defmodule Bourse.WS.HyperliquidWatchFrameDeliveryTest do
  @moduledoc """
  Provider-live delivery for Hyperliquid's authored public watch channels (task 702).

  Book and trade probes use testnet. The candle probe uses the production public
  socket because testnet `candle` acknowledges without a data frame (ledgered).
  Native coin ids (`BTC`) are required; unified `BTC/USDT` is not treated as proof.
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS

  @moduletag :network
  @moduletag :integration
  @moduletag :exchange_hyperliquid
  @moduletag timeout: 90_000

  for {method, channel} <- [watch_order_book: "l2Book", watch_trades: "trades"] do
    test "#{method} delivers provider data on the authored channel" do
      assert {:ok, ws} = WS.connect(Exchange.new!("hyperliquid", sandbox: true), :public)
      on_exit(fn -> WS.close(ws) end)

      assert {:ok, handle} = apply(WS, unquote(method), [ws, "BTC"])
      assert handle.channels == [%{"type" => unquote(channel), "coin" => "BTC"}]

      frame = await_channel(unquote(channel), System.monotonic_time(:millisecond) + 45_000)

      assert_data(unquote(channel), frame["data"])
    end
  end

  defp assert_data("l2Book", data) do
    assert %{"coin" => "BTC", "levels" => [[%{"px" => price} | _], [_ | _]]} = data
    assert {_, ""} = Float.parse(price)
  end

  defp assert_data("trades", data) do
    assert [%{"coin" => "BTC", "px" => price, "sz" => size, "tid" => id} | _] = data
    assert {_, ""} = Float.parse(price)
    assert {_, ""} = Float.parse(size)
    assert is_integer(id)
  end

  test "the authored candle channel delivers a candle with its required interval" do
    # Testnet candle is ledgered idle; production public WS is the live proof host.
    exchange = Exchange.new!("hyperliquid", sandbox: false)
    assert ["candle"] = get_in(exchange.spec, ["websocket", "subscribe", "channels", "watchOHLCV"])
    assert {:ok, ws} = WS.connect(exchange, :public)
    on_exit(fn -> WS.close(ws) end)
    assert :ok = WS.subscribe(ws, [%{"type" => "candle", "coin" => "BTC", "interval" => "1m"}])
    frame = await_channel("candle", System.monotonic_time(:millisecond) + 45_000)
    assert %{"s" => "BTC", "i" => "1m", "o" => open, "c" => close, "t" => timestamp} = frame["data"]
    assert {_, ""} = Float.parse(open)
    assert {_, ""} = Float.parse(close)
    assert is_integer(timestamp)
  end

  defp await_channel(channel, deadline) do
    receive do
      {:websocket_message, %{"channel" => ^channel, "data" => _} = frame} -> frame
      {:websocket_message, %{"channel" => "error"} = frame} -> flunk("Provider rejected channel: #{inspect(frame)}")
      {:websocket_message, _} -> await_channel(channel, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("No #{channel} data frame before deadline")
    end
  end
end
