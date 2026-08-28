# Exchange authority corpus

This tree is the first stop for venue-source discovery, planning, contract-coverage
work, and authoring or judging a first-class venue field. The manifest is the local
provenance index, not the authority itself: read it first, then check the provider's
official upstream when the question is freshness or whether another first-party
artifact exists. Pin every newly-relied-on artifact before it drives authoring. The
exchange-owned artifact establishes intended semantics; CCXT and third-party
aggregators remain reference material.

These are **read-only authority references**. Never hand-patch an artifact: a
local edit stops being the exchange's statement and voids its authority. Refresh
provenance, pin, byte count, and hash together from upstream.

Every artifact records independent machine-readable `freshness`,
`expressiveness`, `scope`, and `authority` facts. Partial, stale, inconsistent,
or untyped sources remain useful references but cannot declare themselves
completeness gates. No upstream content is committed. The shared fetch script
(`scripts/fetch_authority.sh` in the `bourse_workbench` authoring repo — the
manifests' `fetch_script` value names it; this repo carries no copy)
materializes pinned bytes into a caller-selected directory outside this tree and
verifies them before use.

Each venue's `errors.json` is a committed normalization of the official error
enumeration: identifiers and concise meanings, without the upstream document's
presentation. Its manifest entry pins both the normalized file and the official
source artifact. `mix bourse.error_authority` validates authored exact mappings
and reports dropped, retired, and provider-only identifiers. Maintenance-state
routing is recorded in each corpus's `maintenance_adjudication` field and
summarized in `docs/error-maintenance-adjudication.md` (task 490): documented
service-down codes map to CCXT `OnMaintenance` → `:exchange_not_available`;
venues with no such code record that finding instead of inventing a sentinel.

## Checks

```sh
mix bourse.authority_check                    # offline manifest/local-hash validation
mix bourse.error_authority                    # offline error-enumeration adjudication
mix bourse.authority_check --online           # explicit network drift check
scripts/fetch_authority.sh /tmp/bourse-authority
mix bourse.contract_compare --artifacts /tmp/bourse-authority --output /tmp/contract-reports
mix bourse.verify_rest_read_contracts         # provider-live REST-read contract lane
```

The offline command validates manifest structure and any locally vendored bytes; it
cannot detect remote drift for reference-only artifacts. `--online` verifies each
pinned fetch and then compares the mutable upstream hash (or Bybit repository HEAD)
to the recorded pin. Typed OpenAPI and AsyncAPI drift is blocking. Other governed
roles are prose/docs for drift policy: a mismatch emits an `AUTHORITY_DRIFT` report
line and passes only when `freshness.status` is `drift_detected` and `checked_at` is
no more than 30 days old. Nothing runs the check on a schedule — the window only
prevents an acknowledgment from becoming permanent, and a person has to run
`mix bourse.authority_check --online` for it to mean anything. A missing or older
acknowledgment blocks again.

`checked_at` is the date a prose/docs mismatch was acknowledged, not an automatic
pin refresh. Drift remains a prompt to review the semantic diff before refreshing
the pin, never permission to update the hash merely to restore green.
`initial_baseline` means the artifact entered the index at that pin; it is not a
claim that prior remote bytes drifted.

## Retention — what a drift review can answer

The gate detects drift by content hash. What a later review can *name* depends on
what the tree retained when the previous pin was current. Retention is decided
per artifact class; it is not a third storage mode and it does not migrate
`reference_only` artifacts.

Storage modes are unchanged:

| Storage | What lives in the tree | License rule |
|---|---|---|
| `reference_only` | provenance only (`path` is null) | required for unclear licensing |
| `vendored` | full upstream bytes | explicit redistribution permission |

Full-byte retention of the pinned corpus is declined. The numbers as of
2026-08-18: deribit `current-asyncapi` is 610300 bytes and `api-openapi` is
1438107; the eight typed OpenAPI/AsyncAPI pins together are about 5.5 MB; the
entire pinned corpus (including Bybit's 12.6 MB docs archive, the two Binance
futures `llms-full` files at ~7.9 MB each, and OKX's 5.2 MB HTML snapshot) is
about 52 MB. Vendoring that would make the authority tree a content store, which
`mix bourse.authority_check --fetch` deliberately keeps outside `priv/venues/<venue>/authority/`.

What *is* retained, by class:

| Artifact class | Retained | Cost | What a drift review can answer from repo state |
|---|---|---|---|
| `typed_openapi`, `typed_asyncapi` | `surface-digests/<artifact-id>.json` — sorted channel / path / operation key sets, key-set hashes, and per-entity hashes | a few KB per pin (the 2026-08-18 deribit current AsyncAPI digest is tens of KB, not 610300 bytes) | which named channels, paths, or operations entered, left, or changed identity |
| untyped Postman, prose, HTML, `llms.txt`, source archives | nothing beyond the pin | zero | only that the hash moved. Name the delta by refetching the live document and confronting the authored slice; the previous page is gone once the provider republishes |

A missing digest does not fail `mix bourse.authority_check`. `reference_only`
artifacts stay valid without one, so the change is additive: existing pins and
drift reports keep working. When a digest *is* present, the offline check
requires `source.sha256` / `source.bytes` to match the manifest pin.

`ContractSource.surface_digest/2` builds a digest from materialized bytes.
`ContractComparator.diff_surface_digests/2` names the added and removed keys.
`ContractComparator.review_retained_surface/4` diffs current bytes against the
retained digest, or — when the bytes still match the pin — against the digest's
`prior` slice so a completed republish remains nameable after the old document
has disappeared.

The 2026-08-18 deribit current AsyncAPI republish is the regression: the hand
review recorded the three added channels as `unnameable_prior_bytes_not_retained`
because storage was `reference_only`. Re-running
`ContractComparator.review_retained_surface/4` against the retained digest names
`user.isolated.liquidation`, `user.liquidation`, and `user.lsp`.

For `storage: reference_only` artifacts that still have no digest, compare the
current upstream against the authored slice and record the semantic review
alongside the manifest before changing the pin — that establishes whether the
authored surface survived, not what the provider gained.

`authority.semantic_authority` also depends on the other axes: an artifact marked
`known_stale`, or any artifact whose scope is only `index_only`, must set it to
`false`. Such artifacts remain useful discovery or historical references, but they
cannot establish current provider semantics.

`bourse.contract_compare` performs no network access. It verifies each available
artifact against this corpus, writes one deterministic report per venue, and
states an explicit source-capability limit for missing, prose-only, partial, or
untyped inputs. Its differences are findings for later provider confrontation,
not implementation or deletion decisions.

`mix bourse.verify_rest_read_contracts` is the provider-live oracle: it runs the
complete REST-read contract inventory against the venue's own host.

## Selected sources

| Venue | Currently pinned artifact | Contract role and limit |
|---|---|---|
| Alpaca | Official pages + repository trading/data OpenAPI | Repository schemas are provider-declared stale; pages are partial and remotely drifted |
| Binance | Official Spot OpenAPI, docs, Postman + errors | Typed REST inventory plus untyped REST/WS references |
| Binance COIN-M | Official developer docs + Postman | REST/WS prose and untyped request collection; no official futures OpenAPI published |
| Binance USD-M | Official developer docs + Postman | REST/WS prose and untyped request collection; no official futures OpenAPI published |
| Bybit | Official V5 docs source + Postman | REST/WS prose and untyped request collection |
| Deribit | Current/upcoming OpenAPI, current/upcoming AsyncAPI, `llms.txt`, errors | Five separately scoped contract surfaces; current REST refresh has a committed semantic-diff report |
| Derive | Official documentation `llms.txt` + error documentation | Page index and error semantics; not an OpenAPI schema |
| Hyperliquid | Official documentation + Python SDK API fragments | Full prose plus partial typed `info` sub-specifications |
| Lighter | Official-SDK OpenAPI 3 | Typed REST inventory at the pinned SDK revision |
| OKX | Official API v5 documentation snapshot | REST/WS prose snapshot; no first-party OpenAPI |

Freshness, expressiveness, and scope are orthogonal. Current REST, upcoming REST,
and WebSocket artifacts are tracked separately; no artifact proves live behavior.
