# Lighter native signer

Private Lighter requests use a host-native helper linked to the pinned official
Go signing library. Build it with Go 1.25.0 (the version `go.mod` requires) and
a C compiler:

```bash
mix bourse.build_lighter_signer
```

The Mix task reads the packaged sources from the `bourse` dependency and
writes the host helper beneath the application's `priv/native/lighter_signer/`
directory. Prebuilt binaries are not distributed.

## Verification boundary

`golden_test.go` tests the pinned Go cryptography directly. Its vectors cover
the primitive public key and signature, auth-token construction, create-order,
and the remaining C-exposed transaction constructors (cancel-order,
cancel-all-orders, modify-order, update-leverage, update-margin with a
negative USDCAmount, and ChangePubKey / L2 tx type 8). ChangePubKey's golden
`L1Sig` is empty because that field is not part of the zk hash; the helper
injects a caller-supplied L1 signature string after `SignChangePubKey`. It
does not compile `csrc/helper.c` or send Port frames.

The helper never receives an L1 private key. Elixir produces the EIP-191
signature and passes the finished `0x` string as an input parameter. Derive
the 40-byte zk public key from an API private key with
`LIGHTER_SIGNER_API_PRIVATE_KEY=<hex> go run ./cmd/derive_pubkey` from this
directory. That program takes the key from the environment and rejects it on
argv: `/proc/<pid>/cmdline` is world-readable, `/proc/<pid>/environ` is not.

`test/bourse/signing/lighter_native_test.exs` runs the built executable through
the BEAM Port boundary. It covers initialization, every supported operation,
response framing, malformed and trailing payloads, invalid protocol dispatch,
helper termination, and restart behavior. These tests are tagged `:native`
because they require Go and a C compiler.

`mix bourse.check_lighter_signer` builds and runs the native tests when that
toolchain is available. When `gcov` is present, it also enforces at least 95%
line coverage across the C input parser, frame I/O, operation parsers, and
dispatcher. Output-allocation and dependency-result failure branches remain
outside that metric; successful auth and every transaction response still
cross the real C framing boundary. `mix check.dispatch` invokes the check
against the host target via `mix bourse.build_lighter_signer`. There is no
GitHub Actions workflow and no automated cross-compile matrix: building for
a non-host target, or running `govulncheck` against the pinned Go module, is
a manual step an operator runs by hand when it's needed.
