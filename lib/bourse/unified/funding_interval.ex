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
    with {:ok, %{body: body}} <- Unified.raw_call(exchange, :fetch_funding_intervals, params, opts),
         {:ok, interval} <- interval(body, funding_rate, exchange, params) do
      {:ok, %{funding_rate | interval: interval}}
    end
  end

  def enrich(result, _exchange, _method, _params, _opts), do: result

  defp interval(body, funding_rate, exchange, params) do
    native_symbol = native_symbol(funding_rate, exchange, params)

    case Enum.find(List.wrap(body), &(is_map(&1) and &1["symbol"] == native_symbol)) do
      nil ->
        {:ok, @binance_default_interval}

      row ->
        case Safe.integer(row["fundingIntervalHours"]) do
          hours when is_integer(hours) and hours > 0 -> {:ok, "#{hours}h"}
          _ -> invalid_interval(exchange, row)
        end
    end
  end

  defp native_symbol(%FundingRate{info: %{"symbol" => symbol}}, _exchange, _params) when is_binary(symbol), do: symbol

  defp native_symbol(_funding_rate, exchange, %{"symbol" => symbol}) when is_binary(symbol),
    do: Symbol.to_exchange_id(symbol, exchange)

  defp native_symbol(_funding_rate, _exchange, _params), do: nil

  defp invalid_interval(exchange, row) do
    {:error,
     Error.exchange_error(
       "Invalid fundingIntervalHours from #{exchange.id} funding info",
       exchange: exchange.id,
       raw: row
     )}
  end
end
