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
import gleam/json.{type Json}
import gleam/list
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

/// Encode back to ADF JSON. `doc` nodes carry `"version": 1` (Jira rejects
/// documents without it); text/marks/content are emitted only when present,
/// mirroring what Jira itself produces.
pub fn adf_to_json(node: AdfNode) -> Json {
  let base = [#("type", json.string(node.kind))]
  let base = case node.kind {
    "doc" -> list.append(base, [#("version", json.int(1))])
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
