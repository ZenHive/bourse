defmodule Mix.Tasks.Ccxt.VerifyRestReadContracts do
  @shortdoc "Run every provider-live REST-read contract"

  @moduledoc """
  Runs the complete provider-live REST-read contract inventory.

      mix ccxt.verify_rest_read_contracts
      mix ccxt.verify_rest_read_contracts --output /tmp/rest-read-contracts.json

  The task includes the otherwise excluded network lane explicitly. It fails
  when any inventoried branch is missing, skipped, invalid, or unsuccessful.
  """

  use Mix.Task

  @default_output_path "/tmp/bourse-rest-read-contracts.json"
  @test_file "test/bourse/rest_read_contract_live_test.exs"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    output_path = output_path!(args)
    :ok = contracts().validate!()
    denominator = contracts().denominator()
    File.mkdir_p!(Path.dirname(output_path))

    {command_output, exit_status} =
      System.cmd(mix_executable!(), test_args(output_path),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    report = read_report!(output_path, command_output)
    summary = summarize(report, denominator)
    print_summary(summary, output_path)

    if exit_status != 0 or incomplete?(summary) do
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

  defp output_path!(args) do
    case OptionParser.parse(args, strict: [output: :string]) do
      {[output: path], [], []} when is_binary(path) and path != "" -> path
      {[], [], []} -> @default_output_path
      _other -> raise Mix.Error, "usage: mix ccxt.verify_rest_read_contracts [--output PATH]"
    end
  end

  defp test_args(output_path) do
    [
      "test.json",
      @test_file,
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

  defp print_summary(summary, output_path) do
    Mix.shell().info(
      "REST-read contracts denominator=#{summary.denominator} " <>
        "executed=#{summary.executed} failures=#{summary.failures} report=#{output_path}"
    )
  end
end
