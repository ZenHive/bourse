defmodule Bourse.WS.Subscription.CustomTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.Custom

  test "array_format (Upbit) emits one envelope per channel" do
    config = %{custom_type: "array_format"}

    [one, two] = Custom.subscribe(["KRW-BTC", "KRW-ETH"], config)

    assert %{"type" => "ticker", "codes" => ["KRW-BTC"]} = one
    assert %{"type" => "ticker", "codes" => ["KRW-ETH"]} = two
  end

  test "array_format unsubscribe flags isOnlyRealtime per frame" do
    config = %{custom_type: "array_format"}

    [frame] = Custom.unsubscribe(["KRW-BTC"], config)
    assert frame["isOnlyRealtime"] == true
  end

  test "sendTopicAction (Deepcoin) emits a single nested envelope" do
    config = %{custom_type: "sendTopicAction"}

    assert %{"sendTopicAction" => %{"action" => "subscribe", "topics" => ["ticker"]}} =
             Custom.subscribe(["ticker"], config)

    assert %{"sendTopicAction" => %{"action" => "unsubscribe", "topics" => ["ticker"]}} =
             Custom.unsubscribe(["ticker"], config)
  end

  test "default fallback when no custom_type is set" do
    assert %{"subscribe" => true, "channels" => ["x"]} = Custom.subscribe(["x"], %{})
    assert %{"unsubscribe" => true, "channels" => ["x"]} = Custom.unsubscribe(["x"], %{})
  end
end
