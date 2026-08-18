# Bourse — Bug Reports

The inbound queue for defects consumers of this library hit. File here — this is the only
repository a consumer needs to know. Each entry: the call, observed vs. expected, a repro,
and consumer impact. Newest first.

Triage runs in the private authoring workbench: an open entry becomes a scored task there,
and the entry gets a dated note pointing at it. Entries are never deleted — they are the
reporter's evidence trail.

Entries before 2026-08-05 were filed while the consumers (`trading_dashboard`, `zen_quant`)
and this library shared one repository as path deps; their probes ran via the consumer's
Tidewave node against that path dep. Task ids in those entries refer to the workbench
roadmap.

> **Each entry's `**Status:**` header is the current state.** Where an entry was later
> fixed, the header says so and points at the `> **Update …**` block below it that carries
> the evidence; the original report text is kept verbatim underneath as the repro trail.
> Reconciled 2026-07-25 — before that pass every header still read "🆕 reported" regardless
> of the fix recorded in its own body.
>
> **Authority order when reconciling:** `COVERAGE.md`'s live matrix and the roadmap's landed
> tasks first; the dated sweep banners below are point-in-time snapshots that go stale. The
> 2026-07-25 pass initially mis-marked the lighter entry by trusting the 2026-07-15 banner
> over the matrix — see the Correction on that entry.

> **Consumer rename (2026-07-25).** The consumer previously filed here as `quantex` /
> `Quantex.*` is now **`zen_quant` / `ZenQuant.*`** (pure rename, app `:quantex` →
> `:zen_quant`, no behaviour change). References below were updated so the repros stay
> runnable; commits and task ids from before the rename are unchanged.

> **Re-route (2026-06-23, authored-specs pivot).** The "UPSTREAM distill / resync-gated"
> dispositions below are **retired for first-class venues** (binance, bybit, …). Under the
> pivot a missing/wrong interpretive slice for a first-class venue is an **authoring task**
> here — read the provider contract → author the slice → verify against the reality gate —
> **not** a STOP-and-wait on upstream. The first-class normalization/request-shape defects
> below land via: **171** (author the venue's interpretive slices), **177** (fetchMarkets
> precision/limits/flags oracle), **180** (tier-1 values for divergence-prone fields:
> precision, inverse-perp cost, funding cadence), **181** (carve correctness — diverge from
> CCXT's ontology where reality demands), **183** (stop masking request-malformation 4xx as
> inconclusive). Original evidence below is kept as the consumer's repro trail.

> **Live re-verification sweep (2026-07-15, v0.6.1, `trading_dashboard` Tidewave).** Re-ran
> the filed probes against the current path dep. **Now fixed (return typed structs / succeed
> live):**
> - `fetch_markets` — binance `[%CCXT.Market{}]` (6024, w/ `precision`/`limits`/`type`/`settle`),
>   hyperliquid (232, no HTTP 400), deribit (4813, no `:exchange_error` misclassify).
> - `fetch_ticker` — binance & bybit `%CCXT.Ticker{}` fully populated (`symbol`, `last`,
>   `base_volume`, `quote_volume`, `datetime`, `info`, `vwap`); bybit `category` injected (no
>   "Illegal category").
> - `fetch_order_book` — bybit `category` injected (no "Illegal category").
> - `fetch_funding_rate` (public, no creds) → `%CCXT.FundingRate{}`; `fetch_funding_rates`
>   map-opts → `{:ok, map}` (728, no `FunctionClauseError`; `category` injected).
> - `fetch_trades` — bybit `%CCXT.Trade{}` with `price`/`amount`/`timestamp` populated.
> - `fetch_volatility_history` — deribit `[%CCXT.VolatilityHistory{}]` (384; list-`:params`
>   crash gone).
>
> **Residual (still open):** `fetch_ohlcv` on bybit — the **linear-perp** symbol works
> (`"BTC/USDT:USDT"` → 200 candles), but the **spot** symbol (`"BTC/USDT"`) still errors
> `{:error, "Category is invalid"}` (spot category resolution not wired for `fetch_ohlcv`,
> though it is for ticker/order_book). Candles also return as raw `[ts,o,h,l,c]` arrays — no
> `parse_ohlcvs` collection slice yet (see the parser-gap entry). Not a `trading_dashboard`
> blocker (OHLCV is out of v1 read-only scope).
>
> *Triage note (2026-07-15, orchestrator):* both residuals folded into **task 171**
> (T-D/Bybit authoring) as acceptance criteria — spot category for `fetch_ohlcv` +
> the authored bybit OHLCV parse slice (columnar transformer mechanism exists per task 178).
>
> **Not re-tested:** `fetch_markets` on lighter (entry below) — lighter is WIP upstream;
> left as-is pending the maintainer's lighter update.

---

## 2026-08-12 — `InvalidNonce` classified `:authentication_error` → `retry_class :auth` (non-retryable); nonce/timestamp drift is transient

**Method:** any signed call whose venue error maps through `"InvalidNonce"` (`lib/bourse/error.ex` name map) · **Exchange:** all (classification layer, not venue-specific) · **Severity:** medium (consumer-side terminal handling of a transient error)

**Status (2026-08-13):** ✅ fixed — task 604 shipped `:invalid_nonce` (`retry_class :network`, retryable); live-verified differentially on binance testnet (`recvWindow=1` → `-1021` → `:invalid_nonce`/retryable; bad key → `-2014` → `:authentication_error`/terminal). `:invalid_nonce` also never melts the circuit breaker (client-side drift ≠ venue downtime). **Residual:** the mapped codes are the CEX venues (binance family `-1021`, bybit `10002`, okx `50102`/`60006`); the three DEX venues (lighter, derive, hyperliquid) have no InvalidNonce mapping yet — their nonce/deadline rejections still classify `:authentication_error`. If the consumer trades those venues through this path, report it and the mapping gets confronted per venue.

*(Original triage 2026-08-12: workbench task 604; the lossy collapse was a documented deliberate choice — `error.ex` ~169–171: "AuthenticationError(:auth) wins over the InvalidNonce(:network) edge"; this consumer case showed the money path needs the `:network` side.)*

Observed: `lib/bourse/error.ex` maps `"InvalidNonce" => :authentication_error` (name map, ~line 260),
and `:authentication_error` carries `retry_class: :auth` (~line 186) — "do not retry without
intervention", `should_retry?/1` false. The moduledoc folds it in explicitly: ":authentication_error —
API key/secret rejected **or invalid nonce**".

Expected: nonce/timestamp-window errors are typically transient (client clock skew, concurrent
signers racing a nonce, venue-side recv-window jitter) and succeed on retry after re-sync. CCXT
master deliberately does NOT put InvalidNonce under AuthenticationError: `ts/src/base/errors.ts`
has `InvalidNonce → NetworkError → OperationFailed` (fetched 2026-08-12) — reference taxonomy,
but it reflects practice: retry, don't treat as credential failure.

Consumer impact (how this was found): `trading_dashboard`'s persisted order journal treats
`retry_class :auth` as a DEFINITE rejection (`OrderLifecycle @definite_rejection_classes
[:auth, :non_retryable]`). A transient nonce error while placing a protective stop therefore
marks the order `:rejected` terminal and strands the guarding ladder `:rejected` while the
position is live — a money-path dead-end triggered by a clock-skew blip.

Suggested fix shape: give InvalidNonce its own type (or map it to the network/transient class)
so `retry_class` is retryable; keep genuine credential rejection (`AuthenticationError`,
`PermissionDenied`) as `:auth`. At minimum, split "credentials invalid" from "nonce/timestamp
drift" so consumers can distinguish intervention-required from retry-after-resync.

---

## 2026-08-10 — binanceusdm `cancel_order` on Algo (conditional) orders: successful cancel returns a near-all-nil Order struct

**Method:** `Bourse.cancel_order(ex, algo_id, symbol: "ETH/USDT:USDT")` · **Exchange:** binanceusdm (demo-fapi, sandbox) · **Severity:** low/medium

**Status (2026-08-10):** 📋 triaged — folded into workbench **task 580** (algo-book read/ack parity): the thin `{algoId, code: 200, msg: success}` ack must synthesize at minimum `status: "canceled"`; live-pinned AC added.

Cancelling an Algo (conditional) order succeeds on the wire — raw response
`{"algoId": ..., "code": "200", "msg": "success"}`, and the order is confirmed gone afterwards —
but the returned unified `Bourse.Order` struct is near-all-nil: `status`/`type`/`side`/`amount`/
`trigger_price` all `nil`, only `id`/`symbol`/`info` populated. bourse does not synthesize
`status: "canceled"` from the thin algo-cancel acknowledgement.

Expected: at minimum `status: "canceled"` on the returned struct so callers can branch on the
unified field without reading raw `info`.

---

## 2026-08-10 — binanceusdm `set_margin_mode`: `symbol:` as keyword opt crashes deep in the signing layer (DX)

**Method:** `Bourse.set_margin_mode(ex, "isolated", symbol: "ETH/USDT:USDT")` (malformed — symbol is positional arg 3) · **Exchange:** binanceusdm (demo-fapi, sandbox) · **Severity:** low (DX)

**Status (2026-08-18):** ✅ **fixed** by task 587 — the unified boundary refuses non-encodable param values (`:invalid_parameters`) before dispatch; a keyword list in a required positional slot names the positional convention instead of crashing in `HmacRecipe.encode_query_pairs`.

`set_margin_mode/3` takes the symbol as positional arg 3. Passing `symbol: "..."` as a keyword
opt instead crashes deep in `Bourse.Signing.HmacRecipe.encode_query_pairs` with a Jason
tuple-encode error. This is a caller error, but bourse should reject the malformed opts early
with a clear message ("symbol is a positional argument") instead of surfacing a crypto-layer
crash whose stack trace points nowhere near the actual mistake.

---

## 2026-08-10 — binanceusdm conditional (Algo) order: unified `type` comes back `"limit"` for a stop-market order

**Method:** `Bourse.create_order(ex, "ETH/USDT:USDT", "market", "sell", 0.05, trigger_price: 1000)` · **Exchange:** binanceusdm (demo-fapi, sandbox) · **Severity:** low

**Status (2026-08-10):** 📋 triaged — folded into workbench **task 580**: unified `type` on a conditional order must reflect the request that created it (stop/stop_market family), never `"limit"`; AC added alongside the algo-book read parity work.

The order was correctly routed to the Algo API (`algoId` returned, resting conditional, no
market fire) and the unified struct carries `trigger_price: 1000` / `stop_price: 1000` —
but its unified `type` reads `"limit"`. A trigger-price order submitted with type "market"
is a stop-market; callers branching on the unified `type` to distinguish resting limits from
conditionals get the wrong answer and must fall back to `trigger_price != nil` or raw `info`.

Expected: unified `type` reflecting the conditional nature (e.g. the CCXT-style
`"stop_market"` / `"stop"`), consistent with the request that created it.

---

## 2026-08-10 — binanceusdm `fetch_leverage` `:not_supported`, though the leverage is already in the `fetch_margin_mode` payload

**Method:** `Bourse.fetch_leverage(ex, "ETH/USDT:USDT")` · **Exchange:** binanceusdm (demo-fapi, sandbox) · **Severity:** low

**Status (2026-08-10):** ✅ fixed by task 586 — `fetch_leverage` selects the flat symbol's
configured leverage from `GET /fapi/v1/symbolConfig`; the DAPI sibling reads its account-position
configuration.

Before task 586, `fetch_leverage` returned `:not_supported` for binanceusdm. The raw `symbolConfig` response
that bourse's own `fetch_margin_mode` consumes already carries the `leverage` field for the
symbol (observed: `leverage: 3` alongside `marginType: ISOLATED`), and `fetch_positions` only
exposes leverage while a position is open, leaving no unified way to read the configured leverage
of a flat symbol even though the data was on a wire call bourse already made. The consumer's
workaround read `leverage` from `fetch_margin_mode`'s raw info.

Expected: `fetch_leverage` mapped onto the symbolConfig endpoint for binanceusdm.

---

## 2026-08-10 — binance USD-M: `create_order/6` dropped conditional controls and used the retired endpoint

**Status (2026-08-10):** ✅ **fixed** by workbench task 574. Unified `time_in_force`,
`reduce_only`, `trigger_price`, and `stop_loss_price` now reach the signed request; conditional
orders route to `POST /fapi/v1/algoOrder`. A live ETHUSDT stop-limit remained `NEW` with its
requested trigger, `reduceOnly=true`, and `GTC`; it was canceled and the test position closed.
The accepted-request golden pins the complete request, and provider error `-4120` is pinned on
the retired `/fapi/v1/order` route.

**Observed:** a requested stop could be sent as a plain market sell with neither trigger nor
reduce-only protection, opening a position immediately. `time_in_force` also disappeared unless
the caller bypassed the unified option with native `timeInForce` params.

**Consumer impact:** real-money-relevant; an intended protective stop could execute immediately
as an opening market order.

## 2026-08-10 — binance USD-M: `set_margin_mode/3` omitted `symbol`

**Status (2026-08-10):** ✅ **fixed** by workbench task 574. The unified symbol now becomes
`symbol=ETHUSDT`, and margin modes map to the provider values `ISOLATED` / `CROSSED`. Live changes
in both directions returned code 200 and the account was restored to isolated mode. The signed
request is pinned by an accepted-request golden; invalid symbols return provider error `-1121`.

**Observed:** every unified argument variant returned `-1102` because the signed FAPI request
omitted `symbol`, while raw `POST /fapi/v1/marginType` succeeded with the same credentials.

## 2026-08-10 — binance USD-M: `cancel_all_orders/2` used the wrong route and parsed its acknowledgement as an order

