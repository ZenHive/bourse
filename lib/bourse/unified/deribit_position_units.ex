defmodule Bourse.Unified.DeribitPositionUnits do
  @moduledoc """
  Finalizes the machine-readable unit contract on unified positions.

  Deribit future positions report quote `size` and base `size_currency`.
  Inverse market `contract_size` is quote-denominated, while linear market
  `contract_size` is base-denominated, so the divisor follows settlement.

  Every populated `notional` is paired with its actual unified currency code.
  Most venues publish quote value; Binance COIN-M and inverse Bybit/OKX rows
  publish settlement value, while OKX linear rows publish USD `notionalUsd`.
  """

  alias Bourse.Exchange
  alias Bourse.Position
  alias Bourse.Safe
  alias Bourse.Symbol

  @type parse_result :: {:ok, term()} | {:error, term()}

  @doc "Populates position unit fields and reconciles Deribit future contracts."
  @spec reconcile(parse_result(), Exchange.t()) :: parse_result()
  def reconcile({:ok, positions}, %Exchange{} = exchange) when is_list(positions) do
    positions
    |> reconcile_deribit_positions(exchange)
    |> put_notional_currencies(exchange)
  end

  def reconcile({:ok, %Position{} = position}, %Exchange{} = exchange) do
    position
    |> reconcile_deribit_position(exchange)
    |> put_notional_currency(exchange)
  end

  def reconcile(result, %Exchange{}), do: result

  defp reconcile_deribit_positions(positions, %Exchange{id: "deribit"} = exchange) do
    market_units = market_units(exchange.markets)
    Enum.map(positions, &reconcile_position(&1, market_units))
  end

  defp reconcile_deribit_positions(positions, _exchange), do: positions

  defp reconcile_deribit_position(position, %Exchange{id: "deribit"} = exchange) do
    reconcile_position(position, market_units(exchange.markets))
  end

  defp reconcile_deribit_position(position, _exchange), do: position

  defp put_notional_currencies(positions, exchange) do
    positions
    |> Enum.reduce_while({:ok, []}, fn position, {:ok, acc} ->
      case put_notional_currency(position, exchange) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp put_notional_currency(%Position{notional: nil} = position, _exchange), do: {:ok, position}

  defp put_notional_currency(%Position{} = position, %Exchange{} = exchange) do
    case notional_currency(position, exchange) do
      currency when is_binary(currency) and currency != "" ->
        {:ok, %{position | notional_currency: currency}}

      _missing_currency ->
        {:error, {:missing_position_notional_currency, %{exchange: exchange.id, symbol: position.symbol}}}
    end
  end

  defp put_notional_currency(other, _exchange), do: {:ok, other}

  defp notional_currency(_position, %Exchange{id: "alpaca"}), do: "USD"
  defp notional_currency(_position, %Exchange{id: "lighter"}), do: "USDC"

  defp notional_currency(position, %Exchange{id: "okx"}) do
    with {:ok, parsed} <- parsed_symbol(position) do
      if inverse_symbol?(parsed), do: parsed.settle, else: "USD"
    end
  end

  defp notional_currency(position, %Exchange{id: venue}) when venue in ["binancecoinm", "bybit"] do
    with {:ok, parsed} <- parsed_symbol(position) do
      if inverse_symbol?(parsed), do: parsed.settle, else: parsed.quote
    end
  end

  defp notional_currency(position, _exchange) do
    with {:ok, parsed} <- parsed_symbol(position), do: parsed.quote
  end

  defp parsed_symbol(%Position{symbol: symbol}) when is_binary(symbol), do: Symbol.parse_extended(symbol)
  defp parsed_symbol(_position), do: {:error, :invalid_format}

  defp inverse_symbol?(parsed) do
    parsed.settle == parsed.base and parsed.settle != parsed.quote
  end

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
