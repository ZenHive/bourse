# Bybit carve register

Provider authority: [`priv/venues/bybit/authority/manifest.json`](../../priv/venues/bybit/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
  ([pinned authority manifest](../../priv/venues/bybit/authority/manifest.json), artifact
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
{"carve_id":"C-T594e","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Bybit funding-fee, borrow-history, ticker, position, instrument, and fee-rate contracts linked in C-T594e"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"The closed-position cumEntryValue/cumExitValue ratio is not identified by Bybit as an initial-margin percentage","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
## 2026-08-12 — ledger type authority (Task 598)
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
{"carve_id":"C-T603e","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Bybit V5 ticker contract linked in C-T603e"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"The registered ticker establishes the wire value but the amendment remains documentation-derived for every market family","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->

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
