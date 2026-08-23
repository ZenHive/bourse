defmodule Bourse.EmulationStrategiesTest do
  use ExUnit.Case, async: true

  alias Bourse.Emulation
  alias Bourse.Exchange
  alias Bourse.Spec.EmulatedMethods

  @symbol "BTC/USDT"
  @swap_symbol "BTC/USDT:USDT"
  @other_symbol "ETH/USDT"
  @order_id "order-123"
  @missing_order_id "order-missing"
  @trade_id "trade-1"
  @trade_id_extra "trade-2"
  @code "BTC"
  @network "ERC20"

  @timestamp_old 1_600_000_000_000
  @timestamp_new 1_700_000_000_000
  @timestamp_latest 1_800_000_000_000
  @limit_one 1
  @min_amount 1
  @max_amount 10
  @fee_value "0.0001"

  @credentials %Bourse.Credentials{api_key: "key", secret: "secret"}

  defmodule ExchangeStub do
    @moduledoc false

    @spec __unified_endpoint__(atom()) :: [map()]
    def __unified_endpoint__(method) when is_atom(method) do
      {__MODULE__, :endpoints}
      |> Process.get(%{})
      |> Map.get(method, [])
    end

    @spec configure_endpoints!(%{atom() => [map()]}) :: :ok
    def configure_endpoints!(endpoints) when is_map(endpoints) do
      Process.put({__MODULE__, :endpoints}, endpoints)
      :ok
    end

    # Returns orders from process dictionary for emulation tests
    def fetch_orders(_creds, _symbol, _since, _limit, _opts) do
      {:ok, Process.get(:orders, [])}
    end

    # Returns tickers from process dictionary for emulation tests
    def fetch_tickers(_symbols, _opts) do
      {:ok, Process.get(:tickers, %{})}
    end

    # Returns markets from process dictionary for emulation tests
    def fetch_markets(_opts) do
      {:ok, Process.get(:markets, [])}
    end

    # Minimal ticker parser for metaAndAssetCtxs emulation tests
    def parse_ticker(raw, _opts) when is_map(raw) do
      last =
        case Map.get(raw, "markPx") || Map.get(raw, "midPx") do
          nil -> nil
          value when is_binary(value) -> String.to_float(value)
          value when is_number(value) -> value * 1.0
        end

      {:ok, %Bourse.Ticker{symbol: nil, last: last, info: raw}}
    end

    # Returns deposit address map from process dictionary for emulation tests
    def fetch_deposit_addresses_by_network(_creds, _code, _opts) do
      {:ok, Process.get(:deposit_addresses_by_network, %{})}
    end

    # Returns trades from process dictionary for emulation tests
    def fetch_my_trades(_creds, _symbol, _since, _limit, _opts) do
      {:ok, Process.get(:my_trades, [])}
    end

    # Returns leverage map from process dictionary for emulation tests
    def fetch_leverages(_creds, _symbols, _opts) do
      {:ok, Process.get(:leverages, %{})}
    end

    # Returns trading fees map from process dictionary for emulation tests
    def fetch_trading_fees(_creds, _opts) do
      {:ok, Process.get(:trading_fees, %{})}
    end

    # Returns deposit/withdraw fee map from process dictionary for emulation tests
    def fetch_deposit_withdraw_fees(_creds, _codes, _opts) do
      {:ok, Process.get(:deposit_withdraw_fees, %{})}
    end

    # Returns transaction fee map from process dictionary for emulation tests
    def fetch_transaction_fees(_creds, _codes, _opts) do
      {:ok, Process.get(:transaction_fees, %{})}
    end

    # Returns ledger entries from process dictionary for emulation tests
    def fetch_ledger(_creds, _code, _since, _limit, _opts) do
      {:ok, Process.get(:ledger, [])}
    end

    # Returns deposit address map from process dictionary for emulation tests
    def fetch_deposit_addresses(_creds, _codes, _opts) do
      {:ok, Process.get(:deposit_addresses, %{})}
    end

    # Returns deposits list from process dictionary for emulation tests
    def fetch_deposits(_creds, _code, _since, _limit, _opts) do
      {:ok, Process.get(:deposits, [])}
    end

    # Returns withdrawals list from process dictionary for emulation tests
    def fetch_withdrawals(_creds, _code, _since, _limit, _opts) do
      {:ok, Process.get(:withdrawals, [])}
    end

    # Returns funding rates map from process dictionary for emulation tests
    def fetch_funding_rates(_creds, _symbols, _opts) do
      {:ok, Process.get(:funding_rates, %{})}
    end

    def fetch_funding_rates(_symbols, _opts) do
      {:ok, Process.get(:funding_rates, %{})}
    end

    # Returns leverage tiers map from process dictionary for emulation tests
    def fetch_leverage_tiers(_creds, _symbols, _opts) do
      {:ok, Process.get(:leverage_tiers, %{})}
    end

    # Returns isolated borrow rates map from process dictionary for emulation tests
    def fetch_isolated_borrow_rates(_creds, _opts) do
      {:ok, Process.get(:isolated_borrow_rates, %{})}
    end

    # Returns positions list from process dictionary for emulation tests
    def fetch_positions(_creds, _symbols, _opts) do
      {:ok, Process.get(:positions, [])}
    end

    # Returns positions history from process dictionary for emulation tests
    def fetch_positions_history(_creds, _symbols, _since, _limit, _opts) do
      {:ok, Process.get(:positions_history, [])}
    end

    # Returns margin modes map from process dictionary for emulation tests
    def fetch_margin_modes(_creds, _symbols, _opts) do
      {:ok, Process.get(:margin_modes, %{})}
    end

    # Returns funding intervals map from process dictionary for emulation tests
    def fetch_funding_intervals(_creds, _symbols, _opts) do
      {:ok, Process.get(:funding_intervals, %{})}
    end

    # Returns open orders from process dictionary for emulation tests
    def fetch_open_orders(_creds, _symbol, _since, _limit, _opts) do
      {:ok, Process.get(:open_orders, [])}
    end

    # Returns closed orders from process dictionary for emulation tests
    def fetch_closed_orders(_creds, _symbol, _since, _limit, _opts) do
      {:ok, Process.get(:closed_orders, [])}
    end

    # Returns canceled orders from process dictionary for emulation tests
    def fetch_canceled_orders(_creds, _symbol, _since, _limit, _opts) do
      {:ok, Process.get(:canceled_orders, [])}
    end
  end

  describe "core emulation strategies" do
    test "fetch_closed_orders filters by status and since/limit" do
      exchange_id = exchange_for_method("fetchClosedOrders")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: @order_id, status: "closed", timestamp: @timestamp_new},
        %{id: "open-order", status: "open", timestamp: @timestamp_new},
        %{id: "old-closed", status: "closed", timestamp: @timestamp_old}
      ])

      assert {:ok, [%{id: @order_id}]} =
               dispatch(exchange, :fetch_closed_orders,
                 params: %{symbol: @symbol, since: @timestamp_new, limit: nil},
                 credentials: @credentials
               )
    end

    test "fetch_ticker selects a single ticker from fetch_tickers" do
      exchange_id = exchange_for_method("fetchTicker")
      exchange = build_exchange(exchange_id, [:fetch_tickers])

      Process.put(:tickers, %{
        @symbol => %{symbol: @symbol, last: "42000"},
        @other_symbol => %{symbol: @other_symbol, last: "2500"}
      })

      assert {:ok, %{symbol: @symbol}} =
               dispatch(exchange, :fetch_ticker, params: %{symbol: @symbol})
    end

    test "fetch_ticker resolves hyperliquid metaAndAssetCtxs via carved market symbols" do
      exchange = build_exchange("hyperliquid", [:fetch_tickers, :fetch_markets])

      Process.put(:tickers, %{
        status: 200,
        headers: %{},
        body: [
          %{"universe" => [%{"name" => "BTC", "maxLeverage" => 40, "szDecimals" => 5}]},
          [%{"markPx" => "62750.0", "midPx" => "62744.5"}]
        ]
      })

      Process.put(:markets, [%{symbol: "BTC/USDC:USDC"}])

      assert {:ok, %{symbol: "BTC/USDC:USDC", last: 62_750.0}} =
               dispatch(exchange, :fetch_ticker, params: %{symbol: "BTC/USDC:USDC"})
    end

    test "fetch_ticker indexes nil-symbol tickers against carved markets by position" do
      exchange_id = exchange_for_method("fetchTicker")
      exchange = build_exchange(exchange_id, [:fetch_tickers, :fetch_markets])

      Process.put(:tickers, [%{symbol: nil, last: 42_000}])
      Process.put(:markets, [%{symbol: @symbol}])

      assert {:ok, %{symbol: @symbol, last: 42_000}} =
               dispatch(exchange, :fetch_ticker, params: %{symbol: @symbol})
    end

    test "fetch_ticker returns error when symbol is missing" do
      exchange_id = exchange_for_method("fetchTicker")
      exchange = build_exchange(exchange_id, [:fetch_tickers])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_ticker)

      assert String.contains?(message, "requires a symbol argument")
    end

    test "fetch_trading_limits derives limits from markets" do
      exchange_id = exchange_for_method("fetchTradingLimits")
      exchange = build_exchange(exchange_id, [:fetch_markets])

      Process.put(:markets, [
        %{
          symbol: @symbol,
          limits: %{amount: %{min: @min_amount, max: @max_amount}}
        },
        %{
          symbol: @other_symbol,
          limits: %{amount: %{min: @min_amount, max: @max_amount}}
        }
      ])

      assert {:ok, %{@symbol => %{min: @min_amount, max: @max_amount}}} =
               dispatch(exchange, :fetch_trading_limits, params: %{symbols: [@symbol]})
    end

    test "fetch_trading_fee selects a symbol entry from fetch_trading_fees" do
      exchange_id = exchange_for_method("fetchTradingFee")
      exchange = build_exchange(exchange_id, [:fetch_trading_fees], auth_methods: [:fetch_trading_fees])

      Process.put(:trading_fees, %{@symbol => %{symbol: @symbol, maker: @fee_value}})

      assert {:ok, %{symbol: @symbol, maker: @fee_value}} =
               dispatch(exchange, :fetch_trading_fee,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_trading_fee errors when fetch_trading_fees has no symbol row" do
      exchange_id = exchange_for_method("fetchTradingFee")
      exchange = build_exchange(exchange_id, [:fetch_trading_fees], auth_methods: [:fetch_trading_fees])

      Process.put(:trading_fees, %{})

      assert_missing_symbol_error(
        dispatch(exchange, :fetch_trading_fee,
          params: %{symbol: @symbol},
          credentials: @credentials
        ),
        @symbol
      )
    end

    test "fetch_trading_fee returns not_supported when endpoint missing" do
      exchange_id = exchange_for_method("fetchTradingFee")
      exchange = build_exchange(exchange_id, [])

      assert {:error, %Bourse.Error{type: :not_supported, message: message}} =
               dispatch(exchange, :fetch_trading_fee,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "fetch_trading_fees")
    end

    test "fetch_deposit_address selects network address when provided" do
      exchange_id = exchange_for_method("fetchDepositAddress")

      exchange =
        build_exchange(exchange_id, [:fetch_deposit_addresses_by_network],
          auth_methods: [:fetch_deposit_addresses_by_network]
        )

      Process.put(:deposit_addresses_by_network, %{
        @network => %{address: "0xabc"}
      })

      assert {:ok, %{address: "0xabc"}} =
               dispatch(exchange, :fetch_deposit_address,
                 params: %{code: @code, network: @network},
                 credentials: @credentials
               )
    end

    test "fetch_deposit_address selects an address from fetch_deposit_addresses" do
      exchange_id = exchange_for_method("fetchDepositAddress")

      exchange =
        build_exchange(exchange_id, [:fetch_deposit_addresses], auth_methods: [:fetch_deposit_addresses])

      Process.put(:deposit_addresses, %{@code => %{address: "addr-1"}})

      assert {:ok, %{address: "addr-1"}} =
               dispatch(exchange, :fetch_deposit_address,
                 params: %{code: @code},
                 credentials: @credentials
               )
    end

    test "fetch_deposit_address returns not_supported when endpoints missing" do
      exchange_id = exchange_for_method("fetchDepositAddress")
      exchange = build_exchange(exchange_id, [])

      assert {:error, %Bourse.Error{type: :not_supported, message: message}} =
               dispatch(exchange, :fetch_deposit_address,
                 params: %{code: @code},
                 credentials: @credentials
               )

      assert String.contains?(message, "fetchDepositAddress() is not supported yet")
    end

    test "fetch_order returns not_found when missing" do
      exchange_id = exchange_for_method("fetchOrder")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [%{id: @order_id, status: "open", timestamp: @timestamp_new}])

      assert {:error, %Bourse.Error{type: :order_not_found}} =
               dispatch(exchange, :fetch_order,
                 params: %{id: @missing_order_id, symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_order_trades uses trade ids from params" do
      exchange_id = exchange_for_method("fetchOrderTrades")
      exchange = build_exchange(exchange_id, [:fetch_my_trades], auth_methods: [:fetch_my_trades])

      Process.put(:my_trades, [
        %{id: @trade_id, order_id: @order_id, symbol: @symbol},
        %{id: @trade_id_extra, order_id: @order_id, symbol: @symbol},
        %{id: "ignored-trade", order_id: @order_id, symbol: @symbol}
      ])

      assert {:ok, trades} =
               dispatch(exchange, :fetch_order_trades,
                 params: %{id: @order_id, symbol: @symbol, trades: [@trade_id, @trade_id_extra]},
                 credentials: @credentials
               )

      assert Enum.map(trades, & &1.id) == [@trade_id, @trade_id_extra]
    end

    test "fetch_my_trades flattens trades from orders" do
      exchange_id = exchange_for_method("fetchMyTrades")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: @order_id, trades: [%{id: @trade_id, order_id: @order_id, symbol: @symbol}]}
      ])

      assert {:ok, [%{id: @trade_id, order_id: @order_id}]} =
               dispatch(exchange, :fetch_my_trades,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_order_trades filters fetch_my_trades by order id" do
      exchange_id = exchange_for_method("fetchOrderTrades")
      exchange = build_exchange(exchange_id, [:fetch_my_trades], auth_methods: [:fetch_my_trades])

      Process.put(:my_trades, [
        %{id: @trade_id, order_id: @order_id, symbol: @symbol},
        %{id: "other-trade", order_id: "other", symbol: @symbol}
      ])

      assert {:ok, [%{id: @trade_id}]} =
               dispatch(exchange, :fetch_order_trades,
                 params: %{id: @order_id, symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_leverage returns authentication_error when auth required" do
      exchange_id = exchange_for_method("fetchLeverage")
      exchange = build_exchange(exchange_id, [:fetch_leverages], auth_methods: [:fetch_leverages])

      assert {:error, %Bourse.Error{type: :authentication_error, message: message}} =
               dispatch(exchange, :fetch_leverage, params: %{symbol: @symbol})

      assert String.contains?(message, "Credentials required")
    end

    test "fetch_leverage selects a symbol entry from fetch_leverages" do
      exchange_id = exchange_for_method("fetchLeverage")
      exchange = build_exchange(exchange_id, [:fetch_leverages], auth_methods: [:fetch_leverages])

      Process.put(:leverages, %{@symbol => %{symbol: @symbol, leverage: "5"}})

      assert {:ok, %{symbol: @symbol}} =
               dispatch(exchange, :fetch_leverage,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_leverage errors when fetch_leverages has no symbol row" do
      exchange_id = exchange_for_method("fetchLeverage")
      exchange = build_exchange(exchange_id, [:fetch_leverages], auth_methods: [:fetch_leverages])

      Process.put(:leverages, %{})

      assert_missing_symbol_error(
        dispatch(exchange, :fetch_leverage,
          params: %{symbol: @symbol},
          credentials: @credentials
        ),
        @symbol
      )
    end

    test "fetch_deposit_withdraw_fee selects a code entry" do
      exchange_id = exchange_for_method("fetchDepositWithdrawFee")

      exchange =
        build_exchange(exchange_id, [:fetch_deposit_withdraw_fees], auth_methods: [:fetch_deposit_withdraw_fees])

      Process.put(:deposit_withdraw_fees, %{@code => %{code: @code, fee: @fee_value}})

      assert {:ok, %{code: @code, fee: @fee_value}} =
               dispatch(exchange, :fetch_deposit_withdraw_fee,
                 params: %{code: @code},
                 credentials: @credentials
               )
    end

    test "fetch_transaction_fee returns fees when code is provided" do
      exchange_id = exchange_for_method("fetchTransactionFee")
      exchange = build_exchange(exchange_id, [:fetch_transaction_fees], auth_methods: [:fetch_transaction_fees])

      Process.put(:transaction_fees, %{@code => %{code: @code, fee: @fee_value}})

      assert {:ok, fees} =
               dispatch(exchange, :fetch_transaction_fee,
                 params: %{code: @code},
                 credentials: @credentials
               )

      assert fees[@code][:fee] == @fee_value
    end

    test "fetch_transaction_fee requires a code argument" do
      exchange_id = exchange_for_method("fetchTransactionFee")
      exchange = build_exchange(exchange_id, [:fetch_transaction_fees])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_transaction_fee)

      assert String.contains?(message, "requires a code argument")
    end

    test "fetch_deposits_withdrawals combines deposits and withdrawals when available" do
      exchange_id = exchange_for_method("fetchDepositsWithdrawals")

      exchange =
        build_exchange(exchange_id, [:fetch_deposits, :fetch_withdrawals],
          auth_methods: [:fetch_deposits, :fetch_withdrawals]
        )

      Process.put(:deposits, [
        %{id: "deposit-old", type: "deposit", timestamp: @timestamp_old},
        %{id: "deposit-new", type: "deposit", timestamp: @timestamp_new}
      ])

      Process.put(:withdrawals, [
        %{id: "withdraw-new", type: "withdrawal", timestamp: @timestamp_latest}
      ])

      assert {:ok, [%{id: "deposit-new"}]} =
               dispatch(exchange, :fetch_deposits_withdrawals,
                 params: %{since: @timestamp_new, limit: @limit_one},
                 credentials: @credentials
               )
    end

    test "fetch_deposits_withdrawals filters ledger by type and since/limit" do
      exchange_id = exchange_for_method("fetchDepositsWithdrawals")
      exchange = build_exchange(exchange_id, [:fetch_ledger], auth_methods: [:fetch_ledger])

      Process.put(:ledger, [
        %{id: "ledger-old", type: "deposit", timestamp: @timestamp_old},
        %{id: "ledger-new", transact_type: "withdrawal", timestamp: @timestamp_new},
        %{id: "ledger-trade", type: "trade", timestamp: @timestamp_latest},
        %{id: "ledger-late", type: "deposit", timestamp: @timestamp_latest}
      ])

      assert {:ok, [%{id: "ledger-new"}]} =
               dispatch(exchange, :fetch_deposits_withdrawals,
                 params: %{since: @timestamp_new, limit: @limit_one},
                 credentials: @credentials
               )
    end

    test "fetch_funding_rate rejects non-contract markets" do
      exchange_id = exchange_for_method("fetchFundingRate")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_funding_rates], auth_methods: [:fetch_funding_rates])

      Process.put(:markets, [
        %{symbol: @symbol, contract: false}
      ])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_funding_rate,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "contract markets only")
    end

    test "fetch_market_leverage_tiers returns tiers for a contract market" do
      exchange_id = exchange_for_method("fetchMarketLeverageTiers")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_leverage_tiers], auth_methods: [:fetch_leverage_tiers])

      Process.put(:markets, [
        %{symbol: @symbol, contract: true}
      ])

      Process.put(:leverage_tiers, %{@symbol => %{symbol: @symbol, tiers: []}})

      assert {:ok, %{symbol: @symbol, tiers: []}} =
               dispatch(exchange, :fetch_market_leverage_tiers,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_market_leverage_tiers errors when fetch_leverage_tiers has no symbol row" do
      exchange_id = exchange_for_method("fetchMarketLeverageTiers")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_leverage_tiers], auth_methods: [:fetch_leverage_tiers])

      Process.put(:markets, [%{symbol: @symbol, contract: true}])
      Process.put(:leverage_tiers, %{})

      assert_missing_symbol_error(
        dispatch(exchange, :fetch_market_leverage_tiers,
          params: %{symbol: @symbol},
          credentials: @credentials
        ),
        @symbol
      )
    end

    test "fetch_isolated_borrow_rate selects a symbol entry" do
      exchange_id = exchange_for_method("fetchIsolatedBorrowRate")

      exchange =
        build_exchange(exchange_id, [:fetch_isolated_borrow_rates], auth_methods: [:fetch_isolated_borrow_rates])

      Process.put(:isolated_borrow_rates, %{@symbol => %{symbol: @symbol, rate: "0.1"}})

      assert {:ok, %{symbol: @symbol, rate: "0.1"}} =
               dispatch(exchange, :fetch_isolated_borrow_rate,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end
  end

  describe "untested strategy handlers" do
    test "fetch_bids_asks delegates to fetch_tickers" do
      exchange_id = exchange_for_method("fetchBidsAsks")
      exchange = build_exchange(exchange_id, [:fetch_tickers])

      Process.put(:tickers, %{
        @symbol => %{symbol: @symbol, bid: "41999", ask: "42001"},
        @other_symbol => %{symbol: @other_symbol, bid: "2499", ask: "2501"}
      })

      assert {:ok, %{@symbol => %{symbol: @symbol}, @other_symbol => %{symbol: @other_symbol}}} =
               dispatch(exchange, :fetch_bids_asks)
    end

    test "fetch_currencies derives currencies from markets" do
      # fetchCurrencies handler exists but no exchange currently marks it as emulated,
      # so we test the handler directly instead of going through dispatch.
      exchange = build_exchange("test_exchange", [:fetch_markets])

      Process.put(:markets, [
        %{
          symbol: @symbol,
          base: "BTC",
          quote: "USDT",
          base_id: "btc",
          quote_id: "usdt",
          precision: %{base: 8, quote: 2}
        }
      ])

      assert {:ok, currencies} =
               Emulation.handle_fetch_currencies(exchange, ExchangeStub, %{}, __emulation_caller__: stub_caller())

      assert Map.has_key?(currencies, "BTC")
      assert Map.has_key?(currencies, "USDT")
      assert currencies["BTC"][:code] == "BTC"
      assert currencies["USDT"][:code] == "USDT"
    end

    test "fetch_transactions delegates to fetch_deposits_withdrawals" do
      exchange_id = exchange_for_method("fetchTransactions")

      exchange =
        build_exchange(exchange_id, [:fetch_deposits, :fetch_withdrawals],
          auth_methods: [:fetch_deposits, :fetch_withdrawals]
        )

      Process.put(:deposits, [%{id: "dep-1", type: "deposit", timestamp: @timestamp_new}])
      Process.put(:withdrawals, [%{id: "wd-1", type: "withdrawal", timestamp: @timestamp_latest}])

      assert {:ok, results} =
               dispatch(exchange, :fetch_transactions, credentials: @credentials)

      ids = Enum.map(results, & &1.id)
      assert "dep-1" in ids
      assert "wd-1" in ids
    end

    test "fetch_position selects by symbol from positions list" do
      exchange_id = exchange_for_method("fetchPosition")
      exchange = build_exchange(exchange_id, [:fetch_positions], auth_methods: [:fetch_positions])

      Process.put(:positions, [
        %{symbol: @symbol, side: "long", contracts: 5},
        %{symbol: @other_symbol, side: "short", contracts: 3}
      ])

      assert {:ok, %{symbol: @symbol, side: "long"}} =
               dispatch(exchange, :fetch_position,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_position_history delegates to fetch_positions_history" do
      exchange_id = exchange_for_method("fetchPositionHistory")

      exchange =
        build_exchange(exchange_id, [:fetch_positions_history], auth_methods: [:fetch_positions_history])

      Process.put(:positions_history, [
        %{symbol: @symbol, timestamp: @timestamp_old},
        %{symbol: @symbol, timestamp: @timestamp_new}
      ])

      assert {:ok, positions} =
               dispatch(exchange, :fetch_position_history,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert length(positions) == 2
    end

    test "fetch_margin_mode selects by symbol from margin modes" do
      exchange_id = exchange_for_method("fetchMarginMode")
      exchange = build_exchange(exchange_id, [:fetch_margin_modes], auth_methods: [:fetch_margin_modes])

      Process.put(:margin_modes, %{
        @symbol => %{symbol: @symbol, marginMode: "cross"},
        @other_symbol => %{symbol: @other_symbol, marginMode: "isolated"}
      })

      assert {:ok, %{symbol: @symbol, marginMode: "cross"}} =
               dispatch(exchange, :fetch_margin_mode,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_margin_mode errors when fetch_margin_modes has no symbol row" do
      exchange_id = exchange_for_method("fetchMarginMode")
      exchange = build_exchange(exchange_id, [:fetch_margin_modes], auth_methods: [:fetch_margin_modes])

      Process.put(:margin_modes, %{})

      assert_missing_symbol_error(
        dispatch(exchange, :fetch_margin_mode,
          params: %{symbol: @symbol},
          credentials: @credentials
        ),
        @symbol
      )
    end

    test "fetch_funding_interval success for contract market" do
      exchange_id = exchange_for_method("fetchFundingInterval")

      exchange =
        build_exchange(
          exchange_id,
          [:fetch_markets, :fetch_funding_intervals],
          auth_methods: [:fetch_funding_intervals]
        )

      Process.put(:markets, [%{symbol: @symbol, contract: true}])
      Process.put(:funding_intervals, %{@symbol => %{symbol: @symbol, interval: 8}})

      assert {:ok, %{symbol: @symbol, interval: 8}} =
               dispatch(exchange, :fetch_funding_interval,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_funding_interval returns error when not found" do
      exchange_id = exchange_for_method("fetchFundingInterval")

      exchange =
        build_exchange(
          exchange_id,
          [:fetch_markets, :fetch_funding_intervals],
          auth_methods: [:fetch_funding_intervals]
        )

      Process.put(:markets, [%{symbol: @symbol, contract: true}])
      Process.put(:funding_intervals, %{})

      assert {:error, %Bourse.Error{type: :exchange_error, message: message}} =
               dispatch(exchange, :fetch_funding_interval,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "fetchFundingInterval()")
      assert String.contains?(message, @symbol)
    end

    test "fetch_open_orders filters orders by open status" do
      exchange_id = exchange_for_method("fetchOpenOrders")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: "open-1", status: "open", timestamp: @timestamp_new},
        %{id: "closed-1", status: "closed", timestamp: @timestamp_new},
        %{id: "open-2", status: "open", timestamp: @timestamp_latest}
      ])

      assert {:ok, orders} =
               dispatch(exchange, :fetch_open_orders,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert length(orders) == 2
      assert Enum.all?(orders, fn o -> o.status == "open" end)
    end

    test "fetch_canceled_orders filters orders by canceled status" do
      exchange_id = exchange_for_method("fetchCanceledOrders")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: "open-1", status: "open", timestamp: @timestamp_new},
        %{id: "canceled-1", status: "canceled", timestamp: @timestamp_new},
        %{id: "canceled-2", status: "canceled", timestamp: @timestamp_latest}
      ])

      assert {:ok, orders} =
               dispatch(exchange, :fetch_canceled_orders,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert length(orders) == 2
    end

    test "fetch_canceled_and_closed_orders merges and sorts" do
      exchange_id = exchange_for_method("fetchCanceledAndClosedOrders")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: "open-1", status: "open", timestamp: @timestamp_new},
        %{id: "closed-1", status: "closed", timestamp: @timestamp_old},
        %{id: "canceled-1", status: "canceled", timestamp: @timestamp_latest}
      ])

      assert {:ok, orders} =
               dispatch(exchange, :fetch_canceled_and_closed_orders,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      ids = Enum.map(orders, & &1.id)
      assert "closed-1" in ids
      assert "canceled-1" in ids
      refute "open-1" in ids
    end
  end

  describe "additional code paths in tested handlers" do
    test "fetch_order returns matching order when found" do
      exchange_id = exchange_for_method("fetchOrder")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: @order_id, status: "open", symbol: @symbol, timestamp: @timestamp_new},
        %{id: "other-order", status: "closed", symbol: @symbol, timestamp: @timestamp_old}
      ])

      assert {:ok, %{id: @order_id, status: "open"}} =
               dispatch(exchange, :fetch_order,
                 params: %{id: @order_id, symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_order via combine_order_endpoints when fetch_orders unavailable" do
      exchange_id = exchange_for_method("fetchOrder")

      exchange =
        build_exchange(exchange_id, [:fetch_open_orders, :fetch_closed_orders, :fetch_canceled_orders],
          auth_methods: [:fetch_open_orders, :fetch_closed_orders, :fetch_canceled_orders]
        )

      Process.put(:open_orders, [%{id: "open-1", status: "open", timestamp: @timestamp_new}])
      Process.put(:closed_orders, [%{id: @order_id, status: "closed", timestamp: @timestamp_old}])
      Process.put(:canceled_orders, [])

      assert {:ok, %{id: @order_id, status: "closed"}} =
               dispatch(exchange, :fetch_order,
                 params: %{id: @order_id, symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_order_trades fetches and filters by order_id when no trades param" do
      exchange_id = exchange_for_method("fetchOrderTrades")
      exchange = build_exchange(exchange_id, [:fetch_my_trades], auth_methods: [:fetch_my_trades])

      Process.put(:my_trades, [
        %{id: @trade_id, order_id: @order_id, symbol: @symbol, timestamp: @timestamp_new},
        %{id: "other-trade", order_id: "other-order", symbol: @symbol, timestamp: @timestamp_new}
      ])

      assert {:ok, [%{id: @trade_id}]} =
               dispatch(exchange, :fetch_order_trades,
                 params: %{id: @order_id, symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_order_trades extracts trades from order object in params" do
      exchange_id = exchange_for_method("fetchOrderTrades")
      exchange = build_exchange(exchange_id, [:fetch_my_trades], auth_methods: [:fetch_my_trades])

      order_trades = [
        %{id: @trade_id, order_id: @order_id, symbol: @symbol, timestamp: @timestamp_new},
        %{id: @trade_id_extra, order_id: @order_id, symbol: @symbol, timestamp: @timestamp_latest}
      ]

      assert {:ok, trades} =
               dispatch(exchange, :fetch_order_trades,
                 params: %{
                   id: @order_id,
                   symbol: @symbol,
                   order: %{id: @order_id, trades: order_trades}
                 },
                 credentials: @credentials
               )

      assert length(trades) == 2
      assert Enum.map(trades, & &1.id) == [@trade_id, @trade_id_extra]
    end

    test "fetch_funding_rate success for contract market with rate" do
      exchange_id = exchange_for_method("fetchFundingRate")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_funding_rates], auth_methods: [:fetch_funding_rates])

      Process.put(:markets, [%{symbol: @symbol, contract: true}])
      Process.put(:funding_rates, %{@symbol => %{symbol: @symbol, fundingRate: "0.0001"}})

      assert {:ok, %{symbol: @symbol, fundingRate: "0.0001"}} =
               dispatch(exchange, :fetch_funding_rate,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_funding_rate accepts carved %Market{} with nil contract when symbol is a swap" do
      exchange =
        build_exchange("bybit", [:fetch_markets, :fetch_funding_rates],
          endpoint_configs: %{
            fetch_markets: [%{name: :public_get_markets, authenticated: false}],
            fetch_funding_rates: [%{name: :public_get_funding_rates, authenticated: false}]
          }
        )

      Process.put(:markets, [
        %Bourse.Market{symbol: @swap_symbol, settle: "USDT", contract: nil, info: %{"contractType" => "LinearPerpetual"}}
      ])

      Process.put(:funding_rates, %{@swap_symbol => %{symbol: @swap_symbol, fundingRate: "0.0001"}})

      assert {:ok, %{symbol: @swap_symbol, fundingRate: "0.0001"}} =
               dispatch(exchange, :fetch_funding_rate, params: %{symbol: @swap_symbol})
    end

    test "fetch_funding_rate loads mixed public/private markets without credentials" do
      exchange_id = exchange_for_method("fetchFundingRate")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_funding_rates],
          endpoint_configs: %{
            fetch_markets: [
              %{name: :private_get_markets, authenticated: true},
              %{name: :public_get_markets, authenticated: false}
            ],
            fetch_funding_rates: [%{name: :public_get_funding_rates, authenticated: false}]
          }
        )

      Process.put(:markets, [%{symbol: @symbol, contract: true}])
      Process.put(:funding_rates, %{@symbol => %{symbol: @symbol, fundingRate: "0.0001"}})

      assert {:ok, %{symbol: @symbol, fundingRate: "0.0001"}} =
               dispatch(exchange, :fetch_funding_rate, params: %{symbol: @symbol})
    end

    test "fetch_funding_rate not found for contract market" do
      exchange_id = exchange_for_method("fetchFundingRate")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_funding_rates], auth_methods: [:fetch_funding_rates])

      Process.put(:markets, [%{symbol: @symbol, contract: true}])
      Process.put(:funding_rates, %{})

      assert {:error, %Bourse.Error{type: :exchange_error, message: message}} =
               dispatch(exchange, :fetch_funding_rate,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "fetchFundingRate()")
      assert String.contains?(message, @symbol)
    end

    test "fetch_isolated_borrow_rate returns error when not found" do
      exchange_id = exchange_for_method("fetchIsolatedBorrowRate")

      exchange =
        build_exchange(exchange_id, [:fetch_isolated_borrow_rates], auth_methods: [:fetch_isolated_borrow_rates])

      Process.put(:isolated_borrow_rates, %{})

      assert {:error, %Bourse.Error{type: :exchange_error, message: message}} =
               dispatch(exchange, :fetch_isolated_borrow_rate,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "fetchIsolatedBorrowRate()")
      assert String.contains?(message, @symbol)
    end

    test "fetch_deposit_address returns error when code is missing" do
      exchange_id = exchange_for_method("fetchDepositAddress")

      exchange =
        build_exchange(exchange_id, [:fetch_deposit_addresses], auth_methods: [:fetch_deposit_addresses])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_deposit_address, credentials: @credentials)

      assert String.contains?(message, "requires a code argument")
    end
  end

  describe "currency derivation edge cases" do
    test "fetch_currencies picks highest precision when multiple markets share base" do
      exchange = build_exchange("test_exchange", [:fetch_markets])

      Process.put(:markets, [
        %{
          symbol: "BTC/USDT",
          base: "BTC",
          quote: "USDT",
          base_id: "btc",
          quote_id: "usdt",
          precision: %{base: 4, quote: 2}
        },
        %{
          symbol: "BTC/EUR",
          base: "BTC",
          quote: "EUR",
          base_id: "btc",
          quote_id: "eur",
          precision: %{base: 8, quote: 4}
        }
      ])

      assert {:ok, currencies} =
               Emulation.handle_fetch_currencies(exchange, ExchangeStub, %{}, __emulation_caller__: stub_caller())

      # BTC appears in both markets - should pick highest precision (8)
      assert currencies["BTC"][:precision] == 8
    end

    test "fetch_currencies uses fallback precision when market has nil precision" do
      exchange = build_exchange("test_exchange", [:fetch_markets])

      Process.put(:markets, [
        %{
          symbol: "XYZ/USDT",
          base: "XYZ",
          quote: "USDT",
          base_id: "xyz",
          quote_id: "usdt",
          precision: %{}
        }
      ])

      assert {:ok, currencies} =
               Emulation.handle_fetch_currencies(exchange, ExchangeStub, %{}, __emulation_caller__: stub_caller())

      # Default precision fallback is 1.0e-8
      assert currencies["XYZ"][:precision] == 1.0e-8
    end

    test "fetch_currencies handles market with nil base gracefully" do
      exchange = build_exchange("test_exchange", [:fetch_markets])

      Process.put(:markets, [
        %{
          symbol: "BTC/USDT",
          base: nil,
          quote: "USDT",
          base_id: nil,
          quote_id: "usdt",
          precision: %{quote: 2}
        }
      ])

      assert {:ok, currencies} =
               Emulation.handle_fetch_currencies(exchange, ExchangeStub, %{}, __emulation_caller__: stub_caller())

      # nil base should be skipped, but USDT from quote should exist
      refute Map.has_key?(currencies, nil)
      assert Map.has_key?(currencies, "USDT")
    end
  end

  describe "fetch_market and ensure_contract_market edge cases" do
    test "fetch_funding_rate returns error for unknown symbol" do
      exchange_id = exchange_for_method("fetchFundingRate")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_funding_rates], auth_methods: [:fetch_funding_rates])

      Process.put(:markets, [%{symbol: @other_symbol, contract: true}])
      Process.put(:funding_rates, %{})

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_funding_rate,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "Unknown market symbol")
    end

    test "fetch_market_leverage_tiers returns error for unknown symbol" do
      exchange_id = exchange_for_method("fetchMarketLeverageTiers")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_leverage_tiers], auth_methods: [:fetch_leverage_tiers])

      Process.put(:markets, [])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_market_leverage_tiers,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "Unknown market symbol")
    end

    test "ensure_contract_market returns error when symbol is nil" do
      exchange_id = exchange_for_method("fetchFundingRate")

      exchange =
        build_exchange(exchange_id, [:fetch_markets, :fetch_funding_rates], auth_methods: [:fetch_funding_rates])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_funding_rate,
                 params: %{},
                 credentials: @credentials
               )

      assert String.contains?(message, "requires a symbol argument")
    end
  end

  describe "fetch_deposits_withdrawals edge cases" do
    test "returns not_supported when no deposit/withdrawal/ledger endpoints" do
      exchange_id = exchange_for_method("fetchDepositsWithdrawals")
      exchange = build_exchange(exchange_id, [])

      assert {:error, %Bourse.Error{type: :not_supported, message: message}} =
               dispatch(exchange, :fetch_deposits_withdrawals, credentials: @credentials)

      assert String.contains?(message, "fetchDepositsWithdrawals() is not supported yet")
    end
  end

  describe "fetch_order edge cases" do
    test "returns not_supported when no order endpoints at all" do
      exchange_id = exchange_for_method("fetchOrder")
      exchange = build_exchange(exchange_id, [])

      assert {:error, %Bourse.Error{type: :not_supported, message: message}} =
               dispatch(exchange, :fetch_order,
                 params: %{id: @order_id, symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "fetchOrder() is not supported yet")
    end

    test "returns error when id is nil" do
      exchange_id = exchange_for_method("fetchOrder")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_order,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "requires an id argument")
    end
  end

  describe "empty result edge cases" do
    test "fetch_ticker returns error when tickers map is empty" do
      exchange_id = exchange_for_method("fetchTicker")
      exchange = build_exchange(exchange_id, [:fetch_tickers])

      Process.put(:tickers, %{})

      assert {:error, %Bourse.Error{type: :exchange_error, message: message}} =
               dispatch(exchange, :fetch_ticker, params: %{symbol: @symbol})

      assert String.contains?(message, "could not find a ticker for")
    end

    test "fetch_my_trades returns empty when orders have no trades" do
      exchange_id = exchange_for_method("fetchMyTrades")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: @order_id, trades: nil},
        %{id: "order-2", trades: []}
      ])

      assert {:ok, []} =
               dispatch(exchange, :fetch_my_trades,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_position deliberately returns nil when the account is flat for the symbol" do
      exchange_id = exchange_for_method("fetchPosition")
      exchange = build_exchange(exchange_id, [:fetch_positions], auth_methods: [:fetch_positions])

      Process.put(:positions, [])

      assert {:ok, nil} =
               dispatch(exchange, :fetch_position,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end
  end

  describe "infer_ascending and since/limit edge cases" do
    test "fetch_closed_orders handles single-element list with since/limit" do
      exchange_id = exchange_for_method("fetchClosedOrders")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: @order_id, status: "closed", timestamp: @timestamp_new}
      ])

      assert {:ok, [%{id: @order_id}]} =
               dispatch(exchange, :fetch_closed_orders,
                 params: %{symbol: @symbol, since: @timestamp_old, limit: @limit_one},
                 credentials: @credentials
               )
    end

    test "fetch_closed_orders handles entries with nil timestamps" do
      exchange_id = exchange_for_method("fetchClosedOrders")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: "no-ts", status: "closed", timestamp: nil},
        %{id: @order_id, status: "closed", timestamp: @timestamp_new}
      ])

      # With since filter, nil timestamps are excluded
      assert {:ok, [%{id: @order_id}]} =
               dispatch(exchange, :fetch_closed_orders,
                 params: %{symbol: @symbol, since: @timestamp_old},
                 credentials: @credentials
               )
    end
  end

  describe "normalize_status with atom input" do
    test "fetch_open_orders filters orders with atom status" do
      exchange_id = exchange_for_method("fetchOpenOrders")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: "atom-open", status: :open, timestamp: @timestamp_new},
        %{id: "atom-closed", status: :closed, timestamp: @timestamp_new}
      ])

      assert {:ok, [%{id: "atom-open"}]} =
               dispatch(exchange, :fetch_open_orders,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )
    end
  end

  describe "dispatch_entry edge cases" do
    test "dispatch returns error when exchange_module is nil" do
      exchange_id = exchange_for_method("fetchTicker")
      exchange = build_exchange(exchange_id, [:fetch_tickers])

      Process.put(:tickers, %{@symbol => %{symbol: @symbol}})

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               Emulation.dispatch(exchange, :fetch_ticker, :rest, %{
                 exchange_module: nil,
                 params: %{symbol: @symbol}
               })

      assert String.contains?(message, "missing exchange module")
    end

    test "dispatch returns error when exchange_module key is missing" do
      exchange_id = exchange_for_method("fetchTicker")
      exchange = build_exchange(exchange_id, [:fetch_tickers])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               Emulation.dispatch(exchange, :fetch_ticker, :rest, %{
                 params: %{symbol: @symbol}
               })

      assert String.contains?(message, "missing exchange module")
    end

    test "accepts and uses injected caller for nested calls" do
      exchange_id = exchange_for_method("fetchBidsAsks")
      exchange = build_exchange(exchange_id, [:fetch_bids_asks, :fetch_tickers])

      caller = fn _ex, _mod, meth, _p, _o -> {:ok, {:called_via, meth}} end

      assert {:ok, {:called_via, :fetch_tickers}} =
               Emulation.dispatch(exchange, :fetch_bids_asks, :rest, %{
                 exchange_module: ExchangeStub,
                 params: %{symbol: @symbol},
                 caller: caller
               })
    end
  end

  describe "fetch_order_trades edge cases" do
    test "fetch_order_trades returns error when id is nil" do
      exchange_id = exchange_for_method("fetchOrderTrades")
      exchange = build_exchange(exchange_id, [:fetch_my_trades], auth_methods: [:fetch_my_trades])

      assert {:error, %Bourse.Error{type: :invalid_parameters, message: message}} =
               dispatch(exchange, :fetch_order_trades,
                 params: %{symbol: @symbol},
                 credentials: @credentials
               )

      assert String.contains?(message, "requires an id argument")
    end
  end

  describe "helper edge cases" do
    test "fetch_order_trades finds trades by camelCase orderId field" do
      exchange_id = exchange_for_method("fetchOrderTrades")
      exchange = build_exchange(exchange_id, [:fetch_my_trades], auth_methods: [:fetch_my_trades])

      Process.put(:my_trades, [
        %{"id" => @trade_id, "orderId" => @order_id, "symbol" => @symbol},
        %{"id" => "other-trade", "orderId" => "other-order", "symbol" => @symbol}
      ])

      assert {:ok, [%{"id" => @trade_id}]} =
               dispatch(exchange, :fetch_order_trades,
                 params: %{id: @order_id, symbol: @symbol},
                 credentials: @credentials
               )
    end

    test "fetch_deposit_address resolves first network when network is nil" do
      exchange_id = exchange_for_method("fetchDepositAddress")

      exchange =
        build_exchange(exchange_id, [:fetch_deposit_addresses_by_network],
          auth_methods: [:fetch_deposit_addresses_by_network]
        )

      Process.put(:deposit_addresses_by_network, %{
        "ERC20" => %{address: "0xfirst", network: "ERC20"},
        "TRC20" => %{address: "Tsecond", network: "TRC20"}
      })

      assert {:ok, %{address: address}} =
               dispatch(exchange, :fetch_deposit_address,
                 params: %{code: @code},
                 credentials: @credentials
               )

      assert address in ["0xfirst", "Tsecond"]
    end

    test "fetch_canceled_and_closed_orders with since and limit" do
      exchange_id = exchange_for_method("fetchCanceledAndClosedOrders")
      exchange = build_exchange(exchange_id, [:fetch_orders], auth_methods: [:fetch_orders])

      Process.put(:orders, [
        %{id: "closed-old", status: "closed", timestamp: @timestamp_old},
        %{id: "canceled-new", status: "canceled", timestamp: @timestamp_new},
        %{id: "closed-latest", status: "closed", timestamp: @timestamp_latest},
        %{id: "open-1", status: "open", timestamp: @timestamp_new}
      ])

      assert {:ok, orders} =
               dispatch(exchange, :fetch_canceled_and_closed_orders,
                 params: %{symbol: @symbol, since: @timestamp_new, limit: @limit_one},
                 credentials: @credentials
               )

      assert length(orders) == 1
      refute "open-1" in Enum.map(orders, & &1.id)
    end
  end

  defp dispatch(exchange, method, opts \\ []) do
    exchange =
      case Keyword.get(opts, :credentials) do
        nil -> exchange
        credentials -> %{exchange | credentials: credentials}
      end

    Emulation.dispatch_declared(
      exchange,
      method,
      %{"name" => Atom.to_string(method), "reasons" => ["strategy_test"], "scope" => "rest"},
      %{
        exchange_module: ExchangeStub,
        params: Keyword.get(opts, :params, %{}),
        opts: Keyword.get(opts, :extra_opts, []),
        caller: stub_caller()
      }
    )
  end

  defp assert_missing_symbol_error(result, symbol) do
    assert {:error, %Bourse.Error{type: :exchange_error, message: message}} = result
    assert String.contains?(message, symbol)
  end

  setup do
    Process.delete({ExchangeStub, :endpoints})
    :ok
  end

  defp build_exchange(exchange_id, endpoint_names, opts \\ []) do
    auth_methods = Keyword.get(opts, :auth_methods, [])
    endpoint_configs = Keyword.get(opts, :endpoint_configs, %{})

    endpoints =
      Map.new(endpoint_names, fn name ->
        configs = Map.get(endpoint_configs, name, [%{name: name, authenticated: name in auth_methods}])
        {name, configs}
      end)

    ExchangeStub.configure_endpoints!(endpoints)

    %Exchange{
      id: exchange_id,
      name: "emulation_strategies_test",
      module: ExchangeStub
    }
  end

  # Uses a real declaration when available; strategy-unit coverage is independent
  # of which methods the closed runtime inventory happens to declare.
  defp exchange_for_method(method_name) do
    Enum.find_value(EmulatedMethods.exchanges(), "binance", fn exchange_id ->
      if EmulatedMethods.method_for(exchange_id, method_name), do: exchange_id
    end)
  end

  # ---------------------------------------------------------------------------
  # Stub caller injection support (migrated from production emulation stub path)
  # The positional arg shaping and auth-prefix logic now lives only in test support.
  # ---------------------------------------------------------------------------

  @symbol_since_limit_methods [
    :fetch_orders,
    :fetch_open_orders,
    :fetch_closed_orders,
    :fetch_canceled_orders,
    :fetch_my_trades
  ]

  @code_since_limit_methods [:fetch_deposits, :fetch_withdrawals, :fetch_ledger]

  defp stub_positional_args(method, params) when method in @symbol_since_limit_methods do
    [extract_param(params, :symbol), extract_param(params, :since), extract_param(params, :limit)]
  end

  defp stub_positional_args(method, params) when method in @code_since_limit_methods do
    [extract_param(params, :code), extract_param(params, :since), extract_param(params, :limit)]
  end

  defp stub_positional_args(:fetch_tickers, params) do
    [normalize_symbols(extract_param(params, :symbols) || extract_param(params, :symbol))]
  end

  defp stub_positional_args(:fetch_trading_fees, _params), do: []

  defp stub_positional_args(:fetch_deposit_withdraw_fees, params) do
    [Enum.reject([extract_param(params, :code)], &is_nil/1)]
  end

  defp stub_positional_args(:fetch_transaction_fees, params) do
    [Enum.reject([extract_param(params, :code)], &is_nil/1)]
  end

  defp stub_positional_args(:fetch_deposit_addresses, params) do
    [Enum.reject([extract_param(params, :code)], &is_nil/1)]
  end

  defp stub_positional_args(:fetch_leverages, params) do
    [normalize_symbols(extract_param(params, :symbol))]
  end

  defp stub_positional_args(:fetch_margin_modes, params) do
    [normalize_symbols(extract_param(params, :symbol))]
  end

  defp stub_positional_args(:fetch_leverage_tiers, params) do
    [normalize_symbols(extract_param(params, :symbol))]
  end

  defp stub_positional_args(:fetch_funding_rates, params) do
    [normalize_symbols(extract_param(params, :symbol))]
  end

  defp stub_positional_args(:fetch_funding_intervals, params) do
    [normalize_symbols(extract_param(params, :symbol))]
  end

  defp stub_positional_args(:fetch_positions, params) do
    [normalize_symbols(extract_param(params, :symbol))]
  end

  defp stub_positional_args(:fetch_positions_history, params) do
    [
      normalize_symbols(extract_param(params, :symbol)),
      extract_param(params, :since),
      extract_param(params, :limit)
    ]
  end

  defp stub_positional_args(:fetch_deposit_addresses_by_network, params) do
    [extract_param(params, :code)]
  end

  defp stub_positional_args(_method, _params), do: []

  defp stub_caller do
    fn exchange, module, method, params, opts ->
      auth = auth_required?(module, method)
      args = stub_positional_args(method, params)

      if auth do
        apply(module, method, [exchange.credentials | args] ++ [opts])
      else
        apply(module, method, args ++ [opts])
      end
    end
  end

  defp auth_required?(module, method) when is_atom(method) do
    method
    |> module.__unified_endpoint__()
    |> Enum.all?(&Map.get(&1, :authenticated, false))
  end

  defp normalize_symbols(nil), do: nil
  defp normalize_symbols(symbols) when is_list(symbols), do: symbols
  defp normalize_symbols(symbol) when is_binary(symbol), do: [symbol]
  defp normalize_symbols(_), do: nil

  defp extract_param(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
