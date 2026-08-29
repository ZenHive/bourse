defmodule Bourse.Unified.ReadPayloadHonestyTest do
  @moduledoc """
  Offline pins for the class where the venue already supplied a value and the
  unified surface used to hand back less than it held.
  """

  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified
  alias Bourse.Unified.ReadParse

  describe "binance-family fetchBalance stamps updateTime" do
    test "spot account payload fills Balance.timestamp from updateTime" do
      exchange = Exchange.new!("binance")
      update_time = 1_700_000_000_000

      body = %{
        "updateTime" => update_time,
        "balances" => [%{"asset" => "USDT", "free" => "10", "locked" => "1"}]
      }

      assert {:ok, %Bourse.Balance{timestamp: ^update_time, datetime: datetime}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )

      assert is_binary(datetime)
      assert datetime
    end

    test "USD-M assets payload fills Balance.timestamp from updateTime" do
      exchange = Exchange.new!("binanceusdm")
      update_time = 1_700_000_000_123

      body = %{
        "updateTime" => update_time,
        "assets" => [
          %{
            "asset" => "USDT",
            "walletBalance" => "10",
            "maxWithdrawAmount" => "8",
            "initialMargin" => "2"
          }
        ]
      }

      assert {:ok, %Bourse.Balance{timestamp: ^update_time}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binanceusdm,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )
    end

    test "COIN-M assets payload fills Balance.timestamp from updateTime" do
      exchange = Exchange.new!("binancecoinm")
      update_time = 1_700_000_000_456

      body = %{
        "updateTime" => update_time,
        "assets" => [
          %{
            "asset" => "BTC",
            "walletBalance" => "1",
            "availableBalance" => "0.5"
          }
        ]
      }

      assert {:ok, %Bourse.Balance{timestamp: ^update_time}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binancecoinm,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )
    end
  end

  describe "bybit coins-balance envelope" do
    test "flat result.balance rows parse into total/free, not empty maps" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "balance" => [
            %{"coin" => "USDT", "walletBalance" => "100", "transferBalance" => "40", "bonus" => "0"},
            %{"coin" => "BTC", "walletBalance" => "0.5", "transferBalance" => "0.1", "bonus" => "0"}
          ]
        }
      }

      assert {:ok, %Bourse.Balance{} = balance} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{"type" => "funding"},
                 :parse_balance,
                 false
               )

      assert map_size(balance.total) == 2
      assert balance.total["USDT"] == 100.0
      assert balance.free["USDT"] == 40.0
      assert balance.used["USDT"] == 60.0
      assert balance.total["BTC"] == 0.5
    end

    test "fetchBalance unified slots are wallet-balance and coins-balance only" do
      paths = Enum.map(Bourse.Bybit.__unified_endpoints__()[:fetch_balance], & &1.path)
      assert "v5/account/wallet-balance" in paths
      assert "v5/asset/transfer/query-account-coins-balance" in paths
      refute "v5/account/info" in paths
      refute "v5/user/query-api" in paths
      assert length(paths) == 2
    end
  end

  describe "COIN-M fetchADLRank keeps every position-carrying symbol" do
    test "a two-row adlQuantile list indexes both symbols" do
      exchange = Exchange.new!("binancecoinm")

      body = [
        %{"symbol" => "BTCUSD_PERP", "adlQuantile" => %{"BOTH" => 1, "LONG" => 1, "SHORT" => 2}},
        %{"symbol" => "ETHUSD_PERP", "adlQuantile" => %{"BOTH" => 3, "LONG" => 3, "SHORT" => 4}}
      ]

      assert {:ok, ranks} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binancecoinm,
                 :fetch_adl_rank,
                 "fetchADLRank",
                 body,
                 %{},
                 :parse_adl_rank,
                 false
               )

      assert is_map(ranks)
      assert map_size(ranks) == 2
      assert %Bourse.ADLRank{rank: 1} = ranks["BTC/USD:BTC"]
      assert %Bourse.ADLRank{rank: 3} = ranks["ETH/USD:ETH"]
    end
  end

  describe "deribit option chain implied volatility and underlying filter" do
    test "mark_iv fills implied_volatility as a fraction" do
      exchange = Exchange.new!("deribit")

      body = %{
        "jsonrpc" => "2.0",
        "result" => [
          deribit_option_row("BTC-29AUG26-100000-C", "BTC", "50.0"),
          deribit_option_row("BTC-29AUG26-100000-P", "BTC", "48.0")
        ]
      }

      assert {:ok, chain} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_option_chain,
                 "fetchOptionChain",
                 body,
                 %{"symbol" => "BTC"},
                 :parse_option,
                 false
               )

      assert map_size(chain) == 2

      Enum.each(chain, fn {_symbol, option} ->
        assert is_number(option.implied_volatility)
        assert option.implied_volatility
        assert option.info["mark_iv"]
      end)

      btc_call =
        Enum.find_value(chain, fn {_sym, opt} -> opt.info["instrument_name"] == "BTC-29AUG26-100000-C" && opt end)

      assert_in_delta btc_call.implied_volatility, 0.5, 1.0e-9
    end

    test "a SOL request keeps SOL legs from a USDC-settled book and drops the rest" do
      exchange = Exchange.new!("deribit")

      body = %{
        "jsonrpc" => "2.0",
        "result" => [
          deribit_option_row("SOL_USDC-29AUG26-200-C", "SOL", "80.0"),
          deribit_option_row("ETH_USDC-29AUG26-4000-C", "ETH", "40.0")
        ]
      }

      assert {:ok, chain} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_option_chain,
                 "fetchOptionChain",
                 body,
                 %{"symbol" => "SOL"},
                 :parse_option,
                 false
               )

      assert map_size(chain) == 1
      [{_symbol, option}] = Map.to_list(chain)
      assert option.currency == "SOL"
      assert option.implied_volatility == 0.8
    end

    test "an unknown underlying is not_supported rather than an empty success" do
      exchange = Exchange.new!("deribit")

      body = %{
        "jsonrpc" => "2.0",
        "result" => [deribit_option_row("SOL_USDC-29AUG26-200-C", "SOL", "80.0")]
      }

      assert {:error, %Error{type: :not_supported}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_option_chain,
                 "fetchOptionChain",
                 body,
                 %{"symbol" => "FOOBAR"},
                 :parse_option,
                 false
               )
    end
  end

  describe "deribit account_margin numeric slot" do
    test "per-currency margin figures are observed numbers, including zero" do
      exchange = Exchange.new!("deribit")

      body = %{
        "result" => %{
          "summaries" => [
            %{
              "currency" => "BTC",
              "portfolio_margining_enabled" => true,
              "margin_model" => "cross_pm",
              "initial_margin" => 0,
              "maintenance_margin" => 1.25,
              "projected_initial_margin" => 0.1,
              "projected_maintenance_margin" => 0.2,
              "margin_balance" => 3.0,
              "projected_close_out_margin" => 0.3,
              "close_out_margin" => 0.4,
              "total_initial_margin_usd" => 10.0,
              "total_maintenance_margin_usd" => 5.0,
              "total_margin_balance_usd" => 20.0
            }
          ]
        }
      }

      assert {:ok, facts} = ReadParse.account_facts(exchange, body)
      assert facts.account_margin.status == :observed

      assert facts.account_margin.provider_fields == [
               "initial_margin",
               "maintenance_margin",
               "projected_initial_margin",
               "projected_maintenance_margin",
               "margin_balance",
               "projected_close_out_margin",
               "close_out_margin",
               "total_initial_margin_usd",
               "total_maintenance_margin_usd",
               "total_margin_balance_usd"
             ]

      [row] = facts.account_margin.value
      assert row["currency"] == "BTC"
      assert row["initial_margin"] == 0
      assert row["maintenance_margin"] == 1.25
      assert row["initial_margin"]
    end

    test "a venue without account-level margin figures is unavailable, not zero" do
      exchange = Exchange.new!("bybit")

      body = %{"result" => %{"unifiedMarginStatus" => 3, "marginMode" => "REGULAR_MARGIN"}}
      assert {:ok, facts} = ReadParse.account_facts(exchange, body)
      assert facts.account_margin.status == :unavailable
      assert facts.account_margin.value == nil
    end
  end

  describe "request routes that used to miss the venue" do
    test "deribit fetch_option_chain remaps a non-settlement underlying to USDC" do
      exchange = Exchange.new!("deribit")

      assert {:ok, [shaped]} = Unified.request_param_shapes(exchange, :fetch_option_chain, %{"symbol" => "SOL"})
      assert shaped["currency"] == "USDC"
      assert shaped["kind"] == "option"
    end

    test "deribit fetch_option_chain leaves BTC on the inverse settlement currency" do
      exchange = Exchange.new!("deribit")

      assert {:ok, [shaped]} = Unified.request_param_shapes(exchange, :fetch_option_chain, %{"symbol" => "BTC"})
      assert shaped["currency"] == "BTC"
    end

    test "okx algo pending fans out across ordTypes when the caller did not pick one" do
      exchange = Exchange.new!("okx")

      assert {:ok, shapes} = Unified.request_param_shapes(exchange, :fetch_open_orders, %{}, endpoint_index: 0)

      assert Enum.map(shapes, & &1["ordType"]) == ["conditional", "oco", "trigger", "move_order_stop"]
    end

    test "okx trigger: true selects only trigger and does not fan out" do
      exchange = Exchange.new!("okx")

      assert {:ok, [shape]} =
               Unified.request_param_shapes(exchange, :fetch_open_orders, %{"trigger" => true}, endpoint_index: 0)

      assert shape["ordType"] == "trigger"
    end

    test "binanceusdm endpoint_index 1 sends algoId, not the openOrder orderId shape" do
      exchange = Exchange.new!("binanceusdm")
      params = %{"id" => "12345", "symbol" => "BTC/USDT:USDT"}

      assert {:ok, [index0]} = Unified.request_param_shapes(exchange, :fetch_open_order, params, endpoint_index: 0)
      assert {:ok, [index1]} = Unified.request_param_shapes(exchange, :fetch_open_order, params, endpoint_index: 1)

      refute index0 == index1
      assert index1["algoId"] == "12345"
      refute Map.has_key?(index1, "orderId")
      assert index0["orderId"] == "12345"
    end
  end

  defp deribit_option_row(instrument_name, base_currency, mark_iv) do
    %{
      "instrument_name" => instrument_name,
      "base_currency" => base_currency,
      "mark_iv" => mark_iv,
      "mark_price" => "0.01",
      "bid_price" => "0.009",
      "ask_price" => "0.011",
      "last" => "0.01",
      "volume" => "1",
      "open_interest" => "10",
      "creation_timestamp" => 1_700_000_000_000,
      "timestamp" => 1_700_000_000_000
    }
  end
end
