# Four-venue option execution readiness — convergence record (task 407)

Audit date: 2026-07-23 (orchestrator seat, live evidence via tidewave on the main
checkout). Durable matrix report: `option_readiness_1784812759202.json` (same dir) —
every cell and fill artifact below is linked there with timestamps and order ids.

**Closure summary — this milestone is NOT four-venue fill proof.** Three venues closed
via a live fill cycle; one closed via ledger deferral:

| Venue | Environment | Matrix status | Closed via |
|---|---|---|---|
| bybit | bybit-demo | `fill_ready` | **fill** — ATM call `BTC/USDT:USDT-260807-65000-C` 0.01 filled @ 2035 (delta 0.526), perp hedge 0.005 short @ 65021.8, `PortfolioRisk.snapshot` `:complete` mid-cycle, unwind, zero residual (`observed_at 1784812293721`) |
| deribit | deribit-testnet | `fill_ready` | **fill** — `BTC/USD:BTC-260731-65000-C` 0.1 filled @ 0.023 BTC (delta 0.521), inverse-perp hedge 3390 USD short @ 65051.5, snapshot `:complete`, unwind, zero residual (`observed_at 1784812374201`) |
| okx | okx-international-demo | `fill_ready` | **fill** — `BTC/USD:BTC-260724-66000-C` partial fill 0.19 ct @ 0.0055 (thin/slow but real), swap hedge 0.2 ct, snapshot `:complete`, reduceOnly limit unwind (market close rejected: 51066, pinned live), zero residual (`observed_at 1784812577099`) |
| derive | derive-demo | `market_unavailable` | **ledger deferral** — book 0/52 two-sided (`observed_at 1784812661779`); unified-path lifecycle proven (create `9f2afe87…` open → fetch via `fetch_open_orders` → cancel `canceled`, 0 open after); fill/hedge/unwind deferred via the open task-403 entry in `docs/prod-verification-ledger.md` (prod window: task 327) |

Notes against the acceptance criteria:

- The audit-time fill-capability set differs from the task body's 2026-07-19 expectation:
  deribit testnet had recovered from its 502 outage and carried 774 two-sided instruments,
  and the okx intl demo book — empty at ATM on 2026-07-19 — delivered a real (partial)
  fill at the ask. Both task-403 ledger entries are therefore **closed** with today's
  evidence; only derive's stays open.
- Derive's matrix row mechanically classifies `market_unavailable` (the empty-book rule
  precedes `order_lifecycle_ready` in `VenueRow.classify_status/1`). Its convergence class
  per this task's criteria is the lifecycle-plus-deferral path: lifecycle cell evidence is
  in this record and the ledger entry, never presented as fill evidence.
- No `venue_degraded` / `account_mode_missing` rows remain.
- No code changes were made by this audit (criteria met by evidence collection alone).

## Residual findings (not fixed here — routed per the proposal gate)

1. **Unified option-position reads mis-carve on two venues** (filed as a task): deribit
   `fetch_positions` returns a doubled option symbol
   (`BTC-31JUL26-65000-C/USD:BTC-31JUL26-65000-C`); okx reports option `contracts: 19.0`
   for a 0.19-contract position (×100 unit error). Both observed live mid-cycle
   2026-07-23.
2. **Readiness collector's preflight/hedge path can't reach `:ok` on any venue today**
   (filed as a task): the deribit hedge candidate carries no sourced price
   (`inverse_hedge_requires_price` despite task 505's candidate-price support), okx/bybit
   preflight is skipped for incomplete venue greeks/underlying, and a `mutate: true`
   lifecycle on derive would `:error` because the collector reads back via `fetch_order`
   (`:not_supported` there — the working read is `fetch_open_orders`).
3. OKX behaviors pinned live, not defects: options refuse market close (51066 — close
   below `minSz` works via reduceOnly limit); demo fills are thin/slow (marketable orders
   can rest, then partially fill).
