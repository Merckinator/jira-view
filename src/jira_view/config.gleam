//// Server configuration, loaded from the environment or `.env` at runtime
//// (see `.env.example` and `dev.sh`).

import envoy
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
  )
}

/// Read configuration from `JIRA_EMAIL`, `JIRA_API_TOKEN` and `JIRA_BASE_URL`.
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
