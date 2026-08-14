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
             {"lighter", :fetch_my_liquidations},
             {"lighter", :fetch_my_trades},
             {"lighter", :fetch_open_orders},
             {"lighter", :fetch_transfers},
             {"lighter", :fetch_withdrawals}
           ]

    assert Map.new(Capture.param_injections(), fn {key, injection} ->
             {key, Map.take(injection, ~w(exempt_params params))}
           end) == %{
             {"lighter", :fetch_closed_orders} => %{
               "exempt_params" => ["auth_deadline"],
               "params" => ["auth_deadline"]
             },
             {"lighter", :fetch_deposits} => %{
               "exempt_params" => ["auth_deadline"],
               "params" => ["auth_deadline"]
             },
             {"lighter", :fetch_my_liquidations} => %{
               "exempt_params" => ["auth_deadline"],
               "params" => ["auth_deadline"]
             },
             {"lighter", :fetch_my_trades} => %{
               "exempt_params" => ["auth_deadline"],
               "params" => ["auth_deadline"]
             },
             {"lighter", :fetch_open_orders} => %{
               "exempt_params" => ["auth_deadline"],
               "params" => ["auth_deadline"]
             },
             {"lighter", :fetch_transfers} => %{
               "exempt_params" => ["auth_deadline"],
               "params" => ["auth_deadline"]
             },
             {"lighter", :fetch_withdrawals} => %{
               "exempt_params" => ["auth_deadline"],
               "params" => ["auth_deadline"]
             }
           }

    assert length(RequestCongruence.legacy_missing_caller_params()) == 50
  end

  test "a recorded caller param omitted by the runtime builder is red with its name" do
    fixture = %{
      "caller_params" => %{"account_index" => "***REDACTED***", "l1_address" => "***REDACTED***"},
      "params" => %{
        "account_index" => "***REDACTED***",
        "auth_deadline" => 1_800_000_000,
        "l1_address" => "***REDACTED***"
      }
    }

    injection = %{
      "exempt_params" => ["auth_deadline"],
      "params" => ["auth_deadline"],
      "reason" => "capture supplies a time-varying authenticated history deadline"
    }

    assert_raise ArgumentError, ~r/runtime request builder drops caller params: l1_address/, fn ->
      RequestCongruence.validate_case!(
        "lighter",
        :fetch_deposits,
        fixture,
        [%{"account_index" => "1", "auth_deadline" => "deadline"}],
        injection
      )
    end
  end

  test "a reasoned exact exemption permits only the time-varying auth deadline" do
    fixture = %{
      "caller_params" => %{"account_index" => "***REDACTED***", "l1_address" => "***REDACTED***"},
      "params" => %{
        "account_index" => "***REDACTED***",
        "auth_deadline" => 1_800_000_000,
        "l1_address" => "***REDACTED***"
      }
    }

    injection = %{
      "exempt_params" => ["auth_deadline"],
      "params" => ["auth_deadline"],
      "reason" => "capture supplies a time-varying authenticated history deadline"
    }

    assert ["auth_deadline"] =
             RequestCongruence.validate_case!(
               "lighter",
               :fetch_deposits,
               fixture,
               [
                 %{
                   "account_index" => "1",
                   "auth_deadline" => "deadline",
                   "l1_address" => "0x0000000000000000000000000000000000000000"
                 }
               ],
               injection
             )
  end

  test "an unregistered capture-only param is red before it can become evidence" do
    fixture = %{"caller_params" => %{}, "params" => %{"capture_only" => true}}

    assert_raise ArgumentError, ~r/unregistered capture-only params: capture_only/, fn ->
      RequestCongruence.validate_case!("venue", :fetch_balance, fixture, [%{"capture_only" => true}], nil)
    end
  end

  test "caller inputs are required instead of falling back to emitted params" do
    fixture = %{"params" => %{"symbol" => "BTC/USDT"}}

    assert_raise ArgumentError, ~r/recorded caller inputs must be a map, got: nil/, fn ->
      RequestCongruence.validate_case!("bybit", :fetch_open_orders, fixture, [], nil)
    end
  end

  test "a malformed runtime shape cannot satisfy caller-param reachability" do
    fixture = %{
      "caller_params" => %{"account_index" => 1},
      "params" => %{"account_index" => 1}
    }

    assert_raise ArgumentError, ~r/runtime request builder drops caller params: account_index/, fn ->
      RequestCongruence.validate_case!("lighter", :fetch_balance, fixture, [:not_a_shape], nil)
    end
  end

  test "nil emitted params do not count as checked private evidence" do
    fixture = %{
      "caller_params" => %{},
      "captured_at" => "2026-08-14T00:00:00Z",
      "params" => nil
    }

    {root, manifest_path} = write_corpus("nil-params", "bybit/fetch_balance.json", fixture, fixture)

    assert_raise ArgumentError, ~r/capture param-injection registry differs from recordings/, fn ->
      RequestCongruence.validate!(root: root, manifest_path: manifest_path)
    end
  end

  test "a new param-carrying recording without caller inputs is red" do
    fixture = %{
      "captured_at" => "2026-08-14T00:00:00Z",
      "params" => %{"symbol" => "BTC/USDT"}
    }

    {root, manifest_path} = write_corpus("new-missing-caller", "bybit/new_capture.json", fixture, fixture)

    assert_raise ArgumentError, ~r/new param-carrying capture without caller_params/, fn ->
      RequestCongruence.validate!(root: root, manifest_path: manifest_path)
    end
  end

  test "manifest provenance rejects caller-input substitution and param deletion" do
    fixture = %{
      "caller_params" => %{},
      "captured_at" => "2026-08-14T00:00:00Z",
      "params" => %{"capture_only" => true}
    }

    substituted = Map.put(fixture, "caller_params", fixture["params"])

    {substituted_root, substituted_manifest} =
      write_corpus("substituted-caller", "bybit/fetch_balance.json", fixture, substituted)

    assert_raise ArgumentError, ~r/request-param provenance differs from manifest/, fn ->
      RequestCongruence.validate!(root: substituted_root, manifest_path: substituted_manifest)
    end

    deleted = Map.delete(fixture, "params")
    {deleted_root, deleted_manifest} = write_corpus("deleted-params", "bybit/fetch_balance.json", fixture, deleted)

    assert_raise ArgumentError, ~r/request-param provenance differs from manifest/, fn ->
      RequestCongruence.validate!(root: deleted_root, manifest_path: deleted_manifest)
    end
  end

  test "the binary oracle boundary runs request congruence first" do
    root = temporary_directory("oracle-boundary")
    fixture_path = Path.join(root, "bybit/fetch_balance.json")
    File.mkdir_p!(Path.dirname(fixture_path))

    fixture = %{"caller_params" => %{}, "params" => %{"capture_only" => true}}
    File.write!(fixture_path, Jason.encode!(fixture))

    manifest_path = Path.join(root, "_manifest.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "recordings" => [
          %{
            "method" => "fetch_balance",
            "path" => "bybit/fetch_balance.json",
            "request_params_sha256" => RequestCongruence.request_params_sha256(fixture),
            "venue" => "bybit"
          }
        ]
      })
    )

    assert_raise ArgumentError, ~r/unregistered capture-only params: capture_only/, fn ->
      OracleProvenance.binary_reports!(recording_root: root, recording_manifest: manifest_path)
    end
  end

  defp write_corpus(label, relative_path, provenance_fixture, written_fixture) do
    root = temporary_directory(label)
    fixture_path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(fixture_path))
    File.write!(fixture_path, Jason.encode!(written_fixture))
    manifest_path = Path.join(root, "_manifest.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "recordings" => [
          %{
            "method" => "fetch_balance",
            "path" => relative_path,
            "request_params_sha256" => RequestCongruence.request_params_sha256(provenance_fixture),
            "venue" => "bybit"
          }
        ]
      })
    )

    {root, manifest_path}
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
