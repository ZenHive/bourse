defmodule Bourse.BybitWatchFrameDeliveryTest do
  @moduledoc "Provider-live delivery for the authored Bybit public watch channels."

  use Bourse.Test.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS

  @moduletag :network
  @moduletag :integration
  @moduletag :exchange_bybit
  @moduletag timeout: 90_000

  test "default ticker, order book, and trades subscriptions receive market data" do
    assert {:ok, ws} = WS.connect(Exchange.new!("bybit", sandbox: true), :public)

    try do
      assert {:ok, _} = WS.watch_ticker(ws, "BTC/USDT", ack_timeout_ms: 0)
      assert {:ok, _} = WS.watch_order_book(ws, "BTC/USDT", ack_timeout_ms: 0)
      assert {:ok, _} = WS.watch_trades(ws, "BTC/USDT", ack_timeout_ms: 0)

      topics = MapSet.new(["tickers.BTCUSDT", "orderbook.50.BTCUSDT", "publicTrade.BTCUSDT"])
      frames = receive_topics(topics, %{}, System.monotonic_time(:millisecond) + 65_000)

      ticker = frames["tickers.BTCUSDT"]["data"]
      assert ticker["symbol"] == "BTCUSDT"
      assert Decimal.positive?(Decimal.new(ticker["lastPrice"]))

      book = frames["orderbook.50.BTCUSDT"]["data"]
      assert book["s"] == "BTCUSDT"
      assert [[bid, _] | _] = book["b"]
      assert [[ask, _] | _] = book["a"]
      assert Decimal.compare(Decimal.new(bid), Decimal.new(ask)) == :lt

      assert [trade | _] = frames["publicTrade.BTCUSDT"]["data"]
      assert trade["s"] == "BTCUSDT"
      assert trade["S"] in ["Buy", "Sell"]
      assert Decimal.positive?(Decimal.new(trade["p"]))
      assert Decimal.positive?(Decimal.new(trade["v"]))
    after
      WS.close(ws)
    end
  end

  test "the former liquidation message hash receives the provider rejection" do
    assert {:ok, ws} = WS.connect(Exchange.new!("bybit", sandbox: true), :public)

    try do
      assert {:error, {:subscription_rejected, frame}} =
               WS.subscribe(ws, ["liquidations:BTCUSDT"], ack_timeout_ms: 5_000)

      assert frame["success"] == false
      assert frame["ret_msg"] == "error:handler not found,topic:liquidations:BTCUSDT"
    after
      WS.close(ws)
    end
  end

  defp receive_topics(needed, frames, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      missing = MapSet.difference(needed, MapSet.new(Map.keys(frames)))
      flunk("Bybit testnet delivered no market data for #{inspect(MapSet.to_list(missing))} within 65 seconds")
    end

    if MapSet.subset?(needed, MapSet.new(Map.keys(frames))) do
      frames
    else
      receive do
        {kind, %{"topic" => topic, "data" => data} = frame}
        when kind in [:websocket_message, :websocket_unmatched_response] and
               (is_map(data) or is_list(data)) ->
          frames = if MapSet.member?(needed, topic), do: Map.put_new(frames, topic, frame), else: frames
          receive_topics(needed, frames, deadline)

        {kind, %{"success" => false} = frame}
        when kind in [:websocket_message, :websocket_unmatched_response] ->
          flunk("Bybit rejected the authored subscription: #{inspect(frame)}")

        _other ->
          receive_topics(needed, frames, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          missing = MapSet.difference(needed, MapSet.new(Map.keys(frames)))
          flunk("Bybit testnet delivered no market data for #{inspect(MapSet.to_list(missing))} within 65 seconds")
      end
    end
  end
end
