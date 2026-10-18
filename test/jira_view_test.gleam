import envoy
import gleam/http
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import jira_view/config
import jira_view/db
import jira_view/jira
import jira_view/web
import shared/types
import wisp/simulate

pub fn main() {
  gleeunit.main()
}

// config

pub fn normalize_base_url_test() {
  config.normalize_base_url("https://acme.atlassian.net")
  |> should.equal("https://acme.atlassian.net")

  config.normalize_base_url("https://acme.atlassian.net/")
  |> should.equal("https://acme.atlassian.net")

  config.normalize_base_url("https://acme.atlassian.net//")
  |> should.equal("https://acme.atlassian.net")
}

// https guard: Basic auth must never be sent to a plain-http or schemeless host

pub fn require_https_test() {
  config.require_https("https://acme.atlassian.net")
  |> should.be_ok
  |> should.equal("https://acme.atlassian.net")

  config.require_https("http://acme.atlassian.net")
  |> should.be_error

  config.require_https("acme.atlassian.net")
  |> should.be_error

  config.require_https("")
  |> should.be_error
}

// web: how /api/me maps failures to statuses

pub fn me_missing_config_test() {
  envoy.unset("JIRA_EMAIL")
  envoy.unset("JIRA_API_TOKEN")
  envoy.unset("JIRA_BASE_URL")
  let resp = web.handle_request(simulate.request(http.Get, "/api/me"))
  resp.status |> should.equal(503)
}

pub fn me_jira_unreachable_test() {
  // a closed local port, so the call fails fast without touching Jira
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp = web.handle_request(simulate.request(http.Get, "/api/me"))
  resp.status |> should.equal(502)
}

// web: /jira/search + /jira/issue requirements

pub fn search_missing_jql_test() {
  let resp = web.handle_request(simulate.request(http.Get, "/jira/search"))
  resp.status |> should.equal(400)
}

pub fn search_jira_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp =
    web.handle_request(simulate.request(
      http.Get,
      "/jira/search?jql=created%20%3E%3D%20-30d",
    ))
  resp.status |> should.equal(502)
}

pub fn issue_jira_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp = web.handle_request(simulate.request(http.Get, "/jira/issue/KAN-1"))
  resp.status |> should.equal(502)
}

// basic auth encoding

pub fn basic_auth_header_test() {
  let cfg =
    config.Config(
      email: "jeff@example.com",
      api_token: "&c|>bE{)Z7!wV$2b",
      base_url: "https://acme.atlassian.net",
    )
  jira.basic_auth_header(cfg)
  |> should.equal("Basic amVmZkBleGFtcGxlLmNvbTomY3w+YkV7KVo3IXdWJDJi")
}

// search request shape: jql bounded, fields pruned, token appended when present

pub fn search_page_query_test() {
  jira.search_page_query("assignee = currentUser()", None)
  |> should.equal([
    #("jql", "assignee = currentUser()"),
    #("fields", jira.search_fields),
  ])

  jira.search_page_query("created >= -30d ORDER BY updated DESC", Some("tok"))
  |> should.equal([
    #("jql", "created >= -30d ORDER BY updated DESC"),
    #("fields", jira.search_fields),
    #("nextPageToken", "tok"),
  ])
}

// cache: schema + upsert + load round trip on an in-memory db

fn cached_issue(
  key: String,
  summary: String,
  assignee_name: String,
) -> types.Issue {
  types.Issue(
    key: key,
    id: "10012",
    summary: summary,
    status: types.Status("To Do", "new"),
    assignee: case assignee_name {
      "" -> None
      name -> Some(types.User("557058:f1a2b3c4", name, "https://x/48.png"))
    },
    updated: "2026-10-18T18:05:33.688-0400",
  )
}

pub fn db_upsert_load_round_trip_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let assert Ok(conn) = db.open()
  let assert Ok(_) = db.migrate(conn)

  db.upsert_issues(conn, [
    cached_issue("KAN-3", "Subtask 2.1", ""),
    cached_issue("KAN-1", "Create a demo project", "Jeff"),
  ])
  |> should.be_ok

  let assert Ok(loaded) = db.load_issues(conn)
  // insertion order preserved; rows come back without status category and
  // assignee avatar (those columns only exist for future detail rendering)
  loaded
  |> should.equal([
    types.Issue(
      key: "KAN-3",
      id: "10012",
      summary: "Subtask 2.1",
      status: types.Status("To Do", ""),
      assignee: None,
      updated: "2026-10-18T18:05:33.688-0400",
    ),
    types.Issue(
      key: "KAN-1",
      id: "10012",
      summary: "Create a demo project",
      status: types.Status("To Do", ""),
      assignee: Some(types.User("", "Jeff", "")),
      updated: "2026-10-18T18:05:33.688-0400",
    ),
  ])
}

pub fn db_upsert_replaces_existing_keys_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let assert Ok(conn) = db.open()
  let assert Ok(_) = db.migrate(conn)

  let assert Ok(_) = db.upsert_issues(conn, [cached_issue("KAN-3", "Old", "")])
  let assert Ok(_) = db.upsert_issues(conn, [cached_issue("KAN-3", "New", "")])

  let assert Ok(loaded) = db.load_issues(conn)
  loaded
  |> should.equal([
    types.Issue(
      key: "KAN-3",
      id: "10012",
      summary: "New",
      status: types.Status("To Do", ""),
      assignee: None,
      updated: "2026-10-18T18:05:33.688-0400",
    ),
  ])
}

