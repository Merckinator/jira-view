//// A minimal Jira Cloud REST client (Phase 0 spike: prove auth + one call).

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/result
import jira_view/config.{type Config}

/// The current user, from GET /rest/api/3/myself.
pub type Me {
  Me(
    account_id: String,
    display_name: String,
    email: String,
    avatar_url: String,
    time_zone: String,
  )
}

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

/// Fetch and decode GET /rest/api/3/myself.
pub fn myself(cfg: Config) -> Result(Me, JiraError) {
  use body <- result.try(get(cfg, myself_path))
  case json.parse(body, me_decoder()) {
    Ok(me) -> Ok(me)
    Error(error) -> Error(Decode(error))
  }
}

/// GET `path` against the configured site with Basic auth.
///
/// Phase 0 only covers what the spike needs; pagination and POST helpers
/// arrive with Phase 1.
pub fn get(cfg: Config, path: String) -> Result(String, JiraError) {
  use req <- result.try(
    request.to(cfg.base_url <> path)
    |> result.map_error(fn(_) { Api(0, "JIRA_BASE_URL could not be parsed") }),
  )
  let req =
    req
    |> request.prepend_header("authorization", basic_auth_header(cfg))
    |> request.prepend_header("accept", "application/json")

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

/// Decoder for the /rest/api/3/myself response. Exposed for unit tests.
pub fn me_decoder() -> decode.Decoder(Me) {
  use display_name <- decode.field("displayName", decode.string)
  use account_id <- decode.field("accountId", decode.string)
  use email <- decode.optional_field("emailAddress", "", decode.string)
  use avatar_url <- decode.subfield(["avatarUrls", "48x48"], decode.string)
  use time_zone <- decode.optional_field("timeZone", "", decode.string)
  decode.success(Me(account_id:, display_name:, email:, avatar_url:, time_zone:))
}

/// Encode a `Me` as JSON for the /api/me endpoint.
pub fn me_to_json(me: Me) -> json.Json {
  json.object([
    #("account_id", json.string(me.account_id)),
    #("display_name", json.string(me.display_name)),
    #("email", json.string(me.email)),
    #("avatar_url", json.string(me.avatar_url)),
    #("time_zone", json.string(me.time_zone)),
  ])
}
