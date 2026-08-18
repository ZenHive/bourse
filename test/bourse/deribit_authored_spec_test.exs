defmodule Bourse.DeribitAuthoredSpecTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Symbol
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified
  alias Bourse.Unified.ReadParse

  @ratio_tolerance 1.0e-12

  test "nested option greeks populate the unified fields" do
    raw = %{
      "ask_iv" => 343.95,
      "bid_iv" => 0.0,
      "greeks" => %{"delta" => 0.7, "gamma" => 0.01, "rho" => 1.2, "theta" => -4.5, "vega" => 0.3},
      "mark_iv" => 59.44,
      "timestamp" => 1_784_204_793_040
    }

    assert {:ok, %Bourse.Greeks{} = greeks} = Bourse.Deribit.parse_greeks(raw)
    assert {greeks.delta, greeks.gamma, greeks.rho, greeks.theta, greeks.vega} == {0.7, 0.01, 1.2, -4.5, 0.3}
    assert greeks.bid_implied_volatility == 0.0
    assert greeks.mark_implied_volatility == 0.5944
    assert greeks.ask_implied_volatility == 3.4395
  end

  test "fetch_positions list read emits inverse margin fractions and skips the linear branch" do
    # Provider inverse example from the Positions contract; linear row uses
    # quote-settled margin against base `size_currency` and must stay nil.
    inverse = %{
      "direction" => "buy",
      "initial_margin" => 0.000197283,
      "instrument_name" => "BTC-PERPETUAL",
      "kind" => "future",
      "maintenance_margin" => 0.000143783,
      "size" => 50,
      "size_currency" => 0.006687487
    }

    linear = %{
      "direction" => "buy",
      "initial_margin" => 300,
      "instrument_name" => "ETH_USDC-PERPETUAL",
      "kind" => "future",
      "mark_price" => 3000.25,
      "maintenance_margin" => 150,
      "size" => 1500.125,
      "size_currency" => 0.5
    }

    {:ok, requests} = RequestCollector.start_link()

    exchange =
      Exchange.put_markets(private_exchange(), [
        %Bourse.Market{
          id: "BTC-PERPETUAL",
          symbol: "BTC/USD:BTC",
          contract: true,
          contract_size: 10.0,
          inverse: true,
          swap: true,
          type: "swap"
        },
        %Bourse.Market{
          id: "ETH_USDC-PERPETUAL",
          symbol: "ETH/USDC:USDC",
          contract: true,
          contract_size: 0.001,
          inverse: false,
          linear: true,
          swap: true,
          type: "swap"
        }
      ])

    assert {:ok, positions} =
             Unified.call(
               exchange,
               :fetch_positions,
               "fetchPositions",
               %{},
               plug: {Req.Test, stub(requests, rpc_result([inverse, linear]))}
             )

    assert_request!(requests, "/api/v2/private/get_positions")

    inverse_position = Enum.find(positions, &(&1.info["instrument_name"] == "BTC-PERPETUAL"))
    linear_position = Enum.find(positions, &(&1.info["instrument_name"] == "ETH_USDC-PERPETUAL"))

    assert %Bourse.Position{} = inverse_position
    assert %Bourse.Position{} = linear_position
    assert inverse_position.notional == 50.0
    assert inverse_position.base_quantity == 0.006687487
    assert inverse_position.contract_size == 10.0
    assert inverse_position.contracts == 5.0
    assert inverse_position.initial_margin_percentage
    assert inverse_position.maintenance_margin_percentage
    assert_in_delta inverse_position.initial_margin_percentage, 0.000197283 / 0.006687487, @ratio_tolerance
    assert_in_delta inverse_position.maintenance_margin_percentage, 0.000143783 / 0.006687487, @ratio_tolerance
    assert linear_position.notional == 1500.125
    assert linear_position.base_quantity == 0.5
    assert linear_position.contract_size == 0.001
    assert linear_position.contracts == 500.0
    assert linear_position.side == "long"
    assert linear_position.initial_margin_percentage == nil
    assert linear_position.maintenance_margin_percentage == nil
  end

  test "position fields preserve provider quote and base units while inverse margins branch by market" do
    spec = Bourse.Spec.load!("deribit")
    field_map = get_in(spec, ["normalization", "field_maps", "position", "field_map"])

    assert field_map["baseQuantity"] == %{
             "coercion" => "safeNumber",
             "key" => "size_currency",
             "kind" => "absolute"
           }

    assert field_map["notional"]["guard"] == %{"field" => "kind", "in" => ["future"]}

    assert field_map["notional"]["then"] == %{
             "coercion" => "safeNumber",
             "key" => "size",
             "kind" => "absolute"
           }

    for field <- ["initialMarginPercentage", "maintenanceMarginPercentage"] do
      rule = field_map[field]
      assert rule["kind"] == "when"
      assert rule["guard"] == %{"equals" => true, "field" => "_bourse_inverse"}
      refute Map.has_key?(rule, "discriminator")
      # Direct parse_*/2 callers carry no payload annotation; they degrade to
      # the request-context market.inverse discriminator instead of nil.
      assert rule["else"]["kind"] == "discriminated"
      assert rule["else"]["discriminator"] == "market.inverse"
    end
  end

  test "direct parse_position without a payload annotation degrades to market context" do
    raw = %{
      "instrument_name" => "BTC-PERPETUAL",
      "kind" => "future",
      "initial_margin" => 0.000197283,
      "maintenance_margin" => 0.000143783,
      "size" => 50,
      "size_currency" => 0.006687487
    }

    assert {:ok, %Bourse.Position{} = position} =
             Bourse.Deribit.parse_position(raw, market: %Bourse.Market{inverse: true})

    assert_in_delta position.initial_margin_percentage, 0.000197283 / 0.006687487, @ratio_tolerance
    assert_in_delta position.maintenance_margin_percentage, 0.000143783 / 0.006687487, @ratio_tolerance
    assert position.notional == 50.0
    assert position.base_quantity == 0.006687487
    assert position.contracts == nil

    linear_raw = %{
      "direction" => "sell",
      "instrument_name" => "ETH_USDC-PERPETUAL",
      "kind" => "future",
      "initial_margin" => 300,
      "mark_price" => 3000.25,
      "maintenance_margin" => 150,
      "size" => 1500.125,
      "size_currency" => 0.5
    }

    assert {:ok,
            %Bourse.Position{
              base_quantity: 0.5,
              notional: 1500.125,
              side: "short",
              initial_margin_percentage: nil,
              maintenance_margin_percentage: nil
            }} = Bourse.Deribit.parse_position(linear_raw, market: %Bourse.Market{linear: true})
  end

  test "symbol-less fetch_my_trades derives inverse cost from each payload row" do
    raw = %{
      "amount" => 10,
      "direction" => "buy",
      "instrument_name" => "BTC-PERPETUAL",
      "order_id" => "order-1",
      "order_type" => "limit",
      "price" => 50_000,
      "timestamp" => 1_784_204_793_040,
      "trade_id" => "trade-1"
    }

    exchange =
      Exchange.put_markets(private_exchange(), [
        %Bourse.Market{id: "BTC-PERPETUAL", symbol: "BTC/USD:BTC", inverse: true, linear: false}
      ])

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, [%Bourse.Trade{} = trade]} =
             Bourse.fetch_my_trades(
               exchange,
               plug: {Req.Test, stub(requests, rpc_result(%{"has_more" => false, "trades" => [raw]}))}
             )

    assert_request!(requests, "/api/v2/private/get_user_trades_by_currency")
    assert trade.amount == 10.0
    assert trade.price == 50_000.0
    assert trade.cost == 0.0002
  end

  test "direct parse_trade without a payload annotation degrades to market context" do
    raw = %{"amount" => 10, "price" => 50_000}

    assert {:ok, %Bourse.Trade{cost: 0.0002}} =
             Bourse.Deribit.parse_trade(raw, market: %Bourse.Market{inverse: true})

    assert {:ok, %Bourse.Trade{cost: 500_000.0}} =
             Bourse.Deribit.parse_trade(raw, market: %Bourse.Market{inverse: false})
  end

  test "trade cost branches on payload identity before direct-parser market context" do
    rule =
      "deribit"
      |> Bourse.Spec.load!()
      |> get_in(["normalization", "field_maps", "trade", "field_map", "cost"])

    assert rule["kind"] == "when"
    assert rule["guard"] == %{"equals" => true, "field" => "_bourse_inverse"}
    assert rule["then"]["op"] == "div"
    assert rule["else"]["kind"] == "discriminated"
    assert rule["else"]["discriminator"] == "market.inverse"
    assert rule["else"]["true"]["op"] == "div"
    assert rule["else"]["false"]["op"] == "mul"
  end

  test "Deribit money-row classification prefers loaded markets and falls back only for unknown ids" do
    known = %{"amount" => 10, "instrument_name" => "BTC-PERPETUAL", "price" => 50_000}
    unknown = %{"amount" => 10, "instrument_name" => "BTC-UNKNOWN", "price" => 50_000}

    exchange =
      Exchange.put_markets(private_exchange(), [
        %Bourse.Market{id: "BTC-PERPETUAL", symbol: "BTC/USD:BTC", inverse: false, linear: true}
      ])

    assert {:ok, [known_trade, unknown_trade]} =
             ReadParse.parse(
               exchange,
               Bourse.Deribit,
               :fetch_my_trades,
               "fetchMyTrades",
               rpc_result(%{"has_more" => false, "trades" => [known, unknown]}),
               %{},
               :parse_trade,
               true
             )

    assert known_trade.cost == 500_000.0
    assert unknown_trade.cost == 0.0002
  end

  # Provider: "For perpetual and inverse futures the amount is in USD units. For
  # options and linear futures it is the underlying base currency coin."
  # (private/get_user_trades_by_currency). Option cost is therefore
  # `amount * price`, and the venue leaves `instrument_type` off option
  # instruments so a loaded option market reads `inverse: false` — the id
  # degradation path must agree with it instead of emitting `amount / price`.
  test "option rows are never inverse, with or without a loaded market" do
    option = %{"amount" => 10, "instrument_name" => "BTC-31JUL26-65000-C", "price" => 0.02}
    usdc_option = %{"amount" => 10, "instrument_name" => "ETH_USDC-31JUL26-3000-P", "price" => 0.02}

    for exchange <- [
          private_exchange(),
          Exchange.put_markets(private_exchange(), [
            %Bourse.Market{
              id: "BTC-31JUL26-65000-C",
              symbol: "BTC/USD:BTC-260731-65000-C",
              option: true,
              inverse: false,
              linear: false
            }
          ])
        ] do
      assert {:ok, [btc_trade, usdc_trade]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_my_trades,
                 "fetchMyTrades",
                 rpc_result(%{"has_more" => false, "trades" => [option, usdc_option]}),
                 %{},
                 :parse_trade,
                 true
               )

      assert_in_delta btc_trade.cost, 0.2, @ratio_tolerance
      assert_in_delta usdc_trade.cost, 0.2, @ratio_tolerance
    end
  end

  test "future spreads and dated inverse futures keep the inverse degradation branch" do
    rows = [
      %{"amount" => 10, "instrument_name" => "BTC-26JUN26", "price" => 50_000},
      %{"amount" => 10, "instrument_name" => "BTC-FS-31JUL26_17JUL26", "price" => 50_000}
    ]

    assert {:ok, trades} =
             ReadParse.parse(
               private_exchange(),
               Bourse.Deribit,
               :fetch_my_trades,
               "fetchMyTrades",
               rpc_result(%{"has_more" => false, "trades" => rows}),
               %{},
               :parse_trade,
               true
             )

    assert Enum.map(trades, & &1.cost) == [0.0002, 0.0002]
  end

  test "deposit and withdrawal rows share authored transaction fields" do
    deposit = %{
      "address" => "deposit-address",
      "amount" => 10.0,
      "currency" => "btc",
      "received_timestamp" => 1_555_224_541_722,
      "state" => "completed",
      "transaction_id" => "deposit-tx"
    }

    {:ok, deposit_requests} = RequestCollector.start_link()

    assert {:ok, [%Bourse.Transaction{} = parsed_deposit]} =
             Unified.call(
               private_exchange(),
               :fetch_deposits,
               "fetchDeposits",
               %{"code" => "BTC"},
               plug: {Req.Test, stub(deposit_requests, transaction_rows(deposit))}
             )

    assert_request!(deposit_requests, "/api/v2/private/get_deposits")

    assert parsed_deposit.currency == "BTC"
    assert parsed_deposit.timestamp == 1_555_224_541_722
    assert parsed_deposit.datetime == "2019-04-14T06:49:01.722Z"
    assert parsed_deposit.type == "deposit"
    assert parsed_deposit.status == "ok"

    withdrawal = %{
      "address" => "withdrawal-address",
      "amount" => 1.0,
      "currency" => "BTC",
      "created_timestamp" => 1_555_224_541_722,
      "id" => 1,
      "state" => "rejected"
    }

    {:ok, withdrawal_requests} = RequestCollector.start_link()

    assert {:ok, [%Bourse.Transaction{type: "withdrawal", status: "failed"}]} =
             Unified.call(
               private_exchange(),
               :fetch_withdrawals,
               "fetchWithdrawals",
               %{"code" => "BTC"},
               plug: {Req.Test, stub(withdrawal_requests, transaction_rows(withdrawal))}
             )

    assert_request!(withdrawal_requests, "/api/v2/private/get_withdrawals")
  end

  test "funding rate carries Deribit's observed hourly cadence" do
    assert {:ok, %Bourse.FundingRate{funding_rate: 0.001, interval: "1h"}} =
             Bourse.Deribit.parse_funding_rate(%{"result" => 0.001})
  end

  test "funding history parses Deribit's hourly interest rows" do
    raw = %{
      "index_price" => 63_468.58,
      "interest_1h" => 3.744828644533425e-7,
      "interest_8h" => 8.88800800171591e-7,
      "timestamp" => 1_785_801_600_000
    }

    assert {:ok,
            [
              %Bourse.FundingRateHistory{
                funding_rate: 3.744828644533425e-7,
                timestamp: 1_785_801_600_000,
                datetime: "2026-08-04T00:00:00.000Z"
              }
            ]} = Bourse.Deribit.parse_funding_rate_history([raw])
  end

  test "fetch_deposit_address unwraps Deribit's JSON-RPC result" do
    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.DepositAddress{currency: "BTC", address: "bcrt1qexample", network: nil} = address} =
             Bourse.fetch_deposit_address(
               private_exchange(),
               "BTC",
               plug:
                 {Req.Test,
                  stub(
                    requests,
                    rpc_result(%{"address" => "bcrt1qexample", "currency" => "BTC", "type" => "deposit"})
                  )}
             )

    assert_request!(requests, "/api/v2/private/get_current_deposit_address")

    refute Map.has_key?(address.info, "jsonrpc")
    assert address.info["type"] == "deposit"
  end

  test "fetch_trading_fees expands the per-currency schedule over matching markets" do
    exchange =
      Exchange.put_markets(private_exchange(), [
        %Bourse.Market{base: "BTC", symbol: "BTC/USD:BTC", type: "swap"},
        %Bourse.Market{base: "BTC", symbol: "BTC/USD:BTC-260626", type: "future"},
        %Bourse.Market{base: "ETH", symbol: "ETH/USD:ETH", type: "swap"}
      ])

    body =
      rpc_result(%{
        "currency" => "BTC",
        "fees" => [
          %{"instrument_type" => "perpetual", "maker_fee" => -0.0001, "taker_fee" => 0.0005},
          %{"instrument_type" => "future", "maker_fee" => 0.0, "taker_fee" => 0.0003}
        ]
      })

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, fees} =
             Bourse.fetch_trading_fees(
               exchange,
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/api/v2/private/get_account_summary")

    assert %Bourse.TradingFee{maker: -0.0001, taker: 0.0005, percentage: true, tier_based: true} =
             fees["BTC/USD:BTC"]

    assert fees["BTC/USD:BTC"].info == %{
             "instrument_type" => "perpetual",
             "maker_fee" => -0.0001,
             "taker_fee" => 0.0005
           }

    refute Map.has_key?(fees["BTC/USD:BTC"].info, "info")
    assert %Bourse.TradingFee{maker: maker, taker: 0.0003} = fees["BTC/USD:BTC-260626"]
    assert maker == 0.0
    refute Map.has_key?(fees, "ETH/USD:ETH")
  end

  test "fetch_trading_fees rejects Deribit's nested fee contract under carve C-T380a" do
    exchange =
      Exchange.put_markets(private_exchange(), [%Bourse.Market{base: "BTC", symbol: "BTC/USD:BTC", type: "swap"}])

    nested_fees = %{
      "btc_usd" => %{
        "future" => %{
          "default" => %{"type" => "relative", "maker" => -0.0001, "taker" => 0.0005}
        }
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:error, %Error{type: :exchange_error, exchange: "deribit", raw: ^nested_fees} = error} =
             Bourse.fetch_trading_fees(
               exchange,
               plug: {Req.Test, stub(requests, rpc_result(%{"currency" => "BTC", "fees" => nested_fees}))}
             )

    assert_request!(requests, "/api/v2/private/get_account_summary")
    assert error.message =~ "C-T380a"
    assert error.message =~ "observed fees key shape"
    assert error.message =~ "btc_usd"
    assert error.message =~ "future"
    assert Exception.message(error) =~ "[deribit]"
  end

  test "fetch_markets gives dated Deribit contracts unique symbols and expiry datetimes" do
    exchange = Exchange.new!("deribit")

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, markets} =
             Bourse.fetch_markets(
               exchange,
               plug: {Req.Test, stub(requests, rpc_result(deribit_market_rows()))}
             )

    assert_request!(requests, "/api/v2/public/get_instruments")

    symbols = Enum.map(markets, & &1.symbol)
    assert symbols == Enum.uniq(symbols)

    future = Enum.find(markets, &(&1.id == "BTC-16JUL26"))
    assert %Bourse.Market{} = future
    assert future.symbol == "BTC/USD:BTC-260716"
    assert future.future == true
    assert future.expiry == 1_784_188_800_000
    assert future.expiry_datetime == "2026-07-16T08:00:00.000Z"

    option = Enum.find(markets, &(&1.id == "BTC-16JUL26-56000-C"))
    assert %Bourse.Market{} = option
    assert option.symbol == "BTC/USD:BTC-260716-56000-C"
    assert option.expiry_datetime == "2026-07-16T08:00:00.000Z"

    linear_future = Enum.find(markets, &(&1.id == "BTC_USDC-22JUN26"))
    assert %Bourse.Market{} = linear_future
    assert linear_future.symbol == "BTC/USDC:USDC-260622"

    linear_swap = Enum.find(markets, &(&1.id == "1000BONK_USDC-PERPETUAL"))
    assert %Bourse.Market{} = linear_swap
    assert linear_swap.symbol == "1000BONK/USDC:USDC"

    linear_option = Enum.find(markets, &(&1.id == "AVAX_USDC-22JUN26-5d5-C"))
    assert %Bourse.Market{} = linear_option
    assert linear_option.symbol == "AVAX/USDC:USDC-260622-5.5-C"

    # Combo instruments keep their native ids (carve C27). The read path retains the
    # id *before* the symbol executor sees it; the public Symbol API also identity-
    # passthroughs under the task 305 contract (never the uppercased d-strike rewrite).
    for {id, unified_type} <- [
          {"BTC-FS-17JUL26_PERP", "future"},
          {"BTC-FS-31JUL26_17JUL26", "future"},
          {"BTC-REV-18JUL26-65000", "option"},
          {"DOGE_USDC-CS-28AUG26-0d1184_0d12", "option"}
        ] do
      market = Enum.find(markets, &(&1.id == id))
      assert %Bourse.Market{symbol: ^id, type: ^unified_type} = market
      assert Symbol.to_exchange_id(market.symbol, exchange) == id
      type = String.to_existing_atom(unified_type)
      assert Symbol.from_exchange_id(id, exchange, type) == id
    end
  end

  test "option positions use the payload kind to construct the unified symbol" do
    native_id = "BTC-31JUL26-65000-C"
    symbol = "BTC/USD:BTC-260731-65000-C"

    market = %Bourse.Market{
      id: native_id,
      symbol: symbol,
      option: true,
      quantity_unit: "base",
      native_quantity_unit: "base",
      native_amount_step: 0.1,
      precision: %{"amount" => 0.1},
      contract_size: 1
    }

    exchange = Exchange.put_markets(private_exchange(), [market])
    {:ok, requests} = RequestCollector.start_link()

    body =
      rpc_result([
        %{
          "average_price" => 0.023,
          "direction" => "buy",
          "instrument_name" => native_id,
          "kind" => "option",
          "size" => 0.1
        }
      ])

    assert {:ok, [%Bourse.Position{symbol: ^symbol, contracts: 0.1}]} =
             Bourse.fetch_positions(exchange, plug: {Req.Test, stub(requests, body)})

    assert_request!(requests, "/api/v2/private/get_positions")
  end

  test "authored Deribit future and option examples round-trip to their native ids" do
    exchange = Exchange.new!("deribit")

    examples =
      "priv/specs/json/output/authored/deribit.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["markets", "patterns"])
      |> Map.take(["future", "option"])
      |> Enum.flat_map(fn {market_type, pattern} ->
        Enum.map(pattern["examples"], &{market_type, &1})
      end)

    assert examples != []

    for {market_type, %{"id" => id, "symbol" => symbol}} <- examples do
      type = String.to_existing_atom(market_type)

      assert Symbol.from_exchange_id(id, exchange, type) == symbol
      assert Symbol.to_exchange_id(symbol, exchange) == id
    end
  end

  test "the future flag follows the resolved market type, not settlement_period" do
    exchange = Exchange.new!("deribit")

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, markets} =
             Bourse.fetch_markets(
               exchange,
               plug: {Req.Test, stub(requests, rpc_result(deribit_market_rows()))}
             )

    assert_request!(requests, "/api/v2/public/get_instruments")

    flag = fn id -> Enum.find(markets, &(&1.id == id)).future end

    # A day-settled dated future is still a future: the authored enum_map only enumerates
    # week/month and defaults to false, so keying the flag on settlement_period reports false here.
    assert flag.("BTC-17JUL26") == true
    assert flag.("BTC-16JUL26") == true

    # An option shares settlement_period with futures, so the same enum_map wrongly reported
    # future: true for it (3896 of 4564 live testnet options, 2026-07-16).
    assert flag.("BTC-16JUL26-56000-C") == false

    # A perpetual is a swap, never a future.
    assert flag.("BTC-PERPETUAL") == false
  end

  test "fetch_ticker on dated Deribit future dispatches the native instrument_name" do
    exchange = Exchange.new!("deribit")

    {:ok, requests} = RequestCollector.start_link()

    stub =
      stub(
        requests,
        rpc_result(%{
          "instrument_name" => "BTC-16JUL26",
          "last_price" => 64_100.5,
          "timestamp" => 1_784_204_793_040
        })
      )

    assert {:ok, %Bourse.Ticker{symbol: "BTC/USD:BTC-260716", last: 64_100.5}} =
             Bourse.fetch_ticker(exchange, "BTC/USD:BTC-260716", plug: {Req.Test, stub})

    conn = RequestCollector.one!(requests)
    assert conn.request_path == "/api/v2/public/ticker"
    assert URI.decode_query(conn.query_string)["instrument_name"] == "BTC-16JUL26"
  end

  test "fetch_option_chain is keyed by unified symbols" do
    exchange = Exchange.new!("deribit")

    option = %{
      "ask_price" => 0.182,
      "base_currency" => "BTC",
      "bid_price" => 0.1355,
      "instrument_name" => "BTC-16JUL26-56000-C",
      "mark_price" => 0.15548142,
      "open_interest" => 0.0,
      "quote_currency" => "BTC",
      "underlying_price" => 64_903.72
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %{"BTC/USD:BTC-260716-56000-C" => %Bourse.OptionData{} = parsed}} =
             Bourse.fetch_option_chain(
               exchange,
               "BTC",
               plug: {Req.Test, stub(requests, rpc_result([option]))}
             )

    assert_request!(requests, "/api/v2/public/get_book_summary_by_currency")

    assert parsed.symbol == "BTC/USD:BTC-260716-56000-C"
    refute Map.has_key?(parsed.info, "symbol")
  end

  test "fetch_tickers requires scope and returns a parsed symbol-keyed map" do
    exchange = Exchange.new!("deribit")

    assert {:error, %Error{type: :bad_request, message: message}} = Bourse.fetch_tickers(exchange)
    assert message =~ "symbols list or code"

    ticker = %{
      "best_ask_price" => 64_101.0,
      "best_bid_price" => 64_100.0,
      "instrument_name" => "BTC-PERPETUAL",
      "last_price" => 64_100.5,
      "timestamp" => 1_784_204_793_040
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %{"BTC/USD:BTC" => %Bourse.Ticker{} = parsed}} =
             Bourse.fetch_tickers(
               exchange,
               code: "BTC",
               plug: {Req.Test, stub(requests, rpc_result([ticker]))}
             )

    assert_request!(requests, "/api/v2/public/get_book_summary_by_currency")

    assert parsed.last == 64_100.5
  end

  test "fetch_tickers scoped by symbols keeps only the requested instruments" do
    perpetual = book_summary("BTC-PERPETUAL", 64_100.5)
    option = book_summary("BTC-10MAR26-7750-C", 0.021)

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, tickers} =
             Bourse.fetch_tickers(
               Exchange.new!("deribit"),
               symbols: ["BTC/USD:BTC"],
               plug: {Req.Test, stub(requests, rpc_result([perpetual, option]))}
             )

    assert_request!(requests, "/api/v2/public/get_book_summary_by_currency")

    assert Map.keys(tickers) == ["BTC/USD:BTC"]
  end

  test "fetch_tickers rejects a mixed-base symbols list instead of reading one base" do
    assert {:error, %Error{type: :bad_request, message: message}} =
             Bourse.fetch_tickers(Exchange.new!("deribit"), symbols: ["BTC/USD:BTC", "ETH/USD:ETH"])

    assert message =~ "must be the same for all symbols"
  end

  test "fetch_tickers rejects a code that contradicts the requested symbols" do
    assert {:error, %Error{type: :bad_request, message: message}} =
             Bourse.fetch_tickers(Exchange.new!("deribit"), code: "ETH", symbols: ["BTC/USD:BTC"])

    assert message =~ "must be the same for all symbols"
  end

  # Task 281 — private/buy|edit nest the order under result.order; cancel puts the
  # order row under result. Without those envelopes, field-map parse yields id: nil
  # (or empty-parse after task 256) and create→cancel is unusable programmatically.
  test "createOrder unwraps result.order into a populated Order" do
    order = deribit_order_row("107869080813", "open", 10_000.0)
    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.Order{} = parsed} =
             Unified.call(
               private_exchange(),
               :create_order,
               "createOrder",
               %{
                 "symbol" => "BTC/USD:BTC",
                 "type" => "limit",
                 "side" => "buy",
                 "amount" => 10,
                 "price" => 10_000
               },
               plug: {Req.Test, stub(requests, rpc_result(%{"order" => order, "trades" => []}))}
             )

    assert_request!(requests, "/api/v2/private/buy")

    assert parsed.id == "107869080813"
    assert parsed.status == "open"
    assert parsed.price == 10_000.0
    assert parsed.amount == 10
    assert parsed.side == "buy"
    assert parsed.type == "limit"
    assert parsed.symbol == "BTC/USD:BTC"
    assert parsed.info["order_id"] == "107869080813"
    refute Map.has_key?(parsed.info, "trades")
  end

  test "order and trade field maps round-trip Deribit's label as client_order_id" do
    order = Map.put(deribit_order_row("107869080813", "open", 10_000.0), "label", "t622-order")
    trade = Map.put(deribit_trade_row(), "label", "t622-order")

    assert {:ok, %Bourse.Order{client_order_id: "t622-order"}} = Bourse.Deribit.parse_order(order)

    assert {:ok, %Bourse.Trade{client_order_id: "t622-order", order_id: "order-1"}} =
             Bourse.Deribit.parse_trade(trade)
  end

  test "createOrder request shape maps unified clientOrderId onto native label" do
    exchange = private_exchange()

    assert {:ok, [shaped]} =
             Unified.request_param_shapes(exchange, :create_order, %{
               "amount" => 10,
               "clientOrderId" => "t622-shape",
               "side" => "buy",
               "symbol" => "BTC/USD:BTC",
               "type" => "market"
             })

    assert shaped["label"] == "t622-shape"
    assert shaped["instrument_name"] == "BTC-PERPETUAL"
    refute Map.has_key?(shaped, "clientOrderId")
  end

  test "editOrder unwraps result.order id/status/price/amount" do
    order = deribit_order_row("107869080813", "open", 11_000.0)
    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.Order{} = parsed} =
             Unified.call(
               private_exchange(),
               :edit_order,
               "editOrder",
               %{
                 "id" => "107869080813",
                 "symbol" => "BTC/USD:BTC",
                 "type" => "limit",
                 "side" => "buy",
                 "amount" => 10,
                 "price" => 11_000
               },
               plug: {Req.Test, stub(requests, rpc_result(%{"order" => order, "trades" => []}))}
             )

    assert_request!(requests, "/api/v2/private/edit")

    assert parsed.id == "107869080813"
    assert parsed.status == "open"
    assert parsed.price == 11_000.0
    assert parsed.amount == 10
  end

  test "cancelOrder unwraps result into a populated Order" do
    order = deribit_order_row("107869080813", "cancelled", 10_000.0)
    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.Order{} = parsed} =
             Unified.call(
               private_exchange(),
               :cancel_order,
               "cancelOrder",
               %{"id" => "107869080813", "symbol" => "BTC/USD:BTC"},
               plug: {Req.Test, stub(requests, rpc_result(order))}
             )

    assert_request!(requests, "/api/v2/private/cancel")

    assert parsed.id == "107869080813"
    assert parsed.status == "canceled"
    assert parsed.price == 10_000.0
    assert parsed.amount == 10
  end

  test "order status covers every provider-documented state with deliberate terminal semantics" do
    expected = %{
      "open" => "open",
      "untriggered" => "open",
      "triggered" => "open",
      "speed_bumped" => "open",
      "filled" => "closed",
      "cancelled" => "canceled",
      "rejected" => "rejected"
    }

    rule =
      "deribit"
      |> Bourse.Spec.load!()
      |> get_in(["normalization", "field_maps", "order", "field_map", "status"])

    assert rule["enum_map"] == expected

    for {provider_state, unified_state} <- expected do
      assert {:ok, %Bourse.Order{status: ^unified_state}} =
               Bourse.Deribit.parse_order(deribit_order_row("state-#{provider_state}", provider_state, 10_000.0))
    end
  end

  defp deribit_order_row(order_id, order_state, price) do
    %{
      "amount" => 10,
      "average_price" => 0,
      "creation_timestamp" => 1_784_200_000_000,
      "direction" => "buy",
      "filled_amount" => 0,
      "instrument_name" => "BTC-PERPETUAL",
      "last_update_timestamp" => 1_784_200_000_000,
      "order_id" => order_id,
      "order_state" => order_state,
      "order_type" => "limit",
      "original_order_type" => "limit",
      "post_only" => false,
      "price" => price,
      "time_in_force" => "good_til_cancelled"
    }
  end

  defp deribit_trade_row do
    %{
      "amount" => 10,
      "direction" => "buy",
      "instrument_name" => "BTC-PERPETUAL",
      "order_id" => "order-1",
      "order_type" => "limit",
      "price" => 50_000,
      "timestamp" => 1_784_204_793_040,
      "trade_id" => "trade-1"
    }
  end

  defp book_summary(instrument_name, last_price) do
    %{
      "best_ask_price" => last_price + 1.0,
      "best_bid_price" => last_price - 1.0,
      "instrument_name" => instrument_name,
      "last_price" => last_price,
      "timestamp" => 1_784_204_793_040
    }
  end

  defp deribit_market_rows do
    expiry = 1_784_188_800_000

    [
      %{
        "base_currency" => "BTC",
        "contract_size" => 10.0,
        "expiration_timestamp" => nil,
        "instrument_name" => "BTC-PERPETUAL",
        "instrument_type" => "reversed",
        "is_active" => true,
        "kind" => "future",
        "quote_currency" => "USD",
        "settlement_period" => "perpetual"
      },
      %{
        "base_currency" => "BTC",
        "contract_size" => 10.0,
        "expiration_timestamp" => expiry,
        "instrument_name" => "BTC-16JUL26",
        "instrument_type" => "reversed",
        "is_active" => true,
        "kind" => "future",
        "quote_currency" => "USD",
        "settlement_period" => "week"
      },
      # settlement_period "day" is a real Deribit value (23 of 74 live dated futures on testnet,
      # 2026-07-16) that the authored `future` enum_map does not enumerate. Keep a day-period row
      # here so the flag is exercised against the venue's full period enum, not just week/month.
      %{
        "base_currency" => "BTC",
        "contract_size" => 10.0,
        "expiration_timestamp" => expiry,
        "instrument_name" => "BTC-17JUL26",
        "instrument_type" => "reversed",
        "is_active" => true,
        "kind" => "future",
        "quote_currency" => "USD",
        "settlement_period" => "day"
      },
      %{
        "base_currency" => "BTC",
        "contract_size" => 1.0,
        "expiration_timestamp" => 1_782_112_800_000,
        "instrument_name" => "BTC_USDC-22JUN26",
        "instrument_type" => "linear",
        "is_active" => true,
        "kind" => "future",
        "quote_currency" => "USDC",
        "settlement_period" => "month"
      },
      %{
        "base_currency" => "1000BONK",
        "contract_size" => 1.0,
        "expiration_timestamp" => nil,
        "instrument_name" => "1000BONK_USDC-PERPETUAL",
        "instrument_type" => "linear",
        "is_active" => true,
        "kind" => "future",
        "quote_currency" => "USDC",
        "settlement_currency" => "USDC",
        "settlement_period" => "perpetual"
      },
      %{
        "base_currency" => "BTC",
        "contract_size" => 1.0,
        "expiration_timestamp" => expiry,
        "instrument_name" => "BTC-16JUL26-56000-C",
        "instrument_type" => "reversed",
        "is_active" => true,
        "kind" => "option",
        "option_type" => "call",
        "quote_currency" => "BTC",
        "settlement_period" => "week",
        "strike" => 56_000.0
      },
      %{
        "base_currency" => "AVAX",
        "contract_size" => 1.0,
        "expiration_timestamp" => 1_782_112_800_000,
        "instrument_name" => "AVAX_USDC-22JUN26-5d5-C",
        "instrument_type" => "linear",
        "is_active" => true,
        "kind" => "option",
        "option_type" => "call",
        "quote_currency" => "USDC",
        "settlement_period" => "month",
        "strike" => 5.5
      },
      %{
        "base_currency" => "BTC",
        "contract_size" => 10.0,
        "expiration_timestamp" => expiry,
        "instrument_name" => "BTC-FS-17JUL26_PERP",
        "instrument_type" => "reversed",
        "is_active" => true,
        "kind" => "future_combo",
        "quote_currency" => "USD",
        "settlement_currency" => "BTC",
        "settlement_period" => "week"
      },
      %{
        "base_currency" => "BTC",
        "contract_size" => 10.0,
        "expiration_timestamp" => expiry,
        "instrument_name" => "BTC-FS-31JUL26_17JUL26",
        "instrument_type" => "reversed",
        "is_active" => true,
        "kind" => "future_combo",
        "quote_currency" => "USD",
        "settlement_currency" => "BTC",
        "settlement_period" => "week"
      },
      %{
        "base_currency" => "BTC",
        "contract_size" => 1.0,
        "expiration_timestamp" => expiry,
        "instrument_name" => "BTC-REV-18JUL26-65000",
        "instrument_type" => "reversed",
        "is_active" => true,
        "kind" => "option_combo",
        "quote_currency" => "BTC",
        "settlement_currency" => "BTC",
        "settlement_period" => "day"
      },
      # A linear USDC option combo whose `d`-encoded strikes the option grammar would
      # rewrite to "0D1184_0D12" if combo ids were routed through the symbol executor.
      %{
        "base_currency" => "DOGE",
        "contract_size" => 100,
        "expiration_timestamp" => 1_787_904_000_000,
        "instrument_name" => "DOGE_USDC-CS-28AUG26-0d1184_0d12",
        "instrument_type" => "linear",
        "is_active" => true,
        "kind" => "option_combo",
        "quote_currency" => "USDC",
        "settlement_currency" => "USDC",
        "settlement_period" => "month"
      }
    ]
  end

  defp private_exchange do
    Exchange.new!("deribit", api_key: "test-key", secret: "test-secret")
  end

  defp transaction_rows(row), do: rpc_result(%{"data" => [row]})
  defp rpc_result(result), do: %{"jsonrpc" => "2.0", "result" => result}

  # The stub only records the request; every request-shape assertion runs in the
  # test process via `assert_request!/2` after the call under test returns.
  defp stub(collector, body) do
    name = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(name, fn conn ->
      conn = RequestCollector.capture(collector, conn)
      Req.Test.json(conn, body)
    end)

    name
  end

  defp assert_request!(collector, path) do
    assert RequestCollector.one!(collector).request_path == path
  end
end
