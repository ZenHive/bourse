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
source artifact. `mix ccxt.error_authority` validates authored exact mappings
and reports dropped, retired, and provider-only identifiers. Maintenance-state
routing is recorded in each corpus's `maintenance_adjudication` field and
summarized in `docs/error-maintenance-adjudication.md` (task 490): documented
service-down codes map to CCXT `OnMaintenance` → `:exchange_not_available`;
venues with no such code record that finding instead of inventing a sentinel.

## Checks

```sh
mix ccxt.authority_check                    # offline manifest/local-hash validation
mix ccxt.error_authority                    # offline error-enumeration adjudication
mix ccxt.authority_check --online           # explicit network drift check
scripts/fetch_authority.sh /tmp/ccxt-authority
```

The offline command validates manifest structure and any locally vendored bytes; it
cannot detect remote drift for reference-only artifacts. `--online` verifies each
pinned fetch and then compares the mutable upstream hash (or Bybit repository HEAD)
to the recorded pin. Typed OpenAPI and AsyncAPI drift is blocking. Other governed
roles are prose/docs for drift policy: a mismatch emits an `AUTHORITY_DRIFT` report
line and passes only when `freshness.status` is `drift_detected` and `checked_at` is
no more than 30 days old. The 30-day window gives the weekly lane four review
opportunities while preventing an acknowledgment from becoming permanent. A
missing or older acknowledgment blocks again.

`checked_at` is the date a prose/docs mismatch was acknowledged, not an automatic
pin refresh. Drift remains a prompt to review the semantic diff before refreshing
the pin, never permission to update the hash merely to restore green. For
`storage: reference_only`, compare the current upstream against the authored slice
because prior upstream bytes are not retained; record the semantic review alongside
the manifest before changing the pin. `initial_baseline` means the artifact entered
the index at that pin; it is not a claim that prior remote bytes drifted.

`authority.semantic_authority` also depends on the other axes: an artifact marked
`known_stale`, or any artifact whose scope is only `index_only`, must set it to
`false`. Such artifacts remain useful discovery or historical references, but they
cannot establish current provider semantics.

## Weekly lane contract

`ops/live-drift.sh` is the canonical lane entry point for both the always-on operator
host and the manual GitHub fallback. The host syncs the target branch before each
run, invokes `bash ops/live-drift.sh artifacts`, and sends a successful healthcheck
ping only when that command exits zero. The script always runs both authority drift
and live provider checks, then exits nonzero if either return code is nonzero; the
authority return code is therefore part of the alarm again. GitHub calls the same
script and uploads both reports, so its manual fallback has identical gating
semantics.

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
