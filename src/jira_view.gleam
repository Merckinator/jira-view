//// jira-view: a private local front-end for Jira Cloud.
////
//// Phase 0: start a Wisp/Mist server on 127.0.0.1 and prove Jira
//// credentials via the /api/me endpoint. Configuration is read per
//// request so the server always boots; see `.env.example`.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/result
import jira_view/web
import mist
import wisp
import wisp/wisp_mist

const default_port = 8787

pub fn main() {
  wisp.configure_logger()

  let port = port()
  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    web.handle_request
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start

  io.println("jira-view listening on http://127.0.0.1:" <> int.to_string(port))
  process.sleep_forever()
}

fn port() -> Int {
  case envoy.get("JIRA_VIEW_PORT") {
    Ok(value) -> result.unwrap(int.parse(value), default_port)
    Error(_) -> default_port
  }
}
