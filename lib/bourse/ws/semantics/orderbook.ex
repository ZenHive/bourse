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
    * `{:unavailable, reason}` — the frames for this key cannot be maintained:
      two depth streams of one market on one socket whose frames carry no
      stream name (two diff speeds, two partial depths, or a partial and a
      diff stream). Reported once per key.
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
      Bybit documents consecutive ids only for its full-ob topic. On the depth
      topics the rule is observed live on depths 50 and 1000 only, not
      documented; depth 1 sends snapshots, which are not chained. The spec
      records this as `continuity.limitation`.

  A delta that lacks any authored field is never merged: it invalidates the
  book. A snapshot that lacks its id is not published, because nothing after
  it could be chained.

  ## Frames without a type marker

  A frame of a `both` venue whose discriminator is absent is a snapshot only
  on a channel the venue documents as snapshot-only — the authored
  `continuity.snapshot_channel` (OKX `books5`/`bbo-tbt`, Deribit's grouped
  `book.*.*.*.*`). Anywhere else it invalidates the book, as does a
  discriminator value the spec does not name: an unmarked update must not
  replace the book.

  Binance spot partial-depth frames carry neither a type nor the symbol. They
  are a snapshot only while a partial-depth subscription is tracked, and their
  book is keyed by that subscription's stream name. Two such subscriptions on
  one socket cannot be told apart and are reported `{:unavailable,
  :ambiguous_depth_streams}`.

  The provider document behind each venue's rule is its authored
  `continuity.doc`; where that document does not establish the rule, the
  authored `continuity.limitation` says what does.

  ## Changed in task 708

  `apply/3,4` returns `{state, outcome}`. It returned `{state, book_or_nil}`
  before; `{:book, book}` carries what was the book, and every other outcome
  is what was `nil`.
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
          depth_streams: %{String.t() => %{String.t() => :partial | :diff}},
          anonymous_partials: %{String.t() => String.t()},
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
            anonymous_partials: %{},
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
      snapshot_channel: snapshot_channel(c["snapshot_channel"]),
      partial_depth_channel: compile_pattern(c["partial_depth_channel"])
    }
  end

  defp continuity_config(_), do: nil

  defp compile_pattern(nil), do: nil
  defp compile_pattern(pattern), do: Regex.compile!(pattern)

  defp snapshot_channel(%{"path" => path, "pattern" => pattern}), do: %{path: path, pattern: Regex.compile!(pattern)}
  defp snapshot_channel(_), do: nil

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
  def key(%__MODULE__{continuity: %{} = c} = state, frame, channel, market_id) when is_map(frame) do
    path_value(frame, c.subscription_path) || path_value(frame, c.market_path) ||
      anonymous_partial_key(state, frame, market_id || channel)
  end

  def key(%__MODULE__{}, _frame, channel, market_id), do: market_id || channel

  @doc "Returns the instrument a frame's book belongs to, read from the authored `market_path`."
  @spec market(t(), map() | nil) :: String.t() | nil
  def market(%__MODULE__{continuity: %{market_path: path}} = state, frame) when is_map(frame) do
    case path_value(frame, path) do
      market when is_binary(market) ->
        market

      _ ->
        case anonymous_partial(state, frame) do
          {:ok, _stream, market} -> market
          _ -> nil
        end
    end
  end

  def market(%__MODULE__{}, _frame), do: nil

  @doc """
  Records depth subscriptions so frames that carry no stream name can be told
  apart. Only venues with an authored `partial_depth_channel` need this: their
  partial-depth snapshots and diff deltas share one frame shape, and so do two
  diff streams of one market at different speeds.
  """
  @spec track_subscriptions(t(), [String.t() | map()]) :: t()
  def track_subscriptions(%__MODULE__{continuity: %{partial_depth_channel: %Regex{} = re} = c} = state, channels) do
    Enum.reduce(channels, state, fn
      channel, acc when is_binary(channel) ->
        case depth_stream(re, channel) do
          nil ->
            acc

          # Partial frames that carry no symbol are keyed by their stream name.
          {market, :partial} when c.unmarked_frames == "snapshot" ->
            %{acc | anonymous_partials: Map.put(acc.anonymous_partials, channel, market)}

          {market, kind} ->
            streams = Map.update(acc.depth_streams, market, %{channel => kind}, &Map.put(&1, channel, kind))
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
  # A partial-depth stream is a snapshot every frame; its next frame resyncs it.
  def resync_action(%__MODULE__{anonymous_partials: partials}, key) when is_map_key(partials, key), do: :none

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

  @doc "Returns whether `key` is waiting for a REST snapshot and no fetch or retry is scheduled for it."
  @spec needs_fetch?(t(), key()) :: boolean()
  def needs_fetch?(%__MODULE__{} = state, key) do
    match?(%{status: :bootstrapping, fetch_ref: nil}, Map.get(state.books, key))
  end

  @max_retry_delay_ms 30_000

  @doc """
  Reserves the next REST snapshot attempt for `key` under `token` after an
  unusable or failed one, and returns how long to wait before it. The delay
  doubles per consecutive failure, from one second up to thirty. Only one
  attempt is reserved per book: a later invalidation or reset drops `token`.
  """
  @spec fetch_retry(t(), key(), reference()) :: {t(), non_neg_integer()} | :none
  def fetch_retry(%__MODULE__{} = state, key, token) do
    case Map.get(state.books, key) do
      %{status: :bootstrapping, attempts: attempts} = entry ->
        delay = min(1_000 * Integer.pow(2, attempts), @max_retry_delay_ms)
        {put_entry(state, key, %{entry | fetch_ref: token, attempts: attempts + 1}), delay}

      _ ->
        :none
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
        # A body missing either side is not a book, even with a current id.
        id = if both_sides?(body), do: to_int(Map.get(body, c.rest_snapshot["id_field"]))
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

    if entry.status == :unavailable do
      {state, :pending}
    else
      case depth_stream_kind(state, key) do
        :ambiguous_anonymous ->
          {put_entry(state, key, %{new_entry() | status: :unavailable}), {:unavailable, :ambiguous_depth_streams}}

        :ambiguous ->
          {put_entry(state, key, %{new_entry() | status: :unavailable}), {:unavailable, :ambiguous_depth_streams}}

        :partial ->
          publish(state, key, snapshot_entry(payload, nil))

        _diff_or_untracked ->
          apply_continuous(state, key, entry, classify(state, payload, frame || payload), payload)
      end
    end
  end

  def apply(%__MODULE__{} = state, _key, _payload, _frame), do: {state, :none}

  # Two subscribed depth streams of one market deliver frames that cannot be
  # told apart, so neither can be maintained.
  defp depth_stream_kind(_state, {:ambiguous_depth_streams, _channel}), do: :ambiguous_anonymous

  defp depth_stream_kind(%__MODULE__{depth_streams: streams}, key) when is_binary(key) do
    case Map.get(streams, key) do
      nil -> nil
      channels when map_size(channels) > 1 -> :ambiguous
      channels -> channels |> Map.values() |> hd()
    end
  end

  defp depth_stream_kind(_state, _key), do: nil

  defp apply_continuous(state, key, _entry, :snapshot, payload) do
    case current_id(state, payload) do
      nil -> invalidate(state, key, nil, {:missing_sequence, snapshot_id_field(state)})
      id -> publish(state, key, snapshot_entry(payload, id))
    end
  end

  defp apply_continuous(%__MODULE__{continuity: c} = state, key, entry, :delta, payload) do
    if sequenced?(c, payload) do
      apply_sequenced(state, key, entry, payload)
    else
      invalidate(state, key, nil, {:missing_sequence, c.fields})
    end
  end

  defp apply_continuous(state, key, _entry, {:unmarked, reason}, _payload), do: invalidate(state, key, nil, reason)
  defp apply_continuous(state, _key, _entry, _unknown, _payload), do: {state, :none}

  defp apply_sequenced(state, key, entry, payload) do
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

  # Every field the venue's rule names must be present: a delta merged without
  # its ids could neither be checked nor chained from.
  defp sequenced?(%{fields: fields}, payload) do
    Enum.all?(fields, fn {_role, field} -> is_integer(to_int(payload[field])) end)
  end

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
  # A frame that cannot be checked is not kept (`payload` is nil).
  # A book already waiting for its snapshot keeps the request (or scheduled
  # retry) it has: the bridge rules decide whether that snapshot still fits
  # the deltas buffered after this point.
  defp invalidate(%__MODULE__{continuity: %{snapshot_source: "rest"}} = state, key, payload, reason) do
    entry =
      case Map.get(state.books, key) do
        %{status: :bootstrapping} = bootstrapping -> %{bootstrapping | buffer: List.wrap(payload)}
        _ -> %{new_entry() | status: :bootstrapping, buffer: List.wrap(payload)}
      end

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

  # A partial depth snapshot (Binance spot `lastUpdateId` + `bids`/`asks`)
  # carries the REST snapshot's id field instead of the event fields.
  defp current_id(%__MODULE__{} = state, payload), do: to_int(payload[snapshot_id_field(state)])

  defp snapshot_id_field(%__MODULE__{continuity: %{fields: f} = c}) do
    cond do
      f["current"] -> f["current"]
      c.rest_snapshot -> c.rest_snapshot["id_field"]
      true -> f["last"]
    end
  end

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

        # `attempts` stays until the replay succeeds: a gap inside the buffer
        # sends the book back to bootstrapping as the same failed attempt.

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
        buffer = Enum.reverse([delta | rest])
        restart = %{new_entry() | status: :bootstrapping, buffer: buffer, attempts: entry.attempts}
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
      state.continuity == nil -> unmarked(state)
      is_nil(value) and snapshot_channel?(state.continuity, frame) -> :snapshot
      is_nil(value) -> {:unmarked, {:unmarked_frame, field}}
      true -> {:unmarked, {:unknown_frame_type, field, value}}
    end
  end

  defp classify_both(%__MODULE__{continuity: nil}, _frame), do: :unknown
  defp classify_both(%__MODULE__{discriminator_field: field}, _frame), do: {:unmarked, {:unmarked_frame, field}}

  defp snapshot_channel?(%{snapshot_channel: %{path: path, pattern: pattern}}, frame) do
    case path_value(frame, path) do
      channel when is_binary(channel) -> Regex.match?(pattern, channel)
      _ -> false
    end
  end

  defp snapshot_channel?(_continuity, _frame), do: false

  # An event carries its sequence fields; a partial depth snapshot is told apart
  # by its own shape — the REST snapshot id field plus `bids` and `asks`, and
  # none of the event fields. Anything else is a delta, and one without its
  # ids is rejected by the continuity check rather than taken for a snapshot.
  defp classify_incremental(%__MODULE__{continuity: %{fields: f} = c} = state, payload) when is_map(payload) do
    if c.unmarked_frames == "snapshot" and state.anonymous_partials != %{} and partial_snapshot?(c, f, payload),
      do: :snapshot,
      else: :delta
  end

  defp classify_incremental(%__MODULE__{}, _payload), do: :delta

  defp partial_snapshot?(%{rest_snapshot: %{"id_field" => id_field}}, fields, payload) do
    Map.has_key?(payload, id_field) and is_list(payload["bids"]) and is_list(payload["asks"]) and
      not Enum.any?(fields, fn {_role, field} -> Map.has_key?(payload, field) end)
  end

  defp partial_snapshot?(_continuity, _fields, _payload), do: false

  defp unmarked(%__MODULE__{snapshot_values: snapshots}), do: if(snapshots == [], do: :unknown, else: :delta)

  # Resolves a symbol-less partial-depth frame to the one partial stream
  # subscribed on this socket; with two or more it cannot be attributed.
  defp anonymous_partial(%__MODULE__{continuity: %{fields: f} = c, anonymous_partials: partials}, frame)
       when partials != %{} do
    cond do
      not partial_snapshot?(c, f, frame) -> :none
      map_size(partials) == 1 -> partials |> Enum.at(0) |> then(fn {stream, market} -> {:ok, stream, market} end)
      true -> :ambiguous
    end
  end

  defp anonymous_partial(_state, _frame), do: :none

  defp anonymous_partial_key(state, frame, fallback) do
    case anonymous_partial(state, frame) do
      {:ok, stream, _market} -> stream
      :ambiguous -> {:ambiguous_depth_streams, fallback}
      :none -> fallback
    end
  end

  defp both_sides?(body), do: is_list(side_value(body, ["b", "bids"])) and is_list(side_value(body, ["a", "asks"]))

  defp side_value(body, names), do: Enum.find_value(names, &Map.get(body, &1))

  defp new_entry do
    %{
      status: :awaiting_snapshot,
      id: nil,
      awaiting_first: false,
      bids: %{},
      asks: %{},
      buffer: [],
      fetch_ref: nil,
      attempts: 0
    }
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
