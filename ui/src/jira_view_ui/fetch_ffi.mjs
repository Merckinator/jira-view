import { Result$Ok, Result$Error } from "../gleam.mjs";

export async function fetch_text(url, callback) {
  try {
    const response = await fetch(url, {
      headers: { accept: "application/json" },
    });
    const body = await response.text();
    if (response.ok) {
      callback(Result$Ok(body));
    } else {
      callback(Result$Error(`${response.status}: ${body.slice(0, 300)}`));
    }
  } catch (error) {
    callback(Result$Error(`network: ${error}`));
  }
}