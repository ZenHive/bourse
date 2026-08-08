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

  Enabling the breaker is the only way a test can install or melt a fuse, so this
  is also the only place that has to clean one up: on exit every fuse installed
  during the run is removed. Cleaning all of them rather than a caller-named one
  is deliberate — a test that melts a venue it did not think to declare is
  exactly how the original leak went unnoticed.
  """
  @spec enable!(map()) :: :ok
  def enable!(overrides \\ %{}) when is_map(overrides) do
    previous = Application.get_env(:bourse, :circuit_breaker)

    Application.put_env(:bourse, :circuit_breaker, Map.merge(%{enabled: true}, overrides))

    on_exit(fn ->
      remove_installed_fuses()

      case previous do
        nil -> Application.delete_env(:bourse, :circuit_breaker)
        value -> Application.put_env(:bourse, :circuit_breaker, value)
      end
    end)

    :ok
  end

  @doc """
  Enables the breaker and guarantees `exchange_id` starts with no installed fuse,
  so a fuse left behind by an earlier run cannot decide this test's outcome.
  """
  @spec isolate!(String.t(), map()) :: :ok
  def isolate!(exchange_id, overrides \\ %{}) when is_binary(exchange_id) do
    enable!(overrides)

    exchange_id |> CircuitBreaker.fuse_name() |> :fuse.remove()

    :ok
  end

  @doc """
  Removes every fuse the node has installed. Removing an absent fuse is a no-op,
  so this is safe whether or not the breaker was ever enabled.
  """
  @spec remove_installed_fuses() :: :ok
  def remove_installed_fuses do
    Enum.each(CircuitBreaker.all_statuses(), fn {exchange_id, _status} ->
      exchange_id |> CircuitBreaker.fuse_name() |> :fuse.remove()
    end)
  end
end
