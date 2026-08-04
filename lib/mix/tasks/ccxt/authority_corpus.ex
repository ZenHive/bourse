defmodule Mix.Tasks.Ccxt.AuthorityCorpus do
  @moduledoc """
  Validates the first-class venue authority manifests and local artifact hashes.
  """

  @runtime_manifest Bourse.Spec.manifest_path()
  @external_resource @runtime_manifest
  @venues Bourse.Spec.exchanges()
  @required_artifact_fields ~w(id kind source_url fetch_url filename retrieved_at upstream_pin sha256 bytes storage license drift)
  @required_license_fields ~w(status license evidence_url handling reason)
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

    ensure!(document["schema_version"] == 1, "#{path}: unsupported schema_version")
    ensure!(document["venue"] == venue, "#{path}: venue does not match directory")
    ensure_string!(document, "official_docs_url", path)
    ensure_string!(document, "selection_reason", path)
    ensure!(document["fetch_script"] == "scripts/fetch_authority.sh", "#{path}: fetch_script is not canonical")
    ensure_artifacts!(document["artifacts"], root, venue, path)
    document
  end

  defp ensure_artifacts!(artifacts, root, venue, manifest_path) do
    ensure!(is_list(artifacts) and artifacts != [], "#{manifest_path}: artifacts must be a non-empty list")

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
    ensure_storage!(artifact, root, venue, label)
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
