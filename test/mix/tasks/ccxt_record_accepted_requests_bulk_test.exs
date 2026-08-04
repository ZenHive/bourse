defmodule Mix.Tasks.Ccxt.RecordAcceptedRequests.BulkTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.RecordAcceptedRequests.Bulk

  test "rejects positional arguments" do
    assert_raise Mix.Error, ~r/usage: mix ccxt.record_accepted_requests.bulk/, fn ->
      Bulk.run(["binance"])
    end
  end

  test "rejects negative pacing" do
    assert_raise Mix.Error, ~r/usage: mix ccxt.record_accepted_requests.bulk/, fn ->
      Bulk.run(["--pacing-ms", "-1"])
    end
  end
end
