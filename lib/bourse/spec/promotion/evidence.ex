defmodule Bourse.Spec.Promotion.Evidence do
  @moduledoc """
  Evidence-report contract for owned-spec promotion.

  Every item carries separate provider-owned semantic authority and Bourse
  compatibility-reference fields, explicit provenance, and binary verification.
  """

  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance.Derivation
  alias Bourse.Spec.Promotion
  alias Bourse.Spec.Promotion.Gap

  @report_version 2
  @verification_values ~w(verified unverified)
  @command_success 0
  @tail_line_count 10
  @required_item_fields ~w(id kind status semantic_authority compatibility_reference provenance verification)
  @contract_ids ~w(
    contract:public:success
    contract:public:error
    contract:authenticated:success
    contract:authenticated:error
    contract:official_semantics
    contract:integration_tests
    check:oracle_gate
    check:carve_registration
  )
  @observed_kinds ~w(live_api observed_traffic recorded_venue)
  @reality_manifests %{
    accepted: "test/fixtures/exchange_accepted_requests/_manifest.json",
    errors: "test/fixtures/recorded_errors/_manifest.json",
    public_accepted: "test/fixtures/public_accepted_requests/_manifest.json",
    responses: "test/fixtures/responses/_manifest.json"
  }

  @type gap :: Promotion.gap()

  @doc "Creates the candidate-status evidence report for a prepared spec."
  @spec template(String.t(), map(), [String.t()], [String.t()], map()) :: map()
  def template(venue, reference, methods, subjects, candidate) do
    items =
      Enum.map(subjects, &unresolved_item("decision:#{&1}", "interpretive_decision", reference)) ++
        Enum.map(methods, &unresolved_item("capability:#{&1}", "capability_decision", reference)) ++
        Enum.map(@contract_ids, &unresolved_item(&1, contract_kind(&1), reference))

    %{
      "schema_version" => @report_version,
      "venue" => venue,
      "status" => "candidate",
      "candidate_sha256" => Promotion.sha256(Promotion.encode!(candidate)),
      "reference" => reference,
      "trading_venue" => "unresolved",
      "items" => items,
      "gaps" => Enum.map(items, & &1["id"])
    }
  end

  @doc """
  Returns all evidence, provenance, artifact, and external-check gaps.

  `methods` must be the method inventory re-derived from the pinned Bourse
  reference (not from the report's capability items). Candidate support maps
  and report capability items are both checked against that inventory.
  """
  @spec gaps(map(), map(), [String.t()], [String.t()], keyword()) :: [gap()]
  def gaps(candidate, report, methods, subjects, opts) do
    venue = get_in(candidate, ["exchange", "id"])
    items = item_index(report)
    report_methods = capability_methods(report)

    report_shape_gaps(report, venue, candidate) ++
      item_shape_gaps(report) ++
      method_inventory_gaps(candidate, methods, report_methods) ++
      decision_gaps(items, candidate, methods, subjects) ++
      boundary_contract_gaps(items, report) ++
      integration_test_gaps(items, opts) ++
      carve_gaps(items, opts) ++
      oracle_gate_gaps(items, candidate, opts)
  end

  defp unresolved_item(id, kind, reference) do
    %{
      "id" => id,
      "kind" => kind,
      "status" => "unresolved",
      "semantic_authority" => nil,
      "compatibility_reference" => reference,
      "provenance" => [reference],
      "verification" => "unverified"
    }
  end

  defp contract_kind("check:" <> _rest), do: "mechanical_check"
  defp contract_kind(_id), do: "boundary_contract"

  defp report_shape_gaps(report, venue, candidate) do
    expected_digest = Promotion.sha256(Promotion.encode!(candidate))

    Enum.reject(
      [
        gap_unless(
          report["schema_version"] == @report_version,
          :report_schema_invalid,
          "evidence schema_version must be 2"
        ),
        gap_unless(report["venue"] == venue, :report_venue_mismatch, "evidence venue must match candidate exchange.id"),
        gap_unless(report["status"] == "candidate", :report_status_invalid, "evidence status must remain candidate"),
        gap_unless(
          report["candidate_sha256"] == expected_digest,
          :candidate_digest_mismatch,
          "candidate_sha256 does not match the candidate bytes"
        ),
        gap_unless(is_map(report["reference"]), :reference_provenance_missing, "pinned CCXT reference is missing"),
        gap_unless(is_list(report["items"]), :evidence_items_missing, "evidence items must be a list")
      ],
      &is_nil/1
    )
  end

  defp item_shape_gaps(%{"items" => items}) when is_list(items) do
    duplicate_gaps(items) ++ Enum.flat_map(items, &item_gaps/1)
  end

  defp item_shape_gaps(_report), do: []

  defp capability_methods(%{"items" => items}) when is_list(items) do
    items
    |> Enum.flat_map(fn
      %{"id" => "capability:" <> method} when method != "" -> [method]
      _item -> []
    end)
    |> Enum.sort()
  end

  defp capability_methods(_report), do: []

  defp method_inventory_gaps(candidate, reference_methods, report_methods) do
    support_methods = candidate |> get_in(["capabilities", "has"]) |> map_keys()
    endpoint_methods = candidate |> get_in(["endpoints", "unified"]) |> map_keys()

    candidate_match? =
      support_methods == reference_methods and endpoint_methods == reference_methods

    report_match? = report_methods == reference_methods

    candidate_gaps =
      if candidate_match? do
        []
      else
        [
          Gap.new(
            :method_inventory_mismatch,
            "candidate support maps must exactly preserve the prepared reference method inventory"
          )
        ]
      end

    report_gaps =
      if report_match? do
        []
      else
        [
          Gap.new(
            :method_inventory_reference_drift,
            "report capability inventory drifted from the pinned reference method inventory"
          )
        ]
      end

    candidate_gaps ++ report_gaps
  end

  defp map_keys(value) when is_map(value), do: value |> Map.keys() |> Enum.sort()
  defp map_keys(_value), do: []

  defp duplicate_gaps(items) do
    duplicates = items |> Enum.map(& &1["id"]) |> Enum.frequencies() |> Enum.filter(fn {_id, count} -> count > 1 end)

    Enum.map(duplicates, fn {id, _count} ->
      Gap.new(:duplicate_evidence_item, "evidence item #{inspect(id)} is duplicated", to_string(id))
    end)
  end

  defp item_gaps(item) when is_map(item) do
    missing = Enum.reject(@required_item_fields, &Map.has_key?(item, &1))
    id = to_string(item["id"] || "unknown")

    base =
      if missing == [] do
        []
      else
        [Gap.new(:evidence_item_incomplete, "missing fields: #{Enum.join(missing, ", ")}", id)]
      end

    base ++ authority_shape_gaps(item, id) ++ forbidden_claim_gaps(item, id)
  end

  defp item_gaps(_item), do: [Gap.new(:evidence_item_invalid, "every evidence item must be an object")]

  defp authority_shape_gaps(item, id) do
    semantic = item["semantic_authority"]
    compatibility = item["compatibility_reference"]
    provenance = item["provenance"]
    verification = item["verification"]

    Enum.reject(
      [
        gap_unless(
          is_nil(semantic) or
            match?(%{"kind" => "provider_owned", "reference" => reference} when is_binary(reference), semantic),
          :semantic_authority_invalid,
          "semantic_authority must be nil or a provider_owned reference",
          id
        ),
        gap_unless(
          is_nil(compatibility) or match?(%{"kind" => "ccxt"}, compatibility),
          :compatibility_reference_invalid,
          "compatibility_reference must be nil or explicitly kind=ccxt",
          id
        ),
        gap_unless(is_list(provenance) and provenance != [], :provenance_missing, "provenance must be non-empty", id),
        gap_unless(
          verification in @verification_values,
          :verification_invalid,
          "verification must be verified or unverified",
          id
        ),
        gap_unless(
          verification != "verified" or reality_verified?(item),
          :verified_evidence_incomplete,
          "verified evidence needs provider semantics and venue observation",
          id
        )
      ],
      &is_nil/1
    )
  end

  defp forbidden_claim_gaps(item, id) do
    forbidden = item |> nested_keys() |> Enum.filter(&(&1 == "oracle"))

    if forbidden == [] do
      []
    else
      [Gap.new(:ambiguous_evidence_claim, "bare oracle fields are forbidden", id)]
    end
  end

  defp nested_keys(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [key | nested_keys(value)] end)
  end

  defp nested_keys(list) when is_list(list), do: Enum.flat_map(list, &nested_keys/1)
  defp nested_keys(_value), do: []

  defp decision_gaps(items, candidate, methods, subjects) do
    decision_items = Enum.map(subjects, &{"decision:#{&1}", nil})
    support = get_in(candidate, ["capabilities", "has"]) || %{}
    capability_items = Enum.map(methods, &{"capability:#{&1}", Map.get(support, &1)})

    Enum.flat_map(decision_items ++ capability_items, &decision_gap(items, &1))
  end

  defp decision_gap(items, {id, declaration}) do
    case Map.get(items, id) do
      nil ->
        [Gap.new(:decision_evidence_missing, "required authoring decision is missing", id)]

      item ->
        required_status = if declaration == false, do: "unsupported", else: "authored"
        validate_decision_item(item, id, required_status)
    end
  end

  defp validate_decision_item(item, id, required_status) do
    if item["status"] == required_status and item["verification"] == "verified" and reality_verified?(item) do
      []
    else
      [
        Gap.new(
          :decision_not_provider_authoritative,
          "decision must be #{required_status} with verified provider semantics and venue observation",
          id
        )
      ]
    end
  end

  defp boundary_contract_gaps(items, report) do
    base =
      Enum.flat_map(@contract_ids, fn id ->
        required_contract_gap(items, id) ++ boundary_observation_gaps(items, id)
      end)

    trading =
      case report["trading_venue"] do
        true ->
          required_contract_gap(items, "contract:trading:lifecycle") ++ trading_lifecycle_gaps(items)

        false ->
          []

        _other ->
          [Gap.new(:trading_classification_unresolved, "trading_venue must be explicitly true or false")]
      end

    base ++ trading
  end

  defp required_contract_gap(items, id) do
    case Map.get(items, id) do
      %{"status" => "passed", "verification" => "verified"} = item ->
        if reality_verified?(item),
          do: [],
          else: [Gap.new(:boundary_contract_incomplete, "contract lacks verified provider evidence", id)]

      _item ->
        [Gap.new(:boundary_contract_incomplete, "required contract item has not passed", id)]
    end
  end

  defp boundary_observation_gaps(items, "contract:" <> rest = id) do
    cond do
      String.ends_with?(rest, ":success") -> boundary_outcome_gap(items, id, "success")
      String.ends_with?(rest, ":error") -> boundary_outcome_gap(items, id, "error")
      true -> []
    end
  end

  defp boundary_observation_gaps(_items, _id), do: []

  defp boundary_outcome_gap(items, id, expected) do
    case get_in(items, [id, "details", "outcome"]) do
      ^expected -> []
      _other -> [Gap.new(:boundary_observation_missing, "details.outcome must be #{expected}", id)]
    end
  end

  defp trading_lifecycle_gaps(items) do
    details = get_in(items, ["contract:trading:lifecycle", "details"]) || %{}
    lifecycle = details["lifecycle"]

    if details["safe"] == true and is_list(lifecycle) and Enum.all?(~w(create fetch cancel), &(&1 in lifecycle)) do
      []
    else
      [
        Gap.new(
          :trading_lifecycle_incomplete,
          "safe create/fetch/cancel lifecycle evidence is required",
          "contract:trading:lifecycle"
        )
      ]
    end
  end

  defp integration_test_gaps(items, opts) do
    with %{"details" => details} <- Map.get(items, "contract:integration_tests"),
         paths when is_list(paths) and paths != [] <- details["paths"],
         setup when is_map(setup) <- details["credential_setup"] do
      root = Keyword.get(opts, :root, File.cwd!())
      path_gaps = Enum.flat_map(paths, &integration_path_gaps(&1, root))
      path_gaps ++ credential_setup_gaps(setup)
    else
      _other ->
        [
          Gap.new(
            :integration_test_contract_invalid,
            "details must include test paths and credential_setup",
            "contract:integration_tests"
          )
        ]
    end
  end

  defp integration_path_gaps(path, root) do
    with {:ok, expanded_path} <- expand_within_root(path, root),
         {:ok, source} <- read_source(expanded_path) do
      requirements = ["@moduletag :integration", "@moduletag :network", "require_credentials!"]
      missing = Enum.reject(requirements, &String.contains?(source, &1))
      skip? = Regex.match?(~r/@(?:module)?tag\s+:skip/, source)

      Enum.reject(
        [
          gap_unless(
            missing == [],
            :integration_test_contract_invalid,
            "#{expanded_path} is missing #{Enum.join(missing, ", ")}"
          ),
          gap_unless(not skip?, :integration_test_silently_skips, "#{expanded_path} uses a skip tag")
        ],
        &is_nil/1
      )
    else
      {:error, reason} ->
        [Gap.new(:integration_test_missing, "cannot read #{inspect(path)}: #{inspect(reason)}")]
    end
  end

  defp expand_within_root(path, root) when is_binary(path) and is_binary(root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path, expanded_root)
    root_prefix = expanded_root <> if(String.ends_with?(expanded_root, "/"), do: "", else: "/")

    if expanded_path == expanded_root or String.starts_with?(expanded_path, root_prefix) do
      {:ok, expanded_path}
    else
      {:error, :outside_root}
    end
  end

  defp expand_within_root(_path, _root), do: {:error, :invalid_path}

  defp read_source(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, :eof)) do
      {:ok, source} when is_binary(source) -> {:ok, source}
      # IO.binread(device, :eof) yields :eof (not "") on an empty file.
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp credential_setup_gaps(setup) do
    variables = setup["environment_variables"]
    commands = setup["export_commands"]
    url = setup["credentials_url"]

    commands_cover_variables? =
      is_list(variables) and is_list(commands) and
        Enum.all?(variables, fn variable ->
          is_binary(variable) and Enum.any?(commands, &String.contains?(&1, "export #{variable}="))
        end)

    Enum.reject(
      [
        gap_unless(
          is_list(variables) and variables != [],
          :credential_setup_incomplete,
          "environment_variables are required"
        ),
        gap_unless(
          commands_cover_variables?,
          :credential_setup_incomplete,
          "exact export commands are required for every variable"
        ),
        gap_unless(is_binary(url) and url != "", :credential_setup_incomplete, "credentials_url is required")
      ],
      &is_nil/1
    )
  end

  defp carve_gaps(items, opts) do
    with %{"details" => %{"paths" => paths, "authority_manifest" => authority}} <-
           Map.get(items, "check:carve_registration"),
         true <- is_list(paths) and paths != [] and is_binary(authority) do
      root = Keyword.get(opts, :root, File.cwd!())
      missing = Enum.reject([authority | paths], &File.regular?(Path.expand(&1, root)))

      if missing == [] do
        []
      else
        [Gap.new(:carve_registration_missing, "missing: #{Enum.join(missing, ", ")}", "check:carve_registration")]
      end
    else
      _other ->
        [
          Gap.new(
            :carve_registration_missing,
            "carve paths and authority manifest are required",
            "check:carve_registration"
          )
        ]
    end
  end

  defp oracle_gate_gaps(items, candidate, opts) do
    with %{"details" => %{"command" => [executable | args], "critical_recordings" => recordings}} <-
           Map.get(items, "check:oracle_gate"),
         true <- oracle_gate_command?(executable, args),
         true <- is_list(recordings) do
      runner = Keyword.get(opts, :command_runner, &default_runner/3)
      root = Keyword.get(opts, :root, File.cwd!())

      critical_recording_gaps(candidate, recordings, root) ++
        run_oracle_gate(runner, executable, args, root)
    else
      _other ->
        [
          Gap.new(
            :oracle_gate_contract_missing,
            ~s(details must contain command ["mix", "ccxt.oracle_gate"] and critical_recordings),
            "check:oracle_gate"
          )
        ]
    end
  end

  defp run_oracle_gate(runner, executable, args, root) do
    case runner.(executable, args, root) do
      {_output, @command_success} ->
        []

      {output, status} ->
        [Gap.new(:oracle_gate_failed, "oracle gate exited #{status}: #{tail(output)}", "check:oracle_gate")]
    end
  end

  defp oracle_gate_command?("mix", ["ccxt.oracle_gate"]), do: true
  defp oracle_gate_command?(_executable, _args), do: false

  defp critical_recording_gaps(candidate, recordings, root) do
    expected =
      candidate
      |> Derivation.critical_slots()
      |> Map.new(&{&1.path, &1})

    indexed = Enum.group_by(recordings, &recording_slot/1)

    duplicate_gaps =
      indexed
      |> Enum.filter(fn {_slot, entries} -> length(entries) != 1 end)
      |> Enum.map(fn {slot, _entries} ->
        Gap.new(:critical_recording_duplicate, "critical slot must have exactly one recording registration", slot)
      end)

    missing_gaps =
      expected
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(indexed, &1))
      |> Enum.map(&Gap.new(:critical_recording_missing, "critical slot has no manifest-registered recording", &1))

    unknown_gaps =
      indexed
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(expected, &1))
      |> Enum.map(&Gap.new(:critical_recording_unknown, "recording names a non-critical slot", to_string(&1)))

    registration_gaps =
      Enum.flat_map(recordings, &recording_registration_gaps(&1, candidate, root, expected))

    duplicate_gaps ++ missing_gaps ++ unknown_gaps ++ registration_gaps
  end

  defp recording_slot(%{"slot" => slot}) when is_binary(slot), do: slot
  defp recording_slot(_recording), do: nil

  defp recording_registration_gaps(%{"slot" => slot, "manifest" => manifest, "path" => path}, candidate, root, expected)
       when is_binary(slot) and is_binary(manifest) and is_binary(path) do
    venue = get_in(candidate, ["exchange", "id"])
    rows = registered_rows(Path.expand(manifest, root), venue, path)
    expected_methods = expected |> Map.get(slot, %{}) |> Map.get(:expected_methods, [])

    cond do
      manifest not in manifests_for_slot(slot) ->
        [
          Gap.new(
            :critical_recording_wrong_manifest,
            "#{slot} must use #{Enum.join(manifests_for_slot(slot), " or ")}",
            slot
          )
        ]

      rows == [] ->
        [
          Gap.new(
            :critical_recording_unregistered,
            "#{path} is not registered for #{venue} in #{manifest}",
            slot
          )
        ]

      expected_methods != [] and not Enum.any?(rows, &registered_method?(&1, expected_methods)) ->
        expected = Enum.join(expected_methods, ", ")

        [
          Gap.new(
            :critical_recording_method_mismatch,
            "#{path} is registered for #{registered_methods(rows)}, " <>
              "not one of #{slot}'s expected method(s) #{expected}",
            slot
          )
        ]

      true ->
        []
    end
  end

  defp recording_registration_gaps(_recording, _candidate, _root, _expected) do
    [
      Gap.new(
        :critical_recording_invalid,
        "critical recordings require string slot, manifest, and path fields",
        "check:oracle_gate"
      )
    ]
  end

  defp manifests_for_slot("auth.sign_recipe." <> _rest),
    do: [@reality_manifests.accepted, @reality_manifests.public_accepted]

  defp manifests_for_slot("request_shape." <> _rest),
    do: [@reality_manifests.accepted, @reality_manifests.public_accepted]

  defp manifests_for_slot("normalization.field_maps." <> _rest), do: [@reality_manifests.responses]
  defp manifests_for_slot("markets.patterns." <> _rest), do: [@reality_manifests.responses]
  defp manifests_for_slot("errors.handle_errors." <> _rest), do: [@reality_manifests.errors]
  defp manifests_for_slot(_slot), do: []

  defp registered_rows(manifest_path, venue, fixture_path) do
    manifest = JsonDocument.decode_file!(manifest_path)
    rows = Map.get(manifest, "recordings", []) ++ Map.get(manifest, "goldens", [])
    Enum.filter(rows, &(&1["venue"] == venue and &1["path"] == fixture_path))
  rescue
    _error in [File.Error, Jason.DecodeError, ArgumentError] -> []
  end

  defp registered_method?(%{"method" => method}, expected_methods) when is_binary(method) do
    Derivation.js_method!(method) in expected_methods
  end

  defp registered_method?(_row, _expected_methods), do: false

  defp registered_methods(rows) do
    rows
    |> Enum.map(& &1["method"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Derivation.js_method!/1)
    |> Enum.uniq()
    |> case do
      [] -> "no method"
      methods -> Enum.join(methods, ", ")
    end
  end

  defp default_runner("mix", ["ccxt.oracle_gate"], root) do
    System.cmd("mix", ["ccxt.oracle_gate"], cd: root, stderr_to_stdout: true)
  end

  defp tail(output) when is_binary(output) do
    output |> String.split("\n") |> Enum.take(-@tail_line_count) |> Enum.join("\n")
  end

  defp tail(output), do: inspect(output)

  defp item_index(%{"items" => items}) when is_list(items) do
    Enum.reduce(items, %{}, fn
      %{"id" => id} = item, index -> Map.put(index, id, item)
      _item, index -> index
    end)
  end

  defp item_index(_report), do: %{}

  defp reality_verified?(item) do
    match?(%{"kind" => "provider_owned", "reference" => reference} when is_binary(reference), item["semantic_authority"]) and
      Enum.any?(item["provenance"] || [], &(is_map(&1) and &1["kind"] in @observed_kinds))
  end

  defp gap_unless(true, _code, _message), do: nil
  defp gap_unless(false, code, message), do: Gap.new(code, message)
  defp gap_unless(true, _code, _message, _item_id), do: nil
  defp gap_unless(false, code, message, item_id), do: Gap.new(code, message, item_id)
end
