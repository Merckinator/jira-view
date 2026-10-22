//// Atlassian Document Format: the tagged-JSON tree that descriptions and
//// comments arrive as. Decoded here (pure) into `AdfNode`; converting to
//// lustre elements is the UI package's job (lustre is a JS-first
//// dependency).
////
//// Block types covered are the ones that actually occur in the project's
//// real data (verified by capture: doc, paragraph, text, bulletList,
//// listItem); text is always kept, so an unhandled structure degrades to
//// plain text instead of vanishing.

import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type AdfMark {
  /// Inline mark ("strong", "em", "code", "link", ...).
  /// `href` is set only for links.
  AdfMark(kind: String, href: String)
}

pub type AdfNode {
  /// e.g. kind "doc" | "paragraph" | "text" | "bulletList" | "listItem".
  AdfNode(
    kind: String,
    /// Only text nodes carry text content.
    text: String,
    /// Child nodes (doc/paragraph/list bodies). Empty for plain text nodes.
    content: List(AdfNode),
    /// Inline marks; rendering decisions for them live in the UI package.
    marks: List(AdfMark),
  )
}

/// Decoder for any ADF node (recursive). A paragraph is still
/// "paragraph" even when marks are missing, and a text node's `text` is
/// always kept.
pub fn adf_decoder() -> decode.Decoder(AdfNode) {
  use <- decode.recursive
  use kind <- decode.field("type", decode.string)
  use text <- decode.optional_field("text", "", decode.string)
  use marks <- decode.optional_field("marks", [], decode.list(mark_decoder()))
  use content <- decode.optional_field(
    "content",
    [],
    decode.list(adf_decoder()),
  )
  decode.success(AdfNode(kind:, text:, content:, marks:))
}

/// Links carry their target in `attrs.href`; other marks don't.
fn mark_decoder() -> decode.Decoder(AdfMark) {
  use kind <- decode.field("type", decode.string)
  use href <- decode.then(decode.optionally_at(
    ["attrs", "href"],
    "",
    decode.string,
  ))
  decode.success(AdfMark(kind, href))
}

/// Only http(s), mailto and local links are rendered. A `javascript:` or
/// `data:` href would run in the app's origin, so it falls back to plain text.
pub fn safe_link(href: String) -> Bool {
  let href = string.lowercase(string.trim(href))
  string.starts_with(href, "http://")
  || string.starts_with(href, "https://")
  || string.starts_with(href, "mailto:")
  || string.starts_with(href, "/")
  || string.starts_with(href, "#")
}

// ————— building / encoding —————

/// The minimal document comment/worklog POST bodies need: one paragraph of
/// plain text. Newlines stay as-is (single paragraph) — good enough for the
/// short comments this app writes.
pub fn paragraph_document(text: String) -> AdfNode {
  AdfNode(kind: "doc", text: "", marks: [], content: [
    AdfNode(kind: "paragraph", text: "", marks: [], content: [
      AdfNode(kind: "text", text: text, marks: [], content: []),
    ]),
  ])
}

/// Build an ADF document from the comment composer's basic text format.
///
/// Blank lines separate blocks, a single newline is a line break, `- ` starts
/// a bullet item, `1. ` starts a numbered item, and `# ` starts a level-1
/// heading. Inline marks are not parsed: their text stays as plain text.
pub fn basic_document(text: String) -> AdfNode {
  let lines =
    text
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
    |> string.split("\n")

  let state =
    list.fold(lines, BasicState([], [], None, []), fn(state, line) {
      case string.trim(line) {
        "" -> flush_blocks(state)
        _ -> parse_basic_line(state, line)
      }
    })

  let state = flush_blocks(state)
  AdfNode(kind: "doc", text: "", marks: [], content: list.reverse(state.blocks))
}

type ListKind {
  BulletListKind
  OrderedListKind
}

/// Reverse accumulators while scanning the composer text: finished blocks,
/// the current paragraph's lines, and the current list's kind and items.
type BasicState {
  BasicState(
    blocks: List(AdfNode),
    paragraph: List(String),
    list_kind: Option(ListKind),
    items: List(String),
  )
}

fn parse_basic_line(state: BasicState, line: String) -> BasicState {
  // A marker with no text ("- ", "1. ", "# ") is dropped: an empty list item
  // or heading becomes a text node with no text, which Jira rejects.
  case bullet_item(line) {
    Some("") -> state
    Some(item) -> add_list_item(flush_paragraph(state), BulletListKind, item)
    None ->
      case ordered_item(line) {
        Some("") -> state
        Some(item) ->
          add_list_item(flush_paragraph(state), OrderedListKind, item)
        None ->
          case string.starts_with(line, "# ") {
            True ->
              case string.trim(string.drop_start(line, 2)) {
                "" -> state
                text ->
                  state
                  |> flush_blocks
                  |> prepend_block(heading_node(text))
              }
            False -> add_paragraph_line(flush_list(state), string.trim(line))
          }
      }
  }
}

