//// SQLite via sqlight: saved views and their private per-view ordering.
//// Server-side only; never compiled for the JS target.

import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import shared/types.{type Issue, type ViewDef, Jql, ViewDef}
import sqlight

pub type DbError {
  /// Filesystem/sqlite failure while opening or querying, debug-rendered.
  Sqlite(String)
  /// A view id does not exist.
  NotFound
}

/// Where the database lives. `JIRA_VIEW_DB` overrides; the default is the
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

/// Remove the old write-only issue cache from databases created before it
/// was dropped. Fresh databases never create the table; this is a no-op
/// there. A failure (e.g. a locked db) is safe to retry on the next request.
const drop_issue_cache_migration = "DROP TABLE IF EXISTS issues"

/// Schema evolution: board-backed views (Phase 5). SQLite's ALTER TABLE
/// errors when the column already exists; any failure here is swallowed —
/// duplicate column is the only known failure mode.
const board_column_migration = "ALTER TABLE views ADD COLUMN board_id INTEGER"

/// The seeding of a genuinely fresh database: exactly one view so the app
/// is usable (and addressable as /jira/views/…) before the user edits it.
const seed_view_id = "my-issues"
const seed_view_name = "My issues"
const seed_view_jql =
  "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"

/// Columns in the order they render; saved views may store any subset.
pub fn default_columns() -> List(String) {
  ["key", "summary", "status", "assignee", "updated"]
}

/// Create/evolve all tables + seed the default view on a genuinely fresh
/// database. Idempotent, so it is safe on every boot and request.
pub fn migrate(conn: sqlight.Connection) -> Result(Nil, DbError) {
  use views_table_existed <- result.try(views_table_exists(conn))
  use _ <- result.try(
    sqlight.exec(schema, on: conn)
    |> result.map_error(fn(error) { Sqlite(string.inspect(error)) }),
  )
  // Phase 5 evolution; errors swallowed (duplicate column = already ran).
  let _ = sqlight.exec(board_column_migration, on: conn)
  case views_table_existed {
    True -> Ok(Nil)
    False ->
      seed_view(conn, ViewDef(
        id: seed_view_id,
        name: seed_view_name,
        source: Jql(seed_view_jql),
        columns: default_columns(),
      ))
  }
}

