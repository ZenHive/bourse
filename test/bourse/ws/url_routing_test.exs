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
