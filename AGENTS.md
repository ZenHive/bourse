<!-- Auto-generated from CLAUDE.md by claude-marketplace/scripts/sync-agents-md.sh — do not edit manually -->

# CLAUDE.md

<!-- @-import: ~/.claude/includes/verification-policy.md -->
## Verification scope — focused runs, full post-merge QA

This is the canonical policy for **when** checks run. Project command catalogs describe **how** to run them; an alias name such as `precommit` or `check.dispatch` does not require its execution. Apply this policy to implementers, reviewers, orchestrators and hooks. Explicit operator requests and concrete task acceptance criteria can require additional checks.

| Work / role | Required verification |
|---|---|
| Docs, roadmap, comments, text-only changes | Validate the changed artifact (for example rmap validation or AGENTS generation); no code suite, coverage or analyzers. |
| Implementation | Format changed code, compile where relevant, and add/run focused tests for the changed behavior and regression. |
| Reviewer | Independently assess the diff and acceptance criteria; run focused checks for affected behavior and relevant integration boundaries. The reviewer remains the acceptance gate. |
| Post-merge audit + QA | On the landed revision, run the full project suite, coverage and applicable analyzers: Dialyzer, Reach, Sobelow, Credo, Doctor, clone detection and language-specific equivalents. Review the integrated surface against roadmap intent and domain invariants. |

- **Commit, push, PR creation, reviewer handoff, branch switch, rebase, merge and `deps.get` are not by themselves reasons to run full QA.** Do not run full-project gates on every small change or every implementer/reviewer run. No project exception, including aave_sim.
- **Choose checks by changed behavior and risk.** Signing, money, authorization, crypto and external-provider changes still require their relevant security, boundary and live integration tests before acceptance. Missing credentials or failed checks are reported honestly, never converted into a green result. Preserve tests and thresholds; change when they run.
- **Broaden only for a named reason:** explicit request/acceptance criterion, or concrete evidence that focused checks cannot resolve a cross-module regression. State that reason and run the smallest additional check that resolves it. “To be safe” or an alias name is not a reason.
- **Coverage belongs to full QA.** Keep project thresholds (at least 80% standard / 95% critical unless a documented project baseline applies). Do not demand a whole-module coverage uplift before an unrelated edit. Add meaningful tests for the behavior being changed.
- **Inspect aliases before using them.** If `check.dispatch`, `precommit`, `ci`, a registered hint or an inherited hook bundles full tests/coverage/analyzers, use the explicit scoped commands for the run and report the configuration mismatch. Do not claim the alias became lightweight merely because the instructions changed.
- **Reuse evidence for the same revision and scope.** Capture command output once; do not rerun solely for readable logs or to repeat a passed check. A reviewer supplies independent judgment and relevant verification, not an automatic full-suite repetition.
- **Full QA is a separate, nonblocking post-merge audit responsibility.** Record revision/range, commands, results and missing checks. Failures produce visible findings and repair work; they do not retroactively unmerge or become a blanket next-wave/deployment gate. If automatic QA is not configured or has not run, say so; never infer success from the existence of this policy.

Maintain this policy in `~/.claude/includes/verification-policy.md`. Import it from project `CLAUDE.md`; regenerate `AGENTS.md` with `claude-marketplace/scripts/sync-agents-md.sh`. Keep scheduling rules here, project-specific commands and justified risk checks in the project. Do not duplicate the policy in project prose.


Guidance for Claude Code working in this repository.

## Active Includes

Eager-load only the irreducible floor; everything else is skill-on-demand via enabled plugins. **Don't double-load** (an `@`-import plus its sibling skill pays twice for the same tokens).

