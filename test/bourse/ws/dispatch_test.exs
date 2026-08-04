defmodule Bourse.WS.DispatchTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.Dispatch

  test "resolves bybit orderbook channel via substring match" do
    exchange = Exchange.new!("bybit")

    assert {:family, :watch_order_book} =
             Dispatch.resolve_channel(exchange, "orderbook.500.BTCUSDT")
  end

  test "resolves deribit ticker via split match" do
    exchange = Exchange.new!("deribit")

    assert {:family, :watch_ticker} =
             Dispatch.resolve_channel(exchange, "ticker.BTC-PERPETUAL.raw")
  end

  test "returns :system for pong handler" do
    exchange = Exchange.new!("bybit")

    assert :system = Dispatch.resolve_channel(exchange, "pong")
  end

  test "uses exact, prefix, and no-match dispatch paths" do
    exchange = Exchange.new!("okx")

    spec = %{
      "websocket" => %{
        "dispatch" => %{
          "entries" => [
            %{"channel" => "tickers", "handler" => "handleTicker"},
            %{"channel" => "candle", "handler" => "handleOHLCV"}
          ]
        }
      }
    }

    exchange = %{exchange | spec: spec}
    assert Dispatch.entries(exchange) == get_in(spec, ["websocket", "dispatch", "entries"])
    assert {:family, :watch_ticker} = Dispatch.resolve_channel(exchange, "tickers")
    assert {:family, :watch_ohlcv} = Dispatch.resolve_channel(exchange, "candle1m")
    assert :not_found = Dispatch.resolve_channel(exchange, "unknown")
  end

  test "returns empty entries when dispatch data is unavailable" do
    exchange = %{Exchange.new!("bybit") | spec: %{}}
    assert Dispatch.entries(exchange) == []
  end
end
