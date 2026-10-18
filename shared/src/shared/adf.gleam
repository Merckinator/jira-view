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
