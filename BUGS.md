# Bourse — Bug Reports

The inbound queue for defects consumers of this library hit. File here — this is the only
repository a consumer needs to know. Each entry: the call, observed vs. expected, a repro,
and consumer impact. Newest first.

Triage runs in this repository: operator-routed work becomes a scored task in
`roadmap/tasks.toml`, and the entry gets a dated note pointing at it. Entries are never deleted — they are the
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
> **Authority order when reconciling:** a live call against the venue first, then the
> roadmap's landed tasks; the dated sweep banners below are point-in-time snapshots that go
> stale. The 2026-07-25 pass mis-marked the lighter entry by trusting the 2026-07-15 banner
> over the then-current state — see the Correction on that entry.

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

> **Class carve of the open entries (2026-08-28, orchestrator).** All 24 open entries were
> read end to end and grouped by *mechanism*, because a per-entry reading produces
> instance-shaped tasks. Worked evidence that this is the failing mode here: 658 -> 660
> ("still ... after the 658 pass-through") -> 661, three tasks on one symbol class, plus the
> bybit dated-contract entry below as a fourth instance still open. Same shape at 664 (the
> instance) -> 666 ("derived per venue with no shared rule" — the class, filed *after* the
> instance shipped). The six classes, with the entries each covers:
>
> 1. **Raten statt scheitern (Substitutionsklasse)** — the code silently substitutes a guess
>    where the authored slice or the payload does not fit: OKX `fallback_keys` yielding a
>    `billId` instead of `nil`; the spec loader dropping alpaca's unrecognised
>    `errors.status_map` shape; `HmacRecipe`'s canonical-string ladders picking a block by map
>    order; the `notional_currency` guard `:halt`ing a whole fold on one bad row. Deliverable
>    is the manifest-wide gate, not four patches.
> 2. **Der unified Read gibt weniger zurück als der Payload** — field never fills (binance
>    `updateTime`, binancecoinm ADL list collapsed, bybit funding-balance envelope, deribit
>    `implied_volatility`) and route never reaches the venue (okx/binanceusdm algo branches,
>    bybit classification helpers in the balance indices, deribit's USDC-settled option book,
>    the missing numeric slot in `fetch_account_facts`). Natural seam if the diff is too large
>    to review: field-fills-not / route-hits-not — never per venue, which collides in
>    `lib/bourse/unified/read_parse.ex` (6 191 lines, the shared surface of all of them).
> 3. **Die Gates lügen** — `bourse.check_lighter_signer` exits 0 printing "NOT RUN"; the live
>    suite cannot distinguish a ledgered deliberate red from a genuine failure (incl. the raw
>    branch reporting "none of the semantic keys" when it means zero rows); `spec_disk_test`
>    pins pre-rotation hashes and reds on a clean tree; fourteen contract cases are green only
>    while hand-made account state exists.
> 4. **`Bourse.Symbol`** — non-injective `reverse_aliases/1`, the `:aliases` substring rewrite,
>    dated-future ids, and the three surfaces where the docs and the code already disagree.
> 5. **Request-Pacing und Signaturreihenfolge** — burst depth, the unbounded ~60 s pre-request
>    sleep, sign-before-throttle, and the ignored authored `recv_window`. Stays alone: needs a
>    model decision and live proof on all eleven venues.
> 6. **Transport-Ehrlichkeit** — `WS.connect/3` returning an open unauthenticated private
>    socket, bybit's `watchOrders` template pointing at a topic the venue does not serve, and
>    okx's outer batch `code "1"` masking the real `sCode`.
>
> **Routed 2026-08-28 (operator: all six).** One task per class, so the next instance of a class
> lands in the task that owns it instead of spawning a sibling: **685** substitution ·
> **686** unified read · **687** the gates · **688** `Bourse.Symbol` · **689** pacing and signing
> order · **690** transport honesty. Each open entry above carries its task id on its `**Status:**`
> line. Two live siblings were checked rather than duplicated: **563** (derive WS auth, superseded,
> hand-build because the handshake was unobserved — now live-verified, so 690 carries it) and
> **670** (the fixture-oracle deletion and gate flip, which 687 stays out of).

---

## 2026-09-15 — `limit` on hyperliquid's emulated order-status reads truncated the history BEFORE the status filter ran, so `fetch_closed_orders(limit: 10)` answered `[]` while 137 closed orders existed

**Status:** ✅ fixed inline (orchestrator, landed-base review) — `lib/bourse/emulation.ex`,
live-proven against hyperliquid testnet. Regression test:
`test/live/hyperliquid/emulated_order_status_limit_test.exs`.

Hyperliquid carries the only three `_delegate` entries in the authored surface —
`fetchClosedOrders`, `fetchCanceledOrders` and `fetchCanceledAndClosedOrders` all delegate to
`fetchOrders`. `Bourse.Emulation.handle_fetch_filtered_orders/5` extracted `since`/`limit`
to apply them locally after `filter_by_status/2`, but did **not** declare them consumed in
`@consumed_delegated_params`, so `delegated_params/4` forwarded them to the delegate as well.
`Bourse.Unified.ReadParse.maybe_take_limit/3` then applied `limit` at the delegate's parse
layer, cutting the raw order history down to the newest N rows *before* the status filter
ever saw it. The wallet's newest rows are `open`/`canceled` lifecycle events, so the closed
filter found nothing in them.

**Repro on the landed base** (`c73e031`), hyperliquid testnet:

```elixir
{:ok, h} = Bourse.Exchange.new("hyperliquid", credentials: creds, sandbox: true)
Bourse.fetch_closed_orders(h)            #=> {:ok, [137 orders]}
Bourse.fetch_closed_orders(h, limit: 10) #=> {:ok, []}      # expected 10
```

A caller asking for "the last 10 closed orders" got a silently empty list — the answer is
well-formed, plausible, and wrong, with no error to notice. `fetch_canceled_orders` and
`fetch_canceled_and_closed_orders` share the handler class and the same defect.

> **Update (2026-09-15, orchestrator).** Fixed by declaring `since` and `limit` consumed for
> `{:handle_fetch_filtered_orders, :fetch_orders}` and
> `{:handle_fetch_canceled_and_closed_orders, :fetch_orders}`, so the delegate returns the
> full history and the window is applied once, locally, after the status filter. Hyperliquid's
> `fetchOrders` authors no `limit`/`since` request slot (its request defaults are `type` +
> `user` only), so nothing server-side is lost. Live after the fix: `limit: 10` → 10 closed
> orders, all `status == "closed"`, matching the newest 10 timestamps of the full 137;
> `since: <median>` → 69 rows all `>= since`, and `since` + `limit: 5` → the 5 oldest in that
> window; `fetch_canceled_orders(limit: 5)` → 5, `fetch_canceled_and_closed_orders(limit: 7)`
> → 7. The contract case `hyperliquid:fetchClosedOrders:0:publicPostInfo`, red on the landed
> base as "provider account/market state did not exercise the read", now passes — its failure
> message had been blaming account state for a client bug.
>
> **Latent siblings, deliberately not changed.** `handle_fetch_my_trades/4`,
> `handle_fetch_order_trades/4` and `handle_fetch_deposits_withdrawals/4` have the same shape
> (extract `since`/`limit` locally, forward the untouched params to a delegate, filter after).
> No venue routes to them today — hyperliquid's three are the only `_delegate` entries in all
> eleven authored documents — so there is no live evidence to fix against, and inventing it
> would be guessing. They become real the moment a venue delegates one of those methods.

---

## 2026-09-15 — every venue's contract `symbols.option` names a non-option symbol, so each option branch is proven against an arbitrarily-picked illiquid strike

**Status:** 🆕 measured live (orchestrator, landed-base review) — not routed.

`Bourse.Test.RestReadContractScenario.market_symbol!/2` prefers
`venue_contract["symbols"][kind]`, then falls back to the first active market whose symbol
starts with `BTC`. All eleven `priv/venues/<venue>/authority/rest_read_contract.json` files
declare an `option` slot that is a swap or spot symbol — okx `BTC/USDT:USDT`, deribit
`BTC/USD:BTC`, bybit `BTC/USDT:USDT`, alpaca `GLD`, and so on — so no option market ever
matches the preference and every option branch runs against whichever BTC option happens to
sort first. That instrument is usually an untraded strike.

**Live evidence** (2026-09-15, okx demo, `x-simulated-trading: 1`):
`okx:fetchTrades:2:publicGetPublicOptionTrades` fails as "provider account/market state did
not exercise the read", yet the venue is actively trading options —
`GET /api/v5/public/option-trades?instFamily=BTC-USD` returns 100 fills across 30 distinct
instruments, and a per-instrument query returns 100 rows for `BTC-USD-260925-100000-C`, 9 for
`BTC-USD-260916-73000-P` and 3 for `BTC-USD-260916-72000-P`. The branch is reachable; the
case just picks an instrument nothing has traded.

**Why pinning a symbol does not fix it:** option instruments expire, so any literal written
into the contract file goes stale on a schedule and lands back here. The durable shape is a
selection strategy that picks a *traded* option instrument — but `market_symbol!/2` is shared
by all eleven venues and every market kind, so changing it is a whole-lane change, not a
one-line correction. That is the routing question.

**What this masks:** an option branch that is genuinely broken is indistinguishable from one
that drew a dead strike, because both report the same "did not exercise the read" message.

---

## 2026-09-15 — swapping the DEX signing primitives onto Cartouche/Hieroglyph moved keccak and secp256k1 off Rust NIFs onto pure Elixir, costing ~50x more CPU per signed request

**Status:** 🆕 measured live (orchestrator, landed-base review of task 703, shipped
`434c97988d6a`) — not routed. The migration is **correct**: hyperliquid and derive both
accept the new signatures live, so this is a cost finding, not a correctness one.

Task 703 replaced `ex_keccak` (Rust NIF) and `ex_secp256k1` (Rust NIF) with `cartouche`,
whose transitive hashing and curve dependencies — `ex_sha3` and `curvy` — are pure Elixir.
No acceptance criterion named performance and no per-task reviewer could see it: every
live journey passes, only the clock changed.

**Measured on this host against the landed base (Tidewave `project_eval`, warm BEAM):**

```
Crypto.sign_hash/2                    2.788 ms each   (50 iterations)
Crypto.recover_signer_address/2       2.030 ms each   (50 iterations)
Crypto.keccak256/1, 32-byte input     181.96 us each  (2000 iterations)
Crypto.keccak256/1, 128-byte input    197.25 us each
Crypto.keccak256/1, 1024-byte input   1344.32 us each
EIP712.encode/4 (Agent, 2 fields)     1.032 ms each   (200 iterations)
one signed hyperliquid order preimage 5.657 ms each   (200 iterations, encode + keccak + sign)
```

The `ex_keccak` / `ex_secp256k1` NIFs they replaced are single-digit microseconds for
keccak and well under 100 us for a sign, so signing one DEX order went from roughly a
tenth of a millisecond to **~5.7 ms** — and it is synchronous scheduler time in the caller
process, not dirty-NIF work that yields.

