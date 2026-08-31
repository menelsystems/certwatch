//// Keeps the poller fleet in sync with google's log list. CT logs are
//// sharded by year and rotate: shards expire, new ones appear. A process
//// that runs for months must periodically re-fetch the list, start
//// pollers for new logs, and stop pollers for retired ones.

import certwatch/log_list.{type CtLog}
import certwatch/poller
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import logging

const refresh_interval_ms = 21_600_000

// 6 hours

pub type Msg {
  Refresh
}

type State {
  State(
    factory: factory.Supervisor(CtLog, Subject(poller.Msg)),
    pollers: Dict(String, Subject(poller.Msg)),
    self: Subject(Msg),
  )
}

pub fn supervised(
  factory_name: process.Name(factory.Message(CtLog, Subject(poller.Msg))),
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(factory_name) })
}

pub fn start(
  factory_name: process.Name(factory.Message(CtLog, Subject(poller.Msg))),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(10_000, fn(self) {
    process.send(self, Refresh)
    actor.initialised(State(
      factory: factory.get_by_name(factory_name),
      pollers: dict.new(),
      self:,
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Refresh -> {
      let state = refresh(state)
      process.send_after(state.self, refresh_interval_ms, Refresh)
      actor.continue(state)
    }
  }
}

fn refresh(state: State) -> State {
  case log_list.fetch() {
    Error(_) -> {
      logging.log(
        logging.Warning,
        "log list refresh failed, keeping current pollers",
      )
      state
    }
    Ok(logs) -> {
      let wanted = list.filter(logs, log_list.should_poll)
      let wanted_by_url =
        dict.from_list(list.map(wanted, fn(l) { #(l.url, l) }))

      // stop pollers whose logs are no longer pollable
      // if a poller crash-restarted, our subject is stale and
      // Stop goes nowhere until the next app restart; name pollers by
      // url if zombie pollers ever matter
      let kept =
        dict.fold(state.pollers, dict.new(), fn(kept, url, subject) {
          case dict.has_key(wanted_by_url, url) {
            True -> dict.insert(kept, url, subject)
            False -> {
              logging.log(logging.Info, "log retired: " <> url)
              process.send(subject, poller.Stop)
              kept
            }
          }
        })

      // start pollers for logs we aren't watching yet
      let pollers =
        list.fold(wanted, kept, fn(acc, log) {
          case dict.has_key(acc, log.url) {
            True -> acc
            False ->
              case factory.start_child(state.factory, log) {
                Ok(started) -> {
                  logging.log(logging.Info, "watching log: " <> log.url)
                  dict.insert(acc, log.url, started.data)
                }
                Error(_) -> {
                  logging.log(
                    logging.Warning,
                    "poller failed to start: " <> log.url,
                  )
                  acc
                }
              }
          }
        })

      logging.log(
        logging.Info,
        "log list refreshed: "
          <> int.to_string(dict.size(pollers))
          <> " pollers running",
      )
      State(..state, pollers:)
    }
  }
}
