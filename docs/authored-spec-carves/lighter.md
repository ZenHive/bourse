# Lighter carve register

Provider authority: [`priv/authority/lighter/manifest.json`](../../priv/authority/lighter/manifest.json).
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
