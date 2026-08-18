defmodule Bourse.OracleProvenance.MutationAdjudication do
  @moduledoc """
  Adjudicates Deribit current-REST mutating operations and validates their reality.

  Three artifacts, three jobs. The register
  (`priv/authority/deribit/mutation-adjudication.json`) carries one reviewed
  reachability and safety judgment per operation with a rationale drawn from the
  provider's own description; nothing here derives that judgment from an HTTP
  verb, a method name or a name pattern. The lifecycle plan
  (`priv/authority/deribit/mutation-lifecycle-plan.json`) authorizes the small
  set of reversible mutations that may actually be sent, each with setup,
  cleanup and a final-state observation. The captured corpus holds what the
  venue answered.

  Relation, runtime scope, evidence, reachability, safety and contract scope stay
  six independent facts. A refused operation keeps its place in the 182-operation
  denominator as `evidence: "unverified"` with a ledger entry — refused never
  means absent, unsupported or deleted.
  """

  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance.MutationAdjudication.Redaction
  alias Bourse.OracleProvenance.PathGuard
  alias Bourse.RecordedResponseFixtures
  alias Mix.Tasks.Ccxt.AuthorityCorpus
  alias Mix.Tasks.Ccxt.ContractComparator

  @default_root "test/fixtures/provider_operations/deribit_mutations"
  @default_register "priv/authority/deribit/mutation-adjudication.json"
  @default_plan "priv/authority/deribit/mutation-lifecycle-plan.json"
  @default_ledger "docs/prod-verification-ledger.md"
  @default_errors "priv/authority/deribit/errors.json"
  @default_spec_root "priv/specs/json/output/authored"

  @decisions ~w(approved refused)
  @reachability_values ~w(safe unsafe unreachable)
  @safety_values ~w(safe unsafe not_applicable)
  @durability_values ~w(reversible_order_state session persistent)
  @value_movements ~w(none internal external)
  @effects ~w(mutate session)
  @exposures ~w(public private)
  @roles ~w(setup act observe cleanup final_state idempotent_final_state failure_probe)
  @mutating_roles ~w(act cleanup idempotent_final_state failure_probe)
  @outcomes ~w(success documented_error)

  @typedoc "A validated mutation-adjudication corpus."
  @type corpus :: %{register: map(), plan: map(), manifest: map(), recordings: %{String.t() => map()}}

  @doc "Returns the default paths this corpus is built from."
  @spec defaults() :: keyword()
  def defaults do
    [
      root: @default_root,
      register_path: @default_register,
      plan_path: @default_plan,
      ledger_path: @default_ledger,
      errors_path: @default_errors,
      spec_root: @default_spec_root
    ]
  end

  @doc """
  Validates the reviewed register and lifecycle plan without requiring captures.

  The capture boundary calls this before it sends anything, so a plan that names
  an unadjudicated, unsafe or unreachable operation is refused before any request
  leaves the machine.
  """
  @spec load_reviewed!(keyword()) :: %{register: map(), plan: map()}
  def load_reviewed!(opts \\ []) do
    opts = Keyword.merge(defaults(), opts)
    register = validate_register!(opts)
    %{register: register, plan: validate_plan!(register, opts)}
  end

  @doc "Validates the committed mutation-adjudication corpus and returns its decoded documents."
  @spec validate!(keyword()) :: corpus()
  def validate!(opts \\ []) do
    opts = Keyword.merge(defaults(), opts)
    %{register: register, plan: plan} = load_reviewed!(opts)
    root = opts[:root]
    manifest_path = Keyword.get(opts, :manifest_path, Path.join(root, "_manifest.json"))

    manifest = JsonDocument.decode_file!(manifest_path)
    recordings = validate_manifest!(manifest, register, plan, root, manifest_path, opts)
    %{register: register, plan: plan, manifest: manifest, recordings: recordings}
  end

  @doc """
  Decides whether one reviewed lifecycle step may be executed.

  Every refusal names why. A non-mutating step must resolve to an operation the
  register partitions into the read surface; a mutating step must resolve to an
  explicitly approved register entry inside an approved lifecycle.
  """
  @spec authorize(map(), map(), map()) :: :ok | {:error, {:refused, atom()}}
  def authorize(register, lifecycle, step) when is_map(register) and is_map(lifecycle) and is_map(step) do
    role = step["role"]
    operation_id = step["operation_id"]

    cond do
      role not in @roles -> refused(:unclassified_role)
      role in @mutating_roles -> authorize_mutation(register, lifecycle, operation_id)
      true -> authorize_support(register, operation_id)
    end
  end

  @doc "Returns registered comparison facts derived only from validated captures."
  @spec facts!(keyword()) :: [map()]
  def facts!(opts \\ []) do
    %{manifest: manifest} = validate!(opts)

    Enum.map(manifest["operations"], fn operation ->
      operation
      |> Map.take(~w(venue operation_key contract_scope relation runtime_scope reachability safety evidence))
      |> Map.put("evidence_source", "registered_mutation_lifecycle_capture")
      |> Map.put("capture_ids", operation["capture_ids"])
    end)
  end

  @doc """
  Builds the manifest operation rows implied by one register and one capture set.

  `captures` maps an `operation_id` to the capture ids that observed it. Only a
  populated `row_fields` observation advances evidence; a refused operation can
  never carry a capture, so it can never be labelled verified.
  """
  @spec manifest_operations(map(), %{String.t() => [String.t()]}, map()) :: [map()]
  def manifest_operations(register, captures, authored) when is_map(register) and is_map(captures) do
    authored_index = authored_index(authored)

    Enum.map(register["operations"], fn operation ->
      review = operation["execution_review"]
      operation_key = operation["operation_key"]
      capture_ids = Map.get(captures, operation["operation_id"], [])
      authored_entry = Map.get(authored_index, operation_key)

      %{
        "venue" => register["venue"],
        "operation_key" => operation_key,
        "operation_id" => operation["operation_id"],
        "contract_scope" => register["contract_scope"],
        "relation" => if(authored_entry, do: "shared", else: "provider_only"),
        "runtime_scope" => (authored_entry && authored_entry["runtime_scope"]) || "not_implemented",
        "decision" => review["decision"],
        "reachability" => review["reachability"],
        "safety" => review["safety"],
        "evidence" => if(capture_ids == [], do: "unverified", else: "verified"),
        "capture_ids" => capture_ids,
        "ledger_ref" => review["ledger_ref"]
      }
    end)
  end

  @doc "Returns whether a decoded JSON-RPC body carries populated domain rows."
  @spec row_fields_populated?(term()) :: boolean()
  def row_fields_populated?(%{"result" => result}) when is_map(result), do: map_size(result) > 0
  def row_fields_populated?(%{"result" => result}) when is_list(result), do: result != []
  def row_fields_populated?(%{"result" => result}) when is_binary(result), do: result != ""
  def row_fields_populated?(%{"result" => result}) when is_number(result) or is_boolean(result), do: true
  def row_fields_populated?(_body), do: false

  @doc "Checks one observation against its reviewed expectation, returning every mismatch."
  @spec observation_errors(map(), map(), map()) :: [String.t()]
  def observation_errors(expected, body, documented_codes) when is_map(expected) and is_map(body) do
    case expected["outcome"] do
      "success" ->
        if Map.has_key?(body, "error") do
          ["reviewed success carries a provider error: #{inspect(body["error"])}"]
        else
          assertion_errors(expected["assertions"] || [], body)
        end

      "documented_error" ->
        documented_error_errors(expected, body, documented_codes)
    end
  end

  # -- register ---------------------------------------------------------------

  defp validate_register!(opts) do
    path = opts[:register_path]
    register = JsonDocument.decode_file!(path)
    ensure!(register["schema_version"] == 1, "#{path}: unsupported schema_version")
    ensure!(register["report_type"] == "provider_mutation_adjudication", "#{path}: wrong report_type")
    ensure!(register["contract_scope"] == "current_rest", "#{path}: unsupported contract scope")
    ensure!(is_binary(register["venue"]) and register["venue"] != "", "#{path}: missing venue")

    validate_source_binding!(register, path)
    validate_denominator!(register, path)
    ledger = File.read!(opts[:ledger_path])

    Enum.each(register["operations"], &validate_review!(&1, register, ledger, path, opts[:ledger_path]))
    register
  end

  defp validate_source_binding!(register, path) do
    binding = register["source_binding"]
    ensure!(is_map(binding), "#{path}: missing source binding")
    ensure!(is_binary(binding["pinned_revision_sha256"]), "#{path}: missing pinned revision")
    enumerated = binding["denominator_enumerated_from"]
    ensure!(is_map(enumerated), "#{path}: missing denominator source revision")

    drift_path = binding["drift_record"]
    ensure!(is_binary(drift_path) and File.regular?(drift_path), "#{path}: drift record is missing")
    current = current_revision(JsonDocument.decode_file!(drift_path), path, drift_path)

    ensure!(
      current["sha256"] == enumerated["sha256"],
      "#{path}: denominator revision differs from #{drift_path}"
    )

    ensure!(
      current["operation_key_set_sha256"] == enumerated["operation_key_set_sha256"],
      "#{path}: denominator operation-key set differs from #{drift_path}"
    )

    ensure!(
      current["sha256"] == binding["pinned_revision_sha256"],
      "#{path}: pinned revision differs from #{drift_path}"
    )
  end

  defp validate_denominator!(register, path) do
    denominator = register["denominator"]
    ensure!(is_map(denominator), "#{path}: missing denominator")

    partitions =
      ~w(task_556_operation_keys task_557_operation_keys adjudicated_operation_keys websocket_only_operation_keys)

    lists =
      Enum.map(partitions, fn part ->
        value = denominator[part]
        ensure!(is_list(value) and value != [], "#{path}: #{part} must be a non-empty list")
        ensure!(value == Enum.sort(value), "#{path}: #{part} must be sorted")
        ensure!(length(Enum.uniq(value)) == length(value), "#{path}: #{part} has duplicates")
        MapSet.new(value)
      end)

    union = Enum.reduce(lists, MapSet.new(), &MapSet.union/2)
    total = Enum.sum_by(lists, &MapSet.size/1)
    ensure!(MapSet.size(union) == total, "#{path}: denominator partitions overlap")

    ensure!(
      total == denominator["provider_count"],
      "#{path}: denominator partitions cover #{total} of #{denominator["provider_count"]} provider operations"
    )

    adjudicated = MapSet.union(Enum.at(lists, 2), Enum.at(lists, 3))
    reviewed = MapSet.new(register["operations"], & &1["operation_key"])

    ensure!(
      MapSet.equal?(reviewed, adjudicated),
      "#{path}: reviewed operations differ from the adjudicated denominator"
    )
  end

  defp validate_review!(operation, register, ledger, path, ledger_path) do
    key = operation["operation_key"]
    review = operation["execution_review"]
    ensure!(is_map(review), "#{path}: #{key} has no execution review")
    ensure!(review["classification"] == "reviewed", "#{path}: #{key} is not explicitly reviewed")
    ensure_member!(review, "decision", @decisions, key, path)
    ensure_member!(review, "exposure", @exposures, key, path)
    ensure_member!(review, "effect", @effects, key, path)
    ensure_member!(review, "durability", @durability_values, key, path)
    ensure_member!(review, "value_movement", @value_movements, key, path)
    ensure_member!(review, "reachability", @reachability_values, key, path)
    ensure_member!(review, "safety", @safety_values, key, path)

    ensure!(
      is_binary(review["rationale"]) and String.length(review["rationale"]) >= 40,
      "#{path}: #{key} needs a substantive reviewed rationale"
    )

    ensure!(
      review["reachability"] == "unreachable" == (review["safety"] == "not_applicable"),
      "#{path}: #{key} pairs reachability #{review["reachability"]} with safety #{review["safety"]}"
    )

    validate_decision!(review, operation, register, key, path)
    validate_ledger_reference!(review, ledger, key, path, ledger_path)
  end

  defp validate_decision!(%{"decision" => "approved"} = review, operation, register, key, path) do
    ensure!(review["reachability"] == "safe", "#{path}: #{key} is approved but not reachable-safe")
    ensure!(review["safety"] == "safe", "#{path}: #{key} is approved but not safety-safe")
    ensure!(review["value_movement"] == "none", "#{path}: #{key} is approved but moves value")
    ensure!(review["durability"] != "persistent", "#{path}: #{key} is approved but persists beyond the session")
    ensure!(is_nil(review["ledger_ref"]), "#{path}: #{key} is approved and needs no ledger entry")
    validate_reversal!(review, operation, register, key, path)
  end

  defp validate_decision!(%{"decision" => "refused"} = review, _operation, _register, key, path) do
    ensure!(
      review["safety"] != "safe" or review["reachability"] != "safe",
      "#{path}: #{key} is refused but records no unsafe or unreachable fact"
    )

    ensure!(is_binary(review["ledger_ref"]), "#{path}: #{key} is refused without a ledger reference")
  end

  defp validate_reversal!(review, operation, register, key, path) do
    case review["reversal_operation_id"] do
      nil ->
        ensure!(
          review["durability"] == "reversible_order_state",
          "#{path}: #{key} is approved with no reversal and is not itself a reversal"
        )

      reversal when is_binary(reversal) ->
        ensure!(reversal != operation["operation_id"], "#{path}: #{key} names itself as its reversal")

        ensure!(
          Enum.any?(register["operations"], &(&1["operation_id"] == reversal)),
          "#{path}: #{key} names an unadjudicated reversal #{reversal}"
        )

      other ->
        raise ArgumentError, "#{path}: #{key} has a non-string reversal #{inspect(other)}"
    end
  end

  defp validate_ledger_reference!(review, ledger, key, path, ledger_path) do
    case review["ledger_ref"] do
      nil ->
        :ok

      reference ->
        ensure!(
          is_binary(reference) and String.contains?(ledger, reference),
          "#{path}: #{key} names ledger entry #{inspect(reference)} which is absent from #{ledger_path}"
        )
    end
  end

  # -- lifecycle plan ---------------------------------------------------------

  defp validate_plan!(register, opts) do
    path = opts[:plan_path]
    plan = JsonDocument.decode_file!(path)
    ensure!(plan["schema_version"] == 1, "#{path}: unsupported schema_version")
    ensure!(plan["report_type"] == "provider_mutation_lifecycle_plan", "#{path}: wrong report_type")
    ensure!(plan["venue"] == register["venue"], "#{path}: venue differs from the register")
    ensure!(plan["environment"] == "testnet", "#{path}: only testnet lifecycles may be planned")
    ensure!(plan["adjudication"] == opts[:register_path], "#{path}: plan is bound to another register")
    ensure!(URI.parse(plan["base_url"]).host == plan["host"], "#{path}: base URL host differs from the plan host")

    lifecycles = plan["lifecycles"]
    ensure!(is_list(lifecycles) and lifecycles != [], "#{path}: plan has no lifecycles")
    ensure_unique!(lifecycles, "lifecycle_id", "planned lifecycle", path)
    documented = documented_codes(opts[:errors_path])
    Enum.each(lifecycles, &validate_lifecycle!(&1, register, documented, path))
    plan
  end

  defp validate_lifecycle!(lifecycle, register, documented, path) do
    id = lifecycle["lifecycle_id"]
    review = lifecycle["review"]
    ensure!(is_map(review), "#{path}: lifecycle #{id} has no review")
    ensure!(review["classification"] == "reviewed", "#{path}: lifecycle #{id} is not explicitly reviewed")
    ensure!(review["decision"] == "approved", "#{path}: lifecycle #{id} is not approved")
    ensure!(review["cleanup_failure_handling"] == "raise", "#{path}: lifecycle #{id} must fail loudly on cleanup")

    steps = lifecycle["steps"]
    ensure!(is_list(steps) and steps != [], "#{path}: lifecycle #{id} has no steps")
    ensure_unique!(steps, "step_id", "planned step", path)

    roles = Enum.map(steps, & &1["role"])
    Enum.each(~w(setup act cleanup final_state), &ensure!(&1 in roles, "#{path}: lifecycle #{id} has no #{&1} step"))

    cleanup = Enum.find(steps, &(&1["role"] == "cleanup"))

    ensure!(
      cleanup["operation_id"] == review["cleanup_operation_id"],
      "#{path}: lifecycle #{id} cleanup step does not run the reviewed cleanup operation"
    )

    ensure!(
      Enum.find_index(roles, &(&1 == "act")) < Enum.find_index(roles, &(&1 == "cleanup")),
      "#{path}: lifecycle #{id} cleans up before it acts"
    )

    Enum.each(steps, &validate_step!(&1, lifecycle, register, documented, path))
    validate_mutating_step_order!(steps, lifecycle, register, path)
  end

  defp validate_mutating_step_order!(steps, lifecycle, register, path) do
    cleanup_index = Enum.find_index(steps, &(&1["role"] == "cleanup"))

    steps
    |> Enum.with_index()
    |> Enum.each(fn {step, index} ->
      if step["role"] in @mutating_roles and index > cleanup_index do
        validate_own_compensator!(step, lifecycle, register, path)
      end
    end)
  end

  defp validate_own_compensator!(step, lifecycle, register, path) do
    id = "#{lifecycle["lifecycle_id"]}/#{step["step_id"]}"
    compensator = step["compensator"]

    ensure!(
      is_map(compensator),
      "#{path}: mutating step #{id} runs after cleanup without its own compensator"
    )

    ensure!(is_binary(compensator["operation_id"]), "#{path}: step #{id} compensator names no operation")
    ensure!(compensator["authenticated"] == true, "#{path}: step #{id} compensator is not authenticated")
    ensure!(is_map(compensator["params"]), "#{path}: step #{id} compensator has no reviewed params")

    compensation_step =
      compensator
      |> Map.put("step_id", "#{step["step_id"]}_compensator")
      |> Map.put("role", "cleanup")

    case authorize(register, lifecycle, compensation_step) do
      :ok -> :ok
      {:error, {:refused, reason}} -> raise ArgumentError, "#{path}: step #{id} compensator refused: #{reason}"
    end
  end

  defp validate_step!(step, lifecycle, register, documented, path) do
    id = "#{lifecycle["lifecycle_id"]}/#{step["step_id"]}"

    ensure!(
      Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, step["step_id"]),
      "#{path}: step #{id} names a capture that is not a safe path component"
    )

    ensure!(step["role"] in @roles, "#{path}: step #{id} has an unclassified role")
    ensure!(is_binary(step["operation_id"]), "#{path}: step #{id} names no operation")
    ensure!(is_map(step["params"]), "#{path}: step #{id} has no reviewed params")
    expected = step["expected"]
    ensure!(is_map(expected) and expected["outcome"] in @outcomes, "#{path}: step #{id} has no reviewed outcome")

    case authorize(register, lifecycle, step) do
      :ok -> :ok
      {:error, {:refused, reason}} -> raise ArgumentError, "#{path}: step #{id} refused: #{reason}"
    end

    if expected["outcome"] == "documented_error" do
      code = expected["error_code"]

      ensure!(
        Map.has_key?(documented, to_string(code)),
        "#{path}: step #{id} expects error #{inspect(code)} which is absent from the provider error authority"
      )

      ensure!(
        step["durable_state_effect"] == "none",
        "#{path}: step #{id} probes a failure without declaring that it creates no durable state"
      )
    end
  end

  # -- authorization ----------------------------------------------------------

  defp authorize_mutation(register, lifecycle, operation_id) do
    review = lifecycle["review"] || %{}

    with :ok <- require_reviewed_lifecycle(review),
         {:ok, operation} <- fetch_operation(register, operation_id),
         :ok <- require_mutating(operation),
         :ok <- require_approved(operation),
         :ok <- require_reachable(operation),
         :ok <- require_safe(operation) do
      require_reversible(operation)
    end
  end

  defp authorize_support(register, operation_id) do
    denominator = register["denominator"] || %{}
    key = "GET /api/v2/#{operation_id}"

    reads =
      MapSet.union(
        MapSet.new(denominator["task_556_operation_keys"] || []),
        MapSet.new(denominator["task_557_operation_keys"] || [])
      )

    cond do
      Enum.any?(register["operations"] || [], &(&1["operation_id"] == operation_id)) -> refused(:mutating)
      MapSet.member?(reads, key) -> :ok
      true -> refused(:unadjudicated)
    end
  end

  defp require_reviewed_lifecycle(%{"classification" => "reviewed", "decision" => "approved"}), do: :ok
  defp require_reviewed_lifecycle(_review), do: refused(:no_reviewed_lifecycle)

  defp fetch_operation(register, operation_id) do
    case Enum.find(register["operations"] || [], &(&1["operation_id"] == operation_id)) do
      nil -> refused(:unadjudicated)
      operation -> {:ok, operation}
    end
  end

  defp require_mutating(%{"execution_review" => %{"effect" => "mutate"}}), do: :ok
  defp require_mutating(_operation), do: refused(:not_a_mutation)

  defp require_approved(%{"execution_review" => %{"classification" => "reviewed", "decision" => "approved"}}), do: :ok
  defp require_approved(%{"execution_review" => %{"classification" => "reviewed"}}), do: refused(:refused_by_review)
  defp require_approved(_operation), do: refused(:unclassified)

  defp require_reachable(%{"execution_review" => %{"reachability" => "safe"}}), do: :ok
  defp require_reachable(%{"execution_review" => %{"reachability" => "unreachable"}}), do: refused(:unreachable)
  defp require_reachable(_operation), do: refused(:unsafe)

  defp require_safe(%{"execution_review" => %{"safety" => "safe"}}), do: :ok
  defp require_safe(_operation), do: refused(:unsafe)

  defp require_reversible(%{"execution_review" => review}) do
    cond do
      review["value_movement"] != "none" -> refused(:value_moving)
      review["durability"] == "persistent" -> refused(:persistent_state)
      true -> :ok
    end
  end

  # -- captured corpus --------------------------------------------------------

  defp validate_manifest!(manifest, register, plan, root, manifest_path, opts) do
    ensure!(manifest["schema_version"] == 1, "#{manifest_path}: unsupported schema_version")
    ensure!(manifest["corpus"] == "provider_mutation_reality", "#{manifest_path}: wrong corpus")
    ensure!(manifest["venue"] == register["venue"], "#{manifest_path}: venue differs from the register")
    ensure!(manifest["source_binding"] == register["source_binding"], "#{manifest_path}: source binding differs")
    ensure!(manifest["adjudication"] == opts[:register_path], "#{manifest_path}: bound to another register")
    ensure!(manifest["plan"] == opts[:plan_path], "#{manifest_path}: bound to another lifecycle plan")
    ensure!(is_list(manifest["recordings"]), "#{manifest_path}: recordings must be a list")
    ensure_unique!(manifest["recordings"], "capture_id", "registered capture", manifest_path)

    steps = plan_steps(plan)
    expected_ids = MapSet.new(steps, & &1.capture_id)
    actual_ids = MapSet.new(manifest["recordings"], & &1["capture_id"])
    ensure!(MapSet.equal?(expected_ids, actual_ids), "#{manifest_path}: captures differ from the reviewed plan")

    documented = documented_codes(opts[:errors_path])

    recordings =
      Map.new(manifest["recordings"], fn row ->
        step = Enum.find(steps, &(&1.capture_id == row["capture_id"]))
        {row["capture_id"], validate_recording!(row, step, register, plan, root, documented)}
      end)

    validate_lifecycle_outcomes!(manifest, plan, recordings, manifest_path)
    validate_operations!(manifest, register, steps, recordings, manifest_path, opts)
    recordings
  end

  defp validate_recording!(row, %{lifecycle: lifecycle, step: step}, register, plan, root, documented) do
    path = PathGuard.resolve_inside_root!(root, row["path"], "registered mutation capture")
    ensure!(File.regular?(path), "registered mutation capture is missing: #{path}")
    contents = File.read!(path)
    ensure!(byte_size(contents) == row["bytes"], "#{path}: byte count differs from manifest")
    ensure!(AuthorityCorpus.sha256(contents) == row["sha256"], "#{path}: SHA-256 differs from manifest")
    fixture = Jason.decode!(contents)

    ensure!(fixture["schema_version"] == 1, "#{path}: unsupported schema_version")
    ensure!(fixture["venue"] == register["venue"], "#{path}: venue differs")
    ensure!(fixture["source_binding"] == register["source_binding"], "#{path}: source binding differs")
    ensure!(fixture["lifecycle_id"] == lifecycle["lifecycle_id"], "#{path}: lifecycle differs")
    ensure!(fixture["step_id"] == step["step_id"], "#{path}: step differs")
    ensure!(fixture["role"] == step["role"], "#{path}: role differs from the reviewed plan")
    ensure!(fixture["operation_id"] == step["operation_id"], "#{path}: operation differs from the reviewed plan")
    ensure!(fixture["operation_key"] == "GET /api/v2/#{step["operation_id"]}", "#{path}: operation key differs")
    ensure!(fixture["host"] == plan["host"], "#{path}: capture left the reviewed host")
    ensure!(URI.parse(fixture["request"]["url"]).host == plan["host"], "#{path}: request left the reviewed host")
    ensure!(is_binary(fixture["captured_at"]), "#{path}: missing capture time")
    ensure!(fixture["scrubbed"] == true, "#{path}: capture is not marked scrubbed")

    case Redaction.violations(fixture) do
      [] -> :ok
      violations -> raise ArgumentError, "#{path}: capture carries credential material at #{Enum.join(violations, ", ")}"
    end

    ensure!(RecordedResponseFixtures.safety_violations(fixture) == [], "#{path}: capture contains sensitive fields")

    body = Jason.decode!(fixture["response"]["raw_body"])
    ensure!(is_list(fixture["response"]["redacted_body_paths"]), "#{path}: capture records no body redaction")
    ensure!(RecordedResponseFixtures.safety_violations(body) == [], "#{path}: response body exposes sensitive fields")
    ensure!(fixture["response"]["http_status"] == step["expected"]["http_status"], "#{path}: HTTP status differs")

    case observation_errors(step["expected"], body, documented) do
      [] -> :ok
      errors -> raise ArgumentError, "#{path}: #{Enum.join(errors, "; ")}"
    end

    populated = row_fields_populated?(body)
    ensure!(fixture["row_fields_populated"] == populated, "#{path}: row population marker differs")

    if step["evidence_semantics"] == "row_fields" do
      ensure!(populated, "#{path}: row-field evidence requires populated domain data")
    end

    ensure!(row["http_status"] == fixture["response"]["http_status"], "#{path}: manifest status differs")
    ensure!(row["captured_at"] == fixture["captured_at"], "#{path}: manifest capture time differs")
    ensure!(row["role"] == step["role"], "#{path}: manifest role differs")
    fixture
  end

  defp validate_lifecycle_outcomes!(manifest, plan, recordings, manifest_path) do
    ensure!(is_list(manifest["lifecycles"]), "#{manifest_path}: lifecycles must be a list")

    ensure!(
      Enum.map(manifest["lifecycles"], & &1["lifecycle_id"]) == Enum.map(plan["lifecycles"], & &1["lifecycle_id"]),
      "#{manifest_path}: recorded lifecycles differ from the reviewed plan"
    )

    Enum.each(manifest["lifecycles"], fn recorded ->
      id = recorded["lifecycle_id"]
      planned = Enum.find(plan["lifecycles"], &(&1["lifecycle_id"] == id))

      ensure!(
        recorded["cleanup_outcome"] == "completed",
        "#{manifest_path}: lifecycle #{id} did not complete its reviewed cleanup"
      )

      cleanup = Enum.find(planned["steps"], &(&1["role"] == "cleanup"))
      fixture = Map.fetch!(recordings, cleanup["step_id"])
      body = Jason.decode!(fixture["response"]["raw_body"])

      ensure!(
        recorded["final_state"] == get_in(body, ["result", "order_state"]),
        "#{manifest_path}: lifecycle #{id} records a final state the cleanup response does not show"
      )
    end)
  end

  defp validate_operations!(manifest, register, steps, recordings, manifest_path, opts) do
    captures =
      steps
      |> Enum.filter(fn %{capture_id: id, step: step} ->
        step["evidence_semantics"] == "row_fields" and Map.fetch!(recordings, id)["row_fields_populated"]
      end)
      |> Enum.group_by(& &1.step["operation_id"], & &1.capture_id)

    authored = JsonDocument.decode_file!(Path.join(opts[:spec_root], "#{register["venue"]}.json"))
    expected = manifest_operations(register, captures, authored)

    ensure!(manifest["operations"] == expected, "#{manifest_path}: operation facts differ from the register and captures")

    Enum.each(manifest["operations"], fn operation ->
      if operation["decision"] == "refused" do
        ensure!(
          operation["evidence"] == "unverified" and operation["capture_ids"] == [],
          "#{manifest_path}: refused operation #{operation["operation_key"]} claims evidence"
        )
      end
    end)
  end

  # -- shared helpers ---------------------------------------------------------

  @doc "Validates materialized provider operation keys against the reviewed source binding."
  @spec validate_source_inventory!(String.t(), [String.t()], keyword()) :: :ok
  def validate_source_inventory!(revision_sha256, operation_keys, opts \\ [])
      when is_binary(revision_sha256) and is_list(operation_keys) do
    %{register: register} = load_reviewed!(opts)
    binding = register["source_binding"]
    source = binding["denominator_enumerated_from"]
    expected_count = register["denominator"]["provider_count"]
    serialized_keys = operation_keys |> Enum.sort() |> Enum.join("\n") |> Kernel.<>("\n")
    operation_key_set_sha256 = AuthorityCorpus.sha256(serialized_keys)

    ensure!(revision_sha256 == binding["pinned_revision_sha256"], "materialized mutation revision differs from pin")
    ensure!(revision_sha256 == source["sha256"], "materialized mutation revision differs from denominator")
    ensure!(length(operation_keys) == expected_count, "materialized mutation denominator count differs")

    ensure!(
      operation_key_set_sha256 == source["operation_key_set_sha256"],
      "materialized mutation operation-key set differs from reviewed denominator"
    )

    :ok
  end

  defp current_revision(drift, path, drift_path) do
    current = drift["current"] || drift["observed"]
    ensure!(is_map(current), "#{path}: #{drift_path} has no current revision")
    current
  end

  @doc "Flattens a lifecycle plan into one entry per reviewed step, keyed by its capture id."
  @spec plan_steps(map()) :: [%{capture_id: String.t(), lifecycle: map(), step: map()}]
  def plan_steps(plan) do
    for lifecycle <- plan["lifecycles"], step <- lifecycle["steps"] do
      %{capture_id: step["step_id"], lifecycle: lifecycle, step: step}
    end
  end

  @doc "Loads the venue's documented error codes, which are the only codes a reviewed probe may expect."
  @spec documented_codes(Path.t()) :: map()
  def documented_codes(errors_path) do
    errors_path |> JsonDocument.decode_file!() |> Map.fetch!("codes")
  end

  defp authored_index(authored) do
    authored
    |> ContractComparator.authored_rest_operations()
    |> Map.new(&{&1["key"], &1})
  end

  defp assertion_errors(assertions, body) do
    Enum.flat_map(assertions, fn assertion ->
      actual = get_in(body, assertion["path"])

      if actual == assertion["equals"] do
        []
      else
        ["#{Enum.join(assertion["path"], ".")} is #{inspect(actual)}, reviewed as #{inspect(assertion["equals"])}"]
      end
    end)
  end

  defp documented_error_errors(expected, body, documented_codes) do
    error = body["error"] || %{}
    code = error["code"]

    code_errors =
      cond do
        is_nil(code) ->
          ["reviewed provider error is absent from the response"]

        code != expected["error_code"] ->
          ["provider error code is #{inspect(code)}, reviewed as #{expected["error_code"]}"]

        not Map.has_key?(documented_codes, to_string(code)) ->
          ["provider error #{code} is not documented by the venue"]

        true ->
          []
      end

    message_errors =
      if error["message"] == expected["error_message"],
        do: [],
        else: [
          "provider error message is #{inspect(error["message"])}, reviewed as #{inspect(expected["error_message"])}"
        ]

    data_errors =
      Enum.flat_map(expected["error_data"] || %{}, fn {key, value} ->
        actual = get_in(error, ["data", key])

        if actual == value,
          do: [],
          else: ["provider error data.#{key} is #{inspect(actual)}, reviewed as #{inspect(value)}"]
      end)

    code_errors ++ message_errors ++ data_errors
  end

  defp ensure_member!(map, key, allowed, label, path) do
    ensure!(map[key] in allowed, "#{path}: #{label} has an unsupported #{key} #{inspect(map[key])}")
  end

  defp ensure_unique!(values, key, label, path) do
    identities = Enum.map(values, & &1[key])
    ensure!(Enum.all?(identities, &(is_binary(&1) and &1 != "")), "#{path}: #{label} #{key} must be non-empty")
    ensure!(length(identities) == length(Enum.uniq(identities)), "#{path}: duplicate #{label} #{key}")
  end

  defp refused(reason), do: {:error, {:refused, reason}}

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)
end
