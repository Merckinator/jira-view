// Document-level keyboard bindings for the issues table (vim-style).
//
// Attached exactly once (module flag survives app restarts/HMR); targets
// that take free-form input or activate on Enter (inputs, buttons, links) are
// skipped so typing and keyboard activation are never hijacked. Escape is the
// exception: it must still close the detail from those controls. `combos` is
// the whitelist — anything not on it is ignored, so update only ever hears
// keys it asked for.
export function attach_keys(combos, on_key) {
  if (window.__jira_view_keys_attached) return;
  window.__jira_view_keys_attached = true;
  const handled = new Set(combos);
  document.addEventListener("keydown", (event) => {
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