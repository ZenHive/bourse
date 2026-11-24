# Deribit carve register

Provider authority: [`priv/venues/deribit/authority/manifest.json`](../../priv/venues/deribit/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.

## 2026-11-25 — funding interval, ticker volumes, liquidation filter (Task 710)

**C-T710a — `fetchFundingRate` interval is the requested accrual window.
Outcome: DIVERGE from C-T535a's history-spacing `"1h"`.**

- *Exchange semantics:* `public/get_funding_rate_value` "retrieves the funding
  rate (interest rate) value for a perpetual instrument over a specified time
  period" bounded by the required `start_timestamp`/`end_timestamp`; the history
  endpoint names its per-row fields "1hour interest rate" (`interest_1h`) and
  "8hour interest rate" (`interest_8h`).
  [get_funding_rate_value](https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_value)
  [get_funding_rate_history](https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_history)
- *Why C-T535a was wrong:* hourly *history* spacing is the history sampling
  interval — how often `get_funding_rate_history` publishes a row — not a payment
  cadence: Deribit calculates and pays funding continuously into the realised
  session PnL and moves it to cash at the daily settlement, 08:00 UTC
  ([Funding Specifications](https://support.deribit.com/hc/en-us/articles/31424939178397-Funding-Specifications)).
  The sampling interval was applied to a different read, whose value is whatever
  the request window accrued. That window is 8h by default, so the value was an 8h
  rate labelled `"1h"`.
- *Our carve:* the label never changes which bounds go on the wire. The request
  shaper sends what it always sent — a caller bound as given (integer or
  string), otherwise `end_timestamp` = request clock and `start_timestamp` =
  request clock − 8h. `Bourse.Unified.call_dispatch/6` pins that clock once, and
  `Bourse.Unified.FundingInterval` re-derives the same dispatched shape and
  labels the value with the span between its two bounds, in the largest unit
  that divides it exactly (`"8h"`, `"7h"`, `"14399877ms"`). A bound counts only
  when it is an integer or a string that is entirely an integer; a malformed one
  is sent unchanged and Deribit answers `-32602` `"integer required"`. The
  authored default `"8h"` documents the default window.
- *Review rounds (2026-11-25):* the first cut read only integer bounds from the
  unified params, so string bounds `[T-4h, T]` were sent but labelled `"8h"` and
  a start-only window or a 4h−123ms span got nil. A second cut rewrote the
  bounds before dispatch, which made `"oops"` silently default and moved an
  end-only request's start from clock − 8h to end − 8h; it was replaced by the
  label-only derivation above. Live at `T = 1795561200000`
  (`timestamp_ms_override: T`): string bounds, start-only and integer bounds on
  `[T-4h, T]` answer `{0.0, "4h"}`; end-only `T-1h` answers the
  `[T-8h, T-1h]` value with `"7h"`; the 4h−123ms span answers
  `"14399877ms"`; `"oops"` and `"<digits>oops"` answer `-32602` `"integer
  required"` for the named param.
- *History sampling interval:* pinned separately in
  `test/live/deribit/deribit_authored_integration_test.exs` — unified
  `fetch_funding_rate_history` rows carry exactly the raw history timestamps,
  spaced one hour apart, with `funding_rate` equal to each row's `interest_1h`.
- *Live evidence (2026-11-25, test.deribit.com, BTC-PERPETUAL):* with
  hour-aligned end `T = 1795561200000`, the `[T-8h, T]` value was
  `8.666511141627127e-08`, the history row at `T` had `interest_8h
  8.666511141627128e-08`, the sum of the eight `interest_1h` rows was
  `8.6657e-08`, and the `[T-1h, T]` value was `0.0`. Window values at an
  unaligned end: 1h/2h/4h `0.0`, 8h `-4.0168e-08`, 16h `-8.27e-06`. Before the fix
  unified returned `-4.0167563995206885e-8` with `interval: "1h"`, and after it
  the same value with `"8h"`. Error: a dated future answers `-32602`, reason
  `"instrument is not perpetual"`.
  Pinned in `test/live/deribit/deribit_value_semantics_test.exs`. The test reads
  provider window values at several spans and asserts that the unified value
  matches exactly one, and that the interval names that span.

**C-T710b — ticker `baseVolume` ← `stats.volume`, `quoteVolume` ←
`volume_notional`, with `volume_usd` only where no notional is published.
Outcome: DIVERGE from `quoteVolume ← stats.volume`. The task premise held in
part: `volume_usd` is not the quote figure on every kind.**

- *Exchange semantics:* ticker `stats.volume` is "Volume during last 24h in base
  currency"; `stats.volume_notional` is "24-hour volume in quote currency;
  omitted when base and quote currencies are equal or for Coinbase-routed spot";
  `stats.volume_usd` is "Volume in usd (futures only)". Book summary has the same
  fields: `volume` "(in base currency)", `volume_notional` "Volume in quote
  currency (futures and spots only)", and `volume_usd` "Volume in USD".
  [ticker](https://docs.deribit.com/api-reference/market-data/public-ticker)
  [get_book_summary_by_currency](https://docs.deribit.com/api-reference/market-data/public-get_book_summary_by_currency)
- *Per kind, live 2026-11-25 (test.deribit.com):*

  | Kind | Instrument | `volume` | `volume_notional` | `volume_usd` | Unified quote |
  |---|---|---|---|---|---|
  | inverse perpetual | BTC-PERPETUAL | 99875.29 (BTC) | 6.0098e9 | 6.0098e9 | USD → notional |
  | linear perpetual | BTC_USDC-PERPETUAL | 839.80 (BTC) | 50547243.09 (USDC) | 50538761.5 (USD) | USDC → notional, not USD |
  | Coinbase-routed spot | BTC_USDC | 196259.23 (BTC) | absent | absent | USDC → nil, no figure published |
  | native spot | BTC_USDT | 7.5713 (BTC) | 514458.4 (USDT) | 513891.63 | USDT → notional |
  | inverse option | BTC-24SEP27-45000-P | 8979.0 (BTC) | absent (provider quote = base, BTC) | 254152171.59 | USD (`counter_currency`) → `volume_usd` |
  | linear option | BTC_USDC-25DEC26-20000-P | 2600.03 | 78024.85 (USDC) | 78016.11 | USDC → notional |

  For every kind, `volume` × the instrument price lands on the notional
  (99875 BTC × ~60.2k ≈ 6.0e9), so `volume` is the base figure. The linear-USDC
  rows show why `volume_usd` cannot be the unified quote: there it is USD, not
  the USDC quote.
- *Our carve:* `baseVolume` = `stats.volume` (falling back to the book-summary
  `volume`); `quoteVolume` = `stats.volume_notional`, then `volume_notional`,
  then `stats.volume_usd` / `volume_usd`. The `volume_usd` fallback is reached
  only where no notional is published, which is the inverse option, whose
  unified quote is USD. Natively matched spot publishes full `stats`, so its
  quote is the notional; Coinbase-routed spot (`is_cbe_routed: true` on
  `get_instruments`) omits both quote figures, so `quoteVolume` stays nil and is
  not computed from price. Routing is provider configuration that can change
  ([spot trading venues](https://docs.deribit.com/articles/spot-trading-venues)),
  so the test reads the flag rather than assuming it.
- *Open edge:* if a linear-USDC future ever omitted `volume_notional`, the
  fallback would report its USD figure. No live row omits it.
- Pinned in `test/live/deribit/deribit_value_semantics_test.exs`. For each of
  the six kinds (native and routed spot separately) the test compares both volumes with the same response's
  `stats`, and with an independent `public/ticker` call within 1%. It also
  checks the denomination (`quote/base` ≈ index for perpetuals and native spot,
  premium below underlying for options), so swapped volumes fail.

**C-T710c — `fetchLiquidations` keeps only tape rows with a `liquidation`
marker. Outcome: DIVERGE from returning every public trade.**

- *Exchange semantics:* `public/get_last_trades_by_instrument` trade rows carry
  `liquidation`, documented as "Optional field (only for trades caused by liquidation)":
  `"M"`, `"T"` or `"MT"` for which side was under liquidation.
  [get_last_trades_by_instrument](https://docs.deribit.com/api-reference/market-data/public-get_last_trades_by_instrument)
- *Our carve:* `response_envelopes.liquidation.fetchLiquidations.row_filter =
  {"key": "liquidation", "present": true}`, applied by
  `Bourse.Unified.Envelope.filter_rows/4` before parsing. `fetchMyLiquidations`
  (settlement history) has no filter.
- *Live evidence (2026-11-25):* none of the 1000 newest trades on test.deribit.com
  BTC-PERPETUAL, ETH-PERPETUAL, BTC/ETH/SOL/XRP_USDC-PERPETUAL carried
  `liquidation`; the same held for 1000-trade windows ending 0–30 days back.
  Production public BTC/ETH-PERPETUAL windows 0–7 days back were also unmarked.
  Before the fix `fetch_liquidations("BTC/USDC:USDC")` returned 10 rows; after it,
  `[]`. Error: unknown instrument `BTC-31DEC99` (`BTC/USD:BTC-991231`) answers `-32602` `"instrument not
  found"`. The positive branch (a marked row surviving the filter) has not been
  observed live; see `docs/prod-verification-ledger.md`. The REST-read case now
  declares `empty_collection: allowed`, and `fetchLiquidations` is authored
  `verification: "unverified"` until a marked trade survives parsing live.

<!-- carve-evidence-status
{"carve_id":"C-T710a","date":"2026-11-25","semantic_source":{"kind":"provider_owned","reference":"Deribit public/get_funding_rate_value window semantics and get_funding_rate_history interest_1h/interest_8h"},"observed_evidence":{"kind":"live_venue","reference":"2026-11-25 test.deribit.com BTC-PERPETUAL [T-8h,T] value 8.666511141627127e-08 == history interest_8h at T; window values distinct per span; -32602 instrument is not perpetual on a dated future"},"compatibility_reference":null,"resolved_tier":1}
-->
<!-- carve-evidence-status
{"carve_id":"C-T710b","date":"2026-11-25","semantic_source":{"kind":"provider_owned","reference":"Deribit public/ticker stats.volume / volume_notional / volume_usd and get_book_summary_by_currency volume fields"},"observed_evidence":{"kind":"live_venue","reference":"2026-11-25 test.deribit.com inverse perp, linear perp, native spot BTC_USDT, Coinbase-routed spot BTC_USDC, inverse option, linear option stats table in C-T710b"},"compatibility_reference":null,"resolved_tier":1}
-->
<!-- carve-evidence-status
{"carve_id":"C-T710c","date":"2026-11-25","semantic_source":{"kind":"provider_owned","reference":"Deribit public/get_last_trades_by_instrument optional liquidation field"},"observed_evidence":{"kind":"live_venue","reference":"2026-11-25 test.deribit.com unmarked tapes filter to []; marked-row branch not observed live"},"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"no liquidation-marked trade found on testnet or production public tapes; the positive branch is ledgered"}
-->

## 2026-09-15 — order trigger_price and reduce_only round-trip (Task 700)

**C-T700 — Deribit order objects publish `trigger_price` and `reduce_only`.
Outcome: CONFIRM the provider fields on the order read map.**

- *Exchange semantics:* `private/get_order_state` (and the open-order list)
  return an order object with `trigger_price` (future trigger orders) and
  `reduce_only` (omitted on spot). There is no distinct stop-loss / take-profit
  price: those legs are `order_type` (`stop_market` / `take_market`) plus
  `trigger_price`.
  [private/get_order_state](https://docs.deribit.com/api-reference/upcoming/trading/private-get_order_state.md)
- *Live evidence (2026-09-15, test.deribit.com):* `stop_market` sell
  `SLTS-11018249` at trigger 65525.0, `order_state` `untriggered`,
  `info["trigger_price"] == 65525.0`, `info["reduce_only"] == false`. Before
  the mapping, unified `trigger_price` and `reduce_only` were nil on create,
  `fetch_open_orders`, and `fetch_order`. Cancelled; open book empty. Buy-stop
  at trigger 1 answered `10035 trigger_price_too_low`.

<!-- carve-evidence-status
{"carve_id":"C-T700","date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"Deribit order object trigger_price and reduce_only on private/get_order_state"},"observed_evidence":{"kind":"live_venue","reference":"2026-09-15 test.deribit.com SLTS-11018249 untriggered stop_market sell trigger_price 65525.0 reduce_only false; 10035 trigger_price_too_low on buy-stop at 1"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-09-15 — transfer currency (landed-base gate, no task)

**Deribit `private/get_transfers` rows carry their own `currency`; the authored
transfer slot had it null. Outcome: CONFIRM the provider field, DIVERGE from the
previous "deribit publishes no transfer currency" reading.**

- *Exchange semantics:* a transfer object is documented with a `currency` field
  alongside `amount`, `direction`, `state` and `other_side`.
  [private/get_transfers](https://docs.deribit.com/api-reference/account-management/private-get_transfers)
- *Live evidence (2026-09-15):* `GET /api/v2/private/get_transfers?currency=BTC&count=5`
  on `test.deribit.com` returned one row —
  `{"id": 493346, "type": "subaccount", "state": "confirmed", "currency": "BTC",
  "amount": 5.0, "direction": "payment", "other_side": "efries_1"}`. The authored
  `transfer.field_map.currency` was `null`, so `Bourse.TransferEntry.currency`
  came back nil and `deribit:fetchTransfers:0:privateGetGetTransfers` failed its
  `required_fields` check with *"required semantic field currency is nil"*.
- *Why it was invisible until now:* the case declares `empty_collection: allowed`
  and the testnet account held no transfer at all, so an empty list passed the
  lane for as long as the slot stayed unexercised. The defect is as old as the
  slice; the first live row is what made it observable.
- `fromAccount` / `toAccount` stay null on purpose: deribit publishes `other_side`
  plus a `direction` (`payment` = outgoing, `income` = incoming), so naming the two
  sides needs a direction-dependent rule rather than a flat key map, and the
  contract case requires neither.

<!-- carve-evidence-status
{"carve_id":null,"date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_transfers transfer object"},"observed_evidence":{"kind":"live_call","reference":"test.deribit.com private/get_transfers currency=BTC 2026-09-15, one confirmed subaccount row carrying currency BTC"},"compatibility_reference":null,"resolved_tier":"verified","note":"authored inline from the landed-base mix ci gate, no task; see BUGS.md 2026-09-15 entry for the gate triage"}
-->

## 2026-09-15 — order identity, fill fees, closed-order 11044 (Task 695)

**C-T695 — Deribit `instrument_name` is order/trade identity, user-trade `fee`/`fee_currency`
are the fill fee, and `11044 not_open_order` is OrderNotFound for open-order ops.
Outcome: CONFIRM provider contract; DIVERGE from treating native ids as unified symbols
and from classifying a closed-order cancel as InvalidOrder.**

- *Exchange semantics:* Order and user-trade objects carry `instrument_name`
  ([private/buy](https://docs.deribit.com/api-reference/trading/private-buy),
  [private/get_user_trades_by_instrument](https://docs.deribit.com/api-reference/trading/private-get_user_trades_by_instrument)).
  That id is not the unified symbol; loaded markets map `market.id` onto
  `market.symbol` (`BTC-PERPETUAL` → `BTC/USD:BTC`). User trades publish `fee`
  in units of `fee_currency`, including signed rebates. [Errors](https://docs.deribit.com/articles/errors)
  define `11044` as `"not_open_order"` — “Attempt to do open order operations
  with the not open order.” Observed live on both `private/cancel` and
  `private/edit`. The code does not say filled versus canceled; `order_state`
  does (`cancelled` → `canceled`, `filled` → `closed`).
- *Our carve:* `field_maps.order`/`trade` `.symbol` read `instrument_name` as
  the native id. Unified reads remap through loaded markets. Trade `fee`/`fees`
  copy `fee`/`fee_currency` into the map Fee contract (signed, no abs, no
  invented order-level aggregate), both `omit_if_empty` because the same trade
  field map also serves public `public/get_last_trades_by_instrument` rows,
  which carry no fee: there the absent fee stays the unavailable default
  (`fee` null-cost/null-currency, `fees` empty) instead of an empty fee object.
  `raw.exceptions.11044` is `OrderNotFound`
  for every open-order operation that returns it.
- *Live evidence (2026-09-15, test.deribit.com):* resting BTC-PERPETUAL GTC
  create/fetch/cancel kept unified `BTC/USD:BTC`; direct `parse_order` of the
  payload kept native `BTC-PERPETUAL`. `fetch_my_trades` fill `267466153` had
  `info.fee 7.1e-7` / `fee_currency BTC`. Cancel-then-cancel and edit of that
  closed order both answered `11044`; `fetch_order` of a filled id stayed
  `closed`. A public BTC-PERPETUAL trade row carried no `fee` key and parsed to
  the unavailable default. Malformed `BTC-0` stayed JSON-RPC `-32602`. WS `private/cancel`
  of the closed id returned the same JSON-RPC error, classified through
  `Bourse.HTTP.Errors.classify_response/5`. Pinned in
  `test/live/deribit/deribit_order_lifecycle_integration_test.exs`.

<!-- carve-evidence-status
{"carve_id":"C-T695","date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"Deribit instrument_name on orders/trades; user-trade fee/fee_currency; errors 11044 not_open_order"},"observed_evidence":{"kind":"live_venue","reference":"2026-09-15 test.deribit.com: parse_order native BTC-PERPETUAL, unified BTC/USD:BTC; fill 267466153 fee 7.1e-7 BTC; cancel+edit 11044; fetch filled order closed; WS private/cancel same code"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-29 — option-row implied volatility (Task 686)

**C-T686f — Deribit's option book summary carries `mark_iv`, so the unified
option row emits it as a fraction (task 686). Outcome: DIVERGE from C-T600f's
`absent` claim for this slot.**

<!-- rate-unit path="normalization.field_maps.option.field_map.impliedVolatility" unit="fraction" source-unit="percent_points" --> `public/get_book_summary_by_currency` publishes `mark_iv` in the same percent-point convention as the ticker IVs carved in C-T600f (`100` means 100%), so the authored `scale: 0.01` emits a fraction — matching the sibling `greeks` IV slots and bybit's already-fractional `markIv`. [Book summary](https://docs.deribit.com/api-reference/market-data/public-get_book_summary_by_currency) [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker)

- *Live evidence (2026-08-29, www.deribit.com public):* the inverse BTC book
  returned 1030 legs, every one carrying `mark_iv` and a numeric
  `implied_volatility` — `BTC/USD:BTC-260925-81000-P` read `mark_iv 36.3` and
  emitted `0.363`. The USDC-settled linear book returned 3308 legs of which 606
  are SOL; `SOL/USDC:USDC-261225-115-P` read `mark_iv 61.58` and emitted
  `0.6158`.

<!-- carve-evidence-status
{"carve_id":"C-T686f","date":"2026-08-29","semantic_source":{"kind":"provider_owned","reference":"Deribit public/get_book_summary_by_currency mark_iv and public/ticker percent-point IV convention linked in C-T686f"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-29 www.deribit.com public/get_book_summary_by_currency: BTC 1030/1030 legs with mark_iv (BTC/USD:BTC-260925-81000-P 36.3 -> 0.363); USDC 606 SOL legs (SOL/USDC:USDC-261225-115-P 61.58 -> 0.6158); pinned in test/live/read_parse_slots_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-28 — option premium notional shared rule (Task 666)

**C-T666c — Deribit's Task 664 premium derivation satisfies the shared option
`notional` rule. Outcome: CONFIRM C-T664; do not re-derive.**

The unified option `notional` is mark-to-market premium value in
`notional_currency`. Deribit still computes
`abs(contracts) * contract_size * abs(mark_price)` in the option's settlement
currency when loaded markets supply `contract_size`, and leaves `notional` nil
without that input. That is the same cash-value rule OKX (`optVal`) and Bybit
(`positionValue`) now satisfy. Future rows are unchanged.

<!-- carve-evidence-status
{"carve_id":"C-T666c","date":"2026-08-28","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_positions option size/mark_price and public/get_contract_size base-coin unit for options"},"observed_evidence":{"kind":"live_venue","reference":"Task 664 live pin in test/live/deribit/deribit_authored_integration_test.exs (dangerous): option premium notional with loaded markets, nil without"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-22 — option premium notional (Task 664)

**C-T664 — Deribit option `notional` is the settlement-currency premium
`abs(contracts) × contract_size × abs(mark_price)`, never a guessed contract
size (task 664). Outcome: DIVERGE from mapping option `size` onto quote
notional.**

- *Exchange semantics:* [`private/get_positions`](https://docs.deribit.com/api-reference/account-management/private-get_positions)
  + [`public/get_contract_size`](https://docs.deribit.com/api-reference/market-data/public-get_contract_size).
  Option `size` is a contract count; option `mark_price` is premium per unit of
  underlying in settlement currency. The venue does not publish a quote notional
  for options.
- *Our carve:* `Bourse.Unified.DeribitPositionUnits` derives the premium only when
  loaded markets supply a positive `contract_size`. Missing `contract_size`
  leaves `notional` nil rather than substituting 1.0. `notional_currency` is the
  option's settlement code.
- *Live evidence:* `test/live/deribit/deribit_authored_integration_test.exs`
  opens an option and a future on one account and asserts the arithmetic.

<!-- carve-evidence-status
{"carve_id":"C-T664","date":"2026-08-22","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_positions option size/mark_price contract and public/get_contract_size base-coin unit for options"},"observed_evidence":{"kind":"live_venue","reference":"test/live/deribit/deribit_authored_integration_test.exs dangerous option+future position unit pin"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-18 — unified client_order_id round-trip (Task 622)
**C-T622 — Deribit `label` is the client identifier on both the request and the
private order/fill echo (task 622). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* Deribit's
  [`private/buy`](https://docs.deribit.com/#private-buy) and
  [`private/sell`](https://docs.deribit.com/#private-sell) accept optional `label`
  (user-defined, maximum 64 characters) and present it on the order when previously
  set. [`private/get_user_trades_by_instrument`](https://docs.deribit.com/#private-get_user_trades_by_instrument)
  echoes the same `label` on each user-trade row.
- *Request:* unified `clientOrderId` / `client_order_id` maps onto native `label`.
  A caller-supplied native `label` wins. Values longer than 64 characters raise
  `invalid_parameters` rather than being silently dropped.
- *Response:* `normalization.field_maps.order` and `.trade` both map `label` onto
  unified `clientOrderId`. The Binance `_bourse_client_order_id` synthetic stays
  the same field-map mechanism — there is no Deribit branch in the parse layer.
- *Live evidence (2026-08-18, testnet):* a market buy on `test.deribit.com` created
  with unified `clientOrderId` returns `%Bourse.Order{client_order_id: id}` and the
  matching `private/get_user_trades_by_instrument` fill carries the same
  `client_order_id`. Durable pin:
  `test/live/deribit/deribit_authored_integration_test.exs`.

<!-- carve-evidence-status
{"carve_id":"C-T622","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"Deribit private/buy, private/sell, and private/get_user_trades_by_instrument label contract (maximum 64 characters)"},"observed_evidence":{"kind":"live_venue","reference":"Live test.deribit.com labelled market order plus matching private/get_user_trades_by_instrument fill on 2026-08-18"},"compatibility_reference":null,"resolved_tier":1}
-->
- *Provider primitive:* `priv/venues/deribit/authority/manifest.json` pins the provider contract for
## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594g — Deribit's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM provider units.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for current/history funding; absent for null interest, next-rate, and previous-rate slots | Deribit defines the payment as funding rate × position size × time fraction and works `0.05%` as `0.0005`; `result`/`interest_8h` and history `interest_1h` therefore remain decimal fractions. [Funding specifications](https://support.deribit.com/hc/en-us/articles/31424939178397-Funding-Specifications) [Funding history](https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_history) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker`, `normalization.field_maps.trading_fee.field_map.maker`, `normalization.field_maps.trading_fee.field_map.taker` | fraction | Deribit applies fee percentages multiplicatively in worked examples (`0.035% = 0.00035`); instrument commission fields and account fee rates retain that fraction. [Fees](https://support.deribit.com/hc/en-us/articles/25944746248989-Fees) [Instruments](https://docs.deribit.com/api-reference/market-data/public-get_instruments) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The market fee-mode flag is null; maker/taker rates are separate. [Instruments](https://docs.deribit.com/api-reference/market-data/public-get_instruments) |
| `normalization.field_maps.option.field_map.percentage` | percent points | Deribit documents `price_change` as the 24-hour price-change percentage and returns examples already in percent points; the authored mapping passes it through. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | percent points | The authored arithmetic divides provider margin by `size_currency` and multiplies by 100, so `10` represents 10%. The position contract supplies those same-unit amounts. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions) |
| `normalization.field_maps.position.field_map.percentage` | percent points | The authored `pnl_percentage` operation computes floating PnL divided by initial margin and emits ×100 percent points. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions) |
| `normalization.field_maps.ticker.field_map.percentage` | absent; no emitted percentage or unit | The general ticker slot is null; option percentage is mapped on the option-specific surface. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker) |
| `normalization.field_maps.trading_fee.field_map.percentage` | boolean, not a numeric rate | The authored `true` declares that maker/taker charges are percentage-based; the numeric rates remain fractions. [Fees](https://support.deribit.com/hc/en-us/articles/25944746248989-Fees) |

<!-- carve-evidence-status
{"carve_id":"C-T594g","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Deribit funding, fee, instrument, ticker, and position contracts linked in C-T594g"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"Registered funding responses establish the funding values, but the complete position and fee-rate set is documentation/arithmetic anchored rather than covered by populated registered rows","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T600f — Deribit percent-point IV and margin sources normalize to unified fractions
(task 600). Outcome: DIVERGE from the prior pass-through and ×100 margin rules.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | Deribit funding arithmetic applies decimal fractions. [Funding specifications](https://support.deribit.com/hc/en-us/articles/31424939178397-Funding-Specifications) |
| `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | These authored slots are null. [Funding history](https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_history) |
| `normalization.field_maps.greeks.field_map.askImpliedVolatility`, `normalization.field_maps.greeks.field_map.bidImpliedVolatility`, `normalization.field_maps.greeks.field_map.markImpliedVolatility` | fraction | Deribit prices `advanced=implv` in percentages (`100` means 100%); ticker `ask_iv`, `bid_iv`, and `mark_iv` use that percent-point convention. Authored `scale: 0.01` emits fractions. [Order price semantics](https://docs.deribit.com/api-reference/trading/private-buy) [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker) |
| `normalization.field_maps.option.field_map.impliedVolatility` | absent | The option-instrument row has no authored IV; Greeks carry ticker IV. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | fraction | Margin divided by same-currency `size_currency` is already a fraction; removing ×100 makes `0.1` represent 10%. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions) |

- *Live evidence (2026-08-12T08:57:33Z):* testnet `public/ticker` returned
  `BTC-13AUG26-58000-C` with `mark_iv 59.44`, `bid_iv 0.0`, and `ask_iv 343.95`.
  The unified values are `0.5944`, `0.0`, and `3.4395`.

<!-- carve-evidence-status
{"carve_id":"C-T600f","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Deribit order implied-volatility, ticker, positions, and funding contracts linked in C-T600f"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-12T08:57:33Z test.deribit.com public/ticker BTC-13AUG26-58000-C mark_iv 59.44 bid_iv 0.0 ask_iv 343.95; parser goldens in deribit_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The live IV row is pinned in parser expectations but is not a manifest-registered response fixture"}
-->
**C-T603f — Deribit margin ratios are restricted to inverse instruments (task 603).
Outcome: DIVERGE from the same-currency claim for linear settlement.**

<!-- rate-unit path="normalization.field_maps.greeks.field_map.askImpliedVolatility" unit="fraction" source-unit="percent_points" --> Deribit ticker IV is in percent points and `scale: 0.01` emits a fraction. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker)
<!-- rate-unit path="normalization.field_maps.greeks.field_map.bidImpliedVolatility" unit="fraction" source-unit="percent_points" --> Deribit ticker IV is in percent points and `scale: 0.01` emits a fraction. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker)
<!-- rate-unit path="normalization.field_maps.greeks.field_map.markImpliedVolatility" unit="fraction" source-unit="percent_points" --> Deribit ticker IV is in percent points and `scale: 0.01` emits a fraction. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker)
<!-- rate-unit path="normalization.field_maps.position.field_map.initialMarginPercentage" unit="fraction" --> On inverse rows, `initial_margin / size_currency` divides same-currency BTC amounts. The provider's `BTC-PERPETUAL` example gives `0.000197283 / 0.006687487`. Linear rows settle margin in USDC/USDT while `size_currency` is base size, so that invalid price-scaled quotient is not emitted. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions)
<!-- rate-unit path="normalization.field_maps.position.field_map.maintenanceMarginPercentage" unit="fraction" --> The inverse-only maintenance ratio follows the same unit identity; linear rows emit no unsupported ratio. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions)

- *Live evidence (2026-08-18):* the registered testnet `private/get_positions`
  recording contains `ETH_USDC-PERPETUAL` with `initial_margin = 0.0381122`
  USDC and `size_currency = 0.001` ETH. The parser leaves both percentage
  fields nil instead of dividing unlike currencies.

<!-- carve-evidence-status
{"carve_id":"C-T603f","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_positions contract and inverse example linked in C-T603f"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"Deribit does not expose a same-unit percentage identity for the linear row; the recording pins the intentional nil output","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->

## 2026-08-13 — list-read discriminator (Task 606)
**C-T606f — Deribit inverse margin ratios are gated on the payload instrument
(task 606). Outcome: DIVERGE from the request-context `market.inverse` gate.**

<!-- rate-unit path="normalization.field_maps.position.field_map.initialMarginPercentage" unit="fraction" --> Inverse vs linear is read from `instrument_name`: linear ids put settle in the first token (`ETH_USDC-PERPETUAL`); inverse ids do not (`BTC-PERPETUAL`). `fetchPositions` is currency-scoped and never carries a request symbol, so a market-context discriminator is absent on the list path. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions)
<!-- rate-unit path="normalization.field_maps.position.field_map.maintenanceMarginPercentage" unit="fraction" --> The maintenance ratio uses the same payload instrument gate. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions)

- *Live evidence (2026-08-13):* testnet `private/get_positions` on an open
  `BTC-PERPETUAL` row emitted the same-currency quotient (~0.0295). The
  request-context `market.inverse` gate had dropped that to nil on the list
  path. The Unified.call list-read golden pins the provider inverse example
  `0.000197283 / 0.006687487` and a linear `ETH_USDC-PERPETUAL` nil branch.

<!-- carve-evidence-status
{"carve_id":"C-T606f","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_positions instrument naming and same-currency inverse example linked in C-T606f"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"The populated recording closes the inverse/linear reachability gap; option position units remain outside this future-only carve","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
