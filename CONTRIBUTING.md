# Contributing

Thanks for helping improve `bourse`. This doc covers code/test changes and
provider-authoritative spec work under the authored-specs model.

## Where Does My Fix Belong?

| Symptom | Belongs In |
|---------|------------|
| Dispatcher, HTTP client, signing runtime, rate limiter, circuit breaker, unified-API translation layer | `bourse` (this repo) |
| Supported-venue interpretive gap (signing, response normalization, symbol/error semantics) | **Author** the slice here from the provider contract, then verify it through the reality gate — see `docs/authored-specs.md` |
| Unsupported venue | Prepare and grade a candidate with the `ccxt.promote_venue` Mix task; copying reference JSON alone never adds runtime support |
| Exchange-specific quirk no spec field can represent | Record and author a provider-backed carve rather than patching consumer heuristics |

The ten supported venues are hand-owned (`docs/authored-specs.md`). CCXT source,
fixtures, and ccxt-distill are compatibility/bootstrap references only. The
provider's observed API behavior and provider-owned contract establish
semantics.

## Venue promotion

Use `mix ccxt.promote_venue --prepare` to create a candidate and evidence report.
Promotion requires provider-owned semantics plus manifest-registered reality for
every critical slot. See `docs/authored-specs.md` § Venue promotion boundary.

### Anti-Patterns

- ❌ Adding a per-exchange override map in `%Bourse.Exchange{}` to paper over spec data.
- ❌ Reintroducing a standing vendor-sync Mix task or distill staleness hooks — removed in task 172 / T-E1.
- ❌ Adding runtime interpretation heuristics for data that belongs in an authored spec field.

### Reference

- `docs/authored-specs.md` — first-class authoring loop and epistemology
- `CLAUDE.md` § The workbench boundary — what this repo owns and what it does not

## Code Contributions (bourse)

### Before You Start

- Read `CLAUDE.md` — architectural decisions, naming conventions, and the Non-Unified Track scope policy.
- Read `CHANGELOG.md` § Unreleased — what has landed since the last release.
- Open `priv/authority/<venue>/` before authoring a supported-venue field.

### Running the Suite

```bash
mix test.json --quiet                        # offline suite
mix test.json --quiet --failed               # iterate on failures
mix ccxt.oracle_gate                         # manifest-registered reality oracle
mix test.json --quiet --include network      # integration probes (requires testnet creds)
mix dialyzer.json --quiet
mix credo --strict --format json
```

Full flag reference: see the `ex-unit-json` and `dialyzer-json` sections in `CLAUDE.md`.

### PR Checklist

- [ ] Code follows existing module/function naming and the conventions documented in `CLAUDE.md`.
- [ ] New behavior has tests (unit + integration where appropriate). Tests fail loudly — no silent `assert true` branches on errors.
- [ ] `mix test.json --quiet`, `mix dialyzer.json --quiet`, and `mix credo --strict` all pass.
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` with what was done and key decisions (no test counts or file-count stats).
- [ ] `CLAUDE.md` updated only if architecture, conventions, or the module inventory changed.
- [ ] If a discovery surfaced new work, open an issue — the task roadmap lives in
      the private authoring workbench, not in this repository.

### Commit Messages

Conventional-commits format: `<type>(<scope>): <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`. See recent history (`git log --oneline`) for examples.
