//// "My issues" — Lustre MVU app over the backend proxy.
////
//// Phase 2: table + detail panel with ADF rendering. Phase 3: private
//// drag-and-drop ordering (SortableJS + a keyed tbody; a drop reorders
//// the model and PATCHes the full key list to /jira/views/:view/order)
//// and keyboard navigation (Tab into the table; j/k cursor, Shift+j/K
//// relocate, Enter opens the detail in place of the list, Esc closes it and
//// returns focus to the list). Phase 4: optimistic
//// writes in the panel — summary, transitions (status flips locally first),
//// comments (basic formatting), work log, labels and assignee; failures undo
//// themselves by refetching. Phase 5: saved views — a picker over
//// GET /jira/views (each with its own source: JQL or a board's active
//// sprint), its own column set, and its own private ordering; an edit
//// panel creates/renames/re-sources/deletes views. The browser only ever
//// talks to localhost: avatars/attachments render via /jira/* proxies.

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
import jira_view_ui/ordering
import jira_view_ui/palette
import jira_view_ui/sortable
import jira_view_ui/theme
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/keyed
import lustre/element/svg
import lustre/event
import shared/adf
import shared/types.{type Issue, type IssueDetail}

/// Fallback/pre-fill for JQL-mode views (bounded, per plan gotchas).
pub const default_jql =
  "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"

pub const default_columns = ["key", "summary", "status", "assignee", "updated"]

pub type Model {
  Model(
    /// Saved views: the picker's + editor's data.
    views: ViewList,
    current_view: Option(types.ViewDef),
    /// Board options for the editor, fetched when it opens.
    boards: Option(Result(List(types.AgileBoard), String)),
    edit: Option(EditForm),
    view_error: Option(String),
    /// Color-scheme preference: Auto/Light/Dark.
    theme: theme.Theme,
    /// Whether the floating appearance dialog is open.
    theme_palette_open: Bool,
    // — issues of the current view —
    jql_input: String,
    state: State,
    // — ordering (Phase 3) —
    cursor: Option(Int),
    order_error: Option(String),
    // — detail panel writes (Phase 4) —
    selected: Option(Detail),
    transitions: Option(Result(List(types.Transition), String)),
    /// Candidates for the detail panel's assignee picker.
    assignable: Option(Result(List(types.User), String)),
    resolutions: Option(Result(List(types.Resolution), String)),
    resolution_draft: String,
    /// The summary being edited; `None` means the header shows the read-only
    /// title. A `Some("")` draft is allowed while typing.
    summary_edit: Option(String),
    write_error: Option(String),
    comment_draft: String,
    pending_comments: List(String),
    worklog_draft: String,
    pending_worklog: List(String),
    label_draft: String,
  )
}

pub type ViewList {
  ViewsLoading
  ViewsFailed(String)
  ViewsLoaded(List(types.ViewDef))
}

/// One view editor; `id: None` while creating.
pub type EditForm {
  EditForm(
    id: Option(String),
    name: String,
    source: types.ViewSource,
    columns: List(String),
    /// First click arms the Delete button; the second click deletes.
    confirm_delete: Bool,
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
  GotViews(Result(List(types.ViewDef), String))
  SelectView(id: String)
  NewView
  EditExisting
  CancelEdit
  PickJqlSource
  SetEditName(String)
  SetEditJql(String)
  SetEditBoard(Int)
  ToggleColumn(column: String, checked: Bool)
  SaveView
  GotViewSaved(Result(types.ViewDef, String))
  DeleteView
  GotViewDeleted(id: String, result: Result(Nil, String))
  GotBoards(Result(List(types.AgileBoard), String))
  SetJql(String)
  ToggleThemePalette
  CloseThemePalette
  ThemePaletteClosed
  SetTheme(theme.Theme)
  CycleTheme
  NoOp
  Refresh
  GotIssues(view_id: String, result: Result(List(Issue), String))
  FocusDown
  FocusUp
  TableFocused
  RowDown
  RowUp
  Open
  Dropped(from: Int, to: Int)
  OrderSaved(Result(Nil, String))
  Select(key: String)
  GotDetail(key: String, result: Result(IssueDetail, String))
  Escape
  CloseDetail
  EditSummary
  SetSummaryDraft(String)
  SaveSummary
  CancelSummaryEdit
  GotSummarySaved(key: String, result: Result(Nil, String))
  GotTransitions(key: String, result: Result(List(types.Transition), String))
  GotAssignable(key: String, result: Result(List(types.User), String))
  SetAssignee(assignee: Option(types.User))
  GotAssignee(key: String, result: Result(Nil, String))
  SetFlagged(flagged: Bool)
  GotFlagged(key: String, result: Result(Nil, String))
  GotResolutions(Result(List(types.Resolution), String))
  SetResolution(String)
  TransitionClicked(transition: types.Transition)
  GotTransition(key: String, to_status: String, result: Result(Nil, String))
  SetCommentDraft(String)
  CommentClicked
  GotComment(Result(types.Comment, String))
  SetWorklogDraft(String)
  WorklogClicked
  GotWorklog(Result(types.WorklogEntry, String))
  SetLabelDraft(String)
  AddLabel
  RemoveLabel(label: String)
  GotLabels(key: String, result: Result(Nil, String))
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
    #("Escape", Escape),
  ]
}

pub fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    Model(
      views: ViewsLoading,
      current_view: None,
      boards: None,
      edit: None,
      view_error: None,
      theme: theme.load(),
      theme_palette_open: False,
      jql_input: default_jql,
      state: Loading,
      cursor: None,
      order_error: None,
      selected: None,
      transitions: None,
      assignable: None,
      resolutions: None,
      resolution_draft: "",
      summary_edit: None,
      write_error: None,
      comment_draft: "",
      pending_comments: [],
      worklog_draft: "",
      pending_worklog: [],
      label_draft: "",
    ),
    effect.batch([
      fetch_views(),
      fetch_resolutions(),
      // Document-level key handler: attach once at startup (idempotent FFI).
      keyboard.attach(keyboard_bindings()),
      effect.from(fn(dispatch) {
        palette.attach_shortcut(fn() { dispatch(ToggleThemePalette) })
      }),
    ]),
  )
}

