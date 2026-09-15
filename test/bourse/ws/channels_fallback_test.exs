defmodule Bourse.WS.ChannelsFallbackTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.Channels

  test "a missing primary template retains the fallback's unresolved reason" do
    exchange = Exchange.new!("deribit")

    channels = %{"watchTickers" => %{"_unresolved_reason" => "requires_contract_choice"}}
    exchange = %{exchange | spec: put_in(exchange.spec, ["websocket", "subscribe", "channels"], channels)}

    assert {:error, {:unresolved, "requires_contract_choice"}} =
             Channels.build(exchange, :watch_ticker, %{symbol: "BTC-PERPETUAL"})
  end

  test "unknown venue infers method subscription from its authored envelope" do
    exchange = Exchange.new!("hyperliquid")
    channels = %{"watchTicker" => ["allMids"]}
    spec = put_in(exchange.spec, ["websocket", "subscribe", "channels"], channels)
    spec = put_in(spec, ["websocket", "subscribe", "resolved_from"], nil)
    exchange = %{exchange | id: "unknown_venue", spec: spec}

    assert {:ok, "allMids"} = Channels.build(exchange, :watch_ticker, %{})
  end
end
