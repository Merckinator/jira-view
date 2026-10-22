import envoy
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import jira_view/config
import jira_view/db
import jira_view/jira
import jira_view/web
import shared/adf
import shared/types
import wisp
import wisp/simulate

pub fn main() {
  gleeunit.main()
}

const flagged_field = "customfield_10021"

/// Wisp's simulated requests default to `wisp.example.com`; the handler now
/// accepts only local hosts, so every test request goes through this helper.
fn local_request(method: http.Method, path: String) -> wisp.Request {
  simulate.request(method, path)
  |> simulate.header("host", "127.0.0.1:8787")
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
  let resp = web.handle_request(local_request(http.Get, "/api/me"))
  resp.status |> should.equal(503)
}

/// A page on another origin must not be able to read the local API through
/// DNS rebinding, which would send its own Host header.
pub fn foreign_host_rejected_test() {
  let resp =
    simulate.request(http.Get, "/jira/views")
    |> simulate.header("host", "evil.example")
    |> web.handle_request
  resp.status |> should.equal(400)
}

pub fn me_jira_unreachable_test() {
  // a closed local port, so the call fails fast without touching Jira
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp = web.handle_request(local_request(http.Get, "/api/me"))
  resp.status |> should.equal(502)
}

// web: /jira/search + /jira/issue requirements

pub fn search_missing_jql_test() {
  let resp = web.handle_request(local_request(http.Get, "/jira/search"))
  resp.status |> should.equal(400)
}

pub fn search_jira_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp =
    web.handle_request(local_request(
      http.Get,
      "/jira/search?jql=created%20%3E%3D%20-30d",
    ))
  resp.status |> should.equal(502)
}

pub fn issue_jira_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp = web.handle_request(local_request(http.Get, "/jira/issue/KAN-1"))
  resp.status |> should.equal(502)
}

// basic auth encoding

pub fn basic_auth_header_test() {
  let cfg =
    config.Config(
      email: "jeff@example.com",
      api_token: "&c|>bE{)Z7!wV$2b",
      base_url: "https://acme.atlassian.net",
      flagged_field: None,
      flagged_value: None,
    )
  jira.basic_auth_header(cfg)
  |> should.equal("Basic amVmZkBleGFtcGxlLmNvbTomY3w+YkV7KVo3IXdWJDJi")
}

// search request shape: jql bounded, fields pruned, token appended when present

pub fn search_page_query_test() {
  jira.search_page_query("assignee = currentUser()", None, flagged_field)
  |> should.equal([
    #("jql", "assignee = currentUser()"),
    #("fields", jira.search_fields(flagged_field)),
    #("maxResults", "100"),
  ])

  jira.search_page_query(
    "created >= -30d ORDER BY updated DESC",
    Some("tok"),
    flagged_field,
  )
  |> should.equal([
    #("jql", "created >= -30d ORDER BY updated DESC"),
    #("fields", jira.search_fields(flagged_field)),
    #("maxResults", "100"),
    #("nextPageToken", "tok"),
  ])
}

// a site without the Flagged field reads unflagged: no trailing comma, no
// empty custom-field entry in the allowlist
pub fn fields_skip_missing_flag_test() {
  jira.search_fields("")
  |> should.equal("summary,status,assignee,updated,labels")

  jira.issue_fields("")
  |> should.equal(
    "summary,description,status,assignee,updated,comment,worklog,attachment,labels",
  )
}

// the Flagged field is discovered per site; the id is not stable across
// Jira Cloud instances, so these tests pin the name-based lookup.

pub fn find_flagged_field_test() {
  let assert Ok(fields) =
    json.parse(
      "[{\"id\":\"customfield_10300\",\"name\":\"Flagged\",\"untranslatedName\":\"Flagged\",\"schema\":{\"type\":\"array\"}}]",
      jira.jira_fields_decoder(),
    )
  jira.find_flagged_field(fields)
  |> should.equal(Ok(jira.FlagField("customfield_10300", jira.OptionField)))
}

pub fn find_flagged_boolean_field_test() {
  let assert Ok(fields) =
    json.parse(
      "[{\"id\":\"customfield_10300\",\"name\":\"Flagged\",\"untranslatedName\":\"Flagged\",\"schema\":{\"type\":\"boolean\"}}]",
      jira.jira_fields_decoder(),
    )
  jira.find_flagged_field(fields)
  |> should.equal(Ok(jira.FlagField("customfield_10300", jira.BooleanField)))
}

pub fn find_flagged_field_missing_test() {
  let assert Ok(fields) =
    json.parse(
      "[{\"id\":\"summary\",\"name\":\"Summary\",\"schema\":{\"type\":\"string\"}}]",
      jira.jira_fields_decoder(),
    )
  jira.find_flagged_field(fields)
  |> should.be_error
}

