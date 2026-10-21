//// Server configuration, loaded from the environment or `.env` at runtime
//// (see `.env.example` and `dev.sh`).

import envoy
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Config {
  Config(
    /// The Atlassian account email the API token belongs to.
    email: String,
    /// API token from:
    /// https://id.atlassian.com/manage-profile/security/api-tokens
    api_token: String,
    /// Site root without trailing slash, e.g. "https://acme.atlassian.net".
    base_url: String,
    /// Optional override for the custom field id of Jira's "Flagged" field.
    /// Without it the id is discovered from GET /rest/api/3/field.
    flagged_field: Option(String),
    /// Optional override for the option value written when flagging. Without
    /// it the issue's edit metadata supplies the first allowed option.
    flagged_value: Option(String),
  )
}

/// Read configuration from `JIRA_EMAIL`, `JIRA_API_TOKEN` and `JIRA_BASE_URL`.
/// `JIRA_FLAGGED_FIELD` and `JIRA_FLAGGED_VALUE` are optional overrides.
pub fn load() -> Result(Config, String) {
  case
    envoy.get("JIRA_EMAIL"),
    envoy.get("JIRA_API_TOKEN"),
    envoy.get("JIRA_BASE_URL")
  {
    Ok(email), Ok(api_token), Ok(base_url) ->
      case string.trim(base_url) |> require_https {
        Ok(base_url) ->
          Ok(Config(
            email: string.trim(email),
            api_token: string.trim(api_token),
            base_url: normalize_base_url(base_url),
            flagged_field: optional_env("JIRA_FLAGGED_FIELD"),
            flagged_value: optional_env("JIRA_FLAGGED_VALUE"),
          ))
        Error(message) -> Error(message)
      }
    _, _, _ ->
      Error(
        "Missing configuration: set JIRA_EMAIL, JIRA_API_TOKEN and "
        <> "JIRA_BASE_URL (see .env.example; ./dev.sh loads .env)",
      )
  }
}

/// Basic credentials (email + token) travel in the header of every request
/// to the base URL's host, so it must be reached over https.
pub fn require_https(base_url: String) -> Result(String, String) {
  case string.starts_with(base_url, "https://") {
    True -> Ok(base_url)
    False ->
      Error(
        "JIRA_BASE_URL must start with https:// because the Jira "
        <> "credentials are sent with every request (got: \""
        <> base_url
        <> "\")",
      )
  }
}

/// Strip all trailing slashes so paths can be appended unambiguously.
pub fn normalize_base_url(base_url: String) -> String {
  case string.ends_with(base_url, "/") {
    True -> normalize_base_url(string.drop_end(base_url, 1))
    False -> base_url
  }
}

/// An optional environment value; absent and blank values both mean "unset".
fn optional_env(name: String) -> Option(String) {
  case envoy.get(name) {
    Ok(value) ->
      case string.trim(value) {
        "" -> None
        value -> Some(value)
      }
    Error(_) -> None
  }
}
