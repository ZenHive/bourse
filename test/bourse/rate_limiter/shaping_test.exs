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
    test "numeric weight uses default request axis", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{id, :public, "request"}, %{requests: 600, period: 60_000}, 3}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, 3)

      assert id == exchange.id
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

      assert Enum.all?(checks, fn {_key, %{requests: r, period: p}, cost} ->
               r == 1200 and p == 60_000 and cost == 5
             end)

      axes = Enum.map(checks, fn {{_id, :public, axis}, _, _} -> axis end)
      assert axes == ["ip", "order_weight"]
    end

    test "string-key maps are accepted", %{exchange: exchange} do
      rate_key = Shaping.rate_key(exchange)

      assert [{{_, :public, "uid"}, %{requests: 600, period: 60_000}, 2}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, %{
                 "axes" => ["uid"],
                 "cost" => 2,
                 "rate_limit_ms" => 100
               })
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

      assert [{{_, :public, "request"}, %{requests: 600, period: 60_000}, 1}] =
               Shaping.build_rate_limit_checks(rate_key, exchange, :not_a_descriptor)
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
      rate_key = Shaping.rate_key(exchange)
      assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)
      assert RateLimiter.get_cost({exchange.id, :public, "request"}, 60_000) == 1
    end

    test "throttles then retries when the bucket is exhausted", %{exchange: exchange} do
      # Shrink the sliding window so the delay path is exerciseable in tests.
      previous_window = Application.get_env(:bourse, :rate_limit_window_ms)
      Application.put_env(:bourse, :rate_limit_window_ms, 40)

      on_exit(fn ->
        if is_nil(previous_window) do
          Application.delete_env(:bourse, :rate_limit_window_ms)
        else
          Application.put_env(:bourse, :rate_limit_window_ms, previous_window)
        end
      end)

      # rate_limit_ms == window → max 1 request per window
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
      # Second call hits {:delay, _}, emits telemetry, sleeps ~window, then retries to :ok
      assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)

      assert_received {:throttled, %{delay_ms: delay_ms, cost: cost}, %{exchange: id}}
      assert delay_ms > 0
      assert cost >= 1
      assert id == exchange.id
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
end
