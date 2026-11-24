defmodule Bourse.BinanceFamilyOrderBookSelectionTest do
  @moduledoc """
  Which Binance futures order book the unified order-list reads answer from.

  Binance futures keep two books per symbol: regular orders
  (`openOrders` / `allOrders`) and conditional algo orders
  (`openAlgoOrders` / `allAlgoOrders`). The unqualified `fetch_open_orders` /
  `fetch_orders` answer from the regular book only; the conditional book is
  the authored algo slot, selected with `endpoint_index`. Carve: C-T713a in
  `docs/authored-spec-carves/binanceusdm.md`.

  The two books also bound time differently (observed live on
  demo-fapi.binance.com, 2026-11-25): `allOrders` applies `endTime` to the
  order's creation time, `allAlgoOrders` applies it to the row's update time.
  A creation-time `until` therefore cannot be honoured on a read that merges
  the algo book, which is the second half of why the books are not merged.
  """
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.Unified
  alias Bourse.Unified.OrderOptions

  @moduletag :integration
  @moduletag :network
  @moduletag :dangerous

  # Authored unified slot order: `fapiPrivateGetOpenAlgoOrders` /
  # `fapiPrivateGetAllAlgoOrders` on USD-M, `dapiPrivateGetOpenAlgoOrders` on COIN-M.
  @usdm_algo_index 2
  @coinm_algo_index 0

  @usdm_symbol "BTC/USDT:USDT"
  # 0.002 BTC at 90% of the best bid clears USD-M MIN_NOTIONAL (journey, 2026-08-28).
  @usdm_amount 0.002
  @usdm_conditional_symbol "ETH/USDT:USDT"
  @usdm_conditional_amount 0.25
  @coinm_symbol "BTC/USD:BTC"
  @coinm_amount 1
  @resting_ratio 0.9
  @trigger_ratio "0.85"
  @price_decimals 1
  # Binance futures error -4165: "Maximum time interval is 7 days."
  @interval_error_code -4165
  @eight_days_ms 8 * 86_400_000
  @poll_attempts 20
  @poll_interval_ms 250

  describe "binanceusdm" do
    test "a resting limit order is in the unqualified open-orders and order-history reads" do
      exchange = sandbox!(:binanceusdm)
      placed = place_resting_limit!(exchange, @usdm_symbol, @usdm_amount)
      on_exit(fn -> release!(exchange, placed.id, @usdm_symbol) end)

      open = poll_open!(exchange, placed.id, symbol: @usdm_symbol)
      assert open.status == "open"
      assert open.type == "limit"
      assert open.side == "buy"
      assert is_nil(open.info["algoId"])

      assert {:ok, history} = Bourse.fetch_orders(exchange, symbol: @usdm_symbol)
      assert Enum.any?(history, &(&1.id == placed.id))

      assert {:ok, algo_open} = Bourse.fetch_open_orders(exchange, symbol: @usdm_symbol, endpoint_index: @usdm_algo_index)
      refute Enum.any?(algo_open, &(&1.id == placed.id))

      assert {:ok, %Order{id: id}} = Bourse.cancel_order(exchange, placed.id, symbol: @usdm_symbol)
      assert id == placed.id
      poll_gone!(exchange, placed.id, symbol: @usdm_symbol)

      # allOrders bounds endTime on creation time: a row created at T and
      # canceled later is inside `until: T`.
      row = history_row!(exchange, placed.id, symbol: @usdm_symbol)
      assert row.info["updateTime"] > row.timestamp

      assert {:ok, bounded} = Bourse.fetch_orders(exchange, symbol: @usdm_symbol, until: row.timestamp)
      assert Enum.any?(bounded, &(&1.id == placed.id))
      assert Enum.all?(bounded, &(&1.timestamp <= row.timestamp))

      assert {:ok, from} = Bourse.fetch_orders(exchange, symbol: @usdm_symbol, since: row.timestamp)
      assert Enum.any?(from, &(&1.id == placed.id))
      assert Enum.all?(from, &(&1.timestamp >= row.timestamp))
    end

    test "a resting conditional order is only in the explicit algo-book read" do
      exchange = sandbox!(:binanceusdm)
      id = place_conditional!(exchange, @usdm_conditional_symbol, @usdm_conditional_amount)
      on_exit(fn -> release!(exchange, id, @usdm_conditional_symbol) end)

      algo = [symbol: @usdm_conditional_symbol, endpoint_index: @usdm_algo_index]
      order = poll_open!(exchange, id, algo)
      assert order.type == "stop_market"
      assert order.info["algoType"] == "CONDITIONAL"
      assert order.info["algoStatus"] == "NEW"

      assert {:ok, regular_open} = Bourse.fetch_open_orders(exchange, symbol: @usdm_conditional_symbol)
      refute Enum.any?(regular_open, &(&1.id == id))

      assert {:ok, regular_history} = Bourse.fetch_orders(exchange, symbol: @usdm_conditional_symbol)
      refute Enum.any?(regular_history, &(&1.id == id))

      assert {:ok, %Order{status: "canceled"}} = Bourse.cancel_order(exchange, id, symbol: @usdm_conditional_symbol)
      poll_gone!(exchange, id, algo)

      # allAlgoOrders bounds startTime on creation time but endTime on update
      # time: the canceled row is outside [createTime, createTime] and inside
      # [createTime, updateTime]. Both edges are sent because an endTime-only
      # algo read pages from the oldest rows of the window, not the newest.
      row = history_row!(exchange, id, algo)
      created = row.info["createTime"]
      updated = row.info["updateTime"]
      assert row.timestamp == created
      assert updated > created

      history_row!(exchange, id, algo ++ [since: created, until: updated])

      assert {:ok, by_created} = Bourse.fetch_orders(exchange, algo ++ [since: created, until: created])
      refute Enum.any?(by_created, &(&1.id == id))
    end

    test "an order-history window wider than seven days is the venue's -4165" do
      exchange = sandbox!(:binanceusdm)
      until = System.system_time(:millisecond)

      assert {:error, %Error{type: :bad_request, code: @interval_error_code, message: message}} =
               Bourse.fetch_orders(exchange, symbol: @usdm_symbol, since: until - @eight_days_ms, until: until)

      assert message =~ "7 days"
    end
  end

  describe "binancecoinm" do
    test "the unqualified open-orders read holds the resting limit, the algo slot holds the conditional" do
      exchange = sandbox!(:binancecoinm)
      placed = place_resting_limit!(exchange, @coinm_symbol, @coinm_amount)
      on_exit(fn -> release!(exchange, placed.id, @coinm_symbol) end)

      open = poll_open!(exchange, placed.id, symbol: @coinm_symbol)
      assert open.type == "limit"
      assert is_nil(open.info["algoId"])

      algo = [symbol: @coinm_symbol, endpoint_index: @coinm_algo_index]
      assert {:ok, algo_open} = Bourse.fetch_open_orders(exchange, algo)
      refute Enum.any?(algo_open, &(&1.id == placed.id))

      conditional_id = place_conditional!(exchange, @coinm_symbol, @coinm_amount)
      on_exit(fn -> release!(exchange, conditional_id, @coinm_symbol) end)

      conditional = poll_open!(exchange, conditional_id, algo)
      assert conditional.type == "stop_market"
      assert conditional.info["algoType"] == "CONDITIONAL"

      assert {:ok, regular_open} = Bourse.fetch_open_orders(exchange, symbol: @coinm_symbol)
      refute Enum.any?(regular_open, &(&1.id == conditional_id))

      assert {:ok, _} = Bourse.cancel_order(exchange, conditional_id, symbol: @coinm_symbol)
      poll_gone!(exchange, conditional_id, algo)

      assert {:ok, _} = Bourse.cancel_order(exchange, placed.id, symbol: @coinm_symbol)
      poll_gone!(exchange, placed.id, symbol: @coinm_symbol)
    end
  end

  defp sandbox!(venue) do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(venue, credentials: credentials, sandbox: true)

    case Bourse.load_markets(exchange) do
      {:ok, loaded} -> loaded
      {:error, error} -> flunk("#{venue}: load_markets failed: #{inspect(error)}")
    end
  end

  defp place_resting_limit!(exchange, symbol, amount) do
    assert {:ok, book} = Bourse.fetch_order_book(exchange, symbol)
    assert [[best_bid, _size] | _] = book.bids
    price = Float.round(best_bid * @resting_ratio, @price_decimals)

    assert {:ok, %Order{id: id} = placed} =
             Bourse.create_order(exchange, symbol, "limit", "buy", amount,
               price: price,
               time_in_force: "GTC",
               clientOrderId: "t713-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
             )

    assert is_binary(id) and id != ""
    placed
  end

  # A stop-market sell 15% under mark. The route is asserted before sending,
  # so a request that would reach the regular book as a market order never leaves.
  defp place_conditional!(exchange, symbol, amount) do
    assert {:ok, ticker} = Bourse.fetch_ticker(exchange, symbol)
    market = Enum.find(exchange.markets, &(&1.symbol == symbol))
    tick = Decimal.new(to_string(market.precision["price"]))

    trigger =
      (ticker.mark_price || ticker.last)
      |> to_string()
      |> Decimal.new()
      |> Decimal.mult(Decimal.new(@trigger_ratio))
      |> Decimal.div(tick)
      |> Decimal.round(0, :floor)
      |> Decimal.mult(tick)
      |> Decimal.to_float()

    extras = [trigger_price: trigger, reduce_only: false]
    params = Unified.build_params([:symbol, :type, :side, :amount], [symbol, "market", "sell", amount], extras)
    assert {:ok, prepared} = OrderOptions.prepare(exchange, :create_order, params)
    assert {:ok, [shape]} = Unified.request_param_shapes(exchange, :create_order, prepared)
    assert shape["algoType"] == "CONDITIONAL"
    assert shape["type"] == "STOP_MARKET"

    assert {:ok, %Order{id: id}} = Bourse.create_order(exchange, symbol, "market", "sell", amount, extras)
    assert is_binary(id) and id != ""
    id
  end

  defp poll_open!(exchange, id, opts, attempts \\ @poll_attempts)

  defp poll_open!(_exchange, id, opts, 0), do: flunk("order #{id} never appeared in fetch_open_orders(#{inspect(opts)})")

  defp poll_open!(exchange, id, opts, attempts) do
    assert {:ok, orders} = Bourse.fetch_open_orders(exchange, opts)

    case Enum.find(orders, &(&1.id == id)) do
      %Order{} = order ->
        order

      nil ->
        Process.sleep(@poll_interval_ms)
        poll_open!(exchange, id, opts, attempts - 1)
    end
  end

  defp poll_gone!(exchange, id, opts, attempts \\ @poll_attempts)

  defp poll_gone!(_exchange, id, opts, 0), do: flunk("order #{id} still in fetch_open_orders(#{inspect(opts)})")

  defp poll_gone!(exchange, id, opts, attempts) do
    assert {:ok, orders} = Bourse.fetch_open_orders(exchange, opts)

    if Enum.any?(orders, &(&1.id == id)) do
      Process.sleep(@poll_interval_ms)
      poll_gone!(exchange, id, opts, attempts - 1)
    else
      :ok
    end
  end

  # Order history trails cancels and time filters by a moment, so poll until
  # the row is present in its canceled state.
  defp history_row!(exchange, id, opts, attempts \\ @poll_attempts)

  defp history_row!(_exchange, id, opts, 0),
    do: flunk("canceled order #{id} never appeared in fetch_orders(#{inspect(opts)})")

  defp history_row!(exchange, id, opts, attempts) do
    assert {:ok, orders} = Bourse.fetch_orders(exchange, opts)

    case Enum.find(orders, &(&1.id == id)) do
      %Order{status: "canceled"} = row ->
        row

      _pending ->
        Process.sleep(@poll_interval_ms)
        history_row!(exchange, id, opts, attempts - 1)
    end
  end

  defp release!(exchange, id, symbol) do
    case Bourse.cancel_order(exchange, id, symbol: symbol) do
      {:ok, _} -> :ok
      {:error, %Error{type: type}} when type in [:order_not_found, :invalid_order] -> :ok
      {:error, error} -> flunk("cleanup cancel of #{id} failed: #{inspect(error)}")
    end
  end
end
