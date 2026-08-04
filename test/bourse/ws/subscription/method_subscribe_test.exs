defmodule Bourse.WS.Subscription.MethodSubscribeTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.MethodSubscribe

  test "subscribe emits upper-case SUBSCRIBE per Binance convention" do
    assert %{"method" => "SUBSCRIBE", "params" => ["btcusdt@ticker"]} =
             MethodSubscribe.subscribe(["btcusdt@ticker"], %{})
  end

  test "unsubscribe emits upper-case UNSUBSCRIBE" do
    assert %{"method" => "UNSUBSCRIBE", "params" => ["btcusdt@ticker"]} =
             MethodSubscribe.unsubscribe(["btcusdt@ticker"], %{})
  end

  test "honours field overrides" do
    config = %{op_field: "cmd", args_field: "args"}
    assert %{"cmd" => "SUBSCRIBE", "args" => ["x"]} = MethodSubscribe.subscribe(["x"], config)
  end
end
