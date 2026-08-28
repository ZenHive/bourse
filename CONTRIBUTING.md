# Contributing

Thanks for helping improve `bourse`. This doc covers code/test changes and
provider-authoritative spec work under the authored-specs model.

## Where Does My Fix Belong?

| Symptom | Belongs In |
|---------|------------|
| Dispatcher, HTTP client, signing runtime, rate limiter, circuit breaker, unified-API translation layer | `bourse` (this repo) |
| Supported-venue interpretive gap (signing, response normalization, symbol/error semantics) | **Author** the slice here from the provider contract, then verify it with a live REST-read contract case — see `docs/authored-specs.md` |
| Unsupported venue | Hand-author the owned document and earn live REST-read contract coverage for it; copying reference JSON alone never adds runtime support |
| Exchange-specific quirk no spec field can represent | Author a provider-backed carve and register it rather than patching consumer heuristics |

The eleven supported venues are hand-owned (`docs/authored-specs.md`). CCXT source
and ccxt-distill are a pinned third-party extraction, usable as an authoring
clue only. The provider's observed API behavior and provider-owned contract
establish semantics.

## Adding a venue

There is no promotion task. A new venue is hand-authored: write the owned
document, add it to `Bourse.Spec`, the registry and the compiled set, and give
every critical operation a live REST-read contract case in
`priv/venues/<venue>/authority/rest_read_contract.json`. Provider-owned semantics plus a
passing live case are what make a slot `verified`. See `docs/authored-specs.md`
§ Adding a venue.

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
- Open `priv/venues/<venue>/authority/` before authoring a supported-venue field.

### Running the Suite

The suite is provider-live. Every assertion about what a venue does is a real
call against that venue's testnet/demo/public host, so the venues' credentials
must be present — `test/test_helper.exs` raises when they are not. What runs
offline is our own mechanics: signing vectors, encoders, decimal arithmetic, URL
construction, the rate limiter, WebSocket dialect parsing, types.

```bash
mix test.json --quiet                        # the suite (provider-live)
mix test.json --quiet --failed               # iterate on failures
mix bourse.verify_rest_read_contracts          # the full REST-read contract lane
mix dialyzer.json --quiet
mix credo --strict --format json
mix ci                                       # everything, incl. the coverage gate
```

`mix ci` is the gate a change is judged by; there is no hosted CI running it for
you, so run it locally before opening a PR.

Full flag reference: see the `ex-unit-json` and `dialyzer-json` sections in `CLAUDE.md`.

### PR Checklist

- [ ] Code follows existing module/function naming and the conventions documented in `CLAUDE.md`.
- [ ] New behavior has tests. A claim about what a venue returns is made by a live call to that venue; a claim about our own mechanics may be offline. Tests fail loudly — no silent `assert true` branches on errors, no mock or replay standing in for the provider (`test/bourse/no_faked_provider_oracle_test.exs` fails the suite on `Req.Test`, `Bypass`, `Mox`, `plug: {`, a fixture path, or `@tag :skip`).
- [ ] `mix ci` passes locally — it carries `mix test.json`, `mix bourse.verify_rest_read_contracts`, dialyzer, `mix credo --strict` and the 80% coverage gate.
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` with what was done and key decisions (no test counts or file-count stats).
- [ ] `CLAUDE.md` updated only if architecture, conventions, or the module inventory changed.
- [ ] If a discovery surfaced new work, open an issue — the task roadmap lives in
      the private authoring workbench, not in this repository.

## Reporting a Bug

File it in [BUGS.md](https://github.com/ZenHive/bourse/blob/main/BUGS.md), newest entry first: the call you made, what you
observed, what you expected, and the affected venue where it is venue-specific. A
runnable repro is worth more than a description. Entries are triaged into scored
tasks in the authoring workbench and get a dated note pointing at the filed id;
nothing is deleted, so the file doubles as the record of what is already known and
what has since been fixed.

### Commit Messages

Conventional-commits format: `<type>(<scope>): <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`. See recent history (`git log --oneline`) for examples.
