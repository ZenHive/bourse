defmodule Bourse.WS.UnifiedWatchTest do
  use Bourse.Test.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Channels
  alias Bourse.WS.Handle
  alias Bourse.WS.Subscription

  @moduletag trace_messages: 200

  describe "watch_orders/2" do
    test "requires private section" do
      exchange = Exchange.new!("okx")

      ws = %WS{
        exchange: exchange,
        zen_client: nil,
        url: "wss://example.test",
        section: :public
      }

      assert {:error, :private_section_required} = WS.watch_orders(ws)
    end
  end

  describe "Handle" do
    test "stores channels for unsubscribe" do
      exchange = Exchange.new!("bybit")

      ws = %WS{
        exchange: exchange,
        zen_client: nil,
        url: "wss://example.test",
        section: :public
      }

      assert {:ok, channel} = Channels.build(exchange, :watch_ticker, %{symbol: "BTC/USDT"}, [])
      handle = Handle.new(ws, :watch_ticker, channel)

      assert handle.method == :watch_ticker
      assert handle.channels == ["tickers.BTCUSDT"]
      assert handle.opts == []

      assert {:ok, %{"op" => "unsubscribe", "args" => ["tickers.BTCUSDT"]}} =
               Subscription.build_unsubscribe(:op_subscribe, handle.channels, %{})
    end
  end

  describe "WS telemetry (send path)" do
    setup do
      parent = self()
      ref = make_ref()
      handler_id = "ws-telemetry-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [[:bourse, :ws, :send]],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :send on subscribe (outbound)" do
      exchange = Exchange.new!("bybit")

      ws = %WS{
        exchange: exchange,
        zen_client: %ZenWebsocket.Client{state: :disconnected},
        url: "wss://example.test",
        section: :public
      }

      assert {:error, {:not_connected, :disconnected}} = WS.subscribe(ws, ["tickers.BTCUSDT"])

      assert_received {:telemetry, [:bourse, :ws, :send], %{system_time: _}, %{exchange: "bybit", section: :public}}
    end
  end
end
