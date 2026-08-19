defmodule Bourse.Unified.RequestShape.Lighter do
  @moduledoc false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Symbol

  @operation_key "__bourse_lighter_transaction_operation"
  @params_key "__bourse_lighter_transaction_params"
  @auth_lifetime_seconds 300
  @default_order_expiry -1
  @order_type_limit 0
  @account_methods ~w(fetchBalance fetchPositions)
  @private_account_methods ~w(fetchDeposits fetchMyLiquidations fetchMyTrades fetchTransfers fetchWithdrawals)
  @time_in_force %{
    "GTC" => 1,
    "IOC" => 0,
    "PO" => 2,
    "good-till-time" => 1,
    "immediate-or-cancel" => 0,
    "post-only" => 2
  }

  @doc false
  @spec build(map(), String.t(), Exchange.t(), keyword()) :: map()
  def build(params, "createOrder", %Exchange{} = exchange, _opts) when is_map(params) do
    build_create_order(params, exchange)
  end

  def build(params, "cancelOrder", %Exchange{} = exchange, _opts) when is_map(params) do
    market = find_market!(exchange, Map.fetch!(params, "symbol"))

    transaction_params = %{
      market_index: integer!(market_field(market, :id), "market id"),
      order_index: integer_param!(params, ["id", "order_index"]),
      skip_nonce: false,
      nonce: integer_param!(params, ["nonce"])
    }

    put_transaction(params, "cancel_order", transaction_params)
  end

  def build(params, js_name, %Exchange{} = exchange, _opts) when is_map(params) and js_name in @account_methods do
    params
    |> Map.put_new_lazy("by", fn -> "index" end)
    |> Map.put_new_lazy("value", fn -> account_index!(exchange) end)
  end

  # deposit/history is the one private history endpoint whose provider contract
  # also marks `l1_address` required (withdraw/history takes account_index alone),
  # and the venue answers its absence with an unspecific 20001 "invalid param" —
  # so require it loudly here instead of shipping that raw error.
  def build(params, "fetchDeposits", %Exchange{} = exchange, _opts) when is_map(params) do
    if not is_binary(first_value(params, ["l1_address", "l1Address"], nil)) do
      raise Error.invalid_parameters(
              message:
                "lighter deposit/history requires l1_address (the account's L1 wallet address, " <>
                  "published on public_get_account) — pass l1_address: \"0x…\"",
              exchange: "lighter",
              raw: %{"reason" => "missing_l1_address"}
            )
    end

    params
    |> Map.put_new("account_index", account_index!(exchange))
    |> Map.put_new("auth_deadline", System.system_time(:second) + @auth_lifetime_seconds)
  end

  def build(params, js_name, %Exchange{} = exchange, _opts) when is_map(params) and js_name in @private_account_methods do
    params
    |> Map.put_new("account_index", account_index!(exchange))
    |> Map.put_new("auth_deadline", System.system_time(:second) + @auth_lifetime_seconds)
  end

  def build(params, _js_name, _exchange, _opts), do: params

  defp build_create_order(params, %Exchange{} = exchange) do
    market = find_market!(exchange, Map.fetch!(params, "symbol"))

    transaction_params = %{
      market_index: integer!(market_field(market, :id), "market id"),
      client_order_index: integer_param!(params, ["client_order_index", "clientOrderId"]),
      base_amount: scaled_integer!(Map.fetch!(params, "amount"), market_precision!(market, :amount), "amount"),
      price: scaled_integer!(Map.fetch!(params, "price"), market_precision!(market, :price), "price"),
      is_ask: side_is_ask!(Map.fetch!(params, "side")),
      order_type: order_type!(Map.fetch!(params, "type")),
      time_in_force: time_in_force!(params),
      reduce_only: boolean_param(params, ["reduceOnly", "reduce_only"], false),
      trigger_price: 0,
      order_expiry: integer_param(params, ["order_expiry", "orderExpiry"], @default_order_expiry),
      integrator_account_index: integer_param(params, ["integrator_account_index"], 0),
      integrator_taker_fee: integer_param(params, ["integrator_taker_fee"], 0),
      integrator_maker_fee: integer_param(params, ["integrator_maker_fee"], 0),
      self_trade_behavior: integer_param(params, ["self_trade_behavior"], 0),
      self_trade_equality: integer_param(params, ["self_trade_equality"], 0),
      skip_nonce: false,
      nonce: integer_param!(params, ["nonce"])
    }

    put_transaction(params, "create_order", transaction_params)
  end

  defp put_transaction(params, operation, transaction_params) do
    params
    |> Map.put(@operation_key, operation)
    |> Map.put(@params_key, transaction_params)
  end

  defp find_market!(%Exchange{markets: markets} = exchange, symbol) when is_list(markets) do
    Enum.find(markets, fn market ->
      market_symbol = market_field(market, :symbol)

      market_symbol == symbol or market_field(market, :id) == symbol or
        (is_binary(market_symbol) and Symbol.to_exchange_id(market_symbol, exchange) == symbol)
    end) || raise ArgumentError, "Lighter order build requires a loaded market for #{symbol}"
  end

  defp find_market!(_exchange, symbol),
    do: raise(ArgumentError, "Lighter order build requires loaded markets for #{symbol}")

  defp market_precision!(market, field) do
    precision = market_field(market, :precision)

    case market_field(precision, field) do
      value when not is_nil(value) -> value
      _ -> raise ArgumentError, "Lighter order build requires #{field} precision"
    end
  end

  defp scaled_integer!(value, step, name) do
    with {:ok, decimal} <- Decimal.cast(value),
         {:ok, precision} <- Decimal.cast(step),
         true <- Decimal.positive?(precision) do
      units = Decimal.div(decimal, precision)
      integer = Decimal.round(units, 0)

      if Decimal.equal?(units, integer) do
        Decimal.to_integer(integer)
      else
        raise Error.invalid_parameters(
                message: "Lighter #{name} does not align with market precision",
                exchange: "lighter",
                raw: %{"reason" => "precision_misalignment", "parameter" => name}
              )
      end
    else
      _ ->
        raise Error.invalid_parameters(
                message: "Lighter #{name} must be numeric",
                exchange: "lighter",
                raw: %{"reason" => "non_numeric", "parameter" => name}
              )
    end
  end

  defp order_type!(type) when type in ["limit", :limit], do: @order_type_limit

  defp order_type!(type) do
    raise Error.invalid_parameters(
            message: "Lighter authored trading supports limit orders only",
            exchange: "lighter",
            raw: %{"reason" => "unsupported_order_type", "value" => type}
          )
  end

  defp side_is_ask!(side) when side in ["sell", :sell], do: true
  defp side_is_ask!(side) when side in ["buy", :buy], do: false

  defp side_is_ask!(side) do
    raise Error.invalid_parameters(
            message: "Lighter order side must be buy or sell",
            exchange: "lighter",
            raw: %{"reason" => "invalid_side", "value" => side}
          )
  end

  defp time_in_force!(params) do
    value = first_value(params, ["timeInForce", "time_in_force"], "GTC")

    case Map.fetch(@time_in_force, value) do
      {:ok, time_in_force} ->
        time_in_force

      :error ->
        raise Error.invalid_parameters(
                message: "unsupported Lighter time in force #{inspect(value)}",
                exchange: "lighter",
                raw: %{"reason" => "unsupported_time_in_force", "value" => value}
              )
    end
  end

  defp boolean_param(params, names, default) do
    case first_value(params, names, default) do
      value when is_boolean(value) ->
        value

      value ->
        raise Error.invalid_parameters(
                message: "expected boolean Lighter parameter, got: #{inspect(value)}",
                exchange: "lighter",
                raw: %{"reason" => "invalid_boolean", "value" => value}
              )
    end
  end

  defp integer_param!(params, names), do: params |> first_value(names, nil) |> integer_param_value!(List.first(names))

  defp integer_param(params, names, default),
    do: params |> first_value(names, default) |> integer_param_value!(List.first(names))

  defp integer_param_value!(value, _name) when is_integer(value), do: value

  defp integer_param_value!(value, name) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> reject_invalid_integer_param!(name, value)
    end
  end

  defp integer_param_value!(value, name), do: reject_invalid_integer_param!(name, value)

  defp reject_invalid_integer_param!(name, value) do
    raise Error.invalid_parameters(
            message: "Lighter #{name} must be an integer",
            exchange: "lighter",
            raw: %{"reason" => "invalid_integer", "parameter" => name, "value" => value}
          )
  end

  defp account_index!(%Exchange{credentials: %{uid: uid}}) when not is_nil(uid), do: integer!(uid, "account index")

  defp account_index!(%Exchange{options: options}) when is_map(options) do
    options
    |> first_value([:account_index, "account_index", "accountIndex"], nil)
    |> integer!("account index")
  end

  defp integer!(value, _name) when is_integer(value), do: value

  defp integer!(value, name) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> raise ArgumentError, "Lighter #{name} must be an integer"
    end
  end

  defp integer!(_value, name), do: raise(ArgumentError, "Lighter #{name} must be an integer")

  defp first_value(params, names, default) do
    names
    |> Enum.find_value(default, fn name ->
      case Map.fetch(params, name) do
        {:ok, value} -> {:value, value}
        :error -> nil
      end
    end)
    |> case do
      {:value, value} -> value
      value -> value
    end
  end

  defp market_field(map, field) when is_map(map), do: Map.get(map, field, Map.get(map, Atom.to_string(field)))
  defp market_field(_map, _field), do: nil
end
