defmodule Bourse.RateLimiter.State do
  @moduledoc """
  ETS-backed store for rate limit status across exchanges.

  Stores the latest `Bourse.RateLimiter.Info` from each exchange response, keyed by
  `{exchange_id, api_key | :public, bucket_axis}`. This allows consumers to
  query current rate limit pressure at any time.

  ## Architecture

  A GenServer owns the ETS table (OTP-idiomatic -- handles restarts cleanly).
  The table is `:public` with `read_concurrency: true` so any process can
  read without going through the GenServer.

  ## Usage

      case Bourse.RateLimiter.State.status("binance") do
        %Info{remaining: remaining} -> remaining
        nil -> :unknown
      end

  """

  use GenServer

  alias Bourse.RateLimiter.Info

  @table :bourse_rate_limit_state

  @doc "Starts the State GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Updates the rate limit info for a given key.

  Key is `{exchange_id, api_key | :public, bucket_axis}`. Legacy two-part keys
  are normalized to the `"request"` axis.
  """
  @spec update({String.t(), term()} | {String.t(), term(), String.t()}, Info.t()) :: :ok
  def update(key, %Info{} = info) do
    :ets.insert(@table, {normalize_key(key), info, System.monotonic_time()})
    :ok
  end

  @doc """
  Returns the latest rate limit info for an exchange's public endpoints.
  """
  @spec status(String.t()) :: Info.t() | nil
  def status(exchange_id) when is_binary(exchange_id) do
    status(exchange_id, :public)
  end

  @doc """
  Returns the latest rate limit info for a specific exchange + credential key.
  """
  @spec status(String.t(), term()) :: Info.t() | nil
  def status(exchange_id, credential_key) when is_binary(exchange_id) do
    status(exchange_id, credential_key, "request")
  end

  @doc """
  Returns the latest rate limit info for a specific exchange + credential + bucket axis.
  """
  @spec status(String.t(), term(), String.t()) :: Info.t() | nil
  def status(exchange_id, credential_key, axis) when is_binary(exchange_id) and is_binary(axis) do
    case :ets.lookup(@table, {exchange_id, credential_key, axis}) do
      [{_key, info, _timestamp}] -> info
      [] -> nil
    end
  end

  @doc """
  Returns all rate limit entries for an exchange.
  """
  @spec all(String.t()) :: [Info.t()]
  def all(exchange_id) when is_binary(exchange_id) do
    # Match all keys starting with {exchange_id, _, _}
    match_spec = [{{{exchange_id, :_, :_}, :"$1", :_}, [], [:"$1"]}]
    :ets.select(@table, match_spec)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @spec normalize_key({String.t(), term()} | {String.t(), term(), String.t()}) ::
          {String.t(), term(), String.t()}
  defp normalize_key({exchange_id, credential_key, axis}) when is_binary(axis) do
    {exchange_id, credential_key, axis}
  end

  defp normalize_key({exchange_id, credential_key}) do
    {exchange_id, credential_key, "request"}
  end
end
