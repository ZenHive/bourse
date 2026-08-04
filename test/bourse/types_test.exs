defmodule Bourse.TypesTest do
  use ExUnit.Case, async: true

  describe "Bourse.Fee" do
    test "creates struct with all fields nil by default" do
      fee = %Bourse.Fee{}
      assert is_nil(fee.currency)
      assert is_nil(fee.cost)
      assert is_nil(fee.rate)
    end

    test "creates struct with values" do
      fee = %Bourse.Fee{currency: "USDT", cost: 0.5, rate: 0.001}
      assert fee.currency == "USDT"
      assert fee.cost == 0.5
      assert fee.rate == 0.001
    end
  end

  describe "Bourse.Credentials" do
    test "new/1 creates credentials with required fields" do
      assert {:ok, creds} = Bourse.Credentials.new(api_key: "abc", secret: "xyz")
      assert creds.api_key == "abc"
      assert creds.secret == "xyz"
      assert creds.sandbox == false
    end

    test "new/1 accepts optional fields" do
      assert {:ok, creds} =
               Bourse.Credentials.new(
                 api_key: "abc",
                 secret: "xyz",
                 password: "pass",
                 uid: "123",
                 sandbox: true
               )

      assert creds.password == "pass"
      assert creds.uid == "123"
      assert creds.sandbox == true
    end

    test "new/1 returns error when api_key is missing" do
      assert {:error, :missing_api_key} = Bourse.Credentials.new(secret: "xyz")
    end

    test "new/1 returns error when secret is missing" do
      assert {:error, :missing_secret} = Bourse.Credentials.new(api_key: "abc")
    end

    test "new!/1 creates credentials" do
      creds = Bourse.Credentials.new!(api_key: "abc", secret: "xyz")
      assert creds.api_key == "abc"
    end

    test "new!/1 raises on missing api_key" do
      assert_raise ArgumentError, "api_key is required", fn ->
        Bourse.Credentials.new!(secret: "xyz")
      end
    end

    test "new!/1 raises on missing secret" do
      assert_raise ArgumentError, "secret is required", fn ->
        Bourse.Credentials.new!(api_key: "abc")
      end
    end

    test "new/1 returns error on unknown key" do
      assert {:error, {:unknown_key, :bogus}} =
               Bourse.Credentials.new(api_key: "abc", secret: "xyz", bogus: "bad")
    end

    test "new!/1 raises on unknown key" do
      assert_raise ArgumentError, ~r/unknown key: :bogus/, fn ->
        Bourse.Credentials.new!(api_key: "abc", secret: "xyz", bogus: "bad")
      end
    end

    test "new/1 returns error when api_key is not a string" do
      assert {:error, {:invalid_type, :api_key}} =
               Bourse.Credentials.new(api_key: 123, secret: "xyz")
    end

    test "new/1 returns error when secret is not a string" do
      assert {:error, {:invalid_type, :secret}} =
               Bourse.Credentials.new(api_key: "abc", secret: :bad)
    end

    test "new!/1 raises on invalid type" do
      assert_raise ArgumentError, ~r/api_key must be a string/, fn ->
        Bourse.Credentials.new!(api_key: 123, secret: "xyz")
      end
    end
  end

  describe "Bourse.Ticker" do
    test "creates struct with all fields nil by default" do
      ticker = %Bourse.Ticker{}
      assert is_nil(ticker.symbol)
      assert is_nil(ticker.last)
      assert is_nil(ticker.info)
    end

    test "creates struct with populated fields" do
      ticker = %Bourse.Ticker{
        symbol: "BTC/USDT",
        last: 28_000.0,
        bid: 27_999.0,
        ask: 28_001.0,
        base_volume: 1500.0,
        info: %{"raw" => "data"}
      }

      assert ticker.symbol == "BTC/USDT"
      assert ticker.last == 28_000.0
      assert ticker.bid == 27_999.0
      assert ticker.ask == 28_001.0
    end
  end

  describe "Bourse.Trade" do
    test "creates struct with all fields nil by default" do
      trade = %Bourse.Trade{}
      assert is_nil(trade.id)
      assert is_nil(trade.fee)
    end

    test "creates struct with nested fee" do
      trade = %Bourse.Trade{
        id: "t1",
        symbol: "BTC/USDT",
        side: "buy",
        price: 28_000.0,
        amount: 0.1,
        cost: 2800.0,
        fee: %Bourse.Fee{currency: "USDT", cost: 2.8}
      }

      assert trade.price == 28_000.0
      assert trade.fee.currency == "USDT"
    end
  end

  describe "Bourse.Order" do
    test "creates struct with defaults" do
      order = %Bourse.Order{}
      assert order.trades == []
      assert is_nil(order.status)
    end

    test "open?/1 returns true for open orders" do
      assert Bourse.Order.open?(%Bourse.Order{status: "open"})
      refute Bourse.Order.open?(%Bourse.Order{status: "closed"})
      refute Bourse.Order.open?(%Bourse.Order{})
    end

    test "closed?/1 returns true for closed orders" do
      assert Bourse.Order.closed?(%Bourse.Order{status: "closed"})
      refute Bourse.Order.closed?(%Bourse.Order{status: "open"})
    end

    test "canceled?/1 returns true for canceled orders" do
      assert Bourse.Order.canceled?(%Bourse.Order{status: "canceled"})
      refute Bourse.Order.canceled?(%Bourse.Order{status: "open"})
    end

    test "filled?/1 returns true when filled equals amount" do
      assert Bourse.Order.filled?(%Bourse.Order{filled: 1.0, amount: 1.0})
      assert Bourse.Order.filled?(%Bourse.Order{filled: 1.5, amount: 1.0})
    end

    test "filled?/1 returns false for partial fills" do
      refute Bourse.Order.filled?(%Bourse.Order{filled: 0.5, amount: 1.0})
    end

    test "filled?/1 returns false for nil values" do
      refute Bourse.Order.filled?(%Bourse.Order{filled: nil, amount: 1.0})
      refute Bourse.Order.filled?(%Bourse.Order{filled: 1.0, amount: nil})
      refute Bourse.Order.filled?(%Bourse.Order{})
    end

    test "filled?/1 returns false for zero amount" do
      refute Bourse.Order.filled?(%Bourse.Order{filled: 0, amount: 0})
    end

    test "creates struct with nested fee and trades" do
      order = %Bourse.Order{
        id: "o1",
        symbol: "BTC/USDT",
        status: "closed",
        fee: %Bourse.Fee{currency: "USDT", cost: 5.6},
        trades: [%Bourse.Trade{id: "t1", price: 28_000.0, amount: 0.1}]
      }

      assert length(order.trades) == 1
      assert order.fee.cost == 5.6
    end
  end

  describe "Bourse.Balance" do
    setup do
      balance = %Bourse.Balance{
        free: %{"BTC" => 1.5, "USDT" => 10_000.0},
        used: %{"BTC" => 0.5},
        total: %{"BTC" => 2.0, "USDT" => 10_000.0}
      }

      {:ok, balance: balance}
    end

    test "creates struct with empty map defaults" do
      balance = %Bourse.Balance{}
      assert balance.free == %{}
      assert balance.used == %{}
      assert balance.total == %{}
    end

    test "get/2 returns balance for known currency", %{balance: balance} do
      result = Bourse.Balance.get(balance, "BTC")
      assert result == %{free: 1.5, used: 0.5, total: 2.0}
    end

    test "get/2 defaults missing categories to 0.0", %{balance: balance} do
      result = Bourse.Balance.get(balance, "USDT")
      assert result == %{free: 10_000.0, used: 0.0, total: 10_000.0}
    end

    test "get/2 returns nil for unknown currency", %{balance: balance} do
      assert is_nil(Bourse.Balance.get(balance, "DOGE"))
    end

    test "currencies/1 returns sorted unique list", %{balance: balance} do
      assert Bourse.Balance.currencies(balance) == ["BTC", "USDT"]
    end

    test "currencies/1 returns empty list for empty balance" do
      assert Bourse.Balance.currencies(%Bourse.Balance{}) == []
    end
  end

  describe "Bourse.OHLCV" do
    test "from_list/1 creates struct from candle array" do
      ohlcv = Bourse.OHLCV.from_list([1_680_000_000_000, 28_000.0, 28_500.0, 27_800.0, 28_200.0, 150.5])
      assert ohlcv.timestamp == 1_680_000_000_000
      assert ohlcv.open == 28_000.0
      assert ohlcv.high == 28_500.0
      assert ohlcv.low == 27_800.0
      assert ohlcv.close == 28_200.0
      assert ohlcv.volume == 150.5
    end

    test "from_list/1 handles nil values" do
      ohlcv = Bourse.OHLCV.from_list([1_680_000_000_000, nil, nil, nil, nil, nil])
      assert ohlcv.timestamp == 1_680_000_000_000
      assert is_nil(ohlcv.open)
      assert is_nil(ohlcv.volume)
    end

    test "enforces timestamp key" do
      assert_raise ArgumentError, fn ->
        struct!(Bourse.OHLCV, open: 1.0)
      end
    end
  end

  describe "Bourse.Market" do
    test "creates struct with all fields nil by default" do
      market = %Bourse.Market{}
      assert is_nil(market.id)
      assert is_nil(market.type)
      assert is_nil(market.spot)
    end

    test "creates spot market" do
      market = %Bourse.Market{
        id: "BTCUSDT",
        symbol: "BTC/USDT",
        base: "BTC",
        quote: "USDT",
        type: "spot",
        spot: true,
        active: true,
        taker: 0.001,
        maker: 0.001
      }

      assert market.type == "spot"
      assert market.spot == true
      assert market.taker == 0.001
    end

    test "creates derivatives market" do
      market = %Bourse.Market{
        id: "BTCUSDT",
        symbol: "BTC/USDT:USDT",
        type: "swap",
        swap: true,
        contract: true,
        linear: true,
        contract_size: 1.0,
        settle: "USDT"
      }

      assert market.type == "swap"
      assert market.linear == true
      assert market.contract_size == 1.0
    end

    test "creates options market" do
      market = %Bourse.Market{
        type: "option",
        option: true,
        strike: 30_000.0,
        option_type: "call",
        expiry: 1_700_000_000_000,
        expiry_datetime: "2023-11-14T00:00:00.000Z"
      }

      assert market.strike == 30_000.0
      assert market.option_type == "call"
    end
  end

  # --- Task 43: Missing Unified Type Structs ---

  describe "Bourse.OrderBook" do
    test "creates struct with empty list defaults" do
      ob = %Bourse.OrderBook{}
      assert ob.bids == []
      assert ob.asks == []
      assert is_nil(ob.symbol)
    end

    test "creates struct with populated fields" do
      ob = %Bourse.OrderBook{
        symbol: "BTC/USDT",
        bids: [[28_000.0, 1.5], [27_999.0, 2.0]],
        asks: [[28_001.0, 0.8], [28_002.0, 1.2]],
        nonce: 42,
        timestamp: 1_680_000_000_000,
        info: %{"raw" => true}
      }

      assert ob.symbol == "BTC/USDT"
      assert length(ob.bids) == 2
      assert ob.nonce == 42
    end

    test "best_bid/1 returns highest bid price" do
      ob = %Bourse.OrderBook{bids: [[28_000.0, 1.5], [27_999.0, 2.0]]}
      assert Bourse.OrderBook.best_bid(ob) == 28_000.0
    end

    test "best_bid/1 returns nil for empty bids" do
      assert is_nil(Bourse.OrderBook.best_bid(%Bourse.OrderBook{}))
    end

    test "best_ask/1 returns lowest ask price" do
      ob = %Bourse.OrderBook{asks: [[28_001.0, 0.8]]}
      assert Bourse.OrderBook.best_ask(ob) == 28_001.0
    end

    test "best_ask/1 returns nil for empty asks" do
      assert is_nil(Bourse.OrderBook.best_ask(%Bourse.OrderBook{}))
    end

    test "spread/1 returns ask - bid" do
      ob = %Bourse.OrderBook{
        bids: [[28_000.0, 1.5]],
        asks: [[28_001.0, 0.8]]
      }

      assert Bourse.OrderBook.spread(ob) == 1.0
    end

    test "spread/1 returns nil when either side is empty" do
      assert is_nil(Bourse.OrderBook.spread(%Bourse.OrderBook{bids: [[1.0, 1.0]]}))
      assert is_nil(Bourse.OrderBook.spread(%Bourse.OrderBook{asks: [[1.0, 1.0]]}))
      assert is_nil(Bourse.OrderBook.spread(%Bourse.OrderBook{}))
    end

    test "spread/1 returns negative for crossed book" do
      ob = %Bourse.OrderBook{
        bids: [[28_002.0, 1.0]],
        asks: [[28_000.0, 1.0]]
      }

      assert Bourse.OrderBook.spread(ob) == -2.0
    end

    test "best_bid/1 returns nil for nil bids" do
      ob = %Bourse.OrderBook{bids: nil}
      assert is_nil(Bourse.OrderBook.best_bid(ob))
    end

    test "best_ask/1 returns nil for nil asks" do
      ob = %Bourse.OrderBook{asks: nil}
      assert is_nil(Bourse.OrderBook.best_ask(ob))
    end

    test "best_bid/1 returns nil for malformed level with nil price" do
      ob = %Bourse.OrderBook{bids: [[nil, 1.0]]}
      assert is_nil(Bourse.OrderBook.best_bid(ob))
    end

    test "best_ask/1 returns nil for malformed level with nil price" do
      ob = %Bourse.OrderBook{asks: [[nil, 1.0]]}
      assert is_nil(Bourse.OrderBook.best_ask(ob))
    end

    test "spread/1 returns nil when bid price is nil" do
      ob = %Bourse.OrderBook{bids: [[nil, 1.0]], asks: [[2.0, 1.0]]}
      assert is_nil(Bourse.OrderBook.spread(ob))
    end

    test "spread/1 returns nil when ask price is nil" do
      ob = %Bourse.OrderBook{bids: [[2.0, 1.0]], asks: [[nil, 1.0]]}
      assert is_nil(Bourse.OrderBook.spread(ob))
    end

    test "spread/1 returns nil for nil bids" do
      ob = %Bourse.OrderBook{bids: nil, asks: [[2.0, 1.0]]}
      assert is_nil(Bourse.OrderBook.spread(ob))
    end
  end

  describe "Bourse.Position" do
    test "creates struct with all fields nil by default" do
      pos = %Bourse.Position{}
      assert is_nil(pos.symbol)
      assert is_nil(pos.side)
      assert is_nil(pos.leverage)
    end

    test "creates long position" do
      pos = %Bourse.Position{
        symbol: "BTC/USDT:USDT",
        side: "long",
        contracts: 10.0,
        leverage: 5.0,
        entry_price: 28_000.0,
        unrealized_pnl: 500.0
      }

      assert pos.contracts == 10.0
      assert pos.leverage == 5.0
    end

    test "long?/1 returns true for long positions" do
      assert Bourse.Position.long?(%Bourse.Position{side: "long"})
      refute Bourse.Position.long?(%Bourse.Position{side: "short"})
      refute Bourse.Position.long?(%Bourse.Position{})
    end

    test "short?/1 returns true for short positions" do
      assert Bourse.Position.short?(%Bourse.Position{side: "short"})
      refute Bourse.Position.short?(%Bourse.Position{side: "long"})
    end

    test "profitable?/1 returns true for positive PnL" do
      assert Bourse.Position.profitable?(%Bourse.Position{unrealized_pnl: 100.0})
      refute Bourse.Position.profitable?(%Bourse.Position{unrealized_pnl: -50.0})
      refute Bourse.Position.profitable?(%Bourse.Position{unrealized_pnl: 0})
      refute Bourse.Position.profitable?(%Bourse.Position{})
    end
  end

  describe "Bourse.Currency" do
    test "defaults match Bourse safeCurrencyStructure (nil networks, empty fees, nil-limits)" do
      curr = %Bourse.Currency{}
      assert is_nil(curr.networks)
      assert is_nil(curr.code)
      assert curr.fees == %{}
      assert is_nil(curr.limits)
    end

    test "creates currency with populated fields" do
      curr = %Bourse.Currency{
        id: "BTC",
        code: "BTC",
        name: "Bitcoin",
        type: "crypto",
        active: true,
        deposit: true,
        withdraw: true,
        precision: 8,
        networks: %{"ERC20" => %{}, "BTC" => %{}}
      }

      assert curr.code == "BTC"
      assert curr.active == true
      assert map_size(curr.networks) == 2
    end
  end

  describe "Bourse.Transaction" do
    test "creates struct with all fields nil by default" do
      tx = %Bourse.Transaction{}
      assert is_nil(tx.id)
      assert is_nil(tx.type)
    end

    test "creates deposit transaction" do
      tx = %Bourse.Transaction{
        id: "tx1",
        type: "deposit",
        currency: "BTC",
        amount: 0.5,
        status: "ok",
        address: "bc1q...",
        fee: %Bourse.Fee{currency: "BTC", cost: 0.0001}
      }

      assert tx.amount == 0.5
      assert tx.fee.cost == 0.0001
    end

    test "deposit?/1 returns true for deposits" do
      assert Bourse.Transaction.deposit?(%Bourse.Transaction{type: "deposit"})
      refute Bourse.Transaction.deposit?(%Bourse.Transaction{type: "withdrawal"})
      refute Bourse.Transaction.deposit?(%Bourse.Transaction{})
    end

    test "withdrawal?/1 returns true for withdrawals" do
      assert Bourse.Transaction.withdrawal?(%Bourse.Transaction{type: "withdrawal"})
      refute Bourse.Transaction.withdrawal?(%Bourse.Transaction{type: "deposit"})
    end

    test "pending?/1 returns true for pending transactions" do
      assert Bourse.Transaction.pending?(%Bourse.Transaction{status: "pending"})
      refute Bourse.Transaction.pending?(%Bourse.Transaction{status: "ok"})
      refute Bourse.Transaction.pending?(%Bourse.Transaction{})
    end
  end

  describe "Bourse.LedgerEntry" do
    test "creates struct with all fields nil by default" do
      entry = %Bourse.LedgerEntry{}
      assert is_nil(entry.id)
      assert is_nil(entry.direction)
    end

    test "creates ledger entry with populated fields" do
      entry = %Bourse.LedgerEntry{
        id: "le1",
        direction: "in",
        type: "trade",
        currency: "USDT",
        amount: 100.0,
        before: 1000.0,
        after: 1100.0,
        fee: %Bourse.Fee{currency: "USDT", cost: 0.1}
      }

      assert entry.direction == "in"
      assert entry.after == 1100.0
      assert entry.fee.cost == 0.1
    end
  end

  describe "Bourse.FundingRate" do
    test "creates struct with all fields nil by default" do
      fr = %Bourse.FundingRate{}
      assert is_nil(fr.symbol)
      assert is_nil(fr.funding_rate)
    end

    test "creates funding rate with populated fields" do
      fr = %Bourse.FundingRate{
        symbol: "BTC/USDT:USDT",
        funding_rate: 0.0001,
        mark_price: 28_000.0,
        index_price: 27_999.0,
        interval: "8h",
        timestamp: 1_680_000_000_000
      }

      assert fr.funding_rate == 0.0001
      assert fr.interval == "8h"
    end
  end

  describe "Bourse.DepositAddress" do
    test "creates struct with all fields nil by default" do
      da = %Bourse.DepositAddress{}
      assert is_nil(da.currency)
      assert is_nil(da.address)
    end

    test "creates deposit address with populated fields" do
      da = %Bourse.DepositAddress{
        currency: "BTC",
        network: "BTC",
        address: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
        tag: nil
      }

      assert da.currency == "BTC"
      assert da.network == "BTC"
    end
  end

  describe "Bourse.TransferEntry" do
    test "creates struct with all fields nil by default" do
      te = %Bourse.TransferEntry{}
      assert is_nil(te.id)
      assert is_nil(te.from_account)
    end

    test "creates transfer with populated fields" do
      te = %Bourse.TransferEntry{
        id: "tr1",
        currency: "USDT",
        amount: 1000.0,
        from_account: "spot",
        to_account: "futures",
        status: "ok"
      }

      assert te.from_account == "spot"
      assert te.to_account == "futures"
    end
  end

  describe "Bourse.TradingFee" do
    test "creates struct with all fields nil by default" do
      tf = %Bourse.TradingFee{}
      assert is_nil(tf.symbol)
      assert is_nil(tf.maker)
    end

    test "creates trading fee with populated fields" do
      tf = %Bourse.TradingFee{
        symbol: "BTC/USDT",
        maker: 0.001,
        taker: 0.002,
        percentage: true,
        tier_based: true
      }

      assert tf.maker == 0.001
      assert tf.taker == 0.002
    end
  end

  describe "Bourse.Leverage" do
    test "creates struct with all fields nil by default" do
      lev = %Bourse.Leverage{}
      assert is_nil(lev.symbol)
      assert is_nil(lev.long_leverage)
    end

    test "creates leverage with populated fields" do
      lev = %Bourse.Leverage{
        symbol: "BTC/USDT:USDT",
        margin_mode: "cross",
        long_leverage: 10.0,
        short_leverage: 10.0
      }

      assert lev.long_leverage == 10.0
      assert lev.margin_mode == "cross"
    end
  end

  describe "Bourse.OpenInterest" do
    test "creates struct with all fields nil by default" do
      oi = %Bourse.OpenInterest{}
      assert is_nil(oi.symbol)
      assert is_nil(oi.open_interest_amount)
    end

    test "creates open interest with populated fields" do
      oi = %Bourse.OpenInterest{
        symbol: "BTC/USDT:USDT",
        open_interest_amount: 50_000.0,
        open_interest_value: 1_400_000_000.0,
        timestamp: 1_680_000_000_000
      }

      assert oi.open_interest_amount == 50_000.0
      assert oi.open_interest_value == 1_400_000_000.0
    end
  end

  describe "Bourse.Liquidation" do
    test "creates struct with all fields nil by default" do
      liq = %Bourse.Liquidation{}
      assert is_nil(liq.symbol)
      assert is_nil(liq.price)
    end

    test "creates liquidation with populated fields" do
      liq = %Bourse.Liquidation{
        symbol: "BTC/USDT:USDT",
        price: 27_000.0,
        contracts: 5.0,
        side: "long",
        timestamp: 1_680_000_000_000
      }

      assert liq.price == 27_000.0
      assert liq.side == "long"
    end
  end

  describe "Bourse.Greeks" do
    test "creates struct with all fields nil by default" do
      greeks = %Bourse.Greeks{}
      assert is_nil(greeks.delta)
      assert is_nil(greeks.gamma)
    end

    test "creates greeks with populated fields" do
      greeks = %Bourse.Greeks{
        symbol: "BTC/USDT:USDT-260116-30000-C",
        delta: 0.65,
        gamma: 0.02,
        theta: -15.5,
        vega: 45.0,
        rho: 2.1,
        mark_implied_volatility: 0.55,
        underlying_price: 28_000.0
      }

      assert greeks.delta == 0.65
      assert greeks.theta == -15.5
    end
  end

  describe "Bourse.OptionData" do
    test "creates struct with all fields nil by default" do
      opt = %Bourse.OptionData{}
      assert is_nil(opt.symbol)
      assert is_nil(opt.implied_volatility)
    end

    test "creates option data with populated fields" do
      opt = %Bourse.OptionData{
        symbol: "BTC/USDT:USDT-260116-30000-C",
        implied_volatility: 0.55,
        open_interest: 1000.0,
        bid_price: 2500.0,
        ask_price: 2550.0,
        mark_price: 2525.0,
        underlying_price: 28_000.0
      }

      assert opt.implied_volatility == 0.55
      assert opt.open_interest == 1000.0
    end
  end

  describe "Bourse.LeverageTier" do
    test "creates struct with all fields nil by default" do
      tier = %Bourse.LeverageTier{}
      assert is_nil(tier.tier)
      assert is_nil(tier.max_leverage)
    end

    test "creates leverage tier with populated fields" do
      tier = %Bourse.LeverageTier{
        tier: 1,
        symbol: "BTC/USDT:USDT",
        min_notional: 0.0,
        max_notional: 50_000.0,
        maintenance_margin_rate: 0.004,
        max_leverage: 125.0
      }

      assert tier.tier == 1
      assert tier.max_leverage == 125.0
    end
  end

  describe "Bourse.MarginMode" do
    test "creates struct with all fields nil by default" do
      mm = %Bourse.MarginMode{}
      assert is_nil(mm.symbol)
      assert is_nil(mm.margin_mode)
    end

    test "creates margin mode with populated fields" do
      mm = %Bourse.MarginMode{symbol: "BTC/USDT:USDT", margin_mode: "cross"}
      assert mm.margin_mode == "cross"
    end
  end

  describe "Bourse.MarginModification" do
    test "creates struct with all fields nil by default" do
      mod = %Bourse.MarginModification{}
      assert is_nil(mod.symbol)
      assert is_nil(mod.type)
    end

    test "creates margin modification with populated fields" do
      mod = %Bourse.MarginModification{
        symbol: "BTC/USDT:USDT",
        type: "add",
        margin_mode: "isolated",
        amount: 100.0,
        total: 600.0,
        code: "USDT",
        status: "ok"
      }

      assert mod.type == "add"
      assert mod.total == 600.0
    end
  end

  describe "Bourse.MarginLoan" do
    test "creates struct with all fields nil by default" do
      loan = %Bourse.MarginLoan{}
      assert is_nil(loan.currency)
      assert is_nil(loan.amount)
    end

    test "creates margin loan with populated fields" do
      loan = %Bourse.MarginLoan{currency: "BTC", amount: "0.001", info: %{"coin" => "BTC"}}
      assert loan.currency == "BTC"
      assert loan.amount == "0.001"
    end
  end

  describe "Bourse.LongShortRatio" do
    test "creates struct with all fields nil by default" do
      lsr = %Bourse.LongShortRatio{}
      assert is_nil(lsr.symbol)
      assert is_nil(lsr.long_short_ratio)
    end

    test "creates long/short ratio with populated fields" do
      lsr = %Bourse.LongShortRatio{
        symbol: "BTC/USDT:USDT",
        long_short_ratio: 1.25,
        timeframe: "1h",
        timestamp: 1_680_000_000_000
      }

      assert lsr.long_short_ratio == 1.25
      assert lsr.timeframe == "1h"
    end
  end

  describe "Bourse.FundingHistory" do
    test "creates struct with all fields nil by default" do
      fh = %Bourse.FundingHistory{}
      assert is_nil(fh.id)
      assert is_nil(fh.amount)
    end

    test "creates funding history with populated fields" do
      fh = %Bourse.FundingHistory{
        id: "fh1",
        symbol: "BTC/USDT:USDT",
        code: "USDT",
        amount: -2.5,
        timestamp: 1_680_000_000_000
      }

      assert fh.amount == -2.5
      assert fh.code == "USDT"
    end
  end

  describe "Bourse.Conversion" do
    test "creates struct with all fields nil by default" do
      conv = %Bourse.Conversion{}
      assert is_nil(conv.id)
      assert is_nil(conv.from_currency)
    end

    test "creates conversion with populated fields" do
      conv = %Bourse.Conversion{
        id: "cv1",
        from_currency: "BTC",
        from_amount: 0.1,
        to_currency: "USDT",
        to_amount: 2800.0,
        price: 28_000.0,
        fee: 2.8
      }

      assert conv.from_amount == 0.1
      assert conv.to_amount == 2800.0
      assert conv.fee == 2.8
    end
  end

  describe "Bourse.Account" do
    test "creates struct with all fields nil by default" do
      acc = %Bourse.Account{}
      assert is_nil(acc.id)
      assert is_nil(acc.type)
    end

    test "creates account with populated fields" do
      acc = %Bourse.Account{id: "acc1", type: "spot", code: "USDT"}
      assert acc.type == "spot"
    end
  end

  describe "Bourse.LastPrice" do
    test "creates struct with all fields nil by default" do
      lp = %Bourse.LastPrice{}
      assert is_nil(lp.symbol)
      assert is_nil(lp.price)
    end

    test "creates last price with populated fields" do
      lp = %Bourse.LastPrice{
        symbol: "BTC/USDT",
        price: 28_000.0,
        side: "buy",
        timestamp: 1_680_000_000_000
      }

      assert lp.price == 28_000.0
      assert lp.side == "buy"
    end
  end

  describe "Bourse.DepositWithdrawFee" do
    test "creates struct with empty networks default" do
      dwf = %Bourse.DepositWithdrawFee{}
      assert dwf.networks == %{}
      assert is_nil(dwf.withdraw)
    end

    test "creates deposit/withdraw fee with populated fields" do
      dwf = %Bourse.DepositWithdrawFee{
        withdraw: %{fee: 0.0005, percentage: false},
        deposit: %{fee: 0, percentage: false},
        networks: %{
          "ERC20" => %{withdraw: %{fee: 0.005}, deposit: %{fee: 0}},
          "TRC20" => %{withdraw: %{fee: 1.0}, deposit: %{fee: 0}}
        }
      }

      assert dwf.withdraw.fee == 0.0005
      assert map_size(dwf.networks) == 2
    end
  end

  describe "Bourse.BorrowRate" do
    test "creates struct with all fields nil by default" do
      br = %Bourse.BorrowRate{}
      assert is_nil(br.currency)
      assert is_nil(br.rate)
    end

    test "creates cross borrow rate (symbol nil)" do
      br = %Bourse.BorrowRate{
        currency: "USDT",
        rate: 0.0001,
        period: 86_400_000,
        timestamp: 1_680_000_000_000
      }

      assert is_nil(br.symbol)
      assert br.rate == 0.0001
    end

    test "creates isolated borrow rate (symbol set)" do
      br = %Bourse.BorrowRate{
        symbol: "BTC/USDT",
        currency: "USDT",
        rate: 0.00015,
        base: "BTC",
        base_rate: 0.0001,
        quote: "USDT",
        quote_rate: 0.00015
      }

      assert br.symbol == "BTC/USDT"
      assert br.base_rate == 0.0001
    end
  end

  describe "Bourse.ADLRank" do
    test "creates struct with all fields nil by default" do
      adl = %Bourse.ADLRank{}
      assert is_nil(adl.symbol)
      assert is_nil(adl.rank)
    end

    test "creates ADL rank with populated fields" do
      adl = %Bourse.ADLRank{
        symbol: "BTC/USDT:USDT",
        rank: 3,
        rating: "3",
        percentage: 60.0,
        timestamp: 1_680_000_000_000
      }

      assert adl.rank == 3
      assert adl.rating == "3"
      assert adl.percentage == 60.0
    end
  end

  describe "Bourse.BorrowInterest" do
    test "creates struct with all fields nil by default" do
      bi = %Bourse.BorrowInterest{}
      assert is_nil(bi.currency)
      assert is_nil(bi.interest)
    end

    test "creates borrow interest with populated fields" do
      bi = %Bourse.BorrowInterest{
        symbol: "BTC/USDT",
        currency: "USDT",
        interest: 0.15,
        interest_rate: 0.0001,
        amount_borrowed: 1500.0,
        margin_mode: "cross",
        timestamp: 1_680_000_000_000
      }

      assert bi.interest == 0.15
      assert bi.amount_borrowed == 1500.0
      assert bi.margin_mode == "cross"
    end
  end

  describe "Bourse.FundingRateHistory" do
    test "creates struct with all fields nil by default" do
      frh = %Bourse.FundingRateHistory{}
      assert is_nil(frh.symbol)
      assert is_nil(frh.funding_rate)
    end

    test "creates funding rate history with populated fields" do
      frh = %Bourse.FundingRateHistory{
        symbol: "BTC/USDT:USDT",
        funding_rate: 0.0001,
        timestamp: 1_680_000_000_000,
        datetime: "2023-03-28T12:00:00.000Z"
      }

      assert frh.funding_rate == 0.0001
      assert frh.datetime == "2023-03-28T12:00:00.000Z"
    end
  end
end
