# Static fixture vintages

These frozen CCXT static fixtures are the tier-2 compatibility oracle. They are
**read-only vendored artifacts**: refresh a directory wholesale from the named
CCXT release, never hand-edit an individual value. A locally-patched fixture
stops being CCXT's interpretation and becomes ours, which silently voids every
gate that reads it.

| Directory | CCXT version | Refreshed | Verified against upstream |
|---|---:|---|---|
| `request/` | 4.5.57 | 2026-06-22 | task-430 set except `derive`, `hyperliquid` (see below); Lighter added from the on-disk vintage (task 501) |
| `response/` | 4.5.65 | 2026-07-19 | all 6 task-430 files content-equal; `binance`, `deribit`, `derive` differ only by a trailing newline; Lighter added from the on-disk vintage (task 501) |
| `markets/` | 4.5.65 | 2026-07-17 | all 6 task-430 files byte-equal; Lighter added from the on-disk vintage (task 501) |
| `currencies/` | 4.5.65 | 2026-07-17 | all 6 task-430 files byte-equal; Lighter added from the on-disk vintage (task 501) |

`markets/` and `currencies/` are the support caches used by replay; `response/`
is the parse oracle. Task 430 re-froze `response/` from 4.5.65 to match the
caches, then verified every file in all four directories against the upstream
tag (see the recipe below).

## Known local deltas

- **`request/derive`** carries one extra `fetchCurrencies` case, and
  **`request/hyperliquid`** omits `isUnifiedEnabled` plus some
  `enableUnifiedMargin` keys, relative to 4.5.57. These predate task 430. A
  future refresh of `request/` must re-apply them deliberately or drop them
  deliberately — restoring the directory wholesale silently discards them.

## Cross-directory consistency

`currencies/` and `response/` are two vendored views of the same CCXT parse, so
a chain's unified network code must not depend on which one it came from. That
invariant is asserted offline by
`test/ccxt/recorded_response_fixtures_test.exs` ("currency caches and response
fixtures agree on their shared network codes"), against an adjudicated baseline
that fails on any change in either direction.

One skew is **upstream's, and is retained rather than patched away**: at 4.5.65,
from the same raw bybit row (`chain: "OP"`, `chainType: "OP Mainnet"`),
`currencies/bybit.json` says `OPTIMISM` while `response/bybit.json` says `OP`.
CCXT took the two snapshots either side of its own network-code rename and never
regenerated the cache, so **no single CCXT release makes them agree** — version
pinning cannot close this one. Editing the vendored cache to `OP` would fabricate
a value present in no CCXT release; the baseline records it instead.

## Verifying a directory against its tag

Offline gates never do this (they run against the frozen files); run it by hand
after any refresh:

```sh
tag=v4.5.65; dir=currencies; venue=bybit
curl -sS -o /tmp/up.json \
  "https://raw.githubusercontent.com/ccxt/ccxt/$tag/ts/src/test/static/$dir/$venue.json"
diff <(jq -S . "priv/specs/json/ccxt/ts/src/test/static/$dir/$venue.json") <(jq -S . /tmp/up.json)
```
