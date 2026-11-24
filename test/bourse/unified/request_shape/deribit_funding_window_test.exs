defmodule Bourse.Unified.RequestShape.DeribitFundingWindowTest do
  use ExUnit.Case, async: true

  alias Bourse.Unified.RequestShape

  @hour 3_600_000
  @now 1_795_561_200_000

  describe "resolve_deribit_funding_window/2" do
    test "no caller bound resolves to the eight-hour window ending at the request clock" do
      assert %{"symbol" => "BTC/USD:BTC", "start_timestamp" => start, "end_timestamp" => @now} =
               RequestShape.resolve_deribit_funding_window(%{"symbol" => "BTC/USD:BTC"}, @now)

      assert start == @now - 8 * @hour
    end

    test "a start-only window ends at the request clock" do
      assert %{"start_timestamp" => start, "end_timestamp" => @now} =
               RequestShape.resolve_deribit_funding_window(%{"since" => @now - 4 * @hour}, @now)

      assert start == @now - 4 * @hour
    end

    test "an end-only window starts eight hours before the caller's end" do
      finish = @now - @hour

      assert %{"start_timestamp" => start, "end_timestamp" => ^finish} =
               RequestShape.resolve_deribit_funding_window(%{"until" => finish}, @now)

      assert start == finish - 8 * @hour
    end

    test "numeric-string bounds are bounds, resolved to integers" do
      resolved =
        RequestShape.resolve_deribit_funding_window(
          %{"start_timestamp" => Integer.to_string(@now - 4 * @hour), "end_timestamp" => Integer.to_string(@now)},
          @now + 5 * @hour
        )

      assert resolved["start_timestamp"] == @now - 4 * @hour
      assert resolved["end_timestamp"] == @now
    end

    test "the unified spellings are replaced by the native keys" do
      resolved = RequestShape.resolve_deribit_funding_window(%{"since" => 1, "until" => 2}, @now)

      refute Map.has_key?(resolved, "since")
      refute Map.has_key?(resolved, "until")
    end
  end

  describe "deribit_funding_window_ms/1" do
    test "reads the span of two resolved bounds at full precision" do
      assert RequestShape.deribit_funding_window_ms(%{"start_timestamp" => 0, "end_timestamp" => 4 * @hour - 123}) ==
               {:ok, 4 * @hour - 123}
    end

    test "an unresolved or inverted window is unknown" do
      assert :unknown = RequestShape.deribit_funding_window_ms(%{"start_timestamp" => 0})
      assert :unknown = RequestShape.deribit_funding_window_ms(%{"start_timestamp" => @hour, "end_timestamp" => 0})
    end
  end
end
