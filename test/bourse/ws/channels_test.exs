defmodule Bourse.WS.ChannelsTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.Channels

  describe "build/4 per-exchange formatters" do
    @cases [
      {"bybit", :watch_ticker, %{symbol: "BTC/USDT"}, "tickers.BTCUSDT"},
      {"bybit", :watch_order_book, %{symbol: "BTC/USDT"}, "orderbook:BTCUSDT"},
      {"bybit", :watch_trades, %{symbol: "BTC/USDT"}, "publicTrade.BTCUSDT"},
      {"okx", :watch_ticker, %{symbol: "BTC/USDT"}, %{"channel" => "tickers", "instId" => "BTC-USDT"}},
      {"okx", :watch_trades, %{symbol: "BTC/USDT"}, %{"channel" => "trades", "instId" => "BTC-USDT"}},
      {"okx", :watch_orders, %{}, %{"channel" => "orders"}},
      {"deribit", :watch_ticker, %{symbol: "BTC-PERPETUAL"}, "ticker.BTC-PERPETUAL.100ms"},
      {"binance", :watch_ticker, %{symbol: "BTC/USDT"}, "btcusdt@miniTicker"},
      {"binance", :watch_order_book, %{symbol: "BTC/USDT"}, "orderbook:btcusdt"},
      {"binance", :watch_trades, %{symbol: "BTC/USDT"}, "btcusdt@trade"},
      {"binanceusdm", :watch_ticker, %{symbol: "BTC/USDT"}, "btcusdt@miniTicker"},
      {"binanceusdm", :watch_trades, %{symbol: "BTC/USDT"}, "btcusdt@trade"},
      {"derive", :watch_ticker, %{symbol: "BTC/USDT"}, "ticker.BTC-USDT.100"},
      {"derive", :watch_trades, %{symbol: "BTC/USDT"}, "trades.BTC-USDT"},
      {"hyperliquid", :watch_order_book, %{symbol: "BTC/USDT"}, "orderbook:BTCUSDT"},
      {"hyperliquid", :watch_trades, %{symbol: "BTC/USDT"}, "trade:BTCUSDT"},
      {"hyperliquid", :watch_orders, %{}, "orderUpdates"}
    ]

    for {exchange_id, method, params, expected} <- @cases do
      test "#{exchange_id} #{method}" do
        exchange = Exchange.new!(unquote(exchange_id))

        assert {:ok, unquote(Macro.escape(expected))} =
                 Channels.build(exchange, unquote(method), unquote(Macro.escape(params)), [])
      end
    end
  end

  describe "build/4 errors and pass-through" do
    test "returns error for unsupported method" do
      exchange = Exchange.new!("bybit")
      assert {:error, :unsupported_method} = Channels.build(exchange, :watch_balance, %{}, [])
    end

    test "symbol-only templates require a symbol" do
      exchange = Exchange.new!("bybit")
      assert {:error, :missing_symbol} = Channels.build(exchange, :watch_orders, %{}, [])
    end

    test "missing templates fall back to channel pass-through opt" do
      exchange = Exchange.new!("deribit")

      assert {:ok, "book.BTC-PERPETUAL.raw"} =
               Channels.build(exchange, :watch_order_book, %{symbol: "BTC-PERPETUAL"}, channel: "book.BTC-PERPETUAL.raw")
    end

    test "unresolved template entries fall back to channel pass-through opt" do
      exchange = Exchange.new!("bybit")

      spec =
        put_in(exchange.spec, ["websocket", "subscribe", "channels", "watchTicker"], %{
          "_unresolved_reason" => "computed_channel_key"
        })

      exchange = %{exchange | spec: spec}

      assert {:ok, "tickers.BTCUSDT"} =
               Channels.build(exchange, :watch_ticker, %{symbol: "BTC/USDT"}, channel: "tickers.BTCUSDT")
    end

    test "unresolved templates error without pass-through channel" do
      exchange = Exchange.new!("bybit")

      spec =
        put_in(exchange.spec, ["websocket", "subscribe", "channels", "watchTicker"], %{
          "_unresolved_reason" => "computed_channel_key"
        })

      exchange = %{exchange | spec: spec}

      assert {:error, {:unresolved, "computed_channel_key"}} =
               Channels.build(exchange, :watch_ticker, %{symbol: "BTC/USDT"}, [])
    end
  end

  describe "private?/1" do
    test "watch_orders is private" do
      assert Channels.private?(:watch_orders)
      refute Channels.private?(:watch_ticker)
    end
  end
end
