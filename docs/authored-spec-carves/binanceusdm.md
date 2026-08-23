# Binance USD-M carve register

Provider authority: [`priv/venues/binanceusdm/authority/manifest.json`](../../priv/venues/binanceusdm/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
{"carve_id":"C-T633a","date":"2026-08-19","semantic_source":{"kind":"provider_owned","reference":"Binance official USD-M connector GET /fapi/v1/allOrders and /fapi/v1/userTrades startTime/endTime; GET /fapi/v1/openOrders has no time-bound parameters. Indexed by priv/venues/binanceusdm/authority/manifest.json artifacts developer-docs-full and usds-futures-postman"},"observed_evidence":{"kind":"provider_shaped","reference":"Request-shape goldens in test/live/time_window_integration_test.exs and test/bourse/binance_authored_spec_test.exs pin startTime/endTime on USD-M closed/canceled/order-trades reads and omit since/until/startTime/endTime on fetchOpenOrders"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Open-orders omit and history rename are pinned request-side; populated-row boundary evidence for those private histories remains on the time-window exclusion matrix"}
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
{"carve_id":"C-T594d","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M funding, ticker, position, ADL, and commission contracts linked in C-T594d"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"The carried borrow-rate rules have no USD-M provider operation, and the carried spot/inverse static schedules are not USD-M runtime evidence","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
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
{"carve_id":"C-T600d","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance USD-M premium-index and Binance option mark-price contracts linked in C-T600d"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"The carried borrow mappings have no USD-M provider operation","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T603d — the carried Binance option ticker slice preserves the EAPI unit (task 603).
Outcome: DIVERGE from the prior unscaled EAPI percentage.**

<!-- rate-unit path="normalization.field_maps.option.field_map.percentage" unit="percent_points" source-unit="fraction" --> EAPI `priceChangePercent` is a decimal ratio and `scale: 100` emits public percent points. [Option 24hr ticker](https://developers.binance.com/docs/derivatives/option/market-data/24hr-Ticker-Price-Change-Statistics)
<!-- rate-unit path="normalization.field_maps.ticker.field_map.percentage" unit="percent_points" source-unit="fraction" --> The eapi ticker route (`eapiPublic/ticker`) scales only EAPI rows; USD-M ticker rows remain provider percent points. [USD-M 24hr ticker](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/24hr-Ticker-Price-Change-Statistics)
<!-- rate-unit path="normalization.field_maps.position.field_map.percentage" unit="percent_points" source-unit="fraction" --> The position quotient is a fraction before `scale: 100`. [Position information](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Position-Information-V3)

<!-- carve-evidence-status
{"carve_id":"C-T603d","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance EAPI and USD-M ticker contracts linked in C-T603d"},"observed_evidence":{"kind":"provider_shaped","reference":"The 2026-08-12 EAPI row pinned in binance_authored_spec_test.exs is parsed through the carried USD-M module"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The EAPI slice is carried by this complete document but is not a USD-M runtime operation"}
-->
## 2026-08-13 — list-read discriminator (Task 606)
**C-T606d — the carried Binance option ticker slice uses the eapi route
(task 606). Outcome: DIVERGE from the request-context `market.option` gate.**

<!-- rate-unit path="normalization.field_maps.ticker.field_map.percentage" unit="percent_points" source-unit="fraction" --> The carried ticker map now gates the EAPI scale on `eapiPublic/ticker`, matching the binance runtime document. [Option 24hr ticker](https://developers.binance.com/docs/derivatives/option/market-data/24hr-Ticker-Price-Change-Statistics)

<!-- carve-evidence-status
{"carve_id":"C-T606d","date":"2026-08-13","semantic_source":{"kind":"provider_owned","reference":"Binance EAPI ticker contract linked in C-T606d"},"observed_evidence":{"kind":"provider_shaped","reference":"The 2026-08-13 EAPI row pinned in binance_authored_spec_test.exs is parsed through the carried USD-M module"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The EAPI slice is carried by this complete document but is not a USD-M runtime operation"}
-->

## 2026-08-09 — reachable USD-M account and position selectors (Task 534)

**C-T592b — USD-M income and options bills retain separate routed vocabularies
(task 592; amended by Task 601). Outcome: CONFIRM the enumerated income vocabulary;
DIVERGE on unified income labels and the open options type string.**

- *Exchange semantics:* the Income History operation defines the row vocabulary and signed
  `income`; the provider change log additionally documents `AUTO_EXCHANGE` rather than leaving
  the endpoint page as the sole vocabulary source. The provider defines **no semantics** for
  `INSURANCE_CLEAR`, and describes `AUTO_EXCHANGE` only as a Multi-Assets-margin
  auto-exchange event — a system-initiated conversion, not an order fill.
- *Our carve:* `INSURANCE_CLEAR` normalizes to `settlement` and `AUTO_EXCHANGE` to `trade` by
  **our judgment** (the provider is silent on meaning). The official SDK's 22-value enum adds
  `STRATEGY_UMFUTURES_TRANSFER`, `FEE_RETURN`, and `BFUSD_REWARD`. The routed options Funding
  Flow contract defines `type` only as a free `String`, so it evidences row shape but no literal;
  options types pass through while income remains strict.
- *Direction:* negative is `out`, positive is `in`, and zero is `nil` because the provider
  assigns no flow direction to a zero amount.
- *Verification:* the exact income-set guard and open options-scope guard pin the official SDK
  sources separately. The registered populated USD-M income recording pins negative rows as `out`.

<!-- carve-evidence-status
{"carve_id":"C-T592b","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance official Java SDK a13868d0 USD-M IncomeType and options AccountFundingFlowResponseInner contracts; the latter defines type as a free String"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"USD-M income is recorded; the options bill route has no populated provider-owned recording and deliberately preserves its open type string","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
