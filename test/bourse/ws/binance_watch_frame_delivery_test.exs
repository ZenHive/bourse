defmodule Bourse.WS.BinanceWatchFrameDeliveryTest do
  @moduledoc """
  Live frame-delivery evidence for the default binance-family public watch
  path (tasks 618 and 627).

  Binance acks unknown stream names, so a subscribe-ack is not evidence.
  These tests go through `watch_*` with no caller-supplied channel and wait
  for a data frame that matches the provider payload.

  Gated by `:network` + `:integration`. Run with:

      mix test.json --quiet --include network --include integration \\
        test/bourse/ws/binance_watch_frame_delivery_test.exs
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS

  @moduletag :network
  @moduletag :integration
  @moduletag trace_messages: 200

  @receive_timeout 15_000

  describe "binance spot default public watch path" do
    test "watch_order_book delivers a partial-depth book frame" do
      exchange = Exchange.new!("binance")
      assert {:ok, ws} = WS.connect(exchange, :public)

      assert {:ok, handle} = WS.watch_order_book(ws, "BTC/USDT")
      assert handle.channels == ["btcusdt@depth20@100ms"]

      frame = await_data_frame(&book_frame?/1, @receive_timeout)
      assert book_frame?(frame)
      assert length(frame["bids"]) == 20
      assert length(frame["asks"]) == 20

      assert :ok = WS.close(ws)
    end

    test "watch_trades delivers a trade frame" do
      exchange = Exchange.new!("binance")
      assert {:ok, ws} = WS.connect(exchange, :public)

      assert {:ok, handle} = WS.watch_trades(ws, "BTC/USDT")
      assert handle.channels == ["btcusdt@trade"]

      frame = await_data_frame(&trade_frame?/1, @receive_timeout)
      assert frame["e"] == "trade"
      assert frame["s"] == "BTCUSDT"

      assert :ok = WS.close(ws)
    end

    test "watch_ticker delivers a mini-ticker frame" do
      exchange = Exchange.new!("binance")
      assert {:ok, ws} = WS.connect(exchange, :public)

      assert {:ok, handle} = WS.watch_ticker(ws, "BTC/USDT")
      assert handle.channels == ["btcusdt@miniTicker"]

      frame = await_data_frame(&mini_ticker_frame?/1, @receive_timeout)
      assert frame["e"] == "24hrMiniTicker"
      assert frame["s"] == "BTCUSDT"

      assert :ok = WS.close(ws)
    end
  end

  describe "binanceusdm default public watch path" do
    test "watch_order_book delivers a depthUpdate book frame" do
      exchange = Exchange.new!("binanceusdm")
      assert {:ok, ws} = WS.connect(exchange, :public)
      assert ws.url == "wss://fstream.binance.com/public/ws"

      assert {:ok, handle} = WS.watch_order_book(ws, "BTC/USDT")
      assert handle.channels == ["btcusdt@depth20@100ms"]
      assert handle.ws.url == "wss://fstream.binance.com/public/ws"

      frame = await_data_frame(&book_frame?/1, @receive_timeout)
      assert book_frame?(frame)

      assert :ok = WS.close(ws)
    end

    test "watch_trades delivers a trade frame" do
      exchange = Exchange.new!("binanceusdm")
      assert {:ok, ws} = WS.connect(exchange, :public)
      assert ws.url == "wss://fstream.binance.com/public/ws"

      assert {:ok, handle} = WS.watch_trades(ws, "BTC/USDT")
      assert handle.channels == ["btcusdt@trade"]
      assert handle.ws.url == "wss://fstream.binance.com/public/ws"

      frame = await_data_frame(&trade_frame?/1, @receive_timeout)
      assert frame["e"] == "trade"
      assert frame["s"] == "BTCUSDT"

      assert :ok = WS.close(ws)
    end

    test "watch_ticker delivers a mini-ticker frame on /market/ws" do
      exchange = Exchange.new!("binanceusdm")
      assert {:ok, ws} = WS.connect(exchange, :public)
      assert ws.url == "wss://fstream.binance.com/public/ws"

      assert {:ok, handle} = WS.watch_ticker(ws, "BTC/USDT")
      assert handle.channels == ["btcusdt@miniTicker"]
      assert handle.ws.url == "wss://fstream.binance.com/market/ws"

      frame = await_data_frame(&mini_ticker_frame?/1, @receive_timeout)
      assert frame["e"] == "24hrMiniTicker"
      assert frame["s"] == "BTCUSDT"

      assert :ok = WS.close(handle.ws)
      assert :ok = WS.close(ws)
    end
  end

  defp await_data_frame(predicate, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_data_frame(predicate, deadline)
  end

  defp do_await_data_frame(predicate, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("timed out waiting for a data frame on the default watch path")
    else
      receive do
        {:websocket_message, %{"result" => _} = _ack} ->
          do_await_data_frame(predicate, deadline)

        {:websocket_message, frame} when is_map(frame) ->
          if predicate.(frame) do
            frame
          else
            do_await_data_frame(predicate, deadline)
          end
      after
        max(left, 0) ->
          flunk("timed out waiting for a data frame on the default watch path")
      end
    end
  end

  defp book_frame?(%{"lastUpdateId" => _, "bids" => bids, "asks" => asks})
       when is_list(bids) and is_list(asks) and bids != [] and asks != [] do
    true
  end

  defp book_frame?(%{"e" => "depthUpdate"} = frame) do
    bids = frame["b"] || frame["bids"]
    asks = frame["a"] || frame["asks"]
    is_list(bids) and is_list(asks) and bids != [] and asks != []
  end

  defp book_frame?(_frame), do: false

  defp trade_frame?(%{"e" => "trade", "s" => symbol, "p" => price, "q" => qty})
       when is_binary(symbol) and is_binary(price) and is_binary(qty) do
    true
  end

  defp trade_frame?(_frame), do: false

  defp mini_ticker_frame?(%{"e" => "24hrMiniTicker", "s" => symbol, "c" => close})
       when is_binary(symbol) and is_binary(close) do
    true
  end

  defp mini_ticker_frame?(_frame), do: false
end
