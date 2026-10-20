import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import jira_view_ui
import jira_view_ui/ordering
import shared/types

pub fn main() {
  gleeunit.main()
}

fn sample_issue(key: String) -> types.Issue {
  types.Issue(
    key: key,
    id: "1",
    summary: key,
    status: types.Status("To Do", "new"),
    assignee: None,
    labels: [],
    updated: "2026-10-19",
  )
}

fn sample_issues() -> List(types.Issue) {
  [sample_issue("A"), sample_issue("B"), sample_issue("C")]
}

fn keys(issues: List(types.Issue)) -> List(String) {
  list.map(issues, fn(issue) { issue.key })
}

// ————— drag ordering —————

pub fn move_item_down_test() {
  ordering.move_item(sample_issues(), 0, 2)
  |> keys
  |> should.equal(["B", "C", "A"])
}

pub fn move_item_up_test() {
  ordering.move_item(sample_issues(), 2, 0)
  |> keys
  |> should.equal(["C", "A", "B"])
}

pub fn move_item_same_index_test() {
  ordering.move_item(sample_issues(), 1, 1)
  |> keys
  |> should.equal(["A", "B", "C"])
}

pub fn move_item_out_of_range_test() {
  ordering.move_item(sample_issues(), 3, 0)
  |> keys
  |> should.equal(["A", "B", "C"])

  ordering.move_item(sample_issues(), 0, -1)
  |> keys
  |> should.equal(["A", "B", "C"])

  ordering.move_item([], 0, 0)
  |> keys
  |> should.equal([])
}

pub fn insert_at_test() {
  ordering.insert_at([sample_issue("A"), sample_issue("B")], 1, sample_issue("X"))
  |> keys
  |> should.equal(["A", "X", "B"])
}

// ————— keyboard cursor —————

pub fn focus_empty_list_test() {
  ordering.focus([], None, True)
  |> should.equal(None)
}

pub fn focus_starts_at_top_or_bottom_test() {
  ordering.focus(sample_issues(), None, True)
  |> should.equal(Some(0))

  ordering.focus(sample_issues(), None, False)
  |> should.equal(Some(2))
}

pub fn focus_moves_and_clamps_test() {
  ordering.focus(sample_issues(), Some(0), True)
  |> should.equal(Some(1))

  ordering.focus(sample_issues(), Some(2), True)
  |> should.equal(Some(2))

  ordering.focus(sample_issues(), Some(0), False)
  |> should.equal(Some(0))

  ordering.focus(sample_issues(), Some(1), False)
  |> should.equal(Some(0))
}

pub fn table_focus_starts_at_the_first_row_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      selected: None,
      state: jira_view_ui.Ready(sample_issues()),
      cursor: None,
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.TableFocused)
  next.cursor
  |> should.equal(Some(0))
}

pub fn table_focus_keeps_the_existing_cursor_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      selected: None,
      state: jira_view_ui.Ready(sample_issues()),
      cursor: Some(2),
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.TableFocused)
  next.cursor
  |> should.equal(Some(2))
}

// ————— stale replies —————

fn test_model() -> jira_view_ui.Model {
  jira_view_ui.Model(
    views: jira_view_ui.ViewsLoaded([]),
    current_view: Some(types.ViewDef(
      id: "v",
      name: "V",
      source: types.Jql("project = X"),
      columns: ["key"],
    )),
    boards: None,
    edit: None,
    view_error: None,
    jql_input: "",
    state: jira_view_ui.Loading,
    cursor: None,
    order_error: None,
    selected: Some(jira_view_ui.DetailLoading("B")),
    transitions: None,
    resolutions: None,
    resolution_draft: "",
    write_error: None,
    comment_draft: "",
    pending_comments: [],
    worklog_draft: "",
    pending_worklog: [],
    label_draft: "",
  )
}

pub fn stale_detail_reply_is_ignored_test() {
  let #(next, _) =
    jira_view_ui.update(
      test_model(),
      jira_view_ui.GotDetail("A", Error("stale")),
    )
  next.selected
  |> should.equal(Some(jira_view_ui.DetailLoading("B")))
}

pub fn matching_detail_reply_is_applied_test() {
  let #(next, _) =
    jira_view_ui.update(
      test_model(),
      jira_view_ui.GotDetail("B", Error("boom")),
    )
  next.selected
  |> should.equal(Some(jira_view_ui.DetailFailed("boom")))
}

pub fn stale_transitions_reply_is_ignored_test() {
  let #(next, _) =
    jira_view_ui.update(
      test_model(),
      jira_view_ui.GotTransitions("A", Ok([])),
    )
  next.transitions
  |> should.equal(None)
}

pub fn stale_view_reply_is_ignored_test() {
  let #(next, _) =
    jira_view_ui.update(
      test_model(),
      jira_view_ui.GotIssues("other", Ok([])),
    )
  next.state
  |> should.equal(jira_view_ui.Loading)
}

