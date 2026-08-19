defmodule Mix.Tasks.Ccxt.AggregateLiveLaneTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.AggregateLiveLane

  test "writes the durable artifact from per-surface reports" do
    directory = Path.join(System.tmp_dir!(), "live-lane-agg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    authority = Path.join(directory, "authority-drift-report.txt")
    drift = Path.join(directory, "live-drift-report.json")
    corpus = Path.join(directory, "live-corpus-report.json")
    auth_smoke = Path.join(directory, "ws-auth-smoke-dangerous-report.json")
    ws = Path.join(directory, "ws-first-frame-report.json")
    report = Path.join(directory, "live-lane-report.json")

    File.write!(authority, "ok\n")
    File.write!(drift, Jason.encode!(%{status: "passed", venues: [], failures: []}))
    test_row = %{file: "test/live_test.exs", name: "live probe", state: "passed", tags: %{exchange_bybit: true}}
    File.write!(corpus, Jason.encode!(%{summary: %{result: "passed", failed: 0}, tests: [test_row]}))
    File.write!(auth_smoke, Jason.encode!(%{status: "passed", tests: [test_row]}))
    File.write!(ws, Jason.encode!(%{status: "passed", venues: [], failures: []}))

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    assert :ok =
             AggregateLiveLane.run([
               "--report",
               report,
               "--authority",
               authority,
               "--authority-rc",
               "0",
               "--drift",
               drift,
               "--corpus",
               corpus,
               "--auth-smoke",
               auth_smoke,
               "--ws",
               ws
             ])

    assert %{"status" => "passed"} = Jason.decode!(File.read!(report))
  end

  test "missing surface reports fail the aggregation and still write the artifact" do
    directory = Path.join(System.tmp_dir!(), "live-lane-agg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    report = Path.join(directory, "live-lane-report.json")
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    assert_raise Mix.Error, ~r/live lane aggregation failed/, fn ->
      AggregateLiveLane.run(["--report", report, "--authority-rc", "1"])
    end

    assert %{"status" => "failed"} = Jason.decode!(File.read!(report))
  end

  test "rejects unknown switches" do
    assert_raise Mix.Error, ~r/usage: mix ccxt.aggregate_live_lane/, fn ->
      AggregateLiveLane.run(["--nope"])
    end
  end
end

defmodule Mix.Tasks.Ccxt.VerifyWsFirstFrameTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.VerifyWsFirstFrame

  test "rejects unknown switches" do
    assert_raise Mix.Error, ~r/usage: mix ccxt.verify_ws_first_frame/, fn ->
      VerifyWsFirstFrame.run(["--nope"])
    end
  end

  test "writes a passing classified report" do
    directory = Path.join(System.tmp_dir!(), "ws-first-frame-#{System.unique_integer([:positive])}")
    report_path = Path.join(directory, "report.json")
    on_exit(fn -> File.rm_rf(directory) end)

    report = %{status: "passed", venues: [], failures: []}

    assert :ok =
             VerifyWsFirstFrame.run(["--report", report_path],
               bootstrap: fn -> self() end,
               verify: fn -> {:ok, report} end
             )

    assert ^report = report_path |> File.read!() |> Jason.decode!(keys: :atoms)
  end

  test "writes a failing classified report before raising" do
    directory = Path.join(System.tmp_dir!(), "ws-first-frame-#{System.unique_integer([:positive])}")
    report_path = Path.join(directory, "report.json")
    on_exit(fn -> File.rm_rf(directory) end)

    report = %{
      status: "failed",
      venues: [],
      failures: [%{venue: "bybit", channel: "tickers", reason: "bybit tickers: silence"}]
    }

    assert_raise Mix.Error, ~r/WebSocket first-frame lane failed/, fn ->
      VerifyWsFirstFrame.run(["--report", report_path],
        bootstrap: fn -> self() end,
        verify: fn -> {:error, report} end
      )
    end

    assert ^report = report_path |> File.read!() |> Jason.decode!(keys: :atoms)
  end
end

defmodule Bourse.LiveLaneBootstrapTest do
  use ExUnit.Case, async: false

  alias Bourse.LiveLane.Bootstrap

  test "ensure_started failures name the WebSocket application" do
    ensure_started = fn
      application when application in [:req, :fuse] -> {:ok, [application]}
      application -> {:error, {:stopped, application}}
    end

    start_supervisor = fn _children -> {:ok, spawn(fn -> :ok end)} end

    assert_raise RuntimeError, ~r/failed to start ssl/, fn ->
      Bootstrap.start!(ensure_started: ensure_started, start_supervisor: start_supervisor)
    end
  end

  test "already-started supervisors are reused" do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    start_supervisor = fn _children -> {:error, {:already_started, pid}} end
    ensure_started = fn _application -> {:ok, []} end

    assert Bootstrap.start!(ensure_started: ensure_started, start_supervisor: start_supervisor) == pid
    send(pid, :stop)
  end

  test "supervisor start failures raise" do
    ensure_started = fn _application -> {:ok, []} end

    start_supervisor = fn children ->
      if Enum.any?(children, &(&1 == Bourse.WS.ConnectionOwner.Supervisor)) do
        {:error, :crash}
      else
        {:ok, spawn(fn -> :ok end)}
      end
    end

    assert_raise RuntimeError, ~r/failed to start live lane WebSocket processes/, fn ->
      Bootstrap.start!(ensure_started: ensure_started, start_supervisor: start_supervisor)
    end
  end
end
