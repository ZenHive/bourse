defmodule Bourse.StructValidatorsTest do
  use ExUnit.Case, async: true

  import Bourse.StructValidators

  alias Bourse.Balance
  alias Bourse.Market
  alias Bourse.OHLCV
  alias Bourse.Order
  alias Bourse.OrderBook
  alias Bourse.Position
  alias Bourse.Ticker
  alias Bourse.Trade

  describe "assert_ticker_struct/2" do
    test "passes with numeric fields and bid <= ask" do
      ticker = %Ticker{
        symbol: "BTC/USDT",
        last: 28_000.0,
        close: 28_000.0,
        bid: 27_999.0,
        ask: 28_001.0,
        high: 28_500.0,
        low: 27_800.0,
        open: 28_100.0,
        base_volume: 12.5,
        timestamp: 1_700_000_000_000
      }

      assert :ok = assert_ticker_struct(ticker, "BTC/USDT")
    end

    test "accepts numeric strings from parsers" do
      ticker = %Ticker{last: "65000.00", close: "65000.00", bid: "64999.00", ask: "65001.00"}
      assert :ok = assert_ticker_struct(ticker)
    end

    test "allows nil price fields" do
      assert :ok = assert_ticker_struct(%Ticker{symbol: "BTC/USDT"})
    end

    test "flunks on symbol mismatch" do
      ticker = %Ticker{symbol: "ETH/USDT", last: 1.0, close: 1.0}

      assert_raise ExUnit.AssertionError, ~r/symbol/, fn ->
        assert_ticker_struct(ticker, "BTC/USDT")
      end
    end

    test "flunks when bid > ask" do
      ticker = %Ticker{bid: 28_002.0, ask: 28_000.0}

      assert_raise ExUnit.AssertionError, ~r/bid/, fn ->
        assert_ticker_struct(ticker)
      end
    end

    test "flunks when last != close" do
      ticker = %Ticker{last: 1.0, close: 2.0}

      assert_raise ExUnit.AssertionError, ~r/last/, fn ->
        assert_ticker_struct(ticker)
      end
    end

    test "flunks when high < low" do
      ticker = %Ticker{high: 1.0, low: 2.0}

      assert_raise ExUnit.AssertionError, ~r/high/, fn ->
        assert_ticker_struct(ticker)
      end
    end

    test "flunks on negative volume" do
      ticker = %Ticker{base_volume: -1.0}

      assert_raise ExUnit.AssertionError, ~r/base_volume/, fn ->
        assert_ticker_struct(ticker)
      end
    end

    test "flunks when percentage < -100" do
      ticker = %Ticker{percentage: -100.1}

      assert_raise ExUnit.AssertionError, ~r/percentage/, fn ->
        assert_ticker_struct(ticker)
      end
    end

    test "does not enforce last-within-1%-of-midpoint policy" do
      # Thin market: last far from mid — policy-rejected in classification table.
      ticker = %Ticker{
        last: 100.0,
        close: 100.0,
        bid: 1.0,
        ask: 2.0,
        high: 200.0,
        low: 50.0
      }

      assert :ok = assert_ticker_struct(ticker)
    end
  end

  describe "assert_order_book_struct/2" do
    test "passes for sorted non-crossed book" do
      book = %OrderBook{
        symbol: "BTC/USDT",
        bids: [[28_000.0, 1.5], [27_999.0, 2.0]],
        asks: [[28_001.0, 0.8], [28_002.0, 1.2]],
        timestamp: 1_700_000_000_000
      }

      assert :ok = assert_order_book_struct(book, "BTC/USDT")
    end

    test "allows equal consecutive prices" do
      book = %OrderBook{
        bids: [[28_000.0, 1.0], [28_000.0, 2.0]],
        asks: [[28_001.0, 1.0], [28_001.0, 0.5]]
      }

      assert :ok = assert_order_book_struct(book)
    end

    test "allows locked book bid == ask" do
      book = %OrderBook{bids: [[100.0, 1.0]], asks: [[100.0, 1.0]]}
      assert :ok = assert_order_book_struct(book)
    end

    test "flunks on unsorted bids" do
      book = %OrderBook{bids: [[27_999.0, 1.0], [28_000.0, 1.0]], asks: [[28_001.0, 1.0]]}

      assert_raise ExUnit.AssertionError, ~r/bids must be descending/, fn ->
        assert_order_book_struct(book)
      end
    end

    test "flunks on crossed book" do
      book = %OrderBook{bids: [[28_002.0, 1.0]], asks: [[28_000.0, 1.0]]}

      assert_raise ExUnit.AssertionError, ~r/crossed book/, fn ->
        assert_order_book_struct(book)
      end
    end

    test "flunks on non-positive level price" do
      book = %OrderBook{bids: [[0.0, 1.0]], asks: [[1.0, 1.0]]}

      assert_raise ExUnit.AssertionError, ~r/price must be > 0/, fn ->
        assert_order_book_struct(book)
      end
    end

    test "flunks on a level with extra columns" do
      book = %OrderBook{bids: [[100.0, 1.0, 7]], asks: [[101.0, 1.0]]}

      assert_raise ExUnit.AssertionError, ~r/exactly \[price, amount\]/, fn ->
        assert_order_book_struct(book)
      end
    end
  end

  describe "assert_balance_struct/1" do
    test "passes for currency maps with numeric amounts" do
      balance = %Balance{
        free: %{"BTC" => 1.5, "USDT" => "10000.0"},
        used: %{"BTC" => 0.5},
        total: %{"BTC" => 2.0, "USDT" => 10_000.0}
      }

      assert :ok = assert_balance_struct(balance)
    end

    test "flunks when free is not a map" do
      assert_raise ExUnit.AssertionError, ~r/balance\.free must be a map/, fn ->
        assert_balance_struct(%Balance{free: "bad"})
      end
    end

    test "does not enforce free+used==total (policy-rejected)" do
      # Deribit-like equity/margin total outside free+used.
      balance = %Balance{
        free: %{"BTC" => 1.0},
        used: %{"BTC" => 1.0},
        total: %{"BTC" => 3.0}
      }

      assert :ok = assert_balance_struct(balance)
    end

    test "accepts provider-defined negative currency equity only for Deribit" do
      # Live 2026-07-29: Deribit testnet ETH total ≈ −0.19 with short options.
      # Contract: https://docs.deribit.com/api-reference/account-management/private-get_account_summary
      balance = %Balance{
        free: %{"ETH" => -0.1},
        used: %{"ETH" => 0.0},
        total: %{"ETH" => -0.1}
      }

      assert :ok = assert_balance_struct(balance, venue: "deribit")

      assert_raise ExUnit.AssertionError, ~r/must be >= 0/, fn ->
        assert_balance_struct(balance)
      end

      assert_raise ExUnit.AssertionError, ~r/must be >= 0/, fn ->
        assert_balance_struct(balance, venue: "okx")
      end
    end

    test "flunks on non-numeric amount" do
      balance = %Balance{free: %{"BTC" => "n/a"}, used: %{}, total: %{}}

      assert_raise ExUnit.AssertionError, ~r/must be numeric/, fn ->
        assert_balance_struct(balance)
      end
    end

    test "accepts nil amount placeholders only for Derive" do
      balance = %Balance{free: %{"ETH" => nil}, used: %{}, total: %{}}

      assert :ok = assert_balance_struct(balance, venue: "derive")

      assert_raise ExUnit.AssertionError, ~r/must be numeric/, fn ->
        assert_balance_struct(balance)
      end

      assert_raise ExUnit.AssertionError, ~r/must be numeric/, fn ->
        assert_balance_struct(balance, venue: "deribit")
      end
    end
  end

  describe "assert_ohlcv_list/1" do
    test "passes for valid candles" do
      candles = [
        %OHLCV{
          timestamp: 1_680_000_000_000,
          open: 28_000.0,
          high: 28_500.0,
          low: 27_800.0,
          close: 28_200.0,
          volume: 150.5
        },
        %OHLCV{
          timestamp: 1_680_003_600_000,
          open: "28000",
          high: "28500",
          low: "27800",
          close: "28200",
          volume: "0"
        }
      ]

      assert :ok = assert_ohlcv_list(candles)
    end

    test "flunks when high < low" do
      candle = %OHLCV{timestamp: 1_680_000_000_000, high: 1.0, low: 2.0, volume: 1.0}

      assert_raise ExUnit.AssertionError, ~r/high/, fn ->
        assert_ohlcv_list([candle])
      end
    end

    test "flunks on negative volume" do
      candle = %OHLCV{timestamp: 1_680_000_000_000, high: 2.0, low: 1.0, volume: -0.1}

      assert_raise ExUnit.AssertionError, ~r/volume/, fn ->
        assert_ohlcv_list([candle])
      end
    end

    test "flunks when open outside high/low" do
      candle = %OHLCV{
        timestamp: 1_680_000_000_000,
        open: 3.0,
        high: 2.0,
        low: 1.0,
        close: 1.5,
        volume: 1.0
      }

      assert_raise ExUnit.AssertionError, ~r/ohlcv\.open/, fn ->
        assert_ohlcv_list([candle])
      end
    end

    test "repo-owned: allows descending candle timestamps (newest-first venues)" do
      candles = [
        %OHLCV{timestamp: 1_680_003_600_000, high: 2.0, low: 1.0, volume: 0},
        %OHLCV{timestamp: 1_680_000_000_000, high: 2.0, low: 1.0, volume: 0}
      ]

      assert :ok = assert_ohlcv_list(candles)
    end

    test "repo-owned: flunks on non-monotone timestamps" do
      candles = [
        %OHLCV{timestamp: 1_680_000_000_000, high: 2.0, low: 1.0, volume: 0},
        %OHLCV{timestamp: 1_680_007_200_000, high: 2.0, low: 1.0, volume: 0},
        %OHLCV{timestamp: 1_680_003_600_000, high: 2.0, low: 1.0, volume: 0}
      ]

      assert_raise ExUnit.AssertionError, ~r/monotone/, fn ->
        assert_ohlcv_list(candles)
      end
    end

    test "accepts list-form candles from partially-parsed venues" do
      candles = [
        [1_680_000_000_000, 28_000.0, 28_500.0, 27_800.0, 28_200.0, 10.0],
        ["1680003600000", "28000", "28500", "27800", "28200", "0"]
      ]

      assert :ok = assert_ohlcv_list(candles)
    end
  end

  describe "assert_trade_struct/2 and list ordering" do
    test "passes for valid trade" do
      trade = %Trade{
        symbol: "BTC/USDT",
        side: "buy",
        price: "12.5",
        amount: 0.4,
        taker_or_maker: "taker",
        timestamp: 1_700_000_000_000
      }

      assert :ok = assert_trade_struct(trade, "BTC/USDT")
    end

    test "flunks on invalid side" do
      trade = %Trade{side: "long", price: 1.0, amount: 1.0}

      assert_raise ExUnit.AssertionError, ~r/side/, fn ->
        assert_trade_struct(trade)
      end
    end

    test "flunks on negative price" do
      trade = %Trade{price: -1.0, amount: 1.0}

      assert_raise ExUnit.AssertionError, ~r/price/, fn ->
        assert_trade_struct(trade)
      end
    end

    test "allows descending trade timestamps (newest-first venues)" do
      trades = [
        %Trade{price: 1.0, amount: 1.0, timestamp: 1_700_000_000_100},
        %Trade{price: 1.0, amount: 1.0, timestamp: 1_700_000_000_000}
      ]

      assert :ok = assert_trade_list(trades)
    end

    test "flunks on non-monotone trade timestamps" do
      trades = [
        %Trade{price: 1.0, amount: 1.0, timestamp: 1_700_000_000_000},
        %Trade{price: 1.0, amount: 1.0, timestamp: 1_700_000_000_200},
        %Trade{price: 1.0, amount: 1.0, timestamp: 1_700_000_000_100}
      ]

      assert_raise ExUnit.AssertionError, ~r/monotone/, fn ->
        assert_trade_list(trades)
      end
    end
  end

  describe "assert_market_struct/1 and carve non-enforcement" do
    test "passes for spot market" do
      market = %Market{
        symbol: "BTC/USDT",
        base: "BTC",
        quote: "USDT",
        type: "spot",
        active: true,
        precision: %{"price" => 2},
        limits: %{"amount" => %{"min" => 0.001}}
      }

      assert :ok = assert_market_struct(market)
    end

    test "accepts multi-leg venue market types" do
      for type <- ["future_combo", "option_combo"] do
        assert :ok = assert_market_struct(%Market{symbol: "BTC-COMBO", type: type})
      end
    end

    test "flunks without symbol" do
      assert_raise ExUnit.AssertionError, ~r/market\.symbol/, fn ->
        assert_market_struct(%Market{base: "BTC"})
      end
    end

    test "C6: hyperliquid-style market with nil precision.price passes" do
      market = %Market{
        symbol: "BTC/USDC:USDC",
        base: "BTC",
        quote: "USDC",
        type: "swap",
        precision: %{"amount" => 0.001},
        contract_size: nil
      }

      assert :ok = assert_market_struct(market)
      # Completely missing precision map is also fine
      assert :ok = assert_market_struct(%Market{symbol: "BTC/USDC:USDC", precision: nil})
    end
  end

  describe "assert_position_struct/2 and carve C7" do
    test "passes with enums and nil contract_size (C7)" do
      position = %Position{
        symbol: "BTC-PERPETUAL",
        side: "long",
        margin_mode: "cross",
        contracts: 1.0,
        contract_size: nil,
        leverage: 5.0,
        entry_price: 50_000.0,
        mark_price: 51_000.0,
        timestamp: 1_700_000_000_000
      }

      assert :ok = assert_position_struct(position, "BTC-PERPETUAL")
    end

    test "flunks on invalid side" do
      assert_raise ExUnit.AssertionError, ~r/side/, fn ->
        assert_position_struct(%Position{side: "buy"})
      end
    end

    test "flunks when leverage is zero" do
      assert_raise ExUnit.AssertionError, ~r/leverage/, fn ->
        assert_position_struct(%Position{leverage: 0})
      end
    end

    test "accepts signed negative contracts only for Deribit short positions" do
      # Live 2026-07-29: Deribit ETH short option with contracts = −6.0.
      # Contract: https://docs.deribit.com/api-reference/account-management/private-get_positions
      position = %Position{
        symbol: "ETH/USD:ETH-260731-2250-C",
        side: "short",
        contracts: -6.0,
        leverage: 1.0,
        entry_price: 0.01,
        mark_price: 0.02
      }

      assert :ok = assert_position_struct(position, nil, venue: "deribit")

      assert_raise ExUnit.AssertionError, ~r/must be >= 0 unless Deribit reports a short/, fn ->
        assert_position_struct(position)
      end

      assert_raise ExUnit.AssertionError, ~r/must be >= 0 unless Deribit reports a short/, fn ->
        assert_position_struct(%{position | side: "long"}, nil, venue: "deribit")
      end
    end
  end

  describe "assert_order_struct/2" do
    test "passes for open limit order" do
      order = %Order{
        symbol: "BTC/USDT",
        side: "buy",
        status: "open",
        amount: 1.0,
        filled: 0.2,
        remaining: 0.8,
        price: 50_000.0,
        timestamp: 1_700_000_000_000
      }

      assert :ok = assert_order_struct(order, "BTC/USDT")
    end

    test "flunks when filled > amount" do
      order = %Order{amount: 1.0, filled: 1.5}

      assert_raise ExUnit.AssertionError, ~r/amount/, fn ->
        assert_order_struct(order)
      end
    end
  end

  describe "validate_for_method!/2" do
    test "dispatches fetch_trades to trade list validation" do
      trades = [%Trade{price: 1.0, amount: 0.1, side: "sell", timestamp: 1_700_000_000_000}]
      assert :ok = validate_for_method!(:fetch_trades, trades)
    end

    test "dispatches fetch_positions to position list validation" do
      positions = [%Position{side: "short", contract_size: nil, leverage: 2.0, entry_price: 1.0}]
      assert :ok = validate_for_method!(:fetch_positions, positions)
    end

    test "integration helper struct path uses validators" do
      import Bourse.IntegrationHelper

      struct = %Ticker{
        symbol: "BTC/USDT",
        last: 1.0,
        close: 1.0,
        bid: 0.9,
        ask: 1.1,
        high: 1.2,
        low: 0.8
      }

      assert :ok = assert_public_response(:fetch_ticker, {:ok, struct})
    end
  end

  describe "timestamp policy window" do
    test "flunks timestamps before 2009" do
      assert_raise ExUnit.AssertionError, ~r/Bitcoin genesis/, fn ->
        assert_ticker_struct(%Ticker{timestamp: 1_000_000_000})
      end
    end

    test "flunks timestamps after 2038 bound" do
      assert_raise ExUnit.AssertionError, ~r/2038/, fn ->
        assert_ticker_struct(%Ticker{timestamp: 3_000_000_000_000})
      end
    end
  end
end
