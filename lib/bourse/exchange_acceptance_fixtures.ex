defmodule Bourse.ExchangeAcceptanceFixtures do
  @moduledoc """
  Records and replays fixture-signed requests whose live equivalents exchanges accepted.

  Live request material stays in memory. A golden contains the same request rebuilt
  with committed fixture credentials and frozen clock overrides, never live keys or
  signature bytes.
  """

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.JsonDocument
  alias Bourse.OracleLabel
  alias Bourse.RecordedResponseFixtures.LighterMarket
  alias Bourse.ReplayExchange
  alias Bourse.Unified

  @schema_version 1
  @fixture_root Path.expand("../../test/fixtures/exchange_accepted_requests", __DIR__)
  @accepted_http_statuses 200..299
  @fixture_http_status 200
  @auth_marker "__FIXTURE_AUTH_SLOT__"
  @capture_receive_timeout_ms 1_000
  @no_extra_request_wait_ms 0
  @acceptance_nonce_offset_ms 1
  @binance_order_history_limit 25
  @binance_order_history_window_ms 3_600_000
  @binance_conditional_order_amount 0.02
  @binance_take_profit_trigger_ratio 1.15
  @binance_conditional_price_decimal_places 2
  @derive_subaccount_id 144_422
  @bybit_order_amount 0.1444444234234234
  @bybit_price_ratio 0.99
  @bybit_price_decimal_places 2
  @bybit_unrounded_increment 0.003
  @hyperliquid_order_amount 0.001
  @hyperliquid_price_ratio 0.5
  @hyperliquid_price_decimal_places 0
  @lighter_auth_lifetime_seconds 300
  @first_class_venues ~w(alpaca binance binancecoinm binanceusdm bybit deribit derive hyperliquid lighter okx)

  @type golden :: %{required(String.t()) => term()}
  @type transport :: (Req.Request.t() -> {Req.Request.t(), Req.Response.t() | Exception.t()})
  @type record_option :: {:transport, transport()}

  @doc "Returns the ten first-class venues covered by this oracle."
  @spec first_class_venues() :: [String.t()]
  def first_class_venues, do: @first_class_venues

  @doc "Returns every configured `{venue, method}` signed acceptance profile."
  @spec profiles() :: [{String.t(), atom()}]
  def profiles do
    Enum.flat_map(@first_class_venues, fn venue ->
      Enum.map(profiles_for(venue), &{venue, &1.method})
    end)
  end

  @doc "Returns the accepted-request fixture root."
  @spec fixture_root() :: Path.t()
  def fixture_root, do: @fixture_root

  @doc "Returns the accepted-request manifest path."
  @spec manifest_path() :: Path.t()
  def manifest_path, do: Path.join(@fixture_root, "_manifest.json")

  @doc "Returns one venue's accepted-request golden path."
  @spec fixture_path(String.t()) :: Path.t()
  def fixture_path(venue) when venue in @first_class_venues do
    case profiles_for(venue) do
      [profile] -> fixture_path(venue, profile.method)
      _profiles -> raise ArgumentError, "#{venue} has multiple accepted-request profiles; provide the method"
    end
  end

  @doc "Returns one signed profile's accepted-request golden path."
  @spec fixture_path(String.t(), atom()) :: Path.t()
  def fixture_path(venue, method) when venue in @first_class_venues and is_atom(method) do
    _profile = profile!(venue, method)
    Path.join([@fixture_root, venue, "#{method}.json"])
  end

  @doc "Loads every golden named by the manifest."
  @spec load_all!() :: [golden()]
  def load_all! do
    manifest_path()
    |> JsonDocument.decode_file!()
    |> Map.fetch!("goldens")
    |> Enum.map(fn %{"path" => path} -> @fixture_root |> Path.join(path) |> JsonDocument.decode_file!() end)
  end

  @doc "Calls a venue with one signed profile and returns its fixture-signed golden."
  @spec record(String.t(), [record_option()]) :: {:ok, golden()} | {:error, term()}
  def record(venue, opts \\ []) when venue in @first_class_venues and is_list(opts) do
    case profiles_for(venue) do
      [profile] -> record_profile(profile, opts)
      _profiles -> {:error, {:multiple_acceptance_profiles, venue}}
    end
  end

  @doc "Calls every signed profile for one venue and returns safe fixture-signed goldens."
  @spec record_all(String.t(), [record_option()]) :: {:ok, [golden()]} | {:error, term()}
  def record_all(venue, opts \\ []) when venue in @first_class_venues and is_list(opts) do
    venue
    |> profiles_for()
    |> Enum.reduce_while({:ok, []}, fn profile, {:ok, goldens} ->
      case record_profile(profile, opts) do
        {:ok, golden} -> {:cont, {:ok, [golden | goldens]}}
        {:error, reason} -> {:halt, {:error, {profile.method, reason}}}
      end
    end)
    |> case do
      {:ok, goldens} -> {:ok, Enum.reverse(goldens)}
      {:error, _reason} = error -> error
    end
  end

  defp record_profile(profile, opts) do
    with {:ok, credentials} <- live_credentials(profile),
         {:ok, exchange} <- build_live_exchange(profile, credentials),
         {:ok, exchange} <- prepare_live_exchange(exchange, profile),
         {:ok, params, replay_context} <- request_params(exchange, profile) do
      clock = frozen_clock()

      case capture_live(exchange, profile, params, clock, opts) do
        {:ok, response, live_request, cleanup} ->
          result = build_golden(profile, params, replay_context, clock, response, live_request, credentials)
          finish_with_cleanup(result, exchange, profile, cleanup)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Deterministically rebuilds and checks one committed fixture-signed golden."
  @spec replay(golden()) :: :ok | {:error, term()}
  def replay(%{"acceptance" => %{"venue" => venue}, "replay" => replay, "request" => primary} = golden)
      when venue in @first_class_venues do
    expected = [primary | Map.get(golden, "additional_requests", [])]

    with {:ok, method} <- method_atom(replay["method"]),
         profile = profile!(venue, method),
         :ok <- validate_replay_identity(profile, replay),
         {:ok, exchange} <- build_fixture_exchange(profile, replay),
         {:ok, actual} <- capture_fixture_request(exchange, profile, replay) do
      compare_fixture_requests(expected, actual, profile)
    end
  end

  @doc "Rejects a term containing any supplied live credential or authentication value."
  @spec validate_no_material(term(), [String.t()]) :: :ok | {:error, :sensitive_material_present}
  def validate_no_material(value, forbidden_values) when is_list(forbidden_values) do
    forbidden_values = Enum.filter(forbidden_values, &(is_binary(&1) and &1 != ""))

    if Enum.any?(forbidden_values, &contains_material?(value, &1)) do
      {:error, :sensitive_material_present}
    else
      :ok
    end
  end

  defp profiles_for("alpaca"), do: [alpaca_market_profile(), alpaca_trader_profile()]

  defp profiles_for("binance") do
    [
      binance_balance_profile(),
      binance_order_history_profile(),
      binance_take_profit_order_profile(),
      binance_margin_mode_profile(),
      binance_cancel_all_orders_profile()
    ]
  end

  defp profiles_for(venue), do: [profile(venue)]

  defp profile!(venue, method) do
    Enum.find(profiles_for(venue), &(&1.method == method)) ||
      raise ArgumentError, "unknown accepted-request profile #{venue}/#{method}"
  end

  defp alpaca_market_profile do
    build_profile("alpaca", :fetch_ticker, "v2/stocks/{symbol}/snapshot", "data.alpaca.markets", :alpaca,
      sandbox: false,
      fixture_seed: :empty,
      params: %{"symbol" => "GLD"},
      sensitive_headers: ["apca-api-key-id", "apca-api-secret-key"],
      business_success: "HTTP 2xx stock snapshot payload"
    )
  end

  defp alpaca_trader_profile do
    build_profile("alpaca", :fetch_balance, "v2/account", "paper-api.alpaca.markets", :alpaca,
      sandbox: true,
      fixture_seed: :empty,
      sensitive_headers: ["apca-api-key-id", "apca-api-secret-key"],
      business_success: "HTTP 2xx paper-account payload"
    )
  end

  defp binance_balance_profile do
    build_profile("binance", :fetch_balance, "fapi/v3/account", "demo-fapi.binance.com", :binanceusdm,
      sandbox: true,
      params: %{"type" => :swap},
      sensitive_headers: ["x-mbx-apikey"],
      sensitive_query: ["signature"],
      stub_body: %{"assets" => [], "positions" => []},
      business_success: "HTTP 2xx USD-M account payload without an error code"
    )
  end

  defp binance_order_history_profile do
    build_profile("binance", :fetch_orders, "api/v3/allOrders", "testnet.binance.vision", :binance,
      sandbox: true,
      params: :binance_order_history,
      sensitive_headers: ["x-mbx-apikey"],
      sensitive_query: ["signature"],
      stub_body: [],
      business_success: "HTTP 2xx filtered order-history list without an error code"
    )
  end

  defp binance_take_profit_order_profile do
    build_profile("binance", :create_order, "fapi/v1/algoOrder", "demo-fapi.binance.com", :binanceusdm,
      sandbox: true,
      params: :binance_take_profit_order,
      sensitive_headers: ["x-mbx-apikey"],
      sensitive_query: ["signature"],
      stub_body: %{
        "algoId" => 1,
        "algoStatus" => "NEW",
        "algoType" => "CONDITIONAL",
        "orderType" => "TAKE_PROFIT_MARKET",
        "symbol" => "ETHUSDT"
      },
      symbol: "ETH/USDT:USDT",
      business_success: "HTTP 2xx resting take-profit order with an algo id; accepted order cancelled"
    )
  end

  defp binance_margin_mode_profile do
    build_profile("binance", :set_margin_mode, "fapi/v1/marginType", "demo-fapi.binance.com", :binanceusdm,
      sandbox: true,
      params: %{"margin_mode" => "cross", "symbol" => "ETH/USDT:USDT"},
      sensitive_headers: ["x-mbx-apikey"],
      sensitive_query: ["signature"],
      stub_body: %{"code" => 200, "msg" => "success"},
      business_success: "code=200 margin-mode update; original isolated mode restored"
    )
  end

  defp binance_cancel_all_orders_profile do
    build_profile(
      "binance",
      :cancel_all_orders,
      "fapi/v1/allOpenOrders",
      "demo-fapi.binance.com",
      :binanceusdm,
      sandbox: true,
      params: %{"symbol" => "ETH/USDT:USDT"},
      sensitive_headers: ["x-mbx-apikey"],
      sensitive_query: ["signature"],
      stub_body: %{"code" => 200, "msg" => "The operation of cancel all open order is done."},
      business_success: "code=200 symbol-scoped cancel-all acknowledgement"
    )
  end

  defp profile("binanceusdm") do
    build_profile(
      "binanceusdm",
      :fetch_balance,
      "fapi/v3/account",
      "demo-fapi.binance.com",
      :binanceusdm,
      sandbox: true,
      sensitive_headers: ["x-mbx-apikey"],
      sensitive_query: ["signature"],
      business_success: "HTTP 2xx futures account payload without an error code"
    )
  end

  defp profile("binancecoinm") do
    build_profile(
      "binancecoinm",
      :fetch_balance,
      "dapi/v1/account",
      "demo-dapi.binance.com",
      :binanceusdm,
      sandbox: true,
      fixture_seed: :empty,
      sensitive_headers: ["x-mbx-apikey"],
      sensitive_query: ["signature"],
      business_success: "HTTP 2xx COIN-M account payload without an error code"
    )
  end

  defp profile("deribit") do
    build_profile("deribit", :fetch_balance, "private/get_account_summaries", "test.deribit.com", :deribit,
      sandbox: true,
      sensitive_headers: ["authorization"],
      business_success: "JSON-RPC result map with no error member"
    )
  end

  # Canonical OKX acceptance host: www.okx.com international demo with OKX_INTL_*
  # credentials (sandbox: true supplies the host and the x-simulated-trading header).
  # Replay rebuilds from this profile, so the committed golden must be recorded
  # against the same host — a host change requires re-earning live acceptance.
  defp profile("okx") do
    build_profile("okx", :fetch_balance, "api/v5/account/balance", "www.okx.com", :okx,
      sandbox: true,
      sensitive_headers: ["ok-access-key", "ok-access-sign", "ok-access-passphrase"],
      business_success: "code=0"
    )
  end

  defp profile("derive") do
    build_profile("derive", :fetch_balance, "private/get_all_portfolios", "api-demo.lyra.finance", :derive,
      sandbox: true,
      exchange_opts: [options: %{"subaccount_id" => @derive_subaccount_id}],
      sensitive_body: ["wallet"],
      sensitive_headers: ["x-lyrawallet", "x-lyrasignature"],
      business_success: "JSON-RPC result list with no error member"
    )
  end

  defp profile("bybit") do
    build_profile("bybit", :create_order, "v5/order/create", "api-demo.bybit.com", :bybit,
      sandbox: false,
      call_opts: [base_url: "https://api-demo.bybit.com"],
      params: :bybit_order,
      prepare: :fixture_markets,
      sensitive_headers: ["x-bapi-api-key", "x-bapi-sign"],
      stub_body: %{"retCode" => 0, "retMsg" => "OK", "result" => %{"orderId" => "fixture-order"}},
      symbol: "LTC/USDT",
      business_success: "retCode=0 with orderId; accepted order cancelled"
    )
  end

  defp profile("hyperliquid") do
    build_profile("hyperliquid", :create_order, "exchange:order", "api.hyperliquid-testnet.xyz", :hyperliquid,
      sandbox: true,
      params: :hyperliquid_order,
      prepare: :live_markets,
      sensitive_body: ["signature"],
      stub_body: %{
        "status" => "ok",
        "response" => %{
          "type" => "order",
          "data" => %{"statuses" => [%{"resting" => %{"oid" => 1}}]}
        }
      },
      symbol: "BTC/USDC:USDC",
      business_success: "status=ok with resting oid; accepted order cancelled"
    )
  end

  defp profile("lighter") do
    build_profile(
      "lighter",
      :fetch_closed_orders,
      "accountInactiveOrders",
      "testnet.zklighter.elliot.ai",
      :lighter,
      sandbox: true,
      params: :lighter_closed_orders,
      prepare: :live_markets,
      sensitive_headers: ["authorization"],
      stub_body: %{"code" => 200, "orders" => []},
      symbol: "ETH/USDC:USDC",
      business_success: "code=200 authenticated inactive-order payload"
    )
  end

  defp build_profile(venue, method, endpoint, host, credential_profile, opts) do
    %{
      business_success: Keyword.fetch!(opts, :business_success),
      call_opts: Keyword.get(opts, :call_opts, []),
      credential_env: credential_env(credential_profile),
      endpoint: endpoint,
      exchange_opts: Keyword.get(opts, :exchange_opts, []),
      fixture_seed: Keyword.get(opts, :fixture_seed, :static),
      host: host,
      method: method,
      params: Keyword.get(opts, :params, %{}),
      prepare: Keyword.get(opts, :prepare, :none),
      sandbox: Keyword.fetch!(opts, :sandbox),
      sensitive_body: Keyword.get(opts, :sensitive_body, []),
      sensitive_headers: Keyword.get(opts, :sensitive_headers, []),
      sensitive_query: Keyword.get(opts, :sensitive_query, []),
      stub_body: Keyword.get_lazy(opts, :stub_body, fn -> success_stub(venue) end),
      symbol: Keyword.get(opts, :symbol),
      venue: venue
    }
  end

  defp credential_env(:binance), do: [api_key: "BINANCE_TESTNET_API_KEY", secret: "BINANCE_TESTNET_API_SECRET"]

  defp credential_env(:binanceusdm),
    do: [api_key: "BINANCE_FUTURES_TEST_API_KEY", secret: "BINANCE_FUTURES_TEST_API_SECRET"]

  defp credential_env(:bybit), do: [api_key: "BYBIT_DEMO_API_KEY", secret: "BYBIT_DEMO_API_SECRET"]

  defp credential_env(:deribit), do: [api_key: "DERIBIT_TESTNET_API_KEY", secret: "DERIBIT_TESTNET_API_SECRET"]

  defp credential_env(:okx),
    do: [api_key: "OKX_INTL_API_KEY", secret: "OKX_INTL_API_SECRET", password: "OKX_INTL_PASSPHRASE"]

  defp credential_env(:hyperliquid),
    do: [api_key: "HYPERLIQUID_TESTNET_API_KEY", secret: "HYPERLIQUID_TESTNET_API_SECRET"]

  defp credential_env(:derive), do: [api_key: "DERIVE_TESTNET_API_KEY", secret: "DERIVE_TESTNET_API_SECRET"]

  defp credential_env(:lighter) do
    [
      api_key: "LIGHTER_TESTNET_API_KEY_INDEX",
      uid: "LIGHTER_TESTNET_ACCOUNT_INDEX",
      secret: "LIGHTER_TESTNET_API_PRIVATE_KEY"
    ]
  end

  defp credential_env(:alpaca), do: [api_key: "ALPACA_API_KEY", secret: "ALPACA_API_SECRET"]

  defp success_stub("binance"), do: %{"balances" => []}
  defp success_stub("binancecoinm"), do: %{"assets" => [], "positions" => []}
  defp success_stub("binanceusdm"), do: %{"assets" => [], "positions" => []}
  defp success_stub("deribit"), do: %{"jsonrpc" => "2.0", "result" => %{}}
  defp success_stub("okx"), do: %{"code" => "0", "data" => [], "msg" => ""}
  defp success_stub("derive"), do: %{"id" => "fixture", "result" => []}
  defp success_stub("alpaca"), do: %{"currency" => "USD", "equity" => "1"}

  defp live_credentials(profile) do
    missing = for {_field, env_name} <- profile.credential_env, System.get_env(env_name) in [nil, ""], do: env_name

    if missing == [] do
      opts = Enum.map(profile.credential_env, fn {field, env_name} -> {field, System.fetch_env!(env_name)} end)
      {:ok, Credentials.new!(opts)}
    else
      {:error, {:missing_credentials, missing}}
    end
  end

  defp build_live_exchange(profile, credentials) do
    opts = Keyword.put(profile.exchange_opts, :credentials, credentials)
    Exchange.new(profile.venue, Keyword.put(opts, :sandbox, profile.sandbox))
  end

  defp prepare_live_exchange(exchange, %{prepare: :none}), do: {:ok, exchange}

  defp prepare_live_exchange(exchange, %{prepare: :fixture_markets, venue: venue}) do
    fixture_exchange = ReplayExchange.build!(venue, %{})
    {:ok, %{exchange | markets: fixture_exchange.markets, currencies: fixture_exchange.currencies}}
  end

  defp prepare_live_exchange(exchange, %{prepare: :live_markets}) do
    Unified.load_markets(exchange)
  end

  defp request_params(_exchange, %{params: :binance_order_history}) do
    params = %{
      "limit" => @binance_order_history_limit,
      "since" => System.system_time(:millisecond) - @binance_order_history_window_ms,
      "symbol" => "BTC/USDT"
    }

    {:ok, params, %{}}
  end

  defp request_params(exchange, %{params: :binance_take_profit_order}) do
    case Bourse.Binance.fapiPublic_get_ticker_24hr(exchange, %{"symbol" => "ETHUSDT"}) do
      {:ok, %{body: %{"lastPrice" => last_price}}} ->
        case Float.parse(last_price) do
          {last, ""} ->
            trigger_price = binance_conditional_price(last, @binance_take_profit_trigger_ratio)

            {:ok,
             %{
               "amount" => @binance_conditional_order_amount,
               "side" => "sell",
               "symbol" => "ETH/USDT:USDT",
               "take_profit_price" => trigger_price,
               "type" => "market"
             }, %{}}

          _other ->
            {:error, :binance_take_profit_order_inputs_unavailable}
        end

      _other ->
        {:error, :binance_take_profit_order_inputs_unavailable}
    end
  end

  defp request_params(_exchange, %{params: params}) when is_map(params), do: {:ok, params, %{}}

  defp request_params(exchange, %{params: :lighter_closed_orders, symbol: symbol}) do
    account_index = LighterMarket.credential_integer!(exchange.credentials.uid)

    with {:ok, market_id} <- LighterMarket.market_id(exchange.markets, symbol) do
      {:ok,
       %{
         "account_index" => account_index,
         "auth_deadline" => System.system_time(:second) + @lighter_auth_lifetime_seconds,
         "market_id" => market_id
       }, %{}}
    end
  end

  defp request_params(exchange, %{params: :bybit_order} = profile) do
    with {:ok, %Bourse.OrderBook{bids: [[bid | _] | _]}} <-
           Bourse.fetch_order_book(exchange, profile.symbol, profile.call_opts),
         true <- is_number(bid) do
      accepted_price = bid |> Kernel.*(@bybit_price_ratio) |> Float.round(@bybit_price_decimal_places)

      params = %{
        "amount" => @bybit_order_amount,
        "price" => accepted_price + @bybit_unrounded_increment,
        "side" => "buy",
        "symbol" => profile.symbol,
        "type" => "limit"
      }

      {:ok, params, %{}}
    else
      _other -> {:error, :bybit_order_inputs_unavailable}
    end
  end

  defp request_params(exchange, %{params: :hyperliquid_order}) do
    symbol = "BTC/USDC:USDC"

    with {:ok, %Bourse.OrderBook{bids: [[bid | _] | _], asks: [[ask | _] | _]}} <-
           Bourse.fetch_order_book(exchange, symbol),
         true <- is_number(bid) and is_number(ask),
         market when not is_nil(market) <- Enum.find(exchange.markets, &(&1.symbol == symbol)) do
      mid = (bid + ask) / 2
      price = mid |> Kernel.*(@hyperliquid_price_ratio) |> Float.round(@hyperliquid_price_decimal_places) |> trunc()

      params = %{
        "amount" => @hyperliquid_order_amount,
        "price" => price,
        "side" => "buy",
        "symbol" => symbol,
        "type" => "limit"
      }

      {:ok, params, %{"market_asset_index" => market.asset_index}}
    else
      _other -> {:error, :hyperliquid_order_inputs_unavailable}
    end
  end

  defp binance_conditional_price(last, ratio) do
    last
    |> Kernel.*(ratio)
    |> Float.floor(@binance_conditional_price_decimal_places)
    |> :erlang.float_to_binary(decimals: @binance_conditional_price_decimal_places)
  end

  defp frozen_clock do
    timestamp_ms = System.system_time(:millisecond)
    %{"nonce" => timestamp_ms + @acceptance_nonce_offset_ms, "timestamp_ms" => timestamp_ms}
  end

  defp capture_live(exchange, profile, params, clock, opts) do
    reference = make_ref()
    transport = Keyword.get(opts, :transport, &default_transport/1)
    adapter = network_capture_adapter(self(), reference, transport)

    case dispatch_capture(exchange, profile, params, clock, adapter) do
      {:ok, response} ->
        with {:ok, requests} <- captured_requests(reference, profile),
             {:ok, cleanup} <- accepted_response(profile, response) do
          {:ok, response, requests, cleanup}
        end

      {:error, %Bourse.Error{type: type, code: code}} ->
        {:error, {:live_call_failed, type, code}}

      {:error, _reason} ->
        {:error, :live_call_failed}
    end
  end

  defp network_capture_adapter(parent, reference, transport) do
    fn request ->
      send(parent, {:accepted_request_capture, reference, request_map(request)})
      transport.(request)
    end
  end

  defp fixture_capture_adapter(parent, reference, body) do
    fn request ->
      send(parent, {:accepted_request_capture, reference, request_map(request)})
      {request, Req.Response.new(status: @fixture_http_status, body: body)}
    end
  end

  defp dispatch_capture(exchange, profile, params, clock, adapter) do
    opts =
      Keyword.merge(profile.call_opts,
        adapter: adapter,
        nonce_override: clock["nonce"],
        timestamp_ms_override: clock["timestamp_ms"]
      )

    Unified.capture_responses(exchange, profile.method, params, opts)
  end

  defp captured_requests(reference, profile) do
    receive do
      {:accepted_request_capture, ^reference, request} ->
        drain_captured_requests(reference, [request], profile)
    after
      @capture_receive_timeout_ms -> {:error, :request_not_captured}
    end
  end

  defp drain_captured_requests(reference, requests, profile) do
    receive do
      {:accepted_request_capture, ^reference, request} ->
        drain_captured_requests(reference, [request | requests], profile)
    after
      @no_extra_request_wait_ms -> order_captured_requests(Enum.reverse(requests), profile)
    end
  end

  defp order_captured_requests([request], _profile), do: {:ok, [request]}

  defp order_captured_requests(requests, profile) do
    expected_path = "/#{profile.endpoint}"
    {primary, additional} = Enum.split_with(requests, &(URI.parse(&1["url"]).path == expected_path))

    case primary do
      [request] -> {:ok, [request | Enum.sort_by(additional, & &1["url"])]}
      _other -> {:error, :primary_request_not_captured}
    end
  end

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
      "body" => normalize_request_body(request.body),
      "headers" => headers,
      "method" => request.method |> to_string() |> String.upcase(),
      "url" => URI.to_string(request.url)
    }
  end

  defp normalize_request_body(nil), do: nil
  defp normalize_request_body(body) when is_binary(body), do: body
  defp normalize_request_body(body), do: IO.iodata_to_binary(body)

  defp accepted_response(profile, %{status: status, body: body}) when status in @accepted_http_statuses do
    accepted_business_response(profile, body)
  end

  defp accepted_response(_profile, _response), do: {:error, :exchange_did_not_accept_request}

  defp accepted_business_response(%{venue: "binance", method: :create_order}, %{"algoId" => id}) do
    {:ok, {:order, id}}
  end

  defp accepted_business_response(%{venue: "binance", method: :set_margin_mode}, %{"code" => 200}) do
    {:ok, {:binance_margin_mode, "isolated", "ETH/USDT:USDT"}}
  end

  defp accepted_business_response(%{venue: "binance", method: :cancel_all_orders}, %{"code" => 200}), do: {:ok, nil}

  defp accepted_business_response(%{venue: "binance"}, body) when is_map(body) do
    if Map.has_key?(body, "code"), do: {:error, :venue_business_failure}, else: {:ok, nil}
  end

  defp accepted_business_response(%{venue: "binance"}, body) when is_list(body), do: {:ok, nil}

  defp accepted_business_response(%{venue: "binancecoinm"}, body) when is_map(body) do
    if Map.has_key?(body, "code"), do: {:error, :venue_business_failure}, else: {:ok, nil}
  end

  defp accepted_business_response(%{venue: "binanceusdm"}, body) when is_map(body) do
    if Map.has_key?(body, "code"), do: {:error, :venue_business_failure}, else: {:ok, nil}
  end

  defp accepted_business_response(%{venue: "alpaca"}, body) when is_map(body) do
    if Map.has_key?(body, "message"), do: {:error, :venue_business_failure}, else: {:ok, nil}
  end

  defp accepted_business_response(%{venue: "deribit"}, %{"result" => result} = body) when is_map(result) do
    if Map.has_key?(body, "error"), do: {:error, :venue_business_failure}, else: {:ok, nil}
  end

  defp accepted_business_response(%{venue: "okx"}, %{"code" => "0"}), do: {:ok, nil}
  defp accepted_business_response(%{venue: "derive"}, %{"result" => result}) when is_list(result), do: {:ok, nil}

  defp accepted_business_response(%{venue: "lighter"}, %{"code" => code}) when code in [200, "200"], do: {:ok, nil}

  defp accepted_business_response(%{venue: "bybit"}, %{"retCode" => 0, "result" => %{"orderId" => id}})
       when is_binary(id) and id != "", do: {:ok, {:order, id}}

  defp accepted_business_response(%{venue: "hyperliquid"}, %{
         "status" => "ok",
         "response" => %{"data" => %{"statuses" => [%{"resting" => %{"oid" => id}} | _]}}
       }), do: {:ok, {:order, to_string(id)}}

  defp accepted_business_response(_profile, _body), do: {:error, :venue_business_failure}

  defp build_golden(profile, params, replay_context, clock, response, live_requests, credentials) do
    replay =
      Map.merge(replay_context, %{
        "call_opts" => Map.new(profile.call_opts, fn {key, value} -> {Atom.to_string(key), value} end),
        "method" => Atom.to_string(profile.method),
        "nonce_override" => clock["nonce"],
        "params" => params,
        "timestamp_ms_override" => clock["timestamp_ms"]
      })

    with {:ok, fixture_exchange} <- build_fixture_exchange(profile, replay),
         {:ok, fixture_requests} <- capture_fixture_request(fixture_exchange, profile, replay),
         :ok <- compare_accepted_shapes(live_requests, fixture_requests, profile) do
      golden = golden(profile, replay, response.status, fixture_requests)

      golden
      |> validate_no_material(live_material(live_requests, credentials, profile))
      |> case do
        :ok -> {:ok, golden}
        {:error, _reason} = error -> error
      end
    end
  end

  defp golden(profile, replay, status, [request | additional_requests]) do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    golden = %{
      "acceptance" => %{
        "business_success" => profile.business_success,
        "capture_date" => String.slice(captured_at, 0, 10),
        "captured_at" => captured_at,
        "endpoint" => profile.endpoint,
        "host" => profile.host,
        "http_status" => status,
        "method" => Atom.to_string(profile.method),
        "venue" => profile.venue
      },
      "oracle" => "exchange_acceptance",
      "provenance" => %{
        "credentials" => "committed fixture credentials",
        "signature" => "derived from fixture credentials during deterministic replay"
      },
      "replay" => replay,
      "request" => request,
      "schema_version" => @schema_version
    }

    golden
    |> maybe_put_additional_requests(additional_requests)
    |> Map.put("label", OracleLabel.exchange_acceptance_label(golden))
  end

  defp maybe_put_additional_requests(golden, []), do: golden
  defp maybe_put_additional_requests(golden, requests), do: Map.put(golden, "additional_requests", requests)

  defp build_fixture_exchange(%{fixture_seed: :empty} = profile, _replay) do
    credentials = Credentials.new!(api_key: "key", secret: "secretsecret", password: "password", uid: "uid")
    opts = profile.exchange_opts |> Keyword.put(:credentials, credentials) |> Keyword.put(:sandbox, profile.sandbox)
    Exchange.new(profile.venue, opts)
  end

  defp build_fixture_exchange(profile, replay) do
    seed = ReplayExchange.build!(profile.venue, %{})
    opts = profile.exchange_opts |> Keyword.put(:credentials, seed.credentials) |> Keyword.put(:sandbox, profile.sandbox)
    exchange = Exchange.new!(profile.venue, opts)
    exchange = %{exchange | currencies: seed.currencies, markets: seed.markets}

    case Map.get(replay, "market_asset_index") do
      index when is_integer(index) ->
        market =
          exchange.markets
          |> Enum.find(&(&1["symbol"] == "BTC/USDC:USDC"))
          |> Map.merge(%{"asset_index" => index, "id" => "BTCUSDC"})

        {:ok, %{exchange | markets: [market]}}

      _other ->
        {:ok, exchange}
    end
  end

  defp capture_fixture_request(exchange, profile, replay) do
    reference = make_ref()
    adapter = fixture_capture_adapter(self(), reference, profile.stub_body)
    clock = %{"nonce" => replay["nonce_override"], "timestamp_ms" => replay["timestamp_ms_override"]}

    case dispatch_capture(exchange, profile, replay["params"], clock, adapter) do
      {:ok, _response} -> captured_requests(reference, profile)
      {:error, _reason} -> {:error, :fixture_request_rebuild_failed}
    end
  end

  defp validate_replay_identity(profile, replay) do
    if replay["method"] == Atom.to_string(profile.method) and is_map(replay["params"]) and
         is_integer(replay["timestamp_ms_override"]) and is_integer(replay["nonce_override"]) do
      :ok
    else
      {:error, :invalid_replay_identity}
    end
  end

  defp compare_accepted_shapes(live_requests, fixture_requests, profile) do
    live_shapes = Enum.map(live_requests, &acceptance_shape(&1, profile))
    fixture_shapes = Enum.map(fixture_requests, &acceptance_shape(&1, profile))

    if live_shapes == fixture_shapes do
      :ok
    else
      {:error, :live_and_fixture_request_shapes_differ}
    end
  end

  defp compare_fixture_requests(expected, actual, profile) when length(expected) == length(actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.reduce_while(:ok, fn {expected_request, actual_request}, :ok ->
      case compare_fixture_request(expected_request, actual_request, profile) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp compare_fixture_requests(_expected, _actual, _profile), do: {:error, :accepted_request_regressed}

  defp compare_fixture_request(expected, actual, %{venue: "lighter"} = profile) do
    if acceptance_shape(expected, profile) == acceptance_shape(actual, profile) do
      :ok
    else
      {:error, :accepted_request_regressed}
    end
  end

  defp compare_fixture_request(expected, actual, _profile) do
    if actual == expected, do: :ok, else: {:error, :accepted_request_regressed}
  end

  defp acceptance_shape(request, profile) do
    %{
      "body" => shape_body(request["body"], profile.sensitive_body),
      "headers" => shape_headers(request["headers"], profile.sensitive_headers),
      "method" => request["method"],
      "url" => shape_url(request["url"], profile.sensitive_query)
    }
  end

  defp shape_headers(headers, sensitive_names) do
    sensitive_names = MapSet.new(sensitive_names, &String.downcase/1)

    Enum.map(headers, fn [name, value] ->
      if MapSet.member?(sensitive_names, String.downcase(name)), do: [name, @auth_marker], else: [name, value]
    end)
  end

  defp shape_url(url, sensitive_keys) do
    uri = URI.parse(url)
    sensitive_keys = MapSet.new(sensitive_keys)

    query =
      case uri.query do
        nil ->
          []

        value ->
          Enum.map(URI.query_decoder(value), fn {key, val} ->
            {key, if(MapSet.member?(sensitive_keys, key), do: @auth_marker, else: val)}
          end)
      end

    uri
    |> Map.take([:scheme, :host, :port, :path])
    |> Map.put(:query, query)
  end

  defp shape_body(nil, _sensitive_keys), do: nil

  defp shape_body(body, sensitive_keys) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> mask_sensitive_keys(decoded, MapSet.new(sensitive_keys))
      {:error, _reason} -> body
    end
  end

  defp mask_sensitive_keys(map, sensitive_keys) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if MapSet.member?(sensitive_keys, to_string(key)) do
        {key, @auth_marker}
      else
        {key, mask_sensitive_keys(value, sensitive_keys)}
      end
    end)
  end

  defp mask_sensitive_keys(list, sensitive_keys) when is_list(list),
    do: Enum.map(list, &mask_sensitive_keys(&1, sensitive_keys))

  defp mask_sensitive_keys(value, _sensitive_keys), do: value

  defp live_material(requests, credentials, profile) do
    request_material =
      Enum.flat_map(requests, fn request ->
        sensitive_header_values(request["headers"], profile.sensitive_headers) ++
          sensitive_query_values(request["url"], profile.sensitive_query) ++
          sensitive_body_values(request["body"], profile.sensitive_body)
      end)

    credential_material(credentials, profile.venue) ++ request_material
  end

  defp credential_material(credentials, "lighter"), do: [credentials.secret]

  defp credential_material(credentials, _venue) do
    credentials
    |> Map.from_struct()
    |> Map.take([:api_key, :secret, :password, :uid])
    |> Map.values()
  end

  defp sensitive_header_values(headers, sensitive_names) do
    sensitive_names = MapSet.new(sensitive_names, &String.downcase/1)

    for [name, value] <- headers,
        MapSet.member?(sensitive_names, String.downcase(name)),
        do: value
  end

  defp sensitive_query_values(url, sensitive_keys) do
    sensitive_keys = MapSet.new(sensitive_keys)

    case URI.parse(url).query do
      nil -> []
      query -> for {key, value} <- URI.query_decoder(query), MapSet.member?(sensitive_keys, key), do: value
    end
  end

  defp sensitive_body_values(nil, _sensitive_keys), do: []

  defp sensitive_body_values(body, sensitive_keys) do
    case Jason.decode(body) do
      {:ok, decoded} -> collect_sensitive_values(decoded, MapSet.new(sensitive_keys))
      {:error, _reason} -> []
    end
  end

  defp collect_sensitive_values(map, sensitive_keys) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      if MapSet.member?(sensitive_keys, to_string(key)) do
        binary_leaves(value)
      else
        collect_sensitive_values(value, sensitive_keys)
      end
    end)
  end

  defp collect_sensitive_values(list, sensitive_keys) when is_list(list),
    do: Enum.flat_map(list, &collect_sensitive_values(&1, sensitive_keys))

  defp collect_sensitive_values(_value, _sensitive_keys), do: []

  defp binary_leaves(value) when is_binary(value), do: [value]

  defp binary_leaves(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&binary_leaves/1)

  defp binary_leaves(list) when is_list(list), do: Enum.flat_map(list, &binary_leaves/1)
  defp binary_leaves(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> binary_leaves()
  defp binary_leaves(_value), do: []

  defp contains_material?(value, material) when is_binary(value), do: String.contains?(value, material)

  defp contains_material?(map, material) when is_map(map) do
    Enum.any?(map, fn {key, value} -> contains_material?(key, material) or contains_material?(value, material) end)
  end

  defp contains_material?(list, material) when is_list(list), do: Enum.any?(list, &contains_material?(&1, material))

  defp contains_material?(tuple, material) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> contains_material?(material)

  defp contains_material?(_value, _material), do: false

  defp method_atom(method) when is_binary(method) do
    case Enum.find(Unified.method_defs(), fn {atom, _js_name, _params, _description} ->
           Atom.to_string(atom) == method
         end) do
      {atom, _js_name, _params, _description} -> {:ok, atom}
      nil -> {:error, :invalid_replay_identity}
    end
  end

  defp method_atom(_method), do: {:error, :invalid_replay_identity}

  defp finish_with_cleanup(result, exchange, profile, cleanup) do
    case cleanup(exchange, profile, cleanup) do
      :ok -> result
      {:error, _reason} -> {:error, :accepted_order_cleanup_failed}
    end
  end

  defp cleanup(_exchange, _profile, nil), do: :ok

  defp cleanup(exchange, profile, {:order, order_id}) do
    opts = Keyword.merge([symbol: profile.symbol], profile.call_opts)

    case Bourse.cancel_order(exchange, order_id, opts) do
      {:ok, %Bourse.Order{}} -> :ok
      _other -> {:error, :cleanup_failed}
    end
  end

  defp cleanup(exchange, _profile, {:binance_margin_mode, margin_mode, symbol}) do
    case Bourse.set_margin_mode(exchange, margin_mode, symbol) do
      {:ok, %{"code" => 200}} -> :ok
      _other -> {:error, :cleanup_failed}
    end
  end
end
