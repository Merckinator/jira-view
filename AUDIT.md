# jira-view audit — implementation checklist

Audit date: 2026-10-19
Scope: whole repo (`src/`, `shared/src/`, `ui/src/`, `test/`, scripts, config)
Load assumed: one person, one machine, a few saved views, tens to a few hundred
issues per view, occasional overlapping requests. No multi-user or
internet-facing use.

Working method:

1. I explain one finding.
2. You make the decision (fix / skip / different approach).
3. I implement the smallest fix, add or adjust tests, and run them.
4. We tick the box and record the decision.

Baseline: `gleam test` → 48 passed. Findings 2, 3, 5 and 8 were confirmed with
throwaway tests in a copy of the repo; finding 2 was also confirmed with `curl`.
No application code has been changed yet.

Progress: **19 / 19 decided, 19 / 19 repo changes done** (finding 1 still needs
a manual token rotation at Atlassian).

---

## Must fix

- [x] **1. Live Jira token is committed to git**
  - **Files:** `.env`, `.gitignore:7`, commit `9319535` (rewritten away)
  - **What:** `.env` holds `JIRA_EMAIL`, `JIRA_API_TOKEN` and `JIRA_BASE_URL`.
    It is tracked even though `.gitignore` names it, and the file mode is `664`.
  - **Problem:** The token is in the working tree and in history. Anyone with a
    copy of the repo, or any future push, can act as you in Jira. Another local
    user can read the file.
  - **Fix:** Rotate the token first. Then `git rm --cached .env`, `chmod 600
    .env`, and rewrite history only if the repo will leave this machine.
  - **If skipped:** A leaked token gives full access to the Jira account.
  - **Decision:** Purge history. Done: `.env` untracked, mode `600`, all commits
    rewritten by `git filter-branch`, reflogs expired, old objects pruned. The
    old commit `9319535` and `.env` in history are gone. **Manual action still
    required: rotate the API token at Atlassian.**

- [x] **2. Any website can reach the local app through DNS rebinding**
  - **Files:** `src/jira_view/web.gleam:26-59`, `src/jira_view.gleam:34`
  - **What:** The server accepts any HTTP `Host` header.
  - **Problem:** A page on `evil.example` can point that name at `127.0.0.1`
    (DNS rebinding), then read `/jira/views`, `/jira/search`, and post
    comments/transitions as you. Confirmed: `curl -H 'Host: evil.example'
    http://127.0.0.1:8799/jira/views` returned `200` with data.
  - **Fix:** At the top of `handle_request`, reject requests whose
    `request.host` is not `127.0.0.1` or `localhost` (any port). Update the test
    helper to send a local Host header.
  - **If skipped:** One malicious page can expose Jira data and write to Jira.
  - **Decision:** Host allowlist. `handle_request` now checks the `Host` header
    (lowercased, port stripped) against `127.0.0.1` and `localhost` and returns
    `400 invalid_host` otherwise. Tests go through a `local_request` helper;
    a new `foreign_host_rejected_test` covers `evil.example`. Verified live:
    `127.0.0.1` → 200, `localhost` → 200, `evil.example` → 400. `gleam test`:
    49 passed.

- [x] **3. Deleting every view brings "My issues" back**
  - **Files:** `src/jira_view/db.gleam:88-117`, `src/jira_view/web.gleam:404-415`
  - **What:** Every request runs `migrate`, which seeds the default view
    whenever the `views` table is empty.
  - **Problem:** Delete the last view, reload, and the server re-creates "My
    issues". Confirmed with a test.
  - **Fix:** Seed only when the `views` table is created for the first time
    (check `sqlite_master` before creating it, or store a `seeded` flag). Add a
    test: delete all, migrate, still empty.
  - **If skipped:** The user cannot keep an empty view list; delete is a lie.
  - **Decision:** Seed on first creation. `migrate` now checks `sqlite_master`
    for the `views` table before running the schema and seeds only when the
    table is new; `views_are_empty` was removed. Added
    `db_deleting_all_views_does_not_reseed_test`; the fresh-DB seed test still
    passes. `gleam test`: 50 passed.

