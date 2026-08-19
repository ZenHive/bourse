# Bybit carve register

Append-only schema confrontations for Bybit. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for this venue.** Every Bybit confrontation lives here. Historical narrative may
still appear in `docs/authored-specs.md`, but that document points here for the complete
per-venue record (task 466).

## 2026-08-19 — inverse position contract unit (Task 641)

**C-T641 — V5 inverse `Position.contract_size` is the authored 1 USD contract
unit (task 641).** Outcome: CONFIRM provider contract; DIVERGE from leaving
inverse `Position.contract_size` nil and deferring to `Market.contract_size`.
Bybit's
[Order Cost](https://www.bybit.com/en/help-center/article/Order-Cost-USDT-Contract)
contract states that inverse quantity is in USD (`1 contract = 1 USD`). The
[Introduction to Inverse Contract](https://www.bybit.com/en/help-center/article/Introduction-to-Inverse-Contract)
example is the same identity: 70,000 BTCUSD contracts at $35,000 equal 2 BTC.
`GET /v5/position/list` does not send `contractSize` — the registered
`fetch_positions` row has 41 keys and that field is not one of them — so the
unit is authored, not payload-copied. Inverse `Market.contract_size` stays nil
(C-T625b): instruments-info also omits `contractSize`, and this carve does not
reopen the market recipe. C-T610's inverse-Bybit row (`contracts ×
contract_size = notional × mark`) holds because parse now stamps the unit the
provider documents.

<!-- carve-evidence-status
{"carve_id":"C-T641","date":"2026-08-19","semantic_source":{"kind":"provider_owned","reference":"Bybit Order Cost help center: inverse quantity is in USD (1 contract = 1 USD); Introduction to Inverse Contract: 70000 BTCUSD at $35000 = 2 BTC"},"observed_evidence":{"kind":"recorded_venue","reference":"Registered fetch_positions /v5/position/list row omits contractSize (41 keys). Inverse notional identity size/markPrice is the same 1 USD unit already used at parse.","fixture":"test/fixtures/responses/bybit/fetch_positions.json"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The registered recording is an option row that proves field absence on /v5/position/list; no populated inverse position row is registered, and re-recording is out of scope"}
-->

## 2026-08-18 — linear contract unit (Task 625)

**C-T625b — V5 linear `contract_size` is the authored venue-level contract unit
(task 625).** Outcome: CONFIRM provider contract; DIVERGE from treating a missing
instrument-info `contractSize` key as unknown. Bybit's
[batch place-order](https://bybit-exchange.github.io/docs/v5/order/batch-place)
contract states that Perps, Futures, and Option `qty` always use the base coin
as the unit. The
[Get Instruments Info](https://bybit-exchange.github.io/docs/v5/market/instrument)
linear example publishes `lotSizeFilter.minOrderQty` / `qtyStep` and no
`contractSize` field. Live `GET /v5/market/instruments-info?category=linear&symbol=BTCUSDT`
on 2026-08-18 returned `contractType=LinearPerpetual`, `settleCoin=USDT`,
`minOrderQty=0.001`, `qtyStep=0.001`, and no contract-size key — quantity is
already one base-coin unit. Inverse rows are not this recipe: live `BTCUSD`
publishes integer `minOrderQty=1` with `settleCoin=BTC` and also omits
`contractSize`, so inverse `Market.contract_size` stays nil. The authored
`markets.contract_unit` slot declares the linear unit as the constant `1`
with `quantity_unit: "base"`. Linear Position-path stamping (C34) is
unchanged; inverse `Position.contract_size` is the authored 1 USD unit in
C-T641.

<!-- carve-evidence-status
{"carve_id":"C-T625b","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 batch place-order qty unit is base coin for perps/futures/option; Get Instruments Info linear lotSizeFilter has no contractSize"},"observed_evidence":{"kind":"live_venue","reference":"Live api.bybit.com /v5/market/instruments-info linear BTCUSDT minOrderQty 0.001 with no contractSize; inverse BTCUSD minOrderQty 1 settleCoin BTC with no contractSize on 2026-08-18. Recorded fetch_markets test/fixtures/responses/bybit/fetch_markets.json","fixture":"test/fixtures/responses/bybit/fetch_markets.json"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT linear contractSize 1 is compatibility reference only"},"resolved_tier":1}
-->

## 2026-08-14 — remaining ledger-taxonomy splits (Task 609)

**C-T609a — `SETTLEMENT` is the funding-payment arm; amount sources `funding`, not `change`
(task 609, 614). Outcome: CONFIRM the field-level funding/cashFlow split; DIVERGE from C-T607a's
`settlement` collapse and from treating `change` as the funding amount.** Bybit's pinned V5
[UTA transaction-log enum](https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/enum.mdx#typeuta-translog)
defines `SETTLEMENT` as "USDT Perp funding settlement, and USDC Perp funding settlement + USDC
8-hour session settlement". The
[contract transaction-log enum](https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/enum.mdx#typecontract-translog)
is narrower: "USDT / Inverse Perp funding settlement". The
[Get Transaction Log](https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/account/transaction-log.mdx)
response names `feeRate` on `type=SETTLEMENT` as the funding fee rate, documents the identity
`change = cashFlow + funding - fee`, and states that USDC perp funding and the 8-hour session
P&L arrive as **one record**: `funding` is the signed funding fee (positive = receive, negative
= pay; same sign convention as `change`) and `cashFlow` is the session P&L. `transSubType` is
only `movePosition` or empty, so it is not a discriminator.

The single emitted class stays `funding_fee`, matching binance-family `FUNDING_FEE` and OKX
bill type `8`. On `type=SETTLEMENT` the unified `amount` and `direction` source `funding`, not
`change`. Linear-USDT rows where `cashFlow` is `0` keep `funding == change`, so their values
do not move. Session P&L is **intentionally not a second ledger entry**: the venue publishes
one `id` and one `cashBalance` after the combined settlement, `cashFlow` is a component of
`change` rather than an event type (it also carries close-out RPL and transfers on other
rows), and inventing a sibling `realized_pnl` row would fabricate an id and a wallet-after
the venue never sent. The residual stays on the raw row in `info.cashFlow`. Wallet
`before`/`after` still use `change`/`cashBalance` and therefore describe the combined
settlement, not the funding-only amount.

<!-- carve-evidence-status
{"carve_id":"C-T609a","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Bybit docs commit 5ccd3010 docs/v5/enum.mdx type(uta-translog)/type(contract-translog) plus Get Transaction Log funding/cashFlow/feeRate fields"},"observed_evidence":{"kind":"provider_shaped","reference":"Pinned Get Transaction Log SETTLEMENT example row (XRPUSDT funding -0.003676, cashFlow 0)"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Bybit demo transaction-log was empty on 2026-08-13; USDC combined funding+session rows are documentation-anchored"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T609a","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"Bybit docs commit 5ccd3010 docs/v5/enum.mdx type(uta-translog) SETTLEMENT plus Get Transaction Log funding/cashFlow/change identity"},"observed_evidence":{"kind":"provider_shaped","reference":"Pinned Get Transaction Log SETTLEMENT example (XRPUSDT funding == change) plus provider-doc-derived BTCPERP row (funding -0.25, cashFlow 2, change 1.75)"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Bybit demo /v5/account/transaction-log on 2026-08-18 returned one TRADE option row over the last 7 days and no SETTLEMENT rows; demo history remains server-side purged as established 2026-08-13. The mixed USDC-perp row is documentation-anchored from the pinned change identity and the documented USDC-perp symbol BTCPERP."}
-->

**C-T609b — Promotional credits and ADL casing join the cross-venue vocabulary (task 609).
Outcome: CONFIRM provider event identities; DIVERGE from treating bonus as a venue-specific
remainder and from passthrough `ADL`.** The same pinned UTA enum names `BONUS` "Bonus claimed",
`BONUS_RECOLLECT` "Bonus expired", and lists `BONUS_TRANSFER_IN` / `BONUS_TRANSFER_OUT` in the
bonus family. Those four literals emit registered `bonus`, the same class as binance-family
`WELCOME_BONUS` / `CONTEST_REWARD` / `BFUSD_REWARD` (C-T609d). `cashback` stays in the registry
for money returned; it is not this event. `ADL` is "Auto-Deleveraging" and emits venue-specific
`adl`, matching OKX bill type `9` rather than the raw `ADL` casing.

<!-- carve-evidence-status
{"carve_id":"C-T609b","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Bybit docs commit 5ccd3010 docs/v5/enum.mdx type(uta-translog) BONUS/BONUS_RECOLLECT/BONUS_TRANSFER_* and ADL"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Classifications are provider-documentation-anchored; demo transaction-log was empty on 2026-08-13"}
-->

**C-T609c — `CURRENCY_BUY` / `CURRENCY_SELL` / `CONVERT` are conversion, not trade (task 609).
Outcome: CONFIRM the provider convert identity; DIVERGE from C-T607a's uncarved `trade`
hardening.** The pinned UTA enum defines `CURRENCY_BUY` and `CURRENCY_SELL` as "Currency convert,
and the liquidation for borrowing asset (UTA loan)" and `CONVERT` as "Currency convert
repayment". The contract transaction-log enum drops the loan-liquidation clause and names both
buy/sell arms "Currency convert". `transSubType` does not distinguish convert from UTA-loan
liquidation. The single class is `conversion`, matching OKX convert bills and binance
`AUTO_EXCHANGE`. The mixed UTA-loan liquidation meaning stays in `info`.

<!-- carve-evidence-status
{"carve_id":"C-T609c","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Bybit docs commit 5ccd3010 docs/v5/enum.mdx type(uta-translog) CURRENCY_BUY/CURRENCY_SELL/CONVERT and type(contract-translog) Currency convert"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No documented row-level discriminator for the UTA-loan liquidation clause; demo transaction-log was empty on 2026-08-13"}
-->

## 2026-08-13 — registered ledger label reconciliation (Task 607)

**C-T607a — Bybit transaction-log aliases use cross-venue economic-event classes and a
venue-faithful bonus remainder (task 607). Outcome: CONFIRM provider event identities; DIVERGE
from the earlier flattened labels.** Bybit's pinned V5
[UTA transaction-log enum](https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/enum.mdx#typeuta-translog)
and
[contract transaction-log enum](https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/enum.mdx#typecontract-translog)
define the event meanings used below.

| Provider literal | Unified result | Confrontation |
|---|---|---|
| `LIQUIDATION` | `liquidation` | CONFIRMED by the provider event name; DIVERGE from the earlier `trade` alias. |
| `SETTLEMENT`, `DELIVERY` | `settlement` | CONFIRMED as funding/session settlement and futures/option delivery; DIVERGE from `trade`. |
| `INTEREST` | `interest` | CONFIRMED as interest caused by borrowing; DIVERGE from the generic `transaction` label. |
| `TRANSFER_IN`, `TRANSFER_OUT` | `transfer` | CONFIRMED as assets transferred into or out of the wallet; DIVERGE from `transaction`. |
| `FEE_REFUND` | `rebate` | CONFIRMED as a refunded trading fee; DIVERGE from the earlier `cashback` alias. |
| `BONUS` | `bonus` | CONFIRMED as a claimed bonus. No registered class names that event, so the venue-specific result is the snake_case rendering of Bybit's own literal; DIVERGE from `Prize`. |

The raw provider literal remains in `LedgerEntry.info`. Passthrough still preserves documented
types outside the mapped set; the explicit `bonus` remainder is guarded as venue-specific and
cannot be used to excuse an event that has a registered class.

<!-- carve-evidence-status
{"carve_id":"C-T607a","date":"2026-08-13","semantic_source":{"kind":"provider_owned","reference":"Bybit docs commit 5ccd3010 docs/v5/enum.mdx type(uta-translog) and type(contract-translog)"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The classifications are provider-documentation-anchored; no manifest-registered transaction-log rows cover every remapped event"}
-->

**C-T398c — Bybit option Greeks are top-level ticker fields; rho is unsupported (task 398).
Outcome: CONFIRM venue; reality tier 1.**

- *Exchange semantics:* V5 option tickers publish `delta`/`gamma`/`vega`/`theta` at the row
  top level with bid/ask/mark IV. Rho is not published. Envelope `time` is not always
  projected onto the per-row timestamp field.
- *Our carve:* `markets.greeks_conventions` maps the four supported Greeks and marks rho
  `supported: false`. When source timestamp is absent, freshness policy (`max_age_ms`) fails
  explicitly rather than inventing a clock.
- *Live evidence (2026-07-23):* OptionSurface discovery + instrument_greeks on testnet with
  call/put delta sign and range assertions.

<!-- carve-evidence-status
{"carve_id":"C-T398c","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 market tickers option Greeks fields"},"observed_evidence":{"kind":"live_venue","reference":"Bybit testnet OptionSurface discover + instrument_greeks 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T397c — Bybit option `qty` and `qtyStep` are base-asset quantities (task 397).
Outcome: CONFIRMED against provider docs and live demo; reality tier 1.**

- *Exchange semantics:* Bybit's [Get instruments info](https://bybit-exchange.github.io/docs/v5/market/instrument)
  names `lotSizeFilter.qtyStep` as the order quantity increment; its
  [Place order](https://bybit-exchange.github.io/docs/v5/order/create-order) option examples
  send that quantity as `qty`.
- *Live evidence (2026-07-23):* `BTC-25JUN27-150000-P-USDT` reported
  `qtyStep=minOrderQty=0.01`, base BTC, settlement USDT, and its native identity supplied
  expiry, strike, and put type. Demo accepted/canceled `qty=0.01`; raw `qty=0.005` returned
  `retCode=10001`, `Order quantity below the lower limit 0.01`.
- *Our carve:* canonical base exposure passes through unchanged to native `qty`; no contract
  multiplier is invented. Missing strike/type fields are recovered from the already-normalized
  option symbol without changing settlement or expiry.

<!-- carve-evidence-status
{"carve_id":"C-T397c","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Bybit instruments-info and place-order option documentation cited in C-T397c"},"observed_evidence":{"kind":"live_venue","reference":"Bybit demo qty success and below-minimum provider error observed 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T506c — Bybit option position `size` is already base exposure (task 506).
Outcome: CONFIRM venue; reality tier 1.**

- *Exchange semantics:* [Get Position Info](https://bybit-exchange.github.io/docs/v5/position)
  identifies option rows with the result `category` and defines row `size` as position size.
  C-T397c establishes that the corresponding option `qty`/`qtyStep` unit is base exposure.
- *Live evidence (2026-07-23, demo):* order
  `309f90f7-96f5-4305-a195-654f3ee4be1a` filled 0.01
  `BTC-25JUN27-150000-C-USDT`. The option position returned `size=0.01` and unified
  `BTC/USDT:USDT-270625-150000-C`, contracts 0.01. Reduce-only close order
  `bada1e47-3ef4-4758-bc7d-262bc771b9f1` left zero residual. The scrubbed position and
  instrument rows are frozen in `test/fixtures/responses/bybit/fetch_positions.json`.
- *Our carve:* the category selects option symbol grammar and the authored base-unit quantity
  passes through unchanged.

<!-- carve-evidence-status
{"carve_id":"C-T506c","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 position category and size semantics plus C-T397c option quantity unit"},"observed_evidence":{"kind":"live_venue","reference":"Bybit demo option open/position/close lifecycle orders 309f90f7-96f5-4305-a195-654f3ee4be1a and bada1e47-3ef4-4758-bc7d-262bc771b9f1; frozen fetch_positions body"},"compatibility_reference":null,"resolved_tier":1}
-->

## Cross-venue carves that bind Bybit

These keep a single global heading elsewhere; Bybit is a named party. Open those entries for
the full multi-venue rationale — do not re-adjudicate here.

| Carve | Where | Bybit outcome (summary only) |
|---|---|---|
| C36 | `global.md` | Linear: `turnover/volume` is a price (CONFIRMED, task 315). Inverse + option: nil (CONFIRMED, tasks 315/329). Evidence mirrored under [C36 Bybit application](#c36-bybit-application) below. |
| C1 | `docs/authored-specs.md` (historical) | Spot `basePrecision` member; tick-size precision mode (task 171). |
| C5 | `docs/authored-specs.md` (historical) | Per-symbol `fundingIntervalHour` → `"Nh"` (CONFIRM; task 171). Offline fixture nil when field omitted → B3. |
| C7 | `docs/authored-specs.md` (historical) | Linear stamps `contractSize: 1` at annotate (C34 / C-T625b); inverse Position unit is authored 1 USD (C-T641); inverse Market stays nil (C-T625b). |
| C28 | `docs/authored-specs.md` (historical) | UNIFIED wallet: empty `availableToWithdraw` → used = locked+IM sum (task 265/307). |
| C29 / C30 / C-T309 / C31 | `docs/authored-specs.md` (historical) | Unified positional API alignments that Bybit sweeps exposed. |

## 2026-07-22 — response 4.5.65 adjudications (Task 442)

**C-T442b — Per-network `active` preserves Bybit's directional chain status (task 442).
Outcome: DIVERGE from CCXT 4.5.65; CONFIRM venue.**

Bybit's [Get Coin Info](https://bybit-exchange.github.io/docs/v5/asset/coin-info) schema defines
`chainDeposit` and `chainWithdraw` as independent `0` (suspended) / `1` (normal) states. The
authored currency map retains both booleans and summarizes `active` as true when either direction
is available; this means the chain still has a usable funding route, while callers needing a
specific direction read `deposit` or `withdraw`. CCXT 4.5.65 leaves `active` undefined and loses
that provider-owned state. Integer-versus-float fee/limit rendering is not a second defect.

The retired compatibility baseline carried one deliberate divergence for this carve:
`fetchCurrencies default #74`.

## 2026-07-22 — Explicit currency `active` rollup declaration (Task 482)

**C-T482c — Bybit declares `active_requires_both: false` (OR) for chain-derived active
(task 482). Outcome: CONFIRM venue; extends C-T442b without superseding it.**

- *Exchange semantics:* Get Coin Info keeps `chainDeposit` and `chainWithdraw` as separate
  normal/suspended strings. Bybit's own deposit/withdrawal status surface treats each direction
  independently (a coin can show Normal deposit with Limited/suspended withdraw).
- *Our carve:* author the OR rollup **explicitly** — `active_requires_both: false` on both the
  currency-level `currency_network_summary` (`field: "active"`) rule and the
  `currency_networks` rule. This was previously the silent parser default; first-class maps may
  no longer inherit it (global C-T482). Callers that need a specific direction still read
  `deposit` / `withdraw`.
- *C-T442b status:* still true (per-network deliberate divergence from CCXT); not rewritten.

**C-T442c — Position percentage is unrealized PnL divided by initial margin (task 442).
Outcome: CONFIRM venue and align with the unified position contract.**

Bybit's [Get Position Info](https://bybit-exchange.github.io/docs/v5/position) schema defines
`unrealisedPnl` as unrealized PnL and `positionIM` as the position's initial margin. The authored
open-position branch now applies the existing `pnl_percentage` operation to those raw fields:
truncate the ratio to four decimal places, then multiply by 100. The three 4.5.65 position cases
therefore gain their provider-grounded ROI values without changing the closed-position branch.

**C-T442d — `fetchStatus` uses Bybit's system-status API, not announcements (task 442).
Outcome: DIVERGE from the fixture route; CONFIRM venue.**

Bybit documents [`GET /v5/system/status`](https://bybit-exchange.github.io/docs/v5/system-status)
specifically for maintenance and service incidents, with `scheduled`, `ongoing`, `completed`, and
`canceled` states. The authored endpoint now uses that route and reports maintenance only for an
`ongoing` event; completed history and future scheduled events do not describe a current outage.
A live testnet call on 2026-07-22 returned the documented list of completed events. The 4.5.65
fixture was recorded through `/v5/announcements/index`; its empty list is structurally compatible
with an operational result, but it no longer determines the endpoint semantics.

## 2026-07-19 — default_family linear + fetchMarkets base endpoint (Task 378)


**C-T378e — Bybit `default_family: "linear"` and `fetchMarkets` public default (task 378).**
Outcome: CONFIRMED. Bybit's residual multi-endpoint no-arg surface is small (most methods already
have `endpoint_selection`). Authored `config.default_family: "linear"` for family fall-through
parity with CCXT-JS `defaultSubType: "linear"` (tier-2). `fetchMarkets` dual public/private
configs now author `public_get_v5_market_instruments_info` as the base for param fan-out so
selection is never bare `hd(configs)`.

**C-T360 — Task 360: fetchCrossBorrowRate**

- **CONFIRMED:** Bybit V5 documents signed `GET /v5/account/collateral-info` with an
  uppercase `currency` query parameter. Its `result.list[]` rows carry `currency` and
  `hourlyBorrowRate`; the latter is the hourly borrow rate and maps to
  `Bourse.BorrowRate.rate` with a one-hour period.
- **DIVERGE:** The frozen CCXT selection `v5/spot-cross-margin-trade/loan-info` is a
  retired 404 route and used `coin`. The authored selector now uses the current account
  collateral capability and its documented `currency` spelling.
- **Evidence:** [Bybit V5 Get Collateral Info](https://bybit-exchange.github.io/docs/v5/account/collateral-info)
  ([pinned authority manifest](../../priv/authority/bybit/manifest.json), artifact
  `v5-docs-source`), plus the 2026-07-18 testnet
  observation: `currency=USDT` returned `retCode: 0` and one row with
  `hourlyBorrowRate`; an invalid currency returned `retCode: 181015`.

## Task 343 — non-convert identifier_reference request mappings (2026-07-18)

**C-T343 — Bybit non-convert identifier_reference request mappings (task 343). Outcome: CONFIRMED
for the volatility binding; the retired cross-borrow route is superseded by C-T360.**

The remaining Bybit non-convert unresolved mappings are coin selectors; convert methods remain
owned by task 347. The retained CCXT descriptor names `coin` as the selector for its legacy
cross-borrow route, while current Bybit V5 traffic shows that route is retired. Bybit's current
V5 docs define `baseCoin` as the optional uppercase underlying for
`GET /v5/market/historical-volatility` with `category=option`. The latter defaults to BTC, but the
unified call supplies an option symbol, so the authored request derives its base rather than
silently dropping the identifier.

| Method | Native key | Authored source | Bybit V5 authority |
| --- | --- | --- | --- |
| `fetchCrossBorrowRate` | `coin` | unified `code` | retained CCXT route; live 404 — superseded by task 360 (carve `C-T360`) |
| `fetchVolatilityHistory` | `baseCoin` | base of unified option symbol | `GET /v5/market/historical-volatility` |

Public testnet traffic directly observed on 2026-07-18: `category=option&baseCoin=BTC&period=7`
returned `retCode: 0`; replacing `baseCoin` with `NOPE` returned `retCode: 10001`. The integration
pins exercise that public success/error pair. `loan-info` returns HTTP 404 on testnet, demo, and
mainnet even with the documented `coin` query, so the signed mapping has only a live error pin;
success verification requires an upstream endpoint replacement and is not fabricated here.

Superseded 2026-07-18 by task 360 (carve `C-T360`): the unified selection moved to signed
`GET /v5/account/collateral-info` with a `currency` query, which returns a live populated
`hourlyBorrowRate`. The `loan-info` 404 observation above stands as the historical reason for
the move, not as current behavior.

## Historical confrontations (moved from authored-specs.md, task 466)

Full entries relocated so this register is self-contained. Evidence citations
and CONFIRMED/DIVERGE outcomes are unchanged.

**C9 — Bybit request precision follows exchange-accepted precision. Outcome: ALIGNED-to-Bourse.**

- *Exchange semantics (non-CCXT):* Bybit documents error `170134` as “order price decimal too
  long” and directs order builders to the instrument `priceFilter.tickSize`.
- *Acceptance evidence:* demo `POST /v5/order/create` rejected the three-decimal C9 shape with
  `170134` on 2026-07-22. The same signed limit-order flow with two-decimal precision returned
  `retCode=0` and an order id, and the order was cancelled successfully.
- *Our carve:* spot `LTCUSDT` request building truncates price to two decimals and retains the
  five-decimal quantity precision.
- *Compatibility outcome:* the request now matches the vendored CCXT fixture's `60.42`; the C9
  divergence contract was removed because no divergence remains.
- *Implementation:* 229, corrected by 458.

**C10 — Bybit option Greeks baseCoin follows an explicit symbol when present. Outcome: DIVERGE.**

- *Exchange semantics (non-CCXT):* Bybit V5 option ticker docs define `symbol` and `baseCoin` as
  optional filters for option tickers. Live testnet accepted
  `GET /v5/market/tickers?category=option&symbol=ETH-25JUN27-5500-P-USDT` and the same request with
  either `baseCoin=ETH` or `baseCoin=BTC`, returning the ETH option ticker in all three cases on
  2026-07-16.
- *Our carve:* when an option symbol is present and `baseCoin` is not explicit, derive `baseCoin` from
  the symbol (`ETH` for `ETH-...`) before falling back to `BTC`. This keeps the request semantically
  aligned with the symbol while preserving Bybit compatibility.
- *Compatibility cost:* CCXT-JS defaults `baseCoin` to `BTC` when the caller supplies a non-BTC option
  symbol without explicit `baseCoin`; Bybit accepts either filter alongside the explicit symbol.
- *Implementation:* 247.

**C11 — Bybit option ids carry a settle suffix only for USDT settlement. Outcome: CONFIRM Bourse.**

- *Exchange semantics (non-CCXT):* Bybit's own instrument namespace is the oracle. Live
  `GET /v5/market/instruments-info?category=option&baseCoin=BTC&limit=1000` returned 686 ids on
  2026-07-16 (mainnet and testnet agree): **686/686 end in `-USDT`, zero end in `-USDC`**. The
  USDC-settled generation is named bare (`BTC-27DEC24-55000-P`), settlement implied. A `-USDC`
  suffix is therefore a symbol form Bybit never emits and can never match an instrument.
- *Our carve:* `Bourse.Symbol.to_exchange_id/2` emits the bare option id for USDC-settled Bybit
  options and preserves the `-USDT` suffix for USDT-settled options. `fetchOptionChain` derives
  `baseCoin` from the option's base currency, not from the full option id. Matches CCXT-JS and the
  static fixture for `fetchOption` — no divergence.
- *Implementation:* 247, then moved from the `fetchOption` call site to the symbol layer in 249.

**C12 — Bybit `fetchPositionADLRank` category is derived, never a literal. Outcome: CONFIRM Bourse.**

- *Exchange semantics (non-CCXT):* Bybit V5 position docs mark `category` **required** on
  `GET /v5/position/list` and define it as the product-line selector (`linear` for BTCUSDT,
  `inverse` for BTCUSD, `option`). Live testnet 2026-07-16 confirms the venue is *lenient* rather
  than strict: `category=linear&symbol=BTCUSD` returns HTTP 200 and echoes `result.category:
  "linear"` for an inverse contract — a silently mislabelled answer, not an error. That leniency is
  precisely why a hardcoded literal is unsafe: nothing fails loudly.
- *Our carve:* `category` is derived from the unified symbol's settle coin (the shared
  `conditional_value` premarket hook), identical to `fetchPosition`, which hits the same endpoint.
  The static fixture's only case is linear; the inverse branch is pinned by offline regression tests.
- *Implementation:* 247.

**C13 — Bybit `fetchMarkets` includes complete option pages via describe types + per-baseCoin loop. Outcome: DIVERGE from CCXT (with venue evidence).**

- *Exchange semantics (non-CCXT):* Bybit V5 `GET /v5/market/instruments-info` accepts
  `category=option` without `baseCoin` (HTTP 200, retCode 0) — verified live testnet + mainnet
  2026-07-16. But a bare option call returns **only BTC** instruments (testnet n=640 BTC-only;
  mainnet n=688 BTC-only — identical to `baseCoin=BTC`). ETH/SOL/XRP/MNT/DOGE each require an
  explicit `baseCoin` (mainnet: 590/342/238/262/244). So baseCoin is not a hard request
  requirement; it is required for multi-base completeness. Live testnet 2026-07-17: a
  `limit=1000` request returns BTC 604 and ETH 624 with an empty `nextPageCursor`, versus 500 rows
  and cursor `"0%2C500"` with no `limit` — the venue's own cursor is what says the default page is
  incomplete. Status semantics come from Bybit's own `InstrumentStatus` enum
  (<https://bybit-exchange.github.io/docs/v5/enum#status>, a non-CCXT source): only `Trading`
  permits order placement; `PreLaunch`, `Delivering` (expiry/settlement), and `Closed` do not. The
  index therefore **retains** every returned row and expresses tradeability as `Market.active`:
  `Trading` → `true`, every other status → `false`. The venue cursor is the completeness signal —
  a non-empty `nextPageCursor` after the maximum-size request fails loudly, so an expanded option
  surface cannot silently regress into truncation.
- *Our carve:* fan-out variants are derived from `raw.describe.options.fetchMarkets.types`
  (`spot`/`linear`/`inverse`/`option`) — never a hardcoded three-entry list. For `option`, expand
  with the describe `options` baseCoin list (`BTC`/`ETH`/`SOL`/`XRP`/`MNT`/`DOGE`), matching
  CCXT-JS's per-baseCoin loop because the venue's bare-option response is BTC-scoped.
- *Compatibility cost:* two deliberate splits from CCXT-JS's defaults, both venue-grounded.
  (a) *Page size / completeness* — DIVERGE: CCXT-JS with `options.loadAllOptions: false` sends no
  `limit` and never walks the cursor, so its index truncates at the venue's 500-row default; ours
  asks for the venue maximum and **refuses** a still-paginated response rather than trusting
  `limit=1000` to stay "enough". (b) *Status filter* — DIVERGE: CCXT-JS drops non-`Trading` rows
  unless `loadAllOptions`/`loadExpiredOptions`; ours keeps them and marks them `active: false`, so
  a settling option is still resolvable by symbol instead of vanishing from the index. The
  `active` value itself CONFIRMs CCXT (`status === 'Trading'`) because Bybit's enum agrees —
  `Delivering` is not tradeable, so `false` (not `nil`, which would claim we don't know).
- *Implementation:* 251, 261.

**C14 — Bybit legacy (non-v5) private signing places `sign` by HTTP method. Outcome: CONFIRM Bourse.**

- *Exchange semantics (non-CCXT):* Bybit's V3 legacy auth (bybit-exchange.github.io/docs/v3/intro)
  merges `api_key`/`timestamp`/`recv_window` into the request parameters, sorts them, HMAC-SHA256s
  the canonicalized string, and sends `sign` alongside — in the **query for GET**, in the **body for
  POST**. Live testnet 2026-07-16 falsifies the query form for POST specifically: signing
  `POST asset/v3/private/transfer/inter-transfer` with the auth params in the query returns
  `10001 "Request parameter error: apiKey is missing"` — the venue does not read auth from the query
  on legacy POST. Moving the signed params + `sign` into the JSON body changes the answer to
  `10005 "Permission denied"`, i.e. the request now authenticates and is rejected on key scope
  (this testnet key holds only `Derivatives: [DerivativesTrade]`; `Wallet`/`Spot` are empty).
- *Our carve:* one canonical string for both verbs (sorted, `rawencode`d query incl. auth params),
  with placement selected per method via `signature_placement.by_method` — `query` for GET,
  `signed_params_body` for POST. Authored as spec data; the executor gained a generic
  `signed_params_body` location rather than a bybit special-case.
- *Compatibility cost:* none — same wire shape as CCXT-JS. CCXT's form-encoded POST branch
  (path contains `spot`) is authored but **unexercised**: no `spot/v3` POST private endpoint exists
  in the vendored catalog, so it is pinned by offline regression only, not live evidence.
- *Auth-param precedence:* CONFIRM CCXT — `api_key`/`timestamp`/`recv_window` are credential/clock
  derived auth fields, so recipe-declared query auth params override same-named caller params in both
  the signed canonical string and the sent request. This matches CCXT's `extend(params, auth)` with
  the auth object last and avoids signing arbitrary caller-supplied auth material. Live testnet
  evidence 2026-07-16: `GET user/v3/private/query-api` returns `retCode: 0` with sandbox credentials
  after the override change, **and** the same call with a bogus caller-supplied
  `api_key`/`timestamp`/`recv_window` also returns `retCode: 0` for the *real* key's record — the
  venue confirms the caller values never reach the wire. Under the old put-if-missing rule the bogus
  `api_key` would have been signed and rejected.
- *Scope of the override — do NOT generalize it to the whole executor.* This precedence applies only
  to recipe-declared `query_params` (today: bybit's `legacy_else` branch, the sole declaration in the
  catalog). The sibling `maybe_inject_query_timestamp` fallback stays **put-if-missing** on purpose:
  it serves the binance-family recipes (binance, binanceusdm, htx/huobi, …), and CCXT's binance
  `sign()` does `extend({'timestamp': nonce}, params)` — params **last** — so there a caller-supplied
  `timestamp` legitimately wins. CCXT's ordering is per-venue, not global; our executor mirrors that
  asymmetry deliberately. Pinned on both sides by `test/bourse/signing/hmac_recipe_test.exs`
  ("bybit legacy_else GET overrides caller auth params" vs "keeps query-placed POST signatures in the
  URL", which asserts a caller `timestamp` survives). "Unifying" the two helpers would break binance
  compatibility and turn the latter red.
- *Implementation:* 254, 266.

**C19 — Bybit `fetchOpenOrders` carries `nextPageCursor` from `/v5/order/realtime`.
Outcome: CONFIRM Bourse.**

- *Exchange semantics (non-CCXT):* Bybit demo trading host `https://api-demo.bybit.com`
  returned a non-empty `result.nextPageCursor` from `GET /v5/order/realtime` on 2026-07-16
  when two test-owned BTCUSDT linear limit orders were open and the request used `limit=1`.
  Observed cursor:
  `169e8ad0-e7e1-432a-8674-7a9fb0d77985%3A1784211281687%2C169e8ad0-e7e1-432a-8674-7a9fb0d77985%3A1784211281687`.
- *CCXT reference:* `fetchOpenOrders` calls `privateGetV5OrderRealtime`, then
  `addPaginationCursorToResult(response)`, then `parseOrders`.
- *Our carve:* `fetchOpenOrders` joins the Bybit order cursor merge list; the cursor is
  stamped onto the first raw order row, matching the existing `fetchClosedOrders` branch.
- *Implementation:* 263.

**C26 — Bybit `fetchLeverage` margin mode is account-scoped, not a position-row field. Outcome:
CONFIRM VENUE + CCXT COMPAT — nil by design on UTA rows; never fabricate `cross`.**

- *Exchange semantics (non-CCXT — Bybit v5 docs + live demo `api-demo.bybit.com`, 2026-07-17):*
  the `/v5/position/list` row carries **no** `marginMode` key. Its `tradeMode` field is
  documented "**Deprecated**, always `0`, check Get Account Info to know the margin mode"; the
  live UTA demo row confirms `tradeMode: 0` with `marginMode` absent. The venue's margin mode
  is an **account-level** setting: live `GET /v5/account/info` returns
  `marginMode: "REGULAR_MARGIN"` (enum `REGULAR_MARGIN` / `ISOLATED_MARGIN` /
  `PORTFOLIO_MARGIN`), already authored as the `margin_mode` slice (`fetch_margin_mode` →
  `cross` / `isolated` / `portfolio`).
- *CCXT's carve:* `bybit.ts parsePosition` sets `'marginMode': undefined // tradeMode was
  deprecated`, and `fetchLeverage` parses that unified position — so CCXT-JS also returns
  `marginMode: undefined` for bybit leverage. The prior authored map read a phantom
  `marginMode` row key (always nil by accident, not by decision).
- *Our carve + rationale:* map `margin_mode` from the row's own `tradeMode` with enum
  `1 → isolated` only. `0` maps to **nil**, deliberately: under UTA it is a deprecated
  constant, so translating it to `cross` would fabricate a value that contradicts an
  `ISOLATED_MARGIN`/`PORTFOLIO_MARGIN` account setting. A legacy row that genuinely says
  `tradeMode: 1` still surfaces `isolated` (the venue-defined meaning). Consumers who need the
  authoritative mode call `fetch_margin_mode` (account-scoped).
- *Implementation:* 285.
- *Evidence sources:* live demo position row + live `account/info` (tier-1); Bybit v5 docs as the
  non-CCXT semantic source; CCXT-JS `parsePosition` read as compatibility reference only.

**C34 — Bybit residual unified reds (task 306). Outcome: CONFIRM venue + ALIGNED-to-ccxt request shapes.**

- *Exchange semantics (non-CCXT, live testnet 2026-07-17):*
  - `GET /v5/market/risk-limit` requires `category` (linear/inverse); bare/symbol-only → retCode
    `10001 Illegal category`. With `category=linear&symbol=BTCUSDT` returns tier rows.
  - Order/execution private reads that omit `category` answer retCode `10005 "Permission denied"`
    on the same read-only key that succeeds with `category` (or `category`+`settleCoin` when no
    symbol). This is a request-shape defect, not credentials.
  - `GET /v5/asset/deposit/query-address` requires `coin`; missing → `131002 params error`.
  - `GET /v5/market/account-ratio` returns `{buyRatio, sellRatio, timestamp}`; long/short ratio is
    `buyRatio/sellRatio`.
  - Linear V5 positions have unit contract size 1 (instruments-info + CCXT market parse); inverse
    contract size remains market-derived minOrderQty (C7 still holds for inverse/deribit).
  - Batch amend answers HTTP 200 / retCode 0 with per-item failures in `retExtInfo.list` (e.g.
    code `110001`).
  - `GET /v5/asset/deposit/query-address` answers `{result: {coin, chains: [...]}}`; a chain row
    carries its own `chain`/`chainType` but no coin, so `coin` is stamped from the result envelope.
- *CCXT's carve:* getBybitType injects category; fetchOrderClassic uses order history; deposit
  maps `code → coin`; editOrders merges retExtInfo codes; linear contractSize = 1.
  `fetchDepositAddressesByNetwork` returns `indexBy(parsed, 'network')` — a network-keyed **dict**,
  not a list (`bybit.ts:5818`), and `indexBy` skips rows whose key is undefined.
  - `GET /v5/market/instruments-info` omits `PreLaunch` instruments from a default-status read:
    they are a **separate wave**, not extra rows on the first. Live testnet 2026-07-17, linear:
    default 724 + `status=PreLaunch` 22 = 746 (inverse 25, unaffected). ccxt-js 4.5.56 measured on
    the same testnet the same day returns linear 746 / inverse 25 — exact parity once the PreLaunch
    wave is issued. (The task's recorded "inverse 36" was stale; live is 25 on both sides.)
- *Our carve + rationale:* authored bybit_v5 request shapes + endpoint_selection for the residual
  methods; wire `liquidation`/`leverage_tiers` parse slots; stamp linear `contractSize: 1` at
  position annotate (category-scoped, not symbol-regex); merge retExtInfo onto edit_orders;
  fetchFutureMarkets fans out {linear, inverse} x {default, PreLaunch} with limit 1000 and follows
  nextPageCursor — mirroring ccxt-js's paired request (`bybit.ts:1975`) rather than a
  default-status-only read, which under-reports the linear surface by the PreLaunch count.
- *Compatibility cost:* none intentional; open-order reads without symbol now send
  `category=linear&settleCoin=USDT` (matches CCXT defaultSettle behaviour).
  `fetchDepositAddressesByNetwork` changes return shape list → network-keyed dict for **every**
  exchange, aligning with CCXT; a row carrying no network is dropped (no key to index under),
  matching CCXT's `indexBy`. Pinned by test rather than left silent — a venue that answers chains
  without a chain id would return `{}`, so the drop is a known contract, not a discovery.
- *Instruments cursor walk:* `fetchFutureMarkets`/`fetchMarkets` merge cursor pages into the first
  response. The merged envelope reports the **last** page's cursor, so a fully-walked surface reads
  complete and a truncated one (page budget exhausted, or a venue echoing the cursor it was sent —
  i.e. not advancing) retains a non-empty cursor and trips the C13 completeness guard. A stale
  page-1 cursor would misreport a complete walk as truncated.
- *Implementation:* 306.

**C-T347 — Bybit convert-trade quote binding. Outcome: CONFIRMED-against-Bybit docs (task 347).**

- *Exchange-flow confrontation:* [Bybit Confirm a Quote](https://bybit-exchange.github.io/docs/v5/asset/convert/confirm-quote)
  requires `quoteTxId`, the identifier returned when requesting a quote, as the only body field for
  `POST /v5/asset/exchange/convert-execute`.
- *Our carve + rationale:* bind unified `id` directly to `quoteTxId`; `from_code`, `to_code`, and
  `amount` belong to the prior quote request and must not replace the accepted quote identifier.
- *Compatibility cost:* none; this completes the existing C31 signature without changing it.

**B1 — Bybit closed-position `hedged` materialization. Outcome: compatibility carve.**

- *Scope:* closed-PnL history rows only (`closedSize` identifies the row shape); open-position
  `hedged` remains in the strict response comparison.
- *Our carve:* the response gate records the historical materialization difference at `hedged` for
  this row shape and removes only that path before its strict comparison. Both predicates are
  intentionally `any`: the contract documents an existing compatibility boundary rather than
  asserting a venue value that the recorded rows do not establish.
- *Implementation:* 230.

**B2 — Bybit `info.category` annotation. Outcome: DIVERGE — keep and register.**

- *Exchange semantics (non-CCXT):* Bybit v5 wraps list rows in `result: {category, list}`; the
  per-row payload does **not** repeat `category` (v5 docs: the category is an envelope field of
  the list response, `linear`/`spot`/`option`/`inverse`). Live confirmation 2026-07-17 (public
  `market/tickers`, `BTC/USDT:USDT`): the envelope carries `category: "linear"` while each list
  element omits it. Native ids like `BTCUSDT` are ambiguous across spot vs linear without it.
- *CCXT's carve:* static `parsedResponse.info` echoes the list row only — no envelope category.
- *Our carve + rationale:* `annotate_bybit_response_category/2` injects `result.category` onto
  each payload row before parse so `info.category` disambiguates native symbols and feeds
  `native_market_type/2`. Additive annotation is deliberately better than CCXT's fixture info;
  reverting it would re-break symbol resolution. Gate contract B2 applies only when ours has
  `info.category` and the CCXT golden does not: asserts a non-empty string, then removes the
  path. When both sides already carry category (e.g. some ledger fixtures), strict compare
  grades equality.
- *Compatibility cost:* consumers see an extra `info.category` key CCXT does not stamp.
- *Evidence sources:* the live Bybit v5 envelope shape (tier 1) plus Bybit's own v5 list-response docs —
  not CCXT's fixture, which has no category to compare against. The annotated value itself is
  therefore ungraded offline by construction; tier-1 owns whether the category is *correct*.

**B3 — Bybit `FundingRate.interval` offline goldens. Outcome: DIVERGE — CCXT's golden is
markets-cache contamination; tier-1 owns cadence.**

- *Exchange semantics (non-CCXT):* live testnet tickers carry `fundingIntervalHour: "8"` (Bybit v5
  market/tickers: "Funding interval hour… whole hours", per-symbol and variable). Instruments
  carry `fundingInterval` minutes (`480`). Our field map + `funding_interval` format emit `"8h"`
  when either key is in the payload (verified: stub with `fundingIntervalHour` → `interval: "8h"`).
- *CCXT static fixtures:* `fetchFundingRate` / `fetchFundingRates` httpResponses in
  `response/bybit.json` **omit** `fundingIntervalHour`; CCXT's `parsedResponse.interval: "8h"` is
  stamped from a pre-loaded markets cache, not from the recorded body. Our payload-scoped parse
  correctly returns `nil` for those fixtures — not a live gap.
- *Our carve + rationale:* a payload without the interval remains `nil`; the parser never
  invents one from an unrelated cache. `tier1_semantic_oracle_test` asserts `"8h"` against
  a recorded cassette that includes
  `fundingIntervalHour`. Live confrontation 2026-07-17 (public `bybit` mainnet ticker,
  `BTC/USDT:USDT`) returns `fundingIntervalHour: "8"` and our parse yields `interval: "8h"`.
- *Compatibility cost:* none on live payloads that carry the field; offline fixture goldens that
  invent interval from markets cache are not the oracle.


## C36 Bybit application

Canonical schema-level heading: **C36** in `docs/authored-spec-carves/global.md` (ticker `vwap`
is a price, never contract size). Bybit-specific evidence and CONFIRMED outcomes are mirrored
here so a session that only opens this register still sees the venue record. Verdicts are not
re-adjudicated (task 466).

- *Bybit outcome (CONFIRMED, task 315):* The [V5 Get Tickers
  documentation](https://bybit-exchange.github.io/docs/v5/market/tickers) makes
  `category` mandatory and defines the Linear/Inverse ticker's `turnover24h`
  and `volume24h` fields; Bybit's [turnover-versus-volume
  FAQ](https://bybit-exchange.github.io/docs/faq#what-is-the-difference-between-turnover-and-volume)
  defines turnover as the opposite currency to volume. Live public mainnet
  (`api.bybit.com`, 2026-07-17) confirms the units differ by category:

  | category | symbol | last | volume24h | turnover24h | blind `turnover/volume` | unified `vwap` |
  |---|---|---:|---:|---:|---:|---:|
  | linear | BTCUSDT | 63199.40 | 58938.7540 | 3778506601.2070 | **64109.03** | **64109.03** |
  | inverse | BTCUSD | 63135.30 | 223794756.0000 | 3493.1019 | **1.56085e-05** | **nil** |

  `volume24h` is the BTC quantity for linear BTCUSDT, so turnover/volume is a
  USDT price. For inverse BTCUSD it is USD contract quantity while turnover is
  BTC, producing an inverse-price scale rather than a price — C36 says nil.
  **Option is the same carve (CONFIRMED, task 329):** the ticker documentation
  defines `turnover24h` and `volume24h` for options, while Bybit's
  [turnover-versus-volume FAQ](https://bybit-exchange.github.io/docs/faq#what-is-the-difference-between-turnover-and-volume)
  establishes that turnover is denominated in the opposite currency to volume.
  Live public mainnet (`api.bybit.com`, 2026-07-17) recorded
  `BTC-17JUL26-64000-C-USDT` with `lastPrice=5`, `volume24h=294.69`, and
  `turnover24h=18825758.541`; the blind ratio is **63883.26**, approximately
  the BTC underlying price, not the option premium. Therefore `option`, like
  `inverse`, leaves `vwap` nil. The carve deliberately does not reconstruct
  another ratio: Bybit's field semantics do not establish it as a portable
  volume-weighted option-premium contract.
- *Bybit mechanism:* the raw V5 ticker row carries no category (unlike OKX's
  `instType`), but `category` rides the envelope at `result.category` and every
  Bybit read already annotates it onto its rows. So the same payload-gated
  `kind: "when"` shape OKX uses applies here, guarding on the annotated
  `category`. This is what makes the carve hold on `fetchTickers`, which sends
  no `symbol` and therefore has **no market context to discriminate on** — a
  request-context `market.inverse` rule alone leaves the plural path publishing
  `1.56e-05`. The nested `market.inverse` arm is kept as a second, independent
  signal for symbol-scoped reads. Both point at nil, so a missing signal can
  only cost a `vwap`, never publish a wrong one.
- *Bybit residual:* calling the generated `Bourse.Bybit.parse_ticker/1` directly on
  a raw inverse row still computes the ratio — that row carries neither category
  nor market context, so no signal exists to carve on. This is an information
  limit of the raw escape hatch, not the unified path; it is why the annotation
  (not the raw row) is the carve's anchor.
- *Bybit implementation:* 315, extended by 329. *Evidence sources:* Bybit V5 ticker field definitions +
  turnover/volume FAQ (non-CCXT, tier-1 semantic) and the live mainnet rows
  above; offline stubs pin linear VWAP and inverse/option nil on both the
  singular and plural read paths.

## Evidence status records

<!-- carve-evidence-status
{"carve_id":"C-T442b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Bybit Get Coin Info defines chainDeposit and chainWithdraw status values"},"observed_evidence":{"kind":"recorded_venue","reference":"Recorded Bybit fetchCurrencies response carries chainDeposit and chainWithdraw on each chain"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 parsedResponse leaves per-network active undefined"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T482c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Bybit Get Coin Info defines independent chainDeposit and chainWithdraw normal/suspended states"},"observed_evidence":{"kind":"recorded_venue","reference":"Recorded Bybit fetchCurrencies response carries chainDeposit and chainWithdraw on each chain"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 leaves per-network active undefined"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T442c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Bybit Get Position Info defines unrealisedPnl and positionIM"},"observed_evidence":{"kind":"recorded_venue","reference":"The three recorded position responses carry populated unrealisedPnl and positionIM operands"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 safePosition publishes the resulting percentage"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T442d","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Bybit Get System Status documents /v5/system/status and its event states"},"observed_evidence":{"kind":"live_venue","reference":"Public testnet /v5/system/status returned the documented completed-event list on 2026-07-22"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 fixture routes fetchStatus through announcements"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C9","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 error catalog defines 170134 as order price decimal too long; Place Order directs price precision to instrument tickSize"},"observed_evidence":{"kind":"live_venue","reference":"Bybit demo rejected the signed three-decimal LTCUSDT C9 request with 170134, then accepted and cancelled the signed two-decimal order on 2026-07-22"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT request fixture freezes the aligned two-decimal price 60.42"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"B1","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"Bybit closed-position fixture materialization difference at hedged"},"resolved_tier":2,"known_gap_reason":"The contract intentionally records a compatibility boundary with any/any predicates and asserts no venue value"}
-->

<!-- carve-evidence-status
{"carve_id":"B2","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 list-response documentation places category on the result envelope"},"observed_evidence":{"kind":"live_venue","reference":"Live BTCUSDT linear ticker envelope carried category while its row omitted category on 2026-07-17"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT parsed fixture info omits the envelope category"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"B3","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 ticker and instrument docs define fundingIntervalHour and fundingInterval"},"observed_evidence":{"kind":"recorded_venue","reference":"Live ticker returned fundingIntervalHour=8 and the tier1 cassette preserves that field"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT fixture invents interval from a markets cache absent from the raw response"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T378e","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T378e and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T360","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T360 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T360 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T360 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T343","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T343 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T343 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T343 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C10","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C10 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C10 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C10 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C11","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C11 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C11 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C12","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C12 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C12 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C12 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C13","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C13 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C13 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C13 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C14","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C14 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C14 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C14 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C19","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C19 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C19 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C26","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C26 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C26 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C26 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C34","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C34 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C34 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T347","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T347 and its register context"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

## 2026-08-08 — open-interest history request contract (Tasks 565 and 570)

**C-T565d — A provider-supported historical read with an incomplete request binding remains
callable and labelled raw (task 565, corrected by task 570). Outcome: CONFIRM provider support;
mapping incomplete.**

- *Provider contract:* V5 `GET /v5/market/open-interest` requires `category`, `symbol`, and
  `intervalTime`.
- *Live evidence:* testnet accepted native `BTCUSDT` with `category=linear` and
  `intervalTime=5min`; the unified method emitted an invalid-symbol request because its authored
  binding does not resolve that complete native request.
- *Our carve:* `fetchDerivativesOpenInterestHistory` records provider support `true`, mapping
  completeness `false`, and verification `unverified`. The route remains in the generated surface
  and returns `%Bourse.RawResponse{}`. Its public accepted-request branch is explicitly excluded
  until task 550 authors the complete binding; it cannot masquerade as a normalized history.

<!-- carve-evidence-status
{"carve_id":"C-T565d","date":"2026-08-19","semantic_source":{"kind":"provider_owned","reference":"priv/authority/bybit V5 Market Open Interest request contract"},"observed_evidence":{"kind":"live_venue","reference":"api-testnet.bybit.com accepted the native BTCUSDT/category/intervalTime request while the incomplete unified binding returned 10001"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The provider operation is proven; the Bourse request binding and normalized mapping are incomplete"}
-->

## 2026-08-09 — option-market endpoint reachability (Task 534)

**C-T534c — Option-market discovery uses the V5 instruments contract (task 534). Outcome:
CONFIRM provider contract.**

- *Provider boundary:* Bybit V5 exposes option instruments through
  `GET /v5/market/instruments-info` with the option category.
- *Our carve:* `fetchOptionMarkets` has an explicit instruments-info default, so endpoint-section
  priority cannot make the method unreachable.
- *Recorded evidence:* the manifest-registered `fetch_markets` recording pins the same production
  endpoint and its provider response envelope; focused selector tests pin the option method's
  reachability.

<!-- carve-evidence-status
{"carve_id":"C-T534c","date":"2026-08-09","semantic_source":{"kind":"provider_owned","reference":"priv/authority/bybit/manifest.json artifact v5-docs-source; V5 Get Instruments Info option contract"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/bybit/fetch_markets.json captured from v5/market/instruments-info"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-10 — USDC-settled perpetual native ids (Task 571)

**C-T571a — Linear-category native ids with the bare `PERP` suffix are USDC-settled
perpetuals and normalize to `COIN/USDC:USDC` (task 571). Outcome: CONFIRM venue.**

- *Provider contract:* Bybit V5 lists USDC-settled perpetuals under the linear
  category with `settleCoin` USDC; their instrument ids carry the bare `PERP`
  suffix (`TAOPERP`), unlike USDT perps (`TAOUSDT`).
- *Our carve:* the native-symbol backfill resolves `<COIN>PERP` under
  `{bybit, :swap}` to `Symbol.build(coin, "USDC", "USDC")`. This retires the
  historic `"ETCPERP/:"` malformation a consumer recorded on 2026-06-30
  (BUGS.md) — the venue emitting the bare-`PERP` form was observed reality
  before it was carved.
- *Live evidence:* `fetch_tickers(bybit, params: %{"category" => "linear"})` on
  2026-08-10 returned 68 bare-`PERP` rows, each keyed by its unified form
  (`TAOPERP` → `TAO/USDC:USDC`, `DOGEPERP` → `DOGE/USDC:USDC`).

<!-- carve-evidence-status
{"carve_id":"C-T571a","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 Get Instruments Info linear contract (settleCoin USDC, bare PERP suffix)"},"observed_evidence":{"kind":"live_venue","reference":"api.bybit.com v5/market/tickers category=linear 2026-08-10: 68 bare-PERP rows normalize to COIN/USDC:USDC; consumer-observed native form BUGS.md 2026-06-30 (ETCPERP)"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-12 — rate-unit confrontation (Task 594)

**C-T594e — Bybit's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM provider arithmetic where available; retain one position-history gap.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.adl_rank.field_map.percentage` | absent; no emitted percentile or unit | The authored slot is null; Bybit's ADL endpoint reports ranking fields, not a percentage value. [ADL alert](https://bybit-exchange.github.io/docs/v5/market/adl-alert) |
| `normalization.field_maps.borrow_interest.field_map.interestRate` | absent; no emitted rate or unit | The authored accrued-interest slot is null. [Borrow history](https://bybit-exchange.github.io/docs/v5/account/borrow-history) |
| `normalization.field_maps.borrow_rate.field_map.rate` | fraction | Bybit's own example satisfies `borrowAmount × hourlyBorrowRate = borrowCost` (`1.063332657 × 0.000001216904 ≈ 0.00000129`), so the raw hourly rate is a fraction. [Borrow history](https://bybit-exchange.github.io/docs/v5/account/borrow-history) |
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for payment/current/history rates; absent for null interest, next-rate, and previous-rate slots | Bybit defines `funding fee = position value × funding rate`; its worked `0.01%` example is applied as `0.0001`. Transaction-log `feeRate`, ticker `fundingRate`, and funding-history `fundingRate` therefore pass through as fractions. [Funding-fee calculation](https://www.bybit.com/en/help-center/article/Funding-fee-calculation) [Transaction log](https://bybit-exchange.github.io/docs/v5/account/transaction-log) |
| `normalization.field_maps.leverage_tiers.field_map.maintenanceMarginRate` | fraction | Bybit's risk-limit contract publishes `maintenanceMargin` as a decimal maintenance-margin rate; example values such as `0.005` represent 0.5%. [Risk limit](https://bybit-exchange.github.io/docs/v5/market/risk-limit) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker` | fraction | The instrument contract identifies maker/taker fee-rate fields, which multiply trade value; the authored values remain decimal fractions. [Instrument information](https://bybit-exchange.github.io/docs/v5/market/instrument) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The market fee-mode flag is null; maker/taker fields carry the rates independently. [Instrument information](https://bybit-exchange.github.io/docs/v5/market/instrument) |
| `normalization.field_maps.option.field_map.percentage` | absent; no emitted percentage or unit | The authored option percentage slot is null. [Option tickers](https://bybit-exchange.github.io/docs/v5/market/tickers) |
| `normalization.field_maps.position.branches[0].field_map.initialMarginPercentage` | unverified dimensionless ratio | The closed-position mapping computes `cumEntryValue / cumExitValue`, but Bybit describes both fields as cumulative traded values and does not identify their ratio as initial-margin percentage. Its unit/meaning remains unverified; no scale is asserted. [Closed PnL](https://bybit-exchange.github.io/docs/v5/position/close-pnl) |
| `normalization.field_maps.position.branches[0].field_map.maintenanceMarginPercentage`, `normalization.field_maps.position.branches[0].field_map.percentage` | absent; no emitted percentage or unit | Both closed-position slots are null. [Closed PnL](https://bybit-exchange.github.io/docs/v5/position/close-pnl) |
| `normalization.field_maps.position.branches[1].field_map.initialMarginPercentage`, `normalization.field_maps.position.branches[1].field_map.maintenanceMarginPercentage` | fraction | The authored values divide provider position initial/maintenance margin by provider position value; `0.1` represents 10%. [Position information](https://bybit-exchange.github.io/docs/v5/position) |
| `normalization.field_maps.position.branches[1].field_map.percentage` | percent points | The authored PnL arithmetic divides `unrealisedPnl` by `positionIM` and emits ×100 percent points; an omitted/zero PnL remains null by the existing carve. [Position information](https://bybit-exchange.github.io/docs/v5/position) |
| `normalization.field_maps.ticker.field_map.percentage` | percent points | The provider example `price24hPcnt = -0.158315` is a fractional change; the authored ×100 conversion emits `-15.8315` percent points. [Ticker stream](https://bybit-exchange.github.io/docs/v5/websocket/public/ticker) |
| `normalization.field_maps.trading_fee.field_map.maker`, `normalization.field_maps.trading_fee.field_map.taker`, `normalization.field_maps.trading_fees.field_map.maker`, `normalization.field_maps.trading_fees.field_map.taker` | fraction | Bybit's fee-rate operation returns decimal maker/taker rates used multiplicatively against order value; the authored mappings pass them through. [Fee rate](https://bybit-exchange.github.io/docs/v5/account/fee-rate) |
| `normalization.field_maps.trading_fee.field_map.percentage`, `normalization.field_maps.trading_fees.field_map.percentage` | absent boolean; no numeric unit | Both fee-mode flags are null; maker/taker fields carry decimal fractions. [Fee rate](https://bybit-exchange.github.io/docs/v5/account/fee-rate) |
| `fees.trading.maker`, `fees.trading.taker` | fraction | Static defaults are decimal fractions; the authenticated fee-rate operation is authoritative for an account/product. [Fee rate](https://bybit-exchange.github.io/docs/v5/account/fee-rate) |

<!-- carve-evidence-status
{"carve_id":"C-T594e","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Bybit funding-fee, borrow-history, ticker, position, instrument, and fee-rate contracts linked in C-T594e"},"observed_evidence":{"kind":"recorded_venue","reference":"Registered Bybit ticker/funding response plus provider example cross-field arithmetic"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The closed-position cumEntryValue/cumExitValue ratio is not identified by Bybit as an initial-margin percentage"}
-->

## 2026-08-12 — ledger type authority (Task 598)

**C-T598b — ledger types follow the pinned UTA and contract transaction-log enums (task 598).
Outcome: CONFIRM provider vocabulary; DIVERGE because venue-native literals occupy the unified
`type` field when no deliberate alias exists (amended by Task 601).**

- *Provider contract:* the pinned Bybit V5 enum source contains 100 UTA rows and 15 contract
  rows, yielding 101 unique type literals. The eight legacy mixed-case names inherited from the
  frozen compatibility reference do not occur in either provider enum and are removed.
- *Our carve:* only deliberate aliases remain in `enum_map`; all other documented literals flow
  through `enum_passthrough: true`. The provider set is therefore a superset guard, not identity
  padding. This deliberately diverges from a closed unified vocabulary while keeping raw types
  observable.
- *Direction:* `change = cashFlow + funding - fee` is signed. Positive is `in`, negative is
  `out`, and zero has no flow direction, so it maps to `nil`.

<!-- carve-evidence-status
{"carve_id":"C-T598b","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Bybit docs commit 5ccd3010 docs/v5/enum.mdx type(uta-translog) and type(contract-translog), plus transaction-log change arithmetic"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Venue-native literals deliberately pass through the unified type field; no live account can summon every ledger type"}
-->

**C-T600e — Bybit rate fields conform to the cross-venue unit contract (task 600).
Outcome: CONFIRM option IV and funding fractions.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | Bybit applies the decimal funding rate directly to position value. [Funding fee](https://www.bybit.com/en/help-center/article/Funding-fee-calculation) |
| `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | These authored slots are null. [Funding fee](https://www.bybit.com/en/help-center/article/Funding-fee-calculation) |
| `normalization.field_maps.greeks.field_map.askImpliedVolatility`, `normalization.field_maps.greeks.field_map.bidImpliedVolatility`, `normalization.field_maps.greeks.field_map.markImpliedVolatility`, `normalization.field_maps.option.field_map.impliedVolatility` | fraction | The provider ticker contract publishes option IVs as decimal values; its example `markIv: "0.7567"` means 75.67%, and the mappings pass through. [Option tickers](https://bybit-exchange.github.io/docs/v5/market/tickers) |
| `normalization.field_maps.position.branches[0].field_map.initialMarginPercentage` | unverified fraction | `cumEntryValue / cumExitValue` is dimensionless and unscaled, so it cannot introduce a second unit; C-T594e's semantic objection to calling that ratio initial margin remains open. [Closed PnL](https://bybit-exchange.github.io/docs/v5/position/close-pnl) |

- *Live evidence (2026-08-12T08:57:35Z):* testnet `/v5/market/tickers` returned
  `BTC-21AUG26-65000-C-USDT` with `markIv "0.2789"`, `bid1Iv "0.3223"`, and
  `ask1Iv "0.3236"`; the unified fraction is the same numeric value.
- The unwired `income` field map is null; its extras-carried `rate` can no longer publish a
  dead slice outside the invariant.

<!-- carve-evidence-status
{"carve_id":"C-T600e","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 option ticker, funding-fee, and closed-PnL contracts linked in C-T600e"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-12T08:57:35Z api-testnet.bybit.com option ticker BTC-21AUG26-65000-C-USDT markIv 0.2789 bid1Iv 0.3223 ask1Iv 0.3236"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The closed-position cumEntryValue/cumExitValue ratio remains semantically unverified as initial margin"}
-->

**C-T603e — Bybit's ticker percentage declares its source unit (task 603).
Outcome: CONFIRM fraction-to-percent-point conversion.**

<!-- rate-unit path="normalization.field_maps.ticker.field_map.percentage" unit="percent_points" source-unit="fraction" --> Bybit's `price24hPcnt` is a decimal ratio; authored `scale: 100` emits percent points. [Tickers](https://bybit-exchange.github.io/docs/v5/market/tickers)

<!-- carve-evidence-status
{"carve_id":"C-T603e","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 ticker contract linked in C-T603e"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/bybit/fetch_ticker.json","fixture":"test/fixtures/responses/bybit/fetch_ticker.json"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The registered ticker establishes the wire value but the amendment remains documentation-derived for every market family"}
-->

## 2026-08-19 — unified account facts (Task 648)

**C-T648c — Bybit UTA status and margin mode remain distinct account facts (task 648). Outcome: CONFIRM venue.**

V5 `GET /v5/account/info` owns `unifiedMarginStatus` and `marginMode`. The
account-facts read preserves them as product access and account margin without
manufacturing a position margin mode. Its `info` is the full V5 response envelope.

<!-- carve-evidence-status
{"carve_id":"C-T648c","date":"2026-08-19","semantic_source":{"kind":"provider_owned","reference":"https://bybit-exchange.github.io/docs/v5/account/account-info"},"observed_evidence":{"kind":"live_venue","reference":"test/bourse/account_facts_integration_test.exs Bybit demo /v5/account/info unifiedMarginStatus/marginMode pin 2026-08-19"},"compatibility_reference":null,"resolved_tier":1}
-->
