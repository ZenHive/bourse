# Alpaca carve register

Append-only schema confrontations for Alpaca. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for Alpaca's authored primary-market data slices.** This file is the complete carve
record for those partial-exception slices; it does not claim first-class venue status or equity
trading coverage.

> **Verification status — SUPERSEDED 2026-07-20; see the closure note at the end of this file.**
> The banner below is the state as of the authoring review and is retained for provenance.
>
> > **Verification status (reviewer, 2026-07-19).** Every carve below is confronted against
> > Alpaca's own published API reference — a non-CCXT semantic source, which is the correct
> > authority here because CCXT's alpaca is crypto-only and offers no fixture oracle for this
> > surface. **None of them is live-verified:** no `ALPACA_API_KEY`/`ALPACA_API_SECRET` is
> > provisioned in any environment this repo has run in, so no 200 response was ever observed and
> > no real success payload is frozen. The only live evidence captured is the **401 rejection**
> > (real recorded nginx HTML body, pinned in `alpaca_authored_slice_test.exs`). These carves are
> > therefore **documentation-anchored, not tier 1** — they claim shape correctness against the
> > docs, never that the venue was observed agreeing. Open item:
> > `docs/prod-verification-ledger.md` § alpaca.

**C-T428a — Stock symbols select Alpaca's stocks data endpoints without a slash (task 428). Outcome: DIVERGE from CCXT; documentation-anchored, live-unverified.**

- *Exchange semantics (non-CCXT):* Alpaca's stock bars and snapshot paths take a US-equity ticker
  directly (`/v2/stocks/{symbol}/...`), such as `GLD`; they do not use a base/quote pair.
- *CCXT's carve:* Alpaca's vendored CCXT surface is crypto-only and treats unified public symbols
  as slash-separated crypto pairs.
- *Our carve + rationale:* a unified symbol without `/` selects the authored stock endpoint, while
  a slash-separated symbol continues to select the existing crypto endpoint. This retains crypto
  compatibility and permits the primary-market ticker vocabulary Alpaca documents.
- *Verification:* documentation-anchored. Path shape confirmed against Alpaca's bars and snapshot
  reference (`/v2/stocks/{symbol}/bars`, `/v2/stocks/{symbol}/snapshot`). The tagged live probe
  requests `GLD` but has never run — no credentials. Ledger: § alpaca.

**C-T428b — Authored stock reads request Alpaca's `iex` feed by default (task 428). Outcome: DIVERGE from implicit feed selection; documentation-anchored, live-unverified.**

- *Exchange semantics (non-CCXT):* Alpaca documents `feed` as an optional stock-data parameter;
  the free market-data entitlement supplies IEX data, while SIP access depends on subscription.
- *Our carve + rationale:* the authored stock bars and snapshot request shapes set `feed=iex` unless
  the caller supplies a feed. This makes free-paper credentials deterministic and avoids silently
  requesting an unavailable SIP feed.
- *Verification:* documentation-anchored. `feed` values (`iex`, `sip`, `delayed_sip`, `otc`,
  `boats`, `overnight`) and the free-tier IEX default are confirmed against Alpaca's market-data
  reference. The live success probe asserting a `GLD` bar under that feed has never run — no
  credentials. Ledger: § alpaca.

**C-T428c — Stock OHLCV preserves Alpaca's market-session bars rather than inventing 24/7 crypto sessions (task 428). Outcome: DIVERGE from crypto assumptions; documentation-anchored, live-unverified.**

- *Exchange semantics (non-CCXT):* Alpaca's stock bars are historical market-data bars for the
  requested stock and timeframe; they reflect the selected feed and exchange trading session.
- *Our carve + rationale:* `fetch_ohlcv("GLD", "1d")` maps the response's `t/o/h/l/c/v` rows
  directly to unified OHLCV. No synthetic day, continuous-session, or slash-pair normalization is
  applied.
