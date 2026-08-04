defmodule Mix.Tasks.Ccxt.OracleGate do
  @shortdoc "Reports computed binary oracle provenance and checks its exact ratchet"
  @moduledoc """
  Computes verified and unverified authored slots from committed reality.

      mix ccxt.oracle_gate
      mix ccxt.oracle_gate --update

  Critical-slot coverage is report-only. Manifest consistency, the exact
  verified-slot baseline, and production-ledger conflicts are gates.
  """

  use Mix.Task

  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance

  @baseline_path "test/fixtures/oracle_gate_baseline.json"
  @ledger_path "docs/prod-verification-ledger.md"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:bourse)

    {opts, rest, invalid} = OptionParser.parse(args, strict: [update: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix ccxt.oracle_gate [--update]")
    end

    reports = OracleProvenance.binary_reports!()
    check_open_ledger!(reports)
    Enum.each(reports, &report/1)

    if opts[:update] do
      reports
      |> OracleProvenance.binary_baseline()
      |> Jason.encode!(pretty: true)
      |> then(&Mix.Generator.create_file(@baseline_path, &1 <> "\n", force: true))

      Mix.shell().info("updated #{@baseline_path}")
    else
      check_baseline!(reports)
    end
  end

  defp check_open_ledger!(reports) do
    conflicts =
      @ledger_path
      |> File.read!()
      |> OracleProvenance.open_ledger_entries()
      |> then(&OracleProvenance.tier_one_ledger_conflicts(reports, &1))

    if conflicts != [] do
      Mix.raise("production oracle claims conflict with the open ledger:\n" <> bullets(conflicts))
    end
  end

  defp check_baseline!(reports) do
    # Strict reader: a duplicate key in the ratchet baseline must raise, not
    # silently let the first occurrence win.
    baseline = JsonDocument.decode_file!(@baseline_path)

    case OracleProvenance.binary_baseline_differences(reports, baseline) do
      [] -> Mix.shell().info("binary oracle exact-set ratchet passed")
      differences -> Mix.raise("binary oracle exact-set ratchet failed:\n" <> bullets(differences))
    end
  end

  defp report(report) do
    Mix.shell().info("#{report.venue}: verified #{length(report.verified)}, unverified #{length(report.unverified)}")

    Enum.each(report.slots, fn slot ->
      Mix.shell().info(
        "  #{status(slot)} #{slot.path} host=#{hosts(slot)} semantic=#{slot.semantic} " <>
          "methods=#{methods(slot.contributing_methods)} verification=#{verification(slot)} " <>
          "evidence=#{evidence(slot)}#{critical(slot)}"
      )
    end)
  end

  defp status(%{verified: true}), do: "verified"
  defp status(_slot), do: "unverified"
  defp hosts(%{host_classes: []}), do: "-"
  defp hosts(slot), do: Enum.join(slot.host_classes, ",")
  defp methods([]), do: "-"
  defp methods(methods), do: Enum.join(methods, ",")
  defp verification(%{verification_paths: []}), do: "-"
  defp verification(%{verification_paths: paths}), do: Enum.map_join(paths, ",", &Atom.to_string/1)
  defp verification(_slot), do: "-"
  defp evidence(%{verification_citations: []}), do: "-"
  defp evidence(%{verification_citations: citations}), do: Enum.join(citations, ",")
  defp evidence(_slot), do: "-"
  defp critical(%{critical: false}), do: ""

  defp critical(slot) do
    " critical=true missing_methods=#{methods(slot.unverified_methods)}"
  end

  defp bullets(messages), do: Enum.map_join(messages, "\n", &"  * #{&1}")
end
