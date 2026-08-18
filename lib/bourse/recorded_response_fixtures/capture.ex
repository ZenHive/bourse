defmodule Bourse.RecordedResponseFixtures.Capture do
  @moduledoc """
  Live capture profiles for the committed real-response corpus.

  Public reads use venue production hosts. Account-scoped reads use only the
  provisioned testnet or demo environments named by each profile. Error probes
  deliberately trigger safely-recordable business rejections (unknown symbol,
  invalid credentials/signature, order-not-found, insufficient funds where no
  fill is possible) and freeze the scrubbed raw error body. Every body is
  scrubbed before it leaves this module.
  """

  alias Bourse.Credentials
  alias Bourse.Dispatch
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.RecordedResponseFixtures.LighterMarket
  alias Bourse.Registry
  alias Bourse.Telemetry
  alias Bourse.Unified

  @mask "***REDACTED***"
  @ohlcv_timeframe "1m"
  @history_limit 10
  @lighter_auth_lifetime_seconds 300
  @derive_subaccount_id 144_422
  @alpaca_order_amount 1
  @alpaca_order_price_ratio 0.01
  @bybit_order_amount 0.001
  @binance_order_amount 0.001
  @binance_coinm_order_amount 1
  @binance_usdm_order_amount 0.002
  @bybit_order_price_ratio 0.5
  @binance_order_price_ratio 0.8
  @order_price_decimal_places 0
  @unfillable_balance_multiple 100
  @invalid_api_key "invalid-key-not-real"
  @invalid_api_secret "invalid-secret-not-real-0123456789abcdef"
  @invalid_okx_secret "0123456789abcdef0123456789abcdef"
  @invalid_okx_passphrase "invalid-passphrase"
  @unknown_symbol "THISISNOTAREALSYMBOLXYZ"
  @lighter_private_history_methods [
    :fetch_deposits,
    :fetch_my_liquidations,
    :fetch_my_trades,
    :fetch_transfers,
    :fetch_withdrawals
  ]
  @error_mutation_safety %{
    "deliberately_invalid_params" => true,
    "key_mutation" => false,
    "paramless_persistent_mutation" => false,
    "transfer" => false,
    "valid_order" => false,
    "withdrawal" => false
  }
  @param_injections %{
    {"lighter", :fetch_closed_orders} => %{
      "exempt_params" => ~w(auth_deadline),
      "params" => ~w(auth_deadline),
      "reason" => "capture supplies a time-varying authenticated history deadline"
    },
    {"lighter", :fetch_deposits} => %{
      "exempt_params" => ~w(auth_deadline),
      "params" => ~w(auth_deadline),
      "reason" => "capture supplies a time-varying authenticated history deadline"
    },
    {"lighter", :fetch_my_liquidations} => %{
      "exempt_params" => ~w(auth_deadline),
      "params" => ~w(auth_deadline),
      "reason" => "capture supplies a time-varying authenticated history deadline"
    },
    {"lighter", :fetch_my_trades} => %{
      "exempt_params" => ~w(auth_deadline),
      "params" => ~w(auth_deadline),
      "reason" => "capture supplies a time-varying authenticated history deadline"
    },
    {"lighter", :fetch_open_orders} => %{
      "exempt_params" => ~w(auth_deadline),
      "params" => ~w(auth_deadline),
      "reason" => "capture supplies a time-varying authenticated history deadline"
    },
    {"lighter", :fetch_transfers} => %{
      "exempt_params" => ~w(auth_deadline),
      "params" => ~w(auth_deadline),
      "reason" => "capture supplies a time-varying authenticated history deadline"
    },
    {"lighter", :fetch_withdrawals} => %{
      "exempt_params" => ~w(auth_deadline),
      "params" => ~w(auth_deadline),
      "reason" => "capture supplies a time-varying authenticated history deadline"
    }
  }

  # lighter ask/bid_account_id stay unmasked: they carry no credential material
  # (the testnet account index is already plaintext in caller_params of every
  # private lighter recording), and masking them kills the only offline evidence
  # for the trade role/fee derivation in ReadParse.annotate_lighter_trade/2.
  @sensitive_keys MapSet.new(~w(
    address accountnumber apikey apisecret key password passphrase secret sig signature signer uid
    user userid wallet walletaddress accountid accountalias subaccountid withdrawaladdress
    depositaddress l1address froml1address tol1address fromaccountindex toaccountindex
    email username systemname referrerid memberid
  ))

  defp public_profiles do
    %{
      {"alpaca", :fetch_ticker} =>
        public("v2/stocks/{symbol}/snapshot", "data.alpaca.markets", "GLD", credential_profile: :alpaca),
      {"binance", :fetch_markets} => public("api/v3|fapi/v1|dapi/v1|eapi/v1/exchangeInfo", "api.binance.com", "BTC/USDT"),
      {"binance", :fetch_ticker} => public("api/v3/ticker/24hr", "api.binance.com", "BTC/USDT"),
      {"binance", :fetch_trades} => public("api/v3/trades", "api.binance.com", "BTC/USDT"),
      {"binance", :fetch_ohlcv} => public("api/v3/klines", "api.binance.com", "BTC/USDT", call_opts: [endpoint_index: 9]),
      {"binance", :fetch_bids_asks} => public("api/v3/ticker/bookTicker", "api.binance.com", nil),
      {"binance", :fetch_last_prices} =>
        public("api/v3/ticker/price", "testnet.binance.vision", nil,
          environment: "testnet-demo",
          exchange_opts: [sandbox: true]
        ),
      {"binance", :fetch_leverage_tiers} =>
        private("fapi/v1/leverageBracket", "demo-fapi.binance.com", :binanceusdm, %{}),
      {"binanceusdm", :fetch_ticker} => public("fapi/v1/ticker/price", "fapi.binance.com", "BTC/USDT:USDT"),
      {"binanceusdm", :fetch_trades} => public("fapi/v1/aggTrades", "fapi.binance.com", "BTC/USDT:USDT"),
      {"binanceusdm", :fetch_ohlcv} =>
        public("fapi/v1/klines", "fapi.binance.com", "BTC/USDT:USDT", call_opts: [endpoint_index: 6]),
      {"binanceusdm", :fetch_funding_intervals} =>
        public("fapi/v1/fundingInfo", "demo-fapi.binance.com", nil,
          environment: "testnet-demo",
          exchange_opts: [sandbox: true]
        ),
      {"binanceusdm", :fetch_last_prices} =>
        public("fapi/v1/ticker/price", "demo-fapi.binance.com", nil,
          environment: "testnet-demo",
          exchange_opts: [sandbox: true]
        ),
      {"binanceusdm", :fetch_leverage_tiers} => binance_usdm("fapi/v1/leverageBracket", %{}),
      {"binanceusdm", :fetch_margin_modes} => binance_usdm("fapi/v1/symbolConfig", %{}),
      {"binancecoinm", :fetch_markets} => public("dapi/v1/exchangeInfo", "dapi.binance.com", "BTC/USD:BTC"),
      {"binancecoinm", :fetch_ticker} =>
        public("dapi/v1/ticker/price", "dapi.binance.com", "BTC/USD:BTC", params: %{"symbol" => "BTCUSD_PERP"}),
      {"binancecoinm", :fetch_open_interest} =>
        public("dapi/v1/openInterest", "demo-dapi.binance.com", "BTC/USD:BTC",
          environment: "testnet-demo",
          exchange_opts: [sandbox: true],
          params: %{"symbol" => "BTC/USD:BTC"}
        ),
      {"binanceusdm", :fetch_markets} => public("fapi/v1/exchangeInfo", "fapi.binance.com", "BTC/USDT:USDT"),
      {"bybit", :fetch_ticker} => public("v5/market/tickers", "api.bybit.com", "BTC/USDT:USDT"),
      {"bybit", :fetch_trades} => public("v5/market/recent-trade", "api.bybit.com", "BTC/USDT:USDT"),
      {"bybit", :fetch_markets} => public("v5/market/instruments-info", "api.bybit.com", "BTC/USDT:USDT"),
      {"coinbaseexchange", :fetch_ticker} => public("products/{id}/ticker", "api.exchange.coinbase.com", "ETH-USD"),
      {"coinbaseexchange", :fetch_ohlcv} => public("products/{id}/candles", "api.exchange.coinbase.com", "ETH-USD"),
      {"bybit", :fetch_leverage_tiers} =>
        public("v5/market/risk-limit", "api-testnet.bybit.com", nil,
          environment: "testnet-demo",
          exchange_opts: [sandbox: true],
          params: %{"category" => "linear"}
        ),
      {"deribit", :fetch_ticker} => public("public/ticker", "www.deribit.com", "BTC-PERPETUAL"),
      {"deribit", :fetch_trades} => public("public/get_last_trades_by_instrument", "www.deribit.com", "BTC-PERPETUAL"),
      {"deribit", :fetch_markets} => public("public/get_instruments", "www.deribit.com", "BTC-PERPETUAL"),
      {"deribit", :fetch_funding_rate} => public("public/get_funding_rate_value", "www.deribit.com", "BTC/USD:BTC"),
      {"okx", :fetch_ticker} => public("api/v5/market/ticker", "www.okx.com", "BTC/USDT"),
      {"okx", :fetch_trades} => public("api/v5/market/trades", "www.okx.com", "BTC/USDT"),
      {"okx", :fetch_markets} => public("api/v5/public/instruments", "www.okx.com", "BTC/USDT"),
      {"okx", :fetch_funding_rate_history} =>
        public("api/v5/public/funding-rate-history", "www.okx.com", "BTC/USDT:USDT",
          params: %{"limit" => 3, "symbol" => "BTC/USDT:USDT"}
        ),
      {"okx", :fetch_open_interests} =>
        public("api/v5/public/open-interest", "www.okx.com", nil, params: %{"instType" => "SWAP"}),
      {"okx", :fetch_markets_by_type} =>
        public("api/v5/public/instruments", "www.okx.com", nil,
          environment: "testnet-demo",
          exchange_opts: [sandbox: true],
          params: %{"type" => "SWAP"}
        ),
      {"hyperliquid", :fetch_ohlcv} =>
        public("info:candleSnapshot", "api.hyperliquid.xyz", "BTC/USDC",
          params: %{"timeframe" => @ohlcv_timeframe, "since" => 0}
        ),
      {"hyperliquid", :fetch_markets} => public("info:meta", "api.hyperliquid.xyz", "BTC/USDC:USDC"),
      {"hyperliquid", :fetch_open_interests} =>
        public("info:metaAndAssetCtxs", "api.hyperliquid-testnet.xyz", nil,
          environment: "testnet-demo",
          exchange_opts: [sandbox: true]
        ),
      {"derive", :fetch_trades} => public("public/get_trade_history", "api.lyra.finance", "BTC/USDC"),
      {"derive", :fetch_markets} => public("public/get_all_instruments", "api.lyra.finance", "BTC/USDC"),
      {"lighter", :fetch_markets} =>
        public("orderBookDetails", "testnet.zklighter.elliot.ai", "ETH/USDC:USDC",
          environment: "testnet-demo",
          exchange_opts: [sandbox: true]
        ),
      {"lighter", :fetch_ticker} =>
        public("orderBookDetails", "testnet.zklighter.elliot.ai", "ETH/USDC:USDC",
          environment: "testnet-demo",
          exchange_opts: [sandbox: true],
          load_markets?: true
        ),
      {"lighter", :fetch_funding_rate_history} =>
        public("fundings", "testnet.zklighter.elliot.ai", "BTC/USDC:USDC",
          environment: "testnet-demo",
          exchange_opts: [sandbox: true],
          load_markets?: true,
          params: %{"limit" => @history_limit, "symbol" => "BTC/USDC:USDC"}
        )
    }
  end

  defp private_profiles do
    %{
      {"alpaca", :fetch_markets} =>
        private("v2/assets", "paper-api.alpaca.markets", :alpaca, %{},
          param_variants: [%{"asset_class" => "us_equity"}, %{"asset_class" => "crypto"}]
        ),
      {"alpaca", :fetch_balance} => private("v2/account", "paper-api.alpaca.markets", :alpaca, %{}),
      {"alpaca", :fetch_time} => private("v2/clock", "paper-api.alpaca.markets", :alpaca, %{}),
      {"alpaca", :fetch_open_orders} => private("v2/orders", "paper-api.alpaca.markets", :alpaca, %{}),
      {"alpaca", :fetch_positions} => private("v2/positions", "paper-api.alpaca.markets", :alpaca, %{}),
      {"deribit", :fetch_balance} => private("private/get_account_summaries", "test.deribit.com", :deribit, %{}),
      {"deribit", :fetch_open_orders} =>
        private("private/get_open_orders_by_instrument", "test.deribit.com", :deribit, %{
          "symbol" => "BTC/USD:BTC"
        }),
      {"deribit", :fetch_positions} =>
        private("private/get_positions", "test.deribit.com", :deribit, %{},
          load_markets?: true,
          market_context_ids: ["BTC-PERPETUAL", "ETH_USDC-PERPETUAL"],
          oracle_membership: ["tier1_semantic_oracle", "deribit_position_units"]
        ),
      {"deribit", :fetch_my_trades} =>
        private("private/get_user_trades_by_instrument", "test.deribit.com", :deribit, %{
          "symbol" => "BTC/USD:BTC",
          "limit" => @history_limit
        }),
      {"deribit", :fetch_deposit_address} =>
        private("private/get_current_deposit_address", "test.deribit.com", :deribit, %{"code" => "BTC"}),
      {"deribit", :fetch_trading_fees} => private("private/get_account_summary", "test.deribit.com", :deribit, %{}),
      # Canonical OKX capture host: www.okx.com international demo with OKX_INTL_*
      # credentials. The frozen my.okx.com EEA recordings replay from their own fixture
      # metadata and stay valid provenance; they are not re-capturable from here.
      {"okx", :fetch_balance} => private("api/v5/account/balance", "www.okx.com", :okx, %{}),
      {"okx", :account_subtypes} =>
        private("api/v5/account/subtypes", "www.okx.com", :okx, %{}, raw_endpoint: :private_get_account_subtypes),
      {"okx", :fetch_open_orders} =>
        private("api/v5/trade/orders-pending", "www.okx.com", :okx, %{"symbol" => "BTC/USDT"}),
      {"okx", :fetch_positions} =>
        private("api/v5/account/positions", "www.okx.com", :okx, %{"symbols" => ["BTC/USDT:USDT"]}),
      {"okx", :fetch_positions_for_symbol} =>
        private("api/v5/account/positions", "www.okx.com", :okx, %{"symbol" => "BTC/USDT:USDT"}),
      {"okx", :fetch_my_trades} =>
        private("api/v5/trade/fills", "www.okx.com", :okx, %{
          "symbol" => "BTC/USDT",
          "limit" => @history_limit
        }),
      {"bybit", :fetch_balance} => bybit_demo("v5/account/wallet-balance", %{}),
      {"bybit", :fetch_open_orders} => bybit_demo("v5/order/realtime", %{"symbol" => "BTC/USDT:USDT"}),
      {"bybit", :fetch_positions} => bybit_demo("v5/position/list", %{"symbols" => ["BTC/USDT:USDT"]}),
      {"bybit", :fetch_my_trades} =>
        bybit_demo("v5/execution/list", %{"symbol" => "BTC/USDT:USDT", "limit" => @history_limit}),
      {"binance", :fetch_balance} => binance_spot("api/v3/account", %{}),
      {"binance", :fetch_open_orders} => binance_spot("api/v3/openOrders", %{"symbol" => "BTC/USDT"}),
      {"binance", :fetch_my_trades} =>
        binance_spot("api/v3/myTrades", %{"symbol" => "BTC/USDT", "limit" => @history_limit}),
      {"binanceusdm", :fetch_balance} => binance_usdm("fapi/v3/account", %{}),
      {"binanceusdm", :fetch_account_positions} => binance_usdm("fapi/v3/account", %{}),
      {"binanceusdm", :fetch_leverages} =>
        binance_usdm("fapi/v1/symbolConfig", %{"symbol" => "ETH/USDT:USDT"}, load_markets?: true),
      {"binanceusdm", :fetch_open_orders} => binance_usdm("fapi/v1/openOrders", %{"symbol" => "BTC/USDT:USDT"}),
      {"binanceusdm", :fetch_positions} => binance_usdm("fapi/v3/positionRisk", %{"symbols" => ["BTC/USDT:USDT"]}),
      {"binanceusdm", :fetch_positions_risk} => binance_usdm("fapi/v3/positionRisk", %{}),
      {"binanceusdm", :fetch_my_trades} =>
        binance_usdm("fapi/v1/userTrades", %{"symbol" => "BTC/USDT:USDT", "limit" => @history_limit}),
      {"binanceusdm", :fetch_ledger} => binance_usdm("fapi/v1/income", %{"limit" => @history_limit}),
      {"binanceusdm", :fetch_position_adl_rank} => binance_usdm("fapi/v1/adlQuantile", %{"symbol" => "BTC/USDT:USDT"}),
      {"binancecoinm", :fetch_balance} => binance_coinm("dapi/v1/account", %{}),
      {"binancecoinm", :fetch_leverages} =>
        binance_coinm("dapi/v1/account", %{"symbol" => "BTC/USD:BTC"}, load_markets?: true),
      {"binancecoinm", :fetch_open_orders} =>
        binance_coinm("dapi/v1/openOrders", %{"symbol" => "BTCUSD_PERP"}, symbol: "BTC/USD:BTC"),
      {"binancecoinm", :fetch_orders} =>
        binance_coinm("dapi/v1/allOrders", %{"symbol" => "BTC/USD:BTC", "limit" => @history_limit}),
      {"binancecoinm", :fetch_closed_orders} =>
        binance_coinm("dapi/v1/allOrders", %{"symbol" => "BTC/USD:BTC", "limit" => @history_limit}),
      {"binancecoinm", :fetch_canceled_orders} =>
        binance_coinm("dapi/v1/allOrders", %{"symbol" => "BTC/USD:BTC", "limit" => @history_limit}),
      {"binancecoinm", :fetch_leverage_tiers} => binance_coinm("dapi/v2/leverageBracket", %{"symbol" => "BTC/USD:BTC"}),
      {"binancecoinm", :fetch_trading_fee} => binance_coinm("dapi/v1/commissionRate", %{"symbol" => "BTC/USD:BTC"}),
      {"binancecoinm", :fetch_ledger} => binance_coinm("dapi/v1/income", %{"limit" => @history_limit}),
      {"binancecoinm", :fetch_adl_rank} => binance_coinm("dapi/v1/adlQuantile", %{"symbol" => "BTC/USD:BTC"}),
      {"binancecoinm", :fetch_positions} => binance_coinm("dapi/v1/positionRisk", %{"symbols" => ["BTC/USD:BTC"]}),
      {"binancecoinm", :fetch_my_trades} =>
        binance_coinm("dapi/v1/userTrades", %{"symbol" => "BTCUSD_PERP", "limit" => @history_limit},
          symbol: "BTC/USD:BTC"
        ),
      {"hyperliquid", :fetch_balance} => hyperliquid("info:clearinghouseState", %{}),
      {"hyperliquid", :fetch_open_orders} => hyperliquid("info:openOrders", %{"symbol" => "BTC/USDC:USDC"}),
      {"hyperliquid", :fetch_positions} => hyperliquid("info:clearinghouseState", %{}),
      {"hyperliquid", :fetch_my_trades} =>
        hyperliquid("info:userFills", %{"symbol" => "BTC/USDC:USDC", "limit" => @history_limit}),
      {"derive", :fetch_balance} => derive("private/get_all_portfolios", %{}),
      {"derive", :fetch_open_orders} => derive("private/get_orders", %{}),
      {"derive", :fetch_positions} => derive("private/get_positions", %{}),
      {"derive", :fetch_my_trades} => derive("private/get_trade_history", %{"limit" => @history_limit}),
      {"derive", :fetch_canceled_orders} => derive("private/get_orders", %{}),
      {"lighter", :fetch_closed_orders} =>
        lighter("accountInactiveOrders", %{}, load_markets?: true, symbol: "ETH/USDC:USDC"),
      {"lighter", :fetch_open_orders} =>
        lighter("accountActiveOrders", %{}, load_markets?: true, symbol: "ETH/USDC:USDC"),
      {"lighter", :fetch_balance} => lighter("account", %{}, []),
      {"lighter", :fetch_positions} => lighter("account", %{}, load_markets?: true),
      {"lighter", :fetch_my_trades} => lighter("trades", %{}, load_markets?: true),
      {"lighter", :fetch_deposits} => lighter("deposit_history", %{}, []),
      {"lighter", :fetch_withdrawals} => lighter("withdraw_history", %{}, []),
      {"lighter", :fetch_transfers} => lighter("transfer_history", %{}, []),
      {"lighter", :fetch_my_liquidations} => lighter("liquidations", %{}, load_markets?: true)
    }
  end

  defp write_profiles do
    %{
      {"alpaca", :order_lifecycle} =>
        "v2/orders create -> fetch -> cancel"
        |> private("paper-api.alpaca.markets", :alpaca, %{})
        |> order_lifecycle(
          "GLD",
          @alpaca_order_amount,
          @alpaca_order_price_ratio,
          :fetch_order,
          ["id"],
          %{"extended_hours" => false, "time_in_force" => "day"}
        ),
      {"bybit", :order_lifecycle} =>
        "v5/order/create -> v5/order/realtime -> v5/order/cancel"
        |> bybit_demo(%{})
        |> order_lifecycle(
          "BTC/USDT:USDT",
          @bybit_order_amount,
          @bybit_order_price_ratio,
          :fetch_open_orders,
          ["result", "orderId"],
          %{"postOnly" => true}
        ),
      {"binance", :order_lifecycle} =>
        "api/v3/order create -> query -> cancel"
        |> binance_spot(%{})
        |> order_lifecycle(
          "BTC/USDT",
          @binance_order_amount,
          @binance_order_price_ratio,
          :fetch_order,
          ["orderId"],
          %{"newOrderRespType" => "ACK", "timeInForce" => "GTC"}
        ),
      {"binanceusdm", :order_lifecycle} =>
        "fapi/v1/order create -> query -> cancel"
        |> binance_usdm(%{})
        |> order_lifecycle(
          "BTC/USDT:USDT",
          @binance_usdm_order_amount,
          @binance_order_price_ratio,
          :fetch_order,
          ["orderId"],
          %{"timeInForce" => "GTC"}
        ),
      {"binancecoinm", :order_lifecycle} =>
        "dapi/v1/order create -> query -> cancel"
        |> binance_coinm(%{})
        |> order_lifecycle(
          "BTCUSD_PERP",
          @binance_coinm_order_amount,
          @bybit_order_price_ratio,
          :fetch_order,
          ["orderId"],
          %{"positionSide" => "LONG", "timeInForce" => "GTC"}
        )
    }
  end

  # Error probes deliberately request business rejections. Mutating endpoints use
  # only invalid/unfillable params — never a resting valid order, withdraw, transfer,
  # or key-change. Invalid-signature probes sign with garbage credentials (not env).
  defp error_profiles do
    %{
      {"coinbaseexchange", :error_bad_granularity} =>
        error_public(
          "products/{id}/candles",
          "api.exchange.coinbase.com",
          :fetch_ohlcv,
          %{"id" => "ETH-USD", "granularity" => 61},
          error_kind: "bad_granularity",
          expected_types: [:bad_request],
          raw_endpoint: :public_get_products__id__candles
        ),
      {"alpaca", :error_bad_symbol} =>
        error_probe("v2/stocks/{symbol}/snapshot", "paper-api.alpaca.markets", :alpaca, :fetch_ticker, %{
          "symbol" => "NOTAREAL"
        }),
      {"alpaca", :error_invalid_signature} =>
        error_invalid_creds("v2/account", "paper-api.alpaca.markets", :alpaca, :fetch_balance, %{}),
      {"binance", :error_bad_symbol} =>
        error_public("api/v3/ticker/24hr", "api.binance.com", :fetch_ticker, %{"symbol" => @unknown_symbol}),
      {"binance", :error_invalid_signature} =>
        error_invalid_creds("api/v3/account", "testnet.binance.vision", :binance, :fetch_balance, %{}),
      {"binance", :error_insufficient_funds} =>
        error_insufficient_funds(
          "api/v3/order",
          "testnet.binance.vision",
          :binance,
          "BTC/USDT",
          100,
          %{"newOrderRespType" => "ACK", "type" => "market"}
        ),
      {"binancecoinm", :error_bad_symbol} =>
        error_public(
          "dapi/v1/ticker/price",
          "demo-dapi.binance.com",
          :fetch_ticker,
          %{
            "symbol" => @unknown_symbol
          },
          environment: "testnet-demo",
          exchange_opts: [sandbox: true]
        ),
      {"binancecoinm", :error_invalid_signature} =>
        error_invalid_creds(
          "dapi/v1/account",
          "demo-dapi.binance.com",
          :binanceusdm,
          :fetch_balance,
          %{},
          exchange_opts: [sandbox: true]
        ),
      {"binancecoinm", :error_position_mode_unchanged} =>
        "dapi/v1/positionSide/dual"
        |> error_probe("demo-dapi.binance.com", :binancecoinm, :set_position_mode, %{"hedge_mode" => false})
        |> Map.merge(%{
          error_kind: "position_mode_unchanged",
          expected_types: [:operation_failed],
          mutation_safety: Map.put(@error_mutation_safety, "error_kind", "position_mode_unchanged")
        }),
      {"binanceusdm", :error_bad_symbol} =>
        error_public(
          "fapi/v1/ticker/price",
          "demo-fapi.binance.com",
          :fetch_ticker,
          %{
            "symbol" => @unknown_symbol
          },
          environment: "testnet-demo",
          exchange_opts: [sandbox: true]
        ),
      {"binanceusdm", :error_invalid_signature} =>
        error_invalid_creds("fapi/v3/account", "demo-fapi.binance.com", :binanceusdm, :fetch_balance, %{}),
      {"bybit", :error_bad_symbol} =>
        error_public("v5/market/tickers", "api.bybit.com", :fetch_ticker, %{"symbol" => "NOTAREAL/USDT:USDT"}),
      {"bybit", :error_invalid_signature} =>
        error_invalid_creds("v5/account/wallet-balance", "api-demo.bybit.com", :bybit_demo, :fetch_balance, %{},
          call_opts: [base_url: "https://api-demo.bybit.com"]
        ),
      {"deribit", :error_bad_symbol} =>
        error_public("public/ticker", "www.deribit.com", :fetch_ticker, %{"symbol" => "BTC-NOTAREAL"}),
      {"deribit", :error_invalid_signature} =>
        error_invalid_creds("private/get_account_summaries", "test.deribit.com", :deribit, :fetch_balance, %{}),
      {"deribit", :error_trigger_price_too_low} =>
        "private/buy"
        |> error_probe("test.deribit.com", :deribit, :create_order, %{
          "amount" => 10,
          "side" => "buy",
          "symbol" => "BTC/USD:BTC",
          "trigger" => "index_price",
          "trigger_price" => 1,
          "type" => "stop_market"
        })
        |> Map.merge(%{
          error_kind: "trigger_price_too_low",
          expected_types: [:invalid_order],
          mutation_safety: Map.put(@error_mutation_safety, "error_kind", "trigger_price_too_low")
        }),
      {"derive", :error_invalid_signature} =>
        error_invalid_creds("private/get_all_portfolios", "api-demo.lyra.finance", :derive, :fetch_balance, %{},
          invalid_credentials: derive_invalid_credentials()
        ),
      {"hyperliquid", :error_order_not_found} =>
        "info:orderStatus"
        |> error_probe("api.hyperliquid-testnet.xyz", :hyperliquid, :fetch_order, %{
          "id" => "999999999",
          "symbol" => "BTC/USDC:USDC"
        })
        |> Map.merge(%{
          expected_types: [:order_not_found],
          load_markets?: true,
          mutation_safety: Map.put(@error_mutation_safety, "error_kind", "order_not_found")
        }),
      {"lighter", :error_bad_request} =>
        error_public("orderBookDetails", "testnet.zklighter.elliot.ai", :fetch_order_book, %{"market_id" => "99999"},
          call_opts: [],
          exchange_opts: [sandbox: true],
          expected_types: [:bad_request, :exchange_error],
          raw_endpoint: :public_get_orderbookdetails
        ),
      {"okx", :error_bad_symbol} =>
        error_public("api/v5/market/ticker", "www.okx.com", :fetch_ticker, %{"symbol" => @unknown_symbol}),
      {"okx", :error_invalid_signature} =>
        error_invalid_creds("api/v5/account/balance", "www.okx.com", :okx, :fetch_balance, %{})
    }
  end

  @type category :: :public | :private | :write | :error
  @type capture_option :: {atom(), term()}

  @doc "Returns every configured `{venue, method}` capture target."
  @spec targets() :: [{String.t(), atom()}]
  def targets, do: capture_profiles() |> Map.keys() |> Enum.sort()

  @doc "Returns the capture category for a configured target."
  @spec category(String.t(), atom()) :: category() | nil
  def category(exchange_id, method) do
    case Map.get(capture_profiles(), {exchange_id, method}) do
      nil -> nil
      profile -> profile.category
    end
  end

  @doc "Returns the environment variables required by one capture target."
  @spec required_credentials(String.t(), atom()) :: [String.t()] | nil
  def required_credentials(exchange_id, method) do
    case Map.get(capture_profiles(), {exchange_id, method}) do
      nil -> nil
      profile -> Enum.map(profile.credential_env, &elem(&1, 1))
    end
  end

  @doc "Returns stable oracle identity fields for a configured target."
  @spec oracle_identity(String.t(), atom()) :: map() | nil
  def oracle_identity(exchange_id, method) do
    case Map.get(capture_profiles(), {exchange_id, method}) do
      nil ->
        nil

      profile ->
        identity = %{
          "authenticated" => profile.authenticated,
          "endpoint" => profile.endpoint,
          "environment" => profile.environment,
          "host" => profile.host
        }

        identity
        |> maybe_put("mutation_safety", Map.get(profile, :mutation_safety))
        |> maybe_put("error_kind", Map.get(profile, :error_kind))
    end
  end

  @doc "Returns the exact reasoned registry of capture-only request-param injections."
  @spec param_injections() :: %{{String.t(), atom()} => %{String.t() => term()}}
  def param_injections, do: @param_injections

  @doc "Captures and scrubs one configured response fixture."
  @spec capture_fixture(String.t(), atom(), [capture_option()]) :: {:ok, map()} | {:error, term()}
  def capture_fixture(exchange_id, method, call_opts \\ []) when is_list(call_opts) do
    case Map.get(capture_profiles(), {exchange_id, method}) do
      nil ->
        {:error, {:no_capture_profile, exchange_id, method}}

      profile ->
        profile = Map.update!(profile, :call_opts, &Keyword.merge(&1, call_opts))

        with {:ok, credentials} <- credentials(profile),
             {:ok, exchange} <- build_exchange(exchange_id, profile, credentials) do
          capture_profile(exchange, exchange_id, method, profile, credentials)
        end
    end
  end

  @doc "Recursively masks credentials, signatures, account identifiers, and addresses."
  @spec scrub(term(), Credentials.t() | nil) :: term()
  def scrub(value, credentials \\ nil) do
    scrub_value(value, credential_values(credentials))
  end

  @doc "Returns corpus paths whose sensitive fields are not masked."
  @spec safety_violations(term()) :: [String.t()]
  def safety_violations(value), do: value |> find_safety_violations("$") |> Enum.sort()

  @doc "Root directory for committed real error recordings."
  @spec error_fixture_root() :: String.t()
  def error_fixture_root do
    __DIR__
    |> Path.join("../../../test/fixtures/recorded_errors")
    |> Path.expand()
  end

  @doc "Absolute path for one committed real error recording."
  @spec error_fixture_path(String.t(), atom()) :: String.t()
  def error_fixture_path(exchange_id, method) when is_binary(exchange_id) and is_atom(method) do
    Path.join([error_fixture_root(), exchange_id, "#{method}.json"])
  end

  defp capture_profiles do
    public_profiles()
    |> Map.merge(private_profiles())
    |> Map.merge(write_profiles())
    |> Map.merge(error_profiles())
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp public(endpoint, host, symbol, opts \\ []) do
    credential_profile = Keyword.get(opts, :credential_profile)

    %{
      authenticated: credential_profile != nil,
      call_opts: Keyword.get(opts, :call_opts, []),
      category: :public,
      credential_env: if(credential_profile, do: credential_env(credential_profile), else: []),
      endpoint: endpoint,
      environment: Keyword.get(opts, :environment, "production-public"),
      exchange_opts: Keyword.get(opts, :exchange_opts, []),
      host: host,
      load_markets?: Keyword.get(opts, :load_markets?, false),
      params: Keyword.get(opts, :params, %{}),
      symbol: symbol
    }
  end

  defp private(endpoint, host, credential_profile, params, opts \\ []) do
    %{
      authenticated: true,
      call_opts: Keyword.get(opts, :call_opts, []),
      category: :private,
      credential_env: credential_env(credential_profile),
      endpoint: endpoint,
      environment: "testnet-demo",
      exchange_opts: exchange_opts(credential_profile),
      host: host,
      load_markets?: Keyword.get(opts, :load_markets?, false),
      market_context_ids: Keyword.get(opts, :market_context_ids),
      oracle_membership: Keyword.get(opts, :oracle_membership),
      param_variants: Keyword.get(opts, :param_variants),
      params: params,
      raw_endpoint: Keyword.get(opts, :raw_endpoint),
      symbol: Keyword.get(opts, :symbol, Map.get(params, "symbol"))
    }
  end

  defp bybit_demo(endpoint, params) do
    endpoint
    |> private("api-demo.bybit.com", :bybit_demo, params)
    |> Map.put(:call_opts, base_url: "https://api-demo.bybit.com")
  end

  defp binance_spot(endpoint, params), do: private(endpoint, "testnet.binance.vision", :binance, params)

  defp binance_usdm(endpoint, params, opts \\ []),
    do: private(endpoint, "demo-fapi.binance.com", :binanceusdm, params, opts)

  defp binance_coinm(endpoint, params, opts \\ []),
    do: private(endpoint, "demo-dapi.binance.com", :binancecoinm, params, opts)

  defp hyperliquid(endpoint, params), do: private(endpoint, "api.hyperliquid-testnet.xyz", :hyperliquid, params)

  defp derive(endpoint, params), do: private(endpoint, "api-demo.lyra.finance", :derive, params)

  defp lighter(endpoint, params, opts), do: private(endpoint, "testnet.zklighter.elliot.ai", :lighter, params, opts)

  defp order_lifecycle(profile, symbol, amount, price_ratio, read_method, order_id_path, extra_params) do
    create_params =
      Map.merge(
        %{
          "amount" => amount,
          "side" => "buy",
          "symbol" => symbol,
          "type" => "limit"
        },
        extra_params
      )

    Map.merge(profile, %{
      category: :write,
      create_params: create_params,
      mutation_safety: %{
        "cleanup" => "cancel_order",
        "far_from_market" => true,
        "paramless_persistent_mutation" => false,
        "price_ratio" => price_ratio,
        "price_source" => "live_ticker_ratio"
      },
      order_id_path: order_id_path,
      params: create_params,
      price_ratio: price_ratio,
      read_method: read_method,
      symbol: symbol
    })
  end

  defp error_public(endpoint, host, call_method, params, opts \\ []) do
    error_kind = Keyword.get(opts, :error_kind, "bad_symbol")

    %{
      authenticated: false,
      call_method: call_method,
      call_opts: Keyword.get(opts, :call_opts, []),
      category: :error,
      credential_env: [],
      endpoint: endpoint,
      environment: Keyword.get(opts, :environment, "production-public"),
      error_kind: error_kind,
      exchange_opts: Keyword.get(opts, :exchange_opts, []),
      expected_types: Keyword.get(opts, :expected_types, [:bad_symbol, :bad_request, :exchange_error]),
      host: host,
      load_markets?: Keyword.get(opts, :load_markets?, false),
      mutation_safety: Map.put(@error_mutation_safety, "error_kind", error_kind),
      params: params,
      params_transform: Keyword.get(opts, :params_transform),
      raw_endpoint: Keyword.get(opts, :raw_endpoint),
      symbol: Map.get(params, "symbol")
    }
  end

  defp error_probe(endpoint, host, credential_profile, call_method, params) do
    %{
      authenticated: true,
      call_method: call_method,
      call_opts: [],
      category: :error,
      credential_env: credential_env(credential_profile),
      endpoint: endpoint,
      environment: "testnet-demo",
      error_kind: "business_error",
      exchange_opts: exchange_opts(credential_profile),
      expected_types: [:bad_symbol, :bad_request, :exchange_error, :authentication_error, :order_not_found],
      host: host,
      load_markets?: false,
      mutation_safety: Map.put(@error_mutation_safety, "error_kind", "business_error"),
      params: params,
      params_transform: nil,
      symbol: Map.get(params, "symbol")
    }
  end

  defp error_invalid_creds(endpoint, host, credential_profile, call_method, params, opts \\ []) do
    %{
      authenticated: true,
      call_method: call_method,
      call_opts: Keyword.get(opts, :call_opts, []),
      category: :error,
      credential_env: [],
      endpoint: endpoint,
      environment: "testnet-demo",
      error_kind: "invalid_signature",
      exchange_opts: Keyword.get(opts, :exchange_opts, exchange_opts(credential_profile)),
      expected_types: [
        :authentication_error,
        :permission_denied,
        :access_restricted,
        :exchange_error,
        :bad_request
      ],
      host: host,
      invalid_credentials: Keyword.get(opts, :invalid_credentials, invalid_credentials(credential_profile)),
      load_markets?: false,
      mutation_safety: Map.put(@error_mutation_safety, "error_kind", "invalid_signature"),
      params: params,
      params_transform: nil,
      symbol: Map.get(params, "symbol")
    }
  end

  defp error_insufficient_funds(endpoint, host, credential_profile, symbol, amount, extra_params) do
    # Market (or deliberately oversized) buy that the venue rejects before any fill —
    # never a resting valid limit. Expected classes include :invalid_order because some
    # venues label insufficient balance under that class while still returning the
    # provider's insufficient-balance code.
    params =
      Map.merge(
        %{
          "amount" => amount,
          "side" => "buy",
          "symbol" => symbol,
          "type" => "market"
        },
        extra_params
      )

    %{
      authenticated: true,
      call_method: :create_order,
      call_opts: [],
      category: :error,
      credential_env: credential_env(credential_profile),
      endpoint: endpoint,
      environment: "testnet-demo",
      error_kind: "insufficient_funds",
      exchange_opts: exchange_opts(credential_profile),
      expected_types: [:insufficient_funds, :invalid_order, :bad_request, :exchange_error],
      host: host,
      load_markets?: false,
      mutation_safety:
        @error_mutation_safety
        |> Map.put("error_kind", "insufficient_funds")
        |> Map.put("unfillable_amount", true),
      params: params,
      params_transform: nil,
      quote: "USDT",
      symbol: symbol
    }
  end

  defp invalid_credentials(:okx) do
    Credentials.new!(
      api_key: @invalid_api_key,
      secret: @invalid_okx_secret,
      password: @invalid_okx_passphrase
    )
  end

  defp invalid_credentials(:alpaca) do
    Credentials.new!(api_key: @invalid_api_key, secret: @invalid_api_secret)
  end

  defp invalid_credentials(_profile) do
    Credentials.new!(api_key: @invalid_api_key, secret: @invalid_api_secret)
  end

  defp derive_invalid_credentials do
    Credentials.new!(
      api_key: "0x0000000000000000000000000000000000000001",
      secret: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
  end

  defp credential_env(:deribit), do: [api_key: "DERIBIT_TESTNET_API_KEY", secret: "DERIBIT_TESTNET_API_SECRET"]

  defp credential_env(:okx),
    do: [api_key: "OKX_INTL_API_KEY", secret: "OKX_INTL_API_SECRET", password: "OKX_INTL_PASSPHRASE"]

  defp credential_env(:bybit_demo), do: [api_key: "BYBIT_DEMO_API_KEY", secret: "BYBIT_DEMO_API_SECRET"]

  defp credential_env(:binance), do: [api_key: "BINANCE_TESTNET_API_KEY", secret: "BINANCE_TESTNET_API_SECRET"]

  defp credential_env(:binanceusdm),
    do: [api_key: "BINANCE_FUTURES_TEST_API_KEY", secret: "BINANCE_FUTURES_TEST_API_SECRET"]

  defp credential_env(:binancecoinm),
    do: [api_key: "BINANCE_FUTURES_TEST_API_KEY", secret: "BINANCE_FUTURES_TEST_API_SECRET"]

  defp credential_env(:hyperliquid),
    do: [api_key: "HYPERLIQUID_TESTNET_API_KEY", secret: "HYPERLIQUID_TESTNET_API_SECRET"]

  defp credential_env(:derive), do: [api_key: "DERIVE_TESTNET_API_KEY", secret: "DERIVE_TESTNET_API_SECRET"]

  defp credential_env(:alpaca), do: [api_key: "ALPACA_API_KEY", secret: "ALPACA_API_SECRET"]

  defp credential_env(:lighter) do
    [
      api_key: "LIGHTER_TESTNET_API_KEY_INDEX",
      uid: "LIGHTER_TESTNET_ACCOUNT_INDEX",
      secret: "LIGHTER_TESTNET_API_PRIVATE_KEY"
    ]
  end

  defp exchange_opts(:deribit), do: [sandbox: true]
  defp exchange_opts(:okx), do: [sandbox: true]
  defp exchange_opts(:bybit_demo), do: []
  defp exchange_opts(:binance), do: [sandbox: true]
  defp exchange_opts(:binanceusdm), do: [sandbox: true]
  defp exchange_opts(:binancecoinm), do: [sandbox: true]
  defp exchange_opts(:hyperliquid), do: [sandbox: true]
  defp exchange_opts(:derive), do: [sandbox: true, options: %{"subaccount_id" => @derive_subaccount_id}]
  defp exchange_opts(:alpaca), do: [sandbox: true]
  defp exchange_opts(:lighter), do: [sandbox: true]

  defp credentials(%{invalid_credentials: %Credentials{} = credentials}), do: {:ok, credentials}
  defp credentials(%{credential_env: []}), do: {:ok, nil}

  defp credentials(%{credential_env: env}) do
    missing = for {_field, variable} <- env, System.get_env(variable) in [nil, ""], do: variable

    if missing == [] do
      opts = Enum.map(env, fn {field, variable} -> {field, System.fetch_env!(variable)} end)
      {:ok, Credentials.new!(opts)}
    else
      {:error, {:missing_credentials, missing, credential_setup_instructions(missing)}}
    end
  end

  defp credential_setup_instructions(missing) do
    exports = Enum.map_join(missing, "\n", &~s(  export #{&1}="replace-me"))

    """
    Missing capture credentials:
    #{exports}
    Replace each placeholder with the venue credential described in CLAUDE.md Testnet Credentials.
    Error capture never skips a missing credential silently.
    """
  end

  defp build_exchange(exchange_id, profile, credentials) do
    opts = if credentials, do: Keyword.put(profile.exchange_opts, :credentials, credentials), else: profile.exchange_opts
    Exchange.new(exchange_id, opts)
  end

  defp build_params(:fetch_markets, _profile), do: %{}

  defp build_params(method, profile) do
    base = legacy_symbol_params(method, Map.get(profile, :symbol))
    Map.merge(base, Map.get(profile, :params) || %{})
  end

  defp legacy_symbol_params(:fetch_ticker, symbol) when is_binary(symbol), do: %{"symbol" => symbol}
  defp legacy_symbol_params(:fetch_trades, symbol) when is_binary(symbol), do: %{"symbol" => symbol}
  defp legacy_symbol_params(:fetch_funding_rate, symbol) when is_binary(symbol), do: %{"symbol" => symbol}
  defp legacy_symbol_params(:fetch_order_book, symbol) when is_binary(symbol), do: %{"symbol" => symbol}

  defp legacy_symbol_params(:fetch_ohlcv, symbol) when is_binary(symbol),
    do: %{"symbol" => symbol, "timeframe" => @ohlcv_timeframe}

  defp legacy_symbol_params(_method, _symbol), do: %{}

  defp capture_profile(exchange, exchange_id, method, %{category: :write} = profile, credentials) do
    with {:ok, create_params} <- live_create_params(exchange, profile),
         profile = %{profile | create_params: create_params, params: create_params},
         {:ok, create_response} <- Unified.capture_responses(exchange, :create_order, create_params, profile.call_opts),
         {:ok, order_id} <- order_id(create_response, profile) do
      capture_created_order(exchange, exchange_id, method, profile, credentials, order_id, create_response)
    end
  end

  defp capture_profile(exchange, exchange_id, method, %{category: :error} = profile, credentials) do
    with {:ok, exchange} <- maybe_load_markets(exchange, profile),
         {:ok, params} <- error_params(exchange, profile) do
      accept_error_response(
        capture_transport_status(exchange.id, fn -> dispatch_error_probe(exchange, profile, params) end),
        profile,
        exchange_id,
        method,
        params,
        credentials
      )
    end
  end

  defp capture_profile(exchange, exchange_id, method, %{param_variants: [_ | _] = variants} = profile, credentials) do
    with {:ok, responses} <- capture_param_variants(exchange, method, variants, profile.call_opts) do
      fixture =
        %{profile | params: %{"variants" => variants}}
        |> metadata(exchange_id, method)
        |> Map.put("responses", responses)
        |> scrub(credentials)

      {:ok, fixture}
    end
  end

  defp capture_profile(exchange, exchange_id, method, %{raw_endpoint: raw_endpoint} = profile, credentials)
       when is_atom(raw_endpoint) and not is_nil(raw_endpoint) do
    with {:ok, exchange} <- maybe_load_markets(exchange, profile),
         {:ok, params} <- live_read_params(exchange, method, profile),
         caller_params = recorded_caller_params(exchange_id, method, params, profile),
         {:ok, response} <- dispatch_raw_endpoint(exchange, raw_endpoint, params, profile.call_opts) do
      fixture =
        %{profile | params: params}
        |> metadata(exchange_id, method)
        |> Map.put("caller_params", caller_params)
        |> put_captured_responses([response])
        |> scrub(credentials)

      {:ok, fixture}
    end
  end

  defp capture_profile(exchange, exchange_id, method, profile, credentials) do
    with {:ok, exchange} <- maybe_load_markets(exchange, profile),
         {:ok, params} <- live_read_params(exchange, method, profile),
         caller_params = recorded_caller_params(exchange_id, method, params, profile),
         {:ok, response_or_responses} <-
           Unified.capture_responses(exchange, method, params, profile.call_opts) do
      fixture =
        %{profile | params: params}
        |> metadata(exchange_id, method)
        |> Map.put("caller_params", caller_params)
        |> put_captured_responses(List.wrap(response_or_responses))
        |> put_market_contexts(exchange, profile)
        |> scrub(credentials)

      {:ok, fixture}
    end
  end

  defp capture_param_variants(exchange, method, variants, call_opts) do
    variants
    |> Enum.reduce_while({:ok, []}, fn params, {:ok, responses} ->
      case Unified.capture_responses(exchange, method, params, call_opts) do
        {:ok, response} -> {:cont, {:ok, [variant_bodies(response, params) | responses]}}
        {:error, reason} -> {:halt, {:error, {:variant_capture_failed, params, reason}}}
      end
    end)
    |> case do
      {:ok, responses} -> {:ok, responses |> Enum.reverse() |> Enum.concat()}
      {:error, _reason} = error -> error
    end
  end

  defp variant_bodies(response, params) do
    response
    |> List.wrap()
    |> Enum.map(fn %{body: body} -> %{"body" => body, "params" => params} end)
  end

  defp live_read_params(%Exchange{id: "lighter"} = exchange, method, profile)
       when method in [:fetch_closed_orders, :fetch_open_orders] do
    with {:ok, market_id} <- LighterMarket.market_id(exchange.markets, profile.symbol) do
      {:ok,
       %{
         "account_index" => LighterMarket.credential_integer!(exchange.credentials.uid),
         "auth_deadline" => System.system_time(:second) + @lighter_auth_lifetime_seconds,
         "market_id" => market_id
       }}
    end
  end

  defp live_read_params(%Exchange{id: "lighter"} = exchange, :fetch_deposits, profile) do
    account_index = LighterMarket.credential_integer!(exchange.credentials.uid)

    with {:ok, %{status: 200, body: %{"code" => 200, "accounts" => [account | _]}}} <-
           Bourse.Lighter.public_get_account(exchange, %{"by" => "index", "value" => account_index}),
         l1_address when is_binary(l1_address) <- Map.get(account, "l1_address") do
      {:ok,
       :fetch_deposits
       |> build_params(profile)
       |> Map.merge(lighter_private_history_params(exchange))
       |> Map.put("l1_address", l1_address)}
    else
      nil -> {:error, :lighter_account_missing_l1_address}
      other -> {:error, {:lighter_account_lookup_failed, other}}
    end
  end

  defp live_read_params(%Exchange{id: "lighter"} = exchange, method, profile)
       when method in @lighter_private_history_methods do
    {:ok, method |> build_params(profile) |> Map.merge(lighter_private_history_params(exchange))}
  end

  defp live_read_params(_exchange, method, profile), do: {:ok, build_params(method, profile)}

  defp lighter_private_history_params(exchange) do
    %{
      "account_index" => LighterMarket.credential_integer!(exchange.credentials.uid),
      "auth_deadline" => System.system_time(:second) + @lighter_auth_lifetime_seconds
    }
  end

  defp recorded_caller_params("lighter", method, params, _profile)
       when is_map_key(@param_injections, {"lighter", method}) do
    Map.delete(params, "auth_deadline")
  end

  defp recorded_caller_params(_exchange_id, method, _params, profile), do: build_params(method, profile)

  defp error_params(exchange, %{error_kind: "insufficient_funds"} = profile) do
    params = build_params(Map.fetch!(profile, :call_method), profile)

    with {:ok, %Bourse.Balance{} = balance} <- Bourse.fetch_balance(exchange),
         {:ok, %Bourse.Ticker{last: last}} when is_number(last) and last > 0 <-
           Bourse.fetch_ticker(exchange, profile.symbol),
         total when is_number(total) <- Map.get(balance.total, profile.quote),
         notional = params["amount"] * last,
         true <- notional > total * @unfillable_balance_multiple do
      {:ok, params}
    else
      false -> {:error, {:order_not_proven_unfillable, profile.symbol}}
      nil -> {:error, {:missing_quote_balance, profile.quote}}
      {:ok, ticker} -> {:error, {:missing_live_order_price, ticker}}
      {:error, reason} -> {:error, {:unfillable_preflight_failed, reason}}
    end
  end

  defp error_params(_exchange, profile), do: {:ok, build_params(Map.fetch!(profile, :call_method), profile)}

  defp accept_error_response({{:error, %Error{} = error}, http_status}, profile, exchange_id, method, params, credentials)
       when is_integer(http_status) do
    if error.type in profile.expected_types do
      fixture =
        profile
        |> error_metadata(exchange_id, method, params, error, http_status)
        |> scrub(credentials)

      {:ok, fixture}
    else
      {:error, {:unexpected_error_type, error.type, profile.expected_types, error}}
    end
  end

  defp accept_error_response({result, nil}, _profile, exchange_id, method, _params, _credentials) do
    {:error, {:missing_http_status, exchange_id, method, result}}
  end

  defp accept_error_response({{:ok, response}, _http_status}, _profile, _exchange_id, _method, _params, _credentials) do
    {:error, {:expected_error_got_success, response}}
  end

  defp accept_error_response(other, _profile, _exchange_id, _method, _params, _credentials) do
    {:error, {:unexpected_error_probe_result, other}}
  end

  defp maybe_load_markets(exchange, %{load_markets?: true}) do
    case Bourse.fetch_markets(exchange) do
      {:ok, markets} -> {:ok, %{exchange | markets: markets}}
      {:error, reason} -> {:error, {:load_markets_failed, reason}}
    end
  end

  defp maybe_load_markets(exchange, _profile), do: {:ok, exchange}

  defp dispatch_error_probe(exchange, profile, params) do
    case Map.get(profile, :raw_endpoint) do
      nil ->
        Unified.capture_responses(exchange, profile.call_method, params, profile.call_opts)

      raw_endpoint ->
        dispatch_raw_endpoint(exchange, raw_endpoint, params, profile.call_opts)
    end
  end

  defp dispatch_raw_endpoint(exchange, raw_endpoint, params, call_opts) do
    module = Registry.module_for(exchange.id)
    config = Enum.find(module.__endpoints__(), &(&1.name == raw_endpoint))

    if config do
      Dispatch.call(exchange, config, params, call_opts)
    else
      {:error, {:unknown_raw_endpoint, raw_endpoint}}
    end
  end

  @doc false
  @spec handle_transport_status(
          [atom()],
          map(),
          map(),
          {pid(), reference(), String.t()}
        ) :: :ok
  def handle_transport_status(_event, _measurements, metadata, {receiver, ref, expected_exchange}) do
    if metadata.exchange == expected_exchange do
      send(receiver, {ref, metadata.status})
    end

    :ok
  end

  defp capture_transport_status(exchange_id, request_fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    message_ref = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.request_stop(),
        &__MODULE__.handle_transport_status/4,
        {self(), message_ref, exchange_id}
      )

    try do
      result = request_fun.()
      {result, latest_transport_status(message_ref)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp latest_transport_status(message_ref) do
    receive do
      {^message_ref, status} -> latest_transport_status(message_ref, status)
    after
      0 -> nil
    end
  end

  defp latest_transport_status(message_ref, current) do
    receive do
      {^message_ref, status} -> latest_transport_status(message_ref, status)
    after
      0 -> current
    end
  end

  defp error_metadata(profile, exchange_id, method, params, %Error{} = error, http_status) do
    body = error_body(error)

    %{
      "authenticated" => profile.authenticated,
      "body" => body,
      "call_method" => Atom.to_string(profile.call_method),
      "call_opts" => Map.new(profile.call_opts, fn {key, value} -> {Atom.to_string(key), value} end),
      "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "code" => error_code(error),
      "endpoint" => profile.endpoint,
      "environment" => profile.environment,
      "error_class" => Atom.to_string(error.type),
      "error_kind" => profile.error_kind,
      "exchange" => exchange_id,
      "host" => profile.host,
      "http_status" => http_status,
      "message" => error.message,
      "method" => Atom.to_string(method),
      "mutation_safety" => profile.mutation_safety,
      "params" => params,
      "symbol" => Map.get(profile, :symbol)
    }
  end

  defp error_body(%Error{raw: raw}) when is_map(raw) and map_size(raw) > 0, do: raw
  defp error_body(%Error{raw: raw}) when is_list(raw) and raw != [], do: raw

  defp error_body(%Error{raw: raw, message: message, http_status: status, code: code})
       when is_binary(raw) and raw != "" do
    %{
      "body" => raw,
      "code" => code,
      "http_status" => status,
      "message" => message
    }
  end

  defp error_body(%Error{message: message, http_status: status, code: code}) do
    %{
      "code" => code,
      "http_status" => status,
      "message" => message || ""
    }
  end

  defp error_code(%Error{code: code}) when is_binary(code) or is_integer(code), do: to_string(code)
  defp error_code(%Error{raw: %{"code" => code}}) when is_binary(code) or is_integer(code), do: to_string(code)
  defp error_code(%Error{raw: %{"retCode" => code}}) when is_binary(code) or is_integer(code), do: to_string(code)
  defp error_code(%Error{raw: %{"status" => status}}) when is_binary(status), do: status

  defp error_code(%Error{raw: %{"error" => %{"code" => code}}}) when is_binary(code) or is_integer(code),
    do: to_string(code)

  defp error_code(%Error{http_status: status}) when is_integer(status), do: to_string(status)
  defp error_code(%Error{}), do: nil

  defp capture_created_order(exchange, exchange_id, method, profile, credentials, order_id, create_response) do
    order_id = to_string(order_id)
    read_params = lifecycle_read_params(profile, order_id)
    cancel_params = %{"id" => order_id, "symbol" => profile.symbol}

    try do
      with {:ok, read_response} <-
             Unified.capture_responses(exchange, profile.read_method, read_params, profile.call_opts),
           {:ok, cancel_response} <-
             Unified.capture_responses(exchange, :cancel_order, cancel_params, profile.call_opts) do
        fixture =
          profile
          |> metadata(exchange_id, method)
          |> Map.put("mutation_safety", profile.mutation_safety)
          |> Map.put("responses", [
            lifecycle_response("create", :create_order, create_response),
            lifecycle_response("read", profile.read_method, read_response),
            lifecycle_response("cancel", :cancel_order, cancel_response)
          ])
          |> scrub(credentials)

        {:ok, fixture}
      end
    after
      cleanup_order!(exchange, profile, order_id)
    end
  end

  defp lifecycle_read_params(%{read_method: :fetch_open_orders, symbol: symbol}, _order_id), do: %{"symbol" => symbol}

  defp lifecycle_read_params(%{read_method: :fetch_order, symbol: symbol}, order_id),
    do: %{"id" => order_id, "symbol" => symbol}

  defp lifecycle_response(step, method, %{body: body}) do
    %{"body" => body, "method" => Atom.to_string(method), "step" => step}
  end

  defp lifecycle_response(step, method, response) do
    raise ArgumentError,
          "write lifecycle #{step}/#{method} expected one raw response, got: #{inspect(response)}"
  end

  defp order_id(%{body: body}, profile) do
    case get_in(body, profile.order_id_path) do
      nil -> {:error, {:missing_order_id, body}}
      "" -> {:error, {:missing_order_id, body}}
      id -> {:ok, id}
    end
  end

  defp order_id(response, _profile), do: {:error, {:unexpected_create_response, response}}

  defp live_create_params(exchange, profile) do
    case Bourse.fetch_ticker(exchange, profile.symbol, profile.call_opts) do
      {:ok, %Bourse.Ticker{last: last}} when is_number(last) and last > 0 ->
        price = last |> Kernel.*(profile.price_ratio) |> Float.round(@order_price_decimal_places)
        {:ok, Map.put(profile.create_params, "price", price)}

      {:ok, ticker} ->
        {:error, {:missing_live_order_price, ticker}}

      {:error, reason} ->
        {:error, {:live_order_price_failed, reason}}
    end
  end

  defp cleanup_order!(exchange, profile, order_id) do
    opts = Keyword.merge([symbol: profile.symbol], profile.call_opts)

    case Bourse.cancel_order(exchange, order_id, opts) do
      {:ok, %Bourse.Order{}} ->
        :ok

      {:error, %Error{type: type}} when type in [:order_not_found, :invalid_order] ->
        :ok

      other ->
        raise "write-fixture cleanup failed for #{exchange.id} order #{order_id}: #{inspect(other)}"
    end
  end

  defp metadata(profile, exchange_id, method) do
    maybe_put(
      %{
        "authenticated" => profile.authenticated,
        "call_opts" => Map.new(profile.call_opts, fn {key, value} -> {Atom.to_string(key), value} end),
        "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "endpoint" => profile.endpoint,
        "environment" => profile.environment,
        "exchange" => exchange_id,
        "host" => profile.host,
        "method" => Atom.to_string(method),
        "params" => profile.params,
        "symbol" => profile.symbol,
        "timeframe" => if(method == :fetch_ohlcv, do: @ohlcv_timeframe)
      },
      "oracle_membership",
      Map.get(profile, :oracle_membership)
    )
  end

  defp put_market_contexts(fixture, %Exchange{markets: markets}, %{market_context_ids: [_ | _] = ids})
       when is_list(markets) do
    contexts = Enum.map(ids, &market_context!(markets, &1))
    Map.put(fixture, "market_contexts", contexts)
  end

  defp put_market_contexts(fixture, _exchange, _profile), do: fixture

  defp market_context!(markets, id) do
    market = Enum.find(markets, &((Map.get(&1, :id) || Map.get(&1, "id")) == id))

    if is_map(market) do
      %{
        "normalized" => %{
          "contract_size" => Map.get(market, :contract_size) || Map.get(market, "contractSize"),
          "id" => id,
          "inverse" => Map.get(market, :inverse) == true or Map.get(market, "inverse") == true,
          "linear" => Map.get(market, :linear) == true or Map.get(market, "linear") == true,
          "symbol" => Map.get(market, :symbol) || Map.get(market, "symbol")
        },
        "raw" => Map.get(market, :info) || Map.get(market, "info") || %{}
      }
    else
      raise "loaded Deribit markets omitted required recording context #{id}"
    end
  end

  defp put_captured_responses(fixture, [%{"api" => _api} | _] = responses), do: Map.put(fixture, "responses", responses)

  defp put_captured_responses(fixture, [%{body: body}]), do: Map.put(fixture, "body", body)

  defp scrub_value(map, secrets) when is_map(map) do
    account_identity? = account_identity_map?(map)

    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) or (account_identity? and normalized_key(key) in ["id", "index", "accountindex"]) do
        {key, @mask}
      else
        {key, scrub_value(value, secrets)}
      end
    end)
  end

  defp scrub_value(list, secrets) when is_list(list), do: Enum.map(list, &scrub_value(&1, secrets))

  defp scrub_value(value, secrets) when is_binary(value) do
    if value in secrets, do: @mask, else: value
  end

  defp scrub_value(value, _secrets), do: value

  defp credential_values(nil), do: []

  defp credential_values(credentials) do
    credentials
    |> Map.from_struct()
    |> Map.take([:api_key, :secret, :password, :uid])
    |> Map.values()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp find_safety_violations(map, path) when is_map(map) do
    account_identity? = account_identity_map?(map)

    Enum.flat_map(map, fn {key, value} ->
      child_path = path <> "." <> to_string(key)

      nested_violations = find_safety_violations(value, child_path)

      sensitive? =
        sensitive_key?(key) or (account_identity? and normalized_key(key) in ["id", "index", "accountindex"])

      if sensitive? and value != @mask,
        do: [child_path | nested_violations],
        else: nested_violations
    end)
  end

  defp find_safety_violations(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> find_safety_violations(value, "#{path}[#{index}]") end)
  end

  defp find_safety_violations(_value, _path), do: []

  defp sensitive_key?(key) do
    MapSet.member?(@sensitive_keys, normalized_key(key))
  end

  defp account_identity_map?(map),
    do: Enum.any?(Map.keys(map), &(normalized_key(&1) in ["email", "username", "systemname", "l1address"]))

  defp normalized_key(key), do: key |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
end
