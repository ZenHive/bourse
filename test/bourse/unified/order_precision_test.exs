defmodule Bourse.Unified.OrderPrecisionTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified.OrderPrecision

  test "unguarded methods preserve params and exchange" do
    exchange = exchange("binance", nil)
    params = %{"amount" => 1.234}
    assert {^params, ^exchange} = OrderPrecision.guard_dispatch!(params, exchange, "createOrder", endpoint_path: "/x")
    okx = %{exchange | id: "okx"}
    assert {^params, ^okx} = OrderPrecision.guard_dispatch!(params, okx, "createOrder", [])
    assert length(OrderPrecision.precision_matrix()) == 40
  end

  test "rounds amount down and price half-up and scopes the selected market" do
    market = market(%{"precision" => %{"amount" => "0.01", "price" => "0.5"}})
    exchange = exchange("okx", [market])

    assert {%{"amount" => "1.23", "price" => "10.5", "symbol" => "BTC/USDT"}, scoped} =
             OrderPrecision.guard_dispatch!(
               %{"amount" => 1.239, "price" => 10.26, "symbol" => "BTC/USDT"},
               exchange,
               "createOrder",
               endpoint_path: "/trade/order"
             )

    assert scoped.markets == [market]
  end

  test "cost orders snap cost and OKX preserves non-zero sub-step values" do
    exchange = exchange("okx", [market(%{"precision" => %{"amount" => 1, "price" => 1}})])

    assert {%{"cost" => "0.2", "symbol" => "BTC/USDT"}, _exchange} =
             OrderPrecision.guard_dispatch!(
               %{"cost" => 0.2, "symbol" => "BTC/USDT"},
               exchange,
               "createMarketBuyOrderWithCost",
               endpoint_path: "/trade/order"
             )
  end

  test "batch orders inherit shared fields and retain unrelated values" do
    exchange = exchange("bybit", [market(%{"linear" => true})])

    params = %{
      "category" => "linear",
      "orders" => [
        %{"symbol" => "BTC/USDT", "amount" => 1.239, "price" => 10.26, "clientId" => "a"},
        %{"symbol" => "BTCUSDT", "amount" => 2.001, "price" => 11.76}
      ]
    }

    assert {%{"orders" => [first, second]}, scoped} =
             OrderPrecision.guard_dispatch!(params, exchange, "createOrders", endpoint_path: "/batch")

    assert first == %{"symbol" => "BTC/USDT", "amount" => "1.23", "price" => "10", "clientId" => "a"}
    assert second["amount"] == "2"
    assert second["price"] == "11.5"
    assert scoped.markets != []
  end

  test "market selection supports ids, categories, and Hyperliquid symbols" do
    spot = market(%{"id" => "BTCUSDT", "spot" => true})
    linear = market(%{"id" => "BTCUSDT", "symbol" => "BTC/USDT:USDT", "linear" => true})
    exchange = exchange("okx", [spot, linear])

    assert {%{"amount" => "1.23"}, %{markets: [^linear]}} =
             OrderPrecision.guard_dispatch!(
               %{"instId" => "BTCUSDT", "category" => "linear", "amount" => 1.239},
               exchange,
               "createOrder",
               endpoint_path: "/x"
             )

    hyperliquid =
      exchange("hyperliquid", [%{"id" => "BTC", "symbol" => "BTC/USDC:USDC", "precision" => %{"amount" => 0.001}}])

    assert {%{"amount" => "1.234", "symbol" => "BTC"}, _} =
             OrderPrecision.guard_dispatch!(
               %{"amount" => 1.2349, "symbol" => "BTC"},
               hyperliquid,
               "createOrder",
               endpoint_path: "/x"
             )
  end

  test "missing markets, symbols, precision, and numeric values fail with domain errors" do
    for {exchange, params, reason} <- [
          {exchange("okx", nil), %{"symbol" => "BTC/USDT", "amount" => 1}, "markets_not_loaded"},
          {exchange("okx", [market()]), %{"symbol" => "ETH/USDT", "amount" => 1}, "market_not_found"},
          {exchange("okx", [market(%{"precision" => %{}})]), %{"symbol" => "BTC/USDT", "amount" => 1},
           "missing_precision"}
        ] do
      error =
        assert_raise Error, fn ->
          OrderPrecision.guard_dispatch!(params, exchange, "createOrder", endpoint_path: "/x")
        end

      assert get_in(error.raw, ["order_precision", "reason"]) == reason
    end

    assert_raise Error, ~r/expected a number/, fn ->
      OrderPrecision.guard_dispatch!(
        %{"symbol" => "BTC/USDT", "amount" => "many"},
        exchange("derive", [market()]),
        "createOrder",
        endpoint_path: "/x"
      )
    end
  end

  test "orders with no precision-bearing fields require no market" do
    exchange = exchange("lighter", nil)
    params = %{"symbol" => "BTC/USDT", "clientOrderId" => "x"}
    assert {^params, ^exchange} = OrderPrecision.guard_dispatch!(params, exchange, "editOrder", endpoint_path: "/x")
  end

  test "inferred market families cover every authored category form" do
    categories = [
      {:spot, "spot"},
      {:option, "option"},
      {"linear", "linear"},
      {"inverse", "inverse"}
    ]

    for {market_type, category} <- categories do
      selected = market(%{"symbol" => "BTC/USDT:USDT", category => true})
      other = market(%{"symbol" => "BTC/USDT:OTHER"})

      assert {%{"amount" => "1.23", "symbol" => "BTCUSDT"}, %{markets: [^selected]}} =
               OrderPrecision.guard_dispatch!(
                 %{"amount" => 1.239, "symbol" => "BTCUSDT"},
                 exchange("okx", [other, selected]),
                 "createOrder",
                 endpoint_path: "/x",
                 market_type: market_type
               )
    end

    only = market(%{"symbol" => "BTC/USDT:ONLY"})

    assert {_, %{markets: [^only]}} =
             OrderPrecision.guard_dispatch!(
               %{"amount" => 1, "symbol" => "BTCUSDT"},
               exchange("okx", [only]),
               "createOrder",
               endpoint_path: "/x",
               market_family: "linear"
             )
  end

  test "non-rounding Lighter validates precision while preserving numeric values" do
    exchange = exchange("lighter", [market()])
    params = %{"amount" => 1.239, "symbol" => "BTCUSDT"}

    assert {^params, %{markets: [_]}} =
             OrderPrecision.guard_dispatch!(params, exchange, "createOrder", endpoint_path: "/x")

    assert_raise Error, fn ->
      OrderPrecision.guard_dispatch!(params, %{exchange | markets: %{}}, "createOrder", endpoint_path: "/x")
    end

    assert_raise Error, fn ->
      OrderPrecision.guard_dispatch!(params, %{exchange | markets: [:invalid]}, "createOrder", endpoint_path: "/x")
    end

    assert_raise Error, fn ->
      OrderPrecision.guard_dispatch!(
        Map.put(params, "category", "unknown"),
        exchange,
        "createOrder",
        endpoint_path: "/x"
      )
    end

    assert {_, %{markets: [_]}} =
             OrderPrecision.guard_dispatch!(params, exchange, "createOrder", endpoint_path: "/x", market_type: :swap)
  end

  defp exchange(id, markets), do: %Exchange{id: id, name: id, markets: markets}

  defp market(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "BTCUSDT",
        "symbol" => "BTC/USDT",
        "precision" => %{"amount" => "0.01", "price" => "0.5"}
      },
      overrides
    )
  end
end