// ————— update —————

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // — Phase 5: saved views —
    GotViews(Ok(views)) -> view_list_ready(model, views)
    GotViews(Error(message)) -> #(
      Model(..model, views: ViewsFailed(message)),
      effect.none(),
    )
    SelectView(id) ->
      case model.views {
        ViewsLoaded(views) ->
          case list.find(views, fn(view) { view.id == id }) {
            Ok(view) -> switch_to_view(model, view)
            Error(_) -> #(model, effect.none())
          }
        _ -> #(model, effect.none())
      }
    NewView -> #(
      Model(
        ..model,
        edit: Some(new_edit_form()),
        boards: None,
        view_error: None,
      ),
      fetch_boards(),
    )
    EditExisting ->
      case model.current_view {
        Some(view) -> #(
          Model(
            ..model,
            edit: Some(EditForm(
              id: Some(view.id),
              name: view.name,
              source: view.source,
              columns: view.columns,
              confirm_delete: False,
            )),
            boards: None,
            view_error: None,
          ),
          fetch_boards(),
        )
        None -> #(model, effect.none())
      }
    CancelEdit -> #(Model(..model, edit: None, view_error: None), effect.none())
    PickJqlSource ->
      case model.edit {
        Some(form) -> #(
          Model(..model, edit: Some(EditForm(..form, source: types.Jql("")))),
          effect.none(),
        )
        None -> #(model, effect.none())
      }
    SetEditName(name) ->
      case model.edit {
        Some(form) -> #(
          Model(..model, edit: Some(EditForm(..form, name:))),
          effect.none(),
        )
        None -> #(model, effect.none())
      }
    SetEditJql(jql) ->
      case model.edit {
        Some(form) -> #(
          Model(..model, edit: Some(EditForm(..form, source: types.Jql(jql)))),
          effect.none(),
        )
        None -> #(model, effect.none())
      }
    SetEditBoard(board_id) ->
      case model.edit {
        Some(form) -> #(
          Model(
            ..model,
            edit: Some(EditForm(..form, source: types.Board(board_id))),
          ),
          effect.none(),
        )
        None -> #(model, effect.none())
      }
    ToggleColumn(column, checked) ->
      case model.edit {
        Some(form) -> #(
          Model(
            ..model,
            edit: Some(
              EditForm(
                ..form,
                columns: set_column(form.columns, column, checked),
              ),
            ),
          ),
          effect.none(),
        )
        None -> #(model, effect.none())
      }
    SaveView ->
      case model.edit {
        Some(form) -> #(
          Model(..model, view_error: None),
          save_view_effect(form),
        )
        None -> #(model, effect.none())
      }
    GotViewSaved(Ok(view)) ->
      switch_to_view(
        Model(
          ..model,
          views: upsert_view(model.views, view),
          current_view: Some(view),
          edit: None,
          view_error: None,
        ),
        view,
      )
    GotViewSaved(Error(message)) -> #(
      Model(..model, view_error: Some(message)),
      effect.none(),
    )
    DeleteView ->
      case model.edit {
        Some(form) ->
          case form {
            EditForm(Some(id), _, _, _, confirm_delete) ->
              case confirm_delete {
                False -> #(
                  Model(
                    ..model,
                    edit: Some(EditForm(..form, confirm_delete: True)),
                  ),
                  effect.none(),
                )
                True -> #(
                  Model(..model, view_error: None),
                  fetch.delete_json("/jira/views/" <> id, fn(result) {
                    GotViewDeleted(id, result)
                  }),
                )
              }
            EditForm(None, _, _, _, _) -> #(model, effect.none())
          }
        None -> #(model, effect.none())
      }
    GotViewDeleted(id, Ok(_)) -> {
      let remaining = case model.views {
        ViewsLoaded(views) -> list.filter(views, fn(view) { view.id != id })
        _ -> []
      }
      case remaining {
        [] -> #(
          Model(
            ..model,
            views: ViewsLoaded([]),
            current_view: None,
            edit: None,
            view_error: None,
          ),
          effect.none(),
        )
        [view, ..] ->
          switch_to_view(
            Model(
              ..model,
              views: ViewsLoaded(remaining),
              edit: None,
              view_error: None,
            ),
            view,
          )
      }
    }
    GotViewDeleted(_, Error(message)) -> #(
      Model(..model, view_error: Some(message)),
      effect.none(),
    )
    GotBoards(boards) -> #(Model(..model, boards: Some(boards)), effect.none())

    // — current view's issues —
    SetJql(jql) -> #(Model(..model, jql_input: jql), effect.none())
    ToggleThemePalette -> {
      let open = !model.theme_palette_open
      #(Model(..model, theme_palette_open: open), palette_effect(open))
    }
    CloseThemePalette -> #(
      Model(..model, theme_palette_open: False),
      palette_effect(False),
    )
    ThemePaletteClosed -> #(
      Model(..model, theme_palette_open: False),
      effect.none(),
    )
    SetTheme(next) -> #(
      Model(..model, theme: next, theme_palette_open: False),
      effect.batch([
        effect.from(fn(_dispatch) { theme.apply(next) }),
        palette_effect(False),
      ]),
    )
    CycleTheme -> {
      let next = theme.next(model.theme)
      #(
        Model(..model, theme: next),
        effect.from(fn(_dispatch) { theme.apply(next) }),
      )
    }
    NoOp -> #(model, effect.none())
    Refresh ->
      case model.current_view {
        Some(view) ->
          case view.source {
            types.Jql(_) -> #(
              Model(..model, state: Loading),
              fetch.get(search_url(view.id, model.jql_input), fn(response) {
                decode_issues(view.id, response)
              }),
            )
            types.Board(_) -> #(
              Model(..model, state: Loading),
              fetch_issues_effect(view),
            )
          }
        None -> #(model, effect.none())
      }
    GotIssues(view_id, Ok(issues)) ->
      case is_current_view(model, view_id) {
        True -> #(
          Model(..model, state: Ready(issues), cursor: None),
          // (Re)attach drag-and-drop once the fresh tbody is in the DOM.
          sortable.attach(".jv-tbody", Dropped),
        )
        False -> #(model, effect.none())
      }
    GotIssues(view_id, Error(message)) ->
      case is_current_view(model, view_id) {
        True -> #(Model(..model, state: Failed(message)), effect.none())
        False -> #(model, effect.none())
      }

    // — Phase 3: ordering —
    FocusDown -> #(
      Model(..model, cursor: focus(model.state, model.cursor, True)),
      effect.none(),
    )
    FocusUp -> #(
      Model(..model, cursor: focus(model.state, model.cursor, False)),
      effect.none(),
    )
    // Tab lands on the table: highlight the first row if nothing is focused,
    // so Enter works immediately and the user can see where they are.
    TableFocused ->
      case model.cursor {
        None -> #(
          Model(..model, cursor: focus(model.state, None, True)),
          effect.none(),
        )
        Some(_) -> #(model, effect.none())
      }
    RowDown -> move_row(model, 1)
    RowUp -> move_row(model, -1)
    Open ->
      // The list is hidden while a detail is open; Enter belongs to the list.
      case model.selected {
        Some(_) -> #(model, effect.none())
        None ->
          case model.state, model.cursor {
            Ready(issues), Some(index) ->
              case item_at(issues, index) {
                Ok(issue) -> open_detail(model, issue.key)
                Error(Nil) -> #(model, effect.none())
              }
            _, _ -> #(model, effect.none())
          }
      }
    Dropped(from, to) ->
      case model.state {
        Ready(issues) -> {
          let issues = ordering.move_item(issues, from, to)
          #(
            Model(..model, state: Ready(issues)),
            save_order(issues, model.current_view),
          )
        }
        _ -> #(model, effect.none())
      }
    OrderSaved(Ok(_)) -> #(Model(..model, order_error: None), effect.none())
    OrderSaved(Error(message)) -> #(
      Model(..model, order_error: Some(message)),
      effect.none(),
    )

    // — Phases 2/4: detail + writes —
    Select(key) -> open_detail(model, key)
    GotDetail(key, Ok(detail)) ->
      case is_selected(model, key) {
        True -> #(
          Model(
            ..model,
            selected: Some(DetailLoaded(detail)),
            // The fresh detail also refreshes the matching row (used after
            // transition failures to undo the optimistic flip).
            state: sync_ready_row(model.state, detail.issue),
          ),
          effect.none(),
        )
        False -> #(model, effect.none())
      }
    GotDetail(key, Error(message)) ->
      case is_selected(model, key) {
        True -> #(
          Model(..model, selected: Some(DetailFailed(message))),
          effect.none(),
        )
        False -> #(model, effect.none())
      }
    // Escape closes an open detail; otherwise it leaves whichever control has
    // focus and returns to the list, where j/k/Enter work again. The view
    // editor keeps its own controls, so there Escape stays a no-op.
    Escape ->
      case model.summary_edit {
        Some(_) -> cancel_summary_edit(model)
        None ->
          case model.selected {
            Some(_) -> close_detail(model)
            None ->
              case model.edit {
                Some(_) -> #(model, effect.none())
                None -> #(model, keyboard.focus_table())
              }
          }
      }
    CloseDetail -> close_detail(model)
    EditSummary -> edit_summary(model)
    SetSummaryDraft(text) ->
      case model.summary_edit {
        Some(_) -> #(Model(..model, summary_edit: Some(text)), effect.none())
        None -> #(model, effect.none())
      }
    SaveSummary -> save_summary(model)
    CancelSummaryEdit -> cancel_summary_edit(model)
    GotSummarySaved(_, Ok(_)) -> #(model, effect.none())
    GotSummarySaved(key, Error(message)) ->
      case is_selected(model, key) {
        True -> #(
          Model(..model, write_error: Some(message), summary_edit: None),
          fetch_detail(key),
        )
        False -> #(model, effect.none())
      }
    GotTransitions(key, Ok(transitions)) ->
      case is_selected(model, key) {
        True -> #(
          Model(..model, transitions: Some(Ok(transitions))),
          effect.none(),
        )
        False -> #(model, effect.none())
      }
    GotTransitions(key, Error(message)) ->
      case is_selected(model, key) {
        True -> #(
          Model(..model, transitions: Some(Error(message))),
          effect.none(),
        )
        False -> #(model, effect.none())
      }
    GotAssignable(key, Ok(users)) ->
      case is_selected(model, key) {
        True -> #(Model(..model, assignable: Some(Ok(users))), effect.none())
        False -> #(model, effect.none())
      }
    GotAssignable(key, Error(message)) ->
      case is_selected(model, key) {
        True -> #(
          Model(..model, assignable: Some(Error(message))),
          effect.none(),
        )
        False -> #(model, effect.none())
      }
    SetAssignee(assignee) ->
      case selected_key(model) {
        Error(_) -> #(model, effect.none())
        Ok(key) ->
          case same_assignee(current_assignee(model), assignee) {
            True -> #(model, effect.none())
            False -> #(
              Model(..with_assignee(model, key, assignee), write_error: None),
              put_assignee(key, assignee),
            )
          }
      }
    GotAssignee(_, Ok(_)) -> #(model, effect.none())
    GotAssignee(key, Error(message)) ->
      case is_selected(model, key) {
        True -> #(
          Model(..model, write_error: Some(message)),
          // The optimistic change is rolled back by the fresh detail; its
          // response also syncs the matching list row.
          fetch_detail(key),
        )
        False -> #(model, effect.none())
      }
    SetFlagged(flagged) ->
      case selected_key(model) {
        Error(_) -> #(model, effect.none())
        Ok(key) ->
          case current_flagged(model) == flagged {
            True -> #(model, effect.none())
            False -> #(
              Model(..with_flagged(model, key, flagged), write_error: None),
              put_flagged(key, flagged),
            )
          }
      }
    GotFlagged(_, Ok(_)) -> #(model, effect.none())
    GotFlagged(key, Error(message)) ->
      case is_selected(model, key) {
        True -> #(
          Model(..model, write_error: Some(message)),
          // The optimistic change is rolled back by the fresh detail; its
          // response also syncs the matching list row.
          fetch_detail(key),
        )
        False -> #(model, effect.none())
      }
    GotResolutions(Ok(resolutions)) -> #(
      Model(
        ..model,
        resolutions: Some(Ok(resolutions)),
        resolution_draft: choose_resolution(model.resolution_draft, resolutions),
      ),
      effect.none(),
    )
    GotResolutions(Error(message)) -> #(
      Model(..model, resolutions: Some(Error(message))),
      effect.none(),
    )
    SetResolution(name) -> #(
      Model(..model, resolution_draft: name),
      effect.none(),
    )
    TransitionClicked(transition) ->
      case selected_key(model) {
        Error(_) -> #(model, effect.none())
        Ok(key) -> {
          let requires_resolution = transition_requires_resolution(transition)
          case requires_resolution, string.trim(model.resolution_draft) {
            True, "" -> #(
              Model(..model, write_error: Some("Pick a resolution first.")),
              effect.none(),
            )
            _, _ -> {
              let resolution = case requires_resolution {
                True -> Some(string.trim(model.resolution_draft))
                False -> None
              }
              #(
                Model(
                  ..model,
                  state: flip_row_status(model.state, key, transition.to_status),
                  selected: flip_detail_status(
                    model.selected,
                    transition.to_status,
                  ),
                  write_error: None,
                ),
                post_transition(key, transition, resolution),
              )
            }
          }
        }
      }
    GotTransition(key, _to_status, Ok(_)) -> #(
      model,
      effect.batch([fetch_transitions(key), fetch_detail(key)]),
    )
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
    SetLabelDraft(text) -> #(Model(..model, label_draft: text), effect.none())
    AddLabel -> add_label(model)
    RemoveLabel(label) -> remove_label(model, label)
    GotLabels(_, Ok(_)) -> #(model, effect.none())
    GotLabels(key, Error(message)) ->
      case is_selected(model, key) {
        True -> #(
          Model(..model, write_error: Some(message)),
          // The optimistic change is rolled back by the fresh detail; its
          // response also syncs the matching list row.
          fetch_detail(key),
        )
        False -> #(model, effect.none())
      }
  }
}