pub fn editmeta_flag_option_decoder_test() {
  json.parse(
    "{\"fields\":{\"customfield_10300\":{\"allowedValues\":[{\"id\":\"10019\",\"value\":\"Impediment\"}]}}}",
    jira.flag_option_decoder("customfield_10300"),
  )
  |> should.equal(Ok(Some(jira.FlagOption("value", "Impediment"))))

  json.parse(
    "{\"fields\":{\"customfield_10300\":{\"allowedValues\":[{\"id\":\"10019\"}]}}}",
    jira.flag_option_decoder("customfield_10300"),
  )
  |> should.equal(Ok(Some(jira.FlagOption("id", "10019"))))

  json.parse(
    "{\"fields\":{\"customfield_10300\":{}}}",
    jira.flag_option_decoder("customfield_10300"),
  )
  |> should.equal(Ok(None))
}

pub fn config_flagged_overrides_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://acme.atlassian.net")
  envoy.set("JIRA_FLAGGED_FIELD", "customfield_10300")
  envoy.set("JIRA_FLAGGED_VALUE", "Flagged")

  let assert Ok(cfg) = config.load()
  cfg.flagged_field |> should.equal(Some("customfield_10300"))
  cfg.flagged_value |> should.equal(Some("Flagged"))
  jira.flag_field(cfg)
  |> should.equal(Ok(jira.FlagField("customfield_10300", jira.OptionField)))

  envoy.unset("JIRA_FLAGGED_FIELD")
  envoy.unset("JIRA_FLAGGED_VALUE")
}

pub fn flag_value_uses_override_test() {
  let cfg =
    config.Config(
      email: "jeff@example.com",
      api_token: "test-token",
      base_url: "https://acme.atlassian.net",
      flagged_field: None,
      flagged_value: Some("Flagged"),
    )
  jira.flag_value(
    cfg,
    "KAN-1",
    jira.FlagField("customfield_10021", jira.OptionField),
  )
  |> should.equal(Ok(jira.FlagOption("value", "Flagged")))

  jira.flag_value(
    cfg,
    "KAN-1",
    jira.FlagField("customfield_10021", jira.BooleanField),
  )
  |> should.equal(Ok(jira.FlagOption("value", "")))
}

// test issues for the private-ordering merge

fn sample_issue(
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
    labels: [],
    flagged: False,
    updated: "2026-10-18T18:05:33.688-0400",
  )
}

// private ordering: merge semantics (the contract the /jira/search view gives)

pub fn merge_view_order_empty_test() {
  // No saved order yet: Jira's order passes through untouched.
  db.merge_view_order([], [
    sample_issue("KAN-1", "One", ""),
    sample_issue("KAN-2", "Two", ""),
  ])
  |> should.equal([
    sample_issue("KAN-1", "One", ""),
    sample_issue("KAN-2", "Two", ""),
  ])
}

pub fn merge_view_order_saved_order_wins_test() {
  db.merge_view_order(["KAN-2", "KAN-1"], [
    sample_issue("KAN-1", "One", ""),
    sample_issue("KAN-2", "Two", ""),
  ])
  |> should.equal([
    sample_issue("KAN-2", "Two", ""),
    sample_issue("KAN-1", "One", ""),
  ])
}

pub fn merge_view_order_appends_new_issues_test() {
  // KAN-3 was never part of the saved order -> appended at the end,
  // in Jira's order, after every ordered row.
  db.merge_view_order(["KAN-2", "KAN-1"], [
    sample_issue("KAN-3", "New", ""),
    sample_issue("KAN-1", "One", ""),
    sample_issue("KAN-2", "Two", ""),
  ])
  |> should.equal([
    sample_issue("KAN-2", "Two", ""),
    sample_issue("KAN-1", "One", ""),
    sample_issue("KAN-3", "New", ""),
  ])
}

pub fn merge_view_order_drops_stale_keys_test() {
  // A saved key that no longer matches the JQL result (resolved, moved
  // projects, …) is simply not rendered; ordering rows stay until the next
  // save rewrites them.
  db.merge_view_order(["KAN-9", "KAN-1"], [
    sample_issue("KAN-1", "One", ""),
    sample_issue("KAN-2", "Two", ""),
  ])
  |> should.equal([
    sample_issue("KAN-1", "One", ""),
    sample_issue("KAN-2", "Two", ""),
  ])
}

