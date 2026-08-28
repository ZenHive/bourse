defmodule Mix.Tasks.Bourse.ErrorAuthorityCorpus do
  @moduledoc """
  Validates authored first-class error mappings against exchange-owned enumerations.
  """

  alias Mix.Tasks.Bourse.AuthorityCorpus

  @authority_root "priv/venues"
  @spec_root "priv/venues"

  @typedoc "A venue's exact-mapping coverage against its official enumeration."
  @type report :: %{
          venue: String.t(),
          mapped_count: non_neg_integer(),
          documented_count: non_neg_integer(),
          documented_not_mapped: [String.t()],
          dropped_non_authoritative: [String.t()],
          retired: [String.t()],
          disposition: String.t(),
          maintenance_status: String.t(),
          maintenance_identifiers: [String.t()]
        }

  @doc "Validates and reports on the committed authority corpus and authored specs."
  @spec validate!() :: [report()]
  def validate!, do: validate!(@authority_root, @spec_root)

  @doc "Validates and reports using caller-selected authority and spec roots."
  @spec validate!(Path.t(), Path.t()) :: [report()]
  def validate!(authority_root, spec_root) do
    Enum.map(AuthorityCorpus.error_enumeration_venues(), &validate_venue!(&1, authority_root, spec_root))
  end

  defp validate_venue!(venue, authority_root, spec_root) do
    {manifest, corpus} = load_authority!(venue, authority_root)
    exact = spec_root |> load_spec!(venue) |> exact_mappings()
    known = known_identifiers(corpus)

    exact
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(&ensure_known!(&1, known, venue))

    ensure_mapping_targets!(exact, venue)
    ensure_live_probe!(corpus, known, venue)
    ensure_maintenance_adjudication!(corpus, exact, known, venue)
    build_report(venue, manifest, corpus, exact, known)
  end

  defp load_authority!(venue, root) do
    manifest_path = Path.join([root, venue, "authority", "manifest.json"])
    manifest = Bourse.JsonDocument.decode_file!(manifest_path)
    pin = manifest["error_enumeration"] || Mix.raise("#{manifest_path}: missing error_enumeration")
    corpus_path = Path.join([root, venue, "authority", pin["path"] || ""])
    contents = File.read!(corpus_path)

    AuthorityCorpus.verify_content!(pin, contents, corpus_path)
    corpus = Jason.decode!(contents)
    validate_provenance!(venue, manifest, pin, corpus, corpus_path)
    validate_corpus!(venue, corpus, corpus_path)
    {manifest, corpus}
  end

  defp validate_provenance!(venue, manifest, pin, corpus, path) do
    authority = corpus["authority"] || %{}
    source_id = pin["source_artifact_id"]
    source = Enum.find(manifest["artifacts"] || [], &(&1["id"] == source_id))

    ensure!(manifest["venue"] == venue, "#{path}: manifest venue mismatch")
    ensure!(corpus["venue"] == venue, "#{path}: corpus venue mismatch")
    ensure!(is_map(source), "#{path}: source artifact #{inspect(source_id)} is absent")
    ensure!(authority["source_artifact_id"] == source_id, "#{path}: source artifact id mismatch")
    ensure!(authority["source_url"] == pin["source_url"], "#{path}: source URL mismatch")
    ensure!(authority["retrieved_at"] == pin["retrieved_at"], "#{path}: retrieval date mismatch")
    ensure!(authority["source_sha256"] == source["sha256"], "#{path}: source SHA-256 mismatch")
  end

  defp validate_corpus!(venue, corpus, path) do
    ensure!(corpus["schema_version"] == 1, "#{path}: unsupported schema_version")
    ensure_string_map!(corpus["codes"], "#{path}: codes")
    ensure_string_map!(corpus["exact_messages"], "#{path}: exact_messages")
    ensure_string_list!(corpus["retired_codes"], "#{path}: retired_codes")
    ensure_string_list!(corpus["dropped_non_authoritative_identifiers"], "#{path}: dropped identifiers")
    ensure!(corpus["unmapped_code_disposition"] == "exchange_error", "#{venue}: invalid unmapped disposition")
  end

  defp load_spec!(root, venue) do
    Bourse.Spec.load_from_root!(root, venue)
  end

  defp exact_mappings(spec) do
    case get_in(spec, ["errors", "handle_errors", "exceptions"]) do
      %{"exact" => exact} when is_map(exact) -> exact
      exact when is_map(exact) -> exact
      _other -> %{}
    end
  end

  defp known_identifiers(corpus) do
    retired = MapSet.new(corpus["retired_codes"])

    corpus["codes"]
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(retired, &1))
    |> Kernel.++(Map.keys(corpus["exact_messages"]))
    |> MapSet.new()
  end

  defp ensure_known!(identifier, known, venue) do
    ensure!(
      MapSet.member?(known, identifier),
      "#{venue}: authored error_codes entry #{inspect(identifier)} is absent from the active official enumeration"
    )
  end

  defp ensure_mapping_targets!(exact, venue) do
    allowed = allowed_targets()

    Enum.each(exact, fn {identifier, class_name} ->
      ensure!(is_binary(class_name), "#{venue}: error code #{identifier} has a non-string target")
      target = Bourse.Error.from_spec_class(class_name)
      ensure!(target in allowed, "#{venue}: error code #{identifier} resolves to unknown target #{inspect(target)}")
    end)
  end

  defp ensure_live_probe!(corpus, known, venue) do
    probe = corpus["live_probe"] || %{}
    identifier = probe["identifier"]
    evidence = probe["evidence"] || ""

    {path, test_name} =
      case String.split(evidence, ": ", parts: 2) do
        [path, test_name] -> {path, test_name}
        _other -> Mix.raise(~s(#{venue}: live probe evidence must read "<test path>: <test name>"))
      end

    ensure!(MapSet.member?(known, identifier), "#{venue}: live probe identifier #{inspect(identifier)} is undocumented")

    ensure!(
      probe["ccxt_type"] in Enum.map(allowed_targets(), &Atom.to_string/1),
      "#{venue}: live probe target is unknown"
    )

    ensure!(valid_date?(probe["observed_at"]), "#{venue}: live probe date is invalid")
    ensure!(File.read!(path) =~ test_name, "#{venue}: live probe evidence does not name an existing test")
  end

  defp ensure_maintenance_adjudication!(corpus, exact, known, venue) do
    adjudication = corpus["maintenance_adjudication"]
    ensure!(is_map(adjudication), "#{venue}: missing maintenance_adjudication")

    status = adjudication["status"]
    identifiers = adjudication["identifiers"] || []

    ensure!(
      status in ~w(mapped confirmed_mapped no_documented_maintenance_code),
      "#{venue}: invalid maintenance_adjudication status #{inspect(status)}"
    )

    ensure!(is_list(identifiers), "#{venue}: maintenance_adjudication.identifiers must be a list")
    ensure!(adjudication["ccxt_class"] == "OnMaintenance", "#{venue}: maintenance class must be OnMaintenance")

    ensure!(
      adjudication["ccxt_type"] == "exchange_not_available",
      "#{venue}: maintenance type must be exchange_not_available"
    )

    case status do
      "no_documented_maintenance_code" ->
        ensure!(identifiers == [], "#{venue}: no-maintenance finding must list zero identifiers")
        ensure!(is_binary(adjudication["finding"]) and adjudication["finding"] != "", "#{venue}: missing finding")

      _mapped ->
        ensure!(identifiers != [], "#{venue}: maintenance mapping must name at least one identifier")

        Enum.each(identifiers, fn identifier ->
          ensure!(
            MapSet.member?(known, identifier),
            "#{venue}: maintenance identifier #{inspect(identifier)} is undocumented"
          )

          class_name = Map.get(exact, identifier)
          ensure!(is_binary(class_name), "#{venue}: maintenance identifier #{inspect(identifier)} is not exact-mapped")

          ensure!(
            Bourse.Error.from_spec_class(class_name) == :exchange_not_available,
            "#{venue}: #{identifier} is not OnMaintenance"
          )
        end)
    end
  end

  defp build_report(venue, _manifest, corpus, exact, known) do
    documented_not_mapped = known |> MapSet.difference(MapSet.new(Map.keys(exact))) |> Enum.sort()
    adjudication = corpus["maintenance_adjudication"] || %{}

    %{
      venue: venue,
      mapped_count: map_size(exact),
      documented_count: MapSet.size(known),
      documented_not_mapped: documented_not_mapped,
      dropped_non_authoritative: corpus["dropped_non_authoritative_identifiers"],
      retired: corpus["retired_codes"],
      disposition: corpus["unmapped_code_disposition"],
      maintenance_status: adjudication["status"] || "missing",
      maintenance_identifiers: adjudication["identifiers"] || []
    }
  end

  defp allowed_targets do
    Bourse.Error.recoverable_types() ++ Bourse.Error.non_recoverable_types() ++ [:exchange_error]
  end

  defp ensure_string_map!(map, label) when is_map(map) do
    Enum.each(map, fn {key, meanings} ->
      ensure!(is_binary(key) and key != "", "#{label}: identifier must be a non-empty string")
      ensure_string_list!(meanings, "#{label}:#{key}")
      ensure!(meanings != [], "#{label}:#{key} must name at least one meaning")
    end)
  end

  defp ensure_string_map!(_value, label), do: Mix.raise("#{label} must be an object")

  defp ensure_string_list!(values, label) when is_list(values) do
    ensure!(Enum.all?(values, &(is_binary(&1) and &1 != "")), "#{label} must contain non-empty strings")
  end

  defp ensure_string_list!(_value, label), do: Mix.raise("#{label} must be a list")

  defp valid_date?(value) when is_binary(value), do: match?({:ok, _date}, Date.from_iso8601(value))
  defp valid_date?(_value), do: false

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: Mix.raise(message)
end
