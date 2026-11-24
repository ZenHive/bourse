defmodule Bourse.WS.DeriveTickerTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.Channels
  alias Bourse.WS.MessageRouter

  test "routes the observed slim envelope and preserves bid, ask, sizes, index and mark" do
    exchange = Exchange.new!("derive")

    data = %{
      "timestamp" => 1_789_470_139_328,
      "instrument_ticker" => %{
        "t" => 1_789_470_139_328,
        "A" => "40",
        "a" => "2485.85",
        "B" => "40",
        "b" => "2483.35",
        "I" => "2484.67",
        "M" => "2484.81"
      }
    }

    frame = %{"method" => "subscription", "params" => %{"channel" => "ticker_slim.ETH-PERP.100", "data" => data}}
    assert {:routed, :watch_ticker, ^data, "ticker_slim.ETH-PERP.100"} = MessageRouter.route(frame, exchange)
    assert {:ok, ticker} = parse(exchange, data)
    assert ticker.bid == 2483.35
    assert ticker.ask == 2485.85
    assert ticker.bid_volume == 40
    assert ticker.ask_volume == 40
    assert ticker.index_price == 2484.67
    assert ticker.mark_price == 2484.81
    assert ticker.timestamp == 1_789_470_139_328
  end

  test "the v3 REST slim ticker (top-level keys) parses and absent slim fields stay absent" do
    exchange = Exchange.new!("derive")
    assert {:ok, ticker} = parse(exchange, %{"b" => "10", "a" => "11", "t" => 123})
    assert ticker.bid == 10
    assert ticker.ask == 11
    assert ticker.timestamp == 123
    assert {:ok, empty} = parse(exchange, %{"instrument_ticker" => %{}})
    assert empty.bid == nil
    assert empty.ask == nil
    assert empty.mark_price == nil
  end

  test "private channels are the provider's subaccount-scoped names" do
    exchange = Exchange.new!("derive")
    channels = get_in(exchange.spec, ["websocket", "subscribe", "channels"])
    assert channels["watchOrders"] == ["{subaccount_id}.orders"]
    assert channels["watchMyTrades"] == ["{subaccount_id}.trades"]

    assert {:error, {:unresolved, reason}} = Channels.build(exchange, :watch_orders, %{symbol: "ETH/USDC:USDC"})
    assert reason =~ "{subaccount_id}.orders"
    assert {:ok, "7.orders"} = Channels.build(exchange, :watch_orders, %{}, channel: "7.orders")

    frame = %{"method" => "subscription", "params" => %{"channel" => "7.orders", "data" => [%{"order_id" => "x"}]}}
    assert {:routed, :watch_orders, [%{"order_id" => "x"}], "7.orders"} = MessageRouter.route(frame, exchange)
  end

  defp parse(exchange, data) do
    exchange.module.parse_ticker(data)
  end
end
