defmodule Bourse.UnifiedEmulationTest do
  use ExUnit.Case, async: true

  alias Bourse.Emulation
  alias Bourse.Exchange

  test "Unified.call passthrough reaches HTTP for native endpoints" do
    {:ok, exchange} = Exchange.new("bybit")
    refute Emulation.emulated?(exchange, :fetch_ticker, :rest)
    assert Bourse.Bybit.__unified_endpoint__(:fetch_ticker) != []
  end
end
