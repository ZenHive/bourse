# Prod-Verification Ledger — deferred tier-1 confirmations

Deferred live confirmations that our current keys/hosts **cannot falsify**: the slice is
landed and green at tier 2 (CCXT fixture / docs), but the tier-1 confrontation against the
real venue needs production keys or real market state we don't have yet. When such keys/state
become available, work this file top-to-bottom; move closed entries to the "Closed" section
with the observed evidence.

**Append rule (reviewers & orchestrator):** any reviewer concern of the class "not reachable
with our keys / needs prod / needs real position" gets an entry here — in the review's
worktree, riding the deliverable — instead of a vague concern that dies with the run record.
Never write key material or secrets into this file.

Entry template:

```
### <venue> — <method(s)> (task <id>, filed YYYY-MM-DD)
- Authored slices: `<venue>:<canonical slot path>` (omit only when the entry is not about an authored field-map, sign-recipe, error-map, or symbol-pattern slot)
- Blocked by: <what's missing: prod key with X perms / funded position / …>
- What tier-2 already proved: <one line>
- The open question: <the semantic fact only the live call can falsify>
- Exact call: <copy-paste eval, minus creds>
- Expected evidence: <what the live response must show to CONFIRM>
```

## Open

> **OKX routing:** all remaining OKX probes use the international entity
> (`www.okx.com`) and `OKX_INTL_*` credentials. References to `my.okx.com` below are
> historical negative evidence only, never the target for a new probe.

### all venues — residual oracle critical slots (task 526, filed 2026-08-10)

These markers are explicit hard-gate waivers, not verification. The response recordings cited by
`mix ccxt.oracle_gate` close every slot for which the committed live call preserved sufficient
request or populated-body evidence. The residual slots need account state, permissions,
instrument families, or provider error conditions unavailable through the provisioned hosts and
the far-from-market/cancel-in-session mutation discipline.

- [oracle-critical-slot-waiver-review 2026-08-10]

The review marker periodically re-acknowledges the complete open waiver set. It is valid through
day 30; on day 31, or when a waiver is filed after the latest review, `mix ccxt.oracle_gate` names
the affected slot and blocks until an operator rechecks every listed blocker, removes any waiver
that can now be closed, and appends a new review marker. Markers are append-only so renewal
history remains in this ledger. Re-acknowledgment confirms only that the blocker still exists; it
does not turn a waiver into reality evidence.

This uses the same 30-day boundary as task 579's prose-drift acknowledgment: both remain valid
through day 30 and fail on day 31. Prose drift keeps a per-artifact `freshness.checked_at` because
each upstream document moves independently; these waivers use one append-only batch review
because they form one enumerated residual set whose blockers are reviewed together here.

A hard evidence-expiry was rejected because read-only keys, production-only endpoints, and absent
market state can remain genuine blockers after review; requiring closure would manufacture a
permanent red. A shrink-only count ratchet was rejected because an unchanged count can preserve
unreviewed waivers indefinitely or exchange one gap for another. Per-waiver `review_by` dates were
rejected because copying one review across 79 lines creates partial-renewal drift without adding
evidence beyond the batch review.

#### alpaca

- Blocked by: the paper account has no populated position and no distinct closed/all-order list
  observations. Creating the missing position would require a fill; the task permits only
  far-from-market orders cancelled in the same session.
  - [oracle-critical-slot-waiver 2026-08-10] `alpaca:normalization.field_maps.position`
  - [oracle-critical-slot-waiver 2026-08-10] `alpaca:request_shape.fetchClosedOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `alpaca:request_shape.fetchOrders`

#### binance

- Blocked by: the provisioned keys cover Spot and USD-M test/demo, not Options, Portfolio Margin,
  SAPI production, or every COIN-M signing section. The available accounts have no nonzero
  cross-family position, and the captured market inventory contains no currency-alias case.
  - [oracle-critical-slot-waiver 2026-08-10] `binance:auth.sign_recipe.dapiPrivate`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:auth.sign_recipe.dapiPrivateV2`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:auth.sign_recipe.eapiPrivate`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:auth.sign_recipe.fapiPrivateV2`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:auth.sign_recipe.papi`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:auth.sign_recipe.papiV2`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:auth.sign_recipe.sapi`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:markets.patterns.currency_aliases`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:normalization.field_maps.position`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:request_shape.fetchPositions`
  - [oracle-critical-slot-waiver 2026-08-10] `binance:request_shape.fetchTicker`

#### binancecoinm

- Blocked by: the demo account cannot safely manufacture the four remaining exchange-error conditions,
  and the provider inventory has no observed currency-alias case. Recorded open-orders and
  position reads close the remaining private request-shape slots.
  - [oracle-critical-slot-waiver 2026-08-10] `binancecoinm:errors.handle_errors.exceptions.exact.-1014`
  - [oracle-critical-slot-waiver 2026-08-10] `binancecoinm:errors.handle_errors.exceptions.exact.-2011`
  - [oracle-critical-slot-waiver 2026-08-10] `binancecoinm:errors.handle_errors.exceptions.exact.-4050`
  - [oracle-critical-slot-waiver 2026-08-10] `binancecoinm:errors.handle_errors.exceptions.inverse.exact.-1005`
  - [oracle-critical-slot-waiver 2026-08-10] `binancecoinm:markets.patterns.currency_aliases`

#### binanceusdm

- Blocked by: this runtime spec retains cross-product signing branches for COIN-M, Options,
  Portfolio Margin, Spot, and SAPI that the USD-M demo credential/host cannot accept. The public
  ticker fan-out also reaches product hosts without a valid common symbol; no observed inventory
  row exercises a currency alias.
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:auth.sign_recipe.dapiPrivate`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:auth.sign_recipe.dapiPrivateV2`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:auth.sign_recipe.eapiPrivate`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:auth.sign_recipe.fapiPrivateV2`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:auth.sign_recipe.papi`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:auth.sign_recipe.papiV2`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:auth.sign_recipe.private`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:auth.sign_recipe.sapi`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:markets.patterns.currency_aliases`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:request_shape.fetchOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:request_shape.fetchTicker`
  - [oracle-critical-slot-waiver 2026-08-10] `binanceusdm:request_shape.fetchTickers`

#### bybit

- Blocked by: demo trading lacks the option-family market evidence and account/order states needed
  by the history and singular-order variants. Batch/edit/cancel and market-cost variants require
  stateful mutations beyond the one far-from-market create/cancel profile; the read-only testnet
  key rejects signed creates with provider error 10024.
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:markets.patterns.currency_aliases`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:markets.patterns.option`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.cancelAllOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.cancelOrder`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.cancelOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.createMarketBuyOrderWithCost`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.createMarketSellOrderWithCost`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.createOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.editOrder`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.editOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchCanceledAndClosedOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchCanceledOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchClosedOrder`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchClosedOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchFutureMarkets`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchOpenOrder`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchOrder`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchOrderClassic`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchOrdersClassic`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchPosition`
  - [oracle-critical-slot-waiver 2026-08-10] `bybit:request_shape.fetchPositionsHistory`

#### deribit

- Blocked by: the test account has no closed-order state for a distinct closed-orders capture, and
  the observed instrument inventory contains no currency-alias case.
  - [oracle-critical-slot-waiver 2026-08-10] `deribit:markets.patterns.currency_aliases`
  - [oracle-critical-slot-waiver 2026-08-10] `deribit:request_shape.fetchClosedOrders`

#### derive

- Blocked by: demo order books and account history do not expose populated ticker or closed/all-order
  observations, and the provider inventory has no currency-alias case. The existing demo lifecycle
  proves create/open/cancel, but does not produce a fill or closed-history row.
  - [oracle-critical-slot-waiver 2026-08-10] `derive:markets.patterns.currency_aliases`
  - [oracle-critical-slot-waiver 2026-08-10] `derive:normalization.field_maps.ticker`
  - [oracle-critical-slot-waiver 2026-08-10] `derive:request_shape.fetchClosedOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `derive:request_shape.fetchOrders`

#### hyperliquid

- Blocked by: the provisioned wallet has no order history or position state, the recorded market
  inventory is perpetual-only, and no populated ticker/order response is registered. TP/SL and
  TWAP creation require stateful mutation protocols not covered by the safe single-order profile.
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:markets.patterns.currency_aliases`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:markets.patterns.spot`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:normalization.field_maps.order`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:normalization.field_maps.ticker`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:request_shape.createOrderWithTakeProfitAndStopLoss`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:request_shape.createTwapOrder`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:request_shape.fetchCanceledAndClosedOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:request_shape.fetchCanceledOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:request_shape.fetchClosedOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `hyperliquid:request_shape.fetchOrders`

#### lighter

- Blocked by: the testnet account has no populated order evidence or currency-alias market row.
  Create/cancel requires nonce-managed zk signing and a mutation lifecycle absent from the safe
  accepted-request recorder.
  - [oracle-critical-slot-waiver 2026-08-10] `lighter:markets.patterns.currency_aliases`
  - [oracle-critical-slot-waiver 2026-08-10] `lighter:normalization.field_maps.order`
  - [oracle-critical-slot-waiver 2026-08-10] `lighter:request_shape.cancelOrder`
  - [oracle-critical-slot-waiver 2026-08-10] `lighter:request_shape.createOrder`

#### okx

