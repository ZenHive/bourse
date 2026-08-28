defmodule Bourse.Journeys.Trader.BinancecoinmTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.WS

  @moduletag :exchange_binancecoinm

  @venue :binancecoinm
  @symbol "BTC/USD:BTC"
  # BTCUSD_PERP is inverse: one contract is 100 USD of notional.
  @amount 1
  @price_decimals 1
  @resting_ratio 0.9
  @margin_exceeding_amount 100
  @frame_timeout_ms 20_000

  describe "a trader's day" do
    test "survey the market, place a resting limit buy, track it, cancel it" do
      exchange = sandbox_exchange!(@venue)

      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      assert market, "#{@symbol} missing from loaded binancecoinm markets"
      assert market.active
      assert market.contract and market.inverse and market.settle == "BTC"
      assert market.type == "swap"
      assert market.contract_size == 100
      assert market.limits["amount"]["min"] <= @amount

      {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol)
      assert ticker.symbol == @symbol
      assert is_number(ticker.last) and ticker.last > 0
      assert ticker.low <= ticker.last and ticker.last <= ticker.high
      assert_recent_timestamp!(ticker.timestamp)

      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      assert [best_bid, bid_size] = hd(book.bids)
      assert [best_ask, ask_size] = hd(book.asks)
      assert best_bid <= best_ask
      assert bid_size > 0 and ask_size > 0

      {:ok, balance} = Bourse.fetch_balance(exchange)
      assert map_size(balance.total) > 0
      assert_coinm_margin!(balance)

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
          newClientOrderId: unique_client_order_id("tbcoinm")
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
      {:ok, balance} = Bourse.fetch_balance(exchange)
      assert_coinm_margin!(balance)

      {:ok, ws} = WS.connect(exchange, :private)

      try do
        # connect/3 obtains a dapiPrivate listen key and puts the body-returned
        # key in the demo-dstream path. Connectivity alone proves no delivery.
        assert %{pattern: :listen_key} = ws.auth
        assert ws.url =~ "demo-dstream.binance.com"
        assert ws.url =~ "/ws/"

        {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
        assert [[best_bid, _bid_size] | _] = book.bids
        price = Float.round(best_bid * @resting_ratio, @price_decimals)
        client_order_id = unique_client_order_id("tbcws")

        {:ok, placed} =
          Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
            price: price,
            timeInForce: "GTC",
            newClientOrderId: client_order_id
          )

        assert is_binary(placed.id) and placed.id != ""

        try do
          # Observed live 2026-08-28 on demo-dstream: e is
          # ORDER_TRADE_UPDATE; o.X/x are NEW, o.ps is BOTH, and o.c echoes
          # newClientOrderId. Authority: Binance COIN-M Event Order Update.
          placed_event = await_order_event!(placed.id, "NEW")

          assert placed_event["s"] == "BTCUSD_PERP"
          assert placed_event["S"] == "BUY"
          assert placed_event["o"] == "LIMIT"
          assert placed_event["f"] == "GTC"
          assert placed_event["c"] == client_order_id
          assert placed_event["x"] == "NEW"
          assert placed_event["ps"] == "BOTH"

          assert {event_price, ""} = Float.parse(placed_event["p"])
          assert_in_delta event_price, price, 0.05
          assert {event_qty, ""} = Float.parse(placed_event["q"])
          assert_in_delta event_qty, @amount, 1.0e-9

          {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
          assert canceled.id == placed.id

          # Observed live 2026-08-28: the same o.i returns X/x CANCELED,
          # preserves o.c, and reports zero accumulated quantity in o.z.
          cancel_event = await_order_event!(placed.id, "CANCELED")
          assert cancel_event["c"] == client_order_id
          assert cancel_event["x"] == "CANCELED"
          assert cancel_event["z"] == "0"
        after
          release_order!(exchange, placed.id, @symbol)
        end
      after
        WS.close(ws)
      end
    end
  end

  describe "orders the venue rejects" do
    test "an oversized notional is refused with binancecoinm's own error" do
      exchange = sandbox_exchange!(@venue)
      {:ok, balance} = Bourse.fetch_balance(exchange)
      assert_coinm_margin!(balance)
      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      assert [[best_bid, _bid_size] | _] = book.bids
      price = Float.round(best_bid * @resting_ratio, @price_decimals)

      result =
        Bourse.create_order(exchange, @symbol, "limit", "buy", @margin_exceeding_amount,
          price: price,
          timeInForce: "GTC"
        )

      # Observed live 2026-08-28: POST /dapi/v1/order for 100 valid
      # BTCUSD_PERP contracts answers -2019, "Margin is insufficient."
      # Authority: Binance COIN-M error code -2019 MARGIN_NOT_SUFFICIEN.
      case result do
        {:ok, %Order{id: id}} ->
          release_order!(exchange, id, @symbol)
          flunk("expected -2019 margin rejection, venue accepted #{id}")

        {:error, %Error{} = error} ->
          assert error.type == :insufficient_funds
          assert error.code == -2019
          assert error.message == "Margin is insufficient."

        other ->
          flunk("unexpected create_order result: #{inspect(other)}")
      end
    end
  end

  defp await_order_event!(order_id, status) do
    await_order_event!(order_id, status, System.monotonic_time(:millisecond) + @frame_timeout_ms)
  end

  defp await_order_event!(order_id, status, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("no #{status} ORDER_TRADE_UPDATE for #{order_id} within #{@frame_timeout_ms}ms")
    else
      receive do
        {:websocket_message, %{"e" => "ORDER_TRADE_UPDATE", "o" => order}} ->
          if order["X"] == status and to_string(order["i"]) == to_string(order_id) do
            order
          else
            await_order_event!(order_id, status, deadline)
          end

        _other ->
          await_order_event!(order_id, status, deadline)
      after
        left -> flunk("no #{status} ORDER_TRADE_UPDATE for #{order_id} within #{@frame_timeout_ms}ms")
      end
    end
  end

  defp assert_coinm_margin!(balance) do
    assert (balance.free["BTC"] || 0) > 0,
           "binancecoinm demo BTC wallet has no free margin; re-fund COIN-M through the Binance demo UI (the faucet credits USD-M only)"
  end
end