// ————— views plumbing —————

/// The freshly loaded list selects and loads its first view.
fn view_list_ready(
  model: Model,
  views: List(types.ViewDef),
) -> #(Model, Effect(Msg)) {
  case views {
    [view, ..] ->
      switch_to_view(Model(..model, views: ViewsLoaded(views)), view)
    [] -> #(
      Model(..model, views: ViewsLoaded([]), current_view: None),
      effect.none(),
    )
  }
}

/// Point the whole issue apparatus at a view: rows reset, the JQL buffer
/// takes the view's own query (empty for board views).
fn switch_to_view(model: Model, view: types.ViewDef) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..model,
      current_view: Some(view),
      jql_input: case view.source {
        types.Jql(jql) -> jql
        types.Board(_) -> ""
      },
      state: Loading,
      selected: None,
      cursor: None,
      order_error: None,
      write_error: None,
      summary_edit: None,
      transitions: None,
      assignable: None,
      comment_draft: "",
      pending_comments: [],
      worklog_draft: "",
      pending_worklog: [],
      label_draft: "",
    ),
    fetch_issues_effect(view),
  )
}

fn upsert_view(views: ViewList, view: types.ViewDef) -> ViewList {
  case views {
    ViewsLoaded(existing) ->
      case
        list.any(existing, fn(existing_view) { existing_view.id == view.id })
      {
        True ->
          ViewsLoaded(
            list.map(existing, fn(existing_view) {
              case existing_view.id == view.id {
                True -> view
                False -> existing_view
              }
            }),
          )
        False -> ViewsLoaded(list.append(existing, [view]))
      }
    other -> other
  }
}

fn new_edit_form() -> EditForm {
  EditForm(
    id: None,
    name: "",
    source: types.Jql(default_jql),
    columns: default_columns,
    confirm_delete: False,
  )
}

fn set_column(
  columns: List(String),
  column: String,
  checked: Bool,
) -> List(String) {
  case checked, list.contains(columns, column) {
    True, False -> list.append(columns, [column])
    True, True -> columns
    False, True -> list.filter(columns, fn(existing) { existing != column })
    False, False -> columns
  }
}

fn fetch_views() -> Effect(Msg) {
  fetch.get("/jira/views", fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, views_wrapper_decoder()) {
          Ok(views) -> GotViews(Ok(views))
          Error(error) -> GotViews(Error(string.inspect(error)))
        }
      Error(message) -> GotViews(Error(message))
    }
  })
}

fn views_wrapper_decoder() -> decode.Decoder(List(types.ViewDef)) {
  decode.field("views", decode.list(types.app_view_decoder()), decode.success)
}

fn fetch_resolutions() -> Effect(Msg) {
  fetch.get("/jira/resolutions", fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, types.resolutions_decoder()) {
          Ok(resolutions) -> GotResolutions(Ok(resolutions))
          Error(error) -> GotResolutions(Error(string.inspect(error)))
        }
      Error(message) -> GotResolutions(Error(message))
    }
  })
}

fn fetch_boards() -> Effect(Msg) {
  fetch.get("/jira/boards", fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, boards_wrapper_decoder()) {
          Ok(boards) -> GotBoards(Ok(boards))
          Error(error) -> GotBoards(Error(string.inspect(error)))
        }
      Error(message) -> GotBoards(Error(message))
    }
  })
}

fn boards_wrapper_decoder() -> decode.Decoder(List(types.AgileBoard)) {
  decode.field("boards", decode.list(types.app_board_decoder()), decode.success)
}

fn save_view_effect(form: EditForm) -> Effect(Msg) {
  case form.id {
    Some(id) ->
      fetch.put_json_raw("/jira/views/" <> id, view_body(form), fn(response) {
        case response {
          Ok(body) ->
            case json.parse(body, types.app_view_decoder()) {
              Ok(view) -> GotViewSaved(Ok(view))
              Error(error) -> GotViewSaved(Error(string.inspect(error)))
            }
          Error(message) -> GotViewSaved(Error(message))
        }
      })
    None ->
      fetch.post_json_raw("/jira/views", view_body(form), fn(response) {
        case response {
          Ok(body) ->
            case json.parse(body, types.app_view_decoder()) {
              Ok(view) -> GotViewSaved(Ok(view))
              Error(error) -> GotViewSaved(Error(string.inspect(error)))
            }
          Error(message) -> GotViewSaved(Error(message))
        }
      })
  }
}

fn view_body(form: EditForm) -> String {
  let #(jql, board_id) = case form.source {
    types.Jql(jql) -> #(Some(jql), None)
    types.Board(board_id) -> #(None, Some(board_id))
  }
  json.object(
    list.flatten([
      [#("name", json.string(form.name))],
      case jql {
        Some(jql) -> [#("jql", json.string(jql))]
        None -> []
      },
      case board_id {
        Some(board_id) -> [#("board_id", json.int(board_id))]
        None -> []
      },
      [#("columns", json.array(form.columns, json.string))],
    ]),
  )
  |> json.to_string
}

fn fetch_issues_effect(view: types.ViewDef) -> Effect(Msg) {
  case view.source {
    types.Board(board_id) ->
      fetch.get(
        "/jira/board/"
          <> int.to_string(board_id)
          <> "/issues?"
          <> uri.query_to_string([#("view", view.id)]),
        fn(response) { decode_issues(view.id, response) },
      )
    // JQL views: the SAVED query (switching views resets the box, but
    // loading a view fresh always uses its stored query).
    types.Jql(jql) ->
      fetch.get(search_url(view.id, jql), fn(response) {
        decode_issues(view.id, response)
      })
  }
}

fn search_url(view_id: String, jql: String) -> String {
  "/jira/search?" <> uri.query_to_string([#("jql", jql), #("view", view_id)])
}

fn decode_issues(view_id: String, response: Result(String, String)) -> Msg {
  case response {
    Ok(body) ->
      case json.parse(body, types.issues_response_decoder()) {
        Ok(issues) -> GotIssues(view_id, Ok(issues))
        Error(error) -> GotIssues(view_id, Error(string.inspect(error)))
      }
    Error(message) -> GotIssues(view_id, Error(message))
  }
}

/// Close the detail and put keyboard focus back on the list. The table was
/// unmounted while the detail showed, so drag-and-drop and the tab stop both
/// have to be restored once Lustre renders it again.
fn close_detail(model: Model) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, selected: None, assignable: None, summary_edit: None),
    effect.batch([
      sortable.attach(".jv-tbody", Dropped),
      keyboard.focus_table(),
    ]),
  )
}

fn open_detail(model: Model, key: String) -> #(Model, Effect(Msg)) {
  let resolutions_effect = case model.resolutions {
    Some(Ok(_)) -> effect.none()
    _ -> fetch_resolutions()
  }
  #(
    Model(
      ..model,
      selected: Some(DetailLoading(key)),
      transitions: None,
      assignable: None,
      summary_edit: None,
      write_error: None,
      comment_draft: "",
      pending_comments: [],
      worklog_draft: "",
      pending_worklog: [],
      label_draft: "",
    ),
    effect.batch([
      fetch_detail(key),
      fetch_transitions(key),
      fetch_assignable(key),
      resolutions_effect,
    ]),
  )
}

fn edit_summary(model: Model) -> #(Model, Effect(Msg)) {
  case model.selected {
    Some(DetailLoaded(info)) -> #(
      Model(..model, summary_edit: Some(info.issue.summary), write_error: None),
      keyboard.focus_summary(),
    )
    _ -> #(model, effect.none())
  }
}

