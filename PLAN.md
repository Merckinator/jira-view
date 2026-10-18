# jira-view — Implementation Plan

A private, local front-end for Jira Cloud built because Atlassian's UI is bloated
for my workflows. Views, filters, and — the key feature — **manually re-ordered
issues** live on *my machine only*, never shared with teammates.

> Provisional project name/location: `~/Documents/jira-view`. Rename freely.

---

## 1. Decisions (locked)

| Decision | Choice | Notes |
| --- | --- | --- |
| Language | Gleam (single project, two compile targets) | Functional, compiles to Erlang **and** JS from one codebase |
| Backend | Wisp on Mist (Erlang target) | Holds API token, proxies Jira, owns SQLite |
| Frontend | Lustre (Elm architecture, JS target) | Model/Update/View; served as static bundle by the backend |
| Storage | SQLite via `sqlight` | Read cache + **private per-view ordering state** |
| Auth | Jira Cloud **API token** + Basic auth (`email:token`) | Cloud has no PATs; token stays in local env/config, never in browser code |
| Rejected | Elm frontend (frozen ecosystem, duplicate types/ports), React/TS stack (more moving parts), browser extension (fragile DOM-fighting), native app (overkill), TUI (wrong fit for visual views) | |
| Deferred | `lustre/server_component` spike (LiveView-style, experimental), Tauri desktop wrapper, cross-device hosting | Phase 7 / later |

**Why the backend exists at all:** the browser cannot safely talk to Jira
directly — token custody, CORS, attachment/avatar proxying, and the SQLite cache
all need a local process in *every* variant of this project.

---

## 2. Architecture

```
┌──────────────────── one Gleam project, two targets ────────────────────────┐
│                                                                             │
│   Backend — Erlang target (wisp + mist)      Frontend — JS target          │
│   ─────────────────────────────────          ───────────────────────        │
│   · Jira REST client (gleam_httpc, Basic auth) · lustre app (MVU)            │
│   · JSON types + decoders  ◄── shared code, compiles to both ──►           │
│   · ADF → lustre Element converter                                          │
│   · sqlight: cache + my orderings      · lustre_http: fetch localhost JSON │
│   · serves static lustre build         · SortableJS drag/drop via JS hook  │
│   · /jira/* JSON endpoints, /assets/*                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

Gleam payoff: Jira issue types, JSON decoders, and the ADF converter are written
once; on BEAM they power the proxy/cache, in the browser they render.

### Local database sketch

```sql
-- read cache, invalidated by explicit refresh (no TTLs at first)
CREATE TABLE issues (
  key        TEXT PRIMARY KEY,      -- "PROJ-123"
  id         TEXT,                  -- Jira numeric issue id
  summary    TEXT,
  status     TEXT,
  assignee   TEXT,
  updated    TEXT,                  -- ISO timestamp
  fields_json TEXT,                 -- full pruned fields blob for detail view
  fetched_at TEXT
);

