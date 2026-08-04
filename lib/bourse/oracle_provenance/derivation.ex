defmodule Bourse.OracleProvenance.Derivation do
  @moduledoc """
  Derives binary oracle provenance from committed venue-reality evidence.

  Reality recordings establish that a method was observed. The owned spec is
  used only to route that method to the interpretive slots it exercises.
  """

  alias Bourse.Exchange
  alias Bourse.ExchangeAcceptanceFixtures
  alias Bourse.JsonDocument
  alias Bourse.PublicAcceptedRequests
  alias Bourse.RecordedResponseFixtures
  alias Bourse.RecordedResponseFixtures.ListBody
  alias Bourse.Registry
  alias Bourse.Spec
  alias Bourse.Unified
  alias Bourse.Unified.FieldMaps

  @response_root "test/fixtures/responses"
  @accepted_request_root "test/fixtures/exchange_accepted_requests"
  @public_accepted_request_root "test/fixtures/public_accepted_requests"
  @recorded_error_root "test/fixtures/recorded_errors"
  @authority_root "priv/authority"

  @core_parse_types ~w(market ticker order balance position)
  @extension_methods %{
    "fetchFundingHistory" => "income",
    "fetchOptionPositions" => "option_position",
    "fetchMySettlementHistory" => "settlement",
    "fetchSettlementHistory" => "settlement",
    "fetchTradingFees" => "trading_fees"
  }
  @return_type_aliases %{
    "ADL" => "ADLRank",
    "Accounts" => "Account",
    "Balances" => "Balance",
    "CrossBorrowRate" => "BorrowRate",
    "CrossBorrowRates" => "BorrowRate",
    "Currencies" => "Currency",
    "FundingRates" => "FundingRate",
    "Leverages" => "Leverage",
    "Option" => "OptionData",
    "OptionChain" => "OptionData",
    "Tickers" => "Ticker",
    "TradingFeeInterface" => "TradingFee",
    "TradingFees" => "TradingFee"
  }
  @safe_error_classes ~w(
    AuthenticationError BadRequest BadSymbol InsufficientFunds InvalidOrder
    OperationRejected OrderNotFound PermissionDenied
  )
  # Operational / ambient failures that must not be deliberately live-triggered.
  # These verify from the provider-owned error enumeration (authority docs), not
  # from a captured probe.
  @provider_doc_error_classes ~w(
    OnMaintenance ExchangeNotAvailable DDoSProtection RateLimitExceeded
    RequestTimeout NetworkError
  )
  @envelope_scalar_keys MapSet.new(~w(
    code count hasMore http_status id jsonrpc message msg next retCode retMsg
    status success time timestamp total ts
  ))
  @test_host_markers ["demo", "paper", "sandbox", "test.", "testnet"]

  @type host_class :: :production | :testnet_demo | :provider_doc
  @type verification_path ::
          :recorded_error | :provider_doc | :response | :accepted_request | :public_accepted_request
  @type slot_report :: %{
          path: String.t(),
          verified: boolean(),
          host_classes: [host_class()],
          contributing_methods: [String.t()],
          semantic: boolean(),
          critical: boolean(),
          expected_methods: [String.t()],
          unverified_methods: [String.t()],
          verification_paths: [verification_path()],
          verification_citations: [String.t()]
        }
  @type critical_slot :: %{path: String.t(), expected_methods: [String.t()]}
  @type venue_report :: %{
          venue: String.t(),
          verified: [String.t()],
          unverified: [String.t()],
          slots: [slot_report()]
        }

  @doc "Derives reports for the runtime venue set from committed reality manifests."
  @spec reports!(keyword()) :: [venue_report()]
  def reports!(opts \\ []) do
    venues = Keyword.get(opts, :venues, Spec.exchanges())
    response_root = Keyword.get(opts, :response_root, @response_root)
    accepted_root = Keyword.get(opts, :accepted_request_root, @accepted_request_root)
    public_accepted_root = Keyword.get(opts, :public_accepted_request_root, @public_accepted_request_root)
    error_root = Keyword.get(opts, :recorded_error_root, @recorded_error_root)
    authority_root = Keyword.get(opts, :authority_root, @authority_root)
    replay? = Keyword.get(opts, :replay_accepted_requests, true)
    replay_public? = Keyword.get(opts, :replay_public_accepted_requests, true)

    responses = load_evidence!(response_root, "recordings")
    accepted = load_evidence!(accepted_root, "goldens")
    {public_manifest, public_accepted} = PublicAcceptedRequests.load_all!(public_accepted_root)
    errors = load_evidence!(error_root, "recordings")

    Enum.map(venues, fn venue ->
      spec = venue |> Spec.owned_spec_path() |> Spec.decode_file!()
      ensure_authority!(authority_root, venue)

      contributions =
        response_contributions(spec, venue, responses) ++
          accepted_request_contributions(spec, venue, accepted, replay?) ++
          public_accepted_request_contributions(venue, public_manifest, public_accepted, replay_public?) ++
          error_contributions(spec, venue, errors, error_root) ++
          provider_doc_error_contributions(spec, venue, authority_root)

      build_report(spec, venue, contributions)
    end)
  end

  @doc "Returns the explicit method-to-field-map extensions outside the struct vocabulary."
  @spec method_slot_extensions() :: %{String.t() => String.t()}
  def method_slot_extensions, do: @extension_methods

  @doc "Derives the critical interpretive slots a promotion candidate must evidence."
  @spec critical_slots(map()) :: [critical_slot()]
  def critical_slots(spec) when is_map(spec) do
    expected = critical_expected_methods(spec)
    critical_error_paths = critical_error_paths(spec, %{})

    spec
    |> critical_slot_paths()
    |> Enum.filter(&critical_slot?(&1, expected, spec, critical_error_paths))
    |> Enum.map(fn path ->
      %{
        path: path,
        expected_methods: expected |> Map.get(path, []) |> Enum.sort()
      }
    end)
  end

  @doc "Classifies the environment named by a committed manifest host."
  @spec host_class(String.t()) :: host_class()
  def host_class(host) when is_binary(host) do
    normalized = String.downcase(host)

    if Enum.any?(@test_host_markers, &String.contains?(normalized, &1)) do
      :testnet_demo
    else
      :production
    end
  end

  @doc "Returns whether a real response body contains domain data rather than shape alone."
  @spec body_populated?(term()) :: boolean()
  def body_populated?(body) when is_list(body), do: ListBody.body_populated?(body)

  def body_populated?(body) when is_map(body) do
    Enum.any?(body, fn {key, value} ->
      case value do
        value when is_map(value) -> body_populated?(value)
        value when is_list(value) -> nested_list_populated?(value)
        value -> meaningful_scalar?(key, value)
      end
    end)
  end

  def body_populated?(_body), do: false

  @doc """
  Resolves the exact endpoint route an accepted-request golden was signed
  against, raising when the golden matches no (or more than one) route.
  """
  @spec accepted_route!(String.t(), map()) :: map()
  def accepted_route!(venue, golden) do
    acceptance = Map.fetch!(golden, "acceptance")
    request = Map.fetch!(golden, "request")
    method_atom = method_atom!(acceptance["method"])
    module = Registry.module_for(venue)
    expected_uri = URI.parse(Map.fetch!(request, "url"))
    expected_method = request |> Map.fetch!("method") |> String.downcase()
    sandbox? = host_class(Map.fetch!(acceptance, "host")) == :testnet_demo
    exchange = Exchange.new!(venue, sandbox: sandbox?)
    override = get_in(golden, ["replay", "call_opts", "base_url"])
    params = get_in(golden, ["replay", "params"]) || %{}

    matches =
      method_atom
      |> module.__unified_endpoint__()
      |> Enum.filter(fn config ->
        Atom.to_string(config.method) == expected_method and
          route_matches?(exchange, config, override, expected_uri, params)
      end)

    case matches do
      [config] -> config
      [] -> raise ArgumentError, "accepted request #{venue}:#{acceptance["method"]} matches no exact endpoint route"
      _many -> raise ArgumentError, "accepted request #{venue}:#{acceptance["method"]} matches multiple endpoint routes"
    end
  end

  defp response_contributions(spec, venue, evidence) do
    evidence
    |> rows_for(venue)
    |> Enum.flat_map(fn {row, fixture} ->
      if fixture_populated?(fixture) do
        method = Map.fetch!(row, "method")
        semantic = "tier1_semantic_oracle" in Map.get(row, "oracle_membership", [])
        contribution = contribution(method, row, semantic, :response)

        spec
        |> method_slot_paths(method)
        |> Kernel.++(market_pattern_paths(spec, method, fixture, row))
        |> Enum.map(&Map.put(contribution, :path, &1))
      else
        []
      end
    end)
  end

  defp accepted_request_contributions(spec, venue, evidence, replay?) do
    evidence
    |> rows_for(venue)
    |> Enum.flat_map(fn {row, golden} ->
      validate_accepted_identity!(row, golden)
      verify_accepted_replay!(golden, row, replay?)

      method = Map.fetch!(row, "method")
      route = accepted_route!(venue, golden)
      base = contribution(method, row, false, :accepted_request)
      request_path = "request_shape.#{js_method!(method)}"

      auth_paths =
        if route.authenticated do
          [auth_slot_path!(spec, route)]
        else
          []
        end

      Enum.map([request_path | auth_paths], &Map.put(base, :path, &1))
    end)
  end

  defp public_accepted_request_contributions(venue, manifest, evidence, replay?) do
    complete_methods = complete_public_methods(venue, manifest)

    evidence
    |> Enum.filter(fn {row, _golden} -> row["venue"] == venue end)
    |> Enum.flat_map(fn {row, golden} ->
      validate_public_accepted_identity!(row, golden)
      verify_public_accepted_replay!(golden, row, replay?)
      method = Map.fetch!(row, "method")
      base = contribution(method, row, false, :public_accepted_request)

      paths =
        [PublicAcceptedRequests.sign_path(Map.fetch!(golden, "acceptance"))] ++
          if(MapSet.member?(complete_methods, method), do: ["request_shape.#{method}"], else: [])

      Enum.map(paths, &Map.put(base, :path, &1))
    end)
  end

  defp complete_public_methods(venue, manifest) do
    expected =
      venue
      |> PublicAcceptedRequests.inventory()
      |> Enum.group_by(& &1.js_method, & &1.key)

    accepted =
      manifest["goldens"]
      |> Enum.filter(&(&1["venue"] == venue))
      |> Enum.group_by(& &1["method"], &public_branch_key/1)

    expected
    |> Enum.filter(fn {method, keys} -> MapSet.new(keys) == MapSet.new(Map.get(accepted, method, [])) end)
    |> MapSet.new(&elem(&1, 0))
  end

  defp public_branch_key(row), do: Enum.join([row["venue"], row["method"], row["branch"]], "|")

  defp error_contributions(spec, venue, evidence, error_root) do
    evidence
    |> rows_for(venue)
    |> Enum.flat_map(fn {row, fixture} ->
      if error_fixture_usable?(fixture, row) do
        base =
          Map.put(
            contribution(Map.fetch!(row, "method"), row, false, :recorded_error),
            :citation,
            Path.join(error_root, Map.fetch!(row, "path"))
          )

        spec
        |> error_slot_paths(Map.fetch!(row, "code"))
        |> Enum.map(&Map.put(base, :path, &1))
      else
        []
      end
    end)
  end

  defp provider_doc_error_contributions(spec, venue, authority_root) do
    %{codes: documented, citation: citation} = authority_error_evidence(authority_root, venue)

    spec
    |> error_slots()
    |> Enum.flat_map(fn {path, class} ->
      code = path |> Path.extname() |> String.trim_leading(".")

      # Live probes cover the safe business classes. Codes that cannot be safely
      # triggered (maintenance, IP bans, similar operational states) verify from
      # the provider-owned error enumeration when the code is documented there.
      if provider_doc_verifiable?(path, class) and MapSet.member?(documented, code) do
        [
          %{
            path: path,
            method: nil,
            host_class: :provider_doc,
            semantic: false,
            source: :provider_doc,
            citation: citation
          }
        ]
      else
        []
      end
    end)
  end

  defp provider_doc_verifiable?(path, class) do
    safely_recordable_error_code?(path) and class in @provider_doc_error_classes
  end

  defp contribution(method, row, semantic, source) do
    %{
      method: if(method in [nil, ""], do: nil, else: js_method!(method)),
      host_class: host_class(Map.fetch!(row, "host")),
      semantic: semantic,
      source: source,
      citation: contribution_citation(source, row)
    }
  end

  defp contribution_citation(_source, _row), do: nil

  defp build_report(spec, venue, contributions) do
    expected = expected_methods_by_slot(spec, venue)
    contribution_groups = Enum.group_by(contributions, & &1.path)
    critical_error_paths = critical_error_paths(spec, contribution_groups)

    slots =
      spec
      |> slot_paths(venue)
      |> Enum.map(fn path ->
        claims = Map.get(contribution_groups, path, [])

        methods =
          claims
          |> Enum.map(& &1.method)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        expected_methods = expected |> Map.get(path, []) |> Enum.sort()

        verification_paths =
          claims
          |> Enum.map(& &1.source)
          |> Enum.uniq()
          |> Enum.sort()

        verification_citations =
          claims
          |> Enum.map(& &1.citation)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        %{
          path: path,
          verified: claims != [],
          host_classes: claims |> Enum.map(& &1.host_class) |> Enum.uniq() |> Enum.sort(),
          contributing_methods: methods,
          semantic: Enum.any?(claims, & &1.semantic),
          critical: critical_slot?(path, expected, spec, critical_error_paths),
          expected_methods: expected_methods,
          unverified_methods: expected_methods -- methods,
          verification_paths: verification_paths,
          verification_citations: verification_citations
        }
      end)

    %{
      venue: venue,
      verified: slots |> Enum.filter(& &1.verified) |> Enum.map(& &1.path),
      unverified: slots |> Enum.reject(& &1.verified) |> Enum.map(& &1.path),
      slots: slots
    }
  end

  defp slot_paths(spec, venue) do
    field_paths =
      spec
      |> get_in(["normalization", "field_maps"])
      |> child_keys()
      |> Enum.map(&"normalization.field_maps.#{&1}")

    auth_paths =
      spec
      |> get_in(["auth", "sign_recipe"])
      |> child_keys()
      |> Enum.map(&"auth.sign_recipe.#{&1}")

    request_paths =
      spec
      |> supported_js_methods()
      |> Enum.map(&"request_shape.#{&1}")

    market_paths =
      spec
      |> get_in(["markets", "patterns"])
      |> child_keys()
      |> Enum.map(&"markets.patterns.#{&1}")

    error_paths = spec |> error_slots() |> Enum.map(&elem(&1, 0))

    public_sign_paths =
      venue
      |> PublicAcceptedRequests.inventory()
      |> Enum.map(&PublicAcceptedRequests.sign_path/1)

    (field_paths ++ auth_paths ++ request_paths ++ market_paths ++ error_paths ++ public_sign_paths)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expected_methods_by_slot(spec, venue) do
    method_slots =
      spec
      |> supported_js_methods()
      |> Enum.flat_map(fn method ->
        Enum.map(method_slot_paths(spec, method), &{&1, method})
      end)

    auth_slots =
      spec
      |> supported_method_configs(venue)
      |> Enum.flat_map(fn {method, configs} ->
        configs
        |> Enum.filter(& &1.authenticated)
        |> Enum.map(&{auth_slot_path!(spec, &1), method})
      end)

    market_slots =
      spec
      |> get_in(["markets", "patterns"])
      |> child_keys()
      |> Enum.map(&{"markets.patterns.#{&1}", "fetchMarkets"})

    request_slots =
      spec
      |> supported_js_methods()
      |> Enum.map(&{"request_shape.#{&1}", &1})

    public_sign_slots =
      venue
      |> PublicAcceptedRequests.inventory()
      |> Enum.map(&{PublicAcceptedRequests.sign_path(&1), &1.js_method})

    (method_slots ++ auth_slots ++ market_slots ++ request_slots ++ public_sign_slots)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {path, methods} -> {path, Enum.uniq(methods)} end)
  end

  defp critical_slot_paths(spec) do
    field_paths =
      spec
      |> get_in(["normalization", "field_maps"])
      |> child_keys()
      |> Enum.map(&"normalization.field_maps.#{&1}")

    auth_paths =
      spec
      |> get_in(["auth", "sign_recipe"])
      |> child_keys()
      |> Enum.map(&"auth.sign_recipe.#{&1}")

    request_paths =
      spec
      |> supported_js_methods()
      |> Enum.map(&"request_shape.#{&1}")

    market_paths =
      spec
      |> get_in(["markets", "patterns"])
      |> child_keys()
      |> Enum.map(&"markets.patterns.#{&1}")

    error_paths = spec |> error_slots() |> Enum.map(&elem(&1, 0))

    (field_paths ++ auth_paths ++ request_paths ++ market_paths ++ error_paths)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp critical_expected_methods(spec) do
    method_slots =
      spec
      |> supported_js_methods()
      |> Enum.flat_map(fn method ->
        Enum.map(method_slot_paths(spec, method), &{&1, method})
      end)

    auth_slots =
      spec
      |> candidate_method_configs()
      |> Enum.flat_map(fn {method, configs} ->
        configs
        |> Enum.filter(& &1.authenticated)
        |> Enum.map(&{auth_slot_path!(spec, &1), method})
      end)

    market_slots =
      spec
      |> get_in(["markets", "patterns"])
      |> child_keys()
      |> Enum.map(&{"markets.patterns.#{&1}", "fetchMarkets"})

    request_slots =
      spec
      |> supported_js_methods()
      |> Enum.map(&{"request_shape.#{&1}", &1})

    (method_slots ++ auth_slots ++ market_slots ++ request_slots)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {path, methods} -> {path, Enum.uniq(methods)} end)
  end

  defp candidate_method_configs(spec) do
    describe = get_in(spec, ["raw", "describe"]) || %{}
    hostname = describe["hostname"] || ""
    prefixes = Exchange.compute_url_prefixes(spec, hostname)
    auth_sections = get_in(spec, ["auth", "authenticated_sections"]) || []
    configs = Exchange.build_endpoint_configs(describe["api"] || %{}, prefixes, auth_sections)
    mapping = Exchange.build_unified_method_mapping(spec, configs)

    Map.new(supported_js_methods(spec), fn method ->
      method_atom = Unified.method_atom_for_js_name(method)
      {method, Map.get(mapping, method_atom, [])}
    end)
  end

  defp critical_slot?("auth.sign_recipe." <> _section = path, expected, _spec, _error_paths),
    do: Map.has_key?(expected, path)

  defp critical_slot?("markets.patterns." <> _type, _expected, _spec, _error_paths), do: true

  defp critical_slot?("normalization.field_maps." <> type, expected, _spec, _error_paths) do
    type in @core_parse_types and Map.has_key?(expected, "normalization.field_maps.#{type}")
  end

  defp critical_slot?("request_shape." <> method, expected, spec, _error_paths) do
    path = "request_shape.#{method}"
    Map.has_key?(expected, path) and Enum.any?(method_slot_paths(spec, method), &core_field_path?/1)
  end

  defp critical_slot?("errors.handle_errors." <> _rest = path, _expected, _spec, error_paths),
    do: MapSet.member?(error_paths, path)

  defp critical_slot?(_path, _expected, _spec, _error_paths), do: false

  defp critical_error_paths(spec, contribution_groups) do
    spec
    |> error_slots()
    |> Enum.filter(fn {path, class} ->
      safely_recordable_error_code?(path) and class in @safe_error_classes
    end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> MapSet.new(fn {_class, paths} ->
      paths = Enum.sort(paths)
      Enum.find(paths, &Map.has_key?(contribution_groups, &1)) || hd(paths)
    end)
  end

  defp core_field_path?("normalization.field_maps." <> type), do: type in @core_parse_types
  defp core_field_path?(_path), do: false

  defp method_slot_paths(spec, method) do
    js_method = js_method!(method)
    field_maps = get_in(spec, ["normalization", "field_maps"]) || %{}

    derived =
      case parse_type_for_method(spec, js_method) do
        nil -> []
        parse_type -> ["normalization.field_maps.#{parse_type}"]
      end

    extension =
      case Map.get(@extension_methods, js_method) do
        nil -> []
        parse_type -> ["normalization.field_maps.#{parse_type}"]
      end

    (derived ++ extension)
    |> Enum.filter(fn "normalization.field_maps." <> type -> Map.has_key?(field_maps, type) end)
    |> Enum.uniq()
  end

  defp parse_type_for_method(spec, js_method) do
    return_type = get_in(spec, ["endpoints", "descriptors", js_method, "signature", "return_type"])

    with return_type when is_binary(return_type) <- return_type,
         [_, token] <- Regex.run(~r/^Promise<(.+)>$/, return_type) do
      token = normalize_return_token(token)
      aliased = Map.get(@return_type_aliases, token, token)
      parse_types_by_return_type()[aliased]
    else
      _other -> nil
    end
  end

  defp normalize_return_token(token) do
    token
    |> String.trim()
    |> String.replace(~r/\[\]$/, "")
    |> String.replace(~r/^Array<(.+)>$/, "\\1")
    |> String.replace(~r/\s*\|\s*undefined$/, "")
  end

  defp parse_types_by_return_type do
    Map.new(FieldMaps.parse_types(), fn parse_type ->
      name = parse_type |> FieldMaps.struct_for() |> Module.split() |> List.last()
      {name, parse_type}
    end)
  end

  defp supported_js_methods(spec) do
    capabilities = get_in(spec, ["capabilities", "has"]) || %{}
    unified = get_in(spec, ["endpoints", "unified"]) || %{}

    unified
    |> Enum.filter(fn {method, endpoints} -> Map.get(capabilities, method) == true and match?([_ | _], endpoints) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&(Unified.method_atom_for_js_name(&1) != nil))
    |> Enum.sort()
  end

  defp supported_method_configs(spec, venue) do
    module = Registry.module_for(venue)

    Map.new(supported_js_methods(spec), fn method ->
      {method, module.__unified_endpoint__(Unified.method_atom_for_js_name(method))}
    end)
  end

  defp auth_slot_path!(spec, config) do
    recipes = get_in(spec, ["auth", "sign_recipe"]) || %{}
    section = Enum.join(config.sections, ".")
    top_section = List.first(config.sections)

    cond do
      Map.has_key?(recipes, section) -> "auth.sign_recipe.#{section}"
      Map.has_key?(recipes, top_section) -> "auth.sign_recipe.#{top_section}"
      true -> raise ArgumentError, "authenticated endpoint #{config.name} has no authored sign recipe"
    end
  end

  defp route_matches?(exchange, config, override, expected_uri, params) do
    base_url = override || endpoint_base_url(exchange.base_urls, config.sections)

    case base_url do
      nil ->
        false

      base_url ->
        case interpolate_route_path(config.path, params) do
          {:ok, path} ->
            candidate = URI.parse(join_url(base_url, config.url_prefix, path))
            candidate.host == expected_uri.host and candidate.path == expected_uri.path

          :error ->
            false
        end
    end
  end

  defp interpolate_route_path(path, params) do
    keys = for [_, key] <- Regex.scan(~r/{([^}]+)}/, path), do: key

    if Enum.all?(keys, &Map.has_key?(params, &1)) do
      {:ok, Regex.replace(~r/{([^}]+)}/, path, fn _match, key -> to_string(Map.fetch!(params, key)) end)}
    else
      :error
    end
  end

  defp endpoint_base_url(base_urls, sections) do
    section = Enum.join(sections, ".")

    Map.get(base_urls, section) ||
      Map.get(base_urls, List.first(sections)) ||
      Map.get(base_urls, "rest") ||
      if map_size(base_urls) == 1, do: base_urls |> Map.values() |> hd()
  end

  defp join_url(base, prefix, path) do
    base = String.trim_trailing(base, "/")
    suffix = [prefix, path] |> Enum.join("/") |> String.replace(~r{/+}, "/") |> String.trim_leading("/")
    "#{base}/#{suffix}"
  end

  defp market_pattern_paths(spec, method, fixture, row) do
    if js_method!(method) == "fetchMarkets" do
      known = spec |> get_in(["markets", "patterns"]) |> child_keys() |> MapSet.new()

      fixture
      |> market_types(row)
      |> Enum.filter(&MapSet.member?(known, &1))
      |> Enum.map(&"markets.patterns.#{&1}")
    else
      []
    end
  end

  defp market_types(fixture, row) do
    fixture
    |> response_bodies()
    |> Enum.flat_map(fn {body, metadata} ->
      inferred =
        metadata
        |> market_case(row)
        |> RecordedResponseFixtures.infer_market_type()

      [inferred | market_types_from_body(body)]
    end)
    |> Enum.reject(&(&1 in ["unknown", "inverse"]))
    |> Enum.uniq()
  end

  defp market_case(metadata, row) do
    params = Map.get(metadata, "params")
    result = metadata |> Map.get("body", %{}) |> map_value("result")
    category = map_value(params, "category") || map_value(result, "category")

    input =
      case category do
        "spot" -> ["BTC/USDT"]
        "linear" -> ["BTC/USDT:USDT"]
        "inverse" -> ["BTC/USD:BTC"]
        _other -> []
      end

    %{"input" => input, "url" => "#{row["host"]}/#{metadata["api"] || row["endpoint"]}"}
  end

  defp market_types_from_body(body) do
    values = all_maps(body)
    categories = Enum.map(values, &(Map.get(&1, "category") || Map.get(&1, "kind")))
    asset_classes = Enum.map(values, &Map.get(&1, "class"))
    contract_types = Enum.map(values, &Map.get(&1, "contractType"))
    market_types = Enum.map(values, &Map.get(&1, "market_type"))

    []
    |> maybe_add("crypto", "crypto" in asset_classes)
    |> maybe_add("equity", "us_equity" in asset_classes)
    |> maybe_add("spot", "spot" in categories or "spot" in market_types or spot_market_body?(values))
    |> maybe_add("option", "option" in categories or Enum.any?(values, &Map.has_key?(&1, "optionSymbols")))
    |> maybe_add(
      "swap",
      "linear" in categories or Enum.any?(market_types, &(&1 in ["perp", "perpetual"])) or
        perpetual_body?(values, contract_types)
    )
    |> maybe_add("future", future_body?(values, contract_types))
  end

  defp spot_market_body?(maps) do
    Enum.any?(
      maps,
      &(Map.has_key?(&1, "baseAsset") and Map.has_key?(&1, "quoteAsset") and
          !Map.has_key?(&1, "contractType"))
    )
  end

  defp perpetual_body?(maps, contract_types) do
    "PERPETUAL" in contract_types or
      Enum.any?(maps, &(Map.get(&1, "settlement_period") == "perpetual")) or
      Enum.any?(maps, &Map.has_key?(&1, "universe"))
  end

  defp future_body?(maps, contract_types) do
    Enum.any?(contract_types, &(is_binary(&1) and &1 != "PERPETUAL")) or
      Enum.any?(maps, &(Map.get(&1, "kind") == "future" and Map.get(&1, "settlement_period") != "perpetual"))
  end

  defp maybe_add(types, type, true), do: [type | types]
  defp maybe_add(types, _type, false), do: types

  defp all_maps(map) when is_map(map), do: [map | Enum.flat_map(Map.values(map), &all_maps/1)]
  defp all_maps(list) when is_list(list), do: Enum.flat_map(list, &all_maps/1)
  defp all_maps(_other), do: []

  defp response_bodies(%{"responses" => responses}) when is_list(responses) do
    Enum.map(responses, fn response -> {Map.get(response, "body"), response} end)
  end

  defp response_bodies(%{"body" => body} = fixture), do: [{body, fixture}]
  defp response_bodies(fixture), do: [{fixture, fixture}]

  defp fixture_populated?(fixture) do
    fixture
    |> response_bodies()
    |> Enum.any?(fn {body, _metadata} -> body_populated?(body) end)
  end

  # Error envelopes are often code/msg only. Those keys are envelope scalars for
  # success-body populated-ness, so error recordings use their own usability rule:
  # a frozen code plus a present body (map/list/binary) is evidence.
  defp error_fixture_usable?(fixture, row) do
    code = Map.get(row, "code") || Map.get(fixture, "code")
    body = Map.get(fixture, "body")
    code not in [nil, ""] and body not in [nil, "", %{}, []]
  end

  defp error_slots(spec) do
    spec
    |> get_in(["errors", "handle_errors", "exceptions"])
    |> flatten_error_slots(["exceptions", "handle_errors", "errors"])
  end

  defp authority_error_evidence(root, venue) do
    manifest_path = Path.join([root, venue, "manifest.json"])
    manifest = JsonDocument.decode_file!(manifest_path)

    case manifest["error_enumeration"] do
      %{"path" => path} when is_binary(path) ->
        citation = Path.join([root, venue, path])

        codes =
          citation
          |> JsonDocument.decode_file!()
          |> Map.get("codes", %{})

        %{
          citation: citation,
          codes: if(is_map(codes), do: MapSet.new(Map.keys(codes)), else: MapSet.new())
        }

      _other ->
        %{citation: nil, codes: MapSet.new()}
    end
  end

  defp flatten_error_slots(map, reversed_prefix) when is_map(map) do
    Enum.flat_map(map, fn
      {key, value} when is_map(value) ->
        flatten_error_slots(value, [key | reversed_prefix])

      {key, value} when is_binary(value) ->
        [{[key | reversed_prefix] |> Enum.reverse() |> Enum.join("."), value}]

      _other ->
        []
    end)
  end

  defp flatten_error_slots(_other, _prefix), do: []

  defp error_slot_paths(spec, code) do
    code = to_string(code)

    spec
    |> error_slots()
    |> Enum.filter(fn {path, _class} -> String.ends_with?(path, ".#{code}") end)
    |> Enum.map(&elem(&1, 0))
  end

  defp load_evidence!(root, collection_key) do
    manifest_path = Path.join(root, "_manifest.json")
    manifest = JsonDocument.decode_file!(manifest_path)
    rows = Map.fetch!(manifest, collection_key)

    if Map.get(manifest, "count") != length(rows) do
      raise ArgumentError, "#{manifest_path} count does not match #{collection_key}"
    end

    declared = MapSet.new(rows, &Map.fetch!(&1, "path"))
    actual = reality_files(root)
    missing = declared |> MapSet.difference(actual) |> MapSet.to_list() |> Enum.sort()
    orphaned = actual |> MapSet.difference(declared) |> MapSet.to_list() |> Enum.sort()

    if missing != [] or orphaned != [] do
      missing = Enum.map(missing, &manifest_row_label(rows, &1, root, collection_key))
      orphaned = Enum.map(orphaned, &orphan_label(&1, root, collection_key))

      raise ArgumentError,
            "#{manifest_path} is inconsistent: missing files #{inspect(missing)}, orphaned files #{inspect(orphaned)}"
    end

    Enum.map(rows, fn row ->
      path = Map.fetch!(row, "path")
      {row, root |> Path.join(path) |> JsonDocument.decode_file!()}
    end)
  end

  defp reality_files(root) do
    root
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "_manifest.json"))
    |> MapSet.new(&Path.relative_to(&1, root))
  end

  defp ensure_authority!(root, venue) do
    path = Path.join([root, venue, "manifest.json"])
    manifest = JsonDocument.decode_file!(path)

    if manifest["venue"] != venue or !is_list(manifest["artifacts"]) or manifest["artifacts"] == [] do
      raise ArgumentError, "invalid authority manifest for #{venue}: #{path}"
    end
  end

  defp validate_accepted_identity!(row, golden) do
    acceptance = Map.fetch!(golden, "acceptance")
    identity_keys = ~w(venue method host endpoint capture_date captured_at http_status)

    mismatches = Enum.reject(identity_keys, &(Map.get(row, &1) == Map.get(acceptance, &1)))
    request_host = golden |> get_in(["request", "url"]) |> URI.parse() |> Map.get(:host)

    if mismatches != [] or request_host != row["host"] do
      raise ArgumentError, "accepted request identity mismatch for #{row["path"]}"
    end
  end

  defp verify_accepted_replay!(_golden, _row, false), do: :ok

  defp verify_accepted_replay!(golden, row, true) do
    case ExchangeAcceptanceFixtures.replay(golden) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "accepted request replay failed for #{row["path"]}: #{inspect(reason)}"
    end
  end

  # The manifest row is the golden's acceptance block plus "path" by
  # construction — any other delta (host, endpoint, dates, status) is a
  # provenance mutation, not a formatting difference.
  defp validate_public_accepted_identity!(row, golden) do
    acceptance = Map.fetch!(golden, "acceptance")

    if Map.delete(row, "path") != acceptance do
      raise ArgumentError, "public accepted request identity mismatch for #{row["path"]}"
    end
  end

  defp verify_public_accepted_replay!(_golden, _row, false), do: :ok

  defp verify_public_accepted_replay!(golden, row, true) do
    case PublicAcceptedRequests.replay(golden) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "public accepted request replay failed for #{row["path"]}: #{inspect(reason)}"
    end
  end

  defp rows_for(rows, venue), do: Enum.filter(rows, fn {row, _fixture} -> row["venue"] == venue end)

  @doc """
  Canonicalizes a manifest method name — snake atom string or JS name — to its
  unified JS name. Names outside `Unified.method_defs/0` pass through unchanged.
  """
  @spec js_method!(String.t()) :: String.t()
  def js_method!(method) when is_binary(method) do
    case Enum.find(Unified.method_defs(), fn {atom, js_name, _params, _description} ->
           method == Atom.to_string(atom) or method == js_name
         end) do
      {_atom, js_name, _params, _description} -> js_name
      nil -> method
    end
  end

  defp method_atom!(method) do
    case Enum.find(Unified.method_defs(), fn {atom, js_name, _params, _description} ->
           method == Atom.to_string(atom) or method == js_name
         end) do
      {atom, _js_name, _params, _description} -> atom
      nil -> raise ArgumentError, "unknown unified method #{inspect(method)}"
    end
  end

  defp child_keys(map) when is_map(map) do
    map |> Map.keys() |> Enum.reject(&String.starts_with?(&1, "_")) |> Enum.sort()
  end

  defp child_keys(_other), do: []

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_other, _key), do: nil

  defp meaningful_scalar?(key, value) do
    !MapSet.member?(@envelope_scalar_keys, to_string(key)) and value not in [nil, ""]
  end

  defp nested_list_populated?([]), do: false

  defp nested_list_populated?(list) do
    Enum.any?(list, fn
      value when is_map(value) -> body_populated?(value)
      value when is_list(value) -> nested_list_populated?(value)
      value -> value not in [nil, ""]
    end)
  end

  defp safely_recordable_error_code?(path) do
    code = path |> :binary.split(".", [:global]) |> List.last()
    String.contains?(path, ".exact.") or match?({_integer, ""}, Integer.parse(code))
  end

  defp manifest_row_label(rows, path, root, collection_key) do
    row = Enum.find(rows, &(&1["path"] == path))
    evidence_label(row, path, root, collection_key)
  end

  defp orphan_label(path, root, collection_key) do
    [venue | _rest] = Path.split(path)
    basename = Path.basename(path)
    extension = path |> Path.extname() |> String.trim_leading(".")

    method =
      Enum.find_value(Unified.method_defs(), basename, fn {method, _js_name, _params, _description} ->
        if Enum.join([Atom.to_string(method), extension], ".") == basename, do: Atom.to_string(method)
      end)

    evidence_label(%{"venue" => venue, "method" => method}, path, root, collection_key)
  end

  defp evidence_label(%{"venue" => venue, "method" => method} = row, path, root, collection_key) do
    slots =
      cond do
        collection_key == "goldens" ->
          ["request_shape.#{js_method!(method)}"]

        String.contains?(root, "recorded_errors") and Map.has_key?(row, "code") ->
          venue
          |> Spec.owned_spec_path()
          |> Spec.decode_file!()
          |> error_slot_paths(row["code"])

        venue in Spec.exchanges() ->
          venue
          |> Spec.owned_spec_path()
          |> Spec.decode_file!()
          |> method_slot_paths(method)

        true ->
          []
      end

    "#{venue}:#{Enum.join(slots, ",")} (#{path})"
  end

  defp evidence_label(_row, path, _root, _collection_key), do: path
end
