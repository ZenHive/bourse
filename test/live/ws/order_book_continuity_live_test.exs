defmodule Bourse.WS.OrderBookContinuityLiveTest do
  @moduledoc """
  Provider-live evidence that incremental order books check continuity
  (task 708).

  Each venue's public diff stream is consumed through `Bourse.WS.Adapter`. The
  test observes real deltas chaining under the venue's documented rule, then
  creates a gap the way a network loses one: a real delta is dropped between
  the socket and the adapter. It asserts that the book is invalidated, that no
  book is published until the resync completes, and that the resynced book
  matches the venue's own REST depth snapshot.

  Every venue runs against its testnet/demo host (`sandbox: true`), measured
  2026-11-25 to serve the same depth frames and sequence fields as production:

    * binance — `wss://stream.testnet.binance.vision/ws`, `U`/`u`, REST `testnet.binance.vision`
    * binanceusdm — `wss://demo-fstream.binance.com/public/ws`, `U`/`u`/`pu`, REST `demo-fapi.binance.com`
    * okx — `wss://wspap.okx.com:8443/ws/v5/public`, `prevSeqId`/`seqId`, REST with `x-simulated-trading: 1`
    * deribit — `wss://test.deribit.com/ws/api/v2`, `type` + `change_id`/`prev_change_id`, REST `test.deribit.com`
    * bybit — `wss://stream-testnet.bybit.com/v5/public/linear`, `u` incrementing by one

  REST snapshot alignment: the REST snapshot carries a sequence id `R`. The WS
  book compared against it is the one published after the frame whose id range
  covers `R`. Prices touched by that frame are excluded because the frame may
  also carry updates past `R`.

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

  @receive_timeout 20_000
  @chained_books 8
  @compare_levels 25

  @venues %{
    "binance" => %{
      channel: "btcusdt@depth@100ms",
      delta?: &__MODULE__.binance_delta?/1,
      chained?: &__MODULE__.binance_chained?/2,
      range: &__MODULE__.binance_range/1,
      rest: &__MODULE__.binance_rest/1
    },
    "binanceusdm" => %{
      channel: "btcusdt@depth@100ms",
      delta?: &__MODULE__.binance_delta?/1,
      chained?: &__MODULE__.usdm_chained?/2,
      range: &__MODULE__.usdm_range/1,
      rest: &__MODULE__.usdm_rest/1
    },
    "okx" => %{
      channel: %{"channel" => "books", "instId" => "BTC-USDT"},
      delta?: &__MODULE__.okx_delta?/1,
      chained?: &__MODULE__.okx_chained?/2,
      range: &__MODULE__.okx_range/1,
      rest: &__MODULE__.okx_rest/1
    },
    "deribit" => %{
      channel: "book.BTC-PERPETUAL.100ms",
      delta?: &__MODULE__.deribit_delta?/1,
      chained?: &__MODULE__.deribit_chained?/2,
      range: &__MODULE__.deribit_range/1,
      rest: &__MODULE__.deribit_rest/1
    },
    "bybit" => %{
      channel: "orderbook.50.BTCUSDT",
      delta?: &__MODULE__.bybit_delta?/1,
      chained?: &__MODULE__.bybit_chained?/2,
      range: nil,
      rest: nil
    }
  }

  for venue <- ~w(binance binanceusdm okx deribit bybit) do
    describe "#{venue}" do
      @tag venue: venue
      test "chains real deltas, invalidates on a dropped delta, and resyncs", %{venue: venue} do
        config = Map.fetch!(@venues, venue)
        {adapter, drop} = start(venue, config)

        history = await_books(@chained_books, [])
        assert_chained(history, config)

        :atomics.put(drop, 1, 1)
        assert_receive {:dropped_delta, _frame}, @receive_timeout

        reason = await_invalidation()
        assert gap_reason?(reason), "expected a continuity gap, got #{inspect(reason)}"

        # After the invalidation no book is published until the resync is done.
        [{_payload, resynced} | _] = after_resync = await_books(1, [])
        assert resynced["bids"] != [] and resynced["asks"] != []

        if config.rest do
          compare_with_rest(venue, config, after_resync)
        else
          # bybit's REST depth carries a different update id than the WS
          # level-50 stream, so it cannot be aligned to a WS frame. The resync
          # is proved by the book chaining again after the fresh snapshot.
          assert_chained(await_books(@chained_books, []), config)
        end

        GenServer.stop(adapter)
      end

      @tag venue: venue
      test "after a reconnect the first book comes from a fresh snapshot", %{venue: venue} do
        config = Map.fetch!(@venues, venue)
        {adapter, _drop} = start(venue, config)
        _history = await_books(3, [])

        send(adapter, :connect)
        discard_until_connected()

        [{payload, book} | _] = first = await_books(1, [])
        assert book["bids"] != [] and book["asks"] != []

        assert_fresh_snapshot(venue, config, payload, first)

        GenServer.stop(adapter)
      end
    end
  end

  # -- setup ------------------------------------------------------------------

  defp sandbox(venue), do: Exchange.new!(venue, sandbox: true)

  defp start(venue, config) do
    test_pid = self()
    drop = :atomics.new(1, [])
    Broadcast.subscribe(Broadcast.topic(venue, :watch_order_book, nil))

    connect_fun = fn exchange, section, opts ->
      filtered = dropping_handler(Keyword.fetch!(opts, :handler), config, drop, test_pid)

      with {:ok, ws} <- WS.connect(exchange, section, Keyword.put(opts, :handler, filtered)) do
        send(test_pid, {:connected, ws})
        {:ok, ws}
      end
    end

    {:ok, adapter} = Adapter.start_link(sandbox(venue), :public, connect_fun: connect_fun)
    assert_receive {:connected, _ws}, @receive_timeout
    assert :ok = Adapter.subscribe(adapter, [config.channel])
    {adapter, drop}
  end

  # Sits between the socket and the adapter. While `drop` is armed, the next
  # real delta is taken out of the stream — the gap a lost frame leaves.
  defp dropping_handler(handler, config, drop, test_pid) do
    fn
      {:message, data} = message ->
        if is_map(data) and config.delta?.(data) and :atomics.compare_exchange(drop, 1, 1, 0) == :ok do
          send(test_pid, {:dropped_delta, data})
        else
          handler.(message)
        end

      message ->
        handler.(message)
    end
  end

  # -- observation ------------------------------------------------------------

  # Collects `count` routed frames that carry a book, newest first. A routed
  # frame with a nil book is a frame received while no valid book exists.
  defp await_books(0, acc), do: acc

  defp await_books(count, acc) do
    receive do
      {:bourse_ws, {:routed, :watch_order_book, payload, _channel, _market, %{"bids" => _} = book}} ->
        await_books(count - 1, [{payload, book} | acc])

      {:bourse_ws, {:routed, :watch_order_book, _payload, _channel, _market, nil}} ->
        await_books(count, acc)

      {:bourse_ws, {:order_book_invalidated, _channel, _market, reason}} ->
        flunk("book invalidated while chaining live deltas: #{inspect(reason)}")
    after
      @receive_timeout -> flunk("no order book within #{@receive_timeout}ms (#{count} still expected)")
    end
  end

  # Routed books that were already queued when the dropped delta was taken
  # out are valid; anything carrying a book after the invalidation is not.
  defp await_invalidation do
    receive do
      {:bourse_ws, {:order_book_invalidated, _channel, _market, reason}} -> reason
      {:bourse_ws, {:routed, :watch_order_book, _, _, _, _}} -> await_invalidation()
    after
      @receive_timeout -> flunk("a dropped delta did not invalidate the book")
    end
  end

  # Books routed before the new connection was adopted were built on the old
  # one. The adapter sends `{:connected, ws}` while it adopts the new
  # connection, so everything ahead of it in the mailbox is older.
  defp discard_until_connected do
    receive do
      {:connected, _ws} -> :ok
      {:bourse_ws, {:routed, :watch_order_book, _, _, _, _}} -> discard_until_connected()
    after
      @receive_timeout -> flunk("the adapter did not reconnect")
    end
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

  defp ids(payload), do: Map.take(payload, ~w(U u pu seqId prevSeqId change_id prev_change_id))

  # A REST-bootstrapped book is published on the first delta after its REST
  # snapshot; it is checked against a fresh REST snapshot.
  defp assert_fresh_snapshot(venue, config, _payload, first) when venue in ~w(binance binanceusdm),
    do: compare_with_rest(venue, config, first)

  # Stream venues: the first book must be the snapshot the venue sends on
  # subscribe, not a delta continued from the old connection.
  defp assert_fresh_snapshot("okx", _config, payload, _first),
    do: assert(payload["prevSeqId"] == -1, inspect(ids(payload)))

  defp assert_fresh_snapshot("deribit", _config, payload, _first),
    do: assert(payload["type"] == "snapshot", inspect(ids(payload)))

  # bybit puts `type` on the frame, not the payload; its level-50 snapshot
  # carries 50 levels per side, a delta only the changed ones.
  defp assert_fresh_snapshot("bybit", _config, payload, _first),
    do: assert(length(payload["b"]) == 50 and length(payload["a"]) == 50, inspect(ids(payload)))

  # -- REST comparison --------------------------------------------------------

  # A REST snapshot is a separate request to a separate service, and one
  # observed okx REST snapshot carried a level its own seqId did not account
  # for (2026-11-25). A WS book that is wrong stays wrong against every later
  # snapshot, so up to three snapshots are compared and every mismatch is
  # reported when none of them agrees.
  @rest_attempts 3

  defp compare_with_rest(venue, config, initial) do
    exchange = sandbox(venue)

    1..@rest_attempts
    |> Enum.reduce_while({initial, []}, fn _attempt, {history, mismatches} ->
      Process.sleep(1_000)
      task = Task.async(fn -> config.rest.(exchange) end)
      history = collect_for(3_000, history)
      {rest_id, rest_bids, rest_asks} = Task.await(task, 15_000)
      history = collect_for(4_000, history)

      case rest_mismatch(history, config, rest_id, rest_bids, rest_asks) do
        nil -> {:halt, :ok}
        mismatch -> {:cont, {history, ["REST id #{rest_id}: " <> mismatch | mismatches]}}
      end
    end)
    |> case do
      :ok -> :ok
      {_history, mismatches} -> flunk(Enum.join(Enum.reverse(mismatches), "\n"))
    end
  end

  defp rest_mismatch(history, config, rest_id, rest_bids, rest_asks) do
    case covering_frame(history, config, rest_id) do
      nil ->
        "no WS frame covers it"

      {payload, book} ->
        touched = touched_prices(payload)

        side_mismatch("bids", rest_bids, book["bids"], touched, :desc) ||
          side_mismatch("asks", rest_asks, book["asks"], touched, :asc)
    end
  end

  defp covering_frame(history, config, rest_id) do
    Enum.find(history, fn {payload, _book} ->
      case config.range.(payload) do
        {lo, hi} when is_integer(lo) and is_integer(hi) -> lo < rest_id and rest_id <= hi
        _ -> false
      end
    end)
  end

  defp collect_for(ms, acc) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_collect(deadline, acc)
  end

  defp do_collect(deadline, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:bourse_ws, {:routed, :watch_order_book, payload, _, _, %{"bids" => _} = book}} ->
        do_collect(deadline, [{payload, book} | acc])

      {:bourse_ws, {:order_book_invalidated, _, _, reason}} ->
        flunk("book invalidated after resync: #{inspect(reason)}")
    after
      left -> acc
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

  def bybit_delta?(frame), do: frame["type"] == "delta"
  def bybit_chained?(prev, next), do: next["u"] == prev["u"] + 1
end
