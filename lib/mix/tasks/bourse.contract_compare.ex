defmodule Mix.Tasks.Bourse.ContractCompare do
  @shortdoc "Compares pinned provider contracts with authored venue specs"

  @moduledoc """
  Emits deterministic, read-only provider-versus-authored inventories.

  Artifact bytes must first be materialized through the authority-corpus fetch
  controls. This task performs no network access and verifies every available
  artifact against its manifest before parsing it.

      mix bourse.authority_check --fetch /tmp/bourse-authority
      mix bourse.contract_compare --artifacts /tmp/bourse-authority --output /tmp/bourse-contracts

  Missing or non-machine-readable sources produce explicit capability-limited
  reports. `--venue` narrows output to one supported venue. `--facts` supplies
  registered reachability or runtime judgments.

  A comparison of pinned bytes against authored specs calls no venue and so
  observes no behaviour. A `--facts` entry declaring `evidence: "verified"` is
  refused: that axis is advanced only by the provider-live contract lane
  (`mix bourse.verify_rest_read_contracts`).
  """

  use Mix.Task

  alias Mix.Tasks.Bourse.ContractComparator

  @switches [
    artifacts: :string,
    output: :string,
    venue: :string,
    facts: :string
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    ensure_no_positional!(positional)
    artifact_root = required_option!(opts, :artifacts)
    output_root = required_option!(opts, :output)
    ensure_directory!(artifact_root, "--artifacts")

    reports =
      ContractComparator.compare_all!(artifact_root, venue: opts[:venue], facts_path: opts[:facts])

    ensure_reports!(reports, opts[:venue])
    File.mkdir_p!(output_root)

    Enum.each(reports, fn report ->
      path = Path.join(output_root, "#{report["venue"]}.json")
      File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
      print_summary(report, path)
    end)

    :ok
  end

  defp print_summary(report, path) do
    summaries =
      Enum.map_join(~w(current_rest upcoming_rest current_websocket upcoming_websocket), ", ", fn surface ->
        value = report["surfaces"][surface]
        "#{surface}=#{value["source_capability"]}:#{value["provider_count"]}/#{value["authored_count"]}"
      end)

    Mix.shell().info("#{report["venue"]}: #{summaries} -> #{path}")
  end

  defp required_option!(opts, key) do
    Keyword.get(opts, key) || Mix.raise("--#{key} is required")
  end

  defp ensure_directory!(path, option) do
    if !File.dir?(path), do: Mix.raise("#{option} must name an existing directory: #{path}")
  end

  defp ensure_reports!([], venue), do: Mix.raise("unsupported or unmatched venue #{inspect(venue)}")
  defp ensure_reports!(_reports, _venue), do: :ok

  defp ensure_no_positional!([]), do: :ok
  defp ensure_no_positional!(args), do: Mix.raise("unexpected arguments: #{Enum.join(args, " ")}")
end
