defmodule Bourse.Unified.RequestShape.DeribitFundingWindowTest do
  use ExUnit.Case, async: true

  alias Bourse.Unified.RequestShape

  @hour 3_600_000

  test "no caller window is the authored eight-hour default" do
    assert RequestShape.deribit_funding_window_ms(%{"symbol" => "BTC/USD:BTC"}) == {:ok, 8 * @hour}
  end

  test "a caller window is the caller's span, under either key spelling" do
    assert RequestShape.deribit_funding_window_ms(%{"start_timestamp" => 0, "end_timestamp" => 4 * @hour}) ==
             {:ok, 4 * @hour}

    assert {:ok, @hour} = RequestShape.deribit_funding_window_ms(%{"since" => @hour, "until" => 2 * @hour})
  end

  test "one caller-set end leaves the window unknown" do
    assert :unknown = RequestShape.deribit_funding_window_ms(%{"start_timestamp" => 0})
    assert :unknown = RequestShape.deribit_funding_window_ms(%{"until" => @hour})
  end
end
