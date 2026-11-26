defmodule Bourse.WS.SubscribeReturnShapeTest do
  @moduledoc """
  Pins the unified `Bourse.WS.subscribe/3` return shape (task 543):

  Always `:ok | {:error, term()}` — never `{:ok, envelope}`.
  Venue rejections (async or correlated) surface as
  `{:error, {:subscription_rejected, frame}}`.
  """

  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS
  alias ZenWebsocket.Client

  defmodule Transport do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         owner: Keyword.fetch!(opts, :owner),
         reply: Keyword.get(opts, :reply, :ok),
         # A venue that never answers a correlated request: the call is held.
         block: Keyword.get(opts, :block, false)
       }}
    end

    @impl true
    def handle_call({:send_message, message}, _from, state) do
      send(state.owner, {:transport_sent, message})
      if state.block, do: {:noreply, state}, else: {:reply, state.reply, state}
    end

    def handle_call(:get_state, _from, state), do: {:reply, :connected, state}
  end

  test "subscribe return type is always :ok or {:error, _} — never {:ok, map}" do
    # Documented contract: success is bare :ok across venues.
    assert :ok = normalize_example(:ok)
    assert {:error, :unsupported_exchange} = normalize_example({:error, :unsupported_exchange})

    refute match?({:ok, %{}}, normalize_example(:ok))
    refute match?({:ok, %{}}, normalize_example({:error, :x}))
  end

  test "async venue rejection is returned to the caller, not swallowed as :ok" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    reject = %{
      "op" => "subscribe",
      "success" => false,
      "req_id" => "7",
      "ret_msg" => "error:handler not found,topic:not.a.real.channel"
    }

    # Frame is already in the mailbox when await runs (same as a fast venue reply).
    send(self(), {:websocket_message, reject})

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["not.a.real.channel"], ack_timeout_ms: 200, request_id: 7)

    assert_receive {:transport_sent, _}
  end

  test "Alpaca's batched acknowledgement is consumed and earlier data is preserved" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("alpaca"), zen_client: client, url: "wss://offline.test", section: :public}
    connected = [%{"T" => "success", "msg" => "connected"}]

    send(self(), {:websocket_message, connected})
    send(self(), {:websocket_message, [%{"T" => "subscription", "trades" => ["FAKEPACA"]}]})

    assert :ok = WS.subscribe(ws, ["trades:FAKEPACA"], ack_timeout_ms: 200)
    assert_receive {:websocket_message, ^connected}
    assert_receive {:transport_sent, payload}

    assert Jason.decode!(payload) == %{
             "action" => "subscribe",
             "trades" => ["FAKEPACA"]
           }
  end

  test "async hyperliquid rejection surfaces as subscription_rejected" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("hyperliquid"), zen_client: client, url: "wss://offline.test", section: :public}

    reject = %{"channel" => "error", "data" => "Error parsing JSON into valid websocket request"}
    send(self(), {:websocket_message, reject})

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["allMids"], ack_timeout_ms: 200)
  end

  test "async acceptance returns bare :ok and preserves unrelated messages" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    send(self(), :unrelated)
    send(self(), {:websocket_message, %{"op" => "subscribe", "success" => true, "req_id" => "7"}})

    assert :ok = WS.subscribe(ws, ["tickers.BTCUSDT"], ack_timeout_ms: 200, request_id: 7)
    assert_receive :unrelated
  end

  test "adapter-tagged async rejection is returned to the caller" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}
    reject = %{"op" => "subscribe", "success" => false, "req_id" => "7", "ret_msg" => "bad topic"}

    send(self(), {:ws_frame, reject})

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["not.a.real.channel"], ack_timeout_ms: 200, request_id: 7)
  end

  test "a reply to another request is not this request's outcome and stays in the mailbox" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}
    late = {:websocket_message, %{"op" => "subscribe", "success" => true, "req_id" => "6"}}
    refused = {:websocket_message, %{"op" => "subscribe", "success" => false, "req_id" => "5", "ret_msg" => "x"}}
    unechoed = {:websocket_message, %{"op" => "subscribe", "success" => true}}

    send(self(), late)
    send(self(), refused)
    send(self(), unechoed)

    assert {:error, :subscription_ack_timeout} =
             WS.subscribe(ws, ["tickers.BTCUSDT"], ack_timeout_ms: 50, request_id: 7)

    assert_received ^late
    assert_received ^refused
    assert_received ^unechoed
  end

  test "a binance-family reply is matched by the id it echoes" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}

    for venue <- ["binance", "binanceusdm", "binancecoinm"] do
      ws = %WS{exchange: Exchange.new!(venue), zen_client: client, url: "wss://offline.test", section: :public}
      late = {:websocket_message, %{"id" => 6, "result" => nil}}
      refused = %{"id" => 7, "error" => %{"code" => 2, "msg" => "Invalid request: invalid stream"}}

      send(self(), late)
      send(self(), {:websocket_message, refused})

      assert {:error, {:subscription_rejected, ^refused}} =
               WS.subscribe(ws, ["btcusdt@depth"], ack_timeout_ms: 200, request_id: 7)

      assert_received ^late
      assert_receive {:transport_sent, payload}
      assert %{"id" => 7, "method" => "SUBSCRIBE", "params" => ["btcusdt@depth"]} = Jason.decode!(payload)
    end
  end

  test "a correlated reply that never comes times out at the acknowledgement deadline" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok, block: true})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("okx"), zen_client: client, url: "wss://offline.test", section: :public}

    {elapsed_us, result} = :timer.tc(fn -> WS.subscribe(ws, [%{"channel" => "tickers"}], ack_timeout_ms: 100) end)

    assert {:error, :subscription_ack_timeout} = result
    assert elapsed_us < 1_000_000
    refute_received {:DOWN, _, _, _, _}
  end

  describe "a subscribe that does not wait for the acknowledgement" do
    # Nothing waits for the reply, so no id is generated and the frame goes out
    # as on a venue without correlation: zen_websocket returns the send's own
    # result and hands the venue's reply to the handler as an ordinary frame.
    @channels %{
      "binance" => ["btcusdt@depth"],
      "okx" => [%{"channel" => "books", "instId" => "BTC-USDT"}],
      "bybit" => ["orderbook.50.BTCUSDT"]
    }

    for venue <- Map.keys(@channels) do
      test "#{venue} sends the frame without a generated id and returns the send's result" do
        transport = start_supervised!({Transport, owner: self(), reply: :ok})
        ws = no_wait_ws(unquote(venue), transport)

        assert :ok = WS.subscribe(ws, @channels[unquote(venue)], ack_timeout_ms: 0)
        assert_receive {:transport_sent, payload}
        frame = Jason.decode!(payload)
        refute Map.has_key?(frame, "id")
        refute Map.has_key?(frame, "req_id")
      end

      test "#{venue} returns a closed connection's error" do
        dead = spawn(fn -> :ok end)
        ref = Process.monitor(dead)
        assert_receive {:DOWN, ^ref, :process, ^dead, _}

        assert {:error, {:not_connected, :process_down}} =
                 WS.subscribe(no_wait_ws(unquote(venue), dead), @channels[unquote(venue)], ack_timeout_ms: 0)
      end

      test "#{venue} returns the transport's immediate refusal of the send" do
        transport = start_supervised!({Transport, owner: self(), reply: {:error, {:not_connected, :disconnected}}})

        assert {:error, {:not_connected, :disconnected}} =
                 WS.subscribe(no_wait_ws(unquote(venue), transport), @channels[unquote(venue)], ack_timeout_ms: 0)
      end
    end

    # A connection process that does not answer the send: the transport call's
    # own timeout reaches the caller, not :ok.
    test "a stalled connection surfaces the transport call's timeout" do
      transport = start_supervised!({Transport, owner: self(), block: true})

      assert {:timeout, _call} =
               catch_exit(WS.subscribe(no_wait_ws("okx", transport), @channels["okx"], ack_timeout_ms: 0))
    end

    test "an explicit request id is put on the frame" do
      transport = start_supervised!({Transport, owner: self(), reply: :ok})
      assert :ok = WS.subscribe(no_wait_ws("bybit", transport), ["tickers.BTCUSDT"], ack_timeout_ms: 0, request_id: 9)
      assert_receive {:transport_sent, payload}
      assert %{"req_id" => "9"} = Jason.decode!(payload)
    end

    # zen_websocket hands a frame without an `id` to the handler as
    # `{:message, frame}`; okx's refusal of an id-less request carries none.
    test "the default handler delivers okx's refusal as a websocket message" do
      test_pid = self()

      connect = fn _url, opts ->
        send(test_pid, {:handler, Keyword.fetch!(opts, :handler)})
        {:ok, %Client{server_pid: self(), state: :connected}}
      end

      assert {:ok, _ws} = WS.connect(Exchange.new!("okx"), :public, connect_fun: connect)
      assert_receive {:handler, handler}

      refusal = %{"event" => "error", "code" => "60018", "msg" => "doesn't exist", "connId" => "c"}
      handler.({:message, refusal})
      assert_receive {:websocket_message, ^refusal}
    end
  end

  defp no_wait_ws(venue, transport) do
    %WS{
      exchange: Exchange.new!(venue),
      zen_client: %Client{server_pid: transport, state: :connected},
      url: "wss://offline.test",
      section: :public
    }
  end

  test "a missing async acknowledgement returns a named timeout instead of success" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    assert {:error, :subscription_ack_timeout} =
             WS.subscribe(ws, ["tickers.BTCUSDT"], ack_timeout_ms: 10)

    assert_receive {:transport_sent, _}
  end

  test "derive unmatched JSON-RPC rejection is classified" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("derive"), zen_client: client, url: "wss://offline.test", section: :public}

    reject = %{
      "jsonrpc" => "2.0",
      "id" => "abc",
      "error" => %{
        "code" => -32_602,
        "data" => "`ticker` channel has been deprecated. Please use `ticker_slim`."
      }
    }

    send(self(), {:websocket_unmatched_response, reject})

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["ticker.ETH-PERPETUAL"], ack_timeout_ms: 200)
  end

  test "correlated deribit rejection is classified (not returned as {:ok, envelope})" do
    reject = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{
        "code" => 13_778,
        "message" => "raw_subscriptions_not_available_for_unauthorized"
      }
    }

    transport = start_supervised!({Transport, owner: self(), reply: {:ok, reject}})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("deribit"), zen_client: client, url: "wss://offline.test", section: :public}

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["ticker.BTC-PERPETUAL.raw"])
  end

  test "correlated deribit success normalizes to :ok" do
    ok_envelope = %{"jsonrpc" => "2.0", "id" => 1, "result" => ["ticker.BTC-PERPETUAL.100ms"]}
    transport = start_supervised!({Transport, owner: self(), reply: {:ok, ok_envelope}})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("deribit"), zen_client: client, url: "wss://offline.test", section: :public}

    assert :ok = WS.subscribe(ws, ["ticker.BTC-PERPETUAL.100ms"])
  end

  test "non-ack data frames stay in the mailbox during the await window" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    data = %{"topic" => "tickers.BTCUSDT", "data" => %{"lastPrice" => "1"}}
    reject = %{"op" => "subscribe", "success" => false, "req_id" => "7", "ret_msg" => "nope"}

    send(self(), {:websocket_message, data})
    send(self(), {:websocket_message, reject})

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["x"], ack_timeout_ms: 200, request_id: 7)

    assert_receive {:websocket_message, ^data}, 50
  end

  test "frames held during the await window keep arrival order with frames still queued behind the ack" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    connection = make_ref()
    frame = fn u -> {:ws_frame, connection, %{"topic" => "orderbook.50.BTCUSDT", "data" => %{"u" => u}}} end

    send(self(), frame.(1))
    send(self(), {:ws_frame, connection, %{"op" => "subscribe", "success" => true, "req_id" => "7"}})
    send(self(), frame.(2))
    send(self(), {:websocket_message, %{"topic" => "orderbook.50.BTCUSDT", "data" => %{"u" => 3}}})

    assert :ok = WS.subscribe(ws, ["orderbook.50.BTCUSDT"], ack_timeout_ms: 200, request_id: 7)

    # An order book checks every delta against the one before it, so the
    # held frame must come back ahead of the ones that arrived after it.
    {:messages, messages} = Process.info(self(), :messages)

    assert [
             {:ws_frame, ^connection, %{"data" => %{"u" => 1}}},
             {:ws_frame, ^connection, %{"data" => %{"u" => 2}}},
             {:websocket_message, %{"data" => %{"u" => 3}}}
           ] = Enum.reject(messages, &match?({:transport_sent, _}, &1))
  end

  test "frames that arrive while the ack is awaited keep arrival order" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}
    test_pid = self()
    frame = fn u -> {:websocket_message, %{"topic" => "orderbook.50.BTCUSDT", "data" => %{"u" => u}}} end

    receiver =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        send(test_pid, {:subscribed, WS.subscribe(ws, ["orderbook.50.BTCUSDT"], ack_timeout_ms: 5_000, request_id: 7)})

        receive do
          :report -> :ok
        end

        {:messages, messages} = Process.info(self(), :messages)
        send(test_pid, {:ids, for({:websocket_message, %{"data" => %{"u" => u}}} <- messages, do: u)})
      end)

    # A frame that arrives at the moment the wait hands frames back to the
    # mailbox. A wait that re-sends held frames lets it land among them.
    tracer =
      spawn(fn ->
        receive do
          {:trace, ^receiver, :send, {:websocket_message, %{"data" => %{"u" => 1}}}, ^receiver} ->
            send(receiver, frame.(5_001))
        end
      end)

    :erlang.trace(receiver, true, [:send, {:tracer, tracer}])

    for u <- 1..5_000, do: send(receiver, frame.(u))
    send(receiver, {:websocket_message, %{"op" => "subscribe", "success" => true, "req_id" => "7"}})

    # A second sender keeps delivering while the wait runs.
    {:ok, _sender} = Task.start(fn -> for u <- 5_002..6_000, do: send(receiver, frame.(u)) end)
    send(receiver, :go)

    assert_receive {:subscribed, :ok}, 5_000
    Process.sleep(100)
    send(receiver, :report)
    assert_receive {:ids, ids}, 5_000

    out_of_order = Enum.find(Enum.zip(ids, tl(ids)), fn {a, b} -> a > b end)
    assert out_of_order == nil, "frames left arrival order at #{inspect(out_of_order)}"
    assert Enum.take(ids, 5_000) == Enum.to_list(1..5_000)
  end

  test "messages that are not frames keep their place relative to frames" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("alpaca"), zen_client: client, url: "wss://offline.test", section: :public}
    trade = [%{"T" => "t", "S" => "FAKEPACA"}]

    send(self(), {:websocket_message, [%{"T" => "subscription", "trades" => ["FAKEPACA"]}]})
    send(self(), {:websocket_message, trade})
    send(self(), :market_timeout)

    assert :ok = WS.subscribe(ws, ["trades:FAKEPACA"], ack_timeout_ms: 1_000)

    {:messages, messages} = Process.info(self(), :messages)

    assert [{:websocket_message, ^trade}, :market_timeout] =
             Enum.reject(messages, &match?({:transport_sent, _}, &1))
  end

  test "the auth wait leaves every other message where it arrived" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    exchange = Exchange.new!("bybit", api_key: "key", secret: "secret")
    ws = %WS{exchange: exchange, zen_client: client, url: "wss://offline.test", section: :private}
    data = {:websocket_message, %{"topic" => "order", "data" => [%{"orderId" => "1"}]}}

    send(self(), data)
    send(self(), {:websocket_message, %{"op" => "auth", "success" => true}})
    send(self(), :tick)
    send(self(), {:websocket_message, %{"topic" => "order", "data" => [%{"orderId" => "2"}]}})

    assert {:ok, _meta} = WS.authenticate(ws)

    {:messages, messages} = Process.info(self(), :messages)

    assert [^data, :tick, {:websocket_message, %{"data" => [%{"orderId" => "2"}]}}] =
             Enum.reject(messages, &match?({:transport_sent, _}, &1))
  end

  test "channel shape errors from pattern modules propagate as {:error, atom}" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("hyperliquid"), zen_client: client, url: "wss://offline.test", section: :public}

    assert {:error, :multiple_maps_not_supported} =
             WS.subscribe(ws, [%{"type" => "a"}, %{"type" => "b"}], ack_timeout_ms: 50)

    # No frame sent when the pattern rejects the input shape.
    refute_receive {:transport_sent, _}, 50
  end

  defp normalize_example(result), do: result
end
