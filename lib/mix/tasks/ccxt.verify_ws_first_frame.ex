defmodule Mix.Tasks.Ccxt.VerifyWsFirstFrame do
  @shortdoc "Probe every WebSocket venue for a classified first data frame"

  @moduledoc """
  Runs the classified public WebSocket first-frame matrix.

      mix ccxt.verify_ws_first_frame --report artifacts/ws-first-frame-report.json

  A subscribe acknowledgement is not coverage. Connecting and then receiving
  nothing within the bounded wait fails and names the venue and channel.
  Intentionally absent from commit, dispatch, and offline CI aliases.
  """

  use Mix.Task

  alias Bourse.LiveLane.Bootstrap
  alias Bourse.LiveLane.FirstFrame

  @default_report_path "artifacts/ws-first-frame-report.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    report_path = report_path!(args)
    Bootstrap.start!()
    result = FirstFrame.run()
    report = elem(result, 1)
    write_report!(report_path, report)
    print_report(report)

    case result do
      {:ok, _report} -> :ok
      {:error, _report} -> raise Mix.Error, "WebSocket first-frame lane failed; report: #{report_path}"
    end
  end

  defp report_path!(args) do
    case OptionParser.parse(args, strict: [report: :string]) do
      {[report: path], [], []} when is_binary(path) and path != "" -> path
      {[], [], []} -> @default_report_path
      _other -> raise Mix.Error, "usage: mix ccxt.verify_ws_first_frame [--report PATH]"
    end
  end

  defp write_report!(path, report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
  end

  defp print_report(%{status: "passed", venues: venues}) do
    Mix.shell().info("WebSocket first-frame passed for #{length(venues)} rows")
  end

  defp print_report(%{failures: failures}) do
    Mix.shell().error("WebSocket first-frame failed")

    Enum.each(failures, fn failure ->
      Mix.shell().error(failure.reason || "#{failure.venue} #{failure.channel}")
    end)
  end
end