fn cancel_summary_edit(model: Model) -> #(Model, Effect(Msg)) {
  #(Model(..model, summary_edit: None, write_error: None), effect.none())
}

fn save_summary(model: Model) -> #(Model, Effect(Msg)) {
  case model.selected, model.summary_edit {
    Some(DetailLoaded(info)), Some(draft) -> {
      let summary = string.trim(draft)
      case summary {
        "" -> #(
          Model(..model, write_error: Some("Summary must not be empty.")),
          effect.none(),
        )
        _ ->
          case summary == info.issue.summary {
            True -> cancel_summary_edit(model)
            False -> {
              let issue = types.Issue(..info.issue, summary: summary)
              let detail = types.IssueDetail(..info, issue: issue)
              #(
                Model(
                  ..model,
                  summary_edit: None,
                  write_error: None,
                  selected: Some(DetailLoaded(detail)),
                  state: sync_ready_row(model.state, issue),
                ),
                put_summary(info.issue.key, summary),
              )
            }
          }
      }
    }
    _, _ -> #(model, effect.none())
  }
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

/// Whether a reply belongs to the issue currently open in the panel.
fn is_selected(model: Model, key: String) -> Bool {
  selected_key(model) == Ok(key)
}

/// Whether a reply belongs to the view currently showing.
fn is_current_view(model: Model, view_id: String) -> Bool {
  case model.current_view {
    Some(view) -> view.id == view_id
    None -> False
  }
}

fn transition_requires_resolution(transition: types.Transition) -> Bool {
  list.any(transition.fields, fn(field) {
    field.required && field.key == "resolution"
  })
}

fn needs_resolution(transitions: List(types.Transition)) -> Bool {
  list.any(transitions, transition_requires_resolution)
}

/// Keep the user's pick if it still exists; otherwise prefer Done, then the
/// first value Jira returned.
fn choose_resolution(
  current: String,
  resolutions: List(types.Resolution),
) -> String {
  let names = list.map(resolutions, fn(resolution) { resolution.name })
  case list.contains(names, current) {
    True -> current
    False ->
      case list.contains(names, "Done") {
        True -> "Done"
        False ->
          case names {
            [first, ..] -> first
            [] -> ""
          }
      }
  }
}

/// j/k: move the cursor, clamped inside the visible rows; starting out
/// opens at the top (j) or bottom (k) when nothing is focused yet.
fn focus(state: State, cursor: Option(Int), down: Bool) -> Option(Int) {
  case state {
    Ready(issues) -> ordering.focus(issues, cursor, down)
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
          let issues = ordering.move_item(issues, index, target)
          #(
            Model(..model, state: Ready(issues), cursor: Some(target)),
            save_order(issues, model.current_view),
          )
        }
        False -> #(model, effect.none())
      }
    }
    _, _ -> #(model, effect.none())
  }
}

fn item_at(issues: List(Issue), index: Int) -> Result(Issue, Nil) {
  case list.drop(issues, index) {
    [issue, ..] -> Ok(issue)
    [] -> Error(Nil)
  }
}

/// Persist the whole visible order (not just the moved pair), so previously
/// unordered ("appended") rows join the ordering the moment they are moved.
fn save_order(issues: List(Issue), view: Option(types.ViewDef)) -> Effect(Msg) {
  case view {
    Some(types.ViewDef(id: view_id, ..)) ->
      fetch.patch_json(
        "/jira/views/" <> view_id <> "/order",
        json.to_string(
          json.object([
            #(
              "keys",
              json.array(list.map(issues, fn(issue) { issue.key }), json.string),
            ),
          ]),
        ),
        fn(result) {
          case result {
            Ok(_) -> OrderSaved(Ok(Nil))
            Error(message) -> OrderSaved(Error(message))
          }
        },
      )
    None -> effect.none()
  }
}

fn fetch_detail(key: String) -> Effect(Msg) {
  fetch.get("/jira/issue/" <> key, fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, types.app_issue_detail_decoder()) {
          Ok(detail) -> GotDetail(key, Ok(detail))
          Error(error) -> GotDetail(key, Error(string.inspect(error)))
        }
      Error(message) -> GotDetail(key, Error(message))
    }
  })
}

fn fetch_transitions(key: String) -> Effect(Msg) {
  fetch.get("/jira/issue/" <> key <> "/transitions", fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, types.jira_transitions_decoder()) {
          Ok(transitions) -> GotTransitions(key, Ok(transitions))
          Error(error) -> GotTransitions(key, Error(string.inspect(error)))
        }
      Error(message) -> GotTransitions(key, Error(message))
    }
  })
}

fn fetch_assignable(key: String) -> Effect(Msg) {
  fetch.get("/jira/issue/" <> key <> "/assignable", fn(response) {
    case response {
      Ok(body) ->
        case json.parse(body, types.users_response_decoder()) {
          Ok(users) -> GotAssignable(key, Ok(users))
          Error(error) -> GotAssignable(key, Error(string.inspect(error)))
        }
      Error(message) -> GotAssignable(key, Error(message))
    }
  })
}

