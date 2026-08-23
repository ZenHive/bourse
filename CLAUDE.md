# CLAUDE.md

Guidance for Claude Code working in this repository.

## Active Includes

Eager-load only the irreducible floor; everything else is skill-on-demand via enabled plugins. **Don't double-load** (an `@`-import plus its sibling skill pays twice for the same tokens).

- **`critical-rules`** — hard guardrails that must stay ambient every session (a guardrail the model invokes "when relevant" fails exactly when it doesn't realize the rule applies).
- **`ex-unit-json`** — `mix test.json` is the test runner every session uses; its flight-recorder semantics and the "JSON-by-design — parse for real failures, never reject the envelope" rule are load-bearing for cross-family reviewers.
- **`harness-workflow`** — this repo IS registered for harness dispatch (see below). Its guardrails fail by non-recognition (`Recover, Don't Redo`; `Settle ≠ landed`; the duplicate-land trap), so a skill-on-demand load is not equivalent.

@~/.claude/includes/critical-rules.md
@~/.claude/includes/ex-unit-json.md
@~/.claude/includes/harness-workflow.md

(`response-conventions` loads globally via `~/.claude/CLAUDE.md` — not re-imported here.)

## What this repository is

`bourse` (`:bourse`, namespace `Bourse.*`) — an Elixir client for eleven exchange integrations: `alpaca`, `binance`, `binancecoinm`, `binanceusdm`, `bybit`, `coinbaseexchange`, `deribit`, `derive`, `hyperliquid`, `lighter`, `okx`. One complete hand-authored JSON spec per venue drives macro-generated endpoint modules; the three DEX venues carry hand-written signing. Coinbase Exchange is deliberately public-only and exposes candles plus ticker.

Runtime support is a **closed set**. `Bourse.Exchanges` and `Bourse.Registry` read `priv/specs/json/runtime_support.json` and generate exactly eleven modules; constructing anything else fails immediately with `unsupported_exchange`. There is no `config :bourse, exchanges:` knob — support is not a configuration outcome.

### 🚧 The workbench boundary — read this before deciding where work goes

This repo was extracted from `../bourse_workbench`, which remains the **authoring workbench**. The split is by question, not by file type:

| Question | Repo |
|---|---|
| Does the client behave correctly against a supported venue? | **here** |
| Is a supported venue's authored spec right? | **here** — the spec, its authority manifest and its reality evidence all live here |
| Does an eleventh venue get added? | **here** — `mix ccxt.promote_venue` grades its candidate against the reality manifests, and those live here. Pass the pinned CCXT reference document in from the workbench with `--reference`. |
| Did the full CCXT reference extraction shift across all 110 venues? | workbench — this repo carries a 16-venue slice and cannot answer corpus-wide questions |
| Roadmap and task scoring, and the CHANGELOG gate that reads it | workbench — one rmap, declaring `project = "bourse"`. It is not a workbench roadmap that mentions this client; it **is** this client's roadmap. Do **not** stand up a second rmap here. |
| Where does a consumer file a bug? | **here**, in `BUGS.md` — this is the only repo a consumer knows. Triage into scored tasks happens in the workbench, and writes a dated note back into the entry. |

#### 🚨 The roadmap admits reported defects — quality work against the API surface has no end

Eleven venues times ~240 unified methods is an effectively unbounded surface. A live
measurement, a reviewer proposal or a coverage sweep will *always* find one more true
thing, and every one of those findings is real. That is precisely why "is it real"
cannot be the filter: it rejects nothing, so the backlog stops converging. Measured on
this project — 103 tasks filed against 101 landed across fourteen days, and fifteen
tasks created in one day (647–661), several of them grandchildren of a single stack
trace.

**A finding enters the workbench roadmap only when a consumer reported the defect.**
Everything else — a drift you measured live, a reviewer's `proposed_tasks`, an
uncovered branch, a carve you would author differently — goes into `BUGS.md` with its
evidence and stops there. `BUGS.md` is the durable record; the roadmap is the work
queue, and they are not the same list.

- ✅ DO: append the measurement to `BUGS.md` with the exact call, the observed value and the expected one. That preserves the finding at zero dispatch cost.
- ✅ DO: fix it inline and say so when it is bounded and local. A finding you can close in minutes never needed a task.
- ❌ DO NOT: file because a finding is genuine, evidenced and cross-session. Those are the floor, not the bar — they admit everything.
- ❌ DO NOT: promote a reviewer proposal on the strength of its shape. Proposals arrive pre-scored and dispatch-ready; that is a rendering choice, not a routing decision.

**Security and data-loss defects are filed on discovery** regardless of who found
them, sanitized per `critical-rules.md` § NEVER BROADCAST AN UNPATCHED VULNERABILITY.

This tightens the portfolio-wide Default-DECLINE bar in `harness-workflow.md`, which
governs whether a proposal is *worth* filing. Here the question is prior: whether the
roadmap is the right destination at all.

#### Where harness runs from — three locations, none of them optional

`bourse` is registered in `Harness.ProjectRegistry`, and the registration is what
resolves the split. Verify it with `project_registry-list` rather than guessing:

| Role | Location | Registry field |
|---|---|---|
| The harness BEAM | `~/_DATA/code/harness` (`iex -S mix`) | — never the target repo |
| Code — what gets forked, reviewed and landed | `~/_DATA/code/bourse` | `source` |
| Roadmap — what gets read, scored and status-written | `~/_DATA/code/bourse_workbench` | `roadmap_path` |

**Harness resolves `roadmap_path` itself** — `Harness.Roadmap` shells `rmap` there
and owns durable roadmap writes into that repo. A dispatch call passes
`project: "bourse"` and nothing else; the orchestrator never shuttles task state
between the two checkouts by hand.

**Drive the loop from this repo.** The dispatched work is bourse code, and
verification needs what only lives here: `mix check.dispatch`, the testnet
credentials, the venue authority index, and this file's doctrine. Sit in the
workbench only for deliberate roadmap surgery, where `rmap` wants to be cwd.

🚨 **The two repo locations above are doctrine; every other registration value is
not written down here on purpose.** `check_command`, `concurrency_cap`,
`landing_policy`, `target_branch`, `reviewer` and the model pins are operator
settings that change without anyone thinking about this file — a copy of them here
would be stale duplication with no gate to catch it, and the registry is on this
host only, so no CI check can ever guard it. Read them from
`project_registry-list`, which is the authority. Never quote them into a doc.

**Consequences that bite if forgotten:**

- **Read `BUGS.md` before chasing a reported defect.** It is the inbound consumer queue, newest first, and each entry carries a `**Status:**` header — the bug in front of you may already be filed, already fixed, or already decided against. Entries are never deleted; a fixed one keeps its repro as the evidence trail.

- One test deliberately stayed in the workbench because it is corpus-wide: the zero-param JSON-body gate audit, which asserts a gate set across all 110 reference specs. The same applies to anything else that iterates every document under `priv/specs/json/output/` expecting the full set. **Do not re-add a corpus-wide audit here** — it would be answering a 110-venue question with 15 specs.
- `priv/specs/json/reference_corpus.json` honestly declares the 16 carried venues (the eleven supported plus `coinmetro`, `deepcoin`, `kraken`, `weex`, `whitebit`, used as parser and unsupported-venue counter-examples). Its two SHA-256 pins still name the upstream revision the slice came from, so provenance stays verifiable. **Adding a reference venue means adding its JSON *and* the manifest entry** — `Bourse.ReferenceSlice` validates count, sort order and pins, and raises otherwise. That module lives in `test/support/`, not `lib/`: the slice is test input, so neither the client nor the Hex package can reach it.

## 🎯 Core doctrine: provider-authoritative, reality-verified

**Interpret, don't extract.** Full model and rationale: `docs/authored-specs.md` — read it first.

**The one and only reality is the exchange APIs we talk to** — not CCXT, not CCXT's fixtures, not training. CCXT was the bootstrap; it is now **one disposable reference among several** (exchange API docs, official SDKs, observed behavior). The DEX venues already live this way. Three axes, kept distinct: **value** correctness (is the number right vs reality), **carve** correctness (is the field/abstraction itself right, willing to *diverge* from CCXT's ontology), and **freshness** (frozen recordings kept honest by live drift checks).

