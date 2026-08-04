defmodule Bourse.Multi do
  @moduledoc """
  Parallel fetch operations across multiple exchanges.

  Enables fetching data from multiple exchanges concurrently with graceful
  handling of partial failures. Essential for dashboards, price comparison,
  and arbitrage detection.

  ## Key Features

  - **Partial failure handling**: one exchange failing doesn't kill the whole request
  - **Concurrent execution**: uses `Task.async_stream/3` for efficient parallel fetching
  - **Configurable timeouts**: per-exchange timeout with a sensible default
  - **Per-exchange symbols**: map inputs allow different symbols per exchange
  - **Result helpers**: easy extraction of successes and failures

  ## Exchange struct, not module atoms

  Unlike the original `ccxt_client_bak` port (which dispatched on generated
  exchange modules like `Bourse.Bybit`), this version operates on `%Bourse.Exchange{}`
  structs built via `Bourse.exchange/2`. Each parallel call routes through the
  unified API (`Bourse.fetch_ticker/3`, etc.) with the exchange struct as the first
  argument, and result maps are keyed by the `%Bourse.Exchange{}` struct.

  ## Usage

      {:ok, bybit} = Bourse.exchange("bybit")
      {:ok, binance} = Bourse.exchange("binance")

      # Uniform symbol across all exchanges
      result = Bourse.Multi.fetch_tickers([bybit, binance], "BTC/USDT")
      # => %{bybit => {:ok, %{...}}, binance => {:ok, %{...}}}

      # Per-exchange symbols (exchanges use different symbol formats)
      result = Bourse.Multi.fetch_tickers(%{bybit => "BTC/USDT:USDT", deribit => "BTC-PERPETUAL"})

      # Get only successful results (unwrapped)
      tickers = Bourse.Multi.successes(result)
      # => %{bybit => %{...}, binance => %{...}}

      # Check which exchanges failed (unwrapped reasons)
      failures = Bourse.Multi.failures(result)
      # => %{}  (empty if all succeeded)

      # Generic parallel call for any unified function
      result = Bourse.Multi.parallel_call([bybit, binance], :fetch_balance, [], timeout: 15_000)

  ## Common Pitfalls

  - **Always filter before consuming**: Multi results mix `{:ok, _}` and
    `{:error, _}` tuples. Call `successes/1` before passing to downstream
    consumers that expect unwrapped values.
  - **Use map form for cross-exchange symbols**: the same instrument has different
    symbol formats per exchange. The map form
    `%{deribit => "BTC-PERPETUAL", bybit => "BTC/USDT:USDT"}` handles this.

  ## Notes

  - `fetch_tickers/2,3` and `fetch_order_books/2,3` are public endpoint calls
    (no authentication required).
  - For authenticated calls, use `parallel_call/4` against exchanges built with
    credentials.
  - Timeout is per-exchange, not total (total time ≈ `max(individual timeouts)`).
  """

  alias Bourse.Exchange

  @default_timeout_ms 10_000

  @typedoc "Result map keyed by exchange struct, with `{:ok, value} | {:error, reason}` values"
  @type result(t) :: %{Exchange.t() => {:ok, t} | {:error, term()}}

  @typedoc "Map of exchange structs to a per-exchange first argument (e.g., symbol)"
  @type exchange_map :: %{Exchange.t() => term()}

  # ===========================================================================
  # fetch_tickers
  # ===========================================================================

  @doc """
  Fetches tickers from multiple exchanges in parallel.

  Returns partial results — one exchange failing doesn't kill the whole request.

  Accepts either a list of exchanges with a shared symbol, or a map of
  `%{exchange => symbol}` for per-exchange symbol formats.

  ## Parameters

  - `exchange_map` — `%{%Exchange{} => symbol}` (per-exchange symbols)
  - `exchanges` — list of `%Exchange{}` (shared symbol)
  - `symbol` — unified symbol (e.g., `"BTC/USDT"`), used with list form
  - `opts`:
    - `:timeout` — per-exchange timeout in ms (default: `#{@default_timeout_ms}`)
    - any other option is forwarded to `Bourse.fetch_ticker/3`

  ## Examples

      iex> Bourse.Multi.fetch_tickers([], "BTC/USDT")
      %{}

      iex> Bourse.Multi.fetch_tickers(%{})
      %{}
  """
  @spec fetch_tickers(exchange_map()) :: result(map())
  @spec fetch_tickers(exchange_map(), keyword()) :: result(map())
  @spec fetch_tickers([Exchange.t()], String.t()) :: result(map())
  @spec fetch_tickers([Exchange.t()], String.t(), keyword()) :: result(map())
  def fetch_tickers(map) when is_map(map) and not is_struct(map), do: fetch_tickers(map, [])

  @doc "Map form with options, or list+symbol form (defaults opts to `[]`). See `fetch_tickers/1`."
  def fetch_tickers(map, opts) when is_map(map) and not is_struct(map) and is_list(opts) do
    {call_opts, fetch_opts} = Keyword.split(opts, [:timeout])
    parallel_call(map, :fetch_ticker, [fetch_opts], call_opts)
  end

  def fetch_tickers(list, symbol) when is_list(list) and is_binary(symbol), do: fetch_tickers(list, symbol, [])

  @doc "List form with a shared symbol and options. Accepts `:timeout` in opts. See `fetch_tickers/1`."
  def fetch_tickers(list, symbol, opts) when is_list(list) and is_binary(symbol) and is_list(opts) do
    {call_opts, fetch_opts} = Keyword.split(opts, [:timeout])
    parallel_call(list, :fetch_ticker, [symbol, fetch_opts], call_opts)
  end

  # ===========================================================================
  # fetch_order_books
  # ===========================================================================

  @doc """
  Fetches order books from multiple exchanges in parallel.

  Accepts either a list of exchanges with a shared symbol, or a map of
  `%{exchange => symbol}` for per-exchange symbol formats.

  ## Parameters

  - `exchange_map` — `%{%Exchange{} => symbol}`
  - `exchanges` — list of `%Exchange{}`
  - `symbol` — unified symbol, used with list form
  - `opts`:
    - `:timeout` — per-exchange timeout in ms (default: `#{@default_timeout_ms}`)
    - `:limit` — order book depth limit (forwarded to `Bourse.fetch_order_book/3`)
    - any other option is forwarded to `Bourse.fetch_order_book/3`

  ## Examples

      iex> Bourse.Multi.fetch_order_books([], "BTC/USDT")
      %{}

      iex> Bourse.Multi.fetch_order_books(%{})
      %{}
  """
  @spec fetch_order_books(exchange_map()) :: result(map())
  @spec fetch_order_books(exchange_map(), keyword()) :: result(map())
  @spec fetch_order_books([Exchange.t()], String.t()) :: result(map())
  @spec fetch_order_books([Exchange.t()], String.t(), keyword()) :: result(map())
  def fetch_order_books(map) when is_map(map) and not is_struct(map), do: fetch_order_books(map, [])

  @doc "Map form with options, or list+symbol form (defaults opts to `[]`). See `fetch_order_books/1`."
  def fetch_order_books(map, opts) when is_map(map) and not is_struct(map) and is_list(opts) do
    {call_opts, fetch_opts} = Keyword.split(opts, [:timeout])
    parallel_call(map, :fetch_order_book, [fetch_opts], call_opts)
  end

  def fetch_order_books(list, symbol) when is_list(list) and is_binary(symbol), do: fetch_order_books(list, symbol, [])

  @doc "List form with a shared symbol and options. Accepts `:timeout` and `:limit` in opts. See `fetch_order_books/1`."
  def fetch_order_books(list, symbol, opts) when is_list(list) and is_binary(symbol) and is_list(opts) do
    {call_opts, fetch_opts} = Keyword.split(opts, [:timeout])
    parallel_call(list, :fetch_order_book, [symbol, fetch_opts], call_opts)
  end

  # ===========================================================================
  # parallel_call
  # ===========================================================================

  @doc """
  Generic parallel call — invokes any unified `Bourse` function on multiple exchanges.

  Accepts either a list of `%Exchange{}` structs with shared args, or a map of
  `%{exchange => value}` where `value` is prepended as the first argument (after
  the exchange) to each call — enabling per-exchange symbols or other values.

  Each call routes through `Bourse.<function_name>(exchange, args...)`. This is the
  core function the specialized helpers build on.

  ## Parameters

  - `exchange_or_map` — list of `%Exchange{}`, or `%{%Exchange{} => first_arg}`
  - `function_name` — unified function atom (e.g., `:fetch_ticker`, `:fetch_balance`)
  - `args` — argument list. List form: full args after the exchange. Map form:
    shared args appended after the per-exchange value.
  - `opts`:
    - `:timeout` — per-exchange timeout in ms (default: `#{@default_timeout_ms}`)

  ## Examples

      iex> Bourse.Multi.parallel_call([], :fetch_ticker, ["BTC/USDT"])
      %{}

      iex> Bourse.Multi.parallel_call(%{}, :fetch_ticker, [])
      %{}
  """
  @spec parallel_call(exchange_map() | [Exchange.t()], atom(), [term()], keyword()) :: result(term())
  def parallel_call(exchange_or_map, function_name, args, opts \\ [])

  def parallel_call(map, function_name, shared_args, opts)
      when is_map(map) and not is_struct(map) and is_atom(function_name) and is_list(shared_args) and is_list(opts) do
    entries = Map.to_list(map)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    entries
    |> Task.async_stream(
      fn {exchange, value} -> call_exchange(exchange, function_name, [value | shared_args]) end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(entries)
    |> Map.new(fn {result, {exchange, _value}} -> {exchange, normalize_result(result)} end)
  end

  def parallel_call([], _function_name, _args, _opts), do: %{}

  def parallel_call(exchanges, function_name, args, opts)
      when is_list(exchanges) and is_atom(function_name) and is_list(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    exchanges
    |> Task.async_stream(
      fn exchange -> call_exchange(exchange, function_name, args) end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(exchanges)
    |> Map.new(fn {result, exchange} -> {exchange, normalize_result(result)} end)
  end

  # ===========================================================================
  # Result helpers
  # ===========================================================================

  @doc """
  Returns only successful results, discarding errors.

  Unwraps `{:ok, value}` tuples to just values. The result map is keyed the same
  way as the input (by `%Exchange{}` for `fetch_*`/`parallel_call` output).

  ## Examples

      iex> results = %{a: {:ok, %{price: 100}}, b: {:error, :timeout}}
      iex> Bourse.Multi.successes(results)
      %{a: %{price: 100}}
  """
  @spec successes(result(t)) :: %{Exchange.t() => t} when t: var
  def successes(results) when is_map(results) do
    results
    |> Enum.filter(fn {_exchange, result} -> match?({:ok, _}, result) end)
    |> Map.new(fn {exchange, {:ok, value}} -> {exchange, value} end)
  end

  @doc """
  Returns only failed results, discarding successes.

  Unwraps `{:error, reason}` tuples to just reasons.

  ## Examples

      iex> results = %{a: {:ok, %{price: 100}}, b: {:error, :timeout}}
      iex> Bourse.Multi.failures(results)
      %{b: :timeout}
  """
  @spec failures(result(term())) :: %{Exchange.t() => term()}
  def failures(results) when is_map(results) do
    results
    |> Enum.filter(fn {_exchange, result} -> match?({:error, _}, result) end)
    |> Map.new(fn {exchange, {:error, reason}} -> {exchange, reason} end)
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  # Calls the unified Bourse function with the exchange as the first argument and
  # wraps any failure (unexported function, exception, throw) in {:error, _}.
  @spec call_exchange(Exchange.t(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defp call_exchange(%Exchange{} = exchange, function_name, args) do
    Code.ensure_loaded!(Bourse)
    arity = length(args) + 1

    if function_exported?(Bourse, function_name, arity) do
      apply(Bourse, function_name, [exchange | args])
    else
      {:error, {:function_not_exported, {Bourse, function_name, arity}}}
    end
  rescue
    # reach:disable-next-line bare_rescue — intentional: convert any apply/3 exception into a uniform {:error, _} result
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp call_exchange(other, _function_name, _args) do
    {:error, {:not_an_exchange, other}}
  end

  # Normalizes Task.async_stream result to {:ok, _} | {:error, _}.
  # Unified functions already return {:ok, value} | {:error, reason}; raw values
  # are auto-wrapped in {:ok, value}.
  @spec normalize_result({:ok, term()} | {:exit, term()}) :: {:ok, term()} | {:error, term()}
  defp normalize_result({:ok, {:ok, value}}), do: {:ok, value}
  defp normalize_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_result({:ok, other}), do: {:ok, other}
  defp normalize_result({:exit, :timeout}), do: {:error, :timeout}
  defp normalize_result({:exit, reason}), do: {:error, {:exit, reason}}
end
