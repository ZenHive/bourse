# Authored Specs — provider-authoritative, reality-verified

Status: **active pivot** (branch `authored-specs`, phase `authored_specs`). This is the
durable design anchor; the `authored_specs` rmap tasks reference it.

## Read this first: authority and verification

The exchange-owned API contract is the semantic authority. A **live call** against the
venue establishes what the venue did; the provider's official docs/specs/SDK establish
what its fields and parameters mean.

Provenance for every external API claim, in this order:

1. Live E2E against the real host.
2. Understand one success and one relevant error from that interaction.
3. Write a REST-read contract case that hits the same host and asserts those semantics,
   inventoried in `priv/authority/rest-read-contracts.json`.

There is no replay layer. Nothing stored in this repository may stand in for a venue —
`test/bourse/no_faked_provider_oracle_test.exs` fails the suite on any `Req.Test`,
`Bypass`, `Mox`, `plug: {`, fixture path or `@tag :skip` under `test/`. Offline tests
cover our own mechanics (signing vectors, encoders, decimal arithmetic, URL construction,
the rate limiter, WebSocket dialect parsing, types) and nothing a venue owns.
Verification stays binary: a claim is `verified` only after steps 1–3 plus provider-owned
meaning, and `unverified` otherwise. CCXT source, execution, and static data are a pinned
third-party extraction — an authoring reference, never an oracle.

## The authority rule

**Interpret, don't extract — and make interpretation answerable to the venue.** The
exchange-owned API contract is the correctness authority: live raw behavior against the
venue's own host establishes what happens, and the exchange's own docs/specs/SDK establish
what it means.
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

**Scope:** the 11 first-class venues — `alpaca`, `deribit`, `okx`, `bybit`, `binance`,
`binancecoinm`, `binanceusdm`, `coinbaseexchange`, `hyperliquid`, `derive`, `lighter`. The ~100-exchange long tail stays as last-frozen vendored specs
(public-data-only); removing the *sync tooling* does not delete the vendored files.

### Vendored reference storage decisions

The client deliberately tracks its reference slice so a fresh clone compiles and
runs its own structural tests without fetching authoring inputs:

- The 16 documents in `priv/specs/json/output/` are test-only authoring references.
  Tests read their complete endpoint trees and symbol indexes, including five
  unsupported-venue counter-examples. Fetching them on demand would make those
  structural tests depend on a third party's availability; the 19 MB slice
  therefore remains tracked. They are a pinned third-party extraction and grade
  nothing a venue owns.
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
- **Three independent method facts are explicit.** `capabilities.has` is provider support:
  `true` means the venue has the operation, `false` means its contract exposes neither the
  operation nor primitives sufficient to derive it, and `"emulated"` means the venue exposes
  derivation primitives but no native operation. `"emulated"` says nothing about whether Bourse
  performs that derivation. `capabilities.mapping_complete` says only whether Bourse completely
  maps the authored unified route. `capabilities.verification` is `"verified"` only when a
  provider-live contract case covers that implementation; sandbox reachability may change this
  field and no other. The two implementation maps have exactly the `endpoints.unified` keys.
- **Callability is derived without conflation.** A provider-native declaration needs an authored
  route; provider-emulated operations are callable only through an authored raw route or an
  implemented Bourse emulation. Per-venue generated endpoint mappings use provider support plus
  a non-empty route; `Exchange.has?/2` uses the same callable outcome. Native feature declarations
  used by order validation remain available separately as `Exchange.venue_support`.
  `Bourse.describe/2` remains the global unified vocabulary and is not a venue-availability query.
  Verification never changes any of these surfaces. An incomplete read returns
  `{:ok, %Bourse.RawResponse{}}`, labelled with its payload, venue, method and verification state,
  instead of posing as a normalized result.
- **Unsupported is stricter than incomplete.** A provider-unsupported method carries no unified
  route. An offered method with an incomplete mapping retains its route and stays callable as a
  labelled raw read. Deleting a wrong route does not itself declare the provider operation
  unsupported. Endpoint presence, `reason`, `_unresolved_reason` and compatibility-reference
  capability values cannot create provider support.
- **Runtime-only surface.** Extraction ASTs, source receipts, provenance payloads, method
  inventories and test-only symbol indexes are forbidden by path. Evidence remains in the
  authority and carve surfaces; integration symbol selection reads the frozen reference
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
  (carve C-T164a); the remaining first-class venues declare `false`.

### Adding a venue

There is no promotion tooling. A candidate-to-owned boundary is hand-authored work, and it is
judged by the same rules as every other slot rather than by a task's report.

An owned document starts from a pinned reference's mechanical endpoint tree and metadata only —
reference-only payloads and raw capability claims are stripped, and signing, authenticated
sections, request shape, unified routing, normalization, symbols, errors, emulated methods,
WebSocket semantics and every method support decision are authored, each one `verified` or
`unverified` with nothing in between.

