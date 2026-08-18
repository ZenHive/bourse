defmodule Bourse.WS.ConnectionOwnerTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.ConnectionOwner
  alias ZenWebsocket.Client

  test "checkout after take refuses new hosts" do
    {:ok, pid} = Agent.start(fn -> :ok end)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    client = %Client{server_pid: pid, state: :connected, url: "wss://a.test"}
    {:ok, owner} = ConnectionOwner.start("wss://a.test", client)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)

    assert {:ok, [^client]} = ConnectionOwner.take(owner, 1_000)

    assert {:error, :connection_closed} =
             ConnectionOwner.checkout(
               owner,
               fn _url, _opts -> flunk("closed owner must not open a host") end,
               "wss://b.test",
               [],
               1_000
             )
  end

  test "killing the owner kills linked clients" do
    {:ok, pid} = Agent.start(fn -> :ok end)
    client = %Client{server_pid: pid, state: :connected, url: "wss://a.test"}
    {:ok, owner} = ConnectionOwner.start("wss://a.test", client)
    ref = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 200
  end

  test "a client exit is dropped and the owner stays up" do
    {:ok, pid} = Agent.start(fn -> :ok end)
    client = %Client{server_pid: pid, state: :connected, url: "wss://a.test"}
    {:ok, owner} = ConnectionOwner.start("wss://a.test", client)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    ref = Process.monitor(pid)

    Agent.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 200
    send(owner, :ignored)
    assert :sys.get_state(owner).connections == %{}
    assert :ok = ConnectionOwner.stop(owner, 1_000)
    assert :ok = ConnectionOwner.stop(owner, 1_000)
  end

  test "a client without a server pid still starts" do
    client = %Client{state: :disconnected}
    {:ok, owner} = ConnectionOwner.start("wss://a.test", client)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)

    assert {:ok, ^client} =
             ConnectionOwner.checkout(owner, fn _, _ -> flunk("already stored") end, "wss://a.test", [], 1_000)
  end
end
