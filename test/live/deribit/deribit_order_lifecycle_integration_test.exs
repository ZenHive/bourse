defmodule Bourse.DeribitOrderLifecycleIntegrationTest do
  @moduledoc """
  Provider-live Deribit order identity, fill fees, and closed-order 11044.

  Observed 2026-09-15 on test.deribit.com before the authored fix: direct
  `parse_order` dropped `instrument_name`, `parse_trade` left fee cost/currency
  nil despite `fee`/`fee_currency`, and a second cancel classified 11044 as
  InvalidOrder. Authority: Deribit order/trade `instrument_name`, user-trade
  `fee` in units of `fee_currency`, and errors 11044 `not_open_order`.
  """
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.HTTP.Errors
  alias Bourse.Order
  alias Bourse.Test.LiveGateIsolation
  alias Bourse.Trade
  alias Bourse.WS

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_deribit

  @instrument_id "BTC-PERPETUAL"
  @symbol "BTC/USD:BTC"
  @amount 10.0
  @resting_ratio 0.9
  @order_channel "user.orders.BTC-PERPETUAL.raw"
  @frame_timeout_ms 20_000

  setup do
    LiveGateIsolation.isolate!("deribit")
    :ok
  end

  test "a live fill exposes provider fee cost/currency through parse_trade and fetch_my_trades" do
    exchange = loaded_sandbox!()

    assert {:ok, trades} = Bourse.fetch_my_trades(exchange, symbol: @symbol, limit: 10)

    trade =
      Enum.find(trades, fn %Trade{info: info} ->
        is_map(info) and is_number(info["fee"]) and is_binary(info["fee_currency"])
      end)

    assert trade,
           "this testnet account has no BTC-PERPETUAL fill carrying fee/fee_currency; " <>
             "place a sandbox fill then re-run. export DERIBIT_TESTNET_API_KEY and " <>
             "DERIBIT_TESTNET_API_SECRET against https://test.deribit.com"

    # Provider: fee is in units of fee_currency and may be signed (rebate < 0).
    # https://docs.deribit.com/api-reference/trading/private-get_user_trades_by_instrument
    raw_cost = trade.info["fee"]
    raw_currency = trade.info["fee_currency"]
    assert is_number(raw_cost)
    assert raw_currency != ""
    assert trade.symbol == @symbol

    assert_provider_fee!(trade.fee, trade.fees, raw_cost, raw_currency)

    assert {:ok, %Trade{} = parsed} = Bourse.Deribit.parse_trade(trade.info)
    assert parsed.symbol == trade.info["instrument_name"]
    assert_provider_fee!(parsed.fee, parsed.fees, raw_cost, raw_currency)

    {:ok, %Order{} = filled} = Bourse.fetch_order(exchange, trade.order_id, symbol: @symbol)
    assert filled.symbol == @symbol
    assert filled.status == "closed"
    # The order object does not carry a fee; do not invent an aggregate.
    assert is_nil(filled.fee)

    assert {:ok, %Order{} = parsed_order} = Bourse.Deribit.parse_order(filled.info)
    assert parsed_order.symbol == @instrument_id
    assert parsed_order.symbol == filled.info["instrument_name"]
    assert market_symbol!(exchange, parsed_order.symbol) == @symbol
  end

  @tag :dangerous
  test "a sandbox order keeps instrument identity through parse, unified writes, and WS; 11044 is order_not_found" do
    exchange = loaded_sandbox!()
    market = Enum.find(exchange.markets, &(&1.id == @instrument_id))
    assert market, "#{@instrument_id} missing from loaded deribit markets"
    assert market.symbol == @symbol
    tick = market.precision["price"]
    assert is_number(tick) and tick > 0

    {:ok, book} = Bourse.fetch_order_book(exchange, @symbol)
    assert [[best_bid, _size] | _] = book.bids
    price = resting_price(best_bid, tick)
    label = unique_label("t695")

    {:ok, ws} = WS.connect(exchange, :private)

    try do
      assert :ok = WS.subscribe(ws, [@order_channel])

      {:ok, placed} =
        Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
          price: price,
          clientOrderId: label
        )

      try do
        assert placed.symbol == @symbol
        assert placed.status == "open"
        assert is_nil(placed.fee)
        assert placed.info["instrument_name"] == @instrument_id

        assert {:ok, %Order{} = direct} = Bourse.Deribit.parse_order(placed.info)
        assert direct.symbol == @instrument_id
        assert market_symbol!(exchange, direct.symbol) == @symbol

        {:ok, fetched} = Bourse.fetch_order(exchange, placed.id, symbol: @symbol)
        assert fetched.symbol == @symbol
        assert fetched.status == "open"

        frame = await_order_event!(placed.id, "open")
        assert frame["instrument_name"] == @instrument_id
        assert {:ok, %Order{} = from_ws} = Bourse.Deribit.parse_order(frame)
        assert from_ws.symbol == @instrument_id
        assert from_ws.id == placed.id
        assert market_symbol!(exchange, from_ws.symbol) == @symbol

        {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
        assert canceled.id == placed.id
        assert canceled.symbol == @symbol
        assert canceled.status == "canceled"

        {:ok, after_cancel} = Bourse.fetch_order(exchange, placed.id, symbol: @symbol)
        assert after_cancel.status == "canceled"
        assert after_cancel.symbol == @symbol

        assert {:error, %Error{} = rest_11044} =
                 Bourse.cancel_order(exchange, placed.id, symbol: @symbol)

        # Observed live 2026-09-15: private/cancel of a just-canceled GTC
        # answers 11044 not_open_order. Same code on private/edit.
        # Authority: https://docs.deribit.com/articles/errors — 11044.
        # The code is not proof of canceled vs filled; fetch_order above is.
        assert rest_11044.type == :order_not_found
        assert rest_11044.code == 11_044
        assert rest_11044.message =~ "not_open_order"

        assert {:error, %Error{type: :order_not_found, code: 11_044}} =
                 Bourse.edit_order(exchange, placed.id, @symbol, "limit", "buy",
                   amount: @amount,
                   price: price
                 )

        ws_cancel = %{
          "jsonrpc" => "2.0",
          "id" => System.unique_integer([:positive]),
          "method" => "private/cancel",
          "params" => %{"order_id" => placed.id}
        }

        assert {:ok, ws_body} = WS.send_message(ws, ws_cancel)
        assert ws_body["error"]["code"] == 11_044
        assert ws_body["error"]["message"] == "not_open_order"

        assert {:error, %Error{type: :order_not_found, code: 11_044}} =
                 Errors.classify_response(:get, 200, %{}, ws_body, exchange)
      after
        release_order(exchange, placed.id)
      end

      native_label = unique_label("t695n")

      {:ok, native_placed} =
        Bourse.create_order(exchange, @instrument_id, "limit", "buy", @amount,
          price: price,
          clientOrderId: native_label
        )

      try do
        assert native_placed.symbol == @symbol
        assert native_placed.info["instrument_name"] == @instrument_id
        {:ok, native_canceled} = Bourse.cancel_order(exchange, native_placed.id, symbol: @instrument_id)
        assert native_canceled.symbol == @symbol
        assert native_canceled.status == "canceled"
      after
        release_order(exchange, native_placed.id)
      end
    after
      WS.close(ws)
    end
  end

  defp loaded_sandbox! do
    credentials = Bourse.Testnet.creds!(:deribit)
    {:ok, exchange} = Bourse.Exchange.new("deribit", credentials: credentials, sandbox: true)

    case Bourse.load_markets(exchange) do
      {:ok, loaded} -> loaded
      {:error, error} -> flunk("deribit load_markets failed against test.deribit.com: #{inspect(error)}")
    end
  end

  defp assert_provider_fee!(fee, fees, raw_cost, raw_currency) do
    assert is_map(fee)
    refute is_struct(fee)
    assert fee["currency"] == raw_currency
    # Preserve the provider sign (rebates are negative) and magnitude.
    assert_in_delta fee["cost"], raw_cost, abs(raw_cost) * 1.0e-12 + 1.0e-18

    assert is_list(fees) and fees != []
    [first | _rest] = fees
    assert first["currency"] == raw_currency
    assert_in_delta first["cost"], raw_cost, abs(raw_cost) * 1.0e-12 + 1.0e-18
  end

  defp market_symbol!(exchange, native) do
    market = Enum.find(exchange.markets, &(&1.id == native))
    assert market, "no loaded market whose id is #{inspect(native)}"
    market.symbol
  end

  defp resting_price(best_bid, tick) do
    Float.round(best_bid * @resting_ratio / tick) * tick
  end

  defp unique_label(prefix) do
    "#{prefix}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp release_order(exchange, id) do
    case Bourse.cancel_order(exchange, id, symbol: @symbol) do
      {:ok, %Order{}} -> :ok
      {:error, %Error{type: :order_not_found}} -> :ok
      {:error, %Error{code: code}} when code in [11_044, "11044"] -> :ok
      {:error, error} -> flunk("cleanup for order #{id} failed: #{inspect(error)}")
    end
  end

  defp await_order_event!(order_id, order_state) do
    deadline = System.monotonic_time(:millisecond) + @frame_timeout_ms
    await_user_order_frame(to_string(order_id), order_state, deadline)
  end

  defp await_user_order_frame(order_id, order_state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("timed out waiting for Deribit #{order_state} user.orders frame #{order_id}")
    else
      receive do
        {:websocket_message, %{"params" => %{"data" => %{"order_id" => ^order_id, "order_state" => ^order_state} = row}}} ->
          row

        _ignored ->
          await_user_order_frame(order_id, order_state, deadline)
      after
        remaining ->
          flunk("timed out waiting for Deribit #{order_state} user.orders frame #{order_id}")
      end
    end
  end
end
