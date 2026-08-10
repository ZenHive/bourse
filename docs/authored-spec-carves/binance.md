# Binance carve register

Append-only schema confrontations for Binance spot. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for this venue.** Historical narrative may still appear in `docs/authored-specs.md`;
this file is the complete Binance spot carve record.

## 2026-08-10 — futures cadence and generic USD-M routing (Tasks 573–576)

**C-T573a — Current funding rates join the provider's per-symbol cadence (task 573).
Outcome: CONFIRM venue.** Binance's official
[Funding Rate Info](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Get-Funding-Rate-Info)
contract publishes `fundingIntervalHours` for symbols whose cadence is adjusted; the eight-hour
default for non-adjusted symbols comes from Binance's own funding-rate settlement announcement
(binance.com/en/support/announcement/detail/6d707b1f7ae34f419621b4c807464ab1), not from the
endpoint contract itself. `fetchFundingRate` therefore joins its `premiumIndex` row to
`fundingInfo` by native symbol, normalizes the provider value to a duration token such as `4h`,
and uses `8h` only when the provider returns no adjusted row. Live demo FAPI returned `8h` for
BTCUSDT; the pre-change unified result had `interval: nil`.

**C-T574a — Conditional USD-M orders use the Algo Order API and preserve unified order
controls (task 574). Outcome: CONFIRM provider endpoint move.** Binance's official
[New Algo Order](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/New-Algo-Order)
contract places conditional orders at `POST /fapi/v1/algoOrder` with
`algoType=CONDITIONAL` and `triggerPrice`. Unified `trigger_price` and `stop_loss_price` select
that route; `time_in_force`, `reduce_only`, and the trigger reach the signed request. A live
stop-limit remained `NEW` with the requested trigger, `reduceOnly=true`, and `GTC`. The legacy
`POST /fapi/v1/order` returned provider error `-4120` directing clients to the Algo API.

**C-T574b — Margin-mode and cancel-all writes are symbol-scoped FAPI calls (task 574).
Outcome: CONFIRM venue.** The provider's
[Change Margin Type](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Change-Margin-Type)
contract requires `symbol` and `marginType` (`ISOLATED` or `CROSSED`); the
[Cancel All Open Orders](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Cancel-All-Open-Orders)
contract requires `symbol` and returns a `code=200` acknowledgement rather than an order.
Live calls changed ETHUSDT in both directions, canceled three resting FAPI orders, and returned
zero open orders afterward.

**C-T575 — `fetchBalance(type: :swap)` is the canonical generic-Binance USD-M wallet read
(task 575). Outcome: CONFIRM market-family routing.** On the multi-market `binance` client,
`:spot` selects `/api/v3/account`, `:swap` selects `/fapi/v3/account`, and
`:delivery` selects `/dapi/v1/account`; all three succeeded on their provider sandboxes.
`:margin` is a named sandbox exclusion because Spot Testnet exposes no SAPI host. The generic
`fetchSwapBalance` capability remains unsupported; consumers use `fetchBalance(type: :swap)`.
The accepted-request golden pins `demo-fapi.binance.com/fapi/v3/account`, preventing a silent
return to the Spot wallet.

**C-T576 — USD-M conditional orders use one unified lifecycle across the regular and Algo
books (task 576). Outcome: CONFIRM provider contracts; merged-read carve.** Binance's official
[Cancel Algo Order](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Cancel-Algo-Order),
[Cancel All Algo Open Orders](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Cancel-All-Algo-Open-Orders),
and [Current All Algo Open Orders](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Current-All-Algo-Open-Orders)
contracts keep conditional orders in a dedicated book at `algoOrder`, `algoOpenOrders`, and
`openAlgoOrders`. Unified `fetchOpenOrders` merges regular and Algo rows into one list;
`cancelOrder` tries the regular book and crosses to the Algo book only on Binance's typed
order-not-found response; `cancelAllOrders` sends the symbol-scoped cancellation to both books.
The provider's [New Algo Order](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/New-Algo-Order)
contract maps unified `take_profit_price` to `TAKE_PROFIT` or `TAKE_PROFIT_MARKET`, so it never
becomes a bare market order on `/fapi/v1/order`. Before the carve, a live unified cancel-all
returned `code=200` while the created Algo stop remained visible through the raw Algo endpoint.
After the carve, live futures-demo lifecycles created, fetched, and canceled a conditional order
through unified methods; a second conditional order disappeared after unified cancel-all.

