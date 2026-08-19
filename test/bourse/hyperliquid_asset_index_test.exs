defmodule Bourse.HyperliquidAssetIndexTest do
  # Task 339 — explicit Market.asset_index from Hyperliquid meta/spotMeta ordering.
  # Offline pins use recorded real meta (perps) and real-shaped spot/HIP-3 rows;
  # formula authority: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/asset-ids
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Unified.ReadParse
  alias Bourse.Unified.RequestShape

  @meta_fixture "test/fixtures/responses/hyperliquid/fetch_markets.json"

  # Real-shaped spotMeta.universe sample captured from testnet 2026-07-17
  # (api.hyperliquid-testnet.xyz, type: spotMeta). Full payload is large;
  # these three rows are enough to pin the 10000+index rule.
  @spot_universe [
    %{"tokens" => [1, 0], "name" => "PURR/USDC", "index" => 0, "isCanonical" => true},
    %{"tokens" => [2, 0], "name" => "@1", "index" => 1, "isCanonical" => false},
    %{"tokens" => [3, 0], "name" => "@2", "index" => 2, "isCanonical" => false}
  ]

  test "perp asset_index is the meta.universe position (recorded real payload)" do
    payload = @meta_fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("body")
    universe = Map.fetch!(payload, "universe")
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, markets} =
             ReadParse.parse(
               exchange,
               Bourse.Hyperliquid,
               :fetch_markets,
               "fetchMarkets",
               payload,
               %{},
               :parse_market,
               true
             )

    assert length(markets) == length(universe)

    btc_index = Enum.find_index(universe, &(&1["name"] == "BTC"))
    sol_index = Enum.find_index(universe, &(&1["name"] == "SOL"))
    assert btc_index == 0
    assert is_integer(sol_index)

    btc = Enum.find(markets, &(&1.base == "BTC" and &1.symbol == "BTC/USDC:USDC"))
    sol = Enum.find(markets, &(&1.base == "SOL" and &1.symbol == "SOL/USDC:USDC"))

    assert btc.asset_index == btc_index
    assert sol.asset_index == sol_index
    # Task 370: id/base_id are the universe index (Bourse baseId) so consumers can
    # key markets without overloading asset_index; synthetics stay out of info.
    assert btc.id == Integer.to_string(btc_index)
    assert btc.base_id == Integer.to_string(btc_index)
    refute Map.has_key?(btc.info || %{}, "_bourse_asset_index")
  end

  test "spot asset_index is 10000 + spotMeta universe index (venue rule)" do
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, markets} =
             ReadParse.parse(
               exchange,
               Bourse.Hyperliquid,
               :fetch_markets,
               "fetchMarkets",
               %{"universe" => @spot_universe},
               %{},
               :parse_market,
               true
             )

    by_name = Map.new(markets, fn m -> {get_in(m.info, ["name"]), m} end)

    assert by_name["PURR/USDC"].asset_index == 10_000
    assert by_name["@1"].asset_index == 10_001
    assert by_name["@2"].asset_index == 10_002
  end

  test "HIP-3 asset_index is 100000 + perp_dex_index * 10000 + index_in_meta (venue rule)" do
    # Official docs example: test:ABC on testnet → perp_dex_index=1, index_in_meta=0 → 110000.
    # xyz:XYZ100 at index 0 on dex index 1 matches the authored baseId 110000.
    universe = [
      %{
        "name" => "test:ABC",
        "maxLeverage" => 10,
        "szDecimals" => 2,
        "perpDexIndex" => 1
      },
      %{
        "name" => "xyz:XYZ100",
        "maxLeverage" => 30,
        "szDecimals" => 4,
        "perpDexIndex" => 1
      },
      %{
        "name" => "xyz:MSFT",
        "maxLeverage" => 20,
        "szDecimals" => 2,
        "perpDexIndex" => 1,
        "index" => 10
      }
    ]

    exchange = Exchange.new!("hyperliquid")

    assert {:ok, markets} =
             ReadParse.parse(
               exchange,
               Bourse.Hyperliquid,
               :fetch_markets,
               "fetchMarkets",
               %{"universe" => universe},
               %{},
               :parse_market,
               true
             )

    assert Enum.at(markets, 0).asset_index == 110_000
    assert Enum.at(markets, 1).asset_index == 110_001
    assert Enum.at(markets, 2).asset_index == 110_010
  end

  test "RequestShape cancel reads only Market.asset_index (not id/base_id)" do
    markets = [
      %Bourse.Market{
        symbol: "BTC/USDC:USDC",
        base: "BTC",
        quote: "USDC",
        settle: "USDC",
        # Deliberately wrong identity fields — must be ignored.
        id: "999",
        base_id: "999",
        asset_index: 0
      }
    ]

    exchange = "hyperliquid" |> Exchange.new!() |> Map.put(:markets, markets)

    shaped =
      RequestShape.apply(
        %{"id" => 1, "symbol" => "BTC/USDC:USDC"},
        exchange,
        "cancelOrder",
        timestamp_ms_override: 42
      )

    assert shaped["action"] == %{
             "type" => "cancel",
             "cancels" => [%{"a" => 0, "o" => 1}]
           }
  end

  test "RequestShape cancel raises when markets were never loaded" do
    exchange = Exchange.new!("hyperliquid")
    assert is_nil(exchange.markets)

    assert_raise ArgumentError, ~r/markets are not loaded for BTC\/USDC:USDC/, fn ->
      RequestShape.apply(
        %{"id" => 1, "symbol" => "BTC/USDC:USDC"},
        exchange,
        "cancelOrder",
        timestamp_ms_override: 42
      )
    end
  end

  test "RequestShape cancel raises when the loaded market has no asset_index" do
    markets = [
      %Bourse.Market{
        symbol: "BTC/USDC:USDC",
        base: "BTC",
        id: nil,
        base_id: nil,
        asset_index: nil
      }
    ]

    exchange = "hyperliquid" |> Exchange.new!() |> Map.put(:markets, markets)

    assert_raise ArgumentError, ~r/loaded market has no asset_index for BTC\/USDC:USDC/, fn ->
      RequestShape.apply(
        %{"id" => 1, "symbol" => "BTC/USDC:USDC"},
        exchange,
        "cancelOrder",
        timestamp_ms_override: 42
      )
    end
  end

  test "RequestShape cancel names an unknown symbol as caller input" do
    markets = [
      %Bourse.Market{
        symbol: "BTC/USDC:USDC",
        base: "BTC",
        quote: "USDC",
        settle: "USDC",
        asset_index: 0
      }
    ]

    exchange = "hyperliquid" |> Exchange.new!() |> Map.put(:markets, markets)

    error =
      assert_raise Bourse.Error, fn ->
        RequestShape.apply(
          %{"id" => 1, "symbol" => "NOPE/USDC:USDC"},
          exchange,
          "cancelOrder",
          timestamp_ms_override: 42
        )
      end

    assert error.type == :bad_symbol
    assert error.raw["reason"] == "unknown_symbol"
    assert error.raw["symbol"] == "NOPE/USDC:USDC"
  end

  test "fixture markets cache injects asset_index from Bourse baseId for L1 replay" do
    exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})

    shaped =
      RequestShape.apply(
        %{"id" => 6_466_108_935, "symbol" => "SOL/USDC:USDC"},
        exchange,
        "cancelOrder",
        timestamp_ms_override: 1_709_205_271_182
      )

    assert shaped["action"] == %{
             "type" => "cancel",
             "cancels" => [%{"a" => 5, "o" => 6_466_108_935}]
           }
  end
end