- Blocked by: the international demo account has no populated order, closed-order, or position-history
  state, and the provider inventory contains no currency-alias example. `closePosition` requires an
  open position, which the far-from-market/cancel-in-session policy does not create.
  - [oracle-critical-slot-waiver 2026-08-10] `okx:markets.patterns.currency_aliases`
  - [oracle-critical-slot-waiver 2026-08-10] `okx:normalization.field_maps.order`
  - [oracle-critical-slot-waiver 2026-08-10] `okx:request_shape.closePosition`
  - [oracle-critical-slot-waiver 2026-08-10] `okx:request_shape.fetchClosedOrders`
  - [oracle-critical-slot-waiver 2026-08-10] `okx:request_shape.fetchPositionsHistory`

### binance — populated margin-adjustment history row (task 568, filed 2026-08-09)
- Authored slices: `binance:normalization.field_maps.margin_modification` (intentionally
  absent while the task-550 coverage cell remains open).
- Blocked by: the provisioned USD-M demo account returned `[]` for
  `fapi/v1/positionMargin/history` across BTC, ETH, SOL, XRP, BNB, ADA, and DOGE. Producing a
  row requires an isolated position plus an add/reduce-margin mutation.
- What tier-2 already proved: Binance's USD-M contract defines `amount`, `asset`, `type` 1/2,
  `time`, `symbol`, and `positionSide`; an empty signed demo response proves routing and auth
  but none of those row meanings.
- The open question: does a populated demo row preserve the documented amount, currency,
  add/reduce type, and millisecond event time through the unified parser?
- Exact call: after an operator-approved isolated-position margin adjustment, call
  `Bourse.fetch_margin_adjustment_history(ex, "BTC/USDT:USDT", limit: 10)` on
  `demo-fapi.binance.com`.
- Expected evidence: freeze and register a populated response; assert the parsed amount,
  currency, type, symbol, and timestamp against the same raw row; author the map and remove
  only the Binance margin-adjustment task-550 coverage cell.

### hyperliquid — populated funding history on testnet (task 568, filed 2026-08-09)
- Authored slices: `hyperliquid:normalization.field_maps.funding_history` (intentionally absent
  while the task-550 coverage cell remains open).
- Blocked by: `info:userFunding` returned `[]` for the provisioned testnet wallet even with
  `startTime: 0`. Producing a row requires holding a perpetual position across an hourly
  funding event.
- What tier-2 already proved: Hyperliquid's provider-owned contract defines the row's `time`,
  `hash`, and nested `delta.coin`, `delta.usdc`, and `delta.fundingRate`; the empty testnet
  response proves only endpoint reachability.
- The open question: do those fields retain the documented meanings on a populated testnet
  row and normalize to the correct unified symbol and USDC amount?
- Exact call: after a testnet position survives a funding boundary, call
  `Bourse.fetch_funding_history(ex, since: 0)`.
- Expected evidence: freeze and register the populated testnet body; assert its exact id,
  amount, rate, symbol, and timestamp; author the map and remove only the Hyperliquid funding
  task-550 coverage cell.

### okx — populated margin-adjustment bill row (task 568, filed 2026-08-09)
- Authored slices: `okx:normalization.field_maps.margin_modification` (intentionally absent
  while the task-550 coverage cell remains open).
- Blocked by: the international demo account returned no type-6 rows from either the recent or
  archive bills endpoint. Producing one requires an isolated position plus a margin mutation.
- What tier-2 already proved: live `GET /api/v5/account/subtypes` identifies type 6 subtype
  `160` as manual margin increase and `161` as manual margin decrease. OKX's bills contract
  distinguishes account-level `balChg`/`bal` from position-level `posBalChg`/`posBal`; the
  latter pair matches `MarginModification.amount`/`total`.
- The open question: what signs and resulting position-margin totals do populated subtype
  160/161 demo rows carry?
- Exact call: after an operator-approved isolated-position add/reduce, call
  `Bourse.fetch_margin_adjustment_history(ex, type: "add")` and the matching `"reduce"` read.
- Expected evidence: freeze and register both populated bill rows; assert subtype, signed
  `posBalChg`, resulting `posBal`, currency, margin mode, and timestamp; author the map and
  remove only the OKX margin-adjustment task-550 coverage cell.

### bybit — conversion read field map on sandbox (task 567, filed 2026-08-08)
- Authored slices: `bybit:normalization.field_maps.conversion` (intentionally absent while
  the three task-550 coverage cells remain open).
- Blocked by: neither provisioned sandbox credential can produce a successful conversion
  response. `api-demo.bybit.com` returns `10032 "Demo trading are not supported."` for
  `fetchConvertQuote`, `fetchConvertTrade`, and `fetchConvertTradeHistory`; the testnet key
  reaches the same three endpoints but returns `10005` because it lacks Bybit's Exchange
  permission.
- What live production already proved: the read-only production probe returned a populated
  quote, one successful history row, and that row again through convert-status. The observed
  fields match Bybit's provider-owned quote/history/status contracts, but task 567 requires a
  sandbox recording and does not treat production traffic as a substitute.
- The open question: does an Exchange-enabled testnet account return the same conversion
  fields and meanings through all three unified reads?
- Exact call: with an Exchange-enabled `BYBIT_TESTNET_*` key, call
  `Bourse.fetch_convert_quote(ex, "SOL", "USDT", 0.00005)`, then use an existing testnet
  history id with `Bourse.fetch_convert_trade(ex, id)` and call
  `Bourse.fetch_convert_trade_history(ex, limit: 10)`. Do not confirm or execute the quote.
- Expected evidence: `retCode 0` bodies carrying the quote id, source/destination currencies
  and amounts, venue rate, status, and millisecond clock; freeze and register all three raw
  responses, author the conversion map, assert those exact parsed meanings, and remove only
  the three Bybit task-550 coverage cells.

### binanceusdm — conversion and currency read field maps on sandbox (task 567, filed 2026-08-08)
- Authored slices: `binanceusdm:normalization.field_maps.conversion` and
  `binanceusdm:normalization.field_maps.currency` (intentionally absent while the five
  task-550 coverage cells remain open).
- Blocked by: the authored `sapi` routes used by `fetchConvertQuote`, `fetchConvertTrade`,
  `fetchConvertTradeHistory`, `fetchConvertCurrencies`, and `fetchCurrencies` have no USD-M
  sandbox base URL. The first, fourth, and fifth stop with the explicit no-base error; the two
  history/status reads currently stop earlier on ambiguous multi-endpoint selection. Direct
  probes of USD-M's native `fapi/v1/convert/exchangeInfo` and `convert/getQuote` returned
  Binance `-1000` / HTTP 500 on both `demo-fapi.binance.com` and the legacy
  `testnet.binancefuture.com` host.
- What live production already proved: the production `sapi` host returned 600 Convert asset
  rows and 729 Wallet currency rows; Convert history returned a successful empty envelope and
  an invalid status id returned Binance's `-1102` parameter error. Those calls establish
  production reachability but cannot supply the sandbox-success recordings task 567 requires.
- The open question: which sandbox-supported provider operations supply the five declared
  reads, and do their populated rows retain the production field meanings?
- Exact call: with the provisioned `BINANCE_FUTURES_TEST_*` key, first call
  `Bourse.Binanceusdm.fapiPublic_get_convert_exchangeinfo(ex)` and the non-executing
  `fapiPrivate_post_convert_getquote/2`; after the provider returns success, exercise all five
  unified reads with sandbox mode enabled. Do not accept the quote.
- Expected evidence: successful sandbox bodies for each declared read, including a populated
  conversion history/status row and concrete currency rows; freeze and register each response,
  author both maps from Binance's own contracts, assert the observed domain values, and remove
  only the five Binance USD-M task-550 coverage cells.

### binance — documented pending and match-expiry order statuses (task 538, C-T538b, filed 2026-08-04)
- Authored slices: `binance:normalization.field_maps.order.field_map.status`
- Blocked by: the provisioned Spot Testnet history has no registered row carrying
  `PENDING_NEW`, `PENDING_CANCEL`, or `EXPIRED_IN_MATCH`; manufacturing these states requires
  venue-specific matching or cancel-race conditions.
- What tier-2 already proved: Binance's provider-owned order-status enum publishes all three
  values, and the runtime-wide coverage test pins them in the authored map.
- The open question: do live order-history rows preserve these exact spellings and terminality?
- Exact call: `Bourse.fetch_orders(exchange, "BTC/USDT")` after the account naturally records
  one of the three statuses.
- Expected evidence: raw status spelling plus unified `open` for the pending states and
  `canceled` for `EXPIRED_IN_MATCH`.

### binanceusdm — documented match-expiry order status (task 538, C-T538c, filed 2026-08-04)
- Authored slices: `binanceusdm:normalization.field_maps.order.field_map.status`
- Blocked by: the provisioned demo-fapi history has no registered `EXPIRED_IN_MATCH` row;
  manufacturing one requires a matching-engine expiry condition.
- What tier-2 already proved: Binance's provider-owned USD-M enum publishes the value, and the
  runtime-wide coverage test pins it in the authored map.
- The open question: does a live history row preserve the spelling and terminal semantics?
- Exact call: `Bourse.fetch_orders(exchange, "BTC/USDT:USDT")` after such a row exists.
- Expected evidence: raw `EXPIRED_IN_MATCH` parses as unified `canceled`.

