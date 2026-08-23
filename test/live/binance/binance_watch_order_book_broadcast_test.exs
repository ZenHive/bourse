defmodule Bourse.WS.BinanceWatchOrderBookBroadcastTest do
  @moduledoc """
  Live Broadcast routing evidence for the default binance spot
  `watch_order_book` stream (task 628).

  Task 618 pinned frame arrival on `{:websocket_message, frame}`. That is not
  enough for Broadcast consumers: Adapter must classify the partial-book
  snapshot and emit `{:routed, :watch_order_book, ...}`. A subscribe-ack or a
  raw/unknown classification is not success.

  Gated by `:network` + `:integration`. Run with:

      mix test.json --quiet --include network --include integration \\
        test/live/binance/binance_watch_order_book_broadcast_test.exs
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS.Adapter
  alias Bourse.WS.Broadcast
  alias Bourse.WS.Channels

  @moduletag :network
  @moduletag :integration
  @moduletag trace_messages: 200

  @receive_timeout 15_000
  @connect_timeout 15_000

  test "spot default depth20@100ms produces a routed watch_order_book Broadcast" do
    exchange = Exchange.new!("binance")
    book_topic = Broadcast.topic("binance", :watch_order_book, nil)
    raw_topic = Broadcast.topic("binance", :raw, nil)
    Broadcast.subscribe(book_topic)
    Broadcast.subscribe(raw_topic)

    on_exit(fn ->
      Broadcast.unsubscribe(book_topic)
      Broadcast.unsubscribe(raw_topic)
    end)

    {:ok, adapter} = Adapter.start_link(exchange, :public)
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter, :normal) end)

    await_connected(adapter, @connect_timeout)

    assert {:ok, "btcusdt@depth20@100ms"} =
             Channels.build(exchange, :watch_order_book, %{symbol: "BTC/USDT"}, [])

    assert :ok = Adapter.subscribe(adapter, ["btcusdt@depth20@100ms"])

    payload = await_routed_book(@receive_timeout)
    assert is_integer(payload["lastUpdateId"])
    assert is_list(payload["bids"]) and payload["bids"] != []
    assert is_list(payload["asks"]) and payload["asks"] != []
    refute Map.has_key?(payload, "e")
    refute Map.has_key?(payload, "result")
  end

  defp await_connected(adapter, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_connected(adapter, deadline)
  end

  defp do_await_connected(adapter, deadline) do
    case Adapter.connection_state(adapter) do
      :connected ->
        :ok

      _other ->
        left = deadline - System.monotonic_time(:millisecond)

        if left <= 0 do
          flunk("timed out waiting for the binance public adapter to connect")
        else
          receive do
          after
            min(50, left) -> do_await_connected(adapter, deadline)
          end
        end
    end
  end

  defp await_routed_book(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_routed_book(deadline)
  end

  defp do_await_routed_book(deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("timed out waiting for a routed :watch_order_book Broadcast")
    else
      receive do
        {:bourse_ws, {:raw, frame}} ->
          flunk("classified as raw/unknown instead of :watch_order_book: #{inspect(frame)}")

        {:bourse_ws, {:system, _ack}} ->
          do_await_routed_book(deadline)

        {:bourse_ws, {:routed, :watch_order_book, payload, _channel, _market, _book}} ->
          if book_snapshot?(payload) do
            payload
          else
            flunk("routed :watch_order_book payload was not a partial-book snapshot: #{inspect(payload)}")
          end

        {:bourse_ws, other} ->
          flunk("unexpected Broadcast on the book/raw topics: #{inspect(other)}")
      after
        max(left, 0) ->
          flunk("timed out waiting for a routed :watch_order_book Broadcast")
      end
    end
  end

  defp book_snapshot?(%{"lastUpdateId" => _, "bids" => bids, "asks" => asks})
       when is_list(bids) and is_list(asks) and bids != [] and asks != [] do
    true
  end

  defp book_snapshot?(_payload), do: false
end
