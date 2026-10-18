//// "My issues" — the first real view (Phase 2).
////
//// A Lustre MVU app: fetches GET /jira/search?jql=… (the backend proxy
//// caches every fetch in SQLite), renders a table, and on row click opens
//// a detail panel whose description is rendered by the shared ADF
//// decoder + converter. The JQL box doubles as the explicit refresh
//// control: edit it and hit Refresh to refetch (and re-cache).

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import jira_view_ui/adf_view
import jira_view_ui/fetch
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import shared/types.{type Issue, type IssueDetail}

/// The plan's default view. JQL must be bounded: the new search endpoint
/// rejects unbounded queries (see plan gotchas).
const default_jql =
  "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"

pub type Model {
  Model(jql_input: String, state: State, selected: Option(Detail))
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
}

pub fn main() {
  let app = lustre.application(init: init, update: update, view: view)
  let assert Ok(_) = lustre.start(app, onto: "#app", with: Nil)
}

pub fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    Model(jql_input: default_jql, state: Loading, selected: None),
    fetch_issues(default_jql),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SetJql(jql) -> #(Model(..model, jql_input: jql), effect.none())
    Refresh -> #(Model(..model, state: Loading), fetch_issues(model.jql_input))
    GotIssues(Ok(issues)) -> #(
      Model(..model, state: Ready(issues)),
      effect.none(),
    )
    GotIssues(Error(message)) -> #(
      Model(..model, state: Failed(message)),
      effect.none(),
    )
    Select(key) -> #(
      Model(..model, selected: Some(DetailLoading(key))),
      fetch_detail(key),
    )
    GotDetail(Ok(detail)) -> #(
      Model(..model, selected: Some(DetailLoaded(detail))),
      effect.none(),
    )
    GotDetail(Error(message)) -> #(
      Model(..model, selected: Some(DetailFailed(message))),
      effect.none(),
    )
    CloseDetail -> #(Model(..model, selected: None), effect.none())
  }
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
  "/jira/search?" <> uri.query_to_string([#("jql", jql)])
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
    case model.state {
      Loading -> html.p([attribute.class("jv-note")], [text("Loading…")])
      Failed(message) ->
        html.p([attribute.class("jv-error")], [text("Error: " <> message)])
      Ready(issues) ->
        case issues {
          [] -> html.p([attribute.class("jv-note")], [text("No issues.")])
          _ -> table(issues)
        }
    },
    case model.selected {
      Some(detail) -> detail_panel(detail)
      None -> element.none()
    },
  ])
}

fn table(issues: List(Issue)) -> Element(Msg) {
  html.table([attribute.class("jv-table")], [
    html.thead([], [
      html.tr([], [
        head("key"),
        head("summary"),
        head("status"),
        head("assignee"),
        head("updated"),
      ]),
    ]),
    html.tbody([], list.map(issues, row)),
  ])
}

fn head(title: String) -> Element(Msg) {
  html.th([attribute.class("jv-col-" <> title)], [text(title)])
}

fn cell(content: String) -> Element(Msg) {
  html.td([], [text(content)])
}

fn row(issue: Issue) -> Element(Msg) {
  html.tr([attribute.class("jv-row"), event.on_click(Select(issue.key))], [
    cell(issue.key),
    cell(issue.summary),
    cell(issue.status.name),
    cell(assignee_name(issue.assignee)),
    cell(issue.updated),
  ])
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
