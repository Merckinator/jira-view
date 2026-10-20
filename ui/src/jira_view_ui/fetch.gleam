//// Minimal fetch wrapper (lustre_http is unusable with stdlib 1.x — see
//// fetch_ffi.mjs for the rationale; these FFI calls replace it).
////
//// Verbs: GET (any payload), PATCH/POST/PUT (JSON body, either mapped to
//// `Ok(Nil)` or to the raw response body when the endpoint returns a
//// created record), DELETE.

import lustre/effect.{type Effect}

@external(javascript, "./fetch_ffi.mjs", "fetch_text")
fn fetch_text(url: String, callback: fn(Result(String, String)) -> Nil) -> Nil

@external(javascript, "./fetch_ffi.mjs", "patch_json")
fn patch_json_ffi(
  url: String,
  body: String,
  callback: fn(Result(String, String)) -> Nil,
) -> Nil

@external(javascript, "./fetch_ffi.mjs", "post_json")
fn post_json_ffi(
  url: String,
  body: String,
  callback: fn(Result(String, String)) -> Nil,
) -> Nil

@external(javascript, "./fetch_ffi.mjs", "put_json")
fn put_json_ffi(
  url: String,
  body: String,
  callback: fn(Result(String, String)) -> Nil,
) -> Nil

@external(javascript, "./fetch_ffi.mjs", "delete_json")
fn delete_json_ffi(
  url: String,
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

/// PATCH a JSON document; successes carry no usable payload.
pub fn patch_json(
  url: String,
  body: String,
  to_msg: fn(Result(Nil, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    patch_json_ffi(url, body, fn(result) { dispatch(to_msg(as_nil(result))) })
  })
}

/// POST a JSON document; successes carry no usable payload.
pub fn post_json(
  url: String,
  body: String,
  to_msg: fn(Result(Nil, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    post_json_ffi(url, body, fn(result) { dispatch(to_msg(as_nil(result))) })
  })
}

/// POST a JSON document and map the raw response body into a message (the
/// write endpoints return the created record pruned).
pub fn post_json_raw(
  url: String,
  body: String,
  to_msg: fn(Result(String, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    post_json_ffi(url, body, fn(result) { dispatch(to_msg(result)) })
  })
}

/// PUT a JSON document; successes carry no usable payload.
pub fn put_json(
  url: String,
  body: String,
  to_msg: fn(Result(Nil, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    put_json_ffi(url, body, fn(result) { dispatch(to_msg(as_nil(result))) })
  })
}

/// PUT a JSON document and map the raw response body into a message.
pub fn put_json_raw(
  url: String,
  body: String,
  to_msg: fn(Result(String, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    put_json_ffi(url, body, fn(result) { dispatch(to_msg(result)) })
  })
}

/// DELETE a URL; successes carry no usable payload.
pub fn delete_json(
  url: String,
  to_msg: fn(Result(Nil, String)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    delete_json_ffi(url, fn(result) { dispatch(to_msg(as_nil(result))) })
  })
}

fn as_nil(result: Result(String, String)) -> Result(Nil, String) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(message) -> Error(message)
  }
}
