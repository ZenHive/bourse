defmodule Bourse.RestReadContractInventoryTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.RestReadContracts
  alias Bourse.Test.RestReadContractScenario

  @expected_case_counts %{
    "alpaca" => 16,
    "binance" => 26,
    "binancecoinm" => 32,
    "binanceusdm" => 65,
    "bybit" => 91,
    "coinbaseexchange" => 3,
    "deribit" => 41,
    "derive" => 24,
    "hyperliquid" => 30,
    "lighter" => 15,
    "okx" => 84
  }

  test "provider-owned inventory covers every supported REST-read branch" do
    assert :ok = RestReadContracts.validate!()

    actual_counts =
      Map.new(RestReadContracts.venues(), fn venue ->
        {venue, length(RestReadContracts.cases_for(venue))}
      end)

    assert actual_counts == @expected_case_counts
    assert RestReadContracts.denominator() == 427
  end

  test "scalar time contracts assert current milliseconds without a module" do
    now = System.system_time(:millisecond)

    contract_case = %{
      "id" => "binance:fetchTime:2:publicGetTime",
      "method" => "fetchTime",
      "venue" => "binance",
      "success" => %{
        "representation" => "parsed",
        "collection" => "scalar",
        "scalar" => "integer",
        "invariants" => [%{"operator" => "recent_ms", "tolerance_ms" => 300_000}]
      }
    }

    assert :ok = RestReadContractScenario.assert_live_value!(contract_case, now)
  end

  test "nested map contracts assert provider meaning keys without a module" do
    contract_case = %{
      "id" => "binance:fetchTradingLimits:3:publicGetExchangeInfo",
      "method" => "fetchTradingLimits",
      "venue" => "binance",
      "success" => %{
        "representation" => "nested_map",
        "provider_meaning_keys" => ["min", "max"]
      }
    }

    assert :ok =
             RestReadContractScenario.assert_live_value!(
               contract_case,
               %{"BTC/USDT" => %{"min" => 0.00001, "max" => 9000.0}}
             )
  end

  test "live contract implementation has no offline semantic substitute" do
    sources =
      Enum.map_join(
        [
          "test/bourse/rest_read_contract_live_test.exs",
          "test/support/rest_read_contracts.ex",
          "test/support/test_generator/rest_read_contract.ex"
        ],
        "\n",
        &File.read!/1
      )

    refute sources =~ "Req.Test"
    refute sources =~ "RecordedResponse"
    refute sources =~ "test/fixtures"
    refute sources =~ "plug:"
    refute sources =~ "@tag :skip"
  end
end
