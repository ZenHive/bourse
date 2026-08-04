defmodule Bourse.TimestampTest do
  use ExUnit.Case, async: true

  alias Bourse.Timestamp

  # 2023-11-14T22:03:20.123Z
  @ms 1_699_999_400_123

  describe "iso8601_from_ms/1" do
    test "formats a millisecond timestamp as UTC ISO 8601 with millisecond precision" do
      assert Timestamp.iso8601_from_ms(@ms) == "2023-11-14T22:03:20.123Z"
    end

    test "returns nil when the timestamp is absent" do
      assert Timestamp.iso8601_from_ms(nil) == nil
    end
  end

  describe "iso8601_seconds_from_ms/1" do
    test "truncates to whole seconds and omits the zone designator" do
      assert Timestamp.iso8601_seconds_from_ms(@ms) == "2023-11-14T22:03:20"
    end

    test "returns nil when the timestamp is absent" do
      assert Timestamp.iso8601_seconds_from_ms(nil) == nil
    end

    test "formats in UTC regardless of the host time zone" do
      # Epoch second 0 pins the UTC anchor — a local-time formatter would drift.
      assert Timestamp.iso8601_seconds_from_ms(0) == "1970-01-01T00:00:00"
    end

    test "zero-pads every component to the documented fixed width" do
      assert Timestamp.iso8601_seconds_from_ms(1_041_411_845_000) == "2003-01-01T09:04:05"
    end
  end
end
