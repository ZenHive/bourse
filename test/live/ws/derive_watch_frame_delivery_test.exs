defmodule Bourse.WS.DeriveWatchFrameDeliveryTest do
  @moduledoc """
  Provider-live delivery for Derive's authored public watch channels (task 702).

  `ticker_slim` is not shape-identical to the retired `ticker` channel: parse
  is asserted against the nested `instrument_ticker` payload on a real frame.
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.MessageRouter

  @moduletag :network
  @moduletag :integration
  @moduletag :exchange_derive
  @moduletag timeout: 30_000

  test "the authored ticker delivers and parses the provider's slim payload" do
    exchange = Exchange.new!("derive", sandbox: true)
    assert {:ok, ws} = WS.connect(exchange, :public)

    try do
      assert {:ok, handle} = WS.watch_ticker(ws, "ETH/USD:USDC")
      assert handle.channels == ["ticker_slim.ETH-PERP.100"]
      frame = await_channel("ticker_slim.ETH-PERP.100")
      assert {:routed, :watch_ticker, payload, "ticker_slim.ETH-PERP.100"} = MessageRouter.route(frame, exchange)
      assert %{"instrument_ticker" => slim} = payload
      assert {:ok, ticker} = exchange.module.parse_ticker(payload, symbol: "ETH/USD:USDC")
      assert ticker.bid == Bourse.Safe.number(slim["b"])
      assert ticker.ask == Bourse.Safe.number(slim["a"])
      assert ticker.mark_price == Bourse.Safe.number(slim["M"])
      assert ticker.timestamp == slim["t"]
    after
      WS.close(ws)
    end
  end

  test "the deprecated ticker and message hash are rejected by the provider" do
    exchange = Exchange.new!("derive", sandbox: true)
    assert {:ok, ws} = WS.connect(exchange, :public)

    try do
      for {channel, code} <- [{"ticker.ETH-PERP.100", -32_602}, {":ETH-PERP", 13_000}] do
        assert {:error, {:subscription_rejected, frame}} = WS.subscribe(ws, [channel])
        assert frame["error"]["code"] == code
      end
    after
      WS.close(ws)
    end
  end

  defp await_channel(channel) do
    receive do
      {:websocket_message, %{"params" => %{"channel" => ^channel, "data" => data}} = frame} when is_map(data) -> frame
      {:websocket_message, _other} -> await_channel(channel)
    after
      15_000 -> flunk("no live data on #{channel}")
    end
  end
end
