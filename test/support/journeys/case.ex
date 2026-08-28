defmodule Bourse.Test.Journeys.Case do
  @moduledoc """
  Case template for the live journey suites under `test/live/journeys/`.

  A journey file plays one role (`trader/`, `option_seller/`, `market_maker/`)
  against one venue's sandbox host, top to bottom: real reads, real orders,
  and its own cleanup. Journeys mutate venue state, so every journey module
  is tagged `:dangerous` (opt-in via `--include dangerous`) alongside
  `:journey` and `:network` for selection.

  This is the only shared module journeys use — the flow itself stays inside
  each venue file so a red test reads as a story, not a helper stack.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Bourse.Error
  alias Bourse.Order

  @poll_attempts 20
  @poll_interval_ms 250

  using do
    quote do
      import Bourse.Test.Journeys.Case

      @moduletag :journey
      @moduletag :network
      @moduletag :dangerous
    end
  end

  @doc """
  Authenticated sandbox exchange for `venue`, with market metadata loaded.

  Credentials come from `Bourse.Testnet` (registered by `test_helper.exs`,
  which already raises with the exact env vars when a pair is missing).
  """
  def sandbox_exchange!(venue) do
    credentials = Bourse.Testnet.creds!(venue)
    {:ok, exchange} = Bourse.Exchange.new(to_string(venue), credentials: credentials, sandbox: true)

    case Bourse.load_markets(exchange) do
      {:ok, loaded} -> loaded
      {:error, error} -> flunk("#{venue}: load_markets failed against the sandbox host: #{inspect(error)}")
    end
  end

  @doc """
  Client order id anchored to wall-clock time.

  `System.unique_integer/1` alone resets per VM start and collides on a
  persistent sandbox account (bybit rejects the duplicate as error 170141).
  """
  def unique_client_order_id(prefix \\ "journey") do
    "#{prefix}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Cancels a resting order during cleanup, tolerating the states a finished
  journey legitimately leaves behind (already canceled, already gone).
  """
  def release_order!(exchange, id, symbol) do
    case Bourse.cancel_order(exchange, id, symbol: symbol) do
      {:ok, %Order{}} -> :ok
      {:error, %Error{type: :order_not_found}} -> :ok
      {:error, %Error{type: :invalid_order}} -> :ok
      # OKX already-canceled/filled cancel is a batch envelope: outer code "1",
      # per-order sCode 51400. Authored mapping of 51400 is OrderNotFound, but
      # classification keys the outer code, so the typed match above misses.
      {:error, %Error{raw: %{"data" => [%{"sCode" => "51400"}]}}} -> :ok
      {:error, error} -> flunk("cleanup for order #{id} failed: #{inspect(error)}")
    end
  end

  @doc """
  Polls `fun` until it returns `{:ok, value}`; `:retry` waits and tries again.

  Live sandboxes propagate writes with a small lag, so journeys poll for the
  state they just created instead of asserting on the first read.
  """
  def poll_until!(label, fun), do: poll_until!(label, fun, @poll_attempts)

  defp poll_until!(label, _fun, 0), do: flunk("gave up polling: #{label}")

  defp poll_until!(label, fun, attempts) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        Process.sleep(@poll_interval_ms)
        poll_until!(label, fun, attempts - 1)
    end
  end

  @doc "Asserts a venue-reported millisecond timestamp is close to now."
  def assert_recent_timestamp!(timestamp_ms, within_ms \\ to_timeout(minute: 5)) do
    now = System.system_time(:millisecond)

    assert is_integer(timestamp_ms) and abs(now - timestamp_ms) <= within_ms,
           "venue timestamp #{inspect(timestamp_ms)} is not within #{within_ms}ms of now (#{now})"
  end
end
