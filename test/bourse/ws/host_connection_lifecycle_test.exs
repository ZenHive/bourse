defmodule Bourse.WS.HostConnectionLifecycleTest do
  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Adapter
  alias Bourse.WS.URLRouting
  alias ZenWebsocket.Client

  @ack_timeout_ms 0
  @assert_timeout_ms 200
  @refute_timeout_ms 50
  @connection_timeout_ms 250
  @heartbeat_interval_ms 12_345

  defmodule Transport do
    @moduledoc false
    use GenServer

    @spec start(pid(), String.t(), keyword()) :: GenServer.on_start()
    def start(owner, url, opts), do: GenServer.start(__MODULE__, {owner, url, opts})

    @spec deliver(pid(), map()) :: :ok
    def deliver(server, frame), do: GenServer.call(server, {:deliver, frame})

    @impl true
    def init({owner, url, opts}) do
      send(owner, {:transport_connected, url, self(), opts})
      {:ok, %{owner: owner, url: url, handler: Keyword.fetch!(opts, :handler)}}
    end

    @impl true
    def handle_call({:send_message, payload}, _from, state) do
      send(state.owner, {:transport_sent, state.url, Jason.decode!(payload)})
      {:reply, :ok, state}
    end

    def handle_call({:deliver, frame}, _from, state) do
      state.handler.({:message, frame})
      {:reply, :ok, state}
    end

    def handle_call(:get_state, _from, state), do: {:reply, :connected, state}
  end

  test "watch and raw subscriptions reuse hosts, preserve options, deliver, and close as one lifecycle" do
    test_pid = self()
    handler = fn message -> send(test_pid, {:configured_handler, message}) end
    heartbeat = %{type: :ping, interval: @heartbeat_interval_ms}
    disconnect = fn _reason -> :ok end

    connect_opts = [
      handler: handler,
      heartbeat_config: heartbeat,
      on_disconnect: disconnect,
      timeout: @connection_timeout_ms
    ]

    {ws, public_pid} = owned_ws(connect_opts)
    on_exit(fn -> WS.close(ws) end)

    public_url = URLRouting.public_url(ws.exchange)
    market_url = URLRouting.market_url(ws.exchange)
    assert_receive {:transport_connected, ^public_url, ^public_pid, root_opts}, @assert_timeout_ms
    assert root_opts[:handler] == handler
    assert root_opts[:heartbeat_config] == heartbeat
    assert root_opts[:on_disconnect] == disconnect
    assert root_opts[:timeout] == @connection_timeout_ms

    assert {:ok, first} = WS.watch_ticker(ws, "BTC/USDT", ack_timeout_ms: @ack_timeout_ms)
    assert first.channels == ["btcusdt@miniTicker"]
    assert_receive {:transport_connected, ^market_url, market_pid, routed_opts}, @assert_timeout_ms
    assert routed_opts[:handler] == handler
    assert routed_opts[:heartbeat_config] == heartbeat
    assert routed_opts[:on_disconnect] == disconnect
    assert routed_opts[:timeout] == @connection_timeout_ms
    assert_receive {:transport_sent, ^market_url, %{"params" => ["btcusdt@miniTicker"]}}, @assert_timeout_ms

    assert {:ok, second} = WS.watch_ticker(ws, "ETH/USDT", ack_timeout_ms: @ack_timeout_ms)
    assert second.ws.zen_client.server_pid == market_pid
    assert_receive {:transport_sent, ^market_url, %{"params" => ["ethusdt@miniTicker"]}}, @assert_timeout_ms
    refute_receive {:transport_connected, ^market_url, _, _}, @refute_timeout_ms

    assert {:ok, _book} = WS.watch_order_book(ws, "BTC/USDT", ack_timeout_ms: @ack_timeout_ms)
    assert_receive {:transport_sent, ^public_url, %{"params" => ["btcusdt@depth20@100ms"]}}, @assert_timeout_ms

    assert :ok =
             WS.subscribe(
               ws,
               ["btcusdt@bookTicker", "btcusdt@aggTrade"],
               ack_timeout_ms: @ack_timeout_ms
             )

    assert_receive {:transport_sent, ^public_url, %{"params" => ["btcusdt@bookTicker"]}}, @assert_timeout_ms
    assert_receive {:transport_sent, ^market_url, %{"params" => ["btcusdt@aggTrade"]}}, @assert_timeout_ms
    assert map_size(:sys.get_state(ws.connection_owner).connections) == 2

    public_frame = %{"e" => "depthUpdate"}
    market_frame = %{"e" => "aggTrade"}
    assert :ok = Transport.deliver(public_pid, public_frame)
    assert :ok = Transport.deliver(market_pid, market_frame)
    assert_receive {:configured_handler, {:message, ^public_frame}}, @assert_timeout_ms
    assert_receive {:configured_handler, {:message, ^market_frame}}, @assert_timeout_ms

    public_ref = Process.monitor(public_pid)
    market_ref = Process.monitor(market_pid)
    owner_ref = Process.monitor(ws.connection_owner)
    assert :ok = WS.close(ws)
    assert_receive {:DOWN, ^public_ref, :process, ^public_pid, :normal}, @assert_timeout_ms
    assert_receive {:DOWN, ^market_ref, :process, ^market_pid, :normal}, @assert_timeout_ms
    assert_receive {:DOWN, ^owner_ref, :process, _, :normal}, @assert_timeout_ms
  end

  test "adapter raw subscribe splits mixed hosts and adapter shutdown closes both" do
    test_pid = self()
    handler = fn message -> send(test_pid, {:configured_handler, message}) end
    {ws, public_pid} = owned_ws(handler: handler, timeout: @connection_timeout_ms)
    on_exit(fn -> WS.close(ws) end)

    public_url = URLRouting.public_url(ws.exchange)
    market_url = URLRouting.market_url(ws.exchange)
    assert_receive {:transport_connected, ^public_url, ^public_pid, _opts}, @assert_timeout_ms

    {:ok, adapter} = Adapter.start_link(ws.exchange, :public, connect: false, ws: ws)

    assert :ok =
             Adapter.subscribe(
               adapter,
               ["btcusdt@bookTicker", "btcusdt@ticker"],
               ack_timeout_ms: @ack_timeout_ms
             )

    assert_receive {:transport_connected, ^market_url, market_pid, _opts}, @assert_timeout_ms
    assert_receive {:transport_sent, ^public_url, %{"params" => ["btcusdt@bookTicker"]}}, @assert_timeout_ms
    assert_receive {:transport_sent, ^market_url, %{"params" => ["btcusdt@ticker"]}}, @assert_timeout_ms
    assert :sys.get_state(adapter).subscriptions == ["btcusdt@bookTicker", "btcusdt@ticker"]

    public_ref = Process.monitor(public_pid)
    market_ref = Process.monitor(market_pid)
    owner_ref = Process.monitor(ws.connection_owner)
    assert :ok = GenServer.stop(adapter)
    assert_receive {:DOWN, ^public_ref, :process, ^public_pid, :normal}, @assert_timeout_ms
    assert_receive {:DOWN, ^market_ref, :process, ^market_pid, :normal}, @assert_timeout_ms
    assert_receive {:DOWN, ^owner_ref, :process, _, :normal}, @assert_timeout_ms
  end

  test "a routed connection failure names the authored target host" do
    test_pid = self()
    handler = fn message -> send(test_pid, {:configured_handler, message}) end
    exchange = Exchange.new!("binanceusdm")
    public_url = URLRouting.public_url(exchange)
    market_url = URLRouting.market_url(exchange)

    connect_fun = fn
      ^public_url, opts ->
        with {:ok, transport} <- Transport.start(test_pid, public_url, opts) do
          {:ok, %Client{server_pid: transport, state: :connected, url: public_url}}
        end

      ^market_url, _opts ->
        {:error, :connection_refused}
    end

    assert {:ok, ws} =
             WS.connect(exchange, :public,
               handler: handler,
               connect_fun: connect_fun,
               timeout: @connection_timeout_ms
             )

    on_exit(fn -> WS.close(ws) end)
    assert_receive {:transport_connected, ^public_url, _, _opts}, @assert_timeout_ms

    assert {:error, {:stream_host_unavailable, ^market_url, :connection_refused}} =
             WS.subscribe(ws, ["btcusdt@ticker"], ack_timeout_ms: @ack_timeout_ms)
  end

  test "a mixed subscribe rolls back the first host when the second host fails" do
    test_pid = self()
    handler = fn message -> send(test_pid, {:configured_handler, message}) end
    exchange = Exchange.new!("binanceusdm")
    public_url = URLRouting.public_url(exchange)
    market_url = URLRouting.market_url(exchange)
    mixed = ["btcusdt@bookTicker", "btcusdt@ticker"]

    connect_fun = fn
      ^public_url, opts ->
        with {:ok, transport} <- Transport.start(test_pid, public_url, opts) do
          {:ok, %Client{server_pid: transport, state: :connected, url: public_url}}
        end

      ^market_url, _opts ->
        {:error, :connection_refused}
    end

    assert {:ok, ws} =
             WS.connect(exchange, :public,
               handler: handler,
               connect_fun: connect_fun,
               timeout: @connection_timeout_ms
             )

    on_exit(fn -> WS.close(ws) end)
    assert_receive {:transport_connected, ^public_url, _public_pid, _opts}, @assert_timeout_ms

    assert {:error, {:stream_host_unavailable, ^market_url, :connection_refused}} =
             WS.subscribe(ws, mixed, ack_timeout_ms: @ack_timeout_ms)

    assert_receive {:transport_sent, ^public_url, %{"method" => "SUBSCRIBE", "params" => ["btcusdt@bookTicker"]}},
                   @assert_timeout_ms

    assert_receive {:transport_sent, ^public_url, %{"method" => "UNSUBSCRIBE", "params" => ["btcusdt@bookTicker"]}},
                   @assert_timeout_ms

    refute_receive {:transport_connected, ^market_url, _, _}, @refute_timeout_ms
    refute_receive {:transport_sent, ^public_url, _}, @refute_timeout_ms

    assert {:error, {:stream_host_unavailable, ^market_url, :connection_refused}} =
             WS.subscribe(ws, mixed, ack_timeout_ms: @ack_timeout_ms)

    assert_receive {:transport_sent, ^public_url, %{"method" => "SUBSCRIBE", "params" => ["btcusdt@bookTicker"]}},
                   @assert_timeout_ms

    assert_receive {:transport_sent, ^public_url, %{"method" => "UNSUBSCRIBE", "params" => ["btcusdt@bookTicker"]}},
                   @assert_timeout_ms

    refute_receive {:transport_sent, ^public_url, %{"method" => "SUBSCRIBE", "params" => ["btcusdt@bookTicker"]}},
                   @refute_timeout_ms
  end

  test "adapter does not record a mixed list when any host fails" do
    test_pid = self()
    handler = fn message -> send(test_pid, {:configured_handler, message}) end
    exchange = Exchange.new!("binanceusdm")
    public_url = URLRouting.public_url(exchange)
    market_url = URLRouting.market_url(exchange)

    connect_fun = fn
      ^public_url, opts ->
        with {:ok, transport} <- Transport.start(test_pid, public_url, opts) do
          {:ok, %Client{server_pid: transport, state: :connected, url: public_url}}
        end

      ^market_url, _opts ->
        {:error, :connection_refused}
    end

    assert {:ok, ws} =
             WS.connect(exchange, :public,
               handler: handler,
               connect_fun: connect_fun,
               timeout: @connection_timeout_ms
             )

    on_exit(fn -> WS.close(ws) end)
    {:ok, adapter} = Adapter.start_link(ws.exchange, :public, connect: false, ws: ws)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)

    assert {:error, {:stream_host_unavailable, ^market_url, :connection_refused}} =
             Adapter.subscribe(
               adapter,
               ["btcusdt@bookTicker", "btcusdt@ticker"],
               ack_timeout_ms: @ack_timeout_ms
             )

    assert :sys.get_state(adapter).subscriptions == []
  end

  test "a stopped owner closes every routed socket so none are orphaned" do
    handler = fn _message -> :ok end
    {ws, public_pid} = owned_ws(handler: handler, timeout: @connection_timeout_ms)
    on_exit(fn -> WS.close(ws) end)
    public_url = URLRouting.public_url(ws.exchange)
    market_url = URLRouting.market_url(ws.exchange)
    assert_receive {:transport_connected, ^public_url, ^public_pid, _opts}, @assert_timeout_ms

    assert :ok =
             WS.subscribe(
               ws,
               ["btcusdt@bookTicker", "btcusdt@ticker"],
               ack_timeout_ms: @ack_timeout_ms
             )

    assert_receive {:transport_connected, ^market_url, market_pid, _opts}, @assert_timeout_ms

    public_ref = Process.monitor(public_pid)
    market_ref = Process.monitor(market_pid)
    owner_ref = Process.monitor(ws.connection_owner)
    assert :ok = GenServer.stop(ws.connection_owner)

    assert_receive {:DOWN, ^public_ref, :process, ^public_pid, :normal}, @assert_timeout_ms
    assert_receive {:DOWN, ^market_ref, :process, ^market_pid, :normal}, @assert_timeout_ms
    assert_receive {:DOWN, ^owner_ref, :process, _, :normal}, @assert_timeout_ms

    assert {:error, {:stream_host_unavailable, ^market_url, {:connection_owner_down, _reason}}} =
             WS.subscribe(ws, ["btcusdt@aggTrade"], ack_timeout_ms: @ack_timeout_ms)

    assert :ok = WS.close(ws)
  end

  test "a killed owner takes routed sockets with it" do
    handler = fn _message -> :ok end
    {ws, public_pid} = owned_ws(handler: handler, timeout: @connection_timeout_ms)
    on_exit(fn -> WS.close(ws) end)
    public_url = URLRouting.public_url(ws.exchange)
    market_url = URLRouting.market_url(ws.exchange)
    assert_receive {:transport_connected, ^public_url, ^public_pid, _opts}, @assert_timeout_ms

    assert :ok =
             WS.subscribe(
               ws,
               ["btcusdt@bookTicker", "btcusdt@ticker"],
               ack_timeout_ms: @ack_timeout_ms
             )

    assert_receive {:transport_connected, ^market_url, market_pid, _opts}, @assert_timeout_ms

    public_ref = Process.monitor(public_pid)
    market_ref = Process.monitor(market_pid)
    Process.exit(ws.connection_owner, :kill)

    assert_receive {:DOWN, ^public_ref, :process, ^public_pid, :killed}, @assert_timeout_ms
    assert_receive {:DOWN, ^market_ref, :process, ^market_pid, :killed}, @assert_timeout_ms
    assert :ok = WS.close(ws)
  end

  test "an authored split host without an owner fails with the target host named" do
    exchange = Exchange.new!("binanceusdm")
    public_url = URLRouting.public_url(exchange)
    market_url = URLRouting.market_url(exchange)
    {:ok, transport} = Transport.start(self(), public_url, handler: fn _message -> :ok end)
    on_exit(fn -> if Process.alive?(transport), do: GenServer.stop(transport) end)
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: exchange, zen_client: client, url: public_url, section: :public}
    assert_receive {:transport_connected, ^public_url, ^transport, _opts}, @assert_timeout_ms

    assert {:error, {:stream_host_unavailable, ^market_url, :connection_not_owned}} =
             WS.subscribe(ws, ["btcusdt@aggTrade"], ack_timeout_ms: @ack_timeout_ms)

    refute_receive {:transport_sent, _, _}, @refute_timeout_ms
  end

  defp owned_ws(connect_opts) do
    exchange = Exchange.new!("binanceusdm")
    test_pid = self()

    connect_fun = fn url, opts ->
      with {:ok, transport} <- Transport.start(test_pid, url, opts) do
        {:ok, %Client{server_pid: transport, state: :connected, url: url}}
      end
    end

    {:ok, ws} = WS.connect(exchange, :public, Keyword.put(connect_opts, :connect_fun, connect_fun))

    {ws, ws.zen_client.server_pid}
  end
end