pub fn matching_view_reply_is_applied_test() {
  let #(next, _) =
    jira_view_ui.update(
      test_model(),
      jira_view_ui.GotIssues("v", Ok([])),
    )
  next.state
  |> should.equal(jira_view_ui.Ready([]))
}

// ————— detail navigation —————

pub fn escape_is_bound_to_escape_test() {
  jira_view_ui.keyboard_bindings()
  |> list.key_find("Escape")
  |> should.equal(Ok(jira_view_ui.Escape))
}

pub fn close_detail_returns_to_the_list_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      state: jira_view_ui.Ready(sample_issues()),
      cursor: Some(1),
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.CloseDetail)
  next.selected
  |> should.equal(None)
  next.cursor
  |> should.equal(Some(1))
}

pub fn escape_closes_the_detail_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      state: jira_view_ui.Ready(sample_issues()),
      cursor: Some(1),
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.Escape)
  next.selected
  |> should.equal(None)
  next.cursor
  |> should.equal(Some(1))
}

pub fn escape_without_detail_keeps_the_list_cursor_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      selected: None,
      state: jira_view_ui.Ready(sample_issues()),
      cursor: Some(2),
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.Escape)
  next.selected
  |> should.equal(None)
  next.cursor
  |> should.equal(Some(2))
}

pub fn escape_keeps_the_view_editor_open_test() {
  let form =
    jira_view_ui.EditForm(
      id: Some("v"),
      name: "V",
      source: types.Jql("project = X"),
      columns: ["key"],
      confirm_delete: False,
    )
  let model =
    jira_view_ui.Model(
      ..test_model(),
      selected: None,
      edit: Some(form),
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.Escape)
  next.edit
  |> should.equal(Some(form))
}

pub fn enter_is_ignored_while_detail_is_open_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      state: jira_view_ui.Ready(sample_issues()),
      cursor: Some(0),
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.Open)
  next.selected
  |> should.equal(Some(jira_view_ui.DetailLoading("B")))
}

// ————— resolution picker —————

pub fn resolution_defaults_to_done_test() {
  let #(next, _) =
    jira_view_ui.update(
      test_model(),
      jira_view_ui.GotResolutions(Ok([
        types.Resolution("1", "Won't Do"),
        types.Resolution("2", "Done"),
      ])),
    )
  next.resolution_draft |> should.equal("Done")
}

pub fn required_resolution_without_pick_is_blocked_test() {
  let transition =
    types.Transition("1", "Done", "Done", [
      types.TransitionField("resolution", True),
    ])
  let #(next, _) =
    jira_view_ui.update(
      test_model(),
      jira_view_ui.TransitionClicked(transition),
    )
  next.write_error
  |> should.equal(Some("Pick a resolution first."))
}

// ————— destructive actions —————

pub fn delete_requires_two_clicks_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      edit: Some(jira_view_ui.EditForm(
        id: Some("v"),
        name: "V",
        source: types.Jql("project = X"),
        columns: ["key"],
        confirm_delete: False,
      )),
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.DeleteView)
  next.edit
  |> should.equal(Some(jira_view_ui.EditForm(
    id: Some("v"),
    name: "V",
    source: types.Jql("project = X"),
    columns: ["key"],
    confirm_delete: True,
  )))
}

// ————— labels —————

fn loaded_detail(key: String, labels: List(String)) -> jira_view_ui.Detail {
  jira_view_ui.DetailLoaded(types.IssueDetail(
    issue: types.Issue(..sample_issue(key), labels: labels),
    description: [],
    comments: [],
    worklog: [],
    attachments: [],
  ))
}

pub fn add_label_updates_detail_and_row_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      state: jira_view_ui.Ready([sample_issue("B")]),
      selected: Some(loaded_detail("B", [])),
      label_draft: "urgent",
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.AddLabel)

  let assert Some(jira_view_ui.DetailLoaded(info)) = next.selected
  info.issue.labels |> should.equal(["urgent"])

  let assert jira_view_ui.Ready([row]) = next.state
  row.labels |> should.equal(["urgent"])

  next.label_draft |> should.equal("")
}

pub fn remove_label_updates_detail_and_row_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      state: jira_view_ui.Ready([sample_issue("B")]),
      selected: Some(loaded_detail("B", ["urgent", "docs"])),
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.RemoveLabel("urgent"))

  let assert Some(jira_view_ui.DetailLoaded(info)) = next.selected
  info.issue.labels |> should.equal(["docs"])

  let assert jira_view_ui.Ready([row]) = next.state
  row.labels |> should.equal(["docs"])
}

pub fn invalid_label_is_rejected_test() {
  let model =
    jira_view_ui.Model(
      ..test_model(),
      selected: Some(loaded_detail("B", [])),
      label_draft: "two words",
    )
  let #(next, _) = jira_view_ui.update(model, jira_view_ui.AddLabel)

  let assert Some(jira_view_ui.DetailLoaded(info)) = next.selected
  info.issue.labels |> should.equal([])

  next.write_error
  |> should.equal(Some("Labels can't contain spaces."))
}