**Status (2026-08-10):** ✅ **fixed** by workbench task 574. The generic Binance client now sends
`DELETE /fapi/v1/allOpenOrders?symbol=ETHUSDT`, treats the provider's `code=200` body as a success
acknowledgement, and preserves bad-symbol error `-1121`. Live verification canceled three
resting orders and `fetch_open_orders` returned zero afterward; the signed request has an
accepted-request golden.

**Observed:** the unified call returned an all-nil-order parse error and left three resting FAPI
orders untouched; the equivalent raw symbol-scoped DELETE canceled them.

## 2026-08-10 — binance: `fetch_balance(type: :swap)` selected the Spot Testnet wallet

**Status (2026-08-10):** ✅ **fixed** by workbench task 575. Atom market types now participate in
endpoint selection: `:spot` reaches Spot, `:swap` reaches USD-M FAPI, and `:delivery` reaches
COIN-M DAPI. All three succeeded live with their matching sandbox keys. `:margin` is a named
exclusion because Spot Testnet has no SAPI host. `fetch_balance(type: :swap)` is the documented
canonical generic-client path; its accepted-request golden pins `demo-fapi.binance.com/fapi/v3/account`.

**Observed:** futures keys received a 401 invalid-key response from the Spot host, while Spot
keys returned the Spot asset list. `fetch_swap_balance` was also unsupported, leaving no unified
route to the USD-M wallet.

## 2026-08-07 — binance: `fetch_funding_rate/2` leaves `interval` nil

**Status (2026-08-10):** ✅ **fixed** by workbench task 573. Binance, Binance USD-M, and Binance
COIN-M now join the current premium-index row to the provider's per-symbol funding-info cadence,
using the documented eight-hour default only when no adjusted row exists. OKX derives cadence
from its provider `fundingTime` / `nextFundingTime` pair. Live sandbox calls returned `interval:
"8h"` on all four surfaces; the pre-change Binance result with `interval: nil` was observed first.

> **Update 2026-08-10:** The C5 decisions are registered under task 573 in the four venue carve
> registers. The trading_dashboard history-timestamp workaround is no longer needed for these
> current-rate reads.

**Call:** `Bourse.Exchange.new("binance")` → `Bourse.fetch_funding_rate(client, "BTC/USDT:USDT")`

**Observed:** the returned `%Bourse.FundingRate{}` has `interval: nil` (rate itself is
correct, fraction per 8h period; `mark_price` populated). Hyperliquid's
`fetch_funding_rates/1` fills `interval: "1h"` for the same struct.

**Expected:** `interval: "8h"` — the field exists on the struct precisely so consumers
don't hardcode a venue's funding cadence, and Binance's cadence is knowable (premiumIndex
carries `nextFundingTime`/`lastFundingRate`; the spec knows the venue funds every 8h).
A consumer annualizing `funding_rate` via `interval` silently gets nothing to multiply by
on binance while the same code works on hyperliquid.

**Affected exchange:** binance (USDT-M perps). Not checked: bybit, okx.

**Consumer workaround:** trading_dashboard `Macro.CrossVenue` avoids the current-rate
endpoint entirely and derives cadence from `fetch_funding_rate_history` timestamps.

## 2026-08-05 — `fetch_ticker/2` returns `timestamp: nil` and `datetime: nil` on every bybit ticker — the mapped `time` key lives on the envelope the parser never sees

