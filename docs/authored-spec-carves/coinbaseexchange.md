# Coinbase Exchange carve register

Provider-authoritative decisions for the deliberately public-only Coinbase
Exchange client surface.

**Canonical for this venue.**

**C-T593a — The client exposes only candles and ticker (task 593). Outcome: DIVERGE from the broader reference inventory.**

- *Exchange semantics:* Coinbase documents public product candle and ticker
  routes that require no credentials.
- *Our carve:* only `fetchOHLCV` and `fetchTicker` are supported. Every other
  reference-inventoried method is explicitly false, authenticated sections are
  empty, and no signing recipe exists.
- *Verification:* both unified reads returned live ETH-USD data from
  `api.exchange.coinbase.com` without credentials on 2026-08-11.

**C-T593b — Candle granularity and pagination follow inclusive provider windows (task 593). Outcome: CONFIRMED provider contract.**

- *Exchange semantics:* granularity is one of `60`, `300`, `900`, `3600`,
  `21600`, or `86400` seconds. The provider documents a 300-candle maximum and
  directs clients to issue multiple start/end requests for larger histories.
- *Our carve:* unified timeframes are `1m`, `5m`, `15m`, `1h`, `6h`, and `1d`.
  Requests over 300 candles are split into inclusive, non-overlapping windows;
  the merged result is chronological and deduplicated.
- *Verification:* live 1d probes returned 300 rows for a 299-day delta and 301
  rows for a 300-day delta, while a 301-day delta returned the provider's
  exceeds-300 error. Granularity `61` returned `Unsupported granularity`.

**C-T593c — Wire ordering and sparse/forming buckets are preserved honestly (task 593). Outcome: CONFIRMED observed behavior.**

- *Exchange semantics:* the candle response row is
  `[time, low, high, open, close, volume]`; intervals with no ticks may be
  absent.
- *Our carve:* Coinbase's newest-first wire rows are normalized to chronological
  `[milliseconds, open, high, low, close, volume]`. No empty bucket is invented.
  The current forming bucket is present after that interval has traded and may
  be absent before its first tick.
- *Verification:* consecutive live minute probes on 2026-08-11 showed descending
  raw timestamps and the current bucket appearing after a trade; the provider
  documentation independently states that no-tick intervals are omitted.

<!-- carve-evidence-status
{"carve_id":"C-T593a","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange product candle and ticker API references; priv/authority/coinbaseexchange/manifest.json"},"observed_evidence":{"kind":"live_venue","reference":"Live public ETH-USD ticker and candle successes recorded under test/fixtures/responses/coinbaseexchange"},"compatibility_reference":{"kind":"ccxt","reference":"Frozen Coinbase Exchange reference supplies the reconciled method inventory only"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T593b","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange Get product candles reference"},"observed_evidence":{"kind":"live_venue","reference":"Live inclusive-window row counts and invalid-granularity/range errors observed 2026-08-11"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T593c","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange candle response schema and no-tick interval note"},"observed_evidence":{"kind":"live_venue","reference":"Live ETH-USD minute candles observed newest-first with a conditional forming bucket on 2026-08-11"},"compatibility_reference":null,"resolved_tier":1}
-->
