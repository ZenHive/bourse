# Binance USD-M carve register

Append-only schema confrontations for Binance USD-M. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for this venue.** Historical narrative may still appear in `docs/authored-specs.md`;
this file is the complete Binance USD-M carve record.

## 2026-08-10 — flat-symbol configured leverage (Task 586)

**C-T586c — USD-M `symbolConfig` is the configured-leverage read for flat symbols (task 586).
Outcome: CONFIRM provider contract.** Binance's official
[Symbol Configuration](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/Symbol-Config)
contract defines `GET /fapi/v1/symbolConfig`, accepts an optional symbol, and returns `symbol`,
`marginType`, and integer `leverage`. Live demo FAPI returned `leverage=3` and
`marginType=ISOLATED` for flat `ETHUSDT`. The authored plural route and field map already targeted
that endpoint, but `fetchLeverage` was declared emulated without an emulation registry entry, so
the public method returned `:not_supported`. Registering the single-symbol emulation makes it
select the requested row from the same provider response; it does not depend on an open position.

<!-- carve-evidence-status
{"carve_id":"C-T586c","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M Symbol Configuration REST contract"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binanceusdm/fetch_leverages.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-10 — dedicated USD-M write routing (Task 578)

**C-T578b — The dedicated USD-M client owns the same regular and Algo books as FAPI (task 578). Outcome:
CONFIRM provider contracts.** The provider's New Algo Order contract routes conditional orders to
`/fapi/v1/algoOrder`; the regular order endpoint remains the non-conditional book. Live demo FAPI
accepted a conditional order carrying `timeInForce` and `reduceOnly=false`, accepted a symbol-scoped
margin-type change with `marginType=CROSSED`, and returned `code=200` from both regular and Algo
cancel-all calls. Before the repair, the dedicated create route omitted the order controls and the
margin-mode shape put `ETHUSDT` in `marginType`. Reasserting the live one-way position mode now
reaches business validation `-4059` with `dualSidePosition=false` instead of losing the boolean and
failing `-1102`.

<!-- carve-evidence-status
{"carve_id":"C-T578b","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M New Algo Order, Change Margin Type, Change Position Mode, and cancel-all contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/exchange_accepted_requests/binanceusdm/create_order.json, set_margin_mode.json, cancel_all_orders.json, and set_position_mode.json; live position-mode regression test reached -4059"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-10 — current funding-rate cadence (Task 573)

**C-T573b — A direct current-rate read applies the existing per-symbol funding-interval carve (task 573).
Outcome: CONFIRM venue.** C-T539b established `fundingIntervalHours` as the provider cadence
source, but `fetchFundingRate` reads `premiumIndex`, whose row does not carry that field. The
direct read now joins `GET /fapi/v1/fundingInfo` by native symbol and uses the `8h` default from
Binance's own
[Introduction to Binance Futures Funding Rates](https://www.binance.com/en/support/faq/introduction-to-binance-futures-funding-rates-360033525031)
only for perpetual contracts with a positive `nextFundingTime`. An inverse symbol selects DAPI
for both `fetchFundingRate` and its funding-info join. Live demo FAPI changed the unified BTCUSDT
result from `interval: nil` to `interval: "8h"`.

<!-- carve-evidence-status
{"carve_id":"C-T573b","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M Funding Rate Info contract cited by C-T539b and FAQ 360033525031"},"observed_evidence":{"kind":"live_venue","reference":"Live binanceusdm BTCUSDT premiumIndex plus fundingInfo returned unified interval 8h on 2026-08-10"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-04 — documented order-status coverage (Task 538)

**C-T538c — USD-M order statuses cover Binance's complete published vocabulary (task 538).
Outcome: CONFIRM venue; documentation-anchored, live-unverified.** Binance's official USD-M
[order-status definition](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures/common-definition#order-status-status)
includes `EXPIRED_IN_MATCH`; it is terminal and maps to unified `canceled`. The runtime-wide
provider-status coverage test pins the complete list.

<!-- carve-evidence-status
{"carve_id":"C-T538c","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M common-definition order-status enum"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No live order-history row carrying EXPIRED_IN_MATCH is registered"}
-->

## 2026-07-30 — multi-assets balance axes and trading-fee scope (Task 530)

**C-T530a — USD-M balance fields remain on provider-defined per-asset axes in Multi-Assets
Mode (task 530). Outcome: DIVERGE from subtracting `availableBalance` from
`walletBalance`.** Binance's
[Account Information V3](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/Account-Information-V3)
defines each asset's wallet balance, initial margin required, maximum withdrawal, and available
balance as distinct fields. The 2026-07-30 demo-fapi capture at
`test/fixtures/responses/binanceusdm/fetch_balance.json` records a BNB row with zero wallet and
margin balances, zero maximum withdrawal, but positive converted `availableBalance`.
That observed combination establishes that `availableBalance` is cross-asset capacity in this
Multi-Assets account, not BNB held or reserved.
Consequently, the authored unified axes are `total = walletBalance`,
`used = initialMargin`, and `free = maxWithdrawAmount`. The former
`walletBalance - availableBalance` calculation mixed wallet units with cross-asset buying
capacity and fabricated a negative used balance that Binance never states.

**C-T530b — USD-M exposes a symbol-scoped commission rate, not a bulk trading-fee
schedule (task 530). Outcome: CONFIRM venue; DIVERGE from advertising
`fetchTradingFees`.** Binance's
[User Commission Rate](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate)
requires `symbol` and returns `makerCommissionRate` / `takerCommissionRate`.
Live demo-fapi traffic on 2026-07-30 confirmed a populated BTCUSDT success and Binance
`-1121` for an invalid symbol. Binance's
[Futures Account Configuration](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/Account-Config)
contract and the live `GET /fapi/v1/accountConfig` response report account configuration such
as `feeTier`; they do not provide per-market maker/taker rates. Therefore
`fetchTradingFee(symbol)` remains supported through `/fapi/v1/commissionRate`, while the
plural `fetchTradingFees` capability is explicitly unsupported rather than parsed into an
all-nil fee.

## 2026-07-26 — market-scoped error boundary (Task 515)

**C-T515b — Binance USD-M's heterogeneous raw exception maps stay outside its authored contract
(task 515). Outcome: DIVERGE from treating the raw projection as provider-authored.**

The USD-M-owned `errors.handle_errors.exceptions` slice deliberately retains only its authored
top-level map. Its frozen `raw.describe.exceptions` bundle also contains spot, COIN-M, option, and
portfolio-margin scopes that the USD-M authority enumeration does not own, so lifting the bundle
wholesale would mislabel compatibility data as provider-authored. Runtime selects the raw map by
the API family actually called, with a scoped entry overriding a conflicting top-level entry.
The provider-owned USD-M enumeration confirms `-2019` as `MARGIN_NOT_SUFFICIEN` and `-4061` as
`POSITION_SIDE_NOT_MATCH`; the raw maps' distinct class targets remain tier-2 compatibility data
rather than one flattened or falsely authored class.

## 2026-07-22 — position ratios and precision (Task 438)

**C-T438a — USD-M `fetchPositions` uses only position-risk-row inputs for margin ratios and
percentage PnL (task 438).** Outcome: DIVERGE from CCXT on cross `margin_ratio` and on precision.
The [USD-M Position Information V3](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#position-information-v3)
row ([pinned authority manifest](../../priv/authority/binanceusdm/manifest.json), artifact
`developer-docs-full`) directly states `unRealizedProfit`, `initialMargin`, `maintMargin`, and `notional`, but states
neither cross-account collateral nor `marginRatio`. A live testnet BTCUSDT position lifecycle on
2026-07-22 confirmed those fields on the same row. We therefore preserve `maintMargin` at the
venue's stated precision, compute percentage PnL as `unRealizedProfit / initialMargin * 100`
rounded to two percentage-point decimals, and leave cross `margin_ratio` nil. CCXT instead
recomputes maintenance margin from notional, truncates an intermediate percentage ratio, and
imports account collateral to produce a ratio; the frozen `2.43009666712` / `6.72` / `0.0945`
values are compatibility outputs, not the position-row contract.

## 2026-07-19 — position value axes (Task 334)

**C-T334a — USD-M `fetchPositions` position-risk rows do not state cross-account collateral
(task 334).** Outcome: CONFIRMED against the [USD-M Position Information V3](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#position-information-v3)
authority and a live testnet position lifecycle. The row's `positionAmt`, `notional`,
`leverage`, `initialMargin`, `maintMargin`, and `marginType` describe the position; they do not
carry a cross-account collateral balance. Therefore linear `contract_size` is the loaded market's
unit size (1 for BTCUSDT), `notional` is the absolute venue `notional`, and initial/maintenance
margin stay separate from collateral. A direct cross-margin position-risk row sets
`collateral: nil`; `isolatedMargin` is used only for an isolated row. The static CCXT fixtures
that populate cross collateral from a different account read are tier-2 compatibility residuals,
not authority to invent a zero collateral value.

## 2026-07-19 — dormant futuresTransfer / verifyGiftCode request slots (Task 418)

**C-T418c — Binance USD-M `futuresTransfer` request bindings (task 418).** Outcome: CONFIRMED
against CCXT JS (`binance.ts` `futuresTransfer`, `@ignore` internal helper; USD-M inherits the
spot family method). Same binding and non-exposure decision as the spot carve
`docs/authored-spec-carves/binance.md` § C-T418a: optional `asset` ← `code`, `amount` ←
`amount`, `type` ← `type`. Unified transfer path is unchanged.

**C-T418d — Binance USD-M `verifyGiftCode` request binding (task 418).** Outcome: CONFIRMED
against CCXT JS (`binance.ts` `verifyGiftCode`). Same binding and non-exposure decision as the
spot carve § C-T418b: optional `referenceNo` ← `id`.

## 2026-07-19 — default_family linear + no-arg multi-endpoint selection (Task 378)

**C-T378c — Binance USD-M `default_family: "linear"` (task 378).** Outcome: CONFIRMED against
live testnet catalog shape (tier 1). No-arg multi-endpoint reads default to the USD-M linear
fapi surface; explicit `subType=inverse` / `type=inverse` / `type=future` select COIN-M dapi.
Live 2026-07-19: `fetch_funding_rates()` → fapi premiumIndex (~700+ rows);
`fetch_funding_rates(subType: "inverse")` → dapi premiumIndex (~40 rows). CCXT-JS
`defaultSubType: "linear"` is tier-2 reference only. Authored
`endpoints.request.endpoint_selection` entries (fetchTickers / fetchPositions /
fetchOpenOrders / fetchFundingRates / fetchTime and the broader no-arg-read set) carry the
preferred path within each family; the venue-local `@binanceusdm_preferred_paths` clauses in
`Bourse.Unified` are removed.

## 2026-07-19 — acknowledgement order values (Task 381)

**C-T381b — Binance USD-M conditional/algo cancel acknowledgement fill (task 381).** Outcome:
DIVERGE from Bourse. The USD-M [Cancel Algo Order](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#cancel-algo-order)
schema and a 2026-07-19 testnet acknowledgement expose `algoId`, `clientAlgoId`, `code`, and
`msg`, with no `executedQty` or other fill field. A missing field is not a zero fill, so sparse
acknowledgements retain `filled: nil`; the CCXT fixture's `filled: 0` is an expected tier-2 red
under the C-T381b divergence contract.

The divergence spans the whole USD-M algo surface, not only the bare cancel acknowledgement: the
conditional `createOrder` / `fetchOrder` / `fetchOrders` / `fetchOpenOrders` rows carry `algoId`
and full request echo but still no `executedQty`, so they state no fill either. Because CCXT
derives `cost` and `remaining` from the invented `filled: 0`, those two values are invented as
well and are contracted alongside it; C-T381b selects on `info.algo_id` and fires only where we
declined to state a value CCXT manufactured.

**C-T381c — Binance USD-M cancel-all acknowledgement shape (task 381).** Outcome: DIVERGE from
Bourse. A 2026-07-19 testnet `DELETE /fapi/v1/allOpenOrders` returned
`{"code": 200, "msg": "The operation of cancel all open order is done."}`. Binance's
[Cancel All Open Orders](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures/trade/rest-api/Cancel-All-Open-Orders)
response schema is that acknowledgement, not an order collection. The unified return preserves
the explicit venue acknowledgement rather than fabricating an all-nil `%Bourse.Order{}` row; the
frozen CCXT list is an expected tier-2 red under C-T381c's whole-result contract.

## 2026-07-18 — request identifier bindings (Task 341)

**C-T341b — Binance USD-M request identifiers (task 341).** Outcome: CONFIRM VENUE, no divergence from
Bourse. The authored bindings preserve Binance's native asset, symbol, record, and position-mode
keys while sourcing their corresponding unified inputs. The USD-M testnet accepts a symbol-filtered
order-list read and returns `-2013` for a deliberately nonexistent order id, proving the request
reaches venue business validation. No valid mutating request is sent.

## 2026-07-18 — batch-order element allowlist (Task 337)

- **Endpoint confronted:** `POST /fapi/v1/batchOrders` on `testnet.binancefuture.com`, 2026-07-18.
- **Pinned reference:** `priv/specs/json/output/binanceusdm.json` (`ccxt_version` `4.5.57`, `schema_version` `4.13.0`).
  Note both are *our vendored spec's* pins, not a Binance-published API revision — Binance does not
  version the USD-M New Order table. CCXT is the tier-2 reference here; the tier-1 anchor is the live
  probe set below, which is what the allowlist is actually answerable to.
- **Decision:** explicit native-key, order-type-scoped allowlist; unknown and inapplicable caller keys raise client-side rather than being forwarded or silently discarded.
- **Allowlist:** `reduceOnly`, `positionSide`, and `selfTradePreventionMode` for all supported element types; `closePosition`, `workingType`, and `priceProtect` for `STOP_MARKET`/`TAKE_PROFIT_MARKET`; `workingType` and `activationPrice` for `TRAILING_STOP_MARKET`; `workingType`/`priceProtect` for `STOP`/`TAKE_PROFIT`; `priceMatch` for `LIMIT`/`STOP`/`TAKE_PROFIT`; and `goodTillDate` for `LIMIT`/`STOP`/`TAKE_PROFIT` when `timeInForce` is `GTD`.
- **Constraints (all raise client-side with the offending key named):**
  - `priceMatch` and `price` are mutually exclusive, and a priced element (`LIMIT`/`STOP`/`TAKE_PROFIT`)
    must carry exactly one of them — omitting both is a caller error, not a field to drop.
  - `closePosition: true` sizes itself from the open position, so it excludes both `amount` and
    `reduceOnly`. An explicit `closePosition: false` is legal and does not trip the exclusion.
  - `goodTillDate` requires `timeInForce` `GTD`.
- **Live evidence (tier 1, A/B on one otherwise-identical LIMIT element):**
  - `reduceOnly` as JSON boolean `true` → `-1102` (representation rejected).
  - `reduceOnly` as the native string `"true"` → `-2022 "ReduceOnly Order is rejected."` — a business
    error that names the field, proving it was parsed and honored rather than generically refused.
  - The builder therefore serializes boolean callers as `"true"`/`"false"` before submission.
  - Probe hygiene: the price must be rounded to the symbol's tick (LTCUSDT `0.01`) or the element dies
    at `-1111` *before* the venue evaluates `reduceOnly`, which would be a generic rejection and not
    evidence for this carve.
- **Not confirmed live:** the conditional family (`activationPrice`, `closePosition` on `STOP_MARKET`)
  — testnet rejects those batch elements wholesale with `-4120`. Tracked in
  `docs/prod-verification-ledger.md`; those slices stay tier-2 until that entry closes.

## Historical confrontations (moved from authored-specs.md, task 466)

**C-T321a — Binance USD-M `timeInForce=GTX` is Post Only. Outcome: CONFIRM VENUE + ALIGNED-to-ccxt (task 321).**

- *Exchange semantics (non-CCXT):* Binance USD-M / Portfolio Margin common definitions document
  `GTX` as **"Good Till Crossing (Post Only)"**
  ([USD-M futures common definition](https://developers.binance.com/docs/derivatives/usds-margined-futures/common-definition);
  [portfolio-margin common definition](https://developers.binance.com/docs/derivatives/portfolio-margin/common-definition);
  support note: GTX orders that cannot rest as maker are rejected with `-5022`). Spot uses
  `LIMIT_MAKER` type for post-only; USD-M keeps `type=LIMIT` and encodes post-only on TIF.
- *CCXT's carve:* maps wire `timeInForce: "GTX"` → unified `timeInForce: "PO"` and
  `postOnly: true` (see CCXT issue #11830: GTX is not a portable CCXT TIF token).
- *Our carve + rationale:* `annotate_binance_order/1` synthesises `_bourse_time_in_force` (GTX→PO)
  and `_bourse_post_only` (`LIMIT_MAKER` **or** `GTX`). Authored order field map reads those keys.
  **CONFIRM venue** for the Post-Only meaning of GTX; **ALIGNED-to-ccxt** for the `PO` token
  (tier-2 portable vocabulary).
- *Implementation:* task 321.

**C-T321b — Binance order `lastTradeTimestamp` from `updateTime` on FILLED. Outcome: CONFIRMED LIVE + ALIGNED-to-ccxt (task 321).**

- *Exchange semantics (non-CCXT):* USD-M / papi order objects expose `time` (create) and
  `updateTime` (last status change). There is **no** dedicated last-trade timestamp field on
  `GET /fapi/v1/allOrders` / papi UM allOrders. Binance documents `updateTime` as the last
  update to the order (placed / filled / canceled). For a `FILLED` order the final update is
  the fill, so `updateTime` is a faithful last-trade proxy; for `CANCELED` after a partial fill
  it is the cancel clock, not the last fill — so we only stamp on `status == "FILLED"`.
- *CCXT's carve:* sets `lastTradeTimestamp` from `updateTime` on filled portfolio-margin orders
  (static fixture `fetch portfolio margin orders`).
- *Our carve + rationale:* synthetic `_bourse_last_trade` only when status is `FILLED`. A live
  USD-M testnet market fill on 2026-07-23 returned `last_trade_timestamp = 1784766919776`,
  exactly equal to the maximum timestamp of the matching `fetch_my_trades` row. The reversible
  0.002 BTC cycle left no position or open order. This confirms the terminal-fill proxy against
  venue behavior; the CCXT fixture remains compatibility evidence.
- *Implementation:* task 321.

**C-T321c — Binance funding-history `rate` is absent on wire. Outcome: DIVERGE (additive nil) (task 321).**

- *Exchange semantics:* Binance `GET /fapi/v1/income` / papi um income rows carry
  `income`/`asset`/`time`/`tranId` — no funding-rate field. CCXT `parseIncome` omits `rate`.
- *Our carve:* `%Bourse.FundingHistory{}` always materializes `rate` (owned schema; bybit supplies
  `feeRate`). For binanceusdm income rows `rate` is legitimately `nil`. Contract **C-T321c**
  drops the additive nil key before strict T-A compare so the richer struct does not fail the
  older CCXT golden.
- *Implementation:* task 321.

**C-T321d — Binance `fetchPositionADLRank` is the singular adlQuantile read. Outcome: CONFIRM VENUE + ALIGNED-to-ccxt (task 321).**

- *Exchange semantics (non-CCXT):* USD-M exposes ADL quantile via signed
  `GET /fapi/v1/adlQuantile` (and papi/dapi siblings). The public `GET /fapi/v1/symbolAdlRisk`
  is a **different** surface (`adlRisk` string rating) already wired as `fetchADLRank`.
- *CCXT's carve:* plural `fetchPositionsADLRank` hits adlQuantile; singular
  `fetchPositionADLRank(symbol)` is the same payload filtered to one market (fixture
  `linear swap fetchPositionADLRank` records the adlQuantile row shape with `BOTH` rank).
- *Our carve + rationale:* author `endpoints.unified.fetchPositionADLRank` onto the same
  quantile interfaces as `fetchPositionsADLRank` (`fapiPrivateGetAdlQuantile`,
  `dapiPrivateGetAdlQuantile`, papi cm/um). Not a non-support — the venue endpoint exists and
  the fixture is the quantile shape, not symbolAdlRisk.
- *Implementation:* task 321.

**C-T332 — Binance USD-M batch-order elements follow each order type's required fields. Outcome: CONFIRM VENUE for LIMIT/MARKET; DEFERRED (tier 2) for the conditional family (task 332).**

- *Exchange semantics (non-CCXT):* Binance's [Place Multiple Orders](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#place-multiple-orders) states that batch parameter rules match New Order. Its [New Order](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#new-order) table requires `quantity` for MARKET; `quantity`, `price`, and `stopPrice` for STOP/TAKE_PROFIT; `stopPrice` for STOP_MARKET/TAKE_PROFIT_MARKET; and `callbackRate` for TRAILING_STOP_MARKET. LIMIT retains `timeInForce`, `quantity`, and `price`.
- *CCXT carve:* the static `createOrders` request fixture covers only LIMIT, so it does not establish a competing shape for the other order types.
- *Our carve + rationale:* emit exactly the fields required for the selected type. MARKET carries neither `price` nor `timeInForce`; the conditional and trailing variants use Binance's documented trigger/callback fields.
- *`quantity` is a mandatory-column omission, not a forbidden field (live-corrected):* the docs table omits `quantity` for STOP_MARKET / TAKE_PROFIT_MARKET / TRAILING_STOP_MARKET only because `closePosition: true` substitutes for it — a sized order still requires it. Reading the table's minimum as the complete set made those types unplaceable: a caller-supplied `amount` was dropped and testnet answered `-1102` "Mandatory parameter 'quantity' was not sent" (observed 2026-07-17, valid symbol `LTCUSDT`). We therefore emit `quantity` whenever the caller supplies `amount`, and omit it otherwise so the closePosition path stays expressible.
- *Evidence sources (tier 1, LIMIT/MARKET only):* against `testnet.binancefuture.com` with a **valid** symbol, MARKET reaches business validation (`-4164`, notional below minimum) — proving the element is accepted and shaped correctly. The earlier invalid-symbol probe cannot discriminate here: Binance validates the symbol first and short-circuits at `-1121` before ever checking the order type, so it is green for any element shape.
- *🚨 The conditional family is rejected wholesale by this endpoint (observed 2026-07-17, tier 1):* STOP, TAKE_PROFIT, STOP_MARKET, TAKE_PROFIT_MARKET and TRAILING_STOP_MARKET each return `-4120` "Order type not supported for this endpoint. Please use the Algo Order API endpoints instead." on testnet `batchOrders`, with a valid symbol and a well-formed element (same batch shape that gets LIMIT to `-4164`). Their authored shapes are therefore **docs-derived and unverified against a venue that accepts them** — tier 2, not tier 1. Whether prod `batchOrders` also refuses them (i.e. Binance has moved conditional orders to the Algo Order API) is not falsifiable with testnet keys; see `docs/prod-verification-ledger.md`. The shapes are retained because the alternative is the `KeyError` this task fixed, but no caller should read them as confirmed.

## Evidence status records

<!-- carve-evidence-status
{"carve_id":"C-T515b","date":"2026-07-26","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binanceusdm/errors.json: -2019 MARGIN_NOT_SUFFICIEN; -4061 POSITION_SIDE_NOT_MATCH"},"observed_evidence":{"kind":"recorded_real_exchange","reference":"Existing USD-M testnet coverage pins fapi request routing and provider error envelopes"},"compatibility_reference":{"kind":"ccxt","reference":"raw.describe.exceptions remains the explicit tier-2 runtime source for heterogeneous scoped class targets"},"resolved_tier":2,"known_gap_reason":"The raw scoped class targets are deliberately excluded from the provider-authored USD-M slice"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T438a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M Position Information V3 schema cited in C-T438a"},"observed_evidence":{"kind":"live_venue","reference":"Live BTCUSDT testnet position lifecycle observed the position-risk row inputs on 2026-07-22"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT USD-M position fixtures provide the conflicting derived ratios"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T381b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M Cancel Algo Order response schema cited in C-T381b"},"observed_evidence":{"kind":"live_venue","reference":"Testnet acknowledgement observed 2026-07-19 with algo identifiers and no executedQty"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT conditional/algo fixtures synthesize filled=0"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T381c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M Cancel All Open Orders response schema cited in C-T381c"},"observed_evidence":{"kind":"live_venue","reference":"Testnet DELETE /fapi/v1/allOpenOrders returned the documented acknowledgement on 2026-07-19"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT frozen fixture parses the acknowledgement as an order list"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T321c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M income-history schema cited in C-T321c"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT income fixture and parseIncome omit rate"},"resolved_tier":2,"known_gap_reason":"No independently recorded venue income row is registered for this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T334a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T334a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T334a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T334a and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T418c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T418c and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T418c and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T418d","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T418d and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T378c","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T378c and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T378c and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T341b","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T341b and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T341b and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T321a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T321a and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T321a and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T321b","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M order schema defines updateTime as the order's last update"},"observed_evidence":{"kind":"live_venue","reference":"Filled BTCUSDT testnet order 23444179805 had last_trade_timestamp equal to its matching trade timestamp; cleanup left zero positions and orders"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT portfolio-margin order fixture carries the same FILLED-only proxy"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T321d","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T321d and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T332","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T332 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T332 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T332 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T530a","date":"2026-07-30","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M Account Information V3 and Multi-Assets Mode semantics cited in C-T530a"},"observed_evidence":{"kind":"recorded_venue","reference":"Manifest-registered demo-fapi /fapi/v3/account capture test/fixtures/responses/binanceusdm/fetch_balance.json plus live mode confirmation on 2026-07-30"},"compatibility_reference":{"kind":"ccxt","reference":"The inherited total-minus-available mapping is the compatibility behavior rejected by this carve"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T530b","date":"2026-07-30","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M User Commission Rate contract cited in C-T530b"},"observed_evidence":{"kind":"live_venue","reference":"Demo-fapi BTCUSDT commissionRate success and -1121 invalid-symbol response observed and pinned by tagged integration tests on 2026-07-30"},"compatibility_reference":{"kind":"ccxt","reference":"The inherited accountConfig bulk-fee route is the compatibility behavior rejected by this carve"},"resolved_tier":1}
-->

## 2026-08-04 — income, funding-interval, and empty ADL read semantics (Tasks 537, 539)

**C-T539a — Income rows populate ledger amount, currency, and type from the provider's
fields (task 539). Outcome: CONFIRM venue; DIVERGE from the inert inherited field map.**

- *Exchange semantics:* `GET /fapi/v1/income` publishes `income`, `asset`, and `incomeType`.
- *Our carve:* map those fields to ledger `amount`, `currency`, and `type`; retain the existing
  income-type enum normalization.
- *Live evidence:* the manifest-registered demo-fapi recording contains ten income rows, including
  a commission row with all three provider fields populated.

**C-T539b — Funding interval comes from `fundingIntervalHours` (task 539). Outcome: CONFIRM venue.**

- *Exchange semantics:* `GET /fapi/v1/fundingInfo` publishes `fundingIntervalHours` as a count of
  hours.
- *Our carve:* normalize that value to the unified duration token, such as `8h`.
- *Live evidence:* the manifest-registered demo-fapi recording contains 616 rows and every
  recorded row supplies the provider field.

**C-T537 — An empty ADL-quantile object is a successful no-position result (task 537). Outcome:
CONFIRM venue.**

- *Exchange semantics:* `GET /fapi/v1/adlQuantile` returned HTTP 200 with `{}` for an account
  holding no position.
- *Our carve:* singular `fetchPositionADLRank` returns `nil` for that exact empty object. A
  populated object that cannot map still produces a typed parse error, preserving all-nil
  detection.

<!-- carve-evidence-status
{"carve_id":"C-T539a","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binanceusdm/manifest.json artifact developer-docs-full; USD-M income-history response schema"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binanceusdm/fetch_ledger.json"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T539b","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binanceusdm/manifest.json artifact developer-docs-full; USD-M funding-info response schema"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binanceusdm/fetch_funding_intervals.json"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T537","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binanceusdm/manifest.json artifact developer-docs-full; USD-M ADL-quantile response contract"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binanceusdm/fetch_position_adl_rank.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-04 — order-history window (Task 540)

**C-T540d — USD-M order history uses `startTime` and `endTime` millisecond bounds
(task 540). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* the provider-owned USD-M all-orders contract documents `startTime`,
  `endTime`, and `limit` alongside the required symbol.
- *Our carve:* `fetchOrders` maps unified `since`/`until` to the native bounds and retains the
  provider-native `limit` spelling.
- *Verification:* the ten-venue request-shape sweep pins the exact FAPI parameter names.

<!-- carve-evidence-status
{"carve_id":"C-T540d","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binanceusdm/manifest.json artifact developer-docs-full; USD-M all-orders parameters"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Provider-owned semantics and offline request shape are pinned; no task-specific live window recording is registered"}
-->

## 2026-08-04 — order-status partitions (Task 536)

**C-T536 — Closed and canceled reads partition the USD-M all-orders response by status
(task 536). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* Binance documents `GET /fapi/v1/allOrders` as returning active,
  canceled, and filled account orders in one response.
- *Our carve:* `fetchClosedOrders`, `fetchCanceledOrders`, and
  `fetchCanceledAndClosedOrders` are emulated from `fetchOrders`; the unified status filters
  select the requested partition instead of exposing the undifferentiated response.
- *Live evidence:* USD-M demo returned 29 orders on 2026-08-04: 22 filled and 7 canceled.
  The unified closed and canceled reads returned disjoint 22- and 7-order subsets of the same
  all-orders response.

<!-- carve-evidence-status
{"carve_id":"C-T536","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M All Orders contract: GET /fapi/v1/allOrders returns active, canceled, or filled orders"},"observed_evidence":{"kind":"live_venue","reference":"USD-M demo BTC/USDT:USDT fetch_orders returned 29 mixed rows; fetch_closed_orders returned 22 closed rows and fetch_canceled_orders returned 7 canceled rows"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-08 — composite positions and unavailable API families (Task 565)

**C-T565c — Position reads must not parse leverage brackets as positions; SAPI/EAPI reads
need a reachable provider sandbox (task 565). Outcome: DIVERGE from the inherited capability
declarations.**

- *Provider boundary:* USD-M position/account responses and leverage-bracket responses are
  distinct contracts. SAPI dust/isolated-margin and EAPI option-account routes are not served by
  the USD-M demo host.
- *Live evidence:* demo-fapi returned 877 `{symbol, brackets}` carriers for the route selected by
  `fetchAccountPositions` and `fetchPositionsRisk`; the old parser produced 877 mostly-empty
  position structs. SAPI/EAPI probes had no sandbox base URL.
- *Our carve:* `fetchAccountPositions`, `fetchOptionPositions`, `fetchPositionsRisk`,
  `fetchMyDustTrades`, and `fetchIsolatedBorrowRates` are `has=false`. `fetchLeverageTiers`
  remains declared and explicitly flattens the provider's nested bracket carrier.

<!-- carve-evidence-status
{"carve_id":"C-T565c","date":"2026-08-08","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binanceusdm provider artifacts distinguish account, position-risk, and leverage-bracket responses"},"observed_evidence":{"kind":"live_venue","reference":"Task 565 demo-fapi probes observed 877 nested leverage-bracket carriers on the incorrectly selected position routes and no SAPI/EAPI sandbox host"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-09 — reachable USD-M account and position selectors (Task 534)

**C-T534a — Account positions, position risk, and configured leverage select their distinct
provider contracts (task 534). Outcome: CONFIRM provider contract.**

- *Provider boundary:* `GET /fapi/v3/account` carries account `positions`,
  `GET /fapi/v3/positionRisk` returns position-risk rows, and
  `GET /fapi/v1/symbolConfig` returns configured per-symbol leverage.
- *Our carve:* the three unified methods select those respective FAPI routes. Account positions
  unwrap the account `positions` member; leverage maps `symbol`, `leverage`, and `marginType`
  into a unified-symbol-keyed collection without dropping provider rows.
- *Live evidence:* a test-owned 0.002 BTCUSDT LONG made both position reads non-empty while the
  symbol-config response remained populated. The three scrubbed demo responses are registered
  in the reality manifest; the position was then closed and the account verified flat with no
  open orders.
- *History:* this supersedes only the USD-M position-route conclusion in C-T565c. That entry
  remains the evidence for the prior selector defect and for the still-unavailable SAPI/EAPI
  reads.

<!-- carve-evidence-status
{"carve_id":"C-T534a","date":"2026-08-09","semantic_source":{"kind":"provider_owned","reference":"priv/authority/binanceusdm/manifest.json artifact developer-docs-full; USD-M account information, position risk, and symbol configuration contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binanceusdm/fetch_account_positions.json, test/fixtures/responses/binanceusdm/fetch_positions_risk.json, and test/fixtures/responses/binanceusdm/fetch_leverages.json"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T592b — USD-M income vocabulary includes change-log additions, and signed income defines
direction (task 592). Outcome: CONFIRMED vocabulary membership; DIVERGE on the unified
mapping of the two new arms (amended 2026-08-12, ARC pass).**

- *Exchange semantics:* the Income History operation defines the row vocabulary and signed
  `income`; the provider change log additionally documents `AUTO_EXCHANGE` rather than leaving
  the endpoint page as the sole vocabulary source. The provider defines **no semantics** for
  `INSURANCE_CLEAR`, and describes `AUTO_EXCHANGE` only as a Multi-Assets-margin
  auto-exchange event — a system-initiated conversion, not an order fill.
- *Our carve:* `INSURANCE_CLEAR` normalizes to `settlement` and `AUTO_EXCHANGE` to `trade` by
  **our judgment** (the provider is silent on meaning). The official SDK's 22-value enum adds
  `STRATEGY_UMFUTURES_TRANSFER`, `FEE_RETURN`, and `BFUSD_REWARD`; the routed options Funding
  Flow contract independently evidences `FEE`. `CONTRACT` is removed. Futures rows read
  `incomeType`/`income`; options rows read fallback `type`/`amount`.
- *Direction:* negative is `out`, positive is `in`, and zero is `nil` because the provider
  assigns no flow direction to a zero amount.
- *Verification:* the two-way documented-set guard pins the official SDK sources. The registered
  populated USD-M income recording pins negative rows as `out`.

<!-- carve-evidence-status
{"carve_id":"C-T592b","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance official Java SDK a13868d0 USD-M IncomeType and options AccountFundingFlowResponseInner contracts"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/binanceusdm/fetch_ledger.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-12 — rate-unit confrontation (Task 594)

**C-T594d — Binance USD-M's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM documented and arithmetic-derived units; retain explicit gaps.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.adl_rank.field_map.percentage` | absent; no emitted percentile or unit | The authored slot is null; the provider exposes a quantile rank rather than a percentage field. [Position ADL quantile](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Position-ADL-Quantile-Estimation) |
| `normalization.field_maps.borrow_interest.field_map.interestRate`, `normalization.field_maps.borrow_rate.field_map.rate` | unverified | USD-M publishes no borrow principal/rate/interest operation for these carried rules, so no venue-owned arithmetic establishes their unit. They are recorded as unverified rather than inferred from another product. [USD-M account API](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api) |
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for `fundingRate` / `interestRate`; absent for null history-payment, next-rate, and previous-rate slots | Binance defines funding payment from position notional and the decimal funding rate; USD-M publishes `lastFundingRate`, `interestRate`, and history `fundingRate` in that fraction. The null slots emit no rate. [Funding formula](https://www.binance.com/en/support/faq/introduction-to-binance-futures-funding-rates-360033525031) [USD-M premium index](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Mark-Price) |
| `normalization.field_maps.leverage_tiers.field_map.maintenanceMarginRate` | fraction | The USD-M leverage-bracket contract publishes `maintMarginRatio` as a decimal ratio, with examples such as `0.004` for 0.4%. [Notional and leverage brackets](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/Notional-and-Leverage-Brackets) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The authored market fee-mode flag is null; rate fields are separate. [Commission rate](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate) |
| `normalization.field_maps.option.field_map.percentage`, `normalization.field_maps.ticker.field_map.percentage` | percent points | Binance names `priceChangePercent` as percent change and publishes it in percent points; the authored mappings do not multiply by 100. [USD-M 24hr ticker](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/24hr-Ticker-Price-Change-Statistics) |
| `normalization.field_maps.option_position.field_map.initialMarginPercentage`, `normalization.field_maps.option_position.field_map.maintenanceMarginPercentage`, `normalization.field_maps.option_position.field_map.percentage` | absent; no emitted percentage or unit | All three authored option-position percentage slots are null. [Binance Options position information](https://developers.binance.com/docs/derivatives/option/trade/Option-Position-Information) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | fraction | The authored arithmetic divides provider margin amounts by provider notional; `0.1` represents 10%. [USD-M position information](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Position-Information-V3) |
| `normalization.field_maps.position.field_map.percentage` | percent points | The authored arithmetic is `unRealizedProfit / initialMargin × 100`; the provider contract supplies both monetary operands. [USD-M position information](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Position-Information-V3) |
| `normalization.field_maps.trading_fee.field_map.maker`, `normalization.field_maps.trading_fee.field_map.taker`, `normalization.field_maps.trading_fees.field_map.maker`, `normalization.field_maps.trading_fees.field_map.taker` | fraction | The USD-M commission endpoint publishes decimal maker/taker rates; the authored fields retain the fraction. [User commission rate](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate) |
| `normalization.field_maps.trading_fee.field_map.percentage`, `normalization.field_maps.trading_fees.field_map.percentage` | absent boolean; no numeric unit | Both fee-mode flags are null; decimal maker/taker rates carry the numeric unit. [User commission rate](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate) |
| `fees.trading.maker`, `fees.trading.taker`, `fees.linear.trading.maker`, `fees.linear.trading.taker`, `fees.inverse.trading.maker`, `fees.inverse.trading.taker`, `fees.linear.trading.tiers.maker[*].rate`, `fees.linear.trading.tiers.taker[*].rate`, `fees.inverse.trading.tiers.maker[*].rate`, `fees.inverse.trading.tiers.taker[*].rate` | fraction | Static schedule values are decimal fractions; the account commission endpoint is authoritative for the effective USD-M rate. The carried spot/inverse schedules are not USD-M runtime evidence. [USD-M commission rate](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate) |

<!-- carve-evidence-status
{"carve_id":"C-T594d","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M funding, ticker, position, ADL, and commission contracts linked in C-T594d"},"observed_evidence":{"kind":"recorded_venue","reference":"Registered USD-M funding and commission responses plus authored cross-field arithmetic"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The carried borrow-rate rules have no USD-M provider operation, and the carried spot/inverse static schedules are not USD-M runtime evidence"}
-->

**C-T600d — Binance USD-M rate fields conform to the cross-venue unit contract (task 600).
Outcome: CONFIRM funding and option-IV fractions.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.borrow_interest.field_map.interestRate`, `normalization.field_maps.borrow_rate.field_map.rate` | fraction contract; provider source unit remains unverified | These carried spot-margin rules have no USD-M operation; any parsed value must still use the unified fraction contract. [USD-M API](https://developers.binance.com/docs/derivatives/usds-margined-futures/general-info) |
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | USD-M publishes decimal funding rates applied to position notional. [Premium index](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Mark-Price) |
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | These authored slots are null. [Premium index](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Mark-Price) |
| `normalization.field_maps.greeks.field_map.askImpliedVolatility`, `normalization.field_maps.greeks.field_map.bidImpliedVolatility`, `normalization.field_maps.greeks.field_map.markImpliedVolatility` | fraction | The Binance option mark-price response publishes decimal IV values; no scale is needed. [Option mark price](https://developers.binance.com/docs/derivatives/option/market-data/Option-Mark-Price) |
| `normalization.field_maps.option.field_map.impliedVolatility` | absent | The generic option row has no authored IV; Greeks carry it. [Option mark price](https://developers.binance.com/docs/derivatives/option/market-data/Option-Mark-Price) |

<!-- carve-evidence-status
{"carve_id":"C-T600d","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M premium-index and Binance option mark-price contracts linked in C-T600d"},"observed_evidence":{"kind":"recorded_venue","reference":"Registered USD-M funding response and provider-shaped option parser golden"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The carried borrow mappings have no USD-M provider operation"}
-->
