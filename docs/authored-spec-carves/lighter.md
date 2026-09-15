# Lighter carve register

Provider authority: [`priv/venues/lighter/authority/manifest.json`](../../priv/venues/lighter/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
## 2026-08-11 — account and history response slices (Task 546)
**C-T600i — Lighter's rate-like slots normalize to the cross-venue units (task 600).
Outcome: DIVERGE from pass-through margin; CONFIRM funding, fee, and ticker units.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | C-T546g proves the provider `Funding.rate` is percent points from `value = mark_price × rate / 100`; `scale: 0.01` emits a fraction. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker` | fraction | The market's decimal maker/taker fee rates are multiplicative charges; the recorded zero rates remain fractions. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `fees.maker`, `fees.taker` | fraction | The venue-level zero defaults are decimal fee fractions; authenticated market rows remain authoritative. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.market.field_map.percentage` | absent | The fee-mode flag is null. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.position.field_map.initialMarginPercentage` | fraction | The provider's `initial_margin_fraction` response is percent points (`"5.00"`); authored `scale: 0.01` emits `0.05`. The recorded position pins that conversion. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.position.field_map.maintenanceMarginPercentage`, `normalization.field_maps.position.field_map.percentage` | absent | Neither position field is authored. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.ticker.field_map.percentage` | percent points | The provider publishes `daily_price_change` as the daily percentage change; the recorded ticker raw `1.3548036637247152` emits 1.3548 percent points. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |

<!-- carve-evidence-status
{"carve_id":"C-T600i","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Pinned Lighter OpenAPI Funding, AccountPosition, OrderBookDetail and fee schemas"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T603g — Lighter's scaled percentages declare their source units (task 603).
Outcome: CONFIRM percent-point-to-fraction conversion.**

<!-- rate-unit path="normalization.field_maps.funding_rate_history.field_map.fundingRate" unit="fraction" source-unit="percent_points" --> Lighter's funding row is percentage-valued; `scale: 0.01` emits the unified fraction. [API reference](https://apidocs.lighter.xyz/)
<!-- rate-unit path="normalization.field_maps.position.field_map.initialMarginPercentage" unit="fraction" source-unit="percent_points" --> `initial_margin_fraction` is percentage-valued; `scale: 0.01` emits the unified fraction. [API reference](https://apidocs.lighter.xyz/)

<!-- carve-evidence-status
{"carve_id":"C-T603g","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Pinned Lighter Funding and AccountPosition schemas"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
## 2026-09-15 — current venue funding rates (Task 692)
**C-T692 — Lighter's current funding `rate` is a signed hourly fraction, not history percent-points (task 692).
Outcome: CONFIRM current `GET /api/v1/funding-rates` `rate` as source-unit fraction; DIVERGE from `/fundings` history `scale: 0.01`.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate` | fraction | OpenAPI `FundingRate.rate` is a signed decimal with no percent conversion. Live testnet 2026-09-15 returned Lighter BTC `rate: 9.6e-5` alongside comparison-venue rows; that magnitude matches an hourly fraction (Hyperliquid `funding: 0.0001841099` the same day), not the history percent-points that C-T546g/`scale: 0.01` convert. [Funding rates](https://apidocs.lighter.xyz/#tag/funding/GET/api/v1/funding-rates) [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | The current `FundingRate` object is `{market_id, exchange, symbol, rate}` — no interest, next, or previous slots. [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |

<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.fundingRate" unit="fraction" source-unit="fraction" --> Lighter's current `funding-rates` `rate` is already a signed decimal fraction; no scale. History `/fundings` stays percent-points under C-T603g. [Funding rates](https://apidocs.lighter.xyz/#tag/funding/GET/api/v1/funding-rates)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.interestRate" unit="absent" --> Current funding rows do not carry an interest component. [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.nextFundingRate" unit="absent" --> Current funding rows do not carry a next-rate slot. [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.previousFundingRate" unit="absent" --> Current funding rows do not carry a previous-rate slot. [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json)

<!-- carve-evidence-status
{"carve_id":"C-T692","date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"Pinned Lighter OpenAPI FundingRate plus GET /api/v1/funding-rates"},"observed_evidence":{"kind":"live_call","reference":"testnet GET /api/v1/funding-rates 2026-09-15 Lighter BTC rate 9.6e-5 signed fraction; comparison rows dropped"},"compatibility_reference":null,"resolved_tier":"verified","note":"interval authored 1h from history resolution 1h plus matching hourly-fraction magnitude; REST snapshot is not the market_stats WebSocket"}
-->
