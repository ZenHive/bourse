defmodule Bourse.WS.MessageRouterTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.MessageRouter

  describe "get_nested/2" do
    test "resolves dot-notation path" do
      msg = %{"params" => %{"channel" => "ticker.BTC-PERPETUAL"}}
      assert MessageRouter.get_nested(msg, "params.channel") == "ticker.BTC-PERPETUAL"
    end

    test "returns nil for absent, invalid, and non-map paths" do
      assert MessageRouter.get_nested(%{"params" => []}, "params.channel") == nil
      assert MessageRouter.get_nested(%{}, nil) == nil
      assert MessageRouter.get_nested(:not_a_map, "params.channel") == nil
    end
  end

  describe "extract_data/2" do
    test "unwraps single-element list when unwrap_list is true" do
      msg = %{"data" => [%{"price" => "42000"}]}
      envelope = %{"data_field" => "data", "unwrap_list" => true}

      assert MessageRouter.extract_data(msg, envelope) == %{"price" => "42000"}
    end

    test "returns raw data for self, multiple items, and missing data" do
      msg = %{"data" => [%{"price" => "1"}, %{"price" => "2"}]}
      assert MessageRouter.extract_data(msg, %{"data_field" => "self"}) == msg
      assert MessageRouter.extract_data(msg, %{"data_field" => "data", "unwrap_list" => true}) == msg["data"]
      assert MessageRouter.extract_data(msg, %{}) == nil
    end
  end

  describe "route/3" do
    setup do
      exchange = Exchange.new!("bybit")

      envelope = %{
        "discriminator_field" => "topic",
        "data_field" => "data",
        "match_type" => "exact_then_substring"
      }

      %{exchange: exchange, envelope: envelope}
    end

    test "routes Bybit orderbook with substring matching", %{exchange: exchange, envelope: envelope} do
      data = %{"b" => [["42000", "1"]], "a" => [["42001", "1"]]}
      msg = %{"topic" => "orderbook.500.BTCUSDT", "data" => data}

      assert {:routed, :watch_order_book, ^data, "orderbook.500.BTCUSDT"} =
               MessageRouter.route(msg, envelope, exchange)
    end

    test "returns {:system, msg} for pong", %{exchange: exchange, envelope: envelope} do
      msg = %{"op" => "pong", "ret_msg" => "pong"}
      envelope = Map.put(envelope, "discriminator_field", "op")

      assert {:system, ^msg} = MessageRouter.route(msg, envelope, exchange)
    end

    test "classifies response messages as system and unknown frames as raw", %{exchange: exchange} do
      response = %{"id" => 1, "result" => %{"ok" => true}}
      assert {:system, ^response} = MessageRouter.route(response, %{"discriminator_field" => "channel"}, exchange)

      unknown = %{"channel" => "not-in-spec"}
      assert {:unknown, ^unknown} = MessageRouter.route(unknown, %{"discriminator_field" => "channel"}, exchange)
      assert {:unknown, ^unknown} = MessageRouter.route(unknown, nil, exchange)
    end

    test "routes Binance depthUpdate", %{envelope: _envelope} do
      exchange = Exchange.new!("binance")
      envelope = %{"discriminator_field" => "e", "data_field" => "self", "match_type" => "exact"}
      msg = %{"e" => "depthUpdate", "b" => [["42000", "1.5"]], "a" => [["42001", "0.5"]]}

      assert {:routed, :watch_order_book, ^msg, "depthUpdate"} =
               MessageRouter.route(msg, envelope, exchange)
    end

    test "routes OKX tickers with unwrap_list", %{envelope: _envelope} do
      exchange = Exchange.new!("okx")

      envelope = %{
        "discriminator_field" => "arg.channel",
        "data_field" => "data",
        "unwrap_list" => true,
        "match_type" => "exact"
      }

      ticker_data = %{"instType" => "SPOT", "instId" => "BTC-USDT", "last" => "42000"}

      msg = %{
        "arg" => %{"channel" => "tickers", "instId" => "BTC-USDT"},
        "data" => [ticker_data]
      }

      assert {:routed, :watch_ticker, ^ticker_data, "tickers"} =
               MessageRouter.route(msg, envelope, exchange)
    end
  end

  describe "extract_market_id/1" do
    test "extracts BTCUSDT from bybit channel" do
      assert MessageRouter.extract_market_id("tickers.BTCUSDT") == "BTCUSDT"
    end

    test "ignores protocol segments and returns nil when no market id exists" do
      assert MessageRouter.extract_market_id("book.100ms.raw") == nil
      assert MessageRouter.extract_market_id(nil) == nil
    end
  end
end
