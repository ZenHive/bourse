defmodule Bourse.PublicAcceptedRequests do
  @moduledoc """
  Records and replays provider-accepted public request branches.

  Branch inventory comes from the owned unified endpoint routing. Only
  unauthenticated, non-transactional reads are eligible; every request is sent
  sequentially and must receive HTTP 200 from the provider.
  """

  alias Bourse.Dispatch
  alias Bourse.Exchange
  alias Bourse.JsonDocument
  alias Bourse.Registry
  alias Bourse.ReplayExchange
  alias Bourse.Spec
  alias Bourse.Unified
  alias Bourse.Unified.RequestShape

  @schema_version 1
  @fixture_root Path.expand("../../test/fixtures/public_accepted_requests", __DIR__)
  @default_pacing_ms 100
  @capture_drain_ms 10
  @capture_timeout_ms 2_000
  @ohlcv_timeframe "1m"
  @history_window_ms 3_600_000
  @lighter_public_account_index 0
  # Matched against normalize_name/1 output (lowercased, non-alphanumerics
  # stripped) — entries must be in that normalized form or they are unreachable.
  @sensitive_names MapSet.new(~w(
    accesskey accesspassphrase accesssign accesstoken account accountid
    apcaapikeyid apcaapisecretkey apikey apisecret authorization bearer
    clientsecret cookie key okaccesskey okaccesspassphrase okaccesssign
    passphrase password privatekey secret session signature subaccount
    subaccountid token user wallet walletaddress xapikey xbapiapikey xbapisign
    xlyrasignature xlyrawallet xmbxapikey
  ))
  @credential_env_names ~w(
    ALPACA_API_KEY ALPACA_API_SECRET
    BINANCE_TESTNET_API_KEY BINANCE_TESTNET_API_SECRET
    BINANCE_FUTURES_TEST_API_KEY BINANCE_FUTURES_TEST_API_SECRET
    BYBIT_TESTNET_API_KEY BYBIT_TESTNET_API_SECRET
    BYBIT_DEMO_API_KEY BYBIT_DEMO_API_SECRET
    DERIBIT_TESTNET_API_KEY DERIBIT_TESTNET_API_SECRET
    DERIVE_TESTNET_API_KEY DERIVE_TESTNET_API_SECRET
    HYPERLIQUID_TESTNET_API_KEY HYPERLIQUID_TESTNET_API_SECRET
    LIGHTER_TESTNET_API_PRIVATE_KEY
    OKX_INTL_API_KEY OKX_INTL_API_SECRET OKX_INTL_PASSPHRASE
  )

  @type branch :: %{
          required(:key) => String.t(),
          required(:venue) => String.t(),
          required(:method) => atom(),
          required(:js_method) => String.t(),
          required(:required_params) => [atom()],
          required(:branch) => String.t(),
          required(:endpoint_index) => non_neg_integer(),
          required(:config) => map()
        }
  @type capture_result :: {:golden, map()} | {:exclusion, map()}

  @doc "Returns the bulk public-acceptance fixture root."
  @spec fixture_root() :: Path.t()
  def fixture_root, do: @fixture_root

  @doc "Returns the bulk public-acceptance manifest path."
  @spec manifest_path() :: Path.t()
  def manifest_path, do: Path.join(@fixture_root, "_manifest.json")

  @doc "Derives every eligible public request branch from the owned runtime specs."
  @spec inventory() :: [branch()]
  def inventory do
    Spec.exchanges()
    |> Enum.flat_map(&inventory/1)
    |> Enum.sort_by(& &1.key)
  end

  @doc "Derives one venue's eligible public request branches."
  @spec inventory(String.t()) :: [branch()]
  def inventory(venue) when is_binary(venue) do
    spec = venue |> Spec.owned_spec_path() |> Spec.decode_file!()
    module = Registry.module_for(venue)
    capabilities = get_in(spec, ["capabilities", "has"]) || %{}
    classifications = get_in(spec, ["endpoints", "transaction_classification"]) || %{}
    selections = get_in(spec, ["endpoints", "request", "endpoint_selection"]) || %{}

    Unified.method_defs()
    |> Enum.flat_map(&inventory_method(&1, venue, module, capabilities, classifications, selections))
    |> ensure_unique_inventory!()
    |> Enum.sort_by(& &1.key)
  end

  @doc "Returns the public sign-path slot exercised by a branch."
  @spec sign_path(branch() | map()) :: String.t()
  def sign_path(%{config: config}), do: "sign_path.public.#{Enum.join(config.sections, ".")}"

  def sign_path(%{"sections" => sections}) when is_list(sections), do: "sign_path.public.#{Enum.join(sections, ".")}"

  @doc "Records all branches for one venue without credentials."
  @spec record_venue(String.t(), keyword()) :: [capture_result()]
  def record_venue(venue, opts \\ []) when is_binary(venue) do
    exchange = capture_exchange!(venue)
    Enum.map(inventory(venue), &record_branch(&1, Keyword.put(opts, :exchange, exchange)))
  end

  @doc "Records one public request branch, returning a golden or dated exclusion."
  @spec record_branch(branch(), keyword()) :: capture_result()
  def record_branch(branch, opts \\ []) do
    captured_at = Keyword.get_lazy(opts, :captured_at, &DateTime.utc_now/0)

    try do
      with :ok <- validate_safe_branch(branch),
           exchange = Keyword.get_lazy(opts, :exchange, fn -> capture_exchange!(branch.venue) end),
           {:ok, params, markets} <- replay_inputs(exchange, branch),
           timestamp_ms = DateTime.to_unix(captured_at, :millisecond),
           {:ok, requests, cursors} <- capture_live(exchange, branch, params, timestamp_ms, opts),
           golden = golden(branch, params, markets, requests, cursors, captured_at, timestamp_ms),
           [] <- scrub_violations(golden),
           :ok <- validate_route(golden) do
        {:golden, golden}
      else
        {:error, reason} -> {:exclusion, exclusion(branch, captured_at, reason)}
        [_ | _] = violations -> {:exclusion, exclusion(branch, captured_at, {:scrub_violations, violations})}
      end
    rescue
      # Intentional: a single branch's capture must never crash the bulk loop.
      # reach:disable-next-line bare_rescue
      error -> {:exclusion, exclusion(branch, captured_at, Exception.message(error))}
    end
  end

  @doc "Loads and validates the committed bulk manifest and all named goldens."
  @spec load_all!(Path.t()) :: {map(), [{map(), map()}]}
  def load_all!(root \\ @fixture_root) do
    manifest = root |> Path.join("_manifest.json") |> JsonDocument.decode_file!()
    validate_manifest!(manifest, root)

    goldens =
      Enum.map(manifest["goldens"], fn row ->
        {row, root |> Path.join(row["path"]) |> JsonDocument.decode_file!()}
      end)

    {manifest, goldens}
  end

  @doc "Validates the committed manifest against the current authored branch inventory."
  @spec validate_manifest!(map(), Path.t()) :: :ok
  def validate_manifest!(manifest, root \\ @fixture_root) do
    case manifest_errors(manifest, inventory(), root) do
      [] -> :ok
      errors -> raise ArgumentError, Enum.join(["invalid public accepted-request manifest:" | errors], "\n  * ")
    end
  end

  @doc "Returns manifest completeness and safety errors without raising."
  @spec manifest_errors(map(), [branch() | map()], Path.t() | nil) :: [String.t()]
  def manifest_errors(manifest, expected, root \\ nil) when is_map(manifest) and is_list(expected) do
    goldens = Map.get(manifest, "goldens", [])
    exclusions = Map.get(manifest, "exclusions", [])
    rows = goldens ++ exclusions
    expected_keys = MapSet.new(expected, &branch_key/1)
    actual_keys = MapSet.new(rows, &branch_key/1)

    []
    |> maybe_error(manifest["schema_version"] != @schema_version, "schema_version must be #{@schema_version}")
    |> maybe_error(manifest["count"] != length(goldens), "count does not match goldens")
    |> maybe_error(manifest["exclusion_count"] != length(exclusions), "exclusion_count does not match exclusions")
    |> Kernel.++(duplicate_errors(rows))
    |> Kernel.++(set_errors(expected_keys, actual_keys))
    |> Kernel.++(row_errors(goldens, exclusions))
    |> Kernel.++(file_errors(root, goldens))
  end

  @doc "Deterministically rebuilds and validates one committed public golden."
  @spec replay(map()) :: :ok | {:error, term()}
  def replay(golden) when is_map(golden) do
    with :ok <- validate_route(golden),
         [] <- scrub_violations(golden),
         {:ok, branch} <- branch_for_golden(golden),
         {:ok, exchange} <- replay_exchange(golden),
         {:ok, requests, _cursors} <- capture_replay(exchange, branch, golden),
         true <- requests == golden["requests"] do
      :ok
    else
      false -> {:error, :request_regressed}
      [_ | _] -> {:error, :sensitive_material_present}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns structural credential and account-identity leaks in a golden."
  @spec scrub_violations(term()) :: [String.t()]
  def scrub_violations(golden) do
    requests = Map.get(golden, "requests", [])
    structural = requests |> Enum.with_index() |> Enum.flat_map(&request_violations/1)
    material = forbidden_material_violations(golden)
    Enum.sort(structural ++ material)
  end

  @doc "Builds a complete manifest document from capture results."
  @spec manifest([capture_result()], DateTime.t()) :: map()
  def manifest(results, generated_at \\ DateTime.utc_now()) when is_list(results) do
    goldens =
      for {:golden, golden} <- results do
        golden
        |> Map.fetch!("acceptance")
        |> Map.take(~w(branch capture_date captured_at endpoint host http_status method sections venue))
        |> Map.put("path", fixture_relative_path(golden))
      end

    exclusions = for {:exclusion, exclusion} <- results, do: exclusion

    %{
      "count" => length(goldens),
      "exclusion_count" => length(exclusions),
      "exclusions" => Enum.sort_by(exclusions, &branch_key/1),
      "generated_at" => generated_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "goldens" => Enum.sort_by(goldens, &branch_key/1),
      "oracle" => "public_exchange_acceptance",
      "schema_version" => @schema_version
    }
  end

  @doc "Returns a golden's stable relative fixture path."
  @spec fixture_relative_path(map()) :: Path.t()
  def fixture_relative_path(%{"acceptance" => acceptance}) do
    method = Macro.underscore(acceptance["method"])
    branch = String.replace(acceptance["branch"], ~r/[^a-zA-Z0-9_.-]/, "_")
    Path.join(acceptance["venue"], "#{method}--#{branch}.json")
  end

  defp public_read?(capabilities, classifications, js_method) do
    capabilities[js_method] == true and
      get_in(classifications, [js_method, "transactional"]) == false
  end

  defp inventory_method(
         {method, js_method, required_params, _description},
         venue,
         module,
         capabilities,
         classifications,
         selections
       ) do
    if public_read?(capabilities, classifications, js_method) do
      method
      |> module.__unified_endpoint__()
      |> selected_public_configs(Map.get(selections, js_method))
      |> Enum.map(&inventory_branch(&1, venue, method, js_method, required_params))
    else
      []
    end
  end

  defp inventory_branch({config, endpoint_index}, venue, method, js_method, required_params) do
    branch(venue, method, js_method, required_params, config, endpoint_index)
  end

  defp selected_public_configs(configs, selection) do
    indexed = Enum.with_index(configs)
    public = Enum.filter(indexed, fn {config, _index} -> config.authenticated == false end)
    targets = selection_targets(selection)

    if targets == [] do
      public
    else
      Enum.filter(public, fn {config, _index} ->
        Enum.any?(targets, &(config.path == &1 or Atom.to_string(config.name) == &1))
      end)
    end
  end

  defp selection_targets(selection) when is_map(selection) do
    ([selection["default"]] ++
       Enum.map(selection["rules"] || [], & &1["endpoint"]) ++
       Enum.map(selection["cases"] || [], & &1["path"]) ++
       Map.values(selection["by_market_type"] || %{}))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp selection_targets(_selection), do: []

  defp branch(venue, method, js_method, required_params, config, endpoint_index) do
    branch_name = Atom.to_string(config.name)

    %{
      branch: branch_name,
      config: config,
      endpoint_index: endpoint_index,
      js_method: js_method,
      key: Enum.join([venue, js_method, branch_name], "|"),
      method: method,
      required_params: required_params,
      venue: venue
    }
  end

  defp ensure_unique_inventory!(branches) do
    case duplicate_keys(branches) do
      [] -> branches
      duplicates -> raise ArgumentError, "duplicate public request branches: #{inspect(duplicates)}"
    end
  end

  defp validate_safe_branch(branch) do
    config = branch.config
    spec = branch.venue |> Spec.owned_spec_path() |> Spec.decode_file!()
    classification = get_in(spec, ["endpoints", "transaction_classification", branch.js_method])
    exchange = Exchange.new!(branch.venue)
    base_url = Dispatch.resolve_base_url(config.sections, exchange.base_urls)
    uri = base_url && URI.parse(base_url)

    cond do
      config.authenticated != false ->
        {:error, :authenticated_route}

      !is_map(classification) or classification["transactional"] != false ->
        {:error, :transactional_or_unclassified_route}

      config.method not in [:get, :post] ->
        {:error, :unsupported_http_method}

      !match?(%URI{scheme: "https", host: host} when is_binary(host), uri) ->
        {:error, :non_https_provider_route}

      true ->
        :ok
    end
  end

  defp capture_exchange!(venue) do
    exchange = Exchange.new!(venue)
    seed = ReplayExchange.build!(venue, %{})
    markets = if seed.markets in [nil, []], do: fallback_markets(venue), else: seed.markets
    %{exchange | currencies: seed.currencies, markets: markets}
  rescue
    File.Error ->
      exchange = Exchange.new!(venue)
      %{exchange | markets: fallback_markets(venue)}
  end

  defp fallback_markets("alpaca") do
    [
      %{
        "active" => true,
        "base" => "BTC",
        "id" => "BTC/USD",
        "quote" => "USD",
        "spot" => true,
        "symbol" => "BTC/USD"
      }
    ]
  end

  defp fallback_markets("binancecoinm") do
    [
      %{
        "active" => true,
        "base" => "BTC",
        "contract" => true,
        "future" => false,
        "id" => "BTCUSD_PERP",
        "inverse" => true,
        "linear" => false,
        "option" => false,
        "quote" => "USD",
        "settle" => "BTC",
        "spot" => false,
        "swap" => true,
        "symbol" => "BTC/USD:BTC"
      }
    ]
  end

  defp fallback_markets("coinbaseexchange") do
    [
      %{
        "active" => true,
        "base" => "ETH",
        "id" => "ETH-USD",
        "quote" => "USD",
        "spot" => true,
        "symbol" => "ETH-USD"
      }
    ]
  end

  defp fallback_markets(_venue), do: []

  defp replay_inputs(exchange, branch) do
    family = branch_family(branch)

    with {:ok, values, market} <- required_values(branch.required_params, exchange.markets, family) do
      params = Unified.build_params(branch.required_params, values, optional_params(branch))

      markets = if market, do: [json_market(market)], else: []
      {:ok, params, markets}
    end
  end

  defp required_values(names, markets, family) do
    market = if :symbol in names, do: select_market(markets, family)

    values =
      Enum.map(names, fn
        :symbol -> market && market_value(market, "symbol")
        :timeframe -> @ohlcv_timeframe
        :code -> "BTC"
        :id -> "1"
        :type -> family_type(family)
        :sub_type -> family_sub_type(family)
        _other -> nil
      end)

    if Enum.any?(values, &is_nil/1), do: {:error, :required_capture_input_unavailable}, else: {:ok, values, market}
  end

  defp optional_params(branch) do
    now = System.system_time(:millisecond)
    lighter_account? = lighter_account_branch?(branch)

    []
    |> maybe_put("code", if(branch.venue == "deribit" and branch.method == :fetch_tickers, do: "BTC"))
    |> maybe_put("by", if(lighter_account?, do: "index"))
    |> maybe_put("value", if(lighter_account?, do: @lighter_public_account_index))
    |> maybe_put("since", if(history_branch?(branch), do: now - @history_window_ms))
    |> maybe_put("limit", if(history_branch?(branch), do: 10))
  end

  defp lighter_account_branch?(%{venue: "lighter", method: method}) when method in [:fetch_balance, :fetch_positions],
    do: true

  defp lighter_account_branch?(_branch), do: false

  defp maybe_put(entries, _key, nil), do: entries
  defp maybe_put(entries, key, value), do: [{key, value} | entries]

  defp history_branch?(branch) do
    path = String.downcase(branch.config.path)
    String.contains?(path, "history") or String.contains?(path, "and_time")
  end

  defp branch_family(%{venue: "lighter"}), do: :linear

  defp branch_family(branch) do
    value =
      [branch.branch, branch.config.path | branch.config.sections]
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(value, "option") or String.contains?(value, "eapi") -> :option
      String.contains?(value, "dapi") or String.contains?(value, "inverse") -> :inverse
      String.contains?(value, "fapi") or String.contains?(value, "linear") -> :linear
      branch.method in [:fetch_option, :fetch_option_chain, :fetch_greeks] -> :option
      true -> :spot
    end
  end

  defp family_type(:linear), do: "swap"
  defp family_type(:inverse), do: "swap"
  defp family_type(family), do: Atom.to_string(family)
  defp family_sub_type(:linear), do: "linear"
  defp family_sub_type(:inverse), do: "inverse"
  defp family_sub_type(_family), do: nil

  defp select_market(markets, family) when is_list(markets) do
    candidates = Enum.filter(markets, &market_family?(&1, family))
    Enum.find(candidates, &preferred_market?/1) || Enum.find(candidates, &active_market?/1) || List.first(candidates)
  end

  defp select_market(_markets, _family), do: nil

  defp market_family?(market, :spot), do: market_value(market, "spot") == true
  defp market_family?(market, :option), do: market_value(market, "option") == true

  defp market_family?(market, :linear),
    do: market_value(market, "swap") == true and market_value(market, "linear") == true

  defp market_family?(market, :inverse),
    do:
      (market_value(market, "swap") == true or market_value(market, "future") == true) and
        market_value(market, "inverse") == true

  defp preferred_market?(market) do
    market_value(market, "symbol") in [
      "BTC/USDT",
      "BTC/USD",
      "BTC/USDC",
      "BTC/USDT:USDT",
      "BTC/USDC:USDC",
      "BTC/USD:BTC"
    ] and active_market?(market)
  end

  defp active_market?(market), do: market_value(market, "active") != false

  defp market_value(%_struct{} = market, key), do: Map.get(market, String.to_existing_atom(key))
  defp market_value(market, key) when is_map(market), do: Map.get(market, key) || atom_map_value(market, key)
  defp market_value(_market, _key), do: nil

  defp atom_map_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp json_market(%_struct{} = market), do: market |> Map.from_struct() |> stringify_keys()
  defp json_market(market) when is_map(market), do: stringify_keys(market)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp capture_live(exchange, branch, params, timestamp_ms, opts) do
    pacing_ms = Keyword.get(opts, :pacing_ms, @default_pacing_ms)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    transport = Keyword.get(opts, :transport, &default_transport/1)
    adapter = capture_adapter(self(), make_ref(), sleep, pacing_ms, transport)
    do_capture(exchange, branch, params, adapter, timestamp_ms)
  end

  defp capture_replay(exchange, branch, golden) do
    cursors = get_in(golden, ["replay", "pagination_cursors"]) || []
    timestamp_ms = get_in(golden, ["replay", "timestamp_ms_override"])
    counter = :atomics.new(1, [])
    transport = replay_transport(branch.venue, cursors, counter)
    adapter = capture_adapter(self(), make_ref(), fn _milliseconds -> :ok end, 0, transport)
    do_capture(exchange, branch, get_in(golden, ["replay", "params"]), adapter, timestamp_ms)
  end

  defp capture_adapter(parent, reference, sleep, pacing_ms, transport) do
    then(
      fn request ->
        sleep.(pacing_ms)
        {request, response} = transport.(request)
        send(parent, {:public_request_capture, reference, request_map(request), response.status, capture_body(response)})
        {request, response}
      end,
      &{reference, &1}
    )
  end

  defp do_capture(exchange, branch, params, {reference, adapter}, timestamp_ms) do
    opts = [
      adapter: adapter,
      endpoint_index: branch.endpoint_index,
      timestamp_ms_override: timestamp_ms
    ]

    case Unified.capture_responses(exchange, branch.method, params, opts) do
      {:ok, _response} ->
        reference
        |> drain_captures([])
        |> capture_result()

      {:error, reason} ->
        _discarded = drain_captures(reference, [])
        {:error, {:live_call_failed, compact_reason(reason)}}
    end
  end

  defp capture_result([]), do: {:error, :request_not_captured}

  defp capture_result(captures) do
    if Enum.any?(captures, fn {_request, status, _body} -> status != 200 end) do
      {:error, :non_200_response}
    else
      requests = Enum.map(captures, &elem(&1, 0))
      cursors = Enum.map(captures, &capture_cursor/1)
      {:ok, requests, cursors}
    end
  end

  defp capture_cursor({_request, _status, body}), do: pagination_cursor(body)

  defp drain_captures(reference, captures) do
    receive do
      {:public_request_capture, ^reference, request, status, body} ->
        drain_captures(reference, [{request, status, body} | captures])
    after
      if(captures == [], do: @capture_timeout_ms, else: @capture_drain_ms) ->
        Enum.reverse(captures)
    end
  end

  defp pagination_cursor(%{"result" => %{"nextPageCursor" => cursor}}) when is_binary(cursor), do: cursor
  defp pagination_cursor(_body), do: nil

  # The capture adapter replaces Req's transport step, so response steps
  # (decompress/decode) have not run yet — a live venue body arrives as a
  # possibly-gzipped binary. Decode enough to expose pagination cursors.
  defp capture_body(%Req.Response{body: body} = response) when is_binary(body) do
    body
    |> maybe_gunzip(Req.Response.get_header(response, "content-encoding"))
    |> maybe_decode_json()
  end

  defp capture_body(%Req.Response{body: body}), do: body

  defp maybe_gunzip(body, encodings) do
    if Enum.any?(encodings, &String.contains?(&1, "gzip")) do
      :zlib.gunzip(body)
    else
      body
    end
  rescue
    ErlangError -> body
  end

  defp maybe_decode_json(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp replay_transport(venue, cursors, counter) do
    fn request ->
      index = :atomics.add_get(counter, 1, 1) - 1
      cursor = Enum.at(cursors, index)
      body = success_stub(venue, cursor)
      {request, Req.Response.new(status: 200, body: body)}
    end
  end

  defp success_stub("bybit", cursor),
    do: %{"retCode" => 0, "retMsg" => "OK", "result" => %{"list" => [], "nextPageCursor" => cursor || ""}}

  defp success_stub("deribit", _cursor), do: %{"jsonrpc" => "2.0", "result" => %{}}
  defp success_stub("derive", _cursor), do: %{"id" => "fixture", "result" => []}
  defp success_stub("hyperliquid", _cursor), do: %{"status" => "ok", "response" => %{}}
  defp success_stub("lighter", _cursor), do: %{"code" => 200}
  defp success_stub("okx", _cursor), do: %{"code" => "0", "data" => [], "msg" => ""}
  defp success_stub(_venue, _cursor), do: %{}

  # Req owns these header values (the user-agent carries Req's version and the
  # accept-encoding set moved into the Req.Finch adapter in 0.7); no venue signs
  # them, so they are excluded from acceptance evidence to keep goldens stable
  # across Req upgrades.
  @transport_owned_headers ~w(accept-encoding user-agent)

  # A plug-stubbed base client must never reach the network, even though the
  # capture adapter overrides the client's adapter slot.
  defp default_transport(request) do
    if request.options[:plug], do: Req.Plug.run(request), else: Req.Finch.run(request)
  end

  defp request_map(request) do
    headers =
      request
      |> Req.get_headers_list()
      |> Enum.map(&Tuple.to_list/1)
      |> Enum.reject(fn [name, _value] -> name in @transport_owned_headers end)
      |> Enum.sort()

    %{
      "body" => normalize_body(request.body),
      "headers" => headers,
      "method" => request.method |> to_string() |> String.upcase(),
      "url" => URI.to_string(request.url)
    }
  end

  defp normalize_body(nil), do: nil
  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body), do: IO.iodata_to_binary(body)

  defp golden(branch, params, markets, requests, cursors, captured_at, timestamp_ms) do
    captured_at = captured_at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    first_uri = requests |> hd() |> Map.fetch!("url") |> URI.parse()

    %{
      "acceptance" => %{
        "branch" => branch.branch,
        "capture_date" => String.slice(captured_at, 0, 10),
        "captured_at" => captured_at,
        "endpoint" => branch.config.path,
        "host" => first_uri.host,
        "http_status" => 200,
        "method" => branch.js_method,
        "sections" => branch.config.sections,
        "venue" => branch.venue
      },
      "oracle" => "public_exchange_acceptance",
      "replay" => %{
        "markets" => markets,
        "pagination_cursors" => cursors,
        "params" => params,
        "timestamp_ms_override" => timestamp_ms
      },
      "requests" => requests,
      "schema_version" => @schema_version
    }
  end

  defp exclusion(branch, captured_at, reason) do
    %{
      "branch" => branch.branch,
      "capture_date" => captured_at |> DateTime.to_date() |> Date.to_iso8601(),
      "endpoint" => branch.config.path,
      "method" => branch.js_method,
      "reason" => compact_reason(reason),
      "sections" => branch.config.sections,
      "venue" => branch.venue
    }
  end

  defp compact_reason(%Bourse.Error{type: type, code: code}), do: "#{type}:#{code || "no_code"}"
  defp compact_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 240)
  defp compact_reason(reason), do: reason |> inspect(limit: 8, printable_limit: 240) |> String.slice(0, 240)

  defp validate_route(golden) do
    with {:ok, branch} <- branch_for_golden(golden),
         :ok <- validate_safe_branch(branch),
         {:ok, exchange} <- replay_exchange(golden),
         true <- golden["schema_version"] == @schema_version,
         true <- get_in(golden, ["acceptance", "http_status"]) == 200,
         [_ | _] = requests <- golden["requests"],
         true <- Enum.all?(requests, &request_matches_branch?(&1, branch, golden, exchange)) do
      :ok
    else
      # Keep the construction diagnostic — a venue that cannot even be built is
      # a different failure than a request that does not match its route.
      {:error, {:replay_exchange_failed, _message} = reason} -> {:error, reason}
      false -> {:error, :route_identity_mismatch}
      _other -> {:error, :invalid_route_identity}
    end
  end

  defp branch_for_golden(golden) do
    acceptance = golden["acceptance"] || %{}
    key = branch_key(acceptance)

    case Enum.find(inventory(acceptance["venue"] || ""), &(branch_key(&1) == key)) do
      nil -> {:error, :unknown_authored_branch}
      branch -> {:ok, branch}
    end
  rescue
    # Intentional: any inventory/spec lookup failure for the declared identity is an unknown branch.
    # reach:disable-next-line bare_rescue
    _error -> {:error, :unknown_authored_branch}
  end

  defp request_matches_branch?(request, branch, golden, exchange) do
    base_url = Dispatch.resolve_base_url(branch.config.sections, exchange.base_urls)
    base_uri = base_url && URI.parse(base_url)
    request_uri = request["url"] && URI.parse(request["url"])

    request_matches_route?(request, branch, golden, exchange, base_uri, request_uri)
  end

  defp request_matches_route?(
         request,
         branch,
         golden,
         exchange,
         %URI{scheme: "https", host: base_host} = base_uri,
         %URI{scheme: "https", host: request_host} = request_uri
       )
       when is_binary(base_host) and is_binary(request_host) do
    expected_method = branch.config.method |> Atom.to_string() |> String.upcase()
    expected_path = expected_path(base_uri, branch, exchange, get_in(golden, ["replay", "params"]) || %{})

    Enum.all?([
      request["method"] == expected_method,
      request_host == base_host,
      request_uri.port == base_uri.port,
      request_uri.path == expected_path,
      get_in(golden, ["acceptance", "host"]) == request_host
    ])
  end

  defp request_matches_route?(_request, _branch, _golden, _exchange, _base_uri, _request_uri), do: false

  defp expected_path(base_uri, branch, exchange, params) do
    params =
      params
      |> RequestShape.apply_premarket(exchange, branch.js_method)
      |> Unified.maybe_denormalize_symbol(exchange)
      |> Unified.maybe_translate_timeframe(exchange)
      |> Unified.maybe_merge_request_defaults(exchange, branch.js_method)
      |> RequestShape.apply(exchange, branch.js_method, endpoint_path: branch.config.path)

    {path, _remaining} = Dispatch.interpolate_path(branch.config.path, params)

    [base_uri.path, branch.config.url_prefix, path]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("/")
    |> String.replace(~r{/+}, "/")
    |> then(&if(String.starts_with?(&1, "/"), do: &1, else: "/" <> &1))
  end

  defp replay_exchange(golden) do
    venue = get_in(golden, ["acceptance", "venue"])
    exchange = Exchange.new!(venue)
    markets = get_in(golden, ["replay", "markets"]) || []
    {:ok, %{exchange | markets: markets}}
  rescue
    # Intentional: any exchange construction failure is surfaced as a uniform replay error.
    # reach:disable-next-line bare_rescue
    error -> {:error, {:replay_exchange_failed, Exception.message(error)}}
  end

  defp request_violations({request, index}) do
    path = "$.requests[#{index}]"
    header_errors = sensitive_pair_errors(request["headers"] || [], "#{path}.headers")
    uri = URI.parse(request["url"] || "")
    query_errors = (uri.query || "") |> URI.decode_query() |> Map.to_list() |> sensitive_pair_errors("#{path}.query")
    body_errors = body_violations(request["body"], "#{path}.body")
    userinfo_errors = if uri.userinfo in [nil, ""], do: [], else: ["#{path}.url.userinfo"]
    header_errors ++ query_errors ++ body_errors ++ userinfo_errors
  end

  defp sensitive_pair_errors(pairs, path) do
    pairs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {[name, value], index} -> sensitive_pair_error(name, value, "#{path}[#{index}]")
      {{name, value}, index} -> sensitive_pair_error(name, value, "#{path}[#{index}]")
      {_other, index} -> ["#{path}[#{index}] malformed"]
    end)
  end

  defp sensitive_pair_error(name, value, path) do
    if sensitive_name?(name) or forbidden_value?(value), do: [path], else: []
  end

  defp body_violations(nil, _path), do: []

  defp body_violations(body, path) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> nested_violations(decoded, path)
      {:error, _reason} -> if(forbidden_value?(body), do: [path], else: [])
    end
  end

  defp nested_violations(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      child = "#{path}.#{key}"
      nested = nested_violations(value, child)
      if sensitive_name?(key) or forbidden_value?(value), do: [child | nested], else: nested
    end)
  end

  defp nested_violations(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> nested_violations(value, "#{path}[#{index}]") end)
  end

  defp nested_violations(_value, _path), do: []

  defp sensitive_name?(name), do: MapSet.member?(@sensitive_names, normalize_name(name))
  defp normalize_name(name), do: name |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp forbidden_material_violations(golden) do
    serialized = Jason.encode!(golden)
    Enum.flat_map(@credential_env_names, &forbidden_environment_material(&1, serialized))
  end

  defp forbidden_environment_material(env_name, serialized) do
    case System.get_env(env_name) do
      value when is_binary(value) and value != "" ->
        if String.contains?(serialized, value), do: ["$.env.#{env_name}"], else: []

      _other ->
        []
    end
  end

  defp forbidden_value?(value) when is_binary(value) do
    Enum.any?(@credential_env_names, fn name ->
      case System.get_env(name) do
        secret when is_binary(secret) and secret != "" -> value == secret or String.contains?(value, secret)
        _other -> false
      end
    end)
  end

  defp forbidden_value?(_value), do: false

  defp branch_key(%{key: key}), do: key

  defp branch_key(row) when is_map(row) do
    Enum.join([row["venue"], row["method"], row["branch"]], "|")
  end

  defp duplicate_errors(rows) do
    rows
    |> duplicate_keys()
    |> Enum.map(&"duplicate branch #{&1}")
  end

  defp duplicate_keys(rows) do
    rows
    |> Enum.group_by(&branch_key/1)
    |> Enum.filter(fn {_key, grouped} -> length(grouped) > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp set_errors(expected, actual) do
    missing = expected |> MapSet.difference(actual) |> Enum.sort() |> Enum.map(&"missing branch #{&1}")
    extra = actual |> MapSet.difference(expected) |> Enum.sort() |> Enum.map(&"unknown branch #{&1}")
    missing ++ extra
  end

  defp row_errors(goldens, exclusions) do
    golden_errors =
      Enum.flat_map(goldens, fn row ->
        []
        |> maybe_error(row["http_status"] != 200, "#{branch_key(row)} golden status is not 200")
        |> maybe_error(!valid_date?(row["capture_date"]), "#{branch_key(row)} golden capture_date is invalid")
        |> maybe_error(!is_binary(row["host"]) or row["host"] == "", "#{branch_key(row)} golden host is missing")
        |> maybe_error(!is_binary(row["endpoint"]) or row["endpoint"] == "", "#{branch_key(row)} endpoint is missing")
      end)

    exclusion_errors =
      Enum.flat_map(exclusions, fn row ->
        []
        |> maybe_error(!valid_date?(row["capture_date"]), "#{branch_key(row)} exclusion capture_date is invalid")
        |> maybe_error(!is_binary(row["reason"]) or row["reason"] == "", "#{branch_key(row)} exclusion reason is missing")
      end)

    golden_errors ++ exclusion_errors
  end

  defp file_errors(nil, _goldens), do: []

  defp file_errors(root, goldens) do
    declared = MapSet.new(goldens, & &1["path"])

    actual =
      root
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "_manifest.json"))
      |> MapSet.new(&Path.relative_to(&1, root))

    missing = declared |> MapSet.difference(actual) |> Enum.sort() |> Enum.map(&"missing golden file #{&1}")
    orphaned = actual |> MapSet.difference(declared) |> Enum.sort() |> Enum.map(&"orphaned golden file #{&1}")

    identity =
      Enum.flat_map(goldens, fn row ->
        path = Path.join(root, row["path"])

        if File.regular?(path) do
          golden = JsonDocument.decode_file!(path)
          acceptance = golden["acceptance"] || %{}

          cond do
            Map.delete(row, "path") != acceptance -> ["#{row["path"]} identity mismatch"]
            scrub_violations(golden) != [] -> ["#{row["path"]} contains sensitive material"]
            validate_route(golden) != :ok -> ["#{row["path"]} route mismatch"]
            true -> []
          end
        else
          []
        end
      end)

    missing ++ orphaned ++ identity
  end

  defp valid_date?(date) when is_binary(date), do: match?({:ok, _date}, Date.from_iso8601(date))
  defp valid_date?(_date), do: false

  defp maybe_error(errors, false, _message), do: errors
  defp maybe_error(errors, true, message), do: [message | errors]
end
