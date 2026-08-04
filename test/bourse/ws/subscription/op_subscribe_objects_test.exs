defmodule Bourse.WS.Subscription.OpSubscribeObjectsTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.OpSubscribeObjects

  test "subscribe preserves channel objects in args" do
    channels = [%{"channel" => "tickers", "instId" => "BTC-USDT"}]
    assert %{"op" => "subscribe", "args" => ^channels} = OpSubscribeObjects.subscribe(channels, %{})
  end

  test "coerces plain channel strings into %{\"channel\" => _}" do
    assert %{"op" => "subscribe", "args" => [%{"channel" => "tickers"}]} =
             OpSubscribeObjects.subscribe(["tickers"], %{})
  end

  test "mixes strings and objects through the same coercion" do
    channels = ["tickers", %{"channel" => "books", "instId" => "BTC-USDT"}]

    assert %{
             "op" => "subscribe",
             "args" => [%{"channel" => "tickers"}, %{"channel" => "books", "instId" => "BTC-USDT"}]
           } = OpSubscribeObjects.subscribe(channels, %{})
  end

  test "unsubscribe flips action only" do
    assert %{"op" => "unsubscribe", "args" => [%{"channel" => "tickers"}]} =
             OpSubscribeObjects.unsubscribe([%{"channel" => "tickers"}], %{})
  end
end
