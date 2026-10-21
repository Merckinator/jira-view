//// Color-scheme preference: follow the operating system, or force light/dark.

@external(javascript, "./theme_ffi.mjs", "get_theme")
fn get_theme() -> String

@external(javascript, "./theme_ffi.mjs", "set_theme")
fn set_theme(theme: String) -> Nil

pub type Theme {
  /// Follow `prefers-color-scheme`.
  Auto
  Light
  Dark
}

/// Read the stored preference; absent or unrecognized means Auto.
pub fn load() -> Theme {
  case get_theme() {
    "light" -> Light
    "dark" -> Dark
    _ -> Auto
  }
}

/// Auto -> Light -> Dark -> Auto.
pub fn next(theme: Theme) -> Theme {
  case theme {
    Auto -> Light
    Light -> Dark
    Dark -> Auto
  }
}

/// Apply the preference to the document and remember it for the next visit.
pub fn apply(theme: Theme) -> Nil {
  set_theme(to_string(theme))
}

pub fn label(theme: Theme) -> String {
  case theme {
    Auto -> "Auto"
    Light -> "Light"
    Dark -> "Dark"
  }
}

fn to_string(theme: Theme) -> String {
  case theme {
    Auto -> "auto"
    Light -> "light"
    Dark -> "dark"
  }
}
