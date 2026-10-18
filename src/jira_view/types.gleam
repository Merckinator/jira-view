//// Shared Jira types, JSON decoders and encoders.
////
//// This is the "shared code" of the two-target split: on the Erlang target
//// it powers the backend cache/proxy, on the JS target it will power the
//// Lustre frontend. Keep it pure: only gleam_stdlib and gleam_json imports.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None}

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

/// A Jira user appearing on an issue (assignee). `avatar_url` is the 48x48
/// avatar; empty strings mean "not needed for the list view".
pub type User {
  User(account_id: String, display_name: String, avatar_url: String)
}

/// A workflow status. `category` is statusCategory.key
/// ("new"/"indeterminate"/"done"), handy for colouring badges later.
pub type Status {
  Status(name: String, category: String)
}

/// A Jira issue, pruned to the fields the views need.
pub type Issue {
  Issue(
    /// Key like "PROJ-123"; used for display and caching.
    key: String,
    /// Numeric Jira issue id (some API calls demand the numeric id).
    id: String,
    summary: String,
    status: Status,
    assignee: Option(User),
    /// ISO timestamp string as reported by Jira.
    updated: String,
  )
}

/// One page of GET /rest/api/3/search/jql. `next_page_token` is absent on
/// the last page (where the payload carries `"isLast": true`).
pub type SearchPage {
  SearchPage(issues: List(Issue), next_page_token: Option(String))
}

// ————— decoders —————

/// Decoder for the /rest/api/3/myself response. Exposed for unit tests.
pub fn me_decoder() -> decode.Decoder(Me) {
  use display_name <- decode.field("displayName", decode.string)
  use account_id <- decode.field("accountId", decode.string)
  use email <- decode.optional_field("emailAddress", "", decode.string)
  use avatar_url <- decode.then(decode.optionally_at(
    ["avatarUrls", "48x48"],
    "",
    decode.string,
  ))
  use time_zone <- decode.optional_field("timeZone", "", decode.string)
  decode.success(Me(account_id:, display_name:, email:, avatar_url:, time_zone:))
}

pub fn user_decoder() -> decode.Decoder(User) {
  use account_id <- decode.optional_field("accountId", "", decode.string)
  use display_name <- decode.field("displayName", decode.string)
  use avatar_url <- decode.then(decode.optionally_at(
    ["avatarUrls", "48x48"],
    "",
    decode.string,
  ))
  decode.success(User(account_id:, display_name:, avatar_url:))
}

pub fn status_decoder() -> decode.Decoder(Status) {
  use name <- decode.field("name", decode.string)
  use category <- decode.then(decode.optionally_at(
    ["statusCategory", "key"],
    "",
    decode.string,
  ))
  decode.success(Status(name:, category:))
}

/// Decoder for one issue of a search response. Unexpected extra fields are
/// ignored by the decoder itself; missing *required* fields are a decode
/// error, so payload drift surfaces loudly (see plan section 6).
pub fn issue_decoder() -> decode.Decoder(Issue) {
  use key <- decode.field("key", decode.string)
  use id <- decode.field("id", decode.string)
  use summary <- decode.subfield(["fields", "summary"], decode.string)
  use status <- decode.subfield(["fields", "status"], status_decoder())
  use assignee <- decode.then(decode.optionally_at(
    ["fields", "assignee"],
    None,
    decode.optional(user_decoder()),
  ))
  use updated <- decode.subfield(["fields", "updated"], decode.string)
  decode.success(Issue(key:, id:, summary:, status:, assignee:, updated:))
}

/// Decoder for one page of GET /rest/api/3/search/jql.
pub fn search_page_decoder() -> decode.Decoder(SearchPage) {
  use issues <- decode.field("issues", decode.list(issue_decoder()))
  use next_page_token <- decode.optional_field(
    "nextPageToken",
    None,
    decode.optional(decode.string),
  )
  decode.success(SearchPage(issues:, next_page_token:))
}

// ————— encoding —————

/// Encode a `Me` as JSON for the /api/me endpoint.
pub fn me_to_json(me: Me) -> Json {
  json.object([
    #("account_id", json.string(me.account_id)),
    #("display_name", json.string(me.display_name)),
    #("email", json.string(me.email)),
    #("avatar_url", json.string(me.avatar_url)),
    #("time_zone", json.string(me.time_zone)),
  ])
}

pub fn user_to_json(user: User) -> Json {
  json.object([
    #("account_id", json.string(user.account_id)),
    #("display_name", json.string(user.display_name)),
    #("avatar_url", json.string(user.avatar_url)),
  ])
}

pub fn status_to_json(status: Status) -> Json {
  json.object([
    #("name", json.string(status.name)),
    #("category", json.string(status.category)),
  ])
}

pub fn issue_to_json(issue: Issue) -> Json {
  json.object([
    #("key", json.string(issue.key)),
    #("id", json.string(issue.id)),
    #("summary", json.string(issue.summary)),
    #("status", status_to_json(issue.status)),
    #("assignee", json.nullable(issue.assignee, of: user_to_json)),
    #("updated", json.string(issue.updated)),
  ])
}
