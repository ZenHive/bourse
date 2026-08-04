defmodule Bourse.RateLimiter do
  @moduledoc """
  Per-credential weighted rate limiter for exchange API requests.

  Tracks request costs per `{exchange_id, credential_key, bucket_axis}` using a
  sliding window. Costs are summed (not counted) to handle weighted endpoints
  correctly.

  ## Usage

      # Authenticated request (per-API-key tracking)
      key = {"binance", api_key, "ip"}
      case Bourse.RateLimiter.check_rate(key, %{requests: 1200, period: 60_000}, 4) do
        :ok -> make_request()
        {:delay, ms} -> Process.sleep(ms); make_request()
      end

      # Or use wait_for_capacity which blocks until ready:
      :ok = Bourse.RateLimiter.wait_for_capacity(key, rate_limit, cost)
      make_request()

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

  @typedoc "Rate limit configuration with max weight and period in milliseconds"
  @type rate_limit :: %{requests: pos_integer(), period: pos_integer()}

  @typedoc """
  Rate limiter key: `{exchange_id, api_key | :public, bucket_axis}`.
  """
  @type key :: {String.t(), String.t() | :public} | {String.t(), String.t() | :public, String.t()}

  @typedoc "A single bucket capacity check: `{key, rate_limit, cost}`."
  @type bucket_check :: {key(), rate_limit() | nil, number()}

  # Default period of 1 second if not specified
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

  Returns `:ok` if within limits (and records the request), or `{:delay, milliseconds}`
  if the caller should wait before making the request.

  ## Parameters

  - `key` -- `{exchange_id, api_key}` or `{exchange_id, :public}` tuple
  - `rate_limit` -- `%{requests: max_weight, period: period_ms}` or nil (no limiting)
  - `cost` -- Request weight/cost (default: 1)
  - `name` -- GenServer name (default: `Bourse.RateLimiter`)
  """
  @spec check_rate(key(), rate_limit() | nil, number(), GenServer.name()) ::
          :ok | {:delay, pos_integer()}
  def check_rate(key, rate_limit, cost \\ @default_cost, name \\ __MODULE__)

  def check_rate(_key, nil, _cost, _name), do: :ok

  def check_rate(key, %{requests: max_weight, period: period}, cost, name) do
    GenServer.call(name, {:check_rate, normalize_key(key), max_weight, period, cost})
  end

  def check_rate(key, %{requests: max_weight}, cost, name) do
    GenServer.call(name, {:check_rate, normalize_key(key), max_weight, @default_period_ms, cost})
  end

  @doc """
  Checks multiple bucket capacities atomically.

  Returns `:ok` only when every bucket has capacity, recording every cost in the
  same GenServer transition. Returns `{:delay, milliseconds}` without recording
  any bucket when at least one bucket is over limit.
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

  ## Parameters

  - `key` -- `{exchange_id, api_key}` or `{exchange_id, :public}` tuple
  - `rate_limit` -- `%{requests: max_weight, period: period_ms}` or nil
  - `cost` -- Request weight/cost (default: 1)
  - `name` -- GenServer name (default: `Bourse.RateLimiter`)
  """
  @spec wait_for_capacity(key(), rate_limit() | nil, number(), GenServer.name()) :: :ok
  def wait_for_capacity(key, rate_limit, cost \\ @default_cost, name \\ __MODULE__)

  def wait_for_capacity(_key, nil, _cost, _name), do: :ok

  def wait_for_capacity(key, rate_limit, cost, name) do
    case check_rate(key, rate_limit, cost, name) do
      :ok ->
        :ok

      {:delay, ms} ->
        Process.sleep(ms)
        wait_for_capacity(key, rate_limit, cost, name)
    end
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
  Gets current total cost for a key within a time window.

  Useful for debugging and monitoring.
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
  Clears all rate-limit tracking state.

  Used by offline fixture gates so co-running live probes cannot poison
  capacity for Req.Test stub traffic (Task 179).
  """
  @spec reset_all(GenServer.name()) :: :ok
  def reset_all(name \\ __MODULE__) do
    GenServer.call(name, :reset_all)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    schedule_cleanup()
    # State: %{key => [{timestamp, cost}, ...]}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check_rate, key, max_weight, period, cost}, from, state) do
    # Single-bucket path shares the multi-bucket check + window-trim recording path.
    # TODO(T59): If a single endpoint weight exceeds converted max_weight, allow it
    # through rather than blocking forever. Proper fix: validate weight <= max_weight
    # at compile time in Exchange generator, or normalize weights in Dispatch.
    # With correct conversion (max_weight = period / rate_limit_ms), this should
    # not trigger — endpoint weights are much smaller than per-minute limits.
    handle_call({:check_rates, [{key, max_weight, period, cost}]}, from, state)
  end

  @impl true
  def handle_call({:check_rates, checks}, _from, state) do
    now = System.monotonic_time(:millisecond)

    decisions =
      Enum.map(checks, fn {key, max_weight, period, cost} ->
        {key, max_weight, period, cost, check_bucket(state, key, max_weight, period, cost, now)}
      end)

    case Enum.find(decisions, fn {_key, _max, _period, _cost, decision} -> match?({:delay, _}, decision) end) do
      nil ->
        new_state =
          Enum.reduce(decisions, state, fn
            {key, _max, period, cost, :ok}, acc ->
              record_in_state(acc, key, cost, now, period)

            {_key, _max, _period, _cost, :skip_record}, acc ->
              acc
          end)

        {:reply, :ok, new_state}

      {_key, _max, _period, _cost, {:delay, delay}} ->
        {:reply, {:delay, max(delay, 1)}, state}
    end
  end

  @impl true
  def handle_call({:get_cost, key, period}, _from, state) do
    now = System.monotonic_time(:millisecond)
    window_start = now - period

    total_cost =
      state
      |> Map.get(key, [])
      |> Enum.filter(fn {ts, _cost} -> ts > window_start end)
      |> Enum.reduce(0, fn {_ts, cost}, acc -> acc + cost end)

    {:reply, total_cost, state}
  end

  @impl true
  def handle_call(:reset_all, _from, _state) do
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_cast({:record_request, key, cost}, state) do
    now = System.monotonic_time(:millisecond)
    # Manual record has no per-bucket period; trim to max-age (same horizon as cleanup).
    {:noreply, record_in_state(state, key, cost, now, Defaults.rate_limit_max_age_ms())}
  end

  @impl true
  def handle_cast({:reset, key}, state) do
    new_state = Map.delete(state, key)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    request_cutoff = now - Defaults.rate_limit_max_age_ms()
    eviction_cutoff = now - @key_eviction_age_ms

    # Remove expired timestamps from all keys
    cleaned_state =
      Map.new(state, fn {key, requests} ->
        recent = Enum.filter(requests, fn {ts, _cost} -> ts > request_cutoff end)
        {key, recent}
      end)

    # Remove empty keys and keys idle beyond eviction threshold
    final_state =
      Map.filter(cleaned_state, fn {_key, requests} ->
        case requests do
          [] ->
            false

          [{newest_ts, _} | _] ->
            newest_ts > eviction_cutoff
        end
      end)

    schedule_cleanup()
    {:noreply, final_state}
  end

  @spec normalize_check(key(), rate_limit(), number()) :: {key(), pos_integer(), pos_integer(), number()}
  defp normalize_check(key, %{requests: max_weight, period: period}, cost) do
    {normalize_key(key), max_weight, period, cost}
  end

  defp normalize_check(key, %{requests: max_weight}, cost) do
    {normalize_key(key), max_weight, @default_period_ms, cost}
  end

  @spec normalize_key(key()) :: {String.t(), String.t() | :public, String.t()}
  defp normalize_key({exchange_id, credential_key, axis}) when is_binary(exchange_id) and is_binary(axis) do
    {exchange_id, credential_key, axis}
  end

  defp normalize_key({exchange_id, credential_key}) when is_binary(exchange_id) do
    {exchange_id, credential_key, "request"}
  end

  @spec check_bucket(map(), key(), number(), integer(), number(), integer()) ::
          :ok | :skip_record | {:delay, integer()}
  defp check_bucket(state, key, max_weight, period, cost, now) do
    if cost > max_weight do
      :skip_record
    else
      window_start = now - period
      recent_requests = recent_requests(state, key, window_start)
      current_weight = total_cost(recent_requests)

      if current_weight + cost <= max_weight do
        :ok
      else
        {:delay, calculate_delay(recent_requests, current_weight, max_weight, cost, period, now)}
      end
    end
  end

  @spec recent_requests(map(), key(), integer()) :: [{integer(), number()}]
  defp recent_requests(state, key, window_start) do
    state
    |> Map.get(key, [])
    |> Enum.filter(fn {ts, _cost} -> ts > window_start end)
  end

  @spec total_cost([{integer(), number()}]) :: number()
  defp total_cost(requests) do
    Enum.reduce(requests, 0, fn {_ts, cost}, acc -> acc + cost end)
  end

  # Prepend cost and drop entries outside the rate window so busy keys stay
  # O(window) between cleanup ticks (mirrors legacy check_rate/4 self-trim).
  @spec record_in_state(map(), key(), number(), integer(), pos_integer()) :: map()
  defp record_in_state(state, key, cost, now, period) do
    window_start = now - period
    recent = recent_requests(state, key, window_start)
    Map.put(state, key, [{now, cost} | recent])
  end

  # Calculate delay needed until enough capacity for the requested cost.
  # Finds how long we need to wait for old requests to expire to free up space.
  @spec calculate_delay([{integer(), number()}], number(), number(), number(), integer(), integer()) ::
          integer()
  defp calculate_delay(requests, current_weight, max_weight, cost, period, now) do
    # Sort by timestamp (oldest first)
    sorted = Enum.sort_by(requests, fn {ts, _cost} -> ts end)

    # Find how much weight needs to expire
    weight_to_free = current_weight + cost - max_weight

    # Accumulate oldest requests until we've freed enough weight
    {freed_weight, last_ts} =
      Enum.reduce_while(sorted, {0, now}, fn {ts, c}, {acc_weight, _last_ts} ->
        new_weight = acc_weight + c

        if new_weight >= weight_to_free do
          {:halt, {new_weight, ts}}
        else
          {:cont, {new_weight, ts}}
        end
      end)

    if freed_weight >= weight_to_free do
      # Add 1ms to ensure we're past the window boundary when we retry
      last_ts + period - now + 1
    else
      # Edge case: fall back to a full period wait as a safe default
      period
    end
  end

  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, Defaults.rate_limit_cleanup_interval_ms())
  end
end
