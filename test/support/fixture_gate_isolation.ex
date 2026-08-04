defmodule Bourse.Test.FixtureGateIsolation do
  @moduledoc """
  Hermetic isolation for offline stub-based replay tests.

  Offline reality-oracle and authored-integration tests route through the real
  `Bourse.Unified.call/5` pipeline against `Req.Test` stubs. That pipeline consults
  the process-global `:fuse` CircuitBreaker and the RateLimiter GenServer. Live
  network/raw probes co-tagged `:exchange_<id>` can trip those and make a stub
  replay fail with a false `circuit_open` red (or stall under rate-limit sleeps).
  Stub replays never need either subsystem — this module clears them per case.
  """

  alias Bourse.CircuitBreaker
  alias Bourse.RateLimiter

  @doc """
  Resets circuit-breaker + rate-limiter global state for a stubbed exchange.

  Safe when the fuse is not yet installed (`:not_found` is ignored). Rate-limiter
  state is cleared globally so public/private probe traffic cannot leave residual
  cost on shared keys.
  """
  @spec isolate!(String.t()) :: :ok
  def isolate!(exchange_id) when is_binary(exchange_id) do
    case CircuitBreaker.reset(exchange_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    RateLimiter.reset_all()
    :ok
  end
end
