# Post-merge audit — e0aaaea

Range audited (already merged, never reverted):

- `e0aaaea` harness: agent delivery — task 621 signed-request re-sign on retry
- `9f2a32b` harness: agent delivery — task 611 Deribit linear future contract units
- `52cfb84` harness: reviewer fixes — task 620 compare shape keys, not clocks
- `1f8bb36` harness: agent delivery — task 620 shape-check recaptured caller_params
- `17a6e7b` harness: reviewer fixes — task 614 pin SETTLEMENT funding/change split
- `f7d5af5` harness: agent delivery — task 614 Bybit SETTLEMENT amount sources `funding`
- `620745f` docs(position): qualify notional settlement unit and `base_quantity` set
- `36a9e04` harness: agent delivery — task 615 caller-wins authored conditionals
- `97d54d8` harness: agent delivery — task 619 refresh Deribit current-REST OpenAPI pin

## Scope reviewed

- **Library code** — `Bourse.Dispatch` / `Bourse.HTTP` re-sign-on-retry,
  `Bourse.Unified.DeribitPositionUnits`, `Bourse.Unified.RequestShape`
  conditionals, `Bourse.Position` field docs, Bybit authored ledger `when`
  recipes, and the request-congruence shape walk.
- **Oracle / capture** — `OracleProvenance.DeribitPositionUnits`, capture
  `market_contexts` / `oracle_membership`, Deribit `fetch_positions`
  recording, and the OpenAPI rebind of authority + provider-operation
  artifacts.
- **Docs / consumer queue** — CHANGELOG `[Unreleased]`, BUGS entries for
  tasks 615 and 621, Deribit C-T610f/C-T611 and Bybit C-T609a carves.

## Findings

1. **CHANGELOG gap (fixed).** None of the four consumer-facing deliveries
   (621, 611, 614, 615) wrote `[Unreleased]` — correct for harness delivery
   commits, but the maintained section then had no record of re-sign-on-retry,
   the linear Deribit `contracts` divisor correction, the Bybit SETTLEMENT
   amount source, or caller-wins conditionals. Tasks 619 and 620 are
   authority/oracle tooling and need no consumer changelog. Added a
   `Changed` breaking note for 611 and three `Fixed` entries.

2. **Stale BUGS 621 status (fixed).** The 2026-08-18 signed-retry entry still
   read 🔀 triaged, and its current-state sentence still cited pre-fix
   `dispatch.ex` / `http.ex` line numbers. Header now says ✅ fixed, names the
   `/5` resigner path and the injected-408 pins, and keeps the triage as the
   evidence trail.

3. **Stale BUGS 615 status (fixed).** The conditional-clobber entry still
   said 🔧 **fixed in worktree** after `36a9e04` landed on `main`. Header now
   says ✅ fixed and keeps the live Deribit trigger evidence.

## Checked and clean (no action)

- **No leftover debug / dead code.** No `IO.inspect` / `dbg` / bare TODO in
  the added lib lines. `oracle_provenance` still unpackages the new
  `DeribitPositionUnits` oracle module.
- **Task 621 is sound.** Dispatch re-signs before every Req retry; `/4` is
  forced single-attempt; exhausted retries return the injected 408
  (`:network_error`), not a follow-on recv-window rejection. Both a
  query-signed (Binance) and a nonce-signed (Deribit) pattern are pinned.
- **Task 611 matches the carves.** Linear `contracts` divide base
  `size_currency` by base `contract_size`; inverse keeps quote division.
  `Position` docs already qualify notional as the venue settlement unit
  (`620745f`). Dual C-T609a evidence-status blocks are the allowed
  append-only history (`current_evidence_statuses/1` takes the latest date).
- **Task 620 reviewer fix is load-bearing.** Comparing rebuilt shape *values*
  would have let clocks (`auth_deadline`, `nonce`) mask a dropped caller
  key; the landed walk compares keys.

## Cold-build witness

Ran `mix deps.get && mix check.dispatch` in this intentionally un-warmed
worktree. Result: **passed (exit 0)** — precommit, `ccxt.oracle_gate`
("all modules verified", "binary oracle exact-set ratchet passed"), lighter
signer build + parser coverage 95.78%, `ccxt.claude_check` ("mechanical
claims match the tree"), `ccxt.agents_md --check` ("AGENTS.md is up to
date"), `ex_dna` (no duplication), and `reach.check` (architecture + smells
OK) all green.

## Discoveries filed

None. Every concrete issue found was small enough to fix inline; no
separate rmap task was warranted.

## Reviewer-rejection note

The supplied recent rejection concerns task 551, which is not in this
range, so no false-rejection assessment applies.
