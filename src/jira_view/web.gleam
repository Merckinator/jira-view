//// Web router: Wisp handlers. Phase 0 serves only the auth-proving endpoint.

import gleam/http
import gleam/http/request.{path_segments}
import gleam/int
import gleam/json
import gleam/string
import jira_view/config
import jira_view/jira
import wisp

pub fn handle_request(request: wisp.Request) -> wisp.Response {
  use <- wisp.log_request(request)
  case path_segments(request) {
    ["api", "me"] -> wisp.require_method(request, http.Get, me)
    _ -> wisp.not_found()
  }
}

/// Proves Jira credentials: proxies GET /rest/api/3/myself.
fn me() -> wisp.Response {
  case config.load() {
    Error(message) -> json_error("configuration_incomplete", message, 503)
    Ok(cfg) ->
      case jira.myself(cfg) {
        Ok(me) -> wisp.json_response(json.to_string(jira.me_to_json(me)), 200)
        Error(jira.Api(401, body)) ->
          json_error(
            "unauthorized",
            "Jira rejected the credentials. Check JIRA_EMAIL, "
              <> "JIRA_API_TOKEN and JIRA_BASE_URL. Jira said: "
              <> clip(body),
            401,
          )
        Error(jira.Api(status, body)) ->
          json_error(
            "jira_api_error",
            int.to_string(status) <> ": " <> clip(body),
            502,
          )
        Error(jira.Http(error)) ->
          json_error("jira_unreachable", string.inspect(error), 502)
        Error(jira.Decode(error)) ->
          json_error("decode_failed", string.inspect(error), 502)
      }
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
