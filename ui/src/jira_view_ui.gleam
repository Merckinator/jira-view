//// "My issues" — Lustre MVU app over the backend proxy.
////
//// Phase 2: table + detail panel with ADF rendering. Phase 3: private
//// drag-and-drop ordering (SortableJS + a keyed tbody; a drop reorders
//// the model and PATCHes the full key list to /jira/views/:view/order)
//// and keyboard navigation (j/k cursor, Shift+j/K relocate, Enter opens
//// the detail). Phase 4: optimistic writes in the panel — transitions
//// (status flips locally first), comments, work log; failures undo
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
    // — issues of the current view —
    jql_input: String,
    state: State,
    // — ordering (Phase 3) —
    cursor: Option(Int),
    order_error: Option(String),
    // — detail panel writes (Phase 4) —
    selected: Option(Detail),
    transitions: Option(Result(List(types.Transition), String)),
    resolutions: Option(Result(List(types.Resolution), String)),
    resolution_draft: String,
    write_error: Option(String),
    comment_draft: String,
    pending_comments: List(String),
    worklog_draft: String,
    pending_worklog: List(String),
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
  PickBoardSource
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
  Refresh
  GotIssues(view_id: String, result: Result(List(Issue), String))
  FocusDown
  FocusUp
  RowDown
  RowUp
  Open
  Dropped(from: Int, to: Int)
  OrderSaved(Result(Nil, String))
  Select(key: String)
  GotDetail(key: String, result: Result(IssueDetail, String))
  CloseDetail
  GotTransitions(key: String, result: Result(List(types.Transition), String))
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
      views: ViewsLoading,
      current_view: None,
      boards: None,
      edit: None,
      view_error: None,
      jql_input: default_jql,
      state: Loading,
      cursor: None,
      order_error: None,
      selected: None,
      transitions: None,
      resolutions: None,
      resolution_draft: "",
      write_error: None,
      comment_draft: "",
      pending_comments: [],
      worklog_draft: "",
      pending_worklog: [],
    ),
    effect.batch([
      fetch_views(),
      fetch_resolutions(),
      // Document-level key handler: attach once at startup (idempotent FFI).
      keyboard.attach(keyboard_bindings()),
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
      Model(..model, edit: Some(new_edit_form()), boards: None, view_error: None),
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
        Some(form) ->
          #(Model(..model, edit: Some(EditForm(..form, source: types.Jql("")))), effect.none())
        None -> #(model, effect.none())
      }
    PickBoardSource ->
      case model.edit {
        Some(form) -> #(
          Model(
            ..model,
            edit: Some(EditForm(
              ..form,
              source: source_board_of(model.boards, form.source),
            )),
          ),
          effect.none(),
        )
        None -> #(model, effect.none())
      }
    SetEditName(name) ->
      case model.edit {
        Some(form) -> #(Model(..model, edit: Some(EditForm(..form, name:))), effect.none())
        None -> #(model, effect.none())
      }
    SetEditJql(jql) ->
      case model.edit {
        Some(form) ->
          #(Model(..model, edit: Some(EditForm(..form, source: types.Jql(jql)))), effect.none())
        None -> #(model, effect.none())
      }
    SetEditBoard(board_id) ->
      case model.edit {
        Some(form) -> #(
          Model(..model, edit: Some(EditForm(..form, source: types.Board(board_id)))),
          effect.none(),
        )
        None -> #(model, effect.none())
      }
    ToggleColumn(column, checked) ->
      case model.edit {
        Some(form) -> #(
          Model(
            ..model,
            edit: Some(EditForm(..form, columns: set_column(form.columns, column, checked))),
          ),
          effect.none(),
        )
        None -> #(model, effect.none())
      }
    SaveView ->
      case model.edit {
        Some(form) -> #(Model(..model, view_error: None), save_view_effect(form))
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
        Some(EditForm(Some(id), _, _, _)) -> #(
          Model(..model, view_error: None),
          fetch.delete_json("/jira/views/" <> id, fn(result) {
            GotViewDeleted(id, result)
          }),
        )
        _ -> #(model, effect.none())
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
            Model(..model, views: ViewsLoaded(remaining), edit: None, view_error: None),
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
        True ->
          #(
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
        True ->
          #(
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
        True ->
          #(
            Model(..model, selected: Some(DetailFailed(message))),
            effect.none(),
          )
        False -> #(model, effect.none())
      }
    CloseDetail -> #(Model(..model, selected: None), effect.none())
    GotTransitions(key, Ok(transitions)) ->
      case is_selected(model, key) {
        True ->
          #(
            Model(..model, transitions: Some(Ok(transitions))),
            effect.none(),
          )
        False -> #(model, effect.none())
      }
    GotTransitions(key, Error(message)) ->
      case is_selected(model, key) {
        True ->
          #(
            Model(..model, transitions: Some(Error(message))),
            effect.none(),
          )
        False -> #(model, effect.none())
      }
    GotResolutions(Ok(resolutions)) ->
      #(
        Model(
          ..model,
          resolutions: Some(Ok(resolutions)),
          resolution_draft: choose_resolution(
            model.resolution_draft,
            resolutions,
          ),
        ),
        effect.none(),
      )
    GotResolutions(Error(message)) ->
      #(Model(..model, resolutions: Some(Error(message))), effect.none())
    SetResolution(name) -> #(
      Model(..model, resolution_draft: name),
      effect.none(),
    )
    TransitionClicked(transition) ->
      case selected_key(model) {
        Error(_) -> #(model, effect.none())
        Ok(key) -> {
          let requires_resolution =
            transition_requires_resolution(transition)
          case requires_resolution, string.trim(model.resolution_draft) {
            True, "" ->
              #(
                Model(
                  ..model,
                  write_error: Some("Pick a resolution first."),
                ),
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
                  state: flip_row_status(
                    model.state,
                    key,
                    transition.to_status,
                  ),
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

// ————— views plumbing —————

/// The freshly loaded list selects and loads its first view.
fn view_list_ready(
  model: Model,
  views: List(types.ViewDef),
) -> #(Model, Effect(Msg)) {
  case views {
    [view, ..] -> switch_to_view(Model(..model, views: ViewsLoaded(views)), view)
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
      transitions: None,
      comment_draft: "",
      pending_comments: [],
      worklog_draft: "",
      pending_worklog: [],
    ),
    fetch_issues_effect(view),
  )
}

fn upsert_view(views: ViewList, view: types.ViewDef) -> ViewList {
  case views {
    ViewsLoaded(existing) ->
      case list.any(existing, fn(existing_view) { existing_view.id == view.id }) {
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
  )
}

/// Board mode starts on the first loaded board (placeholder id 0 until the
/// boards arrive; the select then shows the options).
fn source_board_of(
  boards: Option(Result(List(types.AgileBoard), String)),
  previous: types.ViewSource,
) -> types.ViewSource {
  case boards {
    Some(Ok([types.AgileBoard(id, _, _), ..])) -> types.Board(id)
    Some(Ok([])) -> types.Board(0)
    _ -> previous
  }
}

fn set_column(columns: List(String), column: String, checked: Bool) -> List(String) {
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
      fetch.put_json_raw(
        "/jira/views/" <> id,
        view_body(form),
        fn(response) {
          case response {
            Ok(body) ->
              case json.parse(body, types.app_view_decoder()) {
                Ok(view) -> GotViewSaved(Ok(view))
                Error(error) -> GotViewSaved(Error(string.inspect(error)))
              }
            Error(message) -> GotViewSaved(Error(message))
          }
        },
      )
    None ->
      fetch.post_json_raw(
        "/jira/views",
        view_body(form),
        fn(response) {
          case response {
            Ok(body) ->
              case json.parse(body, types.app_view_decoder()) {
                Ok(view) -> GotViewSaved(Ok(view))
                Error(error) -> GotViewSaved(Error(string.inspect(error)))
              }
            Error(message) -> GotViewSaved(Error(message))
          }
        },
      )
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

fn decode_issues(
  view_id: String,
  response: Result(String, String),
) -> Msg {
  case response {
    Ok(body) ->
      case json.parse(body, types.issues_response_decoder()) {
        Ok(issues) -> GotIssues(view_id, Ok(issues))
        Error(error) -> GotIssues(view_id, Error(string.inspect(error)))
      }
    Error(message) -> GotIssues(view_id, Error(message))
  }
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
      write_error: None,
      comment_draft: "",
      pending_comments: [],
      worklog_draft: "",
      pending_worklog: [],
    ),
    effect.batch([fetch_detail(key), fetch_transitions(key), resolutions_effect]),
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
            save_order(issues, model.current_view),
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
fn save_order(issues: List(Issue), view: Option(types.ViewDef)) -> Effect(Msg) {
  case view {
    Some(types.ViewDef(id: view_id, ..)) ->
      fetch.patch_json(
        "/jira/views/" <> view_id <> "/order",
        json.to_string(json.object([
          #("keys", json.array(list.map(issues, fn(issue) { issue.key }), json.string)),
        ])),
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
        case json.parse(body, types.issue_detail_decoder()) {
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

fn append_comment(
  selected: Option(Detail),
  comment: types.Comment,
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(types.IssueDetail(
        ..info,
        comments: list.append(info.comments, [comment]),
      )))
    selected -> selected
  }
}

fn append_worklog(
  selected: Option(Detail),
  entry: types.WorklogEntry,
) -> Option(Detail) {
  case selected {
    Some(DetailLoaded(info)) ->
      Some(DetailLoaded(types.IssueDetail(
        ..info,
        worklog: list.append(info.worklog, [entry]),
      )))
    selected -> selected
  }
}

// ————— view —————

pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("jv")], [
    html.div([attribute.class("jv-toolbar")], toolbar(model)),
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
    case model.selected {
      Some(detail) -> detail_panel(model, detail)
      None -> element.none()
    },
  ])
}

fn columns_of(model: Model) -> List(String) {
  case model.current_view {
    Some(view) -> view.columns
    None -> default_columns
  }
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
          html.div([attribute.class("jv-jql")], list.flatten([
            case views {
              [] -> [
                html.span([attribute.class("jv-note")], [text("No views. Create one:")]),
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
                        attribute.selected(
                          case model.current_view {
                            Some(current) -> current.id == view.id
                            None -> False
                          },
                        ),
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
              html.button([attribute.class("jv-refresh"), event.on_click(Refresh)], [
                text("Refresh"),
              ]),
            ],
            case model.current_view, model.edit {
              Some(_), None -> [
                html.button(
                  [attribute.class("jv-edit-view"), event.on_click(EditExisting)],
                  [text("Edit")],
                )
              ]
              _, _ -> []
            },
            [
              html.button([attribute.class("jv-new-view"), event.on_click(NewView)], [
                text("+ New view"),
              ]),
            ],
          ])),
        ],
      ])
  }
}

