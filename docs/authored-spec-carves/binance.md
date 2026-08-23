# Binance carve register

Provider authority: [`priv/authority/binance/manifest.json`](../../priv/authority/binance/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
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
- *Evidence sources:* live testnet `Bourse.fetch_markets` on binance — exchangeInfo bodies
  carry filters without fee fields.
- *Implementation:* 164.

schema ([pinned authority manifest](../../priv/authority/binance/manifest.json), artifact
## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594b — Binance's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM documented and arithmetic-derived units; retain explicit gaps.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.adl_rank.field_map.percentage` | absent; no emitted percentile or unit | The authored slot is null. Binance's position-ADL response supplies a quantile rank, not a percentage field. [Position ADL quantile](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Position-ADL-Quantile-Estimation) |
| `normalization.field_maps.borrow_interest.field_map.interestRate`, `normalization.field_maps.borrow_rate.field_map.rate` | unverified | The spot margin contracts publish decimal `interestRate` / `dailyInterestRate` examples, but the carried evidence has no principal × rate = interest row and no explicit fraction-vs-percent statement. The unit remains unverified rather than inferred from magnitude. [Interest history](https://developers.binance.com/docs/margin_trading/borrow-and-repay/Get-Interest-History) |
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for `fundingRate` / `interestRate`; absent for null history-payment, next-rate, and previous-rate slots | Binance defines a funding payment as position notional × funding rate and publishes rates such as `0.00010000`; the authored numeric fields pass that fraction through. The null slots emit no rate. [Funding formula](https://www.binance.com/en/support/faq/introduction-to-binance-futures-funding-rates-360033525031) [Premium index](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Mark-Price) |
| `normalization.field_maps.leverage_tiers.field_map.maintenanceMarginRate` | fraction | Binance's leverage-bracket contract publishes `maintMarginRatio` as a decimal ratio, with examples such as `0.004` for 0.4%. [Notional and leverage brackets](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/Notional-and-Leverage-Brackets) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The authored market fee-mode flag is null; maker/taker rates are represented separately. [Commission rates](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate) |
| `normalization.field_maps.option.field_map.percentage`, `normalization.field_maps.ticker.field_map.percentage` | percent points | Binance names `priceChangePercent` as the percentage change and publishes examples in percent points; neither mapping applies a second ×100 conversion. [24hr ticker](https://developers.binance.com/docs/binance-spot-api-docs/rest-api/market-data-endpoints#24hr-ticker-price-change-statistics) |
| `normalization.field_maps.option_position.field_map.initialMarginPercentage`, `normalization.field_maps.option_position.field_map.maintenanceMarginPercentage`, `normalization.field_maps.option_position.field_map.percentage` | absent; no emitted percentage or unit | All three option-position percentage slots are null. [Option position information](https://developers.binance.com/docs/derivatives/option/trade/Option-Position-Information) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | fraction | The authored arithmetic divides provider margin amounts by provider notional, so `0.1` represents 10%; no ×100 is applied. [Position information](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Position-Information-V3) |
| `normalization.field_maps.position.field_map.percentage` | percent points | The authored arithmetic is `unRealizedProfit / initialMargin × 100`, so `10` represents 10%. The provider contract supplies both monetary operands. [Position information](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Position-Information-V3) |
| `normalization.field_maps.trading_fee.field_map.maker`, `normalization.field_maps.trading_fee.field_map.taker`, `normalization.field_maps.trading_fees.field_map.maker`, `normalization.field_maps.trading_fees.field_map.taker` | fraction | The provider commission-rate response publishes decimal maker/taker values; the recorded signed response and request-level contract are preserved without ×100. [User commission rate](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate) |
| `normalization.field_maps.trading_fee.field_map.percentage`, `normalization.field_maps.trading_fees.field_map.percentage` | absent boolean; no numeric unit | Both percentage-mode flags are null; the maker/taker fields carry decimal fractions independently. [User commission rate](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate) |
| `fees.trading.maker`, `fees.trading.taker`, `fees.linear.trading.maker`, `fees.linear.trading.taker`, `fees.inverse.trading.maker`, `fees.inverse.trading.taker`, `fees.linear.trading.tiers.maker[*].rate`, `fees.linear.trading.tiers.taker[*].rate`, `fees.inverse.trading.tiers.maker[*].rate`, `fees.inverse.trading.tiers.taker[*].rate` | fraction | Static schedule values use decimal fractions (`0.001` = 0.1%); signed commission endpoints remain authoritative for an account's effective rate. [Spot commission rates](https://developers.binance.com/docs/binance-spot-api-docs/faqs/commission_faq) [Futures commission rates](https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/User-Commission-Rate) |

<!-- carve-evidence-status
{"carve_id":"C-T594b","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance funding, ticker, position, margin-interest, option-position, and commission contracts linked in C-T594b"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"Borrow-rate responses lack a registered principal/rate/interest identity and the provider contract does not state fraction versus percent explicitly","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T600b — Binance rate fields conform to the cross-venue unit contract (task 600).
Outcome: CONFIRM the option-IV fraction and split emitted funding units from absent slots.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.borrow_interest.field_map.interestRate`, `normalization.field_maps.borrow_rate.field_map.rate` | fraction contract; provider source unit remains unverified | Binance publishes decimal examples and Bourse exposes rate fields as fractions; C-T594b's missing principal arithmetic remains an evidence gap, not a second unified unit. [Interest history](https://developers.binance.com/docs/margin_trading/borrow-and-repay/Get-Interest-History) |
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | Binance defines funding payment from notional and a decimal rate. [Premium index](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Mark-Price) |
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | These authored slots are null. [Premium index](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Mark-Price) |
| `normalization.field_maps.greeks.field_map.askImpliedVolatility`, `normalization.field_maps.greeks.field_map.bidImpliedVolatility`, `normalization.field_maps.greeks.field_map.markImpliedVolatility` | fraction | The option mark-price contract publishes `askIV`, `bidIV`, and `markIV` as decimal implied volatilities; the provider example `0.708575` is retained as 70.8575%. [Option mark price](https://developers.binance.com/docs/derivatives/option/market-data/Option-Mark-Price) |
| `normalization.field_maps.option.field_map.impliedVolatility` | absent | The generic option row has no authored IV; Greeks carry it. [Option mark price](https://developers.binance.com/docs/derivatives/option/market-data/Option-Mark-Price) |

<!-- carve-evidence-status
{"carve_id":"C-T600b","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance option mark-price, premium-index, and margin-interest contracts linked in C-T600b"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"The carried margin-interest response still lacks registered principal arithmetic","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T603b — Binance option ticker fractions normalize to percent points (task 603).
Outcome: DIVERGE from the spot-ticker unit applied to the EAPI route.**

<!-- rate-unit path="normalization.field_maps.option.field_map.percentage" unit="percent_points" source-unit="fraction" --> EAPI `priceChangePercent` is a decimal ratio: the live row `SOL-260814-66-P` (`priceChange=1.42`, `open=0.08`, `lastPrice=1.5`) carries `priceChangePercent=17.75`, satisfying `1.42 / 0.08 = 17.75`; authored `scale: 100` emits `1775` percent points, and the unified output was observed emitting exactly that. [Option 24hr ticker](https://developers.binance.com/docs/derivatives/option/market-data/24hr-Ticker-Price-Change-Statistics)
<!-- rate-unit path="normalization.field_maps.ticker.field_map.percentage" unit="percent_points" source-unit="fraction" --> The eapi ticker route (`eapiPublic/ticker`) converts the EAPI fraction; spot and futures routes retain their provider percent points unchanged. [Option 24hr ticker](https://developers.binance.com/docs/derivatives/option/market-data/24hr-Ticker-Price-Change-Statistics) [Spot 24hr ticker](https://developers.binance.com/docs/binance-spot-api-docs/rest-api/market-data-endpoints#24hr-ticker-price-change-statistics)
<!-- rate-unit path="normalization.field_maps.position.field_map.percentage" unit="percent_points" source-unit="fraction" --> The authored position quotient is a fraction before `scale: 100`. [Position information](https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Position-Information-V3)

- *Live evidence (2026-08-13):* production `GET /eapi/v1/ticker` returned
  `SOL-260814-66-P` with `priceChange 1.42`, `open 0.08`, `lastPrice 1.5` and
  `priceChangePercent 17.75` (= `1.42 / 0.08`, the venue's own arithmetic), and
  `Bourse.fetch_option/2` emitted `percentage: 1775.0` percent points from that
  live body. The earlier round-number example row (`-5 / 25 = -0.2`) was
  illustrative, not observed, and is superseded by this observation.

<!-- carve-evidence-status
{"carve_id":"C-T603b","date":"2026-08-13","semantic_source":{"kind":"provider_owned","reference":"Binance EAPI and spot 24hr ticker contracts linked in C-T603b"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-13 eapi.binance.com GET /eapi/v1/ticker SOL-260814-66-P priceChange 1.42 open 0.08 priceChangePercent 17.75; unified fetch_option emitted percentage 1775.0"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The live EAPI body is pinned as a parser golden but is not registered as a frozen response"}
-->
## 2026-08-13 — list-read discriminator (Task 606)
**C-T606b — Binance option ticker fractions are gated on the eapi route
(task 606). Outcome: DIVERGE from the request-context `market.option` gate.**

<!-- rate-unit path="normalization.field_maps.ticker.field_map.percentage" unit="percent_points" source-unit="fraction" --> `fetchTickers` with `type=option` (or a symbols list) hits `GET /eapi/v1/ticker` with no singular `symbol`, so a market-context discriminator is absent. The eapi route identity `eapiPublic/ticker` scales the wire fraction; other ticker routes keep provider percent points. [Option 24hr ticker](https://developers.binance.com/docs/derivatives/option/market-data/24hr-Ticker-Price-Change-Statistics)

- *Live evidence (2026-08-13):* production `GET /eapi/v1/ticker` returned
  `SOL-260814-66-P` with `priceChangePercent 17.75`. Plural `fetchTickers` on
  that eapi body now emits `1775.0`, matching `fetchOption` / `fetchTicker`.

<!-- carve-evidence-status
{"carve_id":"C-T606b","date":"2026-08-13","semantic_source":{"kind":"provider_owned","reference":"Binance EAPI 24hr ticker contract linked in C-T606b"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-13 eapi.binance.com GET /eapi/v1/ticker SOL-260814-66-P priceChangePercent 17.75; Unified.call fetchTickers list-read golden in binance_authored_spec_test.exs emits 1775.0"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The live EAPI body is pinned as a parser golden but is not registered as a frozen response"}
-->

## 2026-08-09 — reachable method-specific endpoint defaults (Task 534)

**C-T592c — Binance ledger vocabularies are scoped to their routed provider contracts
(task 592; amended by Tasks 598 and 601). Outcome: CONFIRM the enumerated income vocabulary;
DIVERGE for the open options type string and unified label judgments.**

- *Exchange semantics:* the official Binance Java SDK's USD-M `IncomeType` enum carries 22
  literals. The options Account Funding Flow contract documents `asset`, signed `amount`, and
  `type` as a free `String`; it enumerates no type literals. The futures/portfolio-margin routes emit
  `incomeType`, signed `income`, and `asset`; the options route emits `type`, `amount`, and
  `asset`.
- *Our carve:* endpoint-scoped field maps keep the 22-value income enum strict while the options
  bill route preserves its open string. `STRATEGY_UMFUTURES_TRANSFER`, `FEE_RETURN`, and
  `BFUSD_REWARD` are mapped by our coarse unified judgment, as are `INSURANCE_CLEAR` and
  `AUTO_EXCHANGE`; no options literal is claimed from the provider contract.
- *Direction:* provider contracts define positive as inflow and negative as outflow. They do
  not assign a direction to zero, so the zero arm is `nil` rather than inventing an inflow.
- *Verification:* the registered generic-Binance demo recording from `fapi/v1/income` is parsed
  through `Bourse.Binance` and pins type, signed amount, asset, and direction. A shape-only
  options parser test pins arbitrary-string passthrough without treating its literal as evidence.
  The coverage guard asserts the income enum exactly and the options open set independently.

<!-- carve-evidence-status
{"carve_id":"C-T592c","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Binance official Java SDK a13868d0 IncomeType and AccountFundingFlowResponseInner contracts; the latter defines type as a free String"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"Income is manifest-recorded; no populated provider-owned options bill recording enumerates literals, so options type deliberately passes through","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
