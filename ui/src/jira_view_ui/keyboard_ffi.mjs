// Document-level keyboard bindings for the issues table (vim-style).
//
// Attached exactly once (module flag survives app restarts/HMR); targets
// that take free-form input are skipped so typing in the JQL box is never
// hijacked. `combos` is the whitelist — anything not on it is ignored, so
// update only ever hears keys it asked for.
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
    const tag = target && target.tagName;
    if (
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      tag === "SELECT" ||
      target.isContentEditable
    ) {
      return;
    }
    event.preventDefault();
    on_key(event.key);
  });
}