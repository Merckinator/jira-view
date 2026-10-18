# jira_view

A private, local front-end for Jira Cloud — views, filters, and manually
re-ordered issues that live on your machine only (see [PLAN.md](PLAN.md)).

Currently Phase 3: "My issues" as a Lustre table with **private drag-and-drop
ordering**, served by a Wisp proxy that caches every fetch in SQLite.

## Run

1. Copy `.env.example` to `.env` and fill it in. Create an API token at
   <https://id.atlassian.com/manage-profile/security/api-tokens>.
2. `./dev.sh`, then open <http://127.0.0.1:8787/>. That URL serves the app;
   `/api/me` stays as the credential probe.

## Ordering (the point of this app)

- Drag rows by the `⋮⋮` handle; the order is saved to the local
  `view_issues` table on every drop and re-applied over Jira's sort on the
  next fetch (new issues append at the end).
- Keyboard: `j`/`k` move the focus cursor, `Shift+j`/`Shift+k` relocate the
  focused row, `Enter` opens its detail panel.

## Development

```sh
gleam test   # Backend tests (Erlang target)
./build.sh   # Rebuild the ui/ bundle into assets/app.js
```