//// Fetches and decodes the google CT log list (all_logs_list.json).

import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

const log_list_url = "https://www.gstatic.com/ct/log_list/v3/all_logs_list.json"

/// Lifecycle state of a CT log, per the v3 log list schema.
/// The json encodes this as an object with exactly one key, e.g.
/// {"state": {"usable": {"timestamp": "..."}}}
pub type LogState {
  Pending
  Qualified
  Usable
  Readonly
  Retired
  Rejected
}

pub type CtLog {
  CtLog(description: String, url: String, state: Option(LogState))
}

pub type Error {
  BadUrl
  HttpError(httpc.HttpError)
  JsonError(json.DecodeError)
}

/// Decide whether we should poll this log for new certificates.
pub fn should_poll(log: CtLog) -> Bool {
  case log.state {
    Some(Usable) -> True
    _ -> False
  }
}

pub fn fetch() -> Result(List(CtLog), Error) {
  let assert Ok(req) = request.to(log_list_url)
  use resp <- result.try(result.map_error(httpc.send(req), HttpError))
  parse(resp.body)
}

pub fn parse(body: String) -> Result(List(CtLog), Error) {
  json.parse(from: body, using: list_decoder())
  |> result.map_error(JsonError)
}

fn state_decoder() -> decode.Decoder(LogState) {
  decode.one_of(decode.at(["usable"], decode.success(Usable)), [
    decode.at(["qualified"], decode.success(Qualified)),
    decode.at(["pending"], decode.success(Pending)),
    decode.at(["readonly"], decode.success(Readonly)),
    decode.at(["retired"], decode.success(Retired)),
    decode.at(["rejected"], decode.success(Rejected)),
  ])
}

fn log_decoder() -> decode.Decoder(CtLog) {
  use description <- decode.field("description", decode.string)
  use url <- decode.field("url", decode.string)
  use state <- decode.optional_field(
    "state",
    None,
    decode.optional(state_decoder()),
  )
  decode.success(CtLog(description:, url:, state:))
}

fn list_decoder() -> decode.Decoder(List(CtLog)) {
  use per_operator <- decode.field(
    "operators",
    decode.list({
      use logs <- decode.field("logs", decode.list(log_decoder()))
      decode.success(logs)
    }),
  )
  decode.success(list.flatten(per_operator))
}
