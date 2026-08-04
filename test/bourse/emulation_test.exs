defmodule Bourse.EmulationTest do
  use ExUnit.Case, async: true

  alias Bourse.Emulation
  alias Bourse.Exchange
  alias Bourse.Extract.EmulatedMethods

  defmodule ExchangeStub do
    @moduledoc false
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
