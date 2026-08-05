# Bourse — Endpoint Coverage Matrix

What the `trading_dashboard` consumer **expects to work** across its shortlist of
exchanges, with **live-probed** status (not CCXT's self-declared `has` map — which
over-promises: lighter advertises `fetchMarkets: true` but errors live).

- **Scope:** public (uncredentialed) endpoints the consumer needs for v1 (pricing,
  market metadata, fees/leverage/funding for the position sizer).
- **Shortlist:** binance, bybit, lighter, deribit, hyperliquid.
- **Method:** live probes via the consumer's Tidewave node (:4025) against this
  library as a path dep. Last swept **2026-06-23**.
- **Standing gate (Task 188):** `test/bourse/public_api_live_test.exs` —
  `@moduletag :capability_live` per-{venue,method} matrix over this shortlist.
  Run: `mix test.json --quiet --include capability_live test/bourse/public_api_live_test.exs`.
  A cell is green only when that test passes; this doc is the historical sweep,
  not the gate.
- **Companion:** defects found here are logged in `BUGS.md` (newest-first repros).

## Legend

| Mark | Meaning |
|---|---|
| ✅ | Live-probed: returns normalized structs with expected fields populated |
| ⚠️ | Live-probed: returns structs, but some canonical fields empty/malformed |
| ❌ | Live-probed: errors out — no usable data (see root cause) |
| 📣 | `has`-map **claim only**, not yet live-probed (truth may differ — see lighter) |
| — | Exchange does not support this endpoint (`has` = false / nil) |

## Public endpoint coverage

| Endpoint | binance | bybit | lighter | deribit | hyperliquid |
|---|---|---|---|---|---|
| **fetchMarkets** | ⚠️ | ✅ | ✅ | ✅ | ✅ |
| **fetchTicker** | ✅ | ✅ | ✅ | ⚠️ | ✅ |
| **fetchTickers** | 📣 | 📣 | 📣 | 📣 | 📣 |
| **fetchCurrencies** | 📣 | 📣 | 📣 | 📣 | 📣 |
| **fetchFundingRate** | 📣 | ✅ | — | ⚠️ | — |
| **fetchFundingRates** | 📣 | 📣 | 📣 | — | 📣 |
| **fetchLeverageTiers** | 📣 | 📣 | — | — | — |
| **fetchMarketLeverageTiers** | 📣 (emul) | 📣 | — | — | — |
| **fetchTradingFee** | 📣 | 📣 | — | — | 📣 |
| **fetchTradingFees** | 📣 | 📣 | — | 📣 | — |
| **fetchOHLCV** | 📣 | 📣 | 📣 | 📣 | 📣 |
| **fetchOrderBook** | 📣 | 📣 | 📣 | 📣 | 📣 |

Root-cause tags: **req** = request-shape bug (malformed/missing params sent upstream);
**cls** = response classifier misreads an exchange *success* envelope as an error (FIXED for
deribit/lighter by task 186 — both now reach the carve); **carve** = request + classify
succeed, but the response is returned as a raw envelope rather than parsed into unified
structs (markets read-parse, task 171); **sym** = response IS parsed into structs but
`symbol` is not backfilled (the venue's coin field isn't mapped) — distinct from `carve`,
which never reaches struct form (hyperliquid markets: 230 `%Market{}` but every `symbol` nil);
**tkr** = markets carve is green but the *emulated* `fetch_ticker` (via `fetchTickers`) can't
match the requested symbol against the carved index (task 196).

Wave-2 live deltas (2026-06-23, tidewave + recompile, tier-1 real API):
- **bybit fetchTicker ❌ req → ✅** (task 190: `category` injected pre-denormalization via
  `apply_premarket`; live `%Ticker{}` returned).
