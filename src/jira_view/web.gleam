//// Web router: Wisp handlers. Serves the auth-proving endpoint, the
//// paginated Jira search proxy (which writes every fetch into the SQLite
//// cache), the issue-detail passthrough, and the built frontend bundle.

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
/// Jira, writes the issues into the cache, and returns the full list.
fn search(request: wisp.Request) -> wisp.Response {
  case list.key_find(wisp.get_query(request), "jql") {
    Error(_) ->
      json_error("missing_parameter", "required query parameter: jql", 400)
    Ok(jql) ->
      case config.load() {
        Error(message) -> json_error("configuration_incomplete", message, 503)
        Ok(cfg) ->
          case jira.search(cfg, jql) {
            Ok(issues) ->
              case cache_issues(issues) {
                Ok(_) ->
                  json.object([
                    #("issues", json.array(issues, types.issue_to_json)),
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

/// Fetches own the connection: open, migrate, upsert, done.
fn cache_issues(issues: List(types.Issue)) -> Result(Nil, db.DbError) {
  use conn <- result.try(db.open())
  use _ <- result.try(db.migrate(conn))
  db.upsert_issues(conn, issues)
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
