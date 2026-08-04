defmodule Bourse.OkxAuthoredSpecTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Test.Generator.SymbolResolver
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified
  alias Bourse.Unified.ReadParse
  alias Bourse.Unified.RequestShape
  alias Bourse.Unified.RequestShape.OKX

  @positions_history_since_ms 1_700_000_000_500
  @positions_history_until_ms 1_700_000_002_000

  test "trading balance branches used per currency row" do
    body = %{
      "code" => "0",
      "msg" => "",
      "data" => [
        %{
          "uTime" => "1752243339082",
          "details" => [
            %{
              "ccy" => "USDT",
              "eq" => "0.000258796",
              "availEq" => "0",
              "availBal" => "0",
              "cashBal" => "0.000258796",
              "frozenBal" => "441.02"
            },
            %{
              "ccy" => "BTC",
              "eq" => "1.06126645222",
              "availEq" => "0.6612664522199999",
              "availBal" => "0.6612664522199999",
              "cashBal" => "1.06126645222",
              "frozenBal" => "0.4"
            },
            # No availEq: free/used come straight from availBal/frozenBal. eq is
            # deliberately != availBal + frozenBal so a derived `total - free`
            # (0.75) cannot masquerade as the mapped frozenBal (0.5).
            %{
              "ccy" => "ETH",
              "eq" => "2",
              "availBal" => "1.25",
              "cashBal" => "2",
              "frozenBal" => "0.5"
            }
          ]
        }
      ]
    }

    requests = collector()

    assert {:ok, balance} =
             Unified.call(
               private_exchange(),
               :fetch_balance,
               "fetchBalance",
               %{},
               plug: {Req.Test, stub_json(requests, body)}
             )

    assert_path!(requests, "/api/v5/account/balance")

    assert balance.total == %{"USDT" => 2.58796e-4, "BTC" => 1.06126645222, "ETH" => 2.0}
    assert balance.free == %{"USDT" => 0.0, "BTC" => 0.6612664522199999, "ETH" => 1.25}

    # availEq present: used is derived (eq - availEq) — frozenBal (441.02) must
    # never surface. availEq absent (ETH): used is the mapped frozenBal (0.5),
    # not the 0.75 a total - free derivation would report.
    assert balance.used["USDT"] == 2.58796e-4
    assert balance.used["BTC"] == 0.4000000000000001
    assert balance.used["ETH"] == 0.5
  end

  describe "response slices (task 258)" do
    # C-T427a — OKX signs a commission negative; we normalize to the positive-is-cost
    # convention every other authored venue already produces. Raw stays in `info`.
    test "trading fee unwraps the documented data row and normalizes OKX's negative sign" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "category" => "1",
            "instType" => "SPOT",
            "maker" => "-0.0008",
            "makerU" => "",
            "taker" => "-0.001",
            "takerU" => ""
          }
        ]
      }

      requests = collector()

      assert {:ok,
              %Bourse.TradingFee{
                symbol: "BTC/USDT",
                maker: 0.0008,
                taker: 0.001,
                info: %{"maker" => "-0.0008", "taker" => "-0.001"}
              }} =
               Unified.call(
                 private_exchange(),
                 :fetch_trading_fee,
                 "fetchTradingFee",
                 %{"symbol" => "BTC/USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/account/trade-fee")
    end

    # C-T427b — a USDT-margined row blanks `maker`/`taker` and carries the rate on
    # `makerU`/`takerU`. Without the second key this parses to an all-nil struct and the
    # fail-loud read guard rejects it (the defect class task 427 was filed for).
    test "trading fee falls back to the USDT-margined maker/taker carriers" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "category" => "1",
            "instType" => "SWAP",
            "maker" => "",
            "makerU" => "-0.0002",
            "taker" => "",
            "takerU" => "-0.0005"
          }
        ]
      }

      requests = collector()

      assert {:ok, %Bourse.TradingFee{symbol: "BTC/USDT:USDT", maker: 0.0002, taker: 0.0005}} =
               Unified.call(
                 private_exchange(),
                 :fetch_trading_fee,
                 "fetchTradingFee",
                 %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/account/trade-fee")
    end

    test "market-data residuals parse funding payments, newest-first candles, open interest, and status" do
      funding_body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "balChg" => "0.0197523380434766",
            "billId" => "3377454988989915430",
            "ccy" => "USDT",
            "instId" => "BTC-USDT-SWAP",
            "ts" => "1773158402431"
          }
        ]
      }

      funding_requests = collector()

      assert {:ok,
              [
                %Bourse.FundingHistory{
                  id: "3377454988989915430",
                  symbol: "BTC/USDT:USDT",
                  code: "USDT",
                  amount: 0.0197523380434766,
                  timestamp: 1_773_158_402_431,
                  datetime: "2026-03-10T16:00:02.431Z"
                }
              ]} =
               Unified.call(
                 private_exchange(),
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, stub_json(funding_requests, funding_body)}
               )

      assert_path!(funding_requests, "/api/v5/account/bills-archive")

      ohlcv_body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          ["1706637600000", "43398.6", "43493.9", "43279.9", "43373.9", "5070.79611732"],
          ["1706634000000", "43495.9", "43591.7", "43300", "43398.6", "4492.95408114"]
        ]
      }

      ohlcv_requests = collector()

      assert {:ok, [[1_706_634_000_000 | _], [1_706_637_600_000 | _]]} =
               Unified.call(public_exchange(), :fetch_ohlcv, "fetchOHLCV", %{"symbol" => "BTC/USDT", "timeframe" => "1h"},
                 plug: {Req.Test, stub_json(ohlcv_requests, ohlcv_body)}
               )

      assert_path!(ohlcv_requests, "/api/v5/market/candles")

      open_interest_body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instId" => "BTC-USDT-SWAP",
            "oi" => "2663107.29999999861",
            "oiCcy" => "26631.0729999999861",
            "oiUsd" => "1676426045.349999124995",
            "ts" => "1728728314766"
          }
        ]
      }

      open_interest_requests = collector()

      assert {:ok,
              %Bourse.OpenInterest{
                symbol: "BTC/USDT:USDT",
                open_interest_amount: amount,
                open_interest_value: value,
                base_volume: volume,
                timestamp: 1_728_728_314_766,
                datetime: "2024-10-12T10:18:34.766Z"
              }} =
               Unified.call(public_exchange(), :fetch_open_interest, "fetchOpenInterest", %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, stub_json(open_interest_requests, open_interest_body)}
               )

      assert_path!(open_interest_requests, "/api/v5/public/open-interest")

      assert_in_delta amount, 2_663_107.2999999986, 1.0e-8
      assert_in_delta value, 1_676_426_045.3499992, 1.0e-4
      assert_in_delta volume, 26_631.072999999986, 1.0e-10

      status_body = %{"code" => "0", "msg" => "", "data" => []}
      status_requests = collector()

      assert {:ok, %{status: "ok", updated: nil, eta: nil, url: nil, info: ^status_body}} =
               Unified.call(public_exchange(), :fetch_status, "fetchStatus", %{},
                 plug: {Req.Test, stub_json(status_requests, status_body)}
               )

      assert_path!(status_requests, "/api/v5/system/status")
    end

    test "status reports maintenance with the window eta and announcement url" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "begin" => "1621328400000",
            "end" => "1621329000000",
            "href" => "https://www.okx.com/support/hc/en-us/articles/360060882172",
            "scheDesc" => "",
            "serviceType" => "1",
            "state" => "ongoing",
            "system" => "classic",
            "title" => "Classic Spot System Upgrade"
          }
        ]
      }

      requests = collector()

      assert {:ok,
              %{
                status: "maintenance",
                eta: 1_621_329_000_000,
                url: "https://www.okx.com/support/hc/en-us/articles/360060882172",
                updated: nil,
                info: ^body
              }} =
               Unified.call(public_exchange(), :fetch_status, "fetchStatus", %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/system/status")
    end

    # A scheduled-but-not-started window is still operational; only `ongoing`
    # degrades service. The eta/url stay populated so a caller can surface the
    # upcoming window.
    test "status stays operational for a scheduled window while retaining the eta" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "end" => "1621329000000",
            "href" => "https://www.okx.com/support/hc/en-us/articles/360060882172",
            "state" => "scheduled",
            "title" => "Classic Spot System Upgrade"
          }
        ]
      }

      requests = collector()

      assert {:ok, %{status: "ok", eta: 1_621_329_000_000, url: "https://www.okx.com" <> _}} =
               Unified.call(public_exchange(), :fetch_status, "fetchStatus", %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/system/status")
    end

    test "status preserves an OKX business error instead of reporting ok" do
      body = %{"code" => "51000", "msg" => "Parameter instId error", "data" => []}

      requests = collector()

      assert {:error, %Bourse.Error{type: :bad_request, raw: ^body}} =
               Unified.call(public_exchange(), :fetch_status, "fetchStatus", %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/system/status")
    end

    test "order reads retain OKX lifecycle fields while action acknowledgements stay sparse" do
      exchange = private_exchange()

      read = %{
        "instId" => "BTC-USDT",
        "ordId" => "312269865356374016",
        "clOrdId" => "bourse-task363-read",
        "cTime" => "1751705801423",
        "uTime" => "1751705807467",
        "fillTime" => "1751705807000",
        "state" => "partially_filled",
        "ordType" => "limit",
        "side" => "buy",
        "px" => "100000",
        "avgPx" => "99999",
        "sz" => "0.01",
        "accFillSz" => "0.004",
        "reduceOnly" => "true"
      }

      assert {:ok,
              %Bourse.Order{
                id: "312269865356374016",
                client_order_id: "bourse-task363-read",
                timestamp: 1_751_705_801_423,
                last_update_timestamp: 1_751_705_807_467,
                last_trade_timestamp: 1_751_705_807_000,
                status: "open",
                type: "limit",
                time_in_force: "GTC",
                amount: 0.01,
                filled: 0.004,
                remaining: 0.006,
                price: 100_000.0,
                average: 99_999.0,
                cost: 399.996,
                reduce_only: true
              }} =
               ReadParse.parse(exchange, Bourse.Okx, :fetch_order, "fetchOrder", read, %{}, :parse_order, false)

      acknowledgement = %{
        "clOrdId" => "bourse-task363-ack",
        "ordId" => "312269865356374016",
        "sCode" => "0",
        "sMsg" => ""
      }

      assert {:ok,
              %Bourse.Order{
                id: "312269865356374016",
                client_order_id: "bourse-task363-ack",
                amount: nil,
                average: nil,
                cost: nil,
                fee: nil,
                fees: [],
                filled: nil,
                price: nil,
                remaining: nil,
                reduce_only: nil,
                side: nil,
                status: nil,
                time_in_force: nil,
                timestamp: nil,
                type: nil
              }} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :create_order,
                 "createOrder",
                 acknowledgement,
                 %{"symbol" => "BTC/USDT"},
                 :parse_order,
                 false
               )
    end

    test "fetch_time returns integer ms from data[0].ts" do
      body = %{"code" => "0", "data" => [%{"ts" => "1712250348676"}], "msg" => ""}

      requests = collector()

      assert {:ok, 1_712_250_348_676} =
               Unified.call(public_exchange(), :fetch_time, "fetchTime", %{}, plug: {Req.Test, stub_json(requests, body)})

      assert_path!(requests, "/api/v5/public/time")
    end

    test "fetch_accounts returns Account structs from account/config" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "uid" => "374579799097793561",
            "acctLv" => "1",
            "mainUid" => "374579799097793561",
            "label" => "Ray2"
          }
        ]
      }

      requests = collector()

      assert {:ok, [%Bourse.Account{} = account]} =
               Unified.call(private_exchange(), :fetch_accounts, "fetchAccounts", %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/account/config")

      assert account.id == "374579799097793561"
      assert account.type == "1"
      assert is_map(account.info)
    end

    test "fetch_ticker computes vwap/change/percentage/average/quote_volume from raw fields" do
      # Values from the CCXT compatibility response fixture for OKX fetchTicker.
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instType" => "SPOT",
            "instId" => "BTC-USDT",
            "last" => "73384.8",
            "askPx" => "73384.8",
            "askSz" => "0.40193728",
            "bidPx" => "73384.7",
            "bidSz" => "0.0655768",
            "open24h" => "72166.8",
            "high24h" => "73625.6",
            "low24h" => "68600",
            "volCcy24h" => "1519926359.597266598",
            "vol24h" => "21266.19145051",
            "ts" => "1710328243709"
          }
        ]
      }

      requests = collector()

      assert {:ok, %Bourse.Ticker{} = ticker} =
               Unified.call(public_exchange(), :fetch_ticker, "fetchTicker", %{"symbol" => "BTC/USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/market/ticker")

      assert ticker.last == 73_384.8
      assert ticker.open == 72_166.8
      assert_in_delta ticker.quote_volume, 1_519_926_359.597266598, 1.0
      assert_in_delta ticker.change, 1218.0, 0.01
      assert_in_delta ticker.percentage, 1.6877566969853173, 1.0e-6
      assert_in_delta ticker.average, 72_775.8, 0.01
      assert_in_delta ticker.vwap, 71_471.48858950088, 0.01
      assert ticker.symbol == "BTC/USDT"
    end

    # C36: linear SWAP volCcy24h/vol24h == ctVal (0.01), not a price. Live mainnet
    # 2026-07-17 BTC-USDT-SWAP: last≈63391, ratio=0.01. Bourse emits 0.01; we nil.
    test "fetch_ticker leaves vwap nil on linear swap (C36 — ratio is ctVal, not price)" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instType" => "SWAP",
            "instId" => "BTC-USDT-SWAP",
            "last" => "63391.4",
            "open24h" => "64582.8",
            "high24h" => "65000",
            "low24h" => "63000",
            "vol24h" => "8305293.78",
            "volCcy24h" => "83052.9378",
            "ts" => "1784256801861"
          }
        ]
      }

      requests = collector()

      assert {:ok, %Bourse.Ticker{} = ticker} =
               Unified.call(
                 public_exchange(),
                 :fetch_ticker,
                 "fetchTicker",
                 %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/market/ticker")

      assert ticker.last == 63_391.4
      assert_in_delta ticker.base_volume, 8_305_293.78, 0.01
      assert_in_delta ticker.quote_volume, 83_052.9378, 0.01
      # Bourse-compat formula would yield 0.01 (== ctVal); ours must not.
      refute ticker.vwap == 0.01
      assert is_nil(ticker.vwap)
    end

    # C36: inverse SWAP ratio is also not a price without ctVal (live 2026-07-17
    # BTC-USD-SWAP: volCcy/vol24 ≈ 0.00156 vs last ≈ 63335).
    test "fetch_ticker leaves vwap nil on inverse swap (C36)" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instType" => "SWAP",
            "instId" => "BTC-USD-SWAP",
            "last" => "63335",
            "open24h" => "64539.2",
            "high24h" => "65000",
            "low24h" => "63000",
            "vol24h" => "2696948",
            "volCcy24h" => "4207.9245",
            "ts" => "1784256802759"
          }
        ]
      }

      requests = collector()

      assert {:ok, %Bourse.Ticker{} = ticker} =
               Unified.call(
                 public_exchange(),
                 :fetch_ticker,
                 "fetchTicker",
                 %{"symbol" => "BTC/USD:BTC"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/market/ticker")

      assert ticker.last == 63_335.0
      assert is_nil(ticker.vwap)
    end

    test "fetch_mark_price returns numeric mark_price on Ticker" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instId" => "BTC-USDT-SWAP",
            "instType" => "SWAP",
            "markPx" => "64210.8",
            "ts" => "1784208522102"
          }
        ]
      }

      requests = collector()

      assert {:ok, %Bourse.Ticker{} = ticker} =
               Unified.call(
                 public_exchange(),
                 :fetch_mark_price,
                 "fetchMarkPrice",
                 %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/public/mark-price")

      assert is_number(ticker.mark_price)
      assert ticker.mark_price == 64_210.8
      assert ticker.symbol == "BTC/USDT:USDT"
    end

    test "fetch_tickers indexes a non-empty symbol-keyed map from data rows" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instType" => "SPOT",
            "instId" => "BTC-USDT",
            "last" => "100",
            "open24h" => "90",
            "vol24h" => "10",
            "volCcy24h" => "950",
            "ts" => "1710328243709"
          },
          %{
            "instType" => "SPOT",
            "instId" => "ETH-USDT",
            "last" => "200",
            "open24h" => "180",
            "vol24h" => "20",
            "volCcy24h" => "3800",
            "ts" => "1710328243709"
          }
        ]
      }

      requests = collector()

      assert {:ok, %{} = tickers} =
               Unified.call(public_exchange(), :fetch_tickers, "fetchTickers", %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/market/tickers")

      assert map_size(tickers) == 2
      assert %Bourse.Ticker{last: 100.0} = tickers["BTC/USDT"]
      assert %Bourse.Ticker{last: 200.0} = tickers["ETH/USDT"]
    end

    test "fetch_markets unwraps data list into Markets with type/symbol/id" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instType" => "SPOT",
            "instId" => "BTC-USDT",
            "baseCcy" => "BTC",
            "quoteCcy" => "USDT",
            "state" => "live",
            "lotSz" => "0.00001",
            "tickSz" => "0.1",
            "minSz" => "0.00001"
          },
          %{
            "instType" => "SWAP",
            "instId" => "BTC-USDT-SWAP",
            "baseCcy" => "",
            "quoteCcy" => "",
            "ctValCcy" => "BTC",
            "settleCcy" => "USDT",
            "ctType" => "linear",
            "ctVal" => "0.01",
            "state" => "live",
            "lotSz" => "1",
            "tickSz" => "0.1",
            "minSz" => "1"
          }
        ]
      }

      # Pin a single instType so the offline plug is not asked to fan out every
      # option-underlying wave (param_fan_out short-circuits when instType is set).
      requests = collector()

      assert {:ok, markets} =
               Unified.call(
                 public_exchange(),
                 :fetch_markets,
                 "fetchMarkets",
                 %{"instType" => "SPOT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/public/instruments")

      assert length(markets) == 2
      spot = Enum.find(markets, &(&1.id == "BTC-USDT"))
      swap = Enum.find(markets, &(&1.id == "BTC-USDT-SWAP"))
      assert %Bourse.Market{type: "spot", symbol: "BTC/USDT", id: "BTC-USDT"} = spot
      assert %Bourse.Market{type: "swap", symbol: "BTC/USDT:USDT", id: "BTC-USDT-SWAP"} = swap
    end

    # Contract-size and inverse/linear come from the market FIELD-MAP (ctVal /
    # ctType), not hand-built market structs: task 397 nulled the generic
    # contractSize map while repopulating only OPTION markets, silently dropping
    # contract_size for OKX swaps/futures — nothing caught it because position
    # tests hand-set the field. Instrument shapes per OKX API v5
    # /public/instruments; the inverse-swap values match the reviewer's live
    # confrontation (BTC/USD:BTC ctVal 100 → contract_size 100.0).
    test "fetch_markets populates contract_size and inverse/linear from ctVal/ctType" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instType" => "SWAP",
            "instId" => "BTC-USD-SWAP",
            "uly" => "BTC-USD",
            "baseCcy" => "",
            "quoteCcy" => "",
            "ctValCcy" => "USD",
            "settleCcy" => "BTC",
            "ctType" => "inverse",
            "ctVal" => "100",
            "ctMult" => "1",
            "state" => "live",
            "lotSz" => "1",
            "tickSz" => "0.1",
            "minSz" => "1"
          },
          %{
            "instType" => "SWAP",
            "instId" => "BTC-USDT-SWAP",
            "uly" => "BTC-USDT",
            "baseCcy" => "",
            "quoteCcy" => "",
            "ctValCcy" => "BTC",
            "settleCcy" => "USDT",
            "ctType" => "linear",
            "ctVal" => "0.01",
            "ctMult" => "1",
            "state" => "live",
            "lotSz" => "1",
            "tickSz" => "0.1",
            "minSz" => "1"
          },
          %{
            "instType" => "OPTION",
            "instId" => "BTC-USD-260327-100000-C",
            "uly" => "BTC-USD",
            "baseCcy" => "",
            "quoteCcy" => "",
            "ctValCcy" => "BTC",
            "settleCcy" => "BTC",
            "ctType" => "",
            "ctVal" => "0.01",
            "ctMult" => "1",
            "optType" => "C",
            "stk" => "100000",
            "expTime" => "1774569600000",
            "state" => "live",
            "lotSz" => "1",
            "tickSz" => "0.0001",
            "minSz" => "1"
          }
        ]
      }

      requests = collector()

      assert {:ok, markets} =
               Unified.call(
                 public_exchange(),
                 :fetch_markets,
                 "fetchMarkets",
                 %{"instType" => "SWAP"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/public/instruments")

      inverse_swap = Enum.find(markets, &(&1.id == "BTC-USD-SWAP"))
      linear_swap = Enum.find(markets, &(&1.id == "BTC-USDT-SWAP"))
      option = Enum.find(markets, &(&1.id == "BTC-USD-260327-100000-C"))

      assert %Bourse.Market{contract: true, contract_size: 100.0, inverse: true, linear: false} =
               inverse_swap

      assert %Bourse.Market{contract: true, contract_size: 0.01, inverse: false, linear: true} =
               linear_swap

      # OPTION contract_size is ctVal * ctMult (normalize_market override; the
      # product semantics itself is pinned in option_quantity_test).
      assert %Bourse.Market{contract: true, contract_size: 0.01} = option
    end

    test "fetch_convert_currencies parses currency list without shape error" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{"ccy" => "BTC", "min" => "0.0001", "max" => ""},
          %{"ccy" => "USDT", "min" => "1", "max" => ""}
        ]
      }

      requests = collector()

      assert {:ok, %{} = currencies} =
               Unified.call(
                 private_exchange(),
                 :fetch_convert_currencies,
                 "fetchConvertCurrencies",
                 %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/asset/convert/currencies")

      assert map_size(currencies) == 2
      assert %Bourse.Currency{id: "BTC", code: "BTC"} = currencies["BTC"]
      assert %Bourse.Currency{id: "USDT", code: "USDT"} = currencies["USDT"]
    end

    test "fetch_currencies groups every chain under one currency" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "ccy" => "BTC",
            "name" => "Bitcoin",
            "chain" => "BTC-Bitcoin",
            "mainNet" => true,
            "canDep" => true,
            "canWd" => true,
            "fee" => "0.000015",
            "wdTickSz" => "8",
            "minWd" => "0.00008",
            "maxWd" => "500",
            "minDep" => "0.00003"
          },
          %{
            "ccy" => "BTC",
            "name" => "Bitcoin",
            "chain" => "BTCK-OKTC",
            "mainNet" => false,
            "canDep" => true,
            "canWd" => false,
            "fee" => "0",
            "wdTickSz" => "8",
            "minWd" => "0",
            "maxWd" => "500",
            "minDep" => "0.00000001"
          }
        ]
      }

      requests = collector()

      assert {:ok, %{"BTC" => %Bourse.Currency{} = bitcoin}} =
               Unified.call(private_exchange(), :fetch_currencies, "fetchCurrencies", %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/asset/currencies")

      assert bitcoin.info == body["data"]
      assert bitcoin.fee == 1.5e-5
      assert bitcoin.precision == 1.0e-8
      assert bitcoin.limits["withdraw"] == %{"min" => 0.0, "max" => 500.0}
      assert %{"BTC" => bitcoin_network, "OKTC" => oktc_network} = bitcoin.networks
      assert bitcoin_network["fee"] == 1.5e-5
      assert bitcoin_network["limits"]["withdraw"] == %{"min" => 8.0e-5, "max" => 500.0}
      assert oktc_network["withdraw"] == false
    end

    test "fetch_transfers maps OKX bills fields without treating balance change as amt" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "billId" => "673260238845333504",
            "ccy" => "USDT",
            "balChg" => "1.25",
            "amt" => "99",
            "from" => "6",
            "to" => "18",
            "ts" => "1706789749511"
          }
        ]
      }

      requests = collector()

      assert {:ok, [%Bourse.TransferEntry{} = transfer]} =
               Unified.call(private_exchange(), :fetch_transfers, "fetchTransfers", %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/account/bills-archive")

      assert transfer.id == "673260238845333504"
      assert transfer.currency == "USDT"
      assert transfer.amount == 1.25
      assert transfer.from_account == "funding"
      assert transfer.to_account == "trading"
    end

    test "fetch_ledger retains signed balance, fee, currency, and direction semantics" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "bal" => "67533.7456994514348308",
            "balChg" => "-10.1580000000000000",
            "billId" => "696837060589600769",
            "ccy" => "USDT",
            "fee" => "0",
            "ordId" => "1339107111507525632",
            "ts" => "1712410901851",
            "type" => "2"
          }
        ]
      }

      requests = collector()

      assert {:ok, [%Bourse.LedgerEntry{} = entry]} =
               Unified.call(private_exchange(), :fetch_ledger, "fetchLedger", %{"code" => "USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/account/bills")

      assert entry.id == "696837060589600769"
      assert entry.currency == "USDT"
      assert entry.amount == -10.158
      assert_in_delta entry.after, 67_533.74569945144, 1.0e-9
      assert_in_delta entry.before, 67_543.90369945144, 1.0e-9
      assert entry.direction == "out"
      assert entry.reference_id == "1339107111507525632"
      assert entry.type == "trade"
      assert entry.status == "ok"
      assert entry.fee == %{"cost" => 0.0, "currency" => "USDT"}
    end

    test "fetch_transfer translates funding and trading account identifiers" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "amt" => "1",
            "ccy" => "USDC",
            "from" => "18",
            "state" => "success",
            "to" => "6",
            "transId" => "820757608"
          }
        ]
      }

      requests = collector()

      assert {:ok, %Bourse.TransferEntry{} = transfer} =
               Unified.call(private_exchange(), :fetch_transfer, "fetchTransfer", %{"id" => "820757608"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/asset/transfer-state")

      assert transfer.id == "820757608"
      assert transfer.currency == "USDC"
      assert transfer.amount == 1.0
      assert transfer.from_account == "trading"
      assert transfer.to_account == "funding"
      assert transfer.status == "ok"
    end

    test "fetch_cross_borrow_rate returns BorrowRate scoped to requested currency" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{"ccy" => "USDT", "interestRate" => "0.0001", "ts" => "1710328243709"}
        ]
      }

      requests = collector()

      assert {:ok, %Bourse.BorrowRate{} = rate} =
               Unified.call(
                 private_exchange(),
                 :fetch_cross_borrow_rate,
                 "fetchCrossBorrowRate",
                 %{"code" => "USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/account/interest-rate")

      assert rate.currency == "USDT"
      assert rate.rate == 0.0001
    end

    test "fetch_cross_borrow_rates keeps every row, keyed by currency code" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{"ccy" => "USDT", "interestRate" => "0.0001", "ts" => "1710328243709"},
          %{"ccy" => "BTC", "interestRate" => "0.00002", "ts" => "1710328243709"},
          %{"ccy" => "ETH", "interestRate" => "0.00003", "ts" => "1710328243709"}
        ]
      }

      requests = collector()

      assert {:ok, %{} = rates} =
               Unified.call(
                 private_exchange(),
                 :fetch_cross_borrow_rates,
                 "fetchCrossBorrowRates",
                 %{},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/account/interest-rate")

      # Bourse `CrossBorrowRates` is a currency-keyed dict. Collapsing to the first
      # row silently drops the rest — live demo answers 21 currencies.
      assert map_size(rates) == 3
      assert %Bourse.BorrowRate{currency: "USDT", rate: 0.0001} = rates["USDT"]
      assert %Bourse.BorrowRate{currency: "BTC", rate: 0.00002} = rates["BTC"]
      assert %Bourse.BorrowRate{currency: "ETH", rate: 0.00003} = rates["ETH"]
    end

    test "fetch_greeks selects Black-Scholes greeks from the requested opt-summary row" do
      symbol = "BTC/USD:USD-261225-90000-P"

      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instId" => "BTC-USD_UM-261225-40000-C",
            "delta" => "",
            "deltaBS" => "",
            "gamma" => "",
            "gammaBS" => "",
            "vega" => "",
            "vegaBS" => "",
            "theta" => "",
            "thetaBS" => "",
            "ts" => "1784208522102"
          },
          %{
            "instId" => "BTC-USD_UM-261225-90000-P",
            "delta" => "-1.2051359955599346",
            "deltaBS" => "-0.7904674450641715",
            "gamma" => "3.2733454416584755",
            "gammaBS" => "0.00001349022316429954",
            "vega" => "0.0018957040866978078",
            "vegaBS" => "121.28278734752634",
            "theta" => "-0.00028299440874938396",
            "thetaBS" => "-9.906365773126579",
            "ts" => "1784208522102"
          }
        ]
      }

      requests = collector()

      assert {:ok, %Bourse.Greeks{} = greeks} =
               Unified.call(public_exchange(), :fetch_greeks, "fetchGreeks", %{"symbol" => symbol},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/public/opt-summary")

      assert greeks.symbol == symbol
      assert greeks.info["instId"] == "BTC-USD_UM-261225-90000-P"
      assert greeks.delta == -0.7904674450641715
      assert greeks.gamma == 0.00001349022316429954
      assert greeks.vega == 121.28278734752634
      assert greeks.theta == -9.906365773126579
      assert greeks.delta >= -1 and greeks.delta <= 0
    end

    test "fetch_all_greeks unwraps opt-summary data and indexes every row by symbol" do
      first_symbol = "BTC/USD:BTC-260717-40000-C"
      second_symbol = "BTC/USD:BTC-260717-48000-C"

      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "instType" => "OPTION",
            "instId" => "BTC-USD-260717-40000-C",
            "delta" => "0.25",
            "deltaBS" => "0.35",
            "gamma" => "0.00008",
            "gammaBS" => "0.00018",
            "vega" => "14.5",
            "vegaBS" => "24.5",
            "theta" => "-7.25",
            "thetaBS" => "-8.25",
            "ts" => "1784208522102"
          },
          %{
            "instType" => "OPTION",
            "instId" => "BTC-USD-260717-48000-C",
            "delta" => "0.42",
            "deltaBS" => "0.52",
            "gamma" => "0.00012",
            "gammaBS" => "0.00022",
            "vega" => "23.5",
            "vegaBS" => "33.5",
            "theta" => "-12.25",
            "thetaBS" => "-13.25",
            "ts" => "1784208522102"
          }
        ]
      }

      requests = collector()

      assert {:ok, %{^first_symbol => first, ^second_symbol => second} = greeks} =
               Unified.call(public_exchange(), :fetch_all_greeks, "fetchAllGreeks", %{"instFamily" => "BTC-USD"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/public/opt-summary")

      assert map_size(greeks) == 2
      assert %Bourse.Greeks{symbol: ^first_symbol, delta: 0.35, gamma: 0.00018, vega: 24.5, theta: -8.25} = first
      assert %Bourse.Greeks{symbol: ^second_symbol, delta: 0.52, gamma: 0.00022, vega: 33.5, theta: -13.25} = second
    end
  end

  describe "residual read and position request builds (task 434)" do
    test "order book and candle requests use OKX depth, bars, and exclusive history windows" do
      exchange = public_exchange()

      assert RequestShape.apply(
               %{"symbol" => "BTC-USDT", "limit" => 5},
               exchange,
               "fetchOrderBook"
             ) == %{"instId" => "BTC-USDT", "sz" => 5}

      assert RequestShape.apply(
               %{
                 "symbol" => "BTC-USDT",
                 "timeframe" => "1H",
                 "since" => 1_699_931_781_033,
                 "limit" => 500
               },
               exchange,
               "fetchOHLCV"
             ) == %{
               "instId" => "BTC-USDT",
               "bar" => "1H",
               "limit" => 300,
               "before" => 1_699_931_781_032,
               "after" => 1_701_011_781_033
             }

      assert RequestShape.apply(%{"symbol" => "BTC-USDT"}, exchange, "fetchOHLCV") == %{
               "instId" => "BTC-USDT",
               "bar" => "1m",
               "limit" => 100
             }
    end

    test "public list reads derive their native market and option filters" do
      exchange = public_exchange()

      ticker_params =
        %{"symbols" => ["BTC/USDT:USDT"]}
        |> RequestShape.apply_premarket(exchange, "fetchTickers")
        |> RequestShape.apply(exchange, "fetchTickers")

      assert ticker_params == %{"instType" => "SWAP"}

      assert RequestShape.apply(%{"symbol" => "BTC-USDT"}, exchange, "fetchTrades") == %{
               "instId" => "BTC-USDT"
             }

      assert RequestShape.apply(%{"symbol" => "BTC"}, exchange, "fetchOptionChain") == %{
               "instType" => "OPTION",
               "uly" => "BTC-USD"
             }

      assert RequestShape.apply(
               %{"symbols" => ["BTC/USD:BTC-241227-60000-P"], "uly" => "BTC-USD"},
               exchange,
               "fetchAllGreeks"
             ) == %{
               "expTime" => "241227",
               "instFamily" => "BTC-USD",
               "uly" => "BTC-USD"
             }

      assert RequestShape.apply(
               %{"symbol" => "BTC-USDT-SWAP"},
               exchange,
               "fetchOpenInterestHistory"
             ) == %{"ccy" => "BTC", "period" => "1D"}
    end

    # C-T475a — bare bases expand only to the registered USD settle; non-USD
    # families fail locally with the input named (no silent -USD rewrite).
    # Authored defaults bind uly from unified `symbol`, so pass families there.
    test "option underlying expansion is USD-only and fails loud for other settles" do
      exchange = public_exchange()

      option_symbols =
        "okx"
        |> SymbolResolver.markets()
        |> Map.keys()
        |> Enum.filter(&Regex.match?(~r/-[CP]$/, &1))

      assert option_symbols != []
      assert Enum.all?(option_symbols, &String.contains?(&1, "/USD:"))

      assert RequestShape.apply(%{"symbol" => "ETH"}, exchange, "fetchOptionChain") == %{
               "instType" => "OPTION",
               "uly" => "ETH-USD"
             }

      assert RequestShape.apply(%{"symbol" => "BTC-USD"}, exchange, "fetchOptionChain") == %{
               "instType" => "OPTION",
               "uly" => "BTC-USD"
             }

      assert_raise ArgumentError, ~r/unsupported OKX option underlying "BTC-USDT".*BASE-USD/, fn ->
        RequestShape.apply(%{"symbol" => "BTC-USDT"}, exchange, "fetchOptionChain")
      end

      assert_raise ArgumentError, ~r/unsupported OKX option underlying "BTC\/USD"/, fn ->
        RequestShape.apply(%{"symbol" => "BTC/USD"}, exchange, "fetchOptionChain")
      end

      assert_raise ArgumentError, ~r/unsupported OKX option underlying "-USD"/, fn ->
        RequestShape.apply(%{"symbol" => "-USD"}, exchange, "fetchOptionChain")
      end
    end

    # C-T475b — Rubik open-interest period is a closed map; unmapped timeframes
    # name the supported set instead of riding through to the venue.
    # Authored defaults bind period from unified `timeframe` (default 1d).
    test "open-interest history periods map the documented set and reject unknowns" do
      exchange = public_exchange()
      contract_opts = [endpoint_path: "rubik/stat/contracts/open-interest-volume"]
      option_opts = [endpoint_path: "rubik/stat/option/open-interest-volume"]
      plug = {Req.Test, stub_json(collector(), %{"code" => "0", "data" => [], "msg" => ""})}

      assert RequestShape.apply(
               %{"symbol" => "BTC-USDT-SWAP", "timeframe" => "5m"},
               exchange,
               "fetchOpenInterestHistory",
               contract_opts
             ) == %{"ccy" => "BTC", "period" => "5m"}

      assert RequestShape.apply(
               %{"symbol" => "BTC-USDT-SWAP", "timeframe" => "1h"},
               exchange,
               "fetchOpenInterestHistory",
               contract_opts
             ) == %{"ccy" => "BTC", "period" => "1H"}

      assert RequestShape.apply(
               %{"symbol" => "BTC/USD:BTC-260622-60000-C", "timeframe" => "8H"},
               exchange,
               "fetchOpenInterestHistory",
               option_opts
             ) == %{"ccy" => "BTC", "period" => "8H"}

      assert_raise ArgumentError,
                   ~r/unsupported OKX open-interest period "15m".*contracts.*supported: .*1D/,
                   fn ->
                     Unified.call(
                       exchange,
                       :fetch_open_interest_history,
                       "fetchOpenInterestHistory",
                       %{"symbol" => "BTC/USDT:USDT", "timeframe" => "15m"},
                       plug: plug
                     )
                   end

      assert_raise ArgumentError, ~r/unsupported OKX open-interest period "8H".*contracts/, fn ->
        RequestShape.apply(
          %{"symbol" => "BTC-USDT-SWAP", "timeframe" => "8H"},
          exchange,
          "fetchOpenInterestHistory",
          contract_opts
        )
      end

      assert_raise ArgumentError, ~r/unsupported OKX open-interest period "5m".*option/, fn ->
        Unified.call(
          exchange,
          :fetch_open_interest_history,
          "fetchOpenInterestHistory",
          %{"symbol" => "BTC/USD:BTC-260622-60000-C", "timeframe" => "5m"},
          plug: plug
        )
      end

      assert_raise ArgumentError, ~r/unsupported OKX open-interest endpoint "rubik\/stat\/other"/, fn ->
        RequestShape.apply(
          %{"symbol" => "BTC-USDT-SWAP", "timeframe" => "1D"},
          exchange,
          "fetchOpenInterestHistory",
          endpoint_path: "rubik/stat/other"
        )
      end
    end

    test "signed account reads map currency filters and documented pagination names" do
      exchange = private_exchange()

      assert RequestShape.apply(%{"code" => "USDT"}, exchange, "fetchLedger") == %{
               "ccy" => "USDT",
               "instType" => "SPOT"
             }

      assert RequestShape.apply(
               %{"code" => "USDT", "since" => 1_700_000_000_000, "until" => 1_700_000_100_000},
               exchange,
               "fetchDeposits"
             ) == %{
               "ccy" => "USDT",
               "before" => 1_699_999_999_999,
               "after" => 1_700_000_100_000
             }
    end

    test "position reads expand native ids and map history until to native after" do
      exchange = private_exchange()

      assert RequestShape.apply(
               %{"symbols" => ["LTC/USDT:USDT", "BTC/USDT:USDT"]},
               exchange,
               "fetchPositions"
             ) == %{"instId" => "LTC-USDT-SWAP,BTC-USDT-SWAP"}

      assert RequestShape.apply(
               %{
                 "symbols" => ["XRP/USDT:USDT"],
                 "since" => 1_708_735_940_395,
                 "until" => 1_708_735_950_000,
                 "limit" => 1
               },
               exchange,
               "fetchPositionsHistory"
             ) == %{
               "after" => 1_708_735_950_000,
               "instId" => "XRP-USDT-SWAP",
               "limit" => 1
             }

      assert RequestShape.apply(
               %{"symbol" => "BTC-USDT-SWAP"},
               exchange,
               "fetchPosition"
             ) == %{"instId" => "BTC-USDT-SWAP", "instType" => "SWAP"}
    end

    test "positions history keeps since local and sends exclusive until as after" do
      rows =
        [
          %{
            "cTime" => "1700000002000",
            "closeAvgPx" => "1.40",
            "direction" => "long",
            "instId" => "SUSHI-USDT-SWAP",
            "lever" => "10",
            "mgnMode" => "isolated",
            "openAvgPx" => "1.35",
            "posId" => "newer-than-until",
            "realizedPnl" => "1.0",
            "uTime" => "1700000002100"
          },
          %{
            "cTime" => "1700000001900",
            "closeAvgPx" => "1.35",
            "direction" => "short",
            "instId" => "SUSHI-USDT-SWAP",
            "lever" => "10",
            "mgnMode" => "isolated",
            "openAvgPx" => "1.30",
            "posId" => "at-until",
            "realizedPnl" => "0.9",
            "uTime" => Integer.to_string(@positions_history_until_ms)
          },
          %{
            "cTime" => "1700000001800",
            "closeAvgPx" => "1.32",
            "direction" => "long",
            "instId" => "SUSHI-USDT-SWAP",
            "lever" => "10",
            "mgnMode" => "isolated",
            "openAvgPx" => "1.28",
            "posId" => "before-until",
            "realizedPnl" => "0.8",
            "uTime" => Integer.to_string(@positions_history_until_ms - 1)
          },
          %{
            "cTime" => "1700000000000",
            "closeAvgPx" => "1.25",
            "direction" => "long",
            "instId" => "SUSHI-USDT-SWAP",
            "lever" => "10",
            "mgnMode" => "isolated",
            "openAvgPx" => "1.20",
            "posId" => "before-since",
            "realizedPnl" => "0.5",
            "uTime" => "1700000000100"
          },
          %{
            "cTime" => "1700000001000",
            "closeAvgPx" => "1.30",
            "direction" => "short",
            "instId" => "SUSHI-USDT-SWAP",
            "lever" => "10",
            "mgnMode" => "isolated",
            "openAvgPx" => "1.25",
            "posId" => "after-since",
            "realizedPnl" => "0.75",
            "uTime" => "1700000001100"
          }
        ]

      requests = collector()

      assert {:ok, history} =
               Bourse.fetch_positions_history(private_exchange(),
                 since: @positions_history_since_ms,
                 until: @positions_history_until_ms,
                 plug: {Req.Test, stub_positions_history(requests, rows)}
               )

      assert Enum.map(history, & &1.id) == ["before-until", "after-since"]
      assert Enum.all?(history, &(&1.timestamp < @positions_history_until_ms))

      conn = RequestCollector.one!(requests)
      assert conn.method == "GET"
      assert conn.request_path == "/api/v5/account/positions-history"

      assert RequestCollector.query(conn) == %{
               "after" => Integer.to_string(@positions_history_until_ms),
               "limit" => "100"
             }
    end
  end

  describe "createOrder / editOrder / fetchMyTrades request builds (task 385)" do
    test "create_order posts trade/order with OKX body keys, not batch-orders" do
      # Fake success acknowledgement — offline path only; never a live resting order.
      ack = %{
        "code" => "0",
        "data" => [
          %{
            "clOrdId" => "",
            "ordId" => "312269865356374016",
            "sCode" => "0",
            "sMsg" => ""
          }
        ],
        "msg" => ""
      }

      expected_body = %{
        "instId" => "BTC-USDT",
        "tdMode" => "cash",
        "ordType" => "limit",
        "side" => "buy",
        "sz" => "0.0001",
        "px" => "31998"
      }

      requests = collector()

      assert {:ok, %Bourse.Order{id: "312269865356374016"}} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "BTC/USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 0.0001,
                   "price" => 31_998.0
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order", expected_body)
    end

    test "create_order uses tdMode cross for swaps and honors marginMode override on spot" do
      ack = %{
        "code" => "0",
        "data" => [%{"clOrdId" => "", "ordId" => "1", "sCode" => "0", "sMsg" => ""}],
        "msg" => ""
      }

      swap_body = %{
        "instId" => "BTC-USDT-SWAP",
        "tdMode" => "cross",
        "ordType" => "limit",
        "side" => "buy",
        "sz" => "1",
        "px" => "25000"
      }

      swap_requests = collector()

      assert {:ok, %Bourse.Order{}} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "BTC/USDT:USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 1,
                   "price" => 25_000
                 },
                 plug: {Req.Test, stub_json(swap_requests, ack)}
               )

      assert_post!(swap_requests, "/api/v5/trade/order", swap_body)

      margin_body = %{
        "instId" => "BTC-USDT",
        "tdMode" => "isolated",
        "ordType" => "limit",
        "side" => "buy",
        "sz" => "0.01",
        "px" => "10000"
      }

      margin_requests = collector()

      assert {:ok, %Bourse.Order{}} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "BTC/USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 0.01,
                   "price" => 10_000,
                   "marginMode" => "isolated"
                 },
                 plug: {Req.Test, stub_json(margin_requests, ack)}
               )

      assert_post!(margin_requests, "/api/v5/trade/order", margin_body)
    end

    test "edit_order posts trade/amend-order with newSz/newPx" do
      ack = %{
        "code" => "0",
        "data" => [
          %{
            "clOrdId" => "",
            "ordId" => "617122719557050368",
            "sCode" => "0",
            "sMsg" => ""
          }
        ],
        "msg" => ""
      }

      expected_body = %{
        "instId" => "BTC-USDT",
        "ordId" => "617122719557050368",
        "newSz" => "0.05",
        "newPx" => "55"
      }

      requests = collector()

      assert {:ok, %Bourse.Order{id: "617122719557050368"}} =
               Unified.call(
                 private_exchange(),
                 :edit_order,
                 "editOrder",
                 %{
                   "id" => "617122719557050368",
                   "symbol" => "BTC/USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 0.05,
                   "price" => 55
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/amend-order", expected_body)
    end

    test "loaded market precision rounds create and amend quantities and prices" do
      ack = %{
        "code" => "0",
        "data" => [%{"clOrdId" => "", "ordId" => "617122719557050368", "sCode" => "0", "sMsg" => ""}],
        "msg" => ""
      }

      exchange = private_exchange_with_btc_precision()
      create_requests = collector()

      assert {:ok, %Bourse.Order{}} =
               Unified.call(
                 exchange,
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "BTC/USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => "0.000109",
                   "price" => "31998.09"
                 },
                 plug: {Req.Test, stub_json(create_requests, ack)}
               )

      assert_post!(create_requests, "/api/v5/trade/order", %{
        "instId" => "BTC-USDT",
        "tdMode" => "cash",
        "ordType" => "limit",
        "side" => "buy",
        "sz" => "0.0001",
        "px" => "31998.1"
      })

      edit_requests = collector()

      assert {:ok, %Bourse.Order{}} =
               Unified.call(
                 exchange,
                 :edit_order,
                 "editOrder",
                 %{
                   "id" => "617122719557050368",
                   "symbol" => "BTC/USDT",
                   "amount" => "0.000109",
                   "price" => "31998.09"
                 },
                 plug: {Req.Test, stub_json(edit_requests, ack)}
               )

      assert_post!(edit_requests, "/api/v5/trade/amend-order", %{
        "instId" => "BTC-USDT",
        "ordId" => "617122719557050368",
        "newSz" => "0.0001",
        "newPx" => "31998.1"
      })
    end

    test "sub-lot amount forwards the requested size rather than rounding to zero" do
      ack = %{
        "code" => "0",
        "data" => [%{"clOrdId" => "", "ordId" => "617122719557050368", "sCode" => "0", "sMsg" => ""}],
        "msg" => ""
      }

      # 0.000001 is below the 0.00001 lot step; no client-side rounding can
      # satisfy it, so the caller's size must survive to the wire and let OKX
      # answer with 51121 naming the real amount instead of an opaque sz=0.
      requests = collector()

      assert {:ok, %Bourse.Order{}} =
               Unified.call(
                 private_exchange_with_btc_precision(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "BTC/USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => "0.000001",
                   "price" => "31998.09"
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order", %{
        "instId" => "BTC-USDT",
        "tdMode" => "cash",
        "ordType" => "limit",
        "side" => "buy",
        "sz" => "0.000001",
        "px" => "31998.1"
      })
    end

    test "raw-map markets carry precision the same as %Bourse.Market{} structs" do
      ack = %{
        "code" => "0",
        "data" => [%{"clOrdId" => "", "ordId" => "617122719557050368", "sCode" => "0", "sMsg" => ""}],
        "msg" => ""
      }

      # `Exchange.market_cache/0` admits raw maps; an atom-only read would skip
      # precision here and ship the unrounded value.
      raw_markets =
        Exchange.put_markets(private_exchange(), [
          %{"id" => "BTC-USDT", "symbol" => "BTC/USDT", "precision" => %{"amount" => 0.00001, "price" => 0.1}}
        ])

      requests = collector()

      assert {:ok, %Bourse.Order{}} =
               Unified.call(
                 raw_markets,
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "BTC/USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => "0.000109",
                   "price" => "31998.09"
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order", %{
        "instId" => "BTC-USDT",
        "tdMode" => "cash",
        "ordType" => "limit",
        "side" => "buy",
        "sz" => "0.0001",
        "px" => "31998.1"
      })
    end

    test "fetch_my_trades GETs trade/fills with instId and no raw symbol key" do
      body = %{"code" => "0", "data" => [], "msg" => ""}

      requests = collector()

      assert {:ok, []} =
               Unified.call(
                 private_exchange(),
                 :fetch_my_trades,
                 "fetchMyTrades",
                 %{"symbol" => "BTC/USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_get!(requests, "/api/v5/trade/fills", %{"instId" => "BTC-USDT"})
    end

    # OKX names the fills window `begin`/`end` (ms), never `since`. An unmapped
    # `since` is not rejected — it is ignored — so the caller's window would be
    # silently dropped on this deliberately short 3-day route.
    test "fetch_my_trades maps unified since to OKX begin and keeps limit" do
      body = %{"code" => "0", "data" => [], "msg" => ""}

      requests = collector()

      assert {:ok, []} =
               Unified.call(
                 private_exchange(),
                 :fetch_my_trades,
                 "fetchMyTrades",
                 %{"symbol" => "BTC/USDT", "since" => 1_700_000_000_000, "limit" => 5},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_get!(requests, "/api/v5/trade/fills", %{
        "instId" => "BTC-USDT",
        "begin" => "1700000000000",
        "limit" => "5"
      })
    end

    test "endpoint_selection defaults pin singular trade/order, amend-order, and asset withdrawal" do
      ex = Exchange.new!("okx")
      assert ex.endpoint_selection["createOrder"]["default"] == "trade/order"
      assert ex.endpoint_selection["editOrder"]["default"] == "trade/amend-order"
      assert ex.endpoint_selection["withdraw"]["default"] == "asset/withdrawal"

      [config] = Bourse.Okx.__unified_endpoint__(:fetch_my_trades)
      assert config.path == "trade/fills"
    end

    test "withdraw selects the funding write route instead of the currencies read route" do
      venue_error = %{"code" => "50038", "data" => [], "msg" => "Demo trading unavailable"}
      requests = collector()

      assert {:error, %Bourse.Error{code: "50038"}} =
               Unified.call(
                 private_exchange(),
                 :withdraw,
                 "withdraw",
                 %{"code" => "USDT", "amount" => 1, "address" => "invalid-address"},
                 plug: {Req.Test, stub_json(requests, venue_error)}
               )

      # amt is a documented String on POST /api/v5/asset/withdrawal (C-T484b).
      assert_post!(requests, "/api/v5/asset/withdrawal", %{
        "amt" => "1",
        "ccy" => "USDT",
        "dest" => "4",
        "toAddr" => "invalid-address"
      })
    end

    test "withdraw maps unified network to composite chain and stringifies amt/fee" do
      venue_error = %{"code" => "50120", "data" => [], "msg" => "API key doesn't have permission"}
      requests = collector()

      assert {:error, %Bourse.Error{code: "50120"}} =
               Unified.call(
                 private_exchange(),
                 :withdraw,
                 "withdraw",
                 %{
                   "code" => "USDT",
                   "amount" => 5,
                   "address" => "TTsY9uu2Y3aXXXXXscA4v",
                   "network" => "TRC20",
                   "fee" => 1
                 },
                 plug: {Req.Test, stub_json(requests, venue_error)}
               )

      assert_post!(requests, "/api/v5/asset/withdrawal", %{
        "amt" => "5",
        "ccy" => "USDT",
        "chain" => "USDT-TRC20",
        "dest" => "4",
        "fee" => "1",
        "toAddr" => "TTsY9uu2Y3aXXXXXscA4v"
      })

      # network must not ride through — OKX would ignore it and target the default chain.
      body = RequestCollector.json_body!(requests)
      refute Map.has_key?(body, "network")
    end

    test "fetchDepositAddress and fetchWithdrawals rename code to ccy" do
      deposit_body =
        deposit_address_body([
          %{
            "ccy" => "USDT",
            "chain" => "USDT-TRC20",
            "addr" => "TXtvfb7cdrn6VX9H49mgio8bUxZ3DGfvYF",
            "selected" => true
          }
        ])

      deposit_requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :fetch_deposit_address,
                 "fetchDepositAddress",
                 %{"code" => "USDT"},
                 plug: {Req.Test, stub_json(deposit_requests, deposit_body)}
               )

      assert_get!(deposit_requests, "/api/v5/asset/deposit-address", %{"ccy" => "USDT"})

      withdrawal_requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :fetch_withdrawals,
                 "fetchWithdrawals",
                 %{"code" => "USDT"},
                 plug: {Req.Test, stub_json(withdrawal_requests, %{"code" => "0", "msg" => "", "data" => []})}
               )

      assert_get!(withdrawal_requests, "/api/v5/asset/withdrawal-history", %{"ccy" => "USDT"})
    end

    test "fetchFundingHistory derives instType/ctType/ccy from a linear swap symbol" do
      empty = %{"code" => "0", "msg" => "", "data" => []}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, stub_json(requests, empty)}
               )

      assert_get!(requests, "/api/v5/account/bills-archive", %{
        "type" => "8",
        "instType" => "SWAP",
        "ctType" => "linear",
        "ccy" => "USDT"
      })
    end

    test "fetchFundingHistory derives inverse ctType and base ccy" do
      empty = %{"code" => "0", "msg" => "", "data" => []}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 %{"symbol" => "BTC/USD:BTC"},
                 plug: {Req.Test, stub_json(requests, empty)}
               )

      assert_get!(requests, "/api/v5/account/bills-archive", %{
        "type" => "8",
        "instType" => "SWAP",
        "ctType" => "inverse",
        "ccy" => "BTC"
      })
    end
  end

  describe "normal batch order request builds (task 361)" do
    test "create_orders posts an array of individually shaped normal-order rows" do
      ack = %{
        "code" => "0",
        "data" => [
          %{"clOrdId" => "task361-a", "ordId" => "1", "sCode" => "0", "sMsg" => ""},
          %{"clOrdId" => "task361-b", "ordId" => "2", "sCode" => "0", "sMsg" => ""}
        ],
        "msg" => ""
      }

      expected_body = [
        %{
          "instId" => "BTC-USDT",
          "tdMode" => "cash",
          "side" => "buy",
          "ordType" => "limit",
          "sz" => "0.0001",
          "px" => "25000",
          "clOrdId" => "task361-a",
          "stpMode" => "cancel_maker"
        },
        %{
          "instId" => "BTC-USDT-SWAP",
          "tdMode" => "cross",
          "side" => "sell",
          "ordType" => "post_only",
          "sz" => "1",
          "px" => "27000",
          "clOrdId" => "task361-b",
          "posSide" => "short"
        }
      ]

      requests = collector()

      assert {:ok, [_first, _second]} =
               Unified.call(
                 private_exchange(),
                 :create_orders,
                 "createOrders",
                 %{
                   "orders" => [
                     %{
                       "symbol" => "BTC/USDT",
                       "type" => "limit",
                       "side" => "buy",
                       "amount" => 0.0001,
                       "price" => 25_000,
                       "clientOrderId" => "task361-a",
                       "stpMode" => "cancel_maker"
                     },
                     %{
                       "symbol" => "BTC/USDT:USDT",
                       "type" => "limit",
                       "side" => "sell",
                       "amount" => 1,
                       "price" => 27_000,
                       "clientOrderId" => "task361-b",
                       "postOnly" => true,
                       "posSide" => "short"
                     }
                   ]
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/batch-orders", expected_body)
    end

    test "edit_orders posts amend-batch-orders with one normal amend row per order" do
      ack = %{
        "code" => "0",
        "data" => [
          %{"clOrdId" => "", "ordId" => "101", "sCode" => "0", "sMsg" => ""},
          %{"clOrdId" => "task361-b", "ordId" => "", "sCode" => "0", "sMsg" => ""}
        ],
        "msg" => ""
      }

      expected_body = [
        %{"instId" => "BTC-USDT", "ordId" => "101", "newSz" => "0.01", "newPx" => "25000", "cxlOnFail" => true},
        %{"instId" => "BTC-USDT-SWAP", "clOrdId" => "task361-b", "newSz" => "2", "newPx" => "27000", "cxlOnFail" => true}
      ]

      requests = collector()

      assert {:ok, [_first, _second]} =
               Unified.call(
                 private_exchange(),
                 :edit_orders,
                 "editOrders",
                 %{
                   "orders" => [
                     %{"id" => "101", "symbol" => "BTC/USDT", "amount" => 0.01, "price" => 25_000},
                     %{
                       "clientOrderId" => "task361-b",
                       "symbol" => "BTC/USDT:USDT",
                       "amount" => 2,
                       "price" => 27_000
                     }
                   ],
                   "cxlOnFail" => true
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/amend-batch-orders", expected_body)
    end

    test "endpoint selections pin normal batch surfaces" do
      ex = Exchange.new!("okx")
      assert ex.endpoint_selection["editOrders"]["default"] == "trade/amend-batch-orders"

      [config] = Bourse.Okx.__unified_endpoint__(:edit_orders)
      assert config.path == "trade/amend-batch-orders"
    end

    # A native key that the row builder neither renames nor derives must still reach
    # the wire verbatim. Dropping one is silent: OKX ignores unknown members, so an
    # attached TP/SL or self-trade-prevention choice would vanish without an error.
    test "native normal-order option keys pass through the row builder unshaped" do
      row =
        RequestShape.apply(
          %{
            "symbol" => "BTC/USDT",
            "side" => "buy",
            "type" => "limit",
            "amount" => 1,
            "price" => 25_000,
            "attachAlgoOrds" => [%{"tpTriggerPx" => "30000", "tpOrdPx" => "-1"}],
            "banAmend" => true,
            "stpId" => "1",
            "stpMode" => "cancel_maker",
            "tag" => "task361"
          },
          private_exchange(),
          "createOrder"
        )

      assert row["attachAlgoOrds"] == [%{"tpTriggerPx" => "30000", "tpOrdPx" => "-1"}]
      assert row["banAmend"] == true
      assert row["stpId"] == "1"
      assert row["stpMode"] == "cancel_maker"
      assert row["tag"] == "task361"
    end
  end

  test "OKX request-shape helpers preserve their authored non-order contracts" do
    exchange = private_exchange()

    assert %{"instType" => "SPOT"} = RequestShape.apply(%{}, exchange, "fetchTickers")
    assert %{"instType" => "SWAP"} = RequestShape.apply(%{}, exchange, "fetchMarkPrices")
    assert %{"instType" => "SWAP"} = RequestShape.apply(%{}, exchange, "fetchOpenInterests")

    assert %{"instId" => "BTC/USDT", "instType" => "SPOT", "state" => "filled"} =
             RequestShape.apply(%{"symbol" => "BTC/USDT"}, exchange, "fetchClosedOrders")

    assert %{"from" => "6", "to" => "18"} =
             RequestShape.apply(
               %{"from_account" => "funding", "to_account" => "spot"},
               exchange,
               "transfer"
             )

    assert %{"transId" => "42"} = RequestShape.apply(%{"id" => "42", "code" => "USDT"}, exchange, "fetchTransfer")

    assert %{"subType" => "160"} =
             RequestShape.apply(%{"type" => "add"}, exchange, "fetchMarginAdjustmentHistory")
  end

  describe "order-read and market-with-cost request builds (task 483)" do
    test "plain order reads rename symbol and pin their documented state" do
      empty_orders = %{"code" => "0", "data" => [], "msg" => ""}

      cases = [
        {:fetch_open_orders, "fetchOpenOrders", %{"symbol" => "BTC/USDT"}, "/api/v5/trade/orders-pending",
         %{"instId" => "BTC-USDT"}},
        {:fetch_closed_orders, "fetchClosedOrders", %{"symbol" => "BTC/USDT:USDT"}, "/api/v5/trade/orders-history",
         %{"instId" => "BTC-USDT-SWAP", "instType" => "SWAP", "state" => "filled"}},
        {:fetch_canceled_orders, "fetchCanceledOrders", %{"symbol" => "BTC/USDT"}, "/api/v5/trade/orders-history",
         %{"instId" => "BTC-USDT", "instType" => "SPOT", "state" => "canceled"}}
      ]

      for {method, js_name, params, path, query} <- cases do
        requests = collector()

        assert {:ok, []} =
                 Unified.call(private_exchange(), method, js_name, params,
                   plug: {Req.Test, stub_json(requests, empty_orders)}
                 )

        assert_get!(requests, path, query)
      end
    end

    test "algo order reads select the algo schemas and their native state" do
      empty_orders = %{"code" => "0", "data" => [], "msg" => ""}

      cases = [
        {:fetch_open_orders, "fetchOpenOrders", %{"symbol" => "BTC/USDT:USDT", "trailing" => true},
         "/api/v5/trade/orders-algo-pending", %{"instId" => "BTC-USDT-SWAP", "ordType" => "move_order_stop"}},
        {:fetch_closed_orders, "fetchClosedOrders", %{"stop" => true}, "/api/v5/trade/orders-algo-history",
         %{"instType" => "SPOT", "ordType" => "conditional", "state" => "effective"}},
        {:fetch_canceled_orders, "fetchCanceledOrders", %{"trigger" => true}, "/api/v5/trade/orders-algo-history",
         %{"instType" => "SPOT", "ordType" => "trigger", "state" => "canceled"}}
      ]

      for {method, js_name, params, path, query} <- cases do
        requests = collector()

        assert {:ok, []} =
                 Unified.call(private_exchange(), method, js_name, params,
                   plug: {Req.Test, stub_json(requests, empty_orders)}
                 )

        assert_get!(requests, path, query)
      end
    end

    test "archive history and algo detail use the endpoint-specific identifiers" do
      empty_orders = %{"code" => "0", "data" => [], "msg" => ""}

      archive_requests = collector()

      assert {:ok, []} =
               Unified.call(
                 private_exchange(),
                 :fetch_closed_orders,
                 "fetchClosedOrders",
                 %{
                   "symbol" => "BTC/USDT:USDT",
                   "limit" => 1,
                   "method" => "privateGetTradeOrdersHistoryArchive"
                 },
                 plug: {Req.Test, stub_json(archive_requests, empty_orders)}
               )

      assert_get!(archive_requests, "/api/v5/trade/orders-history-archive", %{
        "instId" => "BTC-USDT-SWAP",
        "instType" => "SWAP",
        "limit" => "1",
        "state" => "filled"
      })

      algo_requests = collector()

      assert {:error, %Bourse.Error{type: :order_not_found}} =
               Unified.call(
                 private_exchange(),
                 :fetch_order,
                 "fetchOrder",
                 %{"id" => "999", "symbol" => "BTC/USDT:USDT", "stop" => true},
                 plug: {Req.Test, stub_json(algo_requests, empty_orders)}
               )

      assert_get!(algo_requests, "/api/v5/trade/order-algo", %{"algoId" => "999", "instId" => "BTC-USDT-SWAP"})
    end

    test "market orders with cost reach singular place-order with quote sizing on spot" do
      acknowledgement = %{
        "code" => "0",
        "data" => [%{"clOrdId" => "", "ordId" => "123", "sCode" => "0", "sMsg" => ""}],
        "msg" => ""
      }

      for {method, js_name, side} <- [
            {:create_market_buy_order_with_cost, "createMarketBuyOrderWithCost", "buy"},
            {:create_market_sell_order_with_cost, "createMarketSellOrderWithCost", "sell"}
          ] do
        requests = collector()

        assert {:ok, %Bourse.Order{id: "123"}} =
                 Unified.call(private_exchange(), method, js_name, %{"symbol" => "BTC/USDT", "cost" => 10},
                   plug: {Req.Test, stub_json(requests, acknowledgement)}
                 )

        assert_post!(requests, "/api/v5/trade/order", %{
          "instId" => "BTC-USDT",
          "ordType" => "market",
          "side" => side,
          "sz" => "10",
          "tdMode" => "cash",
          "tgtCcy" => "quote_ccy"
        })
      end
    end

    # OKX documents tgtCcy as SPOT-market-order-only, so a derivative `sz` is a
    # contract count. Sizing a swap by `cost` would silently place a
    # wrong-sized order, so the build refuses instead of guessing.
    test "market orders with cost refuse derivatives instead of sizing cost as contracts" do
      exchange = private_exchange()

      for js_name <- ["createMarketBuyOrderWithCost", "createMarketSellOrderWithCost"] do
        assert_raise ArgumentError, ~r/SPOT-only/, fn ->
          RequestShape.apply(%{"symbol" => "BTC/USDT:USDT", "cost" => 10}, exchange, js_name)
        end
      end
    end
  end

  describe "cancelOrder endpoint selection (task 357)" do
    test "plain cancel_order posts trade/cancel-order with instId/ordId body" do
      # Fake id only — never a real resting order. Business response is order-missing.
      missing = %{
        "code" => "1",
        "data" => [
          %{
            "clOrdId" => "",
            "ordId" => "999999999999999999",
            "sCode" => "51400",
            "sMsg" => "Order cancellation failed as the order has been filled, canceled or does not exist"
          }
        ],
        "msg" => "All operations failed"
      }

      requests = collector()

      assert {:error, %Bourse.Error{} = error} =
               Unified.call(
                 private_exchange(),
                 :cancel_order,
                 "cancelOrder",
                 %{"id" => "999999999999999999", "symbol" => "BTC/USDT"},
                 plug: {Req.Test, stub_json(requests, missing)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-order", %{
        "instId" => "BTC-USDT",
        "ordId" => "999999999999999999"
      })

      # Must not surface cancel-algos schema rejection (50002 Incorrect json data format).
      refute error.message && String.contains?(to_string(error.message), "50002")
      refute error.message && String.contains?(to_string(error.message), "Incorrect json")
    end

    test "stop cancel_order selects trade/cancel-algos with array body" do
      # Fake algo id only. Venue business error (algo missing) — never 50002 schema reject.
      missing = %{
        "code" => "1",
        "data" => [
          %{
            "algoId" => "641788035268431872",
            "sCode" => "51400",
            "sMsg" => "Cancellation failed as the order does not exist"
          }
        ],
        "msg" => "All operations failed"
      }

      requests = collector()

      assert {:error, %Bourse.Error{} = error} =
               Unified.call(
                 private_exchange(),
                 :cancel_order,
                 "cancelOrder",
                 %{"id" => "641788035268431872", "symbol" => "LTC/USDT:USDT", "stop" => true},
                 plug: {Req.Test, stub_json(requests, missing)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-algos", [
        %{"algoId" => "641788035268431872", "instId" => "LTC-USDT-SWAP"}
      ])

      refute error.message && String.contains?(to_string(error.message), "50002")
      refute error.message && String.contains?(to_string(error.message), "Incorrect json")
    end

    test "trigger cancel_order posts cancel-algos array body not object" do
      missing = %{
        "code" => "1",
        "data" => [
          %{
            "algoId" => "999888777666555444",
            "sCode" => "51400",
            "sMsg" => "Cancellation failed as the order does not exist"
          }
        ],
        "msg" => "All operations failed"
      }

      requests = collector()

      assert {:error, %Bourse.Error{} = error} =
               Unified.call(
                 private_exchange(),
                 :cancel_order,
                 "cancelOrder",
                 %{"id" => "999888777666555444", "symbol" => "BTC/USDT", "trigger" => true},
                 plug: {Req.Test, stub_json(requests, missing)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-algos", [
        %{"algoId" => "999888777666555444", "instId" => "BTC-USDT"}
      ])

      refute error.message && String.contains?(to_string(error.message), "50002")
    end

    test "endpoint_selection default is trade/cancel-order" do
      selection = Exchange.new!("okx").endpoint_selection["cancelOrder"]
      assert selection["default"] == "trade/cancel-order"
      assert selection["consume"] == ["stop", "trailing", "trigger"]
    end
  end

  describe "cancelOrders / cancelOrdersForSymbols endpoint selection (task 359)" do
    test "plain cancel_orders posts trade/cancel-batch-orders with array body" do
      # Fake ids only — never real resting orders.
      missing = %{
        "code" => "1",
        "data" => [
          %{
            "clOrdId" => "",
            "ordId" => "999999999999999001",
            "sCode" => "51400",
            "sMsg" => "Order cancellation failed as the order has been filled, canceled or does not exist"
          },
          %{
            "clOrdId" => "",
            "ordId" => "999999999999999002",
            "sCode" => "51400",
            "sMsg" => "Order cancellation failed as the order has been filled, canceled or does not exist"
          }
        ],
        "msg" => "All operations failed"
      }

      expected_body = [
        %{"ordId" => "999999999999999001", "instId" => "LTC-USDT"},
        %{"ordId" => "999999999999999002", "instId" => "LTC-USDT"}
      ]

      requests = collector()

      assert {:error, %Bourse.Error{} = error} =
               Unified.call(
                 private_exchange(),
                 :cancel_orders,
                 "cancelOrders",
                 %{"ids" => ["999999999999999001", "999999999999999002"], "symbol" => "LTC/USDT"},
                 plug: {Req.Test, stub_json(requests, missing)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-batch-orders", expected_body)

      refute error.message && String.contains?(to_string(error.message), "50002")
      refute error.message && String.contains?(to_string(error.message), "Incorrect json")
    end

    test "stop cancel_orders selects trade/cancel-algos with algoId array body" do
      missing = %{
        "code" => "1",
        "data" => [
          %{
            "algoId" => "635561454703480832",
            "sCode" => "51400",
            "sMsg" => "Cancellation failed as the order does not exist"
          }
        ],
        "msg" => "All operations failed"
      }

      expected_body = [
        %{"algoId" => "635561454703480832", "instId" => "LTC-USDT"},
        %{"algoId" => "637051086087655424", "instId" => "LTC-USDT"}
      ]

      requests = collector()

      assert {:error, %Bourse.Error{} = error} =
               Unified.call(
                 private_exchange(),
                 :cancel_orders,
                 "cancelOrders",
                 %{
                   "ids" => ["635561454703480832", "637051086087655424"],
                   "symbol" => "LTC/USDT",
                   "stop" => true
                 },
                 plug: {Req.Test, stub_json(requests, missing)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-algos", expected_body)

      refute error.message && String.contains?(to_string(error.message), "50002")
    end

    test "trailing and trigger cancel_orders select trade/cancel-algos" do
      missing = %{"code" => "1", "data" => [], "msg" => "All operations failed"}

      for flag <- ["trailing", "trigger"] do
        requests = collector()

        assert {:error, %Bourse.Error{}} =
                 Unified.call(
                   private_exchange(),
                   :cancel_orders,
                   "cancelOrders",
                   %{"ids" => ["635561454703480832"], "symbol" => "LTC/USDT", flag => true},
                   plug: {Req.Test, stub_json(requests, missing)}
                 )

        assert_post!(requests, "/api/v5/trade/cancel-algos", [
          %{"algoId" => "635561454703480832", "instId" => "LTC-USDT"}
        ])
      end
    end

    test "plain cancel_orders_for_symbols posts trade/cancel-batch-orders" do
      missing = %{
        "code" => "1",
        "data" => [
          %{
            "clOrdId" => "",
            "ordId" => "1388361822563405824",
            "sCode" => "51400",
            "sMsg" => "Order cancellation failed as the order has been filled, canceled or does not exist"
          }
        ],
        "msg" => "All operations failed"
      }

      expected_body = [
        %{"instId" => "LTC-USDT-SWAP", "ordId" => "1388361822563405824"},
        %{"instId" => "ADA-USDT", "ordId" => "1388360134171496448"}
      ]

      requests = collector()

      assert {:error, %Bourse.Error{} = error} =
               Unified.call(
                 private_exchange(),
                 :cancel_orders_for_symbols,
                 "cancelOrdersForSymbols",
                 %{
                   "orders" => [
                     %{"id" => "1388361822563405824", "symbol" => "LTC/USDT:USDT"},
                     %{"id" => "1388360134171496448", "symbol" => "ADA/USDT"}
                   ]
                 },
                 plug: {Req.Test, stub_json(requests, missing)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-batch-orders", expected_body)

      refute error.message && String.contains?(to_string(error.message), "50002")
    end

    test "stop cancel_orders_for_symbols posts trade/cancel-algos" do
      missing = %{"code" => "1", "data" => [], "msg" => "All operations failed"}
      requests = collector()

      assert {:error, %Bourse.Error{}} =
               Unified.call(
                 private_exchange(),
                 :cancel_orders_for_symbols,
                 "cancelOrdersForSymbols",
                 %{
                   "orders" => [%{"id" => "1388361822563405824", "symbol" => "LTC/USDT:USDT"}],
                   "stop" => true
                 },
                 plug: {Req.Test, stub_json(requests, missing)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-algos", [
        %{"algoId" => "1388361822563405824", "instId" => "LTC-USDT-SWAP"}
      ])
    end

    test "plain cancel_orders uses clOrdId rows when client ids are supplied" do
      missing = %{
        "code" => "1",
        "data" => [%{"clOrdId" => "task361-cancel", "ordId" => "", "sCode" => "51400", "sMsg" => "Order does not exist"}],
        "msg" => "All operations failed"
      }

      requests = collector()

      assert {:error, %Bourse.Error{}} =
               Unified.call(
                 private_exchange(),
                 :cancel_orders,
                 "cancelOrders",
                 %{"clOrdId" => ["task361-cancel"], "symbol" => "BTC/USDT"},
                 plug: {Req.Test, stub_json(requests, missing)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-batch-orders", [
        %{"clOrdId" => "task361-cancel", "instId" => "BTC-USDT"}
      ])
    end

    test "endpoint_selection defaults are trade/cancel-batch-orders" do
      ex = Exchange.new!("okx")

      for method <- ["cancelOrders", "cancelOrdersForSymbols"] do
        selection = ex.endpoint_selection[method]
        assert selection["default"] == "trade/cancel-batch-orders"
        assert selection["consume"] == ["stop", "trailing", "trigger"]
      end
    end
  end

  # Task 440 made an ordering load-bearing across every okx method that carries
  # both an authored `endpoints.request.endpoint_selection` slice and a
  # `describe().options.<jsName>.method` default: the authored slice wins, and
  # the configured method is only a default. Reverting that order in
  # `Bourse.Unified.select_endpoint/5` must redden a test that NAMES the rule, not
  # merely one that exercises okx cancels.
  describe "endpoint-selection precedence: authored slice outranks configured options.method" do
    test "the disagreement this rule arbitrates actually exists in the okx spec" do
      ex = private_exchange()

      # Premise guard: if the spec ever stops naming a DIFFERENT endpoint than the
      # authored conditional case, the precedence tests below go vacuous without
      # failing. Pin the disagreement itself.
      assert %{"method" => "privatePostTradeCancelBatchOrders"} =
               get_in(ex.spec, ["options", "cancelOrders"])

      selection = ex.endpoint_selection["cancelOrders"]
      assert selection["default"] == "trade/cancel-batch-orders"

      assert Enum.any?(selection["cases"] || [], fn c ->
               c["path"] == "trade/cancel-algos"
             end)
    end

    test "an authored conditional case beats the configured method naming another endpoint" do
      requests = collector()

      assert {:error, %Bourse.Error{}} =
               Unified.call(
                 private_exchange(),
                 :cancel_orders,
                 "cancelOrders",
                 %{"ids" => ["635561454703480832"], "symbol" => "LTC/USDT", "stop" => true},
                 plug: {Req.Test, stub_json(requests, %{"code" => "1", "data" => []})}
               )

      # options.cancelOrders.method names cancel-batch-orders; the authored
      # stop-case names cancel-algos. Authored wins.
      assert_post!(requests, "/api/v5/trade/cancel-algos", [
        %{"algoId" => "635561454703480832", "instId" => "LTC-USDT"}
      ])
    end

    test "with no case firing, the authored default agrees with the configured method" do
      requests = collector()

      assert {:error, %Bourse.Error{}} =
               Unified.call(
                 private_exchange(),
                 :cancel_orders,
                 "cancelOrders",
                 %{"ids" => ["635561454703480832"], "symbol" => "LTC/USDT"},
                 plug: {Req.Test, stub_json(requests, %{"code" => "1", "data" => []})}
               )

      # Demoting options.method to a default must not move the no-case path.
      assert_post!(requests, "/api/v5/trade/cancel-batch-orders", [
        %{"instId" => "LTC-USDT", "ordId" => "635561454703480832"}
      ])
    end
  end

  # Task 389. The six CCXT compatibility fixtures (#18-23) cover the happy paths; these pin the
  # branches they do NOT reach — tag-carrier precedence, an unaliased chain, and a
  # requested-network miss. Offline behaviour pins (tier 2): the reality axis for this
  # family is the prod-verification ledger, because OKX demo cannot serve the endpoint.
  describe "deposit-address response semantics (task 389)" do
    test "the selected row wins over stale rows sharing a chain" do
      body =
        deposit_address_body([
          %{"chain" => "USDT-TRC20", "ccy" => "USDT", "addr" => "stale-one", "selected" => false},
          %{"chain" => "USDT-TRC20", "ccy" => "USDT", "addr" => "current", "selected" => true},
          %{"chain" => "USDT-TRC20", "ccy" => "USDT", "addr" => "stale-two", "selected" => false}
        ])

      requests = collector()

      assert {:ok, address} = fetch_deposit_address(requests, body, "USDT", network: "TRC20")
      assert_path!(requests, "/api/v5/asset/deposit-address")
      assert address.address == "current"
      assert address.network == "TRC20"
    end

    test "the tag falls back tag -> pmtId -> memo -> addrEx.comment" do
      carriers = [
        {%{"tag" => "from-tag", "pmtId" => "x", "memo" => "y", "addrEx" => %{"comment" => "z"}}, "from-tag"},
        {%{"pmtId" => "from-pmt", "memo" => "y", "addrEx" => %{"comment" => "z"}}, "from-pmt"},
        {%{"memo" => "from-memo", "addrEx" => %{"comment" => "z"}}, "from-memo"},
        {%{"addrEx" => %{"comment" => "from-addr-ex"}}, "from-addr-ex"},
        {%{}, nil}
      ]

      for {carrier, expected} <- carriers do
        row =
          Map.merge(carrier, %{
            "chain" => "USDT-TON",
            "ccy" => "USDT",
            "addr" => "addr-1",
            "selected" => true
          })

        requests = collector()

        assert {:ok, address} = fetch_deposit_address(requests, deposit_address_body([row]), "USDT", network: "TON")
        assert_path!(requests, "/api/v5/asset/deposit-address")
        assert address.tag == expected
      end
    end

    test "an unaliased chain yields a nil network and is dropped from the by-network dict" do
      body =
        deposit_address_body([
          %{"chain" => "USDT-TRC20", "ccy" => "USDT", "addr" => "known", "selected" => true},
          %{"chain" => "USDT-NotAChainWeKnow", "ccy" => "USDT", "addr" => "unknown", "selected" => true}
        ])

      requests = collector()

      assert {:ok, by_network} =
               Unified.call(
                 private_exchange(),
                 :fetch_deposit_addresses_by_network,
                 "fetchDepositAddressesByNetwork",
                 %{"code" => "USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/asset/deposit-address")

      # The raw chain id is never emitted as if it were a unified network code.
      assert Map.keys(by_network) == ["TRC20"]
      refute Enum.any?(by_network, fn {_code, addr} -> addr.address == "unknown" end)
    end

    test "a requested network with no matching row fails instead of returning another chain" do
      body =
        deposit_address_body([
          %{"chain" => "USDT-TRC20", "ccy" => "USDT", "addr" => "trc20-addr", "selected" => true}
        ])

      # Not merely "an error": the TRC20 address must never be substituted for the
      # ERC20 one the caller asked for (carve C-T389e).
      requests = collector()

      assert {:error, %Bourse.Error{} = error} = fetch_deposit_address(requests, body, "USDT", network: "ERC20")
      assert_path!(requests, "/api/v5/asset/deposit-address")
      assert error.message =~ "requested_row_not_found"
      assert error.raw == "ERC20"
    end

    test "no requested network falls back to the authored default network" do
      # ERC20 is listed first; the USDT default (TRC20) must still win.
      body =
        deposit_address_body([
          %{"chain" => "USDT-ERC20", "ccy" => "USDT", "addr" => "erc20-addr", "selected" => true},
          %{"chain" => "USDT-TRC20", "ccy" => "USDT", "addr" => "trc20-addr", "selected" => true}
        ])

      requests = collector()

      assert {:ok, address} = fetch_deposit_address(requests, body, "USDT", [])
      assert_path!(requests, "/api/v5/asset/deposit-address")
      assert address.network == "TRC20"
      assert address.address == "trc20-addr"
    end

    test "the deposit-address alias table matches the currency slice verbatim" do
      field_maps = Bourse.Okx.__field_maps__()

      deposit_aliases = get_in(field_maps, ["deposit_address", "field_map", "network", "network_aliases"])
      currency_aliases = get_in(field_maps, ["currency", "field_map", "networks", "network_aliases"])

      # Both slices project the same Bourse `currency['networks']` + networkIdToCode
      # resolution. Drift between them would make one read disagree with the other
      # about what network an address is on (carve C-T389b).
      assert deposit_aliases == currency_aliases
      assert deposit_aliases["USDT-TRC20"] == "TRC20"
      assert deposit_aliases["ETH-ERC20"] == "ETH"
      assert deposit_aliases["ETH-Optimism"] == "OP"
      assert deposit_aliases["USDT-Optimism"] == "OP"
      assert deposit_aliases["POL-Polygon"] == "MATIC"
    end
  end

  defp deposit_address_body(rows), do: %{"code" => "0", "msg" => "", "data" => rows}

  defp fetch_deposit_address(requests, body, code, opts) do
    params = opts |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("code", code)

    Unified.call(
      private_exchange(),
      :fetch_deposit_address,
      "fetchDepositAddress",
      params,
      plug: {Req.Test, stub_json(requests, body)}
    )
  end

  defp public_exchange do
    Exchange.new!("okx")
  end

  describe "algo / TP-SL / trailing / cancelAllOrdersAfter request builds (task 387)" do
    test "endpoint_selection routes algo families to order-algo and amend-algos" do
      ex = Exchange.new!("okx")
      create = ex.endpoint_selection["createOrder"]
      edit = ex.endpoint_selection["editOrder"]

      assert create["default"] == "trade/order"

      assert Enum.any?(
               create["cases"],
               &(&1["path"] == "trade/order-algo" and &1["when"] == %{"triggerPrice" => "present"})
             )

      assert Enum.any?(
               create["cases"],
               &(&1["path"] == "trade/order-algo" and &1["when"] == %{"stopLossPrice" => "present"})
             )

      assert Enum.any?(
               create["cases"],
               &(&1["path"] == "trade/order-algo" and &1["when"] == %{"trailingPercent" => "present"})
             )

      assert edit["default"] == "trade/amend-order"
      assert Enum.any?(edit["cases"], &(&1["path"] == "trade/amend-algos" and &1["when"] == %{"type" => "conditional"}))
      assert Enum.any?(create["cases"], &(&1["path"] == "trade/order-algo" and &1["when"] == %{"type" => "oco"}))
      assert Enum.any?(edit["cases"], &(&1["path"] == "trade/amend-algos" and &1["when"] == %{"type" => "oco"}))

      assert Enum.any?(
               edit["cases"],
               &(&1["path"] == "trade/amend-algos" and &1["when"] == %{"newTriggerPx" => "present"})
             )
    end

    test "trigger create_order posts trade/order-algo with triggerPx and orderPx" do
      ack = %{"code" => "0", "data" => [%{"algoId" => "1", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "LTC/USDT:USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 1,
                   "price" => 50,
                   "stopPrice" => 55,
                   "triggerPxType" => "mark",
                   "clientOrderId" => "algo-trigger-1",
                   "posSide" => "long"
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order-algo", %{
        "instId" => "LTC-USDT-SWAP",
        "tdMode" => "cross",
        "side" => "buy",
        "ordType" => "trigger",
        "sz" => "1",
        "triggerPx" => "55",
        "orderPx" => "50",
        "triggerPxType" => "mark",
        "algoClOrdId" => "algo-trigger-1",
        "posSide" => "long"
      })
    end

    test "conditional takeProfitPrice create_order posts trade/order-algo" do
      ack = %{"code" => "0", "data" => [%{"algoId" => "2", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "LTC/USDT:USDT",
                   "type" => "limit",
                   "side" => "sell",
                   "amount" => 1,
                   "price" => 100,
                   "takeProfitPrice" => 105,
                   "posSide" => "long"
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order-algo", %{
        "instId" => "LTC-USDT-SWAP",
        "tdMode" => "cross",
        "side" => "sell",
        "ordType" => "conditional",
        "sz" => "1",
        "tpTriggerPx" => "105",
        "tpOrdPx" => "100",
        "tpTriggerPxType" => "last",
        "posSide" => "long"
      })
    end

    test "both standalone TP and SL prices create an OCO with string native order prices" do
      ack = %{"code" => "0", "data" => [%{"algoId" => "2", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "LTC/USDT:USDT",
                   "type" => "limit",
                   "side" => "sell",
                   "amount" => 1,
                   "takeProfitPrice" => 105,
                   "stopLossPrice" => 95,
                   "tpOrdPx" => 104,
                   "slOrdPx" => 96
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order-algo", %{
        "instId" => "LTC-USDT-SWAP",
        "tdMode" => "cross",
        "side" => "sell",
        "ordType" => "oco",
        "sz" => "1",
        "tpTriggerPx" => "105",
        "tpOrdPx" => "104",
        "tpTriggerPxType" => "last",
        "slTriggerPx" => "95",
        "slOrdPx" => "96",
        "slTriggerPxType" => "last"
      })
    end

    test "trailingPercent create_order posts move_order_stop with callbackRatio fraction" do
      ack = %{"code" => "0", "data" => [%{"algoId" => "3", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "BTC/USDT:USDT",
                   "type" => "market",
                   "side" => "sell",
                   "amount" => 1,
                   "trailingPercent" => "0.5",
                   "trailingTriggerPrice" => 90_000,
                   "clientOrderId" => "algo-trailing-1",
                   "reduceOnly" => true,
                   "posSide" => "long"
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order-algo", %{
        "instId" => "BTC-USDT-SWAP",
        "tdMode" => "cross",
        "side" => "sell",
        "ordType" => "move_order_stop",
        "sz" => "1",
        "callbackRatio" => "0.005",
        "activePx" => "90000",
        "algoClOrdId" => "algo-trailing-1",
        "reduceOnly" => true,
        "posSide" => "long"
      })
    end

    test "attached stopLoss on a normal order stays on trade/order with attachAlgoOrds" do
      ack = %{"code" => "0", "data" => [%{"ordId" => "4", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "BTC/USDT:USDT",
                   "type" => "market",
                   "side" => "buy",
                   "amount" => 0.1,
                   "stopLoss" => %{"triggerPrice" => 100_333}
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order", %{
        "instId" => "BTC-USDT-SWAP",
        "tdMode" => "cross",
        "side" => "buy",
        "ordType" => "market",
        "sz" => "0.1",
        "attachAlgoOrds" => [
          %{"slTriggerPx" => "100333", "slOrdPx" => "-1", "slTriggerPxType" => "last"}
        ]
      })
    end

    test "createOrderWithTakeProfitAndStopLoss attaches both legs on trade/order" do
      ack = %{"code" => "0", "data" => [%{"ordId" => "5", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :create_order_with_take_profit_and_stop_loss,
                 "createOrderWithTakeProfitAndStopLoss",
                 %{
                   "symbol" => "ADA/USDT:USDT",
                   "type" => "market",
                   "side" => "buy",
                   "amount" => 5,
                   "takeProfit" => 2,
                   "stopLoss" => 0.2
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order", %{
        "instId" => "ADA-USDT-SWAP",
        "tdMode" => "cross",
        "side" => "buy",
        "ordType" => "market",
        "sz" => "5",
        "attachAlgoOrds" => [
          %{
            "slTriggerPx" => "0.2",
            "slOrdPx" => "-1",
            "slTriggerPxType" => "last",
            "tpTriggerPx" => "2",
            "tpOrdPx" => "-1",
            "tpTriggerPxType" => "last"
          }
        ]
      })
    end

    test "conditional edit_order posts amend-algos with algoId and newSl* fields" do
      ack = %{"code" => "0", "data" => [%{"algoId" => "670963589699682304", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :edit_order,
                 "editOrder",
                 %{
                   "id" => "670963589699682304",
                   "symbol" => "BTC/USDT:USDT",
                   "type" => "conditional",
                   "side" => "buy",
                   "amount" => 1,
                   "stopLossPrice" => 62_000,
                   "newSlOrdPx" => 33_000
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/amend-algos", %{
        "instId" => "BTC-USDT-SWAP",
        "algoId" => "670963589699682304",
        "newSz" => "1",
        "newSlTriggerPx" => "62000",
        "newSlOrdPx" => "33000",
        "newSlTriggerPxType" => "last"
      })
    end

    test "trigger and trailing amend use their current native field families" do
      ack = %{"code" => "0", "data" => [%{"algoId" => "7", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      trigger_requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :edit_order,
                 "editOrder",
                 %{
                   "algoId" => "7",
                   "symbol" => "BTC/USDT:USDT",
                   "newTriggerPx" => 61_000,
                   "newOrdPx" => 60_500,
                   "newTriggerPxType" => "index"
                 },
                 plug: {Req.Test, stub_json(trigger_requests, ack)}
               )

      assert_post!(trigger_requests, "/api/v5/trade/amend-algos", %{
        "instId" => "BTC-USDT-SWAP",
        "algoId" => "7",
        "newTriggerPx" => "61000",
        "newOrdPx" => "60500",
        "newTriggerPxType" => "index"
      })

      trailing_requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :edit_order,
                 "editOrder",
                 %{
                   "algoId" => "7",
                   "symbol" => "BTC/USDT:USDT",
                   "type" => "move_order_stop",
                   "trailingPercent" => "0.5",
                   "trailingTriggerPrice" => 90_000
                 },
                 plug: {Req.Test, stub_json(trailing_requests, ack)}
               )

      assert_post!(trailing_requests, "/api/v5/trade/amend-algos", %{
        "instId" => "BTC-USDT-SWAP",
        "algoId" => "7",
        "newCallbackRatio" => "0.005",
        "newActivePx" => "90000"
      })
    end

    test "normal attached TP amend nests current attachAlgoOrds schema" do
      ack = %{"code" => "0", "data" => [%{"ordId" => "8", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :edit_order,
                 "editOrder",
                 %{
                   "id" => "8",
                   "symbol" => "BTC/USDT:USDT",
                   "type" => "limit",
                   "takeProfit" => %{"triggerPrice" => 65_000, "orderPrice" => 64_900},
                   "attachAlgoId" => "9"
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/amend-order", %{
        "instId" => "BTC-USDT-SWAP",
        "ordId" => "8",
        "attachAlgoOrds" => [
          %{
            "attachAlgoId" => "9",
            "newTpTriggerPx" => "65000",
            "newTpOrdPx" => "64900",
            "newTpTriggerPxType" => "last",
            "newTpOrdKind" => "condition"
          }
        ]
      })
    end

    test "cancelAllOrdersAfter maps timeout ms to timeOut seconds" do
      body = %{"code" => "0", "data" => [%{"triggerTime" => "0", "ts" => "0"}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :cancel_all_orders_after,
                 "cancelAllOrdersAfter",
                 %{"timeout" => 10_000, "tag" => "risk-switch"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_post!(requests, "/api/v5/trade/cancel-all-after", %{"timeOut" => "10", "tag" => "risk-switch"})
    end

    test "closeFraction omits sz on conditional algo place" do
      ack = %{"code" => "0", "data" => [%{"algoId" => "6", "sCode" => "0", "sMsg" => ""}], "msg" => ""}
      requests = collector()

      assert {:ok, _} =
               Unified.call(
                 private_exchange(),
                 :create_order,
                 "createOrder",
                 %{
                   "symbol" => "LTC/USDT:USDT",
                   "type" => "market",
                   "side" => "sell",
                   "amount" => 0,
                   "takeProfitPrice" => 120,
                   "closeFraction" => 1,
                   "reduceOnly" => true
                 },
                 plug: {Req.Test, stub_json(requests, ack)}
               )

      assert_post!(requests, "/api/v5/trade/order-algo", %{
        "instId" => "LTC-USDT-SWAP",
        "tdMode" => "cross",
        "side" => "sell",
        "ordType" => "conditional",
        "tpTriggerPx" => "120",
        "tpOrdPx" => "-1",
        "tpTriggerPxType" => "last",
        "closeFraction" => "1",
        "reduceOnly" => true
      })
    end
  end

  # Task 364 — OKX position response semantics. Computed fields (notional, IM/MM %,
  # collateral, percentage, net-mode side) are domain-asserted, not just shape-matched.
  describe "position response semantics (task 364)" do
    test "linear cross open position computes collateral IM/MM percentages and percentage PnL" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "653944598162657280",
            "instId" => "LTC-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "cross",
            "posSide" => "long",
            "pos" => "2",
            "avgPx" => "82.675",
            "markPx" => "101.33",
            "liqPx" => "",
            "lever" => "10",
            "imr" => "0.020266",
            "mmr" => "0.00131729",
            "upl" => "0.03731",
            "uplRatio" => "2.256425763531902",
            "notionalUsd" => "0.2027248512",
            "realizedPnl" => "-0.0154998159554622",
            "cTime" => "1706612162996",
            "uTime" => "1712390404547"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "LTC-USDT-SWAP",
            symbol: "LTC/USDT:USDT",
            contract_size: 1,
            linear: true,
            inverse: false,
            type: "swap"
          }
        ])

      requests = collector()

      assert {:ok, %Bourse.Position{} = position} =
               Unified.call(
                 exchange,
                 :fetch_position,
                 "fetchPosition",
                 %{"symbol" => "LTC/USDT:USDT"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert_path!(requests, "/api/v5/account/positions")
      assert position.id == "653944598162657280"
      assert position.symbol == "LTC/USDT:USDT"
      assert position.side == "long"
      assert position.hedged == true
      assert position.contracts == 2.0
      assert position.contract_size == 1.0
      assert position.notional == 0.2027248512
      assert position.entry_price == 82.675
      assert position.mark_price == 101.33
      assert position.leverage == 10.0
      assert position.margin_mode == "cross"
      assert position.unrealized_pnl == 0.03731
      # cross collateral = imr + upl
      assert position.collateral == 0.057576
      assert position.initial_margin == 0.020266
      # imr/notional truncated to 4 dp
      assert position.initial_margin_percentage == 0.0999
      assert position.maintenance_margin == 0.00131729
      # (mmr/notional + 0.00005) truncated to 4 dp
      assert position.maintenance_margin_percentage == 0.0065
      assert position.margin_ratio == 0.0228
      # uplRatio * 100
      assert_in_delta position.percentage, 225.6425763531902, 1.0e-10
      assert position.liquidation_price == nil
      assert position.timestamp == 1_706_612_162_996
    end

    test "inverse isolated open position recomputes notional and IM from contracts×cs" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "3234559463547297792",
            "instId" => "BTC-USD-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "isolated",
            "posSide" => "long",
            "pos" => "1",
            "avgPx" => "92300",
            "markPx" => "92376.7",
            "liqPx" => "69536.6125000014",
            "lever" => "3",
            "imr" => "",
            "margin" => "0.0003611412062116",
            "mmr" => "0.0000043300962256",
            "upl" => "0.000000899562244",
            "uplRatio" => "0.0024908878537552",
            "notionalUsd" => "100",
            "realizedPnl" => "-0.0000005417118093",
            "cTime" => "1768899783914",
            "uTime" => "1768899783914"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "BTC-USD-SWAP",
            symbol: "BTC/USD:BTC",
            contract_size: 100,
            linear: false,
            inverse: true,
            type: "swap"
          }
        ])

      requests = collector()

      assert {:ok, %Bourse.Position{} = position} =
               Unified.call(
                 exchange,
                 :fetch_position,
                 "fetchPosition",
                 %{"symbol" => "BTC/USD:BTC"},
                 plug: {Req.Test, stub_json(requests, body)}
               )

      assert position.symbol == "BTC/USD:BTC"
      assert position.contracts == 1.0
      assert position.contract_size == 100.0
      # inverse notional = contracts * cs / mark
      assert_in_delta position.notional, 0.001082524056390843, 1.0e-15
      # isolated collateral is venue margin
      assert position.collateral == 0.0003611412062116
      # IM = (contracts * cs / entry) / lever
      assert_in_delta position.initial_margin, 0.000361141206211628, 1.0e-18
      assert_in_delta position.initial_margin_percentage, 1 / 3, 1.0e-12
      assert position.liquidation_price == 69_536.6125000014
      assert position.margin_mode == "isolated"
    end

    test "linear isolated net position derives a short side and margin values" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "linear-isolated-short",
            "instId" => "ETH-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "isolated",
            "posSide" => "net",
            "pos" => "-2",
            "avgPx" => "2000",
            "markPx" => "1990",
            "lever" => "4",
            "margin" => "100",
            "mmr" => "2",
            "upl" => "-1",
            "uplRatio" => "-0.01",
            "notionalUsd" => "400",
            "cTime" => "1700000000000",
            "uTime" => "1700000000001"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "ETH-USDT-SWAP",
            symbol: "ETH/USDT:USDT",
            contract_size: 0.1,
            linear: true,
            inverse: false,
            type: "swap"
          }
        ])

      assert {:ok, %Bourse.Position{} = position} =
               Unified.call(
                 exchange,
                 :fetch_position,
                 "fetchPosition",
                 %{"symbol" => "ETH/USDT:USDT"},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert position.side == "short"
      assert position.hedged == false
      assert position.contracts == 2.0
      assert position.notional == 400.0
      assert position.initial_margin == 100.0
      assert position.initial_margin_percentage == 0.25
      assert position.collateral == 100.0
      assert position.maintenance_margin_percentage == 0.005
      assert position.margin_ratio == 0.02
      assert position.percentage == -1.0
    end

    test "sparse inverse row leaves unavailable computed values nil" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "sparse-inverse",
            "instId" => "BTC-USD-SWAP",
            "instType" => "SWAP",
            "posSide" => "net",
            "pos" => "not-a-number",
            "cTime" => "1700000000000",
            "uTime" => "1700000000001"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "BTC-USD-SWAP",
            symbol: "BTC/USD:BTC",
            type: "swap"
          }
        ])

      assert {:ok, %Bourse.Position{} = position} =
               Unified.call(
                 exchange,
                 :fetch_position,
                 "fetchPosition",
                 %{"symbol" => "BTC/USD:BTC"},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert position.side == nil
      assert position.contracts == nil
      assert position.contract_size == nil
      assert position.notional == nil
      assert position.initial_margin == nil
      assert position.initial_margin_percentage == nil
      assert position.maintenance_margin_percentage == nil
      assert position.margin_ratio == nil
    end

    test "cross position without PnL keeps imr as collateral and omits unavailable ratios" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "cross-without-pnl",
            "instId" => "SOL-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "cross",
            "posSide" => "long",
            "pos" => "1",
            "imr" => "5",
            "cTime" => "1700000000000",
            "uTime" => "1700000000001"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "SOL-USDT-SWAP",
            symbol: "SOL/USDT:USDT",
            contract_size: 1,
            linear: true,
            inverse: false,
            type: "swap"
          }
        ])

      assert {:ok, %Bourse.Position{} = position} =
               Unified.call(
                 exchange,
                 :fetch_position,
                 "fetchPosition",
                 %{"symbol" => "SOL/USDT:USDT"},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert position.collateral == 5.0
      assert position.initial_margin == 5.0
      assert position.initial_margin_percentage == nil
      assert position.maintenance_margin_percentage == nil
      assert position.margin_ratio == nil
    end

    test "position annotation preserves sparse and venue-specific fallback values" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "unknown-mode",
            "instId" => "ADA-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "portfolio",
            "posSide" => "borrow",
            "pos" => "3",
            "imr" => "7",
            "upl" => "2",
            "notionalUsd" => "30"
          },
          %{
            "posId" => "cross-without-imr",
            "instId" => "XRP-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "cross",
            "posSide" => "long",
            "pos" => "1",
            "mmr" => "1"
          },
          %{
            "posId" => "market-not-loaded",
            "instId" => "DOGE-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "cross",
            "posSide" => "long",
            "pos" => "1",
            "notionalUsd" => "10"
          },
          %{
            "posId" => "isolated-without-leverage",
            "instId" => "DOT-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "isolated",
            "posSide" => "long",
            "pos" => "1",
            "margin" => "4",
            "notionalUsd" => "20"
          },
          %{
            "posId" => "unknown-mode-with-margin",
            "instId" => "AVAX-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "portfolio",
            "posSide" => "long",
            "pos" => "1",
            "imr" => "3",
            "margin" => "6",
            "upl" => "1",
            "notionalUsd" => "30"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "ADA-USDT-SWAP",
            symbol: "ADA/USDT:USDT",
            contract_size: 1,
            linear: true,
            inverse: false,
            type: "swap"
          },
          %Bourse.Market{
            id: "XRP-USDT-SWAP",
            symbol: "XRP/USDT:USDT",
            contract_size: 1,
            linear: true,
            inverse: false,
            type: "swap"
          },
          %Bourse.Market{
            id: "DOT-USDT-SWAP",
            symbol: "DOT/USDT:USDT",
            contract_size: 1,
            linear: true,
            inverse: false,
            type: "swap"
          },
          %Bourse.Market{
            id: "AVAX-USDT-SWAP",
            symbol: "AVAX/USDT:USDT",
            contract_size: 1,
            linear: true,
            inverse: false,
            type: "swap"
          }
        ])

      assert {:ok, [unknown_mode, no_imr, no_market, isolated, margin_fallback]} =
               Unified.call(
                 exchange,
                 :fetch_positions,
                 "fetchPositions",
                 %{},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert unknown_mode.side == "borrow"
      assert unknown_mode.initial_margin == 7.0
      assert unknown_mode.initial_margin_percentage == nil
      assert unknown_mode.collateral == 9.0

      assert no_imr.initial_margin == nil
      assert no_imr.collateral == nil
      assert no_imr.maintenance_margin == 1.0
      assert no_imr.maintenance_margin_percentage == nil

      assert no_market.symbol == "DOGE/USDT:USDT"
      assert no_market.contract_size == nil
      assert no_market.notional == 10.0

      assert isolated.collateral == 4.0
      assert isolated.initial_margin == nil
      assert isolated.initial_margin_percentage == nil

      assert margin_fallback.initial_margin == 3.0
      assert margin_fallback.collateral == 6.0
    end

    test "position annotation works without a loaded market cache" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "no-market-cache",
            "instId" => "DOGE-USDT-SWAP",
            "instType" => "SWAP",
            "mgnMode" => "cross",
            "posSide" => "long",
            "pos" => "1",
            "notionalUsd" => "10"
          }
        ]
      }

      exchange = %{private_exchange() | markets: nil}

      assert {:ok, %Bourse.Position{} = position} =
               Unified.call(
                 exchange,
                 :fetch_position,
                 "fetchPosition",
                 %{"symbol" => "DOGE/USDT:USDT"},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert position.symbol == "DOGE/USDT:USDT"
      assert position.contract_size == nil
      assert position.notional == 10.0
    end

    test "position annotation handles a missing native instrument and malformed payloads" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "missing-inst-id",
            "mgnMode" => "cross",
            "posSide" => "long",
            "pos" => "1",
            "notionalUsd" => "10"
          }
        ]
      }

      exchange = %{private_exchange() | markets: nil}

      assert {:ok, %Bourse.Position{symbol: "DOGE/USDT:USDT", contract_size: nil, notional: 10.0}} =
               Unified.call(
                 exchange,
                 :fetch_position,
                 "fetchPosition",
                 %{"symbol" => "DOGE/USDT:USDT"},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert {:error, %Bourse.Error{type: :exchange_error, raw: "bad"}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_position,
                 "fetchPosition",
                 %{"code" => "0", "data" => "bad"},
                 %{},
                 :parse_position,
                 false
               )

      assert {:error, %Bourse.Error{type: :exchange_error}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_positions,
                 "fetchPositions",
                 %{"code" => "0", "data" => ["bad"]},
                 %{},
                 :parse_position,
                 true
               )
    end

    test "read parser rejects malformed margin modification envelopes" do
      exchange = private_exchange()

      assert {:error, %Bourse.Error{type: :exchange_error, raw: %{"code" => "51000"}}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :add_margin,
                 "addMargin",
                 %{"code" => "51000", "msg" => "Parameter error", "data" => []},
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_margin_modification,
                 false
               )

      assert {:error, %Bourse.Error{type: :exchange_error}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :add_margin,
                 "addMargin",
                 "bad",
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_margin_modification,
                 false
               )
    end

    test "net-mode posSide derives long/short and marks hedged false" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "1",
            "instId" => "BTC-USDT-SWAP",
            "mgnMode" => "cross",
            "posSide" => "net",
            "pos" => "1",
            "avgPx" => "65000",
            "markPx" => "65100",
            "lever" => "5",
            "imr" => "130",
            "mmr" => "2.6",
            "upl" => "1",
            "uplRatio" => "0.01",
            "notionalUsd" => "651",
            "cTime" => "1700000000000",
            "uTime" => "1700000000000"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "BTC-USDT-SWAP",
            symbol: "BTC/USDT:USDT",
            contract_size: 0.01,
            linear: true,
            inverse: false,
            type: "swap"
          }
        ])

      assert {:ok, %Bourse.Position{} = position} =
               Unified.call(
                 exchange,
                 :fetch_position,
                 "fetchPosition",
                 %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert position.side == "long"
      assert position.hedged == false
      assert position.contracts == 1.0
    end

    test "margin net positions derive side from posCcy rather than positive pos" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "posId" => "margin-long",
            "instId" => "BTC-USDT",
            "instType" => "MARGIN",
            "mgnMode" => "isolated",
            "posSide" => "net",
            "posCcy" => "BTC",
            "pos" => "0.01",
            "notionalUsd" => "700"
          },
          %{
            "posId" => "margin-short",
            "instId" => "ETH-USDT",
            "instType" => "MARGIN",
            "mgnMode" => "isolated",
            "posSide" => "net",
            "posCcy" => "USDT",
            "pos" => "500",
            "notionalUsd" => "500"
          },
          %{
            "posId" => "margin-unknown",
            "instId" => "BTC-USDC",
            "instType" => "MARGIN",
            "mgnMode" => "isolated",
            "posSide" => "net",
            "posCcy" => "EUR",
            "pos" => "1",
            "notionalUsd" => "1"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "BTC-USDT",
            symbol: "BTC/USDT",
            base: "BTC",
            quote: "USDT",
            margin: true,
            type: "margin"
          },
          %Bourse.Market{
            id: "ETH-USDT",
            symbol: "ETH/USDT",
            base: "ETH",
            quote: "USDT",
            margin: true,
            type: "margin"
          },
          %Bourse.Market{
            id: "BTC-USDC",
            symbol: "BTC/USDC",
            base: "BTC",
            quote: "USDC",
            margin: true,
            type: "margin"
          }
        ])

      assert {:ok, [long, short, unknown]} =
               Unified.call(
                 exchange,
                 :fetch_positions,
                 "fetchPositions",
                 %{},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert long.side == "long"
      assert long.hedged == false
      assert short.side == "short"
      assert short.hedged == false
      assert unknown.side == nil
      assert unknown.hedged == false
    end

    test "positions-history rows map open/close averages without inventing live margin" do
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "cTime" => "1708351230102",
            "ccy" => "USDT",
            "closeAvgPx" => "1.2567",
            "closeTotalPos" => "40",
            "direction" => "short",
            "instId" => "SUSHI-USDT-SWAP",
            "instType" => "SWAP",
            "lever" => "10.0",
            "mgnMode" => "isolated",
            "openAvgPx" => "1.2462",
            "openMaxPos" => "40",
            "posId" => "666159086676836352",
            "realizedPnl" => "-0.4551036",
            "uTime" => "1708354805699"
          }
        ]
      }

      exchange =
        Exchange.put_markets(private_exchange(), [
          %Bourse.Market{
            id: "SUSHI-USDT-SWAP",
            symbol: "SUSHI/USDT:USDT",
            contract_size: 1,
            linear: true,
            inverse: false,
            type: "swap"
          }
        ])

      assert {:ok, [%Bourse.Position{} = position]} =
               Unified.call(
                 exchange,
                 :fetch_positions,
                 "fetchPositions",
                 %{"type" => "history"},
                 plug: {Req.Test, stub_json(collector(), body)}
               )

      assert position.id == "666159086676836352"
      assert position.symbol == "SUSHI/USDT:USDT"
      assert position.side == "short"
      assert position.hedged == true
      assert position.entry_price == 1.2462
      assert position.last_price == 1.2567
      assert position.leverage == 10.0
      assert position.margin_mode == "isolated"
      assert position.realized_pnl == -0.4551036
      assert position.contracts == nil
      assert position.notional == nil
      assert position.collateral == nil
      assert position.unrealized_pnl == nil
      assert position.initial_margin_percentage == 0.1
      assert position.contract_size == 1.0
    end
  end

  describe "request-shape boundary contracts" do
    test "withdraw preserves native chains and resolves unified network aliases" do
      exchange = private_exchange()

      assert %{"amt" => "1.25", "ccy" => "USDT", "chain" => "USDT-ERC20", "fee" => "0.5"} =
               OKX.build(
                 %{"code" => "USDT", "amt" => 1.25, "network" => "ETH", "fee" => 0.5},
                 "withdraw",
                 exchange
               )

      assert %{"chain" => "USDT-TRC20"} =
               shaped =
               OKX.build(
                 %{"ccy" => "USDT", "chain" => "USDT-TRC20", "network" => "ETH"},
                 "withdraw",
                 exchange
               )

      refute Map.has_key?(shaped, "network")
      assert OKX.build(%{"network" => "TRC20"}, "withdraw", exchange) == %{}
    end

    test "funding history handles unified, native future, and absent symbols" do
      exchange = private_exchange()

      assert %{"ccy" => "USDT", "ctType" => "linear", "instType" => "SWAP"} =
               OKX.build(%{"symbol" => "BTC/USDT:USDT"}, "fetchFundingHistory", exchange)

      assert %{"ccy" => "USDT", "ctType" => "linear"} =
               future =
               OKX.build(%{"symbol" => "BTC-USDT-260327"}, "fetchFundingHistory", exchange)

      refute Map.has_key?(future, "instType")

      assert %{"limit" => 10} =
               OKX.build(%{"symbol" => "BTC", "limit" => 10}, "fetchFundingHistory", exchange)

      assert %{"ccy" => "BTC", "limit" => 10} =
               OKX.build(%{"ccy" => "BTC", "limit" => 10}, "fetchFundingHistory", exchange)
    end

    test "cancel-all-after accepts every documented scalar timeout form" do
      exchange = private_exchange()

      for {params, expected} <- [
            {%{"timeOut" => 9}, "9"},
            {%{"timeout" => 2_500.9}, "2"},
            {%{"timeout" => "3000"}, "3"},
            {%{"timeout" => "venue-value"}, "venue-value"},
            {%{"timeout" => :venue_value}, "venue_value"}
          ] do
        assert %{"timeOut" => ^expected} = OKX.build(params, "cancelAllOrdersAfter", exchange)
      end
    end

    test "OHLCV windows support every OKX timeframe unit and safe fallbacks" do
      exchange = private_exchange()
      minute_ms = 60_000

      for {bar, duration_ms} <- [
            {"1m", minute_ms},
            {"1D", 24 * 60 * minute_ms},
            {"1W", 7 * 24 * 60 * minute_ms},
            {"1M", 30 * 24 * 60 * minute_ms},
            {"invalid", minute_ms},
            {:invalid, minute_ms}
          ] do
        assert %{"after" => after_ms, "before" => 999, "limit" => 1} =
                 OKX.build(%{"bar" => bar, "since" => 1_000, "limit" => 1}, "fetchOHLCV", exchange)

        assert after_ms == 1_000 + duration_ms
      end

      assert %{"limit" => 100} = OKX.build(%{"limit" => 0}, "fetchOHLCV", exchange)
      assert %{"ccy" => "BTC", "period" => "1D"} = OKX.build(%{"ccy" => "BTC/USDT"}, "fetchOpenInterestHistory", exchange)
    end

    test "native market-type and account filters retain their endpoint vocabularies" do
      exchange = private_exchange()

      assert %{"instType" => "FUTURES"} = OKX.build(%{"symbols" => ["BTC-USDT-260327"]}, "fetchTickers", exchange)

      assert %{"instType" => "OPTION"} =
               OKX.build(%{"symbols" => ["BTC-USD-260327-100000-C"]}, "fetchTickers", exchange)

      assert %{"instType" => "SWAP"} = OKX.build(%{"instType" => "swap"}, "fetchTradingFee", exchange)
      assert %{"instType" => "FUTURES"} = OKX.build(%{"type" => "future"}, "fetchTradingFee", exchange)

      assert %{"subType" => "custom"} =
               OKX.build(%{"type" => "custom"}, "fetchMarginAdjustmentHistory", exchange)

      assert %{"instType" => "SWAP"} =
               OKX.build(%{"symbols" => [], "instType" => "swap"}, "fetchPositionsHistory", exchange)

      assert %{"before" => 999, "ccy" => "USDT"} =
               OKX.build(%{"code" => "USDT", "since" => 1_000}, "fetchDeposits", exchange)
    end

    test "close-position maps unified sides without inventing a net-mode side" do
      exchange = private_exchange()

      for {side, expected} <- [{nil, nil}, {"buy", "long"}, {"sell", "short"}, {"venue-side", "venue-side"}] do
        params = if is_nil(side), do: %{}, else: %{"side" => side}
        shaped = OKX.build(params, "closePosition", exchange)

        if is_nil(expected), do: refute(Map.has_key?(shaped, "posSide")), else: assert(shaped["posSide"] == expected)
        refute Map.has_key?(shaped, "side")
      end
    end

    test "order builders preserve default, hedge, algo, and trailing semantics" do
      exchange = private_exchange()

      assert %{"ordType" => "limit", "posSide" => "long"} =
               OKX.build(
                 %{"symbol" => "BTC-USDT-SWAP", "side" => "sell", "amount" => 1, "hedged" => true},
                 "createOrder",
                 exchange
               )

      assert %{"posSide" => "short"} =
               OKX.build(
                 %{"symbol" => "BTC-USDT-SWAP", "side" => "buy", "amount" => 1, "hedged" => true},
                 "createOrder",
                 exchange
               )

      assert %{"tpOrdPx" => "-1", "tpTriggerPx" => "12", "tgtCcy" => "base_ccy"} =
               OKX.build(
                 %{
                   "symbol" => "BTC-USDT",
                   "side" => "buy",
                   "amount" => 1,
                   "price" => "",
                   "takeProfitPrice" => 12
                 },
                 "createOrder",
                 exchange
               )

      assert %{"callbackRatio" => "0.1"} =
               OKX.build(
                 %{
                   "symbol" => "BTC-USDT-SWAP",
                   "side" => "sell",
                   "amount" => 1,
                   "trailingPrice" => 5,
                   "callbackRatio" => 0.1
                 },
                 "createOrder",
                 exchange
               )

      assert %{"newCallbackRatio" => "0.2"} =
               OKX.build(
                 %{"symbol" => "BTC-USDT-SWAP", "algoId" => "1", "type" => "move_order_stop", "newCallbackRatio" => 0.2},
                 "editOrder",
                 exchange
               )

      assert %{"newCallbackSpread" => "5"} =
               OKX.build(
                 %{"symbol" => "BTC-USDT-SWAP", "algoId" => "1", "type" => "move_order_stop", "trailingPrice" => 5},
                 "editOrder",
                 exchange
               )

      assert [%{"algoClOrdId" => "client-1", "instId" => "BTC-USDT-SWAP"}] =
               OKX.build(
                 %{"symbol" => "BTC-USDT-SWAP", "clientOrderId" => "client-1", "stop" => true},
                 "cancelOrder",
                 exchange
               )
    end
  end

  defp private_exchange do
    "okx"
    |> Exchange.new!(api_key: "test-key", secret: "test-secret", password: "test-pass")
    |> Exchange.put_markets([
      %Bourse.Market{
        id: "BTC-USDT",
        symbol: "BTC/USDT",
        spot: true,
        precision: %{"amount" => 0.00001, "price" => 0.1}
      },
      %Bourse.Market{
        id: "BTC-USDT-SWAP",
        symbol: "BTC/USDT:USDT",
        linear: true,
        precision: %{"amount" => 0.1, "price" => 0.1}
      },
      %Bourse.Market{
        id: "LTC-USDT-SWAP",
        symbol: "LTC/USDT:USDT",
        linear: true,
        precision: %{"amount" => 0.1, "price" => 0.1}
      },
      %Bourse.Market{
        id: "ADA-USDT-SWAP",
        symbol: "ADA/USDT:USDT",
        linear: true,
        precision: %{"amount" => 0.1, "price" => 0.1}
      }
    ])
  end

  defp private_exchange_with_btc_precision do
    Exchange.put_markets(private_exchange(), [
      %Bourse.Market{
        id: "BTC-USDT",
        symbol: "BTC/USDT",
        precision: %{"amount" => 0.00001, "price" => 0.1}
      }
    ])
  end

  defp collector do
    {:ok, requests} = RequestCollector.start_link()
    requests
  end

  # The plug only answers. Every request-shape assertion runs in the test
  # process after the call under test returns, via the `assert_*!` helpers —
  # an assertion raised inside the plug is swallowed by `Bourse.HTTP`'s rescue
  # and its diagnostic is destroyed.
  defp stub_json(requests, response_body) do
    name = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(name, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, response_body)
    end)

    name
  end

  defp stub_positions_history(requests, rows) do
    name = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(name, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      page =
        case Integer.parse(RequestCollector.query(conn)["after"] || "") do
          {after_ms, ""} -> Enum.filter(rows, &(String.to_integer(&1["uTime"]) < after_ms))
          :error -> rows
        end

      Req.Test.json(conn, %{"code" => "0", "data" => page, "msg" => ""})
    end)

    name
  end

  defp assert_path!(requests, path) do
    conn = RequestCollector.one!(requests)
    assert conn.request_path == path
  end

  defp assert_post!(requests, path, expected_body) do
    request = RequestCollector.one_request!(requests)

    assert request.conn.method == "POST"
    assert request.conn.request_path == path
    assert Jason.decode!(request.body) == expected_body
  end

  defp assert_get!(requests, path, expected_query) do
    conn = RequestCollector.one!(requests)

    assert conn.method == "GET"
    assert conn.request_path == path
    query = RequestCollector.query(conn)
    assert query == expected_query
    refute Map.has_key?(query, "symbol")
  end
end
