defmodule Bourse.WS.CanaryTest do
  @moduledoc """
  End-to-end WS canary tests for Task 92.

  Each canary validates the architecture (URL resolution + heartbeat selection +
  subscribe-frame builder + receive loop) against the real public WebSocket
  endpoint. No shape assertions beyond "received a decoded map."

  Gated by `:network` + `:ws_canary` — excluded from default runs.
  Run with: `mix test.json --quiet --include ws_canary --only ws_canary`
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS

  @moduletag :network
  @moduletag :ws_canary
  @moduletag trace_messages: 200

  @receive_timeout 10_000

  describe "bybit public WS" do
    test "connect → subscribe → receive → close" do
      exchange = Exchange.new!("bybit")
      assert {:ok, ws} = WS.connect(exchange, :public)
      assert WS.get_state(ws) == :connected

      assert :ok = WS.subscribe(ws, ["tickers.BTCUSDT"])
      assert_receive {:websocket_message, %{} = _frame}, @receive_timeout

      assert :ok = WS.close(ws)
    end
  end

  describe "deribit public WS" do
    test "connect → subscribe (JSON-RPC) → receive → close" do
      exchange = Exchange.new!("deribit")
      assert {:ok, ws} = WS.connect(exchange, :public)
      assert WS.get_state(ws) == :connected

      # Deribit subscribe carries a JSON-RPC id — correlated reply is classified to :ok
      # (unified return shape, task 543). Use a public (non-raw) channel; raw needs auth.
      assert :ok = WS.subscribe(ws, ["ticker.BTC-PERPETUAL.100ms"])

      # Channel data arrives asynchronously after the subscribe-ack.
      assert_receive {:websocket_message, %{} = _frame}, @receive_timeout

      assert :ok = WS.close(ws)
    end
  end

  describe "okx public WS" do
    test "connect → subscribe → receive → close" do
      exchange = Exchange.new!("okx")
      assert {:ok, ws} = WS.connect(exchange, :public)
      assert WS.get_state(ws) == :connected

      assert :ok = WS.subscribe(ws, [%{"channel" => "tickers", "instId" => "BTC-USDT"}])
      assert_receive {:websocket_message, %{} = _frame}, @receive_timeout

      assert :ok = WS.close(ws)
    end
  end
end