// private ordering: merge semantics (the contract the /jira/search view gives)

pub fn merge_view_order_empty_test() {
  // No saved order yet: Jira's order passes through untouched.
  db.merge_view_order([], [cached_issue("KAN-1", "One", ""), cached_issue("KAN-2", "Two", "")])
  |> should.equal([cached_issue("KAN-1", "One", ""), cached_issue("KAN-2", "Two", "")])
}

pub fn merge_view_order_saved_order_wins_test() {
  db.merge_view_order(
    ["KAN-2", "KAN-1"],
    [cached_issue("KAN-1", "One", ""), cached_issue("KAN-2", "Two", "")],
  )
  |> should.equal([cached_issue("KAN-2", "Two", ""), cached_issue("KAN-1", "One", "")])
}

pub fn merge_view_order_appends_new_issues_test() {
  // KAN-3 was never part of the saved order -> appended at the end,
  // in Jira's order, after every ordered row.
  db.merge_view_order(
    ["KAN-2", "KAN-1"],
    [
      cached_issue("KAN-3", "New", ""),
      cached_issue("KAN-1", "One", ""),
      cached_issue("KAN-2", "Two", ""),
    ],
  )
  |> should.equal([
    cached_issue("KAN-2", "Two", ""),
    cached_issue("KAN-1", "One", ""),
    cached_issue("KAN-3", "New", ""),
  ])
}

pub fn merge_view_order_drops_stale_keys_test() {
  // A saved key that no longer matches the JQL result (resolved, moved
  // projects, …) is simply not rendered; ordering rows stay until the next
  // save rewrites them.
  db.merge_view_order(
    ["KAN-9", "KAN-1"],
    [cached_issue("KAN-1", "One", ""), cached_issue("KAN-2", "Two", "")],
  )
  |> should.equal([
    cached_issue("KAN-1", "One", ""),
    cached_issue("KAN-2", "Two", ""),
  ])
}

pub fn merge_view_order_keeps_fresh_values_test() {
  // Ordered rows come from the fresh fetch, so edits made after the drop
  // (new summary/status) still show through the saved order.
  db.merge_view_order(
    ["KAN-1", "KAN-2"],
    [cached_issue("KAN-1", "One (edited)", ""), cached_issue("KAN-2", "Two", "")],
  )
  |> should.equal([
    cached_issue("KAN-1", "One (edited)", ""),
    cached_issue("KAN-2", "Two", ""),
  ])
}

// private ordering: save/load round trip on an in-memory db

pub fn db_view_order_round_trip_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let assert Ok(conn) = db.open()
  let assert Ok(_) = db.migrate(conn)

  db.load_view_order(conn, "my-issues")
  |> should.be_ok
  |> should.equal([])

  db.save_view_order(conn, "my-issues", ["KAN-2", "KAN-3", "KAN-1"])
  |> should.be_ok

  db.load_view_order(conn, "my-issues")
  |> should.be_ok
  |> should.equal(["KAN-2", "KAN-3", "KAN-1"])

  // saving again replaces the whole ordering (per-view isolation included)
  db.save_view_order(conn, "my-issues", ["KAN-1"])
  |> should.be_ok

  db.save_view_order(conn, "sprint-42", ["KAN-3"])
  |> should.be_ok

  db.load_view_order(conn, "my-issues")
  |> should.be_ok
  |> should.equal(["KAN-1"])

  db.load_view_order(conn, "sprint-42")
  |> should.be_ok
  |> should.equal(["KAN-3"])
}

// web: PATCH /jira/views/:view/order

pub fn order_patch_rejects_bad_body_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let request =
    simulate.request(http.Patch, "/jira/views/my-issues/order")
    |> simulate.json_body(
      json.object([#("order", json.array([], json.string))]),
    )
  let resp = web.handle_request(request)
  resp.status |> should.equal(400)
}

pub fn order_patch_rejects_empty_order_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let request =
    simulate.request(http.Patch, "/jira/views/my-issues/order")
    |> simulate.json_body(json.object([#("keys", json.array([], json.string))]))
  let resp = web.handle_request(request)
  resp.status |> should.equal(400)
}

/// The happy path can't use `:memory:` — the handler opens its own
/// connection while the assertion opens another. A repo-root file does the
/// job (`*.db` is gitignored; saving is full-replace, so runs are idempotent).
pub fn order_patch_stores_order_test() {
  envoy.set("JIRA_VIEW_DB", "order-route-test.db")
  let request =
    simulate.request(http.Patch, "/jira/views/my-issues/order")
    |> simulate.json_body(
      json.object([#("keys", json.array(["KAN-2", "KAN-1"], json.string))]),
    )
  let resp = web.handle_request(request)
  resp.status |> should.equal(200)

  let assert Ok(conn) = db.open()
  db.load_view_order(conn, "my-issues")
  |> should.be_ok
  |> should.equal(["KAN-2", "KAN-1"])
}

pub fn parse_order_body_test() {
  web.parse_order_body("{\"keys\": [\"KAN-2\", \"KAN-1\"]}")
  |> should.be_ok
  |> should.equal(["KAN-2", "KAN-1"])

  web.parse_order_body("{\"keys\": []}")
  |> should.be_ok
  |> should.equal([])

  web.parse_order_body("{\"order\": []}")
  |> should.be_error
}
