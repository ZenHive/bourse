defmodule Bourse.WS.Subscription.MethodSubscriptionTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription
  alias Bourse.WS.Subscription.MethodSubscription

  test "subscribe wraps the first channel as subscription.type" do
    assert %{"method" => "subscribe", "subscription" => %{"type" => "allMids"}} =
             MethodSubscription.subscribe(["allMids"], %{})
  end

  test "unsubscribe flips method only" do
    assert %{"method" => "unsubscribe", "subscription" => %{"type" => "allMids"}} =
             MethodSubscription.unsubscribe(["allMids"], %{})
  end

  test "empty channel list yields empty type" do
    assert %{"subscription" => %{"type" => ""}} = MethodSubscription.subscribe([], %{})
  end

  describe "map-input passthrough (task 543)" do
    test "single map is used as the subscription object without double-wrapping" do
      assert %{
               "method" => "subscribe",
               "subscription" => %{"type" => "allMids"}
             } = MethodSubscription.subscribe([%{"type" => "allMids"}], %{})

      assert %{
               "method" => "subscribe",
               "subscription" => %{"type" => "l2Book", "coin" => "BTC"}
             } =
               MethodSubscription.subscribe([%{"type" => "l2Book", "coin" => "BTC"}], %{})
    end

    test "map-input flips to unsubscribe on unsubscribe/2" do
      assert %{
               "method" => "unsubscribe",
               "subscription" => %{"type" => "allMids"}
             } = MethodSubscription.unsubscribe([%{"type" => "allMids"}], %{})
    end

    test "multiple maps not supported — returns explicit error" do
      assert {:error, :multiple_maps_not_supported} =
               MethodSubscription.subscribe(
                 [%{"type" => "allMids"}, %{"type" => "l2Book", "coin" => "BTC"}],
                 %{}
               )
    end

    test "mixed string/map list rejected" do
      assert {:error, :mixed_channel_types} =
               MethodSubscription.subscribe(["allMids", %{"type" => "l2Book"}], %{})
    end

    test "dispatcher propagates shape errors verbatim" do
      assert {:error, :multiple_maps_not_supported} =
               Subscription.build_subscribe(
                 :method_subscription,
                 [%{"type" => "a"}, %{"type" => "b"}],
                 %{}
               )

      assert {:ok, %{"subscription" => %{"type" => "allMids"}}} =
               Subscription.build_subscribe(:method_subscription, [%{"type" => "allMids"}], %{})
    end
  end
end
