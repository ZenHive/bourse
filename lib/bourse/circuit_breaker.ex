defmodule Bourse.CircuitBreaker do
  @moduledoc """
  Per-exchange circuit breakers using the `:fuse` Erlang library.

  Prevents cascade failures when exchanges are down. Each exchange has isolated
  state — binance down does not affect bybit.

  ## How It Works

  1. Each registered exchange uses its generated module atom as the fuse name
  2. Fuses are installed lazily on first request
  3. After N failures within M milliseconds, the circuit opens
  4. Opened circuits reject requests immediately (fast fail)
  5. After reset timeout, circuit closes and allows requests again

  ## What Triggers the Circuit

  Melt decisions flow from the Phase 13 retry classification carried on a
  normalized `Bourse.Error` (the `:network` and `:server_busy` buckets), with a
  raw HTTP 5xx / transport fallback so transport-level failures still trip.

  | Response | Melts? | Reason |
  |----------|--------|--------|
  | HTTP 500+ | Yes | Server error |
  | Timeouts (transport or body `:network`) | Yes | Server unresponsive |
  | Connection refused | Yes | Server unavailable |
  | Body-level `exchange_not_available` (`:server_busy`) | Yes | Exchange down/maintenance |
  | HTTP 429 / `:rate_limit` | **No** | Handled by rate limiter |
  | HTTP 4xx / `:auth` / `:non_retryable` | **No** | Client error, not server issue |

  ## Configuration

      config :bourse, :circuit_breaker,
        enabled: true,
        max_failures: 5,
        window_ms: 10_000,
        reset_ms: 15_000

  """

  require Logger

  @fuse_mode :sync
  @installed_fuses_key {__MODULE__, :installed_fuses}

  @default_enabled true
  @default_max_failures 5
  @default_window_ms 10_000
  @default_reset_ms 15_000

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Returns the status of a circuit breaker for an exchange.

  - `:ok` — circuit closed, requests allowed
  - `:blown` — circuit open, requests rejected
  - `:not_installed` — no fuse yet (no requests made)
  """
  @spec status(String.t()) :: :ok | :blown | :not_installed
  def status(exchange_id) do
    case fuse_name(exchange_id) do
      nil ->
        :not_installed

      fuse_name ->
        case :fuse.ask(fuse_name, @fuse_mode) do
          :ok -> :ok
          :blown -> :blown
          {:error, :not_found} -> :not_installed
        end
    end
  end

  @doc """
  Resets a circuit breaker for an exchange.
  """
  @spec reset(String.t()) :: :ok | {:error, :not_found}
  def reset(exchange_id) do
    case fuse_name(exchange_id) do
      nil ->
        {:error, :not_found}

      fuse_name ->
        case :fuse.reset(fuse_name) do
          :ok ->
            emit_closed(exchange_id)
            :ok

          {:error, :not_found} ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Resets a circuit breaker, raising on error.
  """
  @spec reset!(String.t()) :: :ok
  def reset!(exchange_id) do
    case reset(exchange_id) do
      :ok -> :ok
      {:error, :not_found} -> raise ArgumentError, "No circuit breaker found for #{exchange_id}"
    end
  end

  @doc """
  Returns status of all installed circuit breakers.
  """
  @spec all_statuses() :: %{String.t() => :ok | :blown}
  def all_statuses do
    Enum.reduce(installed_fuses(), %{}, fn exchange_id, acc ->
      case status(exchange_id) do
        :not_installed -> acc
        s -> Map.put(acc, exchange_id, s)
      end
    end)
  end

  @doc """
  Checks if requests are allowed for an exchange.

  Installs the fuse lazily if not already installed.
  """
  @spec check(String.t()) :: :ok | :blown
  def check(exchange_id) do
    config = config()

    if enabled?(config) do
      case fuse_name(exchange_id) do
        nil ->
          :ok

        fuse_name ->
          ask_installed_fuse(exchange_id, fuse_name, config)
      end
    else
      :ok
    end
  end

  defp ask_installed_fuse(exchange_id, fuse_name, config) do
    ensure_installed(exchange_id, fuse_name, config)

    case :fuse.ask(fuse_name, @fuse_mode) do
      :ok ->
        :ok

      :blown ->
        emit_rejected(exchange_id)
        :blown

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Records a successful request. Success prevents further melts.
  """
  @spec record_success(String.t()) :: :ok
  def record_success(_exchange_id), do: :ok

  @doc """
  Records a failed request. Enough melts within the window opens the circuit.
  """
  @spec record_failure(String.t()) :: :ok
  def record_failure(exchange_id) do
    config = config()

    if enabled?(config) do
      case fuse_name(exchange_id) do
        nil ->
          :ok

        fuse_name ->
          melt_installed_fuse(exchange_id, fuse_name, config)
      end
    end

    :ok
  end

  defp melt_installed_fuse(exchange_id, fuse_name, config) do
    ensure_installed(exchange_id, fuse_name, config)
    previous_status = :fuse.ask(fuse_name, @fuse_mode)
    :fuse.melt(fuse_name)
    current_status = :fuse.ask(fuse_name, @fuse_mode)

    if previous_status == :ok and current_status == :blown do
      emit_open(exchange_id)
    end
  end

  @doc """
  Records the result of a request using `should_melt?/1` logic.

  Accepts either the raw result from Req (`{:ok, %Req.Response{}}` or
  `{:error, reason}`) or the normalized `Bourse.Error` outcome returned by
  `Bourse.HTTP`.
  """
  @spec record_result(String.t(), term()) :: :ok
  def record_result(exchange_id, result) do
    if should_melt?(result) do
      record_failure(exchange_id)
    else
      record_success(exchange_id)
    end
  end

  @doc """
  Determines if a response should trip the circuit breaker.

  Accepts both raw Req results and normalized `{:error, %Bourse.Error{}}`
  outcomes. For a normalized error the decision flows from the Phase 13 retry
  classification: `:network` and `:server_busy` melt, everything else
  (`:rate_limit`, `:auth`, `:non_retryable`, unclassified) does not — with a
  raw HTTP 5xx fallback so server errors melt regardless of body classification.

  Melts on: HTTP 500+, transport errors, `:network`/`:server_busy` errors.
  Does NOT melt on: HTTP 429, HTTP 4xx, `:auth`/`:non_retryable` errors, successes.
  """
  @spec should_melt?(term()) :: boolean()
  # Use map pattern matching to avoid compile-time struct expansion issues
  def should_melt?({:ok, %{__struct__: Req.Response, status: status}}) when status >= 500, do: true
  def should_melt?({:ok, %{__struct__: Req.Response}}), do: false
  def should_melt?({:error, %{__struct__: Req.TransportError}}), do: true

  def should_melt?({:error, %{__struct__: Bourse.Error, http_status: status}}) when is_integer(status) and status >= 500,
    do: true

  def should_melt?({:error, %{__struct__: Bourse.Error, retry_class: class}}) when class in [:network, :server_busy],
    do: true

  def should_melt?({:error, %{__struct__: Bourse.Error}}), do: false
  def should_melt?({:error, _reason}), do: true
  def should_melt?(_), do: false

  # ===========================================================================
  # Configuration
  # ===========================================================================

  @doc "Returns circuit breaker configuration."
  @spec config() :: %{
          enabled: boolean(),
          max_failures: pos_integer(),
          window_ms: pos_integer(),
          reset_ms: pos_integer()
        }
  def config do
    app_config = Application.get_env(:bourse, :circuit_breaker, %{})

    get = fn key, default ->
      cond do
        is_map(app_config) -> Map.get(app_config, key, default)
        is_list(app_config) -> Keyword.get(app_config, key, default)
        true -> default
      end
    end

    %{
      enabled: get.(:enabled, @default_enabled),
      max_failures: get.(:max_failures, @default_max_failures),
      window_ms: get.(:window_ms, @default_window_ms),
      reset_ms: get.(:reset_ms, @default_reset_ms)
    }
  end

  # ===========================================================================
  # Internal Helpers
  # ===========================================================================

  @doc false
  @spec fuse_name(String.t()) :: module() | nil
  def fuse_name(exchange_id), do: Bourse.Registry.module_for(exchange_id)

  defp enabled?(config) do
    config.enabled and config.max_failures > 0
  end

  defp ensure_installed(exchange_id, fuse_name, config) do
    case :fuse.ask(fuse_name, @fuse_mode) do
      {:error, :not_found} -> install_fuse(exchange_id, fuse_name, config)
      _ -> :ok
    end
  end

  defp install_fuse(exchange_id, fuse_name, config) do
    # Fuse library "permits N failures" then blows on N+1.
    # Subtract 1 so max_failures: 5 means "blow after 5 failures".
    permitted_failures = max(config.max_failures - 1, 0)
    fuse_opts = {{:standard, permitted_failures, config.window_ms}, {:reset, config.reset_ms}}

    case :fuse.install(fuse_name, fuse_opts) do
      :ok ->
        track_installed(exchange_id)
        :ok

      :reset ->
        track_installed(exchange_id)
        :ok

      {:error, reason} ->
        Logger.warning("[Bourse.CircuitBreaker] Failed to install fuse for #{exchange_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Tracks exchange in persistent_term for all_statuses/0 enumeration.
  defp track_installed(exchange_id) do
    current = installed_fuses()

    if exchange_id not in current do
      :persistent_term.put(@installed_fuses_key, [exchange_id | current])
    end
  end

  defp installed_fuses do
    @installed_fuses_key
    |> :persistent_term.get([])
    |> Enum.uniq()
  end

  # ===========================================================================
  # Telemetry
  # ===========================================================================

  defp emit_open(exchange_id) do
    :telemetry.execute(
      Bourse.Telemetry.circuit_breaker_open(),
      %{system_time: System.system_time()},
      %{exchange: exchange_id}
    )

    Logger.warning("[Bourse.CircuitBreaker] Circuit OPEN for #{exchange_id} - requests will be rejected")
  end

  defp emit_closed(exchange_id) do
    :telemetry.execute(
      Bourse.Telemetry.circuit_breaker_closed(),
      %{system_time: System.system_time()},
      %{exchange: exchange_id}
    )

    Logger.info("[Bourse.CircuitBreaker] Circuit CLOSED for #{exchange_id} - requests allowed")
  end

  defp emit_rejected(exchange_id) do
    :telemetry.execute(
      Bourse.Telemetry.circuit_breaker_rejected(),
      %{system_time: System.system_time()},
      %{exchange: exchange_id}
    )
  end
end
