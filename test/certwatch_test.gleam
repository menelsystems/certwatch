import certwatch/leaf
import certwatch/poller
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

/// Entry 0 of the elephant2027h1 CT log: a real precert MerkleTreeLeaf,
/// locking in the binary layout parsing and the erlang x509 ffi.
const elephant_precert_leaf = "AAAAAAGVRzLLtgAB43aJADBzoMZJzGVt6UbAMXTSXFZv48OAW4RvUjaUN5gAAtswggLXoAMCAQICBwYvHh3+/qQwDQYJKoZIhvcNAQELBQAwfzELMAkGA1UEBhMCR0IxDzANBgNVBAgMBkxvbmRvbjEXMBUGA1UECgwOR29vZ2xlIFVLIEx0ZC4xITAfBgNVBAsMGENlcnRpZmljYXRlIFRyYW5zcGFyZW5jeTEjMCEGA1UEAwwaTWVyZ2UgRGVsYXkgSW50ZXJtZWRpYXRlIDEwHhcNMjUwMjI3MTEzNzM5WhcNMjcwNTE1MDkyMzE4WjBjMQswCQYDVQQGEwJHQjEPMA0GA1UEBwwGTG9uZG9uMSgwJgYDVQQKDB9Hb29nbGUgQ2VydGlmaWNhdGUgVHJhbnNwYXJlbmN5MRkwFwYDVQQFExAxNzQwNjU2MjU5MDM4ODg0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAufm8G9UW2J+yAp03hZyJVY7Y7Qabnbnt7ILIgULFVFuDcI6OuKtNBA7gUn23UYmoNQVu8Xj5oqKpaKm58JOvAvkSMDWMN1suj1v3bw1a07yVItHU2YUd8IUqPP9305MsfyLXFhtXcDLl+8sSt+rRDqPk71Ct4kOhU5V+UfcVsTfTAOYeA052h7q/OHJq5gFF1s4//BtdfvMyBo0AlnKizjSA2sQgXMYrFlK3W/Fu+0YTcN8ci9OQpPo521lVEtBv9HSI0eXNDztUsAs4MoBuzsviYzCM4tNxCJlRwjj/KN+zOQFMGsj9iwclnwX9s0pko3kwMG6K/2RrDnROYnwO8wIDAQABo4GLMIGIMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCMGA1UdEQQcMBqCGGZsb3dlcnMtdG8tdGhlLXdvcmxkLmNvbTAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaAFOk8BOGAL8KEEy0mcJ7y/RrPqv7GMB0GA1UdDgQWBBTUu62KVH9z4UDCEx1kT4PaxrM83gAA"

pub fn parse_precert_leaf_test() {
  leaf.parse(elephant_precert_leaf)
  |> should.equal(
    Ok(
      leaf.CertEntry(timestamp: 1_740_656_266_166, domains: [
        "flowers-to-the-world.com",
      ]),
    ),
  )
}

pub fn parse_garbage_test() {
  leaf.parse("not base64!")
  |> should.equal(Error(Nil))
  leaf.parse("aGVsbG8=")
  |> should.equal(Error(Nil))
}

pub fn fetch_range_first_run_tails_test() {
  poller.fetch_range(0, 2_000_000_000)
  |> should.equal(None)
}

pub fn fetch_range_caught_up_test() {
  poller.fetch_range(500, 500)
  |> should.equal(None)
  // a log reporting a smaller tree than our cursor: fetch nothing
  poller.fetch_range(500, 400)
  |> should.equal(None)
}

pub fn fetch_range_growth_test() {
  poller.fetch_range(500, 600)
  |> should.equal(Some(#(500, 599)))
}

pub fn fetch_range_caps_batch_test() {
  poller.fetch_range(500, 1_000_000)
  |> should.equal(Some(#(500, 500 + poller.max_batch - 1)))
}
