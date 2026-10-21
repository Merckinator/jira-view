// Document-level keyboard bindings for the issues table (vim-style).
//
// Attached exactly once (module flag survives app restarts/HMR); targets
// that take free-form input or activate on Enter (inputs, buttons, links) are
// skipped so typing and keyboard activation are never hijacked. Escape is the
// exception: it must still close the detail from those controls, and with no
// detail open it returns focus to the list. `combos` is the whitelist —
// anything not on it is ignored, so update only ever hears keys it asked for.
export function attach_keys(combos, on_key) {
  if (window.__jira_view_keys_attached) return;
  window.__jira_view_keys_attached = true;
  const handled = new Set(combos);
  document.addEventListener("keydown", (event) => {
    // A modal dialog owns its keys (Escape must not also close the detail
    // behind the appearance palette).
    if (document.querySelector("dialog[open]")) return;
    if (
      event.ctrlKey ||
      event.altKey ||
      event.metaKey ||
      !handled.has(event.key)
    ) {
      return;
    }
    const target = event.target;
    const interactive =
      target &&
      target.closest &&
      target.closest(
        "input, textarea, select, button, a, [contenteditable='true'], [role='button']",
      );
    if (
      event.key !== "Escape" &&
      (interactive || (target && target.isContentEditable))
    ) {
      return;
    }
    event.preventDefault();
    on_key(event.key);
  });
}

// Focus the issues table without scrolling away from the cursor. The table is
// the list's single tab stop; once focused, j/k/Enter reach the document-level
// handler again (it ignores controls, but the table is not one).
export function focus_table() {
  const table = document.querySelector(".jv-table");
  if (table) table.focus({ preventScroll: true });
}

// Editing a summary replaces the heading with an input; focus and select it so
// typing replaces the old value.
export function focus_summary_input() {
  const input = document.querySelector(".jv-summary-input");
  if (input) {
    input.focus();
    input.select();
  }
}