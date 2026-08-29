defmodule Bourse.RateLimiterTest do
  use Bourse.Test.Case, async: true

  alias Bourse.RateLimiter

  @moduletag trace_messages: true

  setup do
    # Start a fresh rate limiter per test with a unique name
    name = :"rate_limiter_#{:erlang.unique_integer([:positive])}"
    start_supervised!({RateLimiter, name: name})
    {:ok, name: name}
  end

  describe "check_rate/4" do
    test "returns :ok when within limits", %{name: name} do
      key = {"binance", :public}
      rate_limit = %{requests: 10, period: 1000}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
    end

    test "returns :ok for nil rate_limit", %{name: name} do
      key = {"binance", :public}
      assert :ok = RateLimiter.check_rate(key, nil, 1, name)
    end

    test "returns {:delay, ms} when over limit", %{name: name} do
      key = {"binance", :public}
      rate_limit = %{requests: 5, period: 1000}

      # Fill up capacity
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
      end

      # Next request should be delayed
      assert {:delay, delay_ms} = RateLimiter.check_rate(key, rate_limit, 1, name)
      assert delay_ms > 0
      assert delay_ms <= 1001
    end

    test "weighted costs consume proportional capacity", %{name: name} do
      key = {"binance", :public}
      rate_limit = %{requests: 10, period: 1000}

      # Single request with cost 8 — leaves 2
      assert :ok = RateLimiter.check_rate(key, rate_limit, 8, name)

      # Cost 2 fits exactly
      assert :ok = RateLimiter.check_rate(key, rate_limit, 2, name)

      # Cost 1 exceeds
      assert {:delay, _} = RateLimiter.check_rate(key, rate_limit, 1, name)
    end

    test "uses default period when not specified", %{name: name} do
      key = {"binance", :public}
      rate_limit = %{requests: 2}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
      assert {:delay, _} = RateLimiter.check_rate(key, rate_limit, 1, name)
    end

    test "a single cost exceeding capacity is delayed, not skip-recorded", %{name: name} do
      key = {"binance", :public}
      rate_limit = %{capacity: 5, refill_per_sec: 5}

      assert {:delay, delay_ms} = RateLimiter.check_rate(key, rate_limit, 10, name)
      assert delay_ms > 0
      assert RateLimiter.get_cost(key, 1000, name) == 0
    end

    test "token-bucket capacity and refill admit until empty then delay", %{name: name} do
      key = {"okx", :public}
      rate_limit = %{capacity: 1, refill_per_sec: 9.09}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
      assert {:delay, delay_ms} = RateLimiter.check_rate(key, rate_limit, 1, name)
      assert delay_ms > 0
      assert delay_ms <= 200
    end
  end

  describe "reset_all/1" do
    test "clears every tracked key", %{name: name} do
      rate_limit = %{requests: 1, period: 1000}
      key_a = {"binance", :public}
      key_b = {"bybit", "api_key", "ip"}

      assert :ok = RateLimiter.check_rate(key_a, rate_limit, 1, name)
      assert :ok = RateLimiter.check_rate(key_b, rate_limit, 1, name)
      assert {:delay, _} = RateLimiter.check_rate(key_a, rate_limit, 1, name)

      assert :ok = RateLimiter.reset_all(name)
      assert :ok = RateLimiter.check_rate(key_a, rate_limit, 1, name)
      assert :ok = RateLimiter.check_rate(key_b, rate_limit, 1, name)
    end
  end

  describe "reset_exchange/2" do
    test "clears only the named exchange's buckets, leaving siblings paced", %{name: name} do
      # Slow drain so the sibling cannot silently refill during the assertion.
      rate_limit = %{capacity: 1, refill_per_sec: 0.001}
      okx_public = {"okx", :public, "request"}
      okx_private = {"okx", "api_key", "request"}
      bybit_key = {"bybit", :public, "request"}

      assert :ok = RateLimiter.check_rate(okx_public, rate_limit, 1, name)
      assert :ok = RateLimiter.check_rate(okx_private, rate_limit, 1, name)
      assert :ok = RateLimiter.check_rate(bybit_key, rate_limit, 1, name)

      assert :ok = RateLimiter.reset_exchange("okx", name)

      # Both okx buckets are fresh again...
      assert :ok = RateLimiter.check_rate(okx_public, rate_limit, 1, name)
      assert :ok = RateLimiter.check_rate(okx_private, rate_limit, 1, name)

      # ...while bybit keeps the cost it already spent.
      assert {:delay, _} = RateLimiter.check_rate(bybit_key, rate_limit, 1, name)
    end

    test "is a no-op for an exchange with no tracked buckets", %{name: name} do
      rate_limit = %{capacity: 1, refill_per_sec: 0.001}
      key = {"bybit", :public, "request"}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
      assert :ok = RateLimiter.reset_exchange("deribit", name)
      assert {:delay, _} = RateLimiter.check_rate(key, rate_limit, 1, name)
    end
  end

  describe "per-credential isolation" do
    test "different bucket axes have independent limits for the same credential", %{name: name} do
      rate_limit = %{requests: 1, period: 1000}

      ip_key = {"binance", "api_key_a", "ip"}
      order_key = {"binance", "api_key_a", "order_weight"}

      assert :ok = RateLimiter.check_rate(ip_key, rate_limit, 1, name)
      assert {:delay, _} = RateLimiter.check_rate(ip_key, rate_limit, 1, name)

      assert :ok = RateLimiter.check_rate(order_key, rate_limit, 1, name)
    end

    test "different API keys have independent limits", %{name: name} do
      rate_limit = %{requests: 2, period: 1000}

      key_a = {"binance", "api_key_a"}
      key_b = {"binance", "api_key_b"}

      # Fill key_a
      assert :ok = RateLimiter.check_rate(key_a, rate_limit, 2, name)
      assert {:delay, _} = RateLimiter.check_rate(key_a, rate_limit, 1, name)

      # key_b still has capacity
      assert :ok = RateLimiter.check_rate(key_b, rate_limit, 1, name)
    end

    test "public and authenticated keys are separate", %{name: name} do
      rate_limit = %{requests: 1, period: 1000}

      public_key = {"binance", :public}
      auth_key = {"binance", "my_api_key"}

      assert :ok = RateLimiter.check_rate(public_key, rate_limit, 1, name)
      assert {:delay, _} = RateLimiter.check_rate(public_key, rate_limit, 1, name)

      # Auth key unaffected
      assert :ok = RateLimiter.check_rate(auth_key, rate_limit, 1, name)
    end

    test "different exchanges have independent limits", %{name: name} do
      rate_limit = %{requests: 1, period: 1000}

      assert :ok = RateLimiter.check_rate({"binance", :public}, rate_limit, 1, name)
      assert {:delay, _} = RateLimiter.check_rate({"binance", :public}, rate_limit, 1, name)

      # Bybit unaffected
      assert :ok = RateLimiter.check_rate({"bybit", :public}, rate_limit, 1, name)
    end
  end

  describe "get_cost/3" do
    test "returns total cost within window", %{name: name} do
      key = {"binance", :public}
      # Refill is frozen for the assertion window: get_cost/3 reports
      # `capacity - tokens` AFTER refilling, so a live drain rate makes the
      # charged total drift by `refill_per_sec * elapsed` between calls.
      rate_limit = %{capacity: 100, refill_per_sec: 0.0}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 3, name)
      assert :ok = RateLimiter.check_rate(key, rate_limit, 5, name)

      assert RateLimiter.get_cost(key, 1000, name) == 8
    end

    test "returns 0 for unknown key", %{name: name} do
      assert RateLimiter.get_cost({"unknown", :public}, 1000, name) == 0
    end
  end

  describe "reset/2" do
    test "clears tracking for a key", %{name: name} do
      key = {"binance", :public}
      rate_limit = %{requests: 1, period: 1000}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
      assert {:delay, _} = RateLimiter.check_rate(key, rate_limit, 1, name)

      RateLimiter.reset(key, name)
      # Drain cast mailbox before asserting (call waits for prior messages)
      _ = :sys.get_state(name)

      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
    end
  end

  describe "wait_for_capacity/4" do
    test "returns :ok immediately when within limits", %{name: name} do
      key = {"binance", :public}
      rate_limit = %{requests: 10, period: 1000}

      assert :ok = RateLimiter.wait_for_capacity(key, rate_limit, 1, name)
    end

    test "returns :ok for nil rate_limit", %{name: name} do
      assert :ok = RateLimiter.wait_for_capacity({"x", :public}, nil, 1, name)
    end

    test "blocks over the delay then succeeds once capacity frees up", %{name: name} do
      key = {"binance", :public}
      rate_limit = %{requests: 1, period: 30}

      # Consume the only slot; the next request is over limit and must wait.
      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)

      # wait_for_capacity sleeps the returned delay and retries until the window frees.
      assert :ok = RateLimiter.wait_for_capacity(key, rate_limit, 1, name)
    end

    test "returns rate_limit_exceeded when the wait would exceed the named bound", %{name: name} do
      key = {"okx", :public}
      rate_limit = %{capacity: 1, refill_per_sec: 0.001}
      max_wait = Bourse.Defaults.rate_limit_max_wait_ms()

      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Bourse.Error{type: :rate_limit_exceeded} = error} =
               RateLimiter.wait_for_capacity(key, rate_limit, 1, name)

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 200
      assert error.exchange == "okx"
      assert error.message =~ "okx"
      assert error.message =~ "exceeds max #{max_wait}ms"
      assert error.retry_after > max_wait
    end
  end

  describe "record_request/3" do
    test "manually records a request cost", %{name: name} do
      key = {"binance", :public}

      RateLimiter.record_request(key, 5, name)
      # Drain cast mailbox before asserting (call waits for prior messages)
      _ = :sys.get_state(name)

      assert RateLimiter.get_cost(key, 1000, name) == 5
    end
  end

  describe "check_rates/2" do
    test "records all bucket costs when every bucket has capacity", %{name: name} do
      ip_key = {"binance", :public, "ip"}
      order_key = {"binance", :public, "order_weight"}
      # Frozen refill so the charged totals cannot drift between the two reads.
      rate_limit = %{capacity: 10, refill_per_sec: 0.0}

      assert :ok =
               RateLimiter.check_rates(
                 [
                   {ip_key, rate_limit, 3},
                   {order_key, rate_limit, 2}
                 ],
                 name
               )

      assert RateLimiter.get_cost(ip_key, 1000, name) == 3
      assert RateLimiter.get_cost(order_key, 1000, name) == 2
    end

    test "does not partially record when any bucket is over limit", %{name: name} do
      ip_key = {"binance", :public, "ip"}
      order_key = {"binance", :public, "order_weight"}
      # Frozen refill: the reads below assert exact charged costs.
      rate_limit = %{capacity: 1, refill_per_sec: 0.0}

      assert :ok = RateLimiter.check_rate(order_key, rate_limit, 1, name)

      assert {:delay, _} =
               RateLimiter.check_rates(
                 [
                   {ip_key, rate_limit, 1},
                   {order_key, rate_limit, 1}
                 ],
                 name
               )

      assert RateLimiter.get_cost(ip_key, 1000, name) == 0
      assert RateLimiter.get_cost(order_key, 1000, name) == 1
    end

    test "per-key bucket state stays O(1) under sustained volume", %{name: name} do
      key = {"binance", :public, "ip"}
      rate_limit = %{capacity: 10_000, refill_per_sec: 10_000}
      burst = 100

      for _ <- 1..burst do
        assert :ok = RateLimiter.check_rates([{key, rate_limit, 1}], name)
      end

      state_after_burst = :sys.get_state(name)
      bucket = Map.fetch!(state_after_burst, key)
      assert is_map(bucket)
      assert is_number(bucket.tokens)
      assert map_size(state_after_burst) == 1

      for _ <- 1..burst do
        _ = RateLimiter.check_rates([{key, rate_limit, 1}], name)
      end

      state_after_more = :sys.get_state(name)
      assert map_size(state_after_more) == 1
      assert is_map(Map.fetch!(state_after_more, key))
    end

    test "uses the default period when a bucket rate_limit omits it", %{name: name} do
      key = {"binance", :public, "ip"}
      rate_limit = %{requests: 2}

      assert :ok = RateLimiter.check_rates([{key, rate_limit, 1}], name)
      assert :ok = RateLimiter.check_rates([{key, rate_limit, 1}], name)
      assert {:delay, _} = RateLimiter.check_rates([{key, rate_limit, 1}], name)
    end
  end

  describe "cleanup" do
    test "expired timestamps are not counted toward cost", %{name: name} do
      key = {"binance", :public}
      period_ms = 50
      rate_limit = %{requests: 100, period: period_ms}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 10, name)

      # Wait for entries to age past the rate window (real time, not cast-sync)
      Process.sleep(period_ms + 20)

      assert RateLimiter.get_cost(key, period_ms, name) == 0
    end

    test "the periodic :cleanup pass keeps in-window entries", %{name: name} do
      key = {"binance", :public}
      # Frozen refill. `:sys.get_state/1` below can take tens of milliseconds
      # when it has to load the `:sys` module, and `get_cost/3` refills before
      # reporting, so any positive drain rate turns the exact assertion into a
      # timing coin flip (observed live: 2.9999619999999965 against 3).
      rate_limit = %{capacity: 100, refill_per_sec: 0.0}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 3, name)

      # Drive the periodic sweep directly (no 60s wait); the synchronous call
      # after it drains the message so the state reflects the cleanup pass.
      send(name, :cleanup)
      _ = :sys.get_state(name)

      # Recent entry is younger than the max-age horizon, so it survives.
      assert RateLimiter.get_cost(key, 1000, name) == 3
    end
  end
end