/// Between the view select and Refresh: the editable JQL (a JQL view's
/// query console; hidden while the edit form is open — the form has its
/// own field), or the board note.
fn query_slot(model: Model, view: types.ViewDef) -> Element(Msg) {
  case view.source {
    types.Jql(_) -> case model.edit {
      Some(_) -> element.none()
      None ->
        html.input([
          attribute.type_("text"),
          attribute.class("jv-jql-input"),
          attribute.value(model.jql_input),
          event.on_input(SetJql),
        ])
    }
    types.Board(_) ->
      html.span([attribute.class("jv-sprint-note")], [
        text("board · active sprint"),
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
    html.div([attribute.class("jv-edit-columns")], list.flatten([
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
    ])),
    html.div([attribute.class("jv-edit-actions")], [
      html.button([attribute.class("jv-save-view"), event.on_click(SaveView)], [
        text("Save view"),
      ]),
      html.button([attribute.class("jv-cancel-edit"), event.on_click(CancelEdit)], [
        text("Cancel"),
      ]),
      html.button(
        [
          attribute.class("jv-delete"),
          attribute.disabled(form.id == None),
          event.on_click(DeleteView),
        ],
        [text("Delete")],
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
            [attribute.value("loading"), attribute.selected(False)],
            "loading boards…",
          )
        ]
        Some(Error(_)) -> [
          html.option(
            [attribute.value("loaderr"), attribute.selected(False)],
            "boards unavailable",
          )
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
fn table(issues: List(Issue), columns: List(String), cursor: Option(Int)) -> Element(Msg) {
  html.table([attribute.class("jv-table")], [
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
  ])
}

fn head(column: String) -> Element(Msg) {
  html.th([attribute.class("jv-col-" <> column)], [text(column)])
}

fn cell(content: String) -> Element(Msg) {
  html.td([], [text(content)])
}

fn row(issue: Issue, index: Int, cursor: Option(Int), columns: List(String)) -> Element(Msg) {
  keyed.element(
    "tr",
    [
      attribute.class(case cursor {
        Some(focused) if focused == index -> "jv-row jv-row-focused"
        _ -> "jv-row"
      }),
      event.on_click(Select(issue.key)),
    ],
    list.flatten([
      [#("grab", grab_cell())],
      list.map(columns, fn(column) {
        #(column, view_cell(issue, column))
      }),
    ]),
  )
}

fn grab_cell() -> Element(Msg) {
  html.td(
    [attribute.class("jv-grab"), attribute.title("Drag to reorder")],
    [text("⋮⋮")],
  )
}

fn view_cell(issue: Issue, column: String) -> Element(Msg) {
  case column {
    "key" -> cell(issue.key)
    "summary" -> cell(issue.summary)
    "status" -> cell(issue.status.name)
    "assignee" -> assignee_cell(issue)
    "updated" -> cell(issue.updated)
    _ -> cell("")
  }
}

fn assignee_cell(issue: Issue) -> Element(Msg) {
  html.td([attribute.class("jv-col-assignee")], [
    case issue.assignee {
      Some(user) if user.account_id != "" && user.avatar_url != "" ->
        html.img([
          attribute.class("jv-avatar"),
          attribute.src("/jira/avatar/" <> user.account_id),
          attribute.alt(""),
        ])
      _ -> element.none()
    },
    text(assignee_name(issue.assignee)),
  ])
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
          transitions_row(model),
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
    },
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
  html.div([attribute.class("jv-section")], list.flatten([
    [html.h3([attribute.class("jv-section-title")], [text("Attachments")])],
    case attachments {
      [] -> [html.p([attribute.class("jv-note")], [text("None.")])]
      _ -> list.map(attachments, fn(attachment) {
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
  ]))
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
              entry.author <> " · " <> entry.time_spent <> " · " <> entry.started,
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