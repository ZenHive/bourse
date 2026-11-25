defmodule Bourse.WS.Semantics.Orderbook do
  @moduledoc """
  Order book state driven by `websocket.orderbook_semantics`.

  Pure state: the caller feeds routed frames through `apply/4` and acts on the
  returned outcome. For incremental venues every delta is checked against the
  venue's authored continuity rule before it is merged, so a lost, duplicated
  or out-of-order delta invalidates the book instead of corrupting it.

  ## Outcomes

    * `{:book, book}` — the book is valid after this frame.
    * `:pending` — no valid book exists yet (awaiting a snapshot, or buffering
      deltas while a REST snapshot is fetched). Nothing should be published.
    * `{:fetch_snapshot, market}` — a REST-bootstrapped book needs its snapshot;
      the caller fetches it with `rest_snapshot_request/2` and hands the body to
      `apply_rest_snapshot/4`.
    * `{:invalidated, reason}` — continuity broke. The book was discarded and
      the caller must resync with `resync_action/2`.
    * `{:unavailable, reason}` — the frames for this key cannot be maintained
      (two depth streams of one market on one socket whose frames are
      indistinguishable). Reported once per key.
    * `:none` — not an order book this state maintains.

  ## Continuity rules

  Each rule reads only the field roles the venue authored in
  `continuity.fields`: `first`/`last` (the update-id range an event covers),
  `previous` (the id the venue says preceded this event) and `current` (this
  event's id).

    * `first_follows_last` — Binance spot: an event whose `last` is at or below
      the book id is stale and dropped; one whose `first` exceeds the book id + 1
      is a gap.
    * `previous_last` — Binance USDⓈ-M: the first event after the snapshot must
      span the snapshot id (`first <= id <= last`); every later event's
      `previous` must equal the prior event's `last`.
    * `previous_current` — OKX, Deribit: `previous` must equal the prior
      frame's `current`.
    * `increment` — Bybit: `current` must be the prior frame's `current` + 1.

  The provider document behind each venue's rule is its authored
  `continuity.doc`.
  """

  alias Bourse.Exchange

  @max_buffered_deltas 10_000

  @type key :: term()
  @type outcome ::
          {:book, map()}
          | :pending
          | {:fetch_snapshot, String.t()}
          | {:invalidated, term()}
          | {:unavailable, term()}
          | :none

  @type t :: %__MODULE__{
          apply_mode: String.t(),
          discriminator_field: String.t() | nil,
          snapshot_values: [String.t()],
          delta_values: [String.t()],
          sequence_fields: [String.t()],
          checksum_present: boolean(),
          continuity: map() | nil,
          depth_streams: %{String.t() => MapSet.t()},
          books: %{key() => map()}
        }

  defstruct apply_mode: "none",
            discriminator_field: nil,
            snapshot_values: [],
            delta_values: [],
            sequence_fields: [],
            checksum_present: false,
            continuity: nil,
            depth_streams: %{},
            books: %{}

  @doc "Builds state from exchange spec semantics."
  @spec new(Exchange.t()) :: t()
  def new(%Exchange{spec: spec}) do
    semantics = get_in(spec, ["websocket", "orderbook_semantics"]) || %{}

    discriminator = Map.get(semantics, "discriminator", %{})

    %__MODULE__{
      apply_mode: Map.get(semantics, "apply_mode", "none"),
      discriminator_field: Map.get(discriminator, "field"),
      snapshot_values: Map.get(discriminator, "snapshot_values", []),
      delta_values: Map.get(discriminator, "delta_values", []),
      sequence_fields: Map.get(semantics, "sequence_fields", []),
      checksum_present: get_in(semantics, ["checksum", "present"]) == true,
      continuity: continuity_config(Map.get(semantics, "continuity"))
    }
  end

  defp continuity_config(%{"rule" => rule, "fields" => fields} = c) when rule != "none" do
    %{
      rule: rule,
      fields: fields,
      market_path: c["market_path"],
      subscription_path: c["subscription_path"],
      snapshot_source: c["snapshot_source"],
      rest_snapshot: c["rest_snapshot"],
      unmarked_frames: c["unmarked_frames"],
      partial_depth_channel: compile_pattern(c["partial_depth_channel"])
    }
  end

  defp continuity_config(_), do: nil

  defp compile_pattern(nil), do: nil
  defp compile_pattern(pattern), do: Regex.compile!(pattern)

  @doc "Returns the sequence fields the continuity check reads, sorted."
  @spec consumed_fields(t()) :: [String.t()]
  def consumed_fields(%__MODULE__{continuity: nil}), do: []
  def consumed_fields(%__MODULE__{continuity: %{fields: fields}}), do: fields |> Map.values() |> Enum.sort()

  @doc """
  Resolves the key a frame's book is stored under.

  A venue whose frames name their subscription keys by it (one book per
  stream); otherwise by the authored market path, then the routed market id,
  then the channel.
  """
  @spec key(t(), map() | nil, String.t(), String.t() | nil) :: key()
  def key(%__MODULE__{continuity: %{} = c}, frame, channel, market_id) when is_map(frame) do
    path_value(frame, c.subscription_path) || path_value(frame, c.market_path) || market_id || channel
  end

  def key(%__MODULE__{}, _frame, channel, market_id), do: market_id || channel

  @doc """
  Records depth subscriptions so frames that carry no stream name can be told
  apart. Only venues with an authored `partial_depth_channel` need this: their
  partial-depth snapshots and diff deltas share one frame shape.
  """
  @spec track_subscriptions(t(), [String.t() | map()]) :: t()
  def track_subscriptions(%__MODULE__{continuity: %{partial_depth_channel: %Regex{} = re}} = state, channels) do
    Enum.reduce(channels, state, fn
      channel, acc when is_binary(channel) ->
        case depth_stream(re, channel) do
          nil ->
            acc

          {market, kind} ->
            streams = Map.update(acc.depth_streams, market, MapSet.new([kind]), &MapSet.put(&1, kind))
            %{acc | depth_streams: streams, books: Map.delete(acc.books, market)}
        end

      _channel, acc ->
        acc
    end)
  end

  def track_subscriptions(%__MODULE__{} = state, _channels), do: state

  defp depth_stream(re, channel) do
    case Regex.named_captures(re, channel) do
      %{"market" => market} ->
        {String.upcase(market), :partial}

      nil ->
        case Regex.run(~r/^([a-z0-9_]+)@depth(?:@\d+ms)?$/, channel) do
          [_, market] -> {String.upcase(market), :diff}
          nil -> nil
        end
    end
  end

  @doc "Discards every book. Used after a reconnect: each book must start again from a fresh snapshot."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = state), do: %{state | books: %{}}

  @doc "Returns how a book for `key` is resynced: `{:rest_snapshot, market}` or `{:resubscribe, subscription}`."
  @spec resync_action(t(), key()) :: {:rest_snapshot, String.t()} | {:resubscribe, term()} | :none
  def resync_action(%__MODULE__{continuity: %{snapshot_source: "rest"}}, key) when is_binary(key),
    do: {:rest_snapshot, key}

  def resync_action(%__MODULE__{continuity: %{snapshot_source: "stream"}}, key), do: {:resubscribe, key}
  def resync_action(%__MODULE__{}, _key), do: :none

  @doc "Returns `{function, params}` for the venue's authored REST depth snapshot of `market`."
  @spec rest_snapshot_request(t(), String.t()) :: {atom(), map()}
  def rest_snapshot_request(%__MODULE__{continuity: %{rest_snapshot: rest}}, market) do
    params = Map.put(Map.get(rest, "params", %{}), rest["symbol_param"], market)
    {String.to_existing_atom(rest["function"]), params}
  end

  @doc "Marks a REST snapshot fetch as in flight; only the result carrying `ref` is accepted."
  @spec fetch_started(t(), key(), reference()) :: t()
  def fetch_started(%__MODULE__{} = state, key, ref) do
    case Map.get(state.books, key) do
      %{status: :bootstrapping} = entry -> put_entry(state, key, %{entry | fetch_ref: ref})
      _ -> state
    end
  end

  @doc "Returns whether `ref` is the REST snapshot fetch currently awaited for `key`."
  @spec fetch_in_flight?(t(), key(), reference()) :: boolean()
  def fetch_in_flight?(%__MODULE__{} = state, key, ref) do
    match?(%{status: :bootstrapping, fetch_ref: ^ref}, Map.get(state.books, key))
  end

  @doc """
  Applies a REST depth snapshot body to a bootstrapping book, following the
  venue's documented bootstrap rule against the buffered deltas. A result whose
  `ref` is not the fetch in flight (superseded, or the book was reset) is ignored.
  """
  @spec apply_rest_snapshot(t(), key(), reference(), map()) :: {t(), outcome()}
  def apply_rest_snapshot(%__MODULE__{continuity: c} = state, key, ref, body) when is_map(body) do
    case Map.get(state.books, key) do
      %{status: :bootstrapping, fetch_ref: ^ref, buffer: buffer} = entry ->
        id = to_int(Map.get(body, c.rest_snapshot["id_field"]))
        bootstrap(state, key, entry, id, levels_from(body), Enum.reverse(buffer))

      _stale ->
        {state, :pending}
    end
  end

  @doc "Applies a routed order book payload. `frame` is the full decoded message."
  @spec apply(t(), key(), term(), map() | nil) :: {t(), outcome()}
  def apply(state, key, payload, frame \\ nil)

  def apply(%__MODULE__{apply_mode: "none"} = state, _key, _payload, _frame), do: {state, :none}

  def apply(%__MODULE__{continuity: nil} = state, key, payload, frame) do
    case classify(state, payload, frame || payload) do
      :delta ->
        entry = Map.get(state.books, key) || new_entry()
        merge_and_publish(state, key, %{entry | status: :live}, payload)

      kind when kind in [:snapshot, :replace] ->
        publish(state, key, snapshot_entry(payload, nil))

      :unknown ->
        {state, :none}
    end
  end

  def apply(%__MODULE__{} = state, key, payload, frame) when is_map(payload) do
    entry = Map.get(state.books, key) || new_entry()

    cond do
      entry.status == :unavailable ->
        {state, :pending}

      partial_market?(state, key) ->
        apply_partial(state, key, payload)

      true ->
        apply_continuous(state, key, entry, classify(state, payload, frame || payload), payload)
    end
  end

  def apply(%__MODULE__{} = state, _key, _payload, _frame), do: {state, :none}

  defp partial_market?(%__MODULE__{depth_streams: streams}, key) when is_binary(key) do
    case Map.get(streams, key) do
      nil -> false
      kinds -> MapSet.member?(kinds, :partial)
    end
  end

  defp partial_market?(_state, _key), do: false

  defp apply_partial(state, key, payload) do
    if MapSet.size(Map.fetch!(state.depth_streams, key)) > 1 do
      {put_entry(state, key, %{new_entry() | status: :unavailable}), {:unavailable, :ambiguous_depth_streams}}
    else
      publish(state, key, snapshot_entry(payload, nil))
    end
  end

  defp apply_continuous(state, key, _entry, :snapshot, payload) do
    publish(state, key, snapshot_entry(payload, current_id(state, payload)))
  end

  defp apply_continuous(state, key, entry, :delta, payload) do
    case {state.continuity.snapshot_source, entry.status} do
      {"rest", :awaiting_snapshot} ->
        bootstrapping = %{entry | status: :bootstrapping, buffer: [payload]}
        {put_entry(state, key, bootstrapping), {:fetch_snapshot, key}}

      {"rest", :bootstrapping} ->
        buffer_delta(state, key, entry, payload)

      {"stream", :awaiting_snapshot} ->
        {state, :pending}

      {_source, :live} ->
        chain(state, key, entry, payload)
    end
  end

  defp apply_continuous(state, _key, _entry, _unknown, _payload), do: {state, :none}

  defp buffer_delta(state, key, entry, payload) do
    if length(entry.buffer) >= @max_buffered_deltas do
      invalidate(state, key, payload, :snapshot_buffer_overflow)
    else
      {put_entry(state, key, %{entry | buffer: [payload | entry.buffer]}), :pending}
    end
  end

  defp chain(state, key, %{id: nil}, payload), do: invalidate(state, key, payload, :no_sequence_baseline)

  defp chain(state, key, entry, payload) do
    case check(state.continuity, entry, payload) do
      :apply -> merge_and_publish(state, key, next_id(state.continuity, entry, payload), payload)
      :stale -> {state, {:book, render(entry)}}
      {:gap, reason} -> invalidate(state, key, payload, reason)
    end
  end

  # A REST-bootstrapped book keeps the delta that broke the chain: it is valid
  # data, and the next snapshot is reconciled against it.
  defp invalidate(%__MODULE__{continuity: %{snapshot_source: "rest"}} = state, key, payload, reason) do
    entry = %{new_entry() | status: :bootstrapping, buffer: [payload]}
    {put_entry(state, key, entry), {:invalidated, reason}}
  end

  defp invalidate(state, key, _payload, reason) do
    {put_entry(state, key, new_entry()), {:invalidated, reason}}
  end

  defp check(%{rule: "first_follows_last", fields: f}, entry, payload) do
    first = to_int(payload[f["first"]])
    last = to_int(payload[f["last"]])

    cond do
      is_nil(first) or is_nil(last) -> {:gap, {:missing_sequence, f}}
      last <= entry.id -> :stale
      first > entry.id + 1 -> {:gap, {:expected_first_at_most, entry.id + 1, first}}
      true -> :apply
    end
  end

  defp check(%{rule: "previous_last", fields: f}, %{awaiting_first: true} = entry, payload) do
    first = to_int(payload[f["first"]])
    last = to_int(payload[f["last"]])

    cond do
      is_nil(first) or is_nil(last) -> {:gap, {:missing_sequence, f}}
      last < entry.id -> :stale
      first <= entry.id -> :apply
      true -> {:gap, {:snapshot_not_spanned, entry.id, first}}
    end
  end

  defp check(%{rule: "previous_last", fields: f}, entry, payload) do
    case to_int(payload[f["previous"]]) do
      previous when previous == entry.id -> :apply
      previous -> {:gap, {:expected_previous, entry.id, previous}}
    end
  end

  defp check(%{rule: "previous_current", fields: f}, entry, payload) do
    case to_int(payload[f["previous"]]) do
      previous when previous == entry.id -> :apply
      previous -> {:gap, {:expected_previous, entry.id, previous}}
    end
  end

  defp check(%{rule: "increment", fields: f}, entry, payload) do
    case to_int(payload[f["current"]]) do
      current when current == entry.id + 1 -> :apply
      current -> {:gap, {:expected_current, entry.id + 1, current}}
    end
  end

  defp next_id(%{fields: f}, entry, payload) do
    %{entry | id: to_int(payload[f["last"] || f["current"]]), awaiting_first: false}
  end

  defp current_id(%__MODULE__{continuity: %{fields: f}}, payload), do: to_int(payload[f["current"] || f["last"]])

  defp bootstrap(%__MODULE__{continuity: %{rule: rule, fields: f}} = state, key, entry, id, levels, buffer) do
    first_buffered = buffer |> List.first() |> then(&(&1 && to_int(&1[f["first"]])))

    cond do
      is_nil(id) ->
        {put_entry(state, key, %{entry | fetch_ref: nil}), {:fetch_snapshot, key}}

      # Binance spot: a snapshot older than the first buffered event cannot be
      # bridged; fetch again.
      rule == "first_follows_last" and is_integer(first_buffered) and id < first_buffered ->
        {put_entry(state, key, %{entry | fetch_ref: nil}), {:fetch_snapshot, key}}

      true ->
        live = %{
          entry
          | status: :live,
            id: id,
            bids: levels.bids,
            asks: levels.asks,
            buffer: [],
            fetch_ref: nil,
            awaiting_first: rule == "previous_last"
        }

        replay(state, key, live, drop_predating(rule, f, id, buffer))
    end
  end

  # Binance spot drops events with u <= lastUpdateId; USDⓈ-M drops u < lastUpdateId.
  defp drop_predating("first_follows_last", f, id, buffer), do: Enum.drop_while(buffer, &(to_int(&1[f["last"]]) <= id))
  defp drop_predating("previous_last", f, id, buffer), do: Enum.drop_while(buffer, &(to_int(&1[f["last"]]) < id))

  defp replay(state, key, entry, []), do: publish(state, key, entry)

  defp replay(state, key, entry, [delta | rest]) do
    case check(state.continuity, entry, delta) do
      :apply ->
        entry = next_id(state.continuity, entry, delta)
        replay(state, key, merge(entry, delta), rest)

      :stale ->
        replay(state, key, entry, rest)

      {:gap, _reason} ->
        restart = %{new_entry() | status: :bootstrapping, buffer: Enum.reverse([delta | rest])}
        {put_entry(state, key, restart), {:fetch_snapshot, key}}
    end
  end

  defp classify(%__MODULE__{apply_mode: mode} = state, payload, frame) do
    case mode do
      "snapshot" -> :snapshot
      "delta" -> :delta
      "replace" -> :replace
      "both" -> classify_both(state, frame)
      "incremental" -> classify_incremental(state, payload)
      _ -> :unknown
    end
  end

  defp classify_both(%__MODULE__{discriminator_field: field} = state, frame) when is_binary(field) and is_map(frame) do
    value = path_value(frame, field)

    cond do
      value in state.snapshot_values -> :snapshot
      value in state.delta_values -> :delta
      is_nil(value) -> unmarked(state)
      state.continuity == nil -> unmarked(state)
      true -> :unknown
    end
  end

  defp classify_both(%__MODULE__{}, _frame), do: :unknown

  defp classify_incremental(%__MODULE__{continuity: %{fields: f}} = state, payload) when is_map(payload) do
    if Map.has_key?(payload, f["last"] || f["current"]), do: :delta, else: unmarked(state)
  end

  defp classify_incremental(%__MODULE__{}, _payload), do: :delta

  defp unmarked(%__MODULE__{continuity: nil, snapshot_values: snapshots}),
    do: if(snapshots == [], do: :unknown, else: :delta)

  defp unmarked(%__MODULE__{continuity: %{unmarked_frames: "snapshot"}}), do: :snapshot
  defp unmarked(%__MODULE__{}), do: :unknown

  defp new_entry do
    %{status: :awaiting_snapshot, id: nil, awaiting_first: false, bids: %{}, asks: %{}, buffer: [], fetch_ref: nil}
  end

  defp snapshot_entry(payload, id) when is_map(payload) do
    levels = levels_from(payload)
    %{new_entry() | status: :live, id: id, bids: levels.bids, asks: levels.asks}
  end

  defp snapshot_entry(payload, _id), do: Map.put(%{new_entry() | status: :live}, :raw, payload)

  defp levels_from(payload) do
    %{
      bids: payload |> side(["b", "bids"]) |> Enum.reduce(%{}, &put_level(&2, &1)),
      asks: payload |> side(["a", "asks"]) |> Enum.reduce(%{}, &put_level(&2, &1))
    }
  end

  defp side(payload, names) do
    Enum.find_value(names, [], fn name ->
      case Map.get(payload, name) do
        levels when is_list(levels) -> levels
        _ -> nil
      end
    end)
  end

  defp merge_and_publish(state, key, entry, payload) when is_map(payload), do: publish(state, key, merge(entry, payload))
  defp merge_and_publish(state, key, entry, payload), do: publish(state, key, Map.put(entry, :raw, payload))

  defp merge(entry, payload) do
    bids = payload |> side(["b", "bids"]) |> Enum.reduce(entry.bids, &put_level(&2, &1))
    asks = payload |> side(["a", "asks"]) |> Enum.reduce(entry.asks, &put_level(&2, &1))
    %{entry | bids: bids, asks: asks}
  end

  # Deribit levels are [action, price, amount]; every other venue leads with
  # [price, size, ...]. A zero size removes the level.
  defp put_level(levels, [action, price, amount]) when action in ["new", "change", "delete"] do
    if action == "delete" or zero?(amount), do: Map.delete(levels, price), else: Map.put(levels, price, amount)
  end

  defp put_level(levels, [price, size | _]) do
    if zero?(size), do: Map.delete(levels, price), else: Map.put(levels, price, size)
  end

  defp put_level(levels, _malformed), do: levels

  defp zero?(size), do: to_number(size) == 0

  defp publish(state, key, entry) do
    {put_entry(state, key, entry), {:book, render(entry)}}
  end

  defp render(%{raw: raw}), do: %{"payload" => raw}

  defp render(entry) do
    %{
      "bids" => entry.bids |> Enum.sort_by(fn {p, _} -> to_number(p) end, :desc) |> Enum.map(&level/1),
      "asks" => entry.asks |> Enum.sort_by(fn {p, _} -> to_number(p) end, :asc) |> Enum.map(&level/1)
    }
  end

  defp level({price, size}), do: [price, size]

  defp put_entry(state, key, entry), do: %{state | books: Map.put(state.books, key, entry)}

  defp path_value(_frame, nil), do: nil

  defp path_value(frame, path) when is_map(frame) do
    path
    |> String.split(".")
    |> Enum.reduce_while(frame, fn segment, acc ->
      case acc do
        %{} -> {:cont, Map.get(acc, segment)}
        [single] when is_map(single) -> {:cont, Map.get(single, segment)}
        _ -> {:halt, nil}
      end
    end)
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp to_number(_), do: nil
end
