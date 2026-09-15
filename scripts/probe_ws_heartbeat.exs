# Run with MIX_ENV=test mix run scripts/probe_ws_heartbeat.exs.
# Diagnostic only: assertions establish live provider prerequisites, not task completion.
defmodule HeartbeatProbe do
  @moduledoc false

  import ExUnit.Assertions

  alias Bourse.Exchange
  alias Bourse.WS
  alias ZenWebsocket.Client

  @spec run() :: :ok
  def run do
    deribit()
    unsupported_ping()
    binance()
  end

  defp deribit do
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

      assert {:error, {:subscription_rejected, frame}} =
               WS.subscribe(ws, ["ticker.BTC-PERPETUAL.raw"])

      assert frame["error"]["code"] == 13_778

      assert_receive {:websocket_message, %{"result" => %{"version" => version}} = reply}, 5_000
      assert is_binary(version)
      report(:deribit_control_leak, reply)
      report(:deribit_health, Client.get_heartbeat_health(ws.zen_client))
    after
      WS.close(ws)
    end
  end

  defp unsupported_ping do
    assert {:ok, ws} = WS.connect(Exchange.new!("binance", sandbox: true), :public)

    try do
      client = ws.zen_client
      report(:binance_authored_config, Client.get_heartbeat_health(client))
      send(client.server_pid, :send_heartbeat)
      report(:binance_authored_config_after_tick, Client.get_heartbeat_health(client))
    after
      WS.close(ws)
    end
  end

  defp binance do
    assert {:ok, ws} =
             WS.connect(Exchange.new!("binance", sandbox: true), :public,
               heartbeat_config: %{type: :ping_pong, interval: 1_000}
             )

    try do
      client = ws.zen_client

      healthy =
        await(fn ->
          health = Client.get_heartbeat_health(client)
          if :ping_pong in health.active_heartbeats, do: health
        end)

      report(:binance_native_pong_without_subscription, healthy)
      assert healthy.failure_count == 0
      assert is_integer(healthy.last_heartbeat_at)

      # Fault the real Gun process, not a simulated venue. Client timers continue
      # running, but outbound pings and inbound pongs cannot cross the transport.
      gun_pid = :sys.get_state(client.server_pid).gun_pid
      :ok = :sys.suspend(gun_pid)

      try do
        failed =
          await(fn ->
            health = Client.get_heartbeat_health(client)
            if health.failure_count >= 3, do: health
          end)

        report(:binance_missed_pongs, failed)
        report(:binance_state_after_missed_pongs, Client.get_state(client))
      after
        :ok = :sys.resume(gun_pid)
      end

      recovered =
        await(fn ->
          health = Client.get_heartbeat_health(client)
          if health.failure_count == 0 and health.last_heartbeat_at > healthy.last_heartbeat_at, do: health
        end)

      report(:binance_resumed_transport, recovered)
    after
      WS.close(ws)
    end
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 10_000)

  defp await(fun, deadline) do
    case fun.() do
      nil ->
        assert System.monotonic_time(:millisecond) < deadline, "Live heartbeat observation timed out"

        receive do
        after
          50 -> await(fun, deadline)
        end

      result ->
        result
    end
  end

  defp report(label, observation), do: IO.inspect(observation, label: Atom.to_string(label), limit: :infinity)
end

HeartbeatProbe.run()
