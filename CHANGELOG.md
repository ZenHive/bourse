# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial repository. `bourse` is extracted from the working repo it grew up in,
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
