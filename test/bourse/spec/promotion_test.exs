defmodule Bourse.Spec.PromotionTest do
  use ExUnit.Case, async: true

  alias Bourse.OracleProvenance.Derivation
  alias Bourse.ReferenceSlice
  alias Bourse.Spec.Promotion

  @reference_path "priv/specs/json/output/bybit.json"
  @owned_path "priv/specs/json/output/authored/bybit.json"
  @authority_path "priv/authority/bybit/manifest.json"
  @carve_path "docs/authored-spec-carves/bybit.md"
  @integration_path "test/bourse/bybit_authored_integration_test.exs"

  test "preparation is deterministic, exhaustive, and makes no support claim" do
    {candidate, report} = Promotion.prepare_file!(@reference_path)
    {candidate_again, report_again} = Promotion.prepare_file!(@reference_path)
    reference = Bourse.Spec.decode_file!(@reference_path)

    assert Promotion.encode!(candidate) == Promotion.encode!(candidate_again)
    assert Promotion.encode!(report) == Promotion.encode!(report_again)
    assert candidate["authored"] == false
    assert candidate["hand_owned"] == false
    assert candidate["frozen"] == false
    assert candidate["raw"]["describe"]["api"] == reference["raw"]["describe"]["api"]
    assert candidate["fees"] == reference["fees"]
    assert get_in(candidate, ~w(auth sign_recipe promotion_status)) == "unresolved"
    assert get_in(candidate, ~w(normalization field_maps promotion_status)) == "unresolved"
    assert get_in(candidate, ~w(markets patterns promotion_status)) == "unresolved"
    assert candidate["emulated_methods"] == ["__promotion_unresolved__"]
    refute Map.has_key?(candidate["raw"]["describe"], "has")

    methods = candidate["capabilities"]["has"] |> Map.keys() |> Enum.sort()
    assert methods != []
    assert methods == candidate["endpoints"]["unified"] |> Map.keys() |> Enum.sort()
    assert Enum.all?(methods, &(candidate["capabilities"]["has"][&1] == false))
    assert Enum.all?(methods, &(candidate["endpoints"]["unified"][&1] == []))

    assert report["status"] == "candidate"
    assert report["trading_venue"] == "unresolved"
    assert report["reference"]["kind"] == "ccxt"
    assert report["reference"]["sha256"] == Promotion.sha256(File.read!(@reference_path))
    assert Enum.any?(report["items"], &(&1["id"] == "decision:emulated_methods"))

    for item <- report["items"] do
      assert Map.has_key?(item, "semantic_authority")
      assert Map.has_key?(item, "compatibility_reference")
      assert is_list(item["provenance"])
      assert item["verification"] in ~w(verified unverified)
    end

    encoded_report = Promotion.encode!(report)
    refute encoded_report =~ ~s("oracle":)
    refute encoded_report =~ ~s("verified":)
  end

  test "an untouched candidate is refused with schema, authoring, and evidence gaps" do
    {candidate, report} = Promotion.prepare_file!(@reference_path)

    assert {:error, gaps} = Promotion.promote(candidate, report)
    codes = MapSet.new(gaps, & &1.code)

    assert :schema_invalid in codes
    assert :interpretive_slot_unresolved in codes
    assert :decision_not_provider_authoritative in codes
    assert :trading_classification_unresolved in codes
    assert :oracle_gate_contract_missing in codes

    assert Enum.any?(gaps, fn gap ->
             gap.code == :interpretive_slot_unresolved and gap.item_id == "decision:emulated_methods"
           end)
  end

  test "unsupported methods cannot retain a route" do
    candidate = promotion_candidate()
    report = complete_report(candidate)
    candidate = put_in(candidate, ~w(capabilities has fetchTicker), false)
    report = put_capability_status(report, "fetchTicker", "unsupported", candidate)

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())

    assert Enum.any?(gaps, fn gap ->
             gap.code == :capability_contract_invalid and gap.item_id == "capability:fetchTicker"
           end)
  end

  test "candidate cannot drop a method from the prepared reference inventory" do
    candidate = promotion_candidate()
    report = complete_report(candidate)

    candidate =
      candidate
      |> update_in(["capabilities", "has"], &Map.delete(&1, "fetchTicker"))
      |> update_in(["endpoints", "unified"], &Map.delete(&1, "fetchTicker"))

    report = Map.put(report, "candidate_sha256", Promotion.sha256(Promotion.encode!(candidate)))

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :method_inventory_mismatch))
    refute Enum.any?(gaps, &(&1.code == :method_inventory_reference_drift))
  end

  test "both-sides method inventory deletion is refused against the pinned reference" do
    candidate = promotion_candidate()
    report = complete_report(candidate)

    candidate =
      candidate
      |> update_in(["capabilities", "has"], &Map.delete(&1, "fetchTicker"))
      |> update_in(["endpoints", "unified"], &Map.delete(&1, "fetchTicker"))

    report =
      report
      |> Map.update!("items", fn items ->
        Enum.reject(items, &(&1["id"] == "capability:fetchTicker"))
      end)
      |> Map.put("candidate_sha256", Promotion.sha256(Promotion.encode!(candidate)))

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :method_inventory_reference_drift))
    assert Enum.any?(gaps, &(&1.code == :method_inventory_mismatch))
  end

  test "pinned reference digest mismatch fails loudly" do
    candidate = promotion_candidate()
    report = complete_report(candidate)
    report = put_in(report, ["reference", "sha256"], String.duplicate("0", 64))

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :reference_digest_mismatch))
  end

  test "missing pinned reference file fails loudly" do
    candidate = promotion_candidate()
    report = complete_report(candidate)
    report = put_in(report, ["reference", "path"], "priv/specs/json/output/__missing_for_task_498__.json")

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :reference_missing))
  end

  test "missing report.reference.sha256 fails loudly" do
    candidate = promotion_candidate()
    report = complete_report(candidate)
    report = update_in(report, ["reference"], &Map.delete(&1, "sha256"))

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :reference_pin_missing))
  end

  test "missing report.reference.path fails loudly without --reference" do
    candidate = promotion_candidate()
    report = complete_report(candidate)
    report = update_in(report, ["reference"], &Map.delete(&1, "path"))

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :reference_path_missing))
  end

  test "concurrent promotion venues retain the reference-derived method inventory" do
    # Tasks 429 (alpaca) and 451 (lighter) completed around this gate; 450
    # (binancecoinm) depends on this fix and is included when its owned doc lands.
    for venue <- concurrent_promotion_venues() do
      reference_path = ReferenceSlice.spec_path(venue)
      owned_path = Bourse.Spec.owned_spec_path(venue)
      assert is_binary(owned_path) and File.regular?(owned_path)

      {prepared, report} = Promotion.prepare_file!(reference_path)
      expected = prepared["capabilities"]["has"] |> Map.keys() |> Enum.sort()
      owned = Bourse.Spec.decode_file!(owned_path)

      assert owned["capabilities"]["has"] |> Map.keys() |> Enum.sort() == expected
      assert owned["endpoints"]["unified"] |> Map.keys() |> Enum.sort() == expected
      assert report["reference"]["sha256"] == Promotion.sha256(File.read!(reference_path))
    end
  end

  test "heuristically defaulted interpretive values cannot promote" do
    candidate = promotion_candidate()
    candidate = put_in(candidate, ~w(auth sign_recipe provenance), "defaulted")
    report = complete_report(candidate)

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())

    assert Enum.any?(gaps, fn gap ->
             gap.code == :interpretive_slot_unresolved and gap.item_id == "decision:auth.sign_recipe"
           end)
  end

  test "Bourse-only compatibility cannot promote an interpretive decision" do
    candidate = promotion_candidate()
    report = complete_report(candidate)

    report =
      update_item(report, "decision:auth.sign_recipe", fn item ->
        item
        |> Map.put("status", "authored")
        |> Map.put("semantic_authority", nil)
        |> Map.put("provenance", [report["reference"]])
        |> Map.put("verification", "unverified")
      end)

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())

    assert Enum.any?(gaps, fn gap ->
             gap.code == :decision_not_provider_authoritative and
               gap.item_id == "decision:auth.sign_recipe"
           end)
  end

  test "integration evidence must carry loud credential setup instructions" do
    candidate = promotion_candidate()

    report =
      candidate
      |> complete_report()
      |> update_item("contract:integration_tests", fn item ->
        put_in(item, ["details", "credential_setup", "export_commands"], [])
      end)

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :credential_setup_incomplete))
  end

  test "a public-only candidate records authenticated contracts as not applicable" do
    candidate =
      promotion_candidate()
      |> put_in(["auth", "authenticated_sections"], [])
      |> put_in(["auth", "signing_config"], %{})
      |> put_in(["auth", "signing_pattern"], nil)
      |> put_in(["auth", "sign_recipe"], %{})

    report =
      candidate
      |> complete_report()
      |> update_item("contract:authenticated:success", &public_only_contract/1)
      |> update_item("contract:authenticated:error", &public_only_contract/1)
      |> update_item("contract:integration_tests", fn item ->
        put_in(item, ["details", "credential_setup"], %{
          "public_only" => true,
          "environment_variables" => [],
          "export_commands" => [],
          "credentials_url" => "https://docs.example.test/public-api"
        })
      end)

    assert {:ok, promoted} =
             Promotion.promote(candidate, report,
               command_runner: passing_runner(),
               root: promotion_root!(candidate)
             )

    assert promoted["auth"]["authenticated_sections"] == []
    assert promoted["auth"]["signing_pattern"] == nil
  end

  test "an integration test that silently skips cannot promote" do
    candidate = promotion_candidate()
    source = File.read!(@integration_path) <> "\n# @moduletag :skip\n"
    path = Path.join(System.tmp_dir!(), "promotion_skipping_#{System.unique_integer([:positive])}_test.exs")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    report =
      candidate
      |> complete_report()
      |> update_item("contract:integration_tests", &put_in(&1, ["details", "paths"], [path]))

    assert {:error, gaps} =
             Promotion.promote(candidate, report,
               command_runner: passing_runner(),
               reference: Path.expand(@reference_path),
               root: System.tmp_dir!()
             )

    assert Enum.any?(gaps, &(&1.code == :integration_test_silently_skips))
  end

  test "integration evidence cannot read files outside the promotion root" do
    candidate = promotion_candidate()
    path = Path.expand(@integration_path)
    root = Path.join(System.tmp_dir!(), "promotion_root_#{System.unique_integer([:positive])}")

    report =
      candidate
      |> complete_report()
      |> update_item("contract:integration_tests", &put_in(&1, ["details", "paths"], [path]))

    assert {:error, gaps} =
             Promotion.promote(candidate, report,
               command_runner: passing_runner(),
               reference: Path.expand(@reference_path),
               root: root
             )

    assert Enum.any?(gaps, fn gap ->
             gap.code == :integration_test_missing and String.contains?(gap.message, "outside_root")
           end)
  end

  test "a required authoring decision cannot be dropped from the report" do
    candidate = promotion_candidate()

    report =
      candidate
      |> complete_report()
      |> Map.update!("items", fn items -> Enum.reject(items, &(&1["id"] == "decision:errors")) end)

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())

    assert Enum.any?(gaps, fn gap ->
             gap.code == :decision_evidence_missing and gap.item_id == "decision:errors"
           end)
  end

  test "a non-trading venue promotes without create/fetch/cancel lifecycle evidence" do
    candidate = promotion_candidate()

    report =
      candidate
      |> complete_report()
      |> Map.put("trading_venue", false)
      |> Map.update!("items", fn items ->
        Enum.reject(items, &(&1["id"] == "contract:trading:lifecycle"))
      end)

    assert {:ok, promoted} =
             Promotion.promote(candidate, report,
               command_runner: passing_runner(),
               root: promotion_root!(candidate)
             )

    assert promoted["authored"] == true
  end

  test "critical slot registrations must prove the slot's expected method" do
    candidate = promotion_candidate()
    root = promotion_root!(candidate)

    [%{path: victim_path}, %{path: donor_path} | _rest] =
      candidate
      |> critical_recording_entries()
      |> Enum.filter(&String.starts_with?(&1.slot, "request_shape."))

    report =
      candidate
      |> complete_report()
      |> update_item("check:oracle_gate", fn item ->
        update_in(item, ["details", "critical_recordings"], fn recordings ->
          Enum.map(recordings, fn
            %{"path" => ^victim_path} = recording -> Map.put(recording, "path", donor_path)
            recording -> recording
          end)
        end)
      end)

    assert {:error, gaps} =
             Promotion.promote(candidate, report, command_runner: passing_runner(), root: root)

    assert Enum.any?(gaps, &(&1.code == :critical_recording_method_mismatch))
  end

  test "oracle gate is executed and can refuse promotion" do
    candidate = promotion_candidate()
    report = complete_report(candidate)
    runner = fn _executable, _args, _root -> {"oracle mismatch", 2} end

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: runner)
    assert Enum.any?(gaps, &(&1.code == :oracle_gate_failed))
  end

  test "every critical slot requires a reality-manifest registration" do
    candidate = promotion_candidate()

    report =
      candidate
      |> complete_report()
      |> update_item("check:oracle_gate", fn item ->
        update_in(item, ["details", "critical_recordings"], &tl/1)
      end)

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :critical_recording_missing))
  end

  test "critical slot registrations must resolve in the matching reality manifest" do
    candidate = promotion_candidate()

    report =
      candidate
      |> complete_report()
      |> update_item("check:oracle_gate", fn item ->
        update_in(item, ["details", "critical_recordings"], fn [first | rest] ->
          [Map.put(first, "path", "bybit/not-registered.json") | rest]
        end)
      end)

    assert {:error, gaps} = Promotion.promote(candidate, report, command_runner: passing_runner())
    assert Enum.any?(gaps, &(&1.code == :critical_recording_unregistered))
  end

  test "an already-promoted venue proves the gate end to end without runtime registration" do
    candidate = promotion_candidate()
    report = complete_report(candidate)
    parent = self()

    runner = fn executable, args, root ->
      send(parent, {:oracle_command, executable, args, root})
      {"oracle gate passed", 0}
    end

    assert {:ok, promoted} =
             Promotion.promote(candidate, report,
               command_runner: runner,
               root: promotion_root!(candidate)
             )

    assert promoted["authored"] == true
    assert promoted["hand_owned"] == true
    assert promoted["frozen"] == true

    assert_receive {:oracle_command, "mix", ["ccxt.oracle_gate"], _root}

    endpoints = Bourse.Exchange.build_endpoint_configs(promoted["raw"]["describe"]["api"])
    mapping = Bourse.Exchange.build_unified_method_mapping(promoted, endpoints)

    for {method, false} <- promoted["capabilities"]["has"] do
      method_atom =
        Enum.find_value(Bourse.Unified.method_defs(), fn {atom, js_name, _required, _description} ->
          if js_name == method, do: atom
        end)

      if method_atom, do: refute(Map.has_key?(mapping, method_atom))
    end
  end

  defp complete_report(candidate) do
    {_prepared, report} = Promotion.prepare_file!(@reference_path)
    semantic = %{"kind" => "provider_owned", "reference" => @authority_path}
    observation = %{"kind" => "recorded_venue", "reference" => "test/fixtures/responses/bybit"}

    items =
      Enum.map(
        report["items"],
        &complete_item(&1, candidate, semantic, observation, report["reference"])
      )

    trading_item =
      %{
        "id" => "contract:trading:lifecycle",
        "kind" => "boundary_contract",
        "status" => "passed",
        "semantic_authority" => semantic,
        "compatibility_reference" => report["reference"],
        "provenance" => [semantic, observation, report["reference"]],
        "verification" => "verified",
        "details" => %{"safe" => true, "lifecycle" => ["create", "fetch", "cancel"]}
      }

    report
    |> Map.put("candidate_sha256", Promotion.sha256(Promotion.encode!(candidate)))
    |> Map.put("trading_venue", true)
    |> Map.put("items", items ++ [trading_item])
    |> Map.put("gaps", [])
  end

  defp complete_item(%{"id" => "check:oracle_gate"} = item, candidate, semantic, observation, reference) do
    item
    |> verified_item("passed", semantic, observation, reference)
    |> Map.put("details", %{
      "command" => ["mix", "ccxt.oracle_gate"],
      "critical_recordings" => critical_recordings(candidate)
    })
  end

  defp complete_item(%{"id" => "check:carve_registration"} = item, _candidate, semantic, observation, reference) do
    item
    |> verified_item("passed", semantic, observation, reference)
    |> Map.put("details", %{"paths" => [@carve_path], "authority_manifest" => @authority_path})
  end

  defp complete_item(%{"id" => "contract:integration_tests"} = item, _candidate, semantic, observation, reference) do
    item
    |> verified_item("passed", semantic, observation, reference)
    |> Map.put("details", %{
      "paths" => [@integration_path],
      "credential_setup" => %{
        "environment_variables" => ["BYBIT_TESTNET_API_KEY", "BYBIT_TESTNET_API_SECRET"],
        "export_commands" => [
          ~s(export BYBIT_TESTNET_API_KEY="your_key"),
          ~s(export BYBIT_TESTNET_API_SECRET="your_secret")
        ],
        "credentials_url" => "https://testnet.bybit.com"
      }
    })
  end

  defp complete_item(%{"id" => "capability:" <> method} = item, candidate, semantic, observation, reference) do
    status = if get_in(candidate, ["capabilities", "has", method]) == false, do: "unsupported", else: "authored"
    verified_item(item, status, semantic, observation, reference)
  end

  defp complete_item(%{"id" => id} = item, _candidate, semantic, observation, reference) do
    status = if String.starts_with?(id, "decision:"), do: "authored", else: "passed"

    item
    |> verified_item(status, semantic, observation, reference)
    |> add_boundary_outcome(id)
  end

  defp promotion_candidate do
    {prepared, _report} = Promotion.prepare_file!(@reference_path)
    owned = Bourse.Spec.decode_file!(@owned_path)
    methods = Map.keys(prepared["capabilities"]["has"])

    {support, unified} =
      methods
      |> Map.new(fn method ->
        declaration = get_in(owned, ["capabilities", "has", method])
        endpoints = get_in(owned, ["endpoints", "unified", method])

        if declaration in [true, "emulated"] and is_list(endpoints) and endpoints != [] do
          {method, {declaration, endpoints}}
        else
          {method, {false, []}}
        end
      end)
      |> Enum.reduce({%{}, %{}}, fn {method, {declaration, endpoints}}, {has, routes} ->
        {Map.put(has, method, declaration), Map.put(routes, method, endpoints)}
      end)

    owned
    |> Map.merge(%{"authored" => false, "frozen" => false, "hand_owned" => false})
    |> put_in(["capabilities", "has"], support)
    |> put_in(["endpoints", "unified"], unified)
  end

  defp verified_item(item, status, semantic, observation, compatibility) do
    item
    |> Map.put("status", status)
    |> Map.put("semantic_authority", semantic)
    |> Map.put("compatibility_reference", compatibility)
    |> Map.put("provenance", [semantic, observation, compatibility])
    |> Map.put("verification", "verified")
  end

  defp add_boundary_outcome(item, id) do
    cond do
      String.ends_with?(id, ":success") -> Map.put(item, "details", %{"outcome" => "success"})
      String.ends_with?(id, ":error") -> Map.put(item, "details", %{"outcome" => "error"})
      true -> item
    end
  end

  defp public_only_contract(item) do
    item
    |> Map.put("status", "not_applicable")
    |> Map.delete("details")
  end

  defp put_capability_status(report, method, status, candidate) do
    report
    |> Map.put("candidate_sha256", Promotion.sha256(Promotion.encode!(candidate)))
    |> update_item("capability:#{method}", &Map.put(&1, "status", status))
  end

  defp update_item(report, id, update) do
    Map.update!(report, "items", fn items ->
      Enum.map(items, &update_matching_item(&1, id, update))
    end)
  end

  defp update_matching_item(%{"id" => id} = item, id, update), do: update.(item)
  defp update_matching_item(item, _id, _update), do: item

  defp concurrent_promotion_venues do
    Enum.filter(~w(alpaca lighter binancecoinm), fn venue ->
      path = Bourse.Spec.owned_spec_path(venue)
      is_binary(path) and File.regular?(path)
    end)
  end

  defp critical_recordings(candidate) do
    Enum.map(critical_recording_entries(candidate), fn entry ->
      %{"slot" => entry.slot, "manifest" => entry.manifest, "path" => entry.path}
    end)
  end

  defp critical_recording_entries(candidate) do
    Enum.map(Derivation.critical_slots(candidate), fn %{path: slot, expected_methods: expected} ->
      manifest =
        cond do
          String.starts_with?(slot, "auth.sign_recipe.") or
              String.starts_with?(slot, "request_shape.") ->
            "test/fixtures/exchange_accepted_requests/_manifest.json"

          String.starts_with?(slot, "errors.handle_errors.") ->
            "test/fixtures/recorded_errors/_manifest.json"

          true ->
            "test/fixtures/responses/_manifest.json"
        end

      slug = String.replace(slot, ~r/[^A-Za-z0-9]+/, "_")

      %{
        slot: slot,
        manifest: manifest,
        path: "bybit/#{slug}.json",
        method: List.first(expected)
      }
    end)
  end

  # Zero-gap promotions resolve evidence in a fabricated root whose reality
  # manifests register each critical slot's recording under the slot's expected
  # method — the real corpus does not carry per-method rows for every slot.
  defp promotion_root!(candidate) do
    root = Path.join(System.tmp_dir!(), "promotion_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    for path <- [@reference_path, @carve_path, @authority_path, @integration_path] do
      dest = Path.join(root, path)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(path, dest)
    end

    candidate
    |> critical_recording_entries()
    |> Enum.group_by(& &1.manifest)
    |> Enum.each(fn {manifest, entries} ->
      dest = Path.join(root, manifest)
      File.mkdir_p!(Path.dirname(dest))
      rows = Enum.map(entries, &%{"venue" => "bybit", "method" => &1.method, "path" => &1.path})
      File.write!(dest, Jason.encode!(%{"recordings" => rows}))
    end)

    root
  end

  defp passing_runner do
    fn _executable, _args, _root -> {"passed", 0} end
  end
end
