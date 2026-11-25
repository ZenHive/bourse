defmodule Bourse.WS.AdapterRestoreLiveTest do
  @moduledoc """
  Provider-live subscription restore across an adapter redial.

  Hyperliquid testnet accepts one channel map per subscribe call, so two
  separate `Adapter.subscribe/3` calls must come back as two calls on the new
  connection. Both feeds are observed on the replacement socket.
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Adapter

  @moduletag :network
  @moduletag :integration
  @moduletag :exchange_hyperliquid
  @moduletag timeout: 120_000

  @frame_timeout 30_000
  @channels [%{"type" => "l2Book", "coin" => "BTC"}, %{"type" => "trades", "coin" => "BTC"}]

  test "two separate subscriptions both deliver again after the transport is lost" do
    test_pid = self()

    connect_fun = fn exchange, section, opts ->
      generation = System.unique_integer([:positive])
      handler = Keyword.fetch!(opts, :handler)

      tagged = fn
        {:message, %{"channel" => channel}} = message ->
          send(test_pid, {:frame, generation, channel})
          handler.(message)

        message ->
          handler.(message)
      end

      with {:ok, ws} <- WS.connect(exchange, section, Keyword.put(opts, :handler, tagged)) do
        send(test_pid, {:up, generation, ws})
        {:ok, ws}
      end
    end

    {:ok, adapter} = Adapter.start_link(Exchange.new!("hyperliquid", sandbox: true), :public, connect_fun: connect_fun)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)

    assert_receive {:up, first, ws}, @frame_timeout

    # Merged into one call, the venue's subscribe is refused — which is why the
    # adapter replays each accepted call on its own.
    assert WS.subscribe(ws, @channels) == {:error, :multiple_maps_not_supported}

    for %{"type" => type} = channel <- @channels do
      assert :ok = Adapter.subscribe(adapter, [channel])
      assert_receive {:frame, ^first, ^type}, @frame_timeout
    end

    server = ws.zen_client.server_pid
    send(server, {:gun_down, :sys.get_state(server).gun_pid, :http, :closed, []})

    assert_receive {:up, second, replacement}, @frame_timeout
    refute second == first
    refute Process.alive?(server)

    for %{"type" => type} <- @channels do
      assert_receive {:frame, ^second, ^type}, @frame_timeout
    end

    assert WS.get_state(replacement) == :connected
    assert :sys.get_state(adapter).restore_attempts == 0
  end
end
