defmodule Bourse.LiveDriftTest do
  use ExUnit.Case, async: true

  alias Bourse.LiveDrift
  alias Bourse.LiveDrift.Bootstrap
  alias Bourse.LiveDrift.Comparator
  alias Bourse.RecordedResponseFixtures

  @venues ~w(alpaca binance binancecoinm binanceusdm bybit deribit derive hyperliquid lighter okx)
  @expected_capture_count 20

  test "profiles activate exactly one public and one private read for the support manifest" do
    assert LiveDrift.profiles() |> Map.keys() |> Enum.sort() == @venues

    for {venue, profile} <- LiveDrift.profiles() do
      {public_method, _parse_type, _js_method} = profile.public
      assert RecordedResponseFixtures.capture_category(venue, public_method) == :public
      assert RecordedResponseFixtures.capture_category(venue, profile.private) == :private
    end
  end

  test "preflight rejects missing, extra, and duplicated manifest venues" do
    configured_env = fn _variable -> "configured" end

    assert {:error, {:support_manifest_mismatch, difference}} =
             LiveDrift.preflight(manifest_venues: @venues ++ ["kraken"], get_env: configured_env)

    assert difference.extra == ["kraken"]

    assert {:error, {:support_manifest_mismatch, duplicate_difference}} =
             LiveDrift.preflight(manifest_venues: @venues ++ ["okx"], get_env: configured_env)

    assert duplicate_difference.actual == @venues ++ ["okx"]
  end

  test "missing credentials fail before capture with exact setup instructions" do
    test_process = self()

    get_env = fn
      "OKX_INTL_PASSPHRASE" -> nil
      _variable -> "configured"
    end

    capture = fn venue, method, _opts ->
      send(test_process, {:unexpected_capture, venue, method})
      {:error, :unexpected_capture}
    end

    assert {:error, report} = LiveDrift.run(get_env: get_env, capture: capture)
    assert report.status == "failed"

    assert Enum.any?(report.failures, fn failure ->
             failure.venue == "okx" and
               failure.field == "credentials.OKX_INTL_PASSPHRASE" and
               failure.recapture =~ ~s(export OKX_INTL_PASSPHRASE="replace-me")
           end)

    refute_received {:unexpected_capture, _, _}
  end

  test "the offline capture seam exercises every activated public and private profile" do
    test_process = self()

    capture = fn venue, method, opts ->
      send(test_process, {:capture, venue, method, opts})
      {:ok, fixture(venue, method)}
    end

    assert {:ok, report} =
             LiveDrift.run(
               capture: capture,
               capture_opts: [plug: :offline],
               get_env: fn _variable -> "configured" end
             )

    assert report.status == "passed"
    assert length(report.venues) == length(@venues)

    assert Enum.all?(report.venues, fn venue ->
             venue.public.status == "passed" and venue.private.status == "passed"
           end)

    captures =
      for _index <- 1..@expected_capture_count do
        assert_receive {:capture, venue, method, [plug: :offline]}
        {venue, method}
      end

    expected =
      Enum.flat_map(LiveDrift.profiles(), fn {venue, profile} ->
        {public_method, _parse_type, _js_method} = profile.public
        [{venue, public_method}, {venue, profile.private}]
      end)

    assert Enum.sort(captures) == Enum.sort(expected)
  end

  test "removed and type-changed consumed fields fail with targeted repair paths" do
    baseline = fixture("deribit", :fetch_ticker)
    removed = update_in(baseline, ["body", "result"], &Map.delete(&1, "timestamp"))

    removed_result =
      Comparator.compare("deribit", :fetch_ticker, "ticker", "fetchTicker", baseline, removed)

    assert Enum.any?(removed_result.failures, fn failure ->
             failure.venue == "deribit" and
               failure.method == :fetch_ticker and
               failure.field == "timestamp:timestamp" and
               failure.actual_type == "missing" and
               failure.recapture == "mix ccxt.record_fixtures deribit fetch_ticker" and
               failure.reauthor == "priv/specs/json/output/authored/deribit.json"
           end)

    changed = put_in(baseline, ["body", "result", "timestamp"], "not-a-number")
    changed_result = Comparator.compare("deribit", :fetch_ticker, "ticker", "fetchTicker", baseline, changed)

    assert Enum.any?(changed_result.failures, fn failure ->
             failure.field == "timestamp:timestamp" and
               failure.expected_type == "number" and
               failure.actual_type == "string"
           end)
  end

  test "additive unconsumed provider keys are observations rather than failures" do
    baseline = fixture("deribit", :fetch_ticker)
    live = put_in(baseline, ["body", "result", "newProviderField"], true)

    result = Comparator.compare("deribit", :fetch_ticker, "ticker", "fetchTicker", baseline, live)

    assert result.failures == []

    assert result.observations == [
             %{
               field: "result.newProviderField",
               method: :fetch_ticker,
               observation: "additive_unconsumed_key",
               venue: "deribit"
             }
           ]
  end

  test "OKX future captures use the international demo identity without rewriting fixtures" do
    assert RecordedResponseFixtures.oracle_identity("okx", :fetch_balance) == %{
             "authenticated" => true,
             "endpoint" => "api/v5/account/balance",
             "environment" => "testnet-demo",
             "host" => "www.okx.com"
           }

    assert RecordedResponseFixtures.required_credentials("okx", :fetch_balance) ==
             ~w(OKX_INTL_API_KEY OKX_INTL_API_SECRET OKX_INTL_PASSPHRASE)

    committed = fixture("okx", :fetch_balance)
    assert committed["host"] == "my.okx.com"
  end

  test "bootstrap starts only required dependency applications and live-read processes" do
    test_process = self()

    ensure_started = fn application ->
      send(test_process, {:application, application})
      {:ok, [application]}
    end

    start_supervisor = fn children ->
      send(test_process, {:children, children})

      {:ok,
       spawn(fn ->
         receive do
           :stop -> :ok
         end
       end)}
    end

    pid = Bootstrap.start!(ensure_started: ensure_started, start_supervisor: start_supervisor)

    assert_receive {:application, :req}
    assert_receive {:application, :fuse}

    assert_receive {:children,
                    [
                      Bourse.RateLimiter,
                      Bourse.RateLimiter.State,
                      Bourse.Signing.Lighter.Supervisor
                    ]}

    send(pid, :stop)
  end

  test "mix target boots app.config and never starts the complete application" do
    source = File.read!("lib/mix/tasks/ccxt.verify_live_drift.ex")

    assert source =~ ~s|Mix.Task.run("app.config")|
    refute source =~ ~s|Mix.Task.run("app.start")|
    refute source =~ "Application.ensure_all_started(:bourse)"
  end

  test "scheduler is isolated from commit events and uploads its report on failure" do
    workflow = File.read!(".github/workflows/live-drift.yml")
    mix_project = File.read!("mix.exs")

    assert workflow =~ "schedule:"
    assert workflow =~ "workflow_dispatch:"
    refute workflow =~ "pull_request:"
    refute workflow =~ "push:"
    assert workflow =~ "if: always()"
    assert workflow =~ "artifacts/live-drift-report.json"
    refute mix_project =~ ~s("ccxt.verify_live_drift")
  end

  test "declared unreachable venues move reachability capture errors out of failures" do
    capture = fn
      "bybit", _method, _opts -> {:error, %Bourse.Error{type: :network_error, message: "connection refused"}}
      "binance", _method, _opts -> {:error, %Bourse.Error{type: :exchange_not_available, message: "geo page"}}
      venue, method, _opts -> {:ok, fixture(venue, method)}
    end

    assert {:ok, report} =
             LiveDrift.run(
               capture: capture,
               get_env: fn _variable -> "configured" end,
               unreachable_ok: ["binance", "bybit"]
             )

    assert report.status == "passed"
    assert report.failures == []
    assert length(report.unreachable) == 4

    assert Enum.all?(report.unreachable, fn row ->
             row.venue in ["binance", "bybit"] and row.field == "$request"
           end)

    for venue <- ["binance", "bybit"] do
      row = Enum.find(report.venues, &(&1.venue == venue))
      assert row.public.status == "unreachable"
      assert row.private.status == "unreachable"
    end
  end

  test "reachability errors on undeclared venues still fail the run" do
    capture = fn
      "deribit", _method, _opts -> {:error, %Bourse.Error{type: :network_error, message: "connection refused"}}
      venue, method, _opts -> {:ok, fixture(venue, method)}
    end

    assert {:error, report} =
             LiveDrift.run(
               capture: capture,
               get_env: fn _variable -> "configured" end,
               unreachable_ok: ["binance"]
             )

    assert report.status == "failed"
    assert Enum.any?(report.failures, &(&1.venue == "deribit" and &1.actual_type == "network_error"))
  end

  test "the unreachable allowlist never absorbs drift or non-reachability errors" do
    drifted =
      update_in(fixture("bybit", :fetch_ticker), ["body", "result", "list"], fn [row | rest] ->
        [Map.delete(row, "lastPrice") | rest]
      end)

    capture = fn
      "bybit", :fetch_ticker, _opts -> {:ok, drifted}
      "binance", _method, _opts -> {:error, %Bourse.Error{type: :authentication_error, message: "bad key"}}
      venue, method, _opts -> {:ok, fixture(venue, method)}
    end

    assert {:error, report} =
             LiveDrift.run(
               capture: capture,
               get_env: fn _variable -> "configured" end,
               unreachable_ok: ["binance", "bybit"]
             )

    assert report.status == "failed"
    assert Enum.any?(report.failures, &(&1.venue == "bybit" and &1.method == :fetch_ticker))
    assert Enum.any?(report.failures, &(&1.venue == "binance" and &1.actual_type == "authentication_error"))
  end

  defp fixture(venue, method) do
    venue
    |> RecordedResponseFixtures.fixture_path(method)
    |> RecordedResponseFixtures.load_fixture!()
  end
end
