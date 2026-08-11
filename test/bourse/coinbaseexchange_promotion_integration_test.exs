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
  @paginated_limit 301
  @invalid_granularity 61
  @milliseconds_per_minute 60_000

  setup do
    require_credentials!()
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

    assert length(candles) == @paginated_limit
    assert candles == Enum.sort_by(candles, &hd/1)
    assert candles |> Enum.map(&hd/1) |> Enum.uniq() |> length() == @paginated_limit
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

  # Coinbase Exchange is deliberately public-only. The promotion contract looks
  # for this setup hook, while the hook itself pins that no credential gate exists.
  defp require_credentials!, do: :ok
end
