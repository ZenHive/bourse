defmodule Bourse.WS.OrderBookContinuityLiveTest do
  @moduledoc """
  Provider-live evidence that incremental order books check continuity
  (task 708).

  Each venue's diff stream is consumed through `Bourse.WS.Adapter`: the public
  one, except deribit's `book.BTC-PERPETUAL.raw` on an authenticated socket. The
  test observes real deltas chaining under the venue's documented rule, then
  breaks the stream two ways:

    * a real delta is dropped between the socket and the adapter, the gap a
      lost frame leaves;
    * the live transport goes down (`gun_down`, as when the venue closes the
      socket) and a new one is dialled.

  After each break it asserts that the book is invalidated, that every routed
  frame carries no book until the resync is independently observed — a frame
  the venue itself marks as a snapshot, or a REST depth response — and that
  the resynced book matches the venue's own REST depth snapshot.

  Every venue runs against its testnet/demo host (`sandbox: true`), measured
  2026-11-25 to serve the same depth frames and sequence fields as production:

    * binance — `wss://stream.testnet.binance.vision/ws`, `U`/`u`, REST `testnet.binance.vision`
    * binanceusdm — `wss://demo-fstream.binance.com/public/ws`, `U`/`u`/`pu`, REST `demo-fapi.binance.com`
    * okx — `wss://wspap.okx.com:8443/ws/v5/public`, `prevSeqId`/`seqId`, REST with `x-simulated-trading: 1`
    * deribit — `wss://test.deribit.com/ws/api/v2` private section (`public/auth` with the
      `DERIBIT_TESTNET_*` pair), `book.BTC-PERPETUAL.raw`, `type` + `change_id`/`prev_change_id`,
      REST `test.deribit.com`
    * bybit — `wss://stream-testnet.bybit.com/v5/public/linear`, `orderbook.1000`, `u` incrementing by one,
      REST `/v5/market/orderbook` carrying the same `u`

  REST snapshot alignment: the REST snapshot carries a sequence id `R`. The WS
  book compared against it is the one published after the frame whose id range
  covers `R`. When `R` is that frame's own end id the two books describe the
  same state and are compared in full; otherwise the prices the frame touched
  are excluded, because it also carries updates past `R`. okx and deribit are
  compared only where `R` is a frame's own end id: an aggregated push may omit
  a change that reverses within its interval
  (https://www.okx.com/docs-v5/trick_en/#market-data), so a state inside a
  frame is not a prefix of the frame's end state. deribit runs on `raw`, its
  finest granularity ("events are aggregated over a 1 millisecond interval",
  "only available to authorized users" —
  https://docs.deribit.com/subscriptions/orderbook/bookinstrument_nameinterval.md;
  an unauthenticated subscribe is refused live with error 13778
  `raw_subscriptions_not_available_for_unauthorized`), where a REST
  `change_id` lands on a frame's own id often enough to align within the
  bound; on `100ms` it did not in five reads. A REST snapshot no WS frame
  aligns with is fetched again, up to `@rest_attempts` reads and a hard
  deadline; an aligned snapshot that disagrees fails the test.

  bybit documents consecutive `u` only for its full-ob topic; on the depth
  topics the `increment` rule is the observation this test makes, recorded as
  the spec's `continuity.limitation` and in `docs/prod-verification-ledger.md`.

  Sequence contracts (provider documents, also authored as
  `continuity.doc` in each venue spec):

    * binance — https://developers.binance.com/docs/binance-spot-api-docs/web-socket-streams#how-to-manage-a-local-order-book-correctly
    * binanceusdm — https://developers.binance.com/docs/derivatives/usds-margined-futures/websocket-market-streams/How-to-manage-a-local-order-book-correctly
    * okx — https://www.okx.com/docs-v5/en/#order-book-trading-market-data-ws-order-book-channel
    * deribit — https://docs.deribit.com/subscriptions/orderbook/bookinstrument_nameinterval.md
    * bybit — https://bybit-exchange.github.io/docs/v5/websocket/public/orderbook
  """

  use Bourse.Test.Case, async: false

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Adapter
  alias Bourse.WS.Broadcast

  @moduletag :network
  @moduletag :integration
  @moduletag timeout: 180_000

  # Each phase (initial books, invalidation, resync) has this much time in all,
  # however many frames arrive meanwhile.
  @receive_timeout 20_000
  @chained_books 8
  @compare_levels 25

  @venues %{
    "binance" => %{
      channel: "btcusdt@depth@100ms",
      delta?: &__MODULE__.binance_delta?/1,
      chained?: &__MODULE__.binance_chained?/2,
      range: &__MODULE__.binance_range/1,
      rest: &__MODULE__.binance_rest/1,
      payload: &Function.identity/1,
      resync:
        {:rest,
         %{
           stale?: &__MODULE__.binance_stale?/2,
           bridges?: &__MODULE__.binance_bridges?/2,
           follows?: &__MODULE__.binance_chained?/2
         }}
    },
    "binanceusdm" => %{
      channel: "btcusdt@depth@100ms",
      delta?: &__MODULE__.binance_delta?/1,
      chained?: &__MODULE__.usdm_chained?/2,
      range: &__MODULE__.usdm_range/1,
      rest: &__MODULE__.usdm_rest/1,
      payload: &Function.identity/1,
      resync:
        {:rest,
         %{
           stale?: &__MODULE__.usdm_stale?/2,
           bridges?: &__MODULE__.usdm_bridges?/2,
           follows?: &__MODULE__.usdm_chained?/2
         }}
    },
    "okx" => %{
      channel: %{"channel" => "books", "instId" => "BTC-USDT"},
      delta?: &__MODULE__.okx_delta?/1,
      chained?: &__MODULE__.okx_chained?/2,
      range: &__MODULE__.okx_range/1,
      rest: &__MODULE__.okx_rest/1,
      rest_alignment: :end_id,
      payload: &__MODULE__.okx_payload/1,
      resync: {:stream, &__MODULE__.okx_snapshot_id/1, &__MODULE__.okx_payload_id/1}
    },
    "deribit" => %{
      channel: "book.BTC-PERPETUAL.raw",
      section: :private,
      delta?: &__MODULE__.deribit_delta?/1,
      chained?: &__MODULE__.deribit_chained?/2,
      range: &__MODULE__.deribit_range/1,
      rest: &__MODULE__.deribit_rest/1,
      rest_alignment: :end_id,
      payload: &__MODULE__.deribit_payload/1,
      resync: {:stream, &__MODULE__.deribit_snapshot_id/1, &__MODULE__.deribit_payload_id/1}
    },
    "bybit" => %{
      channel: "orderbook.1000.BTCUSDT",
      delta?: &__MODULE__.bybit_delta?/1,
      chained?: &__MODULE__.bybit_chained?/2,
      range: &__MODULE__.bybit_range/1,
      rest: &__MODULE__.bybit_rest/1,
      payload: &__MODULE__.bybit_payload/1,
      resync: {:stream, &__MODULE__.bybit_snapshot_id/1, &__MODULE__.bybit_payload_id/1}
    }
  }

  for venue <- ~w(binance binanceusdm okx deribit bybit) do
    describe "#{venue}" do
      @tag venue: venue
      test "chains real deltas, invalidates on a dropped delta, and resyncs", %{venue: venue} do
        config = Map.fetch!(@venues, venue)
        {_adapter, drop} = start(venue, config)

        history = await_books(@chained_books, [], deadline())
        assert_chained(history, config)

        :atomics.put(drop, 1, 1)
        assert_receive {:dropped_delta, _frame}, @receive_timeout

        # The delta after the dropped one reveals the gap. It must not be
        # published, neither before nor after the invalidation.
        assert_receive {:offending_delta, offending}, @receive_timeout
        {reason, deltas} = await_invalidation(offending, [], deadline())
        assert gap_reason?(reason), "expected a continuity gap, got #{inspect(reason)}"

        resynced = await_resynced_book(config, offending, deltas, nil, deadline())
        compare_with_rest(venue, config, resynced)
      end

      @tag venue: venue
      test "after the live transport drops, the first book comes from a fresh snapshot", %{venue: venue} do
        config = Map.fetch!(@venues, venue)
        {adapter, _drop} = start(venue, config)
        _history = await_books(3, [], deadline())

        old = transport(adapter)
        send(old.server, {:gun_down, old.gun, :http, :closed, []})

        {reason, _deltas} = await_invalidation(nil, [], deadline())
        assert {:connection_lost, {:gun_down, _, :http, :closed, []}} = reason
        assert_receive {:connected, ws}, @receive_timeout
        refute ws.zen_client.server_pid == old.server
        refute Process.alive?(old.server)

        # Deltas from the lost connection cannot bridge the new snapshot.
        resynced = await_resynced_book(config, nil, [], nil, deadline())
        compare_with_rest(venue, config, resynced)
      end
    end
  end

  # -- setup ------------------------------------------------------------------

  defp sandbox(venue), do: Exchange.new!(venue, sandbox: true)

  defp sandbox(venue, %{section: :private}),
    do: Exchange.new!(venue, sandbox: true, credentials: Bourse.Testnet.creds!(String.to_existing_atom(venue)))

  defp sandbox(venue, _config), do: sandbox(venue)

  defp start(venue, config) do
    test_pid = self()
    drop = :atomics.new(1, [])
    Broadcast.subscribe(Broadcast.topic(venue, :watch_order_book, nil))
    handles = own_handles()
    observed = observe_incoming()

    connect_fun = fn exchange, section, opts ->
      filtered = dropping_handler(Keyword.fetch!(opts, :handler), config, drop, observed, test_pid)

      with {:ok, ws} <- WS.connect(exchange, section, Keyword.put(opts, :handler, filtered)) do
        Agent.update(handles, &[ws | &1])
        send(test_pid, {:connected, ws})
        {:ok, ws}
      end
    end

    {:ok, adapter} =
      Adapter.start_link(sandbox(venue, config), Map.get(config, :section, :public), connect_fun: connect_fun)

    Agent.update(handles, &[adapter | &1])

    if match?({:rest, _}, config.resync), do: trace_rest_snapshots(adapter)
    assert_receive {:connected, _ws}, @receive_timeout
    assert :ok = Adapter.subscribe(adapter, [config.channel])
    {adapter, drop}
  end

  # Every adapter and connection a case opens, the replacements after a
  # reconnect included, is closed when the case ends — also when it fails or
  # times out, which kills the test process but not the connection owner, the
  # client or its transport. The registry is not linked to the test process,
  # so it outlives it until the cleanup has run.
  defp own_handles do
    {:ok, handles} = Agent.start(fn -> [] end)

    on_exit(fn ->
      for handle <- Agent.get(handles, & &1), do: close_handle(handle)
      Agent.stop(handles)
    end)

    handles
  end

  defp close_handle(%WS{} = ws) do
    WS.close(ws)
  catch
    :exit, _ -> :ok
  end

  defp close_handle(adapter) when is_pid(adapter) do
    if Process.alive?(adapter), do: GenServer.stop(adapter)
  catch
    :exit, _ -> :ok
  end

  # What reached the socket, counted before the adapter sees it: a timeout then
  # tells a quiet venue (no deltas) from a book the adapter did not publish.
  defp observe_incoming do
    {:ok, observed} = Agent.start(fn -> %{frames: 0, deltas: 0, last: nil} end)
    on_exit(fn -> if Process.alive?(observed), do: Agent.stop(observed) end)
    Process.put(:observed_incoming, observed)
    observed
  end

  defp count_incoming(observed, data, delta?) do
    Agent.cast(observed, fn seen ->
      if delta?,
        do: %{seen | frames: seen.frames + 1, deltas: seen.deltas + 1, last: ids(data)},
        else: %{seen | frames: seen.frames + 1}
    end)
  end

  # The diagnosis appended to every phase timeout. `published` is what the
  # phase itself saw routed: books, and frames routed with no book.
  defp stream_report(published) do
    incoming =
      case Process.get(:observed_incoming) do
        nil ->
          "not observed"

        observed ->
          observed |> Agent.get(& &1) |> then(&"#{&1.frames} frames, #{&1.deltas} deltas, last delta #{inspect(&1.last)}")
      end

    "venue -> socket: #{incoming}; adapter -> test in this phase: " <>
      "#{published.books} books (last #{inspect(published.last)}), #{published.empty} routed without a book"
  end

  defp published, do: %{books: 0, empty: 0, last: nil}
  defp published(seen, nil), do: %{seen | empty: seen.empty + 1}
  defp published(seen, payload), do: %{seen | books: seen.books + 1, last: ids(payload)}

  defp deadline, do: System.monotonic_time(:millisecond) + @receive_timeout
  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # A receive takes a queued message even when its timeout has passed, so a
  # steady stream would never reach `after`; each phase checks its deadline
  # before every receive.
  defp expired!(deadline, message), do: if(left(deadline) == 0, do: flunk(message.()))

  # The REST snapshot the adapter receives is the one its bridge is built on;
  # tracing its mailbox lets the test rebuild that bridge on its own.
  defp trace_rest_snapshots(adapter) do
    :erlang.trace_pattern(:receive, [{[:_, :_, {:order_book_snapshot, :_, :_, :_}], [], []}], [])
    :erlang.trace(adapter, true, [:receive])
    on_exit(fn -> :erlang.trace_pattern(:receive, true, []) end)
  end

  defp transport(adapter) do
    server = :sys.get_state(adapter).ws.zen_client.server_pid
    %{server: server, gun: :sys.get_state(server).gun_pid}
  end

  # Sits between the socket and the adapter. While `drop` is armed, the next
  # real delta is taken out of the stream — the gap a lost frame leaves. A
  # frame the venue marks as a snapshot is reported before the adapter sees
  # it, so the test knows independently where a fresh book starts.
  # Every forwarded delta of a REST-bootstrapped venue is reported, so the
  # test can rebuild the book from the REST snapshot and the deltas after it.
  # After a drop, the next delta is reported as the one that reveals the gap.
  defp dropping_handler(handler, config, drop, observed, test_pid) do
    fn
      {:message, data} = message ->
        report_snapshot(data, config, test_pid)
        delta? = is_map(data) and config.delta?.(data)
        count_incoming(observed, data, delta?)

        if delta? and :atomics.compare_exchange(drop, 1, 1, 2) == :ok,
          do: send(test_pid, {:dropped_delta, data}),
          else: forward(message, delta?, config, drop, test_pid, handler)

      message ->
        handler.(message)
    end
  end

  defp report_snapshot(data, config, test_pid) do
    with {:stream, snapshot_id, _payload_id} <- config.resync,
         true <- is_map(data),
         id when not is_nil(id) <- snapshot_id.(data) do
      send(test_pid, {:snapshot_frame, id, config.payload.(data)})
    end
  end

  defp forward({:message, data} = message, delta?, config, drop, test_pid, handler) do
    if delta?, do: report_delta(data, config, drop, test_pid)
    handler.(message)
  end

  defp report_delta(data, config, drop, test_pid) do
    if :atomics.compare_exchange(drop, 1, 2, 0) == :ok,
      do: send(test_pid, {:offending_delta, config.payload.(data)})

    if match?({:rest, _}, config.resync), do: send(test_pid, {:delta_frame, data})
  end

  # -- observation ------------------------------------------------------------

  # Collects `count` routed frames that carry a book, newest first. A routed
  # frame with a nil book is a frame received while no valid book exists.
  defp await_books(count, acc, deadline), do: await_books(count, acc, deadline, published())

  defp await_books(0, acc, _deadline, _seen), do: acc

  defp await_books(count, acc, deadline, seen) do
    timeout = fn -> "#{count} of the order books still expected after #{@receive_timeout}ms; #{stream_report(seen)}" end
    expired!(deadline, timeout)

    receive do
      {:bourse_ws, {:routed, :watch_order_book, payload, _channel, _market, %{"bids" => _} = book}} ->
        await_books(count - 1, [{payload, book} | acc], deadline, published(seen, payload))

      {:bourse_ws, {:routed, :watch_order_book, _payload, _channel, _market, nil}} ->
        await_books(count, acc, deadline, published(seen, nil))

      {:bourse_ws, {:order_book_invalidated, _channel, _market, reason}} ->
        flunk("book invalidated while chaining live deltas: #{inspect(reason)}")
    after
      left(deadline) -> flunk(timeout.())
    end
  end

  # Routed books that were already queued when the break happened are valid,
  # and so are snapshot markers and REST responses from before it; all of them
  # are consumed in arrival order up to the invalidation.
  # Returns the reason and the forwarded deltas seen so far, oldest first.
  defp await_invalidation(offending, deltas, deadline) do
    expired!(deadline, &invalidation_timeout/0)

    receive do
      {:bourse_ws, {:order_book_invalidated, _channel, "BTC" <> _, reason}} ->
        {reason, Enum.reverse(deltas)}

      {:bourse_ws, {:order_book_invalidated, _channel, market, reason}} ->
        flunk("invalidation for #{inspect(market)}: #{inspect(reason)}")

      {:bourse_ws, {:routed, :watch_order_book, payload, _, _, book}} ->
        refute_offending(offending, payload, book, "before")
        await_invalidation(offending, deltas, deadline)

      {:delta_frame, delta} ->
        await_invalidation(offending, [delta | deltas], deadline)

      {:snapshot_frame, _id, _payload} ->
        await_invalidation(offending, deltas, deadline)

      {:trace, _pid, :receive, {:order_book_snapshot, _, _, _}} ->
        await_invalidation(offending, deltas, deadline)
    after
      left(deadline) -> flunk(invalidation_timeout())
    end
  end

  defp invalidation_timeout,
    do: "the break did not invalidate the book within #{@receive_timeout}ms; #{stream_report(published())}"

  defp refute_offending(nil, _payload, _book, _side), do: :ok
  defp refute_offending(_offending, _payload, nil, _side), do: :ok

  defp refute_offending(offending, payload, _book, side) do
    refute payload == offending, "the delta that revealed the gap was published #{side} the invalidation"
  end

  # After an invalidation every routed frame must carry no book until the
  # resync is observed independently of the adapter: a frame the venue marks
  # as a snapshot, or a REST depth body the adapter received. The first book
  # must then equal that snapshot's levels — or, for a REST venue, the REST
  # snapshot with every later delta applied in order, as the venue documents.
  # Returns the books routed from there, newest first.
  defp await_resynced_book(config, offending, deltas, seen, deadline, routed \\ published()) do
    timeout = fn ->
      "no resynced book within #{@receive_timeout}ms (resync seen: #{inspect(seen)}); #{stream_report(routed)}"
    end

    expired!(deadline, timeout)

    receive do
      {:snapshot_frame, id, payload} ->
        await_resynced_book(config, offending, deltas, {:snapshot, id, payload}, deadline, routed)

      {:trace, _pid, :receive, {:order_book_snapshot, _key, _ref, {:ok, %{status: 200, body: body}}}} ->
        await_resynced_book(config, offending, deltas, {:rest, body}, deadline, routed)

      {:trace, _pid, :receive, {:order_book_snapshot, _key, _ref, _failed}} ->
        await_resynced_book(config, offending, deltas, seen, deadline, routed)

      {:delta_frame, delta} ->
        await_resynced_book(config, offending, deltas ++ [delta], seen, deadline, routed)

      {:connected, _ws} ->
        await_resynced_book(config, offending, deltas, seen, deadline, routed)

      {:bourse_ws, {:routed, :watch_order_book, _payload, _channel, _market, nil}} ->
        await_resynced_book(config, offending, deltas, seen, deadline, published(routed, nil))

      {:bourse_ws, {:routed, :watch_order_book, payload, _channel, _market, book}} ->
        refute_offending(offending, payload, book, "after")
        assert_fresh(config, seen, payload, book, deltas)
        assert book["bids"] != [] and book["asks"] != []
        [{payload, book}]

      {:bourse_ws, {:order_book_invalidated, _channel, _market, reason}} ->
        flunk("invalidated again before the resync: #{inspect(reason)}")
    after
      left(deadline) -> flunk(timeout.())
    end
  end

  # The book is rebuilt as the provider documents it, through the delta it was
  # published with: drop the deltas the snapshot already contains, require the
  # first one left to bridge the snapshot id, require every later one to follow
  # its predecessor, and stop at the published delta. Deltas after it are not
  # part of that book.
  defp assert_fresh(%{resync: {:rest, rules}}, {:rest, body}, payload, book, deltas) do
    id = body["lastUpdateId"]
    published = payload["u"]
    {through, rest} = Enum.split_while(deltas, &(&1["u"] != published))

    # The chain ends in the frame the venue sent, captured before the adapter
    # saw it; the routed payload must be that frame.
    assert [terminal | _] = rest, "the published delta #{inspect(ids(payload))} was not forwarded by the venue"
    assert payload == terminal, "the routed payload differs from the venue's frame #{inspect(ids(terminal))}"
    chain = Enum.reject(through ++ [terminal], &rules.stale?.(&1, id))

    assert [first | _] = chain
    assert rules.bridges?.(first, id), "REST snapshot #{id} is not bridged by #{inspect(ids(first))}"

    for {prev, next} <- Enum.zip(chain, tl(chain)) do
      assert rules.follows?.(prev, next), "the bridge skips from #{inspect(ids(prev))} to #{inspect(ids(next))}"
    end

    expected =
      Enum.reduce(chain, {levels(body["bids"]), levels(body["asks"])}, fn delta, {bids, asks} ->
        {apply_levels(bids, delta["b"]), apply_levels(asks, delta["a"])}
      end)

    assert book_levels(book) == expected,
           "the first book is not REST snapshot #{id} with its #{length(chain)} bridging deltas"
  end

  defp assert_fresh(%{resync: {:stream, _snapshot_id, payload_id}}, {:snapshot, id, snapshot}, payload, book, _deltas) do
    assert payload_id.(payload) == id,
           "the first book after the resync is not the venue's snapshot #{id}: #{inspect(ids(payload))}"

    assert book_levels(book) ==
             {levels(snapshot["bids"] || snapshot["b"]), levels(snapshot["asks"] || snapshot["a"])},
           "the first book after the resync does not carry snapshot #{id}'s levels"
  end

  defp assert_fresh(_config, seen, payload, _book, _deltas) do
    flunk("a book was published before the resync was observed (#{inspect(seen)}): #{inspect(ids(payload))}")
  end

  defp levels(raw), do: apply_levels(%{}, raw)

  # A published book side lists each price once, best first.
  defp book_levels(book), do: {ordered_levels(book, "bids", :desc), ordered_levels(book, "asks", :asc)}

  defp ordered_levels(book, side, order) do
    prices = Enum.map(book[side], &elem(level(&1), 0))
    sorted = prices |> Enum.uniq() |> Enum.sort(order)
    assert prices == sorted, "#{side} are not unique and ordered #{order}: #{inspect(Enum.take(prices, 10))}"
    levels(book[side])
  end

  defp apply_levels(book, raw) do
    Enum.reduce(raw || [], book, fn lvl, acc ->
      case level(lvl) do
        {price, size} when size == 0 -> Map.delete(acc, price)
        {price, size} -> Map.put(acc, price, size)
      end
    end)
  end

  defp gap_reason?({:expected_first_at_most, _, _}), do: true
  defp gap_reason?({:expected_previous, _, _}), do: true
  defp gap_reason?({:expected_current, _, _}), do: true
  defp gap_reason?(_), do: false

  defp assert_chained(history, config) do
    payloads = history |> Enum.reverse() |> Enum.map(&elem(&1, 0))
    pairs = Enum.zip(payloads, tl(payloads))
    assert length(pairs) >= @chained_books - 2

    # The first published book can come from a snapshot that is not a delta.
    for {prev, next} <- tl(pairs) do
      assert config.chained?.(prev, next), "live deltas did not chain: #{inspect(ids(prev))} -> #{inspect(ids(next))}"
    end
  end

  defp ids(payload), do: Map.take(payload, ~w(U u pu seqId prevSeqId change_id prev_change_id type))

  # -- REST comparison --------------------------------------------------------

  # Only a REST snapshot that no WS frame covers is fetched again: its id fell
  # between frames the test did not keep, so nothing was compared. A snapshot
  # that is aligned and disagrees fails at once. A read takes about 2.5 s; the
  # deadline keeps the loop well inside the module's test timeout. On deribit
  # testnet (2026-11-25) between 1 in 5 and 1 in 2 REST reads landed on a raw
  # frame's own change_id.
  @rest_attempts 40
  @rest_deadline_ms 100_000

  defp compare_with_rest(venue, config, initial) do
    exchange = sandbox(venue)
    deadline = System.monotonic_time(:millisecond) + @rest_deadline_ms

    1..@rest_attempts
    |> Enum.reduce_while({initial, []}, fn _attempt, {history, unaligned} ->
      if System.monotonic_time(:millisecond) > deadline,
        do:
          flunk(
            "no WS frame aligned with a REST snapshot within #{@rest_deadline_ms}ms: #{inspect(Enum.reverse(unaligned))}"
          )

      task = Task.async(fn -> config.rest.(exchange) end)
      history = collect_for(1_000, history, deadline)
      {rest_id, rest_bids, rest_asks} = await_rest(task, deadline)
      history = collect_for(1_500, history, deadline)

      case covering_frame(history, config, rest_id) do
        nil ->
          {:cont, {history, [rest_id | unaligned]}}

        {payload, book} ->
          assert_matches_rest(config, rest_id, {payload, book}, rest_bids, rest_asks)
          {:halt, :ok}
      end
    end)
    |> case do
      :ok ->
        :ok

      {history, unaligned} ->
        ends = history |> Enum.map(&elem(config.range.(elem(&1, 0)) || {nil, nil}, 1)) |> Enum.reject(&is_nil/1)

        flunk(
          "no WS frame covers any REST snapshot id: #{inspect(Enum.reverse(unaligned))}; " <>
            "#{length(history)} WS frames kept, end ids #{inspect(Enum.min(ends, fn -> nil end))}..#{inspect(Enum.max(ends, fn -> nil end))}"
        )
    end
  end

  defp assert_matches_rest(config, rest_id, {payload, book}, rest_bids, rest_asks) do
    {_first, last} = config.range.(payload)
    touched = if rest_id == last, do: MapSet.new(), else: touched_prices(payload)

    _ = book_levels(book)

    mismatch =
      side_mismatch("bids", rest_bids, book["bids"], touched, :desc) ||
        side_mismatch("asks", rest_asks, book["asks"], touched, :asc)

    assert mismatch == nil,
           "REST id #{rest_id}, aligned with WS frame #{inspect(ids(payload))}" <>
             if(rest_id == last, do: " (same state)", else: " (touched prices excluded)") <> ": " <> to_string(mismatch)
  end

  defp covering_frame(history, config, rest_id) do
    end_id_only? = Map.get(config, :rest_alignment) == :end_id

    Enum.find(history, fn {payload, _book} ->
      case config.range.(payload) do
        {_lo, hi} when end_id_only? -> rest_id == hi
        {lo, hi} when is_integer(lo) and is_integer(hi) -> lo < rest_id and rest_id <= hi
        _ -> false
      end
    end)
  end

  # One read waits at most @rest_read_ms, and never past the comparison's
  # deadline; the failure names the bound that ended it.
  @rest_read_ms 15_000

  defp await_rest(task, deadline) do
    wait = min(@rest_read_ms, left(deadline))

    case Task.yield(task, wait) || Task.shutdown(task, :brutal_kill) do
      {:ok, snapshot} ->
        snapshot

      {:exit, reason} ->
        flunk("the REST snapshot read failed: #{inspect(reason)}")

      nil ->
        bound =
          if wait < @rest_read_ms,
            do: "the rest of the #{@rest_deadline_ms}ms comparison deadline",
            else: "the #{@rest_read_ms}ms per-read cap"

        flunk(
          "the REST snapshot read did not answer within #{wait}ms (#{bound}; per-read cap #{@rest_read_ms}ms, " <>
            "comparison deadline #{@rest_deadline_ms}ms)"
        )
    end
  end

  # Collects for `ms`, and never past the comparison's `limit`.
  defp collect_for(ms, acc, limit) do
    deadline = min(System.monotonic_time(:millisecond) + ms, limit)
    do_collect(deadline, acc)
  end

  defp do_collect(deadline, acc) do
    if left(deadline) == 0 do
      acc
    else
      receive do
        {:bourse_ws, {:routed, :watch_order_book, payload, _, _, %{"bids" => _} = book}} ->
          do_collect(deadline, [{payload, book} | acc])

        {:bourse_ws, {:order_book_invalidated, _, _, reason}} ->
          flunk("book invalidated after resync: #{inspect(reason)}")
      after
        left(deadline) -> acc
      end
    end
  end

  defp side_mismatch(side, rest_levels, ws_levels, touched, order) do
    rest = rest_levels |> Enum.take(@compare_levels) |> Map.new(&level/1)
    assert map_size(rest) == @compare_levels

    prices = Map.keys(rest)
    in_range? = if order == :desc, do: &(&1 >= Enum.min(prices)), else: &(&1 <= Enum.max(prices))
    untouched = fn levels -> Map.reject(levels, fn {price, _} -> MapSet.member?(touched, price) end) end

    ws =
      ws_levels |> Enum.map(&level/1) |> Enum.filter(fn {price, _} -> in_range?.(price) end) |> Map.new() |> untouched.()

    rest = untouched.(rest)

    assert map_size(rest) > 0, "#{side}: no REST level outside the frame's touched prices is left to compare"

    if ws != rest do
      "#{side} differ outside the covering frame's touched prices; " <>
        "only in WS: #{inspect(Map.drop(ws, Map.keys(rest)))}, " <>
        "only in REST: #{inspect(Map.drop(rest, Map.keys(ws)))}, " <>
        "size differs: #{inspect(for {p, s} <- rest, Map.has_key?(ws, p), ws[p] != s, do: {p, s, ws[p]})}"
    end
  end

  defp touched_prices(payload) do
    for key <- ~w(b a bids asks), levels = payload[key], is_list(levels), lvl <- levels, into: MapSet.new() do
      lvl |> level() |> elem(0)
    end
  end

  defp level([action, price, size]) when action in ["new", "change", "delete"], do: {num(price), num(size)}
  defp level([price, size | _]), do: {num(price), num(size)}

  defp num(value) when is_number(value), do: value / 1

  defp num(value) when is_binary(value) do
    {number, ""} = Float.parse(value)
    number
  end

  # -- per-venue sequence contracts ------------------------------------------

  def binance_delta?(frame), do: frame["e"] == "depthUpdate"
  def binance_chained?(prev, next), do: next["U"] == prev["u"] + 1
  def binance_range(%{"U" => first, "u" => last}), do: {first - 1, last}
  def binance_range(_), do: nil

  # The venues' documented bridge. Binance spot: drop u <= lastUpdateId; the
  # first event left has U <= lastUpdateId + 1 <= u. USDⓈ-M: drop
  # u < lastUpdateId; the first event left has U <= lastUpdateId <= u.
  def binance_stale?(delta, id), do: delta["u"] <= id
  def binance_bridges?(delta, id), do: delta["U"] <= id + 1 and id + 1 <= delta["u"]
  def usdm_stale?(delta, id), do: delta["u"] < id
  def usdm_bridges?(delta, id), do: delta["U"] <= id and id <= delta["u"]

  def binance_rest(exchange) do
    {:ok, %{status: 200, body: body}} =
      Bourse.Binance.public_get_depth(exchange, %{"symbol" => "BTCUSDT", "limit" => 100})

    {body["lastUpdateId"], body["bids"], body["asks"]}
  end

  def usdm_chained?(prev, next), do: next["pu"] == prev["u"]
  def usdm_range(%{"pu" => previous, "u" => last}), do: {previous, last}
  def usdm_range(_), do: nil

  def usdm_rest(exchange) do
    {:ok, %{status: 200, body: body}} =
      Bourse.Binanceusdm.fapiPublic_get_depth(exchange, %{"symbol" => "BTCUSDT", "limit" => 100})

    {body["lastUpdateId"], body["bids"], body["asks"]}
  end

  # A no-update frame (prevSeqId == seqId) changes nothing; dropping it is not
  # a gap, so only a frame that carries levels is dropped.
  def okx_delta?(%{"action" => "update", "data" => [data]}), do: data["bids"] != [] or data["asks"] != []
  def okx_delta?(_), do: false
  def okx_chained?(prev, next), do: next["prevSeqId"] == prev["seqId"]
  def okx_range(%{"prevSeqId" => previous, "seqId" => current}) when previous >= 0, do: {previous, current}
  def okx_range(_), do: nil

  def okx_rest(exchange) do
    {:ok, %{status: 200, body: %{"data" => [data]}}} =
      Bourse.Okx.public_get_market_books(exchange, %{"instId" => "BTC-USDT", "sz" => "100"})

    {data["seqId"], data["bids"], data["asks"]}
  end

  def deribit_delta?(frame), do: get_in(frame, ["params", "data", "type"]) == "change"
  def deribit_chained?(prev, next), do: next["prev_change_id"] == prev["change_id"]
  def deribit_range(%{"prev_change_id" => previous, "change_id" => current}), do: {previous, current}
  def deribit_range(_), do: nil

  def deribit_rest(exchange) do
    {:ok, %{status: 200, body: %{"result" => result}}} =
      Bourse.Deribit.public_get_get_order_book(exchange, %{"instrument_name" => "BTC-PERPETUAL", "depth" => 100})

    {result["change_id"], result["bids"], result["asks"]}
  end

  def okx_snapshot_id(%{"action" => "snapshot", "data" => [%{"seqId" => id}]}), do: id
  def okx_snapshot_id(_), do: nil
  def okx_payload_id(payload), do: payload["seqId"]
  def okx_payload(%{"data" => [data]}), do: data

  def deribit_snapshot_id(frame) do
    case get_in(frame, ["params", "data"]) do
      %{"type" => "snapshot", "change_id" => id} -> id
      _ -> nil
    end
  end

  def deribit_payload_id(payload), do: payload["change_id"]
  def deribit_payload(frame), do: get_in(frame, ["params", "data"])

  def bybit_delta?(frame), do: frame["type"] == "delta"
  def bybit_chained?(prev, next), do: next["u"] == prev["u"] + 1
  def bybit_range(%{"u" => current}), do: {current - 1, current}
  def bybit_range(_), do: nil
  def bybit_snapshot_id(%{"type" => "snapshot", "data" => %{"u" => id}}), do: id
  def bybit_snapshot_id(_), do: nil
  def bybit_payload_id(payload), do: payload["u"]
  def bybit_payload(frame), do: frame["data"]

  def bybit_rest(exchange) do
    {:ok, %{status: 200, body: %{"retCode" => 0, "result" => result}}} =
      Bourse.Bybit.public_get_v5_market_orderbook(exchange, %{
        "category" => "linear",
        "symbol" => "BTCUSDT",
        "limit" => 200
      })

    {result["u"], result["b"], result["a"]}
  end
end
