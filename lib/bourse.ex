defmodule Bourse do
  @moduledoc """
  Unified cryptocurrency exchange client library.

  A provider-authored Elixir client for ten supported exchanges. Exchange
  modules are generated from complete owned specs listed by the closed runtime
  manifest. The version-pinned CCXT corpus is authoring and compatibility
  reference material only.

  ## Architecture

      Bourse.fetch_ticker(exchange, "BTC/USDT")     # Unified API
          → Bourse.Bybit (generated module)          # use Bourse.Exchange, spec: "bybit"
              → Bourse.Dispatch.call/4               # Shared dispatcher
                  → Bourse.Signing.sign/4            # 12 deterministic patterns
                  → Bourse.HTTP.request/4            # Req wrapper

  ## Quick Start

      # List available exchanges
      Bourse.Spec.exchanges()

      # Create an exchange (public-only)
      {:ok, bybit} = Bourse.exchange("bybit")

      # Create with credentials
      {:ok, bybit} = Bourse.exchange("bybit", api_key: "abc", secret: "xyz")

      {:ok, response} = Bourse.fetch_ticker(bybit, "BTC/USDT")

      # Cache markets when a venue needs market metadata at dispatch time
      # (e.g. lighter symbol → numeric market_id). Thread the enriched struct.
      {:ok, lighter} = Bourse.exchange("lighter")
      {:ok, lighter} = Bourse.load_markets(lighter)
      {:ok, response} = Bourse.fetch_ticker(lighter, "BTC/USDC:USDC")

      # Create an order (private, requires credentials)
      {:ok, response} = Bourse.create_order(bybit, "BTC/USDT", "limit", "buy", 0.001, price: 50000)

  ## Optional Parameters

  All unified functions accept an `opts` keyword list as the last argument.
  Optional Bourse parameters (since, limit, price, symbol when optional, etc.)
  and exchange-specific parameters are passed via opts:

      Bourse.fetch_trades(exchange, "BTC/USDT", since: 1_700_000_000_000, limit: 100)
      Bourse.create_order(exchange, "BTC/USDT", "limit", "buy", 0.01, price: 50000)
      Bourse.fetch_balance(exchange, type: "spot")

  Dispatch-level options (`:endpoint_index`, `:market_type`, `:timeout`, `:plug`, `:headers`,
  `:base_url`) are separated automatically and do not get passed to the
  exchange as parameters.

  Order creation and editing may opt into client-side market validation with
  `sanity: true`. It is disabled by default so that existing callers keep the
  exchange's own validation contract — enabling it by default would turn orders
  that the venue accepts today into local failures. Validation is skipped (never
  raised) until markets are loaded with `Bourse.load_markets/1`, since the limits
  it checks live in market metadata.

  A rejected order returns `{:error, %Bourse.Error{type: :invalid_order}}` before
  any HTTP request is issued; the per-check messages are in `hints`, and
  `raw["sanity_check"]` maps each failed check name to its message.

  """

  use Descripex
  use Descripex.Discoverable, modules: [Bourse, Bourse.Exchange, Bourse.Symbol, Bourse.HTTP]

  alias Bourse.Exchange
  alias Bourse.Unified
  alias Bourse.Unified.Descriptor

  # ===========================================================================
  # Exchange Constructor
  # ===========================================================================

  api(:exchange, "Create an exchange configuration.",
    params: [
      exchange_id: [kind: :value, description: "Exchange identifier (e.g., \"bybit\", :binance)"]
    ],
    opts: [
      api_key: [kind: :value, description: "API key for authenticated endpoints"],
      secret: [kind: :value, description: "API secret"],
      password: [kind: :value, description: "API password/passphrase (exchange-specific)"],
      sandbox: [kind: :value, description: "Use testnet URLs", default: false]
    ],
    returns: %{
      type: :result_tuple,
      description:
        ~s|{:ok, %Bourse.Exchange{} built from the owned spec (signing pattern, symbol patterns, error tables, etc.)} or {:error, reason}|
    },
    errors: [:invalid_exchange, :missing_credentials]
  )

  @spec exchange(String.t() | atom(), keyword()) :: {:ok, Exchange.t()} | {:error, term()}
  defdelegate exchange(exchange_id, opts \\ []), to: Exchange, as: :new

  @doc "Bang variant of `exchange/2`. Raises on error."
  @spec exchange!(String.t() | atom(), keyword()) :: Exchange.t()
  defdelegate exchange!(exchange_id, opts \\ []), to: Exchange, as: :new!

  api(:timeframes, "Returns unified-to-native OHLCV timeframe labels for an exchange.",
    params: [
      exchange: [kind: :value, description: "Exchange configuration struct"]
    ],
    returns: %{
      type: :map,
      description: ~s|Unified label => exchange-native OHLCV label (e.g. "1h" => "60" on Bybit)|
    }
  )

  @spec timeframes(Exchange.t()) :: %{String.t() => String.t()}
  defdelegate timeframes(exchange), to: Exchange

  api(:fees, "Returns the static default fee schedule for an exchange.",
    params: [
      exchange: [kind: :value, description: "Exchange configuration struct"]
    ],
    returns: %{
      type: :map,
      description: "Static describe().fees defaults for trading and funding fees, or nil when absent"
    }
  )

  @spec fees(Exchange.t()) :: Exchange.fees()
  defdelegate fees(exchange), to: Exchange

  api(:config, "Returns the derived config metadata (credentials/limits/status/routing/flags) for an exchange.",
    params: [
      exchange: [kind: :value, description: "Exchange configuration struct"]
    ],
    returns: %{
      type: :map,
      description: "Deterministic describe() config metadata, or an empty map when the spec predates the contract"
    }
  )

  @spec config(Exchange.t()) :: Exchange.config()
  defdelegate config(exchange), to: Exchange

  api(:doc_urls, "Returns the documentation URL doc-set (logo/www/doc/fees/api_management) for an exchange.",
    params: [
      exchange: [kind: :value, description: "Exchange configuration struct"]
    ],
    returns: %{
      type: :map,
      description: "Documentation/metadata URLs folded from the derived urls section, or an empty map"
    }
  )

  @spec doc_urls(Exchange.t()) :: Exchange.doc_urls()
  defdelegate doc_urls(exchange), to: Exchange

  api(:load_markets, "Fetch markets and return an enriched exchange with the markets cache set.",
    params: [
      exchange: [kind: :value, description: "Exchange configuration struct"]
    ],
    opts: [
      plug: [kind: :value, description: "Optional Req plug (tests / custom transport)"],
      timeout: [kind: :value, description: "Request timeout in milliseconds"]
    ],
    returns: %{
      type: :result_tuple,
      description:
        ~s|{:ok, %Bourse.Exchange{markets: [...]}} for the caller to thread on later calls, or {:error, reason}|
    }
  )

  @doc """
  Fetches markets and returns an enriched `%Exchange{}` with `:markets` populated.

  Pure-data loadMarkets equivalent: no process or global cache. Thread the
  returned struct into subsequent unified calls so market-metadata consumers
  (e.g. lighter symbol→`market_id` resolution) reuse the list without another
  network round-trip. Call again for an explicit reload.

      {:ok, exchange} = Bourse.exchange("lighter")
      {:ok, exchange} = Bourse.load_markets(exchange)
      {:ok, ticker} = Bourse.fetch_ticker(exchange, "BTC/USDC:USDC")
  """
  @spec load_markets(Exchange.t(), keyword()) ::
          {:ok, Exchange.t()} | {:error, term()}
  defdelegate load_markets(exchange, opts \\ []), to: Unified

  @doc "Bang variant of `load_markets/2`. Raises on error."
  @spec load_markets!(Exchange.t(), keyword()) :: Exchange.t()
  def load_markets!(%Exchange{} = exchange, opts \\ []) do
    case load_markets(exchange, opts) do
      {:ok, loaded} -> loaded
      {:error, error} -> raise error
    end
  end

  # ===========================================================================
  # Generated Unified API
  #
  # Unified methods generated from Bourse.Unified.method_defs/0.
  # Each method gets a standard function (with api() declaration) + bang variant.
  #
  # Signature: func(exchange, ...required_params, opts \\ [])
  # Returns: {:ok, map()} | {:error, Bourse.Error.t()}
  # Bang:    func!(exchange, ...required_params, opts \\ [])
  # Returns: map() | raises Bourse.Error
  # ===========================================================================

  for {name, js_name, required_params, description} <- Unified.method_defs() do
    param_vars = Enum.map(required_params, &Macro.var(&1, __MODULE__))
    param_names = required_params

    api_opts = Descriptor.build_api_opts(js_name, required_params)

    Descripex.emit_api(name, description, api_opts)

    def unquote(name)(%Exchange{} = exchange, unquote_splicing(param_vars), opts \\ []) do
      case Unified.split_opts(opts, unquote(name)) do
        {:ok, {dispatch_opts, extra}} ->
          required_values = [unquote_splicing(param_vars)]
          params = Unified.build_params(unquote(param_names), required_values, extra)
          Unified.call(exchange, unquote(name), unquote(js_name), params, dispatch_opts)

        {:error, _} = error ->
          error
      end
    end

    # Bang variant — @doc false, convenience wrapper
    bang_name = :"#{name}!"

    @doc false
    def unquote(bang_name)(%Exchange{} = exchange, unquote_splicing(param_vars), opts \\ []) do
      case unquote(name)(exchange, unquote_splicing(param_vars), opts) do
        {:ok, response} -> response
        {:error, error} -> raise error
      end
    end
  end
end
