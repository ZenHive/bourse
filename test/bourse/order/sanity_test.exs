defmodule Bourse.Order.SanityTest do
  @moduledoc "Tests for pre-submit order sanity checks."

  use ExUnit.Case, async: true

  alias Bourse.Market
  alias Bourse.Order.Builder
  alias Bourse.Order.Sanity

  defp market(overrides \\ %{}) do
    Map.merge(
      %{
        "symbol" => "BTC/USDT",
        "active" => true,
        "contract" => false,
        "precision" => %{"amount" => 0.001, "price" => 0.5},
        "limits" => %{
          "amount" => %{"min" => 0.001, "max" => 10.0},
          "price" => %{"min" => 100.0, "max" => 100_000.0},
          "cost" => %{"min" => 10.0, "max" => 500_000.0}
        }
      },
      overrides
    )
  end

  describe "validate/3" do
    test "returns normalized params when all checks pass" do
      params = %{symbol: "BTC/USDT", type: "limit", side: "buy", amount: 0.01, price: 50_000.0}

      assert {:ok,
              %{
                symbol: "BTC/USDT",
                type: "limit",
                side: "buy",
                amount: 0.01,
                price: 50_000.0
              }} = Sanity.validate(params, market(), has: %{"createLimitOrder" => true})
    end

    test "accepts builder structs and reads price from builder params" do
      builder =
        "BTC/USDT"
        |> Builder.new("sell", 0.02)
        |> Builder.limit(51_000.0)

      assert {:ok, %{type: "limit", side: "sell", price: 51_000.0}} =
               Sanity.validate(builder, market())
    end

    test "collects hard failures for unsupported type, limits, and precision" do
      params = %{symbol: "BTC/USDT", type: "limit", side: "hold", amount: 0.0005, price: 100_000.25}

      assert {:error, {:sanity_check, reasons}} =
               Sanity.validate(params, market(), has: %{"createLimitOrder" => false})

      assert {:check_side, _} = List.keyfind(reasons, :check_side, 0)
      assert {:check_order_type, _} = List.keyfind(reasons, :check_order_type, 0)
      assert {:check_amount, _} = List.keyfind(reasons, :check_amount, 0)
      assert {:check_price, _} = List.keyfind(reasons, :check_price, 0)
    end

    test "returns warnings when price deviates from reference price" do
      params = %{symbol: "BTC/USDT", type: "limit", side: "buy", amount: 0.1, price: 125.0}

      assert {:ok, ^params, [{:check_price_deviation, message}]} =
               Sanity.validate(params, market(), reference_price: 100.0, deviation_threshold: 0.10)

      assert message =~ "deviates"
    end

    test "promotes warnings to errors in strict mode" do
      params = %{symbol: "BTC/USDT", type: "limit", side: "buy", amount: 0.1, price: 125.0}

      assert {:error, {:sanity_check, [{:check_price_deviation, _}]}} =
               Sanity.validate(params, market(),
                 reference_price: 100.0,
                 deviation_threshold: 0.10,
                 warnings: :strict
               )
    end

    test "skips market checks when market metadata is absent" do
      params = %{symbol: "BTC/USDT", type: "market", side: :buy, amount: 0.1}

      assert {:ok, %{side: "buy", price: nil}} = Sanity.validate(params, nil)
    end
  end

  describe "individual checks" do
    test "check_order_type/1 rejects unknown and non-string types" do
      assert :ok = Sanity.check_order_type("limit")
      assert {:error, unknown} = Sanity.check_order_type("iceberg")
      assert unknown =~ "Unknown order type"
      assert {:error, non_string} = Sanity.check_order_type(:limit)
      assert non_string =~ "must be a string"

      assert :ok = Sanity.check_order_type("limit", has: :not_a_map)
    end

    test "check_symbol/2 rejects mismatched, inactive, and invalid symbols" do
      assert {:error, mismatch} = Sanity.check_symbol("ETH/USDT", market())
      assert mismatch =~ "Symbol mismatch"

      assert {:error, inactive} = Sanity.check_symbol("BTC/USDT", market(%{"active" => false}))
      assert inactive =~ "inactive"

      assert :ok = Sanity.check_symbol("BTC/USDT", %Market{symbol: "BTC/USDT", active: true})
      assert {:error, invalid} = Sanity.check_symbol(nil, market())
      assert invalid =~ "Invalid symbol"
    end

    test "check_amount/3 handles invalid input, nil market, maximums, and decimal precision" do
      assert {:error, invalid} = Sanity.check_amount(0, market())
      assert invalid =~ "positive number"

      assert :ok = Sanity.check_amount(100, nil)

      assert {:error, above_max} = Sanity.check_amount(11.0, market())
      assert above_max =~ "exceeds maximum"

      decimal_market = market(%{"precision" => %{"amount" => 3}})
      assert :ok = Sanity.check_amount(0.123, decimal_market, precision_mode: :decimal_places)
      assert {:error, precision} = Sanity.check_amount(0.1234, decimal_market, precision_mode: :decimal_places)
      assert precision =~ "does not respect increment"

      non_numeric_limit = %{"symbol" => "BTC/USDT", "limits" => %{"amount" => %{"min" => "0.001"}}}
      assert :ok = Sanity.check_amount(0.01, non_numeric_limit)

      non_numeric_precision = %{"symbol" => "BTC/USDT", "precision" => %{"amount" => "0.001"}}
      assert :ok = Sanity.check_amount(0.01, non_numeric_precision)

      zero_increment = %{"symbol" => "BTC/USDT", "precision" => %{"amount" => 0}}
      assert :ok = Sanity.check_amount(0.01, zero_increment)
    end

    test "check_price/4 handles missing, invalid, marketless, and limit-bound prices" do
      assert {:error, missing} = Sanity.check_price(nil, "limit", market())
      assert missing =~ "require a price"

      assert :ok = Sanity.check_price(nil, "market", market())

      assert {:error, invalid} = Sanity.check_price(-1, "limit", market())
      assert invalid =~ "positive number"

      assert :ok = Sanity.check_price(50_000, "limit", nil)

      assert {:error, below_min} = Sanity.check_price(99, "limit", market())
      assert below_min =~ "below minimum"
    end

    test "check_cost/3 handles skipped inputs, cost maximums, and inverse contracts" do
      assert :ok = Sanity.check_cost(1, 100, nil)
      assert :ok = Sanity.check_cost(nil, 100, market())

      assert {:error, above_max} = Sanity.check_cost(10, 100_000, market())
      assert above_max =~ "exceeds maximum"

      inverse_market =
        market(%{
          "contract" => true,
          "inverse" => true,
          "contractSize" => 100,
          "limits" => %{"cost" => %{"min" => 0.01, "max" => 1.0}}
        })

      assert :ok = Sanity.check_cost(10, 50_000, inverse_market)
    end

    test "check_price_deviation/3 ignores missing reference data and accepts prices within threshold" do
      assert :ok = Sanity.check_price_deviation(nil, 100)
      assert :ok = Sanity.check_price_deviation(104, 100, deviation_threshold: 0.05)
    end
  end
end