### derive — documented expired order status (task 538, C-T538d, filed 2026-08-04)
- Authored slices: `derive:normalization.field_maps.order.field_map.status`
- Blocked by: no manifest-registered demo history row carries `expired`; producing one requires
  leaving an accepted order active through its expiry boundary.
- What tier-2 already proved: Derive's provider-owned Get Open Orders schema publishes `expired`,
  and the runtime-wide coverage test pins it in the authored map.
- The open question: does a live order row use that exact terminal status?
- Exact call: `Bourse.fetch_open_orders(exchange)` after an accepted order expires.
- Expected evidence: raw `expired` parses as unified `canceled`.

### okx — documented MMP-canceled order status (task 538, C-T538e, filed 2026-08-04)
- Authored slices: `okx:normalization.field_maps.order.field_map.status`
- Blocked by: no manifest-registered international-demo history row carries `mmp_canceled`;
  producing one requires an account and option flow that trigger market-maker protection.
- What tier-2 already proved: OKX's provider-owned order-details schema publishes the value, and
  the runtime-wide coverage test pins it in the authored map.
- The open question: does a live order-history row preserve the spelling and terminal semantics?
- Exact call: `Bourse.fetch_orders(exchange)` after MMP cancels a demo order.
- Expected evidence: raw `mmp_canceled` parses as unified `canceled`.

### okx — Optimism unified network code (task 441, C-T421, filed 2026-07-20)
- Authored slices: `okx:normalization.field_maps.currency`
- Blocked by: the EEA demo host (`my.okx.com`, `sandbox: true`) does not serve
  `GET /api/v5/asset/currencies` at all — attested live 2026-07-20 on the landed base, the venue
  answers business error `50038` "This feature is unavailable in demo trading". The provisioned
  demo keys 401 (`50101`) against the live host, so no reachable oracle returns okx's own chain
  naming for Optimism with current credentials.
- What tier-2 already proved: after task 441 changed `ETH-Optimism` / `USDT-Optimism` from
  `OPTIMISM` to `OP`, the fetchCurrencies and fetchDepositAddressesByNetwork replay network-key
  sets are byte-identical to the CCXT 4.5.65 oracle (28 keys each, `op` on both sides, bare
  `optimism` on neither). That is compatibility with CCXT, not correctness.
- The open question: does OKX itself name the chain `OP` (venue-code shape, matching the sibling
  aliases `ARBONE` / `MATIC` / `ETH` / `BASE` / `LINEA` already in the same authored table), or
  `OPTIMISM`? The carve currently rests on two okx.com help-centre URLs that the task-441
  reviewer could NOT fetch from its environment, plus an in-repo alias-table consistency
  argument. Neither is tier-1: one is an unverified citation, the other is our own convention.
