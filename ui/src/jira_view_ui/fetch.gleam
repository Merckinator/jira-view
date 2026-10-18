//// Minimal fetch wrapper.
////
//// lustre_http (all published versions) pins gleam_stdlib < 1.0, which
//// clashes with the shared decoders — so the HTTP call is this ~15-line
//// fetch FFI instead. If lustre_http lands a stdlib-1.x release, switch
//// back to it.

import lustre/effect.{type Effect}

@external(javascript, "./fetch_ffi.mjs", "fetch_text")
fn fetch_text(url: String, callback: fn(Result(String, String)) -> Nil) -> Nil

/// GET a URL and map the raw response body into a message.
pub fn get(
  url: String,
  to_msg: fn(Result(String, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    fetch_text(url, fn(result) { dispatch(to_msg(result)) })
  })
}
