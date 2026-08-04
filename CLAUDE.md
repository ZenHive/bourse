# CLAUDE.md

Guidance for Claude Code working in this repository.

## Active Includes

Eager-load only the irreducible floor; everything else is skill-on-demand via enabled plugins. **Don't double-load** (an `@`-import plus its sibling skill pays twice for the same tokens).

- **`critical-rules`** — hard guardrails that must stay ambient every session (a guardrail the model invokes "when relevant" fails exactly when it doesn't realize the rule applies).
- **`ex-unit-json`** — `mix test.json` is the test runner every session uses; its flight-recorder semantics and the "JSON-by-design — parse for real failures, never reject the envelope" rule are load-bearing for cross-family reviewers.

@~/.claude/includes/critical-rules.md
@~/.claude/includes/ex-unit-json.md

(`response-conventions` loads globally via `~/.claude/CLAUDE.md` — not re-imported here.)

> **Add `@~/.claude/includes/harness-workflow.md` when this repo is registered for harness dispatch.** It is not imported yet because no dispatch loop runs here; the import is load-bearing only once it does.

## What this repository is

`bourse` (`:bourse`, namespace `Bourse.*`) — an Elixir client for ten exchange integrations: `alpaca`, `binance`, `binancecoinm`, `binanceusdm`, `bybit`, `deribit`, `derive`, `hyperliquid`, `lighter`, `okx`. One complete hand-authored JSON spec per venue drives macro-generated endpoint modules; the three DEX venues carry hand-written signing.

Runtime support is a **closed set**. `Bourse.Exchanges` and `Bourse.Registry` read `priv/specs/json/runtime_support.json` and generate exactly ten modules; constructing anything else fails immediately with `unsupported_exchange`. There is no `config :bourse, exchanges:` knob — support is not a configuration outcome.

### 🚧 The workbench boundary — read this before deciding where work goes

This repo was extracted from `../ccxt_client`, which remains the **authoring workbench**. The split is by question, not by file type:

| Question | Repo |
|---|---|
| Does the client behave correctly against a supported venue? | **here** |
| Is a supported venue's authored spec right? | **here** — the spec, its authority manifest and its reality evidence all live here |
| Does an eleventh venue get added? | workbench (`mix ccxt.promote_venue`) |
| Did the full CCXT reference extraction shift across all 110 venues? | workbench — this repo carries a 15-venue slice and cannot answer corpus-wide questions |
| Roadmap, task scoring, CHANGELOG gating, AGENTS.md rendering | workbench |

**Consequences that bite if forgotten:**

- Two tests deliberately stayed in the workbench because they are corpus-wide: the zero-param JSON-body gate audit (asserts a gate set across all 110 reference specs) and anything else iterating `Path.wildcard("priv/specs/json/output/*.json")` expecting the full set. **Do not re-add a corpus-wide audit here** — it would be answering a 110-venue question with 15 specs.
- `priv/specs/json/reference_corpus.json` honestly declares the 15 carried venues (the ten supported plus `coinmetro`, `deepcoin`, `kraken`, `weex`, `whitebit`, used as parser and unsupported-venue counter-examples). Its two SHA-256 pins still name the upstream revision the slice came from, so provenance stays verifiable. **Adding a reference venue means adding its JSON *and* the manifest entry** — `Mix.Tasks.Ccxt.ReferenceCorpus` validates count, sort order and pins, and raises otherwise.

## 🎯 Core doctrine: provider-authoritative, reality-verified

**Interpret, don't extract.** Full model and rationale: `docs/authored-specs.md` — read it first.

**The one and only reality is the exchange APIs we talk to** — not CCXT, not CCXT's fixtures, not training. CCXT was the bootstrap; it is now **one disposable reference among several** (exchange API docs, official SDKs, observed behavior). The DEX venues already live this way. Three axes, kept distinct: **value** correctness (is the number right vs reality), **carve** correctness (is the field/abstraction itself right, willing to *diverge* from CCXT's ontology), and **freshness** (frozen recordings kept honest by live drift checks).

