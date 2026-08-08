defmodule Bourse.HyperliquidReadSlicesTest do
  # Task 370 — hyperliquid unified READ slices (markets/tickers/funding/ledger/
  # currencies) + unknownOid → :order_not_found.
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified
  alias Bourse.Unified.ReadParse
  alias Bourse.Unified.RequestShape

  @meta_fixture "test/fixtures/responses/hyperliquid/fetch_markets.json"

  @spot_meta_and_ctxs [
    %{
      "tokens" => [
        %{
          "name" => "USDC",
          "szDecimals" => 8,
          "weiDecimals" => 8,
          "index" => 0,
          "tokenId" => "0xusdc",
          "isCanonical" => true
        },
        %{
          "name" => "PURR",
          "szDecimals" => 0,
          "weiDecimals" => 5,
          "index" => 1,
          "tokenId" => "0xpurr",
          "isCanonical" => true
        }
      ],
      "universe" => [
        %{"tokens" => [1, 0], "name" => "PURR/USDC", "index" => 0, "isCanonical" => true}
      ]
    },
    [
      %{
        "dayNtlVlm" => "8906.0",
        "markPx" => "0.14",
        "midPx" => "0.209265",
        "prevDayPx" => "0.20432"
      }
    ]
  ]

  @meta_and_ctxs [
    %{
      "universe" => [
        %{"maxLeverage" => 40, "name" => "BTC", "szDecimals" => 5},
        %{"maxLeverage" => 25, "name" => "ETH", "szDecimals" => 4}
      ]
    },
    [
      %{
        "funding" => "0.0001",
        "markPx" => "50000.5",
        "midPx" => "50001.0",
        "openInterest" => "10000.5",
        "oraclePx" => "49990.0",
        "prevDayPx" => "49000.0",
        "dayNtlVlm" => "1.2e9",
        "impactPxs" => ["49999.0", "50002.0"]
      },
      %{
        "funding" => "-0.00005",
        "markPx" => "3000.1",
        "midPx" => "3000.2",
        "openInterest" => "25000.25",
        "oraclePx" => "2999.0",
        "prevDayPx" => "2950.0",
        "dayNtlVlm" => "5e8",
        "impactPxs" => ["3000.0", "3000.3"]
      }
    ]
  ]

  @ledger_body [
    %{
      "time" => 1_724_762_307_531,
      "hash" => "0xabc",
      "delta" => %{
        "type" => "accountClassTransfer",
        "usdc" => "50.0",
        "toPerp" => false
      }
    },
    %{
      "time" => 1_724_762_407_531,
      "hash" => "0xdef",
      "delta" => %{
        "type" => "deposit",
        "usdc" => "10.5",
        "fee" => "0.1",
        "user" => "0xpeer"
      }
    }
  ]

  test "swap markets from metaAndAssetCtxs populate type/flags/quote/precision" do
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, markets} =
             ReadParse.parse(
               exchange,
               Bourse.Hyperliquid,
               :fetch_swap_markets,
               "fetchSwapMarkets",
               @meta_and_ctxs,
               %{},
               :parse_market,
               true
             )

    assert length(markets) == 2
    btc = Enum.find(markets, &(&1.base == "BTC"))
    assert btc.symbol == "BTC/USDC:USDC"
    assert btc.type == "swap"
    assert btc.spot == false
    assert btc.swap == true
    assert btc.contract == true
    assert btc.active == true
    assert btc.quote == "USDC"
    assert btc.settle == "USDC"
    assert btc.id == "0"
    assert btc.base_id == "0"
    assert btc.contract_size == 1
    assert btc.taker == 0.00045
    assert btc.maker == 0.00015
    assert is_number(btc.precision["amount"])
    assert is_number(btc.precision["price"])
  end

  test "spot markets from spotMetaAndAssetCtxs populate type and quote without crashing" do
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, markets} =
             ReadParse.parse(
               exchange,
               Bourse.Hyperliquid,
               :fetch_spot_markets,
               "fetchSpotMarkets",
               @spot_meta_and_ctxs,
               %{},
               :parse_market,
               true
             )

    assert [%Bourse.Market{} = purr] = markets
    assert purr.symbol == "PURR/USDC"
    assert purr.type == "spot"
    assert purr.spot == true
    assert purr.swap == false
    assert purr.contract == false
    assert purr.quote == "USDC"
    assert purr.id == "PURR/USDC"
    assert purr.base_id == "10000"
    assert purr.asset_index == 10_000
    assert purr.taker == 0.0007
  end

  test "recorded meta universe still populates swap fields after annotation" do
    payload = @meta_fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("body")
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

    btc = Enum.find(markets, &(&1.symbol == "BTC/USDC:USDC"))
    assert btc.type == "swap"
    assert btc.quote == "USDC"
    assert btc.settle == "USDC"
    assert btc.active == true
    assert is_integer(btc.asset_index)
  end

  test "tickers from metaAndAssetCtxs are a populated symbol-keyed map" do
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, tickers} =
             ReadParse.parse(
               exchange,
               Bourse.Hyperliquid,
               :fetch_tickers,
               "fetchTickers",
               @meta_and_ctxs,
               %{},
               :parse_ticker,
               false
             )

    assert map_size(tickers) == 2
    assert %Bourse.Ticker{} = btc = tickers["BTC/USDC:USDC"]
    assert btc.symbol == "BTC/USDC:USDC"
    assert btc.last == 50_000.5
    assert btc.close == 50_001.0
    assert btc.bid == 49_999.0
    assert btc.ask == 50_002.0
    assert btc.mark_price == 50_000.5
    assert btc.index_price == 49_990.0
    assert btc.quote_volume == 1.2e9
  end

  test "funding rates from metaAndAssetCtxs are a populated symbol-keyed map" do
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, rates} =
             ReadParse.parse(
               exchange,
               Bourse.Hyperliquid,
               :fetch_funding_rates,
               "fetchFundingRates",
               @meta_and_ctxs,
               %{},
               :parse_funding_rate,
               false
             )

    assert map_size(rates) == 2
    assert %Bourse.FundingRate{} = btc = rates["BTC/USDC:USDC"]
    assert btc.symbol == "BTC/USDC:USDC"
    assert btc.funding_rate == 0.0001
    assert btc.mark_price == 50_000.5
    assert btc.index_price == 49_990.0
    assert btc.interval == "1h"
  end

  test "open interests from metaAndAssetCtxs retain every venue row" do
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, interests} =
             ReadParse.parse(
               exchange,
               Bourse.Hyperliquid,
               :fetch_open_interests,
               "fetchOpenInterests",
               @meta_and_ctxs,
               %{},
               :parse_open_interest,
               false
             )

    assert map_size(interests) == 2
    assert %Bourse.OpenInterest{} = btc = interests["BTC/USDC:USDC"]
    assert btc.symbol == "BTC/USDC:USDC"
    assert btc.open_interest_amount == 10_000.5
  end

  test "ledger entries map amount/currency/type from delta" do
    exchange = Exchange.new!("hyperliquid", api_key: "0xwallet", secret: "private-key")

    {stub, requests} = stub_info(@ledger_body)

    assert {:ok, entries} =
             Unified.call(
               exchange,
               :fetch_ledger,
               "fetchLedger",
               %{},
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).request_path == "/info"

    assert length(entries) == 2
    [transfer, deposit] = entries
    assert transfer.amount == 50.0
    assert transfer.currency == "USDC"
    assert transfer.type == "transfer"
    assert transfer.status == "ok"
    assert transfer.id == "0xabc"

    assert deposit.amount == 10.5
    assert deposit.currency == "USDC"
    assert deposit.type == "deposit"
    assert deposit.fee == %{"cost" => 0.1, "currency" => "USDC"}
    assert deposit.reference_account == "0xpeer"
  end

  test "currencies from spotMeta tokens are a populated code-keyed map" do
    body = %{
      "tokens" => [
        %{
          "name" => "USDC",
          "szDecimals" => 8,
          "weiDecimals" => 8,
          "index" => 0,
          "tokenId" => "0xusdc",
          "isCanonical" => true
        },
        %{
          "name" => "PURR",
          "szDecimals" => 0,
          "weiDecimals" => 5,
          "index" => 1,
          "tokenId" => "0xpurr",
          "isCanonical" => true
        }
      ],
      "universe" => []
    }

    exchange = Exchange.new!("hyperliquid")
    {stub, requests} = stub_info(body)

    assert {:ok, currencies} =
             Unified.call(
               exchange,
               :fetch_currencies,
               "fetchCurrencies",
               %{},
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).request_path == "/info"

    assert map_size(currencies) == 2
    assert %Bourse.Currency{} = usdc = currencies["USDC"]
    assert usdc.id == "USDC"
    assert usdc.code == "USDC"
    assert usdc.type == "crypto"
    assert usdc.precision == 1.0e-8
    assert usdc.numeric_id == 0
  end

  test "unknownOid bare body maps to :order_not_found" do
    exchange =
      Exchange.new!("hyperliquid",
        api_key: "0xwallet",
        secret: "0x0123456789012345678901234567890123456789012345678901234567890123",
        sandbox: true
      )

    body = %{"status" => "unknownOid"}
    {stub, requests} = stub_info(body)

    assert {:error, %Bourse.Error{type: :order_not_found, exchange: "hyperliquid", raw: ^body}} =
             Unified.call(
               exchange,
               :fetch_order,
               "fetchOrder",
               %{"id" => "999999999999", "symbol" => "BTC/USDC:USDC"},
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).request_path == "/info"
  end

  test "fetchOrder request shape maps id to integer oid" do
    exchange =
      Exchange.new!("hyperliquid",
        api_key: "0xwallet",
        secret: "private-key"
      )

    shaped =
      RequestShape.apply(
        %{"id" => "12345", "symbol" => "BTC/USDC:USDC"},
        exchange,
        "fetchOrder"
      )

    assert shaped["type"] == "orderStatus"
    assert shaped["oid"] == 12_345
    assert shaped["user"] == "0xwallet"
    refute Map.has_key?(shaped, "id")
  end

  defp stub_info(body) do
    name = {__MODULE__, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(name, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, body)
    end)

    {name, requests}
  end
end
