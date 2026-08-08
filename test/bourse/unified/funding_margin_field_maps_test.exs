defmodule Bourse.Unified.FundingMarginFieldMapsTest do
  @moduledoc """
  Pins the task-568 Binance funding-history field map against its populated
  sandbox recording.
  """

  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.FundingHistory
  alias Bourse.RecordedResponseFixtures
  alias Bourse.Unified.ReadParse

  describe "binance fetchFundingHistory" do
    test "parses recorded FUNDING_FEE income rows into FundingHistory with venue amounts and times" do
      fixture = load_response!("binance", :fetch_funding_history)
      body = fixture["body"]
      assert is_list(body) and body != []

      first = hd(body)

      assert Map.take(first, ["asset", "income", "incomeType", "symbol", "time", "tranId"]) == %{
               "asset" => "USDT",
               "income" => "-0.01286054",
               "incomeType" => "FUNDING_FEE",
               "symbol" => "BTCUSDT",
               "time" => 1_786_089_600_000,
               "tranId" => 1_380_186_948_815_340_520
             }

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

      assert row.id == "1380186948815340520"
      assert row.code == "USDT"
      assert row.amount == -0.01286054
      assert row.timestamp == 1_786_089_600_000
      assert row.datetime == "2026-08-07T08:00:00.000Z"
      assert row.rate == nil
      assert row.symbol == "BTC/USDT:USDT"
      assert row.info["incomeType"] == "FUNDING_FEE"
      assert row.info["tranId"] == first["tranId"]
    end
  end

  defp load_response!(venue, method) do
    venue
    |> RecordedResponseFixtures.fixture_path(method)
    |> RecordedResponseFixtures.load_fixture!()
  end
end
