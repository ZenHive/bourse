defmodule Mix.Tasks.Ccxt.AggregateLiveLane do
  @shortdoc "Aggregate scheduled live-lane reports into one artifact"

  @moduledoc """
  Merges the per-surface live-lane reports into one durable artifact.

      mix ccxt.aggregate_live_lane \\
        --report artifacts/live-lane-report.json \\
        --authority artifacts/authority-drift-report.txt \\
        --authority-rc 0 \\
        --drift artifacts/live-drift-report.json \\
        --corpus artifacts/live-corpus-report.json \\
        --auth-smoke artifacts/ws-auth-smoke-dangerous-report.json \\
        --ws artifacts/ws-first-frame-report.json

  Intentionally absent from commit, dispatch, and offline CI aliases.
  """

  use Mix.Task

  alias Bourse.LiveLane

  @default_report_path "artifacts/live-lane-report.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {opts, report_path} = parse!(args)

    result =
      LiveLane.aggregate(
        authority: Keyword.get(opts, :authority),
        authority_rc: Keyword.get(opts, :authority_rc, 1),
        auth_smoke: read_json(Keyword.get(opts, :auth_smoke)),
        corpus: read_json(Keyword.get(opts, :corpus)),
        drift: read_json(Keyword.get(opts, :drift)),
        ws: read_json(Keyword.get(opts, :ws))
      )

    report = elem(result, 1)
    write_report!(report_path, report)
    print_report(report)

    case result do
      {:ok, _report} -> :ok
      {:error, _report} -> raise Mix.Error, "live lane aggregation failed; report: #{report_path}"
    end
  end

  defp parse!(args) do
    case OptionParser.parse(args,
           strict: [
             report: :string,
             authority: :string,
             authority_rc: :integer,
             drift: :string,
             corpus: :string,
             auth_smoke: :string,
             ws: :string
           ]
         ) do
      {opts, [], []} ->
        {opts, Keyword.get(opts, :report, @default_report_path)}

      _other ->
        raise Mix.Error,
              "usage: mix ccxt.aggregate_live_lane --report PATH --authority PATH --authority-rc N " <>
                "--drift PATH --corpus PATH --auth-smoke PATH --ws PATH"
    end
  end

  defp read_json(nil), do: {:error, "report path missing"}

  defp read_json(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> Jason.decode(contents)
      {:error, reason} -> {:error, "missing report #{path}: #{inspect(reason)}"}
    end
  end

  defp write_report!(path, report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
  end

  defp print_report(%{status: "passed", venues: venues}) do
    Mix.shell().info("Live lane passed; #{length(venues)} venues in artifact")
  end

  defp print_report(%{status: "failed", failures: failures}) do
    Mix.shell().error("Live lane failed")

    Enum.each(failures, fn failure ->
      Mix.shell().error(inspect(failure))
    end)
  end
end
