defmodule Bourse.Test.RestReadContractOwnedState do
  @moduledoc """
  Creates and tears down the sandbox state a REST-read resource argument needs.

  `fetchOpenOrders` / `fetchOrders` get a far-from-market resting limit.
  `fetchCanceledOrders` gets the same order cancelled before the read.
  History windows that the venue itself expires are not manufactured here.
  """

  alias Bourse.Order
  alias Bourse.Test.Journeys.Case, as: Journey

  @resting_ratio 0.9
  @resting_sources ["fetchOpenOrders", "fetchOrders"]
  @canceled_sources ["fetchCanceledOrders"]

  @doc "Whether the scenario can manufacture a sandbox row for this resource source."
  @spec ownable_source?(String.t()) :: boolean()
  def ownable_source?(source) when is_binary(source) do
    source in @resting_sources or source in @canceled_sources
  end

  @doc "Creates the live row a resource argument needs, or `:unownable`."
  @spec ensure(map(), map(), map()) :: {:ok, term()} | :unownable | {:error, term()}
  def ensure(argument, contract_case, context) do
    source = argument["source_method"]

    cond do
      source in @resting_sources -> own_resting_order(argument, contract_case, context)
      source in @canceled_sources -> own_canceled_order(argument, contract_case, context)
      true -> :unownable
    end
  end

  defp own_resting_order(argument, contract_case, context) do
    # `source_kind: "algo"` names a venue's algo book, whose ids only the
    # `algoOrder` read branches accept. A plain GTC limit would yield an
    # `orderId` that endpoint answers `order_not_found` for, so the algo case
    # needs a conditional order of its own. The kind is declared rather than
    # inferred from `source_endpoint_index`, which other venues use to select an
    # ordinary book.
    placement =
      if argument["source_kind"] == "algo",
        do: &place_algo_order/2,
        else: &place_resting_order/2

    place_and_register_order(argument, contract_case, context, placement)
  end

  defp place_and_register_order(argument, contract_case, context, placement) do
    with {:ok, placed} <- placement.(contract_case, context) do
      register_cleanup!(context.exchange, placed)
      field = field_from(placed, argument["field"])

      if is_nil(field), do: {:error, {:missing_field, argument["field"], placed}}, else: {:ok, field}
    end
  end

  defp own_canceled_order(argument, contract_case, context) do
    # Register cleanup before cancelling: a cancel that raises would otherwise
    # leave the order resting on the sandbox forever. A second cancel of an
    # already-cancelled order answers `order_not_found`, which `release_order!`
    # treats as success.
    with {:ok, placed} <- place_resting_order(contract_case, context),
         :ok <- register_cleanup!(context.exchange, placed),
         :ok <- cancel_now(context.exchange, placed) do
      field = field_from(placed, argument["field"])

      if is_nil(field), do: {:error, {:missing_field, argument["field"], placed}}, else: {:ok, field}
    end
  end

  defp place_resting_order(contract_case, context) do
    symbol = contract_case["resolved_symbol"] || market_symbol(context, contract_case)
    market = Enum.find(context.markets || [], &(&1.symbol == symbol))
    amount = min_amount(market)

    case resting_price(context.exchange, symbol, market) do
      price when is_number(price) and price > 0 ->
        sized = sized_amount(amount, price, market)
        Bourse.create_order(context.exchange, symbol, "limit", "buy", sized, price: price, timeInForce: "GTC")

      _missing ->
        {:error, :no_resting_price}
    end
  end

  # A far-below-market conditional sell rests on the venue's algo book
  # (`POST /fapi/v1/algoOrder`, live-proven shape: market + trigger_price +
  # GTC answers `%Order{status: "open", type: "stop_market"}`). Its id is an
  # `algoId`, which is what the `algoOrder` read branches require.
  defp place_algo_order(contract_case, context) do
    symbol = contract_case["resolved_symbol"] || market_symbol(context, contract_case)
    market = Enum.find(context.markets || [], &(&1.symbol == symbol))

    case resting_price(context.exchange, symbol, market) do
      trigger when is_number(trigger) and trigger > 0 ->
        Bourse.create_order(
          context.exchange,
          symbol,
          "market",
          "sell",
          sized_amount(min_amount(market), trigger, market),
          time_in_force: "GTC",
          trigger_price: trigger
        )

      _missing ->
        {:error, :no_resting_price}
    end
  end

  defp resting_price(exchange, symbol, market) do
    case Bourse.fetch_ticker(exchange, symbol) do
      {:ok, ticker} ->
        bid = ticker.bid || ticker.last
        if is_number(bid) and bid > 0, do: round_to(bid * @resting_ratio, market, "price")

      _other ->
        nil
    end
  end

  defp cancel_now(exchange, placed) do
    Journey.release_order!(exchange, placed.id, placed.symbol)
  end

  defp register_cleanup!(exchange, placed) do
    id = placed.id
    symbol = placed.symbol

    ExUnit.Callbacks.on_exit(fn ->
      Journey.release_order!(exchange, id, symbol)
    end)

    :ok
  end

  defp min_amount(%{limits: %{"amount" => %{"min" => min}}}) when is_number(min) and min > 0, do: min
  defp min_amount(_market), do: 0.001

  # USD-M demo rejects notionals below 50; size the resting buy above that floor.
  @min_notional 100.0

  defp sized_amount(min_amount, price, market) when price > 0 do
    needed = @min_notional / price
    raw = if needed > min_amount, do: needed, else: min_amount
    round_to(raw, market, "amount")
  end

  defp round_to(value, %{precision: precision}, "amount") when is_map(precision) do
    ceil_precision(value, precision["amount"])
  end

  defp round_to(value, %{precision: precision}, "price") when is_map(precision) do
    floor_precision(value, precision["price"])
  end

  defp round_to(value, _market, _key), do: Float.round(value, 8)

  defp ceil_precision(value, precision) when is_integer(precision) and precision >= 0 do
    factor = :math.pow(10, precision)
    Float.ceil(value * factor - 1.0e-9) / factor
  end

  defp ceil_precision(value, precision) when is_float(precision) and precision > 0 and precision < 1 do
    Float.round(Float.ceil(value / precision - 1.0e-9) * precision, 8)
  end

  defp ceil_precision(value, _precision), do: Float.round(value, 8)

  defp floor_precision(value, precision) when is_integer(precision) and precision >= 0 do
    factor = :math.pow(10, precision)
    Float.floor(value * factor + 1.0e-9) / factor
  end

  defp floor_precision(value, precision) when is_float(precision) and precision > 0 and precision < 1 do
    Float.round(Float.floor(value / precision + 1.0e-9) * precision, 8)
  end

  defp floor_precision(value, _precision), do: Float.round(value, 8)

  defp field_from(%Order{} = order, "id"), do: order.id
  defp field_from(order, field), do: Map.get(order, String.to_existing_atom(field))

  defp market_symbol(context, contract_case) do
    kind = contract_case["market_kind"]
    context.venue_contract["symbols"][kind] || context.venue_contract["symbols"]["spot"]
  end
end
