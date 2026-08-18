defmodule Bourse.Unified.DeribitPositionUnits do
  @moduledoc """
  Reconciles Deribit future position contracts with loaded market metadata.

  Deribit future positions report quote `size` and base `size_currency`.
  Inverse market `contract_size` is quote-denominated, while linear market
  `contract_size` is base-denominated, so the divisor follows settlement.
  """

  alias Bourse.Exchange
  alias Bourse.Position
  alias Bourse.Safe

  @type parse_result :: {:ok, term()} | {:error, term()}

  @doc "Populates Deribit future contract fields from loaded market metadata."
  @spec reconcile(parse_result(), Exchange.t()) :: parse_result()
  def reconcile({:ok, positions}, %Exchange{id: "deribit"} = exchange) when is_list(positions) do
    market_units = market_units(exchange.markets)
    {:ok, Enum.map(positions, &reconcile_position(&1, market_units))}
  end

  def reconcile({:ok, %Position{} = position}, %Exchange{id: "deribit"} = exchange) do
    {:ok, reconcile_position(position, market_units(exchange.markets))}
  end

  def reconcile(result, %Exchange{}), do: result

  defp market_units(markets) when is_list(markets) do
    Enum.reduce(markets, %{}, fn market, market_units ->
      id = Map.get(market, :id) || Map.get(market, "id")

      contract_size =
        market
        |> then(&(Map.get(&1, :contract_size) || Map.get(&1, "contractSize") || Map.get(&1, "contract_size")))
        |> Safe.number()

      if is_binary(id) and is_number(contract_size) and contract_size > 0 do
        inverse? = Map.get(market, :inverse) == true or Map.get(market, "inverse") == true
        Map.put(market_units, id, %{contract_size: contract_size, inverse?: inverse?})
      else
        market_units
      end
    end)
  end

  defp market_units(_markets), do: %{}

  defp reconcile_position(
         %Position{info: %{"instrument_name" => instrument_name, "kind" => "future"} = info} = position,
         market_units
       ) do
    case Map.get(market_units, instrument_name) do
      %{contract_size: contract_size, inverse?: market_inverse?} ->
        inverse? = Map.get(info, "_bourse_inverse", market_inverse?)

        case contract_quantity(position, inverse?) do
          quantity when is_number(quantity) ->
            %{position | contract_size: contract_size, contracts: quantity / contract_size}

          _missing_quantity ->
            position
        end

      _missing_market_units ->
        position
    end
  end

  defp reconcile_position(position, _market_units), do: position

  defp contract_quantity(%Position{notional: notional}, true), do: notional
  defp contract_quantity(%Position{base_quantity: base_quantity}, false), do: base_quantity
end
