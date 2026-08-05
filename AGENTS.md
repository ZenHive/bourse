<!-- Auto-generated from CLAUDE.md by mix ccxt.agents_md — do not edit manually -->

# CLAUDE.md

Guidance for Claude Code working in this repository.

## Active Includes

Eager-load only the irreducible floor; everything else is skill-on-demand via enabled plugins. **Don't double-load** (an `@`-import plus its sibling skill pays twice for the same tokens).

- **`critical-rules`** — hard guardrails that must stay ambient every session (a guardrail the model invokes "when relevant" fails exactly when it doesn't realize the rule applies).
- **`ex-unit-json`** — `mix test.json` is the test runner every session uses; its flight-recorder semantics and the "JSON-by-design — parse for real failures, never reject the envelope" rule are load-bearing for cross-family reviewers.

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


(`response-conventions` loads globally via `~/.claude/CLAUDE.md` — not re-imported here.)

> **Add `@~/.claude/includes/harness-workflow.md` when this repo is registered for harness dispatch.** It is not imported yet because no dispatch loop runs here; the import is load-bearing only once it does.

## What this repository is

`bourse` (`:bourse`, namespace `Bourse.*`) — an Elixir client for ten exchange integrations: `alpaca`, `binance`, `binancecoinm`, `binanceusdm`, `bybit`, `deribit`, `derive`, `hyperliquid`, `lighter`, `okx`. One complete hand-authored JSON spec per venue drives macro-generated endpoint modules; the three DEX venues carry hand-written signing.

Runtime support is a **closed set**. `Bourse.Exchanges` and `Bourse.Registry` read `priv/specs/json/runtime_support.json` and generate exactly ten modules; constructing anything else fails immediately with `unsupported_exchange`. There is no `config :bourse, exchanges:` knob — support is not a configuration outcome.

### 🚧 The workbench boundary — read this before deciding where work goes

This repo was extracted from `../ccxt_client`, which remains the **authoring workbench**. The split is by question, not by file type:

| Question | Repo |
|---|---|
| Does the client behave correctly against a supported venue? | **here** |
| Is a supported venue's authored spec right? | **here** — the spec, its authority manifest and its reality evidence all live here |
| Does an eleventh venue get added? | **here** — `mix ccxt.promote_venue` grades its candidate against the reality manifests, and those live here. Pass the pinned CCXT reference document in from the workbench with `--reference`. |
| Did the full CCXT reference extraction shift across all 110 venues? | workbench — this repo carries a 15-venue slice and cannot answer corpus-wide questions |
| Roadmap and task scoring, and the CHANGELOG gate that reads it | workbench |
| Where does a consumer file a bug? | **here**, in `BUGS.md` — this is the only repo a consumer knows. Triage into scored tasks happens in the workbench, and writes a dated note back into the entry. |

**Consequences that bite if forgotten:**

- **Read `BUGS.md` before chasing a reported defect.** It is the inbound consumer queue, newest first, and each entry carries a `**Status:**` header — the bug in front of you may already be filed, already fixed, or already decided against. Entries are never deleted; a fixed one keeps its repro as the evidence trail.

- One test deliberately stayed in the workbench because it is corpus-wide: the zero-param JSON-body gate audit, which asserts a gate set across all 110 reference specs. The same applies to anything else that iterates every document under `priv/specs/json/output/` expecting the full set. **Do not re-add a corpus-wide audit here** — it would be answering a 110-venue question with 15 specs.
- `priv/specs/json/reference_corpus.json` honestly declares the 15 carried venues (the ten supported plus `coinmetro`, `deepcoin`, `kraken`, `weex`, `whitebit`, used as parser and unsupported-venue counter-examples). Its two SHA-256 pins still name the upstream revision the slice came from, so provenance stays verifiable. **Adding a reference venue means adding its JSON *and* the manifest entry** — `Bourse.ReferenceSlice` validates count, sort order and pins, and raises otherwise. That module lives in `test/support/`, not `lib/`: the slice is test input, so neither the client nor the Hex package can reach it.

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
- 🚨🚨 DO (behavioral default, anchored to the ACTION): **when you set out to check whether a venue "works," your FIRST call hits the LIVE testnet.** Recipe: `creds = Bourse.Credentials.new!(api_key: System.get_env("DERIBIT_TESTNET_API_KEY"), secret: ...); {:ok, ex} = Bourse.Exchange.new("deribit", credentials: creds, sandbox: true)` → then a real `Bourse.fetch_ticker/fetch_balance`. Testnet credentials for all ten venues are provisioned (below).

### Venue authority index

Any venue-source, contract-coverage or field-judgment question opens `priv/authority/<venue>/` **FIRST**. The manifest is the local provenance index, not the authority itself: when the question is discovery or freshness, check the provider's official upstream next. Manifests record URL, upstream revision, retrieval date, byte count, SHA-256 and licensing disposition.

| Venue | Official docs | Testnet/demo host | Recordings |
|---|---|---|---|
| Alpaca | [Trading API](https://docs.alpaca.markets/) | `https://paper-api.alpaca.markets` | tagged live integration |
| Binance | [Spot API](https://developers.binance.com/en/docs/products/spot) | `https://testnet.binance.vision` | `test/fixtures/responses/binance/` |
| Binance COIN-M | [COIN-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-coin-futures) | `https://demo-dapi.binance.com` | `test/fixtures/responses/binancecoinm/` |
| Binance USD-M | [USD-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures) | `https://demo-fapi.binance.com` | `test/fixtures/responses/binanceusdm/` |
| Bybit | [V5 API](https://bybit-exchange.github.io/docs/v5/intro) | `https://api-testnet.bybit.com` | `test/fixtures/responses/bybit/` |
| Deribit | [API v2](https://docs.deribit.com/) | `https://test.deribit.com` | `test/fixtures/responses/deribit/` |
| Derive | [API reference](https://docs.derive.xyz/) | `https://api-demo.lyra.finance` | `test/fixtures/responses/derive/` |
| Hyperliquid | [API reference](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api) | `https://api.hyperliquid-testnet.xyz` | `test/fixtures/responses/hyperliquid/` |
| Lighter | [API reference](https://apidocs.lighter.xyz/) | `https://testnet.zklighter.elliot.ai` | reality manifests + accepted-request goldens |
| OKX | [API v5](https://www.okx.com/docs-v5/en/) | `https://www.okx.com` + `x-simulated-trading: 1` | `test/fixtures/responses/okx/` |

Artifact **freshness**, **expressiveness** and **scope** are separate axes. A maintained Postman collection can be current but untyped; a frozen OpenAPI can be richly typed but stale. A manifest pin proves which bytes were reviewed, not that the artifact is complete.

**Missing coverage fails open.** A declared unified read without an authored parse slice can return the provider's raw transport envelope inside `{:ok, ...}`; an operation absent from the authored spec is invisible even to that guard. Completeness work must measure both boundaries.

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) and any dispatch run.

- **`mix check.dispatch`** — the dispatch-scale gate: `precommit`, `ccxt.oracle_gate`, `ccxt.check_lighter_signer`, `ccxt.claude_check`, `ccxt.agents_md --check`, the domain-boundary guard, `ex_dna --max-clones 0`, `reach.check --arch --smells --strict`. No dialyzer (a cold worktree cold-builds the PLT for minutes).
- **`mix precommit`** — lean local commit gate (format / compile --warnings-as-errors / credo --strict / doctor --raise / sobelow --skip / offline `test.json`).
- **`mix precommit.full`** — adds `deps.audit` + dialyzer (local pre-PR).
- **`mix ci`** — `check.dispatch` + `deps.audit` + dialyzer.

`--cover` is omitted from all of them; run it explicitly (`mix test.json --cover`) per the critical-rules coverage gate.

| Check | Command | Notes |
|-------|---------|-------|
| Compile | `mix compile --warnings-as-errors` | silent finish = success |
| Tests | `mix test.json --quiet` | **emits JSON by design** — parse it for real failures; the envelope is **not** a build error. Read `summary.result` / `summary.failed`. Most integration tests are excluded without `--include` tags. |
| Reality oracle | `mix ccxt.oracle_gate` | Verifies registered response recordings, accepted-request goldens and recorded exchange errors. |
| Domain boundary | `mix test.json test/bourse/domain_boundary_test.exs` | The client must never depend on the trading domain. |
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

`REF` is a pinned CCXT reference document — supply it from the workbench corpus; this repo carries only a 15-venue slice. The task creates and grades a candidate, and never adds runtime support on its own. Its evidence report uses one binary vocabulary: `verified` requires provider-owned semantics *plus* manifest-registered reality for every critical slot; everything else is `unverified`. `--check` re-derives the method inventory from the reference, byte-verified against `report.reference.sha256`.

**Do not reject a run because `mix test.json` / `mix dialyzer.json` printed JSON** — that is the intended output format, not a failure.

## Running tests

```bash
mix test.json --quiet --failed                       # default iteration
mix ccxt.oracle_gate                                 # manifest-registered reality oracle
mix test.json --quiet --include network              # integration probes (testnet env required)
mix test.json --quiet --only unified_integration     # unified integration probes
mix ccxt.classify_signing                            # signing classification report
mix ccxt.verify_live_drift                           # recordings vs live venue drift
```

> **⚠️ `mix test.json` silently excludes most integration tests by default.** A green run with no `--include` tags covers offline unit + signing tests only. Tags: `integration`, `network` (testnet REST probes), `dangerous` (raw POST/PUT/DELETE), `invalid_creds`, `capability_live`, `option_readiness`, `known_defect`, `native`.

> **⚠️ `:known_defect` quarantine tag — governed, must only shrink.** A test may carry it ONLY when its assertion states the CORRECT expectation, the product is wrong, and the tag comment names the tracking issue. Never weaken an assertion to avoid the tag, and never use it to park a red whose root cause is untracked.

**Per-exchange module split:** `raw_endpoint_probe_test.exs` and `unified_method_integration_test.exs` generate one module per exchange per auth class. `PrivateTest` / `PrivateDangerousTest` gate on a `setup_all` that raises once when creds aren't registered — a missing-creds exchange produces a single module-level flunk instead of N per-endpoint flunks. `PublicTest` / `PublicDangerousTest` always run.

**`Bourse.Testnet` is not an application child.** It is a sandbox-only ETS credential registry that consumers must not boot; `test/test_helper.exs` starts it explicitly via `start_link/1`.

### Testnet credentials

Loaded via `Bourse.Testnet.register_all_from_env/1` in `test_helper.exs`. Env convention `{EXCHANGE}[_{SANDBOX}]_TESTNET_API_KEY/_API_SECRET`, with documented exceptions below. All ten venues are provisioned.

- **Alpaca** — `ALPACA_API_KEY/SECRET`; `sandbox: true` resolves `paper-api.alpaca.markets`. Never point the lifecycle test at the live-money host.
- **Bybit** — `BYBIT_TESTNET_API_KEY/SECRET` is **READ-ONLY**: the testnet key returns business error 10024 on any signed create (region-restricted). Don't burn a probe cycle rediscovering this. **Trade evidence runs on DEMO instead**: `BYBIT_DEMO_API_KEY/SECRET`, host `https://api-demo.bybit.com` — which is **not** `sandbox: true` (that's testnet); pass `base_url:` on the call. Requests omitting `category` fail with 10032.
  - Option orders REQUIRE `orderLinkId` (10001 without it; linear doesn't). Nearest-expiry options are **USDT-settled**.
  - **A SHORT option can become unclosable — pick the instrument for the close, not the open.** Bybit enforces a mark-relative price band (`110003`), and deep-OTM/far-expiry demo books have a single ask far outside it, so a short that filled cannot be bought back at any accepted price (observed 2026-07-25). Select an instrument whose ask sits *inside* the band before selling.
  - **Option TP/SL is `POST /v5/position/trading-stop` only, and an omitted leg CLEARS the other one** under `tpslMode: "Full"` (verified live: a call carrying only `takeProfit` silently wiped the existing `stopLoss`, retCode 0). Always send both legs when amending either. `triggerPrice` on `/v5/order/create` is silently ignored for options.
  - `GET /v5/account/fee-rate` is unusable on demo (empty list with retCode 0 for options, HTTP 400 for linear) — measure fees from actual fills.
- **Deribit** — `DERIBIT_TESTNET_API_KEY/SECRET`.
- **Binance spot** — `BINANCE_TESTNET_API_KEY/SECRET`.
- **Binance USD-M / COIN-M** — the **same** `BINANCE_FUTURES_TEST_API_KEY/SECRET` pair authenticates both (`_TEST_` is a silent fallback for `_TESTNET_`). `demo-dapi.binance.com` and the legacy `testnet.binancefuture.com` are one account, not two environments. **COIN-M and USD-M are separate wallets inside that one account**, and the UI faucet credits USD-M only — a drained COIN-M wallet is re-funded through the UI. The account runs **Hedge Mode**, so orders REQUIRE an explicit `positionSide` (omitting it fails `-4061`; oversized fails `-2019` — both real pinnable business errors). `BTCUSD_PERP` is inverse, 100 USD notional per contract. `DELETE /dapi/v1/allOpenOrders` returns `code 200` even with nothing resting, so it is a safe idempotent cleanup hook.
- **OKX — international demo is canonical.** `OKX_INTL_API_KEY` / `_API_SECRET` / `_PASSPHRASE`, host `www.okx.com` + `x-simulated-trading: 1` (both supplied by `sandbox: true`). The same key on live returns 50101. Option orders at `acctLv 3` require `tdMode: "isolated"`; demo option books carry no two-sided ATM liquidity, so order-accept/cancel is the available lifecycle. **Sharp edge:** batch envelopes report `code "1", msg "All operations failed"` with the real per-order `sCode`/`sMsg` only in `data[0]`. Never use `my.okx.com` or `OKX_TESTNET_*` for new probes — historical EEA recordings remain valid provenance only.
- **Lighter** — DEX (zk perp), not an HMAC pair: `LIGHTER_TESTNET_API_KEY_INDEX` (0–255), `LIGHTER_TESTNET_ACCOUNT_INDEX`, `LIGHTER_TESTNET_API_PRIVATE_KEY` (40-byte hex). Signing is zk-Schnorr through the supervised first-party helper (`Bourse.Signing.Lighter` + `native/lighter_signer/`) — there is no in-Elixir signer. `sandbox: true` selects the testnet host **and** chain id 300 (mainnet is 304; the chain id is part of the signed payload, so a mainnet-chain signature is rejected on testnet). Private reads need an `auth_deadline` and `account_index`; writes need a caller-supplied `nonce` from `public_get_nextnonce` plus a `client_order_index`. Only `limit` orders are supported.
- **Hyperliquid** — DEX; "creds" = an EVM wallet. `HYPERLIQUID_TESTNET_API_KEY` = wallet address, `_API_SECRET` = its private key. Testnet funded via the official drip (`POST /info {"type":"claimDrip","user":…}`, unlocked by a ≥5 native-USDC mainnet Bridge2 deposit from the same address; re-claimable every 4h).
- **Derive** — DEX (Lyra v2). `DERIVE_TESTNET_API_KEY` = the **Derive smart-contract wallet** (what `X-LyraWallet` must carry, NOT the owner EOA); `DERIVE_TESTNET_API_SECRET` = a **registered Admin session key's** private key. REST base `api-demo.lyra.finance`. **Sharp edge:** Derive's edge proxy verifies auth *before* the app — the signer must equal `X-LyraWallet` or be a registered session key for it, else nginx returns HTML 403 with no JSON. The owner EOA is NOT auto-registered on UI onboarding, so a plain owner signature 403s.
  - Order placement: the order endpoints carry `body_encoding: "json"`, so dispatch JSON-encodes params *before* the signer runs — sign the eight-field tuple yourself with `sign_order(order, private_key: ..., testnet: true)` and put the `"signature"` string in params. `max_fee` is required AND has a dynamic floor (~1.5 USDC; error 11023 names the exact minimum) and is part of the signed hash, so re-sign after adjusting. The request also needs `"signer"` (the session key's EOA address), `nonce` (ms), `signature_expiry_sec`, and the trade-module data hash built from `base_asset_address`/`base_asset_sub_id`.

## Do NOT edit (generated) / DO author (frozen specs)

- `lib/bourse/exchanges/*.ex` — generated at compile time; never hand-edit (fix the generator).
- `priv/specs/json/output/authored/<venue>.json` — **the complete hand-owned runtime documents** (ten venues, schema version `3`). These you DO edit, by authoring per the loop in `docs/authored-specs.md`, then proving green with `mix ccxt.oracle_gate`.
- `priv/specs/json/output/<venue>.json` — frozen CCXT-derived **reference** siblings (the 15-venue slice), pinned by `reference_corpus.json`. Never loaded at runtime, never shipped in the Hex package; read-only authoring/test input (e.g. the test-only `markets.symbols_index` used by integration symbol selection).
- `priv/reference_cache/` — vendored market/currency slice for `Bourse.ReplayExchange`. Compatibility reference only; the one module that reads it.

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
| `Bourse.Error` | `defexception` — 17 error types covering 34 compatibility exception classes. Pattern-matchable AND raiseable. |
| `Bourse.Dispatch` | Runtime dispatcher: path interpolation, base URL resolution (4 patterns), signing, HTTP delegation. |
| `Bourse.HTTP` | Req wrapper — manual query encoding, safe retry GET/HEAD only, telemetry, circuit breaker. |
| `Bourse.RateLimiter` | Per-credential weighted GenServer, sliding window. Key `{exchange, api_key \| :public}`. |
| `Bourse.ReplayExchange` | Offline replay exchange from `priv/reference_cache/`. The **only** module reading the vendored slice. |
| `Bourse.RecordedResponseFixtures` | Capture support and path resolution for the committed reality evidence. |
| `Bourse.Application` | Supervises `Bourse.RateLimiter` + `Bourse.RateLimiter.State` + `Bourse.Signing.Lighter.Supervisor` + `Bourse.WS.Broadcast`. |

**Unified response types:** 7 original (`Ticker`, `Trade`, `Order`, `Balance`, `Market`, `OHLCV`, `Fee`), 9 tier-1 core (`OrderBook`, `Position`, `Currency`, `Transaction`, `LedgerEntry`, `FundingRate`, `DepositAddress`, `TransferEntry`, `TradingFee`), 9 tier-2 derivatives, 9 tier-3 analytics.

**Signing:** `Bourse.Signing` dispatches 8 patterns — `:hmac_sha256_query`, `:hmac_sha256_headers`, `:hmac_sha256_iso_passphrase`, `:api_key_secret_headers` (Alpaca), `:deribit`, `:hyperliquid`, `:derive`, `:lighter`. The authoritative table lives in the module's `@moduledoc`.

**WebSocket:** `Bourse.WS` wraps `ZenWebsocket.Client`. **7 of the ten venues are configured and confirmed streaming live** (binance, binanceusdm, bybit, deribit, derive, hyperliquid, okx); alpaca/binancecoinm/lighter have no WS config and `connect/3` answers `{:error, :unsupported_exchange}`. **Known gap: the private path does not authenticate** — `Bourse.WS.Adapter`, which invokes the auth patterns, has no caller from the facade. `subscribe/3` returns `:ok | {:error, term()}` and surfaces venue rejections as `{:error, {:subscription_rejected, frame}}`.

### Critical design decisions

**HTTP pipeline:** manual query encoding (signing needs raw params — don't use Req's `:params`); safe retry GET/HEAD only (never POST/PUT/DELETE — duplicate orders); per-credential rate limiting for multi-user isolation.

**Exchange struct:** config, not process — pure data, no GenServer. String keys matching the JSON spec.

**Errors:** two-tier matching — `error_codes` (exact) plus `broad_error_patterns` (substring), pre-processed at construction. `error_body_checks` for top-level sentinels; `error_code_fields` for exact-code probe order.

**Dispatch:** symbol denormalization happens in `Unified.call/5`, NOT `Dispatch.call/4` — raw callers pass through untouched. Required params always win over opts (`Map.put_new` prevents silent override in trading calls).

**Authored `path_params` descriptors are `%{"name", "source"}` and `source` is ALWAYS `"params"`** — verified 1668/1668 across the catalog. `interpolate_path/3` resolves from the params map by `"name"` and deliberately ignores `source`. This is a relied-on invariant: if an authored spec ever sets a path-param source to anything else, resolving from `params` silently reads the wrong place. The fix is not to pre-build unused branches but to make the day-it-changes failure LOUD — `path_param_name/1` should match `%{"source" => "params"}` and let any other shape hit a raising clause.

**Durable kernel:** when data is finite, verifiable, and fails silently when wrong, **author it explicitly — don't infer it at runtime.** `HmacRecipe` stays as the deterministic recipe *executor* (mechanism, not judgment); author recipes into its shape rather than rebuild a signer.

## The trading domain layer

`Bourse.OptionProposal`, `Bourse.OptionReadiness`, `Bourse.OptionSaga`, `Bourse.PortfolioRisk` live here but are **not part of the client's surface**. `mix.exs` keeps them out of the Hex package, and `test/bourse/domain_boundary_test.exs` (wired into `check.dispatch`) asserts the dependency stays one-directional: **the domain may call the client, never the reverse.**

That guard is why the layer can stay. It was introduced while the invariant already held, so it costs no refactor — and as long as it is green, moving the domain into its own repo remains a file move rather than a refactor. **A single inbound edge turns it into one**, so don't "temporarily" reach into the domain from client code.

## Git commit configuration

Conventional commits: `<type>(<scope>): <description>`. Types: feat, fix, docs, style, refactor, test, chore. Title-only; bodies only when asked. No `Co-Authored-By` footers.
