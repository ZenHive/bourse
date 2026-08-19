defmodule Bourse.EmulationTest do
  use ExUnit.Case, async: true

  alias Bourse.Emulation
  alias Bourse.Exchange
  alias Bourse.Extract.EmulatedMethods
  alias Bourse.Spec

  @emulation_path "lib/bourse/emulation.ex"
  @external_resource @emulation_path
  @sample_ticker_last 42_000
  @higher_precision_digits 8
  @lower_precision_digits 2
  @passthrough_until 1_700_003_600_000
  @passthrough_native "venue-native-passthrough"

  defmodule ExchangeStub do
    @moduledoc false

    @spec __unified_endpoint__(atom()) :: [map()]
    def __unified_endpoint__(method) do
      {__MODULE__, :endpoints}
      |> Process.get(%{})
      |> Map.get(method, [])
    end

    @spec configure_endpoints!(MapSet.t(atom())) :: :ok
    def configure_endpoints!(methods) do
      endpoints = Map.new(methods, &{&1, [%{authenticated: false}]})
      Process.put({__MODULE__, :endpoints}, endpoints)
      :ok
    end
  end

  setup do
    Process.delete({ExchangeStub, :endpoints})
    :ok
  end

  describe "dispatch" do
    test "returns invalid_parameters when context is missing exchange module" do
      {exchange_id, method, scope} = sample_emulated_method()
      exchange = build_exchange(exchange_id)

      assert Emulation.emulated?(exchange, method, scope)

      assert {:error, %Bourse.Error{type: :invalid_parameters}} =
               Emulation.dispatch(exchange, method, scope, %{})
    end

    test "returns invalid_parameters when exchange_module is nil" do
      {exchange_id, method, scope} = sample_emulated_method()
      exchange = build_exchange(exchange_id)

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               Emulation.dispatch(exchange, method, scope, %{exchange_module: nil})

      assert String.contains?(message, "missing exchange module")
    end

    test "returns passthrough for non-emulated methods" do
      {exchange_id, _method, scope} = sample_emulated_method()
      exchange = build_exchange(exchange_id)

      refute Emulation.emulated?(exchange, :__not_emulated__, scope)
      assert :passthrough == Emulation.dispatch(exchange, :__not_emulated__, scope, %{})
    end
  end

  describe "dispatch for unimplemented methods" do
    test "returns not_supported with reason suffix when handler is missing" do
      case find_unimplemented_entry() do
        nil ->
          flunk("""
          No unimplemented emulated methods found.

          Either all emulated methods are implemented or extraction data is empty.
          Check emulated-methods catalog / extraction coverage for this build.
          """)

        {exchange_id, method, scope, entry} ->
          exchange = build_exchange(exchange_id)

          assert {:error, %Bourse.Error{type: :not_supported, message: message}} =
                   Emulation.dispatch(exchange, method, scope, %{
                     exchange_module: ExchangeStub,
                     params: %{},
                     opts: []
                   })

          assert String.contains?(message, Atom.to_string(method))

          reasons = Map.get(entry, "reasons", [])

          if reasons == [] do
            refute String.contains?(message, "(")
          else
            assert String.contains?(message, Enum.join(reasons, ", "))
          end
      end
    end
  end

  describe "handler boundary coverage" do
    test "locally selected reads reject absent required selectors" do
      for method <- [
            :fetch_deposit_withdraw_fee,
            :fetch_funding_interval,
            :fetch_isolated_borrow_rate,
            :fetch_leverage,
            :fetch_margin_mode,
            :fetch_market_leverage_tiers
          ] do
        assert {:error, %Bourse.Error{type: :invalid_parameters}} =
                 dispatch_declared(method, %{}, fn _method, _params ->
                   flunk("#{method} delegated without its required selector")
                 end)
      end
    end

    test "deposit address emulation reports missing rows from either delegated source" do
      for endpoint <- [:fetch_deposit_addresses, :fetch_deposit_addresses_by_network] do
        ExchangeStub.configure_endpoints!(MapSet.new([endpoint]))

        assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
                 dispatch_declared(
                   :fetch_deposit_address,
                   %{"code" => "BTC", "network" => "ERC20"},
                   fn ^endpoint, _params -> {:ok, %{}} end
                 )

        assert message =~ "could not find a deposit address for BTC"
      end
    end

    test "ticker emulation handles opaque and unkeyed delegated payloads" do
      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_tickers, :fetch_markets]))

      assert {:error, %Bourse.Error{type: :exchange_error}} =
               dispatch_declared(:fetch_ticker, %{"symbol" => "BTC/USDT"}, fn
                 :fetch_tickers, _params -> {:ok, :opaque}
                 method, _params -> flunk("unexpected delegated method: #{method}")
               end)

      assert {:ok, %{symbol: "BTC/USDT"}} =
               dispatch_declared(:fetch_ticker, %{"symbol" => "BTC/USDT"}, fn
                 :fetch_tickers, _params ->
                   {:ok, %{"BTCUSDT" => %{symbol: nil, last: @sample_ticker_last}}}

                 :fetch_markets, _params ->
                   {:ok, [%{symbol: "BTC/USDT"}]}
               end)
    end

    test "trade-id extraction ignores unsupported identifiers" do
      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_my_trades]))

      assert {:ok, [%{id: "trade-1"}]} =
               dispatch_declared(
                 :fetch_order_trades,
                 %{"id" => "order-1", "trades" => [%{"id" => "trade-1"}, :unsupported]},
                 fn :fetch_my_trades, _params -> {:ok, [%{id: "trade-1"}, %{id: "trade-2"}]} end
               )
    end

    test "transaction emulation reads legacy transactType and propagates delegated errors" do
      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_ledger]))

      assert {:ok, [%{"transactType" => "deposit"}]} =
               dispatch_declared(:fetch_transactions, %{}, fn :fetch_ledger, _params ->
                 {:ok, [%{"transactType" => "deposit"}, %{"transactType" => "trade"}]}
               end)

      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_deposits, :fetch_withdrawals]))

      assert {:error, :delegated_failure} =
               dispatch_declared(:fetch_transactions, %{}, fn
                 :fetch_deposits, _params -> {:error, :delegated_failure}
                 method, _params -> flunk("unexpected delegated method after failure: #{method}")
               end)
    end

    test "currency emulation tolerates missing and non-numeric precision" do
      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_markets]))

      markets = [
        %{symbol: nil, base: nil, quote: "USDT", precision: %{quote: "unknown"}},
        %{
          symbol: "BTC/USDT",
          base: "BTC",
          quote: "USDT",
          precision: %{base: @higher_precision_digits, quote: @lower_precision_digits}
        }
      ]

      assert {:ok,
              %{
                "BTC" => %{precision: @higher_precision_digits},
                "USDT" => %{precision: @lower_precision_digits}
              }} =
               dispatch_declared(:fetch_currencies, %{}, fn :fetch_markets, _params ->
                 {:ok, markets}
               end)
    end

    test "delegated payload edge cases retain their documented local semantics" do
      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_orders]))

      assert {:ok, []} =
               dispatch_declared(:fetch_my_trades, %{}, fn :fetch_orders, _params -> {:ok, []} end)

      assert {:ok, []} =
               dispatch_declared(:fetch_closed_orders, %{}, fn :fetch_orders, _params ->
                 {:ok, [7]}
               end)

      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_positions]))

      assert {:ok, nil} =
               dispatch_declared(:fetch_position, %{}, fn :fetch_positions, _params -> {:ok, []} end)

      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_deposit_withdraw_fees]))

      assert {:ok, nil} =
               dispatch_declared(:fetch_deposit_withdraw_fee, %{"code" => "BTC"}, fn
                 :fetch_deposit_withdraw_fees, _params -> {:ok, []}
               end)
    end
  end

  describe "delegated parameter surface" do
    test "every emulated capability reaches only caller-derived delegated params" do
      ast = emulation_ast()
      definitions = function_definitions(ast)
      dispatch_handlers = module_attribute!(ast, :dispatch_handlers)
      delegated_handlers = delegated_handlers(definitions)

      assert delegated_params_reads_register?(definitions),
             "delegated_params/4 no longer reads @consumed_delegated_params; the drop register is documentation-only"

      for handler <- delegated_handlers,
          site <- call_method_sites(definitions, handler) do
        assert derived_from_incoming_params?(site.params),
               "#{handler} reaches call_method/5 at line #{site.line} with params not derived " <>
                 "from its incoming params: #{Macro.to_string(site.params)}"
      end

      for handler <- delegated_handlers,
          rebinding <- params_rebindings(definitions, handler) do
        flunk(
          "#{handler} rebinds incoming params at line #{rebinding.line}: " <>
            Macro.to_string(rebinding.ast)
        )
      end

      for {venue, js_name} <- emulated_capability_pairs() do
        method = capability_method!(js_name)
        handler = Map.fetch!(dispatch_handlers, method)

        assert handler in delegated_handlers,
               "#{venue}.#{js_name}=emulated is not covered by the delegated-param handler scan"
      end
    end

    test "every deliberately consumed param is documented and the register has no stale entries" do
      ast = emulation_ast()
      definitions = function_definitions(ast)
      consumed = module_attribute!(ast, :consumed_delegated_params)

      for {{handler, method}, params} <- consumed do
        assert method in delegation_methods(definitions, handler),
               "stale consumed-param entry: #{handler} no longer delegates #{method}"

        extracted = extracted_params(definitions, handler)

        for {param, reason} <- params do
          assert is_binary(reason) and String.trim(reason) != "",
                 "#{handler} -> #{method} drops #{param} without a reason"

          assert param in extracted,
                 "stale consumed-param entry: #{handler} no longer consumes #{param}"
        end
      end
    end

    test "unknown caller params survive filtered-order delegation" do
      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_orders]))

      assert {:ok, []} =
               dispatch_declared(
                 :fetch_closed_orders,
                 %{
                   "until" => @passthrough_until,
                   "venueNative" => @passthrough_native,
                   "limit" => 5
                 },
                 fn :fetch_orders, params ->
                   assert params["until"] == @passthrough_until
                   assert params["venueNative"] == @passthrough_native
                   assert params["limit"] == 5
                   {:ok, []}
                 end
               )
    end

    test "consumed selectors are stripped before the nested read" do
      ExchangeStub.configure_endpoints!(MapSet.new([:fetch_orders]))

      assert {:error, %Bourse.Error{type: :order_not_found}} =
               dispatch_declared(
                 :fetch_order,
                 %{
                   "id" => "missing-order",
                   "until" => @passthrough_until,
                   "venueNative" => @passthrough_native
                 },
                 fn :fetch_orders, params ->
                   refute Map.has_key?(params, "id")
                   refute Map.has_key?(params, :id)
                   assert params["until"] == @passthrough_until
                   assert params["venueNative"] == @passthrough_native
                   {:ok, []}
                 end
               )
    end
  end

  describe "method_atom/1" do
    test "resolves extractor REST names via the validated Unified method map" do
      assert Emulation.method_atom("fetchFundingRate") == :fetch_funding_rate
      assert Emulation.method_atom("fetchCanceledAndClosedOrders") == :fetch_canceled_and_closed_orders
      assert Emulation.method_atom("fetchOpenInterest") == :fetch_open_interest
    end

    test "resolves extractor WS names that are not in method_defs" do
      assert Emulation.method_atom("watchLiquidations") == :watch_liquidations
      assert Emulation.method_atom("watchMyLiquidations") == :watch_my_liquidations
      assert Emulation.method_atom("watchPosition") == :watch_position
    end

    test "returns nil for unknown names instead of minting atoms" do
      assert Emulation.method_atom("notARealMethod") == nil
      assert Emulation.method_atom("fetchDefinitelyMissing") == nil
      assert Emulation.method_atom(nil) == nil
      assert Emulation.method_atom(:already_an_atom) == nil
    end

    test "indexes every owned emulated method name" do
      Emulation.reload!()

      for exchange_id <- EmulatedMethods.exchanges(),
          entry <- EmulatedMethods.methods_for(exchange_id) do
        name = Map.fetch!(entry, "name")
        method = Emulation.method_atom(name)
        scope = entry_scope(entry)

        assert is_atom(method),
               "extractor name #{inspect(name)} on #{exchange_id} failed to resolve to an atom"

        exchange = build_exchange(exchange_id)

        assert Emulation.emulated?(exchange, method, scope),
               "#{exchange_id} #{method} (#{scope}) should be indexed as emulated"
      end
    end
  end

  @doc false
  # Builds a minimal Spec struct for emulation lookup.
  defp build_exchange(exchange_id) do
    %Exchange{
      id: exchange_id,
      name: "emulation_test",
      module: ExchangeStub
    }
  end

  defp dispatch_declared(method, params, responder) do
    Emulation.dispatch_declared(
      build_exchange("handler-boundary-test"),
      method,
      %{"name" => Atom.to_string(method), "reasons" => ["test"], "scope" => "rest"},
      %{
        exchange_module: ExchangeStub,
        params: params,
        caller: caller(responder)
      }
    )
  end

  defp caller(responder) do
    fn _exchange, _module, method, params, _opts -> responder.(method, params) end
  end

  defp emulation_ast do
    @emulation_path
    |> File.read!()
    |> Code.string_to_quoted!(file: @emulation_path)
  end

  defp module_attribute!(ast, name) do
    {_ast, values} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{^name, _, [value]}]} = node, values -> {node, [value | values]}
        node, values -> {node, values}
      end)

    [value] = values
    {evaluated, _binding} = Code.eval_quoted(value)
    evaluated
  end

  defp function_definitions(ast) do
    {_ast, definitions} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, [do: body]]} = node, definitions when kind in [:def, :defp] ->
          name = function_name(head)
          {node, Map.update(definitions, name, [body], &[body | &1])}

        node, definitions ->
          {node, definitions}
      end)

    definitions
  end

  defp function_name({:when, _, [head | _guards]}), do: function_name(head)
  defp function_name({name, _, _args}) when is_atom(name), do: name

  defp delegated_handlers(definitions) do
    definitions
    |> Map.keys()
    |> Enum.filter(&(String.starts_with?(Atom.to_string(&1), "handle_") and call_method_sites(definitions, &1) != []))
  end

  defp call_method_sites(definitions, handler) do
    for function <- reachable_functions(definitions, handler),
        body <- Map.fetch!(definitions, function),
        site <- calls_in(body, :call_method),
        do: site
  end

  defp params_rebindings(definitions, handler) do
    for function <- reachable_functions(definitions, handler),
        body <- Map.fetch!(definitions, function),
        rebinding <- params_rebindings_in(body),
        do: rebinding
  end

  defp delegation_methods(definitions, handler) do
    for function <- reachable_functions(definitions, handler),
        body <- Map.fetch!(definitions, function),
        call_name <- [:call_method, :call_optional_method],
        %{method: method} <- calls_in(body, call_name),
        is_atom(method),
        uniq: true,
        do: method
  end

  defp extracted_params(definitions, handler) do
    for function <- reachable_functions(definitions, handler),
        body <- Map.fetch!(definitions, function),
        param <- extracted_params_in(body),
        uniq: true,
        do: param
  end

  defp reachable_functions(definitions, root) do
    definitions |> expand_reachable([root], MapSet.new()) |> MapSet.to_list()
  end

  defp expand_reachable(_definitions, [], seen), do: seen

  defp expand_reachable(definitions, [function | pending], seen) do
    if MapSet.member?(seen, function) do
      expand_reachable(definitions, pending, seen)
    else
      callees =
        definitions
        |> Map.fetch!(function)
        |> Enum.flat_map(&local_calls(&1, definitions))

      expand_reachable(definitions, callees ++ pending, MapSet.put(seen, function))
    end
  end

  defp local_calls(ast, definitions) do
    {_ast, calls} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _, args} = node, calls when is_atom(name) and is_list(args) ->
          if name != :call_method and Map.has_key?(definitions, name) do
            {node, MapSet.put(calls, name)}
          else
            {node, calls}
          end

        node, calls ->
          {node, calls}
      end)

    MapSet.to_list(calls)
  end

  defp calls_in(ast, call_name) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {^call_name, meta, [_exchange, _module, method, params | _rest]} = node, calls ->
          method = if is_atom(method), do: method
          {node, [%{line: meta[:line], method: method, params: params} | calls]}

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp params_rebindings_in(ast) do
    {_ast, rebindings} =
      Macro.prewalk(ast, [], fn
        {:=, meta, [{:params, _, _context}, _value]} = node, rebindings ->
          {node, [%{line: meta[:line], ast: node} | rebindings]}

        node, rebindings ->
          {node, rebindings}
      end)

    rebindings
  end

  defp extracted_params_in(ast) do
    {_ast, params} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:extract_param, _, [_params, param]} = node, params when is_atom(param) ->
          {node, MapSet.put(params, param)}

        node, params ->
          {node, params}
      end)

    MapSet.to_list(params)
  end

  defp derived_from_incoming_params?({:delegated_params, _, [{:params, _, _context}, _handler, _method | _rest]}),
    do: true

  defp derived_from_incoming_params?(_params), do: false

  defp emulated_capability_pairs do
    for venue <- Spec.exchanges(),
        {js_name, "emulated"} <- get_in(Spec.load!(venue), ["capabilities", "has"]),
        do: {venue, js_name}
  end

  defp capability_method!("fetchCurrenciesWs"), do: :fetch_currencies

  defp capability_method!(js_name) do
    Emulation.method_atom(js_name) || flunk("emulated capability has no unified method: #{js_name}")
  end

  @doc false
  # Returns {exchange_id, method_atom, scope_atom} for a sample emulated method.
  defp sample_emulated_method do
    sample =
      Enum.find_value(EmulatedMethods.exchanges(), fn exchange_id ->
        case List.first(EmulatedMethods.methods_for(exchange_id)) do
          nil -> nil
          entry -> {exchange_id, entry}
        end
      end)

    if is_nil(sample) do
      flunk("""
      No exchanges with emulated methods found.

      Check the owned runtime specs for this build.
      """)
    end

    {exchange_id, entry} = sample

    method = Emulation.method_atom(Map.get(entry, "name"))

    if is_nil(method) do
      flunk("Could not resolve method atom for #{inspect(entry)}")
    end

    scope =
      case Map.get(entry, "scope") do
        "rest" -> :rest
        "ws" -> :ws
        other -> flunk("Unknown emulation scope: #{inspect(other)}")
      end

    {exchange_id, method, scope}
  end

  @doc false
  # Finds an emulated method entry that has no implementation handler.
  defp find_unimplemented_entry do
    implemented = Emulation.implemented_methods()

    Enum.find_value(EmulatedMethods.exchanges(), fn exchange_id ->
      find_unimplemented_in_exchange(exchange_id, implemented)
    end)
  end

  @doc false
  # Searches a single exchange's emulated methods for one missing from implemented set.
  defp find_unimplemented_in_exchange(exchange_id, implemented) do
    exchange_id
    |> EmulatedMethods.methods_for()
    |> Enum.find_value(fn entry ->
      method = Emulation.method_atom(Map.get(entry, "name"))
      scope = entry_scope(entry)

      if scope in [:rest, :ws] and is_atom(method) and not MapSet.member?(implemented, method) do
        {exchange_id, method, scope, entry}
      end
    end)
  end

  @doc false
  # Converts an entry's scope field to an atom.
  defp entry_scope(%{"scope" => "rest"}), do: :rest
  defp entry_scope(%{"scope" => "ws"}), do: :ws
  defp entry_scope(_entry), do: :unknown
end
