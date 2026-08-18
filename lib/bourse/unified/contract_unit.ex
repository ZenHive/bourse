defmodule Bourse.Unified.ContractUnit do
  @moduledoc """
  Applies an authored venue-level contract unit to parsed linear markets.

  A provider-published `contract_size` always wins. A missing unit becomes the
  authored constant or field only when the venue declared that recipe; unknown
  or missing multiplier semantics fail loudly instead of defaulting to one.
  """

  alias Bourse.Exchange
  alias Bourse.Market

  @doc "Applies the authored linear contract unit to a parsed market."
  @spec normalize_market(Market.t(), map(), Exchange.t()) :: Market.t()
  def normalize_market(%Market{option: true} = market, _raw, _exchange), do: market

  def normalize_market(%Market{linear: true, contract: true} = market, raw, %Exchange{
        config: %{"contract_unit" => %{"quantity_unit" => unit, "linear" => recipe}}
      })
      when is_map(raw) and is_binary(unit) do
    contract_size = resolve_contract_size!(market.contract_size, recipe, raw, market)

    market
    |> Map.put(:contract_size, contract_size)
    |> Map.put(:quantity_unit, unit)
  end

  def normalize_market(%Market{} = market, _raw, _exchange), do: market

  defp resolve_contract_size!(existing, recipe, raw, market) do
    case positive_number(existing) do
      {:ok, value} -> value
      :error -> apply_recipe!(recipe, raw, market)
    end
  end

  defp apply_recipe!(%{"kind" => "constant", "value" => value}, _raw, market) do
    require_contract_size!(value, market, ["constant"])
  end

  defp apply_recipe!(%{"kind" => "field", "field" => field}, raw, market) when is_map(raw) do
    raw
    |> Map.get(field)
    |> require_contract_size!(market, [field])
  end

  defp apply_recipe!(_recipe, _raw, market), do: raise_contract_size!(market, [])

  defp require_contract_size!(value, market, fields) do
    case positive_number(value) do
      {:ok, number} -> number
      :error -> raise_contract_size!(market, fields)
    end
  end

  defp raise_contract_size!(market, fields) do
    raise ArgumentError,
          "missing linear contract unit for #{market.symbol || market.id}: #{Enum.join(fields, " * ")}"
  end

  defp positive_number(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_number(value) when is_float(value) and value > 0.0, do: {:ok, value}

  defp positive_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number > 0.0 ->
        if number == :math.floor(number), do: {:ok, trunc(number)}, else: {:ok, number}

      _ ->
        :error
    end
  end

  defp positive_number(_value), do: :error
end
