defmodule Bourse.WS.HeartbeatContractLiveTest do
  @moduledoc """
  Provider-live prerequisites for the heartbeat lifecycle integration.

  These contracts do not grade automatic heartbeat reply isolation or bounded
  disconnects; the zen_websocket 0.9.0 blocker is documented in
  docs/ws-heartbeat-upstream.md.
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS
  alias ZenWebsocket.Client

  @moduletag :integration
  @moduletag :network
  @moduletag :ws_canary
  @moduletag trace_messages: 50

  test "Deribit correlates public/test and subscription outcomes while delivering ticker data" do
    assert {:ok, ws} = WS.connect(Exchange.new!("deribit", sandbox: true), :public)

    try do
      request = Jason.encode!(%{jsonrpc: "2.0", id: "heartbeat-contract", method: "public/test", params: %{}})

      assert {:ok, %{"id" => "heartbeat-contract", "result" => %{"version" => version}}} =
               Client.send_message(ws.zen_client, request)

      assert is_binary(version) and byte_size(version) > 0
      assert :ok = WS.subscribe(ws, ["ticker.BTC-PERPETUAL.100ms"])

      assert_receive {:websocket_message,
                      %{
                        "method" => "subscription",
                        "params" => %{"channel" => "ticker.BTC-PERPETUAL.100ms", "data" => data}
                      }},
                     10_000

      assert data["instrument_name"] == "BTC-PERPETUAL"
      assert is_number(data["mark_price"]) and data["mark_price"] > 0

      assert {:error, {:subscription_rejected, frame}} = WS.subscribe(ws, ["ticker.BTC-PERPETUAL.raw"])
      assert frame["error"]["code"] == 13_778

      refute_receive {:websocket_message, %{"id" => "heartbeat-contract"}}
      refute_receive {:websocket_message, %{"result" => ["ticker.BTC-PERPETUAL.100ms"]}}
      refute_receive {:websocket_message, %{"error" => %{"code" => 13_778}}}
    after
      WS.close(ws)
    end
  end

  test "Binance native pong provides heartbeat evidence without any market subscription" do
    assert {:ok, ws} =
             WS.connect(Exchange.new!("binance", sandbox: true), :public,
               heartbeat_config: %{type: :ping_pong, interval: 1_000}
             )

    try do
      health = await_native_pong(ws.zen_client, System.monotonic_time(:millisecond) + 10_000)
      assert health.active_heartbeats == [:ping_pong]
      assert health.failure_count == 0
      assert is_integer(health.last_heartbeat_at)
      assert Client.get_state(ws.zen_client) == :connected
      refute_receive {:websocket_message, _}
    after
      WS.close(ws)
    end
  end

  defp await_native_pong(client, deadline) do
    case Client.get_heartbeat_health(client) do
      %{active_heartbeats: [:ping_pong]} = health ->
        health

      health ->
        assert System.monotonic_time(:millisecond) < deadline,
               "No live Binance native pong within 10 seconds: #{inspect(health)}"

        receive do
        after
          50 -> await_native_pong(client, deadline)
        end
    end
  end
end
