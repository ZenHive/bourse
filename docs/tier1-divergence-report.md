# Tier-1 Divergence Report — reality-anchored semantic oracle (Task 180)

Doctrine anchor: `docs/authored-specs.md` § "The epistemology — provider-owned contract, binary
verification" (successor of the retired "CCXT-tier ceiling" section — the tier-2 machinery is
gone, task 523). This report is the adjudication artifact that doctrine calls for: every
targeted divergence-prone field gets a **reality-anchored expected value** (real captured response
+ a non-CCXT semantic source) and an explicit adjudication — never auto-resolved toward CCXT.

**Independence invariant.** The expected side of each row is derived from (a) a real captured
exchange response (`test/fixtures/responses/`, captured by `mix ccxt.record_fixtures` against the
live production APIs, 2026-07-15) and (b) the exchange's own API documentation — never from CCXT
JS, CCXT static fixtures, or our own `field_maps`. CCXT appears only in the cross-check column.

**Adjudication vocabulary** (per task 180): `replicate` (CCXT is right; we match/should match it),
`diverge` (CCXT is wrong or lossy vs reality; we deliberately do otherwise — registered),
`our-reading-wrong` (our implementation contradicts reality; CCXT may or may not be right).

**Consuming gate:** `test/bourse/tier1_semantic_oracle_test.exs` (offline, default suite). Two
assertion kinds: *tier-1 GREEN* (our parse matches reality — regression guard) and *adjudicated
divergence PIN* (our parse is known-wrong/lossy; the pin freezes the defective state so both a new
regression and the authoring fix fail loudly and force re-adjudication — a pin is never an
endorsement).

Live first-move evidence (2026-07-15): tidewave `project_eval` against deribit/bybit/hyperliquid
testnets (`sandbox: true`) — `Bourse.fetch_markets`, `Bourse.fetch_trades("BTC/USD:BTC")`,
`Bourse.fetch_funding_rate` — surfaced every finding below before any fixture was replayed.

---

## 1. fetchMarkets precision

### 1.1 Precision value semantics are venue-heterogeneous (tick-size vs decimal-places)

| Venue (instrument) | Reality (raw) | Non-CCXT semantic source | Our parsed `Market.precision` | Adjudication |
|---|---|---|---|---|
| deribit BTC-PERPETUAL | `tick_size: 0.5` | docs.deribit.com `public/get_instruments`: tick_size "specifies minimal price change" → a TICK SIZE | `%{"price" => 0.5}` (float) | GREEN (value); semantics untyped — see below |
| bybit BTCUSDT linear | `priceFilter.tickSize: "0.10"`, `lotSizeFilter.qtyStep: "0.001"` | bybit v5 docs/market/instrument: tickSize/qtyStep = "the step to increase/reduce order price/quantity" → TICK SIZES | `%{"price" => 0.1, "amount" => 0.001}` (floats) | GREEN (values) |
| hyperliquid BTC perp | `szDecimals: 5` | hyperliquid.gitbook.io tick-and-lot-size: "sizes are rounded to the szDecimals of that asset" → DECIMAL PLACES | `%{"amount" => 5}` (integer) | GREEN (value) |

**Finding (cross-venue):** the unified `precision` map mixes tick-size **floats** and
decimal-places **integers** with no discriminator. The per-venue `precision_mode` exists in the
authored spec (`Bourse.Spec` distill key, consumed by `Bourse.Order.Sanity.precision_increment/3`) but
is not surfaced on the parsed `%Bourse.Market{}`, so a consumer cannot interpret the value.
**Adjudication: carve-level concern, owned by task 181** (schema confrontation). CCXT cross-check:
CCXT carries the same heterogeneity but types it via the exchange-level `precisionMode` constant —
our schema dropped the discriminator, not Bourse.

### 1.2 Missing precision members

| Venue | Reality provides | Our parse | Adjudication |
|---|---|---|---|
| deribit BTC-PERPETUAL | amount granularity: `min_trade_amount: 10.0`, `contract_size: 10.0` (USD steps) | `precision["amount"]: 10.0`, `limits.amount.min: 10.0` | **GREEN:** `qty_tick_size` wins when present, otherwise `min_trade_amount` supplies the authored fallback. |
| bybit BTCUSDT spot | `lotSizeFilter.basePrecision: "0.000001"` (spot has NO qtyStep; bybit docs: basePrecision = "the precision of base coin", spot-only) | `precision["amount"]` absent — field_map reads only `qtyStep` | **our-reading-wrong** (lossy): spot needs the basePrecision fallback. PINNED. |
| hyperliquid BTC perp | price rule: "prices can have up to 5 significant figures, but no more than MAX_DECIMALS − szDecimals decimal places", MAX_DECIMALS = 6 for perps (gitbook tick-and-lot-size) | `precision["price"]` absent | **our-reading-wrong** (lossy) — though reality's rule (sig-figs + decimals cap) does not fit a single tick-size scalar; the honest carve is a task-181 question. PINNED. CCXT cross-check deferred to 181. |

### 1.3 Market type flags (root cause feeding § 2)

