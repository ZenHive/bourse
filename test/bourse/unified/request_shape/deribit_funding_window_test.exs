defmodule Bourse.Unified.RequestShape.DeribitFundingWindowTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Unified
  alias Bourse.Unified.RequestShape

  @hour 3_600_000
  @now 1_795_561_200_000

  describe "deribit_funding_window_ms/1" do
    test "reads the span of two integer bounds at full precision" do
      assert RequestShape.deribit_funding_window_ms(%{"start_timestamp" => 0, "end_timestamp" => 4 * @hour - 123}) ==
               {:ok, 4 * @hour - 123}
    end

    test "reads a string bound only when the whole string is an integer" do
      assert RequestShape.deribit_funding_window_ms(%{
               "start_timestamp" => Integer.to_string(@now - 4 * @hour),
               "end_timestamp" => Integer.to_string(@now)
             }) == {:ok, 4 * @hour}

      for malformed <- ["oops", "#{@now - 4 * @hour}oops", " #{@now - 4 * @hour}", ""] do
        assert :unknown =
                 RequestShape.deribit_funding_window_ms(%{"start_timestamp" => malformed, "end_timestamp" => @now}),
               "#{inspect(malformed)} must not read as a bound"
      end
    end

    test "a missing or inverted bound is unknown" do
      assert :unknown = RequestShape.deribit_funding_window_ms(%{"start_timestamp" => 0})
      assert :unknown = RequestShape.deribit_funding_window_ms(%{"start_timestamp" => @hour, "end_timestamp" => 0})
    end
  end

  # The bounds dispatched for each caller combination; the label reads these,
  # so they must be exactly what the request shaper already sends.
  describe "dispatched fetchFundingRate bounds" do
    setup do
      {:ok, exchange: Exchange.new!("deribit")}
    end

    test "absent bounds sit on the request clock", %{exchange: exchange} do
      assert %{"start_timestamp" => start, "end_timestamp" => @now} = shape(exchange, %{})
      assert start == @now - 8 * @hour
    end

    test "an end-only request keeps its start on the request clock", %{exchange: exchange} do
      assert %{"start_timestamp" => start, "end_timestamp" => finish} =
               shape(exchange, %{"end_timestamp" => @now - @hour})

      assert {start, finish} == {@now - 8 * @hour, @now - @hour}
    end

    test "a start-only request ends on the request clock", %{exchange: exchange} do
      assert %{"start_timestamp" => start, "end_timestamp" => @now} = shape(exchange, %{"since" => @now - 4 * @hour})
      assert start == @now - 4 * @hour
    end

    test "caller string bounds, numeric or not, are sent unchanged", %{exchange: exchange} do
      for value <- [Integer.to_string(@now - 4 * @hour), "oops", "#{@now - 4 * @hour}oops"] do
        assert %{"start_timestamp" => ^value} = shape(exchange, %{"start_timestamp" => value})
      end
    end
  end

  defp shape(exchange, params) do
    assert {:ok, [shape]} =
             Unified.request_param_shapes(
               exchange,
               :fetch_funding_rate,
               Map.put(params, "symbol", "BTC/USD:BTC"),
               timestamp_ms_override: @now
             )

    shape
  end
end
