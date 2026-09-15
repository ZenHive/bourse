defmodule Bourse.Unified.OrderOptions do
  @moduledoc "Normalizes unified order controls before venue selection and refuses unsupported protection."

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified

  @aliases [
    {"trigger_price", "triggerPrice"},
    {"stop_loss_price", "stopLossPrice"},
    {"take_profit_price", "takeProfitPrice"},
    {"time_in_force", "timeInForce"},
    {"reduce_only", "reduceOnly"}
  ]
  @conditional_keys ~w(trigger_price stop_loss_price take_profit_price)
  @order_methods ~w(create_order create_orders edit_order edit_orders create_order_with_take_profit_and_stop_loss
    create_spot_order create_spot_orders create_contract_order create_contract_orders create_swap_order
    create_uta_order create_uta_orders create_trailing_amount_order create_trailing_percent_order create_twap_order
    create_market_buy_order_with_cost create_market_sell_order_with_cost create_market_order_with_cost
    edit_contract_order edit_spot_order)a
  @built_order_methods ~w(create_order create_orders edit_order edit_orders
    create_order_with_take_profit_and_stop_loss create_market_buy_order_with_cost create_market_sell_order_with_cost create_twap_order)a
  @binance ~w(binance binanceusdm binancecoinm)

  @doc "Dispatches a public unified call after normalizing and checking its order controls."
  @spec call(Exchange.t(), atom(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(exchange, method, capability, params, opts) do
    with {:ok, params} <- Unified.validate_param_values(params, method),
         {:ok, params} <- prepare(exchange, method, params),
         :ok <- check_route(exchange, method, params, opts) do
      Unified.call(exchange, method, capability, params, opts)
    end
  end

  @doc "Resolves aliases and checks that the venue builder can preserve every requested control."
  @spec prepare(Exchange.t(), atom(), map()) :: {:ok, map()} | {:error, Error.t()}
  def prepare(%Exchange{} = exchange, method, params) when method in @order_methods do
    with {:ok, canonical} <- canonicalize(params, exchange),
         :ok <- validate_controls(canonical, exchange, method),
         {:ok, canonical} <- prepare_children(canonical, exchange, method) do
      {:ok, venue_keys(canonical, exchange, method)}
    end
  end

  def prepare(_exchange, _method, params), do: {:ok, params}

  defp canonicalize(params, exchange) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    Enum.reduce_while(@aliases, {:ok, params}, fn {canonical, legacy}, {:ok, acc} ->
      case {Map.fetch(acc, canonical), Map.fetch(acc, legacy)} do
        {{:ok, value}, {:ok, other}} when value != other ->
          {:halt, invalid(exchange, "conflicting #{canonical} and #{legacy}")}

        {:error, {:ok, value}} ->
          {:cont, {:ok, acc |> Map.delete(legacy) |> Map.put(canonical, value)}}

        _ ->
          {:cont, {:ok, Map.delete(acc, legacy)}}
      end
    end)
  end

  defp prepare_children(%{"orders" => orders, "action" => _} = params, exchange, _method) when is_list(orders) do
    if Enum.any?(orders, &has_controls?/1),
      do: invalid(exchange, "native action overrides cannot be combined with child order controls"),
      else: {:ok, params}
  end

  defp prepare_children(%{"orders" => orders} = params, exchange, method) when is_list(orders) do
    orders
    |> Enum.reduce_while({:ok, []}, fn order, {:ok, acc} ->
      case prepare(exchange, method, order) do
        {:ok, child} -> {:cont, {:ok, [child | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, children} -> {:ok, Map.put(params, "orders", Enum.reverse(children))}
      {:error, _} = error -> error
    end
  end

  defp prepare_children(params, _exchange, _method), do: {:ok, params}

  defp has_controls?(params) do
    keys = Enum.map(Map.keys(params), &to_string/1)
    Enum.any?(@aliases, fn {canonical, legacy} -> canonical in keys or legacy in keys end)
  end

  defp validate_controls(params, exchange, method) do
    requested = Enum.filter(@conditional_keys, &Map.has_key?(params, &1))
    controls = Enum.filter(@aliases, fn {key, _alias} -> Map.has_key?(params, key) end)

    with :ok <- validate_placement(params, exchange, method, controls),
         :ok <- validate_edit_controls(params, exchange, method, controls),
         :ok <- validate_control_values(params, exchange),
         :ok <- validate_conditionals(params, exchange, method, requested) do
      validate_time_in_force(params, exchange)
    end
  end

  defp validate_placement(_params, _exchange, _method, []), do: :ok

  defp validate_placement(%{"orders" => _}, exchange, _method, _controls),
    do: invalid(exchange, "batch order controls must be supplied on each order")

  defp validate_placement(%{"action" => _}, exchange, _method, _controls),
    do: invalid(exchange, "order controls cannot be combined with a native action override")

  defp validate_placement(_params, exchange, method, _controls) when method not in @built_order_methods,
    do: invalid(exchange, "#{method} cannot express these order controls")

  defp validate_placement(_params, exchange, :create_twap_order, controls) do
    if Enum.any?(controls, fn {key, _alias} -> key != "reduce_only" or exchange.id != "hyperliquid" end),
      do: invalid(exchange, "this TWAP operation cannot express these controls"),
      else: :ok
  end

  defp validate_placement(_params, _exchange, _method, _controls), do: :ok

  defp validate_edit_controls(_params, _exchange, _method, []), do: :ok

  defp validate_edit_controls(_params, %Exchange{id: venue} = exchange, method, _controls)
       when method in [:edit_order, :edit_orders] and venue in ["bybit", "hyperliquid" | @binance],
       do: invalid(exchange, "#{venue} order edits cannot express these controls")

  defp validate_edit_controls(%{"time_in_force" => _}, %Exchange{id: "deribit"} = exchange, :edit_order, _controls),
    do: invalid(exchange, "Deribit order edits cannot change time_in_force")

  defp validate_edit_controls(params, %Exchange{id: "okx"} = exchange, method, _controls)
       when method in [:edit_order, :edit_orders] do
    if Enum.any?(~w(reduce_only time_in_force), &Map.has_key?(params, &1)),
      do: invalid(exchange, "OKX order edits cannot express reduce_only or time_in_force"),
      else: :ok
  end

  defp validate_edit_controls(_params, _exchange, _method, _controls), do: :ok

  defp validate_control_values(params, exchange) do
    with :ok <- refuse_nil_controls(params, exchange),
         :ok <- refuse_non_numeric_prices(params, exchange),
         :ok <- refuse_invalid_reduce_only(params, exchange) do
      refuse_invalid_time_in_force(params, exchange)
    end
  end

  defp refuse_nil_controls(params, exchange) do
    if Enum.any?(@aliases, fn {key, _alias} -> Map.fetch(params, key) == {:ok, nil} end),
      do: invalid(exchange, "order controls cannot be nil"),
      else: :ok
  end

  defp refuse_non_numeric_prices(params, exchange) do
    if Enum.any?(@conditional_keys, &(Map.has_key?(params, &1) and not numeric_price?(params[&1]))),
      do: invalid(exchange, "trigger and protective prices must be numeric"),
      else: :ok
  end

  defp refuse_invalid_reduce_only(params, exchange) do
    cond do
      Map.has_key?(params, "reduce_only") and not is_boolean(params["reduce_only"]) ->
        invalid(exchange, "reduce_only must be a boolean")

      params["reduce_only"] == true and exchange.id in ["alpaca", "coinbaseexchange"] ->
        invalid(exchange, "this order cannot express reduce_only")

      true ->
        :ok
    end
  end

  defp refuse_invalid_time_in_force(params, exchange) do
    if Map.has_key?(params, "time_in_force") and not is_binary(params["time_in_force"]),
      do: invalid(exchange, "time_in_force must be a string"),
      else: :ok
  end

  defp numeric_price?(value) when is_number(value), do: true

  defp numeric_price?(value) when is_binary(value), do: match?({_parsed, ""}, Float.parse(value))

  defp numeric_price?(%Decimal{}), do: true
  defp numeric_price?(_value), do: false

  defp validate_conditionals(_params, _exchange, _method, []), do: :ok

  defp validate_conditionals(params, exchange, method, requested) do
    cond do
      "trigger_price" in requested and length(requested) > 1 ->
        invalid(exchange, "trigger_price cannot be combined with stop_loss_price or take_profit_price")

      trailing_selector?(params) ->
        invalid(exchange, "conditional prices cannot be combined with a trailing or trading-stop selector")

      exchange.id in @binance and length(requested) > 1 ->
        invalid(exchange, "Binance conditional orders accept one protective leg")

      not conditional_supported?(exchange.id, method, params, requested) ->
        invalid(exchange, "#{method} cannot express #{Enum.join(requested, ", ")} with this order type")

      true ->
        :ok
    end
  end

  defp trailing_selector?(params) do
    Enum.any?(
      ~w(trailingAmount trailingPercent trailingPrice trailingStop tradingStopEndpoint callbackRatio callbackSpread),
      &(Map.get(params, &1) not in [nil, false])
    )
  end

  defp conditional_supported?("okx", :create_order, params, ["trigger_price"]),
    do: params["type"] != "oco" and params["ordType"] != "oco"

  defp conditional_supported?("okx", :create_order, _params, _requested), do: true

  defp conditional_supported?("okx", :edit_order, params, ["trigger_price"]),
    do: params["type"] == "trigger" or not is_nil(params["algoId"])

  defp conditional_supported?("okx", :edit_order, _params, _requested), do: true

  defp conditional_supported?("bybit", :create_order, _params, _requested), do: true
  defp conditional_supported?("bybit", :create_orders, _params, requested), do: length(requested) == 1

  defp conditional_supported?(venue, :create_order, _params, _requested) when venue in @binance, do: true

  defp conditional_supported?("deribit", method, params, ["trigger_price"]) when method in [:create_order, :edit_order],
    do: params["type"] in ~w(stop_market stop_limit take_market take_limit)

  defp conditional_supported?("alpaca", :create_order, params, ["trigger_price"]),
    do: params["type"] in ~w(stop stop_limit)

  defp conditional_supported?(_venue, _method, _params, _requested), do: false

  defp validate_time_in_force(%{"time_in_force" => tif} = params, %Exchange{id: "okx"} = exchange) do
    if tif == "GTC" or
         (params["type"] == "limit" and tif in ["IOC", "FOK"] and
            params["postOnly"] not in [true, "true", 1, "1"] and params["ordType"] in [nil, String.downcase(tif)] and
            not Enum.any?(@conditional_keys, &Map.has_key?(params, &1))),
       do: :ok,
       else: invalid(exchange, "this OKX order cannot express time_in_force=#{inspect(tif)}")
  end

  defp validate_time_in_force(%{"time_in_force" => tif} = params, %Exchange{id: "bybit"} = exchange) do
    tif = String.upcase(tif)

    if (params["type"] == "market" and tif != "IOC") or (params["postOnly"] == true and tif != "POSTONLY"),
      do: invalid(exchange, "this Bybit order cannot express time_in_force=#{inspect(tif)}"),
      else: :ok
  end

  defp validate_time_in_force(%{"time_in_force" => tif} = params, %Exchange{id: "hyperliquid"} = exchange) do
    if tif in ["GTC", "IOC", "ALO", "PO"] and (params["type"] != "market" or tif == "IOC"),
      do: :ok,
      else: invalid(exchange, "unsupported time_in_force=#{inspect(tif)}")
  end

  defp validate_time_in_force(_params, _exchange), do: :ok

  defp venue_keys(params, %Exchange{id: "okx"}, _method) do
    params =
      case params["time_in_force"] do
        "IOC" -> Map.put(params, "type", "ioc")
        "FOK" -> Map.put(params, "type", "fok")
        _ -> params
      end

    rename(params, @aliases)
  end

  defp venue_keys(params, %Exchange{id: venue}, _method) when venue in ["bybit", "hyperliquid", "lighter"],
    do: rename(params, @aliases)

  defp venue_keys(params, %Exchange{id: venue}, method)
       when venue in @binance and method in [:create_orders, :edit_orders], do: rename(params, @aliases)

  defp venue_keys(params, %Exchange{id: "alpaca"}, _method), do: rename(params, [{"trigger_price", "stop_price"}])

  defp venue_keys(params, _exchange, _method), do: params

  defp check_route(%Exchange{id: venue} = exchange, :create_order, params, opts) when venue in @binance do
    if Enum.any?(@conditional_keys, &Map.has_key?(params, &1)) do
      with {:ok, shapes} <- request_shapes(exchange, :create_order, params, opts) do
        require_algo_shapes(shapes, exchange)
      end
    else
      :ok
    end
  end

  defp check_route(%Exchange{id: venue} = exchange, :create_orders, %{"orders" => orders} = params, opts)
       when venue in ["bybit", "okx"] do
    shared = Map.delete(params, "orders")

    Enum.reduce_while(orders, :ok, fn child, :ok ->
      case check_route(exchange, :create_order, Map.merge(child, shared), opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_route(%Exchange{id: "bybit"} = exchange, method, params, opts)
       when method in [:create_order, :create_market_buy_order_with_cost, :create_market_sell_order_with_cost] do
    conditional? = Enum.any?(~w(triggerPrice stopLossPrice takeProfitPrice), &Map.has_key?(params, &1))

    if conditional? or params["reduceOnly"] == true do
      with {:ok, [shape]} <- request_shapes(exchange, method, params, opts) do
        validate_bybit_category(shape["category"], params, conditional?, exchange)
      end
    else
      :ok
    end
  end

  defp check_route(%Exchange{id: "okx"} = exchange, method, %{"reduceOnly" => true} = params, opts)
       when method in [:create_order, :create_market_buy_order_with_cost, :create_market_sell_order_with_cost] do
    with {:ok, [shape]} <- request_shapes(exchange, method, params, opts) do
      if shape["tdMode"] == "cash",
        do: invalid(exchange, "OKX cash orders cannot express reduce_only"),
        else: :ok
    end
  end

  defp check_route(_exchange, _method, _params, _opts), do: :ok

  defp require_algo_shapes(shapes, exchange) do
    if Enum.all?(
         shapes,
         &(&1["algoType"] == "CONDITIONAL" and &1["type"] in ~w(STOP STOP_MARKET TAKE_PROFIT TAKE_PROFIT_MARKET))
       ),
       do: :ok,
       else: invalid(exchange, "selected Binance route cannot express this conditional order")
  end

  defp validate_bybit_category("option", _params, true, exchange),
    do: invalid(exchange, "Bybit options cannot express trigger controls")

  defp validate_bybit_category("spot", %{"reduceOnly" => true}, _conditional?, exchange),
    do: invalid(exchange, "Bybit spot cannot express reduce_only")

  defp validate_bybit_category("spot", params, _conditional?, exchange) do
    if params["stopLossPrice"] != nil and params["takeProfitPrice"] != nil,
      do: invalid(exchange, "Bybit spot cannot express both conditional legs on this order"),
      else: :ok
  end

  defp validate_bybit_category(_category, _params, _conditional?, _exchange), do: :ok

  # Shaping raises caller-input `invalid_parameters` (unsupported type, missing
  # field). Convert those at this boundary so a bad route is an error, not a
  # throw past `Unified.call/5`'s own raise-vs-tuple contract.
  defp request_shapes(exchange, method, params, opts) do
    Unified.request_param_shapes(exchange, method, params, opts)
  rescue
    error in Error ->
      if error.type == :invalid_parameters, do: {:error, error}, else: reraise(error, __STACKTRACE__)
  end

  defp rename(params, pairs) do
    Enum.reduce(pairs, params, fn {source, target}, acc ->
      case Map.pop(acc, source) do
        {nil, rest} -> rest
        {value, rest} -> Map.put(rest, target, value)
      end
    end)
  end

  defp invalid(exchange, message), do: {:error, Error.invalid_parameters(exchange: exchange.id, message: message)}
end
