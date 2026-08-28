defmodule Bourse.Journeys.Trader.DeribitTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.WS

  @moduletag :exchange_deribit

  @venue :deribit
  @instrument_id "BTC-PERPETUAL"
  @symbol "BTC/USD:BTC"
  # Inverse perpetual: Deribit `private/buy` amount is USD notional, not coins.
  # BTC-PERPETUAL min_trade_amount and contract_size are both 10 USD
  # (https://docs.deribit.com/api-reference/trading/private-buy).
  @amount 10.0
  @resting_ratio 0.9
  @order_channel "user.orders.BTC-PERPETUAL.raw"
  @frame_timeout_ms 20_000

  describe "a trader's day" do
    test "survey the market, place a resting limit buy, track it, cancel it" do
      exchange = sandbox_exchange!(@venue)

      market = Enum.find(exchange.markets, &(&1.id == @instrument_id))
      assert market, "#{@instrument_id} missing from loaded deribit markets"
      assert market.active
      assert market.symbol == @symbol
      assert market.contract and market.inverse and not market.linear
      assert market.settle == "BTC" and market.type == "swap"
      assert market.info["instrument_type"] == "reversed"
      assert market.info["settlement_period"] == "perpetual"
      assert market.contract_size == 10.0
      assert market.limits["amount"]["min"] <= @amount
      tick = market.precision["price"]
      assert is_number(tick) and tick > 0

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
      # Observed live 2026-08-28: unified balance.timestamp is nil; BTC
      # free+used does not equal total (equity vs wallet). Assert signs only.
      assert (balance.total["BTC"] || 0) > 0

      for {currency, total} <- balance.total, is_number(total) do
        free = balance.free[currency] || 0.0
        used = balance.used[currency] || 0.0
        assert free >= 0 and used >= 0, "#{currency}: negative balance component"
      end

      price = resting_price(best_bid, tick)

      {:ok, placed} =
        Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
          price: price,
          clientOrderId: unique_client_order_id("trader-deribit")
        )

      assert is_binary(placed.id) and placed.id != ""

      try do
        # Deribit authors no fetchOpenOrder; private/get_order_state is fetch_order.
        order =
          poll_until!("order #{placed.id} visible as open", fn ->
            case Bourse.fetch_order(exchange, placed.id, symbol: @symbol) do
              {:ok, %Order{status: "open"} = order} -> {:ok, order}
              {:ok, %Order{}} -> :retry
              {:error, %Error{type: :order_not_found}} -> :retry
              {:error, error} -> flunk("fetch_order failed: #{inspect(error)}")
            end
          end)

        assert order.side == "buy"
        assert order.type == "limit"
        assert order.client_order_id == placed.client_order_id
        assert_in_delta order.price, price, tick / 2
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
      market = Enum.find(exchange.markets, &(&1.id == @instrument_id))
      tick = market.precision["price"]

      {:ok, ws} = WS.connect(exchange, :private)

      try do
        # connect/3 ran public/auth; an unauthenticated subscribe to a user
        # channel is accepted as an empty result list (Bourse.WS.SubscribeAck).
        assert %{pattern: :jsonrpc_linebreak} = ws.auth
        assert :ok = WS.subscribe(ws, [@order_channel])

        {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
        assert [[best_bid, _bid_size] | _] = book.bids
        price = resting_price(best_bid, tick)
        client_order_id = unique_client_order_id("trader-deribit-ws")

        {:ok, placed} =
          Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
            price: price,
            clientOrderId: client_order_id
          )

        assert is_binary(placed.id) and placed.id != ""

        try do
          # Observed live 2026-08-28 on wss://test.deribit.com/ws/api/v2:
          # method "subscription", channel user.orders.BTC-PERPETUAL.raw,
          # data is one order object (not a list), order_state "open".
          # Authority: Deribit user.orders.(instrument_name).raw
          # (https://docs.deribit.com/subscriptions/user/userordersinstrument_nameraw).
          placed_event = await_order_event!(placed.id, "open")

          assert placed_event["instrument_name"] == @instrument_id
          assert placed_event["direction"] == "buy"
          assert placed_event["order_type"] == "limit"
          assert placed_event["time_in_force"] == "good_til_cancelled"
          assert placed_event["label"] == client_order_id
          assert placed_event["api"] == true
          assert placed_event["filled_amount"] == 0.0
          assert_in_delta placed_event["price"], price, tick / 2
          assert_in_delta placed_event["amount"], @amount, 1.0e-9
          assert_in_delta placed_event["contracts"], @amount / market.contract_size, 1.0e-9

          {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
          assert canceled.id == placed.id

          # Observed live 2026-08-28: the same order_id returns order_state
          # "cancelled" and cancel_reason "user_request" — the venue names who
          # cancelled. Filled stays 0; remaining is not zeroed.
          cancel_event = await_order_event!(placed.id, "cancelled")

          assert cancel_event["label"] == client_order_id
          assert cancel_event["cancel_reason"] == "user_request"
          assert cancel_event["filled_amount"] == 0.0
        after
          release_order!(exchange, placed.id, @symbol)
        end
      after
        WS.close(ws)
      end
    end
  end

  describe "orders the venue rejects" do
    test "an amount below the instrument minimum is refused with deribit's own error" do
      exchange = sandbox_exchange!(@venue)
      below_min = market_min_amount(exchange) / 10
      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      assert [[best_bid, _bid_size] | _] = book.bids
      tick = Enum.find(exchange.markets, &(&1.id == @instrument_id)).precision["price"]
      price = resting_price(best_bid, tick)

      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, @symbol, "limit", "buy", below_min, price: price)

      # Observed live 2026-08-28: private/buy amount 1 (BTC-PERPETUAL
      # min_trade_amount / contract_size 10 USD) answers JSON-RPC -32602
      # Invalid params, data.param "amount", data.reason
      # "must be a multiple of contract size".
      # Authority: Deribit JSON-RPC errors —32602 Invalid params
      # (https://docs.deribit.com/articles/errors) and private/buy amount
      # (USD notional, multiple of contract size)
      # (https://docs.deribit.com/api-reference/trading/private-buy).
      assert error.type == :bad_request
      assert error.code == -32_602
      assert error.message =~ "must be a multiple of contract size"
      assert error.message =~ ~s("param" => "amount")
    end
  end

  # Deribit user.orders.raw notifications are JSON-RPC `subscription` frames
  # with a single order object in `params.data` (not a batched list).
  defp await_order_event!(order_id, status) do
    await_order_event!(order_id, status, System.monotonic_time(:millisecond) + @frame_timeout_ms)
  end

  defp await_order_event!(order_id, status, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
    else
      receive do
        {:websocket_message,
         %{
           "method" => "subscription",
           "params" => %{"channel" => @order_channel, "data" => data}
         }}
        when is_map(data) ->
          if to_string(data["order_id"]) == to_string(order_id) and data["order_state"] == status do
            data
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

  defp resting_price(best_bid, tick) do
    Float.round(best_bid * @resting_ratio / tick) * tick
  end

  defp market_min_amount(exchange) do
    market = Enum.find(exchange.markets, &(&1.id == @instrument_id))
    market.limits["amount"]["min"]
  end
end
