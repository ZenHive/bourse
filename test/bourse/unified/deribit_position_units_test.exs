defmodule Bourse.Unified.DeribitPositionUnitsTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Position
  alias Bourse.Unified.DeribitPositionUnits

  test "reconciles inverse quote notional and linear base size into market-derived contracts" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([
        %{"id" => "BTC-PERPETUAL", "contractSize" => "10", "inverse" => true},
        %Market{id: "ETH_USDC-PERPETUAL", contract_size: 0.001, inverse: false, linear: true},
        %Market{id: nil, contract_size: nil}
      ])

    inverse =
      %Position{
        contracts: nil,
        contract_size: nil,
        notional: 50.0,
        symbol: "BTC/USD:BTC",
        info: %{"_bourse_inverse" => true, "instrument_name" => "BTC-PERPETUAL", "kind" => "future"}
      }

    linear =
      %Position{
        base_quantity: 0.5,
        contracts: nil,
        contract_size: nil,
        notional: 1500.0,
        symbol: "ETH/USDC:USDC",
        info: %{"_bourse_inverse" => false, "instrument_name" => "ETH_USDC-PERPETUAL", "kind" => "future"}
      }

    assert {:ok,
            [
              %Position{contracts: 5.0, contract_size: 10.0, notional_currency: "USD"},
              %Position{contracts: 500.0, contract_size: 0.001, notional_currency: "USDC"}
            ]} = DeribitPositionUnits.reconcile({:ok, [inverse, linear]}, exchange)

    assert {:ok, %Position{contracts: 5.0, contract_size: 10.0, notional_currency: "USD"}} =
             DeribitPositionUnits.reconcile({:ok, inverse}, exchange)
  end

  test "falls back to loaded market settlement when direct parser info has no annotation" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([%Market{id: "ETH_USDC-PERPETUAL", contract_size: 0.001, linear: true}])

    position = %Position{
      base_quantity: 0.5,
      notional: 1500.0,
      symbol: "ETH/USDC:USDC",
      info: %{"instrument_name" => "ETH_USDC-PERPETUAL", "kind" => "future"}
    }

    assert {:ok, %Position{contracts: 500.0, contract_size: 0.001, notional_currency: "USDC"}} =
             DeribitPositionUnits.reconcile({:ok, position}, exchange)
  end

  test "leaves contract fields unchanged without applicable market metadata while adding the notional currency" do
    exchange = Exchange.new!("deribit")

    future = %Position{
      notional: 50.0,
      symbol: "BTC/USD:BTC",
      info: %{"instrument_name" => "BTC-PERPETUAL", "kind" => "future"}
    }

    option = %Position{contracts: 0.1, info: %{"instrument_name" => "BTC-OPTION", "kind" => "option"}}

    assert {:ok, [%Position{contracts: nil, contract_size: nil, notional_currency: "USD"}, ^option, :raw]} =
             DeribitPositionUnits.reconcile({:ok, [future, option, :raw]}, exchange)
  end

  test "adds a quote currency to non-Deribit positions and passes through errors" do
    exchange = Exchange.new!("binance")
    result = {:ok, [%Position{notional: 50.0, symbol: "BTC/USDT:USDT"}]}
    error = {:error, :request_failed}

    assert {:ok, [%Position{notional_currency: "USDT"}]} =
             DeribitPositionUnits.reconcile(result, exchange)

    assert DeribitPositionUnits.reconcile(error, exchange) == error
  end

  test "fails loudly when a populated notional has no resolvable currency" do
    exchange = Exchange.new!("binance")

    positions = [
      %Position{notional: 10.0, symbol: "BTC/USDT:USDT"},
      %Position{notional: 50.0}
    ]

    assert {:error, {:missing_position_notional_currency, %{exchange: "binance", symbol: nil}}} =
             DeribitPositionUnits.reconcile({:ok, %Position{notional: 50.0}}, exchange)

    assert {:error, {:missing_position_notional_currency, %{exchange: "binance", symbol: nil}}} =
             DeribitPositionUnits.reconcile({:ok, positions}, exchange)
  end

  test "leaves deribit future contracts unchanged when the settlement quantity is missing" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([%Market{id: "BTC-PERPETUAL", contract_size: 10.0, inverse: true}])

    position = %Position{
      symbol: "BTC/USD:BTC",
      info: %{"instrument_name" => "BTC-PERPETUAL", "kind" => "future"}
    }

    assert {:ok, %Position{contracts: nil, contract_size: nil, notional: nil, notional_currency: nil}} =
             DeribitPositionUnits.reconcile({:ok, position}, exchange)
  end

  test "derives option premium notional in the settlement currency from loaded contract size" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([
        %Market{id: "BTC-31JUL26-65000-C", contract_size: 1.0},
        %Market{id: "AVAX_USDC-22JUN26-5d5-C", contract_size: 10.0}
      ])

    inverse_option = %Position{
      contracts: 0.1,
      mark_price: 0.00701189,
      symbol: "BTC/USD:BTC-260731-65000-C",
      info: %{
        "instrument_name" => "BTC-31JUL26-65000-C",
        "kind" => "option",
        "mark_price" => 0.00701189,
        "size" => 0.1
      }
    }

    linear_option = %Position{
      contracts: 5.0,
      mark_price: 2.0,
      symbol: "AVAX/USDC:USDC-260622-5.5-C",
      info: %{"instrument_name" => "AVAX_USDC-22JUN26-5d5-C", "kind" => "option"}
    }

    assert {:ok,
            %Position{
              contract_size: 1.0,
              contracts: 0.1,
              notional: notional,
              notional_currency: "BTC"
            }} = DeribitPositionUnits.reconcile({:ok, inverse_option}, exchange)

    assert_in_delta notional, 0.000701189, 1.0e-12

    assert {:ok,
            %Position{
              contract_size: 10.0,
              contracts: 5.0,
              notional: 100.0,
              notional_currency: "USDC"
            }} = DeribitPositionUnits.reconcile({:ok, linear_option}, exchange)
  end

  test "leaves option notional nil when contract size is missing rather than guessing 1.0" do
    exchange = Exchange.new!("deribit")

    option = %Position{
      contracts: 0.1,
      mark_price: 0.00701189,
      symbol: "BTC/USD:BTC-260731-65000-C",
      info: %{"instrument_name" => "BTC-31JUL26-65000-C", "kind" => "option", "mark_price" => 0.00701189}
    }

    assert {:ok, %Position{contract_size: nil, notional: nil, notional_currency: nil}} =
             DeribitPositionUnits.reconcile({:ok, option}, exchange)
  end

  test "reads option mark price from the raw payload when the struct field is empty" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([%Market{id: "BTC-31JUL26-65000-C", contract_size: 1.0}])

    option = %Position{
      contracts: 0.1,
      symbol: "BTC/USD:BTC-260731-65000-C",
      info: %{"instrument_name" => "BTC-31JUL26-65000-C", "kind" => "option", "mark_price" => "0.007"}
    }

    assert {:ok, %Position{notional: notional, notional_currency: "BTC"}} =
             DeribitPositionUnits.reconcile({:ok, option}, exchange)

    assert_in_delta notional, 0.0007, 1.0e-12
  end

  test "leaves option notional nil when mark price is missing even with loaded contract size" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([%Market{id: "BTC-31JUL26-65000-C", contract_size: 1.0}])

    option = %Position{
      contracts: 0.1,
      symbol: "BTC/USD:BTC-260731-65000-C",
      info: %{"instrument_name" => "BTC-31JUL26-65000-C", "kind" => "option", "size" => 0.1}
    }

    assert {:ok, ^option} = DeribitPositionUnits.reconcile({:ok, option}, exchange)
  end

  test "does not convert option combo marks into a premium notional" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([%Market{id: "BTC-REV-18JUL26-65000", contract_size: 1.0}])

    combo = %Position{
      contracts: 0.1,
      mark_price: -0.0683,
      symbol: "BTC-REV-18JUL26-65000",
      info: %{"instrument_name" => "BTC-REV-18JUL26-65000", "kind" => "option_combo"}
    }

    assert {:ok, ^combo} = DeribitPositionUnits.reconcile({:ok, combo}, exchange)
  end

  test "fails loudly when a deribit option notional has no resolvable currency" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([%Market{id: "BTC-31JUL26-65000-C", contract_size: 1.0}])

    position = %Position{
      contracts: 0.1,
      mark_price: 0.007,
      info: %{"instrument_name" => "BTC-31JUL26-65000-C", "kind" => "option"}
    }

    assert {:error, {:missing_position_notional_currency, %{exchange: "deribit", symbol: nil}}} =
             DeribitPositionUnits.reconcile({:ok, position}, exchange)
  end

  test "labels inverse settlement notionals with the settle currency" do
    coinm = Exchange.new!("binancecoinm")
    bybit = Exchange.new!("bybit")
    okx = Exchange.new!("okx")

    assert {:ok, %Position{notional_currency: "ETH"}} =
             DeribitPositionUnits.reconcile(
               {:ok, %Position{notional: 0.01, symbol: "ETH/USD:ETH"}},
               coinm
             )

    assert {:ok, %Position{notional_currency: "BTC"}} =
             DeribitPositionUnits.reconcile(
               {:ok, %Position{notional: 0.002, symbol: "BTC/USD:BTC"}},
               bybit
             )

    assert {:ok, %Position{notional_currency: "BTC"}} =
             DeribitPositionUnits.reconcile(
               {:ok, %Position{notional: 0.01, symbol: "BTC/USD:BTC"}},
               okx
             )

    assert {:ok, %Position{notional_currency: "USD"}} =
             DeribitPositionUnits.reconcile(
               {:ok, %Position{notional: 50.0, symbol: "BTC/USDT:USDT"}},
               okx
             )
  end
end
