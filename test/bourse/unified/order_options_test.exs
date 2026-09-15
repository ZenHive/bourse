defmodule Bourse.Unified.OrderOptionsTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified
  alias Bourse.Unified.OrderOptions

  @aliases [
    {"trigger_price", "triggerPrice", 40_000},
    {"stop_loss_price", "stopLossPrice", 40_000},
    {"take_profit_price", "takeProfitPrice", 90_000},
    {"time_in_force", "timeInForce", "GTC"},
    {"reduce_only", "reduceOnly", true}
  ]

  test "conflicting spellings fail before authentication or dispatch for every venue" do
    for venue <- Bourse.Spec.exchanges(), {canonical, legacy, value} <- @aliases do
      exchange = Exchange.new!(venue)
      params = Map.merge(order(), %{canonical => value, legacy => "conflicting"})

      assert {:error, %Error{type: :invalid_parameters}} =
               create_order(exchange, params),
             "#{venue} accepted conflicting #{canonical} / #{legacy}"
    end
  end

  test "a conflicting child prevents dispatch of the entire batch" do
    exchange = Exchange.new!("bybit")
    orders = [order(), Map.merge(order(), %{"reduce_only" => false, "reduceOnly" => true})]

    assert {:error, %Error{type: :invalid_parameters}} = Bourse.create_orders(exchange, orders)
  end

  test "OKX canonical options and equal duplicate aliases retain the legacy request shape" do
    exchange = shape_exchange("okx")

    for {canonical, legacy, value} <- @aliases do
      assert {:ok, [expected]} = shape(exchange, Map.put(order(), legacy, value))
      assert {:ok, [^expected]} = shape(exchange, Map.put(order(), canonical, value))
      assert {:ok, [^expected]} = shape(exchange, Map.merge(order(), %{canonical => value, legacy => value}))
    end

    assert {:ok, [%{"ordType" => "trigger", "triggerPx" => "40000", "side" => "sell"}]} =
             shape(exchange, Map.put(order(), "trigger_price", 40_000))
  end

  test "Bybit conditional fields survive normalization" do
    exchange = shape_exchange("bybit")
    params = Map.merge(order(), %{"type" => "limit", "price" => 40_000, "category" => "linear", "triggerDirection" => 2})

    for {canonical, legacy, value} <- @aliases do
      assert {:ok, [expected]} = shape(exchange, Map.put(params, legacy, value))
      assert {:ok, [^expected]} = shape(exchange, Map.put(params, canonical, value))
    end

    assert {:ok, [%{"triggerPrice" => "40000", "triggerDirection" => 2, "side" => "Sell"}]} =
             shape(exchange, Map.put(params, "trigger_price", 40_000))
  end

  test "venues without a unified trigger builder refuse protection instead of discarding it" do
    for venue <- ["derive", "hyperliquid", "lighter", "coinbaseexchange"],
        {canonical, legacy, value} <- Enum.take(@aliases, 3),
        spelling <- [canonical, legacy] do
      exchange = Exchange.new!(venue)

      assert {:error, %Error{type: :invalid_parameters}} =
               create_order(exchange, Map.put(order(), spelling, value)),
             "#{venue} did not refuse #{spelling}"
    end
  end

  test "Deribit requires a conditional type when a trigger is requested" do
    exchange = shape_exchange("deribit")
    params = Map.merge(order(), %{"symbol" => "BTC/USD:BTC", "trigger_price" => 40_000})
    assert {:error, %Error{type: :invalid_parameters}} = shape(exchange, params)

    assert {:ok, [%{"trigger_price" => 40_000, "type" => "stop_market"}]} =
             shape(exchange, Map.put(params, "type", "stop_market"))
  end

  test "plain market and limit requests keep their existing shapes" do
    exchange = shape_exchange("okx")
    assert {:ok, [%{"ordType" => "market"}]} = shape(exchange, order())

    assert {:ok, [%{"ordType" => "limit", "px" => "40000"}]} =
             shape(exchange, Map.merge(order(), %{"type" => "limit", "price" => 40_000}))
  end

  test "non-order methods and numeric price spellings pass through preparation" do
    exchange = Exchange.new!("okx")
    assert {:ok, %{"limit" => 5}} = OrderOptions.prepare(exchange, :fetch_open_orders, %{"limit" => 5})

    assert {:ok, %{"triggerPrice" => "40000.5"}} =
             OrderOptions.prepare(exchange, :create_order, Map.put(order(), "trigger_price", "40000.5"))

    assert {:ok, %{"triggerPrice" => %Decimal{} = price}} =
             OrderOptions.prepare(exchange, :create_order, Map.put(order(), "trigger_price", Decimal.new("40000")))

    assert Decimal.equal?(price, Decimal.new("40000"))

    assert {:error, %Error{type: :invalid_parameters}} =
             OrderOptions.prepare(exchange, :create_order, Map.put(order(), "trigger_price", "40x"))
  end

  test "nil controls, competing triggers and unsupported edit controls fail closed" do
    for {venue, method, extra} <- [
          {"okx", :create_order, %{"trigger_price" => nil}},
          {"okx", :create_order, %{"trigger_price" => :not_a_price}},
          {"okx", :create_order, %{"trigger_price" => 40_000, "stop_loss_price" => 30_000}},
          {"binanceusdm", :create_order, %{"stop_loss_price" => 40_000, "take_profit_price" => 90_000}},
          {"bybit", :edit_order, %{"trigger_price" => 40_000}},
          {"bybit", :edit_orders, %{"orders" => [Map.put(order(), "reduce_only", true)]}},
          {"okx", :edit_order, %{"reduce_only" => true}},
          {"okx", :edit_orders, %{"orders" => [Map.put(order(), "time_in_force", "GTC")]}},
          {"alpaca", :create_order, %{"reduce_only" => true}},
          {"coinbaseexchange", :create_order, %{"reduce_only" => true}},
          {"okx", :create_orders, %{"orders" => [Map.put(order(), "trigger_price", 40_000)]}},
          {"bybit", :create_orders, %{"orders" => [order()], "reduce_only" => true}},
          {"bybit", :create_orders,
           %{"orders" => [Map.merge(order(), %{"stop_loss_price" => 40_000, "take_profit_price" => 90_000})]}}
        ] do
      assert {:error, %Error{type: :invalid_parameters}} =
               OrderOptions.prepare(Exchange.new!(venue), method, Map.merge(order(), extra))
    end
  end

  test "batch children keep false reduce-only and normalize their own time-in-force" do
    for venue <- ["bybit", "binance", "binanceusdm", "binancecoinm"] do
      params = %{"orders" => [Map.merge(order(), %{"type" => "limit", "reduce_only" => false, "time_in_force" => "GTC"})]}

      assert {:ok, %{"orders" => [%{"reduceOnly" => false, "timeInForce" => "GTC"}]}} =
               OrderOptions.prepare(Exchange.new!(venue), :create_orders, params)
    end
  end

  test "time-in-force cannot become a different execution policy" do
    for venue <- ["okx", "hyperliquid"], tif <- ["unknown", "PO"] do
      assert {:error, %Error{type: :invalid_parameters}} =
               OrderOptions.prepare(Exchange.new!(venue), :create_order, Map.put(order(), "time_in_force", tif))
    end

    for {tif, type} <- [{"IOC", "ioc"}, {"FOK", "fok"}] do
      assert {:ok, [%{"ordType" => ^type}]} =
               shape(
                 shape_exchange("okx"),
                 Map.merge(order(), %{"type" => "limit", "price" => 40_000, "time_in_force" => tif})
               )
    end

    assert {:ok, %{"timeInForce" => "IOC"}} =
             OrderOptions.prepare(Exchange.new!("hyperliquid"), :create_order, Map.put(order(), "time_in_force", "IOC"))
  end

  test "Alpaca stop and Derive native controls retain their provider spelling" do
    assert {:ok, %{"stop_price" => 100}} =
             OrderOptions.prepare(
               Exchange.new!("alpaca"),
               :create_order,
               Map.merge(order(), %{"type" => "stop", "triggerPrice" => 100})
             )

    assert {:ok, %{"reduce_only" => false, "time_in_force" => "gtc"}} =
             OrderOptions.prepare(
               Exchange.new!("derive"),
               :create_order,
               Map.merge(order(), %{"reduceOnly" => false, "timeInForce" => "gtc"})
             )
  end

  test "Binance spot and explicit regular endpoints cannot turn a trigger into a market order" do
    exchange = shape_exchange("binanceusdm")

    assert {:error, %Error{type: :invalid_parameters}} =
             Bourse.create_order(exchange, "BTC/USDT", "market", "sell", 1, trigger_price: 40_000)

    configs = exchange.module.__unified_endpoint__(:create_order)
    index = Enum.find_index(configs, &(&1.path == "order" and "fapiPrivate" in &1.sections))
    assert is_integer(index)

    assert {:error, %Error{type: :invalid_parameters}} =
             Bourse.create_order(exchange, "BTC/USDT:USDT", "market", "sell", 1,
               trigger_price: 40_000,
               endpoint_index: index
             )

    assert {:error, %Error{type: :invalid_parameters}} =
             Bourse.create_order(exchange, "BTC/USDT:USDT", "market", "sell", 1, trigger_price: :not_a_price)
  end

  test "spot reduce-only and Bybit spot dual legs are refused before submitting an order" do
    for venue <- ["okx", "bybit"] do
      exchange = shape_exchange(venue)
      [market] = exchange.markets

      market = %{
        market
        | symbol: "BTC/USDT",
          id: if(venue == "okx", do: "BTC-USDT", else: "BTCUSDT"),
          type: "spot",
          spot: true,
          contract: false,
          linear: false
      }

      exchange = %{exchange | markets: [market]}

      assert {:error, %Error{type: :invalid_parameters}} =
               Bourse.create_order(exchange, market.symbol, "market", "sell", 1, reduce_only: true, category: "spot")

      assert {:error, %Error{type: :invalid_parameters}} =
               Bourse.create_orders(exchange, [Map.merge(order(), %{"symbol" => market.symbol, "reduceOnly" => true})],
                 category: "spot"
               )

      if venue == "bybit" do
        assert {:error, %Error{type: :invalid_parameters}} =
                 Bourse.create_order(exchange, market.symbol, "market", "sell", 1,
                   stop_loss_price: 40_000,
                   take_profit_price: 90_000,
                   category: "spot"
                 )
      end
    end
  end

  test "Bybit option triggers are refused instead of treated as ordinary options orders" do
    exchange = shape_exchange("bybit")
    [market] = exchange.markets

    exchange = %{
      exchange
      | markets: [
          %{
            market
            | type: "option",
              option: true,
              linear: false,
              quantity_unit: "base",
              native_quantity_unit: "base",
              native_quantity_field: "qty",
              native_amount_step: 0.01
          }
        ]
    }

    assert {:error, %Error{type: :invalid_parameters}} =
             Bourse.create_order(exchange, market.symbol, "market", "sell", 1, trigger_price: 40_000, category: "option")

    assert {:error, %Error{type: :invalid_parameters}} =
             Bourse.create_orders(exchange, [Map.merge(order(), %{"trigger_price" => 40_000, "category" => "option"})],
               category: "option"
             )
  end

  test "unsupported wrappers and native overrides cannot discard protective controls" do
    for {venue, method, params} <- [
          {"binance", :edit_order, Map.put(order(), "reduce_only", true)},
          {"binance", :edit_orders, %{"orders" => [Map.put(order(), "time_in_force", "GTC")]}},
          {"deribit", :edit_order, Map.put(order(), "time_in_force", "GTC")},
          {"hyperliquid", :edit_order, Map.put(order(), "reduce_only", true)},
          {"hyperliquid", :create_order, Map.merge(order(), %{"action" => %{}, "reduce_only" => true})},
          {"hyperliquid", :create_twap_order, Map.put(order(), "time_in_force", "GTC")},
          {"bybit", :create_uta_order, Map.put(order(), "trigger_price", 40_000)},
          {"bybit", :create_order, Map.merge(order(), %{"trigger_price" => 40_000, "tradingStopEndpoint" => true})}
        ] do
      assert {:error, %Error{type: :invalid_parameters}} = OrderOptions.prepare(Exchange.new!(venue), method, params)
    end

    assert {:ok, %{"reduceOnly" => true}} =
             OrderOptions.prepare(Exchange.new!("hyperliquid"), :create_twap_order, Map.put(order(), "reduce_only", true))

    for {key, value} <- [{"trigger_price", 40_000}, {"stop_loss_price", 30_000}] do
      assert {:ok, prepared} =
               OrderOptions.prepare(
                 Exchange.new!("okx"),
                 :edit_order,
                 Map.merge(order(), %{"type" => "trigger", key => value})
               )

      refute Map.has_key?(prepared, key)
    end
  end

  test "invalid control types and competing native selectors fail before dispatch" do
    for {venue, extra} <- [
          {"bybit", %{"time_in_force" => :IOC}},
          {"bybit", %{"timeInForce" => 123}},
          {"hyperliquid", %{"reduce_only" => "TRUE"}},
          {"hyperliquid", %{"reduceOnly" => :yes}},
          {"okx", %{"trigger_price" => 40_000, "callbackRatio" => "0.01"}},
          {"okx", %{"trigger_price" => 40_000, "callbackSpread" => "100"}},
          {"okx", %{"trigger_price" => 40_000, "callback_ratio" => "0.01"}},
          {"okx", %{"trigger_price" => 40_000, "callback_spread" => "100"}},
          {"okx", %{"trigger_price" => 40_000, "trailing_stop" => "100"}},
          {"okx", %{"trigger_price" => 40_000, "type" => "oco"}},
          {"okx", %{"trigger_price" => 40_000, "ordType" => "oco"}},
          {"okx", %{"type" => "limit", "time_in_force" => "IOC", "postOnly" => "true"}},
          {"bybit", %{"type" => "limit", "time_in_force" => "IOC", "postOnly" => true}},
          {"bybit", %{"time_in_force" => "FOK"}}
        ] do
      assert {:error, %Error{type: :invalid_parameters}} =
               create_order(Exchange.new!(venue), Map.merge(order(), extra))
    end
  end

  test "a native batch action cannot bypass child protection" do
    exchange = Exchange.new!("hyperliquid")

    for key <- ["reduce_only", "reduceOnly"] do
      assert {:error, %Error{type: :invalid_parameters}} =
               Bourse.create_orders(exchange, [Map.put(order(), key, true)], action: %{})
    end

    assert {:ok, _} = OrderOptions.prepare(exchange, :create_orders, %{"action" => %{}, "orders" => [order()]})
  end

  defp shape_exchange(venue) do
    exchange =
      Exchange.new!(venue, credentials: Bourse.Credentials.new!(api_key: "key", secret: "secret", password: "pass"))

    market = %Bourse.Market{
      id: if(venue == "okx", do: "BTC-USDT-SWAP", else: "BTCUSDT"),
      symbol: "BTC/USDT:USDT",
      type: "swap",
      linear: true,
      contract: true,
      precision: %{"amount" => 0.01, "price" => 0.1},
      contract_size: 1
    }

    %{exchange | markets: [market]}
  end

  defp shape(exchange, params) do
    with {:ok, prepared} <- OrderOptions.prepare(exchange, :create_order, params) do
      Unified.request_param_shapes(exchange, :create_order, prepared)
    end
  end

  defp create_order(exchange, params) do
    Bourse.create_order(
      exchange,
      params["symbol"],
      params["type"],
      params["side"],
      params["amount"],
      Map.drop(params, ~w(symbol type side amount))
    )
  end

  defp order do
    %{"symbol" => "BTC/USDT:USDT", "type" => "market", "side" => "sell", "amount" => 1}
  end
end