- [x] **4. A slow reply can make the next comment go to the wrong issue**
  - **Files:** `ui/src/jira_view_ui.gleam:399-421`, `732-756`, `866-885`
  - **What:** `GotDetail` and `GotTransitions` carry no issue key; `GotIssues`
    carries no view id. The last reply wins.
  - **Problem:** Open issue A, click B before A answers; if A's reply lands
    last, the panel shows A and `selected_key` is A, so a comment typed for B
    is posted to A. The same race can show A's transition buttons while B is
    selected and post A's transition id to B. Switching views can show A's
    issues under B.
  - **Fix:** Put the key/view id in the messages and ignore replies that do not
    match the current selection/view. Add a test for out-of-order replies.
  - **If skipped:** Rare but real wrong-issue writes; the panel can silently
    show the wrong issue.
  - **Decision:** Tag replies. `GotDetail`/`GotTransitions` now carry the issue
    key and `GotIssues` carries the view id; `is_selected`/`is_current_view`
    drop replies that no longer match. UI compiles for JavaScript. Test coverage
    comes with finding 13. Remaining known gap: two requests for the same
    issue/view can still race; a generation counter would close that if needed.

- [x] **5. Saving the order is not atomic**
  - **Files:** `src/jira_view/db.gleam:216-244`, `src/jira_view/web.gleam:146-192`
  - **What:** One PATCH deletes the old order, then inserts each key separately,
    with no transaction.
  - **Problem:** Two quick drags overlap, or a client sends a duplicate key: the
    DELETE is committed and the inserts fail halfway. Confirmed: saving
    `["KAN-9", "KAN-9"]` left only `KAN-9`, losing the previous order.
  - **Fix:** Validate/dedupe keys, then wrap DELETE + inserts in
    `BEGIN`/`COMMIT` with rollback on error. Put `delete_view`'s two statements
    in a transaction too.
  - **If skipped:** A failed or overlapping save silently eats the private
    ordering the app exists for.
  - **Decision:** Atomic saves. Added `in_transaction` (`BEGIN IMMEDIATE` /
    `COMMIT` / `ROLLBACK`) around `save_view_order` and `delete_view`;
    `parse_order_body` now rejects duplicate keys with 400. Test: a duplicate
    save returns an error and the previous order is unchanged. `gleam test`:
    50 passed.

---

## Should fix

