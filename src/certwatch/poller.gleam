//// One poller actor per CT log. Wakes up on a timer, decides whether
//// anyone is listening, and if so drains any new entries from the log,
//// publishing each certificate's domains to the broadcaster.

import certwatch/broadcaster
import certwatch/leaf
import certwatch/log_list.{type CtLog}
import certwatch/metrics
import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import logging

const poll_interval_ms = 10_000

/// Never ask a log for more than this many entries in one request
/// (most cap their responses far lower anyway).
pub const max_batch = 256

/// Cap on get-entries requests per tick. Logs that cap responses hard
/// (google returns ~32 entries) need many requests per tick to keep up
/// with their growth; this bounds a tick's worst-case duration instead.
const max_batches_per_tick = 50

pub type Msg {
  Tick
  Stop
}

type State {
  State(
    log: CtLog,
    broadcaster: Subject(broadcaster.Msg),
    metrics: Subject(metrics.Msg),
    self: Subject(Msg),
    last_size: Int,
  )
}

pub fn start(
  log: CtLog,
  bcast: Subject(broadcaster.Msg),
  metrics_subject: Subject(metrics.Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    // kick off the first tick; every later tick reschedules itself
    process.send(self, Tick)
    actor.initialised(State(
      log:,
      broadcaster: bcast,
      metrics: metrics_subject,
      self:,
      last_size: 0,
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Stop -> {
      logging.log(logging.Info, "poller stopped: " <> state.log.url)
      actor.stop()
    }
    Tick -> {
      let subscribers =
        process.call(state.broadcaster, 100, broadcaster.SubscriberCount)
      let state = case subscribers > 0 {
        True -> poll(state)
        False -> state
      }
      process.send_after(state.self, poll_interval_ms, Tick)
      actor.continue(state)
    }
  }
}

/// One poll cycle: read the tree size, drain new entries until caught up
/// (or the per-tick budget runs out), return the state with our cursor
/// advanced.
fn poll(state: State) -> State {
  case fetch_tree_size(state.log) {
    Error(_) -> {
      logging.log(logging.Warning, "get-sth failed: " <> state.log.url)
      process.send(state.metrics, metrics.FetchFailed(state.log.url))
      state
    }
    Ok(new_size) -> {
      let cursor = drain(state, state.last_size, new_size, max_batches_per_tick)
      process.send(
        state.metrics,
        metrics.Progress(state.log.url, cursor, new_size),
      )
      State(..state, last_size: cursor)
    }
  }
}

fn drain(state: State, cursor: Int, target: Int, budget: Int) -> Int {
  use <- bool.guard(budget <= 0, cursor)
  case fetch_range(cursor, target) {
    // nothing to fetch: first run tails from now, otherwise we're caught up
    option.None -> target
    option.Some(#(start, end)) ->
      case fetch_entries(state.log, start, end) {
        Error(_) -> {
          logging.log(logging.Warning, "get-entries failed: " <> state.log.url)
          process.send(state.metrics, metrics.FetchFailed(state.log.url))
          cursor
        }
        Ok([]) -> cursor
        Ok(leaves) -> {
          let streamed =
            list.fold(leaves, 0, fn(acc, leaf_b64) {
              case leaf.parse(leaf_b64) {
                // no dns names (ip-only cert, or undecodable) -> skip:
                // subscribers only care about domains
                Ok(leaf.CertEntry(domains: [], ..)) -> acc
                Ok(entry) -> {
                  process.send(
                    state.broadcaster,
                    broadcaster.Publish(broadcaster.NewCert(
                      state.log.url,
                      entry,
                    )),
                  )
                  acc + 1
                }
                Error(_) -> acc
              }
            })
          process.send(state.metrics, metrics.Streamed(state.log.url, streamed))
          // logs return fewer entries than asked: advance by what we GOT
          drain(state, start + list.length(leaves), target, budget - 1)
        }
      }
  }
}

/// Given where our cursor is and how big the tree is now, decide which
/// entry range to fetch: None for nothing, Some(#(start, end)) inclusive.
pub fn fetch_range(last_size: Int, new_size: Int) -> Option(#(Int, Int)) {
  case last_size {
    // first run: don't backfill billions of entries, tail from now
    0 -> option.None
    _ if new_size <= last_size -> option.None
    _ -> option.Some(#(last_size, int.min(new_size, last_size + max_batch) - 1))
  }
}

/// Hit <log url>ct/v1/get-sth and pull out the current tree size.
pub fn fetch_tree_size(log: CtLog) -> Result(Int, log_list.Error) {
  // a bad url from the log list must not crash-loop the actor
  use req <- result.try(result.replace_error(
    request.to(log.url <> "ct/v1/get-sth"),
    log_list.BadUrl,
  ))
  use resp <- result.try(result.map_error(httpc.send(req), log_list.HttpError))
  json.parse(from: resp.body, using: {
    use size <- decode.field("tree_size", decode.int)
    decode.success(size)
  })
  |> result.map_error(log_list.JsonError)
}

/// Hit <log url>ct/v1/get-entries and return the base64 leaf_input blobs.
/// start and end are inclusive indices; the log may return fewer entries
/// than asked for.
pub fn fetch_entries(
  log: CtLog,
  start: Int,
  end: Int,
) -> Result(List(String), log_list.Error) {
  use req <- result.try(result.replace_error(
    request.to(
      log.url
      <> "ct/v1/get-entries?start="
      <> int.to_string(start)
      <> "&end="
      <> int.to_string(end),
    ),
    log_list.BadUrl,
  ))
  use resp <- result.try(result.map_error(httpc.send(req), log_list.HttpError))
  json.parse(from: resp.body, using: {
    use entries <- decode.field(
      "entries",
      decode.list({
        use leaf <- decode.field("leaf_input", decode.string)
        decode.success(leaf)
      }),
    )
    decode.success(entries)
  })
  |> result.map_error(log_list.JsonError)
}