Reality (capture + live testnet, deribit BTC-PERPETUAL): `instrument_type: "reversed"`,
`settlement_period: "perpetual"` (docs.deribit.com get_instruments: instrument_type is "linear" or
"reversed"). The authored parse now yields `inverse: true`, `linear: false`, `swap: true`,
`contract: true`, `type: "swap"`, and clears the year-3000 perpetual expiry sentinel.
**Adjudication: GREEN after Task 170.**

## 2. Inverse-perp `cost` branch — confirmed live defect (our-reading-wrong)

Live evidence (deribit testnet, 2026-07-15, `Bourse.fetch_trades(ex, "BTC/USD:BTC")`): raw trade
`amount: 3160.0`, `price: 64710.0` → our parsed `cost: 204_483_600.0` (amount × price) — a ~$204M
cost for a $3,160 trade. Frozen offline replay (mainnet capture, trade 434762295: amount 10.0,
price 64044.5) pins the same defect: parsed cost 640_445.0 vs reality-anchored
`10.0 / 64044.5 ≈ 1.5614e-4 BTC`.

- **Reality semantic source (non-CCXT):** docs.deribit.com `public/get_last_trades_by_instrument`:
  "Trade amount. For perpetual and inverse futures the amount is in USD units." So for a reversed
  contract the settlement-currency cost is amount / price.
- **CCXT cross-check:** CCXT deribit `parseTrade` branches correctly —
  `cost = market['inverse'] ? stringDiv(amount, price) : stringMul(amount, price)`
  (`priv/specs/json/ccxt/ts/src/deribit.ts:1552-1555`). Reality and CCXT agree.
- **Our defect:** `Bourse.ResponseParser` implements the same `"computed"` rule with `inverse_op`
  (`lib/bourse/response_parser.ex`), but the branch keys on `market.inverse`, which our deribit
  market parse leaves `nil` (§ 1.3) — the linear `mul` always fires.

**Adjudication: GREEN after Task 170.** Not a CCXT divergence — the request symbol now supplies
inverse market context, so the authored `inverse_op: "div"` computes settlement-currency cost.

## 3. Funding cadence / interval

| Venue | Reality | Non-CCXT semantic source | Our parse | Adjudication |
|---|---|---|---|---|
| bybit BTC/USDT:USDT | tickers carries `fundingIntervalHour: "8"` explicitly (recorded cassette + live testnet 2026-07-17) | bybit v5 docs/market/tickers: "Funding interval hour. This value currently only supports whole hours" — per-symbol, variable (bybit's own blog: symbols moved 8h → 1h) | `FundingRate.interval: "8h"` when payload carries the field (tier-1 GREEN); offline static fixtures that omit the field correctly parse `nil` (CCXT's fixture `"8h"` is markets-cache contamination — response gate B3) | **GREEN** on reality-bearing payloads. Offline T-A does not grade interval (task 290 / B3). |
| deribit BTC-PERPETUAL | Registered testnet history: 12 rows over 12 hours, every adjacent timestamp gap 3,600,000 ms; each row carries `interest_1h` and `interest_8h` | Deribit's provider-owned `public/get_funding_rate_history` reference defines hourly history and labels both rate fields separately | `funding_rate` copies the scalar; `interval: "1h"`; history maps `interest_1h` into typed rows | **DIVERGE from CCXT:** its `"8h"` labels the snapshot query window, not Deribit's hourly publication cadence. C-T535a binds the fallback to the registered history recording. |
| hyperliquid | funding paid hourly | hyperliquid.gitbook.io trading/funding: "The funding rate on Hyperliquid is paid every hour." | `fetch_funding_rate` → `:not_supported` (only plural paths exist) | Deferred: no singular funding read to anchor yet; when authored (170/171/216-class work), the interval carve must say "1h", not CCXT's default. Noted, not pinned. |

## Verification gaps (flagged by the doc research, not filled from memory)

1. Deribit `get_funding_rate_value` aggregation semantics: the API doc types the result only as
   `number`; "rate over the queried window" is inferred from the method description, not an
   explicit statement.
2. Bybit inverse qty/position-value semantics (qty in USD; value ≈ qty/price): sourced via search
   synthesis of bybit's official help-center page (direct fetches timed out). Not load-bearing for
   the current pins (the inverse-cost row is deribit-anchored), but re-verify before extending § 2
   to bybit inverse.
3. Hyperliquid `metaAndAssetCtxs.funding` field's time unit is not explicitly labeled in the doc
   prose (hourly is inferred from the documented hourly interest component).

## Follow-up ownership

- § 1.2 / 1.3 / 2 pins: authoring fixes belong to tasks 170/171 (deribit proof venue) — the pins
  fail loudly when those land, forcing re-adjudication here (flip pins to tier-1 GREEN asserts).
- § 1.1 semantics discriminator + § 3 funding-cadence carve + hyperliquid price-rule shape:
  schema/carve confrontation — task 181. **Resolved 2026-07-15:** adjudicated in
  `docs/authored-specs.md` § "Carve register — schema-level confrontations" — § 1.1 → entry C1
  (surface `precision_mode` per market; field-maps honor the declared mode), § 3 Deribit cadence →
  entry C-T535a (`interval: "1h"` from provider-documented hourly history and observed timestamp
  spacing; the scalar query window is a separate concern), hyperliquid
  price rule → entry C6 (no snapshot scalar; author the rule parameters). Implementation encoded
  as acceptance criteria on tasks 170/171/209.
