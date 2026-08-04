# Binance COIN-M carve register

Append-only schema confrontations for Binance COIN-M. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for Binance COIN-M's complete authored REST surface.** This file records every
venue-specific decision in the self-contained runtime document. Provider-owned evidence is
indexed by `priv/authority/binancecoinm/manifest.json`.

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
