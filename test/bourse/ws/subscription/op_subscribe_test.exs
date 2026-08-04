defmodule Bourse.WS.Subscription.OpSubscribeTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.OpSubscribe

  test "subscribe wraps channels in op/args envelope" do
    assert %{"op" => "subscribe", "args" => ["tickers.BTCUSDT", "orderbook.50.BTCUSDT"]} =
             OpSubscribe.subscribe(["tickers.BTCUSDT", "orderbook.50.BTCUSDT"], %{})
  end

  test "unsubscribe flips action to unsubscribe" do
    assert %{"op" => "unsubscribe", "args" => ["tickers.BTCUSDT"]} =
             OpSubscribe.unsubscribe(["tickers.BTCUSDT"], %{})
  end

  test "honours op_field and args_field overrides" do
    config = %{op_field: "action", args_field: "topics"}

    assert %{"action" => "subscribe", "topics" => ["x"]} = OpSubscribe.subscribe(["x"], config)
  end

  test "empty channel list yields empty args" do
    assert %{"op" => "subscribe", "args" => []} = OpSubscribe.subscribe([], %{})
  end
end
