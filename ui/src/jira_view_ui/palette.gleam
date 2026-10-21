//// Document-level helpers for the floating appearance palette.

@external(javascript, "./palette_ffi.mjs", "open_dialog")
pub fn open_dialog() -> Nil

@external(javascript, "./palette_ffi.mjs", "close_dialog")
pub fn close_dialog() -> Nil

@external(javascript, "./palette_ffi.mjs", "attach_shortcut")
pub fn attach_shortcut(on_toggle: fn() -> Nil) -> Nil

@external(javascript, "./palette_ffi.mjs", "shortcut_label")
pub fn shortcut_label() -> String
