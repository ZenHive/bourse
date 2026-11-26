defmodule Bourse.WS.FacadeTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Handle
  alias ZenWebsocket.Client

  defmodule Transport do
    @moduledoc false
    use GenServer

    # `echo` builds the venue's reply from the decoded frame, delivered to the
    # owner after the send, as the venue's reply would be.
    def start_link({owner, echo}), do: GenServer.start_link(__MODULE__, {owner, echo})
    def start_link(owner), do: start_link({owner, nil})

    @impl true
    def init({owner, echo}), do: {:ok, %{owner: owner, echo: echo}}

    @impl true
    def handle_call({:send_message, message}, _from, %{owner: owner} = state) do
      send(owner, {:transport_sent, message})
      if state.echo, do: Enum.each(List.wrap(state.echo.(Jason.decode!(message))), &send(owner, &1))
      {:reply, :ok, state}
    end

    def handle_call(:get_state, _from, state), do: {:reply, :connected, state}

    def handle_call(:get_heartbeat_health, _from, state) do
      {:reply,
       %{
         active_heartbeats: [],
         last_heartbeat_at: nil,
         failure_count: 0,
         config: :disabled,
         timer_active: false
       }, state}
    end
  end

  setup do
    transport = start_supervised!({Transport, self()})
    client = %Client{server_pid: transport, state: :connected}
    %{client: client}
  end

  test "returns connection setup errors without opening a socket" do
    alias Bourse.WS.Config

    # Every runtime venue has a public WS config. The missing-config
    # classification for a supported id is still :websocket_not_configured.
    assert Config.missing_config_error("coinbaseexchange") == {:error, :websocket_not_configured}

    unsupported = %Exchange{id: "kraken", name: "Kraken", spec: %{}}
    assert {:error, :unsupported_exchange} = WS.connect(unsupported, :public)
    assert {:error, :no_url_configured} = WS.connect(Exchange.new!("hyperliquid"), :private)
  end

  test "subscribes, sends raw messages, and exposes facade state", %{client: client} do
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    # Offline transport never emits an ack; skip the await window.
    assert :ok = WS.subscribe(ws, ["tickers.BTCUSDT"], ack_timeout_ms: 0)
    assert_receive {:transport_sent, payload}
    # Nothing waits for the reply, so the frame carries no generated id.
    assert Jason.decode!(payload) == %{"args" => ["tickers.BTCUSDT"], "op" => "subscribe"}

    assert :ok = WS.send_message(ws, "ping")
    assert_receive {:transport_sent, "ping"}
    assert :ok = WS.send_message(ws, %{"op" => "ping"})
    assert_receive {:transport_sent, ~s({"op":"ping"})}
    assert WS.get_state(ws) == :connected
    assert WS.get_url(ws) == "wss://offline.test"

    assert {:ok,
            [
              %{
                url: "wss://offline.test",
                role: :primary,
                connection_state: :connected,
                heartbeat: %{failure_count: 0, config: :disabled}
              }
            ]} = WS.health(ws)
  end

  test "unsupported heartbeat types fail without opening a socket" do
    assert {:error, {:unsupported_heartbeat, :ping}} =
             WS.connect(Exchange.new!("bybit"), :public,
               heartbeat_config: %{type: :ping, interval: 1_000},
               connect_fun: fn _url, _opts -> flunk("must not connect") end
             )
  end

  test "binanceusdm watch_ticker stays on a non-authored test-double URL", %{client: client} do
    ws = %WS{exchange: Exchange.new!("binanceusdm"), zen_client: client, url: "wss://offline.test", section: :public}

    assert {:ok, handle} = WS.watch_ticker(ws, "BTC/USDT", ack_timeout_ms: 0)
    assert handle.ws.url == "wss://offline.test"
    assert handle.channels == ["btcusdt@miniTicker"]
    assert_receive {:transport_sent, payload}
    assert Jason.decode!(payload)["params"] == ["btcusdt@miniTicker"]
  end

  test "builds handles and matching unsubscribe frames", %{client: client} do
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    assert {:ok, handle} = WS.watch_ticker(ws, "BTC/USDT", ack_timeout_ms: 0)
    assert_receive {:transport_sent, subscribe_payload}
    assert Jason.decode!(subscribe_payload)["op"] == "subscribe"

    assert :ok = WS.unsubscribe(handle)
    assert_receive {:transport_sent, unsubscribe_payload}

    # The handle keeps the subscribe's `ack_timeout_ms: 0`, so neither frame
    # carries a generated id.
    assert Jason.decode!(unsubscribe_payload) == %{"args" => ["tickers.BTCUSDT"], "op" => "unsubscribe"}
    refute Map.has_key?(Jason.decode!(subscribe_payload), "req_id")
    assert Process.alive?(client.server_pid)
  end

  test "watch returns subscription errors without closing the caller connection" do
    client = %Client{state: :disconnected}
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    assert {:error, {:not_connected, :disconnected}} =
             WS.watch_ticker(ws, "BTC/USDT", ack_timeout_ms: 0)
  end

  test "watch reraises subscription failures without closing the caller connection", %{client: client} do
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    assert_raise ArithmeticError, fn ->
      WS.watch_ticker(ws, "BTC/USDT", ack_timeout_ms: :invalid)
    end

    assert_receive {:transport_sent, _payload}
    assert Process.alive?(client.server_pid)
  end

  test "builds a handle with default subscription options", %{client: client} do
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    assert %Handle{opts: [], channels: ["tickers.BTCUSDT"]} =
             Handle.new(ws, :watch_ticker, "tickers.BTCUSDT")
  end

  test "supports every unified watch wrapper and map subscription options", %{client: client} do
    public_ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}
    private_ws = %{public_ws | section: :private}

    assert {:ok, _} = WS.watch_order_book(public_ws, "BTC/USDT", limit: 50, ack_timeout_ms: 0)
    assert_receive {:transport_sent, _}
    assert {:ok, _} = WS.watch_trades(public_ws, "BTC/USDT", ack_timeout_ms: 0)
    assert_receive {:transport_sent, _}
    assert {:ok, _} = WS.watch_orders(private_ws, ack_timeout_ms: 0)
    assert_receive {:transport_sent, payload}
    assert Jason.decode!(payload) == %{"op" => "subscribe", "args" => ["order"]}
    assert :ok = WS.subscribe(public_ws, ["tickers.BTCUSDT"], %{ack_timeout_ms: 0})
    assert_receive {:transport_sent, _}
  end

  test "default order-book options wait for an acceptance frame" do
    ws = %WS{
      exchange: Exchange.new!("bybit"),
      zen_client: accepting_client(),
      url: "wss://offline.test",
      section: :public
    }

    assert {:ok, %Handle{channels: ["orderbook.50.BTCUSDT"]}} = WS.watch_order_book(ws, "BTC/USDT")
    assert_receive {:transport_sent, _}
  end

  test "an elapsed acknowledgement deadline requeues unrelated messages", %{client: client} do
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}
    send(self(), :unrelated)

    assert {:error, :subscription_ack_timeout} =
             WS.subscribe(ws, ["tickers.BTCUSDT"], ack_timeout_ms: -1)

    assert_received :unrelated
  end

  test "default watch options wait for and consume acceptance frames" do
    ws = %WS{
      exchange: Exchange.new!("bybit"),
      zen_client: accepting_client(),
      url: "wss://offline.test",
      section: :public
    }

    assert {:ok, _handle} = WS.watch_ticker(ws, "BTC/USDT")
    assert_receive {:transport_sent, _}

    assert {:ok, _handle} = WS.watch_trades(ws, "BTC/USDT")
    assert_receive {:transport_sent, _}
    refute_received {:websocket_message, %{"op" => "subscribe"}}
  end

  # A transport whose venue accepts every bybit subscribe, echoing its req_id.
  defp accepting_client do
    echo = fn %{"op" => "subscribe", "req_id" => id} ->
      {:websocket_message, %{"op" => "subscribe", "success" => true, "req_id" => id}}
    end

    %Client{server_pid: start_supervised!({Transport, {self(), echo}}, id: :accepting), state: :connected}
  end

  test "closes a supervised transport", %{client: client} do
    ws = %WS{exchange: Exchange.new!("bybit"), zen_client: client, url: "wss://offline.test", section: :public}

    assert :ok = WS.close(ws)
  end

  test "lighter default subscribe keeps the subscribed snapshot and surfaces invalid-channel rejection", %{
    client: client
  } do
    ws = %WS{exchange: Exchange.new!("lighter"), zen_client: client, url: "wss://offline.test", section: :public}

    snapshot = %{
      "type" => "subscribed/market_stats",
      "channel" => "market_stats:0",
      "market_stats" => %{"market_id" => 0, "symbol" => "ETH"}
    }

    update = %{
      "type" => "update/market_stats",
      "channel" => "market_stats:0",
      "market_stats" => %{"market_id" => 0, "symbol" => "ETH"}
    }

    send(self(), {:websocket_message, snapshot})
    send(self(), {:websocket_message, update})
    assert :ok = WS.subscribe(ws, ["market_stats/0"])
    assert_receive {:transport_sent, payload}
    assert Jason.decode!(payload) == %{"channel" => "market_stats/0", "type" => "subscribe"}
    assert_received {:websocket_message, ^snapshot}
    assert_received {:websocket_message, ^update}

    rejection = %{"error" => %{"code" => 30_005, "message" => "Invalid Channel"}}
    send(self(), {:websocket_message, rejection})

    assert {:error, {:subscription_rejected, ^rejection}} =
             WS.subscribe(ws, ["not_a_real_channel/0"])

    refute_received {:websocket_message, ^rejection}
  end
end