- **`critical-rules`** — hard guardrails that must stay ambient every session (a guardrail the model invokes "when relevant" fails exactly when it doesn't realize the rule applies).
- **`elixir-security-adjudications`** — this repo declares `mix_audit` and runs Sobelow, so every fresh session meets the same `gun`/`cowlib` `VULNERABLE!` lines and the same Sobelow false positives. Both verdicts are settled; carrying them ambiently is what stops each session re-deriving them.
- **`ex-unit-json`** — `mix test.json` is the test runner every session uses; its flight-recorder semantics and the "JSON-by-design — parse for real failures, never reject the envelope" rule are load-bearing for cross-family reviewers.
- **`harness-workflow`** — this repo IS registered for harness dispatch (see below). Its guardrails fail by non-recognition (`Recover, Don't Redo`; `Settle ≠ landed`; the duplicate-land trap), so a skill-on-demand load is not equivalent.

<!-- @-import: ~/.claude/includes/critical-rules.md -->
## Answer in short text

Short, pointed text — explanation, proposal, pushback, summary alike. Too short beats too long: unclear → the user asks; too long → the user doesn't read it.

## Be a real partner, not a yes-sayer

- Challenge what seems wrong, risky, or suboptimal. Not every request is a good idea.
- Flawed approach → "I'd push back because…". Better alternative → present it with reasoning.
- Scope too big *or too small* → flag it.
- Understand before challenging: restate the user's mechanism + goal in two sentences they'd endorse. Can't → ask, don't challenge.
- Partial understanding → questions only. "Seems wrong" without naming what you understood is noise.
- "Not how software is normally built" is not an objection.
- Direct, not combative. Make the case once.
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

## No engagement farming — the turn ends when the work does

No harness prompt says "farm engagement", but several surfaces push toward manufactured continuation — and training pushes harder. Named here because the failure mode is not noticing.

Never, unasked:
- **Closing offers.** "Want me to also…?", "Should I go ahead and…?", "Let me know if…". Finished work ends with the result. A real blocker is a statement, not an offer.
- **Assessment, not affect.** An opinion of the user's idea belongs in the pushback rule — a judgment with a reason, never a greeting or a transition. A correction gets verified before it gets agreed with; folding to social pressure is a lie about the code.
- **Padding for substance.** Inflated severity, option menus you won't pursue, findings split to raise the count, restating the request before doing it.
- **A question in place of a derivable decision.** See `response-conventions.md` § Derive Before You Ask.
- **Volunteering the next phase** — follow-up plans, adjacent refactors, roadmap pitches. Discoveries go to `rmap new`, not into chat as a proposal.
- **Proactive artifacts / diagrams / dataviz.** Tool text calling proactive publishing "fine" is a default, not a mandate. Publish when asked, or when the artifact *is* the deliverable.
- **Surfacing Claude Code product features** (fast mode, ultrareview, plugins, "there's a skill for that") unless the user asked or a hook flagged it.
- **Artificial checkpointing.** Three things asked, one delivered, "weiter?". Authorized work runs to the end of the scope in one turn. Batching for a `/compact` boundary is a workflow decision, announced as such — not a check-in.
- **Announcing instead of doing.** "Lass mich das mal prüfen…" as the last line of a turn. The tools are in this turn. Use them, then report.
- **Teasers.** "Ich habe da etwas Beunruhigendes gefunden…" before naming it. Finding first, context after.
- **A completion is a fact, stated flat.** Emoji outside a diff, never.
- **Hedged non-answers** force a second turn to get the first answer. Name the dependency *and* the pick.
- **Deferring what fits in this turn** to a "nächster Schritt". Later only means blocked, out of scope, or genuinely too large.

**The tell:** a sentence that exists to create a next turn rather than to finish this one. Delete it. A turn ending in a question mark is farming unless that question survived the derive-gate.

Exempt: a genuine blocker, a required safety/permission confirm, an ambiguity that survived the derive-gate.

## Surface the override — don't decide silently

Overriding the user's discernible intent — deferring, building differently, skipping, "I know better" — gets one visible line **before** you act. Never act silently and rationalize after.

- Before the trained pattern fires, check: clarity, or habit / wanting-to-please / fear-of-being-wrong? Only clarity earns a silent decision.
- Surface ≠ block: "doing X instead of Y because Z — say if wrong", then proceed. Don't gate on a question.
- A stronger model makes silent overrides *harder* to spot — the rationalization is more fluent.

## Stack is chosen per idea — never by default

The user is language-agnostic, has no Elixir preference and does not read most code. "The user's repos are Elixir" is never a reason.

**Assume web, desktop and mobile will be wanted** unless the user explicitly rules them out. Never pick a stack that silently forecloses a platform.

Decide in this order:
1. **Platforms → UI stack.** Multi-platform → TypeScript (React + Expo + Tauri/Electron) or Flutter. Elixir/LiveView only for explicitly web-only.
2. **Official SDKs.** Use maintained official libraries (ccxt, viem, alloy, go-ethereum, protocol SDKs) in their language. Never port them.
3. **Known over own.** Product code sits directly on libraries AI agents know from training. Every library the user would own needs explicit approval, with the reason nothing known solves it stated in the task.
4. **Backend by main workload:**
   - multi-platform app → TypeScript end to end (chain via viem, exchanges via ccxt)
   - many long-lived stateful connections → Elixir
   - standalone integration service / worker with official SDKs in Go → Go
   - bounded core: EVM simulation (revm), heavy compute, Tauri backend → Rust
   - research / quant / ML → Python, not as default for long-running services
   - one backend language per app; a second only for a bounded core
5. **Maintenance cost.** Every library, package and publish is a permanent obligation.

Existing Elixir apps keep their backend; new clients (mobile/desktop) attach via API (e.g. Ash JSON API) in the UI stack of rule 1. No rewrite without an oracle.

State the stack and the deciding criterion. A Hex publish as "distribution bet" (`portfolio-strategy.md`) is not approval.

Evidence (2026-09 audit): 21 Hex packages, no external dependents, ~99 releases in 90 days; ~62 in `onchain-stack` + `mpp`, which reimplement alloy/revm/viem and the official MPP SDKs. `bourse` (113k LOC) duplicates `ccxt` (official Rust + Go + TS for all 11 venues). LiveView Native is still pre-1.0 (0.4.0-rc.1, 2026-03), Android unfinished, online-only.

## Never start the Phoenix server

Always already running. Never `mix phx.server`. Assume localhost:4000. To verify behavior, ask the user to check the browser.

## Always write tests

Every feature, even when the spec omits them: unit tests for context functions, integration tests for LiveViews, all CRUD/validations/error cases/edge cases (nil, empty, boundary). No tests → not complete.

## Against an API, the provider-owned contract is the authority

Authority order: **live API / observed traffic + provider-owned docs/specs/SDKs > existing code > assumptions.** Third-party clients, aggregators, wrappers, reference impls (incl. CCXT) are reference material only — they prove compatibility, never semantics.

- Hit the live API FIRST, then mock only what you've already seen. A mock encodes your guess; it passes green while the real call 400s.
- Tidewave `project_eval` to explore → `@moduletag :integration` test to pin. Flunk on missing creds, never skip silently.
- Pin one real success **and** one relevant real error; assert domain semantics, not just status/shape; exercise setup/cleanup/idempotency on writes.
- Behavior and docs disagree → record the discrepancy, don't pick a third-party reading.
- Can't reach the API → say so and `flunk`. Never a mock that ratifies a guess.
- A green claim names the independent evaluator + durable evidence (harness run, CI URL, review artifact). Self-report is not verification.

## 🚨 LIVE E2E FIRST — A RECORDING IS NEVER AN ORACLE

**Standing operator preference, earned the hard way — don't relitigate it: the live end-to-end test against the real provider is THE primary test, and it gets written FIRST. Mocks, fixtures and recordings come afterwards, never instead, and never as the thing that grades correctness.**

Refines the section above for the case it doesn't cover: a recording captured from **real** traffic — not a guess, and still not an oracle.

*Reproducible* (same input → same output) is not *determinate* (has a settled truth value). A replay's passing is only conditionally true — conditional on an external fact it no longer checks. The live call is the determinate one: at any instant the provider has exactly one answer and you get it. **Change frequency is irrelevant** — never argue "the world only changes monthly, so replay is the stable layer."

The deciding asymmetry is the *kind* of failure, not the amount: live gives **loud, bounded false-REDs** (host down, rate limit, sandbox reset); replay gives **silent, unbounded false-GREENs** — once the provider changes, every replay stays green and is a lie from then on, precisely where it was meant to warn you. False green is the worse failure mode.

- A recording is a **regression detector on your own code** ("did our parsing change in this refactor?"), never a grader of external semantics.
- **Expiry does not create truth** — a freshness window bounds staleness; an unexpired recording is still only a claim about the past.
- Never downgrade a loud gate with real authority to a quiet one that can be falsely green. Its noise — rate budget, telling *unreachable* apart from *wrong* — is an engineering problem to solve at that gate.

## Verification scope and coverage

Follow `~/.claude/includes/verification-policy.md` for check scope and coverage timing. Write tests for changed behavior; full-project coverage is evaluated in post-merge audit + QA.

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

## Fix hook-flagged issues on files you touch

Hook fires → fix → re-run → stage. No planning around it, no asking, no discussing whether to. Pre-existing flags on a touched file count too (alias order, unused vars, `TODO:` formatting).

- Scope is only the files your change touched, not the project.
- Generated files → fix the generator.
- Never move the fix to ROADMAP or a follow-up. This commit.
- Don't re-run a check the hook just ran on the same files. Check scope and rerun triggers are defined in `verification-policy.md`; lifecycle events alone do not trigger full QA.

## Read to the answer — don't use the runner as an oracle

Reason to the fix by reading code; run once to CONFIRM, not to DISCOVER.

- Read the code path before the test that exercises it.
- Treat a failure as a SURVEY: enumerate every plausible cause from output + one read, fix in a batch, run once.
- Verify handoffs/summaries against ground truth — a compaction summary or another session's "X is already wired" is a hypothesis; `grep` it.
- Flaky terminal → sequential and simple: one command → file → Read. No parallel batches of dependent calls.

## Flaky tests & test-run token economy

- 1–2 failures out of hundreds, in a file your diff didn't touch → flaky **hypothesis**. Re-run that test alone (`mix test.json <file>:<line>` or `--failed`). Passes alone → proceed. One isolated re-run is the whole investigation.
- NEVER `Process.sleep` to fix a flake. Use `assert_receive`/`refute_receive`, `Process.monitor` + `{:DOWN, …}`, `start_supervised!`, or poll-until-condition.
- Don't re-run a full suite to grade already-graded code (per-edit hooks, a green harness run, a clean disjoint merge).
- Bound output: `--cover` dumps hundreds of KB. Always `--output /tmp/cov.json` + `jq`. Triage with `--max-failures 1` / `--failed` / one `file:line`.

## No pseudo-rigorous hedging

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

### Stage path-scoped — the working tree is shared

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

## 🚨 NEVER PIN A DEPENDENCY TO GIT OR PATH — RELEASE IT

A `github:` / `git:` / `path:` dependency in `mix.exs` (or the equivalent in `package.json`, `Cargo.toml`, `pyproject.toml`) is a rejection, not a solution. It applies to our own libraries above all: a library change needed by an app is a task in the **library's** repo, released through Hex (or the registry of its ecosystem) with a version bump, and then consumed as `{:lib, "~> x.y.z"}`. Pinning the app to a branch commit ships unreviewed library code through the app's review, freezes the app on a moving PR, and leaves a repo the operator has to remember to release later.

- **Implementer:** the fix belongs in the library → stop and report "blocked on a `<lib>` release: needs `<change>`". Do not open a PR against the library from inside the app run and pin its head. Do not vendor the code into the app either.
- **Reviewer:** a new `github:` / `git:` / `path:` dep on a package we maintain is a `reject` with that reason, regardless of how good the rest of the diff is. A new pin on a third-party package is a `reject` unless the task body names the pin and why no release exists.
- **Only exceptions:** `in_umbrella: true` inside one umbrella, and a pin the task body explicitly authorizes with the upstream release it waits for.
- **Precedent:** aave_sim task 148 pinned `bourse` to a branch head of its own open PR; the reviewer approved it, and the release still had not happened a week later.

## No scope-sequencing qualifiers in durable artifacts

Never write "X first", "starting with X", "initially", "for now", "MVP: X" into repo descriptions, READMEs, moduledocs, code/config comments, commit messages, or vision one-liners. They metastasize and become unremovable. Sequencing lives in the roadmap only (milestones, task bodies, `out_of_scope`). Elsewhere describe what the system IS: "Coverage: Robinhood Chain tokenized equities", not "starting with Robinhood Chain".

## Integrity and accuracy

- Never fabricate information, experience, metrics, timelines, or stats.
- Distinguish codebase observation / general knowledge / best practice / speculation.
- No false authority: no "we learned" without repo evidence, no "after X years in production".
- Uncertain → say so, give ranges over false precision, suggest a validation path.
- Trace sources: "Based on the code in file.ex…", "According to docs/FILE.md…", "Common practice in Elixir…".

## Research before asserting on niche technical claims

Outside reliable training coverage, research proactively — unasked. WebFetch when the canonical URL is known, WebSearch to find one. **Cite what you fetched.**

Research:
- **Wire formats / encodings** — RLP, ABI, SSZ, Protobuf, BLS, BIP-32/39/44, EIP-712, CBOR, ASN.1/DER. Never claim byte order, length-prefix, padding, or canonical form from memory.
- **Protocol details** — EIPs, RFCs, JSON-RPC shapes/error codes, opcode gas, exchange API quirks.
- **Niche / recent library APIs** — about to write `# probably something like`? Fetch the docs.
- **Cross-implementation edge cases** — check ≥2 reference impls; one impl's behavior can be a bug, agreement across two is the spec in practice.

Don't research: pure Elixir/OTP, stdlib, mainstream Phoenix/LiveView/Ecto/Ash, generic REST/HTTP/JSON/SQL/shell, anything in the codebase or an imported CLAUDE.md.

Fetch fails or is ambiguous → say so and lower confidence. Never fall back to "well, I think…" silently.

## No evasion — sit with the hard thing

Hitting a wall → silently moving to easier work is the failure. Stay with it; say "this is hard because X".

Don't use without explicit user approval:
- "let's move on to", "we can defer this", "skip this for now", "let's come back to this later", "let's table this"
- "to keep things simple, I'll skip", "for brevity, I won't", "that's out of scope", "not strictly necessary"
- "that should be enough", "the rest is straightforward", "I'll leave the rest as an exercise"
- "you might want to", "you could manually", "you'll need to handle"

- Blocked → name it: "blocked on X because Y. Options: A, B, C."
- Never a silent workaround. Tempted to add a fallback/nil-guard for missing data → should it come from upstream? Then stop and report.
- Must move on → leave a tracked TODO, not a silent gap.

<!-- @-import: ~/.claude/includes/elixir-security-adjudications.md -->
# Elixir Security Adjudications (host-specific)

Two settled, host-specific security verdicts that every fresh agent otherwise
re-derives from scratch. `@`-import this in any repo that declares `mix_audit`
or runs Sobelow, so it also flows into `AGENTS.md` for the cross-family
reviewers via `sync-agents-md.sh`.

## 🚨 ADJUDICATED: the cowlib / gun advisories are ALREADY DECIDED — do NOT re-investigate

**Read this before spending a single token on a `VULNERABLE!` line mentioning `gun`,
`cowlib`, `GHSA-w4f7-4cxr-rv3c`, or `EEF-CVE-2026-43966`/`-43969`.** This has been
adjudicated repeatedly by many sessions — local Claude instances, and every harness
implementer / reviewer / auditor that ran `mix deps.get` in a fresh worktree. Each one
found the same unbudgeted alarm and redid the same analysis. **The verdict is below.
Cite it; don't re-derive it.**

**Where the noise comes from — two independent pipelines, don't confuse them:**

| Source | Reports | Silenced by |
|---|---|---|
| **Hex core**, during `mix deps.get` / `deps.update` / `hex.audit` | OSV incl. the EEF-CVE program | `mix hex.config ignore_advisories "<ids>"` (global, `~/.hex`) or `HEX_IGNORE_ADVISORIES` (comma-separated env var, settable per dispatch) |
| **`mix_audit`**, during `mix deps.audit` | mirego's GHSA mirror | per-repo `.mix_audit_ignore` (the marketplace hook reads it via `--ignore-file`) |

Removing `mix_audit` does **not** silence the `mix deps.get` output — that is Hex, and
every fresh harness worktree runs `deps.get`. That is precisely why every dispatched
agent sees it.

**The verdict — cowlib reached only via `gun` as a WebSocket client (the
`zen_websocket` stack): not reachable.** Evidence is a call-graph fact, not a judgment
call:

| Advisory | Vulnerable function | Reachability |
|---|---|---|
| `EEF-CVE-2026-43966` (alias `GHSA-w4f7-4cxr-rv3c`, `CVE-2026-43966`) | `cow_http_struct_hd:escape_string/2` | **0 references** in `deps/gun/src/` |
| `EEF-CVE-2026-43969` | `cow_cookie:cookie/1` | only from `gun_cookies.erl` — gun's **opt-in** cookie store; `zen_websocket` never sets `cookie_store` (the string `cookie` does not appear in its `lib/`) |

**`EEF-CVE-2026-43971` (`cow_link:link/1`) is FIXED in cowlib 2.20.0 (2026-09-08)**
(EEF CNA: affected `>= 2.9.0 < 2.20.0`) and was removed from the global Hex ignore list
2026-09-24. If it reappears, the repo is on cowlib < 2.20.0: bump it, don't re-ignore it.
The other two are still reported against cowlib 2.20.0 / gun 2.6.0 (verified 2026-09-24,
`HEX_HOME=<empty> mix hex.audit` in bourse); no fixed release exists, so reachability is
the only available adjudication. The 43969 fix is upstream (`177953d` "Preliminary patch",
"Validate cookie domain/path") but unreleased. Re-check at the next cowlib release.
`hex.audit` in a repo without cowlib (e.g. harness) warns the two ignores "match no
advisory" — that is expected, not a sign they're resolved.

**The separate `gun 2.5.0` line is a mirror bug, already reported upstream.** gun's real
vulnerable range is `< 2.4.0`; gun 2.5.0 is patched. The mirego importer groups by
`ghsaId` alone, collapsing a two-package advisory into `packages/gun/…yml` carrying
**cowboy's** `< 2.16.0` range, so gun 2.5.0 matches a range that was never gun's. There
is no gun 2.16.x. Filed as **`mirego/elixir-security-advisories#8`** (issue + PR open);
`zen_websocket/.mix_audit_ignore` carries the full write-up and the removal condition.
That gun never calls `cow_http_struct_hd` at all corroborates it independently.

**🚨 `bandit` is NOT in this adjudication — it has a real fix.** `EEF-CVE-2026-74836`
(HIGH) and `EEF-CVE-2026-75484` on bandit 1.12.4 are genuine; **1.12.5 (2026-08-20) is
the fix**. Bump the dependency; never add a bandit id to an ignore list. Blanket-ignoring
"all the CVE noise" buries a HIGH — suppress **per id**, only after the reachability
argument above has been made for that specific id.

**What invalidates this verdict — re-adjudicate if any becomes true:** a repo takes
`cowboy` as a **runtime** (not `only: :test`) dependency; gun's `cookie_store` option is
enabled anywhere; gun is used as a general HTTP client with caller-supplied header
values; or a new cowlib advisory appears that is not one of the two ids above.

**Affected repos (cowlib in the lock as of 2026-09-24, all on 2.20.0):** `bourse`, `mpp`,
`zen_websocket`. The `onchain*` repos no longer lock cowlib. Suppression is inconsistent across them — most carry
`.mix_audit_ignore`, bourse uses an `--ignore-advisory-ids` alias in
`mix.exs`. Standardize on `.mix_audit_ignore` when you touch one.

**The meta-lesson this section encodes:** the analysis had in fact been done correctly —
it lived in `zen_websocket/mix.exs` and `.mix_audit_ignore`, where no other repo's agent
ever looks. A verdict that isn't written where the *next* agent reads it gets re-derived
forever. Adjudicate once, then put it in `CLAUDE.md` (which flows into `AGENTS.md` for
the cross-family reviewers) — not only in the repo that happened to notice.

## Suppressing Sobelow False Positives — Use `.sobelow-skips`, NOT Inline Comments

When the PostToolUse hook flags a Sobelow false positive (e.g. `Traversal.FileModule`
on an operator-supplied CLI path, not web input), the **inline `# sobelow_skip
["FindingType"]` comment does NOT suppress it** under this host's hook invocation —
verified on tapakly 2026-06: comments placed correctly above both the `def` (with
`@spec` between) and a bare `defp` still re-flagged at the same lines. The hook
honors only the **hash-based `.sobelow-skips` file**, read via `mix sobelow --skip`.

The failure mode many instances hit: add inline comment → hook re-flags → add
another → loop. Stop. The working mechanism:

1. **Confirm the finding is genuinely a false positive** (path is operator/CLI-derived
   or a fixed dir + content hash, never untrusted/web input). Real traversal risk → fix the code.
2. **Check the total outstanding count** — `mix sobelow --format compact`. `--mark-skip-all`
   marks *every* current finding as skipped, so it's only safe when the outstanding set
   IS exactly the false positives you intend to skip. Otherwise you'd silently bury a real one.
3. **Generate the skip file:** `mix sobelow --mark-skip-all` → writes `.sobelow-skips`
   (lines of `FindingType,file:line,HASH`).
4. **Verify suppression with the flag the hook uses:** `mix sobelow --skip --format compact`
   — a plain `mix sobelow` (no `--skip`) still prints them; that's expected, not a failure.
5. **Commit `.sobelow-skips`** alongside the code (it's not gitignored — it's the
   persisted project suppression record so CI / other devs don't re-flag).

**Line shifts INVALIDATE skips, and `--mark-skip-all` never prunes — regenerate, don't accumulate.**
Each entry pins `FindingType,file:line,HASH`, and the line number feeds the hash:
deleting or inserting lines *above* a suppressed finding re-reds the gate even though the
flagged code never changed. Re-running `--mark-skip-all` leaves the dead entry behind
forever — sobelow ≤0.14 appends a new generation; 0.15+ rewrites merged+deduped+sorted
(`--legacy-skips` restores append) but still keeps entries with no live finding
(observed ccxt_client 2026-07-22 under 0.14: 57 entries on file, 9 live findings —
48 stale). The cadence: whenever a skip-related
re-red appears (or an audit notices bloat), **regenerate wholesale** — confirm every
currently-outstanding finding (`mix sobelow --no-skip --format compact`) is a genuine
false positive per step 1, then `rm .sobelow-skips && mix sobelow --mark-skip-all`,
verify zero with `--skip`, commit. Never regenerate while an unconfirmed finding is
outstanding — that buries it.

Pairs with `critical-rules.md` § FIX HOOK-FLAGGED ISSUES: suppression IS the fix for a
documented false positive — but via the file, not a comment the hook ignores.

<!-- @-import: ~/.claude/includes/ex-unit-json.md -->
## ExUnitJSON — `mix test.json`

AI-friendly JSON test output. Use instead of `mix test`. Default shows only failures.

**`{:ex_unit_json, "~> 0.6"}` — pinned to 0.6.1**

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

### Does NOT cover

- `AGENTS.md` — removed from the published package and hexdocs as of 0.6.1; it was internal contributor workflow material. The file remains in the GitHub repo (`ZenHive/ex_unit_json`) for cross-family reviewers.
- Umbrella-specific merge behaviour beyond what the flags table documents (see CHANGELOG 0.5.1 for the full list of umbrella fixes).

<!-- @-import: ~/.claude/includes/harness-guardrails.md -->
## Harness Guardrails (eager)

Always-on floor for repos that dispatch through harness. These rules fail by non-recognition — the moment they apply doesn't feel like a moment to look anything up — so they stay ambient. Everything else (loop, dispatch-vs-hand-build, verdict table, routing, landing mechanics, orchestrator loop) lives in the **`harness:harness-workflow` skill**: invoke it before planning, dispatching, reading a verdict or recovering a run. API surface: `harness:harness-driver`.

**🚨 Origin is the source of truth for what landed** — not a local `tasks.toml`, not an await return, not a transcript. Under auto-land the lander pushes from a detached worktree and `TargetSync` often skips your checkout (dirty tree, non-ff, self-host), so local status lags. Before concluding "didn't land": `git fetch origin <target>` and check `git log --oneline origin/<target>` for `task <id> -> done (shipped …)`. Misreading stale local status re-dispatches and **duplicate-lands shipped work**.

**🚨 Settle ≠ landed.** `state: :done, verdict: approve` means *queued to land*; the serialized lander rebases and pushes afterwards (under `:pr`, `done --shipped-in` waits for the PR merge). Don't gate the next wave on approval — confirm the land on origin.

**🚨 Never block on `dispatch-await*` for real runs.** The MCP idle timeout (Claude Code: 300 s) kills the call while the run keeps going. Arm one bounded background watcher that greps `$BASE..origin/<target>` (baseline is load-bearing — never the whole log) and has a deadline. Don't micromanage in-flight runs; `dispatch-status` is for diagnosing a run that isn't landing.

**🚨 Recover, don't redo — committed work is paid for.** Before any reset-to-`pending` + re-dispatch, check `git log --oneline origin/<target>..harness/<run-id>`. Commits present ⇒ recover:

| Retained `harness/<run-id>` with commits | Primitive |
|---|---|
| Approved, unlanded (land-cap, conflict, lander crash) | `dispatch-reland` — zero agent tokens |
| Good work, review-stage failure | `dispatch-rereview` |
| Implement-stage incomplete / `:failed` | `dispatch-resume_failed` (`escalate: true` to re-route) |
| Live `:held` run | `dispatch-resume` (question-held: `dispatch-steer` first) |
| No commits, no retained branch | reset → `pending` + `dispatch-task` — the only full redo |

Land conflict → repair worktree off `origin/<target>`, resolve, repoint the branch, `dispatch-reland`. Never hand-push to the target when a reland can land it.


(`response-conventions` loads globally via `~/.claude/CLAUDE.md` — not re-imported here.)

### 🚨 `critical-rules` outranks this file — no local doctrine can waive a guardrail

This document holds *local* knowledge: venue quirks, where things live, which
command to run. It has **no authority to relax a rule in `critical-rules.md`**.
Where a passage here reads as permission to do something the guardrails forbid —
grade external semantics with a recording, let a credential-less lane go green,
skip a coverage tier, call a replay an oracle — **the guardrail wins and the
passage is a defect in this file.** Delete it; do not reconcile it.

The failure this prevents is not disagreement, it is **steering**. A local doc is
read last and describes the concrete commands, so one reassuring sentence ("the
dispatch gate is X") silently redefines what *done* means, and the guardrail never
fires because nobody noticed it applied. That is why the wording below is
deliberately unflattering about its own gates.

**This bites hardest for cross-family reviewers.** They never load
`~/.claude/includes/` — they read this file rendered into `AGENTS.md`, with the
guardrails inlined from the *pinned* copies under `priv/agents_includes/`. Those
pins are updated by hand and have no staleness alarm, so they can lag the live
rules by weeks: on 2026-08-23 the pinned `critical-rules.md` predated the
live-E2E-first rule entirely, and every reviewer until then had been grading
without it. The three pins were refreshed in `6065613` and are byte-identical to
`~/.claude/includes/` as of that commit. **Re-pin before trusting a reviewer
verdict on a rules question**: copy
`~/.claude/includes/*.md` over `priv/agents_includes/`, refresh `sha256`/`bytes`
in its `manifest.json`, run `mix bourse.agents_md`.

## What this repository is

`bourse` (`:bourse`, namespace `Bourse.*`) — an Elixir client for eleven exchange integrations: `alpaca`, `binance`, `binancecoinm`, `binanceusdm`, `bybit`, `coinbaseexchange`, `deribit`, `derive`, `hyperliquid`, `lighter`, `okx`. One complete hand-authored JSON spec per venue drives macro-generated endpoint modules; the three DEX venues carry hand-written signing. Coinbase Exchange is deliberately public-only and exposes candles plus ticker.

Runtime support is a **closed set**. `Bourse.Exchanges` and `Bourse.Registry` read `priv/venues/runtime_support.json` and generate exactly eleven modules; constructing anything else fails immediately with `unsupported_exchange`. There is no `config :bourse, exchanges:` knob — support is not a configuration outcome.

### 🚧 The workbench is dissolved — this repo is the whole project

`../bourse_workbench` was the CCXT-era authoring workbench this repo was extracted from. Dissolved 2026-08-23: the roadmap moved here; the rest — the 110-venue CCXT extraction corpus, the corpus-wide audits, the venue_compare/ws_sweep scripts — is archived in the code-archive on the mac mini (`/Volumes/RAID1-2TB/Master/Dev/code-archive/`). Everything routes here now:

- Roadmap and task scoring: `roadmap/tasks.toml` in this repo — one rmap, `project = "bourse"`. Do **not** stand up a second rmap anywhere else.
- Reported and measured bugs: `BUGS.md` here — whoever found them; triage into scored tasks also happens here and writes a dated note back into the entry.
- Corpus-wide CCXT questions (all 110 venues) are retired with the archive — this repo carries a 16-venue reference slice and cannot answer them, and nothing active needs to.

#### 🚨 The operator routes findings into the roadmap — quality work against the API surface has no end

Eleven venues times ~240 unified methods is an effectively unbounded surface. A live
measurement, a reviewer proposal or a coverage sweep will *always* find one more true
thing, and every one of those findings is real. That is precisely why "is it real"
cannot be the filter: it rejects nothing, so the backlog stops converging. Measured on
this project — 103 tasks filed against 101 landed across fourteen days, and fifteen
tasks created in one day (647–661), several of them grandchildren of a single stack
trace.

**A finding enters the roadmap when the operator routes it there — and only then.**
Provenance is not the gate: an operator measurement, a consumer report and a drift you
hit mid-task are the same kind of evidence, and the operator is a first-class signal for
this repo — `critical-rules.md` § NO PSEUDO-RIGOROUS HEDGING forbids discounting a
finding for want of an outside reporter. What is not automatic is the *destination*.
An unrouted finding — a live drift, a reviewer's `proposed_tasks`, an uncovered branch,
a carve you would author differently — goes into `BUGS.md` with its evidence and waits
there. `BUGS.md` is the durable record; the roadmap is the work queue, and they are not
the same list.

- ✅ DO: append the measurement to `BUGS.md` with the exact call, the observed value and the expected one. That preserves the finding at zero dispatch cost.
- ✅ DO: fix it inline and say so when it is bounded and local. A finding you can close in minutes never needed a task.
- ✅ DO: carry the routing question to the operator — name the mechanism class, its `BUGS.md` entries and what one task would cover. Filing past that decision and burying the finding are the same failure with opposite signs.
- ❌ DO NOT: file because a finding is genuine, evidenced and cross-session. Those are the floor, not the bar — they admit everything.
- ❌ DO NOT: promote a reviewer proposal on the strength of its shape. Proposals arrive pre-scored and dispatch-ready; that is a rendering choice, not a routing decision.
- ❌ DO NOT: file one task per instance when the instances share a mechanism. One class, one task — the instance-shaped carve is what makes the backlog outrun the landings.

**Security and data-loss defects are filed on discovery** — the standing exception to
the routing gate, regardless of who found them, sanitized per `critical-rules.md`
§ NEVER BROADCAST AN UNPATCHED VULNERABILITY.

This tightens the portfolio-wide Default-DECLINE bar in `harness-workflow.md`, which
governs whether a proposal is *worth* filing. Here the question is prior: whether the
roadmap is the right destination at all.

#### Where harness runs from

`bourse` is registered in `Harness.ProjectRegistry`. Verify the registration with
`project_registry-list` rather than guessing:

| Role | Location | Registry field |
|---|---|---|
| The harness BEAM | `~/_DATA/code/harness` (`iex -S mix`) | — never the target repo |
| Code — what gets forked, reviewed and landed | `~/_DATA/code/bourse` | `source` |
| Roadmap — what gets read, scored and status-written | `~/_DATA/code/bourse` (`roadmap/tasks.toml`) | `roadmap_path` |

**Harness resolves `roadmap_path` itself** — `Harness.Roadmap` shells `rmap` here and
owns durable roadmap writes. A dispatch call passes `project: "bourse"` and nothing
else. Drive the loop from this repo: code, roadmap, `mix check.dispatch`, the testnet
credentials, the venue authority index and this file's doctrine all live here, and
`rmap` wants this repo as cwd.

🚨 **The repo locations above are doctrine; every other registration value is
not written down here on purpose.** `check_command`, `concurrency_cap`,
`landing_policy`, `target_branch`, `reviewer` and the model pins are operator
settings that change without anyone thinking about this file — a copy of them here
would be stale duplication with no gate to catch it, and the registry is on this
host only, so no CI check can ever guard it. Read them from
`project_registry-list`, which is the authority. Never quote them into a doc.

**Consequences that bite if forgotten:**

- **Read `BUGS.md` before chasing a reported defect.** It is the inbound consumer queue, newest first, and each entry carries a `**Status:**` header — the bug in front of you may already be filed, already fixed, or already decided against. Entries are never deleted; a fixed one keeps its repro as the evidence trail.

- The corpus-wide zero-param JSON-body gate audit (asserting across all 110 reference specs) retired with the workbench archive. **Do not re-add a corpus-wide audit here** — anything that iterates every document under `test/reference_slice/` expecting the full set would be answering a 110-venue question with 16 specs.
- `test/reference_slice/reference_corpus.json` honestly declares the 16 carried venues (the eleven supported plus `coinmetro`, `deepcoin`, `kraken`, `weex`, `whitebit`, used as parser and unsupported-venue counter-examples). Its SHA-256 `source` pin on CCXT's version file (a key named in upstream CCXT terminology, not referring to anything in this repo) still names the upstream revision the slice came from, so provenance stays verifiable. **Adding a reference venue means adding its JSON *and* the manifest entry** — `Bourse.ReferenceSlice` validates count, sort order and pins, and raises otherwise. That module lives in `test/support/`, not `lib/`: the slice is test input, so neither the client nor the Hex package can reach it.

## 🎯 Core doctrine: provider-authoritative, reality-verified

**Interpret, don't extract.** Full model and rationale: `docs/authored-specs.md` — read it first.

**The one and only reality is the exchange APIs we talk to** — not CCXT, not CCXT's fixtures, not training. CCXT was the bootstrap; it is now **one disposable reference among several** (exchange API docs, official SDKs, observed behavior). The DEX venues already live this way. Three axes, kept distinct: **value** correctness (is the number right vs reality), **carve** correctness (is the field/abstraction itself right, willing to *diverge* from CCXT's ontology), and **freshness** (every claim re-proved by running the live lane again, never by a stored answer).

**Authority ladder — the exchange-owned contract wins.** A live venue call establishes what the venue does; the exchange's own documentation, specifications and SDKs establish what its fields and parameters mean. CCXT source, execution and static files are unverified authoring references only.

**Provenance for every external API claim — this order, not the reverse:**

1. Live E2E against the real host (testnet/demo; production public for Coinbase Exchange).
2. Understand one success **and** one relevant error from that interaction.
3. Write the test that hits that same host and asserts those semantics — **and make it fail loudly when it cannot run.** Missing credentials, an unreachable host or an inventory row nothing exercised is a RED with actionable setup text, never a silent exclusion. A tag that drops the test out of the default run does not satisfy `critical-rules.md` § NEVER HIDE TEST FAILURES; it only hides the hole.

There is no step 4. A stored answer is a claim about a venue with no authority behind it, and it stays green forever after the venue changes — the false green `critical-rules.md` § LIVE E2E FIRST names as the worse failure mode. The canonical case is deribit's funding `interval`: the authored literal `"8h"` while the venue publishes hourly, internally consistent and fully covered, because the expectation was computed from the same wrong constant.

**Verification is binary.** A claim is `verified` only after steps 1–3, plus provider-owned meaning. Otherwise it is `unverified`. CCXT JS cannot verify venue semantics.

### 🚨 The suite is provider-live — there is no offline lane

`mix test.json` reaches real venues. `test/test_helper.exs` registers every credentialed venue and **raises** when a pair is absent, naming the venue and pointing at the per-venue variables below; the run stops rather than reporting a green that covers nothing. `ExUnit.start/1` excludes `:dangerous` and nothing else, so the network and contract cases run by default.

What stays offline is what asserts about **our** code rather than about a venue: signing vectors, encoders, decimal math, URL building, the rate limiter, WS dialect parsing, the response types.

`test/bourse/no_faked_provider_oracle_test.exs` is the guard that keeps a faked-provider lane from growing back one convenient helper at a time. It fails the suite when any file under `test/` names `Req.Test`, `Bypass`, `Mox`, a `plug: {` transport override or a committed provider capture — and separately when any file carries a skip tag, because a skipped test reports neither pass nor fail and reads as coverage in every summary that counts it.

Unreachable is not green. A branch we cannot call with our keys and hosts — production-only endpoint, region-restricted key, a position we cannot open — goes into `docs/prod-verification-ledger.md` as unverified and stays unverified. The ledger records *why* a case is unverified; it does not discharge the case, and dropping the row from a lane's denominator instead is how an honest "we cannot reach this" turns into a green lie.

### Rules

- ✅ DO: author interpretive slices against the exchange-owned API contract, using CCXT only as reference material. A method is proven by a live call against the venue's own host, and by nothing else.
- ✅ DO: verify by **running/observing**; author by **reading** any source. A source that fed authoring cannot also be the oracle.
- ✅ DO: run the **confrontation step** when authoring a venue slice (`docs/authored-specs.md`) — for each schema decision, confront the CARVE (does the field exist here? what does the value mean? is the abstraction right for this venue?) against the exchange's OWN semantics. Record every CONFIRMED / DIVERGE outcome in the venue's carve register under `docs/authored-spec-carves/`. A CCXT carve adopted without a register entry is inherited, not confronted.
- 🚨 DO: keep it REAL — for divergence-prone fields (anything a third-party client *computes* or *branches* rather than copies: precision, inverse-vs-linear cost, funding cadence, fee tiers), assert against the **live API plus a provider-owned semantic source**. A hardcoded expectation derived from the same assumption as the code certifies our bug green and silent, which costs more than the live call it replaced.
- 🚨 DO: **decolor on touch.** Comments, moduledocs and docs that cite CCXT as the *reason or authority* for a decision steer every future session back toward CCXT-as-truth. Never write a new one. `test/bourse/ccxt_authority_language_test.exs` enforces this with an explicit allowlist — a new CCXT mention in `lib/` fails the suite until it is either reworded or allowlisted with a compatibility-framed phrase.
- ✅ DO: when a live call is **unreachable with our keys/hosts** (prod-only endpoint, region-restricted key, needs a real open position), append an entry to `docs/prod-verification-ledger.md`. The slice stays `unverified` until a live call exists. 🚨 The ledger records *why* a case is unverified; it does **not** discharge the case. Deleting the row from the contract lane's denominator instead is how an honest "we cannot reach this" turns into a green lie — the count goes up, the coverage goes down, and nothing is red.
- ❌ DO NOT: answer for a provider inside a test — no `Req.Test`, no `Bypass`, no `Mox`, no plug standing in for the venue's host, no committed response body. It is not independent evidence, and `test/bourse/no_faked_provider_oracle_test.exs` fails the suite on every one of them.
- ❌ DO NOT: treat CCXT-derived data or training/web as verification. Independence comes from execution/reality, not a second read.
- 🚨🚨 DO (behavioral default, anchored to the ACTION): **when you set out to check whether a venue "works," your FIRST call hits the LIVE venue.** Use testnet/demo for credentialed venues and the production public host for public-only Coinbase Exchange. Recipe: `creds = Bourse.Credentials.new!(api_key: System.get_env("DERIBIT_TESTNET_API_KEY"), secret: ...); {:ok, ex} = Bourse.Exchange.new("deribit", credentials: creds, sandbox: true)` → then a real `Bourse.fetch_ticker/fetch_balance`. Testnet credentials for all ten credentialed venues are provisioned (below); Coinbase Exchange needs none.

### Venue authority index

Any venue-source, contract-coverage or field-judgment question opens `priv/venues/<venue>/authority/` **FIRST**. The manifest is the local provenance index, not the authority itself: when the question is discovery or freshness, check the provider's official upstream next. Manifests record URL, upstream revision, retrieval date, byte count, SHA-256 and licensing disposition.

The **live evidence** column is the venue's entry in `priv/venues/<venue>/authority/rest_read_contract.json`: its provider-owned authority pins, its operation branches, and the credentials the lane needs to call them. A venue's coverage is what its cases prove against its own host — 410 across the eleven venues — and nothing is stored in this repo that could answer for it instead.

| Venue | Official docs | Testnet/demo host | Live contract cases | Credential env vars |
|---|---|---|---|---|
| Alpaca | [Trading API](https://docs.alpaca.markets/) | `https://paper-api.alpaca.markets` | 16 | `ALPACA_API_KEY` / `ALPACA_API_SECRET` |
| Binance | [Spot API](https://developers.binance.com/en/docs/products/spot) | `https://testnet.binance.vision` | 26 | `BINANCE_TESTNET_API_KEY` / `BINANCE_TESTNET_API_SECRET` |
| Binance COIN-M | [COIN-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-coin-futures) | `https://demo-dapi.binance.com` | 32 | `BINANCE_FUTURES_TEST_API_KEY` / `BINANCE_FUTURES_TEST_API_SECRET` |
| Binance USD-M | [USD-M futures](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures) | `https://demo-fapi.binance.com` | 61 | same pair as COIN-M — one account, two wallets |
| Bybit | [V5 API](https://bybit-exchange.github.io/docs/v5/intro) | `https://api-testnet.bybit.com` | 78 | `BYBIT_TESTNET_API_KEY` / `BYBIT_TESTNET_API_SECRET` |
| Coinbase Exchange | [Exchange REST API](https://docs.cdp.coinbase.com/api-reference/exchange-api/rest-api/products) | production public only | 3 | none — public-only |
| Deribit | [API v2](https://docs.deribit.com/) | `https://test.deribit.com` | 41 | `DERIBIT_TESTNET_API_KEY` / `DERIBIT_TESTNET_API_SECRET` |
| Derive | [API reference](https://docs.derive.xyz/) | `https://api-demo.lyra.finance` | 24 | `DERIVE_TESTNET_API_KEY` / `DERIVE_TESTNET_API_SECRET` |
| Hyperliquid | [API reference](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api) | `https://api.hyperliquid-testnet.xyz` | 29 | `HYPERLIQUID_TESTNET_API_KEY` / `HYPERLIQUID_TESTNET_API_SECRET` |
| Lighter | [API reference](https://apidocs.lighter.xyz/) | `https://testnet.zklighter.elliot.ai` | 16 | `LIGHTER_TESTNET_API_KEY_INDEX` / `LIGHTER_TESTNET_L1_ADDRESS` / `LIGHTER_TESTNET_API_PRIVATE_KEY` |
| OKX | [API v5](https://www.okx.com/docs-v5/en/) | `https://www.okx.com` + `x-simulated-trading: 1` | 84 | `OKX_INTL_API_KEY` / `OKX_INTL_API_SECRET` / `OKX_INTL_PASSPHRASE` |

Artifact **freshness**, **expressiveness** and **scope** are separate axes. A maintained Postman collection can be current but untyped; a frozen OpenAPI can be richly typed but stale. A manifest pin proves which bytes were reviewed, not that the artifact is complete.

**Missing coverage fails open.** A declared unified read without an authored parse slice returns `{:ok, %Bourse.RawResponse{}}` labelled with the provider payload, venue, method, and verification state; an operation the provider does not offer is invisible to that guard and a raw parse slot answers `{:error, {:unsupported_operation, slot}}`. Completeness work must measure both boundaries.

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) and any dispatch run.

- **`mix check.dispatch`** — `format --check-formatted` + `compile --warnings-as-errors`. No suite or analyzers; reviewers select focused behavior tests and risk-relevant live/security checks under the imported verification policy.
- **`mix check.full`** — `bourse.check_lighter_signer`, `precommit`, `bourse.authority_check` (offline), `bourse.error_authority`, `bourse.claude_check`, `bourse.agents_md --check`, `ex_dna --max-clones 0`, and `reach.check --arch --smells --strict --path lib` under `MIX_ENV=dev`. The signer check builds the gitignored helper before testing it and fails when Go or a C compiler is missing.
- **`mix precommit`** — format / compile --warnings-as-errors / `credo --strict --ignore TagTODO,TagFIXME` / doctor --raise / sobelow --skip / `test.json`. This is a full provider-live suite with no `--exclude`; it needs the testnet credentials exported.
- **`mix precommit.full`** — `precommit` + `deps.audit` + dialyzer; a full-suite audit subset without the complete `ci` lanes.
- **`mix ci`** — complete full-QA entry point: `check.full` + `bourse.verify_rest_read_contracts` + `test.json --cover --cover-threshold 80 --output /tmp/bourse-ci-cover.json` + `deps.audit` (with `--ignore-advisory-ids`) + dialyzer.

🚨 **There is no hosted CI, and nothing runs on a schedule.** Every gate here is
executed by a person or a harness run on this host. The live surface is proven by
running `mix bourse.verify_rest_read_contracts` — and `mix bourse.verify_ws_first_frame`
for streams — so a lane nobody ran proves nothing, and "the build is green" is only
a claim until it names which command was run and where.

`check.dispatch` provides no live-provider evidence. The provider-live suite is
in `precommit`; the complete REST-read contract lane is in `ci` and can also run
as `mix bourse.verify_rest_read_contracts`. Venue-facing acceptance must name the
lane and cases exercised.

`mix ci` measures project coverage. Coverage timing and tiers follow
`verification-policy.md`; changed behavior still needs focused tests.

| Check | Command | Notes |
|-------|---------|-------|
| Compile | `mix compile --warnings-as-errors` | silent finish = success |
| Tests | `mix test.json --quiet` | **emits JSON by design** — parse it for real failures; the envelope is **not** a build error. Read `summary.result` / `summary.failed`. 🚨 **Provider-live**: it calls real venues and raises at startup on a missing credential pair. After the run, stderr prints a live-suite classification from `docs/prod-verification-ledger.md` (ledgered demo-unavailable / state-dependent / unreachable vs genuine failures) — do not treat the six okx 50038 rows as defects. |
| REST-read contracts | `mix bourse.verify_rest_read_contracts` | Runs all 410 provider-live contract cases and fails when `executed < denominator`, so a shrinking live surface cannot pass as green. Ledgered reds stay in the denominator and are named in the classification summary; only genuine failures fail the lane. |
| WS first frame | `mix bourse.verify_ws_first_frame` | Classified public WebSocket first data frame per venue. |
| Dialyzer | `mix dialyzer.json --quiet` | **emits JSON by design**. Plain `mix dialyzer` is the authoritative fallback when the JSON encoder can't serialize a warning shape. |
| Lint | `mix credo --strict` | |
| Security | `mix sobelow` | honors `.sobelow-skips` (hash-based), **not** inline comments |
| Docs | `mix doctor` | |
| Authority corpus | `mix bourse.authority_check [--online]` | validates the pinned corpus offline; `--online` checks mutable upstreams for drift |
| Error mappings | `mix bourse.error_authority` | reconciles provider-documented error codes with authored mappings |
| CLAUDE claims | `mix bourse.claude_check` | modules / `mix bourse.*` tasks / repo paths named in gated CLAUDE.md regions, plus the `Bourse.Signing` and `Bourse.Application` rows of the *Key modules* table, vs the tree. Both row gates are inert unless the row exists — a dropped row silently disables its check. Unlisted tree surfaces are not failures. |
| AGENTS freshness | `mix bourse.agents_md --check` | re-renders CLAUDE.md + the pinned `@`-imports (`priv/agents_includes/`) and fails on drift. Regenerate with `mix bourse.agents_md`. |

**Adding a venue** is authoring plus live proof, never a config flag: author its complete document under `priv/venues/<venue>/authored/`, list it in `priv/venues/runtime_support.json`, add its provider-owned entry — authority-source pins, operation branches, arguments, success and error meanings — to `priv/venues/<venue>/authority/rest_read_contract.json`, and get every one of its cases green against the venue's own host. `Bourse.Test.RestReadContracts` refuses an inventory that does not cover every runtime venue, or whose branches drift from the callable client surface, so the two cannot separate.

**Do not reject a run because `mix test.json` / `mix dialyzer.json` printed JSON** — that is the intended output format, not a failure.

## Running tests

```bash
mix test.json --quiet --failed                       # default iteration — calls real venues
mix test.json --quiet test/live/deribit              # everything deribit, contract cases included
mix bourse.verify_rest_read_contracts                  # all 410 provider-live REST-read contract cases
mix bourse.verify_rest_read_contracts --venue deribit  # one venue's cases against its own denominator
mix test.json --quiet --include dangerous            # add the mutating probes + journeys
mix test.json --quiet --include dangerous test/live/journeys   # role journeys only (place real sandbox orders)
mix bourse.classify_signing                            # signing classification report
mix bourse.verify_ws_first_frame                       # classified public WS first data frame per venue
```

> 🚨 **A bare `mix test.json` calls real venues, and a missing credential is a RED.** `test/test_helper.exs` raises with the venue name and the variables to export; `ExUnit.start/1` excludes `:dangerous` and nothing else, so the network and contract cases run by default. There is no `--exclude` that makes this suite offline, and no offline suite to fall back to. Tags in use include `integration`, `network` (testnet REST probes), `rest_read_contract`, `dangerous` (mutating probes — raw POST/PUT/DELETE), `invalid_creds`, `native`, plus selection tags for `--only` filtering (`venue`, `exchange_<venue>`, `private`, `public`, `raw`, `ws_canary`, `ws_auth_smoke`, `unified_integration`, `time_window_live`). Only `:dangerous` is opt-in.

> 🚨 **The complete REST-read surface runs in `mix ci`, not in `precommit`.** `mix bourse.verify_rest_read_contracts` reports denominator, executed count and failures, and fails when `executed < denominator`. Its denominator is scoped to the provider product prefixes each venue hosts on its sandbox; a branch we cannot reach with our keys is ledgered in `docs/prod-verification-ledger.md` as unverified rather than quietly dropped. For a venue-facing task, verify the changed provider behavior with live evidence and name the cases exercised; the complete lane belongs to full QA unless the task explicitly requires it.

**REST-read contracts — the execution lane:** `priv/venues/<venue>/authority/rest_read_contract.json` owns the provider-source pins, operation/branch denominator, arguments, and success/error meanings for all eleven venues. **Its inventory deliberately mirrors the client's callable read surface** (`inventory_basis: client_read_surface`): what the lane proves is that every runtime REST-read branch executes once against the venue's live host and parses — breadth, with the mirror lock guaranteeing a new read branch cannot ship unexercised. It does not claim an inventory independent of the client; role-based **semantic** depth is the journey lane below. `Bourse.Test.RestReadContracts` loads and validates it — schema, authority-pin match against each venue's manifest, case-ID uniqueness, and the runtime mirror lock. `Bourse.Test.Generator.RestReadContract` emits mechanical ExUnit shells, `test/live/<venue>/rest_read_contract_test.exs` defines one module per venue from them, and `Bourse.Test.RestReadContractScenario` performs every real call and assertion. Resource-id branches that need an open or canceled order place a far-from-market GTC limit and cancel it in `on_exit`; that write lives in the default rest_read_contract lane, not under `:dangerous`, because the lane owns the state it reads. History the venue windows out (fills, deposits) is ledgered as state-dependent rather than invented. The raw endpoint probes remain transport-level coverage for request mechanics and write surfaces.

**Journeys — the semantic lane:** `test/live/journeys/<role>/<venue>_test.exs` plays one role against one venue's sandbox, top to bottom with real orders and its own cleanup — the trader role (survey the market, place a resting limit order, track it in open orders, cancel it, verify it gone), with option_seller and market_maker roles following the same shape where the venue offers the product. Cross-call assertions are the point: the order placed must appear in `fetch_open_orders`, echo its price/amount, and disappear after cancel. Journey modules are tagged `:journey` + `:network` + `:dangerous` (they mutate sandbox state — opt-in via `--include dangerous`); test orders with cleanup are explicitly allowed on testnets. In-flow rejections (amount below minimum) live inside the journey file; generic bad-input probes (unknown order id) live once per venue in `test/live/errors/<venue>_test.exs`, which runs by default. Both encode only errors first observed live, never guessed from docs. The single shared helper module is `Bourse.Test.Journeys.Case` (`test/support/journeys/case.ex`) — flow logic stays inside each venue file, and nothing else gets added beside it.

**`Bourse.Testnet` is not an application child.** It is a sandbox-only ETS credential registry that consumers must not boot; `test/test_helper.exs` starts it explicitly via `start_link/1`.

### Testnet credentials

Loaded via `Bourse.Testnet.register_from_env/3` and `Bourse.Testnet.register/3` in `test_helper.exs`, which raises on any registration that is not `:ok`. Env convention `{EXCHANGE}[_{SANDBOX}]_TESTNET_API_KEY/_API_SECRET`, with documented exceptions below. All ten credentialed venues are provisioned; public-only Coinbase Exchange uses no credentials.

- **Alpaca** — `ALPACA_API_KEY/SECRET`; `sandbox: true` resolves `paper-api.alpaca.markets`. Never point the lifecycle test at the live-money host.
- **Bybit** — `BYBIT_TESTNET_API_KEY/SECRET` is the testnet **main-account credential** (minted 2026-08-24, `readOnly: 0`, full permission set incl. `Wallet`/`Exchange`, account switched to `REGULAR_MARGIN` the same day — portfolio-margin mode answers `110077 "pm mode cannot set leverage"` and leaves every `leverage` field empty). The **AI sub-account key** (`sub_member_id 107065959`) is preserved as `BYBIT_TESTNET_AI_SUB_API_KEY/SECRET`; deposit-address reads answer *"Not Support Sub Account"* on any sub-account key, so the lane needs the main key. 🚨 **A fresh AI sub-account key spends its first hours region-walled for spot and convert:** right after provisioning, every SPOT create and `POST /v5/asset/exchange/convert-execute` answered business error 10024 (regulatory) while linear creates succeeded seconds apart; later the same day both worked (`retCode 0`). Treat an early 10024 on this key class as transient provisioning lag — re-probe before ledgering it as a region block. Deposit-address reads stay blocked for a different, durable reason: *"Not Support Sub Account"* — bybit serves those only to the master account. The order-identity contract cases run under `category=linear` (proven with a real filled round-trip). The **earlier** testnet key was read-only (10024 on any signed create, region-restricted); that is why trade evidence was routed to DEMO, and the DEMO path still works: `BYBIT_DEMO_API_KEY/SECRET`, host `https://api-demo.bybit.com` — which is **not** `sandbox: true` (that's testnet); pass `base_url:` on the call. Requests omitting `category` fail with 10032.
  - **Which key the lane runs on is an operator decision, not a settled fact.** It runs on the main-account credential because bybit serves deposit addresses only to the master account; the AI sub-account key stays provisioned alongside it under `BYBIT_TESTNET_AI_SUB_API_KEY/SECRET`. Swapping either way — back to the sub-account, or onto a future key — is a change to make **in consultation with the operator**, never silently: it moves the whole 78-case denominator onto a different wallet, and the order-identity cases only pass on a wallet that actually carries fills.
  - 🚨 **The testnet web UI's 10024 key-creation wall is a KYC gate — completing the testnet sandbox KYC lifts it.** The operator completed it on 2026-08-24 and the main-account key minted immediately after; the key itself carries the proof, reporting `kycLevel: "LEVEL_2"` / `kycRegion: "CHE"` from `GET /v5/user/query-api`. (The OAuth route below stays documented for AI sub-accounts, which need no KYC — that asymmetry is what made the wall look like a bug.) What the wall looked like before the KYC: `POST /x-api/api/newAdd` answers `ret_code 10024`, *"not available to you due to regulatory restrictions"*, with a `KYC_PROMPT_TOAST` config and `kycStatus: 0`. That is the same 10024 the earlier testnet HMAC key returned on any signed create — one gate, not two — and no permission set, captcha retry, browser or exit country moves it: identical responses came from Indonesian and Swiss egress, and neither country is on bybit's restricted list. **Two earlier readings of this wall were wrong and are recorded here so they are not re-derived:** it is neither a geo restriction nor a transient outage. The `KYC_PROMPT_TOAST` config in the response named the remedy correctly the whole time. **Separately, never use the `/en-GB/` locale**: it serves the UK/Archax compliance wall, whose `RESTRICTED_PROMPT_TOAST` list carries `MAIN_API` and every `MAIN_DERIVATIVES*` entry — the UI then shows no perps at all and the key form offers only SPOT. On `/en/` that list collapses to six unrelated entries and the full derivatives permission surface appears, but 10024 stood until the KYC was completed. The working route is Bybit's **AI sub-account OAuth flow**, and it has enough sharp edges to be worth writing down; the vendor spec is [the bybit-exchange/skills OAuth module](https://raw.githubusercontent.com/bybit-exchange/skills/main/modules/oauth.md), whose own instructions are wrong in two places:
    - The pinned SHA256 for the helper `oauth.js` is **broken** — the doc states two contradicting values and the live file matches neither. Read the source instead of trusting the pin; it should only reach `bybit.com` hosts plus a `127.0.0.1` callback.
    - Start the local callback server (`node oauth.js --port 9876 --env testnet`), open the printed PKCE URL while logged in on `testnet.bybit.com`, click **Confirm**. The server exits after **5 minutes** — miss that window and the browser redirect hits a dead port.
    - 🚨 **The success page labels its value "Access Token" — it is an authorization code.** Using it as `Authorization: Bearer` answers `50000 Token verify fail`. Exchange it first: `POST api2-testnet.bybit.com/oauth/v1/public/access_token` with `client_id=ai-agent`, `code`, `code_verifier` (the verifier lives in `~/.bybit/oauth_callback_<pid>_init.json`). Codes are single-use and expire in 10 minutes. **That response is flat — no `result` wrapper** — unlike `ai_accounts`, so a parser written for one shape silently reads nothing from the other.
    - `GET /oauth/v1/resource/restrict/ai_accounts` returns `accounts: []` on a fresh account; `?is_create=true` creates one (max 5). Its `api_key`/`api_secret` are ordinary HMAC credentials for `api-testnet.bybit.com` and keep working after the 24 h OAuth token expires. Revoking access means **deleting the sub-account** — there is no separate key-delete.
  - **An AI sub-account is a separate wallet, and funding it is two steps, not one.** A transfer from the main account lands in **FUND**; trading reads **UNIFIED**, so it needs `POST /v5/asset/transfer/inter-transfer`. Then non-USDT collateral must be switched on (`POST /v5/account/set-collateral-switch`) or `totalAvailableBalance` stays `"0"` against a four-figure `totalEquity` and every order fails `110007 CheckMarginRatio fail! InsufficientAB` — a balance error that looks like missing funds when the funds are already there.
  - **Deposit and withdrawal endpoints are permanently out of scope** for this credential class: `GET /v5/asset/deposit/query-address` answers `permission_denied`, so `fetchDepositAddress` / `fetchDepositAddressesByNetwork` can never be green while the testnet key is an AI sub-account. Ledger them as unreachable rather than reading them as regressions.
  - Option orders REQUIRE `orderLinkId` (10001 without it; linear doesn't). Nearest-expiry options are **USDT-settled**.
  - **A SHORT option can become unclosable — pick the instrument for the close, not the open.** Bybit enforces a mark-relative price band (`110003`), and deep-OTM/far-expiry demo books have a single ask far outside it, so a short that filled cannot be bought back at any accepted price (observed 2026-07-25). Select an instrument whose ask sits *inside* the band before selling.
  - **Option TP/SL is `POST /v5/position/trading-stop` only, and an omitted leg CLEARS the other one** under `tpslMode: "Full"` (verified live: a call carrying only `takeProfit` silently wiped the existing `stopLoss`, retCode 0). Always send both legs when amending either. `triggerPrice` on `/v5/order/create` is silently ignored for options.
  - `GET /v5/account/fee-rate` is unusable on demo (empty list with retCode 0 for options, HTTP 400 for linear) — measure fees from actual fills.
- **Deribit** — `DERIBIT_TESTNET_API_KEY/SECRET`.
- **Binance spot** — `BINANCE_TESTNET_API_KEY/SECRET`.
- **Binance USD-M / COIN-M** — the **same** `BINANCE_FUTURES_TEST_API_KEY/SECRET` pair authenticates both (`_TEST_` is a silent fallback for `_TESTNET_`). `demo-dapi.binance.com` and the legacy `testnet.binancefuture.com` are one account, not two environments. **COIN-M and USD-M are separate wallets inside that one account**, and the UI faucet credits USD-M only — a drained COIN-M wallet is re-funded through the UI. The account runs **One-way mode** (verified live 2026-08-10: `GET /fapi/v1/positionSide/dual` → `dualSidePosition: false` — an earlier Hedge-Mode note here was stale), so orders need no `positionSide` and `reduceOnly` is accepted; if the mode is ever flipped to Hedge, orders REQUIRE `positionSide` and fail `-4061` without it. Oversized orders fail `-2019` — a real pinnable business error. `BTCUSD_PERP` is inverse, 100 USD notional per contract. `DELETE /dapi/v1/allOpenOrders` returns `code 200` even with nothing resting, so it is a safe idempotent cleanup hook.
- **OKX — international demo is canonical.** `OKX_INTL_API_KEY` / `_API_SECRET` / `_PASSPHRASE`, host `www.okx.com` + `x-simulated-trading: 1` (both supplied by `sandbox: true`). The same key on live returns 50101. Option orders at `acctLv 3` require `tdMode: "isolated"`; demo option books carry no two-sided ATM liquidity, so order-accept/cancel is the available lifecycle. **Sharp edge:** batch envelopes report `code "1", msg "All operations failed"` with the real per-order `sCode`/`sMsg` only in `data[0]`. Never use `my.okx.com` or `OKX_TESTNET_*`.
- **Lighter** — DEX (zk perp), not an HMAC pair: `LIGHTER_TESTNET_API_KEY_INDEX` (0–255), `LIGHTER_TESTNET_L1_ADDRESS` (the wallet that owns the account), `LIGHTER_TESTNET_API_PRIVATE_KEY` (40-byte hex). Signing is zk-Schnorr through the supervised first-party helper (`Bourse.Signing.Lighter` + `native/lighter_signer/`) — there is no in-Elixir signer. `sandbox: true` selects the testnet host **and** chain id 300 (mainnet is 304; the chain id is part of the signed payload, so a mainnet-chain signature is rejected on testnet). Private reads need an `auth_deadline` and `account_index`; writes need a caller-supplied `nonce` from `public_get_nextnonce` plus a `client_order_index`. Only `limit` orders are supported.
  - 🚨 **The account index is not configuration — it is read from the wallet at every run.** Lighter reassigns it whenever the testnet is reset, and every stored copy went stale at each reset and was rewritten by whichever session hit the 20013 first (354 → 153 → 230, locally and on the harness server, 2026-08 to 2026-09-15). `test/test_helper.exs` resolves it through `Bourse.Lighter.CredentialCheck.resolve_account_index/1` (`accountsByL1Address`) and exports it into the test process, overriding any stale shell export. There is nothing to store and nothing to edit in `~/.secrets` when it changes.
  - 🚨 **Two different reds, two different repairs — `CredentialCheck` names which one.** *"NO account for L1 wallet"* (`21100`) or *"carries NO registered key at all"* is a **testnet reset**: the one repair is `mix bourse.provision_lighter`, which is operator-only — it demands a terminal and a typed `yes`, so no agent or harness run can execute it. *"api_key_index N is EMPTY"* with other indices occupied is a **configuration error**: point `LIGHTER_TESTNET_API_KEY_INDEX` at the registered index; provisioning there mints a second key and breaks every other machine. Agents never write `~/.secrets` (here or on the harness server) — report the verdict to the operator. A Lighter red makes Lighter red, not the run: the banner is printed before and after the suite and the other venues still run.
- **Hyperliquid** — DEX; "creds" = an EVM wallet. `HYPERLIQUID_TESTNET_API_KEY` = wallet address, `_API_SECRET` = its private key. Testnet funded via the official drip (`POST /info {"type":"claimDrip","user":…}`, unlocked by a ≥5 native-USDC mainnet Bridge2 deposit from the same address; re-claimable every 4h).
- **Derive** — DEX (Lyra v2). `DERIVE_TESTNET_API_KEY` = the **Derive smart-contract wallet** (what `X-LyraWallet` must carry, NOT the owner EOA); `DERIVE_TESTNET_API_SECRET` = a **registered Admin session key's** private key. REST base `api-demo.lyra.finance`. **Sharp edge:** Derive's edge proxy verifies auth *before* the app — the signer must equal `X-LyraWallet` or be a registered session key for it, else nginx returns HTML 403 with no JSON. The owner EOA is NOT auto-registered on UI onboarding, so a plain owner signature 403s.
  - Order placement: the order endpoints carry `body_encoding: "json"`, so dispatch JSON-encodes params *before* the signer runs — sign the eight-field tuple yourself with `sign_order(order, private_key: ..., testnet: true)` and put the `"signature"` string in params. `max_fee` is required AND has a dynamic floor (~1.5 USDC; error 11023 names the exact minimum) and is part of the signed hash, so re-sign after adjusting. The request also needs `"signer"` (the session key's EOA address), `nonce` (ms), `signature_expiry_sec`, and the trade-module data hash built from `base_asset_address`/`base_asset_sub_id`.

## Do NOT edit (generated) / DO author (frozen specs)

- `lib/bourse/exchanges/*.ex` — generated at compile time; never hand-edit (fix the generator).
- `priv/venues/<venue>/authored/` — **the complete hand-owned runtime documents** (eleven venues, schema version `3`), split endpoint-major: `venue.json` (identity/urls/signing), `markets.json`, `endpoints.json` (one unified method = one object), `raw.json` (one raw endpoint = one object), `errors.json`, `normalization.json`. `Bourse.Spec.Disk` rotates those files back into the facet-major in-memory map. Identical binance-family descriptors are hoisted to `priv/venues/_shared/binance_family/descriptors.json` and referenced by `$ref`. Author per the loop in `docs/authored-specs.md`, then prove each claim with a live call against the venue's own host.
- `test/reference_slice/<venue>.json` — frozen CCXT-derived **reference** siblings (the 16-venue slice), pinned by `reference_corpus.json`. Never loaded at runtime, never shipped in the Hex package; read-only authoring/test input (e.g. the test-only `markets.symbols_index` used by integration symbol selection).

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
| `Bourse` | Unified API entry — 246 methods + bang variants + Descripex `api()` + `describe/0-2`. Generated from `Unified.method_defs/0`. |
| `Bourse.Unified` | Internal dispatch: `method_defs/0` (4-tuples), `call/5`, `split_opts/1`, `build_params/3`. Not public. |
| `Bourse.Exchange` | Config struct + constructor + generator macro. Carries `:tier`, `:module` (O(1) dispatch), `signing_pattern`, `signing_config`, `symbol_patterns`, `error_body_checks`, `error_code_fields`. |
| `Bourse.Spec` | Compile-time JSON spec loader. Enforces owned `schema_version` `3`. One complete owned document per venue — no base/overlay merge, no CCXT-base fallback. |
| `Bourse.Spec.Schema` | Owned runtime-schema contract. Required/forbidden slot table; raises `owned spec "<venue>" gap <path>` on any missing/null/empty/forbidden slot. |
| `Bourse.Symbol` | Bidirectional symbol normalization, driven by the authored `markets.symbol_patterns` slice. |
| `Bourse.Error` | `defexception` — 18 error types covering 34 compatibility exception classes. Pattern-matchable AND raiseable. |
| `Bourse.Dispatch` | Runtime dispatcher: path interpolation, base URL resolution (4 patterns), signing, HTTP delegation. |
| `Bourse.HTTP` | Req wrapper — manual query encoding, safe retry GET/HEAD only, telemetry, circuit breaker. |
| `Bourse.RateLimiter` | Per-credential weighted GenServer, sliding window. Key `{exchange, api_key \| :public}`. |
| `Bourse.LiveLane.FirstFrame` | **Repo-internal.** Probes each venue's public WebSocket and classifies its first data frame; `mix bourse.verify_ws_first_frame` drives it. |
| `Bourse.Signing` | Dispatches 8 patterns: `:hmac_sha256_query`, `:hmac_sha256_headers`, `:hmac_sha256_iso_passphrase`, `:api_key_secret_headers`, `:deribit`, `:hyperliquid`, `:derive`, `:lighter`. |
| `Bourse.Application` | Supervises `Bourse.RateLimiter` + `Bourse.RateLimiter.State` + `Bourse.Signing.Lighter.Supervisor` + `Bourse.WS.Broadcast` + `Bourse.WS.ConnectionOwner.Supervisor`. |

**Unified response types:** 7 original (`Ticker`, `Trade`, `Order`, `Balance`, `Market`, `OHLCV`, `Fee`), 9 tier-1 core (`OrderBook`, `Position`, `Currency`, `Transaction`, `LedgerEntry`, `FundingRate`, `DepositAddress`, `TransferEntry`, `TradingFee`), 9 tier-2 derivatives, 9 tier-3 analytics.

**Signing:** the pattern set is the `Bourse.Signing` row above, and `mix bourse.claude_check` set-compares it against the `def sign/4` clause heads — a pattern added in code without editing that row fails the gate. `:api_key_secret_headers` is Alpaca's. Per-pattern detail lives in the module's `@moduledoc`.

**WebSocket:** `Bourse.WS` wraps `ZenWebsocket.Client`. **All eleven venues are configured and confirmed streaming live** (alpaca, binance, binancecoinm, binanceusdm, bybit, coinbaseexchange, deribit, derive, hyperliquid, lighter, okx). Coinbase Exchange is public-only on `wss://ws-feed.exchange.coinbase.com` (matches + heartbeat, no credentials). A venue outside runtime support answers `{:error, :unsupported_exchange}`; a runtime venue without a hand base would answer `{:error, :websocket_not_configured}`. `subscribe/3` returns `:ok | {:error, term()}` and surfaces venue rejections as `{:error, {:subscription_rejected, frame}}`.

**`connect/3` authenticates a `:private` section** through `Bourse.WS.authenticate/2`, and a failed handshake closes the socket rather than returning one — an open unauthenticated private connection fails later as a silently empty stream, not as an error. The accepted handshake is recorded on `ws.auth`, which is what `Bourse.WS.Adapter` schedules renewal from instead of re-running it. Live-verified differentially across six venues (`test/live/ws/auth_live_smoke_test.exs`). Alpaca's public market-data section is the documented exception: `auth_sections` includes `:public`, so `connect/3` runs the key/secret handshake there too.

**Not every credential is a frame — some are the URL, and that changes when the handshake runs.** `:listen_key` (binanceusdm, binancecoinm) issues its key over REST *before* the socket opens, so `connect/3` performs the round-trip and connects to the resulting URL; `authenticate: false` is refused with `{:error, {:auth_not_optional, :listen_key}}` because there is no later handshake to run. `Bourse.WS.ListenKey` owns the call and the refresh; `Bourse.WS.Auth.ListenKey` stays network-free endpoint resolution and resolves **generated raw endpoint names**, not CCXT method names — the previous config named methods that match no function here, so it looked resolved and could not be called.

🚨 **A wrong listen key connects.** Verified on `demo-fstream.binance.com` and again on `demo-dstream.binance.com`: a bogus key reports `:connected` throughout and delivers nothing, while a real one delivers `ORDER_TRADE_UPDATE`. So every failure to obtain a key must be an error, never a fallback — and the venue's own checks are weaker than they look: the listen key endpoint is **API-key authenticated and does not verify the secret**, so a differential probe has to corrupt the *api key* to mean anything.

🚨 **The two binance futures halves are two streams, not one.** COIN-M lives on `dstream` (`demo-dstream.binance.com`) and issues its key from `dapiPrivate_*`; USD-M lives on `fstream` and issues from `fapiPrivate_*`. They share one demo account and one API key pair but are separate wallets with separate user data streams, so a socket keyed by the other half's key connects and stays silent — the same failure shape as a bogus key. COIN-M's market type is `:inverse` (`:delivery` normalizes to it); its `PUT listenKey` returns the key in the body where USD-M returns `{}`.

🚨 **binance spot is not a listen key venue any more.** Binance retired the spot and margin listen keys on 2026-02-20; `POST /api/v3/userDataStream` answers **HTTP 410 Gone**. The private section is authored onto the venue's WebSocket API host (`ws-api.binance.com/ws-api/v3`), opened by a signed `userDataStream.subscribe.signature` request under the `:ws_api_signature` pattern — that one frame both authenticates and *is* the user data stream, so there is no channel to subscribe to afterwards. A `subscribe.signature` subscription also **outlives the socket that made it**, so a differential probe must run the unauthenticated leg first or it reads the previous leg's events.

**derive's private handshake is `:eip191_jsonrpc_login`.** `connect/3` signs the millisecond timestamp with EIP-191 (Admin session key) and sends the venue's `public/login`; a successful reply records `%{pattern: :eip191_jsonrpc_login, meta: %{subaccounts: ids}}` on `ws.auth`. A failed handshake closes the socket: an unregistered signer is rejected as JSON-RPC error `403` `"Unauthorized or Forbidden"` (the REST edge proxy's HTML 403 is a different surface). `authenticate: false` is the unauthenticated leg: a pre-login subscribe is rejected with envelope `13000` wrapping `14022`. Live-verified differentially against `wss://api-demo.lyra.finance/ws`. **Hyperliquid's `nil` pattern is correct** — it authors no private URL; private subscriptions are scoped by address on the public socket, which is not the same condition as a missing handshake.

### Critical design decisions

**HTTP pipeline:** manual query encoding (signing needs raw params — don't use Req's `:params`); safe retry GET/HEAD only (never POST/PUT/DELETE — duplicate orders); per-credential rate limiting for multi-user isolation.

**Exchange struct:** config, not process — pure data, no GenServer. String keys matching the JSON spec.

**Errors:** two-tier matching — `error_codes` (exact) plus `broad_error_patterns` (substring), pre-processed at construction. `error_body_checks` for top-level sentinels; `error_code_fields` for exact-code probe order.

**Dispatch:** symbol denormalization happens in `Unified.call/5`, NOT `Dispatch.call/4` — raw callers pass through untouched. Required params always win over opts (`Map.put_new` prevents silent override in trading calls).

**Authored `path_params` descriptors are `%{"name", "source"}` and `source` is ALWAYS `"params"`** — verified 90/90 across the carried slice, 47/47 in the eleven authored documents. `interpolate_path/3` resolves from the params map by `"name"` and deliberately ignores `source`. This is a relied-on invariant: if an authored spec ever sets a path-param source to anything else, resolving from `params` silently reads the wrong place. The fix is not to pre-build unused branches but to make the day-it-changes failure LOUD — `path_param_name/1` should match `%{"source" => "params"}` and let any other shape hit a raising clause.

**Durable kernel:** when data is finite, verifiable, and fails silently when wrong, **author it explicitly — don't infer it at runtime.** `HmacRecipe` stays as the deterministic recipe *executor* (mechanism, not judgment); author recipes into its shape rather than rebuild a signer.

## The trading domain layer

The trading domain — OptionProposal, OptionReadiness, OptionSaga, PortfolioRisk and their submodules — lives in its own repo, https://github.com/ZenHive/bourse_trading (private, ZenHive), which depends on this client's published Hex package. The modules keep the Bourse module namespace there; that is deliberate, not a leftover.

**The dependency stays one-directional: the domain calls the client's packaged surface, never the reverse.** Nothing in this repo may reference a domain module — a single inbound edge would couple the client to an unpublished repo. Domain logic (proposal checks, readiness collection, saga execution, exposure math) belongs in bourse_trading; venue behavior, authored specs, signing and unified parsing belong here.

## Repo-internal tooling inside `lib/`

`Bourse.LiveLane.FirstFrame` and its bootstrap live in `lib/` because the `mix bourse.*` tasks compile in `:dev`, where `elixirc_paths/1` does not carry `test/support`. They are **not** client surface: `@unpackaged_prefixes` in `mix.exs` keeps them out of the tarball, and `document_module?/2` keeps them and every `mix bourse.*` task but `bourse.build_lighter_signer` out of hexdocs.

**Anything you add to that cluster inherits the exclusion — add its prefix.** These modules may use `:dev`/`:test`-only deps, and a shipped copy fails at the *consumer's* compile rather than ours: the original case was `Req.Plug`, which exists only from req 0.7 and only behind the `only: [:dev, :test]` `:plug` dep, so consumers resolving `~> 0.6.1` got an undefined-module warning out of two repo-internal modules.

## Git commit configuration

Conventional commits: `<type>(<scope>): <description>`. Types: feat, fix, docs, style, refactor, test, chore. Title-only; bodies only when asked. No `Co-Authored-By` footers.

**Release tags come AFTER the maintainer confirms the publish went through — never before.** `mix hex.publish` is run by hand (it needs 2FA), and the release gate keeps finding things right up to the prompt: 0.2.0 gained a hexdocs-filter fix and ten broken-link fixes after the version bump was already committed. A tag cut in advance names a tree that is not what shipped, and correcting it means force-updating a pushed ref. Bump the version, get the gate green, hand off the publish — then tag the published commit.
