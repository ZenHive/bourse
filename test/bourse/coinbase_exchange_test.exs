defmodule Bourse.CoinbaseCandlePaginationTest do
  use ExUnit.Case, async: true

  alias Bourse.CoinbaseCandlePagination
  alias Bourse.ReplayExchange

  @minute_ms 60_000
  @now_ms 1_800_000_000_000

  describe "pagination/3" do
    test "builds non-overlapping inclusive pages of at most 300 candles" do
      params = %{"limit" => 601, "since" => @now_ms - 600 * @minute_ms, "timeframe" => "1m"}

      assert {:paginate, [first, second, third], metadata} =
               CoinbaseCandlePagination.pagination(params, %{"1m" => 60}, @now_ms)

      assert metadata == %{start_ms: params["since"], end_ms: @now_ms, limit: 601}
      assert first.start_ms == params["since"]
      assert first.end_ms - first.start_ms == 299 * @minute_ms
      assert second.start_ms == first.end_ms + @minute_ms
      assert second.end_ms - second.start_ms == 299 * @minute_ms
      assert third.start_ms == second.end_ms + @minute_ms
      assert third.end_ms == @now_ms
      assert third.params["until"] == @now_ms
    end

    test "derives a recent window when since is absent" do
      params = %{"limit" => 301, "timeframe" => "5m"}

      assert {:paginate, [first, second], metadata} =
               CoinbaseCandlePagination.pagination(params, %{"5m" => 300}, @now_ms)

      assert metadata.start_ms == @now_ms - 300 * 300_000
      assert first.end_ms - first.start_ms == 299 * 300_000
      assert second.start_ms == first.end_ms + 300_000
      assert second.end_ms == @now_ms
    end

    test "leaves single-page requests without a window unchanged" do
      params = %{"limit" => 300, "timeframe" => "1m"}
      assert {:single, ^params} = CoinbaseCandlePagination.pagination(params, %{"1m" => 60}, @now_ms)

      bare = %{"timeframe" => "1m"}
      assert {:single, ^bare} = CoinbaseCandlePagination.pagination(bare, %{"1m" => 60}, @now_ms)
    end

    # Coinbase ignores BOTH start and end when either is missing, silently
    # answering with the most recent page — a half-open single-page window
    # must be completed into an atomic pair before it reaches the wire.
    test "completes a since-only single-page window with a paired until" do
      since_ms = @now_ms - 1_000 * @minute_ms
      params = %{"limit" => 5, "since" => since_ms, "timeframe" => "1m"}

      assert {:single, completed} = CoinbaseCandlePagination.pagination(params, %{"1m" => 60}, @now_ms)
      assert completed["until"] == since_ms + 4 * @minute_ms
    end

    test "completes an until-only single-page window with a paired since" do
      until_ms = @now_ms - 500 * @minute_ms
      params = %{"limit" => 10, "timeframe" => "1m", "until" => until_ms}

      assert {:single, completed} = CoinbaseCandlePagination.pagination(params, %{"1m" => 60}, @now_ms)
      assert completed["since"] == until_ms - 9 * @minute_ms
    end

    test "since-only without a limit caps the completed window at one provider page" do
      since_ms = @now_ms - 1_000 * @minute_ms
      params = %{"since" => since_ms, "timeframe" => "1m"}

      assert {:single, completed} = CoinbaseCandlePagination.pagination(params, %{"1m" => 60}, @now_ms)
      assert completed["until"] == since_ms + 299 * @minute_ms
    end

    test "a completed until never runs past now or before since" do
      near_now = @now_ms - 2 * @minute_ms

      assert {:single, clamped} =
               CoinbaseCandlePagination.pagination(
                 %{"since" => near_now, "limit" => 10, "timeframe" => "1m"},
                 %{"1m" => 60},
                 @now_ms
               )

      assert clamped["until"] == @now_ms

      future = @now_ms + 100 * @minute_ms

      assert {:single, future_window} =
               CoinbaseCandlePagination.pagination(
                 %{"since" => future, "limit" => 10, "timeframe" => "1m"},
                 %{"1m" => 60},
                 @now_ms
               )

      assert future_window["until"] == future
    end

    test "an explicit window keeps both bounds untouched" do
      params = %{
        "limit" => 5,
        "since" => @now_ms - 10 * @minute_ms,
        "timeframe" => "1m",
        "until" => @now_ms - 5 * @minute_ms
      }

      assert {:single, ^params} = CoinbaseCandlePagination.pagination(params, %{"1m" => 60}, @now_ms)
    end

    # A since that is off the granularity grid still holds div(delta, tf) + 2
    # aligned buckets; truncating the count would leave the final bucket in a
    # window no page requests.
    test "an unaligned explicit window still tiles pages over its final bucket" do
      aligned = @now_ms - 100_000 * @minute_ms
      since_ms = aligned + 30_000
      until_ms = aligned + 400 * @minute_ms
      params = %{"limit" => 400, "since" => since_ms, "timeframe" => "1m", "until" => until_ms}

      assert {:paginate, pages, _metadata} = CoinbaseCandlePagination.pagination(params, %{"1m" => 60}, @now_ms)
      assert List.last(pages).end_ms >= until_ms
    end
  end

  describe "single-page wire window (unified dispatch)" do
    test "a since-only fetch_ohlcv ships start and end as a pair" do
      stub = :"coinbase_window_#{System.unique_integer([:positive])}"
      test_pid = self()
      since_ms = 1_700_000_000_000

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:candles_query, URI.decode_query(conn.query_string)})
        Req.Test.json(conn, [])
      end)

      {:ok, exchange} = Bourse.Exchange.new("coinbaseexchange")

      assert {:ok, []} =
               Bourse.fetch_ohlcv(exchange, "ETH/USD", "1m",
                 since: since_ms,
                 limit: 5,
                 plug: {Req.Test, stub}
               )

      assert_receive {:candles_query, query}
      assert query["start"] == "2023-11-14T22:13:20.000Z"
      assert query["end"] == "2023-11-14T22:17:20.000Z"
    end
  end

  test "merge_responses!/2 restores newest-first wire order and removes page overlap" do
    response_one = %{body: [[2, 20, 21, 19, 20, 2], [1, 10, 11, 9, 10, 1]], status: 200}
    response_two = %{body: [[3, 30, 31, 29, 30, 3], [2, 20, 21, 19, 20, 2]], status: 200}
    metadata = %{start_ms: 1_000, end_ms: 3_000, limit: 3}

    assert %{body: [[3 | _], [2 | _], [1 | _]], status: 200} =
             CoinbaseCandlePagination.merge_responses!([response_one, response_two], metadata)
  end

  test "public-only replay needs no unsupported market or currency cache" do
    exchange = ReplayExchange.build!("coinbaseexchange", %{})

    assert exchange.markets == []
    assert exchange.currencies == %{}
    assert exchange.signing_pattern == nil
  end
end