fn put_summary(key: String, summary: String) -> Effect(Msg) {
  fetch.put_json(
    "/jira/issue/" <> key <> "/summary",
    json.object([#("summary", json.string(summary))]) |> json.to_string,
    fn(result) { GotSummarySaved(key, result) },
  )
}

fn put_assignee(key: String, assignee: Option(types.User)) -> Effect(Msg) {
  let account_id = case assignee {
    Some(user) -> Some(user.account_id)
    None -> None
  }
  fetch.put_json(
    "/jira/issue/" <> key <> "/assignee",
    json.object([#("account_id", json.nullable(account_id, json.string))])
      |> json.to_string,
    fn(result) {
      case result {
        Ok(_) -> GotAssignee(key, Ok(Nil))
        Error(message) -> GotAssignee(key, Error(message))
      }
    },
  )
}

fn put_flagged(key: String, flagged: Bool) -> Effect(Msg) {
  fetch.put_json(
    "/jira/issue/" <> key <> "/flagged",
    json.object([#("flagged", json.bool(flagged))]) |> json.to_string,
    fn(result) {
      case result {
        Ok(_) -> GotFlagged(key, Ok(Nil))
        Error(message) -> GotFlagged(key, Error(message))
      }
    },
  )
}

fn post_transition(
  key: String,
  transition: types.Transition,
  resolution: Option(String),
) -> Effect(Msg) {
  let body =
    list.flatten([
      [#("id", json.string(transition.id))],
      case resolution {
        Some(name) -> [#("resolution", json.string(name))]
        None -> []
      },
    ])
  fetch.post_json(
    "/jira/issue/" <> key <> "/transition",
    json.to_string(json.object(body)),
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

/// Replace the issue's labels with the full list (Jira's edit-issue shape).
fn save_labels(key: String, labels: List(String)) -> Effect(Msg) {
  fetch.put_json(
    "/jira/issue/" <> key <> "/labels",
    json.object([#("labels", json.array(labels, json.string))])
      |> json.to_string,
    fn(result) { GotLabels(key, result) },
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

// view state helpers —————————————————————————————————————————

/// Optimistic status flip over the ready list; a transition does not reveal
/// the target status category, so the row keeps the old one until refetch.
fn flip_row_status(state: State, key: String, to_status: String) -> State {
  case state {
    Ready(issues) ->
      Ready(
        map_issue(issues, key, fn(issue) {
          types.Issue(
            ..issue,
            status: types.Status(to_status, issue.status.category),
          )
        }),
      )
    state -> state
  }
}

fn flip_detail_status(
  selected: Option(Detail),
  to_status: String,
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(
        types.IssueDetail(
          ..info,
          issue: types.Issue(
            ..info.issue,
            status: types.Status(to_status, info.issue.status.category),
          ),
        ),
      ))
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

fn sync_issue(
  issues: List(types.Issue),
  fresh: types.Issue,
) -> List(types.Issue) {
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

// ————— label editing —————

/// Add the trimmed draft to the open issue's labels (no duplicates) and
/// persist the whole new list. Labels are single tokens; Jira rejects spaces.
fn add_label(model: Model) -> #(Model, Effect(Msg)) {
  case model.selected {
    Some(DetailLoaded(info)) -> {
      let label = string.trim(model.label_draft)
      case label {
        "" -> #(model, effect.none())
        _ ->
          case label_has_whitespace(label) {
            True -> #(
              Model(..model, write_error: Some("Labels can't contain spaces.")),
              effect.none(),
            )
            False ->
              case list.contains(info.issue.labels, label) {
                True -> #(Model(..model, label_draft: ""), effect.none())
                False -> {
                  let labels = list.append(info.issue.labels, [label])
                  let model = with_labels(model, info.issue.key, labels)
                  #(
                    Model(..model, label_draft: "", write_error: None),
                    save_labels(info.issue.key, labels),
                  )
                }
              }
          }
      }
    }
    _ -> #(model, effect.none())
  }
}

fn remove_label(model: Model, label: String) -> #(Model, Effect(Msg)) {
  case model.selected {
    Some(DetailLoaded(info)) ->
      case list.contains(info.issue.labels, label) {
        False -> #(model, effect.none())
        True -> {
          let labels =
            list.filter(info.issue.labels, fn(existing) { existing != label })
          let model =
            Model(
              ..with_labels(model, info.issue.key, labels),
              write_error: None,
            )
          #(model, save_labels(info.issue.key, labels))
        }
      }
    _ -> #(model, effect.none())
  }
}

/// Apply a label change to both the open detail and its list row.
fn with_labels(model: Model, key: String, labels: List(String)) -> Model {
  Model(
    ..model,
    state: set_issue_labels(model.state, key, labels),
    selected: set_detail_labels(model.selected, labels),
  )
}

fn set_detail_labels(
  selected: Option(Detail),
  labels: List(String),
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(
        types.IssueDetail(
          ..info,
          issue: types.Issue(..info.issue, labels: labels),
        ),
      ))
    selected -> selected
  }
}

fn set_issue_labels(state: State, key: String, labels: List(String)) -> State {
  case state {
    Ready(issues) ->
      Ready(
        map_issue(issues, key, fn(issue) {
          types.Issue(..issue, labels: labels)
        }),
      )
    state -> state
  }
}

fn label_has_whitespace(label: String) -> Bool {
  label
  |> string.to_graphemes
  |> list.any(fn(grapheme) { list.contains([" ", "\t", "\n", "\r"], grapheme) })
}

// ————— assignee editing —————

fn current_assignee(model: Model) -> Option(types.User) {
  case model.selected {
    Some(DetailLoaded(info)) -> info.issue.assignee
    _ -> None
  }
}

fn same_assignee(a: Option(types.User), b: Option(types.User)) -> Bool {
  case a, b {
    Some(a), Some(b) -> a.account_id == b.account_id
    None, None -> True
    _, _ -> False
  }
}

/// Apply an assignee change to both the open detail and its list row.
fn with_assignee(
  model: Model,
  key: String,
  assignee: Option(types.User),
) -> Model {
  Model(
    ..model,
    state: set_issue_assignee(model.state, key, assignee),
    selected: set_detail_assignee(model.selected, assignee),
  )
}

fn set_detail_assignee(
  selected: Option(Detail),
  assignee: Option(types.User),
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(
        types.IssueDetail(
          ..info,
          issue: types.Issue(..info.issue, assignee: assignee),
        ),
      ))
    selected -> selected
  }
}

fn set_issue_assignee(
  state: State,
  key: String,
  assignee: Option(types.User),
) -> State {
  case state {
    Ready(issues) ->
      Ready(
        map_issue(issues, key, fn(issue) {
          types.Issue(..issue, assignee: assignee)
        }),
      )
    state -> state
  }
}

// ————— flag editing —————

fn current_flagged(model: Model) -> Bool {
  case model.selected {
    Some(DetailLoaded(info)) -> info.issue.flagged
    _ -> False
  }
}

/// Apply a flag change to both the open detail and its list row.
fn with_flagged(model: Model, key: String, flagged: Bool) -> Model {
  Model(
    ..model,
    state: set_issue_flagged(model.state, key, flagged),
    selected: set_detail_flagged(model.selected, flagged),
  )
}

fn set_detail_flagged(
  selected: Option(Detail),
  flagged: Bool,
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(
        types.IssueDetail(
          ..info,
          issue: types.Issue(..info.issue, flagged: flagged),
        ),
      ))
    selected -> selected
  }
}

fn set_issue_flagged(state: State, key: String, flagged: Bool) -> State {
  case state {
    Ready(issues) ->
      Ready(
        map_issue(issues, key, fn(issue) {
          types.Issue(..issue, flagged: flagged)
        }),
      )
    state -> state
  }
}

fn append_comment(
  selected: Option(Detail),
  comment: types.Comment,
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(
        types.IssueDetail(
          ..info,
          comments: list.append(info.comments, [comment]),
        ),
      ))
    selected -> selected
  }
}

fn append_worklog(
  selected: Option(Detail),
  entry: types.WorklogEntry,
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(
        types.IssueDetail(..info, worklog: list.append(info.worklog, [entry])),
      ))
    selected -> selected
  }
}

// ————— view —————

pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [attribute.class("jv")],
    list.flatten([
      [html.div([attribute.class("jv-toolbar")], toolbar(model))],
      case model.selected {
        Some(detail) -> [detail_panel(model, detail)]
        None -> list_view(model)
      },
      [theme_trigger(model), theme_dialog(model)],
    ]),
  )
}

/// The list area — order/edit/loading/error/table. It is replaced wholesale by
/// the detail panel while an issue is open.
fn list_view(model: Model) -> List(Element(Msg)) {
  [
    case model.order_error {
      Some(message) ->
        html.p([attribute.class("jv-order-error")], [
          text("Private order not saved: " <> message),
        ])
      None -> element.none()
    },
    case model.edit {
      Some(form) -> edit_panel(model, form)
      None -> element.none()
    },
    case model.state {
      Loading if model.current_view == None ->
        html.p([attribute.class("jv-note")], [
          text("Create a view to get started."),
        ])
      Loading -> html.p([attribute.class("jv-note")], [text("Loading…")])
      Failed(message) ->
        html.p([attribute.class("jv-error")], [text("Error: " <> message)])
      Ready(issues) ->
        case issues {
          [] -> html.p([attribute.class("jv-note")], [text("No issues.")])
          _ -> table(issues, columns_of(model), model.cursor)
        }
    },
  ]
}

fn columns_of(model: Model) -> List(String) {
  case model.current_view {
    Some(view) -> view.columns
    None -> default_columns
  }
}

fn palette_effect(open: Bool) -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    case open {
      True -> palette.open_dialog()
      False -> palette.close_dialog()
    }
  })
}

fn theme_trigger(model: Model) -> Element(Msg) {
  html.button(
    [
      attribute.class("jv-theme-trigger"),
      attribute.type_("button"),
      attribute.title("Appearance: " <> theme.label(model.theme)),
      attribute.aria_label("Appearance: " <> theme.label(model.theme)),
      attribute.aria_haspopup("dialog"),
      attribute.aria_expanded(model.theme_palette_open),
      event.on_click(ToggleThemePalette),
    ],
    [
      theme_icon(model.theme),
      html.span([attribute.class("jv-theme-trigger-label")], [
        text(theme.label(model.theme)),
      ]),
    ],
  )
}

fn theme_dialog(model: Model) -> Element(Msg) {
  html.dialog(
    [
      attribute.class("jv-theme-dialog"),
      attribute.aria_labelledby("jv-theme-title"),
      attribute.aria_modal(True),
      event.on("close", decode.success(ThemePaletteClosed)),
      event.on_keydown(fn(key) {
        case key {
          "t" | "T" -> CycleTheme
          _ -> NoOp
        }
      }),
    ],
    [
      html.div(
        [
          attribute.class("jv-theme-backdrop"),
          event.on_click(CloseThemePalette),
        ],
        [],
      ),
      html.div([attribute.class("jv-theme-panel")], [
        theme_palette_head(),
        html.div(
          [
            attribute.class("jv-theme-options"),
            attribute.role("group"),
            attribute.aria_label("Color scheme"),
          ],
          list.map([theme.Auto, theme.Light, theme.Dark], fn(option) {
            theme_option(model.theme, option)
          }),
        ),
        theme_palette_footer(),
      ]),
    ],
  )
}

fn theme_palette_head() -> Element(Msg) {
  html.div([attribute.class("jv-theme-head")], [
    html.div([], [
      html.h2(
        [attribute.id("jv-theme-title"), attribute.class("jv-theme-title")],
        [text("Appearance")],
      ),
      html.p([attribute.class("jv-theme-subtitle")], [
        text("Choose how jira-view looks."),
      ]),
    ]),
    html.div([attribute.class("jv-theme-head-actions")], [
      html.button(
        [
          attribute.class("jv-theme-cycle"),
          attribute.type_("button"),
          attribute.title("Cycle theme (T)"),
          attribute.aria_label("Cycle theme"),
          event.on_click(CycleTheme),
        ],
        [text("↻")],
      ),
      html.button(
        [
          attribute.class("jv-theme-close"),
          attribute.type_("button"),
          attribute.title("Close"),
          attribute.aria_label("Close appearance"),
          event.on_click(CloseThemePalette),
        ],
        [text("×")],
      ),
    ]),
  ])
}

