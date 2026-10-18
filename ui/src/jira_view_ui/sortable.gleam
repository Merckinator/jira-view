//// Drag-and-drop: SortableJS on the issues <tbody>, via the JS FFI.
////
//// Attach through `effect.before_paint`, which Lustre guarantees runs after
//// the view is rendered and the DOM is patched — exactly when the (new)
//// tbody exists. Attaching again after every ready-render is intentional:
//// tbody nodes come and go with the Loading/Ready cycle, and re-attaching
//// is idempotent (existing instances are destroyed first).
////
//// The model is always the source of truth: on drop, `update` reorders the
//// list and saves it; Lustre's re-render leaves the *content* of rows in
//// model order, and Sortable's physical DOM order already matches.

import gleam/dynamic.{type Dynamic}
import lustre/effect.{type Effect}

@external(javascript, "./sortable_ffi.mjs", "attach_sortable")
fn attach_sortable_ffi(
  root: Dynamic,
  selector: String,
  on_drop: fn(Int, Int) -> Nil,
) -> Nil

/// Make the element at `selector` (inside the app root) drag-sortable.
/// `on_drop` receives SortableJS's `(old_index, new_index)` — indexes over
/// the draggable children, which for the issues table are exactly the model
/// list indexes.
pub fn attach(selector: String, on_drop: fn(Int, Int) -> msg) -> Effect(msg) {
  effect.before_paint(fn(dispatch, root) {
    attach_sortable_ffi(root, selector, fn(old_index, new_index) {
      dispatch(on_drop(old_index, new_index))
    })
  })
}