# bourse Roadmap

**Vision:** `bourse` — an Elixir client for **ten supported venues** (`alpaca`, `binance`, `binancecoinm`, `binanceusdm`, `bybit`, `deribit`, `derive`, `hyperliquid`, `lighter`, `okx`), generated from **one complete hand-authored JSON spec per venue** via macros. Every interpretive slice (signing, request shape, response normalization, symbol/error semantics) is **authored against the exchange-owned API contract and verified live against the venue's own testnet/demo host** — every case in the REST-read contract inventory (`priv/authority/rest-read-contracts.json`) is executed for real by `mix ccxt.verify_rest_read_contracts`. CCXT JS is unverified authoring reference material, never the oracle (see [docs/authored-specs.md](docs/authored-specs.md)). The one reality is the exchange APIs themselves. Runtime support is a closed manifest (`priv/specs/json/runtime_support.json`); adding an eleventh venue is a promotion, not a config flag.

**Design spec:** [2026-04-03-ccxt-client-roadmap-design.md](docs/superpowers/specs/2026-04-03-ccxt-client-roadmap-design.md) (historical — predates the authored-specs pivot and the ten-venue cutover)

**Task tracking:** This file is rendered by `rmap` from `roadmap/tasks.toml`. Don't hand-edit task tables inside `<!-- TASKS:BEGIN -->` / `<!-- TASKS:END -->` marker pairs — they're regenerated on every `rmap render`. Edit `roadmap/tasks.toml` or use `rmap status` / `rmap mark` / `rmap new`. Prose outside the marker pairs is byte-preserved.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for release notes. Per-task history (done + superseded) stays durable in `roadmap/tasks.toml`; query with `rmap list --status done`.

---

## For Consumers (Users & AI Agents)

What to rely on today and how to discover the rest. All snippets in this section were verified end-to-end against a live app via `tidewave project_eval` on 2026-07-26.

### Stability Tiers

| Surface | Status | Use For |
|---------|--------|---------|
| **Raw per-exchange endpoints** (`Bourse.<Exchange>.public_get_*`, `private_post_*`, …) | ✅ Stable | Production trading, agents, anything that wants to interpret exchange-native responses. Signing / rate limiting / circuit breakers / transport all handled. |
| **Unified methods** (`fetch_ticker`, `fetch_balance`, `create_order`, …) | ✅ Authored + reality-verified per venue | Normalized structs (`%Bourse.Ticker{}` etc.). Every venue's interpretive slices are authored against the provider contract; verification per slot is binary — `verified` once a live call against the venue's own testnet/demo host exercises it (via `mix ccxt.verify_rest_read_contracts` against the REST-read contract inventory), or honestly `unverified`. |
| **WebSocket subscribe** (`Bourse.WS.connect`, `subscribe`, `close`) | 🔶 Configured for 16 exchanges, frames exchange-native | Streaming. Frames arrive as `{:websocket_message, decoded_map}`; channel names are pass-through. |
| **WebSocket unified frames** (`%Bourse.Ticker{}` over WS) | ❌ Not shipped | WS authored slices = task 175, deferred; no ETA. |

### Supported Venues (closed runtime set)

Exactly ten venues compile — one generated module per entry in `priv/specs/json/runtime_support.json`. There is **no compile-time selection knob**; constructing any other exchange fails with `unsupported_exchange`. The former ~100-exchange long tail lives on only as a reference corpus (`priv/specs/json/reference_corpus.json`) for authoring/audit tooling — never loaded at runtime, never shipped in the Hex package.

```elixir
Bourse.Registry.exchanges()
#=> ["alpaca", "binance", "binancecoinm", "binanceusdm", "bybit",
#    "deribit", "derive", "hyperliquid", "lighter", "okx"]
```

Supported specs are **hand-authored and frozen** (`priv/specs/json/output/authored/<venue>.json`, schema version 3); the CCXT-derived siblings are read-only reference input. Widening support means promoting a venue: author its spec against the exchange's own contract, prove each interpretive slice against a live call to its testnet/demo host, then admit it into the closed runtime manifest.

### Verified Examples

All snippets run against the live app via tidewave on 2026-07-26 — outputs shown are real.

**1. Construct an exchange**

```elixir
{:ok, bybit} = Bourse.Exchange.new("bybit")
# or with credentials:
{:ok, bybit} = Bourse.Exchange.new("bybit", credentials: Bourse.Credentials.new!(api_key: "...", secret: "..."))
```

**2. Raw public call — exchange-native response**

```elixir
{:ok, response} =
  Bourse.Bybit.public_get_v5_market_tickers(bybit, %{category: "spot", symbol: "BTCUSDT"})

response.status
#=> 200
get_in(response.body, ["result", "list"]) |> List.first()
#=> %{"symbol" => "BTCUSDT", "lastPrice" => "64570.6", ...}
```

**3. Unified calls — normalized values**

```elixir
{:ok, deribit} = Bourse.Exchange.new("deribit")
{:ok, server_time} = Bourse.fetch_time(deribit)
#=> {:ok, 1785068765295}   # ms epoch, normalized

{:ok, ticker} = Bourse.fetch_ticker(bybit, "BTC/USDT")
ticker.__struct__   #=> Bourse.Ticker
ticker.last         #=> 64570.6
```

**4. WebSocket public stream**

```elixir
{:ok, exchange} = Bourse.Exchange.new("bybit")
{:ok, ws} = Bourse.WS.connect(exchange, :public)
:ok = Bourse.WS.subscribe(ws, ["tickers.BTCUSDT"])
# receive do
#   {:websocket_message, %{"topic" => "tickers.BTCUSDT", "data" => data}} -> ...
# end
Bourse.WS.close(ws)
```

### Discovery (Agent-Friendly)

```elixir
Bourse.describe()                       # Library overview + quick start
Bourse.describe(Bourse, :fetch_ticker)  # Method contract — arity, params, errors, returns
Bourse.MCP.tools()                      # MCP tool definitions (248 entries) for agent autodiscovery
Bourse.Registry.exchanges()             # The ten supported exchange ids

# Per-exchange introspection (every generated exchange module):
Bourse.Bybit.__spec__()                 # Raw spec map
Bourse.Bybit.__endpoints__()            # 366 endpoints with path/method/auth/weight
Bourse.Bybit.__signing__()              # %{pattern: :hmac_sha256_headers, config: %{...}}
Bourse.Bybit.__unified_endpoints__()    # Unified-method → endpoint configs
Bourse.Bybit.__features__()             # has/features map from spec
```

### Error Handling

Unified methods return `{:ok, result}` or `{:error, %Bourse.Error{}}`. The error struct carries:

```elixir
%Bourse.Error{
  type: :bad_request,            # One of 17 canonical types
  code: 10001,                   # Exchange-native error code (when present)
  http_status: 400,              # nil if mapped from body sentinel (not HTTP status)
  message: "Illegal category",   # Raw exchange message
  exchange: "bybit",
  retry_after: nil,              # Set for rate-limit errors when header present
  recoverable: false,            # true for :rate_limit, :network, :server_busy
  hints: []
}
```

See `lib/bourse/error.ex` for the full type list.

### Release Status

- **0.6.1** — ✅ published to Hex as `ccxt_client` on 2026-04-20 (https://hex.pm/packages/ccxt_client/0.6.1). The last release of the pre-pivot full-catalog architecture; consumers can stay pinned on `{:ccxt_client, "~> 0.6.1"}` or migrate per [README § Migrating from ccxt_client](README.md).
- **1.0.0 (in tree, unpublished)** — marks the bourse rename cut (task 182), not a Hex release. The Hex publish of `bourse` is gated on the `v1_0` roadmap milestone; query with `rmap list --milestone v1_0`.

---

## Current Focus

**Provider-authoritative, provider-live specs** (pivot 2026-06-21; the client's fixture/mock/replay test lane is retired — every assertion about venue behavior is a live call against its own testnet/demo host). Verification is **binary**: a slot is `verified` only when a live call, via the REST-read contract inventory (`priv/authority/rest-read-contracts.json`) and `mix ccxt.verify_rest_read_contracts`, exercises it; otherwise it is honestly `unverified`. Compatibility with CCXT is not a verification tier. Provenance is **computed, not declared**: the derivation walks the REST-read contract inventory, so a venue acquires `verified` slots the moment its live coverage lands. Full model: [docs/authored-specs.md](docs/authored-specs.md); per-venue schema confrontations live in `docs/authored-spec-carves/`.

Remaining `v1_0` work: scheduled live drift verification (task 157, in flight), prod-verification ledger closures (task 327, operator-gated), and the binance dust-encoding reality probe (task 349, operator-gated). Post-1.0: CCXT corpus eviction to manifest-pinned on-demand fetch (task 524), WS authored slices (task 175).

> **Verify against reality, not against CCXT.** A CCXT-matching value proves *compatibility*, never *correctness*. For divergence-prone fields the oracle is the real exchange API plus a provider-owned semantic source. When checking whether a venue "works," the first move is a **live signed call against its testnet/demo host**, not a fixture replay.

---

## Packaging & Release Strategy

**Decision: single library (`:bourse`), two documented contracts — raw and unified. Do not split into core + unified packages unless concrete pressure justifies it.**

- **Raw surface** — `Bourse.Bybit.public_get_v5_market_tickers/2`, generated per venue. Pass-through semantics (signing + transport). Primary agent-facing surface.
- **Unified surface** — `Bourse.fetch_ticker/2`, the authored normalization layer, reality-verified per slot via a live call against each venue's own testnet/demo host.

Both compile together and share the spec pipeline; splitting would double release/CI/docs work for no marginal benefit. Revisit only if release cadences genuinely diverge or a consumer needs to pin raw independently of unified. The Hex package ships `lib`, the native lighter signer, and exactly the ten authored runtime specs + manifest (see `mix.exs` `package/0`) — the reference corpus stays out.

---
## Phase 1: Foundation

Build spec loader, core types, exchange configuration, HTTP client, error types.

<!-- TASKS:BEGIN phase=1 -->
> 6 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-1-foundation).
<!-- TASKS:END -->

## Phase 2: Macro Engine

The heart of the project. `use CCXT.Exchange, spec: "bybit"` generates exchange modules from specs at compile time.

<!-- TASKS:BEGIN phase=2 -->
> 8 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-2-macro-engine).
<!-- TASKS:END -->

## Phase 3: Signing Patterns

Request authentication via 9 signing patterns classified from spec ASTs.

<!-- TASKS:BEGIN phase=3 -->
> 6 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-3-signing-patterns).
<!-- TASKS:END -->

## Phase 4: REST Client (Unified API)

The public-facing unified API. `CCXT.fetch_ticker(exchange, "BTC/USDT")`.

<!-- TASKS:BEGIN phase=4 -->
> 7 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-4-rest-client-unified-api).
<!-- TASKS:END -->

## Phase 5: Integration Tests

Macro-generated integration tests validating Phase 4 end-to-end and providing acceptance criteria for Phase 6 parsers. Compile-time test generation from exchange introspection functions — same macro patterns as `CCXT.Exchanges`.

> **Design principles:** `CCXT.Testnet` ETS credential registry (scales to 110+ exchanges). Tag hierarchy for surgical test selection (`:integration`, `:public`/`:authenticated`, `:unified`/`:raw`/`:signing`, `:exchange_bybit`). `ExUnit.configure(exclude: [:integration])` — never runs by accident. Prod URLs for public, sandbox for private. Rate-limited responses treated as inconclusive, not failure. Structural assertions detect parsed structs (Phase 6) vs raw responses automatically. `flunk()` with actionable env var instructions for missing credentials. `:dangerous` tag for write endpoints — never auto-run. Port patterns from `../ccxt_client_bak/test/support/`.

> **Credentials available:** Deribit, Bybit, Binance. New exchange = add config entry, tests auto-generate.

<!-- TASKS:BEGIN phase=5 -->
> 15 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-5-integration-tests).
<!-- TASKS:END -->

## Phase 6: Parsers (Field Mapping Extraction)

Transform raw exchange responses into unified structs via compile-time field mapping extraction.

> **json_spec integration:** `json_spec` (already a transitive dep via descripex) provides compile-time Elixir typespec → JSON Schema conversion and safe `atomize/2` for string→atom key conversion. Use it at two boundaries: (1) unified type schemas on structs for agent/MCP discovery, and (2) safe atomization after field mapping extraction, before struct creation. Do NOT use for raw exchange response validation — exchange APIs are too inconsistent; the Safe accessor pattern handles that.