**Authority ladder — the exchange-owned contract wins.** A live venue call establishes what the venue does; the exchange's own documentation, specifications and SDKs establish what its fields and parameters mean. CCXT source, execution and static files are unverified authoring references only.

**Provenance for every external API claim — this order, not the reverse:**

1. Live E2E against the real host (testnet/demo; production public for Coinbase Exchange).
2. Understand one success **and** one relevant error from that interaction.
3. Write an integration test (`--include network` / `--include dangerous`) that hits the same host and asserts those semantics.
4. Only then, if CI needs a fast offline replay, derive a fixture from that captured interaction.

No mock or recording may invent behavior. Every expectation traces to a documented real call. The offline suite is a replay cache of reality, not its authority. `mix ccxt.oracle_gate` grades that cache so it does not rot; it does **not** verify a new method. A recording in the same diff as the spec it certifies is the Deribit-`"8h"` bug.

**Verification is binary.** A claim is `verified` only after steps 1–3, plus provider-owned meaning. Otherwise it is `unverified`. CCXT JS cannot verify venue semantics.

### Rules

- ✅ DO: author interpretive slices against the exchange-owned API contract, using CCXT only as reference material. Keep `mix ccxt.oracle_gate` green for **existing** goldens — do not add a fixture to make a new method look verified.
- ✅ DO: verify by **running/observing**; author by **reading** any source. A source that fed authoring cannot also be the oracle.
- ✅ DO: run the **confrontation step** when authoring a venue slice (`docs/authored-specs.md`) — for each schema decision, confront the CARVE (does the field exist here? what does the value mean? is the abstraction right for this venue?) against the exchange's OWN semantics. Record every CONFIRMED / DIVERGE outcome in the venue's carve register under `docs/authored-spec-carves/`. A CCXT carve adopted without a register entry is inherited, not confronted.
- 🚨 DO: keep it REAL — for divergence-prone fields (anything CCXT *computes* or *branches* rather than copies: precision, inverse-vs-linear cost, funding cadence, fee tiers), test against the **REAL API plus a non-CCXT semantic source**, never against a potentially-wrong CCXT fixture. A wrong fixture is *more costly* than a live call: it certifies our bug green and silent. The canonical case: deribit's funding `interval` was the authored literal `"8h"` while the venue publishes hourly — internally consistent, fully tested, and wrong, because the golden was computed with the same wrong constant.
- 🚨 DO: **decolor on touch.** Comments, moduledocs and docs that cite CCXT as the *reason or authority* for a decision steer every future session back toward CCXT-as-truth. Never write a new one. `test/bourse/ccxt_authority_language_test.exs` enforces this with an explicit allowlist — a new CCXT mention in `lib/` fails the suite until it is either reworded or allowlisted with a compatibility-framed phrase.
- ✅ DO: when a live call is **unreachable with our keys/hosts** (prod-only endpoint, region-restricted key, needs a real open position), append an entry to `docs/prod-verification-ledger.md`. The slice stays `unverified` until a live call exists.
- ❌ DO NOT: write `test/fixtures/**`, call `Bourse.RecordedResponseFixtures`, or add a manifest row in the same change as the spec or parser under test. That recording is not independent evidence.
- ❌ DO NOT: treat CCXT-derived data or training/web as verification. Independence comes from execution/reality, not a second read.
- 🚨🚨 DO (behavioral default, anchored to the ACTION): **when you set out to check whether a venue "works," your FIRST call hits the LIVE venue.** Use testnet/demo for credentialed venues and the production public host for public-only Coinbase Exchange. Recipe: `creds = Bourse.Credentials.new!(api_key: System.get_env("DERIBIT_TESTNET_API_KEY"), secret: ...); {:ok, ex} = Bourse.Exchange.new("deribit", credentials: creds, sandbox: true)` → then a real `Bourse.fetch_ticker/fetch_balance`. Testnet credentials for all ten credentialed venues are provisioned (below); Coinbase Exchange needs none.

