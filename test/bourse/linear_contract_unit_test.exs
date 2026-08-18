defmodule Bourse.LinearContractUnitTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Unified.ReadParse

  @usdm_fixture "test/fixtures/responses/binanceusdm/fetch_markets.json"
  @coinm_fixture "test/fixtures/responses/binancecoinm/fetch_markets.json"
  @binance_fixture "test/fixtures/responses/binance/fetch_markets.json"
  @bybit_fixture "test/fixtures/responses/bybit/fetch_markets.json"
  @derive_fixture "test/fixtures/responses/derive/fetch_markets.json"
  @external_resource @usdm_fixture
  @external_resource @coinm_fixture
  @external_resource @binance_fixture
  @external_resource @bybit_fixture
  @external_resource @derive_fixture

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

  test "binance umbrella authors the linear FAPI unit without inheriting it onto spot or COIN-M" do
    markets = parse_recorded_markets!("binance", @binance_fixture)

    assert %Market{
             symbol: "BTC/USDT:USDT",
             contract: true,
             linear: true,
             inverse: false,
             contract_size: 1,
             quantity_unit: "base"
           } = Enum.find(markets, &(&1.symbol == "BTC/USDT:USDT"))

    refute Enum.find(markets, &(&1.symbol == "BTC/USDT:USDT")).info["contractSize"]

    assert %Market{
             symbol: "BTC/USD:BTC",
             contract: true,
             linear: false,
             inverse: true,
             contract_size: 100
           } = Enum.find(markets, &(&1.symbol == "BTC/USD:BTC"))

    assert Enum.find(markets, &(&1.symbol == "BTC/USD:BTC")).info["contractSize"] == 100

    assert %Market{
             symbol: "BTC/USDT",
             type: "spot",
             contract: false,
             linear: false,
             contract_size: nil
           } = Enum.find(markets, &(&1.symbol == "BTC/USDT" and &1.spot == true))
  end

  test "bybit linear qty is the authored base unit; inverse stays provider-nil" do
    markets = parse_recorded_markets!("bybit", @bybit_fixture)

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

  test "derive perp qty is the authored base unit; options stay nil" do
    markets = parse_recorded_markets!("derive", @derive_fixture)

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
    assert %Market{contract: true, linear: true, contract_size: nil} = option
  end

  defp parse_recorded_markets!(exchange_id, path) do
    parse_fixture!(exchange_id, Jason.decode!(File.read!(path)))
  end

  defp parse_fixture!(exchange_id, %{"body" => body}) when is_map(body) do
    parse_body!(exchange_id, body)
  end

  defp parse_fixture!(exchange_id, %{"responses" => responses}) when is_list(responses) do
    Enum.flat_map(responses, &parse_body!(exchange_id, &1["body"]))
  end

  defp parse_body!(exchange_id, body) when is_map(body) do
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

    List.wrap(markets)
  end

  defp parse_body!(_exchange_id, _body), do: []
end
