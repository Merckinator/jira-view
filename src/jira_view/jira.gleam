//// A minimal Jira Cloud REST client.
////
//// Phase 1: paginated search via GET /rest/api/3/search/jql. Issue/value
//// types and decoders live in jira_view/types so they can be shared with
//// the Lustre frontend.

import gleam/bit_array
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import jira_view/config.{type Config}
import jira_view/types

pub type JiraError {
  /// The request could not be completed (network/TLS/timeout).
  Http(httpc.HttpError)
  /// Jira answered with a non-success status code.
  Api(status: Int, body: String)
  /// The response body could not be decoded.
  Decode(json.DecodeError)
}

/// The endpoint that proves credentials.
pub const myself_path = "/rest/api/3/myself"

/// Modern search endpoint. The legacy /rest/api/3/search is deprecated.
pub const search_path = "/rest/api/3/search/jql"

/// The `fields` allowlist sent with search requests; anything not on it is
/// not fetched. Add a field here + to types.Issue/decoders together.
pub const search_fields = "summary,status,assignee,updated"

/// Fetch and decode GET /rest/api/3/myself.
pub fn myself(cfg: Config) -> Result(types.Me, JiraError) {
  use body <- result.try(get(cfg, myself_path))
  case json.parse(body, types.me_decoder()) {
    Ok(me) -> Ok(me)
    Error(error) -> Error(Decode(error))
  }
}

/// Fetch every page of the search endpoint. Pages are followed via
/// `nextPageToken` until it is absent (last page), so the result is the
/// complete issue list in Jira's order.
pub fn search(
  cfg: Config,
  jql: String,
) -> Result(List(types.Issue), JiraError) {
  search_pages(cfg, jql, None, [])
}

fn search_pages(
  cfg: Config,
  jql: String,
  token: option.Option(String),
  acc: List(types.Issue),
) -> Result(List(types.Issue), JiraError) {
  use body <- result.try(get_with_query(
    cfg,
    search_path,
    search_page_query(jql, token),
  ))
  case json.parse(body, types.search_page_decoder()) {
    Error(error) -> Error(Decode(error))
    Ok(types.SearchPage(issues, next)) -> {
      let acc = list.append(acc, issues)
      case next {
        Some(token) -> search_pages(cfg, jql, Some(token), acc)
        None -> Ok(acc)
      }
    }
  }
}

/// Query pairs for one search request: the bounded JQL, the pruned field
/// allowlist, and the continuation token when there is one.
pub fn search_page_query(
  jql: String,
  token: option.Option(String),
) -> List(#(String, String)) {
  let base = [#("jql", jql), #("fields", search_fields)]
  case token {
    None -> base
    Some(token) -> list.append(base, [#("nextPageToken", token)])
  }
}

/// GET `path` against the configured site with Basic auth.
pub fn get(cfg: Config, path: String) -> Result(String, JiraError) {
  get_with_query(cfg, path, [])
}

/// GET `path` with query parameters (values are percent-encoded by
/// gleam_http when the URL is rendered).
pub fn get_with_query(
  cfg: Config,
  path: String,
  query: List(#(String, String)),
) -> Result(String, JiraError) {
  use req <- result.try(
    request.to(cfg.base_url <> path)
    |> result.map_error(fn(_) { Api(0, "JIRA_BASE_URL could not be parsed") }),
  )
  let req =
    req
    |> request.prepend_header("authorization", basic_auth_header(cfg))
    |> request.prepend_header("accept", "application/json")
    |> request.set_query(query)

  case httpc.send(req) {
    Ok(resp) ->
      case resp.status >= 200 && resp.status < 300 {
        True -> Ok(resp.body)
        False -> Error(Api(resp.status, resp.body))
      }
    Error(error) -> Error(Http(error))
  }
}

/// `HTTP Basic` credentials: base64 of "email:token" (Jira Cloud API tokens).
pub fn basic_auth_header(cfg: Config) -> String {
  let credentials = cfg.email <> ":" <> cfg.api_token
  "Basic " <> bit_array.base64_encode(bit_array.from_string(credentials), True)
}
