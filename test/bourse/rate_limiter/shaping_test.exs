defmodule Bourse.RateLimiter.ShapingTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.RateLimiter
  alias Bourse.RateLimiter.Info
  alias Bourse.RateLimiter.Shaping
  alias Bourse.RateLimiter.State

  setup do
    exchange = %Exchange{
      id: "shaping_test_#{System.unique_integer([:positive])}",
      name: "Shaping Test",
      credentials: nil,
      sandbox: false,
      rate_limit_ms: 100,
      hostname: nil,
      base_urls: %{"public" => "https://api.test.com"},
      has: %{},
      required_credentials: %{},
      options: %{},
      error_codes: %{},
      broad_error_patterns: %{},
      error_body_checks: [],
      error_code_fields: [],
      http_exceptions: %{},
      spec: %{}
    }

    {:ok, exchange: exchange}
  end

  describe "rate_key/1" do
    test "uses :public when credentials are nil", %{exchange: exchange} do
      assert Shaping.rate_key(exchange) == {exchange.id, :public}
    end

    test "uses api_key when present", %{exchange: exchange} do
      creds = %Credentials{api_key: "k1", secret: "s1"}
      exchange = %{exchange | credentials: creds}
      assert Shaping.rate_key(exchange) == {exchange.id, "k1"}
    end

    test "falls back to :public when credentials have nil api_key", %{exchange: exchange} do
      creds = %Credentials{api_key: nil, secret: "s1"}
      exchange = %{exchange | credentials: creds}
      assert Shaping.rate_key(exchange) == {exchange.id, :public}
    end
  end

  describe "build_rate_limit_checks/3" do
    test "numeric weight uses default request axis as a token bucket", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{id, :public, "request"}, %{capacity: 1, refill_per_sec: refill}, 3}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, 3)

      assert id == exchange.id
      assert_in_delta refill, 10.0, 0.0001
    end

    test "map with axes and cost shapes multi-axis checks", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      checks =
        Shaping.build_rate_limit_checks(rate_key, exchange, %{
          axes: ["ip", "order_weight"],
          cost: 5,
          rate_limit_ms: 50
        })

      assert length(checks) == 2

      assert Enum.all?(checks, fn {_key, %{capacity: cap, refill_per_sec: refill}, cost} ->
               cap == 1 and abs(refill - 20.0) < 0.0001 and cost == 5
             end)

      axes = Enum.map(checks, fn {{_id, :public, axis}, _, _} -> axis end)
      assert axes == ["ip", "order_weight"]
    end

    test "string-key maps are accepted", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{_, :public, "uid"}, %{capacity: 1, refill_per_sec: refill}, 2}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, %{
                 "axes" => ["uid"],
                 "cost" => 2,
                 "rate_limit_ms" => 100
               })

      assert_in_delta refill, 10.0, 0.0001
    end

    test "list of descriptors expands flatly", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      checks =
        Shaping.build_rate_limit_checks(rate_key, exchange, [
          %{axes: ["ip"], cost: 1},
          %{axes: ["order_weight"], cost: 10}
        ])

      assert length(checks) == 2
      costs = Enum.map(checks, fn {_, _, cost} -> cost end)
      assert costs == [1, 10]
    end

    test "empty or invalid axes fall back to request axis", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{_, :public, "request"}, _, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, %{axes: [], cost: 1})

      assert [{{_, :public, "request"}, _, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, %{axes: [1, :atom], cost: 1})

      assert [{{_, :public, "request"}, _, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, %{axes: %{}, cost: 1})
    end

    test "map-shaped axes values are flattened", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{_, :public, "ip"}, _, 1}, {{_, :public, "uid"}, _, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, %{
                 axes: %{"a" => "ip", "b" => ["uid"]},
                 cost: 1
               })
    end

    test "non-positive rate_limit_ms drops the check", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)
      exchange = %{exchange | rate_limit_ms: 0}
      assert Shaping.build_rate_limit_checks(rate_key, exchange, 1) == []
    end

    test "unknown descriptor shape falls back to weight 1", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{_, :public, "request"}, %{capacity: 1, refill_per_sec: refill}, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, :not_a_descriptor)

      assert_in_delta refill, 10.0, 0.0001
    end

    test "authored max_size and refill_per_sec are the limiter, not a 60s window", %{exchange: exchange} do
      exchange = %{
        exchange
        | config: %{"rate_limit_bucket" => %{max_size: 1, refill_per_sec: 9.09, rate_limit_ms: 110}}
      }

      rate_key = Shaping.rate_key(exchange)

      assert [{{_, :public, "request"}, %{capacity: 1, refill_per_sec: refill}, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, 1)

      assert_in_delta refill, 9.09, 0.0001
      refute match?({_, %{requests: _, period: 60_000}, _}, hd(Shaping.build_rate_limit_checks(rate_key, exchange, 1)))
    end

    test "non-numeric cost defaults to 1", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{_, :public, "request"}, _, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, %{cost: "x", axes: ["request"]})
    end
  end

  describe "maybe_update_state/2" do
    test "returns :ok when headers carry no rate-limit info", %{exchange: exchange} do
      assert :ok = Shaping.maybe_update_state(exchange, %{"content-type" => ["application/json"]})
    end

    test "stores parsed binance weight under the ip axis", %{exchange: exchange} do
      headers = %{"x-mbx-used-weight-1m" => ["42"]}
      assert :ok = Shaping.maybe_update_state(exchange, headers)

      assert %Info{used: 42, axis: "ip"} =
               State.status(exchange.id, :public, "ip")
    end
  end

  describe "maybe_rate_limit/3" do
    test "returns :ok when limiter is enabled and capacity is free", %{exchange: exchange} do
      # Slowest drain the authored-bucket clause accepts — `bucket_limit/1`
      # requires `refill_per_sec > 0`, so unlike the limiter's own tests this
      # one cannot freeze the clock entirely. `get_cost/3` refills before
      # reporting, so the charged cost decays by `refill_per_sec * elapsed`:
      # assert the charge within a tolerance that the drain cannot cross,
      # never exact equality, which is a timing coin flip.
      exchange = %{
        exchange
        | config: %{"rate_limit_bucket" => %{max_size: 5, refill_per_sec: 0.001}}
      }

      rate_key = Shaping.rate_key(exchange)
      assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)
      assert_in_delta RateLimiter.get_cost({exchange.id, :public, "request"}, 60_000), 1, 0.01
    end

    test "throttles then retries when the bucket is exhausted", %{exchange: exchange} do
      exchange = %{exchange | rate_limit_ms: 40}
      rate_key = Shaping.rate_key(exchange)

      parent = self()
      ref = make_ref()
      handler_id = "shaping-throttle-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        Bourse.Telemetry.rate_limiter_throttled(),
        fn _event, measurements, metadata, _config ->
          send(parent, {:throttled, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)
      # Second call hits {:delay, _}, emits telemetry, sleeps ~1/refill, then retries to :ok
      assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)

      assert_received {:throttled, %{delay_ms: delay_ms, cost: cost}, %{exchange: id}}
      assert delay_ms > 0
      assert delay_ms <= 80
      assert cost >= 1
      assert id == exchange.id
    end

    test "returns rate_limit_exceeded without sleeping past the named bound", %{exchange: exchange} do
      exchange = %{
        exchange
        | config: %{"rate_limit_bucket" => %{max_size: 1, refill_per_sec: 0.001}}
      }

      rate_key = Shaping.rate_key(exchange)
      max_wait = Bourse.Defaults.rate_limit_max_wait_ms()

      assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Bourse.Error{type: :rate_limit_exceeded} = error} =
               Shaping.maybe_rate_limit(rate_key, exchange, 1)

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 200
      assert error.exchange == exchange.id
      assert error.message =~ exchange.id
      assert error.message =~ "exceeds max #{max_wait}ms"
    end

    test "returns :ok when rate limiter is disabled", %{exchange: exchange} do
      previous = Application.get_env(:bourse, :rate_limiter_enabled, true)
      Application.put_env(:bourse, :rate_limiter_enabled, false)
      on_exit(fn -> Application.put_env(:bourse, :rate_limiter_enabled, previous) end)

      rate_key = Shaping.rate_key(exchange)
      assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)
      # No cost recorded while disabled
      assert RateLimiter.get_cost({exchange.id, :public, "request"}, 60_000) == 0
    end

    test "returns :ok when checks list is empty (non-positive rate_limit_ms)", %{exchange: exchange} do
      exchange = %{exchange | rate_limit_ms: 0}
      rate_key = Shaping.rate_key(exchange)
      assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)
    end
  end

  describe "normalize_axes edge cases via build_rate_limit_checks/3" do
    test "non-list non-map axes fall back to request", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{_, :public, "request"}, _, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, %{axes: :invalid, cost: 1})
    end
  end

  describe "over-capacity costs on authored venues" do
    test "every runtime venue delays a cost above max_size; no endpoint skip-records" do
      name = :"authored_bucket_#{:erlang.unique_integer([:positive])}"
      start_supervised!({RateLimiter, name: name})

      venues = Bourse.Registry.exchanges()
      assert length(venues) == 11

      for venue <- venues do
        exchange = Exchange.new!(venue)
        bucket = Map.fetch!(exchange.config, "rate_limit_bucket")
        max_size = bucket.max_size
        refill = bucket.refill_per_sec

        assert is_number(max_size) and max_size > 0,
               "#{venue} authored max_size is missing or non-positive: #{inspect(bucket)}"

        assert is_number(refill) and refill > 0,
               "#{venue} authored refill_per_sec is missing or non-positive: #{inspect(bucket)}"

        RateLimiter.reset_all(name)
        over_cost = max_size + 1
        checks = Shaping.build_rate_limit_checks({venue, :public}, exchange, over_cost)
        assert checks != [], "#{venue} produced no limiter checks for over-capacity cost #{over_cost}"

        assert {:delay, delay_ms} = RateLimiter.check_rates(checks, name),
               "#{venue} skip-recorded over-capacity cost #{over_cost} instead of delaying"

        assert delay_ms > 0
        assert RateLimiter.get_cost({venue, :public, "request"}, 1, name) == 0

        for {_key, %{rate_limit: %{cost: cost} = rate_limit}} <- exchange.request_contracts,
            is_number(cost) and cost > max_size do
          RateLimiter.reset_all(name)
          endpoint_checks = Shaping.build_rate_limit_checks({venue, :public}, exchange, rate_limit)

          assert {:delay, _} = RateLimiter.check_rates(endpoint_checks, name),
                 "#{venue} endpoint cost #{cost} > max_size #{max_size} was not limited"
        end
      end
    end

    test "an authored cost that outruns the wait bound errors immediately instead of sleeping" do
      okx = Exchange.new!("okx")
      bucket = Map.fetch!(okx.config, "rate_limit_bucket")
      max_wait = Bourse.Defaults.rate_limit_max_wait_ms()

      over_bound =
        Enum.find(okx.request_contracts, fn {_key, %{rate_limit: rate_limit}} ->
          is_map(rate_limit) and is_number(rate_limit[:cost]) and
            (rate_limit.cost - bucket.max_size) / bucket.refill_per_sec * 1000 > max_wait
        end)

      assert {_key, %{rate_limit: rate_limit}} = over_bound,
             "okx authors no endpoint whose accrual exceeds #{max_wait}ms; " <>
               "this test pins the documented refusal for those endpoints"

      # A private key so the probe cannot collide with the shared okx buckets.
      probe = %{okx | id: "over_bound_#{System.unique_integer([:positive])}", credentials: nil}
      started = System.monotonic_time(:millisecond)

      assert {:error, %Bourse.Error{type: :rate_limit_exceeded} = error} =
               Shaping.maybe_rate_limit(Shaping.rate_key(probe), probe, rate_limit)

      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 200, "refusal slept #{elapsed}ms instead of returning immediately"
      assert error.exchange == probe.id
      assert error.message =~ probe.id
      assert error.message =~ "exceeds max #{max_wait}ms"
      assert error.retry_after > max_wait
    end
  end
end
