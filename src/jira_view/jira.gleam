//// A minimal Jira Cloud REST client.
////
//// Phase 1: paginated search via GET /rest/api/3/search/jql. Issue/value
//// types and decoders live in jira_view/types so they can be shared with
//// the Lustre frontend.

import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import jira_view/config.{type Config}
import shared/types

pub type JiraError {
  /// The request could not be completed (network/TLS/timeout).
  Http(httpc.HttpError)
  /// Jira answered with a non-success status code.
  Api(status: Int, body: String)
  /// The response body could not be decoded.
  Decode(json.DecodeError)
  /// A single view returned more issues than the app will render.
  TooMany(limit: Int)
}

/// The endpoint that proves credentials.
pub const myself_path = "/rest/api/3/myself"

/// Modern search endpoint. The legacy /rest/api/3/search is deprecated.
pub const search_path = "/rest/api/3/search/jql"

/// The `fields` allowlist sent with search requests; anything not on it is
/// not fetched. Add a field here + to types.Issue/decoders together.
pub const search_fields = "summary,status,assignee,updated,labels"

/// Rows requested per page. Jira's default is 50; 100 halves the round trips
/// without making a single response large.
const page_size = "100"

/// Hard cap for one view. The table is unusable beyond this, and it keeps a
/// broad JQL from holding the request open for minutes.
pub const max_issue_fetch = 2000

/// Path of the issue detail endpoint for the detail view.
pub fn issue_path(key: String) -> String {
  "/rest/api/3/issue/" <> key
}

/// The fields the detail panel renders (description arrives as ADF; the
/// comment, worklog and attachment embeds drive the panel's lists).
pub const issue_fields =
  "summary,description,status,assignee,updated,comment,worklog,attachment,labels"

/// Paths of the transitions metadata + POST endpoints of an issue.
pub fn transitions_path(key: String) -> String {
  issue_path(key) <> "/transitions"
}

/// Path of the comment POST endpoint of an issue.
pub fn comment_path(key: String) -> String {
  issue_path(key) <> "/comment"
}

/// Path of the worklog POST endpoint of an issue.
pub fn worklog_path(key: String) -> String {
  issue_path(key) <> "/worklog"
}

/// Global resolution values for the transition picker.
pub const resolutions_path = "/rest/api/3/resolution"

// ————— agile API (Phase 5 board views) —————

pub const boards_path = "/rest/agile/1.0/board"

pub fn board_issues_path(board_id: Int) -> String {
  boards_path <> "/" <> int.to_string(board_id) <> "/issue"
}

/// Attachment content of an issue, byte-level (metadata lives in the issue
/// detail payload).
pub fn attachment_content_path(attachment_id: String) -> String {
  "/rest/api/3/attachment/content/" <> attachment_id
}

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
/// complete issue list in Jira's order, up to `max_issue_fetch`.
pub fn search(
  cfg: Config,
  jql: String,
) -> Result(List(types.Issue), JiraError) {
  search_pages(cfg, jql, None, [], 0)
}

fn search_pages(
  cfg: Config,
  jql: String,
  token: option.Option(String),
  acc: List(List(types.Issue)),
  count: Int,
) -> Result(List(types.Issue), JiraError) {
  use body <- result.try(get_with_query(
    cfg,
    search_path,
    search_page_query(jql, token),
  ))
  case json.parse(body, types.search_page_decoder()) {
    Error(error) -> Error(Decode(error))
    Ok(types.SearchPage(issues, next)) -> {
      let count = count + list.length(issues)
      case count > max_issue_fetch {
        True -> Error(TooMany(max_issue_fetch))
        False -> {
          let acc = [issues, ..acc]
          case next {
            Some(token) -> search_pages(cfg, jql, Some(token), acc, count)
            None -> Ok(acc |> list.reverse |> list.flatten)
          }
        }
      }
    }
  }
}

/// Query pairs for one search request: the bounded JQL, the pruned field
/// allowlist, the page size, and the continuation token when there is one.
pub fn search_page_query(
  jql: String,
  token: option.Option(String),
) -> List(#(String, String)) {
  let base = [
    #("jql", jql),
    #("fields", search_fields),
    #("maxResults", page_size),
  ]
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

  send_and_check(req)
}

/// POST `body` (JSON) to `path`.
pub fn post(cfg: Config, path: String, body: String) -> Result(String, JiraError) {
  send_json(http.Post, cfg, path, body)
}

/// PUT `body` (JSON) to `path` (Jira's edit-issue endpoint).
pub fn put(cfg: Config, path: String, body: String) -> Result(String, JiraError) {
  send_json(http.Put, cfg, path, body)
}

fn send_json(
  method: http.Method,
  cfg: Config,
  path: String,
  body: String,
) -> Result(String, JiraError) {
  use req <- result.try(
    request.to(cfg.base_url <> path)
    |> result.map_error(fn(_) { Api(0, "JIRA_BASE_URL could not be parsed") }),
  )
  req
  |> request.set_method(method)
  |> request.prepend_header("authorization", basic_auth_header(cfg))
  |> request.prepend_header("accept", "application/json")
  |> request.prepend_header("content-type", "application/json")
  |> request.set_body(body)
  |> send_and_check
}

/// Send the request and map non-2xx responses into JiraError. 204 (No
/// Content, the transitions POST response) reads back as "".
fn send_and_check(req: request.Request(String)) -> Result(String, JiraError) {
  case httpc.send(req) {
    Ok(resp) ->
      case resp.status >= 200 && resp.status < 300 {
        True -> Ok(resp.body)
        False -> Error(Api(resp.status, resp.body))
      }
    Error(error) -> Error(Http(error))
  }
}

