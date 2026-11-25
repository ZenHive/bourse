defmodule Bourse.DeribitValueSemanticsTest do
  @moduledoc """
  Value semantics of deribit `fetch_funding_rate`, `fetch_ticker` and
  `fetch_liquidations` against test.deribit.com.

  Every expectation here comes from a raw provider response read in the same
  test — never from a constant the client also uses — so a mapping that agrees
  with itself but not with the venue reddens.

  Authorities:
  - https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_value
  - https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_history
  - https://docs.deribit.com/api-reference/market-data/public-ticker
  - https://docs.deribit.com/api-reference/market-data/public-get_last_trades_by_instrument
  """
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2]

  alias Bourse.Error
  alias Bourse.Test.LiveGateIsolation

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_deribit

  @ms_per_hour 3_600_000
  @candidate_window_hours [1, 2, 4, 8]
  @window_search_hours 72
  @value_tolerance 1.0e-9
  @volume_drift 0.01
  @tape_attempts 5

  setup do
    LiveGateIsolation.isolate!("deribit")
    :ok
  end

  describe "fetch_funding_rate" do
    test "interval is the window the provider accrued the value over" do
      exchange = build_exchange(:deribit, sandbox: true)
      {end_ms, raw_by_hours} = distinguishable_funding_windows!(exchange, "BTC-PERPETUAL")

      # Provider semantics: a window value is the rate accrued over that window,
      # so the 8h window equals the history row's documented "8hour interest rate".
      history_8h = interest_8h_at!(exchange, "BTC-PERPETUAL", end_ms)
      assert_in_delta Map.fetch!(raw_by_hours, 8), history_8h, abs(history_8h) * 1.0e-6 + @value_tolerance

      assert {:ok, %Bourse.FundingRate{funding_rate: rate, interval: interval}} =
               Bourse.fetch_funding_rate(exchange, "BTC/USD:BTC", timestamp_ms_override: end_ms)

      assert [hours] = matching_windows(raw_by_hours, rate),
             "unified funding_rate #{inspect(rate)} must equal exactly one raw window value, got #{inspect(raw_by_hours)}"

      assert interval == "#{hours}h"

      four_hour_start = end_ms - 4 * @ms_per_hour
      four_hour_value = Map.fetch!(raw_by_hours, 4)

      # Every caller spelling of the same [T-4h, T] window must reach the
      # provider as that window and be labelled with its span.
      for {spelling, opts} <- [
            integer_bounds: [params: %{"start_timestamp" => four_hour_start, "end_timestamp" => end_ms}],
            string_bounds: [
              params: %{
                "start_timestamp" => Integer.to_string(four_hour_start),
                "end_timestamp" => Integer.to_string(end_ms)
              }
            ],
            start_only_on_request_clock: [since: four_hour_start, timestamp_ms_override: end_ms]
          ] do
        assert {:ok, %Bourse.FundingRate{funding_rate: caller_rate, interval: caller_interval}} =
                 with_rate_limit_retry(fn -> Bourse.fetch_funding_rate(exchange, "BTC/USD:BTC", opts) end)

        assert caller_interval == "4h", "#{spelling}: interval #{inspect(caller_interval)}"
        assert_window_value(caller_rate, four_hour_value, "#{spelling} rate")
      end

      # A span that is not a whole number of hours keeps its exact length.
      odd_start = four_hour_start + 123
      odd_value = raw_window_value!(exchange, "BTC-PERPETUAL", odd_start, end_ms)

      assert {:ok, %Bourse.FundingRate{funding_rate: odd_rate, interval: "14399877ms"}} =
               with_rate_limit_retry(fn ->
                 Bourse.fetch_funding_rate(exchange, "BTC/USD:BTC",
                   params: %{"start_timestamp" => odd_start, "end_timestamp" => end_ms}
                 )
               end)

      assert_window_value(odd_rate, odd_value, "non-round window rate")

      # End-only: the start stays on the request clock (clock - 8h), so the
      # dispatched window is [clock - 8h, end] and the label names that span.
      early_end = end_ms - @ms_per_hour
      end_only_value = raw_window_value!(exchange, "BTC-PERPETUAL", end_ms - 8 * @ms_per_hour, early_end)

      assert {:ok, %Bourse.FundingRate{funding_rate: end_only_rate, interval: "7h"}} =
               with_rate_limit_retry(fn ->
                 Bourse.fetch_funding_rate(exchange, "BTC/USD:BTC",
                   params: %{"end_timestamp" => early_end},
                   timestamp_ms_override: end_ms
                 )
               end)

      assert_window_value(end_only_rate, end_only_value, "end-only window rate")

      # Equal bounds: Deribit accepts the empty window and accrues 0 over it.
      assert {:ok, %Bourse.FundingRate{funding_rate: empty_rate, interval: "0ms"}} =
               with_rate_limit_retry(fn ->
                 Bourse.fetch_funding_rate(exchange, "BTC/USD:BTC",
                   params: %{"start_timestamp" => end_ms, "end_timestamp" => end_ms}
                 )
               end)

      assert empty_rate == 0

      # An unset clock override falls back to the system clock, like the request shaper.
      assert {:ok, %Bourse.FundingRate{interval: "8h", funding_rate: clock_rate}} =
               with_rate_limit_retry(fn ->
                 Bourse.fetch_funding_rate(exchange, "BTC/USD:BTC", timestamp_ms_override: nil)
               end)

      assert is_number(clock_rate)
    end

    test "a malformed bound reaches the provider and is refused as not an integer" do
      exchange = build_exchange(:deribit, sandbox: true)
      end_ms = div(System.system_time(:millisecond), @ms_per_hour) * @ms_per_hour

      # Observed live 2026-11-25: -32602 Invalid params, reason "integer required".
      for {param, value} <- [
            {"start_timestamp", "oops"},
            {"start_timestamp", Integer.to_string(end_ms - 4 * @ms_per_hour) <> "oops"},
            {"end_timestamp", "oops"}
          ] do
        assert {:error, %Error{type: :bad_request, code: -32_602, raw: raw}} =
                 with_rate_limit_retry(fn ->
                   Bourse.fetch_funding_rate(exchange, "BTC/USD:BTC",
                     params: %{param => value},
                     timestamp_ms_override: end_ms
                   )
                 end)

        assert raw["error"]["data"] == %{"param" => param, "reason" => "integer required"},
               "#{param}=#{inspect(value)}: #{inspect(raw)}"
      end
    end

    test "a dated future is refused by the provider as not perpetual" do
      exchange = build_exchange(:deribit, sandbox: true)
      {:ok, exchange} = Bourse.load_markets(exchange)
      future = Enum.find(exchange.markets, &(&1.future and &1.inverse and &1.base == "BTC"))
      assert %Bourse.Market{} = future

      # Observed live 2026-11-25: -32602 Invalid params, reason "instrument is not perpetual".
      assert {:error, %Error{type: :bad_request, code: -32_602, raw: raw}} =
               Bourse.fetch_funding_rate(exchange, future.symbol)

      assert raw["error"]["data"] == %{"param" => "instrument_name", "reason" => "instrument is not perpetual"}
    end
  end

  describe "fetch_ticker" do
    test "base and quote volumes carry the provider's base and quote figures per instrument kind" do
      {:ok, exchange} = Bourse.load_markets(build_exchange(:deribit, sandbox: true))

      for {kind, instrument} <- ticker_instruments!(exchange) do
        market = Enum.find(exchange.markets, &(&1.id == instrument))
        assert %Bourse.Market{} = market, "#{kind}: #{instrument} missing from loaded markets"

        assert {:ok, %Bourse.Ticker{base_volume: base, quote_volume: quote, info: info}} =
                 with_rate_limit_retry(fn -> Bourse.fetch_ticker(exchange, market.symbol) end)

        stats = info["stats"]
        independent = raw_ticker_stats!(exchange, instrument)

        # stats.volume: "Volume during last 24h in base currency".
        assert base == stats["volume"], "#{kind}: base_volume #{inspect(base)} vs stats #{inspect(stats)}"
        assert_close(base, independent["volume"], "#{kind} base vs independent raw call")

        assert_spot_quote_publication(kind, stats)

        case expected_quote(stats) do
          nil ->
            assert quote == nil, "#{kind}: provider published no quote figure, got #{inspect(quote)}"

          expected ->
            assert quote == expected, "#{kind}: quote_volume #{inspect(quote)} vs stats #{inspect(stats)}"
            assert_close(quote, expected_quote(independent), "#{kind} quote vs independent raw call")
            assert_quote_denomination(kind, base, quote, info)
        end
      end
    end

    test "an unknown instrument is refused by the provider" do
      exchange = build_exchange(:deribit, sandbox: true)

      # Observed live 2026-11-25: -32602 Invalid params, reason "instrument not found".
      assert {:error, %Error{type: :bad_request, code: -32_602, raw: raw}} =
               Bourse.fetch_ticker(exchange, "BTC/USD:BTC-991231")

      assert raw["error"]["data"]["reason"] == "instrument not found"
    end
  end

  describe "fetch_liquidations" do
    test "returns exactly the tape rows the provider marks as liquidations" do
      {:ok, exchange} = Bourse.load_markets(build_exchange(:deribit, sandbox: true))
      market = Enum.find(exchange.markets, &(&1.id == "BTC_USDC-PERPETUAL"))
      assert %Bourse.Market{} = market

      {raw_trades, liquidations} = stable_tape!(exchange, market, @tape_attempts)

      assert raw_trades != [], "the raw tape must hold trades for the filter to be exercised"

      marked = Enum.filter(raw_trades, &Map.has_key?(&1, "liquidation"))

      assert Enum.map(liquidations, & &1.info["trade_id"]) == Enum.map(marked, & &1["trade_id"])
      assert Enum.all?(liquidations, &(&1.info["liquidation"] in ["M", "T", "MT"]))

      if marked == [], do: assert(liquidations == [])
    end

    test "an unknown instrument is refused by the provider" do
      exchange = build_exchange(:deribit, sandbox: true)

      # Observed live 2026-11-25: -32602 Invalid params, reason "instrument not found".
      assert {:error, %Error{type: :bad_request, code: -32_602, raw: raw}} =
               Bourse.fetch_liquidations(exchange, "BTC/USD:BTC-991231")

      assert raw["error"]["data"]["reason"] == "instrument not found"
    end
  end

  # Picks the latest hour whose candidate windows accrued pairwise-distinct
  # amounts (judged from the hourly `interest_1h` history), then reads the
  # provider's own window values at that hour, so a match names one window.
  defp distinguishable_funding_windows!(exchange, instrument) do
    current_hour = div(System.system_time(:millisecond), @ms_per_hour) * @ms_per_hour
    longest = Enum.max(@candidate_window_hours)

    params = %{
      "instrument_name" => instrument,
      "start_timestamp" => current_hour - @window_search_hours * @ms_per_hour,
      "end_timestamp" => current_hour
    }

    assert {:ok, %{body: %{"result" => rows}}} =
             with_rate_limit_retry(fn -> Bourse.Deribit.public_get_get_funding_rate_history(exchange, params) end)

    hourly = Map.new(rows, &{&1["timestamp"], &1["interest_1h"]})

    end_ms =
      Enum.find(0..(@window_search_hours - longest), fn back ->
        end_ms = current_hour - back * @ms_per_hour
        hours = Enum.map(0..(longest - 1), &Map.get(hourly, end_ms - &1 * @ms_per_hour))

        Enum.all?(hours, &is_number/1) and
          distinct?(Enum.map(@candidate_window_hours, fn w -> hours |> Enum.take(w) |> Enum.sum() end))
      end)

    if is_nil(end_ms),
      do: flunk("no hour in the last #{@window_search_hours}h has distinguishable funding windows on #{instrument}")

    end_ms = current_hour - end_ms * @ms_per_hour
    values = Map.new(@candidate_window_hours, &{&1, raw_funding_value!(exchange, instrument, end_ms, &1)})

    assert distinct?(Map.values(values)),
           "provider window values at #{end_ms} are not distinguishable: #{inspect(values)}"

    {end_ms, values}
  end

  defp distinct?(values) do
    values
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> abs(b - a) > max(abs(a), abs(b)) * 0.01 end)
  end

  defp matching_windows(raw_by_hours, rate) do
    for {hours, value} <- Enum.sort(raw_by_hours), same_value?(value, rate), do: hours
  end

  defp same_value?(a, b), do: abs(a - b) <= max(abs(a), abs(b)) * @value_tolerance

  defp assert_window_value(rate, expected, label) do
    assert is_number(rate) and same_value?(rate, expected), "#{label}: #{inspect(rate)} vs provider #{inspect(expected)}"
  end

  defp with_rate_limit_retry(fun, attempts \\ 4) do
    case fun.() do
      {:error, %Error{type: :rate_limit_exceeded}} when attempts > 1 ->
        Process.sleep(1_000)
        with_rate_limit_retry(fun, attempts - 1)

      result ->
        result
    end
  end

  defp raw_funding_value!(exchange, instrument, end_ms, hours),
    do: raw_window_value!(exchange, instrument, end_ms - hours * @ms_per_hour, end_ms)

  defp raw_window_value!(exchange, instrument, start_ms, end_ms) when start_ms < end_ms do
    params = %{"instrument_name" => instrument, "start_timestamp" => start_ms, "end_timestamp" => end_ms}

    assert {:ok, %{body: %{"result" => value}}} =
             with_rate_limit_retry(fn -> Bourse.Deribit.public_get_get_funding_rate_value(exchange, params) end)

    assert is_number(value)
    value
  end

  defp interest_8h_at!(exchange, instrument, end_ms) do
    params = %{"instrument_name" => instrument, "start_timestamp" => end_ms - @ms_per_hour, "end_timestamp" => end_ms}

    assert {:ok, %{body: %{"result" => rows}}} =
             with_rate_limit_retry(fn -> Bourse.Deribit.public_get_get_funding_rate_history(exchange, params) end)

    assert %{"interest_8h" => value} = Enum.find(rows, &(&1["timestamp"] == end_ms))
    value
  end

  defp ticker_instruments!(exchange) do
    [
      {:inverse_perpetual, "BTC-PERPETUAL"},
      {:linear_perpetual, "BTC_USDC-PERPETUAL"},
      {:native_spot, spot_instrument!(exchange, "BTC_USDT", :native)},
      {:routed_spot, spot_instrument!(exchange, "BTC_USDC", :routed)},
      {:inverse_option, most_traded_option!(exchange, "BTC", "BTC-")},
      {:linear_option, most_traded_option!(exchange, "USDC", "BTC_USDC-")}
    ]
  end

  # https://docs.deribit.com/articles/spot-trading-venues: natively matched spot
  # publishes full `stats`; Coinbase-routed spot (flagged `is_cbe_routed: true`,
  # the flag absent on native pairs) omits `volume_notional` and `volume_usd`.
  # Routing is provider configuration, so the venue is read, not assumed.
  defp spot_instrument!(exchange, instrument, venue) do
    assert {:ok, %{body: %{"result" => rows}}} =
             with_rate_limit_retry(fn ->
               Bourse.Deribit.public_get_get_instruments(exchange, %{"currency" => "any", "kind" => "spot"})
             end)

    assert %{} = meta = Enum.find(rows, &(&1["instrument_name"] == instrument)), "#{instrument} is not listed as spot"

    routed? = Map.get(meta, "is_cbe_routed", false)
    assert routed? == (venue == :routed), "#{instrument} is_cbe_routed=#{inspect(routed?)}, expected #{venue} spot"
    instrument
  end

  defp most_traded_option!(exchange, currency, prefix) do
    assert {:ok, %{body: %{"result" => rows}}} =
             with_rate_limit_retry(fn ->
               Bourse.Deribit.public_get_get_book_summary_by_currency(exchange, %{
                 "currency" => currency,
                 "kind" => "option"
               })
             end)

    rows
    |> Enum.filter(&(String.starts_with?(&1["instrument_name"], prefix) and (&1["volume"] || 0) > 0))
    |> Enum.max_by(& &1["volume"], fn -> flunk("no traded #{prefix} option on the #{currency} book") end)
    |> Map.fetch!("instrument_name")
  end

  defp raw_ticker_stats!(exchange, instrument) do
    assert {:ok, %{body: %{"result" => %{"stats" => stats}}}} =
             with_rate_limit_retry(fn ->
               Bourse.Deribit.public_get_ticker(exchange, %{"instrument_name" => instrument})
             end)

    stats
  end

  # stats.volume_notional: "24-hour volume in quote currency"; inverse options
  # (whose provider quote equals base) publish only volume_usd, which is the
  # unified quote (USD) for those markets.
  defp expected_quote(stats), do: stats["volume_notional"] || stats["volume_usd"]

  defp assert_close(left, right, label) do
    assert is_number(left) and is_number(right), "#{label}: #{inspect(left)} / #{inspect(right)}"
    assert abs(left - right) <= max(abs(right), 1.0) * @volume_drift, "#{label}: #{left} vs #{right}"
  end

  defp assert_spot_quote_publication(:native_spot, stats) do
    assert is_number(stats["volume"]) and stats["volume"] > 0,
           "native spot needs traded volume to exercise its quote figure: #{inspect(stats)}"

    assert is_number(stats["volume_notional"]), "native spot publishes volume_notional: #{inspect(stats)}"
  end

  defp assert_spot_quote_publication(:routed_spot, stats) do
    refute Map.has_key?(stats, "volume_notional") or Map.has_key?(stats, "volume_usd"),
           "routed spot omits volume_notional and volume_usd: #{inspect(stats)}"
  end

  defp assert_spot_quote_publication(_kind, _stats), do: :ok

  defp assert_quote_denomination(kind, base, quote, info)
       when kind in [:inverse_perpetual, :linear_perpetual, :native_spot] do
    per_base = quote / base
    index = info["index_price"] || info["last_price"]
    assert per_base > index / 2 and per_base < index * 2, "#{kind}: quote/base #{per_base} vs index #{index}"
  end

  defp assert_quote_denomination(kind, base, quote, info) do
    per_base = quote / base
    underlying = info["underlying_price"] || info["index_price"]
    assert per_base > 0 and per_base < underlying, "#{kind}: premium per base #{per_base} vs underlying #{underlying}"
  end

  defp stable_tape!(_exchange, market, 0), do: flunk("the #{market.id} tape kept moving across #{@tape_attempts} reads")

  defp stable_tape!(exchange, market, attempts) do
    before = raw_tape!(exchange, market.id)
    assert {:ok, liquidations} = with_rate_limit_retry(fn -> Bourse.fetch_liquidations(exchange, market.symbol) end)
    after_read = raw_tape!(exchange, market.id)

    if trade_ids(before) == trade_ids(after_read) do
      {before, liquidations}
    else
      stable_tape!(exchange, market, attempts - 1)
    end
  end

  defp raw_tape!(exchange, instrument) do
    assert {:ok, %{body: %{"result" => %{"trades" => trades}}}} =
             with_rate_limit_retry(fn ->
               Bourse.Deribit.public_get_get_last_trades_by_instrument(exchange, %{"instrument_name" => instrument})
             end)

    trades
  end

  defp trade_ids(trades), do: Enum.map(trades, & &1["trade_id"])
end
