# Post-merge audit — ca7abaf

Range audited (already merged, never reverted):

- `98978d2` task 653 RequestShape caller-input `ArgumentError` → `Bourse.Error`
- `9631b7f` / `d0aabbe` task 658 dated-future `convert_date/3` catch-all and pattern-conversion tests
- `305b5db` / `1c10e13` / `ca7abaf` task 650 scheduled live lane: corpus, auth smoke, first-frame matrix

## Scope reviewed

- **Runtime code** — `Bourse.Symbol.convert_date/3`, RequestShape caller-input
  raises on Binance / Hyperliquid / Lighter / OKX, unified
  `@caller_input_reasons`, live-lane aggregation, first-frame probes, and
  `ops/live-drift.sh`.
- **Operator surface** — `mix ccxt.verify_ws_first_frame`,
  `mix ccxt.aggregate_live_lane`, GitHub `live-drift.yml`, authority README,
  CLAUDE/AGENTS mix-task inventory, Hex unpackaged `live_lane` prefix.
- **Tests and documentation** — live-lane completeness and classification
  tests, RequestShape class sweep, dated-future round-trips, `[Unreleased]`.

## Findings

1. **Reviewer-fixes committed generated live-lane reports (fixed).**
   `1c10e13` added `artifacts/authority-drift-report.txt`, a 2.1MB
   `live-corpus-report.json`, and `live-drift-report.json` from a local
   lane run (absolute implementer-worktree paths, compile chatter, full
   `--all` test dump). Those files are operator/CI output, not source.
   Removed them from the tree and gitignored `/artifacts/`.

2. **`[Unreleased]` omitted the three landed consumer/operator changes
   (fixed).** Added entries for the live-lane first-frame/corpus expansion,
   the remaining RequestShape caller-input tuple conversion, and the
   dated-future `convert_date/3` pass-through.

3. **Dead `continue_after_ack/4` branch (fixed).**
   `frame_kind(:success, frame)` is always `"acknowledgement"`, so the
   `acknowledgement_with_payload` arm could never run. Payload-bearing
   acks already arrive as `{:success, :data}` from `SubscribeAck`. Collapsed
   the helper to wait for the next classified frame.

## Checked and clean

- Remaining RequestShape `ArgumentError` sites are the 651-classified
  setup/spec guards (markets not loaded, missing asset_index/precision,
  unknown open-interest endpoint path, account-index parse). Hyperliquid
  already splits unknown symbol to `:bad_symbol`.
- No leftover `IO.inspect`, `dbg`, bare TODO/FIXME, or debug prints in the
  landed range.
- CLAUDE.md and AGENTS.md both name the new mix tasks; `mix ccxt.agents_md
  --check` was green. `live_lane` is on the unpackaged prefix list.
- First-frame completeness covers every runtime venue on public and private
  surfaces; exclusions name a reason and a task-tracking reference.
- Lighter `find_market!/2` still raises `ArgumentError` when a loaded
  market list has no matching symbol. That is the same class Hyperliquid
  already split into caller-input `:bad_symbol`. The 651 sweep already
  watches remaining RequestShape `ArgumentError` messages, so no separate
  rmap task was filed.

## Verification

- `mix test.json --quiet --output /tmp/audit-ca7abaf-focused.json
  test/bourse/live_lane_test.exs test/mix/tasks/ccxt_live_lane_test.exs`:
  **30 passed / 0 failed**.
- `mix check.dispatch`: **passed**. Offline suite **4,001 passed / 0 failed
  / 288 excluded**. Oracle gate, authority check, error authority,
  `ccxt.claude_check`, `ccxt.agents_md --check`, `ex_dna --max-clones 0`,
  and `reach.check --arch --smells --strict` all passed.

## Cold-build witness

Ran `mix deps.get && mix check.dispatch` in the intentionally un-warmed
worktree (no copied `deps/` or `_build/` at start). First compile built
deps and the project; the dispatch gate finished green as above. This
post-merge fact did not revert, unmerge, or block the settled range.

## Discoveries filed

None. The concrete hygiene issues were small enough to fix in this audit.
The leftover Lighter unknown-symbol `ArgumentError` stays under the
existing 651 class sweep rather than a new task.

## Reviewer-rejection note

No reviewer rejections were supplied for this project, so no false-rejection
assessment applies.
