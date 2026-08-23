defmodule Bourse.LiveLaneTest do
  use ExUnit.Case, async: false

  alias Bourse.LiveLane
  alias Bourse.LiveLane.Bootstrap
  alias Bourse.LiveLane.FirstFrame
  alias Bourse.Spec
  alias Bourse.WS.Config

  defmodule StubWS do
    @moduledoc false

    def connect(exchange, :public), do: {:ok, exchange}

    def watch_ticker(exchange, _symbol, _opts) do
      send(self(), {:websocket_message, %{"topic" => "ticker", "data" => %{"last" => "1"}}})
      {:ok, %{channels: ["ticker:#{exchange.id}"]}}
    end

    def watch_trades(exchange, _symbol, _opts) do
      send(self(), {:websocket_message, [%{"T" => "t", "S" => "FAKEPACA"}]})
      {:ok, %{channels: ["trades:#{exchange.id}"]}}
    end

    def subscribe(%{id: "lighter"}, _channels, _opts) do
      send(self(), {:websocket_message, lighter_snapshot()})
      :ok
    end

    def subscribe(_exchange, channels, _opts) do
      send(self(), {:websocket_message, %{"channel" => List.first(channels), "data" => %{"value" => "1"}}})
      :ok
    end

    def close(_exchange), do: :ok

    defp lighter_snapshot do
      %{"type" => "subscribed/market_stats", "channel" => "market_stats/0", "market_stats" => %{"market_id" => 0}}
    end
  end

  test "completeness covers every runtime venue on public and private WS surfaces" do
    assert :ok = FirstFrame.completeness_error()

    probed = MapSet.new(Enum.map(FirstFrame.probes(), & &1.venue))
    assert probed == MapSet.new(Config.supported_exchanges())

    public_excluded =
      FirstFrame.exclusions()
      |> Enum.filter(&(&1.surface == "ws_public"))
      |> MapSet.new(& &1.venue)

    private_excluded =
      FirstFrame.exclusions()
      |> Enum.filter(&(&1.surface == "ws_private"))
      |> MapSet.new(& &1.venue)

    runtime = MapSet.new(Spec.exchanges())
    assert MapSet.union(probed, public_excluded) == runtime
    assert private_excluded == runtime
  end

  test "every exclusion names why it cannot be probed and where it is tracked" do
    for %{venue: venue, surface: surface, reason: reason, tracking: tracking} <- FirstFrame.exclusions() do
      assert surface in ["ws_public", "ws_private"], "#{venue} exclusion surface is #{surface}"
      assert String.trim(reason) != "", "#{venue} #{surface} exclusion has no reason"
      assert tracking =~ ~r/task(?:s)? \d+/i, "#{venue} #{surface} exclusion has no task tracking reference"
    end
  end

  test "the scheduled corpus includes the WebSocket auth smoke and the files the lane actually runs" do
    assert LiveLane.corpus_include() == ~w(network capability_live)

    assert LiveLane.corpus_exclude() ==
             ~w(dangerous raw public_probe unified_integration invalid_creds symbol_public_probe)

    lane = File.read!("ops/live-drift.sh")
    assert lane =~ "test/bourse/ws/auth_live_smoke_test.exs"
    assert lane =~ "--all"
    assert lane =~ "--include network"
    assert lane =~ "--include capability_live"
    refute lane =~ "--include integration"
    assert lane =~ "--exclude dangerous"
    assert lane =~ "mix ccxt.verify_ws_first_frame --report"
    assert lane =~ "mix ccxt.aggregate_live_lane"
  end

  test "silence after connect fails and names the venue and channel" do
    assert {:error, report} =
             FirstFrame.run(
               timeout_ms: 20,
               connect: fn _spec -> {:ok, :stub} end,
               subscribe: fn _ws, spec -> {:ok, channel_name(spec)} end,
               close: fn _ws -> :ok end
             )

    bybit = Enum.find(report.venues, &(&1.venue == "bybit" and &1.status == "failed"))
    assert bybit.channel == "watch_ticker:BTC/USDT"
    assert bybit.reason =~ "bybit watch_ticker:BTC/USDT:"
    assert bybit.reason =~ "connected but received no frame"
    assert bybit.first_frame == nil
  end

  test "a subscribe acknowledgement without a data frame is silence, not coverage" do
    subscribe = fn _ws, spec ->
      if spec.venue == "bybit" do
        send(self(), {:websocket_message, %{"op" => "subscribe", "success" => true}})
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} =
             FirstFrame.run(
               timeout_ms: 30,
               connect: fn _spec -> {:ok, :stub} end,
               subscribe: subscribe,
               close: fn _ws -> :ok end
             )

    bybit = Enum.find(report.venues, &(&1.venue == "bybit"))
    assert bybit.status == "failed"
    assert bybit.first_frame == "acknowledgement"
    assert bybit.data_frame == nil
    assert bybit.reason =~ "bybit watch_ticker:BTC/USDT:"
    assert bybit.reason =~ "connected but received no data frame"
  end

  test "a first frame that is an acknowledgement carrying payload is classified as such" do
    subscribe = fn _ws, spec ->
      if spec.venue == "lighter" do
        send(self(), {:websocket_message, lighter_snapshot()})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:ok, report} = run_classified(subscribe)
    lighter = Enum.find(report.venues, &(&1.venue == "lighter" and &1.status == "passed"))
    assert lighter.first_frame == "acknowledgement_with_payload"
    assert lighter.data_frame == "acknowledgement_with_payload"
    assert lighter.channel == "market_stats/0"
  end

  test "a later data frame after a pure ack is classified separately from the acknowledgement" do
    subscribe = fn _ws, spec ->
      if spec.venue == "bybit" do
        send(self(), {:websocket_message, %{"op" => "subscribe", "success" => true}})
        send(self(), {:websocket_message, %{"topic" => "tickers.BTCUSDT", "data" => %{"lastPrice" => "1"}}})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:ok, report} = run_classified(subscribe)
    bybit = Enum.find(report.venues, &(&1.venue == "bybit" and &1.status == "passed"))
    assert bybit.first_frame == "acknowledgement"
    assert bybit.data_frame == "data"
  end

  test "subscription metadata is not a data frame" do
    subscribe = fn _ws, spec ->
      if spec.venue == "hyperliquid" do
        send(self(), {
          :websocket_message,
          %{
            "channel" => "subscriptionResponse",
            "data" => %{"method" => "subscribe", "subscription" => %{"type" => "allMids"}}
          }
        })
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} = run_classified(subscribe)
    hyperliquid = Enum.find(report.venues, &(&1.venue == "hyperliquid" and &1.status == "failed"))
    assert hyperliquid.first_frame == "acknowledgement"
    assert hyperliquid.data_frame == nil
    assert hyperliquid.reason =~ "received no data frame"
  end

  test "late frames from one venue cannot satisfy the next venue probe" do
    subscribe = fn _ws, spec ->
      cond do
        spec.venue == "alpaca" ->
          send_passed_frames(spec)
          send_passed_frames(spec)

        spec.venue == "binance" ->
          :ok

        true ->
          send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} = run_classified(subscribe)
    binance = Enum.find(report.venues, &(&1.venue == "binance" and &1.status == "failed"))
    assert binance.reason =~ "binance watch_ticker:BTC/USDT"
    assert binance.reason =~ "received no frame"
  end

  test "subscribe errors and skipped heartbeats still name the venue and channel" do
    subscribe = fn _ws, spec ->
      cond do
        spec.venue == "derive" ->
          {:error, :subscription_rejected}

        spec.venue == "okx" ->
          send(self(), {:websocket_message, "ping"})
          send(self(), {:ws_frame, %{"event" => "subscribe"}})

          send(
            self(),
            {:websocket_unmatched_response, %{"arg" => %{"channel" => "tickers"}, "data" => [%{"last" => "1"}]}}
          )

          {:ok, channel_name(spec)}

        true ->
          send_passed_frames(spec)
          {:ok, channel_name(spec)}
      end
    end

    assert {:error, report} =
             FirstFrame.run(
               timeout_ms: 50,
               connect: fn _spec -> {:ok, :stub} end,
               subscribe: subscribe,
               close: fn _ws -> :ok end
             )

    derive = Enum.find(report.venues, &(&1.venue == "derive"))
    assert derive.status == "failed"
    assert derive.reason =~ "derive"
    assert derive.reason =~ "subscription_rejected"

    okx = Enum.find(report.venues, &(&1.venue == "okx" and &1.status == "passed"))
    assert okx.first_frame == "acknowledgement"
    assert okx.data_frame == "data"
  end

  test "heartbeats are skipped and a rejected subscribe fails the named channel" do
    subscribe = fn _ws, spec ->
      if spec.venue == "okx" do
        send(self(), {:websocket_message, %{"event" => "ping"}})
        send(self(), {:websocket_message, %{"event" => "error", "code" => "60018", "msg" => "bad"}})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} =
             FirstFrame.run(
               timeout_ms: 50,
               connect: fn _spec -> {:ok, :stub} end,
               subscribe: subscribe,
               close: fn _ws -> :ok end
             )

    okx = Enum.find(report.venues, &(&1.venue == "okx"))
    assert okx.status == "failed"
    assert okx.first_frame == "rejected"
    assert okx.reason =~ "okx"
    assert okx.reason =~ "60018"
  end

  test "declared unreachable connect errors move out of failures" do
    assert {:ok, report} =
             FirstFrame.run(
               unreachable_ok: ["binance"],
               connect: fn
                 %{venue: "binance"} -> {:error, :network_error}
                 _spec -> {:ok, :stub}
               end,
               subscribe: fn _ws, spec ->
                 send_passed_frames(spec)
                 {:ok, channel_name(spec)}
               end,
               close: fn _ws -> :ok end,
               timeout_ms: 50
             )

    binance = Enum.find(report.venues, &(&1.venue == "binance" and &1.section == "public"))
    assert binance.status == "unreachable"
    assert report.failures == []
  end

  test "alpaca missing credentials fail the named public channel" do
    assert {:error, report} =
             FirstFrame.run(
               get_env: fn _variable -> nil end,
               timeout_ms: 20,
               ws_client: StubWS
             )

    alpaca = Enum.find(report.venues, &(&1.venue == "alpaca" and &1.status == "failed"))
    assert alpaca.reason =~ "alpaca"
    assert alpaca.reason =~ "missing_credentials"
  end

  test "default connection and subscription paths receive classified frames" do
    get_env = fn
      "ALPACA_API_KEY" -> "paper-key"
      "ALPACA_API_SECRET" -> "paper-secret"
    end

    assert {:ok, report} = FirstFrame.run(get_env: get_env, timeout_ms: 20, ws_client: StubWS)
    assert Enum.all?(report.venues, &(&1.status in ["passed", "excluded"]))
  end

  test "frame_kind distinguishes payload-bearing acks from connectivity" do
    assert FirstFrame.frame_kind({:success, :data}, lighter_snapshot()) == "acknowledgement_with_payload"
    assert FirstFrame.frame_kind(:not_ack, %{"topic" => "tickers.BTCUSDT"}) == "data"
    assert FirstFrame.frame_kind(:success, %{"op" => "subscribe", "success" => true}) == "acknowledgement"

    assert FirstFrame.frame_kind(:success, %{
             "channel" => "subscriptionResponse",
             "data" => %{"method" => "subscribe"}
           }) == "acknowledgement"
  end

  test "aggregate fails when a surface report is missing so silence cannot pass" do
    assert {:error, report} =
             LiveLane.aggregate(
               authority: "artifacts/authority-drift-report.txt",
               authority_rc: 0,
               drift: {:ok, %{"status" => "passed", "venues" => [], "failures" => []}},
               corpus: {:error, "missing report artifacts/live-corpus-report.json: :enoent"},
               auth_smoke: {:ok, %{"status" => "passed", "summary" => %{"result" => "passed", "failed" => 0}}},
               ws: {:ok, %{"status" => "passed", "venues" => [], "failures" => []}}
             )

    assert report.status == "failed"
    assert Enum.any?(report.failures, &(&1.surface == "live_corpus"))
    coinbase = Enum.find(report.venues, &(&1.venue == "coinbaseexchange"))
    assert coinbase.ws_public["status"] == "excluded"
    assert coinbase.ws_private["status"] == "excluded"
  end

  test "aggregate fails a non-zero authority check and records corpus test failures" do
    corpus = %{
      "tests" => [
        %{
          "state" => "failed",
          "file" => "test/a.exs",
          "name" => "one",
          "failures" => [%{"message" => "boom"}]
        },
        %{"state" => "failed", "file" => "test/b.exs", "name" => "two", "message" => "ouch"},
        %{"state" => "failed", "file" => "test/c.exs", "name" => "three"}
      ]
    }

    assert {:error, report} =
             LiveLane.aggregate(
               authority: "artifacts/authority-drift-report.txt",
               authority_rc: 7,
               drift: {:ok, %{"status" => "passed", "venues" => [], "failures" => []}},
               corpus: {:ok, corpus},
               auth_smoke: {:error, "missing report ws-auth-smoke-dangerous-report.json: :enoent"},
               ws: {:error, "missing report ws-first-frame-report.json: :enoent"}
             )

    assert report.status == "failed"
    assert report.surfaces.authority.status == "failed"
    assert report.surfaces.live_corpus.status == "failed"
    assert hd(report.surfaces.live_corpus.failures).message == "boom"
    assert Enum.any?(report.surfaces.live_corpus.failures, &(&1.message == "ouch"))
    assert Enum.any?(report.surfaces.live_corpus.failures, &(&1.message == "failed"))
    assert report.surfaces.ws_auth_smoke_dangerous.status == "failed"
    assert report.surfaces.ws_first_frame.status == "failed"
  end

  test "aggregate keeps atom-keyed first-frame rows and GitHub run identity" do
    previous = {System.get_env("GITHUB_RUN_ID"), System.get_env("GITHUB_SERVER_URL"), System.get_env("GITHUB_REPOSITORY")}

    on_exit(fn ->
      restore_env("GITHUB_RUN_ID", elem(previous, 0))
      restore_env("GITHUB_SERVER_URL", elem(previous, 1))
      restore_env("GITHUB_REPOSITORY", elem(previous, 2))
    end)

    System.put_env("GITHUB_RUN_ID", "99")
    System.put_env("GITHUB_SERVER_URL", "https://example.test")
    System.put_env("GITHUB_REPOSITORY", "zenhive/bourse")

    ws_venues = [
      %{venue: "okx", section: :public, status: "passed", channel: "tickers", first_frame: "data", data_frame: "data"}
    ]

    assert {:ok, report} =
             LiveLane.aggregate(
               authority_rc: 0,
               drift:
                 {:ok,
                  %{"status" => "passed", "venues" => [%{venue: "okx", public: %{status: "passed"}}], "failures" => []}},
               corpus:
                 {:ok,
                  %{
                    "status" => "passed",
                    "summary" => %{"failed" => 0},
                    "tests" => [passed_test("test/bourse/rest_read_contract_live_test.exs", "okx")]
                  }},
               auth_smoke:
                 {:ok,
                  %{
                    "status" => "passed",
                    "tests" => [passed_test("test/bourse/ws/auth_live_smoke_test.exs", "okx")]
                  }},
               ws: {:ok, %{"status" => "passed", "venues" => ws_venues, "failures" => []}}
             )

    assert report.run.id == "99"
    assert report.run.url == "https://example.test/zenhive/bourse/actions/runs/99"
    okx = Enum.find(report.venues, &(&1.venue == "okx"))
    assert okx.ws_public["first_frame"] == "data"
    assert okx.rest["public"].status == "passed"
  end

  test "a passed aggregation lists rest and classified first-frame outcomes per venue" do
    ws_venues = [
      %{
        "venue" => "bybit",
        "section" => "public",
        "status" => "passed",
        "channel" => "watch_ticker:BTC/USDT",
        "first_frame" => "acknowledgement",
        "data_frame" => "data"
      }
    ]

    drift_venues =
      Enum.map(
        Spec.exchanges(),
        &%{"venue" => &1, "public" => %{"status" => "passed"}, "private" => %{"status" => "passed"}}
      )

    assert {:ok, report} =
             LiveLane.aggregate(
               authority: "artifacts/authority-drift-report.txt",
               authority_rc: 0,
               drift: {:ok, %{"status" => "passed", "venues" => drift_venues, "failures" => []}},
               corpus: {
                 :ok,
                 %{
                   "summary" => %{"result" => "passed", "failed" => 0, "total" => 1, "passed" => 1},
                   "tests" => [
                     passed_test("test/bourse/rest_read_contract_live_test.exs", "bybit"),
                     %{
                       "file" => "test/bourse/skipped_live_test.exs",
                       "name" => "registered exclusion",
                       "state" => "skipped",
                       "tags" => %{"network" => true}
                     }
                   ]
                 }
               },
               auth_smoke:
                 {:ok,
                  %{
                    "status" => "passed",
                    "summary" => %{"result" => "passed", "failed" => 0},
                    "tests" => [passed_test("test/bourse/ws/auth_live_smoke_test.exs", "bybit")]
                  }},
               ws: {:ok, %{"status" => "passed", "venues" => ws_venues, "failures" => []}}
             )

    bybit = Enum.find(report.venues, &(&1.venue == "bybit"))
    assert bybit.rest["public"]["status"] == "passed"
    assert bybit.ws_public["first_frame"] == "acknowledgement"
    assert bybit.ws_public["data_frame"] == "data"
    assert bybit.ws_private["status"] == "excluded"
    assert bybit.ws_private["tracking"] =~ "auth_live_smoke"
    assert bybit.live_tests.live_corpus.status == "passed"
    assert bybit.live_tests.ws_auth_smoke_dangerous.status == "passed"

    assert report.surfaces.live_corpus.files == [
             %{file: "test/bourse/rest_read_contract_live_test.exs", states: %{"passed" => 1}, status: "passed"},
             %{file: "test/bourse/skipped_live_test.exs", states: %{"skipped" => 1}, status: "skipped"}
           ]
  end

  test "bootstrap starts REST drift plus WebSocket lane processes" do
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

    pid =
      Bootstrap.start!(
        ensure_started: ensure_started,
        start_supervisor: start_supervisor
      )

    assert_receive {:application, :req}
    assert_receive {:application, :fuse}
    assert_receive {:application, :ssl}
    assert_receive {:application, :crypto}
    assert_receive {:application, :jason}
    assert_receive {:application, :zen_websocket}

    assert_receive {:children, [Bourse.RateLimiter, Bourse.RateLimiter.State, Bourse.Signing.Lighter.Supervisor]}
    assert_receive {:children, children}

    assert Enum.map(children, &child_name/1) == [
             Bourse.WS.Broadcast.Registry,
             Bourse.WS.ConnectionOwner.Supervisor
           ]

    send(pid, :stop)
  end

  test "mix targets boot app.config and never start the complete application" do
    for path <- [
          "lib/mix/tasks/ccxt.verify_ws_first_frame.ex",
          "lib/mix/tasks/ccxt.aggregate_live_lane.ex"
        ] do
      source = File.read!(path)
      assert source =~ ~s|Mix.Task.run("app.config")|
      refute source =~ ~s|Mix.Task.run("app.start")|
      refute source =~ "Application.ensure_all_started(:bourse)"
    end

    mix_project = File.read!("mix.exs")
    refute mix_project =~ ~s("ccxt.verify_ws_first_frame")
    refute mix_project =~ ~s("ccxt.aggregate_live_lane")
  end

  defp run_classified(subscribe) do
    FirstFrame.run(
      timeout_ms: 50,
      connect: fn _spec -> {:ok, :stub} end,
      subscribe: subscribe,
      close: fn _ws -> :ok end
    )
  end

  defp send_passed_frames(%{venue: "lighter"}) do
    send(self(), {:websocket_message, lighter_snapshot()})
  end

  defp send_passed_frames(_spec) do
    send(self(), {:websocket_message, %{"topic" => "tickers.BTCUSDT", "data" => %{"lastPrice" => "1"}}})
  end

  defp lighter_snapshot do
    %{"type" => "subscribed/market_stats", "channel" => "market_stats/0", "market_stats" => %{"market_id" => 0}}
  end

  defp channel_name(%{channels: [channel | _]}) when is_binary(channel), do: channel
  defp channel_name(%{channels: [channel | _]}) when is_map(channel), do: inspect(channel)
  defp channel_name(%{watch: watch, symbol: symbol}), do: "#{watch}:#{symbol}"

  defp child_name(%{id: id}), do: id
  defp child_name({id, _start, _restart, _shutdown, _type, _modules}), do: id
  defp child_name(module) when is_atom(module), do: module
  defp child_name(_other), do: nil

  defp passed_test(file, venue) do
    %{
      "file" => file,
      "name" => "#{venue} live probe",
      "state" => "passed",
      "tags" => %{"exchange_#{venue}" => true, "venue" => venue}
    }
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
