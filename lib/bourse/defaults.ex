defmodule Bourse.Defaults do
  @moduledoc """
  Centralized default configuration values for bourse.

  All defaults can be overridden via application config:

      config :bourse,
        recv_window_ms: 10_000,
        request_timeout_ms: 60_000

  ## Available Defaults

  | Config Key | Default | Description |
  |------------|---------|-------------|
  | `:recv_window_ms` | 5000 | Request timestamp validity window (exchanges reject stale requests) |
  | `:request_timeout_ms` | 30000 | HTTP request timeout |
  | `:retry_policy` | `:safe_transient` | HTTP retry strategy (GET/HEAD only) |
  | `:retry_delay` | `nil` | Backoff between retries; `nil` keeps Req's exponential default |
  | `:rate_limiter_enabled` | `true` | Enable/disable rate limiter |
  | `:rate_limit_cleanup_interval_ms` | 60000 | Interval for cleaning up old rate limit timestamps |
  | `:rate_limit_max_age_ms` | 60000 | Maximum age for rate limit request timestamps |

  """

  @default_recv_window_ms 5_000
  @default_request_timeout_ms 30_000
  @default_retry_policy :safe_transient
  @default_retry_delay nil
  @default_rate_limiter_enabled true
  @default_rate_limit_cleanup_interval_ms 60_000
  @default_rate_limit_max_age_ms 60_000

  @doc """
  Returns the recv_window value in milliseconds.

  The recv_window defines how long a signed request is valid.
  Exchanges reject requests with timestamps outside this window.

  Default: #{@default_recv_window_ms}ms
  """
  @spec recv_window_ms() :: pos_integer()
  def recv_window_ms do
    Application.get_env(:bourse, :recv_window_ms, @default_recv_window_ms)
  end

  @doc """
  Returns the HTTP request timeout in milliseconds.

  Maximum time to wait for a response from an exchange API.

  Default: #{@default_request_timeout_ms}ms
  """
  @spec request_timeout_ms() :: pos_integer()
  def request_timeout_ms do
    Application.get_env(:bourse, :request_timeout_ms, @default_request_timeout_ms)
  end

  @doc """
  Returns the HTTP retry policy.

  ## Trading Safety (CRITICAL)

  Uses `:safe_transient` by default — only retries GET/HEAD requests.
  **Never use `:transient` for trading APIs** as it could duplicate orders.

  Default: `:safe_transient`
  """
  @spec retry_policy() :: :safe_transient | :transient | false
  def retry_policy do
    Application.get_env(:bourse, :retry_policy, @default_retry_policy)
  end

  @doc """
  Returns the backoff between HTTP retries.

  `nil` — the default — leaves the decision to Req, which honors a `retry-after`
  header on 429/503 and otherwise backs off exponentially. An integer overrides
  both with a fixed millisecond delay.

  The test suite sets `0` so stub-driven retry paths exercise the same code
  without paying production backoff; real backoff behavior is asserted by
  passing `:retry_delay` per call.

  Default: `nil`
  """
  @spec retry_delay() :: non_neg_integer() | nil
  def retry_delay do
    Application.get_env(:bourse, :retry_delay, @default_retry_delay)
  end

  @doc """
  Returns whether the rate limiter is enabled.

  Default: `true`
  """
  @spec rate_limiter_enabled?() :: boolean()
  def rate_limiter_enabled? do
    Application.get_env(:bourse, :rate_limiter_enabled, @default_rate_limiter_enabled)
  end

  @doc """
  Returns the interval for cleaning up expired rate limit timestamps.

  Default: #{@default_rate_limit_cleanup_interval_ms}ms
  """
  @spec rate_limit_cleanup_interval_ms() :: pos_integer()
  def rate_limit_cleanup_interval_ms do
    Application.get_env(
      :bourse,
      :rate_limit_cleanup_interval_ms,
      @default_rate_limit_cleanup_interval_ms
    )
  end

  @doc """
  Returns the maximum age for rate limit request timestamps before removal.

  Default: #{@default_rate_limit_max_age_ms}ms
  """
  @spec rate_limit_max_age_ms() :: pos_integer()
  def rate_limit_max_age_ms do
    Application.get_env(:bourse, :rate_limit_max_age_ms, @default_rate_limit_max_age_ms)
  end

  @doc false
  @spec raw_defaults() :: %{
          recv_window_ms: pos_integer(),
          request_timeout_ms: pos_integer(),
          retry_policy: atom(),
          retry_delay: non_neg_integer() | nil,
          rate_limiter_enabled: boolean(),
          rate_limit_cleanup_interval_ms: pos_integer(),
          rate_limit_max_age_ms: pos_integer()
        }
  def raw_defaults do
    %{
      recv_window_ms: @default_recv_window_ms,
      request_timeout_ms: @default_request_timeout_ms,
      retry_policy: @default_retry_policy,
      retry_delay: @default_retry_delay,
      rate_limiter_enabled: @default_rate_limiter_enabled,
      rate_limit_cleanup_interval_ms: @default_rate_limit_cleanup_interval_ms,
      rate_limit_max_age_ms: @default_rate_limit_max_age_ms
    }
  end
end
