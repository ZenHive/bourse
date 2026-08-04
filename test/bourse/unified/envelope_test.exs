defmodule Bourse.Unified.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Bourse.Unified.Envelope

  describe "unwrap/6" do
    test "unwraps binance fetchMarkets symbols envelope" do
      body = %{"symbols" => [%{"symbol" => "BTCUSDT"}]}

      assert {:ok, [%{"symbol" => "BTCUSDT"}]} =
               Envelope.unwrap(body, Bourse.Binance, "binance", "market", "fetchMarkets", true)
    end

    # COIN-M dapi exchangeInfo uses the same symbols[] list key as spot/fapi
    # (Binance docs GET /dapi/v1/exchangeInfo). Task 415: market envelope was null.
    test "unwraps binancecoinm fetchMarkets symbols envelope" do
      body = %{
        "timezone" => "UTC",
        "rateLimits" => [%{"rateLimitType" => "REQUEST_WEIGHT"}],
        "symbols" => [%{"symbol" => "BTCUSD_PERP", "baseAsset" => "BTC", "quoteAsset" => "USD"}]
      }

      assert {:ok, [%{"symbol" => "BTCUSD_PERP"}]} =
               Envelope.unwrap(body, Bourse.Binancecoinm, "binancecoinm", "market", "fetchMarkets", true)
    end

    test "passes through list bodies for list-return methods" do
      body = [%{"tradeId" => "1"}]

      assert {:ok, ^body} =
               Envelope.unwrap(body, Bourse.Okx, "okx", "trade", "fetchTrades", true)
    end

    test "unwraps bybit ticker list and coerces to single object" do
      body = %{"result" => %{"list" => [%{"lastPrice" => "1"}]}}

      assert {:ok, %{"lastPrice" => "1"}} =
               Envelope.unwrap(body, Bourse.Bybit, "bybit", "ticker", "fetchTicker", false)
    end

    test "unwraps okx data envelope via dot-delimited key" do
      body = %{"code" => "0", "data" => [%{"last" => "1"}]}

      assert {:ok, [%{"last" => "1"}]} =
               Envelope.unwrap(body, Bourse.Okx, "okx", "trade", "fetchTrades", true)
    end

    test "ignores nil response_envelope slots without crashing" do
      body = %{"lastPrice" => "1", "symbol" => "BTCUSDT"}

      assert {:ok, ^body} =
               Envelope.unwrap(body, Bourse.Binanceusdm, "binanceusdm", "ticker", "fetchTicker", false)
    end

    test "lighter fetchTicker skips empty primary envelope key and falls back (T197)" do
      body = %{
        "code" => 200,
        "order_book_details" => [%{"market_id" => 1, "last_trade_price" => 1.0, "symbol" => "BTC"}],
        "spot_order_book_details" => []
      }

      assert {:ok, %{"market_id" => 1, "last_trade_price" => 1.0}} =
               Envelope.unwrap(body, Bourse.Lighter, "lighter", "ticker", "fetchTicker", false)
    end
  end
end
