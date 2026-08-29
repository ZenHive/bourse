defmodule Bourse.RateLimiter.Shaping do
  @moduledoc """
  Shapes endpoint rate-limit descriptors into `Bourse.RateLimiter` checks and
  updates rate-limit state from response headers.

  Authored buckets execute as token buckets: `max_size` is capacity and
  `refill_per_sec` is the drain rate. A request is admitted when the bucket
  holds its cost. There is no fixed 60s window and no skip-record exemption.

  ## Endpoints whose authored cost outruns the wait bound

  Because no cost is exempt, an endpoint accrues `cost / refill_per_sec`
  seconds before it is admitted. Where that accrual exceeds
  `Bourse.Defaults.rate_limit_max_wait_ms/0` the call returns
  `{:error, %Bourse.Error{type: :rate_limit_exceeded}}` naming the venue and
  the wait, instead of the pre-Task-689 skip-record pass-through that let the
  request go out unlimited and collect the venue's own 429.

  Measured against the authored documents at the 10s default: 50 of 3,530
  runtime endpoints sit above the bound — 13 each on binance, binancecoinm and
  binanceusdm (heaviest `POST papi/margin/repay-debt`, cost 3000 at 20/s =
  150s) and 11 on okx (heaviest `POST asset/monthly-statement`, cost 1_296_000
  at 9.09/s ≈ 39.6h — okx publishes it as one request per month). These are
  administrative endpoints the venue itself paces in hours or days; calling one
  requires raising `config :bourse, :rate_limit_max_wait_ms` to the accrual the
  venue actually demands. The refusal is immediate and names the wait; it is
  never a silent sleep.
  """

  alias Bourse.Defaults
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.RateLimiter
  alias Bourse.RateLimiter.Headers, as: RateLimitHeaders

  @default_bucket_axis "request"

  @typedoc "Credential slice of a rate key: API key string or `:public`"
  @type credential_key :: String.t() | :public

  @typedoc "Base rate key without bucket axis"
  @type rate_key :: {String.t(), credential_key()}

  @typedoc "Full rate key including bucket axis"
  @type axis_key :: {String.t(), credential_key(), String.t()}

  @typedoc "Token-bucket limit passed to RateLimiter.check_rates/1"
  @type bucket_limit :: %{capacity: number(), refill_per_sec: number()}

  @typedoc "One RateLimiter.check_rates/1 triple"
  @type rate_check :: {axis_key(), bucket_limit(), number()}

  @doc """
  Builds the base rate-limiter key from an exchange: `{exchange_id, api_key | :public}`.
  """
  @spec rate_key(Exchange.t()) :: rate_key()
  def rate_key(%Exchange{id: id, credentials: nil}), do: {id, :public}
  def rate_key(%Exchange{id: id, credentials: creds}), do: {id, creds.api_key || :public}

  @doc """
  Checks rate limit if enabled — blocks until capacity is available.

  Returns `{:error, %Bourse.Error{}}` when the pre-request wait would exceed
  `Bourse.Defaults.rate_limit_max_wait_ms/0`, naming the venue and the wait.
  """
  @spec maybe_rate_limit(rate_key(), Exchange.t(), term()) :: :ok | {:error, Error.t()}
  def maybe_rate_limit(rate_key, exchange, endpoint_rate_limit) do
    await_capacity(rate_key, exchange, endpoint_rate_limit, System.monotonic_time(:millisecond))
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

  Accepts a numeric weight, a map with `:cost`/`:axes`/`:max_size`/
  `:refill_per_sec`, a list of those maps, or falls back to weight `1` on the
  default `"request"` axis. Venue-level `config["rate_limit_bucket"]` fills
  `max_size` / `refill_per_sec` gaps; `rate_limit_ms` is only a refill
  fallback (`1000 / rate_limit_ms` per second, capacity 1).
  """
  @spec build_rate_limit_checks(rate_key(), Exchange.t(), term()) :: [rate_check()]
  def build_rate_limit_checks(rate_key, exchange, endpoint_rate_limit) do
    fallback = venue_bucket(exchange)

    endpoint_rate_limit
    |> normalize_endpoint_rate_limits(fallback)
    |> Enum.flat_map(fn descriptor ->
      case bucket_limit(descriptor) do
        nil ->
          []

        limit ->
          [{put_rate_axis(rate_key, descriptor.axis), limit, descriptor.cost}]
      end
    end)
  end

  defp await_capacity(rate_key, exchange, endpoint_rate_limit, started_at) do
    checks = build_rate_limit_checks(rate_key, exchange, endpoint_rate_limit)

    if Defaults.rate_limiter_enabled?() and checks != [] do
      max_wait = Defaults.rate_limit_max_wait_ms()
      elapsed = System.monotonic_time(:millisecond) - started_at
      remaining = max_wait - elapsed

      case RateLimiter.check_rates(checks) do
        :ok ->
          :ok

        {:delay, delay_ms} when delay_ms > remaining ->
          {:error, wait_exceeded_error(exchange.id, delay_ms + max(elapsed, 0), max_wait)}

        {:delay, delay_ms} ->
          emit_rate_limit_throttled(exchange.id, delay_ms, total_check_cost(checks))
          Process.sleep(delay_ms)
          await_capacity(rate_key, exchange, endpoint_rate_limit, started_at)
      end
    else
      :ok
    end
  end

  defp wait_exceeded_error(exchange_id, wait_ms, max_wait_ms) do
    Error.rate_limit_exceeded(
      exchange: exchange_id,
      message: "#{exchange_id} rate-limit wait #{wait_ms}ms exceeds max #{max_wait_ms}ms",
      retry_after: wait_ms
    )
  end

  defp venue_bucket(%Exchange{} = exchange) do
    bucket = Map.get(exchange.config, "rate_limit_bucket") || %{}

    %{
      max_size: Map.get(bucket, :max_size) || Map.get(bucket, "max_size"),
      refill_per_sec: Map.get(bucket, :refill_per_sec) || Map.get(bucket, "refill_per_sec"),
      rate_limit_ms: Map.get(bucket, :rate_limit_ms) || Map.get(bucket, "rate_limit_ms") || exchange.rate_limit_ms
    }
  end

  defp normalize_endpoint_rate_limits(weight, fallback) when is_number(weight) do
    [
      Map.merge(fallback, %{
        axis: @default_bucket_axis,
        cost: weight
      })
    ]
  end

  defp normalize_endpoint_rate_limits(rate_limits, fallback) when is_list(rate_limits) do
    Enum.flat_map(rate_limits, &normalize_endpoint_rate_limits(&1, fallback))
  end

  defp normalize_endpoint_rate_limits(%{} = rate_limit, fallback) do
    cost = numeric_or_default(Map.get(rate_limit, :cost) || Map.get(rate_limit, "cost"), 1)

    max_size =
      Map.get(rate_limit, :max_size) || Map.get(rate_limit, "max_size") || fallback.max_size

    refill_per_sec =
      Map.get(rate_limit, :refill_per_sec) || Map.get(rate_limit, "refill_per_sec") ||
        fallback.refill_per_sec

    rate_limit_ms =
      Map.get(rate_limit, :rate_limit_ms) || Map.get(rate_limit, "rate_limit_ms") ||
        fallback.rate_limit_ms

    rate_limit
    |> Map.get(:axes, Map.get(rate_limit, "axes", [@default_bucket_axis]))
    |> normalize_axes()
    |> Enum.map(fn axis ->
      %{
        axis: axis,
        cost: cost,
        max_size: max_size,
        refill_per_sec: refill_per_sec,
        rate_limit_ms: rate_limit_ms
      }
    end)
  end

  defp normalize_endpoint_rate_limits(_rate_limit, fallback) do
    normalize_endpoint_rate_limits(1, fallback)
  end

  defp bucket_limit(%{max_size: max_size, refill_per_sec: refill_per_sec})
       when is_number(max_size) and max_size > 0 and is_number(refill_per_sec) and refill_per_sec > 0 do
    %{capacity: max_size, refill_per_sec: refill_per_sec}
  end

  defp bucket_limit(%{rate_limit_ms: rate_limit_ms, max_size: max_size})
       when is_number(rate_limit_ms) and rate_limit_ms > 0 do
    capacity = if is_number(max_size) and max_size > 0, do: max_size, else: 1
    %{capacity: capacity, refill_per_sec: 1000 / rate_limit_ms}
  end

  defp bucket_limit(%{rate_limit_ms: rate_limit_ms}) when is_number(rate_limit_ms) and rate_limit_ms > 0 do
    %{capacity: 1, refill_per_sec: 1000 / rate_limit_ms}
  end

  defp bucket_limit(_descriptor), do: nil

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
