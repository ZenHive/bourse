defmodule Bourse.Journeys.Trader.BinanceTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.WS

  @moduletag :exchange_binance

  @venue :binance
  @symbol "BTC/USDT"
  @amount 0.001
  # BTCUSDT quotes in 0.01 USDT ticks; resting bid sits 10% under market,
  # inside PERCENT_PRICE_BY_SIDE bidMultiplierDown 0.5 (observed 2026-08-28).
  @price_decimals 2
  @resting_ratio 0.9
  @frame_timeout_ms 20_000

  describe "a trader's day" do
    test "survey the market, place a resting limit buy, track it, cancel it" do
      exchange = sandbox_exchange!(@venue)

      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      assert market, "#{@symbol} missing from loaded binance markets"
      assert market.active
      assert market.spot and market.type == "spot" and not market.contract
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
          timeInForce: "GTC",
          newClientOrderId: unique_client_order_id("tb")
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
        # connect/3 sent userDataStream.subscribe.signature; that request *is*
        # the user data stream, so there is no channel to subscribe to after.
        # A subscribe.signature subscription outlives the socket that made it —
        # this block does not add an unauthenticated differential, because that
        # leg would have to run first or it would read this connection's events.
        assert %{pattern: :ws_api_signature} = ws.auth
        assert ws.url =~ "ws-api.testnet.binance.vision"

        {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
        assert [[best_bid, _bid_size] | _] = book.bids
        price = Float.round(best_bid * @resting_ratio, @price_decimals)
        client_order_id = unique_client_order_id("tbws")

        {:ok, placed} =
          Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
            price: price,
            timeInForce: "GTC",
            newClientOrderId: client_order_id
          )

        assert is_binary(placed.id) and placed.id != ""

        try do
          # Observed live 2026-08-28 on wss://ws-api.testnet.binance.vision/ws-api/v3:
          # envelope {subscriptionId, event}; event.e "executionReport", X/x "NEW",
          # r "NONE", w true. Authority: Binance Spot User Data Stream
          # executionReport (developers.binance.com).
          placed_event = await_order_event!(placed.id, "NEW")

          assert placed_event["s"] == "BTCUSDT"
          assert placed_event["S"] == "BUY"
          assert placed_event["o"] == "LIMIT"
          assert placed_event["f"] == "GTC"
          assert placed_event["c"] == client_order_id
          assert placed_event["C"] == ""
          assert placed_event["r"] == "NONE"
          assert placed_event["x"] == "NEW"
          assert placed_event["w"] == true

          assert {event_price, ""} = Float.parse(placed_event["p"])
          assert_in_delta event_price, price, 0.05
          assert {event_qty, ""} = Float.parse(placed_event["q"])
          assert_in_delta event_qty, @amount, 1.0e-9

          {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
          assert canceled.id == placed.id

          # Observed live 2026-08-28: the same i returns X/x "CANCELED", w false,
          # original newClientOrderId in C (c is a venue-issued replacement).
          cancel_event = await_order_event!(placed.id, "CANCELED")

          assert cancel_event["C"] == client_order_id
          assert cancel_event["x"] == "CANCELED"
          assert cancel_event["w"] == false
          assert cancel_event["z"] == "0.00000000"
        after
          release_order!(exchange, placed.id, @symbol)
        end
      after
        WS.close(ws)
      end
    end
  end

  describe "orders the venue rejects" do
    test "an amount below the instrument minimum is refused with binance's own error" do
      exchange = sandbox_exchange!(@venue)
      below_min = below_lot_size_quantity(exchange)
      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      assert [[best_bid, _bid_size] | _] = book.bids
      price = Float.round(best_bid * @resting_ratio, @price_decimals)

      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, @symbol, "limit", "buy", below_min,
                 price: price,
                 timeInForce: "GTC"
               )

      # Observed live 2026-08-28: POST /api/v3/order with quantity "0.000001"
      # (BTCUSDT LOT_SIZE minQty 0.00001) answers code -1013,
      # "Filter failure: LOT_SIZE". A float below 1.0e-4 encodes as scientific
      # notation and is refused first as -1100 ILLEGAL_CHARS, so the quantity
      # is a decimal string. Authority: Binance Spot errors.md —1013
      # INVALID_MESSAGE / Filter failure: LOT_SIZE
      # (https://developers.binance.com/docs/binance-spot-api-docs/errors).
      assert error.type == :invalid_order
      assert error.code == -1013
      assert error.message == "Filter failure: LOT_SIZE"
    end
  end

  # Spot user-data events arrive as {:websocket_message, %{"event" => …,
  # "subscriptionId" => _}}. Order id `i` is an integer on the wire; REST
  # returns it as a string.
  defp await_order_event!(order_id, status) do
    await_order_event!(order_id, status, System.monotonic_time(:millisecond) + @frame_timeout_ms)
  end

  defp await_order_event!(order_id, status, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
    else
      receive do
        {:websocket_message, %{"event" => %{"e" => "executionReport"} = event}} ->
          if order_event?(event, order_id, status) do
            event
          else
            await_order_event!(order_id, status, deadline)
          end

        _other ->
          await_order_event!(order_id, status, deadline)
      after
        left -> flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
      end
    end
  end

  defp order_event?(event, order_id, status) do
    event["X"] == status and to_string(event["i"]) == to_string(order_id)
  end

  # A float below 1.0e-4 `to_string`s as scientific notation and is refused
  # as -1100 before LOT_SIZE; compact decimal is the quantity the venue sees.
  defp below_lot_size_quantity(exchange) do
    :erlang.float_to_binary(market_min_amount(exchange) / 10, [{:decimals, 8}, :compact])
  end

  defp market_min_amount(exchange) do
    market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
    market.limits["amount"]["min"]
  end
end