### Venue authority index

Any venue-source, contract-coverage or field-judgment question opens `priv/authority/<venue>/` **FIRST**. The manifest is the local provenance index, not the authority itself: when the question is discovery or freshness, check the provider's official upstream next. Manifests record URL, upstream revision, retrieval date, byte count, SHA-256 and licensing disposition.

| Venue | Official docs | Testnet/demo host | Recordings |
|---|---|---|---|
| Alpaca | [Trading API](https://docs.alpaca.markets/) | `https://paper-api.alpaca.markets` | tagged live integration |
| Binance | [Spot API](https://developers.binance.com/en/docs/products/spot) | `https://testnet.binance.vision` | `test/fixtures/responses/binance/` |
| Binance COIN-M | [COIN-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-coin-futures) | `https://demo-dapi.binance.com` | `test/fixtures/responses/binancecoinm/` |
| Binance USD-M | [USD-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures) | `https://demo-fapi.binance.com` | `test/fixtures/responses/binanceusdm/` |
| Bybit | [V5 API](https://bybit-exchange.github.io/docs/v5/intro) | `https://api-testnet.bybit.com` | `test/fixtures/responses/bybit/` |
| Coinbase Exchange | [Exchange REST API](https://docs.cdp.coinbase.com/api-reference/exchange-api/rest-api/products) | production public only | `test/fixtures/responses/coinbaseexchange/` |
| Deribit | [API v2](https://docs.deribit.com/) | `https://test.deribit.com` | `test/fixtures/responses/deribit/` |
| Derive | [API reference](https://docs.derive.xyz/) | `https://api-demo.lyra.finance` | `test/fixtures/responses/derive/` |
| Hyperliquid | [API reference](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api) | `https://api.hyperliquid-testnet.xyz` | `test/fixtures/responses/hyperliquid/` |
| Lighter | [API reference](https://apidocs.lighter.xyz/) | `https://testnet.zklighter.elliot.ai` | reality manifests + accepted-request goldens |
| OKX | [API v5](https://www.okx.com/docs-v5/en/) | `https://www.okx.com` + `x-simulated-trading: 1` | `test/fixtures/responses/okx/` |

Artifact **freshness**, **expressiveness** and **scope** are separate axes. A maintained Postman collection can be current but untyped; a frozen OpenAPI can be richly typed but stale. A manifest pin proves which bytes were reviewed, not that the artifact is complete.

**Missing coverage fails open.** A declared unified read without an authored parse slice returns `{:ok, %Bourse.RawResponse{}}` labelled with the provider payload, venue, method, and verification state; an operation the provider does not offer is invisible to that guard and a raw parse slot answers `{:error, {:unsupported_operation, slot}}`. Completeness work must measure both boundaries.

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) and any dispatch run.

- **`mix check.dispatch`** — the dispatch-scale gate: `precommit`, `ccxt.oracle_gate`, `ccxt.check_lighter_signer`, `ccxt.claude_check`, `ccxt.agents_md --check`, `ccxt.authority_check` (offline), `ccxt.error_authority`, the domain-boundary guard, `ex_dna --max-clones 0`, `reach.check --arch --smells --strict`. No dialyzer (a cold worktree cold-builds the PLT for minutes).
- **`mix precommit`** — lean local commit gate (format / compile --warnings-as-errors / credo --strict / doctor --raise / sobelow --skip / offline `test.json`).
- **`mix precommit.full`** — adds `deps.audit` + dialyzer (local pre-PR).
- **`mix ci`** — `check.dispatch` + `deps.audit` + dialyzer.

`--cover` is omitted from all of them; run it explicitly (`mix test.json --cover`) per the critical-rules coverage gate.

| Check | Command | Notes |
|-------|---------|-------|
| Compile | `mix compile --warnings-as-errors` | silent finish = success |
| Tests | `mix test.json --quiet` | **emits JSON by design** — parse it for real failures; the envelope is **not** a build error. Read `summary.result` / `summary.failed`. Most integration tests are excluded without `--include` tags. |
| Reality oracle | `mix ccxt.oracle_gate` | Replays already-registered recordings, accepted-request goldens and recorded exchange errors. Does not verify a new method. |
| Dialyzer | `mix dialyzer.json --quiet` | **emits JSON by design**. Plain `mix dialyzer` is the authoritative fallback when the JSON encoder can't serialize a warning shape. |
| Lint | `mix credo --strict` | |
| Security | `mix sobelow` | honors `.sobelow-skips` (hash-based), **not** inline comments |
| Docs | `mix doctor` | |
| Authority corpus | `mix ccxt.authority_check [--online]` | validates the pinned corpus offline; `--online` checks mutable upstreams for drift |
| Error mappings | `mix ccxt.error_authority` | reconciles provider-documented error codes with authored mappings |
| CLAUDE claims | `mix ccxt.claude_check` | modules / `mix ccxt.*` tasks / repo paths named in gated CLAUDE.md regions, plus the signing pattern list and `Application` children, vs the tree. Unlisted tree surfaces are not failures. |
| AGENTS freshness | `mix ccxt.agents_md --check` | re-renders CLAUDE.md + the pinned `@`-imports (`priv/agents_includes/`) and fails on drift. Regenerate with `mix ccxt.agents_md`. |

**Venue promotion** — adding an eleventh venue is a graded promotion, never a config flag:

```bash
mix ccxt.promote_venue --prepare --reference REF --candidate CANDIDATE --report REPORT
mix ccxt.promote_venue --check   --candidate CANDIDATE --report REPORT [--reference REF]
```

`REF` is a pinned CCXT reference document — supply it from the workbench corpus; this repo carries only a 16-venue slice. The task creates and grades a candidate, and never adds runtime support on its own. Its evidence report uses one binary vocabulary: `verified` requires provider-owned semantics *plus* manifest-registered reality for every critical slot; everything else is `unverified`. `--check` re-derives the method inventory from the reference, byte-verified against `report.reference.sha256`.

**Do not reject a run because `mix test.json` / `mix dialyzer.json` printed JSON** — that is the intended output format, not a failure.

## Running tests

```bash
mix test.json --quiet --failed                       # default iteration
mix ccxt.oracle_gate                                 # manifest-registered reality oracle
mix ccxt.verify_rest_read_contracts                  # all 427 provider-live REST-read contracts
mix test.json --quiet --include network              # integration probes (testnet env required)
mix ccxt.classify_signing                            # signing classification report
mix ccxt.verify_live_drift                           # recordings vs live venue drift
mix ccxt.verify_ws_first_frame                       # classified public WS first data frame per venue
mix ccxt.aggregate_live_lane                         # merge live-lane surface reports into one artifact
```

> **⚠️ `mix test.json` silently excludes most integration tests by default.** A green run with no `--include` tags covers offline unit + signing tests only. `mix ccxt.verify_rest_read_contracts` is the complete REST-read lane: it explicitly includes all network cases and reports denominator, executed count, and failures. Tags: `integration`, `network` (testnet REST probes), `rest_read_contract`, `dangerous` (raw POST/PUT/DELETE), `invalid_creds`, `option_readiness`, `known_defect`, `native`.

> **⚠️ `:known_defect` quarantine tag — governed, must only shrink.** A test may carry it ONLY when its assertion states the CORRECT expectation, the product is wrong, and the tag comment names the tracking issue. Never weaken an assertion to avoid the tag, and never use it to park a red whose root cause is untracked.

**REST-read contracts:** `priv/authority/rest-read-contracts.json` owns the provider-source pins, operation/branch denominator, arguments, and success/error meanings for all eleven venues. `test/bourse/rest_read_contract_live_test.exs` generates only ExUnit shells; `Bourse.Test.RestReadContractScenario` performs every real call and assertion. The raw endpoint probes remain transport-level coverage for request mechanics and write surfaces.

**`Bourse.Testnet` is not an application child.** It is a sandbox-only ETS credential registry that consumers must not boot; `test/test_helper.exs` starts it explicitly via `start_link/1`.

### Testnet credentials

Loaded via `Bourse.Testnet.register_all_from_env/1` in `test_helper.exs`. Env convention `{EXCHANGE}[_{SANDBOX}]_TESTNET_API_KEY/_API_SECRET`, with documented exceptions below. All ten credentialed venues are provisioned; public-only Coinbase Exchange uses no credentials.

- **Alpaca** — `ALPACA_API_KEY/SECRET`; `sandbox: true` resolves `paper-api.alpaca.markets`. Never point the lifecycle test at the live-money host.
- **Bybit** — `BYBIT_TESTNET_API_KEY/SECRET` is **READ-ONLY**: the testnet key returns business error 10024 on any signed create (region-restricted). Don't burn a probe cycle rediscovering this. **Trade evidence runs on DEMO instead**: `BYBIT_DEMO_API_KEY/SECRET`, host `https://api-demo.bybit.com` — which is **not** `sandbox: true` (that's testnet); pass `base_url:` on the call. Requests omitting `category` fail with 10032.
  - Option orders REQUIRE `orderLinkId` (10001 without it; linear doesn't). Nearest-expiry options are **USDT-settled**.
  - **A SHORT option can become unclosable — pick the instrument for the close, not the open.** Bybit enforces a mark-relative price band (`110003`), and deep-OTM/far-expiry demo books have a single ask far outside it, so a short that filled cannot be bought back at any accepted price (observed 2026-07-25). Select an instrument whose ask sits *inside* the band before selling.
  - **Option TP/SL is `POST /v5/position/trading-stop` only, and an omitted leg CLEARS the other one** under `tpslMode: "Full"` (verified live: a call carrying only `takeProfit` silently wiped the existing `stopLoss`, retCode 0). Always send both legs when amending either. `triggerPrice` on `/v5/order/create` is silently ignored for options.
  - `GET /v5/account/fee-rate` is unusable on demo (empty list with retCode 0 for options, HTTP 400 for linear) — measure fees from actual fills.
- **Deribit** — `DERIBIT_TESTNET_API_KEY/SECRET`.
- **Binance spot** — `BINANCE_TESTNET_API_KEY/SECRET`.
- **Binance USD-M / COIN-M** — the **same** `BINANCE_FUTURES_TEST_API_KEY/SECRET` pair authenticates both (`_TEST_` is a silent fallback for `_TESTNET_`). `demo-dapi.binance.com` and the legacy `testnet.binancefuture.com` are one account, not two environments. **COIN-M and USD-M are separate wallets inside that one account**, and the UI faucet credits USD-M only — a drained COIN-M wallet is re-funded through the UI. The account runs **One-way mode** (verified live 2026-08-10: `GET /fapi/v1/positionSide/dual` → `dualSidePosition: false` — an earlier Hedge-Mode note here was stale), so orders need no `positionSide` and `reduceOnly` is accepted; if the mode is ever flipped to Hedge, orders REQUIRE `positionSide` and fail `-4061` without it. Oversized orders fail `-2019` — a real pinnable business error. `BTCUSD_PERP` is inverse, 100 USD notional per contract. `DELETE /dapi/v1/allOpenOrders` returns `code 200` even with nothing resting, so it is a safe idempotent cleanup hook.
- **OKX — international demo is canonical.** `OKX_INTL_API_KEY` / `_API_SECRET` / `_PASSPHRASE`, host `www.okx.com` + `x-simulated-trading: 1` (both supplied by `sandbox: true`). The same key on live returns 50101. Option orders at `acctLv 3` require `tdMode: "isolated"`; demo option books carry no two-sided ATM liquidity, so order-accept/cancel is the available lifecycle. **Sharp edge:** batch envelopes report `code "1", msg "All operations failed"` with the real per-order `sCode`/`sMsg` only in `data[0]`. Never use `my.okx.com` or `OKX_TESTNET_*` for new probes — historical EEA recordings remain valid provenance only.
- **Lighter** — DEX (zk perp), not an HMAC pair: `LIGHTER_TESTNET_API_KEY_INDEX` (0–255), `LIGHTER_TESTNET_ACCOUNT_INDEX`, `LIGHTER_TESTNET_API_PRIVATE_KEY` (40-byte hex). Signing is zk-Schnorr through the supervised first-party helper (`Bourse.Signing.Lighter` + `native/lighter_signer/`) — there is no in-Elixir signer. `sandbox: true` selects the testnet host **and** chain id 300 (mainnet is 304; the chain id is part of the signed payload, so a mainnet-chain signature is rejected on testnet). Private reads need an `auth_deadline` and `account_index`; writes need a caller-supplied `nonce` from `public_get_nextnonce` plus a `client_order_index`. Only `limit` orders are supported.
- **Hyperliquid** — DEX; "creds" = an EVM wallet. `HYPERLIQUID_TESTNET_API_KEY` = wallet address, `_API_SECRET` = its private key. Testnet funded via the official drip (`POST /info {"type":"claimDrip","user":…}`, unlocked by a ≥5 native-USDC mainnet Bridge2 deposit from the same address; re-claimable every 4h).
- **Derive** — DEX (Lyra v2). `DERIVE_TESTNET_API_KEY` = the **Derive smart-contract wallet** (what `X-LyraWallet` must carry, NOT the owner EOA); `DERIVE_TESTNET_API_SECRET` = a **registered Admin session key's** private key. REST base `api-demo.lyra.finance`. **Sharp edge:** Derive's edge proxy verifies auth *before* the app — the signer must equal `X-LyraWallet` or be a registered session key for it, else nginx returns HTML 403 with no JSON. The owner EOA is NOT auto-registered on UI onboarding, so a plain owner signature 403s.
  - Order placement: the order endpoints carry `body_encoding: "json"`, so dispatch JSON-encodes params *before* the signer runs — sign the eight-field tuple yourself with `sign_order(order, private_key: ..., testnet: true)` and put the `"signature"` string in params. `max_fee` is required AND has a dynamic floor (~1.5 USDC; error 11023 names the exact minimum) and is part of the signed hash, so re-sign after adjusting. The request also needs `"signer"` (the session key's EOA address), `nonce` (ms), `signature_expiry_sec`, and the trade-module data hash built from `base_asset_address`/`base_asset_sub_id`.

## Do NOT edit (generated) / DO author (frozen specs)

- `lib/bourse/exchanges/*.ex` — generated at compile time; never hand-edit (fix the generator).
- `priv/specs/json/output/authored/<venue>.json` — **the complete hand-owned runtime documents** (eleven venues, schema version `3`). These you DO edit, by authoring per the loop in `docs/authored-specs.md`, then proving with a live venue call. `mix ccxt.oracle_gate` must stay green for already-registered goldens; it is not the proof for a new slice.
- `priv/specs/json/output/<venue>.json` — frozen CCXT-derived **reference** siblings (the 16-venue slice), pinned by `reference_corpus.json`. Never loaded at runtime, never shipped in the Hex package; read-only authoring/test input (e.g. the test-only `markets.symbols_index` used by integration symbol selection).
- `priv/reference_cache/` — vendored market/currency slice for `Bourse.ReplayExchange`. Compatibility reference only; the one module that reads it. Neither the cache nor its reader is packaged.

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
| `Bourse` | Unified API entry — 246 methods + bang variants + Descripex `api()` + `describe/0-2`. Generated from `Unified.method_defs/0`. |
| `Bourse.Unified` | Internal dispatch: `method_defs/0` (4-tuples), `call/5`, `split_opts/1`, `build_params/3`. Not public. |
| `Bourse.Exchange` | Config struct + constructor + generator macro. Carries `:tier`, `:module` (O(1) dispatch), `signing_pattern`, `signing_config`, `symbol_patterns`, `error_body_checks`, `error_code_fields`. |
| `Bourse.Spec` | Compile-time JSON spec loader. Enforces owned `schema_version` `3`. One complete owned document per venue — no base/overlay merge, no CCXT-base fallback. |
| `Bourse.Spec.Schema` | Owned runtime-schema contract. Required/forbidden slot table; raises `owned spec "<venue>" gap <path>` on any missing/null/empty/forbidden slot. |
| `Bourse.Symbol` | Bidirectional symbol normalization, driven by the authored `markets.symbol_patterns` slice. |
| `Bourse.Error` | `defexception` — 18 error types covering 34 compatibility exception classes. Pattern-matchable AND raiseable. |
| `Bourse.Dispatch` | Runtime dispatcher: path interpolation, base URL resolution (4 patterns), signing, HTTP delegation. |
| `Bourse.HTTP` | Req wrapper — manual query encoding, safe retry GET/HEAD only, telemetry, circuit breaker. |
| `Bourse.RateLimiter` | Per-credential weighted GenServer, sliding window. Key `{exchange, api_key \| :public}`. |
| `Bourse.ReplayExchange` | **Repo-internal.** Offline replay exchange from `priv/reference_cache/`. The **only** module reading the vendored slice. |
| `Bourse.RecordedResponseFixtures` | **Repo-internal.** Capture support and path resolution for the committed reality evidence. |
| `Bourse.Application` | Supervises `Bourse.RateLimiter` + `Bourse.RateLimiter.State` + `Bourse.Signing.Lighter.Supervisor` + `Bourse.WS.Broadcast` + `Bourse.WS.ConnectionOwner.Supervisor`. |

**Unified response types:** 7 original (`Ticker`, `Trade`, `Order`, `Balance`, `Market`, `OHLCV`, `Fee`), 9 tier-1 core (`OrderBook`, `Position`, `Currency`, `Transaction`, `LedgerEntry`, `FundingRate`, `DepositAddress`, `TransferEntry`, `TradingFee`), 9 tier-2 derivatives, 9 tier-3 analytics.

**Signing:** `Bourse.Signing` dispatches 8 patterns — `:hmac_sha256_query`, `:hmac_sha256_headers`, `:hmac_sha256_iso_passphrase`, `:api_key_secret_headers` (Alpaca), `:deribit`, `:hyperliquid`, `:derive`, `:lighter`. The authoritative table lives in the module's `@moduledoc`.

**WebSocket:** `Bourse.WS` wraps `ZenWebsocket.Client`. **10 of the eleven venues are configured and confirmed streaming live** (alpaca, binance, binancecoinm, binanceusdm, bybit, deribit, derive, hyperliquid, lighter, okx); Coinbase Exchange is the registered config divergence and `connect/3` answers `{:error, :websocket_not_configured}` for it, distinct from `:unsupported_exchange` for a venue outside runtime support. `subscribe/3` returns `:ok | {:error, term()}` and surfaces venue rejections as `{:error, {:subscription_rejected, frame}}`.

**`connect/3` authenticates a `:private` section** through `Bourse.WS.authenticate/2`, and a failed handshake closes the socket rather than returning one — an open unauthenticated private connection fails later as a silently empty stream, not as an error. The accepted handshake is recorded on `ws.auth`, which is what `Bourse.WS.Adapter` schedules renewal from instead of re-running it. Live-verified differentially across six venues (`test/bourse/ws/auth_live_smoke_test.exs`). Alpaca's public market-data section is the documented exception: `auth_sections` includes `:public`, so `connect/3` runs the key/secret handshake there too.

**Not every credential is a frame — some are the URL, and that changes when the handshake runs.** `:listen_key` (binanceusdm, binancecoinm) issues its key over REST *before* the socket opens, so `connect/3` performs the round-trip and connects to the resulting URL; `authenticate: false` is refused with `{:error, {:auth_not_optional, :listen_key}}` because there is no later handshake to run. `Bourse.WS.ListenKey` owns the call and the refresh; `Bourse.WS.Auth.ListenKey` stays network-free endpoint resolution and resolves **generated raw endpoint names**, not CCXT method names — the previous config named methods that match no function here, so it looked resolved and could not be called.

🚨 **A wrong listen key connects.** Verified on `demo-fstream.binance.com` and again on `demo-dstream.binance.com`: a bogus key reports `:connected` throughout and delivers nothing, while a real one delivers `ORDER_TRADE_UPDATE`. So every failure to obtain a key must be an error, never a fallback — and the venue's own checks are weaker than they look: the listen key endpoint is **API-key authenticated and does not verify the secret**, so a differential probe has to corrupt the *api key* to mean anything.

🚨 **The two binance futures halves are two streams, not one.** COIN-M lives on `dstream` (`demo-dstream.binance.com`) and issues its key from `dapiPrivate_*`; USD-M lives on `fstream` and issues from `fapiPrivate_*`. They share one demo account and one API key pair but are separate wallets with separate user data streams, so a socket keyed by the other half's key connects and stays silent — the same failure shape as a bogus key. COIN-M's market type is `:inverse` (`:delivery` normalizes to it); its `PUT listenKey` returns the key in the body where USD-M returns `{}`.

🚨 **binance spot is not a listen key venue any more.** Binance retired the spot and margin listen keys on 2026-02-20; `POST /api/v3/userDataStream` answers **HTTP 410 Gone**. The private section is authored onto the venue's WebSocket API host (`ws-api.binance.com/ws-api/v3`), opened by a signed `userDataStream.subscribe.signature` request under the `:ws_api_signature` pattern — that one frame both authenticates and *is* the user data stream, so there is no channel to subscribe to afterwards. A `subscribe.signature` subscription also **outlives the socket that made it**, so a differential probe must run the unauthenticated leg first or it reads the previous leg's events.

One auth surface remains **unwired, and fails loudly rather than silently**: **derive authors no `auth_pattern`** although the venue has a WS login, so its private section connects without a handshake. Hyperliquid's `nil` pattern is correct — its private subscriptions are scoped by address.

### Critical design decisions

**HTTP pipeline:** manual query encoding (signing needs raw params — don't use Req's `:params`); safe retry GET/HEAD only (never POST/PUT/DELETE — duplicate orders); per-credential rate limiting for multi-user isolation.

**Exchange struct:** config, not process — pure data, no GenServer. String keys matching the JSON spec.

**Errors:** two-tier matching — `error_codes` (exact) plus `broad_error_patterns` (substring), pre-processed at construction. `error_body_checks` for top-level sentinels; `error_code_fields` for exact-code probe order.

**Dispatch:** symbol denormalization happens in `Unified.call/5`, NOT `Dispatch.call/4` — raw callers pass through untouched. Required params always win over opts (`Map.put_new` prevents silent override in trading calls).

**Authored `path_params` descriptors are `%{"name", "source"}` and `source` is ALWAYS `"params"`** — verified 1668/1668 across the catalog. `interpolate_path/3` resolves from the params map by `"name"` and deliberately ignores `source`. This is a relied-on invariant: if an authored spec ever sets a path-param source to anything else, resolving from `params` silently reads the wrong place. The fix is not to pre-build unused branches but to make the day-it-changes failure LOUD — `path_param_name/1` should match `%{"source" => "params"}` and let any other shape hit a raising clause.

**Durable kernel:** when data is finite, verifiable, and fails silently when wrong, **author it explicitly — don't infer it at runtime.** `HmacRecipe` stays as the deterministic recipe *executor* (mechanism, not judgment); author recipes into its shape rather than rebuild a signer.

## The trading domain layer

The trading domain — OptionProposal, OptionReadiness, OptionSaga, PortfolioRisk and their submodules — lives in its own repo, https://github.com/ZenHive/bourse_trading (private, ZenHive), which depends on this client's published Hex package. The modules keep the Bourse module namespace there; that is deliberate, not a leftover.

**The dependency stays one-directional: the domain calls the client's packaged surface, never the reverse.** Nothing in this repo may reference a domain module — a single inbound edge would couple the client to an unpublished repo. Domain logic (proposal checks, readiness collection, saga execution, exposure math) belongs in bourse_trading; venue behavior, authored specs, signing and unified parsing belong here.

The `docs/option_readiness/` JSON snapshots stay in this repo as frozen evidence — `docs/prod-verification-ledger.md` cites them by path.

## Repo-internal tooling inside `lib/`

The oracle / recording / replay / drift cluster — `Bourse.ExchangeAcceptanceFixtures`, `Bourse.PublicAcceptedRequests`, `Bourse.OracleProvenance`, `Bourse.OracleLabel`, `Bourse.ReplayExchange`, `Bourse.RecordedResponseFixtures`, `Bourse.LiveDrift`, `Bourse.Spec.Promotion` — lives in `lib/` because the `mix ccxt.*` tasks compile in `:dev`, where `elixirc_paths/1` does not carry `test/support`. It is **not** client surface: `@unpackaged_prefixes` in `mix.exs` keeps every one of them out of the tarball and out of hexdocs.

**Anything you add to that cluster inherits the exclusion — add its prefix.** These modules read `test/fixtures/**` and `priv/reference_cache/`, which are never packaged, and they may use `:dev`/`:test`-only deps. A shipped copy fails twice over: on missing files at runtime, and at the consumer's *compile* — the original case was `Req.Plug`, which exists only from req 0.7 and only behind the `only: [:dev, :test]` `:plug` dep, so consumers resolving `~> 0.6.1` got an undefined-module warning out of two fixture modules. `test/mix_project_test.exs` gates both halves: the package file list, and an AST scan asserting no shipped module names a dependency a consumer may not have.

## Git commit configuration

Conventional commits: `<type>(<scope>): <description>`. Types: feat, fix, docs, style, refactor, test, chore. Title-only; bodies only when asked. No `Co-Authored-By` footers.

**Release tags come AFTER the maintainer confirms the publish went through — never before.** `mix hex.publish` is run by hand (it needs 2FA), and the release gate keeps finding things right up to the prompt: 0.2.0 gained a hexdocs-filter fix and ten broken-link fixes after the version bump was already committed. A tag cut in advance names a tree that is not what shipped, and correcting it means force-updating a pushed ref. Bump the version, get the gate green, hand off the publish — then tag the published commit.
