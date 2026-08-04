defmodule Bourse.Test.Generator.RawEndpointProbe.Config do
  @moduledoc """
  Per-exchange configuration for `Bourse.Test.Generator.RawEndpointProbe` (Task 83).

  Module attributes drive generator behavior at compile time:

    * `@path_param_defaults` — maps exchange id → `%{param_name => value}` used
      to populate `{curly}` path placeholders. Endpoints whose path has
      unresolved placeholders after merging these defaults are silently
      skipped (no test emitted). Expansion is opt-in per exchange: add entries
      → coverage grows.

    * `@unavailable_on_testnet` — maps exchange id → section prefix list
      (e.g. Binance `sapi` / `papi` / `eapi`). Private probes on sandbox emit
      one `:skip` test per matched prefix instead of N inconclusive calls.

    * `@ws_only_methods` — maps exchange id → method-name prefix set (entries
      ending in `_` match `String.starts_with?/2`). One `:skip` per prefix.

    * `@needs_params_prefixes` — maps exchange id → path-prefix list for public
      endpoints whose required query params cannot be inferred (Task 111). One
      `:skip` test per prefix instead of N `bad_request` flunks.

    * `@retired_endpoint_*` / `@misclassified_endpoint_names` — live-sweep
      dispositions for endpoints that stay generated but should not be treated
      as venue capability by raw probes.

    * `query_params_for/2` — compile-time query-param map merged into probe
      calls (Task 111). Bybit V5 market paths resolve `category` / `symbol` /
      `interval` from `SymbolResolver.pick_symbol/1` and the vendored markets
      index.

    * `endpoints.transaction_classification` (Task 117) — per-endpoint
      `transactional` / `on_chain` flags from the vendored spec. Write methods
      with `transactional: false` follow GET tag rules (`:public` / `:private`);
      `transactional: true` routes to `:public_dangerous` or
      `:private_dangerous` by the endpoint's `authenticated` flag. Endpoints
      without a resolvable classification keep the pre-117 dangerous split.

  ## Aster caveat

  `aster` POSTs stay behind `--include dangerous` until sandbox creds exist.
  Transaction classification does not opt aster into read-style POST tagging.

  See T83 plan (`optimized-singing-fox.md`) and T61 plan (`spicy-baking-cray.md`).
  """

  alias Bourse.Spec
  alias Bourse.Test.Generator.SymbolResolver
  alias Bourse.UnifiedMethod

  @first_class_venues ~w(hyperliquid binance)

  # TODO(Task 83): Seed `@path_param_defaults` per exchange to unlock
  # path-templated endpoints (gate/kucoin/bitfinex are the high-value
  # candidates). Empty map = those endpoints skip silently.
  @path_param_defaults %{}

  @binance_family ~w(binance binanceus binanceusdm binancecoinm)

  @unavailable_on_testnet_sections ~w(sapi papi eapi)

  @unavailable_on_testnet Map.new(@binance_family, &{&1, @unavailable_on_testnet_sections})

  @ws_only_methods %{
    "deribit" => MapSet.new(["private_get_"])
  }

  @needs_params_prefixes %{
    "bybit" => ~w(v5/crypto-loan-fixed/)
  }

  @retired_endpoint_names %{
    "deribit" => MapSet.new(~w(
        private_get_get_portfolio_margins
        public_get_get_index
        public_get_get_index_price_names
      )),
    "okx" => MapSet.new(~w(
        public_get_support_announcements_types
      ))
  }

  @retired_endpoint_path_prefixes %{
    "bybit" => [
      "spot/v3/public/",
      "derivatives/v3/public/",
      "contract/v3/private/",
      "unified/v3/private/",
      "v5/lending/",
      "v5/spot-cross-margin-trade/",
      "v5/spot-lever-token/order"
    ]
  }

  @misclassified_endpoint_names %{
    "bybit" => MapSet.new(~w(
        private_get_v5_user_del_submember
      )),
    "okx" => MapSet.new(~w(
        private_get_account_set_auto_repay
      ))
  }

  @bybit_kline_interval "1"

  @path_param_regex ~r/\{([\w-]+)\}/

  @sandbox_auth_classes [:private, :private_dangerous]

  @doc "First-class venues used by the Task 117 population gate test."
  @spec first_class_venues() :: [String.t()]
  def first_class_venues, do: @first_class_venues

  @doc "Returns the path-param default map for an exchange, or `%{}`."
  @spec path_param_defaults(String.t()) :: %{optional(String.t()) => term()}
  # Compile-time conditional silences the type checker when the seed map is
  # empty — `Map.get(%{}, _, %{})` provably returns `%{}`. When entries are
  # added, the runtime lookup branch takes over.
  if map_size(@path_param_defaults) == 0 do
    def path_param_defaults(exchange_id) when is_binary(exchange_id), do: %{}
  else
    def path_param_defaults(exchange_id) when is_binary(exchange_id) do
      Map.get(@path_param_defaults, exchange_id, %{})
    end
  end

  @doc """
  Returns `true` when the exchange spec carries a non-empty
  `endpoints.transaction_classification` map.
  """
  @spec transaction_classification_populated?(String.t()) :: boolean()
  def transaction_classification_populated?(exchange_id) when is_binary(exchange_id) do
    exchange_id
    |> transaction_context()
    |> Map.get(:populated?, false)
  end

  @doc """
  Loads `endpoints.transaction_classification` and unified reverse lookup for
  an exchange. Used once per compile-time probe module.
  """
  @spec transaction_context(String.t()) :: %{
          populated?: boolean(),
          tc: map(),
          rev_unified: %{String.t() => String.t()}
        }
  def transaction_context(exchange_id) when is_binary(exchange_id) do
    spec = Spec.load!(exchange_id)
    tc = get_in(spec, ["endpoints", "transaction_classification"]) || %{}
    unified = get_in(spec, ["endpoints", "unified"]) || %{}

    rev_unified =
      unified
      |> Enum.flat_map(fn {method, names} ->
        Enum.map(List.wrap(names), &{&1, method})
      end)
      |> Map.new()

    %{
      populated?: map_size(tc) > 0,
      tc: tc,
      rev_unified: rev_unified
    }
  end

  @doc """
  Resolves `endpoints.transaction_classification` for a raw endpoint config.

  Unified methods are keyed by camelCase JS name (e.g. `"fetchBalance"`); raw-only
  endpoints fall back to the Bourse interface name (e.g. `"publicPostSendTx"`).
  """
  @spec classification_for(map(), map()) :: map() | nil
  def classification_for(%{populated?: true, tc: tc, rev_unified: rev_unified}, endpoint) when is_map(endpoint) do
    js_name =
      UnifiedMethod.endpoint_config_to_js_name(
        endpoint.sections,
        endpoint.method,
        endpoint.path
      )

    key = Map.get(rev_unified, js_name, js_name)
    Map.get(tc, key)
  end

  def classification_for(%{populated?: false}, _endpoint), do: nil

  @doc """
  Returns `true` when a write endpoint should follow GET tag rules (`:public` /
  `:private`) instead of `:dangerous`.

  Reads `transactional: false` from `endpoints.transaction_classification`.
  """
  @spec treat_post_as_safe?(String.t(), map()) :: boolean()
  def treat_post_as_safe?(exchange_id, endpoint) when is_binary(exchange_id) and is_map(endpoint) do
    exchange_id
    |> transaction_context()
    |> classification_for(endpoint)
    |> read_style_write?()
  end

  @doc false
  @spec read_style_write?(map() | nil) :: boolean()
  def read_style_write?(%{"transactional" => false}), do: true
  def read_style_write?(_), do: false

  @doc """
  Returns the unique list of `{param}` placeholders referenced by `path`.
  """
  @spec referenced_params(String.t()) :: [String.t()]
  def referenced_params(path) when is_binary(path) do
    @path_param_regex
    |> Regex.scan(path)
    |> Enum.map(fn [_whole, name] -> name end)
    |> Enum.uniq()
  end

  @doc """
  Returns a list of unresolved `{param}` placeholders in `path` after substituting
  the supplied defaults map. Used at compile time to decide whether to emit a
  test for a path-templated endpoint.
  """
  @spec unresolved_params(String.t(), map()) :: [String.t()]
  def unresolved_params(path, defaults) when is_binary(path) and is_map(defaults) do
    path
    |> referenced_params()
    |> Enum.reject(&Map.has_key?(defaults, &1))
  end

  @doc """
  Returns compile-time query params merged into raw probe calls for `endpoint`.
  """
  @spec query_params_for(String.t(), map()) :: %{String.t() => term()}
  def query_params_for(exchange_id, endpoint) when is_binary(exchange_id) and is_map(endpoint) do
    case exchange_id do
      "bybit" -> bybit_query_params(Map.get(endpoint, :path, ""))
      _ -> %{}
    end
  end

  @doc """
  Returns the path prefix when `endpoint` needs hand-authored query params, or `nil`.
  """
  @spec needs_params_prefix(String.t(), map()) :: String.t() | nil
  def needs_params_prefix(exchange_id, endpoint) when is_binary(exchange_id) and is_map(endpoint) do
    path = Map.get(endpoint, :path, "")

    case Map.get(@needs_params_prefixes, exchange_id) do
      nil -> nil
      prefixes -> Enum.find(prefixes, &String.starts_with?(path, &1))
    end
  end

  @doc """
  Returns the matched testnet-unavailable section prefix for `endpoint`, or `nil`.
  """
  @spec unavailable_testnet_prefix(String.t(), map()) :: String.t() | nil
  def unavailable_testnet_prefix(exchange_id, endpoint) when is_binary(exchange_id) and is_map(endpoint) do
    case Map.get(@unavailable_on_testnet, exchange_id) do
      nil ->
        nil

      prefixes ->
        sections = Map.get(endpoint, :sections, [])
        Enum.find(prefixes, &(&1 in sections))
    end
  end

  @doc """
  Returns `true` when `endpoint.name` matches a configured WS-only method prefix.
  """
  @spec ws_only_method?(String.t(), map()) :: boolean()
  def ws_only_method?(exchange_id, endpoint) when is_binary(exchange_id) and is_map(endpoint) do
    case Map.get(@ws_only_methods, exchange_id) do
      nil ->
        false

      prefixes ->
        name = to_string(endpoint.name)

        Enum.any?(prefixes, fn prefix ->
          prefix = to_string(prefix)
          String.starts_with?(name, prefix)
        end)
    end
  end

  @doc """
  Returns a retired endpoint key when live sweeps proved the generated endpoint
  is no longer venue capability.
  """
  @spec retired_endpoint_key(String.t(), map()) :: String.t() | nil
  def retired_endpoint_key(exchange_id, endpoint) when is_binary(exchange_id) and is_map(endpoint) do
    endpoint_name = endpoint |> Map.get(:name) |> to_string()
    endpoint_path = Map.get(endpoint, :path, "")

    cond do
      @retired_endpoint_names |> Map.get(exchange_id, MapSet.new()) |> MapSet.member?(endpoint_name) ->
        endpoint_name

      prefix = retired_path_prefix(exchange_id, endpoint_path) ->
        prefix

      true ->
        nil
    end
  end

  @doc """
  Returns a misclassified endpoint key when the frozen spec has the wrong HTTP
  method/path semantics but the generated function must remain present.
  """
  @spec misclassified_endpoint_key(String.t(), map()) :: String.t() | nil
  def misclassified_endpoint_key(exchange_id, endpoint) when is_binary(exchange_id) and is_map(endpoint) do
    endpoint_name = endpoint |> Map.get(:name) |> to_string()

    if @misclassified_endpoint_names |> Map.get(exchange_id, MapSet.new()) |> MapSet.member?(endpoint_name) do
      endpoint_name
    end
  end

  @doc """
  Returns a skip group key when the probe should not call the endpoint.
  """
  @spec skip_group_key(String.t(), map(), atom()) ::
          {:testnet_unavailable, String.t()}
          | {:ws_only, String.t()}
          | {:needs_params, String.t()}
          | {:retired_endpoint, String.t()}
          | {:misclassified_endpoint, String.t()}
          | nil
  def skip_group_key(exchange_id, endpoint, auth) when is_binary(exchange_id) and is_map(endpoint) and is_atom(auth) do
    cond do
      auth == :public -> public_skip_group_key(exchange_id, endpoint)
      auth in @sandbox_auth_classes -> sandbox_skip_group_key(exchange_id, endpoint)
      true -> nil
    end
  end

  defp public_skip_group_key(exchange_id, endpoint) do
    cond do
      key = retired_endpoint_key(exchange_id, endpoint) ->
        {:retired_endpoint, key}

      key = misclassified_endpoint_key(exchange_id, endpoint) ->
        {:misclassified_endpoint, key}

      prefix = needs_params_prefix(exchange_id, endpoint) ->
        {:needs_params, prefix}

      true ->
        nil
    end
  end

  defp sandbox_skip_group_key(exchange_id, endpoint) do
    cond do
      prefix = unavailable_testnet_prefix(exchange_id, endpoint) ->
        {:testnet_unavailable, prefix}

      ws_only_method?(exchange_id, endpoint) ->
        {:ws_only, ws_only_prefix(exchange_id, endpoint)}

      key = retired_endpoint_key(exchange_id, endpoint) ->
        {:retired_endpoint, key}

      key = misclassified_endpoint_key(exchange_id, endpoint) ->
        {:misclassified_endpoint, key}

      true ->
        nil
    end
  end

  @doc """
  Human-readable skip label for compile-time grouped skip tests.
  """
  @spec skip_label(
          {:testnet_unavailable, String.t()}
          | {:ws_only, String.t()}
          | {:needs_params, String.t()}
          | {:retired_endpoint, String.t()}
          | {:misclassified_endpoint, String.t()}
        ) :: String.t()
  def skip_label({:testnet_unavailable, prefix}), do: "#{prefix} prefix unavailable on testnet"
  def skip_label({:ws_only, prefix}), do: "#{prefix}* WS-only (no REST surface)"
  def skip_label({:needs_params, prefix}), do: "#{prefix}* needs hand-authored query params"
  def skip_label({:retired_endpoint, key}), do: "#{key} retired by live sweep"
  def skip_label({:misclassified_endpoint, key}), do: "#{key} misclassified by live sweep"

  @doc """
  ExUnit skip reason string for a grouped skip test.
  """
  @spec skip_reason(
          {:testnet_unavailable, String.t()}
          | {:ws_only, String.t()}
          | {:needs_params, String.t()}
          | {:retired_endpoint, String.t()}
          | {:misclassified_endpoint, String.t()},
          non_neg_integer()
        ) :: String.t()
  def skip_reason({:testnet_unavailable, prefix}, count) do
    "Binance testnet does not host #{prefix} REST prefix " <>
      "(#{count} endpoint#{if count == 1, do: "", else: "s"}) — only api/fapi/dapi available"
  end

  def skip_reason({:ws_only, prefix}, count) do
    "#{prefix}* methods are WS-only JSON-RPC (#{count} endpoint#{if count == 1, do: "", else: "s"}) — " <>
      "no REST GET surface"
  end

  def skip_reason({:needs_params, prefix}, count) do
    "#{prefix}* endpoints need query params the probe cannot infer " <>
      "(#{count} endpoint#{if count == 1, do: "", else: "s"}) — skipped"
  end

  def skip_reason({:retired_endpoint, key}, count) do
    "#{key} is registered retired from the 2026-07-16 live sweep " <>
      "(#{count} endpoint#{if count == 1, do: "", else: "s"}) — generated function retained"
  end

  def skip_reason({:misclassified_endpoint, key}, count) do
    "#{key} is registered misclassified from the 2026-07-16 live sweep " <>
      "(#{count} endpoint#{if count == 1, do: "", else: "s"}) — generated function retained"
  end

  @bybit_kline_paths [
    "v5/market/index-price-kline",
    "v5/market/mark-price-kline",
    "v5/market/premium-index-price-kline"
  ]

  defp bybit_query_params(path) when path in ["v5/market/tickers", "v5/market/instruments-info"],
    do: %{"category" => "spot"}

  defp bybit_query_params("v5/market/risk-limit"), do: %{"category" => "linear"}

  defp bybit_query_params("v5/announcements/index"), do: %{"locale" => "en-US"}

  defp bybit_query_params("v5/earn/product"), do: %{"category" => "FlexibleSaving"}

  defp bybit_query_params("v5/market/delivery-price"), do: %{"category" => "linear", "baseCoin" => bybit_base_coin()}

  defp bybit_query_params("v5/market/funding/history"), do: bybit_linear_params()

  defp bybit_query_params("v5/market/open-interest"), do: Map.put(bybit_linear_params(), "intervalTime", "5min")

  defp bybit_query_params("v5/market/account-ratio"), do: Map.put(bybit_linear_params(), "period", "5min")

  defp bybit_query_params(path) when path in @bybit_kline_paths,
    do: Map.put(bybit_linear_params(), "interval", @bybit_kline_interval)

  defp bybit_query_params("v5/market/kline"), do: Map.put(bybit_spot_params(), "interval", @bybit_kline_interval)

  defp bybit_query_params(path) when path in ["v5/market/orderbook", "v5/market/recent-trade"], do: bybit_spot_params()

  defp bybit_query_params(path) when is_binary(path) do
    if String.starts_with?(path, "spot/v3/public/quote/") do
      %{"symbol" => bybit_spot_id(), "interval" => @bybit_kline_interval}
    else
      %{}
    end
  end

  defp bybit_spot_params, do: %{"category" => "spot", "symbol" => bybit_spot_id()}
  defp bybit_linear_params, do: %{"category" => "linear", "symbol" => bybit_linear_id()}

  defp bybit_spot_id do
    case SymbolResolver.pick_symbol("bybit") do
      nil -> "BTCUSDT"
      sym -> sym |> String.split(":") |> List.first() |> String.replace("/", "")
    end
  end

  defp bybit_linear_id do
    markets = bybit_markets()

    linear_sym =
      Enum.find(["BTC/USDT:USDT", "ETH/USDT:USDT"], &Map.has_key?(markets, &1)) ||
        SymbolResolver.pick_symbol("bybit")

    linear_sym
    |> to_string()
    |> String.split(":")
    |> List.first()
    |> String.replace("/", "")
  end

  defp bybit_base_coin do
    bybit_spot_id()
    |> String.replace("USDT", "")
    |> String.replace("USDC", "")
  end

  defp bybit_markets do
    SymbolResolver.markets("bybit")
  end

  defp retired_path_prefix(exchange_id, path) when is_binary(path) do
    @retired_endpoint_path_prefixes
    |> Map.get(exchange_id, [])
    |> Enum.find(&String.starts_with?(path, &1))
  end

  defp ws_only_prefix(exchange_id, endpoint) do
    name = to_string(endpoint.name)
    prefixes = Map.get(@ws_only_methods, exchange_id, MapSet.new())

    Enum.find_value(prefixes, "", fn prefix ->
      prefix = to_string(prefix)

      if String.starts_with?(name, prefix) do
        prefix
      end
    end)
  end
end
