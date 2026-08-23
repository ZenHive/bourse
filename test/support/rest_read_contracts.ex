defmodule Bourse.Test.RestReadContracts do
  @moduledoc """
  Loads and validates the provider-owned REST-read contract inventory.

  The inventory is the denominator. Runtime endpoint metadata is consulted only
  by `validate!/0` to make a drift between the independent contract and the
  callable client surface fail loudly.
  """

  alias Bourse.Exchange
  alias Bourse.JsonDocument
  alias Bourse.Registry
  alias Bourse.Unified
  alias Bourse.UnifiedMethod

  @inventory_path "priv/authority/rest-read-contracts.json"
  @external_resource @inventory_path
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

  @typedoc "One provider operation branch exercised by the live lane."
  @type contract_case :: %{
          required(String.t()) => term()
        }

  @doc "Returns the provider-owned REST-read inventory."
  @spec inventory() :: map()
  def inventory, do: JsonDocument.decode_file!(@inventory_path)

  @doc "Returns the inventory path used by the canonical runner."
  @spec inventory_path() :: String.t()
  def inventory_path, do: @inventory_path

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

      success_cases =
        for operation <- venue_contract["operations"],
            {branch, endpoint_index} <- Enum.with_index(operation["branches"]) do
          operation
          |> Map.delete("branches")
          |> Map.merge(branch)
          |> Map.put("id", success_case_id(venue, operation, branch, endpoint_index))
          |> Map.put("kind", "success")
          |> Map.put("endpoint_index", endpoint_index)
          |> Map.put("venue", venue)
          |> Map.put("venue_contract", contract_context)
        end

      error_cases =
        Enum.map(venue_contract["error_cases"], fn error_case ->
          error_case
          |> Map.put("venue", venue)
          |> Map.put("venue_contract", contract_context)
        end)

      success_cases ++ error_cases
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

  @doc "Validates provider provenance, case uniqueness, and runtime coverage."
  @spec validate!() :: :ok
  def validate! do
    document = inventory()
    ensure!(document["schema_version"] == 1, "unsupported REST-read inventory schema")
    ensure!(document["inventory_basis"] == "provider_owned_contracts", "inventory is not provider-owned")
    ensure!(document["runtime_specs_are_not_authority"] == true, "runtime specs must not be inventory authority")
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
      manifest = JsonDocument.decode_file!("priv/authority/#{venue}/manifest.json")
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
    definitions =
      Map.new(Unified.method_defs(), fn {method, js_name, params, _description} ->
        {js_name, {method, params}}
      end)

    read_methods =
      definitions
      |> Enum.filter(fn {js_name, _definition} -> String.starts_with?(js_name, "fetch") end)
      |> Map.new(fn {_js_name, {method, _params}} -> {method, true} end)

    Enum.each(inventory()["venues"], fn {venue, venue_contract} ->
      module = Registry.module_for(venue)
      runtime = module.__unified_endpoints__()

      inventoried =
        Map.new(venue_contract["operations"], fn operation ->
          {method, params} = Map.fetch!(definitions, operation["method"])

          ensure!(
            Enum.map(operation["arguments"], & &1["name"]) == Enum.map(params, &Atom.to_string/1),
            "#{venue}.#{operation["method"]}: argument contract drift"
          )

          {method, operation}
        end)

      runtime_reads =
        runtime
        |> Map.new(fn {method, branches} -> {method, branches} end)
        |> Map.take(Map.keys(read_methods))

      ensure!(
        Enum.sort(Map.keys(runtime_reads)) == Enum.sort(Map.keys(inventoried)),
        "#{venue}: runtime read surface differs from provider inventory"
      )

      Enum.each(inventoried, fn {method, operation} ->
        runtime_operations =
          runtime
          |> Map.fetch!(method)
          |> Enum.map(&UnifiedMethod.endpoint_config_to_js_name(&1.sections, &1.method, &1.path))

        provider_operations = Enum.map(operation["branches"], & &1["provider_operation"])
        ensure!(runtime_operations == provider_operations, "#{venue}.#{operation["method"]}: provider branch drift")
      end)
    end)
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)

  defp success_case_id(venue, operation, branch, endpoint_index) do
    Enum.join([venue, operation["method"], endpoint_index, branch["provider_operation"]], ":")
  end
end

