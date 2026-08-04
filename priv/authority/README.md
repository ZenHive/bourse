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

Every selected artifact currently lacks a clear artifact-specific redistribution
grant. The manifests therefore retain URL, upstream pin, retrieval date, byte
count, and SHA-256 only. No upstream content is committed. The shared fetch
script materializes pinned bytes into a caller-selected directory outside this
tree and verifies them before use.

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
to the recorded pin. Drift is a prompt to review the semantic diff before refreshing
the pin, not permission to update the hash merely to make the check green.

## Selected sources

| Venue | Currently pinned artifact | Contract role and limit |
|---|---|---|
| Alpaca | Selected official API documentation pages | Partial REST semantics; not a complete inventory |
| Binance | Official Spot OpenAPI + error documentation | Typed Spot REST inventory at the pinned revision |
| Binance COIN-M | Official developer-docs `llms-full.txt` | REST prose/inventory snapshot; no schema guarantee |
| Binance USD-M | Official developer-docs `llms-full.txt` | REST prose/inventory snapshot; no schema guarantee |
| Bybit | Official V5 documentation source archive | REST/WS prose and examples; no OpenAPI typing |
| Deribit | Current official OpenAPI 3 + error documentation | Typed current REST inventory; upcoming REST and AsyncAPI are not yet pinned |
| Derive | Official documentation `llms.txt` + error documentation | Page index and error semantics; not an OpenAPI schema |
| Hyperliquid | Official documentation `llms-full.txt` | REST prose; SDK sub-specifications are not yet pinned |
| Lighter | Official-SDK OpenAPI 3 | Typed REST inventory at the pinned SDK revision |
| OKX | Official API v5 documentation snapshot | REST/WS prose snapshot; no first-party OpenAPI |

Freshness, expressiveness, and scope are orthogonal. Current REST, upcoming REST,
and WebSocket artifacts are tracked separately; no artifact proves live behavior.
