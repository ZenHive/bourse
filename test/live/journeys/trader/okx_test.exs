defmodule Bourse.Journeys.Trader.OkxTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.WS

  @moduletag :exchange_okx

  @venue :okx
  @symbol "BTC/USDT:USDT"
  # BTC-USDT-SWAP minSz and lotSz are both 0.01 contracts (ctVal 0.01 BTC).
  @amount 0.01
  # BTC-USDT-SWAP quotes in 0.1 USDT ticks; resting bid sits 10% under market.
  @price_decimals 1
  @resting_ratio 0.9

  # OKX's private orders channel is `{channel: "orders", instType: ...}`. The
  # authored `websocket.subscribe.channels.watchOrders` template is `["ANY"]` —
  # the instType value alone, with no channel name — so the journey names the
  # whole arg itself. `ANY` is the account-wide instType (www.okx.com/docs-v5).
  @order_channel %{"channel" => "orders", "instType" => "ANY"}
  @frame_timeout_ms 20_000

  describe "a trader's day" do
    test "survey the market, place a resting limit buy, track it, cancel it" do
      exchange = sandbox_exchange!(@venue)

      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      assert market, "#{@symbol} missing from loaded okx markets"
      assert market.active
      assert market.contract and market.linear and market.settle == "USDT"
      assert market.limits["amount"]["min"] <= @amount

      {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol)
      assert ticker.symbol == @symbol
      assert ticker.bid > 0 and ticker.ask > 0 and ticker.bid <= ticker.ask
      assert is_number(ticker.last) and ticker.last > 0
      assert_recent_timestamp!(ticker.timestamp)

      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      assert [best_bid, bid_size] = hd(book.bids)
      assert [best_ask, ask_size] = hd(book.asks)
      assert best_bid <= best_ask
      assert bid_size > 0 and ask_size > 0

      {:ok, balance} = Bourse.fetch_balance(exchange)
      assert map_size(balance.total) > 0
      # Observed live 2026-08-28: GET /api/v5/account/balance has no timestamp
      # field, so the unified Balance.timestamp stays nil.

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
          clientOrderId: unique_cl_ord_id("tokx")
        )

      assert is_binary(placed.id) and placed.id != ""

      try do
        # OKX authors no fetchOpenOrder; GET /api/v5/trade/order is the
        # single-order read (state "live" → unified "open").
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
        # connect/3 ran the iso-passphrase login; an unauthenticated socket
        # is accepted by OKX and then rejects the private subscribe (60011).
        assert %{pattern: :iso_passphrase} = ws.auth
        assert ws.url =~ "wspap.okx.com"
        assert :ok = WS.subscribe(ws, [@order_channel])

        {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
        assert [[best_bid, _bid_size] | _] = book.bids
        price = Float.round(best_bid * @resting_ratio, @price_decimals)
        client_order_id = unique_cl_ord_id("wokx")

        {:ok, placed} =
          Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
            price: price,
            clientOrderId: client_order_id
          )

        assert is_binary(placed.id) and placed.id != ""

        try do
          # Observed live 2026-08-28 on wss://wspap.okx.com:8443/ws/v5/private:
          # arg.channel "orders", data[] carries state "live", code "0",
          # accFillSz "0". instType ANY also pushes other account orders, so
          # the matching row is picked by ordId. Authority: OKX API v5 Order
          # channel (https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-order-channel).
          placed_event = await_order_event!(placed.id, "live")

          assert placed_event["instId"] == "BTC-USDT-SWAP"
          assert placed_event["instType"] == "SWAP"
          assert placed_event["side"] == "buy"
          assert placed_event["ordType"] == "limit"
          assert placed_event["tdMode"] == "cross"
          assert placed_event["clOrdId"] == client_order_id
          assert placed_event["accFillSz"] == "0"
          assert placed_event["code"] == "0"

          assert {event_price, ""} = Float.parse(placed_event["px"])
          assert_in_delta event_price, price, 0.05
          assert {event_qty, ""} = Float.parse(placed_event["sz"])
          assert_in_delta event_qty, @amount, 1.0e-9

          {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
          assert canceled.id == placed.id

          # Observed live 2026-08-28: the same ordId returns state "canceled",
          # cancelSource "1" (user canceled). Authority: OKX API v5 Order
          # channel cancelSource `1`: Order canceled by user.
          cancel_event = await_order_event!(placed.id, "canceled")

          assert cancel_event["clOrdId"] == client_order_id
          assert cancel_event["cancelSource"] == "1"
          assert cancel_event["accFillSz"] == "0"
        after
          release_order!(exchange, placed.id, @symbol)
        end
      after
        WS.close(ws)
      end
    end
  end

  describe "orders the venue rejects" do
    test "an amount below the instrument lot size is refused with OKX's own error" do
      exchange = sandbox_exchange!(@venue)
      below_lot = market_min_amount(exchange) / 10
      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      assert [[best_bid, _bid_size] | _] = book.bids
      price = Float.round(best_bid * @resting_ratio, @price_decimals)

      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, @symbol, "limit", "buy", below_lot, price: price)

      # Observed live 2026-08-28 on www.okx.com with x-simulated-trading: POST
      # /api/v5/trade/order with sz "0.001" (BTC-USDT-SWAP lotSz/minSz 0.01)
      # answers envelope code "1", "All operations failed"; the per-order
      # outcome is data[0] sCode "51121", sMsg "Order quantity must be a
      # multiple of the lot size." Classification reads sCode, not the outer
      # envelope. Authority: OKX API v5 51121
      # (https://www.okx.com/docs-v5/en/#error-code).
      row = hd(error.raw["data"])
      assert error.type == :invalid_order
      assert error.code == "51121"
      assert error.message == "Order quantity must be a multiple of the lot size."
      assert row["sCode"] == "51121"
      assert row["sMsg"] == "Order quantity must be a multiple of the lot size."
    end
  end

  # OKX's private orders push is `{arg, data}` with no correlating id, so
  # zen_websocket hands it to the caller as `{:websocket_message, _}`. instType
  # ANY batches the whole account; the matching entry is picked out of `data`
  # by ordId instead of assumed to be at its head.
  defp await_order_event!(order_id, status) do
    await_order_event!(order_id, status, System.monotonic_time(:millisecond) + @frame_timeout_ms)
  end

  defp await_order_event!(order_id, status, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
    else
      receive do
        {:websocket_message, %{"arg" => %{"channel" => "orders"}, "data" => data}} when is_list(data) ->
          case Enum.find(data, &(&1["ordId"] == order_id and &1["state"] == status)) do
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

  # OKX clOrdId is alphanumeric, max 32. The shared helper inserts hyphens
  # (bybit/alpaca accept them); strip so the id stays wall-clock unique.
  defp unique_cl_ord_id(prefix) do
    prefix
    |> unique_client_order_id()
    |> String.replace("-", "")
    |> String.slice(0, 32)
  end

  defp market_min_amount(exchange) do
    market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
    market.limits["amount"]["min"]
  end
end
