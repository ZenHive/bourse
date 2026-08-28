defmodule Bourse.Journeys.Trader.HyperliquidTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.WS

  @moduletag :exchange_hyperliquid

  @venue :hyperliquid
  @symbol "BTC/USDC:USDC"
  @amount 0.001
  @resting_ratio "0.9"
  @order_topic "orderUpdates"
  @frame_timeout_ms 20_000

  describe "a trader's day" do
    test "survey the market, place a resting limit buy, track it, cancel it" do
      exchange = sandbox_exchange!(@venue)

      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      assert market, "#{@symbol} missing from loaded hyperliquid markets"
      assert market.active
      assert market.contract and market.linear and market.settle == "USDC"
      assert is_number(market.precision["price"]) and market.precision["price"] > 0
      assert is_number(market.precision["amount"]) and market.precision["amount"] > 0
      assert market.limits["cost"]["min"] == 10
      assert market.precision["amount"] <= @amount

      {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol)
      assert ticker.symbol == @symbol
      # Observed live 2026-08-28: last/mark and impact bid/ask are populated;
      # timestamp, high, and low are nil. The book is the spread authority.
      assert is_number(ticker.last) and ticker.last > 0
      assert is_number(ticker.mark_price) and ticker.mark_price > 0
      assert ticker.bid > 0 and ticker.ask > 0 and ticker.bid <= ticker.ask

      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      assert [best_bid, bid_size] = hd(book.bids)
      assert [best_ask, ask_size] = hd(book.asks)
      assert best_bid <= best_ask
      assert bid_size > 0 and ask_size > 0

      {:ok, balance} = require_margin!(exchange)
      assert_recent_timestamp!(balance.timestamp)

      for {currency, total} <- balance.total, is_number(total) do
        free = balance.free[currency] || 0.0
        used = balance.used[currency] || 0.0
        assert free >= 0 and used >= 0, "#{currency}: negative balance component"
        assert_in_delta free + used, total, 0.01
      end

      price = resting_price(best_bid, market)
      cloid = unique_cloid()

      {:ok, placed} =
        Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
          price: price,
          clientOrderId: cloid
        )

      assert is_binary(placed.id) and placed.id != ""
      assert placed.client_order_id == cloid

      try do
        order =
          poll_until!("order #{placed.id} visible as open", fn ->
            case find_open_order(exchange, placed.id) do
              %Order{status: "open"} = order -> {:ok, order}
              %Order{} -> :retry
              nil -> :retry
            end
          end)

        assert order.side == "buy"
        assert order.type == "limit"
        assert order.client_order_id == cloid
        assert_in_delta order.price, price, market.precision["price"] / 2
        assert_in_delta order.amount, @amount, 1.0e-9

        {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
        assert Enum.any?(open_orders, &(&1.id == placed.id)), "resting order missing from open orders"

        {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
        # Observed live 2026-08-28: cancel ack is statuses: ["success"], parsed
        # as %Order{status: "canceled"} with no oid echo.
        assert canceled.status == "canceled"

        poll_until!("order #{placed.id} gone from open orders", fn ->
          if find_open_order(exchange, placed.id), do: :retry, else: {:ok, :gone}
        end)
      after
        cleanup_order!(exchange, placed.id)
      end
    end
  end

  describe "a trader watching the private order stream" do
    test "the order's own lifecycle arrives on the stream, place and cancel" do
      exchange = sandbox_exchange!(@venue)
      _ = require_margin!(exchange)

      # Hyperliquid authors no private WS URL; private data is the public
      # socket scoped by address (no auth handshake). Authority:
      # https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions
      assert {:error, :no_url_configured} = WS.connect(exchange, :private)
      {:ok, ws} = WS.connect(exchange, :public)

      try do
        assert is_nil(ws.auth)

        user = exchange.credentials.api_key

        assert :ok =
                 WS.subscribe(ws, [%{"type" => @order_topic, "user" => user}], ack_timeout_ms: 8_000)

        {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
        assert [[best_bid, _bid_size] | _] = book.bids
        market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
        price = resting_price(best_bid, market)
        cloid = unique_cloid()

        {:ok, placed} =
          Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
            price: price,
            clientOrderId: cloid
          )

        assert is_binary(placed.id) and placed.id != ""

        try do
          # Observed live 2026-08-28 against wss://api.hyperliquid-testnet.xyz/ws:
          # channel "orderUpdates", data[0] status "open", order.coin "BTC",
          # order.side "B", order.cloid the 128-bit hex we sent.
          placed_event = await_order_event!(placed.id, "open")
          placed_order = placed_event["order"]

          assert placed_order["coin"] == "BTC"
          assert placed_order["side"] == "B"
          assert placed_order["cloid"] == cloid
          assert to_string(placed_order["oid"]) == placed.id

          assert {event_price, ""} = Float.parse(placed_order["limitPx"])
          assert_in_delta event_price, price, market.precision["price"] / 2
          assert {event_qty, ""} = Float.parse(placed_order["origSz"])
          assert_in_delta event_qty, @amount, 1.0e-9

          {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
          assert canceled.status == "canceled"

          # Observed live 2026-08-28: the same oid returns status "canceled"
          # (docs: "Canceled by user"). origSz/sz stay at the placed size.
          cancel_event = await_order_event!(placed.id, "canceled")
          cancel_order = cancel_event["order"]

          assert cancel_order["cloid"] == cloid
          assert to_string(cancel_order["oid"]) == placed.id
          assert {cancel_qty, ""} = Float.parse(cancel_order["origSz"])
          assert_in_delta cancel_qty, @amount, 1.0e-9
        after
          cleanup_order!(exchange, placed.id)
        end
      after
        WS.close(ws)
      end
    end
  end

  describe "orders the venue rejects" do
    test "a notional below the instrument minimum is refused with hyperliquid's own error" do
      exchange = sandbox_exchange!(@venue)
      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
      [[best_bid, _] | _] = book.bids
      below_min = market.precision["amount"]

      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, @symbol, "limit", "buy", below_min, price: resting_price(best_bid, market))

      # Observed live 2026-08-28 against api.hyperliquid-testnet.xyz: HTTP 200
      # envelope status "ok" with statuses[0].error
      # "Order must have minimum value of $10. asset=3".
      # Authority: MinTradeNtl at
      # https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/error-responses
      assert error.type == :exchange_error
      assert error.message =~ "minimum value of $10"
    end
  end

  defp require_margin!(exchange) do
    case Bourse.fetch_balance(exchange) do
      {:ok, balance} ->
        assert map_size(balance.total) > 0
        usdc = balance.total["USDC"] || 0.0

        if not is_number(usdc) or usdc < 10 do
          flunk("""
          Hyperliquid testnet wallet holds no usable margin (USDC total=#{inspect(usdc)}).
          Claim the testnet drip (re-claimable every 4h):

            POST https://api.hyperliquid-testnet.xyz/info
            {"type":"claimDrip","user":"<wallet address>"}

          Unlocked by a ≥5 native-USDC mainnet Bridge2 deposit from the same address.
          """)
        end

        {:ok, balance}

      {:error, error} ->
        flunk("fetch_balance failed: #{inspect(error)}")
    end
  end

  defp find_open_order(exchange, order_id) do
    case Bourse.fetch_open_orders(exchange, symbol: @symbol) do
      {:ok, orders} -> Enum.find(orders, &(&1.id == order_id))
      {:error, error} -> flunk("fetch_open_orders failed: #{inspect(error)}")
    end
  end

  # Case.release_order! swallows :order_not_found / :invalid_order. Observed
  # live 2026-08-28: a second cancel of this oid is HTTP 200 MissingOrder,
  # classified :exchange_error ("Order was never placed, already canceled, or
  # filled. asset=N") — that helper would flunk the after block.
  defp cleanup_order!(exchange, id) do
    case Bourse.cancel_order(exchange, id, symbol: @symbol) do
      {:ok, %Order{}} ->
        :ok

      {:error, %Error{type: type}} when type in [:order_not_found, :invalid_order] ->
        :ok

      {:error, %Error{type: :exchange_error, message: message} = error} ->
        if is_binary(message) and String.contains?(message, "never placed") do
          :ok
        else
          flunk("cleanup for order #{id} failed: #{inspect(error)}")
        end

      {:error, error} ->
        flunk("cleanup for order #{id} failed: #{inspect(error)}")
    end
  end

  # Hyperliquid cloid is a 128-bit hex string (0x + 32 hex), not an arbitrary
  # prefix. Mix wall-clock with entropy so two journeys in the same millisecond
  # cannot collide. Authority:
  # https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint
  defp unique_cloid do
    stamp =
      :millisecond
      |> System.system_time()
      |> rem(0x1_0000_0000_0000)
      |> Integer.to_string(16)
      |> String.pad_leading(12, "0")
      |> String.downcase()

    "0x" <> stamp <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
  end

  defp resting_price(best_bid, market) do
    tick = Decimal.from_float(market.precision["price"])

    best_bid
    |> Decimal.from_float()
    |> Decimal.mult(Decimal.new(@resting_ratio))
    |> Decimal.div(tick)
    |> Decimal.round(0, :down)
    |> Decimal.mult(tick)
    |> Decimal.to_float()
  end

  defp await_order_event!(order_id, status) do
    await_order_event!(order_id, status, System.monotonic_time(:millisecond) + @frame_timeout_ms)
  end

  defp await_order_event!(order_id, status, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
    else
      receive do
        {:websocket_message, %{"channel" => @order_topic, "data" => data}} when is_list(data) ->
          case Enum.find(data, &match_order_event?(&1, order_id, status)) do
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

  defp match_order_event?(%{"order" => order, "status" => status}, order_id, expected) when is_map(order) do
    to_string(order["oid"]) == order_id and status == expected
  end

  defp match_order_event?(_frame, _order_id, _expected), do: false
end
