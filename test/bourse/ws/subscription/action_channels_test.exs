defmodule Bourse.WS.Subscription.ActionChannelsTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription.ActionChannels

  test "groups Alpaca channel:symbol entries under the action envelope" do
    assert %{
             "action" => "subscribe",
             "trades" => ["FAKEPACA", "AAPL"],
             "quotes" => ["FAKEPACA"]
           } =
             ActionChannels.subscribe(
               ["trades:FAKEPACA", "quotes:FAKEPACA", "trades:AAPL"],
               %{}
             )
  end

  test "unsubscribe changes only the action" do
    assert %{"action" => "unsubscribe", "trades" => ["FAKEPACA"]} =
             ActionChannels.unsubscribe(["trades:FAKEPACA"], %{})
  end

  test "rejects malformed and non-string channels" do
    assert {:error, {:invalid_channel, "trades"}} =
             ActionChannels.subscribe(["trades"], %{})

    assert {:error, {:invalid_channel, %{channel: "trades"}}} =
             ActionChannels.subscribe([%{channel: "trades"}], %{})
  end
end
