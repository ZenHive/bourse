defmodule Bourse.WS.URLRoutingTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.URLRouting

  describe "public_url/1" do
    test "bybit production URL interpolates {hostname}" do
      exchange = Exchange.new!("bybit")
      assert URLRouting.public_url(exchange) == "wss://stream.bybit.com/v5/public/linear"
    end

    test "bybit sandbox URL interpolates {hostname}" do
      exchange = Exchange.new!("bybit", sandbox: true)
      assert URLRouting.public_url(exchange) == "wss://stream-testnet.bybit.com/v5/public/linear"
    end

    test "deribit production URL (no hostname interpolation)" do
      exchange = Exchange.new!("deribit")
      assert URLRouting.public_url(exchange) == "wss://www.deribit.com/ws/api/v2"
    end

    test "deribit sandbox URL" do
      exchange = Exchange.new!("deribit", sandbox: true)
      assert URLRouting.public_url(exchange) == "wss://test.deribit.com/ws/api/v2"
    end

    test "okx production URL" do
      exchange = Exchange.new!("okx")
      assert URLRouting.public_url(exchange) == "wss://ws.okx.com:8443/ws/v5/public"
    end

    test "okx sandbox URL (wspap host)" do
      exchange = Exchange.new!("okx", sandbox: true)
      assert URLRouting.public_url(exchange) == "wss://wspap.okx.com:8443/ws/v5/public"
    end

    test "unsupported exchange returns nil" do
      exchange = %Exchange{id: "kraken", name: "Unsupported", spec: %{}}
      assert URLRouting.public_url(exchange) == nil
    end

    test "hyperliquid public URL resolves from hand base" do
      exchange = Exchange.new!("hyperliquid")
      assert URLRouting.public_url(exchange) == "wss://api.hyperliquid.xyz/ws"
    end

    test "hyperliquid sandbox public URL" do
      exchange = Exchange.new!("hyperliquid", sandbox: true)
      assert URLRouting.public_url(exchange) == "wss://api.hyperliquid-testnet.xyz/ws"
    end

    test "binanceusdm public URL is the high-frequency /public host" do
      exchange = Exchange.new!("binanceusdm")
      assert URLRouting.public_url(exchange) == "wss://fstream.binance.com/public/ws"
      assert URLRouting.market_url(exchange) == "wss://fstream.binance.com/market/ws"
    end

    test "binanceusdm sandbox public URL follows the same /public vs /market split" do
      exchange = Exchange.new!("binanceusdm", sandbox: true)
      assert URLRouting.public_url(exchange) == "wss://demo-fstream.binance.com/public/ws"
      assert URLRouting.market_url(exchange) == "wss://demo-fstream.binance.com/market/ws"
    end
  end

  describe "stream_url/2" do
    test "binanceusdm ticker and aggTrade resolve to /market/ws" do
      exchange = Exchange.new!("binanceusdm")
      market = "wss://fstream.binance.com/market/ws"

      assert URLRouting.stream_url(exchange, "btcusdt@miniTicker") == market
      assert URLRouting.stream_url(exchange, "btcusdt@ticker") == market
      assert URLRouting.stream_url(exchange, "btcusdt@aggTrade") == market
    end

    test "binanceusdm depth, trade, and bookTicker stay on /public/ws" do
      exchange = Exchange.new!("binanceusdm")
      public = "wss://fstream.binance.com/public/ws"

      assert URLRouting.stream_url(exchange, "btcusdt@depth20@100ms") == public
      assert URLRouting.stream_url(exchange, "btcusdt@trade") == public
      assert URLRouting.stream_url(exchange, "btcusdt@bookTicker") == public
    end

    test "other venues ignore USD-M host split" do
      exchange = Exchange.new!("binance")
      assert URLRouting.stream_url(exchange, "btcusdt@miniTicker") == URLRouting.public_url(exchange)
      assert URLRouting.market_url(exchange) == nil
    end

    test "legacy unrouted /ws is still an authored USD-M host" do
      exchange = Exchange.new!("binanceusdm")
      assert URLRouting.authored_usdm_host?(exchange, "wss://fstream.binance.com/ws")
      refute URLRouting.authored_usdm_host?(exchange, "wss://offline.test")
    end

    test "groups mixed USD-M channels by host without dropping either family" do
      exchange = Exchange.new!("binanceusdm")
      public = URLRouting.public_url(exchange)
      market = URLRouting.market_url(exchange)

      assert URLRouting.group_channels_by_url(exchange, [
               "btcusdt@bookTicker",
               "btcusdt@miniTicker",
               "btcusdt@aggTrade",
               %{"stream" => "opaque"}
             ]) == [
               {public, ["btcusdt@bookTicker", %{"stream" => "opaque"}]},
               {market, ["btcusdt@miniTicker", "btcusdt@aggTrade"]}
             ]
    end
  end

  describe "private_url/1" do
    test "bybit production private URL" do
      exchange = Exchange.new!("bybit")
      assert URLRouting.private_url(exchange) == "wss://stream.bybit.com/v5/private"
    end

    test "bybit sandbox private URL" do
      exchange = Exchange.new!("bybit", sandbox: true)
      assert URLRouting.private_url(exchange) == "wss://stream-testnet.bybit.com/v5/private"
    end

    test "deribit private URL matches public URL (auth via message)" do
      exchange = Exchange.new!("deribit")
      assert URLRouting.private_url(exchange) == "wss://www.deribit.com/ws/api/v2"
    end

    test "okx private URL" do
      exchange = Exchange.new!("okx")
      assert URLRouting.private_url(exchange) == "wss://ws.okx.com:8443/ws/v5/private"
    end

    test "unsupported exchange returns nil" do
      exchange = %Exchange{id: "kraken", name: "Unsupported", spec: %{}}
      assert URLRouting.private_url(exchange) == nil
    end

    test "hyperliquid has no private URL" do
      exchange = Exchange.new!("hyperliquid")
      assert URLRouting.private_url(exchange) == nil
    end
  end
end
