defmodule Bourse.Test.Generator.SymbolPublicEndpointProbe do
  @moduledoc """
  Compile-time generator for per-exchange public-pipeline probe tests on
  symbol-required methods (Task 79).

  Sibling of `Bourse.Test.Generator.PublicEndpointProbe` — that one covers
  zero-arg public methods (`fetch_time`, `fetch_currencies`, `fetch_markets`).
  This one extends coverage to `fetch_ticker` and `fetch_ohlcv` by resolving
  a test symbol per exchange from the spec's `runtime.symbols_index` map.

  Usage:

      defmodule Bourse.SymbolPublicEndpointProbeTest do
        use ExUnit.Case, async: false
        use Bourse.Test.Generator.SymbolPublicEndpointProbe
      end

  ## Symbol resolution (compile time)

  Delegated to `Bourse.Test.Generator.SymbolResolver.pick_symbol/1` — shared
  with `Bourse.Test.Generator.UnifiedMethodIntegrationProbe` (Task 39). Returns
  `nil` when a spec has no markets; the exchange is skipped.

  ## Method coverage

    * `:fetch_ticker` — requires `[symbol]`
    * `:fetch_ohlcv` — requires `[symbol, "1m"]` (timeframe baked in; every
      each spec exposes `"1m"` in `runtime.describe.timeframes`)

  An exchange is included for a method only when:

    * the generated module exposes the unified endpoint (non-empty
      `__unified_endpoint__/1`)
    * every endpoint config is `authenticated: false`
    * a symbol resolves from the spec

  Public endpoints bypass signing entirely. Assertions delegate to
  `Bourse.IntegrationHelper.assert_public_response/3`, which treats rate-limit /
  network / exchange-unavailable / Cloudflare errors as inconclusive.

  File-level `@moduletag :network` is emitted from inside the generator
  (same reason as `PublicEndpointProbe`: ExUnit reads module tags at each
  `test` macro expansion).
  """

  alias Bourse.Registry
  alias Bourse.Test.Generator.SymbolResolver

  # TODO: per-exchange timeframe override — every spec currently
  # declares "1m" in runtime.describe.timeframes. Revisit when a spec breaks this.
  @ohlcv_timeframe "1m"

  @candidate_methods [
    {:fetch_ticker, &__MODULE__.ticker_args/1},
    {:fetch_ohlcv, &__MODULE__.ohlcv_args/1}
  ]

  defmacro __using__(_opts) do
    cases = collect_cases()

    test_blocks =
      for {exchange_id, method, args, symbol} <- cases do
        build_test(exchange_id, method, args, symbol)
      end

    quote do
      require Logger

      @moduletag :network
      @moduletag :public_probe
      @moduletag :symbol_public_probe

      unquote_splicing(test_blocks)
    end
  end

  @doc """
  Offline sanity helper — returns the compile-time selection as a flat list
  of `{exchange_id, method, args, symbol}` tuples for IEx inspection, without
  running any network traffic.
  """
  def __collect_for_inspection__, do: collect_cases()

  @doc "Arg builder for `:fetch_ticker` — captured in `@candidate_methods`."
  def ticker_args(symbol), do: [symbol]

  @doc "Arg builder for `:fetch_ohlcv` — captured in `@candidate_methods`."
  def ohlcv_args(symbol), do: [symbol, @ohlcv_timeframe]

  # ---------------------------------------------------------------------------
  # Compile-time selection
  # ---------------------------------------------------------------------------

  defp collect_cases do
    for exchange_id <- Registry.exchanges(),
        module = Registry.module_for(exchange_id),
        module != nil,
        symbol = SymbolResolver.pick_symbol(exchange_id),
        symbol != nil,
        {method, arg_builder} <- @candidate_methods,
        available_public?(module, method) do
      {exchange_id, method, arg_builder.(symbol), symbol}
    end
  end

  defp available_public?(module, method) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__unified_endpoint__, 1),
         [_ | _] = configs <- module.__unified_endpoint__(method) do
      Enum.all?(configs, &(Map.get(&1, :authenticated, false) == false))
    else
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Test emission
  # ---------------------------------------------------------------------------

  defp build_test(exchange_id, method, args, symbol) do
    tag_atom = String.to_atom("exchange_#{exchange_id}")
    id_atom = String.to_atom(exchange_id)

    quote do
      @tag :symbol_public_probe
      @tag unquote(tag_atom)
      test "#{unquote(exchange_id)} public #{unquote(method)} via #{unquote(symbol)}" do
        exchange =
          try do
            Bourse.Exchange.new!(unquote(id_atom))
          rescue
            err ->
              flunk("""
              #{unquote(exchange_id)}: Exchange.new! raised — not a transport failure:
                #{Exception.message(err)}
              """)
          end

        result = apply(Bourse, unquote(method), [exchange | unquote(args)])

        Bourse.IntegrationHelper.assert_public_response(unquote(method), result)
      end
    end
  end
end
