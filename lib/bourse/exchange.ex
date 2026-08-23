defmodule Bourse.Exchange do
  @moduledoc """
  Exchange configuration struct and constructor.

  Holds everything needed to make API calls for a specific exchange instance:
  resolved base URLs, rate limits, credentials, capabilities, and lean spec data.

  This is a pure data struct — no process. Rate limiting, HTTP execution, and
  signing are handled by other modules that receive `%Exchange{}` as input.

  Loaded market metadata lives on the struct as `:markets` (nil until
  `Bourse.load_markets/1` or `put_markets/2`). Production caches contain
  `%Bourse.Market{}` structs; static replay caches retain raw Bourse maps so their
  oracle inputs stay byte-faithful. Callers thread the enriched value; there is
  no hidden global cache.

  ## Examples

      # Public-only (no credentials)
      {:ok, exchange} = Bourse.Exchange.new("bybit")
      exchange.base_urls
      #=> %{"public" => "https://api.bybit.com", ...}

      # With credentials
      {:ok, exchange} = Bourse.Exchange.new("bybit", api_key: "abc", secret: "xyz")
      exchange.credentials
      #=> %Bourse.Credentials{api_key: "abc", secret: "xyz", ...}

      # Sandbox mode (uses testnet URLs)
      {:ok, exchange} = Bourse.Exchange.new("bybit", sandbox: true)

      # Cache markets for symbol→market_id resolution (loadMarkets equivalent)
      {:ok, exchange} = Bourse.load_markets(exchange)

  """

  @capability_surface_version 1
  @capability_surface_path Path.expand("../../priv/venues/capability_surface.json", __DIR__)
  @external_resource @capability_surface_path
  @capability_surface_document @capability_surface_path |> File.read!() |> :json.decode()

  if !(Map.get(@capability_surface_document, "version") == @capability_surface_version and
         is_map(Map.get(@capability_surface_document, "venues"))) do
    raise "invalid capability surface: #{inspect(@capability_surface_document)}"
  end

  @capability_surface Map.fetch!(@capability_surface_document, "venues")

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :credentials,
    :hostname,
    sandbox_headers: %{},
    sandbox: false,
    rate_limit_ms: 0,
    base_urls: %{},
    has: %{},
    timeframes: %{},
    features: nil,
    fees: nil,
    config: %{},
    doc_urls: %{},
    required_credentials: %{},
    signing_pattern: nil,
    signing_config: %{},
    common_currencies: %{},
    currencies: %{},
    outbound_aliases: %{},
    symbol_patterns: %{},
    options: %{},
    network_options: %{},
    error_codes: %{},
    broad_error_patterns: %{},
    error_body_checks: [],
    error_handler_checks: [],
    error_code_fields: [],
    http_exceptions: %{},
    status_map: %{},
    retry_classification: %{},
    error_class_ancestors: %{},
    request_defaults: %{},
    request_param_shape: %{},
    endpoint_selection: %{},
    # Authored venue default market family for multi-endpoint no-arg reads
    # (e.g. "linear" / "spot"). Nil = no authored default; first-class venues
    # must not fall through to bare hd(configs).
    default_family: nil,
    request_contracts: %{},
    # nil = not loaded; list = caller-threaded market cache
    markets: nil,
    module: nil,
    spec: %{}
  ]

  @type error_body_role :: :error_code | :status_sentinel
  @type sentinel_operator :: String.t()
  @type sentinel_value :: %{operator: sentinel_operator(), value: String.t()}
  @type error_status_guard :: {:gte, non_neg_integer()} | {:in, [non_neg_integer()]}
  @type error_body_check :: %{
          field: String.t() | nil,
          field2: String.t() | nil,
          roles: [error_body_role()],
          sentinel_values: [sentinel_value()]
        }
  @type error_handler_check :: %{
          status_guard: error_status_guard(),
          body_contains: [String.t()],
          error_type: Bourse.Error.error_type()
        }
  @type trading_fee_schedule :: %{
          maker: number() | nil,
          taker: number() | nil,
          percentage: boolean() | nil,
          tier_based: boolean() | nil,
          fee_side: String.t() | nil,
          tiers: map() | nil,
          fee: Bourse.TradingFee.t(),
          info: map()
        }
  @type fees :: map() | nil
  @type capability_declaration :: boolean() | String.t()
  @type capability_surface :: %{
          String.t() => %{String.t() => capability_declaration()}
        }
  @type config :: %{optional(String.t()) => term()}
  @type doc_urls :: %{optional(String.t()) => String.t() | [String.t()]}
  @type raw_market :: %{optional(String.t()) => term()}
  @type market_cache :: [Bourse.Market.t() | raw_market()] | nil

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          credentials: Bourse.Credentials.t() | nil,
          sandbox: boolean(),
          sandbox_headers: %{optional(String.t()) => String.t()},
          rate_limit_ms: number(),
          hostname: String.t() | nil,
          base_urls: map(),
          has: %{String.t() => boolean()},
          timeframes: %{String.t() => String.t()},
          features: %{String.t() => map()} | nil,
          fees: fees(),
          config: config(),
          doc_urls: doc_urls(),
          required_credentials: %{String.t() => boolean()},
          signing_pattern: Bourse.Signing.pattern() | nil,
          signing_config: map(),
          common_currencies: %{String.t() => String.t()},
          currencies: %{String.t() => map()},
          outbound_aliases: %{String.t() => String.t()},
          symbol_patterns: %{atom() => Bourse.Symbol.pattern_config()},
          options: map(),
          network_options: map(),
          error_codes: %{String.t() => Bourse.Error.error_type()},
          broad_error_patterns: %{String.t() => Bourse.Error.error_type()},
          error_body_checks: [error_body_check()],
          error_handler_checks: [error_handler_check()],
          error_code_fields: [String.t()],
          http_exceptions: %{String.t() => Bourse.Error.error_type()},
          status_map: %{String.t() => Bourse.Error.error_type()},
          retry_classification: %{String.t() => Bourse.Error.retry_class()},
          error_class_ancestors: %{String.t() => [String.t()]},
          request_defaults: %{String.t() => %{String.t() => term()}},
          request_param_shape: %{String.t() => %{String.t() => map()}},
          endpoint_selection: %{String.t() => map()},
          default_family: String.t() | nil,
          request_contracts: %{request_contract_key() => request_contract()},
          markets: market_cache(),
          module: module() | nil,
          spec: map()
        }
  @type request_contract_key :: {[String.t()], atom(), String.t()}
  @type request_contract :: %{
          optional(:method) => atom(),
          optional(:path) => String.t(),
          optional(:path_params) => [String.t()],
          optional(:body_encoding) => String.t(),
          optional(:content_type) => String.t() | nil,
          optional(:timestamp_recipe) => map(),
          optional(:weight) => number(),
          optional(:rate_limit) => map()
        }

  # ---------------------------------------------------------------------------
  # Generator Macro
  #
  # `use Bourse.Exchange, spec: "bybit"` generates an exchange module at compile
  # time from a JSON spec. Stores lean spec, pre-computed endpoint configs, and
  # introspection functions. Wires up Descripex for self-describing API functions.
  # ---------------------------------------------------------------------------

  @doc "Macro entry point: `use Bourse.Exchange, spec: \"bybit\"` generates an exchange module."
  defmacro __using__(opts) do
    spec_id =
      Keyword.get(opts, :spec) ||
        raise ArgumentError, "use Bourse.Exchange requires spec: \"exchange_id\""

    quote do
      require Bourse.Exchange

      Bourse.Exchange.__generate__(unquote(spec_id))
    end
  end

  @doc "Generates introspection functions and endpoint wrappers from a spec ID."
  defmacro __generate__(spec_id) do
    data = Bourse.Exchange.prepare_generate_data(spec_id)
    Bourse.Exchange.build_module_body(data)
  end

  # v4 normalization-slot → {generated function, unified response struct}.
  # Drives the generated `parse_<slot>/2` functions. Slots mirror
  # `normalization.field_maps` keys (upstream Phase 12 Tasks 74–82);
  # `_unresolved_reason` is a meta key, not a slot. Function-name atoms are
  # literal (not derived via `String.to_atom`) so codegen creates no atoms.
  @parse_slots [
    {"account", :parse_account, Bourse.Account},
    {"balance", :parse_balance, Bourse.Balance},
    {"borrow_interest", :parse_borrow_interest, Bourse.BorrowInterest},
    {"borrow_rate", :parse_borrow_rate, Bourse.BorrowRate},
    {"conversion", :parse_conversion, Bourse.Conversion},
    {"currency", :parse_currency, Bourse.Currency},
    {"deposit_address", :parse_deposit_address, Bourse.DepositAddress},
    {"funding_rate", :parse_funding_rate, Bourse.FundingRate},
    {"funding_rate_history", :parse_funding_rate_history, Bourse.FundingRateHistory},
    {"funding_history", :parse_funding_history, Bourse.FundingHistory},
    {"greeks", :parse_greeks, Bourse.Greeks},
    {"last_price", :parse_last_price, Bourse.LastPrice},
    {"ledger_entry", :parse_ledger_entry, Bourse.LedgerEntry},
    {"leverage", :parse_leverage, Bourse.Leverage},
    {"leverage_tiers", :parse_leverage_tiers, Bourse.LeverageTier},
    {"liquidation", :parse_liquidation, Bourse.Liquidation},
    {"long_short_ratio", :parse_long_short_ratio, Bourse.LongShortRatio},
    {"margin_loan", :parse_margin_loan, Bourse.MarginLoan},
    {"margin_mode", :parse_margin_mode, Bourse.MarginMode},
    {"margin_modification", :parse_margin_modification, Bourse.MarginModification},
    {"market", :parse_market, Bourse.Market},
    {"ohlcv", :parse_ohlcv, Bourse.OHLCV},
    {"open_interest", :parse_open_interest, Bourse.OpenInterest},
    {"option", :parse_option, Bourse.OptionData},
    {"order", :parse_order, Bourse.Order},
    {"order_list", :parse_order_list, Bourse.OrderList},
    {"position", :parse_position, Bourse.Position},
    {"adl_rank", :parse_adl_rank, Bourse.ADLRank},
    {"ticker", :parse_ticker, Bourse.Ticker},
    {"trade", :parse_trade, Bourse.Trade},
    {"trading_fee", :parse_trading_fee, Bourse.TradingFee},
    {"transaction", :parse_transaction, Bourse.Transaction},
    {"transfer", :parse_transfer, Bourse.TransferEntry},
    {"volatility_history", :parse_volatility_history, Bourse.VolatilityHistory}
  ]

  @doc """
  Builds the quoted module body from prepared generate data.

  Called by both `__generate__/1` (macro path) and `Bourse.Exchanges`
  (`Module.create` path) to ensure a single source of truth.

  ## Options

    * `:moduledoc` — optional `@moduledoc` string to inject. The macro path
      leaves this to the caller; `Bourse.Exchanges` provides one per exchange.
  """
  @spec build_module_body(map(), keyword()) :: Macro.t()
  def build_module_body(data, opts \\ []) do
    %{
      exchange_id: exchange_id,
      spec_file: spec_file,
      escaped_lean: escaped_lean,
      escaped_endpoints: escaped_endpoints,
      escaped_unified: escaped_unified,
      escaped_field_maps: escaped_field_maps,
      escaped_mapping_complete: escaped_mapping_complete,
      escaped_verification: escaped_verification,
      escaped_response_envelopes: escaped_response_envelopes,
      endpoint_functions: endpoint_functions,
      parse_functions: parse_functions
    } = data

    namespace = "/#{exchange_id}"
    moduledoc_ast = build_moduledoc_ast(opts)
    introspection = build_introspection_ast(data)

    quote do
      use Descripex, namespace: unquote(namespace)

      unquote_splicing(moduledoc_ast)
      @external_resource unquote(spec_file)

      @bourse_spec unquote(escaped_lean)
      @bourse_endpoint_configs unquote(escaped_endpoints)
      @bourse_unified_mapping unquote(escaped_unified)
      @bourse_field_maps unquote(escaped_field_maps)
      @bourse_mapping_complete unquote(escaped_mapping_complete)
      @bourse_verification unquote(escaped_verification)
      @bourse_response_envelopes unquote(escaped_response_envelopes)

      @doc "Returns the owned normalization field maps (per response-type slot)."
      @spec __field_maps__() :: map()
      def __field_maps__, do: @bourse_field_maps

      @doc "Returns whether each unified method has a complete Bourse mapping."
      @spec __mapping_complete__() :: %{String.t() => boolean()}
      def __mapping_complete__, do: @bourse_mapping_complete

      @doc "Returns each unified method's provider-verification state."
      @spec __verification__() :: %{String.t() => String.t()}
      def __verification__, do: @bourse_verification

      @doc "Returns per-slot unified-method response envelope configs."
      @spec __response_envelopes__() :: map()
      def __response_envelopes__, do: @bourse_response_envelopes

      unquote_splicing(introspection)
      unquote_splicing(endpoint_functions)
      unquote_splicing(parse_functions)
    end
  end

  @doc """
  Builds quoted `parse_<slot>/2` wrapper functions from the spec's normalization
  field maps and provider-support declarations.

  One function per `@parse_slots` entry (`parse_ticker/2`, `parse_trade/2`, …).
  Each embeds its slot mapping as a literal and delegates to `Bourse.Parser.parse/4`,
  A slot with no provider-offered operation returns
  `{:error, {:unsupported_operation, slot}}`. An offered but unmapped slot
  returns `{:error, :no_field_map}`; a non-`nil` `_unresolved_reason` returns
  `{:error, {:unresolved, reason}}`.
  """
  @spec build_parse_functions(map(), map(), map()) :: [Macro.t()]
  def build_parse_functions(field_maps, venue_support, unified)
      when is_map(field_maps) and is_map(venue_support) and is_map(unified) do
    supported_slots = supported_parse_slots(venue_support, unified)

    Enum.map(@parse_slots, fn {slot, fn_name, target} ->
      escaped_mapping = Macro.escape(Map.get(field_maps, slot))
      operation_supported? = MapSet.member?(supported_slots, slot)

      quote do
        @doc """
        Parses a raw #{unquote(slot)} response into `#{inspect(unquote(target))}`.

        Delegates to `Bourse.Parser.parse/4` with this exchange's authored
        normalization field map. Returns `{:error, {:unsupported_operation, slot}}`
        when the provider does not offer the operation, `{:error, :no_field_map}`
        when an offered slot is unmapped, and `{:error, {:unresolved, reason}}`
        when the authored map is not safely derivable. `opts` may carry `:market`
        for discriminated maps.
        When the slot authors per-route field maps (`route_field_maps`), `opts`
        MUST carry `:route` (the endpoint path template, e.g. `"account/bills"`);
        an absent or unknown route returns `{:error, :no_matching_parser_branch}`
        rather than silently parsing with the wrong vocabulary.
        """
        @spec unquote(fn_name)(term(), keyword()) ::
                {:ok, struct() | [struct()]} | {:error, term()}
        def unquote(fn_name)(data, opts \\ []) do
          opts =
            opts
            |> Keyword.put_new(:venue, __id__())
            |> Keyword.put_new(:operation_supported, unquote(operation_supported?))
            |> Keyword.put_new(:parse_slot, unquote(slot))

          Bourse.Parser.parse(data, unquote(escaped_mapping), unquote(target), opts)
        end
      end
    end)
  end

  defp supported_parse_slots(venue_support, unified) do
    unified
    |> Map.keys()
    |> Enum.filter(&(Map.get(venue_support, &1) in [true, "emulated"]))
    |> Enum.reduce(MapSet.new(), fn method, slots ->
      case Bourse.Unified.parse_type_for_method(method) do
        {:ok, slot} -> MapSet.put(slots, slot)
        :error -> slots
      end
    end)
  end

  # Builds optional @moduledoc AST from opts.
  defp build_moduledoc_ast(opts) do
    case Keyword.get(opts, :moduledoc) do
      nil -> []
      doc -> [quote(do: @moduledoc(unquote(doc)))]
    end
  end

  # Builds all introspection function ASTs (__id__, __name__, __spec__, etc.).
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp build_introspection_ast(data) do
    %{
      exchange_id: exchange_id,
      exchange_name: exchange_name,
      signing_pattern: signing_pattern,
      escaped_features: escaped_features,
      escaped_signing_config: escaped_signing_config
    } = data

    [
      quote do
        @doc "Returns the exchange ID string."
        @spec __id__() :: String.t()
        def __id__, do: unquote(exchange_id)

        @doc "Returns the exchange display name."
        @spec __name__() :: String.t()
        def __name__, do: unquote(exchange_name)

        @doc "Returns the lean spec (runtime describe minus API tree)."
        @spec __spec__() :: map()
        def __spec__, do: @bourse_spec

        @doc "Returns all pre-computed endpoint configs."
        @spec __endpoints__() :: [map()]
        def __endpoints__, do: @bourse_endpoint_configs

        @doc "Returns provider-support declarations (`true`, `false`, or `\"emulated\"`)."
        @spec __features__() :: map()
        def __features__, do: unquote(escaped_features)

        @doc "Returns provider support independently of Bourse implementation. Same map as `__features__/0`."
        @spec __venue_support__() :: map()
        def __venue_support__, do: unquote(escaped_features)

        @doc "Returns the signing pattern and config for this exchange."
        @spec __signing__() :: %{pattern: atom() | nil, config: map()}
        def __signing__ do
          %{pattern: unquote(signing_pattern), config: unquote(escaped_signing_config)}
        end

        @doc "Returns the full unified method → endpoint configs mapping."
        @spec __unified_endpoints__() :: %{atom() => [map()]}
        def __unified_endpoints__, do: @bourse_unified_mapping

        @doc "Returns endpoint configs for a specific unified method, or `[]` if unknown."
        @spec __unified_endpoint__(atom()) :: [map()]
        def __unified_endpoint__(method) when is_atom(method) do
          Map.get(@bourse_unified_mapping, method, [])
        end
      end
    ]
  end

  @doc "Prepares all compile-time data for the generator macro."
  @spec prepare_generate_data(String.t()) :: map()
  def prepare_generate_data(spec_id) do
    spec = Bourse.Spec.load!(spec_id)
    describe = spec["raw"]["describe"]
    exchange_id = spec["exchange"]["id"]

    hostname = describe["hostname"] || ""
    url_prefixes = compute_url_prefixes(spec, hostname)
    auth_sections = get_in(spec, ["auth", "authenticated_sections"]) || []

    endpoint_configs =
      Bourse.Exchange.build_endpoint_configs(describe["api"] || %{}, url_prefixes, auth_sections)

    {features, mapping_complete, verification} = capability_facts(spec)
    lean = Map.delete(describe, "api")

    {signing_pattern, signing_config} = Bourse.Exchange.signing_from_spec(spec)

    unified_mapping =
      Bourse.Exchange.build_unified_method_mapping(spec, endpoint_configs)

    field_maps = get_in(spec, ["normalization", "field_maps"]) || %{}
    response_envelopes = get_in(spec, ["normalization", "response_envelopes"]) || %{}

    doc_meta = build_doc_meta(spec, describe, endpoint_configs, features)

    %{
      exchange_id: exchange_id,
      exchange_name: spec["exchange"]["name"],
      spec_file: Bourse.Spec.spec_path(spec_id),
      signing_pattern: signing_pattern,
      escaped_lean: Macro.escape(lean),
      escaped_endpoints: Macro.escape(endpoint_configs),
      escaped_features: Macro.escape(features),
      escaped_mapping_complete: Macro.escape(mapping_complete),
      escaped_verification: Macro.escape(verification),
      escaped_signing_config: Macro.escape(signing_config),
      escaped_unified: Macro.escape(unified_mapping),
      escaped_field_maps: Macro.escape(field_maps),
      escaped_response_envelopes: Macro.escape(response_envelopes),
      endpoint_functions: Bourse.Exchange.build_endpoint_functions(endpoint_configs),
      parse_functions:
        Bourse.Exchange.build_parse_functions(
          field_maps,
          features,
          spec["endpoints"]["unified"]
        ),
      doc_meta: doc_meta
    }
  end

  defp capability_facts(spec) do
    capabilities = spec["capabilities"]

    {
      capabilities["has"],
      capabilities["mapping_complete"],
      capabilities["verification"]
    }
  end

  @highlight_capabilities ~w(
    fetchTicker fetchOrderBook fetchOHLCV fetchBalance fetchPositions
    createOrder cancelOrder fetchOpenOrders fetchMyTrades fetchFundingRate
    fetchMarkets fetchCurrencies withdraw transfer fetchTime
  )

  @doc """
  Builds `@moduledoc` text for a generated exchange module from spec metadata.

  Used by `Bourse.Exchanges` at compile time. The returned string is injected into
  each generated module (e.g. `Bourse.Bybit`) for ExDoc and IDE discovery.
  """
  @spec build_exchange_moduledoc(map()) :: String.t()
  def build_exchange_moduledoc(data) do
    %{
      exchange_id: exchange_id,
      exchange_name: exchange_name,
      signing_pattern: signing_pattern,
      doc_meta: meta
    } = data

    """
    #{exchange_name} exchange client (`#{exchange_id}`).

    Generated from the owned vendored spec at compile time. Provides raw
    REST endpoint wrappers, unified-method mapping, and response parsers.

    ## Metadata

    #{format_doc_metadata(meta)}

    ## Signing

    Pattern: #{format_signing_pattern(signing_pattern)} — #{signing_pattern_description(signing_pattern)}

    ## Capabilities

    #{format_doc_capabilities(meta)}

    ## Credentials

    #{format_doc_credentials(meta)}

    ## Introspection

    - `__endpoints__/0` — #{meta.endpoint_count} raw REST endpoints
    - `__unified_endpoints__/0` — unified method → endpoint mapping
    - `__features__/0` / `__venue_support__/0` — provider-support declarations
    - `__mapping_complete__/0` — Bourse implementation completeness
    - `__verification__/0` — provider-verification state
    - `__signing__/0` — resolved signing pattern and config

    ## Usage

        {:ok, exchange} = Bourse.Exchange.new("#{exchange_id}")
        endpoints = Bourse.#{Macro.camelize(exchange_id)}.__endpoints__()
    """
  end

  defp build_doc_meta(spec, describe, endpoint_configs, features) do
    %{
      hostname: describe["hostname"],
      version: describe["version"],
      countries: describe["countries"] || get_in(spec, ["exchange", "country"]) || [],
      certified: describe["certified"],
      pro: describe["pro"],
      required_credentials: build_required_credentials(spec, describe),
      endpoint_count: length(endpoint_configs),
      capability_count: count_true_capabilities(features),
      sample_capabilities: sample_capabilities(features)
    }
  end

  defp format_doc_metadata(meta) do
    lines = [
      meta_line("Hostname", meta.hostname),
      meta_line("API version", meta.version),
      meta_line("Countries", format_countries(meta.countries)),
      meta_line("Certified", format_bool(meta.certified)),
      meta_line("Pro", format_bool(meta.pro))
    ]

    Enum.join(Enum.reject(lines, &is_nil/1), "\n")
  end

  defp meta_line(_label, nil), do: nil
  defp meta_line(_label, ""), do: nil
  defp meta_line(label, value), do: "- #{label}: `#{value}`"

  defp format_countries([]), do: nil
  defp format_countries(countries) when is_list(countries), do: Enum.join(countries, ", ")
  defp format_countries(country) when is_binary(country), do: country

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"
  defp format_bool(_), do: nil

  defp signing_pattern_description(:hmac_sha256_query), do: "HMAC-SHA256 query signing"
  defp signing_pattern_description(:hmac_sha256_headers), do: "HMAC-SHA256 header signing"
  defp signing_pattern_description(:hmac_sha256_iso_passphrase), do: "ISO timestamp + passphrase HMAC"
  defp signing_pattern_description(:api_key_secret_headers), do: "API key and secret header authentication"
  defp signing_pattern_description(:deribit), do: "Deribit Authorization header"
  defp signing_pattern_description(:hyperliquid), do: "EIP-712 / action signing (DEX)"
  defp signing_pattern_description(:derive), do: "EIP-191 REST headers + EIP-712 order signing (DEX)"
  defp signing_pattern_description(:lighter), do: "first-party zk-Schnorr signer"
  defp signing_pattern_description(nil), do: "public-only; no signing path"
  defp signing_pattern_description(_), do: "see `Bourse.Signing`"

  defp format_signing_pattern(nil), do: "none"
  defp format_signing_pattern(pattern), do: "`#{pattern}`"

  defp format_doc_capabilities(meta) do
    samples = meta.sample_capabilities

    if samples == [] do
      "#{meta.capability_count} enabled unified methods — see `__features__/0`."
    else
      rest =
        if meta.capability_count > length(samples) do
          " (#{meta.capability_count} total — see `__features__/0`)"
        else
          ""
        end

      "- Enabled: `#{Enum.join(samples, "`, `")}`#{rest}"
    end
  end

  defp format_doc_credentials(meta) do
    required =
      meta.required_credentials
      |> Enum.filter(fn {_key, required?} -> required? end)
      |> Enum.map(fn {key, _} -> key end)
      |> Enum.sort()

    case required do
      [] -> "No credentials required for public endpoints."
      keys -> "Private endpoints require: `#{Enum.join(keys, "`, `")}`."
    end
  end

  defp count_true_capabilities(features) when is_map(features) do
    Enum.count(features, fn {_key, value} -> value == true end)
  end

  defp count_true_capabilities(_), do: 0

  defp sample_capabilities(features) when is_map(features) do
    enabled =
      features
      |> Enum.filter(fn {_key, value} -> value == true end)
      |> Enum.map(fn {key, _} -> key end)

    highlighted = Enum.filter(@highlight_capabilities, &(&1 in enabled))

    rest =
      enabled
      |> Enum.reject(&(&1 in @highlight_capabilities))
      |> Enum.sort()

    Enum.take(highlighted ++ rest, 12)
  end

  defp sample_capabilities(_), do: []

  @signing_patterns %{
    "api_key_secret_headers" => :api_key_secret_headers,
    "deribit" => :deribit,
    "derive" => :derive,
    "hmac_sha256_headers" => :hmac_sha256_headers,
    "hmac_sha256_iso_passphrase" => :hmac_sha256_iso_passphrase,
    "hmac_sha256_query" => :hmac_sha256_query,
    "hyperliquid" => :hyperliquid,
    "lighter" => :lighter
  }
  @signing_config_keys %{
    "api_key_header" => :api_key_header,
    "auto_recv_window" => :auto_recv_window,
    "passphrase_header" => :passphrase_header,
    "query_encoder" => :query_encoder,
    "recv_window" => :recv_window,
    "recv_window_header" => :recv_window_header,
    "recv_window_key" => :recv_window_key,
    "secret_header" => :secret_header,
    "signature_encoding" => :signature_encoding,
    "signature_header" => :signature_header,
    "timestamp_header" => :timestamp_header
  }
  @hmac_recipe_patterns [
    :hmac_sha256_headers,
    :hmac_sha256_iso_passphrase,
    :hmac_sha256_query
  ]
  @signature_encodings %{"base64" => :base64, "hex" => :hex, "url" => :url}

  @doc "Reads the explicit signing executor and configuration from an owned runtime spec."
  @spec signing_from_spec(map()) :: {Bourse.Signing.pattern() | nil, map()}
  def signing_from_spec(spec) when is_map(spec) do
    auth = Map.fetch!(spec, "auth")
    pattern = signing_pattern(auth)

    config =
      auth
      |> Map.fetch!("signing_config")
      |> Map.new(fn {key, value} ->
        atom_key = Map.fetch!(@signing_config_keys, key)
        {atom_key, signing_config_value(atom_key, value)}
      end)

    config =
      if pattern in @hmac_recipe_patterns do
        Map.put(config, :sign_recipe, Map.fetch!(auth, "sign_recipe"))
      else
        config
      end

    {pattern, config}
  end

  defp signing_pattern(%{"authenticated_sections" => [], "signing_pattern" => nil}), do: nil
  defp signing_pattern(auth), do: Map.fetch!(@signing_patterns, Map.fetch!(auth, "signing_pattern"))

  defp signing_config_value(:signature_encoding, value), do: Map.fetch!(@signature_encodings, value)
  defp signing_config_value(_key, value), do: value

  @doc "Builds unified method mapping from spec data and pre-computed endpoint configs."
  @spec build_unified_method_mapping(map(), [map()]) :: %{atom() => [map()]}
  def build_unified_method_mapping(spec, endpoint_configs) do
    # Canonical JS→atom lookup from method_defs ensures atoms like :fetch_uta_ohlcv
    # match exactly, avoiding Macro.underscore mangling (fetchUTAOHLCV → :fetch_utaohlcv).
    js_to_atom = Map.new(Bourse.Unified.method_defs(), fn {atom, js, _, _} -> {js, atom} end)
    support = if spec["authored"] == true, do: get_in(spec, ["capabilities", "has"])

    spec
    |> get_in(["endpoints", "unified"])
    |> supported_unified_methods(support)
    |> Bourse.UnifiedMethod.build_unified_mapping(endpoint_configs, js_to_atom)
  end

  defp supported_unified_methods(unified, support) when is_map(unified) and is_map(support) do
    Map.filter(unified, fn {method, endpoints} ->
      Map.get(support, method) in [true, "emulated"] and is_list(endpoints) and endpoints != []
    end)
  end

  defp supported_unified_methods(unified, _support), do: unified

  @doc """
  Returns the release-pinned capability surface for every runtime venue.

  The complete per-capability values are embedded from
  `priv/venues/capability_surface.json`, which the offline oracle gate keeps
  equal to the authored runtime specs.
  """
  @spec capability_surface() :: capability_surface()
  def capability_surface, do: @capability_surface

  @doc "Returns named capability changes between two release surfaces."
  @spec capability_surface_differences(capability_surface(), capability_surface()) :: [String.t()]
  def capability_surface_differences(pinned, current) when is_map(pinned) and is_map(current) do
    pinned
    |> merged_sorted_keys(current)
    |> Enum.flat_map(&venue_capability_differences(&1, pinned, current))
  end

  defp venue_capability_differences(venue, pinned, current) do
    pinned_capabilities = Map.get(pinned, venue, %{})
    current_capabilities = Map.get(current, venue, %{})

    pinned_capabilities
    |> merged_sorted_keys(current_capabilities)
    |> Enum.flat_map(&capability_difference(venue, &1, pinned_capabilities, current_capabilities))
  end

  defp capability_difference(venue, capability, pinned, current) do
    case {Map.fetch(pinned, capability), Map.fetch(current, capability)} do
      {{:ok, value}, {:ok, value}} ->
        []

      {{:ok, previous}, {:ok, current_value}} ->
        ["#{venue}:#{capability} changed #{inspect(previous)} -> #{inspect(current_value)}"]

      {{:ok, previous}, :error} ->
        ["#{venue}:#{capability} removed (was #{inspect(previous)})"]

      {:error, {:ok, current_value}} ->
        ["#{venue}:#{capability} added as #{inspect(current_value)}"]
    end
  end

  defp merged_sorted_keys(left, right) do
    left
    |> Map.keys()
    |> Kernel.++(Map.keys(right))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Builds quoted endpoint wrapper functions from a list of endpoint configs.

  Called at compile time by `__generate__/1`. Each generated function embeds
  its endpoint config as a literal and delegates to `Bourse.Dispatch.call/4`.

  ## Example

  For a config `%{name: :public_get_v5_market_tickers, ...}`, generates:

      def public_get_v5_market_tickers(exchange, params \\\\ %{}, opts \\\\ [])
      def public_get_v5_market_tickers(%Bourse.Exchange{} = exchange, params, opts) do
        Bourse.Dispatch.call(exchange, %{...}, params, opts)
      end

  """
  @spec build_endpoint_functions([map()]) :: [Macro.t()]
  def build_endpoint_functions(endpoint_configs) do
    Enum.map(endpoint_configs, fn config ->
      fn_name = config.name
      escaped_config = Macro.escape(config)

      # credo:disable-for-next-line ExSlop.Check.Readability.DocFalseOnPublicFunction
      quote do
        @doc false
        def unquote(fn_name)(exchange, params \\ %{}, opts \\ [])

        def unquote(fn_name)(%Bourse.Exchange{} = exchange, params, opts) do
          Bourse.Dispatch.call(exchange, unquote(escaped_config), params, opts)
        end
      end
    end)
  end

  # NOTE: HTTP OPTIONS intentionally excluded — no supported venue uses it as an
  # HTTP method, and Gate/GateIO use "options" as a section name for options
  # trading derivatives. Including it here would cause those sections to be
  # treated as HTTP method leaves instead of traversed as API tree branches.
  @http_methods ~w(get post put delete patch head)
  @default_endpoint_weight 1

  @doc """
  Pre-computes a flat list of endpoint configs from the nested API tree.

  Called at compile time by `__generate__/1`. Recursively traverses the spec's
  API tree until it finds HTTP method keys (`get`, `post`, etc.), then extracts
  endpoint configs from the level below.

  Handles three spec patterns:
  - **Standard**: `%{visibility => %{method => %{path => weight}}}`
  - **Deep nesting**: `%{api_type => %{version => %{visibility => %{method => ...}}}}`
  - **Array endpoints**: `%{... => %{method => [list_of_paths]}}`

  All intermediate keys above the HTTP method become the `:sections` list.

  ## Examples

      Bourse.Exchange.build_endpoint_configs(%{
        "public" => %{"get" => %{"v5/market/tickers" => 5}},
        "private" => %{"post" => %{"v5/order/create" => 2.5}}
      })
      #=> [
      #=>   %{name: :public_get_v5_market_tickers, method: :get,
      #=>     path: "v5/market/tickers", sections: ["public"], weight: 5},
      #=>   %{name: :private_post_v5_order_create, method: :post,
      #=>     path: "v5/order/create", sections: ["private"], weight: 2.5}
      #=> ]

  """
  @spec build_endpoint_configs(map(), map(), [String.t()]) :: [map()]
  def build_endpoint_configs(api_tree, url_prefixes \\ %{}, authenticated_sections \\ [])

  def build_endpoint_configs(api_tree, url_prefixes, authenticated_sections) when is_map(api_tree) do
    auth_list = authenticated_sections || []

    api_tree
    |> traverse_api_tree([], url_prefixes, auth_list)
    |> List.flatten()
  end

  # Recursively traverses the API tree. When a key is an HTTP method,
  # extracts endpoints from its value. Otherwise, recurses deeper.
  defp traverse_api_tree(tree, sections, url_prefixes, auth_set) when is_map(tree) do
    for {key, value} <- tree do
      if key in @http_methods do
        extract_endpoints(key, value, sections, url_prefixes, auth_set)
      else
        # reach:disable-next-line suboptimal — sections is a path of depth ≤4; prepend+reverse would invert order
        traverse_api_tree(value, sections ++ [key], url_prefixes, auth_set)
      end
    end
  end

  defp traverse_api_tree(_non_map, _sections, _url_prefixes, _auth_set), do: []

  # Map-style endpoints: %{path => weight}
  defp extract_endpoints(method, endpoints, sections, url_prefixes, auth_set) when is_map(endpoints) do
    prefix = Map.get(url_prefixes, Enum.join(sections, "."), "/")
    authenticated = section_authenticated?(sections, auth_set)

    for {path, weight} when is_binary(path) <- endpoints do
      %{
        name: build_function_name(sections, method, path),
        method: String.to_existing_atom(method),
        path: path,
        sections: sections,
        weight: normalize_weight(weight),
        url_prefix: prefix,
        authenticated: authenticated
      }
    end
  end

  # Array-style endpoints: [list_of_path_strings] — no per-path weight
  defp extract_endpoints(method, endpoints, sections, url_prefixes, auth_set) when is_list(endpoints) do
    prefix = Map.get(url_prefixes, Enum.join(sections, "."), "/")
    authenticated = section_authenticated?(sections, auth_set)

    for path when is_binary(path) <- endpoints do
      %{
        name: build_function_name(sections, method, path),
        method: String.to_existing_atom(method),
        path: path,
        sections: sections,
        weight: @default_endpoint_weight,
        url_prefix: prefix,
        authenticated: authenticated
      }
    end
  end

  defp extract_endpoints(_method, _other, _sections, _url_prefixes, _auth_set), do: []

  # Authenticated if the exact nested section path or its top-level section
  # appears in the spec's authenticated_sections list.
  defp section_authenticated?([top | _] = sections, auth_list) do
    Enum.join(sections, ".") in auth_list or top in auth_list
  end

  defp section_authenticated?([], _auth_list), do: false

  # Extracts a numeric weight from various spec formats.
  # Complex objects (e.g., Binance's {byLimit: [...], cost: 1}) → extract cost.
  defp normalize_weight(weight) when is_number(weight), do: weight
  defp normalize_weight(%{"cost" => cost}) when is_number(cost), do: cost
  defp normalize_weight(_), do: @default_endpoint_weight

  # Derives a function name atom from sections, HTTP method, and path.
  # e.g., (["private"], "post", "v5/order/create") => :private_post_v5_order_create
  # e.g., (["spot", "v1", "private"], "get", "account/balance") => :spot_v1_private_get_account_balance
  # Called at compile time — atom creation is safe (bounded by spec).
  defp build_function_name(sections, http_method, path) do
    sanitized_path =
      path
      |> String.replace(~r/[\/\-\.\{\}]/, "_")
      |> String.trim_leading("_")
      |> String.trim_trailing("_")
      |> String.downcase()

    prefix = Enum.join(sections, "_")
    :"#{prefix}_#{http_method}_#{sanitized_path}"
  end

  @allowed_opts [:api_key, :secret, :password, :uid, :sandbox, :credentials, :hostname, :options]
  @okx_sandbox_hostname "www.okx.com"

  @doc """
  Creates an exchange configuration from an exchange ID and options.

  Loads the spec, resolves base URLs (with hostname interpolation and
  sandbox/testnet switching), and optionally builds credentials.

  ## Options

    * `:api_key` - API key string (builds credentials automatically)
    * `:secret` - API secret string (builds credentials automatically)
    * `:password` - API password (OKX, KuCoin)
    * `:uid` - User ID
    * `:credentials` - Pre-built `%Bourse.Credentials{}` (overrides key/secret opts)
    * `:sandbox` - Use testnet URLs (default: `false`; OKX defaults to `www.okx.com`)
    * `:hostname` - Override the default hostname
    * `:options` - Exchange-specific options map

  ## Examples

      {:ok, exchange} = Bourse.Exchange.new("bybit")
      {:ok, exchange} = Bourse.Exchange.new("okx", api_key: "k", secret: "s", password: "p")
      {:error, :missing_secret} = Bourse.Exchange.new("bybit", api_key: "k")

  """
  @spec new(String.t() | atom(), keyword()) ::
          {:ok, t()}
          | {:error, term()}
  def new(exchange_id, opts \\ []) when (is_binary(exchange_id) or is_atom(exchange_id)) and is_list(opts) do
    exchange_id = to_string(exchange_id)

    with :ok <- validate_opts(opts),
         {:ok, spec} <- load_spec(exchange_id),
         {:ok, credentials} <- build_credentials(opts) do
      describe = put_authored_exceptions(spec["raw"]["describe"], spec)

      sandbox = resolve_sandbox(credentials, opts)
      urls = describe["urls"] || %{}
      testnet_urls = spec["testnet"]
      hostname = resolve_hostname(exchange_id, sandbox, Keyword.get(opts, :hostname), describe)

      with {:ok, base_urls, sandbox_options} <-
             resolve_base_urls(sandbox, testnet_urls, urls, hostname) do
        {signing_pattern, signing_config} = signing_from_spec(spec)
        error_body_checks = build_error_body_checks(spec)
        error_class_ancestors = build_error_class_ancestors(spec)
        error_handler_checks = build_error_handler_checks(spec, error_class_ancestors)

        options = Map.merge(Keyword.get(opts, :options, %{}), sandbox_options)

        {capabilities_has, capabilities_timeframes, capabilities_features} = build_capabilities(spec)

        exchange = %__MODULE__{
          id: spec["exchange"]["id"],
          name: spec["exchange"]["name"],
          credentials: credentials,
          sandbox: sandbox,
          sandbox_headers: sandbox_headers(sandbox, testnet_urls),
          rate_limit_ms: describe["rateLimit"] || 0,
          hostname: hostname,
          base_urls: base_urls,
          has: capabilities_has,
          timeframes: capabilities_timeframes,
          features: capabilities_features,
          fees: build_fees(spec),
          config:
            spec
            |> build_config()
            |> Map.put("option_quantity", get_in(spec, ["markets", "option_quantity"]))
            |> Map.put("contract_unit", get_in(spec, ["markets", "contract_unit"]))
            |> Map.put("greeks_conventions", get_in(spec, ["markets", "greeks_conventions"])),
          doc_urls: build_doc_urls(spec),
          required_credentials: build_required_credentials(spec, describe),
          signing_pattern: signing_pattern,
          signing_config: signing_config,
          common_currencies: build_common_currencies(spec),
          currencies: build_currencies(spec),
          outbound_aliases: %{},
          symbol_patterns: build_symbol_patterns(spec),
          options: options,
          network_options: build_network_options(spec),
          error_codes: build_error_codes(describe, error_class_ancestors),
          broad_error_patterns: build_broad_error_patterns(describe, error_class_ancestors),
          error_body_checks: error_body_checks,
          error_handler_checks: error_handler_checks,
          error_code_fields: build_error_code_fields(spec),
          http_exceptions: build_http_exceptions(describe),
          status_map: build_status_map(spec, error_class_ancestors),
          retry_classification: build_retry_classification(spec),
          error_class_ancestors: error_class_ancestors,
          request_defaults: build_request_defaults(spec),
          request_param_shape: build_request_param_shape(spec),
          endpoint_selection: build_endpoint_selection(spec),
          default_family: build_default_family(spec),
          request_contracts: build_request_contracts(spec),
          module: Bourse.Registry.module_for(exchange_id),
          spec:
            describe
            |> lean_spec()
            |> put_websocket_section(spec)
            |> Map.put("capabilities", Map.take(spec["capabilities"], ~w(has mapping_complete verification)))
            |> Map.put("error_scopes", build_error_scopes(spec, describe, base_urls, hostname))
        }

        {:ok, exchange}
      end
    end
  end

  @doc """
  Creates an exchange configuration, raising on error.

  ## Examples

      exchange = Bourse.Exchange.new!("bybit")
      exchange = Bourse.Exchange.new!("bybit", api_key: "abc", secret: "xyz")

  """
  @spec new!(String.t() | atom(), keyword()) :: t()
  def new!(exchange_id, opts \\ []) do
    case new(exchange_id, opts) do
      {:ok, exchange} -> exchange
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

  @typedoc "Authored exception scope selected by the request's market family."
  @type error_scope :: String.t() | atom() | nil

  @doc """
  Returns the authored exception scope for a request base URL.

  Scope is never inferred from URL path segments or host labels. Construction
  projects the venue's authored `errors.handle_errors.exception_scopes`
  (API-section → scope) onto production and sandbox base URLs into
  `exchange.spec["error_scopes"]`; this lookup is a pure map read against that
  projection. Venues that declare no scopes return `nil` for every URL.
  """
  @spec error_scope(t(), String.t() | nil) :: String.t() | nil
  def error_scope(%__MODULE__{spec: %{"error_scopes" => scopes}}, base_url) when is_binary(base_url) and is_map(scopes) do
    Map.get(scopes, base_url)
  end

  def error_scope(_exchange, _base_url), do: nil

  @doc "Returns exact error-code mappings for `scope`, with scoped entries taking precedence."
  @spec error_codes_for(t(), error_scope()) :: %{String.t() => Bourse.Error.error_type()}
  def error_codes_for(%__MODULE__{} = exchange, scope) do
    Map.merge(exchange.error_codes, scoped_errors(exchange, scope, "exact"))
  end

  @doc "Returns a copy whose active error maps are selected for `scope`."
  @spec with_error_scope(t(), error_scope()) :: t()
  def with_error_scope(%__MODULE__{} = exchange, nil), do: exchange

  def with_error_scope(%__MODULE__{} = exchange, scope) do
    %{
      exchange
      | error_codes: error_codes_for(exchange, scope),
        broad_error_patterns: Map.merge(exchange.broad_error_patterns, scoped_errors(exchange, scope, "broad"))
    }
  end

  defp scoped_errors(%__MODULE__{} = exchange, scope, key) when is_atom(scope) do
    scoped_errors(exchange, Atom.to_string(scope), key)
  end

  defp scoped_errors(%__MODULE__{spec: spec, error_class_ancestors: ancestors}, scope, key) when is_binary(scope) do
    case get_in(spec, ["exceptions", scope, key]) do
      section when is_map(section) -> build_error_type_map(section, ancestors)
      _ -> %{}
    end
  end

  defp scoped_errors(_exchange, _scope, _key), do: %{}

  @doc """
  Checks if the exchange supports a given capability.

  Returns the derived callable surface, not the provider-support declaration.
  Provider-native capabilities require an authored route; provider-emulated
  capabilities require either an authored raw route or an implemented Bourse
  emulation.
  Verification state never changes this result.

  Capability names use camelCase strings matching the Bourse spec
  (e.g., `"fetchTicker"`, `"createOrder"`).

  ## Examples

      Bourse.Exchange.has?(exchange, "fetchTicker")
      #=> true

      Bourse.Exchange.has?(exchange, "fetchFundingRateHistory")
      #=> false

  """
  @spec has?(t(), String.t()) :: boolean()
  def has?(%__MODULE__{has: has}, capability) when is_binary(capability) do
    Map.get(has, capability, false)
  end

  @doc "Returns whether Bourse has a complete normalized mapping for a unified method."
  @spec mapping_complete?(t(), String.t()) :: boolean()
  def mapping_complete?(%__MODULE__{spec: spec}, _capability) when not is_map_key(spec, "capabilities"), do: true

  def mapping_complete?(%__MODULE__{spec: spec}, capability) when is_binary(capability) do
    get_in(spec, ["capabilities", "mapping_complete", capability]) == true
  end

  @doc "Returns the provider-verification state for a unified method."
  @spec verification_state(t(), String.t()) :: :verified | :unverified
  def verification_state(%__MODULE__{spec: spec}, capability) when is_binary(capability) do
    case get_in(spec, ["capabilities", "verification", capability]) do
      "verified" -> :verified
      _ -> :unverified
    end
  end

  @doc "Returns the provider-support declaration for a unified method."
  @spec venue_support(t(), String.t()) :: true | false | String.t() | nil
  def venue_support(%__MODULE__{spec: spec}, capability) when is_binary(capability) do
    get_in(spec, ["capabilities", "has", capability])
  end

  @doc """
  Returns the unified-to-native OHLCV timeframe map from `capabilities.timeframes`.

  Keys are Bourse unified labels (e.g. `"1h"`, `"15m"`); values are exchange-native
  labels (e.g. `"60"` on Bybit, `"1h"` on Binance). Empty when upstream omitted the map.
  """
  @spec timeframes(t()) :: %{String.t() => String.t()}
  def timeframes(%__MODULE__{timeframes: timeframes}) when is_map(timeframes), do: timeframes

  @doc """
  Returns the static default fee schedule from the derived `fees` spec section.

  This is the exchange-level `describe().fees` default, not live per-market
  `loadMarkets()` fees and not dynamic `fetch_trading_fees` endpoint data.
  """
  @spec fees(t()) :: fees()
  def fees(%__MODULE__{fees: fees}), do: fees

  @doc """
  Returns the derived `config` section — deterministic describe() metadata
  (credentials, limits, status, routing, rate-limit meta, flags).

  Empty when an authored spec has no matching configuration. Individual
  sub-sections are also available via `limits/1`, `status/1`, `routing/1`,
  and `flags/1`.
  """
  @spec config(t()) :: config()
  def config(%__MODULE__{config: config}), do: config

  @doc "Returns the global default `config.limits` map (amount/cost/leverage/price), or `%{}`."
  @spec limits(t()) :: map()
  def limits(%__MODULE__{config: config}), do: config_section(config, "limits")

  @doc "Returns the `config.status` map (status/eta/url/info/updated), or `%{}`."
  @spec status(t()) :: map()
  def status(%__MODULE__{config: config}), do: config_section(config, "status")

  @doc "Returns the `config.routing` map (accountsByType / networks / timeInForce), or `%{}`."
  @spec routing(t()) :: map()
  def routing(%__MODULE__{config: config}), do: config_section(config, "routing")

  @doc "Returns the `config.flags` map (e.g. `dex`), or `%{}`."
  @spec flags(t()) :: map()
  def flags(%__MODULE__{config: config}), do: config_section(config, "flags")

  @doc """
  Returns the documentation URL doc-set (`logo`, `www`, `doc`, `fees`,
  `api_management`) folded from the derived `urls` section, or `%{}`.

  Call URLs live on `base_urls`; this surface is metadata for introspection.
  """
  @spec doc_urls(t()) :: doc_urls()
  def doc_urls(%__MODULE__{doc_urls: doc_urls}), do: doc_urls

  @doc """
  Returns the caller-threaded markets cache, or `nil` when not loaded.

  `Bourse.load_markets/1` and `put_markets/2` store `%Bourse.Market{}` structs,
  and they are the only writers, so that is the only shape a caller sees. Pure
  data — no process or global store. Reload by calling `Bourse.load_markets/1`
  again and threading the returned struct.
  """
  @spec markets(t()) :: market_cache()
  def markets(%__MODULE__{markets: markets}), do: markets

  @doc """
  Returns a copy of `exchange` with the markets cache set to `markets`.

  Use when you already hold a `fetch_markets` result and want subsequent
  market-metadata consumers (e.g. symbol→`market_id` resolution) to reuse it
  without another network round-trip. Prefer `Bourse.load_markets/1` for the
  usual fetch-and-attach path.
  """
  @spec put_markets(t(), [Bourse.Market.t()]) :: t()
  def put_markets(%__MODULE__{} = exchange, markets) when is_list(markets) do
    %{exchange | markets: markets}
  end

  defp config_section(config, key) when is_map(config) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  @doc """
  Returns compile-time currency metadata for `code` from the spec's
  `markets.currencies` catalog (Task 97), or `nil` when absent.

  Records include `networks` when the exchange surfaces per-network deposit/
  withdraw metadata via `loadMarkets()`.

  Network coverage is declared by each supported venue's owned runtime spec.
  """
  @spec currency(t(), String.t()) :: map() | nil
  def currency(%__MODULE__{currencies: currencies}, code) when is_binary(code) do
    Map.get(currencies, code)
  end

  @doc """
  Returns per-network metadata for `currency_code` + `network_code`, or `nil`.

  Returns `nil` when the currency is absent, the exchange spec has empty
  `networks` maps (see `currency/2`), or the requested network code is missing.
  """
  @spec currency_network(t(), String.t(), String.t()) :: map() | nil
  def currency_network(%__MODULE__{} = exchange, currency_code, network_code)
      when is_binary(currency_code) and is_binary(network_code) do
    case currency(exchange, currency_code) do
      %{"networks" => networks} when is_map(networks) -> Map.get(networks, network_code)
      _ -> nil
    end
  end

  # Loads and validates the spec exists
  defp load_spec(exchange_id) do
    with {:ok, _module} <- Bourse.Registry.lookup(exchange_id) do
      {:ok, Bourse.Spec.load!(exchange_id)}
    end
  rescue
    e in [File.Error] ->
      {:error, {:spec_load_failed, e.reason}}

    e in [ArgumentError] ->
      {:error, {:spec_load_failed, Exception.message(e)}}
  end

  # Validates option keys are recognized
  defp validate_opts(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in @allowed_opts)) do
      nil -> :ok
      key -> {:error, {:unknown_option, key}}
    end
  end

  # Builds credentials from opts, or uses pre-built credentials
  defp build_credentials(opts) do
    cond do
      creds = Keyword.get(opts, :credentials) ->
        if is_struct(creds, Bourse.Credentials) do
          {:ok, creds}
        else
          {:error, {:invalid_credentials, "expected %Bourse.Credentials{}, got: #{inspect(creds)}"}}
        end

      Keyword.has_key?(opts, :api_key) || Keyword.has_key?(opts, :secret) ->
        cred_opts =
          opts
          |> Keyword.take([:api_key, :secret, :password, :uid, :sandbox])
          |> Keyword.reject(fn {_k, v} -> is_nil(v) end)

        Bourse.Credentials.new(cred_opts)

      true ->
        {:ok, nil}
    end
  end

  # Sandbox from explicit opt, falling back to credentials.
  #
  # `exchange.sandbox` is authoritative — it drives URL resolution and is the
  # only flag callers should read. `credentials.sandbox` is a construction-time
  # hint (used only here as a fallback) and is intentionally left as-is when
  # an explicit `:sandbox` opt overrides it. The two fields may therefore read
  # differently after construction; trust `exchange.sandbox`.
  defp resolve_sandbox(credentials, opts) do
    cond do
      Keyword.has_key?(opts, :sandbox) -> Keyword.get(opts, :sandbox)
      credentials != nil -> credentials.sandbox
      true -> false
    end
  end

  defp sandbox_headers(true, %{"sandbox_headers" => headers}) when is_map(headers), do: headers
  defp sandbox_headers(_sandbox, _testnet_urls), do: %{}

  defp resolve_hostname("okx", true, nil, _describe), do: @okx_sandbox_hostname
  defp resolve_hostname(_exchange_id, _sandbox, hostname, describe), do: hostname || describe["hostname"]

  # Resolves the base URL map. Production path interpolates `{hostname}` against
  # the spec's `urls.api`. Sandbox path reads `runtime.testnet_urls` (schema 2.4.0):
  #
  #   * `pattern: "separate_host"` — `urls` is a section map which may use
  #     the configured `{hostname}` template.
  #   * `pattern: "sandbox_flag"` — keep prod URLs only when `sandbox_flag_field`
  #     is present; otherwise refuse (production host without a sandbox mechanism).
  #   * `pattern: "none"` — no testnet exists; refuse to construct a sandbox
  #     exchange instead of silently falling through to production URLs.
  #   * `pattern: "separate_host"` with URLs identical to production and no
  #     `sandbox_flag_field` — treated as missing testnet data (aster-style leak).
  #
  # `sandbox_flag_field` is independent of `pattern`: okx/gate/hyperliquid/binance
  # carry both a separate host AND a runtime flag (typically `"sandboxMode"`),
  # which gets merged into `exchange.options` so signing or downstream code can
  # observe it.
  defp resolve_base_urls(false, _testnet_urls, urls, hostname) do
    base = resolve_urls(urls["api"] || %{}, hostname, urls["hostnames"])
    {:ok, base, %{}}
  end

  defp resolve_base_urls(true, %{"pattern" => "none"}, _urls, _hostname) do
    {:error, :no_testnet_data}
  end

  defp resolve_base_urls(true, %{"urls" => urls_map} = testnet_urls, urls, hostname) when is_map(urls_map) do
    sandbox_options = sandbox_flag_options(testnet_urls["sandbox_flag_field"])

    cond do
      sandbox_options != %{} ->
        {:ok, resolve_urls(urls_map, hostname, urls["hostnames"]), sandbox_options}

      urls_map == %{} ->
        {:error, :no_testnet_data}

      production_url_fallback?(urls_map, urls, hostname) ->
        {:error, :no_testnet_data}

      true ->
        {:ok, resolve_urls(urls_map, hostname, urls["hostnames"]), sandbox_options}
    end
  end

  defp resolve_base_urls(true, %{"pattern" => "sandbox_flag"} = testnet_urls, urls, hostname) do
    case testnet_urls["sandbox_flag_field"] do
      field when is_binary(field) and field != "" ->
        base = resolve_urls(urls["api"] || %{}, hostname, urls["hostnames"])
        {:ok, base, %{field => true}}

      _ ->
        {:error, :no_testnet_data}
    end
  end

  defp resolve_base_urls(true, _missing_or_malformed, _urls, _hostname) do
    {:error, :no_testnet_data}
  end

  defp sandbox_flag_options(nil), do: %{}
  defp sandbox_flag_options(field) when is_binary(field), do: %{field => true}

  # True when sandbox URL strings match production — sandbox:true would hit live hosts.
  defp production_url_fallback?(sandbox_urls, prod_urls, hostname) do
    prod_base = resolve_urls(prod_urls["api"] || %{}, hostname, prod_urls["hostnames"])
    flatten_url_strings(sandbox_urls) == flatten_url_strings(prod_base)
  end

  defp flatten_url_strings(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {_, value} when is_binary(value) -> [value]
      {_, value} when is_map(value) -> flatten_url_strings(value)
      _ -> []
    end)
    |> Enum.sort()
  end

  # Recursively interpolates {hostname} in all string values at any depth.
  # Preserves full nested structure — dispatch (Phase 2) handles URL lookup.
  #
  # Top-level section keys (e.g., "contract", "spot") may be overridden by a
  # matching string entry in `urls["hostnames"]`. Used by htx/huobi which split
  # the API across hosts (contract → api.hbdm.vn, spot → api.huobi.pro) while
  # `urls.api` uniformly uses the "{hostname}" placeholder. Nested-map values
  # in `hostnames` (e.g., htx's status page by market type) are ignored — those
  # sections need a market-type aware lookup that isn't modelled yet.
  # TODO(Task 80): market-type-aware hostname routing for nested `urls.hostnames`
  # entries (htx/huobi `status` page). Deferred until a consumer surfaces need.
  defp resolve_urls(url_set, default_hostname, hostnames) when is_map(url_set) do
    Map.new(url_set, fn {key, value} ->
      section_hostname = section_hostname(hostnames, key, default_hostname)
      {key, resolve_urls_value(value, section_hostname)}
    end)
  end

  defp resolve_urls(_url_set, _hostname, _hostnames), do: %{}

  defp resolve_urls_value(value, hostname) when is_binary(value), do: interpolate_hostname(value, hostname)

  defp resolve_urls_value(value, hostname) when is_map(value), do: resolve_urls(value, hostname, nil)

  defp resolve_urls_value(value, _hostname), do: value

  defp section_hostname(hostnames, key, default) when is_map(hostnames) do
    case Map.get(hostnames, key) do
      h when is_binary(h) -> h
      _ -> default
    end
  end

  defp section_hostname(_hostnames, _key, default), do: default

  # Replaces {hostname} placeholder in URL strings.
  # If hostname is nil, returns the URL unchanged (already absolute).
  defp interpolate_hostname(url, nil), do: url
  defp interpolate_hostname(url, hostname), do: String.replace(url, "{hostname}", hostname)

  # ---------------------------------------------------------------------------
  # URL Prefix Computation
  #
  # Many exchanges have invisible URL prefixes (e.g., /api/v5/, /spot/) not
  # encoded in the API tree paths. The authored url_prefix field provides
  # pre-computed full URLs.
  # We extract the path prefix relative to the section's base URL.
  #
  # Design: config over inference. Bourse consumes the authored answer without
  # heuristic derivation.
  # ---------------------------------------------------------------------------

  @doc false
  @spec compute_url_prefixes(map(), String.t()) :: %{String.t() => String.t()}
  def compute_url_prefixes(spec, hostname) do
    url_templates = get_in(spec, ["raw", "url_templates"]) || %{}
    urls_api = get_in(spec, ["raw", "describe", "urls", "api"]) || %{}
    hostnames = get_in(spec, ["raw", "describe", "urls", "hostnames"])
    resolved_api = resolve_urls(urls_api, hostname, hostnames)

    # First pass: read url_prefix from spec, extract path relative to base URL
    direct =
      for {section_key, template} <- url_templates,
          url_prefix_full = template["url_prefix"],
          is_binary(url_prefix_full),
          into: %{} do
        base_url = section_base_url(section_key, resolved_api)
        {section_key, path_from_url_prefix(url_prefix_full, base_url)}
      end

    # Second pass: inherit prefix only for private sections without url_prefix.
    # Non-private sections (e.g., "history", "broker") that lack url_prefix get
    # the default "/" — they have their own base URLs and must not borrow prefixes.
    for {section_key, _template} <- url_templates, into: direct do
      {section_key, resolve_section_prefix(section_key, direct)}
    end
  end

  # Extracts the path prefix by removing the base URL from the full url_prefix.
  # When no base URL is found (e.g., OKX uses "rest" key), falls back to URI path.
  defp path_from_url_prefix(url_prefix_full, base_url) when is_binary(base_url) do
    trimmed = String.trim_trailing(base_url, "/")

    if String.starts_with?(url_prefix_full, trimmed) do
      url_prefix_full
      |> String.slice(String.length(trimmed)..-1//1)
      |> normalize_prefix()
    else
      normalize_prefix(URI.parse(url_prefix_full).path || "/")
    end
  end

  defp path_from_url_prefix(url_prefix_full, _nil_base) do
    normalize_prefix(URI.parse(url_prefix_full).path || "/")
  end

  # Resolves the base URL for a section key by navigating the urls.api map.
  # "public" → urls.api["public"], "public.spot" → urls.api["public"]["spot"]
  defp section_base_url(section_key, resolved_api) do
    section_key
    |> String.split(".")
    |> navigate_to_url(resolved_api)
  end

  defp navigate_to_url([key | rest], map) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      value when is_map(value) and rest != [] -> navigate_to_url(rest, value)
      _ -> nil
    end
  end

  defp navigate_to_url(_, _), do: nil

  # Ensures prefix starts and ends with "/"
  defp normalize_prefix(""), do: "/"

  defp normalize_prefix(prefix) do
    prefix = if String.starts_with?(prefix, "/"), do: prefix, else: "/" <> prefix
    if String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/"
  end

  # Resolves prefix for a section: returns existing direct prefix, inherits for
  # private sections, or defaults to "/" for non-private sections without resolved_url.
  defp resolve_section_prefix(section_key, direct_prefixes) do
    case Map.get(direct_prefixes, section_key) do
      nil when is_binary(section_key) -> maybe_inherit_prefix(section_key, direct_prefixes)
      nil -> "/"
      existing -> existing
    end
  end

  # Private sections inherit from their public counterpart.
  # Non-private sections (e.g., "history", "broker") get default "/" —
  # they have their own base URLs and must not borrow prefixes.
  defp maybe_inherit_prefix(section_key, direct_prefixes) do
    if String.contains?(String.downcase(section_key), "private") do
      section_key
      |> build_private_candidates()
      |> Enum.find_value("/", &Map.get(direct_prefixes, &1))
    else
      "/"
    end
  end

  # Builds ordered candidate list for private→public prefix inheritance.
  # Rule 1: Direct sibling replacement (contract.private→contract.public, fapiPrivate→fapiPublic)
  # Rule 2: Stripped suffix (utaPrivate→uta, exchangePrivate→exchange)
  # No bare "public" fallback for namespaced sections — plain "private" naturally
  # gets "public" via Rule 1 (String.replace("private", "private", "public") = "public").
  defp build_private_candidates(section_key) do
    sibling = [
      String.replace(section_key, "private", "public"),
      String.replace(section_key, "Private", "Public")
    ]

    stripped = [
      String.replace(section_key, "Private", ""),
      String.replace(section_key, "private", "")
    ]

    (sibling ++ stripped)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == section_key or &1 == ""))
  end

  # Converts the owned symbol-pattern contract to its closed runtime atoms.
  @market_type_keys %{"spot" => :spot, "swap" => :swap, "future" => :future, "option" => :option}
  @symbol_pattern_atoms %{
    "dash_upper" => :dash_upper,
    "future_ddmmmyy" => :future_ddmmmyy,
    "future_yymmdd" => :future_yymmdd,
    "implicit" => :implicit,
    "no_separator_upper" => :no_separator_upper,
    "option_base_yymmdd" => :option_base_yymmdd,
    "option_base_yyyymmdd" => :option_base_yyyymmdd,
    "option_ddmmmyy" => :option_ddmmmyy,
    "option_with_settle" => :option_with_settle,
    "option_yymmdd" => :option_yymmdd,
    "suffix_perp" => :suffix_perp,
    "suffix_perpetual" => :suffix_perpetual,
    "suffix_swap" => :suffix_swap,
    "underscore_upper" => :underscore_upper
  }
  @symbol_cases %{"lower" => :lower, "mixed" => :mixed, "upper" => :upper}
  @date_formats %{"ddmmmyy" => :ddmmmyy, "yymmdd" => :yymmdd, "yyyymmdd" => :yyyymmdd}

  defp build_symbol_patterns(spec) do
    for {key, entry} <- get_in(spec, ["markets", "symbol_patterns"]), into: %{} do
      market_type = Map.fetch!(@market_type_keys, key)
      {market_type, build_symbol_pattern(market_type, entry)}
    end
  end

  defp build_symbol_pattern(market_type, entry) do
    config = %{
      pattern: Map.fetch!(@symbol_pattern_atoms, Map.fetch!(entry, "pattern")),
      separator: Map.fetch!(entry, "separator"),
      case: Map.fetch!(@symbol_cases, Map.fetch!(entry, "case")),
      date_format: date_format(Map.fetch!(entry, "date_format")),
      suffix: Map.fetch!(entry, "suffix"),
      prefix: Map.fetch!(entry, "prefix")
    }

    if market_type in [:future, :option, :swap] do
      Map.put(config, :quote_settled_suffix, Map.get(entry, "quote_settled_suffix"))
    else
      config
    end
  end

  defp date_format(nil), do: nil
  defp date_format(value), do: Map.fetch!(@date_formats, value)

  # Authored capabilities section: normalized has flags,
  # unified→native OHLCV timeframes, and per-market-type features matrix.
  defp build_capabilities(spec) do
    capabilities = spec["capabilities"] || %{}
    support = Map.get(capabilities, "has") || %{}
    unified = get_in(spec, ["endpoints", "unified"]) || %{}

    {
      callable_capabilities(support, unified),
      Map.get(capabilities, "timeframes") || %{},
      Map.get(capabilities, "features")
    }
  end

  defp callable_capabilities(support, unified) do
    Map.new(support, fn {method, declaration} ->
      {method, callable_capability?(method, declaration, unified)}
    end)
  end

  defp callable_capability?(method, true, unified), do: Map.get(unified, method, []) != []

  defp callable_capability?(method, "emulated", unified) do
    Map.get(unified, method, []) != [] or implemented_emulation?(method)
  end

  defp callable_capability?(_method, _declaration, _unified), do: false

  defp implemented_emulation?(method) do
    MapSet.member?(Bourse.Emulation.implemented_methods(), Bourse.Emulation.method_atom(method))
  end

  @fee_market_type_keys %{
    "future" => :future,
    "inverse" => :inverse,
    "linear" => :linear,
    "option" => :option,
    "spot" => :spot,
    "swap" => :swap
  }

  defp build_fees(spec) do
    case spec["fees"] do
      fees when is_map(fees) ->
        fees
        |> build_fee_map()
        |> nil_if_empty()

      _ ->
        nil
    end
  end

  # Authored `config` section: deterministic describe()
  # metadata — credentials, global default limits, status, options routing
  # (accountsByType / networks / timeInForce), rate-limit meta, and misc flags
  # (dex). Stored verbatim (string keys) to match the JSON spec; `credentials`
  # is re-surfaced separately on `required_credentials`.
  defp build_config(spec) do
    case spec["config"] do
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  # Required-credential flags, re-pointed to the derived `config.credentials`
  # source (Task 46). Falls back to the raw `requiredCredentials` describe key
  # for specs predating the `config` section.
  defp build_required_credentials(spec, describe) do
    case get_in(spec, ["config", "credentials"]) do
      creds when is_map(creds) -> creds
      _ -> describe["requiredCredentials"] || %{}
    end
  end

  # Documentation URL doc-set folded from the derived top-level `urls` section
  # (Task 46): logo, www, doc, fees, api_management. The call URLs (`urls.api`,
  # including `urls.api.ws`) are resolved separately into `base_urls` / the WS
  # config and are intentionally excluded here.
  @doc_url_keys ~w(logo www doc fees api_management)
  defp build_doc_urls(spec) do
    case spec["urls"] do
      urls when is_map(urls) -> Map.take(urls, @doc_url_keys)
      _ -> %{}
    end
  end

  defp build_fee_map(fees) do
    @fee_market_type_keys
    |> Enum.reduce(%{}, fn {source_key, target_key}, acc ->
      maybe_put(acc, target_key, build_market_fee_block(fees[source_key]))
    end)
    |> maybe_put(:trading, build_trading_fee(fees["trading"]))
    |> maybe_put(:funding, build_funding_fee(fees["funding"]))
    |> maybe_put(:static_market_fees, static_market_fees?(fees))
  end

  # Authored opt-in: does this venue publish a static public fee schedule whose
  # rates are the correct default for market rows? Every owned spec declares it.
  defp static_market_fees?(%{"static_market_fees" => flag}) when is_boolean(flag), do: flag

  defp build_market_fee_block(block) when is_map(block) do
    %{}
    |> maybe_put(:trading, build_trading_fee(block["trading"]))
    |> maybe_put(:funding, build_funding_fee(block["funding"]))
    |> nil_if_empty()
  end

  defp build_market_fee_block(_), do: nil

  defp build_trading_fee(trading) when is_map(trading) do
    maker = static_fee_value(trading["maker"])
    taker = static_fee_value(trading["taker"])
    percentage = static_fee_value(trading["percentage"])
    tier_based = static_fee_value(trading["tierBased"])
    fee_side = static_fee_value(trading["feeSide"])
    tiers = build_fee_tiers(trading["tiers"])

    %{
      maker: maker,
      taker: taker,
      percentage: percentage,
      tier_based: tier_based,
      fee_side: fee_side,
      tiers: tiers,
      fee: %Bourse.TradingFee{
        maker: maker,
        taker: taker,
        percentage: percentage,
        tier_based: tier_based,
        info: trading
      },
      info: trading
    }
  end

  defp build_trading_fee(_), do: nil

  defp build_funding_fee(funding) when is_map(funding) do
    %Bourse.DepositWithdrawFee{
      withdraw: static_fee_value(funding["withdraw"]),
      deposit: static_fee_value(funding["deposit"]),
      info: funding
    }
  end

  defp build_funding_fee(_), do: nil

  defp build_fee_tiers(tiers) when is_map(tiers) do
    %{}
    |> maybe_put(:maker, static_fee_value(tiers["maker"]))
    |> maybe_put(:taker, static_fee_value(tiers["taker"]))
    |> nil_if_empty()
  end

  defp build_fee_tiers(_), do: nil

  defp static_fee_value("__undefined"), do: nil
  defp static_fee_value(value), do: value

  defp nil_if_empty(map) when map_size(map) == 0, do: nil
  defp nil_if_empty(map), do: map

  # Inbound currency aliases — prefer v4 `markets.patterns.currency_aliases`
  # (Task 97) over legacy `raw.describe.commonCurrencies`.
  defp build_common_currencies(spec) do
    case get_in(spec, ["markets", "patterns", "currency_aliases"]) do
      aliases when is_map(aliases) -> aliases
      _ -> get_in(spec, ["raw", "describe", "commonCurrencies"]) || %{}
    end
  end

  # Per-currency metadata + network catalog from `markets.currencies` (Task 97).
  defp build_currencies(spec) do
    case get_in(spec, ["markets", "currencies"]) do
      currencies when is_map(currencies) -> currencies
      _ -> %{}
    end
  end

  defp build_network_options(spec) do
    get_in(spec, ["raw", "describe", "options"]) || %{}
  end

  # Projects authored `errors.handle_errors.exception_scopes` (API section →
  # exception scope) onto every known base URL for the venue. Includes both the
  # live `base_urls` map and the production/testnet URL sets so a sandbox host
  # still classifies correctly when the exchange was constructed against mainnet
  # (and vice versa). No path/host inference — unlisted URLs resolve to no scope.
  defp build_error_scopes(spec, describe, base_urls, hostname) do
    declaration = get_in(spec, ["errors", "handle_errors", "exception_scopes"]) || %{}
    hostnames = get_in(describe, ["urls", "hostnames"])
    prod_urls = resolve_urls(get_in(describe, ["urls", "api"]) || %{}, hostname, hostnames)

    testnet_urls =
      case spec["testnet"] do
        %{"urls" => urls} when is_map(urls) -> resolve_urls(urls, hostname, hostnames)
        _ -> %{}
      end

    Enum.reduce([prod_urls, testnet_urls, base_urls], %{}, fn url_map, acc ->
      project_exception_scopes(acc, url_map, declaration)
    end)
  end

  defp project_exception_scopes(acc, url_map, declaration) when is_map(url_map) and is_map(declaration) do
    Enum.reduce(flatten_section_urls(url_map), acc, fn {section, url}, acc ->
      case Map.get(declaration, section) do
        scope when is_binary(scope) and scope != "" -> Map.put(acc, url, scope)
        _ -> acc
      end
    end)
  end

  defp project_exception_scopes(acc, _url_map, _declaration), do: acc

  defp flatten_section_urls(map) when is_map(map) do
    Enum.flat_map(map, fn
      {section, url} when is_binary(section) and is_binary(url) ->
        [{section, url}]

      {section, nested} when is_binary(section) and is_map(nested) ->
        for {child, url} <- flatten_section_urls(nested), do: {"#{section}.#{child}", url}

      _ ->
        []
    end)
  end

  # Pre-processes spec exact exceptions into %{error_code => error_type} map.
  # Exact entries are keyed by error codes (e.g., "10001" => :insufficient_funds).
  # `ancestors` (errors.class_hierarchy.ancestors) lets unmapped leaf classes
  # resolve through their nearest mapped parent (Phase 13 contract).
  defp build_error_codes(describe, ancestors) do
    describe
    |> exceptions_section("exact")
    |> build_error_type_map(ancestors)
  end

  # Pre-processes spec broad exceptions into %{message_substring => error_type} map.
  # Broad entries are keyed by error message substrings for runtime substring matching
  # (e.g., "Insufficient balance!" => :insufficient_funds).
  defp build_broad_error_patterns(describe, ancestors) do
    describe
    |> exceptions_section("broad")
    |> build_error_type_map(ancestors)
  end

  defp build_error_type_map(entries, ancestors) do
    Map.new(entries, fn {identifier, class} ->
      {identifier, Bourse.Error.from_spec_class(spec_class(class), ancestors)}
    end)
  end

  defp put_authored_exceptions(describe, spec) do
    raw = describe["exceptions"]
    authored = get_in(spec, ["errors", "handle_errors", "exceptions"])

    if is_map(raw) and is_map(authored) do
      Map.put(describe, "exceptions", merge_exception_maps(raw, authored))
    else
      describe
    end
  end

  defp merge_exception_maps(raw, authored) do
    Map.merge(raw, authored, fn _key, raw_value, authored_value ->
      if is_map(raw_value) and is_map(authored_value) do
        merge_exception_maps(raw_value, authored_value)
      else
        authored_value
      end
    end)
  end

  # `describe["exceptions"]` may be a map, absent, or the "__undefined" sentinel
  # (an undefined JS value projected verbatim). Only a real nested map yields
  # entries; anything else (sentinel string, missing) normalizes to empty.
  # A flat `exceptions` map (codes at the top level, no nested "exact"/"broad")
  # is treated as the exact-code set — drop the reserved section keys.
  defp exceptions_section(%{"exceptions" => %{} = exceptions}, "exact") do
    case Map.get(exceptions, "exact") do
      section when is_map(section) -> section
      _ -> Map.reject(exceptions, fn {key, value} -> key in ["exact", "broad"] or is_map(value) end)
    end
  end

  defp exceptions_section(%{"exceptions" => %{} = exceptions}, key) do
    case Map.get(exceptions, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp exceptions_section(_describe, _key), do: %{}

  # An exception entry's class is usually a string ("__function:InvalidOrder"),
  # but some reference specs encode CCXT's `[ErrorClass, "message"]` form
  # as a list — take the leading class, discard the message.
  defp spec_class([class | _]) when is_binary(class), do: class
  defp spec_class(class) when is_binary(class), do: class
  defp spec_class(_), do: "ExchangeError"

  # Builds the upstream class hierarchy ancestors map (Phase 13 — schema v4
  # errors.class_hierarchy.ancestors). Shape: %{"ClassName" => [ancestor, ...]}
  # with the nearest ancestor first. Empty when the spec predates the contract.
  defp build_error_class_ancestors(spec) do
    case get_in(spec, ["errors", "class_hierarchy", "ancestors"]) do
      ancestors when is_map(ancestors) -> ancestors
      _ -> %{}
    end
  end

  # Builds the HTTP status → error_type map from the v4 errors.status_map
  # contract (Phase 13). Each status maps to a list of {class, source} entries;
  # the first entry wins. Preferred over the legacy describe.httpExceptions —
  # it is normalized and hierarchy-resolvable. Empty when absent.
  defp build_status_map(spec, ancestors) do
    case get_in(spec, ["errors", "status_map"]) do
      status_map when is_map(status_map) ->
        status_map
        |> Enum.flat_map(&status_map_entry(&1, ancestors))
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp status_map_entry({status, [%{"class" => class} | _]}, ancestors) do
    [{to_string(status), Bourse.Error.from_spec_class(class, ancestors)}]
  end

  defp status_map_entry(_, _), do: []

  # Inverts the v4 errors.retry_classification contract (Phase 13) from
  # %{bucket => [class, ...]} into a faithful %{class_name => bucket_atom} index.
  # Stored verbatim (class-keyed) for principled retry queries; the runtime tags
  # errors via Bourse.Error.retry_class/1 once a type atom is resolved.
  @retry_buckets %{
    "auth" => :auth,
    "network" => :network,
    "rate_limit" => :rate_limit,
    "server_busy" => :server_busy,
    "non_retryable" => :non_retryable
  }

  defp build_retry_classification(spec) do
    case get_in(spec, ["errors", "retry_classification"]) do
      classification when is_map(classification) ->
        for {bucket, classes} <- classification,
            Map.has_key?(@retry_buckets, bucket),
            class <- List.wrap(classes),
            into: %{} do
          {class, Map.fetch!(@retry_buckets, bucket)}
        end

      _ ->
        %{}
    end
  end

  @http_error_min_status 400
  @error_body_roles %{
    "error_code" => :error_code,
    "status_sentinel" => :status_sentinel
  }

  # Builds request_defaults from the authored endpoints.request.defaults slice.
  # Filters to kind: "literal" entries only; unresolved entries remain explicit.
  # Result shape: %{"fetchTime" => %{"type" => "exchangeStatus"}, ...}
  defp build_request_defaults(spec) do
    spec
    |> get_in(["endpoints", "request", "defaults"])
    |> do_build_request_defaults()
  end

  defp do_build_request_defaults(rd) when is_map(rd) do
    rd
    |> Enum.flat_map(&method_literal_pair/1)
    |> Map.new()
  end

  defp do_build_request_defaults(_), do: %{}

  defp build_request_param_shape(spec) do
    spec
    |> get_in(["endpoints", "request", "defaults"])
    |> case do
      %{} = defaults -> defaults
      _ -> %{}
    end
  end

  defp build_endpoint_selection(spec) do
    get_in(spec, ["endpoints", "request", "endpoint_selection"]) || %{}
  end

  # Venue-level default market family for multi-endpoint selection when the
  # caller supplies no type/subType/symbol signal. Authored under
  # `config.default_family` (e.g. "linear", "spot").
  @default_family_values ~w(spot linear inverse option swap future)
  defp build_default_family(spec) do
    case get_in(spec, ["config", "default_family"]) do
      family when family in @default_family_values -> family
      _ -> nil
    end
  end

  defp method_literal_pair({method_name, entries}) do
    case extract_literal_defaults(entries) do
      literals when map_size(literals) > 0 -> [{method_name, literals}]
      _ -> []
    end
  end

  defp extract_literal_defaults(entries) when is_map(entries) do
    entries
    |> Enum.flat_map(fn
      {key, %{"kind" => "literal", "value" => value}} -> [{key, value}]
      _ -> []
    end)
    |> Map.new()
  end

  defp extract_literal_defaults(_), do: %{}

  defp build_request_contracts(spec) do
    shapes = get_in(spec, ["endpoints", "request", "shape"]) || %{}

    Enum.reduce(shapes, %{}, fn {section_key, shape}, contracts ->
      Map.merge(contracts, build_section_request_contracts(spec, section_key, shape))
    end)
  end

  defp build_section_request_contracts(spec, section_key, %{"endpoints" => endpoints} = shape)
       when is_binary(section_key) and is_list(endpoints) do
    sections = String.split(section_key, ".")

    endpoints
    |> Enum.flat_map(&request_contract_pair(spec, section_key, sections, shape, &1))
    |> Map.new()
  end

  defp build_section_request_contracts(_spec, _section_key, _shape), do: %{}

  defp request_contract_pair(spec, section_key, sections, shape, %{} = endpoint) do
    with method when not is_nil(method) <- request_method(endpoint),
         path when not is_nil(path) <- request_path(endpoint) do
      contract =
        %{}
        |> maybe_put(:method, method)
        |> maybe_put(:path, path)
        |> maybe_put(:path_params, request_path_params(endpoint))
        |> maybe_put(:body_encoding, shape["body_encoding"])
        |> maybe_put(:content_type, shape["content_type"])
        |> maybe_put(:timestamp_recipe, timestamp_recipe(spec, section_key, sections))
        |> maybe_put(:weight, request_cost(spec, section_key, method, path))
        |> maybe_put(:rate_limit, request_rate_limit(spec, section_key, method, path))

      [{{sections, method, path}, contract}]
    else
      _ -> []
    end
  end

  defp request_contract_pair(_spec, _section_key, _sections, _shape, _endpoint), do: []

  defp request_method(%{"http_verb" => verb}) when is_binary(verb) do
    case String.downcase(verb) do
      "get" -> :get
      "post" -> :post
      "put" -> :put
      "delete" -> :delete
      "patch" -> :patch
      "head" -> :head
      _ -> nil
    end
  end

  defp request_method(_endpoint), do: nil

  defp request_path(%{"path_template" => path}) when is_binary(path), do: path
  defp request_path(_endpoint), do: nil

  defp request_path_params(%{"path_params" => params}) when is_list(params), do: params
  defp request_path_params(_endpoint), do: nil

  defp request_cost(spec, section_key, method, path) do
    case request_rate_limit(spec, section_key, method, path) do
      %{cost: cost} when is_number(cost) -> cost
      _ -> nil
    end
  end

  defp request_rate_limit(spec, section_key, method, path) do
    key = "#{section_key}.#{method}.#{path}"
    endpoint_cost = get_in(spec, ["rate_limits", "per_endpoint_cost", key]) || %{}
    binding = get_in(spec, ["rate_limits", "endpoint_cost_binding"]) || %{}
    bucket = rate_limit_bucket(spec, binding["bucket_index"])

    cost = Map.get(endpoint_cost, "cost")
    axes = first_axes(endpoint_cost["axes"], binding["axes"], bucket["axes"])
    rate_limit_ms = bucket["rate_limit_ms"]

    cond do
      is_number(cost) and axes != [] ->
        %{cost: cost, axes: axes, rate_limit_ms: rate_limit_ms, bucket_index: binding["bucket_index"]}

      is_number(cost) ->
        %{cost: cost}

      true ->
        nil
    end
  end

  defp rate_limit_bucket(spec, index) when is_integer(index) do
    spec
    |> get_in(["rate_limits", "buckets", "buckets"])
    |> case do
      buckets when is_list(buckets) -> Enum.at(buckets, index) || %{}
      _ -> %{}
    end
  end

  defp rate_limit_bucket(_spec, _index), do: %{}

  defp first_axes(axis_candidates, fallback_axes, bucket_axes) do
    [axis_candidates, fallback_axes, bucket_axes]
    |> Enum.map(&normalize_axes/1)
    |> Enum.find([], &(&1 != []))
  end

  defp normalize_axes(axes) when is_list(axes), do: Enum.filter(axes, &is_binary/1)
  defp normalize_axes(%{} = axes) when map_size(axes) == 0, do: []

  defp normalize_axes(%{} = axes) do
    axes
    |> Map.values()
    |> List.flatten()
    |> normalize_axes()
  end

  defp normalize_axes(_axes), do: []

  defp timestamp_recipe(spec, section_key, [top_section | _]) do
    get_in(spec, ["auth", "sign_recipe", section_key, "timestamp"]) ||
      get_in(spec, ["auth", "sign_recipe", top_section, "timestamp"]) ||
      get_in(spec, ["auth", "sign_recipe", "private", "timestamp"])
  end

  defp timestamp_recipe(spec, _section_key, []) do
    get_in(spec, ["auth", "sign_recipe", "private", "timestamp"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Decodes the closed authored vocabulary into the runtime atom-keyed shape.
  defp build_error_body_checks(spec) do
    spec
    |> get_in(["errors", "handle_errors", "runtime_body_checks"])
    |> Enum.map(fn entry ->
      %{
        field: entry["field"],
        field2: entry["field2"],
        roles: Enum.map(entry["roles"], &Map.fetch!(@error_body_roles, &1)),
        sentinel_values:
          Enum.map(entry["sentinel_values"], fn sentinel ->
            %{operator: sentinel["operator"], value: sentinel["value"]}
          end)
      }
    end)
  end

  defp build_error_code_fields(spec), do: get_in(spec, ["errors", "handle_errors", "runtime_code_fields"])

  defp build_error_handler_checks(spec, ancestors) do
    spec
    |> get_in(["endpoints", "handlers", "error"])
    |> Kernel.||([])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_error_handler_check(&1, ancestors))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_error_handler_check(%{"predicate_limbs" => limbs, "exception_class" => class}, ancestors)
       when is_list(limbs) do
    body_contains = collect_limb_values(limbs, "body_contains")
    status_guard = status_guard_from_limbs(limbs)

    if body_contains != [] and not is_nil(status_guard) do
      %{
        status_guard: status_guard,
        body_contains: body_contains,
        error_type: Bourse.Error.from_spec_class(class, ancestors)
      }
    end
  end

  defp normalize_error_handler_check(_entry, _ancestors), do: nil

  defp collect_limb_values(limbs, kind) do
    limbs
    |> Enum.filter(&match?(%{"kind" => ^kind}, &1))
    |> Enum.flat_map(&normalize_limb_values/1)
    |> Enum.uniq()
  end

  defp normalize_limb_values(%{"values" => values}) when is_list(values) do
    Enum.filter(values, &is_binary/1)
  end

  defp normalize_limb_values(_limb), do: []

  defp status_guard_from_limbs(limbs) do
    Enum.find_value(limbs, &normalize_status_guard/1)
  end

  defp normalize_status_guard(%{"kind" => "http_status_range", "values" => ["400"]}) do
    {:gte, @http_error_min_status}
  end

  defp normalize_status_guard(%{"kind" => "http_status_eq", "values" => values}) when is_list(values) do
    statuses =
      values
      |> Enum.map(&parse_http_status/1)
      |> Enum.reject(&is_nil/1)

    if statuses == [], do: nil, else: {:in, statuses}
  end

  defp normalize_status_guard(_limb), do: nil

  defp parse_http_status(value) when is_binary(value) do
    case Integer.parse(value) do
      {status, ""} -> status
      _ -> nil
    end
  end

  defp parse_http_status(_value), do: nil

  # Pre-processes HTTP status code exception mappings.
  defp build_http_exceptions(describe) do
    Map.new(describe["httpExceptions"] || %{}, fn {status, class} -> {status, Bourse.Error.from_spec_class(class)} end)
  end

  # lean_spec only strips "api" — may need to strip more keys as spec evolves.
  # Full spec access is via generated modules (Phase 2).
  defp lean_spec(describe) do
    Map.delete(describe, "api")
  end

  defp put_websocket_section(lean, spec) do
    case Map.get(spec, "websocket") do
      nil -> lean
      websocket -> Map.put(lean, "websocket", websocket)
    end
  end

  # Formats error tuples into human-readable messages
  defp format_error({:unsupported_exchange, id}), do: "unsupported exchange: #{inspect(id)}"
  defp format_error({:spec_load_failed, reason}), do: "failed to load spec: #{inspect(reason)}"
  defp format_error({:unknown_option, key}), do: "unknown option: #{inspect(key)}"
  defp format_error({:invalid_credentials, msg}), do: msg
  defp format_error(:missing_api_key), do: "api_key is required when secret is provided"
  defp format_error(:missing_secret), do: "secret is required when api_key is provided"
  defp format_error({:invalid_type, key}), do: "#{key} must be a string"

  defp format_error(:no_testnet_data) do
    ~s|no testnet data in spec (runtime.testnet_urls.pattern = "none"). Cannot construct sandbox exchange.|
  end

  defp format_error(reason), do: inspect(reason)
end
