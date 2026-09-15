# Coinbase Exchange carve register

Provider authority: [`priv/venues/coinbaseexchange/authority/manifest.json`](../../priv/venues/coinbaseexchange/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
{"carve_id":"C-T593a","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange product candle and ticker API references; priv/venues/coinbaseexchange/authority/manifest.json"},"observed_evidence":{"kind":"live_venue","reference":"Live public ETH-USD ticker and candle successes against the production public host"},"compatibility_reference":{"kind":"ccxt","reference":"Frozen Coinbase Exchange reference supplies the reconciled method inventory only"},"resolved_tier":1}
## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594f — Coinbase Exchange has no emitted authored rate-like number (task 594).
Outcome: CONFIRM absence.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.ticker.field_map.percentage` | absent; no emitted rate and no unit | The provider's product-ticker response has price, bid, ask, size, time, trade id, and volume, but no percentage-change field. The authored null is therefore an explicit absence rather than an assumed scale. [Get product ticker](https://docs.cdp.coinbase.com/api-reference/exchange-api/rest-api/products/get-product-ticker) |

<!-- carve-evidence-status
{"carve_id":"C-T594f","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange Get product ticker response contract"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->

## 2026-09-15 — public matches and heartbeat WebSocket (Task 697)

**C-T697a — Exchange feed `matches` + `heartbeat` on `wss://ws-feed.exchange.coinbase.com`, no credentials. Outcome: DIVERGE from Advanced Trade; CONFIRMED against the Exchange channels docs and a live public probe.**

| Authored slot | Venue-owned confrontation |
|---|---|
| `websocket.urls.public` | Official Exchange Market Data host `wss://ws-feed.exchange.coinbase.com` ([overview](https://docs.cdp.coinbase.com/exchange/websocket-feed/overview)). Not Advanced Trade. Sandbox URL is the same host: REST for this venue is production-public-only. |
| `websocket.subscribe` `type`/`product_ids`/`channels` | Dual-field subscribe. Live 2026-09-15: `{"type":"subscriptions","channels":[{"name":"matches","product_ids":["ETH-USD"]},{"name":"heartbeat","product_ids":["ETH-USD"]}]}`. |
| `match` vs `last_match` | Provider: after subscribing to `matches`, the first message type is `last_match` (historical); subsequent trades are `match`. Live ETH-USD: `last_match` trade_id 842900890 then `match` 842900891. last_match is not a new trade. |
| `heartbeat.last_trade_id` / `sequence` | Heartbeat channel carries `last_trade_id` and `sequence` for gap recovery ([channels](https://docs.cdp.coinbase.com/exchange/websocket-feed/channels)). Live: `last_trade_id` 842900890 matched the preceding last_match. |
| invalid channel | Live: `{"type":"error","message":"Failed to subscribe","reason":"not_a_valid_channel is not a valid channel"}`. |

{"carve_id":"C-T697a","date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange WebSocket channels + overview; priv/venues/coinbaseexchange/authority/manifest.json websocket-channels"},"observed_evidence":{"kind":"live_venue","reference":"wss://ws-feed.exchange.coinbase.com ETH-USD matches+heartbeat 2026-09-15"},"compatibility_reference":null,"resolved_tier":1}
