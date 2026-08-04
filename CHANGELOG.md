# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial repository. `bourse` is extracted from the `ccxt_client` working repo,
  which remains the authoring workbench for venue specs and venue promotion.
  Carried over: the client (`Bourse.Exchange` / `Dispatch` / `HTTP` / `Signing` /
  `Symbol` / `Unified` / `WS` plus the unified response structs), the ten authored
  runtime specs, the verification layer (`mix ccxt.oracle_gate`, the recorded
  response and accepted-request evidence, live drift checking), and the trading
  domain layer.

  Left behind in the workbench: spec authoring and venue promotion tooling, the
  vendored reference corpus, and the roadmap. The client carries a ~1 MB reference
  cache slice covering exactly the supported venues instead of the full corpus.
