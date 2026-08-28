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

---

## 2026-08-28 — the client's rate limiter grants a 545-deep burst on OKX, then stalls the next call for a full 60 s

**Status:** 🆕 measured live + proven arithmetically (orchestrator, investigating a reported
60 s stall on two OKX contract cases) — not consumer-reported. **Latent**: it did not fire in
any of seven runs on 2026-08-28, but it is the only code path in the client that can block a
single call for exactly ~60 000 ms.

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

**Status:** 🆕 confirmed live (orchestrator) — not consumer-reported. **This is a real client
defect**, unlike the rest of the 2026-08-28 contract-lane reds, which adjudicated to empty
sandbox state or host toolchain.

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

**Status:** 🆕 measured live (orchestrator triage of the task 674 reviewer's finding) — not consumer-reported.

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

**Status:** 🆕 measured live (orchestrator triage of the task 675 reviewer's finding) — not consumer-reported.

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

**Status:** 🆕 measured (orchestrator, across six harness reviews and two full local runs) — not consumer-reported.

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

**Status:** 🆕 measured live (task 679 trader journey) — not consumer-reported.

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

**Not fixed here.** Using `data[0].sCode` when the outer code is `"1"` would retype every
OKX batch refusal (including the 51121 lot-size rejection the journey pins). That is a
classification change, not a journey-lane patch.

---

## 2026-08-28 — `Bourse.WS.connect/3` swallows `:no_auth_pattern` and hands back an open **unauthenticated** private socket

**Status:** 🆕 measured live (orchestrator, harness wave 665/673/681/682) — not consumer-reported.

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

**Not fixed here.** Either `connect/3` refuses a `:private` section with no `auth_pattern`,
or derive authors its `auth_pattern` so the venue's `public/login` runs as the handshake.
Both are behaviour changes outside the wave that surfaced this.

---

## 2026-08-28 — `mix bourse.check_lighter_signer` exits 0 while reporting "NOT RUN" — a gate that is green without running

**Status:** 🆕 measured (orchestrator) — not consumer-reported.

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

**Status:** 🆕 operator action — credential refresh, not a code defect.

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

**Status:** 🆕 reported (consumer: `trading_dashboard`, bourse 0.7.0, live Deribit public API,
2026-08-28 ~00:50 UTC; no credentials — all endpoints public)

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

**Status:** 🆕 reported (measured, not consumer-reported — mutation testing on
`lib/bourse/signing/hmac_recipe.ex`, muex 0.9.1, 2366 mutants, 421 survivors)

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

**Status:** 🆕 reported (found while scoping a mutation-testing run; `main` is red on a clean
tree as of `e71e714`)

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

**Status:** 🆕 reported (found live while building the trader WS journey, 2026-08-24; the
journey subscribes the raw `"order"` topic directly and is green, so nothing user-facing is
blocked — the defect is that the unified `watch_orders/2` path cannot do the same)

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

**Consumer impact:** any consumer following the unified WS surface gets an error where the
venue works fine; the workaround (raw topic string) requires venue knowledge the unified
layer exists to encapsulate. Related sharp edge recorded with the journey: bybit's private
pushes carry an `"id"` field, so zen_websocket's correlator hands them to the owner as
`{:websocket_unmatched_response, frame}`, never `{:websocket_message, _}` — a fix to the
channel template should keep that delivery shape in mind.

## 2026-08-24 — `Bourse.Symbol.reverse_aliases/1` is not injective on hyperliquid's authored alias map — one currency is silently dropped

**Status:** 🆕 reported (mutation-testing testability survey, 2026-08-24 — see the provenance
note on the test-gap entry below; the finding came from reading `lib/bourse/symbol.ex`, and the
numbers here were re-measured against the authored data with `mix run`)

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

**Status:** 🆕 reported (mutation-testing testability survey, 2026-08-24 — provenance note on the
test-gap entry below; measured against authored alias maps and the frozen reference slice's
market ids)

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

**Status:** 📋 noted (not defects — test gaps, filed so the evidence is not lost)

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

**Status:** 🆕 reported (surfaced by the task-671 bybit lane; cross-venue client machinery, untouched by the venue-scoped fix pass)

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

**Status:** 🆕 reported (task-671 bybit pass — deliberately not fixed venue-scoped: the fix
touches `fetchBalance` envelope authoring for `type: funding` across venues)

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

**Status:** 🆕 reported (task 671 state-population pass)

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

**Status:** 🆕 reported (task 671, live-verified 2026-08-23)

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

**Status:** 🆕 reported (task 671, live-verified 2026-08-23)

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

**Status:** 🆕 reported (task 671, live-verified 2026-08-23)

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

**Status:** 🆕 reported (task 671 carved them out of the six red READ methods only — see `docs/authored-spec-carves/bybit.md` C-T671a)

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

**Status:** 🆕 reported · **Venue:** deribit (testnet, `sandbox: true`, bourse `0.7.0` from Hex) ·
**Class:** unfilled unified field — not a venue gap. The venue publishes the numbers in the very
payload the client already fetches and parses.

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

---

## 2026-08-22 — `Bourse.load_markets/2` rejects `:type` and reports the unknown option as a recoverable network error, blowing the circuit breaker

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
