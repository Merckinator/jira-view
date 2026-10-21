# AGENTS.md

## Layout

Three independent Gleam packages (no workspace tool):

- Root `jira_view` (Erlang target): the Wisp/Mist backend. `src/jira_view.gleam` starts the server, `src/jira_view/web.gleam` is the router, `src/jira_view/jira.gleam` is the Jira client, `src/jira_view/db.gleam` owns SQLite.
- `shared/` (compiled for both Erlang and JS): Jira types, JSON decoders and ADF helpers. Keep it pure — only `gleam_stdlib` / `gleam_json`, no target-specific code.
- `ui/` (JavaScript target): the Lustre MVU app in `ui/src/jira_view_ui.gleam`; the `.mjs` files beside it are its JS FFI.

The backend serves the hand-written `assets/index.html` and generated `assets/app.js` under `/assets`; `/` redirects to the index. The browser only talks to local `/jira/*` endpoints, which proxy Jira so credentials never reach the browser.

## Commands

```sh
./dev.sh                                    # source .env, build UI, run at http://127.0.0.1:8787/
gleam test                                  # backend suite (root package only)
(cd shared && gleam test)                   # shared suite; root `gleam test` does NOT run it
(cd ui && gleam test --target javascript)   # UI suite (Node)
npm --prefix ui install                     # once; needed for UI tests and the bundle
./build.sh                                  # rebuild committed assets/app.js
```

Gleeunit discovers every `test/**/*_test.gleam` function whose name ends in `_test`; there is no single-test filter, so run the package suite.

## Configuration and storage

- Config is read from the environment per request: `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_BASE_URL` (must be `https://`). Optional: `JIRA_VIEW_PORT` (default 8787), `JIRA_VIEW_DB` (default `jira-view.db` in the current directory).
- `dev.sh` sources `.env`; tests do not, so they set values with `envoy`.
- The server binds `127.0.0.1` and rejects non-local `Host` headers; do not weaken either guard.
- SQLite connections are opened per request. `db.ensure_schema()` runs at boot; `db.migrate()` runs per request, seeds the default view only for a genuinely fresh database, and must stay idempotent. Don't add a global connection.

## Testing quirks

- Handler tests share process-wide environment via `envoy`. Set `JIRA_VIEW_DB` explicitly and reset config as needed.
- Direct DB tests use `JIRA_VIEW_DB=:memory:`. Handler tests that open their own connection cannot share an in-memory DB, so they use gitignored files such as `order-route-test.db` and `views-route-test.db` at the repo root.
- No live Jira is needed: failure-path tests point `JIRA_BASE_URL` at `https://127.0.0.1:1`.

## Gotchas

- Add routes in the `case path_segments` in `src/jira_view/web.gleam`.
- Jira search uses the modern `/rest/api/3/search/jql`, not deprecated `/rest/api/3/search`; boards use `/rest/agile/1.0`. A view is capped at 2000 issues.
- The Flagged custom field id varies between Cloud sites. It is discovered by name via `/rest/api/3/field`, cached per base URL in `persistent_term`, and overridable with `JIRA_FLAGGED_FIELD`; the option value is overridable with `JIRA_FLAGGED_VALUE`. Do not hardcode a `customfield_…` id.
- `/jira/issue/:key` is normalized to the app shape (issue + ADF content lists + pruned comments/worklog/attachments), so the UI never needs Jira custom-field ids.
- When adding an issue field, update the `search_fields`/`issue_fields` functions, `shared/types.gleam` and its decoders together.
- Per-view ordering is overlaid on Jira's order by `db.merge_view_order`; a save replaces the entire key list. The tests pin these semantics.
- The UI deliberately avoids `lustre_http` (it conflicts with stdlib 1.x) and uses `ui/src/jira_view_ui/fetch_ffi.mjs`; don't reintroduce `lustre_http`.
- `build.sh` hardcodes the esbuild input path `ui/build/dev/javascript/jira_view_ui/jira_view_ui.mjs`; update it if the UI package is renamed. It skips rebuilding when `assets/app.js` is newer than its inputs and falls back to the committed bundle when esbuild is absent. `assets/app.js` is tracked — rebuild and commit it with UI changes.
