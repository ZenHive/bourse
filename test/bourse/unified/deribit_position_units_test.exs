defmodule Bourse.Unified.DeribitPositionUnitsTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Position
  alias Bourse.Unified.DeribitPositionUnits

  test "reconciles Deribit future quote notional into market-derived contracts" do
    exchange =
      "deribit"
      |> Exchange.new!()
      |> Exchange.put_markets([
        %{"id" => "BTC-PERPETUAL", "contractSize" => "10"},
        %Market{id: nil, contract_size: nil}
      ])

    position =
      %Position{
        contracts: nil,
        contract_size: nil,
        notional: 50.0,
        info: %{"instrument_name" => "BTC-PERPETUAL", "kind" => "future"}
      }

    assert {:ok, [%Position{contracts: 5.0, contract_size: 10.0}]} =
             DeribitPositionUnits.reconcile({:ok, [position]}, exchange)

    assert {:ok, %Position{contracts: 5.0, contract_size: 10.0}} =
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