/// Whether the `views` table predates this migrate call. A fresh database gets
/// the default view; an existing one stays exactly as the user left it, even
/// if every view has been deleted.
fn views_table_exists(conn: sqlight.Connection) -> Result(Bool, DbError) {
  sqlight.query(
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'views'",
    on: conn,
    with: [],
    expecting: count_decoder(),
  )
  |> result.map(fn(count) { list.first(count) == Ok(1) })
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

/// Scalar COUNT(*) comes back as a one-row list of one integer column.
fn count_decoder() -> decode.Decoder(Int) {
  decode.field(0, decode.int, decode.success)
}

fn seed_view(conn: sqlight.Connection, view: ViewDef) -> Result(Nil, DbError) {
  insert_view(conn, view.id, view)
}

/// Open + migrate at boot, so an unusable database takes the server down early
/// instead of failing on the first request. The one-time drop of the old
/// issue cache lives here, not in `migrate`, which runs on every request.
pub fn ensure_schema() -> Nil {
  let assert Ok(conn) = open()
  let assert Ok(_) = migrate(conn)
  let _ = sqlight.exec(drop_issue_cache_migration, on: conn)
  Nil
}

// ————— private per-view ordering (Phase 3) —————

/// Run `next` inside a write transaction. SQLite's busy timeout (set by the
/// driver) lets a concurrent writer wait instead of interleaving statements.
fn in_transaction(
  conn: sqlight.Connection,
  next: fn() -> Result(a, DbError),
) -> Result(a, DbError) {
  use _ <- result.try(exec_sql(conn, "BEGIN IMMEDIATE"))
  case next() {
    Ok(value) ->
      case exec_sql(conn, "COMMIT") {
        Ok(_) -> Ok(value)
        Error(error) -> {
          let _ = exec_sql(conn, "ROLLBACK")
          Error(error)
        }
      }
    Error(error) -> {
      let _ = exec_sql(conn, "ROLLBACK")
      Error(error)
    }
  }
}

fn exec_sql(conn: sqlight.Connection, sql: String) -> Result(Nil, DbError) {
  sqlight.exec(sql, on: conn)
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

/// Replace the saved ordering of a view with `keys`, in that order
/// (position = list index). The whole ordering is rewritten on every drop
/// rather than patched incrementally — simpler, and correct by construction
/// (rows not in the list simply disappear; the next save rewrites them).
/// The delete and inserts are one transaction: a bad key leaves the previous
/// ordering untouched instead of half-erasing it.
pub fn save_view_order(
  conn: sqlight.Connection,
  view_id: String,
  keys: List(String),
) -> Result(Nil, DbError) {
  in_transaction(conn, fn() {
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

// ————— saved views (Phase 5) —————

/// All saved views in creation order.
pub fn list_views(conn: sqlight.Connection) -> Result(List(ViewDef), DbError) {
  sqlight.query(
    "SELECT id, name, jql, board_id, columns_json FROM views ORDER BY rowid",
    on: conn,
    with: [],
    expecting: view_row_decoder(),
  )
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

/// One saved view, or NotFound.
pub fn get_view(
  conn: sqlight.Connection,
  view_id: String,
) -> Result(ViewDef, DbError) {
  sqlight.query(
    "SELECT id, name, jql, board_id, columns_json FROM views WHERE id = ?",
    on: conn,
    with: [sqlight.text(view_id)],
    expecting: view_row_decoder(),
  )
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
  |> result.try(fn(views) {
    case views {
      [view] -> Ok(view)
      _ -> Error(NotFound)
    }
  })
}

fn view_row_decoder() -> decode.Decoder(ViewDef) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use jql <- decode.field(2, decode.optional(decode.string))
  use board_id <- decode.field(3, decode.optional(decode.int))
  use columns_json <- decode.field(4, decode.string)
  let source = case jql {
    Some(jql) -> Jql(jql)
    None ->
      types.Board(case board_id {
        Some(id) -> id
        None -> 0
      })
  }
  let columns =
    json.parse(columns_json, decode.list(decode.string))
    |> result.unwrap(default_columns())
  decode.success(types.ViewDef(id:, name:, source:, columns:))
}

fn insert_view(
  conn: sqlight.Connection,
  view_id: String,
  view: ViewDef,
) -> Result(Nil, DbError) {
  sqlight.query(
    "INSERT INTO views (id, name, jql, board_id, columns_json) VALUES (?, ?, ?, ?, ?)",
    on: conn,
    with: view_params(Some(view_id), view),
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

/// Insert a view whose id must be unique (the caller slugs/guards it).
pub fn create_view(conn: sqlight.Connection, view: ViewDef) -> Result(Nil, DbError) {
  insert_view(conn, view.id, view)
}

/// Replace name/source/columns of an existing view. Returns NotFound when the
/// id does not exist (an UPDATE that matches no rows is not a success).
pub fn update_view(
  conn: sqlight.Connection,
  view_id: String,
  view: ViewDef,
) -> Result(Nil, DbError) {
  use _ <- result.try(
    sqlight.query(
      "UPDATE views SET name = ?, jql = ?, board_id = ?, columns_json = ? WHERE id = ?",
      on: conn,
      with: list.append(view_params(None, view), [sqlight.text(view_id)]),
      expecting: decode.dynamic,
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(error) { Sqlite(string.inspect(error)) }),
  )
  use changed <- result.try(changed_rows(conn))
  case changed {
    0 -> Error(NotFound)
    _ -> Ok(Nil)
  }
}

/// Number of rows the last statement on this connection changed.
fn changed_rows(conn: sqlight.Connection) -> Result(Int, DbError) {
  sqlight.query(
    "SELECT changes()",
    on: conn,
    with: [],
    expecting: count_decoder(),
  )
  |> result.map(fn(counts) { list.first(counts) |> result.unwrap(0) })
  |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
}

fn view_params(
  explicit_id: Option(String),
  view: ViewDef,
) -> List(sqlight.Value) {
  let #(jql, board_id) = case view.source {
    Jql(jql) -> #(Some(jql), None)
    types.Board(board_id) -> #(None, Some(board_id))
  }
  let columns = json.to_string(json.array(view.columns, json.string))
  let id = case explicit_id {
    Some(id) -> [sqlight.text(id)]
    None -> []
  }
  list.flatten([
    id,
    [sqlight.text(view.name)],
    [sqlight.nullable(sqlight.text, jql)],
    [sqlight.nullable(sqlight.int, board_id)],
    [sqlight.text(columns)],
  ])
}

/// Delete a view and its private ordering rows (ordering state must not
/// outlive its view). One transaction, so a failure cannot leave half a
/// deleted view behind.
pub fn delete_view(
  conn: sqlight.Connection,
  view_id: String,
) -> Result(Nil, DbError) {
  in_transaction(conn, fn() {
    use _ <- result.try(
      sqlight.query(
        "DELETE FROM views WHERE id = ?",
        on: conn,
        with: [sqlight.text(view_id)],
        expecting: decode.dynamic,
      )
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(error) { Sqlite(string.inspect(error)) }),
    )
    sqlight.query(
      "DELETE FROM view_issues WHERE view_id = ?",
      on: conn,
      with: [sqlight.text(view_id)],
      expecting: decode.dynamic,
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(error) { Sqlite(string.inspect(error)) })
  })
}

/// Slug a view name into a reusable id ("Q3 Sprint!" -> "q3-sprint"),
/// then make it unique against existing views ("q3-sprint-2").
pub fn unique_view_id(conn: sqlight.Connection, name: String) -> String {
  let base = case slug(name) {
    "" -> "view"
    slug -> slug
  }
  case get_view(conn, base) {
    Error(_) -> base
    Ok(_) -> take_free_suffix(conn, base, 2)
  }
}

fn take_free_suffix(
  conn: sqlight.Connection,
  base: String,
  suffix: Int,
) -> String {
  let candidate = base <> "-" <> int.to_string(suffix)
  case get_view(conn, candidate) {
    Error(_) -> candidate
    Ok(_) -> take_free_suffix(conn, base, suffix + 1)
  }
}

fn slug(name: String) -> String {
  name
  |> string.lowercase
  |> string.trim
  |> string.to_graphemes
  |> list.map(fn(grapheme) {
    case is_slug_char(grapheme) {
      True -> grapheme
      False -> "-"
    }
  })
  |> string.concat
  |> collapse_dashes
  |> drop_leading_dashes
  |> drop_trailing_dashes
}

/// ASCII lowercase letters and digits only — view ids double as URL
/// segments and database keys.
fn is_slug_char(grapheme: String) -> Bool {
  case string.to_utf_codepoints(grapheme) {
    [codepoint] -> {
      let code = string.utf_codepoint_to_int(codepoint)
      { code >= 48 && code <= 57 } || { code >= 97 && code <= 122 }
    }
    _ -> False
  }
}

fn collapse_dashes(text: String) -> String {
  case string.contains(text, "--") {
    True -> collapse_dashes(string.replace(text, "--", "-"))
    False -> text
  }
}

fn drop_leading_dashes(text: String) -> String {
  case string.starts_with(text, "-") {
    True -> drop_leading_dashes(string.drop_start(text, 1))
    False -> text
  }
}

fn drop_trailing_dashes(text: String) -> String {
  case string.ends_with(text, "-") {
    True -> drop_trailing_dashes(string.drop_end(text, 1))
    False -> text
  }
}
