defmodule Bourse.CoinbaseexchangePromotionIntegrationTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Ticker

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_coinbaseexchange

  @symbol "ETH/USD"
  @native_symbol "ETH-USD"
  @timeframe "1m"
  @short_limit 3
  # 450 buckets = a 300-row first page plus a 150-row second page, so the
  # seam assertion below survives sparse no-tick minutes (carve C-T593c).
  @paginated_limit 450
  @sparse_tolerance 10
  @provider_page_limit 300
  @invalid_granularity 61
  @milliseconds_per_minute 60_000

  setup do
    {:ok, exchange} = Bourse.Exchange.new("coinbaseexchange")
    %{exchange: exchange}
  end

  test "public ETH-USD ticker and candles parse live without credentials", %{exchange: exchange} do
    assert {:ok, %Ticker{symbol: @symbol, last: last, bid: bid, ask: ask, base_volume: volume}} =
             Bourse.fetch_ticker(exchange, @symbol)

    assert Enum.all?([last, bid, ask, volume], &is_number/1)
    assert bid <= ask

    assert {:ok, candles} = Bourse.fetch_ohlcv(exchange, @symbol, @timeframe, limit: @short_limit)
    assert length(candles) == @short_limit
    assert candles == Enum.sort_by(candles, &hd/1)

    for [timestamp, open, high, low, close, candle_volume] <- candles do
      assert is_integer(timestamp)
      assert Enum.all?([open, high, low, close, candle_volume], &is_number/1)
      assert low <= high
    end
  end

  test "a history wider than one provider page is windowed through the unified client", %{exchange: exchange} do
    current_bucket_ms = div(System.system_time(:millisecond), @milliseconds_per_minute) * @milliseconds_per_minute
    end_ms = current_bucket_ms - @milliseconds_per_minute
    since_ms = end_ms - (@paginated_limit - 1) * @milliseconds_per_minute

    assert {:ok, candles} =
             Bourse.fetch_ohlcv(exchange, @symbol, @timeframe,
               since: since_ms,
               until: end_ms,
               limit: @paginated_limit,
               timestamp_ms_override: end_ms
             )

    timestamps = Enum.map(candles, &hd/1)

    # The provider omits no-tick minutes (carve C-T593c), so an exact count
    # would flake; the tolerance still proves the window, and the seam
    # assertion proves rows arrived from beyond the 300-bucket first page.
    assert length(candles) <= @paginated_limit
    assert length(candles) >= @paginated_limit - @sparse_tolerance
    assert timestamps == Enum.sort(timestamps)
    assert length(Enum.uniq(timestamps)) == length(timestamps)
    assert List.first(timestamps) >= since_ms
    assert List.last(timestamps) <= end_ms
    assert Enum.any?(timestamps, &(&1 > since_ms + (@provider_page_limit - 1) * @milliseconds_per_minute))
  end

  test "a since-only single-page request returns the historical window, not the latest page", %{exchange: exchange} do
    since_ms =
      div(System.system_time(:millisecond), @milliseconds_per_minute) * @milliseconds_per_minute -
        10_000 * @milliseconds_per_minute

    assert {:ok, candles} = Bourse.fetch_ohlcv(exchange, @symbol, @timeframe, since: since_ms, limit: @short_limit)

    assert candles != []
    timestamps = Enum.map(candles, &hd/1)
    assert List.first(timestamps) >= since_ms
    # Coinbase ignores a lone start param; landing inside the requested
    # historical window proves the client shipped the start/end pair.
    assert List.last(timestamps) <= since_ms + @short_limit * @milliseconds_per_minute
  end

  test "unsupported candle granularity preserves the venue's live error semantics", %{exchange: exchange} do
    assert {:error,
            %Error{
              type: :bad_request,
              code: "Unsupported granularity",
              http_status: 400,
              message: "Unsupported granularity",
              raw: %{"message" => "Unsupported granularity"}
            }} =
             Bourse.Coinbaseexchange.public_get_products__id__candles(exchange, %{
               "id" => @native_symbol,
               "granularity" => @invalid_granularity
             })
  end
end