fn theme_option(current: theme.Theme, option: theme.Theme) -> Element(Msg) {
  let selected = current == option
  html.button(
    [
      attribute.class("jv-theme-option"),
      attribute.type_("button"),
      attribute.aria_pressed(case selected {
        True -> "true"
        False -> "false"
      }),
      attribute.autofocus(selected),
      event.on_click(SetTheme(option)),
    ],
    [
      theme_swatch(option),
      html.span([attribute.class("jv-theme-option-copy")], [
        html.span([attribute.class("jv-theme-option-label")], [
          text(theme.label(option)),
        ]),
        html.span([attribute.class("jv-theme-option-desc")], [
          text(theme.description(option)),
        ]),
      ]),
      html.span(
        [attribute.class("jv-theme-check"), attribute.aria_hidden(True)],
        [
          text(case selected {
            True -> "✓"
            False -> ""
          }),
        ],
      ),
    ],
  )
}

fn theme_swatch(option: theme.Theme) -> Element(Msg) {
  let variant = case option {
    theme.Auto -> "jv-theme-swatch-auto"
    theme.Light -> "jv-theme-swatch-light"
    theme.Dark -> "jv-theme-swatch-dark"
  }
  html.span(
    [
      attribute.class("jv-theme-swatch " <> variant),
      attribute.aria_hidden(True),
    ],
    [theme_icon(option)],
  )
}

fn theme_icon(option: theme.Theme) -> Element(Msg) {
  let paths = case option {
    theme.Auto -> [
      svg.path([attribute.attribute("d", "M3 5h18v11H3z")]),
      svg.path([attribute.attribute("d", "M8 20h8M12 16v4")]),
    ]
    theme.Light -> [
      svg.circle([
        attribute.attribute("cx", "12"),
        attribute.attribute("cy", "12"),
        attribute.attribute("r", "4"),
      ]),
      svg.path([
        attribute.attribute(
          "d",
          "M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4",
        ),
      ]),
    ]
    theme.Dark -> [
      svg.path([
        attribute.attribute(
          "d",
          "M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5 8.5 8.5 0 1 0 20.5 14.5Z",
        ),
      ]),
    ]
  }
  html.svg(
    [
      attribute.class("jv-theme-icon"),
      attribute.attribute("viewBox", "0 0 24 24"),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "1.7"),
      attribute.attribute("stroke-linecap", "round"),
      attribute.attribute("stroke-linejoin", "round"),
      attribute.aria_hidden(True),
    ],
    paths,
  )
}

fn theme_palette_footer() -> Element(Msg) {
  html.div([attribute.class("jv-theme-foot")], [
    html.span([attribute.class("jv-theme-hint")], [
      html.kbd([attribute.class("jv-theme-kbd")], [text("T")]),
      text(" cycle"),
    ]),
    html.span([attribute.class("jv-theme-hint")], [
      html.kbd([attribute.class("jv-theme-kbd")], [text("Esc")]),
      text(" close"),
    ]),
    html.span([attribute.class("jv-theme-hint")], [
      html.kbd([attribute.class("jv-theme-kbd")], [
        text(palette.shortcut_label()),
      ]),
      text(" toggle"),
    ]),
  ])
}

fn toolbar(model: Model) -> List(Element(Msg)) {
  case model.views {
    ViewsLoading -> [
      html.p([attribute.class("jv-note")], [text("Loading views…")]),
    ]
    ViewsFailed(message) -> [
      html.p([attribute.class("jv-error")], [text("Error: " <> message)]),
      html.button([attribute.class("jv-new-view"), event.on_click(NewView)], [
        text("+ New view"),
      ]),
    ]
    ViewsLoaded(views) ->
      list.flatten([
        [
          html.div(
            [attribute.class("jv-jql")],
            list.flatten([
              case views {
                [] -> [
                  html.span([attribute.class("jv-note")], [
                    text("No views. Create one:"),
                  ]),
                ]
                _ -> [
                  html.select(
                    [
                      attribute.class("jv-view-select"),
                      attribute.value(case model.current_view {
                        Some(current) -> current.id
                        None -> ""
                      }),
                      event.on_change(SelectView),
                    ],
                    list.map(views, fn(view) {
                      html.option(
                        [
                          attribute.value(view.id),
                          attribute.selected(case model.current_view {
                            Some(current) -> current.id == view.id
                            None -> False
                          }),
                        ],
                        view.name,
                      )
                    }),
                  ),
                ]
              },
              case model.current_view {
                Some(view) -> [query_slot(model, view)]
                None -> []
              },
              [
                html.button(
                  [attribute.class("jv-refresh"), event.on_click(Refresh)],
                  [
                    text("Refresh"),
                  ],
                ),
              ],
              case model.current_view, model.edit {
                Some(_), None -> [
                  html.button(
                    [
                      attribute.class("jv-edit-view"),
                      event.on_click(EditExisting),
                    ],
                    [text("Edit")],
                  ),
                ]
                _, _ -> []
              },
              [
                html.button(
                  [attribute.class("jv-new-view"), event.on_click(NewView)],
                  [
                    text("+ New view"),
                  ],
                ),
              ],
            ]),
          ),
        ],
      ])
  }
}

/// Between the view select and Refresh: the editable JQL (a JQL view's
/// query console; hidden while the edit form is open — the form has its
/// own field), or the board note.
fn query_slot(model: Model, view: types.ViewDef) -> Element(Msg) {
  case view.source {
    types.Jql(_) ->
      case model.edit {
        Some(_) -> element.none()
        None ->
          html.input([
            attribute.type_("text"),
            attribute.class("jv-jql-input"),
            attribute.value(model.jql_input),
            event.on_input(SetJql),
            // Enter in the query console refreshes, like the button.
            event.on_keydown(fn(key) {
              case key {
                "Enter" -> Refresh
                _ -> NoOp
              }
            }),
          ])
      }
    types.Board(_) ->
      html.span([attribute.class("jv-board-note")], [
        text("board · all issues"),
      ])
  }
}

/// The view editor's DOM is a STATIC structure: no internal case branches,
/// because Lustre resolves event handlers by stable node paths and branches
/// that appear/disappear desync them (the Board toggle button was observed
/// silently dropping its clicks). Everything is always rendered and merely
/// disabled/emptied per state.
fn edit_panel(model: Model, form: EditForm) -> Element(Msg) {
  html.div([attribute.class("jv-edit")], [
    html.p([attribute.class("jv-write-error")], [
      text(case model.view_error {
        Some(message) -> message
        None -> ""
      }),
    ]),
    html.div([attribute.class("jv-edit-row")], [
      html.input([
        attribute.class("jv-edit-name"),
        attribute.value(form.name),
        attribute.placeholder("View name"),
        event.on_input(SetEditName),
      ]),
    ]),
    html.div([attribute.class("jv-edit-row")], [
      html.span([attribute.class("jv-note")], [text("Source:")]),
      source_select(model.boards, form.source),
    ]),
    html.div([attribute.class("jv-edit-row")], [
      html.input([
        attribute.class("jv-edit-jql"),
        attribute.value(case form.source {
          types.Jql(jql) -> jql
          types.Board(_) -> ""
        }),
        attribute.disabled(case form.source {
          types.Jql(_) -> False
          types.Board(_) -> True
        }),
        attribute.placeholder("JQL (must be bounded)"),
        event.on_input(fn(jql) { SetEditJql(jql) }),
      ]),
    ]),
    html.div(
      [attribute.class("jv-edit-columns")],
      list.flatten([
        [html.span([attribute.class("jv-note")], [text("Columns:")])],
        list.map(default_columns, fn(column) {
          html.label([], [
            html.input([
              attribute.type_("checkbox"),
              attribute.checked(list.contains(form.columns, column)),
              event.on_check(fn(checked) { ToggleColumn(column, checked) }),
            ]),
            text(column),
          ])
        }),
      ]),
    ),
    html.div([attribute.class("jv-edit-actions")], [
      html.button(
        [
          attribute.class("jv-save-view"),
          attribute.disabled(case form.source {
            types.Board(0) -> True
            _ -> False
          }),
          event.on_click(SaveView),
        ],
        [text("Save view")],
      ),
      html.button(
        [attribute.class("jv-cancel-edit"), event.on_click(CancelEdit)],
        [
          text("Cancel"),
        ],
      ),
      html.button(
        [
          attribute.class("jv-delete"),
          attribute.disabled(form.id == None),
          event.on_click(DeleteView),
        ],
        [
          text(case form.confirm_delete {
            True -> "Confirm delete"
            False -> "Delete"
          }),
        ],
      ),
    ]),
  ])
}

