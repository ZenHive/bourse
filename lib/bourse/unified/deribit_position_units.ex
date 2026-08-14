defmodule Bourse.Unified.DeribitPositionUnits do
  @moduledoc """
  Reconciles Deribit future position contracts with loaded market metadata.

  Deribit reports future `size` in quote currency. The market's `contract_size`
  converts that value into the venue contract count.
  """

  alias Bourse.Exchange
  alias Bourse.Position
  alias Bourse.Safe

  @type parse_result :: {:ok, term()} | {:error, term()}

  @doc "Populates Deribit future contract fields from loaded market metadata."
  @spec reconcile(parse_result(), Exchange.t()) :: parse_result()
  def reconcile({:ok, positions}, %Exchange{id: "deribit"} = exchange) when is_list(positions) do
    contract_sizes = contract_sizes(exchange.markets)
    {:ok, Enum.map(positions, &reconcile_position(&1, contract_sizes))}
  end

  def reconcile({:ok, %Position{} = position}, %Exchange{id: "deribit"} = exchange) do
    {:ok, reconcile_position(position, contract_sizes(exchange.markets))}
  end

  def reconcile(result, %Exchange{}), do: result

  defp contract_sizes(markets) when is_list(markets) do
    Enum.reduce(markets, %{}, fn market, contract_sizes ->
      id = Map.get(market, :id) || Map.get(market, "id")

      contract_size =
        market
        |> then(&(Map.get(&1, :contract_size) || Map.get(&1, "contractSize") || Map.get(&1, "contract_size")))
        |> Safe.number()

      if is_binary(id) and is_number(contract_size) and contract_size > 0 do
        Map.put(contract_sizes, id, contract_size)
      else
        contract_sizes
      end
    end)
  end

  defp contract_sizes(_markets), do: %{}

  defp reconcile_position(
         %Position{info: %{"instrument_name" => instrument_name, "kind" => "future"}, notional: notional} = position,
         contract_sizes
       )
       when is_number(notional) do
    case Map.get(contract_sizes, instrument_name) do
      contract_size when is_number(contract_size) and contract_size > 0 ->
        %{position | contract_size: contract_size, contracts: notional / contract_size}

      _missing_contract_size ->
        position
    end
  end

  defp reconcile_position(position, _contract_sizes), do: position
end
