defmodule Bourse.CoinbaseCandleWindowIntegrationTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_coinbaseexchange
  @hour 3_600_000

  setup do
    {:ok, exchange} = Bourse.Exchange.new("coinbaseexchange")
    %{exchange: exchange}
  end

  test "1200 opened hourly candles ending inside the current hour", %{exchange: exchange} do
    now = System.system_time(:millisecond)
    opening = div(now, @hour) * @hour
    since = opening - 1199 * @hour

    assert {:ok, candles} = Bourse.fetch_ohlcv(exchange, "ETH/USD", "1h", since: since, until: now, limit: 1200)
    assert Enum.map(candles, &hd/1) == Enum.map(0..1199, &(since + &1 * @hour))
  end

  test "unaligned pagination preserves openings at both page seams", %{exchange: exchange} do
    last = div(System.system_time(:millisecond), @hour) * @hour - @hour
    first = last - 600 * @hour

    assert {:ok, candles} =
             Bourse.fetch_ohlcv(exchange, "ETH/USD", "1h",
               since: first - 1,
               until: last + 1,
               limit: 601
             )

    assert Enum.map(candles, &hd/1) == Enum.map(0..600, &(first + &1 * @hour))
  end

  test "raw endpoint includes aligned boundaries and rejects a future start", %{exchange: exchange} do
    hour_seconds = div(System.system_time(:second), 3600) * 3600
    start = hour_seconds - 3 * 3600

    # Contract: https://docs.cdp.coinbase.com/api-reference/exchange-api/rest-api/products/get-product-candles
    for {offset, expected} <- [{0, [start + 7200, start + 3600, start]}, {1, [start + 7200, start + 3600]}] do
      assert {:ok, %{body: rows}} =
               Bourse.Coinbaseexchange.public_get_products__id__candles(exchange, %{
                 "id" => "ETH-USD",
                 "granularity" => 3600,
                 "start" => start + offset,
                 "end" => start + 7200 + offset
               })

      assert Enum.map(rows, &hd/1) == expected
    end

    assert {:error, %Error{http_status: 400, message: "Start cannot be in the future"}} =
             Bourse.Coinbaseexchange.public_get_products__id__candles(exchange, %{
               "id" => "ETH-USD",
               "granularity" => 3600,
               "start" => hour_seconds + 7200,
               "end" => hour_seconds + 10_800
             })
  end
end
