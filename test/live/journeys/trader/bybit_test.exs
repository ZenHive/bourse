defmodule Bourse.Journeys.Trader.BybitTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.WS
  alias Bourse.WS.Handle

  @moduletag :exchange_bybit

  @venue :bybit
  @symbol "BTC/USDT:USDT"
  @amount 0.001
  # BTCUSDT linear quotes in 0.1 USDT ticks; resting bid sits 10% under market.
  @price_decimals 1
  @resting_ratio 0.9

  # bybit's private order stream is one flat account-wide topic.
  @order_topic "order"
  @frame_timeout_ms 20_000

  describe "a trader's day" do
    test "survey the market, place a resting limit buy, track it, cancel it" do
      exchange = sandbox_exchange!(@venue)

      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      assert market, "#{@symbol} missing from loaded bybit markets"
      assert market.active
      assert market.contract and market.linear and market.settle == "USDT"
      assert market.limits["amount"]["min"] <= @amount

      {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol)
      assert ticker.symbol == @symbol
      assert ticker.bid > 0 and ticker.ask > 0 and ticker.bid <= ticker.ask
      assert ticker.low <= ticker.last and ticker.last <= ticker.high
      assert_recent_timestamp!(ticker.timestamp)

      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      assert [best_bid, bid_size] = hd(book.bids)
      assert [best_ask, ask_size] = hd(book.asks)
      assert best_bid <= best_ask
      assert bid_size > 0 and ask_size > 0

      {:ok, balance} = Bourse.fetch_balance(exchange)
      assert map_size(balance.total) > 0
      assert_recent_timestamp!(balance.timestamp)

      for {currency, total} <- balance.total, is_number(total) do
        free = balance.free[currency] || 0.0
        used = balance.used[currency] || 0.0
        assert free >= 0 and used >= 0, "#{currency}: negative balance component"
        assert_in_delta free + used, total, 0.01
      end

      price = Float.round(best_bid * @resting_ratio, @price_decimals)

      {:ok, placed} =
        Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
          price: price,
          clientOrderId: unique_client_order_id("trader-bybit")
        )

      assert is_binary(placed.id) and placed.id != ""

      try do
        order =
          poll_until!("order #{placed.id} visible as open", fn ->
            case Bourse.fetch_open_order(exchange, placed.id, symbol: @symbol) do
              {:ok, %Order{status: "open"} = order} -> {:ok, order}
              {:ok, %Order{}} -> :retry
              {:error, %Error{type: :order_not_found}} -> :retry
              {:error, error} -> flunk("fetch_open_order failed: #{inspect(error)}")
            end
          end)

        assert order.side == "buy"
        assert order.type == "limit"
        assert_in_delta order.price, price, 0.05
        assert_in_delta order.amount, @amount, 1.0e-9

        {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
        assert Enum.any?(open_orders, &(&1.id == placed.id)), "resting order missing from open orders"

        {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
        assert canceled.id == placed.id

        poll_until!("order #{placed.id} gone from open orders", fn ->
          {:ok, open} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
          if Enum.any?(open, &(&1.id == placed.id)), do: :retry, else: {:ok, :gone}
        end)
      after
        release_order!(exchange, placed.id, @symbol)
      end
    end
  end

  describe "a trader watching the private order stream" do
    test "the order's own lifecycle arrives on the stream, place and cancel" do
      exchange = sandbox_exchange!(@venue)

      {:ok, ws} = WS.connect(exchange, :private)

      try do
        # connect/3 ran the handshake; an unauthenticated socket would be
        # accepted by bybit and then deliver nothing at all.
        assert %{pattern: :direct_hmac_expiry} = ws.auth
        assert {:ok, %Handle{channels: [@order_topic]}} = WS.watch_orders(ws)

        {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
        assert [[best_bid, _bid_size] | _] = book.bids
        price = Float.round(best_bid * @resting_ratio, @price_decimals)
        client_order_id = unique_client_order_id("trader-bybit-ws")

        {:ok, placed} =
          Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
            price: price,
            clientOrderId: client_order_id
          )

        assert is_binary(placed.id) and placed.id != ""

        try do
          # Observed live 2026-08-24: topic "order", data[0] carries
          # orderStatus "New", rejectReason "EC_NoError", cancelType "UNKNOWN".
          placed_event = await_order_event!(placed.id, "New")

          assert placed_event["symbol"] == "BTCUSDT"
          assert placed_event["category"] == "linear"
          assert placed_event["side"] == "Buy"
          assert placed_event["orderType"] == "Limit"
          assert placed_event["timeInForce"] == "GTC"
          assert placed_event["orderLinkId"] == client_order_id
          assert placed_event["rejectReason"] == "EC_NoError"
          assert placed_event["cancelType"] == "UNKNOWN"

          assert {event_price, ""} = Float.parse(placed_event["price"])
          assert_in_delta event_price, price, 0.05
          assert {event_qty, ""} = Float.parse(placed_event["qty"])
          assert_in_delta event_qty, @amount, 1.0e-9

          {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
          assert canceled.id == placed.id

          # Observed live 2026-08-24: the same order id returns with
          # orderStatus "Cancelled", cancelType "CancelByUser" and
          # rejectReason "EC_PerCancelRequest" — the venue names who cancelled.
          cancel_event = await_order_event!(placed.id, "Cancelled")

          assert cancel_event["orderLinkId"] == client_order_id
          assert cancel_event["cancelType"] == "CancelByUser"
          assert cancel_event["rejectReason"] == "EC_PerCancelRequest"
          assert cancel_event["leavesQty"] == "0"
          assert cancel_event["cumExecQty"] == "0"
        after
          release_order!(exchange, placed.id, @symbol)
        end
      after
        WS.close(ws)
      end
    end
  end

  describe "orders the venue rejects" do
    test "an amount below the instrument minimum is refused with bybit's own error" do
      exchange = sandbox_exchange!(@venue)
      below_min = market_min_amount(exchange) / 10

      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, @symbol, "limit", "buy", below_min, price: 50_000.0)

      # Observed live 2026-08-24: retCode 10001,
      # "The number of contracts exceeds minimum limit allowed".
      assert error.type == :bad_request
      assert error.code == 10_001
      assert error.message =~ "minimum limit"
    end
  end

  # bybit's private order push carries an `"id"`, and zen_websocket hands any
  # id-bearing frame that correlates to no in-flight request to the caller as
  # `{:websocket_unmatched_response, _}` rather than `{:websocket_message, _}`.
  # One frame can batch several of the account's orders, so the matching entry
  # is picked out of `data` instead of assumed to be at its head.
  defp await_order_event!(order_id, status) do
    await_order_event!(order_id, status, System.monotonic_time(:millisecond) + @frame_timeout_ms)
  end

  defp await_order_event!(order_id, status, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
    else
      receive do
        {:websocket_unmatched_response, %{"topic" => @order_topic, "data" => data}} when is_list(data) ->
          case Enum.find(data, &(&1["orderId"] == order_id and &1["orderStatus"] == status)) do
            nil -> await_order_event!(order_id, status, deadline)
            event -> event
          end

        _other ->
          await_order_event!(order_id, status, deadline)
      after
        left -> flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
      end
    end
  end

  defp market_min_amount(exchange) do
    market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
    market.limits["amount"]["min"]
  end
end