// ————— agile API (Phase 5 board views) —————

/// All boards (bulk: pages followed via startAt/total), app shape.
pub fn boards(cfg: Config) -> Result(List(types.AgileBoard), JiraError) {
  boards_pages(cfg, 0, [])
}

fn boards_pages(
  cfg: Config,
  start_at: Int,
  acc: List(types.AgileBoard),
) -> Result(List(types.AgileBoard), JiraError) {
  use body <- result.try(get_with_query(cfg, boards_path, [
    #("startAt", int.to_string(start_at)),
    #("maxResults", "50"),
  ]))
  case json.parse(body, types.boards_page_decoder()) {
    Error(error) -> Error(Decode(error))
    Ok(#(boards, total)) -> {
      let acc = list.append(acc, boards)
      case start_at + list.length(boards) < total && boards != [] {
        True -> boards_pages(cfg, start_at + list.length(boards), acc)
        False -> Ok(acc)
      }
    }
  }
}

/// ALL issues of one board, bulk: pages are followed until
/// startAt+maxResults covers total (the agile API paginates by offset,
/// unlike the platform search), up to `max_issue_fetch`. Same issue shape as
/// the platform search. Works for every board kind; this site's boards don't
/// use sprints at all (the sprint endpoints answer 400 on them).
pub fn board_issues(
  cfg: Config,
  board_id: Int,
) -> Result(List(types.Issue), JiraError) {
  board_issues_pages(cfg, board_id, 0, [], 0)
}

fn board_issues_pages(
  cfg: Config,
  board_id: Int,
  start_at: Int,
  acc: List(List(types.Issue)),
  count: Int,
) -> Result(List(types.Issue), JiraError) {
  use body <- result.try(get_with_query(cfg, board_issues_path(board_id), [
    #("startAt", int.to_string(start_at)),
    #("maxResults", page_size),
    #("fields", search_fields),
  ]))
  case json.parse(body, types.agile_page_decoder()) {
    Error(error) -> Error(Decode(error))
    Ok(#(issues, total)) -> {
      let count = count + list.length(issues)
      case count > max_issue_fetch {
        True -> Error(TooMany(max_issue_fetch))
        False -> {
          let acc = [issues, ..acc]
          case start_at + list.length(issues) < total && issues != [] {
            True ->
              board_issues_pages(
                cfg,
                board_id,
                start_at + list.length(issues),
                acc,
                count,
              )
            False -> Ok(acc |> list.reverse |> list.flatten)
          }
        }
      }
    }
  }
}

// ————— binary proxies (Phase 5) —————

/// GET a Jira path as raw bytes; returns the body plus the response's
/// content-type (Jira's attachment content endpoint sets it).
pub fn get_bits(
  cfg: Config,
  path: String,
) -> Result(#(BitArray, String), JiraError) {
  use req <- result.try(
    request.to(cfg.base_url <> path)
    |> result.map_error(fn(_) { Api(0, "JIRA_BASE_URL could not be parsed") }),
  )
  req
  |> request.prepend_header("authorization", basic_auth_header(cfg))
  |> request.prepend_header("accept", "*/*")
  |> request.set_body(<<>>)
  |> send_bits_and_check
}

/// The 48x48 avatar of a user, by account id: Jira's
/// /rest/api/3/user?accountId=…&expand=avatarUrls (auth) yields the CDN
/// URL, which is public — fetched WITHOUT the auth header.
pub fn avatar(
  cfg: Config,
  account_id: String,
) -> Result(#(BitArray, String), JiraError) {
  use body <- result.try(get_with_query(cfg, user_path, [
    #("accountId", account_id),
    #("expand", "avatarUrls"),
  ]))
  use url <- result.try(case json.parse(body, types.avatar_url_decoder()) {
    Ok("") -> Error(Api(404, "user has no avatar"))
    Ok(url) -> Ok(url)
    Error(error) -> Error(Decode(error))
  })
  get_public_bits(url)
}

pub const user_path = "/rest/api/3/user"

fn get_public_bits(
  url: String,
) -> Result(#(BitArray, String), JiraError) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { Api(0, "avatar URL could not be parsed") }),
  )
  req |> request.set_body(<<>>) |> send_bits_and_check
}

/// Send the request and map non-2xx responses into JiraError. Attachment
/// content answers 303 with a signed CDN location, followed WITHOUT auth
/// (one hop is enough for Jira Cloud media links).
fn send_bits_and_check(
  req: request.Request(BitArray),
) -> Result(#(BitArray, String), JiraError) {
  case httpc.send_bits(req) {
    Ok(resp) ->
      case resp.status {
        status if status >= 200 && status < 300 ->
          Ok(#(
            resp.body,
            case list.key_find(resp.headers, "content-type") {
              Ok(content_type) -> content_type
              Error(_) -> "application/octet-stream"
            },
          ))
        status if status >= 300 && status < 400 ->
          case list.key_find(resp.headers, "location") {
            Ok(next_url) -> get_public_bits(next_url)
            Error(_) -> Error(Api(status, "redirect without location"))
          }
        status -> Error(Api(status, "binary response"))
      }
    Error(error) -> Error(Http(error))
  }
}

/// `HTTP Basic` credentials: base64 of "email:token" (Jira Cloud API tokens).
pub fn basic_auth_header(cfg: Config) -> String {
  let credentials = cfg.email <> ":" <> cfg.api_token
  "Basic " <> bit_array.base64_encode(bit_array.from_string(credentials), True)
}
