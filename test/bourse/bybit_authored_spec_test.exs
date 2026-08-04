defmodule Bourse.BybitAuthoredSpecTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified
  alias Bourse.Unified.RequestShape

  @maintenance_end_ms 1_785_000_000_000

  test "authored selection uses wallet balance and ordinary kline endpoints" do
    exchange = Exchange.new!("bybit")

    assert exchange.endpoint_selection["fetchBalance"]["default"] == "v5/account/wallet-balance"
    assert exchange.endpoint_selection["fetchOHLCV"]["default"] == "v5/market/kline"
    assert exchange.request_defaults["fetchBalance"]["accountType"] == "UNIFIED"
  end

  test "unified wallet balance branches free and used per coin" do
    body = %{
      "retCode" => 0,
      "time" => "1736866023302",
      "result" => %{
        "list" => [
          %{
            "coin" => [
              %{
                "coin" => "USDT",
                "walletBalance" => "12.5",
                "availableToWithdraw" => "",
                "borrowAmount" => "0",
                "totalPositionIM" => "1.5",
                "totalOrderIM" => "1",
                "locked" => "2.5",
                "bonus" => "0"
              },
              %{
                "coin" => "USDC",
                "walletBalance" => "12.5",
                "availableToWithdraw" => "10",
                "locked" => "9",
                "totalPositionIM" => "8",
                "totalOrderIM" => "7"
              }
            ]
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, balance} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_balance,
               "fetchBalance",
               %{},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/account/wallet-balance", %{"accountType" => "UNIFIED"})

    assert balance.total == %{"USDT" => 12.5, "USDC" => 12.5}
    assert balance.free == %{"USDT" => 7.5, "USDC" => 10.0}
    assert balance.used == %{"USDT" => 5.0, "USDC" => 2.5}
    assert balance.debt == %{"USDT" => 0.0}
    assert balance.timestamp == 1_736_866_023_302
  end

  test "ticker fields use numeric venue semantics" do
    raw = %{
      "ask1Price" => "51444.40",
      "ask1Size" => "491.691",
      "bid1Price" => "51444.30",
      "bid1Size" => "55.841",
      "lastPrice" => "51444.40",
      "prevPrice24h" => "50147.50",
      "price24hPcnt" => "0.025861",
      "turnover24h" => "2352063794.0035",
      "volume24h" => "47293.8870"
    }

    assert {:ok, ticker} = Bourse.Bybit.parse_ticker(raw)
    assert ticker.ask == 51_444.4
    assert ticker.ask_volume == 491.691
    assert ticker.bid == 51_444.3
    assert ticker.bid_volume == 55.841
    assert ticker.average == 50_795.9
    assert ticker.change == 1_296.9
    assert ticker.percentage == 2.5861
    assert_in_delta ticker.vwap, 49_732.93470260755, 1.0e-10
  end

  test "fetch_ticker keeps linear vwap and omits inverse and option vwap (C36)" do
    linear = %{
      "retCode" => 0,
      "result" => %{
        "category" => "linear",
        "list" => [
          %{
            "symbol" => "BTCUSDT",
            "lastPrice" => "63473.40",
            "turnover24h" => "3598869742.8282",
            "volume24h" => "56045.9340"
          }
        ]
      }
    }

    inverse = %{
      "retCode" => 0,
      "result" => %{
        "category" => "inverse",
        "list" => [
          %{"symbol" => "BTCUSD", "lastPrice" => "63409.00", "turnover24h" => "3506.4956", "volume24h" => "224851247.0"}
        ]
      }
    }

    {:ok, linear_requests} = RequestCollector.start_link()

    assert {:ok, linear_ticker} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_ticker,
               "fetchTicker",
               %{"symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, stub(linear_requests, linear)}
             )

    assert_request!(linear_requests, "/v5/market/tickers", %{"category" => "linear", "symbol" => "BTCUSDT"})

    assert_in_delta linear_ticker.vwap, 64_212.86, 0.01
    assert_in_delta linear_ticker.vwap, linear_ticker.last, linear_ticker.last * 0.02

    {:ok, inverse_requests} = RequestCollector.start_link()

    assert {:ok, inverse_ticker} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_ticker,
               "fetchTicker",
               %{"symbol" => "BTC/USD:BTC"},
               plug: {Req.Test, stub(inverse_requests, inverse)}
             )

    assert_request!(inverse_requests, "/v5/market/tickers", %{"category" => "inverse", "symbol" => "BTCUSD"})

    assert inverse_ticker.last == 63_409.0
    assert is_nil(inverse_ticker.vwap)

    option = %{
      "retCode" => 0,
      "result" => %{
        "category" => "option",
        "list" => [
          %{
            "symbol" => "BTC-17JUL26-64000-C-USDT",
            "lastPrice" => "5",
            "turnover24h" => "18825758.541",
            "volume24h" => "294.69"
          }
        ]
      }
    }

    {:ok, option_requests} = RequestCollector.start_link()

    assert {:ok, option_ticker} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_ticker,
               "fetchTicker",
               %{"category" => "option", "symbol" => "BTC-17JUL26-64000-C-USDT"},
               plug: {Req.Test, stub(option_requests, option)}
             )

    assert_request!(option_requests, "/v5/market/tickers", %{
      "category" => "option",
      "symbol" => "BTC-17JUL26-64000-C-USDT"
    })

    assert option_ticker.last == 5.0
    assert is_nil(option_ticker.vwap)
  end

  # fetch_tickers carries no `symbol` param, so the parse context has no market
  # flags to discriminate on. The carve leans on the envelope `result.category`
  # that every Bybit read already annotates onto its rows.
  test "fetch_tickers keeps linear vwap and omits inverse and option vwap without a symbol context (C36)" do
    linear = %{
      "retCode" => 0,
      "result" => %{
        "category" => "linear",
        "list" => [
          %{
            "symbol" => "BTCUSDT",
            "lastPrice" => "63473.40",
            "turnover24h" => "3598869742.8282",
            "volume24h" => "56045.9340"
          }
        ]
      }
    }

    inverse = %{
      "retCode" => 0,
      "result" => %{
        "category" => "inverse",
        "list" => [
          %{"symbol" => "BTCUSD", "lastPrice" => "63409.00", "turnover24h" => "3506.4956", "volume24h" => "224851247.0"}
        ]
      }
    }

    {:ok, linear_requests} = RequestCollector.start_link()

    assert {:ok, linear_tickers} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_tickers,
               "fetchTickers",
               %{"category" => "linear"},
               plug: {Req.Test, stub(linear_requests, linear)}
             )

    assert_request!(linear_requests, "/v5/market/tickers")

    linear_ticker = single_ticker(linear_tickers)
    assert_in_delta linear_ticker.vwap, 64_212.86, 0.01
    assert_in_delta linear_ticker.vwap, linear_ticker.last, linear_ticker.last * 0.02

    {:ok, inverse_requests} = RequestCollector.start_link()

    assert {:ok, inverse_tickers} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_tickers,
               "fetchTickers",
               %{"category" => "inverse"},
               plug: {Req.Test, stub(inverse_requests, inverse)}
             )

    assert_request!(inverse_requests, "/v5/market/tickers")

    inverse_ticker = single_ticker(inverse_tickers)
    assert inverse_ticker.last == 63_409.0
    assert is_nil(inverse_ticker.vwap)

    option = %{
      "retCode" => 0,
      "result" => %{
        "category" => "option",
        "list" => [
          %{
            "symbol" => "BTC-17JUL26-64000-C-USDT",
            "lastPrice" => "5",
            "turnover24h" => "18825758.541",
            "volume24h" => "294.69"
          }
        ]
      }
    }

    {:ok, option_requests} = RequestCollector.start_link()

    assert {:ok, option_tickers} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_tickers,
               "fetchTickers",
               %{"category" => "option"},
               plug: {Req.Test, stub(option_requests, option)}
             )

    assert_request!(option_requests, "/v5/market/tickers")

    option_ticker = single_ticker(option_tickers)
    assert option_ticker.last == 5.0
    assert is_nil(option_ticker.vwap)
  end

  defp single_ticker(%{} = tickers) when not is_struct(tickers) do
    assert [ticker] = Map.values(tickers)
    ticker
  end

  defp single_ticker(tickers) do
    assert [ticker] = List.wrap(tickers)
    ticker
  end

  test "unified OHLCV returns Bybit reverse-ordered candles oldest first" do
    body = %{
      "retCode" => 0,
      "result" => %{
        "list" => [
          ["1706637600000", "3", "4", "2", "3.5", "30", "105"],
          ["1706634000000", "2", "3", "1", "2.5", "20", "50"]
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, candles} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_ohlcv,
               "fetchOHLCV",
               %{"symbol" => "BTC/USDT:USDT", "timeframe" => "1h"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/market/kline")

    assert candles == [
             [1_706_634_000_000, 2.0, 3.0, 1.0, 2.5, 20.0],
             [1_706_637_600_000, 3.0, 4.0, 2.0, 3.5, 30.0]
           ]
  end

  test "market category fan-out authors Bybit market flags" do
    map = Bourse.Bybit.__field_maps__()["market"]["field_map"]

    assert {:ok, %Bourse.Market{type: "swap", swap: true, linear: true, inverse: false}} =
             Bourse.ResponseParser.apply_mappings(
               %{"category" => "linear", "contractType" => "LinearPerpetual"},
               map,
               target: Bourse.Market
             )

    assert {:ok, %Bourse.Market{type: "future", future: true, inverse: true, swap: false}} =
             Bourse.ResponseParser.apply_mappings(
               %{"category" => "inverse", "contractType" => "InverseFutures"},
               map,
               target: Bourse.Market
             )
  end

  test "leverage margin_mode reads tradeMode and never fabricates cross (carve C26)" do
    map = Bourse.Bybit.__field_maps__()["leverage"]["field_map"]

    # Real UTA demo row shape (2026-07-17): tradeMode is deprecated/always 0 and
    # the row carries no marginMode key — 0 must stay nil, not become "cross".
    assert {:ok, %Bourse.Leverage{margin_mode: nil}} =
             Bourse.ResponseParser.apply_mappings(
               %{"symbol" => "BTCUSDT", "leverage" => "10", "tradeMode" => 0},
               map,
               target: Bourse.Leverage
             )

    # Legacy rows that genuinely say tradeMode 1 mean isolated per Bybit v5 docs.
    assert {:ok, %Bourse.Leverage{margin_mode: "isolated"}} =
             Bourse.ResponseParser.apply_mappings(
               %{"symbol" => "BTCUSDT", "leverage" => "10", "tradeMode" => 1},
               map,
               target: Bourse.Leverage
             )

    assert map["marginMode"]["key"] == "tradeMode"
    assert map["marginMode"]["enum_map"] == %{"1" => "isolated"}
  end

  test "read collections unwrap Bybit v5 result lists" do
    envelopes = Bourse.Bybit.__response_envelopes__()

    for {slot, method} <- [
          {"order", "fetchOpenOrders"},
          {"position", "fetchPositions"},
          {"trade", "fetchMyTrades"}
        ] do
      assert %{^method => %{"key" => "result.list", "default" => []}} = envelopes[slot]
    end
  end

  test "order field map distinguishes full reads from sparse acknowledgements" do
    map = Bourse.Bybit.__field_maps__()["order"]["field_map"]

    raw = %{
      "avgPrice" => "100.5",
      "createdTime" => "1",
      "cumExecQty" => "0.5",
      "cumExecValue" => "50.25",
      "cumFeeDetail" => %{"USDT" => "0.01"},
      "leavesQty" => "0.5",
      "orderId" => "order-1",
      "orderStatus" => "PartiallyFilled",
      "price" => "101",
      "qty" => "1",
      "timeInForce" => "PostOnly"
    }

    assert {:ok, %Bourse.Order{} = order} = Bourse.ResponseParser.apply_mappings(raw, map, target: Bourse.Order)
    assert order.amount == 1.0
    assert order.average == 100.5
    assert order.cost == 50.25
    assert order.filled == 0.5
    assert order.remaining == 0.5
    assert order.price == 101.0
    assert order.status == "open"
    assert order.time_in_force == "PO"
    assert order.post_only
    assert order.fee == %{"cost" => 0.01, "currency" => "USDT"}

    assert {:ok, %Bourse.Order{id: "order-2", amount: nil, status: nil, fee: nil}} =
             Bourse.ResponseParser.apply_mappings(%{"orderId" => "order-2"}, map, target: Bourse.Order)
  end

  test "fetch_open_orders request symbol wins over ambiguous native order id before filtering" do
    body = %{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "list" => [
          %{
            "createdTime" => "1784191497000",
            "leavesQty" => "0.01",
            "orderId" => "spot-order-1",
            "orderStatus" => "New",
            "orderType" => "Limit",
            "price" => "65000",
            "qty" => "0.01",
            "side" => "Buy",
            "symbol" => "BTCUSDT",
            "timeInForce" => "GTC"
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, [%Bourse.Order{} = order]} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_open_orders,
               "fetchOpenOrders",
               %{"symbol" => "BTC/USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/order/realtime")

    assert order.symbol == "BTC/USDT"
    assert order.id == "spot-order-1"
    assert order.status == "open"
  end

  test "a successful empty single-order response is order_not_found" do
    body = %{"retCode" => 0, "retMsg" => "OK", "result" => %{"category" => "linear", "list" => []}}

    {:ok, requests} = RequestCollector.start_link()

    assert {:error, %Bourse.Error{type: :order_not_found}} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_open_order,
               "fetchOpenOrder",
               %{"id" => "missing", "symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/order/realtime")
  end

  # Task 235 — account/analytics response slices
  test "fetch_margin_mode maps REGULAR_MARGIN to cross with request symbol" do
    body = %{
      "retCode" => "0",
      "retMsg" => "OK",
      "result" => %{
        "marginMode" => "REGULAR_MARGIN",
        "updatedTime" => "1723481446000",
        "unifiedMarginStatus" => "5"
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.MarginMode{symbol: "BTC/USDT", margin_mode: "cross"} = mode} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_margin_mode,
               "fetchMarginMode",
               %{"symbol" => "BTC/USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/account/info")

    assert mode.info["marginMode"] == "REGULAR_MARGIN"
  end

  test "borrow_cross_margin returns %MarginLoan{} with string amount" do
    body = %{
      "retCode" => "0",
      "retMsg" => "success",
      "result" => %{"coin" => "BTC", "amount" => "0.001"},
      "time" => "1763194940073"
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.MarginLoan{currency: "BTC", amount: "0.001", id: nil}} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :borrow_cross_margin,
               "borrowCrossMargin",
               %{"code" => "BTC", "amount" => 0.001},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/account/borrow")
  end

  test "repay_cross_margin backfills request amount onto sparse ack" do
    body = %{
      "retCode" => "0",
      "retMsg" => "success",
      "result" => %{"resultStatus" => "SU"},
      "time" => "1763195201119"
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.MarginLoan{currency: "BTC", amount: 0.001, info: %{"resultStatus" => "SU"}}} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :repay_cross_margin,
               "repayCrossMargin",
               %{"code" => "BTC", "amount" => 0.001},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/account/no-convert-repay")
  end

  test "fetch_cross_borrow_rate selects collateral info and parses its hourly rate" do
    body = %{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "list" => [
          %{
            "currency" => "USDT",
            "hourlyBorrowRate" => "0.00000147",
            "maxBorrowingAmount" => "3"
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.BorrowRate{currency: "USDT", rate: rate, period: 3_600_000}} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_cross_borrow_rate,
               "fetchCrossBorrowRate",
               %{"code" => "USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/account/collateral-info", %{"currency" => "USDT"})

    assert_in_delta rate, 1.47e-6, 1.0e-12
  end

  test "fetch_borrow_rate_history sorts hourly rows and drops pre-since" do
    body = %{
      "retCode" => "0",
      "retMsg" => "OK",
      "result" => %{
        "list" => [
          %{
            "timestamp" => "1729245600000",
            "currency" => "USDT",
            "hourlyBorrowRate" => "0.000003433654",
            "vipLevel" => "No VIP"
          },
          %{
            "timestamp" => "1729242000000",
            "currency" => "USDT",
            "hourlyBorrowRate" => "0.000003238239",
            "vipLevel" => "No VIP"
          },
          %{
            "timestamp" => "1729238400000",
            "currency" => "USDT",
            "hourlyBorrowRate" => "0.000003140500",
            "vipLevel" => "No VIP"
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, rows} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_borrow_rate_history,
               "fetchBorrowRateHistory",
               %{"code" => "USDT", "since" => 1_729_241_283_000},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/spot-margin-trade/interest-rate-history")

    assert length(rows) == 2
    assert Enum.map(rows, & &1.timestamp) == [1_729_242_000_000, 1_729_245_600_000]
    assert Enum.all?(rows, &(&1.period == 3_600_000 and &1.currency == "USDT"))
    assert_in_delta hd(rows).rate, 3.238239e-6, 1.0e-12
  end

  test "fetch_all_greeks indexes option rows by unified symbol" do
    body = %{
      "retCode" => "0",
      "retMsg" => "SUCCESS",
      "result" => %{
        "category" => "option",
        "list" => [
          %{
            "symbol" => "BTC-30MAY25-70000-C-USDT",
            "bid1Price" => "0",
            "bid1Size" => "0",
            "bid1Iv" => "0",
            "ask1Price" => "0",
            "ask1Size" => "0",
            "ask1Iv" => "0",
            "lastPrice" => "0",
            "markPrice" => "7037.25257463",
            "markIv" => "0.5252",
            "underlyingPrice" => "107998.45",
            "delta" => "0.46906374",
            "gamma" => "0.00001814",
            "vega" => "166.09011572",
            "theta" => "-79.92724861"
          }
        ]
      }
    }

    symbol = "BTC/USDT:USDT-250530-70000-C"

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %{^symbol => %Bourse.Greeks{} = greeks}} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_all_greeks,
               "fetchAllGreeks",
               %{"symbols" => [symbol], "baseCoin" => "BTC"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/market/tickers")

    assert greeks.symbol == symbol
    assert_in_delta greeks.delta, 0.46906374, 1.0e-12
    assert_in_delta greeks.mark_implied_volatility, 0.5252, 1.0e-12
  end

  test "fetch_all_greeks keeps native option symbols per row instead of stamping the request symbol" do
    body = %{
      "retCode" => "0",
      "retMsg" => "SUCCESS",
      "result" => %{
        "category" => "option",
        "list" => [
          %{"symbol" => "BTC-30MAY25-70000-C-USDT", "delta" => "0.46906374", "markIv" => "0.5252"},
          %{"symbol" => "BTC-30MAY25-80000-C-USDT", "delta" => "0.12345678", "markIv" => "0.4111"}
        ]
      }
    }

    requested = "BTC/USDT:USDT-250530-70000-C"

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, indexed} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_all_greeks,
               "fetchAllGreeks",
               %{"symbol" => requested, "baseCoin" => "BTC"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/market/tickers")

    # A singular request symbol must not overwrite every row's native option id:
    # doing so would pass the whole chain through the symbol filter and collapse
    # it onto one key, silently serving the wrong strike's greeks.
    assert Map.keys(indexed) == [requested]
    assert_in_delta indexed[requested].delta, 0.46906374, 1.0e-12
  end

  # Task 306 residuals — offline pins for request-build + parse wiring.

  test "fetch_market_leverage_tiers injects category and parses risk-limit rows" do
    body = %{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "category" => "linear",
        "list" => [
          %{
            "id" => 1,
            "symbol" => "BTCUSDT",
            "riskLimitValue" => "2000000",
            "maintenanceMargin" => "0.005",
            "initialMargin" => "0.01",
            "maxLeverage" => "100.00"
          },
          %{
            "id" => 2,
            "symbol" => "BTCUSDT",
            "riskLimitValue" => "4000000",
            "maintenanceMargin" => "0.01",
            "maxLeverage" => "50.00"
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, [%Bourse.LeverageTier{} = tier | _] = tiers} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_market_leverage_tiers,
               "fetchMarketLeverageTiers",
               %{"symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/market/risk-limit", %{"category" => "linear", "symbol" => "BTCUSDT"})

    assert length(tiers) == 2
    assert tier.symbol == "BTC/USDT:USDT"
    assert tier.tier == 1
    assert tier.max_leverage == 100.0
    assert tier.max_notional == 2_000_000.0
    assert_in_delta tier.maintenance_margin_rate, 0.005, 1.0e-12
  end

  test "fetch_order_classic routes to order history and order_not_found on empty list" do
    body = %{"retCode" => 0, "retMsg" => "OK", "result" => %{"category" => "linear", "list" => []}}

    {:ok, requests} = RequestCollector.start_link()

    assert {:error, %Bourse.Error{type: :order_not_found}} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_order_classic,
               "fetchOrderClassic",
               %{"id" => "missing", "symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/order/history")
  end

  test "fetch_order_classic endpoint_selection prefers order history over account info" do
    exchange = Exchange.new!("bybit")
    assert exchange.endpoint_selection["fetchOrderClassic"]["default"] == "v5/order/history"

    configs = Bourse.Bybit.__unified_endpoint__(:fetch_order_classic)
    selected = Enum.find(configs, &(&1.path == "v5/order/history"))
    assert selected
  end

  test "fetch_long_short_ratio_history parses buy/sell ratio series" do
    body = %{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "list" => [
          %{
            "symbol" => "BTCUSDT",
            "buyRatio" => "0.6828",
            "sellRatio" => "0.3172",
            "timestamp" => "1784246400000"
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, [%Bourse.LongShortRatio{} = row]} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_long_short_ratio_history,
               "fetchLongShortRatioHistory",
               %{"symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/market/account-ratio")

    assert row.symbol == "BTC/USDT:USDT"
    assert row.timestamp == 1_784_246_400_000
    assert_in_delta row.long_short_ratio, 0.6828 / 0.3172, 1.0e-9
    assert row.timeframe == "1d"
  end

  test "fetch_my_liquidations returns normalized Liquidation list, never raw HTTP envelope" do
    body = %{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "category" => "linear",
        "list" => [
          %{
            "symbol" => "ETHUSDT",
            "side" => "Buy",
            "execPrice" => "1183.54",
            "execQty" => "0.1",
            "execValue" => "118.354",
            "execTime" => "1672282722429",
            "orderId" => "liq-1"
          }
        ],
        "nextPageCursor" => ""
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, [%Bourse.Liquidation{} = liq]} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_my_liquidations,
               "fetchMyLiquidations",
               %{"symbol" => "ETH/USDT:USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/execution/list")

    assert liq.symbol == "ETH/USDT:USDT"
    assert liq.side == "buy"
    assert liq.price == 1183.54
    assert liq.contracts == 0.1
    assert liq.timestamp == 1_672_282_722_429
  end

  test "edit_orders surfaces per-item rejection code and message from retExtInfo" do
    body = %{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "list" => [
          %{
            "category" => "linear",
            "symbol" => "BTCUSDT",
            "orderId" => "missing-order",
            "orderLinkId" => ""
          }
        ]
      },
      "retExtInfo" => %{
        "list" => [%{"code" => 110_001, "msg" => "order not exists or too late to replace"}]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    exchange =
      "bybit"
      |> Exchange.new!(api_key: "test-key", secret: "test-secret")
      |> Exchange.put_markets([
        %Bourse.Market{
          id: "BTCUSDT",
          symbol: "BTC/USDT:USDT",
          linear: true,
          precision: %{"amount" => 0.001, "price" => 0.1}
        }
      ])

    assert {:ok, [%Bourse.Order{} = order]} =
             Unified.call(
               exchange,
               :edit_orders,
               "editOrders",
               %{
                 "orders" => [
                   %{
                     "id" => "missing-order",
                     "symbol" => "BTC/USDT:USDT",
                     "type" => "limit",
                     "side" => "buy",
                     "amount" => 0.01,
                     "price" => 10_000
                   }
                 ]
               },
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/order/amend-batch")

    assert order.status == "rejected"
    assert order.info["code"] == 110_001
    assert order.info["msg"] =~ "order not exists"
  end

  test "fetch_position stamps contract_size 1 for linear perps" do
    body = %{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "category" => "linear",
        "list" => [
          %{
            "symbol" => "BTCUSDT",
            "side" => "Buy",
            "size" => "0.1",
            "avgPrice" => "50000",
            "positionValue" => "5000",
            "leverage" => "10",
            "positionIM" => "500",
            "positionMM" => "50",
            "unrealisedPnl" => "50",
            "markPrice" => "50100",
            "positionIdx" => 0,
            "updatedTime" => "1672279322668",
            "createdTime" => "1672121182216"
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.Position{} = position} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_position,
               "fetchPosition",
               %{"symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/position/list")

    assert position.symbol == "BTC/USDT:USDT"
    assert position.contract_size == 1.0
    assert position.contracts == 0.1
    assert position.percentage == 10.0
  end

  test "fetch_position leaves percentage nil when zero PNL is omitted by the authored carve" do
    body = %{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "category" => "inverse",
        "list" => [
          %{
            "symbol" => "BTCUSD",
            "side" => "Buy",
            "size" => "1",
            "positionIM" => "0.00000011",
            "unrealisedPnl" => "0"
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()

    assert {:ok, %Bourse.Position{unrealized_pnl: nil, percentage: nil}} =
             Unified.call(
               Exchange.new!("bybit", api_key: "test-key", secret: "test-secret"),
               :fetch_position,
               "fetchPosition",
               %{"symbol" => "BTC/USD:BTC"},
               plug: {Req.Test, stub(requests, body)}
             )

    assert_request!(requests, "/v5/position/list")
  end

  test "fetch_status uses the provider system endpoint and maps ongoing maintenance" do
    body = %{
      "retCode" => 0,
      "result" => %{
        "list" => [
          %{
            "state" => "ongoing",
            "end" => Integer.to_string(@maintenance_end_ms),
            "href" => "https://status.bybit.com/event"
          }
        ]
      }
    }

    {:ok, requests} = RequestCollector.start_link()
    exchange = Exchange.new!("bybit")

    assert Exchange.has?(exchange, "fetchStatus")

    assert {:ok,
            %{
              status: "maintenance",
              updated: nil,
              eta: @maintenance_end_ms,
              url: "https://status.bybit.com/event",
              info: ^body
            }} = Bourse.fetch_status(exchange, plug: {Req.Test, stub(requests, body)})

    assert_request!(requests, "/v5/system/status")
  end

  test "fetch_status surfaces a nonzero venue response as a typed bad request" do
    body = %{"retCode" => 10_001, "retMsg" => "invalid request", "result" => %{}}
    {:ok, requests} = RequestCollector.start_link()

    assert {:error, %Bourse.Error{type: :bad_request, raw: ^body}} =
             Bourse.fetch_status(Exchange.new!("bybit"), plug: {Req.Test, stub(requests, body)})

    assert_request!(requests, "/v5/system/status")
  end

  test "order-trades request shape tolerates an extra-params map in the positional slot" do
    exchange = Exchange.new!("bybit", api_key: "k", secret: "s")

    # The positional `params` slot carries extra params as a map when the caller
    # passes no symbol; it must never be read as the symbol (FunctionClauseError).
    request =
      %{"id" => "123", "params" => %{"orderLinkId" => "abc"}}
      |> RequestShape.apply_premarket(exchange, "fetchOrderTrades")
      |> RequestShape.apply(exchange, "fetchOrderTrades")

    assert request["category"] == "linear"
    assert request["orderId"] == "123"
    refute Map.has_key?(request, "symbol")

    # The symbol travels in its own `"symbol"` channel, never the positional slot.
    with_symbol =
      %{"id" => "123", "symbol" => "BTC/USDT:USDT"}
      |> RequestShape.apply_premarket(exchange, "fetchOrderTrades")
      |> Unified.maybe_denormalize_symbol(exchange)
      |> RequestShape.apply(exchange, "fetchOrderTrades")

    assert with_symbol["symbol"] == "BTCUSDT"
    assert with_symbol["category"] == "linear"
  end

  test "open orders / canceled-closed request shapes inject category for no-symbol reads" do
    exchange = Exchange.new!("bybit", api_key: "k", secret: "s")

    open =
      %{}
      |> RequestShape.apply_premarket(exchange, "fetchOpenOrders")
      |> RequestShape.apply(exchange, "fetchOpenOrders")

    assert open["category"] == "linear"
    assert open["settleCoin"] == "USDT"

    canceled =
      %{"symbol" => "BTC/USDT:USDT"}
      |> RequestShape.apply_premarket(exchange, "fetchCanceledAndClosedOrders")
      |> Unified.maybe_denormalize_symbol(exchange)
      |> RequestShape.apply(exchange, "fetchCanceledAndClosedOrders")

    assert canceled["category"] == "linear"
    assert canceled["symbol"] == "BTCUSDT"
  end

  # The stub only records the request; every request-shape assertion runs in the
  # test process via `assert_request!/3` after the call under test returns.
  defp stub(collector, body) do
    name = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(name, fn conn ->
      conn = RequestCollector.capture(collector, conn)
      Req.Test.json(conn, body)
    end)

    name
  end

  defp assert_request!(collector, path, expected_query \\ nil) do
    conn = RequestCollector.one!(collector)

    assert conn.request_path == path
    assert_expected_query(conn, expected_query)
  end

  defp assert_expected_query(conn, expected_query) when is_map(expected_query) do
    query = Plug.Conn.fetch_query_params(conn).query_params

    Enum.each(expected_query, fn {key, value} -> assert query[key] == value end)
  end

  defp assert_expected_query(_conn, _expected_query), do: :ok
end
