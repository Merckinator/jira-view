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

import gleam/dynamic/decode
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
import shared/adf
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
    /// Transitions of the open issue, fetched when the panel opens.
    transitions: Option(Result(List(types.Transition), String)),
    /// Panel write errors (transition/comment/worklog failures).
    write_error: Option(String),
    /// Comment/worklog drafts and the texts/entries optimistically sent
    /// (rendered as "sending…" until the server confirms).
    comment_draft: String,
    pending_comments: List(String),
    worklog_draft: String,
    pending_worklog: List(String),
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
  // — Phase 4 writes —
  GotTransitions(Result(List(types.Transition), String))
  /// Click on a transition button: status flips optimistically, then the
  /// POST confirms (or a refetch undoes it).
  TransitionClicked(transition: types.Transition)
  /// Result of the transition POST for the open issue.
  GotTransition(key: String, to_status: String, result: Result(Nil, String))
  SetCommentDraft(String)
  CommentClicked
  GotComment(Result(types.Comment, String))
  SetWorklogDraft(String)
  WorklogClicked
  GotWorklog(Result(types.WorklogEntry, String))
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
      transitions: None,
      write_error: None,
      comment_draft: "",
      pending_comments: [],
      worklog_draft: "",
      pending_worklog: [],
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
      Model(
        ..model,
        selected: Some(DetailLoaded(detail)),
        // The fresh detail also refreshes the matching row (used after
        // transition failures to undo the optimistic flip).
        state: sync_ready_row(model.state, detail.issue),
      ),
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
    GotTransitions(Ok(transitions)) -> #(
      Model(..model, transitions: Some(Ok(transitions))),
      effect.none(),
    )
    GotTransitions(Error(message)) -> #(
      Model(..model, transitions: Some(Error(message))),
      effect.none(),
    )
    TransitionClicked(transition) ->
      case selected_key(model) {
        Ok(key) -> #(
          Model(
            ..model,
            // Optimistic: flip the row + the panel status immediately; a
            // failed POST is undone by the refetch in GotTransition below.
            state: flip_row_status(model.state, key, transition.to_status),
            selected: flip_detail_status(model.selected, transition.to_status),
            write_error: None,
          ),
          post_transition(key, transition),
        )
        Error(_) -> #(model, effect.none())
      }
    GotTransition(_key, _to_status, Ok(_)) -> #(model, effect.none())
    GotTransition(key, _to_status, Error(message)) -> #(
      Model(..model, write_error: Some(message)),
      fetch_detail(key),
    )
    SetCommentDraft(text) -> #(
      Model(..model, comment_draft: text),
      effect.none(),
    )
    CommentClicked ->
      case selected_key(model) {
        Ok(key) ->
          case string.trim(model.comment_draft) {
            "" -> #(model, effect.none())
            text -> #(
              Model(
                ..model,
                pending_comments: [text, ..model.pending_comments],
                comment_draft: "",
                write_error: None,
              ),
              post_comment(key, text),
            )
          }
        Error(_) -> #(model, effect.none())
      }
    GotComment(Ok(comment)) -> #(
      Model(
        ..model,
        pending_comments: drop_first(model.pending_comments),
        selected: append_comment(model.selected, comment),
      ),
      effect.none(),
    )
    GotComment(Error(message)) -> #(
      Model(
        ..model,
        pending_comments: drop_first(model.pending_comments),
        write_error: Some(message),
      ),
      effect.none(),
    )
    SetWorklogDraft(text) -> #(
      Model(..model, worklog_draft: text),
      effect.none(),
    )
    WorklogClicked ->
      case selected_key(model) {
        Ok(key) ->
          case string.trim(model.worklog_draft) {
            "" -> #(model, effect.none())
            time_spent -> #(
              Model(
                ..model,
                pending_worklog: [time_spent, ..model.pending_worklog],
                worklog_draft: "",
                write_error: None,
              ),
              post_worklog(key, time_spent),
            )
          }
        Error(_) -> #(model, effect.none())
      }
    GotWorklog(Ok(entry)) -> #(
      Model(
        ..model,
        pending_worklog: drop_first(model.pending_worklog),
        selected: append_worklog(model.selected, entry),
      ),
      effect.none(),
    )
    GotWorklog(Error(message)) -> #(
      Model(
        ..model,
        pending_worklog: drop_first(model.pending_worklog),
        write_error: Some(message),
      ),
      effect.none(),
    )
  }
}

fn open_detail(model: Model, key: String) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..model,
      selected: Some(DetailLoading(key)),
      transitions: None,
      write_error: None,
      comment_draft: "",
      pending_comments: [],
      worklog_draft: "",
      pending_worklog: [],
    ),
    effect.batch([fetch_detail(key), fetch_transitions(key)]),
  )
}

