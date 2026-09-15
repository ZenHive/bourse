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

  test "REST ticker fields still parse and absent slim fields stay absent" do
    exchange = Exchange.new!("derive")
    assert {:ok, ticker} = parse(exchange, %{"best_bid_price" => "10", "best_ask_price" => "11", "timestamp" => 123})
    assert ticker.bid == 10
    assert ticker.ask == 11
    assert ticker.timestamp == 123
    assert {:ok, empty} = parse(exchange, %{"instrument_ticker" => %{}})
    assert empty.bid == nil
    assert empty.ask == nil
    assert empty.mark_price == nil
  end

  test "private message hashes are explicitly unresolved, with provider channel pass-through" do
    exchange = Exchange.new!("derive")
    assert {:error, {:unresolved, reason}} = Channels.build(exchange, :watch_orders, %{symbol: "ETH/USD:USDC"})
    assert reason =~ "{subaccount_id}.orders"
    assert {:ok, "144422.orders"} = Channels.build(exchange, :watch_orders, %{}, channel: "144422.orders")

    assert %{"_unresolved_reason" => trades_reason} =
             get_in(exchange.spec, ["websocket", "subscribe", "channels", "watchMyTrades"])

    assert trades_reason =~ "{subaccount_id}.trades"
  end

  defp parse(exchange, data) do
    exchange.module.parse_ticker(data)
  end
end
