defmodule Bourse.Unified.OrderPrecisionTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified
  alias Bourse.Unified.OrderPrecision
  alias Bourse.Unified.RequestShape

  @dispatch_opts [endpoint_path: "orders"]
  @credentials [api_key: "key", secret: "secretsecret", password: "password"]
  @precision_methods ~w(
    createMarketBuyOrderWithCost createMarketSellOrderWithCost createOrder createOrders
    createOrderWithTakeProfitAndStopLoss createTwapOrder editOrder editOrders
  )
  @precision_venues ~w(bybit derive hyperliquid lighter okx)

  test "public precision matrix guarantees every guard-passing order value is on its resolved grid" do
    expected = for venue <- @precision_venues, method <- @precision_methods, do: {venue, method}
    assert MapSet.new(OrderPrecision.precision_matrix()) == MapSet.new(expected)

    for {venue, method} <- OrderPrecision.precision_matrix() do
      market = precision_market(venue)
      exchange = venue |> exchange() |> Exchange.put_markets([market])
      params = precision_params(method, venue)

      assert {prepared, %Exchange{markets: [^market]}} =
               OrderPrecision.guard_dispatch!(
                 params,
                 exchange,
                 method,
                 @dispatch_opts ++ [market_family: "linear"]
               )

      Enum.each(order_rows(prepared), fn row ->
        assert_on_grid!(row["amount"] || row["cost"], market.precision["amount"])
        assert_on_grid!(row["price"], market.precision["price"])
      end)
    end
  end

  test "dispatch shaping requires instrument precision for all authored precision venues" do
    for {venue, symbol} <- [
          {"bybit", "BTCUSDT"},
          {"okx", "BTC-USDT"},
          {"derive", "ETH-PERP"},
          {"hyperliquid", "BTC/USDC:USDC"}
        ] do
      exchange = exchange(venue)

      error =
        assert_raise Error, fn ->
          RequestShape.apply(order(symbol), exchange, "createOrder", @dispatch_opts)
        end

      assert error.type == :invalid_order
      assert error.exchange == venue
      assert error.message =~ symbol
      assert error.message =~ "missing instrument precision"
      assert get_in(error.raw, ["order_precision", "reason"]) == "markets_not_loaded"
    end
  end

  test "an explicitly empty markets cache remains an unloaded precision error" do
    exchange = "okx" |> exchange() |> Exchange.put_markets([])

    error =
      assert_raise Error, fn ->
        RequestShape.apply(order("BTC-USDT"), exchange, "createOrder", @dispatch_opts)
      end

    assert get_in(error.raw, ["order_precision", "reason"]) == "markets_not_loaded"
  end

  test "a batch order missing its symbol fails before venue shaping" do
    exchange =
      "okx"
      |> exchange()
      |> Exchange.put_markets([%Market{id: "BTC-USDT", symbol: "BTC/USDT", precision: %{"amount" => 0.001}}])

    error =
      assert_raise Error, fn ->
        RequestShape.apply(
          %{"orders" => [Map.delete(order("BTC-USDT", 1, nil), "symbol")]},
          exchange,
          "createOrders",
          @dispatch_opts
        )
      end

    assert error.message =~ "(missing symbol)"
    assert get_in(error.raw, ["order_precision", "reason"]) == "market_not_found"
  end

  test "direct request-shape construction stays permissive without markets" do
    exchange = exchange("bybit")

    assert %{"qty" => "0.123456", "price" => "60.423"} =
             RequestShape.apply(order("LTCUSDT", 0.123_456, 60.423), exchange, "createOrder")
  end

  test "dispatch shaping names missing precision fields on a loaded market" do
    exchange =
      "okx"
      |> exchange()
      |> Exchange.put_markets([%Market{id: "BTC-USDT", symbol: "BTC/USDT", precision: %{"amount" => 0.001}}])

    error =
      assert_raise Error, fn ->
        RequestShape.apply(order("BTC-USDT"), exchange, "createOrder", @dispatch_opts)
      end

    assert error.message =~ "BTC-USDT"
    assert error.message =~ "price"
    assert get_in(error.raw, ["order_precision", "missing"]) == ["price"]
    assert get_in(error.raw, ["order_precision", "reason"]) == "missing_precision"
  end

  test "dispatch shaping rejects a loaded market whose precision map is absent" do
    exchange =
      "okx"
      |> exchange()
      |> Exchange.put_markets([%Market{id: "BTC-USDT", symbol: "BTC/USDT"}])

    error =
      assert_raise Error, fn ->
        RequestShape.apply(order("BTC-USDT"), exchange, "createOrder", @dispatch_opts)
      end

    assert get_in(error.raw, ["order_precision", "missing"]) == ["price", "amount"]
  end

  test "Bybit dispatch precision selects the market matching the order category" do
    markets =
      for field <- [:spot, :linear, :inverse, :option] do
        attrs = %{
          field => true,
          id: "BTCUSDT",
          symbol: "BTC/USDT",
          precision: %{"amount" => 0.001, "price" => 0.1}
        }

        option_quantity =
          if field == :option do
            %{
              quantity_unit: "base",
              native_quantity_unit: "base",
              native_quantity_field: "qty",
              native_amount_step: 0.001
            }
          else
            %{}
          end

        struct!(Market, Map.merge(attrs, option_quantity))
      end

    exchange = "bybit" |> exchange() |> Exchange.put_markets([nil, %Market{id: "OTHER"} | markets])

    for category <- ~w(spot linear inverse option) do
      assert %{"category" => ^category, "qty" => "0.123", "price" => "60.4"} =
               RequestShape.apply(
                 Map.put(order("BTCUSDT", 0.123, 60.423), "category", category),
                 exchange,
                 "createOrder",
                 @dispatch_opts
               )
    end

    error =
      assert_raise Error, fn ->
        RequestShape.apply(Map.put(order("BTCUSDT"), "category", "margin"), exchange, "createOrder", @dispatch_opts)
      end

    assert get_in(error.raw, ["order_precision", "reason"]) == "market_not_found"
  end

  test "dispatch shaping accepts loaded atom- and string-keyed market precision" do
    bybit =
      "bybit"
      |> exchange()
      |> Exchange.put_markets([
        %Market{
          id: "BTCUSDT",
          symbol: "BTC/USDT",
          spot: true,
          precision: %{"amount" => 0.001, "price" => 0.1}
        }
      ])

    okx =
      "okx"
      |> exchange()
      |> Exchange.put_markets([
        %{"id" => "BTC-USDT", "symbol" => "BTC/USDT", "precision" => %{"amount" => "0.001", "price" => "0.1"}}
      ])

    assert %{"qty" => "0.123", "price" => "60.4"} =
             RequestShape.apply(order("BTCUSDT"), bybit, "createOrder", @dispatch_opts)

    assert %{"sz" => "0.123", "px" => "60.4"} =
             RequestShape.apply(order("BTC-USDT"), okx, "createOrder", @dispatch_opts)
  end

  test "batch dispatch validates every order and amount-only methods need no price precision" do
    exchange =
      "hyperliquid"
      |> exchange()
      |> Exchange.put_markets([
        %Market{symbol: "BTC/USDC:USDC", asset_index: 0, precision: %{"amount" => 0.001}}
      ])

    assert %{"action" => %{"twap" => %{"s" => "1.234"}}} =
             RequestShape.apply(
               %{"symbol" => "BTC/USDC:USDC", "side" => "buy", "amount" => 1.234, "duration" => 60_000},
               exchange,
               "createTwapOrder",
               @dispatch_opts
             )

    error =
      assert_raise Error, fn ->
        RequestShape.apply(
          %{"orders" => [order("BTC/USDC:USDC", 1.234, nil), order("ETH/USDC:USDC", 1.234, nil)]},
          exchange,
          "createOrders",
          @dispatch_opts
        )
      end

    assert error.message =~ "ETH/USDC:USDC"
  end

  test "cost-sized order dispatch requires amount precision" do
    unloaded = exchange("okx")

    error =
      assert_raise Error, fn ->
        RequestShape.apply(
          %{"symbol" => "BTC-USDT", "cost" => 10},
          unloaded,
          "createMarketBuyOrderWithCost",
          @dispatch_opts
        )
      end

    assert get_in(error.raw, ["order_precision", "missing"]) == ["amount"]

    loaded =
      Exchange.put_markets(unloaded, [
        %Market{id: "BTC-USDT", symbol: "BTC/USDT", precision: %{"amount" => 0.01}}
      ])

    assert %{"sz" => "10", "tgtCcy" => "quote_ccy"} =
             RequestShape.apply(
               %{"symbol" => "BTC-USDT", "cost" => 10},
               loaded,
               "createMarketBuyOrderWithCost",
               @dispatch_opts
             )
  end

  test "Hyperliquid dispatch matches a denormalized id to the loaded unified market" do
    exchange =
      "hyperliquid"
      |> exchange()
      |> Exchange.put_markets([
        %Market{
          id: "5",
          symbol: "SOL/USDC:USDC",
          asset_index: 5,
          precision: %{"amount" => 0.01, "price" => 0.001}
        }
      ])

    assert %{"action" => %{"orders" => [%{"a" => 5, "s" => "0.12", "p" => "60.423"}]}} =
             RequestShape.apply(
               order("SOLUSDC", 0.12, 60.423),
               exchange,
               "createOrder",
               @dispatch_opts
             )
  end

  test "a guard-passing Bybit editOrder without an explicit category still rounds to the tick grid" do
    # The guard resolves a market by symbol alone, but Bybit's own precision
    # lookup keys on category too. An unset category used to pass the guard and
    # then silently skip rounding — the guard passing must imply the shape rounds.
    exchange =
      "bybit"
      |> exchange()
      |> Exchange.put_markets([
        %Market{id: "LTCUSDT", symbol: "LTC/USDT", spot: true, precision: %{"amount" => 0.01, "price" => 0.01}}
      ])

    shaped =
      RequestShape.apply(
        %{"symbol" => "LTCUSDT", "id" => "123", "amount" => 0.144_444_423, "price" => 60.423_777_7},
        exchange,
        "editOrder",
        @dispatch_opts
      )

    assert %{"qty" => "0.14", "price" => "60.42"} = shaped
    refute Map.has_key?(shaped, "category")
  end

  test "unified Bybit edit resolves a same-id linear market before symbol denormalization" do
    spot =
      %Market{
        id: "BTCUSDT",
        symbol: "BTC/USDT",
        spot: true,
        precision: %{"amount" => 0.000_001, "price" => 0.01}
      }

    linear =
      %Market{
        id: "BTCUSDT",
        symbol: "BTC/USDT:USDT",
        linear: true,
        precision: %{"amount" => 0.1, "price" => 100}
      }

    exchange = "bybit" |> exchange() |> Exchange.put_markets([spot, linear])
    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %{body: %{"retCode" => 0}}} =
             Unified.capture_responses(
               exchange,
               :edit_order,
               %{
                 "id" => "order-1",
                 "symbol" => "BTC/USDT:USDT",
                 "type" => "limit",
                 "side" => "buy",
                 "amount" => 0.55,
                 "price" => 9_050
               },
               plug: {Req.Test, bybit_stub(requests)}
             )

    assert %{
             "category" => "linear",
             "symbol" => "BTCUSDT",
             "qty" => "0.5",
             "price" => "9000"
           } = RequestCollector.json_body!(requests)
  end

  defp exchange("derive") do
    Exchange.new!("derive", @credentials ++ [options: %{"subaccount_id" => 144_422}])
  end

  defp exchange(venue), do: Exchange.new!(venue, @credentials)

  defp order(symbol, amount \\ 0.123_456, price \\ 60.423) do
    %{
      "symbol" => symbol,
      "type" => "limit",
      "side" => "buy",
      "amount" => amount,
      "price" => price
    }
  end

  defp precision_market("bybit"), do: %Market{id: "BTCUSDT", symbol: "BTC/USDT:USDT", linear: true, precision: grid()}

  defp precision_market("okx"), do: %Market{id: "BTC-USDT-SWAP", symbol: "BTC/USDT:USDT", linear: true, precision: grid()}

  defp precision_market("derive"), do: %Market{id: "BTC-PERP", symbol: "BTC/USD:USDC", linear: true, precision: grid()}

  defp precision_market("hyperliquid"), do: %Market{id: "0", symbol: "BTC/USDC:USDC", linear: true, precision: grid()}

  defp precision_market("lighter"), do: %Market{id: "1", symbol: "BTC/USDC:USDC", linear: true, precision: grid()}

  defp grid, do: %{"amount" => 0.1, "price" => 100}

  defp precision_params(method, venue) do
    amount = if venue == "lighter", do: "0.5", else: "0.55"
    price = if venue == "lighter", do: "9000", else: "9050"
    symbol = precision_market(venue).symbol

    row =
      Map.put(
        %{"symbol" => symbol, "type" => "limit", "side" => "buy", "price" => price},
        if(method in ~w(createMarketBuyOrderWithCost createMarketSellOrderWithCost), do: "cost", else: "amount"),
        amount
      )

    if method in ~w(createOrders editOrders), do: %{"orders" => [row]}, else: row
  end

  defp order_rows(%{"orders" => orders}), do: orders
  defp order_rows(order), do: [order]

  defp assert_on_grid!(value, step) do
    {:ok, value} = Decimal.cast(value)
    {:ok, step} = Decimal.cast(step)
    units = Decimal.div(value, step)

    assert Decimal.equal?(units, Decimal.round(units, 0)),
           "expected #{Decimal.to_string(value)} to align with step #{Decimal.to_string(step)}"
  end

  defp bybit_stub(requests) do
    name = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(name, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, %{"retCode" => 0, "retMsg" => "OK", "result" => %{}})
    end)

    name
  end
end
