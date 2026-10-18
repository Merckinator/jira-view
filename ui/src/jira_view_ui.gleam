//// "My issues" — the first real view (Phase 2) + private ordering (Phase 3).
////
//// A Lustre MVU app: fetches GET /jira/search?jql=…&view=my-issues (the
//// backend proxy caches every fetch in SQLite and returns the view's
//// *merged* ordering — rows the user has privately ordered keep that
//// order, new ones appended), renders a table, and on row click opens a
//// detail panel whose description is rendered by the shared ADF decoder +
//// converter. The JQL box doubles as the explicit refresh control: edit it
//// and hit Refresh to refetch (and re-cache).
////
//// Ordering is the headline feature (Phase 3): rows drag via SortableJS —
//// the model is the source of truth, so a drop reorders the model and
//// PATCHes the full key list to /jira/views/:view/order — and Shift+j/K
//// move the focused row by keyboard (same save path as a drop). j/k walk
//// the focus cursor, Enter opens the detail for the focused row. A failed
//// order save surfaces as a toolbar note; the visual order stands until
//// the next refresh.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import jira_view_ui/adf_view
import jira_view_ui/fetch
import jira_view_ui/keyboard
import jira_view_ui/sortable
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import shared/types.{type Issue, type IssueDetail}

/// The plan's default view. JQL must be bounded: the new search endpoint
/// rejects unbounded queries (see plan gotchas).
pub const default_jql =
  "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"

/// The single hardcoded view until Phase 5 saved views arrive. Must match
/// what the backend /jira/search treats as its default.
pub const view_id = "my-issues"

pub type Model {
  Model(
    jql_input: String,
    state: State,
    selected: Option(Detail),
    /// Keyboard focus cursor: index into the ready list. j/k move it,
    /// Shift+j/K relocate the focused row, Enter opens its detail.
    cursor: Option(Int),
    /// Set when the last order save failed; cleared by the next success.
    order_error: Option(String),
  )
}

pub type State {
  Loading
  Failed(String)
  Ready(List(Issue))
}

pub type Detail {
  DetailLoading(key: String)
  DetailLoaded(IssueDetail)
  DetailFailed(String)
}

pub type Msg {
  GotIssues(Result(List(Issue), String))
  SetJql(String)
  Refresh
  Select(key: String)
  GotDetail(Result(IssueDetail, String))
  CloseDetail
  /// j/k: move the focus cursor one row down/up.
  FocusDown
  FocusUp
  /// Shift+j/K: relocate the focused row, then save the new order.
  RowDown
  RowUp
  /// Enter: open the detail panel for the focused row.
  Open
  /// SortableJS drop: old_index/new_index over the ready list (model indexes,
  /// post-drop semantics — one move, never a swap).
  Dropped(from: Int, to: Int)
  /// Result of the PATCH that persists a new ordering.
  OrderSaved(Result(Nil, String))
}

pub fn main() {
  let app = lustre.application(init: init, update: update, view: view)
  let assert Ok(_) = lustre.start(app, onto: "#app", with: Nil)
}

/// Keyboard bindings live here so the FFI whitelist and the message type
/// stay in lockstep; the names are raw `event.key` values.
pub fn keyboard_bindings() -> List(#(String, Msg)) {
  [
    #("j", FocusDown),
    #("k", FocusUp),
    #("J", RowDown),
    #("K", RowUp),
    #("Enter", Open),
  ]
}

pub fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    Model(
      jql_input: default_jql,
      state: Loading,
      selected: None,
      cursor: None,
      order_error: None,
    ),
    effect.batch([
      fetch_issues(default_jql),
      // Document-level key handler: attach once at startup (idempotent FFI).
      keyboard.attach(keyboard_bindings()),
    ]),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SetJql(jql) -> #(Model(..model, jql_input: jql), effect.none())
    Refresh -> #(Model(..model, state: Loading), fetch_issues(model.jql_input))
    GotIssues(Ok(issues)) -> #(
      Model(..model, state: Ready(issues), cursor: None),
      // (Re)attach drag-and-drop once the fresh tbody is in the DOM.
      sortable.attach(".jv-tbody", Dropped),
    )
    GotIssues(Error(message)) -> #(
      Model(..model, state: Failed(message)),
      effect.none(),
    )
    Select(key) -> open_detail(model, key)
    GotDetail(Ok(detail)) -> #(
      Model(..model, selected: Some(DetailLoaded(detail))),
      effect.none(),
    )
    GotDetail(Error(message)) -> #(
      Model(..model, selected: Some(DetailFailed(message))),
      effect.none(),
    )
    CloseDetail -> #(Model(..model, selected: None), effect.none())
    FocusDown -> #(
      Model(..model, cursor: focus(model.state, model.cursor, True)),
      effect.none(),
    )
    FocusUp -> #(
      Model(..model, cursor: focus(model.state, model.cursor, False)),
      effect.none(),
    )
    RowDown -> move_row(model, 1)
    RowUp -> move_row(model, -1)
    Open ->
      case model.state, model.cursor {
        Ready(issues), Some(index) ->
          case item_at(issues, index) {
            Ok(issue) -> open_detail(model, issue.key)
            Error(Nil) -> #(model, effect.none())
          }
        _, _ -> #(model, effect.none())
      }
    Dropped(from, to) ->
      case model.state {
        Ready(issues) -> {
          let issues = move_item(issues, from, to)
          #(
            Model(..model, state: Ready(issues)),
            save_order(issues),
          )
        }
        _ -> #(model, effect.none())
      }
    OrderSaved(Ok(_)) -> #(Model(..model, order_error: None), effect.none())
    OrderSaved(Error(message)) -> #(
      Model(..model, order_error: Some(message)),
      effect.none(),
    )
  }
}

