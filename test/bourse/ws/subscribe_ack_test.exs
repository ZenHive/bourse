defmodule Bourse.WS.SubscribeAckTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.SubscribeAck

  describe "classify/2" do
    test "alpaca batched success, rejection, and market data" do
      assert :success = SubscribeAck.classify("alpaca", [%{"T" => "subscription", "trades" => ["FAKEPACA"]}])

      assert {:rejected, %{"T" => "error", "code" => 400}} =
               SubscribeAck.classify("alpaca", [
                 %{"T" => "error", "code" => 400, "msg" => "invalid syntax"}
               ])

      assert :not_ack =
               SubscribeAck.classify("alpaca", [
                 %{"T" => "t", "S" => "FAKEPACA", "p" => 134.56}
               ])
    end

    test "bybit success and rejection" do
      assert :success =
               SubscribeAck.classify("bybit", %{"op" => "subscribe", "success" => true})

      assert {:rejected, %{"success" => false}} =
               SubscribeAck.classify("bybit", %{
                 "op" => "subscribe",
                 "success" => false,
                 "ret_msg" => "error:handler not found"
               })

      assert :not_ack = SubscribeAck.classify("bybit", %{"topic" => "tickers.BTCUSDT", "data" => %{}})
      assert :success = SubscribeAck.classify("bybit", %{"op" => "subscribe", "success" => "true"})

      assert {:rejected, %{"success" => "false"}} =
               SubscribeAck.classify("bybit", %{"op" => "subscribe", "success" => "false"})
    end

    test "okx success and rejection" do
      assert :success = SubscribeAck.classify("okx", %{"event" => "subscribe", "arg" => %{}})

      assert {:rejected, %{"event" => "error"}} =
               SubscribeAck.classify("okx", %{"event" => "error", "code" => "60018", "msg" => "bad"})

      assert :not_ack = SubscribeAck.classify("okx", %{"event" => "notice"})
    end

    test "hyperliquid success and rejection" do
      assert :success =
               SubscribeAck.classify("hyperliquid", %{
                 "channel" => "subscriptionResponse",
                 "data" => %{"method" => "subscribe", "subscription" => %{"type" => "allMids"}}
               })

      assert {:rejected, %{"channel" => "error"}} =
               SubscribeAck.classify("hyperliquid", %{
                 "channel" => "error",
                 "data" => "Error parsing JSON"
               })

      assert :not_ack = SubscribeAck.classify("hyperliquid", %{"channel" => "allMids"})
    end

    test "derive and deribit JSON-RPC envelopes" do
      assert :success =
               SubscribeAck.classify("deribit", %{"jsonrpc" => "2.0", "result" => ["ch"], "id" => 1})

      assert {:rejected, %{"error" => %{"code" => 13_778}}} =
               SubscribeAck.classify("deribit", %{
                 "jsonrpc" => "2.0",
                 "error" => %{"code" => 13_778, "message" => "raw_subscriptions_not_available_for_unauthorized"},
                 "id" => 1
               })

      assert {:rejected, %{"error" => %{"code" => -32_602}}} =
               SubscribeAck.classify("derive", %{
                 "jsonrpc" => "2.0",
                 "error" => %{
                   "code" => -32_602,
                   "data" => "`ticker` channel has been deprecated. Please use `ticker_slim`."
                 },
                 "id" => "abc"
               })

      assert :success =
               SubscribeAck.classify("derive", %{
                 "jsonrpc" => "2.0",
                 "result" => %{"status" => "ok", "current_subscriptions" => ["trades.ETH-PERPETUAL"]},
                 "id" => "abc"
               })

      assert :not_ack = SubscribeAck.classify("derive", %{"jsonrpc" => "2.0", "method" => "subscription"})
      assert :not_ack = SubscribeAck.classify("derive", %{"channel" => "ticker"})
    end

    test "deribit's empty result list is a refusal, not an acknowledgement" do
      # Both envelopes captured on test.deribit.com 2026-08-06 from the same
      # `user.portfolio.btc` subscribe — the only difference is whether the
      # connection had authenticated. Deribit does not report the refusal as an
      # error; it reports subscribing to nothing.
      refused = %{"jsonrpc" => "2.0", "id" => 6, "result" => [], "testnet" => true}
      accepted = %{"jsonrpc" => "2.0", "id" => 7, "result" => ["user.portfolio.btc"], "testnet" => true}

      assert {:rejected, ^refused} = SubscribeAck.classify("deribit", refused)
      assert :success = SubscribeAck.classify("deribit", accepted)

      # Derive answers with a map, so it is untouched by the empty-list rule.
      assert :success =
               SubscribeAck.classify("derive", %{
                 "jsonrpc" => "2.0",
                 "result" => %{"status" => "ok", "current_subscriptions" => []},
                 "id" => "abc"
               })
    end

    test "binance family result envelope" do
      assert :success = SubscribeAck.classify("binance", %{"id" => nil, "result" => nil})
      assert :success = SubscribeAck.classify("binanceusdm", %{"id" => 1, "result" => nil})

      assert {:rejected, %{"error" => _}} =
               SubscribeAck.classify("binance", %{"id" => 1, "error" => %{"code" => 2, "msg" => "bad"}})

      assert :not_ack = SubscribeAck.classify("binance", %{"stream" => "btcusdt@ticker"})
    end

    test "lighter snapshot acknowledgement, updates, and rejection" do
      assert {:success, :data} =
               SubscribeAck.classify("lighter", %{
                 "type" => "subscribed/market_stats",
                 "channel" => "market_stats:0"
               })

      assert :not_ack =
               SubscribeAck.classify("lighter", %{
                 "type" => "update/market_stats",
                 "channel" => "market_stats:0"
               })

      assert {:rejected, %{"error" => %{"code" => 30_005}}} =
               SubscribeAck.classify("lighter", %{
                 "error" => %{"code" => 30_005, "message" => "Invalid Channel"}
               })
    end

    test "generic fallback recognizes common ack shapes without classifying data" do
      assert :success = SubscribeAck.classify("future_venue", %{"success" => true})

      assert {:rejected, %{"success" => false}} =
               SubscribeAck.classify("future_venue", %{"success" => false})

      assert {:rejected, %{"error" => %{}}} =
               SubscribeAck.classify("future_venue", %{"error" => %{}})

      assert {:rejected, %{"event" => "error"}} =
               SubscribeAck.classify("future_venue", %{"event" => "error"})

      assert {:rejected, %{"channel" => "error"}} =
               SubscribeAck.classify("future_venue", %{"channel" => "error"})

      assert :not_ack = SubscribeAck.classify("future_venue", %{"channel" => "ticker"})
    end
  end

  describe "to_result/1" do
    test "maps classifications to the public subscribe return shape" do
      assert :ok = SubscribeAck.to_result(:success)
      assert :ok = SubscribeAck.to_result({:success, :data})
      assert {:error, :unexpected_subscription_response} = SubscribeAck.to_result(:not_ack)

      frame = %{"success" => false}
      assert {:error, {:subscription_rejected, ^frame}} = SubscribeAck.to_result({:rejected, frame})
    end
  end
end
