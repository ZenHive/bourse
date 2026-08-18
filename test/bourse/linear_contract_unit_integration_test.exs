defmodule Bourse.LinearContractUnitIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Test.FixtureGateIsolation
  alias Bourse.Unified

  @moduletag :integration
  @moduletag :network

  setup do
    Enum.each(~w(binance bybit derive), &FixtureGateIsolation.isolate!/1)
    :ok
  end

  test "live linear markets populate the authored base unit" do
    assert_binance_umbrella_families()
    assert_bybit_linear_unit()
    assert_derive_perp_unit()
  end

  defp assert_binance_umbrella_families do
    exchange = Exchange.new!("binance")
    fapi_index = market_endpoint_index!(exchange, "fapiPublic")
    dapi_index = market_endpoint_index!(exchange, "dapiPublic")
    spot_index = market_endpoint_index!(exchange, "public")

    assert {:ok, fapi} = Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, endpoint_index: fapi_index)

    assert %Market{
             symbol: "BTC/USDT:USDT",
             contract: true,
             linear: true,
             inverse: false,
             contract_size: 1,
             quantity_unit: "base"
           } = Enum.find(fapi, &(&1.symbol == "BTC/USDT:USDT"))

    refute Enum.find(fapi, &(&1.symbol == "BTC/USDT:USDT")).info["contractSize"]

    assert {:ok, dapi} = Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, endpoint_index: dapi_index)

    assert %Market{
             symbol: "BTC/USD:BTC",
             contract: true,
             linear: false,
             inverse: true,
             contract_size: 100
           } = Enum.find(dapi, &(&1.symbol == "BTC/USD:BTC"))

    assert Enum.find(dapi, &(&1.symbol == "BTC/USD:BTC")).info["contractSize"] == 100

    assert {:ok, spot} = Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, endpoint_index: spot_index)

    assert %Market{symbol: "BTC/USDT", contract: false, linear: false, contract_size: nil} =
             Enum.find(spot, &(&1.symbol == "BTC/USDT" and &1.spot == true))
  end

  defp assert_bybit_linear_unit do
    assert {:ok, markets} = Bourse.fetch_markets(Exchange.new!("bybit"))

    assert %Market{
             symbol: "BTC/USDT:USDT",
             contract: true,
             linear: true,
             inverse: false,
             contract_size: 1,
             quantity_unit: "base"
           } = Enum.find(markets, &(&1.symbol == "BTC/USDT:USDT"))

    refute Map.has_key?(Enum.find(markets, &(&1.symbol == "BTC/USDT:USDT")).info, "contractSize")

    assert %Market{
             symbol: "BTC/USD:BTC",
             contract: true,
             linear: false,
             inverse: true,
             contract_size: nil
           } = Enum.find(markets, &(&1.symbol == "BTC/USD:BTC"))
  end

  defp assert_derive_perp_unit do
    assert {:ok, markets} = Bourse.fetch_markets(Exchange.new!("derive"))

    assert %Market{
             symbol: "BTC/USD:USDC",
             contract: true,
             linear: true,
             inverse: false,
             option: false,
             contract_size: 1,
             quantity_unit: "base"
           } = Enum.find(markets, &(&1.symbol == "BTC/USD:USDC"))

    option = Enum.find(markets, &(&1.option == true))
    assert option
    assert is_nil(option.contract_size)
  end

  defp market_endpoint_index!(%Exchange{module: module}, section) do
    configs = module.__unified_endpoint__(:fetch_markets)

    index =
      Enum.find_index(configs, fn config ->
        section in config.sections
      end)

    assert is_integer(index), "no fetch_markets section #{inspect(section)}"
    index
  end
end
