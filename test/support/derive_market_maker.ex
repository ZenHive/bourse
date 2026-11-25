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
        Decimal.lt?(Decimal.mult(delta, current), 0) and not Decimal.gt?(amount, Decimal.abs(current))

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
      # The absolute deadline is checked before every receive: a frame still
      # queued once it has passed is not accepted.
      left = deadline - System.monotonic_time(:millisecond)

      if left <= 0 do
        flunk_missing(missing, timeout_ms)
      else
        receive do
          frame -> await_all(wanted, absorb(frame, wanted, found), deadline, timeout_ms)
        after
          left -> flunk_missing(missing, timeout_ms)
        end
      end
    end
  end

  defp flunk_missing(missing, timeout_ms), do: flunk("within #{timeout_ms}ms no frame carried #{inspect(missing)}")

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

  @doc """
  Runs every cleanup step, each one whether or not an earlier one failed.
  Returns `:ok` when all succeed; one failure is re-raised as is, several are
  raised together in step order.
  """
  @spec cleanup_all([(-> term())]) :: :ok
  def cleanup_all(steps) when is_list(steps) do
    case for step <- steps, outcome = capture(step), elem(outcome, 0) != :ok, do: outcome do
      [] ->
        :ok

      [{kind, reason, stack}] ->
        :erlang.raise(kind, reason, stack)

      failures ->
        raise ExUnit.AssertionError,
          message:
            Enum.map_join(failures, "\nanother cleanup step also failed:\n", fn {k, r, st} ->
              Exception.format(k, r, st)
            end)
    end
  end

  @mmp_fields ~w(mmp_interval mmp_frozen_time mmp_amount_limit mmp_delta_limit)

  @doc """
  The MMP state cleanup must leave behind, from the config read
  before the test (`nil` when none existed): the four config fields, and the
  freeze state. No prior config restores as disabled (`mmp_interval 0`), the
  provider's own "MMP off" state.
  """
  @spec mmp_restore_target(map() | nil) :: map()
  def mmp_restore_target(nil),
    do: %{
      "mmp_interval" => 0,
      "mmp_frozen_time" => 0,
      "mmp_amount_limit" => "0",
      "mmp_delta_limit" => "0",
      "is_frozen" => false
    }

  def mmp_restore_target(%{} = original) do
    original |> mmp_frozen!() |> then(&Map.put(Map.take(original, @mmp_fields), "is_frozen", &1))
  end

  @doc """
  The config row for `currency` from a `private/get_mmp_config` result, or
  `nil` when none exists. A returned row must carry a boolean `is_frozen`:
  a missing, null or string flag is not evidence of either state.
  """
  @spec mmp_config_row!([map()], String.t()) :: map() | nil
  def mmp_config_row!(configs, currency) when is_list(configs) do
    case Enum.find(configs, &(&1["currency"] == currency)) do
      nil ->
        nil

      row ->
        mmp_frozen!(row)
        row
    end
  end

  defp mmp_frozen!(%{"is_frozen" => frozen}) when is_boolean(frozen), do: frozen

  defp mmp_frozen!(row),
    do: flunk("MMP config row carries no boolean is_frozen, so its freeze state is unknown: #{inspect(row)}")

  @doc """
  True when cleanup must call `reset_mmp`: a config exists whose freeze flag is
  anything but literal `false` while the target state is unfrozen.
  """
  @spec mmp_needs_reset?(map(), map() | nil) :: boolean()
  def mmp_needs_reset?(_target, nil), do: false
  def mmp_needs_reset?(%{"is_frozen" => false}, %{} = current), do: current["is_frozen"] !== false
  def mmp_needs_reset?(_target, _current), do: false

  @doc """
  The fields where `current` differs from `target`, freeze state included;
  amount and delta limits compare as decimals. `[]` means restored.
  """
  @spec mmp_mismatches(map(), map() | nil) :: [String.t()]
  def mmp_mismatches(_target, nil), do: ["config missing"]

  def mmp_mismatches(target, %{} = current) do
    for field <- ["is_frozen" | @mmp_fields], not same?(field, target[field], current[field]), do: field
  end

  defp same?("is_frozen", target, current), do: is_boolean(current) and current === target

  defp same?(field, target, current) when field in ~w(mmp_amount_limit mmp_delta_limit),
    do: not is_nil(current) and Decimal.equal?(Decimal.new(to_string(target)), Decimal.new(to_string(current)))

  defp same?(_field, target, current), do: target === current

  @doc """
  Reads every page of a paginated private RPC. `fetch_page` gets a 1-based
  page number and returns `{:ok, result}`, where `result` carries the rows
  under `key` and `pagination.num_pages`. Flunks on any failed page, a
  missing page count, or a count that changes during the read: an incomplete
  read is never treated as an empty one.
  """
  @spec read_all_pages!(String.t(), (pos_integer() -> {:ok, map()} | term())) :: [map()]
  def read_all_pages!(key, fetch_page) do
    {rows, num_pages} = read_page!(key, fetch_page, 1)
    rest = for page <- 2..num_pages//1, do: read_page!(key, fetch_page, page, num_pages)
    rows ++ Enum.flat_map(rest, & &1)
  end

  defp read_page!(key, fetch_page, page) do
    case fetch_page.(page) do
      {:ok, %{"pagination" => %{"num_pages" => n}} = result} when is_integer(n) and n >= 0 ->
        {page_rows!(result, key, page), n}

      other ->
        flunk("page #{page} of #{key} is not a complete paginated result: #{inspect(other)}")
    end
  end

  defp read_page!(key, fetch_page, page, num_pages) do
    case fetch_page.(page) do
      {:ok, %{"pagination" => %{"num_pages" => ^num_pages}} = result} ->
        page_rows!(result, key, page)

      other ->
        flunk("page #{page} of #{num_pages} of #{key} failed or changed page count mid-read: #{inspect(other)}")
    end
  end

  defp page_rows!(result, key, page) do
    case result[key] do
      rows when is_list(rows) -> rows
      other -> flunk("page #{page} of #{key} carries no #{key} list: #{inspect(other)}")
    end
  end

  @doc """
  Ids of open MMP orders and quotes on `currency`'s instruments: the provider
  cancels them when the threshold trips, so a deliberate freeze must not run
  while any exist. Orders are `private/get_open_orders` rows, quotes
  `private/get_quotes` rows (instruments in `legs`).
  """
  @spec mmp_exposure([map()], [map()], String.t()) :: [String.t()]
  def mmp_exposure(orders, quotes, currency) do
    on_currency? = &String.starts_with?(to_string(&1), currency <> "-")

    order_ids =
      for %{"mmp" => true, "order_status" => "open", "instrument_name" => name} = o <- orders,
          on_currency?.(name),
          do: o["order_id"]

    quote_ids =
      for %{"mmp" => true, "status" => "open"} = q <- quotes,
          Enum.any?(q["legs"] || [], &on_currency?.(&1["instrument_name"])),
          do: q["quote_id"]

    order_ids ++ quote_ids
  end

  defp capture(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end

  defp info(%{info: info}) when is_map(info), do: info
  defp info(%{} = raw), do: raw
end