/// The key of the issue whose detail panel is open.
fn selected_key(model: Model) -> Result(String, Nil) {
  case model.selected {
    Some(DetailLoading(key)) -> Ok(key)
    Some(DetailLoaded(info)) -> Ok(info.issue.key)
    Some(DetailFailed(_)) -> Error(Nil)
    None -> Error(Nil)
  }
}

/// Optimistic status flip over the ready list; category is unknowable from
/// a transition (re-set on the next detail load).
fn flip_row_status(state: State, key: String, to_status: String) -> State {
  case state {
    Ready(issues) ->
      Ready(map_issue(issues, key, fn(issue) {
        types.Issue(
          ..issue,
          status: types.Status(to_status, issue.status.category),
        )
      }))
    state -> state
  }
}

fn flip_detail_status(
  selected: Option(Detail),
  to_status: String,
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(types.IssueDetail(
        ..info,
        issue: types.Issue(
          ..info.issue,
          status: types.Status(to_status, info.issue.status.category),
        ),
      )))
    selected -> selected
  }
}

/// Reconcile one row of the ready list with a freshly fetched issue.
fn sync_ready_row(state: State, fresh: types.Issue) -> State {
  case state {
    Ready(issues) -> Ready(sync_issue(issues, fresh))
    state -> state
  }
}

fn sync_issue(issues: List(types.Issue), fresh: types.Issue) -> List(types.Issue) {
  map_issue(issues, fresh.key, fn(_) { fresh })
}

fn map_issue(
  issues: List(types.Issue),
  key: String,
  transform: fn(types.Issue) -> types.Issue,
) -> List(types.Issue) {
  list.map(issues, fn(issue) {
    case issue.key == key {
      True -> transform(issue)
      False -> issue
    }
  })
}

fn drop_first(items: List(a)) -> List(a) {
  case items {
    [_, ..rest] -> rest
    [] -> []
  }
}

fn append_comment(selected: Option(Detail), comment: types.Comment) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(types.IssueDetail(
        ..info,
        comments: list.append(info.comments, [comment]),
      )))
    selected -> selected
  }
}

fn append_worklog(selected: Option(Detail), entry: types.WorklogEntry) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(types.IssueDetail(
        ..info,
        worklog: list.append(info.worklog, [entry]),
      )))
    selected -> selected
  }
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

fn fetch_transitions(key: String) -> Effect(Msg) {
  fetch.get("/jira/issue/" <> key <> "/transitions", fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, types.jira_transitions_decoder()) {
          Ok(transitions) -> GotTransitions(Ok(transitions))
          Error(error) -> GotTransitions(Error(string.inspect(error)))
        }
      Error(message) -> GotTransitions(Error(message))
    }
  })
}

