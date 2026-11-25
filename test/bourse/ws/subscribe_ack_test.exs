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

    test "a refusal confirms only the channels it names as already subscribed" do
      bybit = %{
        "op" => "subscribe",
        "success" => false,
        "ret_msg" => "error:already subscribed,topic:publicTrade.BTCUSDT"
      }

      assert ["publicTrade.BTCUSDT"] = SubscribeAck.already_subscribed("bybit", bybit, ["publicTrade.BTCUSDT"])
      assert [] = SubscribeAck.already_subscribed("bybit", bybit, ["publicTrade.ETHUSDT"])
      # Bybit names only the first active topic of a multi-topic request.
      assert ["publicTrade.BTCUSDT"] =
               SubscribeAck.already_subscribed("bybit", bybit, ["orderbook.50.BTCUSDT", "publicTrade.BTCUSDT"])

      assert [] =
               SubscribeAck.already_subscribed("bybit", %{bybit | "ret_msg" => "error:handler not found"}, [
                 "publicTrade.BTCUSDT"
               ])

      sub = %{"type" => "trades", "coin" => "BTC"}
      hl = %{"channel" => "error", "data" => ~s(Already subscribed: {"type":"trades","coin":"BTC"})}
      assert [^sub] = SubscribeAck.already_subscribed("hyperliquid", hl, [sub])
      assert [] = SubscribeAck.already_subscribed("hyperliquid", hl, [%{sub | "coin" => "ETH"}])

      # As observed on testnet: the echo carries l2Book's optional fields at their defaults.
      book = %{"type" => "l2Book", "coin" => "BTC"}
      echo = ~s(Already subscribed: {"type":"l2Book","coin":"BTC","nSigFigs":null,"mantissa":null,"fast":false})
      assert [^book] = SubscribeAck.already_subscribed("hyperliquid", %{hl | "data" => echo}, [book])
      other = ~s(Already subscribed: {"type":"l2Book","coin":"BTC","nSigFigs":5,"mantissa":null,"fast":false})
      assert [] = SubscribeAck.already_subscribed("hyperliquid", %{hl | "data" => other}, [book])
      assert [] = SubscribeAck.already_subscribed("hyperliquid", %{hl | "data" => "Already unsubscribed: x"}, [sub])
      assert [] = SubscribeAck.already_subscribed("okx", %{"event" => "error"}, ["x"])

      # Compared as sent on the wire: atom keys and a plain string channel.
      atom_book = %{type: "l2Book", coin: "BTC"}
      assert [^atom_book] = SubscribeAck.already_subscribed("hyperliquid", %{hl | "data" => echo}, [atom_book])
      mids = %{hl | "data" => ~s(Already subscribed: {"type":"allMids"})}
      assert ["allMids"] = SubscribeAck.already_subscribed("hyperliquid", mids, ["allMids"])
    end

    # Replies observed 2026-11-26 on stream-testnet.bybit.com,
    # stream.testnet.binance.vision, demo-fstream, demo-dstream and wspap.okx.com.
    test "a reply is the outcome only of the request whose id it echoes" do
      bybit_ok = %{"op" => "subscribe", "req_id" => "7", "success" => true, "ret_msg" => ""}
      bybit_refused = %{bybit_ok | "success" => false, "ret_msg" => "error:handler not found,topic:x"}
      assert :success = SubscribeAck.classify("bybit", bybit_ok, ["x"], {"req_id", "7"})
      assert {:rejected, ^bybit_refused} = SubscribeAck.classify("bybit", bybit_refused, ["x"], {"req_id", "7"})
      assert :not_ack = SubscribeAck.classify("bybit", bybit_ok, ["x"], {"req_id", "8"})
      assert :not_ack = SubscribeAck.classify("bybit", bybit_refused, ["x"], {"req_id", "8"})
      assert :not_ack = SubscribeAck.classify("bybit", Map.delete(bybit_ok, "req_id"), ["x"], {"req_id", "7"})

      for venue <- ["binance", "binanceusdm", "binancecoinm"] do
        refused = %{"id" => 7, "error" => %{"code" => 2, "msg" => "Invalid request: invalid stream"}}
        assert :success = SubscribeAck.classify(venue, %{"id" => 7, "result" => nil}, ["x"], {"id", 7})
        assert {:rejected, ^refused} = SubscribeAck.classify(venue, refused, ["x"], {"id", 7})
        assert :not_ack = SubscribeAck.classify(venue, %{"id" => 6, "result" => nil}, ["x"], {"id", 7})
        assert :not_ack = SubscribeAck.classify(venue, %{refused | "id" => 6}, ["x"], {"id", 7})
      end

      okx_error = %{"event" => "error", "code" => "60018", "id" => "7", "msg" => "Subscribe failed"}
      assert :success = SubscribeAck.classify("okx", %{"event" => "subscribe", "id" => "7"}, [], {"id", "7"})
      assert {:rejected, ^okx_error} = SubscribeAck.classify("okx", okx_error, [], {"id", "7"})
      assert :not_ack = SubscribeAck.classify("okx", %{"event" => "subscribe", "id" => "6"}, [], {"id", "7"})
    end

    test "binance COIN-M acceptance is read as the binance family's" do
      assert :success = SubscribeAck.classify("binancecoinm", %{"id" => 1, "result" => nil})
    end

    test "a hyperliquid acceptance is the outcome only of the subscription it echoes" do
      accepted = fn subscription ->
        %{"channel" => "subscriptionResponse", "data" => %{"method" => "subscribe", "subscription" => subscription}}
      end

      trades = %{"type" => "trades", "coin" => "BTC"}
      book = %{"type" => "l2Book", "coin" => "BTC"}
      assert :success = SubscribeAck.classify("hyperliquid", accepted.(trades), [trades])
      assert :not_ack = SubscribeAck.classify("hyperliquid", accepted.(trades), [book])
      assert :success = SubscribeAck.classify("hyperliquid", accepted.(trades), [%{type: "trades", coin: "BTC"}])
      assert :success = SubscribeAck.classify("hyperliquid", accepted.(%{"type" => "allMids"}), ["allMids"])

      assert {:rejected, %{"channel" => "error"}} =
               SubscribeAck.classify("hyperliquid", %{"channel" => "error", "data" => "Error parsing JSON"}, [book])

      assert :success = SubscribeAck.classify("bybit", %{"op" => "subscribe", "success" => true}, ["x"])
    end

    # Both refusals echo what they refuse (api.hyperliquid-testnet.xyz, 2026-11-26).
    test "a hyperliquid refusal is the outcome only of the subscription it echoes" do
      trades = %{"type" => "trades", "coin" => "BTC"}
      eth = %{"type" => "trades", "coin" => "ETH"}
      already = %{"channel" => "error", "data" => ~s(Already subscribed: {"type":"trades","coin":"BTC"})}

      unparsable = %{
        "channel" => "error",
        "data" =>
          ~s(Error parsing JSON into valid websocket request: {"method":"subscribe","subscription":{"type":"nope"}})
      }

      assert {:rejected, ^already} = SubscribeAck.classify("hyperliquid", already, [trades])
      assert :not_ack = SubscribeAck.classify("hyperliquid", already, [eth])
      assert {:rejected, ^unparsable} = SubscribeAck.classify("hyperliquid", unparsable, [%{"type" => "nope"}])
      assert :not_ack = SubscribeAck.classify("hyperliquid", unparsable, [eth])
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

      unsubscribed = %{"method" => "unsubscribe", "subscription" => %{"type" => "trades", "coin" => "BTC"}}

      assert :not_ack =
               SubscribeAck.classify("hyperliquid", %{"channel" => "subscriptionResponse", "data" => unsubscribed})
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

      # Deribit public/test (heartbeat) is a version map, not a subscribe echo.
      assert :not_ack =
               SubscribeAck.classify("deribit", %{
                 "jsonrpc" => "2.0",
                 "result" => %{"version" => "1.2.26"}
               })
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

    test "coinbaseexchange subscriptions ack, invalid-channel error, and data frames" do
      assert :success =
               SubscribeAck.classify("coinbaseexchange", %{
                 "type" => "subscriptions",
                 "channels" => [
                   %{"name" => "matches", "product_ids" => ["ETH-USD"]},
                   %{"name" => "heartbeat", "product_ids" => ["ETH-USD"]}
                 ]
               })

      error = %{
        "type" => "error",
        "message" => "Failed to subscribe",
        "reason" => "not_a_valid_channel is not a valid channel"
      }

      assert {:rejected, ^error} = SubscribeAck.classify("coinbaseexchange", error)
      assert {:error, {:subscription_rejected, ^error}} = SubscribeAck.to_result({:rejected, error})

      assert :not_ack =
               SubscribeAck.classify("coinbaseexchange", %{
                 "type" => "last_match",
                 "trade_id" => 842_900_890,
                 "product_id" => "ETH-USD"
               })

      assert :not_ack =
               SubscribeAck.classify("coinbaseexchange", %{
                 "type" => "match",
                 "trade_id" => 842_900_891,
                 "product_id" => "ETH-USD",
                 "side" => "sell",
                 "price" => "2497.81",
                 "size" => "0.721"
               })

      assert :not_ack =
               SubscribeAck.classify("coinbaseexchange", %{
                 "type" => "heartbeat",
                 "last_trade_id" => 842_900_890,
                 "sequence" => 102_860_075_212,
                 "product_id" => "ETH-USD"
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
