defmodule Bourse.Test.Generator.UnifiedMethodIntegrationProbe do
  @moduledoc """
  Compile-time generator for per-exchange unified-method integration probe
  tests (Task 39).

  ## Usage

      defmodule Bourse.Probes.Unified.BybitPrivateTest do
        use ExUnit.Case, async: false
        use Bourse.Test.Generator.UnifiedMethodIntegrationProbe, exchange: :bybit, auth: :private
      end

  The caller owns the `defmodule` — one module per exchange per auth class
  (`:public`, `:private`). For `:private`, credential availability is decided
  while the test module is generated: registered exchanges get the full
  per-method tests plus a thin runtime `setup_all` backstop; exchanges without
  registered credentials get one missing-credentials flunk test and no
  `setup_all`.

  Sibling to the three existing probes, each of which covers a narrow
  slice:

    * `Bourse.Test.Generator.PublicEndpointProbe` (T40) — zero-arg public
      methods: `fetch_time`, `fetch_currencies`, `fetch_markets`.
    * `Bourse.Test.Generator.SymbolPublicEndpointProbe` (T79) — symbol-required
      public methods: `fetch_ticker`, `fetch_ohlcv`.
    * `Bourse.Test.Generator.InvalidCredsProbe` (T67) — private pipeline shape
      with deliberately-bogus credentials.

  T39 is the gap-fill: covers the public methods those three don't, plus
  the private methods that need **real** testnet credentials to produce a
  conclusive pass/fail.

  ## Method coverage

  Public, zero-arg:

    * `:fetch_status`

  Public, symbol-required (symbol resolved via
  `Bourse.Test.Generator.SymbolResolver`):

    * `:fetch_order_book`
    * `:fetch_trades`
    * `:fetch_funding_rate` — uses `pick_funding_symbol/1` (perpetual only)

  Private (real testnet credentials required):

    * `:fetch_balance`
    * `:fetch_open_orders`
    * `:fetch_my_trades`
    * `:fetch_positions`
    * `:fetch_account`
    * `:fetch_trading_fees` — loads markets first (Deribit `market_fee_rows` transform)

  Write-path methods (`create_order`, `cancel_order`, `withdraw`, …) are
  **deliberately excluded** — they need per-exchange test-asset config
  (symbol, min order size, post-only flag, cancel verification, cleanup)
  that doesn't exist yet. Tracked as a separate roadmap follow-up.

  ## Compile-time emission rules

  For the requested exchange and auth class, emit one test per `(method,
  category)` combination that passes all of:

    * The generated exchange module is compiled.
    * `__unified_endpoint__/1` returns a non-empty config list for the
      method — i.e. the exchange actually maps the method.
    * **Public path:** every config is `authenticated: false`.
    * **Private path:** every config is `authenticated: true`.
    * **Symbol-required methods:** a unified symbol resolves from the spec
      via `SymbolResolver.pick_symbol/1`. Exchanges without markets are
      skipped for those methods only.
    * **Account-identifier methods:** the probe-level requirement map supplies
      the documented identifier.

  ## Tags

  Module-level (attached from inside the generator's quote so they apply
  to tests registered via `unquote_splicing/1`):

    * `:network` — gates default `mix test` runs (suite excluded).
    * `:unified_integration` — suite-level filter.
    * `:exchange_{id}` — per-exchange filter.

  Per test:

    * `:public` or `:private`

  Run with `mix test.json --include network` or `--only unified_integration`.
  """

  alias Bourse.Exchange
  alias Bourse.Registry
  alias Bourse.Symbol
  alias Bourse.Test.Generator.SymbolResolver

  @public_zero_arg_methods [:fetch_status]

  @public_symbol_methods [:fetch_order_book, :fetch_trades, :fetch_funding_rate]

  @order_book_pair_param_exchanges MapSet.new(["kraken"])

  @private_methods [
    :fetch_balance,
    :fetch_open_orders,
    :fetch_my_trades,
    :fetch_positions,
    :fetch_account,
    :fetch_trading_fees
  ]

  @derive_demo_subaccount_id 144_422
  @lighter_auth_lifetime_seconds 300

  @private_identifier_requirements %{
    {"binance", :fetch_my_trades} => [symbol: :resolved_symbol],
    {"lighter", :fetch_open_orders} => [
      symbol: :resolved_symbol,
      account_index: {:credential, :uid},
      auth_deadline: {:unix_now_plus, @lighter_auth_lifetime_seconds}
    ],
    {"derive", :fetch_my_trades} => [subaccount_id: @derive_demo_subaccount_id],
    {"derive", :fetch_open_orders} => [subaccount_id: @derive_demo_subaccount_id],
    {"derive", :fetch_positions} => [subaccount_id: @derive_demo_subaccount_id]
  }

  @auth_classes [:public, :private]

  defmacro __using__(opts) do
    exchange = Keyword.fetch!(opts, :exchange)
    auth = Keyword.fetch!(opts, :auth)

    if auth not in @auth_classes do
      raise ArgumentError,
            "UnifiedMethodIntegrationProbe: auth must be one of #{inspect(@auth_classes)}, got #{inspect(auth)}"
    end

    exchange_id = to_string(exchange)
    exchange_atom = String.to_atom(exchange_id)

    registered? = auth != :private or Bourse.Testnet.registered?(exchange_atom, :default)

    test_blocks =
      if auth == :private and not registered? do
        [build_missing_credentials_test(exchange_id, exchange_atom)]
      else
        for {kind, ^exchange_id, method, extra} <- cases_for(exchange_id, auth) do
          build_test(kind, exchange_id, method, extra)
        end
      end

    moduletags =
      quote do
        @moduletag :network
        @moduletag :unified_integration
        @moduletag unquote(String.to_atom("exchange_#{exchange_id}"))
      end

    setup_gate =
      if auth == :private and registered? do
        build_setup_gate(exchange_id, exchange_atom)
      end

    quote do
      unquote(moduletags)
      unquote(setup_gate)
      unquote_splicing(test_blocks)
    end
  end

  @doc """
  Returns the compile-time probe selection without running network calls.
  """
  @spec __collect_for_inspection__() :: [{atom(), String.t(), atom(), term()}]
  def __collect_for_inspection__ do
    Enum.flat_map(Registry.exchanges(), fn exchange_id ->
      Enum.flat_map(@auth_classes, &cases_for(exchange_id, &1))
    end)
  end

  # ---------------------------------------------------------------------------
  # Compile-time selection (per exchange, per auth class)
  # ---------------------------------------------------------------------------

  defp cases_for(exchange_id, :public) do
    module = Registry.module_for(exchange_id)

    if module do
      public_zero_cases(exchange_id, module) ++ public_symbol_cases(exchange_id, module)
    else
      []
    end
  end

  defp cases_for(exchange_id, :private) do
    module = Registry.module_for(exchange_id)

    if module do
      private_cases(exchange_id, module)
    else
      []
    end
  end

  defp public_zero_cases(exchange_id, module) do
    for method <- @public_zero_arg_methods, available_public?(module, method) do
      {:public_zero, exchange_id, method, nil}
    end
  end

  defp public_symbol_cases(exchange_id, module) do
    for method <- @public_symbol_methods,
        available_public?(module, method),
        symbol = symbol_for(exchange_id, method),
        is_binary(symbol) do
      {:public_symbol, exchange_id, method, public_symbol_args(exchange_id, method, symbol)}
    end
  end

  defp symbol_for(exchange_id, :fetch_funding_rate), do: SymbolResolver.pick_funding_symbol(exchange_id)
  defp symbol_for(exchange_id, _method), do: SymbolResolver.pick_symbol(exchange_id)

  @doc """
  Builds the positional args used by public symbol-method probe calls.
  """
  @spec public_symbol_args(String.t(), atom(), String.t()) :: [term()]
  def public_symbol_args(exchange_id, :fetch_order_book, symbol) when is_binary(exchange_id) and is_binary(symbol) do
    if MapSet.member?(@order_book_pair_param_exchanges, exchange_id) do
      [symbol, [pair: native_symbol(exchange_id, symbol)]]
    else
      [symbol]
    end
  end

  def public_symbol_args(_exchange_id, _method, symbol) when is_binary(symbol), do: [symbol]

  defp private_cases(exchange_id, module) do
    for method <- @private_methods,
        available_private?(module, method),
        args = private_args(exchange_id, method),
        is_list(args) do
      {:private, exchange_id, method, args}
    end
  end

  defp private_args(exchange_id, method) do
    case Map.fetch(@private_identifier_requirements, {exchange_id, method}) do
      {:ok, params} ->
        private_args_for_requirements(exchange_id, params)

      :error ->
        []
    end
  end

  defp private_args_for_requirements(exchange_id, params) do
    case Keyword.get(params, :symbol) do
      :resolved_symbol -> private_symbol_args(exchange_id, params)
      _other -> [params]
    end
  end

  defp private_symbol_args(exchange_id, params) do
    case SymbolResolver.pick_symbol(exchange_id) do
      symbol when is_binary(symbol) -> [Keyword.replace!(params, :symbol, symbol)]
      nil -> nil
    end
  end

  defp available_public?(module, method), do: available?(module, method, false)

  defp available_private?(module, method), do: available?(module, method, true)

  defp available?(module, method, expected_auth) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__unified_endpoint__, 1),
         [_ | _] = configs <- module.__unified_endpoint__(method) do
      Enum.all?(configs, &(Map.get(&1, :authenticated, false) == expected_auth))
    else
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # setup_all gate (registered private modules only)
  # ---------------------------------------------------------------------------

  defp build_setup_gate(exchange_id, exchange_atom) do
    quote do
      setup_all do
        exchange_atom = unquote(exchange_atom)
        exchange_id = unquote(exchange_id)

        passphrase? =
          case Bourse.Exchange.new(exchange_atom) do
            {:ok, ex} -> ex.required_credentials["password"] == true
            _ -> false
          end

        if !Bourse.Testnet.registered?(exchange_atom, :default) do
          raise Bourse.IntegrationHelper.missing_credentials_message(exchange_atom, :default, passphrase: passphrase?)
        end

        try do
          _ = Bourse.Exchange.new!(exchange_atom, sandbox: true)
        rescue
          err in ArgumentError ->
            msg = Exception.message(err)

            if msg =~ "no testnet data" do
              reraise """
                      #{exchange_id}: no testnet data per spec — skipping private probes.
                        #{msg}
                      """,
                      __STACKTRACE__
            else
              reraise err, __STACKTRACE__
            end
        end

        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test emission
  # ---------------------------------------------------------------------------

  defp build_missing_credentials_test(exchange_id, exchange_atom) do
    passphrase? = passphrase_required?(exchange_atom)

    quote do
      @tag :private
      test "#{unquote(exchange_id)} private missing testnet credentials" do
        flunk(
          Bourse.IntegrationHelper.missing_credentials_message(unquote(exchange_atom), :default,
            passphrase: unquote(passphrase?)
          )
        )
      end
    end
  end

  defp passphrase_required?(exchange_atom) do
    with module when is_atom(module) <- Registry.module_for(Atom.to_string(exchange_atom)),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__spec__, 0),
         %{} = describe <- map_get(module.__spec__(), "describe"),
         %{} = required <- map_get(describe, "requiredCredentials") do
      required["password"] == true
    else
      _ -> false
    end
  end

  defp map_get(%{} = map, key), do: Map.get(map, key)
  defp map_get(_value, _key), do: nil

  defp build_test(:public_zero, exchange_id, method, _extra) do
    id_atom = String.to_atom(exchange_id)

    quote do
      @tag :public
      test "#{unquote(exchange_id)} public #{unquote(method)}" do
        exchange =
          unquote(__MODULE__).__build_public_exchange__(unquote(id_atom), unquote(exchange_id))

        result = apply(Bourse, unquote(method), [exchange])
        Bourse.IntegrationHelper.assert_public_response(unquote(method), result)
      end
    end
  end

  defp build_test(:public_symbol, exchange_id, method, args) do
    id_atom = String.to_atom(exchange_id)
    symbol = List.first(args)
    escaped_args = Macro.escape(args)

    quote do
      @tag :public
      test "#{unquote(exchange_id)} public #{unquote(method)} via #{unquote(symbol)}" do
        exchange =
          unquote(__MODULE__).__build_public_exchange__(unquote(id_atom), unquote(exchange_id))

        result = apply(Bourse, unquote(method), [exchange | unquote(escaped_args)])
        Bourse.IntegrationHelper.assert_public_response(unquote(method), result)
      end
    end
  end

  defp build_test(:private, exchange_id, method, args) do
    id_atom = String.to_atom(exchange_id)
    load_markets? = method == :fetch_trading_fees
    escaped_args = Macro.escape(args)

    quote do
      @tag :private
      test "#{unquote(exchange_id)} private #{unquote(method)} with real creds" do
        creds = Bourse.IntegrationHelper.require_credentials!(unquote(id_atom))

        exchange =
          Bourse.IntegrationHelper.build_exchange(unquote(id_atom),
            credentials: creds,
            sandbox: true
          )

        exchange =
          unquote(__MODULE__).__maybe_load_markets__(
            exchange,
            unquote(exchange_id),
            unquote(load_markets?)
          )

        call_args =
          unquote(__MODULE__).__resolve_private_args__(
            exchange,
            unquote(escaped_args)
          )

        result = apply(Bourse, unquote(method), [exchange | call_args])

        Bourse.IntegrationHelper.assert_private_response(
          unquote(method),
          result,
          venue: unquote(exchange_id)
        )
      end
    end
  end

  @doc false
  @spec __resolve_private_args__(Exchange.t(), [keyword()]) :: [keyword()]
  def __resolve_private_args__(%Exchange{} = exchange, args) when is_list(args) do
    Enum.map(args, fn params ->
      Enum.map(params, &resolve_runtime_identifier(&1, exchange))
    end)
  end

  defp resolve_runtime_identifier({name, {:credential, :uid}}, exchange) do
    {name, credential_uid!(exchange)}
  end

  defp resolve_runtime_identifier({name, {:unix_now_plus, seconds}}, _exchange) do
    {name, System.system_time(:second) + seconds}
  end

  defp resolve_runtime_identifier(param, _exchange), do: param

  defp credential_uid!(%Exchange{credentials: %{uid: uid}}) when is_binary(uid), do: String.to_integer(uid)

  defp credential_uid!(_exchange) do
    raise ArgumentError, "private probe requires a numeric credential uid"
  end

  @doc """
  Optionally loads markets before a private probe that expands over the cache
  (Deribit `market_fee_rows` for `fetch_trading_fees`).
  """
  @spec __maybe_load_markets__(Exchange.t(), String.t(), boolean()) :: Exchange.t() | no_return()
  def __maybe_load_markets__(exchange, _exchange_id, false), do: exchange

  def __maybe_load_markets__(exchange, exchange_id, true) do
    case Bourse.load_markets(exchange) do
      {:ok, loaded} ->
        loaded

      {:error, %_{} = reason} ->
        ExUnit.Assertions.flunk("""
        #{exchange_id}: load_markets failed before private probe:
          #{Exception.message(reason)}
        """)

      {:error, reason} ->
        ExUnit.Assertions.flunk("""
        #{exchange_id}: load_markets failed before private probe:
          #{inspect(reason)}
        """)
    end
  end

  @doc """
  Constructs an `%Exchange{}` for a public-path probe test. Public so the
  macro-generated test bodies can call it; kept out of `defp` so the
  `Exchange.new!` raise path can be traced during debugging.
  """
  @spec __build_public_exchange__(atom(), String.t()) :: Exchange.t() | no_return()
  def __build_public_exchange__(id_atom, exchange_id) do
    Exchange.new!(id_atom)
  rescue
    err ->
      ExUnit.Assertions.flunk("""
      #{exchange_id}: Exchange.new! raised — not a transport failure:
        #{Exception.message(err)}
      """)
  end

  defp native_symbol(exchange_id, symbol) do
    exchange_id
    |> Exchange.new!()
    |> then(&Symbol.to_exchange_id(symbol, &1))
  end
end
