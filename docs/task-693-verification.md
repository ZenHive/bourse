# Task 693 verification

## Contract

The public `Bourse` order API accepts snake_case controls and their camelCase
aliases. Equal duplicates are accepted; conflicting duplicates return
`invalid_parameters`. Normalization precedes venue selection, including nested
batch orders. Unsupported controls and native selectors that would discard them
are rejected. `reduce_only` takes a boolean and `time_in_force` takes a string.
Raw venue endpoints retain their provider-owned spelling.

The owned-state REST-read helper uses the same public API and canonical options.
Supported trigger lifecycle tests cover OKX, Bybit demo, Binance futures through
all three unified venue IDs, Deribit testnet, and Alpaca paper. Venues whose
current unified builders cannot express conditional controls fail explicitly.

## Provider authority

Consulted the indexed authority manifests under `priv/venues/*/authority/` and
these provider documents:

- [OKX algo orders](https://www.okx.com/docs-v5/en/#order-book-trading-algo-trading-post-place-algo-order).
- [Bybit create order](https://bybit-exchange.github.io/docs/v5/order/create-order):
  the indexed older `/order/create` URL returned 404. Market orders use IOC;
  reduce-only excludes spot and trigger controls exclude options.
- [Binance USD-M trade API](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade):
  the indexed New-Algo-Order URL redirects to this catalog.
- [Deribit sell](https://docs.deribit.com/api-reference/trading/private-sell) and
  [edit](https://docs.deribit.com/api-reference/trading/private-edit): edits
  support trigger price and reduce-only, but not changing time-in-force.
- [Alpaca orders](https://docs.alpaca.markets/us/docs/orders-at-alpaca): stop price,
  price increments and paper order lifecycle.

## Live evidence, 2026-09-15

Before editing external semantics, existing live OKX trigger/missing-order probes
passed (2 tests), and Binance-family lifecycle plus Deribit invalid-trigger
probes passed (2 tests). Evidence in this harness worktree's `/tmp`:
`task693-live-before.json` and `task693-provider-before.json`.

The new seven-venue live regression passed for both aliases on every venue.
Each accepted order has a unique client ID, is found by its own provider ID in
the conditional book, has the requested sell side and numeric trigger, remains
unfilled, and has a provider-native untriggered state. Cancellation runs in
`after`. Each venue also rejects zero quantity with a provider code and a
quantity-related message. Missing credentials and unreachable hosts fail.

The combined coverage run (`/tmp/task693-final-cover.json`) executed 25 tests:
24 passed, with one unit fixture still using market/GTC after the new Bybit
IOC-only guard. Changing that fixture to a limit order yielded 17/17 unit tests
(`/tmp/task693-unit-final.json`); all seven live tests and the public-boundary
live test had passed in the combined run. `Bourse` coverage was 100% before its
production edit and remains 100%; the new `OrderOptions` module is 96.97%.

### Sandbox incident during regression development

An earlier request-shape assertion checked the trigger field but failed to check
the Binance algo type. Legacy spelling consequently reached a regular MARKET
route on the unfixed code. Automatic retry repeated those sandbox fills. This
was reported immediately and the test now checks the conditional route before
submission; mutating verification commands use `--no-retry`.

The resulting ETHUSDT sell fills were `16794940006`, `16794940050`,
`16794940232`, `16794940250` (0.25 each); BTCUSD_PERP sells were `4438322370`
and `4438323018` (one contract each). After confirming the exact resulting
positions, reduce-only sandbox buys `16794941854` (ETH 1) and `4438326951`
(BTC 2 contracts) closed them. Subsequent provider position reads confirmed
ETH `0.000` and BTC `0`. No production trading occurred. A market fill is a
failed test even if exposure is subsequently closed.

An adjacent Binance test was also selected accidentally with line `:794`; its
margin-mode restoration failed with provider -4046 (already in that mode).
The intended lifecycle probe at `:800` subsequently passed. The failed run is
preserved as `/tmp/task693-binance-before.json`.

## Independent reviewer commands

These are reproducible commands for the cross-family reviewer, not a claim that
independent review has already occurred:

```sh
mix test.json test/bourse/unified/order_options_test.exs test/live/conditional_order_options_integration_test.exs test/live/order_api_boundary_integration_test.exs --include dangerous --no-retry --cover --quiet --output /tmp/task693-review.json
jq '.summary, (.coverage.modules[] | select(.module == "Bourse" or .module == "Bourse.Unified.OrderOptions"))' /tmp/task693-review.json
mix check.dispatch
```

Run the affected read lane for each venue (`binance`, `binanceusdm`,
`binancecoinm`, `okx`, `bybit`, `deribit`, `alpaca`):

```sh
MIX_ENV=test mix bourse.verify_rest_read_contracts --venue binanceusdm --output /tmp/task693-review-rest-binanceusdm.json
```

Read-lane results: COIN-M 32/32, Bybit 76/76, Deribit 41/41, Alpaca 16/16.
Binance spot passed 25/26 (no order-list ID available); OKX passed 83/84
(empty option open-interest history). USD-M passed 60/61, with a missing algo
order during concurrent mutation; the isolated rerun passed 61/61 (`/tmp/task693-rest-binanceusdm-isolated.json`).

Offline authority, error authority, CLAUDE mechanical claims, AGENTS freshness,
and the zero-clone budget checks passed. Detailed local artifacts use the
`/tmp/task693-` prefix. These paths are local run evidence, not CI URLs.

`mix check.dispatch` failed in its full provider-live suite: 3,074 passed,
15 failed, 82 excluded (dangerous tests require explicit inclusion). Its preceding
format, compile, Credo, doctor and Sobelow stages passed. The remaining dispatch
checks were executed separately and passed, including strict Reach architecture
and smell checks. Final source formatting, compilation and configured Credo were
also rerun after the last guard changes.

The full-suite failures concern Binance spot order-list state, Lighter account
availability/error semantics/WebSocket channel, OKX empty option interest history,
and a USD-M order-history time-window assertion. These remain visible in
`/tmp/task693-dispatch.json` extracted from `/tmp/task693-dispatch.log`; no check
was disabled. All 14 baseline failures recur here (`/tmp/task693-cov.json`). The additional
USD-M history-window failure also persisted when the generated time-window lane
was run alone: 17/18 passed (`/tmp/task693-time-window-isolated.json`). Its last
returned timestamp was 5,347 ms earlier than the requested upper boundary,
failing the existing proximity assertion; it did not return an order beyond
the upper bound. Follow-up: investigate USD-M merged order-history boundary
selection against the provider. Independent reviewer approval is still required.
