# Conditional order controls

How the unified order API spells trigger and protective controls, which venue
operations can express them, and what the provider-owned contract says.
Implemented by `Bourse.Unified.OrderOptions` (task 693).

## Contract

The public `Bourse` order API accepts snake_case controls and their camelCase
aliases. Equal duplicates are accepted; conflicting duplicates return
`invalid_parameters`. Normalization precedes venue selection, including nested
batch orders. Unsupported controls and native selectors that would discard them
are rejected. `reduce_only` takes a boolean, `time_in_force` takes a string, and
`trigger_price` / `stop_loss_price` / `take_profit_price` take a numeric value
(number, `Decimal`, or a fully-parsing numeric string). Raw venue endpoints
retain their provider-owned spelling.

The owned-state REST-read helper uses the same public API and canonical options.
Supported trigger lifecycle tests cover OKX, Bybit demo, Binance futures through
all three unified venue IDs, Deribit testnet, and Alpaca paper. Venues whose
current unified builders cannot express conditional controls fail explicitly.

A control the write path accepts must map back on the order. The suite-level
invariant in `test/bourse/order_control_round_trip_invariant_test.exs` derives
that set from `OrderOptions.aliases/0` and the authored request shapes; it is
offline and asserts mapping presence, not venue values. The live re-reads live
in `test/live/conditional_order_options_integration_test.exs`
(`fetch_open_orders` / `fetch_order`), which assert `trigger_price` and, where
the venue offers it, `reduce_only` — never the create echo and never an `info`
fallback. A venue that omits a mapped field still answers `nil`.

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

The seven-venue live regression passed for both alias spellings on every venue.
Each accepted order has a unique client ID, is found by its own provider ID in
the conditional book, has the requested sell side and numeric trigger, remains
unfilled, and has a provider-native untriggered state. Cancellation runs in
`after`. Each venue also rejects zero quantity with a provider code and a
quantity-related message. Missing credentials and unreachable hosts fail loudly
rather than skipping.

Pinned in `test/bourse/unified/order_options_test.exs`,
`test/live/conditional_order_options_integration_test.exs` and
`test/live/order_api_boundary_integration_test.exs`.

## Sandbox incident during regression development, 2026-09-15

An earlier request-shape assertion checked the trigger field but not the Binance
algo type. The legacy spelling consequently reached a regular MARKET route on
the unfixed code, and automatic retry repeated those sandbox fills. The test now
checks the conditional route *before* submission, and mutating verification
commands run with `--no-retry`.

The resulting ETHUSDT sell fills were `16794940006`, `16794940050`,
`16794940232`, `16794940250` (0.25 each); BTCUSD_PERP sells were `4438322370`
and `4438323018` (one contract each). After confirming the exact resulting
positions, reduce-only sandbox buys `16794941854` (ETH 1) and `4438326951`
(BTC 2 contracts) closed them. Subsequent provider position reads confirmed
ETH `0.000` and BTC `0`. No production trading occurred.

**The durable lesson: a market fill is a failed test even if the exposure is
subsequently closed.** Assert the route the request will take before the request
is sent, and never let an automatic retry re-run a mutating probe.

## Reproduction

```sh
mix test.json test/bourse/unified/order_options_test.exs test/live/conditional_order_options_integration_test.exs test/live/order_api_boundary_integration_test.exs --include dangerous --no-retry --quiet --output /tmp/order-controls.json
```

Run the affected read lane per venue (`binance`, `binanceusdm`, `binancecoinm`,
`okx`, `bybit`, `deribit`, `alpaca`):

```sh
MIX_ENV=test mix bourse.verify_rest_read_contracts --venue binanceusdm
```
