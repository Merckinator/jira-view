//// Web router: Wisp handlers. Serves the auth-proving endpoint, the
//// paginated Jira search proxy (returned in the view's merged ordering), the
//// issue-detail passthrough, the transitions/transition/comment/worklog write
//// endpoints, the private per-view ordering endpoint, and the built
//// frontend bundle.

import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{get_header, path_segments}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import jira_view/config
import jira_view/db
import jira_view/jira
import shared/adf
import shared/types
import sqlight
import wisp

pub fn handle_request(request: wisp.Request) -> wisp.Response {
  case is_local_host(request) {
    False ->
      json_error("invalid_host", "Host must be 127.0.0.1 or localhost", 400)
    True -> handle_local_request(request)
  }
}

/// The app is only meant to be opened at 127.0.0.1 or localhost. Rejecting
/// other Host headers blocks DNS-rebinding pages from reading the API.
fn is_local_host(request: wisp.Request) -> Bool {
  case get_header(request, "host") {
    Ok(host) -> list.contains(["127.0.0.1", "localhost"], host_name(host))
    Error(_) -> False
  }
}

fn host_name(host: String) -> String {
  case string.split(host, ":") {
    [name, ..] -> string.lowercase(name)
    [] -> string.lowercase(host)
  }
}

fn handle_local_request(request: wisp.Request) -> wisp.Response {
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
    ["jira", "attachment", attachment_id] ->
      wisp.require_method(request, http.Get, fn() { attachment(attachment_id) })
    ["jira", "avatar", account_id] ->
      wisp.require_method(request, http.Get, fn() { avatar(account_id) })
    ["jira", "board", board_id, "issues"] ->
      wisp.require_method(request, http.Get, fn() {
        board_issues(request, board_id)
      })
    ["jira", "boards"] -> wisp.require_method(request, http.Get, boards)
    ["jira", "resolutions"] ->
      wisp.require_method(request, http.Get, resolutions)
    ["jira", "views"] -> views_endpoint(request)
    ["jira", "views", view_id] -> view_endpoint(request, view_id)
    ["jira", "views", view_id, "order"] ->
      wisp.require_method(request, http.Patch, fn() { save_order(request, view_id) })
    _ -> wisp.not_found()
  }
}

/// /jira/views is a collection endpoint: GET lists, POST creates.
fn views_endpoint(request: wisp.Request) -> wisp.Response {
  case request.method {
    http.Get -> list_views()
    http.Post -> create_view(request)
    _ -> wisp.method_not_allowed([http.Get, http.Post])
  }
}

/// /jira/views/:id: PUT updates, DELETE removes.
fn view_endpoint(request: wisp.Request, view_id: String) -> wisp.Response {
  case request.method {
    http.Put -> update_view(request, view_id)
    http.Delete -> delete_view(view_id)
    _ -> wisp.method_not_allowed([http.Put, http.Delete])
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
/// Jira and returns the list in the view's merged order — rows the view has
/// privately ordered keep that order, anything new is appended (see
/// db.merge_view_order). The `view` query parameter names the view; until
/// Phase 5's saved views there is exactly one: "my-issues".
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
            Ok(issues) -> {
              let ordered = merge_with_saved_order(issues, view_id)
              json.object([
                #("issues", json.array(ordered, types.issue_to_json)),
              ])
              |> json.to_string
              |> wisp.json_response(200)
            }
            Error(error) -> jira_error_response(error)
          }
      }
    }
  }
}

const default_view_id = "my-issues"

/// Read the view's private ordering and merge it over Jira's order. A db
/// failure must not hide issues Jira just returned: fall back to Jira's order
/// and log the problem. Saving an order will surface the error separately.
fn merge_with_saved_order(
  issues: List(types.Issue),
  view_id: String,
) -> List(types.Issue) {
  let saved = {
    use conn <- result.try(db.open())
    use _ <- result.try(db.migrate(conn))
    db.load_view_order(conn, view_id)
  }
  case saved {
    Ok(saved) -> db.merge_view_order(saved, issues)
    Error(error) -> {
      io.println("jira-view: saved order unavailable: " <> string.inspect(error))
      issues
    }
  }
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
        Error(error) -> db_error_response(error, "order_write_failed")
      }
    Error(message) -> json_error("bad_request", message, 400)
  }
}

