//// Shared Jira types, JSON decoders and encoders.
////
//// The "shared code" of the two-target split: on the Erlang target it powers
//// the backend proxy, on the JS target the Lustre frontend. Keep it
//// pure: only gleam_stdlib and gleam_json imports, no target-specific code.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import shared/adf.{type AdfNode}

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
    /// Jira labels (fields.labels); empty when the issue has none.
    labels: List(String),
    /// ISO timestamp string as reported by Jira.
    updated: String,
  )
}

/// One page of GET /rest/api/3/search/jql. `next_page_token` is absent on
/// the last page (where the payload carries `"isLast": true`).
pub type SearchPage {
  SearchPage(issues: List(Issue), next_page_token: Option(String))
}

/// Full issue for the detail view: the pruned issue plus the description
/// decoded out of its ADF document (empty list = no description), the
/// issue's comments, work log and attachments.
/// Shape: GET /rest/api/3/issue/{key} — same `fields` nesting as search.
pub type IssueDetail {
  IssueDetail(
    issue: Issue,
    description: List(AdfNode),
    comments: List(Comment),
    worklog: List(WorklogEntry),
    attachments: List(Attachment),
  )
}

/// A file attached to an issue; served to the browser through
/// GET /jira/attachment/:id (the Jira content URL needs the API token, and
/// the browser must never talk to anything but localhost).
pub type Attachment {
  Attachment(
    /// Numeric id used in the proxy URL.
    id: String,
    filename: String,
    mime_type: String,
    size: Int,
  )
}

/// A board from GET /rest/agile/1.0/board. `kind` is "scrum"/"kanban"/…
/// (informational in the UI's board picker).
pub type AgileBoard {
  AgileBoard(id: Int, name: String, kind: String)
}

/// A comment on an issue; `author` is the author's display name and `body`
/// is the ADF document's content (rendered client-side).
pub type Comment {
  Comment(author: String, created: String, body: List(AdfNode))
}

/// One work log entry; `started`/`created` are ISO timestamps as reported
/// by Jira, `time_spent` is Jira's human string ("25m", "2h").
pub type WorklogEntry {
  WorklogEntry(
    author: String,
    started: String,
    time_spent: String,
    body: List(AdfNode),
  )
}

/// A workflow transition from GET /rest/api/3/issue/{key}/transitions.
/// `to_status` is the resolved status name (drives the optimistic UI flip);
/// `fields` lists the transition screen's inputs when the workflow has one
/// (absent entirely on the simplest team-managed workflows).
pub type Transition {
  Transition(
    id: String,
    name: String,
    to_status: String,
    fields: List(TransitionField),
  )
}

/// One field of a transition screen. `key` is the system field id
/// ("resolution", …); the resolution field is the one this app fills from its
/// picker.
pub type TransitionField {
  TransitionField(key: String, required: Bool)
}

/// A global resolution value from GET /rest/api/3/resolution.
pub type Resolution {
  Resolution(id: String, name: String)
}

// ————— views (Phase 5) —————

/// A saved view: a source (JQL query or a board's active sprint) plus the
/// columns it renders. Private ordering lives separately, keyed by a view's
/// `id` in the `view_issues` table.
pub type ViewDef {
  ViewDef(
    /// Slug id, also a URL segment and the ordering-state key.
    id: String,
    name: String,
    source: ViewSource,
    /// Ordered subset of the known columns: key/summary/status/assignee/updated.
    columns: List(String),
  )
}

