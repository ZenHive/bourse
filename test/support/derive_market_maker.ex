defmodule Bourse.Test.DeriveMarketMaker do
  @moduledoc """
  Pure pieces of the Derive market-maker journey, kept here so their behaviour
  is checked offline before the account exists.

  * Position restore: the journey records the instrument's signed size before it
    trades and computes the one order that returns the account to exactly that
    size afterwards.
  * Frame collection: the private order and trade channels have no cross-channel
    ordering guarantee, so every expected event is collected from whichever
    frame carries it, under one deadline, and no frame is consumed unread.
  * Cleanup: account mutations are restored after the body, and a failed
    restore never masks the body's own failure.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @typedoc "An expected event: a name, the channel it arrives on, and a row predicate."
  @type wanted :: {atom(), String.t(), (map() -> boolean())}

  @doc """
  The signed size of `instrument` in a `fetch_positions` result, from the
  provider's own signed `amount` (long positive, short negative). Zero when
  the account holds none.
  """
  @spec signed_size([map()], String.t()) :: Decimal.t()
  def signed_size(positions, instrument) when is_list(positions) do
    positions
    |> Enum.filter(&(info(&1)["instrument_name"] == instrument))
    |> Enum.reduce(Decimal.new(0), fn position, acc ->
      Decimal.add(acc, Decimal.new(to_string(info(position)["amount"])))
    end)
  end

  @doc """
  The order that moves the account from `current` back to `start`:
  `:none`, or `{side, amount, reduce_only?}`. `reduce_only?` is true only when
  the whole order shrinks the current position without crossing zero.
  """
  @spec restore_order(Decimal.t(), Decimal.t()) :: :none | {String.t(), Decimal.t(), boolean()}
  def restore_order(%Decimal{} = start, %Decimal{} = current) do
    delta = Decimal.sub(start, current)

    if Decimal.equal?(delta, 0) do
      :none
    else
      side = if Decimal.gt?(delta, 0), do: "buy", else: "sell"
      amount = Decimal.abs(delta)

      reduce_only =
        not Decimal.equal?(current, 0) and Decimal.lt?(Decimal.mult(delta, current), 0) and
          not Decimal.gt?(amount, Decimal.abs(current))

      {side, amount, reduce_only}
    end
  end

  @doc """
  Folds one WebSocket frame into `found`: every wanted event whose channel the
  frame carries and whose predicate a row satisfies is recorded once.
  """
  @spec absorb(term(), [wanted()], %{atom() => map()}) :: %{atom() => map()}
  def absorb({tag, frame}, wanted, found) when tag in [:websocket_message, :websocket_unmatched_response],
    do: absorb(frame, wanted, found)

  def absorb(%{"params" => %{"channel" => channel, "data" => rows}}, wanted, found) when is_list(rows) do
    Enum.reduce(wanted, found, fn {name, wanted_channel, match?}, acc ->
      with false <- Map.has_key?(acc, name),
           true <- wanted_channel == channel,
           row when is_map(row) <- Enum.find(rows, match?) do
        Map.put(acc, name, row)
      else
        _ -> acc
      end
    end)
  end

  def absorb(_frame, _wanted, found), do: found

  @doc """
  Receives frames until every wanted event is found or `timeout_ms` elapses,
  then returns the events by name. Flunks naming the events still missing.
  """
  @spec await_all!([wanted()], pos_integer()) :: %{atom() => map()}
  def await_all!(wanted, timeout_ms) do
    await_all(wanted, %{}, System.monotonic_time(:millisecond) + timeout_ms, timeout_ms)
  end

  defp await_all(wanted, found, deadline, timeout_ms) do
    missing = for {name, channel, _} <- wanted, not Map.has_key?(found, name), do: {name, channel}

    if missing == [] do
      found
    else
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        frame -> await_all(wanted, absorb(frame, wanted, found), deadline, timeout_ms)
      after
        left -> flunk("within #{timeout_ms}ms no frame carried #{inspect(missing)}")
      end
    end
  end

  @doc """
  Runs `body`, then `cleanup`, whatever `body` did. Returns `body`'s value when
  both succeed. A body failure is re-raised as is when cleanup succeeds; when
  both fail the raised assertion carries both, so a failed cleanup never hides
  the failure that preceded it.
  """
  @spec run_with_cleanup((-> value), (-> term())) :: value when value: term()
  def run_with_cleanup(body, cleanup) do
    outcome = capture(body)
    cleanup_outcome = capture(cleanup)

    case {outcome, cleanup_outcome} do
      {{:ok, value}, {:ok, _}} ->
        value

      {{:ok, _}, {kind, reason, stack}} ->
        :erlang.raise(kind, reason, stack)

      {{kind, reason, stack}, {:ok, _}} ->
        :erlang.raise(kind, reason, stack)

      {{kind, reason, stack}, {c_kind, c_reason, c_stack}} ->
        raise ExUnit.AssertionError,
          message: """
          #{Exception.format(kind, reason, stack)}
          cleanup also failed:
          #{Exception.format(c_kind, c_reason, c_stack)}\
          """
    end
  end

  defp capture(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end

  defp info(%{info: info}) when is_map(info), do: info
  defp info(%{} = raw), do: raw
end
