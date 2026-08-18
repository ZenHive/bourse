defmodule Bourse.BinanceContractUnitIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Bourse.Market
  alias Bourse.Test.FixtureGateIsolation

  @moduletag :integration
  @moduletag :network

  setup do
    FixtureGateIsolation.isolate!("binanceusdm")
    FixtureGateIsolation.isolate!("binancecoinm")
    :ok
  end

  test "live fapi linear unit and dapi contractSize stay distinct" do
    assert {:ok, usdm} = Bourse.load_markets(Bourse.Exchange.new!("binanceusdm"))
    assert {:ok, coinm} = Bourse.load_markets(Bourse.Exchange.new!("binancecoinm"))

    assert %Market{
             symbol: "BTC/USDT:USDT",
             contract: true,
             linear: true,
             inverse: false,
             contract_size: 1,
             quantity_unit: "base"
           } = Enum.find(usdm.markets, &(&1.symbol == "BTC/USDT:USDT"))

    assert %Market{
             symbol: "BTC/USD:BTC",
             contract: true,
             linear: false,
             inverse: true,
             contract_size: 100
           } = Enum.find(coinm.markets, &(&1.symbol == "BTC/USD:BTC"))

    refute Enum.find(usdm.markets, &(&1.symbol == "BTC/USDT:USDT")).info["contractSize"]
    assert Enum.find(coinm.markets, &(&1.symbol == "BTC/USD:BTC")).info["contractSize"] == 100
  end
end