<!-- carve-evidence-status
{"carve_id":"C-T573a","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M Funding Rate Info contract"},"observed_evidence":{"kind":"live_venue","reference":"Live demo-fapi BTCUSDT premiumIndex plus fundingInfo returned unified interval 8h on 2026-08-10"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T574a","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M New Algo Order contract"},"observed_evidence":{"kind":"recorded_venue","reference":"Live resting ETHUSDT conditional lifecycle plus test/fixtures/exchange_accepted_requests/binance/create_order.json; legacy endpoint error -4120 observed live"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T574b","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M Change Margin Type and Cancel All Open Orders contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"Live ETHUSDT margin changes and resting-order cancellation plus set_margin_mode/cancel_all_orders accepted-request goldens"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T575","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance Spot, USD-M Account Information V3, and COIN-M Account Information contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"Live spot/USD-M/COIN-M sandbox balance probes plus test/fixtures/exchange_accepted_requests/binance/fetch_balance.json"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T576","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M New Algo Order, Cancel Algo Order, Cancel All Algo Open Orders, and Current All Algo Open Orders contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"Live futures-demo unified create/fetch/cancel and create/fetch/cancel-all lifecycles plus test/fixtures/exchange_accepted_requests/binance/create_order.json and cancel_all_orders.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-04 — documented order-status coverage (Task 538)

**C-T538b — Spot order statuses cover Binance's complete published vocabulary (task 538).
Outcome: CONFIRM venue; documentation-anchored, live-unverified.** Binance's official
[order-status enum](https://github.com/binance/binance-spot-api-docs/blob/master/enums.md#order-status-status)
includes `PENDING_NEW`, `PENDING_CANCEL`, and `EXPIRED_IN_MATCH` in addition to the statuses
already authored. Pending states remain unified `open`; `EXPIRED_IN_MATCH` is terminal and maps
to unified `canceled`. The runtime-wide provider-status coverage test pins the complete list.

<!-- carve-evidence-status
{"carve_id":"C-T538b","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"Binance Spot API order-status enum"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No live order-history row carrying PENDING_NEW, PENDING_CANCEL, or EXPIRED_IN_MATCH is registered"}
-->

## 2026-07-30 — Spot Testnet trading-fee boundary (Task 530)

**C-T530c — Spot Testnet cannot serve the bulk SAPI trading-fee route (task 530).
Outcome: CONFIRM venue and preserve an explicit environment-scoped unsupported
contract.** Binance's official
[Spot API repository](https://github.com/binance/binance-spot-api-docs#spot-testnet)
states that Spot Testnet supports `/api/*` endpoints and does not support `/sapi/*`.
The production bulk fee route remains `/sapi/v1/asset/tradeFee`; a sandbox call therefore
returns the explicit `No base URL for section sapi on binance (sandbox)` contract rather
than a bare capability failure caused by accidental routing. Binance's
[Query Commission Rates](https://github.com/binance/binance-spot-api-docs/blob/master/rest-api.md#query-commission-rates-user_data)
endpoint at `/api/v3/account/commission` is reachable on Spot Testnet but requires one
symbol, so it is not a bulk replacement. Live Spot Testnet traffic on 2026-07-30 confirmed
a populated BTCUSDT commission response and `-1121` for an invalid symbol.

## 2026-07-26 — market-scoped error boundary (Task 515)

**C-T515a — Binance's heterogeneous raw exception maps stay outside the spot-authored contract
(task 515). Outcome: DIVERGE from treating the raw projection as provider-authored.**

The spot-owned `errors.handle_errors.exceptions` slice deliberately retains only its authored
top-level map. `priv/authority/binance/errors.json` does not enumerate derivative-only codes, so
lifting `linear`, `inverse`, `option`, or `portfolioMargin` wholesale from
`raw.describe.exceptions` would falsely promote a CCXT compatibility projection to Binance spot
authority. Runtime still selects those frozen raw maps by the API family actually called:
`api`/`sapi` → spot, `fapi` → linear, `dapi` → inverse, `eapi` → option, and `papi` → portfolio
margin. Their class targets remain tier-2 compatibility data unless the owning venue register
confronts them separately.

## 2026-07-22 — market maker/taker + filter precision/limits (Task 164)

**C-T164a — Public market maker/taker come from Binance's published fee schedule, not
exchangeInfo and not private tradeFee (task 164). Outcome: CONFIRM venue; DIVERGE from
treating CCXT `this.fees` / member coercion as an authority.**

- *Exchange semantics (non-CCXT):* `GET /api/v3/exchangeInfo` (and fapi/dapi siblings) publish
  instruments with `filters[]` and asset/precision fields — **no** maker/taker rates on the
  symbol row. Account-specific rates live on private surfaces (`GET /sapi/v1/asset/tradeFee`
  for spot; futures account fee tier on private account endpoints). Binance's public fee
  schedules document the base (VIP 0) maker/taker rates that apply before account discounts:
  [Spot & Margin](https://www.binance.com/en/fee/trading),
  [USDⓈ-M Futures](https://www.binance.com/en/fee/futureFee), and
  [COIN-M Futures](https://www.binance.com/en/fee/deliveryFee).
- *CCXT's carve (compatibility reference only):* `parseMarket` fills maker/taker from the
  static `this.fees` table (`fees.trading` / `fees.linear.trading` / `fees.inverse.trading`);
  the distill-era member path `"fees.trading.maker"` was a **static table read**, not a
  response path — never a venue payload field.
- *Our carve:* for public `%Bourse.Market{}` rows, author the VIP-0 schedule into the owned
  `fees` block and apply it after market-family flags are known:
  spot → `fees.trading` (0.001 / 0.001), linear → `fees.linear.trading` (0.0002 / 0.0005),
  inverse → `fees.inverse.trading` (0.0001 / 0.0005), plus `percentage` / `tier_based` from
  the same schedule. Private VIP overrides remain a separate `fetch_trading_fees` surface
  (task 164 out of scope). CCXT's table is cited only as the mechanical projection that
  seeded `fees.*`; the authority is Binance's published schedule + the absence of fee fields
  on exchangeInfo.
- *Evidence sources:* live testnet `Bourse.fetch_markets` on binance (first verification move —
  see completion note); recorded `test/fixtures/responses/binance/fetch_markets.json`
  exchangeInfo bodies carry filters without fee fields; offline regression in
  `test/bourse/binance_authored_spec_test.exs`.
- *Implementation:* 164.

**C-T164b — Market precision and limits derive from the instrument's own `filters[]`;
precision values are tick sizes, not digit counts (task 164). Outcome: CONFIRM venue
(extends C8).**

- *Exchange semantics (non-CCXT — Binance filters docs + live/recorded exchangeInfo):*
  - price increment = `PRICE_FILTER.tickSize`; price min/max = `minPrice` / `maxPrice`
  - quantity increment = `LOT_SIZE.stepSize`; amount min/max = `minQty` / `maxQty`
  - market-order size bounds = `MARKET_LOT_SIZE.minQty` / `maxQty`
  - cost min = spot `NOTIONAL.minNotional` or futures `MIN_NOTIONAL.notional`; cost max =
    `NOTIONAL.maxNotional` when present
  Top-level `baseAssetPrecision` / `quotePrecision` / `pricePrecision` /
  `quantityPrecision` are **digit counts** for different concerns (base/quote asset
  decimals or display); they are not the order-grid tick. Flat `minQty`/`tickSize` keys do
  **not** exist on the instrument root — they live only inside `filters[]`.
- *Our carve:*
  1. `precision.price` / `precision.amount` continue to read `filters[]` via
     `collection_member` (C8) — values are **tick sizes** (e.g. `0.01`, `1e-5`), not
     decimal-place integers.
  2. `precision_mode: "tick_size"` is stamped on every market row so Order.Sanity and
     consumers treat those numbers as increments (task 489 doctrine / C1 ontology).
  3. `limits.amount` / `limits.price` / `limits.cost` / `limits.market` also read the matching
     `filters[]` members — never hardcoded per-symbol tables and never the digit-count
     fields. Cost filter matching prefers `NOTIONAL` then `MIN_NOTIONAL`, with
     `minNotional` falling back to `notional`.
- *Compatibility cost:* aligns with CCXT static markets goldens for BTC spot/linear/inverse
  fee rates and filter-derived limits; the ontology stamp `precision_mode` is ours (C1).
- *Evidence sources:* Binance's [symbol filters documentation](https://developers.binance.com/en/docs/products/spot/filters),
  [USDⓈ-M exchange information](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/market-data#exchange-information),
  and [COIN-M exchange information](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-coin-m-futures/api/rest-api/market-data#exchange-information);
  live testnet fetch_markets; recorded exchangeInfo fixture pin + unit tests for ordered
  `match_values` / `fallback_keys` on collection_member.
- *Implementation:* 164.

## 2026-07-22 — fetchOHLCV response envelope resolved by absence (post-449 sweep)

**C-T449a — fetchOHLCV needs no response envelope: `/api/v3/klines` returns the bare
kline array (task 449 post-land sweep). Outcome: CONFIRM venue; the shipped
`_unresolved_reason: "no_safe_value_call"` marker was extraction residue, removed.**

- *Exchange semantics (non-CCXT):* Binance's
  [Kline/Candlestick data](https://developers.binance.com/en/docs/products/spot/websocket-api/market-data-requests#klines)
  REST endpoint (`GET /api/v3/klines`) responds with a top-level JSON array of kline rows —
  there is no wrapping object, so there is no envelope key to author. The family sibling
  `binanceusdm` already records this state as an absent `response_envelopes.ohlcv` entry.
- *CCXT's carve (compatibility reference only):* CCXT's `fetchOHLCV` passes the response
  straight to `parseOHLCVs`; the distill marker `no_safe_value_call` recorded only that no
  `safeValue` unwrap exists — an extraction observation, not an unresolved venue question.
- *Compatibility cost:* none — the runtime envelope layer already treated the marker-only
  entry as no-unwrap, so behavior is unchanged; the entry now states the decision instead
  of an open question (and the task-449 promotion gate no longer flags binance).
- *Evidence sources:* live testnet `Bourse.fetch_ohlcv` (bare array observed); binance
  per-venue fixture replay gate green on the edited spec at the time (that gate is since
  retired — the reality oracle in `check.dispatch` is `mix ccxt.oracle_gate`).
- *Implementation:* post-449 orchestrator sweep (this entry).

## 2026-07-22 — response 4.5.65 currencies adjudication (Task 442)

**C-T442a — Per-network `active` preserves Binance's deposit and withdrawal availability
(task 442). Outcome: DIVERGE from CCXT 4.5.65; CONFIRM venue.**

- *Exchange semantics:* Binance's [All Coins' Information](https://developers.binance.com/en/docs/catalog/core-trading-wallet/api/rest-api/capital#all-coins-information)
  schema defines independent `depositEnable` and `withdrawEnable` booleans on every
  `networkList` row. The recorded Binance responses carry those booleans on every network.
- *Our carve:* retain the existing `active_requires_both: true` summary: a network is active
  only when both directions are available, while `deposit` and `withdraw` preserve each
  direction separately. CCXT 4.5.65 leaves per-network `active` undefined, discarding a
  provider-owned availability fact.
- *Numeric-rendering check:* the Binance, Bybit, and OKX cases share no numeric coercion defect.
  Replay comparison treats numerically equal integers and floats recursively as equivalent;
  the only currency mismatch is `active`.
- *Retired compatibility-baseline inventory:* two deliberate divergences were tied to this
  carve: `fetchCurrencies default #112` and `fetchCurrencies default #164`.

## 2026-07-22 — Explicit currency `active` rollup declaration (Task 482)

**C-T482a — Binance declares `active_requires_both: true` for chain-derived network active
(task 482). Outcome: CONFIRM venue; extends C-T442a without superseding it.**

- *Exchange semantics:* `depositEnable` and `withdrawEnable` remain independent provider-owned
  booleans on each `networkList` row (All Coins' Information). Neither field alone means the
  chain is fully fundable.
- *Our carve:* keep the authored AND rollup as an **explicit** first-class decision on the
  `currency_networks` rule (`active_requires_both: true`). Currency-level `active` continues
  to come from coin-level `trading` (C-T319) — it is not chain-derived, so it is outside the
  flag. Cross-venue rule C-T482 forbids inheriting the OR default on first-class maps.
- *C-T442a status:* still true (per-network deliberate divergence from CCXT); not rewritten.

## 2026-07-22 — COIN-M position ratios and precision (Task 438)

**C-T438b — COIN-M `fetchPositions` does not synthesize margin metrics absent from Position
Information rows (task 438).** Outcome: DIVERGE from Bourse. The
[COIN-M Position Information](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-coin-m-futures/api/rest-api/trade#position-information)
authority states position amount, prices, unrealized profit, leverage, margin type, and isolated
margin; it does not state initial margin, maintenance margin, margin ratio, or percentage PnL. A
signed testnet `GET /dapi/v1/positionRisk` on 2026-07-22 likewise returned family-native rows with
`notionalValue` but none of those four derived fields. The provisioned COIN-M wallet had no active
position, so the authority supplies the populated-position semantic while the live call pins the
wire schema. We leave `maintenance_margin`, `maintenance_margin_percentage`, `margin_ratio`, and
`percentage` nil rather than assuming a universal 0.4% maintenance tier or deriving ROI through
an unstated initial margin. CCXT's inverse fixture values are deliberate tier-2 compatibility
divergences.

## 2026-07-21 — BorrowInterest and AllGreeks request shapes (Task 452)

**C-T452a — `fetchAllGreeks` sends one native `symbol` and keeps multi-symbol filtering
client-side (task 452).** Outcome: CONFIRM VENUE, tier 1. Binance's
[Option Mark Price schema](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-options/api/rest-api/market-data#option-mark-price)
accepts one optional `symbol`; it does not define a `symbols[]` query. The authored shape converts
an exactly-one `symbols` list to the native option id and omits the list otherwise, leaving
multi-symbol filtering to the response layer. CCXT-JS makes the same compatibility choice, but
the Binance schema is the semantic authority. A safe live call on 2026-07-21 accepted
`BNB/USDT:USDT-260722-515-C` as native query `BNB-260722-515-C`; the same shaped path with
`BTC-991231-999999-C` returned Binance error `-1121`.

**C-T452b — `fetchBorrowInterest` binds unified filters to the selected margin-account
schema (task 452).** Outcome: CONFIRM VENUE, tier 2 pending a production margin account.
Binance's
[Margin Interest History schema](https://developers.binance.com/en/docs/catalog/core-trading-margin-trading/api/rest-api/borrow-repay)
defines `asset`, `isolatedSymbol`, `startTime`, `endTime`, and `size`: omitting
`isolatedSymbol` selects cross-margin history, while including it selects the isolated pair. The
[Portfolio Margin interest-history schema](https://developers.binance.com/en/docs/catalog/advanced-trading-derivatives-trading-portfolio-margin/api/rest-api/account#get-margin-borrow-loan-interest-history)
uses the same five query fields on PAPI. The authored shape therefore maps `code`, `symbol`,
`since`, `until`, and `limit` to those venue names after endpoint selection consumes
`portfolioMargin`. CCXT-JS is used only to check compatibility with the frozen fixtures. Safe
live calls proved the current testnet capability boundary rather than the signed transport:
cross and isolated calls return `No base URL for section sapi on binance (sandbox)`, and the
portfolio call returns the corresponding `papi` error. Exact deferred calls are in the
production verification ledger.

## 2026-07-21 — borrow interest, option greeks, and Convert quote responses (Task 323)

**C-T323a — `fetchBorrowInterest` selects and parses the account family explicitly
(task 323).** Outcome: CONFIRM VENUE, tier 2 pending a production account. Binance's
[Portfolio Margin interest-history schema](https://developers.binance.com/en/docs/catalog/advanced-trading-derivatives-trading-portfolio-margin/api/rest-api/account#get-margin-borrow-loan-interest-history)
returns `rows` containing `asset`, `principal`, `interest`, `interestRate`, and
`interestAccuredTime`; the authored selector uses that PAPI endpoint only when
`portfolioMargin: true` and otherwise retains the SAPI margin-history endpoint. A row with
`isolatedSymbol` is isolated margin; its absence is cross margin. This endpoint-scoped
derivation matches CCXT and does not invent a symbol for portfolio/cross rows. The provisioned
spot-testnet key cannot reach PAPI or SAPI, so populated-row live confirmation remains in the
production verification ledger.

**C-T323b — EAPI mark rows are option greeks (task 323).** Outcome: CONFIRM VENUE, tier 1.
Binance's
[Option Mark Price schema](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-options/api/rest-api/market-data#option-mark-price)
defines `symbol`, `markPrice`, `bidIV`, `askIV`, `markIV`, `delta`, `theta`, `gamma`, and
`vega`. A safe live `GET /eapi/v1/mark` on 2026-07-21 returned 1,454 rows with those fields and
native ids such as `BTC-260925-145000-C`; the public integration test pins a populated
symbol-keyed `%Bourse.Greeks{}` result and Binance's `-1121` invalid-symbol error. The EAPI
endpoint family is therefore authored as `:option` for reverse symbol conversion. Binance's
`highPriceLimit`, `lowPriceLimit`, and `riskFreeInterest` remain intact in `info` because the
unified Greeks type has no corresponding fields. There is no deliberate CCXT divergence.

**C-T323c — Convert quote request context and price ratio (task 323).** Outcome: DIVERGE from
CCXT on `price`, tier 2 pending production transport. Binance's
[Send Quote Request schema](https://developers.binance.com/en/docs/catalog/core-trading-convert/api/rest-api/trade#send-quote-request)
returns optional `quoteId`, `validTimestamp`, `fromAmount`, `toAmount`, `ratio`, and
`inverseRatio`, but does not echo `fromAsset` or `toAsset`. The unified conversion therefore
takes currencies from the request, maps the two amounts and validity timestamp from the body,
and leaves an absent quote id nil. Binance defines `ratio` as the forward price ratio on its
Convert response family (the forward quote rate, approximately `toAmount / fromAmount` within
the venue's published precision), so `Conversion.price` is authored from `ratio`. CCXT's
`parseConversion` leaves that field nil; the deliberate
divergence is contracted under C-T323c rather than discarding venue-stated price information.
Spot testnet has no SAPI host, so the populated response remains tier-2-labelled in the ledger.

## 2026-07-19 — COIN-M position value axes (Task 334)

**C-T334b — COIN-M `fetchPositions` derives contract size from Exchange Information, not the
native-symbol spelling (task 334).** Outcome: tier 2 pending a funded COIN-M testnet account. The
[COIN-M Position Information](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-coin-m-futures/api/rest-api/trade#position-information)
row supplies `positionAmt`, `notionalValue`, margin fields and `marginType`, while the exchange
information market record supplies the contract unit. We therefore read `contract_size` from the
caller-threaded market cache rather than assuming every `*USD_PERP` contract is USD 100. The
position's `notional` preserves the absolute `notionalValue` settlement amount and initial and
maintenance margin remain distinct values. Cross collateral is nil unless the response itself
states it; `isolatedMargin` is collateral only for `marginType: isolated`. The static CCXT inverse
fixture remains compatibility evidence only until the ledger entry below is closed.

## 2026-07-19 — dormant futuresTransfer / verifyGiftCode request slots (Task 418)

**C-T418a — Binance `futuresTransfer` request bindings (task 418).** Outcome: CONFIRMED against
CCXT JS (`binance.ts` `futuresTransfer`, `@ignore` internal helper). CCXT builds
`{asset: currency['id'], amount, type}` for `sapiPostFuturesTransfer` from the method args
`(code, amount, type)`. We do **not** expose `futuresTransfer` on the unified API (transfer
semantics stay on unified `transfer`, which already binds `asset` ← `code`); the shape entry is
kept at the shaping layer only so the task-267 request-shape sweep stays green. Authored
optional sources: `asset` ← `code`, `amount` ← `amount`, `type` ← `type`. Source class is
`optional` because the method is not in `method_defs/0` (so `unified_param` source validation
would reject the bindings).

**C-T418b — Binance `verifyGiftCode` request binding (task 418).** Outcome: CONFIRMED against
CCXT JS (`binance.ts` `verifyGiftCode`). CCXT maps the method arg `id` to native `referenceNo`
for `sapiGetGiftcardVerify`. We do **not** expose `verifyGiftCode` on the unified API (gift-card
create is the only gift method in `method_defs/0`). Authored optional source: `referenceNo` ←
`id`. Same optional source-class rationale as C-T418a.

## 2026-07-19 — default_family spot for multi-endpoint no-arg reads (Task 378)

**C-T378d — Binance spot `default_family: "spot"` (task 378).** Outcome: CONFIRMED. The spot
venue's multi-endpoint unified list often puts COIN-M `dapi*` configs first; without an authored
default, bare `hd(configs)` mis-routes no-arg reads off the spot surface. Authored
`config.default_family: "spot"` plus per-method `endpoint_selection` defaults (and linear/inverse
rules where the method also covers futures) pin the no-arg fall-through. Cross-venue mechanism:
C-T378a/b.

## 2026-07-19 — Convert quote request sources (Task 386)

**C-T386 — `fetchConvertQuote` asset bindings (task 386).** Outcome: CONFIRM VENUE. Binance's
[Convert API quote endpoint](https://developers.binance.com/docs/convert/trade)
requires `fromAsset` and `toAsset`, and accepts either `fromAmount` or `toAmount`.
The authored request shape binds the unified `from_code`, `to_code`, and `amount`
arguments to `fromAsset`, `toAsset`, and `fromAmount`; it does not retain the
unified snake_case keys on the wire. This corrects inherited camel-case source
labels that silently omitted both mandatory asset fields. Spot testnet has no
`sapi` base URL, so production transport confirmation remains tracked in the
verification ledger.

## 2026-07-18 — request identifier bindings (Task 341)

**C-T341a — Binance spot request identifiers (task 341).** Outcome: CONFIRM VENUE, no divergence from Bourse.
The authored bindings retain Binance's native request names while sourcing asset identifiers from
unified `code`, order filters from `symbol`, records from `id`, and position mode from `hedged`.
Binance's Spot REST documentation identifies `symbol` as the order-query filter and documents
`-2013` for an unknown order; the live testnet probe reaches that business error for a deliberately
nonexistent id after the symbol binding is applied. No order, transfer, margin, gift-card, or
withdrawal mutation is sent by this task.

## 2026-07-18 — spot order reads and sparse acknowledgements (Task 336)

**C-T336 — Binance spot order read and acknowledgement shapes (task 336).** Outcome:
CONFIRMED for the complete query rows and observed ACK; DIVERGE from padding sparse
acknowledgements.

- **Read rows:** Binance Spot's Query Order and All Orders schemas provide the complete lifecycle
  shape: `origQty`, `executedQty`, `cummulativeQuoteQty`, status, side, type, and lifecycle
  clocks. `fetchOrder` and `fetchOrders` therefore parse amounts, fills, cost, status and order
  times only when those keys are present. The frozen CCXT static responses cover a filled
  `fetchOrder` and a cancelled `fetchOrders` row.
- **ACK / RESULT / FULL:** Binance documents `newOrderRespType` as three distinct response modes.
  ACK is not an incomplete RESULT: it carries only `symbol`, `orderId`, `orderListId`,
  `clientOrderId`, and `transactTime`; RESULT and FULL add order-state and (for FULL) fills. A
  live spot-testnet ACK observed 2026-07-18 contained exactly those ACK keys. It yielded the
  order id, client id, symbol and timestamp, while amount, price, filled, cost, status, and type
  remained nil. The same account's cancel returned Binance's full cancelled-order row; an
  invalid-order query remains the venue's `-2013` order-not-found error, not a sparse success.
- **No-padding scope (DIVERGE from CCXT, tier 2).** CCXT's Binance `parseOrder` defaults
  `executedQty` to `"0"` for every row it accepts as an order, so it reports a bare
  acknowledgement as `filled: 0` — a fill fact the venue never stated. We diverge, but ONLY for
  the documented sparse spot ACK key set above (`transactTime` present and no key outside
  `symbol`/`orderId`/`orderListId`/`clientOrderId`/`transactTime`). Any additional key means a
  RESULT/FULL body or another Binance surface, and those keep CCXT's default — the frozen
  binanceusdm conditional/algo fixtures (`cancelOrder`/`createOrder`/`fetchOrder`/`fetchOrders`/
  `fetchOpenOrders` linear swap conditional) pin `filled: 0` and are the tier-2 oracle for that
  path. Both sides of this boundary are asserted in `binance_authored_spec_test.exs`.
- **Timestamp precedence:** `time`, then `workingTime`, `createTime`, and `transactTime` — all
  Binance-documented response keys, read only when present. `transactTime` is appended LAST
  rather than second: it is the only clock a sparse ACK carries, but Binance also returns it
  alongside `workingTime` on spot creates, where the frozen `createOrder spot market buy order
  with trailingPercent` fixture pins the earlier key (`workingTime: -1`) as the oracle's
  timestamp. No request timestamp or synthetic clock is substituted.

  > CCXT adopting a `-1` sentinel `workingTime` as a real millisecond timestamp looks like a
  > CCXT bug, not Binance semantics. It is preserved here as tier-2 compatibility and is out of
  > this task's scope; correcting it needs a tier-1 confrontation.

## 2026-07-19 — invented order values (Task 381)

**C-T381a — Binance spot trailing-order working-time sentinel (task 381).** Outcome: DIVERGE
from Bourse. A spot-testnet trailing take-profit create observed 2026-07-19 returned
`workingTime: -1` with a non-negative `transactTime`; after immediate cancellation its pending
state confirmed the order had not begun working. Binance's [New order](https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/rest-api/trade)
schema ([pinned authority manifest](../../priv/authority/binance/manifest.json), artifact
`spot-openapi`) identifies `workingTime` as the order's working clock, while the observed `-1` is the
unactivated sentinel, not an epoch. We therefore reject negative candidate clocks and use the
next documented creation clock (`transactTime` here). Unified timestamps are never negative
epochs.
>
> CCXT derives `datetime` from that same sentinel, so its golden carries `datetime: nil` while
> ours carries the ISO form of the creation clock. Both the sentinel value and the value derived
> from it are recorded under C-T381a.

## 2026-07-18 — capital transaction histories and withdraw acknowledgement (Task 335)

**C-T335 — Binance capital transaction semantics (task 335).** Outcome: CONFIRMED — the
[`Deposit History`](https://developers.binance.com/docs/wallet/capital/deposite-history),
[`Withdraw History`](https://developers.binance.com/docs/wallet/capital/withdraw-history), and
[`Withdraw`](https://developers.binance.com/docs/wallet/capital/withdraw) authorities in Binance
Wallet API documentation define the three response families. The history rows carry `coin`,
`network`, `address`, `addressTag`, amount, status and their respective creation-time fields; the
apply acknowledgement carries only the venue withdrawal `id`.

- **Status and direction:** CONFIRMED. Deposit and withdrawal history rows are stamped by their
  endpoint families. The authored maps keep the documented deposit (`0` pending, `1`/`6`
  complete) and withdrawal (`0` email sent, `1` cancelled, `2` approval, `3` rejected, `4`
  processing, `5` failed, `6` completed) vocabularies distinct. This preserves the fact that code
  `1` has different meanings by endpoint family; the sparse apply acknowledgement has neither a
  status nor a type.
- **Identity, network and fee:** CONFIRMED. `address` and non-empty `addressTag` are the target
  identity; raw `network` is normalized through Binance's `TRX`/`BSC`/`ETH` identifiers. Only
  withdrawal-history `transactionFee` produces a fee, denominated in the row's `coin`; deposit
  rows have no invented fee.
- **Timestamp:** CONFIRMED. Deposit `insertTime` is the history event timestamp; withdrawal
  `applyTime` is the application timestamp. `completeTime` and `successTime` are not substituted
  for it, so `updated` remains nil unless the venue explicitly supplies `successTime`.
- **Sparse acknowledgement:** DIVERGE from a richer local echo. The apply response's `id` is
  retained with request-context currency only; no txid, network, amount, address, tag, fee,
  status, or timestamp is invented. Production confirmation is deferred in the ledger because
  spot testnet does not expose this Wallet API family.
- **Deposit status codes 7 and 8:** DIVERGE from CCXT toward the Binance authority. The
  [Deposit History](https://developers.binance.com/docs/wallet/capital/deposite-history) page
  enumerates five codes verbatim — "0: pending, 6: credited but cannot withdraw, 7: Wrong
  Deposit, 8: Waiting User confirm, 1: success". CCXT's own map carries only `0`/`1`/`6`, so
  inheriting it left `7` and `8` parsing to `status: nil` — a Wrong Deposit read as unknown
  rather than failed. Authored here as `7` -> `failed` and `8` -> `pending`. The static fixtures
  exercise only status `1`, so this divergence is doc-confirmed, not fixture-confirmed.
- **Withdrawal status labels 3/4/6 are CCXT-inherited, not doc-confirmed:** the
  [Withdraw History](https://developers.binance.com/docs/wallet/capital/withdraw-history) page
  names only `0` (Sent) and `2` (Approval) and does not enumerate the rest, so the authored
  `3` -> failed, `4` -> pending, `6` -> ok labels rest on CCXT's map plus the fixture's status
  `6` row. Tier-2 until a production withdrawal history confirms them (see the ledger entry).
- **Network vocabulary is open-ended:** DIVERGE from a closed enum. The authored map normalizes
  only Binance's `TRX`/`BSC`/`ETH` ids to `TRC20`/`BEP20`/`ERC20`; Binance's capital API accepts
  a far larger network set (`BTC`, `SOL`, `MATIC`, `ARBITRUM`, ...). A closed map with a null
  default silently returned `network: nil` for every unlisted id — dropping an identifier the
  venue did supply. The rule now carries `"enum_fallback": "raw"`, so an unmapped id survives as
  the venue's own string. This matches CCXT's `networkIdToCode`, which likewise falls back to the
  raw id, and is tier-2: the three normalized ids are confirmed by the static fixtures, while the
  fallback set is not enumerated against a live Binance response.
- **Timestamp coercion name:** DIVERGE from CCXT's coercion vocabulary. The two capital-history
  time fields need one coercion that accepts both epoch ms (`insertTime`) and a naive
  `"YYYY-MM-DD HH:MM:SS"` UTC datetime (`applyTime`), so this slot is authored as
  `epochMsOrDatetime` rather than reusing CCXT's `safeTimestamp`. CCXT's `safeTimestamp` means
  seconds -> milliseconds, which this coercion deliberately does not do. Naming it
  `safeTimestamp` would have made the catalog's 48 other `safeTimestamp` rules — many with
  second-resolution sources (`"format": "s"`) — appear implemented while the missing x1000
  stayed silent. Task 376 added resolution-aware runtime handling; the catalog audit is recorded
  in `docs/safe-timestamp-audit.md`.

## Historical confrontations (moved from authored-specs.md, task 466)

**C-T340 — Binance plural ticker routing. Outcome: CONFIRMED venue surfaces (task 340).**

- *Exchange semantics:* Binance exposes distinct ticker surfaces for
  spot (`/api/v3/ticker/24hr`), USD-M (`/fapi/v1/ticker/24hr`), COIN-M
  (`/dapi/v1/ticker/24hr`), and options (`/eapi/v1/ticker`). A requested
  unified symbol identifies the surface; no requested symbol is a spot read.
- *Our carve + rationale:* `fetchTickers` has authored market-type and
  market-family rules. Endpoint selection derives both from the first requested
  `symbols` entry just as it does from singular `symbol`; an absent symbol list
  deliberately defaults to spot. This distinguishes linear USD-M from inverse
  COIN-M swaps, avoids positional `hd(configs)` selection (whose first Binance
  entry is COIN-M), and makes the no-symbol behavior explicit in the frozen spec.
- *Compatibility cost:* none intended. The plural and singular forms now select
  the same market surface for the same symbol shape.
- *Implementation:* 340. *Evidence sources:* public Binance ticker read plus offline
  route stubs for spot, USD-M, COIN-M, options, and the no-symbol default.

**C8 — Binance market filters and REST families. Outcome: CONFIRM exchange semantics.**

- *Exchange semantics (non-CCXT):* Binance spot and derivatives publish price increments in the
  `PRICE_FILTER.tickSize` member and quantity increments in `LOT_SIZE.stepSize`. Spot account
  reads use `/api/v3/account`; USD-M account and market-data reads use `/fapi/*`; COIN-M uses
  `/dapi/*`. These shapes were confronted against the official Spot REST, USD-M, and COIN-M
  documentation and live testnet responses on 2026-07-15.
- *Our carve:* market precision reads the matching member of the live `filters` array rather than
  top-level digit-count fields. Authored endpoint rules select spot, linear, inverse, option, and
  mark/index/premium price families from request semantics; selector-only parameters are consumed
  before dispatch.
- *Compatibility cost:* none. Vendored CCXT-JS uses the same endpoint families and filter values.
- *Implementation:* 207.

**C18 — Binance EAPI option ids omit the quote/settle segment. Outcome: CONFIRM VENUE.**

- *Exchange semantics (non-CCXT — live Binance EAPI mainnet, 2026-07-16):*
  `GET /eapi/v1/exchangeInfo` returns option ids shaped `BASE-YYMMDD-STRIKE-C/P`, with both
  integer strikes (`BTC-260925-145000-C`) and decimal strikes (`XRP-260731-0.85-C`; 130 of the
  1576 live ids). All 1576 `optionSymbols` rows — and every `optionContracts` row — report
  `quoteAsset: USDT`, and each row carries the quote only in `underlying` (`BTCUSDT`), never in
  `symbol`. So the unified symbol keeps `BTC/USDT:USDT-260925-145000-C` while the venue id
  deliberately omits both the quote and the settle segment.
- *Our carve:* Binance option examples are authored into the frozen spec and classify as
  `:option_base_yymmdd`. `Bourse.Symbol.to_exchange_id/2` emits `BTC-260925-145000-C` for the unified
  option symbol, and `from_exchange_id/3` restores the `USDT` quote/settle because the id itself
  carries no quote to read back.
- *Compatibility cost:* this is narrower than OKX's `BASE-QUOTE-YYMMDD-STRIKE-C/P` (C15a) and
  Bybit's settle-suffixed shape (C11). Extending a venue-generic option heuristic would make
  Binance's omitted quote look accidental; the dedicated atom records that the omission is a
  Binance EAPI carve.
- *Residual (accepted, not silent):* the reverse direction hard-codes `USDT` because the id omits
  the quote — there is nothing in the id to derive it from. This is exact against every live
  option contract today (uniform `quoteAsset: USDT`), and matches the same shape as deribit's
  base-only reverse (`reverse_option_ddmmmyy` hard-codes `USD`). If Binance ever lists a
  non-USDT-quoted option, `from_exchange_id/3` returns a wrong quote silently; the live gate below
  is what would surface it.
- *Evidence sources:* live Binance EAPI mainnet `GET /eapi/v1/exchangeInfo` (tier-1 — the venue's own
  instrument list), pinned by `test/bourse/binance_authored_integration_test.exs`.
- *Implementation:* 274.

**C20 — Binance market type/boolean flags: payload shape + generic type derive, not endpoint stamp.
Outcome: CONFIRM VENUE (+ mechanical derive).**

- *Exchange semantics (non-CCXT — live Binance testnet, 2026-07-17):*
  `fetch_markets` fans out across spot `/api/v3/exchangeInfo`, USD-M `/fapi/v1/exchangeInfo`,
  COIN-M `/dapi/v1/exchangeInfo`, and related sections, then merges rows. Spot rows carry
  `baseAsset`/`quoteAsset`/`status` and **no** per-row kind field (`contractType` absent;
  `isSpotTradingAllowed` is spot-only). USD-M/COIN-M rows carry `contractType`
  (`PERPETUAL` / dated quarters), `status` (or `contractStatus`), and `marginAsset` settle.
  There is **no** producing-endpoint tag on each row after fan-out merge — so "spot because
  this endpoint is publicGetExchangeInfo" is not available at parse time.
- *CCXT's carve (compatibility reference):* `safeMarket` / `parseMarket` sets
  `spot`/`swap`/`future`/`contract`/`linear`/`inverse` from the instrument family and
  settlement direction; `active` from `status == TRADING`.
- *Our carve:*
  1. **Authored payload keys (binance + binanceusdm market field_map):**
     `type` from `contractType` enum (`PERPETUAL` → `"swap"`, dated quarters → `"future"`,
     `CRYPTO_OPTIONS` → `"option"`); when `contractType` is absent the field stays nil and
     `market_type_from_raw/1` fills `"spot"` from `baseAsset`+`quoteAsset` (same payload-shape
     signal live uses). `active` from `status` / `contractStatus` with `TRADING → true`.
     `settle`/`settleId` already key `marginAsset`.
  2. **Generic read-path derive (all venues, nil-only):** once `type` (and for settlement
     direction, `settle`/`base`/`quote`) is known, `derive_market_type_flags/1` fills
     `spot`/`swap`/`future`/`option`/`contract`/`linear`/`inverse` **only when the field-map
     left them nil**. Authored enum maps (bybit/okx/deribit) always win. linear/inverse =
     settle==quote / settle==base for contracts; non-contracts get both `false`.
  3. **Not endpoint constants:** because fan-out does not stamp the producing section onto
     each row, endpoint-implied flags would be dishonest after merge. Payload shape is the
     honest source for Binance family type.
- *Evidence sources:* live testnet `Bourse.fetch_markets` on `binance` + `binanceusdm` (tier-1) —
  BTC/USDT `spot=true, contract=false, active` from status; BTC/USDT:USDT
  `swap=true, linear=true, settle="USDT"`. Offline: `test/bourse/binance_authored_spec_test.exs`
  + integration assertions.
- *Implementation:* 227.

**C22 — Binance no-arg market surfaces and order enum casing. Outcome: CONFIRM VENUE — the
sandbox drops the margin/option waves (not linear/inverse), and USD-M is linear-only.**

- *Exchange semantics (non-CCXT — live Binance testnets + Binance's own USD-M docs,
  2026-07-17):* the spot sandbox (`testnet.binance.vision`) serves `/api/v3/exchangeInfo`;
  the futures sandbox (`testnet.binancefuture.com`) serves both `/fapi/v1/exchangeInfo`
  (USD-M) and `/dapi/v1/exchangeInfo` (COIN-M). Neither testnet publishes a `sapi` (margin)
  or `eapi` (option) host, so our sandbox `base_urls` resolve those two sections to `nil` and
  the margin path falls back onto the dapi template — which is why the venue answered `-5000
  "Path /dapi/v1/margin/allPairs"` for a *sapi* path (task 294 facet (a), reproduced). Binance
  order endpoints require uppercase enum strings (`BUY`/`SELL`, `LIMIT`/`MARKET`) and take size
  under the native `quantity` key.
- *CCXT's carve (compatibility reference — `binance.ts` / `binanceusdm.ts`, read 2026-07-17):*
  `fetchMarkets` takes its surface list from `options.fetchMarkets.types`. `binance` ships
  `['spot','linear','inverse']` and **keeps all three under sandbox** — it drops exactly two
  waves: `option` (`type === 'option' && isDemoEnv → continue`) and the sapi margin pairs
  (`fetchMargins && checkRequiredCredentials(false) && !isDemoEnv`). `binanceusdm` pins
  `types: ['linear']`, on mainnet as well as sandbox, consistent with its `has.spot: false`.
  CCXT JS uppercases `side`/`type` for order creation.
- *Our carve:* CONFIRM VENUE on both axes. `binance` no-arg `fetch_markets` fans out to
  spot+linear+inverse, minus the margin wave when sandboxed or uncredentialed (the existing
  `fan_out_configs/2` credential filter already encoded CCXT's `checkRequiredCredentials`
  guard) and minus the option wave when sandboxed. `binanceusdm` collapses to the fapi surface
  alone — a **deliberate narrowing** of the previous no-arg behavior, which fanned the whole
  binance family onto USD-M and returned spot/option rows the venue does not trade (live: 6092
  → 840 rows, 2026-07-17). The other surfaces stay reachable on both venues through the
  authored `fetchMarkets` rules (`type`/`subType`); only the no-arg fan-out narrows. Order
  lifecycle methods (`createOrder`, `fetchOrder`, `cancelOrder`) select spot/fapi/dapi/eapi by
  market family; `createOrder` reshapes unified `amount` → `quantity` and uppercases `side` and
  `type` before signing; `fetchOrder`/`cancelOrder` reshape unified `id` → `orderId`.
- *Evidence sources:* live Binance spot and USD-M testnets (tier 1 — real responses, with Binance's own
  USD-M docs as the non-CCXT semantic source) for the enum casing, the fapi market id, and the
  create→fetch→cancel lifecycle; CCXT-JS source read as the compatibility reference for the
  surface list only (tier 2). Offline surface/request-shape pins in
  `test/bourse/binance_authored_spec_test.exs`; live lifecycle and the spot write-path pin
  (lowercase unified side → venue `BUY`, far-from-market limit rests) in
  `test/bourse/binance_authored_integration_test.exs`.
- *Implementation:* 296.
- *Id note:* landed as a second **C21** by task 296 while task 286 already owned C21 (query
  space encoding). Post-merge audit renumbered this entry to **C22** so the append-only
  namespace stays unique; C21 remains the `%20` encoding carve.

**C-T356 — Binance multi-row ticker symbols follow the resolved endpoint family. Outcome: CONFIRM
VENUE + ALIGNED-to-ccxt (task 356).**

- *Exchange semantics (non-CCXT — live Binance spot testnet `GET /api/v3/ticker/24hr` plus
  `/api/v3/exchangeInfo`, 2026-07-18):* ticker rows identify a spot market only as an ambiguous
  compact id such as `BTCUSDT`; `exchangeInfo` defines that id with `baseAsset: BTC`,
  `quoteAsset: USDT`, and spot trading enabled. It is not a USD-M contract merely because the
  same compact grammar can occur on a futures surface.
- *CCXT's carve (compatibility reference — `binance.ts` `fetchTickers` / `parseTickers`):*
  `marketSymbols` resolves the requested markets, spot sends `symbols: json(marketIds(symbols))`,
  and parsed rows are keyed through the market lookup.
- *Our carve:* parse-only endpoint context wins over native-id grammar for multi-row response
  symbols, scoped to **Binance spot only** — the venue+family whose compact native ids
  (`BTCUSDT`) collide with the perpetual grammar so the per-id classifier mis-keys a spot row as
  a swap. A row from the selected Binance spot endpoint becomes `BTC/USDT`; the fapi endpoint
  still becomes `BTC/USDT:USDT` via the per-id grammar, unthreaded. The scoping is deliberately
  `exchange.id == "binance"`, NOT a generic "any spot section" mechanism: the endpoint section
  names that identify Binance spot (`public`/`v1`) are shared across venues and market families —
  bybit's v5 derivative endpoints and binanceusdm's COIN-M (`dapi/v1`) reuse them — so a
  section-name-only match stamps non-spot rows as spot and overrides their correct per-row
  classification (observed to regress binanceusdm inverse tickers and bybit funding/greeks
  multi-row reads against the static-fixture gate). Contract families are self-describing in their
  ids and need no endpoint hint. Binance spot serializes a requested plural list as the venue's
  JSON array query parameter, while derivative surfaces retain their existing request contract.
- *Evidence sources:* live Binance spot testnet for the requested `BTC/USDT`/`ETH/USDT` response and
  `exchangeInfo` market definition (tier 1); CCXT-JS source for compatibility (tier 2). Offline
  spot/USD-M endpoint-family and query-shape pins live in
  `test/bourse/binance_authored_spec_test.exs`.
- *Implementation:* 356.

**C-T366 — Binance USD-M ticker ids require fapi/dapi settlement context. Outcome: CONFIRM VENUE
ALIGNED-to-ccxt (task 366).**

- *Exchange semantics (non-CCXT — live Binance Futures testnet `GET /dapi/v1/ticker/24hr` plus
  `/dapi/v1/exchangeInfo`, and `GET /fapi/v1/ticker/24hr` plus `/fapi/v1/exchangeInfo`,
  2026-07-18):* COIN-M `BTCUSD_PERP` identifies `baseAsset: BTC`, `quoteAsset: USD`,
  `marginAsset: BTC`, and `contractType: PERPETUAL`, so its unified key is `BTC/USD:BTC`.
  Dated fapi `ETHUSDT_251226` identifies a USDT-margined delivery contract, so its key is
  `ETH/USDT:USDT-251226`.
- *Our carve:* CONFIRM VENUE. Resolve underscore-suffixed Binance USD-M ticker ids using the
  selected endpoint family: dapi settles inverse contracts in base; fapi settles dated linear
  contracts in quote. This is scoped to Binance USD-M endpoint families, not shared section
  names, preserving Binance spot and Bybit behavior. The USD-M family hint is threaded for
  `fetchTickers` only — USD-M contract ids are otherwise self-describing, and stamping a family
  onto every read would override the correct per-id classification on order/position/trade rows
  (the same failure mode carve C-T356 records for section-name-only keying). Binance spot's hint
  stays threaded for all methods, as landed in 356.
- *Evidence sources:* Binance Futures testnet instrument identity (tier 1); CCXT-JS `parseTickers` and
  static fixtures as compatibility checks (tier 2).
- *Implementation:* 366.

**C-T318a — Binance ticker average uses the loaded market price precision. Outcome: ALIGNED-to-ccxt (task 318).**

- *Exchange semantics (non-CCXT):* Binance spot `exchangeInfo` exposes each symbol's
  `PRICE_FILTER.tickSize`; the official filters documentation defines it as the valid price
  increment. A live spot-testnet `BTCUSDT` response on 2026-07-17 reported tick size
  `0.01000000`, while the live 24-hour ticker reported the `openPrice` and `lastPrice`
  operands. Binance does not publish this synthetic `(open+close)/2` average itself.
- *Counter-evidence, and why the carve is compatibility-driven (task 318 review, live
  2026-07-17):* the nearest average Binance DOES publish — `ticker/24hr.weightedAvgPrice` —
  comes back at FULL precision (`64201.22783705` against a `0.01` tick), i.e. the venue does
  not tick-round its own derived statistics. So tick-truncating `average` is NOT venue
  semantics; it is CCXT's `safeTicker` convention. We adopt it for tier-2 replay
  compatibility, not because `72775.465` is wrong. Revisit if a consumer needs the
  untruncated statistic — the un-truncated value is arguably the more faithful mean, and
  `72775.46` is a mean rounded to a tick that means nothing for a non-executable price.
- *Our carve:* when a loaded market supplies `precision.price`, truncate a computed ticker
  average to that decimal precision. The cache is caller-threaded on `%Bourse.Exchange{}` and
  replay loads the same static markets/currencies caches as CCXT's offline driver.
- *Compatibility cost:* none for CCXT fixtures: this matches `safeTicker`'s loaded-market
  branch (`72775.46` for the recorded BTC/USDT case). Without a cache, retain the full computed
  value rather than invent market metadata.
- *Evidence sources:* Binance spot filters documentation and live spot-testnet `exchangeInfo`/24-hour
  ticker observations (tier 1 for market metadata); CCXT static replay is tier 2 for the
  synthetic-average representation.
- *Implementation:* 318.

**C-T319 — Binance `fetchCurrencies` networkList rollups (task 319). Outcome: CONFIRMED LIVE
(wallet API) + tier-2 network-code aliases.**

- *Payload:* `GET /sapi/v1/capital/config/getall` returns coin rows each with `networkList[]`
  carrying per-network `depositEnable` / `withdrawEnable` / `withdrawFee` /
  `withdrawIntegerMultiple` / `withdrawMin` / `withdrawMax` / `depositDust` /
  `contractAddressUrl` / `isDefault` (Binance Wallet Capital "All Coins' Information").
- *active:* Binance exposes coin-level `trading` plus `depositAllEnable` / `withdrawAllEnable`,
  and per-network enable flags. CCXT sets unified `active` from **`trading`**, not from deposit
  capability. **CONFIRMED** against the wallet payload: `trading` is the tradability bit; deposit
  and withdraw are separate unified fields rolled from networks. We adopt `active ← trading`.
- *deposit / withdraw:* **CONFIRMED** as OR across `networkList[*].depositEnable` /
  `withdrawEnable`. Coin-level `depositAllEnable` / `withdrawAllEnable` agree with that OR when
  networks are consistent; the network flags are the actionable truth for a chosen chain (same
  keys deposit-address flows need — coordinate with task 318's `contractAddressUrl` network
  derivation; do not invent a second network-code ontology). Per-network unified `active` is
  deposit **and** withdraw (`active_requires_both: true`) so a deposit-only chain such as
  SEGWITBTC is inactive for withdrawal routing. CCXT 4.5.65 now leaves that derived field nil;
  C-T442a records why the provider-backed boolean deliberately remains.
- *fee:* **CONFIRMED** as **minimum** `withdrawFee` across networks (cheapest withdrawal path).
  Per-network fees also materialize in unified `fees` keyed by **raw** network id (`BSC`, not
  `BEP20`) — CCXT's `parseCurrency` map, tier-2.
- *precision:* Binance's `withdrawIntegerMultiple` is already a **tick size** (not a digit
  count). Currency-level precision is CCXT `safeCurrencyStructure`'s **maximum** (coarsest) step
  across networks when they disagree — a lossy scalar; the per-network value is the truth.
  **CONFIRMED** the field meaning against the wallet API (step size for integer multiples).
  A signed production payload on 2026-07-23 confirmed the max aggregate for the current USDT
  network set: 19 rows and unified `precision = 0.00001`. Authored:
  `precision_mode: "tick_size"` + `precision_aggregate: "max"`.
- *network codes:* Binance `networksById` aliases (`BSC→BEP20`, `ETH→ERC20`, `TRX→TRC20`,
  `OPTIMISM→OP`, `ARBITRUM→ARBONE`) plus `impliedNetworks` (`ETH`/`TRX` keep their native chain
  code). **CONFIRMED-as-CCXT-compat** (tier 2) — these are CCXT's unified network vocabulary,
  not names Binance returns on the wire. Same alias table must serve deposit-address network
  recovery (task 318) so the two slices never disagree on `BEP20` vs `BSC`.
- *limits:* withdraw min/max and deposit min (`depositDust`) roll min/max across networks;
  empty `amount` shell omitted (`include_amount_limits: false`) to match Binance static goldens.
- *Compatibility cost:* none for the T-A `fetchCurrencies` default fixture once the slice is
  authored; missing-slice path now fails loud naming the venue (task 319 / task-256 spirit)
  instead of `key :id not found`.
- *Live citation:* signed `GET /sapi/v1/capital/config/getall` on `api.binance.com`,
  2026-07-23 — 709 currencies; USDT unified precision matched the maximum raw
  `withdrawIntegerMultiple`, and unified fee `0.01` matched the minimum raw `withdrawFee`.

**C-T349 — Binance `asset/dust` encodes multiple assets as one comma-separated field
(task 349). Outcome: CONFIRM PROVIDER CONTRACT; live mutation deferred.**

- *Provider-owned contract:* Binance Wallet's
  [Dust Transfer](https://developers.binance.com/en/docs/catalog/core-trading-wallet/api/rest-api/asset#dust-transfer)
  defines one required string field, `asset`, and gives `asset=BTC,USDT` for multiple assets.
  The endpoint has no amount parameter: it converts the full eligible dust balance of every
  named asset, so a production request is a venue-final mutation rather than a harmless probe.
- *Our carve:* the authored `sapi` signing recipe selects
  `urlencodeCommaSeparatedArray` only when the exact runtime path is `/asset/dust`.
  `/asset/dust-btc` and every other Binance array query retain the existing JSON-array
  dialect. Dispatch threads the endpoint's dotted section path into the signer, which
  selects the exact section key, then the top-level segment, then falls back to heuristic
  recipe resolution (section maps are keyed inconsistently across the catalog: htx-family
  by dotted path, gate-family by top-level segment, poloniex by neither) — so runtime
  selects `sapi` directly instead of heuristically choosing another Binance-family recipe.
- *Compatibility reference:* repeated bare `asset` keys are rejected as the governing
  contract because they contradict Binance's current provider-owned schema. Existing
  JSON-array behavior for ordinary Binance GET arrays remains independently live-pinned.
- *Residual:* signed production preview traffic found eligible ADA and EUR dust on 2026-07-23,
  but the key has Spot & Margin Trading disabled and no conversion was authorized. The exact
  execution confirmation remains in the production verification ledger.

## Evidence status records

<!-- carve-evidence-status
{"carve_id":"C-T515a","date":"2026-07-26","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binance/errors.json is the spot-owned enumeration and does not own the derivative-only maps"},"observed_evidence":{"kind":"recorded_real_exchange","reference":"Existing Binance-family request coverage identifies the api/sapi/fapi/dapi/eapi/papi family boundaries"},"compatibility_reference":{"kind":"ccxt","reference":"raw.describe.exceptions remains the explicit tier-2 runtime source for heterogeneous scoped class targets"},"resolved_tier":2,"known_gap_reason":"The raw scoped class targets are deliberately excluded from the provider-authored spot slice"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T319","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Binance All Coins' Information defines networkList withdrawIntegerMultiple and withdrawFee"},"observed_evidence":{"kind":"live_venue","reference":"Signed production fetchCurrencies payload on 2026-07-23: 709 currencies, 19 USDT networks, max precision 0.00001 and min fee 0.01 matched unified output"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT network-code alias vocabulary remains the tier-2 portion"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T349","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Binance Dust Transfer contract defines one comma-separated asset string"},"observed_evidence":{"kind":"live_venue","reference":"Signed dust-btc preview reached production and returned eligible assets, but no dust conversion was executed"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Production mutation requires Spot & Margin Trading permission and explicit approval because no amount cap exists; tracked in the production verification ledger"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T442a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance All Coins' Information defines networkList depositEnable and withdrawEnable"},"observed_evidence":{"kind":"recorded_venue","reference":"The two recorded Binance fetchCurrencies responses carry per-network depositEnable and withdrawEnable booleans"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 parsedResponse leaves per-network active undefined"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T482a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance All Coins' Information defines independent networkList depositEnable and withdrawEnable booleans"},"observed_evidence":{"kind":"recorded_venue","reference":"Recorded Binance fetchCurrencies responses carry both enable flags on every networkList row"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 leaves per-network active undefined"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T438b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance COIN-M Position Information schema cited in C-T438b"},"observed_evidence":{"kind":"live_venue","reference":"Signed dapi positionRisk testnet rows observed 2026-07-22 without the four derived margin fields"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT inverse position fixtures provide the conflicting derived values"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T323c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance Send Quote Request schema cited in C-T323c"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT parseConversion and frozen Convert fixture"},"resolved_tier":2,"known_gap_reason":"Spot testnet has no SAPI host; populated Convert response remains deferred in the production verification ledger"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T381a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance Spot New Order schema cited in C-T381a"},"observed_evidence":{"kind":"live_venue","reference":"Spot-testnet trailing order returned workingTime=-1 and non-negative transactTime on 2026-07-19"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT trailing-order fixture records timestamp=-1"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T452a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T452a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T452a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T452a and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T452b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T452b and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T452b and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T452b and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T323a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T323a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T323a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T323a and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T323b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T323b and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T323b and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T323b and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T334b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T334b and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T334b and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T334b and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T418a","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T418a and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T418b","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T418b and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T378d","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":null,"resolved_tier":3,"known_gap_reason":"This internal authoring outcome records no provider-owned semantic source, independent venue observation, or CCXT compatibility evidence"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T386","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T386 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T386 and its register context"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T341a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T341a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T341a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T341a and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T336","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T336 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T336 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T335","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T335 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T335 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T335 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T340","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"recorded_venue","reference":"Public Binance ticker read plus offline route stubs for spot, USD-M, COIN-M, options, and the no-symbol default cited in C-T340"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The recorded public read and route stubs establish routing behavior, but no provider-owned semantic source independently establishes the authored market-family selection"}
-->

<!-- carve-evidence-status
{"carve_id":"C8","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C8 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C8 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C8 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C18","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C18 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C18 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C20","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C20 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C20 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C22","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C22 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C22 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C22 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T356","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T356 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T356 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T366","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T366 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T366 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T318a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T318a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T318a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T318a and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T319","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T319 and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T319 and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T164a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance exchangeInfo has no maker/taker on symbol rows; public fee schedule documents VIP-0 rates; private /sapi/v1/asset/tradeFee is account-specific and out of scope for public market rows"},"observed_evidence":{"kind":"live_venue","reference":"Live sandbox Bourse.fetch_markets on binance plus recorded test/fixtures/responses/binance/fetch_markets.json exchangeInfo bodies without fee fields"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT this.fees static table / parseMarket maker-taker fill cited as reference only"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T164b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance filters docs: PRICE_FILTER.tickSize, LOT_SIZE.stepSize/minQty/maxQty, NOTIONAL/MIN_NOTIONAL cost bounds"},"observed_evidence":{"kind":"live_venue","reference":"Live sandbox fetch_markets filter members and recorded exchangeInfo fixture pin"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT static markets goldens for filter-derived precision/limits; parsePrecision digit-count path rejected for amount/price ticks"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T449a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance spot klines endpoint documentation: GET /api/v3/klines responds with a top-level JSON array of kline rows; no wrapping object"},"observed_evidence":{"kind":"live_venue","reference":"Live testnet Bourse.fetch_ohlcv on binance returning the bare kline array; binance per-venue fixture replay gate green on the edited spec"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT fetchOHLCV passes the response straight to parseOHLCVs; distill marker no_safe_value_call cited as extraction observation only"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T530c","date":"2026-07-30","semantic_source":{"kind":"provider_owned","reference":"Binance official Spot API repository Testnet boundary and Query Commission Rates contract cited in C-T530c"},"observed_evidence":{"kind":"live_venue","reference":"Spot Testnet BTCUSDT account/commission success, -1121 invalid-symbol response, and explicit SAPI sandbox routing failure observed and pinned by tagged integration tests on 2026-07-30"},"compatibility_reference":{"kind":"ccxt","reference":"The production SAPI bulk fee route remains the compatibility surface outside Spot Testnet"},"resolved_tier":1}
-->

## 2026-08-04 — filtered order-history window (Task 540)

**C-T540b — Spot order history names its millisecond bounds `startTime` and `endTime`
(task 540). Outcome: CONFIRM venue.**

- *Exchange semantics:* Binance's `GET /api/v3/allOrders` contract accepts `startTime`,
  `endTime`, and `limit`; `symbol` is required.
- *Our carve:* `fetchOrders` maps unified `since`/`until` to those native names and preserves a
  supplied limit. Missing optionals are absent rather than encoded as empty values; emulated
  closed/canceled reads inherit the same request shape.
- *Live evidence:* Spot Testnet accepted `BTCUSDT` with `startTime` and `limit=25` at HTTP 200.
  The fixture-signed request is registered as
  `test/fixtures/exchange_accepted_requests/binance/fetch_orders.json`.

<!-- carve-evidence-status
{"carve_id":"C-T540b","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"Binance Spot All Orders GET /api/v3/allOrders parameter contract in the pinned spot-openapi authority artifact"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/exchange_accepted_requests/binance/fetch_orders.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-08 — unsupported composite and sandbox-absent reads (Task 565)

**C-T565b — Do not declare a unified read when one provider response cannot satisfy it
(task 565). Outcome: DIVERGE from the inherited capability declarations.**

- *Provider boundary:* account positions and position risk require account/position rows plus
  leverage-bracket data; selecting the bracket route alone does not return positions. The EAPI
  option-account and SAPI dust/isolated-margin routes have no Spot Testnet host.
- *Live evidence:* Spot/Futures sandbox probes selected either an incompatible route or reported
  no sandbox base URL. `fetchMarginModes` also had multiple incompatible market-family routes.
- *Our carve:* `fetchAccountPositions`, `fetchOptionPositions`, `fetchPositionsRisk`,
  `fetchMyDustTrades`, `fetchIsolatedBorrowRates`, and `fetchMarginModes` are `has=false` on the
  multi-market Binance surface. This prevents leverage brackets from being silently parsed as
  positions and keeps sandbox-unverifiable reads out of the declared client surface.

<!-- carve-evidence-status
{"carve_id":"C-T565b","date":"2026-08-08","semantic_source":{"kind":"provider_owned","reference":"Pinned Binance Spot, USD-M, and Options API artifacts in priv/authority/binance identify separate account, leverage-bracket, EAPI, and SAPI contracts"},"observed_evidence":{"kind":"live_venue","reference":"Task 565 Spot/Futures sandbox differential probes: bracket rows were selected as positions; EAPI and SAPI reported no sandbox base URL"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-09 — reachable method-specific endpoint defaults (Task 534)

**C-T534b — A mapped method keeps a reachable default when several API sections expose similar
names (task 534). Outcome: CONFIRM routing boundary.**

- *Provider boundary:* Spot order lookup and trade reads live under `/api/v3`; convert history,
  margin liquidation history, and account fee reads live under their distinct SAPI families.
- *Our carve:* `fetchOpenOrder`, `fetchOrderTrades`, `fetchConvertTrade`,
  `fetchConvertTradeHistory`, `fetchMyLiquidations`, and `fetchTradingFee` carry explicit defaults
  plus market-family rules where the provider exposes futures counterparts. Selection no longer
  depends on incidental endpoint-section ordering.
- *Verification:* exhaustive selector tests prove each mapping is reachable by a documented
  parameter set. Spot endpoint semantics are pinned by `spot-openapi`; the SAPI routes have no
  task-specific registered live response.

<!-- carve-evidence-status
{"carve_id":"C-T534b","date":"2026-08-09","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binance/manifest.json artifact spot-openapi for the Spot order and trade endpoints"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Selector reachability is pinned offline, but the SAPI defaults added by task 534 have no task-specific manifest-registered live response"}
-->
