defmodule Mix.Tasks.Ccxt.ContractComparator do
  @moduledoc """
  Compares pinned provider-contract inventories with complete authored specs.

  Reports relation, runtime scope, evidence, reachability, and contract scope as
  independent axes. The comparator is read-only: it never executes operations,
  edits specs, or turns a syntactic difference into a semantic decision.
  """

  alias Mix.Tasks.Ccxt.AuthorityCorpus
  alias Mix.Tasks.Ccxt.ContractSource

  @authority_root "priv/authority"
  @spec_root "priv/specs/json/output/authored"
  @digest_dir "surface-digests"
  @key_set_fields ~w(channel_keys path_keys operation_keys)
  @surfaces ~w(current_rest upcoming_rest current_websocket upcoming_websocket)
  @current_surfaces ~w(current_rest current_websocket)
  @runtime_scopes ~w(unified raw_only carved not_implemented unknown)
  @evidence_values ~w(verified unverified)
  @reachability_values ~w(safe unsafe unreachable unknown)
  @rest_methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "HEAD" => :head,
    "OPTIONS" => :options,
    "TRACE" => :trace
  }

  @typedoc "A deterministic per-venue comparison report."
  @type report :: map()

  @doc "Compares every supported venue using caller-materialized pinned artifacts."
  @spec compare_all!(Path.t(), keyword()) :: [report()]
  def compare_all!(artifact_root, opts \\ []) do
    authority_root = Keyword.get(opts, :authority_root, @authority_root)
    spec_root = Keyword.get(opts, :spec_root, @spec_root)

    facts = load_facts(Keyword.get(opts, :facts_path))
    venue_filter = Keyword.get(opts, :venue)

    authority_root
    |> AuthorityCorpus.load!()
    |> Enum.filter(&(is_nil(venue_filter) or &1["venue"] == venue_filter))
    |> Enum.map(fn manifest ->
      authored = Bourse.JsonDocument.decode_file!(Path.join(spec_root, "#{manifest["venue"]}.json"))
      venue_facts = Enum.filter(facts, &(&1["venue"] == manifest["venue"]))
      report = compare_venue!(manifest, authored, artifact_root, venue_facts)
      validate_committed_baseline!(report, authority_root)
      report
    end)
  end

  @doc "Builds one venue report from a validated manifest and authored document."
  @spec compare_venue!(map(), map(), Path.t(), [map()]) :: report()
  def compare_venue!(manifest, authored, artifact_root, facts \\ []) do
    facts = Enum.map(facts, &validate_fact!(&1, "registered facts"))

    Enum.each(facts, fn fact ->
      ensure!(fact["venue"] == manifest["venue"], "registered facts: venue mismatch")
    end)

    build_report(manifest, authored, artifact_root, facts)
  end

  @doc "Returns the committed surface-digest path for one authority artifact."
  @spec surface_digest_path(Path.t(), String.t(), String.t()) :: Path.t()
  def surface_digest_path(authority_root, venue, artifact_id) do
    Path.join([authority_root, venue, @digest_dir, "#{artifact_id}.json"])
  end

  @doc "Loads a retained surface digest, or `nil` when the artifact has none."
  @spec load_surface_digest(Path.t(), String.t(), String.t()) :: map() | nil
  def load_surface_digest(authority_root, venue, artifact_id) do
    path = surface_digest_path(authority_root, venue, artifact_id)
    if File.exists?(path), do: Bourse.JsonDocument.decode_file!(path)
  end

  @doc "Loads a retained surface digest and raises when it is absent."
  @spec load_surface_digest!(Path.t(), String.t(), String.t()) :: map()
  def load_surface_digest!(authority_root, venue, artifact_id) do
    load_surface_digest(authority_root, venue, artifact_id) ||
      Mix.raise("missing surface digest for #{venue}/#{artifact_id}")
  end

  @doc """
  Names entities that entered, left, or changed identity between two digests.

  Either side may be a full digest or a `prior` slice that carries only
  `key_sets`. Per-entity change detection runs only when both sides retain
  entity hashes.
  """
  @spec diff_surface_digests(map(), map()) :: map()
  def diff_surface_digests(prior, current) when is_map(prior) and is_map(current) do
    added = key_set_delta(current, prior)
    removed = key_set_delta(prior, current)

    %{
      "schema_version" => 1,
      "report_type" => "authority_surface_delta",
      "named" => true,
      "prior" => digest_ref(prior),
      "current" => digest_ref(current),
      "added" => added,
      "removed" => removed,
      "changed" => changed_entities(prior, current),
      "counts" => %{
        "added_channel_count" => length(added["channel_keys"]),
        "added_path_count" => length(added["path_keys"]),
        "added_operation_count" => length(added["operation_keys"]),
        "removed_channel_count" => length(removed["channel_keys"]),
        "removed_path_count" => length(removed["path_keys"]),
        "removed_operation_count" => length(removed["operation_keys"])
      }
    }
  end

  @doc """
  Reviews current artifact bytes against the digest retained in the authority tree.

  A missing digest is not an error: `reference_only` artifacts stay valid
  without one. The review then cannot name entity-level additions or removals.
  When the supplied bytes still match the retained pin, the last superseded
  `prior` slice is compared so a completed republish remains nameable.
  """
  @spec review_retained_surface(String.t(), map(), binary(), Path.t()) :: map()
  def review_retained_surface(venue, artifact, current_contents, authority_root \\ @authority_root)
      when is_binary(venue) and is_map(artifact) and is_binary(current_contents) do
    retained = load_surface_digest(authority_root, venue, artifact["id"])
    current = ContractSource.surface_digest(artifact, current_contents)

    cond do
      is_nil(retained) ->
        unnamed_surface_delta(
          "No retained surface digest for #{venue}/#{artifact["id"]}; added and removed entities cannot be named from repo state."
        )

      current["source"]["sha256"] == retained["source"]["sha256"] and is_map(retained["prior"]) ->
        diff_surface_digests(retained["prior"], retained)

      true ->
        diff_surface_digests(retained, current)
    end
  end

  defp build_report(manifest, authored, artifact_root, facts) do
    sources = load_sources(manifest, artifact_root)
    authored_rest = authored_rest_operations(authored)
    authored_websocket = authored_websocket_operations(authored)

    surfaces =
      Map.new(@surfaces, fn surface ->
        authored_operations =
          if String.ends_with?(surface, "websocket"), do: authored_websocket, else: authored_rest

        {surface, compare_surface(surface, sources, authored_operations, facts)}
      end)

    %{
      "schema_version" => 1,
      "report_type" => "provider_contract_comparison",
      "venue" => manifest["venue"],
      "provenance" => %{
        "authority_manifest" => "priv/authority/#{manifest["venue"]}/manifest.json",
        "authored_spec_canonical_sha256" => authored |> Jason.encode!() |> AuthorityCorpus.sha256(),
        "artifacts" => Enum.map(sources, & &1.provenance)
      },
      "surfaces" => surfaces,
      "semantic_effect" => "none",
      "allowed_actions" => [],
      "limitations" => [
        "Syntactic equality does not establish semantic correctness.",
        "Provider examples are documentation and never mark evidence verified.",
        "Findings require later provider confrontation before any runtime change."
      ]
    }
  end

  @doc "Validates a report against any committed source-revision baseline."
  @spec validate_committed_baseline!(report(), Path.t()) :: :ok
  def validate_committed_baseline!(report, authority_root \\ @authority_root) do
    path = Path.join([authority_root, report["venue"], "contract-baselines.json"])

    if File.exists?(path) do
      baseline = Bourse.JsonDocument.decode_file!(path)
      validate_baseline_document!(report, baseline, path)
    end

    :ok
  end

  @doc "Derives authored REST authentication facts by provider operation key."
  @spec authored_rest_authentication(map()) :: %{String.t() => [map()]}
  def authored_rest_authentication(authored) when is_map(authored) do
    authored
    |> authored_rest_operations()
    |> Enum.group_by(& &1["key"])
    |> Map.new(fn {key, variants} ->
      authentication = variants |> Enum.map(&Map.take(&1, ["authentication"])) |> Enum.sort()
      {key, authentication}
    end)
  end

  @doc "Loads and validates optional registered per-operation axis facts."
  @spec load_facts(Path.t() | nil) :: [map()]
  def load_facts(nil), do: []

  def load_facts(path) do
    document = Bourse.JsonDocument.decode_file!(path)
    ensure!(document["schema_version"] == 1, "#{path}: unsupported facts schema_version")
    ensure!(is_list(document["operations"]), "#{path}: operations must be a list")
    Enum.map(document["operations"], &validate_fact!(&1, path))
  end

  defp load_sources(manifest, artifact_root) do
    Enum.map(manifest["artifacts"], fn artifact ->
      path = Path.join([artifact_root, manifest["venue"], artifact["filename"]])
      provenance = artifact_provenance(artifact, path)

      if File.exists?(path) do
        contents = File.read!(path)
        AuthorityCorpus.verify_content!(artifact, contents, "#{manifest["venue"]}/#{artifact["id"]}")
        parsed = ContractSource.parse!(artifact, contents)

        %{
          artifact: artifact,
          available: true,
          operations: Enum.map(parsed.operations, &Map.put(&1, "artifact_id", artifact["id"])),
          limitations: artifact_limitations(artifact) ++ parsed.limitations,
          metrics: parsed.metrics,
          provenance: Map.merge(provenance, %{"status" => source_status(artifact), "metrics" => parsed.metrics})
        }
      else
        %{
          artifact: artifact,
          available: false,
          operations: [],
          limitations:
            artifact_limitations(artifact) ++
              ["Pinned artifact bytes were not materialized at #{path}; no remote content was substituted."],
          metrics: %{},
          provenance: Map.put(provenance, "status", "unavailable")
        }
      end
    end)
  end

  defp artifact_provenance(artifact, path) do
    artifact
    |> Map.take(~w(id kind source_url retrieved_at upstream_pin sha256 bytes freshness expressiveness scope))
    |> Map.put("materialized_path", path)
  end

  defp source_status(artifact) do
    if artifact["kind"] in ~w(openapi-json openapi-yaml postman-collection asyncapi-json) do
      "parsed"
    else
      "source_capability_limited"
    end
  end

  defp artifact_limitations(artifact) do
    expressiveness = get_in(artifact, ["expressiveness", "limitations"]) || []
    scope = Enum.flat_map(artifact["scope"] || [], &(&1["limitations"] || []))
    Enum.uniq(expressiveness ++ scope)
  end

  defp compare_surface(surface, sources, authored_operations, facts) do
    surface_sources = Enum.filter(sources, &source_covers?(&1, surface))
    provider = provider_inventory(surface_sources)
    authored = merge_inventory(authored_operations)
    operation_keys = provider |> Map.keys() |> Kernel.++(Map.keys(authored)) |> Enum.uniq() |> Enum.sort()
    surface_facts = Enum.filter(facts, &(&1["contract_scope"] == surface))

    Enum.each(surface_facts, fn fact ->
      ensure!(
        fact["operation_key"] in operation_keys,
        "registered facts: unknown operation #{surface} #{fact["operation_key"]}"
      )
    end)

    operations =
      Enum.map(operation_keys, fn key ->
        compare_operation(surface, key, provider[key], authored[key], surface_facts)
      end)

    counts = relation_counts(operations)
    completeness = completeness_claim?(surface_sources, surface)

    %{
      "contract_scope" => surface,
      "current_runtime_denominator" => surface in @current_surfaces,
      "source_capability" => source_capability(surface_sources, completeness),
      "completeness_claim" => completeness,
      "provider_count" => map_size(provider),
      "authored_count" => map_size(authored),
      "shared_count" => counts.shared,
      "provider_only_count" => counts.provider_only,
      "authored_only_count" => counts.authored_only,
      "current_runtime_missing_count" =>
        if(surface in @current_surfaces and completeness, do: counts.provider_only, else: 0),
      "source_metrics" => Map.new(surface_sources, &{&1.artifact["id"], &1.metrics}),
      "limitations" => surface_limitations(surface_sources),
      "operations" => operations
    }
  end

  defp source_covers?(source, surface) do
    Enum.any?(source.artifact["scope"] || [], &(&1["surface"] == surface))
  end

  defp provider_inventory(sources) do
    sources
    |> Enum.flat_map(& &1.operations)
    |> merge_inventory()
  end

  defp merge_inventory(operations) do
    operations
    |> Enum.group_by(& &1["key"])
    |> Map.new(fn {key, variants} -> {key, Enum.sort_by(variants, &(&1["artifact_id"] || "authored"))} end)
  end

  defp compare_operation(surface, key, provider, authored, facts) do
    relation = operation_relation(provider, authored)
    runtime_scope = authored_runtime_scope(authored)
    fact = operation_fact!(facts, surface, key)

    %{
      "operation_key" => key,
      "axes" => %{
        "relation" => relation,
        "runtime_scope" => fact["runtime_scope"] || runtime_scope,
        "evidence" => fact["evidence"] || "unverified",
        "reachability" => fact["reachability"] || "unknown",
        "contract_scope" => surface
      },
      "provider" => provider || [],
      "authored" => authored || [],
      "field_differences" => field_differences(provider, authored)
    }
  end

  defp operation_relation(nil, _authored), do: "authored_only"
  defp operation_relation(_provider, nil), do: "provider_only"
  defp operation_relation(_provider, _authored), do: "shared"

  defp authored_runtime_scope(nil), do: "unknown"

  defp authored_runtime_scope(variants) do
    if Enum.any?(variants, &(&1["runtime_scope"] == "unified")), do: "unified", else: "raw_only"
  end

  defp operation_fact!(facts, surface, key) do
    matching = Enum.filter(facts, &(&1["contract_scope"] == surface and &1["operation_key"] == key))
    ensure!(length(matching) <= 1, "duplicate registered facts for #{surface} #{key}")
    List.first(matching) || %{}
  end

  defp field_differences(nil, _authored), do: []
  defp field_differences(_provider, nil), do: []

  defp field_differences(provider, authored) do
    Enum.flat_map(~w(authentication parameters response_schemas message_schemas examples message_references), fn field ->
      provider_values = known_field_values(provider, field)
      authored_values = known_field_values(authored, field)

      if provider_values != [] and authored_values != [] and provider_values != authored_values do
        [%{"field" => field, "provider" => provider_values, "authored" => authored_values}]
      else
        []
      end
    end)
  end

  defp known_field_values(variants, field) do
    variants
    |> Enum.flat_map(fn variant ->
      case variant[field] do
        %{"status" => "known", "value" => value} -> [value]
        _unknown -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp relation_counts(operations) do
    Enum.reduce(operations, %{shared: 0, provider_only: 0, authored_only: 0}, fn operation, counts ->
      relation = operation["axes"]["relation"]
      Map.update!(counts, String.to_existing_atom(relation), &(&1 + 1))
    end)
  end

  defp completeness_claim?(sources, surface) do
    Enum.any?(sources, fn source ->
      source.available and source.provenance["status"] == "parsed" and
        source.artifact["authority"]["completeness_gate"] == true and
        Enum.any?(source.artifact["scope"], &(&1["surface"] == surface and &1["coverage"] == "complete"))
    end)
  end

  defp source_capability([], _completeness), do: "unavailable"
  defp source_capability(_sources, true), do: "complete_machine_inventory"

  defp source_capability(sources, false) do
    if Enum.any?(sources, &(&1.available and &1.provenance["status"] == "parsed")) do
      "partial_machine_inventory"
    else
      "source_capability_limited"
    end
  end

  defp surface_limitations([]), do: ["No provider-owned artifact is registered for this contract scope."]

  defp surface_limitations(sources) do
    sources
    |> Enum.flat_map(& &1.limitations)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns the authored REST operations of one complete authored document.

  Each entry carries the `"key"` the provider inventory is compared against plus
  the authored `"runtime_scope"`, so a caller that already knows an operation key
  can resolve relation and runtime scope without a provider artifact.
  """
  @spec authored_rest_operations(map()) :: [map()]
  def authored_rest_operations(authored) do
    unified_names =
      authored
      |> get_in(["endpoints", "unified"])
      |> case do
        values when is_map(values) -> values |> Map.values() |> List.flatten() |> MapSet.new()
        _other -> MapSet.new()
      end

    authored
    |> get_in(["endpoints", "request", "shape"])
    |> Enum.flat_map(fn {section, config} ->
      Enum.map(config["endpoints"] || [], fn endpoint ->
        authored_rest_operation(authored, section, endpoint, unified_names)
      end)
    end)
    |> Enum.sort_by(& &1["key"])
  end

  defp authored_rest_operation(authored, section, endpoint, unified_names) do
    method = String.upcase(endpoint["http_verb"])
    path = authored_path(authored, section, endpoint["path_template"])
    sections = String.split(section, ".")
    js_name = Bourse.UnifiedMethod.endpoint_config_to_js_name(sections, @rest_methods[method], endpoint["path_template"])
    authenticated = authored_authenticated?(authored, section)
    path_parameters = endpoint["path_params"]

    %{
      "key" => "#{method} #{path}",
      "transport" => "rest",
      "path" => path,
      "channel" => nil,
      "method" => method,
      "authentication" => ContractSource.known(%{"required" => authenticated}),
      "parameters" => authored_path_parameters(path_parameters),
      "response_schemas" => ContractSource.unknown(),
      "message_schemas" => ContractSource.unknown(),
      "examples" => ContractSource.unknown(),
      "message_references" => ContractSource.unknown(),
      "qualifiers" => [],
      "runtime_scope" => if(MapSet.member?(unified_names, js_name), do: "unified", else: "raw_only")
    }
  end

  defp authored_path(authored, section, endpoint_path) do
    templates = get_in(authored, ["raw", "url_templates"]) || %{}

    template_prefix =
      case Map.get(templates, section) do
        template when is_map(template) -> Map.get(template, "url_prefix")
        _other -> nil
      end

    prefix = template_prefix || authored_api_url(authored, section)

    base_path = if is_binary(prefix), do: URI.parse(prefix).path || "", else: ""
    ContractSource.normalize_path("#{base_path}/#{endpoint_path}")
  end

  defp authored_api_url(authored, section) do
    api = get_in(authored, ["raw", "describe", "urls", "api"]) || %{}

    if is_map(api) do
      Map.get(api, section) || nested_api_url(api, String.split(section, "."))
    else
      api
    end
  end

  defp nested_api_url(api, sections) do
    Enum.reduce_while(sections, api, fn section, value ->
      cond do
        is_binary(value) -> {:halt, value}
        is_map(value) and Map.has_key?(value, section) -> {:cont, value[section]}
        true -> {:halt, nil}
      end
    end)
  end

  defp authored_authenticated?(authored, section) do
    authenticated = get_in(authored, ["auth", "authenticated_sections"]) || []
    top = section |> String.split(".", parts: 2) |> List.first()
    section in authenticated or top in authenticated
  end

  defp authored_path_parameters(path_parameters) when is_list(path_parameters) do
    path_parameters
    |> Enum.map(fn parameter ->
      name = if is_map(parameter), do: parameter["name"], else: parameter

      %{
        "name" => name,
        "location" => "path",
        "required" => ContractSource.known(true),
        "type" => ContractSource.unknown(),
        "schema" => ContractSource.unknown(),
        "example" => ContractSource.unknown(),
        "source_ref" => nil
      }
    end)
    |> ContractSource.known()
  end

  defp authored_path_parameters(_path_parameters), do: ContractSource.unknown()

  defp authored_websocket_operations(authored) do
    channels = get_in(authored, ["websocket", "subscribe", "channels"]) || %{}

    channels
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn channel ->
      Enum.map(~w(send receive), &authored_websocket_operation(channel, &1))
    end)
    |> Enum.sort_by(& &1["key"])
  end

  defp authored_websocket_operation(channel, method) do
    %{
      "key" => "#{method} #{channel}",
      "transport" => "websocket",
      "path" => nil,
      "channel" => channel,
      "method" => method,
      "authentication" => ContractSource.unknown(),
      "parameters" => ContractSource.unknown(),
      "response_schemas" => ContractSource.unknown(),
      "message_schemas" => ContractSource.unknown(),
      "examples" => ContractSource.unknown(),
      "message_references" => ContractSource.unknown(),
      "qualifiers" => [],
      "runtime_scope" => "unified"
    }
  end

  defp validate_fact!(fact, path) do
    ensure_string!(fact, "venue", path)
    ensure_string!(fact, "operation_key", path)
    ensure_member!(fact["contract_scope"], @surfaces, "contract_scope", path)
    validate_optional_member!(fact, "runtime_scope", @runtime_scopes, path)
    validate_optional_member!(fact, "evidence", @evidence_values, path)
    validate_optional_member!(fact, "reachability", @reachability_values, path)
    refuse_verified_evidence!(fact, path)
    fact
  end

  defp refuse_verified_evidence!(%{"evidence" => "verified"}, path) do
    Mix.raise(
      "#{path}: evidence verified cannot be declared here. This task compares pinned " <>
        "provider artifacts against authored specs; it never calls a venue, so it can " <>
        "establish no observed behaviour. Verification is earned only by the " <>
        "provider-live contract lane (mix ccxt.verify_rest_read_contracts)."
    )
  end

  defp refuse_verified_evidence!(_fact, _path), do: :ok

  defp validate_baseline_document!(report, baseline, path) do
    ensure!(baseline["schema_version"] == 1, "#{path}: unsupported schema_version")
    ensure!(baseline["venue"] == report["venue"], "#{path}: venue mismatch")

    Enum.each(baseline["surfaces"] || %{}, fn {surface, expected} ->
      actual = report["surfaces"][surface] || Mix.raise("#{path}: report omits #{surface}")
      artifact_id = expected["artifact_id"]
      provenance = Enum.find(report["provenance"]["artifacts"], &(&1["id"] == artifact_id))

      ensure!(is_map(provenance), "#{path}: artifact #{artifact_id} is absent")
      ensure!(provenance["sha256"] == expected["sha256"], "#{path}: #{surface} SHA-256 mismatch")
      ensure!(provenance["upstream_pin"] == expected["upstream_pin"], "#{path}: #{surface} revision mismatch")

      if provenance["status"] == "parsed" do
        validate_expected_counts!(actual, provenance["metrics"], expected["expected"], path, surface)
      end
    end)
  end

  defp validate_expected_counts!(surface_report, metrics, expected, path, surface) do
    Enum.each(expected || %{}, fn
      {"provider_count", value} ->
        ensure!(surface_report["provider_count"] == value, "#{path}: #{surface} provider_count differs")

      {"authored_count", value} ->
        ensure!(surface_report["authored_count"] == value, "#{path}: #{surface} authored_count differs")

      {"shared_count", value} ->
        ensure!(surface_report["shared_count"] == value, "#{path}: #{surface} shared_count differs")

      {"provider_only_count", value} ->
        ensure!(surface_report["provider_only_count"] == value, "#{path}: #{surface} provider_only_count differs")

      {"authored_only_count", value} ->
        ensure!(surface_report["authored_only_count"] == value, "#{path}: #{surface} authored_only_count differs")

      {metric, value} ->
        ensure!(metrics[metric] == value, "#{path}: #{surface} #{metric} differs")
    end)
  end

  defp key_set_delta(left, right) do
    Map.new(@key_set_fields, fn field ->
      left_keys = MapSet.new(get_in(left, ["key_sets", field]) || [])
      right_keys = MapSet.new(get_in(right, ["key_sets", field]) || [])
      {field, left_keys |> MapSet.difference(right_keys) |> Enum.sort()}
    end)
  end

  defp changed_entities(prior, current) do
    prior_entities = entity_index(prior)
    current_entities = entity_index(current)

    cond do
      prior_entities == %{} -> []
      current_entities == %{} -> []
      true -> entity_hash_changes(prior_entities, current_entities)
    end
  end

  defp entity_hash_changes(prior_entities, current_entities) do
    prior_entities
    |> Map.keys()
    |> Enum.filter(&Map.has_key?(current_entities, &1))
    |> Enum.sort()
    |> Enum.flat_map(&entity_hash_change(&1, prior_entities[&1], current_entities[&1]))
  end

  defp entity_hash_change(_key, hash, hash), do: []

  defp entity_hash_change({kind, name}, prior_hash, current_hash) do
    [%{"kind" => kind, "key" => name, "prior_sha256" => prior_hash, "current_sha256" => current_hash}]
  end

  defp entity_index(%{"entities" => entities}) when is_list(entities) do
    Map.new(entities, fn entity -> {{entity["kind"], entity["key"]}, entity["sha256"]} end)
  end

  defp entity_index(_digest), do: %{}

  defp digest_ref(digest) do
    %{
      "artifact_id" => digest["artifact_id"],
      "source" => digest["source"],
      "key_set_sha256" => digest["key_set_sha256"]
    }
  end

  defp unnamed_surface_delta(limitation) do
    empty = Map.new(@key_set_fields, &{&1, []})

    %{
      "schema_version" => 1,
      "report_type" => "authority_surface_delta",
      "named" => false,
      "added" => empty,
      "removed" => empty,
      "changed" => [],
      "limitations" => [limitation]
    }
  end

  defp validate_optional_member!(map, key, allowed, path) do
    if Map.has_key?(map, key), do: ensure_member!(map[key], allowed, key, path)
  end

  defp ensure_member!(value, allowed, field, path) do
    ensure!(value in allowed, "#{path}: invalid #{field} #{inspect(value)}")
  end

  defp ensure_string!(map, key, path) do
    ensure!(is_binary(map[key]) and map[key] != "", "#{path}: #{key} must be a non-empty string")
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: Mix.raise(message)
end
