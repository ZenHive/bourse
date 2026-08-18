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
        info: %{"_bourse_inverse" => true, "instrument_name" => "BTC-PERPETUAL", "kind" => "future"}
      }

    linear =
      %Position{
        base_quantity: 0.5,
        contracts: nil,
        contract_size: nil,
        notional: 1500.0,
        info: %{"_bourse_inverse" => false, "instrument_name" => "ETH_USDC-PERPETUAL", "kind" => "future"}
      }

    assert {:ok,
            [
              %Position{contracts: 5.0, contract_size: 10.0},
              %Position{contracts: 500.0, contract_size: 0.001}
            ]} = DeribitPositionUnits.reconcile({:ok, [inverse, linear]}, exchange)

    assert {:ok, %Position{contracts: 5.0, contract_size: 10.0}} =
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
      info: %{"instrument_name" => "ETH_USDC-PERPETUAL", "kind" => "future"}
    }

    assert {:ok, %Position{contracts: 500.0, contract_size: 0.001}} =
             DeribitPositionUnits.reconcile({:ok, position}, exchange)
  end

  test "leaves positions unchanged without applicable market metadata" do
    exchange = Exchange.new!("deribit")
    future = %Position{notional: 50.0, info: %{"instrument_name" => "BTC-PERPETUAL", "kind" => "future"}}
    option = %Position{contracts: 0.1, info: %{"instrument_name" => "BTC-OPTION", "kind" => "option"}}

    assert {:ok, [^future, ^option, :raw]} =
             DeribitPositionUnits.reconcile({:ok, [future, option, :raw]}, exchange)
  end

  test "passes through non-Deribit and error results" do
    exchange = Exchange.new!("binance")
    result = {:ok, [%Position{notional: 50.0}]}
    error = {:error, :request_failed}

    assert DeribitPositionUnits.reconcile(result, exchange) == result
    assert DeribitPositionUnits.reconcile(error, exchange) == error
  end
end
