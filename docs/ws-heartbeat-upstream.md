# Task 696: heartbeat lifecycle blocked on zen_websocket

## Outcome

The locked `zen_websocket` 0.9.0 cannot supply the requested Bourse liveness
contract. No production behavior or dependency pin has been changed. The added
live contracts establish provider prerequisites; their passing is **not** an
acceptance verdict for task 696.

The separately reviewable upstream work is tracked in
[ZenHive/zen_websocket#19](https://github.com/ZenHive/zen_websocket/issues/19).
This document and `scripts/probe_ws_heartbeat.exs` provide the detailed handoff.
No upstream implementation, release, or reviewer approval is claimed.
The [Hex package API](https://hex.pm/api/packages/zen_websocket) listed 0.9.0 as
the newest published version when checked on 2026-09-15; there is no newer Hex
release to adopt for this change.

## Observed on 2026-09-15

Executed against the locked dependency and real anonymous testnet sockets:

- Deribit accepted `ticker.BTC-PERPETUAL.100ms`, delivered a matching instrument
  with a positive numeric mark price, and rejected the unauthenticated `.raw`
  subscription with error `13778`.
- Deribit's automatic `public/test` response contained `result.version =
  "1.2.26"` and arrived as `{:websocket_message, response}`. Its heartbeat health
  had a timestamp but an empty `active_heartbeats` list and zero failures.
- Binance answered a native client ping using the supported dependency type
  `:ping_pong`, without any subscription or market data. Health recorded a pong.
- Binance's authored `:ping` configuration was accepted, but a heartbeat tick
  left its timestamp nil, active heartbeat list empty, and failures at zero.
- Suspending that socket's actual Gun process while leaving the Client process
  and its timers running produced `failure_count: 3`, retained the old successful
  timestamp, and left connection state `:connected`. Resuming Gun restored pong
  evidence and reset the counter. This was transport resumption, **not** bounded
  disconnect/reconnect recovery.

The finite fault probe demonstrates three misses without disconnect. The absence
of any bound is additionally established by the callback source below, not by
claiming a finite wait proves indefinite behavior. The probe uses no recorded or
fake provider responses. It suspends only the Gun process of its own socket and
resumes/closes it in `after` blocks.

## Exact dependency gaps

Paths below are relative to `deps/zen_websocket/lib/zen_websocket/` at 0.9.0:

| Source | Missing primitive |
| --- | --- |
| `heartbeat_manager.ex`, `send_heartbeat/1` | Only `:deribit` and `:ping_pong` send anything. Other types silently return unchanged state. Payload-bearing `:ping` configs do not send their payloads. |
| `helpers/deribit.ex`, `send_heartbeat/1` | Sends `public/test` without an ID and sets `last_heartbeat_at` on send, without observing a response. |
| `client/frames.ex`, `route_data_frame/2` | The no-ID result falls through to the application handler. It cannot be correlated to a heartbeat request. Filtering every version-shaped result in Bourse would guess request ownership. |
| `client/callbacks.ex`, `tick_heartbeat/2` | Sends and reschedules unconditionally. No miss threshold or response deadline enters the existing transport failure/retry lifecycle. |
| `heartbeat_manager.ex`, `get_health/1` | Does not expose pending request identity/deadline or connection generation. Disconnect cleanup resets failures, while old success observations are not scoped to a new generation. |
| `client/frames.ex`, `track_heartbeat_frame/2` | Records matched native pongs only; server-originated ping traffic provides no health observation. |

Bourse's `lib/bourse/ws/spec_config.ex` assigns `:ping` to Alpaca, Binance,
Binance USD-M, Binance COIN-M, Bybit, OKX, Derive, Hyperliquid, and Lighter.
Spec merging preserves that type even for JSON/string payloads. Deribit gets
`:deribit`. These are code observations, not verification of those nine provider
contracts. `lib/bourse/ws.ex` forwards the configuration unchanged.

`Bourse.WS.get_state/1` reads only the primary client. `ConnectionOwner` holds
routed clients but has no non-destructive snapshot API; `take/2` closes ownership
and must not be used as a health query.

## Provider authority

Consulted the provider manifests under `priv/venues/{binance,deribit}/authority/`.
The referenced documents were fetched during this investigation:

- [Binance stream contract at the manifest's pinned revision](https://raw.githubusercontent.com/binance/binance-spot-api-docs/b483413fcdf4da783cd3fcaad6fab7200a93297f/web-socket-streams.md):
  server ping every 20 seconds, payload-matching pong required within one minute;
  subscription acceptance uses a correlated null result. Client ping/pong success
  was observed live separately. The authored 180-second value is not evidence
  of the current server heartbeat cadence.
- [Deribit OpenAPI](https://docs.deribit.com/specifications/deribit_openapi.json)
  and [connection management](https://docs.deribit.com/articles/connection-management-best-practices.md):
  `public/test` returns the server version. `public/set_heartbeat` is WebSocket
  only, accepts an interval of at least 10 seconds, and enables server heartbeat
  and test-request notifications; test requests require a `public/test` response.
  The one-second probe interval drives client-initiated tests; it is not a
  `public/set_heartbeat` interval.

REST observations also succeeded: `GET /api/v2/public/test` returned the version;
`GET /api/v2/public/get_order_book?instrument_name=TASK696_INVALID` returned
`-32602` with `param=instrument_name`, `reason=instrument not found`.

## Upstream change contract

[Issue 19](https://github.com/ZenHive/zen_websocket/issues/19) specifies request
correlation/control isolation, explicit configuration validation, generation-scoped
pending/success/failure observations, and bounded expiry through the existing
transport retry lifecycle. Its validation requires real-provider prerequisites,
transport faults, reconnection/restoration, and late/duplicate/mismatched replies.
Sending or market-data activity must not substitute for heartbeat evidence.

The Bourse integration then needs a non-destructive owner snapshot and a public
health API keyed by actual socket identity/role, covering primary and routed
sockets and closed/unavailable owners. It must delegate observations and failure
decisions to the reviewed dependency primitive. Release/pin that primitive and
prove each configured venue dialect against its own authority and live transport.

## Reviewer reproduction and checks

From this worktree, with the repository's provider-live credentials configured:

```sh
MIX_ENV=test mix run scripts/probe_ws_heartbeat.exs
mix test.json test/live/ws/heartbeat_contract_live_test.exs --quiet --output /tmp/task696-live.json
mix test.json test/bourse/ws/spec_config_test.exs test/bourse/ws/facade_test.exs test/bourse/ws/connection_owner_test.exs --cover --quiet --output /tmp/task696-coverage.json
mix bourse.verify_rest_read_contracts --venue deribit --output /tmp/task696-rest-deribit.json
mix bourse.verify_rest_read_contracts --venue binance --output /tmp/task696-rest-binance.json
mix check.dispatch
```

The diagnostic expects the observed 0.9.0 leak and prints current health. A zero
exit means the reproduction completed, not that heartbeat isolation/liveness
passes. The live test file asserts supported provider prerequisites without
asserting that the leak or missing deadline is desirable behavior. Missing
credentials and unreachable providers remain failures.

Pre-mutation focused coverage: 34 tests passed; `Bourse.WS` 72.17%,
`Bourse.WS.SpecConfig` 84.62%, `Bourse.WS.ConnectionOwner` 80.56%.
The new provider-live contracts: 2 tests passed, zero skips/exclusions.
No existing runtime module was mutated. The WS figure is below tier and must be
raised before changing that module; these focused numbers are not a full-suite
coverage claim. Check outcomes are recorded in the harness implementer report;
an independent reviewer must run the commands and supply the acceptance verdict.

### Implementer check results

| Check | Result |
| --- | --- |
| Live heartbeat prerequisite tests | 2 passed; zero skips/exclusions |
| Focused existing WS tests with coverage | 34 passed |
| Deribit REST-read lane | 41/41 executed, zero failures |
| Binance REST-read lane | 26/26 executed, one failure: no order-list ID from `fetchOrderLists`; confirmed in an isolated run |
| `mix check.dispatch` | Failed in its provider-live suite: 3,012 passed, 15 confirmed failures, one recovered flaky test, 74 excluded dangerous cases, zero skips |
| Dispatch checks before the live suite | Native signer, formatting, compilation, Credo, Doctor, and Sobelow passed |
| Authority, error authority, CLAUDE/AGENTS consistency, clone budget | Passed when run separately after the alias stopped at the live-suite failure |
| `MIX_ENV=dev mix reach.check --arch --smells --strict --path lib` | Passed: architecture OK; no cross-function smell findings |

The 15 confirmed failures are outside the new test file: the Binance order-list
prerequisite (one); Lighter account authentication (ten), unknown-market REST
error expectation (one), and `market_stats/0` subscription rejection (one); OKX
option open-interest history returning empty data (one); Binance USD-M's order
time-window assertion (one). The auto-retry recovered a Binance COIN-M algo-order
lookup. These failures remain visible and unfixed; they require separate
provider-state/contract investigation, not heartbeat expectation changes.

Local command output is in `/tmp/task696-probe.log`,
`/tmp/task696-live.json`, `/tmp/task696-coverage.json`,
`/tmp/task696-rest-{deribit,binance}.json`, `/tmp/task696-binance-order-list.json`,
`/tmp/task696-dispatch.log`, and `/tmp/task696-dispatch-tests.json` (the parsed
test envelope). These are implementer artifacts, not independent review evidence.

## Acceptance status

- AC1: live market delivery and explicit subscription outcomes verified;
  automatic heartbeat reply isolation remains broken.
- AC2: native Binance pong and Deribit JSON-RPC success observed; other venue
  dialects and unsupported-configuration rejection remain unimplemented.
- AC3: sparse Binance socket evidence verified at the dependency boundary;
  no Bourse primary/routed health API has been added.
- AC4: real transport fault reproduced the missing bound; disconnect/reconnect
  recovery remains blocked on the upstream primitive.
- AC5: provider authority, real success/error, live prerequisite tests, and
  pre-mutation coverage recorded. Independent reviewer approval is outstanding.
