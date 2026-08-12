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

**C-T593d — Ticker `volume` maps to `baseVolume` (task 593, confronted post-land). Outcome: CONFIRMED against the recorded wire value.**

- *Exchange semantics:* the product ticker route documents `volume` only as
  "24h volume" without naming the unit; the provider text alone does not
  settle base-vs-quote.
- *Our carve:* `volume` is parsed as `baseVolume`.
- *Verification:* the registered live recording
  (`test/fixtures/responses/coinbaseexchange/fetch_ticker.json`) shows
  `volume: "66031.61658655"` for ETH-USD — a plausible ETH quantity and three
  orders of magnitude below any plausible 24h USD notional, which
  disconfirms the quote-unit reading. `quoteVolume` and `vwap` stay null.

**C-T593e — Ticker omits `high`/`low`/`open` (task 593, confronted post-land). Outcome: DIVERGE from the reference enrichment.**

- *Exchange semantics:* `GET /products/{id}/ticker` carries no high/low/open
  fields; the reference document populates them by additionally calling
  `/products/{id}/stats`.
- *Our carve:* the unified ticker maps only what the ticker route itself
  returns — `price`, `bid`, `ask`, `volume`, `time` — and leaves
  `high`/`low`/`open` honestly nil instead of fanning out a second request.
- *Verification:* the registered live recording carries none of the three
  fields; the divergence is a deliberate single-request carve, not a gap.

<!-- carve-evidence-status
{"carve_id":"C-T593d","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange Get product ticker reference (volume documented without unit)"},"observed_evidence":{"kind":"live_venue","reference":"Registered ETH-USD ticker recording under test/fixtures/responses/coinbaseexchange; base-unit magnitude check"},"compatibility_reference":{"kind":"ccxt","reference":"Frozen reference maps volume to baseVolume; agreement noted, not authority"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T593e","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Coinbase Exchange Get product ticker reference (no high/low/open on the ticker route)"},"observed_evidence":{"kind":"live_venue","reference":"Registered ETH-USD ticker recording carries no high/low/open fields"},"compatibility_reference":{"kind":"ccxt","reference":"Frozen reference enriches ticker via /products/{id}/stats; deliberately not adopted"},"resolved_tier":1}
-->