**Status (2026-08-05):** 📋 triaged — filed as workbench **task 562** ("Per-field maps cannot address
envelope-level keys, so every bybit ticker is unstamped"), open. Symptom and cause independently
re-verified live on 2026-08-05 before filing: unified `fetch_ticker` returned `timestamp: nil` /
`datetime: nil` with `last: 64148.6`, while the same call's raw envelope carried
`time: 1785918546548` and the extracted list element carried only `deliveryTime` /
`nextFundingTime`. The fix is scoped as a parse-path mechanism change (per-field access to
envelope-level keys), not a bybit-specific patch. **Severity:** medium — not a crash and not a
wrong number, but every bybit ticker is unstampable, so a consumer cannot tell a fresh quote from
a stale one or order two tickers in time. **Reporter:** orchestrator session, live probes against
bybit testnet via this repo's Tidewave node (not a path-dep consumer).

**Method:** `Bourse.fetch_ticker/2` · **Exchange:** bybit · **Blast radius:** bybit only —
deribit stamps `timestamp`/`datetime` correctly from the same unified call.

**Call:**

```elixir
{:ok, bb} = Bourse.Exchange.new("bybit", credentials: creds, sandbox: true)
{:ok, t} = Bourse.fetch_ticker(bb, "BTC/USDT:USDT")
{t.timestamp, t.datetime}
# => {nil, nil}          # every other field populated: last, bid, ask, high, low, vwap, …
```

**Observed:** `timestamp` and `datetime` nil on every call. **Expected:** the venue's response
time, which bybit does return.

**Cause:** the authored ticker field map asks for the right key —

```elixir
# priv/specs/json/output/authored/bybit.json → normalization.field_maps.ticker.field_map
"timestamp" => %{"coercion" => "safeInteger", "format" => "ms", "key" => "time"}
```

— but `normalization.response_envelopes.ticker.fetchTicker` extracts `"result.list"`, so the
parser is handed a **list element**, and `time` sits one level up on the **envelope**. Verified
live (`public_get_v5_market_tickers`, category `linear`, symbol `BTCUSDT`):

```elixir
Map.keys(braw.body)            # => ["result", "retCode", "retExtInfo", "retMsg", "time"]
braw.body["time"]              # => 1785887542111
braw.body["result"]["list"] |> hd() |> Map.keys()
                               # no "time" — only "deliveryTime" / "nextFundingTime", both unrelated
```

`datetime` follows `timestamp`, so it is nil for the same reason (`"datetime" => :null` in the
map, derived post-parse).

**The reality evidence for a fix is already committed.**
`test/fixtures/responses/bybit/fetch_ticker.json` (captured 2026-06-20) preserves the whole
envelope — `body.time == 1781993749592`, with the list element again carrying no `time`. So
`mix ccxt.oracle_gate` is green over a recording that *contains* the value the parser cannot
reach, which is the "coverage ratifies the bug" shape CLAUDE.md warns about. A fix is verifiable
against the existing recording; no new capture is needed.

**Suggested fix (reporter's):** the per-field map needs a way to address envelope-level keys.
Note the mechanism already exists next door — `response_envelopes.time.fetchTime` uses
`fallback_keys: ["result.timeNano", "result.timeSecond", "time"]`, reaching the envelope root —
but there is no per-field equivalent, so this is a mechanism change in the parse path rather than
a spec edit. Worth scoping before implementing; a bybit-only special case would be the wrong
shape, since any venue that stamps at the envelope has the same problem.

## 2026-08-05 — `fetch_ticker/2` on derive maps `high`/`low`/`change`/`percentage` from a `stats` object the venue no longer returns — four fields permanently nil

**Status (2026-08-05):** ✅ **fixed** (workbench task 560). The four `stats.*` sources are recorded
as `null` in the authored derive ticker field map, and the absence is registered as carve
**C-T560d** in `docs/authored-spec-carves/derive.md` citing derive's own `public/get_ticker`
reference. Re-verified live before the change on both hosts: `BTC-PERP` returned 36 result keys
with no `stats` member on `api.lyra.finance` and on `api-demo.lyra.finance`, the two key sets
identical. The fields stay nil — that is now the recorded venue characteristic rather than an
unresolvable mapping. **Severity when open:** low-to-medium — no wrong
value is produced (the fields are honestly nil), but the authored map advertises coverage that
cannot resolve on any host, which is misleading to both consumers and future authoring sessions.
**Reporter:** orchestrator session, live probes against derive demo **and mainnet**.

**Method:** `Bourse.fetch_ticker/2` · **Exchange:** derive · **Blast radius:** derive only.

**Call:**

```elixir
{:ok, dv} = Bourse.Exchange.new("derive", credentials: creds, sandbox: true)
{:ok, t} = Bourse.fetch_ticker(dv, "BTC-PERP")
{t.high, t.low, t.change, t.percentage}
# => {nil, nil, nil, nil}     # bid/ask/index_price/mark_price/timestamp all populated
```

**Cause:** the authored ticker map sources those four fields from a nested `stats` object:

```elixir
# priv/specs/json/output/authored/derive.json → normalization.field_maps.ticker.field_map
"high"       => %{"key" => "stats.high",           "coercion" => "safeNumber"}
"low"        => %{"key" => "stats.low",            "coercion" => "safeNumber"}
"change"     => %{"key" => "stats.percent_change", "coercion" => "safeNumber"}
"percentage" => %{"key" => "stats.percent_change", "coercion" => "safeNumber", "scale" => 100}
```

That object does not exist in the response. Three independent checks agree:

| Source | `stats` present? |
|---|---|
| demo `api-demo.lyra.finance` `public/get_ticker` | ❌ — 35 keys, no `stats` |
| **mainnet** `api.lyra.finance` `public/get_ticker` | ❌ — identical 35 keys, no `stats` |
| [official docs](https://docs.derive.xyz/reference/post_public-get-ticker) | ❌ — documented result object is exactly those 35 fields; no `stats`, no 24h-statistics section |

Mainnet and demo returning the *same* key set rules out a demo-only omission. The `stats` shape
appears only in the CCXT-derived descriptor's embedded sample under
`endpoints.descriptors.fetchTicker.source`, whose sample timestamp is `1736140984000` —
**January 2025**. Derive has since removed the field; the carve was inherited from CCXT and never
confronted against the venue's own contract.

**Expected:** either the four fields are sourced from somewhere the venue actually publishes, or
the mappings are dropped and the absence is recorded as a venue characteristic.

**Suggested fix (reporter's):** drop the four `stats.*` entries and add a DIVERGE entry to
`docs/authored-spec-carves/derive.md` citing the docs URL above — this is precisely the
confrontation step the doctrine calls for, on a carve that was adopted rather than confronted.
Small and self-contained.

**Related non-defect, recorded so it is not re-filed:** derive's `last` is also nil, and that is
**correct** — neither the live response nor the official docs carry a last-traded-price field on
this endpoint (the map already has `"last" => :null`). Populating it would mean emulating from
`public/get_trade_history`, which is a design decision, not a repair.

## 2026-08-05 — `Bourse.Testnet` is not supervised, so `register_all_from_env/1` exits in any consumer

**Status (2026-08-05):** ✅ **fixed** (workbench task 561) — by the second of the two options
below, not the first. The registry stays out of `Bourse.Application`'s children: the 0.1.0 reason
holds, and a sandbox-only credential registry does not belong in a consumer's always-on tree.
What changed is the failure mode. Every write (`register/3`, `register_from_env/3`,
`register_all_from_env/1`, `unregister/2`, `clear/0`) now returns `{:error, :not_started}` instead
of exiting the caller, every read (`creds/2`, `creds!/2`, `registered?/2`,
`registered_exchanges/0`, `exchanges_with_creds/0`) raises an `ArgumentError` naming
`Bourse.Testnet.start_link([])` instead of an opaque ETS badarg, and `started?/0` answers the
question directly. Reads deliberately kept their raising behaviour: their `nil` / `false` / `[]`
returns already mean "not registered", and widening them would let an absent registry read as an
empty one. Exit reproduced live via this repo's Tidewave node before the fix
(`{:exited, {:noproc, {GenServer, :call, [Bourse.Testnet, ...]}}}` with `Process.whereis/1` nil).

**Affected:** `Bourse.Testnet` (not exchange-specific)

**Call:**

```elixir
# consumer's test/test_helper.exs, after `mix test` has run `app.start`
Bourse.Testnet.register_all_from_env([
  {:bybit, testnet: true},
  {:binance, testnet: true},
  {:binance, :futures, testnet: true},
  {:deribit, testnet: true}
])
```

**Observed:**

```
** (exit) exited in: GenServer.call(Bourse.Testnet, {:put, {:bybit, :default}, #Bourse.Credentials<...>}, 5000)
    ** (EXIT) no process: the process is not alive or there's no process currently
              associated with the given name, possibly because its application isn't started
    (bourse 0.1.0) lib/bourse/testnet.ex:229: Bourse.Testnet.register_config/1
    (bourse 0.1.0) lib/bourse/testnet.ex:215: anonymous fn/2 in Bourse.Testnet.register_all_from_env/1
    (bourse 0.1.0) lib/bourse/testnet.ex:214: Bourse.Testnet.register_all_from_env/1
```

**Expected:** `register_all_from_env/1` returns per-entry `:ok` / `:skipped` once
`:bourse` is started, without the consumer having to know the registry is a
separate process.

**Cause:** `Bourse.Testnet` is a `GenServer` registered under its own module name
and owning an ETS table (`lib/bourse/testnet.ex:81`), but it is absent from
`Bourse.Application`'s children (`lib/bourse/application.ex:19-24`, which starts
only `Bourse.RateLimiter`, `Bourse.RateLimiter.State`,
`Bourse.Signing.Lighter.Supervisor` and `Broadcast.child_spec()`). Nothing in the
library starts it, so every public `Testnet` function that issues a `GenServer.call`
exits in any consumer that has not hand-started the process.

`Application.ensure_all_started(:bourse)` does **not** help — the app starts fine,
the child simply is not in the tree.

**Impact:** this is not a degraded read; it exits the calling process. In a
consumer's `test_helper.exs` it aborts the *entire* test suite before a single test
runs, which is how it was found (trading_dashboard, 2026-08-05).

**Suggested fix (reporter's):** add `Bourse.Testnet` to `Bourse.Application`'s children. If
the registry is meant to be test-only, the alternative is to document that consumers must
start it themselves and have the `Testnet` client functions return `{:error, :not_started}`
instead of exiting when the process is absent — an exit from a credential-registration
helper is surprising either way.

**Consumer workaround in place:** trading_dashboard's `test/test_helper.exs` starts
the process itself before registering, cross-referenced back to this entry.

## 2026-08-03 — `fetch_ohlcv/3-4` cannot succeed on alpaca at all: silent `{:ok, []}` by default, HTTP 400 when the documented `since` option is used

**Status (2026-08-03):** ✅ **fixed** in `8a413fd1` (task 532, harness run
`run-1785742326556-48d416ee`). The stock-bars request slice now maps unified ms `since`→`start`
and `until`→`end` as RFC-3339, carries `limit`, `_omit`s the unified `since` name from the wire,
and authors a 60-day `default_lookback_ms` so a window-less call issues a real dated window
(DIVERGE carve C-T532 in `docs/authored-spec-carves/alpaca.md`). Re-verified live against the
paper account on 2026-08-03: `fetch_ohlcv/3` → 39 candles, `limit: 5` → 5, `since:` (30d) → 20.
**Severity:** high — a documented
unified read that has **no** working call shape on a supported venue, and whose default path
fails *silently as success*. **Reporter:** orchestrator session (live alpaca paper account,
`sandbox: true`), not a path-dep consumer.

**Method:** `Bourse.fetch_ohlcv/3-4` · **Exchange:** alpaca · **Blast radius:** alpaca only —
binance/bybit/okx/deribit all return candles normally (500/200/100/1000 respectively).

```elixir
{:ok, alp} = Bourse.Exchange.new("alpaca", credentials: creds, sandbox: true)

Bourse.fetch_ohlcv(alp, "GLD", "1d")
# => {:ok, []}                      # silent — indistinguishable from "no data in range"

Bourse.fetch_ohlcv(alp, "GLD", "1d", limit: 30)
# => {:ok, []}                      # limit does not help

Bourse.fetch_ohlcv(alp, "GLD", "1d", since: <60d ago in ms>)
# => {:error, %Bourse.Error{type: :exchange_error, http_status: 400,
#      message: "unexpected query parameter(s): since"}}
```

The unified `since` option — documented on `Bourse.fetch_ohlcv/4` as *"timestamp in ms of the
earliest candle to fetch"* — is forwarded to alpaca **verbatim and unmapped**; alpaca's bars API
names that parameter `start` and rejects unknown query params. So the documented option 400s, and
without it alpaca returns **HTTP 200 with an empty bar set** (it does not error on a missing
window), which the read path faithfully reports as `{:ok, []}`.

**Root cause is the request slice, not the parse layer.** Task 256's fail-loud invariant
("empty collections are success") is behaving *correctly* here — the venue really did return
nothing, because we asked for nothing. The authored alpaca `fetchOHLCV` request slice
(`endpoints.request.defaults.endpoint_overrides.fetchOHLCV`) injects `feed`/`symbol` but maps
neither `since` → `start` nor `limit`.

Proof the venue is fine once the window is supplied — same account, same creds, raw endpoint:

```elixir
Bourse.Alpaca.market_private_get_v2_stocks__symbol__bars(alp,
  %{"symbol" => "GLD", "timeframe" => "1Day", "feed" => "iex"})
# => status 200, bars: 0            # no start → empty, no error

Bourse.Alpaca.market_private_get_v2_stocks__symbol__bars(alp,
  %{"symbol" => "GLD", "timeframe" => "1Day", "feed" => "iex", "start" => "2026-07-01"})
# => status 200, bars: 22           # works
```

**Two non-defects checked and dismissed in the same session** (recorded so they are not
re-reported a fourth time):

- Candles returning raw `[ts, o, h, l, c, v]` arrays is the **documented contract**, not a gap —
  `Bourse.fetch_ohlcv/4`'s generated `## Returns` reads *"A list of candles ordered as timestamp,
  open, high, low, close, volume"*, `Bourse.OHLCV`'s moduledoc says the same, and
  `Unified.FieldMaps` states "OHLCV carries no field map (array shape)". It is CCXT-compatible by
  design; `Bourse.OHLCV.from_list/1` is the opt-in consumer convenience. This supersedes the
  "no `parse_ohlcvs` collection slice yet" remark in the 2026-07-15 sweep banner above.
- Raw endpoints returning `%{status, body, headers}` is also the contract —
  `Bourse.Dispatch.call/4` is specced `{:ok, HTTP.response()}`. Task 380's envelope leak was about
  **unified** methods lacking a parse slice; a raw `public_get_*` call returning the envelope is
  correct behaviour, not a regression.

---

## 2026-07-25 — `fetch_order_book/3` leaks venue-native 3-element levels `[price, size, extra]` on okx — violates `%CCXT.OrderBook{}`'s documented `[price, amount]` contract

**Status (2026-07-25):** ✅ **fixed** — task 514 (`14f46414`), live-confirmed; see the Update block below. Note the triage correction: the reported root cause was wrong (CCXT JS emits 3-element okx levels too), and the real defect was our own contract disagreement plus an inherited carve. **Severity when open:** high (the struct is *documented* as normalized pairs, so every consumer pattern-matches `[price, size]`; okx silently fell through those clauses into neutral/empty results rather than erroring). **Consumer:** zen_quant (path-dep, MM / Orderflow / Execution) — consumer-side hardening shipped separately as zen_quant task 50.

> **Triage note (2026-07-25, orchestrator):** 📋 filed as **task 514**. Symptom confirmed live
> (okx raw row `["64070.7","866.05","0","35"]` = `[price, sz, liquidated_orders, num_orders]`), but
> the reported root cause is **wrong**: CCXT JS `parseBidAsk` defaults `countOrIdKey = 2` and pushes
> a third element when present, and `okx.ts` calls `parseOrderBook` with those defaults — so CCXT JS
> emits 3-element okx levels too. bybit is 2-element only because its rows have no third column
> (`bybit.ts` overrides side keys, not index keys). Our parse is therefore CCXT-compatible; the real
> defects are (a) `%CCXT.OrderBook{}`'s `@doc`/typespec promising pairs while the parser emits up to
> three — a contract disagreement that is ours to resolve, and (b) an **inherited carve**: CCXT's
> index-2 picks okx's *deprecated* always-zero `liquidated_orders` and discards the meaningful
> `num_orders` at index 3, which task 514 confronts against OKX's own v5 docs and registers.
>
> **Update (2026-07-25):** ✅ **fixed** — task 514 landed (`14f46414`, run
> `run-1784943923373-24fd554f`, reviewer-approved). Unified order-book levels are now exact
> `[price, amount]` pairs on every venue; OKX's full four-column rows are preserved verbatim in
> `OrderBook.info` (so `num_orders`, which CCXT discards, is still reachable), and a level in any
> other shape fails loudly with `{:error, {:unexpected_order_book_level, …}}` instead of reaching
> the consumer. The `@doc`, typespec, JSON schema (`maxItems: 2`), `best_bid`/`best_ask`, and
> `assert_level_pair!/2` all agree with the parser now. Registered as a **deliberate divergence**
> from CCXT 4.5.65 (carve C-T514a, tier 1) with `deliberate_divergence: true` baseline entries, so
> a future session cannot "fix" us back toward CCXT by chasing a green fixture. Live-confirmed on
> the landed base 2026-07-25: okx `[64084.1, 994.03]`, all arities `[2]`, `info` row
> `["64084.1","994.03","0","46"]`. zen_quant can drop its level-shape hardening workaround.

**Method:** `CCXT.fetch_order_book(ex, "BTC/USDT:USDT", limit: 5)` · **Exchange:** okx (bybit and binance are correct)

`lib/bourse/order_book.ex` declares the contract explicitly:

```elixir
* `bids` - List of bid levels as `[price, amount]` pairs, highest first
bids: [[number()]],
```

okx returns three-element levels instead:

```elixir
{:ok, okx} = CCXT.exchange(:okx)
{:ok, ob} = CCXT.fetch_order_book(okx, "BTC/USDT:USDT", limit: 5)
List.first(ob.asks)
#=> [64004.4, 351.01, 0.0]        # okx: [price, size, liquidated_orders, num_orders] truncated to 3

{:ok, bybit} = CCXT.exchange(:bybit)
{:ok, ob2} = CCXT.fetch_order_book(bybit, "BTC/USDT:USDT", limit: 5)
List.first(ob2.asks)
#=> [64006.5, 0.727]              # correct pair
```

**Root cause (suspected):** okx's REST book rows are `[price, sz, liquidated_orders, num_orders]`. CCXT JS's `parseOrderBook`/`parseBidsAsks` projects each row down to `[price, amount]` via `parseBidAsk(bidask, priceKey=0, amountKey=1)`; the Elixir parse slice appears to pass the row through (or drop only the last element) instead of projecting to two.

**Expected / Fix:** the `parse_order_book` slice projects every level to exactly `[price, amount]` for all venues, matching both CCXT JS and this struct's own `@doc`. If a venue's extra columns are worth keeping, they belong in `:info`, not in the level tuple.

**Consumer impact (zen_quant, live-probed 2026-07-25):** silent degradation across three modules — the failure is invisible because none of them raise:

| call | okx (3-element) | same book truncated to 2-element |
|---|---|---|
| `ZenQuant.Orderflow.imbalance(book, 5)` | `{:ok, 0.0}` — **a plausible "neutral book" a bot would trade on** | `{:ok, 0.69}` |
| `ZenQuant.Orderflow.heatmap_points(book, 5)` | `{:ok, []}` | 10 points |
| `ZenQuant.Orderflow.dom_level(book, price)` | `FunctionClauseError` | works |
| `ZenQuant.Execution.split_order(:buy, %{quantity: 2.0}, [venue])` | `status: :unfillable`, 0 allocations against a 600+ unit top level | fills |

zen_quant is hardening its own level parsers to reject unknown shapes loudly instead of returning zeros, but the normalization itself belongs here — the struct promises pairs.

## 2026-06-30 — `fetch_trades/2` returns `%CCXT.Trade{}` with `price`/`amount`/`timestamp` nil — core fields stranded in `:info` (bybit)

**Status (2026-06-30):** ✅ **fixed** — verified live in the 2026-07-15 v0.6.1 sweep (see the sweep banner at top): bybit `fetch_trades` returns `%CCXT.Trade{}` with `price`/`amount`/`timestamp` populated. **Severity when open:** medium (parser built the struct but left its defining fields empty — worse than a raw envelope, because the struct *looked* parsed). **Consumer:** zen_quant (path-dep, Orderflow integration suite).

> **Triage note (2026-07-14):** 📋 filed as **task 199** (bybit fetch_trades nil price/amount/timestamp, regression vs 152/178) — generalized: field_map fixed against bybit's actual execution keys + cross-verified on ≥1 other first-class venue; live tier-1 AC included.

**Method:** `CCXT.fetch_trades(ex, symbol)` · **Exchange:** bybit

`fetch_trades` DOES return a parsed `[%CCXT.Trade{}]` list (so a `parse_trade` slice runs), but only `:symbol`, `:side`, `:fee`, `:fees` are populated — `:price`, `:amount`, and `:timestamp` are `nil`:

```elixir
{:ok, bx} = CCXT.exchange(:bybit)
{:ok, [t | _]} = CCXT.fetch_trades(bx, "BTC/USDT:USDT")
{t.price, t.amount, t.timestamp}        # => {nil, nil, nil}
t.info                                  # => %{"price" => "59…", "size" => "0.0…", "time" => 178…, "side" => "Buy", …}
```

**Root cause:** the bybit `parse_trade` slice doesn't map the venue's `price` → `:price`, `size` → `:amount`, `time` → `:timestamp`. (Contrast the parser-gap entry below, which tracks *absent* parsers; here the parser exists but under-populates.) **Expected:** `%CCXT.Trade{price:, amount:, timestamp:}` populated from the venue row. **Consumer impact:** zen_quant's Orderflow paths (`cvd_delta`, `footprint_cells`, `vwap`) need price/amount per trade; with the struct fields nil they must read `t.info["price"]`/`t.info["size"]` by hand — defeating the unified contract.

---

## 2026-06-30 — unified `fetch_order_book/2` omits bybit's `category` injection → `{:error, "Illegal category"}` (bybit)

**Status (2026-06-30):** ✅ **fixed** — verified live in the 2026-07-15 v0.6.1 sweep (see the sweep banner at top): bybit `fetch_order_book` has `category` injected, no "Illegal category". **Severity when open:** medium (request-shape gap — the `category` injection that tasks 190/192 added for `fetch_ticker`/`fetch_funding_rate(s)`/`fetch_markets` did **not** generalize to `fetch_order_book`). **Consumer:** zen_quant (path-dep, MM + Orderflow integration suites).

> **Triage note (2026-07-14):** 📋 folded into **task 153** (order_book read path — moved to milestone v0_7_0): verifying the order-book parse live on bybit presupposes the category injection, so request-shape generalization + parse land as one diff. Task 153's ACs now require the no-manual-params live call.

**Method:** `CCXT.fetch_order_book(ex, symbol)` · **Exchange:** bybit

```elixir
{:ok, bx} = CCXT.exchange(:bybit)
CCXT.fetch_order_book(bx, "BTC/USDT:USDT")
# => {:error, %CCXT.Error{type: :bad_request, code: 10001, message: "Illegal category", exchange: "bybit"}}

# Workaround — caller injects category by hand:
CCXT.fetch_order_book(bx, "BTC/USDT:USDT", params: %{"category" => "linear"})
# => {:ok, %{status: 200, body: …}}   (raw envelope — no parse_order_book slice; see the parser-gap entry)
```

**Root cause:** bybit V5 requires a `category` param on the orderbook endpoint, same as ticker/funding/markets; the per-venue `request_param_shape` category injection (task 190) was wired for those methods but not `fetch_order_book`. **Expected:** `CCXT.fetch_order_book(bx, "BTC/USDT:USDT")` resolves the linear/spot category from the symbol like `fetch_ticker` does. **Consumer impact:** zen_quant's MM (`spread`, `imbalance`) and Orderflow (`dom_level`, `heatmap`) paths have no working bybit order-book call without a manual `params` category; deribit order_book works (returns a raw envelope, no parser).

---

## 2026-06-23 — unified `fetch_volatility_history/2` RAISES `encode_query/2 values cannot be lists` on `:params` keyword (deribit)

**Status (2026-06-23):** ✅ **fixed** — reclassified 2026-06-30 (the generic crash was a call-site shape error, hardened by task 185), residual parse gap closed by task 200, and confirmed in the 2026-07-15 v0.6.1 sweep: deribit `fetch_volatility_history` returns `[%CCXT.VolatilityHistory{}]` (384). See both Update blocks below. **Severity when open:** high (hard crash on the documented `:params` shape — broke the `{:ok,…}|{:error,…}` contract). **Consumer:** zen_quant (path-dep, DVOL integration suite + `ZenQuant.Options.Deribit.dvol/2`).

> **Update (2026-06-30, zen_quant re-probe):** ⚠️ **reclassified — the generic crash is gone.** `CCXT.fetch_volatility_history(ex, "BTC", params: %{"currency" => "BTC"})` now returns `{:ok, %{status: 200, …}}`. The RAISE was the call site passing `params:` as the **symbol positional** (`[:symbol]` is required, unified.ex:147), so the keyword list got query-encoded; calling with the symbol positional fixed by task 185's `split_opts` hardening avoids it. **Residual ccxt gap:** no `parse_volatility_history` slice → the read returns a raw `%{status, body}` envelope, not a struct (zen_quant's `parse_dvol` already hand-navigates the body, so non-blocking). Consumer fix is the zen_quant call-site migration (Task 2). *Triage note (2026-07-14): the residual parse gap is filed as **task 200** (parse_volatility_history slice for Deribit DVOL, milestone v0_7_0).*
>
> **Update (2026-07-14, task 200):** ✅ **residual parse gap closed.** `fetch_volatility_history` returns `[%CCXT.VolatilityHistory{info, timestamp, datetime, volatility}]` (array-of-pairs parse path; never the raw HTTP/JSON-RPC envelope). zen_quant can drop body-digging once it re-points at the typed list.

**Method:** `CCXT.fetch_volatility_history(ex, params: %{…})` · **Exchange:** deribit

Calling the unified method **correctly** (with an `%Exchange{}` and a `:params` keyword) still raises — the `:params` key is not split out of `opts` and gets handed verbatim to query encoding:

```elixir
{:ok, ex} = CCXT.exchange(:deribit)
CCXT.fetch_volatility_history(ex, params: %{"currency" => "BTC"})
# ** (RuntimeError/ArgumentError) encode_query/2 values cannot be lists,
#    got: [params: %{"currency" => "BTC"}]
```

**Root cause:** the dispatch path passes the whole `opts` keyword list (`[params: %{…}]`) into query encoding instead of extracting `:params` as the exchange-native param map. `CCXT.Unified.split_opts/1` recognizes `:endpoint_index, :market_type, :timeout, :plug, :headers, :base_url` but **not** `:params` (verified: `split_opts(normalize: false, params: %{"a"=>1})` returns `{[], [normalize: false, params: %{"a"=>1}]}` — both land in `extra`). So `extra` carries `params: %{…}` as a literal query pair, and `encode_query` rejects the map-valued list.

**Expected:** `:params` is the standard channel for exchange-native query params (CCXT JS's `params` object); it must be merged into the request query, not encoded as a literal `params=` pair. **Fix:** teach `split_opts/1` (or the request builder) to pull `:params` out of `opts` and merge its map into the venue query.

**Consumer impact:** zen_quant's entire Deribit DVOL path is dead — `ZenQuant.Options.Deribit.dvol/2` (`lib/zen_quant/options/deribit.ex:272`) and all 6 `deribit_dvol_integration_test.exs` tests crash. There is no caller-side workaround: `:params` is the documented param channel.

---

## 2026-06-23 — unified `fetch_ohlcv/3` omits bybit's `intervalTime` mapping → `{:error, "intervalTime is invalid"}` (bybit)

**Status (2026-07-25):** ✅ **fixed** — both residuals closed; see the 2026-07-25 Update block below. The filed defect (the `intervalTime` timeframe mapping) was fixed by task 190 (`de3f0a2`); the spot-category residual is live-verified gone, and the "no `parse_ohlcvs` slice" residual was a mischaracterization (the slice exists; arrays are the deliberate contract). **Severity when open:** medium (authoring gap — timeframe→venue-interval mapping was not injected; same family as the `category` / `fetch_markets` request-shape entries below).

> **Update (2026-06-30, zen_quant re-probe):** ✅ **Fixed by task 190** (`de3f0a2`). The `intervalTime` rejection is gone — `CCXT.fetch_ohlcv(ex, "BTC/USDT:USDT", "1h")` returns 200 candles (linear perp symbol). The old `"BTC/USDT"` (spot) symbol now returns `"Category is invalid"` instead — that's the spot/linear category-resolution path, not the timeframe mapping this entry filed. Consumer note: zen_quant must pass the linear-perp symbol (`…:USDT`). Residual: candles return as raw arrays (no `parse_ohlcvs` collection slice — see the parser-gap entry).

> **Update (2026-07-25, audit-review live re-probe):** ✅ **Both residuals closed.** Live on bybit (public, no creds): `CCXT.fetch_ohlcv(ex, "BTC/USDT", "1h", limit: 3)` → 3 candles, no `"Category is invalid"` — spot category resolution is wired. The second residual was a **mischaracterization, not a gap**: the `ohlcv` parse slice does exist (`CCXT.Unified.ReadParse.do_parse("ohlcv", …)`, `lib/bourse/unified/read_parse.ex:127`) and it *is* what produced the observed rows — it extracts the envelope payload, normalizes candle order, coerces the six standard positions (`ohlcv_timestamp` + `safeNumber`), and applies `since`/`limit`. The **list-of-arrays return is the deliberate contract**, matching CCXT's `parseOHLCVs`; `%CCXT.OHLCV{}` is the caller's opt-in conversion via `CCXT.OHLCV.from_list/1`. Consumer note for zen_quant: map with `CCXT.OHLCV.from_list/1` if structs are wanted — no client change pending. Note task 171 (the former tracking task) is `done`; nothing here is untracked.

**Method:** `CCXT.fetch_ohlcv(ex, symbol, timeframe)` · **Exchange:** bybit

A unified timeframe string (`"1h"`) is not translated to bybit V5's expected interval param, so the venue rejects the request:

```elixir
{:ok, ex} = CCXT.exchange(:bybit)
CCXT.fetch_ohlcv(ex, "BTC/USDT", "1h")
# => {:error, %CCXT.Error{type: :bad_request, code: 10001,
#       message: "params error: intervalTime is invalid", exchange: "bybit"}}
```

The unified layer passes the timeframe through without mapping it to bybit's `interval` / `intervalTime` enum (`"1h"` → `60`). Per the authored-specs re-route above, for a first-class venue this is an **authoring task** (read CCXT JS `fetchOHLCV` `timeframes` map → inject the venue interval), not an upstream wait.

**Expected:** `CCXT.fetch_ohlcv(ex, "BTC/USDT", "1h")` returns candles. **Consumer impact:** zen_quant's 8 volatility integration tests (realized/parkinson/garman_klass/yang_zhang/cone/rolling/elevated?) have no working OHLCV call path on bybit.

---

## 2026-06-23 — unified reads return the raw HTTP envelope (no `parseX`) for most methods zen_quant needs — parser authoring gap

**Status (2026-07-25):** ✅ **fixed** — see the 2026-07-25 Update block on the bybit OHLCV entry above. Task 189 landed the options/greeks/funding parsers; the 2026-07-15 v0.6.1 sweep confirms `fetch_markets`, `fetch_ticker`, `fetch_order_book`, `fetch_funding_rate(s)`, `fetch_trades`, and `fetch_volatility_history` all return typed structs. The last standing residual — "no `parse_ohlcvs` collection slice" — was a mischaracterization: the slice exists (`lib/bourse/unified/read_parse.ex:127`) and the coerced list-of-arrays return is the deliberate CCXT-compatible contract, with `CCXT.OHLCV.from_list/1` as the caller's opt-in struct conversion. **Severity when open:** medium (authoring gap — Phase-5 parsers; not a crash, but no normalized contract). **Consumer:** zen_quant (cross-venue analytics depend on the unified field contract).

> **Update (2026-06-30, zen_quant re-probe):** ⚠️ **Partially fixed by task 189** (`0a84288`). Now parsed (live-confirmed deribit): `fetch_greeks` → `%CCXT.Greeks{}`, `fetch_option_chain` → `%{symbol => %CCXT.OptionData{}}`, `fetch_funding_rate(s)` → `%CCXT.FundingRate{}` (singular) / `%{symbol => %CCXT.FundingRate{}}` (plural). **Still raw envelopes / unmapped collections:** `parse_order_book`, `parse_trades`, `parse_ohlcvs`, `parse_option_chain` are absent (`parse_option`/`parse_funding_rate`/`parse_greeks` present) — so `fetch_order_book`, `fetch_trades`, and `fetch_ohlcv` collections return raw shapes. Field gaps observed: `%OptionData{currency: nil}`. Net: the methods zen_quant's options/greeks/funding paths need are parsed; orderbook/trades/ohlcv collection parsers remain.

**Methods:** `fetch_option_chain/2`, `fetch_greeks/2`, `fetch_funding_rate(s)`, `fetch_order_book/2`, `fetch_trades/2`, `fetch_ohlcv/3` · **Exchanges:** bybit, deribit (probed both)

Normalization is **partially** shipped: some unified reads return a parsed struct, others return the raw `%{status, body, headers}` HTTP envelope. Verified live:

```elixir
{:ok, dx} = CCXT.exchange(:deribit)
CCXT.fetch_ticker(dx, "BTC/USD:BTC")    # => {:ok, %CCXT.Ticker{bid: …, ask: …}}   ✅ parsed
CCXT.fetch_option_chain(dx, "BTC")      # => {:ok, %{body: …, headers: …, status: 200}}  ⚠️ raw envelope
CCXT.fetch_greeks(dx, "BTC-PERPETUAL")  # => {:ok, %{body: …, headers: …, status: 200}}  ⚠️ raw envelope
```

Per-exchange parser presence (probed on bybit **and** deribit — identical):

| parser | present |
|---|---|
| `parse_ticker`, `parse_trade`, `parse_ohlcv` | ✅ |
| `parse_funding_rate(s)`, `parse_order_book`, `parse_trades`, `parse_ohlcvs`, `parse_option_chain`, `parse_option`, `parse_greeks` | ❌ |

**Expected:** unified reads return normalized structs (`%CCXT.OptionData{}`, `%CCXT.OrderBook{}`, `%CCXT.FundingRate{}`, …) like `fetch_ticker` already does — the "Phase 5 parsers" the consumer roadmap is gated on. **Fix:** author the missing `parseX` slices per the re-route (171/181) and wire them into the unified read path.

**Consumer impact:** zen_quant's Options chain/GammaWalls, Greeks, Funding, Orderflow, and MM paths get raw envelopes they must navigate by hand (`body["result"]["list"]`), with no stable field contract — so the cross-venue analytics (`Execution.best_price`, `from_multi`, `basis`, options chain) that depend on uniform fields cannot run.

---

## 2026-06-23 — unified `fetch_funding_rates/2` RAISES `FunctionClauseError` when `opts` is a map (all exchanges)

**Status (2026-06-23):** ✅ **fixed** by task 185 (`56a989e`) — see the Update block below; re-confirmed in the 2026-07-15 v0.6.1 sweep (`fetch_funding_rates` map-opts → `{:ok, map}`, 728 entries, no `FunctionClauseError`). **Severity when open:** high (broke the `{:ok,…}|{:error,…}` contract — a hard crash, not an error tuple). **Consumer:** zen_quant (path-dep, integration suite).

> **Update (2026-06-30, zen_quant re-probe):** ✅ **Fixed by task 185** (`56a989e`, "reject malformed dispatch opts"). `CCXT.Unified.split_opts(%{"category" => "linear"})` now coerces the map → `{[], [{"category", "linear"}]}` instead of `FunctionClauseError`, and `CCXT.fetch_funding_rates(ex, params: %{"category" => "linear"})` returns `{:ok, %{symbol => %CCXT.FundingRate{}}}`. No raise.

**Method:** `CCXT.fetch_funding_rates(ex, opts)` (any zero-required-param unified method) · **Exchange:** all (defect is in the generic dispatch path, not venue-specific)

Passing exchange-native params as a **map** — the natural shape, since CCXT JS takes an
object `params` — makes the generated unified function raise instead of returning a value:

```elixir
{:ok, ex} = CCXT.exchange(:bybit)
CCXT.fetch_funding_rates(ex, %{"category" => "linear"})
# ** (FunctionClauseError) no function clause matching in Keyword.split/2
#     # 1  %{"category" => "linear"}
#     # 2  [:endpoint_index, :market_type, :timeout, :plug, :headers, :base_url]
#     (elixir) lib/keyword.ex:1230: Keyword.split/2
#     (ccxt_client 0.6.1) lib/ccxt.ex:160: CCXT.fetch_funding_rates/2
```

**Root cause:** the macro-generated `def fetch_funding_rates(%Exchange{}=ex, opts \\ [])`
(`lib/bourse.ex:160`) calls `Unified.split_opts(opts)`, which is `Keyword.split(opts, …)`.
`Keyword.split/2` is guarded `when is_list(keywords)` and `FunctionClause`-raises on a map.
Nothing normalizes or validates `opts` first.

**Expected:** either accept a map for extra/params (convert internally), or reject it with a
clean `{:error, %CCXT.Error{type: :bad_request}}`. A public dispatch function must never raise
`FunctionClauseError` at the consumer. **Fix:** in `Unified.split_opts/1` (or before it), coerce
`opts` to a keyword list (`opts |> Enum.to_list()` / `Map.to_list/1`) or `raise ArgumentError`
with a clear message, and document that exchange params go through a dedicated `:params` key.

**Consumer impact:** zen_quant's funding integration tests need to pass bybit's `category` param;
the obvious map form crashes the test process instead of erroring, so the failure is opaque.

---

## 2026-06-23 — public `fetch_funding_rate/2` demands credentials ("Credentials required for fetch_markets") (bybit)

**Status (2026-06-23):** ✅ **fixed** by task 187 (`760622d`) — see the Update block below; re-confirmed in the 2026-07-15 v0.6.1 sweep (public `fetch_funding_rate` → `%CCXT.FundingRate{}` with no credentials). **Severity when open:** high (public funding data unreachable without API keys).

> **Update (2026-06-30, zen_quant re-probe):** ✅ **Fixed by task 187** (`760622d`, "public symbol resolution must not require credentials"). `CCXT.fetch_funding_rate(ex, "BTC/USDT:USDT")` returns `{:ok, %CCXT.FundingRate{}}` with no credentials configured.

**Method:** `CCXT.fetch_funding_rate(ex, symbol)` · **Exchange:** bybit (likely any venue whose symbol resolution forces market load)

A funding rate is **public** data, but the unified call fails demanding credentials:

```elixir
{:ok, ex} = CCXT.exchange(:bybit)
CCXT.fetch_funding_rate(ex, "BTC/USDT:USDT")
# => {:error, %CCXT.Error{type: :authentication_error,
#       message: "Credentials required for fetch_markets", exchange: "bybit"}}
```

The symbol-bearing path resolves `"BTC/USDT:USDT"` → market, which triggers a market load that
is (incorrectly) gated behind credentials. In CCXT JS `fetchMarkets` / `loadMarkets` are public;
resolving a symbol for a **public** funding call must not require API keys.

**Expected:** `fetch_funding_rate(ex, symbol)` works credential-free for public venues, same as
`fetch_ticker`/`fetch_order_book`. **Fix:** market loading for symbol resolution must use the
public endpoint; only genuinely private methods should surface `:authentication_error`.

**Consumer impact:** zen_quant can't exercise per-symbol funding analytics against public bybit
without provisioning keys it shouldn't need.

---

## 2026-06-23 — unified `fetch_funding_rates/1` omits bybit's required `category` → `{:error, "Illegal category"}` (bybit)

**Status (2026-06-23):** ✅ **fixed** by tasks 190/192 (`de3f0a2`, `d29f53b`) — see the Update block below; re-confirmed in the 2026-07-15 v0.6.1 sweep (bybit `category` injected, no "Illegal category"). Residual carve note on malformed bybit symbols is tracked separately under 171/195. **Severity when open:** medium (authoring gap — request shape not injected; same family as the `fetch_markets` request-shape entries below).

> **Update (2026-06-30, zen_quant re-probe):** ✅ **Fixed by tasks 190/192** (`de3f0a2` category injection, `d29f53b` emulated symbol resolution). `CCXT.fetch_funding_rates(ex, params: %{"category" => "linear"})` returns `{:ok, %{symbol => %CCXT.FundingRate{}}}` — no "Illegal category". Residual carve note: some bybit symbols come back malformed (`"ETCPERP/:"` trailing `/:`), tracked separately under the markets-carve work (171/195).

**Method:** `CCXT.fetch_funding_rates(ex)` · **Exchange:** bybit

The bare unified call doesn't inject bybit V5's mandatory `category` (linear/inverse/spot) query
param, so the exchange rejects it:

```elixir
{:ok, ex} = CCXT.exchange(:bybit)
CCXT.fetch_funding_rates(ex)
# => {:error, %CCXT.Error{type: :bad_request, code: 10001,
#       message: "Illegal category", exchange: "bybit"}}
```

This is the "symbol-bearing/contract methods need a market-category param the unified layer
doesn't yet inject" gap the README/roadmap already flags for `fetch_ticker` et al. — here for
`fetch_funding_rates`. Per the authored-specs re-route above, for a first-class venue this is an
**authoring task** (read CCXT JS `fetchFundingRates` → inject `category` per market type), not an
upstream wait.

**Expected:** `CCXT.fetch_funding_rates(ex)` returns linear-perp funding without the caller
hand-passing `category`. **Note:** the obvious workaround — passing `%{"category" => "linear"}` —
currently hits the `FunctionClauseError` crash reported above, so there is no clean caller-side
escape hatch today.

**Consumer impact:** zen_quant's funding suite (mean/compare/cumulative/detect_spikes over bybit
rates) has no working public call path until either the category injection lands or the map-opts
crash is fixed.

---

## 2026-06-23 — `fetch_markets` on lighter misclassifies HTTP-success as `:exchange_error` — returns `{:error, …}`, no normalization (lighter)

**Status (2026-06-23):** ✅ **fixed.** The classifier defect this entry filed was closed by the response-classifier task (HTTP/JSON-RPC success no longer misread as `:exchange_error` — lighter `code: 200`, deribit result-without-error), and task 195 added the `order_book_details` envelope unwrap for lighter's `fetch_markets` (206 markets). Lighter has since been promoted to a **complete authored public/private venue** (task 451, `7a7b9d58`), with `fetch_ticker` authored by task 197 and the upstream CCXT static corpus vendored into the fixture replay gate (task 501). `COVERAGE.md`'s live matrix carries lighter `fetchMarkets` ✅ and `fetchTicker` ✅. **Severity when open:** high (blocked lighter onboarding entirely).

> **Correction (2026-07-25).** An earlier pass of this reconciliation marked this entry "OPEN — not re-tested", carrying forward the 2026-07-15 sweep banner's "lighter is WIP upstream" note. That note was itself stale: lighter was promoted after the sweep. `COVERAGE.md`'s live matrix — not the sweep banner — is the authority for current per-venue state.

**Method:** `CCXT.fetch_markets(ex)` · **Exchange:** lighter (perp DEX, `zklighter.elliot.ai`)

`fetch_markets` on lighter does not return a market list at all — it returns an **error** even though the exchange responded successfully:

```elixir
{:ok, ex} = CCXT.exchange(:lighter)
CCXT.fetch_markets(ex)
# => {:error, %CCXT.Error{type: :exchange_error, message: "Exchange error response",
#       exchange: "lighter",
#       raw: %{"code" => 200, "order_book_details" => [ %{...per-market...}, ... ]}}}
```

The raw payload carries `"code" => 200` — lighter's **success** code — and the per-market data
under `order_book_details`. ccxt_client's error detector appears to treat the presence of a
`"code"` key (or a non-`0` code) as an exchange error, but lighter signals success with `code: 200`.
The success envelope is misread as a failure, so the whole call errors and **nothing is normalized**.

**The data we need is all present in `.raw`** — only the envelope classification + the carve are missing:

| Unified Market field | lighter `order_book_details[]` source |
|---|---|
| `id` / `symbol` | `market_id` / `symbol` (e.g. `"LAUNCHCOIN"`) |
| `type` / `swap` / `contract` | `market_type` (`"perp"`) |
| `active` | `status` (`"active"` / `"inactive"`) |
| `maker` / `taker` | `maker_fee` (`"0.0000"`) / `taker_fee` |
| `precision.price` / `precision.amount` | `supported_price_decimals` (6) / `supported_size_decimals` (0) |
| `limits.amount.min` | `min_base_amount` (`"100"`) |
| `limits.cost` | `order_quote_limit` |
| MMR (for `limits.leverage` / consumer MMR) | `maintenance_margin_fraction` (2000) |
| max leverage | `min_initial_margin_fraction` / `default_initial_margin_fraction` (3333) → ≈ 1/IMF |
| `info` | the raw per-market object |

**Consumer impact:** lighter has **no** `fetchTradingFee(s)` and **no** `fetchLeverageTiers`/
`fetchMarketLeverageTiers` endpoints (`has` map all `false`), so `fetch_markets` is the **only**
source for lighter's fees, MMR, and leverage caps. With it erroring out, `trading_dashboard` cannot
onboard lighter for tasks 22/23/24 at all — there is no fallback endpoint. Fix is two parts:
(1) treat lighter `code: 200` as success in the response classifier; (2) author the lighter
`fetchMarkets` carve mapping the `order_book_details` fields above.

---

## 2026-06-23 — `fetch_markets` on deribit misclassifies JSON-RPC success as `:exchange_error` — drops 4636 markets (deribit)

**Status (2026-06-23):** ✅ **fixed** — verified live in the 2026-07-15 v0.6.1 sweep (see the sweep banner at top): deribit `fetch_markets` returns 4813 markets, no `:exchange_error` misclassification. **Severity when open:** high (blocked deribit onboarding).

**Method:** `CCXT.fetch_markets(ex)` · **Exchange:** deribit

Same misclassification family as the lighter bug above, but a **JSON-RPC** envelope.
Deribit replies with a valid JSON-RPC success — `result` holds **4636 markets** — yet
ccxt_client flags the whole envelope as an error and extracts nothing:

```elixir
{:ok, ex} = CCXT.exchange(:deribit)
CCXT.fetch_markets(ex)
# => {:error, %CCXT.Error{type: :exchange_error,
#       raw: %{"jsonrpc" => "2.0", "result" => [ ...4636 markets... ],
#              "testnet" => false, "usIn" => ..., "usOut" => ..., "usDiff" => ...}}}
```

There is **no** `error` member in the response (JSON-RPC signals failure via an `error`
object; this response has only `result`), so the classifier should treat presence-of-`result`
/ absence-of-`error` as success and parse `result` as the market list. `fetch_ticker` on
deribit works (returns a normalized `%CCXT.Ticker{}`, only `base_volume` nil), so the
JSON-RPC envelope handling is endpoint-specific to `fetch_markets`.

**Consumer impact:** deribit cannot be onboarded for tasks 22/23/24 until `fetch_markets`
parses the JSON-RPC `result`. Fix: (1) classify deribit JSON-RPC `result`-without-`error`
as success; (2) author the deribit `fetchMarkets` carve over the `result[]` entries.

---

## 2026-06-23 — `fetch_markets` + `fetch_ticker` on hyperliquid send a malformed request body (HTTP 400) (hyperliquid)

**Status (2026-06-23):** ✅ **fixed** — verified live in the 2026-07-15 v0.6.1 sweep (see the sweep banner at top): hyperliquid `fetch_markets` returns 232 markets with no HTTP 400. **Severity when open:** high (blocked hyperliquid onboarding).

**Method:** `CCXT.fetch_markets(ex)` / `CCXT.fetch_ticker(ex, sym)` · **Exchange:** hyperliquid

Unlike lighter/deribit (success-misclassified-as-error), this is a **genuine request-shape
bug** — hyperliquid rejects the request before returning data:

```elixir
{:ok, ex} = CCXT.exchange(:hyperliquid)
CCXT.fetch_markets(ex)
# => {:error, %CCXT.Error{type: :exchange_error, http_status: 400,
#       raw: "Failed to parse the request body as JSON"}}
CCXT.fetch_ticker(ex, "BTC/USDC:USDC")
# => {:error, %CCXT.Error{type: :exchange_error,
#       message: "Failed to deserialize the JSON body into the target type"}}
```

Hyperliquid's public API is a single POST `/info` endpoint that takes a JSON body
(`{"type":"meta"}`, `{"type":"metaAndAssetCtxs"}`, etc.). The HTTP-400 / "failed to
deserialize" responses indicate ccxt_client is sending an empty, malformed, or
wrong-typed body — the request slice for hyperliquid's info endpoint needs authoring.
Cross-endpoint: both `fetch_markets` and `fetch_ticker` fail the same way.

**Consumer impact:** hyperliquid cannot be onboarded at all (no endpoint returns data),
and like lighter it has no `fetchLeverageTiers` fallback — `fetch_markets` is the only
fees/leverage source. Fix: author the hyperliquid `/info` POST request body (`request_param_shape`)
per endpoint, then the `fetchMarkets`/`fetchTicker` carves.

## 2026-06-21 — `fetch_ticker` normalization drops `symbol`, `base_volume`, `quote_volume`, `info`, `datetime` (binance)

**Status (2026-06-21):** ✅ **fixed** — the 2026-07-15 v0.6.1 sweep confirms binance and bybit `fetch_ticker` return `%CCXT.Ticker{}` fully populated (`symbol`, `last`, `base_volume`, `quote_volume`, `datetime`, `info`, `vwap`), closing the `base_volume` residual that had been re-routed to task 171. History: partially fixed by Task 152 (`053f289e577c`) and Task 165 (`a2696dc1ae58`); Task 165 addressed the `datetime` and `info` defects; `base_volume` was re-routed 2026-06-23 → authored task 171 (carve correctness, 181) — see the re-route banner at top. Earlier re-test after Task 152:
- `symbol` → `"BTC/USDT"` ✅ fixed
- `quote_volume` → `"613813447.72..."` ✅ fixed
- `base_volume` → still `nil` ❌ (raw `"volume"` not mapped)
- `datetime` → fixed by Task 165 ✅
- `info` → fixed by Task 165 ✅

One of five fields remains. Original report below.

**Triage (2026-06-21, verified live via tidewave):**
- `symbol` ✅ Task 152 (`backfill_request_symbols`). `quote_volume` ✅ distill T86 (resynced `84b4101`).
- `base_volume` ❌ → **RE-ROUTED 2026-06-23 → authored task 171** (was: UPSTREAM distill, resync-gated). The binance ticker carve maps `baseVolume` to source key `"baseVolume"`, but the raw payload carries it under `"volume"` (CCXT JS `parseTicker` reads `'volume'`) — a carve/value question to author against CCXT JS + the real binance response, not wait on upstream. Carve-correctness (diverge from CCXT's source-key choice if reality demands) is task 181.
- `datetime` + `info` ✅ → **consumer Task 165** (universal post-parse datetime ISO8601 + info raw-body preservation in the unified read path), landed in `a2696dc1ae58`.

**Method:** `CCXT.fetch_ticker(ex, "BTC/USDT")` · **Exchange:** binance (spot) · **Severity:** moderate

After T144, `fetch_ticker` returns a `%CCXT.Ticker{}` struct (good — normalization is live),
but several canonical ccxt ticker fields are `nil` even though the raw exchange payload carries them:

| Ticker field   | Normalized value | Raw payload key (present) |
|----------------|------------------|---------------------------|
| `symbol`       | `nil`            | `"symbol" => "BTCUSDT"` (should map to unified `"BTC/USDT"`) |
| `base_volume`  | `nil`            | `"volume" => "9870.03..."` |
| `quote_volume` | `nil`            | `"quoteVolume" => "628810089.75..."` |
| `datetime`     | `nil`            | derivable from `timestamp` (present, e.g. `1781995831652`) → ISO8601 |
| `info`         | `nil`            | the raw exchange response is not preserved |

Per the [ccxt ticker structure](https://docs.ccxt.com/?id=ticker-structure), `symbol`,
`baseVolume`, `quoteVolume`, and `info` are populated fields — `info` by convention always
holds the raw exchange response so consumers can reach exchange-specific fields the unified
struct doesn't model. The field-map for the binance ticker read path appears to omit these
mappings.

**Repro:**
```elixir
{:ok, ex} = CCXT.exchange(:binance)
{:ok, t} = CCXT.fetch_ticker(ex, "BTC/USDT")
# t.last => "64307.36..."  (OK)
# t.symbol / t.base_volume / t.quote_volume / t.datetime => nil
# t.info => nil   (raw payload lost)
```

**Consumer impact:** `last`/`close` ARE populated, so `trading_dashboard`'s price-fetch path
(`Portfolio.Capture`) works. But `info: nil` means any consumer needing a raw field must
re-fetch raw; and `symbol: nil` makes a `%CCXT.Ticker{}` non-self-describing when tickers are
collected into a map/stream.

---

## 2026-06-21 — `fetch_markets` not normalized — still returns raw exchange envelope (binance)

**Status (2026-06-21):** ✅ **fixed** — the 2026-07-15 v0.6.1 sweep confirms binance `fetch_markets` returns 6024 `%CCXT.Market{}` with `precision`/`limits`/`type`/`settle` populated, closing the metadata residual re-routed to tasks 177/180/181. Inverse-perp symbol formatting remains tracked separately as Task 167. History: partially fixed by Task 152 (`053f289e577c`), Task 165 (`a2696dc1ae58`), and Task 166 (`ba68646e63f8`); Task 166 addressed the single-endpoint routing defect by fanning out across market-type endpoints, Task 165 addressed `info`. Earlier re-test after Task 152:

### Re-test defects (2026-06-21, binance, `{:ok, m} = CCXT.fetch_markets(ex)`)

1. **Only 38 markets, ALL coin-margined (`*_PERP`, dapi).** `length(m) == 38`; first symbols are `BTCUSD_PERP/`, `ETHUSD_PERP/`, … — no spot, no USD-M linear. `fetch_markets` appears to route to only the coin-margined `exchangeInfo`; the bulk of binance's market universe (spot + USD-M) is missing.
2. **Malformed unified symbol — 38/38 end in a trailing `/`.** `m |> hd |> Map.get(:symbol) == "BTCUSD_PERP/"`. The symbol builder concatenates the raw id + `/` with an empty tail; expected a unified ccxt symbol (inverse perp ≈ `"BTC/USD:BTC"`), never `"BTCUSD_PERP/"`.
3. **`limits` all empty.** `%{"amount" => %{}, "cost" => %{}, "leverage" => %{}, "market" => %{}, "price" => %{}}` — despite the raw symbol carrying `filters` (`LOT_SIZE` minQty/maxQty/stepSize, `PRICE_FILTER` tickSize). amount/price/leverage bounds are not extracted.
4. **`precision` uses `base`/`quote`, not `amount`/`price`.** Got `%{"base" => 8, "quote" => 8}`; ccxt precision is `%{amount, price}` (here derivable from raw `quantityPrecision`/`pricePrecision`). Consumers needing tick/lot precision can't use it.
5. **Market-type flags all `nil`.** `type/spot/swap/future/option/contract/linear/inverse/active` are `nil` on a coin-margined perpetual that should be `swap: true, contract: true, inverse: true, settle: "BTC"`. Consumers can't classify spot-vs-derivative.
6. **`info: nil`** — raw per-symbol payload not preserved (same ccxt-convention break as the ticker bug).

Original report below.

**Triage (2026-06-21, verified live via tidewave):**
- #1 only 38 coin-M markets → **consumer Task 166** (fetch_markets multi-endpoint fan-out — union spot + linear + inverse), landed in `ba68646e63f8`.
- #2 trailing-slash symbol (`"BTCUSD_PERP/"`) → **consumer Task 167**, symbol-builder bug for inverse-perp ids.
- #3 `limits` empty + #4 `precision` base/quote-only → **RE-ROUTED 2026-06-23 → authored tasks 177 + 180** (was: UPSTREAM distill, resync-gated). limits/precision sources (`minQty`/`stepSize`/`tickSize`) live inside binance's `filters[]` array (indexed by `filterType`); CCXT JS reads them by logic, so the carve must be authored — 177 owns the fetchMarkets precision/limits oracle, 180 the tier-1 (real-API + non-CCXT-source) value verification for divergence-prone precision.
- #5 market-type flags all nil → **RE-ROUTED 2026-06-23 → authored tasks 177 + 181** (was: UPSTREAM distill). `spot`/`swap`/`contract`/`linear`/`inverse`/`settle`/`type` are CCXT-JS-derived by logic — author the derivation; carve correctness vs reality is 181.
- #6 `info: nil` → **consumer Task 165** (universal info preservation), landed in `a2696dc1ae58`.
- Per-symbol `maker`/`taker` (`member` coercion) references the exchange's STATIC fees, not response data — re-scoping tracked on blocked Task 164.

**Method:** `CCXT.fetch_markets(ex)` · **Exchange:** binance · **Severity:** moderate (blocks consumer work)

T144 wired the *ticker* read path, but `fetch_markets` still returns the **raw exchange body**,
not a list of unified market structs:

```elixir
{:ok, ex} = CCXT.exchange(:binance)
{:ok, m} = CCXT.fetch_markets(ex)
is_list(m)                 # => false
Map.keys(m)                # => ["exchangeFilters","rateLimits","serverTime","symbols","timezone"]
# m["symbols"] |> List.first  => raw binance keys:
#   "pricePrecision", "quantityPrecision", "maintMarginPercent", "liquidationFee",
#   "quoteAsset", "contractSize", "baseAsset", "filters" => [PRICE_FILTER/LOT_SIZE/...]
```

Expected (per ccxt market structure): a list of unified market structs carrying
`precision: %{amount, price}`, `limits: %{leverage, amount, ...}`, `maker`/`taker` fees, and
`quote`/`base` — i.e. the per-symbol metadata that lets consumers derive precision, fees,
leverage caps, and USD-quote resolution without parsing exchange-native shapes.

**Secondary:** a bare `fetch_markets(:binance)` returned the **coin-margined (dapi) `exchangeInfo`**
(sample symbol `"BTCUSD_PERP"`, `marginAsset: "BTC"`), not spot/usd-m — so default market-type
routing for `fetch_markets` may also need attention.

**Consumer impact:** `trading_dashboard` tasks 22/23/24 (derive USD quote-currency resolution,
position-sizer market-param defaults, and per-exchange account-type options from ccxt market
metadata) are gated on exactly this normalization. They remain blocked until `fetch_markets`
returns unified per-symbol structs.

---

## 2026-06-21 — `fetch_ticker` on bybit fails with `Illegal category` (lower confidence)

**Status (2026-06-23):** ✅ **fixed** — the 2026-07-15 v0.6.1 sweep confirms bybit `category` is injected (no "Illegal category") and `fetch_ticker` returns a fully populated `%CCXT.Ticker{}`. History: RE-ROUTED → authored task 171 (was: Task 154, blocked on upstream public request-shape data); bybit v5 `category` injection was authored as a request-shape slice (`request_param_shape`) against CCXT JS + the real bybit response. Task 183 separately ensures this `:bad_request` 4xx stops being masked as inconclusive in the sweep.

**Method:** `CCXT.fetch_ticker(ex, "BTC/USDT")` · **Exchange:** bybit · **Severity:** unconfirmed

```elixir
{:ok, ex} = CCXT.exchange(:bybit)
CCXT.fetch_ticker(ex, "BTC/USDT")
# => {:error, %CCXT.Error{type: :bad_request, code: 10001, message: "Illegal category", exchange: "bybit"}}
```

Bybit v5 requires a `category` (`spot`/`linear`/...) param. The unified `fetch_ticker` may not be
injecting/inferring it from the symbol. **Lower confidence** — this could be a known limitation
or expect a market-type hint we didn't pass; needs maintainer confirmation on whether the unified
layer is supposed to inject `category` automatically.

---

## 2026-08-10 — binance fapi `create_order`: unified opts (`time_in_force`, `reduce_only`, `trigger_price`, `stop_loss_price`) werden stillschweigend verworfen — Market-Sell statt Stop-Order ausgeführt

**Status (2026-08-10):** ✅ **fixed** by workbench **task 574** — see the consolidated
"`create_order/6` dropped conditional controls and used the retired endpoint" entry above for the
outcome. The repro below is retained as the evidence trail. `time_in_force`, `reduce_only`,
`trigger_price` and `stop_loss_price` now reach the fapi request; conditional orders route to the
Algo Order API (`-4120` resolved).

**Method:** `Bourse.create_order/6` · **Exchange:** binance (USD-M futures, `sandbox: true`, testnet.binancefuture.com) · **Severity:** HIGH — real-money-relevant: eine als Stop gemeinte Order wurde als nackter Market-Sell ausgeführt

```elixir
{:ok, ex} = Bourse.exchange(:binance, api_key: ..., secret: ..., sandbox: true)
# 1) time_in_force-Opt kommt nie an (jede Variante :GTC / "GTC" / "gtc"):
Bourse.create_order(ex, "ETH/USDT:USDT", "limit", "buy", 0.41, price: 1822, time_in_force: "GTC")
# => {:error, -1102 "Mandatory parameter 'timeinforce' was not sent"}
# Workaround der ankommt: params: %{"timeInForce" => "GTC"}

# 2) trigger_price + reduce_only werden verworfen — die Order ging als PLAIN MARKET SELL raus und wurde sofort ausgeführt (Position -1.28 ETH eröffnet):
Bourse.create_order(ex, "ETH/USDT:USDT", "market", "sell", 1.28, trigger_price: 1620, reduce_only: true)
# => {:ok, %Order{}} — raw info: type=MARKET, kein stopPrice, reduceOnly=false, status=FILLED

# 3) stop_loss_price-Opt ebenso wirkungslos; ein "type"-Override via params wird vom
#    unified type überschrieben => Conditional-Orders sind für binance aktuell NICHT baubar:
Bourse.create_order(ex, sym, "market", "sell", 1.28, params: %{"type" => "STOP_MARKET", "stopPrice" => "1620", "reduceOnly" => "true"})
# => {:error, -1106 "Parameter 'stopprice' sent when not required."}  (type blieb MARKET)
```

Expected: die dokumentierten unified Opts (`time_in_force`, `reduce_only`, `trigger_price`,
`stop_loss_price` — alle in der `create_order`-Descripex-Contract-Doku gelistet) erreichen den
fapi-Request; `trigger_price`/`stop_loss_price` mappen auf `STOP_MARKET`+`stopPrice`.
Zusatzbefund: Binance hat Conditional-Orders von `POST /fapi/v1/order` auf die **Algo Order API**
verschoben (`-4120 "use the Algo Order API endpoints"`; `POST /fapi/v1/algoOrder` mit
`algoType=CONDITIONAL` + `triggerPrice`) — das binance-Mapping braucht also ohnehin den neuen Endpoint.
Quelle: developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api, live verifiziert 2026-08-10.

**Consumer impact:** trading_dashboard (Testnet-Order-Ladder 2026-08-10). Workaround lokal: rohe
signierte fapi-Calls via Req für marginType/Stop; Limit-Orders via `params:`-Map.

---

## 2026-08-10 — binance `set_margin_mode/3`: symbol-Parameter erreicht den Request nicht

**Status (2026-08-10):** ✅ **fixed** by workbench **task 574** — see the consolidated
"`set_margin_mode/3` omitted `symbol`" entry above. The unified symbol now resolves to `ETHUSDT`
on the wire; repro retained as evidence.

**Method:** `Bourse.set_margin_mode(ex, "isolated", "ETH/USDT:USDT")` · **Exchange:** binance (fapi, sandbox) · **Severity:** medium

Jede Arg-Variante (`"isolated"`, `"ISOLATED"`, zusätzlich `params: %{"symbol" => "ETHUSDT"}`) =>
`{:error, -1102 "Mandatory parameter 'symbol' was not sent"}`. Roher Call
`POST /fapi/v1/marginType?symbol=ETHUSDT&marginType=ISOLATED` mit denselben Keys => 200.
Expected: symbol wird aus dem unified Symbol aufgelöst und mitgesendet.

---

## 2026-08-10 — binance fapi `cancel_all_orders`: Erfolgsantwort wird als all-nil Order geparst UND Orders bleiben offen

**Status (2026-08-10):** ✅ **fixed** by workbench **task 574** — see the consolidated
"`cancel_all_orders/2` used the wrong route and parsed its acknowledgement as an order" entry above.
The call now routes to `DELETE /fapi/v1/allOpenOrders` (which actually cancels) and treats the
`{"code":200}` acknowledgement as success. Repro retained as evidence.

**Method:** `Bourse.cancel_all_orders(ex, symbol: "ETH/USDT:USDT")` · **Exchange:** binance (fapi, sandbox) · **Severity:** medium-high (meldet Fehler bei Erfolg — und der zugrundeliegende Call cancelt real nichts)

```elixir
Bourse.cancel_all_orders(ex, symbol: "ETH/USDT:USDT")
# => {:error, %Bourse.Error{type: :exchange_error, message: "Unexpected response shape: parsed to an all-nil struct (method: cancel_all_orders)",
#      raw: [%Bourse.Order{... alles nil, info: %{"code" => 200, "msg" => "The operation of cancel all open order is done."}}]}}
# Beobachtung: trotz "done"-Message blieben alle 3 offenen Limit-Orders bestehen (fetch_open_orders danach: 3).
# Roher Call DELETE /fapi/v1/allOpenOrders?symbol=ETHUSDT => 200 und cancelt tatsächlich.
```

Zwei Teilprobleme: (a) die `{"code":200,"msg":...}`-Bestätigung ist keine Order-Liste und gehört
nicht durch den Order-Parser (=> false-negative Error); (b) welcher Endpoint auch immer getroffen
wurde, er hat die offenen fapi-Orders nicht gecancelt — möglicherweise falsches Produkt-Routing.

---

## 2026-08-10 — binance `fetch_balance(type: :swap)` routet im Sandbox-Modus auf den Spot-Testnet

**Status (2026-08-10):** ✅ **fixed** by workbench **task 575** — see the consolidated
"`fetch_balance(type: :swap)` selected the Spot Testnet wallet" entry above. `:swap` now reaches
USD-M FAPI (`fapi/v3/account`), `:delivery` reaches COIN-M DAPI, `:margin` is a named exclusion.
Repro retained as evidence.

**Method:** `Bourse.fetch_balance(ex, type: :swap)` · **Exchange:** binance (sandbox) · **Severity:** medium (führt Konsumenten auf das falsche Konto)

Mit gültigen **Futures**-Testnet-Keys => `{:error, 401 "Invalid API-key"}`; mit **Spot**-Testnet-Keys
=> `{:ok, ...}` mit dem Spot-Testnet-Asset-Grabbag (GMT/JUV/... + BTC 1.0). Roher Call
`GET testnet.binancefuture.com/fapi/v2/balance` mit den Futures-Keys => 200 (USDT 4997.04).
Expected: `type: :swap` trifft fapi (testnet.binancefuture.com), nicht den Spot-Testnet.
`fetch_swap_balance` ist für binance zugleich `:not_supported` — es gibt also aktuell keinen
funktionierenden unified Weg zum USD-M-Wallet-Stand im Sandbox-Modus.

---

## 2026-08-14 — deribit: flache Positionen (`direction: "zero"`) degradieren `PortfolioRisk.snapshot` zu `:partial`

**Method:** `Bourse.PortfolioRisk.snapshot/1` (via `Bourse.fetch_positions/1`) · **Exchange:** deribit (sandbox, test.deribit.com) · **Severity:** medium (Konsument kann nie `status: :complete` erreichen, sobald das Konto je eine Position hatte)

Deribit `private/get_positions` liefert für geschlossene/flache Positionen Einträge mit
`"direction": "zero"` und `"size": 0.0`. `fetch_positions` normalisiert die zu
`%Bourse.Position{side: nil, contracts: 0.0}`, und `PortfolioRisk` wertet `side: nil` als
Komponenten-Failure:

```elixir
{:ok, snap} = Bourse.PortfolioRisk.snapshot([Bourse.PortfolioRisk.scope(ex, "main")])
# => snap.status == :partial, snap.failures ==
#    [%{reason: :missing_position_side, symbol: "BTC/USD:BTC", component: :positions, ...},
#     %{reason: :missing_position_side, symbol: "ETH/USD:ETH-260925-2700-P", ...}]
# obwohl domain.components.positions status: :ok hat und beide Positionen size 0.0 sind.
```

Expected: eine `direction: "zero"`-Position ist *flat* — entweder soll `fetch_positions` sie
gar nicht als offene Position emittieren, oder `PortfolioRisk` soll zero-size-Positionen als
flat behandeln statt `:missing_position_side` zu melden. Konsument-Repro: trading_dashboard
`test/integration/risk_portfolio_margin_integration_test.exs` (pinnt `status: :complete`, rot
seit das Testnet-Konto geschlossene Positionen trägt).

**Status (2026-08-14, später):** ✅ **fixed downstream** — bourse_trading main `1b30a24`
(„fix(portfolio_risk): treat flat positions (contracts == 0) as no exposure, not missing side"):
`Exposure.position_lot/3` liefert bei `contracts == 0` (int wie float) `{:ok, []}`;
`:missing_position_side` feuert nur noch bei `contracts != 0` und fehlender `side`. Live gegen
das Deribit-Testnet verifiziert (vorher `:partial` mit zwei Failures auf den flachen Rows,
nachher `:complete` mit leeren `failures`, inkl. Mischzustand echte Long + flache Option-Row).
Client-seitig bleibt alles unverändert — die Carve unten war korrekt.

**Status (2026-08-14):** 🔀 **triaged — not a client defect; fix routed to bourse_trading (PortfolioRisk).**
`side: nil` + `contracts: 0.0` für flache Positionen ist die etablierte Cross-Venue-Carve, kein
deribit-Sonderfall: derive und lighter authoren `sign_direction` explizit mit `"zero": null`, und
die binance-Familie leitet `side` aus dem `positionAmt`-Vorzeichen ab (Zero → `nil`,
`binance_position_side/1` in `Bourse.Unified.ReadParse`). Flache Rows client-seitig zu filtern
würde provider-emittierte Information löschen und die public Surface ändern — abgelehnt.
Empfohlener Downstream-Fix: `PortfolioRisk` behandelt `contracts == 0` als *flat*;
`:missing_position_side` nur bei `contracts != 0` und fehlender `side`. An den
bourse_trading-Orchestrator gemeldet (Session-Message, 2026-08-14). Hinweis dorthin: seit Task
610 (heute gelandet, unreleased) sind deribit-Future-`contracts`/`contract_size` ohne
`load_markets` `nil` — Exposure-Math, das `contracts` liest, braucht geladene Markets.

## 2026-08-14 — deribit `createOrder`: caller-supplied `trigger`-Selektor wird beim Request-Shaping verworfen

**Method:** `Bourse.create_order(ex, "BTC-PERPETUAL", "stop_market", "sell", qty, trigger_price: X, trigger: "index_price")` · **Exchange:** deribit · **Severity:** medium (Stop/Take-Order landet mit falschem Trigger-Referenzpreis statt dem angeforderten)

Die authored Deribit-Spec (`priv/specs/json/output/authored/deribit.json`) definiert
`endpoints.request.defaults.createOrder.trigger` als **Conditional**, das `last_price` nur
emittiert, wenn `trailingAmount` gesetzt ist. `RequestShape.put_authored_conditional/4`
**löscht** dadurch einen explizit vom Caller übergebenen `trigger` (z. B. `"index_price"`),
obwohl Deribit `trigger` auf Stop-/Take-Orders verlangt (docs.deribit.com `private/buy`,
Param `trigger`: `index_price | mark_price | last_price`).

Expected: ein caller-supplied natives `trigger`-Feld überlebt das Shaping (Passthrough oder
Conditional-mit-Caller-Präzedenz); das Conditional darf nur den *Default* stellen, nie einen
expliziten Wert verwerfen.

Konsument-Workaround (trading_dashboard, Task 54): `OrderPlacement.@venue_request_shape_supplements`
re-authort den Eintrag als `native_passthrough`-Reference vor dem Dispatch
(`lib/trading_dashboard/exchange/order_placement.ex`); live gegen Deribit-Testnet verifiziert —
mit Supplement erreicht die Trigger-Order Deribits Business-Logik (echte `10035
trigger_price_too_low`-Rejection), ohne Supplement kommt der Selektor nie an. Der Workaround
kann raus, sobald bourse den Fix shippt.

**Status (2026-08-18):** ✅ fixed — task 615 shipped caller-wins conditionals.
`put_authored_conditional/4` keeps a caller-supplied native key when no authored
case matches. Live testnet: the same `stop_market` + `trigger: "index_price"` call
that used to die as `-32602 trigger is required` now reaches Deribit business
logic (`10035 trigger_price_too_low` on a buy-stop at 1; a sell-stop at 1 was
accepted with `info["trigger"] == "index_price"` and cancelled). Matching cases
still rewrite (trailingAmount → `last_price` / `trailing_stop`).

**Status:** 🔀 triaged 2026-08-14 — bestätigter Client-Defekt. Mechanismus verifiziert per
Code-Read: `RequestShape.put_authored_conditional/4` (lib/bourse/unified/request_shape.ex:379)
prüft nie, ob der Caller den nativen Key bereits gesetzt hat — ohne matchenden Case und ohne
`source`/`default` löscht der `is_nil`-Zweig den Caller-Wert (`Map.delete`), mit matchendem
Case überschreibt `Map.put` ihn. Klassen-Scope: sieben authored Conditionals über fünf Venues;
deribit `createOrder.trigger` ist die einzige source-lose und die live-verifizierte Instanz.
Fix als Task 615 gefiled (caller precedence: Conditional stellt nur den Default), assignee
grok/grok-4.6, bundle live_triage.

## 2026-08-14 — binance `Bourse.WS.watch_order_book/3`: generierter Channel liefert nie Frames

**Method:** `Bourse.WS.watch_order_book/3` (Channel-Extraktion `Bourse.WS.Channels.build/4`)
**Exchange:** binance · **Severity:** hoch (Default-Orderbuch-Stream still tot)

`Channels.build/4` produziert für das Binance-Orderbuch den internen Cache-Key
`orderbook:btcusdt` als Subscription-Channel. Der Socket akzeptiert die Subscription
kommentarlos — es kommt aber nie ein Frame an: der still tote Stream ist die schlimmste
Fehlerklasse (kein Error, keine Daten). Eine provider-owned Subscription
(`btcusdt@depth20@100ms`, Binance partial-depth) liefert sofort komplette 20×20-Book-Frames.

Expected: `watch_order_book/3` emittiert ohne caller-supplied `subscribe_payload` einen
provider-nativen partial-depth- oder diff-depth-Stream; ein Integrationstest pinnt den
Default-Pfad (Frame kommt an) und das Provider-Rejection-Verhalten.

Konsument-Workaround (trading_dashboard, Task 68): der Orderflow-Transport subscribed den
provider-owned `depth20@100ms`-Stream direkt statt über die generierte Channel-Extraktion
(`lib/trading_dashboard/market_data/transport/local.ex`); live gegen Binance verifiziert
(Reviewer-Run run-1786673501096-c9939b07). Der Workaround kann raus, sobald bourse den
Default-Channel fixt.

**Status (2026-08-18):** ✅ **fixed** by task 618 (delivery commit
`8dc570a`, harness run `run-1787019715121-97bb4904`). Default `watch_order_book/3` now builds the
provider partial-depth stream `{symbol}@depth20@100ms` (`btcusdt@depth20@100ms`
for `BTC/USDT`) on binance and binanceusdm. The four `watch_*` defaults were
audited against the venue stream docs; leftover hashes
(`orderbook::{symbol}`, `trade::{symbol}`, `myLiquidations::{symbol}`,
`:{symbol}`, bare `miniTicker`/`kline`/`name`) are gone. Live
frame-delivery tests in `test/bourse/ws/binance_watch_frame_delivery_test.exs`
pin a book frame on both venues — subscribe-ack is not treated as evidence.
The trading_dashboard `depth20@100ms` workaround can be retired after this
lands. binancecoinm still authors no channel table and fails loud with
`:no_channel_templates`.

**Status:** 🔀 triaged 2026-08-14 — bestätigter Spec-Authoring-Defekt, Klasse statt Einzelfall.
binance authored kein `watchOrderBook`; der `Channels.build/4`-Fallback greift auf
`watchOrderBookForSymbols` mit dem Template `orderbook::{symbol}` — ein CCXT-interner
Message-Hash, kein Binance-Stream-Name (`collapse_separators/1` faltet `::` zu `:`).
Klassen-Scope: binance und binanceusdm tragen ebenso `trade::{symbol}`,
`myLiquidations::{symbol}`, `:{symbol}` und bare `miniTicker`/`kline`/`name`; binancecoinm
authored `channels: null` (fällt wenigstens laut mit `:no_channel_templates`). Weil Binance
unbekannte Stream-Namen stumm ackt, ist Subscribe-Ack keine Evidenz — der Fix verlangt
Frame-Delivery-Tests. Als Task 618 gefiled (Audit aller vier watch_*-Defaults gegen die
provider-owned Stream-Doku, grok/grok-4.6, bundle live_triage).

## 2026-08-17 — deribit: `client_order_id` fährt raus als `label`, kommt aber nie zurück (asymmetrische Normalisierung)

**Method:** `Bourse.create_order(ex, "BTC/USD:BTC", "market", "buy", qty, params: %{"label" => id})` bzw. `clientOrderId`; danach `Bourse.fetch_my_trades/2` · **Exchange:** deribit (testnet) · **Severity:** medium (jeder Consumer, der eigene Orders über eine selbstvergebene Id wiedererkennen muss, fällt auf `info`/`raw_call` zurück)

**Status (2026-08-18):** 🔀 triaged — bestätigter Defekt, als **Klassen-Invariante** gefiled statt als deribit-Patch: workbench **task 622** (cursor/cursor-grok-4.6-high, bundle `live_triage`). Ein Venue darf einen Client-Identifier in **beide** Richtungen oder in **keine** mappen; einseitiges Mapping lässt einen venue-übergreifenden Test rot werden. Precedent: task 473 hat genau diese Defektform 2026-07 auf Derives *Request*-Seite gepatcht, die deribit-Instanz tauchte vier Monate später auf der anderen Seite desselben Round-Trips auf.

*Korrektur einer Prämisse des Reports:* `lib/bourse/unified/request_shape/derive.ex` ist der Shaper der Venue **Derive**, nicht deribits. Deribit hat **auch request-seitig** kein `clientOrderId`→`label`-Mapping (Spec-Read 2026-08-18: `normalization.field_maps.order`/`.trade` tragen keinen `client_order_id`-Eintrag, und die einzige Rückabbildung überhaupt ist binances synthetisches `_bourse_client_order_id`, `read_parse.ex:3205`). Der Live-Call funktionierte nur, weil er natives `params: %{"label" => id}` durchgereicht hat — beide Richtungen sind unauthored und beide sind in 622 in scope.

Die **Request**-Seite ist korrekt: `RequestShape.Derive` mappt unified `clientOrderId` auf
Deribits natives `label` (`lib/bourse/unified/request_shape/derive.ex:166-173`, Kommentar
sagt es explizit). Die **Response**-Seite mappt nicht zurück: der geparste `%Bourse.Order{}`
kommt mit `client_order_id: nil`, obwohl `order.info["label"]` den Wert trägt, und die
Trade-Rows aus `private/get_user_trades_by_instrument` führen `label` ohne jedes
`client_order_id`-Feld. In `lib/bourse/unified/read_parse.ex` existiert ein synthetisches
`_bourse_client_order_id` nur für binance (`clientOrderId`/`clientAlgoId`, Zeile 3205) —
für deribit gibt es kein Gegenstück.

Live beobachtet 2026-08-17 auf test.deribit.com: eine gelabelte Market-Order liefert
`%Order{client_order_id: nil}` mit `order.info["label"] == label`, und der zugehörige
private Fill trägt `trade["label"] == label` bei `refute Map.has_key?(trade, "client_order_id")`.

Expected: was bourse als `clientOrderId` rausschickt, kommt auf Order **und** Fill als
`client_order_id` zurück — sonst ist der unified Roundtrip venue-abhängig gebrochen und die
Abstraktion trägt genau dort nicht, wo sie gebraucht wird.

Konsument-Workaround (trading_dashboard, Task 126): der MM-Journal korreliert Session-Fills
auf das rohe `label`-Feld statt auf den normalisierten Struct; die beobachtete Shape ist in
`test/integration/market_making_hedge_fill_payload_integration_test.exs` gepinnt. Kann raus,
sobald bourse zurückmappt.

## 2026-08-17 — binanceusdm `fetchMarkets`: lineare Kontrakte verlieren die kanonische Contract-Size

**Method:** `Bourse.load_markets/2` / `Bourse.fetch_markets/2` · **Exchange:** binanceusdm ·
**Severity:** hoch (Money-/Margin-Consumer können lineares Order-Notional nicht aus
provider-eigenen Contract-Facts ableiten)

**Status (2026-08-18):** ✅ fixed — task 623 shipped `markets.contract_unit` on binanceusdm (`linear` constant `1`, `quantity_unit: "base"`). Recorded `fetch_markets` and a live fapi/dapi probe pin `BTC/USDT:USDT` at `contract_size: 1` while COIN-M `BTC/USD:BTC` stays at the provider `contractSize` 100. A market whose venue states no unit stays nil; a declared recipe with a missing or non-positive value fails loud. C-T623a records the provider sources. Residual: the sweep still names `binance` (umbrella FAPI fan-out), `bybit`, and `derive` as known nil-gaps — filed as workbench **task 625**.

*Triage (same day, before the land):* bestätigt und als workbench **task 623** gefiled (grok/grok-4.6, bundle `live_triage`). Spec-Read 2026-08-18: binanceusdm *und* binancecoinm mappen `market.contractSize` vom Venue-Key `"contractSize"` ohne Fallback — COIN-M veröffentlicht ihn, USD-M nicht, also landet er per Konstruktion `nil`.

Verschärfend: das Repo widerspricht sich bereits selbst. Carve **C-T334a** (`docs/authored-spec-carves/binanceusdm.md`) hält fest, lineares `contract_size` *sei* die Unit-Size des geladenen Marktes (1 für BTCUSDT) — die USD-M-Positions-Semantik ist also auf ein Market-Fact authored, das `fetchMarkets` nie befüllt. Der Task löst den Widerspruch, statt eine Seite zu patchen.

*Nicht* als Parse-Layer-Default: task 397 hat die Gegenregel gelandet ("unknown or missing multiplier and amount semantics fail loudly instead of defaulting to one"), und ein hartkodiertes 1 ist genau die Domain-Konstanten-Falle, in der ein mit derselben Annahme berechnetes Golden den Bug ratifiziert. Die Unit kommt aus Binances eigener USD-M-Kontraktspezifikation, wird in der authored Spec deklariert und als Carve verbucht.

Live beobachtet gegen `GET https://fapi.binance.com/fapi/v1/exchangeInfo` mit bourse 0.4.0:
`BTC/USDT:USDT` wird als `%Bourse.Market{contract: true, linear: true, inverse: false}`
normalisiert, aber `contract_size` bleibt `nil`. Binance USD-M führt Order-`quantity` in
Base-Asset-Einheiten und veröffentlicht anders als COIN-M kein `contractSize`-Feld; die
kanonische lineare Contract-Size ist daher 1. Der Gegencheck über binancecoinm ist korrekt:
`BTC/USD:BTC` kommt als inverse mit `contract_size: 100`, direkt aus dem provider-owned
`contractSize`-Feld.

Expected: `fetchMarkets` normalisiert lineare Binance-USD-M-Märkte mit
`contract_size: 1` (und idealerweise der passenden Quantity-Unit), während COIN-M weiterhin
die venue-eigene `contractSize` übernimmt. Ein Live-Test sollte beide Oberflächen gemeinsam
pinnen, damit lineares `quantity * price` und inverses `contracts * contract_size` sichtbar
verschieden bleiben.

Konsument-Handling (trading_dashboard, Task 131): `ContractNotional.from_market/2` behandelt
den bestätigten binanceusdm-Nil-Fall innerhalb der bestehenden Contract-Fact-Grenze als
Größe 1; alle anderen fehlenden/unbrauchbaren Größen bleiben fail-closed. Kann raus, sobald
bourse die Normalisierung shippt.

## 2026-08-18 — signierte Requests werden bei Retry nicht neu signiert: transienter 408 wird zu `authentication_error`

**Method:** `Bourse.Http.signed_request/4` (jeder private Read über `Bourse.Dispatch`) ·
**Exchange:** binanceusdm bestätigt, betrifft jede Venue mit Timestamp-Fenster ·
**Severity:** hoch (Money-Path: ein Bracket-Guard-Reconcile scheitert dauerhaft, und die
Fehlerklasse zeigt auf die falsche Ursache)

**Status (2026-08-18):** ✅ fixed — task 621 shipped re-sign-on-retry. Dispatch
passes a resigner into `HTTP.signed_request/5`; a request step refreshes
timestamp, nonce, and deadline before every repeated attempt. Injected-408 tests
pin a fresh Binance query `timestamp` and a fresh Deribit nonce on the second
try, and pin that exhausted retries return the original 408 (`:network_error`)
rather than a follow-on recv-window rejection. The already-signed
`HTTP.signed_request/4` path is single-attempt.

*Triage (same day, before the land):* bestätigt und als workbench **task 621**
gefiled (codex/gpt-5.6-sol, bundle `live_triage`, D6/B9/U7). Mechanismus per
Code-Read: `dispatch.ex` signierte einmal und reichte das eingefrorene
`signed`-Struct an `Http.signed_request/4` mit `retry: Defaults.retry_policy()` —
Req wiederholte die vorbereitete Anfrage ohne neue Signatur.

Klassen-Scope statt Binance-Fix: jede Venue, deren Signatur Timestamp, Nonce oder Deadline abdeckt, ist gleich exponiert (Binance-Familie, bybit, okx, deribit, hyperliquid, derive, lighter). Der Fix sitzt an der Signing/Dispatch-Grenze, und die Acceptance Criteria verlangen den Nachweis über **zwei** Signing-Patterns (query-signiert *und* nonce/deadline-basiert), damit er nicht binance-förmig ausfällt.

Zum zweiten Teil (die Fehlerklasse lügt): die Klassifikation von `-1021` ist auf `main` bereits gesplittet — **task 604** (shipped `1a3a386b1418`) gibt InvalidNonce den eigenen Typ `:invalid_nonce` mit `retry_class :network`. Der Report beobachtet das released 0.4.0-Verhalten von vor 604. Was offen bleibt und in 621 steckt: nach erschöpften Retries darf die Folge-Ablehnung gar nicht erst der terminale Fehler sein — der Caller muss den 408 sehen.

`Bourse.Signing.sign/4` baut `timestamp` und `signature` in die URL, bevor
`Http.signed_request/4` sie an Req übergibt — und zwar mit
`retry: Defaults.retry_policy()` (`:safe_transient`). Req wiederholt bei 408/429/5xx
**dieselbe vorbereitete Anfrage**; Timestamp und Signature sind zu diesem Zeitpunkt
eingefroren. Mit Reqs exponentiellem Default-Backoff liegt der letzte Versuch rund 7 s
nach dem Signieren und damit außerhalb von Binance' Default-`recvWindow` von 5000 ms.

Live beobachtet 2026-08-17/18 gegen `fapi.binance.com` (trading_dashboard, BracketGuard,
22-s-Takt). Logsequenz pro Zyklus, wörtlich:

    [warning] retry: got response with status 408, will retry in 905ms, 3 attempts left
    [warning] retry: got response with status 408, will retry in 1986ms, 2 attempts left
    [warning] retry: got response with status 408, will retry in 3753ms, 1 attempt left
    -> ** (Bourse.Error) [binanceusdm] authentication_error: Timestamp for this request
       is outside of the recvWindow

Der lokale Clock-Skew war zur selben Zeit 29 ms (`GET /fapi/v1/time` gegen
`System.system_time(:millisecond)`), das Zeitfenster ist also nicht das Problem — der
Retry ist es. Reproduzierbar über drei aufeinanderfolgende Reconcile-Zyklen: jeder endet
identisch, die Ladder erholt sich nie von selbst.

Expected: ein Retry einer signierten Anfrage wird vor jedem Versuch **neu signiert**
(frischer Timestamp, neue Signature), oder signierte Anfragen mit Timestamp-Fenster werden
gar nicht von Req retried und bourse macht den Retry selbst über `Signing.sign/4`.
Ein Live-Test sollte einen 408 auf einem signierten GET injizieren und pinnen, dass der
zweite Versuch einen anderen `timestamp`-Query-Parameter trägt als der erste.

Zweiter, eigenständiger Teil des Defekts: die Fehlerklasse lügt. Ein transienter
Netzwerk-Timeout kommt beim Konsumenten als `authentication_error` an, was einen Operator
zu den API-Keys schickt statt zur Netzwerkstrecke. Selbst mit Re-Signing sollte der
finale Fehler nach erschöpften Retries den 408 nennen, nicht die Folge-Ablehnung.

Konsument-Handling (trading_dashboard): keines — der Befund ist unverfälscht, der Guard
schreibt den Venue-Fehler unverändert nach `OrderLadder.last_error`. Die
Sichtbarkeitslücke auf Konsumentenseite (eine Ladder bleibt auf `protecting`, während
jeder Reconcile scheitert, ohne dass etwas alarmiert) wird dort getrennt gefilet.

> **Update 2026-08-18 — Kausalität eingeschränkt, Defekt bleibt.** Die oben zitierte
> Logsequenz ist echt, taugt aber **nicht** als Beweis dafür, dass der Retry diesen
> Vorfall verursacht hat. Eine Parallelmessung mit abgeschaltetem Retry
> (`Application.put_env(:bourse, :retry_policy, false)`, sofort zurückgesetzt) zeigt: die
> Binance-Futures-**Testnet**-Account-Plane antwortet schon beim ersten Versuch fehlerhaft
> — `fetch_open_orders` → HTTP 400 / `-1000 unknown error`, `fetch_positions` und
> `fetch_balance` → `-1021`. Clock-Skew zur selben Zeit: Testnet −8 ms, Mainnet −9 ms bei
> 380 ms RTT; beide Public-Endpoints 200. Ein `-1021` ohne Retry und ohne Uhr-Abweichung
> ist venue-seitig, nicht client-seitig — die Venue war während der Beobachtung selbst
> gestört. Der Retry hat diesen Ausfall folglich nicht erzeugt, sondern **verdeckt**: er
> ersetzt die Ursache des ersten Versuchs durch die Ablehnung des letzten.
>
> Der eigentliche Defekt steht unverändert, weil er aus dem Quelltext folgt und keine
> Venue-Beobachtung braucht: `signed_request/4` reicht eine fertig signierte URL an Req
> mit `retry: :safe_transient`, und Req wiederholt dieselbe Anfrage mit eingefrorenem
> Timestamp. Belastbarer Regressionstest deshalb ohne echte Venue: einen 408 auf einem
> signierten GET injizieren und pinnen, dass der zweite Versuch einen anderen
> `timestamp`-Query-Parameter trägt als der erste.
