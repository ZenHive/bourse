defmodule Bourse.Unified do
  # Internal: method definitions and dispatch for unified API functions.
  #
  # The @method_defs list is the single source of truth for unified methods.
  # Each entry: {elixir_name, js_capability_name, required_params, description}.
  # Bourse module generates functions + bang variants + api() declarations from
  # this list at compile time.
  #
  # Optional params (since, limit, price, tag, symbols, etc.) go in opts.
  @moduledoc false

  alias Bourse.CoinbaseCandlePagination
  alias Bourse.Dispatch
  alias Bourse.Emulation
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Order.Sanity
  alias Bourse.Registry
  alias Bourse.Safe
  alias Bourse.Symbol
  alias Bourse.Unified.DeribitPositionUnits
  alias Bourse.Unified.Descriptor
  alias Bourse.Unified.FieldMaps
  alias Bourse.Unified.FundingInterval
  alias Bourse.Unified.OrderPrecision
  alias Bourse.Unified.ReadParse
  alias Bourse.Unified.RequestShape

  # Dispatch-level opts separated from exchange params
  @dispatch_opts [
    :endpoint_index,
    :market_type,
    :timeout,
    :plug,
    :headers,
    :base_url,
    :sanity,
    :timestamp_ms_override,
    :nonce_override
  ]

  # Dispatch opts that only steer endpoint SELECTION — they are consumed before
  # the request is built and are not Req options, so they must be dropped before
  # the call reaches `Bourse.HTTP` (Req raises `unknown option` otherwise).
  @selection_opts [:endpoint_index, :market_type]

  @sanity_methods [:create_order, :edit_order]
  @list_required_params [:ids, :orders]

  # First endpoint section names preferred per market type when multiple unified
  # routes exist (e.g. Binance spot "public" vs fapi/dapi/eapiPublic).
  @spot_sections ~w(public v1 private sapi sapiV2 sapiV3 sapiV4)
  @swap_sections ~w(fapiPublicV3 fapiPublicV2 fapiPublic fapiData fapiPrivateV3 fapiPrivateV2 fapiPrivate linearPublic contractPublic swapPublic)
  @future_sections ~w(dapiPublic dapiData dapiPrivateV2 dapiPrivate inversePublic deliveryPublic futurePublic)
  @option_sections ~w(eapiPublic eapiPrivate optionPublic optionsPublic)

  @endpoint_selection_param_sets [
    {~s(type: "spot"), %{"type" => "spot"}},
    {~s(type: "swap"), %{"type" => "swap"}},
    {~s(type: "future"), %{"type" => "future"}},
    {~s(type: "option"), %{"type" => "option"}},
    {~s(type: "linear"), %{"type" => "linear"}},
    {~s(type: "inverse"), %{"type" => "inverse"}},
    {~s(subType: "linear"), %{"subType" => "linear"}},
    {~s(subType: "inverse"), %{"subType" => "inverse"}},
    {~s(symbol: "BTC/USDT"), %{"symbol" => "BTC/USDT"}},
    {~s(symbol: "BTC/USDT:USDT"), %{"symbol" => "BTC/USDT:USDT"}},
    {~s(symbol: "BTC/USD:BTC"), %{"symbol" => "BTC/USD:BTC"}},
    {~s(symbol: "BTC/USDT:USDT-260925-100000-C"), %{"symbol" => "BTC/USDT:USDT-260925-100000-C"}}
  ]

  # ===========================================================================
  # Method Definitions
  #
  # {elixir_name, js_capability_name, required_params, description}
  #
  # Signature convention:
  #   - Required positional args only (exchange is implicit, opts is appended)
  #   - Optional Bourse params (since, limit, price, symbol when optional) → opts
  #   - Generated function: func(exchange, ...required, opts \\ [])
  # ===========================================================================

  # Curated descriptions for the most-used unified methods.
  # Remaining methods get auto-generated descriptions via description_for/1.
  @curated_descriptions %{
    fetch_ticker: "Fetch latest ticker (price, volume, bid/ask) for a trading pair.",
    fetch_tickers: "Fetch tickers for all or specified trading pairs.",
    fetch_order_book: "Fetch the order book (bids and asks) for a symbol.",
    fetch_trades: "Fetch recent public trades for a symbol.",
    fetch_ohlcv: "Fetch OHLCV candlestick data for a symbol and timeframe.",
    fetch_markets: "Fetch all available markets and trading pairs.",
    fetch_currencies: "Fetch all available currencies and their details.",
    fetch_time: "Fetch the exchange server time.",
    fetch_status: "Fetch the exchange operational status.",
    create_order: "Create a new order on the exchange.",
    create_orders: "Create multiple orders in a single request.",
    cancel_order: "Cancel an existing order by ID.",
    cancel_all_orders: "Cancel all open orders, optionally filtered by symbol.",
    edit_order: "Edit an existing order (modify price, amount, etc.).",
    fetch_order: "Fetch details of a specific order by ID.",
    fetch_orders: "Fetch a list of orders, optionally filtered by symbol.",
    fetch_order_list: "Fetch a specific order group by its exchange list ID.",
    fetch_order_lists: "Fetch historical order groups.",
    fetch_open_order_lists: "Fetch currently open order groups.",
    fetch_open_orders: "Fetch all currently open orders.",
    fetch_closed_orders: "Fetch completed (filled) orders.",
    fetch_balance: "Fetch account balance across all currencies.",
    fetch_my_trades: "Fetch the authenticated user's trade history.",
    fetch_positions: "Fetch all open derivative positions.",
    fetch_position: "Fetch a specific derivative position for a symbol.",
    set_leverage: "Set leverage for a symbol on the exchange.",
    set_margin_mode: "Set margin mode (cross/isolated) for a symbol.",
    fetch_funding_rate: "Fetch the current funding rate for a perpetual swap.",
    fetch_funding_rates: "Fetch funding rates for all perpetual swaps.",
    fetch_deposit_address: "Fetch a deposit address for a currency.",
    withdraw: "Withdraw funds to an external address.",
    fetch_deposits: "Fetch deposit history.",
    fetch_withdrawals: "Fetch withdrawal history.",
    transfer: "Transfer funds between exchange accounts (e.g., spot to futures).",
    fetch_trading_fee: "Fetch the trading fee for a specific symbol.",
    fetch_trading_fees: "Fetch trading fees for all symbols.",
    fetch_ledger:
      "Fetch the account ledger. Entry types use registered unified values (trade, fee, deposit, withdrawal, transfer, funding_fee, realized_pnl, liquidation, settlement, interest, rebate, commission, cashback, referral, conversion, bonus) or a venue-faithful snake_case label for mapped events outside the registry. Scopes with enum passthrough (base maps and routed maps alike) emit the provider's raw literal for any type outside their mapped set; the venue literal is always retained in info.",
    close_position: "Close a derivative position for a symbol.",
    fetch_open_interest: "Fetch open interest for a perpetual or futures symbol.",
    fetch_leverage: "Fetch current leverage setting for a symbol.",
    fetch_mark_price: "Fetch the mark price for a derivative symbol.",
    fetch_liquidations: "Fetch recent liquidation events for a symbol.",
    fetch_option_chain: "Fetch the full options chain for an underlying asset.",
    fetch_greeks: "Fetch option greeks (delta, gamma, theta, vega) for a symbol."
  }

  @method_defs [
    # -----------------------------------------------------------------------
    # Market Data (public)
    # -----------------------------------------------------------------------
    {:fetch_ticker, "fetchTicker", [:symbol]},
    {:fetch_tickers, "fetchTickers", []},
    {:fetch_order_book, "fetchOrderBook", [:symbol]},
    {:fetch_order_books, "fetchOrderBooks", []},
    {:fetch_l2_order_book, "fetchL2OrderBook", [:symbol]},
    {:fetch_l3_order_book, "fetchL3OrderBook", [:symbol]},
    {:fetch_trades, "fetchTrades", [:symbol]},
    {:fetch_ohlcv, "fetchOHLCV", [:symbol, :timeframe]},
    {:fetch_markets, "fetchMarkets", []},
    {:fetch_markets_by_type, "fetchMarketsByType", [:type]},
    {:fetch_markets_by_type_and_sub_type, "fetchMarketsByTypeAndSubType", [:type, :sub_type]},
    {:fetch_spot_markets, "fetchSpotMarkets", []},
    {:fetch_swap_markets, "fetchSwapMarkets", []},
    {:fetch_future_markets, "fetchFutureMarkets", []},
    {:fetch_option_markets, "fetchOptionMarkets", []},
    {:fetch_contract_markets, "fetchContractMarkets", []},
    {:fetch_swap_and_future_markets, "fetchSwapAndFutureMarkets", []},
    {:fetch_inverse_swap_markets, "fetchInverseSwapMarkets", []},
    {:fetch_uta_markets, "fetchUTAMarkets", []},
    {:fetch_swap_balance, "fetchSwapBalance", []},
    {:fetch_usdt_markets, "fetchUSDTMarkets", []},
    {:fetch_currencies, "fetchCurrencies", []},
    {:fetch_currency, "fetchCurrency", [:code]},
    {:fetch_currency_by_id, "fetchCurrencyById", [:id]},
    {:fetch_time, "fetchTime", []},
    {:fetch_status, "fetchStatus", []},
    {:fetch_bids_asks, "fetchBidsAsks", []},
    {:fetch_last_prices, "fetchLastPrices", []},
    {:fetch_market, "fetchMarket", [:symbol]},
    {:fetch_market_by_id, "fetchMarketById", [:id]},
    {:fetch_mark_price, "fetchMarkPrice", [:symbol]},
    {:fetch_mark_prices, "fetchMarkPrices", []},
    {:fetch_market_leverage_tiers, "fetchMarketLeverageTiers", [:symbol]},
    {:fetch_derivatives_market_leverage_tiers, "fetchDerivativesMarketLeverageTiers", [:symbol]},

    # Funding rates
    {:fetch_funding_rate, "fetchFundingRate", [:symbol]},
    {:fetch_funding_rates, "fetchFundingRates", []},
    {:fetch_funding_rate_history, "fetchFundingRateHistory", [:symbol]},
    {:fetch_funding_history, "fetchFundingHistory", [:symbol]},
    {:fetch_funding_interval, "fetchFundingInterval", [:symbol]},
    {:fetch_funding_intervals, "fetchFundingIntervals", []},
    {:fetch_funding_limits, "fetchFundingLimits", []},

    # Open interest
    {:fetch_open_interest, "fetchOpenInterest", [:symbol]},
    {:fetch_open_interest_history, "fetchOpenInterestHistory", [:symbol]},
    {:fetch_open_interests, "fetchOpenInterests", []},
    {:fetch_derivatives_open_interest_history, "fetchDerivativesOpenInterestHistory", [:symbol]},

    # Analytics
    {:fetch_long_short_ratio_history, "fetchLongShortRatioHistory", [:symbol]},
    {:fetch_liquidations, "fetchLiquidations", [:symbol]},
    {:fetch_volatility_history, "fetchVolatilityHistory", [:symbol]},

    # Options
    {:fetch_option, "fetchOption", [:symbol]},
    {:fetch_option_chain, "fetchOptionChain", [:symbol]},
    {:fetch_greeks, "fetchGreeks", [:symbol]},
    {:fetch_all_greeks, "fetchAllGreeks", []},
    {:fetch_underlying_assets, "fetchUnderlyingAssets", []},
    {:fetch_option_underlyings, "fetchOptionUnderlyings", []},
    {:fetch_option_positions, "fetchOptionPositions", []},
    {:fetch_option_ohlcv, "fetchOptionOHLCV", [:symbol, :timeframe]},

    # Exchange-specific OHLCV variants
    {:fetch_contract_ohlcv, "fetchContractOHLCV", [:symbol, :timeframe]},
    {:fetch_spot_ohlcv, "fetchSpotOHLCV", [:symbol, :timeframe]},
    {:fetch_uta_ohlcv, "fetchUTAOHLCV", [:symbol, :timeframe]},

    # Exchange-specific tickers
    {:fetch_contract_tickers, "fetchContractTickers", []},

    # -----------------------------------------------------------------------
    # Trading — Order Creation
    # -----------------------------------------------------------------------
    {:create_order, "createOrder", [:symbol, :type, :side, :amount]},
    {:create_orders, "createOrders", [:orders]},
    {:create_spot_order, "createSpotOrder", [:symbol, :type, :side, :amount]},
    {:create_spot_orders, "createSpotOrders", [:orders]},
    {:create_contract_order, "createContractOrder", [:symbol, :type, :side, :amount]},
    {:create_contract_orders, "createContractOrders", [:orders]},
    {:create_swap_order, "createSwapOrder", [:symbol, :type, :side, :amount]},
    {:create_uta_order, "createUtaOrder", [:symbol, :type, :side, :amount]},
    {:create_uta_orders, "createUtaOrders", [:orders]},
    {:create_order_with_take_profit_and_stop_loss, "createOrderWithTakeProfitAndStopLoss",
     [:symbol, :type, :side, :amount]},
    {:create_trailing_amount_order, "createTrailingAmountOrder", [:symbol, :type, :side, :amount]},
    {:create_trailing_percent_order, "createTrailingPercentOrder", [:symbol, :type, :side, :amount]},
    {:create_twap_order, "createTwapOrder", [:symbol, :side, :amount, :duration]},
    {:create_market_buy_order_with_cost, "createMarketBuyOrderWithCost", [:symbol, :cost]},
    {:create_market_sell_order_with_cost, "createMarketSellOrderWithCost", [:symbol, :cost]},
    {:create_market_order_with_cost, "createMarketOrderWithCost", [:symbol, :side, :cost]},

    # -----------------------------------------------------------------------
    # Trading — Order Cancellation
    # -----------------------------------------------------------------------
    {:cancel_order, "cancelOrder", [:id]},
    {:cancel_orders, "cancelOrders", [:ids]},
    {:cancel_all_orders, "cancelAllOrders", []},
    {:cancel_all_orders_after, "cancelAllOrdersAfter", [:timeout]},
    {:cancel_orders_for_symbols, "cancelOrdersForSymbols", [:orders]},
    {:cancel_spot_order, "cancelSpotOrder", [:id]},
    {:cancel_contract_order, "cancelContractOrder", [:id]},
    {:cancel_unified_order, "cancelUnifiedOrder", [:id]},
    {:cancel_uta_order, "cancelUtaOrder", [:id]},
    {:cancel_uta_orders, "cancelUtaOrders", [:ids]},
    {:cancel_twap_order, "cancelTwapOrder", [:id]},
    {:cancel_all_spot_orders, "cancelAllSpotOrders", []},
    {:cancel_all_contract_orders, "cancelAllContractOrders", []},
    {:cancel_all_uta_orders, "cancelAllUtaOrders", []},

    # -----------------------------------------------------------------------
    # Trading — Order Editing
    # -----------------------------------------------------------------------
    {:edit_order, "editOrder", [:id, :symbol, :type, :side]},
    {:edit_orders, "editOrders", [:orders]},
    {:edit_contract_order, "editContractOrder", [:id, :symbol, :type, :side]},
    {:edit_spot_order, "editSpotOrder", [:id, :symbol, :type, :side]},

    # -----------------------------------------------------------------------
    # Trading — Order Fetching
    # -----------------------------------------------------------------------
    {:fetch_order, "fetchOrder", [:id]},
    {:fetch_order_classic, "fetchOrderClassic", [:id]},
    {:fetch_orders, "fetchOrders", []},
    {:fetch_orders_classic, "fetchOrdersClassic", []},
    {:fetch_order_list, "fetchOrderList", [:id]},
    {:fetch_order_lists, "fetchOrderLists", []},
    {:fetch_open_order, "fetchOpenOrder", [:id]},
    {:fetch_open_orders, "fetchOpenOrders", []},
    {:fetch_open_order_lists, "fetchOpenOrderLists", []},
    {:fetch_closed_order, "fetchClosedOrder", [:id]},
    {:fetch_closed_orders, "fetchClosedOrders", []},
    {:fetch_canceled_orders, "fetchCanceledOrders", []},
    {:fetch_canceled_and_closed_orders, "fetchCanceledAndClosedOrders", []},
    {:fetch_order_trades, "fetchOrderTrades", [:id]},
    {:fetch_order_status, "fetchOrderStatus", [:id]},
    {:fetch_orders_by_ids, "fetchOrdersByIds", [:ids]},
    {:fetch_orders_by_state, "fetchOrdersByState", [:state]},
    {:fetch_orders_by_status, "fetchOrdersByStatus", [:status]},
    {:fetch_orders_by_type, "fetchOrdersByType", [:type]},

    # Exchange-specific order variants
    {:fetch_spot_order, "fetchSpotOrder", [:id]},
    {:fetch_spot_orders, "fetchSpotOrders", []},
    {:fetch_spot_order_trades, "fetchSpotOrderTrades", [:id]},
    {:fetch_spot_orders_by_states, "fetchSpotOrdersByStates", []},
    {:fetch_spot_orders_by_status, "fetchSpotOrdersByStatus", []},
    {:fetch_open_spot_orders, "fetchOpenSpotOrders", []},
    {:fetch_open_swap_orders, "fetchOpenSwapOrders", []},
    {:fetch_closed_spot_orders, "fetchClosedSpotOrders", []},
    {:fetch_closed_contract_orders, "fetchClosedContractOrders", []},
    {:fetch_canceled_and_closed_spot_orders, "fetchCanceledAndClosedSpotOrders", []},
    {:fetch_canceled_and_closed_swap_orders, "fetchCanceledAndClosedSwapOrders", []},
    {:fetch_contract_order, "fetchContractOrder", [:id]},
    {:fetch_contract_orders, "fetchContractOrders", []},
    {:fetch_contract_orders_by_status, "fetchContractOrdersByStatus", []},
    {:fetch_uta_order, "fetchUtaOrder", [:id]},
    {:fetch_uta_orders_by_status, "fetchUtaOrdersByStatus", []},
    {:fetch_uta_canceled_and_closed_orders, "fetchUtaCanceledAndClosedOrders", []},
    {:fetch_adl_rank, "fetchADLRank", []},

    # -----------------------------------------------------------------------
    # Account — Balance & Info
    # -----------------------------------------------------------------------
    {:fetch_balance, "fetchBalance", []},
    {:fetch_spot_balance, "fetchSpotBalance", []},
    {:fetch_contract_balance, "fetchContractBalance", []},
    {:fetch_margin_balance, "fetchMarginBalance", []},
    {:fetch_financial_balance, "fetchFinancialBalance", []},
    {:fetch_uta_balance, "fetchUtaBalance", []},
    {:fetch_account, "fetchAccount", []},
    {:fetch_accounts, "fetchAccounts", []},
    {:fetch_account_positions, "fetchAccountPositions", []},
    {:create_account, "createAccount", []},
    {:create_sub_account, "createSubAccount", []},

    # -----------------------------------------------------------------------
    # Account — Trades
    # -----------------------------------------------------------------------
    {:fetch_my_trades, "fetchMyTrades", []},
    {:fetch_my_spot_trades, "fetchMySpotTrades", []},
    {:fetch_my_contract_trades, "fetchMyContractTrades", []},
    {:fetch_my_uta_trades, "fetchMyUtaTrades", []},
    {:fetch_my_buys, "fetchMyBuys", []},
    {:fetch_my_sells, "fetchMySells", []},
    {:fetch_my_dust_trades, "fetchMyDustTrades", []},
    {:fetch_my_liquidations, "fetchMyLiquidations", []},
    {:fetch_my_settlement_history, "fetchMySettlementHistory", []},

    # -----------------------------------------------------------------------
    # Account — Positions
    # -----------------------------------------------------------------------
    {:fetch_position, "fetchPosition", [:symbol]},
    {:fetch_positions, "fetchPositions", []},
    {:fetch_positions_for_symbol, "fetchPositionsForSymbol", [:symbol]},
    {:fetch_positions_history, "fetchPositionsHistory", []},
    {:fetch_position_history, "fetchPositionHistory", []},
    {:fetch_positions_risk, "fetchPositionsRisk", []},
    {:fetch_positions_adl_rank, "fetchPositionsADLRank", []},
    {:fetch_position_adl_rank, "fetchPositionADLRank", [:symbol]},
    {:close_position, "closePosition", [:symbol]},
    {:close_all_positions, "closeAllPositions", []},
    {:fetch_position_mode, "fetchPositionMode", []},
    {:set_position_mode, "setPositionMode", [:hedge_mode]},

    # -----------------------------------------------------------------------
    # Account — Leverage & Margin
    # -----------------------------------------------------------------------
    {:fetch_leverage, "fetchLeverage", [:symbol]},
    {:fetch_leverages, "fetchLeverages", []},
    {:fetch_leverage_tiers, "fetchLeverageTiers", []},
    {:set_leverage, "setLeverage", [:leverage, :symbol]},
    {:fetch_margin_mode, "fetchMarginMode", [:symbol]},
    {:fetch_margin_modes, "fetchMarginModes", []},
    {:set_margin_mode, "setMarginMode", [:margin_mode, :symbol]},
    {:set_margin, "setMargin", [:symbol, :amount]},
    {:add_margin, "addMargin", [:symbol, :amount]},
    {:reduce_margin, "reduceMargin", [:symbol, :amount]},
    {:fetch_margin_adjustment_history, "fetchMarginAdjustmentHistory", []},

    # -----------------------------------------------------------------------
    # Account — Fees & Trading Limits
    # -----------------------------------------------------------------------
    {:fetch_trading_fee, "fetchTradingFee", [:symbol]},
    {:fetch_trading_fees, "fetchTradingFees", []},
    {:fetch_trading_limits, "fetchTradingLimits", []},
    {:fetch_trading_limits_by_id, "fetchTradingLimitsById", [:id]},
    {:fetch_private_trading_fee, "fetchPrivateTradingFee", [:symbol]},
    {:fetch_private_trading_fees, "fetchPrivateTradingFees", []},
    {:fetch_public_trading_fee, "fetchPublicTradingFee", [:symbol]},
    {:fetch_public_trading_fees, "fetchPublicTradingFees", []},
    {:fetch_transaction_fee, "fetchTransactionFee", [:code]},
    {:fetch_transaction_fees, "fetchTransactionFees", []},
    {:fetch_private_transaction_fees, "fetchPrivateTransactionFees", []},
    {:fetch_public_transaction_fees, "fetchPublicTransactionFees", []},

    # -----------------------------------------------------------------------
    # Account — Ledger
    # -----------------------------------------------------------------------
    {:fetch_ledger, "fetchLedger", []},
    {:fetch_ledger_entry, "fetchLedgerEntry", [:id]},
    {:fetch_ledger_by_entries, "fetchLedgerByEntries", []},
    {:fetch_ledger_entries_by_ids, "fetchLedgerEntriesByIds", [:ids]},

    # -----------------------------------------------------------------------
    # Funding — Deposits
    # -----------------------------------------------------------------------
    {:fetch_deposit, "fetchDeposit", [:id]},
    {:fetch_deposits, "fetchDeposits", []},
    {:fetch_deposit_address, "fetchDepositAddress", [:code]},
    {:fetch_deposit_addresses, "fetchDepositAddresses", []},
    {:fetch_deposit_addresses_by_network, "fetchDepositAddressesByNetwork", [:code]},
    {:fetch_network_deposit_address, "fetchNetworkDepositAddress", [:code]},
    {:fetch_contract_deposit_address, "fetchContractDepositAddress", [:code]},
    {:create_deposit_address, "createDepositAddress", [:code]},
    {:fetch_deposit_method_id, "fetchDepositMethodId", [:code]},
    {:fetch_deposit_method_ids, "fetchDepositMethodIds", []},
    {:fetch_deposit_methods, "fetchDepositMethods", [:code]},
    {:fetch_payment_methods, "fetchPaymentMethods", []},

    # -----------------------------------------------------------------------
    # Funding — Withdrawals
    # -----------------------------------------------------------------------
    {:withdraw, "withdraw", [:code, :amount, :address]},
    {:fetch_withdrawal, "fetchWithdrawal", [:id]},
    {:fetch_withdrawals, "fetchWithdrawals", []},
    {:fetch_withdraw_addresses, "fetchWithdrawAddresses", []},
    {:fetch_contract_withdrawals, "fetchContractWithdrawals", []},
    {:fetch_contract_deposits, "fetchContractDeposits", []},

    # -----------------------------------------------------------------------
    # Funding — Deposit/Withdraw Fees
    # -----------------------------------------------------------------------
    {:fetch_deposit_withdraw_fee, "fetchDepositWithdrawFee", [:code]},
    {:fetch_deposit_withdraw_fees, "fetchDepositWithdrawFees", []},
    {:fetch_private_deposit_withdraw_fees, "fetchPrivateDepositWithdrawFees", []},
    {:fetch_public_deposit_withdraw_fees, "fetchPublicDepositWithdrawFees", []},

    # -----------------------------------------------------------------------
    # Funding — Deposits + Withdrawals combined
    # -----------------------------------------------------------------------
    {:fetch_deposits_withdrawals, "fetchDepositsWithdrawals", []},
    {:fetch_transactions, "fetchTransactions", []},
    {:fetch_transactions_by_type, "fetchTransactionsByType", [:type]},

    # -----------------------------------------------------------------------
    # Funding — Transfers
    # -----------------------------------------------------------------------
    {:transfer, "transfer", [:code, :amount, :from_account, :to_account]},
    {:fetch_transfer, "fetchTransfer", [:id]},
    {:fetch_transfers, "fetchTransfers", []},
    {:transfer_between_main_and_sub_account, "transferBetweenMainAndSubAccount",
     [:code, :amount, :from_account, :to_account]},
    {:transfer_between_sub_accounts, "transferBetweenSubAccounts", [:code, :amount, :from_account, :to_account]},
    {:transfer_classic, "transferClassic", [:code, :amount, :from_account, :to_account]},
    {:transfer_out, "transferOut", [:code, :amount, :address]},
    {:transfer_uta, "transferUta", [:code, :amount, :from_account, :to_account]},

    # -----------------------------------------------------------------------
    # Margin — Borrowing
    # -----------------------------------------------------------------------
    {:borrow_cross_margin, "borrowCrossMargin", [:code, :amount]},
    {:borrow_isolated_margin, "borrowIsolatedMargin", [:symbol, :code, :amount]},
    {:repay_cross_margin, "repayCrossMargin", [:code, :amount]},
    {:repay_isolated_margin, "repayIsolatedMargin", [:symbol, :code, :amount]},
    {:repay_margin, "repayMargin", [:code, :amount]},
    {:fetch_borrow_interest, "fetchBorrowInterest", []},
    {:fetch_borrow_rate_history, "fetchBorrowRateHistory", [:code]},
    {:fetch_borrow_rate_histories, "fetchBorrowRateHistories", []},
    {:fetch_cross_borrow_rate, "fetchCrossBorrowRate", [:code]},
    {:fetch_cross_borrow_rates, "fetchCrossBorrowRates", []},
    {:fetch_isolated_borrow_rate, "fetchIsolatedBorrowRate", [:symbol]},
    {:fetch_isolated_borrow_rates, "fetchIsolatedBorrowRates", []},

    # -----------------------------------------------------------------------
    # Convert
    # -----------------------------------------------------------------------
    {:create_convert_trade, "createConvertTrade", [:id, :from_code, :to_code, :amount]},
    {:fetch_convert_currencies, "fetchConvertCurrencies", []},
    {:fetch_convert_quote, "fetchConvertQuote", [:from_code, :to_code, :amount]},
    {:fetch_convert_trade, "fetchConvertTrade", [:id]},
    {:fetch_convert_trade_history, "fetchConvertTradeHistory", []},

    # -----------------------------------------------------------------------
    # Settlement
    # -----------------------------------------------------------------------
    {:fetch_settlement_history, "fetchSettlementHistory", []},

    # -----------------------------------------------------------------------
    # Portfolios & Vaults
    # -----------------------------------------------------------------------
    {:fetch_portfolios, "fetchPortfolios", []},
    {:fetch_portfolio_details, "fetchPortfolioDetails", [:portfolio_id]},
    {:create_vault, "createVault", [:code, :amount]},

    # -----------------------------------------------------------------------
    # Gift Codes
    # -----------------------------------------------------------------------
    {:create_gift_code, "createGiftCode", [:code, :amount]}
  ]

  @js_names Map.new(@method_defs, fn {name, js_name, _params} -> {name, js_name} end)
  @js_to_method Map.new(@method_defs, fn {name, js_name, _params} -> {js_name, name} end)
  @required_params_by_method Map.new(@method_defs, fn {name, _js_name, params} -> {name, params} end)
  @parse_types_by_return_type FieldMaps.parse_types()
                              |> Map.new(fn parse_type ->
                                type_name = parse_type |> FieldMaps.struct_for() |> Module.split() |> List.last()
                                {type_name, parse_type}
                              end)
                              |> Map.put("OrderBook", "order_book")
  @parsers_by_parse_type %{
    "account" => :parse_account,
    "balance" => :parse_balance,
    "borrow_interest" => :parse_borrow_interest,
    "borrow_rate" => :parse_borrow_rate,
    "conversion" => :parse_conversion,
    "currency" => :parse_currency,
    "deposit_address" => :parse_deposit_address,
    "funding_rate" => :parse_funding_rate,
    "funding_rate_history" => :parse_funding_rate_history,
    "funding_history" => :parse_funding_history,
    "greeks" => :parse_greeks,
    "last_price" => :parse_last_price,
    "ledger_entry" => :parse_ledger_entry,
    "leverage" => :parse_leverage,
    "leverage_tiers" => :parse_leverage_tiers,
    "liquidation" => :parse_liquidation,
    "long_short_ratio" => :parse_long_short_ratio,
    "margin_loan" => :parse_margin_loan,
    "margin_mode" => :parse_margin_mode,
    "margin_modification" => :parse_margin_modification,
    "market" => :parse_market,
    "ohlcv" => :parse_ohlcv,
    "open_interest" => :parse_open_interest,
    "order_book" => :parse_order_book,
    "option" => :parse_option,
    "order" => :parse_order,
    "order_list" => :parse_order_list,
    "position" => :parse_position,
    "adl_rank" => :parse_adl_rank,
    "ticker" => :parse_ticker,
    "trade" => :parse_trade,
    "trading_fee" => :parse_trading_fee,
    "transaction" => :parse_transaction,
    "transfer" => :parse_transfer,
    "volatility_history" => :parse_volatility_history
  }

  @return_type_aliases %{
    "ADL" => "ADLRank",
    "Accounts" => "Account",
    "Balances" => "Balance",
    "BorrowInterest" => "BorrowInterest",
    "Conversion" => "Conversion",
    "CrossBorrowRate" => "BorrowRate",
    "CrossBorrowRates" => "BorrowRate",
    # Isolated borrow rates are BorrowRate rows scoped by symbol, not a separate type.
    "IsolatedBorrowRate" => "BorrowRate",
    "IsolatedBorrowRates" => "BorrowRate",
    "Currencies" => "Currency",
    "FundingRates" => "FundingRate",
    "FundingHistory" => "FundingHistory",
    "Leverage" => "Leverage",
    "Leverages" => "Leverage",
    # Descriptor plural token (LeverageTiers) vs module name (LeverageTier).
    "LeverageTiers" => "LeverageTier",
    "Liquidation" => "Liquidation",
    "Liquidations" => "Liquidation",
    "LongShortRatio" => "LongShortRatio",
    # Plural collection tokens already wired as singular parse types.
    "MarginModes" => "MarginMode",
    "OpenInterests" => "OpenInterest",
    # Descriptor return tokens use Bourse's short names; struct modules differ.
    "Option" => "OptionData",
    "OptionChain" => "OptionData",
    "Tickers" => "Ticker",
    # Hyperliquid (and others) type the fee schedule as TradingFeeInterface.
    "TradingFeeInterface" => "TradingFee",
    "TradingFees" => "TradingFee"
  }

  # Unified methods that dispatch all endpoint configs concurrently when no
  # market type is inferable.
  @fan_out_methods [:fetch_markets]

  @write_return_contracts %{
    add_margin: :unified_struct,
    borrow_cross_margin: :unified_struct,
    borrow_isolated_margin: :venue_body,
    cancel_all_contract_orders: :venue_body,
    cancel_all_orders: :already_parsed_order_like,
    cancel_all_orders_after: :venue_body,
    cancel_all_spot_orders: :venue_body,
    cancel_all_uta_orders: :venue_body,
    cancel_contract_order: :venue_body,
    cancel_order: :already_parsed_order_like,
    cancel_orders: :already_parsed_order_like,
    cancel_orders_for_symbols: :venue_body,
    cancel_spot_order: :venue_body,
    cancel_twap_order: :venue_body,
    cancel_unified_order: :venue_body,
    cancel_uta_order: :venue_body,
    cancel_uta_orders: :venue_body,
    close_all_positions: :venue_body,
    close_position: :already_parsed_order_like,
    create_account: :venue_body,
    create_convert_trade: :unified_struct,
    create_contract_order: :venue_body,
    create_contract_orders: :venue_body,
    create_deposit_address: :unified_struct,
    create_gift_code: :venue_body,
    create_market_buy_order_with_cost: :already_parsed_order_like,
    create_market_order_with_cost: :venue_body,
    create_market_sell_order_with_cost: :already_parsed_order_like,
    create_order: :already_parsed_order_like,
    create_order_with_take_profit_and_stop_loss: :already_parsed_order_like,
    create_orders: :already_parsed_order_like,
    create_spot_order: :venue_body,
    create_spot_orders: :venue_body,
    create_sub_account: :venue_body,
    create_swap_order: :venue_body,
    create_trailing_amount_order: :venue_body,
    create_trailing_percent_order: :venue_body,
    create_twap_order: :already_parsed_order_like,
    create_uta_order: :venue_body,
    create_uta_orders: :venue_body,
    create_vault: :venue_body,
    edit_contract_order: :venue_body,
    edit_order: :already_parsed_order_like,
    edit_orders: :already_parsed_order_like,
    edit_spot_order: :venue_body,
    reduce_margin: :unified_struct,
    repay_cross_margin: :unified_struct,
    repay_isolated_margin: :venue_body,
    repay_margin: :venue_body,
    set_leverage: :venue_body,
    set_margin: :venue_body,
    set_margin_mode: :venue_body,
    set_position_mode: :venue_body,
    transfer: :unified_struct,
    transfer_between_main_and_sub_account: :venue_body,
    transfer_between_sub_accounts: :venue_body,
    transfer_classic: :venue_body,
    transfer_out: :venue_body,
    transfer_uta: :venue_body,
    withdraw: :unified_struct
  }

  @doc "Returns the return contract for every unified write/action method."
  @spec write_return_contracts() :: %{atom() => :venue_body | :unified_struct | :already_parsed_order_like}
  def write_return_contracts, do: @write_return_contracts

  @doc "Returns all unified method definitions as `{elixir_name, js_name, required_params, description}` tuples."
  @spec method_defs() :: [{atom(), String.t(), [atom()], String.t()}]
  def method_defs do
    Enum.map(@method_defs, fn {name, js_name, params} ->
      {name, js_name, params, description_for(name)}
    end)

    # ===========================================================================
    # Dispatch
    # ===========================================================================
  end

  @doc "Returns the description for a unified method, curated or auto-generated."
  @spec description_for(atom()) :: String.t()
  def description_for(name) do
    Map.get_lazy(@curated_descriptions, name, fn -> auto_description(name) end)
  end

  # Auto-generates a description from the method name.
  # "fetch_funding_rate" → "Fetch funding rate."
  defp auto_description(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> then(fn s -> String.upcase(String.first(s)) <> String.slice(s, 1..-1//1) end)
    |> Kernel.<>(".")
  end

  @doc """
  Fetches markets and returns an enriched `%Exchange{}` with the markets cache set.

  Loads markets for the pure-data Exchange design; the caller threads the
  returned struct. Subsequent unified calls that need market
  metadata (e.g. lighter `market_id` resolution) reuse `exchange.markets`
  without another network round-trip. Call again for an explicit reload.
  """
  @spec load_markets(Exchange.t(), keyword()) ::
          {:ok, Exchange.t()} | {:error, Error.t() | term()}
  def load_markets(%Exchange{} = exchange, opts \\ []) when is_list(opts) do
    with {:ok, module} <- require_module(exchange),
         {:ok, markets} when is_list(markets) <-
           call_dispatch(exchange, module, :fetch_markets, "fetchMarkets", %{}, opts) do
      {:ok, Exchange.put_markets(exchange, markets)}
    end
  end

  @doc "Dispatches a unified method call through module resolution and endpoint selection."
  @spec call(Exchange.t(), atom(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, Error.t() | term()}
  def call(%Exchange{} = exchange, method_atom, capability_name, params, opts) do
    with {:ok, params} <- validate_param_values(params, method_atom),
         {:ok, params} <- validate_venue_params(exchange, method_atom, params),
         {:ok, params} <- maybe_validate_order(exchange, method_atom, params, opts),
         {:ok, module} <- require_module(exchange) do
      dispatch_opts = Keyword.delete(opts, :sanity)

      emulation_context = %{
        exchange_module: module,
        params: params,
        opts: dispatch_opts
      }

      case Emulation.dispatch(exchange, method_atom, :rest, emulation_context) do
        :passthrough ->
          call_dispatch(exchange, module, method_atom, capability_name, params, dispatch_opts)

        {:ok, result} ->
          {:ok, result}

        {:error, _} = error ->
          error
      end
    end
  rescue
    # Only an unresolved authored identifier_reference (e.g. derive's missing
    # subaccount_id) is normalized to a tuple at the public boundary. Other
    # Bourse.Error raises in the pipeline — notably OrderPrecision's fail-loud
    # "call load_markets/1" guard — are deliberate and must stay raises.
    error in Error ->
      case error do
        %Error{raw: %{"reason" => "unresolved_identifier_reference"}} -> {:error, error}
        _ -> reraise(error, __STACKTRACE__)
      end
  end

  defp maybe_validate_order(%Exchange{markets: markets} = exchange, method, params, opts)
       when method in @sanity_methods and is_list(markets) do
    if Keyword.get(opts, :sanity, false) do
      market = Enum.find(markets, &market_symbol_match?(&1, Map.get(params, "symbol")))

      # edit_order carries only the fields being changed, so an absent amount or
      # price is a partial update rather than a missing required field.
      sanity_opts = [has: exchange.has, partial: method == :edit_order]

      case Sanity.validate(params, market, sanity_opts) do
        {:ok, _params} -> {:ok, params}
        {:ok, _params, _warnings} -> {:ok, params}
        {:error, {:sanity_check, reasons}} -> {:error, sanity_error(exchange, reasons)}
      end
    else
      {:ok, params}
    end
  end

  defp maybe_validate_order(_exchange, _method, params, _opts), do: {:ok, params}

  defp sanity_error(%Exchange{} = exchange, reasons) do
    messages = Enum.map(reasons, fn {_check, message} -> message end)

    Error.invalid_order(
      message: "Order failed client-side sanity checks: #{Enum.join(messages, "; ")}",
      exchange: exchange.id,
      hints: messages,
      raw: %{"sanity_check" => Map.new(reasons, fn {check, message} -> {to_string(check), message} end)}
    )
  end

  @doc "Dispatches a unified method to HTTP without checking emulation."
  @spec call_dispatch(Exchange.t(), module(), atom(), String.t(), map(), keyword()) ::
          {:ok, map() | list()} | {:error, Error.t() | term()}
  def call_dispatch(%Exchange{} = exchange, module, method_atom, capability_name, params, opts) do
    case resolve_dispatch_plan(exchange, module, method_atom, capability_name, params, opts) do
      {:error, _} = error ->
        error

      {:ok, {:fan_out, configs}} ->
        js_name = js_name_for!(method_atom)

        with {:ok, responses} <- dispatch_fan_out(exchange, capability_name, configs, params, opts) do
          parsed = parse_fan_out_responses(exchange, module, method_atom, js_name, params, responses)

          parsed
          |> maybe_resolve_binance_spot_ticker_symbols(exchange, module, method_atom, opts)
          |> FundingInterval.enrich(exchange, method_atom, params, opts)
        end

      {:ok, {:broadcast, configs}} ->
        js_name = js_name_for!(method_atom)

        with {:ok, [response | _]} <- dispatch_fan_out(exchange, capability_name, configs, params, opts) do
          parse_unified_response(exchange, module, method_atom, js_name, params, response, hd(configs))
        end

      {:ok, {:first_success, configs}} ->
        js_name = js_name_for!(method_atom)

        with {:ok, response, config} <-
               dispatch_first_success(exchange, capability_name, configs, params, opts) do
          parse_unified_response(exchange, module, method_atom, js_name, params, response, config)
        end

      {:ok, {:param_fan_out, config, param_variants}} ->
        js_name = js_name_for!(method_atom)

        with {:ok, {param_variants, responses}} <-
               dispatch_param_fan_out(exchange, capability_name, config, param_variants, params, opts) do
          parsed =
            parse_param_fan_out_responses(exchange, module, method_atom, js_name, params, param_variants, responses)

          parsed
          |> maybe_resolve_binance_spot_ticker_symbols(exchange, module, method_atom, opts)
          |> FundingInterval.enrich(exchange, method_atom, params, opts)
        end

      {:ok, {:single, config}} ->
        js_name = js_name_for!(method_atom)

        with {:ok, response} <- dispatch_single(exchange, capability_name, config, params, opts) do
          parsed = parse_unified_response(exchange, module, method_atom, js_name, params, response, config)

          parsed
          |> maybe_resolve_binance_spot_ticker_symbols(exchange, module, method_atom, opts)
          |> FundingInterval.enrich(exchange, method_atom, params, opts)
        end
    end
  end

  defp maybe_resolve_binance_spot_ticker_symbols({:ok, parsed}, exchange, module, method_atom, opts),
    do: resolve_binance_spot_ticker_symbols(exchange, module, method_atom, parsed, opts)

  defp maybe_resolve_binance_spot_ticker_symbols({:error, _} = error, _exchange, _module, _method_atom, _opts), do: error

  defp resolve_binance_spot_ticker_symbols(%Exchange{id: "binance"} = exchange, module, :fetch_tickers, tickers, opts)
       when is_map(tickers) do
    if Enum.any?(Map.keys(tickers), &(is_binary(&1) and not String.contains?(&1, "/"))) do
      rekey_binance_spot_tickers(exchange, module, tickers, opts)
    else
      {:ok, tickers}
    end
  end

  defp resolve_binance_spot_ticker_symbols(_exchange, _module, _method_atom, parsed, _opts), do: {:ok, parsed}

  defp rekey_binance_spot_tickers(%Exchange{markets: markets}, _module, tickers, _opts) when is_list(markets) do
    {:ok, ReadParse.index_tickers_by_market_id(tickers, markets)}
  end

  # Only the spot `exchangeInfo` surface can key a spot ticker row, but a bare
  # no-arg `fetchMarkets` fans out across spot/fapi/dapi/eapi — eapi alone
  # returns ~1400 option rows the lookup can never use. `market_type: :spot`
  # both takes the call off the fan-out (`fan_out?/5`) and lets the authored
  # `fetchMarkets` selection resolve its `public_get_exchangeinfo` default by
  # name. Selecting by market type rather than by list position matters: the
  # config list `select_endpoint/5` sees is credential-filtered, so a positional
  # index computed over the unfiltered list silently drifts onto the wrong
  # surface the day an authenticated row sorts ahead of the spot one.
  defp rekey_binance_spot_tickers(%Exchange{} = exchange, module, tickers, opts) do
    spot_markets_opts = Keyword.put(opts, :market_type, :spot)

    with {:ok, markets} <- call_dispatch(exchange, module, :fetch_markets, "fetchMarkets", %{}, spot_markets_opts) do
      {:ok, ReadParse.index_tickers_by_market_id(tickers, markets)}
    end
  end

  # Deribit's `get_book_summary_by_currency` answers for one
  # currency, so the code comes from `code` or the symbols' shared base. Neither
  # present is ArgumentsRequired; a mixed-base symbol list is a BadRequest rather
  # than a silent read of whichever base happened to come first.
  defp validate_venue_params(%Exchange{id: "deribit"} = exchange, :fetch_tickers, params) do
    bases = params |> Map.get("symbols") |> List.wrap() |> Enum.map(&deribit_symbol_base/1)

    case [deribit_tickers_code(params) | bases] |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [code] -> {:ok, Map.put(params, "code", code)}
      [] -> deribit_tickers_arguments_error(exchange)
      _mixed -> deribit_tickers_mixed_base_error(exchange)
    end
  end

  defp validate_venue_params(%Exchange{} = exchange, method, %{"symbol" => symbol} = params)
       when method in [:set_margin, :add_margin, :reduce_margin] and is_binary(symbol) do
    _ = Symbol.to_exchange_id!(symbol, exchange)
    {:ok, params}
  end

  defp validate_venue_params(_exchange, _method_atom, params), do: {:ok, params}

  defp deribit_tickers_code(%{"code" => code}) when is_binary(code) and code != "", do: code
  defp deribit_tickers_code(_params), do: nil

  defp deribit_symbol_base(symbol) when is_binary(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, %{base: base}} -> base
      _ -> nil
    end
  end

  defp deribit_symbol_base(_symbol), do: nil

  defp deribit_tickers_arguments_error(exchange) do
    {:error,
     Error.bad_request(
       exchange: exchange.id,
       message: "deribit fetchTickers requires a non-empty symbols list or code"
     )}
  end

  defp deribit_tickers_mixed_base_error(exchange) do
    {:error,
     Error.bad_request(
       exchange: exchange.id,
       message:
         "deribit fetchTickers the base currency must be the same for all symbols — " <>
           "get_book_summary_by_currency supports one base currency at a time"
     )}
  end

  @doc """
  Dispatches a unified public read without parsing the response body.

  Used by `mix ccxt.record_fixtures` to capture raw exchange JSON for offline
  replay tests. Returns a single raw response — for fan-out methods it selects
  one endpoint rather than crashing. Use `capture_responses/4` when every
  fan-out section is required.
  """
  @spec raw_call(Exchange.t(), atom(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def raw_call(%Exchange{} = exchange, method_atom, params, opts \\ []) when is_atom(method_atom) do
    with {:ok, module} <- require_module(exchange) do
      dispatch_http(exchange, module, method_atom, js_name_for!(method_atom), params, opts)
    end
  end

  defp dispatch_http(%Exchange{} = exchange, module, method_atom, capability_name, params, opts) do
    with {:ok, config} <- resolve_endpoint(exchange, module, method_atom, capability_name, params, opts) do
      dispatch_single(exchange, capability_name, config, params, opts)
    end
  end

  @doc """
  Dispatches a unified public read capturing every fan-out section.

  Unlike `raw_call/4`, which collapses fan-out methods to a single endpoint,
  this preserves each response tagged with its provider API section so
  comparison tooling can execute the method over the recording.
  Single-endpoint methods return the bare `%{body: ...}` response unchanged.
  """
  @spec capture_responses(Exchange.t(), atom(), map(), keyword()) ::
          {:ok, map() | [map()]} | {:error, Error.t() | term()}
  def capture_responses(%Exchange{} = exchange, method_atom, params, opts \\ []) when is_atom(method_atom) do
    js_name = js_name_for!(method_atom)

    with {:ok, module} <- require_module(exchange),
         {:ok, resolution} <- resolve_dispatch_plan(exchange, module, method_atom, js_name, params, opts) do
      dispatch_raw_response(exchange, js_name, resolution, params, opts)
    end
  end

  @doc false
  @spec request_param_shapes(Exchange.t(), atom(), map(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t() | term()}
  def request_param_shapes(%Exchange{} = exchange, method_atom, params, opts \\ [])
      when is_atom(method_atom) and is_map(params) do
    js_name = js_name_for!(method_atom)

    with {:ok, module} <- require_module(exchange),
         {:ok, resolution} <- resolve_dispatch_plan(exchange, module, method_atom, js_name, params, opts) do
      build_request_param_shapes(exchange, js_name, resolution, params, opts)
    end
  end

  defp build_request_param_shapes(exchange, js_name, {:single, config}, params, opts) do
    with {:ok, params} <- maybe_resolve_market_id(exchange, js_name, params, opts) do
      {:ok, [build_final_params(exchange, js_name, params, opts, config.path)]}
    end
  end

  defp build_request_param_shapes(exchange, js_name, {mode, _configs}, params, opts)
       when mode in [:fan_out, :broadcast] do
    with {:ok, params} <- maybe_resolve_market_id(exchange, js_name, params, opts) do
      {:ok, [build_final_params(exchange, js_name, params, opts, nil)]}
    end
  end

  defp build_request_param_shapes(exchange, js_name, {:first_success, configs}, params, opts) do
    with {:ok, params} <- maybe_resolve_market_id(exchange, js_name, params, opts) do
      {:ok, Enum.map(configs, &build_final_params(exchange, js_name, params, opts, &1.path))}
    end
  end

  defp build_request_param_shapes(exchange, js_name, {:param_fan_out, config, variants}, params, opts) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, shapes} ->
      case maybe_resolve_market_id(exchange, js_name, Map.merge(params, variant), opts) do
        {:ok, merged} ->
          shape = build_final_params(exchange, js_name, merged, opts, config.path)
          {:cont, {:ok, [shape | shapes]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, shapes} -> {:ok, Enum.reverse(shapes)}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch_raw_response(exchange, capability_name, {:single, config}, params, opts) do
    dispatch_single(exchange, capability_name, config, params, opts)
  end

  defp dispatch_raw_response(exchange, capability_name, {:fan_out, configs}, params, opts) do
    with {:ok, responses} <- dispatch_fan_out(exchange, capability_name, configs, params, opts) do
      {:ok, tag_raw_responses(configs, responses)}
    end
  end

  defp dispatch_raw_response(exchange, capability_name, {:broadcast, configs}, params, opts) do
    with {:ok, [response | _]} <- dispatch_fan_out(exchange, capability_name, configs, params, opts) do
      {:ok, response}
    end
  end

  defp dispatch_raw_response(exchange, capability_name, {:first_success, configs}, params, opts) do
    with {:ok, response, _config} <-
           dispatch_first_success(exchange, capability_name, configs, params, opts) do
      {:ok, response}
    end
  end

  defp dispatch_raw_response(exchange, capability_name, {:param_fan_out, config, variants}, params, opts) do
    with {:ok, {variants, responses}} <-
           dispatch_param_fan_out(exchange, capability_name, config, variants, params, opts) do
      {:ok, tag_param_fan_out_responses(config, variants, responses)}
    end
  end

  defp tag_raw_responses(configs, responses) do
    configs
    |> Enum.zip(responses)
    |> Enum.map(fn {config, %{body: body}} -> %{"api" => List.first(config.sections), "body" => body} end)
  end

  defp tag_param_fan_out_responses(config, variants, responses) do
    variants
    |> Enum.zip(responses)
    |> Enum.map(fn {variant, %{body: body}} ->
      %{"api" => List.first(config.sections), "params" => variant, "body" => body}
    end)
  end

  defp dispatch_single(%Exchange{} = exchange, capability_name, config, params, opts) do
    dispatch_opts = Keyword.drop(opts, @selection_opts)

    with {:ok, params} <- maybe_resolve_market_id(exchange, capability_name, params, opts) do
      dispatch_coinbase_pages(exchange, capability_name, config, params, opts, dispatch_opts)
    end
  end

  defp dispatch_coinbase_pages(
         %Exchange{id: "coinbaseexchange"} = exchange,
         "fetchOHLCV",
         config,
         params,
         opts,
         dispatch_opts
       ) do
    now_ms = Keyword.get(opts, :timestamp_ms_override, System.system_time(:millisecond))

    case CoinbaseCandlePagination.pagination(params, exchange.timeframes, now_ms) do
      {:single, completed_params} ->
        final_params = build_final_params(exchange, "fetchOHLCV", completed_params, opts, config.path)
        dispatch_and_paginate(exchange, "fetchOHLCV", config, final_params, dispatch_opts)

      {:paginate, pages, metadata} ->
        with {:ok, responses} <- dispatch_coinbase_page_requests(exchange, config, pages, opts, dispatch_opts) do
          {:ok, CoinbaseCandlePagination.merge_responses!(responses, metadata)}
        end
    end
  end

  defp dispatch_coinbase_pages(exchange, capability_name, config, params, opts, dispatch_opts) do
    final_params = build_final_params(exchange, capability_name, params, opts, config.path)
    dispatch_and_paginate(exchange, capability_name, config, final_params, dispatch_opts)
  end

  defp dispatch_coinbase_page_requests(exchange, config, pages, opts, dispatch_opts) do
    pages
    |> Enum.reduce_while({:ok, []}, fn %{params: params}, {:ok, responses} ->
      final_params = build_final_params(exchange, "fetchOHLCV", params, opts, config.path)

      case Dispatch.call(exchange, config, final_params, dispatch_opts) do
        {:ok, response} -> {:cont, {:ok, [response | responses]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, responses} -> {:ok, Enum.reverse(responses)}
      {:error, _reason} = error -> error
    end
  end

  # Instruments-info reads are the only cursor-paged capabilities; every other
  # capability dispatches straight through (a bare `Dispatch.call`).
  @bybit_paginated_instruments_methods ["fetchFutureMarkets", "fetchMarkets"]

  defp dispatch_and_paginate(exchange, capability_name, config, final_params, dispatch_opts) do
    case Dispatch.call(exchange, config, final_params, dispatch_opts) do
      {:ok, response} when capability_name in @bybit_paginated_instruments_methods ->
        maybe_paginate_bybit_instruments(exchange, config, final_params, response, dispatch_opts)

      other ->
        other
    end
  end

  defp dispatch_param_fan_out(%Exchange{} = exchange, capability_name, config, param_variants, params, opts) do
    with {:ok, param_variants} <- okx_option_market_variants(exchange, capability_name, param_variants, opts),
         {:ok, responses} <-
           dispatch_param_fan_out_requests(exchange, capability_name, config, param_variants, params, opts),
         :ok <- ensure_bybit_option_market_completeness(exchange, capability_name, param_variants, responses) do
      {:ok, {param_variants, responses}}
    end
  end

  defp dispatch_param_fan_out_requests(%Exchange{} = exchange, capability_name, config, param_variants, params, opts) do
    dispatch_opts = Keyword.drop(opts, @selection_opts)
    timeout = Keyword.get(opts, :timeout, Bourse.Defaults.request_timeout_ms())

    results =
      param_variants
      |> Task.async_stream(
        fn overlay ->
          with {:ok, merged} <-
                 params
                 |> Map.merge(overlay)
                 |> then(&maybe_resolve_market_id(exchange, capability_name, &1, opts)) do
            final_params = build_final_params(exchange, capability_name, merged, opts, config.path)
            dispatch_and_paginate(exchange, capability_name, config, final_params, dispatch_opts)
          end
        end,
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.to_list()

    collect_fan_out_responses(results, [config], exchange)
  end

  # Follow Bybit instruments-info `nextPageCursor` until empty (fetchFutureMarkets /
  # fetchMarkets linear|inverse waves). Merges list rows into the first response.
  defp maybe_paginate_bybit_instruments(
         %Exchange{id: "bybit"} = exchange,
         config,
         params,
         %{body: %{"result" => %{"list" => first_list}}} = response,
         dispatch_opts
       )
       when is_list(first_list) and is_map(params) do
    case get_in(response, [:body, "result", "nextPageCursor"]) do
      cursor when is_binary(cursor) and cursor != "" ->
        paginate_bybit_instruments(exchange, config, params, response, first_list, cursor, dispatch_opts, 0)

      _ ->
        {:ok, response}
    end
  end

  defp maybe_paginate_bybit_instruments(_exchange, _config, _params, response, _dispatch_opts), do: {:ok, response}

  @bybit_instruments_max_pages 20

  defp paginate_bybit_instruments(exchange, config, params, first_response, acc_list, cursor, dispatch_opts, page)
       when page < @bybit_instruments_max_pages do
    page_params = Map.put(params, "cursor", cursor)

    case Dispatch.call(exchange, config, page_params, dispatch_opts) do
      {:ok, %{body: %{"result" => %{"list" => more}}} = page_response} when is_list(more) ->
        next = get_in(page_response, [:body, "result", "nextPageCursor"])

        cond do
          # The venue handed back the cursor we just sent: the walk is not
          # advancing, so this page repeats rows we already hold. Drop it rather
          # than folding duplicates in, and report the cursor as unresolved.
          next == cursor ->
            finish_bybit_instruments(first_response, acc_list, cursor)

          # An empty page halts the walk even when a cursor is still advertised
          # (following it again would spin); the cursor is reported verbatim so
          # the surface reads as truncated rather than complete.
          is_binary(next) and next != "" and more != [] ->
            paginate_bybit_instruments(
              exchange,
              config,
              params,
              first_response,
              acc_list ++ more,
              next,
              dispatch_opts,
              page + 1
            )

          true ->
            finish_bybit_instruments(first_response, acc_list ++ more, next)
        end

      # A page that answers without a `list` cannot advance the walk; stop and
      # keep the cursor we could not follow so the surface reads as incomplete.
      {:ok, _} ->
        finish_bybit_instruments(first_response, acc_list, cursor)

      {:error, _} = error ->
        error
    end
  end

  # Page budget exhausted — retain the unfollowed cursor rather than silently
  # truncating, so the completeness guard (carve C13) fails loudly.
  defp paginate_bybit_instruments(_exchange, _config, _params, first_response, acc_list, cursor, _opts, _page) do
    finish_bybit_instruments(first_response, acc_list, cursor)
  end

  # The merged envelope must answer for the LAST page walked, not the first —
  # a stale page-1 cursor would report a fully-walked surface as truncated.
  defp finish_bybit_instruments(first_response, acc_list, cursor) do
    {:ok,
     first_response
     |> put_in([:body, "result", "list"], acc_list)
     |> put_in([:body, "result", "nextPageCursor"], cursor || "")}
  end

  # OKX rejects an OPTION instruments read without `uly` or `instFamily`. Unlike
  # Bybit's option base coins, the families are live venue data, so fetch them
  # before constructing one OPTION wave per underlying.
  defp okx_option_market_variants(%Exchange{id: "okx"} = exchange, "fetchMarkets", param_variants, opts) do
    dispatch_opts = Keyword.drop(opts, @selection_opts)

    with {:ok, response} <- okx_option_underlyings(exchange, dispatch_opts),
         {:ok, option_variants} <- okx_option_instrument_variants(response, exchange) do
      {:ok, param_variants ++ option_variants}
    end
  end

  defp okx_option_market_variants(_exchange, _capability_name, param_variants, _opts), do: {:ok, param_variants}

  defp okx_option_underlyings(%Exchange{} = exchange, dispatch_opts) do
    with module when is_atom(module) <- exchange.module || Registry.module_for(exchange.id),
         config when not is_nil(config) <-
           Enum.find(module.__endpoints__(), &(&1.name == :public_get_public_underlying)) do
      Dispatch.call(exchange, config, %{"instType" => "OPTION"}, dispatch_opts)
    else
      _ ->
        {:error,
         Error.not_supported(
           exchange: exchange.id,
           message: "#{exchange.id} does not expose public/underlying for option markets"
         )}
    end
  end

  # Live 2026-07-16 (my.okx.com demo): `data` nests the families one level —
  # `[["SOL-USD", "BTC-USD", "LTC-USD", "ETH-USD", "XAU-USD"]]`. Anything that
  # flattens to a non-string is an unrecognised carve: fail loudly rather than
  # filter it away, since a silent drop returns spot/futures/swap and no options.
  defp okx_option_instrument_variants(%{body: %{"data" => underlyings}} = response, %Exchange{} = exchange)
       when is_list(underlyings) do
    inst_type = get_in(exchange.spec, ["options", "exchangeType", "option"]) || "OPTION"
    families = List.flatten(underlyings)

    if Enum.all?(families, &is_binary/1) do
      {:ok, Enum.map(families, &%{"instType" => inst_type, "uly" => &1})}
    else
      okx_underlying_error(response, exchange)
    end
  end

  defp okx_option_instrument_variants(response, %Exchange{} = exchange) do
    okx_underlying_error(response, exchange)
  end

  defp okx_underlying_error(response, %Exchange{} = exchange) do
    {:error,
     Error.exchange_error(
       "Unexpected option underlying response from #{exchange.id}",
       exchange: exchange.id,
       raw: response
     )}
  end

  defp dispatch_fan_out(%Exchange{} = exchange, capability_name, configs, params, opts) do
    dispatch_opts = Keyword.drop(opts, @selection_opts)

    with {:ok, params} <- maybe_resolve_market_id(exchange, capability_name, params, opts) do
      final_params = build_final_params(exchange, capability_name, params, opts, nil)
      dispatch_fan_out_with_params(exchange, capability_name, configs, final_params, dispatch_opts, opts)
    end
  end

  defp dispatch_fan_out_with_params(%Exchange{} = exchange, _capability_name, configs, final_params, dispatch_opts, opts) do
    timeout = Keyword.get(opts, :timeout, Bourse.Defaults.request_timeout_ms())

    results =
      configs
      |> Task.async_stream(
        fn config -> Dispatch.call(exchange, config, final_params, dispatch_opts) end,
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.to_list()

    case Enum.find(results, &match?({:ok, {:error, _}}, &1)) do
      {:ok, {:error, _} = error} ->
        error

      nil ->
        collect_fan_out_responses(results, configs, exchange)
    end
  end

  defp dispatch_first_success(exchange, capability_name, configs, params, opts) do
    dispatch_first_success_route(exchange, capability_name, configs, params, opts)
  end

  defp dispatch_first_success_route(exchange, capability_name, [config | rest], params, opts) do
    case dispatch_single(exchange, capability_name, config, params, opts) do
      {:ok, response} ->
        {:ok, response, config}

      {:error, %Error{type: :order_not_found}} when rest != [] ->
        dispatch_first_success_route(exchange, capability_name, rest, params, opts)

      {:error, _reason} = error ->
        error
    end
  end

  # Lighter fetchTicker requires `{market_id: market.id}` after markets load —
  # the numeric index, not the unified symbol string. Authored shape marks
  # market_id as dynamic_construction; resolve it here before RequestShape.apply.
  # Prefer `exchange.markets` (from load_markets/1) so repeated calls reuse the
  # cache; only fetch when the struct has not been loaded yet.
  defp maybe_resolve_market_id(%Exchange{} = exchange, js_name, params, opts)
       when is_binary(js_name) and is_map(params) do
    case market_id_shape(exchange, js_name) do
      %{"optional" => true} ->
        if is_binary(params["symbol"]), do: resolve_market_id_param(exchange, params, opts), else: {:ok, params}

      %{} ->
        resolve_market_id_param(exchange, params, opts)

      nil ->
        {:ok, params}
    end
  end

  defp maybe_resolve_market_id(_exchange, _js_name, params, _opts), do: {:ok, params}

  defp market_id_shape(%Exchange{request_param_shape: shape}, js_name) when is_map(shape) do
    case get_in(shape, [js_name, "market_id"]) do
      %{"reason" => "dynamic_construction"} = entry -> entry
      _ -> nil
    end
  end

  defp market_id_shape(_exchange, _js_name), do: nil

  defp resolve_market_id_param(_exchange, %{"market_id" => _id} = params, _opts) do
    {:ok, params}
  end

  defp resolve_market_id_param(%Exchange{markets: markets} = exchange, %{"symbol" => symbol} = params, _opts)
       when is_list(markets) and is_binary(symbol) do
    with {:ok, market_id} <- market_id_for_symbol(markets, symbol, exchange) do
      {:ok, Map.put(params, "market_id", market_id)}
    end
  end

  defp resolve_market_id_param(%Exchange{} = exchange, %{"symbol" => symbol} = params, opts) when is_binary(symbol) do
    with {:ok, module} <- require_module(exchange),
         {:ok, markets} <- call_dispatch(exchange, module, :fetch_markets, "fetchMarkets", %{}, opts),
         {:ok, market_id} <- market_id_for_symbol(markets, symbol, exchange) do
      {:ok, Map.put(params, "market_id", market_id)}
    end
  end

  defp resolve_market_id_param(%Exchange{} = exchange, _params, _opts) do
    {:error,
     Error.bad_symbol(
       message: "#{exchange.id} requires a known market symbol to resolve market_id",
       exchange: exchange.id
     )}
  end

  defp market_id_for_symbol(markets, symbol, %Exchange{} = exchange) when is_list(markets) do
    case Enum.find(markets, &market_symbol_match?(&1, symbol)) do
      %{id: id} when is_binary(id) and id != "" ->
        {:ok, coerce_market_id(id)}

      %{id: id} when is_integer(id) ->
        {:ok, id}

      %{"id" => id} when is_binary(id) and id != "" ->
        {:ok, coerce_market_id(id)}

      _ ->
        {:error,
         Error.bad_symbol(
           message: "Unknown market symbol #{symbol}",
           exchange: exchange.id
         )}
    end
  end

  defp market_id_for_symbol(_markets, symbol, %Exchange{} = exchange) do
    {:error,
     Error.bad_symbol(
       message: "Unknown market symbol #{symbol}",
       exchange: exchange.id
     )}
  end

  defp market_symbol_match?(%{symbol: market_symbol}, symbol) when is_binary(market_symbol) do
    market_symbol == symbol
  end

  defp market_symbol_match?(%{"symbol" => market_symbol}, symbol) when is_binary(market_symbol) do
    market_symbol == symbol
  end

  defp market_symbol_match?(_market, _symbol), do: false

  # Lighter's API accepts integer market_id; market parse stores id as string.
  defp coerce_market_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp collect_fan_out_responses(results, _configs, %Exchange{} = exchange) do
    responses = for {:ok, {:ok, response}} <- results, do: response

    if length(responses) == length(results) do
      {:ok, responses}
    else
      reason =
        Enum.find_value(results, fn
          {:exit, :timeout} -> :timeout
          {:exit, reason} -> {:exit, reason}
          _ -> nil
        end)

      {:error,
       Error.exchange_error(
         "Multi-endpoint dispatch failed for #{exchange.id}",
         exchange: exchange.id,
         raw: reason
       )}
    end
  end

  defp build_final_params(%Exchange{} = exchange, capability_name, params, opts, endpoint_path) do
    market_type = infer_market_type(params, opts)

    shape_opts =
      opts
      |> Keyword.take([:timestamp_ms_override])
      |> Keyword.put(:endpoint_path, endpoint_path)
      |> Keyword.put(:market_type, market_type)
      |> Keyword.put(:market_family, infer_market_family(params, market_type) || exchange.default_family)

    {params, exchange} =
      case Exchange.markets(exchange) do
        markets when is_list(markets) and markets != [] ->
          OrderPrecision.guard_dispatch!(params, exchange, capability_name, shape_opts)

        _ ->
          {params, exchange}
      end

    # Keep endpoint-selection keys (e.g. OKX stop/trailing/trigger) through
    # RequestShape so venue builders can reshape cancel-algos bodies; drop them
    # after so they never reach the wire.
    params
    |> RequestShape.apply_premarket(exchange, capability_name)
    |> maybe_denormalize_symbol(exchange)
    |> maybe_translate_timeframe(exchange)
    |> maybe_merge_request_defaults(exchange, capability_name)
    |> RequestShape.apply(exchange, capability_name, shape_opts)
    |> drop_endpoint_selector_params(exchange, capability_name)
  end

  defp parse_fan_out_responses(%Exchange{} = exchange, module, method_atom, js_name, params, responses) do
    responses
    |> Enum.reduce_while({:ok, []}, fn response, {:ok, acc} ->
      case parse_unified_response(exchange, module, method_atom, js_name, params, response) do
        {:ok, items} when is_list(items) -> {:cont, {:ok, Enum.reverse(items, acc)}}
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _} = error -> error
    end
  end

  defp parse_param_fan_out_responses(%Exchange{} = exchange, module, method_atom, js_name, params, variants, responses) do
    variants
    |> Enum.zip(responses)
    |> Enum.reduce_while({:ok, []}, fn {variant, response}, {:ok, acc} ->
      case parse_unified_response(exchange, module, method_atom, js_name, Map.merge(params, variant), response) do
        {:ok, items} when is_list(items) -> {:cont, {:ok, Enum.reverse(items, acc)}}
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _} = error -> error
    end
  end

  @doc "Returns the JS capability name for a unified method atom."
  @spec js_name_for!(atom()) :: String.t()
  def js_name_for!(method) when is_atom(method) do
    Map.fetch!(@js_names, method)
  end

  @doc "Returns the unified method atom for a JS capability name, if known."
  @spec method_atom_for_js_name(String.t()) :: atom() | nil
  def method_atom_for_js_name(js_name) when is_binary(js_name) do
    Map.get(@js_to_method, js_name)
  end

  @doc "Returns required unified params for a method atom."
  @spec required_params_for(atom()) :: [atom()]
  def required_params_for(method) when is_atom(method) do
    Map.get(@required_params_by_method, method, [])
  end

  @doc """
  Denormalize a unified `"symbol"` param (e.g. `"BTC/USDT"`) into the exchange's
  native form (e.g. `"BTCUSDT"` on Binance, `"BTC-PERPETUAL"` on Deribit swap)
  before the params reach Dispatch.

  No-op when:
    * `params` has no `"symbol"` key
    * `params["symbol"]` is not a binary
    * `exchange.symbol_patterns` has no entry for the detected market type
      (`Bourse.Symbol.to_exchange_id/2` returns the input unchanged)

  Raw generated endpoint callers (`Bourse.Bybit.public_get_v5_market_tickers/3`)
  bypass this — they're expected to pass exchange-native symbols already.
  """
  @spec maybe_denormalize_symbol(map(), Exchange.t()) :: map()
  def maybe_denormalize_symbol(%{"symbol" => unified} = params, %Exchange{} = exchange) when is_binary(unified) do
    Map.put(params, "symbol", Symbol.to_exchange_id(unified, exchange))
  end

  def maybe_denormalize_symbol(params, _exchange), do: params

  @doc """
  Translate a unified `"timeframe"` param (e.g. `"1h"`) into the exchange-native
  OHLCV label from `capabilities.timeframes` before params reach Dispatch.

  No-op when:
    * `params` has no `"timeframe"` key
    * `params["timeframe"]` is not a binary
    * `exchange.timeframes` is nil or empty

  Raises `ArgumentError` when the map is present and the unified label is absent.
  """
  @spec maybe_translate_timeframe(map(), Exchange.t()) :: map()
  def maybe_translate_timeframe(%{"timeframe" => unified} = params, %Exchange{id: id, timeframes: timeframes})
      when is_binary(unified) and is_map(timeframes) and map_size(timeframes) > 0 do
    case Map.fetch(timeframes, unified) do
      # Native labels are usually strings ("1min") but some exchanges declare
      # numeric intervals — kraken/bitmart use integer minutes, others seconds.
      # Carry the native value through verbatim; query/body encoding stringifies.
      {:ok, native} when is_binary(native) or is_number(native) ->
        Map.put(params, "timeframe", native)

      _ ->
        supported = Enum.map_join(timeframes, ", ", fn {timeframe, _native} -> timeframe end)

        raise ArgumentError,
              "unsupported timeframe #{inspect(unified)} for exchange #{id}; supported: #{supported}"
    end
  end

  def maybe_translate_timeframe(params, _exchange), do: params

  @doc """
  Merge per-method default request-body params into the caller's params.

  Reads authored request-default literals materialized onto the Exchange struct
  at construction time.
  Caller-supplied params win over defaults (`Map.put_new` semantics).

  Unblocks exchanges like hyperliquid whose unified methods route through a
  single endpoint discriminated by a literal body field (e.g. `fetchTime` →
  `POST /info` with `{ "type": "exchangeStatus" }`).

  No-op when:
    * `exchange.request_defaults` has no entry for the method
    * the entries map is empty (all entries were `kind: "unresolved"` and filtered
      out at Exchange construction time)
  """
  @spec maybe_merge_request_defaults(map(), Exchange.t(), String.t()) :: map()
  def maybe_merge_request_defaults(params, %Exchange{request_defaults: defaults}, js_name)
      when is_map(params) and is_binary(js_name) do
    case Map.get(defaults, js_name) do
      literals when is_map(literals) and map_size(literals) > 0 ->
        Enum.reduce(literals, params, fn {k, v}, acc -> Map.put_new(acc, k, v) end)

      _ ->
        params
    end
  end

  @doc """
  Separates dispatch-level opts from exchange params.

  Accepts a keyword list or a map. The `:params`
  keyword is peeled off and its map entries are merged into exchange params;
  top-level keys override `:params` entries on conflict.

  Returns `{:error, %Error{type: :bad_request}}` for invalid opts shapes so
  public unified functions never raise `FunctionClauseError`.
  """
  @typep opt_entries :: [{atom() | String.t(), term()}]

  @spec split_opts(opt_entries() | map()) :: {:ok, {keyword(), opt_entries()}} | {:error, Error.t()}
  def split_opts(opts) do
    with {:ok, keyword_opts} <- coerce_opts(opts),
         {:ok, exchange_opts} <- merge_params_channel(keyword_opts) do
      {:ok, Keyword.split(exchange_opts, @dispatch_opts)}
    end
  end

  @doc "Separates opts while preserving method-specific positional guidance."
  @spec split_opts(opt_entries() | map(), atom()) :: {:ok, {keyword(), opt_entries()}} | {:error, Error.t()}
  def split_opts(opts, method) when is_atom(method) do
    result = split_opts(opts)

    # Only an opts-shape failure can be a mis-passed unified positional. A well-shaped
    # opts that fails later (e.g. a non-map :params channel) keeps its own message.
    with {:error, %Error{type: :bad_request}} <- result,
         {:error, _shape_error} <- coerce_opts(opts),
         hint when is_binary(hint) <- positional_hint(method) do
      {:error, Error.bad_request(message: "#{method} #{hint}, got: #{inspect(opts)}")}
    else
      _ -> result
    end
  end

  defp coerce_opts(opts) when is_list(opts) do
    if valid_opt_entries?(opts) do
      {:ok, opts}
    else
      invalid_opts(opts)
    end
  end

  defp coerce_opts(opts) when is_map(opts) do
    entries = Map.to_list(opts)

    if valid_opt_entries?(entries) do
      {:ok, entries}
    else
      invalid_opts(opts)
    end
  end

  defp coerce_opts(opts), do: invalid_opts(opts)

  defp invalid_opts(opts) do
    {:error, Error.bad_request(message: "opts must be a keyword list or map, got: #{inspect(opts)}")}
  end

  defp positional_hint(:fetch_order_book), do: "expects opts as a keyword list or map; pass depth as limit: depth"

  defp positional_hint(:fetch_positions_adl_rank),
    do: "expects opts as a keyword list or map; pass symbols as symbols: [...]"

  defp positional_hint(:fetch_orders_classic),
    do: ~s(expects opts as a keyword list or map; pass a symbol as symbol: "BTC/USDT")

  defp positional_hint(_method), do: nil

  defp valid_opt_entries?(opts) do
    Enum.all?(opts, fn
      {key, _value} when is_atom(key) or is_binary(key) -> true
      _other -> false
    end)
  end

  defp merge_params_channel(opts) do
    {params, rest} = pop_params_channel(opts)

    case params do
      params when is_map(params) ->
        {:ok, merge_params_entries(params, rest)}

      nil ->
        {:ok, rest}

      params ->
        {:error, Error.bad_request(message: "opts :params must be a map, got: #{inspect(params)}")}
    end
  end

  defp pop_params_channel(opts) do
    {atom_params, rest} = Keyword.pop(opts, :params)
    {string_params, rest} = pop_string_params(rest)

    {if(is_nil(atom_params), do: string_params, else: atom_params), rest}
  end

  defp pop_string_params(opts) do
    case List.keytake(opts, "params", 0) do
      {{"params", params}, rest} -> {params, rest}
      nil -> {nil, opts}
    end
  end

  defp merge_params_entries(params, rest) do
    rest_keys =
      MapSet.new(rest, fn {k, _} -> normalize_opt_key(k) end)

    params_entries =
      Enum.reject(Map.to_list(params), fn {k, _} ->
        MapSet.member?(rest_keys, normalize_opt_key(k))
      end)

    rest ++ params_entries
  end

  defp normalize_opt_key(k) when is_atom(k), do: Atom.to_string(k)
  defp normalize_opt_key(k) when is_binary(k), do: k

  @doc "Builds a string-keyed params map from required param names/values and extra opts."
  @spec build_params([atom()], [term()], opt_entries()) :: map()
  def build_params(required_names, required_values, extra) do
    params =
      required_names
      |> Enum.zip(required_values)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    Enum.reduce(extra, params, fn {k, v}, acc ->
      Map.put_new(acc, to_string(k), v)
    end)
  end

  @doc """
  Refuses param values that cannot reach the wire.

  Keyword lists, tuples, and structs survive `split_opts/2` (the opts
  envelope) and otherwise detonate in the signer. A keyword list in a
  required positional slot names the positional convention.
  """
  @spec validate_param_values(map(), atom()) :: {:ok, map()} | {:error, Error.t()}
  def validate_param_values(params, method) when is_map(params) and is_atom(method) do
    case Enum.find(params, fn {_key, value} -> not wire_encodable?(value) end) do
      nil -> {:ok, params}
      {key, value} -> {:error, non_encodable_param_error(key, value, method)}
    end
  end

  defp wire_encodable?(value) when is_binary(value) or is_number(value) or is_atom(value), do: true

  defp wire_encodable?(value) when is_struct(value), do: false

  defp wire_encodable?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_atom(key) or is_binary(key) -> wire_encodable?(nested)
      _other -> false
    end)
  end

  defp wire_encodable?(value) when is_list(value) do
    not keyword_param?(value) and Enum.all?(value, &wire_encodable?/1)
  end

  defp wire_encodable?(_value), do: false

  defp keyword_param?(value) when is_list(value) and value != [], do: Keyword.keyword?(value)
  defp keyword_param?(_value), do: false

  defp non_encodable_param_error(key, value, method) do
    name = param_key_atom(key)
    required = required_params_for(method)
    kind = value_kind(value)

    message =
      if positional_keyword_mistake?(name, value, required) do
        arity = length(required) + 1

        "invalid parameter #{inspect(to_string(name))}: expected a query/JSON-encodable value, " <>
          "got a #{kind}; #{name} is a positional argument of #{method}/#{arity}, not a keyword option"
      else
        "invalid parameter #{inspect(to_string(key))}: expected a query/JSON-encodable value " <>
          "(binary, number, boolean, list, or map), got a #{kind}"
      end

    Error.invalid_parameters(message: message)
  end

  defp positional_keyword_mistake?(name, value, required) do
    name in required and name not in @list_required_params and keyword_param?(value)
  end

  defp param_key_atom(key) when is_atom(key), do: key

  defp param_key_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp param_key_atom(_key), do: nil

  defp value_kind(value) when is_struct(value), do: "#{inspect(value.__struct__)} struct"
  defp value_kind(value) when is_tuple(value), do: "tuple"
  defp value_kind(value) when is_pid(value), do: "pid"
  defp value_kind(value) when is_function(value), do: "function"
  defp value_kind(value) when is_reference(value), do: "reference"
  defp value_kind(value) when is_port(value), do: "port"

  defp value_kind(value) when is_list(value) do
    if keyword_param?(value), do: "keyword list", else: "list"
  end

  defp value_kind(_value), do: "non-encodable value"

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Resolves the exchange module from struct field or registry fallback
  defp require_module(%Exchange{module: module}) when not is_nil(module), do: {:ok, module}

  defp require_module(%Exchange{id: id}) do
    case Registry.module_for(id) do
      nil ->
        {:error,
         Error.not_supported(
           exchange: id,
           message: "No compiled module found for exchange #{id}"
         )}

      module ->
        {:ok, module}
    end
  end

  defp parse_unified_response(exchange, module, method_atom, js_name, params, response, config \\ nil)

  defp parse_unified_response(%Exchange{id: "bybit"}, _module, :fetch_status, "fetchStatus", _params, response, _config) do
    case response_body(response) do
      %{"retCode" => code, "result" => %{"list" => events}} = body when code in [0, "0"] and is_list(events) ->
        {:ok, bybit_status(body, events)}

      %{} = body ->
        {:error, Error.exchange_error("Bybit status request failed", exchange: "bybit", raw: body)}

      body ->
        {:error, {:unexpected_response_shape, body}}
    end
  end

  defp parse_unified_response(%Exchange{id: "okx"}, _module, :fetch_status, "fetchStatus", _params, response, _config) do
    case response_body(response) do
      %{"code" => code} = body when code in [0, "0"] ->
        {:ok, okx_status(body)}

      %{} = body ->
        {:error, Error.exchange_error("OKX status request failed", exchange: "okx", raw: body)}

      body ->
        {:error, {:unexpected_response_shape, body}}
    end
  end

  defp parse_unified_response(
         %Exchange{id: "alpaca"},
         _module,
         :cancel_order,
         "cancelOrder",
         params,
         %{status: 204},
         _config
       ) do
    {:ok,
     %Bourse.Order{
       id: params["id"] || params["order_id"],
       status: "canceled",
       info: %{"http_status" => 204}
     }}
  end

  defp parse_unified_response(%Exchange{id: "derive"} = exchange, module, method_atom, js_name, params, response, config)
       when method_atom in [:create_order, :cancel_order] do
    ReadParse.parse(
      exchange,
      module,
      method_atom,
      js_name,
      response_body(response),
      put_endpoint_parse_context(params, config, exchange, method_atom),
      :parse_order,
      false
    )
  end

  defp parse_unified_response(%Exchange{id: "lighter"}, _module, method_atom, _js_name, _params, response, _config)
       when method_atom in [:create_order, :cancel_order] do
    case response_body(response) do
      %{"code" => code, "tx_hash" => tx_hash} = body when code in [200, "200"] and is_binary(tx_hash) and tx_hash != "" ->
        {:ok, body}

      %{} = body ->
        {:error, Error.exchange_error("Lighter transaction request failed", exchange: "lighter", raw: body)}

      body ->
        {:error, {:unexpected_response_shape, body}}
    end
  end

  defp parse_unified_response(%Exchange{} = exchange, module, method_atom, js_name, params, response, config) do
    case parser_plan(method_atom, js_name) do
      {:ok, parser, list_return?} when is_atom(parser) ->
        response
        |> response_body()
        |> then(
          &ReadParse.parse(
            exchange,
            module,
            method_atom,
            js_name,
            &1,
            put_endpoint_parse_context(params, config, exchange, method_atom),
            parser,
            list_return?
          )
        )
        |> reconcile_position_units(parser, exchange)

      :none ->
        {:ok, response_body(response)}
    end
  end

  defp reconcile_position_units(result, :parse_position, exchange), do: DeribitPositionUnits.reconcile(result, exchange)

  defp reconcile_position_units(result, _parser, _exchange), do: result

  # OKX reports maintenance as rows in `data`; an empty list is normal operation
  # rather than an empty resource collection. Each row carries the window end
  # (`end`) as the ETA and an announcement `href`, and only an `ongoing` row
  # actually degrades service — `scheduled`/`completed`/`canceled` windows stay
  # operational. A `code: "0"` envelope alone does NOT imply "ok".
  defp okx_status(body) do
    events = if is_list(body["data"]), do: body["data"], else: []
    initial = %{updated: nil, status: if(events == [], do: "ok", else: "maintenance"), eta: nil, url: nil, info: body}

    Enum.reduce(events, initial, fn
      event, acc when is_map(event) ->
        acc = %{acc | eta: Safe.integer(event["end"]), url: Safe.string(event["href"])}

        case Safe.string(event["state"]) do
          "ongoing" -> %{acc | status: "maintenance"}
          state when state in ["scheduled", "completed", "canceled"] -> %{acc | status: "ok"}
          _other -> acc
        end

      _event, acc ->
        acc
    end)
  end

  # Bybit returns completed status history alongside current events. Only an
  # `ongoing` event describes a present service degradation; `scheduled` is future.
  defp bybit_status(body, events) do
    ongoing = Enum.find(events, &(is_map(&1) and Safe.string(&1["state"]) == "ongoing"))

    %{
      status: if(ongoing, do: "maintenance", else: "ok"),
      updated: nil,
      eta: ongoing && Safe.integer(ongoing["end"]),
      url: ongoing && Safe.string(ongoing["href"]),
      info: body
    }
  end

  defp put_endpoint_market_type(params, nil, _exchange, _method_atom), do: params

  defp put_endpoint_market_type(params, config, exchange, method_atom) do
    case endpoint_market_type(config, exchange, method_atom) do
      nil -> params
      market_type -> Map.put(params, "_bourse_endpoint_market_type", market_type)
    end
  end

  defp put_endpoint_parse_context(params, config, exchange, method_atom) do
    params
    |> put_endpoint_market_type(config, exchange, method_atom)
    |> put_endpoint_route(config)
  end

  defp put_endpoint_route(params, nil), do: params

  defp put_endpoint_route(params, config) do
    params
    |> Map.put("_bourse_endpoint_route", config.path)
    |> put_endpoint_id(config)
  end

  @doc "Builds a route identity from every section, the HTTP method, and the path."
  @spec endpoint_id(map()) :: String.t() | nil
  def endpoint_id(%{sections: sections, method: method, path: path})
      when is_list(sections) and is_atom(method) and is_binary(path) do
    Enum.join(sections ++ [Atom.to_string(method), path], "/")
  end

  def endpoint_id(_config), do: nil

  defp put_endpoint_id(params, config) do
    case endpoint_id(config) do
      id when is_binary(id) -> Map.put(params, "_bourse_endpoint_id", id)
      nil -> params
    end
  end

  # Binance's endpoint family disambiguates compact native ids. The spot rule remains scoped to
  # `binance`; Binance USD-M has distinct fapi (linear) and dapi (inverse) families.
  # Section names in @spot_sections ("public"/"v1") are shared across venues and market
  # families — bybit's v5 derivative endpoints and binanceusdm's COIN-M (dapi `v1`) reuse them —
  # so a section-name-only match wrongly stamps non-spot rows as spot and overrides their correct
  # per-id classification (observed: regressed binanceusdm inverse tickers and bybit funding/greeks
  # multi-row reads against the static-fixture gate). Contract families are self-describing
  # in their ids and need no generic endpoint hint.
  defp endpoint_market_type(config, %Exchange{id: "binance"}, :fetch_all_greeks) do
    case endpoint_section(config) do
      "eapiPublic" -> :option
      section when section in @spot_sections -> :spot
      _section -> nil
    end
  end

  defp endpoint_market_type(config, %Exchange{id: "binance"}, _method_atom) do
    if endpoint_section(config) in @spot_sections, do: :spot
  end

  # binanceusdm's fapi/dapi split is threaded for `fetch_tickers` only. Its contract ids are
  # otherwise self-describing, and stamping a family onto every read would override the correct
  # per-id classification on order/position/trade rows that already resolve without a hint.
  defp endpoint_market_type(config, %Exchange{id: "binanceusdm"}, method_atom)
       when method_atom in [:fetch_tickers, :fetch_leverages] do
    case endpoint_section(config) do
      section when section in @swap_sections -> :swap
      section when section in @future_sections -> :future
      _ -> nil
    end
  end

  defp endpoint_market_type(_config, _exchange, _method_atom), do: nil

  # Deribit DVOL history is array-of-pairs (not a field_map object). Route even
  # when a venue descriptor is absent — the parse slot is special-cased in ReadParse.
  defp parser_plan(:fetch_volatility_history, "fetchVolatilityHistory") do
    {:ok, :parse_volatility_history, true}
  end

  # `fetchTime` returns an integer millisecond timestamp, not a struct.
  defp parser_plan(:fetch_time, "fetchTime") do
    {:ok, :parse_time, false}
  end

  # Descriptor says Promise<LeverageTiers> (dict-shaped token) but every wired venue
  # returns a flat list of tier rows — same as fetchMarketLeverageTiers. Force list
  # return so we don't collapse the body into a single all-nil LeverageTier.
  defp parser_plan(:fetch_leverage_tiers, "fetchLeverageTiers") do
    {:ok, :parse_leverage_tiers, true}
  end

  defp parser_plan(method_atom, js_name) when is_atom(method_atom) do
    with %{"signature" => %{"return_type" => return_type}} <- Map.get(Descriptor.descriptors(), js_name),
         {:ok, parse_type} <- parse_type_from_return(return_type),
         {:ok, parser} <- Map.fetch(@parsers_by_parse_type, parse_type) do
      list_return? = String.ends_with?(return_type, "[]>")
      {:ok, parser, list_return?}
    else
      _ -> :none
    end
  end

  defp parse_type_from_return("Promise<" <> rest) do
    type_token =
      rest
      |> String.trim_trailing(">")
      |> String.trim_trailing("[]")

    type_token
    |> then(&Map.get(@return_type_aliases, &1, &1))
    |> parse_type_for_token()
  end

  defp parse_type_from_return(_return_type), do: :error

  defp parse_type_for_token(type_token), do: Map.fetch(@parse_types_by_return_type, type_token)

  defp response_body(%{body: body}), do: body

  # Looks up unified endpoint configs and selects one (raw_call / single dispatch).
  defp resolve_endpoint(%Exchange{} = exchange, module, method_atom, capability_name, params, opts) do
    case resolve_dispatch_plan(exchange, module, method_atom, capability_name, params, opts) do
      {:error, _} = error ->
        error

      {:ok, {:single, config}} ->
        {:ok, config}

      {:ok, {:fan_out, configs}} ->
        {:ok, hd(configs)}

      {:ok, {:broadcast, configs}} ->
        {:ok, hd(configs)}

      {:ok, {:first_success, configs}} ->
        {:ok, hd(configs)}

      {:ok, {:param_fan_out, config, _param_variants}} ->
        {:ok, config}
    end
  end

  # Resolves single-endpoint vs concurrent fan-out for unified dispatch.
  defp resolve_dispatch_plan(%Exchange{} = exchange, module, method_atom, capability_name, params, opts) do
    case module.__unified_endpoint__(method_atom) do
      [] ->
        {:error,
         Error.not_supported(
           exchange: exchange.id,
           message: unsupported_capability_message(exchange, method_atom, capability_name)
         )}

      [config] ->
        finalize_single_config_plan(exchange, method_atom, config, params, opts)

      configs ->
        resolve_multi_config_plan(exchange, method_atom, capability_name, configs, params, opts)
    end
  end

  # Hyperliquid has no public market-trade tape. The CCXT compatibility mapping
  # routes fetchTrades to wallet fills; Bourse deliberately diverges — see the carve register.
  defp unsupported_capability_message(%Exchange{id: "hyperliquid"}, :fetch_trades, _capability_name) do
    "hyperliquid does not support fetch_trades (no public market tape); use fetch_my_trades for per-wallet fills"
  end

  defp unsupported_capability_message(%Exchange{id: id}, _method_atom, capability_name) do
    "#{id} does not support #{capability_name}"
  end

  defp finalize_single_config_plan(exchange, method_atom, config, params, opts) do
    case param_fan_out_plan(exchange, method_atom, params, opts) do
      {:ok, param_variants} -> {:ok, {:param_fan_out, config, param_variants}}
      :no_param_fan_out -> {:ok, {:single, config}}
    end
  end

  defp resolve_multi_config_plan(exchange, method_atom, capability_name, configs, params, opts) do
    selection_params = batch_order_selection_params(params, method_atom)

    plan =
      case authored_book_dispatch_plan(exchange, method_atom, configs, selection_params, opts) do
        :none ->
          fallback_multi_config_plan(exchange, method_atom, capability_name, configs, params, selection_params, opts)

        authored_plan ->
          authored_plan
      end

    case plan do
      {:ok, {:single, config}} -> finalize_single_config_plan(exchange, method_atom, config, params, opts)
      other -> other
    end
  end

  defp fallback_multi_config_plan(exchange, method_atom, capability_name, configs, params, selection_params, opts) do
    if fan_out?(exchange, method_atom, configs, params, opts) do
      plan_fan_out_dispatch(exchange, method_atom, capability_name, configs)
    else
      case select_endpoint(configs, exchange, method_atom, opts, selection_params) do
        {:ok, config} -> {:ok, {:single, config}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp batch_order_selection_params(%{"orders" => [%{"symbol" => symbol} | _]} = params, method_atom)
       when method_atom in [:create_orders, :edit_orders] and is_binary(symbol) do
    Map.put_new(params, "symbol", symbol)
  end

  defp batch_order_selection_params(params, _method_atom), do: params

  defp authored_book_dispatch_plan(exchange, method_atom, configs, params, opts) do
    selection = Map.get(exchange.endpoint_selection, js_name_for!(method_atom), %{})
    context = selection_context(params, opts, exchange)

    selection
    |> Map.get("book_routes", [])
    |> Enum.find(&selection_conditions_match?(Map.get(&1, "when", %{}), context))
    |> resolve_book_dispatch_plan(configs, exchange, method_atom)
  end

  defp resolve_book_dispatch_plan(nil, _configs, _exchange, _method_atom), do: :none

  defp resolve_book_dispatch_plan(%{"mode" => mode, "endpoints" => targets}, configs, exchange, method_atom)
       when is_list(targets) do
    selected = Enum.map(targets, fn target -> Enum.find(configs, &endpoint_target?(&1, target)) end)

    with true <- selected != [] and Enum.all?(selected, &is_map/1),
         {:ok, reachable} <- ensure_book_routes_reachable(selected, configs, exchange, method_atom) do
      book_dispatch_plan(mode, reachable, exchange, method_atom)
    else
      false -> invalid_book_route(exchange, method_atom)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_book_dispatch_plan(_route, _configs, exchange, method_atom) do
    invalid_book_route(exchange, method_atom)
  end

  defp ensure_book_routes_reachable(selected, configs, exchange, method_atom) do
    selected
    |> Enum.reduce_while({:ok, []}, fn config, {:ok, reachable} ->
      case ensure_reachable(config, configs, exchange, method_atom) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | reachable]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reachable} -> {:ok, Enum.reverse(reachable)}
      {:error, _reason} = error -> error
    end
  end

  defp book_dispatch_plan("merge", configs, _exchange, _method_atom), do: {:ok, {:fan_out, configs}}
  defp book_dispatch_plan("broadcast", configs, _exchange, _method_atom), do: {:ok, {:broadcast, configs}}
  defp book_dispatch_plan("first_success", configs, _exchange, _method_atom), do: {:ok, {:first_success, configs}}
  defp book_dispatch_plan(_mode, _configs, exchange, method_atom), do: invalid_book_route(exchange, method_atom)

  defp invalid_book_route(exchange, method_atom) do
    {:error,
     Error.bad_request(
       exchange: exchange.id,
       message: "invalid authored order-book route for #{js_name_for!(method_atom)} on #{exchange.id}"
     )}
  end

  defp plan_fan_out_dispatch(%Exchange{} = exchange, method_atom, capability_name, configs) do
    case configs |> market_surface_configs(exchange, method_atom) |> credential_reachable_configs(exchange) do
      [config] ->
        {:ok, {:single, config}}

      [] ->
        {:error,
         Error.not_supported(
           exchange: exchange.id,
           message: "#{exchange.id} has no public #{capability_name} endpoints"
         )}

      fan_out_configs ->
        {:ok, {:fan_out, fan_out_configs}}
    end
  end

  defp credential_reachable_configs(configs, %Exchange{credentials: nil}) do
    Enum.filter(configs, &(&1.authenticated == false))
  end

  defp credential_reachable_configs(configs, %Exchange{}), do: configs

  defp fan_out?(exchange, method_atom, configs, params, opts) do
    method_atom in @fan_out_methods and
      length(configs) > 1 and
      is_nil(Keyword.get(opts, :endpoint_index)) and
      is_nil(infer_market_type(params, opts)) and
      param_fan_out_plan(exchange, method_atom, params, opts) == :no_param_fan_out
  end

  # Binance USD-M market discovery is linear-only: the fapi surface
  # answers for the fapi surface on mainnet as well as the testnet, and carries
  # `has.spot: false`. The other surfaces stay reachable through the authored
  # `fetchMarkets` rules; they are only off the no-arg fan-out.
  defp market_surface_configs(configs, %Exchange{id: "binanceusdm"}, :fetch_markets),
    do: Enum.filter(configs, &(endpoint_section(&1) == "fapiPublic"))

  # Binance COIN-M market discovery is inverse-only: the
  # COIN-M venue is dapi-only. Without this filter the no-arg fan-out walks the
  # inherited multi-surface `fetchMarkets` rules (spot/fapi/eapi/sapi) and, with
  # a null market envelope, each exchangeInfo map collapses to one all-nil
  # Market (task 415: four nil rows live).
  defp market_surface_configs(configs, %Exchange{id: "binancecoinm"}, :fetch_markets),
    do: Enum.filter(configs, &(endpoint_section(&1) == "dapiPublic"))

  # Binance market discovery keeps spot/linear/inverse under sandbox and drops
  # exactly two waves: `option` is skipped whenever demo/sandbox is on, and the
  # sapi margin pairs ride `fetchMargins && checkRequiredCredentials (false) &&
  # !isDemoEnv`. Binance's testnet hosts publish no sapi or eapi base at all, so
  # either wave resolves onto the dapi template and the venue answers -5000 for
  # `/dapi/v1/margin/allPairs`, failing the whole fan-out.
  defp market_surface_configs(configs, %Exchange{id: "binance", sandbox: true}, :fetch_markets),
    do: Enum.reject(configs, &(endpoint_section(&1) in ["sapi", "eapiPublic"]))

  defp market_surface_configs(configs, _exchange, _method_atom), do: configs

  defp endpoint_section(config), do: List.first(config.sections)

  defp param_fan_out_plan(%Exchange{id: "bybit"} = exchange, :fetch_markets, params, opts) do
    if param_fan_out_allowed?(params, opts) do
      case bybit_fetch_markets_param_variants(exchange) do
        [] -> :no_param_fan_out
        variants -> {:ok, variants}
      end
    else
      :no_param_fan_out
    end
  end

  # Bare fetchFutureMarkets has no category; fetchMarkets always supplies
  # one. Fan out linear + inverse with limit=1000 so a no-arg call matches the
  # derivative surface (USDC linear settles ride the linear category).
  defp param_fan_out_plan(%Exchange{id: "bybit"}, :fetch_future_markets, params, opts) do
    if param_fan_out_allowed?(params, opts) do
      {:ok, bybit_fetch_future_markets_param_variants()}
    else
      :no_param_fan_out
    end
  end

  defp param_fan_out_plan(%Exchange{id: "okx"} = exchange, :fetch_markets, params, opts) do
    if param_fan_out_allowed?(params, opts) do
      case okx_fetch_markets_param_variants(exchange) do
        [] -> :no_param_fan_out
        variants -> {:ok, variants}
      end
    else
      :no_param_fan_out
    end
  end

  # Derive's `fetchMarkets` composes the three typed get_all_instruments calls.
  # Keep the variants in the authored leaf defaults so the literals remain part
  # of the venue contract rather than dispatcher configuration.
  defp param_fan_out_plan(%Exchange{id: "derive"} = exchange, :fetch_markets, params, opts) do
    if param_fan_out_allowed?(params, opts) do
      variants =
        exchange.request_defaults
        |> Map.take(~w(fetchSpotMarkets fetchSwapMarkets fetchOptionMarkets))
        |> Map.values()

      case variants do
        [] -> :no_param_fan_out
        variants -> {:ok, variants}
      end
    else
      :no_param_fan_out
    end
  end

  # Hyperliquid fetchMarkets fans out across spot and swap.
  # HIP-3 is a separate surface (sibling task) — not part of the bare fan-out.
  # Authority: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint
  defp param_fan_out_plan(%Exchange{id: "hyperliquid"}, :fetch_markets, params, opts) do
    if param_fan_out_allowed?(params, opts) do
      {:ok,
       [
         %{"type" => "metaAndAssetCtxs"},
         %{"type" => "spotMetaAndAssetCtxs"}
       ]}
    else
      :no_param_fan_out
    end
  end

  defp param_fan_out_plan(_exchange, _method_atom, _params, _opts), do: :no_param_fan_out

  @bybit_future_markets_limit 1000

  # instruments-info omits PreLaunch instruments from a default-status read, so
  # they are a second wave per category rather than extra rows on the first —
  # verified live testnet 2026-07-17: linear default 724 + PreLaunch 22 = 746.
  @bybit_future_markets_statuses [nil, "PreLaunch"]

  defp bybit_fetch_future_markets_param_variants do
    for category <- ["linear", "inverse"],
        status <- @bybit_future_markets_statuses do
      maybe_put_status(%{"category" => category, "limit" => @bybit_future_markets_limit}, status)
    end
  end

  defp maybe_put_status(variant, nil), do: variant
  defp maybe_put_status(variant, status), do: Map.put(variant, "status", status)

  # Bybit's per-request maximum. Not trusted to be "enough" — every option wave
  # is checked against the venue's own `nextPageCursor` (carve C13), so a page
  # that outgrows this limit fails loudly instead of truncating.
  @bybit_option_markets_limit 1000

  # Bybit fetchMarkets categories come from the vendored describe slice
  # `options.fetchMarkets.types` (spot/linear/inverse/option) — never a
  # hardcoded three-entry list. Live 2026-07-16: bare `category=option`
  # succeeds but returns only BTC (same set as baseCoin=BTC); the describe
  # `options` baseCoin list is required for multi-base option coverage.
  defp bybit_fetch_markets_param_variants(%Exchange{} = exchange) do
    config = get_in(exchange.spec, ["options", "fetchMarkets"]) || %{}
    types = List.wrap(config["types"])
    option_bases = List.wrap(config["options"])

    Enum.flat_map(types, &bybit_fetch_markets_variants_for_type(&1, option_bases))
  end

  defp bybit_fetch_markets_variants_for_type("option", []) do
    [%{"category" => "option", "limit" => @bybit_option_markets_limit}]
  end

  defp bybit_fetch_markets_variants_for_type("option", bases) do
    Enum.map(bases, &%{"category" => "option", "baseCoin" => &1, "limit" => @bybit_option_markets_limit})
  end

  defp bybit_fetch_markets_variants_for_type(category, _bases) when is_binary(category) do
    [%{"category" => category}]
  end

  defp bybit_fetch_markets_variants_for_type(_other, _bases), do: []

  defp ensure_bybit_option_market_completeness(%Exchange{id: "bybit"}, "fetchMarkets", param_variants, responses) do
    param_variants
    |> Enum.zip(responses)
    |> Enum.reduce_while(:ok, fn
      {%{"category" => "option"} = variant, response}, :ok ->
        case get_in(response, [:body, "result", "nextPageCursor"]) do
          cursor when is_binary(cursor) and cursor != "" ->
            base_coin = Map.get(variant, "baseCoin", "all base coins")

            {:halt,
             {:error,
              Error.exchange_error(
                "Bybit option markets are incomplete for #{base_coin}; nextPageCursor=#{cursor}",
                exchange: "bybit",
                raw: response
              )}}

          _ ->
            {:cont, :ok}
        end

      _, :ok ->
        {:cont, :ok}
    end)
  end

  defp ensure_bybit_option_market_completeness(_exchange, _capability_name, _param_variants, _responses), do: :ok

  # OKX fetchMarkets static waves come from the venue's own
  # `options.fetchMarkets.types`. OPTION is expanded separately from the live
  # `public/underlying` response because instruments requires `uly` or instFamily.
  @okx_fetch_markets_excluded_types ~w(option)

  defp okx_fetch_markets_param_variants(%Exchange{} = exchange) do
    exchange.spec
    |> get_in(["options", "fetchMarkets", "types"])
    |> List.wrap()
    |> Enum.reject(&(&1 in @okx_fetch_markets_excluded_types))
    |> Enum.map(fn type ->
      inst_type = get_in(exchange.spec, ["options", "exchangeType", type]) || String.upcase(type)
      %{"instType" => inst_type}
    end)
  end

  defp param_fan_out_allowed?(params, opts) do
    is_nil(Keyword.get(opts, :endpoint_index)) and
      is_nil(infer_market_type(params, opts)) and
      is_nil(params["category"]) and
      is_nil(params["type"]) and
      is_nil(params["instType"]) and
      is_nil(params["instrument_type"])
  end

  # First-class venues must not silently fall through to bare `hd(configs)` for
  # multi-endpoint selection. Long-tail public-data-only venues keep
  # the legacy positional default.
  @runtime_manifest Bourse.Spec.manifest_path()
  @external_resource @runtime_manifest
  @runtime_venues Bourse.Spec.exchanges()

  # Named no-arg-read method set used by the bare-hd audit.
  # Multi-endpoint pairs on first-class venues in this set must resolve via
  # authored endpoint_selection / default_family / market-type signal, or fail
  # loudly — never by bare list ordering.
  @no_arg_read_methods [
    :fetch_time,
    :fetch_status,
    :fetch_markets,
    :fetch_currencies,
    :fetch_tickers,
    :fetch_funding_rates,
    :fetch_positions,
    :fetch_open_orders,
    :fetch_open_order_lists,
    :fetch_balance,
    :fetch_accounts,
    :fetch_trading_fees,
    :fetch_deposit_withdraw_fees,
    :fetch_borrow_rates,
    :fetch_leverage_tiers,
    :fetch_my_trades,
    :fetch_orders,
    :fetch_order_lists,
    :fetch_closed_orders,
    :fetch_canceled_orders,
    :fetch_deposits,
    :fetch_withdrawals,
    :fetch_ledger,
    :fetch_transfers,
    :fetch_open_interests
  ]

  @doc "Named no-arg-read method set for the bare-hd audit."
  @spec no_arg_read_methods() :: [atom()]
  def no_arg_read_methods, do: @no_arg_read_methods

  @doc "First-class venue ids (authored-spec / owned-schema scope)."
  @spec first_class_venues() :: [String.t()]
  def first_class_venues, do: @runtime_venues

  @doc "Lists mapped unified methods that no documented endpoint-selection parameter set can reach."
  @spec mapped_endpoint_reachability_failures() :: [{String.t(), atom()}]
  def mapped_endpoint_reachability_failures do
    for id <- @runtime_venues,
        method <- Registry.module_for(id).__unified_endpoints__() |> Map.keys() |> Enum.sort(),
        not mapped_endpoint_reachable?(id, method),
        do: {id, method}
  end

  defp mapped_endpoint_reachable?(exchange_id, method_atom) do
    module = Registry.module_for(exchange_id)

    case module.__unified_endpoint__(method_atom) do
      [] ->
        true

      _configs ->
        exchange = Exchange.new!(exchange_id, api_key: "k", secret: "s", password: "p")
        param_sets = [%{} | Enum.map(@endpoint_selection_param_sets, &elem(&1, 1))]

        Enum.any?(param_sets, fn params ->
          match?(
            {:ok, _plan},
            resolve_dispatch_plan(exchange, module, method_atom, js_name_for!(method_atom), params, [])
          )
        end)
    end
  end

  @doc """
  Lists first-class `{exchange_id, method}` pairs from the no-arg-read set that
  still resolve multi-endpoint selection by bare `hd(configs)`.

  This list must be empty. Fan-out methods and pairs with
  an authored `endpoint_selection` / `default_family` / configured default are
  not counted. Loud first-class failures are also not bare-hd resolutions.
  """
  @spec bare_hd_no_arg_pairs() :: [{String.t(), atom()}]
  def bare_hd_no_arg_pairs do
    for id <- @runtime_venues,
        method <- @no_arg_read_methods,
        bare_hd_no_arg_pair?(id, method),
        do: {id, method}
  end

  defp bare_hd_no_arg_pair?(exchange_id, method_atom) do
    configs = Registry.module_for(exchange_id).__unified_endpoint__(method_atom)
    exchange = Exchange.new!(exchange_id, api_key: "k", secret: "s", password: "p")
    params = %{}
    opts = []

    multi? = length(configs) > 1
    fan_out_like? = multi? and fan_out?(exchange, method_atom, configs, params, opts)

    multi? and not fan_out_like? and bare_hd_selection?(configs, exchange, method_atom, params, opts)
  end

  # Bare hd = selected element zero without authored/configured/default_family.
  # First-class never takes that path (loud-fails instead).
  defp bare_hd_selection?(configs, exchange, method_atom, params, opts) do
    explicit? =
      not is_nil(
        configured_endpoint(exchange, method_atom, configs) ||
          authored_endpoint(exchange, method_atom, configs, params, opts) ||
          infer_endpoint(configs, exchange, params, opts)
      )

    case select_endpoint(configs, exchange, method_atom, opts, params) do
      {:ok, config} -> config == hd(configs) and not explicit?
      {:error, _} -> false
    end
  end

  # Selects endpoint config: override via :endpoint_index, else configured /
  # authored selection, else market-type / default_family inference. Returns
  # `{:ok, config}` or `{:error, Error.t()}` — first-class multi-endpoint
  # selection never silently uses bare `hd(configs)`.
  defp select_endpoint(configs, exchange, method_atom, opts, params) do
    case Keyword.get(opts, :endpoint_index) do
      idx when is_integer(idx) ->
        {:ok, Enum.at(configs, idx) || hd(configs)}

      _ ->
        # Explicit stages (authored/configured) express authored venue intent, so
        # they resolve over the FULL config list — a credless pre-filter would make
        # an authored rule targeting an authenticated endpoint silently miss and
        # fall through to an unrelated config (observed: credless alpaca
        # fetch_ohlcv rerouted GLD to the crypto endpoint). The heuristic infer
        # stage and the hd-fallback stay on the credential-reachable subset.
        reachable = credential_reachable_configs(configs, exchange)

        case selected_config(configs, reachable, exchange, method_atom, params, opts) do
          %{} = config ->
            ensure_reachable(config, configs, exchange, method_atom)

          nil ->
            unresolved_multi_endpoint(reachable, exchange, method_atom)
        end
    end
  end

  defp selected_config(configs, reachable, exchange, method_atom, params, opts) do
    authored_endpoint(exchange, method_atom, configs, params, opts) ||
      configured_endpoint(exchange, method_atom, configs) ||
      infer_endpoint(reachable, exchange, params, opts)
  end

  # An explicitly resolved endpoint the exchange cannot call without credentials
  # never reroutes silently: venues list private+public twins of the same path
  # (bybit v5/market/instruments-info), so substitute the public twin when one
  # exists; otherwise fail loud — the caller asked for a surface that requires
  # auth.
  defp ensure_reachable(
         %{authenticated: true, path: path} = _config,
         configs,
         %Exchange{credentials: nil} = exchange,
         method_atom
       ) do
    case Enum.find(configs, &(&1.authenticated == false and &1.path == path)) do
      %{} = public_twin ->
        {:ok, public_twin}

      nil ->
        {:error,
         Error.authentication_error(
           exchange: exchange.id,
           message:
             "#{js_name_for!(method_atom)} on #{exchange.id} resolves to authenticated endpoint " <>
               "#{path}; credentials required"
         )}
    end
  end

  defp ensure_reachable(config, _configs, _exchange, _method_atom), do: {:ok, config}

  # Market-type / default-family inference. Explicit type/subType/symbol wins;
  # otherwise the authored venue `default_family` supplies the fall-through
  # family. Returns nil when nothing authored can resolve the choice, and the
  # caller fails loudly.
  defp infer_endpoint(configs, exchange, params, opts) do
    case infer_market_type(params, opts) do
      nil ->
        case exchange.default_family do
          nil -> nil
          family -> pick_config_for_market_type(configs, normalize_market_type(family))
        end

      market_type ->
        pick_config_for_market_type(configs, market_type)
    end
  end

  # Nothing reachable without credentials: every config for the method is
  # authenticated. Loud auth error, not a crash on hd([]).
  defp unresolved_multi_endpoint([], %Exchange{id: id}, method_atom) do
    {:error,
     Error.authentication_error(
       exchange: id,
       message: "#{js_name_for!(method_atom)} on #{id} has only authenticated endpoints; credentials required"
     )}
  end

  defp unresolved_multi_endpoint([only], _exchange, _method_atom), do: {:ok, only}

  defp unresolved_multi_endpoint(configs, %Exchange{id: id} = exchange, method_atom) when id in @runtime_venues do
    js = js_name_for!(method_atom)
    hints = working_selection_hints(configs, exchange, method_atom)

    resolution =
      case hints do
        [] -> "no documented type/subType/symbol parameter set resolves these endpoints"
        hints -> "pass #{Enum.join(hints, " or ")}"
      end

    {:error,
     Error.bad_request(
       exchange: id,
       message:
         "ambiguous multi-endpoint selection for #{js} on #{id}: " <>
           "author config.default_family and/or endpoints.request.endpoint_selection, " <>
           resolution <> " (refusing bare hd(configs))"
     )}
  end

  defp working_selection_hints(configs, exchange, method_atom) do
    Enum.flat_map(@endpoint_selection_param_sets, fn {label, params} ->
      case selected_config(configs, configs, exchange, method_atom, params, []) do
        %{} -> [label]
        nil -> []
      end
    end)
  end

  defp authored_endpoint(%Exchange{endpoint_selection: selections} = exchange, method_atom, configs, params, opts) do
    selection = Map.get(selections, js_name_for!(method_atom))
    context = selection_context(params, opts, exchange)

    selection
    |> selection_target(context, params)
    |> then(fn target -> Enum.find(configs, &endpoint_target?(&1, target)) end)
  end

  # Some venue method choices are part of the authored `describe().options`
  # contract. They are defaults only: an authored endpoint-selection rule may
  # select a conditional endpoint before this fallback applies.
  # `options.<jsName>` is not uniformly a map — okx's `createOrder` is a bare
  # method-name string — so match the map shape rather than `get_in/2`-ing a
  # "method" key out of whatever is there (raises on a binary).
  defp configured_endpoint(%Exchange{id: "hyperliquid"}, :create_order, configs) do
    Enum.find(configs, & &1.authenticated)
  end

  defp configured_endpoint(%Exchange{id: "okx", spec: spec}, method_atom, configs) do
    with js_name when is_binary(js_name) <- js_name_for!(method_atom),
         %{"method" => method} when is_binary(method) <- get_in(spec, ["options", js_name]) do
      underscored = Macro.underscore(method)
      Enum.find(configs, &(Atom.to_string(&1.name) == underscored))
    else
      _ -> nil
    end
  end

  # Hyperliquid fetchCurrencies is a public `/info` `{type: spotMeta}` probe.
  # The unified list also carries privatePostExchange first (signing envelope
  # surface); prefer the public row so we never ask the L1 signer for an action.
  defp configured_endpoint(%Exchange{id: "hyperliquid"}, :fetch_currencies, configs) do
    Enum.find(configs, &(&1.authenticated == false))
  end

  defp configured_endpoint(_exchange, _method_atom, _configs), do: nil

  # Deribit-style authored `cases`: conditions match raw params, with
  # "present"/"absent" sentinels, and select by endpoint path.
  defp selection_target(%{"cases" => cases} = selection, _context, params) when is_list(cases) do
    Enum.find_value(cases, Map.get(selection, "default"), fn authored_case ->
      if case_conditions_match?(params, Map.get(authored_case, "when", %{})), do: Map.get(authored_case, "path")
    end)
  end

  # Binance-family authored `rules`: conditions match the derived selection
  # context (params + market_type + market_family) and select by endpoint
  # path or name.
  defp selection_target(%{"rules" => rules, "default" => default}, context, _params) when is_list(rules) do
    Enum.find_value(rules, default, fn
      %{"when" => conditions, "endpoint" => endpoint} when is_map(conditions) ->
        if selection_conditions_match?(conditions, context), do: endpoint

      _ ->
        nil
    end)
  end

  defp selection_target(%{"by_market_type" => choices, "default" => default}, context, _params) when is_map(choices) do
    Map.get(choices, context["market_type"] || "spot", default)
  end

  defp selection_target(%{"default" => target}, _context, _params) when is_binary(target), do: target
  defp selection_target(_selection, _context, _params), do: nil

  defp case_conditions_match?(params, conditions) when is_map(conditions) do
    Enum.all?(conditions, fn
      {key, "present"} -> not is_nil(Map.get(params, key))
      {key, "absent"} -> is_nil(Map.get(params, key))
      {key, expected} -> Map.get(params, key) == expected
    end)
  end

  defp selection_conditions_match?(conditions, context) do
    Enum.all?(conditions, fn
      {key, "present"} -> not is_nil(context[key])
      {key, "absent"} -> is_nil(context[key])
      {key, value} -> selection_value_matches?(context[key], value)
    end)
  end

  defp selection_value_matches?(actual, expected) when is_atom(actual) and is_binary(expected),
    do: Atom.to_string(actual) == expected

  defp selection_value_matches?(actual, expected) when is_binary(actual) and is_atom(expected),
    do: actual == Atom.to_string(expected)

  defp selection_value_matches?(actual, expected), do: actual == expected

  defp selection_context(params, opts, exchange) do
    market_type = infer_market_type(params, opts)
    market_family = infer_market_family(params, market_type) || exchange.default_family

    params
    |> Map.put("market_type", market_type && Atom.to_string(market_type))
    |> Map.put("market_family", market_family)
    |> Map.put("symbol_has_slash", symbol_has_slash?(selection_symbol(params)))
    |> Map.put("default_type", get_in(exchange.options, ["fetchBalance", "defaultType"]))
    |> Map.put("unified_margin_status", exchange.options["unifiedMarginStatus"])
  end

  defp symbol_has_slash?(symbol) when is_binary(symbol), do: String.contains?(symbol, "/")
  defp symbol_has_slash?(_symbol), do: false

  defp infer_market_family(%{"subType" => family}, _market_type) when family in ["linear", "inverse"], do: family
  defp infer_market_family(%{"sub_type" => family}, _market_type) when family in ["linear", "inverse"], do: family

  defp infer_market_family(%{"type" => family}, _market_type) when family in ["spot", "linear", "inverse", "option"],
    do: family

  defp infer_market_family(params, market_type) when is_map(params) do
    case selection_symbol(params) do
      symbol when is_binary(symbol) -> family_from_symbol(symbol)
      _ -> market_type && Atom.to_string(market_type)
    end
  end

  defp infer_market_family(_params, nil), do: nil
  defp infer_market_family(_params, market_type) when is_atom(market_type), do: Atom.to_string(market_type)

  defp family_from_symbol(symbol) do
    case Symbol.parse_extended(symbol) do
      {:ok, %{settle: settle, base: base} = parsed} when is_binary(settle) ->
        cond do
          Symbol.detect_market_type(parsed) == :option -> "option"
          String.upcase(settle) == String.upcase(base) -> "inverse"
          true -> "linear"
        end

      {:ok, parsed} ->
        parsed |> Symbol.detect_market_type() |> Atom.to_string()

      _ ->
        nil
    end
  end

  defp endpoint_target?(config, target) when is_binary(target) do
    config.path == target or Atom.to_string(config.name) == target
  end

  defp endpoint_target?(_config, _target), do: false

  defp drop_endpoint_selector_params(params, _exchange, _capability_name) when is_list(params), do: params

  defp drop_endpoint_selector_params(params, %Exchange{endpoint_selection: selections}, capability_name)
       when is_map(params) do
    case get_in(selections, [capability_name, "consume"]) do
      keys when is_list(keys) -> Map.drop(params, keys)
      _ -> params
    end
  end

  defp infer_market_type(params, opts) do
    cond do
      mt = opts[:market_type] ->
        normalize_market_type(mt)

      type = params["type"] || params["category"] ->
        normalize_market_type(type)

      symbol = selection_symbol(params) ->
        case Symbol.parse_extended(symbol) do
          {:ok, parsed} -> Symbol.detect_market_type(parsed)
          _ -> :spot
        end

      true ->
        nil
    end
  end

  defp selection_symbol(%{"symbol" => symbol}) when is_binary(symbol), do: symbol
  defp selection_symbol(%{"symbols" => [symbol | _]}) when is_binary(symbol), do: symbol
  defp selection_symbol(_params), do: nil

  defp normalize_market_type(type) when type in [:spot, :swap, :future, :option], do: type
  defp normalize_market_type(:linear), do: :swap
  defp normalize_market_type(type) when type in [:inverse, :delivery], do: :future

  defp normalize_market_type("spot"), do: :spot
  defp normalize_market_type("swap"), do: :swap
  defp normalize_market_type("future"), do: :future
  defp normalize_market_type("option"), do: :option
  defp normalize_market_type("linear"), do: :swap
  defp normalize_market_type("inverse"), do: :future
  defp normalize_market_type("delivery"), do: :future
  defp normalize_market_type(_), do: :spot

  defp pick_config_for_market_type(configs, market_type) do
    market_type
    |> sections_for_market_type()
    |> Enum.find_value(fn section ->
      Enum.find(configs, fn
        %{sections: [^section | _]} -> true
        _ -> false
      end)
    end)
  end

  defp sections_for_market_type(:spot), do: @spot_sections
  defp sections_for_market_type(:swap), do: @swap_sections
  defp sections_for_market_type(:future), do: @future_sections
  defp sections_for_market_type(:option), do: @option_sections
end
