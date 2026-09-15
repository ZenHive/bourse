defmodule Bourse.WS.ControlFrameTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.ControlFrame

  test "Deribit subscriptions are market data; version results and errors are control" do
    assert ControlFrame.classify(%{
             "method" => "subscription",
             "params" => %{"channel" => "ticker.BTC-PERPETUAL.100ms", "data" => %{}}
           }) == :market

    assert ControlFrame.classify(%{"jsonrpc" => "2.0", "result" => %{"version" => "1.2.26"}}) ==
             :control

    assert ControlFrame.classify(%{
             "jsonrpc" => "2.0",
             "error" => %{"code" => 13_778, "message" => "raw_subscriptions_not_available_for_unauthorized"}
           }) == :control
  end

  test "ping and pong keepalives are control in JSON and plaintext" do
    assert ControlFrame.classify(%{"method" => "heartbeat"}) == :control
    assert ControlFrame.classify(%{"method" => "ping"}) == :control
    assert ControlFrame.classify(%{"op" => "ping"}) == :control
    assert ControlFrame.classify(%{"op" => "pong"}) == :control
    assert ControlFrame.classify(%{"event" => "ping"}) == :control
    assert ControlFrame.classify(%{"type" => "pong"}) == :control
    assert ControlFrame.classify("ping") == :control
    assert ControlFrame.classify("PONG") == :control
    assert ControlFrame.classify("ticker") == :market
  end
end
