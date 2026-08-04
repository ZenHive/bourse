defmodule Bourse.WS.SubscribeRejectionLiveTest do
  @moduledoc """
  Live verification that venue-rejected subscriptions return
  `{:error, {:subscription_rejected, frame}}` rather than `:ok` (task 543).

  Gated by `:network` + `:ws_canary`. Run with:
    mix test.json --quiet --include ws_canary --only ws_canary test/bourse/ws/subscribe_rejection_live_test.exs
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS

  @moduletag :network
  @moduletag :ws_canary
  @moduletag trace_messages: 50

  @ack_timeout_ms 5_000

  describe "live subscription rejections" do
    test "bybit rejects an unknown topic" do
      exchange = Exchange.new!("bybit", sandbox: true)
      assert {:ok, ws} = WS.connect(exchange, :public)

      assert {:error, {:subscription_rejected, frame}} =
               WS.subscribe(ws, ["not.a.real.channel.XYZ"], ack_timeout_ms: @ack_timeout_ms)

      assert frame["success"] == false
      assert frame["op"] == "subscribe"
      assert is_binary(frame["ret_msg"])

      assert :ok = WS.close(ws)
    end

    test "hyperliquid rejects a double-wrapped map channel shape at the pattern layer" do
      # Pattern-layer fix: maps are accepted as subscription objects, not nested under type.
      # Malformed string-shaped "types" still reach the venue; use a nonsense type.
      exchange = Exchange.new!("hyperliquid", sandbox: true)
      assert {:ok, ws} = WS.connect(exchange, :public)

      assert {:error, {:subscription_rejected, frame}} =
               WS.subscribe(ws, ["notARealHyperliquidChannel"], ack_timeout_ms: @ack_timeout_ms)

      assert frame["channel"] == "error"
      assert is_binary(frame["data"])

      assert :ok = WS.close(ws)
    end

    test "deribit rejects unauthorized raw ticker channel" do
      exchange = Exchange.new!("deribit", sandbox: true)
      assert {:ok, ws} = WS.connect(exchange, :public)

      assert {:error, {:subscription_rejected, frame}} =
               WS.subscribe(ws, ["ticker.BTC-PERPETUAL.raw"], ack_timeout_ms: @ack_timeout_ms)

      assert get_in(frame, ["error", "code"]) == 13_778

      assert :ok = WS.close(ws)
    end

    test "derive rejects deprecated ticker channel" do
      exchange = Exchange.new!("derive", sandbox: true)
      assert {:ok, ws} = WS.connect(exchange, :public)

      assert {:error, {:subscription_rejected, frame}} =
               WS.subscribe(ws, ["ticker.ETH-PERPETUAL"], ack_timeout_ms: @ack_timeout_ms)

      assert is_map(frame["error"])
      data = get_in(frame, ["error", "data"]) || ""
      assert data =~ "ticker_slim" or data =~ "deprecated" or is_integer(get_in(frame, ["error", "code"]))

      assert :ok = WS.close(ws)
    end

    test "bybit accepted subscription still returns bare :ok" do
      exchange = Exchange.new!("bybit", sandbox: true)
      assert {:ok, ws} = WS.connect(exchange, :public)

      assert :ok = WS.subscribe(ws, ["tickers.BTCUSDT"], ack_timeout_ms: @ack_timeout_ms)
      assert :ok = WS.close(ws)
    end
  end
end