<!-- TASKS:BEGIN phase=6 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 19 | ✅ | 🎁 **v4_adopt** · 🚀 **v0_7_0** · AST Field Extractor [D:7/B:9/U:10 → Eff:1.36?] 📋 |
| Task 20 | ✅ | 🎁 **v4_adopt** · 🚀 **v0_7_0** · Generic Parser [D:2/B:8/U:9 → Eff:4.25?] 🎯 |
| Task 21 | ✅ | 🎁 **v4_adopt** · 🚀 **v0_7_0** · Generated Parse Functions (reshape — consume upstream field maps) [D:2/B:8/U:9 → Eff:4.25?] 🎯 |
| Task 21b | ✅ | 🎁 **parsers** · Unified Type Schemas [D:2/B:7/U:8 → Eff:3.75?] 🎯 |
| Task 44 | ✅ | 🎁 **v4_adopt** · 🚀 **v0_7_0** · Response Shape Transformers (reduce scope pending upstream Task 83) [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 116 | ⛔ | 🎁 **parsers** · Catalog 2026-04-21 integration-run failures into a persistent evidence artifact [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 515 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Error classification silently drops market-type-scoped exception sub-maps [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 518 `[CX]` | ✅ | 🎁 **authored_specs** · Author the error-classification market scope instead of inferring it from base-URL text [D:5/B:7/U:6 → Eff:1.3?] 📋 |
<!-- TASKS:END -->

## Phase 7: WebSocket (Real-Time Streaming) — Unified Layer

Real-time market data and order updates. ZenWebsocket, three-layer architecture.

> **⚠️ Hold off starting Phase 7 unified work until upstream Phase 15 (Tasks 91–96) lands.** Upstream will deliver declarative WS subscribe/auth/heartbeat/snapshot-delta per channel. Starting now risks porting classifier infrastructure we'll delete. Pattern modules stay as runtime executors; classifiers go.

> **Deps:** Add `zen_websocket` when starting Phase 7. Verify whether `castore` is needed — present in bak but may not be required.

> **Distinction:** Phase 7 (unified, normalized) is gated; Phase 12 (unnormalized WS track ported from bak) ships now.

<!-- TASKS:BEGIN phase=7 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 22 | ⛔ | 🎁 **ws_unified** · 🚀 **v1_0** · WS Helpers (Layer 1) [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
| Task 23 | ⛔ | 🎁 **ws_unified** · 🚀 **v1_0** · Subscription Pattern Modules [D:3/B:8/U:8 → Eff:2.67?] 🎯 |
| Task 24 | ⛔ | 🎁 **ws_unified** · 🚀 **v1_0** · WS Client (Layer 2) [D:3/B:8/U:8 → Eff:2.67?] 🎯 |
| Task 25 | ✅ | 🎁 **ws_unified** · 🚀 **v1_0** · WS Adapter (Layer 3) [D:4/B:8/U:7 → Eff:1.88?] 🚀 |
| Task 26 | ✅ | 🎁 **ws_unified** · 🚀 **v1_0** · Unified WS API [D:3/B:8/U:8 → Eff:2.67?] 🎯 |
| Task 27 | ⛔ | 🎁 **ws_unified** · 🚀 **v1_0** · WS Auth Patterns [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 121 | ✅ | 🎁 **ws_unified** · 🚀 **v1_0** · Adopt spec-driven WS config from v4.1.0 `websocket` section [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 122 | ✅ | 🎁 **signing** · Resolve signing fixture-replay drift vs ccxt_extract fixtures (8 cases) [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 618 `[P]` | ✅ | 🎁 **live_triage** · Binance-family WS subscribe templates are CCXT message-hashes, not provider stream names — silent dead streams that ack cannot catch [D:5/B:7/U:5 → Eff:1.2] 📋 |
| Task 627 `[P]` | ✅ | 🎁 **live_triage** · USD-M public WS host /ws silently drops documented ticker and aggTrade streams [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 628 `[P]` | ✅ | 🎁 **live_triage** · Spot partial-depth frames have no e field, so watch_order_book never routes after task 618 [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 629 `[P]` | ⛔ | 🎁 **live_triage** · 🐛 Author Binance COIN-M unified WebSocket watch channels [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 630 | ✅ | 🎁 **live_triage** · 🐛 Make split-host WebSocket subscriptions own and reuse connections [D:6/B:8/U:7 → Eff:1.25] 📋 |
| Task 631 | ✅ | 🎁 **live_triage** · 🐛 Mixed-host WS subscribe must not leave a live half when the other host fails [D:4/B:6/U:4 → Eff:1.25] 📋 |
| Task 632 | ✅ | 🎁 **live_triage** · 🐛 Binance-family order-type reads are not the inverse of the writes: every conditional type collapses to market or limit [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 634 | ✅ | 🎁 **live_triage** · 🐛 Deribit shipped release 2.1.1 during a maintenance window: re-bind the current-REST corpus to the republished OpenAPI [D:5/B:8/U:8 → Eff:1.6] 🚀 |
<!-- TASKS:END -->

## Phase 8: Polish (Hex Publishing)

Production-ready for Hex.pm publication.

<!-- TASKS:BEGIN phase=8 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 28 | ✅ | 🎁 **polish** · Discoverable + MCP Tools [D:2/B:7/U:8 → Eff:3.75?] 🎯 |
| Task 29 | ✅ | 🎁 **polish** · 🚀 **v1_0** · ExDoc + Documentation [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 30 | ✅ | 🎁 **polish** · 🚀 **v1_0** · Quality Gates [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 31 | ✅ | 🎁 **polish** · 🚀 **v1_0** · Hex Package + README [D:2/B:7/U:7 → Eff:3.5?] 🎯 |
| Task 32 | ✅ | 🎁 **polish** · 🚀 **v1_0** · Mix Tasks [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 33 | ✅ | 🎁 **polish** · 🚀 **v1_0** · Telemetry — WS + signing events [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 34 | ✅ | 🎁 **polish** · Log warning for missing path params [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 35 | ✅ | 🎁 **polish** · Fix "options" section ambiguity in build_endpoint_configs [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 36 | ✅ | 🎁 **polish** · 🚀 **v1_0** · Add Descripex.emit_api/3 for compile-time loops [D:2/B:6/U:7 → Eff:3.25?] 🎯 |
| Task 106 | ✅ | 🎁 **polish** · 🚀 **v0_6_1** · Add `LICENSE` file (MIT text) [D:1/B:3/U:4 → Eff:3.5?] 🎯 |
| Task 107 | ✅ | 🎁 **polish** · 🚀 **v0_6_1** · Document `has?/2` ≠ "dispatch will succeed" + `:custom` signing caveat + no-testnet list in README [D:1/B:5/U:6 → Eff:5.5?] 🎯 |
| Task 118 `[P]` | ✅ | 🎁 **polish** · Guard `CCXT.Symbol.detect_market_type/1` against bare strings [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 123 | ✅ | 🎁 **polish** · Rewrite ROADMAP.md prose for full-catalog / ccxt-distill reality [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 124 | ✅ | 🎁 **polish** · Cache or pre-resolve request contract shapes to avoid per-Dispatch.call Spec.load! JSON I/O+decode [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task 125 | ⛔ | 🎁 **polish** · 🚀 **v1_0** · Publish descripex 0.9.2 and drop vendor path dep [D:1/B:4/U:5 → Eff:4.5?] 🎯 |
| Task 126 | ✅ | 🎁 **polish** · Convert or remove remaining bare TODO: comments per project convention [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 201 | ✅ | 🎁 **polish** · 🔒 Redacting Inspect for credential-bearing structs + Testnet ETS access tightening [D:2/B:9/U:8 → Eff:4.25?] 🎯 |
| Task 203 | ✅ | 🎁 **polish** · 🔒 Wire dependency CVE scanning (mix_audit) into the check stack [D:1/B:5/U:6 → Eff:5.5?] 🎯 |
| Task 205 | ✅ | 🎁 **polish** · Extract CCXT.HTTP error-classification and rate-limit shaping into focused modules [D:7/B:5/U:3 → Eff:0.57?] ⚠️ |
| Task 213 | ✅ | 🎁 **polish** · Make full-catalog exchange generation compile cleanly under warnings-as-errors [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 215 | ✅ | 🎁 **polish** · Cache market data for symbol->market_id resolution (loadMarkets equivalent) instead of re-fetching per call [D:5/B:6/U:5 → Eff:1.1?] 📋 |
| Task 447 `[P]` | ✅ | 🎁 **polish** · Reduce the warm offline test suite to at most 60 seconds without losing coverage [D:7/B:9/U:8 → Eff:1.21?] 📋 |
| Task 448 `[P]` | ✅ | 🎁 **polish** · Reduce the full seven-venue fixture-replay gate to at most 60 seconds [D:6/B:9/U:7 → Eff:1.33?] 📋 |
<!-- TASKS:END -->

## Phase 9: Trading Utilities

Higher-level conveniences built on the unified API. Port domain knowledge from `../ccxt_client_bak/`.

<!-- TASKS:BEGIN phase=9 -->
> 6 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-9-trading-utilities).
<!-- TASKS:END -->

## Phase 10: Config Over Inference Migration

Replace heuristics that fail silently with explicit config. Each sub-task can be done independently. Some require ccxt-distill changes (marked upstream); others are ccxt_client-only.

> **Design principle:** When data is finite, verifiable against exchange docs, and fails silently when wrong — configure it, don't infer it. See CLAUDE.md "Config Over Inference" section.

<!-- TASKS:BEGIN phase=10 -->
> 5 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-10-config-over-inference-migration).
<!-- TASKS:END -->

## Phase 11: Upstream-Driven Adaptations

Tasks triggered by upcoming ccxt-distill changes. Two sub-bundles:

- **`upstream_adapt`** — primary adoption of upstream spec contracts (signing recipes, request shape, error taxonomy, rate-limit buckets, currency aliases, descriptors, v4 cut).
- **`deferred_signing`** — consumer-side signing patches deferred pending upstream Phase 9/10/11 contracts. Pick these back up once the relevant upstream bundle lands, or if integration-test evidence (T39) surfaces a correctness blocker that can't wait.

<!-- TASKS:BEGIN phase=11 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 53 | ✅ | 🎁 **upstream_adapt** · Schema 2.0.0 / provenance adapter [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 54 | ✅ | 🎁 **signing_v4** · 🚀 **v0_7_0** · Retire `CCXT.Signing.Classifier` [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 55 | ✅ | 🎁 **v4_adopt** · 🚀 **v0_7_0** · Regenerate unified struct schemas from upstream field maps [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 56 | ✅ | 🎁 **signing_v4** · 🚀 **v0_7_0** · Spec-driven signing pattern modules [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 57 | ✅ | 🎁 **v4_adopt** · 🚀 **v0_7_0** · Adopt request-building contract [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 58 | ✅ | 🎁 **v4_adopt** · 🚀 **v1_0** · Adopt error contract [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 59 | ✅ | 🎁 **trading** · 🚀 **v1_0** · Multi-bucket rate limiter [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 60 | ✅ | 🎁 **trading** · 🚀 **v1_0** · Consume currency aliases + network info [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 61 | ✅ | 🎁 **upstream_adapt** · Testnet/sandbox URL catalog from spec [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task 63 | ✅ | 🎁 **upstream_adapt** · Override contribution workflow [D:1/B:4/U:4 → Eff:4.0?] 🎯 |
| Task 90 | ✅ | 🎁 **upstream_adapt** · Adopt `structure.request_defaults` from upstream Task 73c [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
| Task 91 | ✅ | 🎁 **upstream_adapt** · 🐛 Scope reverse currency-alias application to alias-using exchanges [D:3/B:9/U:9 → Eff:3.0?] 🎯 |
| Task 109 | ✅ | 🎁 **upstream_adapt** · Consume upstream unified-method descriptors in `api()` [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task 117 | ✅ | 🎁 **v4_adopt** · Consume `:transactional` / `:on_chain` endpoint flag [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task v4-adopt | ✅ | 🎁 **v4_adopt** · 🚀 **v0_7_0** · 🐛 Adopt upstream ccxt_extract v4 schema cut [D:4/B:9/U:10 → Eff:2.38?] 🎯 |
| Task 68 | ⛔ | 🎁 **deferred_signing** · HmacSha256Query POST body/URL placement [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 71 | ⛔ | 🎁 **deferred_signing** · Error-classifier override seeding from T67/T40 evidence [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 73 | ⛔ | 🎁 **deferred_signing** · Classifier Tier-2 Bybit misrouting [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 74 | ✅ | 🎁 **signing_v4** · 🚀 **v0_7_0** · Spec-driven timestamp format [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 75 | ⛔ | 🎁 **deferred_signing** · Param insertion-order preservation [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 76 | ⛔ | 🎁 **deferred_signing** · Spec-driven body encoding + extra headers [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 77 | ⛔ | 🎁 **deferred_signing** · Signature encoding audit (base64 vs hex) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 78 | ⛔ | 🎁 **deferred_signing** · Fixture replay CI gate [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task custom-signing-modules | ✅ | 🎁 **signing_v4** · 🚀 **v0_7_0** · Custom signing modules: `CCXT.Signing.Hyperliquid` + `CCXT.Signing.Derive` [D:6/B:8/U:9 → Eff:1.42?] 📋 |
| Task O1 | ⛔ | 🎁 **signing_v4** · ccxt_ocx conformance oracle — wire JS-via-QuickBEAM as byte-equal signing comparator for T39 [D:5/B:9/U:8 → Eff:1.7?] 🚀 |
| Task O2 | ⛔ | 🎁 **upstream_adapt** · Optional ccxt_ocx fallback adapter for tier-3 / long-tail exchanges [D:6/B:6/U:5 → Eff:0.92?] ⚠️ |
| Task 127 | ✅ | 🎁 **upstream_adapt** · 🚀 **v1_0** · Verify currency network metadata population [D:2/B:5/U:6 → Eff:2.75?] 🎯 |
| Task 128 | ⛔ | 🎁 **upstream_adapt** · 🚀 **v1_0** · Own exchange priority/scope locally — stop reading spec exchange.tier from ccxt-distill [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 129 | ✅ | 🎁 **upstream_adapt** · 🚀 **v1_0** · Read handler predicate_limbs for error routing — stop inferring from predicate_raw [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task 130 | ✅ | 🎁 **signing_v4** · 🚀 **v1_0** · Make Recipe.resolve/1 non-raising for the full distill catalog + sign(:unsupported) fallback [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
| Task 131 | ✅ | 🎁 **upstream_adapt** · 🚀 **v1_0** · Cut spec source over to ccxt-distill: vendor all ~110 + consumer-selectable :exchanges (compile_env) [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 132 | ⛔ | 🎁 **signing_v4** · Custom signing modules umbrella (superseded by bounded per-venue tasks) [D:4/B:4/U:3 → Eff:0.88?] ⚠️ |
| Task 133 | ⛔ | 🎁 **signing_v4** · 🚀 **v1_0** · Repoint signing fixtures to ccxt-distill + regenerate (fixture_replay) [D:2/B:4/U:3 → Eff:1.75?] 🚀 |
| Task 134 | ✅ | 🎁 **signing_v4** · 🚀 **v1_0** · *lib/ccxt/signing/recipe.ex* · Degrade null-canonical_string hmac recipes to :unsupported (complete graceful resolve — no sign-time raise) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 135 | ✅ | 🎁 **upstream_adapt** · 🚀 **v1_0** · Push upstream (ccxt-distill): derive canonical_string for the ~60 not_yet_derived exchanges [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 136 | ✅ | 🎁 **v4_adopt** · 🚀 **v1_0** · Consume derived `capabilities` section (has / features / timeframes) [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 137 | ✅ | 🎁 **v4_adopt** · 🚀 **v1_0** · Consume derived `fees` static section (trading + funding defaults) [CRITICAL: money, 95% tier] [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 138 | ✅ | 🎁 **v4_adopt** · 🚀 **v1_0** · Consume derived `config` section (credentials / limits / status / routing / flags + urls doc-set) [D:3/B:3/U:3 → Eff:1.0?] 📋 |
| Task 139 | ✅ | 🎁 **v4_adopt** · HmacRecipe: consume `"*"`-key + conditional `canonical_string` components (4.6.0) [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 140 | ✅ | 🎁 **v4_adopt** · HmacRecipe: consume query-component fidelity (encoder / key_order / replacements) — guard against silently-wrong signatures [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 141 | ✅ | 🎁 **v4_adopt** · Signing tests: derive expected auth-header names from the recipe, not the hardcoded bybit map [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 142 | ✅ | 🎁 **v4_adopt** · Resync to distill 2f7a557 (schema 4.6.0) + re-green signing suite — record newly-resolved count [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 143 | ✅ | 🎁 **signing_v4** · 🚀 **v1_0** · 🐛 HmacRecipe: resolve non-flat sign_recipe shapes — residual signing reds after distill 4.6.0 resync [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 144 | ✅ | 🎁 **parsers** · 🚀 **v1_0** · Wire normalization.field_maps into the unified read path — reads return parsed structs, not raw envelopes [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 146 | ✅ | 🎁 **signing_v4** · 🚀 **v1_0** · Implement CCXT.Signing.Lighter through the signer path selected by task 198 [D:7/B:9/U:9 → Eff:1.29?] 📋 |
| Task 147 | ✅ | 🎁 **signing_v4** · 🚀 **v1_0** · 🐛 Consume 4.12.0 fully-derived recipes the resolver drops to :unsupported — staged_hmac executor + flat-family routing [D:6/B:6/U:5 → Eff:0.92?] ⚠️ |
| Task 152 | ✅ | 🎁 **parsers** · 🚀 **v1_0** · 🐛 Complete unified read-path parsing for fetch_markets / fetch_ticker (consumer) [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 154 | ✅ | 🎁 **v4_adopt** · 🚀 **v1_0** · 🐛 Consume resynced corpus end-to-end for public market data (request shape + response envelopes, extends T57) [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 155 | ⛔ | 🎁 **integration_tests** · Full-catalog public integration evidence doc (superseded by executable gates) [D:2/B:5/U:6 → Eff:2.75?] 🎯 |
| Task 156 | ✅ | 🎁 **integration_tests** · 🚀 **v1_0** · Offline recorded-response replay harness + capture task (green-method fixtures only) [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 157 | ✅ | 🎁 **integration_tests** · 🚀 **v1_0** · Schedule live public and private drift verification for all ten supported venues [D:8/B:9/U:6 → Eff:0.94?] ⚠️ |
| Task 158 | ✅ | 🎁 **integration_tests** · 🚀 **v1_0** · Collapse cred-less private probe fan-out to one flunk per module [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 159 | ✅ | 🎁 **integration_tests** · 🚀 **v1_0** · 🐛 Fix public fetch_order_book probe failures (symbol/param resolution) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 160 | ✅ | 🎁 **integration_tests** · 🚀 **v1_0** · 🐛 🔒 Close the aster testnet -> production-URL leak in integration probes [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 163 | ⛔ | 🎁 **v4_adopt** · 🐛 Audit dynamic_construction/conditional_value request bindings: spec classifier vs consumer-hardcoded recipe [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 164 | ✅ | 🎁 **v4_adopt** · 🐛 Author binance market maker/taker and precision/limits semantics against Binance's own contract [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 165 | ✅ | 🎁 **parsers** · 🐛 Universal post-parse enrichment: derive datetime (ISO8601) + preserve info (raw body) across unified read structs [D:3/B:8/U:7 → Eff:2.5?] 🎯 |
| Task 166 | ✅ | 🎁 **parsers** · 🐛 fetch_markets multi-endpoint fan-out — union markets across all market types (spot + linear + inverse + option) [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 167 | ✅ | 🎁 **parsers** · 🚀 **v0_7_0** · 🐛 Fix inverse-perp market symbol normalization surfaced by fetch_markets fan-out [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 183 | ✅ | 🎁 **integration_tests** · 🚀 **v1_0** · Recalibrate integration-helper: request-malformation 4xx must FAIL, not pass inconclusive [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 198 | ✅ | 🎁 **signing_v4** · Spike: native lighter zk_schnorr signer WITHOUT QuickBEAM (cgo C-lib port vs pure-Rust NIF) [D:6/B:4/U:4 → Eff:0.67?] ⚠️ |
| Task 470 `[P]` | ✅ | 🎁 **signing_v4** · 🐛 Lighter test helper crashes with :epipe on normal Port teardown, polluting every check run [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
<!-- TASKS:END -->

## Phase 12: WebSocket Track (Unnormalized)

Same philosophy as the raw REST surface: pass exchange-native frames through, let consumers parse. No spec-driven WS dispatch — upstream dropped raw `structure.ws_methods` at schema 3.0.0; the equivalent of REST's `sign_method` / `request_defaults` derivation would need upstream WS-extraction work that isn't on the immediate horizon (filed against ccxt-distill — see Current Focus). Format-independent porting from `ccxt_client_bak/lib/ccxt/ws/` is unblocked; 13 exchanges are WS-configured today (all Registry-reachable).

**Why now:**
- `zen_websocket` (5-function client + Deribit heartbeat + reconnection backoff) is already a documented dependency
- Three-layer architecture (helpers → stateless client → stateful adapter) lets us ship Layer 2 first; Layer 3 is mostly provided by zen_websocket already
- Bak has battle-tested domain knowledge: 9 auth pattern modules, 14 subscription pattern modules, ~75 per-exchange modules — ported as the pattern-dispatch layer (`CCXT.WS.Subscription.*` / `CCXT.WS.Auth.*`)

**Out of scope for this track:**
- Message normalization (parsing exchange-native frames into unified `%CCXT.Ticker{}` / `%CCXT.Trade{}` / `%CCXT.OrderBook{}`) — paired with REST unified normalization (T44), gated on T39 evidence + upstream normalization data
- `:custom` DEX WS auth (hyperliquid, derive) — signs action/order payloads rather than HTTP-style frames; covered by their dedicated custom signing modules

This phase carries two bundles: `ws_track` (port + shipped fixes) and `live_triage` (current open probe-gating + cred-refresh work).

<!-- TASKS:BEGIN phase=12 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 92 | ✅ | 🎁 **ws_track** · 📝 WS Layer 1+2 foundation [D:4/B:9/U:9 → Eff:2.25?] 🎯 |
| Task 93 | ✅ | 🎁 **ws_track** · 📝 Port WS auth pattern modules from bak [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 94 | ✅ | 🎁 **ws_track** · 📝 Port WS subscription pattern modules + per-exchange config [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 95 | ✅ | 🎁 **ws_track** · 🐛 Reconcile testnet env var naming (`_TEST_` alias fallback) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 96 | ✅ | 🎁 **ws_track** · 🐛 Register aster testnet creds (prod-key caveat documented) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 97 | ✅ | 🎁 **ws_unified** · Per-exchange channel-name formatters [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 98 | ✅ | 🎁 **ws_track** · 🐛 EventSubscribe dual-shape input contract [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 99 | ✅ | 🎁 **ws_track** · 🐛 MethodParams dual-shape input contract [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 100 | ✅ | 🎁 **ws_track** · 🐛 SubBased strips `id` field to bypass zen_websocket correlator [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 101 | ✅ | 🎁 **ws_track** · 🐛 Fix aster WS public URL (combined-stream `/stream` → dynamic-SUBSCRIBE `/ws`) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 102 | ✅ | 🎁 **ws_track** · 🐛 Remove orphaned `CCXT.WS.Config` entries (bingx / bitget / mexc) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 103 | ✅ | 🎁 **ws_track** · 🐛 Honor `allow_4xx` on `IntegrationHelper` error-branch responses [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 104 | ✅ | 🎁 **ws_track** · 🐛 📝 Fix stale "110 exchange" scope claims in docstrings [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 105 | ✅ | 🎁 **ws_track** · 🚀 **v0_6_1** · Migrate `SymbolResolver` to `runtime.symbols_index` (schema 3.0.0 adoption) [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
| Task 110 | ✅ | 🎁 **ws_track** · 🐛 htx/huobi nested-private probe-gate cascade fix [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 111 | ✅ | 🎁 **live_triage** · 🐛 Bybit raw-public failures — symbol-required + V3-discontinued [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 112 | ✅ | 🎁 **live_triage** · RawEndpointProbe gating — testnet-unavailable + WS-only endpoints [D:4/B:6/U:7 → Eff:1.62?] 🚀 |
| Task 113 | ⛔ | 🎁 **live_triage** · 🐛 Bitfinex invalid-creds classifier emits `:exchange_error` "Unknown error" [D:4/B:4/U:4 → Eff:1.0?] 📋 |
| Task 114 | ✅ | 🎁 **live_triage** · 🐛 WS auth_live_smoke single-test regression triage [D:3/B:3/U:3 → Eff:1.0?] 📋 |
| Task 115 | ⛔ | 🎁 **live_triage** · Refresh expired testnet credentials (superseded by unified credential baseline) [D:2/B:3/U:5 → Eff:2.0?] 🎯 |
| Task 80 | ✅ | 🎁 **ws_track** · Per-section hostname overrides (htx + huobi subset) [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 81 | ✅ | 🎁 **ws_track** · Public-endpoint request-shape diagnosis (priority subset) [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 84 | ✅ | 🎁 **ws_track** · Surface `exchange.tier` on Exchange struct [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 85 | ✅ | 🎁 **ws_track** · `@spec_dir` adopts ccxt_extract's split read/write layout [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 148 | ⛔ | 🎁 **upstream_adapt** · Fix distill staleness hook: compares ccxt-source-sha against distill repo HEAD [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 149 | ✅ | 🎁 **polish** · Extract a typed ParsedSymbol struct for Symbol.parse_extended/1 [D:5/B:3/U:3 → Eff:0.6?] ⚠️ |
| Task 150 | ⛔ | 🎁 **polish** · Extract a typed SymbolPattern struct for Symbol.classify_pattern/2 [D:5/B:3/U:3 → Eff:0.6?] ⚠️ |
| Task 151 | ✅ | 🎁 **polish** · 🚀 **v0_7_0** · 🐛 Replace Emulation.to_method_atom String.to_atom with a validated name-to-atom map [D:3/B:2/U:2 → Eff:0.67?] ⚠️ |
| Task 161 | ✅ | 🎁 **polish** · Wire ex_unit_json flight recorder into process-heavy test modules [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 162 | ✅ | 🎁 **ws_track** · Add regression test pinning aster public WS URL to the dynamic /ws endpoint [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 184 | ✅ | 🎁 **live_triage** · 🚀 **v1_0** · Provision and refresh the seven first-class live testnet credential baselines [D:3/B:7/U:9 → Eff:2.67?] 🎯 |
| Task 185 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Harden unified dispatch opts: extract :params, coerce map-opts — public functions must never raise [D:2/B:8/U:8 → Eff:4.0?] 🎯 |
| Task 186 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Fix response classifier misreading HTTP/JSON-RPC success as :exchange_error (lighter code:200, deribit result-without-error) [D:3/B:8/U:7 → Eff:2.5?] 🎯 |
| Task 187 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Public symbol resolution must not require credentials (fetch_funding_rate et al. force a credentialed market load) [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 188 | ✅ | 🎁 **live_triage** · 🚀 **v1_0** · Codify the COVERAGE.md live sweep as a standing :capability_live per-{venue,method} matrix test [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
| Task 189 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · Wire remaining Tier-1/2/3 parser slots (funding_rate(s), greeks, option_chain) through the read-parse mechanism [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 192 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Bybit emulated fetch_funding_rate: resolve symbol against carved markets (downstream of markets-carve) [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 193 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Author deribit fetch_funding_rate request shape (start_timestamp/end_timestamp required) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 195 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Public fetch_markets carve: every shortlist venue returns symbol-populated [%CCXT.Market{}] (envelope unwrap + symbol backfill) [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 196 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Emulated fetch_ticker must resolve the symbol against the carved markets index (hyperliquid; verify lighter) [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 197 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Author lighter fetch_ticker request shape (sends invalid param, 20001 HTTP 400) [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 199 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 bybit fetch_trades returns %CCXT.Trade{} with nil price/amount/timestamp (regression vs 152/178) [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 200 | ✅ | 🎁 **live_triage** · 🚀 **v0_7_0** · 🐛 Return typed Deribit DVOL volatility history instead of the raw envelope [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 204 | ✅ | 🎁 **ws_track** · 🚀 **v1_0** · Raise WS-layer test coverage to tier (Adapter, MessageRouter, Envelope, Semantics, WS facade) [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 508 | ✅ | 🎁 **polish** · 🐛 Pin reach.check's graded surface so check.dispatch grades the same set cold and warm [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
<!-- TASKS:END -->

## Phase 13: Long-Tail Exchange Bugs (Historical)

Bugs surfaced by exchanges that were outside the brief narrow-scope window (2026-04-15 → 2026-06-16) when only the ~20 priority-tier exchanges compiled. **The full-catalog cutover (Task 131) reversed that narrowing** — these exchanges compile by default again, so the bugs are reproducible in the default build. All three were resolved as part of the shared construction/dispatch/signing paths and are now superseded; this section is retained for lineage.

<!-- TASKS:BEGIN phase=13 -->
> 3 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-13-tier3-dormant-reactivation-on-demand).
<!-- TASKS:END -->

## Phase 14: Authored Specs — First-Class Venue Confrontation

The authored-specs pivot workstream (see [docs/authored-specs.md](docs/authored-specs.md)): T-A venue authoring/confrontation slices, fixture-gate closures, schema v-next, and the retirement of the legacy heuristic layers.

<!-- TASKS:BEGIN phase=14 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 153 | ✅ | 🎁 **authored_specs** · 🚀 **v0_7_0** · 🐛 Implement + wire the order_book read path (transformer + %CCXT.OrderBook{} struct + sort invariants) [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 168 | ✅ | 🎁 **authored_specs** · T-A: Differential fixture gate (REST request + response) against in-repo CCXT static fixtures [D:3/B:8/U:8 → Eff:2.67?] 🎯 |
| Task 169 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-B: Own the spec schema as a versioned compile-time contract (decouple from distill; split authored slice from frozen bulk) [D:6/B:8/U:9 → Eff:1.42?] 📋 |
| Task 170 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-C: Author, verify, and freeze Deribit as the proof venue [D:5/B:8/U:9 → Eff:1.7?] 🚀 |
| Task 171 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-D/Bybit: Author, verify, and freeze the Bybit spec [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 172 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-E1: Remove distill sync + staleness tooling [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 173 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Cut runtime support to ten complete authored venues and demote CCXT to reference-only [D:9/B:10/U:10 → Eff:1.11?] 📋 |
| Task 174 | ⛔ | 🎁 **authored_specs** · 🚀 **v1_0** · T-F: Reconcile repository doctrine after authored specs and the Bourse rename [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 175 | ⛔ | 🎁 **authored_specs** · T-G: WS authored slices + cassette harness (DEFERRED) [D:5/B:5/U:3 → Eff:0.8?] ⚠️ |
| Task 176 | ⛔ | 🎁 **authored_specs** · 🚀 **v1_0** · 📝 T-E3 doctrine sweep (superseded by task 174) [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 177 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Execute vendored CCXT-JS as the tier-2 oracle for unfixtured methods [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 178 | ✅ | 🎁 **authored_specs** · Read-parse path: faithfully reproduce CCXT parse* for first-class public-read (nested keys, computed scalars, Tier-1/2/3 coverage, columnar OHLCV) [D:5/B:7/U:8 → Eff:1.5?] 🚀 |
| Task 179 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Harden the T-A fixture gate against global CircuitBreaker / rate-limiter contamination [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 180 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Tier-1 (reality-anchored) semantic oracle for CCXT-divergence-prone fields [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 181 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Make the unified schema reality-answerable: confront CCXT-inherited carves against exchange semantics; register divergences [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 182 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Rename project away from ccxt_client / CCXT.* namespace [D:7/B:7/U:5 → Eff:0.86?] ⚠️ |
| Task 190 | ✅ | 🎁 **authored_specs** · 🚀 **v0_7_0** · 🐛 Author bybit V5 request shape: inject category + map fetch_ohlcv timeframe to interval [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 191 | ✅ | 🎁 **authored_specs** · 🚀 **v0_7_0** · 🐛 Author hyperliquid /info POST request body (fetch_markets + fetch_ticker send malformed body, HTTP 400) [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 194 | ✅ | 🎁 **authored_specs** · 🚀 **v0_7_0** · 🐛 Make static request fixture replay deterministic for dynamic request-shape clocks [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 206 | ⛔ | 🎁 **authored_specs** · Authored read/WS slots umbrella (folded into schema and venue tasks) [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 207 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-D/Binance family: Author, verify, and freeze Binance spot + USD-M specs [D:5/B:9/U:9 → Eff:1.8?] 🚀 |
| Task 208 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-D/OKX: Author, verify, and freeze the OKX spec [D:4/B:8/U:7 → Eff:1.88?] 🚀 |
| Task 209 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-D/Hyperliquid: Author, verify, and freeze the Hyperliquid spec [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 210 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-D/Derive: Author, verify, and freeze the Derive spec [D:4/B:8/U:7 → Eff:1.88?] 🚀 |
| Task 211 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Wire tier-2 CCXT-JS oracle output into task-168 differential gate for fetchMarkets [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 212 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Wire OKX demo-trading transport: EEA hostname + x-simulated-trading header via sandbox flag [D:4/B:8/U:7 → Eff:1.88?] 🚀 |
| Task 214 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Default OKX sandbox hostname to EEA demo host (avoid literal {hostname}) [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 216 | ✅ | 🎁 **authored_specs** · 🚀 **v0_7_0** · 🐛 Author hyperliquid account-read /info bodies: inject credential-derived `user` param [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 217 | ✅ | 🎁 **authored_specs** · 🚀 **v0_7_0** · 🐛 Preserve canonical uppercase currency keys in parsed Balance maps [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 218 | ✅ | 🎁 **authored_specs** · 🚀 **v0_7_0** · 🐛 Author remaining hyperliquid /info account-read `user` bindings (source: api_key) [D:2/B:6/U:5 → Eff:2.75?] 🎯 |
| Task 219 | ✅ | 🎁 **authored_specs** · 🐛 Register hyperliquid fetch_trades divergence (:not_supported) + author fetch_my_trades userFills/userFillsByTime [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 220 | ✅ | 🎁 **authored_specs** · T-A/Deribit: author venue-wide request-builds (fetchOHLCV computed timestamps as anchor case) [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 221 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Audit + extend CCXT.StructValidators against CCXT's Exchange/test.*.ts invariant catalog [D:4/B:7/U:8 → Eff:1.88?] 🚀 |
| Task 222 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Machine-readable divergence contracts: fixture gates consume the carve register as expected-diff assertions, not skip-keys [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 223 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/Bybit: land accumulated response work; author ticker + OHLCV semantics [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 224 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/OKX: final human convergence audit after all request/response closures [D:3/B:8/U:7 → Eff:2.5?] 🎯 |
| Task 225 | ✅ | 🎁 **authored_specs** · Hyperliquid: close the blocked live signed-success + fill-parse verification [D:2/B:7/U:7 → Eff:3.5?] 🎯 |
| Task 226 `[P]` | ⛔ | 🎁 **authored_specs** · 🚀 **v1_0** · Hyperliquid: live-tier fill for fetch_my_trades parse (wallet registration / EIP-712 order) [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task 227 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-D/Binance family: author market type/boolean flags (spot/swap/contract/active/linear/inverse/settle) [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 228 | ✅ | 🎁 **polish** · 🚀 **v1_0** · Refresh ROADMAP.md prose after distill-sync removal [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 229 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/Bybit: author venue-wide request-builds (close the signing_fixture_replay gate) [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 230 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/Bybit: author positions + openInterest response slices [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 231 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/Bybit: author trades/myTrades/ledger/transfers/currencies response slices [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 232 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/Bybit: author funding response slices (rate/rates/rateHistory/history) [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 233 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-D/Bybit: preserve market identity and author venue-native type flags [D:4/B:8/U:7 → Eff:1.88?] 🚀 |
| Task 234 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/Bybit: author order-lifecycle response slices [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 235 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/Bybit: author remaining account/analytics responses and close the venue-wide response gate [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 236 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-D/Deribit: dated-instrument market identity — symbols must encode expiry/strike (1007-way collision), future flag, expiry_datetime, option-chain keys [D:4/B:9/U:8 → Eff:2.12?] 🎯 |
| Task 237 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Deribit: author unresolved currency request-shape references (withdraw / fetchTradingFees / fetchTransfers) + trading-fees default code [D:2/B:7/U:6 → Eff:3.25?] 🎯 |
| Task 238 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Deribit: author missing response slices — greeks (nested object), transaction fields, funding-rate interval, tickers map [D:3/B:8/U:6 → Eff:2.33?] 🎯 |
| Task 239 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Wire missing unified parser slots: fetch_accounts / fetch_time / fetch_option return raw HTTP envelopes [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 240 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Array-valued query params crash request building (URI.encode_query) on both the public and signed GET paths [D:3/B:8/U:7 → Eff:2.5?] 🎯 |
| Task 241 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Balance used-reconciliation clobbers parsed values (negative used; maintenance_margin overwritten by total - free) [D:2/B:8/U:6 → Eff:3.5?] 🎯 |
| Task 242 | ✅ | 🎁 **authored_specs** · Register retired/misclassified endpoints surfaced by live sweeps (deribit, bybit, okx rows) [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 243 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Unified reads must honor request market context — single-record data[0] unwrap + request-symbol authority over native-id guesses [D:4/B:8/U:6 → Eff:1.75?] 🚀 |
| Task 244 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Raise ReadParse financial-parser coverage and remove the bare decimal rescue [D:4/B:7/U:5 → Eff:1.5?] 🚀 |
| Task 245 | ✅ | 🎁 **authored_specs** · Complete Bybit live order-lifecycle evidence once trade-permission testnet key is provisioned [D:1/B:6/U:6 → Eff:6.0?] 🎯 |
| Task 246 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Bybit account/analytics request builds must survive default call shapes (nil since crash, missing greeks baseCoin) [D:2/B:7/U:5 → Eff:3.0?] 🎯 |
| Task 247 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Bybit request gate: close the 2 unexplained reds task 229 left open (fetchOption symbol suffix, fetchPositionADLRank category) [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 248 | ✅ | 🎁 **authored_specs** · Request-symbol authority is Trade-only — other single-symbol reads still let a native-id guess win [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 249 | ✅ | 🎁 **authored_specs** · 🐛 Bybit option ids: Symbol.to_exchange_id emits a phantom -USDC suffix Bybit never lists [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 250 | ⛔ | 🎁 **authored_specs** · Bybit testnet key cannot trade (retCode 10024) — live non-empty open-order evidence is unobtainable [D:2/B:5/U:6 → Eff:2.75?] 🎯 |
| Task 251 | ✅ | 🎁 **authored_specs** · 🐛 bybit fetch_markets omits the option category — unified option reads have no symbol index [D:3/B:7/U:5 → Eff:2.0?] 🎯 |
| Task 252 | ✅ | 🎁 **authored_specs** · 🐛 Honor the caller-supplied :base_url dispatch opt on public and signed paths [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 253 | ✅ | 🎁 **authored_specs** · 🐛 Bybit unified reads drop all rows: native symbol never resolved back to unified form, then the requested-symbol filter discards everything [D:5/B:9/U:7 → Eff:1.6?] 🚀 |
| Task 254 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Bybit: author the legacy query-param HMAC signing recipe (legacy_else falsified — 15 live endpoints unreachable) [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 255 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 HTTP error/success-body robustness: scalar error keys crash the classifier, legit empty-200 rejected, batch and non-JSON error detail dropped [D:3/B:8/U:7 → Eff:2.5?] 🎯 |
| Task 256 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Read-parse fail-loud invariant: empty collections are success, all-nil parses are errors, lists never collapse into one struct [D:4/B:8/U:7 → Eff:1.88?] 🚀 |
| Task 257 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/OKX: author venue-wide unified request-builds (instType fan-out, param defaults and mappings, transfer account ids) [D:5/B:8/U:7 → Eff:1.5?] 🚀 |
| Task 258 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/OKX: author response slices — kill raw-envelope leaks, wire computed ticker fields, register the sandbox fetch_currencies carve [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 259 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Confront unified positional-arg divergences from CCXT: add_margin/reduce_margin arg order, create_convert_trade missing quote id [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 260 | ✅ | 🎁 **authored_specs** · 🐛 Thread the effective host into signing config for host-signing venues (htx/huobi/bittrade) [D:4/B:5/U:4 → Eff:1.12?] 📋 |
| Task 261 | ✅ | 🎁 **authored_specs** · 🐛 bybit fetch_markets option index truncates at 500 rows per baseCoin — venue cursor says there is more [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 262 | ✅ | 🎁 **authored_specs** · 🐛 filter_requested_symbols raises KeyError on symbol-less structs (Transaction/LedgerEntry/TransferEntry/DepositAddress) [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 263 | ✅ | 🎁 **authored_specs** · 🐛 Confront Bybit fetchOpenOrders exclusion from the order pagination-cursor merge list [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 264 | ⛔ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Balance reconciliation derives only `used` — safeBalance fills whichever of free/used/total is missing [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 265 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Balance field-map cannot express CCXT's per-currency used/free branch (okx availEq, bybit availableToWithdraw) [D:5/B:5/U:4 → Eff:0.9?] ⚠️ |
| Task 266 | ✅ | 🎁 **authored_specs** · 🐛 Bybit legacy signing: decide auth-param precedence vs caller params (CCXT extend semantics) [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 267 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A: final human audit for unresolved identifier_reference params across first-class venues [D:2/B:7/U:7 → Eff:3.5?] 🎯 |
| Task 268 | ✅ | 🎁 **authored_specs** · 🐛 Pre-existing red: deribit fetchClosedOrders 'spot closed order' recorded-response fixture returns a different order than its golden [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 269 | ✅ | 🎁 **authored_specs** · T-A/OKX: fetch_markets option wave — per-underlying fan-out over public/underlying [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 270 | ✅ | 🎁 **authored_specs** · T-A/OKX: option symbols classify as :option_unknown — instId drops the quote [D:5/B:6/U:6 → Eff:1.2?] 📋 |
| Task 271 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Pin the remaining first-class GET array dialects: Deribit brackets and Binance JSON [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 272 | ✅ | 🎁 **authored_specs** · 📝 OKX: move task-257 request defaults from full vendored okx.json into authored/okx.json [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 273 | ✅ | 🎁 **authored_specs** · 🐛 T-A/OKX: fetch_greeks must select the requested instId row from public/opt-summary [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 274 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Binance: option symbol pattern is entirely unpopulated — denormalization is a silent no-op [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 275 | ⛔ | 🎁 **authored_specs** · 🐛 T-A/OKX: fetch_greeks parses to an all-nil struct — requested instId's row never selected from the family-wide opt-summary list [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 276 | ✅ | 🎁 **authored_specs** · 🐛 Carve register ids collide and dangle — make carve_id a checked namespace, not a hand-typed number [D:3/B:4/U:5 → Eff:1.5?] 🚀 |
| Task 277 | ✅ | 🎁 **authored_specs** · T-A/OKX: close the two remaining response-slice fixture gaps — fetchCurrencies per-chain grouping, Account carve [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 278 | ✅ | 🎁 **authored_specs** · T-A/OKX: fetchBorrowInterest raises unresolved identifier_reference for mgnMode before reaching the wire [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 279 | ✅ | 🎁 **authored_specs** · Carve: confront swap/inverse ticker vwap against venue semantics — CCXT's quoteVolume/baseVolume yields contract size, not a price [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 280 | ✅ | 🎁 **authored_specs** · 📝 Pretty-print authored/okx.json to match the other six authored slices [D:1/B:3/U:3 → Eff:3.0?] 🎯 |
| Task 281 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Deribit: order-mutation responses parse to id: nil — result.order envelope never unwrapped (create/edit/cancel unusable programmatically) [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 282 | ✅ | 🎁 **authored_specs** · 🐛 T-A/OKX: author the greeks response envelope — fetch_all_greeks parses the raw opt-summary envelope [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 283 | ✅ | 🎁 **authored_specs** · 🐛 Author htx/huobi/bittrade private query auth params (AccessKeyId/SignatureMethod/SignatureVersion/Timestamp) [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 284 | ✅ | 🎁 **authored_specs** · 🐛 htx contract.private and spot.private endpoints are never signed (authenticated: false) [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 285 | ✅ | 🎁 **authored_specs** · 🐛 bybit leverage margin_mode is nil live — field map reads a marginMode key bybit never sends [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 286 | ✅ | 🎁 **authored_specs** · 🐛 Confront canonical query encoder space encoding (+ vs %20) against venue signing docs [D:5/B:5/U:5 → Eff:1.0?] 📋 |
| Task 287 | ✅ | 🎁 **authored_specs** · 🐛 T-D/Deribit: USDC-book id grammar — 3040 markets keep raw instrument_name as unified symbol (BASE_QUOTE-DDMMMYY, d-decimal strikes) [D:4/B:8/U:7 → Eff:1.88?] 🚀 |
| Task 288 | ⛔ | 🎁 **authored_specs** · 🐛 Deribit USDC linear dated instruments — underscore id grammar for futures/options [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 289 | ⛔ | 🎁 **authored_specs** · 🐛 T-A/OKX: author the fetchTransfers response field map for the bills row shape (ccy/balChg/from/to) [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 290 | ✅ | 🎁 **authored_specs** · 🐛 Bybit recorded-response gate: adjudicate the 23 standing reds — expected-diff registrations or fixes (category-in-info, int-vs-float goldens, funding interval nil) [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 291 | ✅ | 🎁 **authored_specs** · 🐛 Dead authenticated_sections entries designate no endpoint in 5 catalog specs [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 292 | ✅ | 🎁 **authored_specs** · 🐛 Private sections with NO authored authenticated_sections entry dispatch unsigned (kucoin utaPrivate, coinspot v2.private) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 293 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Binance family: author the order/position/balance response slices — venue response gates stand at 60 (binance) + 30 (binanceusdm) reds [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 294 | ⛔ | 🎁 **authored_specs** · 🐛 Sandbox-aware fetch_markets fan-out: waves for sections absent on the venue testnet 404 the whole call (binance margin/allPairs) [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 295 | ✅ | 🎁 **authored_specs** · 🐛 T-A/OKX: confront the greeks carve — coin-margined delta/gamma/vega/theta vs Black-Scholes *BS fields [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 296 | ✅ | 🎁 **authored_specs** · 🐛 Binance family: unblock the live order lifecycle — binanceusdm fetch_markets routes to the coin-margined path, and side is not uppercased [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 297 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Binance family: finish the residual response-slice reds — gates stand at 48 (binance) + 14 (binanceusdm) after task 293 [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 298 | ✅ | 🎁 **authored_specs** · 🐛 Base-URL resolution silently rides an arbitrary host when a section has no sandbox URL [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 299 | ✅ | 🎁 **authored_specs** · 🐛 T-D/Deribit: combo instruments still pass through raw instrument_name symbols [D:4/B:4/U:4 → Eff:1.0?] 📋 |
| Task 300 | ✅ | 🎁 **authored_specs** · 🐛 T-D/Deribit: linear USDC perpetual swaps use base settle in unified symbols instead of USDC [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 301 | ⛔ | 🎁 **authored_specs** · 🐛 T-D/Deribit: to_exchange_id raises FunctionClauseError on REV (reversal) combo symbols instead of failing gracefully [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 302 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Hyperliquid: author the ~30 missing response field-map slices — the gate is 1/33 with no shared root cause [D:8/B:6/U:5 → Eff:0.69?] ⚠️ |
| Task 303 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Derive: close the recorded-response gate — 14 reds incl. fetchFundingRate parsing to an all-nil struct [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 304 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Schema v-next: replace the seven overlays with complete owned runtime specs [D:8/B:10/U:9 → Eff:1.19?] 📋 |
| Task 305 | ✅ | 🎁 **authored_specs** · 🐛 Symbol.from_exchange_id/3 silently corrupts Deribit combo ids instead of failing loudly [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 306 | ✅ | 🎁 **authored_specs** · T-A/Bybit: close the residual unified reds from the 2026-07-17 convergence re-run (endpoint routing, leverage tiers, pagination, liquidations parser) [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 307 | ✅ | 🎁 **authored_specs** · 🐛 Balance availability branches (okx availEq, bybit availableToWithdraw) are authored but never confronted against a live row [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 308 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Author OKX convert request-build so the quote id reaches the wire [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 309 | ✅ | 🎁 **authored_specs** · Confront set_margin arg order against its now-aligned add_margin/reduce_margin siblings [D:1/B:4/U:5 → Eff:4.5?] 🎯 |
| Task 310 | ✅ | 🎁 **authored_specs** · A bare positional CCXT accepts must never crash with an opts TypeError (fetch_order_book depth, adl_rank symbols, orders_classic symbol) [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 311 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/OKX: confront the currency-level fee/precision rollup semantics against a tier-1 oracle [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 312 | ✅ | 🎁 **authored_specs** · Bybit request shapes: positional `params` slot read as a symbol crashes with FunctionClauseError [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 313 | ✅ | 🎁 **authored_specs** · Bybit request shapes: non-symbol positional `params` slots silently build a map-valued query param [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 314 | ✅ | 🎁 **authored_specs** · 🐛 Carve ids still collide and dangle after 276: allocate them mechanically and check every reference [D:3/B:4/U:5 → Eff:1.5?] 🚀 |
| Task 315 | ✅ | 🎁 **authored_specs** · Apply carve C36 to bybit inverse ticker vwap — blind turnover24h/volume24h publishes 1.56e-05 as a price [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 316 | ✅ | 🎁 **authored_specs** · Derive position: carve-confront realized_pnl / cumulative_funding that CCXT drops [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 317 | ✅ | 🎁 **authored_specs** · Derive request shapes: the unified symbol never reaches the wire as instrument_name [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 318 | ✅ | 🎁 **authored_specs** · 🐛 T-A replay harness: load the CCXT static markets/currencies caches the response oracle itself used [D:6/B:9/U:8 → Eff:1.42?] 📋 |
| Task 319 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Binance: author the fetchCurrencies slice — binance has no `currency` field map at all [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 320 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Binance: author batch-order request building — createOrders/editOrders `batchOrders` is a JSON-encoded query param, not a JSON body [D:6/B:7/U:6 → Eff:1.08?] 📋 |
| Task 321 | ✅ | 🎁 **authored_specs** · 🐛 T-A/BinanceUSDM: finish the 5 residual reds — papi funding-history, margin-adjustment envelope, GTX post_only, papi order last_trade_timestamp, fetchPositionADLRank [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 322 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Binance: carve-confront the fetchPositions family, transaction slices and spot order reads against Binance's own semantics [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 323 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Binance spot: close fetchBorrowInterest, fetchAllGreeks and fetchConvertQuote response clusters [D:6/B:7/U:6 → Eff:1.08?] 📋 |
| Task 324 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Replay exchange :markets carries raw CCXT maps, violating the [CCXT.Market.t()] contract [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 325 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Remove the eight vestigial Bybit positional `params` fallbacks [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 326 | ✅ | 🎁 **authored_specs** · Gate the T-A fixture-replay suite against a frozen failing-name baseline [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 327 | 🔶 | 🎁 **authored_specs** · Work the prod-verification ledger: close deferred tier-1 confirmations with prod keys / real market state [D:3/B:6/U:4 → Eff:1.67?] 🚀 ⛔ Live session 2026-07-23 closed Binance task 319, Binance USD-M task 321, and the obsolete OKX EEA follow-up for task 364; every remaining OKX probe is routed to the international entity. Remaining ledger entries require one or more of: populated account state, an OKX international production read key, usable sandbox liquidity, or explicit approval for a venue-final mutation. |
| Task 328 | ✅ | 🎁 **authored_specs** · 🐛 hyperliquid response-gate: 2 transfer cases fail on a request-side signing precondition, unreachable from any response-scoped task [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 329 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Confront carve C36 for bybit OPTION ticker vwap — publishes ~63883 next to a premium last of 5 [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 330 | ⛔ | 🎁 **authored_specs** · 🐛 hyperliquid transfer: successful ack parses to an all-nil TransferEntry and surfaces as {:error, ...} [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 331 | ✅ | 🎁 **authored_specs** · 🐛 hyperliquid transfer path end-to-end: request builder constructs :action (9 signing reds) + successful-ack carve returns {:ok, ...} [D:6/B:6/U:6 → Eff:1.0?] 📋 |
| Task 332 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Binance: batch-order builder only encodes limit orders — market/stop elements raise KeyError on price [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 333 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Fix Hyperliquid candleSnapshot request values: universe coin and nested-only params [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 334 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Binance family: confront fetchPositions value axes against a tier-1 oracle [D:7/B:8/U:6 → Eff:1.0?] 📋 |
| Task 335 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Binance: author the transaction slice -- fetchDeposits / fetchWithdrawals / withdraw parse per Binance's own field semantics [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 336 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Binance: close the spot order reads (fetchOrder / fetchOrders) and pin the sparse mutation-ACK shape [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 337 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Binance: batch-order builder silently drops every optional element field (reduceOnly, closePosition, positionSide, workingType, activationPrice) [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 338 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Fix Hyperliquid L1 msgpack action field ordering [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 339 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Populate an explicit Hyperliquid market asset_index from live meta ordering [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 340 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Unified endpoint selection ignores params symbols (plural) — binance fetch_tickers routes to COIN-M dapi [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 341 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Close Binance-family unresolved identifier request mappings [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 342 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Close OKX non-convert unresolved identifier request mappings [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 343 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Close Bybit non-convert unresolved identifier request mappings [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 344 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Close Deribit unresolved identifier request mappings [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 345 | ⛔ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Close Derive unresolved identifier request mappings [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 346 | ⛔ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Close Hyperliquid non-action unresolved identifier request mappings [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 347 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Author Bybit convert quoteTxId request binding [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 348 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Hyperliquid l2Book: parse levels objects into OrderBook bids/asks [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 349 | 🔶 | 🎁 **authored_specs** · 🐛 Determine and carve Binance sapi asset/dust encoding from authoritative evidence [D:3/B:5/U:4 → Eff:1.5?] 🚀 ⛔ Never dispatched (0 attempts, no harness branch, no commits) — the reason field previously carried a foreign run's note about Credo depth findings in lib/ccxt/circuit_breaker.ex; that WIP is gone and credo --strict on that file is clean, so it was never this task's blocker. The real blocker is the one in the body: the sapi dust wire contract is not safely observable. Confirmed live 2026-07-25 while working task 450 — the production MAIN key is spot-only (accountType SPOT, permissions TRD_GRP_002/TRD_GRP_077) and returns -2015 on every /fapi and /dapi path, SUB1 is IP-whitelisted (-2015 even on spot), and spot testnet does not expose the sapi dust endpoint at all. The MAIN key may technically reach sapi on spot, and the wallet does hold dust, but a valid dust conversion is an IRREVERSIBLE mutation on a live-money account: unblock only with explicit operator approval for a controlled minimal conversion, an official SDK capture, or observed signed production traffic. |
| Task 350 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Make the fixture-replay ratchet enforce shrink: gate fails when frozen baseline names now pass [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 351 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Thread exchange-level sandbox into signing: hyperliquid signs mainnet phantom source against testnet when only Exchange.new gets sandbox: true [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 352 | ✅ | 🎁 **authored_specs** · Hyperliquid createOrders response parse yields an all-nil Order for a filled order [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 353 | ✅ | 🎁 **authored_specs** · Hyperliquid order size/price string passthrough breaks the L1 signature (non-canonical wire format) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 354 | ✅ | 🎁 **authored_specs** · Hyperliquid singular createOrder sends an unshaped body — wire it through the authored L1 order action build [D:2/B:6/U:5 → Eff:2.75?] 🎯 |
| Task 355 | ✅ | 🎁 **authored_specs** · Hyperliquid cancelOrder/cancelOrders response parse wraps venue outcomes as all-nil errors [D:2/B:6/U:5 → Eff:2.75?] 🎯 |
| Task 356 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Binance spot multi-row reads key rows with perp-style symbols — requested unified symbols unfindable in fetch_tickers [D:5/B:8/U:7 → Eff:1.5?] 🚀 |
| Task 357 | ✅ | 🎁 **authored_specs** · 🐛 OKX cancelOrder selects trade/cancel-algos ahead of trade/cancel-order [D:2/B:5/U:6 → Eff:2.75?] 🎯 |
| Task 358 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Unified write/action methods leak the HTTP transport envelope — return the venue body or the CCXT-defined struct [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 359 | ✅ | 🎁 **authored_specs** · 🐛 OKX cancelOrders / cancelOrdersForSymbols select cancel-algos ahead of cancel-batch [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 360 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Replace retired Bybit cross-borrow-rate endpoint with a live V5 capability [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 361 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author normal and batch order request semantics [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 387 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author algo, TP/SL, trigger and trailing-order request semantics [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 388 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author OHLCV, status, open-interest and funding-history response semantics [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 389 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author deposit-address and network collection response semantics [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 362 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author non-order account and conversion request semantics [D:6/B:7/U:6 → Eff:1.08?] 📋 |
| Task 363 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author order, fill and sparse action-response semantics [D:6/B:7/U:6 → Eff:1.08?] 📋 |
| Task 364 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: confront position response semantics [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 365 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author ledger, transfer and account response semantics [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 366 | ✅ | 🎁 **authored_specs** · 🐛 binanceusdm COIN-M inverse multi-row fetch_tickers mis-keys unified symbols (regression since task 340) [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 367 | ✅ | 🎁 **authored_specs** · 🐛 binanceusdm fetch_tickers ignores the symbols filter — returns the full catalog [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 368 | ✅ | 🎁 **authored_specs** · 🐛 binanceusdm no-arg fetch_tickers routes to COIN-M dapi — linear fapi must be the default family [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 369 | ✅ | 🎁 **authored_specs** · Zero-param POST sends no HTTP body — JSON-RPC venues reject with -32700 where ccxt-js sends {} [D:3/B:8/U:7 → Eff:2.5?] 🎯 |
| Task 370 | ✅ | 🎁 **authored_specs** · T-A/Hyperliquid: author the live-red unified READ slices — markets/tickers/funding_rates/ledger field maps, spot/swap backfill crash, currency slice, unknownOid sentinel [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 371 | ✅ | 🎁 **authored_specs** · T-A/Hyperliquid: wire the unified WRITE/margin request builds — addMargin/reduceMargin/createTwapOrder actions, closed/canceled-order wrapper delegation, withdraw identifier [D:5/B:7/U:5 → Eff:1.2?] 📋 |
| Task 372 | ✅ | 🎁 **authored_specs** · T-A/Derive: author the live-red unified slices — fetch_markets fan-out defaults, open/closed-orders parse handlers, market classification fields, spot/option symbol carves [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 373 | ✅ | 🎁 **authored_specs** · 🐛 binanceusdm no-arg reads beyond fetch_tickers still fall through to the COIN-M dapi hd(configs) [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 374 | ✅ | 🎁 **authored_specs** · Determine zero-param JSON body semantics across gated signing venues [D:5/B:5/U:4 → Eff:0.9?] ⚠️ |
| Task 375 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Fail loudly on duplicate keys in every JSON document consumed by CCXT.Spec [D:3/B:8/U:5 → Eff:2.17?] 🎯 |
| Task 376 | ✅ | 🎁 **authored_specs** · 🐛 Audit and implement safeTimestamp coercion across the current catalog [D:8/B:8/U:7 → Eff:0.94?] ⚠️ |
| Task 377 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Normalize Binance-family multi-row result keys across inverse and dated families [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 378 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Authored per-venue default-family spec slot — retire the venue-local hd(configs) clauses in CCXT.Unified [D:7/B:9/U:8 → Eff:1.21?] 📋 |
| Task 379 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Derive unified write path builds a malformed order request: instrument name lands in order_type [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 380 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Deribit: author fetchTradingFees + fetchDepositAddress parse slices (raw envelope leaks) [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 381 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/Binance: confront the order values CCXT invents rather than copies (workingTime -1 clock, sparse-ACK filled padding) [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 382 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 OKX order/fill/ack response fixtures: close the residual reds left open by task 363 [D:6/B:7/U:7 → Eff:1.17?] 📋 |
| Task 383 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Fix the obsolete contiguous asset_index assertion in the Hyperliquid live test [D:1/B:4/U:3 → Eff:3.5?] 🎯 |
| Task 384 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Hyperliquid withdraw ignores the vaultAddress branch — CCXT routes it to a vaultTransfer action [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 385 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author the remaining unified request builds — createOrder/editOrder endpoint selection + body mapping, fetchMyTrades fills routing [D:5/B:9/U:9 → Eff:1.8?] 🚀 |
| Task 386 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Validate authored request-source contracts and repair known unresolved bindings [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 390 | ✅ | 🎁 **authored_specs** · 🐛 Binance spot multi-row reads key non-USDT-quote rows with raw exchange ids [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 391 | ✅ | 🎁 **authored_specs** · 🐛 Fixture-replay baseline cannot distinguish a deliberate CCXT divergence from an open defect [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 392 | ✅ | 🎁 **authored_specs** · 🐛 Extend duplicate-key rejection to the JsonLoader-backed extractor documents [D:2/B:6/U:5 → Eff:2.75?] 🎯 |
| Task 393 | ✅ | 🎁 **authored_specs** · 🐛 Assert catalog-wide that every coercion-tagged field rule resolves to a non-passthrough parser branch [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 394 | ✅ | 🎁 **authored_specs** · 🐛 T-A/OKX: apply market precision to createOrder/editOrder sz/px (lotSz/tickSz), matching bybit's builder-aware sibling [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 395 | ✅ | 🎁 **authored_specs** · 🐛 binancecoinm cancelAllOrders still fabricates a phantom order from the venue ack envelope [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 410 | ✅ | 🎁 **authored_specs** · 🐛 Route the recorded-fixture JSON reads through the strict duplicate-key decoder [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 411 | ✅ | 🎁 **authored_specs** · 🐛 Reach CCXT.Order.Sanity from the unified create/edit dispatch path (currently dead code) [D:5/B:6/U:5 → Eff:1.1?] 📋 |
| Task 412 | ✅ | 🎁 **authored_specs** · 🐛 Implement or retire the ten catalog coercion tags that fall through to the response-parser passthrough branch [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 413 | ✅ | 🎁 **authored_specs** · 🐛 Make the iso8601 coercion honour its declared seconds resolution [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 414 | ✅ | 🎁 **authored_specs** · 🐛 Binance fetch_tickers refetches the whole markets fan-out on every call when markets are unloaded [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 415 | ✅ | 🎁 **authored_specs** · 🐛 binancecoinm fetch_markets returns four all-nil market structs instead of the dapi instrument set [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 416 | ✅ | 🎁 **authored_specs** · 🐛 Derive private reads/cancels must default subaccount_id from exchange-level config instead of raising per call [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 417 | ✅ | 🎁 **authored_specs** · 🐛 Hyperliquid action methods declare signer-owned natives (nonce/signature) as identifier_reference request slots [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 418 | ✅ | 🎁 **authored_specs** · 🐛 Binance family: resolve or retire the dormant futuresTransfer/verifyGiftCode identifier slots [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 419 | ✅ | 🎁 **authored_specs** · 🐛 Retag deepcoin CreateTime and whitebit fundingTime safeTimestamp rules from ms to s [D:1/B:3/U:4 → Eff:3.5?] 🎯 |
| Task 420 | ✅ | 🎁 **authored_specs** · 🐛 Retire static describe-member coercions from response field maps [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 421 | ✅ | 🎁 **authored_specs** · 🐛 Recover unified network codes from the live currency catalog before falling back to the frozen alias table [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 422 | ✅ | 🎁 **authored_specs** · 🐛 Replace inert flunk-inside-Req.Test-stub guards with assertions that survive the HTTP rescue [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 423 | ✅ | 🎁 **authored_specs** · 🐛 Author the missing derive request shapes so unshaped private methods stop bypassing the subaccount_id default [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 424 | ✅ | 🎁 **authored_specs** · 🐛 Guard the catalog against field-map keys that read exchange instance state [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 425 | ✅ | 🎁 **authored_specs** · 🐛 Convert remaining inert ExUnit assertions inside Req.Test plug callbacks to cross-process collectors [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 426 | ✅ | 🎁 **authored_specs** · 🐛 Port networkIdToCode so catalog-resolved chains emit unified network codes, not raw network ids [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 427 | ✅ | 🎁 **authored_specs** · 🐛 T-A/OKX: author the trading-fee response slice (live all-nil struct on /api/v5/account/trade-fee) [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 428 | ✅ | 🎁 **authored_specs** · Author Alpaca primary-market TradFi data slices (stocks bars/quotes/snapshots, news, forex rates) [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 429 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Promote Alpaca as a complete authored public/private venue [D:7/B:9/U:9 → Eff:1.29?] 📋 |
| Task 430 | ✅ | 🎁 **authored_specs** · 🐛 Align vendored CCXT fixture vintages so the currencies cache and response oracle agree [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 431 | ✅ | 🎁 **authored_specs** · 🐛 Flatten transform-synthesized rows so `info` carries the venue payload, not a nested `info` [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 432 | ✅ | 🎁 **authored_specs** · 🐛 T-A/OKX: author withdraw endpoint_selection (live pre-wire ambiguous multi-endpoint refusal) [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 433 | ✅ | 🎁 **authored_specs** · 🐛 Make in-plug request-shape assertions non-inert across the whole test suite [D:5/B:5/U:6 → Eff:1.1?] 📋 |
| Task 434 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 T-A/OKX: author the residual read and position request builds (request-gate reds) [D:6/B:7/U:7 → Eff:1.17?] 📋 |
| Task 435 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Derive unified fetch_open_orders returns canceled orders as open (raw endpoint returns []) [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 436 | ✅ | 🎁 **authored_specs** · 🐛 Raw endpoint arg misuse crashes deep in signing instead of a clear ArgumentError [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 437 | ✅ | 🎁 **authored_specs** · 🐛 OKX EEA demo balance live tests are red whenever the demo subaccount is unfunded [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 438 | ✅ | 🎁 **authored_specs** · 🐛 T-A/Binance: confront fetchPositions margin_ratio and percentage against a tier-1 oracle [D:5/B:6/U:5 → Eff:1.1?] 📋 |
| Task 439 | ✅ | 🎁 **authored_specs** · Classify HTML-bodied 401 as an authentication error, not access_restricted [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 440 | ✅ | 🎁 **authored_specs** · 🐛 Author okx endpoint_selection for cancelOrders so stop/trailing/trigger reaches trade/cancel-algos [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 441 | ✅ | 🎁 **authored_specs** · 🐛 Adjudicate okx Optimism network code against the CCXT 4.5.65 oracle (alias OPTIMISM vs oracle OP) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 442 | ✅ | 🎁 **authored_specs** · 🐛 Adjudicate the residual replay reds absorbed by the 4.5.65 response re-freeze [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 443 | ✅ | 🎁 **authored_specs** · 🐛 Make fixture-replay baseline drift visible to dispatch-scale runs [D:4/B:6/U:4 → Eff:1.25?] 📋 |
| Task 444 | ✅ | 🎁 **authored_specs** · 🐛 Derive option instrument ids do not carve into unified symbols on read paths [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 445 | ✅ | 🎁 **authored_specs** · 🐛 Derive editOrder builds a malformed request (same wholesale mapping failure as task 379 createOrder) [D:5/B:7/U:5 → Eff:1.2?] 📋 |
| Task 446 | ✅ | 🎁 **authored_specs** · 🐛 Carve registers can assert a weaker evidence tier than the ledger records; the consistency gate does not catch it [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 449 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Build a repeatable CCXT-reference-to-authored venue promotion gate [D:5/B:9/U:10 → Eff:1.9?] 🚀 |
| Task 450 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Promote Binance Coin-M as a complete authored public/private venue [D:7/B:9/U:8 → Eff:1.21?] 📋 |
| Task 451 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Promote Lighter as a complete authored public/private venue [D:7/B:9/U:9 → Eff:1.29?] 📋 |
| Task 452 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Close the Binance request-side BorrowInterest and AllGreeks fixture reds [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 453 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Scope exact-value response divergence contracts to their fixture cases [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 454 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Pin Task 434's OKX EEA-demo provenance and local-filter contract [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 455 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Make authored request-shape builder contracts fail loudly [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 456 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Map OKX fetchPositionsHistory until to native after [D:3/B:5/U:3 → Eff:1.33?] 📋 |
| Task 457 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Extend the recorded-fixture corpus to authenticated testnet reads and demo write flows [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 458 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Freeze exchange-accepted signed requests as a tier-1 signing oracle [D:6/B:7/U:6 → Eff:1.08?] 📋 |
| Task 459 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Report oracle tier and identity in fixture-gate output [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 460 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Vendor per-venue exchange-authority artifacts with provenance and an authority index [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 461 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Anchor the error taxonomy to vendored exchange error enumerations [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 462 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Promote venue_compare sweeps to a committed, replayable regression corpus [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 463 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Prune dead WS subscription patterns and orphaned reporting mix tasks; adjudicate bitfinex subscription pattern [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 464 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Machine-checkable oracle provenance per authored slice with a tier-coverage ratchet [D:5/B:5/U:3 → Eff:0.8?] ⚠️ |
| Task 465 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Add official-SDK third-way runners to venue_compare [D:5/B:5/U:3 → Eff:0.8?] ⚠️ |
| Task 466 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Level the per-venue carve registers to self-contained authority [D:3/B:3/U:2 → Eff:0.83?] ⚠️ |
| Task 467 `[P]` | ✅ | 🎁 **authored_specs** · 🐛 Teach the diff-scoped fixture_replay_gate to recognize the real-recordings corpus as venue scope [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 468 | ✅ | 🎁 **authored_specs** · Confront deribit fetchTradingFees carve C-T380a against current Deribit fee-schedule documentation [D:4/B:6/U:4 → Eff:1.25?] 📋 |
| Task 469 `[P]` | ✅ | 🎁 **authored_specs** · Make vacuous-on-empty private replay assertions self-declaring [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 471 | ✅ | 🎁 **polish** · AGENTS.md freshness gate never fires unattended, so the cross-family reviewer can grade against stale rules [D:5/B:7/U:8 → Eff:1.5?] 🚀 |
| Task 472 | ✅ | 🎁 **authored_specs** · Pin the availEq-absent balance branch on the international OKX demo account [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 473 | ✅ | 🎁 **authored_specs** · Derive createOrder silently drops clientOrderId while editOrder maps it to label [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 474 | ✅ | 🎁 **authored_specs** · Lighter native signer is unbuildable for Hex consumers and its C helper layer is unverified by the default check [D:4/B:6/U:5 → Eff:1.38?] 📋 |
| Task 475 | ✅ | 🎁 **authored_specs** · OKX request shape carries an unregistered -USD option hardcode and silently passes through unmapped timeframes [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 476 | ✅ | 🎁 **authored_specs** · .sobelow-skips accumulates stale line-pinned entries, so any edit above a skip silently re-reds the gate [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 477 `[P]` | ✅ | 🎁 **authored_specs** · Make the fixture_replay_scope global-path list self-verifying against the tree [D:4/B:7/U:5 → Eff:1.5?] 🚀 |
| Task 478 | ✅ | 🎁 **authored_specs** · Give authority-corpus drift checks an independent signal per artifact [D:3/B:4/U:3 → Eff:1.17?] 📋 |
| Task 479 | ✅ | 🎁 **authored_specs** · Decide and encode fixture-replay scope for the 19 unscoped top-level lib/ccxt modules [D:4/B:6/U:4 → Eff:1.25?] 📋 |
| Task 480 `[P]` | ✅ | 🎁 **authored_specs** · Make deribit fetchTradingFees fail loudly on the nested fee contract instead of silently returning an empty map [D:3/B:5/U:3 → Eff:1.33?] 📋 |
| Task 481 `[P]` | ✅ | 🎁 **authored_specs** · Finish the carve-register leveling: migrate residual binding tables, uniform canonical claims, and machine-readable evidence statuses for every prose tier claim [D:5/B:6/U:4 → Eff:1.0?] 📋 |
| Task 482 | ✅ | 🎁 **authored_specs** · Unify or explicitly justify the per-venue currency `active` rollup semantics (OR vs AND) [D:3/B:5/U:3 → Eff:1.33?] 📋 |
| Task 483 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/OKX: author order-read and with-cost request builds (state/algo routing, symbol rename) [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 484 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/OKX: author funding-surface request builds (code->ccy, withdraw chain/body, funding-history derivation) [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 485 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-A/OKX: wire fetchOpenInterestHistory response parse (raw envelope leak) [D:2/B:5/U:4 → Eff:2.25?] 🎯 |
| Task 486 | ✅ | 🎁 **polish** · 🚀 **v1_0** · Gate the landed-task CHANGELOG invariant so entries stop being backfilled by hand in audits [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 487 | ✅ | 🎁 **polish** · Gate CLAUDE.md's mechanical claims against the tree so doc drift fails loudly [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 488 | ✅ | 🎁 **authored_specs** · Give acceptance goldens distinct timestamp and nonce so transposition regressions redden the gate [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 489 | ✅ | 🎁 **authored_specs** · Derive Bybit request precision from instrument tickSize instead of a hardcoded per-symbol table [D:5/B:6/U:4 → Eff:1.0?] 📋 |
| Task 490 `[P]` | ✅ | 🎁 **authored_specs** · Restore maintenance-state error classification after the authority-anchored sentinel drop [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 491 `[P]` | ⛔ | 🎁 **authored_specs** · Mechanically verify vendored error enumerations are complete transcriptions of upstream [D:5/B:6/U:3 → Eff:0.9?] ⚠️ |
| Task 492 | ✅ | 🎁 **polish** · Request-shape sweep swallows every non-identifier exception, scoring broken builders as resolved [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 493 | ⛔ | 🎁 **polish** · Backfill the 38 same-wave tasks the CHANGELOG baseline froze as historical debt [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 494 | ✅ | 🎁 **authored_specs** · Decide and encode the unified order-precision contract when markets are not loaded [D:4/B:6/U:4 → Eff:1.25?] 📋 |
| Task 495 `[P]` | ✅ | 🎁 **authored_specs** · Pin the OKX option rubik open-interest-history column units with an offline tier-1 regression [D:2/B:4/U:3 → Eff:1.75?] 🚀 |
| Task 496 | ✅ | 🎁 **authored_specs** · 🐛 🔒 Make Sobelow blocking and eliminate dynamic fuse atoms [D:2/B:8/U:10 → Eff:4.5?] 🎯 |
| Task 497 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · 🐛 Unify order-precision market resolution so a passing guard provably implies a rounded wire value [D:6/B:8/U:6 → Eff:1.17?] 📋 |
| Task 498 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Re-derive the promotion method inventory from the pinned reference at check time [D:4/B:8/U:10 → Eff:2.25?] 🎯 |
| Task 499 | ✅ | 🎁 **authored_specs** · Decide the spec-driven trigger for static public trading fees instead of a hardcoded venue list [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 500 | ✅ | 🎁 **authored_specs** · Close the OKX intl-demo migration's live-evidence gaps (coverage, pins, capture profiles, acctLv safety) [D:4/B:5/U:5 → Eff:1.25?] 📋 |
| Task 501 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Vendor the upstream Lighter CCXT static corpus and wire it into the fixture replay gate [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 502 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Replay the shared Binance corpus for binanceusdm in the fixture replay gate [D:2/B:6/U:5 → Eff:2.75?] 🎯 |
| Task 503 `[P]` | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · T-D/OKX: derivative market identity — carve the _UM instId grammar into canonical unified symbols [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 504 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · OKX _UM carve: scope the quote-settled suffix to the USD family and extend it to SWAP instIds [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 514 | ✅ | 🎁 **authored_specs** · 🐛 Make %CCXT.OrderBook{} level arity a real contract, and confront okx's count-or-id column [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 516 | ✅ | 🎁 **authored_specs** · Author each supported venue's oracle profile instead of inferring graded sets from exemption lists [D:5/B:7/U:5 → Eff:1.2?] 📋 |
| Task 517 `[CX]` | ✅ | 🎁 **authored_specs** · No signing pattern may exist that no supported venue routes to [D:3/B:5/U:3 → Eff:1.33?] 📋 |
| Task 519 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Compute binary oracle provenance from reality manifests and add the oracle gate [D:7/B:9/U:9 → Eff:1.29?] 📋 |
| Task 520 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Capture recorded real error responses as a first-class evidence category [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 521 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Close the reality-recording gaps: alpaca, lighter, binancecoinm and the critical-slot residue [D:7/B:8/U:8 → Eff:1.14?] 📋 |
| Task 522 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Bulk-capture public accepted-request goldens across all ten venues [D:5/B:8/U:7 → Eff:1.5?] 🚀 |
| Task 523 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Retire the CCXT tier-2 oracle machinery and flip verification to the reality gate [D:8/B:9/U:6 → Eff:0.94?] ⚠️ |
| Task 524 | ✅ | 🎁 **authored_specs** · Decide the client's remaining vendored reference slice: recorded seeds or documented carry [D:4/B:5/U:4 → Eff:1.12?] 📋 |
| Task 525 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Unified public reads must round-trip live on each venue's own market symbols [D:5/B:8/U:7 → Eff:1.5?] 🚀 |
| Task 526 | ✅ | 🎁 **authored_specs** · Converge task 521: close residual critical-slot evidence and flip the oracle gate to hard-fail per venue [D:5/B:7/U:5 → Eff:1.2?] 📋 |
| Task 527 | ✅ | 🎁 **authored_specs** · Always-on VPS runner for the live-drift lane: full ten-venue coverage without the unreachable allowlist [D:3/B:6/U:3 → Eff:1.5?] 🚀 |
| Task 528 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Derive: close the live-red private read slices — subaccount threading, actionable missing-identifier error, balance free/used mapping [D:4/B:7/U:5 → Eff:1.5] 🚀 |
| Task 529 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Reconcile the live integration suites with landed contracts and current venue state [D:5/B:6/U:5 → Eff:1.1] 📋 |
| Task 530 | ✅ | 🎁 **authored_specs** · 🚀 **v1_0** · Binance-family: correct USD-M multi-assets balance free/used mapping and live trading-fee contracts [D:5/B:8/U:7 → Eff:1.5] 🚀 |
| Task 531 | ✅ | 🎁 **authored_specs** · Thread venue-required symbol params into unified private integration probes [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 532 | ✅ | 🎁 **authored_specs** · 🐛 Alpaca fetchOHLCV: author the time-window request slice so since/limit reach the venue instead of 400ing or silently returning nothing [D:3/B:7/U:6 → Eff:2.17] 🎯 |
| Task 533 | ✅ | 🎁 **authored_specs** · 🐛 Whole-surface unified-read contract guard: no raw envelopes, no collapsed multi-row responses, no un-normalized symbol keys [D:5/B:9/U:8 → Eff:1.7] 🚀 |
| Task 534 | ✅ | 🎁 **authored_specs** · 🐛 Unified endpoint selection must honor section priority, and every mapped method must be reachable by some documented param set [D:5/B:9/U:9 → Eff:1.8] 🚀 |
| Task 535 | ✅ | 🎁 **authored_specs** · 🐛 Funding cadence must come from observed venue data, not an authored constant — deribit reports 8h for an hourly venue [D:4/B:8/U:8 → Eff:2.0] 🎯 |
| Task 536 | ✅ | 🎁 **authored_specs** · 🐛 Order-status reads are unfiltered: fetch_canceled_orders, fetch_closed_orders and fetch_orders return identical rows [D:3/B:7/U:7 → Eff:2.33] 🎯 |
| Task 537 | ✅ | 🎁 **authored_specs** · 🐛 Unified read parsing raises instead of returning a typed error on legitimate venue responses [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 538 | ✅ | 🎁 **authored_specs** · 🐛 Authored enum slices reject real venue values — an unmapped order status kills four hyperliquid read methods [D:3/B:7/U:7 → Eff:2.33] 🎯 |
| Task 539 | ✅ | 🎁 **authored_specs** · 🐛 Field maps present but inert: populated venue fields arrive nil, and one scalar parse takes the year off a timestamp [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 540 | ✅ | 🎁 **authored_specs** · 🐛 Time-window request params must reach the venue on every venue, not one at a time [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 541 | ✅ | 🎁 **authored_specs** · 🐛 Lighter private reads demand a symbol the venue documents as optional [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 542 | ✅ | 🎁 **ws_unified** · 🐛 WebSocket private path never authenticates — the auth layer has no caller from the public API [D:7/B:8/U:7 → Eff:1.07] 📋 |
| Task 543 | ✅ | 🎁 **ws_unified** · 🐛 WS subscribe reports success when the venue rejects the subscription, and its return shape varies by venue [D:3/B:7/U:6 → Eff:2.17] 🎯 |
| Task 544 | ✅ | 🎁 **ws_unified** · 🐛 Two runtime venues have no WebSocket support at all — alpaca and lighter [D:5/B:6/U:4 → Eff:1.0] 📋 |
| Task 545 | ✅ | 🎁 **authored_specs** · 🐛 binancecoinm exposes 17 unified methods while the venue supports order history, leverage tiers, open interest, fees, ledger and ADL [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 546 | ✅ | 🎁 **authored_specs** · 🐛 lighter exposes 8 unified methods and no balance or positions, though one account response carries both [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 547 | ✅ | 🎁 **authored_specs** · 🐛 alpaca exposes no trade history and no transfers, though the paper account serves all three live [D:4/B:5/U:4 → Eff:1.12] 📋 |
| Task 548 | ✅ | 🎁 **authored_specs** · 🐛 binance OCO order lists are invisible to the unified surface [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 549 | ✅ | 🎁 **authored_specs** · 🐛 derive declares four capabilities false while the endpoints for them exist [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 550 | ⛔ | 🎁 **authored_specs** · 🐛 Close the unified parse-coverage gap: declared-supported read methods that have no response parse slice [D:7/B:9/U:8 → Eff:1.21] 📋 |
| Task 551 | ⛔ | 🎁 **authored_specs** · Grade every sliced read method against a recording — 246 of 313 are measured by nothing today [D:7/B:9/U:8 → Eff:1.21] 📋 |
| Task 552 | ✅ | 🎁 **authored_specs** · enum_passthrough silently exempts a venue from the status-coverage test — enumerate it or drop it [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 553 | ✅ | 🎁 **authored_specs** · 🐛 since is still dropped on binance spot reads — assert the returned window, not the absence of an error [D:6/B:8/U:7 → Eff:1.25] 📋 |
| Task 554 `[P]` | ✅ | 🎁 **authored_specs** · Activate the provider-authority corpus as a complete, freshness-visible source index [D:6/B:8/U:9 → Eff:1.42] 📋 |
| Task 555 | ✅ | 🎁 **authored_specs** · Compare provider-owned contracts with authored specs across the ten supported venues [D:8/B:10/U:9 → Eff:1.19] 📋 |
| Task 556 | ✅ | 🎁 **authored_specs** · Build provider-operation reality capture and prove it on Deribit public REST [D:7/B:10/U:9 → Eff:1.36] 📋 |
| Task 557 | ⛔ | 🎁 **authored_specs** · Drain Deribit current-REST read evidence by provider contract section [D:9/B:10/U:8 → Eff:1.0] 📋 |
| Task 558 | ✅ | 🎁 **authored_specs** · Adjudicate Deribit mutating REST operations with reversible evidence and explicit unsafe boundaries [D:7/B:9/U:8 → Eff:1.21] 📋 |
| Task 559 | ✅ | 🎁 **integration_tests** · 🐛 Circuit-breaker fuses leak across test modules, so the offline suite reports a rotating set of flaky failures [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 560 | ✅ | 🎁 **authored_specs** · 🐛 Derive ticker maps high/low/change/percentage from a stats object the venue does not publish [D:2/B:5/U:4 → Eff:2.25] 🎯 |
| Task 561 | ✅ | 🎁 **integration_tests** · 🐛 Bourse.Testnet exits the calling process when unsupervised, aborting a consumer's entire test suite [D:3/B:6/U:5 → Eff:1.83] 🚀 |
| Task 562 | ✅ | 🎁 **parsers** · 🐛 Per-field maps cannot address envelope-level keys, so every bybit ticker is unstamped [D:5/B:7/U:7 → Eff:1.4] 📋 |
| Task 563 | ⛔ | 🎁 **ws_unified** · 🐛 derive authors no WebSocket auth pattern, so its private section connects without a handshake [D:6/B:6/U:5 → Eff:0.92] ⚠️ |
| Task 564 | ✅ | 🎁 **authored_specs** · 🐛 The parse-coverage guard measures a dead CCXT descriptor field: 65 of its 79 tracked cells are phantom and 49 real leaks are invisible [D:5/B:9/U:9 → Eff:1.8] 🚀 |
| Task 565 | ✅ | 🎁 **authored_specs** · 🐛 51 declared reads resolve to no parser slot at all — repair the return-type resolution table, do not invent types per venue [D:6/B:9/U:9 → Eff:1.5] 🚀 |
| Task 566 | ⛔ | 🎁 **authored_specs** · 🐛 Build the unified return types the resolution repair could not alias, or retire their declarations [D:7/B:7/U:7 → Eff:1.0] 📋 |
| Task 567 | ✅ | 🎁 **authored_specs** · 🐛 The conversion and currency parse types are wired but have no field map on bybit and binanceusdm — 8 declared reads error instead of parsing [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 568 | ✅ | 🎁 **authored_specs** · 🐛 funding_history and margin_modification parse types have no field map on four venue-method pairs [D:3/B:6/U:5 → Eff:1.83] 🚀 |
| Task 569 | ✅ | 🎁 **signing** · 🔒 Five of the seven C-exposed Lighter signing operations are pinned only by shape, so a dependency bump cannot be verified [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 570 | ✅ | 🎁 **authored_specs** · 🚀 **v1_1** · 🐛 One field carries three independent facts, so a raw unmapped read is either silently mislabelled as normalized or deleted outright — separate them and label raw as raw [D:9/B:9/U:9 → Eff:1.0] 📋 |
| Task 571 | ✅ | 🎁 **authored_specs** · 🐛 Bulk list reads return venue-native symbols in unified structs, so a consumer cannot join them to any other unified result [D:5/B:8/U:7 → Eff:1.5] 🚀 |
| Task 572 | ✅ | 🎁 **authored_specs** · 🚀 **v1_1** · 🐛 Bybit authors 59 unresolved category defaults, so declared reads that pass every coverage gate still fail live with error 10001 [D:6/B:8/U:7 → Eff:1.25] 📋 |
| Task 573 | ✅ | 🎁 **authored_specs** · 🐛 binance fetch_funding_rate leaves interval nil — the C5 funding-interval carve was never confronted for binance [D:2/B:5/U:5 → Eff:2.5] 🎯 |
| Task 574 | ✅ | 🎁 **authored_specs** · 🐛 binance fapi write path drops unified opts and misparses cancel confirmations — a stop order executed as a naked market sell [D:6/B:9/U:8 → Eff:1.42] 📋 |
| Task 575 | ✅ | 🎁 **authored_specs** · 🐛 binance fetch_balance(type: :swap) routes to the spot testnet in sandbox — no unified path to the USD-M wallet [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 576 | ✅ | 🎁 **authored_specs** · 🐛 binance USD-M conditional orders are write-only: cancel and fetch cannot see the algo book, and take_profit_price still routes as a naked market order [D:6/B:9/U:8 → Eff:1.42] 📋 |
| Task 577 | ✅ | 🎁 **authored_specs** · 🐛 binance-family funding interval: inverse symbols on the generic client read the USD-M funding list, and the plural read is never enriched [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 578 | ✅ | 🎁 **authored_specs** · 🐛 The task-574/575 write-path fixes landed only on the generic binance spec — binanceusdm still sends the symbol as marginType and both dedicated futures venues drop unified order opts [D:6/B:8/U:6 → Eff:1.17] 📋 |
| Task 579 | ✅ | 🎁 **authored_specs** · 🐛 Authority drift lane cries wolf: split --online drift semantics by artifact class (typed contract fails, prose churn warns) [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 580 | ✅ | 🎁 **authored_specs** · 🐛 Unified order reads are blind to the binance algo book: an identifier cancel_order accepts makes fetch_order answer order_not_found [D:5/B:6/U:5 → Eff:1.1] 📋 |
| Task 581 | ✅ | 🎁 **authored_specs** · 🐛 Oracle critical-slot waivers never expire: 79 dated entries satisfy the hard gate indefinitely, restoring report-only semantics under a new name [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 582 | ⛔ | 🎁 **authored_specs** · Record populated evidence for shape-only-verified surfaces: binance order lists (C-T548) and derive ERC-20 transfers (C-T549b) [D:4/B:3/U:2 → Eff:0.62] ⚠️ |
| Task 583 | ⛔ | 🎁 **authored_specs** · 🐛 Generic binance inverse-family parity: symbols denormalize to the pair form, and the algo/book_routes selection exists only on the dedicated venue [D:6/B:7/U:5 → Eff:1.0] 📋 |
| Task 584 | ✅ | 🎁 **authored_specs** · 🐛 Binance-family plural funding reads stamp a fabricated 8h interval onto instruments that never fund — gate the default on perpetuals [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 585 | ✅ | 🎁 **authored_specs** · 🐛 Derive fetch_transfers silently drops caller-supplied code and limit — the venue endpoint has no asset filter or pagination [D:3/B:4/U:3 → Eff:1.17] 📋 |
| Task 586 | ✅ | 🎁 **authored_specs** · 🐛 binance futures family declares capabilities false the venues serve: coinm setPositionMode/setLeverage, usdm fetchLeverage via symbolConfig [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 587 | ✅ | 🎁 **authored_specs** · Unified boundary accepts structurally invalid arguments and crashes in the signing layer — validate param value shapes before dispatch [D:3/B:4/U:2 → Eff:1.0] 📋 |
| Task 588 | ⛔ | 🎁 **authored_specs** · Native-symbol backfill fails loudly on one venue out of ten — make the resolver's outcome explicit everywhere and stop accepting degenerate unified forms [D:5/B:6/U:3 → Eff:0.9] ⚠️ |
| Task 589 | ✅ | 🎁 **authored_specs** · Emulated configuration reads answer {:ok, nil} when the plural has no row — a config read refuses or errors, it never hands back nil [D:3/B:6/U:2 → Eff:1.33] 📋 |
| Task 590 | ⛔ | 🎁 **authored_specs** · Binance futures leverage/margin carve completion: coinm cannot read the margin mode it can set, and leverage 0 ships as a multipliable number [D:4/B:5/U:2 → Eff:0.88] ⚠️ |
| Task 591 | ✅ | 🎁 **authored_specs** · 🐛 binancecoinm wires plural fetchTradingFees to the symbol-mandatory commission-rate endpoint - move to singular fetchTradingFee and retire the shared parse compensation [D:3/B:5/U:4 → Eff:1.5] 🚀 |
| Task 592 | ✅ | 🎁 **authored_specs** · 🐛 binance-family ledger enums are incomplete and undirected - add the missing income-type arms, sign_direction, and a documented-set coverage guard for ledger_entry.type [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 593 | ✅ | 🎁 **authored_specs** · Promote coinbaseexchange as a public-only market-data venue (candles + ticker) [D:5/B:6/U:5 → Eff:1.1] 📋 |
| Task 594 | ✅ | 🎁 **authored_specs** · 🐛 Confront the unit of every authored rate-like slot against venue-owned arithmetic [D:4/B:7/U:6 → Eff:1.62] 🚀 |
| Task 595 | ✅ | 🎁 **authored_specs** · 🐛 Lighter account and history slice fidelity against a funded, active testnet account [D:7/B:8/U:5 → Eff:0.93] ⚠️ |
| Task 596 | ✅ | 🎁 **authored_specs** · Request-shape / recorded-request congruence gate: a recording captured with params the runtime builder cannot produce is red [D:5/B:8/U:6 → Eff:1.4] 📋 |
| Task 597 | ⛔ | 🎁 **authored_specs** · Coinbase Exchange read-only market data: candles and ticker [D:4/B:5/U:2 → Eff:0.88] ⚠️ |
| Task 598 | ✅ | 🎁 **authored_specs** · 🐛 Ledger type authority: derive the documented-set registry from provider contracts, fix the generic binance ledger map, make unmapped types loud [D:6/B:8/U:7 → Eff:1.25] 📋 |
| Task 599 | ✅ | 🎁 **authored_specs** · Close the 596 congruence-gate residuals: vacuous-pass ratchet, exemption pinning, caller_params and inventory-snapshot anchoring [D:7/B:8/U:6 → Eff:1.0] 📋 |
| Task 600 | ✅ | 🎁 **authored_specs** · 🐛 One unit per unified rate-like field: cross-venue unit invariant (margin percentage, implied volatility, lighter coverage, extras-carried rates) [D:6/B:8/U:6 → Eff:1.17] 📋 |
| Task 601 | ✅ | 🎁 **authored_specs** · 🐛 Ledger vocabulary is route-blind: scope the type registries per routed endpoint and make the unified type contract honest [D:6/B:7/U:6 → Eff:1.08] 📋 |
| Task 603 | ✅ | 🎁 **authored_specs** · 🐛 The rate-unit invariant grades declarations, not emissions: make it falsifiable and fix the three unit bugs it certified green [D:7/B:8/U:6 → Eff:1.0] 📋 |
| Task 606 | ✅ | 🎁 **live_triage** · 🐛 Unit discriminators die on list reads: deribit positions emit nil margins, binance plural option tickers stay 100x off [D:5/B:8/U:6 → Eff:1.4] 📋 |
| Task 607 `[P]` | ✅ | 🎁 **live_triage** · Reconcile bybit and hyperliquid ledger labels onto the registered taxonomy; venue_specific must mean outside-the-registry [D:6/B:5/U:4 → Eff:0.75] ⚠️ |
| Task 608 `[P]` | ✅ | 🎁 **live_triage** · Money-field discriminators must be payload-derived on every symbol-less read: deribit trade cost is 2.5e9x off, and the endpoint-route key is not an identity [D:6/B:8/U:6 → Eff:1.17] 📋 |
| Task 609 `[P]` | ✅ | 🎁 **live_triage** · Close the remaining ledger-taxonomy splits: bybit funding is invisible, promotional credits and converts split cross-venue, passthrough remainders split by casing [D:6/B:7/U:4 → Eff:0.92] ⚠️ |
| Task 610 `[P]` | ✅ | 🎁 **live_triage** · Position carries one unit contract: notional is quote-denominated and contracts x contractSize reconciles, on every venue [D:6/B:6/U:4 → Eff:0.83] ⚠️ |
| Task 611 `[P]` | ✅ | 🎁 **live_triage** · Deribit linear futures break the fresh unit contract: notional guards on kind, not settlement, so the USDC book emits base-coin notional labelled as quote [D:5/B:8/U:7 → Eff:1.5] 🚀 |
| Task 612 `[P]` | ⛔ | 🎁 **live_triage** · Deribit inverse classification has one source of truth: collapse the instrument-id parser onto the market carve and cover combos [D:5/B:7/U:5 → Eff:1.2] 📋 |
| Task 613 `[P]` | ✅ | 🎁 **live_triage** · Unified Position carries a machine-readable unit contract: notional currency and base_quantity are populated or scoped, never prose-only [D:5/B:7/U:4 → Eff:1.1] 📋 |
| Task 614 `[P]` | ✅ | 🎁 **live_triage** · Bybit USDC-perp SETTLEMENT rows mix session P&L into funding_fee amount — source the funding component, not change [D:4/B:6/U:4 → Eff:1.25] 📋 |
| Task 615 `[P]` | ✅ | 🎁 **live_triage** · Authored conditional request entries clobber caller-supplied native params — caller value wins, the conditional only supplies the default [D:3/B:7/U:4 → Eff:1.83] 🚀 |
| Task 616 `[P]` | ✅ | 🎁 **live_triage** · A single struct escaping a symbol-dict unified read is a silent contract break — make the fallthrough loud and prove the binance fee slice live [D:4/B:6/U:4 → Eff:1.25] 📋 |
| Task 617 `[P]` | ✅ | 🎁 **live_triage** · 🐛 Time-window translation is asserted request-side: an offline guard over every since/until read, and a since-mutation the matrix can actually catch [D:6/B:8/U:6 → Eff:1.17] 📋 |
| Task 619 | ✅ | 🎁 **authored_specs** · Refresh the pinned Deribit current-REST OpenAPI and re-bind every artifact that quotes it [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 620 `[P]` | ✅ | 🎁 **authored_specs** · Shape-check non-lighter caller_params against request_param_shapes so recaptured no-injection fixtures are actually verified [D:4/B:7/U:5 → Eff:1.5] 🚀 |
| Task 622 `[P]` | ✅ | 🎁 **live_triage** · 🐛 Unified client_order_id is one-way on deribit: it goes out as label and never comes back — make the round-trip a cross-venue invariant [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 623 `[P]` | ✅ | 🎁 **live_triage** · 🐛 binanceusdm markets ship contract_size nil while the position carve already assumes 1 — source the linear unit from the provider, never a silent default [D:4/B:8/U:6 → Eff:1.75] 🚀 |
| Task 624 `[P]` | ✅ | 🎁 **authored_specs** · Mutation-lifecycle compensation holds under transport and parse failure: attempted-act tracking, session-label sweep, mutating-steps-before-cleanup plan rule [D:4/B:7/U:5 → Eff:1.5] 🚀 |
| Task 625 `[P]` | ✅ | 🎁 **authored_specs** · Author remaining linear contract_unit recipes for the known-gap venues (binance umbrella, bybit, derive) [D:4/B:7/U:5 → Eff:1.5] 🚀 |
| Task 626 `[P]` | ✅ | 🎁 **live_triage** · 🚀 **v1_1** · A market's declared type and its capability flags disagree, and multi-leg instruments carry no quantity semantics at all — a consumer keying on either signal computes a meaningless exposure [D:5/B:7/U:4 → Eff:1.1] 📋 |
| Task 633 `[P]` | ✅ | 🎁 **live_triage** · 🐛 Binance USD-M and COIN-M time-window reads still pass raw since/until: omit open-orders bounds and rename the histories that document startTime/endTime [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 635 `[P]` | ✅ | 🎁 **live_triage** · 🐛 Unified until is declared inclusive but two OKX cursor sites still send it exclusive — decide once and guard the class [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 636 `[P]` | ✅ | 🎁 **live_triage** · Authority pins detect drift but cannot name it: reference_only artifacts retain no bytes, so every review reconstructs the delta by hand [D:6/B:7/U:6 → Eff:1.08] 📋 |
| Task 637 `[P]` | ✅ | 🎁 **live_triage** · 🐛 OKX fetch_withdrawals still passes raw since/until onto exclusive before/after cursors [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 638 | ✅ | 🎁 **ws_unified** · 🐛 Lighter subscribe acknowledgement swallows the first market snapshot [D:3/B:4/U:3 → Eff:1.17] 📋 |
| Task 639 `[P]` | ✅ | 🎁 **live_triage** · 🐛 Two canonical SHA-256 schemes hash the same operation-key set, so a REST surface digest will report false drift [D:6/B:8/U:5 → Eff:1.08] 📋 |
| Task 640 `[P]` | ⛔ | 🎁 **live_triage** · Surface digests carry unvalidated inferred provenance and stale not-nameable claims the digest itself now disproves [D:5/B:6/U:4 → Eff:1.0] 📋 |
| Task 641 `[P]` | ✅ | 🎁 **live_triage** · 🐛 Bybit inverse position contract_size is nil in production but the unit invariant is proven on an injected field the venue never sends [D:6/B:8/U:5 → Eff:1.08] 📋 |
| Task 642 `[P]` | ✅ | 🎁 **live_triage** · 🐛 Caller-input validation has two error contracts: a too-long client_order_id raises out of the non-bang API while a bad price value returns a tuple [D:4/B:6/U:4 → Eff:1.25] 📋 |
| Task 643 | ✅ | 🎁 **ws_unified** · 🐛 Shipped 0.6.0 connects the USD-M private stream to a host Binance decommissioned on 2026-04-23, and the failure is silent [D:5/B:9/U:6 → Eff:1.5] 🚀 |
| Task 644 | ⛔ | 🎁 **ws_unified** · 🐛 watch_order_book returns nil on deribit and both binance futures surfaces, and one socket with several symbols collapses every book onto one key [D:6/B:8/U:5 → Eff:1.08] 📋 |
| Task 645 | ✅ | 🎁 **ws_unified** · 🐛 Every WebSocket reconnect leaks a connection-owner process, and the ownership check that would have caught it is dead code three docs still describe as live [D:5/B:6/U:4 → Eff:1.0] 📋 |
| Task 646 | ✅ | 🎁 **live_triage** · 🐛 fetch_funding_rate answers for markets that have no funding: a spot symbol silently receives the perp's rate stamped with the spot symbol [D:6/B:9/U:6 → Eff:1.25] 📋 |
| Task 647 `[P]` | ✅ | 🎁 **live_triage** · 🐛 The live public-read smoke guard is red on main and nobody sees it: coinbaseexchange is missing and the test only runs under --include network [D:3/B:6/U:4 → Eff:1.67] 🚀 |
| Task 648 `[P]` | ✅ | 🎁 **rest_unified** · 🚀 **v1_1** · Account class and margin model are not readable as unified facts, so a consumer cannot tell a derivatives account from a spot one [D:7/B:8/U:5 → Eff:0.93] ⚠️ |
| Task 649 | ✅ | 🎁 **live_triage** · 🐛 Nothing pins the capability surface across releases, so answering whether a has? flag changed means unpacking two hex tarballs by hand [D:5/B:9/U:5 → Eff:1.4] 📋 |
| Task 650 `[P]` | ✅ | 🎁 **live_triage** · The scheduled live lane probes two methods per venue while the WebSocket corpus that would have caught the last three outages runs nowhere [D:5/B:9/U:6 → Eff:1.5] 🚀 |
| Task 651 `[P]` | ✅ | 🎁 **rest_unified** · 🐛 Two caller-input rejections still escape the non-bang unified API as exceptions, so the public error contract depends on which field was wrong [D:3/B:6/U:4 → Eff:1.67] 🚀 |
| Task 652 | ✅ | 🎁 **rest_unified** · 🐛 Every emulated read rebuilds the parameter map from three hardcoded keys, so all other caller parameters are silently discarded before the delegated call [D:5/B:8/U:6 → Eff:1.4] 📋 |
| Task 653 `[P]` | ✅ | 🎁 **rest_unified** · 🐛 RequestShape still raises ArgumentError for caller-input problems, and the 651 class sweep cannot see them [D:5/B:6/U:4 → Eff:1.0] 📋 |
| Task 654 | ⛔ | 🎁 **live_triage** · 🐛 Umbrella binance inverse symbols denormalize to a compact id the COIN-M premiumIndex does not list [D:4/B:7/U:5 → Eff:1.5] 🚀 |
| Task 655 | ⛔ | 🎁 **authored_specs** · 🐛 A post-parse backfill re-supplies the value the authored field map already produces, so oracle replay cannot tell a working envelope clock from a broken one [D:4/B:7/U:5 → Eff:1.5] 🚀 |
| Task 656 `[P]` | ⛔ | 🎁 **authored_specs** · The critical-module coverage tier is doctrine that nothing enforces, and six modules on the money path are below it while every wave mutates them [D:5/B:8/U:6 → Eff:1.4] 📋 |
| Task 657 `[P]` | ⛔ | 🎁 **rest_unified** · 🐛 The fundingless predicate names one of the four market types the taxonomy already distinguishes, so an option or dated future is only caught when the venue happens to answer empty [D:3/B:8/U:6 → Eff:2.33] 🎯 |
| Task 658 | ✅ | 🎁 **rest_unified** · 🐛 The unified symbol for a bybit dated future carries the venue-native date form, so every unified method crashes on all 44 of them [D:5/B:9/U:7 → Eff:1.6] 🚀 |
| Task 659 | ✅ | 🎁 **rest_unified** · 🐛 OrderPrecision snap_value MatchError is a third contract for non-numeric order amounts [D:3/B:5/U:3 → Eff:1.33] 📋 |
| Task 660 | ✅ | 🎁 **rest_unified** · 🐛 Bybit dated-future unified symbols still carry venue-native DDMMMYY after the 658 pass-through [D:5/B:9/U:7 → Eff:1.6] 🚀 |
| Task 661 | ⛔ | 🎁 **rest_unified** · 🐛 Bybit InverseFutures native ids are quarterly codes, not DDMMMYY [D:5/B:8/U:6 → Eff:1.4] 📋 |
| Task 662 `[P]` | ✅ | 🎁 **live_triage** · 🚀 **v1_1** · An unrecognized caller option is reported as a recoverable venue network fault and melts the circuit breaker, taking every read on that venue down [D:4/B:8/U:6 → Eff:1.75] 🚀 |
| Task 663 | ✅ | 🎁 **live_triage** · 🚀 **v1_1** · 🐛 🔒 The unified write boundary silently discards caller intent: an uninterpretable `side` routes to a DEFAULT direction instead of erroring [D:4/B:8/U:7 → Eff:1.88] 🚀 |
| Task 664 | ✅ | 🎁 **live_triage** · 🚀 **v1_1** · 🐛 Unified `notional` is authored nil for every non-future deribit position kind, so an open option contributes nothing to a size fold [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 665 `[P]` | ✅ | 🎁 **live_triage** · 🚀 **v1_1** · 🐛 🔒 A side that is not exactly "buy" or "sell" still becomes a direction on every batch write path [D:3/B:7/U:6 → Eff:2.17] 🎯 |
| Task 666 `[P]` | ✅ | 🎁 **live_triage** · 🚀 **v1_1** · 🐛 Option position notional is derived per venue with no shared rule, so the same field carries a different unit on each one [D:4/B:6/U:3 → Eff:1.12] 📋 |
<!-- TASKS:END -->

## Phase 15: Options Execution

Four-venue option trading program (deribit, bybit, okx-international, derive): option semantics → surface → portfolio risk → preflight/hedge → execution saga → readiness matrix → per-venue attestation → convergence → optimization.

<!-- TASKS:BEGIN phase=15 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 396 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Attest option-capable sandbox accounts and venue health [D:4/B:10/U:10 → Eff:2.5?] 🎯 |
| Task 397 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Confront option amount, multiplier and settlement semantics [D:8/B:10/U:9 → Eff:1.19?] 📋 |
| Task 398 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Complete the four-venue option and Greeks surface [D:7/B:9/U:9 → Eff:1.29?] 📋 |
| Task 399 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Build a coherent multi-venue portfolio risk snapshot [D:8/B:10/U:9 → Eff:1.19?] 📋 |
| Task 400 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Add option proposal preflight and hedge calculations [D:9/B:10/U:9 → Eff:1.06?] 📋 |
| Task 401 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Execute approved option plans as an observable saga [D:9/B:10/U:9 → Eff:1.06?] 📋 |
| Task 402 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Add an executable four-venue option readiness matrix [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 403 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Attest option fill, hedge and unwind across the four option venues (orchestrator sweep) [D:6/B:9/U:8 → Eff:1.42?] 📋 |
| Task 404 | ⛔ | 🎁 **options_execution** · 🚀 **v1_0** · Attest Bybit option fill, hedge and unwind [D:6/B:9/U:8 → Eff:1.42?] 📋 |
| Task 405 | ⛔ | 🎁 **options_execution** · 🚀 **v1_0** · Attest OKX option fill, hedge and unwind [D:6/B:9/U:8 → Eff:1.42?] 📋 |
| Task 406 | ⛔ | 🎁 **options_execution** · 🚀 **v1_0** · Attest Derive option fill, hedge and unwind [D:6/B:9/U:8 → Eff:1.42?] 📋 |
| Task 407 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Converge four-venue option execution readiness [D:4/B:9/U:8 → Eff:2.12?] 🎯 |
| Task 408 | ✅ | 🎁 **options_execution** · Add multi-Greek multi-instrument optimization [D:9/B:8/U:5 → Eff:0.72?] ⚠️ |
| Task 409 | ✅ | 🎁 **options_execution** · Expose venue-local margin impact for caller-supplied candidate plans [D:9/B:8/U:5 → Eff:0.72?] ⚠️ |
| Task 505 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · OptionProposal preflight: make the live self-fetch path usable — negative-age staleness and inverse-hedge price sourcing [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 506 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Fix unified option-position reads: venue symbol carve and contracts unit [D:3/B:7/U:6 → Eff:2.17?] 🎯 |
| Task 507 | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Make the option-readiness preflight/hedge collectors live-capable on all four venues [D:3/B:6/U:5 → Eff:1.83?] 🚀 |
| Task 509 `[P]` | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · Pin live testnet margin-impact evidence for deribit, bybit and derive candidate plans [D:4/B:6/U:3 → Eff:1.12?] 📋 |
| Task 510 `[P]` | ✅ | 🎁 **options_execution** · 🚀 **v1_0** · 🐛 Dialyzer-clean the options-wave modules [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
| Task 511 | ✅ | 🎁 **options_execution** · 🐛 Authored order-state completeness: map Deribit speed_bumped and close the unmapped-status class [D:6/B:8/U:7 → Eff:1.25?] 📋 |
| Task 512 | ⛔ | 🎁 **options_execution** · OptionProposal: base-currency numeraire risk targets + covered-call preflight mode [D:6/B:7/U:6 → Eff:1.08?] 📋 |
| Task 513 | ✅ | 🎁 **options_execution** · OptionReadiness: expose orthogonal short-side lifecycle capability [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 602 `[P]` | ⛔ | 🎁 **options_execution** · Expose account-level portfolio-margin summaries in Bourse.PortfolioRisk [D:5/B:7/U:5 → Eff:1.2] 📋 |
<!-- TASKS:END -->
