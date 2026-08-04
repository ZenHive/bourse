defmodule Bourse.RateLimiter.Shaping do
  @moduledoc """
  Shapes endpoint rate-limit descriptors into `Bourse.RateLimiter` checks and
  updates rate-limit state from response headers.

  Extracted from `Bourse.HTTP` so transport stays focused on request execution
  while bucket-axis normalization, cost shaping, and header→ETS updates live
  with the RateLimiter family. Behavior-preserving delegation only.
  """

  # reach:disable-for-this-file fixed_shape_map — local rate-limit descriptor; struct adds ceremony, no boundary win

  alias Bourse.Defaults
  alias Bourse.Exchange
  alias Bourse.RateLimiter
  alias Bourse.RateLimiter.Headers, as: RateLimitHeaders

  # Authored rateLimit values are milliseconds between requests; convert to max req/window below.
  # Window defaults to 60s (req/min). Overridable via `:rate_limit_window_ms` for tests.
  @rate_limit_period_ms 60_000
  @default_bucket_axis "request"

  @typedoc "Credential slice of a rate key: API key string or `:public`"
  @type credential_key :: String.t() | :public

  @typedoc "Base rate key without bucket axis"
  @type rate_key :: {String.t(), credential_key()}

  @typedoc "Full rate key including bucket axis"
  @type axis_key :: {String.t(), credential_key(), String.t()}

  @typedoc "One RateLimiter.check_rates/1 triple"
  @type rate_check :: {axis_key(), %{requests: non_neg_integer(), period: pos_integer()}, number()}

  @doc """
  Builds the base rate-limiter key from an exchange: `{exchange_id, api_key | :public}`.
  """
  @spec rate_key(Exchange.t()) :: rate_key()
  def rate_key(%Exchange{id: id, credentials: nil}), do: {id, :public}
  def rate_key(%Exchange{id: id, credentials: creds}), do: {id, creds.api_key || :public}

  @doc """
  Checks rate limit if enabled — blocks until capacity is available, returns `:ok`.

  `rate_limit_ms` is "milliseconds between requests", so
  max requests per period = period / rate_limit_ms.
  """
  @spec maybe_rate_limit(rate_key(), Exchange.t(), term()) :: :ok
  def maybe_rate_limit(rate_key, exchange, endpoint_rate_limit) do
    checks = build_rate_limit_checks(rate_key, exchange, endpoint_rate_limit)

    if Defaults.rate_limiter_enabled?() and checks != [] do
      case RateLimiter.check_rates(checks) do
        :ok ->
          :ok

        {:delay, delay_ms} ->
          emit_rate_limit_throttled(exchange.id, delay_ms, total_check_cost(checks))
          Process.sleep(delay_ms)
          maybe_rate_limit(rate_key, exchange, endpoint_rate_limit)
      end
    else
      :ok
    end
  end

  @doc """
  Parses rate limit headers from a response and updates the ETS state store.

  Returns `:ok` when the exchange doesn't send rate limit headers (OKX, Kraken,
  etc.) — the normal case for most exchanges, not an error.
  """
  @spec maybe_update_state(Exchange.t(), map()) :: :ok
  def maybe_update_state(exchange, resp_headers) do
    case RateLimitHeaders.parse(exchange.id, resp_headers, exchange.rate_limit_ms) do
      {:ok, info} ->
        axis_key = put_rate_axis(rate_key(exchange), info.axis)
        RateLimiter.State.update(axis_key, info)
        :ok

      :none ->
        :ok
    end
  end

  @doc """
  Builds RateLimiter check triples from an endpoint rate-limit descriptor.

  Accepts a numeric weight, a map with `:cost`/`:axes`/`:rate_limit_ms`, a list
  of those maps, or falls back to weight `1` on the default `"request"` axis.
  """
  @spec build_rate_limit_checks(rate_key(), Exchange.t(), term()) :: [rate_check()]
  def build_rate_limit_checks(rate_key, exchange, endpoint_rate_limit) do
    period_ms = rate_limit_period_ms()

    endpoint_rate_limit
    |> normalize_endpoint_rate_limits(exchange.rate_limit_ms)
    |> Enum.flat_map(fn %{axis: axis, cost: cost, rate_limit_ms: rate_limit_ms} ->
      if is_number(rate_limit_ms) and rate_limit_ms > 0 do
        max_requests = trunc(period_ms / rate_limit_ms)
        limit = %{requests: max_requests, period: period_ms}
        [{put_rate_axis(rate_key, axis), limit, cost}]
      else
        []
      end
    end)
  end

  defp rate_limit_period_ms do
    Application.get_env(:bourse, :rate_limit_window_ms, @rate_limit_period_ms)
  end

  defp normalize_endpoint_rate_limits(weight, fallback_rate_limit_ms) when is_number(weight) do
    [%{axis: @default_bucket_axis, cost: weight, rate_limit_ms: fallback_rate_limit_ms}]
  end

  defp normalize_endpoint_rate_limits(rate_limits, fallback_rate_limit_ms) when is_list(rate_limits) do
    Enum.flat_map(rate_limits, &normalize_endpoint_rate_limits(&1, fallback_rate_limit_ms))
  end

  defp normalize_endpoint_rate_limits(%{} = rate_limit, fallback_rate_limit_ms) do
    cost = numeric_or_default(Map.get(rate_limit, :cost) || Map.get(rate_limit, "cost"), 1)
    rate_limit_ms = Map.get(rate_limit, :rate_limit_ms) || Map.get(rate_limit, "rate_limit_ms") || fallback_rate_limit_ms

    rate_limit
    |> Map.get(:axes, Map.get(rate_limit, "axes", [@default_bucket_axis]))
    |> normalize_axes()
    |> Enum.map(&%{axis: &1, cost: cost, rate_limit_ms: rate_limit_ms})
  end

  defp normalize_endpoint_rate_limits(_rate_limit, fallback_rate_limit_ms) do
    normalize_endpoint_rate_limits(1, fallback_rate_limit_ms)
  end

  defp normalize_axes([]), do: [@default_bucket_axis]

  defp normalize_axes(axes) when is_list(axes) do
    axes
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> [@default_bucket_axis]
      valid_axes -> valid_axes
    end
  end

  defp normalize_axes(%{} = axes) when map_size(axes) == 0, do: [@default_bucket_axis]

  defp normalize_axes(%{} = axes) do
    axes
    |> Map.values()
    |> List.flatten()
    |> normalize_axes()
  end

  defp normalize_axes(_axes), do: [@default_bucket_axis]

  defp numeric_or_default(value, _default) when is_number(value), do: value
  defp numeric_or_default(_value, default), do: default

  defp put_rate_axis({exchange_id, credential_key}, axis), do: {exchange_id, credential_key, axis}

  defp total_check_cost(checks) do
    Enum.reduce(checks, 0, fn {_key, _rate_limit, cost}, acc -> acc + cost end)
  end

  defp emit_rate_limit_throttled(exchange_id, delay_ms, cost) do
    :telemetry.execute(
      Bourse.Telemetry.rate_limiter_throttled(),
      %{delay_ms: delay_ms, cost: cost},
      %{exchange: exchange_id}
    )
  end
end
