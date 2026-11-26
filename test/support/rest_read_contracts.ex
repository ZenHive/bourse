defmodule Bourse.Test.RestReadContracts do
  @moduledoc """
  Loads and validates the REST-read execution inventory.

  The inventory mirrors the client's callable REST-read surface: every runtime
  read branch under each venue's provider product prefixes appears exactly
  once, and `validate!/0` keeps that mirror locked so a new read branch cannot
  ship without a live execution. What the lane proves is that our client can
  call every one of its read branches against the venue's live host and parse
  what comes back; the meaning of each field and error is pinned per venue to
  provider-owned authority sources. Role-based semantic coverage lives in the
  journey suites under `test/live/journeys/`.
  """

  alias Bourse.JsonDocument
  alias Bourse.Registry
  alias Bourse.Unified
  alias Bourse.UnifiedMethod

  @policy_path "priv/venues/rest_read_contracts_policy.json"
  @option_requirements ~w(listed quoted traded)
  @option_symbol ~r/^[^\/]+\/[^:]+:[^-]+-\d{6}-[0-9.]+-[CP]$/
  @external_resource @policy_path
  @runtime_venues ~w(
    alpaca
    binance
    binancecoinm
    binanceusdm
    bybit
    coinbaseexchange
    deribit
    derive
    hyperliquid
    lighter
    okx
  )

  for venue <- @runtime_venues do
    @external_resource "priv/venues/#{venue}/authority/rest_read_contract.json"
  end

  @typedoc "One provider operation branch exercised by the live lane."
  @type contract_case :: %{
          required(String.t()) => term()
        }

  @doc """
  Returns the REST-read execution inventory.

  The inventory is stored venue-first: shared policy keys in
  `priv/venues/rest_read_contracts_policy.json`, one contract per venue under
  `priv/venues/<venue>/authority/rest_read_contract.json`. They are merged here into
  the single document every validation below reads.
  """
  @spec inventory() :: map()
  def inventory do
    venues =
      Map.new(@runtime_venues, fn venue ->
        {venue, JsonDocument.decode_file!(venue_contract_path(venue))}
      end)

    @policy_path
    |> JsonDocument.decode_file!()
    |> Map.put("venues", venues)
  end

  @doc "Returns the shared inventory-policy path used by the canonical runner."
  @spec inventory_path() :: String.t()
  def inventory_path, do: @policy_path

  @doc "Returns one venue's REST-read contract path."
  @spec venue_contract_path(String.t()) :: String.t()
  def venue_contract_path(venue) when is_binary(venue) do
    Path.join(["priv/venues", venue, "authority", "rest_read_contract.json"])
  end

  @doc "Returns the provider inventory's venue IDs."
  @spec venues() :: [String.t()]
  def venues do
    inventory()
    |> Map.fetch!("venues")
    |> Map.keys()
    |> Enum.sort()
  end

  @doc "Expands each inventoried provider branch into one executable case."
  @spec cases() :: [contract_case()]
  def cases do
    Enum.flat_map(inventory()["venues"], fn {venue, venue_contract} ->
      contract_context = Map.drop(venue_contract, ["operations", "error_cases"])
      expand_venue_cases(venue, venue_contract, contract_context)
    end)
  end

  @doc "Returns every executable case for one venue."
  @spec cases_for(String.t() | atom()) :: [contract_case()]
  def cases_for(venue) do
    venue = to_string(venue)
    Enum.filter(cases(), &(&1["venue"] == venue))
  end

  @doc "Returns the independent inventory denominator."
  @spec denominator() :: non_neg_integer()
  def denominator, do: length(cases())

  @doc "Returns one venue's independent inventory denominator."
  @spec denominator(String.t() | atom()) :: non_neg_integer()
  def denominator(venue), do: length(cases_for(venue))

  @doc "Validates provider provenance, case uniqueness, and runtime coverage."
  @spec validate!() :: :ok
  def validate! do
    document = inventory()
    ensure!(document["schema_version"] == 2, "unsupported REST-read inventory schema")

    ensure!(
      document["inventory_basis"] == "client_read_surface",
      "inventory basis must name the client read surface it mirrors"
    )

    ensure!(venues() == @runtime_venues, "REST-read inventory must cover all eleven runtime venues")
    validate_sources!(document)
    Enum.each(document["venues"], fn {venue, contract} -> validate_option_selection!(venue, contract) end)
    validate_cases!()
    validate_runtime_surface!()
    :ok
  end

  @doc """
  Validates a success case's optional `field_values` declaration.

  Absent means no value constraint. Present must be a non-empty map from field
  names to non-empty lists of allowed values; any other shape raises instead of
  silently constraining nothing.
  """
  @spec validate_field_values!(map()) :: :ok
  def validate_field_values!(%{"success" => success} = contract_case) when is_map(success) do
    case Map.fetch(success, "field_values") do
      :error ->
        :ok

      {:ok, field_values} ->
        ensure!(
          is_map(field_values) and map_size(field_values) > 0 and Enum.all?(field_values, &allowed_values?/1),
          "#{contract_case["id"]}: field_values must map field names to non-empty lists of allowed values, " <>
            "got #{inspect(field_values)}"
        )
    end
  end

  @doc """
  Validates how a venue contract resolves option instruments.

  Option instruments expire, so a contract never names one: the `symbols` map
  carries no `option` slot, and a value there — a swap or spot symbol, or a
  literal strike that would go stale — is rejected. Every option branch that
  reads one instrument declares `option_instrument`, the state the read needs
  that instrument to have right now:

    * `listed` — an active option market (greeks, chains, currency-level stats)
    * `quoted` — a two-sided book (ticker reads)
    * `traded` — 24-hour volume (trade tapes)

  Any requirement beyond `listed` is resolved from the venue's own live data
  through `option_selection`, a unified read plus its options, which the venue
  contract must then declare.
  """
  @spec validate_option_selection!(String.t(), map()) :: :ok
  def validate_option_selection!(venue, contract) do
    validate_option_slot!(venue, get_in(contract, ["symbols", "option"]))

    requirements =
      Enum.flat_map(contract["operations"], fn operation ->
        Enum.map(operation["branches"], &validate_option_requirement!(venue, operation, &1))
      end)

    if Enum.any?(requirements, &(&1 not in [nil, "listed"])) do
      validate_selection_source!(venue, contract["option_selection"])
    end

    :ok
  end

  @doc "Returns true when `symbol` is a unified option symbol (`BASE/QUOTE:SETTLE-YYMMDD-STRIKE-C|P`)."
  @spec option_symbol?(term()) :: boolean()
  def option_symbol?(symbol) when is_binary(symbol), do: Regex.match?(@option_symbol, symbol)
  def option_symbol?(_symbol), do: false

  defp validate_option_slot!(_venue, nil), do: :ok

  defp validate_option_slot!(venue, symbol) do
    if option_symbol?(symbol) do
      raise ArgumentError,
            "#{venue}: symbols.option names the literal option #{inspect(symbol)}; option instruments expire, " <>
              "so declare option_instrument on the branch and let the lane select one from live venue data"
    else
      raise ArgumentError,
            "#{venue}: symbols.option names #{inspect(symbol)}, which is not an option symbol; " <>
              "remove the slot and declare option_instrument on each option branch"
    end
  end

  defp validate_option_requirement!(venue, operation, branch) do
    requirement = branch["option_instrument"]
    id = "#{venue}.#{operation["method"]}.#{branch["provider_operation"]}"

    if branch["market_kind"] == "option" and reads_one_instrument?(operation, branch) do
      ensure!(
        requirement in @option_requirements,
        "#{id}: option branch must declare option_instrument as one of #{inspect(@option_requirements)}, " <>
          "got #{inspect(requirement)}"
      )
    else
      ensure!(is_nil(requirement), "#{id}: option_instrument is only meaningful on an option branch that takes a symbol")
    end

    requirement
  end

  defp reads_one_instrument?(operation, branch) do
    Enum.any?(operation["arguments"] ++ (branch["options"] || []), &(&1["strategy"] == "market_symbol"))
  end

  defp validate_selection_source!(venue, %{"source_method" => method, "options" => options})
       when is_binary(method) and is_list(options) do
    ensure!(
      Enum.all?(options, &(is_map(&1) and is_binary(&1["name"]) and is_binary(&1["strategy"]))),
      "#{venue}: option_selection options must be named strategies"
    )
  end

  defp validate_selection_source!(venue, other) do
    raise ArgumentError,
          "#{venue}: option branches need a quoted or traded instrument, so the contract must declare " <>
            "option_selection with a source_method and options, got #{inspect(other)}"
  end

  defp allowed_values?({field, allowed}), do: is_binary(field) and field != "" and is_list(allowed) and allowed != []

  defp validate_sources!(document) do
    Enum.each(document["venues"], fn {venue, contract} ->
      sources = contract["authority_sources"]
      ensure!(is_list(sources) and sources != [], "#{venue}: no provider-owned authority source")
      manifest = JsonDocument.decode_file!("priv/venues/#{venue}/authority/manifest.json")
      artifacts = Map.new(manifest["artifacts"], &{&1["id"], &1})

      Enum.each(sources, fn source ->
        artifact = artifacts[source["id"]]
        ensure!(is_map(artifact), "#{venue}: unknown authority artifact #{inspect(source["id"])}")
        ensure!(artifact["sha256"] == source["sha256"], "#{venue}: authority pin drifted for #{source["id"]}")

        ensure!(
          get_in(artifact, ["authority", "semantic_authority"]) == true,
          "#{venue}: #{source["id"]} is not semantic authority"
        )
      end)

      source_ids = MapSet.new(sources, & &1["id"])

      Enum.each(contract["operations"], fn operation ->
        ensure!(
          MapSet.subset?(MapSet.new(operation["authority_source_ids"]), source_ids),
          "#{venue}.#{operation["method"]}: operation cites an unknown authority source"
        )
      end)

      Enum.each(contract["error_cases"], fn error_case ->
        ensure!(
          MapSet.member?(source_ids, error_case["authority_source_id"]),
          "#{error_case["id"]}: error case cites an unknown authority source"
        )
      end)
    end)
  end

  defp validate_cases! do
    expanded = cases()
    ids = Enum.map(expanded, & &1["id"])
    ensure!(expanded != [], "REST-read inventory is empty")
    ensure!(length(ids) == MapSet.size(MapSet.new(ids)), "REST-read inventory has duplicate branch IDs")

    expanded
    |> Enum.filter(&(&1["kind"] == "success"))
    |> Enum.each(fn contract_case ->
      ensure!(contract_case["http_method"] in ~w(GET POST), "#{contract_case["id"]}: read uses unsafe verb")
      ensure!(is_binary(contract_case["path"]), "#{contract_case["id"]}: provider path missing")
      ensure!(is_map(contract_case["success"]), "#{contract_case["id"]}: success meaning missing")
      ensure!(is_list(contract_case["arguments"]), "#{contract_case["id"]}: argument data missing")
      validate_field_values!(contract_case)
    end)

    expanded
    |> Enum.filter(&(&1["kind"] == "error"))
    |> Enum.each(fn contract_case ->
      ensure!(is_map(contract_case["expected_error"]), "#{contract_case["id"]}: error meaning missing")
      ensure!(is_list(contract_case["arguments"]), "#{contract_case["id"]}: argument data missing")
    end)
  end

  defp validate_runtime_surface! do
    definitions = unified_read_definitions()
    read_methods = Map.new(definitions, fn {_js_name, {method, _params}} -> {method, true} end)

    Enum.each(inventory()["venues"], fn {venue, venue_contract} ->
      validate_venue_runtime!(venue, venue_contract, definitions, read_methods)
    end)
  end

  defp unified_read_definitions do
    Unified.method_defs()
    |> Enum.filter(fn {_method, js_name, _params, _description} -> String.starts_with?(js_name, "fetch") end)
    |> Map.new(fn {method, js_name, params, _description} -> {js_name, {method, params}} end)
  end

  defp validate_venue_runtime!(venue, venue_contract, definitions, read_methods) do
    prefixes = venue_contract["provider_operation_prefixes"]
    ensure!(is_list(prefixes) and prefixes != [], "#{venue}: provider operation prefixes missing")
    Enum.each(venue_contract["operations"], &validate_operation_surface!(venue, &1, definitions, prefixes))

    inventoried = inventoried_provider_operations(venue_contract["operations"], definitions)
    runtime = native_runtime_operations(venue, prefixes, read_methods)

    ensure!(
      inventoried == runtime,
      "#{venue}: provider-prefix REST-read surface drifted from inventory"
    )
  end

  defp validate_operation_surface!(venue, operation, definitions, prefixes) do
    {_method, params} = Map.fetch!(definitions, operation["method"])

    ensure!(
      Enum.map(operation["arguments"], & &1["name"]) == Enum.map(params, &Atom.to_string/1),
      "#{venue}.#{operation["method"]}: argument contract drift"
    )

    Enum.each(operation["branches"], fn branch ->
      ensure!(
        prefix_match?(branch["provider_operation"], prefixes),
        "#{venue}.#{operation["method"]}: #{branch["provider_operation"]} is outside the provider product"
      )
    end)
  end

  defp inventoried_provider_operations(operations, definitions) do
    operations
    |> Enum.flat_map(fn operation ->
      {method, _params} = Map.fetch!(definitions, operation["method"])
      Enum.map(operation["branches"], &{method, &1["provider_operation"]})
    end)
    |> Enum.sort()
  end

  defp native_runtime_operations(venue, prefixes, read_methods) do
    venue
    |> Registry.module_for()
    |> then(& &1.__unified_endpoints__())
    |> Enum.filter(fn {method, _branches} -> Map.has_key?(read_methods, method) end)
    |> Enum.flat_map(&provider_operations_for_method/1)
    |> Enum.filter(fn {_method, provider_operation} -> prefix_match?(provider_operation, prefixes) end)
    |> Enum.sort()
  end

  defp provider_operations_for_method({method, branches}) do
    Enum.map(branches, fn config ->
      {method, UnifiedMethod.endpoint_config_to_js_name(config.sections, config.method, config.path)}
    end)
  end

  defp expand_venue_cases(venue, venue_contract, contract_context) do
    success_cases =
      Enum.flat_map(venue_contract["operations"], &expand_operation_cases(venue, &1, contract_context))

    error_cases =
      Enum.map(venue_contract["error_cases"], fn error_case ->
        error_case
        |> Map.put("venue", venue)
        |> Map.put("venue_contract", contract_context)
      end)

    success_cases ++ error_cases
  end

  defp expand_operation_cases(venue, operation, contract_context) do
    Enum.map(operation["branches"], &expand_success_case(venue, operation, &1, contract_context))
  end

  defp expand_success_case(venue, operation, branch, contract_context) do
    endpoint_index = runtime_endpoint_index!(venue, operation["method"], branch["provider_operation"])

    operation
    |> Map.delete("branches")
    |> Map.merge(branch)
    |> Map.put("id", success_case_id(venue, operation, branch, endpoint_index))
    |> Map.put("kind", "success")
    |> Map.put("endpoint_index", endpoint_index)
    |> Map.put("venue", venue)
    |> Map.put("venue_contract", contract_context)
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)

  defp prefix_match?(provider_operation, prefixes) when is_binary(provider_operation) do
    Enum.any?(prefixes, &prefixed_by?(provider_operation, &1))
  end

  defp prefixed_by?(operation, prefix) do
    String.starts_with?(operation, prefix) and suffix_starts_upper?(operation, prefix)
  end

  defp suffix_starts_upper?(operation, prefix) when byte_size(operation) == byte_size(prefix), do: true

  defp suffix_starts_upper?(operation, prefix) do
    size = byte_size(prefix)
    <<_skip::binary-size(^size), char, _rest::binary>> = operation
    char >= ?A and char <= ?Z
  end

  defp runtime_endpoint_index!(venue, js_name, provider_operation) do
    method = Unified.method_atom_for_js_name(js_name)
    ensure!(is_atom(method), "#{venue}: unknown unified method #{inspect(js_name)}")

    configs = Registry.module_for(venue).__unified_endpoints__()[method]

    index =
      Enum.find_index(configs, fn config ->
        UnifiedMethod.endpoint_config_to_js_name(config.sections, config.method, config.path) ==
          provider_operation
      end)

    ensure!(
      is_integer(index),
      "#{venue}.#{js_name}: #{provider_operation} is not a runtime endpoint"
    )

    index
  end

  defp success_case_id(venue, operation, branch, endpoint_index) do
    Enum.join([venue, operation["method"], endpoint_index, branch["provider_operation"]], ":")
  end
end
