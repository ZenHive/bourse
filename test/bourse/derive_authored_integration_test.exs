defmodule Bourse.DeriveAuthoredIntegrationTest do
  @moduledoc """
  Live Derive testnet pins for task 210 (authored/frozen derive slice).

  Authority: api-demo.lyra.finance + Derive REST auth (X-Lyra* header trio).
  Edge semantics (verified live): proxy verifies recovered signer against
  X-LyraWallet / session-key registry before the app — owner EOA is not
  auto-registered; mismatch is nginx HTML 403 (no JSON envelope).
  """
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Balance
  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.FundingRate
  alias Bourse.FundingRateHistory
  alias Bourse.Order
  alias Bourse.Safe
  alias Bourse.Test.FixtureGateIsolation
  alias Bourse.Ticker
  alias Bourse.Trade
  alias Bourse.TransferEntry
  alias Bourse.Unified.RequestShape.Derive, as: DeriveRequestShape

  @moduletag :integration
  @moduletag :network

  @derive_testnet_url "https://api-demo.lyra.finance"
  @perp_symbol "BTC/USD:USDC"
  @perp_instrument_name "BTC-PERP"
  @minimum_trade_to_ticker_ratio 0.5
  @maximum_trade_to_ticker_ratio 1.5
  @derive_subaccount_id 144_422
  @far_perp_limit_price 100
  @far_option_limit_price 0.1
  @order_max_fee "200"
  @perp_order_amount 0.1
  @edit_price_offset 10
  @option_amount 2
  @order_client_id "task473-create-label"

  setup do
    FixtureGateIsolation.isolate!("derive")
    :ok
  end

  test "public ticker parses from live testnet" do
    exchange = build_exchange(:derive, sandbox: true)

    assert {:ok, %Ticker{symbol: @perp_symbol, last: last}} = Bourse.fetch_ticker(exchange, @perp_symbol)
    assert last == nil or is_number(last)
  end

  test "missing public instrument parameter returns Derive's documented invalid-params code" do
    exchange = build_exchange(:derive, sandbox: true)

    assert {:error, %Error{type: :invalid_order, code: -32_602, message: message}} =
             Bourse.Derive.public_post_get_instrument(exchange, %{})

    assert message =~ "Invalid params"
  end

  test "public perp reads use Derive's instrument_name filter" do
    exchange = build_exchange(:derive, sandbox: true)

    assert {:ok, %Ticker{} = ticker} = Bourse.fetch_ticker(exchange, @perp_symbol)
    assert ticker.info["instrument_name"] == @perp_instrument_name
    ticker_price = ticker.last || ticker.mark_price
    assert is_number(ticker_price)

    assert {:ok, %FundingRate{symbol: @perp_symbol, funding_rate: funding_rate}} =
             Bourse.fetch_funding_rate(exchange, @perp_symbol)

    assert is_number(funding_rate)

    assert {:ok, [%FundingRateHistory{symbol: @perp_symbol} | _]} =
             Bourse.fetch_funding_rate_history(exchange, @perp_symbol)

    assert {:ok, [%Trade{symbol: @perp_symbol, price: trade_price} | _] = trades} =
             Bourse.fetch_trades(exchange, @perp_symbol)

    # `symbol` is stamped from the request, so it cannot witness the filter. The raw
    # venue field can: every row must be the instrument we asked for.
    assert Enum.uniq(Enum.map(trades, & &1.info["instrument_name"])) == [@perp_instrument_name]

    assert trade_price / ticker_price > @minimum_trade_to_ticker_ratio
    assert trade_price / ticker_price < @maximum_trade_to_ticker_ratio
  end

  test "signed get_all_portfolios preserves the SM collateral amount without inventing free or used" do
    credentials = require_credentials!(:derive, url: @derive_testnet_url)
    exchange = build_exchange(:derive, credentials: credentials, sandbox: true)

    assert {:ok, %Balance{} = balance} = Bourse.fetch_balance(exchange)

    portfolio =
      Enum.find(balance.info["result"], fn portfolio ->
        portfolio["subaccount_id"] == @derive_subaccount_id
      end)

    assert %{"margin_type" => "SM"} = portfolio
    eth = Enum.find(portfolio["collaterals"], &(&1["currency"] == "ETH"))

    assert balance.total["ETH"] == Safe.number(eth["amount"])
    assert balance.free["ETH"] == nil
    assert balance.used["ETH"] == nil
  end

  test "signed transfer history reaches live demo and returns typed entries" do
    credentials = require_credentials!(:derive, url: @derive_testnet_url)

    exchange =
      build_exchange(:derive,
        credentials: credentials,
        sandbox: true,
        options: %{"subaccount_id" => @derive_subaccount_id}
      )

    assert {:ok, transfers} = Bourse.fetch_transfers(exchange)
    assert is_list(transfers)
    assert Enum.all?(transfers, &match?(%TransferEntry{}, &1))
  end

  test "unregistered session key yields edge HTML 403 (access_restricted)" do
    # Wrong secret for a real-looking wallet: edge recovers a different signer
    # that is not registered for the wallet → nginx HTML 403 (no JSON envelope).
    credentials =
      Credentials.new!(
        api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
        secret: "0x0123456789012345678901234567890123456789012345678901234567890123",
        sandbox: true
      )

    exchange = build_exchange(:derive, credentials: credentials, sandbox: true)

    assert {:error, %Error{type: :access_restricted, code: 403}} = Bourse.fetch_balance(exchange)
  end

  @tag :dangerous
  test "signed labeled perpetual and dynamically discovered option orders create, read, and cancel" do
    credentials = require_credentials!(:derive, url: @derive_testnet_url)

    base =
      build_exchange(:derive,
        credentials: credentials,
        sandbox: true,
        options: %{"subaccount_id" => @derive_subaccount_id}
      )

    assert {:ok, exchange} = Bourse.load_markets(base)
    option = Enum.find(exchange.markets, &(&1.option and &1.active))

    assert %Bourse.Market{
             quantity_unit: "base",
             native_quantity_unit: "base",
             native_quantity_field: "amount",
             contract_size: nil,
             native_amount_step: amount_step,
             settle: settle,
             expiry: expiry,
             strike: strike,
             option_type: option_type
           } = option

    assert amount_step == Safe.number(option.info["amount_step"])
    assert option.precision["amount"] == amount_step
    assert is_binary(settle)
    assert is_integer(expiry)
    assert is_number(strike)
    assert option_type in ["call", "put"]

    assert_order_lifecycle(exchange, @perp_symbol, @perp_order_amount, @far_perp_limit_price, @perp_symbol)

    assert_order_lifecycle(exchange, option.symbol, @option_amount, @far_option_limit_price, option.symbol)

    invalid_amount = option.limits["amount"]["min"] + amount_step / 2

    request =
      DeriveRequestShape.build(
        %{
          "instrument_name" => option.symbol,
          "type" => "limit",
          "side" => "buy",
          "amount" => invalid_amount,
          "price" => @far_option_limit_price,
          "max_fee" => @order_max_fee,
          "subaccount_id" => @derive_subaccount_id,
          "clientOrderId" => "task397-invalid-quantity"
        },
        "createOrder",
        exchange
      )

    assert {:error, %Error{type: :invalid_order, code: 11_012, message: message}} =
             Bourse.Derive.private_post_order(exchange, request)

    assert message =~ "Amount must be a multiple of"
  end

  @tag :dangerous
  test "edit_order place-edit-cancel lifecycle leaves zero resting orders" do
    credentials = require_credentials!(:derive, url: @derive_testnet_url)

    base =
      build_exchange(:derive,
        credentials: credentials,
        sandbox: true,
        options: %{"subaccount_id" => @derive_subaccount_id}
      )

    assert {:ok, exchange} = Bourse.load_markets(base)

    create_price = @far_perp_limit_price
    edit_price = @far_perp_limit_price - @edit_price_offset

    try do
      assert {:ok, []} = Bourse.fetch_open_orders(exchange)

      assert {:ok, %Order{id: created_id, status: "open"}} =
               Bourse.create_order(exchange, @perp_symbol, "limit", "buy", @perp_order_amount,
                 price: create_price,
                 max_fee: @order_max_fee
               )

      assert {:ok, %Order{id: edited_id, status: "open"}} =
               Bourse.edit_order(exchange, created_id, @perp_symbol, "limit", "buy",
                 amount: @perp_order_amount,
                 price: edit_price,
                 max_fee: @order_max_fee
               )

      assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange)

      # Replace cancels the old order and opens a new one; open-orders is the
      # authority for the amended price/amount (ack fields may be partial).
      assert %Order{id: ^edited_id, price: live_price, amount: live_amount, status: "open"} =
               Enum.find(open_orders, &(&1.id == edited_id))

      assert live_price == edit_price
      assert live_amount == @perp_order_amount

      if created_id != edited_id do
        refute Enum.any?(open_orders, &(&1.id == created_id))
      end

      assert {:ok, %Order{id: ^edited_id, status: "canceled"}} =
               Bourse.cancel_order(exchange, edited_id, symbol: @perp_symbol)
    after
      # Runs even when an assertion fails — drain any leftover resting orders.
      cancel_all_open!(exchange)
      assert {:ok, []} = Bourse.fetch_open_orders(exchange)
    end
  end

  defp assert_order_lifecycle(exchange, symbol, amount, price, expected_read_symbol) do
    {:ok, %Order{id: id, status: "open"}} =
      Bourse.create_order(exchange, symbol, "limit", "buy", amount,
        price: price,
        max_fee: @order_max_fee,
        clientOrderId: @order_client_id
      )

    try do
      assert {:ok, orders} = Bourse.fetch_open_orders(exchange)

      assert %Order{
               id: ^id,
               symbol: ^expected_read_symbol,
               price: live_price,
               amount: live_amount,
               side: "buy",
               status: "open",
               info: %{"label" => @order_client_id}
             } = Enum.find(orders, &(&1.id == id))

      # `==` not a pin: a whole-number limit passed as an integer reads back as a float.
      assert live_price == price
      assert live_amount == amount
    after
      assert {:ok, %Order{id: ^id, status: "canceled"}} = Bourse.cancel_order(exchange, id, symbol: symbol)
    end
  end

  defp cancel_all_open!(exchange) do
    assert {:ok, orders} = Bourse.fetch_open_orders(exchange)

    Enum.each(orders, fn %Order{id: id, symbol: symbol} ->
      assert {:ok, %Order{id: ^id, status: "canceled"}} =
               Bourse.cancel_order(exchange, id, symbol: symbol)
    end)
  end
end
