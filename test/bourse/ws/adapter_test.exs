defmodule Bourse.WS.AdapterTest do
  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Adapter
  alias Bourse.WS.Broadcast
  alias Bourse.WS.MessageRouter
  alias ZenWebsocket.Client

  @moduletag trace_messages: 200

  defmodule Transport do
    @moduledoc false
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:send_message, payload}, _from, owner) do
      send(owner, {:transport_sent, payload})
      {:reply, :ok, owner}
    end

    def handle_call(:get_state, _from, owner), do: {:reply, :connected, owner}
  end

  setup do
    topic = Broadcast.topic("bybit", :watch_ticker, "tickers.BTCUSDT")
    Broadcast.subscribe(topic)
    on_exit(fn -> Broadcast.unsubscribe(topic) end)
    :ok
  end

  test "routes inbound frame and broadcasts to registry subscribers" do
    exchange = Exchange.new!("bybit")

    envelope = %{
      "discriminator_field" => "topic",
      "data_field" => "data",
      "match_type" => "exact_then_substring"
    }

    data = %{"lastPrice" => "42000"}
    msg = %{"topic" => "tickers.BTCUSDT", "data" => data}

    assert {:routed, :watch_ticker, ^data, "tickers.BTCUSDT"} =
             MessageRouter.route(msg, envelope, exchange)

    topic = Broadcast.topic("bybit", :watch_ticker, "tickers.BTCUSDT")

    Broadcast.broadcast(
      topic,
      {:bourse_ws, {:routed, :watch_ticker, data, "tickers.BTCUSDT", "BTCUSDT", nil}}
    )

    assert_receive {:bourse_ws, {:routed, :watch_ticker, ^data, "tickers.BTCUSDT", "BTCUSDT", nil}},
                   100
  end

  test "auth_state defaults to unauthenticated" do
    exchange = Exchange.new!("bybit")
    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false)

    on_exit(fn ->
      if Process.alive?(adapter) do
        GenServer.stop(adapter, :normal)
      end
    end)

    assert Adapter.auth_state(adapter) == :unauthenticated
  end

  test "reports disconnected state and rejects calls before a connection exists" do
    exchange = Exchange.new!("bybit")
    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    assert Adapter.connection_state(adapter) == :disconnected
    assert {:error, :not_connected} = Adapter.subscribe(adapter, ["tickers.BTCUSDT"])
    assert {:error, :not_connected} = Adapter.authenticate(adapter)
  end

  test "reports missing credentials after an injected connection is available" do
    exchange = Exchange.new!("bybit")
    ws = %WS{exchange: exchange, zen_client: %Client{state: :connected}, url: "wss://offline.test", section: :public}
    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false, ws: ws)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    assert {:error, :no_credentials} = Adapter.authenticate(adapter)
  end

  test "subscribes, authenticates, and routes semantics through an injected transport" do
    transport = start_supervised!({Transport, self()})
    client = %Client{server_pid: transport, state: :connected}
    exchange = Exchange.new!("bybit", api_key: "key", secret: "secret")
    ws = %WS{exchange: exchange, zen_client: client, url: "wss://offline.test", section: :public}

    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false, ws: ws)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    assert Adapter.connection_state(adapter) == :connected
    # Offline transport never emits an ack; skip the await window.
    assert :ok = Adapter.subscribe(adapter, ["tickers.BTCUSDT"], ack_timeout_ms: 0)
    assert_receive {:transport_sent, subscribe_payload}
    assert Jason.decode!(subscribe_payload)["op"] == "subscribe"

    # Auth completes on the venue's verdict, not on the send succeeding — so the
    # call is in flight until the ack frame arrives. Treating the send as
    # success is what left private connections unauthenticated and silent.
    auth = Task.async(fn -> Adapter.authenticate(adapter) end)
    assert_receive {:transport_sent, auth_payload}
    assert Jason.decode!(auth_payload)["op"] == "auth"

    send(adapter, {:ws_frame, %{"op" => "auth", "success" => true}})

    assert :ok = Task.await(auth)
    assert Adapter.auth_state(adapter) == :authenticated

    orderbook_topic = Broadcast.topic("bybit", :watch_order_book, "orderbook.500.BTCUSDT")
    Broadcast.subscribe(orderbook_topic)
    on_exit(fn -> Broadcast.unsubscribe(orderbook_topic) end)

    send(
      adapter,
      {:ws_frame, %{"topic" => "orderbook.500.BTCUSDT", "data" => %{"type" => "snapshot", "b" => [["1", "2"]]}}}
    )

    assert_receive {:bourse_ws, {:routed, :watch_order_book, _payload, "orderbook.500.BTCUSDT", "BTCUSDT", book}}
    assert book == %{"bids" => [["1", "2"]], "asks" => []}

    trades_topic = Broadcast.topic("bybit", :watch_trades, "publicTrade.BTCUSDT")
    ohlcv_topic = Broadcast.topic("bybit", :watch_ohlcv, "kline.BTCUSDT")
    Broadcast.subscribe(trades_topic)
    Broadcast.subscribe(ohlcv_topic)

    on_exit(fn ->
      Broadcast.unsubscribe(trades_topic)
      Broadcast.unsubscribe(ohlcv_topic)
    end)

    send(adapter, {:ws_frame, %{"topic" => "publicTrade.BTCUSDT", "data" => [%{"id" => "1"}]}})
    assert_receive {:bourse_ws, {:routed, :watch_trades, [%{"id" => "1"}], "publicTrade.BTCUSDT", "BTCUSDT", nil}}

    send(adapter, {:ws_frame, %{"topic" => "kline.BTCUSDT", "data" => [%{"open" => "1"}]}})
    assert_receive {:bourse_ws, {:routed, :watch_ohlcv, [%{"open" => "1"}], "kline.BTCUSDT", "BTCUSDT", nil}}

    # Re-auth on expiry runs the same handshake, so it needs the same verdict.
    # The frame can be queued while the adapter is already blocked waiting for
    # it — receive scans the mailbox.
    send(adapter, :auth_expired)
    send(adapter, {:ws_frame, %{"op" => "auth", "success" => true}})
    assert Adapter.auth_state(adapter) == :authenticated
  end

  test "returns an asynchronous venue rejection while subscribe is waiting" do
    transport = start_supervised!({Transport, self()})
    client = %Client{server_pid: transport, state: :connected}
    exchange = Exchange.new!("bybit")
    ws = %WS{exchange: exchange, zen_client: client, url: "wss://offline.test", section: :public}
    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false, ws: ws)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    subscribe = Task.async(fn -> Adapter.subscribe(adapter, ["not.a.real.channel"], ack_timeout_ms: 200) end)
    assert_receive {:transport_sent, _payload}

    rejection = %{"op" => "subscribe", "success" => false, "ret_msg" => "bad topic"}
    send(adapter, {:ws_frame, rejection})

    assert {:error, {:subscription_rejected, ^rejection}} = Task.await(subscribe)
    assert :sys.get_state(adapter).subscriptions == []
  end

  test "broadcasts system and unknown frames without changing adapter state" do
    exchange = Exchange.new!("bybit")
    system_topic = Broadcast.topic("bybit", :system, nil)
    raw_topic = Broadcast.topic("bybit", :raw, nil)
    Broadcast.subscribe(system_topic)
    Broadcast.subscribe(raw_topic)

    on_exit(fn ->
      Broadcast.unsubscribe(system_topic)
      Broadcast.unsubscribe(raw_topic)
    end)

    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    response = %{"id" => 1, "result" => %{"ok" => true}}
    send(adapter, {:ws_frame, response})
    assert_receive {:bourse_ws, {:system, ^response}}

    raw = %{"topic" => "unknown.channel"}
    send(adapter, {:ws_frame, raw})
    assert_receive {:bourse_ws, {:raw, ^raw}}
  end

  test "uses an injected connector and restores subscriptions deterministically" do
    exchange = Exchange.new!("bybit")
    ws = %WS{exchange: exchange, zen_client: %Client{state: :disconnected}, url: "wss://offline.test", section: :public}

    connector = fn _exchange, _section, opts ->
      send(self(), {:connector_opts, opts})
      {:ok, ws}
    end

    state = %Adapter{exchange: exchange, section: :public, subscriptions: [], connect_fun: connector}
    assert {:noreply, connected} = Adapter.handle_info(:connect, state)
    assert connected.ws == ws
    assert_receive :restore_subscriptions
    # The adapter opts out of the facade's connect-time handshake: it runs the
    # handshake itself so it can read the session TTL and schedule re-auth.
    assert_receive {:connector_opts, [handler: handler, authenticate: false]}

    assert {:ok, _pid} =
             Task.start(fn -> handler.({:message, %{"topic" => "tickers.BTCUSDT"}}) end)

    assert_receive {:ws_frame, %{"topic" => "tickers.BTCUSDT"}}

    assert {:ok, _pid} =
             Task.start(fn -> handler.({:binary, %{"topic" => "tickers.BTCUSDT"}}) end)

    assert_receive {:ws_frame, %{"topic" => "tickers.BTCUSDT"}}

    assert {:ok, _pid} =
             Task.start(fn -> handler.({:unmatched_response, %{"error" => %{"code" => -1}}}) end)

    assert_receive {:ws_frame, %{"error" => %{"code" => -1}}}
    assert :ok = handler.(:ignored)

    assert {:noreply, ^connected} = Adapter.handle_info(:restore_subscriptions, connected)

    restored = %{connected | subscriptions: ["tickers.BTCUSDT"]}
    assert {:noreply, ^restored} = Adapter.handle_info(:restore_subscriptions, restored)
  end

  test "handles named starts, already-authenticated calls, and ignored messages" do
    exchange = Exchange.new!("bybit")
    name = {:global, {:adapter_test, make_ref()}}
    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false, name: name)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    :sys.replace_state(adapter, &%{&1 | auth_state: :authenticated})
    assert :ok = Adapter.authenticate(adapter)
    send(adapter, :ignored)
    assert Adapter.auth_state(adapter) == :authenticated
  end

  test "initializes a connecting adapter without performing transport work" do
    exchange = Exchange.new!("bybit")
    assert {:ok, %Adapter{ws: nil}} = Adapter.init({exchange, :public, []})
    assert_receive :connect
  end
end
