//// Web router: Wisp handlers. Serves the auth-proving endpoint, the
//// paginated Jira search proxy (which writes every fetch into the SQLite
//// cache and returns the view's merged ordering), the issue-detail
//// passthrough, the transitions/transition/comment/worklog write
//// endpoints, the private per-view ordering endpoint, and the built
//// frontend bundle.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{path_segments}
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import jira_view/config
import jira_view/db
import jira_view/jira
import shared/adf
import shared/types
import wisp

pub fn handle_request(request: wisp.Request) -> wisp.Response {
  use <- wisp.serve_static(request, under: "/assets", from: "assets")
  use <- wisp.log_request(request)
  case path_segments(request) {
    [] -> wisp.redirect("/assets/index.html")
    ["api", "me"] -> wisp.require_method(request, http.Get, me)
    ["jira", "search"] ->
      wisp.require_method(request, http.Get, fn() { search(request) })
    ["jira", "issue", key] ->
      wisp.require_method(request, http.Get, fn() { issue(key) })
    ["jira", "issue", key, "transitions"] ->
      wisp.require_method(request, http.Get, fn() { issue_transitions(key) })
    ["jira", "issue", key, "transition"] ->
      wisp.require_method(request, http.Post, fn() { transition(request, key) })
    ["jira", "issue", key, "comment"] ->
      wisp.require_method(request, http.Post, fn() { comment(request, key) })
    ["jira", "issue", key, "worklog"] ->
      wisp.require_method(request, http.Post, fn() { worklog(request, key) })
    ["jira", "views", view_id, "order"] ->
      wisp.require_method(request, http.Patch, fn() { save_order(request, view_id) })
    _ -> wisp.not_found()
  }
}

/// Proves Jira credentials: proxies GET /rest/api/3/myself.
fn me() -> wisp.Response {
  case config.load() {
    Error(message) -> json_error("configuration_incomplete", message, 503)
    Ok(cfg) ->
      case jira.myself(cfg) {
        Ok(me) -> wisp.json_response(json.to_string(types.me_to_json(me)), 200)
        Error(error) -> jira_error_response(error)
      }
  }
}

/// Search proxy: GET /jira/search?jql=... follows every search page from
/// Jira, writes the issues into the cache, and returns the list in the
/// view's merged order — rows the view has privately ordered keep that
/// order, anything new is appended (see db.merge_view_order). The `view`
/// query parameter names the view; until Phase 5's saved views there is
/// exactly one: "my-issues".
fn search(request: wisp.Request) -> wisp.Response {
  case list.key_find(wisp.get_query(request), "jql") {
    Error(_) ->
      json_error("missing_parameter", "required query parameter: jql", 400)
    Ok(jql) -> {
      let view_id = case list.key_find(wisp.get_query(request), "view") {
        Ok(view_id) -> view_id
        Error(_) -> default_view_id
      }
      case config.load() {
        Error(message) -> json_error("configuration_incomplete", message, 503)
        Ok(cfg) ->
          case jira.search(cfg, jql) {
            Ok(issues) ->
              case cache_and_merge(issues, view_id) {
                Ok(ordered) ->
                  json.object([
                    #("issues", json.array(ordered, types.issue_to_json)),
                  ])
                  |> json.to_string
                  |> wisp.json_response(200)
                Error(error) ->
                  json_error("cache_write_failed", string.inspect(error), 500)
              }
            Error(error) -> jira_error_response(error)
          }
      }
    }
  }
}

const default_view_id = "my-issues"

/// Fetches own the connection: open, migrate, upsert the fresh issues, then
/// read the view's private ordering and merge it over the fetched order.
fn cache_and_merge(
  issues: List(types.Issue),
  view_id: String,
) -> Result(List(types.Issue), db.DbError) {
  use conn <- result.try(db.open())
  use _ <- result.try(db.migrate(conn))
  use _ <- result.try(db.upsert_issues(conn, issues))
  use saved <- result.try(db.load_view_order(conn, view_id))
  Ok(db.merge_view_order(saved, issues))
}

