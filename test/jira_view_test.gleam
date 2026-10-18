import gleam/json.{parse}
import gleeunit
import gleeunit/should
import jira_view/config
import jira_view/jira

pub fn main() {
  gleeunit.main()
}

// config

pub fn normalize_base_url_test() {
  config.normalize_base_url("https://acme.atlassian.net")
  |> should.equal("https://acme.atlassian.net")

  config.normalize_base_url("https://acme.atlassian.net/")
  |> should.equal("https://acme.atlassian.net")
}

// decoding against the shape of a captured Jira /rest/api/3/myself response

const sample_myself =
  "
{
  \"accountId\": \"557058:f1a2b3c4\",
  \"displayName\": \"Jeff Merckens\",
  \"emailAddress\": \"jeff@example.com\",
  \"timeZone\": \"America/New_York\",
  \"avatarUrls\": {
    \"16x16\": \"https://acme.atlassian.net/16.png\",
    \"48x48\": \"https://acme.atlassian.net/48.png\"
  }
}
"

pub fn decode_me_test() {
  let assert Ok(me) = parse(sample_myself, jira.me_decoder())
  me.account_id |> should.equal("557058:f1a2b3c4")
  me.display_name |> should.equal("Jeff Merckens")
  me.email |> should.equal("jeff@example.com")
  me.avatar_url |> should.equal("https://acme.atlassian.net/48.png")
  me.time_zone |> should.equal("America/New_York")
}

pub fn decode_me_missing_optional_fields_test() {
  let assert Ok(me) =
    parse(
      "{
        \"accountId\": \"abc\",
        \"displayName\": \"Jeff\",
        \"avatarUrls\": {\"48x48\": \"https://acme.atlassian.net/48.png\"}
      }",
      jira.me_decoder(),
    )
  me.email |> should.equal("")
  me.time_zone |> should.equal("")
}

// basic auth encoding

pub fn basic_auth_header_test() {
  let cfg =
    config.Config(
      email: "jeff@example.com",
      api_token: "&c|>bE{)Z7!wV$2b",
      base_url: "https://acme.atlassian.net",
    )
  jira.basic_auth_header(cfg)
  |> should.equal("Basic amVmZkBleGFtcGxlLmNvbTomY3w+YkV7KVo3IXdWJDJi")
}
