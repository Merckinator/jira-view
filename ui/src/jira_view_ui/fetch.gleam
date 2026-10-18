//// Minimal fetch wrapper.
////
//// lustre_http (all published versions) pins gleam_stdlib < 1.0, which
//// clashes with the shared decoders — so the HTTP call is this ~15-line
//// fetch FFI instead. If lustre_http lands a stdlib-1.x release, switch
//// back to it.

import lustre/effect.{type Effect}

@external(javascript, "./fetch_ffi.mjs", "fetch_text")
fn fetch_text(url: String, callback: fn(Result(String, String)) -> Nil) -> Nil

@external(javascript, "./fetch_ffi.mjs", "patch_json")
fn patch_json_ffi(
  url: String,
  body: String,
  callback: fn(Result(String, String)) -> Nil,
) -> Nil

/// GET a URL and map the raw response body into a message.
pub fn get(
  url: String,
  to_msg: fn(Result(String, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    fetch_text(url, fn(result) { dispatch(to_msg(result)) })
  })
}

/// PATCH a JSON document; successes carry no usable payload, so callers see
/// `Ok(Nil)` with only failures keeping the error detail.
pub fn patch_json(
  url: String,
  body: String,
  to_msg: fn(Result(Nil, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    patch_json_ffi(url, body, fn(result) {
      dispatch(to_msg(case result {
        Ok(_) -> Ok(Nil)
        Error(message) -> Error(message)
      }))
    })
  })
}
