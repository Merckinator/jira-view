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
import shared/adf
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

// Phase 4: ADF building + round trip

pub fn adf_paragraph_document_round_trip_test() {
  let document = adf.paragraph_document("hello \"json\" & <world>")
  json.parse(json.to_string(adf.adf_to_json(document)), adf.adf_decoder())
  |> should.equal(Ok(document))
}

pub fn adf_document_shape_test() {
  // Jira needs type+version at the doc level and type/text inside.
  json.to_string(adf.adf_to_json(adf.paragraph_document("hi")))
  |> should.equal(
    "{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}]}",
  )
}

// Phase 4: comment / worklog decoders against captured real shapes

pub fn jira_comment_decoder_capture_test() {
  // Shape captured from POST /rest/api/3/issue/SAM1-11/comment (identical
  // to the entries embedded in fields.comment.comments, minus extras).
  json.parse(
    "{\"id\":\"10000\",\"author\":{\"accountId\":\"5a67cc62cc9f657ed59d22da\",\"displayName\":\"Jeffery Merckens\",\"active\":true},\"body\":{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"Captured comment shape\"}]}]},\"created\":\"2026-10-18T19:38:02.298-0400\",\"updated\":\"2026-10-18T19:38:02.298-0400\",\"jsdPublic\":true}",
    types.jira_comment_decoder(),
  )
  |> should.equal(Ok(types.Comment(
    author: "Jeffery Merckens",
    created: "2026-10-18T19:38:02.298-0400",
    body: [
      adf.AdfNode(
        "paragraph",
        "",
        [adf.AdfNode("text", "Captured comment shape", [], [])],
        [],
      ),
    ],
  )))
}

pub fn jira_comment_decoder_absent_body_test() {
  json.parse("{\"created\":\"2026\"}", types.jira_comment_decoder())
  |> should.equal(Ok(types.Comment(author: "", created: "2026", body: [])))
}

pub fn jira_worklog_decoder_capture_test() {
  // Shape per the POST /rest/api/3/issue/:key/worklog capture: author,
  // started, timeSpent; comment (ADF) is optional.
  json.parse(
    "{\"id\":\"10000\",\"author\":{\"displayName\":\"Jeffery Merckens\"},\"started\":\"2026-10-18T23:38:02.298+0000\",\"timeSpent\":\"25m\",\"timeSpentSeconds\":1500}",
    types.jira_worklog_decoder(),
  )
  |> should.equal(Ok(types.WorklogEntry(
    author: "Jeffery Merckens",
    started: "2026-10-18T23:38:02.298+0000",
    time_spent: "25m",
    body: [],
  )))
}

pub fn issue_detail_decoder_with_embeds_test() {
  // fields.comment / fields.worklog embeds decode through the same
  // entry decoders (verified against a live capture with one of each).
  json.parse(
    "{\"id\":\"10013\",\"key\":\"SAM1-11\",\"fields\":{\"summary\":\"Phase 4 verification\",\"status\":{\"name\":\"Done\",\"statusCategory\":{\"key\":\"done\"}},\"updated\":\"2026-10-18\",\"description\":null,\"comment\":{\"comments\":[{\"author\":{\"displayName\":\"Jeffery Merckens\"},\"created\":\"2026-10-18T19:38:02.298-0400\",\"body\":{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"c1\"}]}]}}],\"total\":1},\"worklog\":{\"worklogs\":[{\"author\":{\"displayName\":\"Jeffery Merckens\"},\"started\":\"2026-10-18T23:38:02.298+0000\",\"timeSpent\":\"25m\"}],\"total\":1}}}",
    types.issue_detail_decoder(),
  )
  |> should.equal(Ok(types.IssueDetail(
    issue: types.Issue(
      key: "SAM1-11",
      id: "10013",
      summary: "Phase 4 verification",
      status: types.Status("Done", "done"),
      assignee: None,
      updated: "2026-10-18",
    ),
    description: [],
    comments: [
      types.Comment(
        author: "Jeffery Merckens",
        created: "2026-10-18T19:38:02.298-0400",
        body: [
          adf.AdfNode("paragraph", "", [adf.AdfNode("text", "c1", [], [])], []),
        ],
      ),
    ],
    worklog: [
      types.WorklogEntry(
        author: "Jeffery Merckens",
        started: "2026-10-18T23:38:02.298+0000",
        time_spent: "25m",
        body: [],
      ),
    ],
  )))
}

