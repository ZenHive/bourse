defmodule Bourse.LiveLaneLedgerTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.LiveLane.Ledger
  alias Bourse.RawResponse
  alias Bourse.Test.LiveLane
  alias Bourse.Test.RestReadContractScenario

  test "the ledger file is the classification source for okx 50038 demo-unavailable" do
    document = Ledger.load!()
    methods = Enum.flat_map(document["cases"], & &1["methods"])

    for method <- [
          "fetchCurrencies",
          "fetchDepositWithdrawFees",
          "fetchDepositAddress",
          "fetchDepositAddressesByNetwork",
          "fetchBorrowRateHistory",
          "fetchBorrowRateHistories"
        ] do
      assert method in methods
    end

    error = %Error{
      type: :exchange_error,
      code: "50038",
      message: "This feature is unavailable in demo trading"
    }

    contract_case = %{"venue" => "okx", "method" => "fetchDepositAddress", "id" => "okx:fetchDepositAddress:0:x"}

    assert {:ledgered, entry} = Ledger.classify(contract_case, {:error, error}, document)
    assert entry["class"] == "ledgered_demo_unavailable"

    summary =
      Ledger.format_summary([%{"id" => contract_case["id"], "class" => entry["class"], "summary" => entry["summary"]}], 1)

    assert summary =~ "ledgered demo-unavailable: 1"
    assert summary =~ "genuine failures: 1"
    assert summary =~ "okx:fetchDepositAddress:0:x"
    assert summary =~ "does not host funding-account"
    refute summary =~ "actual defect"
  end

  test "a 50038-shaped error on another venue is genuine" do
    document = Ledger.load!()

    error = %Error{
      type: :exchange_error,
      code: "50038",
      message: "This feature is unavailable in demo trading"
    }

    contract_case = %{"venue" => "bybit", "method" => "fetchDepositAddress", "id" => "bybit:fetchDepositAddress:0:x"}

    assert :genuine = Ledger.classify(contract_case, {:error, error}, document)
  end

  test "report-row classification strips the ExUnit test prefix" do
    document = Ledger.load!()

    tests = [
      %{
        "name" => "test okx:fetchDepositAddress:0:privateGetAssetDepositAddress",
        "state" => "failed",
        "message" => "live provider success failed: 50038 This feature is unavailable in demo trading"
      },
      %{
        "name" => "test bybit:fetchPositionsHistory:0:privateGetV5PositionClosedPnl",
        "state" => "failed",
        "message" => "missing_position_notional_currency DOGEUSDT-28AUG26"
      }
    ]

    classified = Ledger.classify_report_failures(tests, document)
    assert hd(classified.ledgered)["class"] == "ledgered_demo_unavailable"
    assert hd(classified.genuine)["name"] =~ "fetchPositionsHistory"
  end

  test "a different okx error on a ledgered method is genuine" do
    document = Ledger.load!()
    error = %Error{type: :authentication_error, code: "50111", message: "Invalid API key"}
    contract_case = %{"venue" => "okx", "method" => "fetchDepositAddress", "id" => "okx:fetchDepositAddress:0:x"}

    assert :genuine = Ledger.classify(contract_case, {:error, error}, document)
  end

  test "raw contracts distinguish empty rows from rows that lack semantic keys" do
    contract_case = %{
      "id" => "example:fetchWidget:0:publicGetWidget",
      "method" => "fetchWidget",
      "venue" => "example",
      "success" => %{
        "representation" => "raw",
        "provider_meaning_keys" => ["deliveryPrice", "deliveryRpl"]
      }
    }

    empty = RawResponse.new(%{"result" => %{"list" => []}}, "example", "fetchWidget", :unverified)

    empty_error =
      assert_raise ExUnit.AssertionError, fn ->
        RestReadContractScenario.assert_live_value!(contract_case, empty)
      end

    assert empty_error.message =~ "provider returned no rows"
    assert empty_error.message =~ "empty account state, not a missing-key carve"
    refute empty_error.message =~ "none of them carry the semantic keys"

    present =
      RawResponse.new(
        %{"result" => %{"list" => [%{"unrelated" => "x"}]}},
        "example",
        "fetchWidget",
        :unverified
      )

    missing_error =
      assert_raise ExUnit.AssertionError, fn ->
        RestReadContractScenario.assert_live_value!(contract_case, present)
      end

    assert missing_error.message =~ "rows are present but none of them carry the semantic keys"
    assert missing_error.message =~ "shape/carve mismatch, not empty account state"
    refute missing_error.message =~ "provider returned no rows"
  end

  test "a meaning key plus an empty nested list is not empty account state" do
    contract_case = %{
      "id" => "example:fetchStatus:0:publicGetStatus",
      "method" => "fetchStatus",
      "venue" => "example",
      "success" => %{
        "representation" => "raw",
        "provider_meaning_keys" => ["status"]
      }
    }

    value =
      RawResponse.new(
        %{"status" => "ok", "incidents" => []},
        "example",
        "fetchStatus",
        :unverified
      )

    assert :ok = RestReadContractScenario.assert_live_value!(contract_case, value)
  end

  test "an empty-resource ledger row does not swallow an unrelated provider error" do
    document = Ledger.load!()

    error = %Error{
      type: :exchange_error,
      code: "10001",
      message: "Unmatched request"
    }

    contract_case = %{
      "venue" => "deribit",
      "method" => "fetchOrder",
      "id" => "deribit:fetchOrder:0:x"
    }

    assert :genuine = Ledger.classify(contract_case, {:error, error}, document)
  end

  test "the hits path is scoped per checkout so concurrent worktrees cannot cross-read" do
    a = Ledger.hits_path("/data/worktrees/bourse/run-a")
    b = Ledger.hits_path("/data/worktrees/bourse/run-b")

    assert a != b
    assert Path.dirname(a) == System.tmp_dir!()
    assert Ledger.hits_path("/data/worktrees/bourse/run-a") == a
  end

  test "a shape/carve mismatch on a state-dependent method stays genuine" do
    document = Ledger.load!()

    tests = [
      %{
        "name" => "test okx:fetchOrder:0:privateGetTradeOrder",
        "state" => "failed",
        "message" =>
          "okx:fetchOrder:0:privateGetTradeOrder: rows are present but none of them carry " <>
            "the semantic keys [\"ordId\"]. This is a shape/carve mismatch, not empty account state."
      }
    ]

    classified = Ledger.classify_report_failures(tests, document)

    assert classified.ledgered == []
    assert hd(classified.genuine)["name"] =~ "fetchOrder"
  end

  test "the empty-state flunks the scenario emits are still ledgered by message" do
    document = Ledger.load!()

    tests =
      for message <- [
            "okx:fetchOrder:0:x: provider account state has no id from fetchClosedOrders",
            "okx:fetchOrder:0:x: provider account/market state did not exercise the read.",
            "okx:fetchOrder:0:x: provider returned no rows (empty collection). This is empty " <>
              "account state, not a missing-key carve."
          ] do
        %{"name" => "test okx:fetchOrder:0:x", "state" => "failed", "message" => message}
      end

    classified = Ledger.classify_report_failures(tests, document)

    assert classified.genuine == []
    assert length(classified.ledgered) == 3
    assert Enum.all?(classified.ledgered, &(&1["class"] == "ledgered_state_dependent"))
  end

  test "a generic expected-true assertion on a ledgered method stays genuine" do
    document = Ledger.load!()

    tests = [
      %{
        "name" => "test deribit:fetchOrder:0:privateGetGetOrderState",
        "state" => "failed",
        "message" => "Assertion with == failed, expected true, got false"
      }
    ]

    classified = Ledger.classify_report_failures(tests, document)
    assert classified.ledgered == []
    assert hd(classified.genuine)["name"] =~ "fetchOrder"
  end

  test "sparse history on a ledgered method is state-dependent, a window-boundary miss is genuine" do
    document = Ledger.load!()

    sparse_case = %{
      "venue" => "binanceusdm",
      "method" => "fetchMyTrades",
      "id" => "binanceusdm:fetchMyTrades:time_window"
    }

    assert {:ledgered, entry} = Ledger.classify(sparse_case, :sparse_history, document)
    assert entry["class"] == "ledgered_state_dependent"
    assert entry["id"] == "binanceusdm-my-trades-window"

    assert {:ledgered, _} = Ledger.classify(sparse_case, :empty_collection, document)

    deribit_case = %{
      "venue" => "deribit",
      "method" => "fetchTrades",
      "id" => "deribit:fetchTrades:time_window"
    }

    assert {:ledgered, deribit_entry} = Ledger.classify(deribit_case, :sparse_history, document)
    assert deribit_entry["id"] == "deribit-public-trades-window"

    tests = [
      %{
        "name" => "test binanceusdm:fetchMyTrades:0:privateGetUserTrades",
        "state" => "failed",
        "message" => "binanceusdm.fetch_my_trades needs 4 distinct live timestamps; got [1, 2]"
      },
      %{
        "name" => "test binanceusdm:fetchMyTrades:0:privateGetUserTrades",
        "state" => "failed",
        "message" =>
          "binanceusdm.fetch_my_trades returned the latest page instead of the since boundary: requested 1, first 9"
      }
    ]

    classified = Ledger.classify_report_failures(tests, document)
    assert hd(classified.ledgered)["class"] == "ledgered_state_dependent"
    assert hd(classified.genuine)["message"] =~ "latest page instead of the since boundary"
  end

  test "lighter empty market history still classifies from the ledger file" do
    document = Ledger.load!()
    contract_case = %{"venue" => "lighter", "method" => "fetchOHLCV", "id" => "lighter:fetchOHLCV:live"}

    assert {:ledgered, entry} = Ledger.classify(contract_case, :empty_collection, document)
    assert entry["id"] == "lighter-empty-market-history"
  end

  test "LiveLane contract cases use unified JS names rather than a test-local roster" do
    assert LiveLane.contract_case(:binanceusdm, :fetch_my_trades) == %{
             "venue" => "binanceusdm",
             "method" => "fetchMyTrades",
             "id" => "binanceusdm:fetchMyTrades:live"
           }
  end

  test "LiveLane flunks an empty collection the ledger does not cover" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        LiveLane.accept_or_flunk!("bybit", "fetchTicker", :empty_collection, "genuine empty ticker")
      end

    assert error.message =~ "genuine empty ticker"
  end
end