A venue is not addable on unresolved interpretation; on third-party evidence; on incomplete
public or authenticated success/error observations; without provider-owned semantics; on unsafe
or incomplete create/fetch/cancel evidence for a trading venue; on skipped or credential-less
tests; without the carve and authority artifacts; on schema failures; or with any critical slot
lacking a live success and a relevant live error against the venue's own host. Those calls are
inventoried in `priv/authority/rest-read-contracts.json` and run by
`mix ccxt.verify_rest_read_contracts`, so the venue carries reality provenance whether or not a
third-party reference for it exists. A written owned document is still not a supported venue:
the named venue delivery must separately add it to `Bourse.Spec`, the registry, and the
compiled set.

## The epistemology — provider-owned contract, binary verification

We build the client ourselves, by our own rules, but those rules answer to the exchange API.

| Role | Allowed sources | Verification effect |
|---|---|---|
| **Semantic authority** | Exchange-owned docs/specs/SDKs | Required meaning for a verified claim |
| **Observed behavior** | Live API call (success and a relevant error) | Establishes what the venue actually did |
| **Authoring reference** | CCXT source/execution/static data, training, third-party docs, general web | Implementation clue only; claim remains unverified |

If author and grader share the same third-party interpretation, both can converge on the same
wrong belief. A live venue call is the grader for every claim, new or old — a stored response
can only tell us our own parsing changed, and it says so silently and forever once the venue
moves. `mix ccxt.verify_rest_read_contracts` therefore re-asks the venue rather than replaying
an answer, and its runner fails when executed cases fall below the inventoried denominator, so
a shrinking live surface cannot pass as green. CCXT-derived data can help discover or compare
behavior, but cannot make a claim verified.

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
| **Evidence** | `verified`, `unverified` | Whether a provider-live contract case covers the claim |
| **Reachability** | `safe`, `unsafe`, `unreachable`, `unknown` | Whether and how a live call may be made |
| **Contract scope** | `current_rest`, `upcoming_rest`, `current_websocket`, `upcoming_websocket` | Which provider surface defines the denominator |

The axes are machine-readable. The comparator may carry forward registered facts, but it never
makes semantic or safety judgments: absent evidence is `unverified`; absent runtime or
reachability evidence is `unknown`. Only a passing provider-live contract case can advance the
evidence axis. Upcoming methods remain forward-compatibility observations, not missing
current-runtime methods.

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
 "observed_evidence":{"kind":"live_venue","reference":"200 body, alpaca market-data host"},
 "compatibility_reference":null,
 "resolved_tier":1}
-->
```

**Supersession is by date, not by edit.** Append a new block; the latest `date` for a
`carve_id` is the current status and outranks every earlier block and every `*Verification:*`
line for that carve. Earlier blocks stay as provenance. Two blocks sharing one date is an
error — nothing can order them.

Field rules — an authoring convention since the consistency gate was removed with the replay
lane, so nothing mechanical grades them now:

- `resolved_tier` is `1`, `2`, or `3`, and is the tier the § "Compatibility ≠ correctness"
  table defines.
- **Tier 1 requires two independent facts**, matching the authority rule: a
  `semantic_source` of kind `provider_owned`, *and* an `observed_evidence` of kind
  `live_venue`, each with a non-empty `reference`. Docs alone, a closed ledger entry alone, or
  anything of kind `ccxt` can never reach tier 1 — CCXT belongs in `compatibility_reference`,
  which never affects the tier. Blocks of kind `recorded_venue` predate the removal of the
  replay lane; they stay as the record of what was observed then, and a new block names the
  live contract case instead.
- **Tier 2/3 requires `known_gap_reason`** — say what is missing, so the gap is a record
  rather than a silence.
- A `docs/prod-verification-ledger.md` entry and a register status must agree. When a live
  call closes a ledger entry, drop the entry and append the tier-1 status in the same change.
- Every carve section carrying `*Verification:*` prose must have a status block, so legacy
  prose can never be the only tier claim.

**Registers do not use a bare `Oracle:` label.** It reads as a correctness claim regardless of
what follows it. Write `Evidence sources:` and let the status block carry the tier.

## Discovery and grading are both live

The authoring order is real call → understand → inventory the branch → assert against the
venue. Live calls discover the venue's current response and error shapes, and the same live
calls grade the slice afterwards: `priv/authority/rest-read-contracts.json` names every
supported read operation and provider-defined semantic branch, and
`mix ccxt.verify_rest_read_contracts` executes them against the venues' own hosts, reporting
denominator, executed and failures. Drift is not something a periodic re-capture detects
later; the gate meets it on the next run. Nothing runs on a schedule: the lane proves the
surface only when a person or a harness run executes it on this host.

## Authoring nuance — not all normalization is field_map-shaped

### Field-rule data source

A field rule reads from the extracted row by default; authors may state
`"source": "row"` explicitly. Use `"source": "envelope"` when the provider
places that field on the original decoded response outside the row selected by
`normalization.response_envelopes`. The rule's `key`, fallbacks, coercion, and
format are then applied to the envelope without changing how the row itself is
selected. `Bourse.Spec.Schema` rejects any other source value.

Envelope-sourced fields need a live response that carries the envelope key. The
contract case asserts the parsed value against that response and fails when the
parse drops it; declaring the rule is not verification.

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
that was ported wholesale from Bourse. How much a case asserts is orthogonal to this: a thin
live assertion inherits the same vocabulary, it just checks less of it. So authoring a venue
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

