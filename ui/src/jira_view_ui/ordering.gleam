//// Pure list helpers for drag/keyboard ordering. Kept out of the MVU app so
//// they can be tested on their own.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// Remove the item at `from` and reinsert it at `to` (post-drop index).
/// Out-of-range indexes return the list unchanged.
pub fn move_item(items: List(a), from: Int, to: Int) -> List(a) {
  case from >= 0 && to >= 0, list.drop(items, from) {
    True, [item, ..rest] -> {
      let before = list.take(items, from)
      case from < to {
        True -> list.append(before, insert_at(rest, to - from, item))
        False -> list.append(insert_at(before, to, item), rest)
      }
    }
    _, _ -> items
  }
}

pub fn insert_at(items: List(a), at: Int, item: a) -> List(a) {
  list.append(list.take(items, at), [item, ..list.drop(items, at)])
}

/// j/k cursor movement over a list, clamped inside it. Starting with no cursor
/// picks the top (down) or bottom (up).
pub fn focus(
  items: List(a),
  cursor: Option(Int),
  down: Bool,
) -> Option(Int) {
  case items {
    [] -> cursor
    _ -> {
      let last = list.length(items) - 1
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
}
