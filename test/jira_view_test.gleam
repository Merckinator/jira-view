import envoy
import gleam/http
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