- [x] **6. A cache error hides a successful Jira fetch**
  - **Files:** `src/jira_view/web.gleam:111-141`
  - **What:** `search` and `board_issues` return `500 cache_write_failed` if
    opening, migrating or writing SQLite fails, even after Jira returned issues.
  - **Problem:** A locked DB or two overlapping writes means the user sees an
    error and no issues, although the fetch worked.
  - **Fix:** Make cache writing best-effort: log the failure, then return the
    fresh issues (Jira's order if the saved order cannot be read).
  - **If skipped:** The cache can take the whole view down.
  - **Decision:** Resolved by deleting the write-only cache (finding 7).
    `search` and `board_issues` no longer write issues. `merge_with_saved_order`
    reads the saved order and, if the database fails, logs the problem and
    returns Jira's order, so a db problem cannot hide fetched issues.

- [x] **7. The SQLite issue cache is write-only**
  - **Files:** `src/jira_view/db.gleam:138-208`; `load_issues` is used only by
    tests
  - **What:** Every search upserts full issues and `fields_json`, but no
    endpoint reads the `issues` table.
  - **Problem:** Each fetch pays one INSERT per issue and schema/maintenance
    cost for data nobody reads. `PLAN.md`'s definition of done says everything
    reads through the cache; that is not true today.
  - **Fix:** Either read cached issues on view load and keep explicit Refresh
    (the plan), or delete `upsert_issues`, `load_issues`, the `issues` table and
    the write call. Pick one.
  - **If skipped:** Wasted writes now, and a cache that can drift stale before
    it is ever used.
  - **Decision:** Deleted. Removed the `issues` table, `upsert_issues`,
    `load_issues`, `upsert_issue`, `issue_row_decoder` and their tests;
    `ensure_schema` drops the old table once at boot. View loads still fetch
    Jira fresh (as before); `PLAN.md` DoD #5 ("everything reads through the
    cache") is superseded. Two cache tests removed: `gleam test` now 48 passed.

- [x] **8. Updating a missing view returns 200**
  - **Files:** `src/jira_view/web.gleam:467-487`, `src/jira_view/db.gleam:365-378`
  - **What:** `UPDATE views ... WHERE id = ?` succeeds when zero rows match, and
    the handler returns the view JSON as if it existed. The order PATCH also
    stores rows for a nonexistent view.
  - **Problem:** A stale tab, a typo or a deleted view gets "saved" with 200;
    the next load shows the old state. Confirmed with a test.
  - **Fix:** Check `get_view` first (or `changes()` after the UPDATE) and return
    404; do the same in `store_order`.
  - **If skipped:** Silent no-op writes; orphan order rows can attach to a
    future view with the same slug.
  - **Decision:** 404 on missing views. `db.update_view` now checks `changes()`
    and returns `NotFound` on zero rows; `store_order` checks `get_view` before
    saving. Added a db assertion plus PUT/PATCH route tests. `gleam test`:
    50 passed.

- [x] **9. Every transition gets resolution "Done"**
  - **Files:** `src/jira_view/web.gleam:285-306`
  - **What:** When a transition screen requires `resolution`, the app always
    posts `{"name": "Done"}`.
  - **Problem:** A workflow with "Won't Do" or "Duplicate" transitions records
    the wrong resolution. The status is right; the resolution is not.
  - **Fix:** Fetch `/rest/api/3/resolution` and let the user pick when the field
    is required; at minimum map common resolution names from the transition
    name instead of hardcoding "Done".
  - **If skipped:** Reports and filters by resolution become wrong.
  - **Decision:** Resolution picker. Added the shared `Resolution` type and
    decoder, a `/jira/resolutions` proxy, an optional `resolution` in the
    transition request (required transitions return 400 if it is missing), and
    a UI picker that defaults to Done. README updated. `gleam test`: 52
    passed; UI compiles.

- [x] **10. Search pages at Jira's default and inserts one row at a time**
  - **Files:** `src/jira_view/jira.gleam:89-130`, `src/jira_view/db.gleam:138-143`
  - **What:** `/search/jql` requests set no `maxResults` (Jira defaults to 50),
    follow pages forever, append with `list.append`, and insert each issue
    separately.
  - **Problem:** A broad but valid JQL (`project = X`) or a big board means
    dozens of round trips, O(n²) list building and an INSERT per issue while the
    request is open.
  - **Fix:** Ask for 100–500 per page, stop at a sane cap (e.g. 2,000 issues)
    with a clear error, prepend/reverse instead of append, and batch the inserts
    in one transaction. This shrinks a lot if the write-only cache (7) is
    dropped.
  - **If skipped:** Some views become very slow; the UI sits on "Loading…" with
    no cancel.
  - **Decision:** Page size 100 and a 2,000-issue cap for both search and
    boards; pages are accumulated as lists and flattened once (linear). The
    per-issue INSERTs were removed with the cache (7). A new `TooMany` error
    maps to `413 too_many_issues` with a "narrow the JQL / smaller board"
    message. `search_page_query_test` updated; `gleam test`: 52 passed.

- [x] **11. The attachment proxy can run an attachment as the app**
  - **Files:** `src/jira_view/web.gleam:641-653`, `src/jira_view/jira.gleam:258-330`
  - **What:** The proxy passes Jira's `content-type` straight through and sets
    no `content-disposition` or `nosniff`.
  - **Problem:** An HTML or SVG attachment opened at
    `http://127.0.0.1:8787/jira/attachment/<id>` runs on the app's origin, where
    it can call the local JSON endpoints. The UI's `download` link helps, but
    the URL is directly reachable and SVG images can be opened in a tab.
  - **Fix:** Render inline only for a small image allowlist (`image/png`,
    `jpeg`, `gif`, `webp`) with `x-content-type-options: nosniff`; for
    everything else send `content-disposition: attachment`.
  - **If skipped:** A malicious attachment in a Jira issue becomes script in the
    app's origin.
  - **Decision:** Safe inline whitelist. `attachment_headers` always sets
    `x-content-type-options: nosniff`; only PNG/JPEG/GIF/WebP are inline, and
    everything else (including SVG and HTML) gets `content-disposition:
    attachment`. Header test covers all four cases. `gleam test`: 53 passed.

- [x] **12. ADF links accept `javascript:` URLs**
  - **Files:** `ui/src/jira_view_ui/adf_view.gleam:41-50`,
    `shared/src/shared/adf.gleam:51-59`
  - **What:** Link marks become `html.a([attribute.href(mark.href)], ...)` with
    no scheme check.
  - **Problem:** A comment or description with a link mark whose `href` is
    `javascript:...` runs script when clicked, in the app's origin. Jira's
    editor may not create one, but anything with API access can.
  - **Fix:** Only render `http://`, `https://`, `mailto:` or safe relative
    links; otherwise show plain text.
  - **If skipped:** Same-origin script execution from Jira content.
  - **Decision:** `shared/adf.safe_link` allows http(s), mailto, `/...` and
    `#...`; everything else falls back to text. The test covers `javascript:`,
    mixed case, `data:`, and empty hrefs. `gleam test`: 54 passed; UI compiles.

- [x] **13. The riskiest UI logic has no tests**
  - **Files:** `ui/src/jira_view_ui.gleam:760-830`; no `ui/test/`
  - **What:** `move_item`, `insert_at` and `focus` implement drag and keyboard
    ordering; the backend has 48 tests, the UI package has none.
  - **Problem:** A one-line index mistake breaks drag ordering silently, and the
    stale-reply rules from finding 4 cannot be regression-tested. Change
    `to - from` to `to - from - 1` and every test still passes.
  - **Fix:** Move these pure functions into a small module and add a few
    gleeunit tests (move down/up, boundaries, empty list), plus tests for reply
    matching.
  - **If skipped:** The feature the app exists for is the least tested part.
  - **Decision:** Extracted `move_item`, `insert_at` and `focus` into
    `ui/src/jira_view_ui/ordering.gleam`. Added
    `ui/test/jira_view_ui_test.gleam`: 15 tests covering drag up/down,
    same-index, out-of-range/empty, cursor clamp, stale/fresh detail and view
    replies, resolution defaulting and the missing-resolution guard. UI tests
    pass; backend 54; UI compiles. README has the test command.

- [x] **14. Delete view has no confirmation**
  - **Files:** `ui/src/jira_view_ui.gleam:294-303`, `1230-1237`
  - **What:** The Delete button immediately deletes the view and its ordering.
  - **Problem:** One stray click permanently loses the view and its private
    order; the button sits next to Cancel.
  - **Fix:** Two-step confirm (a dialog or a "Confirm delete" button) in the edit
    panel.
  - **If skipped:** Accidental, unrecoverable data loss.
  - **Decision:** Two-step confirm. `EditForm.confirm_delete` starts false; the
    first Delete click arms it and the label becomes "Confirm delete", the
    second click deletes. UI test covers the first click; 16 UI tests pass.

- [x] **15. Transition buttons are not refreshed after a successful move**
  - **Files:** `ui/src/jira_view_ui.gleam:435`, `1441-1459`
  - **What:** `GotTransition(_, _, Ok(_))` leaves the model unchanged, so the
    old transition list stays.
  - **Problem:** After "Done" succeeds, the panel still offers "Done" and the
    old alternatives until you close and reopen; clicking again posts a
    transition Jira may reject.
  - **Fix:** On success, refetch transitions (and the issue detail) for that
    key, or clear the list while loading.
  - **If skipped:** Confusing errors and a second click that does nothing.
  - **Decision:** Refetch both transitions and the issue detail on success; the
    stale-reply guards from finding 4 ignore them if the panel changed. UI
    tests: 16 passed; UI compiles.

- [x] **16. `./dev.sh` needs the network even though the bundle is committed**
  - **Files:** `dev.sh:13`, `build.sh:8-14`
  - **What:** Every start runs `npx --yes esbuild`; esbuild is not in
    `ui/package.json`.
  - **Problem:** On a fresh clone with no npm cache and no network, startup
    fails before the server runs, even though `assets/app.js` is committed.
  - **Fix:** Add esbuild to `ui/devDependencies` and use
    `ui/node_modules/.bin/esbuild`, or build only when `assets/app.js` is older
    than the UI sources.
  - **If skipped:** Offline or deterministic startup can break on an unrelated
    npm download.
  - **Decision:** Pinned `esbuild ^0.28.2` in `ui/devDependencies`. `build.sh`
    uses the local binary, skips when `assets/app.js` is newer than the UI and
    shared sources, and falls back to the committed bundle with a warning if
    esbuild is missing. Verified rebuild, up-to-date skip, and missing-binary
    fallback. Bundle rebuilt with all UI findings.

---

## Nice to have

- [x] **17. Board views say "active sprint" but fetch every board issue**
  - **Files:** `ui/src/jira_view_ui.gleam:1163-1167`,
    `src/jira_view/jira.gleam:218-252`
  - **What:** The label says "board · active sprint"; `board_issues` calls the
    board's issue endpoint, which returns all issues.
  - **Problem:** If a sprint board has old issues, the view shows them and the
    label is misleading.
  - **Fix:** Change the label to "board · all issues", or filter by the active
    sprint if that is the intent.
  - **If skipped:** Users misread what the list contains.
  - **Decision:** Renamed the label to "board · all issues" and the CSS class
    to `jv-board-note`. Bundle rebuilt; UI tests 16 passed.

- [x] **18. Choosing Board before boards load silently does nothing**
  - **Files:** `ui/src/jira_view_ui.gleam:230-243`, `589-598`
  - **What:** `PickBoardSource` keeps the previous source while `boards` is
    still `None`.
  - **Problem:** New view, pick "Board" quickly, and the select snaps back to
    JQL; the user has to pick again after the list arrives.
  - **Fix:** Switch to a `Board(0)` placeholder and disable Save until boards
    load, or fetch boards before opening the editor.
  - **If skipped:** A small but confusing dead click.
  - **Decision:** Disabled the "loading boards…" and "boards unavailable"
    options, so they cannot be chosen; Save is disabled while the source is
    `Board(0)`. Removed the unused `PickBoardSource` message and
    `source_board_of` helper. UI tests 16 passed; bundle rebuilt.

- [x] **19. Enter on a focused button opens the row instead**
  - **Files:** `ui/src/jira_view_ui/keyboard_ffi.mjs:11-31`
  - **What:** The key handler skips inputs, textareas and selects, but not
    buttons or links, and calls `preventDefault()` for Enter.
  - **Problem:** Tab to Cancel/Delete/Comment and press Enter: the button's
    default action is cancelled and the focused issue row opens. Space still
    works.
  - **Fix:** Skip the handler when the event target is inside a `button` or `a`.
  - **If skipped:** Keyboard users cannot use Enter on controls.
  - **Decision:** The handler now ignores events whose target is inside
    `input`, `textarea`, `select`, `button`, `a`, `[contenteditable='true']` or
    `[role='button']` (plus the existing `isContentEditable` check). Bundle
    rebuilt; UI tests 16 passed.

---

## Notes left out of the numbered list

Two smaller UI polish items, deliberately not part of the 19:

- ADF mentions render as empty text because only `text` is kept (`mention`
  nodes carry their label in `attrs`).
- Pending comments use `drop_first`, so two comments sent quickly can remove
  the wrong "sending…" line (the actual comment still goes to the right issue).

## Final verification

- Backend: `gleam test` → **54 passed**.
- Frontend: `(cd ui && gleam test --target javascript)` → **16 passed**.
- `./build.sh` → bundle rebuilt after the UI findings, then reported up to date.
- Boot smoke test on `127.0.0.1:8802`: `/` → 303, index → 200, bundle → 200,
  `/jira/views` → 200, foreign `Host` → 400, `/jira/resolutions` → 502 with
  dummy credentials.

## Not checked

- Live Jira calls/writes. The resolution endpoint and the transition POST are
  covered by decoders and unit tests, not a live request. Do one real
  transition (including a non-Done resolution) before relying on it.
- Browser click-through. The UI logic is unit-tested and the bundle is rebuilt,
  but nobody has clicked through it since the changes.
- Vendored `build/packages` and the minified `assets/app.js`.
- Concurrent-request stress. Order saves are transactional, but no load test
  was run.

## Lean

Removed the write-only issue cache (about 100 lines and one table) and the 14
tracked Playwright debug artifacts (156 KB, now ignored). No unused
dependencies found.

## Verdict

All 19 findings are implemented and committed. The only required manual step is
rotating the Jira token at Atlassian. Optional: do a live transition smoke test.
