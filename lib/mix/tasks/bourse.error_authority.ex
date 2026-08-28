defmodule Mix.Tasks.Bourse.ErrorAuthority do
  @shortdoc "Checks authored error mappings against official venue enumerations"

  @moduledoc """
  Validates first-class venue error mappings and reports provider-documented
  identifiers that intentionally fall back to `Bourse.Error.exchange_error`.

      mix bourse.error_authority
  """

  use Mix.Task

  alias Mix.Tasks.Bourse.ErrorAuthorityCorpus

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([]) do
    reports = ErrorAuthorityCorpus.validate!()
    Enum.each(reports, &print_report/1)
    :ok
  end

  def run(args), do: Mix.raise("unexpected arguments: #{Enum.join(args, " ")}")

  defp print_report(report) do
    Mix.shell().info(
      "#{report.venue}: #{report.mapped_count}/#{report.documented_count} exact mappings; " <>
        "#{length(report.documented_not_mapped)} provider-only -> #{report.disposition}; " <>
        "#{length(report.dropped_non_authoritative)} inherited mappings dropped; " <>
        "#{length(report.retired)} retired; " <>
        "maintenance=#{report.maintenance_status}"
    )
  end
end
