defmodule Bourse.Unified.ContractUnitTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Spec
  alias Bourse.Spec.Schema
  alias Bourse.Unified.ContractUnit

  describe "authored semantics" do
    test "linear venues declare a venue-level unit rather than a parse default" do
      for venue <- ~w(binance binanceusdm bybit derive) do
        spec = Spec.load!(venue)
        config = get_in(spec, ["markets", "contract_unit"])

        assert config["quantity_unit"] == "base"
        assert config["linear"] == %{"kind" => "constant", "value" => 1}
        assert Schema.validate!(spec, venue) == spec
        assert %Exchange{config: %{"contract_unit" => ^config}} = Exchange.new!(venue)

        market_map = Exchange.new!(venue).module.__field_maps__()["market"]["field_map"]["contractSize"]
        refute is_map(market_map) and Map.has_key?(market_map, "default")
      end
    end

    test "reject missing or non-positive linear units" do
      spec = Spec.load!("binanceusdm")

      assert_raise ArgumentError, ~r/markets\.contract_unit\.linear/, fn ->
        Schema.validate!(put_in(spec, ["markets", "contract_unit", "linear"], nil), "binanceusdm")
      end

      assert_raise ArgumentError, ~r/markets\.contract_unit\.linear/, fn ->
        Schema.validate!(
          put_in(spec, ["markets", "contract_unit", "linear"], %{"kind" => "constant", "value" => 0}),
          "binanceusdm"
        )
      end

      assert_raise ArgumentError, ~r/markets\.contract_unit.*base quantity_unit/, fn ->
        Schema.validate!(put_in(spec, ["markets", "contract_unit", "quantity_unit"], "contracts"), "binanceusdm")
      end
    end

    test "accepts a named provider field as the linear recipe" do
      spec = Spec.load!("binanceusdm")

      updated =
        put_in(spec, ["markets", "contract_unit", "linear"], %{"kind" => "field", "field" => "contractSize"})

      assert Schema.validate!(updated, "binanceusdm") == updated

      assert_raise ArgumentError, ~r/markets\.contract_unit\.linear/, fn ->
        Schema.validate!(
          put_in(spec, ["markets", "contract_unit", "linear"], %{"kind" => "field", "field" => ""}),
          "binanceusdm"
        )
      end
    end
  end

  describe "normalize_market/3" do
    test "fills a linear market from the authored constant" do
      market = linear_market()
      exchange = exchange(%{"kind" => "constant", "value" => 1})

      normalized = ContractUnit.normalize_market(market, %{}, exchange)

      assert normalized.contract_size == 1
      assert normalized.quantity_unit == "base"
    end

    test "keeps a provider-published size instead of replacing it" do
      market = %{linear_market() | contract_size: 100}
      exchange = exchange(%{"kind" => "constant", "value" => 1})

      assert ContractUnit.normalize_market(market, %{}, exchange).contract_size == 100
    end

    test "reads a declared field and fails loud when that field is missing" do
      market = linear_market()
      exchange = exchange(%{"kind" => "field", "field" => "contractSize"})

      assert ContractUnit.normalize_market(market, %{"contractSize" => "0.01"}, exchange).contract_size == 0.01
      assert ContractUnit.normalize_market(market, %{"contractSize" => "1"}, exchange).contract_size == 1

      assert_raise ArgumentError, ~r/missing linear contract unit/, fn ->
        ContractUnit.normalize_market(market, %{}, exchange)
      end

      assert_raise ArgumentError, ~r/missing linear contract unit/, fn ->
        ContractUnit.normalize_market(market, %{"contractSize" => "not-a-size"}, exchange)
      end
    end

    test "an unrecognized recipe fails loud instead of becoming 1" do
      market = %{linear_market() | symbol: nil, id: "BTCUSDT"}

      assert_raise ArgumentError, ~r/missing linear contract unit for BTCUSDT/, fn ->
        ContractUnit.normalize_market(market, %{}, exchange(%{"kind" => "guess"}))
      end
    end

    test "keeps a provider-published float size" do
      market = %{linear_market() | contract_size: 1.0}

      assert ContractUnit.normalize_market(market, %{}, exchange(%{"kind" => "constant", "value" => 2})).contract_size ==
               1.0
    end

    test "a market whose venue states no unit stays nil instead of becoming 1" do
      market = linear_market()

      assert ContractUnit.normalize_market(market, %{}, Exchange.new!("okx")).contract_size == nil
      assert ContractUnit.normalize_market(market, %{}, Exchange.new!("binancecoinm")).contract_size == nil
    end

    test "does not rewrite option or inverse markets" do
      option = %Market{option: true, linear: true, contract: true, contract_size: nil}
      inverse = %Market{linear: false, inverse: true, contract: true, contract_size: nil}
      exchange = exchange(%{"kind" => "constant", "value" => 1})

      assert ContractUnit.normalize_market(option, %{}, exchange).contract_size == nil
      assert ContractUnit.normalize_market(inverse, %{}, exchange).contract_size == nil
    end
  end

  defp linear_market do
    %Market{
      id: "BTCUSDT",
      symbol: "BTC/USDT:USDT",
      type: "swap",
      swap: true,
      contract: true,
      linear: true,
      inverse: false,
      contract_size: nil
    }
  end

  defp exchange(recipe) do
    %Exchange{
      id: "binanceusdm",
      name: "binanceusdm",
      config: %{"contract_unit" => %{"quantity_unit" => "base", "linear" => recipe}}
    }
  end
end
