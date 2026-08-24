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
    validate_cases!()
    validate_runtime_surface!()
    :ok
  end

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
