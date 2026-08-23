# Alpaca carve register

Provider authority: [`priv/authority/alpaca/manifest.json`](../../priv/authority/alpaca/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
{"carve_id":"C-T429a","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Alpaca Trading API and Market Data product boundaries; priv/authority/alpaca/manifest.json"},"observed_evidence":{"kind":"live_venue","reference":"Live data.alpaca.markets reads and paper-api.alpaca.markets account/order lifecycle observed 2026-07-23"},"compatibility_reference":{"kind":"ccxt","reference":"Frozen Alpaca reference supplies the reconciled 118-method inventory only"},"resolved_tier":1}
## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594a — Alpaca's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM provider units; documentation-anchored.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.position.field_map.percentage` | percent points | Alpaca defines `unrealized_plpc` as percent by a factor of one and illustrates `(600 - 500) / 500 = 0.20`; the authored `scale: 100` therefore emits `20` percent points. [Positions contract](https://github.com/alpacahq/alpaca-docs/blob/master/content/api-references/broker-api/trading/positions.md) |
| `fees.trading.maker`, `fees.trading.taker` | fraction | The authored zero rates are fraction-valued fee rates; zero is scale-invariant. Alpaca describes commission-free API trading, but no charged fill in the registered evidence establishes a non-zero rate. [Trading fees](https://alpaca.markets/support/what-are-the-fees-or-commissions-for-trading-with-alpaca) |

<!-- carve-evidence-status
{"carve_id":"C-T594a","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Alpaca positions contract and trading-fee statement linked in C-T594a"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The zero static fee rates are scale-invariant and no registered charged fill establishes a non-zero rate"}
-->
**C-T603a — Alpaca's position percentage declares its source unit (task 603).
Outcome: CONFIRM fraction-to-percent-point conversion.**

<!-- rate-unit path="normalization.field_maps.position.field_map.percentage" unit="percent_points" source-unit="fraction" --> Alpaca's `unrealized_plpc` is a decimal ratio; authored `scale: 100` emits the public percent-point contract. [Positions](https://docs.alpaca.markets/reference/getallopenpositions)

<!-- carve-evidence-status
{"carve_id":"C-T603a","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Alpaca positions contract linked in C-T603a"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No populated position body is registered for this rate-unit amendment"}
-->

## 2026-08-18 — trade history and transfers (Task 547)

**C-T547a — `fetchMyTrades` reads paper fills from `GET /v2/account/activities/FILL` (task 547). Outcome: CONFIRM venue.**

- *Exchange semantics:* the Trading API documents `FILL` as order fills (partial and full). Each row carries `id`, `order_id`, `symbol`, `side`, `price`, `qty`, `transaction_time`, and `type` of `fill` / `partial_fill`. The path parameter is `activity_type`; pagination is `page_size` / `page_token`; the time window is `after` / `until` in RFC-3339 or `YYYY-MM-DD`. There is no symbol query — a caller-supplied unified symbol is filtered after parse.
- *Our carve:* pin `activity_type=FILL`, map `limit` → `page_size` and `since` → `after`, convert millisecond `until` in place, and omit unified `symbol` / `since` / `limit` from the wire. Unified `type` stays nil: the venue's `type` is fill vs partial fill, not the order type. Cost is `price * qty`.
- *Live evidence:* paper-api.alpaca.markets returned HTTP 200 and `[]` on 2026-08-18. The paper account's only activity is a `JNLC` funding journal, so no fill row is registered. Field mapping is pinned offline against the provider's published FILL example.

<!-- carve-evidence-status
{"carve_id":"C-T547a","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"https://docs.alpaca.markets/reference/getaccountactivitiesbyactivitytype-1 — Trading API FILL activity schema"},"observed_evidence":{"kind":"live_venue","reference":"paper-api.alpaca.markets GET /v2/account/activities/FILL HTTP 200 empty list 2026-08-18"},"compatibility_reference":null,"resolved_tier":1}
-->
