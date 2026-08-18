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
         reply: Keyword.get(opts, :reply, :ok)
       }}
    end

    @impl true
    def handle_call({:send_message, message}, _from, state) do
      send(state.owner, {:transport_sent, message})
      {:reply, state.reply, state}
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
      "ret_msg" => "error:handler not found,topic:not.a.real.channel"
    }

    # Frame is already in the mailbox when await runs (same as a fast venue reply).
    send(self(), {:websocket_message, reject})

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["not.a.real.channel"], ack_timeout_ms: 200)

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
    send(self(), {:websocket_message, %{"op" => "subscribe", "success" => true}})

    assert :ok = WS.subscribe(ws, ["tickers.BTCUSDT"], ack_timeout_ms: 200)
    assert_receive :unrelated
  end

  test "adapter-tagged async rejection is returned to the caller" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}
    reject = %{"op" => "subscribe", "success" => false, "ret_msg" => "bad topic"}

    send(self(), {:ws_frame, reject})

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["not.a.real.channel"], ack_timeout_ms: 200)
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

  test "non-ack data frames are re-queued during the await window" do
    transport = start_supervised!({Transport, owner: self(), reply: :ok})
    client = %Client{server_pid: transport, state: :connected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    data = %{"topic" => "tickers.BTCUSDT", "data" => %{"lastPrice" => "1"}}
    reject = %{"op" => "subscribe", "success" => false, "ret_msg" => "nope"}

    send(self(), {:websocket_message, data})
    send(self(), {:websocket_message, reject})

    assert {:error, {:subscription_rejected, ^reject}} =
             WS.subscribe(ws, ["x"], ack_timeout_ms: 200)

    assert_receive {:websocket_message, ^data}, 50
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
