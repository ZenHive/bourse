defmodule Mix.Tasks.Ccxt.OracleGate do
  @shortdoc "Reports computed binary oracle provenance and checks its exact ratchet"
  @moduledoc """
  Computes verified and unverified authored slots from committed reality.

      mix ccxt.oracle_gate
      mix ccxt.oracle_gate --update

  Critical-slot coverage hard-fails per venue unless each slot has
  manifest-registered reality evidence or an explicit dated production-ledger
  waiver. Manifest consistency, the exact verified-slot baseline, and ledger
  conflicts are also gates.
  """

  use Mix.Task

  alias Bourse.Exchange
  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance
  alias Bourse.Spec

  @baseline_path "test/fixtures/oracle_gate_baseline.json"
  @capability_surface_path "priv/specs/json/capability_surface.json"
  @capability_surface_version 1
  @ledger_path "docs/prod-verification-ledger.md"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args), do: run(args, [])

  @doc false
  @spec run([String.t()], keyword()) :: :ok
  def run(args, runtime_opts) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:bourse)

    {parsed_opts, rest, invalid} = OptionParser.parse(args, strict: [update: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix ccxt.oracle_gate [--update]")
    end

    capability_surface =
      Keyword.get_lazy(runtime_opts, :capability_surface, &authored_capability_surface/0)

    if !parsed_opts[:update], do: check_capability_surface!(capability_surface)

    reports = OracleProvenance.binary_reports!()
    check_open_ledger!(reports)
    check_critical_slots!(reports, Keyword.get(runtime_opts, :today, Date.utc_today()))
    Enum.each(reports, &report/1)

    if parsed_opts[:update] do
      reports
      |> OracleProvenance.binary_baseline()
      |> Jason.encode!(pretty: true)
      |> then(&Mix.Generator.create_file(@baseline_path, &1 <> "\n", force: true))

      capability_surface
      |> capability_surface_document()
      |> Jason.encode!(pretty: true)
      |> then(&Mix.Generator.create_file(@capability_surface_path, &1 <> "\n", force: true))

      Mix.shell().info("updated #{@baseline_path}")
      Mix.shell().info("updated #{@capability_surface_path}")
    else
      check_baseline!(reports)
    end
  end

  defp check_capability_surface!(current) do
    case Exchange.capability_surface_differences(Exchange.capability_surface(), current) do
      [] ->
        Mix.shell().info("capability surface ratchet passed")

      differences ->
        Mix.raise(
          "capability surface ratchet failed:\n" <>
            bullets(differences) <>
            "\n  Run mix ccxt.oracle_gate --update to explicitly re-pin reviewed changes."
        )
    end
  end

  defp authored_capability_surface do
    Map.new(Spec.exchanges(), fn venue ->
      {venue, venue |> Spec.load!() |> get_in(["capabilities", "has"])}
    end)
  end

  defp capability_surface_document(surface) do
    venues =
      surface
      |> Enum.sort()
      |> Enum.map(fn {venue, capabilities} -> {venue, ordered_object(capabilities)} end)
      |> Jason.OrderedObject.new()

    Jason.OrderedObject.new([{"version", @capability_surface_version}, {"venues", venues}])
  end

  defp ordered_object(map) do
    map
    |> Enum.sort()
    |> Jason.OrderedObject.new()
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

  defp check_critical_slots!(reports, today) do
    waivers = @ledger_path |> File.read!() |> OracleProvenance.critical_slot_waivers()

    case OracleProvenance.critical_slot_coverage_errors(reports, waivers, today) do
      [] -> report_critical_slot_passes(reports, waivers)
      errors -> Mix.raise("critical-slot hard gate failed:\n" <> bullets(errors))
    end
  end

  defp report_critical_slot_passes(reports, waivers) do
    waiver_counts = Enum.frequencies_by(waivers, & &1.venue)

    Enum.each(reports, fn report ->
      critical = Enum.count(report.slots, & &1.critical)
      waived = Map.get(waiver_counts, report.venue, 0)

      Mix.shell().info(
        "#{report.venue}: critical-slot hard gate passed (#{critical - waived} verified, #{waived} waived)"
      )
    end)
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
