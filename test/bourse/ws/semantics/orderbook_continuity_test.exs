defmodule Bourse.WS.Semantics.OrderbookContinuityTest do
  @moduledoc """
  Continuity state machine for incremental order books.

  Frames here are synthetic: they assert our book maintenance against each
  venue's authored rule. Their shapes follow frames captured live from each
  venue's public stream (see `test/live/ws/order_book_continuity_live_test.exs`
  for the provider-live counterpart).
  """

  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Spec
  alias Bourse.Spec.Schema
  alias Bourse.WS.Semantics.Orderbook

  defp state(venue), do: Orderbook.new(Exchange.new!(venue))

  defp spot_delta(first, last, bids \\ [], asks \\ []) do
    %{"e" => "depthUpdate", "s" => "BTCUSDT", "U" => first, "u" => last, "b" => bids, "a" => asks}
  end

  defp usdm_delta(first, last, previous, bids \\ []) do
    %{"e" => "depthUpdate", "s" => "BTCUSDT", "U" => first, "u" => last, "pu" => previous, "b" => bids, "a" => []}
  end

  defp bootstrap(state, key, frames, rest_body) do
    {state, outcomes} =
      Enum.reduce(frames, {state, []}, fn frame, {st, acc} ->
        {st, outcome} = Orderbook.apply(st, key, frame, frame)
        {st, [outcome | acc]}
      end)

    ref = make_ref()
    state = Orderbook.fetch_started(state, key, ref)
    {state, result} = Orderbook.apply_rest_snapshot(state, key, ref, rest_body)
    {state, Enum.reverse(outcomes), result}
  end

  describe "binance spot (first_follows_last, REST bootstrap)" do
    test "a snapshot answered after the buffered deltas were lost waits for a delta that bridges it" do
      st = state("binance")
      assert {st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", spot_delta(100, 105, [["101", "1"]]))
      ref = make_ref()
      st = Orderbook.fetch_started(st, "BTCUSDT", ref)

      unsequenced = Map.delete(spot_delta(106, 0), "u")
      assert {st, {:invalidated, _}} = Orderbook.apply(st, "BTCUSDT", unsequenced, unsequenced)

      body = %{"lastUpdateId" => 90, "bids" => [["90", "7"]], "asks" => [["95", "2"]]}
      assert {st, :pending} = Orderbook.apply_rest_snapshot(st, "BTCUSDT", ref, body)
      refute Orderbook.live?(st, "BTCUSDT")

      # A delta the snapshot already contains publishes nothing.
      assert {st, :pending} = Orderbook.apply(st, "BTCUSDT", spot_delta(89, 90, [["13", "1"]]))
      # The next delta starts past the snapshot: it is fetched again.
      assert {st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", spot_delta(107, 110))
      refute Orderbook.live?(st, "BTCUSDT")
    end

    test "a snapshot whose bridging delta arrives after it goes live on that delta" do
      st = state("binance")
      assert {st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", spot_delta(1, 5))
      ref = make_ref()
      st = Orderbook.fetch_started(st, "BTCUSDT", ref)

      assert {st, :pending} =
               Orderbook.apply_rest_snapshot(st, "BTCUSDT", ref, %{
                 "lastUpdateId" => 10,
                 "bids" => [["9", "1"]],
                 "asks" => []
               })

      assert {st, {:book, %{"bids" => [["9", "1"], ["8", "2"]]}}} =
               Orderbook.apply(st, "BTCUSDT", spot_delta(9, 12, [["8", "2"]]))

      assert Orderbook.live?(st, "BTCUSDT")
    end

    test "buffers deltas until the REST snapshot, drops those it covers, and chains U == u + 1" do
      st = state("binance")
      assert Orderbook.key(st, spot_delta(1, 2), "depthUpdate", nil) == "BTCUSDT"

      frames = [
        spot_delta(98, 100, [["10", "1"]]),
        spot_delta(101, 105, [["11", "2"]]),
        spot_delta(106, 108, [["12", "3"]])
      ]

      rest = %{"lastUpdateId" => 103, "bids" => [["9", "5"], ["10", "1"]], "asks" => [["20", "1"]]}

      {st, outcomes, result} = bootstrap(st, "BTCUSDT", frames, rest)
      assert outcomes == [{:fetch_snapshot, "BTCUSDT"}, :pending, :pending]

      # 98..100 predates the snapshot and is dropped; 101..105 spans 104; 106..108 follows.
      assert {:book, %{"bids" => [["12", "3"], ["11", "2"], ["10", "1"], ["9", "5"]], "asks" => [["20", "1"]]}} =
               result

      assert {_st, {:book, book}} = Orderbook.apply(st, "BTCUSDT", spot_delta(109, 110, [["9", "0.00000000"]]))
      assert book["bids"] == [["12", "3"], ["11", "2"], ["10", "1"]]
    end

    test "refetches when the snapshot is older than the first buffered event" do
      {_st, _outcomes, result} =
        bootstrap(state("binance"), "BTCUSDT", [spot_delta(200, 205)], %{
          "lastUpdateId" => 150,
          "bids" => [],
          "asks" => []
        })

      assert result == {:fetch_snapshot, "BTCUSDT"}
    end

    test "a skipped update invalidates the book and keeps the breaking delta for the next snapshot" do
      {st, _outcomes, {:book, _}} =
        bootstrap(state("binance"), "BTCUSDT", [spot_delta(10, 12)], %{"lastUpdateId" => 11, "bids" => [], "asks" => []})

      assert {st, {:invalidated, {:expected_first_at_most, 13, 20}}} =
               Orderbook.apply(st, "BTCUSDT", spot_delta(20, 25, [["1", "1"]]))

      assert Orderbook.resync_action(st, "BTCUSDT") == {:rest_snapshot, "BTCUSDT"}
      assert {st, :pending} = Orderbook.apply(st, "BTCUSDT", spot_delta(26, 27))

      ref = make_ref()
      st = Orderbook.fetch_started(st, "BTCUSDT", ref)

      assert {_st, {:book, book}} =
               Orderbook.apply_rest_snapshot(st, "BTCUSDT", ref, %{"lastUpdateId" => 22, "bids" => [], "asks" => []})

      assert book["bids"] == [["1", "1"]]
    end

    test "an event already covered by the book is dropped, not merged" do
      {st, _outcomes, {:book, before}} =
        bootstrap(state("binance"), "BTCUSDT", [spot_delta(10, 12)], %{
          "lastUpdateId" => 11,
          "bids" => [["5", "1"]],
          "asks" => []
        })

      assert {_st, {:book, ^before}} = Orderbook.apply(st, "BTCUSDT", spot_delta(9, 12, [["5", "0"]]))
    end

    test "a snapshot result that is not the fetch in flight is ignored" do
      st = state("binance")
      {st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", spot_delta(1, 2))
      st = Orderbook.fetch_started(st, "BTCUSDT", make_ref())

      assert {^st, :pending} = Orderbook.apply_rest_snapshot(st, "BTCUSDT", make_ref(), %{"lastUpdateId" => 1})
    end

    test "a partial-depth frame is a snapshot keyed by the one partial stream subscribed" do
      frame = %{"lastUpdateId" => 5, "bids" => [["1", "2"]], "asks" => [["3", "4"]]}
      st = Orderbook.track_subscriptions(state("binance"), ["btcusdt@depth20@100ms"])

      key = Orderbook.key(st, frame, "depthUpdate", nil)
      assert key == "btcusdt@depth20@100ms"
      assert Orderbook.market(st, frame) == "BTCUSDT"
      assert Orderbook.resync_action(st, key) == :none

      assert {st, {:book, %{"bids" => [["1", "2"]], "asks" => [["3", "4"]]}}} = Orderbook.apply(st, key, frame, frame)
      assert st.books[key].id == 5
    end

    test "two partial streams on one socket are reported unavailable, not merged under one identity" do
      btc = %{"lastUpdateId" => 5, "bids" => [["59566", "1"]], "asks" => []}
      eth = %{"lastUpdateId" => 9, "bids" => [["1670", "1"]], "asks" => []}
      st = Orderbook.track_subscriptions(state("binance"), ["btcusdt@depth20@100ms", "ethusdt@depth20@100ms"])

      key = Orderbook.key(st, btc, "depthUpdate", nil)
      assert key == Orderbook.key(st, eth, "depthUpdate", nil)
      assert Orderbook.market(st, btc) == nil

      assert {st, {:unavailable, :ambiguous_depth_streams}} = Orderbook.apply(st, key, btc, btc)
      assert {_st, :pending} = Orderbook.apply(st, key, eth, eth)
    end

    test "a partial stream and the diff stream of one market are kept apart" do
      partial = %{"lastUpdateId" => 5, "bids" => [["1", "2"]], "asks" => []}
      st = Orderbook.track_subscriptions(state("binance"), ["btcusdt@depth20", "btcusdt@depth@100ms"])

      assert Orderbook.key(st, partial, "depthUpdate", nil) == "btcusdt@depth20"
      assert Orderbook.key(st, spot_delta(1, 2), "depthUpdate", nil) == "BTCUSDT"
      assert {_st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", spot_delta(1, 2), spot_delta(1, 2))
    end

    test "a delta without its last update id is rejected, not taken for a partial snapshot" do
      {st, _outcomes, {:book, before}} =
        bootstrap(state("binance"), "BTCUSDT", [spot_delta(10, 11, [["90", "4"]])], %{
          "lastUpdateId" => 10,
          "bids" => [["80", "5"]],
          "asks" => [["100", "2"]]
        })

      unsequenced = Map.delete(spot_delta(12, 0, [["95", "1"]]), "u")

      assert {st, {:invalidated, {:missing_sequence, %{"first" => "U", "last" => "u"}}}} =
               Orderbook.apply(st, "BTCUSDT", unsequenced, unsequenced)

      # The unchecked delta is not kept for the next snapshot either.
      ref = make_ref()
      st = Orderbook.fetch_started(st, "BTCUSDT", ref)

      assert {st, :pending} =
               Orderbook.apply_rest_snapshot(st, "BTCUSDT", ref, %{"lastUpdateId" => 11, "bids" => [], "asks" => []})

      assert {_st, {:book, %{"bids" => bids}}} = Orderbook.apply(st, "BTCUSDT", spot_delta(12, 13), spot_delta(12, 13))
      assert bids == []
      assert before["bids"] == [["90", "4"], ["80", "5"]]
    end

    test "a partial snapshot is recognised by its shape, and only while a partial stream is subscribed" do
      partial = %{"lastUpdateId" => 5, "bids" => [["1", "2"]], "asks" => [["3", "4"]]}
      tracked = Orderbook.track_subscriptions(state("binance"), ["btcusdt@depth5"])
      {st, {:book, _}} = Orderbook.apply(tracked, "btcusdt@depth5", partial, partial)
      assert st.books["btcusdt@depth5"].id == 5

      # Without a partial subscription the same shape is an unsequenced delta.
      assert {_st, {:invalidated, {:missing_sequence, _}}} =
               Orderbook.apply(state("binance"), "BTCUSDT", partial, partial)

      # bids/asks alone, or a frame that also carries event fields, is not one.
      for frame <- [%{"bids" => [], "asks" => []}, Map.put(partial, "U", 6)] do
        assert {_st, {:invalidated, {:missing_sequence, _}}} = Orderbook.apply(tracked, "BTCUSDT", frame, frame)
      end
    end

    test "a REST snapshot missing either side is not installed, even at a current id" do
      for body <- [
            %{"lastUpdateId" => 10},
            %{"lastUpdateId" => 10, "bids" => []},
            %{"lastUpdateId" => 10, "bids" => [], "asks" => "x"}
          ] do
        {st, _outcomes, result} = bootstrap(state("binance"), "BTCUSDT", [spot_delta(10, 11)], body)
        assert result == {:fetch_snapshot, "BTCUSDT"}
        assert Orderbook.needs_fetch?(st, "BTCUSDT")
        assert {_st, :pending} = Orderbook.apply(st, "BTCUSDT", spot_delta(12, 12, [["9", "1"]]))
      end
    end

    test "malformed deltas while a snapshot is in flight keep that one request" do
      {st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(state("binance"), "BTCUSDT", spot_delta(100, 105))
      ref = make_ref()
      st = Orderbook.fetch_started(st, "BTCUSDT", ref)
      malformed = Map.delete(spot_delta(106, 107), "u")

      st =
        Enum.reduce(1..12, st, fn _, st ->
          {st, {:invalidated, {:missing_sequence, _}}} = Orderbook.apply(st, "BTCUSDT", malformed, malformed)
          refute Orderbook.needs_fetch?(st, "BTCUSDT")
          assert Orderbook.fetch_in_flight?(st, "BTCUSDT", ref)
          st
        end)

      # The snapshot that was in flight is reconciled against what followed the
      # malformed delta; the skipped range shows up as a gap, not a merge.
      {st, :pending} = Orderbook.apply(st, "BTCUSDT", spot_delta(110, 111))

      assert {_st, {:fetch_snapshot, "BTCUSDT"}} =
               Orderbook.apply_rest_snapshot(st, "BTCUSDT", ref, %{"lastUpdateId" => 105, "bids" => [], "asks" => []})
    end

    test "the REST snapshot request is the authored depth call" do
      assert Orderbook.rest_snapshot_request(state("binance"), "BTCUSDT") ==
               {:public_get_depth, %{"limit" => 1000, "symbol" => "BTCUSDT"}}
    end
  end

  describe "binance USDⓈ-M (previous_last, REST bootstrap)" do
    test "the first event must span the snapshot id, then pu must equal the previous u" do
      frames = [usdm_delta(90, 100, 89), usdm_delta(101, 120, 100, [["7", "1"]])]

      {st, _outcomes, {:book, book}} =
        bootstrap(state("binanceusdm"), "BTCUSDT", frames, %{"lastUpdateId" => 110, "bids" => [], "asks" => []})

      assert book["bids"] == [["7", "1"]]
      assert {st, {:book, _}} = Orderbook.apply(st, "BTCUSDT", usdm_delta(121, 130, 120))

      assert {_st, {:invalidated, {:expected_previous, 130, 135}}} =
               Orderbook.apply(st, "BTCUSDT", usdm_delta(140, 150, 135))
    end

    test "a first event that starts after the snapshot id cannot bridge it" do
      st = state("binanceusdm")

      {st, _o, :pending} =
        bootstrap(st, "BTCUSDT", [usdm_delta(1, 5, 0)], %{"lastUpdateId" => 50, "bids" => [], "asks" => []})

      # The snapshot is fetched again; nothing was published from it.
      assert {st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", usdm_delta(60, 70, 59))
      assert Orderbook.needs_fetch?(st, "BTCUSDT")
    end

    test "partial-depth subscriptions replace the book; mixing them with a diff stream is refused" do
      st = Orderbook.track_subscriptions(state("binanceusdm"), ["btcusdt@depth20@100ms"])
      frame = usdm_delta(1, 2, 0, [["5", "1"]])

      assert {st, {:book, %{"bids" => [["5", "1"]]}}} = Orderbook.apply(st, "BTCUSDT", frame, frame)
      assert {_st, {:book, %{"bids" => [["6", "1"]]}}} = Orderbook.apply(st, "BTCUSDT", %{frame | "b" => [["6", "1"]]})

      st = Orderbook.track_subscriptions(st, ["btcusdt@depth@100ms"])
      assert {st, {:unavailable, :ambiguous_depth_streams}} = Orderbook.apply(st, "BTCUSDT", frame, frame)
      assert {_st, :pending} = Orderbook.apply(st, "BTCUSDT", frame, frame)
    end

    # The raw /ws endpoint carries no stream name, so two speeds of one diff
    # stream (or two partial depths) deliver frames that cannot be told apart.
    test "two diff speeds or two partial depths of one market are reported unavailable once" do
      frame = usdm_delta(1, 2, 0, [["5", "1"]])

      for channels <- [
            ["btcusdt@depth@100ms", "btcusdt@depth@500ms"],
            ["btcusdt@depth5@100ms", "btcusdt@depth10@100ms"]
          ] do
        st = Orderbook.track_subscriptions(state("binanceusdm"), channels)
        assert {st, {:unavailable, :ambiguous_depth_streams}} = Orderbook.apply(st, "BTCUSDT", frame, frame)
        assert {_st, :pending} = Orderbook.apply(st, "BTCUSDT", %{frame | "pu" => 2, "U" => 3, "u" => 4})
      end

      # One stream per market stays maintained; another market is unaffected.
      st = Orderbook.track_subscriptions(state("binanceusdm"), ["btcusdt@depth@100ms", "ethusdt@depth@500ms"])
      assert {_st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", frame, frame)
    end

    test "a delta without pu is rejected instead of chained" do
      {st, _o, {:book, _}} =
        bootstrap(state("binanceusdm"), "BTCUSDT", [usdm_delta(1, 5, 0)], %{
          "lastUpdateId" => 3,
          "bids" => [],
          "asks" => []
        })

      frame = 6 |> usdm_delta(7, 5) |> Map.delete("pu")
      assert {_st, {:invalidated, {:missing_sequence, _}}} = Orderbook.apply(st, "BTCUSDT", frame, frame)
    end
  end

  describe "okx (previous_current, stream snapshot)" do
    defp okx(action, previous, current, bids \\ []) do
      %{
        "action" => action,
        "arg" => %{"channel" => "books", "instId" => "BTC-USDT"},
        "data" => [%{"asks" => [], "bids" => bids, "prevSeqId" => previous, "seqId" => current, "checksum" => 0}]
      }
    end

    defp apply_okx(st, frame) do
      [payload] = frame["data"]
      Orderbook.apply(st, Orderbook.key(st, frame, "books", nil), payload, frame)
    end

    test "chains prevSeqId to the previous seqId, including no-update and reset frames" do
      st = state("okx")
      key = Orderbook.key(st, okx("snapshot", -1, 1), "books", nil)
      assert key == %{"channel" => "books", "instId" => "BTC-USDT"}
      assert Orderbook.resync_action(st, key) == {:resubscribe, key}

      {st, :pending} = apply_okx(st, okx("update", 5, 6))
      {st, {:book, _}} = apply_okx(st, okx("snapshot", -1, 10, [["100", "1", "0", "1"]]))
      {st, {:book, _}} = apply_okx(st, okx("update", 10, 15, [["101", "2", "0", "1"]]))
      {st, {:book, _}} = apply_okx(st, okx("update", 15, 15))
      {st, {:book, book}} = apply_okx(st, okx("update", 15, 3, [["100", "0", "0", "0"]]))
      assert book["bids"] == [["101", "2"]]

      assert {st, {:invalidated, {:expected_previous, 3, 9}}} = apply_okx(st, okx("update", 9, 12))
      assert {_st, :pending} = apply_okx(st, okx("update", 12, 13))
    end

    test "a delta whose seqId is missing is not merged, even when prevSeqId matches" do
      {st, {:book, before}} = apply_okx(state("okx"), okx("snapshot", -1, 10, [["100", "1", "0", "1"]]))
      frame = update_in(okx("update", 10, 0, [["99", "1", "0", "1"]]), ["data"], fn [d] -> [Map.delete(d, "seqId")] end)

      assert {st, {:invalidated, {:missing_sequence, %{"current" => "seqId", "previous" => "prevSeqId"}}}} =
               apply_okx(st, frame)

      assert before["bids"] == [["100", "1"]]
      assert {_st, :pending} = apply_okx(st, okx("update", 10, 11))
    end

    test "a snapshot without its seqId is not published" do
      frame = update_in(okx("snapshot", -1, 0, [["1", "1", "0", "1"]]), ["data"], fn [d] -> [Map.delete(d, "seqId")] end)
      assert {_st, {:invalidated, {:missing_sequence, "seqId"}}} = apply_okx(state("okx"), frame)
    end

    test "the instrument comes from the authored market path, per frame" do
      st = state("okx")
      eth = put_in(okx("update", 1, 2), ["arg", "instId"], "ETH-USDT")
      assert Orderbook.market(st, okx("update", 1, 2)) == "BTC-USDT"
      assert Orderbook.market(st, eth) == "ETH-USDT"
      assert Orderbook.market(st, %{"arg" => %{}}) == nil
    end

    test "an update without action on the incremental books channel invalidates instead of replacing the book" do
      {st, {:book, _}} = apply_okx(state("okx"), okx("snapshot", -1, 10, [["100", "1", "0", "1"]]))
      unmarked = Map.delete(okx("update", -666, 11, [["1", "1", "0", "1"]]), "action")

      assert {st, {:invalidated, {:unmarked_frame, "action"}}} = apply_okx(st, unmarked)
      assert {st, :pending} = apply_okx(st, okx("update", 11, 12))

      assert {_st, {:invalidated, {:unknown_frame_type, "action", "partial"}}} =
               apply_okx(elem(apply_okx(st, okx("snapshot", -1, 20)), 0), okx("partial", 20, 21))
    end

    test "a frame without action (books5) is a self-contained snapshot" do
      frame = %{
        "arg" => %{"channel" => "books5", "instId" => "BTC-USDT"},
        "data" => [%{"bids" => [["1", "1", "0", "1"]], "asks" => [], "seqId" => 4}]
      }

      assert {_st, {:book, %{"bids" => [["1", "1"]]}}} = apply_okx(state("okx"), frame)
    end
  end

  describe "deribit (previous_current, stream snapshot)" do
    defp deribit(type, change_id, previous, bids) do
      data = %{
        "type" => type,
        "change_id" => change_id,
        "instrument_name" => "BTC-PERPETUAL",
        "bids" => bids,
        "asks" => []
      }

      data = if previous, do: Map.put(data, "prev_change_id", previous), else: data
      %{"params" => %{"channel" => "book.BTC-PERPETUAL.100ms", "data" => data}}
    end

    defp apply_deribit(st, frame) do
      Orderbook.apply(
        st,
        Orderbook.key(st, frame, "book.BTC-PERPETUAL.100ms", "BTC-PERPETUAL"),
        frame["params"]["data"],
        frame
      )
    end

    test "applies [action, price, amount] levels and chains prev_change_id" do
      st = state("deribit")
      {st, {:book, _}} = apply_deribit(st, deribit("snapshot", 100, nil, [["new", 10.0, 5.0], ["new", 9.5, 1.0]]))
      {st, {:book, book}} = apply_deribit(st, deribit("change", 101, 100, [["change", 10.0, 7.0], ["delete", 9.5, 0.0]]))
      assert book["bids"] == [[10.0, 7.0]]

      assert {_st, {:invalidated, {:expected_previous, 101, 150}}} =
               apply_deribit(st, deribit("change", 151, 150, [["new", 8.0, 1.0]]))
    end

    test "a change without change_id is not merged" do
      {st, {:book, _}} = apply_deribit(state("deribit"), deribit("snapshot", 100, nil, [["new", 10.0, 5.0]]))
      frame = update_in(deribit("change", 0, 100, [["new", 9.0, 1.0]]), ["params", "data"], &Map.delete(&1, "change_id"))
      assert {_st, {:invalidated, {:missing_sequence, _}}} = apply_deribit(st, frame)
    end

    test "a change without type on the incremental channel invalidates instead of replacing the book" do
      {st, {:book, _}} = apply_deribit(state("deribit"), deribit("snapshot", 100, nil, [["new", 10.0, 5.0]]))

      sentinel =
        update_in(deribit("change", 101, 7, [["new", 99_999.0, 1.0]]), ["params", "data"], &Map.delete(&1, "type"))

      assert {_st, {:invalidated, {:unmarked_frame, "params.data.type"}}} = apply_deribit(st, sentinel)
    end

    test "a grouped-book frame without type is a self-contained snapshot" do
      frame = %{
        "params" => %{
          "channel" => "book.BTC-PERPETUAL.none.10.100ms",
          "data" => %{"change_id" => 1, "bids" => [[1.0, 2.0]], "asks" => []}
        }
      }

      assert {_st, {:book, %{"bids" => [[1.0, 2.0]]}}} = apply_deribit(state("deribit"), frame)
    end
  end

  describe "bybit (increment, stream snapshot)" do
    defp bybit(type, u, bids) do
      %{
        "topic" => "orderbook.50.BTCUSDT",
        "type" => type,
        "data" => %{"s" => "BTCUSDT", "u" => u, "b" => bids, "a" => []}
      }
    end

    defp apply_bybit(st, frame),
      do: Orderbook.apply(st, Orderbook.key(st, frame, frame["topic"], "BTCUSDT"), frame["data"], frame)

    test "u must advance by one; a new snapshot resets the book" do
      st = state("bybit")
      {st, {:book, _}} = apply_bybit(st, bybit("snapshot", 7, [["1", "1"]]))
      {st, {:book, _}} = apply_bybit(st, bybit("delta", 8, [["2", "1"]]))
      assert {_gap, {:invalidated, {:expected_current, 9, 10}}} = apply_bybit(st, bybit("delta", 10, []))

      assert {_st, {:book, %{"bids" => [["3", "1"]]}}} = apply_bybit(st, bybit("snapshot", 1, [["3", "1"]]))
    end

    test "a delta without u is not merged" do
      {st, {:book, _}} = apply_bybit(state("bybit"), bybit("snapshot", 7, [["1", "1"]]))
      frame = update_in(bybit("delta", 0, [["2", "1"]]), ["data"], &Map.delete(&1, "u"))
      assert {_st, {:invalidated, {:missing_sequence, %{"current" => "u"}}}} = apply_bybit(st, frame)
    end
  end

  test "reset discards every book so the next one comes from a fresh snapshot" do
    st = state("bybit")
    {st, {:book, _}} = apply_bybit(st, bybit("snapshot", 7, []))
    st = Orderbook.reset(st)
    assert {_st, :pending} = apply_bybit(st, bybit("delta", 8, []))

    {st, _o, {:book, _}} =
      bootstrap(state("binance"), "BTCUSDT", [spot_delta(1, 2)], %{"lastUpdateId" => 1, "bids" => [], "asks" => []})

    st = Orderbook.reset(st)
    assert {_st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", spot_delta(3, 4))
  end

  describe "REST snapshot retries" do
    test "an unusable snapshot reserves one paced retry, doubling per failure" do
      st = state("binance")
      {st, {:fetch_snapshot, "BTCUSDT"}} = Orderbook.apply(st, "BTCUSDT", spot_delta(100, 105))
      assert Orderbook.needs_fetch?(st, "BTCUSDT")

      delays =
        1..7
        |> Enum.map_reduce(st, fn _attempt, st ->
          ref = make_ref()
          st = Orderbook.fetch_started(st, "BTCUSDT", ref)
          refute Orderbook.needs_fetch?(st, "BTCUSDT")
          {st, {:fetch_snapshot, _}} = Orderbook.apply_rest_snapshot(st, "BTCUSDT", ref, %{"lastUpdateId" => 9})
          token = make_ref()
          {st, delay} = Orderbook.fetch_retry(st, "BTCUSDT", token)
          assert Orderbook.fetch_in_flight?(st, "BTCUSDT", token)
          {delay, st}
        end)
        |> elem(0)

      assert delays == [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]
    end

    test "a reset drops the reserved retry" do
      {st, {:fetch_snapshot, _}} = Orderbook.apply(state("binance"), "BTCUSDT", spot_delta(100, 105))
      token = make_ref()
      {st, 1_000} = Orderbook.fetch_retry(st, "BTCUSDT", token)
      refute Orderbook.fetch_in_flight?(Orderbook.reset(st), "BTCUSDT", token)
      assert Orderbook.fetch_retry(Orderbook.reset(st), "BTCUSDT", make_ref()) == :none
    end
  end

  describe "authored continuity contract" do
    test "every declared sequence field is consumed by the continuity check" do
      incremental =
        for venue <- Spec.exchanges(),
            semantics = Spec.load!(venue)["websocket"]["orderbook_semantics"],
            semantics["apply_mode"] in ~w(incremental both),
            do: {venue, semantics}

      assert Enum.sort(Enum.map(incremental, &elem(&1, 0))) == ~w(binance binanceusdm bybit deribit okx)

      for {venue, semantics} <- incremental do
        st = state(venue)
        assert st.continuity != nil, "#{venue} maintains an incremental book without a continuity rule"
        assert Orderbook.consumed_fields(st) == Enum.sort(semantics["sequence_fields"]), venue
        assert semantics["sequence_fields"] != [], venue
      end
    end

    test "an incremental book without sequence fields fails at spec load unless a doc-cited reason is recorded" do
      spec = Spec.load!("deribit")

      bare =
        update_in(
          spec,
          ["websocket", "orderbook_semantics"],
          &(&1 |> Map.delete("continuity") |> Map.put("sequence_fields", []))
        )

      assert_raise ArgumentError, ~r/orderbook_semantics\.continuity/, fn -> Schema.validate!(bare, "deribit") end

      none = put_in(bare, ["websocket", "orderbook_semantics", "continuity"], %{"rule" => "none", "reason" => "no id"})
      assert_raise ArgumentError, ~r/continuity\.doc/, fn -> Schema.validate!(none, "deribit") end

      cited = put_in(none, ["websocket", "orderbook_semantics", "continuity", "doc"], "https://docs.deribit.com/")
      assert Schema.validate!(cited, "deribit") == cited
    end

    test "each rule accepts only the snapshot source it is implemented with" do
      for {rule, source} <- Schema.OrderbookContinuity.rule_sources(),
          venue =
            Enum.find(
              ~w(binance binanceusdm okx bybit),
              &(Spec.load!(&1)["websocket"]["orderbook_semantics"]["continuity"]["rule"] == rule)
            ),
          wrong = if(source == "rest", do: "stream", else: "rest") do
        spec = Spec.load!(venue)
        rest = Spec.load!("binance")["websocket"]["orderbook_semantics"]["continuity"]["rest_snapshot"]

        swapped =
          update_in(spec, ["websocket", "orderbook_semantics", "continuity"], fn c ->
            Map.merge(c, %{"snapshot_source" => wrong, "rest_snapshot" => rest, "subscription_path" => "topic"})
          end)

        assert_raise ArgumentError, ~r/rule #{inspect(rule)} is implemented with snapshot_source/, fn ->
          Schema.validate!(swapped, venue)
        end
      end
    end

    test "a declared sequence field the rule does not read is rejected" do
      spec = Spec.load!("binance")
      extra = update_in(spec, ["websocket", "orderbook_semantics", "sequence_fields"], &(&1 ++ ["nonce"]))

      assert_raise ArgumentError, ~r/sequence_fields: must be exactly the fields/, fn ->
        Schema.validate!(extra, "binance")
      end
    end
  end
end