CREATE TABLE view_issues (
  view_id   TEXT NOT NULL,          -- "my-issues", "sprint", ...
  issue_key TEXT NOT NULL,
  position  INTEGER NOT NULL,       -- DRAG-AND-DROP ORDER (the feature Jira won't give you)
  PRIMARY KEY (view_id, issue_key)
);

CREATE TABLE views (
  id          TEXT PRIMARY KEY,
  name        TEXT,
  jql         TEXT,
  columns_json TEXT                  -- custom column config per view
);
```

---

## 3. Packages

- **Backend (Erlang target):** `wisp`, `mist`, `gleam_httpc`, `gleam_json`,
  `sqlight`, `envoy`
- **Frontend (JS target):** `lustre`, `lustre_ui`, `lustre_http`
- **JS (bundled):** SortableJS (drag-and-drop)
- **Tooling/testing:** `gleeunit` on decoders + ADF converter first; official
  Lustre templates / `lustre` dev flow for the JS build
- **Target split (learned at Phase 0):** this package's Erlang-only
  dependencies (`wisp`, `mist`, `envoy`, `gleam_erlang`, `gleam_httpc`) would
  make `gleam build --target javascript` fail on it. Before the Lustre work
  starts, the shared types + decoders move to a pure package (or module set)
  with no Erlang-only imports; server-only code stays behind.

---

## 4. Phases

### Phase 0 — Spike: prove auth + one call
- [x] Verify toolchain versions — **verified 2026-10-18:** Gleam 1.19.2 (=latest
      v1.19.2), Erlang/OTP 29 / erts-17.1.1 (=latest OTP 29.1.2), rebar3 3.27.3
      (=latest). Nothing to install before starting.
- [x] Create API token at `id.atlassian.com`; store in local env/config
      (`JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_BASE_URL=https://<site>.atlassian.net`)
      — then `cp .env.example .env` and fill it in; run with `./dev.sh`
- [x] `gleam new` (in-place, around PLAN.md); Wisp route calling
      `GET /rest/api/3/myself`
- [x] Decode display name + avatar with `gleam_json`; render JSON in response
      — decode/auth/tests written (4 gleeunit tests pass); verification of the
      200 path awaits real credentials
- [x] Exit when: 200 + correct "you" printed. Everything else is easy after
      this. — **met 2026-10-18:** `GET /api/me` → 200 with real identity.

### Phase 1 — Data layer
- [x] Shared types: `Issue`, `User`, `Status`, etc. — decoders keep a tight
      `fields` allowlist (summary, status, assignee, updated, …) — **done
      2026-10-18:** `src/jira_view/types.gleam` (pure module, only stdlib +
      json; `Me` moved there too). Lifting it into a separate pure package
      stays pending until the Phase 2 JS build actually runs.
- [x] `GET /rest/api/3/search/jql` with `nextPageToken` pagination
      (modern endpoint; legacy `/search` is deprecated) — **done 2026-10-18:**
      `jira.search` follows all pages server-side; verified live (200, 13
      issues, statuses + categories decoded). Multi-page loop hits real data
      only above 50 issues — unit-covered via both page-shape fixtures.
- [x] `sqlight` schema above; cache-on-fetch, explicit refresh button —
      **2026-10-18:** schema (all 3 tables) + cache-on-fetch verified live
      (`INSERT OR REPLACE`, `fetched_at` stamped, `fields_json` blob);
      refresh button/read-through arrive with the Phase 2 UI (no read path
      exists yet to refresh).
- [x] gleeunit tests for decoders against captured real payloads — **16
      tests pass**, fixtures shaped after a live `/search/jql` capture.

### Phase 2 — First real view: "My issues"
- [ ] Lustre app built JS-target, served by Wisp; `lustre_http` against
      `GET /jira/search?jql=...`
- [ ] Default JQL: `assignee = currentUser() AND resolution = Unresolved`
- [ ] Table with custom columns; issue detail page/panel
- [ ] ADF → `lustre/element` converter for description + comments
      (tagged-JSON tree → one recursive function per block type)

### Phase 3 — Private ordering (the headline feature)
- [ ] SortableJS through Lustre's JS interop
- [ ] On drop: write `view_issues` order → `PATCH /jira/views/:id/order`
- [ ] Render merged view: server-ordered list overrides Jira's sort
      (local order wins; new issues appended at the end)
- [ ] Keyboard navigation (j/k/w, enter) alongside drag

### Phase 4 — Writes
- [ ] `GET issue/transitions` first — metadata call; required fields vary
      per workflow (e.g. resolution on Done)
- [ ] `POST /transitions`, `POST comment`, log work (`worklog`)
- [ ] Optimistic UI on local state; refetch on error only

### Phase 5 — More views
- [ ] Saved views CRUD (`views` table): jql + columns + ordering each
- [ ] Sprint/board-style view via `/rest/agile/1.0` (bulk fetch, never
      one request per card)
- [ ] Avatars/attachments proxied through `/jira/*` with auth headers

### Phase 6 — Extras
- [ ] Optional webhooks → live updates (only if desired; refresh-on-demand
      is fine at personal scale)
- [ ] Tauri wrapper around the local server if a dockable desktop app is wanted

### Phase 7 — Experiments (explicitly deferred)
- [ ] `lustre/server_component` spike: migrate "My issues" to LiveView-style
      server rendering if it feels solid; fall back cheaply if not
- [ ] OAuth (3LO) + hosting — only if this ever leaves "just me"

---

## 5. Jira gotchas checklist

- **ADF everywhere:** descriptions/comments are Atlassian Document Format JSON,
  not HTML — render via ADF converter; budget real time here.
- **Search:** use `/rest/api/3/search/jql` + `nextPageToken`; prune `fields`;
  the legacy `/search` endpoint is being retired. **Confirmed live
  2026-10-18:** the token is *absent* on the last page (`isLast: true`), and
  the endpoint **rejects unbounded JQL** with 400 "Unbounded JQL queries are
  not allowed here" — every view's JQL must be bounded (e.g. `assignee =
  currentUser()`, `created >= -90d`).
- **Rank:** Jira's issue *Rank* (LexoRank) is shared via the board — so
  personal manual ordering is stored **locally** (keyed by issue key + view).
  That's the gap this app exists to fill; don't try to write Jira's rank.
- **Transitions metadata:** always fetch per-issue; extra required fields vary.
- **IDs:** keys (`PROJ-123`) for display/caching; numeric `id` where the API
  demands it.
- **Rate limits:** single-user scale is a non-issue *if* we bulk-fetch (no
  parallel request storm per card).

---

## 6. Risk register

| Risk | Plan |
| --- | --- |
| Young ecosystem: some plumbing hand-rolled (env, drag hook, bundling) | Accept for personal scope; follow official Lustre templates |
| Two-target tooling rough edges | Keep shared code pure (no target-specific imports); Erlang-only bits live in backend modules, JS-only in the app |
| Lustre server components stability | Deferred to Phase 7 as a spike, default architecture unaffected |
| Jira API drift | Decoders tested against captured payloads; gleeunit failures surface drift early |
| Scope creep ("rebuild all of Jira") | Every view is trivially deletable config; render only the ~5 workflows I actually live in |

---

## 7. Definition of done (v1)

1. `gleam run` boots the local server on localhost.
2. "My issues" loads my unresolved issues, with columns I chose.
3. I can drag issues into an order that **persists across restarts and is
   visible to nobody else**.
4. I can transition and comment without opening atlassian.net.
5. Everything reads through the local cache; refresh is explicit.