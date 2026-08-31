# certwatch

Streams every certificate the public internet issues, as they're issued. Polls all usable [Certificate Transparency](https://certificate.transparency.dev/) logs from [Google's log list](https://www.gstatic.com/ct/log_list/v3/all_logs_list.json) (~21 logs) and re-serves new certs as a single SSE stream of domain names.
## Quickstart

```sh
gleam run
```

```sh
curl -N localhost:4100/events
```

```
data: {"log_url":"https://sphinx.ct.digicert.com/2026h2/","timestamp":1788136798316,"domains":["*.888boa123.com","888boa123.com"]}
```

Nothing polls until the first subscriber connects, because polling ~21 logs with no one listening is wasted bandwidth.

## Endpoints

| Path | What you get |
|---|---|
| `GET /events` | SSE stream. One event per cert: `log_url`, `timestamp` (ms), `domains` (SAN dNSNames). Certs with no domains (IP-only) are skipped. |
| `GET /metrics` | Prometheus text format: `certwatch_subscribers`, `certwatch_events_dropped_total`, and per-log `certs_streamed_total`, `fetch_failures_total`, `log_tree_size`, `log_cursor`, `log_backlog`. |

`certwatch_log_backlog > 0` sustained means a poller can't keep up with that log's issuance rate.

## How it works

One actor per CT log polls `get-sth` every 10s. When the tree grows, it drains `get-entries` until caught up (max 50 requests per tick, 256 entries per request — most logs cap responses far lower and the cursor advances by what actually arrived). Each leaf is parsed from its MerkleTreeLeaf binary, domains are extracted from the x509 SAN via Erlang's `public_key` (`src/cert_ffi.erl`), and the result fans out through a broadcaster actor to every SSE connection.

Supervision tree:

```
static_supervisor (one_for_one, gives up after 5 restarts in 30s)
├── metrics      — counters, renders /metrics
├── broadcaster  — subscriber list, drops events for any client >500 messages behind
├── factory_supervisor
│   └── poller × ~21 (transient: crashes restart, deliberate stops don't)
└── manager      — re-fetches the log list every 6h, starts/stops pollers as logs rotate
```

Two behaviors to know about:

- **Tails from now.** A fresh poller sets its cursor to the current tree size instead of backfilling — the big logs hold 2.6B+ entries.
- **Slow clients lose events, not the server.** The broadcaster checks each subscriber's mailbox depth before sending and drops past 500 queued, counted in `certwatch_events_dropped_total`.

## Configuration

| Env | Default | |
|---|---|---|
| `PORT` | `4100` | HTTP listen port |

## Docker

Prebuilt multi-arch (amd64/arm64) images are published to [ghcr.io/menelsystems/certwatch](https://github.com/menelsystems/certwatch/pkgs/container/certwatch) on every push to `main`:

```sh
docker run -p 4100:4100 ghcr.io/menelsystems/certwatch:main
```

Images ship with SLSA provenance and an SBOM attached. Verify a pull came from this repo's CI:

```sh
gh attestation verify oci://ghcr.io/menelsystems/certwatch:main --owner menelsystems
```

Or build locally:

```sh
docker build -t certwatch .
docker run -p 4100:4100 certwatch
```

Two-stage build via `gleam export erlang-shipment`, ~192MB image. The entrypoint is invoked through `/bin/sh` because Gleam 1.18's generated `entrypoint.sh` has no shebang line.

## Development

```sh
gleam test    # includes a real precert fixture from elephant2027h1
gleam format src test
```
