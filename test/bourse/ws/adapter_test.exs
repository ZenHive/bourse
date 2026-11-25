defmodule Bourse.WS.AdapterTest do
  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Adapter
  alias Bourse.WS.Broadcast
  alias Bourse.WS.MessageRouter
  alias Bourse.WS.Semantics.Orderbook
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

  # Answers every subscribe with the venue's ack through the connection's own
  # handler, the way a live socket delivers it.
  defmodule AckingTransport do
    @moduledoc false
    use GenServer

    @impl true
    def init({owner, handler}), do: {:ok, {owner, handler}}

    @impl true
    def handle_call({:send_message, payload}, _from, {owner, handler} = state) do
      send(owner, {:transport_sent, self(), Jason.decode!(payload)})
      if Jason.decode!(payload)["op"] == "subscribe", do: handler.({:message, %{"op" => "subscribe", "success" => true}})
      {:reply, :ok, state}
    end

    def handle_call(:get_state, _from, state), do: {:reply, :connected, state}
  end

  defmodule GatedTransport do
    @moduledoc false
    # Acks a subscribe unless the shared gate is closed, and reports each one.
    use GenServer

    @impl true
    def init({owner, handler, gate}), do: {:ok, {owner, handler, gate}}

    @impl true
    def handle_call({:send_message, payload}, _from, {owner, handler, gate} = state) do
      message = Jason.decode!(payload)
      accepted = :atomics.get(gate, 1) == 0
      send(owner, {:transport_sent, self(), message, accepted})

      # 2 leaves the subscribe unanswered; 3 refuses it as already subscribed.
      case {message["op"], :atomics.get(gate, 1)} do
        {"subscribe", 2} ->
          :ok

        {"subscribe", 3} ->
          ret_msg = "error:already subscribed,topic:" <> Enum.join(message["args"], ",")
          handler.({:message, %{"op" => "subscribe", "success" => false, "ret_msg" => ret_msg}})

        {"subscribe", _} ->
          handler.({:message, %{"op" => "subscribe", "success" => accepted, "ret_msg" => "probe"}})

        _ ->
          :ok
      end

      {:reply, :ok, state}
    end

    def handle_call(:get_state, _from, state), do: {:reply, :connected, state}
  end

  defmodule ScriptedTransport do
    @moduledoc false
    # Answers each frame with the replies `script.(epoch, message)` returns,
    # as `{delay_ms, frame}`, and reports every frame sent.
    use GenServer

    @impl true
    def init({owner, handler, epoch, script}), do: {:ok, {owner, handler, epoch, script}}

    @impl true
    def handle_call({:send_message, payload}, _from, {owner, handler, epoch, script} = state) do
      message = Jason.decode!(payload)
      send(owner, {:sent, epoch, message})

      Enum.each(script.(epoch, message), &deliver(handler, &1))
      {:reply, :ok, state}
    end

    def handle_call(:get_state, _from, state), do: {:reply, :connected, state}

    defp deliver(handler, {0, frame}), do: handler.({:message, frame})
    defp deliver(handler, {delay, frame}), do: spawn(fn -> Process.sleep(delay) && handler.({:message, frame}) end)
  end

  # Starts an adapter whose every connection is a ScriptedTransport numbered
  # from 1, and returns it with that connection's pid lookup.
  defp scripted_adapter(venue, script) do
    test_pid = self()
    epochs = :atomics.new(1, [])

    zen_connect = fn url, opts ->
      epoch = :atomics.add_get(epochs, 1, 1)
      {:ok, pid} = GenServer.start(ScriptedTransport, {test_pid, Keyword.fetch!(opts, :handler), epoch, script})
      send(test_pid, {:connected, epoch, pid})
      {:ok, %Client{server_pid: pid, state: :connected, url: url}}
    end

    connect_fun = fn ex, section, opts -> WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect)) end
    {:ok, adapter} = Adapter.start_link(Exchange.new!(venue), :public, connect_fun: connect_fun)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)
    _ = :sys.get_state(adapter)
    adapter
  end

  defp drop_connection(epoch) do
    assert_receive {:connected, ^epoch, pid}
    ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(pid, {:shutdown, :closed}) end)
  end

  defp sent(epoch, acc, window_ms) do
    receive do
      {:sent, ^epoch, message} -> sent(epoch, acc ++ [message], window_ms)
    after
      window_ms -> acc
    end
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
      {:ws_frame,
       %{
         "topic" => "orderbook.500.BTCUSDT",
         "type" => "snapshot",
         "data" => %{"s" => "BTCUSDT", "u" => 1, "b" => [["1", "2"]]}
       }}
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

  test "routes a Binance spot partial-book snapshot onto watch_order_book" do
    exchange = Exchange.new!("binance")
    book_topic = Broadcast.topic("binance", :watch_order_book, nil)
    raw_topic = Broadcast.topic("binance", :raw, nil)
    Broadcast.subscribe(book_topic)
    Broadcast.subscribe(raw_topic)

    on_exit(fn ->
      Broadcast.unsubscribe(book_topic)
      Broadcast.unsubscribe(raw_topic)
    end)

    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    payload = %{"lastUpdateId" => 160, "bids" => [["1", "2"]], "asks" => [["3", "4"]]}
    send(adapter, {:ws_frame, payload})

    assert_receive {:bourse_ws, {:routed, :watch_order_book, ^payload, "depthUpdate", _market, _book}}
    refute_received {:bourse_ws, {:raw, _}}
  end

  test "routes a USD-M depthUpdate frame onto watch_order_book" do
    exchange = Exchange.new!("binanceusdm")
    book_topic = Broadcast.topic("binanceusdm", :watch_order_book, nil)
    Broadcast.subscribe(book_topic)
    on_exit(fn -> Broadcast.unsubscribe(book_topic) end)

    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    payload = %{"e" => "depthUpdate", "s" => "BTCUSDT", "b" => [["42000", "1"]], "a" => [["42001", "1"]]}
    send(adapter, {:ws_frame, payload})

    assert_receive {:bourse_ws, {:routed, :watch_order_book, ^payload, "depthUpdate", _market, _book}}
  end

  test "does not treat a Binance subscribe-ack as a routed book" do
    exchange = Exchange.new!("binance")
    book_topic = Broadcast.topic("binance", :watch_order_book, nil)
    system_topic = Broadcast.topic("binance", :system, nil)
    Broadcast.subscribe(book_topic)
    Broadcast.subscribe(system_topic)

    on_exit(fn ->
      Broadcast.unsubscribe(book_topic)
      Broadcast.unsubscribe(system_topic)
    end)

    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    ack = %{"id" => 1, "result" => nil}
    send(adapter, {:ws_frame, ack})

    assert_receive {:bourse_ws, {:system, ^ack}}
    refute_received {:bourse_ws, {:routed, :watch_order_book, _, _, _, _}}
  end

  test "routes Coinbase match onto watch_trades and last_match/heartbeat onto system" do
    exchange = Exchange.new!("coinbaseexchange")
    trades_topic = Broadcast.topic("coinbaseexchange", :watch_trades, nil)
    system_topic = Broadcast.topic("coinbaseexchange", :system, nil)
    Broadcast.subscribe(trades_topic)
    Broadcast.subscribe(system_topic)

    on_exit(fn ->
      Broadcast.unsubscribe(trades_topic)
      Broadcast.unsubscribe(system_topic)
    end)

    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    match = %{
      "type" => "match",
      "trade_id" => 842_900_891,
      "product_id" => "ETH-USD",
      "side" => "sell",
      "price" => "2497.81",
      "size" => "0.721",
      "time" => "2026-09-15T06:09:40.530674Z"
    }

    last_match = %{match | "type" => "last_match", "trade_id" => 842_900_890}

    heartbeat = %{
      "type" => "heartbeat",
      "last_trade_id" => 842_900_890,
      "sequence" => 102_860_075_212,
      "product_id" => "ETH-USD",
      "time" => "2026-09-15T06:09:40.000000Z"
    }

    subscriptions = %{"type" => "subscriptions", "channels" => []}

    send(adapter, {:ws_frame, subscriptions})
    assert_receive {:bourse_ws, {:system, ^subscriptions}}

    send(adapter, {:ws_frame, last_match})
    assert_receive {:bourse_ws, {:system, ^last_match}}

    send(adapter, {:ws_frame, heartbeat})
    assert_receive {:bourse_ws, {:system, ^heartbeat}}
    assert heartbeat["last_trade_id"] == last_match["trade_id"]

    send(adapter, {:ws_frame, match})

    assert_receive {:bourse_ws, {:routed, :watch_trades, ^match, "match", _market, nil}}

    refute_received {:bourse_ws, {:routed, :watch_trades, ^last_match, _, _, _}}
    refute_received {:bourse_ws, {:routed, :watch_trades, ^heartbeat, _, _, _}}
    refute_received {:bourse_ws, {:routed, :watch_trades, ^subscriptions, _, _, _}}
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
    assert_receive {:restore_subscriptions, _}
    # The facade authenticates the private section and records the outcome on
    # the connection, so the adapter no longer opts out and re-runs it.
    assert_receive {:connector_opts, [handler: handler, reconnect_on_error: false]}
    ref = connected.connection_ref
    assert is_reference(ref)

    assert {:ok, _pid} =
             Task.start(fn -> handler.({:message, %{"topic" => "tickers.BTCUSDT"}}) end)

    assert_receive {:ws_frame, ^ref, %{"topic" => "tickers.BTCUSDT"}}

    assert {:ok, _pid} =
             Task.start(fn -> handler.({:binary, %{"topic" => "tickers.BTCUSDT"}}) end)

    assert_receive {:ws_frame, ^ref, %{"topic" => "tickers.BTCUSDT"}}

    assert {:ok, _pid} =
             Task.start(fn -> handler.({:unmatched_response, %{"error" => %{"code" => -1}}}) end)

    assert_receive {:ws_frame, ^ref, %{"error" => %{"code" => -1}}}
    assert :ok = handler.(:ignored)

    # A frame still queued from a replaced connection is not routed.
    assert {:noreply, ^connected} =
             Adapter.handle_info({:ws_frame, make_ref(), %{"topic" => "tickers.BTCUSDT"}}, connected)

    assert {:noreply, ^connected} = Adapter.handle_info(:restore_subscriptions, connected)

    # A restore queued for a replaced connection does nothing.
    restored = %{connected | subscriptions: [{["tickers.BTCUSDT"], []}]}
    assert {:noreply, ^restored} = Adapter.handle_info({:restore_subscriptions, make_ref()}, restored)
  end

  test "adopts a listen-key connection and arms the refresh the venue requires" do
    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret")

    session = %{
      listen_key: "issued-key",
      market_type: :linear,
      keepalive_endpoint: :fapiPrivate_put_listenkey,
      keepalive_ms: 40
    }

    ws = %WS{
      exchange: exchange,
      zen_client: %Client{state: :connected},
      url: "wss://offline.test/ws/issued-key",
      section: :private,
      auth: %{pattern: :listen_key, meta: session}
    }

    state = %Adapter{
      exchange: exchange,
      section: :private,
      subscriptions: [],
      connect_fun: fn _exchange, _section, _opts -> {:ok, ws} end
    }

    assert {:noreply, connected} = Adapter.handle_info(:connect, state)

    # The facade already authenticated; re-running the handshake would issue a
    # second key this socket could not adopt.
    assert connected.auth_state == :authenticated
    assert connected.auth_context == %{pattern: :listen_key}
    assert is_reference(connected.auth_timer_ref)

    # The authored interval is used as authored — it is already the safe
    # interval below the venue's 60-minute expiry, not a TTL to discount again.
    assert_receive :auth_expired, 500
  end

  test "reports a refresh the venue cannot serve instead of leaving the stream silently dead" do
    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret")

    ws = %WS{
      exchange: exchange,
      zen_client: %Client{state: :connected},
      url: "wss://offline.test/ws/issued-key",
      section: :private,
      auth: %{pattern: :listen_key, meta: %{keepalive_endpoint: :not_a_real_endpoint}}
    }

    state = %Adapter{
      exchange: exchange,
      section: :private,
      ws: ws,
      auth_state: :authenticated,
      auth_context: %{pattern: :listen_key}
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:noreply, expired} = Adapter.handle_info(:auth_expired, state)
        assert expired.auth_state == :expired
      end)

    assert log =~ "auth renewal failed"
    assert log =~ "unknown_listen_key_endpoint"
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

  test "repeated reconnects close the previous owner so the process count stays at one" do
    exchange = Exchange.new!("bybit")

    zen_connect = fn url, _opts ->
      {:ok, pid} = Agent.start(fn -> :ok end)
      {:ok, %Client{server_pid: pid, state: :connected, url: url}}
    end

    connect_fun = fn ex, section, opts ->
      WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect))
    end

    state = %Adapter{exchange: exchange, section: :public, subscriptions: [], connect_fun: connect_fun}
    assert {:noreply, connected} = Adapter.handle_info(:connect, state)
    assert_receive {:restore_subscriptions, _}
    first_owner = connected.ws.connection_owner
    assert Process.alive?(first_owner)

    final =
      Enum.reduce(1..5, connected, fn _n, previous ->
        assert {:noreply, next} = Adapter.handle_info(:connect, previous)
        assert_receive {:restore_subscriptions, _}
        refute Process.alive?(previous.ws.connection_owner)
        assert Process.alive?(next.ws.connection_owner)
        next
      end)

    assert Process.alive?(final.ws.connection_owner)
    refute Process.alive?(first_owner)
    assert Enum.count([first_owner, final.ws.connection_owner], &Process.alive?/1) == 1

    final_owner = final.ws.connection_owner
    assert WS.transport_pids(final.ws) == [final.ws.zen_client.server_pid]
    assert :ok = WS.close(final.ws)
    refute Process.alive?(final_owner)
    # A closed connection owns no transport.
    assert WS.transport_pids(final.ws) == []
    assert WS.transport_pids(%{final.ws | connection_owner: nil}) == []
  end

  test "a lost transport invalidates every book and reconnects with a fresh connection and its subscriptions" do
    test_pid = self()
    exchange = Exchange.new!("bybit")
    channel = "orderbook.50.BTCUSDT"
    Broadcast.subscribe(Broadcast.topic("bybit", :watch_order_book, nil))

    zen_connect = fn url, opts ->
      send(test_pid, {:zen_opts, opts})
      {:ok, pid} = GenServer.start(AckingTransport, {test_pid, Keyword.fetch!(opts, :handler)})
      {:ok, %Client{server_pid: pid, state: :connected, url: url}}
    end

    connect_fun = fn ex, section, opts -> WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect)) end
    {:ok, adapter} = Adapter.start_link(exchange, :public, connect_fun: connect_fun)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    # The transport must not redial underneath the adapter.
    assert_receive {:zen_opts, opts}
    assert opts[:reconnect_on_error] == false
    # Lets the adapter finish adopting the connection (and its empty restore).
    _ = :sys.get_state(adapter)

    assert :ok = Adapter.subscribe(adapter, [channel])
    assert_receive {:transport_sent, first_transport, %{"op" => "subscribe", "args" => [^channel]}}

    first = :sys.get_state(adapter)

    snapshot = fn u ->
      %{"topic" => channel, "type" => "snapshot", "data" => %{"s" => "BTCUSDT", "u" => u, "b" => [["1", "2"]]}}
    end

    delta = fn u ->
      %{"topic" => channel, "type" => "delta", "data" => %{"s" => "BTCUSDT", "u" => u, "b" => [["1", "3"]]}}
    end

    send(adapter, {:ws_frame, first.connection_ref, snapshot.(7)})
    assert_receive {:bourse_ws, {:routed, :watch_order_book, _, ^channel, _, %{"bids" => [["1", "2"]]}}}

    GenServer.stop(first_transport, {:shutdown, :closed})

    assert_receive {:bourse_ws, {:order_book_invalidated, ^channel, "BTCUSDT", {:connection_lost, {:shutdown, :closed}}}}
    assert_receive {:zen_opts, _opts}
    assert_receive {:transport_sent, second_transport, %{"op" => "subscribe", "args" => [^channel]}}
    refute second_transport == first_transport

    second = :sys.get_state(adapter)
    refute second.connection_ref == first.connection_ref
    assert second.orderbook.books == %{}

    # A frame still queued from the lost connection is not applied, and a delta
    # on the new one does not continue the old book.
    send(adapter, {:ws_frame, first.connection_ref, delta.(8)})
    send(adapter, {:ws_frame, second.connection_ref, delta.(8)})
    assert_receive {:bourse_ws, {:routed, :watch_order_book, %{"u" => 8}, ^channel, _, nil}}
    refute_receive {:bourse_ws, {:routed, :watch_order_book, _, _, _, _}}, 50

    send(adapter, {:ws_frame, second.connection_ref, snapshot.(20)})
    assert_receive {:bourse_ws, {:routed, :watch_order_book, %{"u" => 20}, ^channel, _, %{"bids" => [["1", "2"]]}}}

    # The new transport is watched as well. It was short-lived, so the next
    # dial waits.
    GenServer.stop(second_transport, {:shutdown, :closed})
    assert_receive {:bourse_ws, {:order_book_invalidated, ^channel, "BTCUSDT", {:connection_lost, _}}}
    refute_receive {:transport_sent, _, %{"op" => "subscribe"}}, 300
    assert_receive {:transport_sent, third_transport, %{"op" => "subscribe"}}, 1_000
    refute third_transport in [first_transport, second_transport]
  end

  test "an invalidation names the instrument of the book that broke, per instrument on one socket" do
    exchange = Exchange.new!("okx")
    state = %Adapter{exchange: exchange, orderbook: Orderbook.new(exchange)}
    Broadcast.subscribe(Broadcast.topic("okx", :watch_order_book, nil))

    frame = fn market, action, current, previous ->
      %{
        "arg" => %{"channel" => "books", "instId" => market},
        "action" => action,
        "data" => [%{"seqId" => current, "prevSeqId" => previous, "bids" => [["1", "1", "0", "1"]], "asks" => []}]
      }
    end

    state =
      Enum.reduce(["BTC-USDT", "ETH-USDT"], state, fn market, st ->
        {:noreply, st} = Adapter.handle_info({:ws_frame, frame.(market, "snapshot", 42, -1)}, st)
        st
      end)

    ExUnit.CaptureLog.capture_log(fn ->
      {:noreply, _} = Adapter.handle_info({:ws_frame, frame.("ETH-USDT", "update", 50, 49)}, state)
    end)

    assert_receive {:bourse_ws, {:order_book_invalidated, "books", "ETH-USDT", {:expected_previous, 42, 49}}}
    refute_receive {:bourse_ws, {:order_book_invalidated, _, "BTC-USDT", _}}, 50
  end

  test "an unusable or failed REST snapshot is retried after a pause, one attempt per book" do
    exchange = Exchange.new!("binance", sandbox: true)
    key = "BTCUSDT"
    {ob, {:fetch_snapshot, ^key}} = Orderbook.apply(Orderbook.new(exchange), key, %{"U" => 100, "u" => 105})

    for result <- [{:ok, %{status: 200, body: %{"lastUpdateId" => 9, "bids" => [], "asks" => []}}}, {:error, :timeout}] do
      ref = make_ref()
      state = %Adapter{exchange: exchange, orderbook: Orderbook.fetch_started(ob, key, ref)}

      {{:noreply, state}, log} =
        ExUnit.CaptureLog.with_log(fn -> Adapter.handle_info({:order_book_snapshot, key, ref, result}, state) end)

      assert log =~ "retrying in 1000ms"

      # Neither the result nor a further resync request starts a fetch now.
      assert {:noreply, ^state} = Adapter.handle_info({:order_book_resync, key, state.connection_ref}, state)
      refute_receive {:order_book_snapshot, ^key, _, _}, 500

      assert_receive {:order_book_fetch_retry, ^key, token}, 1_000
      assert Orderbook.fetch_in_flight?(state.orderbook, key, token)

      # A retry the book no longer waits for is ignored.
      assert {:noreply, ^state} = Adapter.handle_info({:order_book_fetch_retry, key, make_ref()}, state)
    end
  end

  describe "order book recovery" do
    setup do
      test_pid = self()
      Broadcast.subscribe(Broadcast.topic("bybit", :watch_order_book, nil))
      on_exit(fn -> Broadcast.unsubscribe(Broadcast.topic("bybit", :watch_order_book, nil)) end)

      zen_connect = fn url, opts ->
        {:ok, pid} = GenServer.start(AckingTransport, {test_pid, Keyword.fetch!(opts, :handler)})
        {:ok, %Client{server_pid: pid, state: :connected, url: url}}
      end

      connect_fun = fn ex, section, opts -> WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect)) end
      {:ok, adapter} = Adapter.start_link(Exchange.new!("bybit"), :public, connect_fun: connect_fun)
      on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)
      _ = :sys.get_state(adapter)
      %{adapter: adapter}
    end

    test "a resync runs only for the connection and the book that asked for it", %{adapter: adapter} do
      channel = "orderbook.50.BTCUSDT"
      assert :ok = Adapter.subscribe(adapter, [channel])
      assert_receive {:transport_sent, _, %{"op" => "subscribe"}}
      ref = :sys.get_state(adapter).connection_ref

      # From a connection that is gone: nothing is sent on this one.
      send(adapter, {:order_book_resync, channel, make_ref()})
      _ = :sys.get_state(adapter)
      refute_received {:transport_sent, _, _}

      # For a book that is live again: nothing is sent either.
      snapshot = %{"topic" => channel, "type" => "snapshot", "data" => %{"s" => "BTCUSDT", "u" => 7, "b" => [["1", "2"]]}}
      send(adapter, {:ws_frame, ref, snapshot})
      assert_receive {:bourse_ws, {:routed, :watch_order_book, _, ^channel, _, %{}}}
      send(adapter, {:order_book_resync, channel, ref})
      _ = :sys.get_state(adapter)
      refute_received {:transport_sent, _, _}

      # A broken book on the current connection is resubscribed.
      gap = %{"topic" => channel, "type" => "delta", "data" => %{"s" => "BTCUSDT", "u" => 9, "b" => []}}

      ExUnit.CaptureLog.capture_log(fn ->
        send(adapter, {:ws_frame, ref, %{gap | "data" => Map.put(gap["data"], "u", 7)}})
        _ = :sys.get_state(adapter)
      end)

      assert_receive {:bourse_ws, {:order_book_invalidated, ^channel, "BTCUSDT", _}}
      assert_receive {:transport_sent, _, %{"op" => "unsubscribe", "args" => [^channel]}}
      assert_receive {:transport_sent, _, %{"op" => "subscribe", "args" => [^channel]}}
    end
  end

  test "a single partial-depth book names its instrument; a second partial retires it" do
    exchange = Exchange.new!("binance")
    Broadcast.subscribe(Broadcast.topic("binance", :watch_order_book, nil))
    on_exit(fn -> Broadcast.unsubscribe(Broadcast.topic("binance", :watch_order_book, nil)) end)

    zen_connect = fn url, _opts ->
      {:ok, pid} = Transport.start_link(self())
      {:ok, %Client{server_pid: pid, state: :connected, url: url}}
    end

    connect_fun = fn ex, section, opts -> WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect)) end
    {:ok, adapter} = Adapter.start_link(exchange, :public, connect_fun: connect_fun)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)
    _ = :sys.get_state(adapter)

    assert :ok = Adapter.subscribe(adapter, ["btcusdt@depth20"], ack_timeout_ms: 0)
    ref = :sys.get_state(adapter).connection_ref
    partial = %{"lastUpdateId" => 5, "bids" => [["1", "2"]], "asks" => []}
    send(adapter, {:ws_frame, ref, partial})
    assert_receive {:bourse_ws, {:routed, :watch_order_book, ^partial, "depthUpdate", "BTCUSDT", %{}}}

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok = Adapter.subscribe(adapter, ["ethusdt@depth20"], ack_timeout_ms: 0)
    end)

    assert_receive {:bourse_ws, {:order_book_invalidated, "depthUpdate", "BTCUSDT", :ambiguous_depth_streams}}
  end

  test "an owner crash is visible to the adapter" do
    exchange = Exchange.new!("bybit")

    zen_connect = fn url, _opts ->
      {:ok, pid} = Agent.start(fn -> :ok end)
      {:ok, %Client{server_pid: pid, state: :connected, url: url}}
    end

    connect_fun = fn ex, section, opts ->
      WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect))
    end

    Process.flag(:trap_exit, true)
    {:ok, adapter} = Adapter.start_link(exchange, :public, connect: false, connect_fun: connect_fun)

    send(adapter, :connect)
    owner = :sys.get_state(adapter).ws.connection_owner
    Process.exit(owner, :kill)
    assert_receive {:EXIT, ^adapter, :killed}
    refute Process.alive?(owner)
  end

  describe "transport loss" do
    test "a transport that dies as soon as it opens is redialed with growing pauses" do
      test_pid = self()

      connect_fun = fn ex, section, _opts ->
        send(test_pid, {:dial, System.monotonic_time(:millisecond)})
        dead = spawn(fn -> :ok end)
        {:ok, %WS{exchange: ex, section: section, url: "wss://offline.test", zen_client: %Client{server_pid: dead}}}
      end

      {:ok, adapter} = Adapter.start_link(Exchange.new!("deribit"), :public, connect_fun: connect_fun)
      on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)

      dials = collect_dials([], 1_800)
      gaps = dials |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

      # 0, 500 and 1000 ms: three or four dials in 1.8 s, not a tight loop.
      assert length(dials) in 3..4, "dials at #{inspect(dials)}"
      assert Enum.all?(Enum.drop(gaps, 1), &(&1 >= 450)), "gaps #{inspect(gaps)}"
    end

    test "a failed replacement leaves no connection or authentication behind" do
      test_pid = self()
      exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret")
      dials = :atomics.new(1, [])
      listen_key_session = %{keepalive_endpoint: :fapiPrivate_put_listenkey, keepalive_ms: 60_000}

      connect_fun = fn ex, section, _opts ->
        if :atomics.add_get(dials, 1, 1) == 1 do
          {:ok, transport} = Agent.start(fn -> :ok end)
          {:ok, owner} = Agent.start(fn -> :ok end)
          send(test_pid, {:transport, transport, owner})

          {:ok,
           %WS{
             exchange: ex,
             section: section,
             url: "wss://offline.test/ws/issued-key",
             zen_client: %Client{server_pid: transport, state: :connected},
             auth: %{pattern: :listen_key, meta: listen_key_session}
           }}
        else
          {:error, :refused}
        end
      end

      {:ok, adapter} = Adapter.start_link(exchange, :private, connect_fun: connect_fun)
      on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)

      assert_receive {:transport, transport, _owner}
      assert Adapter.auth_state(adapter) == :authenticated
      timer = :sys.get_state(adapter).auth_timer_ref
      assert is_reference(timer)

      ExUnit.CaptureLog.capture_log(fn ->
        Agent.stop(transport)
        # The redial fails; the state the adapter keeps is what it reports.
        Process.sleep(100)
        state = :sys.get_state(adapter)

        assert state.ws == nil
        assert state.auth_context == nil
        assert state.auth_timer_ref == nil
        assert Process.read_timer(timer) == false
        assert state.monitors == %{}
        assert :atomics.get(dials, 1) == 2
      end)

      assert Adapter.connection_state(adapter) == :disconnected
      assert Adapter.auth_state(adapter) == :unauthenticated
      assert Adapter.authenticate(adapter) == {:error, :not_connected}
    end

    test "losing a routed socket closes the primary one too" do
      test_pid = self()

      zen_connect = fn url, opts ->
        {:ok, pid} = GenServer.start(AckingTransport, {test_pid, Keyword.fetch!(opts, :handler)})
        send(test_pid, {:transport_up, url, pid})
        {:ok, %Client{server_pid: pid, state: :connected, url: url}}
      end

      dials = :atomics.new(1, [])

      connect_fun = fn ex, section, opts ->
        if :atomics.add_get(dials, 1, 1) == 1,
          do: WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect)),
          else: {:error, :refused}
      end

      {:ok, adapter} = Adapter.start_link(Exchange.new!("binanceusdm"), :public, connect_fun: connect_fun)
      on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)

      assert_receive {:transport_up, primary_url, primary}
      _ = :sys.get_state(adapter)
      owner = :sys.get_state(adapter).ws.connection_owner

      # ticker is routed to the market host on USDⓈ-M.
      assert :ok = Adapter.subscribe(adapter, ["btcusdt@ticker"], ack_timeout_ms: 0)
      assert_receive {:transport_up, routed_url, routed}
      refute routed_url == primary_url

      ExUnit.CaptureLog.capture_log(fn ->
        GenServer.stop(routed, {:shutdown, :closed})
        Process.sleep(100)
      end)

      refute Process.alive?(primary)
      refute Process.alive?(owner)
      assert Adapter.connection_state(adapter) == :disconnected
    end
  end

  describe "subscription restore" do
    test "each accepted call is replayed on its own, with its own options" do
      test_pid = self()
      gate = :atomics.new(1, [])

      zen_connect = fn url, opts ->
        {:ok, pid} = GenServer.start(GatedTransport, {test_pid, Keyword.fetch!(opts, :handler), gate})
        {:ok, %Client{server_pid: pid, state: :connected, url: url}}
      end

      connect_fun = fn ex, section, opts -> WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect)) end
      {:ok, adapter} = Adapter.start_link(Exchange.new!("bybit"), :public, connect_fun: connect_fun)
      on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)
      _ = :sys.get_state(adapter)

      assert :ok = Adapter.subscribe(adapter, ["orderbook.50.BTCUSDT"])
      assert :ok = Adapter.subscribe(adapter, ["publicTrade.BTCUSDT"], ack_timeout_ms: 4_000)
      assert_receive {:transport_sent, first, %{"args" => ["orderbook.50.BTCUSDT"]}, true}
      assert_receive {:transport_sent, ^first, %{"args" => ["publicTrade.BTCUSDT"]}, true}

      assert :sys.get_state(adapter).subscriptions == [
               {["orderbook.50.BTCUSDT"], []},
               {["publicTrade.BTCUSDT"], [ack_timeout_ms: 4_000]}
             ]

      ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(first, {:shutdown, :closed}) end)

      assert_receive {:transport_sent, second, %{"args" => ["orderbook.50.BTCUSDT"]}, true}, 1_000
      assert_receive {:transport_sent, ^second, %{"args" => ["publicTrade.BTCUSDT"]}, true}, 1_000
      refute second == first
    end

    test "a call the new connection refuses is logged and retried until it is accepted" do
      test_pid = self()
      gate = :atomics.new(1, [])

      zen_connect = fn url, opts ->
        {:ok, pid} = GenServer.start(GatedTransport, {test_pid, Keyword.fetch!(opts, :handler), gate})
        {:ok, %Client{server_pid: pid, state: :connected, url: url}}
      end

      connect_fun = fn ex, section, opts -> WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect)) end
      {:ok, adapter} = Adapter.start_link(Exchange.new!("bybit"), :public, connect_fun: connect_fun)
      on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)
      _ = :sys.get_state(adapter)

      assert :ok = Adapter.subscribe(adapter, ["publicTrade.BTCUSDT"])
      assert_receive {:transport_sent, first, %{"op" => "subscribe"}, true}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(gate, 1, 1)
          GenServer.stop(first, {:shutdown, :closed})
          assert_receive {:transport_sent, second, %{"args" => ["publicTrade.BTCUSDT"]}, false}, 1_000

          :atomics.put(gate, 1, 0)
          assert_receive {:transport_sent, ^second, %{"args" => ["publicTrade.BTCUSDT"]}, true}, 2_000
          _ = :sys.get_state(adapter)
        end)

      assert log =~ "could not restore"
      assert :sys.get_state(adapter).restore_attempts == 0
    end

    # The unanswered subscribe either never reached the venue (the retry is
    # accepted) or was accepted with its ack lost (the retry is refused as
    # already subscribed). Both restore the group without further attempts.
    for {retry_gate, outcome} <- [{0, "accepted"}, {3, "refused as already subscribed"}] do
      test "a restore whose ack never arrived is restored when its retry is #{outcome}" do
        retry_gate = unquote(retry_gate)
        test_pid = self()
        gate = :atomics.new(1, [])

        zen_connect = fn url, opts ->
          {:ok, pid} = GenServer.start(GatedTransport, {test_pid, Keyword.fetch!(opts, :handler), gate})
          {:ok, %Client{server_pid: pid, state: :connected, url: url}}
        end

        connect_fun = fn ex, section, opts -> WS.connect(ex, section, Keyword.put(opts, :connect_fun, zen_connect)) end
        {:ok, adapter} = Adapter.start_link(Exchange.new!("bybit"), :public, connect_fun: connect_fun)
        on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)
        _ = :sys.get_state(adapter)

        assert :ok = Adapter.subscribe(adapter, ["publicTrade.BTCUSDT"], ack_timeout_ms: 100)
        assert_receive {:transport_sent, first, %{"op" => "subscribe"}, true}

        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(gate, 1, 2)
          GenServer.stop(first, {:shutdown, :closed})
          assert_receive {:transport_sent, second, %{"op" => "subscribe"}, false}, 1_000
          :atomics.put(gate, 1, retry_gate)
          assert_receive {:transport_sent, ^second, %{"op" => "subscribe", "args" => ["publicTrade.BTCUSDT"]}, _}, 2_000
          _ = :sys.get_state(adapter)
        end)

        assert :sys.get_state(adapter).restore_attempts == 0
        refute_receive {:transport_sent, _, _, _}, 2_500
      end
    end

    # Hyperliquid's acceptance echoes the subscription it accepted. Here the
    # trades ack arrives late, while the book's restore is waiting for its own
    # answer, which is a refusal.
    test "a late acceptance of one group is not taken for another group's" do
      hl_accept = fn sub ->
        %{"channel" => "subscriptionResponse", "data" => %{"method" => "subscribe", "subscription" => sub}}
      end

      book_sends = :atomics.new(2, [])

      script = fn
        1, %{"method" => "subscribe", "subscription" => sub} ->
          [{0, hl_accept.(sub)}]

        2, %{"method" => "subscribe", "subscription" => %{"type" => "trades"} = sub} ->
          if :atomics.add_get(book_sends, 2, 1) == 1,
            do: [{200, hl_accept.(sub)}],
            else: [{0, %{"channel" => "error", "data" => ~s(Already subscribed: {"type":"trades","coin":"BTC"})}}]

        2, %{"method" => "subscribe", "subscription" => %{"type" => "l2Book"} = sub} ->
          if :atomics.add_get(book_sends, 1, 1) == 1,
            do: [{400, %{"channel" => "error", "data" => "Error parsing JSON into valid websocket request"}}],
            else: [{0, hl_accept.(sub)}]

        _, _ ->
          []
      end

      adapter = scripted_adapter("hyperliquid", script)
      trades = %{"type" => "trades", "coin" => "BTC"}
      book = %{"type" => "l2Book", "coin" => "BTC"}
      assert :ok = Adapter.subscribe(adapter, [trades], ack_timeout_ms: 100)
      assert :ok = Adapter.subscribe(adapter, [book], ack_timeout_ms: 1_000)

      ExUnit.CaptureLog.capture_log(fn ->
        drop_connection(1)
        sends = sent(2, [], 2_500)
        assert Enum.count(sends, &(&1["subscription"] == book)) == 2
        _ = :sys.get_state(adapter)
      end)

      assert :sys.get_state(adapter).restore_attempts == 0
    end

    # Bybit names only the first already-subscribed topic of a refused request
    # and subscribes none of the others (api-testnet, 2026-11-25).
    for {mode, outcome} <- [{:both_active, "already subscribed"}, {:second_new, "accepted"}] do
      test "a multi-topic retry whose refusal names one topic resends the rest, which is #{outcome}" do
        mode = unquote(mode)
        retries = :atomics.new(1, [])

        refusal = fn topic ->
          %{"op" => "subscribe", "success" => false, "ret_msg" => "error:already subscribed,topic:" <> topic}
        end

        script = fn
          1, %{"op" => "subscribe"} ->
            [{0, %{"op" => "subscribe", "success" => true}}]

          2, %{"op" => "subscribe", "args" => [first | _] = args} ->
            case {:atomics.add_get(retries, 1, 1), mode, args} do
              {1, _, _} -> []
              {_, :second_new, ["publicTrade.BTCUSDT"]} -> [{0, %{"op" => "subscribe", "success" => true}}]
              _ -> [{0, refusal.(first)}]
            end

          _, _ ->
            []
        end

        adapter = scripted_adapter("bybit", script)
        topics = ["orderbook.50.BTCUSDT", "publicTrade.BTCUSDT"]
        assert :ok = Adapter.subscribe(adapter, topics, ack_timeout_ms: 100)

        ExUnit.CaptureLog.capture_log(fn ->
          drop_connection(1)
          sends = sent(2, [], 3_000)
          assert Enum.map(sends, & &1["args"]) == [topics, topics, ["publicTrade.BTCUSDT"]]
        end)

        assert :sys.get_state(adapter).restore_attempts == 0
      end
    end

    # The venue echoes the subscription as it was serialized, so a string
    # channel or atom keys must compare in that form.
    for {label, channel, echo} <- [
          {"an atom-keyed map", Macro.escape(%{type: "l2Book", coin: "BTC"}),
           ~s({"type":"l2Book","coin":"BTC","nSigFigs":null,"mantissa":null,"fast":false})},
          {"a string channel", "allMids", ~s({"type":"allMids"})}
        ] do
      test "a lost acceptance of #{label} is confirmed by the already-subscribed refusal" do
        echo = unquote(echo)
        retries = :atomics.new(1, [])

        script = fn
          1, %{"method" => "subscribe", "subscription" => sub} ->
            [{0, %{"channel" => "subscriptionResponse", "data" => %{"method" => "subscribe", "subscription" => sub}}}]

          2, %{"method" => "subscribe"} ->
            if :atomics.add_get(retries, 1, 1) == 1,
              do: [],
              else: [{0, %{"channel" => "error", "data" => "Already subscribed: " <> echo}}]

          _, _ ->
            []
        end

        adapter = scripted_adapter("hyperliquid", script)
        assert :ok = Adapter.subscribe(adapter, [unquote(channel)], ack_timeout_ms: 100)

        ExUnit.CaptureLog.capture_log(fn ->
          drop_connection(1)
          assert 2 |> sent([], 3_000) |> Enum.filter(&(&1["method"] == "subscribe")) |> length() == 2
        end)

        assert :sys.get_state(adapter).restore_attempts == 0
      end
    end
  end

  defp collect_dials(acc, window_ms) do
    started = List.last(acc) || System.monotonic_time(:millisecond)
    remaining = window_ms - (System.monotonic_time(:millisecond) - (List.first(acc) || started))

    receive do
      {:dial, at} -> collect_dials(acc ++ [at], window_ms)
    after
      max(remaining, 0) -> acc
    end
  end
end
