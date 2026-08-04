defmodule Bourse.WS.Subscription.MethodParamsTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.MethodParams

  test "subscribe nests channels under params.channel" do
    assert %{"method" => "subscribe", "params" => %{"channel" => ["ticker", "book"]}} =
             MethodParams.subscribe(["ticker", "book"], %{})
  end

  test "unsubscribe flips method only" do
    assert %{"method" => "unsubscribe", "params" => %{"channel" => ["ticker"]}} =
             MethodParams.unsubscribe(["ticker"], %{})
  end

  test "honours channel_key override" do
    assert %{"method" => "subscribe", "params" => %{"name" => ["ticker"]}} =
             MethodParams.subscribe(["ticker"], %{channel_key: "name"})
  end

  describe "map-input passthrough (T99)" do
    test "map-input emits the supplied params shape" do
      assert %{
               "method" => "subscribe",
               "params" => %{"channel" => "ticker", "symbol" => ["BTC/USD"]}
             } =
               MethodParams.subscribe(
                 [%{"channel" => "ticker", "symbol" => ["BTC/USD"]}],
                 %{}
               )
    end

    test "map-input flips to unsubscribe on unsubscribe/2" do
      assert %{
               "method" => "unsubscribe",
               "params" => %{"channel" => "ticker", "symbol" => ["BTC/USD"]}
             } =
               MethodParams.unsubscribe(
                 [%{"channel" => "ticker", "symbol" => ["BTC/USD"]}],
                 %{}
               )
    end

    test "multiple maps not supported — returns explicit error" do
      assert {:error, :multiple_maps_not_supported} =
               MethodParams.subscribe(
                 [
                   %{"channel" => "ticker", "symbol" => ["BTC/USD"]},
                   %{"channel" => "book", "symbol" => ["ETH/USD"]}
                 ],
                 %{}
               )
    end

    test "mixed string/map list rejected — string-first variant" do
      assert {:error, :mixed_channel_types} =
               MethodParams.subscribe(
                 ["ticker", %{"channel" => "book", "symbol" => ["ETH/USD"]}],
                 %{}
               )
    end

    test "mixed map/string list rejected — map-first variant" do
      assert {:error, :mixed_channel_types} =
               MethodParams.subscribe(
                 [%{"channel" => "ticker", "symbol" => ["BTC/USD"]}, "book"],
                 %{}
               )
    end
  end
end
