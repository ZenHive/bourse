# OKX carve register

Provider authority: [`priv/authority/okx/manifest.json`](../../priv/authority/okx/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
from `priv/authority/okx/manifest.json` artifact `api-v5-docs` — makes those cursors exclusive.
## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594j — OKX's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM provider arithmetic; retain one history-position gap.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.borrow_interest.field_map.interestRate`, `normalization.field_maps.borrow_rate.field_map.rate` | fraction | OKX's example satisfies accrued interest = liability × `interestRate` (`100 × 0.0000040833333333 = 0.00040833333333`), establishing a fractional hourly rate. [Interest accrued data](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-interest-accrued-data) |
| `normalization.field_maps.funding_history.field_map.rate` | absent; no emitted rate or unit | Account funding-history rows map a cash amount and leave rate null rather than inferring one without position value. [Bills details](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-bills-details-last-7-days) |
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | fraction for current/next funding; absent for null interest and previous-rate slots | OKX defines funding fee as position value × funding rate and works `0.1%` as a multiplicative percentage; current and next rates remain decimal fractions. [Funding FAQ](https://www.okx.com/en-us/help/funding-fees-for-perpetual-contracts-faq) [Funding mechanism](https://www.okx.com/en-gb/help/perps-funding-fee-mechanism) |
| `normalization.field_maps.leverage_tiers.field_map.maintenanceMarginRate` | fraction | OKX's position-tier contract publishes `mmr` as a decimal maintenance-margin ratio. [Position tiers](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-position-tiers) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker` | absent; no emitted market rate or unit | Both authored market fee slots are null; authenticated fee-rate data uses the trading-fee surface. [Get fee rates](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-fee-rates) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The market fee-mode flag is null. [Get fee rates](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-fee-rates) |
| `normalization.field_maps.option.field_map.percentage` | absent; no emitted percentage or unit | The authored option percentage slot is null. [Option market data](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-get-tickers) |
| `normalization.field_maps.position.branches[0].field_map.initialMarginPercentage` | fraction | For isolated history rows the annotation computes `1 / leverage`, so `0.1` represents 10%. [Positions history](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions-history) |
| `normalization.field_maps.position.branches[0].field_map.maintenanceMarginPercentage` | unverified fraction-valued zero | The history contract supplies neither maintenance margin nor notional; the authored annotation emits zero. Zero is scale-invariant, but the provider does not establish it as a maintenance-margin percentage. [Positions history](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions-history) |
| `normalization.field_maps.position.branches[0].field_map.percentage` | absent; no emitted percentage or unit | The history-position PnL percentage slot is null. [Positions history](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions-history) |
| `normalization.field_maps.position.branches[1].field_map.initialMarginPercentage`, `normalization.field_maps.position.branches[1].field_map.maintenanceMarginPercentage` | fraction | The open-position annotation derives initial/maintenance margin divided by notional; `0.1` represents 10%. [Positions](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions) |
| `normalization.field_maps.position.branches[1].field_map.percentage` | percent points | OKX defines `uplRatio` as the floating-PnL ratio; the authored annotation multiplies by 100 to emit percent points. [Isolated margin mode](https://www.okx.com/en-us/help/iv-isolated-margin-mode) |
| `normalization.field_maps.ticker.field_map.percentage` | percent points | The authored cross-field identity is `(last - open24h) / open24h × 100`, using provider price fields, so `10` represents 10%. [Tickers](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-get-tickers) |
| `normalization.field_maps.trading_fee.field_map.maker`, `normalization.field_maps.trading_fee.field_map.taker` | fraction | OKX publishes decimal maker/taker rates and defines negative values as commission and positive values as rebate; authored `scale: -1` normalizes sign without changing fractional magnitude. [Get fee rates](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-fee-rates) |
| `normalization.field_maps.trading_fee.field_map.percentage`, `normalization.field_maps.trading_fees.field_map.maker`, `normalization.field_maps.trading_fees.field_map.taker`, `normalization.field_maps.trading_fees.field_map.percentage` | absent; fee-mode boolean and plural rates emit no numeric unit | These plural/flag slots are null; singular authenticated maker/taker fields carry the rates. [Get fee rates](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-fee-rates) |
| `fees.future.maker`, `fees.future.taker`, `fees.spot.maker`, `fees.spot.taker`, `fees.swap.maker`, `fees.swap.taker`, `fees.trading.maker`, `fees.trading.taker` | fraction | Static schedule values use decimal fractions; OKX's fee arithmetic is fee rate × transaction amount, while authenticated fee rates remain authoritative for an account. [Trading fee rules](https://www.okx.com/en-gb/help/trading-fee-rules-faq) |

<!-- carve-evidence-status
{"carve_id":"C-T594j","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"OKX interest, funding, position, ticker, and fee contracts linked in C-T594j"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"The history-position maintenance-margin percentage is a scale-invariant zero without a provider maintenance-margin/notional identity","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
## 2026-08-12 — ledger type authority (Task 598)
**C-T600j — OKX IV and funding fields conform to the cross-venue fraction contract
(task 600). Outcome: CONFIRM provider decimal volatility.**

<!-- rate-unit path="normalization.field_maps.greeks.field_map.askImpliedVolatility" unit="fraction" --> OKX option volatility uses decimal values; its option market-data contract states `1` means 100%. [Option market data](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-option-market-data)
<!-- rate-unit path="normalization.field_maps.greeks.field_map.bidImpliedVolatility" unit="fraction" --> `bidVol` follows the same option-volatility convention. [Option market data](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-option-market-data)
<!-- rate-unit path="normalization.field_maps.greeks.field_map.markImpliedVolatility" unit="fraction" --> `markVol` follows the same option-volatility convention. [Option market data](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-option-market-data)
<!-- rate-unit path="normalization.field_maps.option.field_map.impliedVolatility" unit="absent" --> The generic option row has no authored IV. [API v5](https://www.okx.com/docs-v5/en/)
<!-- rate-unit path="normalization.field_maps.funding_history.field_map.rate" unit="absent" --> Bills carry cash amount, not an inferred rate. [API v5](https://www.okx.com/docs-v5/en/)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.fundingRate" unit="fraction" --> The decimal funding rate multiplies position value. [Funding FAQ](https://www.okx.com/en-us/help/funding-fees-for-perpetual-contracts-faq)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.interestRate" unit="absent" --> The authored slot is null. [Funding FAQ](https://www.okx.com/en-us/help/funding-fees-for-perpetual-contracts-faq)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.nextFundingRate" unit="fraction" --> The provider next funding rate is a decimal fraction. [Funding FAQ](https://www.okx.com/en-us/help/funding-fees-for-perpetual-contracts-faq)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.previousFundingRate" unit="absent" --> The authored slot is null. [Funding FAQ](https://www.okx.com/en-us/help/funding-fees-for-perpetual-contracts-faq)

<!-- carve-evidence-status
{"carve_id":"C-T600j","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"OKX API v5 option volatility and funding contracts linked in C-T600j"},"observed_evidence":{"kind":"provider_shaped","reference":"Option-volatility parser golden in okx_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The option-volatility parser golden is provider-shaped rather than a manifest-registered live response"}
-->
**C-T603h — OKX fee-sign scales declare their source unit (task 603).
Outcome: CONFIRM sign inversion without a unit conversion.**

<!-- rate-unit path="normalization.field_maps.trading_fee.field_map.maker" unit="fraction" source-unit="fraction" --> OKX supplies decimal fee rates; `scale: -1` changes rebate/charge sign while preserving the fraction unit. [Trading fee rates](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-fee-rates)
<!-- rate-unit path="normalization.field_maps.trading_fee.field_map.taker" unit="fraction" source-unit="fraction" --> OKX supplies decimal fee rates; `scale: -1` changes sign while preserving the fraction unit. [Trading fee rates](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-fee-rates)

<!-- carve-evidence-status
{"carve_id":"C-T603h","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"OKX trading fee-rate contract linked in C-T603h"},"observed_evidence":{"kind":"provider_shaped","reference":"Fee-rate parser goldens in okx_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No populated fee-rate response is registered for this sign-only amendment"}
-->

**C-T598c — bill types come from OKX's authenticated Get bills types enumeration (task 598).
Outcome: CONFIRM the recorded trading-account vocabulary; DIVERGE for unnamed account types and
provider-specific funding-account values (amended by Task 601).**

- *Provider contract:* the bills documentation delegates the type vocabulary to authenticated
  `GET /api/v5/account/subtypes` (Get bills types) instead of maintaining an inline enum.
- *Live confrontation:* the manifest-registered international-demo recording returned `code=0`
  on 2026-08-12 with 32 top-level
  types: `1`–`16`, then `20`, `22`, `24`, `26`–`30`, `32`–`35`, `37`, `38`,
  `250`, and `251`.
- *Our trading-account carve:* all 29 values carrying a current provider name translate to stable
  snake-case semantics. Current types `22`, `24`, and `26` have blank `typeDesc` values and pass
  through numerically; later additions do likewise. This is recorded as DIVERGE, not CONFIRM.
- *Our funding-account carve:* `/api/v5/asset/bills` has a separate 147-value table. Deposit `1`,
  withdrawal `2`, and documented account-transfer codes normalize on that route; other
  funding-specific values pass through. The same codes never reuse the trading-account map.
- *Direction:* OKX defines positive `balChg` as a balance increase and negative as a decrease;
  zero has no flow direction and maps to `nil`.

<!-- carve-evidence-status
{"carve_id":"C-T598c","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"OKX API v5 Get bills types and funding-account Asset bills details contracts"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"Trading-account enumeration is manifest-recorded; the international demo asset-bills call returned an empty success, so its populated-row semantics remain in the production-verification ledger","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->

## 2026-07-19 — plain-order defaults for multi-endpoint no-arg reads (Task 378)

**C-T382a — Order details and fills share one instrument-invariant field contract. Outcome: CONFIRMED-against-OKX docs (task 382).**

- *Exchange semantics:* The OKX V5 order-details rows use `sz`/`accFillSz`, `px`/`avgPx`, signed
  `fee` plus `feeCcy`, and `ordType` for spot, margin, futures, swaps, and options. Fills use the
  same meanings under `fillSz`/`fillPx`, with `execType` `T`/`M` identifying taker/maker. The
  schema does not redefine these fields by instrument family; option size remains contracts and
  option price remains the quote in the contract's settlement currency.
- *Our carve:* derive order cost from `accFillSz × (avgPx ?? px ?? ordPx)`, negate the venue's
  signed fee into unified `fee.cost`, mirror the fee into `fees`, and normalize order type,
  time-in-force, and post-only state from `ordType`. Fill cost uses authored operand fallbacks
  (`sz`→`fillSz`, `px`→`fillPx`) and the same fee projection. Empty acknowledgement rows do not
  acquire an empty fee object.
- *Tier-1 evidence:* the first EEA-demo place attempt returned venue business code `51155`, so it
  created no order. The international demo then accepted a reversible far-from-market option
  order for `BTC-USD-260925-280000-C`: the populated detail row carried id, symbol, live state,
  buy side, limit type, price `0.0001`, size `1`, filled `0`, fee `0` in BTC, and creation/update
  clocks. The order was canceled and absence from open orders was verified. This option row plus
  the common OKX response schema establishes that the authored parser contract is not a
  spot/swap-only carve.
- *Compatibility:* `fetchOrder`, the populated normal-order `fetchOpenOrders`, and
  `fetchMyTrades` now match the bundled CCXT fixture semantics for price/cost/fees/type without a
  divergence contract.