/// The one source field: "jql" or a board id. A placeholder option exists
/// while the board list isn't loaded (option nodes are the select's
/// children — they may come and go; the event listener sits on the stable
/// select node itself).
fn source_select(
  boards: Option(Result(List(types.AgileBoard), String)),
  source: types.ViewSource,
) -> Element(Msg) {
  let option_elements = case boards {
    Some(Ok(boards)) ->
      list.map(boards, fn(board) {
        html.option(
          [
            attribute.value(int.to_string(board.id)),
            attribute.selected(source == types.Board(board.id)),
          ],
          board.name <> " · " <> board.kind,
        )
      })
    _ -> []
  }
  html.select(
    [
      attribute.class("jv-edit-board"),
      event.on_change(fn(value) {
        case value {
          "jql" -> PickJqlSource
          _ ->
            case int.parse(value) {
              Ok(board_id) -> SetEditBoard(board_id)
              Error(_) -> SetEditBoard(0)
            }
        }
      }),
    ],
    list.flatten([
      [
        html.option(
          [
            attribute.value("jql"),
            attribute.selected(case source {
              types.Jql(_) -> True
              types.Board(_) -> False
            }),
          ],
          "JQL query…",
        ),
      ],
      case boards {
        None -> [
          html.option(
            [
              attribute.value("loading"),
              attribute.selected(False),
              attribute.disabled(True),
            ],
            "loading boards…",
          ),
        ]
        Some(Error(_)) -> [
          html.option(
            [
              attribute.value("loaderr"),
              attribute.selected(False),
              attribute.disabled(True),
            ],
            "boards unavailable",
          ),
        ]
        _ -> []
      },
      option_elements,
    ]),
  )
}

/// The table body's <tr>s are KEYED by issue key: load-bearing for
/// drag-and-drop — SortableJS moves physical nodes behind Lustre's back,
/// and unkeyed positional patching would visually scramble the order.
/// Cells are keyed by column name, so column changes reuse nodes too.
fn table(
  issues: List(Issue),
  columns: List(String),
  cursor: Option(Int),
) -> Element(Msg) {
  html.table(
    [
      attribute.class("jv-table"),
      // One tab stop for the whole list; j/k drive the cursor inside it.
      attribute.tabindex(0),
      attribute.aria_label("Issues"),
      event.on_focus(TableFocused),
    ],
    [
      html.thead([], [
        html.tr([], [
          html.th([attribute.class("jv-col-grab")], [text("")]),
          ..list.map(columns, head)
        ]),
      ]),
      keyed.element(
        "tbody",
        [attribute.class("jv-tbody")],
        list.index_map(issues, fn(issue, index) {
          #(issue.key, row(issue, index, cursor, columns))
        }),
      ),
    ],
  )
}

fn head(column: String) -> Element(Msg) {
  html.th([attribute.class("jv-col-" <> column)], [text(column)])
}

fn cell(content: String) -> Element(Msg) {
  html.td([], [text(content)])
}