- Exact call: with a live-entitled okx key, `Bourse.fetch_currencies(exchange)` and read the `ETH`
  entry's `networks` keys; equivalently `GET /api/v5/asset/currencies` and read the `chain`
  field for the Optimism row (okx returns `chain` as `"ETH-Optimism"`-style strings — the
  question is which short code the venue's own docs/UI bind to it).
- Expected evidence: okx's own response or documentation showing the chain short code. If it
  reads `OP`, the carve is confirmed and the citation is replaced with the observed source. If it
  reads `OPTIMISM`, our table was right and the 4.5.65 fixtures must be re-annotated
  `deliberate_divergence: true` — i.e. task 441's change should be reverted.

### Binance COIN-M — fetchPositions value axes (task 334, filed 2026-07-19)
- Authored slices: `binance:normalization.field_maps.position`
- Blocked by: the provisioned `BINANCE_FUTURES_TEST_*` key can read the COIN-M dapi
  position-risk endpoint (`[]`), but its COIN-M account endpoint returns Binance business error
  `-2015` / HTTP 401 (invalid API-key, IP, or permissions). It cannot fund or open a COIN-M
  testnet position.
- What tier-2 already proved: the frozen CCXT response and the offline market-cache test cover
  inverse `notionalValue`, position amount, and a non-100 ETH contract unit without treating
  fixture values as venue truth.
- The open question: on a funded COIN-M testnet or production account, whether a live inverse
  position's loaded market contract size, absolute `notionalValue`, initial/maintenance margin,
  and collateral absence/presence retain the authored meanings through an open/read/close cycle.
- Exact call: construct `Bourse.Exchange.new!("binance", credentials: creds, sandbox: true)`, load
  dapi markets, place and immediately reduce-only-close one minimal BTC/USD or ETH/USD contract,
  then call `Bourse.fetch_positions(exchange, type: "inverse")` and the same call with an invalid
  symbol.
- Expected evidence: one nonzero inverse row whose `contract_size` equals its loaded market,
  `notional == abs(info["notionalValue"])`, margins remain separate, cleanup leaves no nonzero
  position, and the invalid-symbol call reaches Binance's relevant business error. Until then
  this family remains tier-2-labelled.

### derive (testnet) — option ATM fill + settlement semantics (task 403, filed 2026-07-19)
- Authored slices: `derive:normalization.field_maps.trade`
- Blocked by: every nearest-ATM ETH option book (32 instruments across 8 expiries) was
  `bid 0x0 / ask 0x0` and ETH-PERP one-sided at attestation time — no fill is possible on
  this demo market state.
- What tier-2 already proved: header-trio auth + raw reads green; hand-signed EIP-712 order
  accepted (`70ed8f63…`, status open via raw read) then cancelled, 0 open orders after;
  venue error 11023 max_fee floor pinned live (re-sign at floor → accepted); collateral
  intact, zero fees.
- The open question: a real fill (trade row, fee semantics, position row) plus hedge where
  collateral allows, and full unwind.
- Exact call: task-403 protocol via the hand-signed `sign_order/2` path (unified write path
  is task 379) when the testnet books show two-sided ATM liquidity.
- Expected evidence: filled order id + trade history row, position row, then 0 open orders /
  0 positions after unwind.
- Re-attested 2026-07-23 (task 407 convergence audit): book still empty — 52 option
  instruments discovered, 0 two-sided (`observed_at 1784812661779`). The order lifecycle is
  now proven through the **unified** write path (no hand-signing needed): `Bourse.create_order`
  buy 2 @ 0.1 on `ZEC/USDC:USDC-260925-800-P` → order `9f2afe87-c2c4-46ea-affd-8ae5183e251f`
  `open`, read back via `fetch_open_orders` (`fetch_order` is `:not_supported` on derive),
  cancel → `canceled`, 0 open orders after. Entry stays open solely for the fill/hedge/unwind
  confirmation; task 407 converged derive via this ledger deferral.
- Expected evidence extended (task 506 review, 2026-07-23): when the fill lands, also freeze
  the **populated** `fetch_positions` payload (with market_context) so the
  `instrument_type=option` position carve and derive contracts-unit semantics (C-T506d,
  currently recorded/deferred on a shape-only empty-body fixture) are pinned by a populated
  tier-1 fixture — assert the unified option symbol and contracts against the observed amount.

### deribit — fetchTradingFees populated schedule (task 380, filed 2026-07-19)
- Authored slices: `deribit:normalization.field_maps.trading_fees`
- Blocked by (re-confronted 2026-07-22, task 468): the signed testnet route is reachable, but
  this account has no fee discount. A fresh
  `private/get_account_summary?currency=BTC&extended=true` call returned `currency=BTC` and
  omitted both `fee_group` and the optional `fees` field. Deribit's current endpoint
  documentation says `fees` is available only when `extended=true` **and the user has
  discounts**. `DERIBIT_CLIENT_ID` resolves to the same provisioned testnet key, and no separate
  production or discounted credential is available. The 2026-07-21 UTC recording is frozen at
  `test/fixtures/responses/deribit/fetch_trading_fees.json`; its offline replay correctly
  returns an empty map instead of inventing a schedule.
- What tier-2 already proved: the populated authoring-derived body exercises the legacy
  `fees[]` / `instrument_type` / `maker_fee` / `taker_fee` transform and remains covered by
  `deribit_authored_spec_test.exs`. CCXT has no static fixture for this method.
- What tier-1 already proved: signed routing, `currency=BTC`, `extended=true`, the JSON-RPC
  result envelope, and the no-discount/field-absent branch all replay from a real body.
- Provider-contract confrontation (2026-07-22): Deribit's schema version `2.1.1`, identified by
  `priv/authority/deribit/manifest.json`, defines `fees` as
  `index_name -> instrument_type -> default.{type,maker,taker}` plus optional `block_trade`.
  This DIVERGES from C-T380a's authored legacy `fees[]` / `instrument_type` / `maker_fee` /
  `taker_fee` carrier; CCXT 4.5.65 still expects that legacy list and is only a compatibility
  cross-check. The slice therefore remains explicitly **tier 2 / authored**.
- The open question: does a current discounted account return the documented nested value, and
  how should each index/instrument/default object map to the applicable loaded markets and to
  `%Bourse.TradingFee{maker, taker, percentage, tier_based, info}`? A populated live body remains
  necessary before changing the parser.
- Exact call: on a discounted testnet or production account,
  `Bourse.fetch_trading_fees(ex)` after `Bourse.load_markets(ex)`; retain the raw extended account
  summary and compare the same fee carriers to every parsed `%Bourse.TradingFee{}`.
- Expected evidence: retain a populated raw `fees` value, then compare **every** parsed
  `%Bourse.TradingFee{}` field-by-field against its exact index/instrument/default source:
  symbol-to-market applicability, maker, taker, fee type/percentage semantics, tier-based flag,
  and raw `info`. The parsed map must contain no symbol whose fee cannot be traced to that same
  body.

### okx — populated funding-account asset-bills row (task 601, filed 2026-08-12)
- Authored slices: `okx:normalization.field_maps.ledger_entry.route_field_maps.asset/bills`
- Blocked by: the provisioned international demo account returned `code: "0", data: []` from
  the signed funding-account call. Producing a row requires a real demo deposit, withdrawal, or
  account transfer not authorized by this task.
- What tier-2 already proved: OKX's Asset bills details table distinguishes funding-account type
  `1` (deposit), `2` (withdrawal), and the documented account-transfer codes from the colliding
  trading-account meanings. The routed parser confrontation pins one row from each schema.
- The open question: whether a populated international-demo asset bill preserves those documented
  type meanings and the signed balance change through the unified parser.
- Exact call: `Bourse.Unified.raw_call(ex, :fetch_ledger, %{"type" => "funding", "limit" => 100})`
  with an OKX international demo exchange (`sandbox: true`). This exact call returned the empty
  success on 2026-08-12.
- Expected evidence: freeze one populated `/api/v5/asset/bills` response and compare its `type`,
  `billId`, `ccy`, `balChg`, and `ts` directly with the parsed `%Bourse.LedgerEntry{}`.

### okx — populated trading-account ledger row (task 365, filed 2026-07-19)
- Authored slices: `okx:normalization.field_maps.ledger_entry`
- Blocked by: the provisioned EEA demo account may return an empty
  `GET /api/v5/account/bills` list. Creating a trade merely to manufacture a bill is outside
  the mutation policy; a production or demo account with an existing completed account-bill is
  required.
- What tier-2 already proved: fixture #25 and C-T365a map `billId`/`ccy`/`balChg`/`bal`/`fee`/
  `ts` to the ledger identifier, currency, signed amount, before/after balances, fee, and
  timestamp. The official account-bills schema supplies the non-CCXT semantic source.
- What the live call DID confirm (tier 1, 2026-07-19): EEA demo accepts the signed account-bills
  request and returns a successful list envelope; `fetchAccounts` returns a populated account
  configuration row, and `fetchTransfers` returns populated internal-transfer bill rows.
- The open question: whether a current populated **trading-account** bill still uses `bal` as
  the post-change balance and `fee` in the `ccy` currency under this account mode.
- Exact call: `Bourse.fetch_ledger(ex, "USDT", limit: 1)` against an account with a recent
  completed spot trade or account-bill.
- Expected evidence: one nonempty ledger entry where `before + amount == after`, `currency ==
  info["ccy"]`, and `fee.currency == info["ccy"]`. Until then the populated-row branch remains
  tier-2-labelled.

### okx — fetchDepositAddress / fetchDepositAddressesByNetwork (task 389, filed 2026-07-19)
- Authored slices: `okx:normalization.field_maps.deposit_address`
- Blocked by: **the endpoint does not exist in demo trading.** EEA demo (`my.okx.com`,
  `sandbox: true`) answers every `GET /api/v5/asset/deposit-address` with
  `50038 "This feature is unavailable in demo trading"` — an empty `data: []`, not a
  populated row. A production key with *read* permission on the funding account is
  required; no funded state or withdrawal permission is needed.
- What tier-2 already proved: the six CCXT static response fixtures (#18–23) are green —
  `selected: true` row filtering, chain→network aliasing, `defaultNetworks` fallback,
  and the network-keyed dict shape all match CCXT's `fetchDepositAddressesByNetwork`.
  Carves C-T389a–C-T389d record the confrontation against OKX's own documented schema.
- What the live call DID confirm (tier 1, 2026-07-19): the signed request is accepted and
  routed — OKX answers with a *business* error (50038), not `401`/`50111` (bad signature),
  so auth, host, and the `x-simulated-trading` header are correct. Pinned in
  `test/bourse/okx_demo_integration_test.exs`.
- The open question: whether native `ccy` is accepted with code 0 on this endpoint (C-T484a),
  plus the **field semantics of a populated row** — specifically (a) that `addrEx.comment`
  is the memo carrier for TON-family currencies and that `tag`/`pmtId`/`memo` take precedence
  over it, and (b) that a currency whose chain is absent from the authored alias table really
  does surface with `network: nil` (carve C-T389c) rather than some other OKX-side code. These
  remain authored from OKX's documented schema plus CCXT compatibility evidence, i.e. tier 2.
- Exact call (production key, funding-account read scope):
  ```elixir
  creds = Bourse.Credentials.new!(api_key: ..., secret: ..., password: ...)
  {:ok, ex} = Bourse.Exchange.new("okx", credentials: creds)
  Bourse.Okx.private_get_asset_deposit_address(ex, %{"ccy" => "USDT"})
  Bourse.fetch_deposit_addresses_by_network(ex, "USDT")
  Bourse.fetch_deposit_address(ex, "TON")   # the addrEx.comment carrier
  ```
- Expected evidence: code 0 with the requested `ccy`, and a populated `data` array with at least two rows sharing one `chain`
  and differing `selected` flags (proves the stale-row filter matters on real data), and a
  TON row carrying `addrEx.comment` with no top-level `tag`/`pmtId`/`memo` (proves the
  fallback order). Until then the slice stays **tier-2-labelled**.

### Task 374 — zero-param JSON-body audit (filed 2026-07-19)
- Audited set: all 76 vendored venues with at least one `body_encoding: "json"`
  descriptor — `aftermath`, `alpaca`, `arkham`, `ascendex`, `backpack`, `bequant`,
  `bigone`, `bingx`, `bitbank`, `bitfinex`, `bitflyer`, `bitget`, `bitmart`,
  `bitmex`, `bitopro`, `bitso`, `bitteam`, `bittrade`, `bitvavo`, `blockchaincom`, `blofin`,
  `btcmarkets`, `btcturk`, `bullish`, `bydfi`, `cex`, `coinbase`,
  `coinbaseadvanced`, `coinbaseexchange`, `coinbaseinternational`, `coinone`,
  `coinspot`, `cryptocom`, `cryptomus`, `deepcoin`, `delta`, `derive`, `dydx`,
  `extended`, `fmfwio`, `foxbit`, `gate`, `gemini`, `grvt`, `hashkey`, `hibachi`,
  `hitbtc`, `hollaex`, `htx`, `huobi`, `hyperliquid`, `independentreserve`,
  `kucoin`, `kucoinfutures`, `latoken`, `mexc`, `modetrade`, `myokx`, `ndax`,
  `novadax`, `okx`, `okxus`, `onetrading`, `p2b`, `pacifica`, `paradex`,
  `paymium`, `phemex`, `poloniex`, `upbit`, `wavesexchange`, `weex`, `whitebit`,
  `woofipro`, `xt`, and `zebpay`.
- Current source-gated subset — **18 venues**: `alpaca`, `bitflyer`, `bitmex`,
  `bitso`, `bitvavo`, `blofin`, `coinbase`, `coinbaseadvanced`,
  `coinbaseexchange`, `coinbaseinternational`, `hollaex`, `kucoin`,
  `kucoinfutures`, `myokx`, `okx`, `okxus`, `paymium`, and `poloniex`.
- Detection: an `IfStatement` in the extracted `sign()` whose condition tests
  params emptiness and whose branch performs the `body = this.json(...)`
  assignment. **Two idioms carry that gate, not one** — `!this.isEmpty(query)`
  (blofin `js/src/blofin.js:2876`, kucoin `js/src/kucoin.js:11296`, inherited by
  kucoinfutures via `extends kucoin` at `js/src/kucoinfutures.js:5`) and the far
  more common `Object.keys(query).length` (okx `js/src/okx.js:6605`, alpaca
  `js/src/alpaca.js:1869`, bitmex `js/src/bitmex.js:3576`, poloniex
  `js/src/poloniex.js:3579`, bitvavo `js/src/bitvavo.js:2589`, coinbaseexchange
  `js/src/coinbaseexchange.js:2089`). All line references are ccxt 4.5.57.
  Matching only the `isEmpty` idiom undercounts the set to 3.
- Encoded as an invariant in `test/bourse/zero_param_json_body_gate_test.exs` —
  the set is asserted exactly, so re-vendoring a spec or adding a venue fails
  the test rather than silently widening the divergence surface.
- **Bounded finding (tier 1, live 2026-07-19):** the reachable gated venue —
  okx, EEA demo `my.okx.com` — does **not** reject `{}`. It rejects the
  *absence* of a body. Three zero-param signed POSTs, each signed exactly as
  sent (bodyless variant signs without the body, mirroring ccxt-js):

  | path | ccxt-js behavior (no body) | our behavior (`{}`) |
  |---|---|---|
  | `/api/v5/trade/order` | HTTP 400 `50002 Incorrect json data format` | HTTP 200 `50014 Parameter instId can not be empty` |
  | `/api/v5/account/set-position-mode` | HTTP 400 `50002 Incorrect json data format` | HTTP 400 `51000 Parameter posMode error` |
  | `/api/v5/trade/cancel-batch-orders` | HTTP 400 `50000 Body for POST request cannot be empty` | HTTP 400 `50002 Incorrect json data format` |

  In every case `{}` reaches OKX's business validation while the bodyless
  request is rejected at the body-shape layer. (`cancel-batch-orders` wants a
  JSON *array*, so `{}` is the wrong shape there too — but bodyless fails that
  endpoint as well, so it does not contradict the finding.) Mutation-safe by
  construction: zero params means no order can be created.
- Conclusion: **no reachable gated venue rejects `{}`**, so the contract gains
  no `json_when_present` value — and on okx, ccxt-js's gate is the latent bug,
  not ours. Task 369's always-json behavior is confirmed correct against the
  exchange itself, not merely against Bourse. The remaining 17 gated venues are
  unreachable with current credentials and retain ledger entries below; this
  finding is bounded to okx and is **not** a catalog-wide proof.

### blofin — zero-param signed JSON POST body (task 374, filed 2026-07-19)
- Blocked by: missing `BLOFIN_TESTNET_API_KEY`, `BLOFIN_TESTNET_API_SECRET`, and
  `BLOFIN_PASSPHRASE` for the documented demo host
  `https://demo-trading-openapi.blofin.com`.
- What source compatibility proves: CCXT v4.5.57 emits no body for an empty
  private POST query (`js/src/blofin.js:2876`); it does not prove BloFin's
  live endpoint rejects `{}`. Note blofin sets `Content-Type: application/json`
  *outside* the gate, so ccxt-js sends that header with no body at all — the
  same shape okx rejects live.
- The open question: does a signed zero-param private POST accept both no body
  and `{}`, or reject `{}` before its normal business validation?
- Exact call: use the same authenticated, zero-param BloFin private POST twice
  against the demo host, once with no `Content-Type`/body and once with
  `Content-Type: application/json` plus `{}`; sign each exact request.
- Expected evidence: record both HTTP status and exchange response. A body-shape
  error only for `{}` requires an authored `json_when_present` contract value.

### kucoin — zero-param signed JSON POST body (task 374, filed 2026-07-19)
- Blocked by: missing production `KUCOIN_API_KEY`, `KUCOIN_API_SECRET`, and
  `KUCOIN_PASSPHRASE`; the vendored spec declares no KuCoin testnet URL.
- What source compatibility proves: CCXT v4.5.57 emits no body for an empty
  POST query (`js/src/kucoin.js:11296`); it does not prove KuCoin's live
  endpoint rejects `{}`.
- The open question: does a signed zero-param private POST accept both no body
  and `{}`, or reject `{}` before its normal business validation?
- Exact call: use the same authenticated, zero-param KuCoin private POST twice,
  once bodyless and once as `{}`, signing each exact request; prefer a
  non-mutating endpoint and compare the venue responses.
- Expected evidence: record both HTTP status and exchange response. A body-shape
  error only for `{}` requires an authored `json_when_present` contract value.

### kucoinfutures — zero-param signed JSON POST body (task 374, filed 2026-07-19)
- Blocked by: missing production `KUCOINFUTURES_API_KEY`,
  `KUCOINFUTURES_API_SECRET`, and `KUCOINFUTURES_PASSPHRASE`; the futures class
  inherits KuCoin's signer and the vendored spec declares no testnet URL.
- What source compatibility proves: `js/src/kucoinfutures.js:5` (`extends
  kucoin`) inherits the gated KuCoin signer at `js/src/kucoin.js:11296`; it does
  not prove the futures API rejects `{}`.
- The open question: does a signed zero-param futures private POST accept both
  no body and `{}`, or reject `{}` before its normal business validation?
- Exact call: use the same authenticated, zero-param KuCoin Futures private
  POST twice, once bodyless and once as `{}`, signing each exact request; prefer
  a non-mutating endpoint and compare the venue responses.
- Expected evidence: record both HTTP status and exchange response. A body-shape
  error only for `{}` requires an authored `json_when_present` contract value.

### remaining gated venues — zero-param signed JSON POST body (task 374, filed 2026-07-19)
- Covers the 14 gated venues with no provisioned credentials, kept as one entry
  because the open question and the probe are identical for each: `alpaca`,
  `bitflyer`, `bitmex`, `bitso`, `bitvavo`, `coinbase`, `coinbaseadvanced`,
  `coinbaseexchange`, `coinbaseinternational`, `hollaex`, `myokx`, `okxus`,
  `paymium`, `poloniex`.
- Blocked by: no `<VENUE>_TESTNET_API_KEY` / `_API_SECRET` (plus `_PASSPHRASE`
  for the coinbase and okx families) is registered for any of them; none is a
  first-class venue, so none is provisioned. `myokx` and `okxus` share okx's
  signer but are distinct hosts/keys, so okx's live result does not transfer.
- What tier-2 already proved: each one's extracted `sign()` gates
  `body = this.json(...)` behind a params-emptiness test, so ccxt-js sends no
  body on a zero-param signed POST where we send `{}`. That is a compatibility
  fact about ccxt, not a correctness fact about the venue.
- The open question: does a signed zero-param private POST accept `{}`, or
  reject it before business validation? On the one venue we could reach (okx)
  the answer was the reverse of the fear — `{}` is required and bodyless is
  rejected — but that is one data point, not a catalog-wide proof.
- Exact call: issue the same authenticated zero-param private POST twice, once
  bodyless (signing without the body, as ccxt-js does) and once with `{}`
  (signing with it), and compare. Use a POST whose required params are absent
  so validation fails harmlessly — zero params cannot create an order.
- Expected evidence: both HTTP statuses and exchange responses. Only a
  body-shape rejection of `{}` that a bodyless request avoids would justify an
  authored `json_when_present` contract value.

### okx — populated funding-payment history and status error surface (task 388, filed 2026-07-19)
- Authored slices: `okx:normalization.field_maps.funding_history`
- Blocked by: the provisioned EEA demo key has no funding-payment bill rows. Its signed
  `fetchFundingHistory(BTC/USDT:USDT)` call succeeds with `[]`; creating a funding event needs an
  open perpetual position across a funding settlement and is outside the standing no-mutation
  policy. The zero-argument public system-status endpoint has no parameter whose invalid value can
  produce a venue business error without changing an exchange-wide state.
- What tier-2 already proved: fixture #24 parses a populated funding bill (`billId`, `balChg`,
  `ccy`, `ts`) and fixture #39 parses the normal empty-data status envelope. C-T388a/C-T388d
  confront those fields with the OKX API documentation; live demo confirms the funding route
  accepts the signed request and live public status returns `code: "0"`.
- The open question: does a current populated funding bill still use `balChg` as the payment amount
  and `ts` as the event time, and does the status endpoint emit a nonzero business envelope during
  a real maintenance/degradation event?
- Exact call: against a production or demo account with a settled perpetual funding payment,
  `Bourse.fetch_funding_history(ex, "BTC/USDT:USDT", limit: 1)`; during an official OKX status
  incident, `Bourse.fetch_status(ex)` and retain the returned body.
- Expected evidence: one nonempty `FundingHistory` row whose id/amount/currency/timestamp equal
  `billId`/`balChg`/`ccy`/`ts` in the same raw row; a nonzero status code remains a typed error and
  never becomes `%{status: "ok"}`.
- Also unreachable — a **populated status maintenance window**. OKX only emits `data` rows during a
  scheduled or ongoing maintenance event, which cannot be summoned on demand, and the CCXT static
  fixture #39 carries `data: []`. The per-row branch (C-T388d: `ongoing` → `maintenance`, other
  states → `ok`, `eta` from `end`, `url` from `href`) is therefore authored from the OKX schema and
  pinned by offline unit tests only. Close this entry by capturing `Bourse.fetch_status(ex)` during
  the next announced OKX maintenance window and confirming the row fields and resolved status.

