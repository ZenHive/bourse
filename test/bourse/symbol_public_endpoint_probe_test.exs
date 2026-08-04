if Bourse.Test.Generator.OptIn.requested?([:network, :public_probe, :symbol_public_probe]) do
  defmodule Bourse.SymbolPublicEndpointProbeTest do
    @moduledoc """
    Task 79 — Symbol-required public-endpoint probe.

    Extends Task 40's `PublicEndpointProbe` to cover `fetch_ticker` and
    `fetch_ohlcv`, which require a symbol argument. Compile-time symbol
    resolution pulls a preferred spot pair (`BTC/USDT` → `ETH/USDT` → …)
    from each frozen reference's test-only market index, falling back to any
    spot / swap / first-market entry.

    Opt-in: file-level `@moduletag :network` (emitted from the generator)
    gates the suite off the default `mix test` run.

        mix test.json --quiet --only network test/bourse/symbol_public_endpoint_probe_test.exs

    Expect a mix of passes, `⚠️  INCONCLUSIVE` warnings for rate-limit /
    Cloudflare cases, and flunks pinpointing exchanges where the symbol-aware
    public pipeline is broken (bad symbol mapping, wrong URL for the
    symbol-scoped endpoint, missing required query param, etc.).
    """

    use ExUnit.Case, async: false
    use Bourse.Test.Generator.SymbolPublicEndpointProbe

    # Module tags are emitted from inside the generator's `__using__/1` quote;
    # declaring them here would not retroactively attach to tests registered
    # by the generator. See `PublicEndpointProbe` for the ordering rationale.
  end
end
