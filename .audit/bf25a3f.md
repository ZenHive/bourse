# Post-merge audit — bf25a3f

Range audited (already merged, never reverted):

- `099d4c9` document task 649 for the reported stop-market capability regression
- `7fbd1c6` correct and retract that report after live consumer verification
- `a792766` task 642 unify caller-input error behavior at the non-bang boundary
- `bf25a3f` task 641 author the Bybit inverse-position contract unit

## Scope reviewed

- **Runtime code** — `Bourse.Unified.call/5` error normalization,
  `Bourse.Unified.RequestShape` maximum-length validation, and Bybit position
  annotation in `Bourse.Unified.ReadParse`.
- **Tests and evidence** — non-bang/bang validation tests, the preserved
  `OrderPrecision` raise contract, position-unit invariants, recorded-position
  payload-key checks, and the Bybit fixture-backed carve evidence.
- **Consumer documentation** — `[Unreleased]` in `CHANGELOG.md`, the Bybit and
  global carve registers, and the withdrawn `BUGS.md` report.

## Findings

1. **Consumer CHANGELOG coverage was incomplete and stale (fixed).** Task 641's
   consumer-visible inverse-position `contract_size` was absent. The existing
   Deribit client-ID entry also said values longer than 64 characters raise,
   although task 642 makes the non-bang API return an `:invalid_parameters`
   tuple while preserving the bang raise. Added the Bybit position behavior and
   documented both Deribit contracts.

2. **The withdrawn bug entry missed the queue's status convention (fixed).**
   The heading and later retraction explained the outcome, but the entry lacked
   the required current `**Status:**` header. Added an explicit withdrawn status
   naming the consumer's Spot/USD-M mismatch, retained the original report as
   evidence, and removed the trailing blank line introduced by the append.

## Checked and clean

- The task-642 rescue remains narrow: only the two caller-input reasons become
  tuples, while unrelated `Bourse.Error` exceptions are re-raised. Tests pin
  the non-bang tuple, bang raise, and `OrderPrecision` fail-loud guard.
- The task-641 change removes the obsolete inverse/linear helper and stamps the
  authored unit on the shared Bybit position annotation path. The invariant
  test now rejects keys absent from populated venue recordings, including the
  formerly injected Bybit `contractSize` key.
- No leftover debug output, bare TODO/FIXME, dead helper, inconsistent new
  naming, or whitespace error remained in the landed range.

## Cold-build witness

Ran `mix deps.get`, then `mix check.dispatch`, in the intentionally un-warmed
worktree. Dependency resolution succeeded and the cold compile reached the
offline suite: **3,945 passed / 1 failed / 287 excluded**. The sole failure was
`test/mix/tasks/ccxt_agents_md_test.exs:407`: harness prepends its ephemeral
operation rules to the working `AGENTS.md`, so the committed-tree freshness
test reports `STALE`. The injected file was preserved and excluded from this
audit commit. The red post-merge fact did not revert, unmerge, or block the
settled range.

## Discoveries filed

None. Every concrete hygiene issue was small enough to fix in this audit; no
separate rmap task was warranted.

## Reviewer-rejection note

No reviewer rejections were supplied for this project, so no false-rejection
assessment applies.
