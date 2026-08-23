defmodule Bourse.Spec do
  @moduledoc """
  Compile-time JSON spec loader for exchange specifications.

  Reads the closed runtime-support manifest and its complete owned venue specs
  for use by the generator macro (`Bourse.Exchange`). CCXT-derived documents are
  a separate authoring corpus and are never read by this module.

  ## Usage

      # In generator macro (compile time):
      spec = Bourse.Spec.load!("bybit")

      # List available exchanges:
      Bourse.Spec.exchanges()
      #=> ["alpaca", "binance", "binancecoinm", "binanceusdm", "bybit", "coinbaseexchange", "deribit", "derive", "hyperliquid", "lighter", "okx"]

  ## Schema Version

  The returned documents carry this project's schema version. It changes only
  when `bourse` deliberately migrates its compile-time contract; upstream
  extractor versions and provenance metadata are not part of that contract.

  Every supported venue loads one complete hand-owned document from the
  endpoint-major files under `priv/venues/<venue>/authored/`. `Disk.assemble!/2`
  rotates those files back into the facet-major map this module validates.
  Meaningful `null` and empty values are preserved byte-for-byte.
  """

  alias Bourse.JsonDocument
  alias Bourse.Spec.Disk
  alias Bourse.Spec.Schema

  @spec_root "priv/venues"
  @schema_version Schema.version()

  # Only lowercase alphanumeric and underscore — rejects path traversal ("../mix")
  @valid_id_pattern ~r/^[a-z0-9_]+$/

  # Authored request bindings declare their source class in the spec data itself; this
  # list is the closed vocabulary those declarations are validated against, not a
  # per-source exemption table.
  @request_source_classes ~w(unified_param native_passthrough optional credential)
  @request_builder_contracts %{
    "binance_batch_orders" => %{
      handler: :binance,
      exchanges: ~w(binance binanceusdm),
      methods: ~w(createOrders editOrders)
    },
    "binance_single_symbol" => %{
      handler: :binance,
      exchanges: ~w(binance),
      methods: ~w(fetchAllGreeks)
    },
    "bybit_v5" => %{
      handler: :bybit,
      exchanges: ~w(bybit),
      methods: ~w(
        borrowCrossMargin repayCrossMargin fetchCrossBorrowRate fetchTransfers setLeverage
        setPositionMode setMarginMode fetchOHLCV fetchTickers fetchBorrowRateHistory transfer
        fetchOrder fetchOpenOrder fetchClosedOrder fetchOrderClassic fetchOpenOrders
        fetchClosedOrders fetchCanceledOrders fetchCanceledAndClosedOrders fetchOrderTrades
        fetchTradingFee fetchPosition fetchPositionADLRank fetchPositionsADLRank fetchMarketLeverageTiers
        fetchDerivativesMarketLeverageTiers fetchLeverageTiers fetchDepositAddress
        fetchDepositAddressesByNetwork fetchFutureMarkets fetchOption fetchOptionChain
        fetchVolatilityHistory fetchAllGreeks fetchPositionsHistory fetchFundingHistory
        fetchFundingRateHistory fetchMyTrades fetchMyLiquidations fetchLedger fetchOpenInterest
        fetchLeverage fetchMarginMode fetchPositions fetchConvertCurrencies fetchConvertQuote
        createConvertTrade fetchConvertTrade fetchConvertTradeHistory fetchLongShortRatioHistory
        fetchBalance withdraw createOrder createMarketBuyOrderWithCost
        createMarketSellOrderWithCost createOrders editOrder editOrders cancelOrder cancelOrders
        cancelOrdersForSymbols cancelAllOrders
      )
    }
  }

  @doc """
  Loads and decodes an exchange spec by ID.

  Reads and validates the complete owned JSON document. Returns a map with
  string keys.

  Raises `File.Error` if the spec file doesn't exist, or `Jason.DecodeError`
  on invalid JSON.

  ## Examples

      spec = Bourse.Spec.load!("bybit")
      spec["exchange"]["id"]
      #=> "bybit"

  """
  @spec load!(String.t()) :: map()
  def load!(exchange_id) when is_binary(exchange_id) do
    validate_id!(exchange_id)

    if supported?(exchange_id) do
      exchange_id
      |> authored_dir()
      |> Disk.assemble!(spec_root: spec_root())
      |> require_owned_marker!(exchange_id)
      |> validate_schema!(exchange_id)
    else
      raise ArgumentError, "unsupported exchange: #{inspect(exchange_id)}"
    end
  end

  # The owned contract is keyed on the resolved owned path, never on the flag the
  # document declares about itself. Without this, dropping `"authored": true` from
  # an owned document silently downgrades it to the legacy validation branch.
  defp require_owned_marker!(%{"authored" => true} = spec, _exchange_id), do: spec

  defp require_owned_marker!(_spec, exchange_id) do
    raise ArgumentError,
          "owned spec #{inspect(exchange_id)} gap authored: required owned-document marker is missing or not true"
  end

  @doc """
  Loads and decodes the manifest file.

  Returns the closed runtime-support contract. This manifest is structurally
  distinct from the authoring reference-corpus manifest.

  ## Examples

      manifest = Bourse.Spec.load_manifest!()
      manifest["venue_count"] #=> 11

  """
  @spec load_manifest!() :: map()
  def load_manifest! do
    manifest_path()
    |> decode_file!()
    |> validate_manifest_schema!()
  end

  @doc """
  Returns the complete, invariant runtime-support inventory.

  ## Examples

      Bourse.Spec.exchanges()
      #=> ["alpaca", "binance", ..., "okx"]

  """
  @spec exchanges() :: [String.t()]
  def exchanges do
    load_manifest!()["venues"]
  end

  @doc "Returns whether the exchange is part of the closed runtime-support inventory."
  @spec supported?(String.t() | atom()) :: boolean()
  def supported?(exchange_id) when is_atom(exchange_id), do: supported?(Atom.to_string(exchange_id))
  def supported?(exchange_id) when is_binary(exchange_id), do: exchange_id in exchanges()

  @doc """
  Returns the absolute path to the primary venue metadata file for the given
  exchange ID.

  Use `source_files/1` for the complete split document. Unsupported
  reference-only venues raise immediately.

  ## Examples

      Bourse.Spec.spec_path("bybit")
      #=> "/path/to/priv/venues/bybit/authored/venue.json"

  """
  @spec spec_path(String.t()) :: String.t()
  def spec_path(exchange_id) when is_binary(exchange_id) do
    validate_id!(exchange_id)

    case owned_spec_path(exchange_id) do
      nil -> raise ArgumentError, "unsupported exchange: #{inspect(exchange_id)}"
      path -> path
    end
  end

  @doc "Returns the primary owned venue-file path for a first-class venue."
  @spec owned_spec_path(String.t()) :: String.t() | nil
  def owned_spec_path(exchange_id) when is_binary(exchange_id) do
    validate_id!(exchange_id)

    if supported?(exchange_id) do
      Path.join(authored_dir(exchange_id), "venue.json")
    end
  end

  @doc "Absolute directory of one venue's authored split files."
  @spec authored_dir(String.t()) :: String.t()
  def authored_dir(exchange_id) when is_binary(exchange_id) do
    Disk.authored_dir(spec_root(), exchange_id)
  end

  @doc """
  JSON files that must trigger recompilation for a venue, including shared
  descriptor files referenced by `$ref`.
  """
  @spec source_files(String.t()) :: [String.t()]
  def source_files(exchange_id) when is_binary(exchange_id) do
    validate_id!(exchange_id)
    Disk.source_files(spec_root(), exchange_id)
  end

  @doc "Assembles a venue spec from an alternate venues root (tests and mix tasks)."
  @spec load_from_root!(String.t(), String.t()) :: map()
  def load_from_root!(root, exchange_id) when is_binary(root) and is_binary(exchange_id) do
    validate_id!(exchange_id)

    root
    |> Disk.authored_dir(exchange_id)
    |> Disk.assemble!(spec_root: root)
  end

  @doc """
  Returns the absolute path to the manifest file.

  ## Examples

      Bourse.Spec.manifest_path()
      #=> "/path/to/priv/venues/runtime_support.json"

  """
  @spec manifest_path() :: String.t()
  def manifest_path do
    Path.join(spec_root(), "runtime_support.json")
  end

  @doc "Returns the owned local spec schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the primary hand-authored venue-file path, otherwise `nil`."
  @spec authored_spec_path(String.t()) :: String.t() | nil
  def authored_spec_path(exchange_id) when is_binary(exchange_id) do
    validate_id!(exchange_id)

    owned_spec_path(exchange_id)
  end

  @doc "Decodes a spec document after rejecting duplicate JSON object keys."
  @spec decode_file!(String.t()) :: map()
  def decode_file!(path) when is_binary(path) do
    JsonDocument.decode_file!(path)
  end

  @doc """
  Validates the runtime manifest and every supported owned document.

  Reference-corpus validation belongs to the authoring-only reference-corpus
  boundary, which lives in the source repository's Mix tooling and is never
  reachable at runtime.
  """
  @spec validate_all_documents!() :: :ok
  def validate_all_documents! do
    decode_file!(manifest_path())
    Enum.each(exchanges(), &load!/1)
    :ok
  end

  # Resolves the spec root.
  # Uses :code.priv_dir at runtime, falls back to compile-time path.
  defp spec_root do
    case :code.priv_dir(:bourse) do
      {:error, :bad_name} -> @spec_root
      priv_dir -> Path.join(to_string(priv_dir), "venues")
    end
  end

  @doc """
  Validates a decoded per-exchange spec map against the owned schema contract.

  Returns the spec unchanged on success. Called internally from `load!/1`;
  exposed publicly so test suites can exercise every branch against in-memory
  maps without writing fixture files into the live spec directory.
  """
  @spec validate_schema!(map(), String.t()) :: map()
  def validate_schema!(%{"schema_version" => @schema_version, "authored" => true} = spec, exchange_id) do
    Schema.validate!(spec, exchange_id)
    validate_authored_contract!(spec, exchange_id)
    spec
  end

  def validate_schema!(%{"schema_version" => @schema_version}, exchange_id) do
    raise ArgumentError,
          "owned spec #{inspect(exchange_id)} gap authored: required owned-document marker is missing or not true"
  end

  def validate_schema!(%{"schema_version" => version}, exchange_id) do
    raise "spec #{inspect(exchange_id)} has unsupported schema_version #{inspect(version)} " <>
            "(expected #{@schema_version})"
  end

  def validate_schema!(_spec, exchange_id) do
    raise "spec #{inspect(exchange_id)} missing schema_version (expected #{@schema_version})"
  end

  @doc "Validates every required interpretive slot when a spec is marked authored."
  @spec validate_authored_contract!(map(), String.t()) :: :ok
  def validate_authored_contract!(%{"authored" => true} = spec, exchange_id) do
    required_slots = [
      {["auth", "sign_recipe"], :map_allow_empty},
      {["normalization", "field_maps"], :map},
      {["normalization", "response_envelopes"], :map},
      {["markets", "patterns"], :map},
      {["errors", "handle_errors", "error_code_fields"], :list}
    ]

    Enum.each(required_slots, &validate_authored_slot!(spec, exchange_id, &1))
    validate_authored_signing_contract!(spec, exchange_id)
    validate_request_source_contracts!(spec, exchange_id)
  end

  def validate_authored_contract!(_spec, _exchange_id), do: :ok

  defp validate_authored_slot!(spec, exchange_id, {path, expected_type}) do
    value = get_in(spec, path)

    valid? =
      case expected_type do
        :map -> is_map(value) and map_size(value) > 0
        :map_allow_empty -> is_map(value)
        :list -> is_list(value) and value != []
      end

    if !valid? do
      slot = Enum.join(path, ".")

      raise "spec #{inspect(exchange_id)} has invalid authored slot #{slot}: " <>
              "expected non-empty #{expected_type}, got #{inspect(value)}"
    end
  end

  defp validate_authored_signing_contract!(spec, exchange_id) do
    auth = Map.get(spec, "auth", %{})
    recipe = auth["sign_recipe"]

    case Map.fetch(auth, "signing_pattern") do
      {:ok, nil} ->
        if auth["authenticated_sections"] == [] and auth["signing_config"] == %{} and recipe == %{} do
          :ok
        else
          raise "spec #{inspect(exchange_id)} has invalid public-only auth contract"
        end

      _pattern when is_map(recipe) and map_size(recipe) > 0 ->
        :ok

      _pattern ->
        raise "spec #{inspect(exchange_id)} has invalid authored slot auth.sign_recipe: " <>
                "expected non-empty map, got #{inspect(recipe)}"
    end
  end

  defp validate_request_source_contracts!(spec, exchange_id) do
    spec
    |> get_in(["endpoints", "request", "defaults"])
    |> case do
      defaults when is_map(defaults) ->
        Enum.each(defaults, fn {method, entries} ->
          validate_request_sources!(entries, exchange_id, method)
        end)

      _ ->
        :ok
    end
  end

  defp validate_request_sources!(overrides, exchange_id, "endpoint_overrides") when is_map(overrides) do
    Enum.each(overrides, fn {method, paths} ->
      Enum.each(paths, fn {_path, entries} -> validate_request_sources!(entries, exchange_id, method) end)
    end)
  end

  defp validate_request_sources!(entries, exchange_id, method) when is_map(entries) do
    Enum.each(entries, fn
      {"_builder", builder} ->
        resolve_request_builder!(exchange_id, method, builder)

      {_native_key, %{"source" => _source, "source_class" => source_class}}
      when source_class in @request_source_classes ->
        :ok

      {_native_key, %{"source" => source}} when is_binary(source) ->
        raise ArgumentError,
              IO.iodata_to_binary([
                "invalid request source contract for exchange ",
                exchange_id,
                " method ",
                method,
                " source ",
                source,
                ": expected one of ",
                Enum.intersperse(@request_source_classes, ", ")
              ])

      _ ->
        :ok
    end)
  end

  defp validate_request_sources!(_entries, _exchange_id, _method), do: :ok

  @doc false
  @spec resolve_request_builder!(String.t(), String.t(), term()) :: :binance | :bybit
  def resolve_request_builder!(exchange_id, method, builder) do
    case Map.fetch(@request_builder_contracts, builder) do
      {:ok, contract} ->
        if exchange_id in contract.exchanges and method in contract.methods do
          contract.handler
        else
          invalid_request_builder!(exchange_id, method, builder)
        end

      :error ->
        invalid_request_builder!(exchange_id, method, builder)
    end
  end

  defp invalid_request_builder!(exchange_id, method, builder) do
    raise ArgumentError,
          "invalid request-shape builder contract for exchange #{exchange_id} " <>
            "method #{method} builder #{inspect(builder)}"
  end

  @doc "Validates a decoded runtime-support manifest."
  @spec validate_manifest_schema!(map()) :: map()
  def validate_manifest_schema!(
        %{"kind" => "runtime_support", "schema_version" => @schema_version, "venue_count" => count, "venues" => venues} =
          manifest
      )
      when is_integer(count) and is_list(venues) do
    venue_count = length(venues)

    cond do
      count != venue_count ->
        raise "runtime-support manifest venue_count #{count} does not match #{venue_count} venues"

      venues != Enum.sort(Enum.uniq(venues)) ->
        raise "runtime-support manifest venues must be unique and sorted"

      Enum.any?(venues, &(not is_binary(&1) or not Regex.match?(@valid_id_pattern, &1))) ->
        raise "runtime-support manifest contains an invalid venue id"

      true ->
        manifest
    end
  end

  def validate_manifest_schema!(%{"schema_version" => version}) do
    raise "runtime-support manifest has unsupported schema_version #{inspect(version)} (expected #{@schema_version})"
  end

  def validate_manifest_schema!(_manifest) do
    raise "invalid runtime-support manifest contract"
  end

  # Validates exchange_id contains only safe characters (lowercase alphanumeric + underscore).
  # Rejects path traversal attempts like "../mix" or "foo/bar".
  defp validate_id!(exchange_id) do
    if !Regex.match?(@valid_id_pattern, exchange_id) do
      raise ArgumentError, "invalid exchange ID: #{inspect(exchange_id)} (must match #{inspect(@valid_id_pattern)})"
    end
  end
end
