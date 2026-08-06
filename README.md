# bourse

Elixir client library for ten provider-authored exchange integrations generated
from owned JSON specs via compile-time macros.

**Status:** the runtime support contract is the ten venues listed below.

## Installation

```elixir
def deps do
  [
    {:bourse, "~> 0.2"}
  ]
end
```

### Lighter private signing

Lighter private endpoints use a host-native helper compiled from the packaged
Go and C sources. Install Go 1.23.1 and a C compiler, then build the helper in
the consuming Mix project before making private Lighter calls or assembling a
release:

```bash
mix ccxt.build_lighter_signer
```

Public Lighter market-data calls do not require the helper. The package does
not ship prebuilt native binaries.

## Quick Start

```elixir
# Public market data (no credentials)
{:ok, exchange} = Bourse.Exchange.new("bybit")
{:ok, ticker} = Bourse.fetch_ticker(exchange, "BTC/USDT")

# Authenticated private call
{:ok, exchange} =
  Bourse.Exchange.new("bybit",
    api_key: System.fetch_env!("BYBIT_API_KEY"),
    secret: System.fetch_env!("BYBIT_API_SECRET")
  )

{:ok, balance} = Bourse.fetch_balance(exchange)
```

## Supported Exchanges

Runtime support is closed and invariant across builds. Every supported venue
loads one complete owned spec; the version-pinned CCXT corpus retained in the
source repository is reference material for authoring and compatibility tests,
not runtime support.

| Exchange | Role | Markets |
| --- | --- | --- |
| `alpaca` | US-equity data and paper-trading venue | US equities, news, FX rates |
| `binance` | Perp-hedge venue (spot) | Spot |
| `binancecoinm` | Perp-hedge venue (COIN-M) | Inverse perpetuals and dated futures |
| `binanceusdm` | Perp-hedge venue (USDⓈ-M) | Linear perpetuals |
| `bybit` | Options venue | Spot, linear/inverse perps, options |
| `deribit` | Options venue | Options, futures, spot |
| `derive` | Options venue (DEX) | On-chain options on Optimism |
| `hyperliquid` | Perp-hedge venue (DEX) | On-chain perpetuals |
| `lighter` | Perp-hedge venue (DEX) | On-chain perpetuals |
| `okx` | Options venue | Spot, swaps, options |

```elixir
Bourse.Registry.exchanges()
#=> ["alpaca", "binance", "binancecoinm", "binanceusdm", "bybit",
#=>  "deribit", "derive", "hyperliquid", "lighter", "okx"]

Bourse.Exchange.new("kraken")
#=> {:error, {:unsupported_exchange, "kraken"}}
```

## Migrating from `ccxt_client`

`bourse` is the breaking rename of the former `ccxt_client` package. Change
the dependency name to `:bourse`, replace the `CCXT` module prefix with
`Bourse`, move application configuration from `:ccxt_client` to `:bourse`, and
rename app-specific `CCXT_*` environment variables to `BOURSE_*`.

Consumers that cannot migrate in the same release can remain on the final
CCXT-namespaced line with `{:ccxt_client, "~> 0.6.1"}` until their namespace
change lands. Every `ccxt_client` release is retired as `renamed`, so that
dependency resolves with a deprecation warning and receives no further updates.

## Two Contracts

`bourse` exposes two API surfaces with different stability guarantees.

### Raw Endpoints — Stable

Per-exchange generated functions that pass through to the exchange API unchanged. Signing, rate limiting, circuit breakers, and transport are handled; the response body is returned as-is.

```elixir
{:ok, exchange} = Bourse.Exchange.new("bybit", api_key: key, secret: secret)
{:ok, response} = Bourse.Bybit.public_get_v5_market_tickers(exchange, %{category: "spot"})
```

Recommended for agents, automated trading, and any consumer that wants to interpret exchange responses directly.

### Unified API — Evolving

Standardized cross-exchange methods return the unified structs declared by each
owned venue spec where that method is supported.

```elixir
{:ok, ticker} = Bourse.fetch_ticker(exchange, "BTC/USDT")
```

Capability and routing introspection are available through
`Bourse.Exchange.has?/2` and each generated module's `__unified_endpoints__/0`.

### WebSocket — Early

```elixir
{:ok, ws} = Bourse.WS.connect(exchange, :public)
:ok = Bourse.WS.subscribe(ws, ["tickers.BTCUSDT"])
# Messages arrive at the calling process as {:websocket_message, decoded_map}
Bourse.WS.close(ws)
```

