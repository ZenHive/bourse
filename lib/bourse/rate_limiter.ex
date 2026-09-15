defmodule Bourse.RateLimiter do
  @moduledoc """
  Per-credential token-bucket rate limiter for exchange API requests.

  Each `{exchange_id, credential_key, bucket_axis}` key holds tokens that refill
  at the authored `refill_per_sec`, capped at `capacity` (`max_size`). A request
  is admitted when the bucket holds its cost. An over-capacity cost is not
  exempt: the bucket accrues until it can pay, then goes to zero.

  A waiter that will actually sleep (an explicit or default wait budget that
  covers the delay) reserves the unpaid cost so interleaved cheaper traffic
  cannot clamp accrual or spend the reserved tokens. Cheap burst stays capped
  at authored `capacity`. Repeated checks of one key in a single `check_rates/2`
  call are charged once at their combined cost; conflicting bucket definitions
  for the same key fail before any spend.

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
  alias Bourse.Error

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
           refill_per_sec: number(),
           reserved: float(),
           reserved_until: integer()
         }

  @typep normalized_check :: {key(), number(), number(), number()}

  # Default period of 1 second if a legacy `%{requests: n}` omits `period`
  @default_period_ms 1000

  # Default cost if not specified
  @default_cost 1

  # Scheduling slack so a waiter that `Process.sleep`s the returned delay still
  # owns the reservation when it retries.
  @reservation_slack_ms 250

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
  any spend when at least one bucket cannot yet pay.

  Repeated checks of the same key are coalesced into one combined cost. Two
  checks that name the same key with different `capacity` or `refill_per_sec`
  return `{:error, %Bourse.Error{type: :invalid_parameters}}` and spend nothing.

  Pass `max_wait_ms:` when the caller will sleep the returned delay — the unpaid
  cost is reserved so cheaper traffic cannot erase accrual. Probe-style calls
  (no budget) do not reserve.
  """
  @spec check_rates([bucket_check()]) :: :ok | {:delay, pos_integer()} | {:error, Error.t()}
  @spec check_rates([bucket_check()], GenServer.name() | keyword()) ::
          :ok | {:delay, pos_integer()} | {:error, Error.t()}
  @spec check_rates([bucket_check()], GenServer.name(), keyword()) ::
          :ok | {:delay, pos_integer()} | {:error, Error.t()}
  def check_rates(bucket_checks) when is_list(bucket_checks) do
    dispatch_checks(bucket_checks, __MODULE__, [])
  end

  def check_rates(bucket_checks, opts) when is_list(bucket_checks) and is_list(opts) do
    dispatch_checks(bucket_checks, __MODULE__, opts)
  end

  def check_rates(bucket_checks, name) when is_list(bucket_checks) do
    dispatch_checks(bucket_checks, name, [])
  end

  def check_rates(bucket_checks, name, opts) when is_list(bucket_checks) and is_list(opts) do
    dispatch_checks(bucket_checks, name, opts)
  end

  @doc """
  Blocks until rate limit capacity is available, then records the request.

  Returns `{:error, %Bourse.Error{}}` when the wait would exceed the per-call
  budget (`:max_wait_ms`, default `Bourse.Defaults.rate_limit_max_wait_ms/0`).
  The refusal names the required wait and spends nothing.
  """
  @spec wait_for_capacity(key(), rate_limit() | nil) :: :ok | {:error, Error.t()}
  @spec wait_for_capacity(key(), rate_limit() | nil, number()) :: :ok | {:error, Error.t()}
  @spec wait_for_capacity(key(), rate_limit() | nil, number(), GenServer.name() | keyword()) ::
          :ok | {:error, Error.t()}
  @spec wait_for_capacity(key(), rate_limit() | nil, number(), GenServer.name(), keyword()) ::
          :ok | {:error, Error.t()}
  def wait_for_capacity(key, rate_limit, cost \\ @default_cost, name \\ __MODULE__, opts \\ [])

  def wait_for_capacity(_key, nil, _cost, _name, _opts), do: :ok

  def wait_for_capacity(key, rate_limit, cost, name, opts) when is_list(opts) do
    {name, opts} = split_limiter_name_opts(name, opts)

    case Keyword.get(opts, :max_wait_ms, Defaults.rate_limit_max_wait_ms()) do
      max_wait when is_integer(max_wait) and max_wait > 0 ->
        await_capacity(key, rate_limit, cost, name, max_wait, System.monotonic_time(:millisecond))

      other ->
        {:error, Error.invalid_parameters(message: "max_wait_ms must be a positive integer, got: #{inspect(other)}")}
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
  def handle_call({:check_rates, checks, max_wait_ms}, _from, state) do
    now = System.monotonic_time(:millisecond)

    {decisions, delay_ms} =
      Enum.reduce(checks, {[], nil}, fn {key, capacity, refill_per_sec, cost}, {acc, delay} ->
        result = check_bucket(state, key, capacity, refill_per_sec, cost, now)

        delay =
          case result do
            {:delay, ms, _} -> max(ms, delay || 0)
            _ -> delay
          end

        {[{key, cost, result} | acc], delay}
      end)

    decisions = Enum.reverse(decisions)
    new_state = persist_buckets(state, decisions, delay_ms, max_wait_ms, now)
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
          %{
            tokens: 0.0,
            updated_at: now,
            capacity: cost,
            refill_per_sec: 0.0,
            reserved: 0.0,
            reserved_until: 0
          }

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

  defp await_capacity(key, rate_limit, cost, name, max_wait, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = max_wait - elapsed

    case check_rates([{key, rate_limit, cost}], name, max_wait_ms: max(remaining, 0)) do
      :ok ->
        :ok

      {:error, %Error{}} = error ->
        error

      {:delay, delay_ms} when delay_ms > remaining ->
        {:error, wait_exceeded_error(key, delay_ms + max(elapsed, 0), max_wait)}

      {:delay, delay_ms} ->
        Process.sleep(delay_ms)
        await_capacity(key, rate_limit, cost, name, max_wait, started_at)
    end
  end

  defp wait_exceeded_error(key, wait_ms, max_wait_ms) do
    exchange_id =
      case key do
        {id, _, _} -> id
        {id, _} -> id
      end

    Error.rate_limit_exceeded(
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

  defp dispatch_checks(bucket_checks, name, opts) do
    with {:ok, checks} <- prepare_checks(bucket_checks) do
      if checks == [] do
        :ok
      else
        GenServer.call(name, {:check_rates, checks, Keyword.get(opts, :max_wait_ms)})
      end
    end
  end

  defp prepare_checks(bucket_checks) do
    bucket_checks
    |> Enum.reject(fn {_key, rate_limit, _cost} -> is_nil(rate_limit) end)
    |> Enum.map(fn {key, rate_limit, cost} -> normalize_check(key, rate_limit, cost) end)
    |> coalesce_checks()
  end

  defp coalesce_checks(checks) do
    checks
    |> Enum.reduce_while({:ok, %{}, []}, fn {key, capacity, refill, cost}, {:ok, defs, order} ->
      case Map.get(defs, key) do
        nil ->
          {:cont, {:ok, Map.put(defs, key, {capacity, refill, cost}), [key | order]}}

        {^capacity, ^refill, existing_cost} ->
          {:cont, {:ok, Map.put(defs, key, {capacity, refill, existing_cost + cost}), order}}

        {other_cap, other_refill, _} ->
          {:halt, {:error, incompatible_bucket_error(key, {capacity, refill}, {other_cap, other_refill})}}
      end
    end)
    |> case do
      {:ok, defs, order} ->
        {:ok,
         order
         |> Enum.reverse()
         |> Enum.map(fn key ->
           {capacity, refill, cost} = Map.fetch!(defs, key)
           {key, capacity, refill, cost}
         end)}

      {:error, _} = error ->
        error
    end
  end

  defp incompatible_bucket_error({exchange_id, _, _} = key, incoming, existing) do
    Error.invalid_parameters(
      exchange: exchange_id,
      message:
        "incompatible token-bucket definitions for #{inspect(key)}: " <>
          "got #{inspect(incoming)}, already #{inspect(existing)}"
    )
  end

  defp split_limiter_name_opts(name, []) when is_list(name) do
    if Keyword.keyword?(name), do: {__MODULE__, name}, else: {name, []}
  end

  defp split_limiter_name_opts(name, opts), do: {name, opts}

  @spec check_bucket(map(), key(), number(), number(), number(), integer()) ::
          {:ok, bucket_state(), bucket_state()} | {:delay, integer(), bucket_state()}
  defp check_bucket(state, key, capacity, refill_per_sec, cost, now) do
    bucket =
      case Map.get(state, key) do
        nil -> new_bucket(capacity, refill_per_sec, now)
        existing -> expire_reservation(existing, now)
      end

    refill_cap = refill_cap(bucket, capacity, cost)
    refilled = refill_bucket(bucket, refill_cap, refill_per_sec, now)

    accrued = %{
      refilled
      | capacity: capacity,
        refill_per_sec: refill_per_sec,
        updated_at: now
    }

    if available_tokens(accrued, cost) >= cost do
      {:ok, debit(accrued, cost, now), accrued}
    else
      {:delay, delay_for(accrued, cost, now, refill_per_sec), accrued}
    end
  end

  defp persist_buckets(state, decisions, delay_ms, max_wait_ms, now) do
    Enum.reduce(decisions, state, fn {key, cost, result}, acc ->
      Map.put(acc, key, persisted_bucket(result, cost, delay_ms, max_wait_ms, now))
    end)
  end

  defp persisted_bucket({:ok, paid, _accrued}, _cost, nil, _max_wait_ms, _now), do: paid
  defp persisted_bucket({:ok, _paid, accrued}, _cost, _delay_ms, _max_wait_ms, _now), do: accrued

  defp persisted_bucket({:delay, _bucket_delay, accrued}, cost, overall_delay, max_wait_ms, now) do
    persist_delay(accrued, cost, overall_delay, max_wait_ms, now)
  end

  defp persist_delay(bucket, cost, delay_ms, max_wait_ms, now) do
    reserved = Map.get(bucket, :reserved, 0.0)

    cond do
      waiter_will_claim?(max_wait_ms, delay_ms, cost, reserved) ->
        %{
          bucket
          | reserved: cost,
            reserved_until: now + delay_ms + @reservation_slack_ms
        }

      waiter_gives_up?(max_wait_ms, delay_ms, cost, reserved) ->
        expire_reservation(%{bucket | reserved_until: now}, now)

      true ->
        bucket
    end
  end

  defp waiter_will_claim?(max_wait_ms, delay_ms, cost, reserved) do
    covers_wait?(max_wait_ms, delay_ms) and cost >= reserved
  end

  defp waiter_gives_up?(max_wait_ms, delay_ms, cost, reserved) do
    is_integer(max_wait_ms) and not covers_wait?(max_wait_ms, delay_ms) and reserved > 0 and
      cost >= reserved
  end

  defp covers_wait?(max_wait_ms, delay_ms) do
    is_integer(max_wait_ms) and is_integer(delay_ms) and delay_ms <= max_wait_ms
  end

  defp new_bucket(capacity, refill_per_sec, now) do
    %{
      tokens: :erlang.float(capacity),
      updated_at: now,
      capacity: capacity,
      refill_per_sec: refill_per_sec,
      reserved: 0.0,
      reserved_until: 0
    }
  end

  defp expire_reservation(bucket, now) do
    reserved = Map.get(bucket, :reserved, 0)
    reserved_until = Map.get(bucket, :reserved_until, 0)

    bucket =
      bucket
      |> Map.put_new(:reserved, 0.0)
      |> Map.put_new(:reserved_until, 0)

    if reserved > 0 and now >= reserved_until do
      %{
        bucket
        | reserved: 0.0,
          reserved_until: 0,
          tokens: min(bucket.tokens, bucket.capacity)
      }
    else
      bucket
    end
  end

  defp refill_cap(bucket, capacity, cost) do
    reserved = Map.get(bucket, :reserved, 0)
    Enum.max([capacity, reserved, cost, bucket.tokens])
  end

  defp available_tokens(bucket, cost) do
    reserved = Map.get(bucket, :reserved, 0)

    cond do
      reserved <= 0 -> bucket.tokens
      cost >= reserved -> bucket.tokens
      true -> max(bucket.tokens - reserved, 0.0)
    end
  end

  defp debit(bucket, cost, now) do
    reserved = Map.get(bucket, :reserved, 0.0)

    {next_reserved, next_until} =
      if reserved > 0 and cost >= reserved do
        {0.0, 0}
      else
        {reserved, Map.get(bucket, :reserved_until, 0)}
      end

    %{
      bucket
      | tokens: bucket.tokens - cost,
        reserved: next_reserved,
        reserved_until: next_until,
        updated_at: now
    }
  end

  defp delay_for(bucket, cost, now, refill_per_sec) do
    reserved = Map.get(bucket, :reserved, 0)
    reserved_until = Map.get(bucket, :reserved_until, 0)
    token_delay = delay_ms(cost - bucket.tokens, refill_per_sec)

    if reserved > 0 and cost < reserved and reserved_until > now do
      max(reserved_until - now, token_delay)
    else
      token_delay
    end
  end

  @spec refill_bucket(bucket_state(), number(), number(), integer()) :: bucket_state()
  defp refill_bucket(bucket, cap, refill_per_sec, now) do
    elapsed_s = max(now - bucket.updated_at, 0) / 1000
    tokens = min(:erlang.float(cap), bucket.tokens + refill_per_sec * elapsed_s)
    %{bucket | tokens: tokens, updated_at: now, refill_per_sec: refill_per_sec}
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
