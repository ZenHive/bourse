defmodule Bourse.RateLimiter do
  @moduledoc """
  Per-credential token-bucket rate limiter for exchange API requests.

  Each `{exchange_id, credential_key, bucket_axis}` key holds tokens that refill
  at the authored `refill_per_sec`, capped at `capacity` (`max_size`). A request
  is admitted when the bucket holds its cost. An over-capacity cost is not
  exempt: the bucket accrues until it can pay, then goes to zero.

  ## Usage

      key = {"okx", api_key, "request"}
      case Bourse.RateLimiter.check_rate(key, %{capacity: 1, refill_per_sec: 9.09}, 1) do
        :ok -> make_request()
        {:delay, ms} -> Process.sleep(ms); make_request()
      end

  `%{requests: max, period: period_ms}` is accepted as capacity `max` refilling
  at `max / (period_ms / 1000)` tokens per second.

  ## Credential Keys

  The key is a tuple `{exchange_id, credential_key, bucket_axis}` where:
  - `exchange_id` is the exchange string ID (`"binance"`, `"bybit"`, etc.)
  - `credential_key` is either:
    - The API key string (for authenticated requests) -- isolates per-user limits
    - `:public` atom (for public requests) -- shared pool for unauthenticated requests
  - `bucket_axis` is the spec/header bucket axis (`"request"`, `"ip"`,
    `"uid"`, `"order_weight"`, etc.)
  """

  use GenServer

  alias Bourse.Defaults

  @typedoc "Token-bucket configuration: authored capacity and refill rate."
  @type rate_limit ::
          %{capacity: number(), refill_per_sec: number()}
          | %{requests: number(), period: pos_integer()}
          | %{requests: number()}

  @typedoc """
  Rate limiter key: `{exchange_id, api_key | :public, bucket_axis}`.
  """
  @type key :: {String.t(), String.t() | :public} | {String.t(), String.t() | :public, String.t()}

  @typedoc "A single bucket capacity check: `{key, rate_limit, cost}`."
  @type bucket_check :: {key(), rate_limit() | nil, number()}

  @typep bucket_state :: %{
           tokens: float(),
           updated_at: integer(),
           capacity: number(),
           refill_per_sec: number()
         }

  @typep normalized_check :: {key(), number(), number(), number()}

  # Default period of 1 second if a legacy `%{requests: n}` omits `period`
  @default_period_ms 1000

  # Default cost if not specified
  @default_cost 1

  # Maximum idle time before a key is evicted entirely (24 hours)
  @key_eviction_age_ms 24 * 60 * 60 * 1000

  # Client API

  @doc """
  Returns a child specification for starting the rate limiter under a supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Starts the rate limiter."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Checks if a request can be made within rate limits.

  Returns `:ok` if the bucket holds `cost` (and records it), or
  `{:delay, milliseconds}` if the caller should wait for tokens to accrue.

  A cost larger than capacity is limited: the caller waits until the bucket
  has accrued that cost. There is no skip-record exemption.
  """
  @spec check_rate(key(), rate_limit() | nil, number(), GenServer.name()) ::
          :ok | {:delay, pos_integer()}
  def check_rate(key, rate_limit, cost \\ @default_cost, name \\ __MODULE__)

  def check_rate(_key, nil, _cost, _name), do: :ok

  def check_rate(key, %{} = rate_limit, cost, name) do
    check_rates([{key, rate_limit, cost}], name)
  end

  @doc """
  Checks multiple bucket capacities atomically.

  Returns `:ok` only when every bucket has capacity, recording every cost in the
  same GenServer transition. Returns `{:delay, milliseconds}` without recording
  any bucket when at least one bucket cannot yet pay.
  """
  @spec check_rates([bucket_check()], GenServer.name()) :: :ok | {:delay, pos_integer()}
  def check_rates(bucket_checks, name \\ __MODULE__) when is_list(bucket_checks) do
    checks =
      bucket_checks
      |> Enum.reject(fn {_key, rate_limit, _cost} -> is_nil(rate_limit) end)
      |> Enum.map(fn {key, rate_limit, cost} -> normalize_check(key, rate_limit, cost) end)

    if checks == [] do
      :ok
    else
      GenServer.call(name, {:check_rates, checks})
    end
  end

  @doc """
  Blocks until rate limit capacity is available, then records the request.

  Returns `{:error, %Bourse.Error{}}` when the wait would exceed
  `Bourse.Defaults.rate_limit_max_wait_ms/0`.
  """
  @spec wait_for_capacity(key(), rate_limit() | nil, number(), GenServer.name()) ::
          :ok | {:error, Bourse.Error.t()}
  def wait_for_capacity(key, rate_limit, cost \\ @default_cost, name \\ __MODULE__)

  def wait_for_capacity(_key, nil, _cost, _name), do: :ok

  def wait_for_capacity(key, rate_limit, cost, name) do
    await_capacity(key, rate_limit, cost, name, System.monotonic_time(:millisecond))
  end

  @doc """
  Records a request for a key with specified cost.

  Called automatically by `check_rate/4` when it returns `:ok`.
  Exposed for manual tracking if needed.
  """
  @spec record_request(key(), number(), GenServer.name()) :: :ok
  def record_request(key, cost \\ @default_cost, name \\ __MODULE__) do
    GenServer.cast(name, {:record_request, normalize_key(key), cost})
  end

  @doc """
  Gets tokens currently borrowed from the bucket (`capacity - tokens` after refill).

  The `period` argument is unused; it remains so callers that passed a window
  length keep compiling. Useful for debugging and monitoring.
  """
  @spec get_cost(key(), pos_integer(), GenServer.name()) :: number()
  def get_cost(key, period, name \\ __MODULE__) do
    GenServer.call(name, {:get_cost, normalize_key(key), period})
  end

  @doc "Resets rate limit tracking for a key."
  @spec reset(key(), GenServer.name()) :: :ok
  def reset(key, name \\ __MODULE__) do
    GenServer.cast(name, {:reset, normalize_key(key)})
  end

  @doc """
  Clears rate-limit tracking for every bucket belonging to one exchange.

  `Bourse.Test.LiveGateIsolation` uses this so a venue probe cannot enter its
  bucket with capacity another probe already spent (Task 179) *without*
  discarding the sibling venues' pacing at the same time — a global wipe lets a
  heavy endpoint (okx `system/status`, authored cost 50 against a 9.09/s drain)
  go out back to back and earn the venue's own 50011.
  """
  @spec reset_exchange(String.t(), GenServer.name()) :: :ok
  def reset_exchange(exchange_id, name \\ __MODULE__) when is_binary(exchange_id) do
    GenServer.call(name, {:reset_exchange, exchange_id})
  end

  @doc """
  Clears all rate-limit tracking state.

  Whole-map reset; prefer `reset_exchange/2` when only one venue's buckets
  should be cleared.
  """
  @spec reset_all(GenServer.name()) :: :ok
  def reset_all(name \\ __MODULE__) do
    GenServer.call(name, :reset_all)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check_rates, checks}, _from, state) do
    now = System.monotonic_time(:millisecond)

    decisions =
      Enum.map(checks, fn {key, capacity, refill_per_sec, cost} ->
        {key, check_bucket(state, key, capacity, refill_per_sec, cost, now)}
      end)

    delay_ms =
      Enum.find_value(decisions, fn
        {_key, {:delay, ms, _bucket}} -> ms
        _ -> nil
      end)

    new_state = persist_buckets(state, decisions, delay_ms)
    reply = if is_nil(delay_ms), do: :ok, else: {:delay, max(delay_ms, 1)}
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call({:get_cost, key, _period}, _from, state) do
    now = System.monotonic_time(:millisecond)

    used =
      case Map.get(state, key) do
        nil ->
          0

        bucket ->
          refilled = refill_bucket(bucket, bucket.capacity, bucket.refill_per_sec, now)
          max(refilled.capacity - refilled.tokens, 0)
      end

    {:reply, used, state}
  end

  @impl true
  def handle_call({:reset_exchange, exchange_id}, _from, state) do
    {:reply, :ok, Map.reject(state, fn {{id, _credential, _axis}, _bucket} -> id == exchange_id end)}
  end

  @impl true
  def handle_call(:reset_all, _from, _state) do
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_cast({:record_request, key, cost}, state) do
    now = System.monotonic_time(:millisecond)

    bucket =
      case Map.get(state, key) do
        nil ->
          %{tokens: 0.0, updated_at: now, capacity: cost, refill_per_sec: 0.0}

        existing ->
          refilled = refill_bucket(existing, existing.capacity, existing.refill_per_sec, now)
          %{refilled | tokens: max(refilled.tokens - cost, 0.0), updated_at: now}
      end

    {:noreply, Map.put(state, key, bucket)}
  end

  @impl true
  def handle_cast({:reset, key}, state) do
    {:noreply, Map.delete(state, key)}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    eviction_cutoff = now - @key_eviction_age_ms

    final_state =
      Map.filter(state, fn {_key, %{updated_at: updated_at}} ->
        updated_at > eviction_cutoff
      end)

    schedule_cleanup()
    {:noreply, final_state}
  end

  defp await_capacity(key, rate_limit, cost, name, started_at) do
    max_wait = Defaults.rate_limit_max_wait_ms()
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = max_wait - elapsed

    case check_rate(key, rate_limit, cost, name) do
      :ok ->
        :ok

      {:delay, delay_ms} when delay_ms > remaining ->
        {:error, wait_exceeded_error(key, delay_ms + max(elapsed, 0), max_wait)}

      {:delay, delay_ms} ->
        Process.sleep(delay_ms)
        await_capacity(key, rate_limit, cost, name, started_at)
    end
  end

  defp wait_exceeded_error(key, wait_ms, max_wait_ms) do
    exchange_id =
      case key do
        {id, _, _} -> id
        {id, _} -> id
      end

    Bourse.Error.rate_limit_exceeded(
      exchange: exchange_id,
      message: "#{exchange_id} rate-limit wait #{wait_ms}ms exceeds max #{max_wait_ms}ms",
      retry_after: wait_ms
    )
  end

  @spec normalize_check(key(), rate_limit(), number()) :: normalized_check()
  defp normalize_check(key, %{capacity: capacity, refill_per_sec: refill_per_sec}, cost) do
    {normalize_key(key), capacity, refill_per_sec, cost}
  end

  defp normalize_check(key, %{requests: max_weight, period: period}, cost) when period > 0 do
    {normalize_key(key), max_weight, max_weight / (period / 1000), cost}
  end

  defp normalize_check(key, %{requests: max_weight}, cost) do
    normalize_check(key, %{requests: max_weight, period: @default_period_ms}, cost)
  end

  @spec normalize_key(key()) :: {String.t(), String.t() | :public, String.t()}
  defp normalize_key({exchange_id, credential_key, axis}) when is_binary(exchange_id) and is_binary(axis) do
    {exchange_id, credential_key, axis}
  end

  defp normalize_key({exchange_id, credential_key}) when is_binary(exchange_id) do
    {exchange_id, credential_key, "request"}
  end

  @spec check_bucket(map(), key(), number(), number(), number(), integer()) ::
          {:ok, bucket_state(), bucket_state()} | {:delay, integer(), bucket_state()}
  defp check_bucket(state, key, capacity, refill_per_sec, cost, now) do
    bucket =
      case Map.get(state, key) do
        nil ->
          %{tokens: capacity * 1.0, updated_at: now, capacity: capacity, refill_per_sec: refill_per_sec}

        existing ->
          existing
      end

    # Over-capacity costs may accrue above max_size until they can pay; burst
    # of ordinary costs stays capped at authored capacity.
    refill_cap = max(capacity, cost)
    refilled = refill_bucket(bucket, refill_cap, refill_per_sec, now)
    accrued = %{refilled | capacity: capacity, refill_per_sec: refill_per_sec, updated_at: now}

    if refilled.tokens >= cost do
      {:ok, %{accrued | tokens: refilled.tokens - cost}, accrued}
    else
      {:delay, delay_ms(cost - refilled.tokens, refill_per_sec), accrued}
    end
  end

  defp persist_buckets(state, decisions, delay_ms) do
    Enum.reduce(decisions, state, fn {key, result}, acc ->
      Map.put(acc, key, persisted_bucket(result, delay_ms))
    end)
  end

  defp persisted_bucket({:ok, paid, _accrued}, nil), do: paid
  defp persisted_bucket({:ok, _paid, accrued}, _delay_ms), do: accrued
  defp persisted_bucket({:delay, _ms, accrued}, _delay_ms), do: accrued

  @spec refill_bucket(bucket_state(), number(), number(), integer()) :: bucket_state()
  defp refill_bucket(bucket, cap, refill_per_sec, now) do
    elapsed_s = max(now - bucket.updated_at, 0) / 1000
    tokens = min(cap * 1.0, bucket.tokens + refill_per_sec * elapsed_s)
    %{bucket | tokens: tokens, updated_at: now, capacity: cap, refill_per_sec: refill_per_sec}
  end

  @spec delay_ms(number(), number()) :: pos_integer()
  defp delay_ms(_need, refill_per_sec) when refill_per_sec <= 0, do: Defaults.rate_limit_max_wait_ms() + 1

  defp delay_ms(need, refill_per_sec) do
    ms = ceil(need / refill_per_sec * 1000)
    max(ms, 1)
  end

  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, Defaults.rate_limit_cleanup_interval_ms())
  end
end