**Consumer impact.** Every hyperliquid, derive and lighter-L1 write pays it: order place,
order cancel, and each WebSocket auth handshake. A consumer placing or amending orders at
rate (`bourse_trading`'s saga executor, any market-making loop) burns ~50x the CPU per
order and blocks a scheduler for milliseconds at a time. A single order is still fast next
to venue latency; a burst is not.

**The routing question is a dependency decision, not a local fix**, which is why this is
recorded rather than patched: re-adding `ex_keccak` for `Crypto.keccak256/1` alone would
only recover the hashing our own code does — `Cartouche.Typed` hashes internally through
`ex_sha3` regardless — and would partially undo 703's own "no duplicated replacement
implementation" criterion. The choices are (a) accept the cost, (b) ask the Cartouche
maintainers for a NIF-backed hash/curve backend, or (c) carve the hot path back onto NIFs
and say so in the criterion. Not ours to pick.

---

## 2026-09-15 — 23 authored WebSocket `watch*` channel entries across seven venues name methods the client has no function for

**Status:** 🆕 measured live (orchestrator, landed-base review of task 702, shipped
`c18a0a7bd16d`) — not routed.

`Bourse.WS.Channels` dispatches exactly four unified methods plus three fallbacks, so every
other authored `websocket.subscribe.channels` key answers `{:error, :unsupported_method}`
before the template is read — which means task 702 corrected two channel strings nothing can
send (bybit `watchLiquidations`, `watchOHLCVForSymbols`) and left CCXT message hashes in
entries it did not touch (bybit and hyperliquid `watchMyTrades` both carry `":{symbol}"`).
Routing is a choice between trimming the authored set to what the client can dispatch and
adding the missing `watch_*` methods; either way the next confrontation pass repeats this one
until one of them is picked.

---
## 2026-09-15 — the bybit funding-rate contract compared two separate live reads of a moving number at `1.0e-12`, so it went red on the venue's own drift

**Status:** ✅ fixed 2026-09-15 inline (post-merge audit of `79e57bd`).

`test/live/bybit/bybit_authored_integration_test.exs:411` read `fundingRate` from
`GET /v5/market/tickers`, then called `Bourse.fetch_funding_rate/2`, and asserted the two
agreed to `1.0e-12`. That field is the **predicted** next funding rate and it moves
continuously, so the assertion was grading venue drift, not the parse. Observed in the cold
`mix check.dispatch` run on this range:

```
Expected the difference between 1.3943e-4 and 1.4487e-4 (5.439999999999975e-6)
to be less than or equal to 1.0e-12
```

Five orders of magnitude above the tolerance, seconds apart. The automatic retry passed, so
it surfaced as `flaky` rather than as a failure — which is exactly how a latent live-lane
flake stays invisible.

**The fix keeps the assertion's real intent.** The test now takes a *second* raw sample
after the unified call and asserts the unified rate falls within `[min, max]` of the two
raw observations. A wrong field or a scale error still fails hard (those differ by orders
of magnitude); the venue's own drift between two HTTP calls no longer can. Re-run green:
`mix test.json test/live/bybit/bybit_authored_integration_test.exs:411` — 1 passed.

---

## 2026-09-15 — `fetch_open_orders` and `fetch_orders` on binanceusdm resolve to the ALGO book by default, so a resting limit order is invisible to a consumer that asks for its open orders

**Status:** 🆕 measured live (orchestrator, landed-base gate run on `44edfaa`) — not
consumer-reported. · **Unrouted, awaiting the operator's routing decision.**

The calls, against `demo-fapi.binance.com` with the shared futures demo key:

```elixir
{:ok, ex} = Bourse.Exchange.new("binanceusdm", credentials: creds, sandbox: true)

Bourse.fetch_open_orders(ex, symbol: "BTC/USDT:USDT")
#=> {:ok, [%Order{id: "1000000206015819", type: "stop_market",
#           info: %{"algoId" => 1000000206015819, "clientAlgoId" => "QRrtElg3vDTvHwyCx9qJfe"}}]}

Bourse.fetch_open_orders(ex, symbol: "BTC/USDT:USDT", endpoint_index: 2)  # fapiPrivate_get_openalgoorders
#=> the same single algo row

Bourse.fetch_open_orders(ex, symbol: "BTC/USDT:USDT", endpoint_index: 3)  # fapiPrivate_get_openorders
#=> {:ok, []}
```

The default and the explicit algo index return byte-identical results, and the returned row
carries `algoId` with no `orderId` — so the unqualified read is served by
`GET /fapi/v1/openAlgoOrders`, the conditional/algo book, not `GET /fapi/v1/openOrders`.
`fetch_orders` has the same shape: index 2 is `fapiPrivate_get_allalgoorders`, index 3 is
`fapiPrivate_get_allorders`, and the default takes the lower index.

**Consumer impact, and why it is worse than an empty list.** A caller asking "what are my
open orders?" on USD-M is answered from a book that does not contain ordinary limit orders.
A resting GTC limit reads as *absent*, so a consumer polling for its own fill, reconciling
an order it just placed, or deciding whether to re-place, is told the order is gone. The
list is non-empty and well-formed, so nothing anywhere signals that a different book was
read — this is the same substitution class as task 685, one level up: not a wrong field
inside a row, but the wrong book behind a whole read.

**What is already fixed, and what is not.** The REST-read contract cases for
`binanceusdm:fetchOpenOrder:2:fapiPrivateGetOpenOrder` and
`binanceusdm:fetchOrder:2:fapiPrivateGetOrder` inherited an *unpinned* top-level
`id` argument, so they drew their resource id from whatever the default read returned —
an `algoId` — and then handed it to the regular-book endpoint, which answered
`order_not_found: Order does not exist.` Both branches now pin
`source_endpoint_index: 3`, the regular book, so the case owns a real resting limit order
and proves the route it claims to prove (61/61 green on
`test/live/binanceusdm/rest_read_contract_test.exs`). **That repairs the test, not the
client**: the default endpoint selection for the two unified methods is unchanged, and a
consumer calling `fetch_open_orders/2` without `endpoint_index` still reads the algo book.
Deciding that is a carve question — whether USD-M's default open-orders book should be the
regular one, whether the two books should fan out and merge, or whether the unqualified
read should refuse to guess the way deribit's plural funding read does.

---

## 2026-09-15 — five live deribit tests grade against the PRODUCTION host, so a venue maintenance window reds the suite

**Status:** 🆕 reported 2026-09-15 — unrouted, awaiting the operator's routing decision.
Found by the landed-base gate while verifying task 704.

**What it is.** `test/live/read_parse_slots_test.exs` (4 tests) and
`test/live/ws/canary_test.exs` (1 test) construct the venue with `Exchange.new!("deribit")`
— no `sandbox: true` — so they resolve `www.deribit.com`, not `test.deribit.com`. The
repo's own doctrine reserves the production host for public-only Coinbase Exchange; every
credentialed venue is supposed to be graded on testnet/demo.

**Evidence (2026-09-15 17:30 CEST).** Production is in maintenance, testnet is up:

```
www.deribit.com  /api/v2/public/get_index_price → {"error":{"message":"system_maintenance","code":11051}}
test.deribit.com /api/v2/public/get_index_price → {"result":{"index_price":76870.19},"testnet":true}
```

All five tests fail with that 11051 / HTTP 503, and `mix bourse.verify_ws_first_frame`
reports deribit **passed** in the same minutes — that lane uses the testnet host. So the
split is real and observable, not an outage narrative.

**Why this is not a one-line fix.** Re-pointing them at `sandbox: true` trades a loud
external outage for a possibly-thin testnet book: `fetch_option_chain(exchange, "USDC")`
asserts a populated USDC-settled SOL option book with non-empty IV, and the test explicitly
guards against "an empty success". Whether testnet carries that book has to be measured
before the host is moved, or the fix converts a true RED into a flaky one. That measurement
plus the re-point is the task, if the operator routes it.

## 2026-09-15 — task 699's land re-broke a test that had shipped one commit earlier: the WS lane called a talking lighter socket silent

**Status:** ✅ fixed 2026-09-15 inline (shipped `d8c786b`).

**What it was.** `26bb651` (task 701) made a frame count as coverage only when it carries
the subscribed channel, and shipped a test asserting the lane's reason for lighter's
greeting-only case: *"received frames within 50ms but none carried the subscribed channel"*.
`0b10aed` (task 699, landed after it) added a venue-specific clause to
`lib/bourse/live_lane/first_frame.ex`:

```elixir
defp handle_frame("lighter" = venue, deadline, first_kind, tokens, unattributed, %{"type" => "connected"}) do
  await_frame(venue, deadline, first_kind, tokens, unattributed)
end
```

which drops the greeting without recording it as `unattributed`, so `timeout_result/2` took
the `:none` branch and the lane reported *"connected but received no frame within 50ms"* —
a socket that had demonstrably spoken. Task 699 also shipped a second test asserting the
new string, so the file carried two tests contradicting each other on the same input and
the suite was red on `main` from that land onward.

**Why the clause was redundant.** `data_or_wait/7` already refuses to count a
non-attributable frame as data and carries it forward as `unattributed`; `%{"type" =>
"connected"}` classifies as `:not_ack` and matches none of the `market_stats/all` tokens, so
the generic path produces exactly the accurate verdict. The clause only removed the
bookkeeping.

**Why the wording matters.** "received no frame" and "received frames, none attributable"
are two different failures with two different remedies — a dead host versus a subscription
that never resolved. Collapsing them hides which one happened.

**Fix.** Clause removed; task 699's `:silent` assertion corrected to the accurate string.
`test/bourse/ws_first_frame_test.exs` 20/20, and `mix bourse.verify_ws_first_frame` reports
lighter `passed` / `acknowledgement_with_payload` live against the venue.

**Class note.** This is the per-task-reviewer blind spot, not a reviewer lapse: run 699
forked before `26bb651` landed, so the test it broke did not exist in its base. Only the
landed-base gate could see it.

## 2026-09-15 — the pinned lighter-go SDK rejects every four-digit market id, so no lighter order can be signed at all

**Status:** ✅ fixed 2026-09-15 inline (task 704) — `native/lighter_signer/go.mod` now pins
`github.com/elliottech/lighter-go v1.0.9`; see the Update block at the end of this entry.

**Impact:** every lighter write is dead. `Bourse.create_order/6`, `Bourse.cancel_order/3` and
`modify_order` against the live testnet fail before a byte reaches the venue, with
`%Bourse.Error{type: :authentication_error, message: "Request signing failed: lighter_signing/signing_failed"}`.
The private *reads* are unaffected — `CreateAuthToken` does not validate a market id.

**What it is.** `native/lighter_signer/go.mod` pins
`github.com/elliottech/lighter-go v0.0.0-20260608173247-c26ac340ce5d`. That revision
validates the market index against two disjoint windows
(`types/txtypes/constants.go`):

```
MinPerpsMarketIndex int16 = 0
MaxPerpsMarketIndex int16 = 254  // (1 << 8) - 2
MinSpotMarketIndex  int16 = 2048 // (1 << 11)
MaxSpotMarketIndex  int16 = 4094 // (1 << 12) - 2
```

`L2CreateOrderTxInfo.Validate/0` returns `ErrInvalidMarketIndex` for anything outside both,
and our C shim collapses every Go error into `ERROR_SIGNING` (6), so the venue-visible
symptom is a bare `signing_failed` that names nothing.

Lighter testnet has since moved its perp ids into the four-digit space — ETH `4095`,
BTC `4096`, SOL `4097` (same migration already recorded in the lighter WS entry below).
`4095` and `4096` are both outside `0..254` **and** outside `2048..4094`, so the market our
own `fetchMarkets` publishes can never be signed for.

**Live repro (Tidewave, 2026-09-15, testnet account index from `LIGHTER_TESTNET_ACCOUNT_INDEX`):**
a boundary sweep through `Bourse.Signing.Lighter.sign_transaction(:create_order, …)` with
every other field held constant:

| market_index | time_in_force | order_expiry | result |
|---|---|---|---|
| 2 | PO | -1 | signed |
| 254 | PO | -1 | signed |
| **255** | PO | -1 | `signing_failed` |
| 4094 | PO | -1 | signed |
| **4095** | PO | -1 | `signing_failed` |
| **4096** (live BTC) | PO | -1 | `signing_failed` |
| 2 | IOC | 0 | signed |
| **4096** | IOC | 0 | `signing_failed` |

The cut points are exactly `MaxPerpsMarketIndex` and `MaxSpotMarketIndex`. Nothing about
the credential, the nonce or the key is involved: `CreateAuthToken` signs fine on the same
helper process, and `GET /api/v1/apikeys?account_index=<idx>&api_key_index=255` shows our
registered zk pubkey at the configured key index.

**Second finding from the same sweep — an IOC limit order can never carry our default
expiry.** `Bourse.Unified.RequestShape.Lighter` sends `order_expiry: -1` by default; the
SDK's `SignCreateOrder` rewrites `-1` to `now + 28d`, and `Validate/0` then rejects a
`LimitOrder` whose `TimeInForce == ImmediateOrCancel` and whose `OrderExpiry != 0`. So
`timeInForce: "IOC"` (and `"FOK"`, which our capability slice advertises as supported) is
unusable unless the caller also passes `order_expiry: 0`. Proven above: `{2, IOC, -1}`
fails, `{2, IOC, 0}` signs.

**The fix is an SDK bump, not a workaround.** `lighter-go v1.0.9` (2026-09-11) drops the
two-window split entirely — `MinMarketIndex 0` / `MaxMarketIndex (1 << 15) - 1`, with
`NilMarketIndex 255`. Its exported C surface is source-compatible for every call our shim
makes **except `SignModifyOrder`, which gained a trailing `cOrderVersion C.longlong`**, so
`native/lighter_signer/csrc/helper.c:500` needs the new argument. `CreateIntegratorTxAttributes`
gained `orderVersion` on the Go side, which means the signed payload changed — the golden
vectors in `native/lighter_signer/golden_test.go` must be re-derived, not re-blessed.

**Consumer note.** No consumer has hit this yet because no consumer places lighter orders;
it was found by the landed-base gate while trying to open a position so
`lighter:fetchPositions:0:publicGetAccount` would stop reporting an unexercised read.

> **Update (2026-09-15, shipped `1bceb79`).** Landed SDK: `github.com/elliottech/lighter-go
> v1.0.9`. Market **4096** (live BTC/USDC:USDC) now signs and executes: an IOC buy of
> 0.0002 BTC @ 77343.6 returned `{"code" => 200, "tx_hash" =>
> "32c58e4d04116ff4a248cd1c88c968b589913440052a88c40feb292525a916f5a4fcaafb927df155"}` and
> filled at 76955.6; a post-only buy @ 69176.0 rested as order `844424927511380`
> (tx `03c2c667647ba021c2be42df8a312bab3f9ed04761e0f38d31942afff783f72bf18580ca3b753da6`),
> appeared in `fetch_open_orders`, and cancelled clean
> (tx `83be2699fe32f26eed7fbeff5d46b910931803705c4daf48e6f52630a8e3b138db78c6378e2d0a48`).
> `mix bourse.verify_rest_read_contracts --venue lighter` → `denominator=16 executed=16
> failures=0`.
>
> **Correction to this entry.** The paragraph above claiming the signed payload changed and
> that "the golden vectors in `native/lighter_signer/golden_test.go` must be re-derived, not
> re-blessed" is **wrong**, and it was wrong when written. All eight vectors pass
> byte-identically against v1.0.9. The reason is in the SDK's own source rather than in the
> observation: v1.0.9 adds `AttributeTypeOrderOrderVersion` to the signed attribute set, but
> `types/tx_request.go:220` writes it only when `attr.OrderVersion != nil`, and
> `sharedlib/main.go` leaves it nil for every signer our shim reaches — `SignCreateOrder`
> passes `txtypes.NilOrderVersion` itself (`main.go:325`, `:373`), and `csrc/helper.c` now
> passes the same nil value to `SignModifyOrder`, the one signer that takes it from the
> caller. A vector that changes here in future therefore means our shim started sending a
> real order version, not that the SDK moved the hash under us.
>
> The IOC/expiry coupling from the second finding is fixed with it: `default_order_expiry/1`
> derives the sent expiry from the resolved time-in-force (`NilOrderExpiry` for IOC, the
> signer's `-1` otherwise), and an explicit caller `order_expiry` still wins. The false
> `createOrder.timeInForce.FOK: true` capability is corrected to `FOK: false` / `GTD: true`
> — lighter-go publishes exactly `{ImmediateOrCancel 0, GoodTillTime 1, PostOnly 2}` and
> never had a fill-or-kill. Both outcomes are recorded as carve C-T704a in
> `docs/authored-spec-carves/lighter.md`; the parent-level `balance.used` / `total` fix is
> C-T704b.
>
> The long 0.0002 BTC position opened by the IOC probe is **left open** on purpose — it is
> what makes `lighter:fetchPositions:0:publicGetAccount` an exercised read.

## 2026-09-15 — deribit's authored transfer slot never mapped the venue's own `currency`, so the first live transfer row failed the contract lane

**Status:** ✅ fixed 2026-09-15 inline (landed-base `mix ci` gate) — `priv/venues/deribit/authored/normalization.json`
`field_maps.transfer.field_map.currency` now maps `safeCurrencyCode` onto the provider key `currency`;
`mix bourse.verify_rest_read_contracts --venue deribit` runs `denominator=41 executed=41 failures=0`.
Carve recorded in `docs/authored-spec-carves/deribit.md` (2026-09-15, transfer currency).

- Exact call: `deribit:fetchTransfers:0:privateGetGetTransfers` in
  `test/live/deribit/rest_read_contract_test.exs`, i.e. `private/get_transfers`
  with `currency=BTC`, `limit=10` against `test.deribit.com`.
- Observed: `deribit:fetchTransfers:0:privateGetGetTransfers: required semantic field currency is nil`.
- Expected: `Bourse.TransferEntry.currency == "BTC"` — the venue publishes it. Live
  2026-09-15: `{"id": 493346, "type": "subaccount", "state": "confirmed",
  "currency": "BTC", "amount": 5.0, "direction": "payment", "other_side": "efries_1"}`.
- Cause: the authored transfer field map carried `"currency": null` while the
  contract case declares `required_fields: ["id", "currency"]`. bybit maps `coin`
  and okx maps `ccy` through `safeCurrencyCode`; deribit's slot was simply never
  authored.
- Why it stayed green for so long: the case declares `empty_collection: allowed`
  and the testnet account held **no transfer at all**, so the lane passed on an
  empty list. The defect is as old as the slice — a transfer row appearing on the
  account is what made it observable, not any change in our code or in the venue.
  That is the shape `empty_collection: allowed` will keep producing: a required
  field can be unauthored indefinitely while nothing exercises the slot.

**Independently rediscovered in the task 685 dispatch run (2026-09-15).** The review of
that run hit the same contract failure — `deribit:fetchTransfers:0:privateGetGetTransfers:
required semantic field currency is nil`, live row `id: "493346"`, `currency: nil` while
`info["currency"]` held `"BTC"` — and carved the same slot the same way, confirming the
defect predates task 685 and is unrelated to its four instances. Consumer impact named
there: a transfer row whose currency the venue published reads as "currency unknown", so
any consumer bucketing transfers by asset silently loses deribit rows or attributes them
to a nil key. All 41 `test/live/deribit/rest_read_contract_test.exs` cases pass against
`test.deribit.com` with the carve in place.

---

## 2026-09-15 — die Emulations-Brücke `fetchFundingRate` ⇄ `fetchFundingRates` ist ein echter Zyklus im Delegationsgraphen; dass kein Venue beide Hälften als `emulated` führt, ist nirgends erzwungen

**Method:** Lesen von `lib/bourse/emulation.ex` plus mechanische Extraktion des Delegationsgraphen, beim Landed-Base-Review von Task 692 ·
**Exchange:** venue-generisch (Kandidaten heute: bybit, deribit, hyperliquid, lighter) ·
**Severity:** mittel (latent — kein Venue verletzt es heute; die Verletzung wäre aber unbegrenzte Netzwerkverstärkung ohne Signal)

**Status:** 🆕 reported 2026-09-15 — mechanisch verifiziert, **nicht geroutet**. Kein aktueller Verstoß,
also kein Defekt der gelandeten Arbeit; die Frage ist, ob die Invariante erzwungen wird.

Task 692 hat `fetchFundingRates` als Emulation über den singulären Read ergänzt
(`handle_fetch_funding_rates` → `call_method(:fetch_funding_rate)`, über den Helfer
`collect_funding_rates_from_singular/5`). Die Gegenrichtung existierte schon
(`handle_fetch_funding_rate` → `call_method(:fetch_funding_rates)`). Damit ist das Paar ein
2-Zyklus im Delegationsgraphen von `Bourse.Emulation`.

Auseinandergehalten wird er ausschließlich von den Capability-Daten. Live geprüft in
`priv/venues/capability_surface.json` (2026-09-15):

```
alpaca            rate=false     rates=false
binance/coinm/usdm rate=true     rates=true
bybit             rate=emulated  rates=true
coinbaseexchange  rate=false     rates=false
deribit           rate=true      rates=emulated
derive            rate=true      rates=false
hyperliquid       rate=emulated  rates=true
lighter           rate=emulated  rates=true
okx               rate=true      rates=true
```

Kein Venue führt beide als `emulated` — aber nichts prüft das. Ein authored document, das es täte,
liefe `handle_fetch_funding_rate` → `fetch_funding_rates` → `handle_fetch_funding_rates` →
`fetch_funding_rate` → … unbegrenzt, und **jede Ebene ruft echt beim Venue an** (der singuläre
Handler ruft zusätzlich `ensure_contract_market` → `fetch_markets`). Das ist keine Stack-Overflow-
Fußnote, sondern unbegrenzte Netzwerkverstärkung gegen die Venue, ohne Compile-, Test- oder
Lint-Signal.

🚨 **Ein Quelltext-Scan als Prüfung wäre falsch-grün, und das ist hier belegt statt vermutet.**
Der Extraktor, mit dem dieser Befund entstand, liest `call_method(exchange, exchange_module, :method, …)`
je Handler-Rumpf und meldete für genau dieses Paar *keinen* Zyklus — weil die neue Kante nicht im
Handler steht, sondern im Helfer, den er aufruft. Eine Prüfung, die den Graphen aus dem Quelltext
rät, meldet also grün, während der Zyklus dasteht. Wer das erzwingen will, deklariert den Graphen
oder erkennt den Zyklus zur Laufzeit an der einen Stelle, die jeder emulierte Aufruf passiert
(`Bourse.Emulation.dispatch/4`), statt ihn zu extrahieren.

Gegenprobe: die restlichen Delegationskanten sind alle singulär→plural und haben keine
Gegenrichtung (`fetch_ticker`→`fetch_tickers`, `fetch_position`→`fetch_positions`,
`fetch_leverage`→`fetch_leverages`, `fetch_margin_mode`→`fetch_margin_modes`,
`fetch_open_interest`→`fetch_open_interests`, `fetch_trading_fee`→`fetch_trading_fees`,
`fetch_transaction_fee`→`fetch_transaction_fees`, `fetch_deposit_withdraw_fee`→`…fees`,
`fetch_funding_interval`→`fetch_funding_intervals`, `fetch_market_leverage_tiers`→`fetch_leverage_tiers`,
`fetch_bids_asks`→`fetch_tickers`, `fetch_my_trades`/`fetch_filtered_orders`/
`fetch_canceled_and_closed_orders`→`fetch_orders`, `fetch_trading_limits`→`fetch_markets`).
Funding ist das einzige Paar, das in beide Richtungen emuliert werden kann.

---

## 2026-09-15 — die WS-First-Frame-Lane zählt lighters Verbindungsgruß als Datenframe und meldet den Venue grün, während die Venue die Subscription mit 30005 ablehnt

**Method:** `mix bourse.verify_ws_first_frame` (`Bourse.LiveLane.FirstFrame`) ·
**Exchange:** lighter (testnet), Mechanismus venue-generisch ·
**Severity:** hoch (falsches Grün in genau der Lane, die beweisen soll, dass Streams liefern)

**Status:** ✅ fixed 2026-09-15 in `26bb651` (Task 701, inline) — die Lane zählt einen Frame
nur noch als Coverage, wenn er den abonnierten Channel trägt; ein Frame, der das nicht tut,
beendet die Probe nicht, sodass eine dahinter eintreffende Ablehnung weiterhin das Verdikt wird.
Live-Beleg nach dem Fix (voller Lauf über elf Venues): lighter meldet
`failed` / `first_frame: "rejected"` mit der venue-eigenen `%{"error" => %{"code" => 30005,
"message" => "Invalid Channel:  (marketId)"}}` in der Row-Reason, und alle acht zuvor grünen
Venues (alpaca, binance, binanceusdm, bybit, coinbaseexchange, deribit, hyperliquid, okx)
bleiben grün. Zwei Regressionstests in `test/bourse/ws_first_frame_test.exs` sind ohne den Fix
rot verifiziert. Lighters abgelehnter Channel selbst bleibt offen — das ist Task 699.

Gefunden beim Landed-Base-Gate nach Task 697. Die Lane meldet für lighter

```json
{"venue":"lighter","section":"public","channel":"market_stats/0",
 "status":"passed","first_frame":"data","data_frame":"data","reason":null}
```

während derselbe Kanal über `Bourse.WS.subscribe/3` live abgelehnt wird:

```elixir
{:ok, ex} = Bourse.Exchange.new("lighter", sandbox: true)
{:ok, ws} = Bourse.WS.connect(ex, :public)
Bourse.WS.subscribe(ws, ["market_stats/0"], ack_timeout_ms: 6_000)
# => {:error, {:subscription_rejected, %{"error" => %{"code" => 30005,
#      "message" => "Invalid Channel:  (marketId)"}}}}
Bourse.WS.subscribe(ws, ["order_book/0"], ack_timeout_ms: 6_000)   # dasselbe
```

Der `test/live/ws/canary_test.exs`-Fall für lighter ist aus demselben Grund rot. Zwei Lanes
widersprechen sich also über denselben Kanal, und die grüne hat unrecht.

**Mechanismus — zwei Löcher, ein Symptom:**

1. `default_subscribe/3` ruft `ws_client.subscribe(ws, channels, ack_timeout_ms: 0)`
   (`lib/bourse/live_lane/first_frame.ex:348`). Mit Budget 0 wartet die Lane den Ack nie
   ab und sieht die Ablehnung nicht, die `WS.subscribe/3` zurückgäbe.
2. Danach nimmt sie das erste Nicht-Heartbeat-Frame als Daten, ohne zu prüfen, ob es zum
   abonnierten Kanal gehört. lighter schickt unaufgefordert `%{"type" => "connected"}`.
   Mechanisch nachgestellt:

   ```elixir
   Bourse.WS.SubscribeAck.classify("lighter", %{"type" => "connected"})   # => :not_ack
   Bourse.LiveLane.FirstFrame.frame_kind(:not_ack, %{"type" => "connected"})  # => "data"
   ```

   `classify_received/4` mappt jedes `:not_ack` auf `{:data, ...}` → `success_row`. Der
   Gruß kommt vor dem Rejection-Frame an, also ist die Lane fertig, bevor die Ablehnung
   überhaupt eintrifft.

Expected: der Moduledoc der Lane sagt selbst „Subscribe acknowledgements are not coverage.
A connection that stays silent after a bounded wait fails" — ein Verbindungsgruß ist noch
weniger als ein Ack. Die Lane muss (a) die Ablehnung sehen, bevor sie auf Daten wartet,
und (b) ein Datenframe daran binden, dass es den abonnierten Kanal trägt.

**Klassen-Scope für die Routing-Entscheidung:** nicht lighter-spezifisch. Jeder Venue, der
ein unaufgefordertes Frame schickt, das weder ping/pong/heartbeat noch ein bekanntes
Ack-Muster ist, passiert die Lane ohne einen einzigen echten Datenframe. Ein Fix am
`ack_timeout_ms: 0` allein schließt nur Loch 1; die Kanalbindung in `success_row` ist das,
was die Klasse schließt.

**Konsequenz für schon getroffene Aussagen:** der BUGS-Eintrag vom 2026-09-15 („lighter
testnet ging dunkel") bleibt richtig — die öffentliche WS-Subscription wird abgelehnt. Die
grüne lighter-Zeile im First-Frame-Report ist die falsche Angabe, nicht umgekehrt.

## 2026-09-15 — derive's authored WS channel templates name channels the venue does not serve: `watch_ticker` is rejected as deprecated, `watch_orders` / `watch_my_trades` carry a CCXT message hash

**Method:** `Bourse.WS.watch_ticker/3`, `watch_orders/3`, `watch_my_trades/3` (authored
`websocket.subscribe.channels` in `priv/venues/derive/authored/venue.json`) ·
**Exchange:** derive (demo, `wss://api-demo.lyra.finance/ws`) · **Severity:** hoch
(`watch_ticker` ist auf derive vollständig tot; die beiden privaten Kanäle können nie ackn)

**Status:** 🆕 reported 2026-09-15 — live-verifiziert in beide Richtungen, noch nicht geroutet.

Gefunden beim Landed-Base-Gate nach Task 697: `mix bourse.verify_ws_first_frame` ist auf
derive rot. Die Ursache ist nicht der Lane-Probe, sondern die authored Kanalliste.

**Instanz 1 — `watchTicker` → `ticker.{symbol}.100` ist provider-seitig abgekündigt.**
Live 2026-09-15:

```
subscribe ["ticker.ETH-PERP.100"]
  → {:error, {:subscription_rejected,
       %{"error" => %{"code" => -32602, "message" => "Invalid params",
                      "data" => "`ticker` channel has been deprecated. Please use `ticker_slim`."}}}}

subscribe ["ticker_slim.ETH-PERP.100"]
  → :ok, danach method="subscription", params.channel="ticker_slim.ETH-PERP.100",
    params.data.instrument_ticker = %{"A" => "2.96", ...}
```

Expected: `watch_ticker/3` subscribed einen Kanal, den die Venue bedient. Der Ersatz ist
`ticker_slim`, und sein Payload ist **nicht formgleich** — die Daten hängen unter
`params.data.instrument_ticker` statt der bisherigen `ticker`-Form. Ein Fix ist deshalb
Kanalname **plus** Dispatch-Entry (`dispatch.entries[].channel == "ticker"`) **plus**
Prüfung der Feldabbildung gegen den neuen Payload — nicht nur ein String-Tausch.

**Instanz 2 — `watchMyTrades` und `watchOrders` sind auf `":{symbol}"` authored**, den
CCXT-internen Message-Hash, exakt die Klasse, die Task 618 auf binance/binanceusdm
entfernt hat. Live gegen dieselbe Socket:

```
subscribe [":ETH-PERP"]          → {:error, {:subscription_rejected, %{"error" => %{"code" => 13000, ...}}}}
subscribe ["trades.ETH-PERP"]    → :ok
subscribe ["orderbook.ETH-PERP.1.10"] → :ok
```

Die Venue lehnt den Hash also laut ab (besser als binances stummes Ack), aber die beiden
unified Methoden sind damit unbenutzbar. `trades.` und `orderbook.` sind echte
derive-Kanäle — die authored Templates für `watchTrades` sind korrekt, die beiden privaten
sind es nicht.

**Repro:** `{:ok, ex} = Bourse.Exchange.new("derive", sandbox: true)` →
`{:ok, ws} = Bourse.WS.connect(ex, :public)` → die vier `Bourse.WS.subscribe/3`-Calls oben.
Kein Credential nötig, die Kanalvalidierung läuft vor der Auth.

**Consumer impact:** nicht gemeldet — gefunden durch den Lane-Rot, nicht durch einen
Consumer. `watch_ticker` auf derive liefert nie ein Frame; ein Consumer, der auf den
Subscribe-Fehler nicht prüft, sieht einen stillen leeren Stream.

**Klassen-Scope für die Routing-Entscheidung:** vier `watch_*`-Templates auf derive gegen
die provider-owned Kanalliste auditieren (dieselbe Form wie Task 618 für die
binance-Familie), inklusive der Payload-Formprüfung für `ticker_slim`. Der verbleibende
binancecoinm-`:no_channel_templates`-Rest aus 618 gehört in dieselbe Klasse.

## 2026-09-15 — die WS-First-Frame-Probe für binanceusdm ist intermittierend: zwei von drei Lane-Läufen laufen auf `btcusdt@miniTicker` in den 15-s-Timeout, direkte Probes desselben Streams liefern in 3-5 s

**Method:** `mix bourse.verify_ws_first_frame` (`Bourse.LiveLane.FirstFrame`, Probe
`%{venue: "binanceusdm", watch: :watch_ticker, sandbox: true}`) ·
**Exchange:** binanceusdm (demo, `wss://demo-fstream.binance.com/public/ws`) ·
**Severity:** mittel (false-RED-Generator in einem Gate, das per Doktrin verlässlich sein muss)

**Status:** 🆕 reported 2026-09-15 — Mechanismus **nicht** gefunden, Symptom reproduziert und
eingegrenzt. Noch nicht geroutet.

**🚨 Korrektur einer früheren Fassung dieses Eintrags (2026-09-15, gleicher Tag):** die
erste Version behauptete, der Demo-Host acke jede Subscription und liefere nie ein Frame.
Das ist **widerlegt**. Die Behauptung stützte sich auf eine einzige Probe, deren
Sammelschleife nach der ersten 2-s-Lücke abbrach, während drei `WS.subscribe`-Calls mit je
5 s Ack-Budget davor liefen. Der Fehler lag im Probe-Code, nicht bei der Venue.

**Was tatsächlich gilt (live 2026-09-15):**

| Stream, einzeln auf frischem Socket, `sandbox: true` | Ergebnis |
|---|---|
| `btcusdt@aggTrade` | `aggTrade` sofort |
| `btcusdt@miniTicker` | `24hrMiniTicker` sofort |
| `btcusdt@kline_1m` | `kline` sofort |
| `btcusdt@depth20@100ms` | `depthUpdate` sofort |
| `btcusdt@markPrice@1s` | `markPriceUpdate` jede Sekunde |
| `btcusdt@bookTicker` | `bookTicker` laufend |

Sequentielle Subscribes auf **einem** Socket funktionieren ebenfalls (aggTrade, danach
miniTicker — beide liefern weiter). Das Demo-Buch ist nicht ruhig: `fetch_trades` liefert
Rows mit Alter ~0 s, `fetch_ticker` ein 24-h-Quote-Volumen von 1.198e11.

**Das verbleibende Symptom:** `Bourse.WS.watch_ticker(ws, "BTC/USDT", ack_timeout_ms: 0)` —
also exakt der Lane-Pfad — liefert in direkter Wiederholung 5 von 5 Mal `24hrMiniTicker`
nach 2,8 s bzw. 5,6 s. Die Lane selbst meldete denselben Kanal in zwei unabhängigen Läufen
(mein Landed-Base-Gate und der Reviewer-Lauf von Task 697) als
`connected but received no data frame within 15000ms` und im dritten Lauf als `passed`.

Eine Erklärung für die Differenz habe ich **nicht**. Ausgeschlossen ist
Mailbox-Kontamination zwischen Venues: `record_probe/4` kapselt jede Probe in einen eigenen
`Task.async/1`, jede Probe hat also ihre eigene Mailbox und ihren eigenen Socket.

**Repro (das Symptom, nicht der Mechanismus):** `mix bourse.verify_ws_first_frame`
mehrfach laufen lassen und die `binanceusdm`-Zeile vergleichen.

**Warum das trotzdem hier steht:** ein Gate, das in einem Drittel der Läufe grundlos rot
meldet, erzieht dazu, seine Roten wegzulesen — und genau dann übersieht es das echte Rot.
Der Nachbarbefund im selben Report (lighter meldet grün auf einem Verbindungsgruß) zeigt,
dass die Lane-Klassifikation ohnehin zu schwach ist; beide gehören in dieselbe Betrachtung.

## 2026-09-15 — task 693 made conditional controls first-class on the request side, but the read side drops them: three venues never parse `triggerPrice`, and `stop_loss_price` / `take_profit_price` are unmapped on nine of ten

**Status:** ✅ fixed 2026-09-15 (task 700, shipped `75a540b77ca4`) — the durable fix is the
invariant, not the mappings: `test/bourse/order_control_round_trip_invariant_test.exs`
derives the control set from `Bourse.Unified.OrderOptions.aliases/0` plus the authored
create/edit request shapes and fails when a venue accepts a control on write without
mapping it back. Deribit now maps `trigger_price` and `reduce_only`, bybit `triggerPrice` /
`stopLoss` / `takeProfit`, okx `triggerPx`; the Binance family's `stopLossPrice` /
`takeProfitPrice` and alpaca's `reduceOnly` carry named exemptions citing the provider
contract, and a stale exemption fails the same test. The remaining unmapped cells in the
table below are slots those venues' write paths do not accept, which the invariant does not
require. Originally found from the orchestrator seat while answering a `trading_dashboard`
question about the deribit conditional gate; no per-task reviewer could see it, because the
asymmetry only existed once 693 landed. Repro and the pre-fix survey kept below as the
evidence trail.

**The call, live against `test.deribit.com` (2026-09-15):**

```elixir
{:ok, order} =
  Bourse.create_order(ex, "BTC/USD:BTC", "take_market", "sell", 10,
    trigger_price: 96_956.0, trigger: "last_price")

order.trigger_price        #=> nil          ← observed
order.reduce_only          #=> nil          ← observed
order.info["trigger_price"] #=> 96956.0     ← the venue published it
order.info["reduce_only"]   #=> false       ← the venue published it
```

Order `TPTS-11018234`, `order_state: "untriggered"`, cancelled in the same session; the book
was verified empty afterwards (`fetch_open_orders` → 0).

**Expected:** a protective order placed through the unified surface reads back with the
protective fields populated. 693 made `trigger_price` / `stop_loss_price` /
`take_profit_price` / `reduce_only` canonical *inputs* and refuses a request the venue
cannot express; the response slice was not moved with it, so a consumer that places a stop
and reads it back cannot tell a stop from a market order without reaching into `info`.

**It is a class, not an instance** — `priv/venues/<venue>/authored/normalization.json`,
`field_maps.order.field_map`, across all ten venues with an order map:

| slot | unmapped on |
|---|---|
| `triggerPrice` | bybit, deribit, okx |
| `reduceOnly` | alpaca, deribit |
| `stopLossPrice` | all but derive, okx |
| `takeProfitPrice` | all but okx |

**Consumer impact — confirmed worse than a missing field (`trading_dashboard`, same day).**
Its subaccount allocation cap is enforced in a Postgres trigger, not in app code, and that
trigger reads `params ->> 'reduce_only'` out of the adopted order row's jsonb, then uses the
flag to pick `position_side`. A deribit reduce-only order adopted through the unified
surface therefore does not merely lose a flag: it books on the **wrong side of that
symbol's exposure**, inflating committed entry exposure that should have been a reduction
and polluting the `latest_full_close` bookkeeping the notional trigger keys on. Their
adoption code reads `order.reduce_only`, gets `nil`, and correctly concludes "the venue did
not say" — a deliberate documented rule whose premise this gap falsifies. Tracked there as
`trading_dashboard` task 286 (a venue-agnostic seam: mapped struct field first, raw `info`
as fallback, so our fix simply wins when it lands and nothing has to be unwound).

**Not fixed inline** on purpose: ten venues times four slots is authoring work with a live
call and a carve-register entry per venue, not a bounded local edit. One class, one task if
the operator routes it.

## 2026-09-15 — bybit `fetch_all_greeks` answered `%{}` for a symbol its own option ticker list carried, sustained across a retry, then recovered

**Status:** Recorded, not routed (post-merge audit of `de6916d`, 2026-09-15). No task filed — re-probed green minutes later, so this is venue state rather than a client defect on current evidence.

Measured in the cold post-merge audit worktree (`mix check.dispatch`,
`api-testnet.bybit.com`, public — no credentials). Nothing in the audited range
(`8e040ba..de6916d`) touches bybit or the greeks path, so this is not a
regression from the landed work.

- Failing case: `test/live/bybit/bybit_account_analytics_integration_test.exs:25`,
  *"public fetch_all_greeks returns symbol-keyed %Greeks{} values"*.
- Exact call: `public_get_v5_market_tickers(category: "option", baseCoin: "BTC")`
  returned a non-empty list; `hd(rows)["symbol"]` unified to
  `BTC/USDT:USDT-261002-66000-C`; `Bourse.fetch_all_greeks(exchange, symbols:
  [unified], baseCoin: "BTC")` then answered `{:ok, %{}}`.
- Expected: a `%Bourse.Greeks{}` under that key — the ticker list and the greeks
  read are the same option board.
- Not a single-frame race: `mix test.json`'s automatic retry re-ran it and
  confirmed the failure, so the empty read persisted across the retry window.
- Re-probed by this audit minutes after the suite finished: tickers returned 716
  rows, `hd` unified to `BTC/USDT:USDT-260915-77750-P` and round-tripped back to
  `BTC-15SEP26-77750-P-USDT`; the filtered `fetch_all_greeks` returned exactly
  that one key and the unfiltered call returned all 716. Symbol normalization and
  the `symbols:` filter are both correct as of the re-probe.

What is not settled: whether bybit's option greeks surface intermittently drops
instruments its ticker surface still lists, or whether the specific
`261002-66000-C` instrument was delisted between the two calls inside the test.
The test picks `hd(rows)` out of ~716 instruments with no stability requirement,
so it will keep sampling whichever instrument the venue happens to head the list
with. Deciding this needs the failure caught again with both payloads captured
side by side, which no run has done.

---

## 2026-09-15 — binanceusdm merged order history stops ~5.3 s short of the requested `until` boundary, past the probe's 1 s tolerance

**Status:** Recorded, not routed (post-merge audit of `de6916d`, 2026-09-15). No task filed — one observation, and it is not yet settled whether the client selects the boundary wrongly or the probe's tolerance is too tight for a merged read.

Preserved from the task 693 run journal before that journal was rewritten as
`docs/conditional-order-controls.md`; measured by the task 693 implementer
(run `run-1789444835773-5d708551`), not re-proven by this audit.

- Exact call: `test/live/time_window_integration_test.exs`, the
  `binanceusdm` / `fetch_orders` probe against `demo-fapi.binance.com`
  (`tolerance_ms: 1_000`, i.e. `@one_second_ms`).
- Assertion that failed: `last_timestamp >= until_boundary - probe.tolerance_ms`
  — *"did not stop at the until boundary"*.
- Observed: the last returned timestamp was **5,347 ms earlier** than the
  requested upper boundary. No row came back *beyond* the upper bound, so the
  window is not over-wide; it is under-full at the top.
- Expected by the probe: a last row within 1 s of `until_boundary`.
- Persisted when the generated time-window lane was run alone (17/18), so it is
  not contention with concurrent mutation from the rest of the suite.

The open question is which side is wrong. `fetch_orders` on USD-M is a *merged*
read across more than one provider endpoint, so a boundary picked per-endpoint
and then merged can legitimately land short of the requested edge — in which
case the 1 s tolerance (shared with single-endpoint OHLCV probes) is the defect,
and `binancecoinm.fetch_trades` / `derive.fetch_trades` / `lighter.fetch_ohlcv`
already carry `@one_minute_ms` for comparable reasons. If instead the client
picks the merged upper boundary from the wrong endpoint's page, that is a real
read defect. Deciding it needs a live read of both underlying endpoints against
the same window, which nobody has run. Recorded here so the next reader does not
re-derive it.

> **Update (2026-09-15, gate runs 1-4 of the day):** the failure is not
> occasional. It reappeared in every full-suite run of the day — `mix
> test.json --cover` 14:31, `mix ci` 16:11, `mix check.dispatch` 17:24
> (healed on the automatic retry, so it settled *flaky*) and 17:50 — and the
> shortfall varies by four orders of magnitude between runs: **2,113 ms**,
> **3,981 ms**, **1,355,925 ms (22.6 min)** and **313,974 ms (5.2 min)**.
> That variance is the new evidence, and it cuts against the tolerance
> reading: a merged read whose upper boundary is picked per-endpoint and then
> merged can land a second or two short, but it cannot land twenty-two
> minutes short. A shortfall that large means the `until`-bounded page is not
> the page nearest the boundary at all — it is some other page of the same
> history — which points at request construction or provider paging
> semantics, not at the probe's 1 s tolerance. Widening the tolerance would
> turn the small-gap runs green and leave the large-gap runs red, i.e. it
> would make the symptom intermittent rather than settle it. Deciding it
> still needs the live read of both underlying USD-M endpoints against one
> window that nobody has run.
>
> **Correction and two further runs (2026-09-15, same day).** "Reappeared in
> every full-suite run of the day" was true of the four runs it was written
> from and is no longer true: gate run 6 on `44edfaa` passed this test
> outright — the first green in five runs — and gate run 7 on `8cce218` failed
> it again with a shortfall of **5,572 ms** (`requested 1789459979895, last
> 1789459974323`). The six-run record is therefore **2,113 ms · 3,981 ms ·
> 1,355,925 ms · 313,974 ms · GREEN · 5,572 ms**. The claim this evidence
> supports is *intermittent with a four-order-of-magnitude spread*, not
> *always red*; the earlier wording overstated the frequency and is corrected
> here rather than edited away. Nothing about the diagnosis changes — an
> intermittent green is what a merged read whose upper page drifts would
> produce, and a run that lands twenty-two minutes short still cannot be
> explained by a 1 s tolerance. What the green does add is that the bounded
> read is reachable: on at least one run the `until`-bounded page WAS the page
> nearest the boundary, so the defect is in which page gets selected, not in a
> boundary the venue never honours.
>
> **Seventh observation (2026-09-15, post-merge audit of `9c2e70e`).** Red again
> in a cold un-warmed worktree, `mix check.dispatch` on the landed base:
> shortfall **18,728 ms** (`requested 1789464039359, last 1789464020631`). The
> seven-run record is **2,113 ms · 3,981 ms · 1,355,925 ms · 313,974 ms · GREEN ·
> 5,572 ms · 18,728 ms**. Adds no new mechanism — a seventh point inside the
> already-established spread — and is recorded only so the frequency claim stays
> honest: six of seven runs red, spread still four orders of magnitude. The
> deciding experiment is unchanged and still unrun.

---

## 2026-09-15 — lighter testnet went dark: every private read answers `invalid auth: couldnt find account`, the public WS channel is rejected, and an unknown market id no longer errors

**Status:** ✅ resolved 2026-09-15 — the private half was never a venue reset. It was a
**configuration drift**: `LIGHTER_TESTNET_ACCOUNT_INDEX` named a different account on this
machine, on the harness server and inside long-lived agent sessions, and each session
"fixed" the resulting 20013 by re-provisioning, which minted a new key at a new index and
broke the next machine. Root cause, evidence and the durable guard are in the resolution
note at the end of this entry. **Nothing needs provisioning; the registered key is the one
`LIGHTER_TESTNET_API_PRIVATE_KEY` derives.** The WS-channel and unknown-market-id halves
were closed earlier by task 699 (shipped `ba09535718725edef9fcd580660457dab6a5c21c`).

**Historical status line, kept because the reasoning below builds on it:** ⚠️ split — two of
three symptoms fixed, the third is operator-gated and tracked by
no task (re-confirmed in the post-merge audit of `9c2e70e`, 2026-09-15). Task 699 (shipped
`ba09535718725edef9fcd580660457dab6a5c21c`) closed the **WS channel** and **unknown-market-id**
halves; both pass in this audit's cold `mix check.dispatch`. The **private-read** half is still
red — nine lighter cases answer 20013 `invalid auth: couldnt find account` — and 699 put it
`out_of_scope` on purpose: the remedy is the operator running `mix bourse.provision_lighter`
with the L1 wallet key that is deliberately outside the credential set, so it is **not**
pending implementation work and no task will close it. The earlier header read "Tracked in
task 699; implementation pending", which would have left the next reader waiting on a task
that had already shipped and had declined this half by name.

Measured in the cold post-merge audit worktree with `mix check.dispatch` against `https://testnet.zklighter.elliot.ai`, using the provisioned `LIGHTER_TESTNET_API_KEY_INDEX` / `LIGHTER_TESTNET_ACCOUNT_INDEX` / `LIGHTER_TESTNET_API_PRIVATE_KEY`. Nothing in the audited range (`972c1e8..0ac2cd2`) touches lighter, so this is venue-side drift, not a regression. Three distinct symptoms:

- Every private lighter read answers `%Bourse.Error{type: :authentication_error, code: 20013, http_status: 401, message: "invalid auth: couldnt find account"}` — `fetchClosedOrders`, `fetchDeposits`, `fetchMyLiquidations`, `fetchMyTrades`, `fetchOpenOrders`, `fetchTransfers`, `fetchWithdrawals` in `test/live/lighter/rest_read_contract_test.exs`, plus both `lighter_signing_integration_test.exs` cases and `lighter_promotion_integration_test.exs`. The signer produces a token the venue accepts as well-formed and then cannot resolve to an account, which is the shape of a de-provisioned or reset testnet account rather than a bad signature.
- `WS.subscribe(ws, ["market_stats/0"])` is rejected with `{:subscription_rejected, %{"error" => %{"code" => 30005, "message" => "Invalid Channel:  (marketId)"}}}` (`test/live/ws/canary_test.exs`). The authored channel grammar no longer matches what the venue accepts.
- `Bourse.Lighter.public_get_orderbookorders(exchange, %{"market_id" => <unknown>, "limit" => 1})` answers `{:ok, %{status: 200, body: %{"asks" => [], "bids" => [], "code" => 200, "total_asks" => 0, "total_bids" => 0}}}` where `test/live/errors/lighter_test.exs` expects a rejection. An unknown market id now reads as an empty book — the venue stopped distinguishing "no such market" from "empty market", so our only pinned lighter bad-input error no longer exists.

The private half may need operator re-provisioning (`mix bourse.provision_lighter` takes an L1 wallet key that is deliberately outside the credential set); the WS-channel and public-error halves need no credentials and are re-provable immediately.

> **Update (2026-09-15, landed-base `mix ci` gate).** Re-measured on `main` at `75dddad`;
> all three symptoms reproduce, and the private half is now pinned to a specific cause
> rather than a guess — it is **key de-registration, not an account reset**.
>
> - `GET /api/v1/account?by=index&value=$LIGHTER_TESTNET_ACCOUNT_INDEX` answers `code 200`
>   with the account alive: `status 1`, `collateral "10001.029839"`, an open position. So
>   "couldnt find account" is not about the account being gone.
> - `GET /api/v1/apikeys?account_index=$LIGHTER_TESTNET_ACCOUNT_INDEX&api_key_index=$LIGHTER_TESTNET_API_KEY_INDEX`
>   answers `{"code":21109,"message":"api key not found"}`. Querying the same account with
>   `api_key_index=255` lists the keys it does carry — two of them, at indices **0 and 10**,
>   neither of which is our provisioned index.
> - `native/lighter_signer/cmd/derive_pubkey` on our `LIGHTER_TESTNET_API_PRIVATE_KEY`
>   yields a public key that matches **neither** of those two registered keys. Our signer is
>   therefore producing a
>   well-formed token for a key the venue no longer knows — exactly the observed 20013.
>   Re-provisioning needs the L1 wallet key, which is deliberately outside the credential
>   set, so this half is operator-gated.
> - The unknown-market-id half is sharper than "the venue stopped distinguishing":
>   the venue no longer **range-checks** `market_id` at all. `-1`, `65536`, `2147483647`
>   and `4294967296` each answer `200` with an empty book, while a *malformed* value
>   (`not-a-market`, `1.5`, `0x10`, empty) still answers `400` / `20001 "invalid param "`.
>   The 20001 mapping is intact; only the existence check is gone. Note the id space also
>   moved — `GET /api/v1/orderBooks` now lists four-digit ids (`SOL` is `4097`, the
>   account's open position is `4095`), so a replacement bad-input probe must use a
>   malformed value, not a large integer.

> **Resolution (2026-09-15).** The paragraph above is right about the mechanism and wrong
> about the cause. The venue de-registered nothing: the *configured account was the wrong
> account*.
>
> - `LIGHTER_TESTNET_ACCOUNT_INDEX` held two different values in two places. sha256
>   fingerprints of all five lighter/hyperliquid values match between this machine and the
>   harness server **except** that one. The stale value names an account whose two keys
>   (indices 0 and 10) are the fossil record of two earlier re-provisioning rounds; the
>   correct value names the account whose L1 address is `$HYPERLIQUID_TESTNET_API_KEY`, and
>   there `LIGHTER_TESTNET_API_PRIVATE_KEY` derives exactly the key registered at
>   `LIGHTER_TESTNET_API_KEY_INDEX`. The credentials were correct the whole time.
> - **A long-lived process env beats `~/.secrets`.** An agent session started before the
>   file was corrected keeps the old export, so editing the file changes nothing for it.
>   That is why the failure kept "coming back" after each fix.
> - **The re-provisioning loop is the thing that made it recur.** `20013 "invalid auth:
>   couldnt find account"` names the *account* when the *index* is wrong, so every session
>   read it as a testnet reset and ran `mix bourse.provision_lighter`, minting a new key at
>   a new index and invalidating every machine pinned to the old one. The paragraph above
>   records that wrong inference at the moment it was made.
>
> **Durable guard shipped with this resolution** — `Bourse.Lighter.CredentialCheck`, a
> packaged module (so every consumer repo gets it), needs no credentials, no signature and
> no Go toolchain; it reads two public endpoints and asks the venue which indices the
> account actually carries (`api_key_index=255` lists them all). Three call sites:
>
> 1. `test/test_helper.exs` confronts the configured triple with the venue once at startup,
>    so the suite fails with the reason instead of nine cryptic 20013s.
> 2. `mix bourse.provision_lighter` refuses to mint a second key for a wallet that already
>    has one, naming the registered index and the export that fixes the configuration.
> 3. Every message that can be produced by a mismatch names the stale-process-env case and
>    the `zsh -l -c` comparison that proves it.


---

## 2026-09-15 — live contract cases red on unpopulated sandbox state with no ledger row to explain them

**Status:** Recorded, not routed (post-merge audit of `0ac2cd2`, 2026-09-15). No task filed — the ledger process already owns this class.

Same cold `mix check.dispatch` run. Two cases fail for sandbox state rather than for a defect, and neither matches a fence entry in `docs/prod-verification-ledger.md`, so they land in the "genuine failures" count:

- `binance:fetchOrderList:0:privateGetOrderList` — *"provider account state has no id from fetchOrderLists"*. The testnet spot account holds no OCO list to look up.
- `okx:fetchOpenInterestHistory:1:publicGetRubikStatOptionOpenInterestVolume` — *"provider account/market state did not exercise the read"*. The rubik option open-interest read answered empty.

Both scenario helpers fail loudly with actionable text, which is the designed behavior — the open question is whether the state is populatable (populate it) or structurally unavailable on these sandboxes (fence it as state-dependent). Left for the operator to route; recorded here so the next reader does not re-derive it.

**Amended 2026-09-15 (post-merge audit of `79e57bd`).** A third case of the same class
appeared in the cold `mix check.dispatch` run on that range, so the count in the original
title is dropped:

- `okx:fetchTrades:2:publicGetPublicOptionTrades` — *"provider account/market state did not
  exercise the read"*. The public option trade tape answered empty on the demo host.

That run's other reds are all already-owned: ten lighter cases answering `20013 "invalid
auth: couldnt find account"` (then believed to be an unprovisioned testnet account awaiting
`mix bourse.provision_lighter`, task 684 — operator-gated) and the two cases above.
**The lighter clause is superseded:** those ten were a stale `LIGHTER_TESTNET_ACCOUNT_INDEX`,
not an unprovisioned account, and provisioning was the thing making it recur — see the
resolution note on the entry above. They are green as of 2026-09-15. Only the two
unpopulated-state cases remain in this class. Same routing question, same operator
decision; nothing new to file.

---
## 2026-09-01 — `fetch_funding_rate/2` is unavailable on hyperliquid while `fetch_funding_rates/2` serves the same number, so a per-symbol consumer gets `not_supported` for a rate the venue publishes hourly

**Status:** Tracked in task 692 (triage 2026-09-15); implementation pending.

> **Live recheck 2026-09-15 (Bourse Tidewave):** the singular still returns `not_supported`; the plural BTC row returns `funding_rate: 1.25e-5`, `interval: "1h"`, and provider `info.funding: "0.0000125"`. An invalid-symbol singular also fails at the capability gate, not at the provider. Task 692 requires separate live provider-error evidence.

**The call:**

```elixir
{:ok, hl} = Bourse.exchange(:hyperliquid)
Bourse.fetch_funding_rate(hl, "BTC/USDC:USDC")
```

**Observed:**

```elixir
{:error, %Bourse.Error{
   type: :not_supported,
   message: "hyperliquid does not support fetchFundingRate",
   recoverable: false, retry_class: :non_retryable}}
```

**The same number is one call away.** The plural, on the same client, same symbol, live
2026-09-01:

```elixir
Bourse.fetch_funding_rates(hl, symbols: ["BTC/USDC:USDC"])
#=> {:ok, %{"BTC/USDC:USDC" => %Bourse.FundingRate{funding_rate: 1.25e-5, interval: "1h"}}}
```

`interval` is populated, the rate is hyperliquid's base hourly rate. Nothing is missing from
the venue; only the singular entry point refuses.

**Root cause is a capability-map asymmetry, and hyperliquid is the only venue that has it.**
Probed across all eleven venues on the installed 0.8.0:

| Venue | `fetchFundingRate` | `fetchFundingRates` |
|---|---|---|
| **hyperliquid** | **false** | **true** |
| deribit | true | `nil` |
| binance, binanceusdm, binancecoinm, bybit, okx | true | true |
| derive | true | false |
| lighter, alpaca, coinbaseexchange | false | false |

Hyperliquid is the single `false → true` row. This mirrors upstream CCXT faithfully — HL has no
per-symbol funding endpoint, only `metaAndAssetCtxs`, which returns every asset at once — so the
capability flag is not itself wrong. The gap is that bourse offers no bridge across it.

**Expected.** When a venue declares `fetchFundingRates` and not `fetchFundingRate`, the singular
serves the request from the plural and slices the requested symbol out, rather than refusing.
A consumer asking one venue for one symbol's funding should not have to know which of the two
spellings that particular venue happens to implement — that is precisely the normalization this
library exists to provide. The reverse case (deribit: singular yes, plural `nil`) argues for the
same bridge in the other direction.

**Consumer impact (`trading_dashboard`).** The hedge manager ranks perp venues by daily funding
before allocating a hedge; a venue whose funding interval it cannot read is dropped from the plan
entirely (`excluded: :funding_interval_unavailable`). Its funding fetcher calls the singular:

```elixir
def default_funding_fetcher(exchange_id, symbol) do
  with {:ok, exchange} <- Bourse.exchange(exchange_id) do
    Bourse.fetch_funding_rate(exchange, symbol)
  end
end
```

So hyperliquid — a venue the desk holds credentials for and actively hedges on — is silently
unrankable and never receives an order leg. The consumer can special-case the plural per venue,
and will locally, but that is the venue-shape knowledge the unified layer is supposed to absorb.

**Secondary observation, same probe, filed here rather than separately because it is one
authoring pass:** `lighter` declares **both** funding capabilities `false`, but publishes funding
publicly and unauthenticated. Live 2026-09-01:

```
$ curl -s 'https://mainnet.zklighter.elliot.ai/api/v1/funding-rates'
{"code":200,"funding_rates":[{"market_id":133,"exchange":"binance","symbol":"BIRB","rate":0.0001}, …]}
```

`/api/v1/fundings?market_id&resolution=1h` carries the per-market history (rate in percent per
hour, sign in a separate `direction` field, timestamps in seconds, ~2 months retention). So
lighter's `false/false` is an authoring gap, not a venue limitation — a distinct defect class
from the hyperliquid bridge above, but it lands the same consumer outcome: a real perp venue that
the hedge ranker cannot see.

---

## 2026-08-29 — the unified trigger/stop opt is spelled differently per venue, so the same `create_order` call rests a stop on binance and fills a market order on okx

**Status:** ✅ fixed 2026-09-15 (task 693, shipped `9475f0bf3298`) — `Bourse.Unified.OrderOptions` canonicalizes the control spellings and validates them *before* venue selection, including inside nested `orders` entries, so the legacy spelling can no longer reach a plain MARKET route with the trigger dropped; a control the selected operation cannot express is refused with `invalid_parameters` before signing. Repro kept below as the evidence trail.

`Bourse.create_order/6`'s trigger opt has no single spelling. The authored
`createOrder.request.endpoint_selection` rule — the thing that decides whether the order goes
to the algo endpoint or to the plain order endpoint — keys on a **different string per venue**:

| Venue | rule key | sibling key |
|---|---|---|
| binance, binancecoinm, binanceusdm | `trigger_price` | `stop_loss_price` |
| okx | `triggerPrice` | `stopLossPrice` |
| bybit | — | `stopLossPrice` |

Surveyed across all eleven authored documents (`grep -c` on each
`priv/venues/<venue>/authored/endpoints.json`); no other venue authors either key.

**Consumer impact is a wrong fill, not an error.** A caller who learned `trigger_price:` on
binance and reuses it on okx gets no rejection: the rule does not match, `ordType` stays
`market`, and the venue fills immediately. Measured live during the task 686 review on the
okx international demo host — `create_order(ex, "BTC/USDT:USDT", "market", "sell", 0.01,
trigger_price: trigger)` shaped to
`%{"instId" => "BTC-USDT-SWAP", "ordType" => "market", "side" => "sell", "sz" => "0.01",
"tdMode" => "cross"}` and opened a real 0.01 BTC short (order `3874682099387973632`, state
`filled`) that had to be closed by hand. The same call with `triggerPrice:` shapes to
`ordType: trigger` with `triggerPx`.

**Nothing in `lib/` reads the snake_case form.** `grep -rn '"trigger_price"' lib/` returns
zero hits — `Bourse.Unified.build_params/3` stringifies the opt key verbatim with no
camelization, so the only thing that ever consumes `"trigger_price"` is the binance family's
authored rule. `Bourse.Order` carries `trigger_price` as a **response** field, which is
where the snake_case expectation comes from.

**Second, unverified half — the contract lane may be placing market sells.**
`Bourse.Test.RestReadContractOwnedState.place_algo_order/2`
(`test/support/rest_read_contract_owned_state.ex:93-110`, added by the task 686 reviewer)
passes `time_in_force: "GTC", trigger_price: trigger` while its sibling
`place_resting_order/2` twelve lines above passes `timeInForce: "GTC"`. On the binance family
the snake_case key is the authored one, so those cases route to `algoOrder` as the reviewer
reported — but the inconsistency between the two helpers is the tell, and any venue added to
the algo book that authors the camelCase spelling would silently place a **filled market
sell** in the default (non-`:dangerous`) lane. Not yet reproduced; recorded so the next
change to that helper does not inherit the assumption.

**What one task would cover:** pick one spelling as the unified contract, make every venue's
authored rule and request builder accept it (accepting the other as a deprecated alias rather
than ignoring it), and pin a live test per algo-capable venue asserting that a trigger request
never comes back `filled`. Fixing okx alone reproduces the class on the next venue.

## 2026-08-29 — after the bucket rewrite, 50 runtime endpoints always answer `rate_limit_exceeded`, and a heavy request can be starved by cheap traffic

**Status:** ✅ mostly fixed 2026-09-15 (task 694, shipped `8304acb0ea91`) — (2) a waiter whose budget covers the delay now reserves its unpaid cost, so interleaved cheap traffic can neither spend the reservation nor clamp accrual; (3) repeated checks of one key inside a `check_rates/2` call are coalesced into one combined cost and conflicting bucket definitions for the same key answer `invalid_parameters` before any spend. **(1) is only partly addressed**: the wait budget became per-call (`:rate_limit_max_wait_ms` on `Bourse.HTTP`, default `Bourse.Defaults.rate_limit_max_wait_ms/0`), which removes the racy process-wide config, but the 50 endpoints whose authored cost accrues past the 10 s default still refuse unless the caller passes a larger per-call budget. Repro kept below as the evidence trail.

Task 689 replaced the fixed window with the authored token bucket and removed the
`skip_record` exemption, which is what the task asked for. Three consequences of the new
accounting were measured and left in:

1. **50 of 3,530 runtime endpoints are now uncallable.** Their authored cost accrues past the
   new 10 s bound (`Bourse.Defaults.rate_limit_max_wait_ms/0`), so they refuse immediately:
   13 each on binance, binancecoinm, binanceusdm (heaviest `POST papi/margin/repay-debt`,
   cost 3000 at 20/s = 150 s) and 11 on okx (heaviest `POST asset/monthly-statement`, cost
   1_296_000 at 9.09/s ≈ 39.6 h, which is okx's published one-per-month limit). Before the
   change these went out unlimited and collected the venue's own 429. The only escape today
   is the process-wide `config :bourse, :rate_limit_max_wait_ms`, which is racy under
   concurrent consumers.
2. **Over-capacity accrual is destroyed by interleaved cheap requests.**
   `Bourse.RateLimiter.check_bucket/6` refills to `max(capacity, cost)` per check, so while a
   cost-N request (N > `max_size`) sleeps toward N tokens, a concurrent cost-1 request on the
   same `{exchange, credential, axis}` key refills to `max(max_size, 1)` and clamps the
   accrued tokens back down. Under sustained cheap traffic the heavy endpoint starves to the
   bound instead of being served. Reachable on okx today, where many endpoints are cost 2–50
   against `max_size` 1 on a shared public bucket.
3. **`check_rates/2` double-spends two checks on one key.** Every `check_bucket/6` reads the
   same pre-call state and `persist_buckets/3` `Map.put`s per decision, so the last write
   wins and only one cost is charged. Unreachable through the authored documents today (all
   eleven venues bind `axes: ["request"]` and endpoint `rate_limits` are single maps), but
   nothing rejects the shape and `build_rate_limit_checks/3` already accepts a list.

All three share one mechanism — the bucket's per-check accounting — so they are one class,
not three patches.

## 2026-08-29 — `mix ci` clears its own coverage floor by 0.18 points, so an unrelated change reddens it

**Status:** Coverage fragility noted; remeasurement belongs to existing task 670 and coverage-on-touch (triage 2026-09-15). No separate defect task.

Task 687 took coverage from 75.04 % to **80.18 %** against the alias's own 80.0 % threshold.
The critical tier is comfortably met (Signing 96.04, HmacRecipe 95.99, Signing.Hyperliquid
100.0, Signing.Lighter 95.70, Signing.Lighter.Worker 95.45, OrderPrecision 96.74 — all above
the 95 floor), and the denominator was not gamed: `mix.exs` is untouched and 18 `Mix.Tasks.*`
modules are still measured.

The residue is headroom. Nine surfaces stay below the 80 % standard tier —
`RequestShape.Binance` 48.05, `Order.Builder` 58.33, `Bourse.Unified` 64.66, `Bourse.Symbol`
70.52, `RequestShape.OKX` 71.15, `ResponseParser` 71.16, `RequestShape.Derive` 74.36,
`RequestShape.Bybit` 74.55, `Unified.ReadParse` 74.62 — so a future change adding a handful of
uncovered `lib/` lines turns the coverage step red on a diff that did not cause it. That is
the same red-without-a-defect dynamic task 687 was filed to end, relocated from the live suite
to the coverage gate. `critical-rules.md` § RAISE COVERAGE BEFORE MUTATING already makes each
of those a pre-mutation obligation for whoever touches them next, so this is a fragility
report, not an uncovered-defect report.

## 2026-08-29 — `select_endpoint/5` answers with index 0 when the requested `endpoint_index` does not exist

**Status:** ✅ fixed in task 685 — `select_endpoint/5` and `validate_endpoint_index/3` refuse an explicit invalid or out-of-range index as `invalid_parameters` before dispatch; `Enum.at(configs, idx) || hd(configs)` is gone. Regression tests distinguish that from successful index-zero selection, including against an unreachable `base_url`. **Review correction:** the first cut ordered the `{:ok, idx}` catch-all above the absent/`nil` clause, so `Keyword.fetch/2` returning `{:ok, nil}` — "caller did not pick a book" — was refused as an invalid index. That reddened the live `fetchTicker` error contracts for alpaca, binance and binanceusdm. The clause order is fixed and an explicit `endpoint_index: nil` is now pinned equivalent to omitting the option.

`Bourse.Unified.select_endpoint/5` resolves an explicit index with
`Enum.at(configs, idx) || hd(configs)`, so `endpoint_index: 99` quietly returns index 0's
endpoint. A caller naming a branch that does not exist gets a different branch's data labelled
as the one it asked for, and a contract argument carrying a wrong `source_endpoint_index`
reads the wrong book while looking correct.

This is task 685's class verbatim — *a slice that does not fit must fail loudly, never resolve
to a plausible wrong value* — so it belongs in that task rather than a sibling. Recorded here
with its evidence: the reviewer could only establish that `source_endpoint_index: 2` on
binanceusdm `fetchOpenOrders` was correct by enumerating generated case ids, because an
incorrect one would have read index 0 rather than failing.

## 2026-08-29 — two read surfaces lost their contract home, and one dangerous test asserts a shape the client no longer returns

**Status:** Fixed in task 698 — `GET /v5/user/query-api` is `fetchAccount` (nested map of Get API Key Information) on the testnet main-account key; Binance-family `fetchPositionMode` returns `{"dualSidePosition" => boolean}` and the COIN-M promotion test matches that contract.

Bookkeeping fallout from task 686, both real, neither a defect in the shipped behaviour:

- **bybit `privateGetV5UserQueryApi` is exercised by no case at all.** Removing it and
  `privateGetV5AccountInfo` from `fetchBalance`'s branches was the point of the criterion —
  they are account-classification helpers, not balance carriers — and it moved the venue's
  denominator 78 → 76. `privateGetV5AccountInfo` reappears under `fetchMarginMode`;
  `user/query-api` appears nowhere, even though the key's `kycLevel` / `kycRegion` /
  permission set is the load-bearing operator evidence CLAUDE.md cites for the testnet KYC
  wall being lifted. Coverage loss, not a regression.
- **binancecoinm `fetch_position_mode` has no authored parse slice**, so the documented
  missing-coverage-fails-open path returns `{:ok, %Bourse.RawResponse{payload:
  %{"dualSidePosition" => false}, verification: :unverified}}` while
  `test/live/binancecoinm/binancecoinm_promotion_integration_test.exs` matches a bare map.
  Red today and invisible to `mix check.dispatch`, which excludes `:dangerous`. Predates task
  686; the venue's answer is a single documented boolean, so a slice is cheap — but whether
  `RawResponse` is the intended carve is the decision, and it applies to the whole binance
  family, not to binancecoinm alone.

## 2026-08-28 — bybit `fetch_positions_history`: one dated-contract row fails the WHOLE call with `missing_position_notional_currency`

**Status:** ✅ fixed in task 685, amended in review the same day — `put_notional_currencies/2` no longer fails the whole call. **Review correction:** the landed cut *dropped* the unresolvable row, and `reconcile/2` is wired to `:parse_position` for all eleven venues, so that shortened every positions read, not only history. A shorter list is exactly the plausible-wrong-value this task exists to remove: a consumer summing exposure understates the account, and "am I flat?" answers yes for an account that is not. The row is now retained with `notional`/`notional_currency` blanked — which preserves the struct's documented invariant that `notional_currency` is populated whenever `notional` is — and `info["bourse_notional_unavailable"]` carries `reason`, `context` and the `unstated_notional`, so the gap is machine-visible rather than only a log line. The `Logger.warning` stays. Verified live 2026-09-15: `fetch_positions_history(bybit, category: "linear")` returns `{:ok, [9 rows]}`, every row carrying `notional_currency` (the DOGEUSDT-28AUG26 contract has since expired out of the window, so the marker branch is pinned by unit test rather than by a live row). Dated-future symbol ids remain task 688.

The contract case `bybit:fetchPositionsHistory:0:privateGetV5PositionClosedPnl` fails with

```
{:missing_position_notional_currency, %{exchange: "bybit", symbol: "DOGEUSDT-28AUG26"}}
```

**This is the one red in the 33-failure landed-base run that the classification table above
does not account for.** It is not empty state and not a ledgered demo restriction.

**Root cause — the symbol never got normalized, and the guard halts the batch.**
`Bourse.Unified.DeribitPositionUnits.notional_currency/2` resolves bybit's unit via
`Symbol.parse_extended(position.symbol)`. The row carries bybit's **raw venue id**
`DOGEUSDT-28AUG26` (a dated linear future), not the unified form. Verified locally:

- `Symbol.parse_extended("DOGEUSDT-28AUG26")` -> `{:error, :invalid_format}`
- `Symbol.parse_extended("DOGE/USDT:USDT-260828")` -> `{:ok, %ParsedSymbol{quote: "USDT", ...}}`

`put_notional_currency/2` then refuses to ship a populated `notional` with a nil currency —
correct in isolation — but `put_notional_currencies/2` folds with `reduce_while` and `:halt`s
on the first error. **One unparseable row therefore fails the entire call**: a consumer gets
`{:error, ...}` instead of the position history, including every row that parsed fine.

**Not caused by the task 664/666 wave.** Task 666 added only a `%{"category" => "option"}`
clause to `bybit_position_notional/2`; `DOGEUSDT-28AUG26` is a dated **linear** contract and
does not take that path. This is a latent defect newly exposed by account state — the testnet
account acquired a closed position on a dated contract (expiring the day of the run).

**Two separable defects, worth keeping apart:**

1. *Symbol coverage:* bybit dated-futures ids do not normalize, so the unit cannot be resolved.
2. *Blast radius:* one bad row discards a whole successful multi-row read. Whether the guard
   should halt the batch or degrade that row is a carve decision — but silently returning an
   error for an account that merely holds a dated contract is not defensible either way.

---

## 2026-08-28 — the client's rate limiter grants a 545-deep burst on OKX, then stalls the next call for a full 60 s

**Status:** Landed via task 689, `7c4beddf9c01`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage. Residual bucket-accounting defects are tracked in task 694.

`Bourse.RateLimiter.Shaping` converts a venue's authored bucket into a sliding-window check by
reading **only** `cost`, `axes` and `rate_limit_ms`, then dividing a hardcoded
`@rate_limit_period_ms 60_000` by `rate_limit_ms`. OKX authors
(`priv/venues/okx/authored/venue.json`, `rate_limits.buckets.buckets[0]`):

```json
{"algorithm": "leakyBucket", "max_size": 1, "refill_per_sec": 9.09090909090909,
 "rate_limit_ms": 110.00000000000001, "rolling_window_ms": null}
```

`max_size` and `refill_per_sec` are never read. A leaky bucket of **depth 1 refilling at
9.09 req/s** is therefore executed as **545 weight per rolling 60 s** (`trunc(60_000 / 110)`),
which permits the entire minute's budget to be spent in a single burst.

**Two measured consequences.**

1. **The venue 429s us while our own limiter says `:ok`.** Live against `www.okx.com` +
   `x-simulated-trading: 1`, signed GETs issued back to back with `retry: false`:

   ```
   /api/v5/asset/transfer-state?transId=1   → 200 ×10, then 429 %{"code" => "50011", "msg" => "Too many requests"}
   /api/v5/asset/deposit-history            → 200 ×6,  then 429 %{"code" => "50011", "msg" => "Too many requests"}
   ```

   OKX sends **no `retry-after` header** on that 429 (full header set captured: cloudflare,
   `b-locale`, `x-brokerid`, no `retry-after`), so `Defaults.retry_policy()` `:safe_transient`
   falls through to Req's exponential backoff and turns a fast, informative venue rejection into
   4 attempts spread over ~7 s. Observed in the contract lane as
   `retry: got response with status 429, will retry in 907ms, 3 attempts left`, turning a 200 ms
   case into 1 216 ms.

2. **After saturation the next call sleeps ~60 s, silently.** `Shaping.maybe_rate_limit/3` does
   `Process.sleep(delay_ms)` on `{:delay, _}`, and `RateLimiter.calculate_delay/6` returns
   `oldest_needed_ts + period - now + 1`. When the window filled as a burst, the oldest entry is
   also recent, so the delay is the whole window. Proven:

   ```elixir
   {:ok, pid} = Bourse.RateLimiter.start_link(name: :probe_rl)
   key = {"okx", "k", "request"}; limit = %{requests: 545, period: 60_000}
   for _ <- 1..545, do: :ok = Bourse.RateLimiter.check_rates([{key, limit, 1}], :probe_rl)
   Bourse.RateLimiter.check_rates([{key, limit, 1}], :probe_rl)
   #=> {:delay, 59998}
   Bourse.RateLimiter.check_rates([{key, limit, 4}], :probe_rl)
   #=> {:delay, 59996}
   ```

   A caller sees a 60-second block inside one `Bourse.fetch_*` call, with no `:timeout` option
   able to bound it (the sleep happens **before** the HTTP request, so `receive_timeout` never
   applies). Under ExUnit that is indistinguishable from a hang and lands as
   `test timed out after 60000ms`.

**How close the OKX lane runs to that ceiling:** replaying all 84
`okx` REST-read contract cases against the live demo host consumed **263.4 of the 545 budget in
13.4 s** (measured with `Bourse.RateLimiter.get_cost({"okx", api_key, "request"}, 60_000)` —
`load_markets` 9, then 27.5 / 97.0 / 116.7 / 141.3 / 151.2 / 166.8 / 187.8 / 258.0 at every
tenth case). One extra concurrent OKX consumer — the demo-integration and error modules in the
same run, or `mix ci` running `precommit`'s suite and `bourse.verify_rest_read_contracts`
inside the same minute — reaches 545 and buys a 60 s stall for whichever call arrives next.

**Consumer impact:** a library call that normally returns in ~100 ms can block for a full
minute with no way to bound it, and the burst allowance that causes it also provokes the venue
429s the limiter exists to prevent. It is order-dependent, so it presents as an intermittent
hang on an arbitrary method rather than as a rate-limit error.

**The fix needs a model decision, not a constant tweak.** The authored bucket already carries
the right shape (`max_size` = burst depth, `refill_per_sec` = drain rate); the limiter needs to
honour it instead of substituting a fixed 60 s window. A naive `window = rate_limit_ms *
max_size` is **not** the fix: it makes `max_weight` 1 for OKX, and `check_bucket/6` answers
`:skip_record` for any `cost > max_weight` — silently disabling limiting for the 274 OKX
endpoints (of 433) whose authored cost exceeds 1 — up to 20. Whatever shape is chosen
must (a) bound burst depth so
the client stops earning 429s, (b) bound the worst-case pre-request sleep well below the ExUnit
/ caller timeout, and (c) keep endpoints whose cost exceeds one bucket slot limited rather than
exempt. It touches all eleven venues, so it needs live proof per venue.

**Not the cause of the two OKX contract-lane reds it was found while investigating.** Measured
2026-08-28 across seven runs — isolated (`--only method_fetch_deposit --only
method_fetch_transfer`), whole file, `mix bourse.verify_rest_read_contracts --venue okx`, the
`test/live/okx` directory, and a full `mix test.json` (2 895 tests, 4 m 15 s) —
`okx:fetchDeposit:0:privateGetAssetDepositHistory` takes **66–78 ms** and
`okx:fetchTransfer:0:privateGetAssetTransferState` **192–226 ms**; nothing in the whole suite
exceeded 24 s. Those two reds are the already-recorded conditions: `fetchDeposit` is empty
account state (ledgered as task 570; re-probed live 2026-08-28 —
`GET /api/v5/asset/deposit-history` answers `%{"code" => "0", "data" => [], "msg" => ""}` with
no params, with `limit=10`, with `instType=SPOT`, and with `instId=BTC-USDT`, and
`asset/withdrawal-history` likewise, so no parameter is filtering the rows away), and
`fetchTransfer` is the `billId`-as-`TransferEntry.id` carve defect in its own entry below.

---

## 2026-08-28 — Lighter's differential auth test never built a bad signature, so it pinned the wrong rejection code

**Status:** ✅ fixed 2026-08-28 — test construction corrected; both codes now pinned from live calls.

`test/live/lighter/lighter_signing_integration_test.exs:16` is named "rejects an unauthorized
signing key" but constructed its negative leg by incrementing `account_index` while keeping the
correct key. That is not a signature failure — it is an unregistered `(account, key_index)`
binding, and Lighter answers it with a different code. The test therefore asserted `29500
"invalid signature"` against a call that can only produce `20013`, and had no coverage of the
case its name describes.

Measured live against `testnet.zklighter.elliot.ai` (account 153, key index 3):

| Leg | Response |
|---|---|
| correct key, own account 153 | `200` |
| **corrupted key (one nibble flipped), own account 153** | **`29500 "internal server error: invalid signature"`** |
| correct key, account 154 (does not exist) | `20013 "invalid auth: couldnt find account"` |
| correct key, account 152 (**exists**) | `20013 "invalid auth: couldnt find account"` |

**Venue semantics worth keeping:** `20013 "couldnt find account"` is about the *key-to-account
binding*, not the account's existence — account 152 demonstrably exists and still returns it. The
message is misleading; do not read it as "this index is unallocated". `29500` is the genuine
signature rejection, and reaching it requires corrupting the signing key itself.

**Fix:** the test now runs three legs — success, corrupted key → `29500`, foreign account →
`20013` — so the name matches the assertion and both provider errors are pinned from observed
calls rather than one guessed code.

**Note on how it stayed hidden:** the account index in `~/.secrets` had drifted from the
provisioned account, so the whole lighter lane was failing on `29404`/auth errors and this test's
red was indistinguishable from the rest. It surfaced only once the credentials were corrected and
the lane dropped from 15 failures to 6.

## 2026-08-28 — `Bourse.TestnetTest` wipes the shared credential registry, so later live tests in a full run fail as "No credentials registered"

**Status:** ✅ fixed 2026-08-28 in `90b384e` — `Bourse.Test.TestnetSnapshot` (`test/support/`)
captures the registry before a wipe and restores it in `on_exit`, used by both wiping modules.
Measured before/after on the same tree: **19 flaky → 1**, and zero credential-shaped flakes
remain (the survivor is `okx:fetchPosition`, an empty-account case). Report kept below as the
evidence trail, with two corrections the original entry did not have:

> **There was a second wipe site,** and it was the worse one:
> `test/bourse/private_probe_credential_gate_test.exs` cleared the registry and restored only
> **four** venues from a hand-written list (`bybit`, `binance`, `binance/:futures`, `deribit`),
> leaving the other seven unregistered for the rest of the run — which is why the flakes
> clustered on alpaca / derive / hyperliquid / okx / binanceusdm / binancecoinm. The fix
> restores whatever `test_helper.exs` actually registered, so it stays correct as venues are
> added; the hand-written list is gone.
>
> **The wipe was hiding a genuine red.** With the registry restored,
> `Bourse.TimeWindowIntegrationTest` "binanceusdm fetch_my_trades honors since and until"
> stopped flaking and now fails for its real reason:
> `needs 4 distinct live timestamps; got [1787496365915, 1787496713519]` — the demo account
> holds two trades and the window assertion needs four. That is sandbox state, not a
> credential or naming problem: the earlier reading that
> `BINANCEUSDM_TESTNET_API_KEY` "is never provisioned" is wrong — `test/test_helper.exs`
> registers binanceusdm from the shared `BINANCE_FUTURES_TEST_*` pair exactly as CLAUDE.md
> documents.

**Original report (task 679 review, `mix check.dispatch`):**

`test/bourse/testnet_test.exs` mutates the process-global `Bourse.Testnet` registry that
`test/test_helper.exs` populates once per VM: its `setup` calls `Testnet.clear/0`, and the
`"when the registry is not running"` describe block `GenServer.stop`s the registry and
restarts it **empty** in `on_exit`. Nothing re-registers the env credentials afterwards, so
every live test that runs later in the same VM sees an empty registry.

**Observed** in one `mix check.dispatch` run (2877 tests): 42 tests failed on the first pass
with `No credentials registered for <venue>. Set <VENUE>_TESTNET_API_KEY ...` /
`Missing testnet credentials for <venue>` and then passed on the `mix test.json` auto-retry,
including `Bourse.LiveErrors.{Alpaca,Derive,Hyperliquid,Okx}Test`,
`Bourse.BinanceAuthoredIntegrationTest`, `Bourse.BybitAccountAnalyticsIntegrationTest`,
`Bourse.{Deribit,Derive}AuthoredIntegrationTest`, `Bourse.WS.AuthLiveSmokeTest` and ten
`Bourse.RestReadContracts.*Test` `setup_all` blocks. The same files are green when run on
their own with the identical environment.

**Consequence:** the credential-missing RED that `test_helper.exs` is designed to raise
loudly becomes a *false* red mid-run, and it is indistinguishable from a genuinely missing
credential pair. Auto-retry masks it into a `flaky` bucket rather than a failure, so a full
run's redness gets read as "environmental" without anyone locating the mechanism.

**Not fixed here** (out of task 679's scope): the fix is to make the registry mutation
test-local — restore the `test_helper.exs` registrations in an `on_exit` of that module, or
give `Bourse.Testnet` an isolated table for that suite — not something to change from a
venue-journey review.

---

## 2026-08-28 — OKX `TransferEntry.id` is a `billId`, so `fetch_transfer/2` can never resolve an id that `fetch_transfers/1` returned

**Status:** ✅ fixed in task 685 (carve (a)): list `id` is bills-archive `billId` via a `has_key` branch, never `fallback_keys` onto `transId`. `fetch_transfer/2` refuses a 16+ digit billId as `identifier_class_mismatch` before the wire. `fetchTransfer` stays in the REST-read denominator as write-then-read from `POST /api/v5/asset/transfer` (the lane picks the transfer direction by reading both wallet balances — OKX demo keeps USDT in `trading`, so guessing `funding` first wasted a POST and the retry hit `50011`). Manifest-wide identifier-class gate in `test/bourse/authored_identifier_class_test.exs`.

`fetchTransfers` reads `privateGetAccountBillsArchive` (correctly filtered to `type: "1"`,
the transfer bill type). Probed live against the OKX demo:

```
ROW billId="3858573567752257536" transId=nil type="1" subType="11"   # transfer out
ROW billId="3858546950631964672" transId=nil type="1" subType="12"   # transfer in
ROW billId="3766881906966519808" transId=nil type="1" subType="11"
```

**Genuine transfer rows carry no `transId` at all** — `account/bills-archive` does not return
one. But `priv/venues/okx/authored/normalization.json`'s transfer field map declares

```json
"id": {"coercion": "safeString2", "key": "transId", "fallback_keys": ["billId"]}
```

so the parse silently falls back to `billId` and yields a plausible-looking 19-digit id.
`fetchTransfer` then calls `privateGetAssetTransferState`, which only accepts a real
`transId`, and rejects it:

```
transfer-state <- billId, type=1   -> {"51000", "Parameter transId error"}
transfer-state <- billId           -> {"58129", "transId is incorrect or transId does not match with ‘type’"}
```

**Consumer impact:** the obvious composition — list transfers, then fetch one by its id —
fails for every row on OKX. `Bourse.fetch_transfer/2` is unusable with ids this client itself
produced.

**Why it stayed invisible:** `fallback_keys` turns a missing field into a *wrong* value rather
than `nil`. A nil id would have failed loudly at the first consumer; a billId looks like an id
all the way to the venue's rejection.

**The fix needs a carve decision, not a key swap.** Either (a) `TransferEntry.id` carries the
`billId` and is documented as a bills-archive identifier, with `fetchTransfer` sourcing its
`transId` elsewhere (the transfer-creating `POST /api/v5/asset/transfer` response is the only
place OKX issues one); or (b) `fetchTransfers` moves to a source that returns `transId`; or
(c) `fetchTransfer` is declared unreachable from a `fetchTransfers` id and ledgered. Whichever
is chosen, **drop the `billId` fallback** — an id that cannot be fed back into the venue must
be `nil`, not a different identifier. Audit the other venues' `id` field maps for the same
`fallback_keys` shape.

**Credit where the lane earned it:** this was found only because the REST-read contract case
chains `strategy: resource` — `fetchTransfer` sources its argument from `fetchTransfers`, so
the two methods are forced to compose. It surfaced as a red in every run of the 2026-08-28
wave and six consecutive harness reviewers classified the cluster it sat in as
"environmental / pre-existing" without probing it. The lane was right and the summary reading
was wrong.

---

## 2026-08-28 — alpaca's authored `errors.status_map` is silently dropped by the spec loader, so the venue has no HTTP-status error classification

**Status:** ✅ fixed in task 685 — `build_status_map/2` consumes a bare class string; an unrecognized shape raises. HTTP 401 stays hard auth; 403 uses the authored map when present; 429 stays hard `:rate_limit_exceeded` (same type as alpaca's authored 429). **Review correction:** waking the map exposed a wrong carve underneath it — `status_map["404"]` claimed `OrderNotFound`, so a *ticker* 404 ("no snapshot found for ZZZZZZ") typed as `:order_not_found`. Alpaca's own authority documents 40410000 as "the requested resource was not found" and declares `unmapped_code_disposition: exchange_error`, so the 404 entry is now `ExchangeError`; the genuine order 404 stays typed by the exact provider code (`:invalid_order`, pinned in `test/live/errors/alpaca_test.exs`). The same bare-string shape woke coinbaseexchange's `status_map` too, where `404 => BadSymbol` is correct for a public-only product surface and its contract expectation was re-pinned from the old dead-map fallback. Live 403/404/422 pinned on paper-api; the 429 stays unverified and is ledgered (`docs/prod-verification-ledger.md` — "alpaca — HTTP 429 rate-limit classification"), because the only way to provoke it is to burn the suite's own paper key's request budget.

`priv/venues/alpaca/authored/errors.json` declares `status_map` as bare strings:

```json
{"403": "PermissionDenied", "404": "OrderNotFound", "422": "BadRequest", "429": "RateLimitExceeded"}
```

but `Bourse.Exchange.build_status_map/2` only matches the
`{status, [%{"class" => class} | _]}` shape every other venue authors, and falls through to
`[]` otherwise. Measured: `Bourse.Exchange.new("alpaca")` yields `status_map == %{}` and
`http_exceptions == %{}`.

**Consumer impact:** alpaca 404/422/429 are typed only when the numeric provider code happens
to be one of the six entries in `error_codes`; otherwise they arrive as generic
`exchange_error`. A consumer matching on `:order_not_found` for alpaca never matches.

**This is the silent-carve class:** internally consistent, fully green, and wrong — the loader
reads a shape the venue's authored file does not use, and nothing fails.

**The fix is the class, not the instance.** Rotating alpaca's `status_map` to the shape the
loader consumes leaves the next venue free to ship the same silently-dropped map. `Bourse.Spec.Schema`
(or a manifest-wide test) should raise when any venue's `errors.status_map` entry is not the
shape `build_status_map/2` reads. Note that fixing it **changes the unified type of alpaca 403s**,
so `test/live/journeys/trader/alpaca_test.exs`'s rejection assertion must be re-observed live and
re-pinned in the same change. Also reconcile the hard `401`/`403` short-circuit in
`Bourse.HTTP.Errors.normalize_error/3`, which outranks any authored map today.

---

## 2026-08-28 — binance `fetch_balance` drops the venue's `updateTime`; `Balance.timestamp` and `datetime` come back `nil`

**Status:** Landed via task 686, `c6ebd79fcd96`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

Exact call, against `testnet.binance.vision`:

```elixir
creds = Bourse.Credentials.new!(api_key: System.get_env("BINANCE_TESTNET_API_KEY"),
                                secret:  System.get_env("BINANCE_TESTNET_API_SECRET"))
{:ok, ex} = Bourse.Exchange.new("binance", credentials: creds, sandbox: true)
{:ok, bal} = Bourse.fetch_balance(ex)
```

Observed: `bal.timestamp == nil` and `bal.datetime == nil`, while `bal.info` carries
`"updateTime" => 1787885674508`.

Expected: `priv/venues/binance/authored/normalization.json`'s balance branch (guarded by
`has_key "balances"`) declares `timestamp` as `{coercion: safeInteger, format: ms, key: "updateTime"}`,
and `GET /api/v3/account` documents `updateTime` as a required field. The venue supplies it and
the authored slice asks for it, so the value is lost between payload and struct.

**Why it stayed invisible:** `test/live/journeys/trader/binance_test.exs` omits the bybit
exemplar's `assert_recent_timestamp!(balance.timestamp)` precisely because of this gap. That
omission was correct judgment by its author, but it means no test fails on it. Check the
sibling binance-family venues (`binanceusdm`, `binancecoinm` — same field-map shape over
`"assets"`) in the same change.

---

## 2026-08-28 — the provider-live suite cannot distinguish a deliberately-red ledgered case from a genuine failure, so reviewers dismiss the whole result

**Status:** ✅ fixed 2026-08-28 (task 687) — live-suite summary classifies from the JSON fence in `docs/prod-verification-ledger.md`; raw contracts distinguish empty rows from missing semantic keys; resource cases own a resting/cancelled order or are ledgered as state-dependent. · **Tracked:** task 687.

A full `mix test.json` on `main` confirms ~46–48 failures. Independently classified:

| Class | n | Nature |
|---|---|---|
| Lighter native signer `helper_unavailable` / `:enoent` | ~12 | host toolchain — `go` absent, so `priv/native/lighter_signer/` (gitignored build artifact) is never built |
| Lighter account `29404 not found` | ~6 | operator credential — see the Lighter entry below |
| OKX `50038 "unavailable in demo trading"` | 6 | **deliberately red**: ledgered under tasks 311 / 389 / 441 and deliberately kept in the denominator, because dropping the row is the "green lie" CLAUDE.md forbids |
| "provider account state has no id from `fetchOpenOrders`" / "did not exercise the read" | ~13 | contract branches that only execute when a resting order / open position / deposit exists; nothing populates that state |
| `binancecoinm` `balance.total["BTC"] >= 0.01` vs `0.00999833` | 1 | hardcoded threshold against a drained wallet |
| suspicious, warrant real investigation | ~5 | see below |

**The defect is not the red count — much of it is by design.** It is that the summary carries
no way to tell "deliberately unverified, ledgered, expected red" apart from "actually broken".
Measured consequence: across six harness reviews in one day, every reviewer labelled the entire
cluster "environmental / pre-existing", reproduced two or three of its causes, and approved over
the rest. That is the gate training its own users to ignore it.

**All five adjudicated live on 2026-08-28 — one real defect, four empty state:**

- ~~`bybit:fetchMySettlementHistory`~~ — **adjudicated 2026-08-28: empty account state, not carve divergence.** Probed live on the testnet main-account key: `GET /v5/asset/delivery-record` with `limit=10` answers `status 200, retCode 0, retMsg "OK", result.list == []` for **all three** categories (`inverse`, `linear`, `option`). The account has never settled a position, so there are no rows — the `deliveryPrice`/`deliveryRpl` keys are absent because the payload is empty, not because the carve is wrong. Closing this needs a settled position on the testnet account.

  **The lane's own diagnostics caused this misreading, and that part is a real defect.** For a
  `representation: raw` case, `Bourse.Test.RestReadContractScenario` reports
  *"raw provider payload contains none of the semantic keys [...]"* — wording that describes a
  shape mismatch — when the actual condition is zero rows. Every other empty-state case in the
  lane says so plainly (*"provider account state has no id from fetchOpenOrders"*,
  *"did not exercise the read. Populate the sandbox account"*). The raw branch should
  distinguish "provider returned no rows" from "rows present but none carry the semantic keys";
  as written it invites exactly the misclassification recorded here — an orchestrator reading
  the summary singled this case out as the strongest carve-divergence suspect in the whole
  suite, and it was empty state.
- ~~`lighter:fetchOHLCV: provider returned no rows`~~ — **adjudicated 2026-08-28: not a client defect, do not re-investigate.** Probed live against `testnet.zklighter.elliot.ai`: `publicGetCandles` with `market_id=1` (and `0`), `resolution="1h"`, a 24h `start_timestamp`/`end_timestamp` window and `count_back=0` answers HTTP 200 with `%{"code" => 200, "r" => "1h", "c" => []}`. The venue **echoes the resolution back**, and a parameterless call is rejected as `bad_request` — so the request is well-formed and understood; the testnet simply carries no candle history for the probed markets. Note this holds *despite* `priv/venues/lighter/authored/endpoints.json` marking `market_id` and `resolution` as `{"kind": "unresolved", "reason": "dynamic_construction"}`, which is what made this look like a parameter bug.
- ~~`hyperliquid:fetchPosition` and `binanceusdm:fetchPositionADLRank`~~ — **adjudicated 2026-08-28: empty account state, not a parse gap.** `Bourse.fetch_positions/1` returns `{:ok, []}` live on both accounts (hyperliquid testnet, binanceusdm demo), so there is no position for `fetchPosition` to return and nothing for the venue to ADL-rank. Both close by opening a position on the respective sandbox account.
- **`okx:fetchTransfer`** — **CONFIRMED A REAL DEFECT, 2026-08-28. Own entry below.**

---

## 2026-08-28 — OKX already-canceled cancel classifies as `:exchange_error` code `"1"`, not `:order_not_found` 51400

**Status:** ✅ fixed 2026-08-28 (task 690) — batch refusals type from `data[0].sCode`. Repro kept below as the evidence trail.

`POST /api/v5/trade/cancel-order` for an order that is already canceled (or filled, or
missing) answers HTTP 200 with a batch envelope: outer `code` `"1"`, `msg` `"All operations
failed"`, and the per-order outcome only in `data[0]` (`sCode` `"51400"`, `sMsg` `"Order
cancellation failed as the order has been filled, canceled or does not exist."`).

Authored mapping of `51400` is `OrderNotFound` (`priv/venues/okx/authored/raw.json`).
Classification keys `runtime_code_fields: ["code"]`, so the typed error is
`%Error{type: :exchange_error, code: "1"}`. `Bourse.Test.Journeys.Case.release_order!/3`
therefore missed the already-gone case until it grew an explicit `sCode 51400` clause.

**Observed live 2026-08-28** on `www.okx.com` with `x-simulated-trading: 1`, after a
successful cancel of a resting `BTC-USDT-SWAP` limit (ordId `3871666065072578560`).
Authority: OKX API v5 51400 (https://www.okx.com/docs-v5/en/#error-code).

**Fixed in task 690.** Outer code `"1"` with `data[].sCode` present classifies from the
per-order code: 51400 → `:order_not_found`, 51121 → `:invalid_order`. The outer envelope
is still on `raw`.

---

## 2026-08-28 — `Bourse.WS.connect/3` swallows `:no_auth_pattern` and hands back an open **unauthenticated** private socket

**Status:** ✅ fixed 2026-08-28 (task 690) — derive authors `:eip191_jsonrpc_login`; `connect/3` no longer maps `:no_auth_pattern` to ok. Repro kept below as the evidence trail.

`lib/bourse/ws.ex:247` maps the missing-handshake case straight to success:

```elixir
{:error, :no_auth_pattern} ->
  {:ok, ws}
```

So for any venue whose authored spec declares no `auth_pattern` — **derive** is the live
instance — `WS.connect(exchange, :private)` returns `{:ok, ws}` with `ws.auth == nil` and
`state == :connected`. The caller has an open socket on the private section that will never
deliver private events: exactly the "silently empty stream" failure the same paragraph in
`CLAUDE.md` warns about.

**CLAUDE.md is wrong about this today.** Its WebSocket section states derive's unwired auth
surface "**fails loudly rather than silently**". It does not fail at all.

**Observed live 2026-08-28** against `wss://api-demo.lyra.finance/ws` (evidence produced by
the cross-family reviewer on harness run `run-1787878849306-7a0d7ae9`, task 682, and
re-read on the landed tree):

- `WS.connect(exchange, :private)` → `{:ok, ws}`, `ws.auth == nil`, `state == :connected`
- `WS.subscribe(ws, ["144422.orders"])` before login → `{:error, {:subscription_rejected, _}}`,
  envelope code `13000` wrapping `14022` "Subscription to a private channel failed"
- venue-owned `public/login` (EIP-191 over the ms timestamp, Admin session key, wallet =
  `X-LyraWallet`) → `{"result" => [144422]}`; the same subscribe then returns `:ok` and
  delivers `order_status` `open` → `cancelled`

**Consumer impact:** a consumer that treats `{:ok, ws}` as "private stream ready" gets a
socket that is connected and permanently silent. The repro is in
`test/live/journeys/trader/derive_test.exs` (landed `87572cd`), which now asserts
`is_nil(ws.auth)` rather than reading `:connected` as success.

**Fixed in task 690.** Derive authors `:eip191_jsonrpc_login` so `public/login` runs as the
handshake. `maybe_authenticate/5` no longer maps `:no_auth_pattern` to `{:ok, ws}` — a
private section without a pattern closes the socket. Hyperliquid's `nil` pattern stays
correct (no private URL; address-scoped public subscriptions).

---

## 2026-08-28 — `mix bourse.check_lighter_signer` exits 0 while reporting "NOT RUN" — a gate that is green without running

**Status:** ✅ fixed 2026-08-28 (task 687) — `mix bourse.check_lighter_signer` raises `Mix.Error` (Mix exit 1) when Go or a C compiler is missing, with setup text naming `mix bourse.build_lighter_signer`. · **Tracked:** task 687.

With `go` absent from `PATH` the task prints

```
Lighter native verification NOT RUN: missing go.
The lighter-signer workflow remains the mandatory native gate.
```

and **exits 0**, so `mix check.dispatch` records it as a passing step. `priv/native/lighter_signer/*/`
is gitignored (`.gitignore:13`) — the helper is a build artifact of
`mix bourse.build_lighter_signer`, which needs Go — so on a host without Go the directory
does not exist and the signer is genuinely unavailable.

**Why this matters beyond the one task:** four independent harness reviewers in the
2026-08-28 wave each read this "pass" and none noticed the Lighter toolchain was simply
missing; they attributed the resulting `{:lighter_signing, :helper_unavailable}` / `:enoent`
reds to three mutually inconsistent causes across runs 673, 682 and 681. A gate that cannot
run must be RED with actionable setup text (`critical-rules.md` § NEVER HIDE TEST FAILURES),
not `:ok`.

---

## 2026-08-28 — Lighter testnet credentials point at an account the venue does not know (29404), so the trader journey's round-trip cannot be proven

**Status:** Operator-gated account recheck tracked in task 327 (triage 2026-09-15); the historical credential failure has not been re-proven today.

Reproduced live against `testnet.zklighter.elliot.ai` on harness run
`run-1787878849303-bd01a1ca` (task 681):

- `publicGetAccount` → HTTP 400, code **29404** "not found"
- `sendTx` create → code **21100** "account not found"
- private REST reads → code **20013** "couldnt find account"
- `account_all_orders` with a helper-minted auth token → **20013**
- `WS.connect(:private)` → `:no_url_configured`

`LIGHTER_TESTNET_API_KEY_INDEX` / `LIGHTER_TESTNET_ACCOUNT_INDEX` /
`LIGHTER_TESTNET_API_PRIVATE_KEY` need to point at a recognized testnet account before
`test/live/journeys/trader/lighter_test.exs` can go green. The journey is authored and
flunks loudly with that setup text; it is `:dangerous`-tagged, so the red is only visible
under `--include dangerous`.

---

## 2026-08-28 — `mix check.dispatch` is structurally red on `main`: a pre-existing `reach.check` smell makes "check.dispatch passes" unsatisfiable as an acceptance criterion

**Status:** ✅ fixed 2026-08-28 — `Bourse.Spec.Disk.assemble_maps/2` now declares the
explicit `%{required(String.t()) => map() | list()}` shape (harness run
`run-1787882432734-2e732247`, reviewer fix riding task 674). `MIX_ENV=dev mix reach.check
--arch --smells --strict --path lib` is green. Repro kept below as the evidence trail.

On landed `main` (`5923baf`), offline and independent of any task:

```
$ MIX_ENV=dev mix reach.check --arch --smells --strict --path lib
Architecture Policy OK
broad map contract
  lib/bourse/spec/disk.ex:68
    Bourse.Spec.Disk.assemble_maps/2 parameter 1 declares map() but uses strict access
    within the fixed key set "endpoints.json", "errors.json", "markets.json",
    "normalization.json", "raw.json", "venue.json"; declare the shape explicitly
** (Mix) Smell check failed: 1 finding(s)
```

`check.dispatch` never reaches this step today because `precommit`'s provider-live
`test.json` exits first — so the smell is latent, and would surface the moment the live
suite goes green.

**Why it is worth recording rather than shrugging at:** tasks are being written with
"`mix check.dispatch` passes" as an acceptance criterion (task 665 is the landed instance).
That criterion cannot be met while this stands, which trains every reviewer to approve
around the gate instead of reading it.

---

## 2026-08-28 — deribit `fetch_option_chain/2`: an underlying with a live linear book answers `{:ok, %{}}`, and `implied_volatility` is `nil` on every leg

**Status:** Landed via task 686, `c6ebd79fcd96`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**The call:** `Bourse.fetch_option_chain(exchange, currency)` against `deribit`.

**Defect 1 — an underlying whose book is USDC-settled answers with an empty success.**

```elixir
{:ok, ex} = Bourse.exchange(:deribit)
Bourse.fetch_option_chain(ex, "SOL")   # => {:ok, %{}}
Bourse.fetch_option_chain(ex, "USDC")  # => 3_626 legs; 682 of them carry currency: "SOL"
```

Deribit lists altcoin options as USDC-margined linear contracts named
`SOL_USDC-25DEC26-115-P` and indexes them under `currency=USDC`, not `currency=SOL`.
Measured on the returned chain: **SOL 682 instruments, 431 with open interest,
1_331_780 SOL total OI**, `info["mark_iv"]` present on all 682. The same book carries
XRP 500, HYPE 446, TRX 306, AVAX 284 — and BTC 752 / ETH 656 as their linear duplicates.

The venue's own `get_instruments?currency=SOL&kind=option` also returns `[]`, so bourse
relays the venue faithfully. But the unified method takes an **underlying**, and this
underlying has a book — bourse itself proves it knows the mapping, because every leg it
returns from the USDC call is already tagged `currency: "SOL"`.

**Expected.** Either resolve `"SOL"` to the settlement currency that carries its book, or
return `{:error, %Bourse.Error{type: :not_supported}}` — which the docstring's Errors
section already promises. `{:ok, %{}}` is indistinguishable from "this venue lists no
options on this underlying", so the consumer records a live market as absent and cannot
tell the two apart. Silent-empty is the false-green shape; a wrong answer that looks like
a clean answer.

**Defect 2 — the normalized `implied_volatility` field is never populated.**

```elixir
{:ok, btc} = Bourse.fetch_option_chain(ex, "BTC")
map_size(btc)                                                       # 1070
Enum.count(Map.values(btc), &(&1.implied_volatility != nil))        # 0
Enum.count(Map.values(btc), &(get_in(&1.info, ["mark_iv"]) != nil)) # 1070
```

`%Bourse.OptionData{}` declares the field, Deribit supplies a value on every leg, and the
struct field is `nil` throughout — inverse book and linear book alike (682/682 SOL legs
also carry `info["mark_iv"]` while the struct field is nil). The normalization exists and
does not fill.

**Consumer impact (trading_dashboard).** The macro panel's crypto-positioning block —
skew, ATM IV, gamma flip, zero gamma — does not use `fetch_option_chain` at all. It calls
`public_get_get_book_summary_by_currency` through the implicit API and reads raw rows,
precisely because the raw payload carries `mark_iv` and the normalized struct does not
(`lib/trading_dashboard/macro/crypto.ex:800`). Defect 1 is what led a trader session to
conclude from `{:ok, %{}}` that Deribit runs no SOL options market at all; the correction
cost a full re-probe of the venue. No local workaround is needed — passing `"USDC"` and
filtering on `.currency` reaches everything — but the empty-success shape is what made the
wrong reading look verified.

**Not a bourse defect, recorded here so the next reader does not re-derive it:** the linear
instrument name also fails `ZenQuant.Options.Deribit.parse_option/1`
(`{:error, :invalid_format}` on `SOL_USDC-25DEC26-115-P`, `{:ok, …}` on
`BTC-25SEP26-90000-C`). That belongs to zen_quant and is filed there.

---

## 2026-08-27 — `HmacRecipe`'s canonical-string fallback ladders silently pick a block instead of failing; no test reaches past their first rung

**Status:** ✅ fixed in task 685 — `canonical_block!/2` raises on a missing or malformed method block instead of `Map.values() |> List.first()`. Malformed path predicates raise. **muex:** before (BUGS 2026-08-27) muex 0.9.1, 2366 mutants, 421 survivors. After-count was not re-run in this delivery (the implementer's muex invocation produced no JSON after seven minutes; this review did not fabricate a count). The `List.first()` rungs no longer exist, so those surviving mutants are gone by deletion.

**The call:** any signed request whose authored `canonical_string` slice does not carry the
exact key the ladder looks for first.

**Observed:** two fallback ladders resolve which canonical-string block signs a request:

```elixir
# get_unfiltered_components/2, hmac_recipe.ex:270
cs[method] || cs["*"] || cs |> Map.values() |> List.first() || cs

# get_canonical_block/1, hmac_recipe.ex:722
cs["POST"] || cs["GET"] || cs["*"] || cs |> Map.values() |> List.first() || cs
```

Every mutation of the `||` operators from the second rung onward **survives** — no test in
`test/bourse/signing`, `test/bourse/signing_test.exs` or `test/bourse/ws/auth` (274 tests)
distinguishes them. The same holds for the permissive defaults in `path_predicate?/4`
(`hmac_recipe.ex:302`): clauses 1 (`nil -> true`) and 3 (`_ -> true`) can each be deleted
without reddening the suite, and the `unfiltered != []` comparison at `:259` survives
inversion.

**Expected:** either the later rungs are reachable and pinned by a test, or they do not exist.

**Why this is a design report rather than a coverage report:** the eleven authored documents
are a closed set, and every one of them apparently authors the key the first rung reads.
`Map.values() |> List.first()` then means "if the recipe is not the shape we expect, sign with
whichever block the map happens to yield first" — an ordering-dependent guess in the module
that produces signatures. That is the shape CLAUDE.md's `path_params` note argues against:
the fix for a slot that must never drift is a raising clause, not a pre-built fallback that
reads the wrong place quietly. Mitigating: a wrong canonical block yields a wrong signature,
which the venue rejects — the failure is loud at the wire, not silent in our numbers.

**Consumer impact:** none observed today; no venue currently authors a recipe that reaches
past the first rung. The report is that the code carries three untested branches whose only
job is to guess when an authored slice is malformed.

**Repro:**

```
mix muex --files lib/bourse/signing/hmac_recipe.ex \
  --test-paths test/bourse/signing,test/bourse/signing_test.exs,test/bourse/ws/auth \
  --timeout 60000 --no-filter --no-optimize --fail-at 0
```

Score 78.91 % (1575 killed / 421 survived / 370 invalid / 0 timeout). Verdicts were
reproducible here: two byte-identical runs over `lib/bourse/signing/eip712.ex` (398 mutants)
returned identical counts **and** identical survivor lists, so the upstream flicker warning
did not reproduce on this surface. The 370 invalids are a muex artifact, not code: they
survive the 0.9.1 map-update fix unchanged, so a second invalid-producing cause is still
open upstream and silently removes ~16 % of mutants from the denominator.

## 2026-08-27 — `spec_disk_test` pins pre-rotation spec hashes, so every legitimate authored-spec edit reds the suite

**Status:** ✅ fixed 2026-08-28 (task 687) — hash pin **retired**. It proved the one-shot
rotation was lossless; re-recording would only hash the same loader. The structural
split test remains. · **Tracked:** task 687.

**The call:** `mix test.json --quiet test/bourse` on a clean checkout.

**Observed:** `test/bourse/spec_disk_test.exs:63` — "assembled maps match the recorded
original hashes for all eleven venues" — fails for bybit:

```
left:  [{"bybit",
         "01870382452ab401675afb4f96713186c60e1f6e6381ffa032a1714096980fa5",
         "e048a0d6eae4de899f3a111e9b9bafcc9311a630e68fd1674d0e6bf58ad92f69"}]
right: []
```

**Expected:** green on a clean tree, or a red that names a real defect.

**Why it fires:** the hashes in `priv/venues/_shared/binance_family/rotation_report.json` are
the SHA-256 of the facet-major maps as they stood *before* `spec.json` was deleted — a
one-time migration artifact, per the test's own moduledoc ("recorded before `spec.json` was
deleted"). bybit's authored document has since been edited three times on purpose:
`443968c` (carve the account-classification helpers), `9e05b17` (order identity on linear,
convert map, coin filter), `dca6a8c` (convert executed live). Each edit necessarily changes
the assembled map, so the pin cannot hold. The other ten venues still match because nothing
edited them since the rotation.

**The design question underneath:** the pin proved *the rotation was lossless*. That
guarantee expired with the first legitimate authored edit. Re-recording the hash after every
spec change does not restore it — the new hash is produced by the same loader it is meant to
check, so it degrades to a change-detector that reds on normal work. The durable invariant is
the file's *other* test ("every runtime venue is split endpoint-major and has no leftover
`spec.json`"), which is unaffected. Deciding whether to re-scope, re-record, or retire the
hash test is an owner call, not a mechanical fix — which is why this is filed rather than
patched.

**Consumer impact:** none at runtime. The cost is to the gates: `mix precommit` and
`mix ci` cannot go green on a clean tree, and any tool that runs the suite per-iteration
reads a permanent red. It blocked a mutation-testing run outright — a test that fails on
unmutated code marks every mutant as killed, so the score would have read 100 %.

## 2026-08-24 — bybit `watchOrders` channel template is `":{symbol}"` — `Bourse.WS.watch_orders/2` cannot reach the venue's real private order topic

**Status:** ✅ fixed 2026-08-28 (task 690) — authored template is the account-wide `"order"`
topic; `watch_orders/2` no longer needs a symbol. Repro kept below as the evidence trail.

**The call:** `Bourse.WS.watch_orders(ws, ...)` on a bybit private connection — the unified
way a consumer would ask for the account's order stream.

**Observed:** the authored channel template for bybit `watchOrders`
(`priv/venues/bybit/authored/venue.json`) is the degenerate string `":{symbol}"`. With no
symbol, `Channels.build/4` errors `:missing_symbol`; with a symbol it interpolates to a
symbol-suffixed topic that bybit does not serve. The venue's real private order topic is the
flat, account-wide `"order"` (verified live 2026-08-24 on the testnet: subscribing `"order"`
delivers the account's order events — `orderStatus "New"` on place, `"Cancelled"` /
`cancelType "CancelByUser"` on cancel; see
`test/live/journeys/trader/bybit_test.exs`, the private-stream describe block).

**Expected:** `watch_orders/2` on bybit subscribes `"order"` and delivers the account's
order events without the caller needing to know the venue topic string.

**Repro:** `{:ok, ws} = Bourse.WS.connect(exchange, :private); Bourse.WS.watch_orders(ws)`
→ `:missing_symbol` from channel build, while a direct
`Bourse.WS.subscribe(ws, ["order"])` streams events immediately.

**Fixed in task 690.** The authored `watchOrders` template is `"order"`. `watch_orders/2`
subscribes that topic without a symbol. Bybit private pushes still arrive as
`{:websocket_unmatched_response, frame}` because they carry an `"id"`; that delivery
shape is documented on `watch_orders/2` and pinned by the trader journey.

## 2026-08-24 — `Bourse.Symbol.reverse_aliases/1` is not injective on hyperliquid's authored alias map — one currency is silently dropped

**Status:** Landed via task 688, `d94f63344ec6`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**The call:** `Bourse.Symbol.reverse_aliases(aliases)` where `aliases` is a venue's authored
`markets.patterns.currency_aliases` — public API, meant to invert exchange→unified into
unified→exchange for `apply_alias/2`.

**Observed:** `priv/venues/hyperliquid/authored/markets.json` maps **two** keys onto `"BTC"` —
`"XBT" => "BTC"` and `"UBTC" => "BTC"`. `reverse_aliases/1` is `Map.new(aliases, fn {k, v} -> {v, k} end)`
(`lib/bourse/symbol.ex:318-320`), so the collision is discarded without a word: a 14-entry map
comes back with **13** entries, and `rev["BTC"]` is `"XBT"`. Which key survives is decided by map
iteration order, which Elixir does not specify — the code makes no choice, it just keeps whatever
comes last. The round trip is therefore not the identity:

```elixir
hl = Jason.decode!(File.read!("priv/venues/hyperliquid/authored/markets.json"))["patterns"]["currency_aliases"]
map_size(hl)                                          #=> 14
rev = Bourse.Symbol.reverse_aliases(hl)
map_size(rev)                                         #=> 13
Map.get(rev, "BTC")                                   #=> "XBT"

"UBTC" |> Bourse.Symbol.apply_alias(hl) |> Bourse.Symbol.apply_alias(rev)   #=> "XBT"   (expected "UBTC")
"XBT"  |> Bourse.Symbol.apply_alias(hl) |> Bourse.Symbol.apply_alias(rev)   #=> "XBT"   (correct, by luck)
```

**Expected:** either the inversion refuses a non-injective map (or names the collision), or the
venue's authored map carries a designated canonical exchange code per unified code, so that
`apply_alias/2 |> apply_alias(reverse_aliases(…))` is the identity on every key the venue
authored. Hyperliquid's `"UBTC"` is a real, traded market prefix — it is not a duplicate to
throw away.

**Scope, measured:** eight of the eleven venues author a non-empty `currency_aliases`
(binance / binancecoinm / binanceusdm 4 entries, bybit / deribit / derive 2, okx 3,
hyperliquid 14; alpaca, coinbaseexchange author none and lighter authors `{}`). Only
hyperliquid's map has colliding values — the other seven invert losslessly today, so this is a
latent trap for the rest and a live wrong answer for hyperliquid.

**Impact:** consumer-only — `reverse_aliases/1` has **zero callers in `lib/`** (grep across the
tree finds only its own `@doc`/`@spec`/`def`), so nothing in this client is wrong because of it.
A consumer that builds a unified→exchange map from the venue's own alias slice to construct
hyperliquid ids gets `"BTC" => "XBT"`, which is not the code hyperliquid uses for that market,
and gets no error saying so.

## 2026-08-24 — `Bourse.Symbol.normalize/3`'s `:aliases` option rewrites the whole symbol, not currencies — real venue aliases corrupt real market ids

**Status:** Landed via task 688, `d94f63344ec6`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**The call:** `Bourse.Symbol.normalize(exchange_id, %{separator: "", case: :upper}, aliases: venue_aliases)`
— the documented `:aliases` option (`lib/bourse/symbol.ex:138`).

**Observed:** `apply_currency_aliases/2` (`lib/bourse/symbol.ex:569-573`) reduces over the alias
map with `String.replace(acc, from, to)` on the *whole* symbol string. The replacement is not
anchored to a currency boundary, so an alias key that happens to be a substring of a different
currency is rewritten too:

```elixir
bin = Jason.decode!(File.read!("priv/venues/binance/authored/markets.json"))["patterns"]["currency_aliases"]
#=> %{"BCC" => "BCC", "BCHSV" => "BSV", "XBT" => "BTC", "YOYO" => "YOYOW"}

Bourse.Symbol.normalize("AIXBTUSDT", %{separator: "", case: :upper}, aliases: bin)
#=> "AIBTC/USDT"      # expected "AIXBT/USDT" — AIXBT is a market of its own, not XBT
Bourse.Symbol.normalize("AIXBTUSDT", %{separator: "", case: :upper})
#=> "AIXBT/USDT"      # correct without the option

okx = Jason.decode!(File.read!("priv/venues/okx/authored/markets.json"))["patterns"]["currency_aliases"]
#=> %{"AE" => "AET", "BCHSV" => "BSV", "XBT" => "BTC"}
Bourse.Symbol.normalize("AEVO-USDT", %{separator: "-", case: :upper}, aliases: okx)
#=> "AETVO/USDT"      # expected "AEVO/USDT"
```

Sweeping every alias key against the market ids in `test/reference_slice/<venue>.json` (frozen
CCXT-derived test input, so treat the id list as indicative rather than authoritative) counts the
boundary-crossing hits: okx 43 symbols (`AE` inside `AEVO`, `AERGO`, `AERO`, `ADA/EUR`, …),
binance 40 (`XBT` inside `AIXBT`, and inside every `…X/BTC` pair such as `AVAX/BTC`, `CFX/BTC`),
bybit 3, binanceusdm 1, hyperliquid 1 — all of them `AIXBT` or the `X`+`BTC` seam. binancecoinm,
deribit and derive: none.

A second, weaker problem sits on top of the same three lines: `Enum.reduce` iterates a **map**,
whose order Elixir does not specify, so a chained replacement (one alias's output containing
another alias's key) would resolve order-dependently. **Unverified** — sweeping the eight
authored alias maps found no key that is a substring of another key or of another key's value,
so no real-data instance of the chaining hazard exists today. Reported as a latent hazard only.

**Expected:** aliases apply per currency after splitting (the same `Map.get/3` the reverse path
already uses), not as a substring rewrite over the raw id.

**Impact:** consumer-only, and confined to this one option. No caller in `lib/` passes
`:aliases` — the single in-tree caller of `normalize/3` is
`lib/bourse/unified/request_shape.ex:928`, which passes no opts, and the client's own
exchange→unified path (`Bourse.Symbol.from_exchange_id/3` → `apply_reverse_alias/2`) does the
correct per-currency lookup: `Bourse.Symbol.from_exchange_id("AIXBTUSDT", ex, :spot)` returns
`"AIXBT/USDT"`. So a consumer following the documented option gets a *worse* answer than one
using the client's own conversion, with no error — a symbol that names a different market.

## 2026-08-24 — `Bourse.Symbol`: three untested surfaces where the code and the docs already disagree

**Status:** Landed via task 688, `d94f63344ec6`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**Provenance for all three, and for the two entries above:** a mutation-testing *testability*
survey of the offline-testable surface, run 2026-08-24. `Bourse.Symbol` **was not itself
mutation-tested** — it surfaced in the survey as a large, offline, thinly-tested module, and the
findings below come from reading `lib/bourse/symbol.ex` and re-measuring the claims with
`mix run` against the authored specs. No production code and no test was changed.

**1. The single-digit expiry day (1st–9th) is never exercised.** `convert_date/3`'s
`:yymmdd -> :ddmmmyy` clause (`symbol.ex:401-405`) emits the day unpadded, and
`pad_ddmmmyy_day/1` (`symbol.ex:1479-1483`, with the comment recording the venue split at
`:1477-1478`) re-pads it for exactly one caller — the bybit
linear-future branch of `apply_future_ddmmmyy/2` (`symbol.ex:973`), whose comment records the
split: bybit pads (`04SEP26`), deribit's live ids do not (`4SEP26`). Both behaviours ride on a
day in 1–9, and no `.exs` test in the repo supplies one. The `DDMMMYY` literals in `test/**/*.exs`
are `31JUL26` (12×), `31JAN25` (6×), `18JUL26` (4×), `28AUG26` (3×), `22JUN26` (2×), `26JUN26`,
`08AUG26`; the `YYMMDD` literals are `-250131-`, `-260731-`, `-260723-`, `-260814-`, `-260116-`,
`-270625-`, `-260622-`, `-260807-`. The only single-digit day in the suite is the `08AUG26` /
`-260807-` pair at `test/bourse/unified/option_quantity_test.exs:323` — an already-padded
**option** market-id fixture, and `pad_ddmmmyy_day/1` is reachable only from the **future**
branch. No `.exs` file references `convert_date` or `pad_ddmmmyy` at all. Live values for the
record: `convert_date("260807", :yymmdd, :ddmmmyy) #=> "7AUG26"`, and the padded form the bybit
branch would produce is `"07AUG26"` — a mutation that deletes either the padding clause or its
`day in ?1..?9` guard is invisible to the suite.

**2. `convert_date/3` promises an `ArgumentError` it does not raise on two paths.** The `@doc`
at `symbol.ex:385-387` states: *"Supported formats: `:yymmdd`, `:ddmmmyy`, `:yyyymmdd`. Raises
`ArgumentError` naming both formats and the input when the pair is unsupported **or the input
does not match the declared source format**."* The `:ddmmmyy -> :yymmdd` clause honours that (it
regex-matches and raises). The two clauses at `symbol.ex:422-423` validate neither length nor
digit-ness and silently return garbage:

```elixir
Bourse.Symbol.convert_date("BANANA",     :yyyymmdd, :yymmdd)   #=> "NANA"
Bourse.Symbol.convert_date("nonsense",   :yymmdd,   :yyyymmdd) #=> "20nonsense"
Bourse.Symbol.convert_date("2026-03-27", :yyyymmdd, :yymmdd)   #=> "26-03-27"
```

The `:yymmdd -> :ddmmmyy` clause is only accidentally stricter — it raises from
`String.to_integer/1` or `Map.fetch!/2`, not from a check it performs. No test pins any of this,
so the doc and the code can keep disagreeing.

**3. `split_no_separator/2` ignores `get_quote_currencies/1` and its `extra` parameter
entirely.** `split_no_separator/2` (`symbol.ex:1450-1461`) comprehends over the hardcoded module
attribute `@sorted_quote_currencies` (`symbol.ex:54-55`, the 13 default quotes). It is the
splitter for the whole exchange→unified path — `reverse_spot/3` (`:1051`), `reverse_swap/3`
(`:1084`), and the option branches (`:1194`, `:1219`) — i.e. everything reached from the public
`Bourse.Symbol.from_exchange_id/3`. `get_quote_currencies/1` (`symbol.ex:369-376`), which exists
to extend that list, has exactly one caller in the tree: `find_and_split/2` (`symbol.ex:583`),
on the `normalize/3` side. So the venue-extensible quote list is reachable only through
`normalize/3`'s `:quote_currencies` option and never through `from_exchange_id/3`, which has no
such knob:

```elixir
{:ok, ex} = Bourse.Exchange.new("binance")
Bourse.Symbol.from_exchange_id("BTCTRY", ex, :spot)   #=> "BTCTRY"    (unsplit — TRY is a real binance quote)
Bourse.Symbol.from_exchange_id("BTCUSDT", ex, :spot)  #=> "BTC/USDT"

Bourse.Symbol.normalize("BTCTRY", %{separator: "", case: :upper}, quote_currencies: ["TRY"])
#=> "BTC/TRY"
```

No test covers either half of that asymmetry (`grep` finds no `.exs` reference to
`get_quote_currencies` or `quote_currencies:`), so nothing fails if the `extra` branch is
mutated away.

## 2026-08-24 — bybit: intermittent `invalid_nonce` on signed reads — the client signs before it throttles, and the authored `recv_window` never reaches the wire

**Status:** Landed via task 689, `7c4beddf9c01`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage. Residual bucket-accounting defects are tracked in task 694.

**The call:** `mix ccxt.verify_rest_read_contracts --venue bybit` — `fetchTradingFee:0`,
`fetchTradingFees:0` and `fetchBorrowRateHistory:0` fail non-deterministically with

```
invalid_nonce: invalid request, please check your server timestamp or recv_window param:
req_timestamp[1787543676760], server_timestamp[1787543687242], recv_window[5000]
```

**Observed — two distinct defects, both cross-venue:**

1. **Sign-then-throttle ordering.** `Bourse.Dispatch.call/4` runs `Signing.sign/4` (which
   stamps the timestamp) and only then `HTTP.signed_request`, where
   `Shaping.maybe_rate_limit/3` blocks inside `do_signed_request/5`. The observed staleness
   gap is 10.5 s of queue wait; measured clock skew against `/v5/market/time` is only
   78–214 ms, so this is our own rate-limiter queue, not the host clock. The `resigner`
   hook fires only on Req *retries*, never on the initial throttled attempt.
2. **Authored `recv_window` is ignored.** `priv/venues/bybit/authored/venue.json` declares
   `"recv_window": 10000`, but `HmacRecipe` reads the global
   `Bourse.Defaults.recv_window_ms()` (5000) — the error message confirms
   `recv_window[5000]` on the wire.

**Expected:** the timestamp is stamped *after* the rate-limiter releases the request (or the
initial attempt re-signs post-throttle), and the venue's authored `recv_window` reaches the
signed payload.

**Impact:** latency-sensitive false reds on any HMAC venue under queue pressure — a 78-case
lane run showed 3 nonce failures, a 14-case focused run showed 0. Retry (`:invalid_nonce` is
retryable since task 604) usually heals it, which is why it flakes instead of failing hard.

## 2026-08-24 — bybit `fetchBalance` coins-balance branch parses to an empty `%Bourse.Balance{}` — the envelope is pinned to the wallet-balance shape

**Status:** Landed via task 686, `c6ebd79fcd96`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**The call:** `Bourse.fetch_balance(ex, type: "funding", params: %{"coin" => "BTC,USDT"})`
(bybit, testnet) → routed to `GET /v5/asset/transfer/query-account-coins-balance`.

**Observed:** `retCode 0` with populated rows, but the parsed `%Bourse.Balance{}` carries
`free/used/total/debt == %{}`. The authored `balance` response envelope is pinned to
`result.list` (the `/v5/account/wallet-balance` shape with nested `coin[]`), while this
endpoint answers `result.balance[]` flat — so extraction finds nothing. The contract case
still passes because its `any_fields` check treats `%{}` as non-nil, which is vacuous — and
equally vacuous for the already-green branches 0 (`account/info`) and 3 (`user/query-api`),
which are classification helpers, not balance carriers.

**Expected:** a second authored balance envelope/map for the coins-balance shape
(`result.balance[]`, flat `walletBalance`/`transferBalance` fields), and a contract assertion
that distinguishes "parsed a balance" from "parsed nothing".

**Impact:** consumers reading funding-account balances through bybit get an empty struct with
`{:ok, …}` — silently wrong, the worst kind.

## 2026-08-24 — bybit: two contract cases are unreachable with an AI-subaccount testnet credential

**Status:** ✅ resolved (same day) — (1) fixed as a client bug: `balance_request/2` in
`Bourse.Unified.RequestShape.Bybit` now passes the `coin` filter (mandatory for
`accountType=UNIFIED` per https://bybit-exchange.github.io/docs/v5/asset/balance/all-balance),
and the contract case supplies `code: "BTC,USDT"` — live `retCode 0` with rows for both coins.
(2) confirmed permanent and ledgered in `docs/prod-verification-ledger.md` — under the
re-provisioned trade-capable key the answer is *"Not Support Sub Account"*: bybit serves
deposit addresses only to the master account, so the blocker is the credential class (the
earlier 10024 regulatory text was the transient provisioning wall in front of the same
endpoint). The account-state reds below also closed the same day: the order-identity cases
were re-pinned `category=linear` and fed by a real filled round-trip, and a tiny executed
convert turned `fetchConvertTrade:0` green. Later the same day the operator minted a testnet
**main-account** key; with the lane pointed at it both deposit-address cases are green too
(the sub-account boundary was the whole blocker), and the lane runs **77/78** — the last red
is the delivery record, seeded with a dated future that delivers on 2026-08-28.

**The call:** `mix ccxt.verify_rest_read_contracts --venue bybit` (78 cases, 64 green) with
`BYBIT_TESTNET_API_KEY/_SECRET` pointing at a Bybit **AI sub-account** credential
(`sub_member_id 107065959`), issued through the OAuth `ai-agent` flow against
`api2-testnet.bybit.com` because the testnet web UI's own "create API key" dialog has been
erroring for weeks.

**Observed — two distinct defects:**

1. `bybit:fetchBalance:2:privateGetV5AssetTransferQueryAccountCoinsBalance` fails with
   `[bybit] bad_request: request parameter err: Limit the query to 1 to 10 coins for account
   UNIFIED`. The case calls `GET /v5/asset/transfer/query-account-coins-balance` with
   `accountType=UNIFIED` and no `coin` filter; Bybit rejects that combination outright. The
   same call with `accountType=FUND` and no filter returns `retCode 0`, so the branch is
   only wrong for UNIFIED. Reproduced directly:
   `Bourse.Bybit.private_get_v5_asset_transfer_query_account_coins_balance(ex, %{"accountType" => "UNIFIED"})`.

2. `bybit:fetchDepositAddress:0` and `bybit:fetchDepositAddressesByNetwork:0` fail with
   `[bybit] permission_denied: Dear User, The product or service you are trying to access ...`
   on `GET /v5/asset/deposit/query-address`. This is not a transient state problem: the AI
   sub-account authorization scope excludes deposits and withdrawals by construction, so no
   credential of this class can ever make those two branches green.

**Expected:** (1) the UNIFIED branch supplies a `coin` list (1–10 coins) or uses
`/v5/account/wallet-balance` for the unfiltered case. (2) the two deposit-address branches are
ledgered in `docs/prod-verification-ledger.md` as unreachable under an AI-subaccount credential,
naming the credential class — not silently dropped from the denominator.

**Impact:** the venue's lane cannot reach 78/78 with this credential class, and the reason
differs per case — (1) is a spec defect the venue would reject for any caller, (2) is a
permanent scope boundary. Conflating them hides the first behind the second.

**Note on the remaining reds (not defects):** the other 12 failures on that run are live
account-state preconditions on a freshly created sub-account — five `fetchClosedOrders`-derived
cases, three convert-history cases, `fetchMySettlementHistory`, `fetchPositionADLRank`. They are
the class already filed on 2026-08-23 ("fourteen cases across five venues are green only while
live account state exists"), reproduced here on a new account.

## 2026-08-23 — contract lane: fourteen cases across five venues are green only while live account state exists

**Status:** Landed via task 687, `abd78b3886f8`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage. Ledgered unavailable cases remain unverified; this is not a claim that all account state is available.

**The call:** `mix ccxt.verify_rest_read_contracts` (binance family, hyperliquid, okx, deribit).

**Observed:** `binance:fetchOpenOrder:7`, `binance:fetchOrderList:0`, `binanceusdm:fetchOpenOrder:1`,
`binanceusdm:fetchOpenOrder:2`, `binanceusdm:fetchPositionADLRank:1`, `binancecoinm:fetchOpenOrder:0`,
`binancecoinm:fetchOpenOrder:1` — plus hyperliquid `fetchOpenOrders:0`, `fetchPosition:0`,
`fetchPositions:0`, okx `fetchPosition:0`, and deribit `fetchOrder:0` / `fetchOrderTrades:0` —
resolve their arguments from live account state (open orders / positions / recent closed
orders). Deribit is the sharpest instance: a filled round-trip made both cases green, and
~2.5 h later `fetchClosedOrders` returned zero rows even with `include_old: true` — the venue
windows filled orders out of its history, so that state cannot even be made durable by hand.
All fourteen passed on 2026-08-23 with hand-created testnet state (resting far-from-market
limit orders, minimum positions, filled round-trips) and go red again once that state is
cleaned up or ages out — cleanup policy requires removing it.

**Expected:** a case that needs account state should own it — the scenario executor
(`Bourse.Test.RestReadContractScenario`) creating the resting order / minimum position before the
branch runs and tearing it down afterwards. Until then these cases are state-flappy, not stable.

**Impact:** anyone running the lane against a flat account reads ten reds that are neither code
nor spec defects; the lane's honest-red discipline loses signal.

## 2026-08-23 — okx: `endpoint_index`-selected algo reads can only ever see `ordType: "conditional"` orders

**Status:** Landed via task 686, `c6ebd79fcd96`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**The call:** `Bourse.fetch_open_orders(ex, endpoint_index: 0)` / `fetch_closed_orders(ex, endpoint_index: 0)` (okx algo branches).

**Observed:** `Bourse.Unified.RequestShape.Okx.order_read_ord_type/1` defaults to `"conditional"`
when no `trigger`/`trailing` selector is present, and an `endpoint_index`-selected algo route
carries no selector. A live `trigger` algo order is invisible to the unified call — the raw
pending list shows it under `ordType=trigger` while `fetch_open_orders(..., endpoint_index: 0)`
returns `[]` (probed on the international demo host).

**Expected:** the algo read surface should either fan out across the venue's algo `ordType`
values or accept a caller-supplied selector on the algo route.

**Impact:** trigger and trailing algo orders silently disappear from the unified read surface;
both contract cases stay green because they allow an empty collection.

## 2026-08-23 — binanceusdm: the `fetchOpenOrder`/`fetchOrder` algo branch can never reach `GET /fapi/v1/algoOrder`

**Status:** Landed via task 686, `c6ebd79fcd96`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**The call:** `Bourse.fetch_open_order(ex, id, endpoint_index: 1)` (binanceusdm).

**Observed:** two live facts. (a) The authored request mapping sends `orderId ← id`, but the
endpoint accepts only `algoId`/`clientAlgoId` — a raw call with `orderId` answers
`-1102 "Param 'algoid' or 'clientalgoid' must be sent"` (provider doc: Query Algo Order,
developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Query-Algo-Order).
(b) `endpoint_selection.book_routes` runs `first_success` over
`[fapiPrivate_get_openorder, fapiPrivate_get_algoorder]`, so `endpoint_index: 1` still returns the
non-algo endpoint's row — byte-identical to `endpoint_index: 0` (verified live). The contract case
`binanceusdm:fetchOpenOrder:1:fapiPrivateGetAlgoOrder` is therefore satisfied by the wrong
endpoint.

**Expected:** the algo route needs a per-endpoint request override (`id → algoId`) and pinned
routing so `endpoint_index` actually selects it; its contract branch needs argument sourcing from
open *algo* orders.

**Impact:** algo/conditional orders are unreadable through the unified surface; the contract
branch's green is vacuous.

## 2026-08-23 — binancecoinm `fetch_adl_rank`: provider list collapsed into a single struct — second position silently dropped

**Status:** Landed via task 686, `c6ebd79fcd96`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**The call:** `Bourse.fetch_adl_rank(ex)` (binancecoinm).

**Observed:** `GET /dapi/v1/adlQuantile` returns an array, one entry per position-carrying symbol
(live with one position: `[%{"symbol" => "BTCUSD_PERP", "adlQuantile" => %{"BOTH" => 1, …}}]`),
but the unified call returns a bare `%Bourse.ADLRank{}`. Root cause: the global `fetchADLRank`
descriptor is `Promise<ADLRank>` while `binancecoinm/authored/endpoints.json` wires the
list-returning `dapiPrivateGetAdlQuantile` to the singular `parseADLRank`; the sibling
`binanceusdm:fetchPositionsADLRank` wires the same payload shape to `parseADLRanks` correctly.

**Expected:** with two or more COIN-M positions every entry after the first must survive parsing —
either the venue routes this through the plural method or the carve is corrected.

**Impact:** silent data loss for any account holding more than one COIN-M position; the contract
case has always passed vacuously because a flat account answers `[]`.

## 2026-08-23 — bybit: account-classification helper endpoints remain in `fetchBalance` reads and every write method's `unified` array

**Status:** Landed via task 686, `c6ebd79fcd96`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**The call:** `Bourse.fetch_balance(ex, endpoint_index: 0)` / `endpoint_index: 4` (bybit), and the
`unified` arrays of `createOrder`, `createOrders`, `createMarketBuyOrderWithCost`,
`createMarketSellOrderWithCost`, `cancelAllOrders`, `cancelOrders`, `cancelOrdersForSymbols`,
`setMarginMode`, `withdraw`.

**Observed:** those indices dispatch to `/v5/account/info` or `/v5/user/query-api` — account-
classification helpers carrying no balance rows and no order/write capability. The two
`fetchBalance` contract cases pass only because their success meanings are weak enough to be
satisfied by the helper payload; a consumer iterating `endpoint_index` gets classification
metadata labelled as a balance read. The write-method entries shift the meaning of
`endpoint_index` for every write consumer.

**Expected:** helper endpoints live outside the data-read/write branch lists (the client already
has a first-class home: `Unified.call_account_facts_endpoint/5` uses `private_get_v5_account_info`
for `fetch_account_facts`).

**Impact:** wrong-but-green balance reads on two indices; index drift risk for writes. Write-side
cleanup belongs with the writes task (668); the fetchBalance carve needs a decision on the two
currently-green cases.

## 2026-08-23 — deribit `fetch_account_facts`: the account-level margin figures are parsed and then dropped — only the two classification flags survive

**Status:** Landed via task 686, `c6ebd79fcd96`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

**Reporter:** `bourse_trading` (task 4, `Bourse.PortfolioRisk` account-level snapshot layer).

`Bourse.fetch_account_facts/1` returns three facts — `product_access`,
`account_margin_model`, `position_margin_modes` — plus the raw `info`. Deribit's
`/private/get_account_summaries` response carries **twelve** margin fields per currency row;
exactly two of them (`portfolio_margining_enabled`, `margin_model`) reach a normalized fact.
The margin **figures** are read, discarded, and are recoverable only from `info`.

Observed live, this session (deribit testnet, PM-enabled account):

```elixir
{:ok, ex} = Bourse.Exchange.new("deribit", credentials: creds, sandbox: true)
{:ok, facts} = Bourse.fetch_account_facts(ex)

Map.keys(facts)
#=> [:info, :product_access, :account_margin_model, :position_margin_modes]

# the BTC summary row inside facts.info — every number below is already in hand:
%{
  "currency" => "BTC",
  "initial_margin" => 2.75310915,
  "maintenance_margin" => 2.20248732,
  "projected_initial_margin" => 2.75310915,
  "projected_maintenance_margin" => 2.20248732,
  "margin_balance" => 19.55537393,
  "equity" => 19.60656332,
  "available_funds" => 16.80226477,
  "portfolio_margining_enabled" => true,   # <- normalized
  "margin_model" => "cross_pm",            # <- normalized
  "cross_collateral_enabled" => true
}

# the full margin-bearing key set on that same row:
["projected_close_out_margin", "close_out_margin", "portfolio_margining_enabled",
 "margin_balance", "projected_initial_margin", "total_maintenance_margin_usd",
 "projected_maintenance_margin", "maintenance_margin", "initial_margin",
 "total_initial_margin_usd", "margin_model", "total_margin_balance_usd"]
```

**Expected:** the account-level margin figures readable as normalized facts alongside the two
classification flags, with the same explicit-unavailability vocabulary the existing facts use
(`%{status: :observed | :unavailable, provider_fields: [...], value: ...}`), so a venue that
does not publish a field is distinguishable from one reporting zero.

**No other normalized surface carries them.** Checked live on the same exchange:

```elixir
Bourse.fetch_margin_balance(ex)  #=> {:error, %Bourse.Error{type: :not_supported, ...}}
Bourse.fetch_account(ex)         #=> {:error, %Bourse.Error{type: :not_supported, ...}}
Bourse.fetch_balance(ex)         #=> %Bourse.Balance{free:, used:, total:, debt:} — no margin fields
```

`%Bourse.Account{}` is `[:id, :type, :code, :info]`; `%Bourse.Balance{}` is
`free/used/total/debt/timestamp/datetime/info`. `%Bourse.Position{}` does carry
`initial_margin` / `maintenance_margin`, but those are the **per-position** rows — the
account-level figure is not their sum under portfolio margining, which is the whole point of
asking for it.

**Where it stops.** `Bourse.Unified.ReadParse.map_account_facts/2`'s deribit clause builds
exactly three facts through the private `facts/4` constructor
(`product_access`, `account_margin_model`, `position_margin_modes`, `info`). There is no slot
in that shape for a numeric account fact, so the deribit clause has nowhere to put
`initial_margin` even though it is holding the row it came from. The shape, not the deribit
mapping, is the constraint.

**Consumer impact.** `bourse_trading`'s `Bourse.PortfolioRisk.Snapshot` carries per-position
rows only, so a consumer cannot render account margin health — utilisation against
maintenance, headroom to a projected initial-margin call — from the normalized domain. The
two workarounds both break something we deliberately built:

1. Reach into `facts.info["result"]["summaries"]` from the domain layer. That re-introduces
   raw-payload parsing in the consumer, which is exactly what the packaged-surface split
   was meant to end — the domain repo depends on `{:bourse, "~> 0.7.0"}` from Hex precisely
   to prove the packaged surface suffices.
2. Sum the per-position `initial_margin` / `maintenance_margin` rows into an account total.
   Under `margin_model: "cross_pm"` that number is **wrong by construction** — portfolio
   margining nets the legs, so the sum overstates the requirement, and a hedged book is where
   it overstates it worst. A risk surface that reports a fabricated margin requirement is
   worse than one that reports nothing, so we are not doing it.

The consumer-side task (`bourse_trading` task 4) is filed `blocked` on this and stays blocked;
it will not work around the boundary. Note for triage: workbench task **602** covered this
surface and was superseded on 2026-08-19 (admission-rule sweep; also stale, since
`Bourse.PortfolioRisk` had moved to `bourse_trading`). Its account-margin half was noted onto
task **648**, but 648 shipped the classification facts only — the figures were never picked up
by a successor. This entry is that report.

**Doc authority:** https://docs.deribit.com/#private-get_account_summaries — `initial_margin`,
`maintenance_margin`, `projected_initial_margin`, `projected_maintenance_margin` and
`margin_balance` are documented per-currency account fields, distinct from the per-position
margin rows on `/private/get_positions`.

---

## 2026-08-23 — reference-corpus `static_fixtures` pin unreadable, silently emptied every integration probe's symbol index

**Status:** ✅ fixed in-session (pin removed, rescue made loud) · **Venue:** none — repo-internal
test infrastructure defect, not a venue gap · **Class:** false-green test scaffolding.

**Reporter:** self-found, not consumer-reported (repo-internal integration-test-support defect
uncovered while auditing the reference-slice manifest; filed for the durable record per this
repo's `CLAUDE.md` security/data-loss-and-self-found-infra-defect exception).

`priv/specs/json/reference_corpus.json` carried a second manifest pin, `pins.static_fixtures`,
pointing at `ccxt/ts/src/test/static/VINTAGES.md` under `priv/specs/json/ccxt/`. That whole tree
is gitignored (`.gitignore` `/priv/specs/json/ccxt/`) and, aside from the one force-tracked
`ccxt/js/VERSION` file (the `source` pin's target, confirmed present and SHA-256-matching), is
absent from every checkout. `Bourse.ReferenceSlice.load_manifest!/0` validated **both** pins
(`test/support/reference_slice.ex:95`, `Enum.each(["source", "static_fixtures"], &validate_pin!/2)`),
so `load_manifest!/0` — and therefore `spec_path/1` — raised `could not read file
.../VINTAGES.md` on every single invocation, in every checkout, unconditionally.

That raise never surfaced: `test/support/test_generator/symbol_resolver.ex:97-102` wrapped the
whole decode pipeline in a bare `rescue _ -> %{}` (with a `reach:disable-next-line bare_rescue`
suppressing the lint that would have flagged it), so `SymbolResolver.markets/1` silently
degraded to an empty map on the raise instead of propagating it. Every caller of
`pick_symbol/1` / `pick_funding_symbol/1` — i.e. every unified-integration probe that needs a
live test symbol — saw `map_size(markets) == 0` and returned `nil`, which every call site reads
as "this exchange has no markets, skip emission." The suite reported green throughout: skipped
emission looks identical to legitimate emptiness, so no test failed and no gap was visible in
any run's summary.

**Repro (pre-fix):**

```elixir
Bourse.ReferenceSlice.spec_path("binance")
# raised: could not read file .../priv/specs/json/ccxt/ts/src/test/static/VINTAGES.md

Bourse.Test.Generator.SymbolResolver.markets("binance")
# => %{}   (map_size 0 — should have been 4431 live binance markets)
```

> **Update 2026-08-23 — fixed in-session.** Removed the `static_fixtures` pin object from
> `reference_corpus.json` and dropped it from `ReferenceSlice.validate_pins!/1`'s validation
> list (the `source` pin, whose target `ccxt/js/VERSION` is genuinely tracked and
> hash-verified, is untouched and still enforced). Removed the bare `rescue _ -> %{}` from
> `SymbolResolver.markets/1` entirely — a decode failure now raises instead of degrading, and
> the `_ -> %{}` case fallback for a missing `markets.symbols_index` key was changed to an
> explicit raise naming the exchange id and spec path, since an empty symbol index was never a
> valid answer for a spec that decoded successfully. Verified live:
> `SymbolResolver.markets("binance")` now returns a map of size 4431 (was 0). `mix compile
> --warnings-as-errors` clean; no test file directly exercises `ReferenceSlice` or
> `SymbolResolver` (only an unrelated allowlist-pattern reference in
> `ccxt_authority_language_test.exs`), so there is no test-suite delta beyond this fix.

---

## 2026-08-22 — deribit option positions: `notional` / `notional_currency` left nil although every input is present

**Status:** ✅ fixed on `main` after 0.7.0 by task **664** (`74ca5d2`) · **Venue:** deribit (testnet, `sandbox: true`) ·
**Class:** unfilled unified field — not a venue gap.

**Reporter:** `trading_dashboard` (task 225 payload observation, live Deribit testnet).

> **Triage 2026-08-22 (workbench orchestrator) → task 664.** Both "where it stops" claims
> confirmed against the current tree, and one correction worth recording: the nil is **authored,
> not accidental**. `priv/specs/json/output/authored/deribit.json` →
> `normalization.field_maps.position.field_map.notional` is a `when` rule guarded on
> `kind in ["future"]` reading `size`, with an explicit `else: null`; the sibling `contracts`
> rule is its mirror image (null for futures, `size` otherwise). That guard is right as far as it
> goes — an option's `size` is a contract count, not a value — so the gap is a **missing
> derivation**, not a broken mapping. `DeribitPositionUnits.reconcile_position/2` (future-only
> head) and the `%Position{notional: nil}` short-circuit in `put_notional_currency/2` are both
> exactly as described.
>
> Task 664 is scoped to the unit question rather than the multiplication: deribit quotes option
> `mark_price` in the base currency per contract, so the product is base-denominated and lands in
> a different `notional_currency` than the future row — which is why shipping the number without
> the unit is not an acceptable fix. The `0.1 × 1.0 × 0.00701189` reading is carried into the task
> as evidence, not as a specification to implement unexamined; the venue's own position
> documentation is the authority.
>
> One caveat folded into the acceptance criteria: the repro ran without `load_markets`, which is
> also why the *future* row shows `contracts: nil` — `market_units/1` had nothing to build from.
> A derivation that needs `contract_size` must leave `notional` nil when markets are absent
> rather than substituting 1.0. The delta-weighting caveat is honored as written: it is recorded
> in the task's `out_of_scope`, so a populated option notional will not be mistaken for one that
> is summable with a future's.
>
> **Update 2026-08-22 — fixed on `main` after 0.7.0.** Task 664 landed in
> `74ca5d2`. Deribit option rows now derive settlement-currency premium notional
> from `abs(contracts) × contract_size × abs(mark_price)` when loaded markets
> provide a positive contract size, and populate `notional_currency` from the
> parsed settlement code. The live integration pin covers simultaneous option
> and future positions and confirms that an exchange without loaded markets
> still leaves the option notional nil rather than guessing a unit.

A Deribit **option** position comes back with `notional: nil` and therefore also
`notional_currency: nil`, while the sibling **future** row on the same account is fully
populated. Observed live, one credential holding both legs at once:

```elixir
{:ok, positions} = Bourse.fetch_positions(ex)   # exchange built WITHOUT load_markets

# future
%{symbol: "BTC/USD:BTC", contracts: nil, notional: 10.0,
  info: %{"kind" => "future", "size" => 10.0, "size_currency" => 1.2996e-4}}

# option
%{symbol: "BTC/USD:BTC-260823-77000-C", contracts: 0.1, notional: nil,
  info: %{"kind" => "option", "size" => 0.1, "mark_price" => 0.00701189,
          "index_price" => 76948.23, "average_price_usd" => 538.41074,
          "delta" => 0.04945, "vega" => 1.54039, "theta" => -27.91852}}
```

**Expected:** `notional` populated for the option too, with `notional_currency` naming its
unit. Every input is already in hand — `contracts` (0.1) is on the unified struct,
`contract_size` (1.0 BTC) is on the option market, and `mark_price` (0.00701189 BTC per
contract) is in the raw payload:

```
0.1 contracts × 1.0 BTC × 0.00701189 BTC/contract = 0.000701189 BTC
```

The raw payload additionally carries `average_price_usd` (538.41 per contract) and
`index_price`, so a USD-denominated figure is available too if that is the preferred
`notional_currency` for options.

**Where it stops.** `Bourse.Unified.DeribitPositionUnits.reconcile_position/2` matches only
`%{"kind" => "future"}`; options fall through the catch-all clause untouched. Then
`put_notional_currency/2` short-circuits on `%Position{notional: nil}` and returns the
position unchanged, so the unit never gets attached either. Both are consistent with
`Position`'s own moduledoc ("Populated whenever `notional` is populated") — the gap is that
`notional` is never populated for the option kind in the first place.

**Consumer impact.** `trading_dashboard` folds open positions into one long/short notional
pair that feeds hedge sizing. A nil notional is coerced to zero on our side, so an open
option currently contributes **zero** to the hedge book and its row prints `0` — a number
that reads as real. We are fixing the fold to stop treating a missing notional as zero, but
the missing figure itself belongs here: the consumer should not be recomputing a unified
field from `info` when the library already owns that mapping for futures.

**Caveat for the fix, so the two do not get conflated.** A correctly populated option
notional is still **not** additively summable with a future's notional for hedging purposes —
the option's directional exposure is delta-weighted (this row: `delta 0.04945`, i.e. ~5% of a
linear position of the same size). That is the consumer's problem, not bourse's; it is noted
only so a fix here is not mistaken for making the two figures interchangeable. What bourse
owes is the populated value plus the honest `notional_currency`, not summability.

**Doc authority:** https://docs.deribit.com/api-reference/account-management/private-get_positions
— option `size` is the number of contracts in base currency, and `mark_price` for an option
is quoted in the base currency per contract.

---

## 2026-08-22 — `create_order` silently places a BUY when `side` is an ATOM (`:sell`), and drops `params`

**Status:** ✅ fixed on `main` after 0.7.0 by task **663** (`5cde00f`) · **Venue:** deribit
(testnet, `sandbox: true`) · **Severity:** money path — a sell becomes a buy with no error.

> **Fixed 2026-08-22 (task 663, `907f62c` + `5cde00f`).** An uninterpretable `side` is now a hard
> `{:error, %Bourse.Error{type: :invalid_parameters}}` at `Bourse.Unified.validate_param_values/2`
> for every unified method whose required params include `:side` — before any HTTP request,
> independent of `sanity:` and of loaded markets. Atoms are rejected, not coerced, and
> `RequestShape.Lighter.side_is_ask!/1` no longer disagrees. deribit's `createOrder`
> `endpoint_selection` lost its `default: "buy"`; every authored venue was audited and it was the
> only direction-bearing selection. The dropped-`params` half was a separate authoring defect:
> `reduce_only` is deribit's native snake_case field and the authored source listed only
> `reduceOnly`, so the nil lookup deleted the caller's key — `fallback_sources: ["reduce_only"]`
> restores it. Live testnet confirmation on BTC-PERPETUAL: the atom call was refused with no order
> placed; the string buy (`115028667016`) and the `reduce_only: true` sell (`115028668271`)
> both went through in the right direction, positions empty afterwards.
> **Still open, filed separately (closed by task 665):** the batch write paths (`create_orders`
> and siblings) took `:orders` and never entered that clause, so a nested atom side was not
> refused. Task 665 walks every nested `"side"` / `:side` at the unified boundary and refuses
> RequestShape catch-alls that mapped an unmatched value to a direction.

**Reporter:** `trading_dashboard` (task 225 payload observation, live Deribit testnet).

> **Triage 2026-08-22 (workbench orchestrator) → task 663.** Confirmed statically against the
> current tree; filed as the defect class rather than the deribit instance. Root cause read from
> the code: `priv/specs/json/output/authored/deribit.json` →
> `endpoints.request.endpoint_selection.createOrder` is
> `{"cases": [{"path": "sell", "when": {"side": "sell"}}], "default": "buy"}`, and the same
> method's request defaults carry `"_omit": ["side"]` — on deribit the direction *is* the
> endpoint, so an atom `:sell` fails the string match, falls to `default`, and becomes a buy with
> no side param on the wire. `Bourse.Order.Sanity.check_side/1` already rejects anything outside
> `buy`/`sell`, but sanity is opt-in (`sanity: true`, default `false` — task 411's deliberate
> decision) and is skipped without loaded markets, so the one guard that would have caught this
> is off by default on the money path. The venues also disagree with each other today:
> `RequestShape.Lighter.side_is_ask!/1` accepts `:sell`, `RequestShape.Bybit` defaults a missing
> side to `"buy"`, and `RequestShape.OKX` derives `posSide` from `params["side"] == "sell"` (an
> unmatched side silently becomes `long`). Task 663 makes side interpretability an unconditional
> boundary check independent of `sanity:`, and removes every direction-bearing silent `default`
> from the authored selection layer.
>
> On the second defect: `reduce_only` is sourced from the venue-native `reduceOnly`
> (`native_passthrough`) in the deribit authored request, so the snake_case key in the repro may
> never have been a recognized param rather than having been dropped by the atom-side path. Left
> unadjudicated on purpose — task 663 carries a live confrontation of it as an acceptance
> criterion, because either verdict is the same class: caller intent discarded without a word.

`Bourse.create_order/5,6` accepts `side` as an atom without complaint and places the order as a
**buy** regardless. Only the string form is honored. Observed on three consecutive calls; each
one *increased* an existing long instead of reducing it.

```elixir
{:ok, ex} = Bourse.Exchange.new(:deribit, credentials: creds, sandbox: true)

# 1) atom side + params  -> venue echoes direction "buy", reduce_only false
{:ok, o} = Bourse.create_order(ex, "BTC-PERPETUAL", :market, :sell, 10,
                               params: %{"reduce_only" => true})
o.side                  #=> "buy"      EXPECTED "sell"
o.info["direction"]     #=> "buy"      EXPECTED "sell"
o.info["reduce_only"]   #=> false      EXPECTED true

# 2) atom side, arity 5, no params -> still a buy
{:ok, o} = Bourse.create_order(ex, "BTC-PERPETUAL", :market, :sell, 10)
o.info["direction"]     #=> "buy"      EXPECTED "sell"

# 3) string side -> correct
{:ok, o} = Bourse.create_order(ex, "BTC-PERPETUAL", "market", "sell", 10)
o.info["direction"]     #=> "sell"     correct
```

Observed vs. expected, two defects in one call:

1. **Unrecognized `side` falls back to buy instead of erroring.** An atom is the idiomatic
   Elixir spelling and the same atom is accepted for `type` (`:market` worked in call 3's
   string form and in the atom form alike), so the asymmetry is invisible at the call site.
   A side the library cannot interpret must be `{:error, …}` — never a default direction.
   The buy default is the worst possible fallback: on a long it doubles exposure, and on a
   flat account it opens a position the caller never asked for.
2. **`params:` was dropped** on the atom-side path — the venue echoed `reduce_only: false`
   for a call that passed `%{"reduce_only" => true}`. Not separately isolated on the string
   path; may be the same root cause (opts arm not reached) or a second gap.

**Consumer impact.** `trading_dashboard`'s own write path is not exposed: it is the single
call site `Exchange.OrderPlacement.venue_place/3`, and `placement_request/1` stringifies with
`Atom.to_string(order.side)`. The exposure is any ad-hoc/operator/REPL call and any new
consumer following Elixir convention. Cost here: three unintended testnet buys
(BTC-PERPETUAL 10 USD each), flattened afterwards.

**Suggested fix:** normalize `side` (and `type`) through one strict resolver that accepts
`:buy | :sell | "buy" | "sell"` and returns `{:error, {:invalid_side, given}}` for anything
else. No silent default.

**Doc authority:** https://docs.deribit.com/api-reference/trading/private-sell — a sell is
its own endpoint, so the direction is chosen inside the library, not by the venue.

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

**Status (2026-08-18):** ✅ **fixed** by task 580 (`429a8e9`) — a thin `{algoId, code: 200}` cancel ack now synthesizes `_bourse_status: "CANCELED"`, which the authored map emits as unified `status: "canceled"`. `fetch_order` / `fetch_orders` (and the open/closed/canceled variants) fan out to the algo book so the same identifier is readable after the write.

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

**Status (2026-08-18):** ✅ **fixed** by task 580 (`429a8e9`) — `STOP` maps to `"stop"` and `STOP_MARKET` to `"stop_market"` instead of collapsing both to `"limit"`.

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

**Status (2026-08-18):** ✅ fixed by task 562 (`1614d01`, reviewer fix
`1530ff8`). Field rules can now read the original response envelope, so Bybit
`fetch_ticker` binds `body.time` into `timestamp` / `datetime`; the same
vocabulary is confronted against Hyperliquid balance clocks. Registered replay
evidence fails if an envelope-sourced value is present but missing from the
parsed result. The original live repro remains below.

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

**Status (2026-06-23):** ✅ **fixed.** The classifier defect this entry filed was closed by the response-classifier task (HTTP/JSON-RPC success no longer misread as `:exchange_error` — lighter `code: 200`, deribit result-without-error), and task 195 added the `order_book_details` envelope unwrap for lighter's `fetch_markets` (206 markets). Lighter has since been promoted to a **complete authored public/private venue** (task 451, `7a7b9d58`), with `fetch_ticker` authored by task 197. Lighter's `fetchMarkets` and `fetchTicker` are covered by the provider-live REST-read contract lane. **Severity when open:** high (blocked lighter onboarding entirely).

> **Correction (2026-07-25).** An earlier pass of this reconciliation marked this entry "OPEN — not re-tested", carrying forward the 2026-07-15 sweep banner's "lighter is WIP upstream" note. That note was itself stale: lighter was promoted after the sweep. A live call — not the sweep banner — is the authority for current per-venue state.

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
`f5ad332`, harness run `run-1787019715121-97bb4904`). Default `watch_order_book/3` now builds the
provider partial-depth stream `{symbol}@depth20@100ms` (`btcusdt@depth20@100ms`
for `BTC/USDT`) on binance and binanceusdm. The four `watch_*` defaults were
audited against the venue stream docs; leftover hashes
(`orderbook::{symbol}`, `trade::{symbol}`, `myLiquidations::{symbol}`,
`:{symbol}`, bare `miniTicker`/`kline`/`name`) are gone. Live
frame-delivery tests in `test/live/ws/binance_watch_frame_delivery_test.exs`
pin a book frame on both venues — subscribe-ack is not treated as evidence.
The trading_dashboard `depth20@100ms` workaround can now be retired.
binancecoinm still authors no channel table and fails loud with
`:no_channel_templates`.

**Residual fixed (2026-08-18, task 628):** Frame arrival was not Broadcast routing.
Spot `@depth20@100ms` payloads have no `e` field, so Envelope classified them
as raw and Adapter never broadcast `{:routed, :watch_order_book, ...}`. The
authored shape channel maps `lastUpdateId`/`bids`/`asks` onto the existing
`depthUpdate` dispatch entry. Subscribe-ack and unmatched frames stay
system/raw.

**Original triage (2026-08-14):** bestätigter Spec-Authoring-Defekt, Klasse statt Einzelfall.
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

**Status (2026-08-18):** ✅ **fixed** by task 622 (`2fde2c8`) — Deribit request-shapes unified `clientOrderId` onto `label` and the order/trade field maps echo it back as `client_order_id`. The catalog invariant in `test/bourse/client_order_id_round_trip_invariant_test.exs` fails a one-way mapping.

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

**Status (2026-08-18):** ✅ fixed — task 623 shipped `markets.contract_unit` on binanceusdm (`linear` constant `1`, `quantity_unit: "base"`). Task 625 authored the remaining first-class linear recipes on `binance` (umbrella FAPI family only), `bybit`, and `derive`. Recorded `fetch_markets` replays and live probes pin `BTC/USDT:USDT` (binance FAPI / bybit) and `BTC/USD:USDC` (derive) at `contract_size: 1`. Inverse COIN-M and bybit inverse stay on the provider field or nil. A market whose venue states no unit stays nil; a declared recipe with a missing or non-positive value fails loud. C-T623a / C-T625a / C-T625b / C-T625c record the provider sources.

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

## 2026-08-18 — Account-Klasse und Margin-Modi fehlen als provider-treue Unified Facts

**Status (2026-08-19):** ✅ fixed by task 648 (`f291108`).
`Bourse.fetch_account_facts/1` returns independent `product_access`,
`account_margin_model`, and `position_margin_modes` facts for alpaca,
binance, bybit, deribit, hyperliquid, and lighter. Missing provider
fields stay `:unavailable`; caller selectors are never returned as
facts. The six venue carve register entries are C-T648a–f.

**Residual:** `has?("fetchAccountFacts")` stays false — the method is
special-cased in `Unified.call/5` and is not an authored
`capabilities.has` / unified route, so the derived callable surface
does not advertise it. Dedicated `binanceusdm` / `binancecoinm` /
`okx` / `derive` clients still return `:not_supported`.

**Methods:** private Account-Reads (`/v5/account/info`,
`private/get_account_summaries`, `/v2/account`, Binance Account/Positions sowie
Hyperliquid/Lighter Account-State) · **Exchanges:** alpaca, binance, bybit,
deribit, hyperliquid, lighter · **Severity:** hoch (ein Consumer kann sonst
Derivate anhand eines konfigurierten Spot-Labels behandeln)

Bourse 0.6.0 stellt die raw Endpoint-Funktionen bereit, aber kein gemeinsames
Account-Fact-Resultat, das die provider-eigenen Klassifikationsfelder erhält.
`fetch_balance`/`fetch_positions` beweisen Erreichbarkeit und liefern teilweise
normalisierte Positionsmodi, verlieren aber die eigenständigen Account-Fakten:
Bybit `unifiedMarginStatus` + `marginMode`, Deribit
`portfolio_margining_enabled` + `margin_model`, Alpaca `multiplier` +
`shorting_enabled`, Binance `accountType`/`permissions` + positionsbezogenes
`isolated`, Hyperliquid `crossMarginSummary` + `leverage.type` und Lighter
`account_type`/`account_trading_mode` + positionsbezogenes `margin_mode`.

Expected: ein provider-treuer Unified Read trennt Product Access, Account-Margin-
Modell und positionsbezogenen Margin-Modus. Nicht gelieferte Felder bleiben
`unknown`/`unavailable`; Venue-Capabilities oder Caller-Optionen dürfen nicht als
Account-Beobachtung eingesetzt werden. Das Raw-Provider-Payload sollte in `info`
erhalten bleiben, damit Integrations-Tests die dokumentierten Feldnamen pinnen.

Konsument-Handling (trading_dashboard, Task 166): nutzt die vorhandenen raw
Endpoint-Funktionen an einer zentralen Account-Fact-Grenze und persistiert nur
explizit beobachtete Werte. Kann auf den Unified Read wechseln, sobald Bourse ihn
provider-treu shippt.

> **2026-08-19 — triagiert:** gefiled als Workbench-Task **648** ("Account class and
> margin model are not readable as unified facts"), gegen den allgemeinen Defekt
> geschnitten; die sechs genannten Venues stehen als Evidenz in den Acceptance
> Criteria, nicht als Scope-Grenze.

## 2026-08-19 — ZURÜCKGEZOGEN (kein bourse-Bug): binanceusdm `has.createStopMarketOrder` angeblich false — Fehlattribution des Reporters

**Status (2026-08-19):** ↩️ withdrawn — live re-verification found that bourse
returns `true` for binanceusdm; the consumer built a `binance` (Spot) exchange
for the USD-M credential. The original report remains below as the evidence
trail.

Call: `Bourse.Exchange.has?(exchange, "createStopMarketOrder")` auf einem
gebauten `binanceusdm`-Exchange (bourse 0.6.0, hex).

Observed: `false`. Nachbarn: `createStopOrder` true, `createStopLimitOrder`
true, `createTriggerOrder` true.

Expected: `true`. Binance USD-M dokumentiert `STOP_MARKET` (und
`TAKE_PROFIT_MARKET`) als Ordertypen (`POST /fapi/v1/order`, Parameter `type`).
Live-Beweis: trading_dashboard hat am 2026-08-12 unter bourse 0.4.0 über den
Capability-gateten App-Pfad einen STOP_MARKET (closePosition, MARK_PRICE,
Trigger 1620) auf dem Binance-USD-M-Demo-Env platziert — Venue-Order-ID
1000000165145628 lag am Venue. Nach dem Bump 0.4.0 → 0.6.0 (trading_dashboard
commit deaf97c, 2026-08-18) blockiert derselbe Pfad mit "Order capability
:stop_market is not available". Das Flag ist also zwischen 0.4.0 und 0.6.0 von
true auf false gekippt, ohne dass sich die Venue-Fähigkeit geändert hat.

Impact: jeder Capability-gatete Consumer verliert Stop-Market-Schutzorders auf
binanceusdm; im trading_dashboard hat das den BracketGuard-Rearm einer laufenden
Position blockiert (Position zeitweise ohne Stop am Venue).

Konsument-Handling (trading_dashboard): `OrderPlacement.@documented_capabilities`
trägt jetzt `"binanceusdm" => [:stop_market]` als dokumentierte
Venue-Capability-Ergänzung, mit Kommentar-Verweis auf diesen Eintrag. Rollback
sobald bourse das Flag wieder korrekt shippt.

> **2026-08-19 — triagiert:** gefiled als Workbench-Task **649**. Wichtig für die
> Reproduktion: das authored spec ist NICHT gekippt — `git show
> v0.6.0:priv/specs/json/output/authored/binanceusdm.json` liefert
> `capabilities.has.createStopMarketOrder = true`, und diese Datei liegt im
> Hex-Paket. `Exchange.build_capabilities/1` liest die Map wörtlich, `has?/2`
> ist ein reiner Lookup. Der beobachtete `false` entsteht also woanders; die
> Task 649 ist daraufhin auf den Klassen-Teil umgeschnitten worden (gepinnte
> Capability-Fläche im Offline-Gate); ein bourse-Regressionsfix ist NICHT
> gefiled, weil bourse das Flag in beiden Releases korrekt liefert.
>
> Nachgeprüft und widerlegt ist die Kipp-Behauptung selbst: `true` im getaggten
> v0.6.0-Tree, in HEAD, im Hex-Tarball 0.6.0 **und** 0.4.0, und im deps-Baum des
> Consumers; die binanceusdm-Capability-Map ist zwischen 0.4.0 und 0.6.0 mit 157
> Keys byte-identisch. Die Ursache liegt daher mit hoher Wahrscheinlichkeit im
> Consumer-Gate (Mapping `:stop_market` → String, gecachter Snapshot, oder eine
> eigene Kopie der Prüfung statt `has?/2`) — dort weitersuchen, nicht in bourse.

> **2026-08-19 — RETRACT (Reporter, trading_dashboard):** Die QA-Analyse oben
> stimmt; der Report war fehlattribuiert. Live-Verifikation auf bourse 0.6.0
> im laufenden trading_dashboard-BEAM: `Bourse.exchange(:binanceusdm)` →
> `has?("createStopMarketOrder") = true` (korrekt), `Bourse.exchange(:binance)`
> → `false` (korrekt — Spot hat kein STOP_MARKET). Der blockierte Pfad lief
> über den `ConnectionWorker` von trading_dashboard, der die Exchange aus
> `credential.exchange` (`:binance`) baut — ein USD-M-Credential wird dort
> gegen die **Spot**-Spec gegated. Der Defekt ist app-seitig
> (exchange-id-statisches statt produkt-bewusstes Capability-Gating), nicht in
> bourse. Offene historische Frage an bourse-QA: hatte die **Spot**-Spec
> (`binance`, nicht binanceusdm) in 0.4.0 `createStopMarketOrder = true`? Das
> würde erklären, warum derselbe App-Pfad am 2026-08-12 durchging — dann war
> 0.6.0 die Korrektur. Task 649 kann auf diese eine Diff-Frage reduziert oder
> geschlossen werden.

> **2026-08-19 — Bourse follow-up shipped:** Task 649 now packages the
> release-pinned capability surface, exposes it through
> `Bourse.Exchange.capability_surface/0`, and makes the offline oracle require
> an explicit re-pin for future capability changes. This does not reopen the
> withdrawn report: the observed block remains a consumer-side exchange-id
> selection error, and both inspected historical Bourse releases declared the
> USD-M capability correctly.

## 2026-08-19 — Deribit `parse_order_list/2` hat keinen Field-Map-Slot

Call: `Bourse.Deribit.parse_order_list([], symbol: instrument)` (bourse 0.6.0),
entsprechend dem `result: []` von Deribit
`private/get_open_orders_by_instrument` auf einem Instrument ohne offene Orders.

Observed: `{:error, :no_field_map}`. `Bourse.Deribit.__field_maps__()` besitzt
für `order_list` keinen ableitbaren Field Map; damit scheitert auch der
unzweideutige leere Provider-Response und ein Consumer kann keinen vollständigen
Reconciliation-Snapshot aufbauen.

Expected: der leere Response normalisiert zu `{:ok, []}`; für nichtleere Rows
soll Deribits provider-eigene Order-Vokabel in `Bourse.Order` normalisiert werden.

Konsument-Handling (trading_dashboard, Task 184): behandelt ausschließlich den
leeren Raw-Response lokal als leere Orderliste. Nichtleere Responses laufen
weiter durch `Bourse.Deribit.parse_order_list/2`, damit kein geratenes Mapping
die fehlende Bourse-Semantik verdeckt.

> *Triage note (2026-08-19, orchestrator):* in Workbench-Task **570** eingefaltet
> (Drei-Fakten-Trennung). Befund dort verifiziert: deribit führt einen Field Map
> für `order` und keinen für `order_list` und deklariert keinerlei
> fetchOrderList-Capability — die Venue hat keine OCO-Order-Group-Surface. Die
> ehrliche Antwort ist also der Unsupported-Operation-Fakt (Fakt 1 false), nicht
> `:no_field_map` (Fakt 2); genau diese Verwechslung beendet Task 570. Für offene
> Orders unterstützt deribit `parse_order/2`.
>
> **2026-08-19 — Bourse follow-up shipped:** Task 570 restored the three
> independent facts. `Bourse.Deribit.parse_order_list/2` now returns
> `{:error, {:unsupported_operation, "order_list"}}` instead of
> `:no_field_map`. The empty-list snapshot the reporter wanted remains a
> consumer-side interpretation of a provider-unsupported parse slot; open
> orders continue to go through `parse_order/2`.
>
> **2026-09-14 — consumer aligned (trading_dashboard).** The MM session's open-order
> reconciliation still routed non-empty `private/get_open_orders_by_instrument`
> rows through `parse_order_list/2`, so on the first kill switch with MMP enabled
> every cleanup re-polled `{:unsupported_operation, "order_list"}` once a second.
> Now parses per row via `parse_order/2` (commit `90124f2`). No bourse action.

---

## 2026-08-22 — `Bourse.load_markets/2` rejects `:type` and reports the unknown option as a recoverable network error, blowing the circuit breaker

**Status:** Landed via task 662, `fda5fa717262`; confirmed present on origin/main during triage 2026-09-15. No fresh live verification in this triage.

Reporter: trading_dashboard (`TradingDashboard.Risk`, `/risk` account rows), verified
live against Binance testnet on 2026-08-22.

**The call.** A Binance futures credential needs its account selected on private
reads (`type: "swap"` for USDT-M, `"future"` for COIN-M); without it `fetch_balance`
goes to the spot endpoint and answers `-2015 Invalid API-key, IP, or permissions`.
`Bourse.PortfolioRisk.scope/3` takes one `request_opts` keyword list and hands the
*same* list to `Bourse.load_markets/2`, `fetch_balance/2`, `fetch_positions/2` and
`fetch_open_orders/2`. The three private reads accept `:type`; `load_markets/2` does
not.

```elixir
{:ok, ex} = Connectivity.build_exchange(binance_usdm_credential, tenant, actor)

Bourse.fetch_balance(ex, type: "swap")      #=> {:ok, %Bourse.Balance{}}
Bourse.fetch_positions(ex, type: "swap")    #=> {:ok, [...]}
Bourse.fetch_open_orders(ex, type: "swap")  #=> {:ok, [...]}
Bourse.load_markets(ex, type: "swap")
#=> {:error, %Bourse.Error{
#     type: :network_error,
#     message: "Exception: unknown option :type",
#     recoverable: true,
#     retry_class: :network,
#     exchange: "binance"
#   }}
```

**Two defects, the second the damaging one.**

1. `load_markets/2` accepts only `:params` / `:plug` / `:timeout`, so a caller cannot
   thread one `request_opts` set through `PortfolioRisk`. Whether it should accept
   `:type` is a design call; that it silently diverges from every sibling read in the
   same opts set is at least a documentation gap.

2. **An unknown option is classified as `:network_error` / `recoverable: true` /
   `retry_class: :network`.** That is a caller programming error, not venue
   downtime — and the `:network` bucket melts `Bourse.CircuitBreaker`. Three Binance
   credentials in one snapshot produced enough melts to blow the venue's fuse, after
   which *every* Binance read in the whole application failed with
   `Binance circuit open: Circuit breaker is open. Not recoverable.` The originating
   fault was a bad keyword in our own call, and the reported cause pointed at Binance.
   Observed twice in a row; `Bourse.CircuitBreaker.status("binance")` went `:ok` →
   `:blown` across a single `PortfolioRisk.snapshot/1`.

**Expected.** An unrecognized option raises or returns a non-retryable client-error
`Bourse.Error` (`recoverable: false`, no `:network` retry class) so it never melts the
breaker. Ideally `load_markets/2` documents which opts it accepts, or tolerates the
account-selection opts its sibling reads require.

**Consumer handling (trading_dashboard).** `Risk.credential_scope/2` loads markets
itself with **no** opts before building the scope — `PortfolioRisk.ensure_markets/3`
short-circuits on an already-populated `:markets` list — so the account opts reach
only the private reads. Local workaround only; the misclassification is the fix path.

> **2026-08-22 — triagiert:** gefiled als Workbench-Task **662** ("An unrecognized
> caller option is reported as a recoverable venue network fault and melts the
> circuit breaker"), scoped to defect 2 as the general class rather than to the
> `:type`-on-`load_markets` instance. Mechanism confirmed on the landed tree:
> `Bourse.HTTP.request/4` builds `extra_opts` with a **deny-list**
> (`Keyword.drop/2` over seven known keys), so any unknown key survives and is
> merged verbatim into the Req option list; Req raises; the rescue in
> `execute_request/6` calls `CircuitBreaker.record_failure/1` unconditionally and
> returns `Error.network_error(...)`. Every other branch of that same case routes
> through `record_result/2` so the melt flows from the retry classification — the
> rescue bypasses it and melts on anything that raises. So the report is right
> that the fault is a caller error, and right that the breaker is the damage; the
> reach is wider than Binance and wider than `load_markets` — any unrecognized
> option on any venue and any method does this. `Bourse.Error` already carries
> `:bad_request` as non-recoverable, so the correct classification exists unused.
>
> Defect 1 (the option surface of `load_markets/2`) rides the same task as a
> deliberate decision with a documented rationale, not as a silent widening: the
> `api/2` declarations in `lib/bourse.ex` already state each method's accepted
> option set, and nothing enforces them at runtime — which is what lets an
> undeclared option reach Req at all. Enforcing the declaration would answer both
> halves at once; that confrontation is written into the task.
>
> **2026-08-22 — behoben in bourse 0.7.0.** Both halves shipped: an unrecognized
> request option is now rejected pre-wire as
> `%Bourse.Error{type: :bad_request, recoverable: false, retry_class: :non_retryable}`,
> so it never reaches Req and never records a breaker failure; and
> `load_markets/2` accepts and ignores `:type` / `:subType` / `:sub_type`, which
> was the instance that surfaced this. Verified from the consumer side by
> `trading_dashboard` on the 0.7.0 upgrade — its `Risk.credential_scope/2`
> workaround stays, but only for the reason that was always independently true
> (markets are venue-wide public data, so one load answers for every credential
> on the venue), not to route around this defect.

## 2026-09-14 — Deribit `parse_order/2`: `symbol` bleibt `nil`, obwohl `instrument_name` im Raw steht und `symbol:` als Option übergeben wird

**Status:** ✅ fixed 2026-09-15 (task 695, shipped `b4daa6f9402e`) — `field_maps.order.symbol` reads `instrument_name` as the native id; unified reads remap through loaded markets. Repro kept below as the evidence trail.

Call (bourse 0.8.0, Testnet live):

```elixir
raw = %{"order_id" => "OPT-1", "instrument_name" => "BTC-16SEP26-79000-P",
        "direction" => "buy", "amount" => 0.1, "price" => 0.02, "order_state" => "open",
        "order_type" => "limit", "label" => "mm", "creation_timestamp" => 1789374000000, ...}
Bourse.Deribit.parse_order(raw, symbol: "BTC-16SEP26-79000-P")
```

Observed: `{:ok, %Bourse.Order{id: "OPT-1", symbol: nil, side: "buy", price: 0.02, ...}}`.
Dasselbe gilt für die Orders, die `private/cancel` und `private/buy|sell` im
Envelope liefern — jede geparste Deribit-Order trägt `symbol: nil`.

Cause: `priv/venues/deribit/authored/normalization.json` → `field_maps.order.field_map.symbol`
ist `null`, obwohl das Raw-Objekt `instrument_name` führt. `Bourse.Parser.parse/4`
fädelt `:symbol` zwar in den Kontext, ein `null`-Slot wird aber nicht aus dem
Request-Kontext aufgefüllt — der in `Unified.ReadParse` beschriebene
"request-context symbol backfill" greift nur auf dem Unified-Lesepfad, nicht bei
`parse_order/2`.

Expected: entweder mappt der Slot `instrument_name` (bei Deribit ist das der
Unified-Symbol-Rohwert; mit geladenen Markets die `BTC/USD:BTC-…`-Form), oder ein
`null`-Slot wird aus `opts[:symbol]` aufgefüllt — so wie es die Positions- und
Trade-Pfade konsumentenseitig ohnehin tun müssen.

Konsument-Handling (trading_dashboard `MarketMaking.DeribitSession`): füllt
`symbol` nach dem Parse aus dem Request-Instrument nach (`parsed.symbol || instrument`),
identisch zum bestehenden Positions-Pfad. Betroffene Exchange: deribit.

---

## 2026-09-14 — Deribit: Antwort auf die Heartbeat-Reply (`public/test`) erreicht den Owner als Datenframe

**Status:** ✅ fixed 2026-09-15 (task 696, shipped `cbc17f5a7b73`) — `Bourse.WS.ControlFrame` classifies JSON-RPC result/error envelopes and ping/pong keepalives as transport control, so they arrive as `{:websocket_unmatched_response, _}` and route as `:system` instead of being broadcast as `:raw` market data. Repro kept below as the evidence trail.

Call (bourse 0.8.0, Testnet live): `Bourse.WS.connect(exchange, :public, [])` mit
Default-Handler, dann `watch_ticker(ws, "BTC-16SEP26-79000-P", [])` und
`watch_ticker(ws, "BTC-PERPETUAL", [])`; Deribit-Heartbeat aktiv.

Observed: neben den `subscription`-Notifications liefert der Default-Handler
periodisch

```elixir
{:websocket_message, %{"jsonrpc" => "2.0", "result" => %{"version" => "1.2.26"},
                       "testnet" => true, "usIn" => 1789374068399802, "usOut" => ..., "usDiff" => 42}}
```

Das ist Deribits Antwort auf das `public/test`, das die Bibliothek als Reply auf
`test_request` schickt. Sie kommt als `{:message, data}` → `{:websocket_message, _}`
beim Owner an, nicht als `{:websocket_unmatched_response, _}` und nicht
verschluckt — obwohl der Kommentar in `Bourse.WS` (Zeile ~544) genau diese Trennung
für Frames ohne In-flight-Request beschreibt.

Impact: ein Consumer, der jedes `{:websocket_message, frame}` eines abonnierten
Kanals als Tick liest (trading_dashboard `MarketData.Transport.Local.classify/2`),
verarbeitet das Result-Envelope als Marktdaten. Beobachtet: der MM-Orchestrator
journalierte es als `quote_rejected missing_mark_iv` und zog beide Quotes.

Expected: Antworten auf bibliothekseigene Requests (Heartbeat-Reply, Subscribe-Ack)
erreichen den Owner nie als Datenframe; entweder wird die Reply-ID getrackt und die
Antwort konsumiert, oder sie läuft als `:websocket_unmatched_response`.

Konsument-Handling (trading_dashboard): `Transport.Local.classify/2` verwirft
JSON-RPC-Envelopes mit `result`/`error` ohne `method` (Commit `90124f2`). Betroffene
Exchange: deribit; jede andere JSON-RPC-Venue mit Heartbeat dürfte gleich reagieren.

## 2026-09-15 — Coinbase pagination adds a future page at an unaligned end

**Status:** Landed via task 691, `d2befc8afe24`; confirmed present on origin/main during the 2026-09-15 post-merge audit. The reported 1200-hour window is pinned offline in `test/bourse/coinbase_candle_pagination_test.exs`; no fresh live `ETH/USD` call was made in this audit.

Observed in trading_dashboard with Bourse 0.8.0: `Bourse.fetch_ohlcv(client, "ETH/USD", "1h", since: 1785110400000, until: 1789429905831, limit: 1200)` fails with Coinbase HTTP 400 `Start cannot be in the future`. Provider `/time` agrees with the local clock. `CoinbaseCandlePagination.pagination/3` adds ceil alignment slack despite the start already being aligned, generating a fifth page whose start is the next hour. Expected: four pages covering the 1200 opened buckets, no page starting after the requested end. Aligning until to 1789426800000 returned 1200 real rows immediately. Consumer Calendar now aligns the inclusive end to the native candle opening; upstream should bound generated page starts/ends to the actual requested window. This was hidden by the chart continuing to display WebSocket-only prices after history failed.

---

## 2026-09-14 — `SpecConfig`-Heartbeat `:ping` erreicht in zen_websocket 0.9.0 den No-op-Zweig; `Bourse.WS` legt keine Heartbeat-Evidenz offen

**Status:** ✅ fixed 2026-09-15 (task 696, shipped `cbc17f5a7b73`) — `Bourse.WS.Heartbeat.validate/1` accepts only `:disabled`, `:deribit` and `:ping_pong`; `:ping`/`:custom` fail at `connect/3` with `{:error, {:unsupported_heartbeat, type}}` rather than presenting a dead timer as liveness, and `Bourse.WS.health/1` exposes the dependency's `get_heartbeat_health/1` observations per socket. The venues whose keepalive is a JSON/string application ping are authored `:disabled`; the remaining upstream gaps are recorded in `docs/ws-heartbeat-upstream.md`. Repro kept below as the evidence trail.

Call (bourse 0.8.0, zen_websocket 0.9.0, Quell-Inspektion): `Bourse.WS.connect(exchange, :public, [])`
für `binance`/`binanceusdm`; `Bourse.WS.Config`/`SpecConfig` löst die Heartbeat-Konfiguration auf.

Observed — drei zusammenhängende Befunde:

1. `Bourse.WS.SpecConfig` konfiguriert Binance (und die meisten Venues außer Deribit)
   mit `heartbeat: %{type: :ping, interval: …}` (`lib/bourse/ws/spec_config.ex:50,66,79,107,129,145,167,181,192`;
   `heartbeat_type/3` fällt für `"native_frame"`/unbekannte `ping_kind` auf `:ping` zurück).
   `ZenWebsocket.HeartbeatManager.send_heartbeat/1` kennt nur `%{type: :deribit}` und
   `%{type: :ping_pong}`; jeder andere Typ trifft die explizite Fallback-Klausel
   (`deps/zen_websocket/lib/zen_websocket/heartbeat_manager.ex:147-150`, Kommentar:
   "unrecognized heartbeat types are no-ops"). Auf einem Binance-Socket wird damit
   **nie** ein Heartbeat gesendet, obwohl einer konfiguriert ist — Timer läuft,
   `active_heartbeats` bleibt leer.
2. `Bourse.WS.get_state/1` liefert ein Verbindungs-Zustands-Atom, keine Heartbeat-Evidenz.
   `ZenWebsocket.Client.get_heartbeat_health/1` (`client.ex:379`) existiert, wird von
   `Bourse.WS` aber nirgends gewrappt (`grep heartbeat lib/bourse/ws.ex` trifft nur
   Moduledoc und die Config-Weitergabe in Zeile 722/726).
3. `HeartbeatManager` zählt ausbleibende Pongs in `heartbeat_failures`, trennt die
   Verbindung aber nicht, wenn sie sich häufen. Es gibt damit keine
   Failed-Heartbeat-Disconnect-Evidenz mit gebundener Deadline.

Impact: ein Consumer kann verifizierte Transport-Liveness nicht von Datenstille
unterscheiden. Für dichte Feeds ist ein leeres Marktdatenfenster ein brauchbarer
Proxy, für dünne Feeds (Binance USD-M `{symbol}@forceOrder`) nicht: dort ist Stille
der Normalfall, und die einzige verbleibende Evidenz ist der Disconnect selbst.
Socket-Existenz, ein laufender Timer, ein erfolgreicher Session-Keepalive und ein
leeres Marktdatenfenster sind keine Heartbeat-Evidenz.

Expected: `Bourse.WS` konfiguriert einen von zen_websocket tatsächlich unterstützten
Heartbeat-Mechanismus (`:ping_pong` für Venues mit nativen Control-Frames, siehe
[Binance Spot WebSocket](https://github.com/binance/binance-spot-api-docs/blob/master/web-socket-streams.md))
und legt verbindungsbezogene, verifizierte Heartbeat-Beobachtungen plus
Failed-Heartbeat/Disconnect-Evidenz über eine eigene API offen — auch für geroutete
Subscription-Sockets. Ein nicht unterstützter Heartbeat-Typ sollte laut scheitern
statt still zum No-op zu werden.

Konsument-Handling (trading_dashboard `MarketData.StreamWorker`, Task 263): ein
stiller Liquidations-Socket wird allein auf Disconnect-Evidenz oben gehalten;
Data-Freshness wird nur für dichte Feeds erzwungen. Die Failed-Heartbeat-Erholung ist
am Worker mit injiziertem `{:down, :heartbeat_failed}` getestet — Bourse emittiert
diesen Grund noch nicht. Der Dashboard-Code greift bewusst nicht auf `ws.zen_client`
durch. Kontext: `docs/stream-liveness-contract.md` im trading_dashboard.
Betroffene Exchange: binance, binanceusdm und jede Venue mit `heartbeat.type: :ping`.

---

## 2026-09-14 — `coinbaseexchange` hat keine öffentliche WebSocket-Hand-Base; `Bourse.WS.connect/2` ist für die Venue nicht benutzbar

**Status:** Tracked in task 697 (triage 2026-09-15); implementation pending.

Call (bourse 0.8.0): `Bourse.WS.connect(:coinbaseexchange, :public, [])` bzw. jede
Subscription auf dem öffentlichen Coinbase-Exchange-Feed.

Observed: `coinbaseexchange` ist in `Bourse.WS.Config.registered_divergences/0` als
`:websocket_not_configured` geführt. REST-Venue-Support (`Bourse.fetch_ohlcv/4`
liefert für die Venue einwandfrei Kerzen) impliziert also keinen WebSocket-Support;
es gibt keinen Weg, den öffentlichen `matches`/`heartbeat`-Kanal über Bourse zu
konsumieren.

Expected: eine öffentliche Hand-Base für Coinbase Exchange — URL
`wss://ws-feed.exchange.coinbase.com`, `type: "subscribe"` mit `product_ids` und
`channels: ["matches", "heartbeat"]`, Subscribe-Ack (`type: "subscriptions"`) und
Reject (`type: "error"`, `message: "Failed to subscribe"`,
`reason: "<kanal> is not a valid channel"`), sowie normalisierte Trades aus
`trade_id`/`price`/`size`/`time`. Kanaldokumentation:
https://docs.cdp.coinbase.com/exchange/websocket-feed/channels

Live-Evidenz (2026-09-14, unabhängiger Probe gegen den öffentlichen Feed): ein
`subscriptions`-Ack, ein historischer `last_match`, ein neuer `match`
(trade_id 842699720, ETH-USD), ein `heartbeat` sowie Coinbases dokumentierte
Ablehnung eines ungültigen Kanals. `last_match` ist historisch — als Volumen
angewandt, doppelt es REST-Historie; `matches` darf Frames verlieren, und
`heartbeat.last_trade_id` ist die Lücken-Evidenz für REST-Recovery. Ticker-Frames
sind kein Ersatz, da sie das exakte Trade-Volumen nicht tragen.

Konsument-Handling (trading_dashboard Task 261): `TradingDashboard.Chart.Feed`
konsumiert den Feed direkt über `ZenWebsocket.Client` — denselben Client, den
`Bourse.WS` wrappt — in `TradingDashboard.Chart.CoinbaseSocket`, ohne Credentials
und ohne private Kanäle. Sobald die Hand-Base existiert, ersetzt
`Bourse.WS.connect/2` diesen Direktzugriff; der Contract-Test dafür ist
`test/integration/chart_stream_integration_test.exs`. Kontext:
`docs/coinbase-chart-stream-blocker.md` im trading_dashboard.
Betroffene Exchange: coinbaseexchange.

---

## 2026-09-15 — Deribit: Fehlercode 11044 `not_open_order` wird als `:operation_failed`/InvalidOrder statt `:order_not_found` klassifiziert

**Status:** ✅ fixed 2026-09-15 (task 695, shipped `b4daa6f9402e`) — `raw.exceptions.11044` maps to `OrderNotFound` for every open-order operation that returns it, over REST and WS alike. Repro kept below as the evidence trail.

Call (bourse 0.8.0): `Bourse.cancel_order/3` bzw. jeder `private/cancel` gegen Deribit auf eine Order, die die Venue bereits geschlossen hat — typisch nach einem MMP-Trigger, der alle MMP-Orders des Index selbst cancelt, oder nach einem Fill.

Observed: Deribit antwortet `{"code": 11044, "message": "not_open_order"}` (Live-Probe 2026-09-15 auf test.deribit.com: Order anlegen, canceln, nochmals canceln). `priv/venues/deribit/authored/raw.json` mappt `"11044": "__function:InvalidOrder"` (CCXT-Erbe), der `%Bourse.Error{}` trägt `type: :invalid_order` bzw. auf dem WS-Pfad `:operation_failed`, `retry_class: :non_retryable`. Ein Konsument, der `:invalid_order` als definitive Ablehnung behandelt, macht aus einem idempotenten Cancel einen permanenten Fehler.

Expected: `type: :order_not_found` (bourse kennt den Typ bereits, `Bourse.Error.order_not_found/1`). „Order ist nicht offen“ ist für einen Cancel das Ziel, nicht ein ungültiger Auftrag; CCXT-Konsumenten prüfen genau dafür auf OrderNotFound. Dokumentation: https://docs.deribit.com/api-reference/errors (11044 not_open_order).

Konsument-Handling (trading_dashboard, 2026-09-15): `TradingDashboard.MarketMaking.DeribitSession.venue_error/1` und `TradingDashboard.Exchange.OrderPlacement.error_term/1` mappen den Code 11044 lokal auf `:order_not_found`; die Session liest danach `private/get_order_state`, um den echten Endzustand zu journalisieren. Beide Sonderfälle können entfallen, sobald bourse den Code richtig klassifiziert.
Betroffene Exchange: deribit.

---

## 2026-09-15 — Deribit `parse_trade/2`: `fee` bleibt `%{"cost" => nil, "currency" => nil}`, obwohl der Rohtrade `fee`/`fee_currency` trägt

**Status:** ✅ fixed 2026-09-15 (task 695, shipped `b4daa6f9402e`) — the trade field map copies `fee`/`fee_currency` into the Fee contract (signed, no invented order-level aggregate), and both `fee`/`fees` are `omit_if_empty` so public `public/get_last_trades_by_instrument` rows, which carry no fee, keep the unavailable default. Repro kept below as the evidence trail.

Call (bourse 0.8.0): `Bourse.fetch_my_trades(exchange, symbol: "BTC/USD:BTC", limit: 1)` gegen test.deribit.com; gleiches Bild für die Trades in `Bourse.fetch_order/3` (`trades: []`, `fee: nil`).

Observed (2026-09-15, Perp-Hedge-Fill trade_id 267453606): `%Bourse.Trade{fee: %{"cost" => nil, "currency" => nil}, fees: [], info: %{"fee" => 6.385e-5, "fee_currency" => "BTC", ...}}`. Die Normalisierung legt die Fee-Map an, füllt sie aber nicht aus den Deribit-Feldern `fee` und `fee_currency`. `cost` ist dagegen gefüllt.

Expected: `fee: %Bourse.Fee{cost: 6.385e-5, currency: "BTC"}` (bzw. die Map mit denselben Werten) und `fees: [...]`, wie bei den anderen Venues. Deribit-Trade-Schema: https://docs.deribit.com/api-reference/trading/private-get_user_trades_by_instrument (`fee`, `fee_currency`).

Konsument-Handling (trading_dashboard, 2026-09-15): `TradingDashboard.Exchange.OrderLifecycle` fällt beim Anlegen einer `OrderFill` auf `info["fee"]`/`info["fee_currency"]` zurück, wenn die normalisierte Fee keinen `cost` hat. Der Fallback entfällt, sobald die Normalisierung greift.
Betroffene Exchange: deribit.
||||||| Stash base
