defmodule Bourse.Test.LiveGateIsolation do
  @moduledoc """
  Clears process-global gate state between live venue probes.

  Provider-live tests route through the real `Bourse.Unified.call/5` pipeline,
  which consults the process-global `:fuse` CircuitBreaker and the RateLimiter
  GenServer. One venue tripping a breaker or accumulating a rate-limit sleep
  otherwise leaks into the next test as a false `circuit_open` red or a stall.
  This module clears both per case, scoped to the named exchange so a sibling
  venue's in-flight pacing survives.
  """
  alias Bourse.CircuitBreaker
  alias Bourse.RateLimiter

  @doc """
  Resets circuit-breaker + rate-limiter global state for a stubbed exchange.

  Safe when the fuse is not yet installed (`:not_found` is ignored). Rate-limiter
  state is cleared for this exchange's public and credentialed buckets so probe
  traffic cannot leave residual cost on shared keys — and only for this
  exchange, because a global wipe discards another venue's accrued pacing and
  lets its next heavy endpoint go out unpaced into the venue's own 429.
  """
  @spec isolate!(String.t()) :: :ok
  def isolate!(exchange_id) when is_binary(exchange_id) do
    case CircuitBreaker.reset(exchange_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    RateLimiter.reset_exchange(exchange_id)
    :ok
  end
end
