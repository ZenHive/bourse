defmodule Bourse.Unified.RequestShape.OKX do
  @moduledoc false
  # OKX request mechanics that the generic authored-entry machinery cannot express:
  # instrument-type derivation, option-family derivation, transfer account ids and
  # order-book depth. Pure renames/defaults live in the authored spec's
  # `endpoints.request.defaults` instead (see `priv/specs/json/output/okx.json`).

  alias Bourse.Exchange
  alias Bourse.Symbol

  # OKX `market/books` returns top-of-book when `sz` is omitted; request 100 levels.
  @default_order_book_depth 100
  @default_full_order_book_depth 5000
  @default_ohlcv_limit 100
  @max_ohlcv_limit 300
  @max_index_ohlcv_limit 100
  @default_ohlcv_bar "1m"
  @default_open_interest_period "1D"
  @default_positions_history_limit 100
  @exclusive_time_offset_ms 1
  @milliseconds_per_minute 60_000
  @minutes_per_hour 60
  @hours_per_day 24
  @days_per_week 7
  @days_per_month 30
  @percent_denominator 100

  # OKX option underlyings are documented as `BASE-SETTLE` (e.g. BTC-USD) on
  # `GET /api/v5/public/underlying?instType=OPTION` and on option tickers /
  # opt-summary. Live listing (2026-07-22) is exclusively `*-USD` families —
  # bare bases expand to that settle only; any other settle fails locally
  # (carve C-T475a). Do not silently invent a non-USD family.
  @option_underlying_settle "USD"

  # Rubik open-interest history `period` enums are endpoint-specific (carve
  # C-T475b). Unified aliases normalize within each endpoint's closed set.
  @contracts_open_interest_path "rubik/stat/contracts/open-interest-volume"
  @option_open_interest_path "rubik/stat/option/open-interest-volume"
  @contracts_open_interest_periods %{
    "5m" => "5m",
    "1h" => "1H",
    "1H" => "1H",
    "1d" => "1D",
    "1D" => "1D"
  }
  @option_open_interest_periods %{
    "8h" => "8H",
    "8H" => "8H",
    "1d" => "1D",
    "1D" => "1D"
  }

  # `POST /api/v5/asset/transfer` subType values — OKX enumerates margin adds/reduces
  # as 160/161 rather than the unified add/reduce vocabulary.
  @margin_sub_types %{"add" => "160", "reduce" => "161"}

  @doc "Builds native OKX parameters for a unified method."
  @spec build(map(), String.t(), Exchange.t()) :: map() | [map()]
  def build(params, js_name, exchange)

  def build(params, "fetchTickers", %Exchange{} = exchange) when is_map(params),
    do: put_inst_type(params, exchange, symbols_market_type(params) || default_type(exchange))

  def build(params, "fetchMarkPrices", %Exchange{} = exchange) when is_map(params),
    do: put_inst_type(params, exchange, "swap")

  def build(params, "fetchOpenInterests", %Exchange{} = exchange) when is_map(params),
    do: put_inst_type(params, exchange, "swap")

  def build(params, "fetchTradingFee", %Exchange{} = exchange) when is_map(params),
    do: put_trading_fee_instrument(params, exchange)

  def build(params, "fetchOpenOrders", %Exchange{}) when is_map(params), do: put_order_read_ord_type(params)

  def build(params, "fetchClosedOrders", %Exchange{} = exchange) when is_map(params),
    do: build_order_history(params, exchange, "filled")

  def build(params, "fetchCanceledOrders", %Exchange{} = exchange) when is_map(params),
    do: build_order_history(params, exchange, "canceled")

  def build(params, "fetchOrder", %Exchange{}) when is_map(params), do: put_order_read_id(params)

  def build(params, "transfer", %Exchange{} = exchange) when is_map(params), do: map_transfer_accounts(params, exchange)

  # Authored defaults bind id → transId; keep the rename for callers that still
  # hand a unified `id`, and never forward the optional currency filter.
  def build(params, "fetchTransfer", %Exchange{}) when is_map(params) do
    params
    |> rename("id", "transId")
    |> Map.delete("code")
  end

  def build(params, "fetchMarginAdjustmentHistory", %Exchange{}) when is_map(params), do: put_margin_sub_type(params)

  # Dual-mode closePosition(symbol, side) — OKX wants posSide long/short, not buy/sell.
  def build(params, "closePosition", %Exchange{}) when is_map(params), do: put_close_pos_side(params)

  def build(params, "fetchOrderBook", %Exchange{}) when is_map(params), do: put_order_book_depth(params)

  def build(params, "fetchOHLCV", %Exchange{}) when is_map(params), do: build_ohlcv(params)

  def build(params, "fetchLedger", %Exchange{} = exchange) when is_map(params),
    do: params |> rename("code", "ccy") |> put_inst_type(exchange, default_type(exchange))

  def build(params, "fetchDeposits", %Exchange{}) when is_map(params), do: build_deposits(params)

  # Deposit-address and withdrawal-history filter on OKX `ccy`. A raw unified
  # `code` is ignored by the venue, so the currency filter silently vanishes
  # (C-T484a). Same rename C-T434c already authored for ledger/deposits.
  def build(params, "fetchDepositAddress", %Exchange{}) when is_map(params), do: rename(params, "code", "ccy")

  def build(params, "fetchWithdrawals", %Exchange{}) when is_map(params), do: rename(params, "code", "ccy")

  # On-chain withdrawal body: composite `chain` from unified network, and string
  # `amt`/`fee` as OKX documents (C-T484b). Endpoint selection is C-T432.
  def build(params, "withdraw", %Exchange{} = exchange) when is_map(params), do: build_withdraw(params, exchange)

  # Funding-fee bills (type=8 already authored): derive instType/ctType/ccy from
  # the unified symbol; never forward raw `symbol` (C-T484c).
  def build(params, "fetchFundingHistory", %Exchange{} = exchange) when is_map(params),
    do: build_funding_history(params, exchange)

  def build(params, "fetchOptionChain", %Exchange{}) when is_map(params), do: build_option_chain(params)

  def build(params, "fetchAllGreeks", %Exchange{} = exchange) when is_map(params), do: build_all_greeks(params, exchange)

  def build(params, "fetchOpenInterestHistory", %Exchange{}) when is_map(params),
    do: build_open_interest_history(params, @contracts_open_interest_path)

  def build(params, "fetchPositions", %Exchange{} = exchange) when is_map(params), do: build_positions(params, exchange)

  def build(params, "fetchPositionsHistory", %Exchange{} = exchange) when is_map(params),
    do: build_positions_history(params, exchange)

  def build(params, "fetchPosition", %Exchange{} = exchange) when is_map(params),
    do: put_symbol_inst_type(params, exchange)

  def build(params, "fetchGreeks", %Exchange{}) when is_map(params), do: put_option_family(params)

  # Unified `code` → OKX `ccy` for margin borrow-rate / interest reads. The
  # vendored defaults still mark `ccy` as unresolved identifier_reference; map
  # it here so a live fetchCrossBorrowRate("USDT") does not raise before the wire.
  def build(params, js_name, %Exchange{})
      when is_map(params) and
             js_name in [
               "fetchCrossBorrowRate",
               "fetchCrossBorrowRates",
               "fetchBorrowInterest",
               "fetchBorrowRate",
               "fetchBorrowRates",
               "fetchBorrowRateHistory"
             ], do: rename(params, "code", "ccy")

  # OKX cancel-algos and cancel-batch-orders take a root JSON array of objects
  # ([{algoId|ordId, instId}, ...]). A plain map body yields 50002 Incorrect
  # json data format on cancel-algos (live EEA demo 2026-07-18).
  def build(params, "cancelOrder", %Exchange{} = exchange) when is_map(params), do: build_cancel_order(params, exchange)

  def build(params, "cancelOrders", %Exchange{} = exchange) when is_map(params), do: build_cancel_orders(params, exchange)

  def build(params, "cancelOrdersForSymbols", %Exchange{} = exchange) when is_map(params),
    do: build_cancel_orders_for_symbols(params, exchange)

  # Singular place-order body for POST /api/v5/trade/order or trade/order-algo.
  # Endpoint selection pins trade/order for normal/attached rows and
  # trade/order-algo for standalone trigger/conditional/trailing families.
  # Unified amount/price/type/symbol must not ride through as OKX rejects them
  # with 50002.
  def build(params, "createOrder", %Exchange{} = exchange) when is_map(params), do: build_create_order(params, exchange)

  # Cost-based market orders express `cost` as a quote-currency `sz` on OKX
  # spot via `tgtCcy`. OKX documents `tgtCcy` as SPOT-market-order-only, so a
  # derivative has no wire form for cost sizing: its `sz` is a contract count.
  # Raise there rather than ship `sz = cost` as contracts.
  def build(params, "createMarketBuyOrderWithCost", %Exchange{} = exchange) when is_map(params),
    do: build_market_order_with_cost(params, "buy", exchange)

  def build(params, "createMarketSellOrderWithCost", %Exchange{} = exchange) when is_map(params),
    do: build_market_order_with_cost(params, "sell", exchange)

  # Same place body as createOrder: primary order + attachAlgoOrds for TP/SL.
  def build(params, "createOrderWithTakeProfitAndStopLoss", %Exchange{} = exchange) when is_map(params),
    do: build_create_order(params, exchange)

  # Batch orders use the same normal-order row schema as place-order, but the
  # endpoint requires a root array. Each row retains its own instrument and
  # trade mode; outer options apply to every row unless that row overrides them.
  def build(%{"orders" => orders} = params, "createOrders", %Exchange{} = exchange) when is_list(orders),
    do: build_create_orders(params, orders, exchange)

  # Amend-order / amend-algos body. Default selection is trade/amend-order;
  # conditional/trigger/move_order_stop (or explicit algoId) selects amend-algos.
  def build(params, "editOrder", %Exchange{} = exchange) when is_map(params), do: build_edit_order(params, exchange)

  # Amend multiple orders likewise takes a root array. Normal amend rows only —
  # batch algo amend is not a venue surface we expose.
  def build(%{"orders" => orders} = params, "editOrders", %Exchange{} = exchange) when is_list(orders),
    do: build_edit_orders(params, orders, exchange)

  # Dead-man's switch: OKX `timeOut` is whole seconds; unified timeout is ms.
  def build(params, "cancelAllOrdersAfter", %Exchange{}) when is_map(params), do: build_cancel_all_orders_after(params)

  # Transaction details (last 3 days): GET /api/v5/trade/fills. instType is
  # optional; fills-history requires it (live 50014). Route the 3-day fills
  # surface rather than the 3-month fills-history surface.
  def build(params, "fetchMyTrades", %Exchange{} = exchange) when is_map(params),
    do: build_fetch_my_trades(params, exchange)

  def build(params, _js_name, %Exchange{}), do: params

  @doc "Builds native OKX parameters using the selected endpoint metadata."
  @spec build(map(), String.t(), Exchange.t(), keyword()) :: map() | [map()]
  def build(params, "fetchOpenInterestHistory", %Exchange{}, opts) when is_map(params) and is_list(opts),
    do: build_open_interest_history(params, Keyword.get(opts, :endpoint_path))

  def build(params, js_name, %Exchange{} = exchange, _opts) when is_map(params), do: build(params, js_name, exchange)

  # OKX's own `options.defaultType`, not a client-side guess.
  defp default_type(%Exchange{spec: spec}), do: get_in(spec, ["options", "defaultType"]) || "spot"

  # Unified create_order keys → OKX place-order / place-algo-order body.
  # Authority: OKX v5 Place order + Place algo order schemas (native key names
  # and ordType-specific applicability).
  defp build_create_order(params, exchange) do
    inst_id = native_inst(params["instId"] || params["symbol"], exchange)
    amount = first_present(params, ["sz", "amount"])
    price = first_present(params, ["px", "price"])
    market = find_market(exchange, inst_id)
    family = order_family(params)
    ord_type = resolve_ord_type(params, family)
    order_px = algo_order_price(price, family, market)

    %{}
    |> put_unless_nil("instId", inst_id)
    |> put_unless_nil("tdMode", resolve_td_mode(params, inst_id))
    |> put_unless_nil("side", params["side"])
    |> put_unless_nil("ordType", ord_type)
    |> put_size(params, amount, market, family)
    |> put_primary_price(price, market, family)
    |> put_algo_fields(params, order_px, market, family)
    |> put_attach_algo_ords(params, market)
    |> put_client_order_id(params, family)
    |> put_pos_side(params)
    |> put_spot_market_tgt_ccy(params, inst_id, family)
    |> put_close_fraction(params, family)
    |> put_passthrough(params, ~w(reduceOnly ccy tag banAmend stpId stpMode cxlOnClosePos tradeQuoteCcy))
  end

  defp build_market_order_with_cost(params, side, exchange) do
    inst_id = native_inst(params["instId"] || params["symbol"], exchange)

    params
    |> Map.put("type", "market")
    |> Map.put("side", side)
    |> Map.put("amount", params["cost"])
    |> Map.delete("cost")
    |> put_cost_target_currency(inst_id)
    |> build_create_order(exchange)
  end

  # `tgtCcy` is documented "Only applicable to SPOT Market Orders"; a derivative
  # `sz` is always a contract count, so quote-denominated `cost` cannot be
  # expressed. Fail loudly instead of placing a wrong-sized order.
  defp put_cost_target_currency(params, inst_id) when is_binary(inst_id) do
    if spot_inst?(inst_id) do
      Map.put(params, "tgtCcy", "quote_ccy")
    else
      raise ArgumentError,
            "OKX cost-based market orders are SPOT-only (tgtCcy is a spot market-order field); " <>
              "#{inst_id} is a derivative, whose sz is a contract count. " <>
              "Use createOrder with an explicit contract amount instead."
    end
  end

  defp put_cost_target_currency(params, _inst_id), do: params

  defp build_create_orders(params, orders, exchange) do
    shared = Map.delete(params, "orders")

    Enum.map(orders, fn order ->
      shared
      |> Map.merge(order)
      |> build_create_order(exchange)
    end)
  end

  # Unified edit_order keys → OKX amend-order / amend-algos body.
  # newSz/newPx and new{Sl,Tp}* prices are strings; algo amend uses algoId.
  defp build_edit_order(params, exchange) do
    inst_id = native_inst(params["instId"] || params["symbol"], exchange)
    amount = first_present(params, ["newSz", "sz", "amount"])
    price = first_present(params, ["newPx", "px", "price"])
    market = find_market(exchange, inst_id)
    algo? = algo_edit?(params)

    %{}
    |> put_unless_nil("instId", inst_id)
    |> put_edit_id(params, algo?)
    |> put_unless_nil("newSz", precise_number_string(amount, market, :amount))
    |> put_edit_price(price, market, algo?)
    |> put_edit_tp_sl(params, market, algo?)
    |> put_edit_algo_fields(params, market, algo?)
    |> put_passthrough(params, ~w(cxlOnFail reqId))
  end

  defp build_edit_orders(params, orders, exchange) do
    shared = Map.delete(params, "orders")

    Enum.map(orders, fn order ->
      shared
      |> Map.merge(order)
      |> build_edit_order(exchange)
    end)
  end

  # OKX cancel-all-after documents `timeOut` as String seconds; 0 cancels the
  # timer. Unified `timeout` is milliseconds.
  defp build_cancel_all_orders_after(params) do
    timeout =
      case params do
        %{"timeOut" => value} when not is_nil(value) -> number_string(value)
        %{"timeout" => value} when not is_nil(value) -> value |> timeout_seconds() |> number_string()
        _ -> nil
      end

    %{}
    |> put_unless_nil("timeOut", timeout)
    |> put_unless_nil("tag", params["tag"])
  end

  defp timeout_seconds(value) when is_integer(value), do: div(value, 1000)
  defp timeout_seconds(value) when is_float(value), do: value |> trunc() |> div(1000)

  defp timeout_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> div(int, 1000)
      _ -> value
    end
  end

  defp timeout_seconds(value), do: value

  # fetchMyTrades → trade/fills query: instId from symbol; never leave a raw
  # `symbol` key; do not invent instType (optional on fills, required on
  # fills-history — the latter is the 50014 we deliberately avoid).
  # `since` is OKX's `begin` (ms). Left unmapped it rides as an unknown query key
  # that OKX ignores silently, so the caller's window is dropped without an error
  # — which matters more on this 3-day route than it would on fills-history.
  defp build_fetch_my_trades(params, exchange) do
    inst_id = native_inst(params["instId"] || params["symbol"], exchange)

    params
    |> Map.delete("symbol")
    |> then(fn p -> if is_nil(inst_id), do: p, else: Map.put(p, "instId", inst_id) end)
    |> rename("since", "begin")
  end

  # The normal pending/history routes and their algo siblings deliberately use
  # different identifiers and state vocabularies. `stop`, `trigger`, and
  # `trailing` are unified selectors; their native `ordType` reaches only the
  # matching algo route after endpoint selection.
  defp build_order_history(params, exchange, normal_state) do
    params
    |> drop_archive_type()
    |> put_symbol_inst_type(exchange)
    |> put_order_read_state(normal_state)
    |> put_order_read_ord_type()
  end

  defp put_order_read_state(params, normal_state) do
    state = if algo_order_read?(params), do: algo_order_read_state(normal_state), else: normal_state
    Map.put_new(params, "state", state)
  end

  defp algo_order_read_state("filled"), do: "effective"
  defp algo_order_read_state(state), do: state

  defp put_order_read_ord_type(params) do
    if algo_order_read?(params) and not present_binary?(params["ordType"]) do
      Map.put(params, "ordType", order_read_ord_type(params))
    else
      params
    end
  end

  defp order_read_ord_type(params) do
    cond do
      truthy?(params["trailing"]) -> "move_order_stop"
      truthy?(params["trigger"]) -> "trigger"
      true -> "conditional"
    end
  end

  defp put_order_read_id(params) do
    if algo_order_read?(params), do: rename(params, "ordId", "algoId"), else: params
  end

  defp algo_order_read?(params) do
    truthy?(params["stop"]) or truthy?(params["trailing"]) or truthy?(params["trigger"]) or
      params["ordType"] in ["conditional", "oco", "trigger", "move_order_stop"]
  end

  defp drop_archive_type(%{"type" => "archive"} = params), do: Map.delete(params, "type")
  defp drop_archive_type(params), do: params

  # tdMode: cash for spot; cross default for derivatives; explicit marginMode /
  # tdMode overrides always win (OKX v5 place-order docs).
  defp resolve_td_mode(params, inst_id) do
    case first_present(params, ["tdMode", "marginMode", "margin_mode"]) do
      mode when is_binary(mode) and mode != "" -> mode
      _ -> if spot_inst?(inst_id), do: "cash", else: "cross"
    end
  end

  # Order family drives ordType + which native fields apply. Standalone TP/SL
  # scalars become conditional; stop/trigger prices become trigger; trailing
  # percent/price become move_order_stop. Nested takeProfit/stopLoss maps alone
  # stay on the normal-order surface with attachAlgoOrds.
  defp order_family(params) do
    cond do
      trailing_present?(params) -> :trailing
      explicit_oco?(params) -> :oco
      trigger_present?(params) -> :trigger
      dual_tp_sl?(params) -> :oco
      standalone_tp_sl_present?(params) -> :conditional
      true -> :normal
    end
  end

  defp explicit_oco?(params), do: params["type"] == "oco" or params["ordType"] == "oco"

  defp dual_tp_sl?(params) do
    not is_nil(params["takeProfitPrice"]) and not is_nil(params["stopLossPrice"])
  end

  defp trailing_present?(params) do
    not is_nil(
      first_present(params, ["trailingPercent", "trailingPrice", "trailingAmount", "callbackRatio", "callbackSpread"])
    )
  end

  defp trigger_present?(params) do
    not is_nil(first_present(params, ["triggerPrice", "stopPrice", "triggerPx"])) or
      params["type"] in ["trigger"] or params["ordType"] in ["trigger"]
  end

  defp standalone_tp_sl_present?(params) do
    not is_nil(first_present(params, ["takeProfitPrice", "stopLossPrice"])) or
      params["type"] == "conditional" or params["ordType"] == "conditional"
  end

  defp resolve_ord_type(_params, :trailing), do: "move_order_stop"
  defp resolve_ord_type(_params, :trigger), do: "trigger"
  defp resolve_ord_type(_params, :conditional), do: "conditional"
  defp resolve_ord_type(_params, :oco), do: "oco"

  defp resolve_ord_type(params, :normal) do
    cond do
      truthy?(params["postOnly"]) -> "post_only"
      present_binary?(params["ordType"]) -> params["ordType"]
      present_binary?(params["type"]) -> params["type"]
      true -> "limit"
    end
  end

  defp present_binary?(value) when is_binary(value) and value != "", do: true
  defp present_binary?(_value), do: false

  # Algo order limit price: caller's price, else market → "-1" (OKX market marker).
  defp algo_order_price(price, family, market) when family in [:trigger, :conditional, :oco] do
    case price do
      nil -> "-1"
      "" -> "-1"
      value -> precise_number_string(value, market, :price)
    end
  end

  defp algo_order_price(_price, _family, _market), do: nil

  defp put_size(request, params, amount, market, _family) do
    # closeFraction closes a position fractionally; OKX rejects sz when it is set.
    if is_nil(params["closeFraction"]) do
      put_unless_nil(request, "sz", precise_number_string(amount, market, :amount))
    else
      request
    end
  end

  defp put_primary_price(request, price, market, :normal),
    do: put_unless_nil(request, "px", precise_number_string(price, market, :price))

  defp put_primary_price(request, _price, _market, _family), do: request

  defp put_algo_fields(request, params, order_px, market, :trigger) do
    trigger = first_present(params, ["triggerPx", "triggerPrice", "stopPrice"])

    request
    |> put_unless_nil("triggerPx", precise_number_string(trigger, market, :price) || maybe_number_string(trigger))
    |> put_unless_nil("orderPx", order_px)
    |> put_unless_nil("triggerPxType", params["triggerPxType"])
  end

  defp put_algo_fields(request, params, order_px, market, family) when family in [:conditional, :oco] do
    request
    |> put_conditional_leg(params, "tp", order_px, market)
    |> put_conditional_leg(params, "sl", order_px, market)
  end

  defp put_algo_fields(request, params, _order_px, market, :trailing) do
    request
    |> put_trailing_callback(params, market, "callbackRatio", "callbackSpread")
    |> put_unless_nil(
      "activePx",
      params |> first_present(["activePx", "trailingTriggerPrice"]) |> precise_number_string(market, :price)
    )
  end

  defp put_algo_fields(request, _params, _order_px, _market, :normal), do: request

  defp put_conditional_leg(request, params, "tp", order_px, market) do
    trigger = first_present(params, ["tpTriggerPx", "takeProfitPrice"])

    if is_nil(trigger) do
      request
    else
      request
      |> put_unless_nil("tpTriggerPx", precise_number_string(trigger, market, :price) || number_string(trigger))
      |> put_unless_nil("tpOrdPx", conditional_order_price(params["tpOrdPx"], order_px, market))
      |> Map.put_new("tpTriggerPxType", params["tpTriggerPxType"] || "last")
    end
  end

  defp put_conditional_leg(request, params, "sl", order_px, market) do
    trigger = first_present(params, ["slTriggerPx", "stopLossPrice"])

    if is_nil(trigger) do
      request
    else
      request
      |> put_unless_nil("slTriggerPx", precise_number_string(trigger, market, :price) || number_string(trigger))
      |> put_unless_nil("slOrdPx", conditional_order_price(params["slOrdPx"], order_px, market))
      |> Map.put_new("slTriggerPxType", params["slTriggerPxType"] || "last")
    end
  end

  # trailingPercent is a human percent ("5" → 5%); OKX callbackRatio is a
  # decimal fraction of price ("0.05").
  defp conditional_order_price(nil, fallback, _market), do: fallback

  defp conditional_order_price(value, _fallback, market) do
    precise_number_string(value, market, :price)
  end

  defp trailing_percent_ratio(value) do
    case decimal_or_nil(value) do
      %Decimal{} = decimal ->
        decimal
        |> Decimal.div(Decimal.new(@percent_denominator))
        |> Decimal.normalize()
        |> Decimal.to_string(:normal)

      nil ->
        number_string(value)
    end
  end

  defp put_attach_algo_ords(request, params, market) do
    case first_present(params, ["attachAlgoOrds"]) do
      ords when is_list(ords) and ords != [] ->
        Map.put(request, "attachAlgoOrds", ords)

      _ ->
        case build_attach_algo_ord(params, market) do
          nil -> request
          ord -> Map.put(request, "attachAlgoOrds", [ord])
        end
    end
  end

  defp build_attach_algo_ord(params, market) do
    # Standalone TP/SL scalars own the conditional algo surface; only emit
    # attachAlgoOrds when the primary order is normal (or trigger with attaches).
    if order_family(params) in [:conditional, :oco] do
      nil
    else
      attach_algo_ord_from_params(params, market)
    end
  end

  defp attach_algo_ord_from_params(params, market) do
    tp = nested_tp_sl(params, ["takeProfit", "take_profit"])
    sl = nested_tp_sl(params, ["stopLoss", "stop_loss"])

    if is_nil(tp) and is_nil(sl) do
      nil
    else
      attach =
        %{}
        |> put_attach_leg("tp", tp, market)
        |> put_attach_leg("sl", sl, market)

      if map_size(attach) == 0, do: nil, else: attach
    end
  end

  # Nested maps or bare scalars under takeProfit/stopLoss become attach legs.
  # Pure takeProfitPrice/stopLossPrice scalars are standalone conditionals (not
  # attach) and never reach this helper.
  defp nested_tp_sl(params, map_keys) do
    case first_present(params, map_keys) do
      %{} = map ->
        %{
          trigger: first_present(map, ["triggerPrice", "stopPrice", "price", "tpTriggerPx", "slTriggerPx"]),
          order_price: first_present(map, ["orderPrice", "limitPrice", "tpOrdPx", "slOrdPx"]),
          trigger_type: first_present(map, ["triggerPriceType", "tpTriggerPxType", "slTriggerPxType"])
        }

      scalar when not is_nil(scalar) and scalar != "" ->
        %{trigger: scalar, order_price: nil, trigger_type: nil}

      _ ->
        nil
    end
  end

  defp put_attach_leg(attach, "tp", nil, _market), do: attach

  defp put_attach_leg(attach, "tp", %{trigger: trigger} = leg, market) when not is_nil(trigger) do
    attach
    |> put_unless_nil("tpTriggerPx", precise_number_string(trigger, market, :price) || number_string(trigger))
    |> put_unless_nil("tpOrdPx", attach_order_price(leg[:order_price]))
    |> Map.put_new("tpTriggerPxType", leg[:trigger_type] || "last")
  end

  defp put_attach_leg(attach, "tp", _leg, _market), do: attach

  defp put_attach_leg(attach, "sl", nil, _market), do: attach

  defp put_attach_leg(attach, "sl", %{trigger: trigger} = leg, market) when not is_nil(trigger) do
    attach
    |> put_unless_nil("slTriggerPx", precise_number_string(trigger, market, :price) || number_string(trigger))
    |> put_unless_nil("slOrdPx", attach_order_price(leg[:order_price]))
    |> Map.put_new("slTriggerPxType", leg[:trigger_type] || "last")
  end

  defp put_attach_leg(attach, "sl", _leg, _market), do: attach

  defp attach_order_price(nil), do: "-1"
  defp attach_order_price(""), do: "-1"
  defp attach_order_price(price), do: number_string(price)

  defp put_pos_side(request, params) do
    cond do
      is_binary(params["posSide"]) and params["posSide"] != "" ->
        Map.put(request, "posSide", params["posSide"])

      truthy?(params["hedged"]) and params["side"] == "sell" ->
        Map.put(request, "posSide", "long")

      truthy?(params["hedged"]) and params["side"] == "buy" ->
        Map.put(request, "posSide", "short")

      true ->
        request
    end
  end

  # Spot market buys require tgtCcy on OKX (base_ccy when sz is base amount).
  # Algo and normal place surfaces share this requirement.
  defp put_spot_market_tgt_ccy(request, params, inst_id, family) do
    market_like? = request["ordType"] in ["market", "conditional", "oco", "trigger", "move_order_stop"]
    spot? = spot_inst?(inst_id)
    buy? = params["side"] == "buy"
    already? = not is_nil(params["tgtCcy"]) or not is_nil(request["tgtCcy"])

    if family != :normal and market_like? and spot? and buy? and not already? do
      Map.put(request, "tgtCcy", "base_ccy")
    else
      case params["tgtCcy"] do
        nil -> request
        value -> Map.put_new(request, "tgtCcy", value)
      end
    end
  end

  defp algo_edit?(params) do
    not is_nil(params["algoId"]) or
      params["type"] in ["conditional", "trigger", "move_order_stop", "oco"] or
      params["ordType"] in ["conditional", "trigger", "move_order_stop", "oco"] or
      trailing_edit_present?(params) or trigger_edit_present?(params)
  end

  defp put_edit_id(request, params, true = _algo?) do
    algo_id = first_present(params, ["algoId", "ordId", "id"])
    client_id = first_present(params, ["algoClOrdId", "clOrdId", "clientOrderId"])

    request
    |> put_unless_nil("algoId", if(is_nil(algo_id), do: nil, else: to_string(algo_id)))
    |> put_unless_nil("algoClOrdId", client_id)
  end

  defp put_edit_id(request, params, false = _algo?) do
    ord_id = first_present(params, ["ordId", "id"])
    client_id = first_present(params, ["clOrdId", "clientOrderId"])

    request
    |> put_unless_nil("ordId", if(is_nil(ord_id), do: nil, else: to_string(ord_id)))
    |> put_unless_nil("clOrdId", client_id)
  end

  defp put_edit_price(request, _price, _market, true = _algo?), do: request

  defp put_edit_price(request, price, market, false = _algo?) do
    put_unless_nil(request, "newPx", precise_number_string(price, market, :price))
  end

  defp put_edit_tp_sl(request, params, market, true = _algo?) do
    request
    |> put_edit_leg(params, market, :tp, false)
    |> put_edit_leg(params, market, :sl, false)
  end

  defp put_edit_tp_sl(request, params, market, false = _algo?) do
    attach =
      %{}
      |> put_edit_leg(params, market, :tp, true)
      |> put_edit_leg(params, market, :sl, true)
      |> put_unless_nil("attachAlgoId", params["attachAlgoId"])
      |> put_unless_nil("attachAlgoClOrdId", params["attachAlgoClOrdId"])

    if map_size(attach) == 0, do: request, else: Map.put(request, "attachAlgoOrds", [attach])
  end

  defp put_edit_leg(request, params, market, :tp, include_kind?) do
    {trigger, order_px, kind} =
      edit_leg_values(params, ["takeProfitPrice", "newTpTriggerPx"], ["takeProfit"], ["newTpOrdPx"])

    request
    |> put_unless_nil("newTpTriggerPx", precise_number_string(trigger, market, :price) || maybe_number_string(trigger))
    |> put_unless_nil("newTpOrdPx", precise_number_string(order_px, market, :price) || maybe_number_string(order_px))
    |> then(fn req ->
      if is_nil(trigger) do
        req
      else
        req
        |> Map.put_new("newTpTriggerPxType", params["newTpTriggerPxType"] || "last")
        |> put_edit_tp_kind(kind || params["newTpOrdKind"], include_kind?)
      end
    end)
  end

  defp put_edit_leg(request, params, market, :sl, _include_kind?) do
    {trigger, order_px, _kind} =
      edit_leg_values(params, ["stopLossPrice", "newSlTriggerPx"], ["stopLoss"], ["newSlOrdPx"])

    request
    |> put_unless_nil("newSlTriggerPx", precise_number_string(trigger, market, :price) || maybe_number_string(trigger))
    |> put_unless_nil("newSlOrdPx", precise_number_string(order_px, market, :price) || maybe_number_string(order_px))
    |> then(fn req ->
      if is_nil(trigger) do
        req
      else
        Map.put_new(req, "newSlTriggerPxType", params["newSlTriggerPxType"] || "last")
      end
    end)
  end

  defp put_edit_tp_kind(request, kind, true = _include_kind?), do: put_unless_nil(request, "newTpOrdKind", kind)
  defp put_edit_tp_kind(request, _kind, false = _include_kind?), do: request

  defp put_edit_algo_fields(request, _params, _market, false = _algo?), do: request

  defp put_edit_algo_fields(request, params, market, true = _algo?) do
    case edit_algo_family(params) do
      :trigger ->
        put_edit_trigger_fields(request, params, market)

      :trailing ->
        request
        |> put_trailing_callback(params, market, "newCallbackRatio", "newCallbackSpread")
        |> put_edit_active_price(params, market)

      _ ->
        request
    end
  end

  defp edit_algo_family(params) do
    cond do
      params["type"] == "move_order_stop" or params["ordType"] == "move_order_stop" or trailing_edit_present?(params) ->
        :trailing

      params["type"] == "trigger" or params["ordType"] == "trigger" or trigger_edit_present?(params) ->
        :trigger

      true ->
        :conditional
    end
  end

  defp trailing_edit_present?(params) do
    not is_nil(
      first_present(params, [
        "newCallbackRatio",
        "newCallbackSpread",
        "newActivePx",
        "trailingPercent",
        "trailingPrice",
        "trailingAmount",
        "trailingTriggerPrice"
      ])
    )
  end

  defp trigger_edit_present?(params) do
    not is_nil(first_present(params, ["newTriggerPx", "newOrdPx", "triggerPx", "triggerPrice", "stopPrice"]))
  end

  defp put_edit_trigger_fields(request, params, market) do
    trigger = first_present(params, ["newTriggerPx", "triggerPx", "triggerPrice", "stopPrice"])
    order_px = first_present(params, ["newOrdPx", "newPx", "px", "price"])

    request
    |> put_unless_nil("newTriggerPx", precise_number_string(trigger, market, :price))
    |> put_unless_nil("newOrdPx", precise_number_string(order_px, market, :price))
    |> put_unless_nil("newTriggerPxType", params["newTriggerPxType"] || params["triggerPxType"])
  end

  defp put_edit_active_price(request, params, market) do
    active_px = first_present(params, ["newActivePx", "activePx", "trailingTriggerPrice"])
    put_unless_nil(request, "newActivePx", precise_number_string(active_px, market, :price))
  end

  defp put_trailing_callback(request, params, market, ratio_key, spread_key) do
    cond do
      not is_nil(params[ratio_key]) ->
        put_unless_nil(request, ratio_key, number_string(params[ratio_key]))

      ratio_key == "callbackRatio" and not is_nil(params["callbackRatio"]) ->
        put_unless_nil(request, ratio_key, number_string(params["callbackRatio"]))

      not is_nil(params["trailingPercent"]) ->
        put_unless_nil(request, ratio_key, trailing_percent_ratio(params["trailingPercent"]))

      true ->
        put_trailing_spread(request, params, market, spread_key)
    end
  end

  defp put_trailing_spread(request, params, market, spread_key) do
    value = first_present(params, [spread_key, "callbackSpread", "trailingPrice", "trailingAmount"])
    put_unless_nil(request, spread_key, precise_number_string(value, market, :price))
  end

  defp edit_leg_values(params, scalar_keys, map_keys, order_px_keys) do
    case first_present(params, map_keys) do
      %{} = map ->
        {
          first_present(map, ["triggerPrice", "stopPrice", "price"]),
          first_present(params, order_px_keys) || first_present(map, ["price", "orderPrice", "limitPrice"]),
          "condition"
        }

      _ ->
        {
          first_present(params, scalar_keys),
          first_present(params, order_px_keys),
          nil
        }
    end
  end

  defp maybe_number_string(nil), do: nil
  defp maybe_number_string(value), do: number_string(value)

  defp spot_inst?(inst_id) when is_binary(inst_id) do
    match?([_base, _quote], String.split(inst_id, "-"))
  end

  defp spot_inst?(_), do: true

  defp put_client_order_id(request, params, :normal) do
    case first_present(params, ["clOrdId", "clientOrderId"]) do
      nil -> request
      id -> Map.put(request, "clOrdId", id)
    end
  end

  defp put_client_order_id(request, params, _algo_family) do
    case first_present(params, ["algoClOrdId", "clOrdId", "clientOrderId"]) do
      nil -> request
      id -> Map.put(request, "algoClOrdId", number_string(id))
    end
  end

  defp put_close_fraction(request, params, family) when family in [:conditional, :oco] do
    put_unless_nil(request, "closeFraction", maybe_number_string(params["closeFraction"]))
  end

  defp put_close_fraction(request, _params, _family), do: request

  defp put_passthrough(request, params, keys) do
    Enum.reduce(keys, request, fn key, acc ->
      case Map.get(params, key) do
        nil -> acc
        value -> Map.put_new(acc, key, value)
      end
    end)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp first_present(params, keys) do
    Enum.find_value(keys, &Map.get(params, &1))
  end

  # OKX v5 documents sz/px as String on place/amend; keep integers/floats as
  # plain decimal strings rather than scientific notation.
  defp number_string(value) when is_binary(value), do: value
  defp number_string(value) when is_integer(value), do: Integer.to_string(value)

  defp number_string(value) when is_float(value) do
    :erlang.float_to_binary(value, [:compact, {:decimals, 16}])
  end

  defp number_string(value), do: to_string(value)

  # OKX publishes `lotSz`/`tickSz` per instrument on /api/v5/public/instruments;
  # fetchMarkets lands them in `market.precision` as increments, not decimal
  # places (live my.okx.com 2026-07-19: BTC-USDT => %{"amount" => 1.0e-8,
  # "price" => 0.1}). Amounts truncate toward zero to a whole lot; prices snap to
  # the nearest tick. An unloaded or unmatched market keeps the legacy value.
  defp precise_number_string(nil, _market, _field), do: nil

  defp precise_number_string(value, market, field) do
    with step when not is_nil(step) <- market_step(market, field),
         parsed when not is_nil(parsed) <- decimal_or_nil(value) do
      round_to_step(parsed, value, step, field)
    else
      _ -> number_string(value)
    end
  end

  # `Exchange.market_cache/0` admits raw maps alongside `%Bourse.Market{}`, so read
  # both key shapes — an atom-only read silently skips precision on raw markets.
  defp find_market(%Exchange{markets: markets}, inst_id) when is_list(markets) and is_binary(inst_id) do
    Enum.find(markets, &(market_field(&1, "id", :id) == inst_id))
  end

  defp find_market(_exchange, _inst_id), do: nil

  defp market_step(market, :amount), do: market |> precision_map() |> market_field("amount", :amount) |> decimal_or_nil()
  defp market_step(market, :price), do: market |> precision_map() |> market_field("price", :price) |> decimal_or_nil()

  defp precision_map(market), do: market_field(market, "precision", :precision)

  defp market_field(map, string_key, atom_key) when is_map(map), do: Map.get(map, string_key) || Map.get(map, atom_key)
  defp market_field(_map, _string_key, _atom_key), do: nil

  defp decimal_or_nil(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_nil(value) when is_float(value), do: Decimal.from_float(value)

  defp decimal_or_nil(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp decimal_or_nil(_value), do: nil

  # Rounding lands on zero when the caller asks for less than one lot (or tick).
  # No client-side rounding can satisfy that, and emitting "0" would swap the
  # caller's intent for a wire value OKX rejects with an opaque parameter error —
  # forward the original so 51121/51006 names the size actually requested.
  defp round_to_step(parsed, original, step, field) do
    rounded = parsed |> Decimal.div(step) |> Decimal.round(0, rounding_mode(field)) |> Decimal.mult(step)

    if Decimal.equal?(rounded, 0) and not Decimal.equal?(parsed, 0),
      do: number_string(original),
      else: rounded |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp rounding_mode(:amount), do: :down
  defp rounding_mode(:price), do: :half_up

  # Singular plain cancel stays an object for trade/cancel-order; stop/trailing/
  # trigger orders use the cancel-algos array.
  defp build_cancel_order(params, exchange) do
    if algo_cancel?(params) do
      [cancel_row(params, native_inst(params["instId"] || params["symbol"], exchange), true)]
    else
      params
    end
  end

  defp build_cancel_orders(params, exchange) do
    inst_id = native_inst(params["instId"] || params["symbol"], exchange)
    algo? = algo_cancel?(params)
    client_ids = cancel_client_ids(params)

    if client_ids == [] do
      id_key = cancel_id_key(algo?, :server)
      Enum.map(List.wrap(params["ids"] || params["algoId"]), &%{id_key => to_string(&1), "instId" => inst_id})
    else
      id_key = cancel_id_key(algo?, :client)
      Enum.map(client_ids, &%{id_key => &1, "instId" => inst_id})
    end
  end

  defp build_cancel_orders_for_symbols(params, exchange) do
    algo? = algo_cancel?(params)

    Enum.map(List.wrap(params["orders"]), fn order when is_map(order) ->
      cancel_row(order, native_inst(order["symbol"] || order["instId"], exchange), algo?)
    end)
  end

  defp cancel_row(source, inst_id, algo?) do
    client_id = source["algoClOrdId"] || source["clOrdId"] || source["clientOrderId"]

    if present_client_id?(client_id) do
      %{cancel_id_key(algo?, :client) => client_id, "instId" => inst_id}
    else
      id = source["algoId"] || source["ordId"] || source["id"]
      %{cancel_id_key(algo?, :server) => to_string(id), "instId" => inst_id}
    end
  end

  defp cancel_id_key(true, :client), do: "algoClOrdId"
  defp cancel_id_key(false, :client), do: "clOrdId"
  defp cancel_id_key(true, :server), do: "algoId"
  defp cancel_id_key(false, :server), do: "ordId"

  defp present_client_id?(id) when is_binary(id) and id != "", do: true
  defp present_client_id?(_), do: false

  defp algo_cancel?(params), do: truthy?(params["stop"]) or truthy?(params["trailing"]) or truthy?(params["trigger"])

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false

  defp cancel_client_ids(params) do
    params
    |> Map.get("clOrdId", Map.get(params, "clientOrderId"))
    |> List.wrap()
    |> Enum.filter(&present_client_id?/1)
  end

  # After maybe_denormalize_symbol the top-level symbol is already native
  # (BTC-USDT / BTC-USDT-SWAP). Nested cancelOrdersForSymbols rows still carry
  # unified symbols and need conversion.
  defp native_inst(symbol, %Exchange{} = exchange) when is_binary(symbol) do
    if String.contains?(symbol, "/") or String.contains?(symbol, ":") do
      Symbol.to_exchange_id(symbol, exchange)
    else
      symbol
    end
  end

  defp native_inst(_symbol, _exchange), do: nil

  defp put_inst_type(params, exchange, default) do
    type = params["instType"] || params["type"] || default
    params |> Map.put("instType", exchange_type(exchange, type)) |> Map.delete("type")
  end

  defp symbols_market_type(%{"symbols" => [symbol | _]}) when is_binary(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, parsed} -> parsed |> Symbol.detect_market_type() |> Atom.to_string()
      _ -> inst_id_market_type(symbol)
    end
  end

  defp symbols_market_type(_params), do: nil

  # OKX requires instType on the instrument-scoped reads, and it must agree with
  # the symbol's market type — a SPOT default against a swap instId is rejected
  # with 50016, and omitting it entirely with 50014.
  defp put_symbol_inst_type(params, exchange) do
    put_inst_type(params, exchange, market_type(params) || default_type(exchange))
  end

  # `account/trade-fee` additionally keys on the instrument id only for
  # SPOT/MARGIN; a derivative must be addressed by its family, and passing instId
  # there is rejected with 50016 "instId and instType don't match" (verified live
  # on the OKX EEA demo, 2026-07-16).
  defp put_trading_fee_instrument(params, exchange) do
    type = market_type(params) || default_type(exchange)
    params |> put_inst_type(exchange, type) |> put_fee_instrument(type)
  end

  defp put_fee_instrument(params, type) when type in ["spot", "margin"], do: params

  defp put_fee_instrument(params, _type) do
    case inst_family(params["instId"]) do
      nil -> params
      family -> params |> Map.put_new("instFamily", family) |> Map.delete("instId")
    end
  end

  defp market_type(%{"instType" => inst_type}) when is_binary(inst_type), do: inst_type
  defp market_type(%{"type" => type}) when is_binary(type), do: type

  defp market_type(%{"instId" => inst_id}) when is_binary(inst_id) do
    case Symbol.parse_extended(inst_id) do
      {:ok, parsed} -> parsed |> Symbol.detect_market_type() |> Atom.to_string()
      _ -> inst_id_market_type(inst_id)
    end
  end

  defp market_type(_params), do: nil

  # Fallback for an already-denormalized OKX instrument id (BTC-USDT-SWAP,
  # BTC-USD-260327, BTC-USD-260327-100000-C), which is not a unified symbol.
  defp inst_id_market_type(inst_id) do
    case String.split(inst_id, "-") do
      [_base, _quote] -> "spot"
      [_base, _quote, "SWAP"] -> "swap"
      [_base, _quote, _expiry] -> "future"
      [_base, _quote, _expiry, _strike, _side] -> "option"
      _ -> nil
    end
  end

  defp exchange_type(exchange, type) when is_binary(type) do
    get_in(exchange.spec, ["options", "exchangeType", type]) || String.upcase(type)
  end

  defp rename(params, source, target) do
    case Map.pop(params, source) do
      {nil, params} -> params
      {value, params} -> Map.put_new(params, target, value)
    end
  end

  defp put_margin_sub_type(%{"type" => type} = params) do
    sub_type = Map.get(@margin_sub_types, type, type)
    params |> Map.put("subType", sub_type) |> Map.delete("type")
  end

  defp put_margin_sub_type(params), do: params

  # Unified closePosition second arg is Bourse's buy/sell side; OKX close-position
  # wants posSide long/short. An absent side is net mode and omits posSide; any
  # other value rides through verbatim so OKX answers with its own 51000
  # "Parameter posSide error" rather than this client silently closing without a
  # posSide (which net-mode accounts would accept).
  defp put_close_pos_side(params) do
    {side, params} = Map.pop(params, "side")

    case side do
      nil -> params
      "buy" -> Map.put_new(params, "posSide", "long")
      "sell" -> Map.put_new(params, "posSide", "short")
      other -> Map.put_new(params, "posSide", other)
    end
  end

  # Unified `limit` is the caller's requested depth; OKX names it `sz`.
  defp put_order_book_depth(params) do
    {limit, params} = Map.pop(params, "limit")
    default = if full_order_book?(params), do: @default_full_order_book_depth, else: @default_order_book_depth
    Map.put_new(params, "sz", params["sz"] || limit || default)
  end

  defp full_order_book?(params), do: params["method"] in ["books-full", "publicGetMarketBooksFull"]

  defp build_ohlcv(params) do
    bar = params["bar"] || @default_ohlcv_bar
    limit = ohlcv_limit(params)
    since = params["since"]
    until_ms = params["until"]

    params
    |> Map.drop(~w(since timeframe type price until))
    |> Map.put("bar", bar)
    |> Map.put("limit", limit)
    |> put_ohlcv_window(since, until_ms, bar, limit)
  end

  defp ohlcv_limit(params) do
    max_limit = if params["price"] in ["index", "mark"], do: @max_index_ohlcv_limit, else: @max_ohlcv_limit

    default =
      if params["type"] == "HistoryCandles",
        do: @max_ohlcv_limit,
        else: @default_ohlcv_limit

    params
    |> Map.get("limit", default)
    |> positive_integer(default)
    |> min(max_limit)
  end

  defp put_ohlcv_window(params, since, until_ms, _bar, _limit) when is_integer(since) and is_integer(until_ms) do
    put_ohlcv_cursors(params, since, until_ms)
  end

  defp put_ohlcv_window(params, since, _until_ms, bar, limit) when is_integer(since) do
    put_ohlcv_cursors(params, since, since + timeframe_ms(bar) * limit)
  end

  defp put_ohlcv_window(params, _since, until_ms, bar, limit) when is_integer(until_ms) do
    window_start = max(until_ms - timeframe_ms(bar) * limit, 0)
    put_ohlcv_cursors(params, window_start, until_ms)
  end

  defp put_ohlcv_window(params, _since, _until_ms, _bar, _limit), do: params

  defp put_ohlcv_cursors(params, since, until_ms) do
    params
    |> put_exclusive_before(since)
    |> put_exclusive_after(until_ms)
  end

  defp timeframe_ms(bar) when is_binary(bar) do
    case Regex.run(~r/^(\d+)([mHDWM])(?:utc)?$/, bar, capture: :all_but_first) do
      [amount, unit] -> String.to_integer(amount) * timeframe_unit_ms(unit)
      _ -> @milliseconds_per_minute
    end
  end

  defp timeframe_ms(_bar), do: @milliseconds_per_minute

  defp timeframe_unit_ms("m"), do: @milliseconds_per_minute
  defp timeframe_unit_ms("H"), do: @minutes_per_hour * @milliseconds_per_minute
  defp timeframe_unit_ms("D"), do: @hours_per_day * timeframe_unit_ms("H")
  defp timeframe_unit_ms("W"), do: @days_per_week * timeframe_unit_ms("D")
  defp timeframe_unit_ms("M"), do: @days_per_month * timeframe_unit_ms("D")

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp build_deposits(params) do
    {since, params} = Map.pop(params, "since")
    {until_ms, params} = Map.pop(params, "until")

    params
    |> rename("code", "ccy")
    |> put_exclusive_before(since)
    |> put_exclusive_after(until_ms)
  end

  # OKX pagination `before`/`after` exclude the cursor. Unified since/until are
  # inclusive, so the request sends since-1 / until+1.
  defp put_exclusive_before(params, since) when is_integer(since),
    do: Map.put_new(params, "before", max(since - @exclusive_time_offset_ms, 0))

  defp put_exclusive_before(params, _since), do: params

  defp put_exclusive_after(params, until_ms) when is_integer(until_ms),
    do: Map.put(params, "after", until_ms + @exclusive_time_offset_ms)

  defp put_exclusive_after(params, _until_ms), do: params

  # OKX documents amt/fee as String; unified amount/fee arrive as numbers. Network
  # is a unified code (TRC20) that must become the composite chain (USDT-TRC20) —
  # leaving network on the wire is ignored and the venue withdraws on the
  # default chain (silent money-path wrong request).
  defp build_withdraw(params, exchange) do
    params
    |> rename("code", "ccy")
    |> stringify_present("amt")
    |> stringify_present("fee")
    |> put_withdraw_chain(exchange)
  end

  defp put_withdraw_chain(params, exchange) do
    {network, params} = Map.pop(params, "network")

    cond do
      present_binary?(params["chain"]) ->
        params

      present_binary?(network) and present_binary?(params["ccy"]) ->
        Map.put(params, "chain", params["ccy"] <> "-" <> network_to_chain_suffix(network, exchange))

      true ->
        params
    end
  end

  # `config.routing.networks` maps unified codes onto OKX's chain suffix
  # (ETH→ERC20, BTC→Bitcoin, TRC20→TRC20). Unknown codes pass through so the
  # venue can reject an invented chain rather than this client inventing one.
  defp network_to_chain_suffix(network, exchange) when is_binary(network) do
    networks = Exchange.routing(exchange)["networks"] || %{}
    upper = String.upcase(network)
    Map.get(networks, upper) || Map.get(networks, network) || network
  end

  defp stringify_present(params, key) do
    case Map.get(params, key) do
      nil -> params
      value -> Map.put(params, key, number_string(value))
    end
  end

  # Funding bills archive: type=8 is the funding-fee bill type (authored default).
  # OKX filters by bill currency + contract type, not by instrument id — so a
  # linear swap symbol yields ctType=linear and ccy=quote, while inverse yields
  # ctType=inverse and ccy=base. instType is set only for SWAP.
  defp build_funding_history(params, exchange) do
    symbol = params["symbol"] || params["instId"]

    params
    |> Map.drop(["symbol", "instId"])
    |> put_funding_symbol_filters(symbol, exchange)
  end

  # Contract filter is `{type, linear?, base, quote}` — a private 4-tuple so the
  # three construction sites share one shape without a public struct.
  defp put_funding_symbol_filters(params, symbol, exchange) when is_binary(symbol) do
    case funding_contract_info(symbol) do
      {type, true, _base, quote} ->
        params
        |> Map.put_new("ctType", "linear")
        |> Map.put_new("ccy", quote)
        |> put_funding_inst_type(type, exchange)

      {type, false, base, _quote} ->
        params
        |> Map.put_new("ctType", "inverse")
        |> Map.put_new("ccy", base)
        |> put_funding_inst_type(type, exchange)

      _ ->
        params
    end
  end

  defp put_funding_symbol_filters(params, _symbol, _exchange), do: params

  defp put_funding_inst_type(params, :swap, exchange),
    do: Map.put_new(params, "instType", exchange_type(exchange, "swap"))

  defp put_funding_inst_type(params, _type, _exchange), do: params

  # Unified (BTC/USDT:USDT) or native (BTC-USDT-SWAP) forms after denormalization.
  # Linear when settle equals quote; inverse when settle equals base. Native
  # SWAP/FUTURES without an explicit settle treat non-USD quotes as linear.
  defp funding_contract_info(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, %{base: base, quote: quote, settle: settle} = parsed} when is_binary(settle) ->
        type = Symbol.detect_market_type(parsed)
        if type in [:swap, :future], do: {type, settle == quote, base, quote}

      _ ->
        funding_contract_info_from_inst_id(symbol)
    end
  end

  defp funding_contract_info_from_inst_id(inst_id) when is_binary(inst_id) do
    case String.split(inst_id, "-") do
      [base, quote, "SWAP"] when base != "" and quote != "" ->
        {:swap, quote != "USD", base, quote}

      [base, quote, _expiry] when base != "" and quote != "" ->
        {:future, quote != "USD", base, quote}

      _ ->
        nil
    end
  end

  defp build_option_chain(params) do
    family = option_underlying(params["uly"] || params["code"] || params["symbol"])

    params
    |> Map.drop(~w(code symbol))
    |> Map.put_new("instType", "OPTION")
    |> put_unless_nil("uly", family)
  end

  # Bare base (BTC) → BTC-USD under the registered settle premise. Explicit
  # BASE-USD families pass. Any other settle (or non-family shape) raises so a
  # non-USD request cannot be shaped silently.
  defp option_underlying(value) when is_binary(value) do
    cond do
      bare_option_base?(value) ->
        value <> "-" <> @option_underlying_settle

      option_family_settle(value) == @option_underlying_settle ->
        value

      true ->
        raise ArgumentError,
              "unsupported OKX option underlying #{inspect(value)}; " <>
                "expected a bare base or BASE-#{@option_underlying_settle} family " <>
                "(registered settle is #{@option_underlying_settle})"
    end
  end

  defp option_underlying(_value), do: nil

  defp bare_option_base?(value), do: value != "" and not String.contains?(value, "-") and not String.contains?(value, "/")

  defp option_family_settle(value) do
    case String.split(value, "-", parts: 3) do
      [base, settle] when base != "" and settle != "" -> settle
      _ -> nil
    end
  end

  defp build_all_greeks(params, exchange) do
    inst_id = params |> Map.get("symbols", []) |> List.wrap() |> List.first() |> native_inst(exchange)
    family = params["instFamily"] || option_underlying(params["uly"]) || inst_family(inst_id)

    params
    |> Map.drop(~w(symbols instId))
    |> put_unless_nil("uly", params["uly"] || family)
    |> put_unless_nil("instFamily", family)
    |> put_unless_nil("expTime", option_expiry(inst_id))
  end

  defp option_expiry(inst_id) when is_binary(inst_id) do
    case String.split(inst_id, "-") do
      [_base, _quote, expiry, _strike, side] when side in ["C", "P"] -> expiry
      _ -> nil
    end
  end

  defp option_expiry(_inst_id), do: nil

  defp build_open_interest_history(params, endpoint_path) do
    currency = params |> Map.get("ccy") |> base_currency()
    {endpoint_path, periods} = open_interest_period_config(endpoint_path)
    period = normalize_period(params["timeframe"] || params["period"], periods, endpoint_path)

    params
    |> Map.drop(~w(symbol instId timeframe limit))
    |> Map.put("ccy", currency)
    |> Map.put("period", period)
    |> rename("since", "begin")
    |> rename("until", "end")
  end

  defp base_currency(value) when is_binary(value) do
    value
    |> String.split(["/", "-"], parts: 2)
    |> List.first()
  end

  defp base_currency(value), do: value

  defp open_interest_period_config(@contracts_open_interest_path),
    do: {@contracts_open_interest_path, @contracts_open_interest_periods}

  defp open_interest_period_config(@option_open_interest_path),
    do: {@option_open_interest_path, @option_open_interest_periods}

  defp open_interest_period_config(nil), do: {@contracts_open_interest_path, @contracts_open_interest_periods}

  defp open_interest_period_config(endpoint_path) do
    raise ArgumentError,
          "unsupported OKX open-interest endpoint #{inspect(endpoint_path)}; " <>
            "supported: #{@contracts_open_interest_path}, #{@option_open_interest_path}"
  end

  defp normalize_period(nil, _periods, _endpoint_path), do: @default_open_interest_period

  defp normalize_period(period, periods, endpoint_path) do
    case Map.fetch(periods, period) do
      {:ok, native} ->
        native

      :error ->
        supported =
          periods
          |> Map.keys()
          |> Enum.sort()
          |> Enum.join(", ")

        raise ArgumentError,
              "unsupported OKX open-interest period #{inspect(period)} for #{endpoint_path}; " <>
                "supported: #{supported}"
    end
  end

  defp build_positions(params, exchange) do
    case params["symbols"] do
      symbols when is_list(symbols) and symbols != [] ->
        inst_ids = Enum.map_join(symbols, ",", &native_inst(&1, exchange))
        params |> Map.put("instId", inst_ids) |> Map.delete("symbols")

      _ ->
        Map.delete(params, "symbols")
    end
  end

  defp build_positions_history(params, exchange) do
    inst_id =
      case params["symbols"] do
        [symbol] -> native_inst(symbol, exchange)
        _ -> nil
      end

    {until_ms, params} = Map.pop(params, "until")

    params
    |> Map.drop(~w(symbols since))
    |> put_exclusive_after(until_ms)
    |> Map.put_new("limit", @default_positions_history_limit)
    |> rename("marginMode", "mgnMode")
    |> put_unless_nil("instId", inst_id)
    |> uppercase_if_present("instType")
  end

  defp uppercase_if_present(params, key) do
    case params[key] do
      value when is_binary(value) -> Map.put(params, key, String.upcase(value))
      _ -> params
    end
  end

  # `from`/`to` are already renamed from unified from_account/to_account by the
  # authored spec entries; OKX wants its numeric account ids (funding=6, trading=18).
  defp map_transfer_accounts(params, exchange) do
    params
    |> map_account("from", exchange)
    |> map_account("to", exchange)
  end

  defp map_account(params, key, exchange) do
    case get_in(exchange.spec, ["options", "accountsByType", to_string(params[key])]) do
      nil -> params
      account_id -> Map.put(params, key, account_id)
    end
  end

  # `public/opt-summary` keys on the option family (BTC-USD), never the full
  # instrument id. The authored identifier_reference resolves instFamily/uly to the
  # instrument id, so narrow it here and drop the redundant `uly` alias.
  defp put_option_family(params) do
    case inst_family(params["instFamily"] || params["uly"] || params["instId"]) do
      nil -> params
      family -> params |> Map.put("instFamily", family) |> Map.delete("uly")
    end
  end

  # An OKX derivative id is `<family>-<contract-specifics>` — BTC-USDT-SWAP,
  # BTC-USD-260327, BTC-USD-260717-48000-C — so the family is its first two
  # segments. A shorter id (a spot pair, or an id we do not recognise) has no
  # family; return nil rather than guess, and let the venue reject in its own words.
  defp inst_family(inst_id) when is_binary(inst_id) do
    case String.split(inst_id, "-") do
      [base, quote_ccy, _ | _] -> base <> "-" <> quote_ccy
      _ -> nil
    end
  end

  defp inst_family(_inst_id), do: nil
end
