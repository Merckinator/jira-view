// The appearance palette lives in a native modal dialog. These helpers open
// and close it without fighting Lustre's virtual DOM.

const selector = ".jv-theme-dialog";

export function open_dialog() {
  const dialog = document.querySelector(selector);
  if (dialog && !dialog.open) dialog.showModal();
}

export function close_dialog() {
  const dialog = document.querySelector(selector);
  if (dialog && dialog.open) dialog.close();
}

// Cmd/Ctrl+K is the conventional command-palette shortcut. The listener only
// handles the modified key, leaving the table's j/k bindings untouched.
export function attach_shortcut(on_toggle) {
  if (window.__jira_view_palette_shortcut) return;
  window.__jira_view_palette_shortcut = true;
  document.addEventListener("keydown", (event) => {
    if (
      (event.metaKey || event.ctrlKey) &&
      !event.altKey &&
      !event.shiftKey &&
      (event.key === "k" || event.key === "K")
    ) {
      event.preventDefault();
      if (!event.repeat) on_toggle();
    }
  });
}

export function shortcut_label() {
  return /Mac|iPhone|iPad|iPod/.test(navigator.platform) ? "⌘K" : "Ctrl K";
}
