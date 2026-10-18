//// Keyboard navigation bindings (document-level), via the JS FFI.
////
//// Attach once at init; the FFI is idempotent. `bindings` is a whitelist of
//// `"combo"` → message pairs — combos are raw `event.key` names ("j", "J",
//// "Enter", …) and anything not listed (plus any keydown inside inputs) is
//// filtered out in the FFI. See keyboard_ffi.mjs.

import gleam/list
import lustre/effect.{type Effect}

@external(javascript, "./keyboard_ffi.mjs", "attach_keys")
fn attach_keys_ffi(combos: List(String), on_key: fn(String) -> Nil) -> Nil

pub fn attach(bindings: List(#(String, msg))) -> Effect(msg) {
  effect.from(fn(dispatch) {
    attach_keys_ffi(
      list.map(bindings, fn(binding) { binding.0 }),
      fn(key) {
        case list.key_find(bindings, key) {
          Ok(msg) -> dispatch(msg)
          Error(_) -> Nil
        }
      },
    )
  })
}