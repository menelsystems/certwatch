//// The http layer: /events streams certs to any client via
//// server-sent events. Each connection is its own actor, subscribed
//// to the broadcaster for as long as the socket stays open.

import certwatch/broadcaster
import certwatch/metrics
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/otp/actor
import gleam/string_tree
import mist.{type Connection, type ResponseData}

pub fn handler(
  req: Request(Connection),
  bcast: Subject(broadcaster.Msg),
  metrics_subject: Subject(metrics.Msg),
) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["metrics"] -> {
      let subscribers = process.call(bcast, 100, broadcaster.SubscriberCount)
      let body =
        process.call(metrics_subject, 100, metrics.Snapshot(subscribers, _))
      response.new(200)
      |> response.set_header(
        "content-type",
        "text/plain; version=0.0.4; charset=utf-8",
      )
      |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
    }
    ["events"] ->
      mist.server_sent_events(
        req,
        response.new(200),
        init: fn(self) {
          process.send(bcast, broadcaster.Subscribe(self))
          Nil
        },
        loop: fn(state, event, conn) {
          case mist.send_event(conn, to_sse(event)) {
            Ok(_) -> actor.continue(state)
            Error(_) -> actor.stop()
          }
        },
      )
    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn to_sse(event: broadcaster.Event) -> mist.SSEEvent {
  let broadcaster.NewCert(log_url, entry) = event
  json.object([
    #("log_url", json.string(log_url)),
    #("timestamp", json.int(entry.timestamp)),
    #("domains", json.array(entry.domains, json.string)),
  ])
  |> json.to_string
  |> string_tree.from_string
  |> mist.event
}
