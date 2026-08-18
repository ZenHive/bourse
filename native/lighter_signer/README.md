# Lighter native signer

Private Lighter requests use a host-native helper linked to the pinned official
Go signing library. Build it with Go 1.25.0 (the version `go.mod` requires) and
a C compiler:

```bash
mix ccxt.build_lighter_signer
```

The Mix task reads the packaged sources from the `bourse` dependency and
writes the host helper beneath the application's `priv/native/lighter_signer/`
directory. Prebuilt binaries are not distributed.

## Verification boundary

`golden_test.go` tests the pinned Go cryptography directly. Its vectors cover
the primitive public key and signature, auth-token construction, create-order,
and the five remaining C-exposed transaction constructors (cancel-order,
cancel-all-orders, modify-order, update-leverage, and update-margin with a
negative USDCAmount). It does not compile `csrc/helper.c` or send Port frames.

`test/bourse/signing/lighter_native_test.exs` runs the built executable through
the BEAM Port boundary. It covers initialization, every supported operation,
response framing, malformed and trailing payloads, invalid protocol dispatch,
helper termination, and restart behavior. These tests are tagged `:native`
because they require Go and a C compiler.

`mix ccxt.check_lighter_signer` builds and runs the native tests when that
toolchain is available. When `gcov` is present, it also enforces at least 95%
line coverage across the C input parser, frame I/O, operation parsers, and
dispatcher. Output-allocation and dependency-result failure branches remain
outside that metric; successful auth and every transaction response still
cross the real C framing boundary. `mix check.dispatch` invokes the check, while
`.github/workflows/lighter-signer.yml` provides the mandatory four-target
build and native-test matrix.
