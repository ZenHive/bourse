# Task 699 — lighter public surface re-proof

## Provider evidence (2026-09-15)

Sources consulted from `priv/venues/lighter/authority/manifest.json`:
- [Provider API reference](https://apidocs.lighter.xyz/docs/websocket-reference): `market_stats/{MARKET_INDEX}`, `market_stats/all`, `order_book/{MARKET_INDEX}`, and `trade/{MARKET_INDEX}`.
- [Pinned provider OpenAPI](https://raw.githubusercontent.com/elliottech/lighter-python/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json): `GET /api/v1/orderBookOrders` requires integer `market_id` and `limit` (1–250).

The task's grammar-change hypothesis was incorrect. The venue changed its market catalog: `curl -fsS https://testnet.zklighter.elliot.ai/api/v1/orderBookDetails` returned code 200 and ETH=4095, BTC=4096, SOL=4097. The documented slash grammar still works. `venue.json` retains its accurate unresolved numeric-market-index markers: unified symbol conversion does not yet resolve lighter's loaded numeric IDs. No invented channel grammar or universal watch support was authored.

Before changing semantics, credential-free `mix run -e` probes used `Bourse.Exchange.new!("lighter", sandbox: true)`:

```elixir
Bourse.Lighter.public_get_orderbookorders(exchange, %{"market_id" => 2147483647, "limit" => 1})
# {:ok, %{status: 200, body: %{"asks" => [], "bids" => [], "code" => 200,
#                            "total_asks" => 0, "total_bids" => 0}, ...}}
Bourse.Lighter.public_get_orderbookorders(exchange, %{"market_id" => "not-a-market", "limit" => 1})
# {:error, %Bourse.Error{type: :bad_request, http_status: 400,
#                       code: 20001, message: "invalid param ", ...}}
```

For each WS channel, the probe connected with `Bourse.WS.connect(exchange, :public)`, called `Bourse.WS.subscribe(ws, [channel])`, received messages, and closed the socket:

| Channel | Live result |
|---|---|
| `market_stats/0` | Rejected: 30005, `Invalid Channel:  (marketId)` |
| `market_stats/4095` | `:ok`, `market_stats:4095` snapshot with market statistics |
| `order_book/4095` | `:ok`, `order_book:4095` snapshot with asks and bids |
| `trade/4095` | `:ok`, `trade:4095` snapshot with trades |
| `not_a_real_channel/4095` | Rejected: 30005, `Invalid Channel` |
| `market_stats/all` | `:ok`, `market_stats:all` snapshot keyed by live market IDs |

Raw exploration logs: `/tmp/lighter-rest-probe.log`, `/tmp/lighter-ws-probe.log`, `/tmp/lighter-all-probe.log`. The last log also records an exploratory call to nonexistent `Bourse.Lighter.fetch_markets/1`; the implementation uses the supported `Bourse.load_markets/1` API.

## Changes and class sweep

- Canary resolves market IDs through live market metadata and pins real stats, order-book, and trade snapshot payloads. The invalid-channel rejection test remains.
- Unknown numeric-market success is pinned in `test/live/lighter/public_order_book_test.exs`. The error lane now pins a nonnumeric-market rejection, including error type/status/code/message.
- The first-frame probe uses the documented all-market subscription and waits past lighter's unsolicited `connected` greeting. Regression tests cover greeting followed by snapshot, rejection, and silence.
- Reviewed all three authored public channel markers, subscribe envelope, sandbox URL, REST success codes, and the authored 20001 error mapping. No grammar or error-mapping change was needed.
- Ran the existing public REST contracts for markets, ticker, order book, funding rates, funding history, candles, and the invalid-symbol ticker case. Seven cases passed; the existing ledger records empty funding history as state-dependent. Account-dependent reads and signer/provisioning remain outside this change.

## Verification

```sh
mix test.json test/bourse/ws_first_frame_test.exs --cover --quiet --output /tmp/lighter-before-cover.json
```

17 tests passed before mutation. `Bourse.LiveLane.FirstFrame`: 88.37% (114 covered lines), above the 80% tier; this focused coverage run does not establish whole-project coverage.

```sh
mix test.json test/live/errors/lighter_test.exs test/live/lighter/public_order_book_test.exs test/live/ws/canary_test.exs test/bourse/ws_first_frame_test.exs --quiet --output /tmp/lighter-focused-final.json
```

27 passed, 0 failed, 0 skipped. An earlier exploratory template implementation failed two tests because unified symbol conversion did not resolve the numeric ID; that implementation was removed before this passing run.

```sh
mix test.json test/live/lighter/rest_read_contract_test.exs --only method_fetch_markets --only method_fetch_ticker --only method_fetch_order_book --only method_fetch_funding_rates --only method_fetch_funding_rate_history --only method_fetch_ohlcv --quiet --output /tmp/lighter-public-claims.json
```

7 passed, 0 failed; 9 account-dependent cases excluded by the explicit public-method selection.

```sh
mix bourse.verify_ws_first_frame --report /tmp/lighter-first-frame-final.json
```

Lighter public result:

```json
{
  "reason": null,
  "status": "passed",
  "venue": "lighter",
  "channel": "market_stats/all",
  "section": "public",
  "first_frame": "acknowledgement_with_payload",
  "data_frame": "acknowledgement_with_payload",
  "tracking": null
}
```

Command exited 1 because other venues failed: Alpaca connection limit 406, Binance COIN-M `:no_channel_templates`, and Derive deprecated `ticker` channel (-32602). These were not changed. Full output: `/tmp/lighter-first-frame-final.log`.

```sh
mix check.dispatch > /tmp/lighter-check-dispatch-699.log 2>&1
```

Dispatch exited 1 when the test subprocess exited 2. Its JSON summary reports 3,199 total: 3,103 passed, 13 confirmed failures, 1 healed flaky test, 82 excluded dangerous tests, 0 skipped. The automatic retry confirmed the 13 failures. Ten are the explicitly excluded lighter private-account condition (`invalid auth: couldnt find account`, 20013); the others are Binance order-list account state, Deribit transfer currency nil, and OKX option open-interest history empty. The healed flaky case was Bybit account analytics. No changed test failed.

The pre-test native signer checks (7 tests and 95.71% C parser/framing coverage), formatter, compiler, Credo, Doctor, and Sobelow completed. The suite stopped the alias before its remaining checks; those are run separately below. Parsed test result: `/tmp/lighter-dispatch-tests.json`.

Reviewer approval remains the independent gate; these are implementer observations.

Remaining dispatch checks, executed separately after the suite stopped the alias:

| Command | Exit | Output |
|---|---|---|
| `mix bourse.authority_check` | 0 | `/tmp/lighter-remaining-check-0.log` |
| `mix bourse.error_authority` | 0 | `/tmp/lighter-remaining-check-1.log` |
| `mix bourse.claude_check` | 0 | `/tmp/lighter-remaining-check-2.log` |
| `mix bourse.agents_md --check` | 0 | `/tmp/lighter-remaining-check-3.log` |
| `mix ex_dna --max-clones 0` | 0 | `/tmp/lighter-remaining-check-4.log` |
| `mix reach.check --arch --smells --strict --path lib` | 0 | `/tmp/lighter-remaining-check-5.log` |

All six passed. Reach reported architecture OK and no cross-function smells; ExDNA reported no clones. `git diff --check` also passed.
