defmodule Bourse.OracleProvenance.ProviderOperations do
  @moduledoc """
  Validates manifest-registered raw provider-operation captures.

  Contract inventory, execution review, reachability, and observed evidence stay
  separate. A provider example can seed a reviewed request, but only a scrubbed
  live capture registered here advances an operation's evidence axis.
  """

  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance.PathGuard
  alias Bourse.OracleProvenance.ProviderOperations.Capture
  alias Bourse.RecordedResponseFixtures
  alias Mix.Tasks.Ccxt.AuthorityCorpus
  alias Mix.Tasks.Ccxt.ContractComparator

  @default_root "test/fixtures/provider_operations"
  @default_plan "priv/authority/deribit/provider-operation-plan.json"
  @authority_root "priv/authority"
  @spec_root "priv/specs/json/output/authored"

  @typedoc "A validated provider-operation corpus."
  @type corpus :: %{inventory: map(), manifest: map(), plan: map(), recordings: %{String.t() => map()}}

  @doc "Validates the committed provider-operation corpus and returns its decoded documents."
  @spec validate!(keyword()) :: corpus()
  def validate!(opts \\ []) do
    root = Keyword.get(opts, :root, @default_root)
    manifest_path = Keyword.get(opts, :manifest_path, Path.join(root, "_manifest.json"))
    manifest = JsonDocument.decode_file!(manifest_path)
    plan_path = Keyword.get(opts, :plan_path, manifest["plan"] || @default_plan)
    plan = JsonDocument.decode_file!(plan_path)
    inventory = manifest["inventory"]

    ensure!(is_map(inventory), "#{manifest_path}: missing capture inventory snapshot")

    validate_plan!(plan, inventory,
      authority_root: Keyword.get(opts, :authority_root, @authority_root),
      spec_root: Keyword.get(opts, :spec_root, @spec_root)
    )

    validate_manifest!(manifest, plan, inventory, root, manifest_path)
  end

  @doc "Returns registered comparison facts derived only from validated live captures."
  @spec facts!(keyword()) :: [map()]
  def facts!(opts \\ []) do
    %{manifest: manifest} = validate!(opts)

    Enum.map(manifest["operations"], fn operation ->
      operation
      |> Map.take(~w(venue operation_key contract_scope runtime_scope reachability evidence))
      |> Map.put("evidence_source", "registered_live_capture")
      |> Map.put("capture_ids", operation["capture_ids"])
      |> Map.put("evidence_semantics", operation["evidence_semantics"])
    end)
  end

  @doc "Builds the provider-operation manifest rows implied by one reviewed plan."
  @spec manifest_operations(map()) :: [map()]
  def manifest_operations(plan) when is_map(plan) do
    Enum.map(plan["operations"], fn operation ->
      axes = operation["inventory_axes"]
      review = operation["execution_review"]
      semantics = operation["proofs"] |> Enum.map(& &1["evidence_semantics"]) |> Enum.uniq()

      %{
        "venue" => plan["venue"],
        "operation_key" => operation["operation_key"],
        "operation_id" => operation["operation_id"],
        "contract_scope" => axes["contract_scope"],
        "runtime_scope" => axes["runtime_scope"],
        "relation" => axes["relation"],
        "reachability" => review["reachability"],
        "evidence" => evidence_for(semantics),
        "capture_ids" => Enum.map(operation["proofs"], & &1["capture_id"]),
        "evidence_semantics" => semantics
      }
    end)
  end

  @doc "Builds the source-bound inventory snapshot persisted beside captured observations."
  @spec inventory_snapshot(map(), map()) :: map()
  def inventory_snapshot(plan, inventory) when is_map(plan) and is_map(inventory) do
    source = plan["source_revision"]
    provenance = source_provenance!(inventory, source)
    surface = inventory["surfaces"]["current_rest"]

    selected_keys =
      plan["operations"]
      |> Enum.map(& &1["operation_key"])
      |> Kernel.++(plan["source_inventory_facts"]["websocket_only_operation_keys"])
      |> MapSet.new()

    operations = Enum.filter(surface["operations"], &MapSet.member?(selected_keys, &1["operation_key"]))

    provenance =
      inventory["provenance"]
      |> Map.take(~w(authority_manifest authored_spec_canonical_sha256))
      |> Map.put("artifacts", [provenance])

    %{
      "schema_version" => inventory["schema_version"],
      "report_type" => inventory["report_type"],
      "venue" => inventory["venue"],
      "provenance" => provenance,
      "surfaces" => %{
        "current_rest" => %{
          "provider_count" => surface["provider_count"],
          "operations" => operations
        }
      }
    }
  end

  @doc "Validates a reviewed plan against one exact-revision Task 555 comparison report."
  @spec validate_plan!(map(), map(), keyword()) :: :ok
  def validate_plan!(plan, inventory, opts \\ []) when is_map(plan) and is_map(inventory) do
    ensure!(plan["schema_version"] == 1, "provider-operation plan has unsupported schema_version")
    ensure!(inventory["schema_version"] == 1, "capture inventory has unsupported schema_version")
    ensure!(inventory["report_type"] == "provider_contract_comparison", "capture inventory has wrong report_type")
    ensure!(plan["venue"] == inventory["venue"], "capture plan venue differs from inventory")
    ensure_path_component!(plan["venue"], "capture plan venue")

    source = plan["source_revision"]
    provenance = source_provenance!(inventory, source)
    ensure_source_revision!(source, provenance, "capture inventory")
    validate_source_facts!(plan, inventory, provenance)

    authority_root = Keyword.get(opts, :authority_root, @authority_root)
    validate_plan_source!(plan, authority_root)
    authored_authentication = authored_authentication!(plan, inventory, opts)

    operations = inventory["surfaces"]["current_rest"]["operations"]
    inventory_by_key = Map.new(operations, &{&1["operation_key"], &1})
    plan_operations = plan["operations"]
    ensure!(is_list(plan_operations) and plan_operations != [], "capture plan operations must be non-empty")
    ensure_unique!(plan_operations, "operation_key", "capture plan operation")

    Enum.each(plan_operations, fn operation ->
      inventory_operation =
        inventory_by_key[operation["operation_key"]] ||
          raise ArgumentError,
                "capture plan operation is absent from exact-revision inventory: #{operation["operation_key"]}"

      validate_operation_inventory!(operation, inventory_operation, authored_authentication)
      ensure_unique!(operation["proofs"], "capture_id", "capture proof")
    end)

    :ok
  end

  defp validate_plan_source!(plan, authority_root) do
    source = plan["source_revision"]
    venue = plan["venue"]
    manifest_path = Path.join([authority_root, venue, "manifest.json"])
    baseline_path = Path.join([authority_root, venue, "contract-baselines.json"])
    authority = JsonDocument.decode_file!(manifest_path)
    baseline = JsonDocument.decode_file!(baseline_path)

    artifact =
      Enum.find(authority["artifacts"], &(&1["id"] == source["artifact_id"])) ||
        raise ArgumentError, "#{manifest_path}: missing provider-operation source artifact"

    ensure_source_revision!(source, artifact, manifest_path)
    expected = baseline["surfaces"][source["contract_scope"]]
    ensure!(is_map(expected), "#{baseline_path}: missing #{source["contract_scope"]} baseline")
    ensure_source_revision!(source, expected, baseline_path)
    :ok
  end

  defp source_provenance!(inventory, source) do
    Enum.find(inventory["provenance"]["artifacts"], &(&1["id"] == source["artifact_id"])) ||
      raise ArgumentError, "capture inventory omits source artifact #{inspect(source["artifact_id"])}"
  end

  defp authored_authentication!(plan, inventory, opts) do
    spec_root = Keyword.get(opts, :spec_root, @spec_root)
    path = Path.join(spec_root, "#{plan["venue"]}.json")
    authored = JsonDocument.decode_file!(path)
    expected = get_in(inventory, ["provenance", "authored_spec_canonical_sha256"])
    actual = authored |> Jason.encode!() |> AuthorityCorpus.sha256()

    ensure!(is_binary(expected), "capture inventory omits authored-spec SHA-256")
    ensure!(expected == actual, "capture inventory authored-spec SHA-256 mismatch")
    ContractComparator.authored_rest_authentication(authored)
  end

  defp ensure_source_revision!(source, actual, label) do
    ensure!(source["sha256"] == actual["sha256"], "#{label}: provider-artifact SHA-256 mismatch")
    ensure!(source["upstream_pin"] == actual["upstream_pin"], "#{label}: provider-artifact revision mismatch")
    :ok
  end

  defp validate_source_facts!(plan, inventory, provenance) do
    facts = plan["source_inventory_facts"]
    surface = inventory["surfaces"]["current_rest"]
    operations = surface["operations"]

    websocket_only =
      for operation <- operations,
          Enum.any?(operation["provider"], &("websocket_only" in &1["qualifiers"])),
          do: operation["operation_key"]

    ensure!(facts["path_count"] == provenance["metrics"]["path_count"], "capture plan path_count differs")

    ensure!(
      facts["operation_count"] == surface["provider_count"],
      "capture plan operation_count differs"
    )

    ensure!(
      facts["unknown_authentication_count"] == provenance["metrics"]["unknown_authentication_count"],
      "capture plan authentication count differs"
    )

    ensure!(
      facts["security_metadata"] == %{
        "document_security" => "absent",
        "operation_authentication" => "unknown",
        "security_schemes" => "absent"
      },
      "capture plan must preserve absent security metadata explicitly"
    )

    ensure!(
      facts["websocket_only_operation_keys"] == Enum.sort(websocket_only),
      "capture plan WebSocket-only inventory differs"
    )
  end

  defp validate_operation_inventory!(operation, inventory_operation, authored_authentication) do
    ensure_string!(operation, "operation_id", "capture plan operation")
    ensure!(operation["inventory_axes"] == inventory_operation["axes"], "capture plan operation axes differ")

    provider = inventory_operation["provider"]
    ensure!(length(provider) == 1, "capture plan operation must resolve to one provider variant")
    [provider] = provider

    expected_provider = Map.take(provider, ~w(transport method path authentication qualifiers))
    ensure!(operation["provider"] == expected_provider, "capture plan provider facts differ")
    ensure!(is_list(operation["proofs"]) and operation["proofs"] != [], "capture plan operation has no proofs")

    authored = Map.get(authored_authentication, operation["operation_key"], [])

    ensure!(
      inventory_authentication(inventory_operation) == authored,
      "capture inventory authored authentication differs from pinned authored spec"
    )

    Enum.each(operation["proofs"], fn proof ->
      ensure_path_component!(proof["capture_id"], "capture proof capture_id")
      ensure!(proof["request_seed"]["policy"] == "seed_only", "provider examples must remain request seeds only")
      ensure!(proof["request"]["method"] == provider["method"], "capture proof HTTP method differs")
      ensure!(URI.parse(proof["request"]["url"]).path == provider["path"], "capture proof path differs")

      case Capture.authorize(operation, proof, inventory_operation, authored) do
        :ok -> :ok
        {:error, {:refused, reason}} -> raise ArgumentError, "capture proof #{proof["capture_id"]} refused: #{reason}"
      end
    end)
  end

  defp validate_manifest!(manifest, plan, inventory, root, manifest_path) do
    ensure!(manifest["schema_version"] == 1, "#{manifest_path}: unsupported schema_version")
    ensure!(manifest["corpus"] == "provider_operation_reality", "#{manifest_path}: wrong corpus")
    ensure!(manifest["source_revision"] == plan["source_revision"], "#{manifest_path}: source revision differs")
    ensure!(is_list(manifest["recordings"]), "#{manifest_path}: recordings must be a list")
    ensure!(is_list(manifest["operations"]), "#{manifest_path}: operations must be a list")
    ensure_unique!(manifest["recordings"], "capture_id", "registered capture")
    ensure_unique!(manifest["operations"], "operation_key", "registered operation")

    proofs = plan_proofs(plan)
    proof_ids = MapSet.new(proofs, & &1.proof["capture_id"])
    recording_ids = MapSet.new(manifest["recordings"], & &1["capture_id"])
    ensure!(proof_ids == recording_ids, "#{manifest_path}: registered capture set differs from reviewed plan")

    recordings =
      Map.new(manifest["recordings"], fn row ->
        proof = Enum.find(proofs, &(&1.proof["capture_id"] == row["capture_id"]))
        fixture = validate_recording!(row, proof, plan, root)
        {row["capture_id"], fixture}
      end)

    validate_manifest_operations!(manifest["operations"], plan)
    %{inventory: inventory, manifest: manifest, plan: plan, recordings: recordings}
  end

  defp validate_recording!(row, %{operation: operation, proof: proof}, plan, root) do
    path = PathGuard.resolve_inside_root!(root, row["path"], "registered provider-operation capture")
    ensure!(File.regular?(path), "registered provider-operation capture is missing: #{path}")
    contents = File.read!(path)
    ensure!(byte_size(contents) == row["bytes"], "#{path}: byte count differs from manifest")
    ensure!(AuthorityCorpus.sha256(contents) == row["sha256"], "#{path}: SHA-256 differs from manifest")
    fixture = Jason.decode!(contents)

    ensure!(fixture["schema_version"] == 1, "#{path}: unsupported schema_version")
    ensure!(fixture["venue"] == plan["venue"], "#{path}: venue differs")
    ensure!(fixture["capture_id"] == proof["capture_id"], "#{path}: capture_id differs")
    ensure!(fixture["operation_key"] == operation["operation_key"], "#{path}: operation_key differs")
    ensure!(fixture["operation_id"] == operation["operation_id"], "#{path}: operation_id differs")
    ensure!(fixture["provider_artifact"] == plan["source_revision"], "#{path}: provider revision differs")
    ensure!(fixture["request"] == proof["request"], "#{path}: raw request differs from review")
    ensure!(fixture["evidence_semantics"] == proof["evidence_semantics"], "#{path}: evidence semantics differ")
    ensure!(fixture["host"] == URI.parse(fixture["request"]["url"]).host, "#{path}: request host differs")
    ensure!(is_binary(fixture["captured_at"]), "#{path}: missing capture time")
    ensure!(fixture["scrubbed"] == true, "#{path}: capture is not marked scrubbed")
    ensure!(RecordedResponseFixtures.safety_violations(fixture) == [], "#{path}: capture contains sensitive fields")
    validate_observation!(fixture, proof, path)
    ensure!(row["http_status"] == fixture["response"]["http_status"], "#{path}: manifest status differs")
    ensure!(row["captured_at"] == fixture["captured_at"], "#{path}: manifest capture time differs")
    ensure!(row["host"] == fixture["host"], "#{path}: manifest host differs")
    fixture
  end

  defp validate_observation!(fixture, proof, path) do
    response = fixture["response"]
    expected = proof["expected"]
    ensure!(response["http_status"] == expected["http_status"], "#{path}: HTTP status differs from review")
    ensure!(is_binary(response["raw_body"]), "#{path}: raw response body is missing")
    decoded = Jason.decode!(response["raw_body"])

    case expected["outcome"] do
      "success" ->
        ensure!(!Map.has_key?(decoded, "error"), "#{path}: reviewed success contains an error")

      "invalid_parameter_error" ->
        ensure!(get_in(decoded, ["error", "code"]) == expected["error_code"], "#{path}: error code differs")

      outcome ->
        raise ArgumentError, "#{path}: unsupported reviewed outcome #{inspect(outcome)}"
    end

    row_fields_populated = is_map(decoded["result"]) and map_size(decoded["result"]) > 0
    ensure!(fixture["row_fields_populated"] == row_fields_populated, "#{path}: row population marker differs")

    if proof["evidence_semantics"] == "row_fields" do
      ensure!(row_fields_populated, "#{path}: row-field evidence requires populated domain data")
    end
  end

  defp validate_manifest_operations!(registered, plan) do
    expected = manifest_operations(plan)

    ensure!(registered == expected, "provider-operation manifest facts differ from reviewed plan")
  end

  defp evidence_for(semantics) do
    if "row_fields" in semantics, do: "verified", else: "unverified"
  end

  defp plan_proofs(plan) do
    for operation <- plan["operations"], proof <- operation["proofs"] do
      %{operation: operation, proof: proof}
    end
  end

  defp inventory_authentication(operation) do
    Enum.map(operation["authored"], &Map.take(&1, ["authentication"]))
  end

  defp ensure_unique!(values, key, label) when is_list(values) do
    identities = Enum.map(values, & &1[key])
    ensure!(Enum.all?(identities, &(is_binary(&1) and &1 != "")), "#{label} #{key} must be non-empty")
    ensure!(length(identities) == length(Enum.uniq(identities)), "duplicate #{label} #{key}")
  end

  defp ensure_unique!(_values, key, label), do: raise(ArgumentError, "#{label} #{key} collection must be a list")

  defp ensure_string!(map, key, label) do
    ensure!(is_binary(map[key]) and map[key] != "", "#{label} #{key} must be non-empty")
  end

  defp ensure_path_component!(value, label) do
    ensure!(
      is_binary(value) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, value),
      "#{label} must be a safe path component"
    )
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)
end
