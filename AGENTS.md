<!-- Auto-generated from CLAUDE.md by mix ccxt.agents_md — do not edit manually -->

# CLAUDE.md

Guidance for Claude Code working in this repository.

## Active Includes

Eager-load only the irreducible floor; everything else is skill-on-demand via enabled plugins. **Don't double-load** (an `@`-import plus its sibling skill pays twice for the same tokens).

- **`critical-rules`** — hard guardrails that must stay ambient every session (a guardrail the model invokes "when relevant" fails exactly when it doesn't realize the rule applies).
- **`ex-unit-json`** — `mix test.json` is the test runner every session uses; its flight-recorder semantics and the "JSON-by-design — parse for real failures, never reject the envelope" rule are load-bearing for cross-family reviewers.
- **`harness-workflow`** — this repo IS registered for harness dispatch (see below). Its guardrails fail by non-recognition (`Recover, Don't Redo`; `Settle ≠ landed`; the duplicate-land trap), so a skill-on-demand load is not equivalent.

<!-- @-import: ~/.claude/includes/critical-rules.md -->
## 🚨 ANSWER IN SHORT TEXT — ALWAYS

Short, pointed text — explanation, proposal, pushback, summary alike. Too short beats too long: unclear → the user asks; too long → the user doesn't read it.

## 🚨 BE A REAL PARTNER, NOT A YES-SAYER

- Challenge what seems wrong, risky, or suboptimal. Not every request is a good idea.
- Flawed approach → "I'd push back because…". Better alternative → present it with reasoning.
- Scope too big *or too small* → flag it.
- Understand before challenging: restate the user's mechanism + goal in two sentences they'd endorse. Can't → ask, don't challenge.
- Partial understanding → questions only. "Seems wrong" without naming what you understood is noise.
- "Not how software is normally built" is not an objection.
- ≤3 sentences. Direct, not combative.
- Made your case and the user still wants it → commit fully. Pushback ≠ blocking.

### Think As an AI, Not Only As a Developer

| Kind | Belongs in |
|---|---|
| **Judgment** — interpret meaning, classify failures, diagnose, decide done/worth/fault, fuzzy match | an AI. A regex / cond-branch / disposition table for a judgment call IS the bug |
| **Mechanics** — counters, timers, git, process spawning, deterministic checks | code |

Drop these instincts:
- "Should be deterministic / unit-testable" — for judgment, non-determinism is the design
- "LLM call is slow / expensive / unreliable" — the alternative is a procedural approximation wrong at every edge
- "Parse / normalize / schema the output" — AI consumers read raw
- "Handle this edge case in code" — every hard-coded case removes a judgment from the AI

Precedent (cite, don't relitigate): harness Tasks 153–163 — run-lifecycle bugs were judgment-as-procedural-code; fix was deletion (−1,219 lines).

## 🚨 SURFACE THE OVERRIDE — DON'T DECIDE SILENTLY

Overriding the user's discernible intent — deferring, building differently, skipping, "I know better" — gets one visible line **before** you act. Never act silently and rationalize after.

- Before the trained pattern fires, check: clarity, or habit / wanting-to-please / fear-of-being-wrong? Only clarity earns a silent decision.
- Surface ≠ block: "doing X instead of Y because Z — say if wrong", then proceed. Don't gate on a question.
- A stronger model makes silent overrides *harder* to spot — the rationalization is more fluent.

## 🚨 NEVER START THE PHOENIX SERVER

Always already running. Never `mix phx.server`. Assume localhost:4000. To verify behavior, ask the user to check the browser.

## 🚨 ALWAYS WRITE TESTS

Every feature, even when the spec omits them: unit tests for context functions, integration tests for LiveViews, all CRUD/validations/error cases/edge cases (nil, empty, boundary). No tests → not complete.

## 🚨 AGAINST AN API, THE PROVIDER-OWNED CONTRACT IS THE AUTHORITY

Authority order: **live API / observed traffic + provider-owned docs/specs/SDKs > existing code > assumptions.** Third-party clients, aggregators, wrappers, reference impls (incl. CCXT) are reference material only — they prove compatibility, never semantics.

- Hit the live API FIRST, then mock only what you've already seen. A mock encodes your guess; it passes green while the real call 400s.
- Tidewave `project_eval` to explore → `@moduletag :integration` test to pin. Flunk on missing creds, never skip silently.
- Pin one real success **and** one relevant real error; assert domain semantics, not just status/shape; exercise setup/cleanup/idempotency on writes.
- Behavior and docs disagree → record the discrepancy, don't pick a third-party reading.
- Can't reach the API → say so and `flunk`. Never a mock that ratifies a guess.
- A green claim names the independent evaluator + durable evidence (harness run, CI URL, review artifact). Self-report is not verification.

## 🚨 RAISE COVERAGE BEFORE MUTATING

Before any code-changing task on an existing module, its `mix test.json --cover` must be at tier — **≥80%** standard, **≥95%** critical (money, signing, crypto, low-level encoders, security-sensitive parsers; when in doubt, critical). Below tier → write the missing tests first, in this task.

1. `mix test.json --cover --quiet --output /tmp/cov.json`
2. `jq '.coverage.modules[] | select(.module == "MyApp.Foo")' /tmp/cov.json`
3. Below tier → cover the uncovered lines, even ones you didn't come to change. Then mutate.

Exempt: doc-only edits, formatting/alias reordering, pure renames, typo fixes in strings/messages.

## 🚨 NEVER HIDE TEST FAILURES

A test that passes on every outcome is lying. Never `{:error, _} -> assert true`, never a catch-all `{:error, _} -> :ok`, never `IO.puts` + `assert true`.

```elixir
case result do
  {:ok, data} -> assert is_map(data)
  {:error, :insufficient_balance} -> :ok          # this specific error is expected
  {:error, other} -> flunk("Unexpected error: #{inspect(other)}")
end
```

- Don't know what error to expect → don't write the test yet. Explore via Tidewave, then assert.
- Integration tests: never `:skip` on missing credentials. Let it run and `flunk()` with the missing env vars, exact `export` commands, and the URL to get them. "0 failures" from 0 tests is a lie.

## 🚨 FIX HOOK-FLAGGED ISSUES ON FILES YOU TOUCH

Hook fires → fix → re-run → stage. No planning around it, no asking, no discussing whether to. Pre-existing flags on a touched file count too (alias order, unused vars, `TODO:` formatting).

- Scope is only the files your change touched, not the project.
- Generated files → fix the generator.
- Never move the fix to ROADMAP or a follow-up. This commit.
- Don't re-run a check the hook just ran on the same files. Full-suite re-runs earn their cost only before a PR/merge, after `mix deps.get`, after a branch switch, or on request.

## 🚨 READ TO THE ANSWER — DON'T USE THE RUNNER AS AN ORACLE

Reason to the fix by reading code; run once to CONFIRM, not to DISCOVER.

- Read the code path before the test that exercises it.
- Treat a failure as a SURVEY: enumerate every plausible cause from output + one read, fix in a batch, run once.
- Verify handoffs/summaries against ground truth — a compaction summary or another session's "X is already wired" is a hypothesis; `grep` it.
- Flaky terminal → sequential and simple: one command → file → Read. No parallel batches of dependent calls.

## 🚨 FLAKY TESTS & TEST-RUN TOKEN ECONOMY

- 1–2 failures out of hundreds, in a file your diff didn't touch → flaky **hypothesis**. Re-run that test alone (`mix test.json <file>:<line>` or `--failed`). Passes alone → proceed. One isolated re-run is the whole investigation.
- NEVER `Process.sleep` to fix a flake. Use `assert_receive`/`refute_receive`, `Process.monitor` + `{:DOWN, …}`, `start_supervised!`, or poll-until-condition.
- Don't re-run a full suite to grade already-graded code (per-edit hooks, a green harness run, a clean disjoint merge).
- Bound output: `--cover` dumps hundreds of KB. Always `--output /tmp/cov.json` + `jq`. Triage with `--max-failures 1` / `--failed` / one `file:line`.

## 🚨 NO PSEUDO-RIGOROUS HEDGING

You have no consumer telemetry, no usage counts, no demand signal. Don't gate user-requested work behind evidence you cannot obtain. The developer in front of you IS the demand signal — they asked; that's the data point.

STOP if about to write:
- "Demand for X is unproven"
- "We should wait until…"
- "Is this widely needed?"
- "Only worth doing if a Nth+ case is imminent"
- "Bet on usage data before building"

**A legitimate "wait" names an external blocker with an unblock path** — a missing dep, an unreleased upstream, an unactivated market. **"Nobody has asked yet" is not a trigger.** Neither is "it's additive, cheap to add later."

Instead: name actual technical risks ("the macro grows more knobs than the duplication it removes"), cite concrete precedents, or score the task honestly low. Honest framing: *"I don't know if you'll use this 12 more times — that's your call."*

Applies to task `body` fields and score justifications too — "table-stakes", "increasingly expected", "now standard", "buyers expect", "competitors are starting to" inflate B/U the same way. Required: a concrete named reason, or an honest low score.

## Git Commit / Push / PR-Create — Allowed by Default

Commit, push, open PRs without asking when the task calls for it. Announce in one line, then act.

Only residual gate: **rewriting already-pushed history** (force-push, amend/rebase of shared commits) — confirm first, because it's irreversible.

### 🚨 STAGE PATH-SCOPED — THE WORKING TREE IS SHARED

- NEVER `git add -A` / `git add .` / `git commit -a`. Stage explicitly (`git add <path>`) or commit path-scoped (`git commit <path>`).
- Verify before every commit: `git diff --cached --name-only`. A path you didn't touch is someone else's.
- Pre-commit hook trips on a foreign file → path-scoped-stash only their paths (`git stash push -- <paths>`), commit yours, `git stash pop`, re-stage what was staged before. Never format or fix work that isn't yours to clear a hook.
- Untracked files you didn't create: leave them. No `-u` stash, no `add`.

## 🚨 NEVER BROADCAST AN UNPATCHED VULNERABILITY IN A COMMITTED FILE

A committed file is a public file — and permanent in git history. Exploit-actionable detail (attack mechanism, trigger value, PoC, unpublished GHSA/CVE id) never goes into `roadmap/tasks.toml`, `ROADMAP.md`, `CHANGELOG.md`, code comments, or commit messages.

- **Open + undisclosed → out of git.** Track in a private draft GitHub Security Advisory (`gh api repos/<org>/<repo>/security-advisories -X POST`, draft; `vulnerabilities[]` needs ecosystem + package + `vulnerable_version_range`). One per issue, full detail there and only there.
- **Fixed AND advisory published → fine to reference.** The gate is both, not either.
- **Need to schedule the work?** File the rmap task with a sanitized body: `"harden Tempo fee-payer gas bounds — see private advisory <id>"`. Never the mechanism.
- **Embargo window:** commit messages and CHANGELOG describe the shape of the fix, not the hole.
- **Inbound reports hide in one place:** privately-reported vulns appear ONLY under Security → Advisories (`gh api repos/<org>/<repo>/security-advisories`) — not Dependabot, not code/secret scanning, not the notifications inbox. Always query it; act on `triage` and `draft`.
- **Public ledgers carry only ✓ closed / 📋 tracked rows** plus a generic open-item count. Never an enumerated map of unpatched weaknesses.
- **On fix:** patch → release → publish the advisory naming the patched version, same day.
- Already committed = already leaked. Redact now and treat git history as compromised (rotate/patch), don't just stop going forward.

## Shell Safety

`rm` is permitted. Before an irreversible delete, glance at the target — no unexpanded `$VAR`, no wildcard catching more than you mean, not a path you didn't create. `git rm` for tracked files keeps the removal in the diff.

## 🚨 NEVER RUN DESTRUCTIVE DEPENDENCY COMMANDS

Never without explicit consent: `mix deps.clean` (incl. `--all`), `mix deps.unlock --all`, `rm -rf _build`, `rm -rf deps`, `mix clean`.

Instead: compile error → retry `mix compile` / `mix test`. Specific dep → `mix deps.compile <dep> --force`. Most "corrupt cache" issues are transient.

## 🚨 NO SCOPE-SEQUENCING QUALIFIERS IN DURABLE ARTIFACTS

Never write "X first", "starting with X", "initially", "for now", "MVP: X" into repo descriptions, READMEs, moduledocs, code/config comments, commit messages, or vision one-liners. They metastasize and become unremovable. Sequencing lives in the roadmap only (milestones, task bodies, `out_of_scope`). Elsewhere describe what the system IS: "Coverage: Robinhood Chain tokenized equities", not "starting with Robinhood Chain".

## 🚨 Integrity and Accuracy

- Never fabricate information, experience, metrics, timelines, or stats.
- Distinguish codebase observation / general knowledge / best practice / speculation.
- No false authority: no "we learned" without repo evidence, no "after X years in production".
- Uncertain → say so, give ranges over false precision, suggest a validation path.
- Trace sources: "Based on the code in file.ex…", "According to docs/FILE.md…", "Common practice in Elixir…".

## 🚨 RESEARCH BEFORE ASSERTING ON NICHE TECHNICAL CLAIMS

Outside reliable training coverage, research proactively — unasked. WebFetch when the canonical URL is known, WebSearch to find one. **Cite what you fetched.**

Research:
- **Wire formats / encodings** — RLP, ABI, SSZ, Protobuf, BLS, BIP-32/39/44, EIP-712, CBOR, ASN.1/DER. Never claim byte order, length-prefix, padding, or canonical form from memory.
- **Protocol details** — EIPs, RFCs, JSON-RPC shapes/error codes, opcode gas, exchange API quirks.
- **Niche / recent library APIs** — about to write `# probably something like`? Fetch the docs.
- **Cross-implementation edge cases** — check ≥2 reference impls; one impl's behavior can be a bug, agreement across two is the spec in practice.

Don't research: pure Elixir/OTP, stdlib, mainstream Phoenix/LiveView/Ecto/Ash, generic REST/HTTP/JSON/SQL/shell, anything in the codebase or an imported CLAUDE.md.

Fetch fails or is ambiguous → say so and lower confidence. Never fall back to "well, I think…" silently.

## 🚨 NO EVASION — SIT WITH THE HARD THING

Hitting a wall → silently moving to easier work is the failure. Stay with it; say "this is hard because X".

Don't use without explicit user approval:
- "let's move on to", "we can defer this", "skip this for now", "let's come back to this later", "let's table this"
- "to keep things simple, I'll skip", "for brevity, I won't", "that's out of scope", "not strictly necessary"
- "that should be enough", "the rest is straightforward", "I'll leave the rest as an exercise"
- "you might want to", "you could manually", "you'll need to handle"

- Blocked → name it: "blocked on X because Y. Options: A, B, C."
- Never a silent workaround. Tempted to add a fallback/nil-guard for missing data → should it come from upstream? Then stop and report.
- Must move on → leave a tracked TODO, not a silent gap.

<!-- @-import: ~/.claude/includes/ex-unit-json.md -->
## ExUnitJSON — `mix test.json`

AI-friendly JSON test output. Use instead of `mix test`. Default shows only failures.

### Install

```elixir
defp deps do
  [{:ex_unit_json, "~> 0.6", only: [:dev, :test], runtime: false}]
end
```

Requires Elixir 1.18+ (uses built-in `:json` — no external JSON dependency).

`cli/0` for `preferred_envs` is required — see `elixir-setup.md` (or invoke the `elixir:elixir-setup` skill if the include isn't `@`-imported in your project).

### Quick Reference

```bash
mix test.json --quiet                              # first run — failures only (default)
mix test.json --quiet --failed --first-failure     # iterate on failures (fast)
mix test.json --quiet --failed --summary-only      # verify failures fixed
mix test.json --quiet --all                        # include passing tests
mix test.json --quiet --group-by-error --summary-only  # cluster failures
mix test.json --quiet --filter-out "credentials"   # exclude known-noise patterns (repeatable)
mix test.json --quiet --cover --cover-threshold 80 # coverage gate
```

Auto-reminder: if you forget `--failed` when previous failures exist, output includes a TIP suggesting `--failed`. Skipped when already focused (file/dir target or tag filter).

**When NOT to use `--failed`:** after editing fixtures/shared setup, after adding new test files (not in `.mix_test_failures`), or when verifying a full green suite.

### Key Flags

| Flag | Purpose |
|------|---------|
| `--quiet` | **Default.** Suppresses Logger/warnings for clean JSON. Omit when debugging to see runtime output. |
| `--failed` | Re-run only previously failed tests |
| `--summary-only` | Counts only, no test details |
| `--all` | Include passing tests (default shows failures only) |
| `--failures-only` | Failed tests only (default behavior) |
| `--first-failure` | Stop at first failure |
| `--group-by-error` | Cluster failures by error message |
| `--filter-out "X"` | Exclude failures matching pattern (repeatable) |
| `--output FILE` | Write to file instead of stdout |
| `--compact` | JSONL output, one line per test |
| `--cover` / `--cover-threshold N` | Coverage collection / fail under N% |
| `--no-retry` | Disable auto-retry of failed tests (on by default) |
| `--no-warn` | Suppress "use --failed" tip when prior failures exist |

ExUnit flags compose: `mix test.json --only integration --quiet`, `mix test.json test/foo_test.exs --quiet`, `--seed 12345`.

### Automatic Retry — Flaky Healing (default on)

When a bare run has failures, `mix test.json` re-runs **only** the previously-failed tests once (ExUnit-native `--failed --all`, in a subprocess) and merges by `{module, name}`:

- **confirmed** — failed both runs → stays in `tests`, exit 2.
- **flaky** — failed then passed → moved to a top-level `flaky[]` array (named, never hidden) and no longer blocks.

If **every** first-run failure heals, `summary.result` becomes `"passed"` and the **exit code is 0** — so an agent running the default command isn't blocked by an intermittent async/GenServer/Port/LiveView red. A `retry` object (`retried`/`confirmed`/`flaky`) is added whenever a retry runs. This is the in-task version of the "small red count is a flaky-test hypothesis" discipline — no `--failed` flag needed.

**Auto-skipped** (no second run) for: `--no-retry`, `config :ex_unit_json, retry: false`, an already-green suite, and modes the naive merge can't preserve — `--failed`, `--summary-only`, `--first-failure`, `--compact`, `--group-by-error`, `--filter-out`, a `file:line` target, and umbrella projects.

```elixir
# config/test.exs — disable globally
config :ex_unit_json, retry: false
```

### Message Tracing — Flight Recorder (opt-in, v0.6+)

Capture the inter-process `send`/`receive` flow that led to a failure. Wire the setup callback once into a shared `ExUnit.CaseTemplate`:

```elixir
defmodule MyApp.Case do
  use ExUnit.CaseTemplate
  using do
    quote do
      setup {ExUnitJSON.Trace, :setup}
    end
  end
end
```

Then opt a test or module in with a tag:

```elixir
@moduletag trace_messages: true   # whole module
@tag trace_messages: true         # one test
@tag trace_messages: 200          # one test, ring buffer of 200 events
```

**Only failing tests** emit a `"trace"` block (passing tests discard it); untagged tests are a zero-cost no-op. The `messages` flow is the reliable signal; `mailboxes` is a best-effort, `approx`-labeled snapshot of processes still alive near the failure (a dead process's mailbox can't be recovered on the BEAM). `overflow: true` means a per-test event budget was hit and tracing stopped early; `dropped` counts events lost. Requires OTP 27+ (already implied by `:json`).

### Output Schema (v1)

```json
{
  "version": 1,
  "seed": 12345,
  "hint": "3 test(s) failed previously. Use --failed to re-run only those.",
  "summary": {"total": 100, "passed": 80, "failed": 20, "skipped": 0, "excluded": 0, "invalid": 0, "filtered": 15, "flaky": 2, "duration_us": 123456, "result": "failed"},
  "coverage": {"total_percentage": 92.5, "threshold": 80, "threshold_met": true, "modules": [{"module": "MyApp.Users", "percentage": 95.0, "uncovered_lines": [45, 67]}]},
  "error_groups": [{"pattern": "Connection refused", "count": 10, "example": {"file": "...", "line": 42}}],
  "retry": {"ran": true, "passes": 1, "retried": 4, "confirmed": 2, "flaky": 2},
  "flaky": [{"module": "...", "name": "...", "state": "failed"}],
  "module_failures": [{"name": "MyApp.SomeTest", "file": "test/some_test.exs", "state": "failed", "failures": [...]}],
  "tests": [{"file": "...", "name": "...", "state": "failed", "trace": {
    "messages": [
      {"t_us": 12, "dir": "send", "from": "#PID<0.310.0>", "to": "#PID<0.311.0>", "msg": "{:place_order, %{...}}"},
      {"t_us": 45, "dir": "recv", "pid": "#PID<0.311.0>", "msg": "{:ok, %Order{...}}"}
    ],
    "mailboxes": [{"pid": "#PID<0.311.0>", "registered": "MyServer", "messages": ["..."], "approx": true}],
    "overflow": false, "dropped": 0
  }}]
}
```

Conditional fields: `hint` only when prior failures exist and retry is disabled/not applicable (suppressed when auto-retry is ON — its default — because the retry supersedes the manual tip; suppressed by `--no-warn`); `coverage` only with `--cover`; `coverage.threshold_met` only with `--cover-threshold`; `summary.filtered` only with `--filter-out`; `summary.flaky` and top-level `flaky`/`retry` only when a retry actually ran; `error_groups` only with `--group-by-error`; `module_failures` only on `setup_all` failure; `tests` omitted with `--summary-only`; a test's `trace` only on a **failing** test tagged `trace_messages`. `summary.excluded` and `summary.invalid` are always present (zero when none). Test `state` is one of `"passed"`, `"failed"`, `"skipped"`, `"excluded"`, or `"invalid"` (`invalid` occurs when `setup_all` fails; it also drives `summary.result: "failed"`). A flake that healed appears in `flaky[]`, **not** `tests[]`. Trace `messages` entries differ by direction: `send` has `from`/`to`; `recv` has `pid` instead.

### Using jq

**One run captures everything — never summarize-then-detail.** `mix test.json --quiet --output /tmp/r.json` writes the full schema in one payload: `summary`, failing `tests`, `error_groups`, `coverage`, `module_failures`. Slice it after: `jq '.summary' /tmp/r.json` for the summary view, `jq '.tests[] | select(.state == "failed")'` for detail, `jq '.error_groups'` for clusters. The default output is already compacted (only failed tests in `.tests[]`), so a "summary-only first, full run for details next" pass doubles compile-cache rehydration + suite-execution cost for zero informational gain. **Do not** start with `--summary-only` to "scope the failure space" — the captured full JSON contains the summary AND the detail AND the error-groups already.

**Default to `--output FILE`. Always.** Pick a path (e.g. `/tmp/r.json`) before running. A re-run is seconds-to-minutes; a `jq` against the captured file is microseconds. Even a "one-shot" pipe is wrong-by-default: the moment you want to slice a second facet you've paid for the suite twice. Piping is the exception, not the rule — reserve it for genuinely throwaway shell composition.

Piping (when you actually need it) requires `MIX_QUIET=1` to suppress compilation output that would corrupt the JSON stream.

```bash
MIX_QUIET=1 mix test.json --quiet --summary-only | jq '.summary'
MIX_QUIET=1 mix test.json --quiet --group-by-error --summary-only | jq '.error_groups | map({pattern, count})'

mix test.json --quiet --output /tmp/results.json
jq '.tests[] | select(.state == "failed")' /tmp/results.json
jq '.tests | group_by(.file) | map({file: .[0].file, count: length})' /tmp/results.json
```

For large suites that exceed context: `--summary-only`, or `--output FILE` + selective jq.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed (and coverage threshold met if set) |
| 2 | Failures OR coverage below threshold — JSON still valid, check `summary.result` / `coverage.threshold_met` |

Exit 2 may trigger shell error display; use `2>&1` to capture both streams.

### Strict Enforcement (optional)

```elixir
# config/test.exs
config :ex_unit_json, enforce_failed: true
```

Blocks full test runs when failures exist unless `--failed` or a focused filter is used.

<!-- @-import: ~/.claude/includes/harness-workflow.md -->
## Harness Workflow

OTP-native **implement → review → land** loop for roadmap-driven development. An AI orchestrator drives harness; harness dispatches headless implementer agents into isolated git worktrees, then a **cross-family reviewer AI** gates every deliverable (runs the project's checks itself, fixes inline, writes `.harness/review.json`). Optional auto-landing ff-merges approved work; a post-merge audit agent sweeps hygiene.

**Promoted from** `docs/dogfooding-workflow.md` in the harness repo — that file remains the **incubator runbook** for harness-specific history, driver-script templates, and per-batch run logs. This include is the **portfolio-wide contract**. Version-controlled source: `priv/includes/harness-workflow.md` in the harness repo; install to `~/.claude/includes/harness-workflow.md` via `mix harness.install_includes`.

### Relationship to Other Includes (Layered — No Supersession)

| Include | Role relative to harness-workflow |
|---|---|
| `workflow-philosophy.md` | **Foundation.** Evaluator separation, session-per-phase, verification-before-completion. Harness automates the loop while preserving these principles — the **reviewer AI** is the grader, never the implementer's self-report. |
| `task-prioritization.md` | **Task selection.** D/B/U scoring, `rmap next`, parallel markers, refine-don't-duplicate. Harness executes whatever rmap returns; it does not replace prioritization. |
| `worktree-workflow.md` | **Manual parallel sessions.** For hand-build work outside harness dispatch — operator-created worktrees, PR flow, post-merge audit. Harness manages its own per-run worktrees (`harness/<run-id>`); manual worktree rules still apply for hand-build sessions. |
| `dev-lifecycle.md` | **Manual five-phase chain** (`task-driver → worktree → bots → merge → audit-review`). Use when *not* driving through harness. Harness is the automated alternative for dispatchable roadmap tasks; dev-lifecycle still governs plan-and-file, pre-commit review, and post-merge audit. |
| `agent-dispatch.md` / cloud-delegation stack | **Linear/Codex/Cursor PR delegation** without a running harness BEAM. Orthogonal path — projects can use cloud delegation *or* harness; harness subsumes the dispatch+review loop when the OTP node is running. |
| `skills/harness-driver/SKILL.md` (harness repo) | **API surface contract** — MCP tools, `project_eval` patterns, `%LogRecord{}` fields, sharp edges. Load on demand when driving harness; this include covers *workflow*, the skill covers *surfaces*. |

**Adopt per repo:** `@~/.claude/includes/harness-workflow.md` in the project's `CLAUDE.md` (load-on-demand row — not eager; same pattern as `workflow-philosophy.md`).

### The Loop

```
rmap task → implementer AI (worktree) → commit harness/<run-id> → reviewer AI (THE GATE) → done | failed
                                                                              ↓ (done + auto policy)
                                                              MERGE (lander: rebase + ff-push, no re-verify)
                                                                              ↓
                                                              AUDIT (post-merge audit agent, best-effort)
```

One run = one supervised `Harness.Run` gen_statem: fork worktree off target `HEAD`, dispatch implementer, commit diff to `harness/<run-id>`, dispatch cross-family reviewer into the same worktree. The reviewer runs the project's `check_command` hint, fixes what it can, writes `.harness/review.json`. **Success = reviewer `approve`** — never implementer exit code or self-report. There is **no mechanical verification gate** in harness; judgment lives in agents.

Rejections put the task back in the queue for re-dispatch. Fix-and-approve is the near-absolute default for the reviewer.

### When to Dispatch vs Hand-Build

**An rmap task is not automatically a harness run.** Dispatch only when the full
implement→review→land cycle buys meaningful safety, independent verification, or
parallel throughput. Historical run cost stays material even for D≤2 work, so the
old D≤2 / 30-LOC conjunctive exception was too narrow.

**Work inline by default when it is bounded and local:** one coherent surface,
typically D≤4, roughly ≤100 LOC across ≤5 files, focused-testable, and no positive
dispatch trigger below. These are routing hints, not an ALL-of gate — a risky D2
task can earn dispatch, while a routine D4 task can stay inline.

Positive dispatch triggers:

- Signing, money handling, cryptography, security, or authorization
- A public API/schema/contract change or a migration
- Harness runtime, CI/check infrastructure, or a repo-wide invariant
- Live/external-system semantics that need independent evidence
- Multiple subsystems, or genuinely useful parallel execution

Hand-build when harness cannot perform or judge the work:

- Scaffolding that reshapes harness runtime (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**
- Work requiring live human/browser judgment, such as exploratory visual identity; routine spec-anchored UI remains dispatchable
- A harness gap — file via `rmap new`, fix harness, re-dispatch; do not work around the gap inside the target task

**🚨 The routing gate fires at `assignee =`, not at dispatch time.** rmap requires `assignee` + `model` at task creation, so the inline-vs-dispatch decision is made — and frozen — the moment the task is filed: a task carrying an agent assignee reads as "routing already decided" to every later session, and this section never gets consulted again. Two rules close that hole:

- **Filing a task: run this section BEFORE typing `assignee`.** Default is `assignee = "human"` (inline); an agent assignee must be earned by a positive trigger named in the task body. A D≤2 single-file task with an agent assignee and no named trigger is a filing defect (observed: ccxt_client task 470, a one-file test-helper fix dispatched to codex because the reviewer proposal arrived dispatch-shaped). Mirrored as question 6 of `task-writing.md`'s Pre-Creation Gate.
- **Reviewer `proposed_tasks` carry no routing authority.** Proposals arrive dispatch-shaped (suggested scores/markers), but the orchestrator owns routing the same way it owns filing — re-route each proposal through this gate instead of inheriting dispatchability from its shape. Sibling of task-writing's "Re-Generalize an Agent's Decomposition": that filters whose *architecture* a task encodes; this filters whose *routing* it encodes.

### Running a Task

**Prerequisites:** long-lived harness BEAM (`iex -S mix` in the harness checkout), target project registered in `Harness.ProjectRegistry`, clean `git status` on the target's dispatch branch (runs fork worktrees off `HEAD`).

**Three dispatch paths** (prefer top to bottom):

1. **Native MCP — default.** `dispatch-task` (fire-and-forget) or `dispatch-await` (blocks until settle) against `http://localhost:4018/harness/mcp`. Observe via `dispatch-status`, `dispatch-transcript`, `dispatch-verdict_detail`. `scrub_anthropic_key: true` (default) forces subscription OAuth over inherited `ANTHROPIC_API_KEY`.
2. **Tidewave `project_eval` — escape hatch.** Struct-level control the flat tools don't expose (`retry_policy`, fail-over adapter lists, `subscriber: self()`). Run persists to `Harness.ResultStore` even when the eval process exits.
3. **`mix run` driver script — fallback.** Full transcript + reviewer report to terminal. See harness repo `docs/dogfooding-workflow.md` for the canonical template.

> **Never start a second driver BEAM while runs are in flight.** Boot-time worktree sweeps can prune live sibling worktrees. Drive all parallel batches from one long-lived node.

**In-flight idempotency (Task 286):** a second `dispatch-task` / `dispatch-bundle` of the same `{project, task_id}` while a non-terminal run exists returns the **existing** `run_id` (Oban `conflict?: true`), not a duplicate — a retried dispatch is safe and free.

**Coalesce small related tasks:** `dispatch-coalesce` accepts an explicit task-id list and runs it as one worktree, implementer invocation, reviewer gate, and landing unit. Use it when small tasks share a bundle/surface and separating them would only repeat fixed run costs; keep independent tasks in `dispatch-bundle` so write-disjoint work still parallelizes. Coalesced members share the same landing SHA and never partially land — the reviewer must mark every member `approved` in the verdict's `task_outcomes` or the run fails as a unit. The call returns the coalesced `write_set` (the union of every member's `touches`/`files_to_modify`); serialize the next wave against that union, since harness executes the coalesce but never picks what to coalesce.

**Write-set serialization (Task 292):** `dispatch-bundle` and cron ready-set dispatch compute each task's `touches ∪ files_to_modify` before enqueue. Tasks with overlapping write-sets are logged and serialized into later waves instead of fanned out together. Callers no longer hand-dedupe ready sets; they must keep `touches` / `files_to_modify` accurate because harness does not infer paths from task prose.

**Renderable vs executable:** `rmap delegate --to` renders native prompts for all six harness adapters (`claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi`). `droid` renders but has no harness adapter — rejected at ingest. All six shipped adapters declare `worktree_isolation: true`.

### Routing & Model Management

- **Resolve `assignee` + `model` from facts, not by reading code.** `routing-brief` is the thin task-writer index: dispatchable agent roster, each agent's standing model (`Config.agent_model/1`), model availability/blocks, and per-agent KPI rollups — every metric carries `n`, no ranking. A model-capable agent with no configured model shows `model: nil, model_required: true`.
- **Scout routing (advisory).** `dispatch-recommend` returns the cross-family scout AI's per-facet `:exploit` pick (with rationale) or a safe `:explore` / `:fallback_no_data` when a facet is unmeasured; `dispatch-assess_facets` forces a fresh scout assessment. The caller decides whether to dispatch the pick — legacy composite scores are not used for routing.
- **Model is required, never defaulted.** Implementer precedence: **task `model` → `{:agent_model, agent}` → REJECT** (`{:model_required, agent}`) — harness never falls through to the CLI's ambient default. The **reviewer has no task-pin axis**: its model comes solely from `{:agent_model, agent}` for the reviewer adapter's agent (`Run.reviewer_model/1`), and a model-capable reviewer with no configured model is rejected *before* the reviewer spawns. Antigravity is model-capable as of `agy` 1.0.10 (`--model` + `agy models`); harness validates pins against its catalog because the CLI silently falls back on unknown ids.
- **Block exhausted premium models.** A monthly budget can exhaust (e.g. cursor-Opus) while harness still lists the pair as available and routes to it. `model_availability-block_model` (with a `blocked_until` window) removes the pair from routing/cron; `model_availability-unblock_model` clears it.
- **Cost-aware A/B.** `dispatch-compare` runs one task across N adapters (optional per-adapter model overrides) and returns per-adapter `verdict` / `reviewer_diff_size` / `duration_ms` / `token_usage` for selection.

### Reading the Verdict

| `state` / `reason` | Meaning | Action |
|---|---|---|
| `:done` / `:approved` | Reviewer AI approved (possibly after inline fixes — check `reviewer_diff_size`). | Deliverable on `harness/<run-id>`. Review diff, integrate (or let auto-lander handle it), `rmap status <id> done`. |
| `:failed` / `{:review_rejected, report}` | Reviewer rejected (degenerate — near-never by design). | Read `report`. Task back in queue; re-dispatch. |
| `:failed` / `{:review_stuck, report}` | No verdict: reviewer unavailable, crashed, or missing/malformed `.harness/review.json`. | Read `report`. Fix environment or re-dispatch. |
| `:failed` / `{:worktree_failed,_}` `{:agent_spawn_failed,_}` `{:driver_crashed,_}` `{:commit_failed,_}` | Harness-side mechanical failure. | **Harness bug.** File via `rmap new`. |
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside the run worktree into the main checkout — surfaces as `:failed` **only after bounded AI recovery was exhausted** (see "Self-healing recovery" below). | Recovery declared the run dead. Likely an agent/adapter isolation issue; re-dispatch with a worktree-honoring adapter. |
| `:failed` / `{:checkout_pollution_check_failed, _}` | Post-run pollution `git status` errored. | Rare; transient git/IO. Re-run; inspect checkout if persistent. |
| `:failed` / `:timed_out` | Lifetime budget elapsed. | Raise `:lifetime_timeout` or investigate hang. |
| run process **crashed** (no settle) | gen_statem died. | **Harness bug.** File via `rmap new`. |

Failed runs retain the worktree at `result.worktree_path` for inspection. Approved runs keep branch `harness/<run-id>` after worktree teardown. Use `dispatch-verdict_detail` for the reviewer report, ratings, checks, concerns, proposed tasks, warning flag, and `reviewer_diff_size` — no harness-run mechanical per-check stdout.

**The verdict artifact** `.harness/review.json` is `{verdict, report, checks, concerns, proposed_tasks, facets, skills, ratings}`: `verdict` (`approve`/`reject`) is the gate; `report` is the reviewer's prose; `checks` is the reviewer-written record of commands run and their pass/fail claim; `concerns` is the reviewer's self-flagged caveat list; `proposed_tasks` is an optional list of structured discovery proposals (`title`, `body`, suggested scores/markers, and evidence); **`facets`** (open-vocabulary routing KEY — the kind of task) and **`skills`** (v0_13 two-axis rubric, routing VALUE) feed per-facet capability routing; `ratings` is the legacy flat-score fallback. Harness persists proposals verbatim but never files them. After a run lands, the orchestrator reads them from `dispatch-verdict_detail`, dedupes/merges them against the live pending set, and files only warranted tasks through its own task-writing gate. Reviewers never edit `roadmap/tasks.toml`, `roadmap/data.json`, `ROADMAP.md`, or `CHANGELOG.md`; those files are excluded from delivery commits alongside `.harness/`. Approved runs with non-empty concerns or a reviewer-authored failed check surface a warning fact; harness never auto-blocks or classifies prose. The artifact lives under `.harness/` (excluded from staging) so it never rides in the deliverable commit.

**External-system evidence is reviewer-owned judgment.** When acceptance criteria touch an API or external service, the reviewer must look for reality rather than plausibility: a live success call, a relevant live error, the provider's official docs/spec/SDK for semantic meaning, and an integration test pinning the observed domain semantics. Third-party clients, aggregators, wrappers, and reference implementations (including CCXT) are compatibility/reference evidence only; they never establish correctness or override the provider-owned contract. Mocks, fixtures, and the implementer's self-report are not independent evidence. Missing credentials or an unreachable sandbox are surfaced as a failed check/concern (or rejection when the criterion cannot be verified), never silently treated as green. The lander records the reviewer identity plus `harness-run:<run-id>` as rmap verification provenance.

**Self-healing recovery (the `:recovering` state).** Before settling `:failed` for an *interpretive* non-rejection failure — checkout pollution is currently the one wired call-site — the run spawns a **bounded cross-family recovery AI** (`:recovering` state, budget 1/run) with minimal context (the error term + the main checkout's `git status` + the implementer transcript tail + the failing-check output, never the full transcript). It writes `.harness/recovery.json` `{outcome: "repaired"|"dead", report, repaired}`; harness reads it mechanically and **decides nothing itself**: `repaired` resumes at `:committing` and **re-runs the reviewer gate** (never skips to `:done`); `dead` / missing / malformed settles `:failed` with the original reason. A genuine `verdict: reject` is never routed through recovery. The `Result` carries `recovery_attempts` / `recovery_outcome` / `recovery_repaired` / `recovery_token_usage`. (Tier-1 mechanical self-heal precedes it: the reviewer is re-prompted once on a missing/malformed `review.json` — `reviewer_reprompt_count`, capped at 1 — and rotates to the next cross-family candidate on a reviewer timeout — `reviewer_rotation_count`.)

### 🚨 Recover, Don't Redo — Never Burn Tokens Re-Implementing Committed Work

**A run that committed to `harness/<run-id>` already paid for the implementer. Recovering that branch costs a fraction of a fresh dispatch — re-dispatching from `pending` throws the work away and makes the agent redo all of it.** The reflex to "reset → pending → dispatch again" is a token bonfire whenever a retained branch with commits exists. Check for the branch *first*; pick the cheapest primitive that fits:

| Run state — committed `harness/<run-id>` branch exists | Recover with | Agent tokens |
|---|---|---|
| Approved but unlanded (land-cap, lander crash) | `dispatch-reland` | **zero** — pure git rebase + push |
| Committed, review-stage failure (work is good) | `dispatch-rereview` | zero implementer — re-enters at the reviewer gate |
| Committed, implement-stage incomplete/`:failed` | `dispatch-resume_failed` (`escalate: true` to re-route agent) | **re-spends implementer tokens** — a fresh implementer invocation branched off the retained commits with the failure report injected (contrast `rereview`, which re-runs only the reviewer) |
| Live `:held` run (paused, not dead) | `dispatch-resume` | none — un-pauses in place |
| **No commits / no retained branch** | reset → `pending` + fresh `dispatch-task` | full redo — **the only case where this is correct** |

**Live-run intervention (not recovery of a dead run):** `dispatch-hold` (optionally `interrupt: true`) parks a live run mid-turn, `dispatch-steer` stashes guidance applied on resume, `dispatch-resume` un-pauses in place, `dispatch-cancel` kills it (idempotent). Use hold → steer → resume to force-hand a grinding implementer to the reviewer gate instead of burning the lifetime budget.

**The gate before any reset-to-pending + re-dispatch:** `git branch -a | grep harness/<run-id>` and `git log --oneline origin/<target>..harness/<run-id>`. Commits present ⇒ recover, never redo.

**🚨 First, confirm the run actually *didn't* land — check `origin`, not your local checkout.** Under `landing_policy: :auto` the lander pushes to `origin/<target>` and **deliberately never touches your local checkout** (it ff-pushes from a detached worktree). So after an autonomous land your local `tasks.toml` is **stale**: it still reads `in_progress` for a task the lander already marked `done --shipped-in` on origin. **Reading that stale local status as "the run didn't land" is the trap** — it triggers a wasteful reset-to-`pending` + re-dispatch that *duplicate-lands already-shipped work*. Before concluding anything from task status, `git fetch origin <target> && git rebase origin/<target>` (the existing "Sync main before committing" rule) or read ground truth directly:
- `git log --oneline origin/<target>` — does it already show `task <id> -> done (shipped …)` and the agent-delivery commit? Then it **landed**; your local view was just behind. Do nothing but rebase.
- `dispatch-status <run-id>` / `result_store-list_run_records run_id:<id>` — a record with `state: done, verdict: approve` means the run succeeded; cross-check landing against origin before touching the roadmap.

> **Observed 2026-06-12 (the cautionary tale this section exists for):** three approved runs (246/249/251) landed cleanly to `origin/development` — `done --shipped-in`, audited. But the operator's local checkout hadn't rebased, so `rmap show` read stale `in_progress`. That was misread as "approved but didn't land," the tasks were reset to `pending` and re-dispatched, and task 246 **landed a second time** (duplicate delivery) before the mistake surfaced. Root cause: reading stale local state instead of rebasing on `origin` first. The lander was working perfectly the whole time.

The recovery primitives (`reland`/`rereview`/`resume_failed`) read the persisted `ResultStore` record, which **survives** worktree teardown and node restarts — so a genuinely approved-but-unlanded run (lander hit its land-cap, or a real rebase conflict retained the branch) is recoverable token-free via `dispatch-reland`. Reserve reset-to-`pending` for runs with **no committed branch and no settled record** — and only after confirming against `origin` that the work isn't already shipped.

### Parallel Dispatch

`Harness.Run.Supervisor` is a `DynamicSupervisor` — N crash-isolated runs, each with its own worktree.

- **Batch by dependency graph, then write-set.** Every pending task whose `depends_on` is satisfied can enter the ready set, but harness dispatches only the first wave whose `touches ∪ files_to_modify` are disjoint. Overlapping tasks wait for a later wave after the landed base moves forward.
- **Keep write-set fields accurate.** The dispatcher counts declared path intersections; it does not infer paths from the task body. If two tasks really edit the same function, either let write-set serialization sequence them or fold the coupled work into one rmap task (`task-prioritization.md` § "Refine, Don't Duplicate").
- **One driver BEAM** for all concurrent runs in a wave.
- **Integration order (manual landing):** smallest/isolated diffs onto target first; rebase siblings; run the project's check command on target after last merge.
- **While a wave is in flight:** do not run `rmap status` / `rmap mark` / `rmap new` in parallel sessions against the same checkout — triggers `:checkout_polluted` false-positive.
- **Repo-wide invariant tasks run EXCLUSIVE.** A task whose real write-set is "the whole surface" — introduce a repo-wide guard/invariant and convert every violating site (e.g. an AST-scan test over all of `test/`) — cannot be write-set-serialized by declared `touches`: any sibling land that adds a new violating site after the fork reddens the guard at landing time (observed ccxt_client task 433 × 435, 2026-07-19). Dispatch such tasks as a solo wave — nothing lands in parallel — or accept that the orchestrator repairs at landing.
- **Land-conflict repair is a standard orchestrator move, not an incident.** When the lander blocks on a rebase conflict (reason retains the branch): fork a repair worktree off `origin/<target>`, cherry-pick the run commits, resolve (for additive `tasks.toml` collisions: renumber the branch-side new task to the next free id on origin **and rewrite in-diff string references to it** — CHANGELOG lines, code comments; then `rmap validate && rmap render`), point the retained `harness/<run-id>` branch at the repaired tip, and `dispatch-reland` — the lander keeps push authority and advances rmap itself. **Do not re-run gates on a roadmap/doc-only repair:** the reviewer already graded the code; renumbering tasks, merging doc entries, and re-rendering the roadmap change nothing the gates measure, and a clean disjoint auto-merge of verified code needs no re-grade (same token-economy rule as everywhere else). Re-run a check ONLY when the repair touched code, or when the conflict overlapped a repo-wide invariant the sibling lands could have violated (e.g. a new suite-wide guard vs tests added after the fork — run just that guard, not the stack). Never reset-to-pending (that redoes paid work), never hand-push to the target when a reland can land it.

### Autonomous Landing

Projects with `landing_policy: :auto` and `target_branch`:

1. Approved run enqueues one job on serialized `landing_<name>` Oban queue (limit 1)
2. `Harness.Lander.land/1` rebases `harness/<run-id>` onto `origin/<target>` in a detached worktree
3. **ff-pushes without re-verification** — the reviewer already gated the work
4. Successful push enqueues post-merge audit; advances rmap (`done --verified --verified-by <reviewer> --verification-ref harness-run:<run-id> --shipped-in <sha>`)

Conflict / push-rejected retains the branch for repair — never lands red. Witness notification (read-only sink) alerts the operator; it is **not** a merge gate.

**🚨 Settle ≠ landed — don't conflate the two signals.** `dispatch-await` / `dispatch-await_runs` block until **reviewer settle** (`state: :done, verdict: approve`, or `:failed`), which fires the *moment the reviewer approves* — **before** the serialized `landing_<name>` job rebases and ff-pushes. So an `approve` from `await_runs` means "approved and *queued* to land," **not** "on `origin/<target>`." There is **no blocking await-landed tool**; landing is async and surfaces via the witness sink (`Harness.Notification.FileSink` tailing `~/.harness/settled.jsonl`, or `CommandSink`). To gate a next wave on the base actually moving forward, await settle **then** confirm the land against origin once (`git fetch origin <target> && git log --oneline origin/<target>` for the `task <id> -> done (shipped …)` commit) or consume the witness event — never treat approval as landed. This is the same root cause as the duplicate-land trap above, seen from the dispatch side: a poll loop watching `origin` for the landing commit is a workaround for a *fixed* `await_runs`, not a substitute for it — await settles, origin confirms the land.

**Cron manual-approval mode.** A per-project cron poller in `:auto` mode dispatches unattended; in `:manual` mode it **parks** each dispatch decision instead of enqueuing — drain the parked decisions with `dispatch-pending` and approve them with `dispatch-approve`, keeping the orchestrator in the loop for autonomous polling.

### Orchestrator Loop — the Architect Seat the Per-Task Reviewer Can't Fill

The sections above document the *mechanisms*; this is the **continuous loop** the driving AI runs across waves:

```
plan wave → dispatch → await settle → confirm land on origin → run integration suite on the landed base
          ↑                                                     + review whole surface vs roadmap intent & domain invariants
          └── reconcile rmap ← encode any whole-surface finding as a criterion/test ←┘
```

Each arrow reuses an existing mechanism — don't restate them here: *await settle* (§ "Settle ≠ landed"), *confirm land on origin* (§ "Recover, Don't Redo" → the duplicate-land trap), *reconcile rmap* (the lander already advanced `done --shipped-in` under auto-land — verify, don't double-write), *next wave* (§ "Parallel Dispatch" + write-set serialization).

**🚨 Three review seats, each blind where the next sees — the orchestrator seat is mandatory, not optional.** The per-task reviewer gates *one diff against one task* and is **structurally blind** to two defect classes that land clean through it (worked evidence: delta_calc tasks 24/25/26, see its `## Review Blind Spots` / `## Domain Invariants`):

| Seat | What it sees | What it CANNOT see |
|---|---|---|
| **Per-task reviewer** (cross-family, the gate) | one diff vs one task's acceptance criteria + mechanical checks, in an isolated worktree off a base | the whole surface; domain ground truth |
| **Post-merge audit AI** (best-effort) | cold build of the merged commit range; hygiene | whether a domain constant is *wrong*; roadmap-intent fit |
| **Orchestrator** (the architect seat — you) | whole integrated surface vs roadmap intent + domain invariants across all landed waves | — (this is the seat of last resort) |

The two blind classes, both real-correctness, both passing every per-task check:

- **Domain ground truth** — a wrong venue constant (`@funding_periods_per_day 3`, overstating Deribit's hourly funding ~8×) is internally consistent and fully tested *because the golden was computed with the same wrong constant* — coverage ratifies the bug. The reviewer has no signal; that knowledge lives in the architect's head.
- **Cross-module global invariants** — write-set-disjoint parallel dispatch means two worktrees can each define `project_payback_timeline` and neither review sees the other; the collision only exists once both have landed on the integrated base. Only a whole-surface seat catches it.

**🚨 Run the integration suite on the landed base — this is NOT redundant with per-task review.** After each wave lands, run the project's full check (`mix ci` / `mix precommit.full`) on the freshly-landed `origin/<target>`. The per-task reviewer ran the dispatch-scale check hint (for Elixir, `mix check.dispatch` plus focused `mix test.json ...` for touched behavior) in an *isolated worktree off an earlier base, before sibling waves landed* — cross-module breakage doesn't exist until multiple landed diffs coexist. This generalizes the manual-landing-only "run the project's check command on target after last merge" (§ "Parallel Dispatch") into a standing per-wave step.

**Capture dispatch-check output once, to a unique tmp log.** Dispatch checks are normally verbose. The reviewer should capture the first run instead of re-running for readability: `LOG=$(mktemp -t harness-check-dispatch.XXXXXX.log)` then `mix check.dispatch > "$LOG" 2>&1`; inspect with `tail -200 "$LOG"` / `rg "error|failed|warning" "$LOG"` and record the log path in `.harness/review.json`. The random `mktemp` path prevents parallel agents from clobbering each other's logs.

**🚨 Architect/QA is a workflow responsibility, not a harness runtime gate.** After a wave lands, the orchestrator must run the full landed-base gate, review the integrated surface against roadmap intent/domain invariants, fix findings, and only then dispatch the next wave. Harness does not pause dispatches or store a completion marker for this step; this is the driving AI's seat.

**Two framing guards — keep this consistent with the harness mantra:**

- **It's an agent seat, not harness code.** The mantra ("count facts in code; judge with an AI") forbids *harness* computing meaning — it does **not** forbid the orchestrator AI from reviewing the whole surface or running the suite. This adds no mechanical gate to harness; it's judgment in an agent, which is exactly where judgment belongs.
- **The output crystallizes into encoded invariants — don't leave it a manual sweep.** When the architect seat catches a whole-surface or domain defect, the highest-value move is not the manual catch — it's pushing the rule into an **acceptance criterion or a manifest-wide CI test** (the delta_calc rule) so the per-task gate absorbs that class going forward. Orchestrator review *feeds* the criteria/CI; it must not become a permanent re-review of every diff. A finding caught twice by hand is a missing test.

**Convergence sweep (append-only).** The architect seat's whole-surface pass has a disciplined output shape (inspired by spec-kit's `/speckit.converge`, github/spec-kit): assess the landed code against the **roadmap + acceptance criteria as the sole source of intent** — never against the orchestrator's memory of what it dispatched or what a transcript claimed. Three rules:

- **Sole source of intent.** The gap being measured is code vs. `tasks.toml` ACs and roadmap/milestone intent. If the intent itself was wrong, that's a task edit first, then a sweep against the corrected intent.
- **Append, never rewrite.** Every unmet criterion, partial delivery, or intent gap becomes a **new `rmap new` task** (D/B/U-scored, gated per `task-writing.md`) referencing the task it converges on. Never reopen, rewrite, renumber, or edit the history of existing tasks to make the gap disappear — `attempts`/`implemented` records are evidence, not scratch space.
- **Clean sweep = zero mutations.** When the surface already satisfies the roadmap, the sweep leaves `tasks.toml` **byte-for-byte unchanged** — no empty "convergence" ceremony entries, no touched timestamps. A sweep that always writes something is measuring itself, not the code.

### Portfolio Conventions

- **Agent does not commit unless asked.** Staged-but-uncommitted is the default handoff between implementer and reviewer sessions (`workflow-philosophy.md` § "Implementer / Reviewer Handoff"). Harness runs commit agent work to `harness/<run-id>` automatically — that is harness's deliverable branch, not the operator's main checkout.
- **Reviewer discoveries arrive as proposals, and the ORCHESTRATOR files them post-land.** A reviewer that filed a discovery by editing `roadmap/tasks.toml` in its worktree assigned ids from a stale fork (id collisions that block the lander — observed ccxt_client 2026-07-19), couldn't see the live pending set (so the one-session=one-task merge gate never fired), and made roadmap files a universal write-set overlap across "disjoint" waves. That channel is closed: reviewers now emit `proposed_tasks` in `.harness/review.json`, and `roadmap/tasks.toml`, `roadmap/data.json`, `ROADMAP.md`, and `CHANGELOG.md` are excluded from delivery commits, so a run diff carries only code. After each land, read the proposals via `dispatch-verdict_detail` and file only the warranted ones through your own task-writing gate — dedupe against the live pending set, merge per `task-writing.md`, score with real ids off `origin`. Harness persists proposals verbatim and never files them.
  - **🚨 Default-DECLINE — the proposal pipeline outproduces the backlog's right to grow.** Reviewer + audit agents emit ~1 proposal per run; an orchestrator that files "everything evidenced and cross-session" lands N tasks and files N new ones per wave — net backlog delta ±0, the roadmap never converges (observed ccxt_client 2026-07-22: 11 landed, 11 filed in one session, including a D2 one-file fix filed+dispatched instead of done inline, a B4/U3 cosmetic filed instead of declined, and a follow-up that existed only because its parent was scoped as a patch instead of the invariant). Evidence + cross-session is the FLOOR, not the bar. File a proposal only when ALL THREE hold: (a) real defect or invariant gap with evidence, (b) not foldable into an existing pending task — and when the proposal patches an instance of a class, scope the filing as the CLASS invariant so the next instance can't spawn a sibling task, (c) not inline-doable in minutes by the orchestrator — if it is, DO it now instead of filing. Declined proposals need no ceremony: the verdict record in the ResultStore is their evidence trail.
  - **Report the net backlog delta** (landed − filed) as an explicit number in every wave/session wrap-up. A session trending ±0 or negative-growth is the churn alarm firing — tighten the decline bar, don't normalize it.
- **Witness notification is sakshi (read-only).** Landing outcomes notify via configured command sink; the sink grants no merge capability. Human operator reviews blocked/conflict outcomes — harness does not silently force-push past conflicts.
- **`check_command` is a dispatch-scale hint to the reviewer.** Free text (e.g. `"mix check.dispatch"` for Elixir, with focused tests chosen by the reviewer) — the reviewer runs and judges it; harness does not execute it mechanically. Keep full-suite commands like `mix precommit.full` for the landed-base Architect/QA pass. For verbose checks, capture to a per-run `mktemp` log on the first execution; never re-run only to recover truncated output.
- **The cross-family reviewer reads `AGENTS.md`, not your Claude skills/includes.** `AGENTS.md` is generated from `CLAUDE.md` by `claude-marketplace/scripts/sync-agents-md.sh`, which recursively inlines every `@`-import. **Regenerate it after any `CLAUDE.md` change** (`bash ~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh`, or `--dry-run` to preview) so the reviewer gates against current rules — a stale `AGENTS.md` makes codex/cursor/grok judge against rules you've already changed. **`--check` is the freshness gate** — it re-renders in memory and exits non-zero if `AGENTS.md` has drifted (diffs rendered output, not mtimes, so it catches drift in transitive `@`-imports too); wire it into CI / a pre-commit hook / the `check_command` so staleness fails loudly instead of silently. Consequence under Opus-4.8 skill-on-demand: once `CLAUDE.md` slims to the eager floor, reviewer-critical facts that *were* carried by eager includes (the `check_command` gate; that `mix test.json` / `mix dialyzer.json` emit JSON **by design** — parse for real failures, never flag the envelope; plain `mix dialyzer` is authoritative when the JSON encoder can't serialize a warning) no longer reach `AGENTS.md` via those imports. Put them in a **self-contained `## Toolchain & check commands` section in `CLAUDE.md`** so they survive the slim-down and flow into `AGENTS.md` on regen (ref: `tapakly/CLAUDE.md`, `ccxt_extract/CLAUDE.md`).
- **Delegation roster — opus last, and don't over-default to codex.** When assigning a dispatchable task to a harness adapter, prefer the external agents — **cursor, codex, grok** — and reserve the **claude/opus** adapter for work that genuinely needs it (harness-surface changes, judgment-heavy review, tasks the cheaper adapters keep bouncing). Opus tokens are precious: spend them last, not by default. Mix adapters across a wave for review coverage. A repo may override the roster in its own CLAUDE.md.
  - **Observed failure mode: reflex-routing everything to `codex`.** Run ledgers skew heavily codex-over-cursor/grok. Actively spread `assignee` across all three; reserve codex for tasks it's genuinely scored best on, not as the default.
  - **`cursor` runs on Composer (`composer-2.5`) by default — and that's the data-backed pick.** Pin `model = "composer-2.5"` for cursor work: it's the cheapest cost-to-green in the ledger, and **every cursor capability KPI is measured on Composer** (it's a multi-model front-end, but the scores you'd route on reflect Composer, not whatever you pin). The `composer-2.5-fast` variant is cheaper still, but its budget routinely exhausts and the operator blocks it — so **`composer-2.5` (non-fast) is the standing default**; confirm the live id with `cursor-agent --list-models` / `model_availability-list_available_models cursor`. Heavier cursor models exist — as a multi-model front-end its roster churns fast (2026-07-09 build lists `claude-opus-4-8-thinking-high`, the new **`gpt-5.6-sol-high` / `gpt-5.6-sol-xhigh`** = GPT-5.6 Sol at 1M context, `grok-4.5-*`, `gpt-5.5-high`, etc.) — but none is the default, all carry **no** capability data, and the Opus/frontier tiers draw a *monthly token budget that exhausts* (when spent the operator blocks it and routes Opus-grade work to codex gpt-5.6-sol) — pinning one *claims performance the ledger doesn't show*, so reach for it only with a concrete, named reason, not as the "design-heavy/Opus-grade" reflex. Model IDs churn *and get retired* — a pinned id that drops off the live roster silently fails; confirm with `cursor-agent --list-models` / `model_availability-list_available_models cursor` and prune stale selections. **`model` is REQUIRED at creation for any non-`human` assignee** (`rmap new` rejects a model-less dispatchable task — "a dispatchable task must pin the LLM it runs on"; see `rmap.md` § "Pinning an LLM model"); "leave `model` unset for the agent default" does NOT work. Set `assignee` **and** `model` at task creation per `rmap.md`.
  - **`grok` runs on `grok-4.5` — the new frontier default (2026-07), replacing the retired `grok-build`.** Both implementer and reviewer grok seats default to `grok-4.5`; `grok-composer-2.5-fast` is the cheap variant. `grok-4.5` is brand-new and carries **no** capability/cost-to-green data yet — route to it to *gather* that data (A/B via `dispatch-compare` grok-4.5 vs codex/gpt-5.6-sol), not on a performance claim the ledger doesn't yet show. A newly-probed grok model lands in the catalog as `selected?: false`; select it (`model_availability` toggle) before it's dispatchable. Confirm live ids with `grok models` / `model_availability-list_available_models grok`.
  - **`codex` runs on `gpt-5.6-sol` — the standing default since 2026-07-31; `gpt-5.5` is RETIRED from the live catalog.** The GPT-5.6 family (2026-07-10) splits generation from durable capability tier: **Sol** = flagship (complex reasoning/coding/agentic, $5/$30 per 1M tok), **Terra** = balanced (~5.5-competitive at 2× cheaper, $2.50/$15), **Luna** = fast/cheap ($1/$6). Model ids: `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` — the live catalog lists ONLY these three; `agent_model.codex` is pinned to `gpt-5.6-sol` (verified 2026-07-31 via `config-get agent_model.codex` + `model_availability-list_available_models codex`). **Pin `model = "gpt-5.6-sol"` for new codex tasks**, and re-pin any task still carrying `gpt-5.5` when you touch it — a retired pin fails at dispatch. `terra` remains the cost-to-green candidate (2× cheaper, ~5.5-competitive) — A/B it via `dispatch-compare` before routing bulk work to it. Confirm live ids with `codex debug models` / `model_availability-list_available_models codex`; a probe failure falls back to the builtin seed.
### Known Sharp Edges

- **Fresh worktrees lack `deps/` / `_build/`.** Implementer and reviewer each run project bootstrap (e.g. `mix deps.get`) when needed — budget timeouts for cold worktrees.
- **Reviewer runs the checks.** No mechanical check stack. Correct-but-not-pristine work → reviewer fixes and approves (`reviewer_diff_size` > 0).
- **Cold dialyzer PLT** dominates first reviewer check run in Elixir worktrees.
- **Nested Claude auth.** `ANTHROPIC_API_KEY` shadows subscription OAuth — scrub per run (`scrub_anthropic_key: true` or `env: %{"ANTHROPIC_API_KEY" => false}`).
- **Parallel-session rmap mutations** during a run can false-positive `:checkout_polluted` — wait for the wave or use a separate worktree.

### Repo-Specific Detail

| Need | Where |
|---|---|
| Harness API surfaces, MCP tool shapes | `skills/harness-driver/SKILL.md` in harness repo |
| Driver script template, cutover history, run log | `docs/dogfooding-workflow.md` in harness repo |
| Agent-gate architecture spec | `docs/agent-gate-workflow.md` in harness repo |
| Cross-checkout consumer setup | `skills/harness-driver/SKILL.md` § "Context A" |
| D/B/U scoring, task writing | `task-prioritization.md`, `task-writing.md` |
| Manual session/PR/audit chain | `dev-lifecycle.md`, `worktree-workflow.md` |


(`response-conventions` loads globally via `~/.claude/CLAUDE.md` — not re-imported here.)

## What this repository is

`bourse` (`:bourse`, namespace `Bourse.*`) — an Elixir client for eleven exchange integrations: `alpaca`, `binance`, `binancecoinm`, `binanceusdm`, `bybit`, `coinbaseexchange`, `deribit`, `derive`, `hyperliquid`, `lighter`, `okx`. One complete hand-authored JSON spec per venue drives macro-generated endpoint modules; the three DEX venues carry hand-written signing. Coinbase Exchange is deliberately public-only and exposes candles plus ticker.

Runtime support is a **closed set**. `Bourse.Exchanges` and `Bourse.Registry` read `priv/specs/json/runtime_support.json` and generate exactly eleven modules; constructing anything else fails immediately with `unsupported_exchange`. There is no `config :bourse, exchanges:` knob — support is not a configuration outcome.

### 🚧 The workbench boundary — read this before deciding where work goes

This repo was extracted from `../bourse_workbench`, which remains the **authoring workbench**. The split is by question, not by file type:

| Question | Repo |
|---|---|
| Does the client behave correctly against a supported venue? | **here** |
| Is a supported venue's authored spec right? | **here** — the spec, its authority manifest and its reality evidence all live here |
| Does an eleventh venue get added? | **here** — `mix ccxt.promote_venue` grades its candidate against the reality manifests, and those live here. Pass the pinned CCXT reference document in from the workbench with `--reference`. |
| Did the full CCXT reference extraction shift across all 110 venues? | workbench — this repo carries a 16-venue slice and cannot answer corpus-wide questions |
| Roadmap and task scoring, and the CHANGELOG gate that reads it | workbench — one rmap, declaring `project = "bourse"`. It is not a workbench roadmap that mentions this client; it **is** this client's roadmap. Do **not** stand up a second rmap here. |
| Where does a consumer file a bug? | **here**, in `BUGS.md` — this is the only repo a consumer knows. Triage into scored tasks happens in the workbench, and writes a dated note back into the entry. |

#### 🚨 The roadmap admits reported defects — quality work against the API surface has no end

Eleven venues times ~240 unified methods is an effectively unbounded surface. A live
measurement, a reviewer proposal or a coverage sweep will *always* find one more true
thing, and every one of those findings is real. That is precisely why "is it real"
cannot be the filter: it rejects nothing, so the backlog stops converging. Measured on
this project — 103 tasks filed against 101 landed across fourteen days, and fifteen
tasks created in one day (647–661), several of them grandchildren of a single stack
trace.

**A finding enters the workbench roadmap only when a consumer reported the defect.**
Everything else — a drift you measured live, a reviewer's `proposed_tasks`, an
uncovered branch, a carve you would author differently — goes into `BUGS.md` with its
evidence and stops there. `BUGS.md` is the durable record; the roadmap is the work
queue, and they are not the same list.

- ✅ DO: append the measurement to `BUGS.md` with the exact call, the observed value and the expected one. That preserves the finding at zero dispatch cost.
- ✅ DO: fix it inline and say so when it is bounded and local. A finding you can close in minutes never needed a task.
- ❌ DO NOT: file because a finding is genuine, evidenced and cross-session. Those are the floor, not the bar — they admit everything.
- ❌ DO NOT: promote a reviewer proposal on the strength of its shape. Proposals arrive pre-scored and dispatch-ready; that is a rendering choice, not a routing decision.

**Security and data-loss defects are filed on discovery** regardless of who found
them, sanitized per `critical-rules.md` § NEVER BROADCAST AN UNPATCHED VULNERABILITY.

This tightens the portfolio-wide Default-DECLINE bar in `harness-workflow.md`, which
governs whether a proposal is *worth* filing. Here the question is prior: whether the
roadmap is the right destination at all.

#### Where harness runs from — three locations, none of them optional

`bourse` is registered in `Harness.ProjectRegistry`, and the registration is what
resolves the split. Verify it with `project_registry-list` rather than guessing:

| Role | Location | Registry field |
|---|---|---|
| The harness BEAM | `~/_DATA/code/harness` (`iex -S mix`) | — never the target repo |
| Code — what gets forked, reviewed and landed | `~/_DATA/code/bourse` | `source` |
| Roadmap — what gets read, scored and status-written | `~/_DATA/code/bourse_workbench` | `roadmap_path` |

**Harness resolves `roadmap_path` itself** — `Harness.Roadmap` shells `rmap` there
and owns durable roadmap writes into that repo. A dispatch call passes
`project: "bourse"` and nothing else; the orchestrator never shuttles task state
between the two checkouts by hand.

**Drive the loop from this repo.** The dispatched work is bourse code, and
verification needs what only lives here: `mix check.dispatch`, the testnet
credentials, the venue authority index, and this file's doctrine. Sit in the
workbench only for deliberate roadmap surgery, where `rmap` wants to be cwd.

🚨 **The two repo locations above are doctrine; every other registration value is
not written down here on purpose.** `check_command`, `concurrency_cap`,
`landing_policy`, `target_branch`, `reviewer` and the model pins are operator
settings that change without anyone thinking about this file — a copy of them here
would be stale duplication with no gate to catch it, and the registry is on this
host only, so no CI check can ever guard it. Read them from
`project_registry-list`, which is the authority. Never quote them into a doc.

**Consequences that bite if forgotten:**

- **Read `BUGS.md` before chasing a reported defect.** It is the inbound consumer queue, newest first, and each entry carries a `**Status:**` header — the bug in front of you may already be filed, already fixed, or already decided against. Entries are never deleted; a fixed one keeps its repro as the evidence trail.

- One test deliberately stayed in the workbench because it is corpus-wide: the zero-param JSON-body gate audit, which asserts a gate set across all 110 reference specs. The same applies to anything else that iterates every document under `priv/specs/json/output/` expecting the full set. **Do not re-add a corpus-wide audit here** — it would be answering a 110-venue question with 15 specs.
- `priv/specs/json/reference_corpus.json` honestly declares the 16 carried venues (the eleven supported plus `coinmetro`, `deepcoin`, `kraken`, `weex`, `whitebit`, used as parser and unsupported-venue counter-examples). Its two SHA-256 pins still name the upstream revision the slice came from, so provenance stays verifiable. **Adding a reference venue means adding its JSON *and* the manifest entry** — `Bourse.ReferenceSlice` validates count, sort order and pins, and raises otherwise. That module lives in `test/support/`, not `lib/`: the slice is test input, so neither the client nor the Hex package can reach it.

## 🎯 Core doctrine: provider-authoritative, reality-verified

**Interpret, don't extract.** Full model and rationale: `docs/authored-specs.md` — read it first.

**The one and only reality is the exchange APIs we talk to** — not CCXT, not CCXT's fixtures, not training. CCXT was the bootstrap; it is now **one disposable reference among several** (exchange API docs, official SDKs, observed behavior). The DEX venues already live this way. Three axes, kept distinct: **value** correctness (is the number right vs reality), **carve** correctness (is the field/abstraction itself right, willing to *diverge* from CCXT's ontology), and **freshness** (frozen recordings kept honest by live drift checks).

**Authority ladder — the exchange-owned contract wins.** Live or recorded raw exchange behavior establishes what the venue does; the exchange's own documentation, specifications and SDKs establish what its fields and parameters mean. CCXT source, execution and static files are unverified authoring references only.

**Authoring and verification stay separate.** Author by reading multiple sources; verify through manifest-registered venue recordings, accepted-request goldens and recorded exchange errors. `mix ccxt.oracle_gate` is the only verification oracle in the check pipeline.

**Verification is binary.** A claim is `verified` only when the reality manifests and `mix ccxt.oracle_gate` cover it; otherwise it is `unverified`. CCXT JS is a tool, not the truth: its parser output can inform authoring but cannot verify venue semantics.

### Rules

- ✅ DO: author interpretive slices against the exchange-owned API contract, using CCXT only as reference material; keep `mix ccxt.oracle_gate` green.
- ✅ DO: verify by **running/observing**; author by **reading** any source. A source that fed authoring cannot also be the oracle.
- ✅ DO: run the **confrontation step** when authoring a venue slice (`docs/authored-specs.md`) — for each schema decision, confront the CARVE (does the field exist here? what does the value mean? is the abstraction right for this venue?) against the exchange's OWN semantics. Record every CONFIRMED / DIVERGE outcome in the venue's carve register under `docs/authored-spec-carves/`. A CCXT carve adopted without a register entry is inherited, not confronted.
- 🚨 DO: keep it REAL — for divergence-prone fields (anything CCXT *computes* or *branches* rather than copies: precision, inverse-vs-linear cost, funding cadence, fee tiers), test against the **REAL API plus a non-CCXT semantic source**, never against a potentially-wrong CCXT fixture. A wrong fixture is *more costly* than a live call: it certifies our bug green and silent. The canonical case: deribit's funding `interval` was the authored literal `"8h"` while the venue publishes hourly — internally consistent, fully tested, and wrong, because the golden was computed with the same wrong constant.
- 🚨 DO: **decolor on touch.** Comments, moduledocs and docs that cite CCXT as the *reason or authority* for a decision steer every future session back toward CCXT-as-truth. Never write a new one. `test/bourse/ccxt_authority_language_test.exs` enforces this with an explicit allowlist — a new CCXT mention in `lib/` fails the suite until it is either reworded or allowlisted with a compatibility-framed phrase.
- ✅ DO: when a reality confrontation is **unreachable with our keys/hosts** (prod-only endpoint, region-restricted key, needs a real open position), append an entry to `docs/prod-verification-ledger.md`. The slice stays `unverified` until the ledger entry closes and the recording is registered.
- ❌ DO NOT: treat CCXT-derived data or training/web as verification. Independence comes from execution/reality, not a second read.
- 🚨🚨 DO (behavioral default, anchored to the ACTION): **when you set out to check whether a venue "works," your FIRST call hits the LIVE venue.** Use testnet/demo for credentialed venues and the production public host for public-only Coinbase Exchange. Recipe: `creds = Bourse.Credentials.new!(api_key: System.get_env("DERIBIT_TESTNET_API_KEY"), secret: ...); {:ok, ex} = Bourse.Exchange.new("deribit", credentials: creds, sandbox: true)` → then a real `Bourse.fetch_ticker/fetch_balance`. Testnet credentials for all ten credentialed venues are provisioned (below); Coinbase Exchange needs none.

### Venue authority index

Any venue-source, contract-coverage or field-judgment question opens `priv/authority/<venue>/` **FIRST**. The manifest is the local provenance index, not the authority itself: when the question is discovery or freshness, check the provider's official upstream next. Manifests record URL, upstream revision, retrieval date, byte count, SHA-256 and licensing disposition.

| Venue | Official docs | Testnet/demo host | Recordings |
|---|---|---|---|
| Alpaca | [Trading API](https://docs.alpaca.markets/) | `https://paper-api.alpaca.markets` | tagged live integration |
| Binance | [Spot API](https://developers.binance.com/en/docs/products/spot) | `https://testnet.binance.vision` | `test/fixtures/responses/binance/` |
| Binance COIN-M | [COIN-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-coin-futures) | `https://demo-dapi.binance.com` | `test/fixtures/responses/binancecoinm/` |
| Binance USD-M | [USD-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures) | `https://demo-fapi.binance.com` | `test/fixtures/responses/binanceusdm/` |
| Bybit | [V5 API](https://bybit-exchange.github.io/docs/v5/intro) | `https://api-testnet.bybit.com` | `test/fixtures/responses/bybit/` |
| Coinbase Exchange | [Exchange REST API](https://docs.cdp.coinbase.com/api-reference/exchange-api/rest-api/products) | production public only | `test/fixtures/responses/coinbaseexchange/` |
| Deribit | [API v2](https://docs.deribit.com/) | `https://test.deribit.com` | `test/fixtures/responses/deribit/` |
| Derive | [API reference](https://docs.derive.xyz/) | `https://api-demo.lyra.finance` | `test/fixtures/responses/derive/` |
| Hyperliquid | [API reference](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api) | `https://api.hyperliquid-testnet.xyz` | `test/fixtures/responses/hyperliquid/` |
| Lighter | [API reference](https://apidocs.lighter.xyz/) | `https://testnet.zklighter.elliot.ai` | reality manifests + accepted-request goldens |
| OKX | [API v5](https://www.okx.com/docs-v5/en/) | `https://www.okx.com` + `x-simulated-trading: 1` | `test/fixtures/responses/okx/` |

Artifact **freshness**, **expressiveness** and **scope** are separate axes. A maintained Postman collection can be current but untyped; a frozen OpenAPI can be richly typed but stale. A manifest pin proves which bytes were reviewed, not that the artifact is complete.

**Missing coverage fails open.** A declared unified read without an authored parse slice can return the provider's raw transport envelope inside `{:ok, ...}`; an operation absent from the authored spec is invisible even to that guard. Completeness work must measure both boundaries.

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) and any dispatch run.

- **`mix check.dispatch`** — the dispatch-scale gate: `precommit`, `ccxt.oracle_gate`, `ccxt.check_lighter_signer`, `ccxt.claude_check`, `ccxt.agents_md --check`, `ccxt.authority_check` (offline), `ccxt.error_authority`, the domain-boundary guard, `ex_dna --max-clones 0`, `reach.check --arch --smells --strict`. No dialyzer (a cold worktree cold-builds the PLT for minutes).
- **`mix precommit`** — lean local commit gate (format / compile --warnings-as-errors / credo --strict / doctor --raise / sobelow --skip / offline `test.json`).
- **`mix precommit.full`** — adds `deps.audit` + dialyzer (local pre-PR).
- **`mix ci`** — `check.dispatch` + `deps.audit` + dialyzer.

`--cover` is omitted from all of them; run it explicitly (`mix test.json --cover`) per the critical-rules coverage gate.

| Check | Command | Notes |
|-------|---------|-------|
| Compile | `mix compile --warnings-as-errors` | silent finish = success |
| Tests | `mix test.json --quiet` | **emits JSON by design** — parse it for real failures; the envelope is **not** a build error. Read `summary.result` / `summary.failed`. Most integration tests are excluded without `--include` tags. |
| Reality oracle | `mix ccxt.oracle_gate` | Verifies registered response recordings, accepted-request goldens and recorded exchange errors. |
| Dialyzer | `mix dialyzer.json --quiet` | **emits JSON by design**. Plain `mix dialyzer` is the authoritative fallback when the JSON encoder can't serialize a warning shape. |
| Lint | `mix credo --strict` | |
| Security | `mix sobelow` | honors `.sobelow-skips` (hash-based), **not** inline comments |
| Docs | `mix doctor` | |
| Authority corpus | `mix ccxt.authority_check [--online]` | validates the pinned corpus offline; `--online` checks mutable upstreams for drift |
| Error mappings | `mix ccxt.error_authority` | reconciles provider-documented error codes with authored mappings |
| CLAUDE claims | `mix ccxt.claude_check` | modules / `mix ccxt.*` tasks / repo paths named in gated CLAUDE.md regions, plus the signing pattern list and `Application` children, vs the tree. Unlisted tree surfaces are not failures. |
| AGENTS freshness | `mix ccxt.agents_md --check` | re-renders CLAUDE.md + the pinned `@`-imports (`priv/agents_includes/`) and fails on drift. Regenerate with `mix ccxt.agents_md`. |

**Venue promotion** — adding an eleventh venue is a graded promotion, never a config flag:

```bash
mix ccxt.promote_venue --prepare --reference REF --candidate CANDIDATE --report REPORT
mix ccxt.promote_venue --check   --candidate CANDIDATE --report REPORT [--reference REF]
```

`REF` is a pinned CCXT reference document — supply it from the workbench corpus; this repo carries only a 16-venue slice. The task creates and grades a candidate, and never adds runtime support on its own. Its evidence report uses one binary vocabulary: `verified` requires provider-owned semantics *plus* manifest-registered reality for every critical slot; everything else is `unverified`. `--check` re-derives the method inventory from the reference, byte-verified against `report.reference.sha256`.

**Do not reject a run because `mix test.json` / `mix dialyzer.json` printed JSON** — that is the intended output format, not a failure.

## Running tests

```bash
mix test.json --quiet --failed                       # default iteration
mix ccxt.oracle_gate                                 # manifest-registered reality oracle
mix test.json --quiet --include network              # integration probes (testnet env required)
mix test.json --quiet --only unified_integration     # unified integration probes
mix ccxt.classify_signing                            # signing classification report
mix ccxt.verify_live_drift                           # recordings vs live venue drift
mix ccxt.verify_ws_first_frame                       # classified public WS first data frame per venue
mix ccxt.aggregate_live_lane                         # merge live-lane surface reports into one artifact
```

> **⚠️ `mix test.json` silently excludes most integration tests by default.** A green run with no `--include` tags covers offline unit + signing tests only. Tags: `integration`, `network` (testnet REST probes), `dangerous` (raw POST/PUT/DELETE), `invalid_creds`, `capability_live`, `option_readiness`, `known_defect`, `native`.

> **⚠️ `:known_defect` quarantine tag — governed, must only shrink.** A test may carry it ONLY when its assertion states the CORRECT expectation, the product is wrong, and the tag comment names the tracking issue. Never weaken an assertion to avoid the tag, and never use it to park a red whose root cause is untracked.

**Per-exchange module split:** `raw_endpoint_probe_test.exs` and `unified_method_integration_test.exs` generate one module per exchange per auth class. `PrivateTest` / `PrivateDangerousTest` gate on a `setup_all` that raises once when creds aren't registered — a missing-creds exchange produces a single module-level flunk instead of N per-endpoint flunks. `PublicTest` / `PublicDangerousTest` always run.

**`Bourse.Testnet` is not an application child.** It is a sandbox-only ETS credential registry that consumers must not boot; `test/test_helper.exs` starts it explicitly via `start_link/1`.

### Testnet credentials

Loaded via `Bourse.Testnet.register_all_from_env/1` in `test_helper.exs`. Env convention `{EXCHANGE}[_{SANDBOX}]_TESTNET_API_KEY/_API_SECRET`, with documented exceptions below. All ten credentialed venues are provisioned; public-only Coinbase Exchange uses no credentials.

- **Alpaca** — `ALPACA_API_KEY/SECRET`; `sandbox: true` resolves `paper-api.alpaca.markets`. Never point the lifecycle test at the live-money host.
- **Bybit** — `BYBIT_TESTNET_API_KEY/SECRET` is **READ-ONLY**: the testnet key returns business error 10024 on any signed create (region-restricted). Don't burn a probe cycle rediscovering this. **Trade evidence runs on DEMO instead**: `BYBIT_DEMO_API_KEY/SECRET`, host `https://api-demo.bybit.com` — which is **not** `sandbox: true` (that's testnet); pass `base_url:` on the call. Requests omitting `category` fail with 10032.
  - Option orders REQUIRE `orderLinkId` (10001 without it; linear doesn't). Nearest-expiry options are **USDT-settled**.
  - **A SHORT option can become unclosable — pick the instrument for the close, not the open.** Bybit enforces a mark-relative price band (`110003`), and deep-OTM/far-expiry demo books have a single ask far outside it, so a short that filled cannot be bought back at any accepted price (observed 2026-07-25). Select an instrument whose ask sits *inside* the band before selling.
  - **Option TP/SL is `POST /v5/position/trading-stop` only, and an omitted leg CLEARS the other one** under `tpslMode: "Full"` (verified live: a call carrying only `takeProfit` silently wiped the existing `stopLoss`, retCode 0). Always send both legs when amending either. `triggerPrice` on `/v5/order/create` is silently ignored for options.
  - `GET /v5/account/fee-rate` is unusable on demo (empty list with retCode 0 for options, HTTP 400 for linear) — measure fees from actual fills.
- **Deribit** — `DERIBIT_TESTNET_API_KEY/SECRET`.
- **Binance spot** — `BINANCE_TESTNET_API_KEY/SECRET`.
- **Binance USD-M / COIN-M** — the **same** `BINANCE_FUTURES_TEST_API_KEY/SECRET` pair authenticates both (`_TEST_` is a silent fallback for `_TESTNET_`). `demo-dapi.binance.com` and the legacy `testnet.binancefuture.com` are one account, not two environments. **COIN-M and USD-M are separate wallets inside that one account**, and the UI faucet credits USD-M only — a drained COIN-M wallet is re-funded through the UI. The account runs **One-way mode** (verified live 2026-08-10: `GET /fapi/v1/positionSide/dual` → `dualSidePosition: false` — an earlier Hedge-Mode note here was stale), so orders need no `positionSide` and `reduceOnly` is accepted; if the mode is ever flipped to Hedge, orders REQUIRE `positionSide` and fail `-4061` without it. Oversized orders fail `-2019` — a real pinnable business error. `BTCUSD_PERP` is inverse, 100 USD notional per contract. `DELETE /dapi/v1/allOpenOrders` returns `code 200` even with nothing resting, so it is a safe idempotent cleanup hook.
- **OKX — international demo is canonical.** `OKX_INTL_API_KEY` / `_API_SECRET` / `_PASSPHRASE`, host `www.okx.com` + `x-simulated-trading: 1` (both supplied by `sandbox: true`). The same key on live returns 50101. Option orders at `acctLv 3` require `tdMode: "isolated"`; demo option books carry no two-sided ATM liquidity, so order-accept/cancel is the available lifecycle. **Sharp edge:** batch envelopes report `code "1", msg "All operations failed"` with the real per-order `sCode`/`sMsg` only in `data[0]`. Never use `my.okx.com` or `OKX_TESTNET_*` for new probes — historical EEA recordings remain valid provenance only.
- **Lighter** — DEX (zk perp), not an HMAC pair: `LIGHTER_TESTNET_API_KEY_INDEX` (0–255), `LIGHTER_TESTNET_ACCOUNT_INDEX`, `LIGHTER_TESTNET_API_PRIVATE_KEY` (40-byte hex). Signing is zk-Schnorr through the supervised first-party helper (`Bourse.Signing.Lighter` + `native/lighter_signer/`) — there is no in-Elixir signer. `sandbox: true` selects the testnet host **and** chain id 300 (mainnet is 304; the chain id is part of the signed payload, so a mainnet-chain signature is rejected on testnet). Private reads need an `auth_deadline` and `account_index`; writes need a caller-supplied `nonce` from `public_get_nextnonce` plus a `client_order_index`. Only `limit` orders are supported.
- **Hyperliquid** — DEX; "creds" = an EVM wallet. `HYPERLIQUID_TESTNET_API_KEY` = wallet address, `_API_SECRET` = its private key. Testnet funded via the official drip (`POST /info {"type":"claimDrip","user":…}`, unlocked by a ≥5 native-USDC mainnet Bridge2 deposit from the same address; re-claimable every 4h).
- **Derive** — DEX (Lyra v2). `DERIVE_TESTNET_API_KEY` = the **Derive smart-contract wallet** (what `X-LyraWallet` must carry, NOT the owner EOA); `DERIVE_TESTNET_API_SECRET` = a **registered Admin session key's** private key. REST base `api-demo.lyra.finance`. **Sharp edge:** Derive's edge proxy verifies auth *before* the app — the signer must equal `X-LyraWallet` or be a registered session key for it, else nginx returns HTML 403 with no JSON. The owner EOA is NOT auto-registered on UI onboarding, so a plain owner signature 403s.
  - Order placement: the order endpoints carry `body_encoding: "json"`, so dispatch JSON-encodes params *before* the signer runs — sign the eight-field tuple yourself with `sign_order(order, private_key: ..., testnet: true)` and put the `"signature"` string in params. `max_fee` is required AND has a dynamic floor (~1.5 USDC; error 11023 names the exact minimum) and is part of the signed hash, so re-sign after adjusting. The request also needs `"signer"` (the session key's EOA address), `nonce` (ms), `signature_expiry_sec`, and the trade-module data hash built from `base_asset_address`/`base_asset_sub_id`.

## Do NOT edit (generated) / DO author (frozen specs)

- `lib/bourse/exchanges/*.ex` — generated at compile time; never hand-edit (fix the generator).
- `priv/specs/json/output/authored/<venue>.json` — **the complete hand-owned runtime documents** (eleven venues, schema version `3`). These you DO edit, by authoring per the loop in `docs/authored-specs.md`, then proving green with `mix ccxt.oracle_gate`.
- `priv/specs/json/output/<venue>.json` — frozen CCXT-derived **reference** siblings (the 16-venue slice), pinned by `reference_corpus.json`. Never loaded at runtime, never shipped in the Hex package; read-only authoring/test input (e.g. the test-only `markets.symbols_index` used by integration symbol selection).
- `priv/reference_cache/` — vendored market/currency slice for `Bourse.ReplayExchange`. Compatibility reference only; the one module that reads it. Neither the cache nor its reader is packaged.

## Architecture

```
Bourse.fetch_ticker(exchange, "BTC/USDT")     # Unified API
    → Bourse.Bybit (generated module)          # use Bourse.Exchange, spec: "bybit"
        → Bourse.Dispatch.call/4               # Shared dispatcher
            → Bourse.Signing.sign/4            # 8 patterns
            → Bourse.HTTP.request/4            # Req wrapper
            → Bourse.Parser.apply_mappings/3   # Field mapping
```

- **Macro generation:** `use Bourse.Exchange, spec: "bybit"` loads the JSON spec at compile time → generates endpoints, introspection, Descripex wiring.
- **Shared dispatch:** generated functions are thin wrappers around `Bourse.Dispatch.call/4`.
- **Judgment is authored, never inferred at runtime.** The heuristic-interpretation layers are deleted: no `Recipe.resolve`, no `Symbol.classify_pattern/2`, no consumer custom-signer escape hatch, no signing classifier. The runtime reads `auth.sign_recipe` through `Bourse.Signing.HmacRecipe`, symbol patterns from authored `markets.symbol_patterns`, and emulated methods from the authored slice.

### Key modules

| Module | Purpose |
|--------|---------|
| `Bourse` | Unified API entry — 242 methods + bang variants + Descripex `api()` + `describe/0-2`. Generated from `Unified.method_defs/0`. |
| `Bourse.Unified` | Internal dispatch: `method_defs/0` (4-tuples), `call/5`, `split_opts/1`, `build_params/3`. Not public. |
| `Bourse.Exchange` | Config struct + constructor + generator macro. Carries `:tier`, `:module` (O(1) dispatch), `signing_pattern`, `signing_config`, `symbol_patterns`, `error_body_checks`, `error_code_fields`. |
| `Bourse.Spec` | Compile-time JSON spec loader. Enforces owned `schema_version` `3`. One complete owned document per venue — no base/overlay merge, no CCXT-base fallback. |
| `Bourse.Spec.Schema` | Owned runtime-schema contract. Required/forbidden slot table; raises `owned spec "<venue>" gap <path>` on any missing/null/empty/forbidden slot. |
| `Bourse.Symbol` | Bidirectional symbol normalization, driven by the authored `markets.symbol_patterns` slice. |
| `Bourse.Error` | `defexception` — 18 error types covering 34 compatibility exception classes. Pattern-matchable AND raiseable. |
| `Bourse.Dispatch` | Runtime dispatcher: path interpolation, base URL resolution (4 patterns), signing, HTTP delegation. |
| `Bourse.HTTP` | Req wrapper — manual query encoding, safe retry GET/HEAD only, telemetry, circuit breaker. |
| `Bourse.RateLimiter` | Per-credential weighted GenServer, sliding window. Key `{exchange, api_key \| :public}`. |
| `Bourse.ReplayExchange` | **Repo-internal.** Offline replay exchange from `priv/reference_cache/`. The **only** module reading the vendored slice. |
| `Bourse.RecordedResponseFixtures` | **Repo-internal.** Capture support and path resolution for the committed reality evidence. |
| `Bourse.Application` | Supervises `Bourse.RateLimiter` + `Bourse.RateLimiter.State` + `Bourse.Signing.Lighter.Supervisor` + `Bourse.WS.Broadcast` + `Bourse.WS.ConnectionOwner.Supervisor`. |

**Unified response types:** 7 original (`Ticker`, `Trade`, `Order`, `Balance`, `Market`, `OHLCV`, `Fee`), 9 tier-1 core (`OrderBook`, `Position`, `Currency`, `Transaction`, `LedgerEntry`, `FundingRate`, `DepositAddress`, `TransferEntry`, `TradingFee`), 9 tier-2 derivatives, 9 tier-3 analytics.

**Signing:** `Bourse.Signing` dispatches 8 patterns — `:hmac_sha256_query`, `:hmac_sha256_headers`, `:hmac_sha256_iso_passphrase`, `:api_key_secret_headers` (Alpaca), `:deribit`, `:hyperliquid`, `:derive`, `:lighter`. The authoritative table lives in the module's `@moduledoc`.

**WebSocket:** `Bourse.WS` wraps `ZenWebsocket.Client`. **10 of the eleven venues are configured and confirmed streaming live** (alpaca, binance, binancecoinm, binanceusdm, bybit, deribit, derive, hyperliquid, lighter, okx); Coinbase Exchange is the registered config divergence and `connect/3` answers `{:error, :websocket_not_configured}` for it, distinct from `:unsupported_exchange` for a venue outside runtime support. `subscribe/3` returns `:ok | {:error, term()}` and surfaces venue rejections as `{:error, {:subscription_rejected, frame}}`.

**`connect/3` authenticates a `:private` section** through `Bourse.WS.authenticate/2`, and a failed handshake closes the socket rather than returning one — an open unauthenticated private connection fails later as a silently empty stream, not as an error. The accepted handshake is recorded on `ws.auth`, which is what `Bourse.WS.Adapter` schedules renewal from instead of re-running it. Live-verified differentially across six venues (`test/bourse/ws/auth_live_smoke_test.exs`). Alpaca's public market-data section is the documented exception: `auth_sections` includes `:public`, so `connect/3` runs the key/secret handshake there too.

**Not every credential is a frame — some are the URL, and that changes when the handshake runs.** `:listen_key` (binanceusdm, binancecoinm) issues its key over REST *before* the socket opens, so `connect/3` performs the round-trip and connects to the resulting URL; `authenticate: false` is refused with `{:error, {:auth_not_optional, :listen_key}}` because there is no later handshake to run. `Bourse.WS.ListenKey` owns the call and the refresh; `Bourse.WS.Auth.ListenKey` stays network-free endpoint resolution and resolves **generated raw endpoint names**, not CCXT method names — the previous config named methods that match no function here, so it looked resolved and could not be called.

🚨 **A wrong listen key connects.** Verified on `demo-fstream.binance.com` and again on `demo-dstream.binance.com`: a bogus key reports `:connected` throughout and delivers nothing, while a real one delivers `ORDER_TRADE_UPDATE`. So every failure to obtain a key must be an error, never a fallback — and the venue's own checks are weaker than they look: the listen key endpoint is **API-key authenticated and does not verify the secret**, so a differential probe has to corrupt the *api key* to mean anything.

🚨 **The two binance futures halves are two streams, not one.** COIN-M lives on `dstream` (`demo-dstream.binance.com`) and issues its key from `dapiPrivate_*`; USD-M lives on `fstream` and issues from `fapiPrivate_*`. They share one demo account and one API key pair but are separate wallets with separate user data streams, so a socket keyed by the other half's key connects and stays silent — the same failure shape as a bogus key. COIN-M's market type is `:inverse` (`:delivery` normalizes to it); its `PUT listenKey` returns the key in the body where USD-M returns `{}`.

🚨 **binance spot is not a listen key venue any more.** Binance retired the spot and margin listen keys on 2026-02-20; `POST /api/v3/userDataStream` answers **HTTP 410 Gone**. The private section is authored onto the venue's WebSocket API host (`ws-api.binance.com/ws-api/v3`), opened by a signed `userDataStream.subscribe.signature` request under the `:ws_api_signature` pattern — that one frame both authenticates and *is* the user data stream, so there is no channel to subscribe to afterwards. A `subscribe.signature` subscription also **outlives the socket that made it**, so a differential probe must run the unauthenticated leg first or it reads the previous leg's events.

One auth surface remains **unwired, and fails loudly rather than silently**: **derive authors no `auth_pattern`** although the venue has a WS login, so its private section connects without a handshake. Hyperliquid's `nil` pattern is correct — its private subscriptions are scoped by address.

### Critical design decisions

**HTTP pipeline:** manual query encoding (signing needs raw params — don't use Req's `:params`); safe retry GET/HEAD only (never POST/PUT/DELETE — duplicate orders); per-credential rate limiting for multi-user isolation.

**Exchange struct:** config, not process — pure data, no GenServer. String keys matching the JSON spec.

**Errors:** two-tier matching — `error_codes` (exact) plus `broad_error_patterns` (substring), pre-processed at construction. `error_body_checks` for top-level sentinels; `error_code_fields` for exact-code probe order.

**Dispatch:** symbol denormalization happens in `Unified.call/5`, NOT `Dispatch.call/4` — raw callers pass through untouched. Required params always win over opts (`Map.put_new` prevents silent override in trading calls).

**Authored `path_params` descriptors are `%{"name", "source"}` and `source` is ALWAYS `"params"`** — verified 1668/1668 across the catalog. `interpolate_path/3` resolves from the params map by `"name"` and deliberately ignores `source`. This is a relied-on invariant: if an authored spec ever sets a path-param source to anything else, resolving from `params` silently reads the wrong place. The fix is not to pre-build unused branches but to make the day-it-changes failure LOUD — `path_param_name/1` should match `%{"source" => "params"}` and let any other shape hit a raising clause.

**Durable kernel:** when data is finite, verifiable, and fails silently when wrong, **author it explicitly — don't infer it at runtime.** `HmacRecipe` stays as the deterministic recipe *executor* (mechanism, not judgment); author recipes into its shape rather than rebuild a signer.

## The trading domain layer

The trading domain — OptionProposal, OptionReadiness, OptionSaga, PortfolioRisk and their submodules — lives in its own repo, https://github.com/ZenHive/bourse_trading (private, ZenHive), which depends on this client's published Hex package. The modules keep the Bourse module namespace there; that is deliberate, not a leftover.

**The dependency stays one-directional: the domain calls the client's packaged surface, never the reverse.** Nothing in this repo may reference a domain module — a single inbound edge would couple the client to an unpublished repo. Domain logic (proposal checks, readiness collection, saga execution, exposure math) belongs in bourse_trading; venue behavior, authored specs, signing and unified parsing belong here.

The `docs/option_readiness/` JSON snapshots stay in this repo as frozen evidence — `docs/prod-verification-ledger.md` cites them by path.

## Repo-internal tooling inside `lib/`

The oracle / recording / replay / drift cluster — `Bourse.ExchangeAcceptanceFixtures`, `Bourse.PublicAcceptedRequests`, `Bourse.OracleProvenance`, `Bourse.OracleLabel`, `Bourse.ReplayExchange`, `Bourse.RecordedResponseFixtures`, `Bourse.LiveDrift`, `Bourse.Spec.Promotion` — lives in `lib/` because the `mix ccxt.*` tasks compile in `:dev`, where `elixirc_paths/1` does not carry `test/support`. It is **not** client surface: `@unpackaged_prefixes` in `mix.exs` keeps every one of them out of the tarball and out of hexdocs.

**Anything you add to that cluster inherits the exclusion — add its prefix.** These modules read `test/fixtures/**` and `priv/reference_cache/`, which are never packaged, and they may use `:dev`/`:test`-only deps. A shipped copy fails twice over: on missing files at runtime, and at the consumer's *compile* — the original case was `Req.Plug`, which exists only from req 0.7 and only behind the `only: [:dev, :test]` `:plug` dep, so consumers resolving `~> 0.6.1` got an undefined-module warning out of two fixture modules. `test/mix_project_test.exs` gates both halves: the package file list, and an AST scan asserting no shipped module names a dependency a consumer may not have.

## Git commit configuration

Conventional commits: `<type>(<scope>): <description>`. Types: feat, fix, docs, style, refactor, test, chore. Title-only; bodies only when asked. No `Co-Authored-By` footers.

**Release tags come AFTER the maintainer confirms the publish went through — never before.** `mix hex.publish` is run by hand (it needs 2FA), and the release gate keeps finding things right up to the prompt: 0.2.0 gained a hexdocs-filter fix and ten broken-link fixes after the version bump was already committed. A tag cut in advance names a tree that is not what shipped, and correcting it means force-updating a pushed ref. Bump the version, get the gate green, hand off the publish — then tag the published commit.
