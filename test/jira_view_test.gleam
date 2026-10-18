import envoy
import gleam/http
import gleam/json.{parse}
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import jira_view/config
import jira_view/db
import jira_view/jira
import jira_view/types
import jira_view/web
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

// web: /jira/search requirements

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

// decoding against the shape of a captured Jira /rest/api/3/myself response

const sample_myself =
  "
{
  \"accountId\": \"557058:f1a2b3c4\",
  \"displayName\": \"Jeff Merckens\",
  \"emailAddress\": \"jeff@example.com\",
  \"timeZone\": \"America/New_York\",
  \"avatarUrls\": {
    \"16x16\": \"https://acme.atlassian.net/16.png\",
    \"48x48\": \"https://acme.atlassian.net/48.png\"
  }
}
"

pub fn decode_me_test() {
  let assert Ok(me) = parse(sample_myself, types.me_decoder())
  me.account_id |> should.equal("557058:f1a2b3c4")
  me.display_name |> should.equal("Jeff Merckens")
  me.email |> should.equal("jeff@example.com")
  me.avatar_url |> should.equal("https://acme.atlassian.net/48.png")
  me.time_zone |> should.equal("America/New_York")
}

pub fn decode_me_missing_optional_fields_test() {
  let assert Ok(me) =
    parse(
      "{
        \"accountId\": \"abc\",
        \"displayName\": \"Jeff\",
        \"avatarUrls\": {\"48x48\": \"https://acme.atlassian.net/48.png\"}
      }",
      types.me_decoder(),
    )
  me.email |> should.equal("")
  me.time_zone |> should.equal("")
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

// decoding against the shape of a captured Jira /rest/api/3/search/jql
// page (project KAN, bounded jql, fields=summary,status,assignee,updated)

const sample_search_page =
  "
{
  \"nextPageToken\": \"EAMYscSMiZU0IiNjcmVhdGVkPj0tMzBk\",
  \"isLast\": false,
  \"issues\": [
    {
      \"id\": \"10012\",
      \"key\": \"KAN-3\",
      \"fields\": {
        \"summary\": \"Subtask 2.1\",
        \"assignee\": null,
        \"updated\": \"2026-10-18T18:05:33.688-0400\",
        \"status\": {
          \"description\": \"\",
          \"name\": \"To Do\",
          \"id\": \"10003\",
          \"statusCategory\": {\"key\": \"new\", \"name\": \"To Do\"}
        }
      }
    },
    {
      \"id\": \"10010\",
      \"key\": \"KAN-1\",
      \"fields\": {
        \"summary\": \"Create a demo project\",
        \"assignee\": {
          \"accountId\": \"557058:f1a2b3c4-5678\",
          \"displayName\": \"Jeff Merckens\",
          \"avatarUrls\": {\"48x48\": \"https://acme.atlassian.net/48.png\"}
        },
        \"updated\": \"2026-10-17T10:00:00.000-0400\",
        \"status\": {
          \"name\": \"In Progress\",
          \"statusCategory\": {\"key\": \"indeterminate\", \"name\": \"In Progress\"}
        }
      }
    }
  ]
}
"

pub fn decode_search_page_test() {
  let assert Ok(page) = parse(sample_search_page, types.search_page_decoder())
  page.issues |> list.length |> should.equal(2)
  page.next_page_token |> should.equal(Some("EAMYscSMiZU0IiNjcmVhdGVkPj0tMzBk"))

  let assert [first, second] = page.issues
  first.key |> should.equal("KAN-3")
  first.id |> should.equal("10012")
  first.summary |> should.equal("Subtask 2.1")
  first.assignee |> should.be_none
  first.status |> should.equal(types.Status("To Do", "new"))
  first.updated |> should.equal("2026-10-18T18:05:33.688-0400")

  second.assignee |> should.be_some
  let assert Some(assignee) = second.assignee
  assignee.display_name |> should.equal("Jeff Merckens")
  assignee.account_id |> should.equal("557058:f1a2b3c4-5678")
  assignee.avatar_url |> should.equal("https://acme.atlassian.net/48.png")
  second.status |> should.equal(types.Status("In Progress", "indeterminate"))
}

// last page of a real capture: "isLast": true and no nextPageToken at all

pub fn decode_search_last_page_test() {
  let assert Ok(page) =
    parse("{\"issues\": [], \"isLast\": true}", types.search_page_decoder())
  page.issues |> should.equal([])
  page.next_page_token |> should.be_none
}

// a user without avatarUrls and a status without statusCategory still decode
// (the fields allowlist is enforced on the request side; tolerating their
// absence keeps the decoders quiet about rendering-only details)

pub fn decode_search_page_missing_optional_bits_test() {
  let assert Ok(page) =
    parse(
      "{
        \"issues\": [
          {
            \"id\": \"1\",
            \"key\": \"KAN-9\",
            \"fields\": {
              \"summary\": \"s\",
              \"assignee\": {\"displayName\": \"Jeff\"},
              \"updated\": \"2026-10-17T10:00:00.000-0400\",
              \"status\": {\"name\": \"To Do\"}
            }
          }
        ]
      }",
      types.search_page_decoder(),
    )
  let assert [only] = page.issues
  only.status.category |> should.equal("")
  let assert Some(user) = only.assignee
  user.avatar_url |> should.equal("")
  user.account_id |> should.equal("")
}

// missing required fields surface loudly instead of rendering garbage

pub fn decode_search_page_missing_summary_is_error_test() {
  let parsed =
    parse(
      "{
        \"issues\": [
          {\"id\": \"1\", \"key\": \"KAN-9\", \"fields\": {}}
        ]
      }",
      types.search_page_decoder(),
    )
  parsed |> should.be_error
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