fn open_detail(model: Model, key: String) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, selected: Some(DetailLoading(key))),
    fetch_detail(key),
  )
}

/// j/k: move the cursor, clamped inside the visible rows; starting out
/// opens at the top (j) or bottom (k) when nothing is focused yet.
fn focus(state: State, cursor: Option(Int), down: Bool) -> Option(Int) {
  case state {
    Ready(issues) ->
      case issues {
        [] -> cursor
        _ -> {
          let last = list.length(issues) - 1
          case cursor {
            None ->
              Some(case down {
                True -> 0
                False -> last
              })
            Some(index) ->
              Some(case down {
                True -> int.min(index + 1, last)
                False -> int.max(index - 1, 0)
              })
          }
        }
      }
    _ -> cursor
  }
}

/// Shift+j/K: relocate the focused row and persist the new order. The cursor
/// rides along with the moved row, so repeated Shift+j keeps walking it down.
fn move_row(model: Model, delta: Int) -> #(Model, Effect(Msg)) {
  case model.state, model.cursor {
    Ready(issues), Some(index) -> {
      let target = index + delta
      case target >= 0 && target < list.length(issues) {
        True -> {
          let issues = move_item(issues, index, target)
          #(
            Model(..model, state: Ready(issues), cursor: Some(target)),
            save_order(issues),
          )
        }
        False -> #(model, effect.none())
      }
    }
    _, _ -> #(model, effect.none())
  }
}

/// Remove the issue at `from` and reinsert it at `to` (post-drop index).
/// Out-of-range indexes return the list unchanged.
fn move_item(issues: List(Issue), from: Int, to: Int) -> List(Issue) {
  case from >= 0 && to >= 0, list.drop(issues, from) {
    True, [issue, ..rest] -> {
      let before = list.take(issues, from)
      case from < to {
        True -> list.append(before, insert_at(rest, to - from, issue))
        False -> list.append(insert_at(before, to, issue), rest)
      }
    }
    _, _ -> issues
  }
}

fn insert_at(items: List(a), at: Int, item: a) -> List(a) {
  list.append(list.take(items, at), [item, ..list.drop(items, at)])
}

fn item_at(issues: List(Issue), index: Int) -> Result(Issue, Nil) {
  case list.drop(issues, index) {
    [issue, ..] -> Ok(issue)
    [] -> Error(Nil)
  }
}

/// Persist the whole visible order (not just the moved pair), so previously
/// unordered ("appended") rows join the ordering the moment they are moved.
fn save_order(issues: List(Issue)) -> Effect(Msg) {
  let keys = list.map(issues, fn(issue) { issue.key })
  fetch.patch_json(
    "/jira/views/" <> view_id <> "/order",
    json.to_string(json.object([#("keys", json.array(keys, json.string))])),
    fn(result) {
      case result {
        Ok(_) -> OrderSaved(Ok(Nil))
        Error(message) -> OrderSaved(Error(message))
      }
    },
  )
}

fn fetch_issues(jql: String) -> Effect(Msg) {
  fetch.get(issues_url(jql), fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, types.issues_response_decoder()) {
          Ok(issues) -> GotIssues(Ok(issues))
          Error(error) -> GotIssues(Error(string.inspect(error)))
        }
      Error(message) -> GotIssues(Error(message))
    }
  })
}

