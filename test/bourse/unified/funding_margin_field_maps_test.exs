defmodule Bourse.Unified.FundingMarginFieldMapsTest do
  @moduledoc """
  Pins the task-568 Binance funding-history field map against its populated
  sandbox recording.
  """

  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Error
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

  # binance declares four candidate endpoints for fetchFundingHistory
  # (fapi, dapi, papi-cm, papi-um). Picking one by position would route a
  # COIN-M caller to USD-M data silently, so resolution must refuse instead.
  # Both cases resolve before dispatch and issue no request — verified by
  # telemetry: the ambiguous call fires no [:bourse, :request, :*] event
  # while the symbol-bearing call fires start/stop on /income.
  describe "binance fetchFundingHistory endpoint resolution" do
    test "refuses to guess among the four income endpoints when nothing selects one" do
      exchange = Exchange.new!("binance", credentials: Credentials.new!(api_key: "k", secret: "s"))

      assert {:error, %Error{type: :bad_request, message: message}} =
               Bourse.fetch_funding_history(exchange, nil)

      assert message =~ "ambiguous multi-endpoint selection for fetchFundingHistory on binance"
      assert message =~ "refusing bare hd(configs)"
    end

    test "reports the credential requirement rather than an ambiguity when unauthenticated" do
      assert {:error, %Error{type: :authentication_error, message: message}} =
               Bourse.fetch_funding_history(Exchange.new!("binance"), nil)

      assert message =~ "has only authenticated endpoints; credentials required"
    end
  end

  defp load_response!(venue, method) do
    venue
    |> RecordedResponseFixtures.fixture_path(method)
    |> RecordedResponseFixtures.load_fixture!()
  end
end
