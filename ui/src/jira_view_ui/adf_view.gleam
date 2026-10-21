//// ADF → lustre elements. One branch per node type; block types beyond the
//// ones found in real captures (doc, paragraph, text, bulletList, listItem)
//// degrade gracefully: their text and children still render as plain text
//// instead of vanishing.

import gleam/list
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import shared/adf.{type AdfNode, safe_link}

/// Render the content list of an ADF document.
pub fn render(nodes: List(AdfNode)) -> Element(msg) {
  html.div([attribute.class("jv-adf")], list.map(nodes, block))
}

fn block(node: AdfNode) -> Element(msg) {
  case node.kind {
    "paragraph" -> html.p([], inline(node.content))
    "heading" -> html.h3([], inline(node.content))
    "bulletList" -> html.ul([], list.map(node.content, block))
    "orderedList" -> html.ol([], list.map(node.content, block))
    "listItem" -> html.li([], list.map(node.content, block))
    "codeBlock" -> html.pre([], inline(node.content))
    "blockQuote" -> html.blockquote([], list.map(node.content, block))
    // unknown node: keep its text and children
    _ -> html.div([], [text(node.text), ..list.map(node.content, block)])
  }
}

fn inline(nodes: List(AdfNode)) -> List(Element(msg)) {
  list.map(nodes, fn(node) {
    case node.kind {
      "text" -> marked(node)
      "hardBreak" -> html.br([])
      // non-text inline nodes (mention, emoji…): text stands in
      _ -> text(node.text)
    }
  })
}

fn marked(node: AdfNode) -> Element(msg) {
  list.fold(node.marks, text(node.text), fn(current, mark) {
    case mark.kind {
      "strong" -> html.strong([], [current])
      "em" -> html.em([], [current])
      "code" -> html.code([], [current])
      "link" ->
        case safe_link(mark.href) {
          True -> html.a([attribute.href(mark.href)], [current])
          False -> current
        }
      _ -> current
    }
  })
}
