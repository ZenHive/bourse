defmodule Bourse.OracleProvenance do
  @moduledoc """
  Derives and compares binary oracle provenance from committed reality evidence.
  """

  alias Bourse.OracleProvenance.Derivation

  @type ledger_entry :: %{heading: String.t(), slots: [{String.t(), String.t()}]}

  @doc "Parses explicit authored-slice markers from the open ledger section."
  @spec open_ledger_entries(String.t()) :: [ledger_entry()]
  def open_ledger_entries(markdown) when is_binary(markdown) do
    markdown
    |> open_ledger_section()
    |> then(&Regex.scan(~r/^###\s+([^\n]+)\n(.*?)(?=^###\s+|\z)/ms, &1, capture: :all_but_first))
    |> Enum.map(fn [heading, body] ->
      %{heading: heading, slots: ledger_slots(body)}
    end)
    |> Enum.reject(&Enum.empty?(&1.slots))
  end

  @doc "Returns open-ledger conflicts for semantically verified production claims."
  @spec tier_one_ledger_conflicts([Derivation.venue_report()], [ledger_entry()]) :: [String.t()]
  def tier_one_ledger_conflicts(reports, entries) when is_list(reports) and is_list(entries) do
    tier_one_slots =
      reports
      |> Enum.flat_map(fn report ->
        report.slots
        |> Enum.filter(&ledger_conflict_claim?/1)
        |> Enum.map(&{report.venue, &1.path})
      end)
      |> MapSet.new()

    for entry <- entries,
        slot <- entry.slots,
        MapSet.member?(tier_one_slots, slot) do
      {venue, path} = slot
      "#{venue}:#{path} is reality-verified but remains open in ledger entry #{inspect(entry.heading)}"
    end
  end

  @doc "Derives binary verified/unverified reports from committed reality."
  @spec binary_reports!(keyword()) :: [Derivation.venue_report()]
  def binary_reports!(opts \\ []), do: Derivation.reports!(opts)

  @doc "Builds the exact verified-slot baseline for the binary oracle gate."
  @spec binary_baseline([Derivation.venue_report()]) :: map()
  def binary_baseline(reports) when is_list(reports) do
    venues =
      Map.new(reports, fn report ->
        {report.venue, %{"verified_slots" => report.verified}}
      end)

    %{"version" => 1, "venues" => venues}
  end

  @doc "Returns exact-set differences between current binary reports and the committed baseline."
  @spec binary_baseline_differences([Derivation.venue_report()], map()) :: [String.t()]
  def binary_baseline_differences(reports, %{"version" => 1, "venues" => baseline_venues})
      when is_list(reports) and is_map(baseline_venues) do
    current_venues = Map.new(reports, &{&1.venue, MapSet.new(&1.verified)})
    baseline_venues = Map.new(baseline_venues, fn {venue, data} -> {venue, MapSet.new(data["verified_slots"] || [])} end)

    venue_names =
      current_venues
      |> Map.keys()
      |> Kernel.++(Map.keys(baseline_venues))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(venue_names, fn venue ->
      current = Map.get(current_venues, venue, MapSet.new())
      baseline = Map.get(baseline_venues, venue, MapSet.new())

      lost =
        baseline
        |> MapSet.difference(current)
        |> Enum.sort()
        |> Enum.map(&"#{venue}:#{&1} lost verified reality evidence")

      gained =
        current
        |> MapSet.difference(baseline)
        |> Enum.sort()
        |> Enum.map(&"#{venue}:#{&1} newly verified; update the oracle baseline")

      lost ++ gained
    end)
  end

  def binary_baseline_differences(_reports, baseline) do
    raise ArgumentError, "invalid oracle-gate baseline: #{inspect(baseline)}"
  end

  defp ledger_conflict_claim?(%{verified: true, semantic: true, host_classes: host_classes}) do
    :production in host_classes
  end

  defp ledger_conflict_claim?(_slot), do: false

  defp open_ledger_section(markdown) do
    case String.split(markdown, "\n## Open\n", parts: 2) do
      [_before, open_and_closed] -> open_and_closed |> String.split("\n## Closed\n", parts: 2) |> hd()
      _missing -> ""
    end
  end

  defp ledger_slots(body) do
    ~r/^- Authored slices:\s*(.+)$/m
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(fn marker ->
      ~r/`([^`:]+):([^`]+)`/
      |> Regex.scan(marker, capture: :all_but_first)
      |> Enum.map(fn [venue, path] -> {venue, path} end)
    end)
  end
end