- **bybit/deribit/lighter fetchMarkets ❌ → ⚠️ carve** (187 dropped the credential gate, 186
  fixed the classifier, 190 fixed bybit's `category` request) — requests now succeed and
  return real data, but as **raw envelopes**, not `[%Market{}]`. Keystone next: **task 171**
  (markets carve + bybit multi-category merge — `category:"spot"` only returns spot today).
- **bybit fetchFundingRate (emulated) ❌ carve** — past the auth gate (187), now blocked on
  the missing markets index → "Unknown market symbol" (downstream of 171; task **192**).
- **deribit fetchFundingRate ❌ req** — request rejected `-32602 "start_timestamp value
  required"`; deribit funding-rate request-shape gap (parser slot itself wired by 189).

Wave-3 live deltas (2026-06-23, tidewave + recompile, tier-1 real API):
- **hyperliquid fetchMarkets ❌ req → ⚠️ sym** (task 191: `/info` POST body authored) — request
  now succeeds, returns **230 `%Market{}` structs**, but every `symbol` is nil: the carve
  doesn't map hyperliquid's `name` coin field to a symbol. New `sym` root cause (above).
- **hyperliquid fetchTicker ❌ req → ❌ sym** — body fixed by 191; now fails downstream at
  `"could not find a ticker for BTC/USDC:USDC"` because the markets index has nil symbols.
  Unblocks when the markets symbol backfill lands (folded into the markets-carve task).
- **deribit fetchFundingRate ❌ req → ⚠️** (task 193: `start_timestamp`/`end_timestamp` 8h
  window authored) — live `%FundingRate{funding_rate: …}` returned, tier-1 verified. `⚠️`
  not `✅` because deribit's `get_funding_rate_value` returns a bare scalar, so
  timestamp/mark_price/next_funding are inherently nil (endpoint shape, not a parse gap).
  Static fixture-replay determinism for this dynamic request shape is a follow-up (task 194).

Wave-4 live deltas (2026-06-24, tidewave + recompile, tier-1 real API):
- **bybit/deribit/lighter/hyperliquid fetchMarkets ⚠️ → ✅** (task 195: envelope unwrap for
  bybit `result.list` / deribit `result` / lighter `order_book_details`, bybit category-merge,
  hyperliquid `name`→symbol backfill) — all four now return **symbol-populated `[%Market{}]`,
  zero nil symbols**, tier-1 verified: bybit 1134 (incl. linear `BTC/USDT:USDT`), deribit 4688,
  lighter 206, hyperliquid 230. This is the keystone consumer unblock.
- **bybit fetchFundingRate ❌ carve (emul) → ✅** (task 192: emulated path resolves the contract
  symbol against the carved index) — `%FundingRate{funding_rate: 3.055e-5}` for `BTC/USDT:USDT`,
  `"Method supports contract markets only"` gone. Tier-1 verified.
- **hyperliquid fetchTicker ❌ sym → ❌ tkr** — 195 populated the markets symbols, surfacing the
  next layer: the emulated `fetch_ticker` still can't find `BTC/USDC:USDC` in the carved index
  (`"fetchTickers() could not find a ticker"`). Now task **196** (emulated-ticker resolution).

Wave-5 live deltas (2026-06-24, tidewave + recompile, tier-1 real API):
- **hyperliquid fetchTicker ❌ tkr → ✅** (task 196: emulated `fetch_ticker` indexes the carved
  markets) — `%Ticker{last: 62650.0, symbol: "BTC/USDC:USDC"}`, tier-1 verified.
- **lighter fetchTicker ❌ ? → ❌ req** (confirmed, no longer low-confidence) — probed with the
  *correct* carved symbol `BTC/USDC:USDC`; still `20001 "invalid param"` HTTP 400. Distinct from
  196's emulated-resolution class: a genuine lighter request-shape bug. Now task **197**.

Wave-6 live deltas (2026-07-14, real API, no creds, worktree recompile):
- **lighter fetchTicker ❌ req → ✅** (task 197: `market_id` authored as dynamic_construction
  from `market.id` after `fetch_markets`, matching CCXT JS) — live
  `%Ticker{symbol: "BTC/USDC:USDC", last: ...}`; unknown symbol → precise `:bad_symbol`.

## Live-probe detail (2026-06-23)

### fetchMarkets

| Exchange | Result | Detail |
|---|---|---|
| binance | ⚠️ partial | 5960 structs, `info` ✅ — but **2670/5960 symbols malformed** (trailing `/`), and `precision`/`limits`/`maker`/`taker`/type-flags empty on sample. Tasks 167 (symbols), 177/180/181 (precision/limits/flags). |
| bybit | ❌ req | `bad_request` 10001 *"Illegal category"* — v5 needs a `category` param the unified layer doesn't inject. Cross-endpoint (also breaks fetchTicker). Tasks 171/183. |
| lighter | ❌ cls | Exchange returns success (`code: 200`, `order_book_details[]`), classifier flags `:exchange_error`. Data all present in `.raw`. See `BUGS.md` 2026-06-23. |
| deribit | ❌ cls | Valid JSON-RPC success (`result` holds **4636 markets**), classifier flags `:exchange_error` and extracts nothing. See `BUGS.md` 2026-06-23. |
| hyperliquid | ❌ req | HTTP 400 *"Failed to parse the request body as JSON"* — malformed/empty POST body for the info endpoint. Cross-endpoint. See `BUGS.md` 2026-06-23. |

### fetchTicker

| Exchange | Result | Detail |
|---|---|---|
| binance | ✅ | `last`/`symbol`/`base_volume`/`quote_volume`/`datetime`/`info` all populated (base_volume fixed by Task 171). |
| deribit | ⚠️ | All populated **except `base_volume`** (nil). Otherwise usable. |
| bybit | ❌ req | `bad_request` 10001 *"Illegal category"* (same root cause as fetchMarkets). |
| hyperliquid | ❌ req | `exchange_error` *"Failed to deserialize the JSON body"* (same request-body root cause as fetchMarkets). |
| lighter | ✅ | Task 197: numeric `market_id` from markets; live `%Ticker{symbol, last}` for `BTC/USDC:USDC`. |

## Consumer impact summary

- **binance** is the only shortlist exchange with a working public path today (ticker ✅,
  markets ⚠️ but structurally present). Tasks 22/23/24 still blocked on binance markets'
  empty precision/limits/fees.
- **lighter / deribit / hyperliquid** cannot be onboarded at all until `fetchMarkets`
  stops erroring — and lighter/hyperliquid have **no** `fetchTradingFee`/`fetchLeverageTiers`
  fallback endpoints, so `fetchMarkets` is their *only* source for fees/MMR/leverage.
- **bybit** is one fix (`category` injection) away from both endpoints working.

## What's still claimed-not-verified (📣)

`fetchTickers`, `fetchCurrencies`, funding, leverage-tier, trading-fee, OHLCV, and
order-book rows above are CCXT `has`-map claims, **not** live-probed. Given the
markets/ticker gap between claim and reality, treat 📣 as unverified until probed.
Re-run the sweep (extend the Tidewave probe in this doc's method) before depending
on any 📣 endpoint.
