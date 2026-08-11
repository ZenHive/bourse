defmodule Mix.Tasks.Ccxt.RecordAcceptedRequestsTest do
  use ExUnit.Case, async: false

  alias Bourse.ExchangeAcceptanceFixtures
  alias Mix.Tasks.Ccxt.RecordAcceptedRequests

  test "task rejects unsupported venue and argument shapes" do
    assert_raise Mix.Error, ~r/unknown credentialed venue/, fn ->
      RecordAcceptedRequests.run(["unknown"])
    end

    assert_raise Mix.Error, ~r/usage: mix ccxt.record_accepted_requests/, fn ->
      RecordAcceptedRequests.run(["deribit", "extra"])
    end
  end

  @tag :network
  test "task records one live venue and refreshes the merged manifest" do
    require_deribit_credentials!()
    fixture_path = ExchangeAcceptanceFixtures.fixture_path("deribit")
    manifest_path = ExchangeAcceptanceFixtures.manifest_path()
    fixture_before = File.read!(fixture_path)
    manifest_before = File.read!(manifest_path)

    on_exit(fn ->
      File.write!(fixture_path, fixture_before)
      File.write!(manifest_path, manifest_before)
    end)

    assert :ok = RecordAcceptedRequests.run(["deribit"])

    golden = fixture_path |> File.read!() |> Jason.decode!()
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    assert get_in(golden, ["acceptance", "venue"]) == "deribit"
    assert Enum.any?(manifest["goldens"], &(&1["path"] == "deribit/fetch_balance.json"))
  end

  defp require_deribit_credentials! do
    missing =
      Enum.reject(~w(DERIBIT_TESTNET_API_KEY DERIBIT_TESTNET_API_SECRET), fn name ->
        case System.get_env(name) do
          value when is_binary(value) -> String.trim(value) != ""
          nil -> false
        end
      end)

    if missing != [] do
      flunk("""
      Missing Deribit testnet credentials: #{Enum.join(missing, ", ")}

      Set:
        export DERIBIT_TESTNET_API_KEY="your_key"
        export DERIBIT_TESTNET_API_SECRET="your_secret"

      Get credentials at: https://test.deribit.com
      """)
    end
  end
end
