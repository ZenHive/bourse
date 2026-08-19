defmodule Bourse.Unified.RequestShape.Bybit do
  @moduledoc false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Symbol

  @month_ms 30 * 24 * 60 * 60 * 1000
  @three_hours_ms 3 * 60 * 60 * 1000

  @doc false
  @spec build(map(), String.t(), Exchange.t(), map()) :: map()
  def build(params, js_name, exchange, builder) when is_map(params) and is_map(builder) do
    build_method(params, js_name, exchange, builder)
  end

  defp build_method(params, name, exchange, _builder)
       when name in ["createOrder", "createMarketBuyOrderWithCost", "createMarketSellOrderWithCost"],
       do: create_order(params, name, exchange)

  defp build_method(params, "createOrders", exchange, _builder),
    do: batch_orders(params, exchange, &order_item(&1, exchange))

  defp build_method(params, "editOrder", exchange, _builder), do: edit_order(params, exchange)

  defp build_method(params, "editOrders", exchange, _builder),
    do: batch_orders(params, exchange, &edit_item(&1, exchange))

  defp build_method(params, "cancelOrder", _exchange, _builder), do: cancel_order(params)
  defp build_method(params, "cancelOrders", exchange, _builder), do: cancel_orders(params, exchange)

  defp build_method(params, "cancelOrdersForSymbols", exchange, _builder), do: cancel_orders_for_symbols(params, exchange)

  defp build_method(params, "cancelAllOrders", _exchange, _builder), do: cancel_all_orders(params)
  defp build_method(params, js_name, exchange, _builder), do: build_general(params, js_name, exchange)

  defp create_order(params, js_name, exchange) do
    params = market_cost_params(params, js_name)
    category = category(params, exchange)
    type = Map.get(params, "type", "market")
    side = Map.get(params, "side", if(js_name == "createMarketSellOrderWithCost", do: "sell", else: "buy"))
    trading_stop? = trading_stop?(params, category)

    %{"symbol" => native_symbol(params["symbol"], exchange), "category" => category}
    |> put_unless_nil("side", if(!trading_stop?, do: capitalize(side)))
    |> put_unless_nil("orderType", if(!trading_stop?, do: capitalize(type)))
    |> put_order_amount(params, type, side, category, trading_stop?, exchange)
    |> put_order_price(params, type, category, trading_stop?, exchange)
    |> put_passthrough(params, ~w(reduceOnly closeOnTrigger positionIdx isLeverage mmp))
    |> put_time_in_force(params)
    |> put_client_order_id(params, category)
    |> put_trigger(params, category, side, trading_stop?)
    |> put_attached_orders(params, category, trading_stop?)
    |> put_trailing(params, trading_stop?)
    |> put_hedged(params, category, side)
    |> clean()
  end

  defp market_cost_params(params, "createMarketBuyOrderWithCost") do
    params
    |> Map.put("type", "market")
    |> Map.put("side", "buy")
    |> Map.put("amount", -1)
  end

  defp market_cost_params(params, "createMarketSellOrderWithCost") do
    params
    |> Map.put("type", "market")
    |> Map.put("side", "sell")
    |> Map.put("amount", -1)
  end

  defp market_cost_params(params, _js_name), do: params

  defp put_order_amount(request, _params, _type, _side, _category, true, _exchange), do: request

  defp put_order_amount(request, %{"cost" => cost}, "market", "sell", "spot", false, _exchange) when not is_nil(cost),
    do: request |> Map.put("marketUnit", "quoteCoin") |> Map.put("qty", number_string(cost))

  defp put_order_amount(request, %{"amount" => amount, "price" => price}, "market", "sell", "spot", false, _exchange)
       when not is_nil(price),
       do: request |> Map.put("marketUnit", "quoteCoin") |> Map.put("qty", number_string(amount * price))

  defp put_order_amount(request, %{"cost" => cost}, "market", "buy", "spot", false, _exchange) when not is_nil(cost),
    do: Map.put(request, "qty", number_string(cost))

  defp put_order_amount(request, %{"amount" => amount, "price" => price}, "market", "buy", "spot", false, _exchange)
       when not is_nil(price), do: Map.put(request, "qty", number_string(amount * price))

  defp put_order_amount(
         request,
         %{"amount" => amount, "marketUnit" => "quoteCoin"},
         "market",
         _side,
         "spot",
         false,
         _exchange
       ), do: request |> Map.put("marketUnit", "quoteCoin") |> Map.put("qty", number_string(amount))

  defp put_order_amount(request, params, "market", _side, "spot", false, _exchange)
       when not is_map_key(params, "createMarketBuyOrderRequiresPrice") or
              :erlang.map_get("createMarketBuyOrderRequiresPrice", params) != false,
       do: request |> Map.put("marketUnit", "baseCoin") |> Map.put("qty", number_string(params["amount"]))

  defp put_order_amount(request, params, _type, _side, category, false, exchange),
    do:
      put_unless_nil(
        request,
        "qty",
        precise_number_string(params["amount"], request["symbol"], category, "amount", exchange)
      )

  defp put_order_price(request, params, "limit", category, false, exchange),
    do:
      put_unless_nil(
        request,
        "price",
        precise_number_string(params["price"], request["symbol"], category, "price", exchange)
      )

  defp put_order_price(request, _params, _type, _category, _trading_stop?, _exchange), do: request

  defp put_time_in_force(request, params) do
    value =
      cond do
        params["postOnly"] == true -> "PostOnly"
        is_binary(params["timeInForce"]) -> canonical_time_in_force(params["timeInForce"])
        true -> nil
      end

    put_unless_nil(request, "timeInForce", value)
  end

  defp canonical_time_in_force(value) do
    case String.downcase(value) do
      "postonly" -> "PostOnly"
      value -> String.upcase(value)
    end
  end

  defp put_client_order_id(request, params, category) do
    cond do
      is_binary(params["clientOrderId"]) -> Map.put(request, "orderLinkId", params["clientOrderId"])
      is_binary(params["orderLinkId"]) -> Map.put(request, "orderLinkId", params["orderLinkId"])
      category == "option" -> Map.put(request, "orderLinkId", fixture_uuid16(params))
      true -> request
    end
  end

  defp fixture_uuid16(params), do: params["clientOrderId"] || params["orderLinkId"]

  defp put_trigger(request, params, category, side, false) do
    trigger = params["triggerPrice"] || params["stopPrice"]
    stop_loss = scalar_trigger(params["stopLossPrice"])
    take_profit = scalar_trigger(params["takeProfitPrice"])

    apply_trigger(request, trigger, stop_loss, take_profit, params, category, side)
  end

  defp put_trigger(request, _params, _category, _side, _trading_stop?), do: request

  defp apply_trigger(request, trigger, _stop_loss, _take_profit, params, category, _side) when not is_nil(trigger) do
    request
    |> put_unless_nil("orderFilter", trigger_filter(category, "StopOrder"))
    |> put_unless_nil("triggerDirection", trigger_direction(params["triggerDirection"], category))
    |> Map.put("triggerPrice", number_string(trigger))
  end

  defp apply_trigger(request, nil, stop_loss, take_profit, _params, category, side)
       when not is_nil(stop_loss) or not is_nil(take_profit) do
    request
    |> put_unless_nil("orderFilter", trigger_filter(category, "tpslOrder"))
    |> Map.put("triggerDirection", attached_trigger_direction(side, stop_loss))
    |> Map.put("triggerPrice", number_string(stop_loss || take_profit))
    |> Map.put("reduceOnly", true)
  end

  defp apply_trigger(request, nil, nil, nil, _params, _category, _side), do: request

  defp trigger_filter("spot", filter), do: filter
  defp trigger_filter(_category, _filter), do: nil

  defp attached_trigger_direction("buy", nil), do: 2
  defp attached_trigger_direction("buy", _stop_loss), do: 1
  defp attached_trigger_direction(_side, nil), do: 1
  defp attached_trigger_direction(_side, _stop_loss), do: 2

  defp trigger_direction(_direction, "spot"), do: nil
  defp trigger_direction(direction, _category) when direction in [1, "1", "ascending", "above"], do: 1
  defp trigger_direction(_direction, _category), do: 2

  defp put_attached_orders(request, params, category, false) do
    request
    |> put_attached("sl", params["stopLoss"], category)
    |> put_attached("tp", params["takeProfit"], category)
  end

  defp put_attached_orders(request, params, _category, true) do
    request
    |> put_trading_stop("sl", params["stopLossPrice"], params["stopLossLimitPrice"], params["amount"])
    |> put_trading_stop("tp", params["takeProfitPrice"], params["takeProfitLimitPrice"], params["amount"])
    |> put_tpsl_mode()
  end

  defp put_attached(request, _prefix, nil, _category), do: request

  defp put_attached(request, prefix, value, category) do
    trigger = nested_value(value, ["triggerPrice", "stopPrice"]) || value
    limit = nested_value(value, ["price"])

    request
    |> Map.put(if(prefix == "sl", do: "stopLoss", else: "takeProfit"), number_string(trigger))
    |> put_unless_nil(prefix <> "OrderType", if(limit, do: "Limit", else: if(category == "spot", do: "Market")))
    |> put_unless_nil(prefix <> "LimitPrice", if(limit, do: number_string(limit)))
    |> then(fn request -> if limit, do: Map.put(request, "tpslMode", "Partial"), else: request end)
  end

  defp put_trading_stop(request, _prefix, nil, _limit, _amount), do: request

  defp put_trading_stop(request, prefix, trigger, limit, amount) do
    request
    |> Map.put(if(prefix == "sl", do: "stopLoss", else: "takeProfit"), number_string(trigger))
    |> Map.put(prefix <> "OrderType", if(limit, do: "Limit", else: "Market"))
    |> put_unless_nil(prefix <> "LimitPrice", if(limit, do: number_string(limit)))
    |> put_unless_nil(prefix <> "Size", positive_number_string(amount))
  end

  defp put_tpsl_mode(request) do
    partial? = request["slSize"] || request["tpSize"] || request["slLimitPrice"] || request["tpLimitPrice"]

    cond do
      partial? -> Map.put(request, "tpslMode", "Partial")
      request["stopLoss"] || request["takeProfit"] -> Map.put(request, "tpslMode", "Full")
      true -> request
    end
  end

  defp put_trailing(request, params, true) do
    trailing = params["trailingAmount"] || params["trailingStop"]

    if is_nil(trailing) do
      request
    else
      request
      |> Map.put("trailingStop", number_string(trailing))
      |> put_unless_nil(
        "activePrice",
        number_string(params["trailingTriggerPrice"] || params["activePrice"] || params["price"])
      )
    end
  end

  defp put_trailing(request, _params, _trading_stop?), do: request

  defp put_hedged(request, %{"hedged" => true} = params, category, side) when category != "spot" do
    effective_side = if params["reduceOnly"] == true, do: opposite(side), else: side
    request = Map.put(request, "positionIdx", position_index(effective_side))
    if params["reduceOnly"] == true, do: Map.delete(request, "reduceOnly"), else: request
  end

  defp put_hedged(request, _params, _category, _side), do: request

  defp position_index("buy"), do: 1
  defp position_index(_side), do: 2

  defp opposite("buy"), do: "sell"
  defp opposite(_side), do: "buy"

  defp trading_stop?(params, category) do
    category != "spot" and
      (not is_nil(params["trailingAmount"] || params["trailingStop"]) or
         (not is_nil(params["stopLossPrice"]) and not is_nil(params["takeProfitPrice"])) or
         params["tradingStopEndpoint"] == true)
  end

  defp batch_orders(%{"orders" => [first | _] = orders}, exchange, item_builder) do
    %{
      "category" => category(%{"symbol" => first["symbol"]}, exchange),
      "request" => Enum.map(orders, item_builder)
    }
  end

  defp batch_orders(_params, exchange, _item_builder) do
    raise Error.bad_request(
            exchange: exchange.id,
            message: "Bybit batch orders require a non-empty orders list",
            raw: %{"reason" => "non_empty_orders_required"}
          )
  end

  defp order_item(order, exchange) do
    order
    |> create_order("createOrder", exchange)
    |> Map.delete("category")
  end

  defp edit_order(params, exchange) do
    category = params["category"]
    # `find_market/3` keys on category, so an unset one resolves to no market and
    # would silently skip rounding. Derive it for precision only — the wire keeps
    # whatever the caller sent.
    precision_category = category || category(params, exchange)

    clean(%{
      "category" => category,
      "symbol" => params["symbol"],
      "orderId" => blank_to_nil(params["id"]),
      "orderLinkId" => params["clientOrderId"] || params["orderLinkId"],
      "clientOrderId" => params["clientOrderId"],
      "qty" => precise_number_string(params["amount"], params["symbol"], precision_category, "amount", exchange),
      "price" => precise_number_string(params["price"], params["symbol"], precision_category, "price", exchange)
    })
  end

  defp edit_item(order, exchange) do
    category = category(%{"symbol" => order["symbol"]}, exchange)
    symbol = native_symbol(order["symbol"], exchange)

    clean(%{
      "symbol" => symbol,
      "orderId" => order["id"],
      "qty" => precise_number_string(order["amount"], symbol, category, "amount", exchange),
      "price" => precise_number_string(order["price"], symbol, category, "price", exchange)
    })
  end

  defp cancel_order(params) do
    clean(%{
      "category" => params["category"],
      "symbol" => params["symbol"],
      "orderId" => params["id"],
      "orderLinkId" => params["orderLinkId"],
      "orderFilter" =>
        if(params["category"] == "spot", do: if(params["stop"] || params["trigger"], do: "StopOrder", else: "Order"))
    })
  end

  defp cancel_orders(params, exchange) do
    symbol = params["symbol"]
    native = native_symbol(symbol, exchange)

    requests =
      Enum.map(params["clientOrderIds"] || params["clientOids"] || [], &%{"symbol" => native, "orderLinkId" => &1}) ++
        Enum.map(params["ids"] || [], &%{"symbol" => native, "orderId" => &1})

    # `symbol` is already denormalized here (`build_final_params` runs before
    # RequestShape), and a bybit id like `LTCUSDT` is shared by the spot and
    # linear-swap markets — unresolvable back to a category. `apply_premarket`
    # resolved it from the still-unified symbol, so prefer that.
    %{"category" => category(%{"category" => params["category"], "symbol" => symbol}, exchange), "request" => requests}
  end

  defp cancel_orders_for_symbols(params, exchange) do
    orders = params["orders"] || []

    %{
      "category" => category(%{"symbol" => get_in(List.first(orders) || %{}, ["symbol"])}, exchange),
      "request" => Enum.map(orders, &%{"symbol" => native_symbol(&1["symbol"], exchange), "orderId" => &1["id"]})
    }
  end

  defp cancel_all_orders(params) do
    clean(%{
      "category" => params["category"],
      "symbol" => params["symbol"],
      "orderFilter" => if(params["stop"] || params["trigger"], do: "StopOrder")
    })
  end

  defp build_general(params, name, _exchange) when name in ["borrowCrossMargin", "repayCrossMargin"],
    do: %{"coin" => params["code"], "amount" => number_string(params["amount"])}

  defp build_general(params, "fetchCrossBorrowRate", _exchange), do: clean(%{"currency" => params["code"]})

  defp build_general(params, "fetchTransfers", _exchange), do: clean(%{"coin" => params["code"]})

  defp build_general(params, "setLeverage", _exchange), do: leverage_request(params)
  defp build_general(params, "setPositionMode", exchange), do: position_mode_request(params, exchange)

  defp build_general(params, "setMarginMode", _exchange), do: %{"setMarginMode" => margin_mode(params["margin_mode"])}

  defp build_general(params, "fetchOHLCV", _exchange), do: ohlcv_request(params)
  defp build_general(params, "fetchTickers", exchange), do: tickers_request(params, exchange)
  defp build_general(params, "fetchBorrowRateHistory", _exchange), do: borrow_rate_history(params)
  defp build_general(params, "transfer", _exchange), do: transfer_request(params)

  defp build_general(params, name, exchange)
       when name in ["fetchOrder", "fetchOpenOrder", "fetchClosedOrder", "fetchOrderClassic"],
       do: order_lookup(params, exchange, name)

  defp build_general(params, name, _exchange)
       when name in ["fetchOpenOrders", "fetchClosedOrders", "fetchCanceledOrders", "fetchCanceledAndClosedOrders"],
       do: orders_lookup(params, name)

  defp build_general(params, "fetchOrderTrades", exchange), do: order_trades_request(params, exchange)

  defp build_general(params, name, _exchange) when name in ["fetchTradingFee", "fetchPosition", "fetchPositionADLRank"],
    do: symbol_category(params)

  defp build_general(params, name, exchange)
       when name in ["fetchMarketLeverageTiers", "fetchDerivativesMarketLeverageTiers", "fetchLeverageTiers"],
       do: leverage_tiers_request(params, exchange)

  defp build_general(params, name, _exchange) when name in ["fetchDepositAddress", "fetchDepositAddressesByNetwork"],
    do: deposit_address_request(params)

  defp build_general(params, "fetchFutureMarkets", _exchange), do: future_markets_request(params)

  defp build_general(params, "fetchOption", _exchange),
    do: %{"category" => "option", "symbol" => option_symbol(params["symbol"])}

  defp build_general(params, "fetchOptionChain", _exchange),
    do: %{"category" => "option", "baseCoin" => params["code"] || option_base(params["symbol"])}

  defp build_general(params, "fetchVolatilityHistory", _exchange) do
    clean(%{
      "category" => "option",
      "baseCoin" => params["baseCoin"] || option_base(params["symbol"]),
      "period" => params["period"],
      "startTime" => params["startTime"],
      "endTime" => params["endTime"]
    })
  end

  defp build_general(params, "fetchAllGreeks", _exchange), do: option_greeks(params)

  defp build_general(params, name, exchange)
       when name in [
              "fetchPositionsHistory",
              "fetchFundingHistory",
              "fetchFundingRateHistory",
              "fetchMyTrades",
              "fetchMyLiquidations",
              "fetchLedger",
              "fetchOpenInterest",
              "fetchLeverage",
              "fetchMarginMode",
              "fetchPositions"
            ], do: history_request(params, name, exchange)

  defp build_general(_params, "fetchConvertCurrencies", _exchange), do: %{"accountType" => "eb_convert_uta"}
  defp build_general(params, "fetchConvertQuote", _exchange), do: convert_quote(params)
  defp build_general(params, "createConvertTrade", _exchange), do: %{"quoteTxId" => params["id"]}

  defp build_general(params, "fetchConvertTrade", _exchange),
    do: clean(%{"quoteTxId" => params["id"], "accountType" => "eb_convert_uta"})

  defp build_general(params, "fetchConvertTradeHistory", _exchange), do: clean(%{"limit" => params["limit"]})
  defp build_general(params, "fetchLongShortRatioHistory", exchange), do: long_short_ratio(params, exchange)
  defp build_general(params, "fetchBalance", exchange), do: balance_request(params, exchange)
  defp build_general(params, "withdraw", exchange), do: withdraw_request(params, exchange)
  defp build_general(params, _js_name, _exchange), do: params

  defp leverage_request(params) do
    value = number_string(params["leverage"])
    %{"category" => params["category"], "symbol" => params["symbol"], "buyLeverage" => value, "sellLeverage" => value}
  end

  defp position_mode_request(params, exchange) do
    symbol = params["symbol"]

    # `symbol` is already denormalized here, and a bybit id like `BTCUSDT` is
    # shared by the spot and linear-swap markets — unresolvable back to a
    # category. `apply_premarket` resolved it from the still-unified symbol.
    %{
      "category" => category(%{"category" => params["category"], "symbol" => symbol}, exchange),
      "symbol" => native_symbol(symbol, exchange),
      "mode" => if(params["hedge_mode"], do: 3, else: 0)
    }
  end

  defp margin_mode("cross"), do: "REGULAR_MARGIN"
  defp margin_mode("isolated"), do: "ISOLATED_MARGIN"
  defp margin_mode(value), do: value

  defp ohlcv_request(params) do
    clean(%{
      "category" => params["category"],
      "symbol" => params["symbol"],
      "interval" => params["interval"] || params["timeframe"] || "1",
      "start" => params["since"],
      "end" => params["until"],
      "limit" => params["limit"] || 200
    })
  end

  defp tickers_request(params, exchange) do
    category = params["category"] || category(params, exchange) || default_category(exchange)
    base = params["baseCoin"] || params["code"] || base_from_symbols(params["symbols"])
    base = if category == "option", do: base || "BTC", else: base

    clean(%{"category" => category, "baseCoin" => if(category == "option", do: base), "code" => params["code"]})
  end

  # When since is absent, window the last 30 days from now
  # (start = now - 30d, end = start + 30d). Never read nested "params".
  defp borrow_rate_history(params) do
    now = System.system_time(:millisecond)
    since = if is_integer(params["since"]), do: params["since"], else: now - @month_ms
    end_time = if is_integer(params["until"]), do: params["until"], else: since + @month_ms

    %{"currency" => params["code"], "startTime" => since, "endTime" => end_time}
  end

  defp transfer_request(params) do
    clean(%{
      "transferId" => params["transferId"],
      "fromAccountType" => account_type(params["from_account"]),
      "toAccountType" => account_type(params["to_account"]),
      "coin" => params["code"],
      "amount" => number_string(params["amount"])
    })
  end

  defp account_type("funding"), do: "FUND"
  defp account_type("fund"), do: "FUND"
  defp account_type(value) when is_binary(value), do: String.upcase(value)
  defp account_type(value), do: value

  defp order_lookup(params, exchange, js_name) do
    symbol = params["symbol"]

    clean(%{
      "category" => params["category"] || category(%{"symbol" => symbol}, exchange) || "spot",
      "symbol" => native_symbol(symbol, exchange),
      "orderId" => params["id"],
      "orderStatus" => params["status"] || if(js_name == "fetchClosedOrder", do: "Filled")
    })
  end

  defp orders_lookup(params, js_name) do
    category = params["category"] || default_order_category(params)

    clean(%{
      "category" => category,
      "symbol" => params["symbol"],
      # Linear/inverse require symbol OR settleCoin/baseCoin when no symbol is set.
      "settleCoin" => order_settle_coin(params, category),
      "orderFilter" => if(params["stop"] || params["trigger"], do: "StopOrder"),
      "orderStatus" => order_status(params, js_name),
      "limit" => present_value(params["limit"])
    })
  end

  # Bybit returns retCode 10005 ("Permission denied") for order/execution reads that
  # omit `category` — not a real auth failure. Default to linear.
  defp default_order_category(%{"category" => category}) when is_binary(category), do: category
  defp default_order_category(%{"symbol" => symbol}) when is_binary(symbol), do: nil
  defp default_order_category(_params), do: "linear"

  defp order_settle_coin(%{"settleCoin" => settle}, _category) when is_binary(settle), do: settle
  defp order_settle_coin(%{"symbol" => symbol}, _category) when is_binary(symbol), do: nil
  defp order_settle_coin(_params, category) when category in ["linear", "inverse"], do: "USDT"
  defp order_settle_coin(_params, _category), do: nil

  defp order_trades_request(params, exchange) do
    symbol = params["symbol"]
    category = params["category"] || category(%{"symbol" => symbol}, exchange) || "linear"

    clean(%{
      "category" => category,
      "symbol" => native_symbol(symbol, exchange),
      "orderId" => params["id"] || params["orderId"],
      "orderLinkId" => params["clientOrderId"] || params["orderLinkId"],
      "startTime" => params["since"],
      "endTime" => params["until"],
      "limit" => present_value(params["limit"])
    })
  end

  defp leverage_tiers_request(params, exchange) do
    symbol = params["symbol"]
    category = params["category"] || category(%{"symbol" => symbol}, exchange)

    clean(%{
      "category" => category,
      "symbol" => native_symbol(symbol, exchange)
    })
  end

  defp deposit_address_request(params) do
    clean(%{
      "coin" => params["coin"] || params["code"],
      "chainType" => params["network"] || params["chainType"]
    })
  end

  defp future_markets_request(params) do
    clean(%{
      "category" => params["category"],
      "limit" => params["limit"] || 1000,
      "cursor" => params["cursor"],
      "status" => params["status"]
    })
  end

  defp order_status(params, "fetchCanceledOrders"), do: params["orderStatus"] || "Cancelled"
  defp order_status(params, "fetchClosedOrders"), do: params["orderStatus"] || "Filled"
  defp order_status(_params, _js_name), do: nil

  defp symbol_category(params), do: clean(%{"category" => params["category"], "symbol" => params["symbol"]})

  defp history_request(_params, js_name, _exchange) when js_name in ["fetchLedger", "fetchMarginMode"], do: %{}

  defp history_request(params, js_name, exchange) do
    symbol = first_symbol(params) || params["symbol"]
    category = params["category"] || category(%{"symbol" => symbol}, exchange) || "linear"

    clean(%{
      "category" => category,
      "symbol" => native_symbol(symbol, exchange),
      "settleCoin" => settle_coin(params, js_name),
      "execType" => execution_type(js_name),
      "intervalTime" => history_interval(params, js_name),
      "period" => history_period(params, js_name),
      "startTime" => params["since"],
      "endTime" => funding_end_time(params, js_name),
      "limit" => history_limit(params, js_name),
      "size" => history_size(js_name)
    })
  end

  defp first_symbol(%{"symbols" => [symbol | _]}) when is_binary(symbol), do: symbol
  defp first_symbol(_params), do: nil

  defp execution_type("fetchMyTrades"), do: "Trade"
  defp execution_type("fetchFundingHistory"), do: "Funding"
  defp execution_type("fetchMyLiquidations"), do: "BustTrade"
  defp execution_type(_js_name), do: nil

  defp history_interval(params, "fetchOpenInterest"), do: params["timeframe"] || "1h"
  defp history_interval(_params, _js_name), do: nil

  defp history_period(params, "fetchLongShortRatioHistory"), do: params["timeframe"] || "1d"
  defp history_period(_params, _js_name), do: nil

  defp history_size("fetchFundingHistory"), do: "100"
  defp history_size(_js_name), do: nil

  defp funding_end_time(%{"since" => since}, "fetchFundingRateHistory") when is_integer(since),
    do: since + @three_hours_ms

  defp funding_end_time(params, _js_name), do: params["until"]

  defp history_limit(%{"limit" => nil}, "fetchPositions"), do: "200"
  defp history_limit(params, "fetchPositions") when not is_map_key(params, "limit"), do: "200"
  defp history_limit(params, _js_name), do: present_value(params["limit"])

  defp settle_coin(params, "fetchPositions") do
    if is_nil(params["symbol"]), do: "USDT"
  end

  defp settle_coin(_params, _js_name), do: nil

  defp convert_quote(params) do
    %{
      "fromCoin" => params["from_code"],
      "toCoin" => params["to_code"],
      "requestAmount" => number_string(params["amount"]),
      "requestCoin" => params["from_code"],
      "accountType" => "eb_convert_uta"
    }
  end

  defp long_short_ratio(params, exchange) do
    history_request(params, "fetchLongShortRatioHistory", exchange)
  end

  defp balance_request(params, exchange) do
    type = params["type"] || get_in(exchange.options, ["fetchBalance", "defaultType"])

    account =
      if type in ["fund", "funding"],
        do: "FUND",
        else:
          if(exchange.options["unifiedMarginStatus"] == 3 and params["subType"] == "inverse",
            do: "CONTRACT",
            else: "UNIFIED"
          )

    %{"accountType" => account}
  end

  defp withdraw_request(params, exchange) do
    account_type =
      params["accountType"] || if(exchange.options["enableUnifiedAccount"] == false, do: "SPOT", else: "UTA")

    clean(%{
      "coin" => params["code"],
      "amount" => number_string(params["amount"]),
      "address" => params["address"],
      "tag" => blank_to_nil(params["tag"]),
      "chain" => withdraw_chain(params["network"]),
      "accountType" => account_type
    })
  end

  defp withdraw_chain("TRC20"), do: "TRX"
  defp withdraw_chain(network), do: network

  # Option greeks default baseCoin to "BTC", consistent with tickers_request.
  defp option_greeks(params) do
    symbol = params["symbol"] || first_symbol(params)
    base = params["baseCoin"] || params["code"] || option_base(symbol) || "BTC"

    clean(%{
      "category" => "option",
      "baseCoin" => base,
      "symbol" => option_symbol(symbol)
    })
  end

  defp option_symbol(nil), do: nil
  defp option_symbol(symbol) when is_binary(symbol), do: option_unified_symbol(symbol)

  defp option_unified_symbol(symbol) do
    case Regex.run(~r/^([A-Z0-9]+)\/([A-Z0-9]+):[A-Z0-9]+-(\d{2})(\d{2})(\d{2})-(.+)$/, symbol) do
      [_, base, quote, year, month, day, tail] ->
        suffix = if quote == "USDC", do: "", else: "-" <> quote
        base <> "-" <> day <> option_month(month) <> year <> "-" <> tail <> suffix

      _ ->
        symbol
    end
  end

  defp option_base(symbol) when is_binary(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, %{base: base}} -> base
      _ -> native_option_base(symbol)
    end
  end

  defp option_base(_symbol), do: nil

  defp native_option_base(symbol) do
    if String.contains?(symbol, "-") do
      symbol |> String.split(["/", "-"], parts: 2) |> hd()
    else
      case Enum.find(["USDT", "USDC", "USD"], &String.ends_with?(symbol, &1)) do
        nil -> symbol
        quote -> String.trim_trailing(symbol, quote)
      end
    end
  end

  defp option_month(month) do
    Enum.at(~w(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC), String.to_integer(month) - 1)
  end

  defp category(%{"category" => category}, _exchange) when is_binary(category), do: category

  defp category(%{"symbol" => symbol}, exchange) when is_binary(symbol) do
    if Regex.match?(~r/^[A-Z0-9]+-\d{1,2}[A-Z]{3}\d{2}-/, symbol) do
      "option"
    else
      category_from_parsed_symbol(symbol, exchange)
    end
  end

  defp category(_params, _exchange), do: nil

  defp category_from_parsed_symbol(symbol, exchange) do
    case Symbol.parse_extended(symbol) do
      {:ok, parsed} ->
        parsed_category(parsed)

      _ ->
        if String.ends_with?(native_symbol(symbol, exchange), "USD"), do: "inverse", else: "spot"
    end
  end

  defp parsed_category(%{settle: settle} = parsed) do
    case Symbol.detect_market_type(parsed) do
      :spot -> "spot"
      :option -> "option"
      type when type in [:swap, :future] -> if(settle in ["USDT", "USDC"], do: "linear", else: "inverse")
    end
  end

  defp default_category(exchange) do
    case exchange.options["defaultType"] do
      "spot" -> "spot"
      _ -> "linear"
    end
  end

  defp native_symbol(nil, _exchange), do: nil
  defp native_symbol(symbol, exchange) when is_binary(symbol), do: Symbol.to_exchange_id(symbol, exchange)

  defp base_from_symbols([symbol | _]) do
    case Symbol.parse_extended(symbol) do
      {:ok, %{base: base}} -> base
      _ -> nil
    end
  end

  defp base_from_symbols(_symbols), do: nil

  defp put_passthrough(request, params, keys), do: Enum.reduce(keys, request, &put_unless_nil(&2, &1, params[&1]))
  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp nested_value(value, keys) when is_map(value), do: Enum.find_value(keys, &Map.get(value, &1))
  defp nested_value(_value, _keys), do: nil
  defp scalar_trigger(value) when is_map(value), do: nested_value(value, ["triggerPrice", "stopPrice"])
  defp scalar_trigger(value), do: value

  defp positive_number_string(value) when is_number(value) and value > 0, do: number_string(value)
  defp positive_number_string(_value), do: nil
  defp number_string(nil), do: nil
  defp number_string(value) when is_integer(value), do: Integer.to_string(value)

  defp number_string(value) when is_float(value) do
    value |> Decimal.from_float() |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp number_string(value) when is_binary(value), do: value
  defp number_string(value), do: to_string(value)

  defp precise_number_string(nil, _symbol, _category, _field, _exchange), do: nil

  defp precise_number_string(value, symbol, category, field, exchange) do
    with market when not is_nil(market) <- find_market(exchange, symbol, category),
         step when not is_nil(step) <- market_step(market, field),
         parsed when not is_nil(parsed) <- decimal_or_nil(value) do
      parsed
      |> Decimal.div(step)
      |> Decimal.round(0, :down)
      |> Decimal.mult(step)
      |> decimal_string()
    else
      _ -> number_string(value)
    end
  end

  defp find_market(%Exchange{markets: markets}, symbol, category) when is_list(markets) and is_binary(symbol) do
    Enum.find(markets, &(market_field(&1, "id", :id) == symbol and market_category?(&1, category)))
  end

  defp find_market(_exchange, _symbol, _category), do: nil

  defp market_category?(market, "spot"), do: market_field(market, "spot", :spot) == true
  defp market_category?(market, "linear"), do: market_field(market, "linear", :linear) == true
  defp market_category?(market, "inverse"), do: market_field(market, "inverse", :inverse) == true
  defp market_category?(market, "option"), do: market_field(market, "option", :option) == true
  defp market_category?(_market, _category), do: false

  defp market_step(market, "amount") do
    market
    |> market_field("precision", :precision)
    |> market_field("amount", :amount)
    |> decimal_or_nil()
  end

  defp market_step(market, "price") do
    market
    |> market_field("precision", :precision)
    |> market_field("price", :price)
    |> decimal_or_nil()
  end

  defp market_field(map, string_key, atom_key) when is_map(map), do: Map.get(map, string_key) || Map.get(map, atom_key)
  defp market_field(_map, _string_key, _atom_key), do: nil

  defp decimal_or_nil(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> nil
    end
  end

  defp decimal_string(value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp capitalize(value) when is_binary(value) do
    case String.next_grapheme(value) do
      {head, tail} -> String.upcase(head) <> String.downcase(tail)
      nil -> value
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp present_value(value) when value in [nil, ""], do: nil
  defp present_value(value), do: value
  defp clean(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
