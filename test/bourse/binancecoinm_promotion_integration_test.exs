defmodule Bourse.BinancecoinmPromotionIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Bourse.ADLRank
  alias Bourse.Balance
  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.FundingRate
  alias Bourse.FundingRateHistory
  alias Bourse.LedgerEntry
  alias Bourse.LeverageTier
  alias Bourse.Market
  alias Bourse.OpenInterest
  alias Bourse.Order
  alias Bourse.OrderBook
  alias Bourse.Position
  alias Bourse.Test.FixtureGateIsolation
  alias Bourse.Ticker
  alias Bourse.Trade
  alias Bourse.TradingFee

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_binancecoinm

  @credentials_url "https://demo.binance.com/en/my/settings/api-management"
  @demo_host "demo-dapi.binance.com"
  @symbol "BTC/USD:BTC"
  @missing_configuration_symbol "ZZZ/USD:ZZZ"
  @native_symbol "BTCUSD_PERP"
  @order_amount 1
  @oversized_order_amount 100
  @resting_price_ratio 0.5
  @price_rounding_digits 8
  @minimum_btc_balance 0.01
  @minimum_asset_rows 40
  @public_limit 5

  setup do
    FixtureGateIsolation.isolate!("binancecoinm")
    :ok
  end

  test "live DAPI markets, ticker, order book, trades, and funding preserve inverse semantics" do
    exchange = public_exchange!()
    market = market!(exchange, @symbol)

    assert %Market{
             id: @native_symbol,
             symbol: @symbol,
             base: "BTC",
             quote: "USD",
             settle: "BTC",
             type: "swap",
             swap: true,
             contract: true,
             linear: false,
             inverse: true,
             contract_size: 100
           } = market

    assert market.precision["amount"] == 1
    assert market.limits["amount"]["min"] == 1

    assert %Market{type: "future", future: true, settle: settle, expiry: expiry} =
             dated = Enum.find(exchange.markets, &(&1.base == "BTC" and &1.future and &1.active))

    assert settle == dated.base
    assert is_integer(expiry) and expiry > System.system_time(:millisecond)
    assert Regex.match?(~r/^BTC\/USD:BTC-\d{6}$/, dated.symbol)

    assert {:ok, %Ticker{symbol: @symbol, last: last}} = Bourse.fetch_ticker(exchange, @symbol)
    assert is_number(last) and last > 0

    assert {:ok, %OrderBook{symbol: @symbol, bids: bids, asks: asks}} =
             Bourse.fetch_order_book(exchange, @symbol, limit: @public_limit)

    assert match?([[_bid_price, _bid_contracts] | _], bids)
    assert match?([[_ask_price, _ask_contracts] | _], asks)

    assert OrderBook.best_bid(%OrderBook{bids: bids, asks: asks}) <
             OrderBook.best_ask(%OrderBook{bids: bids, asks: asks})

    assert {:ok, [%Trade{symbol: @symbol} | _] = trades} =
             Bourse.fetch_trades(exchange, @symbol, limit: @public_limit)

    assert Enum.all?(trades, &(is_number(&1.price) and is_number(&1.amount) and &1.amount > 0))

    assert {:ok,
            %FundingRate{
              symbol: @symbol,
              mark_price: mark_price,
              index_price: index_price,
              funding_rate: funding_rate,
              next_funding_timestamp: next_funding_timestamp
            }} = Bourse.fetch_funding_rate(exchange, @symbol)

    assert is_number(mark_price) and mark_price > 0
    assert is_number(index_price) and index_price > 0
    assert is_number(funding_rate)
    assert is_integer(next_funding_timestamp) and next_funding_timestamp > 0

    assert {:ok, [%FundingRateHistory{symbol: @symbol} | _] = history} =
             Bourse.fetch_funding_rate_history(exchange, @symbol, limit: @public_limit)

    assert Enum.all?(history, &(is_number(&1.funding_rate) and is_integer(&1.timestamp)))
  end

  test "live DAPI private reads preserve account, position, order, and trade boundaries" do
    exchange = signed_exchange!()

    assert {:ok, %Balance{} = balance} = Bourse.fetch_balance(exchange)
    assert balance.total["BTC"] >= @minimum_btc_balance
    assert map_size(balance.total) >= @minimum_asset_rows
    assert MapSet.new(Map.keys(balance.total)) == MapSet.new(Map.keys(balance.free))

    assert {:ok, positions} = Bourse.fetch_positions(exchange)
    assert Enum.all?(positions, &match?(%Position{}, &1))
    assert Enum.all?(positions, &(is_number(&1.contracts) and &1.contracts != 0))

    assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
    assert Enum.all?(open_orders, &match?(%Order{}, &1))

    assert {:ok, my_trades} = Bourse.fetch_my_trades(exchange, symbol: @symbol, limit: @public_limit)
    assert Enum.all?(my_trades, &match?(%Trade{}, &1))

    assert {:ok, %{"dualSidePosition" => true}} = Bourse.fetch_position_mode(exchange)

    assert {:ok, %{body: %{"positions" => account_positions} = account}} =
             Bourse.Binancecoinm.dapiPrivate_get_account(exchange)

    assert is_list(account["assets"])
    assert is_list(account_positions)

    assert {:ok, %{body: position_risk}} =
             Bourse.Binancecoinm.dapiPrivate_get_positionrisk(exchange)

    assert is_list(position_risk)
    assert length(position_risk) > length(account_positions)
  end

  test "live DAPI configuration read errors when the account has no requested symbol row" do
    assert {:error, %Error{type: :exchange_error, message: message}} =
             Bourse.fetch_leverage(signed_exchange!(), @missing_configuration_symbol)

    assert String.contains?(message, @missing_configuration_symbol)
  end

  test "live DAPI order history and account analytics return unified values" do
    exchange = signed_exchange!()

    assert {:ok, orders} = Bourse.fetch_orders(exchange, symbol: @symbol)
    assert Enum.all?(orders, &match?(%Order{}, &1))
    assert orders != []

    assert {:ok, closed_orders} = Bourse.fetch_closed_orders(exchange, symbol: @symbol)
    assert Enum.all?(closed_orders, &match?(%Order{status: "closed"}, &1))

    assert {:ok, canceled_orders} = Bourse.fetch_canceled_orders(exchange, symbol: @symbol)
    assert Enum.all?(canceled_orders, &match?(%Order{status: "canceled"}, &1))

    assert {:ok, [%LeverageTier{} | _] = leverage_tiers} =
             Bourse.fetch_leverage_tiers(exchange, symbol: @symbol)

    assert Enum.all?(leverage_tiers, &(&1.symbol == @symbol))

    assert {:ok, %OpenInterest{symbol: @symbol, open_interest_amount: amount}} =
             Bourse.fetch_open_interest(exchange, @symbol)

    assert is_number(amount) and amount >= 0

    assert {:ok, %TradingFee{symbol: @symbol, maker: maker, taker: taker}} =
             Bourse.fetch_trading_fee(exchange, @symbol)

    assert is_number(maker) and maker >= 0
    assert is_number(taker) and taker >= 0

    assert {:error, %Error{type: :not_supported}} = Bourse.fetch_trading_fees(exchange)

    assert {:ok, ledger} = Bourse.fetch_ledger(exchange)
    assert Enum.all?(ledger, &match?(%LedgerEntry{}, &1))

    assert {:ok, adl_rank} = Bourse.fetch_adl_rank(exchange, symbol: @symbol)
    assert is_nil(adl_rank) or match?(%ADLRank{symbol: @symbol}, adl_rank)
  end

  test "live DAPI history and account analytics preserve provider errors" do
    exchange = signed_exchange!()
    invalid_symbol = "INVALID/USD:INVALID"

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.fetch_orders(exchange, symbol: invalid_symbol)

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.fetch_closed_orders(exchange, symbol: invalid_symbol)

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.fetch_canceled_orders(exchange, symbol: invalid_symbol)

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.fetch_leverage_tiers(exchange, symbol: invalid_symbol)

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.fetch_open_interest(exchange, invalid_symbol)

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.fetch_trading_fee(exchange, invalid_symbol)

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.fetch_adl_rank(exchange, symbol: invalid_symbol)

    assert {:error, %Error{type: :bad_request, code: -1130}} =
             Bourse.fetch_ledger(exchange, incomeType: "INVALID")
  end

  test "invalid API key is classified as authentication_error" do
    credentials = Credentials.new!(api_key: "invalid-task-450", secret: "invalid-task-450")
    exchange = Exchange.new!("binancecoinm", credentials: credentials, sandbox: true)
    assert_dapi_hosts!(exchange)

    assert {:error, %Error{type: :authentication_error, code: -2014}} =
             Bourse.fetch_balance(exchange)
  end

  @tag :dangerous
  test "safe far-from-market order create, fetch, and cancel lifecycle has targeted cleanup" do
    exchange = signed_exchange!()
    market = market!(exchange, @symbol)
    price = resting_price!(exchange, market)
    client_order_id = client_order_id()
    cleanup_key = {__MODULE__, client_order_id}
    Process.put(cleanup_key, true)

    try do
      assert {:ok, %Order{id: order_id, client_order_id: ^client_order_id} = created} =
               Bourse.create_order(exchange, @symbol, "limit", "buy", @order_amount,
                 price: price,
                 positionSide: "LONG",
                 timeInForce: "GTC",
                 newClientOrderId: client_order_id
               )

      assert is_binary(order_id) and order_id != ""
      assert created.symbol == @symbol
      assert created.side == "buy"
      assert created.type == "limit"
      assert created.amount == @order_amount
      assert created.price == price
      assert created.status == "open"
      assert created.info["pair"] == "BTCUSD"
      assert created.info["positionSide"] == "LONG"

      assert {:ok, %Order{id: ^order_id, status: "open"} = fetched} =
               Bourse.fetch_order(exchange, order_id, symbol: @symbol)

      assert fetched.info["avgPrice"] in ["0", "0.0", "0.00"]

      assert {:ok, %Order{id: ^order_id, status: "canceled"}} =
               Bourse.cancel_order(exchange, order_id, symbol: @symbol)

      assert {:ok, orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
      refute Enum.any?(orders, &(&1.client_order_id == client_order_id))
      Process.put(cleanup_key, false)
    after
      if Process.delete(cleanup_key), do: cleanup_order!(exchange, client_order_id)
    end
  end

  @tag :dangerous
  test "hedge-mode and margin rejections preserve the observed DAPI business errors" do
    exchange = signed_exchange!()
    market = market!(exchange, @symbol)
    price = resting_price!(exchange, market)

    assert {:ok, %{"dualSidePosition" => true}} = Bourse.fetch_position_mode(exchange)

    assert_rejected_order!(
      exchange,
      price,
      @order_amount,
      [],
      %Error{type: :operation_failed, code: -4061},
      "position side"
    )

    error =
      assert_rejected_order!(
        exchange,
        price,
        @oversized_order_amount,
        [positionSide: "LONG"],
        %Error{type: :insufficient_funds, code: -2019},
        "Margin is insufficient"
      )

    refute Error.should_retry?(error)
  end

  defp public_exchange! do
    exchange = Exchange.new!("binancecoinm", sandbox: true)
    assert_dapi_hosts!(exchange)
    {:ok, loaded} = Bourse.load_markets(exchange)
    loaded
  end

  defp signed_exchange! do
    credentials = require_credentials!()
    exchange = Exchange.new!("binancecoinm", credentials: credentials, sandbox: true)
    assert_dapi_hosts!(exchange)
    {:ok, loaded} = Bourse.load_markets(exchange)
    loaded
  end

  defp require_credentials! do
    api_key = System.get_env("BINANCE_FUTURES_TEST_API_KEY")
    secret = System.get_env("BINANCE_FUTURES_TEST_API_SECRET")

    if blank?(api_key) or blank?(secret) do
      flunk("""
      Missing Binance COIN-M demo credentials!

      Set these environment variables:
        export BINANCE_FUTURES_TEST_API_KEY="your_key"
        export BINANCE_FUTURES_TEST_API_SECRET="your_secret"

      Get credentials at: #{@credentials_url}
      """)
    end

    Credentials.new!(api_key: api_key, secret: secret, sandbox: true)
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

  defp assert_dapi_hosts!(exchange) do
    for section <- ~w(dapiPublic dapiPrivate dapiPrivateV2) do
      assert URI.parse(exchange.base_urls[section]).host == @demo_host
    end
  end

  defp market!(%Exchange{markets: markets}, symbol) do
    assert %Market{} = market = Enum.find(markets, &(&1.symbol == symbol))
    market
  end

  defp resting_price!(exchange, market) do
    assert {:ok, %FundingRate{mark_price: mark_price}} = Bourse.fetch_funding_rate(exchange, market.symbol)
    tick_size = market.precision["price"]
    assert is_number(tick_size) and tick_size > 0

    mark_price
    |> Kernel.*(@resting_price_ratio)
    |> Kernel./(tick_size)
    |> Float.floor()
    |> Kernel.*(tick_size)
    |> Float.round(@price_rounding_digits)
  end

  defp client_order_id do
    "ccxt450-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp assert_rejected_order!(exchange, price, amount, opts, expected, message_fragment) do
    client_order_id = client_order_id()
    cleanup_key = {__MODULE__, client_order_id}
    Process.put(cleanup_key, true)

    try do
      result =
        Bourse.create_order(
          exchange,
          @symbol,
          "limit",
          "buy",
          amount,
          Keyword.merge(
            [
              price: price,
              timeInForce: "GTC",
              newClientOrderId: client_order_id
            ],
            opts
          )
        )

      assert {:error, %Error{} = error} = result
      assert error.type == expected.type
      assert error.code == expected.code
      assert error.message =~ message_fragment
      error
    after
      cleanup_order!(exchange, client_order_id)
      Process.delete(cleanup_key)
    end
  end

  defp cleanup_order!(exchange, client_order_id) do
    case Bourse.Binancecoinm.dapiPrivate_delete_order(exchange, %{
           "symbol" => @native_symbol,
           "origClientOrderId" => client_order_id
         }) do
      {:ok, %{body: %{"status" => "CANCELED"}}} ->
        :ok

      {:error, %Error{code: code}} when code in [-2011, -2013] ->
        :ok

      other ->
        flunk("Binance COIN-M targeted cleanup failed for #{client_order_id}: #{inspect(other)}")
    end
  end
end