**Authority ladder — the exchange-owned contract wins.** Live or recorded raw exchange behavior establishes what the venue does; the exchange's own documentation, specifications and SDKs establish what its fields and parameters mean. CCXT source, execution and static files are unverified authoring references only.

**Authoring and verification stay separate.** Author by reading multiple sources; verify through manifest-registered venue recordings, accepted-request goldens and recorded exchange errors. `mix ccxt.oracle_gate` is the only verification oracle in the check pipeline.

**Verification is binary.** A claim is `verified` only when the reality manifests and `mix ccxt.oracle_gate` cover it; otherwise it is `unverified`. CCXT JS is a tool, not the truth: its parser output can inform authoring but cannot verify venue semantics.

### Rules

- ✅ DO: author interpretive slices against the exchange-owned API contract, using CCXT only as reference material; keep `mix ccxt.oracle_gate` green.
- ✅ DO: verify by **running/observing**; author by **reading** any source. A source that fed authoring cannot also be the oracle.
- ✅ DO: run the **confrontation step** when authoring a venue slice (`docs/authored-specs.md`) — for each schema decision, confront the CARVE (does the field exist here? what does the value mean? is the abstraction right for this venue?) against the exchange's OWN semantics. Record every CONFIRMED / DIVERGE outcome in the venue's carve register under `docs/authored-spec-carves/`. A CCXT carve adopted without a register entry is inherited, not confronted.
- 🚨 DO: keep it REAL — for divergence-prone fields (anything CCXT *computes* or *branches* rather than copies: precision, inverse-vs-linear cost, funding cadence, fee tiers), test against the **REAL API plus a non-CCXT semantic source**, never against a potentially-wrong CCXT fixture. A wrong fixture is *more costly* than a live call: it certifies our bug green and silent. The canonical case: deribit's funding `interval` was the authored literal `"8h"` while the venue publishes hourly — internally consistent, fully tested, and wrong, because the golden was computed with the same wrong constant.
- 🚨 DO: **decolor on touch.** Comments, moduledocs and docs that cite CCXT as the *reason or authority* for a decision steer every future session back toward CCXT-as-truth. Never write a new one. `test/bourse/ccxt_authority_language_test.exs` enforces this with an explicit allowlist — a new CCXT mention in `lib/` fails the suite until it is either reworded or allowlisted with a compatibility-framed phrase.
- ✅ DO: when a reality confrontation is **unreachable with our keys/hosts** (prod-only endpoint, region-restricted key, needs a real open position), append an entry to `docs/prod-verification-ledger.md`. The slice stays `unverified` until the ledger entry closes and the recording is registered.
- ❌ DO NOT: treat CCXT-derived data or training/web as verification. Independence comes from execution/reality, not a second read.
- 🚨🚨 DO (behavioral default, anchored to the ACTION): **when you set out to check whether a venue "works," your FIRST call hits the LIVE testnet.** Recipe: `creds = Bourse.Credentials.new!(api_key: System.get_env("DERIBIT_TESTNET_API_KEY"), secret: ...); {:ok, ex} = Bourse.Exchange.new("deribit", credentials: creds, sandbox: true)` → then a real `Bourse.fetch_ticker/fetch_balance`. Testnet credentials for all ten venues are provisioned (below).

### Venue authority index

Any venue-source, contract-coverage or field-judgment question opens `priv/authority/<venue>/` **FIRST**. The manifest is the local provenance index, not the authority itself: when the question is discovery or freshness, check the provider's official upstream next. Manifests record URL, upstream revision, retrieval date, byte count, SHA-256 and licensing disposition.

