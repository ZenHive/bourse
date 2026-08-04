defmodule Bourse.Unified.OptionQuantity do
  @moduledoc """
  Converts option quantities between unified base exposure and venue wire units.

  Unified option order quantities and position `contracts` are expressed in
  units of the option's base currency. Each authored venue declares whether its
  native quantity field uses base units or contract counts.
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Order
  alias Bourse.Position

  @canonical_unit "base"
  @order_methods ~w(createOrder createOrderWithTakeProfitAndStopLoss createOrders editOrder editOrders)
  @quantity_fields [:amount, :filled, :remaining]

  @doc "Applies authored option quantity semantics to a parsed market."
  @spec normalize_market(Market.t(), map(), Exchange.t()) :: Market.t()
  def normalize_market(%Market{option: true} = market, raw, %Exchange{config: %{"option_quantity" => config}})
      when is_map(raw) and is_map(config) do
    native_step = get_in(market.precision || %{}, ["amount"])
    contract_size = contract_size!(config["contract_size"], raw, market)

    market
    |> Map.put(:quantity_unit, @canonical_unit)
    |> Map.put(:native_quantity_unit, config["wire_unit"])
    |> Map.put(:native_quantity_field, config["wire_field"])
    |> Map.put(:native_amount_step, native_step)
    |> Map.put(:contract_size, contract_size || market.contract_size)
    |> Map.put(:precision, scale_amount_precision(market.precision, config["wire_unit"], contract_size))
    |> Map.put(:limits, scale_amount_limits(market.limits, config["wire_unit"], contract_size))
    |> backfill_option_identity()
  end

  def normalize_market(%Market{} = market, _raw, _exchange), do: market

  @doc "Converts a canonical base-currency option amount to the venue wire unit."
  @spec to_native(Market.t(), number() | String.t()) :: {:ok, number()} | {:error, Error.t()}
  def to_native(%Market{} = market, amount) do
    convert(market, amount, :to_native)
  end

  @doc "Converts a venue option quantity to canonical base-currency exposure."
  @spec from_native(Market.t(), number() | String.t()) :: {:ok, number()} | {:error, Error.t()}
  def from_native(%Market{} = market, amount) do
    convert(market, amount, :from_native)
  end

  @doc "Converts canonical base exposure to an option contract count."
  @spec to_contracts(Market.t(), number() | String.t()) :: {:ok, number()} | {:error, Error.t()}
  def to_contracts(%Market{} = market, amount) do
    convert_as_contracts(market, amount, :to_native)
  end

  @doc "Converts an option contract count to canonical base exposure."
  @spec from_contracts(Market.t(), number() | String.t()) :: {:ok, number()} | {:error, Error.t()}
  def from_contracts(%Market{} = market, contracts) do
    convert_as_contracts(market, contracts, :from_native)
  end

  @doc "Converts unified option order amounts before venue request shaping."
  @spec to_native_request!(map(), Exchange.t(), String.t()) :: map()
  def to_native_request!(params, %Exchange{} = exchange, js_name) when is_map(params) and js_name in @order_methods do
    case params["orders"] do
      orders when is_list(orders) ->
        shared = Map.delete(params, "orders")
        converted = Enum.map(orders, &convert_request_row!(&1, shared, exchange))
        Map.put(params, "orders", converted)

      _ ->
        convert_request_row!(params, %{}, exchange)
    end
  end

  def to_native_request!(params, _exchange, _js_name), do: params

  @doc "Converts parsed option orders and positions from venue wire units to base exposure."
  @spec from_native_result!(term(), Exchange.t()) :: term()
  def from_native_result!(orders, %Exchange{} = exchange) when is_list(orders) do
    Enum.map(orders, &from_native_result!(&1, exchange))
  end

  def from_native_result!(%Order{} = order, %Exchange{} = exchange) do
    case find_market(exchange, order.symbol, %{}) do
      %Market{option: true} = market ->
        Enum.reduce(@quantity_fields, order, &convert_order_field!(&2, &1, market))

      _ ->
        order
    end
  end

  def from_native_result!(%Position{} = position, %Exchange{} = exchange) do
    case find_market(exchange, position.symbol, %{}) do
      %Market{option: true} = market ->
        convert_position_contracts!(position, market, position_wire_unit(exchange, market))

      _ ->
        position
    end
  end

  def from_native_result!(result, _exchange), do: result

  defp convert_request_row!(row, shared, exchange) when is_map(row) do
    params = Map.merge(shared, row)

    case {Map.get(row, "amount"), find_market(exchange, order_symbol(params), params), params["category"]} do
      {nil, _market, _category} ->
        row

      {amount, %Market{option: true} = market, _category} ->
        Map.put(row, "amount", convert_or_raise!(market, amount, :to_native))

      {_amount, nil, "option"} ->
        raise quantity_error(nil, params["amount"], "market_not_found")

      {_amount, _market, _category} ->
        row
    end
  end

  defp convert_order_field!(%Order{} = order, field, market) do
    case Map.fetch!(order, field) do
      nil -> order
      amount -> Map.put(order, field, convert_or_raise!(market, amount, :from_native))
    end
  end

  defp convert_position_contracts!(position, _market, "base"), do: position
  defp convert_position_contracts!(%Position{contracts: nil} = position, _market, "contracts"), do: position

  defp convert_position_contracts!(%Position{contracts: contracts} = position, market, "contracts") do
    %{position | contracts: convert_or_raise!(market, contracts, :from_native)}
  end

  defp convert_position_contracts!(position, _market, _unit), do: position

  defp position_wire_unit(%Exchange{config: %{"option_quantity" => %{"wire_unit" => unit}}}, _market), do: unit

  defp position_wire_unit(_exchange, %Market{native_quantity_unit: unit}), do: unit

  defp convert_or_raise!(market, amount, direction) do
    case convert(market, amount, direction) do
      {:ok, converted} -> converted
      {:error, error} -> raise error
    end
  end

  defp convert(%Market{} = market, amount, direction) do
    with :ok <- validate_semantics(market),
         {:ok, decimal} <- quantity_decimal(amount, direction),
         {:ok, converted} <- convert_decimal(market, decimal, direction),
         :ok <- validate_step(market, converted, direction) do
      {:ok, decimal_to_number(converted)}
    else
      {:error, reason} -> {:error, quantity_error(market, amount, reason)}
    end
  end

  defp convert_as_contracts(%Market{} = market, amount, direction) do
    with :ok <- validate_semantics(market),
         {:ok, contract_market} <- contract_market(market) do
      convert(contract_market, amount, direction)
    else
      {:error, reason} -> {:error, quantity_error(market, amount, reason)}
    end
  end

  defp contract_market(%Market{native_quantity_unit: "contracts"} = market), do: {:ok, market}

  defp contract_market(%Market{native_quantity_unit: "base"} = market) do
    with {:ok, contract_size} <- positive_decimal(market.contract_size),
         {:ok, amount_step} <- positive_decimal(market.native_amount_step) do
      contract_step =
        amount_step
        |> Decimal.div(contract_size)
        |> decimal_to_number()

      {:ok, %{market | native_quantity_unit: "contracts", native_amount_step: contract_step}}
    else
      _ -> {:error, "missing_contract_size"}
    end
  end

  defp validate_semantics(%Market{quantity_unit: @canonical_unit, native_quantity_unit: unit, native_amount_step: step})
       when unit in ["base", "contracts"] and not is_nil(step), do: :ok

  defp validate_semantics(_market), do: {:error, "missing_quantity_semantics"}

  defp positive_decimal(value) do
    with {:ok, decimal} <- decimal(value),
         true <- Decimal.positive?(decimal) do
      {:ok, decimal}
    else
      _ -> {:error, "invalid_quantity"}
    end
  end

  defp quantity_decimal(value, :to_native), do: positive_decimal(value)

  defp quantity_decimal(value, :from_native) do
    with {:ok, decimal} <- decimal(value),
         comparison when comparison in [:eq, :gt] <- Decimal.compare(decimal, 0) do
      {:ok, decimal}
    else
      _ -> {:error, "invalid_quantity"}
    end
  end

  defp convert_decimal(%Market{native_quantity_unit: "base"}, amount, _direction), do: {:ok, amount}

  defp convert_decimal(%Market{native_quantity_unit: "contracts"} = market, amount, direction) do
    case positive_decimal(market.contract_size) do
      {:ok, contract_size} ->
        case direction do
          :to_native -> {:ok, Decimal.div(amount, contract_size)}
          :from_native -> {:ok, Decimal.mult(amount, contract_size)}
        end

      _ ->
        {:error, "missing_contract_size"}
    end
  end

  defp validate_step(market, converted, :to_native) do
    validate_multiple(converted, market.native_amount_step)
  end

  defp validate_step(market, converted, :from_native) do
    validate_multiple(converted, get_in(market.precision || %{}, ["amount"]))
  end

  defp validate_multiple(value, step) do
    with {:ok, step} <- positive_decimal(step),
         quotient = Decimal.div(value, step),
         true <- Decimal.equal?(quotient, Decimal.round(quotient, 0)) do
      :ok
    else
      _ -> {:error, "quantization_error"}
    end
  end

  defp contract_size!(nil, _raw, _market), do: nil

  defp contract_size!(%{"kind" => "field", "field" => field}, raw, market) do
    raw
    |> Map.get(field)
    |> require_contract_size!(market, [field])
  end

  defp contract_size!(%{"kind" => "product", "fields" => [left, right]}, raw, market) do
    with {:ok, left_value} <- positive_decimal(raw[left]),
         {:ok, right_value} <- positive_decimal(raw[right]) do
      left_value
      |> Decimal.mult(right_value)
      |> decimal_to_number()
    else
      _ -> raise_contract_size!(market, [left, right])
    end
  end

  defp contract_size!(_recipe, _raw, market), do: raise_contract_size!(market, [])

  defp require_contract_size!(value, market, fields) do
    case positive_decimal(value) do
      {:ok, decimal} -> decimal_to_number(decimal)
      _ -> raise_contract_size!(market, fields)
    end
  end

  defp raise_contract_size!(market, fields) do
    raise ArgumentError,
          "missing option contract multiplier for #{market.symbol || market.id}: #{Enum.join(fields, " * ")}"
  end

  defp scale_amount_precision(precision, "contracts", contract_size) do
    update_amount_value(precision, &multiply(&1, contract_size))
  end

  defp scale_amount_precision(precision, _wire_unit, _contract_size), do: precision

  defp scale_amount_limits(limits, "contracts", contract_size) when is_map(limits) do
    Map.update(limits, "amount", nil, fn
      amount_limits when is_map(amount_limits) ->
        amount_limits
        |> Map.update("min", nil, &multiply(&1, contract_size))
        |> Map.update("max", nil, &multiply(&1, contract_size))

      other ->
        other
    end)
  end

  defp scale_amount_limits(limits, _wire_unit, _contract_size), do: limits

  defp update_amount_value(map, function) when is_map(map) do
    Map.update(map, "amount", nil, fn
      nil -> nil
      value -> function.(value)
    end)
  end

  defp update_amount_value(map, _function), do: map

  defp multiply(nil, _right), do: nil

  defp multiply(left, right) do
    with {:ok, left} <- decimal(left),
         {:ok, right} <- decimal(right) do
      left
      |> Decimal.mult(right)
      |> decimal_to_number()
    else
      _ -> nil
    end
  end

  defp backfill_option_identity(%Market{symbol: symbol} = market) when is_binary(symbol) do
    case Bourse.Symbol.parse_extended(symbol) do
      {:ok, parsed} ->
        %{
          market
          | strike: market.strike || Bourse.Safe.number(parsed.strike),
            option_type: normalize_option_type(market.option_type || parsed.option_type)
        }

      _ ->
        market
    end
  end

  defp backfill_option_identity(market), do: market

  defp normalize_option_type("C"), do: "call"
  defp normalize_option_type("P"), do: "put"
  defp normalize_option_type("Call"), do: "call"
  defp normalize_option_type("Put"), do: "put"
  defp normalize_option_type(type), do: type

  defp decimal(%Decimal{} = value), do: {:ok, value}
  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decimal(_value), do: :error

  defp decimal_to_number(decimal) do
    normalized = Decimal.normalize(decimal)
    string = Decimal.to_string(normalized, :normal)

    case Integer.parse(string) do
      {integer, ""} -> integer
      _ -> Decimal.to_float(normalized)
    end
  end

  defp find_market(%Exchange{markets: markets}, symbol, params) when is_list(markets) and is_binary(symbol) do
    matches =
      Enum.filter(markets, fn market ->
        market_field(market, :id) == symbol or market_field(market, :symbol) == symbol
      end)

    case params["category"] do
      "option" -> Enum.find(matches, &(market_field(&1, :option) == true))
      _ -> List.first(matches)
    end
  end

  defp find_market(_exchange, _symbol, _params), do: nil

  defp market_field(map, field) when is_map(map), do: Map.get(map, field, Map.get(map, Atom.to_string(field)))
  defp market_field(_value, _field), do: nil

  defp order_symbol(params), do: params["symbol"] || params["instId"] || params["instrument_name"]

  defp quantity_error(market, amount, reason) do
    symbol = if market, do: market.symbol || market.id

    Error.invalid_order(
      message:
        "Option quantity #{inspect(amount)} is not representable for #{symbol || "the requested market"}: #{reason}",
      raw: %{
        "reason" => reason,
        "quantity" => amount,
        "quantity_unit" => @canonical_unit,
        "symbol" => symbol
      }
    )
  end
end
