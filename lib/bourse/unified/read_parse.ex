defmodule Bourse.Unified.ReadParse do
  @moduledoc false
  # Final unified read-path normalization: envelope unwrap, field-map parsing,
  # request-context symbol backfill, and fail-loud guards on empty parses.

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.MarginModification
  alias Bourse.OrderBook
  alias Bourse.Parser
  alias Bourse.RawResponse
  alias Bourse.ResponseParser
  alias Bourse.ResponseTransformer
  alias Bourse.Symbol
  alias Bourse.Ticker
  alias Bourse.Timestamp
  alias Bourse.Unified.ContractUnit
  alias Bourse.Unified.Envelope
  alias Bourse.Unified.FieldMaps
  alias Bourse.Unified.OptionQuantity
  alias Bourse.VolatilityHistory

  @parser_slots %{
    parse_account: "account",
    parse_balance: "balance",
    parse_borrow_interest: "borrow_interest",
    parse_borrow_rate: "borrow_rate",
    parse_conversion: "conversion",
    parse_currency: "currency",
    parse_deposit_address: "deposit_address",
    parse_funding_rate: "funding_rate",
    parse_funding_rate_history: "funding_rate_history",
    parse_funding_history: "funding_history",
    parse_greeks: "greeks",
    parse_last_price: "last_price",
    parse_ledger_entry: "ledger_entry",
    parse_leverage: "leverage",
    parse_leverage_tiers: "leverage_tiers",
    parse_liquidation: "liquidation",
    parse_long_short_ratio: "long_short_ratio",
    parse_margin_loan: "margin_loan",
    parse_margin_mode: "margin_mode",
    parse_margin_modification: "margin_modification",
    parse_market: "market",
    parse_ohlcv: "ohlcv",
    parse_open_interest: "open_interest",
    parse_order_book: "order_book",
    parse_option: "option",
    parse_order: "order",
    parse_order_list: "order_list",
    parse_position: "position",
    parse_adl_rank: "adl_rank",
    parse_ticker: "ticker",
    parse_time: "time",
    parse_trade: "trade",
    parse_trading_fee: "trading_fee",
    parse_transaction: "transaction",
    parse_transfer: "transfer",
    parse_volatility_history: "volatility_history"
  }

  @success_codes [0, "0", "00000", 200, "200", nil]
  @milliseconds_per_second 1_000

  @typedoc "A venue-observed account fact and the provider fields that define it."
  @type account_fact :: %{
          status: :observed | :unavailable,
          provider_fields: [String.t()],
          value: term()
        }

  @typedoc "Independent account product, account-margin, and position-margin facts."
  @type account_facts :: %{
          product_access: account_fact(),
          account_margin_model: account_fact(),
          position_margin_modes: account_fact(),
          info: term()
        }

  @doc """
  Parses a unified read response body into the mapped struct(s).

  Returns `{:ok, struct | [struct]}` or `{:error, reason}`.
  """
  @spec parse(
          Exchange.t(),
          module(),
          atom(),
          String.t(),
          term(),
          map(),
          atom(),
          boolean()
        ) :: {:ok, term()} | {:error, term()}
  def parse(%Exchange{} = exchange, module, method_atom, js_name, body, params, parser, list_return?) do
    result =
      if module != exchange.module or Exchange.mapping_complete?(exchange, js_name) do
        parse_type = Map.fetch!(@parser_slots, parser)
        do_parse(parse_type, exchange, module, js_name, body, params, parser, list_return?)
      else
        label_raw_response(exchange, js_name, body)
      end

    normalize_error(result, exchange, method_atom)
  end

  @doc "Labels an incomplete mapping's provider payload without normalizing it."
  @spec label_raw_response(Exchange.t(), String.t(), term()) :: {:ok, RawResponse.t()} | {:error, term()}
  def label_raw_response(%Exchange{} = exchange, js_name, body) when is_binary(js_name) do
    with :ok <- reject_error_envelope(body, exchange) do
      {:ok, RawResponse.new(body, exchange.id, js_name, Exchange.verification_state(exchange, js_name))}
    end
  end

  @doc "Maps provider-owned account classifications without deriving missing facts."
  @spec account_facts(Exchange.t(), term()) :: {:ok, account_facts()} | {:error, term()}
  def account_facts(%Exchange{} = exchange, body) do
    result =
      with :ok <- reject_error_envelope(body, exchange) do
        map_account_facts(exchange.id, body)
      end

    normalize_error(result, exchange, :fetch_account_facts)
  end

  defp map_account_facts("alpaca", body) when is_map(body) do
    {:ok,
     facts(
       fact(body, ["shorting_enabled"]),
       fact(body, ["multiplier"]),
       unavailable([]),
       body
     )}
  end

  defp map_account_facts("bybit", %{"result" => result} = body) when is_map(result) do
    {:ok,
     facts(
       fact(result, ["unifiedMarginStatus"]),
       fact(result, ["marginMode"]),
       unavailable([]),
       body
     )}
  end

  defp map_account_facts("deribit", %{"result" => %{"summaries" => summaries}} = body) when is_list(summaries) do
    {:ok,
     facts(
       row_fact(summaries, ["currency"], ["portfolio_margining_enabled"]),
       row_fact(summaries, ["currency"], ["margin_model"]),
       unavailable([]),
       body
     )}
  end

  defp map_account_facts("binance", body) when is_map(body) do
    {:ok,
     facts(
       fact(body, ["accountType", "permissions"]),
       unavailable([]),
       row_fact(List.wrap(Map.get(body, "positions")), ["symbol"], ["isolated"]),
       body
     )}
  end

  defp map_account_facts("hyperliquid", body) when is_map(body) do
    {:ok,
     facts(
       unavailable([]),
       fact(body, ["crossMarginSummary"]),
       hyperliquid_position_fact(List.wrap(Map.get(body, "assetPositions"))),
       body
     )}
  end

  defp map_account_facts("lighter", %{"accounts" => accounts} = body) when is_list(accounts) do
    {:ok,
     facts(
       row_fact(accounts, ["account_index"], ["account_type"]),
       row_fact(accounts, ["account_index"], ["account_trading_mode"]),
       lighter_position_fact(accounts),
       body
     )}
  end

  defp map_account_facts(exchange_id, body)
       when exchange_id in ["alpaca", "binance", "bybit", "deribit", "hyperliquid", "lighter"] do
    {:error, {:unexpected_response_shape, body}}
  end

  defp map_account_facts(exchange_id, _body),
    do: {:error, Error.not_supported(exchange: exchange_id, message: "Account facts are not mapped for #{exchange_id}")}

  defp facts(product_access, account_margin_model, position_margin_modes, body) do
    %{
      product_access: product_access,
      account_margin_model: account_margin_model,
      position_margin_modes: position_margin_modes,
      info: body
    }
  end

  defp fact(value, provider_fields) when is_map(value) do
    observed = Map.take(value, provider_fields)

    if Enum.any?(observed, fn {_field, field_value} -> not is_nil(field_value) end) do
      observed(provider_fields, observed)
    else
      unavailable(provider_fields)
    end
  end

  defp row_fact(rows, identity_fields, provider_fields) when is_list(rows) do
    values =
      rows
      |> Enum.filter(&observes_any?(&1, provider_fields))
      |> Enum.map(&Map.take(&1, identity_fields ++ provider_fields))

    if values == [], do: unavailable(provider_fields), else: observed(provider_fields, values)
  end

  defp hyperliquid_position_fact(rows) when is_list(rows) do
    values =
      for %{"position" => %{"leverage" => %{"type" => type}} = position} <- rows,
          not is_nil(type) do
        Map.take(position, ["coin", "leverage"])
      end

    if values == [], do: unavailable(["leverage.type"]), else: observed(["leverage.type"], values)
  end

  defp lighter_position_fact(accounts) do
    values =
      for account when is_map(account) <- accounts,
          position when is_map(position) <- List.wrap(Map.get(account, "positions")),
          not is_nil(Map.get(position, "margin_mode")) do
        position
        |> Map.take(["symbol", "margin_mode"])
        |> Map.put("account_index", Map.get(account, "account_index"))
      end

    if values == [], do: unavailable(["margin_mode"]), else: observed(["margin_mode"], values)
  end

  defp observes_any?(value, provider_fields) when is_map(value) do
    Enum.any?(provider_fields, &(Map.has_key?(value, &1) and not is_nil(Map.get(value, &1))))
  end

  defp observes_any?(_value, _provider_fields), do: false

  defp observed(provider_fields, value), do: %{status: :observed, provider_fields: provider_fields, value: value}

  defp unavailable(provider_fields), do: %{status: :unavailable, provider_fields: provider_fields, value: nil}

  # `fetchTime` returns an integer millisecond timestamp (not a struct). OKX/Bybit
  # wrap it as `data: [%{ts: ...}]` / `result.timeSecond`; unwrap then coerce.
  defp do_parse("time", exchange, module, js_name, body, _params, _parser, _list_return?) do
    with :ok <- reject_error_envelope(body, exchange) do
      extract_server_time_ms(body, module, js_name)
    end
  end

  # Binance Futures' DELETE /fapi/v1 and /dapi/v1 allOpenOrders responses are bare
  # success acknowledgements, not order rows. Preserve the venue body instead of
  # manufacturing an all-nil order.
  defp do_parse(
         "order",
         %Exchange{id: id},
         _module,
         "cancelAllOrders",
         %{"code" => code, "msg" => _} = body,
         _params,
         _parser,
         _list_return?
       )
       when id in ["binance", "binanceusdm", "binancecoinm"] and code in [200, "200"] do
    {:ok, body}
  end

  # Balance is a single `%Bourse.Balance{}` with per-currency maps, not a list of
  # structs. OKX (and similar) wrap trading rows under `data[0].details` and
  # funding rows under `data[]` directly — coerce neither via list_return nor the
  # one-element envelope collapse, then let the keyed_collection field map index
  # by currency. `info` keeps the full raw body.
  defp do_parse("balance", exchange, module, js_name, body, params, parser, _list_return?) do
    with :ok <- reject_error_envelope(body, exchange),
         payload = balance_parse_payload(body, module, js_name, params),
         {:ok, parsed} <- invoke_parser(module, parser, payload, envelope: body) do
      {:ok, put_balance_info(parsed, body)}
    end
  end

  # Alpaca's two v1beta3 crypto bars endpoints are multi-symbol batch reads:
  # the venue always answers `{"bars" => %{"<SYMBOL>" => rows_or_row}}`, one
  # entry per requested symbol — historical bars nest an ARRAY of bar objects
  # per symbol (https://docs.alpaca.markets/reference/cryptobars-1), latest
  # bars nest a SINGLE bar object per symbol
  # (https://docs.alpaca.markets/reference/cryptolatestbars-1). Neither is a
  # bare rows list, so the shared `ohlcv_rows/2` extraction below (which
  # expects the envelope key to resolve straight to the rows) sees a map and
  # fails loud with `:unexpected_response_shape`. Dereference the requested
  # symbol out of that wrapper first. The stocks endpoint
  # (`v2/stocks/{symbol}/bars`) already answers a bare array under "bars" and
  # falls through to the generic clause below untouched.
  defp do_parse(
         "ohlcv",
         %Exchange{id: "alpaca"} = exchange,
         _module,
         _js_name,
         %{"bars" => bars} = body,
         params,
         _parser,
         _list_return?
       )
       when is_map(bars) do
    with :ok <- reject_error_envelope(body, exchange) do
      case Map.get(bars, params["symbol"]) do
        rows when is_list(rows) ->
          candles =
            rows
            |> Enum.map(&coerce_ohlcv_row(&1, %{}))
            |> filter_ohlcv_by_since(params)
            |> maybe_take_ohlcv_limit(params)

          {:ok, candles}

        %{} = single_bar ->
          {:ok, [coerce_ohlcv_row(single_bar, %{})]}

        nil ->
          {:ok, []}

        other ->
          {:error, {:unexpected_response_shape, other}}
      end
    end
  end

  # OHLCV is array-shaped, not a field-map struct: envelope-unwrap,
  # optionally transpose a columnar payload (deribit's tradingview shape) to rows, then
  # coerce the timestamp and OHLC values to numbers. Object
  # rows (Hyperliquid candleSnapshot) map via the same six keys before the filter step.
  # Client-side since/limit applies after chronological normalization.
  defp do_parse("ohlcv", exchange, module, js_name, body, params, _parser, _list_return?) do
    with :ok <- reject_error_envelope(body, exchange) do
      config = ohlcv_envelope_config(module, js_name)

      case ohlcv_rows(body, config) do
        rows when is_list(rows) ->
          candles =
            rows
            |> normalize_ohlcv_order(config)
            |> Enum.map(&coerce_ohlcv_row(&1, config))
            |> filter_ohlcv_by_since(params)
            |> maybe_take_ohlcv_limit(params)

          {:ok, candles}

        other ->
          {:error, {:unexpected_response_shape, other}}
      end
    end
  end

  # Volatility history is an array of timestamp/value pairs: envelope
  # unwrap of JSON-RPC `result` to `[[unix_ms, value], ...]`, then one struct per
  # pair. No field_map — the slot is intentionally nil (same family as OHLCV).
  # Keep the raw pair as `info` so the
  # consumer retains the full row (task 200 acceptance: `info: raw`).
  defp do_parse("volatility_history", exchange, module, js_name, body, _params, _parser, _list_return?) do
    with :ok <- reject_error_envelope(body, exchange) do
      rows = volatility_history_rows(body, module, js_name)
      {:ok, Enum.map(rows, &coerce_volatility_history_row/1)}
    end
  end

  # USD-M documents an empty object when an account has no position ADL data.
  # This is an absent row, not an unsuccessfully parsed row; non-empty foreign
  # objects still flow through the all-nil-struct guard below.
  defp do_parse("adl_rank", %Exchange{id: "binanceusdm"}, _module, "fetchPositionADLRank", body, _params, _parser, false)
       when is_map(body) and map_size(body) == 0, do: {:ok, nil}

  defp do_parse("adl_rank", %Exchange{id: "binancecoinm"}, _module, "fetchADLRank", body, _params, _parser, false)
       when is_map(body) and map_size(body) == 0, do: {:ok, nil}

  defp do_parse("order_book", exchange, _module, _js_name, body, params, _parser, _list_return?) do
    with :ok <- reject_error_envelope(body, exchange),
         %{} = payload <- order_book_payload(body),
         {:ok, bids} <- payload |> order_book_side(:bids) |> order_book_levels(:desc, exchange.id),
         {:ok, asks} <- payload |> order_book_side(:asks) |> order_book_levels(:asc, exchange.id) do
      timestamp = Bourse.Safe.integer(Map.get(payload, "timestamp") || Map.get(payload, "ts") || Map.get(payload, "T"))

      {:ok,
       %OrderBook{
         symbol: params["symbol"],
         bids: bids,
         asks: asks,
         timestamp: timestamp,
         datetime: Timestamp.iso8601_from_ms(timestamp),
         nonce: Bourse.Safe.integer(Map.get(payload, "nonce") || Map.get(payload, "lastUpdateId")),
         info: payload
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:unexpected_response_shape, body}}
    end
  end

  # Currencies are returned as a code-keyed map: a list payload is mapped to
  # per-entry structs, then re-keyed by unified code. The field map
  # (`currency` slot) authors the venue's per-entry shape; the universal
  # `safeCurrencyCode` (uppercase + common-currency alias) and `info` are applied
  # here, since they read the exchange, not the entry.
  #
  # A missing `currency` field map must fail loud (task 319) — without it
  # `invoke_parser` would soft-return raw rows and `build_currency_map/2` would
  # raise a bare KeyError on `%{map | code: ...}` looking for atom `:id`.
  defp do_parse("currency", exchange, module, js_name, body, _params, parser, _list_return?) do
    with :ok <- reject_error_envelope(body, exchange),
         :ok <- ensure_currency_field_map(module, exchange),
         entries when is_list(entries) <-
           extract_envelope_payload(body, module, "currency", js_name) || [],
         {:ok, structs} when is_list(structs) <- parse_currency_entries(module, parser, entries, body) do
      {:ok, build_currency_map(structs, exchange)}
    else
      {:error, _} = error -> error
      other -> {:error, {:unexpected_response_shape, other}}
    end
  end

  # `fetchLeverage` returns one `%Leverage{}`. OKX hedge mode answers with
  # multiple `data[]` rows (posSide long/short) that must be merged — a plain
  # first-row unwrap would drop short leverage. Bybit answers a single position
  # row; field-map parse still applies when there is no posSide split.
  defp do_parse("leverage", exchange, module, "fetchLeverage" = js_name, body, params, parser, _list_return?) do
    with :ok <- reject_error_envelope(body, exchange),
         {:ok, payload} <-
           Envelope.unwrap(body, module, exchange.id, "leverage", js_name, true),
         rows when rows != [] <- leverage_rows(payload),
         {:ok, parsed} <- parse_leverage_payload(exchange, module, parser, rows, params, body) do
      {:ok, parsed}
    else
      {:error, _} = error -> error
      [] -> {:error, {:unexpected_response_shape, body}}
      other -> {:error, {:unexpected_response_shape, other}}
    end
  end

  # addMargin/reduceMargin return MarginModification even though the
  # venue acknowledgement is sparse and no authored field map exists yet. Keep
  # the raw acknowledgement in `info`; the method supplies the unambiguous
  # operation type that the response may omit.
  defp do_parse("margin_modification", exchange, _module, js_name, body, params, _parser, _list_return?)
       when js_name in ["addMargin", "reduceMargin"] do
    with :ok <- reject_error_envelope(body, exchange),
         %{} = payload <- margin_modification_payload(body) do
      {:ok,
       %MarginModification{
         symbol: params["symbol"],
         type: margin_modification_type(js_name),
         margin_mode: Map.get(payload, "mgnMode") || Map.get(payload, "marginMode"),
         amount: Bourse.Safe.number(Map.get(payload, "amt") || Map.get(payload, "amount")),
         total: Bourse.Safe.number(Map.get(payload, "total")),
         code: Map.get(payload, "ccy") || Map.get(payload, "currency"),
         status: Map.get(payload, "sCode") || Map.get(payload, "status"),
         info: payload
       }}
    else
      {:error, _} = error -> error
      other -> {:error, {:unexpected_response_shape, other}}
    end
  end

  defp do_parse(parse_type, exchange, module, js_name, body, params, parser, list_return?) do
    dict_js_name = dict_shape_js_name(js_name, exchange)
    envelope_list? = envelope_list_return?(dict_js_name, list_return?)
    unwrap_list? = envelope_list? and not has_authored_transform?(module, parse_type, js_name)

    with :ok <- reject_error_envelope(body, exchange),
         :ok <- reject_hyperliquid_order_rejection(body, exchange, js_name),
         {:ok, payload} <-
           Envelope.unwrap(body, module, exchange.id, parse_type, js_name, unwrap_list?),
         :ok <- validate_authored_transform_shape(payload, module, parse_type, js_name, exchange),
         payload = apply_authored_transform(payload, module, parse_type, js_name, exchange),
         payload = unwrap_bybit_v5_result(payload, exchange, envelope_list?),
         payload = annotate_bybit_deposit_chains(payload, body, exchange, js_name),
         # Peel wire collection containers (data/list/rows/result.*) so list and
         # dict-return reads iterate rows — never fold an envelope map into one
         # all-nil struct. Empty collections become [] here (valid success).
         payload = coerce_collection_payload(payload, envelope_list?, exchange, dict_js_name),
         payload = filter_selected_deposit_rows(payload, exchange, js_name),
         {:ok, payload} <- select_requested_row(payload, exchange, js_name, params),
         {:ok, payload} <- ensure_expected_shape(payload, envelope_list?),
         :ok <- reject_missing_single_order(payload, exchange, js_name, list_return?),
         payload = merge_bybit_pagination_cursor(payload, body, exchange, parse_type, js_name),
         payload = merge_bybit_batch_ret_ext(payload, body, exchange, js_name),
         payload =
           payload
           |> normalize_payload(list_return?, envelope_list?)
           |> annotate_bybit_market_category(body, exchange, parse_type, params)
           |> annotate_binance_family_payload(body, exchange, parse_type, js_name, params)
           |> annotate_lighter_payload(exchange, parse_type, js_name)
           |> annotate_okx_payload(exchange, parse_type)
           |> annotate_derive_payload(exchange, parse_type)
           |> annotate_hyperliquid_payload(exchange, parse_type, js_name, params)
           |> annotate_deribit_payload(exchange, parse_type)
           |> annotate_endpoint_route(params),
         :ok <- reject_unmapped_binance_order_type(payload),
         parse_opts = [{:envelope, body} | build_parse_opts(exchange, params, payload, list_return?)],
         {:ok, parsed} <- invoke_parser(module, parser, payload, parse_opts),
         parsed =
           parsed
           |> maybe_enrich_list(payload, dict_js_name)
           |> enrich(payload, list_return?)
           # Must follow enrich/3: the network is recovered from the explorer url
           # carried in `info`, which enrich/3 is what populates.
           |> enrich_deposit_address(exchange, parse_type, params)
           |> stamp_deribit_transaction_type(exchange, js_name)
           |> normalize_lighter_order_sides(exchange, parse_type),
         parsed = backfill_bybit_requested_tickers(parsed, exchange, js_name, params),
         parsed = stamp_bybit_fetch_position_timestamp(parsed, body, exchange, js_name),
         {:ok, parsed} <- backfill_native_symbols(parsed, exchange, parse_type, params),
         parsed = filter_deribit_requested_tickers(parsed, exchange, js_name, params),
         {:ok, parsed} <- shape_parsed_result(parsed, dict_js_name, list_return?, params),
         {:ok, parsed} <- backfill_market_symbols(parsed, exchange, parse_type, payload, envelope_list?),
         # Emptiness is judged BEFORE request-symbol backfill so a genuinely
         # empty list/single parse (e.g. all-nil trades) is rejected rather than
         # rescued by a request `symbol`. A sparse margin-loan ack (Bybit repay
         # echoes only `{resultStatus}`) is exempt in empty_struct?/1 — its `info`
         # is the success signal — so it survives to request-context backfill.
         :ok <- validate_parsed(parsed, list_return?),
         {:ok, parsed} <- backfill_request_symbols(parsed, params, parse_type, list_return?),
         {:ok, parsed} <- backfill_native_symbols(parsed, exchange, parse_type, params) do
      # Client-side request filtering runs
      # LAST — after request-symbol backfill — so list reads whose per-struct
      # symbol is only populated from the request (e.g. trades) are not emptied
      # before their symbols exist.
      parsed =
        parsed
        |> OptionQuantity.from_native_result!(exchange)
        |> preserve_bybit_order_ack(body, exchange, js_name)
        |> stamp_bybit_edit_orders_rejections(body, exchange, js_name)
        |> sort_bybit_orders(exchange, js_name)
        |> normalize_binance_family_result(exchange, js_name)
        |> put_funding_history_codes()
        # Hyperliquid userFills are not time-ordered on the wire; sort before
        # so limit takes newest/oldest correctly.
        |> maybe_sort_hyperliquid_trades(exchange, parse_type)
        |> apply_request_filters(params, parse_type)
        |> clear_binance_sparse_ack_symbols(exchange)
        |> index_all_greeks(js_name)

      {:ok, parsed}
    end
  end

  defp margin_modification_type("addMargin"), do: "add"
  defp margin_modification_type("reduceMargin"), do: "reduce"
  defp margin_modification_type(_js_name), do: nil

  defp margin_modification_payload(%{"data" => [%{} = payload | _]}), do: payload
  defp margin_modification_payload(%{"result" => %{} = payload}), do: payload
  defp margin_modification_payload(%{} = payload), do: payload
  defp margin_modification_payload(_body), do: nil

  defp maybe_sort_hyperliquid_trades(list, %Exchange{id: "hyperliquid"}, "trade") when is_list(list) do
    Enum.sort_by(list, fn
      %{timestamp: ts} when is_integer(ts) -> ts
      _ -> 0
    end)
  end

  defp maybe_sort_hyperliquid_trades(parsed, _exchange, _parse_type), do: parsed

  # Map returns (tickers, funding rates, and option chains) are
  # built from a list payload re-keyed by symbol after parsing. They are not
  # `list_return?`, but their envelope must stay list-shaped — a single-record
  # first-row unwrap would collapse them to one entry.
  @symbol_dict_return_methods [
    "fetchFundingRates",
    "fetchLeverages",
    "fetchOptionChain",
    "fetchTickers",
    "fetchTradingFees",
    # Plural collection tokens (MarginModes / OpenInterests / IsolatedBorrowRates)
    # resolve via the return-type alias table to singular parse types; re-key the
    # row list by symbol the same way fetchTickers does.
    "fetchMarginModes",
    "fetchOpenInterests",
    "fetchIsolatedBorrowRates"
  ]

  # CrossBorrowRates is keyed by currency code, not by symbol — the rows
  # carry `currency` with `symbol: nil`, so symbol indexing would drop every one.
  @currency_dict_return_methods ["fetchCrossBorrowRates"]

  # Bybit `fetchDepositAddressesByNetwork` returns a network-keyed map; rows live
  # under `result.chains`.
  @network_dict_return_methods ["fetchDepositAddressesByNetwork"]

  @dict_return_methods @symbol_dict_return_methods ++ @currency_dict_return_methods ++ @network_dict_return_methods

  # binanceusdm's bookTicker/premiumIndex/fundingInfo endpoints return a bare
  # array keyed by symbol when no symbol is given — the same shape as
  # fetchTickers — but their descriptor return type ("Tickers"/"FundingRates")
  # is shared with other venues whose current single-item collapse on these
  # same JS method names is separately owned. Alias onto fetchTickers's
  # dict-return classification (envelope shape, enrichment, symbol re-keying)
  # only for binanceusdm, so other venues stay untouched.
  @binanceusdm_dict_return_aliases ["fetchBidsAsks", "fetchMarkPrices", "fetchFundingIntervals", "fetchADLRank"]

  defp dict_shape_js_name(js_name, %Exchange{id: "binanceusdm"}) when js_name in @binanceusdm_dict_return_aliases,
    do: "fetchTickers"

  # binance spot's `ticker/bookTicker` is the same no-symbol-bare-array shape
  # as binanceusdm's aliased endpoints above — without a symbol it answers
  # every symbol as one JSON array, which a non-dict-return classification
  # collapses to a single first-row struct instead of the requested map.
  # https://developers.binance.com/en/docs/binance-spot-api-docs/rest-api/market-data-endpoints#symbol-order-book-ticker
  @binance_dict_return_aliases ["fetchBidsAsks"]

  defp dict_shape_js_name(js_name, %Exchange{id: "binance"}) when js_name in @binance_dict_return_aliases,
    do: "fetchTickers"

  # binancecoinm's `fundingInfo` is the same no-symbol-bare-array shape,
  # additionally spanning both COIN-M and USD-M symbols in one combined list
  # (verified live: identical 616-row body from both dapi and fapi hosts).
  @binancecoinm_dict_return_aliases ["fetchFundingIntervals"]

  defp dict_shape_js_name(js_name, %Exchange{id: "binancecoinm"}) when js_name in @binancecoinm_dict_return_aliases,
    do: "fetchTickers"

  defp dict_shape_js_name(js_name, _exchange), do: js_name

  defp envelope_list_return?(js_name, list_return?) do
    list_return? or js_name in @dict_return_methods
  end

  # Some read methods expose a compact fee schedule which must be expanded over
  # the caller's loaded market cache before field-map parsing. The transform is
  # authored in the spec, so the runtime only executes a venue-neutral recipe.
  defp validate_authored_transform_shape(payload, module, parse_type, js_name, exchange) do
    case get_in(module.__response_envelopes__(), [parse_type, js_name, "transform"]) do
      %{"kind" => "market_fee_rows", "mismatch_carve" => carve} = transform ->
        validate_market_fee_rows_shape(payload, exchange, transform, carve)

      _ ->
        :ok
    end
  end

  defp validate_market_fee_rows_shape(%{} = payload, %Exchange{id: exchange_id}, transform, carve) do
    fees_key = Map.get(transform, "fees_key", "fees")

    case Map.fetch(payload, fees_key) do
      :error -> :ok
      {:ok, fees} -> validate_market_fee_rows_carrier(fees, exchange_id, transform, carve)
    end
  end

  defp validate_market_fee_rows_shape(_payload, _exchange, _transform, _carve), do: :ok

  defp validate_market_fee_rows_carrier(fees, exchange_id, transform, carve) do
    if is_list(fees) and Enum.any?(fees, &authored_fee_row?(&1, transform)) do
      :ok
    else
      {:error,
       Error.exchange_error(
         "Authored market_fee_rows carrier mismatch for carve #{carve}: " <>
           "expected row keys #{inspect(fee_row_keys(transform))}, " <>
           "observed fees key shape #{inspect(fee_key_shape(fees))}",
         exchange: exchange_id,
         raw: fees
       )}
    end
  end

  defp authored_fee_row?(%{} = fee, transform) do
    Enum.all?(fee_row_keys(transform), &Map.has_key?(fee, &1))
  end

  defp authored_fee_row?(_fee, _transform), do: false

  defp fee_row_keys(transform) do
    [
      Map.get(transform, "fee_type_key", "instrument_type"),
      Map.get(transform, "maker_key", "maker_fee"),
      Map.get(transform, "taker_key", "taker_fee")
    ]
  end

  defp fee_key_shape(%{} = value) do
    keys = value |> Map.keys() |> Enum.sort()
    nested = Enum.find_value(keys, fn key -> nested_fee_key_shape(Map.fetch!(value, key)) end)
    %{map_keys: keys, nested: nested}
  end

  defp fee_key_shape([%{} = row | _]), do: %{list_row_keys: row |> Map.keys() |> Enum.sort()}
  defp fee_key_shape([]), do: :empty_list
  defp fee_key_shape(value) when is_list(value), do: :non_map_list
  defp fee_key_shape(_value), do: :scalar

  defp nested_fee_key_shape(value) when is_map(value) or is_list(value), do: fee_key_shape(value)
  defp nested_fee_key_shape(_value), do: nil

  defp apply_authored_transform(payload, module, parse_type, js_name, exchange) do
    config = get_in(module.__response_envelopes__(), [parse_type, js_name]) || %{}

    case Map.get(config, "transform") do
      %{"kind" => "market_fee_rows"} = transform -> market_fee_rows(payload, exchange, transform)
      %{"kind" => "merge_fields"} = transform -> merge_fields(payload, transform)
      "positional_rows" -> positional_rows(payload, Map.get(config, "columns"))
      _ -> payload
    end
  end

  # A venue answering a collection as positional arrays (OKX rubik statistics)
  # names its columns in the authored envelope; the field map then reads the row
  # by name like any object payload.
  defp positional_rows(payload, [_ | _] = columns), do: ResponseTransformer.positional_to_maps(payload, columns)
  defp positional_rows(payload, _columns), do: payload

  defp merge_fields(%{} = payload, %{"fields" => fields}) when is_map(fields) do
    Enum.reduce(fields, payload, fn
      {field, path}, acc when is_binary(field) and is_list(path) ->
        case nested_value(payload, path) do
          nil -> acc
          value -> Map.put(acc, field, value)
        end

      _, acc ->
        acc
    end)
  end

  defp merge_fields(payload, _transform), do: payload

  defp nested_value(value, []), do: value

  defp nested_value(payload, [key | rest]) when is_map(payload) and is_binary(key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> nested_value(value, rest)
      :error -> nil
    end
  end

  defp nested_value(_payload, _path), do: nil

  defp has_authored_transform?(module, parse_type, js_name) do
    is_map(get_in(module.__response_envelopes__(), [parse_type, js_name, "transform"]))
  end

  defp market_fee_rows(%{} = payload, %Exchange{markets: markets}, transform) when is_list(markets) do
    fees = Map.get(payload, Map.get(transform, "fees_key", "fees"), [])
    currency = Map.get(payload, Map.get(transform, "currency_key", "currency"))
    fee_type_key = Map.get(transform, "fee_type_key", "instrument_type")
    maker_key = Map.get(transform, "maker_key", "maker_fee")
    taker_key = Map.get(transform, "taker_key", "taker_fee")
    type_map = Map.get(transform, "market_type_map", %{})

    for market <- markets,
        market_currency?(market, currency),
        fee_type = Map.get(type_map, market_value(market, :type)),
        is_binary(fee_type),
        fee when is_map(fee) <- [Enum.find(fees, &(Map.get(&1, fee_type_key) == fee_type))] do
      %{
        "symbol" => market_value(market, :symbol),
        "maker" => Map.get(fee, maker_key),
        "taker" => Map.get(fee, taker_key),
        "percentage" => true,
        "tierBased" => true,
        "_bourse_info" => fee
      }
    end
  end

  # A market-keyed fee schedule cannot be expanded without the market cache.
  # Soft-passing the payload here is worse than useless: the compact schedule
  # then reaches the field map as a single row and parses into one struct with
  # `symbol`/`maker`/`taker` all nil and the raw envelope dumped into `info` —
  # the exact silent raw-leak this transform exists to close, returned as
  # `{:ok, _}`. Name the missing precondition instead (cf. task 319's currency
  # field-map gate above).
  defp market_fee_rows(%{} = _payload, %Exchange{id: exchange_id}, _transform) do
    raise ArgumentError,
          "#{exchange_id} authored a market_fee_rows transform, which expands a " <>
            "compact fee schedule over the loaded market cache, but `markets` is " <>
            "not loaded. Call Bourse.load_markets/1 (or Exchange.put_markets/2) and " <>
            "thread the returned struct into this call."
  end

  defp market_fee_rows(payload, _exchange, _transform), do: payload

  defp market_currency?(market, currency) when is_binary(currency), do: market_value(market, :base) == currency
  defp market_currency?(_market, _currency), do: false

  defp market_value(market, field) when is_map(market) do
    Map.get(market, field) || Map.get(market, Atom.to_string(field))
  end

  # Single-record reads backed by list envelopes parse the first row.
  defp normalize_payload([first | _], false, false) when is_map(first), do: first

  defp normalize_payload(payload, _list_return?, _envelope_list?), do: payload

  @deposit_address_methods ["fetchDepositAddress", "fetchDepositAddressesByNetwork"]

  # OKX returns EVERY address it has ever issued per chain; `selected: true` marks
  # the one currently attached to the account. Drop the rest before parsing;
  # otherwise the parser
  # takes whichever row happens to come first, which is routinely a stale address.
  # Depositing to a stale address is a real fund-loss surface, so this filter is
  # correctness, not cosmetics.
  defp filter_selected_deposit_rows(rows, exchange, js_name) when is_list(rows) and js_name in @deposit_address_methods do
    case deposit_address_slice(exchange)["row_filter"] do
      %{"key" => key, "equals" => expected} when is_binary(key) ->
        Enum.filter(rows, fn row -> is_map(row) and Map.get(row, key) == expected end)

      _ ->
        rows
    end
  end

  defp filter_selected_deposit_rows(payload, _exchange, _js_name), do: payload

  # `fetchDepositAddress` builds the network-keyed map and then indexes it:
  # the requested `network` wins; otherwise `defaultNetworks[code]`, then the code
  # itself as a network, then the first row. We select the equivalent RAW row up
  # front so the singular read still parses one record. A requested network with
  # no matching row is an error — never a silent
  # fallback to some other chain's address.
  defp select_requested_row(rows, %Exchange{id: "okx"} = exchange, "fetchDepositAddress", params) when is_list(rows) do
    rule = deposit_network_rule(exchange)
    code = params |> Map.get("code") |> normalize_currency_code()
    # The network travels as an authored CODE (`TRC20`, `MATIC`), matched verbatim
    # against the alias table's values — codes are not uniformly upper-case
    # (`X Layer`, `Starknet`), so case-folding here would break those venues.
    requested = Map.get(params, "network")

    if is_binary(requested) do
      case find_okx_deposit_row(rows, rule, exchange, requested) do
        %{} = row -> {:ok, row}
        nil -> {:error, {:requested_row_not_found, requested}}
      end
    else
      default = get_in(rule, ["default_networks", code])

      row =
        find_okx_deposit_row(rows, rule, exchange, default) ||
          find_okx_deposit_row(rows, rule, exchange, code) ||
          List.first(rows)

      {:ok, row}
    end
  end

  defp select_requested_row(rows, %Exchange{id: "okx"} = exchange, "fetchGreeks", %{"symbol" => symbol})
       when is_list(rows) and is_binary(symbol) do
    native_id = Symbol.to_exchange_id(symbol, exchange)

    case Enum.find(rows, &(Map.get(&1, "instId") == native_id)) do
      %{} = row -> {:ok, row}
      nil -> {:error, {:requested_row_not_found, native_id}}
    end
  end

  defp select_requested_row(rows, %Exchange{id: "binance"} = exchange, "fetchMarginMode", %{"symbol" => symbol})
       when is_list(rows) and is_binary(symbol) do
    native_id = binance_requested_market_id(symbol, exchange)

    case Enum.find(rows, &(Map.get(&1, "symbol") == native_id)) do
      %{} = row -> {:ok, row}
      nil -> {:error, {:requested_row_not_found, native_id}}
    end
  end

  defp select_requested_row(payload, _exchange, _js_name, _params), do: {:ok, payload}

  # The authored `deposit_address` slice drives BOTH the stale-row filter and the
  # requested-network selection, so both run off the spec rather than a venue
  # hardcode. A venue with no authored slice keeps the previous behaviour.
  defp deposit_address_slice(%Exchange{module: module}) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__field_maps__, 0) do
      module.__field_maps__()["deposit_address"] || %{}
    else
      %{}
    end
  end

  defp deposit_address_slice(_exchange), do: %{}

  # The `network` field rule carries the chain->code alias table; `default_networks`
  # sits on the slice. Both are needed to pick a row BEFORE parsing.
  defp deposit_network_rule(exchange) do
    slice = deposit_address_slice(exchange)

    slice
    |> get_in(["field_map", "network"])
    |> Kernel.||(%{})
    |> Map.put("default_networks", Map.get(slice, "default_networks", %{}))
  end

  # Resolution is delegated, never re-implemented: the row we SELECT here must carry
  # the same network the field extraction will PARSE out of it.
  defp find_okx_deposit_row(rows, rule, %Exchange{} = exchange, network) when is_binary(network) do
    Enum.find(rows, fn row ->
      is_map(row) and ResponseParser.network_code_for_row(row, rule, network_context(exchange)) == network
    end)
  end

  defp find_okx_deposit_row(_rows, _rule, _exchange, _network), do: nil

  defp normalize_currency_code(code) when is_binary(code), do: String.upcase(code)
  defp normalize_currency_code(_code), do: nil

  defp binance_requested_market_id(symbol, %Exchange{markets: markets} = exchange) when is_list(markets) do
    case Enum.find(markets, &(binance_market_symbol(&1) == symbol)) do
      market when is_map(market) -> binance_market_id(market) || Symbol.to_exchange_id(symbol, exchange)
      _ -> Symbol.to_exchange_id(symbol, exchange)
    end
  end

  defp binance_requested_market_id(symbol, exchange), do: Symbol.to_exchange_id(symbol, exchange)

  defp binance_market_symbol(market), do: Map.get(market, :symbol) || Map.get(market, "symbol")
  defp binance_market_id(market), do: Map.get(market, :id) || Map.get(market, "id")

  # FundingRates and OptionChain are symbol-keyed maps built from a list
  # of parsed structs — mirrors `parseFundingRates` / `parseOptionChain`.
  defp shape_parsed_result(parsed, js_name, false, _params) when js_name in @currency_dict_return_methods do
    case parsed do
      structs when is_list(structs) -> {:ok, index_by_currency(structs)}
      other -> {:ok, other}
    end
  end

  defp shape_parsed_result(parsed, js_name, false, _params) when js_name in @symbol_dict_return_methods do
    case parsed do
      structs when is_list(structs) -> {:ok, index_by_symbol(structs)}
      other -> {:error, {:unexpected_symbol_dict_shape, js_name, other}}
    end
  end

  defp shape_parsed_result(parsed, js_name, _list_return?, _params) when js_name in @network_dict_return_methods do
    case parsed do
      structs when is_list(structs) -> {:ok, index_by_network(structs)}
      other -> {:ok, other}
    end
  end

  # Singular funding-rate reads must not answer for a fundingless market or
  # collapse an empty payload to `{:ok, []}`. Spot symbols alias onto the
  # linear perp's compact id; the empty-list fallthrough is the unservable
  # surface (task 646).
  defp shape_parsed_result(parsed, "fetchFundingRate", false, params) do
    shape_singular_funding_rate(parsed, params["symbol"])
  end

  defp shape_parsed_result(parsed, _js_name, _list_return?, _params), do: {:ok, parsed}

  defp shape_singular_funding_rate([], symbol) do
    if fundingless_symbol?(symbol) do
      {:error, {:fundingless_symbol, symbol}}
    else
      {:error, {:unservable_funding_symbol, symbol}}
    end
  end

  defp shape_singular_funding_rate(parsed, symbol) do
    if fundingless_symbol?(symbol) do
      {:error, {:fundingless_symbol, symbol}}
    else
      {:ok, parsed}
    end
  end

  defp maybe_enrich_list(parsed, payload, js_name) when js_name in @dict_return_methods do
    enrich(parsed, payload, true)
  end

  defp maybe_enrich_list(parsed, _payload, _js_name), do: parsed

  defp stamp_deribit_transaction_type(transactions, %Exchange{id: "deribit"}, "fetchDeposits")
       when is_list(transactions) do
    Enum.map(transactions, &Map.put(&1, :type, "deposit"))
  end

  defp stamp_deribit_transaction_type(transactions, %Exchange{id: "deribit"}, "fetchWithdrawals")
       when is_list(transactions) do
    Enum.map(transactions, &Map.put(&1, :type, "withdrawal"))
  end

  defp stamp_deribit_transaction_type(parsed, _exchange, _js_name), do: parsed

  defp normalize_lighter_order_sides(orders, %Exchange{id: "lighter"}, "order") when is_list(orders) do
    Enum.map(orders, &normalize_lighter_order_side/1)
  end

  defp normalize_lighter_order_sides(%Bourse.Order{} = order, %Exchange{id: "lighter"}, "order") do
    normalize_lighter_order_side(order)
  end

  defp normalize_lighter_order_sides(parsed, _exchange, _parse_type), do: parsed

  defp normalize_lighter_order_side(%Bourse.Order{side: nil, info: %{"is_ask" => true}} = order) do
    %{order | side: "sell"}
  end

  defp normalize_lighter_order_side(%Bourse.Order{side: nil, info: %{"is_ask" => false}} = order) do
    %{order | side: "buy"}
  end

  defp normalize_lighter_order_side(order), do: order

  defp index_by_symbol(structs) do
    structs
    |> Enum.filter(fn %{symbol: sym} -> is_binary(sym) end)
    |> Map.new(fn %{symbol: sym} = struct -> {sym, struct} end)
  end

  defp index_by_network(structs) when is_list(structs) do
    structs
    |> Enum.filter(fn
      %{network: network} when is_binary(network) and network != "" -> true
      _ -> false
    end)
    |> Map.new(fn struct -> {struct.network, struct} end)
  end

  defp index_by_currency(structs) do
    structs
    |> Enum.filter(fn %{currency: currency} -> is_binary(currency) end)
    |> Map.new(fn %{currency: currency} = struct -> {currency, struct} end)
  end

  defp backfill_bybit_requested_tickers(tickers, %Exchange{id: "bybit"}, "fetchTickers", %{"symbols" => symbols})
       when is_list(tickers) and is_list(symbols) do
    Enum.flat_map(symbols, fn symbol ->
      native_id = bybit_ticker_native_id(symbol)

      case Enum.find(tickers, &(get_in(&1, [Access.key(:info), "symbol"]) == native_id)) do
        %Ticker{} = ticker -> [%{ticker | symbol: symbol}]
        _ -> []
      end
    end)
  end

  defp backfill_bybit_requested_tickers(parsed, _exchange, _js_name, _params), do: parsed

  # Deribit's `get_book_summary_by_currency` answers for the whole base currency,
  # so a
  # symbols-scoped request must drop the rest of that currency's instruments —
  # otherwise one requested symbol returns the entire option chain. Runs after
  # native-symbol backfill so the parsed symbols are unified by then.
  defp filter_deribit_requested_tickers(tickers, %Exchange{id: "deribit"}, "fetchTickers", %{"symbols" => symbols})
       when is_list(tickers) and is_list(symbols) and symbols != [] do
    Enum.filter(tickers, &(&1.symbol in symbols))
  end

  defp filter_deribit_requested_tickers(parsed, _exchange, _js_name, _params), do: parsed

  defp bybit_ticker_native_id(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, %{base: base, quote: _quote, settle: settle, expiry: expiry, strike: strike, option_type: option_type}}
      when is_binary(expiry) and is_binary(strike) and is_binary(option_type) ->
        date = Symbol.convert_date(expiry, :yymmdd, :ddmmmyy)
        "#{base}-#{date}-#{strike}-#{option_type}-#{settle}"

      {:ok, %{base: base, quote: quote}} ->
        base <> quote

      _ ->
        symbol
    end
  end

  defp backfill_native_symbols(parsed, exchange, _parse_type, params) do
    backfill_native_symbol(parsed, exchange, endpoint_market_type(params))
  end

  defp backfill_native_symbol(%{__struct__: _module} = parsed, exchange, endpoint_market_type) do
    backfill_one_native_symbol(parsed, exchange, endpoint_market_type)
  end

  defp backfill_native_symbol(%{} = parsed, exchange, endpoint_market_type) do
    Enum.reduce_while(parsed, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case backfill_one_native_symbol(value, exchange, endpoint_market_type) do
        {:ok, normalized} ->
          normalized_key = normalized_symbol_key(key, value, normalized)
          {:cont, {:ok, Map.put(acc, normalized_key, normalized)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp backfill_native_symbol(parsed, exchange, endpoint_market_type) when is_list(parsed) do
    parsed
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case backfill_one_native_symbol(value, exchange, endpoint_market_type) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp backfill_native_symbol(other, _exchange, _endpoint_market_type), do: {:ok, other}

  # A parsed symbol equal to the native id is only a raw-id passthrough worth re-converting when it
  # is not already unified — some venues' native ids (e.g. "ETH/USDT") are byte-identical to the
  # unified symbol, and re-converting those corrupts an already-correct value.
  defp unified_symbol?(symbol) when is_binary(symbol), do: String.contains?(symbol, "/")
  defp unified_symbol?(_symbol), do: false

  defp unified_symbol?(symbol, %Exchange{id: "alpaca"}) when is_binary(symbol), do: symbol != ""
  defp unified_symbol?(symbol, _exchange), do: unified_symbol?(symbol)

  defp backfill_one_native_symbol(%{__struct__: Bourse.Market} = struct, _exchange, _endpoint_market_type) do
    {:ok, struct}
  end

  defp backfill_one_native_symbol(%{symbol: symbol, info: info} = struct, exchange, endpoint_market_type)
       when is_map(info) do
    native =
      [
        Map.get(info, "market_id"),
        Map.get(info, "symbol"),
        Map.get(info, "instrument_name"),
        Map.get(info, "instId"),
        hyperliquid_native_coin(info, exchange),
        symbol
      ]
      |> Enum.map(&Bourse.Safe.string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.find(&backfill_symbol?(symbol, &1))

    cond do
      unified_symbol?(symbol, exchange) ->
        {:ok, struct}

      is_binary(native) and backfill_symbol?(symbol, native) ->
        resolve_backfilled_symbol(struct, native, exchange, info, endpoint_market_type)

      true ->
        {:ok, struct}
    end
  end

  defp backfill_one_native_symbol(%{symbol: symbol} = struct, exchange, endpoint_market_type) when is_binary(symbol) do
    if unified_symbol?(symbol, exchange) do
      {:ok, struct}
    else
      resolve_backfilled_symbol(struct, symbol, exchange, %{}, endpoint_market_type)
    end
  end

  defp backfill_one_native_symbol(struct, _exchange, _endpoint_market_type), do: {:ok, struct}

  defp backfill_symbol?(symbol, native), do: is_nil(symbol) or (symbol == native and not unified_symbol?(symbol))

  defp resolve_backfilled_symbol(struct, native, exchange, info, endpoint_market_type) do
    market_type = endpoint_market_type || native_market_type(struct, native, exchange)

    symbol =
      loaded_market_symbol(exchange, native, market_type) ||
        binance_contract_symbol(native, exchange) ||
        resolve_backfilled_symbol_from_native(native, exchange, info, market_type)

    cond do
      unified_symbol?(symbol, exchange) ->
        {:ok, %{struct | symbol: symbol}}

      is_nil(market_type) ->
        {:error,
         {:unresolved_unified_symbol,
          %{exchange: exchange.id, market_type: nil, native_symbol: native, resolved_symbol: symbol}}}

      true ->
        {:ok, %{struct | symbol: native}}
    end
  end

  defp normalized_symbol_key(key, %{symbol: original}, %{symbol: normalized})
       when key == original and is_binary(normalized), do: normalized

  defp normalized_symbol_key(key, _original, _normalized), do: key

  defp loaded_market_symbol(%Exchange{markets: markets}, native, endpoint_market_type)
       when is_list(markets) and is_binary(native) do
    matches = Enum.filter(markets, &(binance_market_id(&1) == native))

    matches
    |> Enum.find(&market_matches_endpoint_type?(&1, endpoint_market_type))
    |> Kernel.||(List.first(matches))
    |> loaded_market_identity_symbol()
  end

  defp loaded_market_symbol(_exchange, _native, _endpoint_market_type), do: nil

  defp market_matches_endpoint_type?(_market, nil), do: true

  defp market_matches_endpoint_type?(market, endpoint_market_type) do
    market_type = Atom.to_string(endpoint_market_type)

    Map.get(market, endpoint_market_type) == true or
      Map.get(market, market_type) == true or
      Map.get(market, :type) == market_type or
      Map.get(market, "type") == market_type
  end

  defp loaded_market_identity_symbol(nil), do: nil

  defp loaded_market_identity_symbol(market), do: Map.get(market, :symbol) || Map.get(market, "symbol")

  defp resolve_backfilled_symbol_from_native(native, exchange, info, market_type) do
    resolve_native_symbol(native, exchange, market_type, info) || from_exchange_id(native, exchange, market_type)
  end

  defp from_exchange_id(native, exchange, market_type) when is_atom(market_type) do
    Symbol.from_exchange_id(native, exchange, market_type)
  rescue
    Bourse.Symbol.Error -> nil
  end

  # Binance's contract venues use compact ids that encode the settlement currency
  # and, for delivery contracts, a YYMMDD expiry. They identify the market without
  # depending on the endpoint family, so all parsed multi-row reads share this
  # conversion rather than only tickers receiving an endpoint-market hint.
  #
  # COIN-M (dapi) ids settle in base and are listed by both binanceusdm's inverse
  # family and the standalone binancecoinm venue.
  defp binance_contract_symbol(native, %Exchange{id: id})
       when is_binary(native) and id in ["binanceusdm", "binancecoinm"] do
    case Regex.run(~r/^([A-Z0-9]+)USD_(PERP|\d{6})$/, native) do
      [_, base, "PERP"] -> Symbol.build(base, "USD", base)
      [_, base, expiry] -> Symbol.build(base, "USD", "#{base}-#{expiry}")
      _ -> binance_linear_symbol(native, id)
    end
  end

  defp binance_contract_symbol(_native, _exchange), do: nil

  # fapi-only grammars. binancecoinm lists no linear contracts, and the spot venues
  # (`binance`/`binanceus`) list USD1 pairs whose ids would otherwise be mis-carved
  # as settled swaps — so this stays scoped to binanceusdm rather than the family.
  defp binance_linear_symbol(_native, "binancecoinm"), do: nil

  defp binance_linear_symbol(native, _id) do
    case Regex.run(~r/^([A-Z0-9]+)(USDT|USDC)_(\d{6})$/, native) do
      [_, base, quote, expiry] -> Symbol.build(base, quote, "#{quote}-#{expiry}")
      _ -> binance_linear_perpetual_symbol(native)
    end
  end

  # `U` and `USD1` quotes are only distinguishable from a base-asset suffix by the
  # listing itself; both are live fapi perpetual quote assets (/fapi/v1/exchangeInfo,
  # verified 2026-07-19: BTCU/ETHU quoteAsset "U", BTCUSD1/ETHUSD1 quoteAsset "USD1").
  defp binance_linear_perpetual_symbol(native) do
    case Regex.run(~r/^([A-Z0-9]+)(USD1|U)$/, native) do
      [_, base, quote] -> Symbol.build(base, quote, quote)
      _ -> nil
    end
  end

  defp endpoint_market_type(%{"_bourse_endpoint_market_type" => market_type})
       when market_type in [:spot, :swap, :future, :option], do: market_type

  defp endpoint_market_type(%{"symbol" => symbol}) when is_binary(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, parsed} -> Symbol.detect_market_type(parsed)
      {:error, _reason} -> nil
    end
  end

  defp endpoint_market_type(_params), do: nil

  # Hyperliquid rows name the instrument as `coin` (orders/fills/positions) or
  # `name` (metaAndAssetCtxs / universe rows used by tickers and funding rates).
  defp hyperliquid_native_coin(_info, %Exchange{id: id}) when id != "hyperliquid", do: nil

  defp hyperliquid_native_coin(info, _exchange) do
    Map.get(info, "coin") ||
      Map.get(info, "name") ||
      get_in(info, ["order", "coin"]) ||
      get_in(info, ["position", "coin"])
  end

  # Hyperliquid market ids use the HIP-3 option map, raw spot ids, or BASE/USDC:USDC.
  defp resolve_native_symbol(coin, %Exchange{id: "hyperliquid"} = exchange, _market_type, _info) when is_binary(coin) do
    hip3 = hyperliquid_hip3_token(exchange, coin)

    cond do
      is_map(hip3) ->
        code = Map.get(hip3, "code") || String.replace(coin, ":", "-")
        quote = Map.get(hip3, "quote") || "USDC"
        "#{code}/#{quote}:#{quote}"

      String.contains?(coin, "/") or String.contains?(coin, "@") ->
        coin

      String.contains?(coin, ":") ->
        code = coin |> String.replace(":", "-") |> String.upcase()
        "#{code}/USDC:USDC"

      true ->
        "#{String.upcase(coin)}/USDC:USDC"
    end
  end

  defp resolve_native_symbol(native, %Exchange{id: "bybit"}, :swap, _info) when is_binary(native) do
    if String.ends_with?(native, "PERP") do
      native
      |> String.trim_trailing("PERP")
      |> Symbol.build("USDC", "USDC")
    end
  end

  defp resolve_native_symbol(_coin, _exchange, _market_type, _info), do: nil

  defp hyperliquid_hip3_token(%Exchange{options: options}, coin) when is_map(options) do
    get_in(options, ["hip3TokensByName", coin]) || get_in(options, [:hip3TokensByName, coin])
  end

  defp hyperliquid_hip3_token(_exchange, _coin), do: nil

  defp native_market_type(%{info: %{"category" => "spot"}}, _native, _exchange), do: :spot

  defp native_market_type(%{info: %{"category" => category}}, _native, _exchange) when category in ["linear", "inverse"],
    do: :swap

  defp native_market_type(%{info: %{"category" => "option"}}, _native, _exchange), do: :option
  defp native_market_type(%{info: %{"kind" => "option"}}, _native, _exchange), do: :option
  defp native_market_type(%{info: %{"instrument_type" => "option"}}, _native, _exchange), do: :option

  defp native_market_type(%{info: %{"baseCoin" => base, "quoteCoin" => quote} = info}, _native, _exchange)
       when is_binary(base) and is_binary(quote) do
    if Map.has_key?(info, "contractType") or Map.has_key?(info, "settleCoin"), do: :swap, else: :spot
  end

  defp native_market_type(%{info: %{"instType" => inst_type}}, _native, _exchange) when is_binary(inst_type) do
    case String.upcase(inst_type) do
      "SPOT" -> :spot
      "MARGIN" -> :spot
      "SWAP" -> :swap
      "FUTURES" -> :future
      "OPTION" -> :option
      _ -> :spot
    end
  end

  defp native_market_type(%{__struct__: Bourse.OptionData}, _native, _exchange), do: :option

  # Bybit option tickers (greeks) use BASE-DDMMMYY-STRIKE-C/P-SETTLE. Without an
  # option market-type hint, reverse conversion falls through to :swap and the
  # request-symbol filter empties fetchAllGreeks.
  defp native_market_type(%{__struct__: Bourse.Greeks}, native, exchange) when is_binary(native) do
    if bybit_option_native_id?(native), do: :option, else: native_market_type(nil, native, exchange)
  end

  defp native_market_type(_struct, _native, %Exchange{id: "bybit"}), do: nil

  defp native_market_type(_struct, native, _exchange) when is_binary(native) do
    if String.contains?(native, "_") and not String.contains?(native, "-"), do: :spot, else: :swap
  end

  defp bybit_option_native_id?(native) do
    Regex.match?(~r/^[A-Z0-9]+-\d{1,2}[A-Z]{3}\d{2}-\d+-[CP]-[A-Z]+$/, native)
  end

  defp apply_request_filters(parsed, params, parse_type) when is_list(parsed) do
    parsed
    |> filter_requested_symbols(params)
    |> filter_requested_currency(params, parse_type)
    |> filter_by_since(params)
    |> maybe_sort_chronologically(parse_type)
    |> maybe_take_limit(params["limit"] || params["count"], params)
  end

  # fetchTickers is indexed by symbol before request filters run. Keep that
  # shape while filtering its values: Binance USD-M's fapi/dapi `/ticker/24hr`
  # has no server-side `symbols` filter the way spot's `/api/v3/ticker/24hr`
  # does, so the requested-symbol filter must run client-side over the parsed
  # rows.
  #
  # Observed live 2026-07-18, each with `symbols=["BTCUSDT"]`:
  #   testnet.binancefuture.com/fapi/v1/ticker/24hr -> 200, 627 rows (ignored)
  #   testnet.binancefuture.com/dapi/v1/ticker/24hr -> 200,  45 rows (ignored)
  #   testnet.binance.vision/api/v3/ticker/24hr     -> 200,   1 row  (honored)
  #
  # Guarded to NON-struct maps: a singular parse (`%Ticker{}` from fetchTicker)
  # is also a map, and routing it here raises `Enumerable not implemented`.
  defp apply_request_filters(parsed, params, parse_type) when is_non_struct_map(parsed) do
    filter_indexed_symbols(parsed, params, parse_type)
  end

  defp apply_request_filters(parsed, _params, _parse_type), do: parsed

  # All-greeks returns a
  # symbol-keyed dict, not a list. Index after request filters so unmatched
  # option rows are dropped before re-keying.
  defp index_all_greeks(parsed, "fetchAllGreeks") when is_list(parsed), do: index_by_symbol(parsed)
  defp index_all_greeks(parsed, _js_name), do: parsed

  # Collection parsers sort these rows chronologically before
  # `filterBySymbolSinceLimit` applies `limit`. Some endpoints return newest-first.
  defp maybe_sort_chronologically(list, parse_type)
       when parse_type in ["funding_rate_history", "funding_history", "borrow_rate", "order"] do
    Enum.sort_by(list, fn
      %{timestamp: ts} when is_integer(ts) -> ts
      _ -> 0
    end)
  end

  defp maybe_sort_chronologically(list, _parse_type), do: list

  # Symbol/since/limit filtering ignores rows without a `:symbol` key; those are currency-
  # scoped structs (Transaction / LedgerEntry / TransferEntry / DepositAddress) —
  # ignore the symbol filter for those rather than KeyError on unguarded access.
  defp filter_requested_symbols(parsed, %{"symbols" => symbols}) when is_list(symbols) do
    Enum.filter(parsed, fn
      %{symbol: symbol} -> symbol in symbols
      _row -> true
    end)
  end

  defp filter_requested_symbols(parsed, %{"symbol" => symbol}) when is_binary(symbol) do
    Enum.filter(parsed, fn
      %{symbol: row_symbol} -> row_symbol == symbol
      _row -> true
    end)
  end

  defp filter_requested_symbols(parsed, _params), do: parsed

  defp filter_requested_currency(parsed, %{"code" => code}, "transfer") when is_binary(code) do
    Enum.filter(parsed, fn
      %{currency: currency} -> currency == code
      _row -> true
    end)
  end

  defp filter_requested_currency(parsed, _params, _parse_type), do: parsed

  # Symbol-keyed results (fetchTickers) filter by value while preserving the map
  # shape — the list-oriented clauses above would flatten them into k/v tuples.
  # Rows without a `:symbol` key are kept, matching the list behaviour.
  defp filter_indexed_symbols(parsed, %{"symbols" => symbols}, _parse_type) when is_list(symbols) do
    Map.filter(parsed, fn
      {_key, %{symbol: symbol}} -> symbol in symbols
      _entry -> true
    end)
  end

  defp filter_indexed_symbols(parsed, %{"symbol" => symbol}, "leverage") when is_binary(symbol) do
    Map.filter(parsed, fn
      {_key, %{symbol: row_symbol}} -> row_symbol == symbol
      _entry -> true
    end)
  end

  defp filter_indexed_symbols(parsed, _params, _parse_type), do: parsed

  # Since/limit filtering drops rows older than `since` before limit.
  # Used by fetchBorrowRateHistory fixtures.
  defp filter_by_since(parsed, %{"since" => since}) when is_integer(since) do
    Enum.filter(parsed, fn
      %{timestamp: ts} when is_integer(ts) -> ts >= since
      _ -> true
    end)
  end

  defp filter_by_since(parsed, _params), do: parsed

  # When `since` is set, take from the start
  # (oldest after chronological sort); otherwise take the tail (newest `limit` rows).
  defp maybe_take_limit(parsed, limit, params) when is_integer(limit) and limit >= 0 do
    if is_integer(params["since"]) do
      Enum.take(parsed, limit)
    else
      Enum.take(parsed, -limit)
    end
  end

  defp maybe_take_limit(parsed, _limit, _params), do: parsed

  # Currency parse helpers convert a list to a code-keyed map.
  defp parse_currency_entries(_module, _parser, [], _envelope), do: {:ok, []}

  defp parse_currency_entries(module, parser, entries, envelope) do
    groups = group_currency_entries(module, entries)

    with {:ok, structs} <- invoke_parser(module, parser, Enum.map(groups, & &1.parse), envelope: envelope) do
      {:ok, Enum.zip(structs, Enum.map(groups, & &1.info))}
    end
  end

  # Some venues return one currency row per network. An authored `group_by`
  # config turns those rows into one parse input with the original rows retained
  # for the unified currency's raw `info` field.
  defp group_currency_entries(module, entries) do
    field_maps = if function_exported?(module, :__field_maps__, 0), do: module.__field_maps__(), else: %{}

    case get_in(field_maps, ["currency", "group_by"]) do
      %{"key" => key, "collection_key" => collection_key} when is_binary(key) and is_binary(collection_key) ->
        entries
        |> Enum.group_by(&Map.get(&1, key))
        |> Enum.map(fn {group_key, rows} ->
          representative = Enum.find(rows, &Map.get(&1, "mainNet")) || hd(rows)
          %{parse: representative |> Map.put(key, group_key) |> Map.put(collection_key, rows), info: rows}
        end)

      _ ->
        Enum.map(entries, &%{parse: &1, info: &1})
    end
  end

  # Normalize leverage payloads to a non-empty list of row maps.
  defp leverage_rows(rows) when is_list(rows), do: Enum.filter(rows, &is_map/1)
  defp leverage_rows(%{} = row), do: [row]
  defp leverage_rows(_), do: []

  # OKX hedge-mode rows carry posSide long/short with the same lever; merge into
  # one Leverage. Net-mode, single-row, and Bybit-style maps
  # go through the authored field map when present.
  defp parse_leverage_payload(exchange, module, parser, rows, params, envelope) do
    if Enum.any?(rows, &leverage_side_row?/1) do
      merged = merge_sided_leverage_rows(rows)

      # Validate before stamping the request symbol, same order as the field-map
      # branch below — a symbol backfilled from params would otherwise mask a
      # payload that carried no leverage at all.
      with :ok <- validate_parsed(merged, false) do
        backfill_request_symbols(merged, params, "leverage", false)
      end
    else
      parse_opts = [{:envelope, envelope} | build_parse_opts(exchange, params, hd(rows), false)]

      with {:ok, parsed} <- invoke_parser(module, parser, hd(rows), parse_opts),
           parsed = enrich(parsed, hd(rows), false),
           :ok <- validate_parsed(parsed, false) do
        backfill_request_symbols(parsed, params, "leverage", false)
      end
    end
  end

  defp leverage_side_row?(%{"posSide" => side}) when is_binary(side) do
    String.downcase(side) in ["long", "short"]
  end

  defp leverage_side_row?(_), do: false

  defp merge_sided_leverage_rows(rows) do
    base = %Bourse.Leverage{info: rows}

    Enum.reduce(rows, base, fn row, acc ->
      lever = Bourse.Safe.integer(Map.get(row, "lever") || Map.get(row, "leverage"))
      margin_mode = Bourse.Safe.string_lower(Map.get(row, "mgnMode") || Map.get(row, "marginMode"))
      side = row |> Map.get("posSide") |> to_string() |> String.downcase()

      acc = if is_binary(margin_mode), do: %{acc | margin_mode: margin_mode}, else: acc

      case side do
        "long" -> %{acc | long_leverage: lever}
        "short" -> %{acc | short_leverage: lever}
        _ -> %{acc | long_leverage: lever, short_leverage: lever}
      end
    end)
  end

  # Re-key parsed currency structs by unified code, setting `code` and `info`
  # (the raw entry) per entry.
  defp build_currency_map(entries, exchange) do
    Map.new(entries, fn
      {%Bourse.Currency{} = struct, raw} ->
        struct = %{struct | code: currency_code(struct.id, exchange), info: raw}
        {struct.code, struct}

      {other, _raw} ->
        raise ArgumentError,
              "fetchCurrencies expected %Bourse.Currency{} after field-map parse " <>
                "for #{exchange.id}, got #{inspect(other)}; missing authored " <>
                "normalization.field_maps.currency slice?"
    end)
  end

  # Require an authored currency field map before parsing rows. Soft-pass of
  # `:no_field_map` would hand raw maps to `build_currency_map/2` and raise
  # `key :id not found` — name the venue and missing slice instead (task 319).
  # Modules that do not export `__field_maps__/0` (unit-test doubles that return
  # `%Currency{}` directly from `parse_currency/2`) skip this gate. `ensure_loaded?`
  # must precede `function_exported?`, which answers false for a merely-unloaded
  # module — without it the gate silently degrades to `:ok` on the first call for a
  # generated exchange module, and the raw rows reach `build_currency_map/2` and
  # raise the bare ArgumentError this gate exists to replace.
  defp ensure_currency_field_map(module, %Exchange{id: exchange_id}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__field_maps__, 0) do
      currency_field_map_status(module.__field_maps__()["currency"], exchange_id)
    else
      :ok
    end
  end

  # Every authored slice carries the `{_unresolved_reason, extras, field_map}`
  # wrapper; a resolved non-empty `field_map` is the only shape that may parse.
  defp currency_field_map_status(%{"field_map" => field_map}, _exchange_id)
       when is_map(field_map) and map_size(field_map) > 0, do: :ok

  defp currency_field_map_status(%{"_unresolved_reason" => reason}, exchange_id) when is_binary(reason) and reason != "",
    do: {:error, {:missing_currency_field_map, exchange_id, reason}}

  defp currency_field_map_status(_slice, exchange_id), do: {:error, {:missing_currency_field_map, exchange_id, nil}}

  # Uppercase the venue id, then apply the exchange's
  # common-currency aliases (e.g. Kraken XBT -> BTC).
  defp currency_code(id, %Exchange{common_currencies: aliases}) when is_binary(id) do
    up = String.upcase(id)
    Map.get(aliases, up, up)
  end

  defp currency_code(id, _exchange), do: id

  defp ohlcv_envelope_config(module, js_name), do: envelope_config(module, "ohlcv", js_name)

  defp envelope_config(module, slot, js_name) do
    case module.__response_envelopes__() do
      %{^slot => %{} = slot_config} -> Map.get(slot_config, js_name)
      _ -> nil
    end
  end

  # Trading: `data` is `[%{details: [currency rows...], ...}]` — first account wins.
  # Funding: `data` is `[currency rows...]` with no nested details — normalize to
  # the same `%{"details" => rows}` shape so one keyed_collection rule covers both
  # and the parser does not treat the funding list as N separate balances.
  # Empty `data` becomes an empty details collection so free/used/total stay maps.
  defp balance_parse_payload(body, module, js_name, params) do
    case extract_envelope_payload(body, module, "balance", js_name) do
      [%{"details" => _} = account | _] ->
        account

      # Bybit v5 wallet-balance: accounts under `result.list`, currency rows under
      # each account's `coin` — flatten across accounts so the keyed_collection
      # field map (collection_key "coin") indexes every row.
      [%{"coin" => _} | _] = accounts ->
        %{"coin" => Enum.flat_map(accounts, &List.wrap(&1["coin"]))}

      # Derive get_all_portfolios: multi-subaccount list, currency rows under
      # each account's `collaterals` — flatten so keyed_collection can index.
      [%{"collaterals" => _} | _] = accounts ->
        %{"collaterals" => Enum.flat_map(accounts, &List.wrap(&1["collaterals"]))}

      [_ | _] = rows ->
        %{"details" => annotate_binance_papi_balance_rows(rows, params)}

      %{} = account ->
        account

      # `[]`/nil/scalar: a missing envelope path (scalar-balance venues such as
      # bybit/binance whose field map reads top-level free/used/total, or an
      # empty OKX `data`) must fall through to the raw body — reshaping it into
      # `%{"details" => []}` would strip the scalar rows and yield empty maps.
      _ ->
        body
    end
  end

  defp annotate_binance_papi_balance_rows(rows, params) do
    if Enum.any?(rows, &Map.has_key?(&1, "totalWalletBalance")) do
      Enum.map(rows, &annotate_binance_papi_balance_row(&1, params))
    else
      rows
    end
  end

  defp annotate_binance_papi_balance_row(%{} = row, %{"subType" => "linear"}) do
    row
    |> maybe_put_synthetic("_bourse_free", Map.get(row, "umWalletBalance"))
    |> maybe_put_synthetic("_bourse_used", "0")
    |> maybe_put_synthetic("_bourse_total", Map.get(row, "umWalletBalance"))
  end

  defp annotate_binance_papi_balance_row(%{} = row, _params) do
    maybe_put_synthetic(row, "_bourse_total", Map.get(row, "totalWalletBalance"))
  end

  defp put_balance_info(%Bourse.Balance{} = balance, body) do
    balance
    |> remap_hyperliquid_spot_balance_codes(body)
    |> reconcile_balance_used()
    |> Map.put(:info, body)
    |> Map.put(:timestamp, balance_timestamp(body))
    |> put_datetime()
  end

  defp put_balance_info(other, _body), do: other

  # Hyperliquid spot unit tokens (UETH/USOL/…) map to their authored base
  # codes. Applied after the keyed_collection
  # indexes raw coin names so free/used/total share codes.
  defp remap_hyperliquid_spot_balance_codes(%Bourse.Balance{} = balance, %{"balances" => balances})
       when is_list(balances) do
    mapping = hyperliquid_spot_currency_mapping()

    %{
      balance
      | free: remap_balance_code_map(balance.free, mapping),
        used: remap_balance_code_map(balance.used, mapping),
        total: remap_balance_code_map(balance.total, mapping)
    }
  end

  defp remap_hyperliquid_spot_balance_codes(balance, _body), do: balance

  defp remap_balance_code_map(map, mapping) when is_map(map) do
    Enum.reduce(map, %{}, fn {code, value}, acc ->
      mapped = Map.get(mapping, code, code)
      Map.update(acc, mapped, value, fn existing -> hyperliquid_balance_add(existing, value) end)
    end)
  end

  defp remap_balance_code_map(other, _mapping), do: other

  defp hyperliquid_balance_add(a, b) when is_number(a) and is_number(b), do: a + b
  defp hyperliquid_balance_add(a, _b), do: a

  defp hyperliquid_spot_currency_mapping do
    %{
      "UETH" => "ETH",
      "USOL" => "SOL",
      "UBTC" => "BTC",
      "HPENGU" => "PENGU",
      "UFART" => "FARTCOIN",
      "UPUMP" => "PUMP",
      "UDZ" => "2Z",
      "UBONK" => "BONK",
      "USDT0" => "USDT",
      "XAUT0" => "XAUT",
      "UXPL" => "XPL",
      "UUUSPX" => "SPX"
    }
  end

  # Binance portfolio-margin (`GET /papi/v1/balance`) answers with a bare JSON
  # array of asset rows and carries no envelope `time`; map-enveloped balance
  # payloads (spot, futures account) carry it at the top level.
  defp balance_timestamp(body) when is_map(body), do: Bourse.Safe.integer(Map.get(body, "time"))
  defp balance_timestamp(_body), do: nil

  # Fill exactly one missing balance member from the other
  # two. Authored values are never overwritten.
  defp reconcile_balance_used(%Bourse.Balance{free: free, total: total, used: used} = balance)
       when is_map(free) or is_map(total) or is_map(used) do
    free_map = balance_map(free)
    used_map = balance_map(used)
    total_map = balance_map(total)
    currencies = [free_map, used_map, total_map] |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

    free = balance_member(currencies, &fill_free/3, free_map, used_map, total_map)
    # `used` reads the filled `free` — a derived free only exists when used was
    # already parsed, so the fill still touches exactly one member per currency.
    used = balance_member(currencies, &fill_used/3, free, used_map, total_map)
    total = balance_member(currencies, &fill_total/3, free_map, used_map, total_map)

    %{balance | free: free, used: used, total: total}
  end

  defp reconcile_balance_used(balance), do: balance

  defp balance_map(value) when is_map(value), do: value
  defp balance_map(_value), do: %{}

  defp balance_member(currencies, fill, free_map, used_map, total_map) do
    Map.new(currencies, fn currency ->
      {currency, fill.(Map.get(free_map, currency), Map.get(used_map, currency), Map.get(total_map, currency))}
    end)
  end

  defp fill_free(nil, used, total) when is_number(used) and is_number(total), do: balance_sub(total, used)
  defp fill_free(free, _used, _total), do: free

  # Only derive when used is nil; never clobber an authored
  # used (e.g. Deribit maintenance_margin), or portfolio-margin rows reporting
  # equity=0 with positive margin yield huge negatives.
  defp fill_used(free, nil, total) when is_number(free) and is_number(total), do: balance_sub(total, free)
  defp fill_used(_free, used, _total), do: used

  defp fill_total(free, used, nil) when is_number(free) and is_number(used), do: balance_add(free, used)
  defp fill_total(_free, _used, total), do: total

  defp balance_sub(left, right) do
    left |> balance_decimal() |> Decimal.sub(balance_decimal(right)) |> Decimal.to_float()
  end

  defp balance_add(left, right) do
    left |> balance_decimal() |> Decimal.add(balance_decimal(right)) |> Decimal.to_float()
  end

  defp balance_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp balance_decimal(value) when is_float(value), do: value |> Float.to_string() |> Decimal.new()

  # Unwrap the authored envelope key (e.g. deribit's jsonrpc "result") for `slot`;
  # a bare body (binance-style, no envelope) passes through unchanged.
  defp extract_envelope_payload(body, module, slot, js_name) do
    extract_path_from_config(body, envelope_config(module, slot, js_name))
  end

  # `fetchTime` returns integer milliseconds. Prefer authored envelope `data`/`result`, then
  # common venue shapes (OKX `data[0].ts`, Bybit `result.timeNano`/`timeSecond`*1000,
  # top-level `serverTime`/`timestamp`).
  defp extract_server_time_ms(body, module, js_name) do
    payload = extract_envelope_payload(body, module, "time", js_name)

    case server_time_ms(payload) || server_time_ms(body) do
      ms when is_integer(ms) -> {:ok, ms}
      nil -> {:error, {:unexpected_response_shape, body}}
    end
  end

  defp server_time_ms([row | _]), do: server_time_ms(row)
  defp server_time_ms(%{"ts" => ts}), do: Bourse.Safe.integer(ts)
  defp server_time_ms(%{"timeNano" => nano}), do: rescale_time(Bourse.Safe.integer(nano), &div(&1, 1_000_000))
  defp server_time_ms(%{"timeSecond" => sec}), do: rescale_time(Bourse.Safe.integer(sec), &(&1 * 1000))
  defp server_time_ms(%{"serverTime" => ms}), do: Bourse.Safe.integer(ms)
  defp server_time_ms(%{"timestamp" => timestamp}), do: timestamp_ms(timestamp)
  defp server_time_ms(%{"time" => ms}), do: Bourse.Safe.integer(ms)
  defp server_time_ms(%{"data" => data}), do: server_time_ms(data)
  defp server_time_ms(%{"result" => result}), do: server_time_ms(result)
  defp server_time_ms(value), do: Bourse.Safe.integer(value)

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> Bourse.Safe.integer(value)
    end
  end

  defp timestamp_ms(value), do: Bourse.Safe.integer(value)

  defp rescale_time(nil, _fun), do: nil
  defp rescale_time(value, fun), do: fun.(value)

  defp extract_ohlcv_payload(body, config), do: extract_path_from_config(body, config)

  defp order_book_payload(%{"result" => %{} = payload}), do: payload
  defp order_book_payload(%{"data" => [%{} = payload | _]}), do: payload
  defp order_book_payload(%{} = payload), do: payload
  defp order_book_payload(_body), do: nil

  # Read each order-book side as a list; a
  # missing or non-list side defaults to []. Hyperliquid's l2Book instead carries
  # bid and ask object lists at levels[0] and levels[1].
  defp order_book_side(%{"levels" => [bids, _asks]}, :bids) when is_list(bids), do: bids
  defp order_book_side(%{"levels" => [_bids, asks]}, :asks) when is_list(asks), do: asks

  defp order_book_side(payload, side) do
    keys = if side == :bids, do: ["bids", "b"], else: ["asks", "a"]

    Enum.find_value(keys, [], fn key ->
      case Map.get(payload, key) do
        list when is_list(list) -> list
        _ -> nil
      end
    end)
  end

  # Unified levels are exact [price, amount] pairs. Provider-specific columns
  # remain in OrderBook.info; only provider-documented input shapes are accepted.
  defp order_book_levels(levels, direction, exchange_id) when is_list(levels) do
    with {:ok, normalized} <- normalize_order_book_levels(levels, exchange_id) do
      {:ok, Enum.sort_by(normalized, &hd/1, direction)}
    end
  end

  defp order_book_levels(levels, _direction, exchange_id) do
    unexpected_order_book_level(exchange_id, levels)
  end

  defp normalize_order_book_levels(levels, exchange_id) do
    levels
    |> Enum.reduce_while({:ok, []}, fn level, {:ok, acc} ->
      case normalize_order_book_level(level, exchange_id) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_order_book_level([price, amount] = level, exchange_id) do
    normalize_order_book_pair(price, amount, exchange_id, level)
  end

  defp normalize_order_book_level([price, amount, count] = level, "okx") do
    case Bourse.Safe.integer(count) do
      count when is_integer(count) and count >= 0 -> normalize_order_book_pair(price, amount, "okx", level)
      _ -> unexpected_order_book_level("okx", level)
    end
  end

  defp normalize_order_book_level([price, amount, deprecated, count] = level, "okx") do
    with 0 <- Bourse.Safe.integer(deprecated),
         count when is_integer(count) and count >= 0 <- Bourse.Safe.integer(count) do
      normalize_order_book_pair(price, amount, "okx", level)
    else
      _ -> unexpected_order_book_level("okx", level)
    end
  end

  defp normalize_order_book_level(%{"px" => price, "sz" => amount} = level, exchange_id) do
    normalize_order_book_pair(price, amount, exchange_id, level)
  end

  defp normalize_order_book_level(%{"price" => price, "remaining_base_amount" => amount} = level, exchange_id) do
    normalize_order_book_pair(price, amount, exchange_id, level)
  end

  defp normalize_order_book_level(level, exchange_id) do
    unexpected_order_book_level(exchange_id, level)
  end

  defp normalize_order_book_pair(price, amount, exchange_id, level) do
    with parsed_price when is_number(parsed_price) <- Bourse.Safe.number(price),
         parsed_amount when is_number(parsed_amount) <- Bourse.Safe.number(amount) do
      {:ok, [parsed_price, parsed_amount]}
    else
      _ -> unexpected_order_book_level(exchange_id, level)
    end
  end

  defp unexpected_order_book_level(exchange_id, level) do
    {:error, {:unexpected_order_book_level, %{exchange: exchange_id, level: level}}}
  end

  defp extract_path_from_config(body, %{"key" => key}) when is_binary(key) do
    ResponseTransformer.extract_path(body, String.split(key, "."))
  end

  defp extract_path_from_config(body, _config), do: body

  # Read the candle list from its envelope key;
  # so a venue answering an empty window with the envelope key set to null
  # (Alpaca: `{"bars": null, ...}`, live-observed 2026-07-20) means "no candles",
  # not a shape error. Only a PRESENT-but-null key is empty — an absent key falls
  # through to extraction (which returns the non-list body) and stays loud.
  defp ohlcv_rows(body, %{"key" => key} = config) when is_map(body) and is_binary(key) do
    if key |> String.split(".") |> null_at_path?(body) do
      []
    else
      body |> extract_ohlcv_payload(config) |> maybe_transpose_columns(config)
    end
  end

  defp ohlcv_rows(body, config) do
    body |> extract_ohlcv_payload(config) |> maybe_transpose_columns(config)
  end

  defp null_at_path?([key], %{} = map), do: Map.has_key?(map, key) and is_nil(map[key])
  defp null_at_path?([key | rest], %{} = map), do: null_at_path?(rest, Map.get(map, key))
  defp null_at_path?(_path, _value), do: false

  # Authored columnar venues (deribit tradingview shape) carry "transform" +
  # "columns"; row-shaped venues omit it and the payload is already rows.
  defp maybe_transpose_columns(payload, %{"transform" => "transpose_columns", "columns" => cols}) when is_list(cols) do
    ResponseTransformer.transpose_columns_to_rows(payload, cols)
  end

  defp maybe_transpose_columns(payload, _config), do: payload

  defp normalize_ohlcv_order(rows, %{"order" => "newest_first"}), do: Enum.reverse(rows)
  defp normalize_ohlcv_order(rows, _config), do: rows

  # Coerce the six standard OHLCV positions to numeric values and ignore extras.
  # Hyperliquid candleSnapshot rows are objects keyed t/o/h/l/c/v (same six).
  defp coerce_ohlcv_row(row, %{"row_columns" => columns, "timestamp_unit" => "seconds"})
       when is_list(row) and is_list(columns) do
    values = Map.new(Enum.zip(columns, row))

    [
      values |> Map.get("timestamp") |> Bourse.Safe.integer() |> seconds_to_milliseconds(),
      Bourse.Safe.number(Map.get(values, "open")),
      Bourse.Safe.number(Map.get(values, "high")),
      Bourse.Safe.number(Map.get(values, "low")),
      Bourse.Safe.number(Map.get(values, "close")),
      Bourse.Safe.number(Map.get(values, "volume"))
    ]
  end

  # Any row_columns config falling past the clause above would silently be
  # read positionally as [ts, o, h, l, c, v] — mis-ordered OHLC, no error.
  defp coerce_ohlcv_row(_row, %{"row_columns" => _columns} = config) do
    raise ArgumentError,
          "authored ohlcv row_columns requires list rows and timestamp_unit \"seconds\"; " <>
            "got timestamp_unit #{inspect(Map.get(config, "timestamp_unit"))}"
  end

  defp coerce_ohlcv_row([ts, o, h, l, c, v | _], _config) do
    [
      ohlcv_timestamp(ts),
      Bourse.Safe.number(o),
      Bourse.Safe.number(h),
      Bourse.Safe.number(l),
      Bourse.Safe.number(c),
      Bourse.Safe.number(v)
    ]
  end

  # Derived price series carry no traded volume: bybit's index-, mark- and
  # premium-index klines publish exactly five columns, so the six-column clause
  # never matches and the row would otherwise reach the caller as raw strings.
  # https://bybit-exchange.github.io/docs/v5/market/index-kline
  defp coerce_ohlcv_row([ts, o, h, l, c], _config) do
    [
      ohlcv_timestamp(ts),
      Bourse.Safe.number(o),
      Bourse.Safe.number(h),
      Bourse.Safe.number(l),
      Bourse.Safe.number(c),
      nil
    ]
  end

  defp coerce_ohlcv_row(%{} = row, _config) do
    [
      ohlcv_timestamp(Map.get(row, "t")),
      Bourse.Safe.number(Map.get(row, "o")),
      Bourse.Safe.number(Map.get(row, "h")),
      Bourse.Safe.number(Map.get(row, "l")),
      Bourse.Safe.number(Map.get(row, "c")),
      Bourse.Safe.number(Map.get(row, "v"))
    ]
  end

  defp coerce_ohlcv_row(row, _config), do: row

  defp seconds_to_milliseconds(value) when is_integer(value), do: value * 1_000
  defp seconds_to_milliseconds(value), do: value

  defp ohlcv_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> Bourse.Safe.integer(value)
    end
  end

  defp ohlcv_timestamp(value), do: Bourse.Safe.integer(value)

  defp filter_ohlcv_by_since(rows, %{"since" => since}) when is_integer(since) do
    Enum.filter(rows, fn
      [ts | _] when is_integer(ts) -> ts >= since
      _ -> true
    end)
  end

  defp filter_ohlcv_by_since(rows, _params), do: rows

  # With since set, take from the start (oldest after
  # filter); without since, take the newest `limit` rows (tail).
  defp maybe_take_ohlcv_limit(rows, %{"limit" => limit} = params) when is_integer(limit) and limit >= 0 do
    if is_integer(params["since"]) do
      Enum.take(rows, limit)
    else
      Enum.take(rows, -limit)
    end
  end

  defp maybe_take_ohlcv_limit(rows, _params), do: rows

  # Volatility history coerces the timestamp and value and derives datetime from
  # the timestamp. An empty or missing result defaults to [].
  defp volatility_history_rows(body, module, js_name) do
    extracted = extract_envelope_payload(body, module, "volatility_history", js_name)

    cond do
      is_list(extracted) -> extracted
      match?(%{"result" => rows} when is_list(rows), body) -> body["result"]
      is_list(body) -> body
      true -> []
    end
  end

  defp coerce_volatility_history_row([ts, vol | _] = raw) do
    timestamp = Bourse.Safe.integer(ts)

    %VolatilityHistory{
      info: raw,
      timestamp: timestamp,
      datetime: Timestamp.iso8601_from_ms(timestamp),
      volatility: Bourse.Safe.number(vol)
    }
  end

  # Bybit publishes each volatility observation as an object keyed
  # `period`/`value`/`time`, not as the array-of-pairs deribit sends.
  # https://bybit-exchange.github.io/docs/v5/market/iv
  defp coerce_volatility_history_row(%{"time" => ts, "value" => value} = raw) do
    timestamp = Bourse.Safe.integer(ts)

    %VolatilityHistory{
      info: raw,
      timestamp: timestamp,
      datetime: Timestamp.iso8601_from_ms(timestamp),
      volatility: Bourse.Safe.number(value)
    }
  end

  defp coerce_volatility_history_row(raw) when is_list(raw) do
    %VolatilityHistory{info: raw, timestamp: nil, datetime: nil, volatility: nil}
  end

  defp coerce_volatility_history_row(_raw) do
    %VolatilityHistory{info: nil, timestamp: nil, datetime: nil, volatility: nil}
  end

  # The read path is a public consumer boundary: surface a `%Bourse.Error{}` rather
  # than leaking internal `{tag, raw}` tuples. Error envelopes already build one.
  defp normalize_error({:ok, _} = ok, _exchange, _method), do: ok
  defp normalize_error({:error, %Error{} = err}, _exchange, _method), do: {:error, err}

  defp normalize_error({:error, reason}, %Exchange{} = exchange, method) do
    message = "#{response_error_message(reason)} (method: #{method})"
    {:error, Error.exchange_error(message, exchange: exchange.id, raw: response_error_raw(reason))}
  end

  defp response_error_message({:empty_parse, _}), do: "Unexpected response shape: parsed to an all-nil struct"

  defp response_error_message({:unexpected_symbol_dict_shape, js_name, other}) do
    "Unexpected #{js_name} response shape: expected a list of rows to index by symbol, got #{parsed_shape_name(other)}"
  end

  defp response_error_message({:fundingless_symbol, symbol}) do
    "#{symbol} is fundingless; fetch_funding_rate requires a market that publishes funding"
  end

  defp response_error_message({:unservable_funding_symbol, symbol}) do
    "#{symbol} is not servable on this funding-rate surface"
  end

  defp response_error_message({:funding_symbol_mismatch, requested, answered}) do
    "fetch_funding_rate requested #{requested} but the venue answered for #{answered}"
  end

  defp response_error_message({:unexpected_response_shape, _}), do: "Unexpected response shape for unified parse"
  defp response_error_message({:no_field_map, _raw}), do: "No field map available for unified parse"

  defp response_error_message({:unexpected_order_book_level, %{exchange: exchange_id, level: level}}) do
    "Unexpected #{exchange_id} order book level; expected an authored shape that normalizes to " <>
      "[price, amount], got: #{inspect(level)}"
  end

  defp response_error_message({:missing_currency_field_map, exchange_id, nil}) do
    "Missing authored normalization.field_maps.currency slice for #{exchange_id}; " <>
      "fetchCurrencies cannot normalize currency rows (author the slice per docs/authored-specs.md)"
  end

  defp response_error_message({:missing_currency_field_map, exchange_id, reason}) do
    "Unresolved normalization.field_maps.currency slice for #{exchange_id}: #{reason}"
  end

  defp response_error_message({:unparsed_struct_rows, parse_type, module, bad}) do
    "Expected %#{inspect(module)}{} rows for #{parse_type} request-symbol backfill, " <>
      "got #{inspect(bad)}; missing authored normalization.field_maps.#{parse_type} slice?"
  end

  defp response_error_message({:unresolved_unified_symbol, details}) do
    "Cannot resolve unified symbol from venue-native #{inspect(details.native_symbol)} " <>
      "for #{details.exchange}; market family: #{inspect(details.market_type)}"
  end

  defp response_error_message({:unmapped_order_status, %{venue: venue, field: field, raw_value: raw_value}}) do
    "Unmapped authored order status for venue #{inspect(venue)}, field #{inspect(field)}, " <>
      "raw value #{inspect(raw_value)}"
  end

  defp response_error_message({:unmapped_ledger_type, %{venue: venue, field: field, raw_value: raw_value}}) do
    "Unmapped authored ledger type for venue #{inspect(venue)}, field #{inspect(field)}, " <>
      "raw value #{inspect(raw_value)}"
  end

  defp response_error_message(
         {:unmapped_order_type, %{venue: venue, product: product, field: field, raw_value: raw_value}}
       ) do
    "Unmapped Binance #{product} order type for venue #{inspect(venue)}, " <>
      "field #{inspect(field)}, raw value #{inspect(raw_value)}"
  end

  defp response_error_message(other), do: "Unified response parse failed: #{inspect(other)}"

  defp response_error_raw({:unmapped_order_status, details}), do: details
  defp response_error_raw({:unmapped_ledger_type, details}), do: details
  defp response_error_raw({:unmapped_order_type, details}), do: details
  defp response_error_raw({:unexpected_symbol_dict_shape, _js_name, parsed}), do: parsed
  defp response_error_raw({:fundingless_symbol, symbol}), do: %{reason: :fundingless_symbol, symbol: symbol}

  defp response_error_raw({:unservable_funding_symbol, symbol}), do: %{reason: :unservable_funding_symbol, symbol: symbol}

  defp response_error_raw({:funding_symbol_mismatch, requested, answered}),
    do: %{reason: :funding_symbol_mismatch, requested: requested, answered: answered}

  defp response_error_raw({_tag, raw}), do: raw
  defp response_error_raw(_other), do: nil

  defp parsed_shape_name(%{__struct__: module}), do: "%#{inspect(module)}{}"
  defp parsed_shape_name(other) when is_map(other), do: "map"
  defp parsed_shape_name(other), do: inspect(other)

  defp reject_error_envelope(body, %Exchange{} = exchange) when is_map(body) do
    if exchange_error?(body, exchange) do
      {:error, Error.exchange_error("Exchange error response", exchange: exchange.id, raw: body)}
    else
      :ok
    end
  end

  defp reject_error_envelope(_body, _exchange), do: :ok

  defp exchange_error?(body, %Exchange{error_code_fields: fields}) do
    jsonrpc_error?(body) or
      error_object?(body) or
      ret_code_error?(body) or
      code_error?(body) or
      truthy_error_code?(extract_error_code(body, fields))
  end

  # JSON-RPC error present means error; result without error is handled as success by absence of error.
  defp jsonrpc_error?(%{"error" => e}) when not is_nil(e), do: true
  defp jsonrpc_error?(_), do: false

  defp error_object?(%{"error" => error}), do: is_map(error)
  defp error_object?(_body), do: false

  defp ret_code_error?(%{"retCode" => code}), do: code not in [0, "0", nil]
  defp ret_code_error?(_body), do: false

  defp code_error?(%{"code" => code}), do: code not in @success_codes
  defp code_error?(_body), do: false

  defp truthy_error_code?(nil), do: false
  defp truthy_error_code?(code) when code in @success_codes, do: false
  defp truthy_error_code?(_code), do: true

  defp extract_error_code(body, fields) do
    Enum.find_value(fields, &Map.get(body, &1))
  end

  defp ensure_expected_shape(payload, true) when is_list(payload), do: {:ok, payload}
  defp ensure_expected_shape(payload, true) when is_map(payload), do: {:ok, payload}

  defp ensure_expected_shape(payload, true) do
    {:error, {:unexpected_response_shape, payload}}
  end

  defp ensure_expected_shape(payload, false) when is_map(payload) or is_list(payload), do: {:ok, payload}

  defp ensure_expected_shape(payload, false) do
    {:error, {:unexpected_response_shape, payload}}
  end

  # Stamp a route identity onto every row so `kind: when` guards survive
  # list reads that have no request-context market.
  defp annotate_endpoint_route(payload, %{"_bourse_endpoint_id" => id}) when is_binary(id) do
    stamp_endpoint_id(payload, id)
  end

  defp annotate_endpoint_route(payload, %{"_bourse_endpoint_route" => route}) when is_binary(route) do
    stamp_endpoint_route(payload, route)
  end

  defp annotate_endpoint_route(payload, _params), do: payload

  defp stamp_endpoint_id(rows, id) when is_list(rows), do: Enum.map(rows, &stamp_endpoint_id(&1, id))

  defp stamp_endpoint_id(row, id) when is_map(row), do: Map.put_new(row, "_bourse_endpoint_id", id)

  defp stamp_endpoint_id(payload, _id), do: payload

  defp stamp_endpoint_route(rows, route) when is_list(rows), do: Enum.map(rows, &stamp_endpoint_route(&1, route))

  defp stamp_endpoint_route(row, route) when is_map(row), do: Map.put_new(row, "_bourse_endpoint_route", route)

  defp stamp_endpoint_route(payload, _route), do: payload

  # Must stay a keyword list: generated parsers hand this straight to
  # `Bourse.Parser.parse/4`, which reads it with `Keyword.get/3`.
  defp build_parse_opts(exchange, params, _payload, _list_return?) do
    route_opts =
      case Map.get(params, "_bourse_endpoint_route") do
        route when is_binary(route) -> [route: route]
        _route -> []
      end

    symbol_opts =
      case Map.get(params, "symbol") do
        nil -> []
        symbol -> [symbol: symbol, market: market_context(exchange, symbol)]
      end

    route_opts ++ symbol_opts ++ network_opts(exchange)
  end

  defp network_opts(%Exchange{} = exchange) do
    [
      venue: exchange.id,
      currencies: exchange.currencies,
      common_currencies: exchange.common_currencies,
      options: Map.merge(exchange.network_options, exchange.options)
    ]
  end

  defp network_context(%Exchange{} = exchange), do: Map.new(network_opts(exchange))

  defp market_context(%Exchange{markets: markets}, symbol) when is_list(markets) do
    case Enum.find(markets, &(market_symbol(&1) == symbol)) do
      nil -> fallback_market_context(symbol)
      market -> market
    end
  end

  defp market_context(_exchange, symbol), do: fallback_market_context(symbol)

  defp market_symbol(%{symbol: symbol}) when is_binary(symbol), do: symbol
  defp market_symbol(%{"symbol" => symbol}) when is_binary(symbol), do: symbol
  defp market_symbol(_market), do: nil

  defp fallback_market_context(symbol) do
    inverse? = inverse_symbol?(symbol)
    option? = option_symbol?(symbol)
    %{inverse: inverse?, linear: not inverse?, option: option?}
  end

  defp option_symbol?(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, parsed} -> Symbol.detect_market_type(parsed) == :option
      {:error, :invalid_format} -> false
    end
  end

  defp enrich_deposit_address(%Bourse.DepositAddress{} = address, exchange, "deposit_address", params) do
    code = Map.get(params, "code")
    currency = address.currency || code
    network = address.network || deposit_address_network(exchange.currencies, currency, address.info)
    %{address | currency: currency, network: network}
  end

  defp enrich_deposit_address(addresses, exchange, "deposit_address", params) when is_list(addresses) do
    Enum.map(addresses, &enrich_deposit_address(&1, exchange, "deposit_address", params))
  end

  defp enrich_deposit_address(addresses, exchange, "deposit_address", params)
       when is_map(addresses) and not is_struct(addresses) do
    Map.new(addresses, fn {network, address} ->
      {network, enrich_deposit_address(address, exchange, "deposit_address", params)}
    end)
  end

  defp enrich_deposit_address(parsed, _exchange, _parse_type, _params), do: parsed

  # The deposit payload carries only an explorer
  # url, so the network is recovered by matching that url against the currency's
  # per-network `contractAddressUrl`. The match is on the BASE DOMAIN of the
  # catalog url (`getBaseDomainFromUrl` -> "scheme://host/"), NOT the full url —
  # the two urls routinely differ past the host (USDT TRC20 catalogs
  # `tronscan.org/#/token20/` while a deposit url reads `tronscan.org/#/address/`).
  defp deposit_address_network(currencies, code, %{"url" => url})
       when is_map(currencies) and is_binary(code) and is_binary(url) do
    currencies
    |> Map.get(String.upcase(code), %{})
    |> Map.get("networks", %{})
    |> Enum.find_value(fn {network, metadata} ->
      with contract_url when is_binary(contract_url) <- get_in(metadata, ["info", "contractAddressUrl"]),
           base_domain when is_binary(base_domain) <- base_domain_from_url(contract_url),
           true <- String.starts_with?(url, base_domain) do
        network
      else
        _ -> nil
      end
    end)
  end

  defp deposit_address_network(_currencies, _code, _info), do: nil

  # Take the first network whose explorer base domain matches. Authored network
  # data must keep those domains unique per currency; the recorded caches have no
  # collisions, and the invariant is pinned by test.
  defp base_domain_from_url(url) do
    case String.split(url, "/") do
      [scheme, "", host | _] when scheme != "" and host != "" -> scheme <> "//" <> host <> "/"
      _ -> nil
    end
  end

  defp inverse_symbol?(symbol) when is_binary(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, parsed} -> parsed.settle == parsed.base and parsed.settle != parsed.quote
      _ -> false
    end
  end

  defp inverse_symbol?(_symbol), do: false

  defp invoke_parser(module, parser, data, parse_opts) do
    case apply(module, parser, [data, parse_opts]) do
      {:error, {:unresolved, _reason}} ->
        retry_without_unresolved(module, parser, data, parse_opts)

      {:error, :no_field_map} ->
        {:error, {:no_field_map, data}}

      {:ok, parsed} ->
        {:ok, parsed}

      {:error, _} = error ->
        error
    end
  end

  defp retry_without_unresolved(module, parser, data, parse_opts) do
    slot = Map.fetch!(@parser_slots, parser)
    mapping = module.__field_maps__()[slot]

    case mapping do
      %{} = map ->
        stripped = Map.delete(map, "_unresolved_reason")
        target = FieldMaps.struct_for(slot)
        Parser.parse(data, stripped, target, parse_opts)

      _ ->
        {:error, :no_field_map}
    end
  end

  defp backfill_request_symbols(%{__struct__: Ticker} = ticker, params, "ticker", false) do
    # A single-symbol ticker is scoped by the requested market; the request symbol is
    # the authority when venue ids collide across spot/derivative markets.
    {:ok, %{ticker | symbol: requested_symbol(params, ticker.symbol)}}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.Order} = order, params, "order", false) do
    # Single-order reads are scoped by the requested market; prefer it over a
    # native id guess so request filtering cannot drop the row. Create-order
    # filled acks (Hyperliquid statuses[].filled) carry no coin; leave
    # symbol nil rather than stamping the request symbol (createOrder fixtures).
    if hyperliquid_create_order_ack?(order) do
      {:ok, order}
    else
      {:ok, %{order | symbol: requested_symbol(params, order.symbol)}}
    end
  end

  # TradingFee is single-market; stamp request symbol when the venue body has none.
  defp backfill_request_symbols(%{__struct__: Bourse.TradingFee} = fee, params, "trading_fee", false) do
    {:ok, %{fee | symbol: requested_symbol(params, fee.symbol)}}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.Trade} = trade, params, "trade", false) do
    # Trades already follow request authority; keep this path explicit because
    # trade ids commonly omit enough market context to disambiguate native ids.
    {:ok, backfill_trade_symbol(trade, params)}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.OpenInterest} = oi, params, "open_interest", false) do
    # Open-interest endpoints are single-market reads; the requested symbol is
    # more specific than reverse-parsing a venue id like Bybit `BTCUSDT`.
    {:ok, %{oi | symbol: requested_symbol(params, oi.symbol)}}
  end

  defp backfill_request_symbols(interests, params, "open_interest", true) when is_list(interests) do
    {:ok, Enum.map(interests, &%{&1 | symbol: requested_symbol(params, &1.symbol)})}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.Position} = position, params, "position", false) do
    # Single-position reads are scoped by the request market; use that market
    # when present instead of preserving an ambiguous native-id backfill.
    {:ok, %{position | symbol: requested_symbol(params, position.symbol)}}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.ADLRank} = rank, params, "adl_rank", false) do
    # Single ADL-rank reads are symbol-scoped; request authority prevents the
    # final symbol filter from rejecting an otherwise valid rank row.
    {:ok, %{rank | symbol: requested_symbol(params, rank.symbol)}}
  end

  defp backfill_request_symbols(ranks, params, "adl_rank", true) when is_list(ranks) do
    # List ADL-rank reads keep native symbols unless the caller made a singular
    # symbol request; multi-symbol/symbol-less reads are out of request authority.
    {:ok, Enum.map(ranks, &%{&1 | symbol: requested_symbol(params, &1.symbol)})}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.FundingRate} = fr, params, "funding_rate", false) do
    # The venue-answered market is the identity. Stamping the requested
    # unified symbol would re-label a linear perp row as the spot pair that
    # shares its compact id (task 646).
    case funding_rate_identity(params, fr.symbol) do
      {:ok, symbol} -> {:ok, %{fr | symbol: symbol}}
      {:error, _} = error -> error
    end
  end

  defp backfill_request_symbols(%{__struct__: Bourse.BorrowRate} = rate, params, "borrow_rate", false) do
    currency = rate.currency || params["code"] || params["ccy"] || params["currency"]
    {:ok, %{rate | currency: currency}}
  end

  defp backfill_request_symbols(rates, params, "borrow_rate", true) when is_list(rates) do
    currency = params["code"] || params["ccy"] || params["currency"]

    {:ok,
     Enum.map(rates, fn
       %{__struct__: Bourse.BorrowRate, currency: nil} = rate when is_binary(currency) ->
         %{rate | currency: currency}

       rate ->
         rate
     end)}
  end

  # fetchFundingRates returns a list that is later re-keyed by symbol.
  defp backfill_request_symbols([], params, "funding_rate", false) do
    symbol = params["symbol"]

    if fundingless_symbol?(symbol) do
      {:error, {:fundingless_symbol, symbol}}
    else
      {:error, {:unservable_funding_symbol, symbol}}
    end
  end

  defp backfill_request_symbols(rates, params, "funding_rate", true) when is_list(rates) do
    # Multi-symbol funding-rates reads must keep native symbols for indexing;
    # only a singular requested symbol may fill a nil row, and never overwrite
    # a different answered market.
    {:ok, Enum.map(rates, &%{&1 | symbol: keep_answered_funding_symbol(params, &1.symbol)})}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.FundingRateHistory} = fr, params, "funding_rate_history", false) do
    # Single funding-history rows are requested for one market; preserve that
    # request context over ambiguous venue ids.
    {:ok, %{fr | symbol: requested_symbol(params, fr.symbol)}}
  end

  defp backfill_request_symbols(history, params, "funding_rate_history", true) when is_list(history) do
    # History list reads keep native symbols unless a singular request symbol is
    # present.
    {:ok, Enum.map(history, &%{&1 | symbol: requested_symbol(params, &1.symbol)})}
  end

  defp backfill_request_symbols(history, params, "funding_history", true) when is_list(history) do
    # Funding income history can be symbol-scoped; singular request context wins,
    # while symbol-less account history keeps native symbols.
    # Fail loud when rows never became structs (unauthored field map soft-passed
    # raw maps through invoke_parser) — bare %{map | symbol: ...} raises KeyError.
    with :ok <- require_struct_rows(history, Bourse.FundingHistory, "funding_history") do
      {:ok, Enum.map(history, &%{&1 | symbol: requested_symbol(params, &1.symbol)})}
    end
  end

  defp backfill_request_symbols(%{__struct__: Bourse.Greeks} = greeks, params, "greeks", false) do
    # Single greeks reads are for one option market, so request authority is the
    # safest disambiguator when the native id parser guessed a different market.
    {:ok, %{greeks | symbol: requested_symbol(params, greeks.symbol)}}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.OptionData} = option, params, "option", false) do
    # Single option reads are market-scoped; request symbol wins over a native
    # instrument_name/instId reverse parse when both are present.
    {:ok, %{option | symbol: requested_symbol(params, option.symbol)}}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.Leverage} = leverage, params, "leverage", false) do
    # Leverage is always requested for one market; stamp request symbol when the
    # venue row only carries a native id (or omits it after a multi-row merge).
    {:ok, %{leverage | symbol: requested_symbol(params, leverage.symbol)}}
  end

  # fetchAllGreeks returns a list before indexing; each row may still lack a
  # request symbol when the venue echoes only a native option id.
  defp backfill_request_symbols(greeks, params, "greeks", true) when is_list(greeks) do
    # The one clause that KEEPS native precedence: fetchAllGreeks is a
    # baseCoin-scoped multi-option read whose rows are re-keyed by symbol
    # (index_all_greeks/2). A native option id carries full expiry/strike/type
    # context, so it is never the ambiguous guess the other clauses defend
    # against — while stamping a requested symbol over every row would collapse
    # the whole option chain onto one key. Request symbols only fill nil rows.
    symbols = List.wrap(params["symbols"])

    {:ok,
     Enum.map(greeks, fn greek ->
       %{greek | symbol: requested_symbol_or_first(params, symbols, greek.symbol)}
     end)}
  end

  defp backfill_request_symbols(%{__struct__: Bourse.MarginMode} = mode, params, "margin_mode", false) do
    # Margin mode is requested for a specific market; request context wins over
    # any native backfill, which is often absent for account-level responses.
    {:ok, %{mode | symbol: requested_symbol(params, mode.symbol)}}
  end

  # Hyperliquid transfer ack has no TransferEntry-shaped payload — echo the
  # caller's currency/amount/from/to and derive status from the venue ack.
  # Authority: Hyperliquid exchange endpoint returns
  # `{'status': 'ok', 'response': {'type': 'default'}}` for class/sub transfers
  # (https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint).
  defp backfill_request_symbols(%{__struct__: Bourse.TransferEntry} = entry, params, "transfer", false) do
    {:ok,
     entry
     |> put_if_nil(:currency, transfer_code(params))
     |> put_if_nil(:amount, transfer_amount(params))
     |> put_if_nil(:from_account, transfer_account(params, "from_account", "fromAccount"))
     |> put_if_nil(:to_account, transfer_account(params, "to_account", "toAccount"))
     |> put_transfer_status_from_ack()}
  end

  # Bybit repayCrossMargin echoes only `{resultStatus: "SU"}`; backfill the
  # parsed margin loan with the request currency/amount. Borrow carries coin+amount
  # on the wire, but currency still falls back to the request code.
  defp backfill_request_symbols(%{__struct__: Bourse.MarginLoan} = loan, params, "margin_loan", false) do
    amount =
      cond do
        not is_nil(loan.amount) -> loan.amount
        Map.has_key?(params, "amount") -> params["amount"]
        true -> nil
      end

    {:ok,
     %{
       loan
       | currency: loan.currency || params["code"],
         amount: amount,
         # Margin-loan responses are request-scoped when a symbol exists; use it
         # explicitly instead of native precedence.
         symbol: requested_symbol(params, loan.symbol)
     }}
  end

  defp backfill_request_symbols(parsed, params, "trade", true) when is_list(parsed) do
    # Default: stamp the request symbol so native-id collisions across market
    # types still pass the final symbol filter (okx public trades fixtures).
    # Hyperliquid userFills mix coins — keep coin-derived symbols so the filter
    # drops other markets before limit (stamping would keep every fill).
    {:ok, Enum.map(parsed, &backfill_trade_symbol_for_list(&1, params))}
  end

  defp backfill_request_symbols(orders, params, "order", true) when is_list(orders) do
    # Open-order list reads may be scoped to one requested symbol; that request
    # context must beat ambiguous native-id guesses before filtering.
    {:ok, Enum.map(orders, &%{&1 | symbol: requested_symbol(params, &1.symbol)})}
  end

  defp backfill_request_symbols(rows, params, "long_short_ratio", true) when is_list(rows) do
    # Account-ratio rows echo native `BTCUSDT`; stamp the unified request symbol
    # (and optional timeframe) so the post-parse symbol filter cannot empty the list.
    # Bybit request shape defaults period to "1d" when the caller omits timeframe.
    timeframe = params["timeframe"] || params["period"] || "1d"

    {:ok,
     Enum.map(rows, fn
       %{__struct__: Bourse.LongShortRatio} = row ->
         %{
           row
           | symbol: requested_symbol(params, row.symbol),
             timeframe: row.timeframe || timeframe
         }

       other ->
         other
     end)}
  end

  defp backfill_request_symbols(rows, params, "liquidation", true) when is_list(rows) do
    {:ok, Enum.map(rows, &backfill_liquidation_symbol(&1, params))}
  end

  defp backfill_request_symbols(rows, params, "leverage_tiers", true) when is_list(rows) do
    {:ok, Enum.map(rows, &backfill_leverage_tier_symbol(&1, params))}
  end

  defp backfill_request_symbols(addresses, params, "deposit_address", _list_return?) when is_list(addresses) do
    code = params["code"] || params["coin"]

    {:ok,
     Enum.map(addresses, fn
       %{__struct__: Bourse.DepositAddress} = addr when is_binary(code) ->
         %{addr | currency: addr.currency || code}

       other ->
         other
     end)}
  end

  defp backfill_request_symbols(address_map, params, "deposit_address", _list_return?)
       when is_map(address_map) and not is_struct(address_map) do
    code = params["code"] || params["coin"]

    {:ok,
     Map.new(address_map, fn
       {network, %{__struct__: Bourse.DepositAddress} = addr} when is_binary(code) ->
         {network, %{addr | currency: addr.currency || code}}

       other ->
         other
     end)}
  end

  defp backfill_request_symbols(parsed, _params, _parse_type, _list_return?) do
    {:ok, parsed}
  end

  # Raw maps reaching a struct-update backfill mean the field map was missing and
  # invoke_parser soft-returned the wire payload. Name the venue slice instead of
  # raising bare `key :symbol not found` (task 321).
  defp require_struct_rows(rows, module, parse_type) when is_list(rows) do
    case Enum.find(rows, &(not match?(%{__struct__: ^module}, &1))) do
      nil ->
        :ok

      bad ->
        {:error, {:unparsed_struct_rows, parse_type, module, bad}}
    end
  end

  defp backfill_liquidation_symbol(%{__struct__: Bourse.Liquidation} = row, params) do
    %{row | symbol: requested_symbol(params, row.symbol)}
  end

  defp backfill_liquidation_symbol(other, _params), do: other

  defp backfill_leverage_tier_symbol(%{__struct__: Bourse.LeverageTier} = row, params) do
    %{row | symbol: requested_symbol(params, row.symbol)}
  end

  defp backfill_leverage_tier_symbol(other, _params), do: other

  defp requested_symbol(%{"symbol" => symbol}, native_symbol) when is_binary(symbol) do
    if unified_symbol?(symbol), do: symbol, else: native_symbol
  end

  defp requested_symbol(_params, native_symbol), do: native_symbol

  defp funding_rate_identity(params, parsed_symbol) do
    requested = params["symbol"]

    cond do
      fundingless_symbol?(requested) ->
        {:error, {:fundingless_symbol, requested}}

      funding_symbol_mismatch?(requested, parsed_symbol) ->
        {:error, {:funding_symbol_mismatch, requested, parsed_symbol}}

      true ->
        {:ok, choose_funding_symbol(requested, parsed_symbol)}
    end
  end

  defp funding_symbol_mismatch?(requested, parsed_symbol) do
    unified_symbol?(requested) and unified_symbol?(parsed_symbol) and requested != parsed_symbol
  end

  defp choose_funding_symbol(requested, parsed_symbol) do
    cond do
      unified_symbol?(requested) and not unified_symbol?(parsed_symbol) -> requested
      is_binary(parsed_symbol) and parsed_symbol != "" -> parsed_symbol
      is_binary(requested) -> requested
      true -> parsed_symbol
    end
  end

  defp keep_answered_funding_symbol(params, parsed_symbol) do
    requested = params["symbol"]

    cond do
      unified_symbol?(parsed_symbol) -> parsed_symbol
      unified_symbol?(requested) and not fundingless_symbol?(requested) -> requested
      true -> parsed_symbol
    end
  end

  defp fundingless_symbol?(symbol) when is_binary(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, parsed} -> Symbol.detect_market_type(parsed) == :spot
      {:error, _reason} -> false
    end
  end

  defp fundingless_symbol?(_symbol), do: false

  defp put_if_nil(struct, field, value) do
    case Map.get(struct, field) do
      nil when not is_nil(value) -> Map.put(struct, field, value)
      _ -> struct
    end
  end

  defp transfer_code(params), do: params["code"] || params["currency"]

  defp transfer_amount(params) do
    case params["amount"] do
      amount when is_number(amount) or is_binary(amount) -> amount
      _ -> nil
    end
  end

  defp transfer_account(params, snake, camel) do
    params[snake] || params[camel]
  end

  # Venue ack: %{"status" => "ok", "response" => %{"type" => "default"}}.
  # Also accept a field-mapped status already present on the struct.
  defp put_transfer_status_from_ack(%{status: status} = entry) when is_binary(status) and status != "", do: entry

  defp put_transfer_status_from_ack(%{info: %{"status" => status}} = entry) when is_binary(status) and status != "" do
    %{entry | status: status}
  end

  defp put_transfer_status_from_ack(entry), do: entry

  defp requested_symbol_or_first(_params, _symbols, native_symbol) when is_binary(native_symbol), do: native_symbol
  defp requested_symbol_or_first(params, symbols, _native_symbol), do: List.first(symbols) || params["symbol"]

  # Bybit `parseIncome` defaults settle currency to USDT for linear and uses the
  # market quote for inverse. Derive from the unified symbol once it is known.
  defp put_funding_history_codes(history) when is_list(history) do
    Enum.map(history, &put_funding_history_code/1)
  end

  defp put_funding_history_codes(other), do: other

  defp put_funding_history_code(%{__struct__: Bourse.FundingHistory, code: nil, symbol: symbol} = entry)
       when is_binary(symbol) do
    %{entry | code: funding_history_code(symbol)}
  end

  defp put_funding_history_code(entry), do: entry

  defp funding_history_code(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, %{settle: settle} = market} when is_binary(settle) and settle != "" ->
        if settle == market.base and settle != market.quote and is_binary(market.quote) do
          # Inverse contracts settle in base but report funding in quote
          # (for example USD for BTC/USD:BTC).
          market.quote
        else
          settle
        end

      _ ->
        "USDT"
    end
  end

  defp backfill_market_symbols(%{__struct__: Bourse.Market} = market, exchange, "market", raw, false) do
    {:ok, backfill_market_symbol(market, exchange, raw)}
  end

  defp backfill_market_symbols(parsed, exchange, "market", raw_list, true) when is_list(parsed) do
    raw_list = List.wrap(raw_list)

    parsed
    |> Enum.zip(raw_list)
    |> Enum.map(fn {market, raw} -> backfill_market_symbol(market, exchange, raw) end)
    |> then(&{:ok, &1})
  end

  defp backfill_market_symbols(parsed, _exchange, _parse_type, _payload, _list_return?) do
    {:ok, parsed}
  end

  defp backfill_trade_symbol(%{__struct__: Bourse.Trade} = trade, params) do
    case params["symbol"] do
      symbol when is_binary(symbol) -> %{trade | symbol: symbol}
      _ -> trade
    end
  end

  # Hyperliquid fills carry `coin` in info; preserve the resolved symbol so a
  # singular request symbol does not re-label every fill before the filter.
  defp backfill_trade_symbol_for_list(
         %{__struct__: Bourse.Trade, symbol: existing, info: %{"coin" => _}} = trade,
         _params
       )
       when is_binary(existing) and existing != "", do: trade

  # Alpaca FILL rows already carry the unified ticker. Stamping the request
  # symbol would relabel every fill and defeat the post-parse filter (C-T547a).
  defp backfill_trade_symbol_for_list(
         %{__struct__: Bourse.Trade, symbol: existing, info: %{"activity_type" => _}} = trade,
         _params
       )
       when is_binary(existing) and existing != "", do: trade

  defp backfill_trade_symbol_for_list(trade, params), do: backfill_trade_symbol(trade, params)

  defp backfill_market_symbol(%{__struct__: Bourse.Market} = market, exchange, raw) when is_map(raw) do
    type = market.type || market_type_from_raw(raw)

    symbol =
      market.symbol ||
        market_symbol_from_raw(raw, exchange, market_type_atom(type)) ||
        market_symbol_from_components(market)

    market =
      market
      |> Map.put(:symbol, symbol)
      |> Map.put(:type, type)
      |> backfill_lighter_market(exchange, raw)
      |> reconcile_deribit_future_flag(exchange, type)
      # Type-boolean flags (spot/swap/contract/linear/…) are mechanical once `type`
      # (and settle/base/quote for linear/inverse) are known. Fill only when the
      # field-map left them nil so venue-authored enum maps (bybit/okx/deribit) win.
      |> derive_market_type_flags()
      |> reconcile_deribit_inverse_flag(exchange, raw)
      |> OptionQuantity.normalize_market(raw, exchange)
      |> ContractUnit.normalize_market(raw, exchange)
      # Public maker/taker come from the venue's published fee schedule once market
      # family is known; Binance exchangeInfo has no fee fields.
      |> apply_static_trading_fees(exchange)
      |> backfill_expiry_datetime()

    if market.swap do
      %{market | expiry: nil, expiry_datetime: nil}
    else
      market
    end
  end

  # Spot/swap market fan-outs can still hand a non-map residual (e.g. a stray ctx
  # list element) after envelope unwrap. Never crash — keep the market as-is.
  defp backfill_market_symbol(%{__struct__: Bourse.Market} = market, _exchange, _raw), do: market

  # Mechanical type → boolean flags. Authored field-map values always win (`put_new`).
  # linear/inverse follow settlement direction: settle==quote → linear, settle==base → inverse.
  defp derive_market_type_flags(%{type: type} = market) when is_binary(type) do
    contract? = type in ["swap", "future", "option"]
    {linear, inverse} = settlement_direction_flags(market, contract?)

    market
    |> put_new_market_flag(:spot, type == "spot")
    |> put_new_market_flag(:swap, type == "swap")
    |> put_new_market_flag(:future, type == "future")
    |> put_new_market_flag(:option, type == "option")
    |> put_new_market_flag(:contract, contract?)
    |> put_new_market_flag(:linear, linear)
    |> put_new_market_flag(:inverse, inverse)
  end

  defp derive_market_type_flags(market), do: market

  # Fill nil maker/taker/percentage/tier_based from the venue's own authored fee
  # schedule once type flags are known. Response-derived fee fields always win.
  #
  # The trigger is the authored `fees.static_market_fees` opt-in, never a venue-id
  # list: a venue whose owned spec declares the flag takes effect with no change
  # here. Presence of a `fees.trading` block is deliberately NOT the signal — every
  # owned spec carries one as mechanical CCXT-projected reference bulk, so inferring from it
  # would publish rates nobody confronted against the venue's own schedule.
  defp apply_static_trading_fees(%{__struct__: Bourse.Market} = market, %Exchange{
         fees: %{static_market_fees: true} = fees
       }) do
    case static_trading_fee_block(market, fees) do
      %{maker: _, taker: _} = block ->
        market
        |> put_new_market_flag(:maker, block.maker)
        |> put_new_market_flag(:taker, block.taker)
        |> put_new_market_flag(:percentage, block.percentage)
        |> put_new_market_flag(:tier_based, block.tier_based)

      _ ->
        market
    end
  end

  defp apply_static_trading_fees(market, _exchange), do: market

  defp backfill_lighter_market(market, %Exchange{id: "lighter"}, raw) do
    base = market.base || Map.get(raw, "symbol")
    quote = market.quote || "USDC"
    settle = market.settle || if(market.type == "swap", do: quote)

    market
    |> put_new_market_flag(:base, base)
    |> put_new_market_flag(:base_id, base)
    |> put_new_market_flag(:quote, quote)
    |> put_new_market_flag(:quote_id, quote)
    |> put_new_market_flag(:settle, settle)
    |> put_new_market_flag(:settle_id, settle)
    |> put_new_market_flag(:active, Map.get(raw, "status") == "active")
    |> put_new_market_flag(:contract_size, Map.get(raw, "quote_multiplier"))
  end

  defp backfill_lighter_market(market, _exchange, _raw), do: market

  defp static_trading_fee_block(market, fees) do
    cond do
      market.inverse == true -> trading_fee_block(fees[:inverse] || fees["inverse"])
      market.linear == true -> trading_fee_block(fees[:linear] || fees["linear"])
      market.option == true -> trading_fee_block(fees[:option] || fees["option"]) || trading_fee_block(fees)
      true -> trading_fee_block(fees)
    end
  end

  defp trading_fee_block(%{trading: trading}) when is_map(trading), do: trading_fee_fields(trading)
  defp trading_fee_block(%{"trading" => trading}) when is_map(trading), do: trading_fee_fields(trading)
  defp trading_fee_block(fees) when is_map(fees), do: trading_fee_fields(fees[:trading] || fees["trading"] || fees)
  defp trading_fee_block(_), do: nil

  defp trading_fee_fields(trading) when is_map(trading) do
    maker = first_present(trading, [:maker, "maker"])
    taker = first_present(trading, [:taker, "taker"])

    if is_nil(maker) and is_nil(taker) do
      nil
    else
      %{
        maker: maker,
        taker: taker,
        # boolean false is a real value — do not use `||` (it drops false).
        percentage: first_present(trading, [:percentage, "percentage"]),
        tier_based: first_present(trading, [:tier_based, "tierBased", :tierBased])
      }
    end
  end

  defp trading_fee_fields(_), do: nil

  defp first_present(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp put_new_market_flag(market, key, value) do
    if is_nil(Map.get(market, key)), do: Map.put(market, key, value), else: market
  end

  defp settlement_direction_flags(_market, false), do: {false, false}

  defp settlement_direction_flags(market, true) do
    settle = Map.get(market, :settle)

    cond do
      not (is_binary(settle) and settle != "") -> {nil, nil}
      settle == Map.get(market, :quote) -> {true, false}
      settle == Map.get(market, :base) -> {false, true}
      true -> {nil, nil}
    end
  end

  # Deribit's authored `future` field-map keys on `settlement_period`, which cannot express the
  # flag's actual definition: settlement_period is day/week/month for options too, and carries no
  # future-vs-option signal. The resolved market type does, so it — not the raw
  # period — decides.
  defp reconcile_deribit_future_flag(market, %Exchange{id: "deribit"}, type) do
    %{market | future: type == "future"}
  end

  defp reconcile_deribit_future_flag(market, _exchange, _type), do: market

  # Inverse is one source of truth: the id classifier. Authored
  # `instrument_type: reversed` would otherwise mark BTC options and option
  # combos inverse, and `amount / price` on those rows is a squared money error
  # (carve C-T626). A name the classifier cannot positively identify as the
  # inverse book stays false — the mul identity.
  defp reconcile_deribit_inverse_flag(market, %Exchange{id: "deribit"}, %{"instrument_name" => name})
       when is_binary(name) do
    %{market | inverse: deribit_inverse_instrument_id?(name)}
  end

  defp reconcile_deribit_inverse_flag(market, _exchange, _raw), do: market

  defp backfill_expiry_datetime(%{expiry: expiry, expiry_datetime: nil} = market) when is_integer(expiry) do
    %{market | expiry_datetime: Timestamp.iso8601_from_ms(expiry)}
  end

  defp backfill_expiry_datetime(market), do: market

  # Prefer field-map-populated base/quote/settle (authored keys) over exchange-id reverse
  # patterns. Only when settle is present: inverse perps settle in base (BTC/USD:BTC),
  # linear in quote (BTC/USDT:USDT). Spot has no settle and stays on the id/pattern path
  # (BTC/USDT). Building from base+quote alone would collapse option ids like
  # BTC-251226-90000-C into BTC/USDT. Pattern reverse of BTCUSD_PERP through the
  # spot/implicit-swap config yields a trailing-slash form — settle-aware build avoids it.
  defp market_symbol_from_components(%{base: base, quote: quote, settle: settle})
       when is_binary(base) and is_binary(quote) and is_binary(settle) do
    if base != "" and quote != "" and settle != "" do
      Symbol.build(base, quote, settle)
    end
  end

  defp market_symbol_from_components(_market), do: nil

  # Deribit combo ids name multi-leg strategies, not a single base/quote instrument (carve C27).
  # They keep their native ids because the unified symbol grammar cannot represent leg
  # structure — and because the option grammar would rewrite a linear combo's `d`-encoded
  # strikes (DOGE_USDC-CS-28AUG26-0d1184_0d12 -> ...-0D1184_0D12).
  defp market_symbol_from_raw(%{"instrument_name" => id, "kind" => kind}, _exchange, _type)
       when is_binary(id) and kind in ["future_combo", "option_combo"], do: id

  defp market_symbol_from_raw(%{"instrument_name" => id} = raw, exchange, _type) when is_binary(id) do
    Symbol.from_exchange_id(id, exchange, deribit_market_type(raw))
  end

  defp market_symbol_from_raw(%{"name" => name, "maxLeverage" => _} = raw, exchange, _type) when is_binary(name) do
    hyperliquid_market_symbol(name, raw, exchange)
  end

  # Hyperliquid spot rows (tokens[]) and annotated swap rows without maxLeverage.
  defp market_symbol_from_raw(%{"_bourse_type" => "spot"} = raw, exchange, _type) do
    hyperliquid_spot_symbol(raw, exchange)
  end

  defp market_symbol_from_raw(%{"_bourse_type" => "swap", "name" => name} = raw, exchange, _type) when is_binary(name) do
    hyperliquid_market_symbol(name, raw, exchange)
  end

  defp market_symbol_from_raw(%{"tokens" => tokens, "name" => name} = raw, exchange, _type)
       when is_list(tokens) and is_binary(name) do
    hyperliquid_spot_symbol(raw, exchange)
  end

  defp market_symbol_from_raw(%{"baseCoin" => base, "quoteCoin" => quote} = raw, exchange, _type)
       when is_binary(base) and is_binary(quote) do
    bybit_market_symbol(base, quote, raw, exchange)
  end

  defp market_symbol_from_raw(%{"symbol" => sym, "market_type" => _} = raw, exchange, _type) when is_binary(sym) do
    lighter_market_symbol(sym, raw, exchange)
  end

  # Contract markets that expose marginAsset (settle). Must win over bare `symbol` so
  # coin-margined ids are not mis-reversed through the spot pattern (BTCUSD_PERP/).
  defp market_symbol_from_raw(
         %{"symbol" => id, "baseAsset" => base, "quoteAsset" => quote, "marginAsset" => settle},
         exchange,
         _type
       )
       when is_binary(base) and is_binary(quote) and is_binary(settle) and settle != "" do
    binance_contract_symbol(id, exchange) ||
      Symbol.build(
        market_currency_code(base, exchange),
        market_currency_code(quote, exchange),
        market_currency_code(settle, exchange)
      )
  end

  # Rows that report their own instrument identity alongside a compact id. The id
  # grammar wins whenever it resolves, and structured ids (options
  # `BTC-251226-90000-C`, dated futures) pass through untouched — their type context is
  # not expressible as a base/quote pair. Only a SEPARATOR-LESS id that the grammar
  # failed to split defers to the exchange-reported pair: binance spot ids are
  # BASE+QUOTE concatenated, so the boundary is unrecoverable by pattern and every
  # non-USDT/USDC/BTC quote lands here (1116/5966 raw symbols live 2026-07-19). The
  # split itself is always the venue's own `baseAsset`/`quoteAsset`, never a guess.
  defp market_symbol_from_raw(%{"symbol" => id, "baseAsset" => base, "quoteAsset" => quote}, exchange, type)
       when is_binary(id) and is_atom(type) and is_binary(base) and is_binary(quote) do
    unified = Symbol.from_exchange_id(id, exchange, type)

    if String.contains?(unified, "/") or String.contains?(id, ["-", "_", "/", "."]) do
      unified
    else
      Symbol.build(market_currency_code(base, exchange), market_currency_code(quote, exchange))
    end
  end

  defp market_symbol_from_raw(%{"symbol" => id}, exchange, type) when is_binary(id) and is_atom(type) do
    Symbol.from_exchange_id(id, exchange, type)
  end

  defp market_symbol_from_raw(%{"instId" => id}, exchange, type) when is_binary(id) and is_atom(type) do
    # Callers always pass `market_type_atom/1` output, so `type` is an atom here.
    Symbol.from_exchange_id(id, exchange, type)
  end

  defp market_symbol_from_raw(%{"baseAsset" => base, "quoteAsset" => quote}, exchange, _type)
       when is_binary(base) and is_binary(quote) do
    Symbol.build(market_currency_code(base, exchange), market_currency_code(quote, exchange))
  end

  defp market_symbol_from_raw(_raw, _exchange, _type), do: nil

  defp market_type_from_raw(%{"instType" => "SPOT"}), do: "spot"
  defp market_type_from_raw(%{"instType" => "MARGIN"}), do: "margin"
  defp market_type_from_raw(%{"instType" => "SWAP"}), do: "swap"
  defp market_type_from_raw(%{"instType" => "FUTURES"}), do: "future"
  defp market_type_from_raw(%{"instType" => "OPTION"}), do: "option"
  defp market_type_from_raw(%{"contractType" => "CRYPTO_OPTIONS"}), do: "option"
  defp market_type_from_raw(%{"kind" => "spot"}), do: "spot"
  defp market_type_from_raw(%{"kind" => "option"}), do: "option"
  defp market_type_from_raw(%{"kind" => "option_combo"}), do: "option_combo"
  defp market_type_from_raw(%{"kind" => "future_combo"}), do: "future_combo"
  defp market_type_from_raw(%{"settlement_period" => "perpetual"}), do: "swap"

  defp market_type_from_raw(%{"kind" => kind}) when is_binary(kind) do
    if String.contains?(kind, "future"), do: "future"
  end

  defp market_type_from_raw(%{"market_type" => "perp"}), do: "swap"
  defp market_type_from_raw(%{"market_type" => "spot"}), do: "spot"

  defp market_type_from_raw(%{"contractType" => type})
       when is_binary(type) and type in ["PERPETUAL", "TRADIFI_PERPETUAL"], do: "swap"

  defp market_type_from_raw(%{"contractType" => type}) when is_binary(type) and type != "", do: "future"
  defp market_type_from_raw(%{"baseAsset" => _, "quoteAsset" => _}), do: "spot"
  defp market_type_from_raw(%{"_bourse_type" => type}) when type in ["spot", "swap", "future", "option"], do: type
  defp market_type_from_raw(%{"tokens" => tokens}) when is_list(tokens), do: "spot"
  defp market_type_from_raw(%{"name" => name, "maxLeverage" => _}) when is_binary(name), do: "swap"
  defp market_type_from_raw(_raw), do: nil

  defp market_type_atom("margin"), do: :spot
  defp market_type_atom(type) when type in ["spot", "swap", "future", "option"], do: String.to_existing_atom(type)
  defp market_type_atom(_type), do: :spot

  defp annotate_bybit_market_category(payload, _body, %Exchange{id: "bybit"}, "market", %{"category" => category})
       when is_list(payload) and category in ["spot", "linear", "inverse", "option"] do
    Enum.map(payload, &Map.put_new(&1, "category", category))
  end

  # Pre-compute Bybit position notional + margin strings so field maps can read
  # stable keys (`_bourse_notional`, `_bourse_im`, `_bourse_mm`). The response
  # category is injected first: position rows need it for native-symbol
  # resolution just like every other read.
  defp annotate_bybit_market_category(payload, body, %Exchange{id: "bybit"}, "position", params) do
    inverse? = inverse_symbol?(Map.get(params, "symbol"))

    case annotate_bybit_response_category(payload, body) do
      rows when is_list(rows) -> Enum.map(rows, &annotate_bybit_position_row(&1, inverse?))
      %{} = row -> annotate_bybit_position_row(row, inverse?)
      other -> other
    end
  end

  # Bybit's `category=linear`/`inverse` ticker list mixes perpetuals with dated
  # delivery contracts, and a delivery contract publishes no funding at all —
  # `fundingRate` comes back as `""` with `nextFundingTime` `"0"`. Keeping those
  # rows would mint funding-rate records whose every funding field is nil.
  # https://bybit-exchange.github.io/docs/v5/market/tickers
  defp annotate_bybit_market_category(payload, body, %Exchange{id: "bybit"}, "funding_rate", _params)
       when is_list(payload) do
    payload
    |> annotate_bybit_response_category(body)
    |> case do
      rows when is_list(rows) -> Enum.filter(rows, &bybit_funding_row?/1)
      other -> other
    end
  end

  defp annotate_bybit_market_category(payload, body, %Exchange{id: "bybit"}, _parse_type, _params) do
    annotate_bybit_response_category(payload, body)
  end

  defp annotate_bybit_market_category(payload, _body, _exchange, _parse_type, _params), do: payload

  defp bybit_funding_row?(%{"fundingRate" => rate}) when is_binary(rate), do: rate != ""
  defp bybit_funding_row?(_row), do: true

  # Pre-compute OKX parsePosition money strings (notional / IM / collateral / ratio /
  # percentage / side / hedged / contract size) so field maps read stable `_bourse_*`
  # keys. Mirrors okx.ts parsePosition: inverse notional, cross vs isolated margin
  # branches, and uplRatio→percentage scale.
  defp annotate_okx_payload(payload, %Exchange{id: "okx"} = exchange, "position") do
    case payload do
      rows when is_list(rows) -> Enum.map(rows, &annotate_okx_position_row(&1, exchange))
      %{} = row -> annotate_okx_position_row(row, exchange)
      other -> other
    end
  end

  # OKX convert rows (`asset/convert/estimate-quote`, `asset/convert/trade`,
  # `asset/convert/history`) describe the conversion as an instrument side rather
  # than a from/to pair: `side` is taken against `baseCcy` of `instId`, so a `buy`
  # spends `quoteCcy` and receives `baseCcy`. Pre-compute the directional pair so
  # the field map reads stable `_bourse_*` keys. Live-verified on the OKX
  # international demo host 2026-08-23: a `side: "buy"` BTC-USDT conversion debited
  # `fillQuoteSz` USDT and credited `fillBaseSz` BTC.
  defp annotate_okx_payload(payload, %Exchange{id: "okx"}, "conversion") do
    case payload do
      rows when is_list(rows) -> Enum.map(rows, &annotate_okx_conversion_row/1)
      %{} = row -> annotate_okx_conversion_row(row)
      other -> other
    end
  end

  defp annotate_okx_payload(payload, _exchange, _parse_type), do: payload

  defp annotate_okx_conversion_row(row) when is_map(row) do
    base = non_empty_string(Map.get(row, "baseCcy"))
    quote_ccy = non_empty_string(Map.get(row, "quoteCcy"))
    base_size = okx_conversion_size(row, ["fillBaseSz", "baseSz"])
    quote_size = okx_conversion_size(row, ["fillQuoteSz", "quoteSz"])

    put_okx_conversion_pair(row, non_empty_string(Map.get(row, "side")), {base, base_size}, {quote_ccy, quote_size})
  end

  defp annotate_okx_conversion_row(other), do: other

  defp put_okx_conversion_pair(row, "buy", {base, base_size}, {quote_ccy, quote_size}),
    do: put_okx_conversion_direction(row, {quote_ccy, quote_size}, {base, base_size})

  defp put_okx_conversion_pair(row, "sell", {base, base_size}, {quote_ccy, quote_size}),
    do: put_okx_conversion_direction(row, {base, base_size}, {quote_ccy, quote_size})

  # An unknown `side` has no directional meaning; leave the row unannotated so the
  # unified fields stay nil rather than claiming a direction the venue never sent.
  defp put_okx_conversion_pair(row, _side, _base, _quote), do: row

  defp put_okx_conversion_direction(row, {from_ccy, from_size}, {to_ccy, to_size}) do
    row
    |> maybe_put_synthetic("_bourse_from_currency", from_ccy)
    |> maybe_put_synthetic("_bourse_from_amount", from_size)
    |> maybe_put_synthetic("_bourse_to_currency", to_ccy)
    |> maybe_put_synthetic("_bourse_to_amount", to_size)
  end

  defp okx_conversion_size(row, keys), do: Enum.find_value(keys, &non_empty_string(Map.get(row, &1)))

  defp annotate_okx_position_row(row, exchange) when is_map(row) do
    if Map.has_key?(row, "openAvgPx") do
      annotate_okx_history_position_row(row, exchange)
    else
      annotate_okx_open_position_row(row, exchange)
    end
  end

  defp annotate_okx_position_row(other, _exchange), do: other

  defp annotate_okx_history_position_row(row, exchange) do
    side = non_empty_string(Map.get(row, "direction")) || non_empty_string(Map.get(row, "posSide"))
    lever = non_empty_string(Map.get(row, "lever"))
    mgn_mode = non_empty_string(Map.get(row, "mgnMode"))
    im_pct = if mgn_mode == "isolated" and is_binary(lever), do: Bourse.Precise.string_div("1", lever)

    row
    |> maybe_put_synthetic("_bourse_side", side)
    |> maybe_put_synthetic("_bourse_hedged", side != nil and side != "net")
    |> maybe_put_synthetic("_bourse_contract_size", okx_position_contract_size(row, exchange))
    |> maybe_put_synthetic("_bourse_im_pct", im_pct)
    # History rows have no mmr/notional, so their maintenance-margin percentage is 0.
    |> maybe_put_synthetic("_bourse_mm_pct", "0")
  end

  defp annotate_okx_open_position_row(row, exchange) do
    pos = non_empty_string(Map.get(row, "pos"))
    contracts_abs = decimal_abs(pos)
    contract_size = okx_position_contract_size(row, exchange)
    mark = non_empty_string(Map.get(row, "markPx"))
    inverse? = okx_position_inverse?(row, exchange)
    notional = okx_position_notional(row, contracts_abs, contract_size, mark, inverse?)

    ctx = %{
      contracts_abs: contracts_abs,
      contract_size: contract_size,
      entry: non_empty_string(Map.get(row, "avgPx")) || non_empty_string(Map.get(row, "openAvgPx")),
      imr: non_empty_string(Map.get(row, "imr")),
      inverse?: inverse?,
      lever: non_empty_string(Map.get(row, "lever")),
      margin: non_empty_string(Map.get(row, "margin")),
      notional: notional,
      upl: non_empty_string(Map.get(row, "upl"))
    }

    {im, im_pct, collateral} = okx_position_margin_fields(non_empty_string(Map.get(row, "mgnMode")), ctx)
    mmr = non_empty_string(Map.get(row, "mmr"))
    upl_ratio = non_empty_string(Map.get(row, "uplRatio"))

    row
    |> maybe_put_synthetic("_bourse_side", okx_position_side(row, pos, exchange))
    |> maybe_put_synthetic("_bourse_hedged", okx_position_hedged?(row))
    |> maybe_put_synthetic("_bourse_contract_size", contract_size)
    |> maybe_put_synthetic("_bourse_notional", notional)
    |> maybe_put_synthetic("_bourse_im", im)
    |> maybe_put_synthetic("_bourse_im_pct", im_pct)
    |> maybe_put_synthetic("_bourse_collateral", collateral)
    |> maybe_put_synthetic("_bourse_mm_pct", okx_position_mm_pct(mmr, notional))
    |> maybe_put_synthetic("_bourse_margin_ratio", okx_position_margin_ratio(mmr, collateral))
    |> maybe_put_synthetic(
      "_bourse_percentage",
      if(is_binary(upl_ratio), do: Bourse.Precise.string_mul(upl_ratio, "100"))
    )
  end

  # A position is hedged when posSide is not `net`, checked before side conversion.
  defp okx_position_hedged?(row) do
    side = non_empty_string(Map.get(row, "posSide")) || non_empty_string(Map.get(row, "direction"))
    side != nil and side != "net"
  end

  defp okx_position_side(row, pos, exchange) do
    side = non_empty_string(Map.get(row, "posSide")) || non_empty_string(Map.get(row, "direction"))
    okx_position_side(row, pos, exchange, side)
  end

  defp okx_position_side(_row, _pos, _exchange, side) when side in ["long", "short"], do: side

  defp okx_position_side(%{"instType" => "MARGIN"} = row, _pos, exchange, "net") do
    okx_margin_position_side(row, exchange)
  end

  defp okx_position_side(_row, pos, _exchange, "net") when is_binary(pos) do
    case decimal_compare_zero_string(pos) do
      :gt -> "long"
      :lt -> "short"
      _ -> nil
    end
  end

  defp okx_position_side(_row, _pos, _exchange, side), do: side

  defp okx_margin_position_side(row, %Exchange{markets: markets} = exchange) when is_list(markets) do
    inst_id = non_empty_string(Map.get(row, "instId"))
    position_currency = currency_code(Map.get(row, "posCcy"), exchange)

    case Enum.find(markets, &(okx_market_id(&1) == inst_id)) do
      market when is_map(market) and is_binary(position_currency) ->
        base = Map.get(market, "base") || Map.get(market, :base)
        quote = Map.get(market, "quote") || Map.get(market, :quote)

        cond do
          base == position_currency -> "long"
          quote == position_currency -> "short"
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp okx_margin_position_side(_row, _exchange), do: nil

  defp okx_position_notional(_row, contracts_abs, contract_size, mark, true)
       when is_binary(contracts_abs) and is_binary(contract_size) and is_binary(mark) do
    contracts_abs
    |> Bourse.Precise.string_mul(contract_size)
    |> Bourse.Precise.string_div(mark)
  end

  defp okx_position_notional(row, _contracts_abs, _contract_size, _mark, false) do
    non_empty_string(Map.get(row, "notionalUsd"))
  end

  defp okx_position_notional(_row, _contracts_abs, _contract_size, _mark, _inverse?), do: nil

  defp okx_position_margin_fields("cross", %{imr: imr, upl: upl, notional: notional}) do
    collateral = okx_cross_collateral(imr, upl)
    im_pct = if is_binary(imr) and is_binary(notional), do: Bourse.Precise.string_div(imr, notional, 4)
    {imr, im_pct, collateral}
  end

  defp okx_position_margin_fields("isolated", ctx) do
    im_pct = if is_binary(ctx.lever), do: Bourse.Precise.string_div("1", ctx.lever)
    {okx_isolated_im(ctx, im_pct), im_pct, ctx.margin}
  end

  defp okx_position_margin_fields(_mode, %{imr: imr, margin: margin, upl: upl}) do
    collateral =
      case {margin || imr, upl, margin} do
        {c, u, nil} when is_binary(c) and is_binary(u) -> Bourse.Precise.string_add(c, u)
        {c, _, _} -> c
      end

    {imr, nil, collateral}
  end

  defp okx_cross_collateral(imr, upl) when is_binary(imr) and is_binary(upl), do: Bourse.Precise.string_add(imr, upl)
  defp okx_cross_collateral(imr, _upl) when is_binary(imr), do: imr
  defp okx_cross_collateral(_imr, _upl), do: nil

  defp okx_isolated_im(
         %{inverse?: true, contracts_abs: contracts, contract_size: cs, entry: entry, lever: lever},
         _im_pct
       )
       when is_binary(contracts) and is_binary(cs) and is_binary(entry) and is_binary(lever) do
    contracts
    |> Bourse.Precise.string_mul(cs)
    |> Bourse.Precise.string_div(entry)
    |> Bourse.Precise.string_div(lever)
  end

  defp okx_isolated_im(%{inverse?: inverse?, notional: notional}, im_pct)
       when inverse? != true and is_binary(im_pct) and is_binary(notional) do
    Bourse.Precise.string_mul(im_pct, notional)
  end

  defp okx_isolated_im(_ctx, _im_pct), do: nil

  defp okx_position_mm_pct(nil, _notional), do: nil

  defp okx_position_mm_pct(mmr, notional) when is_binary(mmr) and is_binary(notional) do
    mmr
    |> Bourse.Precise.string_div(notional)
    |> Bourse.Precise.string_add("0.00005")
    |> Bourse.Precise.string_div("1", 4)
  end

  defp okx_position_mm_pct(_mmr, _notional), do: nil

  defp okx_position_margin_ratio(mmr, collateral) when is_binary(mmr) and is_binary(collateral) do
    Bourse.Precise.string_div(mmr, collateral, 4)
  end

  defp okx_position_margin_ratio(_mmr, _collateral), do: nil

  defp okx_position_contract_size(row, %Exchange{markets: markets}) when is_list(markets) do
    inst_id = non_empty_string(Map.get(row, "instId"))

    case Enum.find(markets, &(okx_market_id(&1) == inst_id)) do
      nil -> nil
      market -> okx_market_contract_size(market)
    end
  end

  defp okx_position_contract_size(_row, _exchange), do: nil

  defp okx_market_id(market) when is_map(market) do
    Map.get(market, "id") || Map.get(market, :id)
  end

  defp okx_market_contract_size(market) when is_map(market) do
    size = Map.get(market, "contractSize") || Map.get(market, :contract_size) || Map.get(market, :contractSize)
    non_empty_string(size)
  end

  defp okx_position_inverse?(row, %Exchange{markets: markets}) when is_list(markets) do
    inst_id = non_empty_string(Map.get(row, "instId"))

    case Enum.find(markets, &(okx_market_id(&1) == inst_id)) do
      nil -> okx_inverse_inst_id?(inst_id)
      market -> okx_market_inverse?(market)
    end
  end

  defp okx_position_inverse?(row, _exchange), do: okx_inverse_inst_id?(non_empty_string(Map.get(row, "instId")))

  defp okx_market_inverse?(market) when is_map(market) do
    cond do
      Map.get(market, "inverse") == true or Map.get(market, :inverse) == true -> true
      Map.get(market, "linear") == true or Map.get(market, :linear) == true -> false
      true -> okx_inverse_inst_id?(okx_market_id(market))
    end
  end

  # OKX inverse swaps settle in the base: `BTC-USD-SWAP` (quote USD, settle BTC).
  defp okx_inverse_inst_id?(inst_id) when is_binary(inst_id) do
    String.contains?(inst_id, "-USD-") and not String.contains?(inst_id, "-USDT-") and
      not String.contains?(inst_id, "-USDC-")
  end

  defp okx_inverse_inst_id?(_), do: false

  defp decimal_compare_zero_string(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.compare(decimal, 0)
      _ -> nil
    end
  end

  defp annotate_binance_family_payload(payload, body, %Exchange{id: id} = exchange, parse_type, js_name, params)
       when id in ["binance", "binancecoinm", "binanceusdm"] do
    payload = annotate_binance_borrow_and_convert_payload(payload, parse_type, params)

    case_result =
      case parse_type do
        "leverage_tiers" -> flatten_binance_leverage_tiers(payload)
        "order" -> annotate_binance_orders(payload, js_name, exchange, params)
        "position" -> annotate_binance_positions(payload, body, params, exchange)
        "margin_mode" -> annotate_binance_margin_mode(payload)
        "adl_rank" -> annotate_binance_adl_ranks(payload)
        "trade" -> annotate_binance_trades(payload)
        "transaction" -> annotate_binance_transactions(payload, js_name, params)
        _parse_type -> payload
      end

    maybe_wrap_binance_cancel_all(case_result, body, id, parse_type, js_name)
  end

  defp annotate_binance_family_payload(payload, _body, _exchange, _parse_type, _js_name, _params), do: payload

  # Split out of the parse_type case above to keep that function inside the
  # project's cyclomatic-complexity budget.
  defp annotate_binance_borrow_and_convert_payload(payload, "borrow_interest", _params) do
    annotate_binance_borrow_interests(payload)
  end

  defp annotate_binance_borrow_and_convert_payload(payload, "conversion", params) do
    annotate_binance_conversion(payload, params)
  end

  defp annotate_binance_borrow_and_convert_payload(payload, _parse_type, _params), do: payload

  defp flatten_binance_leverage_tiers(rows) when is_list(rows) do
    Enum.flat_map(rows, fn
      %{"brackets" => brackets, "symbol" => symbol} when is_list(brackets) ->
        Enum.map(brackets, &Map.put_new(&1, "symbol", symbol))

      row when is_map(row) ->
        [row]

      _other ->
        []
    end)
  end

  defp flatten_binance_leverage_tiers(payload), do: payload

  defp annotate_binance_orders(rows, js_name, exchange, params) when is_list(rows) do
    Enum.map(rows, &annotate_binance_order(&1, js_name, exchange, params))
  end

  defp annotate_binance_orders(%{} = row, js_name, exchange, params) do
    annotate_binance_order(row, js_name, exchange, params)
  end

  defp annotate_binance_orders(payload, _js_name, _exchange, _params), do: payload

  defp annotate_binance_transactions(rows, js_name, params) when is_list(rows) do
    Enum.map(rows, &annotate_binance_transaction(&1, js_name, params))
  end

  defp annotate_binance_transactions(%{} = row, js_name, params), do: annotate_binance_transaction(row, js_name, params)
  defp annotate_binance_transactions(payload, _js_name, _params), do: payload

  defp annotate_binance_transaction(%{} = row, "fetchDeposits", _params), do: Map.put_new(row, "_bourse_type", "deposit")

  defp annotate_binance_transaction(%{} = row, "fetchWithdrawals", _params),
    do: Map.put_new(row, "_bourse_type", "withdrawal")

  defp annotate_binance_transaction(%{} = row, "withdraw", params) do
    maybe_put_synthetic(row, "_bourse_currency", Map.get(params, "code"))
  end

  defp annotate_binance_transaction(row, _js_name, _params), do: row

  defp annotate_lighter_payload(rows, %Exchange{id: "lighter"}, "transaction", js_name)
       when is_list(rows) and js_name in ["fetchDeposits", "fetchWithdrawals"] do
    type = if js_name == "fetchDeposits", do: "deposit", else: "withdrawal"

    Enum.map(rows, fn
      %{} = row -> Map.put_new(row, "_bourse_type", type)
      row -> row
    end)
  end

  defp annotate_lighter_payload(rows, %Exchange{id: "lighter"} = exchange, "trade", "fetchMyTrades") when is_list(rows) do
    Enum.map(rows, &annotate_lighter_trade(&1, exchange))
  end

  defp annotate_lighter_payload(payload, _exchange, _parse_type, _js_name), do: payload

  defp annotate_lighter_trade(%{} = row, exchange) do
    case lighter_trade_role(row, exchange) do
      {:ask, maker?} -> put_lighter_trade_fields(row, exchange, "sell", maker?, "ask")
      {:bid, maker?} -> put_lighter_trade_fields(row, exchange, "buy", maker?, "bid")
      nil -> row
    end
  end

  defp annotate_lighter_trade(row, _exchange), do: row

  defp lighter_trade_role(row, exchange) do
    account_index = lighter_account_index(exchange)
    ask? = lighter_account?(Map.get(row, "ask_account_id"), account_index)
    bid? = lighter_account?(Map.get(row, "bid_account_id"), account_index)

    case {ask?, bid?, Map.get(row, "is_maker_ask")} do
      {true, false, maker?} when is_boolean(maker?) -> {:ask, maker?}
      {false, true, maker?} when is_boolean(maker?) -> {:bid, not maker?}
      _ -> nil
    end
  end

  defp put_lighter_trade_fields(row, exchange, side, maker?, order_side) do
    fee_key = if maker?, do: "maker_fee", else: "taker_fee"
    order_id = Map.get(row, "#{order_side}_id_str") || Map.get(row, "#{order_side}_id")

    row
    |> maybe_put_synthetic("_bourse_side", side)
    |> maybe_put_synthetic("_bourse_taker_or_maker", if(maker?, do: "maker", else: "taker"))
    |> maybe_put_synthetic("_bourse_order", order_id)
    |> maybe_put_synthetic("_bourse_fee", Map.get(row, fee_key))
    |> maybe_put_synthetic("_bourse_fee_currency", lighter_market_settle(exchange, Map.get(row, "market_id")))
  end

  defp lighter_account?(value, account_index) when is_integer(account_index) do
    Bourse.Safe.integer(value) == account_index
  end

  defp lighter_account?(_value, _account_index), do: false

  defp lighter_account_index(%Exchange{credentials: %{uid: uid}}), do: Bourse.Safe.integer(uid)
  defp lighter_account_index(_exchange), do: nil

  defp lighter_market_settle(%Exchange{markets: markets}, market_id) when is_list(markets) do
    native_id = Bourse.Safe.string(market_id)

    markets
    |> Enum.find(&(Bourse.Safe.string(binance_market_id(&1)) == native_id))
    |> case do
      nil -> nil
      market -> Map.get(market, :settle) || Map.get(market, "settle")
    end
  end

  defp lighter_market_settle(_exchange, _market_id), do: nil

  defp annotate_binance_order(%{} = row, js_name, exchange, params) do
    id = binance_field(row, ["orderId", "algoId"])
    amount = non_empty_string(binance_field(row, ["origQty", "quantity"]))
    filled = binance_order_filled(row, id)
    cost = binance_order_cost(row, amount, filled)
    status = binance_order_status(row, js_name)
    last_update = binance_field(row, ["updateTime", "transactTime"])

    row
    |> maybe_put_synthetic("_bourse_id", id)
    |> maybe_put_synthetic("_bourse_client_order_id", binance_field(row, ["clientOrderId", "clientAlgoId"]))
    |> maybe_put_synthetic("_bourse_amount", amount)
    |> maybe_put_synthetic("_bourse_filled", filled)
    |> maybe_put_synthetic("_bourse_cost", cost)
    |> maybe_put_synthetic("_bourse_price", binance_order_price(row, cost, filled))
    |> maybe_put_synthetic("_bourse_average", binance_order_average(cost, filled))
    |> maybe_put_synthetic("_bourse_remaining", binance_order_remaining(amount, filled))
    # `workingTime: -1` means the trailing order has not started working; it is
    # an activation sentinel, not an epoch. Fall through to the creation clock.
    |> maybe_put_synthetic(
      "_bourse_timestamp",
      binance_order_timestamp(row)
    )
    |> maybe_put_synthetic("_bourse_last_update", last_update)
    |> maybe_put_synthetic("_bourse_last_trade", binance_last_trade_timestamp(status, last_update))
    |> put_binance_order_type(exchange, params)
    |> maybe_put_synthetic("_bourse_status", status)
    |> maybe_put_synthetic("_bourse_trigger_price", binance_order_trigger_price(row))
    |> maybe_put_synthetic("_bourse_time_in_force", binance_time_in_force(row))
    |> maybe_put_synthetic("_bourse_post_only", binance_post_only(row))
  end

  defp annotate_binance_order(other, _js_name, _exchange, _params), do: other

  defp binance_order_status(%{"algoId" => algo_id, "code" => code}, "cancelOrder")
       when not is_nil(algo_id) and code in [200, "200"], do: "CANCELED"

  defp binance_order_status(row, _js_name), do: binance_field(row, ["status", "algoStatus"])

  # Binance USD-M documents GTX as "Good Till Crossing (Post Only)". Normalize
  # GTX to unified timeInForce "PO" and postOnly true (see carve C-T321a).
  defp binance_time_in_force(%{"timeInForce" => "GTX"}), do: "PO"
  defp binance_time_in_force(%{"timeInForce" => tif}) when is_binary(tif), do: tif
  defp binance_time_in_force(_row), do: nil

  defp binance_post_only(row) do
    type = binance_field(row, ["type", "orderType", "origType"])
    tif = Map.get(row, "timeInForce")
    type == "LIMIT_MAKER" or tif == "GTX"
  end

  # Venue order objects expose updateTime (last status change), not a dedicated
  # last-trade clock. For FILLED orders the final update is the fill — adopt that
  # as lastTradeTimestamp (Binance updateTime docs; carve C-T321b).
  defp binance_last_trade_timestamp("FILLED", last_update), do: last_update
  defp binance_last_trade_timestamp(_status, _last_update), do: nil

  # Binance reuses one order shape across spot/futures/papi/algo with per-surface
  # key aliases; first non-nil wins.
  defp binance_field(row, keys), do: Enum.find_value(keys, fn key -> Map.get(row, key) end)

  # Binance acknowledgements without `executedQty` state no fill fact. Do not
  # turn omitted information into a zero fill (carve C-T381b).
  defp binance_order_filled(row, _id), do: non_empty_string(Map.get(row, "executedQty"))

  defp binance_order_timestamp(row) do
    Enum.find_value(["time", "workingTime", "createTime", "transactTime"], fn key ->
      timestamp = Map.get(row, key)
      if non_negative_timestamp?(timestamp), do: timestamp
    end)
  end

  defp non_negative_timestamp?(timestamp) when is_integer(timestamp), do: timestamp >= 0

  defp non_negative_timestamp?(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {value, ""} -> value >= 0
      _ -> false
    end
  end

  defp non_negative_timestamp?(_timestamp), do: false

  defp binance_order_cost(row, amount, filled) do
    non_empty_string(binance_field(row, ["cummulativeQuoteQty", "cumQuote"])) ||
      binance_zero_order_cost(amount, filled)
  end

  defp binance_zero_order_cost(amount, "0") when is_binary(amount), do: "0"
  defp binance_zero_order_cost(_amount, _filled), do: nil

  defp binance_order_trigger_price(row) do
    Map.get(row, "triggerPrice") || zero_as_nil(Map.get(row, "stopPrice"))
  end

  defp binance_order_price(row, cost, filled) do
    explicit = zero_as_nil(Map.get(row, "price") || Map.get(row, "actualPrice"))
    explicit || binance_order_average(cost, filled)
  end

  defp binance_order_average(cost, filled) do
    with cost when is_binary(cost) <- non_empty_string(cost),
         filled when is_binary(filled) <- non_empty_string(filled),
         false <- Decimal.equal?(Decimal.new(filled), Decimal.new(0)) do
      Bourse.Precise.string_div(cost, filled)
    else
      _ -> nil
    end
  rescue
    Decimal.Error -> nil
  end

  defp binance_order_remaining(amount, filled) do
    with amount when is_binary(amount) <- non_empty_string(amount),
         filled when is_binary(filled) <- non_empty_string(filled) do
      amount
      |> Decimal.new()
      |> Decimal.sub(Decimal.new(filled))
      |> Decimal.to_string(:normal)
    else
      _ -> nil
    end
  rescue
    Decimal.Error -> nil
  end

  # Spot enum: New Order `type` on developers.binance.com spot REST Trade.
  # LIMIT_MAKER is a post-only LIMIT (postOnly is derived separately).
  @binance_spot_order_types %{
    "LIMIT" => "limit",
    "LIMIT_MAKER" => "limit",
    "MARKET" => "market",
    "STOP_LOSS" => "stop_loss",
    "STOP_LOSS_LIMIT" => "stop_loss_limit",
    "TAKE_PROFIT" => "take_profit",
    "TAKE_PROFIT_LIMIT" => "take_profit_limit"
  }

  # USD-M / COIN-M: LIMIT/MARKET on the regular book; STOP, STOP_MARKET,
  # TAKE_PROFIT, TAKE_PROFIT_MARKET, TRAILING_STOP_MARKET on algoType=CONDITIONAL.
  @binance_futures_order_types %{
    "LIMIT" => "limit",
    "MARKET" => "market",
    "STOP" => "stop",
    "STOP_MARKET" => "stop_market",
    "TAKE_PROFIT" => "take_profit",
    "TAKE_PROFIT_MARKET" => "take_profit_market",
    "TRAILING_STOP_MARKET" => "trailing_stop_market"
  }

  # Options EAPI New Order documents LIMIT only.
  @binance_option_order_types %{"LIMIT" => "limit"}

  defp put_binance_order_type(row, exchange, params) do
    product = binance_order_product(exchange, params)

    case binance_order_type(binance_field(row, ["type", "orderType"]), product) do
      {:ok, unified} ->
        maybe_put_synthetic(row, "_bourse_type", unified)

      {:error, {:unmapped_order_type, details}} ->
        Map.put(row, "_bourse_unmapped_order_type", Map.put(details, :venue, exchange.id))
    end
  end

  defp binance_order_type(type, product) when is_binary(type) do
    case Map.fetch(binance_order_type_table(product), type) do
      {:ok, unified} ->
        {:ok, unified}

      :error ->
        {:error, {:unmapped_order_type, %{product: product, field: "type", raw_value: type}}}
    end
  end

  defp binance_order_type(_type, _product), do: {:ok, nil}

  defp binance_order_type_table(:spot), do: @binance_spot_order_types
  defp binance_order_type_table(:futures), do: @binance_futures_order_types
  defp binance_order_type_table(:option), do: @binance_option_order_types

  defp binance_order_product(%Exchange{id: id}, _params) when id in ["binanceusdm", "binancecoinm"], do: :futures

  defp binance_order_product(_exchange, params) do
    case endpoint_market_type(params) do
      :spot -> :spot
      :swap -> :futures
      :future -> :futures
      :option -> :option
      nil -> binance_order_product_from_params(params)
    end
  end

  defp binance_order_product_from_params(%{"market_family" => family}) when family in ["linear", "inverse"], do: :futures

  defp binance_order_product_from_params(%{"market_family" => "option"}), do: :option
  defp binance_order_product_from_params(%{"market_family" => "spot"}), do: :spot
  defp binance_order_product_from_params(params), do: binance_order_product_from_endpoint(params)

  defp binance_order_product_from_endpoint(params) do
    id = Map.get(params, "_bourse_endpoint_id") || Map.get(params, "_bourse_endpoint_route") || ""

    cond do
      String.contains?(id, "eapi") -> :option
      String.contains?(id, "fapi") or String.contains?(id, "dapi") -> :futures
      true -> :spot
    end
  end

  defp reject_unmapped_binance_order_type(rows) when is_list(rows) do
    Enum.find_value(rows, :ok, &unmapped_binance_order_type_error/1)
  end

  defp reject_unmapped_binance_order_type(%{} = row) do
    unmapped_binance_order_type_error(row) || :ok
  end

  defp reject_unmapped_binance_order_type(_payload), do: :ok

  defp unmapped_binance_order_type_error(%{"_bourse_unmapped_order_type" => details}) do
    {:error, {:unmapped_order_type, details}}
  end

  defp unmapped_binance_order_type_error(_row), do: nil

  defp zero_as_nil(value) do
    case non_empty_string(value) do
      nil -> nil
      value -> if Decimal.equal?(Decimal.new(value), Decimal.new(0)), do: nil, else: value
    end
  rescue
    Decimal.Error -> nil
  end

  defp maybe_wrap_binance_cancel_all(payload, body, id, "order", "cancelAllOrders")
       when id in ["binance", "binancecoinm", "binanceusdm"] and is_map(payload) and is_map(body) do
    [payload]
  end

  defp maybe_wrap_binance_cancel_all(payload, _body, _id, _parse_type, _js_name), do: payload

  defp annotate_binance_trades(rows) when is_list(rows), do: Enum.map(rows, &annotate_binance_trade/1)
  defp annotate_binance_trades(%{} = row), do: annotate_binance_trade(row)
  defp annotate_binance_trades(payload), do: payload

  defp annotate_binance_trade(%{} = row) do
    amount = Map.get(row, "qty") || Map.get(row, "q")
    price = Map.get(row, "price") || Map.get(row, "p")

    row
    |> maybe_put_synthetic("_bourse_trade_id", Map.get(row, "id") || Map.get(row, "tradeId") || Map.get(row, "a"))
    |> maybe_put_synthetic("_bourse_trade_amount", amount)
    |> maybe_put_synthetic("_bourse_trade_price", price)
    |> maybe_put_synthetic("_bourse_trade_cost", Map.get(row, "quoteQty") || maybe_mul_decimal(amount, price))
    |> maybe_put_synthetic("_bourse_trade_side", binance_trade_side(row))
    |> maybe_put_synthetic("_bourse_taker_or_maker", binance_taker_or_maker(row))
  end

  defp annotate_binance_trade(other), do: other

  defp binance_trade_side(%{"isBuyer" => value}), do: if(Bourse.Safe.bool(value), do: "buy", else: "sell")
  defp binance_trade_side(%{"buyer" => value}), do: if(Bourse.Safe.bool(value), do: "buy", else: "sell")
  defp binance_trade_side(%{"m" => value}), do: if(Bourse.Safe.bool(value), do: "sell", else: "buy")
  defp binance_trade_side(_row), do: nil

  defp binance_taker_or_maker(%{"isMaker" => value}), do: if(Bourse.Safe.bool(value), do: "maker", else: "taker")
  defp binance_taker_or_maker(%{"maker" => value}), do: if(Bourse.Safe.bool(value), do: "maker", else: "taker")
  defp binance_taker_or_maker(_row), do: nil

  defp annotate_binance_adl_ranks(rows) when is_list(rows), do: Enum.map(rows, &annotate_binance_adl_rank/1)
  defp annotate_binance_adl_ranks(%{} = row), do: annotate_binance_adl_rank(row)
  defp annotate_binance_adl_ranks(payload), do: payload

  defp annotate_binance_adl_rank(%{"adlQuantile" => %{} = quantile} = row) do
    maybe_put_synthetic(row, "_bourse_adl_rank", Map.get(quantile, "BOTH"))
  end

  defp annotate_binance_adl_rank(%{"adlRisk" => risk} = row) do
    maybe_put_synthetic(row, "_bourse_adl_rating", risk |> to_string() |> String.downcase())
  end

  defp annotate_binance_adl_rank(row), do: row

  defp annotate_binance_margin_mode(%{} = row) do
    margin_mode =
      case Map.fetch(row, "isolated") do
        {:ok, true} -> "isolated"
        {:ok, false} -> "cross"
        :error -> Map.get(row, "marginType")
      end

    maybe_put_synthetic(row, "_bourse_margin_mode", margin_mode)
  end

  defp annotate_binance_margin_mode(payload), do: payload

  defp annotate_binance_borrow_interests(rows) when is_list(rows), do: Enum.map(rows, &annotate_binance_borrow_interest/1)

  defp annotate_binance_borrow_interests(%{} = row), do: annotate_binance_borrow_interest(row)
  defp annotate_binance_borrow_interests(payload), do: payload

  defp annotate_binance_borrow_interest(%{} = row) do
    margin_mode = if non_empty_string(Map.get(row, "isolatedSymbol")), do: "isolated", else: "cross"
    Map.put_new(row, "_bourse_margin_mode", margin_mode)
  end

  defp annotate_binance_borrow_interest(row), do: row

  defp annotate_binance_conversion(%{} = row, params) do
    row
    |> maybe_put_synthetic("_bourse_from_currency", Map.get(params, "from_code"))
    |> maybe_put_synthetic("_bourse_to_currency", Map.get(params, "to_code"))
  end

  defp annotate_binance_conversion(payload, _params), do: payload

  defp annotate_binance_positions(%{"positions" => positions, "assets" => assets}, _body, _params, exchange)
       when is_list(positions) and is_list(assets) do
    Enum.map(positions, &annotate_binance_position(&1, assets, exchange))
  end

  defp annotate_binance_positions(rows, _body, _params, exchange) when is_list(rows),
    do: Enum.map(rows, &annotate_binance_position(&1, [], exchange))

  defp annotate_binance_positions(%{} = row, _body, _params, exchange), do: annotate_binance_position(row, [], exchange)

  defp annotate_binance_positions(payload, _body, _params, _exchange), do: payload

  defp annotate_binance_position(%{} = row, assets, exchange) do
    contracts = non_empty_string(Map.get(row, "positionAmt"))
    notional = non_empty_string(Map.get(row, "notional") || Map.get(row, "notionalValue"))
    leverage = non_empty_string(Map.get(row, "leverage"))
    margin_asset = Map.get(row, "marginAsset") || binance_settle_from_symbol(Map.get(row, "symbol"))
    asset = Enum.find(assets, &(Map.get(&1, "asset") == margin_asset))
    collateral = binance_position_collateral(row, asset)

    row
    |> maybe_put_synthetic("_bourse_contracts", decimal_abs(contracts))
    |> maybe_put_synthetic("_bourse_contract_size", binance_contract_size(row, exchange))
    |> maybe_put_synthetic("_bourse_notional", decimal_abs(notional))
    |> maybe_put_synthetic(
      "_bourse_initial_margin",
      Map.get(row, "initialMargin") || binance_position_initial_margin(notional, leverage)
    )
    |> maybe_put_synthetic("_bourse_collateral", collateral)
    |> maybe_put_synthetic("_bourse_margin_mode", Map.get(row, "marginType") || "cross")
    |> maybe_put_synthetic("_bourse_side", binance_position_side(contracts))
    |> maybe_put_synthetic("_bourse_hedged", Map.get(row, "positionSide") != "BOTH")
    |> maybe_put_account_asset_margin(asset)
  end

  defp annotate_binance_position(other, _assets, _exchange), do: other

  defp binance_position_collateral(row, asset) do
    Map.get(asset || %{}, "marginBalance") ||
      Map.get(row, "crossMargin") ||
      if(Map.get(row, "marginType") == "isolated", do: Map.get(row, "isolatedMargin"))
  end

  # Binance reuses one exchange id across market types — `BTCUSDT` is both the
  # spot market (contractSize null) and the USD-M linear swap (contractSize 1).
  # A position row is always a contract, so resolve the contract market first
  # and only fall back to a bare id match when no contract market is loaded.
  defp binance_contract_size(%{"symbol" => symbol}, %Exchange{markets: markets})
       when is_binary(symbol) and is_list(markets) do
    matches = Enum.filter(markets, &(binance_market_id(&1) == symbol))

    binance_market_contract_size(Enum.find(matches, &binance_contract_market?/1) || List.first(matches))
  end

  defp binance_contract_size(_row, _exchange), do: nil

  defp binance_market_contract_size(nil), do: nil

  defp binance_market_contract_size(market) do
    Map.get(market, :contract_size) ||
      Map.get(market, "contractSize") ||
      Map.get(market, :contractSize) ||
      if(binance_linear_market?(market), do: 1)
  end

  defp binance_linear_market?(market), do: Map.get(market, :linear) || Map.get(market, "linear")

  defp binance_contract_market?(market) do
    Enum.any?([:contract, "contract", :swap, "swap", :future, "future"], &Map.get(market, &1))
  end

  defp binance_position_initial_margin(notional, leverage) do
    with notional when is_binary(notional) <- decimal_abs(notional),
         leverage when is_binary(leverage) <- non_empty_string(leverage),
         false <- Decimal.equal?(Decimal.new(leverage), Decimal.new(0)) do
      Bourse.Precise.string_div(notional, leverage)
    else
      _ -> nil
    end
  rescue
    Decimal.Error -> nil
  end

  defp binance_position_side(value) do
    case decimal_compare_zero(value) do
      :lt -> "short"
      :gt -> "long"
      _ -> nil
    end
  end

  defp decimal_abs(nil), do: nil

  defp decimal_abs(value) do
    value
    |> Decimal.new()
    |> Decimal.abs()
    |> Decimal.to_string(:normal)
  rescue
    Decimal.Error -> nil
  end

  defp decimal_compare_zero(nil), do: nil

  defp decimal_compare_zero(value) do
    value
    |> Decimal.new()
    |> Decimal.compare(Decimal.new(0))
  rescue
    Decimal.Error -> nil
  end

  defp maybe_mul_decimal(nil, _right), do: nil
  defp maybe_mul_decimal(_left, nil), do: nil
  defp maybe_mul_decimal(left, right), do: Bourse.Precise.string_mul(left, right)

  defp binance_settle_from_symbol(symbol) when is_binary(symbol) do
    cond do
      String.ends_with?(symbol, "USDT") -> "USDT"
      String.ends_with?(symbol, "USDC") -> "USDC"
      String.contains?(symbol, "USD_") or String.ends_with?(symbol, "USD_PERP") -> "BTC"
      true -> nil
    end
  end

  defp binance_settle_from_symbol(_symbol), do: nil

  defp maybe_put_account_asset_margin(row, %{} = asset) do
    row
    |> maybe_put_synthetic("crossMargin", Map.get(asset, "marginBalance"))
    |> maybe_put_synthetic("crossWalletBalance", Map.get(asset, "crossWalletBalance"))
  end

  defp maybe_put_account_asset_margin(row, _asset), do: row

  # Bybit v5 envelopes carry `result.category`; without it a native id like
  # `BTCUSDT` is ambiguous between spot and linear and reverse-resolution
  # guesses, leaving `symbol` wrong or nil so the requested-symbol filter
  # silently drops the row.
  defp annotate_bybit_response_category(payload, %{"result" => %{"category" => category}})
       when category in ["spot", "linear", "inverse", "option"] do
    annotate_bybit_rows(payload, category)
  end

  defp annotate_bybit_response_category(payload, _body), do: payload

  defp annotate_bybit_rows(rows, category) when is_list(rows) do
    Enum.map(rows, &Map.put_new(&1, "category", category))
  end

  defp annotate_bybit_rows(row, category) when is_map(row), do: Map.put_new(row, "category", category)
  defp annotate_bybit_rows(payload, _category), do: payload

  defp annotate_bybit_position_row(row, inverse?) when is_map(row) do
    if Map.has_key?(row, "closedSize") do
      row
    else
      im = non_empty_string(Map.get(row, "positionIM")) || non_empty_string(Map.get(row, "cumEntryValue"))
      notional = bybit_position_notional(row, inverse?)
      mm = bybit_position_maintenance_margin(row, inverse?)

      # Authored V5 unit 1: linear qty is one base-coin (C-T625b); inverse is 1 USD (C-T641).
      row
      |> maybe_put_synthetic("_bourse_im", im)
      |> maybe_put_synthetic("_bourse_notional", notional)
      |> maybe_put_synthetic("_bourse_mm", mm)
      |> maybe_put_synthetic("_bourse_contract_size", "1")
    end
  end

  defp annotate_bybit_position_row(other, _inverse?), do: other

  defp bybit_position_notional(row, true) do
    size = non_empty_string(Map.get(row, "size")) || non_empty_string(Map.get(row, "qty"))
    mark = non_empty_string(Map.get(row, "markPrice"))

    # Inverse notional is size / markPrice because the authored unit is 1 USD (C-T641).
    case {size, mark} do
      {size, mark} when is_binary(size) and is_binary(mark) -> Bourse.Precise.string_div(size, mark)
      _ -> nil
    end
  end

  defp bybit_position_notional(row, false) do
    non_empty_string(Map.get(row, "positionValue")) || non_empty_string(Map.get(row, "cumExitValue"))
  end

  # When liqPrice is present, recompute maintenance margin from bust/liq. An empty
  # bust yields nil even when liq is set.
  defp bybit_position_maintenance_margin(row, inverse?) do
    case non_empty_string(Map.get(row, "liqPrice")) do
      nil ->
        non_empty_string(Map.get(row, "positionMM"))

      liq ->
        bust = non_empty_string(Map.get(row, "bustPrice"))
        size = non_empty_string(Map.get(row, "size")) || non_empty_string(Map.get(row, "qty"))
        bybit_recomputed_mm(liq, bust, size, inverse?)
    end
  end

  defp bybit_recomputed_mm(_liq, nil, _size, _inverse?), do: nil
  defp bybit_recomputed_mm(_liq, _bust, nil, _inverse?), do: nil

  defp bybit_recomputed_mm(liq, bust, size, false) do
    # linear: |liq - bust| * size
    liq
    |> decimal_abs_diff(bust)
    |> case do
      nil -> nil
      diff -> Bourse.Precise.string_mul(diff, size)
    end
  end

  defp bybit_recomputed_mm(liq, bust, size, true) do
    # inverse: size * |bust - liq| / (bust * liq)
    case decimal_abs_diff(bust, liq) do
      nil ->
        nil

      diff ->
        denom = Bourse.Precise.string_mul(bust, liq)
        numer = Bourse.Precise.string_mul(size, diff)
        Bourse.Precise.string_div(numer, denom)
    end
  end

  defp decimal_abs_diff(left, right) when is_binary(left) and is_binary(right) do
    left
    |> Decimal.new()
    |> Decimal.sub(Decimal.new(right))
    |> Decimal.abs()
    |> Decimal.to_string(:normal)
  rescue
    Decimal.Error -> nil
  end

  defp decimal_abs_diff(_left, _right), do: nil

  defp non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_string(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp non_empty_string(_value), do: nil

  defp maybe_put_synthetic(row, _key, nil), do: row
  defp maybe_put_synthetic(row, key, value), do: Map.put(row, key, value)

  # Bybit `fetchPosition` stamps `timestamp` from the outer response `time`
  # after parsePosition (bybit.ts) — not from createdTime on the row.
  defp stamp_bybit_fetch_position_timestamp(%Bourse.Position{} = position, body, %Exchange{id: "bybit"}, "fetchPosition")
       when is_map(body) do
    case Bourse.Safe.integer(Map.get(body, "time")) do
      nil ->
        position

      ts ->
        %{position | timestamp: ts, datetime: Timestamp.iso8601_from_ms(ts)}
    end
  end

  defp stamp_bybit_fetch_position_timestamp(parsed, _body, _exchange, _js_name), do: parsed

  # Bybit v5 list endpoints put rows under `result.list` (markets/orders) or
  # `result.rows` (deposits/withdrawals/currencies). Either empty list is a
  # valid empty collection success for list/dict returns.
  defp unwrap_bybit_v5_result(%{"result" => result}, %Exchange{id: "bybit"}, list_return?) when is_map(result) do
    case {list_return?, bybit_result_collection(result)} do
      {true, rows} when is_list(rows) -> rows
      _ -> result
    end
  end

  defp unwrap_bybit_v5_result(payload, _exchange, _list_return?), do: payload

  defp bybit_result_collection(%{"list" => rows}) when is_list(rows), do: rows
  defp bybit_result_collection(%{"rows" => rows}) when is_list(rows), do: rows
  defp bybit_result_collection(%{"chains" => rows}) when is_list(rows), do: rows
  defp bybit_result_collection(_result), do: nil

  # Deposit query-address answers `{result: {coin, chains: [...]}}`. Stamp `coin`
  # onto each chain row so the field map can fill DepositAddress.currency.
  defp annotate_bybit_deposit_chains(payload, body, %Exchange{id: "bybit"}, js_name)
       when js_name in ["fetchDepositAddress", "fetchDepositAddressesByNetwork"] do
    coin = get_in(body, ["result", "coin"])

    cond do
      is_list(payload) and is_binary(coin) ->
        Enum.map(payload, fn
          row when is_map(row) -> Map.put_new(row, "coin", coin)
          other -> other
        end)

      is_map(payload) and is_list(payload["chains"]) and is_binary(coin) ->
        chains = Enum.map(payload["chains"], &Map.put_new(&1, "coin", coin))
        Map.put(payload, "chains", chains)

      true ->
        payload
    end
  end

  defp annotate_bybit_deposit_chains(payload, _body, _exchange, _js_name), do: payload

  # Common wire containers for list/dict unified reads when the authored envelope
  # key is missing or points at a sibling collection key. Prefer explicit
  # collection keys only — never `extract_first_list_value`, which can peel an
  # incidental nested array off a single-record body.
  @collection_keys ~w(data list rows)

  # binance's per-symbol ticker read answers with a bare flat object instead
  # of a one-element array when a single `symbol` is sent — the same wire
  # endpoint returns an array only when no symbol is given. A dict-return
  # method (fetchTickers, and fetchBidsAsks aliased above) must fold that
  # single row into a one-element list before parsing, or the row parses as
  # one flat struct and shape_parsed_result/4 has no list to re-key by symbol.
  # https://developers.binance.com/en/docs/binance-spot-api-docs/rest-api/market-data-endpoints#24hr-ticker-price-change-statistics
  defp coerce_collection_payload(payload, true, %Exchange{id: "binance"}, "fetchTickers") when is_map(payload) do
    case collection_rows(payload) do
      rows when is_list(rows) -> rows
      :none -> [payload]
    end
  end

  defp coerce_collection_payload(payload, envelope_list?, _exchange, _dict_js_name),
    do: coerce_collection_payload(payload, envelope_list?)

  defp coerce_collection_payload(payload, true) when is_list(payload), do: payload

  defp coerce_collection_payload(payload, true) when is_map(payload) do
    case collection_rows(payload) do
      rows when is_list(rows) -> rows
      :none -> payload
    end
  end

  defp coerce_collection_payload(payload, false) when is_map(payload) do
    # Singular reads often wrap one row as data/list: [row]. Peel to a list so
    # normalize_payload/3 can take the first map; leave non-collection maps alone.
    case collection_rows(payload) do
      rows when is_list(rows) -> rows
      :none -> payload
    end
  end

  defp coerce_collection_payload(payload, _envelope_list?), do: payload

  defp collection_rows(map) when is_map(map) do
    case collection_rows_shallow(map) do
      rows when is_list(rows) ->
        rows

      :none ->
        case Map.get(map, "result") do
          nested when is_map(nested) -> collection_rows_shallow(nested)
          rows when is_list(rows) -> rows
          _ -> :none
        end
    end
  end

  defp collection_rows_shallow(map) when is_map(map) do
    Enum.find_value(@collection_keys, :none, fn key ->
      case Map.get(map, key) do
        rows when is_list(rows) -> rows
        _ -> nil
      end
    end)
  end

  # Attach Bybit pagination cursors only for methods that expose them
  # (fetchPositions / fetchOpenInterest). fetchPosition and closed-PnL history
  # parse list rows without the cursor.
  @bybit_pagination_cursor_methods ~w(fetchPositions fetchOpenInterest fetchOpenInterestHistory)
  @bybit_order_pagination_cursor_methods ~w(fetchClosedOrder fetchClosedOrders fetchOpenOrder fetchOpenOrders)

  defp merge_bybit_pagination_cursor(payload, body, %Exchange{id: "bybit"}, "order", js_name)
       when js_name in @bybit_order_pagination_cursor_methods do
    cursor = body |> get_in(["result", "nextPageCursor"]) |> non_empty_string()

    case {payload, cursor} do
      {[first | rest], cursor} when is_map(first) and is_binary(cursor) ->
        [Map.put(first, "nextPageCursor", cursor) | rest]

      {row, cursor} when is_map(row) and is_binary(cursor) ->
        Map.put(row, "nextPageCursor", cursor)

      _ ->
        payload
    end
  end

  defp merge_bybit_pagination_cursor(payload, body, %Exchange{id: "bybit"}, _parse_type, js_name)
       when js_name in @bybit_pagination_cursor_methods do
    cursor =
      body
      |> get_in(["result", "nextPageCursor"])
      |> non_empty_string()

    case {payload, cursor} do
      {rows, cursor} when is_list(rows) and is_binary(cursor) ->
        Enum.map(rows, &Map.put(&1, "nextPageCursor", cursor))

      {row, cursor} when is_map(row) and is_binary(cursor) ->
        Map.put(row, "nextPageCursor", cursor)

      _ ->
        payload
    end
  end

  defp merge_bybit_pagination_cursor(payload, _body, _exchange, _parse_type, _js_name), do: payload

  defp annotate_deribit_payload(payload, %Exchange{id: "deribit"} = exchange, parse_type)
       when parse_type in ["position", "trade"] do
    index = deribit_market_index(exchange)

    case payload do
      rows when is_list(rows) -> Enum.map(rows, &annotate_deribit_money_row(&1, index))
      %{} = row -> annotate_deribit_money_row(row, index)
      other -> other
    end
  end

  defp annotate_deribit_payload(payload, _exchange, _parse_type), do: payload

  defp annotate_deribit_money_row(row, index) when is_map(row) do
    maybe_put_synthetic(row, "_bourse_inverse", deribit_inverse_instrument?(row, index))
  end

  defp annotate_deribit_money_row(other, _index), do: other

  # Built once per payload: deribit lists ~5k instruments, so a per-row scan of
  # `exchange.markets` is quadratic on a multi-row read.
  defp deribit_market_index(%Exchange{markets: markets}) when is_list(markets) do
    Map.new(markets, &{deribit_market_id(&1), deribit_market_inverse?(&1)})
  end

  defp deribit_market_index(_exchange), do: %{}

  defp deribit_inverse_instrument?(%{"instrument_name" => name}, index) when is_binary(name) and is_map(index) do
    case Map.fetch(index, name) do
      {:ok, inverse?} -> inverse?
      :error -> deribit_inverse_instrument_id?(name)
    end
  end

  defp deribit_inverse_instrument?(_row, _index), do: false

  defp deribit_market_id(market) when is_map(market), do: Map.get(market, :id) || Map.get(market, "id")

  defp deribit_market_inverse?(market) when is_map(market) do
    Map.get(market, :inverse) == true or Map.get(market, "inverse") == true
  end

  # Degradation path when `exchange.markets` does not carry the row's instrument.
  # Positive identification of the inverse (USD-amount) book only; any other
  # shape answers false (the mul identity) because guessing inverse is the
  # direction that produces a squared money error. Linear ids put settle in
  # the first token (`ETH_USDC-PERPETUAL`). Single-leg options (`-C`/`-P`) and
  # option combos are base-coin amount. Future spreads (`-FS-`) on an inverse
  # book stay inverse.
  @doc "Deribit degradation-path inverse classifier for an instrument id."
  @spec deribit_inverse_instrument_id?(String.t()) :: boolean()
  def deribit_inverse_instrument_id?(name) when is_binary(name) do
    tokens = String.split(name, "-")

    cond do
      deribit_linear_id_prefix?(tokens) -> false
      deribit_option_id?(tokens) -> false
      deribit_future_spread_id?(tokens) -> true
      deribit_perpetual_id?(tokens) -> true
      deribit_dated_future_id?(tokens) -> true
      true -> false
    end
  end

  defp deribit_linear_id_prefix?([head | _rest]) when is_binary(head), do: String.contains?(head, "_")
  defp deribit_linear_id_prefix?(_tokens), do: false

  defp deribit_option_id?([_base, _expiry, _strike, suffix]) when suffix in ["C", "P"], do: true
  defp deribit_option_id?(_tokens), do: false

  defp deribit_future_spread_id?([_base, "FS" | _rest]), do: true
  defp deribit_future_spread_id?(_tokens), do: false

  defp deribit_perpetual_id?([_base, "PERPETUAL"]), do: true
  defp deribit_perpetual_id?(_tokens), do: false

  defp deribit_dated_future_id?([_base, expiry]) when is_binary(expiry) do
    String.match?(expiry, ~r/\A\d{1,2}[A-Z]{3}\d{2}\z/)
  end

  defp deribit_dated_future_id?(_tokens), do: false

  defp deribit_market_type(%{"kind" => "spot"}), do: :spot
  defp deribit_market_type(%{"kind" => "option"}), do: :option
  defp deribit_market_type(%{"kind" => "option_combo"}), do: :option
  defp deribit_market_type(%{"kind" => "future_combo"}), do: :future
  defp deribit_market_type(%{"settlement_period" => "perpetual"}), do: :swap

  defp deribit_market_type(%{"kind" => kind}) when is_binary(kind) do
    if String.contains?(kind, "future"), do: :future, else: :swap
  end

  defp deribit_market_type(_raw), do: :swap

  defp hyperliquid_market_symbol(name, raw, exchange) do
    base =
      raw
      |> Map.get("_bourse_base", name)
      |> to_string()
      |> String.replace(":", "-")
      |> market_currency_code(exchange)

    quote =
      raw
      |> Map.get("_bourse_quote", Map.get(raw, "collateralTokenName", "USDC"))
      |> market_currency_code(exchange)

    Symbol.build(base, quote) <> ":" <> quote
  end

  defp hyperliquid_spot_symbol(raw, exchange) when is_map(raw) do
    base = raw |> Map.get("_bourse_base") |> market_currency_code_or_nil(exchange)
    quote = raw |> Map.get("_bourse_quote", "USDC") |> market_currency_code_or_nil(exchange)

    cond do
      is_binary(base) and is_binary(quote) ->
        Symbol.build(base, quote)

      is_binary(Map.get(raw, "name")) and String.contains?(Map.get(raw, "name"), "/") ->
        raw
        |> Map.get("name")
        |> String.split("/", parts: 2)
        |> case do
          [b, q] -> Symbol.build(market_currency_code(b, exchange), market_currency_code(q, exchange))
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp market_currency_code_or_nil(id, exchange) when is_binary(id) and id != "", do: market_currency_code(id, exchange)

  defp market_currency_code_or_nil(_id, _exchange), do: nil

  defp bybit_market_symbol(base, quote, raw, exchange) do
    base = market_currency_code(base, exchange)
    quote = market_currency_code(quote, exchange)

    cond do
      # Option instrument ids are BASE-DDMMMYY-STRIKE-C/P[-SETTLE]; reverse through
      # the option pattern. Collapsing to base/quote would drop strike/expiry and
      # make the symbol index unusable for fetch_option / option chain lookups.
      Map.get(raw, "category") == "option" or is_binary(Map.get(raw, "optionsType")) ->
        case Map.get(raw, "symbol") do
          id when is_binary(id) and id != "" -> Symbol.from_exchange_id(id, exchange, :option)
          _ -> nil
        end

      Map.get(raw, "contractType") in ["LinearPerpetual", "InversePerpetual", "LinearFutures", "InverseFutures"] ->
        settle = raw |> Map.get("settleCoin", quote) |> market_currency_code(exchange)
        suffix = bybit_expiry_suffix(raw)
        Symbol.build(base, quote) <> ":" <> settle <> suffix

      true ->
        Symbol.build(base, quote)
    end
  end

  defp bybit_expiry_suffix(%{"deliveryTime" => delivery}) when delivery in [nil, "", "0", 0], do: ""

  defp bybit_expiry_suffix(%{"deliveryTime" => delivery}) when is_binary(delivery) or is_integer(delivery) do
    case Bourse.Safe.integer(delivery) do
      nil -> ""
      0 -> ""
      ms when ms > 0 -> "-" <> bybit_yymmdd(ms)
    end
  end

  defp bybit_expiry_suffix(_raw), do: ""

  defp bybit_yymmdd(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%y%m%d")
  end

  defp lighter_market_symbol(sym, raw, exchange) do
    cond do
      String.contains?(sym, "/") ->
        sym

      Map.get(raw, "market_type") in ["perp", "swap"] ->
        base = market_currency_code(sym, exchange)
        Symbol.build(base, "USDC") <> ":USDC"

      true ->
        market_currency_code(sym, exchange)
    end
  end

  defp market_currency_code(id, %Exchange{common_currencies: aliases}) when is_binary(id) do
    up = String.upcase(id)
    Map.get(aliases, up, up)
  end

  @doc """
  Builds a symbol-keyed tickers dict from metaAndAssetCtxs-style payloads.

  Pairs each `universe` entry with its asset context, resolves unified symbols
  via the carved-market backfill path, and parses each row into `%Ticker{}`.
  """
  @spec build_tickers_from_meta_asset_ctxs(Exchange.t(), module(), term()) ::
          {:ok, map()} | {:error, term()}
  def build_tickers_from_meta_asset_ctxs(%Exchange{} = exchange, module, [meta, ctxs])
      when is_map(meta) and is_list(ctxs) do
    universe = Map.get(meta, "universe", [])

    tickers =
      universe
      |> Enum.zip(ctxs)
      |> Enum.reduce(%{}, fn {market_raw, ctx_raw}, acc ->
        case build_ticker_from_market_ctx(exchange, module, market_raw, ctx_raw) do
          {:ok, symbol, %Ticker{} = ticker} when is_binary(symbol) ->
            Map.put(acc, symbol, ticker)

          _ ->
            acc
        end
      end)

    {:ok, tickers}
  end

  @doc """
  Keys tickers by carved market symbols when entries lack a unified `:symbol`.

  Zips tickers with markets by index when lengths match; otherwise matches on
  an existing ticker `:symbol` or leaves unkeyed rows out of the result.
  """
  @spec index_tickers_by_markets(list(), list()) :: map()
  def index_tickers_by_markets(tickers, markets) when is_list(tickers) and is_list(markets) do
    pairs =
      if length(tickers) == length(markets) do
        Enum.zip(tickers, markets)
      else
        Enum.map(tickers, &{&1, nil})
      end

    Enum.reduce(pairs, %{}, fn {ticker, market}, acc ->
      symbol = ticker_symbol_for_index(ticker, market)

      if is_binary(symbol) do
        Map.put(acc, symbol, Map.put(ticker, :symbol, symbol))
      else
        acc
      end
    end)
  end

  @doc "Rekeys parsed ticker structs from native market ids to unified symbols."
  @spec index_tickers_by_market_id(map(), list()) :: map()
  def index_tickers_by_market_id(tickers, markets) when is_map(tickers) and is_list(markets) do
    symbols_by_id =
      Map.new(markets, fn market ->
        {Map.get(market, :id) || Map.get(market, "id"), market_identity_symbol(market)}
      end)

    Map.new(tickers, fn {key, ticker} ->
      native = Map.get(ticker.info, "symbol") || key
      symbol = Map.get(symbols_by_id, native, key)
      {symbol, Map.put(ticker, :symbol, symbol)}
    end)
  end

  defp market_identity_symbol(%{base: base, quote: quote}) when is_binary(base) and is_binary(quote),
    do: Symbol.build(base, quote)

  defp market_identity_symbol(market), do: Map.get(market, :symbol) || Map.get(market, "symbol")

  defp build_ticker_from_market_ctx(exchange, module, market_raw, ctx_raw) do
    symbol = market_symbol_from_raw(market_raw, exchange, market_type_atom(market_type_from_raw(market_raw)))

    with {:ok, ticker} <- invoke_parser(module, :parse_ticker, ctx_raw, []) do
      ticker = backfill_ticker_price_fields(ticker, ctx_raw)
      merged = Map.merge(ctx_raw, market_raw)
      {:ok, symbol, enrich_struct(%{ticker | symbol: symbol}, merged)}
    end
  end

  defp ticker_symbol_for_index(%Ticker{symbol: symbol}, _market) when is_binary(symbol), do: symbol

  defp ticker_symbol_for_index(_ticker, %{symbol: symbol}) when is_binary(symbol), do: symbol

  defp ticker_symbol_for_index(_ticker, %{"symbol" => symbol}) when is_binary(symbol), do: symbol

  defp ticker_symbol_for_index(_ticker, _market), do: nil

  defp backfill_ticker_price_fields(%Ticker{last: nil} = ticker, raw) when is_map(raw) do
    last =
      raw
      |> Map.get("markPx", Map.get(raw, "midPx", Map.get(raw, "price")))
      |> Bourse.Safe.number()

    %{ticker | last: last}
  end

  defp backfill_ticker_price_fields(ticker, _raw), do: ticker

  defp enrich(parsed, raw_payload, true) when is_list(parsed) do
    parsed
    |> Enum.zip(List.wrap(raw_payload))
    |> Enum.map(fn {struct, raw} -> enrich_struct(struct, raw) end)
  end

  defp enrich(parsed, raw_payload, _list_return?) do
    enrich_struct(parsed, raw_payload)
  end

  defp enrich_struct(%{__struct__: Bourse.Trade} = trade, raw) do
    trade
    |> put_info(venue_info_echo(raw))
    |> put_datetime()
    |> put_trade_fees()
  end

  # Every venue order carries a
  # `fee` object and a `fees` list derived from it. Unlike put_trade_fees/1, this
  # leaves `fee.cost` as the venue string and coerces only the `fees[]` entry.
  defp enrich_struct(%{__struct__: Bourse.Order} = order, raw) do
    order
    |> put_info(venue_info_echo(raw))
    |> put_datetime()
    |> put_order_fees()
  end

  # Bybit funding-rate parsing omits the fixture-injected `timestamp` key from
  # `info` (`this.omit(ticker, 'timestamp')`) so the raw echo matches the wire
  # ticker without the artificial clock stamp.
  defp enrich_struct(%{__struct__: Bourse.FundingRate} = fr, raw) when is_map(raw) do
    fr
    |> put_info(Map.delete(raw, "timestamp"))
    |> put_datetime()
  end

  # hourlyBorrowRate means a one-hour period; otherwise use one day.
  defp enrich_struct(%{__struct__: Bourse.BorrowRate} = br, raw) when is_map(raw) do
    period =
      case Bourse.Safe.number(Map.get(raw, "hourlyBorrowRate")) do
        rate when is_number(rate) -> 3_600_000
        _ -> br.period || 86_400_000
      end

    br
    |> put_info(raw)
    |> put_datetime()
    |> Map.put(:period, period)
  end

  defp enrich_struct(%{__struct__: Bourse.Position} = position, raw) do
    position
    |> put_info(venue_info_echo(raw))
    |> put_datetime()
  end

  # Keep venue source timestamp and local observation time distinct so callers
  # can apply freshness policy without rewriting provider data.
  defp enrich_struct(%{__struct__: Bourse.Greeks} = greeks, raw) do
    greeks
    |> put_info(raw)
    |> put_datetime()
    |> stamp_observed_at()
  end

  defp enrich_struct(%{__struct__: Bourse.OptionData} = option, raw) do
    option
    |> put_info(raw)
    |> put_datetime()
    |> stamp_observed_at()
  end

  defp enrich_struct(%{__struct__: Bourse.TradingFee} = fee, raw) do
    put_info(fee, venue_info_echo(raw))
  end

  defp enrich_struct(%{__struct__: Bourse.Transaction} = tx, raw) do
    tx
    |> put_info(venue_info_echo(raw))
    |> put_datetime()
    |> clear_empty_transaction_fee()
  end

  # Drop synthetic annotation keys (e.g. `_bourse_asset_index`) from market info so
  # the raw wire echo stays free of parser scaffolding (task 339).
  defp enrich_struct(%{__struct__: Bourse.Market} = market, raw) when is_map(raw) do
    market
    |> put_info(strip_bourse_synthetic_keys(raw))
    |> put_datetime()
  end

  defp enrich_struct(%{__struct__: _} = struct, raw) do
    struct
    |> put_info(raw)
    |> put_datetime()
  end

  defp enrich_struct(other, _raw), do: other

  defp clear_empty_transaction_fee(%{fee: fee} = tx) when fee in [%{}, nil], do: %{tx | fee: nil}
  defp clear_empty_transaction_fee(%{fee: %{"cost" => nil, "currency" => nil}} = tx), do: %{tx | fee: nil}

  defp clear_empty_transaction_fee(%{fee: %{"currency" => _currency} = fee} = tx) when map_size(fee) == 1,
    do: %{tx | fee: nil}

  defp clear_empty_transaction_fee(tx), do: tx

  # Transforms and annotations may stamp `_bourse_info` with the venue-raw echo.
  # Prefer that over the flattened parse row.
  # Always drop `_bourse_*` synthetic keys so `info` stays a pure venue echo.
  defp venue_info_echo(%{"_bourse_info" => info}) when is_map(info), do: strip_bourse_synthetic_keys(info)
  defp venue_info_echo(raw) when is_map(raw), do: strip_bourse_synthetic_keys(raw)
  defp venue_info_echo(raw), do: raw

  defp strip_bourse_synthetic_keys(map) when is_map(map) do
    Map.reject(map, fn {key, _} -> is_binary(key) and String.starts_with?(key, "_bourse_") end)
  end

  defp hyperliquid_create_order_ack?(%{info: %{"filled" => filled}}) when is_map(filled), do: true
  defp hyperliquid_create_order_ack?(%{info: %{"resting" => resting}}) when is_map(resting), do: true
  defp hyperliquid_create_order_ack?(_), do: false

  # A trade always carries a `fee`
  # object and a `fees` list. With no authored fee, both default (fee to a
  # null-cost/null-currency object, fees to `[]`); a single authored fee map
  # becomes `fee` (cost coerced numeric) and the sole entry of `fees`.
  # reduceFees / multi-fee aggregation is exchange-specific and unexercised here.
  defp put_trade_fees(%{__struct__: Bourse.Trade, fee: fee} = trade) do
    {result_fee, result_fees} = parsed_fee_and_fees(fee)
    %{trade | fee: result_fee, fees: result_fees}
  end

  defp put_order_fees(%{__struct__: Bourse.Order, fee: fee} = order) when is_map(fee) do
    cost = Bourse.Safe.number(Map.get(fee, "cost"))
    currency = Map.get(fee, "currency")

    fees =
      if is_nil(cost) and is_nil(currency) do
        []
      else
        [%{"cost" => cost, "currency" => currency}]
      end

    %{order | fees: fees}
  end

  defp put_order_fees(order), do: order

  # Derive position rows carry a signed `amount` (negative = short). Use
  # abs(amount) for contracts and abs(amount)*mark_price for notional. Stamp the
  # absolute size so the authored field map can compute notional without a
  # second abs pass on a product.
  defp annotate_derive_payload(rows, %Exchange{id: "derive"}, "position") when is_list(rows) do
    Enum.map(rows, &annotate_derive_position_row/1)
  end

  defp annotate_derive_payload(rows, %Exchange{id: "derive"}, "market") when is_list(rows) do
    Enum.map(rows, &annotate_derive_market_row/1)
  end

  defp annotate_derive_payload(%{} = row, %Exchange{id: "derive"}, "position") do
    annotate_derive_position_row(row)
  end

  defp annotate_derive_payload(%{} = row, %Exchange{id: "derive"}, "market") do
    annotate_derive_market_row(row)
  end

  defp annotate_derive_payload(payload, _exchange, _parse_type), do: payload

  defp annotate_derive_market_row(%{"instrument_type" => instrument_type} = row) do
    row
    |> Map.put("_bourse_market_type", derive_market_type(instrument_type))
    |> Map.put("_bourse_settle", derive_market_settle(instrument_type, row))
    |> Map.put("_bourse_symbol", derive_market_symbol(instrument_type, row))
    |> Map.merge(derive_market_flags(instrument_type))
    |> Map.merge(derive_option_fields(instrument_type, row))
  end

  defp annotate_derive_market_row(row), do: row

  defp derive_market_type("erc20"), do: "spot"
  defp derive_market_type("perp"), do: "swap"
  defp derive_market_type("option"), do: "option"
  defp derive_market_type(_), do: nil

  defp derive_market_settle("erc20", _row), do: nil
  defp derive_market_settle("perp", _row), do: "USDC"
  defp derive_market_settle("option", row), do: row["quote_currency"]
  defp derive_market_settle(_, _row), do: nil

  defp derive_market_symbol("erc20", %{"base_currency" => base, "quote_currency" => quote}), do: Symbol.build(base, quote)

  defp derive_market_symbol("perp", %{"base_currency" => base, "quote_currency" => quote}),
    do: Symbol.build(base, quote, "USDC")

  defp derive_market_symbol("option", %{"instrument_name" => name, "quote_currency" => quote}) do
    case Regex.run(~r/^([^-]+)-(\d{8})-([^-]+)-([CP])$/, name) do
      [_, base, <<_year::binary-size(2), expiry::binary-size(6)>>, strike, option_type] ->
        Symbol.build(base, quote, "#{quote}-#{expiry}-#{strike}-#{option_type}")

      _ ->
        name
    end
  end

  defp derive_market_symbol(_, %{"instrument_name" => name}) when is_binary(name), do: name
  defp derive_market_symbol(_, _row), do: nil

  defp derive_market_flags("erc20"),
    do: %{
      "_bourse_contract" => false,
      "_bourse_inverse" => false,
      "_bourse_linear" => false,
      "_bourse_option" => false,
      "_bourse_spot" => true,
      "_bourse_swap" => false
    }

  defp derive_market_flags("perp"),
    do: %{
      "_bourse_contract" => true,
      "_bourse_inverse" => false,
      "_bourse_linear" => true,
      "_bourse_option" => false,
      "_bourse_spot" => false,
      "_bourse_swap" => true
    }

  defp derive_market_flags("option"),
    do: %{
      "_bourse_contract" => true,
      "_bourse_inverse" => false,
      "_bourse_linear" => true,
      "_bourse_option" => true,
      "_bourse_spot" => false,
      "_bourse_swap" => false
    }

  defp derive_market_flags(_), do: %{}

  defp derive_option_fields("option", %{"option_details" => details}) when is_map(details) do
    %{
      "_bourse_expiry" => scale_option_expiry(details["expiry"]),
      "_bourse_option_type" => details["option_type"],
      "_bourse_strike" => details["strike"]
    }
  end

  defp derive_option_fields(_, _row), do: %{}

  defp scale_option_expiry(expiry) when is_integer(expiry), do: expiry * @milliseconds_per_second
  defp scale_option_expiry(expiry), do: expiry

  # ---------------------------------------------------------------------------
  # Hyperliquid response annotation (task 302) — flatten nested order/position
  # wrappers, create-order statuses, unit-fee sums, deposit/withdraw type
  # filters, and oid-dedup. Field maps then read flat/synthetic keys.
  # ---------------------------------------------------------------------------

  defp annotate_hyperliquid_payload(payload, %Exchange{id: "hyperliquid"} = exchange, parse_type, js_name, _params) do
    annotate_hyperliquid_by_type(parse_type, payload, exchange, js_name)
  end

  defp annotate_hyperliquid_payload(payload, _exchange, _parse_type, _js_name, _params), do: payload

  defp annotate_hyperliquid_by_type("market", payload, exchange, _js), do: annotate_hyperliquid_markets(payload, exchange)

  defp annotate_hyperliquid_by_type("ticker", payload, exchange, _js),
    do: annotate_hyperliquid_ctx_rows(payload, exchange, :ticker)

  defp annotate_hyperliquid_by_type("funding_rate", payload, exchange, _js),
    do: annotate_hyperliquid_ctx_rows(payload, exchange, :funding_rate)

  defp annotate_hyperliquid_by_type("open_interest", payload, exchange, _js),
    do: annotate_hyperliquid_ctx_rows(payload, exchange, :open_interest)

  defp annotate_hyperliquid_by_type("funding_history", payload, _exchange, _js),
    do: annotate_hyperliquid_funding_history(payload)

  defp annotate_hyperliquid_by_type("order", payload, _exchange, js), do: annotate_hyperliquid_orders(payload, js)
  defp annotate_hyperliquid_by_type("position", payload, _exchange, _js), do: annotate_hyperliquid_positions(payload)
  defp annotate_hyperliquid_by_type("trade", payload, _exchange, _js), do: annotate_hyperliquid_trades(payload)

  defp annotate_hyperliquid_by_type("transaction", payload, _exchange, js),
    do: annotate_hyperliquid_transactions(payload, js)

  defp annotate_hyperliquid_by_type("trading_fee", payload, exchange, _js),
    do: annotate_hyperliquid_trading_fee(payload, exchange)

  defp annotate_hyperliquid_by_type(_type, payload, _exchange, _js), do: payload

  # Hyperliquid asset IDs are not on the wire as a field; they are the
  # position (and official offsets) in meta / spotMeta universe. Annotate each
  # row before the field map so Market.asset_index is populated on live load.
  # Authority: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/asset-ids
  #   perps: index in meta.universe
  #   spot:  10000 + spotMeta.universe[].index
  #   HIP-3: 100000 + perp_dex_index * 10000 + index_in_meta
  #
  # metaAndAssetCtxs / spotMetaAndAssetCtxs arrive as `[meta, ctxs]`. Expand to
  # one row per universe entry (zipped with asset ctx) before field-map parse —
  # without this, backfill_market_symbol/3 crashes on the raw ctx list.
  defp annotate_hyperliquid_markets([%{"universe" => universe} = meta, ctxs], exchange)
       when is_list(universe) and is_list(ctxs) do
    if is_list(Map.get(meta, "tokens")) do
      expand_hyperliquid_spot_markets(meta, ctxs, exchange)
    else
      expand_hyperliquid_swap_markets(meta, ctxs, exchange)
    end
  end

  defp annotate_hyperliquid_markets(%{"universe" => universe} = body, exchange) when is_list(universe) do
    cond do
      is_list(Map.get(body, "tokens")) ->
        expand_hyperliquid_spot_markets(body, [], exchange)

      # Bare `{universe: spotRows}` (tests / partial payloads): spot rows carry
      # `tokens[]` even when the tokens table is absent — still annotate as spot
      # so asset_index uses the 10000+ rule.
      hyperliquid_spot_universe?(universe) ->
        universe
        |> Enum.with_index()
        |> Enum.map(fn
          {row, index} when is_map(row) ->
            row
            |> Map.put("_bourse_type", "spot")
            |> Map.put("_bourse_spot", true)
            |> Map.put("_bourse_swap", false)
            |> Map.put("_bourse_contract", false)
            |> Map.put("_bourse_active", true)
            |> Map.put("_bourse_asset_index", hyperliquid_asset_index_for_row(row, index))
            |> annotate_hyperliquid_spot_name_components(exchange)

          {row, _index} ->
            row
        end)

      true ->
        expand_hyperliquid_swap_markets(body, [], exchange)
    end
  end

  defp annotate_hyperliquid_markets(rows, exchange) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn
      {row, index} when is_map(row) ->
        annotate_hyperliquid_market_row(row, index, exchange)

      {row, _index} ->
        row
    end)
  end

  defp annotate_hyperliquid_markets(%{} = row, exchange) do
    annotate_hyperliquid_market_row(row, 0, exchange)
  end

  defp annotate_hyperliquid_markets(payload, _exchange), do: payload

  defp hyperliquid_spot_universe?([%{"tokens" => tokens} | _]) when is_list(tokens), do: true
  defp hyperliquid_spot_universe?(_), do: false

  # When only pair name is available (PURR/USDC), split it; otherwise leave base/quote
  # nil so field maps don't invent codes (e.g. bare "@1" testnet rows).
  defp annotate_hyperliquid_spot_name_components(%{"name" => name} = row, exchange) when is_binary(name) do
    case String.split(name, "/", parts: 2) do
      [base, quote] ->
        row
        |> Map.put("_bourse_base", hyperliquid_mapped_currency(base, exchange))
        |> Map.put("_bourse_quote", hyperliquid_mapped_currency(quote, exchange))
        |> Map.put("_bourse_quote_id", quote)
        |> Map.put("_bourse_id", name)

      _ ->
        Map.put(row, "_bourse_id", name)
    end
  end

  defp annotate_hyperliquid_spot_name_components(row, _exchange), do: row

  # metaAndAssetCtxs for tickers / funding rates: zip universe + asset ctxs into
  # one list so field maps + symbol backfill produce a symbol-keyed dict.
  defp annotate_hyperliquid_ctx_rows([%{"universe" => universe} = meta, ctxs], exchange, kind)
       when is_list(universe) and is_list(ctxs) do
    if_result =
      if is_list(Map.get(meta, "tokens")) do
        expand_hyperliquid_spot_markets(meta, ctxs, exchange)
      else
        expand_hyperliquid_swap_markets(meta, ctxs, exchange)
      end

    maybe_keep_funding_only(if_result, kind)
  end

  defp annotate_hyperliquid_ctx_rows(payload, _exchange, _kind), do: payload

  defp maybe_keep_funding_only(rows, :funding_rate) when is_list(rows) do
    Enum.filter(rows, fn
      %{"_bourse_type" => "swap"} -> true
      %{"maxLeverage" => _} -> true
      _ -> false
    end)
  end

  defp maybe_keep_funding_only(rows, _kind), do: rows

  defp expand_hyperliquid_swap_markets(meta, ctxs, exchange) when is_map(meta) and is_list(ctxs) do
    universe = Map.get(meta, "universe", [])
    collateral = Map.get(meta, "collateralTokenName") || Map.get(meta, "collateralToken")

    ctx_by_index = by_position(ctxs)

    universe
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      row
      |> merge_ctx(Map.get(ctx_by_index, index))
      |> Map.put_new("baseId", Integer.to_string(index))
      |> maybe_put_collateral_token_name(collateral)
      |> annotate_hyperliquid_market_row(index, exchange)
    end)
  end

  defp expand_hyperliquid_spot_markets(meta, ctxs, exchange) when is_map(meta) and is_list(ctxs) do
    universe = Map.get(meta, "universe", [])
    # Both the tokens table and the ctx list are addressed by POSITION from every
    # universe row; index them once instead of walking the list per row.
    tokens = meta |> Map.get("tokens", []) |> by_position()
    ctx_by_index = by_position(ctxs)

    universe
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, list_index} ->
      case build_hyperliquid_spot_row(row, tokens, ctx_by_index, list_index, exchange) do
        %{} = annotated -> [annotated]
        _ -> []
      end
    end)
  end

  # Merges an asset-ctx row into its universe row. Either side may be absent or
  # a non-map (short/ragged ctx lists) — always yields a map.
  defp merge_ctx(row, ctx) when is_map(row) and is_map(ctx), do: Map.merge(row, ctx)
  defp merge_ctx(row, _ctx) when is_map(row), do: row
  defp merge_ctx(_row, _ctx), do: %{}

  defp build_hyperliquid_spot_row(row, tokens, ctx_by_index, list_index, exchange) when is_map(row) do
    index = Bourse.Safe.integer(Map.get(row, "index")) || list_index
    ctx = Map.get(ctx_by_index, index)
    {base_info, quote_info} = hyperliquid_spot_pair_tokens(row, tokens)
    base_name = Map.get(base_info || %{}, "name")
    quote_name = Map.get(quote_info || %{}, "name")

    if is_binary(base_name) and is_binary(quote_name) do
      base = hyperliquid_mapped_currency(base_name, exchange)
      quote = hyperliquid_mapped_currency(quote_name, exchange)
      sz_decimals = Map.get(base_info || %{}, "szDecimals")
      mid_px = if is_map(ctx), do: Map.get(ctx, "midPx") || Map.get(ctx, "markPx")
      price_tick = hyperliquid_price_tick(mid_px, sz_decimals, 8)
      market_name = Map.get(row, "name")
      base_id = Integer.to_string(10_000 + index)

      row
      |> merge_ctx(ctx)
      |> Map.put("_bourse_asset_index", 10_000 + index)
      |> Map.put("_bourse_type", "spot")
      |> Map.put("_bourse_spot", true)
      |> Map.put("_bourse_swap", false)
      |> Map.put("_bourse_contract", false)
      |> Map.put("_bourse_linear", nil)
      |> Map.put("_bourse_inverse", nil)
      |> Map.put("_bourse_active", true)
      |> Map.put("_bourse_base", base)
      |> Map.put("_bourse_quote", quote)
      |> Map.put("_bourse_quote_id", quote_name)
      |> Map.put("_bourse_settle", nil)
      |> Map.put("_bourse_settle_id", nil)
      |> Map.put("_bourse_id", market_name)
      |> Map.put("_bourse_base_id", base_id)
      |> Map.put("baseId", base_id)
      |> Map.put("_bourse_sz_decimals", sz_decimals)
      |> Map.put("szDecimals", sz_decimals)
      |> Map.put("_bourse_price_tick", price_tick)
      |> Map.put("_bourse_taker", 0.0007)
      |> Map.put("_bourse_maker", 0.0004)
      |> Map.put("_bourse_contract_size", nil)
    end
  end

  defp build_hyperliquid_spot_row(_row, _tokens, _ctx_by_index, _list_index, _exchange), do: nil

  # Spot universe rows name their pair by POSITION into spotMeta.tokens[]:
  # `tokens: [baseTokenIndex, quoteTokenIndex]`.
  defp hyperliquid_spot_pair_tokens(row, tokens) do
    case List.wrap(Map.get(row, "tokens")) do
      [base_pos, quote_pos | _] -> {token_at(tokens, base_pos), token_at(tokens, quote_pos)}
      [base_pos] -> {token_at(tokens, base_pos), nil}
      [] -> {nil, nil}
    end
  end

  defp token_at(tokens, pos) when is_map(tokens) and is_integer(pos) and pos >= 0, do: Map.get(tokens, pos)
  defp token_at(tokens, pos) when is_map(tokens) and is_binary(pos), do: token_at(tokens, Bourse.Safe.integer(pos))
  defp token_at(_tokens, _pos), do: nil

  # Positional index of a wire list, so repeated `at`-style reads stay O(1).
  defp by_position(list) when is_list(list) do
    list |> Enum.with_index() |> Map.new(fn {item, index} -> {index, item} end)
  end

  defp by_position(_other), do: %{}

  defp annotate_hyperliquid_market_row(row, list_index, exchange) when is_map(row) do
    if is_list(Map.get(row, "tokens")) or Map.get(row, "_bourse_type") == "spot" do
      # Already fully annotated by expand_hyperliquid_spot_markets, or a bare
      # spot universe row without tokens table (can't resolve base/quote).
      row
      |> Map.put_new("_bourse_asset_index", hyperliquid_asset_index_for_row(row, list_index))
      |> Map.put_new("_bourse_type", "spot")
    else
      annotate_hyperliquid_swap_row(row, list_index, exchange)
    end
  end

  defp annotate_hyperliquid_swap_row(row, list_index, exchange) when is_map(row) do
    name = Map.get(row, "name")

    quote =
      row
      |> Map.get("collateralTokenName", "USDC")
      |> hyperliquid_mapped_currency(exchange)

    base =
      name
      |> to_string()
      |> String.replace(":", "-")
      |> hyperliquid_mapped_currency(exchange)

    base_id =
      case Map.get(row, "baseId") do
        id when is_binary(id) and id != "" -> id
        id when is_integer(id) -> Integer.to_string(id)
        _ -> Integer.to_string(list_index)
      end

    sz_decimals = Map.get(row, "szDecimals")
    mark_px = Map.get(row, "markPx") || Map.get(row, "midPx")
    price_tick = hyperliquid_price_tick(mark_px, sz_decimals, 6)
    active = Map.get(row, "isDelisted") not in [true, "true"]
    {bid, ask} = hyperliquid_impact_bid_ask(row)

    row
    |> Map.put("_bourse_asset_index", hyperliquid_asset_index_for_row(row, list_index))
    |> Map.put("_bourse_type", "swap")
    |> Map.put("_bourse_spot", false)
    |> Map.put("_bourse_swap", true)
    |> Map.put("_bourse_contract", true)
    |> Map.put("_bourse_linear", true)
    |> Map.put("_bourse_inverse", false)
    |> Map.put("_bourse_active", active)
    |> Map.put("_bourse_base", base)
    |> Map.put("_bourse_quote", quote)
    |> Map.put("_bourse_quote_id", quote)
    |> Map.put("_bourse_settle", quote)
    |> Map.put("_bourse_settle_id", quote)
    |> Map.put("_bourse_id", base_id)
    |> Map.put("_bourse_base_id", base_id)
    |> Map.put_new("baseId", base_id)
    |> Map.put("_bourse_price_tick", price_tick)
    |> Map.put("_bourse_taker", 0.00045)
    |> Map.put("_bourse_maker", 0.00015)
    |> Map.put("_bourse_contract_size", 1)
    |> maybe_put_synthetic("_bourse_bid", bid)
    |> maybe_put_synthetic("_bourse_ask", ask)
  end

  defp hyperliquid_impact_bid_ask(%{"impactPxs" => [bid, ask | _]}), do: {bid, ask}
  defp hyperliquid_impact_bid_ask(_), do: {nil, nil}

  defp hyperliquid_mapped_currency(name, %Exchange{} = exchange) when is_binary(name) do
    mapped = Map.get(hyperliquid_spot_currency_mapping(), name, name)
    market_currency_code(mapped, exchange)
  end

  defp hyperliquid_mapped_currency(name, _exchange) when is_binary(name), do: String.upcase(name)
  defp hyperliquid_mapped_currency(_name, _exchange), do: nil

  # Hyperliquid tick size = 10^-(min(maxDecimals - szDecimals, significant)).
  # Enough for populated precision.price on live metaAndAssetCtxs; meta-only rows stay nil.
  defp hyperliquid_price_tick(price, sz_decimals, max_decimals) do
    amount_precision = Bourse.Safe.integer(sz_decimals)

    with price when is_number(price) and price > 0 <- Bourse.Safe.number(price),
         amount_precision when is_integer(amount_precision) and amount_precision >= 0 <- amount_precision do
      price_precision = hyperliquid_price_precision_digits(price, amount_precision, max_decimals)

      if price_precision >= 0 do
        :math.pow(10, -price_precision)
      end
    else
      _ -> nil
    end
  end

  defp hyperliquid_price_precision_digits(price, amount_precision, max_decimals)
       when is_number(price) and is_integer(amount_precision) and is_integer(max_decimals) do
    budget = max_decimals - amount_precision

    digits =
      cond do
        price >= 1 ->
          integer_digits = price |> trunc() |> Integer.to_string() |> String.length()
          max(5, integer_digits) - integer_digits

        price > 0 ->
          # leading zeros after decimal + 5 significant digits
          frac =
            price
            |> :erlang.float_to_binary(decimals: 18)
            |> String.split(".", parts: 2)
            |> case do
              [_, f] -> f
              _ -> ""
            end

          leading_zeros(frac) + 5

        true ->
          5
      end

    min(budget, max(digits, 0))
  end

  defp leading_zeros(<<?0, rest::binary>>), do: 1 + leading_zeros(rest)
  defp leading_zeros(_binary), do: 0

  defp maybe_put_collateral_token_name(row, collateral) when is_binary(collateral) and collateral != "" do
    Map.put_new(row, "collateralTokenName", collateral)
  end

  defp maybe_put_collateral_token_name(row, _collateral), do: row

  defp hyperliquid_asset_index_for_row(row, list_index) when is_map(row) and is_integer(list_index) do
    cond do
      # Spot universe rows carry tokens[] and an explicit pair index.
      is_list(Map.get(row, "tokens")) or Map.get(row, "_bourse_type") == "spot" ->
        spot_index = Bourse.Safe.integer(Map.get(row, "index")) || list_index
        10_000 + spot_index

      # Builder-deployed (HIP-3) perps: name is always "{dex}:{coin}".
      hyperliquid_hip3_name?(Map.get(row, "name")) ->
        dex_index = hyperliquid_perp_dex_index(row)
        index_in_meta = Bourse.Safe.integer(Map.get(row, "index")) || list_index
        100_000 + dex_index * 10_000 + index_in_meta

      # Main perp dex: universe array position.
      true ->
        list_index
    end
  end

  defp hyperliquid_hip3_name?(name) when is_binary(name), do: String.contains?(name, ":")
  defp hyperliquid_hip3_name?(_), do: false

  defp hyperliquid_perp_dex_index(row) when is_map(row) do
    case Map.get(row, "perpDexIndex") || Map.get(row, "perp_dex_index") || Map.get(row, "_perp_dex_index") do
      idx when is_integer(idx) and idx >= 0 -> idx
      idx when is_binary(idx) -> Bourse.Safe.integer(idx) || 0
      _ -> 0
    end
  end

  defp annotate_hyperliquid_orders(payload, js_name) do
    unwrapped = unwrap_hyperliquid_order_status(payload, js_name)

    annotated =
      if is_list(unwrapped) do
        Enum.map(unwrapped, fn row -> annotate_hyperliquid_order_row(row) end)
      else
        annotate_hyperliquid_order_row(unwrapped)
      end

    maybe_dedup_hyperliquid_orders(annotated, js_name)
  end

  # Order actions use {status, response: {data: {statuses: [...]}}}. Create
  # acks carry order rows, while cancel acks carry the literal "success".
  defp unwrap_hyperliquid_order_status(%{"response" => %{"data" => %{"statuses" => statuses}}}, js_name)
       when is_list(statuses) and js_name in ["createOrder", "createOrders", "createOrderWithTakeProfitAndStopLoss"] do
    case List.first(statuses) do
      %{} = status ->
        Map.put(status, "_bourse_multi_status", length(statuses) > 1)

      other ->
        other
    end
  end

  defp unwrap_hyperliquid_order_status(%{"response" => %{"data" => %{"statuses" => statuses}}}, "cancelOrder")
       when is_list(statuses) do
    statuses
    |> List.first()
    |> hyperliquid_cancel_status()
  end

  defp unwrap_hyperliquid_order_status(%{"response" => %{"data" => %{"statuses" => statuses}}}, "cancelOrders")
       when is_list(statuses) do
    Enum.map(statuses, &hyperliquid_cancel_status/1)
  end

  defp unwrap_hyperliquid_order_status(payload, _js_name), do: payload

  defp hyperliquid_cancel_status("success"), do: %{"status" => "canceled"}
  defp hyperliquid_cancel_status(status), do: status

  defp reject_hyperliquid_order_rejection(
         %{"response" => %{"data" => %{"statuses" => statuses}}} = body,
         %Exchange{id: "hyperliquid"},
         js_name
       )
       when js_name in [
              "createOrder",
              "createOrders",
              "createOrderWithTakeProfitAndStopLoss",
              "cancelOrder",
              "cancelOrders"
            ] and is_list(statuses) do
    case Enum.find_value(statuses, fn
           %{"error" => message} when is_binary(message) and message != "" -> message
           _ -> nil
         end) do
      nil -> :ok
      message -> {:error, Error.exchange_error(message, exchange: "hyperliquid", raw: body)}
    end
  end

  # TWAP acks nest a singular `status` map rather than the `statuses` list the
  # order actions use, and a rejection still arrives under HTTP 200 with a
  # top-level "status" => "ok" — so the venue message has to be lifted here or
  # it is lost and the row parses to an all-nil struct.
  defp reject_hyperliquid_order_rejection(
         %{"response" => %{"data" => %{"status" => %{"error" => message}}}} = body,
         %Exchange{id: "hyperliquid"},
         "createTwapOrder"
       )
       when is_binary(message) and message != "" do
    {:error, Error.exchange_error(message, exchange: "hyperliquid", raw: body)}
  end

  defp reject_hyperliquid_order_rejection(_body, _exchange, _js_name), do: :ok

  # Historical orders return one status row per transition; keep the newest oid.
  defp maybe_dedup_hyperliquid_orders(rows, "fetchOrders") when is_list(rows) do
    rows
    |> Enum.reduce(%{}, &dedup_hyperliquid_order/2)
    |> Map.values()
  end

  defp maybe_dedup_hyperliquid_orders(payload, _js_name), do: payload

  defp dedup_hyperliquid_order(row, acc) do
    oid = row |> Map.get("oid") |> to_string_if_present()

    case {is_binary(oid), Map.get(acc, oid)} do
      {false, _existing} -> acc
      {true, nil} -> Map.put(acc, oid, row)
      {true, existing} -> keep_newer_hyperliquid_order(acc, oid, row, existing)
    end
  end

  # Strict `>`: the venue answers newest-first, so on an equal statusTimestamp
  # (an IOC that opens and fills in the same millisecond emits both rows with
  # one ts) the first-seen row is the terminal status and must win the tie —
  # `>=` let the later-processed "open" row overwrite the "filled" one.
  defp keep_newer_hyperliquid_order(acc, oid, row, existing) do
    if hyperliquid_status_ts(row) > hyperliquid_status_ts(existing) do
      Map.put(acc, oid, row)
    else
      acc
    end
  end

  defp hyperliquid_status_ts(%{"statusTimestamp" => ts}), do: Bourse.Safe.integer(ts) || 0
  defp hyperliquid_status_ts(_), do: 0

  defp annotate_hyperliquid_order_row(row) when is_map(row) do
    {entry, filled_map, nested?} = hyperliquid_order_parts(row)
    sizes = hyperliquid_order_sizes(row, entry, filled_map)
    derived = hyperliquid_order_derived(row, entry, filled_map, sizes)
    info_echo = hyperliquid_order_info_echo(row, entry, filled_map, nested?, sizes)

    entry
    |> hyperliquid_merge_order_echo(row, filled_map, sizes, derived, info_echo)
    |> hyperliquid_put_order_synthetics(sizes, derived)
  end

  defp annotate_hyperliquid_order_row(other), do: other

  # A row is either a wrapper ({order|resting|filled, status, statusTimestamp}) or
  # a flat open-order object; `entry` is the order body, `filled_map` the fill ack.
  defp hyperliquid_order_parts(row) do
    nested? = is_map(Map.get(row, "order")) or is_map(Map.get(row, "resting")) or is_map(Map.get(row, "filled"))
    candidate = Map.get(row, "order") || Map.get(row, "resting") || Map.get(row, "filled") || row
    entry = if is_map(candidate), do: candidate, else: row
    filled_map = Map.get(row, "filled")
    filled_map = if is_map(filled_map), do: filled_map, else: %{}

    {entry, filled_map, nested?}
  end

  defp hyperliquid_order_sizes(row, entry, filled_map) do
    amount = non_empty_string(Map.get(entry, "origSz") || Map.get(entry, "totalSz") || Map.get(filled_map, "totalSz"))
    native_remaining = non_empty_string(Map.get(entry, "sz"))
    filled_from_status = non_empty_string(Map.get(filled_map, "totalSz"))
    trigger? = Map.get(entry, "isTrigger") in [true, "true"]
    has_order_type? = is_binary(Map.get(entry, "orderType"))
    has_status? = is_binary(Map.get(row, "status"))
    multi_status? = Map.get(row, "_bourse_multi_status") == true

    filled =
      hyperliquid_filled_size(filled_from_status, amount, native_remaining, trigger?, has_status?, has_order_type?)

    %{
      amount: amount,
      filled: filled,
      filled_from_status: filled_from_status,
      remaining: hyperliquid_remaining_size(native_remaining, filled_from_status, multi_status?),
      trigger?: trigger?,
      has_order_type?: has_order_type?,
      has_status?: has_status?,
      multi_status?: multi_status?
    }
  end

  # Closed/history wrappers and create filled acks: compute filled. Trigger open
  # orders leave filled nil. Non-trigger open orders with a full
  # orderType report filled = amount-remaining; sparse open-order rows still
  # report filled 0.
  defp hyperliquid_filled_size(filled_from_status, _amount, _remaining, _trigger?, _has_status?, _has_order_type?)
       when is_binary(filled_from_status), do: filled_from_status

  defp hyperliquid_filled_size(_from_status, amount, remaining, trigger?, has_status?, has_order_type?) do
    cond do
      trigger? and not has_status? ->
        nil

      has_status? or has_order_type? or (is_binary(amount) and is_binary(remaining)) ->
        hyperliquid_order_filled(amount, remaining)

      true ->
        nil
    end
  end

  # createOrder filled ack has no remaining size — fully filled, unless this is
  # a multi-status createOrderWithTP response, where remaining stays nil.
  defp hyperliquid_remaining_size(remaining, _from_status, _multi?) when is_binary(remaining), do: remaining
  defp hyperliquid_remaining_size(_remaining, from_status, false) when is_binary(from_status), do: "0"
  defp hyperliquid_remaining_size(_remaining, _from_status, _multi?), do: nil

  defp hyperliquid_order_derived(row, entry, filled_map, sizes) do
    average = non_empty_string(Map.get(entry, "avgPx") || Map.get(filled_map, "avgPx"))
    price = non_empty_string(Map.get(entry, "limitPx"))
    tif = entry |> Map.get("tif") |> hyperliquid_tif()

    %{
      average: average,
      tif: tif,
      cost: hyperliquid_order_cost(sizes.filled, average, price, sizes.amount, hyperliquid_cost_zero_ok?(sizes)),
      status: Map.get(row, "status") || hyperliquid_derived_status(sizes.amount, sizes.remaining, sizes.filled),
      trigger_price: if(sizes.trigger?, do: zero_as_nil(Map.get(entry, "triggerPx"))),
      type: entry |> Map.get("orderType") |> hyperliquid_order_type(),
      post_only: hyperliquid_post_only(tif)
    }
  end

  # Cost 0 for zero-filled non-trigger open orders with orderType; nil for sparse/trigger.
  defp hyperliquid_cost_zero_ok?(sizes) do
    sizes.has_status? or is_binary(sizes.filled_from_status) or (sizes.has_order_type? and not sizes.trigger?)
  end

  defp hyperliquid_post_only("ALO"), do: true
  defp hyperliquid_post_only(tif) when is_binary(tif), do: false
  defp hyperliquid_post_only(_tif), do: nil

  # `info` is the raw status row: full wrapper for fetchOrder/history, the
  # create status map for createOrder, or the flat open-order object.
  # createOrderWithTP info is the filled map only (not the multi-status envelope).
  defp hyperliquid_order_info_echo(row, entry, filled_map, nested?, sizes) do
    base = if nested? or Map.has_key?(row, "status"), do: row, else: entry

    cond do
      not sizes.multi_status? ->
        base

      is_map(Map.get(row, "filled")) ->
        %{"filled" => Map.get(row, "filled")}

      is_map(Map.get(entry, "totalSz")) ->
        %{"filled" => entry}

      is_binary(sizes.filled_from_status) ->
        %{"filled" => Map.take(Map.merge(entry, filled_map), ["totalSz", "avgPx", "oid", "total_sz", "avg_px"])}

      true ->
        base
    end
  end

  defp hyperliquid_merge_order_echo(entry, row, filled_map, sizes, derived, info_echo) do
    Map.merge(entry, %{
      "status" => derived.status,
      "statusTimestamp" => Map.get(row, "statusTimestamp") || Map.get(entry, "statusTimestamp"),
      "avgPx" => derived.average || Map.get(entry, "avgPx"),
      "oid" => Map.get(entry, "oid") || Map.get(filled_map, "oid"),
      "origSz" => sizes.amount || Map.get(entry, "origSz"),
      "sz" => sizes.remaining || Map.get(entry, "sz"),
      "totalSz" => Map.get(filled_map, "totalSz") || Map.get(entry, "totalSz"),
      "_bourse_info" => info_echo
    })
  end

  defp hyperliquid_put_order_synthetics(map, sizes, derived) do
    map
    |> maybe_put_synthetic("_bourse_amount", sizes.amount)
    |> maybe_put_synthetic("_bourse_filled", sizes.filled)
    |> maybe_put_synthetic("_bourse_remaining", sizes.remaining)
    |> maybe_put_synthetic("_bourse_cost", derived.cost)
    |> maybe_put_synthetic("_bourse_average", derived.average)
    |> maybe_put_synthetic("_bourse_tif", derived.tif)
    |> maybe_put_synthetic("_bourse_post_only", derived.post_only)
    |> maybe_put_synthetic("_bourse_trigger_price", derived.trigger_price)
    |> maybe_put_synthetic("_bourse_status", derived.status)
    |> maybe_put_synthetic("_bourse_type", derived.type)
  end

  defp hyperliquid_order_filled(amount, remaining) when is_binary(amount) and is_binary(remaining) do
    {a, r} = {Decimal.new(amount), Decimal.new(remaining)}
    a |> Decimal.sub(r) |> Decimal.to_string(:normal)
  rescue
    Decimal.Error -> nil
  end

  defp hyperliquid_order_filled(_amount, _remaining), do: nil

  # Cost is filled*avg (or filled*price). Zero-filled open orders leave cost nil
  # unless the venue status explicitly carried a fill (createOrder filled ack /
  # closed order with totalSz).
  defp hyperliquid_order_cost(filled, average, price, _amount, from_status?) when is_binary(filled) do
    if filled in ["0", "0.0"] do
      if from_status?, do: "0"
    else
      hyperliquid_filled_cost(filled, average, price)
    end
  end

  defp hyperliquid_order_cost(_filled, _average, _price, _amount, _from_status?), do: nil

  defp hyperliquid_filled_cost(filled, average, _price) when is_binary(average), do: maybe_mul_decimal(filled, average)
  defp hyperliquid_filled_cost(filled, _average, price) when is_binary(price), do: maybe_mul_decimal(filled, price)
  defp hyperliquid_filled_cost(_filled, _average, _price), do: nil

  defp hyperliquid_tif(nil), do: nil
  defp hyperliquid_tif(tif) when is_binary(tif), do: String.upcase(tif)
  defp hyperliquid_tif(_), do: nil

  defp hyperliquid_order_type(nil), do: nil

  defp hyperliquid_order_type(type) when is_binary(type) do
    case String.downcase(type) do
      "stop limit" -> "limit"
      "stop market" -> "market"
      other -> other
    end
  end

  defp hyperliquid_order_type(_), do: nil

  # The authored field map maps Hyperliquid's wire "filled" status to "closed".
  defp hyperliquid_derived_status(_amount, remaining, filled)
       when remaining in ["0", "0.0"] and is_binary(filled) and filled not in [nil, "", "0", "0.0"], do: "filled"

  defp hyperliquid_derived_status(_amount, _remaining, filled) when filled in [nil, "", "0", "0.0"], do: "open"
  defp hyperliquid_derived_status(_amount, remaining, _filled) when is_binary(remaining), do: "open"
  defp hyperliquid_derived_status(_amount, _remaining, _filled), do: nil

  defp annotate_hyperliquid_positions(rows) when is_list(rows), do: Enum.map(rows, &annotate_hyperliquid_position_row/1)
  defp annotate_hyperliquid_positions(%{} = row), do: annotate_hyperliquid_position_row(row)
  defp annotate_hyperliquid_positions(other), do: other

  defp annotate_hyperliquid_position_row(%{"position" => entry} = row) when is_map(entry) do
    leverage = Map.get(entry, "leverage") || %{}
    margin_mode = Map.get(leverage, "type")
    raw_size = non_empty_string(Map.get(entry, "szi"))
    contracts = if is_binary(raw_size), do: decimal_abs(raw_size)
    side = hyperliquid_position_side(raw_size)
    margin_used = non_empty_string(Map.get(entry, "marginUsed"))
    unrealized = non_empty_string(Map.get(entry, "unrealizedPnl"))
    isolated? = margin_mode == "isolated"

    initial_margin =
      if isolated? and is_binary(margin_used) and is_binary(unrealized) do
        {m, u} = {Decimal.new(margin_used), Decimal.new(unrealized)}
        m |> Decimal.sub(u) |> Decimal.to_string(:normal)
      else
        margin_used
      end

    percentage =
      if is_binary(unrealized) and is_binary(margin_used) and margin_used not in ["0", "0.0"] do
        {u, m} = {Decimal.new(unrealized), Decimal.new(margin_used)}

        u
        |> Decimal.div(m)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.to_string(:normal)
      end

    entry
    |> Map.merge(%{
      "type" => Map.get(row, "type"),
      # Keep the assetPositions row wrapper in info, not only the nested position.
      "_bourse_info" => row
    })
    |> maybe_put_synthetic("_bourse_contracts", contracts)
    |> maybe_put_synthetic("_bourse_side", side)
    |> maybe_put_synthetic("_bourse_leverage", Map.get(leverage, "value"))
    |> maybe_put_synthetic("_bourse_margin_mode", margin_mode)
    |> maybe_put_synthetic("_bourse_collateral", margin_used)
    |> maybe_put_synthetic("_bourse_initial_margin", initial_margin)
    |> maybe_put_synthetic("_bourse_percentage", percentage)
    |> maybe_put_synthetic("_bourse_contract_size", "1")
    |> maybe_put_synthetic("_bourse_isolated", isolated?)
    |> Map.put("coin", Map.get(entry, "coin"))
  rescue
    Decimal.Error -> entry
  end

  defp annotate_hyperliquid_position_row(other), do: other

  defp hyperliquid_position_side(size) when is_binary(size) do
    case Decimal.compare(Decimal.new(size), 0) do
      :gt -> "long"
      :lt -> "short"
      _ -> nil
    end
  rescue
    Decimal.Error -> nil
  end

  defp hyperliquid_position_side(_), do: nil

  defp annotate_hyperliquid_trades(rows) when is_list(rows), do: Enum.map(rows, &annotate_hyperliquid_trade_row/1)
  defp annotate_hyperliquid_trades(%{} = row), do: annotate_hyperliquid_trade_row(row)
  defp annotate_hyperliquid_trades(other), do: other

  defp annotate_hyperliquid_trade_row(%{} = row) do
    fee = non_empty_string(Map.get(row, "fee"))
    builder = non_empty_string(Map.get(row, "builderFee"))

    fee_cost =
      cond do
        is_binary(fee) and is_binary(builder) ->
          {f, b} = {Decimal.new(fee), Decimal.new(builder)}
          f |> Decimal.add(b) |> Decimal.to_string(:normal)

        is_binary(fee) ->
          fee

        true ->
          nil
      end

    amount = non_empty_string(Map.get(row, "sz"))
    price = non_empty_string(Map.get(row, "px"))
    cost = maybe_mul_decimal(amount, price)

    crossed = Map.get(row, "crossed")
    taker_or_maker = if is_boolean(crossed), do: if(crossed, do: "taker", else: "maker")

    row
    |> maybe_put_synthetic("_bourse_fee_cost", fee_cost)
    |> maybe_put_synthetic("_bourse_cost", cost)
    |> maybe_put_synthetic("_bourse_taker_or_maker", taker_or_maker)
  rescue
    Decimal.Error -> row
  end

  defp annotate_hyperliquid_trade_row(other), do: other

  defp annotate_hyperliquid_transactions(rows, js_name) when is_list(rows) do
    rows
    |> Enum.map(&extract_hyperliquid_ledger_type/1)
    |> filter_hyperliquid_transactions(js_name)
    |> Enum.map(&annotate_hyperliquid_transaction_row/1)
  end

  defp annotate_hyperliquid_transactions(%{} = row, js_name) do
    row
    |> extract_hyperliquid_ledger_type()
    |> then(fn typed ->
      case filter_hyperliquid_transactions([typed], js_name) do
        [kept] -> annotate_hyperliquid_transaction_row(kept)
        _ -> annotate_hyperliquid_transaction_row(typed)
      end
    end)
  end

  defp annotate_hyperliquid_transactions(other, _js_name), do: other

  # userFunding rows share the ledger-update shape ({"delta" => {...}, "hash",
  # "time"}); promote delta.coin onto the row so the generic native-symbol
  # backfill (hyperliquid_native_coin/2) can resolve `symbol`.
  # https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals#retrieve-a-users-funding-history
  defp annotate_hyperliquid_funding_history(rows) when is_list(rows),
    do: Enum.map(rows, &annotate_hyperliquid_funding_history_row/1)

  defp annotate_hyperliquid_funding_history(%{} = row), do: annotate_hyperliquid_funding_history_row(row)
  defp annotate_hyperliquid_funding_history(other), do: other

  defp annotate_hyperliquid_funding_history_row(%{"delta" => %{"coin" => coin}} = row) when is_binary(coin),
    do: Map.put(row, "coin", coin)

  defp annotate_hyperliquid_funding_history_row(other), do: other

  # Promote delta.type onto the ledger row.
  defp extract_hyperliquid_ledger_type(%{"delta" => %{"type" => type}} = row) when is_binary(type) do
    Map.put(row, "type", type)
  end

  defp extract_hyperliquid_ledger_type(row), do: row

  defp filter_hyperliquid_transactions(rows, "fetchDeposits"), do: Enum.filter(rows, &(Map.get(&1, "type") == "deposit"))

  defp filter_hyperliquid_transactions(rows, "fetchWithdrawals"),
    do: Enum.filter(rows, &(Map.get(&1, "type") == "withdraw"))

  defp filter_hyperliquid_transactions(rows, _js_name), do: rows

  defp annotate_hyperliquid_transaction_row(%{} = row) do
    fee = get_in(row, ["delta", "fee"])
    type = Map.get(row, "type")
    # Internal transfers are the only rows marked internal when type is present.
    internal = if is_binary(type), do: type == "internalTransfer"

    row
    |> maybe_put_synthetic("_bourse_fee_cost", if(fee not in [nil, ""], do: fee))
    |> maybe_put_synthetic("_bourse_fee_currency", if(fee not in [nil, ""], do: "USDC"))
    |> maybe_put_synthetic("_bourse_internal", internal)
  end

  defp annotate_hyperliquid_transaction_row(other), do: other

  # Trading-fee info echoes only the two rate fields.
  defp annotate_hyperliquid_trading_fee(%{} = body, _exchange) do
    %{
      "userAddRate" => Map.get(body, "userAddRate"),
      "userCrossRate" => Map.get(body, "userCrossRate")
    }
  end

  defp annotate_hyperliquid_trading_fee(other, _exchange), do: other

  defp to_string_if_present(nil), do: nil
  defp to_string_if_present(value) when is_binary(value), do: value
  defp to_string_if_present(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_if_present(_), do: nil

  defp annotate_derive_position_row(%{} = row) do
    # Venue mark/liquidation prices can exceed Decimal's parseable digit count
    # (e.g. 36 fractional digits). Use Safe.number (Float.parse) for notional.
    abs_amount = decimal_abs(Map.get(row, "amount"))

    notional =
      case {Bourse.Safe.number(abs_amount), Bourse.Safe.number(Map.get(row, "mark_price"))} do
        {amount, mark} when is_number(amount) and is_number(mark) -> amount * mark
        _ -> nil
      end

    row
    |> maybe_put_synthetic("_bourse_abs_amount", abs_amount)
    |> maybe_put_synthetic("_bourse_notional", notional)
  end

  defp annotate_derive_position_row(other), do: other

  defp preserve_bybit_order_ack(%Bourse.Order{} = order, body, %Exchange{id: "bybit"}, "editOrder") do
    %{order | info: body, symbol: nil}
  end

  defp preserve_bybit_order_ack(parsed, _body, _exchange, _js_name), do: parsed

  # Bybit batch amend answers HTTP 200 with retCode 0 even when individual rows
  # fail; per-item codes live in `retExtInfo.list`. Merge them onto result rows
  # before parse so rejections surface as code/message on the Order.
  defp merge_bybit_batch_ret_ext(payload, body, %Exchange{id: "bybit"}, "editOrders") when is_list(payload) do
    codes = bybit_ret_ext_codes(body)

    payload
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      case Map.get(codes, index) do
        %{"code" => code} = info when code not in [0, "0", nil] ->
          row
          |> Map.merge(Map.take(info, ["code", "msg", "message"]))
          |> Map.put_new("retCode", code)
          |> Map.put_new("retMsg", info["msg"] || info["message"])

        _ ->
          row
      end
    end)
  end

  defp merge_bybit_batch_ret_ext(payload, _body, _exchange, _js_name), do: payload

  # `retExtInfo.list` is positional against the result rows; index it once so the
  # per-row lookup is O(1) rather than an Enum.at/2 scan per row.
  defp bybit_ret_ext_codes(body) do
    body
    |> get_in(["retExtInfo", "list"])
    |> List.wrap()
    |> Enum.with_index()
    |> Map.new(fn {info, index} -> {index, info} end)
  end

  defp stamp_bybit_edit_orders_rejections(orders, body, %Exchange{id: "bybit"}, "editOrders") when is_list(orders) do
    codes = bybit_ret_ext_codes(body)

    orders
    |> Enum.with_index()
    |> Enum.map(fn
      {%Bourse.Order{} = order, index} ->
        case Map.get(codes, index) do
          %{"code" => code} = info when code not in [0, "0", nil] ->
            message = info["msg"] || info["message"] || "batch amend rejected"

            %{
              order
              | status: order.status || "rejected",
                info:
                  (order.info || %{})
                  |> Map.put("code", code)
                  |> Map.put("msg", message)
                  |> Map.put_new("retCode", code)
                  |> Map.put_new("retMsg", message)
            }

          _ ->
            order
        end

      {other, _index} ->
        other
    end)
  end

  defp stamp_bybit_edit_orders_rejections(parsed, _body, _exchange, _js_name), do: parsed

  defp sort_bybit_orders(orders, %Exchange{id: "bybit"}, "fetchClosedOrders") when is_list(orders) do
    Enum.sort_by(orders, &(&1.timestamp || 0))
  end

  defp sort_bybit_orders(parsed, _exchange, _js_name), do: parsed

  defp normalize_binance_family_result(parsed, %Exchange{id: id}, _js_name)
       when id in ["binance", "binancecoinm", "binanceusdm"] do
    parsed
    |> reject_zero_binance_positions()
    |> preserve_binance_sparse_order_ack()
  end

  defp normalize_binance_family_result(parsed, _exchange, _js_name), do: parsed

  defp preserve_binance_sparse_order_ack(orders) when is_list(orders),
    do: Enum.map(orders, &preserve_binance_sparse_order_ack/1)

  defp preserve_binance_sparse_order_ack(%Bourse.Order{id: nil, info: %{"code" => code}} = order)
       when code in [200, "200"] do
    %{order | post_only: nil}
  end

  defp preserve_binance_sparse_order_ack(order), do: order

  defp clear_binance_sparse_ack_symbols(orders, %Exchange{id: id})
       when id in ["binance", "binancecoinm", "binanceusdm"] and is_list(orders) do
    Enum.map(orders, &clear_binance_sparse_ack_symbol/1)
  end

  defp clear_binance_sparse_ack_symbols(parsed, _exchange), do: parsed

  defp clear_binance_sparse_ack_symbol(%Bourse.Order{id: nil, info: %{"code" => code}} = order)
       when code in [200, "200"] do
    %{order | symbol: nil}
  end

  defp clear_binance_sparse_ack_symbol(order), do: order

  defp reject_zero_binance_positions(positions) when is_list(positions) do
    Enum.reject(positions, fn
      %{__struct__: Bourse.Position, contracts: contracts} -> zero_number?(contracts)
      _other -> false
    end)
  end

  defp reject_zero_binance_positions(position), do: position

  defp zero_number?(value) when is_number(value), do: value == 0
  defp zero_number?(_value), do: false

  defp reject_missing_single_order([], exchange, js_name, false)
       when js_name in ["fetchOpenOrder", "fetchClosedOrder", "fetchOrder", "fetchOrderClassic"] do
    {:error,
     Error.order_not_found(
       exchange: exchange.id,
       message: "Order not found",
       raw: []
     )}
  end

  defp reject_missing_single_order(_payload, _exchange, _js_name, _list_return?), do: :ok

  defp parsed_fee_and_fees(fee) when is_map(fee) do
    parsed = parse_fee_numeric(fee)
    {parsed, [parsed]}
  end

  defp parsed_fee_and_fees(_fee), do: {%{"cost" => nil, "currency" => nil}, []}

  defp parse_fee_numeric(fee) when is_map(fee) do
    fee = Map.put(fee, "cost", Bourse.Safe.number(Map.get(fee, "cost")))

    case Map.get(fee, "rate") do
      nil -> fee
      rate -> Map.put(fee, "rate", Bourse.Safe.number(rate))
    end
  end

  defp put_info(%{info: _} = struct, raw) when is_map(raw) do
    # Synthetic annotate keys (`_bourse_*`) are field-map helpers, not wire data.
    %{struct | info: Map.reject(raw, fn {key, _} -> synthetic_info_key?(key) end)}
  end

  defp put_info(%{info: _} = struct, raw), do: %{struct | info: raw}
  defp put_info(struct, _raw), do: struct

  defp synthetic_info_key?(key) when is_binary(key), do: String.starts_with?(key, "_bourse_")
  defp synthetic_info_key?(_key), do: false

  defp put_datetime(%{timestamp: timestamp, datetime: datetime} = struct)
       when is_integer(timestamp) and timestamp >= 0 and
              (is_nil(datetime) or datetime == timestamp or is_integer(datetime)) do
    %{struct | datetime: Timestamp.iso8601_from_ms(timestamp)}
  end

  defp put_datetime(struct), do: struct

  defp stamp_observed_at(%{observed_at: nil} = struct) do
    %{struct | observed_at: System.system_time(:millisecond)}
  end

  defp stamp_observed_at(struct), do: struct

  defp validate_parsed([], _list_return?), do: :ok

  defp validate_parsed(parsed, true) when is_list(parsed) do
    if Enum.all?(parsed, &empty_struct?/1) do
      {:error, {:empty_parse, parsed}}
    else
      :ok
    end
  end

  # Single struct (non-list). Covers both single-return methods and the case
  # where a list-return method's body parses to one record (e.g. a flat OHLCV
  # row) — guard on emptiness without crashing on the shape mismatch.
  defp validate_parsed(parsed, _list_return?) do
    if empty_struct?(parsed), do: {:error, {:empty_parse, parsed}}, else: :ok
  end

  # `info`/`fee`/`fees`/`trades` are structural passthroughs that defaults or
  # `enrich` always inject (raw echo, trade fee defaults, Order's
  # empty `fees`/`trades` lists), independent of whether the field map extracted
  # any real data. Excluding them keeps the "parsed to nothing" guard firing on
  # a foreign body that maps to zero domain fields (e.g. account/info → Order).
  @structural_fields [:info, :fee, :fees, :trades]

  # A sparse margin-loan acknowledgement (Bybit repayCrossMargin echoes only
  # `{resultStatus: "SU"}`) parses to a struct whose only populated field is
  # `info`. That is a successful response, not an empty parse: the currency and
  # amount are backfilled from request context immediately after validation.
  defp empty_struct?(%{__struct__: Bourse.MarginLoan, info: info}) when is_map(info) and map_size(info) > 0, do: false

  # Hyperliquid transfer answers a successful money-move with a bare ack
  # `{"status":"ok","response":{"type":"default"}}` — no TransferEntry-shaped
  # payload (docs: exchange endpoint transfer responses; Python SDK returns the
  # same envelope). Status "ok" (or the raw ack in `info`) is the success signal;
  # currency/amount/from/to are backfilled from the request immediately after.
  defp empty_struct?(%{__struct__: Bourse.TransferEntry, status: status}) when is_binary(status) and status != "",
    do: false

  defp empty_struct?(%{__struct__: Bourse.TransferEntry, info: %{"status" => "ok"}}), do: false

  # Sparse order write acks (Bybit protective OCO returns `result: {}`) enrich to
  # an Order whose only non-nil structural fields are empty defaults. Distinct
  # from a *foreign* body whose `info` is a non-empty map of unmapped keys —
  # that path still fails loud below.
  defp empty_struct?(%{__struct__: Bourse.Order, info: info}) when info in [%{}, nil], do: false

  defp empty_struct?(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__struct__ | @structural_fields])
    |> Enum.all?(fn {_k, v} -> empty_field_value?(v) end)
  end

  defp empty_struct?(_), do: false

  # Nil and empty containers are not evidence of a successful field-map hit.
  defp empty_field_value?(nil), do: true
  defp empty_field_value?([]), do: true
  defp empty_field_value?(map) when is_map(map) and not is_struct(map) and map_size(map) == 0, do: true
  defp empty_field_value?(_), do: false
end