// Phase 4: transitions metadata + the POST body this app builds

pub fn jira_transitions_decoder_capture_test() {
  // Captured from GET /rest/api/3/issue/SAM1-7/transitions (fields absent
  // on the simplest team-managed workflows).
  json.parse(
    "{\"expand\":\"transitions\",\"transitions\":[{\"id\":\"11\",\"name\":\"To Do\",\"to\":{\"name\":\"To Do\",\"statusCategory\":{\"key\":\"new\"}},\"hasScreen\":false,\"isGlobal\":true,\"isConditional\":false},{\"id\":\"41\",\"name\":\"Done\",\"to\":{\"name\":\"Done\",\"statusCategory\":{\"key\":\"done\"}},\"isLooped\":false}]}",
    types.jira_transitions_decoder(),
  )
  |> should.equal(Ok([
    types.Transition("11", "To Do", "To Do", []),
    types.Transition("41", "Done", "Done", []),
  ]))
}

pub fn transition_with_required_resolution_test() {
  // Company-managed workflows carry a transition screen: {fields: [...]}.
  json.parse(
    "{\"transitions\":[{\"id\":\"31\",\"name\":\"Done\",\"to\":{\"name\":\"Done\"},\"fields\":[{\"required\":true,\"name\":\"Resolution\",\"key\":\"resolution\"},{\"required\":false,\"key\":\"comment\"}]}]}",
    types.jira_transitions_decoder(),
  )
  |> should.equal(Ok([
    types.Transition(
      "31",
      "Done",
      "Done",
      [types.TransitionField("resolution", True), types.TransitionField("comment", False)],
    ),
  ]))

  let assert Ok([transition]) =
    json.parse(
      "{\"transitions\":[{\"id\":\"31\",\"name\":\"Done\",\"to\":{\"name\":\"Done\"},\"fields\":[{\"required\":true,\"key\":\"resolution\"}]}]}",
      types.jira_transitions_decoder(),
    )

  // resolution is auto-filled into the POST body…
  web.transition_post_body(transition)
  |> should.equal(
    "{\"transition\":{\"id\":\"31\"},\"fields\":{\"resolution\":{\"name\":\"Done\"}}}",
  )

  // …and never reported as an unexpected requirement; other required
  // fields are refused up front.
  web.unexpected_required_fields(transition)
  |> should.equal([])
}

pub fn transition_post_body_plain_test() {
  let transition = types.Transition("21", "In Progress", "In Progress", [])
  web.transition_post_body(transition)
  |> should.equal("{\"transition\":{\"id\":\"21\"}}")
}

// Phase 4: write request bodies + routes

pub fn parse_write_bodies_test() {
  web.parse_transition_body("{\"id\": \"41\"}")
  |> should.be_ok
  |> should.equal("41")

  web.parse_transition_body("{\"transition\": {}}")
  |> should.be_error

  web.parse_comment_body("{\"text\": \"  hi \\n\"}")
  |> should.be_ok
  |> should.equal("hi")

  web.parse_comment_body("{\"text\": \"   \"}")
  |> should.be_ok
  |> should.equal("")

  web.parse_worklog_body("{\"time_spent\": \"25m\"}")
  |> should.be_ok
  |> should.equal("25m")

  web.parse_worklog_body("{}")
  |> should.be_error
}

pub fn transition_post_route_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let request =
    simulate.request(http.Post, "/jira/issue/KAN-1/transition")
    |> simulate.json_body(json.object([#("id", json.string("41"))]))
  let resp = web.handle_request(request)
  // valid body, but the metadata GET can't reach Jira
  resp.status |> should.equal(502)
}

pub fn write_routes_bad_body_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")

  let bad_transition =
    simulate.request(http.Post, "/jira/issue/KAN-1/transition")
    |> simulate.json_body(json.null())
  web.handle_request(bad_transition).status |> should.equal(400)

  let bad_comment =
    simulate.request(http.Post, "/jira/issue/KAN-1/comment")
    |> simulate.json_body(json.object([#("nope", json.string("hi"))]))
  web.handle_request(bad_comment).status |> should.equal(400)

  let bad_worklog =
    simulate.request(http.Post, "/jira/issue/KAN-1/worklog")
    |> simulate.json_body(json.object([#("x", json.string(""))]))
  web.handle_request(bad_worklog).status |> should.equal(400)
}
