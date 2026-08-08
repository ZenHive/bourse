defmodule Bourse.Unified.FundingMarginFieldMapsTest do
  @moduledoc """
  Task 568 — funding_history / margin_modification field maps for the four
  remaining no_field_map cells:

    * binance fetchFundingHistory / fetchMarginAdjustmentHistory
    * hyperliquid fetchFundingHistory
    * okx fetchMarginAdjustmentHistory

  Domain assertions pin real venue values and timestamps, never `is_map/1` or
  non-empty body presence alone.
  """

  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.FundingHistory
  alias Bourse.MarginModification
  alias Bourse.RecordedResponseFixtures
  alias Bourse.Unified.ReadParse

  describe "binance fetchFundingHistory" do
    test "parses recorded FUNDING_FEE income rows into FundingHistory with venue amounts and times" do
      fixture = load_response!("binance", :fetch_funding_history)
      body = fixture["body"]
      assert is_list(body) and body != []

      first = hd(body)
      assert first["incomeType"] == "FUNDING_FEE"
      assert first["asset"] == "USDT"
      assert is_integer(first["time"])
      assert first["tranId"]

      exchange = Exchange.new!("binance")

      assert {:ok, [%FundingHistory{} | _] = history} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_funding_history,
                 true
               )

      row = Enum.find(history, &(&1.id == to_string(first["tranId"]))) || hd(history)

      assert row.id == to_string(first["tranId"])
      assert row.code == "USDT"
      assert row.amount == Bourse.Safe.number(first["income"])
      assert row.timestamp == first["time"]
      assert is_binary(row.datetime)
      assert row.rate == nil
      assert row.symbol == "BTC/USDT:USDT"
      assert row.info["incomeType"] == "FUNDING_FEE"
      assert row.info["tranId"] == first["tranId"]
    end
  end

  describe "binance fetchMarginAdjustmentHistory" do
    test "empty live recording parses as [] once the field map is authored" do
      fixture = load_response!("binance", :fetch_margin_adjustment_history)
      assert fixture["body"] == []

      exchange = Exchange.new!("binance")

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_margin_adjustment_history,
                 "fetchMarginAdjustmentHistory",
                 fixture["body"],
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_margin_modification,
                 true
               )
    end

    test "parses provider positionMargin/history rows into MarginModification (add/reduce)" do
      # Provider-owned shape from Binance USD-M docs / the same fapi surface the
      # multi-product binance venue routes to. Demo account has no margin
      # adjustments yet; pin domain meaning against the documented wire row.
      body = [
        %{
          "symbol" => "BTCUSDT",
          "type" => 1,
          "deltaType" => "USER_ADJUST",
          "amount" => "23.36332311",
          "asset" => "USDT",
          "time" => 1_578_047_897_183,
          "positionSide" => "BOTH"
        },
        %{
          "symbol" => "BTCUSDT",
          "type" => 2,
          "deltaType" => "USER_ADJUST",
          "amount" => "5.5",
          "asset" => "USDT",
          "time" => 1_578_047_900_425,
          "positionSide" => "LONG"
        }
      ]

      exchange = Exchange.new!("binance")

      assert {:ok, [add, reduce]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_margin_adjustment_history,
                 "fetchMarginAdjustmentHistory",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_margin_modification,
                 true
               )

      assert %MarginModification{} = add
      assert add.type == "add"
      assert add.amount == 23.36332311
      assert add.code == "USDT"
      assert add.timestamp == 1_578_047_897_183
      assert add.margin_mode == "isolated"
      assert add.status == "ok"
      assert add.symbol == "BTC/USDT:USDT"
      assert add.info["deltaType"] == "USER_ADJUST"

      assert reduce.type == "reduce"
      assert reduce.amount == 5.5
      assert reduce.timestamp == 1_578_047_900_425
    end
  end

  describe "hyperliquid fetchFundingHistory" do
    test "empty sandbox recording parses as []" do
      fixture = load_response!("hyperliquid", :fetch_funding_history)
      assert fixture["body"] == []

      exchange = Exchange.new!("hyperliquid")

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 Bourse.Hyperliquid,
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 fixture["body"],
                 %{},
                 :parse_funding_history,
                 true
               )
    end

    test "parses userFunding rows into FundingHistory with delta.usdc amount and fundingRate" do
      # Live-observed mainnet info:userFunding shape (public; same contract as
      # sandbox). Nested under delta: coin / usdc / fundingRate.
      body = [
        %{
          "time" => 1_786_230_000_029,
          "hash" => "0xabc123",
          "delta" => %{
            "type" => "funding",
            "coin" => "BTC",
            "usdc" => "0.43798",
            "szi" => "-1.5",
            "fundingRate" => "0.0000125",
            "nSamples" => nil
          }
        }
      ]

      exchange = Exchange.new!("hyperliquid")

      assert {:ok, [%FundingHistory{} = row]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Hyperliquid,
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 body,
                 %{},
                 :parse_funding_history,
                 true
               )

      assert row.id == "0xabc123"
      assert row.amount == 0.43798
      assert row.rate == 0.0000125
      assert row.timestamp == 1_786_230_000_029
      assert is_binary(row.datetime)
      assert row.code == "USDC"
      assert row.symbol == "BTC/USDC:USDC"
      assert get_in(row.info, ["delta", "coin"]) == "BTC"
      assert get_in(row.info, ["delta", "fundingRate"]) == "0.0000125"
    end
  end

  describe "okx fetchMarginAdjustmentHistory" do
    test "empty demo recording parses as [] once the field map is authored" do
      fixture = load_response!("okx", :fetch_margin_adjustment_history)
      assert fixture["body"]["code"] == "0"
      assert fixture["body"]["data"] == []

      exchange = Exchange.new!("okx")

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_margin_adjustment_history,
                 "fetchMarginAdjustmentHistory",
                 fixture["body"],
                 %{"type" => "add"},
                 :parse_margin_modification,
                 true
               )
    end

    test "parses account-bill margin rows (subType 160/161) into MarginModification" do
      # Same bill envelope as live demo GET /api/v5/account/bills (observed
      # 2026-08-08). subType 160/161 are the documented margin add/reduce codes;
      # the sandbox key currently has no such bills, so pin domain meaning on a
      # row shaped exactly like the live bill contract.
      body = %{
        "code" => "0",
        "msg" => "",
        "data" => [
          %{
            "billId" => "3798832141267492865",
            "ccy" => "USDT",
            "balChg" => "-12.5",
            "bal" => "4985.88602148",
            "type" => "5",
            "subType" => "160",
            "mgnMode" => "isolated",
            "instId" => "BTC-USDT-SWAP",
            "instType" => "SWAP",
            "ts" => "1785716420170"
          },
          %{
            "billId" => "3798832141267492866",
            "ccy" => "USDT",
            "balChg" => "3.25",
            "bal" => "4989.13602148",
            "type" => "5",
            "subType" => "161",
            "mgnMode" => "isolated",
            "instId" => "BTC-USDT-SWAP",
            "instType" => "SWAP",
            "ts" => "1785716421000"
          }
        ]
      }

      exchange = Exchange.new!("okx")

      assert {:ok, [add, reduce]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_margin_adjustment_history,
                 "fetchMarginAdjustmentHistory",
                 body,
                 %{"type" => "add", "symbol" => "BTC/USDT:USDT"},
                 :parse_margin_modification,
                 true
               )

      assert %MarginModification{} = add
      assert add.type == "add"
      assert add.amount == -12.5
      assert add.total == 4985.88602148
      assert add.code == "USDT"
      assert add.margin_mode == "isolated"
      assert add.status == "ok"
      assert add.timestamp == 1_785_716_420_170
      assert is_binary(add.datetime)
      assert add.symbol == "BTC/USDT:USDT"
      assert add.info["billId"] == "3798832141267492865"
      assert add.info["subType"] == "160"

      assert reduce.type == "reduce"
      assert reduce.amount == 3.25
      assert reduce.timestamp == 1_785_716_421_000
    end
  end

  defp load_response!(venue, method) do
    venue
    |> RecordedResponseFixtures.fixture_path(method)
    |> RecordedResponseFixtures.load_fixture!()
  end
end
