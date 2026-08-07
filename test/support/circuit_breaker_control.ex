defmodule Bourse.Test.CircuitBreakerControl do
  @moduledoc """
  Turns the circuit breaker back on for the tests that exist to exercise it.

  `config/config.exs` disables the breaker for the whole `:test` environment
  because `:fuse` keeps its state process-globally per exchange id, which
  otherwise lets one module's failure-path coverage blow a fuse that an unrelated
  module then trips over. A test that asserts breaker behaviour needs the real
  thing, so it opts back in for its own duration.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Bourse.CircuitBreaker

  @doc """
  Enables the circuit breaker for the calling test and restores the environment
  afterwards.

  `overrides` are merged over the production defaults, so a test can shorten the
  window or lower the melt count without restating the rest.
  """
  @spec enable!(map()) :: :ok
  def enable!(overrides \\ %{}) when is_map(overrides) do
    previous = Application.get_env(:bourse, :circuit_breaker)

    Application.put_env(:bourse, :circuit_breaker, Map.merge(%{enabled: true}, overrides))

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bourse, :circuit_breaker)
        value -> Application.put_env(:bourse, :circuit_breaker, value)
      end
    end)

    :ok
  end

  @doc """
  Enables the breaker and guarantees `exchange_id` starts and ends with no
  installed fuse, so neither a previous test nor this one leaks fuse state.
  """
  @spec isolate!(String.t(), map()) :: :ok
  def isolate!(exchange_id, overrides \\ %{}) when is_binary(exchange_id) do
    enable!(overrides)

    fuse_name = CircuitBreaker.fuse_name(exchange_id)
    :fuse.remove(fuse_name)
    on_exit(fn -> :fuse.remove(fuse_name) end)

    :ok
  end
end
