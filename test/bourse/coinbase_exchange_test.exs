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

    test "leaves requests within one provider page unchanged" do
      assert :single =
               CoinbaseCandlePagination.pagination(
                 %{"limit" => 300, "timeframe" => "1m"},
                 %{"1m" => 60},
                 @now_ms
               )

      assert :single = CoinbaseCandlePagination.pagination(%{"timeframe" => "1m"}, %{"1m" => 60}, @now_ms)
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
