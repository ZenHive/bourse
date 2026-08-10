defmodule Mix.Tasks.Ccxt.AuthorityCorpus do
  @moduledoc """
  Validates the first-class venue authority manifests and local artifact hashes.
  """

  @runtime_manifest Bourse.Spec.manifest_path()
  @external_resource @runtime_manifest
  @venues Bourse.Spec.exchanges()
  @required_artifact_fields ~w(id kind source_url fetch_url filename retrieved_at upstream_pin sha256 bytes storage license drift freshness expressiveness scope authority)
  @required_license_fields ~w(status license evidence_url handling reason)
  @required_freshness_fields ~w(status checked_at mutable notes)
  @required_expressiveness_fields ~w(level limitations)
  @required_scope_fields ~w(surface coverage limitations)
  @required_authority_fields ~w(classification semantic_authority completeness_gate)
  @required_rejected_candidate_fields ~w(id source_url authority reason)
  @freshness_statuses ~w(reviewed_current initial_baseline pinned_snapshot known_stale drift_detected)
  @expressiveness_levels ~w(typed_openapi typed_asyncapi untyped_postman documentation_index prose_documentation source_archive)
  @contract_surfaces ~w(current_rest upcoming_rest current_websocket upcoming_websocket documentation_index)
  @scope_coverages ~w(complete partial index_only)
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @date_pattern ~r/\A\d{4}-\d{2}-\d{2}\z/

  # Venues whose provider publishes NO error-code enumeration, so their authored
  # `errors.handle_errors.exceptions.exact` codes cannot be graded against a pinned
  # document. Governed, must only shrink: an entry is admissible only when the
  # provider genuinely publishes nothing, and every exact code the venue authors is
  # instead pinned by a live tagged integration test. Enforced by
  # `test/mix/tasks/ccxt_error_authority_test.exs`.
  @error_enumeration_exemptions %{
    "lighter" =>
      "Lighter publishes no error-code enumeration (confirmed 2026-07-23, task 451): the pinned " <>
        "`rest-openapi` artifact defines only the {code, message} result envelope and no docs page " <>
        "lists code values. Its authored codes are live-observation-derived and pinned by " <>
        "test/bourse/lighter_promotion_integration_test.exs and test/bourse/lighter_signing_integration_test.exs."
  }

  @doc "Returns the governed first-class venue ids."
  @spec venues() :: [String.t()]
  def venues, do: @venues

  @doc "Returns the first-class venues graded against a pinned error-code enumeration."
  @spec error_enumeration_venues() :: [String.t()]
  def error_enumeration_venues, do: @venues -- Map.keys(@error_enumeration_exemptions)

  @doc "Returns venue id => reason for venues with no provider-published error enumeration."
  @spec error_enumeration_exemptions() :: %{optional(String.t()) => String.t()}
  def error_enumeration_exemptions, do: @error_enumeration_exemptions

  @doc "Loads and validates all authority manifests below `root`."
  @spec load!(Path.t()) :: [map()]
  def load!(root) do
    Enum.map(@venues, fn venue -> load_manifest!(root, venue) end)
  end

  @doc "Returns a lowercase SHA-256 digest for binary content."
  @spec sha256(binary()) :: String.t()
  def sha256(contents) do
    contents
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Checks fetched or vendored bytes against an artifact manifest."
  @spec verify_content!(map(), binary(), String.t()) :: :ok
  def verify_content!(artifact, contents, label) do
    ensure!(byte_size(contents) == artifact["bytes"], "#{label}: byte count differs from manifest")
    ensure!(sha256(contents) == artifact["sha256"], "#{label}: SHA-256 differs from manifest")
    :ok
  end

  defp load_manifest!(root, venue) do
    path = Path.join([root, venue, "manifest.json"])
    document = Bourse.JsonDocument.decode_file!(path)

    ensure!(document["schema_version"] == 2, "#{path}: unsupported schema_version")
    ensure!(document["venue"] == venue, "#{path}: venue does not match directory")
    ensure_string!(document, "official_docs_url", path)
    ensure_string!(document, "selection_reason", path)
    ensure!(document["fetch_script"] == "scripts/fetch_authority.sh", "#{path}: fetch_script is not canonical")
    ensure_artifacts!(document["artifacts"], root, venue, path)
    ensure_rejected_candidates!(document["rejected_candidates"], path)
    document
  end

  defp ensure_artifacts!(artifacts, root, venue, manifest_path) do
    ensure!(is_list(artifacts) and artifacts != [], "#{manifest_path}: artifacts must be a non-empty list")
    ids = Enum.map(artifacts, & &1["id"])
    ensure!(length(ids) == length(Enum.uniq(ids)), "#{manifest_path}: artifact ids must be unique")

    Enum.each(artifacts, fn artifact ->
      ensure_artifact!(artifact, root, venue, manifest_path)
    end)
  end

  defp ensure_artifact!(artifact, root, venue, manifest_path) do
    label = "#{manifest_path}:#{artifact["id"] || "unknown"}"
    ensure_keys!(artifact, @required_artifact_fields, label)

    Enum.each(~w(id kind source_url fetch_url filename), fn field ->
      ensure_string!(artifact, field, label)
    end)

    ensure!(valid_format?(artifact["sha256"], @sha256_pattern), "#{label}: invalid SHA-256")
    ensure!(valid_format?(artifact["retrieved_at"], @date_pattern), "#{label}: invalid retrieval date")
    ensure!(is_integer(artifact["bytes"]) and artifact["bytes"] > 0, "#{label}: invalid byte count")
    ensure_pin!(artifact["upstream_pin"], label)
    ensure_license!(artifact["license"], artifact["storage"], label)
    ensure_drift!(artifact["drift"], label)
    ensure_freshness!(artifact["freshness"], label)
    ensure_expressiveness!(artifact["expressiveness"], label)
    ensure_scope!(artifact["scope"], label)
    ensure_authority!(artifact["authority"], artifact, label)
    ensure_storage!(artifact, root, venue, label)
  end

  defp ensure_freshness!(freshness, label) do
    ensure!(is_map(freshness), "#{label}: freshness must be an object")
    ensure_keys!(freshness, @required_freshness_fields, label)
    ensure_member!(freshness["status"], @freshness_statuses, "freshness status", label)
    ensure!(valid_format?(freshness["checked_at"], @date_pattern), "#{label}: invalid freshness check date")
    ensure!(is_boolean(freshness["mutable"]), "#{label}: freshness mutable must be boolean")
    ensure_string!(freshness, "notes", label)
  end

  defp ensure_expressiveness!(expressiveness, label) do
    ensure!(is_map(expressiveness), "#{label}: expressiveness must be an object")
    ensure_keys!(expressiveness, @required_expressiveness_fields, label)
    ensure_member!(expressiveness["level"], @expressiveness_levels, "expressiveness level", label)
    ensure_non_empty_strings!(expressiveness["limitations"], "expressiveness limitations", label)
  end

  defp ensure_scope!(scopes, label) do
    ensure!(is_list(scopes) and scopes != [], "#{label}: scope must be a non-empty list")

    Enum.each(scopes, fn scope ->
      ensure!(is_map(scope), "#{label}: scope entries must be objects")
      ensure_keys!(scope, @required_scope_fields, label)
      ensure_member!(scope["surface"], @contract_surfaces, "contract surface", label)
      ensure_member!(scope["coverage"], @scope_coverages, "scope coverage", label)
      ensure_non_empty_strings!(scope["limitations"], "scope limitations", label)
    end)

    surfaces = Enum.map(scopes, & &1["surface"])
    ensure!(length(surfaces) == length(Enum.uniq(surfaces)), "#{label}: contract surfaces must be unique")
    ensure_separate_versions!(surfaces, "current_rest", "upcoming_rest", label)
    ensure_separate_versions!(surfaces, "current_websocket", "upcoming_websocket", label)
  end

  defp ensure_authority!(authority, artifact, label) do
    ensure!(is_map(authority), "#{label}: authority must be an object")
    ensure_keys!(authority, @required_authority_fields, label)
    ensure!(authority["classification"] == "provider_owned", "#{label}: relied-on artifacts must be provider-owned")
    ensure!(is_boolean(authority["semantic_authority"]), "#{label}: semantic_authority must be boolean")
    ensure!(is_boolean(authority["completeness_gate"]), "#{label}: completeness_gate must be boolean")

    if authority["completeness_gate"] do
      ensure_completeness_source!(artifact, label)
    end
  end

  defp ensure_completeness_source!(artifact, label) do
    typed = artifact["expressiveness"]["level"] in ~w(typed_openapi typed_asyncapi)
    complete = Enum.all?(artifact["scope"], &(&1["coverage"] == "complete"))
    current = artifact["freshness"]["status"] in ~w(reviewed_current initial_baseline)

    ensure!(typed and complete and current, "#{label}: partial, stale, or untyped artifact cannot be a completeness gate")
  end

  defp ensure_rejected_candidates!(candidates, manifest_path) do
    ensure!(is_list(candidates), "#{manifest_path}: rejected_candidates must be a list")

    Enum.each(candidates, fn candidate ->
      label = "#{manifest_path}:rejected:#{candidate["id"] || "unknown"}"
      ensure!(is_map(candidate), "#{label}: candidate must be an object")
      ensure_keys!(candidate, @required_rejected_candidate_fields, label)
      Enum.each(@required_rejected_candidate_fields, &ensure_string!(candidate, &1, label))
      ensure_member!(candidate["authority"], ~w(provider_owned third_party), "candidate authority", label)
    end)
  end

  defp ensure_separate_versions!(surfaces, current, upcoming, label) do
    ensure!(
      not (current in surfaces and upcoming in surfaces),
      "#{label}: current and upcoming surfaces require separate artifacts"
    )
  end

  defp ensure_non_empty_strings!(values, field, label) do
    valid? = is_list(values) and values != [] and Enum.all?(values, &(is_binary(&1) and &1 != ""))
    ensure!(valid?, "#{label}: #{field} must be a non-empty string list")
  end

  defp ensure_member!(value, allowed, field, label) do
    ensure!(value in allowed, "#{label}: unsupported #{field} #{inspect(value)}")
  end

  defp ensure_keys!(map, keys, label) do
    missing = Enum.reject(keys, &Map.has_key?(map, &1))
    ensure!(missing == [], "#{label}: missing fields #{Enum.join(missing, ", ")}")
  end

  defp ensure_pin!(pin, label) do
    ensure!(is_map(pin), "#{label}: upstream_pin must be an object")
    ensure_string!(pin, "type", label)
    ensure_string!(pin, "value", label)
  end

  defp ensure_license!(license, storage, label) do
    ensure!(is_map(license), "#{label}: license must be an object")
    ensure_keys!(license, @required_license_fields, label)

    Enum.each(@required_license_fields, fn field ->
      ensure_string!(license, field, label)
    end)

    case storage do
      "reference_only" ->
        ensure!(license["handling"] == "reference_only", "#{label}: unclear licensing must stay reference-only")

      "vendored" ->
        ensure!(license["status"] == "permitted", "#{label}: vendored content needs explicit permission")

      other ->
        Mix.raise("#{label}: unsupported storage mode #{inspect(other)}")
    end
  end

  defp ensure_drift!(%{"mode" => "sha256", "url" => url}, _label) when is_binary(url), do: :ok

  defp ensure_drift!(%{"mode" => "git_head", "repository_url" => url}, label) when is_binary(url),
    do: ensure!(url != "", "#{label}: empty drift repository_url")

  defp ensure_drift!(_drift, label), do: Mix.raise("#{label}: unsupported drift check")

  defp ensure_storage!(%{"storage" => "reference_only", "path" => path}, _root, _venue, label) do
    ensure!(is_nil(path), "#{label}: reference-only artifact must not have a vendored path")
  end

  defp ensure_storage!(%{"storage" => "vendored", "path" => path} = artifact, root, venue, label) when is_binary(path) do
    contents = File.read!(Path.join([root, venue, path]))
    verify_content!(artifact, contents, label)
  end

  defp ensure_storage!(_artifact, _root, _venue, label), do: Mix.raise("#{label}: invalid storage/path pair")

  defp ensure_string!(map, key, label) do
    value = map[key]
    ensure!(is_binary(value) and value != "", "#{label}: #{key} must be a non-empty string")
  end

  defp valid_format?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: Mix.raise(message)
end