pub fn merge_view_order_keeps_fresh_values_test() {
  // Ordered rows come from the fresh fetch, so edits made after the drop
  // (new summary/status) still show through the saved order.
  db.merge_view_order(["KAN-1", "KAN-2"], [
    sample_issue("KAN-1", "One (edited)", ""),
    sample_issue("KAN-2", "Two", ""),
  ])
  |> should.equal([
    sample_issue("KAN-1", "One (edited)", ""),
    sample_issue("KAN-2", "Two", ""),
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

  // a failed save (duplicate keys) rolls back instead of leaving a partial
  // order behind
  db.save_view_order(conn, "my-issues", ["KAN-9", "KAN-9"])
  |> should.be_error

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
    local_request(http.Patch, "/jira/views/my-issues/order")
    |> simulate.json_body(
      json.object([#("order", json.array([], json.string))]),
    )
  let resp = web.handle_request(request)
  resp.status |> should.equal(400)
}

pub fn order_patch_rejects_empty_order_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let request =
    local_request(http.Patch, "/jira/views/my-issues/order")
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
    local_request(http.Patch, "/jira/views/my-issues/order")
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

  // duplicates would break the insert; reject them before touching the db
  web.parse_order_body("{\"keys\": [\"KAN-1\", \"KAN-1\"]}")
  |> should.be_error

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

pub fn adf_safe_link_test() {
  adf.safe_link("https://example.com")
  |> should.be_true
  adf.safe_link("HTTP://EXAMPLE.COM")
  |> should.be_true
  adf.safe_link("mailto:jeff@example.com")
  |> should.be_true
  adf.safe_link("/issues/KAN-1")
  |> should.be_true
  adf.safe_link("#comment-1")
  |> should.be_true

  adf.safe_link("javascript:alert(1)")
  |> should.be_false
  adf.safe_link("  JaVaScRiPt:alert(1)")
  |> should.be_false
  adf.safe_link("data:text/html,<script>alert(1)</script>")
  |> should.be_false
  adf.safe_link("")
  |> should.be_false
}

// Phase 4: comment / worklog decoders against captured real shapes

pub fn jira_comment_decoder_capture_test() {
  // Shape captured from POST /rest/api/3/issue/SAM1-11/comment (identical
  // to the entries embedded in fields.comment.comments, minus extras).
  json.parse(
    "{\"id\":\"10000\",\"author\":{\"accountId\":\"5a67cc62cc9f657ed59d22da\",\"displayName\":\"Jeffery Merckens\",\"active\":true},\"body\":{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"Captured comment shape\"}]}]},\"created\":\"2026-10-18T19:38:02.298-0400\",\"updated\":\"2026-10-18T19:38:02.298-0400\",\"jsdPublic\":true}",
    types.jira_comment_decoder(),
  )
  |> should.equal(
    Ok(
      types.Comment(
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
      ),
    ),
  )
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
  |> should.equal(
    Ok(
      types.WorklogEntry(
        author: "Jeffery Merckens",
        started: "2026-10-18T23:38:02.298+0000",
        time_spent: "25m",
        body: [],
      ),
    ),
  )
}

pub fn issue_detail_decoder_with_embeds_test() {
  // fields.comment / fields.worklog embeds decode through the same
  // entry decoders (verified against a live capture with one of each).
  json.parse(
    "{\"id\":\"10013\",\"key\":\"SAM1-11\",\"fields\":{\"summary\":\"Phase 4 verification\",\"labels\":[\"phase-4\"],\"customfield_10021\":[{\"id\":\"10019\",\"value\":\"Impediment\"}],\"status\":{\"name\":\"Done\",\"statusCategory\":{\"key\":\"done\"}},\"updated\":\"2026-10-18\",\"description\":null,\"comment\":{\"comments\":[{\"author\":{\"displayName\":\"Jeffery Merckens\"},\"created\":\"2026-10-18T19:38:02.298-0400\",\"body\":{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"c1\"}]}]}}],\"total\":1},\"worklog\":{\"worklogs\":[{\"author\":{\"displayName\":\"Jeffery Merckens\"},\"started\":\"2026-10-18T23:38:02.298+0000\",\"timeSpent\":\"25m\"}],\"total\":1}}}",
    types.issue_detail_decoder(flagged_field),
  )
  |> should.equal(
    Ok(types.IssueDetail(
      issue: types.Issue(
        key: "SAM1-11",
        id: "10013",
        summary: "Phase 4 verification",
        status: types.Status("Done", "done"),
        assignee: None,
        labels: ["phase-4"],
        flagged: True,
        updated: "2026-10-18",
      ),
      description: [],
      comments: [
        types.Comment(
          author: "Jeffery Merckens",
          created: "2026-10-18T19:38:02.298-0400",
          body: [
            adf.AdfNode(
              "paragraph",
              "",
              [adf.AdfNode("text", "c1", [], [])],
              [],
            ),
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
      attachments: [],
      flags_supported: True,
    )),
  )
}

// Phase 4: transitions metadata + the POST body this app builds

pub fn jira_transitions_decoder_capture_test() {
  // Captured from GET /rest/api/3/issue/SAM1-7/transitions (fields absent
  // on the simplest team-managed workflows).
  json.parse(
    "{\"expand\":\"transitions\",\"transitions\":[{\"id\":\"11\",\"name\":\"To Do\",\"to\":{\"name\":\"To Do\",\"statusCategory\":{\"key\":\"new\"}},\"hasScreen\":false,\"isGlobal\":true,\"isConditional\":false},{\"id\":\"41\",\"name\":\"Done\",\"to\":{\"name\":\"Done\",\"statusCategory\":{\"key\":\"done\"}},\"isLooped\":false}]}",
    types.jira_transitions_decoder(),
  )
  |> should.equal(
    Ok([
      types.Transition("11", "To Do", "To Do", []),
      types.Transition("41", "Done", "Done", []),
    ]),
  )
}

pub fn transition_with_required_resolution_test() {
  // Company-managed workflows carry a transition screen: {fields: [...]}.
  json.parse(
    "{\"transitions\":[{\"id\":\"31\",\"name\":\"Done\",\"to\":{\"name\":\"Done\"},\"fields\":[{\"required\":true,\"name\":\"Resolution\",\"key\":\"resolution\"},{\"required\":false,\"key\":\"comment\"}]}]}",
    types.jira_transitions_decoder(),
  )
  |> should.equal(
    Ok([
      types.Transition("31", "Done", "Done", [
        types.TransitionField("resolution", True),
        types.TransitionField("comment", False),
      ]),
    ]),
  )

  let assert Ok([transition]) =
    json.parse(
      "{\"transitions\":[{\"id\":\"31\",\"name\":\"Done\",\"to\":{\"name\":\"Done\"},\"fields\":[{\"required\":true,\"key\":\"resolution\"}]}]}",
      types.jira_transitions_decoder(),
    )

  // the picker's chosen resolution goes into the POST body...
  web.transition_post_body(transition, Some("Done"))
  |> should.equal(Ok(
    "{\"transition\":{\"id\":\"31\"},\"fields\":{\"resolution\":{\"name\":\"Done\"}}}",
  ))

  web.transition_post_body(transition, Some("Won't Do"))
  |> should.equal(Ok(
    "{\"transition\":{\"id\":\"31\"},\"fields\":{\"resolution\":{\"name\":\"Won't Do\"}}}",
  ))

  // ...and a missing resolution is refused before any request is sent.
  web.transition_post_body(transition, None)
  |> should.be_error

  // …and never reported as an unexpected requirement; other required
  // fields are refused up front.
  web.unexpected_required_fields(transition)
  |> should.equal([])
}

pub fn transition_post_body_plain_test() {
  let transition = types.Transition("21", "In Progress", "In Progress", [])
  web.transition_post_body(transition, None)
  |> should.equal(Ok("{\"transition\":{\"id\":\"21\"}}"))
}

pub fn resolutions_decoder_test() {
  json.parse(
    "[{\"id\":\"1\",\"name\":\"Done\",\"description\":\"Work is complete\"},{\"id\":\"2\",\"name\":\"Won't Do\",\"description\":\"Not planned\"}]",
    types.resolutions_decoder(),
  )
  |> should.equal(
    Ok([
      types.Resolution("1", "Done"),
      types.Resolution("2", "Won't Do"),
    ]),
  )
}

// Phase 4: write request bodies + routes

pub fn parse_write_bodies_test() {
  web.parse_transition_body("{\"id\": \"41\"}")
  |> should.equal(Ok(#("41", None)))

  web.parse_transition_body("{\"id\": \"41\", \"resolution\": \"Duplicate\"}")
  |> should.equal(Ok(#("41", Some("Duplicate"))))

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

pub fn comment_post_body_test() {
  let text = "# Notes\n- did a thing"
  json.parse(
    web.comment_post_body(text),
    decode.field("body", adf.adf_decoder(), decode.success),
  )
  |> should.equal(Ok(adf.basic_document(text)))
}

// summary: request parsing + the Jira edit-issue body

pub fn parse_summary_body_test() {
  web.parse_summary_body("{\"summary\": \"  New summary  \"}")
  |> should.equal(Ok("New summary"))

  web.parse_summary_body("{\"summary\": \"   \"}")
  |> should.be_error

  web.parse_summary_body("{}")
  |> should.be_error

  web.parse_summary_body("{\"summary\": 42}")
  |> should.be_error
}

pub fn summary_update_body_test() {
  web.summary_update_body("New summary")
  |> should.equal("{\"fields\":{\"summary\":\"New summary\"}}")
}

pub fn summary_route_bad_body_test() {
  let request =
    local_request(http.Put, "/jira/issue/KAN-1/summary")
    |> simulate.json_body(json.object([#("summary", json.string("  "))]))
  web.handle_request(request).status |> should.equal(400)
}

pub fn summary_route_requires_put_test() {
  web.handle_request(local_request(http.Get, "/jira/issue/KAN-1/summary")).status
  |> should.equal(405)
}

pub fn summary_route_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let request =
    local_request(http.Put, "/jira/issue/KAN-1/summary")
    |> simulate.json_body(
      json.object([#("summary", json.string("New summary"))]),
    )
  web.handle_request(request).status |> should.equal(502)
}

// Open in Jira: a local redirect, never a leaked base URL in the UI

pub fn open_issue_redirects_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://acme.atlassian.net")
  let resp =
    web.handle_request(local_request(http.Get, "/jira/issue/KAN-1/open"))
  resp.status |> should.equal(303)
  resp.headers
  |> list.key_find("location")
  |> should.equal(Ok("https://acme.atlassian.net/browse/KAN-1"))
}

// labels: request parsing + the Jira edit-issue body

pub fn parse_labels_body_test() {
  web.parse_labels_body("{\"labels\": [\"a\", \" b \", \"a\"]}")
  |> should.equal(Ok(["a", "b"]))

  web.parse_labels_body("{\"labels\": []}")
  |> should.equal(Ok([]))

  web.parse_labels_body("{\"labels\": [\"\"]}")
  |> should.be_error

  web.parse_labels_body("{\"labels\": [\"two words\"]}")
  |> should.be_error

  web.parse_labels_body("{\"tags\": []}")
  |> should.be_error
}

pub fn labels_update_body_test() {
  web.labels_update_body(["a", "b"])
  |> should.equal("{\"fields\":{\"labels\":[\"a\",\"b\"]}}")
}

pub fn labels_route_bad_body_test() {
  let request =
    local_request(http.Put, "/jira/issue/KAN-1/labels")
    |> simulate.json_body(
      json.object([
        #("labels", json.array(["two words"], json.string)),
      ]),
    )
  web.handle_request(request).status |> should.equal(400)
}

pub fn labels_route_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let request =
    local_request(http.Put, "/jira/issue/KAN-1/labels")
    |> simulate.json_body(
      json.object([#("labels", json.array(["docs"], json.string))]),
    )
  web.handle_request(request).status |> should.equal(502)
}

// flagged: request parsing, both field shapes, and the proxy route

pub fn parse_flagged_body_test() {
  web.parse_flagged_body("{\"flagged\": true}")
  |> should.equal(Ok(True))

  web.parse_flagged_body("{\"flagged\": false}")
  |> should.equal(Ok(False))

  web.parse_flagged_body("{\"flagged\": \"yes\"}")
  |> should.be_error

  web.parse_flagged_body("{}")
  |> should.be_error
}

pub fn flagged_update_body_test() {
  web.flagged_update_body(
    jira.FlagField("customfield_10300", jira.OptionField),
    jira.FlagOption("value", "Impediment"),
    True,
  )
  |> should.equal(
    "{\"fields\":{\"customfield_10300\":[{\"value\":\"Impediment\"}]}}",
  )

  web.flagged_update_body(
    jira.FlagField("customfield_10300", jira.OptionField),
    jira.FlagOption("id", "10019"),
    True,
  )
  |> should.equal("{\"fields\":{\"customfield_10300\":[{\"id\":\"10019\"}]}}")

  web.flagged_update_body(
    jira.FlagField("customfield_10300", jira.OptionField),
    jira.FlagOption("value", "Impediment"),
    False,
  )
  |> should.equal("{\"fields\":{\"customfield_10300\":[]}}")

  web.flagged_update_body(
    jira.FlagField("customfield_10300", jira.BooleanField),
    jira.FlagOption("value", ""),
    True,
  )
  |> should.equal("{\"fields\":{\"customfield_10300\":true}}")

  web.flagged_update_body(
    jira.FlagField("customfield_10300", jira.BooleanField),
    jira.FlagOption("value", ""),
    False,
  )
  |> should.equal("{\"fields\":{\"customfield_10300\":false}}")
}

pub fn flagged_route_bad_body_test() {
  let request =
    local_request(http.Put, "/jira/issue/KAN-1/flagged")
    |> simulate.json_body(json.object([#("flagged", json.string("yes"))]))
  web.handle_request(request).status |> should.equal(400)
}

pub fn flagged_route_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  envoy.set("JIRA_FLAGGED_FIELD", "customfield_10021")
  envoy.set("JIRA_FLAGGED_VALUE", "Impediment")
  let request =
    local_request(http.Put, "/jira/issue/KAN-1/flagged")
    |> simulate.json_body(json.object([#("flagged", json.bool(True))]))
  web.handle_request(request).status |> should.equal(502)
  envoy.unset("JIRA_FLAGGED_FIELD")
  envoy.unset("JIRA_FLAGGED_VALUE")
}

// assignee: request parsing, the Jira assign body, and the candidate proxy

pub fn parse_assignee_body_test() {
  web.parse_assignee_body("{\"account_id\": \" 557058:abc \"}")
  |> should.equal(Ok(Some("557058:abc")))

  web.parse_assignee_body("{\"account_id\": null}")
  |> should.equal(Ok(None))

  web.parse_assignee_body("{}")
  |> should.equal(Ok(None))

  web.parse_assignee_body("{\"account_id\": \"\"}")
  |> should.equal(Ok(None))

  web.parse_assignee_body("{\"account_id\": 42}")
  |> should.be_error
}

pub fn assignee_update_body_test() {
  web.assignee_update_body(Some("557058:abc"))
  |> should.equal("{\"accountId\":\"557058:abc\"}")

  web.assignee_update_body(None)
  |> should.equal("{\"accountId\":null}")
}

pub fn assignee_route_bad_body_test() {
  let request =
    local_request(http.Put, "/jira/issue/KAN-1/assignee")
    |> simulate.json_body(json.object([#("account_id", json.int(42))]))
  web.handle_request(request).status |> should.equal(400)
}

pub fn assignee_route_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let request =
    local_request(http.Put, "/jira/issue/KAN-1/assignee")
    |> simulate.json_body(
      json.object([#("account_id", json.string("557058:abc"))]),
    )
  web.handle_request(request).status |> should.equal(502)
}

pub fn assignable_route_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  web.handle_request(local_request(http.Get, "/jira/issue/KAN-1/assignable")).status
  |> should.equal(502)
}

pub fn transition_post_route_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let request =
    local_request(http.Post, "/jira/issue/KAN-1/transition")
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
    local_request(http.Post, "/jira/issue/KAN-1/transition")
    |> simulate.json_body(json.null())
  web.handle_request(bad_transition).status |> should.equal(400)

  let bad_comment =
    local_request(http.Post, "/jira/issue/KAN-1/comment")
    |> simulate.json_body(json.object([#("nope", json.string("hi"))]))
  web.handle_request(bad_comment).status |> should.equal(400)

  let bad_worklog =
    local_request(http.Post, "/jira/issue/KAN-1/worklog")
    |> simulate.json_body(json.object([#("x", json.string(""))]))
  web.handle_request(bad_worklog).status |> should.equal(400)
}

// Phase 5: views seeding + CRUD

pub fn db_views_seeded_on_fresh_db_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let assert Ok(conn) = db.open()
  let assert Ok(_) = db.migrate(conn)

  db.list_views(conn)
  |> should.be_ok
  |> should.equal([
    types.ViewDef(
      id: "my-issues",
      name: "My issues",
      source: types.Jql(
        "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
      ),
      columns: db.default_columns(),
    ),
  ])

  // second migrate (the per-request pattern) must not re-seed
  let assert Ok(_) = db.migrate(conn)
  db.list_views(conn)
  |> should.be_ok
  |> list.length
  |> should.equal(1)
}

pub fn db_deleting_all_views_does_not_reseed_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let assert Ok(conn) = db.open()
  let assert Ok(_) = db.migrate(conn)

  db.delete_view(conn, "my-issues") |> should.be_ok

  // an existing database stays empty; only a first-time table gets the seed
  let assert Ok(_) = db.migrate(conn)
  db.list_views(conn)
  |> should.be_ok
  |> should.equal([])
}

pub fn db_view_crud_round_trip_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let assert Ok(conn) = db.open()
  let assert Ok(_) = db.migrate(conn)

  let view =
    types.ViewDef(
      id: "q3-sprint",
      name: "Q3 Sprint",
      source: types.Board(12),
      columns: ["key", "summary", "status"],
    )
  db.create_view(conn, view) |> should.be_ok
  db.get_view(conn, "q3-sprint") |> should.equal(Ok(view))

  // update keeps id + ordering, replaces the rest (board -> jql here)
  let updated =
    types.ViewDef(
      id: "q3-sprint",
      name: "Q3 Sprint (renamed)",
      source: types.Jql("project = SAM1"),
      columns: ["key", "summary", "assignee"],
    )
  db.update_view(conn, "q3-sprint", updated) |> should.be_ok
  db.get_view(conn, "q3-sprint") |> should.equal(Ok(updated))

  db.get_view(conn, "missing") |> should.equal(Error(db.NotFound))
  db.update_view(conn, "missing", updated)
  |> should.equal(Error(db.NotFound))

  // deletion cascades to the private ordering rows
  let assert Ok(_) = db.save_view_order(conn, "q3-sprint", ["KAN-2", "KAN-1"])
  db.delete_view(conn, "q3-sprint") |> should.be_ok
  db.get_view(conn, "q3-sprint") |> should.equal(Error(db.NotFound))
  db.load_view_order(conn, "q3-sprint")
  |> should.be_ok
  |> should.equal([])
}

pub fn unique_view_id_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let assert Ok(conn) = db.open()
  let assert Ok(_) = db.migrate(conn)

  db.unique_view_id(conn, "Q3 Sprint!")
  |> should.equal("q3-sprint")
  // names that slug to nothing fall back to "view"
  db.unique_view_id(conn, "///")
  |> should.equal("view")

  let assert Ok(_) =
    db.create_view(
      conn,
      types.ViewDef(
        id: "q3-sprint",
        name: "Q3 Sprint",
        source: types.Board(1),
        columns: db.default_columns(),
      ),
    )
  db.unique_view_id(conn, "Q3 Sprint?")
  |> should.equal("q3-sprint-2")

  let assert Ok(_) =
    db.create_view(
      conn,
      types.ViewDef(
        id: "q3-sprint-2",
        name: "Q3 Sprint2",
        source: types.Board(2),
        columns: db.default_columns(),
      ),
    )
  db.unique_view_id(conn, "Q3 Sprint")
  |> should.equal("q3-sprint-3")
}

// Phase 5: agile + attachment decoders

pub fn boards_page_decoder_test() {
  json.parse(
    "{\"maxResults\":50,\"startAt\":0,\"total\":2,\"values\":[{\"id\":1,\"name\":\"SAM board\",\"type\":\"scrum\",\"location\":{}},{\"id\":2,\"name\":\"KAN board\",\"type\":\"kanban\"}]}",
    types.boards_page_decoder(),
  )
  |> should.equal(
    Ok(#(
      [
        types.AgileBoard(1, "SAM board", "scrum"),
        types.AgileBoard(2, "KAN board", "kanban"),
      ],
      2,
    )),
  )
}

pub fn agile_page_decoder_test() {
  json.parse(
    "{\"startAt\":0,\"maxResults\":100,\"total\":1,\"issues\":[{\"id\":\"10011\",\"key\":\"KAN-2\",\"fields\":{\"summary\":\"Task 2\",\"status\":{\"name\":\"In Progress\",\"statusCategory\":{\"key\":\"indeterminate\"}},\"updated\":\"2026-10-18\"}}]}",
    types.agile_page_decoder(flagged_field),
  )
  |> should.equal(
    Ok(#(
      [
        types.Issue(
          key: "KAN-2",
          id: "10011",
          summary: "Task 2",
          status: types.Status("In Progress", "indeterminate"),
          assignee: None,
          labels: [],
          flagged: False,
          updated: "2026-10-18",
        ),
      ],
      1,
    )),
  )
}

pub fn attachment_decoder_test() {
  json.parse(
    "{\"id\":\"10001\",\"filename\":\"screenshot.png\",\"mimeType\":\"image/png\",\"size\":2048,\"created\":\"2026\",\"content\":\"https://x\"}",
    types.attachment_decoder(),
  )
  |> should.equal(
    Ok(types.Attachment(
      id: "10001",
      filename: "screenshot.png",
      mime_type: "image/png",
      size: 2048,
    )),
  )
}

pub fn attachment_headers_test() {
  // safe raster images may render inline
  web.attachment_headers("image/png")
  |> should.equal([
    #("content-type", "image/png"),
    #("x-content-type-options", "nosniff"),
  ])

  web.attachment_headers("image/png; charset=binary")
  |> should.equal([
    #("content-type", "image/png; charset=binary"),
    #("x-content-type-options", "nosniff"),
  ])

  // HTML and SVG could run script on the app's origin: force a download
  web.attachment_headers("text/html")
  |> should.equal([
    #("content-type", "text/html"),
    #("x-content-type-options", "nosniff"),
    #("content-disposition", "attachment"),
  ])

  web.attachment_headers("image/svg+xml")
  |> should.equal([
    #("content-type", "image/svg+xml"),
    #("x-content-type-options", "nosniff"),
    #("content-disposition", "attachment"),
  ])
}

pub fn view_json_round_trip_test() {
  let view =
    types.ViewDef(
      id: "board-1",
      name: "Board 1",
      source: types.Board(42),
      columns: ["key", "summary"],
    )
  json.parse(json.to_string(types.view_to_json(view)), types.app_view_decoder())
  |> should.equal(Ok(view))

  let jql_view =
    types.ViewDef(
      id: "v",
      name: "V",
      source: types.Jql("project = SAM1"),
      columns: db.default_columns(),
    )
  json.parse(
    json.to_string(types.view_to_json(jql_view)),
    types.app_view_decoder(),
  )
  |> should.equal(Ok(jql_view))
}

// Phase 5: view routes

/// The routes share one file-backed db (a `:memory:` db is per-connection),
/// which also persists across test RUNS — so assertions are tolerant of
/// leftovers and every creating test cleans up after itself.
pub fn views_list_seeded_route_test() {
  envoy.set("JIRA_VIEW_DB", "views-route-test.db")
  let resp = web.handle_request(local_request(http.Get, "/jira/views"))
  resp.status |> should.equal(200)

  let assert Ok(views) =
    simulate.read_body(resp)
    |> json.parse(decode.field(
      "views",
      decode.list(types.app_view_decoder()),
      decode.success,
    ))
  // the seeded default view always exists
  list.any(views, fn(view) { view.id == "my-issues" })
  |> should.be_true
}

pub fn view_create_update_delete_route_test() {
  envoy.set("JIRA_VIEW_DB", "views-route-test.db")

  // tolerate leftovers from earlier runs: recreate the same slug cleanly
  let _ =
    web.handle_request(local_request(http.Delete, "/jira/views/sprint-view"))

  // create: unique slug id is assigned server-side
  let created =
    web.handle_request(
      local_request(http.Post, "/jira/views")
      |> simulate.json_body(
        json.object([
          #("name", json.string("Sprint view")),
          #("board_id", json.int(1)),
        ]),
      ),
    )
  created.status |> should.equal(201)
  let assert Ok(view) =
    simulate.read_body(created) |> json.parse(types.app_view_decoder())
  view.name |> should.equal("Sprint view")
  view.id |> should.equal("sprint-view")
  view.source
  |> should.equal(types.Board(1))

  // update it
  let put =
    web.handle_request(
      local_request(http.Put, "/jira/views/sprint-view")
      |> simulate.json_body(
        json.object([
          #("name", json.string("Sprint view (done)")),
          #("jql", json.string("project = SAM1")),
          #("columns", json.array(["key", "summary"], json.string)),
        ]),
      ),
    )
  put.status |> should.equal(200)

  // delete it; further deletes 404
  let deleted =
    web.handle_request(local_request(http.Delete, "/jira/views/sprint-view"))
  deleted.status |> should.equal(200)
  let deleted_again =
    web.handle_request(local_request(http.Delete, "/jira/views/sprint-view"))
  deleted_again.status |> should.equal(404)
}

pub fn view_create_rejects_bad_bodies_test() {
  envoy.set("JIRA_VIEW_DB", "views-route-test.db")

  let neither =
    web.handle_request(
      local_request(http.Post, "/jira/views")
      |> simulate.json_body(json.object([#("name", json.string("x"))])),
    )
  neither.status |> should.equal(400)

  let both =
    web.handle_request(
      local_request(http.Post, "/jira/views")
      |> simulate.json_body(
        json.object([
          #("name", json.string("x")),
          #("jql", json.string("project = X")),
          #("board_id", json.int(1)),
        ]),
      ),
    )
  both.status |> should.equal(400)

  let empty_name =
    web.handle_request(
      local_request(http.Post, "/jira/views")
      |> simulate.json_body(
        json.object([#("name", json.string("")), #("jql", json.string("x"))]),
      ),
    )
  empty_name.status |> should.equal(400)
}

pub fn view_update_missing_route_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let resp =
    web.handle_request(
      local_request(http.Put, "/jira/views/nope")
      |> simulate.json_body(
        json.object([
          #("name", json.string("Nope")),
          #("jql", json.string("project = X")),
        ]),
      ),
    )
  resp.status |> should.equal(404)
}

pub fn order_patch_missing_view_route_test() {
  envoy.set("JIRA_VIEW_DB", ":memory:")
  let resp =
    web.handle_request(
      local_request(http.Patch, "/jira/views/nope/order")
      |> simulate.json_body(
        json.object([#("keys", json.array(["KAN-1"], json.string))]),
      ),
    )
  resp.status |> should.equal(404)
}

// Phase 5: board/avatar/attachment routes (unreachable-Jira happy 502s)

pub fn boards_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp = web.handle_request(local_request(http.Get, "/jira/boards"))
  resp.status |> should.equal(502)
}

pub fn resolutions_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp = web.handle_request(local_request(http.Get, "/jira/resolutions"))
  resp.status |> should.equal(502)
}

pub fn board_issues_bad_board_id_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let request = local_request(http.Get, "/jira/board/notanumber/issues")
  web.handle_request(request).status |> should.equal(400)
}

pub fn board_issues_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let request = local_request(http.Get, "/jira/board/1/issues?view=my-issues")
  web.handle_request(request).status |> should.equal(502)
}

pub fn attachment_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp =
    web.handle_request(local_request(http.Get, "/jira/attachment/10001"))
  resp.status |> should.equal(502)
}

pub fn avatar_unreachable_test() {
  envoy.set("JIRA_EMAIL", "jeff@example.com")
  envoy.set("JIRA_API_TOKEN", "test-token")
  envoy.set("JIRA_BASE_URL", "https://127.0.0.1:1")
  let resp =
    web.handle_request(local_request(http.Get, "/jira/avatar/5a67cc62"))
  resp.status |> should.equal(502)
}
