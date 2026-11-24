defmodule Bourse.Emulation.DelegationsTest do
  use ExUnit.Case, async: true

  alias Bourse.Emulation.Delegations
  alias Bourse.Spec
  alias Bourse.Spec.Schema
  alias Bourse.Unified

  @runtime_venue_count 11

  describe "declared graph" do
    test "names only unified methods, under their authored camelCase names" do
      for {from, targets} <- Delegations.edges(), method <- [from | targets] do
        assert Delegations.js_name(method) == Unified.js_name_for!(method),
               "#{method} (delegated from #{from}) does not map to its unified name"
      end
    end

    test "declared?/2 answers from the table" do
      assert Delegations.declared?(:fetch_funding_rate, :fetch_funding_rates)
      refute Delegations.declared?(:fetch_ticker, :fetch_balance)
    end
  end

  describe "find_cycle/1" do
    test "returns the closed path when both funding halves are emulated" do
      assert Delegations.find_cycle(["fetchFundingRates", "fetchFundingRate"]) ==
               ["fetchFundingRate", "fetchFundingRates", "fetchFundingRate"]
    end

    test "returns nil when only one half is emulated" do
      assert Delegations.find_cycle(["fetchFundingRate", "fetchTicker", "fetchOrder", "fetchOpenOrders"]) == nil
      assert Delegations.find_cycle(["fetchFundingRates"]) == nil
      assert Delegations.find_cycle([]) == nil
    end
  end

  describe "authored documents" do
    test "every runtime venue's document passes the cycle check" do
      venues = Spec.exchanges()
      assert length(venues) == @runtime_venue_count

      for venue <- venues do
        spec = Spec.load!(venue)
        assert Schema.validate!(spec, venue) == spec
      end
    end

    test "a document declaring both funding halves emulated in capabilities is rejected" do
      spec = put_in(Spec.load!("bybit"), ["capabilities", "has", "fetchFundingRates"], "emulated")

      assert_raise ArgumentError,
                   ~r/owned spec "bybit" gap emulated_methods: emulation delegation cycle fetchFundingRate -> fetchFundingRates -> fetchFundingRate$/,
                   fn -> Spec.validate_schema!(spec, "bybit") end
    end

    test "a document adding the missing half to emulated_methods is rejected" do
      spec =
        update_in(Spec.load!("deribit"), ["emulated_methods"], fn entries ->
          entries ++ [%{"name" => "fetchFundingRate", "scope" => "rest", "reasons" => ["cycle probe"]}]
        end)

      assert_raise ArgumentError,
                   ~r/owned spec "deribit" gap emulated_methods: emulation delegation cycle fetchFundingRate -> fetchFundingRates -> fetchFundingRate$/,
                   fn -> Spec.validate_schema!(spec, "deribit") end
    end
  end
end
