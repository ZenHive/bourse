defmodule Bourse.WS.HeartbeatTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Heartbeat

  test "accepts the locked dependency's sending types and refuses its no-ops" do
    assert Heartbeat.supported_types() == [:deribit, :ping_pong]
    assert :ok = Heartbeat.validate(:disabled)
    assert :ok = Heartbeat.validate(%{type: :deribit, interval: 30_000})
    assert :ok = Heartbeat.validate(%{type: :ping_pong, interval: 1_000})
    assert :ok = Heartbeat.validate(%{"type" => :deribit})
    assert {:error, {:unsupported_heartbeat, :ping}} = Heartbeat.validate(%{type: :ping, interval: 1_000})
    assert {:error, {:unsupported_heartbeat, :custom}} = Heartbeat.validate(%{type: :custom, interval: 1_000})
    assert {:error, {:unsupported_heartbeat, :ping}} = Heartbeat.validate(%{"type" => :ping})
    assert {:error, {:unsupported_heartbeat, :ping}} = Heartbeat.validate(:ping)
  end
end
