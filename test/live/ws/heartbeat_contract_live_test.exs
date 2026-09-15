defmodule Bourse.WS.HeartbeatContractLiveTest do
  @moduledoc """
  Provider-live heartbeat and control-isolation contracts.

  Bounded disconnect-on-miss remains a zen_websocket 0.9.0 gap
  (`docs/ws-heartbeat-upstream.md`). These tests pin what Bourse can observe
  against live hosts without inventing a competing heartbeat state machine.
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS

  @moduletag :integration
  @moduletag :network
  @moduletag :ws_canary
  @moduletag trace_messages: 50

  test "Deribit delivers ticker data while public/test and subscribe outcomes stay off the market-data path" do
    assert {:ok, ws} =
             WS.connect(Exchange.new!("deribit", sandbox: true), :public,
               heartbeat_config: %{type: :deribit, interval: 1_000}
             )

    try do
      assert :ok = WS.subscribe(ws, ["ticker.BTC-PERPETUAL.100ms"])

      assert_receive {:websocket_message,
                      %{
                        "method" => "subscription",
                        "params" => %{"channel" => "ticker.BTC-PERPETUAL.100ms", "data" => data}
                      }},
                     10_000

      assert data["instrument_name"] == "BTC-PERPETUAL"
      assert is_number(data["mark_price"]) and data["mark_price"] > 0

      assert_receive {:websocket_unmatched_response, %{"result" => %{"version" => version}}}, 10_000
      assert is_binary(version) and byte_size(version) > 0
      refute_received {:websocket_message, %{"result" => %{"version" => _}}}

      assert {:error, {:subscription_rejected, frame}} = WS.subscribe(ws, ["ticker.BTC-PERPETUAL.raw"])
      assert frame["error"]["code"] == 13_778
      refute_received {:websocket_message, %{"error" => %{"code" => 13_778}}}

      assert {:ok, [%{role: :primary, connection_state: :connected, heartbeat: health}]} = WS.health(ws)
      assert health.config.type == :deribit
      assert is_integer(health.last_heartbeat_at)
    after
      WS.close(ws)
    end
  end

  test "Binance native pong health stays healthy without any market subscription" do
    assert {:ok, ws} =
             WS.connect(Exchange.new!("binance", sandbox: true), :public,
               heartbeat_config: %{type: :ping_pong, interval: 1_000}
             )

    try do
      observation = await_native_pong(ws, System.monotonic_time(:millisecond) + 10_000)
      assert observation.role == :primary
      assert observation.connection_state == :connected
      assert observation.heartbeat.active_heartbeats == [:ping_pong]
      assert observation.heartbeat.failure_count == 0
      assert is_integer(observation.heartbeat.last_heartbeat_at)
      refute_receive {:websocket_message, _}
    after
      WS.close(ws)
    end
  end

  defp await_native_pong(ws, deadline) do
    case WS.health(ws) do
      {:ok, [%{heartbeat: %{active_heartbeats: [:ping_pong]}} = observation | _]} ->
        observation

      {:ok, observations} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "No live Binance native pong within 10 seconds: #{inspect(observations)}"

        receive do
        after
          50 -> await_native_pong(ws, deadline)
        end
    end
  end
end
