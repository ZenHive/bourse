defmodule Mix.Tasks.Ccxt.VerifyRestReadContractsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ccxt.VerifyRestReadContracts

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

  test "summarize! rejects a malformed report" do
    assert_raise Mix.Error, ~r/no summary/, fn ->
      VerifyRestReadContracts.summarize!(%{}, 427)
    end
  end
end
