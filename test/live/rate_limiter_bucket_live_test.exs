defmodule Bourse.Live.RateLimiterBucketTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.RateLimiter
  alias Bourse.RateLimiter.Shaping
  alias Bourse.Test.LiveGateIsolation
  alias Bourse.Testnet

  @moduletag :integration
  @moduletag :network

  @public_tickers %{
    "alpaca" => "GLD",
    "binance" => "BTC/USDT",
    "binancecoinm" => "BTC/USD:BTC",
    "binanceusdm" => "BTC/USDT:USDT",
    "bybit" => "BTC/USDT",
    "coinbaseexchange" => "ETH/USD",
    "deribit" => "BTC/USD:BTC",
    "derive" => "BTC/USD:USDC",
    "hyperliquid" => "BTC/USDC:USDC",
    "lighter" => "BTC/USDC:USDC",
    "okx" => "BTC/USDT"
  }

  @okx_burst_count 12
  @bybit_stale_ok_ms 6_000
  @bybit_stale_fail_ms 12_000
  @bybit_queue_concurrency 20

  @moduletag timeout: 120_000

  test "every runtime venue honours its authored token bucket on a live call" do
    venues = Bourse.Registry.exchanges()
    assert length(venues) == 11

    for venue <- venues do
      LiveGateIsolation.isolate!(venue)
      exchange = live_exchange(venue)
      bucket = Map.fetch!(exchange.config, "rate_limit_bucket")

      assert is_number(bucket.max_size) and bucket.max_size > 0,
             "#{venue} cannot execute as a token bucket: #{inspect(bucket)}"

      assert is_number(bucket.refill_per_sec) and bucket.refill_per_sec > 0,
             "#{venue} cannot execute as a token bucket: #{inspect(bucket)}"

      rate_key = Shaping.rate_key(exchange)
      checks = Shaping.build_rate_limit_checks(rate_key, exchange, 1)
      assert [{_key, %{capacity: capacity, refill_per_sec: refill}, _cost} | _] = checks
      assert capacity == bucket.max_size, "#{venue} limiter capacity #{capacity} != authored #{bucket.max_size}"
      assert_in_delta refill, bucket.refill_per_sec, 0.0001

      fill_until_delay(checks)

      parent = self()
      handler_id = "live-bucket-#{venue}-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        Bourse.Telemetry.rate_limiter_throttled(),
        fn _event, measurements, metadata, _config ->
          send(parent, {:throttled, measurements, metadata})
        end,
        nil
      )

      try do
        symbol = Map.fetch!(@public_tickers, venue)

        case Bourse.fetch_ticker(exchange, symbol) do
          {:ok, _ticker} ->
            :ok

          other ->
            flunk("#{venue} live ticker #{symbol} failed: #{inspect(other)}")
        end

        assert_received {:throttled, %{delay_ms: delay_ms}, %{exchange: ^venue}}
        assert delay_ms > 0
        assert delay_ms < Bourse.Defaults.rate_limit_max_wait_ms()
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  @tag timeout: 120_000
  test "okx signed GETs with retry disabled do not earn 50011 while the limiter admits them" do
    LiveGateIsolation.isolate!("okx")
    exchange = live_exchange("okx")

    results =
      for index <- 1..@okx_burst_count do
        {index, Bourse.Okx.private_get_account_config(exchange, %{}, retry: false)}
      end

    first_reject =
      Enum.find(results, fn {_index, result} -> okx_too_many_requests?(result) end)

    assert is_nil(first_reject),
           "okx 50011 at request #{inspect(first_reject)} of #{@okx_burst_count} while limiter was on"

    successes = Enum.count(results, fn {_index, result} -> match?({:ok, _}, result) end)

    assert successes == @okx_burst_count,
           "okx signed GET burst: issued=#{@okx_burst_count} ok=#{successes} first-50011=none results=#{inspect(Enum.map(results, fn {_i, r} -> result_summary(r) end))}"
  end

  test "bybit under queue pressure stays inside recv_window and accepts authored 10000" do
    LiveGateIsolation.isolate!("bybit")
    exchange = live_exchange("bybit")
    assert exchange.signing_config.recv_window == 10_000

    tasks =
      for _i <- 1..@bybit_queue_concurrency do
        Task.async(fn ->
          Bourse.fetch_balance(exchange)
        end)
      end

    results = Task.await_many(tasks, 30_000)

    nonce_failures =
      Enum.filter(results, fn
        {:error, %Error{type: :invalid_nonce}} -> true
        _ -> false
      end)

    assert nonce_failures == [],
           "bybit invalid_nonce under queue pressure: #{inspect(nonce_failures)}"

    {:ok, server_ms} = Bourse.fetch_time(exchange)
    now_ms = System.system_time(:millisecond)
    gap = abs(now_ms - server_ms)

    assert gap < exchange.signing_config.recv_window,
           "req-to-server timestamp gap #{gap}ms is outside recv_window #{exchange.signing_config.recv_window}"

    stale_ok = now_ms - @bybit_stale_ok_ms

    case Bourse.fetch_balance(exchange, timestamp_ms_override: stale_ok) do
      {:ok, _} ->
        :ok

      other ->
        flunk("bybit recv_window 10000 should accept a #{@bybit_stale_ok_ms}ms-stale timestamp: #{inspect(other)}")
    end

    stale_fail = System.system_time(:millisecond) - @bybit_stale_fail_ms

    assert {:error, %Error{type: type} = error} =
             Bourse.fetch_balance(exchange, timestamp_ms_override: stale_fail)

    assert type == :invalid_nonce,
           "expected invalid_nonce for #{@bybit_stale_fail_ms}ms-stale bybit ts, got #{inspect(error)}"
  end

  defp live_exchange("coinbaseexchange") do
    Exchange.new!("coinbaseexchange")
  end

  defp live_exchange(venue) do
    Exchange.new!(venue,
      credentials: Testnet.creds!(String.to_existing_atom(venue)),
      sandbox: true
    )
  end

  defp fill_until_delay(checks) do
    case RateLimiter.check_rates(checks) do
      :ok -> fill_until_delay(checks)
      {:delay, _ms} -> :ok
    end
  end

  defp okx_too_many_requests?({:error, %Error{} = error}) do
    code = error.code || get_in(error.raw, ["code"])
    code in [50_011, "50011"] or (is_binary(error.message) and String.contains?(error.message, "50011"))
  end

  defp okx_too_many_requests?(_result), do: false

  defp result_summary({:ok, _}), do: :ok
  defp result_summary({:error, %Error{} = error}), do: {error.type, error.code, error.message}
  defp result_summary(other), do: other
end