/// PATCH /jira/views/:view/order — persist the private ordering the browser
/// sent as {"keys": ["A-1", "A-2", ...]} (the full row order, so appended
/// issues join the ordering at the same moment they are first dropped).
fn save_order(request: wisp.Request, view_id: String) -> wisp.Response {
  use <- wisp.require_content_type(request, "application/json")
  use body <- wisp.require_string_body(request)
  case parse_order_body(body) {
    Ok([]) ->
      json_error(
        "empty_order",
        "keys must contain at least one issue key; "
          <> "a view with no rows needs no saved order",
        400,
      )
    Ok(keys) ->
      case store_order(view_id, keys) {
        Ok(count) ->
          json.object([
            #("saved", json.bool(True)),
            #("view_id", json.string(view_id)),
            #("count", json.int(count)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
        Error(error) ->
          json_error("order_write_failed", string.inspect(error), 500)
      }
    Error(message) -> json_error("bad_request", message, 400)
  }
}

/// The ordering request shape, decoded and validated. Exposed for tests.
pub fn parse_order_body(body: String) -> Result(List(String), String) {
  case json.parse(body, order_body_decoder()) {
    Ok(keys) -> Ok(keys)
    Error(_) -> Error("expected {\"keys\": [\"KEY\", ...] } JSON")
  }
}

fn order_body_decoder() -> decode.Decoder(List(String)) {
  use keys <- decode.field("keys", decode.list(decode.string))
  decode.success(keys)
}

fn store_order(view_id: String, keys: List(String)) -> Result(Int, db.DbError) {
  use conn <- result.try(db.open())
  use _ <- result.try(db.migrate(conn))
  use _ <- result.try(db.save_view_order(conn, view_id, keys))
  Ok(list.length(keys))
}

// ————— writes (Phase 4) —————

/// GET /jira/issue/:key/transitions — passthrough of the transitions
/// metadata (plan gotcha: fetched per issue, required fields vary); the
/// browser renders one button per transition.
fn issue_transitions(key: String) -> wisp.Response {
  case config.load() {
    Error(message) -> json_error("configuration_incomplete", message, 503)
    Ok(cfg) ->
      case jira.get(cfg, jira.transitions_path(key)) {
        Ok(body) -> wisp.json_response(body, 200)
        Error(error) -> jira_error_response(error)
      }
  }
}

/// POST /jira/issue/:key/transition — body {"id": "31"}. The transitions
/// metadata is read fresh on this call; the metadata drives two behaviours:
/// the common required field (`resolution`, company-managed "Done") is
/// auto-filled, and transitions needing other screen input the UI does not
/// collect yet are refused with 400 instead of Jira's raw screen error.
fn transition(request: wisp.Request, key: String) -> wisp.Response {
  use <- wisp.require_content_type(request, "application/json")
  use body <- wisp.require_string_body(request)
  case parse_transition_body(body) {
    Error(message) -> json_error("bad_request", message, 400)
    Ok(id) ->
      case config.load() {
        Error(message) -> json_error("configuration_incomplete", message, 503)
        Ok(cfg) ->
          case jira.get(cfg, jira.transitions_path(key)) {
            Error(error) -> jira_error_response(error)
            Ok(meta) ->
              case json.parse(meta, types.jira_transitions_decoder()) {
                Error(error) ->
                  json_error("decode_failed", string.inspect(error), 502)
                Ok(transitions) ->
                  case list.find(transitions, fn(t) { t.id == id }) {
                    Error(_) ->
                      json_error(
                        "unknown_transition",
                        "no transition " <> id <> " on issue " <> key,
                        400,
                      )
                    Ok(t) ->
                      case unexpected_required_fields(t) {
                        [_, ..] as fields ->
                          json_error(
                            "transition_requires_fields",
                            "transition " <> t.name <> " requires input the "
                              <> "UI does not collect yet: "
                              <> string.join(fields, ", "),
                            400,
                          )
                        [] ->
                          case
                            jira.post(
                              cfg,
                              jira.transitions_path(key),
                              transition_post_body(t),
                            )
                          {
                            Ok(_) ->
                              json.object([
                                #("applied", json.bool(True)),
                                #("status", json.string(t.to_status)),
                              ])
                              |> json.to_string
                              |> wisp.json_response(200)
                            Error(error) -> jira_error_response(error)
                          }
                      }
                  }
              }
          }
      }
  }
}

/// Required transition-screen fields this app does not auto-fill.
/// Exposed for tests.
pub fn unexpected_required_fields(
  transition: types.Transition,
) -> List(String) {
  transition.fields
  |> list.filter(fn(field) { field.required && field.key != "resolution" })
  |> list.map(fn(field) { field.key })
}

/// The POST body Jira expects for a transition; `resolution` is auto-filled
/// when the workflow's screen requires it. Exposed for tests.
pub fn transition_post_body(transition: types.Transition) -> String {
  let requires_resolution =
    list.any(transition.fields, fn(field) {
      field.required && field.key == "resolution"
    })
  let fields = case requires_resolution {
    False -> []
    True -> [
      #(
        "fields",
        json.object([
          #("resolution", json.object([#("name", json.string("Done"))])),
        ]),
      ),
    ]
  }
  json.object([
    #("transition", json.object([#("id", json.string(transition.id))])),
    ..fields
  ])
  |> json.to_string
}

/// The transition request body shape `{"id": "…"}`. Exposed for tests.
pub fn parse_transition_body(body: String) -> Result(String, String) {
  case json.parse(body, decode.field("id", decode.string, decode.success)) {
    Ok(id) -> Ok(id)
    Error(_) -> Error("expected {\"id\": \"<transition id>\"} JSON")
  }
}

/// POST /jira/issue/:key/comment — body {"text": "…"}. The text is wrapped
/// into an ADF document, posted, and the created comment is returned pruned:
/// {"comment": {author, created, body: [ADF…]}}.
fn comment(request: wisp.Request, key: String) -> wisp.Response {
  use <- wisp.require_content_type(request, "application/json")
  use body <- wisp.require_string_body(request)
  case parse_comment_body(body) {
    Error(message) -> json_error("bad_request", message, 400)
    Ok("") -> json_error("empty_comment", "text must not be empty", 400)
    Ok(text) ->
      case config.load() {
        Error(message) -> json_error("configuration_incomplete", message, 503)
        Ok(cfg) -> {
          let document =
            json.object([
              #("body", adf.adf_to_json(adf.paragraph_document(text))),
            ])
            |> json.to_string
          case jira.post(cfg, jira.comment_path(key), document) {
            Ok(response) ->
              case json.parse(response, types.jira_comment_decoder()) {
                Ok(created) ->
                  json.object([#("comment", types.comment_to_json(created))])
                  |> json.to_string
                  |> wisp.json_response(200)
                Error(error) ->
                  json_error("decode_failed", string.inspect(error), 502)
              }
            Error(error) -> jira_error_response(error)
          }
        }
      }
  }
}

/// The comment request body shape {"text": "…"}. Exposed for tests.
pub fn parse_comment_body(body: String) -> Result(String, String) {
  case json.parse(body, decode.field("text", decode.string, decode.success)) {
    Ok(text) -> Ok(string.trim(text))
    Error(_) -> Error("expected {\"text\": \"…\"} JSON")
  }
}

/// POST /jira/issue/:key/worklog — body {"time_spent": "25m"} (Jira's
/// time format). `started` is left to Jira (defaults to now). The created
/// entry is returned pruned: {"worklog": {author, started, time_spent, …}}.
fn worklog(request: wisp.Request, key: String) -> wisp.Response {
  use <- wisp.require_content_type(request, "application/json")
  use body <- wisp.require_string_body(request)
  case parse_worklog_body(body) {
    Error(message) -> json_error("bad_request", message, 400)
    Ok("") -> json_error("empty_worklog", "time_spent must not be empty", 400)
    Ok(time_spent) ->
      case config.load() {
        Error(message) -> json_error("configuration_incomplete", message, 503)
        Ok(cfg) -> {
          let document =
            json.object([#("timeSpent", json.string(time_spent))])
            |> json.to_string
          case jira.post(cfg, jira.worklog_path(key), document) {
            Ok(response) ->
              case json.parse(response, types.jira_worklog_decoder()) {
                Ok(created) ->
                  json.object([#("worklog", types.worklog_to_json(created))])
                  |> json.to_string
                  |> wisp.json_response(200)
                Error(error) ->
                  json_error("decode_failed", string.inspect(error), 502)
              }
            Error(error) -> jira_error_response(error)
          }
        }
      }
  }
}

/// The worklog request body shape {"time_spent": "…"}. Exposed for tests.
pub fn parse_worklog_body(body: String) -> Result(String, String) {
  case json.parse(body, decode.field("time_spent", decode.string, decode.success)) {
    Ok(time_spent) -> Ok(string.trim(time_spent))
    Error(_) -> Error("expected {\"time_spent\": \"…\"} JSON")
  }
}

/// Issue detail data for the UI panel: fetch
/// GET /rest/api/3/issue/:key?fields=... and pass the raw JSON through —
/// the browser decodes it with the shared issue_detail decoder.
/// shortcut: detail is fetched fresh on every open, not cached; add a
/// description column to the cache when cached-only detail reads matter.
fn issue(key: String) -> wisp.Response {
  case config.load() {
    Error(message) -> json_error("configuration_incomplete", message, 503)
    Ok(cfg) ->
      case
        jira.get_with_query(cfg, jira.issue_path(key), [
          #("fields", jira.issue_fields),
        ])
      {
        Ok(body) -> wisp.json_response(body, 200)
        Error(error) -> jira_error_response(error)
      }
  }
}

/// Uniform JiraError → HTTP status mapping, shared by all Jira endpoints.
fn jira_error_response(error: jira.JiraError) -> wisp.Response {
  case error {
    jira.Api(401, body) ->
      json_error(
        "unauthorized",
        "Jira rejected the credentials. Check JIRA_EMAIL, "
          <> "JIRA_API_TOKEN and JIRA_BASE_URL. Jira said: "
          <> clip(body),
        401,
      )
    jira.Api(status, body) ->
      json_error(
        "jira_api_error",
        int.to_string(status) <> ": " <> clip(body),
        502,
      )
    jira.Http(error) ->
      json_error("jira_unreachable", string.inspect(error), 502)
    jira.Decode(error) ->
      json_error("decode_failed", string.inspect(error), 502)
  }
}

/// Keep Jira error bodies short in responses.
fn clip(body: String) -> String {
  string.slice(body, 0, 300)
}

fn json_error(kind: String, detail: String, status: Int) -> wisp.Response {
  json.object([
    #("error", json.string(kind)),
    #("detail", json.string(detail)),
  ])
  |> json.to_string
  |> wisp.json_response(status)
}
