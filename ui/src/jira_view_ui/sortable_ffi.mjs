// SortableJS hookup for the issues table.
//
// Mounted through a Lustre `effect.before_paint` (see sortable.gleam), so the
// <tbody> exists and the DOM is patched before this runs. Attaching is
// idempotent: `Sortable.get(el)` destroys any instance left over from a
// previous render (e.g. after a Loading → Ready remount).
//
// The Lustre model is the source of truth: SortableJS moves the row
// visually, then calls `on_drop`; `update` reorders the model and Lustre
// re-renders the rows into the new model order. The DOM order Sortable
// leaves behind already matches that order, so row contents just patch in
// place — no manual DOM bookkeeping.
import Sortable from "sortablejs";

export function attach_sortable(root, selector, on_drop) {
  const el =
    (root && root.querySelector(selector)) ||
    document.querySelector(selector);
  if (!el) return;
  const existing = Sortable.get(el);
  if (existing) existing.destroy();
  new Sortable(el, {
    animation: 150,
    draggable: "tr",
    handle: ".jv-grab",
    onEnd(event) {
      const { oldIndex, newIndex } = event;
      if (
        oldIndex !== undefined &&
        newIndex !== undefined &&
        oldIndex !== newIndex
      ) {
        on_drop(oldIndex, newIndex);
      }
    },
  });
}