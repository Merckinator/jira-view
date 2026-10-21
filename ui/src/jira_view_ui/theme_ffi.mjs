// Persist an explicit light/dark choice; "auto" follows the OS again.
const key = "jv-theme";

export function get_theme() {
  try {
    const value = localStorage.getItem(key);
    return value === "light" || value === "dark" ? value : "auto";
  } catch {
    return "auto";
  }
}

export function set_theme(theme) {
  if (theme === "light" || theme === "dark") {
    document.documentElement.dataset.theme = theme;
  } else {
    delete document.documentElement.dataset.theme;
  }

  try {
    if (theme === "light" || theme === "dark") {
      localStorage.setItem(key, theme);
    } else {
      localStorage.removeItem(key);
    }
  } catch {
    // The in-memory toggle still works when storage is unavailable.
  }
}
