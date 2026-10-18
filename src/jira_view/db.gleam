//// SQLite via sqlight: the issues read cache plus the (so far empty) tables
//// for private per-view ordering state. Server-side only; never compiled
//// for the JS target.

import envoy
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import jira_view/types.{type Issue, Issue, Status, User}
import sqlight

pub type DbError {
  /// Filesystem/sqlite failure while opening or querying, debug-rendered.
  Sqlite(String)
}

/// Where the cache lives. `JIRA_VIEW_DB` overrides; the default is the
/// working directory (repo root under `./dev.sh`), already gitignored.
pub fn path() -> String {
  case envoy.get("JIRA_VIEW_DB") {
    Ok(path) -> path
    Error(_) -> "jira-view.db"
  }
}

/// Open a connection. Per request rather than held globally, matching the
/// stateless config.load() pattern of the handlers.
pub fn open() -> Result(sqlight.Connection, DbError) {
  sqlight.open(path())
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

const schema =
  "
CREATE TABLE IF NOT EXISTS issues (
  key TEXT PRIMARY KEY,
  id TEXT,
  summary TEXT,
  status TEXT,
  assignee TEXT,
  updated TEXT,
  fields_json TEXT,
  fetched_at TEXT
);

CREATE TABLE IF NOT EXISTS view_issues (
  view_id TEXT NOT NULL,
  issue_key TEXT NOT NULL,
  position INTEGER NOT NULL,
  PRIMARY KEY (view_id, issue_key)
);

CREATE TABLE IF NOT EXISTS views (
  id TEXT PRIMARY KEY,
  name TEXT,
  jql TEXT,
  columns_json TEXT
);
"

/// Create all tables. Idempotent, so it is safe on every boot and request.
pub fn migrate(conn: sqlight.Connection) -> Result(Nil, DbError) {
  sqlight.exec(schema, on: conn)
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

/// Open + migrate at boot, so an unusable cache takes the server down early
/// instead of failing on the first request.
pub fn ensure_schema() -> Nil {
  let assert Ok(conn) = open()
  let assert Ok(_) = migrate(conn)
  Nil
}

/// Cache-on-fetch: replace every issue with fresh values and a new
/// `fetched_at`.
pub fn upsert_issues(
  conn: sqlight.Connection,
  issues: List(Issue),
) -> Result(Nil, DbError) {
  list.try_each(issues, fn(issue) { upsert_issue(conn, issue) })
}

fn upsert_issue(
  conn: sqlight.Connection,
  issue: Issue,
) -> Result(Nil, DbError) {
  let assignee =
    option.map(issue.assignee, fn(user) { user.display_name })
    |> option.unwrap("")
  sqlight.query(
    "INSERT OR REPLACE INTO issues
       (key, id, summary, status, assignee, updated, fields_json, fetched_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))",
    on: conn,
    with: [
      sqlight.text(issue.key),
      sqlight.text(issue.id),
      sqlight.text(issue.summary),
      sqlight.text(issue.status.name),
      sqlight.text(assignee),
      sqlight.text(issue.updated),
      sqlight.text(json.to_string(types.issue_to_json(issue))),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

/// All cached issues in insertion order (the Jira order of the last fetch).
pub fn load_issues(conn: sqlight.Connection) -> Result(List(Issue), DbError) {
  sqlight.query(
    "SELECT key, id, summary, status, assignee, updated
     FROM issues ORDER BY rowid",
    on: conn,
    with: [],
    expecting: issue_row_decoder(),
  )
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

/// Rows decode positionally. The columns only carry list-view data, so
/// status category and assignee avatar come back empty — `fields_json`
/// keeps the full issue for detail rendering later.
/// shortcut: round-trip loses status category + avatar; add columns when
/// the UI renders cached-only views.
fn issue_row_decoder() -> decode.Decoder(Issue) {
  use key <- decode.field(0, decode.string)
  use id <- decode.field(1, decode.string)
  use summary <- decode.field(2, decode.string)
  use status_name <- decode.field(3, decode.string)
  use assignee_name <- decode.field(4, decode.string)
  use updated <- decode.field(5, decode.string)
  let assignee = case assignee_name {
    "" -> None
    name -> Some(User(account_id: "", display_name: name, avatar_url: ""))
  }
  decode.success(Issue(
    key: key,
    id: id,
    summary: summary,
    status: Status(name: status_name, category: ""),
    assignee: assignee,
    updated: updated,
  ))
}
