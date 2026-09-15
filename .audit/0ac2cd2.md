# Post-merge audit — `972c1e8..0ac2cd2`

Range: 22 commits, `972c1e820bd1ce5b145a24595141af6888e7014a..0ac2cd2` (48 files,
+3060/−358). Audited 2026-09-15 in a cold landing worktree.

The merge is settled. Nothing below reverts or blocks; every fix is forward.

## What was reviewed

- **Code** (`lib/`): the task 686 read-payload work (`unified.ex`,
  `unified/read_parse.ex`, the new `unified/request_shape/deribit.ex`) and the
  task 691 Coinbase candle pagination rewrite (`coinbase_exchange.ex`).
- **Tests**: the two new files (`coinbase_candle_pagination_test.exs`,
  `unified/read_payload_honesty_test.exs`) and the live/journey/contract edits.
- **Authored specs and authority JSON**: bybit normalization branching, bybit
  `fetchBalance` endpoint list, deribit `impliedVolatility`, the binance-family
  and bybit contract inventories.
- **Docs and conventions**: `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md` pins,
  `README.md`, `CONTRIBUTING.md`, `BUGS.md` triage, the carve register and the
  prod-verification ledger.
- **Claimed counts vs the tree**: the REST-read contract denominator documented
  in `CLAUDE.md` (407) was recomputed from the eleven authority documents —
  branches + error cases sum to exactly 407. No drift.
- **Leftover debug output**: none. No `IO.inspect`, `IO.puts`, `dbg(`, `TODO`,
  `FIXME` or `XXX` added anywhere in the range.

## Findings and fixes

### 1. `CHANGELOG.md`: task 686 shipped in v0.8.0 undocumented — FIXED

Task 686 landed at `c6ebd79` and the `v0.8.0` tag (`0575e57`) is its descendant,
so the work shipped to consumers in 0.8.0 — with no CHANGELOG entry of any kind.
It is not a small omission: `fetch_account_facts` gained an `account_margin`
key (a public return-shape change), OKX algo order reads changed which orders
they return, Deribit `fetch_option_chain` changed both the request it makes and
what an empty result means, balance timestamps started filling on two venues,
and the bybit balance field map gained payload-shape branching.

Added one `### Added` bullet and eight `### Fixed` bullets under `## [0.8.0]`.
Documenting an omission inside a published section is a correction of the
record, not a rewrite: those changes are what 0.8.0 actually contains.

### 2. `CHANGELOG.md`: `[Unreleased]` empty while task 691 had landed — FIXED

The Coinbase candle pagination fix (`d2befc8`, `68c198d`) landed *after* the
`v0.8.0` tag, so it belongs under `[Unreleased]`, which was empty. Added a
`### Fixed` entry naming the behavior change (aligned-opening tiling, no
trailing page past the requested end, no requests for a window with no eligible
opening) and the live symptom it closes (HTTP 400 `Start cannot be in the
future` on a 1200-hour `ETH/USD` request).

Both gaps are against the project's own `CONTRIBUTING.md` checklist.

### 3. `BUGS.md`: the Coinbase entry still read "implementation pending" — FIXED

The 2026-09-15 entry "Coinbase pagination adds a future page at an unaligned
end" still carried `**Status:** Tracked in task 691 …; implementation pending`
after 691 shipped inside this very range. Updated to the landed wording used by
the file's other resolved entries, naming `d2befc8afe24` and pointing at the
offline test that pins the reported window. It does **not** claim a fresh live
`ETH/USD` call — none was made in this audit.

### 4. `CLAUDE.md`: a fourth eager `@`-import with no rationale bullet — FIXED

`1f6246a` added `@~/.claude/includes/elixir-security-adjudications.md` to the
import block but left the "Active Includes" list at three bullets. That list
exists precisely to justify each eager import against the selective-load
policy, and `mix bourse.agents_md --check` cannot catch prose drift — it only
diffs the render. Added the missing bullet and regenerated `AGENTS.md`
(`--check` and `mix bourse.claude_check` both green afterwards).

### 5. `Bourse.LiveLane.Ledger.format_summary/2` printed ledgered cases under the
"genuine failures" heading — FIXED

`format_summary/2` emitted the per-class counts, then `genuine failures: N`,
then the detail rows — and the detail rows are the **ledgered** hits, indented
one level deeper, directly beneath that heading. In this audit's own run that
rendered as:

```
  ledgered state-dependent: 15
  genuine failures: 15
    binancecoinm:fetchADLRank:0:… [ledgered_state_dependent] …
    … 21 more ledgered rows …
```