### okx — place/cancel order lifecycle on a trade-enabled host (task 363, C-T363, filed 2026-07-18)
- Authored slices: `okx:normalization.field_maps.order`
- Blocked by: an OKX key/host outside the EEA local-compliance restriction. EEA demo
  (`my.okx.com`) accepts the signed, shaped `POST /api/v5/trade/order` request but returns its
  per-operation error row with `sCode: 51155` before an order can rest (observed 2026-07-18).
- What tier-2 already proved: the authored order map follows the documented order-details/history
  fields; static fixtures and the bundled CCXT execution cover compatible identifiers, states,
  clocks, and fill vocabulary. The sparse action acknowledgement deliberately retains only the
  fields the venue supplies.
- The open question: does a current successful place acknowledgement remain sparse, and does its
  subsequent order-details row preserve `cTime`, `uTime`, `fillTime`, `state`, `sz`, and
  `accFillSz` with the documented meanings?
- Exact call: place a far-from-market post-only `BTC-USDT` demo/prod order through
  `Bourse.create_order(ex, "BTC/USDT", "limit", "buy", amount, price: far_price, postOnly: true)`,
  fetch it with `Bourse.fetch_order(ex, id, symbol: "BTC/USDT")`, then always
  `Bourse.cancel_order(ex, id, symbol: "BTC/USDT")` in `after` cleanup.
- Expected evidence: place acknowledgement has `ordId`/`clOrdId`/`sCode`/`sMsg` without invented
  order fields; fetch returns a populated live row; cancel succeeds (or a typed order-not-found
  error if the order filled before cleanup).
- Re-confirmed 2026-07-19 (task 385 review): with the singular `trade/order` routing and authored
  body in place, both `BTC/USDT` (spot) and `BTC/USDT:USDT` (swap) far-from-market limit creates
  reach `sCode: 51155` — the venue parses the body and rejects on compliance policy, so the
  malformed-body `50002` is gone. A *successful* place (code 0 + `ordId`) stays unreachable on
  this key, so the create/amend slices remain tier-2-labeled until this entry closes.

