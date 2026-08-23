defmodule Bourse.RestReadContractInventoryTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.RestReadContracts

  @expected_case_counts %{
    "alpaca" => 16,
    "binance" => 284,
    "binancecoinm" => 32,
    "binanceusdm" => 281,
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
    assert RestReadContracts.denominator() == 901
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
