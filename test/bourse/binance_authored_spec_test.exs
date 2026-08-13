defmodule Bourse.BinanceAuthoredSpecTest do
  use ExUnit.Case, async: false

  alias Bourse.Balance
  alias Bourse.BorrowInterest
  alias Bourse.Conversion
  alias Bourse.Exchange
  alias Bourse.Greeks
  alias Bourse.OrderList
  alias Bourse.Position
  alias Bourse.Symbol
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified
  alias Bourse.Unified.FundingInterval
  alias Bourse.Unified.ReadParse
  alias Bourse.Unified.RequestShape

  @non_usdt_tickers_fixture "test/fixtures/responses/binance/fetch_tickers_non_usdt_quotes.json"
  @external_resource @non_usdt_tickers_fixture
  @frozen_timestamp_ms 1_700_000_000_000
  @bad_request_status 400
  @eapi_percentage_points 1775.0

  # Live eapi/v1/ticker row observed 2026-08-13: 1.42 / 0.08 = 17.75 on the
  # provider wire. Unified percentage is percent points (fraction × 100).
  @eapi_ticker_row %{
    "lastPrice" => "1.5",
    "open" => "0.08",
    "priceChange" => "1.42",
    "priceChangePercent" => "17.75",
    "symbol" => "SOL-260814-66-P"
  }

  test "EAPI ticker fractions emit percent points on the option surface" do
    for exchange_id <- ~w(binance binancecoinm binanceusdm) do
      module = Exchange.new!(exchange_id).module

      assert {:ok, %Bourse.OptionData{percentage: @eapi_percentage_points}} =
               module.parse_option(@eapi_ticker_row)
    end
  end

  test "direct parse_ticker without a route stamp still scales option rows from market context" do
    # Public parse_*/2 callers carry no _bourse_endpoint_id annotation; the
    # authored rule must fall back to the market.option discriminator instead
    # of silently emitting the raw fraction 100x off the routed reads.
    module = Exchange.new!("binance").module

    assert {:ok, %Bourse.Ticker{percentage: @eapi_percentage_points}} =
             module.parse_ticker(@eapi_ticker_row, market: %Bourse.Market{option: true})

    assert {:ok, %Bourse.Ticker{percentage: 17.75}} =
             module.parse_ticker(@eapi_ticker_row, market: %Bourse.Market{option: false})
  end

  test "fetch_tickers on the eapi route matches singular ticker and option reads" do
    {requests, stub} = ticker_rows_stub([@eapi_ticker_row])
    exchange = Exchange.new!("binance")

    assert {:ok, tickers} =
             Unified.call(
               exchange,
               :fetch_tickers,
               "fetchTickers",
               %{"type" => "option"},
               plug: {Req.Test, stub}
             )

    [%Bourse.Ticker{} = ticker] = Map.values(tickers)
    assert ticker.percentage == @eapi_percentage_points

    symbol = "SOL/USDT:USDT-260814-66-P"

    assert {:ok, %Bourse.Ticker{percentage: @eapi_percentage_points}} =
             Unified.call(
               exchange,
               :fetch_ticker,
               "fetchTicker",
               %{"symbol" => symbol, "type" => "option"},
               plug: {Req.Test, stub}
             )

    assert {:ok, %Bourse.OptionData{percentage: @eapi_percentage_points}} =
             Unified.call(
               exchange,
               :fetch_option,
               "fetchOption",
               %{"symbol" => symbol},
               plug: {Req.Test, stub}
             )

    eapi_requests = Enum.filter(RequestCollector.requests(requests), &(&1.conn.request_path == "/eapi/v1/ticker"))
    assert length(eapi_requests) == 3
  end

  test "ticker percentage branches on the eapi route, not request-context market" do
    for venue <- ~w(binance binancecoinm binanceusdm) do
      rule =
        venue
        |> Bourse.Spec.load!()
        |> get_in(["normalization", "field_maps", "ticker", "field_map", "percentage"])

      assert rule["kind"] == "when"
      assert rule["guard"] == %{"equals" => "eapiPublic/ticker", "field" => "_bourse_endpoint_id"}
      refute Map.has_key?(rule, "discriminator")
    end
  end

  test "authored selectors choose spot and USD-M account endpoints" do
    assert Exchange.new!("binance").endpoint_selection["fetchBalance"]["default"] == "private_get_account"

    assert Exchange.new!("binanceusdm").endpoint_selection["fetchBalance"]["default"] ==
             "fapiPrivateV3_get_account"
  end

  test "options fetch_ledger preserves an unenumerated provider type on the bill route" do
    stub = unique_stub("binance_options_ledger")
    test_process = self()

    Req.Test.stub(stub, fn conn ->
      send(test_process, {:options_ledger_path, conn.request_path})

      Req.Test.json(conn, [
        %{
          "amount" => "-0.16518203",
          "asset" => "USDT",
          "createDate" => @frozen_timestamp_ms,
          "id" => "1125899906845701870",
          "type" => "provider-added-option-type"
        }
      ])
    end)

    exchange = Exchange.new!("binance", api_key: "key", secret: "secret")

    assert {:ok, [%Bourse.LedgerEntry{type: "provider-added-option-type", direction: "out"}]} =
             Unified.call(exchange, :fetch_ledger, "fetchLedger", %{"code" => "USDT", "type" => "option"},
               plug: {Req.Test, stub}
             )

    assert_receive {:options_ledger_path, "/eapi/v1/bill"}
  end

  test "funding rates join the provider's per-symbol cadence for every Binance futures surface" do
    for {exchange_id, symbol, native_symbol, premium_path, funding_path} <- [
          {"binance", "BTC/USDT:USDT", "BTCUSDT", "/fapi/v1/premiumIndex", "/fapi/v1/fundingInfo"},
          {"binance", "BTC/USD:BTC", "BTCUSD_PERP", "/dapi/v1/premiumIndex", "/dapi/v1/fundingInfo"},
          {"binanceusdm", "BTC/USDT:USDT", "BTCUSDT", "/fapi/v1/premiumIndex", "/fapi/v1/fundingInfo"},
          {"binanceusdm", "BTC/USD:BTC", "BTCUSD_PERP", "/dapi/v1/premiumIndex", "/dapi/v1/fundingInfo"},
          {"binancecoinm", "BTC/USD:BTC", "BTCUSD_PERP", "/dapi/v1/premiumIndex", "/dapi/v1/fundingInfo"}
        ] do
      {requests, stub} = funding_rate_stub(native_symbol, premium_path, funding_path, 4)

      assert {:ok, %Bourse.FundingRate{symbol: ^symbol, interval: "4h"}} =
               Bourse.fetch_funding_rate(Exchange.new!(exchange_id, sandbox: true), symbol, plug: {Req.Test, stub})

      assert requests |> RequestCollector.requests() |> Enum.map(& &1.conn.request_path) ==
               [premium_path, funding_path]
    end
  end

  test "plural funding rates default perpetual cadences without stamping dated delivery futures" do
    for {exchange_id, selection_opts, native_symbols, no_funding_symbol, premium_path, funding_path} <- [
          {"binance", [], ["BTCUSDT", "ETHUSDT"], nil, "/fapi/v1/premiumIndex", "/fapi/v1/fundingInfo"},
          {"binance", [subType: "inverse"], ["BTCUSD_PERP", "ETHUSD_PERP"], nil, "/dapi/v1/premiumIndex",
           "/dapi/v1/fundingInfo"},
          {"binanceusdm", [], ["BTCUSDT", "ETHUSDT"], nil, "/fapi/v1/premiumIndex", "/fapi/v1/fundingInfo"},
          {"binancecoinm", [], ["BTCUSD_PERP", "ETHUSD_PERP", "BTCUSD_260925"], "BTCUSD_260925", "/dapi/v1/premiumIndex",
           "/dapi/v1/fundingInfo"}
        ] do
      {requests, stub} = funding_rates_stub(native_symbols, no_funding_symbol, premium_path, funding_path)
      opts = [plug: {Req.Test, stub}] ++ selection_opts

      assert {:ok, rates} = Bourse.fetch_funding_rates(Exchange.new!(exchange_id, sandbox: true), opts)

      rates_by_native_symbol =
        rates
        |> Map.values()
        |> Map.new(&{&1.info["symbol"], &1})

      [adjusted_symbol, default_symbol | _rest] = native_symbols
      assert %Bourse.FundingRate{interval: "4h"} = Map.fetch!(rates_by_native_symbol, adjusted_symbol)
      assert %Bourse.FundingRate{interval: "8h"} = Map.fetch!(rates_by_native_symbol, default_symbol)

      if no_funding_symbol do
        assert %Bourse.FundingRate{info: %{"nextFundingTime" => 0}, interval: nil} =
                 Map.fetch!(rates_by_native_symbol, no_funding_symbol)
      end

      assert requests |> RequestCollector.requests() |> Enum.map(& &1.conn.request_path) ==
               [premium_path, funding_path]
    end
  end

  test "the funding-interval join refuses instead of defaulting when no native symbol resolves" do
    stub = unique_stub("binance_unresolved_funding_interval")
    Req.Test.stub(stub, &Req.Test.json(&1, []))

    assert {:error, %Bourse.Error{message: message}} =
             FundingInterval.enrich(
               {:ok, %Bourse.FundingRate{interval: nil, info: %{}}},
               Exchange.new!("binance", sandbox: true),
               :fetch_funding_rate,
               %{},
               plug: {Req.Test, stub}
             )

    assert message =~ "Cannot resolve the native symbol"
  end

  test "the funding-interval join rejects an invalid provider cadence" do
    stub = unique_stub("binance_invalid_funding_interval")
    {:ok, requests} = RequestCollector.start_link()
    row = %{"fundingIntervalHours" => "invalid", "symbol" => "BTCUSDT"}

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, [row])
    end)

    assert {:error, %Bourse.Error{message: message, raw: ^row}} =
             FundingInterval.enrich(
               {:ok, %Bourse.FundingRate{interval: nil, info: %{}}},
               Exchange.new!("binance", sandbox: true),
               :fetch_funding_rate,
               %{"symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, stub}
             )

    assert message == "Invalid fundingIntervalHours from binance funding info"
    assert RequestCollector.one!(requests).request_path == "/fapi/v1/fundingInfo"
  end

  test "plural funding enrichment propagates an invalid provider cadence" do
    stub = unique_stub("binance_invalid_plural_funding_interval")
    row = %{"fundingIntervalHours" => "invalid", "symbol" => "BTCUSDT"}
    Req.Test.stub(stub, &Req.Test.json(&1, [row]))

    funding_rate = %Bourse.FundingRate{
      info: %{"nextFundingTime" => 1_700_028_800_000, "symbol" => "BTCUSDT"}
    }

    assert {:error, %Bourse.Error{message: "Invalid fundingIntervalHours from binance funding info", raw: ^row}} =
             FundingInterval.enrich(
               {:ok, %{"BTC/USDT:USDT" => funding_rate}},
               Exchange.new!("binance", sandbox: true),
               :fetch_funding_rates,
               %{},
               plug: {Req.Test, stub}
             )
  end

  test "the funding-interval join does not default without perpetual evidence" do
    stub = unique_stub("binance_unknown_funding_interval")
    Req.Test.stub(stub, &Req.Test.json(&1, []))
    funding_rate = %Bourse.FundingRate{info: %{"symbol" => "BTCUSDT"}}

    assert {:ok, %Bourse.FundingRate{interval: nil}} =
             FundingInterval.enrich(
               {:ok, funding_rate},
               Exchange.new!("binance", sandbox: true),
               :fetch_funding_rate,
               %{},
               plug: {Req.Test, stub}
             )
  end

  test "plural funding enrichment preserves an interval already supplied by the primary response" do
    stub = unique_stub("binance_existing_funding_interval")
    Req.Test.stub(stub, &Req.Test.json(&1, []))
    funding_rate = %Bourse.FundingRate{interval: "1h", info: %{"symbol" => "BTCUSDT"}}

    assert {:ok, %{"BTC/USDT:USDT" => ^funding_rate}} =
             FundingInterval.enrich(
               {:ok, %{"BTC/USDT:USDT" => funding_rate}},
               Exchange.new!("binance", sandbox: true),
               :fetch_funding_rates,
               %{},
               plug: {Req.Test, stub}
             )
  end

  test "Binance funding rates use the documented default when no adjusted per-symbol row exists" do
    {requests, stub} = funding_rate_stub("BTCUSDT", "/fapi/v1/premiumIndex", "/fapi/v1/fundingInfo", nil)

    assert {:ok, %Bourse.FundingRate{interval: "8h"}} =
             Bourse.fetch_funding_rate(Exchange.new!("binance", sandbox: true), "BTC/USDT:USDT", plug: {Req.Test, stub})

    assert length(RequestCollector.requests(requests)) == 2
  end

  test "Binance USD-M conditional order opts reach the Algo Order request" do
    for {trigger_opt, trigger_value, order_type, native_type} <- [
          {:trigger_price, "3000", "market", "STOP_MARKET"},
          {:stop_loss_price, "2900", "market", "STOP_MARKET"},
          {:take_profit_price, "3100", "market", "TAKE_PROFIT_MARKET"},
          {:take_profit_price, "3100", "limit", "TAKE_PROFIT"}
        ] do
      {requests, stub} = order_stub()
      exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

      opts =
        [
          {trigger_opt, trigger_value},
          price: if(order_type == "limit", do: "3050"),
          time_in_force: "GTC",
          reduce_only: true,
          plug: {Req.Test, stub},
          timestamp_ms_override: 1_700_000_000_000
        ]

      assert {:ok, %Bourse.Order{}} =
               Bourse.create_order(exchange, "ETH/USDT:USDT", order_type, "sell", 1, opts)

      assert_order_request(requests, :post, "/fapi/v1/algoOrder", fn params ->
        assert params["algoType"] == "CONDITIONAL"
        assert params["quantity"] == "1"
        assert params["reduceOnly"] == "true"
        assert params["side"] == "SELL"
        assert params["symbol"] == "ETHUSDT"
        assert params["timeInForce"] == "GTC"
        assert params["triggerPrice"] == trigger_value
        assert params["type"] == native_type
        refute Map.has_key?(params, Atom.to_string(trigger_opt))
      end)
    end
  end

  test "dedicated Binance futures conditional orders preserve opts and use the Algo book" do
    for {exchange_id, symbol, expected_path} <- [
          {"binanceusdm", "ETH/USDT:USDT", "/fapi/v1/algoOrder"},
          {"binancecoinm", "BTC/USD:BTC", "/dapi/v1/algoOrder"}
        ],
        {trigger_opt, trigger_value, native_type} <- [
          {:trigger_price, "3000", "STOP_MARKET"},
          {:stop_loss_price, "2900", "STOP_MARKET"},
          {:take_profit_price, "3100", "TAKE_PROFIT_MARKET"}
        ] do
      {requests, stub} = algo_order_stub()
      exchange = Exchange.new!(exchange_id, api_key: "key", secret: "secret", sandbox: true)

      opts = [
        {trigger_opt, trigger_value},
        time_in_force: "GTC",
        reduce_only: true,
        plug: {Req.Test, stub},
        timestamp_ms_override: @frozen_timestamp_ms
      ]

      assert {:ok, %Bourse.Order{}} =
               Bourse.create_order(exchange, symbol, "market", "sell", 1, opts)

      assert_order_request(requests, :post, expected_path, fn params ->
        assert params["algoType"] == "CONDITIONAL"
        assert params["quantity"] == "1"
        assert params["reduceOnly"] == "true"
        assert params["side"] == "SELL"
        assert params["timeInForce"] == "GTC"
        assert params["triggerPrice"] == trigger_value
        assert params["type"] == native_type
        refute Map.has_key?(params, Atom.to_string(trigger_opt))
      end)
    end
  end

  test "Binance conditional orders reject simultaneous stop-loss and take-profit legs" do
    for {exchange_id, symbol} <- [
          {"binance", "ETH/USDT:USDT"},
          {"binanceusdm", "ETH/USDT:USDT"},
          {"binancecoinm", "BTC/USD:BTC"}
        ] do
      exchange = Exchange.new!(exchange_id, api_key: "key", secret: "secret", sandbox: true)

      error =
        assert_raise Bourse.Error, fn ->
          Bourse.create_order(exchange, symbol, "market", "sell", 1,
            stop_loss_price: "2900",
            take_profit_price: "3100"
          )
        end

      assert error.type == :invalid_parameters

      assert error.message ==
               "binance-family create_order accepts one conditional leg per order (stop_loss_price OR take_profit_price); two-leg protection is a separate order-list surface"
    end
  end

  test "Binance spot create_order preserves native pass-through controls" do
    {requests, stub} = order_stub()
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, %Bourse.Order{}} =
             Bourse.create_order(exchange, "BTC/USDT", "limit", "buy", 1,
               price: "1000",
               timeInForce: "GTC",
               newClientOrderId: "task-578-spot",
               newOrderRespType: "ACK",
               plug: {Req.Test, stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert_order_request(requests, :post, "/api/v3/order", fn params ->
      assert params["timeInForce"] == "GTC"
      assert params["newClientOrderId"] == "task-578-spot"
      assert params["newOrderRespType"] == "ACK"
    end)
  end

  test "Binance USD-M margin mode calls send the futures symbol" do
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    {margin_requests, margin_stub} = body_capturing_stub(%{"code" => 200, "msg" => "success"})

    assert {:ok, %{"code" => 200}} =
             Bourse.set_margin_mode(exchange, "isolated", "ETH/USDT:USDT",
               plug: {Req.Test, margin_stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_order_request(margin_requests, :post, "/fapi/v1/marginType", fn params ->
      assert params["marginType"] == "ISOLATED"
      assert params["symbol"] == "ETHUSDT"
    end)

    {cross_requests, cross_stub} = body_capturing_stub(%{"code" => 200, "msg" => "success"})

    assert {:ok, %{"code" => 200}} =
             Bourse.set_margin_mode(exchange, "cross", "ETH/USDT:USDT",
               plug: {Req.Test, cross_stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_order_request(cross_requests, :post, "/fapi/v1/marginType", fn params ->
      assert params["marginType"] == "CROSSED"
      assert params["symbol"] == "ETHUSDT"
    end)
  end

  test "dedicated Binance futures margin mode calls send margin type and symbol" do
    for {exchange_id, symbol, expected_path} <- [
          {"binanceusdm", "ETH/USDT:USDT", "/fapi/v1/marginType"},
          {"binancecoinm", "BTC/USD:BTC", "/dapi/v1/marginType"}
        ] do
      {requests, stub} = body_capturing_stub(%{"code" => 200, "msg" => "success"})
      exchange = Exchange.new!(exchange_id, api_key: "key", secret: "secret", sandbox: true)

      assert {:ok, %{"code" => 200}} =
               Bourse.set_margin_mode(exchange, "cross", symbol,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: @frozen_timestamp_ms
               )

      assert_order_request(requests, :post, expected_path, fn params ->
        assert params["marginType"] == "CROSSED"
        refute params["marginType"] == params["symbol"]
      end)
    end
  end

  test "dedicated Binance futures position mode preserves false on the signed wire" do
    for {exchange_id, expected_path} <- [
          {"binanceusdm", "/fapi/v1/positionSide/dual"},
          {"binancecoinm", "/dapi/v1/positionSide/dual"}
        ] do
      {requests, stub} = body_capturing_stub(%{"code" => 200, "msg" => "success"})
      exchange = Exchange.new!(exchange_id, api_key: "key", secret: "secret", sandbox: true)

      assert {:ok, %{"code" => 200}} =
               Bourse.set_position_mode(exchange, false,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: @frozen_timestamp_ms
               )

      assert_order_request(requests, :post, expected_path, fn params ->
        assert params["dualSidePosition"] == "false"
      end)
    end
  end

  test "Binance COIN-M set leverage forwards the native symbol and leverage" do
    response = %{"leverage" => 3, "maxQty" => "1000", "symbol" => "BTCUSD_PERP"}
    {requests, stub} = body_capturing_stub(response)
    exchange = Exchange.new!("binancecoinm", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, ^response} =
             Bourse.set_leverage(exchange, 3, "BTC/USD:BTC",
               plug: {Req.Test, stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert_order_request(requests, :post, "/dapi/v1/leverage", fn params ->
      assert params["leverage"] == "3"
      assert params["symbol"] == "BTCUSD_PERP"
    end)
  end

  test "dedicated Binance futures fetch leverage reads flat-symbol configuration" do
    for {exchange_id, symbol, native_symbol, expected_path, expected_margin_mode, response} <- [
          {"binanceusdm", "ETH/USDT:USDT", "ETHUSDT", "/fapi/v1/symbolConfig", "cross",
           [%{"symbol" => "ETHUSDT", "leverage" => 3, "marginType" => "CROSSED"}]},
          {"binancecoinm", "BTC/USD:BTC", "BTCUSD_PERP", "/dapi/v1/account", nil,
           %{"positions" => [%{"symbol" => "BTCUSD_PERP", "leverage" => "3", "positionAmt" => "0"}]}}
        ] do
      {requests, stub} = body_capturing_stub(response)

      exchange =
        exchange_id
        |> Exchange.new!(api_key: "key", secret: "secret", sandbox: true)
        |> Exchange.put_markets([
          %Bourse.Market{id: native_symbol, symbol: symbol, type: "swap", swap: true, contract: true}
        ])

      # margin_mode must share fetch_margin_mode's vocabulary: CROSSED -> "cross",
      # never the bare safeStringLower "crossed".
      assert {:ok,
              %Bourse.Leverage{
                symbol: ^symbol,
                long_leverage: 3,
                short_leverage: 3,
                margin_mode: ^expected_margin_mode
              }} =
               Bourse.fetch_leverage(exchange, symbol,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: @frozen_timestamp_ms
               )

      assert_order_request(requests, :get, expected_path, fn params ->
        if exchange_id == "binanceusdm" do
          assert params["symbol"] == native_symbol
        else
          refute Map.has_key?(params, "symbol")
        end
      end)
    end
  end

  test "Binance USD-M open orders merge the regular and Algo books" do
    stub = unique_stub("binance_open_order_books")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      body =
        case conn.request_path do
          "/fapi/v1/openOrders" -> [regular_open_order()]
          "/fapi/v1/openAlgoOrders" -> [algo_open_order()]
        end

      Req.Test.json(conn, body)
    end)

    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, orders} =
             Bourse.fetch_open_orders(exchange,
               symbol: "ETH/USDT:USDT",
               plug: {Req.Test, stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert orders |> Enum.map(& &1.id) |> Enum.sort() == ["12345", "9001"]

    assert recorded_paths(requests) == ["/fapi/v1/openAlgoOrders", "/fapi/v1/openOrders"]
  end

  test "Binance USD-M cancel_order falls through order-not-found to the Algo book" do
    stub = unique_stub("binance_cancel_order_books")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      {conn, _body} = RequestCollector.capture_with_body(requests, conn)

      case conn.request_path do
        "/fapi/v1/order" ->
          conn
          |> Plug.Conn.put_status(@bad_request_status)
          |> Req.Test.json(%{"code" => -2011, "msg" => "Unknown order sent."})

        "/fapi/v1/algoOrder" ->
          Req.Test.json(conn, %{"algoId" => "9001", "clientAlgoId" => "algo-client", "code" => "200", "msg" => "success"})
      end
    end)

    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, %Bourse.Order{id: "9001"}} =
             Bourse.cancel_order(exchange, "9001",
               symbol: "ETH/USDT:USDT",
               plug: {Req.Test, stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    [regular, algo] = RequestCollector.requests(requests)
    assert regular.conn.request_path == "/fapi/v1/order"
    assert request_params(regular.conn, regular.body)["orderId"] == "9001"
    assert algo.conn.request_path == "/fapi/v1/algoOrder"
    assert request_params(algo.conn, algo.body)["algoId"] == "9001"
  end

  test "Binance USD-M cancel_all_orders broadcasts to the regular and Algo books" do
    stub = unique_stub("binance_cancel_all_order_books")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, %{"code" => 200, "msg" => "done"})
    end)

    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, %{"code" => 200, "msg" => "done"}} =
             Bourse.cancel_all_orders(exchange,
               symbol: "ETH/USDT:USDT",
               plug: {Req.Test, stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert recorded_paths(requests) == ["/fapi/v1/algoOpenOrders", "/fapi/v1/allOpenOrders"]
  end

  test "dedicated Binance futures cancel_all_orders broadcasts and accepts code 200" do
    for {exchange_id, symbol, expected_paths} <- [
          {"binanceusdm", "ETH/USDT:USDT", ["/fapi/v1/algoOpenOrders", "/fapi/v1/allOpenOrders"]},
          {"binancecoinm", "BTC/USD:BTC", ["/dapi/v1/algoOpenOrders", "/dapi/v1/allOpenOrders"]}
        ] do
      stub = unique_stub("dedicated_binance_cancel_all")
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"code" => 200, "msg" => "done"})
      end)

      exchange = Exchange.new!(exchange_id, api_key: "key", secret: "secret", sandbox: true)

      assert {:ok, %{"code" => 200, "msg" => "done"}} =
               Bourse.cancel_all_orders(exchange,
                 symbol: symbol,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: @frozen_timestamp_ms
               )

      assert recorded_paths(requests) == expected_paths
    end
  end

  test "raw capture executes both book writes and preserves cancel fallback semantics" do
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    broadcast_stub = unique_stub("binance_capture_cancel_all_books")
    {:ok, broadcast_requests} = RequestCollector.start_link()

    Req.Test.stub(broadcast_stub, fn conn ->
      conn = RequestCollector.capture(broadcast_requests, conn)
      Req.Test.json(conn, %{"code" => 200, "msg" => "done"})
    end)

    assert {:ok, %{body: %{"code" => 200}}} =
             Unified.capture_responses(exchange, :cancel_all_orders, %{"symbol" => "ETH/USDT:USDT"},
               plug: {Req.Test, broadcast_stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert recorded_paths(broadcast_requests) == ["/fapi/v1/algoOpenOrders", "/fapi/v1/allOpenOrders"]

    fallback_stub = unique_stub("binance_capture_cancel_order_books")
    {:ok, fallback_requests} = RequestCollector.start_link()

    Req.Test.stub(fallback_stub, fn conn ->
      conn = RequestCollector.capture(fallback_requests, conn)

      case conn.request_path do
        "/fapi/v1/order" ->
          conn
          |> Plug.Conn.put_status(@bad_request_status)
          |> Req.Test.json(%{"code" => -2011, "msg" => "Unknown order sent."})

        "/fapi/v1/algoOrder" ->
          Req.Test.json(conn, %{"algoId" => "9001", "algoStatus" => "CANCELED"})
      end
    end)

    assert {:ok, %{body: %{"algoId" => "9001"}}} =
             Unified.capture_responses(exchange, :cancel_order, %{"id" => "9001", "symbol" => "ETH/USDT:USDT"},
               plug: {Req.Test, fallback_stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert recorded_paths(fallback_requests) == ["/fapi/v1/algoOrder", "/fapi/v1/order"]
  end

  test "Binance USD-M book routing rejects unreachable and malformed authored directives" do
    assert {:error, %Bourse.Error{type: :authentication_error}} =
             Bourse.fetch_open_orders(Exchange.new!("binance"), symbol: "ETH/USDT:USDT")

    exchange = Exchange.new!("binance", api_key: "key", secret: "secret")

    for route <- [
          %{"mode" => "merge", "endpoints" => ["missing"], "when" => %{"market_family" => "linear"}},
          %{"mode" => "merge", "when" => %{"market_family" => "linear"}},
          %{
            "mode" => "unknown",
            "endpoints" => ["fapiPrivate_get_openorders", "fapiPrivate_get_openalgoorders"],
            "when" => %{"market_family" => "linear"}
          }
        ] do
      malformed = put_in(exchange.endpoint_selection["fetchOpenOrders"]["book_routes"], [route])

      assert {:error, %Bourse.Error{type: :bad_request, message: message}} =
               Bourse.fetch_open_orders(malformed, symbol: "ETH/USDT:USDT")

      assert message == "invalid authored order-book route for fetchOpenOrders on binance"
    end
  end

  test "Binance USD-M cancel fallback stops on errors other than order-not-found" do
    stub = unique_stub("binance_cancel_order_non_missing_error")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      conn
      |> Plug.Conn.put_status(@bad_request_status)
      |> Req.Test.json(%{"code" => -1121, "msg" => "Invalid symbol."})
    end)

    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    assert {:error, %Bourse.Error{type: :bad_symbol, code: -1121}} =
             Bourse.cancel_order(exchange, "9001",
               symbol: "ETH/USDT:USDT",
               plug: {Req.Test, stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert recorded_paths(requests) == ["/fapi/v1/order"]
  end

  test "Binance balance atom types select the intended account family" do
    credentials = [api_key: "key", secret: "secret", sandbox: true]

    {swap_requests, swap_stub} = account_stub(futures_balance_body())

    assert {:ok, %Balance{total: %{"USDT" => 5.0}}} =
             Bourse.fetch_balance(Exchange.new!("binance", credentials),
               type: :swap,
               plug: {Req.Test, swap_stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_account_request(swap_requests, "/fapi/v3/account")

    {delivery_requests, delivery_stub} = account_stub(futures_balance_body())

    assert {:ok, %Balance{total: %{"USDT" => 5.0}}} =
             Bourse.fetch_balance(Exchange.new!("binance", credentials),
               type: :delivery,
               plug: {Req.Test, delivery_stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_account_request(delivery_requests, "/dapi/v1/account")

    {spot_requests, spot_stub} = account_stub(%{"balances" => [%{"asset" => "USDT", "free" => "5", "locked" => "0"}]})

    assert {:ok, %Balance{total: %{"USDT" => 5.0}}} =
             Bourse.fetch_balance(Exchange.new!("binance", credentials),
               type: :spot,
               plug: {Req.Test, spot_stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_account_request(spot_requests, "/api/v3/account")

    assert {:error, %Bourse.Error{type: :not_supported, message: message}} =
             Bourse.fetch_balance(Exchange.new!("binance", credentials), type: :margin)

    assert message == "No base URL for section sapi on binance (sandbox)"
  end

  test "Binance spot selectors reach private and SAPI endpoint families" do
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret")

    for {method, params, expected_path} <- [
          {:fetch_order_trades, %{"id" => "1", "symbol" => "BTCUSDT"}, "/api/v3/myTrades"},
          {:fetch_open_order, %{"id" => "1", "symbol" => "BTCUSDT"}, "/api/v3/order"},
          {:fetch_trading_fee, %{"symbol" => "BTCUSDT"}, "/sapi/v1/asset/tradeFee"},
          {:fetch_my_liquidations, %{}, "/sapi/v1/margin/forceLiquidationRec"},
          {:fetch_convert_trade, %{"id" => "1"}, "/sapi/v1/convert/orderStatus"},
          {:fetch_convert_trade_history, %{}, "/sapi/v1/convert/tradeFlow"}
        ] do
      {requests, stub} = path_body_stub([])
      params = Map.put(params, "type", "spot")

      assert {:ok, _response} =
               Unified.raw_call(exchange, method, params,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: 1_700_000_000_000
               )

      request = RequestCollector.one!(requests)
      assert request.request_path == expected_path
      refute Map.has_key?(RequestCollector.query(request), "type")
    end
  end

  test "USD-M position and leverage methods select semantic endpoints and parse typed results" do
    exchange =
      "binanceusdm"
      |> Exchange.new!(api_key: "key", secret: "secret", sandbox: true)
      |> Exchange.put_markets([
        %Bourse.Market{id: "IDOL", symbol: "IDOL/USDT:USDT", type: "swap", swap: true, contract: true}
      ])

    position = %{
      "symbol" => "KAVAUSDT",
      "positionAmt" => "1",
      "entryPrice" => "0.5",
      "markPrice" => "0.6",
      "leverage" => "20",
      "marginType" => "cross",
      "notional" => "0.6",
      "unRealizedProfit" => "0.1",
      "updateTime" => 1_700_000_000_000
    }

    assert_usdm_typed_endpoint(
      exchange,
      :fetch_positions_risk,
      "fetchPositionsRisk",
      [position],
      "/fapi/v3/positionRisk",
      fn result -> assert [%Position{info: ^position}] = result end
    )

    assert_usdm_typed_endpoint(
      exchange,
      :fetch_account_positions,
      "fetchAccountPositions",
      %{"positions" => [position]},
      "/fapi/v3/account",
      fn result -> assert [%Position{info: ^position}] = result end
    )

    btc_leverage = %{"symbol" => "BTCUSDT", "leverage" => "20", "marginType" => "CROSSED"}
    eth_leverage = %{"symbol" => "ETHUSDT", "leverage" => "10", "marginType" => "ISOLATED"}
    idol_leverage = %{"symbol" => "IDOL", "leverage" => "5", "marginType" => "CROSSED"}

    assert_usdm_typed_endpoint(
      exchange,
      :fetch_leverages,
      "fetchLeverages",
      [btc_leverage, eth_leverage, idol_leverage],
      "/fapi/v1/symbolConfig",
      fn result ->
        assert %{
                 "BTC/USDT:USDT" => %Bourse.Leverage{
                   long_leverage: 20,
                   short_leverage: 20,
                   margin_mode: "cross",
                   info: ^btc_leverage
                 },
                 "ETH/USDT:USDT" => %Bourse.Leverage{
                   long_leverage: 10,
                   short_leverage: 10,
                   margin_mode: "isolated",
                   info: ^eth_leverage
                 },
                 "IDOL/USDT:USDT" => %Bourse.Leverage{
                   long_leverage: 5,
                   short_leverage: 5,
                   margin_mode: "cross",
                   info: ^idol_leverage
                 }
               } = result
      end
    )
  end

  test "COIN-M full order history powers direct and status-filtered unified reads" do
    exchange = Exchange.new!("binancecoinm", api_key: "key", secret: "secret", sandbox: true)

    canceled = coinm_order_row(1, "CANCELED")
    filled = coinm_order_row(2, "FILLED")

    assert Exchange.has?(exchange, "fetchOrders")
    assert exchange.has["fetchClosedOrders"] == "emulated"
    assert exchange.has["fetchCanceledOrders"] == "emulated"

    assert_coinm_typed_endpoint(
      exchange,
      :fetch_orders,
      "fetchOrders",
      %{"symbol" => "BTC/USD:BTC"},
      [canceled, filled],
      "/dapi/v1/allOrders",
      fn result ->
        assert [%Bourse.Order{id: "1", status: "canceled"}, %Bourse.Order{id: "2", status: "closed"}] = result
      end
    )

    assert_coinm_typed_endpoint(
      exchange,
      :fetch_closed_orders,
      "fetchClosedOrders",
      %{"symbol" => "BTC/USD:BTC"},
      [canceled, filled],
      "/dapi/v1/allOrders",
      fn result -> assert [%Bourse.Order{id: "2", status: "closed"}] = result end
    )

    assert_coinm_typed_endpoint(
      exchange,
      :fetch_canceled_orders,
      "fetchCanceledOrders",
      %{"symbol" => "BTC/USD:BTC"},
      [canceled, filled],
      "/dapi/v1/allOrders",
      fn result -> assert [%Bourse.Order{id: "1", status: "canceled"}] = result end
    )
  end

  test "COIN-M account analytics select DAPI endpoints and return typed structs" do
    exchange = Exchange.new!("binancecoinm", api_key: "key", secret: "secret", sandbox: true)
    symbol = "BTC/USD:BTC"

    for capability <- ~w(fetchLeverageTiers fetchOpenInterest fetchTradingFees fetchLedger fetchADLRank) do
      assert Exchange.has?(exchange, capability)
    end

    leverage_body = [
      %{
        "symbol" => "BTCUSD_PERP",
        "brackets" => [
          %{
            "bracket" => 1,
            "initialLeverage" => 125,
            "maintMarginRatio" => "0.004",
            "qtyCap" => 50,
            "qtyFloor" => 0
          }
        ]
      }
    ]

    assert_coinm_typed_endpoint(
      exchange,
      :fetch_leverage_tiers,
      "fetchLeverageTiers",
      %{"symbol" => symbol},
      leverage_body,
      "/dapi/v2/leverageBracket",
      fn result ->
        assert [
                 %Bourse.LeverageTier{
                   symbol: ^symbol,
                   tier: 1,
                   min_notional: nil,
                   max_notional: nil,
                   maintenance_margin_rate: 0.004,
                   max_leverage: 125,
                   info: %{"qtyFloor" => 0, "qtyCap" => 50}
                 }
               ] = result
      end
    )

    open_interest = %{
      "contractType" => "PERPETUAL",
      "openInterest" => "15004",
      "pair" => "BTCUSD",
      "symbol" => "BTCUSD_PERP",
      "time" => @frozen_timestamp_ms
    }

    assert_coinm_typed_endpoint(
      exchange,
      :fetch_open_interest,
      "fetchOpenInterest",
      %{"symbol" => symbol},
      open_interest,
      "/dapi/v1/openInterest",
      fn result ->
        assert %Bourse.OpenInterest{
                 symbol: ^symbol,
                 open_interest_amount: 15_004.0,
                 timestamp: @frozen_timestamp_ms,
                 info: ^open_interest
               } = result
      end
    )

    commission = %{
      "makerCommissionRate" => "0.00015",
      "rpiCommissionRate" => "0.00005",
      "symbol" => "BTCUSD_PERP",
      "takerCommissionRate" => "0.0004"
    }

    assert_coinm_typed_endpoint(
      exchange,
      :fetch_trading_fees,
      "fetchTradingFees",
      %{"symbol" => symbol},
      commission,
      "/dapi/v1/commissionRate",
      fn result ->
        assert %{
                 ^symbol => %Bourse.TradingFee{
                   symbol: ^symbol,
                   maker: 0.00015,
                   taker: 0.0004,
                   info: ^commission
                 }
               } = result
      end
    )

    income = %{
      "asset" => "BTC",
      "income" => "-0.00000375",
      "incomeType" => "TRANSFER",
      "symbol" => "",
      "time" => @frozen_timestamp_ms,
      "tradeId" => "7",
      "tranId" => 42
    }

    assert_coinm_typed_endpoint(
      exchange,
      :fetch_ledger,
      "fetchLedger",
      %{},
      [income],
      "/dapi/v1/income",
      fn result ->
        assert [
                 %Bourse.LedgerEntry{
                   id: "42",
                   reference_id: "7",
                   type: "transfer",
                   currency: "BTC",
                   amount: -0.00000375,
                   direction: "out",
                   timestamp: @frozen_timestamp_ms,
                   info: ^income
                 }
               ] = result
      end
    )

    adl = %{"adlQuantile" => %{"BOTH" => 0, "LONG" => 0, "SHORT" => 0}, "symbol" => "BTCUSD_PERP"}

    assert_coinm_typed_endpoint(
      exchange,
      :fetch_adl_rank,
      "fetchADLRank",
      %{"symbol" => symbol},
      [adl],
      "/dapi/v1/adlQuantile",
      fn result -> assert %Bourse.ADLRank{symbol: ^symbol, rank: 0, info: ^adl} = result end
    )
  end

  test "Binance sandbox routes futures APIs to the current Demo Trading hosts" do
    for exchange_id <- ["binance", "binanceusdm"] do
      urls = Exchange.new!(exchange_id, sandbox: true).base_urls

      assert urls["dapiPrivate"] == "https://demo-dapi.binance.com/dapi/v1"
      assert urls["dapiPublic"] == "https://demo-dapi.binance.com/dapi/v1"
      assert urls["fapiPrivateV3"] == "https://demo-fapi.binance.com/fapi/v3"
      assert urls["fapiPublic"] == "https://demo-fapi.binance.com/fapi/v1"
      assert urls["private"] == "https://testnet.binance.vision/api/v3"
    end
  end

  test "portfolio borrow interest selects PAPI and unwraps documented rows" do
    body = %{
      "total" => "1",
      "rows" => [
        %{
          "txId" => "1656187724899910076",
          "interestAccuredTime" => "1707562800000",
          "asset" => "USDT",
          "rawAsset" => "USDT",
          "principal" => "0.00011146",
          "interest" => "0.000000010",
          "interestRate" => "0.00089489",
          "type" => "PERIODIC"
        }
      ]
    }

    {requests, stub} = path_body_stub(body)
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret")

    assert {:ok, [%BorrowInterest{} = interest]} =
             Unified.call(
               exchange,
               :fetch_borrow_interest,
               "fetchBorrowInterest",
               %{"code" => "USDT", "portfolioMargin" => true},
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    request = RequestCollector.one!(requests)
    assert request.request_path == "/papi/v1/margin/marginInterestHistory"
    assert URI.decode_query(request.query_string)["asset"] == "USDT"
    assert interest.currency == "USDT"
    assert interest.margin_mode == "cross"
    assert interest.timestamp == 1_707_562_800_000
    assert_in_delta interest.amount_borrowed, 0.00011146, 1.0e-12
    assert_in_delta interest.interest, 1.0e-8, 1.0e-14

    isolated = put_in(body, ["rows", Access.at(0), "isolatedSymbol"], "BNBUSDT")

    assert {:ok, [%BorrowInterest{margin_mode: "isolated"}]} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :fetch_borrow_interest,
               "fetchBorrowInterest",
               isolated,
               %{},
               :parse_borrow_interest,
               true
             )
  end

  test "single-symbol option marks use Binance's native symbol query and normalize into greeks" do
    row = %{
      "symbol" => "ETH-231229-800-C",
      "markPrice" => "1789.2",
      "bidIV" => "-0.00000001",
      "askIV" => "-0.00000001",
      "markIV" => "0.708575",
      "delta" => "-0.91110168",
      "theta" => "-1.0575559",
      "gamma" => "0.0001436",
      "vega" => "2.00337645",
      "highPriceLimit" => "1982.4",
      "lowPriceLimit" => "1596",
      "riskFreeInterest" => "0.065"
    }

    {requests, stub} = path_body_stub([row])
    symbol = "ETH/USDT:USDT-231229-800-C"

    assert {:ok, %{^symbol => %Greeks{} = greeks}} =
             Unified.call(
               Exchange.new!("binance"),
               :fetch_all_greeks,
               "fetchAllGreeks",
               %{"symbols" => [symbol]},
               plug: {Req.Test, stub}
             )

    request = RequestCollector.one!(requests)
    assert request.request_path == "/eapi/v1/mark"
    assert URI.decode_query(request.query_string) == %{"symbol" => "ETH-231229-800-C"}
    assert greeks.symbol == symbol
    assert greeks.mark_price == 1789.2
    assert greeks.mark_implied_volatility == 0.708575
    assert greeks.info["riskFreeInterest"] == "0.065"
  end

  test "multi-symbol option marks drop the unified list and filter client-side" do
    rows =
      for id <- ["ETH-231229-800-C", "ETH-231229-900-C", "BTC-231229-40000-C"] do
        %{"symbol" => id, "markPrice" => "1.0", "markIV" => "0.5", "delta" => "-0.5"}
      end

    {requests, stub} = path_body_stub(rows)
    requested = ["ETH/USDT:USDT-231229-800-C", "ETH/USDT:USDT-231229-900-C"]

    assert {:ok, greeks} =
             Unified.call(
               Exchange.new!("binance"),
               :fetch_all_greeks,
               "fetchAllGreeks",
               %{"symbols" => requested},
               plug: {Req.Test, stub}
             )

    # Binance's Option Mark Price schema defines a single optional `symbol` and no
    # `symbols[]` list, so a multi-symbol read must send neither and narrow after parse.
    request = RequestCollector.one!(requests)
    assert request.request_path == "/eapi/v1/mark"
    assert URI.decode_query(request.query_string) == %{}

    assert greeks |> Map.keys() |> Enum.sort() == Enum.sort(requested)
  end

  test "borrow interest maps cross and isolated filters to Binance's documented query fields" do
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret")

    assert_borrow_interest_request(
      exchange,
      %{"code" => "USDT", "since" => 1_700_000_000_000, "until" => 1_700_086_400_000, "limit" => 25},
      %{
        "asset" => "USDT",
        "startTime" => "1700000000000",
        "endTime" => "1700086400000",
        "size" => "25"
      }
    )

    assert_borrow_interest_request(
      exchange,
      %{"code" => "USDT", "symbol" => "BTC/USDT"},
      %{"asset" => "USDT", "isolatedSymbol" => "BTCUSDT"}
    )
  end

  test "order-history reads map since and omit an absent limit" do
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret")
    since = 1_700_000_000_000

    for {method, js_name, params, expected} <- [
          {:fetch_orders, "fetchOrders", %{"symbol" => "BTC/USDT", "since" => since, "limit" => 25},
           %{"symbol" => "BTCUSDT", "startTime" => Integer.to_string(since), "limit" => "25"}},
          {:fetch_closed_orders, "fetchClosedOrders", %{"symbol" => "BTC/USDT", "since" => since},
           %{"symbol" => "BTCUSDT", "startTime" => Integer.to_string(since)}}
        ] do
      {requests, stub} = path_body_stub([])

      assert {:ok, []} =
               Unified.call(exchange, method, js_name, params,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: since
               )

      request = RequestCollector.one!(requests)
      assert request.request_path == "/api/v3/allOrders"

      query = request |> RequestCollector.query() |> Map.drop(["timestamp", "signature", "recvWindow"])
      assert query == expected
      refute Enum.any?(query, fn {_key, value} -> value == "" end)
    end
  end

  test "convert quote uses request currencies and the venue price ratio" do
    body = %{
      "ratio" => "0.999351",
      "inverseRatio" => "1.00065",
      "validTimestamp" => "1718724795211",
      "toAmount" => "4.99675625",
      "fromAmount" => "5"
    }

    assert {:ok,
            %Conversion{
              id: nil,
              from_currency: "USDC",
              from_amount: 5.0,
              to_currency: "USDT",
              to_amount: 4.99675625,
              price: 0.999351,
              timestamp: 1_718_724_795_211,
              datetime: "2024-06-18T15:33:15.211Z",
              info: ^body
            }} =
             ReadParse.parse(
               Exchange.new!("binance"),
               Bourse.Binance,
               :fetch_convert_quote,
               "fetchConvertQuote",
               body,
               %{"from_code" => "USDC", "to_code" => "USDT", "amount" => 5},
               :parse_conversion,
               false
             )
  end

  # The parse above supplies its own params map, so it cannot prove which key
  # names the unified layer actually hands the parser. Binance's quote response
  # omits both asset codes, so the currencies exist only if `from_code`/`to_code`
  # survive the real dispatch — assert that end to end.
  test "convert quote currencies come from the dispatched unified params" do
    body = %{
      "quoteId" => "12415572564",
      "ratio" => "0.999351",
      "inverseRatio" => "1.00065",
      "validTimestamp" => "1718724795211",
      "toAmount" => "4.99675625",
      "fromAmount" => "5"
    }

    {requests, stub} = path_body_stub(body)
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret")

    assert {:ok, %Conversion{} = conversion} =
             Unified.call(
               exchange,
               :fetch_convert_quote,
               "fetchConvertQuote",
               %{"from_code" => "USDC", "to_code" => "USDT", "amount" => 5},
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_path_body_request(requests, "/sapi/v1/convert/getQuote")
    assert conversion.id == "12415572564"
    assert conversion.from_currency == "USDC"
    assert conversion.to_currency == "USDT"
    assert conversion.price == 0.999351
  end

  test "every shaped Binance method resolves its identifier references" do
    for exchange <- Enum.map(["binance", "binanceusdm"], &Exchange.new!/1),
        {_method, js_name, required, _description} <- Unified.method_defs(),
        Map.has_key?(exchange.request_param_shape, js_name) do
      params = Map.new(required, &{Atom.to_string(&1), identifier_value(&1)})

      assert is_map(RequestShape.apply(params, exchange, js_name)),
             "#{exchange.id} #{js_name} left an identifier reference unresolved"
    end
  end

  # Task 418 — dormant futuresTransfer / verifyGiftCode shape entries (not in
  # method_defs/0) still resolve their Bourse identifier renames so the task-267
  # shaped-method sweep stays green without exposing the methods on the unified API.
  test "dormant futuresTransfer and verifyGiftCode bind their Bourse argument names" do
    futures_params = %{"code" => "USDT", "amount" => 1.5, "type" => 1}
    verify_params = %{"id" => "0033002404219823"}

    for exchange_id <- ["binance", "binanceusdm"] do
      exchange = Exchange.new!(exchange_id)

      assert RequestShape.apply(futures_params, exchange, "futuresTransfer") == %{
               "amount" => 1.5,
               "asset" => "USDT",
               "type" => 1
             }

      assert RequestShape.apply(verify_params, exchange, "verifyGiftCode") == %{
               "referenceNo" => "0033002404219823"
             }
    end
  end

  test "shaped-method sweep reports zero unresolved identifier_reference for binance family" do
    # Mirrors task 267's apply/3 sweep over every request_param_shape method,
    # seeding inventory-shaped args for the two dormant methods that are not in
    # method_defs/0. Any unresolved identifier_reference raises ArgumentError.
    seed = %{
      "code" => "USDT",
      "amount" => 1,
      "type" => 1,
      "id" => "ref-418",
      "symbol" => "BTC/USDT",
      "address" => "addr",
      "from_code" => "USDC",
      "to_code" => "USDT",
      "hedge_mode" => true
    }

    for exchange_id <- ["binance", "binanceusdm"] do
      exchange = Exchange.new!(exchange_id)

      for {js_name, _entries} <- exchange.request_param_shape do
        assert is_map(RequestShape.apply(seed, exchange, js_name)),
               "#{exchange_id} #{js_name} left an identifier reference unresolved"
      end
    end
  end

  test "convert quote and position mode bind their unified argument names" do
    convert_params = Unified.build_params([:from_code, :to_code, :amount], ["USDC", "USDT", 3], [])
    position_params = Unified.build_params([:hedge_mode], [true], [])

    for exchange_id <- ["binance", "binanceusdm"] do
      exchange = Exchange.new!(exchange_id)

      assert RequestShape.apply(convert_params, exchange, "fetchConvertQuote") == %{
               "fromAmount" => 3,
               "fromAsset" => "USDC",
               "toAsset" => "USDT"
             }

      assert RequestShape.apply(position_params, exchange, "setPositionMode") == %{
               "dualSidePosition" => "true"
             }
    end
  end

  test "inverse positions use the loaded market contract size and do not invent cross collateral" do
    exchange =
      "binance"
      |> Exchange.new!()
      |> Exchange.put_markets([
        %{"id" => "ETHUSD_PERP", "symbol" => "ETH/USD:ETH", "contractSize" => 10}
      ])

    row = %{
      "symbol" => "ETHUSD_PERP",
      "positionAmt" => "2",
      "notionalValue" => "0.01",
      "unRealizedProfit" => "0.0001",
      "leverage" => "20",
      "marginType" => "cross",
      "markPrice" => "2000",
      "updateTime" => "1722105622903"
    }

    assert {:ok, [%Position{} = position]} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :fetch_positions,
               "fetchPositions",
               [row],
               %{"type" => "inverse"},
               :parse_position,
               true
             )

    assert position.contracts == 2
    assert position.contract_size == 10
    assert position.notional == 0.01
    assert position.initial_margin == 0.0005
    assert position.maintenance_margin == nil
    assert position.margin_ratio == nil
    assert position.percentage == nil
    assert position.collateral == nil
  end

  # Binance reuses one exchange id across market types: `BTCUSDT` is both the
  # spot market (contractSize null) and the USD-M linear swap (contractSize 1).
  # A position row is always a contract, so the spot record must never win the
  # lookup — a bare id match resolves spot first and reports contract_size nil.
  test "linear positions resolve the contract market when spot shares the exchange id" do
    exchange =
      "binanceusdm"
      |> Exchange.new!()
      |> Exchange.put_markets([
        %Bourse.Market{id: "BTCUSDT", symbol: "BTC/USDT", type: "spot", spot: true, contract: false},
        %Bourse.Market{
          id: "BTCUSDT",
          symbol: "BTC/USDT:USDT",
          type: "swap",
          swap: true,
          contract: true,
          linear: true,
          contract_size: 1
        }
      ])

    row = %{
      "symbol" => "BTCUSDT",
      "positionAmt" => "0.009",
      "notional" => "607.52416678",
      "leverage" => "80",
      "marginType" => "cross",
      "initialMargin" => "7.59405208",
      "maintMargin" => "2.43009666",
      "unRealizedProfit" => "0.51106678",
      "markPrice" => "67502.68519858",
      "updateTime" => "1722161166529"
    }

    assert {:ok, [%Position{} = position]} =
             ReadParse.parse(
               exchange,
               Bourse.Binanceusdm,
               :fetch_positions,
               "fetchPositions",
               [row],
               %{},
               :parse_position,
               true
             )

    assert position.contract_size == 1
    assert position.notional == 607.52416678
    assert position.initial_margin == 7.59405208
    assert position.maintenance_margin == 2.43009666
    assert position.margin_ratio == nil
    assert position.percentage == 6.73
    assert position.collateral == nil
  end

  # Bourse binance.ts keeps spot/linear/inverse under sandbox and drops only the
  # sapi margin pairs (`!isDemoEnv`) and `option`. Binance's testnet publishes no
  # sapi/eapi base, so either wave rides the dapi template and answers -5000 for
  # `/dapi/v1/margin/allPairs` — the stub raises on any path outside the set, so
  # a re-introduced margin/option wave fails here rather than live.
  test "binance sandbox fetch_markets fans out to spot, linear and inverse only" do
    {paths, stub} =
      recording_markets_stub(%{
        "/api/v3/exchangeInfo" => %{"symbols" => []},
        "/fapi/v1/exchangeInfo" => %{"symbols" => []},
        "/dapi/v1/exchangeInfo" => %{"symbols" => []}
      })

    result =
      Unified.call(Exchange.new!("binance", sandbox: true), :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

    assert_recorded_paths(
      paths,
      [
        "/api/v3/exchangeInfo",
        "/dapi/v1/exchangeInfo",
        "/fapi/v1/exchangeInfo"
      ],
      "unexpected Binance sandbox fetchMarkets path"
    )

    assert {:ok, []} = result
  end

  # Bourse binanceusdm.ts pins `options.fetchMarkets.types` to `['linear']` — the
  # no-arg fan-out collapses to the single fapi surface on mainnet and sandbox
  # alike, so the coin-margined `margin/allPairs` wave never runs.
  test "binanceusdm fetch_markets uses the fapi surface alone on mainnet and sandbox" do
    for sandbox <- [false, true] do
      {paths, stub} = recording_markets_stub(%{"/fapi/v1/exchangeInfo" => %{"symbols" => []}})

      result =
        Unified.call(Exchange.new!("binanceusdm", sandbox: sandbox), :fetch_markets, "fetchMarkets", %{},
          plug: {Req.Test, stub}
        )

      assert_recorded_paths(paths, ["/fapi/v1/exchangeInfo"], "unexpected Binance USD-M fetchMarkets path")
      assert {:ok, []} = result
    end
  end

  # Bourse binancecoinm.ts pins `options.fetchMarkets.types` to `['inverse']` —
  # COIN-M is dapi-only. Without the surface filter the inherited multi-surface
  # fan-out hits spot/fapi/eapi as well and, with a null market envelope, each
  # exchangeInfo map becomes one all-nil Market (task 415).
  test "binancecoinm fetch_markets uses the dapi surface alone on mainnet and sandbox" do
    for sandbox <- [false, true] do
      {paths, stub} = recording_markets_stub(%{"/dapi/v1/exchangeInfo" => %{"symbols" => []}})

      result =
        Unified.call(Exchange.new!("binancecoinm", sandbox: sandbox), :fetch_markets, "fetchMarkets", %{},
          plug: {Req.Test, stub}
        )

      assert_recorded_paths(paths, ["/dapi/v1/exchangeInfo"], "unexpected Binance COIN-M fetchMarkets path")
      assert {:ok, []} = result
    end
  end

  # Offline pin for task 415: recorded dapi exchangeInfo (GET /dapi/v1/exchangeInfo)
  # must unwrap the symbols[] list and yield identity-bearing Market rows. Live
  # authority: Binance COIN-M Exchange Information docs + observed 2026-07-19
  # mainnet traffic (30 instruments under symbols[]).
  @coinm_markets_fixture "test/fixtures/responses/binancecoinm/fetch_markets.json"
  @external_resource @coinm_markets_fixture

  test "binancecoinm fetch_markets parses recorded dapi exchangeInfo symbols" do
    body = @coinm_markets_fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("body")
    wire_symbols = body["symbols"]
    assert is_list(wire_symbols) and wire_symbols != []

    assert {:ok, markets} =
             ReadParse.parse(
               Exchange.new!("binancecoinm"),
               Bourse.Binancecoinm,
               :fetch_markets,
               "fetchMarkets",
               body,
               %{},
               :parse_market,
               true
             )

    assert length(markets) == length(wire_symbols)

    for {market, raw} <- Enum.zip(markets, wire_symbols) do
      assert %Bourse.Market{} = market
      assert is_binary(market.id) and market.id != ""
      assert market.id == raw["symbol"]
      assert is_binary(market.symbol) and market.symbol != ""
      assert is_binary(market.type) and market.type != ""
      assert market.base == raw["baseAsset"]
      assert market.quote == raw["quoteAsset"]
      assert market.settle == raw["marginAsset"]
      assert String.contains?(market.symbol, "/")
      assert String.contains?(market.symbol, ":#{raw["marginAsset"]}")

      case raw["contractType"] do
        "PERPETUAL" -> assert market.type == "swap"
        _ -> assert market.type == "future"
      end
    end

    # Identity samples from the recorded payload (not inferred from code).
    by_id = Map.new(markets, &{&1.id, &1})
    assert %Bourse.Market{symbol: "BTC/USD:BTC", type: "swap"} = by_id["BTCUSD_PERP"]
    assert %Bourse.Market{symbol: "ETH/USD:ETH", type: "swap"} = by_id["ETHUSD_PERP"]
    assert %Bourse.Market{symbol: "BTC/USD:BTC-260925", type: "future"} = by_id["BTCUSD_260925"]

    exchange = "binancecoinm" |> Exchange.new!() |> Exchange.put_markets(markets)
    assert Symbol.to_exchange_id("BTC/USD:BTC", exchange) == "BTCUSD_PERP"
    assert Symbol.to_exchange_id("BTC/USD:BTC-260925", exchange) == "BTCUSD_260925"
  end

  test "Binance order lifecycle endpoints follow spot and USD-M surfaces" do
    assert_private_path(
      "binance",
      :create_order,
      %{"symbol" => "BTC/USDT", "type" => "limit", "side" => "buy", "amount" => 0.001},
      :post,
      "/api/v3/order"
    )

    assert_private_path(
      "binance",
      :fetch_order,
      %{"id" => "12345", "symbol" => "BTC/USDT"},
      :get,
      "/api/v3/order",
      fn params ->
        assert params["orderId"] == "12345"
        refute Map.has_key?(params, "id")
      end
    )

    assert_private_path(
      "binance",
      :fetch_orders,
      %{"symbol" => "BTC/USDT"},
      :get,
      "/api/v3/allOrders"
    )

    assert_private_path(
      "binance",
      :cancel_order,
      %{"id" => "12345", "symbol" => "BTC/USDT"},
      :delete,
      "/api/v3/order",
      fn params ->
        assert params["orderId"] == "12345"
        refute Map.has_key?(params, "id")
      end
    )

    assert_private_path(
      "binanceusdm",
      :create_order,
      %{"symbol" => "BTC/USDT:USDT", "type" => "limit", "side" => "buy", "amount" => 0.001},
      :post,
      "/fapi/v1/order"
    )

    assert_private_path(
      "binanceusdm",
      :fetch_order,
      %{"id" => "12345", "symbol" => "BTC/USDT:USDT"},
      :get,
      "/fapi/v1/order",
      fn params ->
        assert params["orderId"] == "12345"
        refute Map.has_key?(params, "id")
      end
    )

    assert_private_path(
      "binanceusdm",
      :cancel_order,
      %{"id" => "12345", "symbol" => "BTC/USDT:USDT"},
      :delete,
      "/fapi/v1/order",
      fn params ->
        assert params["orderId"] == "12345"
        refute Map.has_key?(params, "id")
      end
    )
  end

  test "fetch_tickers selects Binance's authored market surface from plural symbols" do
    for {symbols, expected_path} <- [
          {["BTC/USDT"], "/api/v3/ticker/24hr"},
          {["BTC/USDT:USDT"], "/fapi/v1/ticker/24hr"},
          {["BTC/USD:BTC"], "/dapi/v1/ticker/24hr"},
          {["BTC/USDT:USDT-260630-100000-C"], "/eapi/v1/ticker"}
        ] do
      {requests, stub} = ticker_stub()

      assert {:ok, _tickers} =
               Unified.call(Exchange.new!("binance"), :fetch_tickers, "fetchTickers", %{"symbols" => symbols},
                 plug: {Req.Test, stub}
               )

      assert_ticker_request(requests, expected_path)
    end
  end

  test "symbol-less fetch_tickers uses Binance's authored spot default" do
    {requests, stub} = ticker_stub()

    assert {:ok, _tickers} =
             Unified.call(Exchange.new!("binance"), :fetch_tickers, "fetchTickers", %{}, plug: {Req.Test, stub})

    assert_ticker_request(requests, "/api/v3/ticker/24hr")
  end

  test "spot fetch_tickers keys compact ids from loaded market identity" do
    rows =
      @non_usdt_tickers_fixture
      |> File.read!()
      |> Jason.decode!()

    # Shaped like a live binance `fetch_markets/1` row: `:symbol` still carries the
    # RAW compact id (verified live 2026-07-19), so the split MUST come from the
    # exchange-reported `baseAsset`/`quoteAsset` pair. Keep `:symbol` raw here or the
    # test silently pins the fallback branch instead of the real one.
    markets = [
      %Bourse.Market{id: "AAVEBNB", symbol: "AAVEBNB", base: "AAVE", quote: "BNB"},
      %Bourse.Market{id: "AAVETRY", symbol: "AAVETRY", base: "AAVE", quote: "TRY"},
      %Bourse.Market{id: "AAVEBRL", symbol: "AAVEBRL", base: "AAVE", quote: "BRL"},
      %Bourse.Market{id: "AAVEBKRW", symbol: "AAVEBKRW", base: "AAVE", quote: "BKRW"},
      %Bourse.Market{id: "LINKUSD1", symbol: "LINKUSD1", base: "LINK", quote: "USD1"}
    ]

    exchange = "binance" |> Exchange.new!() |> Exchange.put_markets(markets)
    {requests, stub} = ticker_rows_stub(rows)

    assert {:ok, tickers} =
             Unified.call(exchange, :fetch_tickers, "fetchTickers", %{}, plug: {Req.Test, stub})

    assert_ticker_rows_request(requests, "/api/v3/ticker/24hr", nil)

    assert tickers |> Map.keys() |> Enum.sort() == ["AAVE/BKRW", "AAVE/BNB", "AAVE/BRL", "AAVE/TRY", "LINK/USD1"]
    assert Enum.all?(tickers, fn {symbol, ticker} -> ticker.symbol == symbol end)
  end

  test "spot fetch_tickers loads only spot identity when markets are unloaded" do
    rows = @non_usdt_tickers_fixture |> File.read!() |> Jason.decode!()

    market_rows =
      for {id, base, quote} <- [
            {"AAVEBNB", "AAVE", "BNB"},
            {"AAVETRY", "AAVE", "TRY"},
            {"AAVEBRL", "AAVE", "BRL"},
            {"AAVEBKRW", "AAVE", "BKRW"},
            {"LINKUSD1", "LINK", "USD1"}
          ] do
        %{"symbol" => id, "baseAsset" => base, "quoteAsset" => quote}
      end

    {paths, stub} = ticker_and_spot_markets_stub(rows, market_rows)

    result = Unified.call(Exchange.new!("binance"), :fetch_tickers, "fetchTickers", %{}, plug: {Req.Test, stub})

    assert_recorded_paths(
      paths,
      ["/api/v3/exchangeInfo", "/api/v3/ticker/24hr"],
      "unexpected Binance unloaded-markets path"
    )

    assert {:ok, tickers} = result
    assert tickers |> Map.keys() |> Enum.sort() == ["AAVE/BKRW", "AAVE/BNB", "AAVE/BRL", "AAVE/TRY", "LINK/USD1"]
  end

  test "spot fetch_tickers rows with no listed market keep their raw id" do
    rows = @non_usdt_tickers_fixture |> File.read!() |> Jason.decode!()

    # Live binance returns a handful of rows (NBTBIDR, AXSBIDR on 2026-07-19) that are
    # absent from /api/v3/exchangeInfo entirely. With no instrument identity to split
    # on, the raw id is the honest key — never a guessed quote boundary.
    markets = [%Bourse.Market{id: "AAVEBNB", symbol: "AAVEBNB", base: "AAVE", quote: "BNB"}]

    exchange = "binance" |> Exchange.new!() |> Exchange.put_markets(markets)
    {requests, stub} = ticker_rows_stub(rows)

    assert {:ok, tickers} =
             Unified.call(exchange, :fetch_tickers, "fetchTickers", %{}, plug: {Req.Test, stub})

    assert_ticker_rows_request(requests, "/api/v3/ticker/24hr", nil)

    assert tickers |> Map.keys() |> Enum.sort() ==
             ["AAVE/BNB", "AAVEBKRW", "AAVEBRL", "AAVETRY", "LINKUSD1"]
  end

  test "symbol-less binanceusdm fetch_tickers routes by family, defaulting to linear fapi (task 368)" do
    for {params, expected_path} <- [
          {%{}, "/fapi/v1/ticker/24hr"},
          {%{"type" => "linear"}, "/fapi/v1/ticker/24hr"},
          {%{"type" => "inverse"}, "/dapi/v1/ticker/24hr"},
          {%{"subType" => "inverse"}, "/dapi/v1/ticker/24hr"},
          # Families the binanceusdm default must not swallow: these keep
          # falling through to the generic market-type inference.
          {%{"type" => "future"}, "/dapi/v1/ticker/24hr"},
          {%{"type" => "spot"}, "/api/v3/ticker"}
        ] do
      {requests, stub} = ticker_stub()

      assert {:ok, _tickers} =
               Unified.call(Exchange.new!("binanceusdm"), :fetch_tickers, "fetchTickers", params, plug: {Req.Test, stub})

      assert_ticker_request(requests, expected_path)
    end
  end

  # Task 373 — same default-family seam as task 368, for the other multi-endpoint
  # binanceusdm reads that still fell through to `hd(configs)` (COIN-M dapi).
  test "symbol-less binanceusdm no-arg reads default to linear fapi (task 373)" do
    for {method, js_name, params, expected_path, body} <- [
          {:fetch_positions, "fetchPositions", %{}, "/fapi/v3/positionRisk", []},
          {:fetch_positions, "fetchPositions", %{"type" => "linear"}, "/fapi/v3/positionRisk", []},
          {:fetch_positions, "fetchPositions", %{"type" => "inverse"}, "/dapi/v1/positionRisk", []},
          {:fetch_positions, "fetchPositions", %{"subType" => "inverse"}, "/dapi/v1/positionRisk", []},
          # Inverse symbol grammar (task 366) must still select COIN-M dapi.
          {:fetch_positions, "fetchPositions", %{"symbol" => "BTC/USD:BTC"}, "/dapi/v1/positionRisk", []},
          # type=future is the COIN-M delivery surface — authored inverse/future rule
          # (task 378) pins positionRisk, not the old bare-hd account sibling.
          {:fetch_positions, "fetchPositions", %{"type" => "future"}, "/dapi/v1/positionRisk", []},
          {:fetch_open_orders, "fetchOpenOrders", %{}, "/fapi/v1/openOrders", []},
          {:fetch_open_orders, "fetchOpenOrders", %{"type" => "linear"}, "/fapi/v1/openOrders", []},
          {:fetch_open_orders, "fetchOpenOrders", %{"type" => "inverse"}, "/dapi/v1/openOrders", []},
          {:fetch_open_orders, "fetchOpenOrders", %{"subType" => "inverse"}, "/dapi/v1/openOrders", []},
          {:fetch_open_orders, "fetchOpenOrders", %{"type" => "future"}, "/dapi/v1/openOrders", []},
          # type=spot routes to the spot private openOrders surface via authored
          # endpoint_selection (task 378) — no longer bare-hd to COIN-M dapi.
          {:fetch_open_orders, "fetchOpenOrders", %{"type" => "spot"}, "/api/v3/openOrders", []},
          {:fetch_funding_rates, "fetchFundingRates", %{}, "/fapi/v1/premiumIndex", []},
          {:fetch_funding_rates, "fetchFundingRates", %{"type" => "linear"}, "/fapi/v1/premiumIndex", []},
          {:fetch_funding_rates, "fetchFundingRates", %{"type" => "inverse"}, "/dapi/v1/premiumIndex", []},
          {:fetch_funding_rates, "fetchFundingRates", %{"subType" => "inverse"}, "/dapi/v1/premiumIndex", []},
          {:fetch_funding_rates, "fetchFundingRates", %{"type" => "future"}, "/dapi/v1/premiumIndex", []},
          {:fetch_time, "fetchTime", %{}, "/fapi/v1/time", %{"serverTime" => 1_700_000_000_000}},
          {:fetch_time, "fetchTime", %{"type" => "linear"}, "/fapi/v1/time", %{"serverTime" => 1_700_000_000_000}},
          {:fetch_time, "fetchTime", %{"type" => "inverse"}, "/dapi/v1/time", %{"serverTime" => 1_700_000_000_000}},
          {:fetch_time, "fetchTime", %{"type" => "future"}, "/dapi/v1/time", %{"serverTime" => 1_700_000_000_000}},
          {:fetch_time, "fetchTime", %{"type" => "spot"}, "/api/v3/time", %{"serverTime" => 1_700_000_000_000}}
        ] do
      {requests, stub} = path_body_stub(body)
      exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

      assert {:ok, _} =
               Unified.call(exchange, method, js_name, params,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: 1_700_000_000_000
               )

      expected_paths =
        case {method, expected_path} do
          {:fetch_funding_rates, path} -> [path, String.replace(path, "premiumIndex", "fundingInfo")]
          {:fetch_open_orders, "/fapi/v1/openOrders"} -> ["/fapi/v1/openOrders", "/fapi/v1/openAlgoOrders"]
          _other -> [expected_path]
        end

      assert requests |> RequestCollector.requests() |> Enum.map(& &1.conn.request_path) == expected_paths
    end
  end

  test "fetch_tickers filters Binance ticker maps by requested symbols" do
    for {exchange_id, symbol, path, expected_query, params, rows} <- [
          {"binance", "BTC/USDT", "/api/v3/ticker/24hr", ~s(["BTCUSDT"]), %{},
           [
             %{"symbol" => "BTCUSDT", "lastPrice" => "65000"},
             %{"symbol" => "ETHUSDT", "lastPrice" => "3000"}
           ]},
          {"binanceusdm", "BTC/USDT:USDT", "/fapi/v1/ticker/24hr", nil, %{},
           [
             %{"symbol" => "BTCUSDT", "lastPrice" => "65000"},
             %{"symbol" => "ETHUSDT", "lastPrice" => "3000"}
           ]},
          {"binanceusdm", "BTC/USD:BTC", "/dapi/v1/ticker/24hr", nil, %{"type" => "inverse"},
           [
             %{"symbol" => "BTCUSD_PERP", "lastPrice" => "65000"},
             %{"symbol" => "ETHUSD_PERP", "lastPrice" => "3000"}
           ]},
          {"binanceusdm", "BTC/USD:BTC-260925", "/dapi/v1/ticker/24hr", nil, %{"type" => "inverse"},
           [%{"symbol" => "BTCUSD_260925", "lastPrice" => "65000"}]},
          {"binanceusdm", "ETH/USDT:USDT-251226", "/fapi/v1/ticker/24hr", nil, %{},
           [%{"symbol" => "ETHUSDT_251226", "lastPrice" => "3000"}]}
        ] do
      {requests, stub} = ticker_rows_stub(rows)

      assert {:ok, %{^symbol => %{last: last}} = tickers} =
               Unified.call(
                 Exchange.new!(exchange_id),
                 :fetch_tickers,
                 "fetchTickers",
                 Map.put(params, "symbols", [symbol]),
                 plug: {Req.Test, stub}
               )

      assert_ticker_rows_request(requests, path, expected_query)

      assert is_number(last)
      assert map_size(tickers) == 1
    end
  end

  @tag :network
  test "live Binance ticker reads retain only requested symbols" do
    for {exchange_id, symbol, opts} <- [
          {"binance", "BTC/USDT", []},
          {"binanceusdm", "BTC/USDT:USDT", []},
          {"binanceusdm", "BTC/USD:BTC", [type: "inverse"]}
        ] do
      exchange = Exchange.new!(exchange_id, sandbox: true)

      assert {:ok, %{^symbol => _ticker} = tickers} =
               Bourse.fetch_tickers(exchange, Keyword.put(opts, :symbols, [symbol]))

      assert map_size(tickers) == 1
    end
  end

  test "Binance create_order uppercases side and type on the wire" do
    {requests, stub} = order_stub()

    assert {:ok, _} =
             Unified.call(
               Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true),
               :create_order,
               "createOrder",
               %{"symbol" => "BTC/USDT:USDT", "type" => "limit", "side" => "buy", "amount" => 0.001, "price" => 10_000},
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_order_request(requests, :post, "/fapi/v1/order", fn params ->
      assert params["symbol"] == "BTCUSDT"
      assert params["side"] == "BUY"
      assert params["type"] == "LIMIT"
      assert params["quantity"] == "0.001"
      refute Map.has_key?(params, "amount")
    end)
  end

  test "Binance batch orders JSON-encode transformed orders as a query parameter" do
    {requests, stub} = order_stub()

    orders = [%{"symbol" => "LTC/USDT:USDT", "type" => "limit", "side" => "buy", "amount" => 0.1, "price" => 60}]
    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, _} =
             Unified.call(exchange, :create_orders, "createOrders", %{"orders" => orders},
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_order_request(requests, :post, "/fapi/v1/batchOrders", fn params ->
      assert [order] = Jason.decode!(params["batchOrders"])
      assert order["symbol"] == "LTCUSDT"
      assert order["side"] == "BUY"
      assert order["type"] == "LIMIT"
      assert order["quantity"] == "0.1"
      assert String.starts_with?(order["newClientOrderId"], "x-xcKtGhcu")

      refute Map.has_key?(params, "orders")
    end)
  end

  # The pinned CCXT static request fixture supplies the LIMIT compatibility vector, but the
  # signing fixture gate carries no binance `createOrders` case — so the byte-for-byte
  # claim had no test. Pin it here: field order and number formatting are both load-bearing.
  @batch_orders_fixture "priv/reference_cache/request/binance.json"
  @external_resource @batch_orders_fixture

  test "Binance batch LIMIT orders reproduce the CCXT compatibility fixture byte-for-byte" do
    expected =
      @batch_orders_fixture
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["methods", "createOrders"])
      |> hd()
      |> Map.fetch!("output")

    assert [_, expected_batch] = Regex.run(~r/batchOrders=(\[.*?\])&recvWindow/, expected)

    orders = [
      %{
        "symbol" => "LTC/USDT:USDT",
        "type" => "limit",
        "side" => "buy",
        "amount" => 0.1,
        "price" => 60,
        "clientOrderId" => "x-xcKtGhcub371e14dda9e4fda804421"
      },
      %{
        "symbol" => "LTC/USDT:USDT",
        "type" => "limit",
        "side" => "buy",
        "amount" => 0.11,
        "price" => 61,
        "clientOrderId" => "x-xcKtGhcu2b5cffec484a42138cdf8e"
      }
    ]

    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)
    built = RequestShape.Binance.build(%{"orders" => orders}, "createOrders", exchange)

    assert built["batchOrders"] == expected_batch
  end

  test "Binance batch orders use the fields required by each order type" do
    {requests, stub} = order_stub()

    orders = [
      %{"symbol" => "LTC/USDT:USDT", "type" => "market", "side" => "buy", "amount" => 0.1},
      %{
        "symbol" => "LTC/USDT:USDT",
        "type" => "stop",
        "side" => "buy",
        "amount" => 0.1,
        "price" => 60,
        "stopPrice" => 59
      },
      %{"symbol" => "LTC/USDT:USDT", "type" => "stop_market", "side" => "buy", "amount" => 0.1, "stopPrice" => 59},
      %{
        "symbol" => "LTC/USDT:USDT",
        "type" => "trailing_stop_market",
        "side" => "buy",
        "amount" => 0.1,
        "callbackRate" => 0.5
      },
      %{"symbol" => "LTC/USDT:USDT", "type" => "take_profit_market", "side" => "buy", "stopPrice" => 59}
    ]

    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, _} =
             Unified.call(exchange, :create_orders, "createOrders", %{"orders" => orders},
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_order_request(requests, :post, "/fapi/v1/batchOrders", fn params ->
      assert [market, stop, stop_market, trailing, close_position] = Jason.decode!(params["batchOrders"])

      assert %{"symbol" => "LTCUSDT", "side" => "BUY", "type" => "MARKET", "quantity" => "0.1"} = market
      refute Map.has_key?(market, "price")
      refute Map.has_key?(market, "timeInForce")

      assert %{
               "type" => "STOP",
               "quantity" => "0.1",
               "price" => "60",
               "stopPrice" => "59"
             } = stop

      assert %{"type" => "STOP_MARKET", "quantity" => "0.1", "stopPrice" => "59"} = stop_market
      refute Map.has_key?(stop_market, "price")

      assert %{"type" => "TRAILING_STOP_MARKET", "quantity" => "0.1", "callbackRate" => "0.5"} = trailing
      refute Map.has_key?(trailing, "price")

      # Binance rejects `quantity` alongside `closePosition: true`, so an
      # amount-less element must omit it rather than send an empty value.
      assert %{"type" => "TAKE_PROFIT_MARKET", "stopPrice" => "59"} = close_position
      refute Map.has_key?(close_position, "quantity")
    end)
  end

  test "Binance batch orders forward their documented type-scoped optional fields" do
    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

    orders = [
      %{
        "symbol" => "LTC/USDT:USDT",
        "type" => "limit",
        "side" => "buy",
        "amount" => 0.1,
        "timeInForce" => "gtd",
        "reduceOnly" => true,
        "positionSide" => "LONG",
        "priceMatch" => "OPPONENT",
        "selfTradePreventionMode" => "EXPIRE_BOTH",
        "goodTillDate" => 1_800_000_000_000
      },
      %{
        "symbol" => "LTC/USDT:USDT",
        "type" => "stop_market",
        "side" => "sell",
        "closePosition" => true,
        "positionSide" => "SHORT",
        "workingType" => "MARK_PRICE",
        "priceProtect" => true,
        "selfTradePreventionMode" => "EXPIRE_TAKER",
        "stopPrice" => 59
      },
      %{
        "symbol" => "LTC/USDT:USDT",
        "type" => "trailing_stop_market",
        "side" => "sell",
        "amount" => 0.1,
        "callbackRate" => 0.5,
        "activationPrice" => 61,
        "workingType" => "CONTRACT_PRICE"
      }
    ]

    assert %{"batchOrders" => batch_orders} = RequestShape.Binance.build(%{"orders" => orders}, "createOrders", exchange)

    assert [limit, close_position, trailing] = Jason.decode!(batch_orders)

    assert %{
             "type" => "LIMIT",
             "timeInForce" => "GTD",
             "reduceOnly" => "true",
             "positionSide" => "LONG",
             "priceMatch" => "OPPONENT",
             "selfTradePreventionMode" => "EXPIRE_BOTH",
             "goodTillDate" => 1_800_000_000_000
           } = limit

    refute Map.has_key?(limit, "price")

    assert %{
             "type" => "STOP_MARKET",
             "closePosition" => "true",
             "positionSide" => "SHORT",
             "workingType" => "MARK_PRICE",
             "priceProtect" => "true",
             "selfTradePreventionMode" => "EXPIRE_TAKER"
           } = close_position

    refute Map.has_key?(close_position, "quantity")

    assert %{
             "type" => "TRAILING_STOP_MARKET",
             "activationPrice" => 61,
             "workingType" => "CONTRACT_PRICE"
           } = trailing
  end

  # The builder keeps the allowlist it VALIDATES against separate from the
  # per-type list it EMITS from. A field added to the first but not the second
  # validates clean and then vanishes — the exact silent drop this carve exists
  # to kill. Assert every allowlisted optional reaches the wire for its type.
  test "every allowlisted optional element field reaches the wire for its order type" do
    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

    base = %{
      "LIMIT" => %{"type" => "limit", "amount" => 0.1, "price" => 60},
      "MARKET" => %{"type" => "market", "amount" => 0.1},
      "STOP" => %{"type" => "stop", "amount" => 0.1, "price" => 60, "stopPrice" => 59},
      "TAKE_PROFIT" => %{"type" => "take_profit", "amount" => 0.1, "price" => 60, "stopPrice" => 59},
      "STOP_MARKET" => %{"type" => "stop_market", "amount" => 0.1, "stopPrice" => 59},
      "TAKE_PROFIT_MARKET" => %{"type" => "take_profit_market", "amount" => 0.1, "stopPrice" => 59},
      "TRAILING_STOP_MARKET" => %{"type" => "trailing_stop_market", "amount" => 0.1, "callbackRate" => 0.5}
    }

    optionals = %{
      "LIMIT" => ~w(reduceOnly positionSide priceMatch selfTradePreventionMode goodTillDate),
      "MARKET" => ~w(reduceOnly positionSide selfTradePreventionMode),
      "STOP" => ~w(reduceOnly positionSide workingType priceProtect priceMatch selfTradePreventionMode goodTillDate),
      "TAKE_PROFIT" =>
        ~w(reduceOnly positionSide workingType priceProtect priceMatch selfTradePreventionMode goodTillDate),
      "STOP_MARKET" => ~w(reduceOnly closePosition positionSide workingType priceProtect selfTradePreventionMode),
      "TAKE_PROFIT_MARKET" => ~w(reduceOnly closePosition positionSide workingType priceProtect selfTradePreventionMode),
      "TRAILING_STOP_MARKET" => ~w(reduceOnly positionSide workingType activationPrice selfTradePreventionMode)
    }

    for {type, fields} <- optionals, field <- fields do
      order =
        base
        |> Map.fetch!(type)
        |> Map.put("symbol", "LTC/USDT:USDT")
        |> Map.put("side", "buy")
        |> put_optional_probe(field)

      assert %{"batchOrders" => batch} =
               RequestShape.Binance.build(%{"orders" => [order]}, "createOrders", exchange)

      assert [encoded] = Jason.decode!(batch)

      assert Map.has_key?(encoded, field),
             "#{type} silently dropped allowlisted field #{field}: #{inspect(encoded)}"
    end
  end

  # `priceMatch` replaces `price`, `goodTillDate` requires GTD, and the
  # close-all element rejects a caller-supplied size — so each probe carries
  # the companion its field needs to be a legal element.
  defp put_optional_probe(order, "priceMatch"), do: order |> Map.delete("price") |> Map.put("priceMatch", "OPPONENT")

  defp put_optional_probe(order, "goodTillDate") do
    order |> Map.put("timeInForce", "GTD") |> Map.put("goodTillDate", 1_800_000_000_000)
  end

  defp put_optional_probe(order, "closePosition"), do: order |> Map.delete("amount") |> Map.put("closePosition", true)
  defp put_optional_probe(order, "reduceOnly"), do: Map.put(order, "reduceOnly", true)
  defp put_optional_probe(order, "priceProtect"), do: Map.put(order, "priceProtect", true)
  defp put_optional_probe(order, "positionSide"), do: Map.put(order, "positionSide", "LONG")
  defp put_optional_probe(order, "workingType"), do: Map.put(order, "workingType", "MARK_PRICE")
  defp put_optional_probe(order, "activationPrice"), do: Map.put(order, "activationPrice", 61)

  defp put_optional_probe(order, "selfTradePreventionMode"), do: Map.put(order, "selfTradePreventionMode", "EXPIRE_TAKER")

  test "Binance batch orders reject conflicting and incomplete priced elements" do
    exchange = Exchange.new!("binanceusdm")

    build = fn order -> RequestShape.Binance.build(%{"orders" => [order]}, "createOrders", exchange) end
    limit = %{"symbol" => "LTC/USDT:USDT", "type" => "limit", "side" => "buy", "amount" => 0.1}

    # Neither `price` nor `priceMatch`: the venue would answer -1102; name the
    # missing key client-side instead of shipping an unpriced LIMIT.
    assert_raise ArgumentError, ~r/requires "price" or "priceMatch"/, fn -> build.(limit) end

    assert_raise ArgumentError, ~r/"priceMatch" cannot be used with "price"/, fn ->
      build.(Map.merge(limit, %{"price" => 60, "priceMatch" => "OPPONENT"}))
    end

    # `closePosition: true` sizes itself from the open position.
    assert_raise ArgumentError, ~r/"amount" cannot be used with "closePosition"/, fn ->
      build.(%{
        "symbol" => "LTC/USDT:USDT",
        "type" => "stop_market",
        "side" => "sell",
        "stopPrice" => 59,
        "amount" => 0.1,
        "closePosition" => true
      })
    end

    # `closePosition: false` is a legal explicit value and must not trip the
    # close-all exclusions.
    assert %{"batchOrders" => _} =
             build.(%{
               "symbol" => "LTC/USDT:USDT",
               "type" => "stop_market",
               "side" => "sell",
               "stopPrice" => 59,
               "amount" => 0.1,
               "closePosition" => false
             })
  end

  test "Binance batch orders fail loudly for unknown and inapplicable element fields" do
    exchange = Exchange.new!("binanceusdm")

    assert_raise ArgumentError, ~r/"mystery".*LIMIT/, fn ->
      RequestShape.Binance.build(
        %{
          "orders" => [
            %{
              "symbol" => "LTC/USDT:USDT",
              "type" => "limit",
              "side" => "buy",
              "amount" => 0.1,
              "price" => 60,
              "mystery" => true
            }
          ]
        },
        "createOrders",
        exchange
      )
    end

    assert_raise ArgumentError, ~r/"activationPrice".*LIMIT/, fn ->
      RequestShape.Binance.build(
        %{
          "orders" => [
            %{
              "symbol" => "LTC/USDT:USDT",
              "type" => "limit",
              "side" => "buy",
              "amount" => 0.1,
              "price" => 60,
              "activationPrice" => 59
            }
          ]
        },
        "createOrders",
        exchange
      )
    end
  end

  test "Binance batch edits JSON-encode transformed orders as a query parameter" do
    {requests, stub} = order_stub()

    orders = [%{"id" => "556886677", "symbol" => "LTC/USDT:USDT", "side" => "buy", "amount" => 0.1, "price" => 60}]
    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, _} =
             Unified.call(exchange, :edit_orders, "editOrders", %{"orders" => orders},
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_order_request(requests, :put, "/fapi/v1/batchOrders", fn params ->
      assert [%{"orderId" => "556886677", "symbol" => "LTCUSDT", "side" => "BUY", "quantity" => "0.1", "price" => "60"}] =
               Jason.decode!(params["batchOrders"])

      refute Map.has_key?(params, "orders")
    end)
  end

  @tag :network
  test "Binance testnet validates an invalid batch after request shaping" do
    api_key = System.get_env("BINANCE_FUTURES_TEST_API_KEY")
    secret = System.get_env("BINANCE_FUTURES_TEST_API_SECRET")

    if is_nil(api_key) or is_nil(secret) do
      flunk("""
      Missing Binance USD-M testnet credentials!

      Set these environment variables:
        export BINANCE_FUTURES_TEST_API_KEY="your_key"
        export BINANCE_FUTURES_TEST_API_SECRET="your_secret"

      Get credentials at: https://demo.binance.com/en/my/settings/api-management
      """)
    end

    exchange = Exchange.new!("binanceusdm", api_key: api_key, secret: secret, sandbox: true)
    orders = [%{"symbol" => "INVALID/USDT:USDT", "type" => "limit", "side" => "buy", "amount" => 0.1, "price" => 1}]

    assert {:ok, [%{info: %{"code" => -1121, "msg" => "Invalid symbol."}}]} =
             Unified.call(exchange, :create_orders, "createOrders", %{"orders" => orders}, [])
  end

  @tag :network
  test "Binance testnet receives reduceOnly in a LIMIT batch element" do
    api_key = System.get_env("BINANCE_FUTURES_TEST_API_KEY")
    secret = System.get_env("BINANCE_FUTURES_TEST_API_SECRET")

    if is_nil(api_key) or is_nil(secret) do
      flunk("""
      Missing Binance USD-M testnet credentials!

      Set these environment variables:
        export BINANCE_FUTURES_TEST_API_KEY="your_key"
        export BINANCE_FUTURES_TEST_API_SECRET="your_secret"

      Get credentials at: https://demo.binance.com/en/my/settings/api-management
      """)
    end

    exchange = Exchange.new!("binanceusdm", api_key: api_key, secret: secret, sandbox: true)

    assert {:ok, %{last: last}} =
             Unified.call(exchange, :fetch_ticker, "fetchTicker", %{"symbol" => "LTC/USDT:USDT"}, [])

    # LTCUSDT's tick size is 0.01; an unrounded `last * 0.9` is rejected with
    # -1111 "Precision is over the maximum" BEFORE the venue evaluates
    # reduceOnly, which would make this probe a generic rejection rather than
    # evidence the field was honored.
    price = Float.round(last * 0.9, 2)

    # The USD-M demo account is in Hedge Mode (`dualSidePosition: true`, live
    # 2026-07-29). Without `positionSide` the venue answers -4061; with
    # `positionSide` + `reduceOnly` it answers -1106 "Parameter 'reduceonly'
    # sent when not required" — both prove the batch element reached the
    # venue with reduceOnly. One-way mode used to answer -2022 for a reduce-
    # only with no position; pin the hedge-mode evidence instead.
    assert {:ok, [%{info: %{"code" => code, "msg" => msg}}]} =
             Unified.call(
               exchange,
               :create_orders,
               "createOrders",
               %{
                 "orders" => [
                   %{
                     "symbol" => "LTC/USDT:USDT",
                     "type" => "limit",
                     "side" => "sell",
                     "amount" => 0.2,
                     "price" => price,
                     "reduceOnly" => true,
                     "positionSide" => "LONG"
                   }
                 ]
               },
               []
             )

    assert code == -1106
    assert msg == "Parameter 'reduceonly' sent when not required."
  end

  @tag :network
  test "Binance testnet validates each non-limit batch order shape" do
    api_key = System.get_env("BINANCE_FUTURES_TEST_API_KEY")
    secret = System.get_env("BINANCE_FUTURES_TEST_API_SECRET")

    if is_nil(api_key) or is_nil(secret) do
      flunk("""
      Missing Binance USD-M testnet credentials!

      Set these environment variables:
        export BINANCE_FUTURES_TEST_API_KEY="your_key"
        export BINANCE_FUTURES_TEST_API_SECRET="your_secret"

      Get credentials at: https://demo.binance.com/en/my/settings/api-management
      """)
    end

    exchange = Exchange.new!("binanceusdm", api_key: api_key, secret: secret, sandbox: true)

    # A VALID symbol is load-bearing: Binance validates the symbol before the order
    # type, so an invalid-symbol probe short-circuits at -1121 and goes green for any
    # element shape — including one that omits a mandatory field. Every element below
    # is sub-minimum notional or far from market, so none can execute or rest.
    submit = fn order ->
      assert {:ok, [%{info: info}]} =
               Unified.call(exchange, :create_orders, "createOrders", %{"orders" => [order]}, [])

      info
    end

    # MARKET carries quantity only; it reaches the notional check, proving the venue
    # accepted the element rather than rejecting its shape.
    assert %{"code" => -4164} =
             submit.(%{"symbol" => "LTC/USDT:USDT", "type" => "market", "side" => "buy", "amount" => 0.001})

    # The conditional family is refused wholesale by this endpoint (see C-T332 and the
    # prod-verification ledger). Pinning -4120 makes a venue change loud: if Binance
    # starts accepting these, this goes red and the ledger entry can be closed.
    for order <- [
          %{"type" => "stop", "amount" => 0.001, "price" => 5000, "stopPrice" => 5000},
          %{"type" => "take_profit", "amount" => 0.001, "price" => 10, "stopPrice" => 10},
          %{"type" => "stop_market", "amount" => 0.001, "stopPrice" => 5000},
          %{"type" => "take_profit_market", "amount" => 0.001, "stopPrice" => 10},
          %{"type" => "trailing_stop_market", "amount" => 0.001, "callbackRate" => 1.0}
        ] do
      info = submit.(Map.merge(%{"symbol" => "LTC/USDT:USDT", "side" => "buy"}, order))

      assert %{"code" => -4120} = info,
             """
             Expected -4120 (order type unsupported on batchOrders) for #{order["type"]}, got:
               #{inspect(info)}

             If Binance now accepts this type, close the binanceusdm batchOrders entry in
             docs/prod-verification-ledger.md and promote C-T332's conditional family to tier 1.
             """
    end
  end

  test "authored Binance option examples classify and round-trip through the real spec" do
    exchange = Exchange.new!("binance")

    assert exchange.symbol_patterns.option.pattern == :option_base_yymmdd

    symbol = "BTC/USDT:USDT-260925-145000-C"
    native = Symbol.to_exchange_id(symbol, exchange)

    assert native == "BTC-260925-145000-C"
    assert Symbol.from_exchange_id(native, exchange, :option) == symbol
  end

  test "spot account rows parse free, locked, and exact totals" do
    body = %{
      "updateTime" => 1_701_856_395_927,
      "balances" => [%{"asset" => "BTC", "free" => "0.91974100", "locked" => "0.00025900"}]
    }

    {requests, stub} = account_stub(body)
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, %Balance{} = balance} =
             Unified.call(exchange, :fetch_balance, "fetchBalance", %{}, plug: {Req.Test, stub})

    assert_account_request(requests, "/api/v3/account")

    assert balance.free == %{"BTC" => 0.919741}
    assert balance.used == %{"BTC" => 0.000259}
    assert balance.total == %{"BTC" => 0.92}
  end

  test "USD-M assets map provider-defined wallet axes in multi-assets mode" do
    body = %{
      "assets" => [
        %{
          "asset" => "BNB",
          "availableBalance" => "18.19275360",
          "initialMargin" => "0.00000000",
          "maxWithdrawAmount" => "0.00000000",
          "walletBalance" => "0.00000000"
        },
        %{
          "asset" => "USDT",
          "availableBalance" => "45.00000000",
          "initialMargin" => "3.97738800",
          "maxWithdrawAmount" => "31.02261200",
          "walletBalance" => "35.00000000"
        }
      ],
      "positions" => []
    }

    {requests, stub} = account_stub(body)
    exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

    assert {:ok, %Balance{} = balance} =
             Unified.call(exchange, :fetch_balance, "fetchBalance", %{}, plug: {Req.Test, stub})

    assert_account_request(requests, "/fapi/v3/account")

    assert balance.free == %{"BNB" => 0.0, "USDT" => 31.022612}
    assert balance.used == %{"BNB" => 0.0, "USDT" => 3.977388}
    assert balance.total == %{"BNB" => 0.0, "USDT" => 35.0}
    assert Enum.all?(balance.used, fn {_asset, used} -> used >= 0 end)
  end

  test "Binance-family plural trading-fee contracts expose their documented boundaries" do
    spot = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)

    assert {:error,
            %Bourse.Error{
              type: :not_supported,
              message: "No base URL for section sapi on binance (sandbox)"
            }} = Unified.call(spot, :fetch_trading_fees, "fetchTradingFees", %{}, [])

    usdm = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

    refute Exchange.has?(usdm, "fetchTradingFees")
    assert Bourse.Binanceusdm.__unified_endpoint__(:fetch_trading_fees) == []

    assert {:error,
            %Bourse.Error{
              type: :not_supported,
              message: "binanceusdm does not support fetchTradingFees"
            }} = Unified.call(usdm, :fetch_trading_fees, "fetchTradingFees", %{}, [])
  end

  test "OHLCV endpoint selection distinguishes market families and price variants" do
    cases = [
      {"binance", "BTC/USDT", nil, "/api/v3/klines"},
      {"binanceusdm", "BTC/USDT:USDT", nil, "/fapi/v1/klines"},
      {"binanceusdm", "BTC/USD:BTC", nil, "/dapi/v1/klines"},
      {"binanceusdm", "BTC/USDT:USDT", "mark", "/fapi/v1/markPriceKlines"},
      {"binanceusdm", "BTC/USD:BTC", "index", "/dapi/v1/indexPriceKlines"}
    ]

    for {exchange_id, symbol, price_variant, expected_path} <- cases do
      {requests, stub} = ohlcv_stub()
      params = %{"symbol" => symbol, "timeframe" => "1m", "price" => price_variant}

      assert {:ok, [[1_700_000_000_000, 1.0, 2.0, 0.5, 1.5, 10.0]]} =
               Unified.call(Exchange.new!(exchange_id), :fetch_ohlcv, "fetchOHLCV", params, plug: {Req.Test, stub})

      assert_ohlcv_request(requests, expected_path)
    end

    {requests, stub} = ohlcv_stub()

    assert {:ok, [[1_700_000_000_000, 1.0, 2.0, 0.5, 1.5, 10.0]]} =
             Unified.call(
               Exchange.new!("binanceusdm"),
               :fetch_ohlcv,
               "fetchOHLCV",
               %{"symbol" => "BTC/USD:BTC", "timeframe" => "1m", "subType" => "inverse"},
               plug: {Req.Test, stub}
             )

    assert_ohlcv_request(requests, "/dapi/v1/klines")
  end

  test "authored market field maps set type and active from venue keys" do
    for exchange_id <- ["binance", "binanceusdm"] do
      map = Exchange.new!(exchange_id).module.__field_maps__()["market"]["field_map"]

      assert {:ok, %Bourse.Market{type: "swap", active: true}} =
               Bourse.ResponseParser.apply_mappings(
                 %{"contractType" => "PERPETUAL", "status" => "TRADING", "marginAsset" => "USDT"},
                 map,
                 target: Bourse.Market
               )

      assert {:ok, %Bourse.Market{type: "future", active: false}} =
               Bourse.ResponseParser.apply_mappings(
                 %{"contractType" => "CURRENT_QUARTER", "status" => "PENDING_TRADING"},
                 map,
                 target: Bourse.Market
               )

      # Spot rows have no contractType — type stays nil at the field-map layer so
      # market_type_from_raw can still fill "spot" from baseAsset/quoteAsset.
      assert {:ok, %Bourse.Market{type: nil, active: true}} =
               Bourse.ResponseParser.apply_mappings(
                 %{"status" => "TRADING", "baseAsset" => "BTC", "quoteAsset" => "USDT"},
                 map,
                 target: Bourse.Market
               )
    end
  end

  test "fetch_markets derives spot and USD-M boolean flags from type and settle" do
    spot_body = %{
      "symbols" => [
        %{
          "symbol" => "BTCUSDT",
          "status" => "TRADING",
          "baseAsset" => "BTC",
          "quoteAsset" => "USDT",
          "baseAssetPrecision" => 8,
          "quotePrecision" => 8,
          "filters" => [
            %{"filterType" => "PRICE_FILTER", "tickSize" => "0.01", "minPrice" => "0.01", "maxPrice" => "1000000"},
            %{"filterType" => "LOT_SIZE", "stepSize" => "0.00001", "minQty" => "0.00001", "maxQty" => "9000"}
          ]
        }
      ]
    }

    swap_body = %{
      "symbols" => [
        %{
          "symbol" => "BTCUSDT",
          "status" => "TRADING",
          "contractType" => "PERPETUAL",
          "baseAsset" => "BTC",
          "quoteAsset" => "USDT",
          "marginAsset" => "USDT",
          "baseAssetPrecision" => 8,
          "quotePrecision" => 8,
          "filters" => [
            %{"filterType" => "PRICE_FILTER", "tickSize" => "0.1", "minPrice" => "0.1", "maxPrice" => "1000000"},
            %{"filterType" => "LOT_SIZE", "stepSize" => "0.001", "minQty" => "0.001", "maxQty" => "1000"}
          ]
        }
      ]
    }

    inverse_body = %{
      "symbols" => [
        %{
          "symbol" => "BTCUSD_PERP",
          "status" => "TRADING",
          "contractType" => "PERPETUAL",
          "baseAsset" => "BTC",
          "quoteAsset" => "USD",
          "marginAsset" => "BTC",
          "baseAssetPrecision" => 8,
          "quotePrecision" => 8,
          "filters" => [
            %{"filterType" => "PRICE_FILTER", "tickSize" => "0.1", "minPrice" => "0.1", "maxPrice" => "1000000"},
            %{"filterType" => "LOT_SIZE", "stepSize" => "1", "minQty" => "1", "maxQty" => "1000000"}
          ]
        }
      ]
    }

    # Pin one section per call (endpoint_index) so the stub answers a single shape.
    spot_index = market_endpoint_index!("binance", "public")
    fapi_index = market_endpoint_index!("binanceusdm", "fapiPublic")
    dapi_index = market_endpoint_index!("binanceusdm", "dapiPublic")

    {unexpected, stub} = markets_stub(%{"/api/v3/exchangeInfo" => spot_body})

    spot_result =
      Unified.call(Exchange.new!("binance"), :fetch_markets, "fetchMarkets", %{},
        endpoint_index: spot_index,
        plug: {Req.Test, stub}
      )

    assert_no_unexpected_paths(unexpected, "unexpected Binance spot markets path")
    assert {:ok, [%Bourse.Market{} = spot]} = spot_result

    assert spot.symbol == "BTC/USDT"
    assert spot.type == "spot"
    assert spot.spot == true
    assert spot.swap == false
    assert spot.contract == false
    assert spot.linear == false
    assert spot.inverse == false
    assert spot.active == true
    assert is_nil(spot.settle)

    {unexpected, stub} =
      markets_stub(%{
        "/fapi/v1/exchangeInfo" => swap_body,
        "/dapi/v1/exchangeInfo" => inverse_body
      })

    usdm = Exchange.new!("binanceusdm")

    linear_result =
      Unified.call(usdm, :fetch_markets, "fetchMarkets", %{},
        endpoint_index: fapi_index,
        plug: {Req.Test, stub}
      )

    assert_no_unexpected_paths(unexpected, "unexpected Binance USD-M markets path")
    assert {:ok, [%Bourse.Market{} = linear]} = linear_result

    assert linear.symbol == "BTC/USDT:USDT"
    assert linear.type == "swap"
    assert linear.swap == true
    assert linear.spot == false
    assert linear.contract == true
    assert linear.linear == true
    assert linear.inverse == false
    assert linear.active == true
    assert linear.settle == "USDT"

    assert {:ok, [%Bourse.Market{} = inverse]} =
             Unified.call(usdm, :fetch_markets, "fetchMarkets", %{},
               endpoint_index: dapi_index,
               plug: {Req.Test, stub}
             )

    assert inverse.symbol == "BTC/USD:BTC"
    assert inverse.type == "swap"
    assert inverse.swap == true
    assert inverse.contract == true
    assert inverse.linear == false
    assert inverse.inverse == true
    assert inverse.settle == "BTC"
  end

  test "fetch_markets derives maker/taker, tick-size precision and filter limits (task 164)" do
    # Offline regression for the Binance-owned market-semantics slice:
    # - maker/taker from the published fee schedule (not exchangeInfo, not private tradeFee)
    # - precision amount/price = LOT_SIZE.stepSize / PRICE_FILTER.tickSize (tick sizes, not digits)
    # - limits from the instrument's own filters[] (LOT_SIZE / PRICE_FILTER / NOTIONAL|MIN_NOTIONAL)
    spot_body = %{
      "symbols" => [
        %{
          "symbol" => "BTCUSDT",
          "status" => "TRADING",
          "baseAsset" => "BTC",
          "quoteAsset" => "USDT",
          "baseAssetPrecision" => 8,
          "quotePrecision" => 8,
          "filters" => [
            %{
              "filterType" => "PRICE_FILTER",
              "tickSize" => "0.01",
              "minPrice" => "0.01",
              "maxPrice" => "1000000"
            },
            %{
              "filterType" => "LOT_SIZE",
              "stepSize" => "0.00001",
              "minQty" => "0.00001",
              "maxQty" => "9000"
            },
            %{
              "filterType" => "MARKET_LOT_SIZE",
              "stepSize" => "0.00001",
              "minQty" => "0.00000",
              "maxQty" => "128.93"
            },
            %{
              "filterType" => "NOTIONAL",
              "minNotional" => "5.00000000",
              "maxNotional" => "9000000.00000000"
            }
          ]
        }
      ]
    }

    linear_body = %{
      "symbols" => [
        %{
          "symbol" => "BTCUSDT",
          "status" => "TRADING",
          "contractType" => "PERPETUAL",
          "baseAsset" => "BTC",
          "quoteAsset" => "USDT",
          "marginAsset" => "USDT",
          "baseAssetPrecision" => 8,
          "quotePrecision" => 8,
          "filters" => [
            %{
              "filterType" => "PRICE_FILTER",
              "tickSize" => "0.1",
              "minPrice" => "556.8",
              "maxPrice" => "4529764"
            },
            %{
              "filterType" => "LOT_SIZE",
              "stepSize" => "0.001",
              "minQty" => "0.001",
              "maxQty" => "1000"
            },
            %{"filterType" => "MIN_NOTIONAL", "notional" => "50"}
          ]
        }
      ]
    }

    inverse_body = %{
      "symbols" => [
        %{
          "symbol" => "BTCUSD_PERP",
          "status" => "TRADING",
          "contractType" => "PERPETUAL",
          "baseAsset" => "BTC",
          "quoteAsset" => "USD",
          "marginAsset" => "BTC",
          "baseAssetPrecision" => 8,
          "quotePrecision" => 8,
          "filters" => [
            %{
              "filterType" => "PRICE_FILTER",
              "tickSize" => "0.1",
              "minPrice" => "1000",
              "maxPrice" => "4520958"
            },
            %{
              "filterType" => "LOT_SIZE",
              "stepSize" => "1",
              "minQty" => "1",
              "maxQty" => "1000000"
            }
          ]
        }
      ]
    }

    spot_index = market_endpoint_index!("binance", "public")
    fapi_index = market_endpoint_index!("binanceusdm", "fapiPublic")
    dapi_index = market_endpoint_index!("binanceusdm", "dapiPublic")

    {unexpected, stub} = markets_stub(%{"/api/v3/exchangeInfo" => spot_body})

    assert {:ok, [%Bourse.Market{} = spot]} =
             Unified.call(Exchange.new!("binance"), :fetch_markets, "fetchMarkets", %{},
               endpoint_index: spot_index,
               plug: {Req.Test, stub}
             )

    assert_no_unexpected_paths(unexpected, "unexpected Binance spot markets path")

    assert spot.symbol == "BTC/USDT"
    assert spot.maker == 0.001
    assert spot.taker == 0.001
    assert spot.percentage == true
    assert spot.tier_based == false
    assert spot.precision_mode == "tick_size"
    assert_in_delta spot.precision["price"], 0.01, 1.0e-12
    assert_in_delta spot.precision["amount"], 0.00001, 1.0e-12
    assert_in_delta spot.limits["amount"]["min"], 0.00001, 1.0e-12
    assert_in_delta spot.limits["amount"]["max"], 9000.0, 1.0e-9
    assert_in_delta spot.limits["price"]["min"], 0.01, 1.0e-12
    assert_in_delta spot.limits["price"]["max"], 1_000_000.0, 1.0e-6
    assert_in_delta spot.limits["cost"]["min"], 5.0, 1.0e-12
    assert_in_delta spot.limits["cost"]["max"], 9_000_000.0, 1.0e-3
    assert_in_delta spot.limits["market"]["max"], 128.93, 1.0e-9

    {unexpected, stub} =
      markets_stub(%{
        "/fapi/v1/exchangeInfo" => linear_body,
        "/dapi/v1/exchangeInfo" => inverse_body
      })

    usdm = Exchange.new!("binanceusdm")

    assert {:ok, [%Bourse.Market{} = linear]} =
             Unified.call(usdm, :fetch_markets, "fetchMarkets", %{},
               endpoint_index: fapi_index,
               plug: {Req.Test, stub}
             )

    assert_no_unexpected_paths(unexpected, "unexpected Binance USD-M markets path")

    assert linear.symbol == "BTC/USDT:USDT"
    assert linear.maker == 0.0002
    assert linear.taker == 0.0005
    assert linear.percentage == true
    assert linear.tier_based == true
    assert linear.precision_mode == "tick_size"
    assert_in_delta linear.precision["price"], 0.1, 1.0e-12
    assert_in_delta linear.precision["amount"], 0.001, 1.0e-12
    assert_in_delta linear.limits["amount"]["min"], 0.001, 1.0e-12
    assert_in_delta linear.limits["price"]["min"], 556.8, 1.0e-9
    assert_in_delta linear.limits["cost"]["min"], 50.0, 1.0e-12

    assert {:ok, [%Bourse.Market{} = inverse]} =
             Unified.call(usdm, :fetch_markets, "fetchMarkets", %{},
               endpoint_index: dapi_index,
               plug: {Req.Test, stub}
             )

    assert inverse.symbol == "BTC/USD:BTC"
    assert inverse.maker == 0.0001
    assert inverse.taker == 0.0005
    assert inverse.precision_mode == "tick_size"
    assert_in_delta inverse.precision["price"], 0.1, 1.0e-12
    assert_in_delta inverse.precision["amount"], 1.0, 1.0e-12
    assert_in_delta inverse.limits["amount"]["min"], 1.0, 1.0e-12
    assert_in_delta inverse.limits["price"]["min"], 1000.0, 1.0e-9
  end

  test "recorded exchangeInfo fixture pins filter-derived market semantics (task 164)" do
    fixture = Jason.decode!(File.read!("test/fixtures/responses/binance/fetch_markets.json"))
    responses = fixture["responses"]

    spot_resp =
      Enum.find(responses, fn resp ->
        body = resp["body"] || %{}
        symbols = body["symbols"] || []
        Enum.any?(symbols, &(&1["symbol"] == "BTCUSDT" and is_nil(&1["contractType"])))
      end)

    assert is_map(spot_resp), "recorded fixture must include a spot BTCUSDT exchangeInfo body"

    spot_row =
      Enum.find(spot_resp["body"]["symbols"], fn row ->
        row["symbol"] == "BTCUSDT" and is_nil(row["contractType"])
      end)

    filters = Map.get(spot_row, "filters", [])
    price_filter = Enum.find(filters, &(&1["filterType"] == "PRICE_FILTER"))
    lot_filter = Enum.find(filters, &(&1["filterType"] == "LOT_SIZE"))
    notional_filter = Enum.find(filters, &(&1["filterType"] in ["NOTIONAL", "MIN_NOTIONAL"]))

    assert is_map(price_filter)
    assert is_map(lot_filter)
    assert is_map(notional_filter)

    body = %{"symbols" => [spot_row]}
    {unexpected, stub} = markets_stub(%{"/api/v3/exchangeInfo" => body})

    assert {:ok, [%Bourse.Market{} = market]} =
             Unified.call(Exchange.new!("binance"), :fetch_markets, "fetchMarkets", %{},
               endpoint_index: market_endpoint_index!("binance", "public"),
               plug: {Req.Test, stub}
             )

    assert_no_unexpected_paths(unexpected, "unexpected Binance recorded markets path")

    assert market.symbol == "BTC/USDT"
    assert market.maker == 0.001
    assert market.taker == 0.001
    assert market.precision_mode == "tick_size"
    assert_in_delta market.precision["price"], String.to_float(price_filter["tickSize"]), 1.0e-12
    assert_in_delta market.precision["amount"], String.to_float(lot_filter["stepSize"]), 1.0e-12
    assert_in_delta market.limits["amount"]["min"], String.to_float(lot_filter["minQty"]), 1.0e-12
    assert_in_delta market.limits["amount"]["max"], String.to_float(lot_filter["maxQty"]), 1.0e-9
    assert_in_delta market.limits["price"]["min"], String.to_float(price_filter["minPrice"]), 1.0e-12
    assert_in_delta market.limits["price"]["max"], String.to_float(price_filter["maxPrice"]), 1.0e-6

    expected_cost_min =
      case notional_filter do
        %{"minNotional" => min} -> String.to_float(min)
        %{"notional" => min} -> String.to_float(min)
      end

    assert_in_delta market.limits["cost"]["min"], expected_cost_min, 1.0e-12
  end

  test "spot fetch_markets splits non-USDT quotes on exchangeInfo baseAsset/quoteAsset" do
    # Live 2026-07-19: 1116/5966 binance spot markets came back with the raw compact
    # id as `:symbol` because the separator-less id was split by pattern. One row per
    # quote asset observed raw that day.
    rows =
      for {id, base, quote} <- [
            {"AAVEBNB", "AAVE", "BNB"},
            {"AAVETRY", "AAVE", "TRY"},
            {"AAVEBRL", "AAVE", "BRL"},
            {"AAVEBKRW", "AAVE", "BKRW"},
            {"LINKUSD1", "LINK", "USD1"}
          ] do
        %{
          "symbol" => id,
          "status" => "TRADING",
          "baseAsset" => base,
          "quoteAsset" => quote,
          "baseAssetPrecision" => 8,
          "quotePrecision" => 8,
          "filters" => []
        }
      end

    {unexpected, stub} = markets_stub(%{"/api/v3/exchangeInfo" => %{"symbols" => rows}})

    result =
      Unified.call(Exchange.new!("binance"), :fetch_markets, "fetchMarkets", %{},
        endpoint_index: market_endpoint_index!("binance", "public"),
        plug: {Req.Test, stub}
      )

    assert_no_unexpected_paths(unexpected, "unexpected Binance spot markets path")
    assert {:ok, markets} = result

    assert Enum.map(markets, & &1.symbol) ==
             ["AAVE/BNB", "AAVE/TRY", "AAVE/BRL", "AAVE/BKRW", "LINK/USD1"]

    assert Enum.all?(markets, &(&1.type == "spot" and is_nil(&1.settle)))
  end

  test "capital transaction rows retain endpoint-specific status and sparse acknowledgements" do
    exchange = Exchange.new!("binance")

    deposit = %{
      "amount" => "10",
      "coin" => "USDT",
      "network" => "TRX",
      "status" => "0",
      "address" => "deposit-address",
      "insertTime" => "1714923704000",
      "transferType" => "1"
    }

    withdrawal = %{
      "id" => "withdrawal-id",
      "amount" => "9",
      "transactionFee" => "1",
      "coin" => "USDT",
      "network" => "TRX",
      "status" => "1",
      "address" => "withdrawal-address",
      "addressTag" => "memo",
      "applyTime" => "2024-05-05 15:38:56",
      "transferType" => "0"
    }

    assert {:ok, [%Bourse.Transaction{type: "deposit", status: "pending", network: "TRC20", internal: true}]} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :fetch_deposits,
               "fetchDeposits",
               [deposit],
               %{},
               :parse_transaction,
               true
             )

    assert {:ok,
            [
              %Bourse.Transaction{
                type: "withdrawal",
                status: "canceled",
                timestamp: 1_714_923_536_000,
                fee: %{"currency" => "USDT", "cost" => 1.0},
                tag: "memo",
                internal: false
              }
            ]} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :fetch_withdrawals,
               "fetchWithdrawals",
               [withdrawal],
               %{},
               :parse_transaction,
               true
             )

    assert {:ok, %Bourse.Transaction{id: "withdrawal-id", currency: "USDT", type: nil, amount: nil, fee: nil}} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :withdraw,
               "withdraw",
               %{"id" => "withdrawal-id"},
               %{"code" => "USDT"},
               :parse_transaction,
               false
             )
  end

  test "spot order lists are separate typed reads with their own request mappings" do
    exchange = Exchange.new!("binance", api_key: "key", secret: "secret", sandbox: true)
    timestamp = 1_565_245_656_253

    order_references = [
      %{"clientOrderId" => "limit-client", "orderId" => 4, "symbol" => "BTCUSDT"},
      %{"clientOrderId" => "stop-client", "orderId" => 5, "symbol" => "BTCUSDT"}
    ]

    row = %{
      "contingencyType" => "OCO",
      "listClientOrderId" => "group-client",
      "listOrderStatus" => "EXECUTING",
      "listStatusType" => "EXEC_STARTED",
      "orderListId" => 27,
      "orders" => order_references,
      "symbol" => "BTCUSDT",
      "transactionTime" => timestamp
    }

    {single_requests, single_stub} = path_body_stub(row)

    assert {:ok,
            %OrderList{
              id: "27",
              client_order_id: "group-client",
              symbol: "BTC/USDT",
              type: "oco",
              status: "open",
              status_type: "exec_started",
              timestamp: ^timestamp,
              orders: ^order_references,
              info: ^row
            } = order_list} =
             Bourse.fetch_order_list(exchange, 27,
               plug: {Req.Test, single_stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert order_list.datetime == Bourse.Timestamp.iso8601_from_ms(timestamp)
    single_request = RequestCollector.one!(single_requests)
    assert single_request.request_path == "/api/v3/orderList"

    assert single_request |> RequestCollector.query() |> signed_query_params() == %{
             "orderListId" => "27"
           }

    {history_requests, history_stub} = path_body_stub([row])

    assert {:ok, [%OrderList{id: "27"}]} =
             Bourse.fetch_order_lists(exchange,
               since: timestamp,
               until: timestamp + 1,
               limit: 1,
               plug: {Req.Test, history_stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    history_request = RequestCollector.one!(history_requests)
    assert history_request.request_path == "/api/v3/allOrderList"

    assert history_request |> RequestCollector.query() |> signed_query_params() == %{
             "endTime" => Integer.to_string(timestamp + 1),
             "limit" => "1",
             "startTime" => Integer.to_string(timestamp)
           }

    {open_requests, open_stub} = path_body_stub([row])

    assert {:ok, [%OrderList{id: "27", status: "open"}]} =
             Bourse.fetch_open_order_lists(exchange,
               plug: {Req.Test, open_stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert RequestCollector.one!(open_requests).request_path == "/api/v3/openOrderList"
  end

  test "spot order reads remain complete while ACKs retain only Binance-supplied values" do
    exchange = Exchange.new!("binance")

    read = %{
      "symbol" => "LTCUSDT",
      "orderId" => "3397148653",
      "clientOrderId" => "client-id",
      "price" => "0.00000000",
      "origQty" => "0.10000000",
      "executedQty" => "0.10000000",
      "cummulativeQuoteQty" => "9.08000000",
      "status" => "FILLED",
      "timeInForce" => "GTC",
      "type" => "MARKET",
      "side" => "SELL",
      "time" => "1679571174472",
      "updateTime" => "1679571174472"
    }

    ack = %{
      "symbol" => "BTCUSDT",
      "orderId" => 18_211_862,
      "orderListId" => -1,
      "clientOrderId" => "bourse-task336-observed",
      "transactTime" => 1_784_366_516_871
    }

    assert {:ok, %Bourse.Order{status: "closed", amount: 0.1, filled: 0.1, cost: 9.08}} =
             ReadParse.parse(exchange, Bourse.Binance, :fetch_order, "fetchOrder", read, %{}, :parse_order, false)

    assert {:ok, [%Bourse.Order{status: "closed", amount: 0.1, filled: 0.1, cost: 9.08}]} =
             ReadParse.parse(exchange, Bourse.Binance, :fetch_orders, "fetchOrders", [read], %{}, :parse_order, true)

    {plain_requests, plain_stub} = path_body_stub([read])

    assert {:ok, [%Bourse.Order{} = plain_order]} =
             Bourse.fetch_orders(Exchange.new!("binance", api_key: "key", secret: "secret"),
               symbol: "LTC/USDT",
               plug: {Req.Test, plain_stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    assert Map.keys(plain_order) == Map.keys(%Bourse.Order{})
    refute Map.has_key?(plain_order, :orders)
    assert RequestCollector.one!(plain_requests).request_path == "/api/v3/allOrders"

    assert {:ok,
            %Bourse.Order{
              id: "18211862",
              client_order_id: "bourse-task336-observed",
              timestamp: 1_784_366_516_871,
              last_update_timestamp: 1_784_366_516_871,
              symbol: "BTC/USDT",
              amount: nil,
              filled: nil,
              cost: nil,
              status: nil
            }} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :create_order,
               "createOrder",
               ack,
               %{"symbol" => "BTC/USDT"},
               :parse_order,
               false
             )
  end

  test "Binance order acknowledgements preserve only venue-stated values" do
    exchange = Exchange.new!("binance")

    # RESULT mode: the ACK keys PLUS order state, but no executedQty. Binance
    # therefore states no fill fact.
    result_mode = %{
      "symbol" => "BTCUSDT",
      "orderId" => 18_211_862,
      "orderListId" => -1,
      "clientOrderId" => "bourse-task336-result",
      "transactTime" => 1_784_366_516_871,
      "origQty" => "0.00200000",
      "status" => "NEW",
      "type" => "LIMIT",
      "side" => "BUY"
    }

    assert {:ok, %Bourse.Order{status: "open", amount: 0.002, filled: nil, cost: nil, remaining: nil}} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :create_order,
               "createOrder",
               result_mode,
               %{"symbol" => "BTC/USDT"},
               :parse_order,
               false
             )

    # Binance USD-M algo cancel acknowledgement has no executedQty, so it must
    # not manufacture a zero fill.
    algo_ack = %{"algoId" => "3386", "clientAlgoId" => "SQPifLIBAzZf0o4YAOGIwm", "code" => "200", "msg" => "success"}

    assert {:ok, %Bourse.Order{id: "3386", filled: nil, amount: nil, cost: nil, status: nil}} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :cancel_order,
               "cancelOrder",
               algo_ack,
               %{},
               :parse_order,
               false
             )
  end

  test "Binance ignores a negative working-time sentinel for the order timestamp" do
    exchange = Exchange.new!("binance")

    trailing_order = %{
      "symbol" => "ETHUSDT",
      "orderId" => "2672907",
      "transactTime" => "1758618616599",
      "origQty" => "0.00860000",
      "executedQty" => "0.00000000",
      "status" => "NEW",
      "type" => "TAKE_PROFIT",
      "side" => "BUY",
      "workingTime" => "-1"
    }

    assert {:ok, %Bourse.Order{timestamp: 1_758_618_616_599}} =
             ReadParse.parse(
               exchange,
               Bourse.Binance,
               :create_order,
               "createOrder",
               trailing_order,
               %{"symbol" => "ETH/USDT"},
               :parse_order,
               false
             )
  end

  test "Binance Futures cancel all acknowledgements remain venue bodies" do
    acknowledgement = %{"code" => "200", "msg" => "The operation of cancel all open order is done."}

    for {exchange_id, module, symbol} <- [
          {"binanceusdm", Bourse.Binanceusdm, "BTC/USDT:USDT"},
          {"binancecoinm", Bourse.Binancecoinm, "BTC/USD:BTC"}
        ] do
      assert {:ok, ^acknowledgement} =
               ReadParse.parse(
                 Exchange.new!(exchange_id),
                 module,
                 :cancel_all_orders,
                 "cancelAllOrders",
                 acknowledgement,
                 %{"symbol" => symbol},
                 :parse_order,
                 true
               )
    end
  end

  # Binance's Deposit History page enumerates five status codes verbatim:
  # "0: pending, 6: credited but cannot withdraw, 7: Wrong Deposit,
  #  8: Waiting User confirm, 1: success". Bourse's map carries only 0/1/6, so 7
  # and 8 must not regress back to nil. See docs/authored-spec-carves/binance.md.
  test "deposit status covers every code Binance documents, including 7 and 8" do
    exchange = Exchange.new!("binance")

    parse_status = fn code ->
      row = %{
        "amount" => "1",
        "coin" => "USDT",
        "network" => "TRX",
        "status" => code,
        "address" => "deposit-address",
        "insertTime" => "1714923704000",
        "transferType" => "0"
      }

      {:ok, [%Bourse.Transaction{status: status}]} =
        ReadParse.parse(exchange, Bourse.Binance, :fetch_deposits, "fetchDeposits", [row], %{}, :parse_transaction, true)

      status
    end

    assert parse_status.("0") == "pending"
    assert parse_status.("1") == "ok"
    assert parse_status.("6") == "ok"
    assert parse_status.("7") == "failed"
    assert parse_status.("8") == "pending"
  end

  # An open-ended venue vocabulary: the authored map normalizes three ids, and
  # anything else must survive as Binance's own string rather than nil.
  test "capital network ids outside the authored map survive unnormalized" do
    exchange = Exchange.new!("binance")

    parse_network = fn network ->
      row = %{
        "amount" => "1",
        "coin" => "USDT",
        "network" => network,
        "status" => "1",
        "address" => "deposit-address",
        "insertTime" => "1714923704000",
        "transferType" => "0"
      }

      {:ok, [%Bourse.Transaction{network: parsed}]} =
        ReadParse.parse(exchange, Bourse.Binance, :fetch_deposits, "fetchDeposits", [row], %{}, :parse_transaction, true)

      parsed
    end

    assert parse_network.("TRX") == "TRC20"
    assert parse_network.("ETH") == "ERC20"
    assert parse_network.("BSC") == "BEP20"
    assert parse_network.("BTC") == "BTC"
    assert parse_network.("ARBITRUM") == "ARBITRUM"
  end

  defp funding_rate_stub(native_symbol, premium_path, funding_path, interval_hours) do
    stub = unique_stub("binance_funding_rate")
    {:ok, requests} = RequestCollector.start_link()

    premium = %{
      "indexPrice" => "3000",
      "lastFundingRate" => "0.0001",
      "markPrice" => "3001",
      "nextFundingTime" => 1_700_028_800_000,
      "symbol" => native_symbol,
      "time" => 1_700_000_000_000
    }

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      body =
        case conn.request_path do
          ^premium_path when premium_path == "/dapi/v1/premiumIndex" ->
            [premium]

          ^premium_path ->
            premium

          ^funding_path when is_integer(interval_hours) ->
            [%{"fundingIntervalHours" => interval_hours, "symbol" => native_symbol}]

          ^funding_path ->
            []
        end

      Req.Test.json(conn, body)
    end)

    {requests, stub}
  end

  defp funding_rates_stub([adjusted_symbol | _rest] = native_symbols, no_funding_symbol, premium_path, funding_path) do
    stub = unique_stub("binance_funding_rates")
    {:ok, requests} = RequestCollector.start_link()

    premium_rows =
      Enum.map(native_symbols, fn symbol ->
        %{
          "indexPrice" => "3000",
          "lastFundingRate" => "0.0001",
          "markPrice" => "3001",
          "nextFundingTime" => if(symbol == no_funding_symbol, do: 0, else: 1_700_028_800_000),
          "symbol" => symbol,
          "time" => 1_700_000_000_000
        }
      end)

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      case conn.request_path do
        ^premium_path -> Req.Test.json(conn, premium_rows)
        ^funding_path -> Req.Test.json(conn, [%{"fundingIntervalHours" => 4, "symbol" => adjusted_symbol}])
      end
    end)

    {requests, stub}
  end

  defp body_capturing_stub(body) do
    stub = unique_stub("binance_body")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      {conn, _raw_body} = RequestCollector.capture_with_body(requests, conn)
      Req.Test.json(conn, body)
    end)

    {requests, stub}
  end

  defp futures_balance_body do
    %{
      "assets" => [
        %{
          "asset" => "USDT",
          "availableBalance" => "4",
          "initialMargin" => "1",
          "walletBalance" => "5"
        }
      ],
      "positions" => []
    }
  end

  defp account_stub(body) do
    stub = unique_stub("binance_account")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, body)
    end)

    {requests, stub}
  end

  defp assert_account_request(requests, expected_path) do
    conn = RequestCollector.one!(requests)
    assert conn.request_path == expected_path
  end

  defp ohlcv_stub do
    stub = unique_stub("binance_ohlcv")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, [[1_700_000_000_000, "1", "2", "0.5", "1.5", "10"]])
    end)

    {requests, stub}
  end

  defp assert_ohlcv_request(requests, expected_path) do
    conn = RequestCollector.one!(requests)
    assert conn.request_path == expected_path
    query = URI.decode_query(conn.query_string)
    refute query["price"]
    refute query["type"]
    refute query["subType"]
    refute query["sub_type"]
  end

  defp ticker_stub do
    stub = unique_stub("binance_tickers")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, [])
    end)

    {requests, stub}
  end

  defp assert_ticker_request(requests, expected_path) do
    conn = RequestCollector.one!(requests)
    assert conn.request_path == expected_path
  end

  defp path_body_stub(body) do
    stub = unique_stub("binance_path_body")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, body)
    end)

    {requests, stub}
  end

  defp signed_query_params(query), do: Map.drop(query, ["recvWindow", "signature", "timestamp"])

  defp assert_usdm_typed_endpoint(exchange, method, js_name, body, expected_path, assertion) do
    {requests, stub} = path_body_stub(body)

    assert {:ok, result} =
             Unified.call(exchange, method, js_name, %{},
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert RequestCollector.one!(requests).request_path == expected_path
    assertion.(result)
  end

  defp assert_coinm_typed_endpoint(exchange, method, js_name, params, body, expected_path, assertion) do
    {requests, stub} = path_body_stub(body)

    assert {:ok, result} =
             Unified.call(exchange, method, js_name, params,
               plug: {Req.Test, stub},
               timestamp_ms_override: @frozen_timestamp_ms
             )

    request = RequestCollector.one!(requests)
    assert request.request_path == expected_path

    if symbol = params["symbol"] do
      assert signed_query_params(RequestCollector.query(request))["symbol"] == Symbol.to_exchange_id(symbol, exchange)
    end

    assertion.(result)
  end

  defp coinm_order_row(id, status) do
    %{
      "avgPrice" => "50000",
      "clientOrderId" => "task-545-#{id}",
      "cumBase" => "1",
      "cumQuote" => "50000",
      "executedQty" => "1",
      "orderId" => id,
      "origQty" => "1",
      "origType" => "LIMIT",
      "pair" => "BTCUSD",
      "positionSide" => "LONG",
      "price" => "50000",
      "reduceOnly" => false,
      "side" => "BUY",
      "status" => status,
      "stopPrice" => "0",
      "symbol" => "BTCUSD_PERP",
      "time" => @frozen_timestamp_ms,
      "timeInForce" => "GTC",
      "type" => "LIMIT",
      "updateTime" => @frozen_timestamp_ms
    }
  end

  defp assert_path_body_request(requests, expected_path) do
    conn = RequestCollector.one!(requests)
    assert conn.request_path == expected_path
  end

  defp assert_borrow_interest_request(exchange, params, expected_query) do
    {requests, stub} = path_body_stub(%{"rows" => []})

    assert {:ok, []} =
             Unified.call(exchange, :fetch_borrow_interest, "fetchBorrowInterest", params,
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    request = RequestCollector.one!(requests)
    assert request.request_path == "/sapi/v1/margin/interestHistory"

    query =
      request.query_string
      |> URI.decode_query()
      |> Map.drop(["timestamp", "signature", "recvWindow"])

    assert query == expected_query
  end

  defp ticker_rows_stub(rows) do
    stub = unique_stub("binance_ticker_rows")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, rows)
    end)

    {requests, stub}
  end

  defp assert_ticker_rows_request(requests, expected_path, expected_query) do
    conn = RequestCollector.one!(requests)
    assert conn.request_path == expected_path

    query = URI.decode_query(conn.query_string)

    if expected_query do
      assert query["symbols"] == expected_query
    else
      refute Map.has_key?(query, "symbols")
    end
  end

  defp ticker_and_spot_markets_stub(ticker_rows, market_rows) do
    stub = unique_stub("binance_tickers_unloaded_markets")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      case conn.request_path do
        "/api/v3/ticker/24hr" -> Req.Test.json(conn, ticker_rows)
        "/api/v3/exchangeInfo" -> Req.Test.json(conn, %{"symbols" => market_rows})
        _path -> Req.Test.json(conn, ticker_rows)
      end
    end)

    {requests, stub}
  end

  # Fan-out dispatches each surface from its own Task, so the hit paths are
  # collected in an Agent rather than the test process' mailbox.
  defp recording_markets_stub(path_bodies) when is_map(path_bodies) do
    stub = unique_stub("binance_markets_recording")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, Map.get(path_bodies, conn.request_path, %{"symbols" => []}))
    end)

    {requests, stub}
  end

  defp recorded_paths(requests) do
    requests
    |> RequestCollector.requests()
    |> Enum.map(& &1.conn.request_path)
    |> Enum.sort()
  end

  defp assert_recorded_paths(paths, expected_paths, diagnostic) do
    actual_paths = recorded_paths(paths)

    assert actual_paths == expected_paths, "#{diagnostic}: #{inspect(actual_paths)}"
  end

  defp markets_stub(path_bodies) when is_map(path_bodies) do
    stub = unique_stub("binance_markets")
    {:ok, unexpected} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      case Map.fetch(path_bodies, conn.request_path) do
        {:ok, body} ->
          Req.Test.json(conn, body)

        # A raise here would be swallowed by Bourse.HTTP's transport rescue, so the
        # path is collected for the caller to assert on after the call returns.
        :error ->
          conn = RequestCollector.capture(unexpected, conn)
          Req.Test.json(conn, %{"symbols" => []})
      end
    end)

    {unexpected, stub}
  end

  defp assert_no_unexpected_paths(unexpected, diagnostic) do
    paths =
      unexpected
      |> RequestCollector.requests()
      |> Enum.map(& &1.conn.request_path)
      |> Enum.sort()

    assert paths == [], "#{diagnostic}: #{inspect(paths)}"
  end

  defp assert_private_path(exchange_id, method, params, verb, expected_path, assert_params \\ fn _params -> :ok end) do
    {requests, stub} = order_stub()
    exchange = Exchange.new!(exchange_id, api_key: "key", secret: "secret", sandbox: true)
    js_name = Unified.js_name_for!(method)

    assert {:ok, _} =
             Unified.call(exchange, method, js_name, params,
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert_order_request(requests, verb, expected_path, assert_params)
  end

  defp regular_open_order do
    %{
      "executedQty" => "0",
      "orderId" => "12345",
      "origQty" => "0.02",
      "price" => "1500",
      "side" => "BUY",
      "status" => "NEW",
      "symbol" => "ETHUSDT",
      "time" => @frozen_timestamp_ms,
      "timeInForce" => "GTC",
      "type" => "LIMIT"
    }
  end

  defp algo_open_order do
    %{
      "algoId" => "9001",
      "algoStatus" => "NEW",
      "clientAlgoId" => "algo-client",
      "createTime" => @frozen_timestamp_ms,
      "orderType" => "STOP",
      "quantity" => "0.02",
      "side" => "SELL",
      "symbol" => "ETHUSDT",
      "timeInForce" => "GTC",
      "triggerPrice" => "1400"
    }
  end

  defp order_stub do
    stub = unique_stub("binance_order")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      {conn, body} = RequestCollector.capture_with_body(requests, conn)
      params = request_params(conn, body)
      Req.Test.json(conn, %{"orderId" => 12_345, "symbol" => params["symbol"], "status" => "NEW"})
    end)

    {requests, stub}
  end

  defp algo_order_stub do
    stub = unique_stub("binance_algo_order")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      {conn, body} = RequestCollector.capture_with_body(requests, conn)
      params = request_params(conn, body)

      Req.Test.json(conn, %{
        "algoId" => 12_345,
        "algoStatus" => "NEW",
        "orderType" => params["type"],
        "symbol" => params["symbol"]
      })
    end)

    {requests, stub}
  end

  defp assert_order_request(requests, verb, expected_path, assert_params) do
    %{conn: conn, body: body} = RequestCollector.one_request!(requests)

    assert conn.method == verb |> Atom.to_string() |> String.upcase()
    assert conn.request_path == expected_path

    params =
      conn
      |> request_params(body)
      |> Map.drop(["timestamp", "signature", "recvWindow"])

    assert_params.(params)
  end

  defp request_params(conn, raw_body) do
    query = URI.decode_query(conn.query_string || "")

    body =
      case raw_body do
        "" -> %{}
        raw_body -> URI.decode_query(raw_body)
      end

    Map.merge(query, body)
  end

  defp market_endpoint_index!(exchange_id, section) do
    configs = Exchange.new!(exchange_id).module.__unified_endpoint__(:fetch_markets)

    index =
      Enum.find_index(configs, fn config ->
        section in config.sections
      end)

    assert is_integer(index), "no fetch_markets section #{inspect(section)}"
    index
  end

  defp identifier_value(:symbol), do: "BTCUSDT"
  defp identifier_value(:timeframe), do: "1m"
  defp identifier_value(:code), do: "USDT"
  defp identifier_value(:id), do: "1"
  defp identifier_value(:amount), do: 1
  defp identifier_value(:type), do: "limit"
  defp identifier_value(:side), do: "buy"
  defp identifier_value(:address), do: "not-a-real-address"
  defp identifier_value(:from_code), do: "USDT"
  defp identifier_value(:to_code), do: "BTC"
  defp identifier_value(:leverage), do: 2
  defp identifier_value(:margin_mode), do: "isolated"
  defp identifier_value(:hedged), do: true
  defp identifier_value(_key), do: "identifier"

  defp unique_stub(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
