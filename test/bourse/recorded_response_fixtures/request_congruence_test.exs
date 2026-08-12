defmodule Bourse.RecordedResponseFixtures.RequestCongruenceTest do
  use ExUnit.Case, async: true

  alias Bourse.OracleProvenance
  alias Bourse.RecordedResponseFixtures.Capture
  alias Bourse.RecordedResponseFixtures.RequestCongruence

  test "every private recording is reproducible and every injection is exact" do
    assert :ok = RequestCongruence.validate!()

    assert Capture.param_injections() |> Map.keys() |> Enum.sort() == [
             {"lighter", :fetch_closed_orders},
             {"lighter", :fetch_deposits},
             {"lighter", :fetch_open_orders}
           ]
  end

  test "a capture-injected param omitted by the runtime builder is red with its name" do
    fixture = %{
      "caller_params" => %{},
      "params" => %{"l1_address" => "***REDACTED***"}
    }

    injection = %{
      "params" => ["l1_address"],
      "reason" => "capture resolves the provisioned account's L1 address"
    }

    assert_raise ArgumentError, ~r/runtime request builder cannot emit recorded params: l1_address/, fn ->
      RequestCongruence.validate_case!(
        "lighter",
        :fetch_deposits,
        fixture,
        [%{"account_index" => "1", "auth_deadline" => "deadline"}],
        injection
      )
    end
  end

  test "a reasoned exact exemption permits a capture-only lookup" do
    fixture = %{"caller_params" => %{}, "params" => %{"l1_address" => "***REDACTED***"}}

    injection = %{
      "exempt_params" => ["l1_address"],
      "params" => ["l1_address"],
      "reason" => "capture resolves the provisioned account's L1 address"
    }

    assert ["l1_address"] =
             RequestCongruence.validate_case!("lighter", :fetch_deposits, fixture, [], injection)
  end

  test "an unregistered capture-only param is red before it can become evidence" do
    fixture = %{"caller_params" => %{}, "params" => %{"capture_only" => true}}

    assert_raise ArgumentError, ~r/unregistered capture-only params: capture_only/, fn ->
      RequestCongruence.validate_case!("venue", :fetch_balance, fixture, [%{"capture_only" => true}], nil)
    end
  end

  test "the binary oracle boundary runs request congruence first" do
    root = temporary_directory("oracle-boundary")
    fixture_path = Path.join(root, "bybit/fetch_balance.json")
    File.mkdir_p!(Path.dirname(fixture_path))

    File.write!(
      fixture_path,
      Jason.encode!(%{"caller_params" => %{}, "params" => %{"capture_only" => true}})
    )

    manifest_path = Path.join(root, "_manifest.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "recordings" => [
          %{"method" => "fetch_balance", "path" => "bybit/fetch_balance.json", "venue" => "bybit"}
        ]
      })
    )

    assert_raise ArgumentError, ~r/unregistered capture-only params: capture_only/, fn ->
      OracleProvenance.binary_reports!(recording_root: root, recording_manifest: manifest_path)
    end
  end

  defp temporary_directory(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "bourse-request-congruence-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end
end
