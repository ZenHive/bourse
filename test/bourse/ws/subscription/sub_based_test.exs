defmodule Bourse.WS.Subscription.SubBasedTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.SubBased

  test "subscribe emits one frame per channel" do
    [f1, f2] = SubBased.subscribe(["market.btcusdt.ticker", "market.ethusdt.ticker"], %{})

    assert %{"sub" => "market.btcusdt.ticker"} = f1
    assert %{"sub" => "market.ethusdt.ticker"} = f2
  end

  test "empty channel list yields empty frame list" do
    assert [] = SubBased.subscribe([], %{})
  end

  test "unsubscribe emits unsub frames per channel" do
    [%{"unsub" => "market.btcusdt.ticker"} = f] = SubBased.unsubscribe(["market.btcusdt.ticker"], %{})
    refute Map.has_key?(f, "id")
  end

  describe "id-field stripping (T100)" do
    test "frames never carry an 'id' key — zen_websocket correlation would hang the caller" do
      [f] = SubBased.subscribe(["market.btcusdt.ticker"], %{})
      refute Map.has_key?(f, "id")
    end

    test "caller-supplied id config is stripped from every frame" do
      [frame] = SubBased.subscribe(["market.btcusdt.ticker"], %{id: 42})

      assert %{"sub" => "market.btcusdt.ticker"} = frame
      refute Map.has_key?(frame, "id")
    end
  end
end