fn row(
  issue: Issue,
  index: Int,
  cursor: Option(Int),
  columns: List(String),
) -> Element(Msg) {
  let attributes = [
    attribute.class(row_class(issue, index, cursor)),
    event.on_click(Select(issue.key)),
  ]
  let attributes = case issue.flagged {
    True -> list.append(attributes, [attribute.title("Flagged")])
    False -> attributes
  }
  keyed.element(
    "tr",
    attributes,
    list.flatten([
      [#("grab", grab_cell())],
      list.map(columns, fn(column) { #(column, view_cell(issue, column)) }),
    ]),
  )
}

fn row_class(issue: Issue, index: Int, cursor: Option(Int)) -> String {
  "jv-row"
  <> case issue.flagged {
    True -> " jv-row-flagged"
    False -> ""
  }
  <> case cursor {
    Some(focused) if focused == index -> " jv-row-focused"
    _ -> ""
  }
}

fn grab_cell() -> Element(Msg) {
  html.td([attribute.class("jv-grab"), attribute.title("Drag to reorder")], [
    text("⋮⋮"),
  ])
}

fn view_cell(issue: Issue, column: String) -> Element(Msg) {
  case column {
    "key" -> cell(issue.key)
    "summary" -> summary_cell(issue)
    "status" -> cell(issue.status.name)
    "assignee" -> assignee_cell(issue)
    "updated" -> cell(issue.updated)
    _ -> cell("")
  }
}

/// The summary cell also carries the issue's labels, so existing saved views
/// show them without a column-config change.
fn summary_cell(issue: Issue) -> Element(Msg) {
  html.td([], [
    text(issue.summary),
    keyed.element(
      "div",
      [attribute.class("jv-labels")],
      list.map(issue.labels, fn(label) {
        #(label, html.span([attribute.class("jv-label")], [text(label)]))
      }),
    ),
  ])
}

fn assignee_cell(issue: Issue) -> Element(Msg) {
  html.td([attribute.class("jv-col-assignee")], [
    assignee_avatar(issue.assignee),
    text(assignee_name(issue.assignee)),
  ])
}

fn assignee_avatar(assignee: Option(types.User)) -> Element(Msg) {
  case assignee {
    Some(user) if user.account_id != "" && user.avatar_url != "" ->
      html.img([
        attribute.class("jv-avatar"),
        attribute.src("/jira/avatar/" <> user.account_id),
        attribute.alt(""),
      ])
    _ -> element.none()
  }
}

fn assignee_name(assignee: option.Option(types.User)) -> String {
  case assignee {
    Some(user) -> user.display_name
    None -> "—"
  }
}

/// The open issue's assignee, always visible, plus the picker that changes it.
/// The candidate list is fetched when the panel opens; an unavailable list
/// leaves the current assignee readable instead of hiding it.
fn assignee_section(model: Model, issue: Issue) -> Element(Msg) {
  html.div([attribute.class("jv-detail-assignee")], [
    html.span([attribute.class("jv-note")], [text("Assignee:")]),
    html.span([attribute.class("jv-assignee-current")], [
      assignee_avatar(issue.assignee),
      text(assignee_name(issue.assignee)),
    ]),
    case model.assignable {
      Some(Ok(users)) -> assignee_select(issue.assignee, users)
      Some(Error(message)) ->
        html.span([attribute.class("jv-write-error")], [
          text("Assignees unavailable: " <> message),
        ])
      None -> element.none()
    },
  ])
}

fn assignee_select(
  current: Option(types.User),
  users: List(types.User),
) -> Element(Msg) {
  let current_id = case current {
    Some(user) -> user.account_id
    None -> ""
  }
  let users = assignee_choices(users, current)
  html.select(
    [
      attribute.class("jv-assignee-select"),
      attribute.title("Change assignee"),
      attribute.value(current_id),
      event.on_change(fn(account_id) {
        SetAssignee(find_assignee(users, account_id))
      }),
    ],
    list.flatten([
      [
        html.option(
          [attribute.value(""), attribute.selected(current_id == "")],
          "Unassigned",
        ),
      ],
      list.map(users, fn(user) {
        html.option(
          [
            attribute.value(user.account_id),
            attribute.selected(user.account_id == current_id),
          ],
          user.display_name,
        )
      }),
    ]),
  )
}

/// The candidates Jira returned, with the current assignee kept selectable
/// even when it is no longer in the assignable search.
fn assignee_choices(
  users: List(types.User),
  current: Option(types.User),
) -> List(types.User) {
  let users = list.filter(users, fn(user) { user.account_id != "" })
  case current {
    Some(user) ->
      case
        list.any(users, fn(existing) { existing.account_id == user.account_id })
      {
        True -> users
        False -> [user, ..users]
      }
    None -> users
  }
}

fn find_assignee(
  users: List(types.User),
  account_id: String,
) -> Option(types.User) {
  case account_id {
    "" -> None
    _ ->
      case list.find(users, fn(user) { user.account_id == account_id }) {
        Ok(user) -> Some(user)
        Error(_) -> None
      }
  }
}

fn detail_panel(model: Model, detail: Detail) -> Element(Msg) {
  let editing_summary = model.summary_edit != None
  html.aside([attribute.class("jv-detail")], [
    html.div(
      [attribute.class(detail_top_class(detail))],
      list.flatten([
        [
          html.div([attribute.class("jv-detail-head")], [
            html.div([attribute.class("jv-detail-head-text")], [
              html.h2([attribute.hidden(editing_summary)], [
                text(detail_title(detail)),
              ]),
              html.input([
                attribute.type_("text"),
                attribute.class("jv-summary-input"),
                attribute.autocomplete("off"),
                attribute.value(option.unwrap(model.summary_edit, "")),
                attribute.hidden(!editing_summary),
                event.on_input(SetSummaryDraft),
                event.on_keydown(fn(key) {
                  case key {
                    "Enter" -> SaveSummary
                    _ -> NoOp
                  }
                }),
              ]),
              html.p([attribute.class("jv-detail-meta")], [
                text(detail_meta(detail)),
              ]),
            ]),
            detail_head_actions(model, detail),
          ]),
        ],
        case detail {
          DetailLoading(key) -> [html.p([], [text("Loading " <> key <> "…")])]
          DetailFailed(message) -> [
            html.p([attribute.class("jv-error")], [text("Error: " <> message)]),
          ]
          DetailLoaded(info) -> [
            flag_section(info.issue),
            assignee_section(model, info.issue),
            case model.write_error {
              Some(message) ->
                html.p([attribute.class("jv-write-error")], [text(message)])
              None -> element.none()
            },
            labels_section(model, info.issue.labels),
            transitions_row(model),
          ]
        },
      ]),
    ),
    case detail {
      DetailLoaded(info) ->
        html.div([attribute.class("jv-detail-body")], [
          adf_view.render(info.description),
          attachments_section(info.attachments),
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
      _ -> element.none()
    },
  ])
}

/// Header controls stay mounted and toggle through `hidden`, so Lustre's
/// event handlers keep stable node paths while the summary is being edited.
fn detail_head_actions(model: Model, detail: Detail) -> Element(Msg) {
  let editing = model.summary_edit != None
  let key = detail_key(detail)
  let href = case key {
    Some(key) -> "/jira/issue/" <> key <> "/open"
    None -> "#"
  }
  html.div([attribute.class("jv-detail-head-actions")], [
    html.button(
      [
        attribute.class("jv-summary-edit"),
        attribute.title("Edit summary"),
        attribute.hidden(!can_edit_summary(detail) || editing),
        event.on_click(EditSummary),
      ],
      [text("Edit")],
    ),
    html.button(
      [
        attribute.class("jv-summary-save"),
        attribute.hidden(!editing),
        event.on_click(SaveSummary),
      ],
      [text("Save")],
    ),
    html.button(
      [
        attribute.class("jv-summary-cancel"),
        attribute.hidden(!editing),
        event.on_click(CancelSummaryEdit),
      ],
      [text("Cancel")],
    ),
    html.a(
      [
        attribute.class("jv-open-jira"),
        attribute.href(href),
        attribute.target("_blank"),
        attribute.rel("noopener noreferrer"),
        attribute.title("Open this issue in Jira"),
        attribute.hidden(key == None),
      ],
      [text("Open in Jira")],
    ),
    html.button([attribute.class("jv-close"), event.on_click(CloseDetail)], [
      text("✕"),
    ]),
  ])
}

fn detail_key(detail: Detail) -> Option(String) {
  case detail {
    DetailLoading(key) -> Some(key)
    DetailLoaded(info) -> Some(info.issue.key)
    DetailFailed(_) -> None
  }
}

fn can_edit_summary(detail: Detail) -> Bool {
  case detail {
    DetailLoaded(_) -> True
    _ -> False
  }
}

fn detail_top_class(detail: Detail) -> String {
  case detail {
    DetailLoaded(info) if info.issue.flagged ->
      "jv-detail-top jv-detail-top-flagged"
    _ -> "jv-detail-top"
  }
}

fn detail_meta(detail: Detail) -> String {
  case detail {
    DetailLoaded(info) -> info.issue.key <> " · " <> info.issue.status.name
    DetailLoading(_) -> ""
    DetailFailed(_) -> ""
  }
}

/// The open issue's flag state, with the control that toggles it.
fn flag_section(issue: Issue) -> Element(Msg) {
  html.label([attribute.class("jv-detail-flag")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.class("jv-flag-toggle"),
      attribute.title("Flag or unflag this issue"),
      attribute.checked(issue.flagged),
      event.on_check(SetFlagged),
    ]),
    text("Flagged"),
  ])
}

/// The open issue's labels with per-chip remove buttons and an add form. The
/// chip container and form keep stable DOM paths (only the keyed chips
/// change), so Lustre's event handlers stay attached.
fn labels_section(model: Model, labels: List(String)) -> Element(Msg) {
  html.div([attribute.class("jv-labels-section")], [
    html.div([attribute.class("jv-labels-row")], [
      html.span([attribute.class("jv-note")], [text("Labels:")]),
      keyed.element(
        "div",
        [attribute.class("jv-labels")],
        list.map(labels, fn(label) {
          #(
            label,
            html.span([attribute.class("jv-label")], [
              text(label),
              html.button(
                [
                  attribute.class("jv-label-remove"),
                  attribute.title("Remove " <> label),
                  event.on_click(RemoveLabel(label)),
                ],
                [text("×")],
              ),
            ]),
          )
        }),
      ),
    ]),
    html.div([attribute.class("jv-label-form")], [
      html.input([
        attribute.type_("text"),
        attribute.class("jv-label-input"),
        attribute.placeholder("Add label…"),
        attribute.value(model.label_draft),
        event.on_input(SetLabelDraft),
        event.on_keydown(fn(key) {
          case key {
            "Enter" -> AddLabel
            _ -> NoOp
          }
        }),
      ]),
      html.button([attribute.class("jv-label-add"), event.on_click(AddLabel)], [
        text("Add"),
      ]),
    ]),
  ])
}

/// One button per available transition of the open issue. The POST applies
/// optimistically in `update`; an invalid move is Jira's to reject. If any
/// transition needs a resolution, a picker is shown above the buttons.
fn transitions_row(model: Model) -> Element(Msg) {
  html.div([attribute.class("jv-transitions")], case model.transitions {
    Some(Ok(transitions)) ->
      list.flatten([
        case needs_resolution(transitions) {
          True -> [resolution_select(model)]
          False -> []
        },
        list.map(transitions, fn(transition) {
          html.button(
            [
              attribute.class("jv-transition"),
              event.on_click(TransitionClicked(transition)),
            ],
            [text(transition.name)],
          )
        }),
      ])
    Some(Error(message)) -> [
      html.span([attribute.class("jv-note")], [text("Transitions: " <> message)]),
    ]
    None -> [html.span([attribute.class("jv-note")], [text("Transitions…")])]
  })
}

fn resolution_select(model: Model) -> Element(Msg) {
  html.label([attribute.class("jv-resolution")], [
    html.span([attribute.class("jv-note")], [text("Resolution:")]),
    case model.resolutions {
      Some(Ok(resolutions)) ->
        html.select(
          [
            attribute.class("jv-resolution-select"),
            attribute.value(model.resolution_draft),
            event.on_change(SetResolution),
          ],
          list.map(resolutions, fn(resolution) {
            html.option(
              [
                attribute.value(resolution.name),
                attribute.selected(resolution.name == model.resolution_draft),
              ],
              resolution.name,
            )
          }),
        )
      Some(Error(message)) ->
        html.span([attribute.class("jv-write-error")], [
          text("Resolutions unavailable: " <> message),
        ])
      None -> html.span([attribute.class("jv-note")], [text("loading…")])
    },
  ])
}

/// Attachments render inline (images through the /jira/attachment proxy)
/// or as same-origin download links.
fn attachments_section(attachments: List(types.Attachment)) -> Element(Msg) {
  html.div(
    [attribute.class("jv-section")],
    list.flatten([
      [html.h3([attribute.class("jv-section-title")], [text("Attachments")])],
      case attachments {
        [] -> [html.p([attribute.class("jv-note")], [text("None.")])]
        _ ->
          list.map(attachments, fn(attachment) {
            html.div([attribute.class("jv-attachment")], [
              case string.starts_with(attachment.mime_type, "image/") {
                True ->
                  html.img([
                    attribute.class("jv-attachment-image"),
                    attribute.src("/jira/attachment/" <> attachment.id),
                    attribute.alt(attachment.filename),
                  ])
                False ->
                  html.a(
                    [
                      attribute.href("/jira/attachment/" <> attachment.id),
                      attribute.attribute("download", attachment.filename),
                    ],
                    [text(attachment.filename)],
                  )
              },
              text(" "),
              html.span([attribute.class("jv-comment-meta")], [
                text(
                  attachment.filename
                  <> " · "
                  <> int.to_string(attachment.size / 1024)
                  <> " kb",
                ),
              ]),
            ])
          })
      },
    ]),
  )
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
          adf_view.render(adf.basic_document(pending_text).content),
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
        html.textarea(
          [
            attribute.class("jv-comment-input"),
            attribute.placeholder("Add a comment…"),
            event.on_input(SetCommentDraft),
          ],
          draft,
        ),
        html.p([attribute.class("jv-comment-hint jv-note")], [
          text(
            "Basic formatting: blank lines = paragraphs, "
            <> "\"- \" = bullets, \"1. \" = numbers, \"# \" = headings.",
          ),
        ]),
        html.div([attribute.class("jv-actions")], [
          html.button(
            [attribute.class("jv-comment-send"), event.on_click(CommentClicked)],
            [text("Comment")],
          ),
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
        html.div([attribute.class("jv-worklog")], [
          html.div([attribute.class("jv-comment-meta")], [
            text(
              entry.author
              <> " · "
              <> entry.time_spent
              <> " · "
              <> entry.started,
            ),
          ]),
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
          html.button(
            [attribute.class("jv-worklog-send"), event.on_click(WorklogClicked)],
            [text("Log work")],
          ),
        ]),
      ],
    ]),
  )
}

fn detail_title(detail: Detail) -> String {
  case detail {
    DetailLoaded(info) -> info.issue.summary
    DetailLoading(key) -> key
    DetailFailed(_) -> "Detail"
  }
}
