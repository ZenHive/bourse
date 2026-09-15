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

    test "per-call wait budgets stay isolated across concurrent consumers", %{name: name} do
      rate_limit = %{capacity: 1, refill_per_sec: 8}
      key_a = {"budget_a_#{:erlang.unique_integer([:positive])}", :public, "request"}
      key_b = {"budget_b_#{:erlang.unique_integer([:positive])}", :public, "request"}

      assert :ok = RateLimiter.check_rate(key_a, rate_limit, 1, name)
      assert :ok = RateLimiter.check_rate(key_b, rate_limit, 1, name)

      task_a =
        Task.async(fn ->
          RateLimiter.wait_for_capacity(key_a, rate_limit, 1, name, max_wait_ms: 40)
        end)

      task_b =
        Task.async(fn ->
          RateLimiter.wait_for_capacity(key_b, rate_limit, 1, name, max_wait_ms: 1_000)
        end)

      assert {:error, %Bourse.Error{type: :rate_limit_exceeded} = error_a} = Task.await(task_a, 2_000)
      assert error_a.message =~ "exceeds max 40ms"
      assert :ok = Task.await(task_b, 2_000)
    end

    test "an explicit budget admits a heavy request the default bound would refuse", %{name: name} do
      key = {"explicit_#{:erlang.unique_integer([:positive])}", :public, "request"}
      rate_limit = %{capacity: 1, refill_per_sec: 20}

      started = System.monotonic_time(:millisecond)

      assert {:error, %Bourse.Error{type: :rate_limit_exceeded} = refused} =
               RateLimiter.wait_for_capacity(key, rate_limit, 15, name, max_wait_ms: 200)

      assert System.monotonic_time(:millisecond) - started < 200
      assert refused.message =~ "exceeds max 200ms"
      assert refused.retry_after > 200

      assert :ok = RateLimiter.wait_for_capacity(key, rate_limit, 15, name, max_wait_ms: 2_000)
    end

    test "rejects a non-positive per-call wait budget without dispatching", %{name: name} do
      key = {"bad_budget", :public}

      assert {:error, %Bourse.Error{type: :invalid_parameters} = error} =
               RateLimiter.wait_for_capacity(key, %{capacity: 1, refill_per_sec: 1}, 1, name, max_wait_ms: 0)

      assert error.message =~ "positive integer"
      assert RateLimiter.get_cost(key, 1000, name) == 0
    end

    test "accepts a keyword wait budget without a limiter name" do
      key = {"kw_budget_#{:erlang.unique_integer([:positive])}", :public, "request"}
      rate_limit = %{capacity: 10, refill_per_sec: 10}

      assert :ok = RateLimiter.wait_for_capacity(key, rate_limit, 1, max_wait_ms: 1_000)
      assert :ok = RateLimiter.check_rates([{key, rate_limit, 1}])
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

    test "records additional cost against an existing bucket", %{name: name} do
      key = {"binance", :public, "request"}
      rate_limit = %{capacity: 10, refill_per_sec: 0.0}

      assert :ok = RateLimiter.check_rate(key, rate_limit, 3, name)
      RateLimiter.record_request(key, 2, name)
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

    test "repeated checks of one key charge the combined cost once", %{name: name} do
      key = {"binance", :public, "request"}
      rate_limit = %{capacity: 10, refill_per_sec: 0.0}

      assert :ok =
               RateLimiter.check_rates(
                 [
                   {key, rate_limit, 3},
                   {key, rate_limit, 2}
                 ],
                 name
               )

      assert RateLimiter.get_cost(key, 1000, name) == 5
      assert {:delay, _} = RateLimiter.check_rates([{key, rate_limit, 6}], name)
    end

    test "a failed multi-key admission that repeats a key spends nothing", %{name: name} do
      key = {"binance", :public, "request"}
      other = {"binance", :public, "ip"}
      rate_limit = %{capacity: 4, refill_per_sec: 0.0}

      assert {:delay, _} =
               RateLimiter.check_rates(
                 [
                   {key, rate_limit, 3},
                   {other, rate_limit, 1},
                   {key, rate_limit, 2}
                 ],
                 name
               )

      assert RateLimiter.get_cost(key, 1000, name) == 0
      assert RateLimiter.get_cost(other, 1000, name) == 0
    end

    test "incompatible duplicate bucket definitions fail before any spend", %{name: name} do
      key = {"okx", :public, "request"}

      assert {:error, %Bourse.Error{type: :invalid_parameters} = error} =
               RateLimiter.check_rates(
                 [
                   {key, %{capacity: 1, refill_per_sec: 9.09}, 1},
                   {key, %{capacity: 5, refill_per_sec: 9.09}, 1}
                 ],
                 name
               )

      assert error.exchange == "okx"
      assert error.message =~ "incompatible token-bucket"
      assert RateLimiter.get_cost(key, 1000, name) == 0
    end
  end

  describe "heavy-request reservation" do
    test "cheap traffic cannot erase accrual or steal a reserved heavy request", %{name: name} do
      key = {"fair_#{:erlang.unique_integer([:positive])}", :public, "request"}
      rate_limit = %{capacity: 1, refill_per_sec: 10}

      heavy =
        Task.async(fn ->
          RateLimiter.wait_for_capacity(key, rate_limit, 8, name, max_wait_ms: 2_000)
        end)

      assert wait_until(fn ->
               case :sys.get_state(name) do
                 %{^key => %{reserved: reserved}} when reserved >= 8 -> true
                 _ -> false
               end
             end)

      cheap =
        for _ <- 1..40 do
          RateLimiter.check_rates([{key, rate_limit, 1}], name, max_wait_ms: 10_000)
        end

      assert Enum.all?(cheap, fn
               {:delay, ms} when ms > 0 -> true
               _ -> false
             end)

      assert :ok = Task.await(heavy, 3_000)
      assert {:delay, _} = RateLimiter.check_rate(key, rate_limit, 1, name)
    end

    test "cheap requests cannot exceed authored burst while a reservation is held", %{name: name} do
      key = {"burst_#{:erlang.unique_integer([:positive])}", :public, "request"}
      rate_limit = %{capacity: 1, refill_per_sec: 5}

      assert {:delay, _} = RateLimiter.check_rates([{key, rate_limit, 4}], name, max_wait_ms: 2_000)

      state = :sys.get_state(name)
      assert %{reserved: reserved} = Map.fetch!(state, key)
      assert reserved >= 4

      cheap_ok =
        Enum.count(1..10, fn _ ->
          RateLimiter.check_rates([{key, rate_limit, 1}], name, max_wait_ms: 10_000) == :ok
        end)

      assert cheap_ok == 0
    end

    test "a waiter that exceeds its remaining budget releases the reservation", %{name: name} do
      key = {"giveup_#{:erlang.unique_integer([:positive])}", :public, "request"}
      rate_limit = %{capacity: 1, refill_per_sec: 5}

      assert {:delay, _} = RateLimiter.check_rates([{key, rate_limit, 8}], name, max_wait_ms: 2_000)
      assert %{reserved: reserved} = Map.fetch!(:sys.get_state(name), key)
      assert reserved >= 8

      assert {:error, %Bourse.Error{type: :rate_limit_exceeded}} =
               RateLimiter.wait_for_capacity(key, rate_limit, 8, name, max_wait_ms: 1)

      assert Map.fetch!(:sys.get_state(name), key).reserved == 0
    end

    test "an expired reservation clamps tokens back to authored capacity", %{name: name} do
      key = {"expire_#{:erlang.unique_integer([:positive])}", :public, "request"}
      rate_limit = %{capacity: 1, refill_per_sec: 40}

      assert {:delay, _} = RateLimiter.check_rates([{key, rate_limit, 6}], name, max_wait_ms: 2_000)
      assert %{reserved: reserved} = Map.fetch!(:sys.get_state(name), key)
      assert reserved >= 6

      Process.sleep(500)

      assert :ok = RateLimiter.check_rate(key, rate_limit, 1, name)
      bucket = Map.fetch!(:sys.get_state(name), key)
      assert bucket.reserved == 0
      assert bucket.tokens <= 1.0
    end

    test "cheap waiters cannot refresh a heavier reservation's deadline", %{name: name} do
      key = {"cheap_refresh_#{:erlang.unique_integer([:positive])}", :public, "request"}
      rate_limit = %{capacity: 1, refill_per_sec: 10}

      assert {:delay, _} = RateLimiter.check_rates([{key, rate_limit, 8}], name, max_wait_ms: 2_000)

      %{reserved: reserved, reserved_until: until} = Map.fetch!(:sys.get_state(name), key)
      assert reserved >= 8

      Process.sleep(20)

      assert {:delay, _} = RateLimiter.check_rates([{key, rate_limit, 1}], name, max_wait_ms: 10_000)

      bucket = Map.fetch!(:sys.get_state(name), key)
      assert bucket.reserved == reserved
      assert bucket.reserved_until == until
    end

    test "a failed multi-key admission does not reserve the short-delay key", %{name: name} do
      fast = {"binance", :public, "ip"}
      slow = {"binance", :public, "order_weight"}
      fast_limit = %{capacity: 1, refill_per_sec: 50}
      slow_limit = %{capacity: 1, refill_per_sec: 0.001}

      assert :ok = RateLimiter.check_rate(fast, fast_limit, 1, name)
      assert :ok = RateLimiter.check_rate(slow, slow_limit, 1, name)

      assert {:delay, delay_ms} =
               RateLimiter.check_rates(
                 [{fast, fast_limit, 1}, {slow, slow_limit, 1}],
                 name,
                 max_wait_ms: 1_000
               )

      assert delay_ms > 1_000

      state = :sys.get_state(name)
      assert Map.fetch!(state, fast).reserved == 0
      assert Map.fetch!(state, slow).reserved == 0
    end

    test "an abandoned heavy reservation expires so a cheap waiter can proceed", %{name: name} do
      key = {"abandon_#{:erlang.unique_integer([:positive])}", :public, "request"}
      rate_limit = %{capacity: 1, refill_per_sec: 40}

      assert {:delay, _} = RateLimiter.check_rates([{key, rate_limit, 6}], name, max_wait_ms: 2_000)
      assert Map.fetch!(:sys.get_state(name), key).reserved >= 6

      assert :ok = RateLimiter.wait_for_capacity(key, rate_limit, 1, name, max_wait_ms: 2_000)
      assert Map.fetch!(:sys.get_state(name), key).reserved == 0
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

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for reservation")

      true ->
        receive do
        after
          5 -> wait_until(fun, deadline)
        end
    end
  end
end
