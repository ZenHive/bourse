defmodule Bourse.BinanceAuthoredIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Balance
  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Greeks
  alias Bourse.Leverage
  alias Bourse.Order
  alias Bourse.OrderList
  alias Bourse.Position
  alias Bourse.Test.FixtureGateIsolation

  @binance_eapi_exchange_info_url "https://eapi.binance.com/eapi/v1/exchangeInfo"
  @usdm_lifecycle_symbol "BTC/USDT:USDT"
  @usdm_lifecycle_amount 0.002
  # Far enough below market to rest without filling, inside Binance's
  # PERCENT_PRICE_BY_SIDE band (a 20_000 bid trips -1013; observed 2026-07-17).
  @usdm_lifecycle_price 50_000
  @usdm_conditional_symbol "ETH/USDT:USDT"
  @usdm_conditional_native_symbol "ETHUSDT"
  @usdm_conditional_amount 0.02
  @usdm_conditional_trigger_ratio 0.85
  @usdm_conditional_limit_ratio 0.84
  @usdm_conditional_price_decimal_places 2
  @usdm_algo_read_amount 0.25
  @coinm_conditional_amount 1
  @coinm_conditional_trigger_ratio 0.85
  @coinm_conditional_price_decimal_places 1
  @usdm_flat_leverage_symbol "ETH/USDT:USDT"
  @coinm_flat_leverage_symbol "BTC/USD:BTC"
  @configured_leverage 3
  @cancel_all_order_count 2
  @legacy_conditional_probe_amount "0.001"
  @legacy_conditional_probe_price "1"
  @legacy_conditional_error_code -4120
  @bad_symbol_error_code -1121
  @missing_order_list_identifier_error_code -1102
  @spot_write_amount 0.001
  @spot_write_price 50_000
  @poll_attempts 10
  @poll_interval_ms 250
  @percentage_scale 100
  @percentage_precision 2
  @http_ok_status 200
  @usdm_convert_demo_error_code -1000
  @usdm_sapi_sandbox_error "No base URL for section sapi on binanceusdm (sandbox)"

  @moduletag :integration
  @moduletag :network

  setup do
    FixtureGateIsolation.isolate!("binance")
    FixtureGateIsolation.isolate!("binancecoinm")
    FixtureGateIsolation.isolate!("binanceusdm")
    :ok
  end

  test "spot and USD-M public reads select their native endpoint families" do
    spot = build_exchange(:binance, sandbox: true)
    usdm = build_exchange(:binanceusdm, sandbox: true)

    assert {:ok, %Bourse.Ticker{symbol: "BTC/USDT", last: spot_last}} =
             Bourse.fetch_ticker(spot, "BTC/USDT")

    assert is_number(spot_last) and spot_last > 0

    assert {:ok, %Bourse.Ticker{symbol: "BTC/USDT:USDT", last: usdm_last}} =
             Bourse.fetch_ticker(usdm, "BTC/USDT:USDT")

    assert is_number(usdm_last) and usdm_last > 0

    assert {:ok, spot_rows} = Bourse.fetch_ohlcv(spot, "BTC/USDT", "1m", limit: 2)
    assert {:ok, usdm_rows} = Bourse.fetch_ohlcv(usdm, "BTC/USDT:USDT", "1m", limit: 2)
    assert_ohlcv_rows(spot_rows)
    assert_ohlcv_rows(usdm_rows)

    assert {:ok, spot_trades} = Bourse.fetch_trades(spot, "BTC/USDT", limit: 2)
    assert {:ok, usdm_trades} = Bourse.fetch_trades(usdm, "BTC/USDT:USDT", limit: 2)
    assert_trade_rows(spot_trades)
    assert_trade_rows(usdm_trades)

    assert {:ok, spot_markets} = Bourse.fetch_markets(spot)
    assert {:ok, usdm_markets} = Bourse.fetch_markets(usdm)
    assert_market_precision(spot_markets, "BTCUSDT")
    assert_market_precision(usdm_markets, "BTCUSDT")

    assert_market_type_flags(spot_markets, "BTC/USDT",
      type: "spot",
      spot: true,
      contract: false,
      active: true
    )

    assert_market_type_flags(usdm_markets, "BTC/USDT:USDT",
      type: "swap",
      swap: true,
      linear: true,
      settle: "USDT",
      active: true
    )
  end

  test "Binance-family and OKX current funding rates publish provider cadence" do
    probes = [
      {:binance, "BTC/USDT:USDT", true},
      {:binance, "BTC/USD:BTC", true},
      {:binanceusdm, "BTC/USDT:USDT", true},
      {:binancecoinm, "BTC/USD:BTC", true},
      {:okx, "BTC/USDT:USDT", true}
    ]

    Enum.each(probes, fn {exchange_id, symbol, sandbox} ->
      exchange = build_exchange(exchange_id, sandbox: sandbox)

      assert {:ok, %Bourse.FundingRate{interval: interval}} =
               Bourse.fetch_funding_rate(exchange, symbol)

      assert is_binary(interval) and Regex.match?(~r/^\d+h$/, interval),
             "#{exchange_id} returned invalid funding interval #{inspect(interval)}"
    end)
  end

  test "signed spot and USD-M balances parse funded account rows" do
    spot_credentials = require_credentials!(:binance, url: "https://testnet.binance.vision")

    usdm_credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    spot = build_exchange(:binance, credentials: spot_credentials, sandbox: true)
    usdm = build_exchange(:binanceusdm, credentials: usdm_credentials, sandbox: true)

    assert {:ok, %Balance{} = spot_balance} = Bourse.fetch_balance(spot, type: :spot)
    assert spot_balance.total["BTC"] == 1.0
    assert spot_balance.total["ETH"] == 1.0
    assert spot_balance.total["USDT"] == 10_000.0

    assert {:ok, %Balance{} = usdm_balance} = Bourse.fetch_balance(usdm)
    assert map_size(usdm_balance.total) > 0
    assert Map.keys(usdm_balance.total) == Map.keys(usdm_balance.free)
    assert Map.keys(usdm_balance.total) == Map.keys(usdm_balance.used)
    assert usdm_balance.free["BNB"] == 0
    assert usdm_balance.used["BNB"] == 0
    assert usdm_balance.total["BNB"] == 0
    assert Enum.all?(usdm_balance.used, fn {_asset, used} -> used >= 0 end)

    binance_futures = build_exchange(:binance, credentials: usdm_credentials, sandbox: true)

    assert {:ok, %Balance{} = swap_balance} = Bourse.fetch_balance(binance_futures, type: :swap)
    assert is_number(swap_balance.total["USDT"])

    assert {:ok, %Balance{} = delivery_balance} =
             Bourse.fetch_balance(binance_futures, type: :delivery)

    assert is_map(delivery_balance.total)

    assert {:error,
            %Error{
              type: :not_supported,
              message: "No base URL for section sapi on binance (sandbox)"
            }} = Bourse.fetch_balance(binance_futures, type: :margin)

    bad_signature =
      Credentials.new!(
        api_key: usdm_credentials.api_key,
        secret: "invalid-task-530-signature"
      )

    invalid_usdm = build_exchange(:binanceusdm, credentials: bad_signature, sandbox: true)
    invalid_binance = build_exchange(:binance, credentials: bad_signature, sandbox: true)

    assert {:error, %Error{type: :authentication_error, code: -1022}} =
             Bourse.fetch_balance(invalid_usdm)

    assert {:error, %Error{type: :authentication_error, code: -1022}} =
             Bourse.fetch_balance(invalid_binance, type: :swap)
  end

  @tag :dangerous
  test "USD-M position risk, account positions, and leverages return typed demo data" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binanceusdm, credentials: credentials, sandbox: true)
    assert {:ok, markets} = Bourse.fetch_markets(exchange)
    exchange = Bourse.Exchange.put_markets(exchange, markets)
    position_opts = usdm_position_opts!(exchange)

    assert_no_active_usdm_position!(exchange)
    open_position!(exchange, position_opts)

    try do
      assert {:ok, positions_risk} = Bourse.fetch_positions_risk(exchange)
      assert %Position{} = active_position!(positions_risk, @usdm_lifecycle_symbol)
      assert Enum.all?(positions_risk, &match?(%Position{}, &1))

      assert {:ok, account_positions} = Bourse.fetch_account_positions(exchange)
      assert %Position{} = active_position!(account_positions, @usdm_lifecycle_symbol)
      assert Enum.all?(account_positions, &match?(%Position{}, &1))

      assert {:ok, leverages} = Bourse.fetch_leverages(exchange)
      assert %Leverage{} = leverage = Map.fetch!(leverages, @usdm_lifecycle_symbol)

      assert Enum.all?(leverages, fn {symbol, value} ->
               is_binary(symbol) and String.contains?(symbol, "/") and match?(%Leverage{}, value)
             end)

      assert is_binary(leverage.symbol) and leverage.symbol != ""
      assert is_integer(leverage.long_leverage)
      assert leverage.short_leverage == leverage.long_leverage
    after
      cleanup_usdm_position!(exchange, position_opts)
    end
  end

  test "Binance-family symbol commission endpoints return populated rates and bad-symbol errors" do
    spot_credentials = require_credentials!(:binance, url: "https://testnet.binance.vision")

    usdm_credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    spot = build_exchange(:binance, credentials: spot_credentials, sandbox: true)
    usdm = build_exchange(:binanceusdm, credentials: usdm_credentials, sandbox: true)

    assert {:ok, %{body: spot_fee}} =
             Bourse.Binance.private_get_account_commission(spot, %{"symbol" => "BTCUSDT"})

    assert spot_fee["symbol"] == "BTCUSDT"
    assert is_binary(get_in(spot_fee, ["standardCommission", "maker"]))
    assert is_binary(get_in(spot_fee, ["standardCommission", "taker"]))

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.Binance.private_get_account_commission(spot, %{"symbol" => "INVALIDUSDT"})

    assert {:error,
            %Error{
              type: :not_supported,
              message: "No base URL for section sapi on binance (sandbox)"
            }} = Bourse.fetch_trading_fees(spot)

    assert {:ok, %{body: usdm_fee}} =
             Bourse.Binanceusdm.fapiPrivate_get_commissionrate(usdm, %{"symbol" => "BTCUSDT"})

    assert usdm_fee["symbol"] == "BTCUSDT"
    assert is_binary(usdm_fee["makerCommissionRate"])
    assert is_binary(usdm_fee["takerCommissionRate"])

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.Binanceusdm.fapiPrivate_get_commissionrate(usdm, %{"symbol" => "INVALIDUSDT"})

    assert {:ok, %Bourse.TradingFee{} = fee} =
             Bourse.fetch_trading_fee(usdm, "BTC/USDT:USDT")

    assert is_number(fee.maker)
    assert is_number(fee.taker)
    assert fee.symbol == "BTC/USDT:USDT"

    assert {:error,
            %Error{
              type: :not_supported,
              message: "binanceusdm does not support fetchTradingFees"
            }} = Bourse.fetch_trading_fees(usdm)
  end

  test "invalid credentials return Binance authentication errors on both account families" do
    credentials = Credentials.new!(api_key: "invalid-task-207", secret: "invalid-task-207")

    for exchange_id <- [:binance, :binanceusdm] do
      exchange = build_exchange(exchange_id, credentials: credentials, sandbox: true)
      assert {:error, %Error{type: :authentication_error}} = Bourse.fetch_balance(exchange)
    end
  end

  test "order identifier mappings reach Binance's business validation" do
    spot_credentials = require_credentials!(:binance, url: "https://testnet.binance.vision")

    usdm_credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    for {exchange_id, credentials, symbol} <- [
          {:binance, spot_credentials, "BTC/USDT"},
          {:binanceusdm, usdm_credentials, @usdm_lifecycle_symbol}
        ] do
      exchange = build_exchange(exchange_id, credentials: credentials, sandbox: true)

      assert {:ok, orders} = Bourse.fetch_orders(exchange, symbol: symbol, limit: 1)
      assert is_list(orders)

      assert {:error, %Error{type: :order_not_found, code: -2013}} =
               Bourse.fetch_order(exchange, "999999999999999", symbol: symbol)
    end
  end

  test "spot order-list reads reach Binance testnet and preserve its missing-identifier error" do
    credentials = require_credentials!(:binance, url: "https://testnet.binance.vision")
    exchange = build_exchange(:binance, credentials: credentials, sandbox: true)

    assert {:ok, historical_order_lists} = Bourse.fetch_order_lists(exchange, limit: 1)
    assert is_list(historical_order_lists)
    assert Enum.all?(historical_order_lists, &match?(%OrderList{}, &1))

    assert {:ok, open_order_lists} = Bourse.fetch_open_order_lists(exchange)
    assert is_list(open_order_lists)
    assert Enum.all?(open_order_lists, &match?(%OrderList{}, &1))

    assert {:error,
            %Error{
              type: :bad_request,
              code: @missing_order_list_identifier_error_code,
              message: message
            }} = Bourse.fetch_order_list(exchange, nil)

    assert message =~ "origClientOrderId"
    assert message =~ "orderListId"
  end

  # TODO(Task 550): replace this blocker pin with parsed sandbox values once
  # Binance exposes successful task-567 conversion/currency responses there.
  test "USD-M conversion and currency reads remain unreachable on sandbox" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binanceusdm, credentials: credentials, sandbox: true)

    for result <- [
          Bourse.fetch_convert_quote(exchange, "USDT", "BTC", 1),
          Bourse.fetch_convert_currencies(exchange),
          Bourse.fetch_currencies(exchange)
        ] do
      assert {:error, %Error{type: :not_supported, message: @usdm_sapi_sandbox_error}} = result
    end

    for {method, result} <- [
          fetchConvertTrade: Bourse.fetch_convert_trade(exchange, "1"),
          fetchConvertTradeHistory: Bourse.fetch_convert_trade_history(exchange)
        ] do
      assert {:error, %Error{type: :bad_request, message: message}} = result
      assert message =~ "ambiguous multi-endpoint selection for #{method} on binanceusdm"
    end

    assert {:error, %Error{type: :operation_failed, code: @usdm_convert_demo_error_code}} =
             Bourse.Binanceusdm.fapiPublic_get_convert_exchangeinfo(exchange)

    # Quote creation is non-executing; accepting the returned quote is a separate endpoint.
    assert {:error, %Error{type: :operation_failed, code: @usdm_convert_demo_error_code}} =
             Bourse.Binanceusdm.fapiPrivate_post_convert_getquote(exchange, %{
               "fromAsset" => "USDT",
               "toAsset" => "BTC",
               "fromAmount" => "1"
             })
  end

  @tag :dangerous
  test "USD-M position mode reaches Binance business validation with the active mode" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binanceusdm, credentials: credentials, sandbox: true)

    assert {:ok, %{"dualSidePosition" => hedge_mode}} = Bourse.fetch_position_mode(exchange)
    assert is_boolean(hedge_mode)

    assert {:error, %Error{code: -4059, message: "No need to change position side."}} =
             Bourse.set_position_mode(exchange, hedge_mode)
  end

  @tag :dangerous
  test "dedicated futures expose flat-symbol leverage and COIN-M write capabilities" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    usdm = build_exchange(:binanceusdm, credentials: credentials, sandbox: true)
    coinm = build_exchange(:binancecoinm, credentials: credentials, sandbox: true)
    assert {:ok, usdm_markets} = Bourse.fetch_markets(usdm)
    assert {:ok, coinm_markets} = Bourse.fetch_markets(coinm)
    usdm = Bourse.Exchange.put_markets(usdm, usdm_markets)
    coinm = Bourse.Exchange.put_markets(coinm, coinm_markets)

    assert {:ok, %{body: [flat_position]}} =
             Bourse.Binanceusdm.fapiPrivateV3_get_positionrisk(usdm, %{"symbol" => "ETHUSDT"})

    assert Bourse.Safe.number(flat_position["positionAmt"]) == 0

    assert {:ok, %Leverage{symbol: @usdm_flat_leverage_symbol, long_leverage: @configured_leverage}} =
             Bourse.fetch_leverage(usdm, @usdm_flat_leverage_symbol)

    assert {:ok, %{"dualSidePosition" => hedge_mode}} = Bourse.fetch_position_mode(coinm)

    assert {:error, %Error{code: -4059, message: "No need to change position side."}} =
             Bourse.set_position_mode(coinm, hedge_mode)

    assert {:ok, %{"leverage" => @configured_leverage, "symbol" => "BTCUSD_PERP"}} =
             Bourse.set_leverage(coinm, @configured_leverage, @coinm_flat_leverage_symbol)

    assert {:ok, %Leverage{symbol: @coinm_flat_leverage_symbol, long_leverage: @configured_leverage}} =
             Bourse.fetch_leverage(coinm, @coinm_flat_leverage_symbol)
  end

  @tag :dangerous
  test "USD-M position risk exposes independent contract, notional, margin, and collateral semantics" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binanceusdm, credentials: credentials, sandbox: true)
    assert {:ok, markets} = Bourse.fetch_markets(exchange)
    exchange = Bourse.Exchange.put_markets(exchange, markets)
    position_opts = usdm_position_opts!(exchange)

    open_position!(exchange, position_opts)

    try do
      assert {:ok, positions} = Bourse.fetch_positions(exchange)
      position = active_position!(positions, @usdm_lifecycle_symbol)

      assert position.contract_size == 1
      venue_notional = Bourse.Safe.number(position.info["notional"])
      venue_initial_margin = Bourse.Safe.number(position.info["initialMargin"])
      venue_maintenance_margin = Bourse.Safe.number(position.info["maintMargin"])
      venue_unrealized_pnl = Bourse.Safe.number(position.info["unRealizedProfit"])

      assert is_number(venue_notional)
      assert is_number(venue_initial_margin)
      assert is_number(venue_maintenance_margin)
      assert is_number(venue_unrealized_pnl)
      assert position.notional == abs(venue_notional)
      assert position.initial_margin == venue_initial_margin
      assert position.maintenance_margin == venue_maintenance_margin

      assert position.percentage ==
               Float.round(
                 venue_unrealized_pnl / venue_initial_margin * @percentage_scale,
                 @percentage_precision
               )

      assert position.margin_ratio == nil
      assert position.collateral == nil

      assert {:error, %Error{type: :bad_symbol, code: -1121}} =
               Bourse.fetch_positions(exchange, symbol: "INVALID/USDT:USDT")
    after
      cleanup_usdm_position!(exchange, position_opts)
    end
  end

  test "COIN-M position-risk rows omit derived margin metrics" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binance, credentials: credentials, sandbox: true)

    assert {:ok, %{status: @http_ok_status, body: [row | _]}} =
             Bourse.Binance.dapiPrivate_get_positionrisk(exchange)

    assert is_binary(row["notionalValue"])
    refute Map.has_key?(row, "initialMargin")
    refute Map.has_key?(row, "maintMargin")
    refute Map.has_key?(row, "marginRatio")
    refute Map.has_key?(row, "percentage")
  end

  @tag :dangerous
  test "USD-M order lifecycle accepts lowercase unified side and cleans up deterministically" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binanceusdm, credentials: credentials, sandbox: true)

    assert {:ok, markets} = Bourse.fetch_markets(exchange)
    assert Enum.any?(markets, &(&1.symbol == @usdm_lifecycle_symbol and &1.id == "BTCUSDT"))

    client_order_id = "bourse-task296-#{System.unique_integer([:positive])}"

    # The shared demo account's position mode is mutable state: in Hedge Mode
    # every order requires an explicit positionSide (-4061 without it).
    position_opts = usdm_position_opts!(exchange)

    order =
      create_usdm_order!(
        exchange,
        [
          newClientOrderId: client_order_id,
          price: @usdm_lifecycle_price,
          timeInForce: "GTC"
        ] ++ position_opts
      )

    try do
      # Lowercase "buy" reached the venue as BUY: -1117 "Invalid side." never
      # fired, and the fapi-sourced market id resolved: no -1121 "Invalid symbol."
      assert %Order{id: id, client_order_id: ^client_order_id} = fetched = fetch_order!(exchange, order.id)
      assert id == order.id
      assert fetched.side == "buy"
      assert fetched.info["side"] == "BUY"
      assert fetched.info["type"] == "LIMIT"
      assert fetched.info["symbol"] == "BTCUSDT"
      assert fetched.status == "open"

      assert {:ok, %Order{id: ^id}} =
               Bourse.cancel_order(exchange, id, symbol: @usdm_lifecycle_symbol)

      assert %Order{status: "canceled"} = fetch_order!(exchange, id)
    after
      cleanup_usdm_order!(exchange, order.id)
    end
  end

  # Task 296 was filed believing the spot testnet key could not write (`-2015
  # "Invalid API-key, IP, or permissions for action"`). Re-probed live 2026-07-17:
  # the key IS trade-enabled and a far-from-market limit order rests, so the write
  # path is asserted rather than tolerated — a `-2015` here is a real regression,
  # not the documented environment.
  #
  # Task 336 extends it to the ACK/read contract: `newOrderRespType=ACK` must stay
  # sparse (no invented fill/cost/status), while the subsequent reads return the
  # venue's complete order row and an unknown id still raises -2013.
  @tag :dangerous
  test "spot ACK remains sparse while order reads return the complete venue state" do
    credentials = require_credentials!(:binance, url: "https://testnet.binance.vision")
    exchange = build_exchange(:binance, credentials: credentials, sandbox: true)

    assert {:ok, %Balance{}} = Bourse.fetch_balance(exchange)

    client_order_id = "bourse-task296-spot-#{System.unique_integer([:positive])}"

    order =
      case Bourse.create_order(exchange, "BTC/USDT", "limit", "buy", @spot_write_amount,
             price: @spot_write_price,
             timeInForce: "GTC",
             newClientOrderId: client_order_id,
             newOrderRespType: "ACK"
           ) do
        {:ok, %Order{id: id} = order} when is_binary(id) and id != "" ->
          order

        other ->
          flunk("Binance spot create_order failed: #{inspect(other)}")
      end

    try do
      assert order.client_order_id == client_order_id
      assert order.timestamp == order.info["transactTime"]
      assert order.amount == nil
      assert order.filled == nil
      assert order.cost == nil
      assert order.status == nil

      assert {:ok, %Order{id: id, side: "buy", amount: @spot_write_amount, status: "open"} = read} =
               Bourse.fetch_order(exchange, order.id, symbol: "BTC/USDT")

      # The ACK echoes no side/type, so the lowercase-unified-side guard moves to
      # the read: "buy" reached the venue as BUY and -1117 "Invalid side." never fired.
      assert read.info["side"] == "BUY"
      assert read.info["type"] == "LIMIT"

      assert {:ok, orders} = Bourse.fetch_orders(exchange, symbol: "BTC/USDT", limit: 10)
      assert Enum.any?(orders, &(&1.id == id and &1.status == "open"))

      assert {:error, %Error{type: :order_not_found, code: -2013}} =
               Bourse.fetch_order(exchange, "999999999999999", symbol: "BTC/USDT")
    after
      cleanup_spot_order!(exchange, order.id)
    end
  end

  @tag :dangerous
  test "trailing spot orders use transactTime when workingTime is the unactivated sentinel" do
    credentials = require_credentials!(:binance, url: "https://testnet.binance.vision")
    exchange = build_exchange(:binance, credentials: credentials, sandbox: true)

    order =
      case Bourse.create_order(exchange, "BTC/USDT", "take_profit", "buy", @spot_write_amount,
             trailingDelta: 500,
             newOrderRespType: "RESULT",
             newClientOrderId: "bourse-task381-#{System.unique_integer([:positive])}"
           ) do
        {:ok, %Order{id: id} = order} when is_binary(id) and id != "" -> order
        other -> flunk("Binance trailing create_order failed: #{inspect(other)}")
      end

    try do
      assert order.info["workingTime"] in [-1, "-1"]
      assert order.timestamp == Bourse.Safe.integer(order.info["transactTime"])
      assert order.timestamp >= 0
    after
      cleanup_spot_order!(exchange, order.id)
    end
  end

  @tag :dangerous
  test "USD-M cancel all returns the documented acknowledgement rather than a phantom order" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binanceusdm, credentials: credentials, sandbox: true)

    assert {:ok, %{"code" => code, "msg" => message}} =
             Bourse.cancel_all_orders(exchange, symbol: @usdm_lifecycle_symbol)

    assert code in [200, "200"]
    assert is_binary(message) and message != ""
  end

  @tag :dangerous
  test "USD-M cancel all surfaces Binance's invalid-symbol error" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binanceusdm, credentials: credentials, sandbox: true)

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.cancel_all_orders(exchange, symbol: "INVALID/USDT:USDT")
  end

  @tag :dangerous
  test "generic Binance USD-M writes use the Algo, margin, and symbol-scoped cancel contracts" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    exchange = build_exchange(:binance, credentials: credentials, sandbox: true)

    assert {:error, %Error{code: @legacy_conditional_error_code}} =
             Bourse.Binance.fapiPrivate_post_order(exchange, %{
               "quantity" => @legacy_conditional_probe_amount,
               "reduceOnly" => "true",
               "side" => "SELL",
               "stopPrice" => @legacy_conditional_probe_price,
               "symbol" => @usdm_conditional_native_symbol,
               "type" => "STOP_MARKET"
             })

    assert {:error, %Error{type: :bad_symbol, code: @bad_symbol_error_code}} =
             Bourse.set_margin_mode(exchange, "isolated", "INVALID/USDT:USDT")

    assert {:error, %Error{type: :bad_symbol, code: @bad_symbol_error_code}} =
             Bourse.cancel_all_orders(exchange, symbol: "INVALID/USDT:USDT")

    assert {:ok, %Bourse.MarginMode{margin_mode: original_margin_mode}} =
             Bourse.fetch_margin_mode(exchange, @usdm_conditional_symbol, type: :swap)

    alternate_margin_mode = if original_margin_mode == "isolated", do: "cross", else: "isolated"

    try do
      assert {:ok, %{"code" => 200}} =
               Bourse.set_margin_mode(exchange, alternate_margin_mode, @usdm_conditional_symbol)

      assert {:ok, %Bourse.MarginMode{margin_mode: ^alternate_margin_mode}} =
               Bourse.fetch_margin_mode(exchange, @usdm_conditional_symbol, type: :swap)
    after
      assert {:ok, %{"code" => 200}} =
               Bourse.set_margin_mode(exchange, original_margin_mode, @usdm_conditional_symbol)
    end

    {trigger_price, limit_price} = conditional_prices!(exchange)
    resting_ids = create_regular_resting_orders!(exchange, limit_price)

    try do
      assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @usdm_conditional_symbol)
      assert Enum.all?(resting_ids, fn id -> Enum.any?(open_orders, &(&1.id == id)) end)

      assert {:ok, %{"code" => 200}} =
               Bourse.cancel_all_orders(exchange, symbol: @usdm_conditional_symbol)

      assert {:ok, []} = Bourse.fetch_open_orders(exchange, symbol: @usdm_conditional_symbol)
    after
      assert {:ok, %{"code" => 200}} =
               Bourse.cancel_all_orders(exchange, symbol: @usdm_conditional_symbol)
    end

    assert {:ok, %Order{}} =
             Bourse.create_order(
               exchange,
               @usdm_conditional_symbol,
               "market",
               "buy",
               @usdm_conditional_amount
             )

    try do
      assert {:ok,
              %Order{
                id: conditional_id,
                reduce_only: true,
                status: "open",
                time_in_force: "GTC",
                trigger_price: parsed_trigger
              }} =
               Bourse.create_order(
                 exchange,
                 @usdm_conditional_symbol,
                 "limit",
                 "sell",
                 @usdm_conditional_amount,
                 price: limit_price,
                 reduce_only: true,
                 time_in_force: "GTC",
                 trigger_price: trigger_price
               )

      assert parsed_trigger == String.to_float(trigger_price)

      assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @usdm_conditional_symbol)

      assert %Order{} = algo_order = Enum.find(open_orders, &(&1.id == conditional_id))

      assert algo_order.status == "open"
      assert algo_order.reduce_only == true
      assert algo_order.time_in_force == "GTC"
      assert algo_order.trigger_price == parsed_trigger

      assert {:ok, %Order{id: ^conditional_id}} =
               Bourse.cancel_order(exchange, conditional_id, symbol: @usdm_conditional_symbol)

      assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @usdm_conditional_symbol)
      refute Enum.any?(open_orders, &(&1.id == conditional_id))

      assert {:ok, %Order{id: cancel_all_id}} =
               Bourse.create_order(
                 exchange,
                 @usdm_conditional_symbol,
                 "limit",
                 "sell",
                 @usdm_conditional_amount,
                 price: limit_price,
                 reduce_only: true,
                 time_in_force: "GTC",
                 trigger_price: trigger_price
               )

      assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @usdm_conditional_symbol)
      assert Enum.any?(open_orders, &(&1.id == cancel_all_id))

      assert {:ok, %{"code" => 200}} =
               Bourse.cancel_all_orders(exchange, symbol: @usdm_conditional_symbol)

      assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @usdm_conditional_symbol)
      refute Enum.any?(open_orders, &(&1.id == cancel_all_id))
    after
      assert {:ok, %{"code" => 200}} =
               Bourse.cancel_all_orders(exchange, symbol: @usdm_conditional_symbol)

      assert {:ok, %Order{reduce_only: true}} =
               Bourse.create_order(
                 exchange,
                 @usdm_conditional_symbol,
                 "market",
                 "sell",
                 @usdm_conditional_amount,
                 reduce_only: true
               )

      assert {:ok, %{body: []}} =
               Bourse.Binance.fapiPrivateV3_get_positionrisk(exchange, %{
                 "symbol" => @usdm_conditional_native_symbol
               })
    end
  end

  @tag :dangerous
  test "Binance-family Algo identifiers round-trip through single reads and return branchable cancel state" do
    credentials =
      require_credentials!(:binance, sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management")

    for {exchange_id, symbol, amount, ratio, decimal_places} <- [
          {:binance, @usdm_conditional_symbol, @usdm_algo_read_amount, @usdm_conditional_trigger_ratio,
           @usdm_conditional_price_decimal_places},
          {:binanceusdm, @usdm_conditional_symbol, @usdm_algo_read_amount, @usdm_conditional_trigger_ratio,
           @usdm_conditional_price_decimal_places},
          {:binancecoinm, @coinm_flat_leverage_symbol, @coinm_conditional_amount, @coinm_conditional_trigger_ratio,
           @coinm_conditional_price_decimal_places}
        ] do
      exchange = build_exchange(exchange_id, credentials: credentials, sandbox: true)
      assert {:ok, %Bourse.Ticker{} = ticker} = Bourse.fetch_ticker(exchange, symbol)
      trigger_price = conditional_price(ticker.mark_price || ticker.last, ratio, decimal_places)

      assert {:ok, %Order{id: id, status: "open", type: "stop_market"}} =
               Bourse.create_order(exchange, symbol, "market", "sell", amount,
                 time_in_force: "GTC",
                 trigger_price: trigger_price
               )

      try do
        assert {:ok, %Order{id: ^id, status: "open", type: "stop_market"}} =
                 Bourse.fetch_order(exchange, id, symbol: symbol)

        assert {:ok, %Order{id: ^id, status: "open", type: "stop_market"}} =
                 Bourse.fetch_open_order(exchange, id, symbol: symbol)

        assert {:ok, %Order{id: ^id, status: "canceled"}} =
                 Bourse.cancel_order(exchange, id, symbol: symbol)
      after
        cleanup_algo_order!(exchange, id, symbol)
      end
    end
  end

  test "every live EAPI option id round-trips through the authored option carve" do
    exchange = Bourse.Exchange.new!("binance")
    rows = live_eapi_option_rows!()

    # Subjects come from the live listing rather than a pinned contract: any hard-coded
    # option id delists at expiry and would turn this gate red for a benign reason.
    assert length(rows) > 100

    # Carve C18 restores the quote as USDT because the id omits it. That is only sound
    # while the venue quotes every option in USDT — assert the premise, don't assume it.
    assert Enum.all?(rows, &(&1["quoteAsset"] == "USDT"))

    ids = Enum.map(rows, &Map.fetch!(&1, "symbol"))

    mismatches =
      for id <- ids,
          symbol = Bourse.Symbol.from_exchange_id(id, exchange, :option),
          # symbol == id catches the pre-274 defect shape: an unpopulated pattern makes
          # both directions a silent passthrough, which would otherwise round-trip green.
          symbol == id or Bourse.Symbol.to_exchange_id(symbol, exchange) != id,
          do: {id, symbol}

    assert mismatches == [],
           "live option ids failed to round-trip: #{inspect(Enum.take(mismatches, 5))}"

    # Both live strike shapes must be exercised, else the decimal branch passes vacuously.
    # A red here is a venue-listing drift signal, not a code defect: it means Binance stopped
    # listing that strike shape, so the carve's handling of it is no longer live-backed.
    assert Enum.any?(ids, &String.contains?(&1, ".")),
           "no decimal-strike option listed; decimal handling is no longer covered live"

    assert Enum.any?(ids, &(not String.contains?(&1, "."))),
           "no integer-strike option listed; integer handling is no longer covered live"
  end

  test "live option marks normalize into greeks and preserve Binance's error" do
    exchange = build_exchange(:binance, sandbox: false)

    assert {:ok, greeks} = Bourse.fetch_all_greeks(exchange)
    assert map_size(greeks) > 100

    assert Enum.all?(greeks, fn {symbol, value} ->
             is_binary(symbol) and symbol == value.symbol and match?(%Greeks{}, value) and
               is_number(value.mark_price) and is_number(value.delta)
           end)

    symbol = greeks |> Map.keys() |> hd()

    # `map_size == 1` is the load-bearing half: a bare `%{^symbol => _}` pattern also
    # matches the unfiltered 1400-row map, so it would pass even if Binance ignored the
    # native `symbol` query and the request shape were a no-op. Observed live 2026-07-21:
    # the full read returns 1454 rows, the single-symbol read returns exactly 1.
    assert {:ok, %{^symbol => %Greeks{symbol: ^symbol}} = single} =
             Bourse.fetch_all_greeks(exchange, symbols: [symbol])

    assert map_size(single) == 1

    # Multi-symbol has no native query — Binance returns every row and the filter runs
    # client-side off the unshaped params. Pins that the `symbols` drop does not lose it.
    multi = greeks |> Map.keys() |> Enum.take(2)

    assert {:ok, filtered} = Bourse.fetch_all_greeks(exchange, symbols: multi)
    assert filtered |> Map.keys() |> Enum.sort() == Enum.sort(multi)

    invalid_symbol = Bourse.Symbol.from_exchange_id("BTC-991231-999999-C", exchange, :option)

    assert {:error, %Error{type: :bad_symbol, code: -1121}} =
             Bourse.fetch_all_greeks(exchange, symbols: [invalid_symbol])
  end

  defp assert_ohlcv_rows(rows) when is_list(rows) and rows != [] do
    assert Enum.all?(rows, fn [timestamp, open, high, low, close, volume] ->
             is_integer(timestamp) and Enum.all?([open, high, low, close, volume], &is_number/1)
           end)
  end

  defp conditional_prices!(exchange) do
    assert {:ok, %Bourse.Ticker{} = ticker} =
             Bourse.fetch_ticker(exchange, @usdm_conditional_symbol)

    mark_price = ticker.mark_price || ticker.last
    assert is_number(mark_price) and mark_price > 0

    trigger_price = conditional_price(mark_price, @usdm_conditional_trigger_ratio)
    limit_price = conditional_price(mark_price, @usdm_conditional_limit_ratio)
    {trigger_price, limit_price}
  end

  defp conditional_price(mark_price, ratio, decimal_places \\ @usdm_conditional_price_decimal_places) do
    mark_price
    |> Kernel.*(ratio)
    |> Float.floor(decimal_places)
    |> :erlang.float_to_binary(decimals: decimal_places)
  end

  defp cleanup_algo_order!(exchange, id, symbol) do
    case Bourse.cancel_order(exchange, id, symbol: symbol) do
      {:ok, %Order{status: "canceled"}} -> :ok
      {:error, %Error{type: :order_not_found}} -> :ok
      {:error, %Error{type: :invalid_order}} -> :ok
      other -> flunk("Binance Algo cleanup failed for #{id}: #{inspect(other)}")
    end
  end

  defp create_regular_resting_orders!(exchange, price) do
    Enum.map(1..@cancel_all_order_count, fn _index ->
      assert {:ok, %Order{id: id}} =
               Bourse.create_order(
                 exchange,
                 @usdm_conditional_symbol,
                 "limit",
                 "buy",
                 @usdm_conditional_amount,
                 price: price,
                 time_in_force: "GTC"
               )

      id
    end)
  end

  defp assert_trade_rows(rows) when is_list(rows) and rows != [] do
    assert Enum.all?(rows, fn trade ->
             is_number(trade.price) and is_number(trade.amount) and is_number(trade.cost) and
               trade.side in ["buy", "sell"]
           end)
  end

  defp assert_market_precision(markets, native_id) when is_list(markets) do
    market = Enum.find(markets, &(&1.id == native_id))

    assert market,
           "no #{native_id} market in #{length(markets)} markets: #{inspect(Enum.take(markets, 3))}"

    assert %Bourse.Market{} = market
    assert is_number(market.precision["price"]) and market.precision["price"] > 0
    assert is_number(market.precision["amount"]) and market.precision["amount"] > 0
  end

  defp assert_market_type_flags(markets, symbol, expected) when is_list(markets) and is_list(expected) do
    market = Enum.find(markets, &(&1.symbol == symbol))

    assert market,
           "no #{symbol} market in #{length(markets)} markets: #{inspect(Enum.take(markets, 3))}"

    for {key, value} <- expected do
      assert Map.get(market, key) == value,
             "#{symbol}.#{key} expected #{inspect(value)}, got #{inspect(Map.get(market, key))}"
    end
  end

  defp live_eapi_option_rows! do
    response = Req.get!(@binance_eapi_exchange_info_url)

    Map.fetch!(response.body, "optionSymbols")
  end

  defp create_usdm_order!(exchange, opts) do
    case Bourse.create_order(exchange, @usdm_lifecycle_symbol, "limit", "buy", @usdm_lifecycle_amount, opts) do
      {:ok, %Order{id: id} = order} when is_binary(id) and id != "" ->
        order

      other ->
        flunk("Binance USD-M create_order failed: #{inspect(other)}")
    end
  end

  defp fetch_order!(exchange, id),
    do: poll_order!(fn -> Bourse.fetch_order(exchange, id, symbol: @usdm_lifecycle_symbol) end)

  defp poll_order!(request, attempts \\ @poll_attempts)

  defp poll_order!(_request, 0),
    do: flunk("Binance USD-M order state did not become visible after #{@poll_attempts} attempts")

  defp poll_order!(request, attempts) do
    case request.() do
      {:ok, %Order{} = order} ->
        order

      {:error, %Error{type: :order_not_found}} ->
        receive do
        after
          @poll_interval_ms -> poll_order!(request, attempts - 1)
        end

      other ->
        flunk("Binance USD-M order lookup failed: #{inspect(other)}")
    end
  end

  defp cleanup_usdm_order!(exchange, id) do
    case Bourse.cancel_order(exchange, id, symbol: @usdm_lifecycle_symbol) do
      {:ok, %Order{}} -> :ok
      {:error, %Error{type: :order_not_found}} -> :ok
      {:error, %Error{type: :invalid_order}} -> :ok
      other -> flunk("Binance USD-M cleanup failed for #{id}: #{inspect(other)}")
    end
  end

  defp open_position!(exchange, opts) do
    case Bourse.create_order(exchange, @usdm_lifecycle_symbol, "market", "buy", @usdm_lifecycle_amount, opts) do
      {:ok, %Order{id: id}} when is_binary(id) and id != "" -> :ok
      other -> flunk("Binance USD-M position open failed: #{inspect(other)}")
    end
  end

  defp usdm_position_opts!(exchange) do
    case Bourse.fetch_position_mode(exchange) do
      {:ok, %{"dualSidePosition" => true}} -> [positionSide: "LONG"]
      {:ok, %{"dualSidePosition" => false}} -> []
      other -> flunk("Binance USD-M position-mode read failed: #{inspect(other)}")
    end
  end

  defp active_position!(positions, symbol) do
    case Enum.find(positions, &(&1.symbol == symbol and is_number(&1.contracts) and &1.contracts > 0)) do
      %Position{} = position -> position
      nil -> flunk("Binance USD-M position did not become visible: #{inspect(positions)}")
    end
  end

  defp assert_no_active_usdm_position!(exchange) do
    assert {:ok, positions} = Bourse.fetch_positions(exchange)

    refute Enum.any?(positions, &(&1.symbol == @usdm_lifecycle_symbol and &1.contracts > 0)),
           "Binance USD-M test requires no existing long position: #{inspect(positions)}"
  end

  defp cleanup_usdm_position!(exchange, position_opts) do
    close_opts = if position_opts == [], do: [reduceOnly: true], else: position_opts

    case Bourse.create_order(exchange, @usdm_lifecycle_symbol, "market", "sell", @usdm_lifecycle_amount, close_opts) do
      {:ok, %Order{}} -> :ok
      other -> flunk("Binance USD-M position cleanup order failed: #{inspect(other)}")
    end

    assert {:ok, positions} = Bourse.fetch_positions(exchange)

    refute Enum.any?(positions, &(&1.symbol == @usdm_lifecycle_symbol and &1.contracts > 0)),
           "Binance USD-M position cleanup left an open position: #{inspect(positions)}"
  end

  defp cleanup_spot_order!(exchange, id) do
    case Bourse.cancel_order(exchange, id, symbol: "BTC/USDT") do
      {:ok, %Order{}} -> :ok
      {:error, %Error{type: :order_not_found}} -> :ok
      {:error, %Error{type: :invalid_order}} -> :ok
      other -> flunk("Binance spot cleanup failed for #{id}: #{inspect(other)}")
    end
  end
end
