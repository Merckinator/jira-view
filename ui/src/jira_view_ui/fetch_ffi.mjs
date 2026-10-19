// Minimal fetch wrapper FFI. lustre_http (all published versions) pins
// gleam_stdlib < 1.0, which clashes with the shared decoders — so these
// ~30 lines replace it. If lustre_http lands a stdlib-1.x release, switch
// back to it.
import { Result$Ok, Result$Error } from "../gleam.mjs";

async function json_request(method, url, body, callback) {
  try {
    const response = await fetch(url, {
      method,
      headers: {
        accept: "application/json",
        ...(body !== undefined ? { "content-type": "application/json" } : {}),
      },
      ...(body !== undefined ? { body } : {}),
    });
    const text = await response.text();
    if (response.ok) {
      callback(Result$Ok(text));
    } else {
      callback(Result$Error(`${response.status}: ${text.slice(0, 300)}`));
    }
  } catch (error) {
    callback(Result$Error(`network: ${error}`));
  }
}

export const fetch_text = (url, callback) =>
  json_request("GET", url, undefined, callback);

export const patch_json = (url, body, callback) =>
  json_request("PATCH", url, body, callback);

export const post_json = (url, body, callback) =>
  json_request("POST", url, body, callback);

export const put_json = (url, body, callback) =>
  json_request("PUT", url, body, callback);

export const delete_json = (url, callback) =>
  json_request("DELETE", url, undefined, callback);