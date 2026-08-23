# Coinbase Exchange carve register

Provider authority: [`priv/authority/coinbaseexchange/manifest.json`](../../priv/authority/coinbaseexchange/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
{"carve_id":"C-T593a","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange product candle and ticker API references; priv/authority/coinbaseexchange/manifest.json"},"observed_evidence":{"kind":"live_venue","reference":"Live public ETH-USD ticker and candle successes against the production public host"},"compatibility_reference":{"kind":"ccxt","reference":"Frozen Coinbase Exchange reference supplies the reconciled method inventory only"},"resolved_tier":1}
## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594f — Coinbase Exchange has no emitted authored rate-like number (task 594).
Outcome: CONFIRM absence.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.ticker.field_map.percentage` | absent; no emitted rate and no unit | The provider's product-ticker response has price, bid, ask, size, time, trade id, and volume, but no percentage-change field. The authored null is therefore an explicit absence rather than an assumed scale. [Get product ticker](https://docs.cdp.coinbase.com/api-reference/exchange-api/rest-api/products/get-product-ticker) |

<!-- carve-evidence-status
{"carve_id":"C-T594f","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange Get product ticker response contract"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
