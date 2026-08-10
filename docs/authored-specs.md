# Authored Specs — provider-authoritative, reality-verified

Status: **active pivot** (branch `authored-specs`, phase `authored_specs`). This is the
durable design anchor; the `authored_specs` rmap tasks reference it.

## Read this first: authority and verification

The exchange-owned API contract is the semantic authority. Live API behavior, observed
traffic, or raw venue recordings establish what the venue did; the provider's official
docs/specs/SDK establish what its fields and parameters mean. A claim is `verified` only
when manifest-registered reality and provider-owned semantics support it; otherwise it is
`unverified`. CCXT source, execution, and static data are authoring references only.

## Why

`ccxt_client` sourced its per-exchange JSON specs by **mechanically extracting** them from
upstream `ccxt-distill` (static analysis of CCXT's TypeScript). That coupling produced
recurring, measured pain:

- **Schema-churn treadmill.** distill's extraction *shape* keeps changing (4.1.0 → 4.5.0 →
  4.6.0 → 4.13.0). Each bump reopens consumer wiring already marked done — the
  `fetch_ticker`/`fetch_markets` normalization surface was re-dispatched **five times**
  (tasks 144 → 152 → 154 → 164 → 165/166), signing once (143). Every round was "residual
  reds after a distill resync."
- **Judgment-as-code.** distill's interpretive layer (signing recipes, field maps, symbol
  patterns) is a static parser doing a *judgment* task — it emits `_unresolved_reason` (a
  parser shrugging where an AI would read CCXT's `sign()` and just understand it). This is
  the `critical-rules.md` § "Think As an AI" anti-pattern: AST-extracting `sign()`/`parse*()`
  is mechanics applied to a judgment problem.
- **STOP-and-wait coupling.** Every gap routes to `../ccxt-distill/BUGS.md` and waits on a
  separate session.

### Why the rebuttals hold (the cons that don't survive scrutiny)

1. *"The compatibility corpus has holes (WS-parse, unfixtured methods)."* — The corpus is
   **extensible**: add cassettes/VCR for WS frames and for unfixtured REST methods. A hole is a
   compatibility fixture to write, not a reason to keep extraction or to lower the tier-1
   evidence requirement.
2. *"You're relocating churn, not eliminating it."* — Today we pay churn **twice**: in
   distill's extraction *and* in our implementation chasing its shape changes. Collapsing to
   authoring-only is strictly less churn, on one surface we own.
3. *"Frozen specs drift from live exchanges."* — That drift is the **status quo**; live data
   already contradicts "everything works" regularly, caught by T39. The freeze doesn't make
   live-drift worse — it removes the *schema*-drift axis on top of it.
4. *"Removing sync kills onboarding exchange #111."* — The *capability* survives: bootstrap a
   new venue ad-hoc via distill, or read CCXT source directly. We remove the *standing* sync,
   not the path.
5. *"Doctrine tension with Full-Catalog priority."* — Doctrine changes (T-F). The catalog
   still compiles for public data; only authored *effort* focuses on the 7.

## The authority rule

**Interpret, don't extract — and make interpretation answerable to the venue.** The
exchange-owned API contract is the correctness authority: live or recorded raw behavior
establishes what happens, and the exchange's own docs/specs/SDK establish what it means.
CCXT source, execution, and static data are unverified authoring references. The *mechanical*
bulk (endpoint tree, urls, fees,
rate-limits) may remain a one-time frozen CCXT projection, but **our spec is authored and
frozen, not synced.** A spec gap is an **authoring task**, not an upstream STOP-and-wait.

This is `critical-rules.md` § "Think As an AI" applied to specs: judgment → an AI does it
better than a static parser; mechanics → code. distill's `_unresolved_reason` was a parser
shrugging at a judgment call. We don't shrug; we read CCXT and author.

## The decision — "Authored spec, our schema"

Keep the macros and the JSON-spec format. Then:

1. The spec becomes **ours** — distill's schema enforcement and provenance are dropped.
2. The **mechanical bulk** (endpoint tree, fees, urls, rate-limits, currencies) is a
   **one-time frozen projection** from CCXT — the part distill never struggled with. No
   recurring resync.
3. The **interpretive slices** (signing recipe, field maps, response envelopes, symbol
   patterns, error fields) are authored against the exchange-owned API contract. CCXT JS may
   inform the authoring, but correctness requires
   observed venue behavior plus a provider-owned semantic source. Freezing preserves that
   provenance; it does not upgrade a reference into an authority.
4. distill + the heuristic interpretation layers (`Recipe.resolve`, `classify_pattern`,
   error-derivation) are **removed**, not reconciled.

**Scope:** the 10 first-class venues — `alpaca`, `deribit`, `okx`, `bybit`, `binance`,
`binancecoinm`, `binanceusdm`, `hyperliquid`, `derive`, `lighter`. The ~100-exchange long tail stays as last-frozen vendored specs
(public-data-only); removing the *sync tooling* does not delete the vendored files.

### Vendored reference storage decisions

The client deliberately tracks its two reference slices so a fresh clone can run
the complete offline suite without fetching authoring inputs:

- `priv/reference_cache/` supplies `Bourse.ReplayExchange` with normalized market
  and currency cache fields used by request reconstruction and parser tests.
  Manifest-registered recordings preserve provider response envelopes instead;
  they do not contain the normalized contract sizes, precision, asset indexes, or
  currency-network metadata that replay consumes. Rebuilding those fields would
  require rerunning the reference implementation, so the ~1 MB cache remains a
  separate vendored compatibility input rather than reality evidence.
- The 15 documents in `priv/specs/json/output/` are test-only authoring references.
  Tests read their complete endpoint trees and symbol indexes, including five
  unsupported-venue counter-examples. Individual operation recordings cannot
  represent that static document contract, while fetch-on-demand would put network
  access on the offline test path; the 19 MB slice therefore remains tracked.
- `priv/specs/json/reference_corpus.json` remains tracked with the documents because
  it declares their closed inventory and pins their provenance. Its
  `pins.source.sha256` is the cross-repository revision key shared with the
  workbench's 110-document corpus. `pins.static_fixtures` verifies each repository's
  local vintage note and is not the upstream-revision join key.

### The schema is ours — versioned compile-time contract

"Our schema" is not a slogan; it is a **versioned compile-time contract WE own** (T-B / 169):

- **Owned version.** Schema version `3` is ours, not distill's `4.13.0`. It changes only with a deliberate runtime-contract migration; extractor churn is not a version event.
- **One complete runtime document.** Each first-class venue loads only
  `priv/specs/json/output/authored/<venue>.json`. The frozen sibling
  `output/<venue>.json` is reference input and cannot fill a runtime field. There is no
  runtime merge, inheritance, template, cross-venue reference or generated twin.
- **Required sections.** The owned document declares identity (`exchange`), REST transport
  (`raw.describe.api`, `raw.url_templates`, `urls`, `testnet`), raw and unified endpoint
  contracts (`endpoints`), support (`capabilities.has`), auth, normalization, market
  semantics, errors, fees/rate limits/config and WebSocket auth/dispatch/heartbeat/subscribe/
  semantics/URLs. `Bourse.Spec.Schema` names the exact missing path at compile time.
- **Missing/null/empty are distinct.** A missing required slot is an authoring gap. `null` is
  an explicit not-applicable value only at a nullable leaf. An empty map/list is an explicit
  declaration with no entries and is accepted only on slots whose schema permits emptiness.
  The owned loader returns the decoded document unchanged; it does not recursively strip
  values or manufacture defaults.
- **Support is explicit.** Every method in a promotion candidate appears in both
  `capabilities.has` and `endpoints.unified`, declared `true`, `false` or `"emulated"`.
  Unsupported methods carry an empty endpoint list; only `true` and `"emulated"` with an
  authored non-empty route generate support. Endpoint presence, `reason`,
  `_unresolved_reason` and raw CCXT `describe.has` values cannot create support.
- **Runtime-only surface.** Extraction ASTs, source receipts, provenance payloads, method
  inventories and test-only symbol indexes are forbidden by path. Evidence remains in the
  authority/carve/fixture surfaces; integration symbol selection reads the frozen reference
  explicitly and never injects that index into a runtime spec.
- **Macro-enforced.** `use Bourse.Exchange` validates the complete owned contract at compile
  time. A missing semantic decision is a named gap, not a consumer discovery.
- **Venue `config.default_family` (task 378 / C-T378a–g).** Multi-endpoint unified methods
  called with no family signal must not resolve by bare `hd(configs)`. The fall-through family
  is authored under `config.default_family` (`spot`/`linear`/`inverse`/`option`/`swap`/`future`)
  and preferred paths within a family stay in `endpoints.request.endpoint_selection`. First-class
  venues loud-fail (`bad_request`) when multi-endpoint selection is still unresolvable; the
  no-arg-read audit set is `Bourse.Unified.no_arg_read_methods/0` and the zero-bare-hd predicate is
  `Bourse.Unified.bare_hd_no_arg_pairs/0`. Carves: `docs/authored-spec-carves/global.md` (C-T378a/b),
  `binanceusdm.md` (C-T378c), `binance.md` (C-T378d), `bybit.md` (C-T378e), `okx.md` (C-T378f),
  `hyperliquid.md` (C-T378g).
- **Venue `fees.static_market_fees` (task 499).** Whether public market rows inherit
  maker/taker from the venue's published fee schedule is an **authored boolean**, required in
  every owned document — never a venue-id list in `lib/` and never inferred from the shape of
  the `fees` block. Declaring `true` makes `Bourse.Unified.ReadParse` fill nil
  `maker`/`taker`/`percentage`/`tier_based` from that venue's own `fees` (spot/linear/inverse/
  option selected by the market's type flags); response-derived fee fields always win. The
  presence of a `fees.trading` block is deliberately *not* the trigger: every owned document
  carries one as mechanical CCXT-projected bulk, so inferring from it would publish rates
  nobody confronted against the venue's own schedule. `true` is therefore an assertion that
  the schedule was confronted and belongs in market rows — today `binance` and `binanceusdm`
  (carve C-T164a); the other five first-class venues declare `false`.
- **One schema, many macro outputs.** The same owned schema generates endpoints *and* (follow-on, gated on the gate) the pattern-match verification assertions. Think in macros: the schema is the single source the codegen and the tests both read.

### Venue promotion boundary

`mix ccxt.promote_venue` is the reusable candidate-to-owned boundary. Preparation copies the
complete pinned reference's mechanical endpoint tree and metadata, strips reference-only
payloads, removes raw capability claims, and replaces signing, authenticated sections, request
shape, unified routing, normalization, symbols, errors, emulated methods, WebSocket semantics,
and every method support decision with explicit unresolved candidate entries. Its JSON report
uses one verification vocabulary: `verified` or `unverified`. Preparation never registers or
compiles the venue.

```sh
mix ccxt.promote_venue --prepare --reference REF --candidate CANDIDATE --report REPORT
mix ccxt.promote_venue --check --candidate CANDIDATE --report REPORT [--reference REF]
mix ccxt.promote_venue --promote OWNED --candidate CANDIDATE --report REPORT [--reference REF]
```

`--check` / `--promote` re-read the pinned CCXT reference (from `--reference` or
`report.reference.path`), verify its bytes against `report.reference.sha256`, and re-derive
the method inventory from that pin. Candidate support maps *and* report capability items must
match that inventory — a both-sides deletion cannot self-consistently pass
(`:method_inventory_reference_drift` / `:method_inventory_mismatch`). Digest or path failures
are loud (`:reference_digest_mismatch`, `:reference_missing`, `:reference_pin_missing`).

The gate refuses missing or unresolved interpretation; CCXT-only evidence; incomplete public
or authenticated success/error observations; missing provider semantics; unsafe or incomplete
create/fetch/cancel evidence for trading venues; silently skipped or credential-less
integration tests; missing carve/authority artifacts; schema failures; non-deterministic JSON;
a failing `mix ccxt.oracle_gate`; or any critical slot without a manifest-registered response,
accepted-request golden, or recorded exchange error. Venue eleven therefore gets reality
provenance whether or not a CCXT reference exists. A written owned document is still not a
supported venue: the named venue delivery must separately add it to `Bourse.Spec`, the registry,
and the compiled set.

## The epistemology — provider-owned contract, binary verification

We build the client ourselves, by our own rules, but those rules answer to the exchange API.

| Role | Allowed sources | Verification effect |
|---|---|---|
| **Semantic authority** | Exchange-owned docs/specs/SDKs | Required meaning for a verified claim |
| **Observed behavior** | Live API / observed traffic / manifest-registered raw venue recording | Establishes what the venue actually did |
| **Authoring reference** | CCXT source/execution/static data, training, third-party docs, general web | Implementation clue only; claim remains unverified |

If author and grader share the same third-party interpretation, both can converge on the same
wrong belief. `mix ccxt.oracle_gate` therefore grades only manifest-registered reality:
recorded responses, accepted-request goldens, and recorded exchange errors. CCXT-derived data
can help discover or compare behavior, but cannot make a claim verified.

## Contract coverage is not behavior verification

The authority manifest is a provenance index for bytes we reviewed. It is neither a substitute
for the provider's current upstream nor proof that the selected artifact covers the venue's
whole API. Source work therefore starts with the manifest and then checks the official upstream
when freshness or source discovery is in question. A newly relied-on artifact is pinned before
it drives authoring.

Artifact quality has independent axes:

| Axis | Examples | What it controls |
|---|---|---|
| **Freshness** | maintained mutable source, frozen repository revision | Whether absence can support a current completeness claim |
| **Expressiveness** | typed OpenAPI, untyped Postman, indexed prose | Which mechanical facts can be compared without interpretation |
| **Scope** | current REST, upcoming REST, WebSocket, one endpoint family | The denominator the artifact is allowed to define |
| **Authority** | provider-owned, third-party aggregation | Whether it can establish semantics or is discovery-only |

OpenXAPI and CCXT can expose a likely omission, but neither may gate semantic correctness.
Provider-owned response examples establish a documented example, not observed behavior. An
invalid-parameter comparison against CCXT exercises request/signing/error compatibility, not a
successful response parser. An empty live list establishes reachability, not row-field meaning.

For each operation in the union of provider and authored inventories at a pinned revision,
contract coverage keeps independent axes. A single disposition enum is forbidden because a raw-
only or carved operation can independently be verified, unsafe, or unreachable.

| Axis | Values | Meaning |
|---|---|---|
| **Relation** | `shared`, `provider_only`, `authored_only` | Which inventory contains the operation |
| **Runtime scope** | `unified`, `raw_only`, `carved`, `not_implemented`, `unknown` | What this client deliberately exposes |
| **Evidence** | `verified`, `unverified` | Whether manifest-registered reality covers the claim |
| **Reachability** | `safe`, `unsafe`, `unreachable`, `unknown` | Whether and how a live call may be made |
| **Contract scope** | `current_rest`, `upcoming_rest`, `current_websocket`, `upcoming_websocket` | Which provider surface defines the denominator |

Task 555 makes these axes machine-readable. The comparator may carry forward registered facts,
but it never makes semantic or safety judgments: absent evidence is `unverified`; absent runtime
or reachability evidence is `unknown`. Direct provider-operation capture establishes the evidence
axis; read evidence and mutation adjudication drain through separate one-session vertical tasks
cut from the resulting inventory. Only manifest-registered live observations can advance the
evidence axis. Upcoming methods remain forward-compatibility observations, not missing
current-runtime methods.

### Measured gaps on 2026-08-04

The authored surface contained 392 declared read-method/venue pairs. Of those, 313 had a parse
slice, 79 did not, and 246 of the sliced pairs had no manifest recording. The recording manifest
contained 84 venue/method pairs in total, including pairs outside the declared-and-sliced set.
Task 533 made the parse absence loud; tasks 550 and 551 own the remaining authored-surface gaps.

A separate Deribit comparison against the current official OpenAPI found 123 authored raw paths:
116 overlapped the provider document, 62 provider paths were absent from the authored spec, and
7 authored paths were absent from the current document. Absence from either side is only a diff,
not a deletion or implementation decision. Task 460 deliberately excluded the reusable
OpenAPI-versus-authored conformance layer; the roadmap now owns that missing mechanism. Until it
lands, these numbers are a dated measurement rather than a reproducible gate.

**Coverage has three boundaries.** The provider-contract comparison measures what our authored
inventory cannot see. Direct provider-operation capture establishes what the live raw API did.
The unified reality oracle measures whether authored behavior means what the provider says it
means. Passing any one boundary cannot substitute for the other two.

### Recording a carve's tier — the machine-readable evidence status (task 446)

Registers are **append-only**, so a `*Verification:*` line written when a venue was
unreachable can never be corrected in place — it understates the tier forever once the
credential gap closes (observed: alpaca C-T428a/b/c, live-verified 2026-07-20 while the
register still read "has never run — no credentials"). The prose is therefore no longer the
tier; a dated status block is:

```
<!-- carve-evidence-status
{"carve_id":"C-T428a","date":"2026-07-20",
 "semantic_source":{"kind":"provider_owned","reference":"Alpaca market-data API reference"},
 "observed_evidence":{"kind":"recorded_venue","reference":"frozen 200 body, alpaca_authored_slice_test.exs"},
 "compatibility_reference":null,
 "resolved_tier":1}
-->
```

**Supersession is by date, not by edit.** Append a new block; the latest `date` for a
`carve_id` is the current status and outranks every earlier block and every `*Verification:*`
line for that carve. Earlier blocks stay as provenance. Two blocks sharing one date is an
error — the gate cannot order them.

Field rules, all enforced by `test/bourse/carve_register_consistency_test.exs` (default offline
suite):

- `resolved_tier` is `1`, `2`, or `3`, and is the tier the § "Compatibility ≠ correctness"
  table defines.
- **Tier 1 requires two independent facts**, matching the authority rule: a
  `semantic_source` of kind `provider_owned`, *and* an `observed_evidence` of kind
  `live_venue` or `recorded_venue`, each with a non-empty `reference`. Docs alone, a closed
  ledger entry alone, or anything of kind `ccxt` can never reach tier 1 — CCXT belongs in
  `compatibility_reference`, which never affects the tier.
- **Tier 2/3 requires `known_gap_reason`** — say what is missing, so the gap is a record
  rather than a silence.
- A closed `docs/prod-verification-ledger.md` entry naming a carve id asserts tier 1 for it;
  a register status that contradicts the ledger fails the gate naming venue, carve id, and
  both tiers. Close the ledger entry and append the tier-1 status in the same change.
- Every carve section carrying `*Verification:*` prose must have a status block, so legacy
  prose can never be the only tier claim.

**Registers do not use a bare `Oracle:` label.** It reads as a correctness claim regardless of
what follows it. Write `Evidence sources:` and let the status block carry the tier.

## Discovery reality-first; reality gate offline

The authoring order is real call → record → register → pure assertions. Live calls discover
the venue's current response and error shapes. Frozen raw venue responses, accepted-request
goldens, and recorded errors make those observations deterministic and hermetic in CI.
`mix ccxt.oracle_gate` checks their manifests, provenance, critical-slot coverage, and replay
contracts. Periodic live re-recording remains the drift detector.

## Task spine (phase `authored_specs`)

Evidence-first, reversible, REST before WS. Deps in brackets.

- **T-A · Reality oracle.** Manifest-registered responses, accepted requests, and recorded
  errors are the verification floor. `mix ccxt.oracle_gate` is the check-pipeline contract.
- **T-B · Own the spec schema.** Decouple `Bourse.Spec` from distill's contract (drop
  `_provenance` requirement + provenance manifest fields); define "our schema" = the
  load-bearing key set; drop the ~20 never-read distill fields. Hand-build (reshapes loader).
  `[after T-A]`