- *Verification:* documentation-anchored. Alpaca's reference confirms `timeframe=1D` is an accepted
  abbreviation for `1Day`, and that a single-symbol bars response is `{"bars": [...], "symbol",
  "currency", "next_page_token"}` with `t` as an RFC-3339 string (hence the ISO→epoch-ms coercion in
  `coerce_ohlcv_row/1`). The offline pin uses a doc-shaped, *illustrative-valued* payload — not a
  recording. Ledger: § alpaca.

**C-T428d — Alpaca publishes no quote-denominated volume; unified `quoteVolume` stays nil (task 428, reviewer). Outcome: CONFIRMED absent; documentation-anchored.**

- *Exchange semantics (non-CCXT):* Alpaca's bar object fields are `t/o/h/l/c/v/n/vw`. `v` is share
  volume (base) and `n` is the **trade count** — the number of trades in the bar. Alpaca documents
  no quote-currency volume on bars or snapshots.
- *What was authored first:* the initial slice mapped `quoteVolume <- dailyBar.n`, which reports a
  trade count as a currency amount — a wrong number that every offline assertion would have
  ratified, since the pin was written from the same mistaken reading.
- *Our carve + rationale:* `quoteVolume` is left unset. `baseVolume <- dailyBar.v` and
  `vwap <- dailyBar.vw` are retained; a consumer wanting notional can compute `v * vw` itself
  rather than have us synthesize a field the venue never sent.
- *Verification:* documentation-anchored; pinned by an explicit `is_nil(ticker.quote_volume)`
  assertion so a future re-mapping has to argue with a test.

---

**Closure note — the live-unverified banner above is superseded (2026-07-20, audit).**

The 2026-07-19 reviewer banner and every `*Verification:* documentation-anchored … has never run
— no credentials` line below it were accurate when written. They are no longer. The operator
provisioned paper-account keys in `~/.secrets` on 2026-07-20 and the ledger entry closed the same
day (`docs/prod-verification-ledger.md` § "alpaca — authored stocks slice live-verified (task 428,
C-T428a/b/c/d; closed 2026-07-20)"). The per-carve `*Verification:*` lines are left unedited per
the append-only rule; read them through this note.

What the venue was actually observed doing:

- `mix test.json --include integration --include network test/bourse/alpaca_authored_integration_test.exs`
  → 3/3 green against `data.alpaca.markets`. `fetch_ohlcv("GLD", "1d")` and `fetch_ticker("GLD")`
  return populated unified structs from real 200s — so **C-T428a** (slash-less symbol selects the
  stocks endpoint) and **C-T428c** (`1D` timeframe, RFC-3339 `t` → epoch ms) are observed agreeing,
  not merely doc-shaped. `feed=iex` is accepted on a free paper key (**C-T428b**).
- The observed 200 bodies (bars + snapshot, `GLD`, `feed=iex`) replaced the illustrative-valued
  payloads in `alpaca_authored_slice_test.exs` — the freeze the open ledger item called for.
- Two reality-driven amendments, both honest reality rather than weakened assertions: a
  present-but-null `bars` key is an **empty window**, not a shape error (fixed in
  `read_parse.ex` `ohlcv_rows/2` + `null_at_path?/2`, pinned offline with the real null-bars body);
  and paper accounts carry **no FX entitlement** — `v1beta1/forex/latest/rates` answers HTTP 403
  `{"message": "not authorized for FX data"}`, so the forex-rate domain fields stay doc-shape-only
  with no reachable oracle on a free paper plan.

**C-T428d** (`quoteVolume` stays nil; `n` is a trade count, not a notional) remains
documentation-anchored by construction — it is a claim about a field the venue never sends, which
no live 200 can confirm or refute beyond its continued absence.

## Evidence status supersessions

These dated records are append-only. The consistency gate treats the newest record for a carve
as authoritative over earlier prose.

