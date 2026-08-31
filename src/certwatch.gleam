import certwatch/broadcaster
import certwatch/manager
import certwatch/metrics
import certwatch/poller
import certwatch/sse
import envoy
import gleam/erlang/process
import gleam/int
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import logging
import mist

pub fn main() -> Nil {
  logging.configure()
  configure_httpc()

  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(4100)

  let metrics_name = process.new_name("metrics")
  let bcast_name = process.new_name("broadcaster")
  let factory_name = process.new_name("poller_factory")
  let metrics_subject = process.named_subject(metrics_name)
  let bcast = process.named_subject(bcast_name)

  // pollers are started and stopped at runtime by the manager as the
  // log list changes, so they live under a factory supervisor.
  // Transient: crashes restart, deliberate stops don't.
  let pollers =
    factory.worker_child(fn(log) { poller.start(log, bcast, metrics_subject) })
    |> factory.restart_strategy(supervision.Transient)
    |> factory.named(factory_name)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    // give up rather than crash-loop: 5 restarts in 30s is a lost cause
    |> supervisor.restart_tolerance(5, 30)
    |> supervisor.add(metrics.supervised(metrics_name))
    |> supervisor.add(broadcaster.supervised(bcast_name, metrics_subject))
    |> supervisor.add(factory.supervised(pollers))
    |> supervisor.add(manager.supervised(factory_name))
    |> supervisor.start

  let assert Ok(_) =
    mist.new(sse.handler(_, bcast, metrics_subject))
    // all interfaces, not just loopback: required inside a container
    |> mist.bind("0.0.0.0")
    |> mist.port(port)
    |> mist.start

  logging.log(
    logging.Info,
    "streaming at http://localhost:" <> int.to_string(port) <> "/events",
  )
  process.sleep_forever()
}

@external(erlang, "httpc_ffi", "configure")
fn configure_httpc() -> Nil