/// The ordering request shape, decoded and validated. Exposed for tests.
pub fn parse_order_body(body: String) -> Result(List(String), String) {
  case json.parse(body, order_body_decoder()) {
    Ok(keys) ->
      case list.length(list.unique(keys)) == list.length(keys) {
        True -> Ok(keys)
        False -> Error("keys must be unique")
      }
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
  use _ <- result.try(db.get_view(conn, view_id))
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

/// GET /jira/resolutions — Jira's global resolution values, raw passthrough
/// for the transition picker.
fn resolutions() -> wisp.Response {
  case config.load() {
    Error(message) -> json_error("configuration_incomplete", message, 503)
    Ok(cfg) ->
      case jira.get(cfg, jira.resolutions_path) {
        Ok(body) -> wisp.json_response(body, 200)
        Error(error) -> jira_error_response(error)
      }
  }
}

/// POST /jira/issue/:key/transition — body {"id": "31", "resolution"?: "Done"}.
/// The transitions metadata is read fresh on this call; the metadata drives two
/// behaviours: a required `resolution` comes from the UI's picker, and
/// transitions needing other screen input the UI does not collect yet are
/// refused with 400 instead of Jira's raw screen error.
fn transition(request: wisp.Request, key: String) -> wisp.Response {
  use <- wisp.require_content_type(request, "application/json")
  use body <- wisp.require_string_body(request)
  case parse_transition_body(body) {
    Error(message) -> json_error("bad_request", message, 400)
    Ok(#(id, resolution)) ->
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
                          case transition_post_body(t, resolution) {
                            Error(message) ->
                              json_error(
                                "transition_requires_resolution",
                                message,
                                400,
                              )
                            Ok(body) ->
                              case
                                jira.post(
                                  cfg,
                                  jira.transitions_path(key),
                                  body,
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

/// The POST body Jira expects for a transition; `resolution` is taken from the
/// picker when the workflow's screen requires it. Exposed for tests.
pub fn transition_post_body(
  transition: types.Transition,
  resolution: Option(String),
) -> Result(String, String) {
  let requires_resolution =
    list.any(transition.fields, fn(field) {
      field.required && field.key == "resolution"
    })
  let fields = case requires_resolution, resolution {
    False, _ -> Ok([])
    True, Some(name) ->
      case string.trim(name) {
        "" ->
          Error(
            "transition " <> transition.name <> " requires a resolution",
          )
        name ->
          Ok([
            #(
              "fields",
              json.object([
                #("resolution", json.object([#("name", json.string(name))])),
              ]),
            ),
          ])
      }
    True, None ->
      Error("transition " <> transition.name <> " requires a resolution")
  }
  case fields {
    Error(message) -> Error(message)
    Ok(fields) ->
      Ok(
        json.object([
          #("transition", json.object([#("id", json.string(transition.id))])),
          ..fields
        ])
        |> json.to_string,
      )
  }
}

/// The transition request body shape `{"id": "…", "resolution"?: "…"}`.
/// Exposed for tests.
pub fn parse_transition_body(
  body: String,
) -> Result(#(String, Option(String)), String) {
  case json.parse(body, transition_body_decoder()) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(
        "expected {\"id\": \"<transition id>\", \"resolution\": "
          <> "\"<resolution name>\" (optional)} JSON",
      )
  }
}

fn transition_body_decoder() -> decode.Decoder(#(String, Option(String))) {
  use id <- decode.field("id", decode.string)
  use resolution <- decode.optional_field(
    "resolution",
    None,
    decode.optional(decode.string),
  )
  decode.success(#(id, resolution))
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

// ————— saved views (Phase 5) —————

/// With a per-request connection this small helper keeps the handlers tidy;
/// every view operation needs open+migrate first.
fn with_views(
  next: fn(sqlight.Connection) -> wisp.Response,
) -> wisp.Response {
  case db.open() {
    Error(error) -> json_error("database_unavailable", string.inspect(error), 500)
    Ok(conn) ->
      case db.migrate(conn) {
        Error(error) -> json_error("database_unavailable", string.inspect(error), 500)
        Ok(_) -> next(conn)
      }
  }
}

fn db_error_response(error: db.DbError, kind: String) -> wisp.Response {
  case error {
    db.NotFound -> json_error(kind, "no such view", 404)
    other -> json_error("database_write_failed", string.inspect(other), 500)
  }
}

/// GET /jira/views — every saved view in creation order. The database is
/// seeded with one default view, so this is only empty by deletion.
fn list_views() -> wisp.Response {
  with_views(fn(conn) {
    case db.list_views(conn) {
      Ok(views) ->
        json.object([
          #("views", json.array(views, types.view_to_json)),
        ])
        |> json.to_string
        |> wisp.json_response(200)
      Error(error) -> json_error("database_read_failed", string.inspect(error), 500)
    }
  })
}

/// POST /jira/views — body {"name", "jql" | "board_id", "columns"?}; the
/// id is a unique slug of the name (server-side, since it is the key of the
/// private ordering state).
fn create_view(request: wisp.Request) -> wisp.Response {
  use <- wisp.require_content_type(request, "application/json")
  use body <- wisp.require_string_body(request)
  case parse_view_body(body) {
    Error(message) -> json_error("bad_request", message, 400)
    Ok(view) ->
      with_views(fn(conn) {
        let view =
          types.ViewDef(
            ..view,
            id: db.unique_view_id(conn, view.name),
          )
        case db.create_view(conn, view) {
          Ok(_) ->
            types.view_to_json(view) |> json.to_string |> wisp.json_response(201)
          Error(error) -> db_error_response(error, "create_failed")
        }
      })
  }
}

/// PUT /jira/views/:id — body like create; replaces name/source/columns.
/// The private ordering is left untouched (a JQL edit does not throw away
/// the user's orderings).
fn update_view(request: wisp.Request, view_id: String) -> wisp.Response {
  use <- wisp.require_content_type(request, "application/json")
  use body <- wisp.require_string_body(request)
  case parse_view_body(body) {
    Error(message) -> json_error("bad_request", message, 400)
    Ok(view) ->
      with_views(fn(conn) {
        case db.update_view(conn, view_id, view) {
          Ok(_) ->
            types.ViewDef(
              ..view,
              id: view_id,
            )
            |> types.view_to_json
            |> json.to_string
            |> wisp.json_response(200)
          Error(error) -> db_error_response(error, "update_failed")
        }
      })
  }
}

/// DELETE /jira/views/:id — also drops the view's private ordering rows.
/// Deleting an absent id is 404 (a no-op DELETE would silently succeed).
fn delete_view(view_id: String) -> wisp.Response {
  with_views(fn(conn) {
    case db.get_view(conn, view_id) {
      Error(_) -> db_error_response(db.NotFound, "delete_failed")
      Ok(_) ->
        case db.delete_view(conn, view_id) {
          Ok(_) ->
            json.object([
              #("deleted", json.bool(True)),
              #("id", json.string(view_id)),
            ])
            |> json.to_string
            |> wisp.json_response(200)
          Error(error) -> db_error_response(error, "delete_failed")
        }
    }
  })
}

/// The create/update view body shape. Exposed for tests. Validates:
/// name, and exactly one of jql / board_id.
pub fn parse_view_body(body: String) -> Result(types.ViewDef, String) {
  case json.parse(body, view_body_decoder()) {
    Error(_) ->
      Error("expected {\"name\", \"jql\"|\"board_id\", \"columns\"} JSON")
    Ok(#(name, jql, board_id, columns)) ->
      case string.trim(name) {
        "" -> Error("name must not be empty")
        name ->
          case jql, board_id {
            None, None -> Error("set jql or board_id")
            Some(_), Some(_) ->
              Error("set either jql or board_id, not both")
            Some(jql), None ->
              case jql {
                "" -> Error("jql must not be empty")
                _ ->
                  Ok(types.ViewDef(
                    id: "",
                    name:,
                    source: types.Jql(jql),
                    columns:,
                  ))
              }
            None, Some(board_id) ->
              Ok(types.ViewDef(
                id: "",
                name:,
                source: types.Board(board_id),
                columns:,
              ))
          }
      }
  }
}

fn view_body_decoder() -> decode.Decoder(
  #(String, Option(String), Option(Int), List(String)),
) {
  use name <- decode.field("name", decode.string)
  use jql <- decode.optional_field("jql", None, decode.optional(decode.string))
  use board_id <- decode.optional_field(
    "board_id",
    None,
    decode.optional(decode.int),
  )
  use columns <- decode.then(decode.optionally_at(
    ["columns"],
    db.default_columns(),
    decode.list(decode.string),
  ))
  decode.success(#(name, jql, board_id, columns))
}

// ————— board views (Phase 5) —————

/// GET /jira/boards — the agile board picker's options.
fn boards() -> wisp.Response {
  case config.load() {
    Error(message) -> json_error("configuration_incomplete", message, 503)
    Ok(cfg) ->
      case jira.boards(cfg) {
        Ok(boards) ->
          json.object([
            #("boards", json.array(boards, types.board_to_json)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
        Error(error) -> jira_error_response(error)
      }
  }
}

/// GET /jira/board/:id/issues?view=… — the board's issues, bulk-fetched and
/// returned in the referring view's merged ordering — same pipeline and
/// response shape as /jira/search.
fn board_issues(request: wisp.Request, board_id: String) -> wisp.Response {
  case int.parse(board_id) {
    Error(_) ->
      json_error("bad_request", "board id must be an integer", 400)
    Ok(board_id) -> {
      let view_id = case list.key_find(wisp.get_query(request), "view") {
        Ok(view_id) -> view_id
        Error(_) -> default_view_id
      }
      case config.load() {
        Error(message) -> json_error("configuration_incomplete", message, 503)
        Ok(cfg) ->
          case jira.board_issues(cfg, board_id) {
            Ok(issues) -> {
              let ordered = merge_with_saved_order(issues, view_id)
              json.object([
                #("issues", json.array(ordered, types.issue_to_json)),
              ])
              |> json.to_string
              |> wisp.json_response(200)
            }
            Error(error) -> jira_error_response(error)
          }
      }
    }
  }
}

// ————— binary proxies (Phase 5) —————

/// GET /jira/avatar/:account_id — the user's 48x48 avatar bytes as served
/// by the avatar CDN (public; no credentials travel to it), with a
/// day-long cache header.
fn avatar(account_id: String) -> wisp.Response {
  case config.load() {
    Error(message) -> json_error("configuration_incomplete", message, 503)
    Ok(cfg) ->
      case jira.avatar(cfg, account_id) {
        Ok(#(bits, content_type)) ->
          wisp.response(200)
          |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(bits)))
          |> wisp.set_header("content-type", content_type)
          |> wisp.set_header("cache-control", "max-age=86400")
        Error(error) -> jira_error_response(error)
      }
  }
}

/// GET /jira/attachment/:id — the attachment content, byte-level, with the
/// auth headers the browser cannot have. Only safe raster images render
/// inline; everything else is served as a download. `nosniff` is always set.
fn attachment(attachment_id: String) -> wisp.Response {
  case config.load() {
    Error(message) -> json_error("configuration_incomplete", message, 503)
    Ok(cfg) ->
      case jira.get_bits(cfg, jira.attachment_content_path(attachment_id)) {
        Ok(#(bits, content_type)) ->
          wisp.response(200)
          |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(bits)))
          |> set_headers(attachment_headers(content_type))
        Error(error) -> jira_error_response(error)
      }
  }
}

/// Response headers for attachment content. SVG is deliberately not inline:
/// it can carry script when opened directly. Exposed for tests.
pub fn attachment_headers(content_type: String) -> List(#(String, String)) {
  let disposition = case is_inline_image(content_type) {
    True -> []
    False -> [#("content-disposition", "attachment")]
  }
  [
    #("content-type", content_type),
    #("x-content-type-options", "nosniff"),
    ..disposition
  ]
}

fn is_inline_image(content_type: String) -> Bool {
  let mime = case string.split_once(content_type, ";") {
    Ok(#(mime, _)) -> mime
    Error(_) -> content_type
  }
  list.contains(
    ["image/png", "image/jpeg", "image/gif", "image/webp"],
    mime |> string.trim |> string.lowercase,
  )
}

fn set_headers(
  response: wisp.Response,
  headers: List(#(String, String)),
) -> wisp.Response {
  list.fold(headers, response, fn(response, header) {
    let #(name, value) = header
    wisp.set_header(response, name, value)
  })
}

/// Issue detail data for the UI panel: fetch
/// GET /rest/api/3/issue/:key?fields=... and pass the raw JSON through —
/// the browser decodes it with the shared issue_detail decoder.
/// shortcut: detail is fetched fresh on every open; add a local detail cache
/// if offline detail reads ever matter.
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
    jira.TooMany(limit) ->
      json_error(
        "too_many_issues",
        "This view returned more than "
          <> int.to_string(limit)
          <> " issues. Narrow the JQL or pick a smaller board.",
        413,
      )
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
