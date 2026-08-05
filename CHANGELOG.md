# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

Findings from the 2026-08-04 live venue sweep, which compared this client against
CCXT JS endpoint by endpoint on the same testnets. Each was generalized to the
defect class rather than patched per venue.

- Unified reads returned raw venue envelopes, collapsed multi-row responses to a
  single row, or keyed results by un-normalized venue symbols. A whole-surface
  contract guard now holds every unified read to the same shape.
- `fetch_canceled_orders/2`, `fetch_closed_orders/2` and `fetch_orders/2`
  returned identical, unfiltered rows.
- Unified read parsing raised on legitimate venue responses instead of returning
  a typed error.
- Authored enum slices rejected real venue values; a single unmapped order status
  disabled four Hyperliquid read methods.
- Field maps were present but inert: populated venue fields arrived as `nil`, and
  one scalar parse dropped the year from a timestamp.
- Time-window request params (`since`, `limit`) did not reach the venue on every
  venue that accepts them.
- `Bourse.WS.subscribe/2` reported success when the venue rejected the
  subscription, and its return shape varied by venue.
- Funding cadence came from an authored constant rather than observed venue data
  — Deribit was recorded as 8h for an hourly venue, overstating funding roughly
  eightfold in anything that multiplied by it.

Reported by consumers against the published package:

- `Bourse.Testnet` exited the calling process when the registry was not running.
  Because the registry is deliberately not an application child, a consumer
  calling `register_all_from_env/1` from its own `test_helper.exs` lost its
  entire suite before a single test ran. Writes now return
  `{:error, :not_started}` and reads raise an `ArgumentError` naming
  `start_link/1`, instead of a `GenServer` exit and an opaque ETS badarg.
- Derive's ticker mapped `high`, `low`, `change` and `percentage` from a `stats`
  object the venue publishes on neither its demo nor its production host, and
  documents nowhere — an inherited carve whose only surviving evidence was a
  January 2025 sample. The four fields are recorded as absent, registered as
  carve `C-T560d`.

Packaging and attribution, found while auditing the extraction:

- The tarball shipped `Bourse.Spec.Promotion` and its two helpers — 1,049 lines
  of repo-internal tooling that reads deliberately unpackaged reality manifests,
  so in a consumer project it could only fail on missing files. `Path.wildcard/1`
  yields directory entries, Hex expands a listed directory recursively, and
  `lib/bourse/spec` matched no exclusion prefix. Directory entries are now
  dropped outright rather than excluded one prefix at a time, and the guard
  asserts against the *built* tarball, where the expansion is actually visible.

### Changed

- `Bourse.Testnet` no longer starts as a child of `Bourse.Application`. It is a
  credential registry for sandbox testing and has no place in a consumer's
  always-on supervision tree; callers that want it start it explicitly.

### Added

- `Bourse.Testnet.started?/0`, so a caller can ask whether the registry is
  running rather than discover it from a failure.
- `NOTICE`, shipped in the package. The authored venue specs still carry method
  and return descriptions taken verbatim from CCXT, `docs.ccxt.com` links
  included; CCXT is MIT, whose terms require the copyright notice to travel with
  that text. No such notice was ever tracked, in this repository or its
  predecessor — publishing the package is what made the omission consequential.
- A CI workflow running the offline gate — format, warnings-as-errors, Credo,
  Doctor, Sobelow, the offline suite, the reality oracle, the documentation
  claims, `deps.audit` and Dialyzer. Until now those ran only on the maintainer's
  host and through dispatch review, so an outside pull request and a fresh clone
  had no gate at all.
- This repository. `bourse` is extracted from the working repo it grew up in,
  which stays behind as the private authoring workbench `bourse-workbench`.
  Carried over: the client (`Bourse.Exchange` / `Dispatch` / `HTTP` / `Signing` /
  `Symbol` / `Unified` / `WS` plus the unified response structs), the ten authored
  runtime specs, the verification layer (`mix ccxt.oracle_gate`, the recorded
  response and accepted-request evidence, live drift checking), the spec-authoring
  and venue-promotion tooling, the authority corpus and its validators, and the
  trading domain layer.

  Left in the workbench: the complete version-pinned CCXT reference corpus (110
  documents), the classification tooling and corpus-wide audits that can only be
  answered against it, and the task roadmap with its CHANGELOG gate. This
  repository carries a 15-document reference slice covering the supported venues,
  which its own offline tests read; both manifests pin the same upstream revision,
  so the two copies are checkable rather than silently divergent.

## [0.1.0] - 2026-08-03

First hex.pm release as `bourse`, succeeding the retired `ccxt_client` package.
Published before this repository existed, from the tree that is now the private
`bourse-workbench` history — there is no `v0.1.0` tag here.

### Added

- Ten provider-authored venue integrations — `alpaca`, `binance`,
  `binancecoinm`, `binanceusdm`, `bybit`, `deribit`, `derive`, `hyperliquid`,
  `lighter`, `okx` — each generated at compile time from one complete owned JSON
  spec. Runtime support is a closed set: constructing any other exchange fails
  with `unsupported_exchange`.
- Two API surfaces. Raw per-exchange endpoint functions pass exchange responses
  through unchanged with signing, rate limiting, circuit breaking, and transport
  handled. The unified `Bourse` API adds cross-exchange methods returning
  normalized structs, with bang variants and machine-readable descriptions.
- Signing for every supported venue, including first-party signers for the three
  DEX venues: EIP-712 for Derive, msgpack action hashing for Hyperliquid, and a
  zk-Schnorr Port helper for Lighter. `Bourse.Signing` dispatches the authored
  recipes; no signing behavior is inferred at runtime.
- WebSocket support via `Bourse.WS` — a thin wrapper over `zen_websocket` driven
  by authored per-exchange subscription and auth patterns.
- Discovery and agent integration: `Bourse.describe/0-2` for method signatures,
  parameters, errors, and return shapes, plus `Bourse.MCP.tools/0` for MCP tool
  autodiscovery.
- Operational layers: per-credential weighted rate limiting with response-header
  feedback, per-exchange circuit breakers, telemetry events, and sandbox
  resolution for all ten venues via `Bourse.Exchange.new/2`.

### Changed

- Renamed from `ccxt_client` to `bourse`, with the `CCXT.*` namespace becoming
  `Bourse.*`. See the migration notes in the README.
- Interpretive judgment moved out of the runtime and into the authored specs.
  The heuristic signing classifier, symbol pattern inference, and long-tail
  fallback are removed; the runtime reads authored fields instead of guessing.
- Correctness is verified against recorded venue reality — registered response
  recordings, accepted-request goldens, and recorded exchange errors — rather
  than against third-party client behavior.

### Fixed

- Alpaca `fetch_ohlcv/3-4` had no working call shape: the default path returned
  an empty list, failing silently as success, and the documented `since` option
  produced an HTTP 400. The authored request slice now emits a real dated window.

### Packaging

- The published package carries the library and the ten authored specs. The
  repo-internal authoring and audit tooling is not shipped; `mix
  ccxt.build_lighter_signer`, the prerequisite for private Lighter calls, is the
  one task consumers receive.

[0.1.0]: https://hex.pm/packages/bourse/0.1.0
