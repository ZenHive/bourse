defmodule Bourse.CoinbaseCandlePaginationTest do
  use ExUnit.Case, async: true

  alias Bourse.CoinbaseCandlePagination

  @hour 3_600_000
  @timeframes %{"1h" => 3600}
  @params %{"timeframe" => "1h", "limit" => 601}

  test "single-page windows supply the missing partner and respect now" do
    for limit <- [nil, 0, 3] do
      params = %{"timeframe" => "1h", "limit" => limit, "since" => @hour}
      assert {:single, completed} = pagination(params, 2 * @hour)
      assert completed["since"] == @hour
      assert completed["until"] == 2 * @hour
    end

    assert {:single, completed} =
             pagination(%{"timeframe" => "1h", "until" => 3 * @hour, "limit" => 3})

    assert completed["since"] == @hour
    assert completed["until"] == 3 * @hour

    assert {:single, %{"since" => 0}} = pagination(%{"timeframe" => "1h", "until" => @hour})
    assert {:single, %{}} = pagination(%{})
    params = %{"since" => @hour, "until" => 2 * @hour}
    assert {:single, ^params} = pagination(params)
  end

  test "pagination retains explicit and inferred bounds" do
    for params <- [@params, Map.put(@params, "until", 900 * @hour), Map.put(@params, "since", 100 * @hour)] do
      assert {:paginate, pages, metadata} = pagination(params)
      assert pages != []
      assert metadata.limit == 601
      assert metadata.end_ms <= 1000 * @hour
      assert Enum.all?(pages, &(&1.params["since"] == &1.start_ms and &1.params["until"] == &1.end_ms))
    end

    assert {:paginate, [_], %{start_ms: 0}} = pagination(@params, 0)
  end

  test "unsupported timeframes fail before dispatch" do
    assert_raise ArgumentError, ~r/unsupported Coinbase Exchange timeframe/, fn ->
      pagination(Map.put(@params, "timeframe", "bad"))
    end
  end

  test "merge filters, deduplicates, orders and caps real rows while retaining response metadata" do
    responses = [%{body: [[0], [3600], [7200]], status: 200}, %{body: [[3600], [10_800], [14_400]]}]
    metadata = %{start_ms: @hour, end_ms: 3 * @hour, limit: 2}
    assert %{body: [[7200], [3600]], status: 200} = CoinbaseCandlePagination.merge_responses!(responses, metadata)
    assert %{body: []} = CoinbaseCandlePagination.merge_responses!([%{body: []}], metadata)
  end

  test "malformed responses and timestamps fail loudly" do
    metadata = %{start_ms: 0, end_ms: @hour, limit: 1}

    assert_raise ArgumentError, ~r/unexpected Coinbase candle response/, fn ->
      CoinbaseCandlePagination.merge_responses!([%{body: :invalid}], metadata)
    end

    for row <- [[], ["3600"]] do
      assert_raise ArgumentError, ~r/unexpected Coinbase candle row/, fn ->
        CoinbaseCandlePagination.merge_responses!([%{body: [row]}], metadata)
      end
    end
  end

  test "page tiling covers exactly the eligible openings, bounded by the limit and clock" do
    for first_offset <- [0, 1, @hour - 1],
        end_offset <- [0, 1, @hour - 1],
        width <- [0, 1, 299, 300, 301, 599, 600, 601, 1199, 1200],
        limit <- [301, 600, 1200] do
      since = 10 * @hour + first_offset
      until_ms = (10 + width) * @hour + end_offset
      now = min(until_ms, 1209 * @hour + 123)
      params = Map.merge(@params, %{"since" => since, "until" => until_ms, "limit" => limit})
      assert {:paginate, pages, metadata} = pagination(params, now)

      expected =
        10..1210
        |> Enum.map(&(&1 * @hour))
        |> Enum.filter(&(&1 >= since and &1 <= until_ms and &1 <= now))
        |> Enum.take(limit)

      actual =
        Enum.flat_map(pages, fn page ->
          assert page.start_ms >= since
          assert page.end_ms <= min(until_ms, now)
          assert page.start_ms <= page.end_ms
          assert rem(page.start_ms, @hour) == 0
          assert rem(page.end_ms, @hour) == 0
          assert div(page.end_ms - page.start_ms, @hour) < 300
          Enum.to_list(page.start_ms..page.end_ms//@hour)
        end)

      assert actual == expected
      assert metadata.start_ms == since
      assert metadata.end_ms == min(until_ms, now)
    end
  end

  test "the reported 1200-hour window needs exactly four pages" do
    params = %{"timeframe" => "1h", "since" => 1_785_110_400_000, "until" => 1_789_429_905_831, "limit" => 1200}
    assert {:paginate, pages, _metadata} = pagination(params, params["until"])
    assert length(pages) == 4
    assert List.last(pages).end_ms == 1_789_426_800_000
  end

  test "empty, reversed and wholly future windows produce no requests or candles" do
    exchange = Bourse.Exchange.new!("coinbaseexchange")

    for {since, until_ms, now} <- [
          {@hour + 1, 2 * @hour - 1, 3 * @hour},
          {2 * @hour, @hour, 3 * @hour},
          {3 * @hour, 4 * @hour, 2 * @hour}
        ] do
      params = Map.merge(@params, %{"since" => since, "until" => until_ms})
      assert {:paginate, [], metadata} = pagination(params, now)
      assert %{body: []} = CoinbaseCandlePagination.merge_responses!([], metadata)

      assert {:ok, []} =
               Bourse.fetch_ohlcv(exchange, "ETH/USD", "1h",
                 since: since,
                 until: until_ms,
                 limit: 601,
                 timestamp_ms_override: now,
                 plug: fn _conn -> flunk("empty candle window dispatched an HTTP request") end
               )
    end
  end

  test "inferred windows count aligned openings when the supplied boundary is unaligned" do
    now = 1000 * @hour + 1

    for params <- [@params, Map.put(@params, "until", now)] do
      assert {:paginate, pages, _} = pagination(params, now)
      assert hd(pages).start_ms == 400 * @hour
      assert List.last(pages).end_ms == 1000 * @hour
    end

    assert {:paginate, pages, _} = pagination(Map.put(@params, "since", 100 * @hour + 1), now)
    assert hd(pages).start_ms == 101 * @hour
    assert List.last(pages).end_ms == 701 * @hour
  end

  defp pagination(params, now \\ 1000 * @hour) do
    CoinbaseCandlePagination.pagination(params, @timeframes, now)
  end
end