pub type ViewSource {
  /// A bounded JQL query.
  Jql(String)
  /// A board id; its issues are bulk-fetched via the agile API.
  Board(Int)
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
  use labels <- decode.then(decode.optionally_at(
    ["fields", "labels"],
    [],
    decode.list(decode.string),
  ))
  use updated <- decode.subfield(["fields", "updated"], decode.string)
  decode.success(Issue(
    key:,
    id:,
    summary:,
    status:,
    assignee:,
    labels:,
    updated:,
  ))
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

pub fn issues_response_decoder() -> decode.Decoder(List(Issue)) {
  use issues <- decode.field("issues", decode.list(app_issue_decoder()))
  decode.success(issues)
}

// The backend's /jira/search re-encodes decoded issues with issue_to_json:
// snake_case, no "fields" wrapper, status{name, category}. The frontend
// decodes that shape with the decoders below.

fn app_status_decoder() -> decode.Decoder(Status) {
  use name <- decode.field("name", decode.string)
  use category <- decode.optional_field("category", "", decode.string)
  decode.success(Status(name:, category:))
}

fn app_user_decoder() -> decode.Decoder(User) {
  use account_id <- decode.optional_field("account_id", "", decode.string)
  use display_name <- decode.field("display_name", decode.string)
  use avatar_url <- decode.optional_field("avatar_url", "", decode.string)
  decode.success(User(account_id:, display_name:, avatar_url:))
}

/// The bare user array from GET /rest/api/3/user/assignable/search.
pub fn jira_users_decoder() -> decode.Decoder(List(User)) {
  decode.list(user_decoder())
}

/// The app's {"users": [...]} shape (the backend re-encodes the Jira array
/// with user_to_json, so the UI decodes one shape everywhere).
pub fn users_response_decoder() -> decode.Decoder(List(User)) {
  use users <- decode.field("users", decode.list(app_user_decoder()))
  decode.success(users)
}

fn app_issue_decoder() -> decode.Decoder(Issue) {
  use key <- decode.field("key", decode.string)
  use id <- decode.field("id", decode.string)
  use summary <- decode.field("summary", decode.string)
  use status <- decode.field("status", app_status_decoder())
  use assignee <- decode.optional_field(
    "assignee",
    None,
    decode.optional(app_user_decoder()),
  )
  use labels <- decode.optional_field("labels", [], decode.list(decode.string))
  use updated <- decode.field("updated", decode.string)
  decode.success(Issue(
    key:,
    id:,
    summary:,
    status:,
    assignee:,
    labels:,
    updated:,
  ))
}

/// Decoder for GET /rest/api/3/issue/{key} with
/// fields=summary,description,status,assignee,updated.
pub fn issue_detail_decoder() -> decode.Decoder(IssueDetail) {
  use key <- decode.field("key", decode.string)
  use id <- decode.field("id", decode.string)
  use summary <- decode.subfield(["fields", "summary"], decode.string)
  use status <- decode.subfield(["fields", "status"], status_decoder())
  use assignee <- decode.then(decode.optionally_at(
    ["fields", "assignee"],
    None,
    decode.optional(user_decoder()),
  ))
  use labels <- decode.then(decode.optionally_at(
    ["fields", "labels"],
    [],
    decode.list(decode.string),
  ))
  use updated <- decode.subfield(["fields", "updated"], decode.string)
  use doc <- decode.then(decode.optionally_at(
    ["fields", "description"],
    None,
    decode.optional(adf.adf_decoder()),
  ))
  let description = case doc {
    Some(doc) -> doc.content
    None -> []
  }
  use comments <- decode.then(decode.optionally_at(
    ["fields", "comment", "comments"],
    [],
    decode.list(jira_comment_decoder()),
  ))
  use worklog <- decode.then(decode.optionally_at(
    ["fields", "worklog", "worklogs"],
    [],
    decode.list(jira_worklog_decoder()),
  ))
  use attachments <- decode.then(decode.optionally_at(
    ["fields", "attachment"],
    [],
    decode.list(attachment_decoder()),
  ))
  decode.success(IssueDetail(
    issue: Issue(key:, id:, summary:, status:, assignee:, labels:, updated:),
    description:,
    comments:,
    worklog:,
    attachments:,
  ))
}

/// One page of an agile list response ({issues: […], startAt, maxResults,
/// total}): the issues plus `total` for the pagination loop. Issue shape
/// inside is identical to the platform search.
pub fn agile_page_decoder() -> decode.Decoder(#(List(Issue), Int)) {
  use issues <- decode.field("issues", decode.list(issue_decoder()))
  use total <- decode.then(decode.optionally_at(["total"], 0, decode.int))
  decode.success(#(issues, total))
}

/// The user's 48x48 avatar CDN URL from /rest/api/3/user?expand=avatarUrls.
pub fn avatar_url_decoder() -> decode.Decoder(String) {
  decode.optionally_at(["avatarUrls", "48x48"], "", decode.string)
}

/// Jira's attachment metadata: {id, filename, mimeType, size, …}.
pub fn attachment_decoder() -> decode.Decoder(Attachment) {
  use id <- decode.field("id", decode.string)
  use filename <- decode.field("filename", decode.string)
  use mime_type <- decode.then(decode.optionally_at(
    ["mimeType"],
    "application/octet-stream",
    decode.string,
  ))
  use size <- decode.then(decode.optionally_at(["size"], 0, decode.int))
  decode.success(Attachment(id:, filename:, mime_type:, size:))
}

/// One page of the agile board list: the boards plus `total` for the
/// pagination loop in jira.gleam.
pub fn boards_page_decoder() -> decode.Decoder(#(List(AgileBoard), Int)) {
  use boards <- decode.then(decode.optionally_at(
    ["values"],
    [],
    decode.list(board_decoder()),
  ))
  use total <- decode.then(decode.optionally_at(["total"], 0, decode.int))
  decode.success(#(boards, total))
}

fn board_decoder() -> decode.Decoder(AgileBoard) {
  use id <- decode.field("id", decode.int)
  use name <- decode.optional_field("name", "", decode.string)
  use kind <- decode.then(decode.optionally_at(["type"], "", decode.string))
  decode.success(AgileBoard(id:, name:, kind:))
}

// ————— comments, worklog, transitions (Jira shapes + app pruned shapes) —————

/// A comment as embedded in GET /rest/api/3/issue/{key} (and returned by
/// POST …/comment, whose top-level object carries the same author/body/
/// created fields). Everything except author, created and the ADF body is
/// ignored.
pub fn jira_comment_decoder() -> decode.Decoder(Comment) {
  use author <- decode.then(decode.optionally_at(
    ["author", "displayName"],
    "",
    decode.string,
  ))
  use created <- decode.optional_field("created", "", decode.string)
  use body <- decode.then(node_body_decoder("body"))
  decode.success(Comment(author:, created:, body:))
}

/// A worklog entry as embedded in GET /rest/api/3/issue/{key} (and returned
/// by POST …/worklog — same author/started/timeSpent fields).
pub fn jira_worklog_decoder() -> decode.Decoder(WorklogEntry) {
  use author <- decode.then(decode.optionally_at(
    ["author", "displayName"],
    "",
    decode.string,
  ))
  use started <- decode.optional_field("started", "", decode.string)
  use time_spent <- decode.field("timeSpent", decode.string)
  use body <- decode.then(node_body_decoder("comment"))
  decode.success(WorklogEntry(author:, started:, time_spent:, body:))
}

/// An optional ADF node ("body"/"comment") reduced to its content list;
/// absent (or non-document) means no text.
fn node_body_decoder(at: String) -> decode.Decoder(List(AdfNode)) {
  decode.optionally_at([at], None, decode.optional(adf.adf_decoder()))
  |> decode.map(fn(doc) {
    case doc {
      Some(node) ->
        case node.kind {
          "doc" -> node.content
          _ -> [node]
        }
      None -> []
    }
  })
}

/// The transitions list of GET /rest/api/3/issue/{key}/transitions.
pub fn jira_transitions_decoder() -> decode.Decoder(List(Transition)) {
  use transitions <- decode.field(
    "transitions",
    decode.list(transition_decoder()),
  )
  decode.success(transitions)
}

fn transition_decoder() -> decode.Decoder(Transition) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use to_status <- decode.then(decode.optionally_at(
    ["to", "name"],
    "",
    decode.string,
  ))
  use fields <- decode.optional_field(
    "fields",
    [],
    decode.list(transition_field_decoder()),
  )
  decode.success(Transition(id:, name:, to_status:, fields:))
}

fn transition_field_decoder() -> decode.Decoder(TransitionField) {
  use key <- decode.then(decode.optionally_at(["key"], "", decode.string))
  use required <- decode.field("required", decode.bool)
  decode.success(TransitionField(key:, required:))
}

/// The bare array from GET /rest/api/3/resolution.
pub fn resolutions_decoder() -> decode.Decoder(List(Resolution)) {
  decode.list(resolution_decoder())
}

fn resolution_decoder() -> decode.Decoder(Resolution) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(Resolution(id:, name:))
}

/// The app's pruned shapes (what the backend re-encodes POST responses into,
/// so the UI decodes one shape everywhere). Same convention as
/// app_issue_decoder: snake_case, ADF flattened to content lists.
pub fn app_comment_decoder() -> decode.Decoder(Comment) {
  use author <- decode.field("author", decode.string)
  use created <- decode.optional_field("created", "", decode.string)
  use body <- decode.optional_field("body", [], adf_content_decoder())
  decode.success(Comment(author:, created:, body:))
}

pub fn app_worklog_decoder() -> decode.Decoder(WorklogEntry) {
  use author <- decode.field("author", decode.string)
  use started <- decode.optional_field("started", "", decode.string)
  use time_spent <- decode.field("time_spent", decode.string)
  use body <- decode.optional_field("body", [], adf_content_decoder())
  decode.success(WorklogEntry(author:, started:, time_spent:, body:))
}

fn adf_content_decoder() -> decode.Decoder(List(AdfNode)) {
  decode.list(adf.adf_decoder())
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
    #("labels", json.array(issue.labels, json.string)),
    #("updated", json.string(issue.updated)),
  ])
}

