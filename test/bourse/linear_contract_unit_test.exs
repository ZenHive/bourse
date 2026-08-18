defmodule Bourse.LinearContractUnitTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Unified.ReadParse

  @usdm_fixture "test/fixtures/responses/binanceusdm/fetch_markets.json"
  @coinm_fixture "test/fixtures/responses/binancecoinm/fetch_markets.json"
  @external_resource @usdm_fixture
  @external_resource @coinm_fixture

  test "linear USD-M unit and inverse COIN-M contractSize stay distinct" do
    usdm = parse_recorded_markets!("binanceusdm", @usdm_fixture)
    coinm = parse_recorded_markets!("binancecoinm", @coinm_fixture)

    assert %Market{
             symbol: "BTC/USDT:USDT",
             contract: true,
             linear: true,
             inverse: false,
             contract_size: linear_size,
             quantity_unit: "base"
           } = Enum.find(usdm, &(&1.symbol == "BTC/USDT:USDT"))

    assert %Market{
             symbol: "BTC/USD:BTC",
             contract: true,
             linear: false,
             inverse: true,
             contract_size: inverse_size
           } = Enum.find(coinm, &(&1.symbol == "BTC/USD:BTC"))

    assert linear_size == 1
    assert inverse_size == 100

    # Visible formula split: linear notional is quantity * price * unit;
    # inverse notional is contracts * provider contractSize.
    price = 50_000
    quantity = 0.001
    contracts = 1
    linear_notional = quantity * price * linear_size
    inverse_notional = contracts * inverse_size

    assert linear_notional == 50.0
    assert inverse_notional == 100
    refute linear_notional == inverse_notional
  end

  defp parse_recorded_markets!(exchange_id, path) do
    body = path |> File.read!() |> Jason.decode!() |> Map.fetch!("body")
    exchange = Exchange.new!(exchange_id)

    assert {:ok, markets} =
             ReadParse.parse(
               exchange,
               exchange.module,
               :fetch_markets,
               "fetchMarkets",
               body,
               %{},
               :parse_market,
               true
             )

    markets
  end
end
