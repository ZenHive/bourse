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

  defp load_response!(venue, method) do
    venue
    |> RecordedResponseFixtures.fixture_path(method)
    |> RecordedResponseFixtures.load_fixture!()
  end
end
