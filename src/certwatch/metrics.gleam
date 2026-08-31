//// Counts everything interesting. Pollers and the broadcaster report in;
//// the /metrics endpoint asks for a Snapshot.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string

pub type LogStats {
  LogStats(cursor: Int, tree_size: Int, streamed: Int, failures: Int)
}

pub type Msg {
  Streamed(log_url: String, count: Int)
  Progress(log_url: String, cursor: Int, tree_size: Int)
  FetchFailed(log_url: String)
  Dropped(count: Int)
  /// Replies with the full prometheus text exposition. Subscriber count
  /// lives in the broadcaster, so the caller passes it in.
  Snapshot(subscribers: Int, reply: Subject(String))
}

type State {
  State(dropped: Int, logs: Dict(String, LogStats))
}

pub fn supervised(
  name: process.Name(Msg),
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name) })
}

pub fn start(
  name: process.Name(Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new(State(dropped: 0, logs: dict.new()))
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Streamed(url, count) -> {
      let stats = stats(state, url)
      update(state, url, LogStats(..stats, streamed: stats.streamed + count))
    }
    Progress(url, cursor, tree_size) ->
      update(state, url, LogStats(..stats(state, url), cursor:, tree_size:))
    FetchFailed(url) -> {
      let stats = stats(state, url)
      update(state, url, LogStats(..stats, failures: stats.failures + 1))
    }
    Dropped(count) ->
      actor.continue(State(..state, dropped: state.dropped + count))
    Snapshot(subscribers, reply) -> {
      process.send(reply, to_prometheus(state, subscribers))
      actor.continue(state)
    }
  }
}

fn stats(state: State, url: String) -> LogStats {
  dict.get(state.logs, url)
  |> result.unwrap(LogStats(cursor: 0, tree_size: 0, streamed: 0, failures: 0))
}

fn update(
  state: State,
  url: String,
  stats: LogStats,
) -> actor.Next(State, Msg) {
  actor.continue(State(..state, logs: dict.insert(state.logs, url, stats)))
}

/// Prometheus text exposition format, version 0.0.4.
fn to_prometheus(state: State, subscribers: Int) -> String {
  let per_log = fn(get: fn(LogStats) -> Int) {
    dict.to_list(state.logs)
    |> list.map(fn(pair) {
      let #(url, s) = pair
      "{log=\"" <> url <> "\"} " <> int.to_string(get(s))
    })
  }
  [
    gauge("certwatch_subscribers", [" " <> int.to_string(subscribers)]),
    counter("certwatch_events_dropped_total", [
      " " <> int.to_string(state.dropped),
    ]),
    counter("certwatch_certs_streamed_total", per_log(fn(s) { s.streamed })),
    counter("certwatch_fetch_failures_total", per_log(fn(s) { s.failures })),
    gauge("certwatch_log_tree_size", per_log(fn(s) { s.tree_size })),
    gauge("certwatch_log_cursor", per_log(fn(s) { s.cursor })),
    gauge("certwatch_log_backlog", per_log(fn(s) { s.tree_size - s.cursor })),
  ]
  |> string.join("")
}

fn counter(name: String, samples: List(String)) -> String {
  family(name, "counter", samples)
}

fn gauge(name: String, samples: List(String)) -> String {
  family(name, "gauge", samples)
}

fn family(name: String, kind: String, samples: List(String)) -> String {
  "# TYPE "
  <> name
  <> " "
  <> kind
  <> "\n"
  <> string.join(list.map(samples, fn(s) { name <> s }), "\n")
  <> "\n"
}
