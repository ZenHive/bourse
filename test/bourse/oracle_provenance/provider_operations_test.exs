defmodule Bourse.OracleProvenance.ProviderOperationsTest do
  use ExUnit.Case, async: false

  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance
  alias Bourse.OracleProvenance.ProviderOperations
  alias Bourse.OracleProvenance.ProviderOperations.Capture
  alias Bourse.RecordedResponseFixtures
  alias Mix.Tasks.Ccxt.AuthorityCorpus
  alias Mix.Tasks.Ccxt.CaptureProviderOperations

  @plan_path "priv/authority/deribit/provider-operation-plan.json"
  @fixture_root "test/fixtures/provider_operations"
  @fixed_now ~U[2026-08-11 04:00:00Z]

  test "committed captures preserve raw observations and independent contract axes" do
    corpus = ProviderOperations.validate!()
    facts = ProviderOperations.facts!()

    assert corpus.plan["source_inventory_facts"]["security_metadata"] == %{
             "document_security" => "absent",
             "operation_authentication" => "unknown",
             "security_schemes" => "absent"
           }

    assert length(corpus.plan["source_inventory_facts"]["websocket_only_operation_keys"]) == 10

    assert Enum.map(facts, &Map.take(&1, ~w(operation_key evidence reachability contract_scope))) == [
             %{
               "operation_key" => "GET /api/v2/public/get_time",
               "evidence" => "unverified",
               "reachability" => "safe",
               "contract_scope" => "current_rest"
             },
             %{
               "operation_key" => "GET /api/v2/public/ticker",
               "evidence" => "verified",
               "reachability" => "safe",
               "contract_scope" => "current_rest"
             }
           ]

    time = corpus.recordings["public_get_time_success"]
    ticker = corpus.recordings["public_ticker_populated_success"]
    invalid = corpus.recordings["public_ticker_invalid_parameter"]

    assert time["request"]["url"] == "https://test.deribit.com/api/v2/public/get_time"
    assert time["response"]["http_status"] == 200
    assert is_integer(Jason.decode!(time["response"]["raw_body"])["result"])
    refute time["row_fields_populated"]

    assert ticker["response"]["http_status"] == 200
    assert Jason.decode!(ticker["response"]["raw_body"])["result"]["instrument_name"] == "BTC-PERPETUAL"
    assert ticker["row_fields_populated"]

    assert invalid["response"]["http_status"] == 400
    assert get_in(Jason.decode!(invalid["response"]["raw_body"]), ["error", "code"]) == -32_602
  end

  test "reviewed plan binds to the exact Task 555 inventory revision" do
    plan = JsonDocument.decode_file!(@plan_path)
    inventory = inventory_for(plan)

    assert :ok = ProviderOperations.validate_plan!(plan, inventory)

    changed = put_in(plan, ["source_revision", "sha256"], String.duplicate("0", 64))

    assert_raise ArgumentError, ~r/provider-artifact SHA-256 mismatch/, fn ->
      ProviderOperations.validate_plan!(changed, inventory)
    end
  end

  test "plan validation projects authentication from full comparison rows" do
    plan = JsonDocument.decode_file!(@plan_path)

    inventory =
      update_in(inventory_for(plan), ["surfaces", "current_rest", "operations"], fn operations ->
        Enum.map(operations, fn operation ->
          update_in(operation["authored"], fn authored ->
            Enum.map(authored, &Map.put(&1, "runtime_scope", "unified"))
          end)
        end)
      end)

    assert :ok = ProviderOperations.validate_plan!(plan, inventory)
  end

  test "private, mutating, unclassified, upcoming, unsafe, WebSocket-only, and unreviewed seeds refuse" do
    plan = JsonDocument.decode_file!(@plan_path)
    operation = hd(plan["operations"])
    proof = hd(operation["proofs"])

    assert :ok = Capture.authorize(operation, proof)

    assert_refused(operation, proof, ["execution_review", "classification"], "unknown", :unclassified)
    assert_refused(operation, proof, ["execution_review", "exposure"], "private", :private)
    assert_refused(operation, proof, ["execution_review", "effect"], "write", :mutating)
    assert_refused(operation, proof, ["inventory_axes", "contract_scope"], "upcoming_rest", :upcoming)
    assert_refused(operation, proof, ["execution_review", "reachability"], "unsafe", :unsafe)
    assert_refused(operation, proof, ["provider", "qualifiers"], ["websocket_only"], :websocket_only)
    assert_refused(operation, proof, ["provider", "transport"], "websocket", :websocket_only)

    unclassified_review = update_in(operation, ["execution_review"], &Map.delete(&1, "exposure"))
    assert {:error, {:refused, :unclassified}} = Capture.authorize(unclassified_review, proof)

    unreviewed = put_in(proof, ["request_review", "decision"], "pending")
    assert {:error, {:refused, :unreviewed_request_seed}} = Capture.authorize(operation, unreviewed)
  end

  test "source inventory prevents private or mutating operations from being relabeled safe" do
    plan = JsonDocument.decode_file!(@plan_path)
    operation = hd(plan["operations"])
    proof = hd(operation["proofs"])
    inventory_operation = hd(inventory_for(plan)["surfaces"]["current_rest"]["operations"])

    forged_public =
      put_in(inventory_operation, ["authored", Access.at(0), "authentication", "value", "required"], false)

    assert {:error, {:refused, :private}} =
             Capture.authorize(operation, proof, forged_public, authentication(true))

    mutating = put_in(inventory_operation, ["provider", Access.at(0), "method"], "POST")

    assert {:error, {:refused, :mutating}} =
             Capture.authorize(operation, proof, mutating, authentication(false))
  end

  test "source inventory rejects missing and contradictory authorization facts" do
    plan = JsonDocument.decode_file!(@plan_path)
    operation = hd(plan["operations"])
    proof = hd(operation["proofs"])
    read = %{"provider" => [%{"method" => "GET"}]}

    assert {:error, {:refused, :unclassified}} = Capture.authorize(operation, proof, %{}, [])
    assert {:error, {:refused, :unclassified}} = Capture.authorize(operation, proof, read, [])

    unclassified = [%{"authentication" => %{"status" => "unknown"}}]
    assert {:error, {:refused, :unclassified}} = Capture.authorize(operation, proof, read, unclassified)

    private = authentication(true) ++ authentication(false)

    assert {:error, {:refused, :private}} = Capture.authorize(operation, proof, read, private)
  end

  test "oracle validation re-applies capture authorization to a post-hoc plan edit" do
    root = temporary_directory("post-hoc-plan-edit")
    File.cp_r!(@fixture_root, root)
    plan = JsonDocument.decode_file!(@plan_path)
    changed = put_in(plan, ["operations", Access.at(0), "execution_review", "exposure"], "private")
    changed_path = Path.join(root, "changed-plan.json")
    File.write!(changed_path, Jason.encode!(changed, pretty: true))

    assert_raise ArgumentError, ~r/capture proof public_get_time_success refused: private/, fn ->
      ProviderOperations.validate!(
        root: root,
        manifest_path: Path.join(root, "_manifest.json"),
        plan_path: changed_path
      )
    end
  end

  test "oracle validation rejects a public plan classification for a private inventory operation" do
    root = temporary_directory("private-inventory-operation")
    File.cp_r!(@fixture_root, root)
    manifest_path = Path.join(root, "_manifest.json")
    manifest = JsonDocument.decode_file!(manifest_path)

    operation_index =
      Enum.find_index(
        manifest["inventory"]["surfaces"]["current_rest"]["operations"],
        &(&1["operation_key"] == "GET /api/v2/public/get_time")
      )

    changed =
      put_in(
        manifest,
        [
          "inventory",
          "surfaces",
          "current_rest",
          "operations",
          Access.at(operation_index),
          "authored",
          Access.at(0),
          "authentication",
          "value",
          "required"
        ],
        true
      )

    File.write!(manifest_path, Jason.encode!(changed, pretty: true))

    assert_raise ArgumentError, ~r/authored authentication differs from pinned authored spec/, fn ->
      ProviderOperations.validate!(root: root, manifest_path: manifest_path)
    end
  end

  test "plan validation re-derives authentication from the pinned authored document" do
    root = temporary_directory("pinned-authored-authentication")
    spec_root = Path.join(root, "authored")
    File.mkdir_p!(spec_root)
    plan = JsonDocument.decode_file!(@plan_path)

    authored =
      plan["venue"]
      |> Bourse.Spec.owned_spec_path()
      |> JsonDocument.decode_file!()
      |> put_in(["auth", "authenticated_sections"], ["private", "public"])

    File.write!(Path.join(spec_root, "deribit.json"), Jason.encode!(authored, pretty: true))

    inventory =
      plan
      |> inventory_for()
      |> put_in(["provenance", "authored_spec_canonical_sha256"], canonical_sha256(authored))

    assert_raise ArgumentError, ~r/authored authentication differs from pinned authored spec/, fn ->
      ProviderOperations.validate_plan!(plan, inventory, spec_root: spec_root)
    end
  end

  test "a refused operation cannot reach the request adapter" do
    root = temporary_directory("refused-before-request")
    plan = JsonDocument.decode_file!(@plan_path)
    inventory_path = write_inventory!(root)
    refused_plan = put_in(plan, ["operations", Access.at(0), "execution_review", "exposure"], "private")
    refused_plan_path = Path.join(root, "refused-plan.json")
    File.write!(refused_plan_path, Jason.encode!(refused_plan, pretty: true))

    request_fun = fn _request -> flunk("refused operation reached the request adapter") end

    assert_raise ArgumentError, ~r/capture proof public_get_time_success refused: private/, fn ->
      Capture.capture_all!(inventory_path, refused_plan_path, Path.join(root, "output"),
        request_fun: request_fun,
        now: fn -> @fixed_now end
      )
    end
  end

  test "capture identifiers cannot escape the output root" do
    root = temporary_directory("unsafe-capture-path")
    plan = JsonDocument.decode_file!(@plan_path)
    inventory = inventory_for(plan)
    changed = put_in(plan, ["operations", Access.at(0), "proofs", Access.at(0), "capture_id"], "../escape")

    assert_raise ArgumentError, ~r/capture proof capture_id must be a safe path component/, fn ->
      ProviderOperations.validate_plan!(changed, inventory)
    end

    manifest_path = Path.join(root, "_manifest.json")
    File.cp_r!(@fixture_root, root)
    manifest = JsonDocument.decode_file!(manifest_path)
    changed = put_in(manifest, ["recordings", Access.at(0), "path"], "../../outside.json")
    File.write!(manifest_path, Jason.encode!(changed, pretty: true))

    assert_raise ArgumentError, ~r/resolves outside its corpus root/, fn ->
      ProviderOperations.validate!(root: root, manifest_path: manifest_path)
    end
  end

  test "capture writes exact scrubbed requests and raw responses without unified parsing" do
    output_root = temporary_directory("raw-capture")
    plan = JsonDocument.decode_file!(@plan_path)
    inventory_path = write_inventory!(output_root)
    request_fun = request_fun()

    manifest =
      RecordedResponseFixtures.capture_provider_operations!(inventory_path, @plan_path, output_root,
        request_fun: request_fun,
        now: fn -> @fixed_now end
      )

    assert length(manifest["recordings"]) == 3
    assert Enum.map(manifest["operations"], & &1["evidence"]) == ["unverified", "verified"]
    assert manifest["inventory"] == ProviderOperations.inventory_snapshot(plan, inventory_for(plan))

    fixture = JsonDocument.decode_file!(Path.join(output_root, "deribit/public_ticker_populated_success.json"))
    assert fixture["request"]["body"] == nil
    assert fixture["request"]["headers"] == [%{"name" => "accept", "value" => "application/json"}]
    assert fixture["response"]["raw_body"] =~ ~s("instrument_name":"BTC-PERPETUAL")
    assert fixture["captured_at"] == "2026-08-11T04:00:00Z"
  end

  test "raw HTTP execution preserves the undecoded response body" do
    stub = make_ref()
    raw_body = ~s({"jsonrpc":"2.0","result":{"instrument_name":"BTC-PERPETUAL"}})

    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, raw_body)
    end)

    request = %{
      "method" => "GET",
      "url" => "https://test.deribit.com/api/v2/public/ticker?instrument_name=BTC-PERPETUAL",
      "headers" => [%{"name" => "accept", "value" => "application/json"}],
      "body" => nil
    }

    assert {:ok, %Req.Response{status: 200, body: ^raw_body}} =
             Capture.execute_raw_request(request, plug: {Req.Test, stub})
  end

  test "capture fails loudly on transport errors and invalid adapter results" do
    inventory_root = temporary_directory("transport-errors")
    inventory_path = write_inventory!(inventory_root)

    assert_raise ArgumentError, ~r/transport failed: :closed/, fn ->
      Capture.capture_all!(inventory_path, @plan_path, temporary_directory("transport-closed"),
        request_fun: fn _request -> {:error, :closed} end,
        now: fn -> @fixed_now end
      )
    end

    assert_raise ArgumentError, ~r/invalid transport result: :invalid/, fn ->
      Capture.capture_all!(inventory_path, @plan_path, temporary_directory("transport-invalid"),
        request_fun: fn _request -> :invalid end,
        now: fn -> @fixed_now end
      )
    end
  end

  test "capture requires the exact inventory document before using its default transport" do
    missing_inventory = Path.join(temporary_directory("missing-inventory"), "inventory.json")

    assert_raise File.Error, fn ->
      Capture.capture_all!(missing_inventory, @plan_path, temporary_directory("unused-output"))
    end
  end

  test "empty success cannot establish row-field semantics" do
    output_root = temporary_directory("empty-row")
    inventory_path = write_inventory!(output_root)

    request_fun = fn request ->
      if String.contains?(request["url"], "BTC-PERPETUAL") do
        {:ok, %{status: 200, body: ~s({"jsonrpc":"2.0","result":{}})}}
      else
        request_fun().(request)
      end
    end

    assert_raise ArgumentError, ~r/row-field evidence requires populated domain data/, fn ->
      Capture.capture_all!(inventory_path, @plan_path, output_root,
        request_fun: request_fun,
        now: fn -> @fixed_now end
      )
    end
  end

  test "deleting a registered capture reds the oracle boundary" do
    output_root = temporary_directory("missing-capture")
    File.cp_r!(@fixture_root, output_root)
    missing = Path.join(output_root, "deribit/public_get_time_success.json")
    File.rm!(missing)

    assert_raise ArgumentError, ~r/registered provider-operation capture is missing/, fn ->
      OracleProvenance.binary_reports!(
        provider_operation_root: output_root,
        provider_operation_manifest: Path.join(output_root, "_manifest.json")
      )
    end
  end

  test "capture task requires the exact inventory, reviewed plan, and output root" do
    assert_raise Mix.Error, ~r/--inventory is required/, fn ->
      CaptureProviderOperations.run([])
    end

    assert_raise Mix.Error, ~r/--plan is required/, fn ->
      CaptureProviderOperations.run(["--inventory", "inventory.json"])
    end

    assert_raise Mix.Error, ~r/--output is required/, fn ->
      CaptureProviderOperations.run(["--inventory", "inventory.json", "--plan", @plan_path])
    end

    assert_raise Mix.Error, ~r/unexpected arguments: extra/, fn ->
      CaptureProviderOperations.run(["extra"])
    end
  end

  test "capture task records the reviewed plan through the recording facade" do
    output_root = temporary_directory("mix-task")
    inventory_path = write_inventory!(output_root)

    assert :ok =
             CaptureProviderOperations.run(
               ["--inventory", inventory_path, "--plan", @plan_path, "--output", output_root],
               request_fun: request_fun(),
               now: fn -> @fixed_now end
             )

    assert File.regular?(Path.join(output_root, "_manifest.json"))
  end

  defp assert_refused(operation, proof, path, value, reason) do
    changed = put_in(operation, path, value)
    assert {:error, {:refused, ^reason}} = Capture.authorize(changed, proof)
  end

  defp write_inventory!(root) do
    plan = JsonDocument.decode_file!(@plan_path)
    path = Path.join(root, "inventory.json")
    File.write!(path, Jason.encode!(inventory_for(plan), pretty: true))
    path
  end

  defp inventory_for(plan) do
    source = plan["source_revision"]

    selected =
      Enum.map(plan["operations"], fn operation ->
        %{
          "operation_key" => operation["operation_key"],
          "axes" => operation["inventory_axes"],
          "provider" => [operation["provider"]],
          "authored" => [
            %{
              "authentication" => %{
                "status" => "known",
                "value" => %{"required" => false}
              }
            }
          ]
        }
      end)

    websocket_only =
      Enum.map(plan["source_inventory_facts"]["websocket_only_operation_keys"], fn key ->
        [method, path] = String.split(key, " ", parts: 2)

        %{
          "operation_key" => key,
          "axes" => %{
            "relation" => "shared",
            "runtime_scope" => "raw_only",
            "evidence" => "unverified",
            "reachability" => "unknown",
            "contract_scope" => "current_rest"
          },
          "provider" => [
            %{
              "transport" => "rest",
              "method" => method,
              "path" => path,
              "authentication" => %{"status" => "unknown"},
              "qualifiers" => ["websocket_only"]
            }
          ],
          "authored" => []
        }
      end)

    %{
      "schema_version" => 1,
      "report_type" => "provider_contract_comparison",
      "venue" => plan["venue"],
      "provenance" => %{
        "authority_manifest" => "priv/authority/deribit/manifest.json",
        "authored_spec_canonical_sha256" => authored_spec_sha256(plan["venue"]),
        "artifacts" => [
          %{
            "id" => source["artifact_id"],
            "sha256" => source["sha256"],
            "upstream_pin" => source["upstream_pin"],
            "metrics" => %{
              "path_count" => 182,
              "unknown_authentication_count" => 182,
              "websocket_only_operation_count" => 10
            }
          }
        ]
      },
      "surfaces" => %{
        "current_rest" => %{
          "provider_count" => 182,
          "operations" => selected ++ websocket_only
        }
      }
    }
  end

  defp request_fun do
    fn request ->
      cond do
        String.ends_with?(request["url"], "/public/get_time") ->
          {:ok, %{status: 200, body: ~s({"jsonrpc":"2.0","result":1786420800000,"testnet":true})}}

        String.contains?(request["url"], "BTC-PERPETUAL") ->
          {:ok,
           %{
             status: 200,
             body: ~s({"jsonrpc":"2.0","result":{"instrument_name":"BTC-PERPETUAL","last_price":64000.0}})
           }}

        String.contains?(request["url"], "BTC-NOTAREAL") ->
          {:ok,
           %{
             status: 400,
             body: ~s({"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params"},"testnet":true})
           }}
      end
    end
  end

  defp authentication(required) do
    [%{"authentication" => %{"status" => "known", "value" => %{"required" => required}}}]
  end

  defp authored_spec_sha256(venue) do
    venue
    |> Bourse.Spec.owned_spec_path()
    |> JsonDocument.decode_file!()
    |> canonical_sha256()
  end

  defp canonical_sha256(document), do: document |> Jason.encode!() |> AuthorityCorpus.sha256()

  defp temporary_directory(label) do
    path = Path.join(System.tmp_dir!(), "provider-operations-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