<!-- carve-evidence-status
{"carve_id":"C-T428a","date":"2026-07-20","semantic_source":{"kind":"provider_owned","reference":"Alpaca Market Data bars and snapshots API reference cited in C-T428a"},"observed_evidence":{"kind":"live_venue","reference":"3/3 Alpaca authored integration tests green against data.alpaca.markets; recorded GLD 200 bodies frozen in alpaca_authored_slice_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T428b","date":"2026-07-20","semantic_source":{"kind":"provider_owned","reference":"Alpaca Market Data feed parameter reference cited in C-T428b"},"observed_evidence":{"kind":"live_venue","reference":"data.alpaca.markets accepted feed=iex with a free paper key; recorded GLD 200 bodies frozen in alpaca_authored_slice_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T428c","date":"2026-07-20","semantic_source":{"kind":"provider_owned","reference":"Alpaca Market Data bar schema and timeframe reference cited in C-T428c"},"observed_evidence":{"kind":"recorded_venue","reference":"Recorded GLD 200 bars preserve 1D session rows and RFC-3339 timestamps; live integration returned populated OHLCV"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T428d","date":"2026-07-20","semantic_source":{"kind":"provider_owned","reference":"Alpaca bar schema defines n as trade count and publishes no quote-volume field"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"A live response can show continued field absence but cannot establish the semantic meaning of a field the venue never sends"}
-->

## Complete venue promotion (task 429)

**Canonical for this venue.** This section supersedes the partial-exception scope above: Alpaca's
owned runtime document now covers its primary-market data and paper-trading contract together.
The task 428 entries remain the append-only history of the market-data slice.

**C-T429a — Alpaca is one owned venue with an exhaustive capability inventory (task 429). Outcome: DIVERGE from CCXT's crypto-oriented Alpaca scope.**

- *Exchange semantics:* Alpaca exposes US-equity market data and a paper Trading API under its
  official data and paper hosts. Options trading and Broker account provisioning are separate
  product surfaces and are not part of this client contract.
- *CCXT reference:* the frozen CCXT Alpaca document remains useful as a method-name inventory and
  compatibility reference, but its crypto orientation does not define Alpaca's equity semantics.
- *Our carve:* the runtime loads one schema-v2 owned document with no base/overlay merge. All 118
  inventoried unified methods are booleans: twelve supported methods cover stock data, assets,
  account, positions, orders, clock, and the paper order lifecycle; the other 106 are explicitly
  false. `option`, `fetchOption`, and `fetchOptionChain` are named false, and Broker API routes and
  hosts are absent.
- *Verification:* the generic venue-promotion gate reconciles the exact reference inventory and
  requires this carve, the Alpaca authority manifest, tagged integration tests, and paper-trading
  evidence before setting the owned markers.

**C-T429b — Alpaca account values remain equity-account values (task 429). Outcome: DIVERGE from crypto wallet buckets.**

- *Exchange semantics:* Alpaca's account resource reports `cash`, `initial_margin`, `equity`,
  `buying_power`, trading-block flags, and `shorting_enabled` in the account currency.
- *Our carve:* unified balance indexes the account currency (`USD`) and maps cash to `free`,
  initial margin to `used`, and equity to `total`; the complete raw account remains in `info`.
  Buying power is not relabelled as a token balance, and unsettled equity proceeds are not
  invented as a separate crypto wallet.
- *Verification:* the paper API returned an ACTIVE USD account with numeric cash, equity, initial
  margin, and buying power on 2026-07-23; the tagged integration and provider-shaped offline pin
  assert the mapping.

**C-T429c — Positions, fractional shares, and short-borrow state keep Alpaca's equity vocabulary (task 429). Outcome: DIVERGE from derivative-contract defaults.**

- *Exchange semantics:* positions report signed share `qty`, `market_value`, `avg_entry_price`,
  `current_price`, and unrealized P/L. Alpaca assets separately publish `fractionable`, minimum
  order/trade increments, `shortable`, `easy_to_borrow`, and `borrow_status`; a locate-required
  state is therefore venue data, not something inferred from a crypto margin flag.
- *Our carve:* absolute share quantity maps to `contracts`, direction stays `long`/`short`, and
  the raw asset row preserves fractionability and borrow/locate state in `Market.info`. A
  `us_equity` asset is represented as spot equity quoted in USD with `option: false`.
- *Verification:* the paper API returned GLD as active/tradable/fractionable and exposed its
  short/borrow fields on 2026-07-23. Alpaca's official fractional-trading and margin/short-selling
  guides define the meaning; offline pins cover a fractional short-position row.

**C-T429d — Orders are paper-only and preserve Alpaca's request, state, and rejection semantics (task 429). Outcome: CONFIRMED provider contract.**

- *Exchange semantics:* Alpaca accepts paper orders at `paper-api.alpaca.markets`, returns the
  order resource from create/fetch, acknowledges a successful cancel with HTTP 204 and no body,
  and rejects a request without `qty` or `notional` with HTTP 422 code `40010001`.
- *Our carve:* `createOrder` maps amount to `qty`, limit price to `limit_price`, defaults DAY and
  `extended_hours=false`, and parses Alpaca status names into the unified order state. A 204 cancel
  becomes a canceled order acknowledgement carrying the requested id. Integration refuses to
  trade unless `sandbox: true` resolves the exact paper hostname, uses a GLD buy limit at $1.00,
  and always attempts cleanup.
- *Verification:* a far-from-market GLD order was created, fetched in `accepted` state, and
  canceled on the paper API on 2026-07-23. The relevant invalid request produced the documented
  422/code/message tuple; tagged integration and offline request-capture tests pin both paths.

**C-T429e — Clock, calendar, and settlement follow US-equity sessions (task 429). Outcome: DIVERGE from 24/7 and instant-settlement assumptions.**

- *Exchange semantics:* Alpaca's clock reports current open state plus the next session open and
  close; its calendar reports each trade date's market hours and `settlement_date`. The observed
  2026-07-22 session opened 09:30, closed 16:00, and settled 2026-07-23, matching T+1.
- *Our carve:* the raw clock/calendar routes are retained as equity-domain evidence and
  `fetchTime` uses the clock timestamp. No continuous 24/7 session or instant token settlement is
  inferred from the unified spot label.
- *Verification:* official calendar/clock semantics were confronted with the live paper API on
  2026-07-23; the tagged integration pins that dated session and its settlement date.

**C-T429f — Equity fees and order defaults do not inherit Alpaca's crypto market model (task 429). Outcome: DIVERGE from CCXT's crypto-oriented metadata.**

- *Exchange semantics:* Alpaca documents stock trading as commission-free while applying separate
  sell-side regulatory fees such as TAF and CAT. Those fees are neither maker/taker commissions nor
  a volume tier. Equity orders use DAY semantics for the fractional-share surface exercised here.
- *Our carve:* maker/taker commission metadata is zero and non-tiered, the fee documentation points
  to Alpaca's regulatory-fee page, and the order default is `day`. Crypto exchange-code defaults and
  the crypto fee schedule are absent. The unified fee fields do not attempt to synthesize dynamic
  regulatory charges.
- *Verification:* provider-owned regulatory-fee and fractional-trading documentation establishes
  the meaning; the owned-spec test pins the absence of the inherited crypto defaults.

<!-- carve-evidence-status
{"carve_id":"C-T429a","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Alpaca Trading API and Market Data product boundaries; priv/authority/alpaca/manifest.json"},"observed_evidence":{"kind":"live_venue","reference":"Live data.alpaca.markets reads and paper-api.alpaca.markets account/order lifecycle observed 2026-07-23"},"compatibility_reference":{"kind":"ccxt","reference":"Frozen Alpaca reference supplies the reconciled 118-method inventory only"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T429b","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Alpaca Working with Account and Trading API account reference"},"observed_evidence":{"kind":"live_venue","reference":"Paper GET /v2/account returned USD cash, initial_margin, equity, buying_power, status, and shorting_enabled on 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T429c","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Alpaca positions, fractional-trading, margin/short-selling, and borrow-status documentation"},"observed_evidence":{"kind":"live_venue","reference":"Paper GET /v2/positions and GET /v2/assets/GLD observed position shape plus fractionable, shortable, easy_to_borrow, and borrow_status fields on 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T429d","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Alpaca create/get/cancel order API references pinned by priv/authority/alpaca/manifest.json"},"observed_evidence":{"kind":"live_venue","reference":"Paper GLD $1 DAY limit create/fetch/cancel succeeded and missing-qty request returned HTTP 422 code 40010001 on 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T429e","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Alpaca market clock and calendar API references"},"observed_evidence":{"kind":"live_venue","reference":"Paper clock plus 2026-07-22 calendar row observed 09:30-16:00 with settlement_date 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T429f","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Alpaca Regulatory Fees and Fractional Trading documentation"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"Frozen Alpaca reference crypto maker/taker tiers and exchange-code defaults deliberately rejected"},"resolved_tier":2,"known_gap_reason":"Commission and regulatory-fee semantics are provider-documented policy; no fee-producing live trade is permitted by task scope"}
-->

## 2026-07-26 — public market-symbol round trip (Task 525)

**C-T525a — Alpaca crypto reads author the location and plural symbol query at the endpoint
boundary (task 525). Outcome: CONFIRMED provider contract.**

- *Exchange semantics:* Alpaca's crypto snapshots and bars references define
  `/v1beta3/crypto/{loc}/...`, require a supported location such as `us`, and accept the
  comma-separated query parameter `symbols`; neither endpoint accepts the unified singular
  `symbol` name on the wire.
- *Live observation:* `fetch_ticker("BTC/USD")` first failed locally with the unresolved `{loc}`
  path, then reached Alpaca but returned HTTP 400 when only `symbol` was sent. After authoring the
  two bindings, the snapshots and bars requests reached `data.alpaca.markets` as
  `/crypto/us/...?...symbols=BTC%2FUSD` and both returned HTTP 200 on 2026-07-26.
- *Our carve:* the crypto endpoint overrides supply the provider's `us` path default and rename
  the unified symbol into `symbols`. Stock reads retain their separate slashless-symbol paths and
  `feed=iex` defaults.
- *Verification:* the accepted-request goldens retain the live HTTP 200 request URLs while their
  replay inputs now contain only the ordinary unified `symbol` and `timeframe` arguments. The
  ten-venue live smoke separately round-trips Alpaca's own `GLD` market into `fetch_ticker`.

<!-- carve-evidence-status
{"carve_id":"C-T525a","date":"2026-07-26","semantic_source":{"kind":"provider_owned","reference":"priv/authority/alpaca/manifest.json artifacts crypto-snapshots and crypto-bars"},"observed_evidence":{"kind":"live_venue","reference":"Alpaca crypto snapshots and bars returned HTTP 200 with authored loc=us and symbols=BTC/USD; accepted-request goldens pin both URLs"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-03 — stock OHLCV window and pagination request shape (Task 532)

**C-T532 — Alpaca stock OHLCV uses an explicit unified window and provider-native pagination
parameters (task 532). Outcome: DIVERGE from Alpaca's current-day default; no CCXT carve is
adopted.**

- *Exchange semantics:* Alpaca's single-stock bars reference defines `timeframe` as required,
  `start` and `end` as inclusive RFC-3339 or `YYYY-MM-DD` bounds, and `limit` as a 1–10,000 page
  bound whose provider default is 1,000. When `start` is absent, Alpaca starts at the beginning of
  the current day; a daily-bar request can therefore return `bars: null` before a completed bar
  exists.
- *Live observation:* on 2026-08-03, `GLD` with no start returned HTTP 200 and no bars, while the
  same endpoint with a 60-day start returned populated daily candles. Unified `since` leaked as
  an unknown query parameter and returned HTTP 400. An inverted provider window returned HTTP 400
  with `end should not be before start`.
- *Our carve:* the stock endpoint maps unified millisecond `since`/`until` to RFC-3339
  `start`/`end`, carries `limit`, and removes the unified names from the wire. A window-less
  unified call supplies a 60-day lookback instead of inheriting Alpaca's current-day default, so
  `fetch_ohlcv/3` has a useful daily-bar call shape. Caller-supplied native `start` remains
  authoritative for compatibility with the previously documented escape hatch. The crypto bars
  endpoint is unchanged.
- *Verification:* tagged live tests assert a non-empty 60-day `GLD` result, a three-candle limit,
  the non-empty window-less call, and the exact inverted-window error. Offline request capture
  pins the RFC-3339 start/end names and values and confirms that `since`/`until` never reach
  Alpaca. Candle rows remain `[timestamp, open, high, low, close, volume]`.

<!-- carve-evidence-status
{"carve_id":"C-T532","date":"2026-08-03","semantic_source":{"kind":"provider_owned","reference":"priv/authority/alpaca/manifest.json artifact stock-bars-single; Alpaca historical bars (single symbol) API reference"},"observed_evidence":{"kind":"live_venue","reference":"Live data.alpaca.markets GLD probes on 2026-08-03 observed populated 60-day bars, limit behavior, empty current-day default, and HTTP 400 end-before-start rejection; tagged integration test pins the outcomes"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-04 — clock timestamp normalization (Task 539)

**C-T539c — `fetchTime` converts the clock's RFC-3339 timestamp to Unix milliseconds (task 539).
Outcome: CONFIRM venue.**

- *Exchange semantics:* the paper clock response supplies `timestamp` as a fractional RFC-3339
  string with an explicit offset.
- *Our carve:* parse the complete instant and return Unix milliseconds. Reading only the leading
  digits as an integer incorrectly returned the calendar year.
- *Live evidence:* the manifest-registered paper-api response records
  `2026-08-03T20:00:44.612184992-04:00`; offline replay returns `1785801644612`.

<!-- carve-evidence-status
{"carve_id":"C-T539c","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"priv/authority/alpaca/manifest.json market-clock API reference"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/alpaca/fetch_time.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-10 — symbols are exempt from unified-symbol backfill (Task 571)

**C-T571b — Every non-empty Alpaca symbol is already the unified form, so the
class-wide native-symbol backfill exempts the venue (task 571). Outcome: CONFIRM
venue; documentation-anchored.**

- *Provider contract:* Alpaca identifies equities by bare ticker (`GLD`) and
  crypto pairs with the slash already present (`BTC/USD`) — there is no separate
  venue-native compact form to normalize from.
- *Our carve:* `unified_symbol?/2` treats any non-empty symbol as unified for
  `%Exchange{id: "alpaca"}`, keeping slash-less stock tickers out of the
  derivatives-style symbol grammar. Consistent with C-T428a (stock symbols
  select the stocks data endpoints without a slash).

<!-- carve-evidence-status
{"carve_id":"C-T571b","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"priv/authority/alpaca/manifest.json asset/data API references — bare-ticker equity symbols, slashed crypto pairs"},"observed_evidence":{"kind":"recorded_venue","reference":"C-T428a live GLD probes 2026-08-03 (bare ticker accepted on stocks endpoints); no compact native form exists to backfill"},"compatibility_reference":null,"resolved_tier":1}
-->

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

**C-T547b — `fetchTrades` reads public stock prints from `GET /v2/stocks/{symbol}/trades` (task 547). Outcome: DIVERGE from a 24/7 tape; CONFIRM venue fields.**

- *Exchange semantics:* Market Data historical trades return `{trades: [...], symbol, next_page_token}` with `t/i/x/p/s/c/z`. There is no buy/sell side. A missing `start` defaults to the beginning of the current day; outside regular hours that answers `trades: null`. Free paper keys take `feed=iex` (C-T428b).
- *Our carve:* slash-less symbols select the single-stock path on `data.alpaca.markets`, default `feed=iex`, map `since`/`until` to RFC-3339 `start`/`end`, and supply a 60-day lookback when `since` is omitted (same empty-window problem as C-T532). Present-but-null `trades` is an empty list. Side and order id stay nil. Cost is `p * s`. Crypto pairs stay out of scope.
- *Live evidence:* data.alpaca.markets returned populated AAPL and GLD IEX prints on 2026-08-18 (`p`, `s`, `t`, `x`). The same endpoint with no window returned `trades: null`.

<!-- carve-evidence-status
{"carve_id":"C-T547b","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"https://docs.alpaca.markets/reference/stocktrades-1 — Market Data historical trades schema"},"observed_evidence":{"kind":"live_venue","reference":"data.alpaca.markets GET /v2/stocks/{symbol}/trades feed=iex populated AAPL/GLD prints and null current-day window 2026-08-18"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T547c — `fetchDeposits`, `fetchWithdrawals`, and `fetchTransfers` stay unsupported (task 547). Outcome: DIVERGE from mapping the wallet endpoints.**

- *Exchange semantics:* Alpaca documents crypto funding wallets at `GET /v2/wallets` and `GET /v2/wallets/transfers` on the paper Trading host. Those are on-chain crypto funding transfers, not equity cash journals. Cash deposits/withdrawals are activity types `CSD`/`CSW`; paper funding on this account is `JNLC`.
- *Live observation:* on 2026-08-18, `GET /v2/wallets` against paper-api.alpaca.markets returned HTTP 404 `{"code": 40410000, "message": "endpoint not found"}`. `GET /v2/wallets/transfers` returned HTTP 404 `Not Found`. `CSD`/`CSW`/`OCT` activity lists were empty; the only activity was a `JNLC` $100000 paper-funding journal.
- *Our carve:* leave the three unified methods `false`. Mapping wallets would claim a surface this paper host does not serve. Mapping `JNLC` as a deposit would relabel paper funding as a customer transfer. The 404s are the provider evidence for the absence.

<!-- carve-evidence-status
{"carve_id":"C-T547c","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"https://docs.alpaca.markets/us/reference/getfundingwallettransfers and Trading API activity types CSD/CSW/OCT/JNLC"},"observed_evidence":{"kind":"live_venue","reference":"paper-api.alpaca.markets GET /v2/wallets 40410000 and GET /v2/wallets/transfers HTTP 404 Not Found 2026-08-18"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-18 — public WebSocket market-data transport (Task 544)

**C-T544a — Alpaca's public market-data stream authenticates with an `action: auth`
key/secret frame before channel subscription (task 544). Outcome: CONFIRM venue.**

- *Exchange semantics:* the provider's streaming-market-data contract publishes the
  `wss://stream.data.alpaca.markets/v2/test` test feed, `FAKEPACA` test symbol,
  key/secret auth frame, and top-level channel subscription shape.
- *Our carve:* `:public` is an authenticated WS section. `watchTrades` builds
  `{"action":"subscribe","trades":[symbol]}`; private trade-update auth and unified
  event normalization are not part of this transport carve.
- *Live evidence:* the provider test feed returned connected, authenticated, and
  subscription envelopes followed by `FAKEPACA` trade frames. A bogus channel returned
  provider error 400 `invalid syntax`.

<!-- carve-evidence-status
{"carve_id":"C-T544a","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"https://docs.alpaca.markets/us/docs/streaming-market-data"},"observed_evidence":{"kind":"live_venue","reference":"test/bourse/ws/canary_test.exs Alpaca test-stream success and invalid-channel probes"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-19 — unified account facts (Task 648)

**C-T648a — Alpaca product access and account margin remain independent provider facts (task 648). Outcome: CONFIRM venue.**

The Trading Account response owns `shorting_enabled` and `multiplier`. The unified
account-facts read preserves those fields as product access and account margin,
respectively; it leaves position margin unavailable because this response reports no
position-level margin mode. The raw account body remains in `info`.

<!-- carve-evidence-status
{"carve_id":"C-T648a","date":"2026-08-19","semantic_source":{"kind":"provider_owned","reference":"Alpaca Trading API GET /v2/account account model (shorting_enabled, multiplier)"},"observed_evidence":{"kind":"live_venue","reference":"test/bourse/account_facts_integration_test.exs Alpaca paper GET /v2/account field pin 2026-08-19"},"compatibility_reference":null,"resolved_tier":1}
-->
