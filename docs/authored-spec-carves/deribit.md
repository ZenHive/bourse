# Deribit carve register

Provider authority: [`priv/venues/deribit/authority/manifest.json`](../../priv/venues/deribit/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.

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
