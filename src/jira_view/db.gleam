//// SQLite via sqlight: the issues read cache plus the (so far empty) tables
//// for private per-view ordering state. Server-side only; never compiled
//// for the JS target.

import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import shared/types.{type Issue, Issue, Status, User}
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

// ————— private per-view ordering (Phase 3) —————

/// Replace the saved ordering of a view with `keys`, in that order
/// (position = list index). The whole ordering is rewritten on every drop
/// rather than patched incrementally — simpler, and correct by construction
/// (rows not in the list simply disappear; the next save rewrites them).
pub fn save_view_order(
  conn: sqlight.Connection,
  view_id: String,
  keys: List(String),
) -> Result(Nil, DbError) {
  use _ <- result.try(
    sqlight.query(
      "DELETE FROM view_issues WHERE view_id = ?",
      on: conn,
      with: [sqlight.text(view_id)],
      expecting: decode.dynamic,
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(error) { Sqlite(string.inspect(error)) }),
  )
  keys
  |> list.index_map(fn(key, position) { #(key, position) })
  |> list.try_each(fn(row) {
    let #(key, position) = row
    sqlight.query(
      "INSERT INTO view_issues (view_id, issue_key, position) VALUES (?, ?, ?)",
      on: conn,
      with: [sqlight.text(view_id), sqlight.text(key), sqlight.int(position)],
      expecting: decode.dynamic,
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
  })
}

/// The saved ordering of a view: issue keys by ascending position.
pub fn load_view_order(
  conn: sqlight.Connection,
  view_id: String,
) -> Result(List(String), DbError) {
  sqlight.query(
    "SELECT issue_key FROM view_issues WHERE view_id = ? ORDER BY position",
    on: conn,
    with: [sqlight.text(view_id)],
    expecting: single_column_decoder(),
  )
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

/// Rows decode one value each; sqlight wraps them into a list.
fn single_column_decoder() -> decode.Decoder(String) {
  decode.field(0, decode.string, decode.success)
}

/// Merge Jira's fetched order (from the last search) with a view's private
/// ordering: previously-ordered issues keep their saved order (with fresh
/// field values), issues the save never saw are appended at the end in Jira
/// order, and saved keys that are no longer in the fetched set are dropped.
/// Pure — unit-tested against exactly the semantics the UI relies on.
pub fn merge_view_order(
  saved: List(String),
  issues: List(Issue),
) -> List(Issue) {
  let by_key =
    list.fold(issues, dict.new(), fn(acc, issue) {
      dict.insert(acc, issue.key, issue)
    })
  let ordered =
    list.filter_map(saved, fn(key) {
      case dict.get(by_key, key) {
        Ok(issue) -> Ok(issue)
        Error(_) -> Error(Nil)
      }
    })
  let saved_keys = set.from_list(saved)
  let rest =
    list.filter(issues, fn(issue) { !set.contains(saved_keys, issue.key) })
  list.append(ordered, rest)
}
