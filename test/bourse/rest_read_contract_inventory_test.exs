defmodule Bourse.RestReadContractInventoryTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.RestReadContracts
  alias Bourse.Test.RestReadContractScenario

  @expected_case_counts %{
    "alpaca" => 16,
    "binance" => 26,
    "binancecoinm" => 32,
    "binanceusdm" => 61,
    "bybit" => 78,
    "coinbaseexchange" => 3,
    "deribit" => 41,
    "derive" => 24,
    "hyperliquid" => 29,
    "lighter" => 16,
    "okx" => 84
  }

  test "the execution inventory mirrors every supported REST-read branch" do
    assert :ok = RestReadContracts.validate!()

    actual_counts =
      Map.new(RestReadContracts.venues(), fn venue ->
        {venue, length(RestReadContracts.cases_for(venue))}
      end)

    assert actual_counts == @expected_case_counts
    assert RestReadContracts.denominator() == 410
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

  describe "field_values" do
    defp open_order_case(success_overrides) do
      %{
        "id" => "binanceusdm:fetchOpenOrder:1:fapiPrivateGetAlgoOrder",
        "method" => "fetchOpenOrder",
        "venue" => "binanceusdm",
        "success" =>
          Map.merge(
            %{
              "representation" => "parsed",
              "collection" => "single",
              "module" => "Bourse.Order",
              "required_fields" => ["id"],
              "any_fields" => ["symbol", "status", "type", "side"]
            },
            success_overrides
          )
      }
    end

    test "an absent declaration constrains nothing" do
      assert :ok = RestReadContracts.validate_field_values!(open_order_case(%{}))
    end

    test "a map from field names to allowed values is accepted" do
      assert :ok = RestReadContracts.validate_field_values!(open_order_case(%{"field_values" => %{"status" => ["open"]}}))
    end

    for {label, malformed} <- [
          false: false,
          null: nil,
          empty_list: [],
          non_map: "status",
          empty_map: %{},
          empty_allowed_list: %{"status" => []},
          non_list_allowed: %{"status" => "open"}
        ] do
      test "a #{label} declaration is rejected" do
        contract_case = open_order_case(%{"field_values" => unquote(Macro.escape(malformed))})

        assert_raise ArgumentError, ~r/field_values must map field names to non-empty lists/, fn ->
          RestReadContracts.validate_field_values!(contract_case)
        end
      end
    end

    test "a declared status rejects an order outside the allowed values" do
      contract_case = open_order_case(%{"field_values" => %{"status" => ["open"]}})
      canceled = %Bourse.Order{id: "1", symbol: "BTC/USDT:USDT", status: "canceled"}

      assert_raise ExUnit.AssertionError, ~r/status is "canceled", expected one of \["open"\]/, fn ->
        RestReadContractScenario.assert_live_value!(contract_case, canceled)
      end

      assert :ok = RestReadContractScenario.assert_live_value!(contract_case, %{canceled | status: "open"})
    end
  end

  test "nested map contracts keep a false provider boolean as meaning" do
    contract_case = %{
      "id" => "binancecoinm:fetchPositionMode:0:dapiPrivateGetPositionSideDual",
      "method" => "fetchPositionMode",
      "venue" => "binancecoinm",
      "success" => %{
        "representation" => "nested_map",
        "provider_meaning_keys" => ["dualSidePosition"]
      }
    }

    assert :ok =
             RestReadContractScenario.assert_live_value!(
               contract_case,
               %{"dualSidePosition" => false}
             )
  end
end
