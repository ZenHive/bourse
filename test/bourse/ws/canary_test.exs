defmodule Bourse.WS.CanaryTest do
  @moduledoc """
  End-to-end WS canary tests for Task 92.

  Each canary validates the architecture (URL resolution + heartbeat selection +
  subscribe-frame builder + receive loop) against the real public WebSocket
  endpoint.

  Gated by `:network` + `:ws_canary` — excluded from default runs.
  Run with: `mix test.json --quiet --include ws_canary --only ws_canary`
  """

  use Bourse.Test.Case, async: false

  import Bourse.IntegrationHelper, only: [require_credentials!: 2]

  alias Bourse.Exchange
  alias Bourse.WS

  @moduletag :network
  @moduletag :ws_canary
  @moduletag trace_messages: 200

  @receive_timeout 10_000

  describe "alpaca public market-data WS" do
    @tag :task_544
    test "connect → authenticate → subscribe → receive → reject invalid channel → close" do
      credentials = require_credentials!(:alpaca, url: "https://app.alpaca.markets/paper/dashboard/overview")
      exchange = Exchange.new!("alpaca", credentials: credentials, sandbox: true)
      assert {:ok, ws} = WS.connect(exchange, :public)

      try do
        assert WS.get_state(ws) == :connected
        assert %{pattern: :action_key_secret} = ws.auth
        assert {:ok, _handle} = WS.watch_trades(ws, "FAKEPACA")

        assert_receive {:websocket_message, [%{"T" => "t", "S" => "FAKEPACA"} | _]},
                       @receive_timeout

        assert {:error, {:subscription_rejected, %{"T" => "error", "code" => 400}}} =
                 WS.subscribe(ws, ["bogus:FAKEPACA"])
      after
        WS.close(ws)
      end
    end
  end

  describe "lighter public WS" do
    @tag :task_544
    test "connect → subscribe → receive → close" do
      exchange = Exchange.new!("lighter", sandbox: true)
      assert {:ok, ws} = WS.connect(exchange, :public)

      try do
        assert WS.get_state(ws) == :connected
        assert :ok = WS.subscribe(ws, ["market_stats/0"], ack_timeout_ms: 0)

        assert_receive {:websocket_message, %{"channel" => "market_stats:0", "market_stats" => %{}}},
                       @receive_timeout
      after
        WS.close(ws)
      end
    end

    @tag :task_544
    test "surfaces the provider's invalid-channel rejection" do
      exchange = Exchange.new!("lighter", sandbox: true)
      assert {:ok, ws} = WS.connect(exchange, :public)

      try do
        assert {:error, {:subscription_rejected, %{"error" => %{"code" => 30_005, "message" => "Invalid Channel"}}}} =
                 WS.subscribe(ws, ["not_a_real_channel/0"])
      after
        WS.close(ws)
      end
    end
  end

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
