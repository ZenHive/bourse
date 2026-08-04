defmodule Mix.Tasks.Ccxt.VerifyLiveDrift do
  @shortdoc "Verify consumed provider fields with scheduled live reads"

  @moduledoc """
  Runs the network-only drift lane for all supported venues.

      mix ccxt.verify_live_drift --report artifacts/live-drift-report.json

  This target is intentionally absent from commit, dispatch, and offline CI
  aliases. It performs one public contract check and one authenticated,
  non-mutating private read per venue.
  """

  use Mix.Task

  alias Bourse.LiveDrift
  alias Bourse.LiveDrift.Bootstrap

  @default_report_path "artifacts/live-drift-report.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    report_path = report_path!(args)

    result =
      case LiveDrift.preflight() do
        :ok ->
          Bootstrap.start!()
          LiveDrift.run()

        {:error, _reason} ->
          LiveDrift.run()
      end

    report = elem(result, 1)
    write_report!(report_path, report)
    print_report(report)

    case result do
      {:ok, _report} -> :ok
      {:error, _report} -> raise Mix.Error, "live drift verification failed; report: #{report_path}"
    end
  end

  defp report_path!(args) do
    case OptionParser.parse(args, strict: [report: :string]) do
      {[report: path], [], []} when is_binary(path) and path != "" -> path
      {[], [], []} -> @default_report_path
      _other -> raise Mix.Error, "usage: mix ccxt.verify_live_drift [--report PATH]"
    end
  end

  defp write_report!(path, report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
  end

  defp print_report(%{status: "passed", run: run, venues: venues} = report) do
    Mix.shell().info("Live drift passed for #{length(venues)} venues; run #{run.id}")

    Enum.each(Map.get(report, :unreachable, []), fn row ->
      Mix.shell().info(
        "UNREACHABLE from this runner (declared via LIVE_DRIFT_UNREACHABLE_OK, not verified): " <>
          "#{row.venue}/#{row.method} -> #{row.actual_type}"
      )
    end)

    if run.url, do: Mix.shell().info("Run: #{run.url}")
  end

  defp print_report(%{failures: failures, run: run}) do
    Mix.shell().error("Live drift failed; run #{run.id}")

    Enum.each(failures, fn failure ->
      Mix.shell().error(
        "#{failure.venue}/#{failure.method} #{failure.field}: " <>
          "#{failure.expected_type} -> #{failure.actual_type}; " <>
          "recapture: #{failure.recapture}; re-author: #{failure.reauthor}"
      )
    end)
  end
end
