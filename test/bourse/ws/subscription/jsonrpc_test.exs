defmodule Bourse.WS.Subscription.JsonRpcTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.JsonRpc

  test "subscribe wraps channels in a JSON-RPC 2.0 envelope" do
    assert %{
             "jsonrpc" => "2.0",
             "method" => "public/subscribe",
             "params" => %{"channels" => ["ticker.BTC-PERPETUAL"]},
             "id" => id
           } = JsonRpc.subscribe(["ticker.BTC-PERPETUAL"], %{})

    assert is_integer(id) and id > 0
  end

  test "unsubscribe swaps to public/unsubscribe" do
    assert %{"method" => "public/unsubscribe"} = JsonRpc.unsubscribe(["ticker.BTC-PERPETUAL"], %{})
  end

  test "honours method override (e.g. private/subscribe)" do
    assert %{"method" => "private/subscribe"} =
             JsonRpc.subscribe(["user.orders"], %{method: "private/subscribe"})

    assert %{"method" => "private/unsubscribe"} =
             JsonRpc.unsubscribe(["user.orders"], %{method: "private/subscribe"})
  end

  test "honours explicit id override" do
    assert %{"id" => 42} = JsonRpc.subscribe(["x"], %{id: 42})
  end
end
