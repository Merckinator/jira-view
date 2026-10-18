# jira_view

A private, local front-end for Jira Cloud — views, filters, and manually
re-ordered issues that live on your machine only (see [PLAN.md](PLAN.md)).

Currently Phase 0: a server on 127.0.0.1 with `GET /api/me`, which proves the
configured Jira credentials and returns your identity.

## Run

1. Copy `.env.example` to `.env` and fill it in. Create an API token at
   <https://id.atlassian.com/manage-profile/security/api-tokens>.
2. `./dev.sh`, then open <http://127.0.0.1:8787/api/me>.

## Development

```sh
gleam test  # Run the tests
```