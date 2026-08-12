# Binance COIN-M carve register

Append-only schema confrontations for Binance COIN-M. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for Binance COIN-M's complete authored REST surface.** This file records every
venue-specific decision in the self-contained runtime document. Provider-owned evidence is
indexed by `priv/authority/binancecoinm/manifest.json`.

## 2026-08-11 — order history and account analytics (Task 545)

**C-T545a — full DAPI order history is the source for direct, filled, and canceled order reads
(task 545). Outcome: CONFIRM provider contract.** Binance's COIN-M All Orders contract defines
`GET /dapi/v1/allOrders` as the symbol-scoped history of active, canceled, and filled orders.
The unified client maps `fetchOrders` to that response and derives `fetchClosedOrders` and
`fetchCanceledOrders` by filtering the parsed provider statuses. Live demo DAPI returned four
typed historical orders for `BTCUSD_PERP`; the same endpoint returned `-1121` for an invalid
symbol.

<!-- carve-evidence-status
{"carve_id":"C-T545a","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binancecoinm/manifest.json artifact developer-docs-full; COIN-M All Orders contract"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binancecoinm/fetch_orders.json, fetch_closed_orders.json, and fetch_canceled_orders.json plus the tagged live integration success/error assertions"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T545b — leverage brackets, open interest, and commission rates remain distinct typed reads
(task 545). Outcome: CONFIRM provider contract.** The provider's V2 Notional Bracket contract
defines symbol-scoped `brackets` with leverage, quantity floors/caps, and maintenance ratios;
the Open Interest contract defines contract count and observation time; the Commission Rate
contract defines maker and taker rates. These map respectively to `LeverageTier`, `OpenInterest`,
and `TradingFee`. The COIN-M `qtyFloor` / `qtyCap` values remain in `LeverageTier.info` instead
of being mislabeled as unified notional bounds. Live demo DAPI returned populated success
responses for all three and `-1121` for invalid symbols.

<!-- carve-evidence-status
{"carve_id":"C-T545b","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binancecoinm/manifest.json artifact developer-docs-full; COIN-M V2 Notional Bracket, Open Interest, and Commission Rate contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/exchange_accepted_requests/binancecoinm/fetch_leverage_tiers.json, test/fixtures/public_accepted_requests/binancecoinm/fetch_open_interest--dapiPublic_get_openinterest.json, test/fixtures/responses/binancecoinm/fetch_trading_fees.json, and tagged live integration success/error assertions"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T545c — income history is ledger data and an empty ADL object means no ranked position
(task 545). Outcome: CONFIRM provider contract.** The Income History contract defines
`incomeType`, signed `income`, `asset`, `time`, `tranId`, and `tradeId`, which map directly to a
typed `LedgerEntry`. The ADL Quantile contract defines ranks from 0 through 4 by position side.
The funded demo account returned successful empty income history and an empty ADL object; the
client preserves those valid states as `[]` and `nil`. An invalid income type returned `-1130`,
and an invalid ADL symbol returned `-1121`. Provider-shaped populated rows are pinned by offline
typed parser tests because this account had no income or ranked position during the sweep.

<!-- carve-evidence-status
{"carve_id":"C-T545c","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binancecoinm/manifest.json artifact developer-docs-full; COIN-M Income History and Position ADL Quantile contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binancecoinm/fetch_ledger.json and fetch_adl_rank.json plus tagged live integration success/error assertions"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The live account returned valid empty income and ADL states; populated provider-shaped rows are contract-authored and pinned offline rather than observed on this account"}
-->

**C-T545d — STP expiry is part of the COIN-M order-status vocabulary (task 545 ARC pass).
Outcome: CONFIRM provider contract.** The COIN-M common-definition status enum omits
`EXPIRED_IN_MATCH`, but the venue ships self-trade prevention on COIN-M with
`selfTradePreventionMode` defaulting to `EXPIRE_MAKER`, and Binance's STP FAQ and derivatives
change log document `EXPIRED_IN_MATCH` as the status of an order expired by STP. The authored
enum maps it to unified `canceled`, matching the `binance` and `binanceusdm` arms, so one
STP-expired row in the `allOrders` window cannot fail the whole `fetchOrders` /
`fetchClosedOrders` / `fetchCanceledOrders` read via the unmapped-status guard.

<!-- carve-evidence-status
{"carve_id":"C-T545d","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"Binance STP FAQ and derivatives change log (developers.binance.com); COIN-M Trade REST contract documents selfTradePreventionMode default EXPIRE_MAKER"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No STP-expired order row was observable on the demo account; the arm is authored from the provider-owned STP contract and guarded by the documented-set coverage test"}
-->

**C-T545e — COIN-M open interest is a contract count and lands in the amount slot (task 545
ARC pass). Outcome: DIVERGE from the bybit/deribit inverse carve.** `GET /dapi/v1/openInterest`
returns `openInterest` denominated in contracts (the sibling Open Interest Statistics contract
documents the unit as `cont`), and `Bourse.OpenInterest` defines `open_interest_amount` as
"open interest in contracts", so the authored map places the venue number in
`openInterestAmount` and leaves `openInterestValue` null — no notional source exists in the
response. bybit and deribit route their inverse open-interest numbers into `openInterestValue`
via discriminated maps because those venues publish value-denominated figures; the divergence
is venue truth, not an oversight. A consumer wanting cross-venue-uniform OI denomination needs
a computed conversion (contract size × count), which the client deliberately does not perform.

<!-- carve-evidence-status
{"carve_id":"C-T545e","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"COIN-M Open Interest and Open Interest Statistics contracts (developers.binance.com); Bourse.OpenInterest struct contract"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binancecoinm/fetch_open_interest.json pins the contract-count reading; binance_authored_spec_test.exs asserts open_interest_amount"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-10 — position-mode and leverage capability routing (Task 586)

**C-T586a — COIN-M exposes position-mode and initial-leverage writes through DAPI (task 586).
Outcome: CONFIRM provider contract.** Binance's official
[Change Position Mode](https://developers.binance.com/docs/derivatives/coin-margined-futures/trade/rest-api/Change-Position-Mode)
contract defines `POST /dapi/v1/positionSide/dual` with the required string
`dualSidePosition`; its
[Change Initial Leverage](https://developers.binance.com/docs/derivatives/coin-margined-futures/trade/rest-api/Change-Initial-Leverage)
contract defines `POST /dapi/v1/leverage` with `symbol` and integer `leverage`. Before this
confrontation, both capabilities were `false` and both unified endpoint lists were empty despite
the raw routes already being authored. Live demo DAPI returned `-4059` when one-way mode was
reasserted with `dualSidePosition=false`, proving that the unified boolean reached business
validation without changing the shared account mode. A leverage value of 3 for `BTCUSD_PERP`
returned HTTP 200 with the provider's leverage acknowledgement. The position-mode validation is
recorded as provider error evidence; an accepted-request golden would require flipping shared
account state because the safe same-state request is intentionally non-2xx.

<!-- carve-evidence-status
{"carve_id":"C-T586a","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance COIN-M Change Position Mode and Change Initial Leverage REST contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/recorded_errors/binancecoinm/error_position_mode_unchanged.json and test/fixtures/exchange_accepted_requests/binancecoinm/set_leverage.json"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T586b — COIN-M configured leverage is the per-symbol `leverage` in DAPI account positions
(task 586). Outcome: CONFIRM provider contract.** Binance's official
[Account Information](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-coin-m-futures/api/rest-api/account#account-information)
contract includes `symbol`, `positionAmt`, and `leverage` in every position row. Live demo DAPI
returned a flat `BTCUSD_PERP` row (`positionAmt=0`) with `leverage=3`. The dedicated client maps
`fetchLeverages` to `GET /dapi/v1/account`, removes the client-side symbol filter from the signed
query, parses the `positions` envelope, and emulates `fetchLeverage` by selecting the requested
contract. Before this confrontation, both leverage-read capabilities were `false` with empty
unified mappings.

<!-- carve-evidence-status
{"carve_id":"C-T586b","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance COIN-M Account Information REST contract"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binancecoinm/fetch_leverages.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-10 — dedicated COIN-M write routing (Task 578)

**C-T578c — COIN-M conditional orders use a distinct DAPI Algo book (task 578). Outcome: CONFIRM provider
contract.** Binance's pinned COIN-M New Order contract states that migrated stop types are rejected
by `/dapi/v1/order` and must use `/dapi/v1/algoOrder`. Live demo DAPI accepted a conditional order
carrying `timeInForce` and `reduceOnly=false`, accepted `marginType=ISOLATED` for `BTCUSD_PERP`, and
returned `code=200` from both regular and Algo cancel-all calls; cleanup restored the crossed margin
mode. Before the repair, the authored DAPI create shape selected the regular order route and omitted
these controls. The dedicated client therefore routes create, cancel, open-order, and cancel-all lifecycle
operations across the regular and Algo books rather than retaining a market-family exclusion.

<!-- carve-evidence-status
{"carve_id":"C-T578c","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Pinned Binance COIN-M New Order migration text plus DAPI margin-type and cancel-all contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/exchange_accepted_requests/binancecoinm/create_order.json, set_margin_mode.json, and cancel_all_orders.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-10 — current funding-rate cadence (Task 573)

**C-T573c — COIN-M current funding rates join DAPI funding info by native symbol (task 573).
Outcome: CONFIRM venue.** Binance's official
[COIN-M Funding Rate Info](https://developers.binance.com/docs/derivatives/coin-margined-futures/market-data/rest-api/Get-Funding-Rate-Info)
contract publishes `fundingIntervalHours` for adjusted symbols. Binance's own
[Introduction to Binance Futures Funding Rates](https://www.binance.com/en/support/faq/introduction-to-binance-futures-funding-rates-360033525031)
defines the eight-hour default for perpetual contracts. `fetchFundingRate` joins `premiumIndex`
to that provider row, emitting the normalized duration and falling back to `8h` only for an
unmatched row with a positive `nextFundingTime`. Dated delivery futures report
`nextFundingTime: 0` and retain `interval: nil`. Live demo DAPI changed BTCUSD_PERP from
`interval: nil` to `interval: "8h"`.

<!-- carve-evidence-status
{"carve_id":"C-T573c","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance COIN-M Funding Rate Info contract and FAQ 360033525031"},"observed_evidence":{"kind":"live_venue","reference":"Live demo-dapi BTCUSD_PERP premiumIndex plus fundingInfo returned unified interval 8h while dated delivery rows reported nextFundingTime 0 on 2026-08-10"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-07-26 — market-scoped error classification (Task 515)

**C-T515c — DAPI error codes select the inverse exception map (task 515). Outcome: CONFIRMED for
`-2019`; scoped taxonomy conflicts remain explicit.**

- *Exchange semantics:* the provider-owned COIN-M error enumeration identifies `-2019` as
  `MARGIN_NOT_SUFFICIEN` and `-4061` as `POSITION_SIDE_NOT_MATCH`.
- *Live observation:* an oversized far-from-market `BTCUSD_PERP` order on the COIN-M demo host
  returned `-2019 "Margin is insufficient"`.
- *Our carve:* a DAPI request selects `inverse.exact`, so `-2019` classifies as
  `:insufficient_funds` with retry class `:non_retryable`. The same code selects
  `:insufficient_funds` under `linear` and the authored `:operation_failed` target under
  `portfolioMargin`. For `-4061`, `option` retains the authored coarse `:exchange_error` target
  while `portfolioMargin` retains `:invalid_order`; these are recorded scoped taxonomy
  divergences rather than flattened into one class. Scoped entries override conflicting
  top-level entries.

## 2026-07-25 — complete COIN-M promotion (Task 450)

**C-T450a — COIN-M is an independent DAPI venue with the documented demo host (task 450). Outcome: CONFIRM VENUE.**

- *Exchange semantics:* Binance's official COIN-M general information defines the DAPI REST
  surface and names `https://demo-dapi.binance.com` as its testnet base.
- *Live observation:* the same `BINANCE_FUTURES_TEST_API_KEY/SECRET` returned byte-identical
  account and balance payloads from `testnet.binancefuture.com/dapi` and
  `demo-dapi.binance.com/dapi`; the authored sandbox slots therefore use the documented demo
  host rather than treating the legacy hostname as a second environment.
- *Our carve:* Binance COIN-M loads one complete owned document. Its supported method routes use
  only `dapiPublic`, `dapiPrivate`, and `dapiPrivateV2`; it inherits no Binance-family runtime
  spec.

**C-T450b — inverse contract identity, settlement, expiry, and quantity stay native (task 450). Outcome: CONFIRM VENUE.**

- *Exchange semantics:* DAPI exchange information distinguishes perpetual and dated delivery
  contracts, reports base-asset settlement and a per-symbol `contractSize`, and expresses order
  quantity as an integer number of contracts.
- *Live observation:* `BTCUSD_PERP` parsed as `BTC/USD:BTC`, inverse and non-linear, with
  `contract_size: 100`; dated `BTCUSD_YYMMDD` rows retained their delivery expiry and
  `BASE/QUOTE:SETTLE-YYMMDD` identity. A quantity of `1` created one 100 USD inverse contract.
- *Our carve:* no spot or USD-M quantity, quote-settlement, or linear-notional assumptions are
  copied into the owned market or order semantics.

**C-T450c — account and position-risk collections remain distinct DAPI contracts (task 450). Outcome: CONFIRM VENUE.**

- *Exchange semantics:* the signed account endpoint embeds `assets` and `positions`, while the
  position-risk endpoint is a separate position collection.
- *Live observation:* the funded hedge-mode account returned `dualSidePosition: true`, 96
  account position slots, and 144 position-risk rows. Unified positions remove zero contracts
  for consumer use, but the raw response-shape asymmetry is asserted and not normalized away.
- *Our carve:* balance reads the account assets; positions read position risk. The two endpoint
  collections are not assumed to have equal cardinality.

**C-T450d — hedge-mode order semantics and safe lifecycle use explicit position side (task 450). Outcome: CONFIRM VENUE.**

- *Exchange semantics:* Binance's COIN-M new-order contract requires `positionSide` in Hedge
  Mode, identifies orders by `orderId` or `origClientOrderId`, and supports symbol-scoped query
  and cancellation.
- *Live observation:* a far-from-market `BTCUSD_PERP` LIMIT BUY of one contract with
  `positionSide=LONG` and `GTC` progressed `NEW → NEW → CANCELED`, leaving no open order.
  Omitting `positionSide` returned `-4061`; an oversized order returned `-2019`. The latter is
  pinned with its currently observed `exchange_not_available` classification pending the
  separate scoped-error-map defect.
- *Our carve:* the tagged integration test creates only a resting one-contract order and
  targets cleanup by its unique client id. A separate acknowledgement test pins the
  idempotent cancel-all response without using symbol-wide cancellation as cleanup.

## 2026-07-19 — cancel-all acknowledgement shape (Task 395)

**C-T395 — Binance COIN-M cancel-all acknowledgement shape (task 395).** Outcome: DIVERGE from
Bourse. Binance's [COIN-M Cancel All Open Orders](https://binance-docs.github.io/apidocs/delivery_testnet/en/#cancel-all-open-orders-trade)
documents `DELETE /dapi/v1/allOpenOrders` returning
`{"code": "200", "msg": "The operation of cancel all open order is done."}`. This is an
acknowledgement, not an order collection. The unified return therefore preserves the venue body
rather than manufacturing an all-nil `%Bourse.Order{}` row; the frozen CCXT order list is an
expected tier-2 red under the C-T395 whole-result contract.

## Historical confrontations (moved from authored-specs.md, task 466)

**C-T322a — Binance inverse `fetchMarginMode` selects the requested position and reads `isolated`. Outcome: CONFIRM VENUE + ALIGNED-to-ccxt (task 322).**

- *Exchange semantics (non-CCXT):* Binance's [COIN-M Position Information](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-coin-m-futures/api/rest-api/trade#position-information) returns a `positions[]` collection whose rows carry the native `symbol`; its inverse margin-mode row carries `isolated` rather than the flat USD-M `marginType` field. The [USD-M Position Information V3](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#position-information-v3) separately documents its flat position-risk row and native `symbol` identity.
- *Live observation (2026-07-17):* signed `Bourse.fetch_positions/1` against `testnet.binancefuture.com` with `BINANCE_FUTURES_TEST_API_KEY/SECRET` succeeded with `[]`; that key had no open testnet position, so it cannot establish non-zero collateral or margin values. The fixture remains the tier-2 compatibility oracle for the populated inverse row.
- *CCXT's carve:* select `BTCUSD_PERP` for the requested `BTC/USD:BTC` market from the inverse `positions[]` response, then map `isolated: false` to `cross` (and `true` to `isolated`).
- *Our carve + rationale:* load the authored `positions` envelope for inverse margin-mode responses, resolve the requested market through the caller-threaded market cache, select the matching native row before parsing, and normalize `isolated` into the authored margin-mode field. The linear `marginType` response remains supported through the same authored field.

- *Live confrontation of the linear shape (2026-07-17, tier 1):* signed `Bourse.fetch_margin_mode(ex, "BTC/USDT:USDT")` against `testnet.binancefuture.com` returned `%Bourse.MarginMode{margin_mode: "cross"}` over a **bare row list** (`[{"symbol": "BTCUSDT", "marginType": "CROSSED", ...}]`) — the venue's own USD-M `positionRisk` answer, matching the shape CCXT's `linear swap fetch margin mode` fixture records. The two margin-mode shapes are therefore a real venue divergence (inverse: `positions[]` envelope + `isolated`; linear: bare list + `marginType`), not a CCXT artifact, so the `positions` envelope must miss cleanly on a non-map body rather than probe it for a map key.
- *Compatibility cost:* none; the offline replay cases (binance inverse, binanceusdm linear), an inverse/linear parser test, and a linear `positionRisk` list-body parser test pin the selection and both response shapes.
- *Implementation:* task 322.

## Evidence status records

<!-- carve-evidence-status
{"carve_id":"C-T515c","date":"2026-07-26","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binancecoinm/errors.json: -2019 MARGIN_NOT_SUFFICIEN; -4061 POSITION_SIDE_NOT_MATCH"},"observed_evidence":{"kind":"live_venue","reference":"Tagged COIN-M demo oversized-order integration test returns -2019 Margin is insufficient and asserts :insufficient_funds/:non_retryable"},"compatibility_reference":{"kind":"ccxt","reference":"Scoped exact-map targets are compatibility input; conflicting scopes remain separate"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T395","date":"2026-07-25","semantic_source":{"kind":"provider_owned","reference":"Binance COIN-M Cancel All Open Orders response schema cited in C-T395"},"observed_evidence":{"kind":"live_venue","reference":"Live demo DAPI DELETE allOpenOrders returned code 200 with the documented acknowledgement after targeted lifecycle cleanup"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT frozen fixture parses the acknowledgement as an order list"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T322a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T322a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T322a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T322a and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T450a","date":"2026-07-25","semantic_source":{"kind":"provider_owned","reference":"Pinned Binance developer-docs-full COIN-M general information"},"observed_evidence":{"kind":"live_venue","reference":"Live demo and legacy DAPI account/balance host comparison plus tagged promotion integration test"},"compatibility_reference":{"kind":"ccxt","reference":"Pinned binancecoinm 4.5.57 reference supplies compatibility inventory only"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T450b","date":"2026-07-25","semantic_source":{"kind":"provider_owned","reference":"Pinned Binance COIN-M exchange-information and order semantics"},"observed_evidence":{"kind":"live_venue","reference":"Live markets and one-contract BTCUSD_PERP lifecycle in binancecoinm promotion integration test"},"compatibility_reference":{"kind":"ccxt","reference":"Task 415 fixture and pinned reference are compatibility evidence only"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T450c","date":"2026-07-25","semantic_source":{"kind":"provider_owned","reference":"Pinned Binance COIN-M account and position-information semantics"},"observed_evidence":{"kind":"live_venue","reference":"Live account positions and positionRisk cardinalities asserted by tagged promotion integration test"},"compatibility_reference":{"kind":"ccxt","reference":"Pinned reference parser decisions are secondary input"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T450d","date":"2026-07-25","semantic_source":{"kind":"provider_owned","reference":"Pinned Binance COIN-M new/query/cancel order and error-code contracts"},"observed_evidence":{"kind":"live_venue","reference":"Live hedge-mode create/fetch/cancel, -4061, and -2019 observations pinned by tagged integration tests"},"compatibility_reference":{"kind":"ccxt","reference":"Pinned reference supplies method names and compatibility behavior only"},"resolved_tier":1}
-->

## 2026-07-26 — public market-symbol round trip (Task 525)

**C-T525b — A COIN-M perpetual keeps its quote asset when denormalized for DAPI (task 525).
Outcome: CONFIRMED provider contract.**

- *Exchange semantics:* Binance's COIN-M exchange-information response publishes the native
  trading symbol, and the 24-hour ticker endpoint accepts that symbol in its singular `symbol`
  query parameter. The BTC perpetual is `BTCUSD_PERP`.
- *Live observation:* the demo exchange-information response parsed `BTCUSD_PERP` into
  `BTC/USD:BTC`. Passing that returned unified symbol to an unloaded exchange first emitted
  `BTC_PERP` and received `-1121 "Invalid symbol."`; the authored `suffix_swap` carve now emits
  `BTCUSD_PERP`, and the same demo request returns a populated ticker.
- *Our carve:* inverse perpetual denormalization concatenates base and quote before `_PERP`.
  Settlement remains encoded only in the unified `:BTC` suffix; no caller or loaded-market cache
  special case is required.
- *Verification:* the offline request capture asserts the exact DAPI query, and the ten-venue live
  smoke selects `BTC/USD:BTC` from the current demo `fetch_markets` result before calling
  `fetch_ticker` on the original exchange.

<!-- carve-evidence-status
{"carve_id":"C-T525b","date":"2026-07-26","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binancecoinm/manifest.json developer-docs-full: COIN-M exchange information and 24-hour ticker"},"observed_evidence":{"kind":"live_venue","reference":"Demo DAPI fetchMarkets returned BTCUSD_PERP/BTC/USD:BTC and the unloaded fetchTicker round trip returned a populated ticker"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-04 — funding-history window (Task 540)

**C-T540c — COIN-M funding history uses `startTime` and `endTime` millisecond bounds
(task 540). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* the provider-owned COIN-M funding-rate history contract documents
  `startTime`, `endTime`, and `limit` query parameters.
- *Our carve:* `fetchFundingRateHistory` renames unified `since`/`until` to those native fields;
  `limit` already shares the provider spelling.
- *Verification:* the ten-venue request-shape sweep pins the exact DAPI parameter names.

<!-- carve-evidence-status
{"carve_id":"C-T540c","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binancecoinm/manifest.json artifact developer-docs-full; COIN-M funding-rate history parameters"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Provider-owned semantics and offline request shape are pinned; no task-specific live window recording is registered"}
-->

**C-T592a — COIN-M income types and signed direction come from the complete Income History
contract (task 592). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* `GET /dapi/v1/income` documents `TRANSFER`, `WELCOME_BONUS`,
  `FUNDING_FEE`, `REALIZED_PNL`, `COMMISSION`, `INSURANCE_CLEAR`, and
  `DELIVERED_SETTELMENT`; `income` is signed.
- *Our carve:* `INSURANCE_CLEAR` normalizes to `settlement`, while the sign of `income`
  produces `direction` (`out` when negative, `in` otherwise). Defensive family aliases
  remain allowed beyond the documented COIN-M set.
- *Verification:* the documented-set guard pins the complete provider vocabulary, and the
  provider-shaped negative income fixture pins `direction: "out"` offline.

<!-- carve-evidence-status
{"carve_id":"C-T592a","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binancecoinm/manifest.json artifact developer-docs-full; COIN-M Get Income History contract"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The demo account returned an empty income history; the complete enum and signed direction are pinned from the provider contract and provider-shaped offline parser fixture"}
-->

## 2026-08-12 — rate-unit confrontation (Task 594)

**C-T594c — Binance COIN-M's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM documented and arithmetic-derived units; retain explicit gaps.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.adl_rank.field_map.percentage` | absent; no emitted percentile or unit | The authored slot is null; the provider exposes a quantile rank rather than a percentage field. [Position ADL quantile](https://developers.binance.com/docs/derivatives/coin-margined-futures/trade/rest-api/Position-ADL-Quantile-Estimation) |
| `normalization.field_maps.borrow_interest.field_map.interestRate`, `normalization.field_maps.borrow_rate.field_map.rate` | unverified | COIN-M publishes no borrow principal/rate/interest operation for these carried rules, so no venue-owned arithmetic establishes their unit. They are recorded as unverified rather than inferred from the sibling product. [COIN-M account API](https://developers.binance.com/docs/derivatives/coin-margined-futures/account/rest-api) |
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for `fundingRate` / `interestRate`; absent for null history-payment, next-rate, and previous-rate slots | Binance defines funding payment from position notional and the decimal funding rate; COIN-M publishes `lastFundingRate`, `interestRate`, and history `fundingRate` in that fraction. The null slots emit no rate. [Funding formula](https://www.binance.com/en/support/faq/introduction-to-binance-futures-funding-rates-360033525031) [COIN-M premium index](https://developers.binance.com/docs/derivatives/coin-margined-futures/market-data/rest-api/Index-Price-and-Mark-Price) |
| `normalization.field_maps.leverage_tiers.field_map.maintenanceMarginRate` | fraction | The COIN-M leverage-bracket contract publishes `maintMarginRatio` as a decimal ratio, with examples such as `0.004` for 0.4%. [Leverage brackets](https://developers.binance.com/docs/derivatives/coin-margined-futures/account/rest-api/Notional-Bracket-for-Symbol) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The authored market fee-mode flag is null; rate fields are separate. [Commission rate](https://developers.binance.com/docs/derivatives/coin-margined-futures/account/rest-api/User-Commission-Rate) |
| `normalization.field_maps.option.field_map.percentage`, `normalization.field_maps.ticker.field_map.percentage` | percent points | Binance names `priceChangePercent` as percent change and publishes it in percent points; the authored mappings do not multiply by 100. [COIN-M 24hr ticker](https://developers.binance.com/docs/derivatives/coin-margined-futures/market-data/rest-api/24hr-Ticker-Price-Change-Statistics) |
| `normalization.field_maps.option_position.field_map.initialMarginPercentage`, `normalization.field_maps.option_position.field_map.maintenanceMarginPercentage`, `normalization.field_maps.option_position.field_map.percentage` | absent; no emitted percentage or unit | All three authored option-position percentage slots are null. [Binance Options position information](https://developers.binance.com/docs/derivatives/option/trade/Option-Position-Information) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | fraction | The authored arithmetic divides provider margin amounts by provider notional; `0.1` represents 10%. [COIN-M position information](https://developers.binance.com/docs/derivatives/coin-margined-futures/trade/rest-api/Position-Information) |
| `normalization.field_maps.position.field_map.percentage` | percent points | The authored arithmetic is `unRealizedProfit / initialMargin × 100`; the provider contract supplies both monetary operands. [COIN-M position information](https://developers.binance.com/docs/derivatives/coin-margined-futures/trade/rest-api/Position-Information) |
| `normalization.field_maps.trading_fee.field_map.maker`, `normalization.field_maps.trading_fee.field_map.taker`, `normalization.field_maps.trading_fees.field_map.maker`, `normalization.field_maps.trading_fees.field_map.taker` | fraction | The COIN-M commission endpoint publishes decimal maker/taker rates; the authored fields retain the fraction. [User commission rate](https://developers.binance.com/docs/derivatives/coin-margined-futures/account/rest-api/User-Commission-Rate) |
| `normalization.field_maps.trading_fee.field_map.percentage`, `normalization.field_maps.trading_fees.field_map.percentage` | absent boolean; no numeric unit | Both fee-mode flags are null; decimal maker/taker rates carry the numeric unit. [User commission rate](https://developers.binance.com/docs/derivatives/coin-margined-futures/account/rest-api/User-Commission-Rate) |
| `fees.trading.maker`, `fees.trading.taker`, `fees.linear.trading.maker`, `fees.linear.trading.taker`, `fees.inverse.trading.maker`, `fees.inverse.trading.taker`, `fees.linear.trading.tiers.maker[*].rate`, `fees.linear.trading.tiers.taker[*].rate`, `fees.inverse.trading.tiers.maker[*].rate`, `fees.inverse.trading.tiers.taker[*].rate` | fraction | Static schedule values are decimal fractions; the account commission endpoint is authoritative for the effective COIN-M rate. The carried spot/linear schedules are not COIN-M runtime evidence. [COIN-M commission rate](https://developers.binance.com/docs/derivatives/coin-margined-futures/account/rest-api/User-Commission-Rate) |

<!-- carve-evidence-status
{"carve_id":"C-T594c","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance COIN-M funding, ticker, position, ADL, and commission contracts linked in C-T594c"},"observed_evidence":{"kind":"recorded_venue","reference":"Registered COIN-M funding response and authored cross-field arithmetic"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The carried borrow-rate rules have no COIN-M provider operation, and the carried spot/linear static schedules are not COIN-M runtime evidence"}
-->
