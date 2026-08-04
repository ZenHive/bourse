defmodule Bourse.WS.Auth.ExpiryTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Auth.Expiry

  describe "compute_ttl_ms/2" do
    test "response-level auth_meta.ttl_ms wins over config" do
      assert Expiry.compute_ttl_ms(%{ttl_ms: 900_000}, %{auth_ttl_ms: 300_000}) == 900_000
    end

    test "falls back to auth_config[:auth_ttl_ms] when response has no ttl" do
      assert Expiry.compute_ttl_ms(%{}, %{auth_ttl_ms: 300_000}) == 300_000
    end

    test "returns nil when neither source provides a positive integer" do
      assert Expiry.compute_ttl_ms(nil, nil) == nil
      assert Expiry.compute_ttl_ms(%{}, %{}) == nil
      assert Expiry.compute_ttl_ms(%{ttl_ms: 0}, %{}) == nil
      assert Expiry.compute_ttl_ms(%{ttl_ms: -1}, %{}) == nil
      assert Expiry.compute_ttl_ms(%{}, %{auth_ttl_ms: 0}) == nil
    end

    test "ignores non-integer ttl values" do
      assert Expiry.compute_ttl_ms(%{ttl_ms: "900"}, %{}) == nil
      assert Expiry.compute_ttl_ms(%{ttl_ms: 1.5}, %{}) == nil
    end
  end

  describe "schedule_delay_ms/1" do
    test "applies the 80% safety margin" do
      assert Expiry.schedule_delay_ms(1_000_000) == 800_000
      assert Expiry.schedule_delay_ms(900_000) == 720_000
    end

    test "caps at 24 hours" do
      # 48 hours in ms — 80% would be > 24h, so it should be capped
      assert Expiry.schedule_delay_ms(48 * 3_600_000) == 86_400_000
    end

    test "returns nil for nil or non-positive input" do
      assert Expiry.schedule_delay_ms(nil) == nil
      assert Expiry.schedule_delay_ms(0) == nil
      assert Expiry.schedule_delay_ms(-500) == nil
    end
  end
end