Thin wrapper over [`zen_websocket`](https://hex.pm/packages/zen_websocket)
driven by authored per-exchange subscription and auth patterns. Callers pass
exchange-native channel strings.

A `:private` connection authenticates before it is returned, so a socket you
hold is one the venue accepted:

```elixir
{:ok, ws} = Bourse.WS.connect(exchange, :private)
:ok = Bourse.WS.subscribe(ws, ["order"])
```

A rejected handshake closes the socket and returns the venue's reason rather
than a connection that would deliver nothing. `binance` and `binanceusdm` need a
REST round-trip first and report `{:error, {:pre_auth_required, _}}`; `derive`
has no authored handshake yet and connects without one.

## Known Caveats

Consumer-facing gotchas not obvious from the API signatures. Full context in
[CLAUDE.md](https://github.com/ZenHive/bourse/blob/main/CLAUDE.md).

- **`has?/2` is support introspection, while endpoint mapping is the dispatch
  gate.** Cross-check a venue's generated `__unified_endpoints__/0` when choosing
  among multiple native endpoint families.

- **Signing is a closed authored contract.** HMAC venues execute their authored
  deterministic recipes. Derive, Hyperliquid, and Lighter use bundled
  first-party signers. Consumers cannot register a reference-only exchange or
  inject a long-tail signer. Derive and Hyperliquid expect the EVM private key
  in `credentials.secret`; Lighter uses its documented API signing key.

- **Every supported venue resolves a sandbox, but sandbox *semantics* differ.**
  `Exchange.new(id, sandbox: true)` succeeds for all ten venues; what it selects
  is venue-specific. Some venues swap the host (Alpaca paper trading), some add
  a header to the production host (OKX simulated trading), and some change
  signed payload material (Lighter also switches chain id). A venue's sandbox
  may additionally be read-only or region-restricted for signed writes, which
  surfaces as a business error rather than a transport failure. Check the
  venue's own sandbox documentation before treating a sandbox pass as
  production-equivalent.

## Discovery

```elixir
Bourse.describe()                      # Library overview
Bourse.describe(Bourse, :fetch_ticker) # Method signature + params + errors + return shape
Bourse.MCP.tools()                     # MCP tool definitions for agent autodiscovery
Bourse.Registry.exchanges()            # List the ten runtime exchange ids
```

Per-exchange introspection (generated on every exchange module):

```elixir
Bourse.Bybit.__spec__()               # Raw spec map (describe output)
Bourse.Bybit.__endpoints__()          # List of %{path, method, authenticated, weight, ...}
Bourse.Bybit.__signing__()            # %{pattern: :hmac_sha256_headers, config: %{...}}
Bourse.Bybit.__unified_endpoints__()  # Unified-method → endpoint-config mapping
```

## Documentation

- [CHANGELOG.md](CHANGELOG.md) — completed tasks and known limitations
- [BUGS.md](https://github.com/ZenHive/bourse/blob/main/BUGS.md) — the consumer bug queue: what has been reported, what is already fixed, and where to file
- [CLAUDE.md](https://github.com/ZenHive/bourse/blob/main/CLAUDE.md) — architecture, design decisions, internal conventions
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to land code and authored-spec fixes

## Authoring Exchange Changes

This section is for work inside the source repository. The authoring and audit
Mix tasks named below are repo-internal and are not part of the published
package; only `mix ccxt.build_lighter_signer` ships to consumers.

For a supported venue, author the owned spec or normalization slice against the
provider's API behavior and provider-owned documentation. Register the
applicable live recording, accepted-request golden, or recorded exchange error
and keep the `ccxt.oracle_gate` Mix task green. CCXT and ccxt-distill remain
reference/bootstrap material only; they do not establish venue semantics.

An unsupported venue enters through the `ccxt.promote_venue` Mix task; copying a
reference spec into the repository does not make it runtime-supported. See
[CONTRIBUTING.md](CONTRIBUTING.md) and
[docs/authored-specs.md](https://github.com/ZenHive/bourse/blob/main/docs/authored-specs.md).

## Development

Checks for work inside the source repository:

```bash
mix deps.get
mix test.json --quiet
mix dialyzer.json --quiet
mix credo --strict --format json
```

## License

MIT — see [LICENSE](https://github.com/ZenHive/bourse/blob/main/LICENSE).