### okx — fetchCurrencies fee/precision rollup on `/api/v5/asset/currencies` (task 311, C-T311, filed 2026-07-18)
- Authored slices: `okx:normalization.field_maps.currency`
- Blocked by: prod okx key (read suffices) — the endpoint is demo-unavailable: live EEA demo (`my.okx.com`) returns "This feature is unavailable in demo trading" (typed exchange_error, observed 2026-07-18; carve register C17a).
- What tier-2 already proved: authored rollup (min `fee` over `canWd: true` chains only, DIVERGE from CCXT's all-rows minimum) confronted against the OKX asset-currencies docs (tier-1 semantic source); divergence contract C-T311 gates the fixture case.
- The open question: does a *current* live payload still carry `canWd: false` rows with lower `fee` than any withdrawable route (i.e. does the divergence stay material), and is `wdTickSz` still the withdrawal precision source?
- Exact call: `Bourse.fetch_currencies(ex)` against `www.okx.com`; slice BTC: per-chain `canWd`/`fee`/`wdTickSz` vs unified `fee`/`precision`.
- Expected evidence: unified `fee == min(fee over canWd: true rows)` recomputed from the same live payload; `networks` map retains every chain row.

### bybit — fetchTransfers `coin=` / fetchConvertTrade `quoteTxId=` semantics (task 313, filed 2026-07-17; extended for task 347 / C-T347, 2026-07-18)
- Blocked by: a populated transfer row plus enough convertible balance for a real quote. The
  write-enabled production key was confirmed live on 2026-07-23; `coin=USDT` returned `retCode
  0` with an empty list, while a non-executing 1 USDT → USDC quote reached balance validation
  and returned "Available Balance is insufficient". No conversion was executed.
- What tier-2 already proved: request shape/signing/transport reach the venue (real business errors on both hosts); CCXT static fixtures pin `?coin=USDT` / `?quoteTxId=…` as the wire form; task 347's authored binding sends `{"quoteTxId": <unified id>}` as the sole `convert-execute` body field (Bybit confirm-quote docs, C-T347), verified offline via RequestShape.
- The open question: does Bybit prod actually accept and *filter by* `coin=USDT` on `/v5/asset/transfer/query-inter-transfer-list`, echo `quoteTxId` on convert-trade lookup — and does `POST /v5/asset/exchange/convert-execute` accept a real (fresh, unexpired) `quoteTxId` as its only body field?
- Exact call: `Bourse.fetch_transfers(ex, code: "USDT", params: %{"limit" => 5})`, `Bourse.fetch_convert_trade(ex, "<real quoteTxId>")`, and `Bourse.fetch_convert_quote(ex, "USDT", "BTC", 10)` → `Bourse.create_convert_trade(ex, quote.id, "USDT", "BTC", 10)` against `api.bybit.com` (tiny amount; convert is a swap, not an order — venue-final).
- Expected evidence: `retCode 0`; transfer rows all `coin == "USDT"`; convert lookup echoes the requested `quoteTxId`; convert-execute returns `retCode 0` with the same `quoteTxId` echoed (or a quote-expired business error — either proves the binding is read by the venue).

### binance — capital deposit/withdraw transaction histories and apply acknowledgement (task 335, filed 2026-07-18)
- Authored slices: `binance:normalization.field_maps.transaction`
- Blocked by: a populated production history row and an explicitly approved withdrawal target.
  The production key reached both history endpoints on 2026-07-23, but both returned empty lists;
  withdrawals remain disabled on the key and no apply mutation was attempted.
- What tier-2 already proved: the three CCXT static fixture cases replay against the authored maps; the Binance Wallet API endpoint schemas were confronted in C-T335. This is compatibility plus documented semantics, not live reality.
- The open question: do current production rows retain the documented status vocabulary, `insertTime`/`applyTime` meanings, `transactionFee` ownership, and sparse `{id}` apply acknowledgement shape?
- Exact call: `Bourse.fetch_deposits(ex, code: "USDT")`, `Bourse.fetch_withdrawals(ex, code: "USDT")`, then an operator-approved minimal `Bourse.withdraw(ex, "USDT", amount, address, tag: tag, network: "TRC20")` against `api.binance.com`.
- Expected evidence: a non-empty history row proves every mapped field against one live payload; a deliberately invalid signed read or apply request produces a typed Binance error; a successful apply acknowledgement supplies only `id` until its history row becomes available.

### binance — `asset/dust` single-field execution confirmation (task 349, C-T349, filed 2026-07-23)
- Authored slices: `binance:auth.sign_recipe.sapi`
- Blocked by: explicit approval for a venue-final dust conversion plus Spot & Margin Trading
  permission on the production key. The key reported that permission disabled on 2026-07-23.
- What provider authority proved: Binance's current Dust Transfer contract defines one string
  field and uses `asset=BTC,USDT`; offline signing and full Dispatch tests pin the exact
  `/asset/dust` dialect without changing ordinary JSON-array queries.
- What live traffic proved: signed `/asset/dust-btc` preview returned eligible ADA and EUR
  rows. No `/asset/dust` mutation was sent.
- The open question: does production accept the URL-encoded single field
  `asset=ADA%2CEUR` under a trade-enabled key and return the documented `tranId` envelope?
- Exact call: preview again, choose only operator-approved assets, then call
  `Bourse.Binance.sapi_post_asset_dust(ex, %{"asset" => ["ADA", "EUR"]})` once and compare the
  returned `transferResult` with post-call dust history. There is no amount cap.
- Expected evidence: HTTP 200, one `tranId`, and result rows only for the named assets; the
  request carries one decoded `asset` field, never repeated keys or a JSON array.

### binance — borrow-interest requests/responses and Convert quote response (tasks 323/452, filed 2026-07-21)
- Authored slices: `binance:normalization.field_maps.borrow_interest`, `binance:normalization.field_maps.conversion`
- Blocked by: populated margin-interest state plus a production key authorized for Portfolio
  Margin and Convert. On 2026-07-23 the production cross-margin call was accepted but empty;
  isolated margin reached the venue and returned "Isolated margin account does not exist";
  Portfolio Margin and the non-executing Convert quote were rejected for missing permission.
- What tier-2 already proved: the task-323 recorded `fetchBorrowInterest` and
  `fetchConvertQuote` cases replay through the authored response slices. Task 452 additionally
  proves that cross, isolated, and portfolio fixture requests carry Binance's documented
  `asset`/`isolatedSymbol` names. Current Binance schemas independently confirm the `rows`
  interest envelope and the quote's amounts, validity timestamp, optional quote id, and forward
  ratio. C-T323c deliberately maps the documented ratio to `Conversion.price` where CCXT leaves
  it nil.
- What live traffic DID confirm (tier 1, 2026-07-21): public EAPI `GET /eapi/v1/mark` returned
  current option rows and the unified call normalized them into symbol-keyed Greeks. The Task
  452 single-symbol request sent `symbol=BNB-260722-515-C` and was accepted; the same shaped
  path with `BTC-991231-999999-C` returned Binance `-1121`. This closes C-T323b/C-T452a but
  supplies no signed evidence for the authenticated families.
- The open question: do current populated production interest rows retain the documented
  `principal`/`interest`/`interestRate` semantics, and does a funded Convert quote preserve
  `ratio` as the forward quote rate while omitting the two asset codes from its response?
- Exact call: with a read-capable production key, call all three request shapes:
  `Bourse.fetch_borrow_interest(ex, code: "USDT", limit: 1)`,
  `Bourse.fetch_borrow_interest(ex, code: "USDT", symbol: "BTC/USDT", limit: 1)`, and
  `Bourse.fetch_borrow_interest(ex, code: "USDT", limit: 1, portfolioMargin: true)`. With an
  operator-approved small quote window, call `Bourse.fetch_convert_quote(ex, "USDC", "USDT", 5)`
  without accepting it.
- Expected evidence: one `%Bourse.BorrowInterest{margin_mode: "cross"}` whose amounts and clock
  equal the same raw row, plus one `%Bourse.Conversion{from_currency: "USDC", to_currency:
  "USDT"}` whose `price` equals the raw `ratio` and whose amount ratio agrees within the
  venue's published precision. A quote
  request is non-executing; do not call `acceptQuote`.

### derive — position accounting fields on a live row (task 316, filed 2026-07-17)
- Authored slices: `derive:normalization.field_maps.position`
- Blocked by: safely unwindable demo liquidity. On 2026-07-23 subaccount 144422 had 0 positions,
  0 open orders, 0.02 ETH and no USDC; ETH-PERP exposed a bid but no ask. Opening a position
  could not be guaranteed to unwind, so no mutation was attempted.
- What tier-2 already proved: docs.derive.xyz field semantics verified verbatim (WebFetch, 316 review); fixture raw `httpResponse` carries all six values; C-T316a pins them.
- The open question: on a *live* open position, are `realized_pnl`, `cumulative_funding`, `pending_funding`, `total_fees`, `net_settlements`, `average_price` populated with the documented semantics (esp. `average_price` non-null where CCXT parses null `entryPrice`)?
- Exact call: open a far-from-market limit order → filled position not required for most fields; then `Bourse.fetch_positions(ex, params: %{"subaccount_id" => 144422})` against `api-demo.lyra.finance`; close/cancel in the same session.
- Expected evidence: the six fields non-null on the live row; `average_price` populated while CCXT-JS `parsePosition` yields null `entryPrice` (confirming the DIVERGE).

### binanceusdm — conditional order types on `/fapi/v1/batchOrders` (task 332, C-T332, filed 2026-07-17)
- Blocked by: prod binanceusdm key with trade perms. Testnet refuses the whole conditional family on this endpoint, so it cannot confirm *or* falsify the authored element shapes — there is no host we can reach that accepts them.
- What tier-2 already proved: the element shapes follow Binance's own USD-M New Order required-field table (C-T332); the LIMIT element reproduces the CCXT static request fixture byte-for-byte; MARKET is tier-1 confirmed live (`-4164` business validation, valid symbol).
- The open question: does **prod** `batchOrders` accept STOP / TAKE_PROFIT / STOP_MARKET / TAKE_PROFIT_MARKET / TRAILING_STOP_MARKET at all, or has Binance moved conditional orders to the Algo Order API for batch as well? Observed live 2026-07-17 on `testnet.binancefuture.com` with a valid `LTCUSDT` element: every one returns `-4120` "Order type not supported for this endpoint. Please use the Algo Order API endpoints instead.", while LIMIT/MARKET in the same shape reach `-4164`. If prod agrees, the authored conditional shapes are dead code and `createOrders` should route those types to the Algo Order API (or reject them client-side with a pointer) rather than emit an element the venue always refuses.
- Exact call: `Bourse.Unified.call(ex, :create_orders, "createOrders", %{"orders" => [%{"symbol" => "LTC/USDT:USDT", "type" => "stop_market", "side" => "buy", "amount" => 0.1, "stopPrice" => 5000}]}, [])` against `fapi.binance.com` (buy stop far above market — non-triggering; cancel if it rests).
- Expected evidence: prod returns a *business* error (notional/precision/balance) or a resting order id → the shape is confirmed and the testnet `-4120` is a sandbox limitation. A prod `-4120` → the conditional family is genuinely unsupported on `batchOrders`; file the routing/reject follow-up and drop the shapes.

### okx — closePosition `posSide` mapping + fetchConvertTrade `clTReqId` binding (task 362, filed 2026-07-18)
- Blocked by: prod okx key outside EEA compliance scope — the EEA demo account (`my.okx.com`) returns 51155 "local compliance restrictions" on `/api/v5/trade/close-position` for every derivative pair (linear and inverse, observed 2026-07-18), which fires *before* posSide validation; convert endpoints return a stable 50026 "System error" on demo (two calls, same code — demo-unavailable class, same as C17a's asset-currencies).
- What tier-2 already proved: buy→long / sell→short posSide mapping and the net-mode omission (reviewer-hardened: unknown side rides through verbatim so OKX answers 51000 itself) green in RequestShape tests against OKX close-position docs; `fetchConvertTrade` binds unified `id` → `clTReqId` per authored spec. Live 2026-07-18: `fetchTransfer` tier-1 CONFIRMED (58129 names `transId` on a bogus id), `fetchMarginAdjustmentHistory` accepted live (`{:ok, []}` with `mgnMode=isolated`, `subType=160`).
- The open question: does OKX read `posSide` from our close-position body (expect 51169 no-position / 51000 posSide error on a long/short-mode account with no position), and does convert-trade lookup echo `clTReqId`?
- Exact call: `Bourse.Unified.call(ex, :close_position, "closePosition", %{"symbol" => "ETH/USDT:USDT", "side" => "buy", "mgnMode" => "cross"}, [])` and `Bourse.fetch_convert_trade(ex, "<real clTReqId>")` against `www.okx.com`.
- Expected evidence: close-position answers a posSide/position business error (not a params-shape error); convert lookup echoes the requested `clTReqId`.

### binance + binanceusdm — sapi/eapi request identifier bindings (task 341, C-T341a/C-T341b, filed 2026-07-18)
- Blocked by: a production Binance key with margin / wallet / gift-card / convert permissions. The provisioned testnet keys cannot reach these bases at all: CCXT's own `urls.test` map (vendored, `priv/specs/json/output/binance.json`) publishes only `public`/`private`/`v1` (spot `api/v3`) and the `fapi*`/`dapi*` futures bases — no `sapi` and no `eapi` — and binance.ts states it outright: *"sandbox/testnet does not support sapi endpoints"*.
- Task 386 (2026-07-19): `fetchConvertQuote` now shapes unified `from_code`/`to_code`/`amount` as Binance Convert's mandatory `fromAsset`/`toAsset` and optional `fromAmount`; an attempted signed sandbox call still stops locally at `No base URL for section sapi on binance (sandbox)`, before transport. Production Convert host/key evidence remains required.
- What tier-2 already proved: the order family is tier-1 CONFIRMED live (testnet `fetch_orders` success + `-2013` on a nonexistent order id, pinned by `binance_authored_integration_test.exs`). The sapi/eapi bindings are corroborated against CCXT's own recorded static request fixtures and, where a descriptor is vendored, against CCXT's `sign()`/request-build source — `fetchLedgerEntry` matches `{'recordId': id, 'currency': currency['id']}` and `fetchCrossBorrowRate` matches `{'asset': currency['id']}` verbatim. `setPositionMode` (`dualSidePosition`), `createGiftCode` (`token`/`amount`) and `borrowCrossMargin`/`repayCrossMargin` (`asset`/`amount`) have **no vendored CCXT descriptor** in this repo and rest on Binance's published endpoint docs only — the weakest evidence in this slice.
- The open question: do the native request names still hold on prod for the families testnet cannot serve — `asset`/`amount` on `/sapi/v1/margin/borrow-repay`, `asset` on `/sapi/v1/margin/interestRateHistory`, `asset`/`amount` on `/sapi/v1/asset/transfer`, `token`/`amount` on `/sapi/v1/giftcard/createCode`, `recordId`/`currency` on the eapi bill endpoint, and `dualSidePosition` as a `"true"`/`"false"` string on `/fapi/v1/positionSide/dual`?
- Exact call: against `api.binance.com` with a read-scoped prod key, the non-mutating members first — `Bourse.fetch_cross_borrow_rate(ex, "USDT")`, `Bourse.fetch_borrow_rate_history(ex, "USDT", limit: 1)`, `Bourse.fetch_ledger_entry(ex, "<real recordId>", "USDT")`; then, only under an operator-approved window, a minimal `Bourse.transfer(...)` and `Bourse.set_position_mode(ex, false)`. Mutating members stay deferred — task 341 deliberately sent no valid mutating request.
- Expected evidence: each read returns a populated row proving the venue accepted the mapped identifier, and a deliberately invalid identifier on the same endpoint returns a typed Binance business error (not a params-shape error) naming the mapped key.

### hyperliquid — vaultTransfer `usd` units on a live non-zero transfer (task 384, C-T384b, filed 2026-07-19)
- Authored slices: `hyperliquid:normalization.field_maps.transfer`
- Blocked by: a real vault the testnet wallet leads or is a depositor in, **plus** an operator-approved window to move funds. Every reachable falsification requires a *successful* transfer: a withdraw from a vault we are not in short-circuits on `"Vault not registered"` before the venue ever reads `usd`, and a deposit large enough to clear the vault minimum under the bare-USD reading would actually move money. There is no error path that echoes the interpreted amount.
- What is already proved: **semantics tier-1, non-CCXT** — the official Python SDK's own examples pass `5_000_000` for *"Transfer 5 usd"* (`examples/basic_vault_transfer.py`) and `1_000_000` for *"Transfer 1 USD"* on the identically-shaped `subAccountTransfer` (`examples/basic_sub_account.py`); the Rust SDK types the field `u64` (bare dollars could not express a cent). CCXT is self-inconsistent — it scales `subAccountTransfer` by 1e6 and leaves `vaultTransfer` bare. Live 2026-07-19: the branch reaches the venue as a signed `vaultTransfer` (venue answered its own vault error, not the bridge-withdraw error).
- The open question: does the venue credit `usd: 5_000_000` as $5.00 (confirming 1e6) rather than $5,000,000? i.e. is our DIVERGE from CCXT's bare value correct on the wire, not just in the SDK docs?
- Exact call: with a wallet that is a depositor in a testnet vault, `Bourse.withdraw(ex, "USDC", 5, "<vault>", vaultAddress: "<vault>")` (→ `usd: 5_000_000`), then read the vault equity / account balance delta before and after.
- Expected evidence: balance moves by **$5.00**, not $5,000,000 (rejected as insufficient) and not $0.000005. A $5,000,000-scale rejection or a micro-cent credit falsifies C-T384b and would restore CCXT's bare reading — in which case fixture #1144 comes *out* of the frozen baseline.

### derive — populated private funding-history row (task 594, C-T594h, filed 2026-08-12)
- Authored slices: `derive:normalization.field_maps.funding_history` (corrected 2026-08-12: venue `funding` is a signed dollar cashflow → unified `amount`; `rate` authored null because the response schema carries no rate field).
- Blocked by: the demo subaccount holds no perpetual position, so `private/get_funding_history` returns an empty `events` list. Producing a row requires holding a perp position across a funding boundary — outside the standing no-mutation policy.
- What tier-2 already proved: Derive's own API reference documents `funding` verbatim as "Dollar funding paid (if negative) or received (if positive) by the subaccount", string-typed, with `timestamp` in ms and no rate field. Live 2026-08-12: the signed call with `subaccount_id` succeeds (`{:ok, []}`), proving auth, routing and the empty-envelope parse; the missing-subaccount request reproduces venue error 14025.
- The open question: does a populated `events` row normalize to the correct signed USDC `amount`, symbol and ms timestamp — i.e. does the documented cashflow meaning hold on real settlement data?
- Exact call: with a demo subaccount that survived a funding boundary in a perp position, `Bourse.fetch_funding_history(ex, nil, params: %{"subaccount_id" => id}, limit: 10)`.
- Expected evidence: freeze and register the populated body; assert the parsed `amount` equals the raw `funding` string as a signed number, `rate` is nil, and the timestamp matches the raw ms value; upgrade C-T594h from resolved_tier 2 to 1.

## Closed

### deribit — option fill/hedge/unwind attestation (task 403; closed 2026-07-23, task 407 audit)
- Was blocked by: a venue-wide `test.deribit.com` 502 outage at the 2026-07-19 attestation
  (zero mutations attempted then).
- Evidence (live, 2026-07-23, testnet): full cycle green. Marketable limit buy 0.1
  `BTC/USD:BTC-260731-65000-C` filled @ 0.023 BTC (order `109140536259`, delta 0.521);
  same-venue inverse-perp hedge sell 3390 USD `BTC/USD:BTC` filled @ 65051.5
  (order `109140538245`); `PortfolioRisk.snapshot` `:complete` with both positions open;
  unwind — option sold (order `109140542503`), perp closed (order `109140544239`);
  `fetch_positions` and `fetch_open_orders` both empty after (`observed_at 1784812374201`).
  Durable row: `docs/option_readiness/option_readiness_1784812759202.json` (deribit
  `fill_ready`).

### okx (international demo) — option ATM fill + fills semantics (task 403; closed 2026-07-23, task 407 audit)
- Was blocked by: no genuinely two-sided ATM book on the intl demo at the 2026-07-19
  attestation.
- Evidence (live, 2026-07-23, `www.okx.com` + simulated-trading, `OKX_INTL_*`): fills ARE
  attainable — thin/slow, but real. Marketable buy 1 ct `BTC/USD:BTC-260724-66000-C`
  @ ask 0.0055 (tdMode isolated) partially filled **0.19 ct** before cancel
  (order `3768499744978354176`, avg 0.0055); coin-margined swap hedge sell 0.2 ct
  `BTC/USD:BTC` filled (order `3768502970633011200`); `PortfolioRisk.snapshot` `:complete`
  with both positions; unwind — venue rejects market close for options (error 51066 pinned
  live), reduceOnly **limit** sell 0.19 at bid filled (order `3768503829928460288`,
  closes below `minSz` 1), perp closed (order `3768503150753202176`); positions and
  open orders both zero after (`observed_at 1784812577099`). Durable row:
  `docs/option_readiness/option_readiness_1784812759202.json` (okx `fill_ready`).

### okx — populated swap position semantics (task 364; closed 2026-07-23)
- Evidence: the international demo (`www.okx.com`, simulated-trading header,
  `OKX_INTL_*` credentials) completed a reversible BTC-USDT-SWAP market open,
  populated `fetch_positions` / `fetch_position`, and `close_position` lifecycle.
- The former EEA-only follow-up is dropped: this project is not targeting the EEA
  entity, and C-T364a already records the international live row at tier 1.

### binanceusdm — order `last_trade_timestamp` stamp on FILLED (task 321, C-T321b; closed 2026-07-23)
- Evidence: an operator-approved reversible USD-M testnet cycle opened `0.002 BTC` on
  `BTC/USDT:USDT` and immediately closed the same LONG leg. Filled order `23444179805` returned
  `last_trade_timestamp = 1784766919776`; its sole matching `fetch_my_trades` row had the same
  maximum timestamp. Cleanup order `23444179883` left 0 active positions and 0 open orders.
- The account was in Hedge Mode, so Binance required `positionSide=LONG` and forbade
  `reduceOnly`; the close used the provider-documented opposite-side LONG-leg order without
  changing account mode.

### binance — fetchCurrencies rollups on `/sapi/v1/capital/config/getall` (task 319; closed 2026-07-23)
- Evidence: a signed production `Bourse.fetch_currencies/1` call returned 709 currencies. The
  live USDT row retained 19 network entries; unified `precision = 0.00001` equalled the maximum
  raw `withdrawIntegerMultiple`, and unified `fee = 0.01` equalled the minimum raw
  `withdrawFee` from the same payload.
- This confirms the current aggregate semantics against Binance's Wallet API; network-code
  aliases remain the separately-labelled tier-2 compatibility portion of C-T319.

### deribit — fetchDepositAddress parsed shape (task 380; closed 2026-07-22 by task 457)
- Evidence: the first verification move was a signed `Bourse.fetch_balance/1` call against
  `test.deribit.com`; the same authenticated capture run then recorded
  `private/get_current_deposit_address` on 2026-07-21 UTC at
  `test/fixtures/responses/deribit/fetch_deposit_address.json`.
- The real body carried a non-empty `result.address`, `result.currency == "BTC"`, and
  `result.type == "deposit"`, matching Deribit's provider-owned endpoint schema. The committed
  address is scrubbed to `***REDACTED***`; currency and type remain available as the semantic
  oracle.
- Offline tier-1 replay: `private_recorded_response_replay_test.exs` returns
  `%Bourse.DepositAddress{currency: "BTC", address: "***REDACTED***"}` and keeps the JSON-RPC
  envelope fields out of `info`. The focused Task-457 replay/fixture suite passed 63 tests.

### lighter — authenticated private call + auth-failure semantics (task 146; closed 2026-07-21)
- Was blocked by: the Lighter testnet account and account-authorized API signing key had not been provisioned under the environment names consumed by the integration test. The existing EVM test wallet was available; the review did not ask for it.
- Evidence (live, 2026-07-21): the official Lighter testnet faucet created account index 354 with test collateral, and the official Python SDK registered API-key index 3 using the wallet's local L1 signature. The SDK's `check_client()` then confirmed that the generated private key matched the public key registered by the venue.
- `mix test.json --quiet --include integration --include network test/bourse/lighter_signing_integration_test.exs` → 1/1 green. `private_get_accountlimits` returned a real successful response for account 354; repeating the call with a deliberately mutated signing key returned the typed `:authentication_error`. This closes both the success and relevant live-error sides of the signing boundary.
- The offline evidence remains independent of CCXT: `native/lighter_signer/golden_test.go` matches the pinned official Go implementation's fixed-entropy vectors, and `lighter_native_test.exs` exercises the real C ABI through the Elixir Port.

### alpaca — authored stocks slice live-verified (task 428, C-T428a/b/c; closed 2026-07-20)
- Was blocked by: no `ALPACA_API_KEY` / `ALPACA_API_SECRET` anywhere this repo runs; Alpaca's data API has no unauthenticated tier, so no success payload could be observed. Unblocked 2026-07-20: operator provisioned paper-account keys in `~/.secrets`.
- Evidence (live, 2026-07-20): `mix test.json --include integration --include network test/bourse/alpaca_authored_integration_test.exs` → 3/3 green against `data.alpaca.markets` with paper keys. `fetch_ohlcv("GLD", "1d")` and `fetch_ticker("GLD")` return populated unified structs from real 200s; `feed=iex` is accepted on a free paper key; the news payload carries `headline` + `symbols` containing `GLD`; invalid keys reproduce the recorded HTML-401 rejection live.
- The observed 200 bodies (bars + snapshot, `GLD`, `feed=iex`) are frozen as the real recorded fixtures in `alpaca_authored_slice_test.exs`, replacing the illustrative-valued payloads — exactly the freeze the open entry called for.
- The test did **not** go green unmodified; two reality-driven amendments were required, both honest reality, not weakened assertions:
  1. **Empty default window.** Without `start`, Alpaca's bar window defaults to the current day; on a weekend that returns HTTP 200 `{"bars": null, "symbol": "GLD", "next_page_token": null}`. This surfaced a real parser carve: a present-but-null envelope key is "no candles" (CCXT `safeList` semantics), not a shape error — fixed in `read_parse.ex` (`ohlcv_rows/2` + `null_at_path?/2`; note `ResponseTransformer.extract_path/2` returns the whole body on a nil value, so the null check must precede extraction) and pinned offline with the real null-bars body. The test now anchors `start` ten days back.
  2. **FX entitlement.** Paper accounts carry no FX data entitlement: `v1beta1/forex/latest/rates` answers HTTP 403 `{"message": "not authorized for FX data"}` (classified `:authentication_error`). The test pins that entitlement boundary as the reality this account can reach; a future FX-entitled key flipping it to 200 should assert the rates payload instead. C-T428 forex-rate domain fields therefore remain doc-shape-only — no reachable oracle on a free paper plan.

### okx demo — cancelOrders algo endpoint selection (task 440, confirmed 2026-07-20)
- EEA demo (`my.okx.com`, `sandbox: true`) accepted the signed `cancelOrders` request with
  `stop: true` and a deliberately nonexistent algo id. Request-start telemetry recorded
  `POST /api/v5/trade/cancel-algos`; OKX returned its normal business-error envelope
  (`Bourse.Error{type: :exchange_error, code: "1"}`), confirming that the unified selector
  reaches the algo route without mutating any order.
