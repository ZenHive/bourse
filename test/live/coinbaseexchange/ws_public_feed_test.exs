defmodule Bourse.CoinbaseexchangeWsPublicFeedTest do
  @moduledoc """
  Provider-live public matches and heartbeat on the Coinbase Exchange feed.

  Observed 2026-09-15 against `wss://ws-feed.exchange.coinbase.com` (no credentials):
  subscriptions ack, historical `last_match`, `heartbeat.last_trade_id`, new
  `match`, and `type=error` / `reason="<channel> is not a valid channel"`.
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS

  @moduletag :network
  @moduletag :ws_canary
  @moduletag :exchange_coinbaseexchange
  @moduletag trace_messages: 200

  @symbol "ETH/USD"
  @product "ETH-USD"
  @ack_timeout_ms 5_000
  @receive_timeout_ms 15_000

  test "connects without credentials, acks trades, and distinguishes last_match from match" do
    exchange = Exchange.new!("coinbaseexchange")
    assert {:ok, ws} = WS.connect(exchange, :public)

    try do
      assert WS.get_state(ws) == :connected
      assert WS.get_url(ws) == "wss://ws-feed.exchange.coinbase.com"
      assert is_nil(ws.auth)

      assert {:ok, _handle} = WS.watch_trades(ws, @symbol, ack_timeout_ms: @ack_timeout_ms)

      frames = collect_feed_frames(@receive_timeout_ms)
      types = Enum.map(frames, & &1["type"])

      refute "subscriptions" in types
      assert "last_match" in types
      assert "match" in types
      assert "heartbeat" in types

      last_match = Enum.find(frames, &(&1["type"] == "last_match"))
      match = Enum.find(frames, &(&1["type"] == "match"))
      heartbeat = Enum.find(frames, &(&1["type"] == "heartbeat"))

      assert_match_fields(last_match)
      assert_match_fields(match)
      assert last_match["trade_id"] != match["trade_id"]

      assert heartbeat["product_id"] == @product
      assert is_integer(heartbeat["last_trade_id"])
      assert is_integer(heartbeat["sequence"])
      assert is_binary(heartbeat["time"])
    after
      WS.close(ws)
    end
  end

  test "a deliberately invalid channel returns the provider subscription error" do
    exchange = Exchange.new!("coinbaseexchange")
    assert {:ok, ws} = WS.connect(exchange, :public)

    try do
      assert {:error, {:subscription_rejected, frame}} =
               WS.subscribe(ws, [@product],
                 channel_name: "not_a_valid_channel",
                 ack_timeout_ms: @ack_timeout_ms
               )

      assert frame["type"] == "error"
      assert frame["message"] == "Failed to subscribe"
      assert frame["reason"] == "not_a_valid_channel is not a valid channel"
    after
      WS.close(ws)
    end
  end

  defp assert_match_fields(frame) do
    assert frame["product_id"] == @product
    assert is_integer(frame["trade_id"])
    assert is_binary(frame["time"])
    assert frame["side"] in ["buy", "sell"]
    assert is_binary(frame["price"])
    assert is_binary(frame["size"])
  end

  defp collect_feed_frames(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    needed = MapSet.new(["last_match", "match", "heartbeat"])
    do_collect(deadline, [], needed)
  end

  defp do_collect(deadline, frames, needed) do
    have = MapSet.new(Enum.map(frames, & &1["type"]))

    cond do
      MapSet.subset?(needed, have) ->
        Enum.reverse(frames)

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "Coinbase Exchange public feed did not deliver last_match, match, and heartbeat within the window. " <>
            "Got types=#{inspect(Enum.map(frames, & &1["type"]))} from wss://ws-feed.exchange.coinbase.com"
        )

      true ->
        left = deadline - System.monotonic_time(:millisecond)

        receive do
          {:websocket_message, %{} = frame} ->
            do_collect(deadline, [frame | frames], needed)

          {:websocket_unmatched_response, %{} = frame} ->
            do_collect(deadline, [frame | frames], needed)

          _other ->
            do_collect(deadline, frames, needed)
        after
          max(left, 0) ->
            do_collect(deadline, frames, needed)
        end
    end
  end
end