fn fetch_detail(key: String) -> Effect(Msg) {
  fetch.get("/jira/issue/" <> key, fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, types.issue_detail_decoder()) {
          Ok(detail) -> GotDetail(Ok(detail))
          Error(error) -> GotDetail(Error(string.inspect(error)))
        }
      Error(message) -> GotDetail(Error(message))
    }
  })
}

fn issues_url(jql: String) -> String {
  "/jira/search?" <> uri.query_to_string([#("jql", jql), #("view", view_id)])
}

// ————— view —————

pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("jv")], [
    html.div([attribute.class("jv-toolbar")], [
      html.h1([attribute.class("jv-title")], [text("My issues")]),
      html.div([attribute.class("jv-jql")], [
        html.input([
          attribute.type_("text"),
          attribute.class("jv-jql-input"),
          attribute.value(model.jql_input),
          event.on_input(SetJql),
        ]),
        html.button([attribute.class("jv-refresh"), event.on_click(Refresh)], [
          text("Refresh"),
        ]),
      ]),
    ]),
    case model.order_error {
      Some(message) ->
        html.p([attribute.class("jv-order-error")], [
          text("Private order not saved: " <> message),
        ])
      None -> element.none()
    },
    case model.state {
      Loading -> html.p([attribute.class("jv-note")], [text("Loading…")])
      Failed(message) ->
        html.p([attribute.class("jv-error")], [text("Error: " <> message)])
      Ready(issues) ->
        case issues {
          [] -> html.p([attribute.class("jv-note")], [text("No issues.")])
          _ -> table(issues, model.cursor)
        }
    },
    case model.selected {
      Some(detail) -> detail_panel(detail)
      None -> element.none()
    },
  ])
}

fn table(issues: List(Issue), cursor: Option(Int)) -> Element(Msg) {
  // The <tr>s are KEYED by issue key: this is load-bearing for drag-and-drop.
  // SortableJS moves the physical nodes around behind Lustre's back during a
  // drag, and a positional (unkeyed) diff would patch row content into
  // whatever <tr> ends up at each index — visually scrambling the order.
  // With keys, Lustre's re-render MOVES the tracked rows into model order,
  // so model, DOM and saved order always agree.
  html.table([attribute.class("jv-table")], [
    html.thead([], [
      html.tr([], [
        html.th([attribute.class("jv-col-grab")], [text("")]),
        head("key"),
        head("summary"),
        head("status"),
        head("assignee"),
        head("updated"),
      ]),
    ]),
    keyed.element(
      "tbody",
      [attribute.class("jv-tbody")],
      list.index_map(issues, fn(issue, index) {
        #(issue.key, row(issue, index, cursor))
      }),
    ),
  ])
}

fn head(title: String) -> Element(Msg) {
  html.th([attribute.class("jv-col-" <> title)], [text(title)])
}

fn cell(content: String) -> Element(Msg) {
  html.td([], [text(content)])
}

fn row(issue: Issue, index: Int, cursor: Option(Int)) -> Element(Msg) {
  html.tr(
    [
      attribute.class(case cursor {
        Some(focused) if focused == index -> "jv-row jv-row-focused"
        _ -> "jv-row"
      }),
      event.on_click(Select(issue.key)),
    ],
    [
      html.td(
        [attribute.class("jv-grab"), attribute.title("Drag to reorder")],
        [text("⋮⋮")],
      ),
      cell(issue.key),
      cell(issue.summary),
      cell(issue.status.name),
      cell(assignee_name(issue.assignee)),
      cell(issue.updated),
    ],
  )
}

fn assignee_name(assignee: option.Option(types.User)) -> String {
  case assignee {
    Some(user) -> user.display_name
    None -> "—"
  }
}

fn detail_panel(detail: Detail) -> Element(Msg) {
  html.aside([attribute.class("jv-detail")], [
    html.div([attribute.class("jv-detail-head")], [
      html.h2([], [text(detail_title(detail))]),
      html.button([attribute.class("jv-close"), event.on_click(CloseDetail)], [
        text("✕"),
      ]),
    ]),
    case detail {
      DetailLoading(key) -> html.p([], [text("Loading " <> key <> "…")])
      DetailFailed(message) ->
        html.p([attribute.class("jv-error")], [text("Error: " <> message)])
      DetailLoaded(info) ->
        html.div([], [
          html.p([attribute.class("jv-detail-meta")], [
            text(info.issue.key <> " · " <> info.issue.status.name),
          ]),
          adf_view.render(info.description),
        ])
    },
  ])
}

fn detail_title(detail: Detail) -> String {
  case detail {
    DetailLoaded(info) -> info.issue.summary
    DetailLoading(key) -> key
    DetailFailed(_) -> "Detail"
  }
}