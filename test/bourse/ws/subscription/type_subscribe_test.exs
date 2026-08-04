defmodule Bourse.WS.Subscription.TypeSubscribeTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.TypeSubscribe

  test "KuCoin single-topic form: first channel under topic" do
    assert %{"type" => "subscribe", "topic" => "/market/ticker:BTC-USDT"} =
             TypeSubscribe.subscribe(["/market/ticker:BTC-USDT"], %{})
  end

  test "Coinbase dual-field form: product_ids + channels" do
    config = %{
      args_field: "product_ids",
      channels_field: "channels",
      channel_name: "matches"
    }

    assert %{
             "type" => "subscribe",
             "product_ids" => ["BTC-USD", "ETH-USD"],
             "channels" => ["matches"]
           } = TypeSubscribe.subscribe(["BTC-USD", "ETH-USD"], config)
  end

  test "dual-field variant with a non-\"channels\" field name passes channel_name as bare string" do
    config = %{args_field: "product_ids", channels_field: "channel", channel_name: "matches"}

    assert %{"channel" => "matches"} = TypeSubscribe.subscribe(["BTC-USD"], config)
  end

  test "unsubscribe flips action only" do
    assert %{"type" => "unsubscribe", "topic" => "x"} = TypeSubscribe.unsubscribe(["x"], %{})
  end
end
