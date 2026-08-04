defmodule Bourse.Test.FixtureGateIsolationTest do
  use ExUnit.Case, async: false

  alias Bourse.CircuitBreaker
  alias Bourse.RateLimiter
  alias Bourse.Test.FixtureGateIsolation

  # A real runtime venue: fuse names resolve through Bourse.Registry, so an
  # arbitrary id would exercise only the nil/no-op path.
  @venue "lighter"

  setup do
    on_exit(fn -> FixtureGateIsolation.isolate!(@venue) end)
  end

  test "isolate! is :ok when the fuse was never installed" do
    assert FixtureGateIsolation.isolate!("fixture-gate-isolation-unknown-venue") == :ok
  end

  test "isolate! resets a blown fuse so stub replays see a closed circuit" do
    assert CircuitBreaker.check(@venue) == :ok
    Enum.each(1..10, fn _failure -> CircuitBreaker.record_failure(@venue) end)
    assert CircuitBreaker.status(@venue) == :blown

    assert FixtureGateIsolation.isolate!(@venue) == :ok
    assert CircuitBreaker.check(@venue) == :ok
  end

  test "isolate! clears residual rate-limiter cost on shared keys" do
    key = {@venue, :public}
    RateLimiter.record_request(key, 1_000)
    assert RateLimiter.get_cost(key, 60_000) >= 1_000

    assert FixtureGateIsolation.isolate!(@venue) == :ok
    assert RateLimiter.get_cost(key, 60_000) == 0
  end
end
