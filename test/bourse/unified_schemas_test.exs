defmodule Bourse.UnifiedSchemasTest do
  @moduledoc """
  Meta-test that validates JSON Schema definitions across all 35 unified type structs.

  Verifies:
  - schema/0 exists and returns a map
  - Schema has "type" => "object" and "properties" key
  - Schema property keys match struct field names (minus __struct__)
  - Schema is valid for JSONSpec.atomize/2 roundtrip
  """

  use ExUnit.Case, async: true

  @unified_structs [
    # Tier 0: Original
    Bourse.Ticker,
    Bourse.Trade,
    Bourse.Order,
    Bourse.Balance,
    Bourse.Market,
    Bourse.OHLCV,
    Bourse.Fee,
    # Tier 1: Core
    Bourse.OrderBook,
    Bourse.Position,
    Bourse.Currency,
    Bourse.Transaction,
    Bourse.LedgerEntry,
    Bourse.FundingRate,
    Bourse.DepositAddress,
    Bourse.TransferEntry,
    Bourse.TradingFee,
    # Tier 2: Derivatives/Options
    Bourse.Leverage,
    Bourse.OpenInterest,
    Bourse.Liquidation,
    Bourse.Greeks,
    Bourse.OptionData,
    Bourse.LeverageTier,
    Bourse.MarginMode,
    Bourse.MarginModification,
    Bourse.MarginLoan,
    Bourse.ADLRank,
    # Tier 3: Analytics/Account/Funding
    Bourse.LongShortRatio,
    Bourse.FundingHistory,
    Bourse.FundingRateHistory,
    Bourse.Conversion,
    Bourse.Account,
    Bourse.LastPrice,
    Bourse.DepositWithdrawFee,
    Bourse.BorrowRate,
    Bourse.BorrowInterest
  ]

  @expected_count 35

  test "all #{@expected_count} unified structs are listed" do
    assert length(@unified_structs) == @expected_count
  end

  for mod <- @unified_structs do
    describe "#{inspect(mod)}" do
      test "exports schema/0" do
        Code.ensure_loaded!(unquote(mod))

        assert function_exported?(unquote(mod), :schema, 0),
               "#{inspect(unquote(mod))} does not export schema/0"
      end

      test "schema/0 returns a JSON Schema object" do
        result = unquote(mod).schema()
        assert is_map(result), "schema/0 should return a map"
        assert result["type"] == "object", "schema type should be 'object'"
        assert is_map(result["properties"]), "schema should have 'properties'"
      end

      test "schema properties match struct fields" do
        schema = unquote(mod).schema()
        schema_keys = schema["properties"] |> Map.keys() |> MapSet.new()

        struct_keys =
          unquote(mod).__struct__()
          |> Map.keys()
          |> Enum.reject(&(&1 == :__struct__))
          |> MapSet.new(&Atom.to_string/1)

        missing_from_schema = MapSet.difference(struct_keys, schema_keys)
        extra_in_schema = MapSet.difference(schema_keys, struct_keys)

        assert MapSet.size(missing_from_schema) == 0,
               "#{inspect(unquote(mod))} schema missing fields: #{inspect(MapSet.to_list(missing_from_schema))}"

        assert MapSet.size(extra_in_schema) == 0,
               "#{inspect(unquote(mod))} schema has extra fields: #{inspect(MapSet.to_list(extra_in_schema))}"
      end

      test "schema properties have type definitions" do
        schema = unquote(mod).schema()

        for {field_name, field_schema} <- schema["properties"] do
          assert is_map(field_schema),
                 "#{inspect(unquote(mod))}.#{field_name} property should be a map, got: #{inspect(field_schema)}"
        end
      end

      test "schema works with JSONSpec.atomize/2" do
        schema = unquote(mod).schema()

        # Build a sample string-keyed map with nil values for all properties
        sample_data =
          schema["properties"]
          |> Map.keys()
          |> Map.new(fn key -> {key, nil} end)

        result = JSONSpec.atomize(schema, sample_data)
        assert is_map(result), "atomize should return a map"

        # All keys should be atoms after atomization
        for {key, _val} <- result do
          assert is_atom(key),
                 "#{inspect(unquote(mod))}: key #{inspect(key)} should be an atom after atomize"
        end
      end
    end
  end

  describe "nested schema shapes" do
    test "OrderBook bids/asks contain exact two-number arrays" do
      schema = Bourse.OrderBook.schema()
      bids = schema["properties"]["bids"]
      asks = schema["properties"]["asks"]

      assert bids["type"] == "array", "bids should be an array"
      assert bids["items"]["type"] == "array", "bids items should be arrays"
      assert bids["items"]["items"]["type"] == "number", "bids inner items should be numbers"
      assert bids["items"]["minItems"] == 2, "bid levels should contain exactly two items"
      assert bids["items"]["maxItems"] == 2, "bid levels should contain exactly two items"

      assert asks["type"] == "array", "asks should be an array"
      assert asks["items"]["type"] == "array", "asks items should be arrays"
      assert asks["items"]["items"]["type"] == "number", "asks inner items should be numbers"
      assert asks["items"]["minItems"] == 2, "ask levels should contain exactly two items"
      assert asks["items"]["maxItems"] == 2, "ask levels should contain exactly two items"
    end

    test "Order trades is an array of objects" do
      schema = Bourse.Order.schema()
      trades = schema["properties"]["trades"]

      assert trades["type"] == "array", "trades should be an array"
      assert trades["items"]["type"] == "object", "trades items should be objects"
    end

    test "Order fee is an object" do
      schema = Bourse.Order.schema()
      fee = schema["properties"]["fee"]

      assert fee["type"] == "object", "fee should be an object"
    end
  end
end
