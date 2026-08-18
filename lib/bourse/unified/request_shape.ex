defmodule Bourse.Unified.RequestShape do
  @moduledoc false
  # Applies per-method `endpoints.request.defaults` from the vendored/authored
  # spec onto unified caller params (literals, references, computed time windows,
  # conditionals, omit rules; plus legacy identifier_reference / dynamic_construction).

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Spec
  alias Bourse.Symbol
  alias Bourse.Timestamp
  alias Bourse.Unified
  alias Bourse.Unified.OptionQuantity
  alias Bourse.Unified.OrderPrecision
  alias Bourse.Unified.RequestShape.Binance
  alias Bourse.Unified.RequestShape.Bybit
  alias Bourse.Unified.RequestShape.Derive
  alias Bourse.Unified.RequestShape.Hyperliquid
  alias Bourse.Unified.RequestShape.Lighter
  alias Bourse.Unified.RequestShape.OKX

  @optional_unified_keys ~w(limit since timeframe category type until)
  @market_id_native_keys ~w(market_id market_index)
  # Atom key (params are string-keyed on the wire) carrying identifier_reference
  # natives a first-class spec could not resolve at entry time; popped — and raised
  # on if still absent — by ensure_identifiers_resolved!/3 after the venue module ran.
  @unresolved_tag :__unresolved_identifier_references__
  @milliseconds_per_minute 60_000
  @milliseconds_per_hour 60 * @milliseconds_per_minute
  @milliseconds_per_day 24 * @milliseconds_per_hour
  # Native target keys populated FROM unified `"timeframe"` (see also
  # `drop_renamed_timeframe/2`). Declared here so `identifier_value/4` can
  # prefer them over symbol when both are required (OKX `bar` vs `instId`).
  @timeframe_native_keys ~w(interval resolution bar granularity)
  # Hyperliquid candleSnapshot requires startTime (docs:
  # https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#candle-snapshot).
  # When neither since nor limit is supplied, pin epoch 0 rather than relying on
  # a venue default.
  @hyperliquid_ohlcv_default_start_time 0
  @hyperliquid_funding_default_limit 500
  @binance_conditional_venues ~w(binance binancecoinm binanceusdm)
  # Nested `req` consumes these unified keys; drop after building so they never
  # leak top-level next to type/req (hyperliquid has no top-level rename targets).
  @hyperliquid_ohlcv_nested_sources ~w(symbol timeframe since limit until)

  @doc """
  Merges spec request defaults/bindings into unified params before dispatch.

  Optional `opts` (fixture / test only):

    * `:timestamp_ms_override` — freezes the request-shape clock used by dynamic
      constructions that depend on "now" (e.g. Deribit `fetchFundingRate`'s
      8h `end_timestamp` window). Production callers leave this unset.
  """
  @spec apply(map(), Exchange.t(), String.t(), keyword()) :: map() | [map()]
  def apply(params, exchange, js_name, opts \\ [])

  def apply(params, %Exchange{request_param_shape: shape} = exchange, js_name, opts)
      when is_map(params) and is_list(opts) do
    params = reject_multiple_binance_conditional_legs!(params, exchange, js_name)
    {params, exchange} = OrderPrecision.guard_dispatch!(params, exchange, js_name, opts)
    context = exchange |> shape_context() |> Map.put(:exchange_id, exchange.id)

    params
    |> OptionQuantity.to_native_request!(exchange, js_name)
    |> apply_shape_builder(shape, js_name, exchange, opts, context)
    |> apply_venue_builders(exchange, js_name, opts)
    |> finalize_shaped_params(exchange, js_name, context)
  end

  def apply(params, _exchange, _js_name, _opts), do: params

  defp apply_shape_builder(params, shape, js_name, exchange, opts, context) do
    case request_entries(shape, js_name, Keyword.get(opts, :endpoint_path)) do
      %{"_builder" => builder} = config -> apply_named_builder(params, config, exchange, js_name, builder)
      %{} = entries -> apply_entries(params, entries, js_name, opts, context)
      _ -> params
    end
  end

  defp apply_named_builder(params, config, exchange, js_name, builder) do
    case Spec.resolve_request_builder!(exchange.id, js_name, builder) do
      :binance -> Binance.build(params, js_name, exchange)
      :bybit -> Bybit.build(params, js_name, exchange, config)
    end
  end

  defp request_entries(shape, js_name, endpoint_path) do
    base = Map.get(shape, js_name)

    case get_in(shape, ["endpoint_overrides", js_name, endpoint_path]) do
      %{} = override when is_map(base) -> Map.merge(base, override)
      %{} = override -> override
      _ -> base
    end
  end

  defp apply_venue_builders(params, %Exchange{id: "okx"} = exchange, js_name, opts),
    do: OKX.build(params, js_name, exchange, opts)

  defp apply_venue_builders(params, %Exchange{id: "hyperliquid"} = exchange, js_name, opts),
    do: Hyperliquid.build(params, js_name, exchange, opts)

  defp apply_venue_builders(params, %Exchange{id: "derive"} = exchange, js_name, opts),
    do: Derive.build(params, js_name, exchange, opts)

  defp apply_venue_builders(params, %Exchange{id: "lighter"} = exchange, js_name, opts),
    do: Lighter.build(params, js_name, exchange, opts)

  defp apply_venue_builders(params, _exchange, _js_name, _opts), do: params

  # OKX cancel-algos / cancel-batch-orders return a root JSON array body.
  defp finalize_shaped_params(list, _exchange, _js_name, _context) when is_list(list), do: drop_nil_values(list)

  defp finalize_shaped_params(params, exchange, js_name, context) when is_map(params) do
    params
    |> ensure_identifiers_resolved!(js_name, context)
    |> put_binance_spot_ticker_symbols(exchange, js_name)
    |> drop_unified_symbols(js_name)
    |> drop_nil_values()
  end

  defp drop_nil_values(params) when is_map(params) do
    params
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, drop_nil_values(value)} end)
  end

  defp drop_nil_values(values) when is_list(values), do: Enum.map(values, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  @doc "Applies request-shape entries that need unified params before symbol denormalization."
  @spec apply_premarket(map(), Exchange.t(), String.t()) :: map()
  def apply_premarket(params, %Exchange{id: "okx"} = exchange, "fetchTickers") when is_map(params),
    do: OKX.build(params, "fetchTickers", exchange)

  def apply_premarket(params, %Exchange{request_param_shape: shape} = exchange, js_name) when is_map(params) do
    case Map.get(shape, js_name) do
      %{"_builder" => builder} ->
        case Spec.resolve_request_builder!(exchange.id, js_name, builder) do
          :bybit -> put_premarket_category(params, js_name)
          :binance -> params
        end

      %{} = entries ->
        with %{"reason" => "conditional_value"} <- Map.get(entries, "category"),
             category when not is_nil(category) <- conditional_value("category", params, [], js_name) do
          Map.put_new(params, "category", category)
        else
          _ -> params
        end

      _ ->
        params
    end
  end

  def apply_premarket(params, _exchange, _js_name), do: params

  defp put_premarket_category(params, js_name) do
    category_params =
      if js_name in ["createOrder", "createMarketBuyOrderWithCost", "createMarketSellOrderWithCost", "editOrder"] do
        Map.delete(params, "type")
      else
        params
      end

    case conditional_value("category", category_params, [], js_name) do
      nil -> params
      category -> Map.put_new(params, "category", category)
    end
  end

  defp apply_entries(params, entries, js_name, opts, context) do
    required = unified_required_params(js_name)
    context = Map.merge(context, dynamic_context(js_name, opts))

    entries
    |> Enum.reduce(params, fn {native_key, entry}, acc ->
      apply_entry(acc, native_key, entry, required, js_name, context)
    end)
    |> drop_authored_sources(entries)
    |> drop_authored_omissions(entries)
    |> drop_renamed_symbol(entries, required)
    |> drop_conditional_coin_symbol(entries)
    |> drop_nested_req_sources(entries, js_name)
    |> drop_unified_symbols(js_name)
    |> drop_renamed_timeframe(entries)
    |> drop_renamed_since(entries)
  end

  # Unified multi-symbol filters are client-side only — never put a multi-symbol
  # list on the wire for these methods. Bybit funding rates use category
  # (+ optional single symbol); symbols are applied after parse.
  defp drop_unified_symbols(%{"symbols" => symbols} = params, "fetchTickers") when is_list(symbols),
    do: Map.delete(params, "symbols")

  defp drop_unified_symbols(params, js_name) when js_name in ["fetchPositions", "fetchFundingRates"],
    do: Map.delete(params, "symbols")

  defp drop_unified_symbols(params, _js_name), do: params

  defp put_binance_spot_ticker_symbols(
         %{"symbols" => symbols} = params,
         %Exchange{id: "binance"} = exchange,
         "fetchTickers"
       )
       when is_list(symbols) and symbols != [] do
    if Enum.all?(symbols, &spot_symbol?/1) do
      native_ids = Enum.map(symbols, &Symbol.to_exchange_id(&1, exchange))
      Map.put(params, "symbols", Jason.encode!(native_ids))
    else
      params
    end
  end

  defp put_binance_spot_ticker_symbols(params, _exchange, _js_name), do: params

  defp spot_symbol?(symbol) when is_binary(symbol), do: not String.contains?(symbol, ":")
  defp spot_symbol?(_symbol), do: false

  defp apply_entry(params, native_key, %{"kind" => "literal", "value" => value}, _required, _js_name, _context) do
    Map.put_new(params, native_key, value)
  end

  defp apply_entry(params, native_key, %{"kind" => "omit"}, _required, _js_name, _context) do
    Map.delete(params, native_key)
  end

  defp apply_entry(
         params,
         native_key,
         %{"kind" => "conditional", "cases" => cases} = entry,
         _required,
         _js_name,
         _context
       )
       when is_list(cases) do
    put_authored_conditional(params, native_key, cases, entry)
  end

  defp apply_entry(
         params,
         native_key,
         %{"kind" => "computed", "operation" => operation} = entry,
         _required,
         _js_name,
         context
       )
       when operation in ["time_window_start", "time_window_end"] do
    value = compute_time_window(operation, params, entry, context)
    Map.put_new(params, native_key, transform_authored_value(value, Map.get(entry, "transform")))
  end

  defp apply_entry(params, native_key, %{"source" => "api_key"}, _required, _js_name, context) do
    case context[:api_key] do
      value when is_binary(value) and value != "" -> Map.put_new(params, native_key, value)
      _ -> params
    end
  end

  defp apply_entry(params, native_key, %{"source" => source} = entry, required, js_name, context)
       when is_binary(source) do
    put_authored_reference(params, native_key, source, entry, required, js_name, context)
  end

  defp apply_entry(params, native_key, %{"reason" => "identifier_reference"}, required, js_name, context) do
    case identifier_value(native_key, params, required, js_name) do
      {:error, :unresolved_identifier_reference} ->
        unresolved_identifier(params, native_key, js_name, context)

      nil ->
        params

      value ->
        Map.put_new(params, native_key, value)
    end
  end

  defp apply_entry(params, native_key, %{"reason" => "dynamic_construction"}, required, js_name, context) do
    case build_dynamic(native_key, params, required, js_name, context) do
      nil -> params
      value -> Map.put_new(params, native_key, value)
    end
  end

  defp apply_entry(params, native_key, %{"reason" => "conditional_value"}, required, js_name, _context) do
    case conditional_value(native_key, params, required, js_name) do
      nil -> params
      value -> Map.put(params, native_key, value)
    end
  end

  defp apply_entry(params, _native_key, _entry, _required, _js_name, _context), do: params

  # An owned spec that cannot resolve an `identifier_reference` is an authoring
  # bug: the request would go out missing a required native parameter, and the venue
  # rejects it before business logic. Fail loudly naming venue/method/param.
  #
  # The raise is DEFERRED to the end of the shaping pipeline: venue modules run after
  # the generic entries and legitimately fill some of these params (OKX.build supplies
  # e.g. fetchOpenInterests instType and fetchTransfer transId), so an entry-time raise
  # fires on params that are resolved one step later. Unresolved keys are tagged here
  # and `ensure_identifiers_resolved!/3` raises only for keys still absent once every
  # stage has run.
  defp unresolved_identifier(params, native_key, _js_name, _context),
    do: Map.update(params, @unresolved_tag, [native_key], &[native_key | &1])

  defp ensure_identifiers_resolved!(params, js_name, context) do
    {tagged, params} = Map.pop(params, @unresolved_tag, [])

    case Enum.reject(tagged, &Map.has_key?(params, &1)) do
      [] ->
        params

      [native_key | _] ->
        raise Error.invalid_parameters(
                message:
                  "Missing required identifier `#{native_key}` for #{js_name}; " <>
                    "pass it in the unified call options as `#{native_key}: value`.",
                exchange: context[:exchange_id],
                raw: %{
                  "method" => js_name,
                  "parameter" => native_key,
                  "reason" => "unresolved_identifier_reference"
                }
              )
    end
  end

  defp put_authored_reference(params, native_key, source, entry, required, js_name, context) do
    validate_unified_source!(entry, source, required, js_name, context)
    value = reference_value(params, source, entry)

    cond do
      present?(params, Map.get(entry, "unless_present")) ->
        Map.delete(params, native_key)

      preserve_native?(entry) and Map.has_key?(params, native_key) and native_key != source ->
        enforce_max_length!(params, native_key, Map.fetch!(params, native_key), entry, js_name, context)

      is_nil(value) ->
        Map.delete(params, native_key)

      true ->
        transformed = transform_authored_value(value, Map.get(entry, "transform"))

        params
        |> Map.put(native_key, transformed)
        |> enforce_max_length!(native_key, transformed, entry, js_name, context)
    end
  end

  defp preserve_native?(%{"preserve_native" => true}), do: true
  defp preserve_native?(_entry), do: false

  defp enforce_max_length!(params, native_key, value, %{"max_length" => max_length}, js_name, context)
       when is_integer(max_length) and max_length > 0 and is_binary(value) do
    if String.length(value) > max_length do
      raise Error.invalid_parameters(
              message: "#{js_name} `#{native_key}` exceeds the venue maximum of #{max_length} characters",
              exchange: context[:exchange_id],
              raw: %{
                "method" => js_name,
                "parameter" => native_key,
                "reason" => "max_length_exceeded",
                "max_length" => max_length
              }
            )
    else
      params
    end
  end

  defp enforce_max_length!(params, _native_key, _value, _entry, _js_name, _context), do: params

  defp validate_unified_source!(%{"source_class" => "unified_param"}, source, required, js_name, context) do
    if source not in unified_param_names(required) do
      raise ArgumentError,
            "unresolved unified source for exchange #{context[:exchange_id]} method #{js_name} source #{source}"
    end
  end

  defp validate_unified_source!(_entry, _source, _required, _js_name, _context), do: :ok

  defp reference_value(params, source, entry) do
    case Enum.find([source | List.wrap(entry["fallback_sources"])], &(not is_nil(Map.get(params, &1)))) do
      nil -> Map.get(entry, "default")
      key -> Map.get(params, key)
    end
  end

  defp reject_multiple_binance_conditional_legs!(
         %{"stop_loss_price" => stop_loss, "take_profit_price" => take_profit},
         %Exchange{id: exchange_id},
         "createOrder"
       )
       when exchange_id in @binance_conditional_venues and not is_nil(stop_loss) and not is_nil(take_profit) do
    raise Error.invalid_parameters(
            message:
              "binance-family create_order accepts one conditional leg per order (stop_loss_price OR take_profit_price); two-leg protection is a separate order-list surface",
            exchange: exchange_id,
            raw: %{"method" => "createOrder", "reason" => "multiple_conditional_legs"}
          )
  end

  defp reject_multiple_binance_conditional_legs!(params, _exchange, _js_name), do: params

  # Caller-supplied native keys win. A matching case still applies (deribit
  # trailingAmount rewrites type → trailing_stop); the nil fallback must not
  # delete a value the caller already set (deribit createOrder.trigger).
  defp put_authored_conditional(params, native_key, cases, entry) do
    fallback = Map.get(params, Map.get(entry, "source"), Map.get(entry, "default"))

    {matched?, value} =
      Enum.reduce_while(cases, {false, fallback}, fn authored_case, acc ->
        if conditions_match?(params, Map.get(authored_case, "when", %{})) do
          {:halt, {true, Map.get(authored_case, "value")}}
        else
          {:cont, acc}
        end
      end)

    cond do
      Map.has_key?(params, native_key) and not matched? ->
        params

      is_nil(value) ->
        Map.delete(params, native_key)

      true ->
        Map.put(params, native_key, transform_authored_value(value, Map.get(entry, "transform")))
    end
  end

  defp drop_authored_sources(params, entries) do
    Enum.reduce(entries, params, fn
      {_native_key, %{"retain_source" => true}}, acc ->
        acc

      {native_key, %{"source" => source} = entry}, acc ->
        [source | List.wrap(entry["fallback_sources"])]
        |> Enum.reject(&(&1 == native_key))
        |> Enum.reduce(acc, &Map.delete(&2, &1))

      _, acc ->
        acc
    end)
  end

  defp drop_authored_omissions(params, entries) do
    case Map.get(entries, "_omit") do
      keys when is_list(keys) -> Map.drop(params, keys)
      _ -> params
    end
  end

  defp transform_authored_value(value, "decrement") when is_integer(value), do: value - 1
  defp transform_authored_value(value, "uppercase") when is_binary(value), do: String.upcase(value)
  # OKX funding/convert bodies document numeric sizes as JSON strings (amt/sz).
  defp transform_authored_value(value, "string"), do: to_string(value)

  defp transform_authored_value(value, "milliseconds_to_rfc3339") when is_integer(value),
    do: Timestamp.iso8601_from_ms(value)

  # Hyperliquid orderStatus `oid` is a JSON number (integer), not a string.
  defp transform_authored_value(value, "integer") when is_integer(value), do: value

  defp transform_authored_value(value, "integer") when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  defp transform_authored_value(value, "date_yymmdd_to_ddmmmyy") when is_binary(value) do
    Regex.replace(~r/^([A-Z]+(?:_[A-Z]+)?-)(\d{6})(?=-)/, value, fn _match, prefix, date ->
      prefix <> Symbol.convert_date(date, :yymmdd, :ddmmmyy)
    end)
  end

  defp transform_authored_value(value, _transform), do: value

  defp conditions_match?(params, conditions) when is_map(conditions) do
    Enum.all?(conditions, fn
      {key, "present"} -> present?(params, key)
      {key, "absent"} -> not present?(params, key)
      {key, expected} -> authored_value_matches?(Map.get(params, key), expected)
    end)
  end

  defp authored_value_matches?(actual, expected) when is_atom(actual) and is_binary(expected),
    do: Atom.to_string(actual) == expected

  defp authored_value_matches?(actual, expected), do: actual == expected

  defp present?(_params, nil), do: false
  defp present?(params, key), do: not is_nil(Map.get(params, key))

  defp compute_time_window(operation, params, entry, context) do
    now_ms = Map.fetch!(context, :now_ms)
    limit = integer_param(params, Map.get(entry, "limit_source"), Map.fetch!(entry, "default_limit"))
    timeframe_ms = timeframe_ms(params, entry)

    case operation do
      "time_window_start" -> time_window_start(params, entry, now_ms, limit, timeframe_ms)
      "time_window_end" -> time_window_end(params, entry, now_ms, limit, timeframe_ms)
    end
  end

  defp time_window_start(params, entry, now_ms, limit, timeframe_ms) do
    case Map.get(params, Map.get(entry, "since_source", "since")) do
      since when is_integer(since) -> since
      _ -> now_ms - Map.get(entry, "default_lookback_ms", max(limit - 1, 0) * timeframe_ms)
    end
  end

  defp time_window_end(params, entry, now_ms, limit, timeframe_ms) do
    case Map.get(params, Map.get(entry, "until_source", "until")) do
      until_ms when is_integer(until_ms) -> until_ms
      _ -> end_from_since(params, entry, now_ms, limit, timeframe_ms)
    end
  end

  defp end_from_since(params, entry, now_ms, limit, timeframe_ms) do
    case Map.get(params, Map.get(entry, "since_source", "since")) do
      since when is_integer(since) -> since + limit * timeframe_ms
      _ -> now_ms
    end
  end

  defp integer_param(params, source, default) do
    case Map.get(params, source) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp timeframe_ms(params, entry) do
    params
    |> Map.get(Map.get(entry, "timeframe_source", "timeframe"))
    |> parse_timeframe_ms(Map.fetch!(entry, "default_timeframe_ms"))
  end

  defp parse_timeframe_ms(nil, default), do: default
  defp parse_timeframe_ms(value, _default) when is_integer(value), do: value * @milliseconds_per_minute

  defp parse_timeframe_ms(value, default) when is_binary(value) do
    case Regex.run(~r/^(\d+)([mMhHdD]?)$/, value, capture: :all_but_first) do
      [amount, unit] -> String.to_integer(amount) * timeframe_unit_ms(unit)
      _ -> default
    end
  end

  defp parse_timeframe_ms(_value, default), do: default

  defp timeframe_unit_ms(unit) when unit in ["", "m", "M"], do: @milliseconds_per_minute
  defp timeframe_unit_ms(unit) when unit in ["h", "H"], do: @milliseconds_per_hour
  defp timeframe_unit_ms(unit) when unit in ["d", "D"], do: @milliseconds_per_day

  # Resolve an `identifier_reference` native key from unified params.
  #
  # Order is load-bearing when a method requires *both* `:symbol` and
  # `:timeframe` (OKX `fetchOHLCV`: `instId` + `bar`). The previous rule
  # "timeframe required ⇒ every non-symbol key is timeframe" rebound
  # `instId` to the bar value. Timeframe targets are the named rename keys
  # (`bar`/`interval`/`resolution`); everything else with a required symbol
  # takes the symbol (e.g. `instId`, `instrument_name`).
  defp identifier_value(native_key, params, required, _js_name) do
    cond do
      present = Map.get(params, native_key) ->
        present

      native_key in unified_param_names(required) ->
        Map.get(params, native_key)

      native_key in @optional_unified_keys ->
        Map.get(params, native_key)

      native_key in @timeframe_native_keys and :timeframe in required ->
        Map.get(params, "timeframe")

      :symbol in required ->
        Map.get(params, "symbol")

      :timeframe in required ->
        Map.get(params, "timeframe")

      true ->
        {:error, :unresolved_identifier_reference}
    end
  end

  defp conditional_value("category", params, _required, js_name), do: bybit_category(params, js_name)

  defp conditional_value("coin", %{"symbol" => symbol}, _required, _js_name) when is_binary(symbol) do
    # Hyperliquid /info coin is the universe name (e.g. "BTC"), not the
    # denormalized pair ("BTCUSDC"). build_final_params denormalizes before apply
    # (swap separator ""), so Symbol.parse alone is not enough — see coin_from_symbol/1.
    # Docs: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint
    coin_from_symbol(symbol)
  end

  defp conditional_value("type", params, _required, "fetchBalance") do
    if params["type"] == "spot" or params["enableUnifiedMargin"] == true do
      "spotClearinghouseState"
    else
      "clearinghouseState"
    end
  end

  defp conditional_value("type", _params, _required, "fetchOpenOrders"), do: "frontendOpenOrders"

  # Hyperliquid fetchMyTrades uses userFills when no since and userFillsByTime +
  # startTime when since is supplied (the same provider body shape as fetchTrades, which
  # we deliberately do not surface — see authored-specs divergence register).
  defp conditional_value("type", params, _required, "fetchMyTrades") do
    if present_integer?(params["since"]), do: "userFillsByTime", else: "userFills"
  end

  defp conditional_value(_native_key, _params, _required, _js_name), do: nil

  defp bybit_category(params, js_name) do
    cond do
      # An already-resolved category is authoritative — the fetchMarkets fan-out
      # (unified.ex) pre-sets `category` per wave and re-deriving here would
      # collapse every wave onto the `fetchMarkets -> "spot"` fallback below.
      is_binary(params["category"]) -> params["category"]
      type = first_type_hint(params) -> bybit_category_from_type(type)
      is_binary(params["symbol"]) -> bybit_category_from_symbol(params["symbol"])
      is_list(params["symbols"]) -> bybit_category_from_symbols(params["symbols"])
      js_name == "fetchFundingRates" -> "linear"
      js_name == "fetchMarkets" -> "spot"
      true -> nil
    end
  end

  # First present type hint, checked subType -> sub_type -> type. A present hint
  # is authoritative even when it maps to nil (matches the prior per-key cond:
  # a type key present but unmapped must not fall through to symbol/fallbacks).
  defp first_type_hint(params) do
    Enum.find_value(["subType", "sub_type", "type"], fn key ->
      if is_binary(params[key]), do: params[key]
    end)
  end

  defp bybit_category_from_type(type) do
    case String.downcase(type) do
      "spot" -> "spot"
      "linear" -> "linear"
      "inverse" -> "inverse"
      "option" -> "option"
      "swap" -> "linear"
      "future" -> "linear"
      _ -> nil
    end
  end

  defp bybit_category_from_symbol(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, parsed} ->
        case Symbol.detect_market_type(parsed) do
          :spot -> "spot"
          :option -> "option"
          market_type when market_type in [:swap, :future] -> bybit_category_from_settle(parsed)
        end

      _ ->
        nil
    end
  end

  defp bybit_category_from_symbols([symbol | _]) when is_binary(symbol), do: bybit_category_from_symbol(symbol)
  defp bybit_category_from_symbols(_symbols), do: nil

  defp bybit_category_from_settle(%{settle: settle}) when is_binary(settle) do
    if String.upcase(settle) in ["USDC", "USDT"], do: "linear", else: "inverse"
  end

  defp bybit_category_from_settle(_parsed), do: nil

  # Hyperliquid candleSnapshot — nested req{coin, interval, startTime, endTime}.
  # Authority: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#candle-snapshot
  # (perp coin = meta universe name; startTime required).
  defp build_dynamic("req", params, required, "fetchOHLCV", context) do
    if :timeframe in required, do: hyperliquid_ohlcv_req(params, context)
  end

  defp build_dynamic("interval", params, required, _js_name, _context) do
    if :timeframe in required, do: Map.get(params, "timeframe")
  end

  defp build_dynamic("baseCoin", params, _required, "fetchTickers", _context) do
    if bybit_category(params, "fetchTickers") == "option" do
      params["baseCoin"] || params["code"] || params["currency"] || base_coin_from_symbols(params["symbols"])
    end
  end

  defp build_dynamic("resolution", params, required, _js_name, _context) do
    if :timeframe in required, do: Map.get(params, "timeframe")
  end

  defp build_dynamic("instType", params, required, _js_name, _context) do
    if :type in required, do: Map.get(params, "type")
  end

  # Deribit fetchFundingRate uses an 8-hour window ending at now unless overridden.
  defp build_dynamic("start_timestamp", params, _required, "fetchFundingRate", context) do
    deribit_funding_start_timestamp(params, context)
  end

  defp build_dynamic("end_timestamp", params, _required, "fetchFundingRate", context) do
    deribit_funding_end_timestamp(params, context)
  end

  # Lighter fetchTicker requires `market_id: market['id']` after markets load.
  # Unified injects the resolved id into params before apply; this clause carries
  # it through and refuses to fall back to the unified symbol string.
  defp build_dynamic("market_id", params, _required, _js_name, _context) do
    case Map.get(params, "market_id") do
      id when is_integer(id) -> id
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # Hyperliquid fetchMyTrades maps since to startTime only on the by-time branch.
  defp build_dynamic("startTime", params, _required, "fetchMyTrades", _context) do
    case params["since"] do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  # Hyperliquid fundingHistory requires startTime. The default window is
  # `limit || 500` hourly funding periods ending now.
  defp build_dynamic("startTime", params, _required, "fetchFundingRateHistory", context) do
    case params["since"] do
      since when is_integer(since) ->
        since

      _ ->
        limit = positive_integer(params["limit"], @hyperliquid_funding_default_limit)
        Map.fetch!(context, :now_ms) - limit * @milliseconds_per_hour
    end
  end

  defp build_dynamic(_native_key, _params, _required, _js_name, _context), do: nil

  defp hyperliquid_ohlcv_req(%{"symbol" => symbol, "timeframe" => interval} = params, context)
       when is_binary(symbol) and is_binary(interval) do
    now = Map.fetch!(context, :now_ms)
    until = hyperliquid_ohlcv_until(params, now)

    %{
      "coin" => coin_from_symbol(symbol),
      "interval" => interval,
      "startTime" => hyperliquid_ohlcv_start_time(params, interval, until),
      "endTime" => until
    }
  end

  defp hyperliquid_ohlcv_req(_params, _context), do: nil

  defp hyperliquid_ohlcv_until(%{"until" => until}, _now) when is_integer(until), do: until
  defp hyperliquid_ohlcv_until(_params, now), do: now

  defp present_integer?(n) when is_integer(n), do: true
  defp present_integer?(_), do: false

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  @deribit_funding_window_ms 8 * 60 * 60 * 1000

  defp deribit_funding_start_timestamp(params, context) do
    cond do
      is_integer(params["start_timestamp"]) -> params["start_timestamp"]
      is_integer(params["since"]) -> params["since"]
      true -> Map.fetch!(context, :now_ms) - @deribit_funding_window_ms
    end
  end

  defp deribit_funding_end_timestamp(params, context) do
    cond do
      is_integer(params["end_timestamp"]) -> params["end_timestamp"]
      is_integer(params["until"]) -> params["until"]
      true -> Map.fetch!(context, :now_ms)
    end
  end

  defp dynamic_context(_js_name, opts) do
    now_ms =
      case Keyword.get(opts, :timestamp_ms_override) do
        ms when is_integer(ms) and ms >= 0 -> ms
        _ -> System.os_time(:millisecond)
      end

    %{now_ms: now_ms}
  end

  defp shape_context(%Exchange{credentials: %{api_key: api_key}}), do: %{api_key: api_key}
  defp shape_context(%Exchange{}), do: %{}

  defp drop_renamed_timeframe(params, entries) do
    if is_map_key(params, "timeframe") and
         Enum.any?(entries, fn {native_key, _entry} -> native_key in @timeframe_native_keys end) do
      Map.delete(params, "timeframe")
    else
      params
    end
  end

  # Hyperliquid fetchMyTrades renames unified `since` → native `startTime`. Drop the
  # leftover so /info is not sent an unrecognized `since` field.
  defp drop_renamed_since(params, entries) do
    if is_map_key(params, "since") and is_map_key(entries, "startTime") and
         is_map_key(params, "startTime") do
      Map.delete(params, "since")
    else
      params
    end
  end

  defp drop_renamed_symbol(params, entries, required) do
    if symbol_renamed?(entries, required) and is_map_key(params, "symbol") do
      Map.delete(params, "symbol")
    else
      params
    end
  end

  # Hyperliquid l2Book renames via conditional_value coin (not identifier_reference),
  # so drop_renamed_symbol does not fire — drop symbol once coin is present.
  defp drop_conditional_coin_symbol(params, entries) do
    if is_map_key(entries, "coin") and is_map_key(params, "coin") and is_map_key(params, "symbol") do
      Map.delete(params, "symbol")
    else
      params
    end
  end

  # Nested dynamic `req` (hyperliquid candleSnapshot) has no top-level native
  # rename targets for symbol/timeframe/since/limit, so the drop_renamed_* helpers
  # never fire. Drop those unified keys once req is built.
  defp drop_nested_req_sources(params, entries, "fetchOHLCV") do
    if is_map_key(entries, "req") and is_map(Map.get(params, "req")) do
      Map.drop(params, @hyperliquid_ohlcv_nested_sources)
    else
      params
    end
  end

  defp drop_nested_req_sources(params, _entries, _js_name), do: params

  # A native key carries the *renamed* symbol only when it both (a) is an
  # identifier_reference and (b) is not itself a known unified param — required
  # (e.g. "timeframe") or optional ("limit", "since", ...). Those passthrough
  # keys resolve from their own value, not the symbol, so they must NOT trigger
  # dropping "symbol" (e.g. binance fetchOHLCV's `limit` was wrongly deleting the
  # mandatory `symbol`). Only a key like okx's `instId` qualifies.
  #
  # Lighter's `market_id` is dynamic_construction from market.id (numeric index),
  # not an identifier_reference rename of the symbol string — still drop the
  # leftover unified `symbol` so the API is not sent an invalid extra param.
  defp symbol_renamed?(entries, required) do
    known = ["symbol" | unified_param_names(required)] ++ @optional_unified_keys

    Enum.any?(entries, fn
      {native_key, %{"reason" => "identifier_reference"}} -> native_key not in known
      {native_key, %{"reason" => "dynamic_construction"}} -> native_key in @market_id_native_keys
      _ -> false
    end)
  end

  # Universe coin for Hyperliquid /info. Accepts unified (`BTC/USDC:USDC`) or
  # denormalized no-separator ids (`BTCUSDC` after maybe_denormalize_symbol).
  # Perpetuals use the meta universe name (= base); never the concatenated pair.
  # Docs: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint
  defp coin_from_symbol(symbol) when is_binary(symbol) do
    case base_from_parsed_symbol(symbol) do
      nil -> base_from_denormalized_symbol(symbol) || symbol
      base -> base
    end
  end

  defp base_from_parsed_symbol(symbol) do
    case Symbol.parse(symbol) do
      {:ok, %{base: base}} when is_binary(base) and base != "" -> base
      _ -> nil
    end
  end

  defp base_from_denormalized_symbol(symbol) do
    case Symbol.normalize(symbol, %{separator: "", case: :upper}) do
      normalized when is_binary(normalized) and normalized != symbol ->
        base_from_parsed_symbol(normalized)

      _ ->
        nil
    end
  end

  # startTime for candleSnapshot. With limit and no since: until - limit * tf_ms.
  # With neither: @hyperliquid_ohlcv_default_start_time.
  defp hyperliquid_ohlcv_start_time(%{"since" => since}, _interval, _until) when is_integer(since), do: since

  defp hyperliquid_ohlcv_start_time(%{"limit" => limit}, interval, until) when is_integer(limit) and limit > 0 do
    tf_ms = parse_timeframe_ms(interval, @milliseconds_per_minute)
    max(until - tf_ms * limit, @hyperliquid_ohlcv_default_start_time)
  end

  defp hyperliquid_ohlcv_start_time(_params, _interval, _until), do: @hyperliquid_ohlcv_default_start_time

  defp base_coin_from_symbols([symbol | _]) when is_binary(symbol), do: coin_from_symbol(symbol)
  defp base_coin_from_symbols(_symbols), do: nil

  defp unified_required_params(js_name) do
    js_name
    |> Unified.method_atom_for_js_name()
    |> case do
      nil -> []
      method -> Unified.required_params_for(method)
    end
  end

  defp unified_param_names(required) do
    Enum.map(required, &Atom.to_string/1)
  end
end