| Venue | Official docs | Testnet/demo host | Recordings |
|---|---|---|---|
| Alpaca | [Trading API](https://docs.alpaca.markets/) | `https://paper-api.alpaca.markets` | tagged live integration |
| Binance | [Spot API](https://developers.binance.com/en/docs/products/spot) | `https://testnet.binance.vision` | `test/fixtures/responses/binance/` |
| Binance COIN-M | [COIN-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-coin-futures) | `https://demo-dapi.binance.com` | `test/fixtures/responses/binancecoinm/` |
| Binance USD-M | [USD-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures) | `https://demo-fapi.binance.com` | `test/fixtures/responses/binanceusdm/` |
| Bybit | [V5 API](https://bybit-exchange.github.io/docs/v5/intro) | `https://api-testnet.bybit.com` | `test/fixtures/responses/bybit/` |
| Deribit | [API v2](https://docs.deribit.com/) | `https://test.deribit.com` | `test/fixtures/responses/deribit/` |
| Derive | [API reference](https://docs.derive.xyz/) | `https://api-demo.lyra.finance` | `test/fixtures/responses/derive/` |
| Hyperliquid | [API reference](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api) | `https://api.hyperliquid-testnet.xyz` | `test/fixtures/responses/hyperliquid/` |
| Lighter | [API reference](https://apidocs.lighter.xyz/) | `https://testnet.zklighter.elliot.ai` | reality manifests + accepted-request goldens |
| OKX | [API v5](https://www.okx.com/docs-v5/en/) | `https://www.okx.com` + `x-simulated-trading: 1` | `test/fixtures/responses/okx/` |

Artifact **freshness**, **expressiveness** and **scope** are separate axes. A maintained Postman collection can be current but untyped; a frozen OpenAPI can be richly typed but stale. A manifest pin proves which bytes were reviewed, not that the artifact is complete.

**Missing coverage fails open.** A declared unified read without an authored parse slice can return the provider's raw transport envelope inside `{:ok, ...}`; an operation absent from the authored spec is invisible even to that guard. Completeness work must measure both boundaries.

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) and any dispatch run.

- **`mix check.dispatch`** — the dispatch-scale gate: `precommit`, `ccxt.oracle_gate`, `ccxt.check_lighter_signer`, the domain-boundary guard, `ex_dna --max-clones 0`, `reach.check --arch --smells --strict`. No dialyzer (a cold worktree cold-builds the PLT for minutes).
- **`mix precommit`** — lean local commit gate (format / compile --warnings-as-errors / credo --strict / doctor --raise / sobelow --skip / offline `test.json`).
- **`mix precommit.full`** — adds `deps.audit` + dialyzer (local pre-PR).
- **`mix ci`** — `check.dispatch` + `deps.audit` + dialyzer.

`--cover` is omitted from all of them; run it explicitly (`mix test.json --cover`) per the critical-rules coverage gate.

| Check | Command | Notes |
|-------|---------|-------|
| Compile | `mix compile --warnings-as-errors` | silent finish = success |
| Tests | `mix test.json --quiet` | **emits JSON by design** — parse it for real failures; the envelope is **not** a build error. Read `summary.result` / `summary.failed`. Most integration tests are excluded without `--include` tags. |
| Reality oracle | `mix ccxt.oracle_gate` | Verifies registered response recordings, accepted-request goldens and recorded exchange errors. |
| Domain boundary | `mix test.json test/bourse/domain_boundary_test.exs` | The client must never depend on the trading domain. |
| Dialyzer | `mix dialyzer.json --quiet` | **emits JSON by design**. Plain `mix dialyzer` is the authoritative fallback when the JSON encoder can't serialize a warning shape. |
| Lint | `mix credo --strict` | |
| Security | `mix sobelow` | honors `.sobelow-skips` (hash-based), **not** inline comments |
| Docs | `mix doctor` | |
| Authority corpus | `mix ccxt.authority_check [--online]` | validates the pinned corpus offline; `--online` checks mutable upstreams for drift |
| Error mappings | `mix ccxt.error_authority` | reconciles provider-documented error codes with authored mappings |

**Do not reject a run because `mix test.json` / `mix dialyzer.json` printed JSON** — that is the intended output format, not a failure.

## Running tests

```bash
mix test.json --quiet --failed                       # default iteration
mix ccxt.oracle_gate                                 # manifest-registered reality oracle
mix test.json --quiet --include network              # integration probes (testnet env required)
mix test.json --quiet --only unified_integration     # unified integration probes
mix ccxt.classify_signing                            # signing classification report
mix ccxt.verify_live_drift                           # recordings vs live venue drift
```

> **⚠️ `mix test.json` silently excludes most integration tests by default.** A green run with no `--include` tags covers offline unit + signing tests only. Tags: `integration`, `network` (testnet REST probes), `dangerous` (raw POST/PUT/DELETE), `invalid_creds`, `capability_live`, `option_readiness`, `known_defect`, `native`.

> **⚠️ `:known_defect` quarantine tag — governed, must only shrink.** A test may carry it ONLY when its assertion states the CORRECT expectation, the product is wrong, and the tag comment names the tracking issue. Never weaken an assertion to avoid the tag, and never use it to park a red whose root cause is untracked.

**Per-exchange module split:** `raw_endpoint_probe_test.exs` and `unified_method_integration_test.exs` generate one module per exchange per auth class. `PrivateTest` / `PrivateDangerousTest` gate on a `setup_all` that raises once when creds aren't registered — a missing-creds exchange produces a single module-level flunk instead of N per-endpoint flunks. `PublicTest` / `PublicDangerousTest` always run.

**`Bourse.Testnet` is not an application child.** It is a sandbox-only ETS credential registry that consumers must not boot; `test/test_helper.exs` starts it explicitly via `start_link/1`.

### Testnet credentials

Loaded via `Bourse.Testnet.register_all_from_env/1` in `test_helper.exs`. Env convention `{EXCHANGE}[_{SANDBOX}]_TESTNET_API_KEY/_API_SECRET`, with documented exceptions below. All ten venues are provisioned.

- **Alpaca** — `ALPACA_API_KEY/SECRET`; `sandbox: true` resolves `paper-api.alpaca.markets`. Never point the lifecycle test at the live-money host.
- **Bybit** — `BYBIT_TESTNET_API_KEY/SECRET` is **READ-ONLY**: the testnet key returns business error 10024 on any signed create (region-restricted). Don't burn a probe cycle rediscovering this. **Trade evidence runs on DEMO instead**: `BYBIT_DEMO_API_KEY/SECRET`, host `https://api-demo.bybit.com` — which is **not** `sandbox: true` (that's testnet); pass `base_url:` on the call. Requests omitting `category` fail with 10032.
  - Option orders REQUIRE `orderLinkId` (10001 without it; linear doesn't). Nearest-expiry options are **USDT-settled**.
  - **A SHORT option can become unclosable — pick the instrument for the close, not the open.** Bybit enforces a mark-relative price band (`110003`), and deep-OTM/far-expiry demo books have a single ask far outside it, so a short that filled cannot be bought back at any accepted price (observed 2026-07-25). Select an instrument whose ask sits *inside* the band before selling.
  - **Option TP/SL is `POST /v5/position/trading-stop` only, and an omitted leg CLEARS the other one** under `tpslMode: "Full"` (verified live: a call carrying only `takeProfit` silently wiped the existing `stopLoss`, retCode 0). Always send both legs when amending either. `triggerPrice` on `/v5/order/create` is silently ignored for options.
  - `GET /v5/account/fee-rate` is unusable on demo (empty list with retCode 0 for options, HTTP 400 for linear) — measure fees from actual fills.
- **Deribit** — `DERIBIT_TESTNET_API_KEY/SECRET`.
- **Binance spot** — `BINANCE_TESTNET_API_KEY/SECRET`.
- **Binance USD-M / COIN-M** — the **same** `BINANCE_FUTURES_TEST_API_KEY/SECRET` pair authenticates both (`_TEST_` is a silent fallback for `_TESTNET_`). `demo-dapi.binance.com` and the legacy `testnet.binancefuture.com` are one account, not two environments. **COIN-M and USD-M are separate wallets inside that one account**, and the UI faucet credits USD-M only — a drained COIN-M wallet is re-funded through the UI. The account runs **Hedge Mode**, so orders REQUIRE an explicit `positionSide` (omitting it fails `-4061`; oversized fails `-2019` — both real pinnable business errors). `BTCUSD_PERP` is inverse, 100 USD notional per contract. `DELETE /dapi/v1/allOpenOrders` returns `code 200` even with nothing resting, so it is a safe idempotent cleanup hook.
- **OKX — international demo is canonical.** `OKX_INTL_API_KEY` / `_API_SECRET` / `_PASSPHRASE`, host `www.okx.com` + `x-simulated-trading: 1` (both supplied by `sandbox: true`). The same key on live returns 50101. Option orders at `acctLv 3` require `tdMode: "isolated"`; demo option books carry no two-sided ATM liquidity, so order-accept/cancel is the available lifecycle. **Sharp edge:** batch envelopes report `code "1", msg "All operations failed"` with the real per-order `sCode`/`sMsg` only in `data[0]`. Never use `my.okx.com` or `OKX_TESTNET_*` for new probes — historical EEA recordings remain valid provenance only.
- **Lighter** — DEX (zk perp), not an HMAC pair: `LIGHTER_TESTNET_API_KEY_INDEX` (0–255), `LIGHTER_TESTNET_ACCOUNT_INDEX`, `LIGHTER_TESTNET_API_PRIVATE_KEY` (40-byte hex). Signing is zk-Schnorr through the supervised first-party helper (`Bourse.Signing.Lighter` + `native/lighter_signer/`) — there is no in-Elixir signer. `sandbox: true` selects the testnet host **and** chain id 300 (mainnet is 304; the chain id is part of the signed payload, so a mainnet-chain signature is rejected on testnet). Private reads need an `auth_deadline` and `account_index`; writes need a caller-supplied `nonce` from `public_get_nextnonce` plus a `client_order_index`. Only `limit` orders are supported.
- **Hyperliquid** — DEX; "creds" = an EVM wallet. `HYPERLIQUID_TESTNET_API_KEY` = wallet address, `_API_SECRET` = its private key. Testnet funded via the official drip (`POST /info {"type":"claimDrip","user":…}`, unlocked by a ≥5 native-USDC mainnet Bridge2 deposit from the same address; re-claimable every 4h).
- **Derive** — DEX (Lyra v2). `DERIVE_TESTNET_API_KEY` = the **Derive smart-contract wallet** (what `X-LyraWallet` must carry, NOT the owner EOA); `DERIVE_TESTNET_API_SECRET` = a **registered Admin session key's** private key. REST base `api-demo.lyra.finance`. **Sharp edge:** Derive's edge proxy verifies auth *before* the app — the signer must equal `X-LyraWallet` or be a registered session key for it, else nginx returns HTML 403 with no JSON. The owner EOA is NOT auto-registered on UI onboarding, so a plain owner signature 403s.
  - Order placement: the order endpoints carry `body_encoding: "json"`, so dispatch JSON-encodes params *before* the signer runs — sign the eight-field tuple yourself with `sign_order(order, private_key: ..., testnet: true)` and put the `"signature"` string in params. `max_fee` is required AND has a dynamic floor (~1.5 USDC; error 11023 names the exact minimum) and is part of the signed hash, so re-sign after adjusting. The request also needs `"signer"` (the session key's EOA address), `nonce` (ms), `signature_expiry_sec`, and the trade-module data hash built from `base_asset_address`/`base_asset_sub_id`.

## Do NOT edit (generated) / DO author (frozen specs)

- `lib/bourse/exchanges/*.ex` — generated at compile time; never hand-edit (fix the generator).
- `priv/specs/json/output/authored/<venue>.json` — **the complete hand-owned runtime documents** (ten venues, schema version `3`). These you DO edit, by authoring per the loop in `docs/authored-specs.md`, then proving green with `mix ccxt.oracle_gate`.
- `priv/specs/json/output/<venue>.json` — frozen CCXT-derived **reference** siblings (the 15-venue slice), pinned by `reference_corpus.json`. Never loaded at runtime, never shipped in the Hex package; read-only authoring/test input (e.g. the test-only `markets.symbols_index` used by integration symbol selection).
- `priv/reference_cache/` — vendored market/currency slice for `Bourse.ReplayExchange`. Compatibility reference only; the one module that reads it.

## Architecture

```
Bourse.fetch_ticker(exchange, "BTC/USDT")     # Unified API
    → Bourse.Bybit (generated module)          # use Bourse.Exchange, spec: "bybit"
        → Bourse.Dispatch.call/4               # Shared dispatcher
            → Bourse.Signing.sign/4            # 8 patterns
            → Bourse.HTTP.request/4            # Req wrapper
            → Bourse.Parser.apply_mappings/3   # Field mapping
```

- **Macro generation:** `use Bourse.Exchange, spec: "bybit"` loads the JSON spec at compile time → generates endpoints, introspection, Descripex wiring.
- **Shared dispatch:** generated functions are thin wrappers around `Bourse.Dispatch.call/4`.
- **Judgment is authored, never inferred at runtime.** The heuristic-interpretation layers are deleted: no `Recipe.resolve`, no `Symbol.classify_pattern/2`, no consumer custom-signer escape hatch, no signing classifier. The runtime reads `auth.sign_recipe` through `Bourse.Signing.HmacRecipe`, symbol patterns from authored `markets.symbol_patterns`, and emulated methods from the authored slice.

### Key modules

| Module | Purpose |
|--------|---------|
| `Bourse` | Unified API entry — 242 methods + bang variants + Descripex `api()` + `describe/0-2`. Generated from `Unified.method_defs/0`. |
| `Bourse.Unified` | Internal dispatch: `method_defs/0` (4-tuples), `call/5`, `split_opts/1`, `build_params/3`. Not public. |
| `Bourse.Exchange` | Config struct + constructor + generator macro. Carries `:tier`, `:module` (O(1) dispatch), `signing_pattern`, `signing_config`, `symbol_patterns`, `error_body_checks`, `error_code_fields`. |
| `Bourse.Spec` | Compile-time JSON spec loader. Enforces owned `schema_version` `3`. One complete owned document per venue — no base/overlay merge, no CCXT-base fallback. |
| `Bourse.Spec.Schema` | Owned runtime-schema contract. Required/forbidden slot table; raises `owned spec "<venue>" gap <path>` on any missing/null/empty/forbidden slot. |
| `Bourse.Symbol` | Bidirectional symbol normalization, driven by the authored `markets.symbol_patterns` slice. |
| `Bourse.Error` | `defexception` — 17 error types covering 34 compatibility exception classes. Pattern-matchable AND raiseable. |
| `Bourse.Dispatch` | Runtime dispatcher: path interpolation, base URL resolution (4 patterns), signing, HTTP delegation. |
| `Bourse.HTTP` | Req wrapper — manual query encoding, safe retry GET/HEAD only, telemetry, circuit breaker. |
| `Bourse.RateLimiter` | Per-credential weighted GenServer, sliding window. Key `{exchange, api_key \| :public}`. |
| `Bourse.ReplayExchange` | Offline replay exchange from `priv/reference_cache/`. The **only** module reading the vendored slice. |
| `Bourse.RecordedResponseFixtures` | Capture support and path resolution for the committed reality evidence. |
| `Bourse.Application` | Supervises `Bourse.RateLimiter` + `Bourse.RateLimiter.State` + `Bourse.Signing.Lighter.Supervisor` + `Bourse.WS.Broadcast`. |

**Unified response types:** 7 original (`Ticker`, `Trade`, `Order`, `Balance`, `Market`, `OHLCV`, `Fee`), 9 tier-1 core (`OrderBook`, `Position`, `Currency`, `Transaction`, `LedgerEntry`, `FundingRate`, `DepositAddress`, `TransferEntry`, `TradingFee`), 9 tier-2 derivatives, 9 tier-3 analytics.

**Signing:** `Bourse.Signing` dispatches 8 patterns — `:hmac_sha256_query`, `:hmac_sha256_headers`, `:hmac_sha256_iso_passphrase`, `:api_key_secret_headers` (Alpaca), `:deribit`, `:hyperliquid`, `:derive`, `:lighter`. The authoritative table lives in the module's `@moduledoc`.

**WebSocket:** `Bourse.WS` wraps `ZenWebsocket.Client`. **7 of the ten venues are configured and confirmed streaming live** (binance, binanceusdm, bybit, deribit, derive, hyperliquid, okx); alpaca/binancecoinm/lighter have no WS config and `connect/3` answers `{:error, :unsupported_exchange}`. **Known gap: the private path does not authenticate** — `Bourse.WS.Adapter`, which invokes the auth patterns, has no caller from the facade. `subscribe/3` returns `:ok | {:error, term()}` and surfaces venue rejections as `{:error, {:subscription_rejected, frame}}`.

### Critical design decisions

**HTTP pipeline:** manual query encoding (signing needs raw params — don't use Req's `:params`); safe retry GET/HEAD only (never POST/PUT/DELETE — duplicate orders); per-credential rate limiting for multi-user isolation.

**Exchange struct:** config, not process — pure data, no GenServer. String keys matching the JSON spec.

**Errors:** two-tier matching — `error_codes` (exact) plus `broad_error_patterns` (substring), pre-processed at construction. `error_body_checks` for top-level sentinels; `error_code_fields` for exact-code probe order.

**Dispatch:** symbol denormalization happens in `Unified.call/5`, NOT `Dispatch.call/4` — raw callers pass through untouched. Required params always win over opts (`Map.put_new` prevents silent override in trading calls).

**Authored `path_params` descriptors are `%{"name", "source"}` and `source` is ALWAYS `"params"`** — verified 1668/1668 across the catalog. `interpolate_path/3` resolves from the params map by `"name"` and deliberately ignores `source`. This is a relied-on invariant: if an authored spec ever sets a path-param source to anything else, resolving from `params` silently reads the wrong place. The fix is not to pre-build unused branches but to make the day-it-changes failure LOUD — `path_param_name/1` should match `%{"source" => "params"}` and let any other shape hit a raising clause.

**Durable kernel:** when data is finite, verifiable, and fails silently when wrong, **author it explicitly — don't infer it at runtime.** `HmacRecipe` stays as the deterministic recipe *executor* (mechanism, not judgment); author recipes into its shape rather than rebuild a signer.

## The trading domain layer

`Bourse.OptionProposal`, `Bourse.OptionReadiness`, `Bourse.OptionSaga`, `Bourse.PortfolioRisk` live here but are **not part of the client's surface**. `mix.exs` keeps them out of the Hex package, and `test/bourse/domain_boundary_test.exs` (wired into `check.dispatch`) asserts the dependency stays one-directional: **the domain may call the client, never the reverse.**

That guard is why the layer can stay. It was introduced while the invariant already held, so it costs no refactor — and as long as it is green, moving the domain into its own repo remains a file move rather than a refactor. **A single inbound edge turns it into one**, so don't "temporarily" reach into the domain from client code.

## Git commit configuration

Conventional commits: `<type>(<scope>): <description>`. Types: feat, fix, docs, style, refactor, test, chore. Title-only; bodies only when asked. No `Co-Authored-By` footers.