fn post_transition(key: String, transition: types.Transition) -> Effect(Msg) {
  fetch.post_json(
    "/jira/issue/" <> key <> "/transition",
    json.to_string(json.object([#("id", json.string(transition.id))])),
    fn(result) { GotTransition(key, transition.to_status, result) },
  )
}

fn post_comment(key: String, text: String) -> Effect(Msg) {
  fetch.post_json_raw(
    "/jira/issue/" <> key <> "/comment",
    json.to_string(json.object([#("text", json.string(text))])),
    fn(response) {
      case response {
        Ok(body) ->
          case json.parse(body, created_comment_decoder()) {
            Ok(comment) -> GotComment(Ok(comment))
            Error(error) -> GotComment(Error(string.inspect(error)))
          }
        Error(message) -> GotComment(Error(message))
      }
    },
  )
}

fn post_worklog(key: String, time_spent: String) -> Effect(Msg) {
  fetch.post_json_raw(
    "/jira/issue/" <> key <> "/worklog",
    json.to_string(json.object([#("time_spent", json.string(time_spent))])),
    fn(response) {
      case response {
        Ok(body) ->
          case json.parse(body, created_worklog_decoder()) {
            Ok(entry) -> GotWorklog(Ok(entry))
            Error(error) -> GotWorklog(Error(string.inspect(error)))
          }
        Error(message) -> GotWorklog(Error(message))
      }
    },
  )
}

/// The created-record responses are {"comment": {…}} / {"worklog": {…}}:
/// decode straight to the inner record.
fn created_comment_decoder() -> decode.Decoder(types.Comment) {
  use comment <- decode.field("comment", types.app_comment_decoder())
  decode.success(comment)
}

fn created_worklog_decoder() -> decode.Decoder(types.WorklogEntry) {
  use entry <- decode.field("worklog", types.app_worklog_decoder())
  decode.success(entry)
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
      Some(detail) -> detail_panel(model, detail)
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

fn detail_panel(model: Model, detail: Detail) -> Element(Msg) {
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
        html.div([attribute.class("jv-detail-body")], [
          html.p([attribute.class("jv-detail-meta")], [
            text(info.issue.key <> " · " <> info.issue.status.name),
          ]),
          case model.write_error {
            Some(message) ->
              html.p([attribute.class("jv-write-error")], [text(message)])
            None -> element.none()
          },
          transitions_row(model.transitions),
          adf_view.render(info.description),
          comments_section(
            info.comments,
            model.pending_comments,
            model.comment_draft,
          ),
          worklog_section(
            info.worklog,
            model.pending_worklog,
            model.worklog_draft,
          ),
        ])
    },
  ])
}

/// One button per available transition of the open issue. The POST applies
/// optimistically in `update`; buttons stay enabled (double clicks are
/// guarded by Jira itself rejecting invalid moves).
fn transitions_row(
  transitions: Option(Result(List(types.Transition), String)),
) -> Element(Msg) {
  html.div([attribute.class("jv-transitions")], case transitions {
    Some(Ok(transitions)) ->
      list.map(transitions, fn(transition) {
        html.button(
          [attribute.class("jv-transition"), event.on_click(TransitionClicked(transition))],
          [text(transition.name)],
        )
      })
    Some(Error(message)) -> [
      html.span([attribute.class("jv-note")], [text("Transitions: " <> message)]),
    ]
    None -> [html.span([attribute.class("jv-note")], [text("Transitions…")])]
  })
}

fn comments_section(
  comments: List(types.Comment),
  pending: List(String),
  draft: String,
) -> Element(Msg) {
  html.div(
    [attribute.class("jv-section")],
    list.flatten([
      [html.h3([attribute.class("jv-section-title")], [text("Comments")])],
      list.map(pending, fn(pending_text) {
        html.div([attribute.class("jv-comment jv-pending")], [
          html.div([attribute.class("jv-comment-meta")], [text("sending…")]),
          adf_view.render(adf_document(pending_text)),
        ])
      }),
      list.map(comments, fn(comment) {
        html.div([attribute.class("jv-comment")], [
          html.div([attribute.class("jv-comment-meta")], [
            text(comment.author <> " · " <> comment.created),
          ]),
          adf_view.render(comment.body),
        ])
      }),
      [
        html.textarea([
          attribute.class("jv-comment-input"),
          attribute.placeholder("Add a comment…"),
          event.on_input(SetCommentDraft),
        ], draft),
        html.div([attribute.class("jv-actions")], [
          html.button([attribute.class("jv-comment-send"), event.on_click(CommentClicked)], [
            text("Comment"),
          ]),
        ]),
      ],
    ]),
  )
}

fn worklog_section(
  entries: List(types.WorklogEntry),
  pending: List(String),
  draft: String,
) -> Element(Msg) {
  html.div(
    [attribute.class("jv-section")],
    list.flatten([
      [html.h3([attribute.class("jv-section-title")], [text("Work log")])],
      list.map(pending, fn(time_spent) {
        html.div([attribute.class("jv-worklog jv-pending")], [
          html.div([attribute.class("jv-comment-meta")], [
            text("sending… · " <> time_spent),
          ]),
        ])
      }),
      list.map(entries, fn(entry) {
        let meta = entry.author <> " · " <> entry.time_spent <> " · " <> entry.started
        html.div([attribute.class("jv-worklog")], [
          html.div([attribute.class("jv-comment-meta")], [text(meta)]),
          case entry.body {
            [] -> element.none()
            body -> adf_view.render(body)
          },
        ])
      }),
      [
        html.div([attribute.class("jv-actions jv-worklog-form")], [
          html.input([
            attribute.type_("text"),
            attribute.class("jv-worklog-input"),
            attribute.placeholder("Time spent, e.g. 25m"),
            attribute.value(draft),
            event.on_input(SetWorklogDraft),
          ]),
          html.button([attribute.class("jv-worklog-send"), event.on_click(WorklogClicked)], [
            text("Log work"),
          ]),
        ]),
      ],
    ]),
  )
}

/// The ADF document for an optimistic comment still being sent.
fn adf_document(text: String) -> List(adf.AdfNode) {
  case adf.paragraph_document(text).content {
    [paragraph, ..] -> [paragraph]
    [] -> []
  }
}

fn detail_title(detail: Detail) -> String {
  case detail {
    DetailLoaded(info) -> info.issue.summary
    DetailLoading(key) -> key
    DetailFailed(_) -> "Detail"
  }
}