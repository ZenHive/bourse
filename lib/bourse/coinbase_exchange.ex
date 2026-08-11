defmodule Bourse.CoinbaseCandlePagination do
  @moduledoc """
  Coinbase Exchange candle-window mechanics.

  Coinbase's Exchange API accepts granularities `60`, `300`, `900`, `3600`,
  `21600`, and `86400` seconds. Its candle endpoint returns newest-first rows
  and documents a 300-candle maximum. Because `start` and `end` are inclusive,
  Bourse requests at most 299 intervals per page, then merges non-overlapping
  pages back into Coinbase's newest-first wire order.

  Unified callers use `ETH/USD`; the authored dash symbol pattern routes it to
  Coinbase's `ETH-USD` product id. Native product ids remain available on the
  generated raw endpoint functions.

  Live observation on 2026-08-11 established that the current forming bucket
  appears once it contains a trade. Intervals without ticks are omitted, as the
  provider documentation states; callers must not assume a dense time series.
  """

  @max_candles_per_request 300
  @milliseconds_per_second 1_000

  @type page :: %{params: map(), start_ms: non_neg_integer(), end_ms: non_neg_integer()}

  @doc "Builds inclusive, non-overlapping request pages when `limit` exceeds 300."
  @spec pagination(map(), map(), non_neg_integer()) ::
          :single | {:paginate, [page()], %{start_ms: non_neg_integer(), end_ms: non_neg_integer(), limit: pos_integer()}}
  def pagination(%{"limit" => limit} = params, timeframes, now_ms)
      when is_integer(limit) and limit > @max_candles_per_request do
    timeframe_ms = timeframe_ms!(params, timeframes)
    {start_ms, end_ms} = requested_window(params, now_ms, limit, timeframe_ms)
    count = min(limit, max(div(end_ms - start_ms, timeframe_ms) + 1, 1))

    metadata = %{end_ms: end_ms, limit: count, start_ms: start_ms}
    {:paginate, build_pages(params, start_ms, count, timeframe_ms), metadata}
  end

  def pagination(_params, _timeframes, _now_ms), do: :single

  @doc "Merges paged raw responses, deduplicating and retaining the requested chronological range."
  @spec merge_responses!([map()], map()) :: map()
  def merge_responses!([first | _] = responses, %{start_ms: start_ms, end_ms: end_ms, limit: limit}) do
    rows =
      responses
      |> Enum.flat_map(&response_rows!/1)
      |> Enum.filter(fn row -> row_in_window?(row, start_ms, end_ms) end)
      |> Enum.uniq_by(&row_timestamp_ms!/1)
      |> Enum.sort_by(&row_timestamp_ms!/1)
      |> Enum.take(limit)
      |> Enum.reverse()

    Map.put(first, :body, rows)
  end

  defp timeframe_ms!(%{"timeframe" => timeframe}, timeframes) do
    case Map.fetch(timeframes, timeframe) do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 -> seconds * @milliseconds_per_second
      _ -> raise ArgumentError, "unsupported Coinbase Exchange timeframe #{inspect(timeframe)}"
    end
  end

  defp requested_window(%{"since" => since_ms} = params, now_ms, limit, timeframe_ms) when is_integer(since_ms) do
    requested_end = Map.get(params, "until", since_ms + (limit - 1) * timeframe_ms)
    end_ms = min(requested_end, now_ms)
    {min(since_ms, end_ms), end_ms}
  end

  defp requested_window(params, now_ms, limit, timeframe_ms) do
    end_ms = min(Map.get(params, "until", now_ms), now_ms)
    {max(end_ms - (limit - 1) * timeframe_ms, 0), end_ms}
  end

  defp build_pages(params, start_ms, count, timeframe_ms) do
    {start_ms, count}
    |> Stream.unfold(fn
      {_page_start, 0} ->
        nil

      {page_start, remaining} ->
        page_count = min(remaining, @max_candles_per_request)
        page_end = page_start + (page_count - 1) * timeframe_ms

        page = %{
          end_ms: page_end,
          params: params |> Map.put("since", page_start) |> Map.put("until", page_end),
          start_ms: page_start
        }

        {page, {page_end + timeframe_ms, remaining - page_count}}
    end)
    |> Enum.to_list()
  end

  defp response_rows!(%{body: rows}) when is_list(rows), do: rows
  defp response_rows!(response), do: raise(ArgumentError, "unexpected Coinbase candle response: #{inspect(response)}")

  defp row_in_window?(row, start_ms, end_ms) do
    timestamp_ms = row_timestamp_ms!(row)
    timestamp_ms >= start_ms and timestamp_ms <= end_ms
  end

  defp row_timestamp_ms!([timestamp_seconds | _]) when is_integer(timestamp_seconds),
    do: timestamp_seconds * @milliseconds_per_second

  defp row_timestamp_ms!(row), do: raise(ArgumentError, "unexpected Coinbase candle row: #{inspect(row)}")
end