Twenty-two ledgered rows printed as if they were the enumeration of fifteen
genuine failures, and not one genuine failure was named. `genuine` is only a
count (`result.failures`) — the function has no identities for them — so the
rows can only be the ledgered ones. This is the exact misreading task 687 ("the
gates report green without running and red without a defect") set out to
remove, sitting in the summary that task produced.

Moved the detail block under its own `ledgered cases (not defects, named
below):` heading, put the genuine count last and labelled it
`genuine failures (named in the run JSON, not here):`. `live_lane_ledger_test.exs`
now pins the ordering, so a future edit cannot silently re-nest the rows.

### 6. `.mcp.json` gained a `chrome-devtools` MCP server — NOT FIXED (noted)

`ec96681` added a `chrome-devtools-mcp@1.7.0` stdio server to the committed
project MCP config. This repo is a headless exchange client with no frontend, so
every agent session here now carries an `npx` browser-automation server it
cannot use. Left alone — the committed MCP set is an operator choice, not an
auditor's to revoke. Flagged for the operator.

### 7. `.sobelow-skips` regenerated (consequence of fix 5)

Adding the explanatory comment in `ledger.ex` shifted the suppressed
`Traversal.FileModule` finding from line 298 to 303, invalidating its
line-keyed hash and re-reddening the pre-commit gate. Per the documented
procedure: confirmed all six outstanding findings are the already-adjudicated
false positives (`hits_path/1` is `System.tmp_dir!()` joined with a SHA-256 of
the checkout root — no user input reaches it), then removed and regenerated the
file. Regenerating wholesale also pruned the stale `:298` entry that
`--mark-skip-all` leaves behind on sobelow 0.15. Six entries, zero outstanding
under `--skip`.

## Filed

- **Task 699** — "Re-prove the public lighter surface: the authored WS channel is
  rejected and the pinned bad-input error no longer occurs" (`codex` /
  `gpt-6-astra`, D3/B6/U6, bundle `live_triage`).

  First filed as the whole lighter failure set; the `rmap` sibling gate caught
  the overlap with tasks 684 and 595 and it was **re-scoped**, which was the
  right call. The private half — every lighter private read answering
  `invalid auth: couldnt find account` (20013/401) — is a recurrence of an
  unprovisioned testnet account, whose remedy is the `mix bourse.provision_lighter`
  task 684 already shipped. That is an operator action with an L1 wallet key held
  outside the credential set, not new roadmap work, and 699 puts it explicitly
  out of scope. What 699 owns is the surface neither 684 nor 595 covers: the
  credential-less **public** lighter claims that have gone stale — the authored
  WS channel grammar (rejected `30005 "Invalid Channel:  (marketId)"`) and the
  bad-input error probe (an unknown market id now answers HTTP 200 with an empty
  book instead of erroring). Scoped as that class rather than as the two rows.

## Recorded in `BUGS.md`, deliberately not filed

- **The lighter testnet drift**, with the full evidence — all three symptoms,
  the exact calls, and the note that the private half's remedy is task 684's
  provisioning tool rather than new work.
- **Two live contract cases red on unpopulated sandbox state with no ledger
  row**: `binance:fetchOrderList:0:privateGetOrderList` ("provider account state
  has no id from fetchOrderLists") and
  `okx:fetchOpenInterestHistory:1:publicGetRubikStatOptionOpenInterestVolume`
  ("state did not exercise the read"). Both helpers fail loudly with actionable
  text, which is the designed behavior; the open question — populate the sandbox
  or fence the case as state-dependent — is a routing decision for the operator,
  and the ledger process already owns that class. Recorded so the next reader
  does not re-derive it.

## Reviewer-rejection feedback

The only rejection in the supplied window is **task 672** (run
`run-1787480486838-53f33055`), the endpoint-major rotation. It is **not** in this
audited range, so this audit has no landed work to grade it against and makes no
false-rejection claim about it. For the record, the quoted report reads as a
fix-and-approve that settled as a rejection — it calls the work "substantially
implemented and salvageable", confirms every stated outcome, and describes a
strictness regression the reviewer *fixed inline*. Worth the orchestrator's
attention when 672 is next touched; outside this audit's evidence.

## Cold check

`mix check.dispatch` in this un-warmed worktree: **red**, 14 confirmed test
failures out of 3112 (1 flaky healed), everything before the suite green
(compile `--warnings-as-errors`, Lighter signer build + Go tests, credo
`--strict` 0 issues over 417 files, doctor 100% moduledoc/spec, sobelow,
authority and error-authority corpora, `agents_md --check`, `claude_check`,
`ex_dna`, `reach.check`).

All 14 are provider-live and none is attributable to the audited range:

- **10 lighter** — 7 contract cases plus both signing-integration tests and the
  promotion test on `invalid auth: couldnt find account`; the public WS canary on
  the `30005` channel rejection; the bad-input probe on the unknown market id now
  returning 200. Filed/recorded as above; nothing in the range touches lighter.
- **2 unpopulated sandbox state** — `binance:fetchOrderList:0` and
  `okx:fetchOpenInterestHistory:1`, recorded in `BUGS.md`.

The remaining 22 red contract cases were correctly matched to
`docs/prod-verification-ledger.md` (6 demo-unavailable, 15 state-dependent, 1
unreachable) and are not defects.

The fixes in this commit were re-verified after the cold run: `mix format
--check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`,
`mix doctor --raise`, `mix bourse.agents_md --check`, `mix bourse.claude_check`
and `mix test.json test/bourse/live_lane_ledger_test.exs` (16 passed) are all
green.

## Note on scope

This commit touches `CHANGELOG.md`, `roadmap/tasks.toml`, `roadmap/data.json`
and `ROADMAP.md` — paths harness excludes from *delivery* commits. The audit
role is explicitly instructed to file discoveries via `rmap new` (which rewrites
all three roadmap files) and to commit its own fixes, so they are included here
deliberately. If the audit commit is subject to the same path reset, the
CHANGELOG corrections and task 699 will be dropped and need re-applying.
