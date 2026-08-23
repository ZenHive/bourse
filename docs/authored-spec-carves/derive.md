# Derive carve register

Provider authority: [`priv/authority/derive/manifest.json`](../../priv/authority/derive/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
  [pinned authority manifest](../../priv/authority/derive/manifest.json), artifact
## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594h — Derive's authored rate-like slots name their venue units, and private funding history
is corrected from rate to cashflow (task 594). Outcome: CONFIRMED against the venue's own contract;
the prior authoring mis-mapped the documented cashflow to `rate` and is corrected here.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_history.field_map.rate` | absent; no emitted rate or unit | `private/get_funding_history` defines `funding` as dollar funding paid or received, not a rate. The authored rate slot is now null. [Private funding history](https://docs.derive.xyz/reference/private-get_funding_history) |
| `normalization.field_maps.funding_history.field_map.amount` | cash amount in quote dollars, not a rate | The same provider contract assigns the signed `funding` cashflow to unified `amount`; the regression test pins `-1.25` as amount and leaves rate null. [Private funding history](https://docs.derive.xyz/reference/private-get_funding_history) |
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for current/history funding; absent for null interest, next-rate, and previous-rate slots | Derive publishes `PERP_STATIC_RATE = 0.0000125` as `0.00125%`, explicitly establishing a fraction, and defines funding payment as size × rate × spot × hours. The authored `funding_rate` values pass through. [Asset parameters](https://docs.derive.xyz/docs/asset-parameters-1) [Supported products](https://docs.derive.xyz/docs/supported-products-1) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker` | fraction | The instrument contract identifies the fields as fee rates applied to spot price; registered venue rows carry values such as `0.0001` and `0.0003`, which are retained as fractions. [Get all instruments](https://docs.derive.xyz/reference/public-get_all_instruments) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The market fee-mode flag is null; maker/taker rates are represented separately. [Get all instruments](https://docs.derive.xyz/reference/public-get_all_instruments) |
| `normalization.field_maps.order.field_map.fee.sub_field_map.rate`, `normalization.field_maps.trade.field_map.fee.sub_field_map.rate` | absent; no emitted per-fill rate or unit | Derive order/trade rows expose fee cash amounts, but these nested unified rate slots are null rather than assuming a rate from an amount. [Trade history](https://docs.derive.xyz/reference/public-get_trade_history) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | absent; no emitted percentage or unit | Both margin-percentage slots are null; the position row preserves margin amounts without inventing ratios. [Get subaccount](https://docs.derive.xyz/reference/private-get_subaccount) |
| `normalization.field_maps.position.field_map.percentage` | percent points | The authored arithmetic is `unrealized_pnl / initial_margin × 100`; both operands are provider-defined dollar amounts. [Get subaccount](https://docs.derive.xyz/reference/private-get_subaccount) |
| `normalization.field_maps.ticker.field_map.percentage` | absent; no emitted percentage or unit | C-T560d establishes that the provider ticker has no 24-hour percentage-change source, so the slot remains null. [Get ticker](https://docs.derive.xyz/reference/post_public-get-ticker) |

<!-- carve-evidence-status
{"carve_id":"C-T594h","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Derive private funding-history, funding parameters/payment, instrument, trade, subaccount, and ticker contracts linked in C-T594h"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"No populated private funding-history response is manifest-registered; the cashflow correction is provider-schema anchored and pinned with a provider-shaped offline row","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T600g — Derive rate fields conform to the cross-venue unit contract (task 600).
Outcome: CONFIRM decimal IV and funding fractions; delete the dead income-rate sibling.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | Derive's funding formula multiplies size, spot, hours, and a decimal rate. [Asset parameters](https://docs.derive.xyz/docs/asset-parameters-1) |
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | Funding history carries cash amount, while these rate slots are null. [Funding history](https://docs.derive.xyz/reference/private-get_funding_history) |
| `normalization.field_maps.greeks.field_map.askImpliedVolatility`, `normalization.field_maps.greeks.field_map.bidImpliedVolatility`, `normalization.field_maps.greeks.field_map.markImpliedVolatility` | fraction | Derive's option-pricing response supplies IV to multiplicative volatility-shock formulas whose parameters are decimals; no percent-point scale is applied. [Ticker](https://docs.derive.xyz/reference/ticker-instrument_name-interval) [Portfolio margin](https://docs.derive.xyz/docs/portfolio-margin-1) |

- `normalization.field_maps.income` is now null. Its dead extras entry mapped the provider's
  dollar `funding` cashflow to `rate`, duplicating the error already corrected in funding history.

<!-- carve-evidence-status
{"carve_id":"C-T600g","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Derive ticker, portfolio-margin, asset-parameter, and funding-history contracts linked in C-T600g"},"observed_evidence":{"kind":"provider_shaped","reference":"IV and funding parser goldens in derive_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No manifest-registered populated option ticker or private funding-history row is carried"}
-->

## 2026-07-22 — response 4.5.65 position adjudication (Task 442)

**C-T528b — SM collateral free/used values are undefined. Outcome: DIVERGE from synthesized balance accounting (task 528).**

- *Exchange semantics:* Derive's
  [Get Subaccount](https://docs.derive.xyz/reference/private-get_subaccount) and
  [Get All Portfolios](https://docs.derive.xyz/reference/private-get_all_portfolios)
  response contracts define each collateral's `amount` in asset units. Their margin fields are
  USD-valued credits or requirements: `initial_margin`, `maintenance_margin`, and
  `open_orders_margin`. Neither response defines an available/free asset amount or a locked/used
  asset amount for SM subaccounts.
- *Observed behavior:* the live SM subaccount `144422` response on 2026-07-29 carried ETH
  `amount: "0.02"` and the documented USD margin fields. The unified balance therefore returned
  `total["ETH"] == 0.02`, with `free["ETH"]` and `used["ETH"]` nil.
- *Decision:* map `total` from the provider collateral `amount` and deliberately leave `free`
  and `used` null. Deriving either from a USD margin field would mix currency units and invent a
  provider meaning.