- **T-C · Author + verify + freeze one venue (proof-of-loop).** `okx` or `deribit`. Bulk
  frozen; interpretive slices authored against provider-owned semantics and observed venue
  behavior, with CCXT retained only as authoring reference; marked hand-owned/frozen.
  Measures real authoring cost before the fleet. Runs the confrontation step (§ The
  confrontation step) per schema decision; outcomes land in the carve register.
  `[after T-A, T-B]`
- **T-D · Roll remaining first-class venues.** Repeat T-C's proven loop across the other 7
  (confrontation step included). `[after T-C]`
- **T-E1 · Remove distill sync + staleness tooling.** Delete `ccxt.sync`, distill-resolution
  helpers, and their tests; confirm already-removed staleness hooks stay gone. `[after T-D]`
  *(landed task 172 — standing sync removed; ad-hoc long-tail bootstrap remains manual)*
- **T-E2 · Remove obsolete interpretation heuristics.** Landed in task 173:
  `Recipe.resolve`, `Symbol.classify_pattern/2`, the error-derivation block,
  long-tail fallbacks, and consumer custom signing are gone. `HmacRecipe`
  survives as the mechanical executor of authored recipes.
- **T-F · Reconcile CLAUDE.md + docs doctrine.** Rewrite the distill-doctrine sections; point
  at this doc; regenerate `AGENTS.md`. `[after T-E1, T-E2]`