/// Encode a `Comment` in the app's pruned shape (see app_comment_decoder).
pub fn comment_to_json(comment: Comment) -> Json {
  json.object([
    #("author", json.string(comment.author)),
    #("created", json.string(comment.created)),
    #("body", json.array(comment.body, adf.adf_to_json)),
  ])
}

/// Encode a `WorklogEntry` in the app's pruned shape.
pub fn worklog_to_json(entry: WorklogEntry) -> Json {
  json.object([
    #("author", json.string(entry.author)),
    #("started", json.string(entry.started)),
    #("time_spent", json.string(entry.time_spent)),
    #("body", json.array(entry.body, adf.adf_to_json)),
  ])
}

/// Encode a `ViewDef` in the app shape (flat: jql/board_id nullable).
pub fn view_to_json(view: ViewDef) -> Json {
  let #(jql, board_id) = case view.source {
    Jql(jql) -> #(Some(jql), None)
    Board(board_id) -> #(None, Some(board_id))
  }
  json.object([
    #("id", json.string(view.id)),
    #("name", json.string(view.name)),
    #("jql", json.nullable(jql, json.string)),
    #("board_id", json.nullable(board_id, json.int)),
    #("columns", json.array(view.columns, json.string)),
  ])
}

/// The app shape's view decoder (backend /jira/views responses).
pub fn app_view_decoder() -> decode.Decoder(ViewDef) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use jql <- decode.optional_field("jql", None, decode.optional(decode.string))
  use board_id <- decode.optional_field(
    "board_id",
    None,
    decode.optional(decode.int),
  )
  use columns <- decode.then(decode.optionally_at(
    ["columns"],
    [],
    decode.list(decode.string),
  ))
  let source = case jql {
    Some(jql) -> Jql(jql)
    None -> Board(option.unwrap(board_id, 0))
  }
  decode.success(ViewDef(id:, name:, source:, columns:))
}

/// Encode a `AgileBoard` for the UI's board picker.
pub fn board_to_json(board: AgileBoard) -> Json {
  json.object([
    #("id", json.int(board.id)),
    #("name", json.string(board.name)),
    #("kind", json.string(board.kind)),
  ])
}

pub fn app_board_decoder() -> decode.Decoder(AgileBoard) {
  use id <- decode.field("id", decode.int)
  use name <- decode.optional_field("name", "", decode.string)
  use kind <- decode.optional_field("kind", "", decode.string)
  decode.success(AgileBoard(id:, name:, kind:))
}
