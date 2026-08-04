defmodule Bourse.Test.Generator.PublicEndpointProbe do
  @moduledoc """
  Compile-time generator for per-exchange public-pipeline probe tests (Task 40).

  Usage:

      defmodule Bourse.PublicEndpointProbeTest do
        use ExUnit.Case, async: false
        @moduletag :network
        @moduletag :public_probe
        use Bourse.Test.Generator.PublicEndpointProbe
      end

  At compile time, iterates `Bourse.Registry.exchanges/0`, resolves each
  exchange's generated module, and emits one `test` per exchange for which a
  zero-arg public unified method is available. Public endpoints bypass signing;
  the surface under test is strictly URL resolution + path
  interpolation + transport + response parsing + error classification.

  Candidate methods (in priority order — first match wins):

    * `:fetch_time` — no params, most universally supported
    * `:fetch_currencies` — no params
    * `:fetch_markets` — no params

  `:fetch_ticker` is deliberately excluded from v1: it requires a per-exchange
  symbol and is tracked for follow-up.

  The generated test body:

    1. Builds `%Bourse.Exchange{}` via `Bourse.Exchange.new!/1` (no credentials).
    2. Invokes the chosen unified method via `apply(Bourse, method, [exchange])`.
    3. Delegates to `Bourse.IntegrationHelper.assert_public_response/3`, which
       treats rate-limit, network, and exchange-unavailable errors as
       inconclusive (logged, not flunked) and flunks on structural issues.

  File-level `@moduletag :network` on the consuming test module gates the
  suite behind `--only network`; `mix test.json` without flags skips it.
  """

  alias Bourse.Registry

  # Zero-arg public methods. Order matters — we pick the first that resolves to
  # at least one unauthenticated endpoint config on a given exchange.
  @candidate_methods [:fetch_time, :fetch_currencies, :fetch_markets]

  defmacro __using__(_opts) do
    exchanges = collect_exchanges()

    test_blocks =
      for {exchange_id, _module, method} <- exchanges do
        build_test(exchange_id, method)
      end

    # Moduletags MUST be emitted from inside the generator's quote — if they
    # lived in the consumer test file after `use ...PublicEndpointProbe`, they
    # would not attach to the already-registered tests (ExUnit reads
    # `@ex_unit_moduletag` at each `test` macro expansion, not retroactively).
    # Emitting them here also survives Styler's `use`-grouping rewrites in
    # the consumer file.
    quote do
      require Logger

      @moduletag :network
      @moduletag :public_probe

      unquote_splicing(test_blocks)
    end
  end

  @doc false
  # Offline sanity helper — call from IEx to see which exchanges made the cut
  # and which got filtered out, before running any network traffic.
  def __collect_for_inspection__, do: collect_exchanges()

  # Compile-time exchange filter. Returns `[{id, module, method}]` for every
  # exchange where (1) the module is compiled and (2) at least one candidate
  # method resolves to an endpoint config list whose entries are all marked
  # `authenticated: false`.
  defp collect_exchanges do
    Registry.exchanges()
    |> Enum.map(fn id ->
      module = Registry.module_for(id)
      method = if module, do: pick_public_method(module)
      {id, module, method}
    end)
    |> Enum.filter(fn {_id, module, method} -> module != nil and method != nil end)
  end

  defp pick_public_method(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__unified_endpoint__, 1) do
      Enum.find(@candidate_methods, fn method ->
        configs = module.__unified_endpoint__(method)
        configs != [] and Enum.all?(configs, &(Map.get(&1, :authenticated, false) == false))
      end)
    end
  end

  defp build_test(exchange_id, method) do
    tag_atom = String.to_atom("exchange_#{exchange_id}")
    id_atom = String.to_atom(exchange_id)

    quote do
      @tag :public_probe
      @tag unquote(tag_atom)
      test "#{unquote(exchange_id)} public pipeline via #{unquote(method)}" do
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

        result = apply(Bourse, unquote(method), [exchange])

        Bourse.IntegrationHelper.assert_public_response(unquote(method), result)
      end
    end
  end
end
