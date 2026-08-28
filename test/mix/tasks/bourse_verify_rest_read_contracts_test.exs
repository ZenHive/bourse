defmodule Mix.Tasks.Bourse.VerifyRestReadContractsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bourse.VerifyRestReadContracts

  test "summarize! reports a fully executed inventory" do
    report = %{
      "summary" => %{
        "total" => 427,
        "failed" => 0,
        "invalid" => 0,
        "skipped" => 0,
        "excluded" => 0,
        "result" => "passed"
      }
    }

    assert VerifyRestReadContracts.summarize!(report, 427) == %{
             denominator: 427,
             executed: 427,
             failures: 0,
             result: "passed"
           }
  end

  test "summarize! rejects an unexercised inventory row" do
    report = %{
      "summary" => %{
        "total" => 427,
        "failed" => 0,
        "invalid" => 0,
        "skipped" => 0,
        "excluded" => 1,
        "result" => "passed"
      }
    }

    assert_raise Mix.Error, ~r/denominator=427 executed=426 failures=1/, fn ->
      VerifyRestReadContracts.summarize!(report, 427)
    end
  end

  test "lane_failures is empty when every red was ledgered" do
    summary = %{denominator: 3, executed: 3, failures: 2, result: "failed"}
    classification = %{ledgered: [%{}, %{}], genuine: [], report_rows: 2}

    assert VerifyRestReadContracts.lane_failures(summary, classification) == []
  end

  test "lane_failures reds an unclassifiable setup_all failure the report never itemised" do
    # A `setup_all` crash marks a venue's tests `invalid`, not `failed`, so no
    # failed row reaches the ledger and `genuine` stays empty.
    summary = %{denominator: 3, executed: 3, failures: 3, result: "failed"}
    classification = %{ledgered: [], genuine: [], report_rows: 0}

    assert [reason] = VerifyRestReadContracts.lane_failures(summary, classification)
    assert reason =~ "3 failure(s) the report did not itemise"
    assert reason =~ "invalid/skipped/excluded"
  end

  test "lane_failures reds a genuine failure and a shrinking lane together" do
    summary = %{denominator: 4, executed: 3, failures: 1, result: "failed"}
    classification = %{ledgered: [], genuine: [%{"name" => "x"}], report_rows: 1}

    reasons = VerifyRestReadContracts.lane_failures(summary, classification)

    assert Enum.any?(reasons, &(&1 =~ "lane shrank: executed=3 denominator=4"))
    assert Enum.any?(reasons, &(&1 =~ "1 genuine failure(s)"))
  end

  test "summarize! rejects a malformed report" do
    assert_raise Mix.Error, ~r/no summary/, fn ->
      VerifyRestReadContracts.summarize!(%{}, 427)
    end
  end
end
