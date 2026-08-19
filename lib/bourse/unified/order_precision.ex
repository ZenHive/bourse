defmodule Bourse.Unified.OrderPrecision do
  @moduledoc false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Symbol

  @precision_venues ~w(bybit derive hyperliquid lighter okx)
  @rounding_venues ~w(bybit derive hyperliquid okx)
  @precision_order_methods ~w(
    createMarketBuyOrderWithCost createMarketSellOrderWithCost createOrder createOrders
    createOrderWithTakeProfitAndStopLoss createTwapOrder editOrder editOrders
  )
  @precision_matrix for venue <- @precision_venues,
                        method <- @precision_order_methods,
                        do: {venue, method}
  @cost_order_methods ~w(createMarketBuyOrderWithCost createMarketSellOrderWithCost)
  @amount_keys ~w(amount newSz sz)
  @cost_keys ~w(cost)
  @price_keys ~w(
    activePx activePrice callbackSpread newActivePx newOrdPx newPrice newPx newSlOrdPx
    newSlTriggerPx newTpOrdPx newTpTriggerPx orderPx price px slOrdPx slTriggerPx
    stopLossPrice stopPrice takeProfitPrice tpOrdPx tpTriggerPx trailingTriggerPrice triggerPrice triggerPx
  )

  @doc "Returns every venue and unified method protected by the order-precision guard."
  @spec precision_matrix() :: [{String.t(), String.t()}]
  def precision_matrix, do: @precision_matrix

  @doc false
  @spec guard_dispatch!(map(), Exchange.t(), String.t(), keyword()) :: {map(), Exchange.t()}
  def guard_dispatch!(params, %Exchange{} = exchange, js_name, opts)
      when is_map(params) and is_binary(js_name) and is_list(opts) do
    if guarded_dispatch?(exchange, js_name, opts) do
      prepare_dispatch!(params, exchange, js_name, opts)
    else
      {params, exchange}
    end
  end

  defp guarded_dispatch?(%Exchange{id: id}, js_name, opts) do
    {id, js_name} in @precision_matrix and Keyword.has_key?(opts, :endpoint_path)
  end

  defp prepare_dispatch!(%{"orders" => orders} = params, exchange, js_name, opts) when is_list(orders) and orders != [] do
    shared = Map.delete(params, "orders")
    precision_keys = @amount_keys ++ @cost_keys ++ @price_keys

    {orders, markets} =
      Enum.map_reduce(orders, [], fn order, markets ->
        {prepared, market} = prepare_order!(Map.merge(shared, order), exchange, js_name, opts)
        {Map.merge(order, Map.take(prepared, precision_keys)), [market | markets]}
      end)

    {Map.put(params, "orders", orders), scope_exchange(exchange, markets)}
  end

  defp prepare_dispatch!(params, exchange, js_name, opts) do
    {params, market} = prepare_order!(params, exchange, js_name, opts)
    {params, scope_exchange(exchange, [market])}
  end

  defp prepare_order!(params, exchange, js_name, opts) do
    required_fields = required_fields(params, js_name)

    if required_fields == [] do
      {params, nil}
    else
      symbol = order_symbol(params)

      case find_market(exchange, symbol, params, opts) do
        {:ok, market} ->
          ensure_market_precision!(exchange, js_name, symbol, market, required_fields)
          {snap_order(params, exchange, js_name, market), market}

        {:error, reason} ->
          raise precision_error(exchange, js_name, symbol, required_fields, reason)
      end
    end
  end

  defp required_fields(params, js_name) do
    amount? =
      present_value?(params, @amount_keys) or (js_name in @cost_order_methods and present_value?(params, @cost_keys))

    []
    |> maybe_require(:amount, amount?)
    |> maybe_require(:price, present_value?(params, @price_keys))
  end

  defp maybe_require(fields, field, true), do: [field | fields]
  defp maybe_require(fields, _field, false), do: fields

  defp present_value?(params, keys) do
    Enum.any?(keys, &(not is_nil(Map.get(params, &1))))
  end

  defp order_symbol(params), do: params["symbol"] || params["instId"] || params["instrument_name"]

  defp find_market(%Exchange{markets: markets} = exchange, symbol, params, opts)
       when is_list(markets) and markets != [] and is_binary(symbol) do
    matches = Enum.filter(markets, &market_matches?(&1, symbol, exchange))
    explicit_category = params["category"]
    inferred_category = Keyword.get(opts, :market_family) || category_for_type(opts[:market_type])
    market = choose_market(matches, symbol, explicit_category, inferred_category)

    case market do
      nil -> {:error, :market_not_found}
      market -> {:ok, market}
    end
  end

  defp find_market(%Exchange{markets: markets}, _symbol, _params, _opts) when markets in [nil, []],
    do: {:error, :markets_not_loaded}

  defp find_market(_exchange, _symbol, _params, _opts), do: {:error, :market_not_found}

  defp choose_market(matches, _symbol, category, _inferred) when not is_nil(category),
    do: Enum.find(matches, &market_category?(&1, to_string(category)))

  defp choose_market(matches, symbol, nil, inferred) do
    Enum.find(matches, &(market_field(&1, :symbol) == symbol)) || choose_inferred_market(matches, inferred)
  end

  defp choose_inferred_market(matches, nil), do: List.first(matches)

  defp choose_inferred_market(matches, category),
    do: Enum.find(matches, &market_category?(&1, to_string(category))) || one_market(matches)

  defp one_market([market]), do: market
  defp one_market(_markets), do: nil

  defp market_matches?(market, symbol, %Exchange{id: id} = exchange)
       when is_map(market) and id in ["hyperliquid", "lighter"] do
    market_id = market_field(market, :id)
    market_symbol = market_field(market, :symbol)

    market_id == symbol or market_symbol == symbol or
      (is_binary(market_symbol) and Symbol.to_exchange_id(market_symbol, exchange) == symbol)
  end

  defp market_matches?(market, symbol, _exchange) when is_map(market),
    do: market_field(market, :id) == symbol or market_field(market, :symbol) == symbol

  defp market_matches?(_market, _symbol, _exchange), do: false

  defp market_category?(market, "spot"), do: market_field(market, :spot) == true
  defp market_category?(market, "linear"), do: market_field(market, :linear) == true
  defp market_category?(market, "inverse"), do: market_field(market, :inverse) == true
  defp market_category?(market, "option"), do: market_field(market, :option) == true
  defp market_category?(_market, _category), do: false

  defp category_for_type(type) when type in [:spot, :option], do: Atom.to_string(type)
  defp category_for_type(type) when type in [:swap, :future], do: nil
  defp category_for_type(type) when type in ["spot", "linear", "inverse", "option"], do: type
  defp category_for_type(_type), do: nil

  defp ensure_market_precision!(exchange, js_name, symbol, market, required_fields) do
    precision = market_field(market, :precision)
    missing = Enum.reject(required_fields, &usable_precision?(market_field(precision, &1)))

    if missing != [] do
      raise precision_error(exchange, js_name, symbol, missing, :missing_precision)
    end
  end

  defp snap_order(params, %Exchange{id: id}, js_name, market) when id in @rounding_venues do
    amount_keys = if js_name in @cost_order_methods, do: @amount_keys ++ @cost_keys, else: @amount_keys

    params
    |> snap_keys(amount_keys, market, :amount, id)
    |> snap_keys(@price_keys, market, :price, id)
  end

  defp snap_order(params, _exchange, _js_name, _market), do: params

  defp snap_keys(params, keys, market, field, venue) do
    step = market |> market_field(:precision) |> market_field(field)

    Enum.reduce(keys, params, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} when not is_nil(value) ->
          Map.put(acc, key, snap_value(value, step, rounding_mode(venue, field), venue))

        _ ->
          acc
      end
    end)
  end

  defp snap_value(original, step, rounding_mode, venue) do
    original
    |> Decimal.cast()
    |> snap_casted(original, step, rounding_mode, venue)
  end

  defp snap_casted({:ok, value}, _original, step, rounding_mode, venue) do
    # Market precision already passed usable_precision?/1. A failed step cast
    # is a spec bug, not caller input — classified keep-raise MatchError.
    {:ok, step} = Decimal.cast(step)

    rounded = value |> Decimal.div(step) |> Decimal.round(0, rounding_mode) |> Decimal.mult(step)

    if venue == "okx" and Decimal.equal?(rounded, 0) and not Decimal.equal?(value, 0),
      do: decimal_string(value),
      else: decimal_string(rounded)
  end

  defp snap_casted(:error, original, _step, _rounding_mode, venue) do
    # Caller input, not an internal invariant. Unified.call/5 converts this
    # reason to {:error, %Error{}} at the public non-bang boundary.
    raise Error.invalid_parameters(
            exchange: venue,
            message: "Cannot snap order value #{inspect(original)} to market precision: expected a number",
            raw: %{"reason" => "invalid_numeric", "value" => original}
          )
  end

  defp rounding_mode("bybit", _field), do: :down
  defp rounding_mode(_venue, :amount), do: :down
  defp rounding_mode(_venue, :price), do: :half_up

  defp decimal_string(decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp scope_exchange(exchange, markets) do
    case markets |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> exchange
      resolved -> Exchange.put_markets(exchange, resolved)
    end
  end

  defp usable_precision?(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> Decimal.positive?(decimal)
      :error -> false
    end
  end

  defp market_field(map, field) when is_map(map), do: Map.get(map, field, Map.get(map, Atom.to_string(field)))
  defp market_field(_map, _field), do: nil

  defp precision_error(exchange, js_name, symbol, missing, reason) do
    fields = missing |> Enum.reverse() |> Enum.map_join(", ", &to_string/1)
    symbol = symbol || "(missing symbol)"

    Error.invalid_order(
      exchange: exchange.id,
      message:
        "Cannot dispatch #{js_name} for #{symbol}: missing instrument precision (#{fields}). " <>
          "Call Bourse.load_markets/1 and use the returned exchange.",
      raw: %{
        "order_precision" => %{
          "method" => js_name,
          "missing" => Enum.map(missing, &to_string/1),
          "reason" => to_string(reason),
          "symbol" => symbol
        }
      }
    )
  end
end
