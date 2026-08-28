defmodule Mix.Tasks.Bourse.VerifyRestReadContracts do
  @shortdoc "Run every provider-live REST-read contract"

  @moduledoc """
  Runs the provider-live REST-read contract inventory.

      mix bourse.verify_rest_read_contracts
      mix bourse.verify_rest_read_contracts --venue deribit
      mix bourse.verify_rest_read_contracts --output /tmp/rest-read-contracts.json

  Without `--venue` it runs every venue's contract file under `test/live/` and
  measures the full inventory denominator. With `--venue` it runs only that
  venue's file and measures that venue's denominator, so a shrinking live
  surface stays red in both modes.

  The task includes the otherwise excluded network lane explicitly. It fails
  when any inventoried branch is missing, skipped, invalid, or unsuccessful.
  """

  use Mix.Task

  alias Bourse.LiveLane.Ledger

  @default_output_path "/tmp/bourse-rest-read-contracts.json"
  @live_root "test/live"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {output_path, venue} = options!(args)
    :ok = contracts().validate!()
    venue = validate_venue!(venue)
    denominator = denominator(venue)
    File.mkdir_p!(Path.dirname(output_path))

    {command_output, _exit_status} =
      System.cmd(mix_executable!(), test_args(output_path, venue),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    report = read_report!(output_path, command_output)
    summary = summarize(report, denominator)
    classification = classify_failures(report)
    print_summary(summary, output_path, classification)

    shrinking? = summary.executed != summary.denominator
    genuine? = classification.genuine != []

    if shrinking? or genuine? do
      Mix.shell().error(command_output)
      raise Mix.Error, "provider-live REST-read contracts failed; report: #{output_path}"
    end

    :ok
  end

  @doc "Builds execution counts from a test.json report."
  @spec summarize(map(), non_neg_integer()) :: map()
  def summarize(%{"summary" => raw_summary}, denominator) do
    %{
      denominator: denominator,
      executed: raw_summary["total"] - raw_summary["excluded"],
      failures:
        raw_summary["failed"] + raw_summary["invalid"] + raw_summary["skipped"] +
          raw_summary["excluded"],
      result: raw_summary["result"]
    }
  end

  def summarize(_report, _denominator), do: raise(Mix.Error, "test.json report has no summary")

  @doc "Builds execution counts and rejects any incomplete or failed inventory."
  @spec summarize!(map(), non_neg_integer()) :: map()
  def summarize!(report, denominator) do
    summary = summarize(report, denominator)

    if incomplete?(summary) do
      raise Mix.Error,
            "REST-read inventory was not fully exercised: " <>
              "denominator=#{denominator} executed=#{summary.executed} failures=#{summary.failures}"
    end

    summary
  end

  defp options!(args) do
    case OptionParser.parse(args, strict: [output: :string, venue: :string]) do
      {parsed, [], []} ->
        output = Keyword.get(parsed, :output, @default_output_path)
        venue = Keyword.get(parsed, :venue)

        if is_binary(output) and output != "" do
          {output, venue}
        else
          usage!()
        end

      _other ->
        usage!()
    end
  end

  defp usage!, do: raise(Mix.Error, "usage: mix bourse.verify_rest_read_contracts [--venue VENUE] [--output PATH]")

  defp validate_venue!(nil), do: nil

  defp validate_venue!(venue) do
    known = contracts().venues()

    if venue in known do
      venue
    else
      raise Mix.Error, "unknown venue #{inspect(venue)}; supported venues: #{Enum.join(known, ", ")}"
    end
  end

  defp denominator(nil), do: contracts().denominator()
  defp denominator(venue), do: contracts().denominator(venue)

  defp test_files(nil), do: Enum.map(contracts().venues(), &venue_test_file/1)
  defp test_files(venue), do: [venue_test_file(venue)]

  defp venue_test_file(venue), do: Path.join([@live_root, venue, "rest_read_contract_test.exs"])

  defp test_args(output_path, venue) do
    ["test.json"] ++
      test_files(venue) ++
      [
        "--quiet",
        "--include",
        "network",
        "--only",
        "rest_read_contract",
        "--no-retry",
        "--output",
        output_path
      ]
  end

  defp mix_executable! do
    System.find_executable("mix") || raise Mix.Error, "mix executable is unavailable"
  end

  defp contracts, do: Module.concat([Bourse, Test, RestReadContracts])

  defp read_report!(output_path, command_output) do
    if File.regular?(output_path) do
      output_path |> File.read!() |> Jason.decode!()
    else
      Mix.shell().error(command_output)
      raise Mix.Error, "test.json did not write the REST-read report: #{output_path}"
    end
  end

  defp incomplete?(summary) do
    summary.executed != summary.denominator or summary.failures != 0 or summary.result != "passed"
  end

  defp print_summary(summary, output_path, classification) do
    Mix.shell().info(
      "REST-read contracts denominator=#{summary.denominator} " <>
        "executed=#{summary.executed} failures=#{summary.failures} report=#{output_path}"
    )

    Mix.shell().info(Ledger.format_summary(classification.ledgered, length(classification.genuine)))

    Enum.each(classification.genuine, fn test ->
      Mix.shell().info("  genuine: #{test["name"]}")
    end)
  end

  defp classify_failures(report) do
    failed = report |> Map.get("tests", []) |> Enum.filter(&(&1["state"] == "failed"))
    classified = Ledger.classify_report_failures(failed, Ledger.load!())
    %{classified | ledgered: read_hits() ++ classified.ledgered}
  end

  defp read_hits do
    case File.read(Ledger.hits_path()) do
      {:ok, contents} -> Jason.decode!(contents)
      {:error, _reason} -> []
    end
  end
end
