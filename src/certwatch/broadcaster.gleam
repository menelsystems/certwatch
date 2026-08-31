//// Fan-out hub: pollers publish events, sse subscribers receive them.

import certwatch/leaf
import certwatch/metrics
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision

/// A subscriber whose mailbox backs up past this is skipped rather than
/// allowed to eat the vm's memory. ~1 tick of firehose at current volume.
const max_subscriber_queue = 500

pub type Event {
  NewCert(log_url: String, entry: leaf.CertEntry)
}

pub type Msg {
  Subscribe(Subject(Event))
  Unsubscribe(Subject(Event))
  Publish(Event)
  SubscriberCount(reply: Subject(Int))
}

type State {
  State(subs: List(Subject(Event)), metrics: Subject(metrics.Msg))
}

/// Child spec so the supervisor owns the broadcaster's lifecycle. It runs
/// under a name: everyone talks to it via process.named_subject, which
/// stays valid across restarts (a raw Subject would die with the process).
pub fn supervised(
  name: process.Name(Msg),
  metrics_subject: Subject(metrics.Msg),
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, metrics_subject) })
}

pub fn start(
  name: process.Name(Msg),
  metrics_subject: Subject(metrics.Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new(State(subs: [], metrics: metrics_subject))
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Subscribe(sub) -> actor.continue(State(..state, subs: [sub, ..state.subs]))
    Unsubscribe(sub) ->
      actor.continue(
        State(..state, subs: list.filter(state.subs, fn(s) { s != sub })),
      )
    Publish(event) -> {
      let subs = alive(state.subs)
      list.each(subs, fn(sub) { deliver(state, sub, event) })
      actor.continue(State(..state, subs:))
    }
    SubscriberCount(reply) -> {
      let subs = alive(state.subs)
      process.send(reply, list.length(subs))
      actor.continue(State(..state, subs:))
    }
  }
}

/// Backpressure: a slow client's sse actor can't drain its mailbox as
/// fast as certs arrive, so drop events for it instead of queueing
/// unboundedly. Dropped events are counted, not silently lost.
fn deliver(state: State, sub: Subject(Event), event: Event) -> Nil {
  case process.subject_owner(sub) {
    Ok(pid) ->
      case queue_len(pid) > max_subscriber_queue {
        True -> process.send(state.metrics, metrics.Dropped(1))
        False -> process.send(sub, event)
      }
    Error(_) -> Nil
  }
}

// sse actors die on disconnect without unsubscribing, so prune
// dead ones on every touch; process monitors if sub counts get large
fn alive(subs: List(Subject(Event))) -> List(Subject(Event)) {
  list.filter(subs, fn(sub) {
    case process.subject_owner(sub) {
      Ok(pid) -> process.is_alive(pid)
      Error(_) -> False
    }
  })
}

@external(erlang, "process_ffi", "queue_len")
fn queue_len(pid: Pid) -> Int