fn bullet_item(line: String) -> Option(String) {
  case string.starts_with(line, "- ") {
    True -> Some(string.trim(string.drop_start(line, 2)))
    False -> None
  }
}

fn ordered_item(line: String) -> Option(String) {
  case string.split_once(line, ". ") {
    Ok(#(prefix, rest)) ->
      case int.parse(string.trim(prefix)) {
        Ok(number) ->
          // Cap the marker length so a sentence like "2026. was a good year"
          // stays prose instead of becoming an ordered list item.
          case number > 0 && string.length(prefix) <= 3 {
            True -> Some(string.trim(rest))
            False -> None
          }
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn add_list_item(
  state: BasicState,
  kind: ListKind,
  item: String,
) -> BasicState {
  case state.list_kind {
    Some(existing) if existing == kind ->
      BasicState(..state, items: [item, ..state.items])
    Some(_) -> add_list_item(flush_list(state), kind, item)
    None -> BasicState(..state, list_kind: Some(kind), items: [item])
  }
}

fn add_paragraph_line(state: BasicState, line: String) -> BasicState {
  BasicState(..state, paragraph: [line, ..state.paragraph])
}

fn prepend_block(state: BasicState, block: AdfNode) -> BasicState {
  BasicState(..state, blocks: [block, ..state.blocks])
}

fn flush_blocks(state: BasicState) -> BasicState {
  state |> flush_paragraph |> flush_list
}

fn flush_paragraph(state: BasicState) -> BasicState {
  case state.paragraph {
    [] -> state
    lines ->
      BasicState(
        ..state,
        blocks: [paragraph_node(list.reverse(lines)), ..state.blocks],
        paragraph: [],
      )
  }
}

fn flush_list(state: BasicState) -> BasicState {
  case state.list_kind, state.items {
    Some(kind), [_, ..] as items ->
      BasicState(
        ..state,
        blocks: [list_node(kind, list.reverse(items)), ..state.blocks],
        list_kind: None,
        items: [],
      )
    _, _ -> BasicState(..state, list_kind: None, items: [])
  }
}

fn paragraph_node(lines: List(String)) -> AdfNode {
  AdfNode("paragraph", "", inline_with_breaks(lines), [])
}

fn inline_with_breaks(lines: List(String)) -> List(AdfNode) {
  lines
  |> list.index_map(fn(line, index) {
    let text_node = AdfNode("text", line, [], [])
    case index {
      0 -> [text_node]
      _ -> [AdfNode("hardBreak", "", [], []), text_node]
    }
  })
  |> list.flatten
}

fn list_node(kind: ListKind, items: List(String)) -> AdfNode {
  let node_kind = case kind {
    BulletListKind -> "bulletList"
    OrderedListKind -> "orderedList"
  }
  AdfNode(
    node_kind,
    "",
    list.map(items, fn(item) {
      AdfNode("listItem", "", [paragraph_node([item])], [])
    }),
    [],
  )
}

fn heading_node(text: String) -> AdfNode {
  AdfNode("heading", "", [AdfNode("text", text, [], [])], [])
}

/// Encode back to ADF JSON. `doc` nodes carry `"version": 1` (Jira rejects
/// documents without it); text/marks/content are emitted only when present,
/// mirroring what Jira itself produces.
pub fn adf_to_json(node: AdfNode) -> Json {
  let base = [#("type", json.string(node.kind))]
  let base = case node.kind {
    "doc" -> list.append(base, [#("version", json.int(1))])
    "heading" ->
      list.append(base, [
        #("attrs", json.object([#("level", json.int(1))])),
      ])
    _ -> base
  }
  let base = case node.text {
    "" -> base
    text -> list.append(base, [#("text", json.string(text))])
  }
  let base = case node.marks {
    [] -> base
    marks -> list.append(base, [#("marks", json.array(marks, mark_to_json))])
  }
  let base = case node.content {
    [] -> base
    content ->
      list.append(base, [#("content", json.array(content, adf_to_json))])
  }
  json.object(base)
}

fn mark_to_json(mark: AdfMark) -> Json {
  let base = [#("type", json.string(mark.kind))]
  case mark.href {
    "" -> json.object(base)
    href ->
      json.object(
        list.append(base, [
          #("attrs", json.object([#("href", json.string(href))])),
        ]),
      )
  }
}