- **T-G · WS authored slices + cassette harness (DEFERRED).** Author WS slices; build a frame
  record/replay harness; port CCXT `pro/test/base` tests. Live `watch*` covers WS meanwhile.
  `[after T-D]`

## Authoring nuance — not all normalization is field_map-shaped

When T-C/T-D author a venue's interpretive slices, `parse*()` → field_maps covers the
**flat-scalar** shapes (ticker, market, trade, balance fields). But some normalizations are
**transformer-shaped**, not field_map-shaped, and have no `@struct_for` entry / no spec slice:

- **order_book** — `[[price, size], …]` level arrays go through the Task-44
  `:order_book_from_flat_list` transformer, not field_maps (the coercion vocab is
  flat-scalar-only). Authoring a venue means *selecting/wiring the transformer*, not writing an
  order_book field_map slice (Task 153 owns this path).

The rule for authors: if the source shape is a nested level array (or otherwise non-scalar the
field_map vocab can't express), it's a transformer, not a field_map slice. The T-A response
gate still verifies it end-to-end (httpResponse → normalizer → parsedResponse) regardless of
which path the normalization takes — so "green against T-A" is the acceptance signal either
way.

## The confrontation step — confront the carve, not just the value (task 181)

Every verification above grades our parser against a **target schema** — struct shapes, field
names, semantic carves (`cost = amount × price`; inverse-divide; a funding `interval` string) —
that was ported wholesale from Bourse. The fixture-vs-live axis is orthogonal to this: a live
assertion inherits the same CCXT vocabulary, it just asserts less of it. So authoring a venue
slice (T-C/T-D) has an explicit step **before** the field-map is written — for each schema
decision, confront the **carve**, not just the value:

1. **Does this field exist on this exchange at all?** (A venue with continuous funding has no
   funding interval; a venue with tiered tick sizes has no single price step.)
2. **What does the value actually MEAN here** — unit, window, mode — sourced from the
   exchange's **own** docs/SDK/observed behavior, with CCXT as one cross-reference, never the
   arbiter?
3. **Is the carve the right abstraction for this venue**, or does it misrepresent it (a scalar
   for a rule; a snapshot for a constraint; a class constant for per-market data)?

Each confrontation lands in the carve register (§ Divergence register below) with one of two
outcomes: **CONFIRMED** — CCXT's carve is right about the exchange, adopted deliberately and
cited from a non-CCXT source — or **DIVERGE** — CCXT's carve is wrong or lossy vs reality, ours
differs, with rationale, the weighed consumer-compatibility cost, and tier-1 venue evidence
(CCXT remains only a compatibility reference for that slice). Either way the register doubles as the audit trail that
the schema was **confronted, not inherited**. Divergence is for correctness about the exchange,
never aesthetics: every entry weighs the compat cost explicitly, and "CCXT is right" is a
recorded verdict, not a silent default.

## Key decisions (stated, not gated)

- **Keep `HmacRecipe` executor; delete only `Recipe` interpretation.** The executor is
  deterministic mechanism — author recipes into its shape rather than rebuild a signer.
- **Long tail stays frozen.** Removing sync tooling leaves the ~100 vendored specs working
  for public data; no decision needed now. New venues bootstrap ad-hoc via distill or raw
  CCXT source.
- **`_unresolved_reason` is diagnostic only.** It never establishes method support or fills a
  required owned-schema slot.
- **rmap: preserve done history.** "Fresh" = supersede obsolete pending + new `authored_specs`
  phase, not wipe the ledger.

## Divergence register (our rules vs CCXT)

Deliberate, registered divergences from CCXT's ontology or method mapping. Each entry is a
conscious "our rules" choice — not an inherited assumption — with tier-1 venue evidence when
CCXT cannot grade compatibility for that slice (see § epistemology).

New carve entries live in `docs/authored-spec-carves/` so independent venue work does not
serialize on this doctrine document. Route venue-specific decisions to the matching file and
cross-venue contract decisions to `global.md`.

**Per-venue registers are canonical** (task 466). Each first-class venue file under
`docs/authored-spec-carves/` is the complete carve record for that venue. Early confrontations
were recorded inline below before those files existed; those entries have been moved (or
mirrored) into the owning register. What remains here is doctrine + historical index: short
pointers keep the narrative, but the heading that the consistency test resolves lives in the
per-venue (or global) register. Do not re-adjudicate a pointer — open the linked file. The
consistency test resolves references in this document against the canonical headings in the
carve files.

| Decision scope | Register |
|---|---|
| Binance spot | `docs/authored-spec-carves/binance.md` |
| Binance COIN-M | `docs/authored-spec-carves/binancecoinm.md` |
| Binance USD-M | `docs/authored-spec-carves/binanceusdm.md` |
| Alpaca | `docs/authored-spec-carves/alpaca.md` |
| Bybit | `docs/authored-spec-carves/bybit.md` |
| Deribit | `docs/authored-spec-carves/deribit.md` |
| Derive | `docs/authored-spec-carves/derive.md` |
| Hyperliquid | `docs/authored-spec-carves/hyperliquid.md` |
| OKX | `docs/authored-spec-carves/okx.md` |
| Cross-venue | `docs/authored-spec-carves/global.md` |

**Carve-id allocation.** Existing `B*`/`C*` ids are append-only historical ids: do not renumber
or reuse them. Every new carve uses the task-scoped id `C-T<task-id>` and names that same task in
its heading. This derives parallel authors' ids from their already-unique tasks instead of the
current register snapshot. When one task registers several carves, suffix them `C-T<task-id>a`,
`C-T<task-id>b`, … — the task still scopes the id, so parallel worktrees cannot collide. The
dispatch gate resolves every `B*`, `C*`, and `C-T*` reference in this register, `CHANGELOG.md`,
and `CHANGELOG.md` to exactly one registered heading, and rejects a new hand-numbered
`B*`/`C*` id.

The historical Hyperliquid `fetch_trades` divergence is canonical in
[`docs/authored-spec-carves/hyperliquid.md`](authored-spec-carves/hyperliquid.md); its venue
evidence and authored `fetchMyTrades` request shape moved there unchanged.

### Carve register — schema-level confrontations (task 181, 2026-07-15)

Confrontation outcomes (§ The confrontation step) for the divergence-prone "bite" carves —
deribit + bybit, hyperliquid where live evidence existed. Live first-move evidence: tidewave
`project_eval` against the deribit/bybit/hyperliquid **testnets** (2026-07-15): `fetch_markets`
(deribit future + option, bybit linear + spot, HL perps), `fetch_funding_rate` (bybit), and raw
`public_get_get_funding_rate_value` over two different windows (deribit). Non-CCXT semantic
sources fetched the same day. Implementation of every code-level outcome is encoded as
acceptance criteria on tasks **170** (deribit), **171** (bybit), **209** (hyperliquid) — nothing
here changes the schema silently.

**Task 466 leveling:** every canonical carve heading that lived only here now resides in its
venue register or `global.md`; entries below remain as historical-index pointers (no second
heading). The fuller proof-loop narratives remain here as history and point back to those
canonical registers.

**C29** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* `add_margin` positional order. Outcome: ALIGNED-to-ccxt.

**C30** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* `reduce_margin` positional order. Outcome: ALIGNED-to-ccxt.

**C-T309** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* `set_margin` positional order. Outcome: ALIGNED-to-ccxt (task 309).

**C31** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* `create_convert_trade` quote identifier. Outcome: ALIGNED-to-ccxt.

**C-T347** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit convert-trade quote binding. Outcome: CONFIRMED-against-Bybit docs (task 347).

**C-T308** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX convert-trade request fields. Outcome: CONFIRMED-against-OKX docs (task 308).

**C-T362** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX non-order account + conversion request residual. Outcome: CONFIRMED-against-OKX docs (task 362).

**C-T363** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX order read + sparse action-acknowledgement response semantics. Outcome: CONFIRMED-against-OKX docs (task 363).

**C-T364a** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX open-position response semantics. Outcome: CONFIRMED-against-OKX docs + live intl demo (task 364).

**C-T364b** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX positions-history response semantics. Outcome: CONFIRMED-against-OKX docs (task 364).

**C39** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* `fetch_order_book` depth. Outcome: CONFIRMED-as-ours.

**C37** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* `fetch_positions_adl_rank` symbols. Outcome: CONFIRMED-as-ours.

**C38** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* `fetch_orders_classic` symbol. Outcome: CONFIRMED-as-ours.

**C34** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit residual unified reds (task 306). Outcome: CONFIRM venue + ALIGNED-to-ccxt request shapes.

**C36** — *historical index only; canonical entry in [`docs/authored-spec-carves/global.md`](authored-spec-carves/global.md) (task 466).* Ticker `vwap` is a price, never contract size. Outcome: DIVERGE from CCXT's blind `quoteVolume/baseVolume`. Bybit-specific evidence also mirrored under bybit.md § C36 Bybit application.

**C-T340** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance plural ticker routing. Outcome: CONFIRMED venue surfaces (task 340).

**C35** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX option greeks denomination. Outcome: DIVERGE from CCXT's bare-key mapping.

**C1** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* precision values need a discriminator; carry it per market, not per exchange class. Outcome: CONFIRM CCXT's tick-size normalization · DIVERGE on where the discriminator lives.

**C2** — *historical index only; canonical entry in [docs/authored-spec-carves/deribit.md](authored-spec-carves/deribit.md) (task 466).* deribit amount granularity: minimum ≠ step, and the live payload names no step. Outcome: REPLICATE CCXT's proxy, gap registered.

**C3** — *historical index only; canonical entry in [docs/authored-spec-carves/deribit.md](authored-spec-carves/deribit.md) (task 466).* deribit tiered tick sizes (`tick_size_steps`). Outcome: shared-lossy, deliberately kept — registered.

**C4** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* inverse-perp `cost`. Outcome: CONFIRM Bourse.

**C5** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* funding cadence/interval. Outcome: CONFIRM CCXT for bybit + hyperliquid; Deribit superseded by C-T535a (hourly, DIVERGE from CCXT).

**C6** — *historical index only; canonical entry in [docs/authored-spec-carves/hyperliquid.md](authored-spec-carves/hyperliquid.md) (task 466).* hyperliquid price precision. Outcome: DIVERGE — no snapshot scalar.

**C7** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* position `contractSize` is market-derived, not payload-derived. Outcome: DIVERGE — nil at parse (with Bybit linear exception, task 306 / C34).

**C-T316a** — *historical index only; canonical entry in [`docs/authored-spec-carves/derive.md`](authored-spec-carves/derive.md) (task 466).* Derive position accounting and entry price. Outcome: DIVERGE from CCXT (task 316).

**C8** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance market filters and REST families. Outcome: CONFIRM exchange semantics.

**C9** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit request precision follows the live instrument tick. Outcome: DIVERGE.

**C10** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit option Greeks baseCoin follows an explicit symbol when present. Outcome: DIVERGE.

**C11** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit option ids carry a settle suffix only for USDT settlement. Outcome: CONFIRM Bourse.

**C12** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit `fetchPositionADLRank` category is derived, never a literal. Outcome: CONFIRM Bourse.

**C13** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit `fetchMarkets` includes complete option pages via describe types + per-baseCoin loop. Outcome: DIVERGE from CCXT (with venue evidence).

**C21** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* Canonical query space encoding: `%20`, not www-form `+`. Outcome: DIVERGE from Elixir `URI.encode_query/1`; CONFIRM Huobi/HTX venue docs (and match CCXT `qs` as cross-check only).

**C15** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* GET array query encoding: empty-bracket keys (`ids[]=`), not CCXT bracket-index. Outcome: DIVERGE from CCXT default `urlencode` (qs indices) AND from OpenAPI form/explode prose.

**C14** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit legacy (non-v5) private signing places `sign` by HTTP method. Outcome: CONFIRM Bourse.

**C19** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit `fetchOpenOrders` carries `nextPageCursor` from `/v5/order/realtime`. Outcome: CONFIRM Bourse.

**C15a** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX unified requests are keyed by instrument type, family and numeric account id, not by the unified caller vocabulary. Outcome: CONFIRM exchange semantics · DIVERGE from CCXT on the trade-fee instrument key.

**C16** — *historical index only; canonical entry in [docs/authored-spec-carves/deribit.md](authored-spec-carves/deribit.md) (task 466).* deribit transaction `state`. Outcome: DIVERGE — map the venue's full state enum instead of CCXT's two-entry passthrough.

**C17** — *historical index only; canonical entry in [docs/authored-spec-carves/deribit.md](authored-spec-carves/deribit.md) (task 466).* deribit dated-instrument market identity. Outcome: CONFIRM VENUE + CCXT COMPAT.

**C27** — *historical index only; canonical entry in [docs/authored-spec-carves/deribit.md](authored-spec-carves/deribit.md) (task 466).* Deribit combo instruments retain their native ids. Outcome: DIVERGE from a single-leg unified grammar.

**C18** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance EAPI option ids omit the quote/settle segment. Outcome: CONFIRM VENUE.

**C20** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance market type/boolean flags: payload shape + generic type derive, not endpoint stamp. Outcome: CONFIRM VENUE (+ mechanical derive).

**C22** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance no-arg market surfaces and order enum casing. Outcome: CONFIRM VENUE — the sandbox drops the margin/option waves (not linear/inverse), and USD-M is linear-only.

**C-T356** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance multi-row ticker symbols follow the resolved endpoint family. Outcome: CONFIRM VENUE + ALIGNED-to-ccxt (task 356).

**C-T366** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance USD-M ticker ids require fapi/dapi settlement context. Outcome: CONFIRM VENUE ALIGNED-to-ccxt (task 366).

**C23** — *historical index only; canonical entry in [docs/authored-spec-carves/deribit.md](authored-spec-carves/deribit.md) (task 466).* Deribit linear dated futures use `BASE_USDC-DMMMYY`. Outcome: CONFIRM VENUE + CCXT COMPAT.

**C24** — *historical index only; canonical entry in [docs/authored-spec-carves/deribit.md](authored-spec-carves/deribit.md) (task 466).* Deribit linear option strikes encode decimal points as `d`. Outcome: CONFIRM VENUE + CCXT COMPAT.

**C25** — *historical index only; canonical entry in [docs/authored-spec-carves/deribit.md](authored-spec-carves/deribit.md) (task 466).* Deribit linear USDC perpetuals settle in USDC. Outcome: CONFIRM VENUE + CCXT COMPAT.

**C17a** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX sandbox `fetchCurrencies` short-circuit. Outcome: DIVERGE from CCXT — surface the exchange error instead of faking an empty currency map.

**C26** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit `fetchLeverage` margin mode is account-scoped, not a position-row field. Outcome: CONFIRM VENUE + CCXT COMPAT.

**C28** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* balance availability branches are per currency row. Outcome: CONFIRM venue semantics + CCXT compatibility; express the branch in the keyed-collection descriptor.

**C32** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX account configuration has no account currency. Outcome: DIVERGE from CCXT's undefined-only key; retain the four-field Account schema.

**C33** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX bills are balance-change records, and their account endpoints stay numeric. Outcome: DIVERGE from CCXT's account-name translation.

**C-T318a** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance ticker average uses the loaded market price precision. Outcome: ALIGNED-to-ccxt (task 318).

### Bybit historical response carves (task 290)

**B1** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit closed-position `hedged` materialization. Outcome: compatibility carve.

**B2** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit `info.category` annotation. Outcome: DIVERGE — keep and register.

**B3** — *historical index only; canonical entry in [`docs/authored-spec-carves/bybit.md`](authored-spec-carves/bybit.md) (task 466).* Bybit `FundingRate.interval` offline goldens. Outcome: DIVERGE — CCXT's golden is markets-cache contamination; tier-1 owns cadence.

**C-T311** — *historical index only; canonical entry in [docs/authored-spec-carves/okx.md](authored-spec-carves/okx.md) (task 466).* OKX `fetchCurrencies` currency-level withdrawal-fee rollup (task 311). Outcome: DIVERGE from CCXT; CONFIRMED against the OKX asset-currencies contract.

**C-T319** — *historical index only; canonical entry in [docs/authored-spec-carves/binance.md](authored-spec-carves/binance.md) (task 466).* Binance `fetchCurrencies` networkList rollups (task 319). Outcome: CONFIRMED (wallet API) + tier-2 network-code aliases.

**C-T321a** — *historical index only; canonical entry in [docs/authored-spec-carves/binanceusdm.md](authored-spec-carves/binanceusdm.md) (task 466).* Binance USD-M `timeInForce=GTX` is Post Only. Outcome: CONFIRM VENUE + ALIGNED-to-ccxt (task 321).

**C-T321b** — *historical index only; canonical entry in [docs/authored-spec-carves/binanceusdm.md](authored-spec-carves/binanceusdm.md) (task 466).* Binance order `lastTradeTimestamp` from `updateTime` on FILLED. Outcome: CONFIRM VENUE (proxy) + ALIGNED-to-ccxt (task 321).

**C-T321c** — *historical index only; canonical entry in [docs/authored-spec-carves/binanceusdm.md](authored-spec-carves/binanceusdm.md) (task 466).* Binance funding-history `rate` is absent on wire. Outcome: DIVERGE (additive nil) (task 321).

**C-T321d** — *historical index only; canonical entry in [docs/authored-spec-carves/binanceusdm.md](authored-spec-carves/binanceusdm.md) (task 466).* Binance `fetchPositionADLRank` is the singular adlQuantile read. Outcome: CONFIRM VENUE + ALIGNED-to-ccxt (task 321).

**C-T302** — *historical index only; canonical entry in [docs/authored-spec-carves/hyperliquid.md](authored-spec-carves/hyperliquid.md) (task 466).* Hyperliquid response slices authored end-to-end (task 302). Outcome: ALIGNED-to-ccxt (tier 2) with venue-native wire shapes.

**C-T339** — *historical index only; canonical entry in [docs/authored-spec-carves/hyperliquid.md](authored-spec-carves/hyperliquid.md) (task 466).* Hyperliquid L1 asset index is an explicit `Market.asset_index`, not `baseId`. Outcome: DIVERGE from CCXT's baseId overload; CONFIRMED against venue (task 339).

**C-T331a** — *historical index only; canonical entry in [docs/authored-spec-carves/hyperliquid.md](authored-spec-carves/hyperliquid.md) (task 466).* Hyperliquid request builder constructs `:action` (L1 + user-signed) (task 331). Outcome: CONFIRMED against the live venue after tasks 338 + 339.

**C-T351** — *historical index only; canonical entry in [docs/authored-spec-carves/global.md](authored-spec-carves/global.md) (task 466).* DEX signing environment follows the effective exchange sandbox (task 351). Outcome: CONFIRMED for Hyperliquid; ALIGNED for Derive.

**C-T331b** — *historical index only; canonical entry in [docs/authored-spec-carves/hyperliquid.md](authored-spec-carves/hyperliquid.md) (task 466).* Hyperliquid transfer success is a bare ack → structured TransferEntry (task 331). Outcome: DIVERGE from CCXT's raw-ack parse; CONFIRMED against venue.

**C-T322a** — *historical index only; canonical entry in [docs/authored-spec-carves/binancecoinm.md](authored-spec-carves/binancecoinm.md) (task 466).* Binance inverse `fetchMarginMode` selects the requested position and reads `isolated`. Outcome: CONFIRM VENUE + ALIGNED-to-ccxt (task 322).

**C-T332** — *historical index only; canonical entry in [docs/authored-spec-carves/binanceusdm.md](authored-spec-carves/binanceusdm.md) (task 466).* Binance USD-M batch-order elements follow each order type's required fields. Outcome: CONFIRM VENUE for LIMIT/MARKET; DEFERRED (tier 2) for the conditional family (task 332).

## Retired and misclassified raw endpoint register

Live sweep dispositions for raw endpoints that remain generated for source compatibility but
must not be treated as venue capability by probes or reviewers. The executable skip record
lives in `Bourse.Test.Generator.RawEndpointProbe.Config`; this register is the durable authoring
record.

Tier note: these rows are **both-sides-agree** observations (our client and CCXT JS hit the same
live venue and got the same rejection), corroborated against the venue's own current docs. That
makes the "not venue capability" call tier-1 for the endpoint's *existence* — the venue itself
rejected the path — while the specific supersession named in each row is a docs reading, not an
executed comparison.

| Venue | Endpoint row | Disposition | Evidence |
|---|---|---|---|
| `deribit` | `public_get_get_index` | Retired. Current Deribit docs expose `get_index_price` instead. | 2026-07-16 venue_compare: our client and CCXT JS both returned JSON-RPC `-32601 Method not found`; scratchpad `vc/b1`. |
| `deribit` | `public_get_get_index_price_names` | Retired. Absent from current Deribit docs. | 2026-07-16 venue_compare: our client and CCXT JS both returned JSON-RPC `-32601 Method not found`; scratchpad `vc/b5`. |
| `deribit` | `private_get_get_portfolio_margins` | Retired. Current Deribit docs expose `get_margins` / `simulate_portfolio` instead. | 2026-07-16 venue_compare: our client and CCXT JS both returned JSON-RPC `-32601 Method not found`; scratchpad `vc/b9`. |
| `bybit` | `spot/v3/public/*`, `derivatives/v3/public/*`, `v5/lending/*`, `v5/spot-cross-margin-trade/*`, `v5/spot-lever-token/order*` | Retired on testnet. Generated functions stay present; raw probes group-skip these path families. | 2026-07-16 bybit venue_compare: both clients returned exchange 404/discontinued responses; scratchpad `vcb/`. |
| `bybit` | private `contract/v3/private/*`, private `unified/v3/private/*` | Retired on testnet, **family-wide by conservative rounding**. The sweep found *most* — not provably all — of these two v3 private families 404 on both clients; the register skips the whole family rather than enumerate a partial subset the sweep did not fully cover. Re-narrow if a later sweep proves a specific row live. | 2026-07-16 bybit venue_compare; scratchpad `vcb/`. |
| `bybit` | `private_get_v5_user_del_submember` | Misclassified. Bybit documents this as destructive `rm-subuid` POST semantics, not a read-style GET. Skipping it also stops the raw probe from issuing a live sub-account deletion against testnet. | 2026-07-16 bybit venue_compare + docs confrontation; scratchpad `vcb/`. |
| `okx` | `private_get_account_set_auto_repay` | Misclassified. OKX accepts the POST row; GET returns `50115` on both clients. | 2026-07-16 okx venue_compare; scratchpad `vcx/RESULTS.md`. |
| `okx` | `public_get_support_announcements_types` | Retired typo/plural path. The real path is `support/announcement-types`, which also exists in the generated spec. | 2026-07-16 okx venue_compare: both clients returned `7002`; scratchpad `vcx/RESULTS.md`. |

## Deribit proof-venue completion (Task 170, 2026-07-15)

The authoring loop took two authored-slice/test iterations after the initial live probe, roughly
75 minutes including source confrontation and cold compilation. The first iteration exposed the
`get_account_summaries` collection carve and the missing market flags; the second aligned the
owned slice, compile-time contract, T-A replay, and live integration coverage.

Tier-1 versus tier-2 outcomes:

- **Agreement:** current CCXT-JS and the live Deribit payload agree that reversed perpetuals are
  inverse swaps, `min_trade_amount` supplies the amount granularity when `qty_tick_size` is absent,
  and account `summaries` must be indexed by currency.
- **Deliberate divergence:** perpetual expiration is nil rather than CCXT's year-3000 sentinel.
  The exchange calls the instrument perpetual, so exposing an expiry invents semantics.
- **Deliberate divergence (superseded by task 535 / C-T535a):** `FundingRate.interval` is `"1h"`,
  derived from Deribit's provider-documented hourly history and its registered 2026-08-04
  timestamp-spacing recording. The scalar endpoint's requested window remains separate from the
  venue cadence.
- **Live-only defect caught after tier-2 compatibility:** `fetch_balance` authenticated but
  silently returned empty maps because the real response is a top-level `summaries` collection.
  The authored keyed-collection rule now preserves each currency as `%Bourse.Balance{}` data.
- **Request-build gap closed (Task 220, verified live 2026-07-15):** the authored slice now maps
  Deribit's venue-wide unified request parameters and conditional endpoint choices. The T-A
  request gate is 85/85 green (formerly 26/85), and its 6 `get_tradingview_chart_data` fixtures
  pin the computed timestamps against CCXT's recorded values. `fetch_ohlcv` sends both required
  timestamps: `start_timestamp = since` and `end_timestamp = since + limit × timeframe`; a live
  testnet call returns CCXT `number[][]` raw candle rows (`[ts, o, h, l, c, v]` — the array OHLCV
  contract, not `%Bourse.OHLCV{}` structs) instead of JSON-RPC `-32602`, confirming the request-build
  against reality and is registered in the reality gate.

`authored`, `hand_owned`, and `frozen` are all true in the Deribit slice. Hand-owned markers mark
first-class specs as frozen against any bulk vendor replace (the former standing `mix ccxt.sync`
path is removed; long-tail bootstrap is ad-hoc only).

### OKX non-convert identifier_reference request renames (Task 342, 2026-07-18)

Task 237 made unresolved `identifier_reference` entries loud; task 342 then closed the residual
non-convert OKX bindings while leaving convert methods with task 308. The authoritative binding
table and its unchanged live EEA-demo pins now live at **C-T342** in
[the OKX carve register](authored-spec-carves/okx.md).

### Deribit residual identifier_reference request renames (Task 344, 2026-07-17)

Task 344 closed the residual Deribit bindings exposed by task 237's fail-loud sweep. The
authoritative method/native-key table, live testnet pins, and recorded residual scope now live at
**C-T344** in [the Deribit carve register](authored-spec-carves/deribit.md).

### Bybit non-convert identifier_reference request mappings (Task 343, 2026-07-18)

Task 343 closed the remaining Bybit non-convert selector mappings; task 360 later superseded the
retired cross-borrow route without changing the volatility binding. The authoritative binding
table, public-testnet pins, and supersession record now live at **C-T343** in
[the Bybit carve register](authored-spec-carves/bybit.md).

## OKX proof-loop completion (Task 208, 2026-07-15)

Applied the Deribit proof loop to OKX (EEA demo transport + passphrase signing already green from
task 212). The live-first probe exposed the balance parse hole: auth and `x-simulated-trading`
were green (`code: 0`, `data[].details[]`) but the unified read returned the raw map (and
callers hitting `balance.total` raised `KeyError: key :total not found`) because the authored
balance field map and envelope were null.

Tier-1 versus tier-2 outcomes:

- **Agreement:** OKX trading balance is `data[0].details[]` indexed by `ccy`; free prefers
  `availEq` then `availBal`; total prefers `eq` then `cashBal` (funding uses `bal`). Live demo
  currencies parse into `%Bourse.Balance{}` free/used/total maps.
- **Agreement (request shape):** `instId` is the symbol rename; `bar` is the timeframe rename
  (`1h` → `1H` via capabilities.timeframes); `limit` passes through. A prior identifier_reference
  rule rebound every non-symbol key to timeframe when both were required — fixed so only
  `bar`/`interval`/`resolution` take timeframe.
- **CCXT compatibility:** used is reconciled as `total − free` after the field map (CCXT
  `parseBalance` Precise subtraction). Raw `frozenBal` matches ordinary rows but overstates used
  when frozen exceeds equity (static fixture USDT: frozenBal 441.02 vs equity 0.000258796).
- **Tier-2 residual gaps (not blocking freeze):** multi-endpoint OHLCV history routing, market
  order-book `sz` rename, funding-wallet endpoint selection for `type=funding`, and computed
  ticker fields (average/vwap/percentage) remain incomplete vs the full static suite — same class
  of residual as other first-class venues pre-carve-complete. Balance free/used/total (the AC
  load-bearing gap) and public ticker/OHLCV live reads are green.

`authored`, `hand_owned`, and `frozen` are all true in the OKX slice.

## Bybit response landing (Task 223, 2026-07-16)

Task 223 is the **landing vehicle** for Bybit response work after four rejected
venue-wide bundles. It does **not** claim venue-wide green: positions, trades/ledger,
funding, market identity, orders, and the final account/analytics gate are tasks
230–235; remaining request-builds are task 229. The retained branch work (envelope
unwrap, parse-slot wiring, UNIFIED balance free/used) lands with the coupled
ticker/OHLCV slice.

Tier-1 versus tier-2 outcomes for this slice:

- **Agreement (ticker numbers):** Bybit V5 ticker prices/volumes are string decimals;
  unified fields coerce via `safeNumber`. Live and static fixtures agree on last/bid/ask
  and 24h volume keys (`lastPrice`, `bid1Price`/`ask1Price`, `volume24h`/`turnover24h`).
- **Agreement (percentage scale):** `price24hPcnt` is a **ratio** on the wire (e.g.
  `0.052785`); unified `percentage` multiplies by 100 (`scale: 100`) so consumers see
  percentage points (`5.2785`), matching CCXT-JS and live-checked semantics (2026-07-16).
- **Agreement (computed fields):** `average` = truncate-1 mean of last and prev 24h open;
  `change` = last − prev; `vwap` = turnover/volume when both present; missing operands
  drop the field rather than crash.
- **Agreement (OHLCV order):** Bybit `result.list` is newest-first; the authored envelope
  marks `order: "newest_first"` and the read path reverses to CCXT's oldest-first
  `number[][]` contract.
- **Agreement (UNIFIED balance free):** free is walletBalance minus
  totalPositionIM/totalOrderIM/locked/bonus (`value_op: subtract` + `operand_keys`);
  used reconciles as total − free. Deprecated empty `availableToWithdraw` is not the free
  source.
- **Request shape for this slice only:** `fetchTickers` derives `category` from
  type/subType/symbols and `baseCoin` for options; other methods remain task 229.
- **Residual (owned elsewhere):** market type/boolean identity (task 233), remaining
  response method groups (230–235), and venue-wide T-A green (task 235).

Parser mechanisms introduced for this authoring (reusable, not Bybit-only):
`zero_as_nil` on direct fields, computed `truncate`, keyed-collection `operand_keys` +
`subtract`, and nil-guard when any computed operand is missing.

`authored`, `hand_owned`, and `frozen` remain true on the Bybit slice (task 171 freeze).

## Project rename — `CCXT.*` → `Bourse` (executed 2026-07-26)

The North star says CCXT was the *bootstrap, not the destination* — the client is ours, by
our rules, correct against the real exchange APIs and deliberately diverging from CCXT's
ontology. The names `ccxt_client` / `CCXT.*` therefore now *overstate the dependency they
describe*: they label the project as a CCXT port when CCXT has been demoted to one disposable
reference among several. The name should follow the reality.

- **Chosen name: `Bourse`** — module namespace `Bourse`, OTP app `:bourse`. Rationale: it
  literally means "exchange", is multi-venue and crypto-neutral, reads cleanly as a short
  Elixir namespace, and carries no CCXT lineage. Confirmed available on hex.pm (2026-06-22)
  against a possible future publish. (Runners-up: `Venue` — names the core abstraction but
  generic; `Pelago` — distinctive but needs a tagline.)
- **The gates are closed.** T-E1/task 172 removed standing distill sync, T-E2/task 173
  removed the legacy interpretation layers, and task 523 retired the CCXT tier-2 oracle.
- **This is a coordinated breaking rename.** Consumers replace `{:ccxt_client, ...}` with
  `{:bourse, ...}`, `CCXT.*` with `Bourse.*`, app configuration under `:ccxt_client` with
  `:bourse`, and app-specific `CCXT_*` environment variables with `BOURSE_*`. A path consumer
  uses `{:bourse, path: "../bourse"}`. Consumers that cannot migrate in the same release pin
  `{:ccxt_client, "~> 0.6.1"}` until their namespace change lands.
- **Mechanics: `mix rename CCXT Bourse ccxt_client bourse`** (the `rename` hex package) as the
  bulk pass, then a manual token-by-token diff-review. The blanket `CCXT` → `Bourse` replace
  also rewrites the *genuine* upstream-CCXT references that must stay — `mix ccxt.*` task names,
  `ccxt-distill`, vendored-CCXT spec paths, and CCXT compatibility-reference prose — and several of
  those live in the same files (CLAUDE.md, mix.exs) as names that *should* change, so
  file-level `ignore_files` can't cleanly separate them. The tool is the bulk mechanism, the
  review is the arbiter. Full task spec: rmap task `182`.

## rmap reconciliation (done at filing — 2026-06-21)

Preserve the shipped-history ledger; triage the open backlog against the pivot:

- **Superseded (obsolete under the pivot):**
  - `133` (repoint signing fixtures *to* distill + regenerate) — directly contradicts T-A,
    which retargets the gate to the in-repo CCXT static fixtures; T-E1 removes distill sync.
  - `148` (fix the distill staleness hook) — that hook is *deleted* by T-E1; no point fixing it.
  - `163` (audit dynamic_construction/conditional_value request bindings: classifier vs
    hardcoded recipe) — subsumed: under authored specs the request recipe is authored directly
    from CCXT JS (T-C/T-D), so the classifier-vs-hardcode audit is moot.
  - `150` (typed SymbolPattern struct for `classify_pattern/2`) — `classify_pattern` is
    *deleted* by T-E2 (173). Under authored specs, market patterns become authored atoms in
    `markets.patterns` (plain spec data, no classifier to type), so the struct has no subject.
    Superseded outright. (Contrast `149`/ParsedSymbol — that types runtime `parse_extended/1`
    output and stays live.)
- **Kept, owns the whole order-book path:** `153` — *not* subsumed by T-D. order_book is
  **transformer-shaped, not field_map-shaped** (verified: no `order_book` in `@struct_for`, no
  spec carries an order_book field_map slot, the field_map coercion vocab is flat-scalar-only
  and can't extract `[[price,size]]` arrays; order books flow through the Task-44
  `:order_book_from_flat_list` transformer). So T-D authors no order_book field_map, and 153
  owns the whole read path (transformer wiring + `%Bourse.OrderBook{}` struct + sort/no-cross
  invariants) as one unit. `depends_on 168` only (the T-A static `fetchOrderBook` fixture
  verifies the transformer+struct output); phase 14 / `authored_specs`.
- **Deprioritized (left pending):** `155` (fresh full-catalog ~110-exchange evidence) —
  conflicts with the first-class focus; kept as a low-priority long-tail baseline, not picked
  ahead of the `authored_specs` phase.

### Routing note

Dispatchable routing is a **dispatch-time** decision (`routing-brief` / `dispatch-recommend`
against live KPIs), non-binding while filed — nothing dispatches from this branch. As filed,
to avoid reflex-codex: `168` → cursor/composer-2.5 (mechanical harness retarget), `170` →
codex/gpt-5.5 (judgment-heavy JS authoring). `grok` is intentionally not used here (stalled
twice in this repo) despite the generic spread-the-roster guidance.

## Verification

- **Reality oracle:** `mix ccxt.oracle_gate` grades the manifest-registered response
  recordings, accepted-request goldens, and recorded errors for all ten venues. This is the
  only verification oracle in `mix check.dispatch`.
- **Suite:** `mix precommit` (offline) stays green throughout; `mix precommit.full` before PR.
- **Live cross-check:** T39 `--include integration --include network` detects current venue
  drift; accepted observations are recorded and registered before they become CI evidence.
- **Removal safety:** after T-E1/T-E2, `mix compile --warnings-as-errors` + full suite green
  confirms no live code depended on the deleted heuristics.
