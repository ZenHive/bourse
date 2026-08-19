defmodule Bourse.Unified.RequestShape.Binance do
  @moduledoc false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Symbol

  @all_create_order_fields ~w(
    symbol side type amount price timeInForce clientOrderId newClientOrderId newOrderRespType
    reduceOnly closePosition positionSide workingType priceProtect activationPrice
    goodTillDate priceMatch selfTradePreventionMode stopPrice callbackRate
  )
  @all_order_types ~w(LIMIT MARKET STOP TAKE_PROFIT STOP_MARKET TAKE_PROFIT_MARKET TRAILING_STOP_MARKET)
  @priced_order_types ~w(LIMIT STOP TAKE_PROFIT)
  @create_order_fields_by_type %{
    "LIMIT" =>
      ~w(symbol side type amount price timeInForce clientOrderId newClientOrderId newOrderRespType reduceOnly positionSide priceMatch selfTradePreventionMode goodTillDate),
    "MARKET" =>
      ~w(symbol side type amount clientOrderId newClientOrderId newOrderRespType reduceOnly positionSide selfTradePreventionMode),
    "STOP" =>
      ~w(symbol side type amount price stopPrice timeInForce clientOrderId newClientOrderId newOrderRespType reduceOnly positionSide workingType priceProtect priceMatch selfTradePreventionMode goodTillDate),
    "TAKE_PROFIT" =>
      ~w(symbol side type amount price stopPrice timeInForce clientOrderId newClientOrderId newOrderRespType reduceOnly positionSide workingType priceProtect priceMatch selfTradePreventionMode goodTillDate),
    "STOP_MARKET" =>
      ~w(symbol side type amount stopPrice clientOrderId newClientOrderId newOrderRespType reduceOnly closePosition positionSide workingType priceProtect selfTradePreventionMode),
    "TAKE_PROFIT_MARKET" =>
      ~w(symbol side type amount stopPrice clientOrderId newClientOrderId newOrderRespType reduceOnly closePosition positionSide workingType priceProtect selfTradePreventionMode),
    "TRAILING_STOP_MARKET" =>
      ~w(symbol side type amount callbackRate activationPrice clientOrderId newClientOrderId newOrderRespType reduceOnly positionSide workingType selfTradePreventionMode)
  }

  @doc false
  @spec build(map(), String.t(), Exchange.t()) :: map()
  def build(%{"orders" => orders} = params, "createOrders", exchange) when is_list(orders) do
    params
    |> Map.delete("orders")
    |> Map.delete("symbol")
    |> Map.put("batchOrders", "[" <> Enum.map_join(orders, ",", &encode_create_order(&1, exchange)) <> "]")
  end

  def build(%{"orders" => orders} = params, "editOrders", exchange) when is_list(orders) do
    params
    |> Map.delete("orders")
    |> Map.delete("symbol")
    |> Map.put("batchOrders", "[" <> Enum.map_join(orders, ",", &encode_edit_order(&1, exchange)) <> "]")
  end

  def build(%{"symbols" => [symbol]} = params, "fetchAllGreeks", exchange) when is_binary(symbol) do
    params
    |> Map.delete("symbols")
    |> Map.put("symbol", Symbol.to_exchange_id(symbol, exchange))
  end

  def build(params, "fetchAllGreeks", _exchange), do: Map.delete(params, "symbols")

  def build(params, _js_name, _exchange), do: params

  defp encode_create_order(order, exchange) do
    type = order |> Map.fetch!("type") |> String.upcase()
    validate_create_order_fields!(order, type)

    encode_object([
      {"symbol", native_symbol(order, exchange)},
      {"side", order |> Map.fetch!("side") |> String.upcase()},
      {"newClientOrderId", client_order_id(order)},
      {"newOrderRespType", Map.get(order, "newOrderRespType", "RESULT")},
      {"type", type} | create_order_fields(order, type) ++ optional_create_order_fields(order, type)
    ])
  end

  defp create_order_fields(order, "LIMIT") do
    [
      {"quantity", number_string(Map.fetch!(order, "amount"))},
      optional_price(order),
      {"timeInForce", order |> Map.get("timeInForce", "GTC") |> String.upcase()}
    ]
  end

  defp create_order_fields(order, "MARKET"), do: [{"quantity", number_string(Map.fetch!(order, "amount"))}]

  defp create_order_fields(order, type) when type in ["STOP", "TAKE_PROFIT"] do
    [
      {"quantity", number_string(Map.fetch!(order, "amount"))},
      optional_price(order),
      {"stopPrice", number_string(Map.fetch!(order, "stopPrice"))}
    ]
  end

  defp create_order_fields(order, type) when type in ["STOP_MARKET", "TAKE_PROFIT_MARKET"] do
    optional_quantity(order) ++ [{"stopPrice", number_string(Map.fetch!(order, "stopPrice"))}]
  end

  defp create_order_fields(order, "TRAILING_STOP_MARKET") do
    optional_quantity(order) ++ [{"callbackRate", number_string(Map.fetch!(order, "callbackRate"))}]
  end

  # Binance omits `quantity` from these types' mandatory column only because
  # `closePosition: true` substitutes for it; a sized order still requires it
  # (live testnet: -1102 "Mandatory parameter 'quantity' was not sent").
  defp optional_quantity(order) do
    case Map.get(order, "amount") do
      nil -> []
      amount -> [{"quantity", number_string(amount)}]
    end
  end

  defp optional_price(order) do
    case Map.fetch(order, "price") do
      {:ok, price} -> {"price", number_string(price)}
      :error -> nil
    end
  end

  defp optional_create_order_fields(order, type) do
    type
    |> optional_fields_for_type()
    |> Enum.flat_map(fn key -> optional_field(order, key) end)
  end

  defp optional_fields_for_type("LIMIT"), do: ~w(reduceOnly positionSide priceMatch selfTradePreventionMode goodTillDate)
  defp optional_fields_for_type("MARKET"), do: ~w(reduceOnly positionSide selfTradePreventionMode)

  defp optional_fields_for_type(type) when type in ["STOP", "TAKE_PROFIT"] do
    ~w(reduceOnly positionSide workingType priceProtect priceMatch selfTradePreventionMode goodTillDate timeInForce)
  end

  defp optional_fields_for_type(type) when type in ["STOP_MARKET", "TAKE_PROFIT_MARKET"] do
    ~w(reduceOnly closePosition positionSide workingType priceProtect selfTradePreventionMode)
  end

  defp optional_fields_for_type("TRAILING_STOP_MARKET") do
    ~w(reduceOnly positionSide workingType activationPrice selfTradePreventionMode)
  end

  defp optional_field(order, "timeInForce") do
    case Map.fetch(order, "timeInForce") do
      {:ok, value} -> [{"timeInForce", String.upcase(value)}]
      :error -> []
    end
  end

  defp optional_field(order, key) when key in ["reduceOnly", "closePosition", "priceProtect"] do
    case Map.fetch(order, key) do
      {:ok, value} -> [{key, boolean_string(value)}]
      :error -> []
    end
  end

  defp optional_field(order, key) do
    case Map.fetch(order, key) do
      {:ok, value} -> [{key, value}]
      :error -> []
    end
  end

  defp validate_create_order_fields!(order, type) do
    if type not in @all_order_types do
      raise Error.invalid_parameters(
              message: "unsupported Binance batch order type #{inspect(type)}",
              raw: %{"reason" => "unsupported_batch_order_type", "type" => type}
            )
    end

    allowed_fields = Map.fetch!(@create_order_fields_by_type, type)

    Enum.each(order, fn {key, _value} ->
      validate_create_order_field!(key, type, allowed_fields)
    end)

    validate_price!(order, type)

    if Map.has_key?(order, "goodTillDate") and String.upcase(Map.get(order, "timeInForce", "GTC")) != "GTD" do
      raise Error.invalid_parameters(
              message: ~s(Binance batch order field "goodTillDate" requires "timeInForce" "GTD"),
              raw: %{"reason" => "good_till_date_requires_gtd"}
            )
    end

    if truthy?(Map.get(order, "closePosition")) do
      validate_close_position_exclusions!(order)
    end
  end

  # `priceMatch` substitutes for an explicit `price` and the two are mutually
  # exclusive, so a priced element carries exactly one of them. Omitting both
  # is a caller error, not a field to drop: the venue would answer -1102 for a
  # request we can reject client-side with the missing key named.
  defp validate_price!(order, type) when type in @priced_order_types do
    case {Map.has_key?(order, "price"), Map.has_key?(order, "priceMatch")} do
      {true, true} ->
        raise Error.invalid_parameters(
                message: ~s(Binance batch order field "priceMatch" cannot be used with "price"),
                raw: %{"reason" => "price_and_price_match_exclusive"}
              )

      {false, false} ->
        raise Error.invalid_parameters(
                message: ~s(Binance batch order type #{type} requires "price" or "priceMatch"),
                raw: %{"reason" => "missing_price", "type" => type}
              )

      _ ->
        :ok
    end
  end

  defp validate_price!(_order, _type), do: :ok

  # Binance's close-all element sizes itself from the open position, so both a
  # caller-supplied size and `reduceOnly` conflict with it.
  defp validate_close_position_exclusions!(order) do
    if Map.has_key?(order, "reduceOnly") do
      raise Error.invalid_parameters(
              message: ~s(Binance batch order field "reduceOnly" cannot be used with "closePosition"),
              raw: %{"reason" => "reduce_only_with_close_position"}
            )
    end

    if Map.has_key?(order, "amount") do
      raise Error.invalid_parameters(
              message: ~s(Binance batch order field "amount" cannot be used with "closePosition"),
              raw: %{"reason" => "amount_with_close_position"}
            )
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp validate_create_order_field!(key, type, allowed_fields) do
    if key in allowed_fields do
      :ok
    else
      reject_create_order_field!(key, type)
    end
  end

  defp reject_create_order_field!(key, type) when key in @all_create_order_fields do
    raise Error.invalid_parameters(
            message: "Binance batch order field #{inspect(key)} is inapplicable to #{type}",
            raw: %{"reason" => "inapplicable_batch_order_field", "field" => key, "type" => type}
          )
  end

  defp reject_create_order_field!(key, type) do
    raise Error.invalid_parameters(
            message: "unsupported Binance batch order field #{inspect(key)} for #{type}",
            raw: %{"reason" => "unsupported_batch_order_field", "field" => key, "type" => type}
          )
  end

  defp encode_edit_order(order, exchange) do
    encode_object([
      {"orderId", to_string(Map.fetch!(order, "id"))},
      {"symbol", native_symbol(order, exchange)},
      {"side", order |> Map.fetch!("side") |> String.upcase()},
      {"quantity", number_string(Map.fetch!(order, "amount"))},
      {"price", number_string(Map.fetch!(order, "price"))}
    ])
  end

  defp encode_object(pairs) do
    pairs = Enum.reject(pairs, &is_nil/1)

    "{" <> Enum.map_join(pairs, ",", fn {key, value} -> Jason.encode!(key) <> ":" <> Jason.encode!(value) end) <> "}"
  end

  defp native_symbol(%{"symbol" => symbol}, exchange), do: Symbol.to_exchange_id(symbol, exchange)
  defp client_order_id(order), do: Map.get(order, "newClientOrderId", Map.get(order, "clientOrderId", broker_id(order)))
  defp broker_id(_order), do: "x-xcKtGhcu" <> (11 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  defp number_string(value) when is_integer(value), do: Integer.to_string(value)

  defp number_string(value) when is_float(value) do
    value |> Decimal.from_float() |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp number_string(value) when is_binary(value), do: value
  defp boolean_string(value) when is_boolean(value), do: to_string(value)
  defp boolean_string(value) when is_binary(value), do: value
end
