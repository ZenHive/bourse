defmodule Bourse.WS.Subscription.EventSubscribeTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.EventSubscribe

  test "Gate-style: event + channel + payload list" do
    config = %{channel_field: "channel", channel_value: "spot.tickers"}

    assert %{"event" => "subscribe", "channel" => "spot.tickers", "payload" => ["BTC_USDT"]} =
             EventSubscribe.subscribe(["BTC_USDT"], config)
  end

  test "Bitfinex-style: :string args_format places first channel directly under field" do
    config = %{args_field: "symbol", args_format: :string, channel_field: "channel", channel_value: "ticker"}

    assert %{"event" => "subscribe", "channel" => "ticker", "symbol" => "tBTCUSD"} =
             EventSubscribe.subscribe(["tBTCUSD"], config)
  end

  test "defaults to payload list when no args_format is given" do
    assert %{"event" => "subscribe", "payload" => ["x"]} = EventSubscribe.subscribe(["x"], %{})
  end

  test "unsubscribe flips event only" do
    assert %{"event" => "unsubscribe"} = EventSubscribe.unsubscribe(["x"], %{})
  end

  describe "map-input passthrough (T98)" do
    test "string-argument config spreads channel + symbol alongside event" do
      config = %{args_field: "symbol", args_format: :string}

      assert %{"event" => "subscribe", "channel" => "ticker", "symbol" => "tBTCUSD"} =
               EventSubscribe.subscribe(
                 [%{"channel" => "ticker", "symbol" => "tBTCUSD"}],
                 config
               )
    end

    test "list-argument config spreads channel + payload alongside event (no double-wrap)" do
      config = %{args_field: "payload", args_format: :list}

      frame =
        EventSubscribe.subscribe(
          [%{"channel" => "spot.tickers", "payload" => ["BTC_USDT"]}],
          config
        )

      assert %{"event" => "subscribe", "channel" => "spot.tickers", "payload" => ["BTC_USDT"]} = frame

      # The caller map must not be nested inside "payload".
      refute match?([%{"channel" => _}], frame["payload"])
    end

    test "map-input passthrough flips to unsubscribe on unsubscribe/2" do
      assert %{"event" => "unsubscribe", "channel" => "ticker", "symbol" => "tBTCUSD"} =
               EventSubscribe.unsubscribe(
                 [%{"channel" => "ticker", "symbol" => "tBTCUSD"}],
                 %{}
               )
    end

    test "multiple maps not supported — returns explicit error rather than malforming" do
      assert {:error, :multiple_maps_not_supported} =
               EventSubscribe.subscribe(
                 [%{"channel" => "ticker", "symbol" => "tBTCUSD"}, %{"channel" => "book", "symbol" => "tETHUSD"}],
                 %{}
               )
    end

    test "mixed string/map list rejected — string-first variant no longer slips through" do
      # Regression: pre-fix, ["str", %{...}] passed the `is_map(hd(...))` guard
      # and silently shipped a heterogeneous payload to the wire.
      assert {:error, :mixed_channel_types} =
               EventSubscribe.subscribe(
                 ["BTC_USDT", %{"channel" => "ticker", "symbol" => "tBTCUSD"}],
                 %{}
               )
    end

    test "mixed map/string list rejected — map-first variant" do
      assert {:error, :mixed_channel_types} =
               EventSubscribe.subscribe(
                 [%{"channel" => "ticker", "symbol" => "tBTCUSD"}, "BTC_USDT"],
                 %{}
               )
    end
  end
end
