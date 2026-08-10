defmodule Bourse.Unified.FundingInterval do
  @moduledoc false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.FundingRate
  alias Bourse.Safe
  alias Bourse.Symbol
  alias Bourse.Unified

  @binance_family ~w(binance binancecoinm binanceusdm)
  @binance_default_interval "8h"

  @doc false
  @spec enrich(
          {:ok, term()} | {:error, term()},
          Exchange.t(),
          atom(),
          map(),
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  def enrich(
        {:ok, %FundingRate{interval: nil} = funding_rate},
        %Exchange{id: id} = exchange,
        :fetch_funding_rate,
        params,
        opts
      )
      when id in @binance_family do
    with {:ok, body} <- funding_intervals(exchange, params, opts) do
      enrich_rate(funding_rate, body, exchange, params)
    end
  end

  def enrich({:ok, funding_rates}, %Exchange{id: id} = exchange, :fetch_funding_rates, params, opts)
      when id in @binance_family and is_map(funding_rates) do
    with {:ok, body} <- funding_intervals(exchange, params, opts) do
      enrich_rates(funding_rates, body, exchange)
    end
  end

  def enrich(result, _exchange, _method, _params, _opts), do: result

  defp funding_intervals(exchange, params, opts) do
    with {:ok, %{body: body}} <- Unified.raw_call(exchange, :fetch_funding_intervals, params, opts) do
      {:ok, body}
    end
  end

  defp enrich_rates(funding_rates, body, exchange) do
    Enum.reduce_while(funding_rates, {:ok, %{}}, fn {symbol, funding_rate}, {:ok, enriched} ->
      case enrich_rate(funding_rate, body, exchange, %{"symbol" => symbol}) do
        {:ok, rate} -> {:cont, {:ok, Map.put(enriched, symbol, rate)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp enrich_rate(%FundingRate{interval: interval} = funding_rate, _body, _exchange, _params) when not is_nil(interval),
    do: {:ok, funding_rate}

  defp enrich_rate(%FundingRate{} = funding_rate, body, exchange, params) do
    case native_symbol(funding_rate, exchange, params) do
      nil ->
        unresolved_symbol(exchange)

      native_symbol ->
        with {:ok, interval} <- interval_for(body, native_symbol, exchange, funding_rate) do
          {:ok, %{funding_rate | interval: interval}}
        end
    end
  end

  defp interval_for(body, native_symbol, exchange, funding_rate) do
    case Enum.find(List.wrap(body), &(is_map(&1) and &1["symbol"] == native_symbol)) do
      nil ->
        {:ok, default_interval(funding_rate)}

      row ->
        case Safe.integer(row["fundingIntervalHours"]) do
          hours when is_integer(hours) and hours > 0 -> {:ok, "#{hours}h"}
          _ -> invalid_interval(exchange, row)
        end
    end
  end

  defp default_interval(%FundingRate{info: %{"nextFundingTime" => timestamp}}) do
    case Safe.integer(timestamp) do
      timestamp when is_integer(timestamp) and timestamp > 0 -> @binance_default_interval
      _ -> nil
    end
  end

  defp default_interval(%FundingRate{}), do: nil

  defp native_symbol(%FundingRate{info: %{"symbol" => symbol}}, _exchange, _params) when is_binary(symbol), do: symbol

  defp native_symbol(_funding_rate, exchange, %{"symbol" => symbol}) when is_binary(symbol),
    do: Symbol.to_exchange_id(symbol, exchange)

  defp native_symbol(_funding_rate, _exchange, _params), do: nil

  defp unresolved_symbol(exchange) do
    {:error,
     Error.exchange_error(
       "Cannot resolve the native symbol for the #{exchange.id} funding-interval join",
       exchange: exchange.id
     )}
  end

  defp invalid_interval(exchange, row) do
    {:error,
     Error.exchange_error(
       "Invalid fundingIntervalHours from #{exchange.id} funding info",
       exchange: exchange.id,
       raw: row
     )}
  end
end
