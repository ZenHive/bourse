# WebSocket heartbeat liveness and control-frame isolation

## What Bourse now does

Bourse treats heartbeat requests/replies as transport control and exposes
connection-scoped observations through `Bourse.WS.health/1`. It reuses
`zen_websocket` 0.9.0's timer and `get_heartbeat_health/1` rather than a
second heartbeat state machine.

- Default handlers classify inbound frames with `Bourse.WS.ControlFrame`.
  Market data stays `{:websocket_message, _}`. Heartbeat replies, JSON-RPC
  results/errors, and ping/pong keepalives arrive as
  `{:websocket_unmatched_response, _}`. Adapter routing classifies the same
  frames as `{:system, _}` so they are not broadcast as `:raw` market data.
- `Bourse.WS.Heartbeat.validate/1` accepts only `:disabled`, `:deribit`, and
  `:ping_pong`. `:ping` and `:custom` fail at `connect/3` with
  `{:error, {:unsupported_heartbeat, type}}` instead of a silent no-op timer.
- Spec merge maps `native_frame` to `:ping_pong` except Deribit (`:deribit`).
  JSON/string application pings (Bybit, OKX, Hyperliquid, Alpaca, Lighter)
  stay `:disabled` because 0.9.0 cannot send those payloads.
- `ConnectionOwner.snapshot/2` is a non-destructive read.
  `Bourse.WS.health/1` reports primary and routed sockets from that snapshot.
  Market-data silence is not a miss.

## Remaining dependency gap

The locked `zen_websocket` 0.9.0 still does not disconnect on missed heartbeats.
`tick_heartbeat/2` reschedules unconditionally. Deribit `public/test` is sent
without an id and `last_heartbeat_at` is set on send, not on a correlated
reply. Bourse therefore reports the dependency's observations as-is and does
not invent a bounded-failure outcome.

The separately reviewable upstream work is
[ZenHive/zen_websocket#19](https://github.com/ZenHive/zen_websocket/issues/19).
No newer Hex release existed on 2026-09-15 (`0.9.0` was latest).

## Observed on 2026-09-15

Executed against the locked dependency and real anonymous testnet sockets
(`scripts/probe_ws_heartbeat.exs`):

- Deribit accepted `ticker.BTC-PERPETUAL.100ms`, delivered a matching instrument
  with a positive numeric mark price, and rejected the unauthenticated `.raw`
  subscription with error `13778`.
- Deribit's automatic `public/test` response contained `result.version =
  "1.2.26"` and, before isolation, arrived as `{:websocket_message, response}`.
- Binance answered a native client ping using `:ping_pong` without any
  subscription. Health recorded a pong.
- Binance `:ping` was accepted by the dependency but a tick left timestamp
  nil, active list empty, failures at zero. Bourse now refuses that type.
- Suspending Gun while leaving Client timers running produced `failure_count: 3`
  and left connection state `:connected`. Resuming Gun restored pongs. This is
  transport resumption, **not** bounded disconnect/reconnect recovery.

The probe uses no recorded or fake provider responses. It suspends only the
Gun process of its own socket and resumes/closes it in `after` blocks.

## Exact remaining gaps in zen_websocket 0.9.0

Paths below are relative to `deps/zen_websocket/lib/zen_websocket/`:

| Source | Missing primitive |
| --- | --- |
| `heartbeat_manager.ex`, `send_heartbeat/1` | Only `:deribit` and `:ping_pong` send anything. |
| `helpers/deribit.ex`, `send_heartbeat/1` | Sends `public/test` without an ID; timestamps the send. |
| `client/frames.ex`, `route_data_frame/2` | No-ID results fall through to the application handler. |
| `client/callbacks.ex`, `tick_heartbeat/2` | No miss threshold or disconnect. |
| `heartbeat_manager.ex`, `get_health/1` | No pending identity, deadline, or generation. |

## Provider authority

Consulted the provider manifests under `priv/venues/{binance,deribit}/authority/`:

- [Binance stream contract](https://raw.githubusercontent.com/binance/binance-spot-api-docs/b483413fcdf4da783cd3fcaad6fab7200a93297f/web-socket-streams.md):
  server ping every 20 seconds, payload-matching pong required within one minute.
- [Deribit OpenAPI](https://docs.deribit.com/specifications/deribit_openapi.json)
  and [connection management](https://docs.deribit.com/articles/connection-management-best-practices.md):
  `public/test` returns the server version. `public/set_heartbeat` is WebSocket
  only.

REST observations: `GET /api/v2/public/test` returned the version;
`GET /api/v2/public/get_order_book?instrument_name=TASK696_INVALID` returned
`-32602` with `reason=instrument not found`.

## Reproduction

```sh
MIX_ENV=test mix run scripts/probe_ws_heartbeat.exs
mix test.json test/live/ws/heartbeat_contract_live_test.exs --quiet --output /tmp/task696-live.json
mix test.json test/bourse/ws --quiet --cover --output /tmp/task696-ws-cover.json
mix bourse.verify_rest_read_contracts --venue deribit
mix bourse.verify_rest_read_contracts --venue binance
mix check.dispatch
```