defmodule Bourse.Test.RestReadContractScenario do
  @moduledoc """
  Executes and asserts provider-live REST-read scenarios.

  All judgments are supplied by the inventory. These functions only resolve
  its mechanical strategies, perform real Bourse calls, and enforce the stated
  success and error meanings.
  """

  import ExUnit.Assertions

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.RawResponse
  alias Bourse.Test.RestReadContracts
  alias Bourse.Testnet
  alias Bourse.Unified

  @auth_deadline_seconds 300
  @recent_time_tolerance_ms 300_000

  @typedoc "Live state shared by all provider branches for one venue."
  @type context :: %{
          exchange: Exchange.t(),
          markets: [map()],
          venue: String.t(),
          venue_contract: map()
        }

  @doc "Builds the live venue context used by that venue's contract cases."
  @spec setup_venue!(String.t() | atom()) :: context()
  def setup_venue!(venue) do
    venue = to_string(venue)
    venue_contract = RestReadContracts.inventory()["venues"][venue]
    exchange = live_exchange!(venue, venue_contract)

    %{exchange: exchange, markets: [], venue: venue, venue_contract: venue_contract}
  end

  @doc "Performs one inventoried provider branch and asserts its domain meaning."
  @spec assert_case!(map(), context()) :: :ok
  def assert_case!(%{"kind" => "error"} = contract_case, context) do
    method = existing_method_atom!(contract_case["method"])
    {args, resolved} = resolve_arguments!(contract_case, context)
    opts = case_options(contract_case, context, resolved)
    result = apply(Bourse, method, [context.exchange | args] ++ [opts])
    assert_observed_error!(result, contract_case)
  end

  def assert_case!(contract_case, context) do
    method = existing_method_atom!(contract_case["method"])
    {args, resolved} = resolve_arguments!(contract_case, context)
    opts = case_options(contract_case, context, resolved)
    result = apply(Bourse, method, [context.exchange | args] ++ [opts])
    assert_success!(contract_case, result, resolved)
  rescue
    error in [ExUnit.AssertionError, ArgumentError] ->
      reraise error, __STACKTRACE__

    error ->
      flunk(
        "#{contract_case["id"]} raised before proving provider semantics: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end

  defp live_exchange!("coinbaseexchange", _contract), do: Exchange.new!(:coinbaseexchange)

  defp live_exchange!(venue, contract) do
    venue_atom = String.to_existing_atom(venue)

    case Testnet.creds(venue_atom, :default) do
      %Bourse.Credentials{} = credentials ->
        Exchange.new!(venue_atom, credentials: credentials, sandbox: true)

      nil ->
        flunk(missing_credentials_message(venue, contract["credentials"]))
    end
  end

  defp missing_credentials_message(venue, credentials) do
    exports = Enum.map_join(credentials["exports"], "\n", &~s(  export #{&1}="your_value"))

    """
    Missing provider-live credentials for #{venue}.

    Set these environment variables and re-run `mix ccxt.verify_rest_read_contracts`:
    #{exports}

    Get credentials at: #{credentials["url"]}
    """
  end

  defp assert_observed_error!(result, contract_case) do
    contract = contract_case["expected_error"]

    case result do
      {:error, %Error{} = error} ->
        assert Atom.to_string(error.type) == contract["type"], error_message(contract_case, error)
        assert error.code == contract["code"], error_message(contract_case, error)
        assert error.message =~ contract["message_contains"], error_message(contract_case, error)
        :ok

      other ->
        flunk("#{contract_case["id"]}: expected provider error #{inspect(contract)}, got #{inspect(other)}")
    end
  end

  defp error_message(contract_case, actual) do
    "#{contract_case["id"]}: provider error meaning drifted; " <>
      "expected #{inspect(contract_case["expected_error"])}, got #{inspect(actual)}"
  end

  defp resolve_arguments!(contract_case, context) do
    resolved =
      Map.new(contract_case["arguments"], fn argument ->
        {argument["name"], resolve_argument!(argument, contract_case, context)}
      end)

    args = Enum.map(contract_case["arguments"], &Map.fetch!(resolved, &1["name"]))
    {args, resolved}
  end

  defp resolve_argument!(%{"strategy" => "market_symbol"}, contract_case, context),
    do: market_symbol!(context, contract_case["market_kind"])

  defp resolve_argument!(%{"strategy" => "market_type"}, contract_case, _context), do: contract_case["market_kind"]

  defp resolve_argument!(%{"strategy" => "market_sub_type"}, contract_case, _context),
    do: if(contract_case["market_kind"] == "inverse", do: "inverse", else: "linear")

  defp resolve_argument!(%{"strategy" => "venue_currency"}, _contract_case, context),
    do: context.venue_contract["currency"]

  defp resolve_argument!(%{"strategy" => "credential_uid"}, _contract_case, context), do: context.exchange.credentials.uid

  defp resolve_argument!(%{"strategy" => "literal", "value" => value}, _contract_case, _context), do: value

  defp resolve_argument!(%{"strategy" => "resource"} = argument, contract_case, context),
    do: resource_value!(argument, contract_case, context)

  defp resolve_argument!(argument, contract_case, _context) do
    flunk("#{contract_case["id"]}: unknown argument strategy #{inspect(argument)}")
  end

  defp case_options(contract_case, context, resolved) do
    options =
      Enum.map(contract_case["options"], fn option ->
        {String.to_atom(option["name"]), option_value!(option, contract_case, context)}
      end)

    options
    |> Keyword.put(:endpoint_index, contract_case["endpoint_index"])
    |> maybe_put_resolved_symbol(resolved)
  end

  defp option_value!(%{"strategy" => "market_symbol"}, contract_case, context),
    do: market_symbol!(context, contract_case["market_kind"])

  defp option_value!(%{"strategy" => "market_type"}, contract_case, _context), do: contract_case["market_kind"]
  defp option_value!(%{"strategy" => "venue_currency"}, _contract_case, context), do: context.venue_contract["currency"]
  defp option_value!(%{"strategy" => "credential_uid"}, _contract_case, context), do: credential_uid!(context)

  defp option_value!(%{"strategy" => "credential_api_key"}, _contract_case, context),
    do: context.exchange.credentials.api_key

  defp option_value!(%{"strategy" => "auth_deadline"}, _contract_case, _context),
    do: System.system_time(:second) + @auth_deadline_seconds

  defp option_value!(%{"strategy" => "current_time_ms"}, _contract_case, _context), do: System.system_time(:millisecond)
  defp option_value!(%{"strategy" => "literal", "value" => value}, _contract_case, _context), do: value

  defp maybe_put_resolved_symbol(options, %{"symbol" => symbol}), do: Keyword.put_new(options, :symbol, symbol)
  defp maybe_put_resolved_symbol(options, _resolved), do: options

  defp credential_uid!(%{exchange: %{credentials: %{uid: uid}}}) when is_binary(uid), do: String.to_integer(uid)

  defp credential_uid!(context),
    do: flunk("#{context.venue}: provider contract requires a numeric credential account index")

  defp market_symbol!(%{markets: []} = context, kind) do
    context.venue_contract["symbols"][kind] || context.venue_contract["symbols"]["spot"] ||
      flunk("#{context.venue}: provider contract has no live symbol strategy")
  end

  defp market_symbol!(context, kind) do
    candidates = Enum.filter(context.markets, &market_kind?(&1, kind))
    preferred = context.venue_contract["symbols"][kind]

    market =
      Enum.find(candidates, &(&1.symbol == preferred and &1.active != false)) ||
        Enum.find(candidates, &(&1.active != false and String.starts_with?(&1.symbol || "", "BTC"))) ||
        Enum.find(candidates, &(&1.active != false))

    if market,
      do: market.symbol,
      else: flunk("#{context.venue}: no active #{kind} market can exercise the provider branch")
  end

  defp market_kind?(market, "spot"), do: market.spot == true or market.type == "spot"
  defp market_kind?(market, "option"), do: market.option == true or market.type in ["option", "option_combo"]
  defp market_kind?(market, "inverse"), do: market.inverse == true and (market.swap == true or market.future == true)
  defp market_kind?(market, "linear"), do: market.linear == true and (market.swap == true or market.future == true)

  defp resource_value!(argument, contract_case, context) do
    source = existing_method_atom!(argument["source_method"])
    source_result = apply(Bourse, source, [context.exchange, resource_source_options(contract_case, context)])
    rows = successful_rows!(source_result, contract_case, argument["source_method"])
    collection? = argument["collection"] == true

    value = Enum.find_value(rows, &field_value(&1, argument["field"]))

    case value do
      nil ->
        flunk(
          "#{contract_case["id"]}: provider account state has no #{argument["field"]} from #{argument["source_method"]}"
        )

      value when collection? ->
        [value]

      value ->
        value
    end
  end

  defp resource_source_options(contract_case, context) do
    [
      symbol: market_symbol!(context, contract_case["market_kind"]),
      market_type: contract_case["market_kind"]
    ]
  end

  defp successful_rows!({:ok, %RawResponse{payload: payload}}, contract_case, source),
    do: payload_rows!(payload, contract_case, source)

  defp successful_rows!({:ok, rows}, _contract_case, _source) when is_list(rows), do: rows
  defp successful_rows!({:ok, rows}, _contract_case, _source) when is_map(rows), do: Map.values(rows)

  defp successful_rows!({:error, reason}, contract_case, source),
    do: flunk("#{contract_case["id"]}: resource source #{source} failed: #{format_reason(reason)}")

  defp successful_rows!(other, contract_case, source),
    do: flunk("#{contract_case["id"]}: resource source #{source} returned #{inspect(other)}")

  defp payload_rows!(payload, contract_case, source) do
    rows = find_first_collection(payload)
    if rows == [], do: flunk("#{contract_case["id"]}: provider account state for #{source} is empty"), else: rows
  end

  defp find_first_collection(value) when is_list(value), do: value

  defp find_first_collection(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.find_value([], fn child ->
      rows = find_first_collection(child)
      if rows == [], do: nil, else: rows
    end)
  end

  defp find_first_collection(_value), do: []

  defp field_value(%_{} = struct, field), do: maybe_atom_field(struct, field)
  defp field_value(map, field) when is_map(map), do: Map.get(map, field) || maybe_atom_field(map, field)
  defp field_value(_value, _field), do: nil

  defp maybe_atom_field(map, field) do
    field_atom = field |> Macro.underscore() |> String.to_existing_atom()
    Map.get(map, field_atom)
  rescue
    ArgumentError -> nil
  end

  defp assert_success!(contract_case, {:ok, value}, resolved) do
    assert_representation!(contract_case, value)
    assert_meaning!(contract_case, value, resolved)
    :ok
  end

  defp assert_success!(contract_case, {:error, reason}, _resolved),
    do: flunk("#{contract_case["id"]}: live provider success failed: #{format_reason(reason)}")

  defp assert_success!(contract_case, other, _resolved),
    do: flunk("#{contract_case["id"]}: live provider returned #{inspect(other)}")

  defp assert_representation!(%{"success" => %{"representation" => "raw"}} = contract_case, value) do
    assert %RawResponse{venue: venue, method: method, payload: payload} = value
    assert venue == contract_case["venue"]
    assert method == contract_case["method"]
    refute is_nil(payload), "#{contract_case["id"]}: provider payload is nil"
  end

  defp assert_representation!(contract_case, %RawResponse{}),
    do:
      flunk(
        "#{contract_case["id"]}: expected provider-defined #{contract_case["success_contract"]}, got labelled raw data"
      )

  defp assert_representation!(%{"success" => %{"representation" => "positional_rows"} = success} = contract_case, value) do
    assert is_list(value), "#{contract_case["id"]}: expected positional provider rows"
    assert value != [], "#{contract_case["id"]}: provider returned no rows"

    assert Enum.all?(value, &(is_list(&1) and length(&1) >= success["minimum_length"])),
           "#{contract_case["id"]}: provider returned an invalid positional row"
  end

  defp assert_representation!(contract_case, value) do
    success = contract_case["success"]
    module = module_from_data(success["module"])

    case success["collection"] do
      "single" ->
        assert is_struct(value, module), "#{contract_case["id"]}: expected #{inspect(module)}, got #{inspect(value)}"

      collection when collection in ["list", "map"] ->
        assert_collection!(contract_case, value, module, collection)

      "scalar" ->
        assert_scalar!(contract_case, value, success["scalar"])
    end
  end

  defp assert_collection!(contract_case, value, module, "list") do
    assert is_list(value), "#{contract_case["id"]}: expected a provider list, got #{inspect(value)}"
    assert value != [], "#{contract_case["id"]}: provider account/market state did not exercise the read"

    assert Enum.all?(value, &is_struct(&1, module)),
           "#{contract_case["id"]}: collection contains a non-#{inspect(module)} value"
  end

  defp assert_collection!(contract_case, value, module, "map") do
    assert is_map(value), "#{contract_case["id"]}: expected a provider map, got #{inspect(value)}"
    assert map_size(value) > 0, "#{contract_case["id"]}: provider account/market state did not exercise the read"

    assert Enum.all?(Map.values(value), &is_struct(&1, module)),
           "#{contract_case["id"]}: map contains a non-#{inspect(module)} value"
  end

  defp assert_scalar!(contract_case, value, "integer") do
    assert is_integer(value), "#{contract_case["id"]}: expected integer semantics, got #{inspect(value)}"

    if contract_case["method"] == "fetchTime" do
      assert abs(System.system_time(:millisecond) - value) <= @recent_time_tolerance_ms,
             "#{contract_case["id"]}: provider time is not current milliseconds"
    end
  end

  defp assert_meaning!(
         %{"success" => %{"representation" => "raw"}} = contract_case,
         %RawResponse{payload: payload},
         _resolved
       ) do
    keys = contract_case["success"]["provider_meaning_keys"]

    assert contains_meaning?(payload, keys),
           "#{contract_case["id"]}: raw provider payload contains none of the semantic keys #{inspect(keys)}"
  end

  defp assert_meaning!(
         %{"success" => %{"representation" => "positional_rows"} = success} = contract_case,
         rows,
         _resolved
       ) do
    Enum.each(rows, &assert_positional_row!(contract_case, success, &1))
  end

  defp assert_meaning!(contract_case, value, resolved) do
    values = semantic_values(value, contract_case["success"]["collection"])
    success = contract_case["success"]

    Enum.each(values, fn semantic_value ->
      Enum.each(success["required_fields"], fn field ->
        refute is_nil(field_value(semantic_value, field)),
               "#{contract_case["id"]}: required semantic field #{field} is nil"
      end)

      if success["any_fields"] != [] do
        assert Enum.any?(success["any_fields"], &(not is_nil(field_value(semantic_value, &1)))),
               "#{contract_case["id"]}: none of #{inspect(success["any_fields"])} carries provider meaning"
      end
    end)

    assert_symbol_meaning!(contract_case, values, resolved)
  end

  defp semantic_values(value, "single"), do: [value]
  defp semantic_values(value, "list"), do: value
  defp semantic_values(value, "map"), do: Map.values(value)
  defp semantic_values(_value, "scalar"), do: []

  defp assert_symbol_meaning!(contract_case, values, %{"symbol" => symbol}) do
    symbol_values = values |> Enum.map(&field_value(&1, "symbol")) |> Enum.reject(&is_nil/1)

    if symbol_values != [] do
      assert symbol in symbol_values,
             "#{contract_case["id"]}: provider result symbols #{inspect(symbol_values)} omit requested #{symbol}"
    end
  end

  defp assert_symbol_meaning!(_contract_case, _values, _resolved), do: :ok

  defp assert_positional_row!(contract_case, success, row) do
    values =
      Map.new(success["fields"], fn field ->
        value = Enum.at(row, field["index"])
        assert_field_type!(contract_case, field, value)
        {field["name"], value}
      end)

    Enum.each(success["invariants"], &assert_invariant!(contract_case, &1, values))
  end

  defp assert_field_type!(contract_case, %{"name" => name, "type" => "integer"}, value) do
    assert is_integer(value), "#{contract_case["id"]}: #{name} is not an integer"
  end

  defp assert_field_type!(contract_case, %{"name" => name, "type" => "number"}, value) do
    assert is_number(value), "#{contract_case["id"]}: #{name} is not numeric"
  end

  defp assert_invariant!(contract_case, %{"operator" => "gte"} = invariant, values) do
    assert values[invariant["left"]] >= values[invariant["right"]],
           "#{contract_case["id"]}: #{invariant["left"]} is below #{invariant["right"]}"
  end

  defp assert_invariant!(contract_case, %{"operator" => "between"} = invariant, values) do
    value = values[invariant["value"]]

    assert value >= values[invariant["minimum"]] and value <= values[invariant["maximum"]],
           "#{contract_case["id"]}: #{invariant["value"]} is outside provider bounds"
  end

  defp contains_meaning?(value, keys) when is_map(value) do
    Enum.any?(value, fn {key, child} ->
      (key_match?(to_string(key), keys) and meaningful?(child)) or contains_meaning?(child, keys)
    end)
  end

  defp contains_meaning?(value, keys) when is_list(value), do: Enum.any?(value, &contains_meaning?(&1, keys))
  defp contains_meaning?(_value, _keys), do: false

  defp key_match?(key, keys) do
    normalized = String.downcase(key)
    Enum.any?(keys, &String.contains?(normalized, String.downcase(&1)))
  end

  defp meaningful?(nil), do: false
  defp meaningful?(""), do: false
  defp meaningful?([]), do: false
  defp meaningful?(map) when is_map(map), do: map_size(map) > 0
  defp meaningful?(_value), do: true

  defp module_from_data(module_name) when is_binary(module_name) do
    module_name
    |> String.split(".")
    |> Module.concat()
  end

  defp existing_method_atom!(js_name) do
    Unified.method_atom_for_js_name(js_name) || flunk("unknown unified REST-read method #{inspect(js_name)}")
  end

  defp format_reason(%Error{} = reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
