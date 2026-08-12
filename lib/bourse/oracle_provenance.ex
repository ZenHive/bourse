defmodule Bourse.OracleProvenance do
  @moduledoc """
  Derives and compares binary oracle provenance from committed reality evidence.
  """

  alias Bourse.OracleProvenance.Derivation
  alias Bourse.RecordedResponseFixtures
  alias Bourse.RecordedResponseFixtures.RequestCongruence

  @type ledger_entry :: %{heading: String.t(), slots: [{String.t(), String.t()}]}
  @type critical_slot_waiver :: %{
          date: Date.t(),
          path: String.t(),
          reviewed_at: Date.t() | nil,
          venue: String.t()
        }

  @waiver_marker "oracle-critical-slot-waiver"
  @waiver_review_marker "oracle-critical-slot-waiver-review"
  @waiver_pattern ~r/^\s*-\s+\[oracle-critical-slot-waiver\s+(\d{4}-\d{2}-\d{2})\]\s+`([^`:]+):([^`]+)`\s*$/
  @waiver_review_pattern ~r/^\s*-\s+\[oracle-critical-slot-waiver-review\s+(\d{4}-\d{2}-\d{2})\]\s*$/
  @waiver_review_days 30
  @waiver_renewal_path "docs/prod-verification-ledger.md"

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

  @doc "Parses explicit dated critical-slot waivers and their latest review from the open ledger section."
  @spec critical_slot_waivers(String.t()) :: [critical_slot_waiver()]
  def critical_slot_waivers(markdown) when is_binary(markdown) do
    lines = markdown |> open_ledger_section() |> String.split("\n")
    reviewed_at = latest_waiver_review!(lines)

    Enum.flat_map(lines, &parse_waiver_line!(&1, reviewed_at))
  end

  @doc "Returns hard-gate errors for critical slots without reality evidence or a valid waiver."
  @spec critical_slot_coverage_errors([Derivation.venue_report()], [critical_slot_waiver()]) :: [String.t()]
  def critical_slot_coverage_errors(reports, waivers) when is_list(reports) and is_list(waivers) do
    critical_slot_coverage_errors(reports, waivers, Date.utc_today())
  end

  @doc false
  @spec critical_slot_coverage_errors([Derivation.venue_report()], [critical_slot_waiver()], Date.t()) :: [String.t()]
  def critical_slot_coverage_errors(reports, waivers, today) when is_list(reports) and is_list(waivers) do
    slots = critical_slots_by_identity(reports)
    waiver_groups = Enum.group_by(waivers, &{&1.venue, &1.path})

    waiver_errors =
      Enum.flat_map(waiver_groups, fn {identity, entries} ->
        waiver_errors(identity, entries, Map.get(slots, identity), today)
      end)

    missing =
      for {{venue, path}, %{verified: false}} <- slots,
          !Map.has_key?(waiver_groups, {venue, path}) do
        "#{venue}:#{path} has no reality evidence or dated production-ledger waiver"
      end

    Enum.sort(waiver_errors ++ missing)
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
  def binary_reports!(opts \\ []) do
    congruence_opts =
      Enum.reject(
        [
          root: opts[:recording_root],
          manifest_path: opts[:recording_manifest]
        ],
        fn {_key, value} -> is_nil(value) end
      )

    provider_opts =
      Enum.reject(
        [
          root: opts[:provider_operation_root],
          manifest_path: opts[:provider_operation_manifest],
          plan_path: opts[:provider_operation_plan],
          authority_root: opts[:authority_root]
        ],
        fn {_key, value} -> is_nil(value) end
      )

    RequestCongruence.validate!(congruence_opts)
    RecordedResponseFixtures.validate_provider_operations!(provider_opts)

    opts
    |> Keyword.drop(
      ~w(recording_root recording_manifest provider_operation_root provider_operation_manifest provider_operation_plan)a
    )
    |> Derivation.reports!()
  end

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

  defp parse_waiver_line!(line, reviewed_at) do
    case Regex.run(@waiver_pattern, line, capture: :all_but_first) do
      [date, venue, path] ->
        [%{date: parse_waiver_date!(date, line), path: path, reviewed_at: reviewed_at, venue: venue}]

      nil ->
        reject_malformed_waiver!(line)
    end
  end

  defp latest_waiver_review!(lines) do
    lines
    |> Enum.flat_map(&parse_waiver_review_line!/1)
    |> Enum.max(Date, fn -> nil end)
  end

  defp parse_waiver_review_line!(line) do
    case Regex.run(@waiver_review_pattern, line, capture: :all_but_first) do
      [date] -> [parse_waiver_date!(date, line)]
      nil -> reject_malformed_waiver_review!(line)
    end
  end

  defp parse_waiver_date!(date, line) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> reject_future_date!(parsed, line)
      {:error, _reason} -> raise ArgumentError, "invalid critical-slot waiver date: #{line}"
    end
  end

  defp reject_future_date!(date, line) do
    if Date.after?(date, Date.utc_today()) do
      raise ArgumentError, "future-dated critical-slot waiver: #{line}"
    else
      date
    end
  end

  defp reject_malformed_waiver!(line) do
    if String.contains?(line, @waiver_marker) and not String.contains?(line, @waiver_review_marker) do
      raise ArgumentError, "malformed critical-slot waiver: #{line}"
    else
      []
    end
  end

  defp reject_malformed_waiver_review!(line) do
    if String.contains?(line, @waiver_review_marker) do
      raise ArgumentError, "malformed critical-slot waiver review: #{line}"
    else
      []
    end
  end

  defp critical_slots_by_identity(reports) do
    Map.new(for report <- reports, slot <- report.slots, slot.critical, do: {{report.venue, slot.path}, slot})
  end

  defp waiver_errors({venue, path}, entries, nil, today) do
    ["#{venue}:#{path} waiver names an unknown or non-critical slot"] ++
      duplicate_errors(venue, path, entries) ++ review_errors(venue, path, entries, today)
  end

  defp waiver_errors({venue, path}, entries, %{verified: true}, today) do
    ["#{venue}:#{path} is reality-verified but retains a critical-slot waiver"] ++
      duplicate_errors(venue, path, entries) ++ review_errors(venue, path, entries, today)
  end

  defp waiver_errors({venue, path}, entries, %{verified: false}, today) do
    duplicate_errors(venue, path, entries) ++ review_errors(venue, path, entries, today)
  end

  defp duplicate_errors(venue, path, entries) do
    if length(entries) == 1, do: [], else: ["#{venue}:#{path} has duplicate critical-slot waivers"]
  end

  defp review_errors(venue, path, [%{date: filed_at} = waiver], today) do
    reviewed_at = Map.get(waiver, :reviewed_at)

    cond do
      is_nil(reviewed_at) ->
        [renewal_error(venue, path, "has no waiver-set review acknowledgment")]

      Date.before?(reviewed_at, filed_at) ->
        [renewal_error(venue, path, "was filed after the latest waiver-set review")]

      Date.diff(today, reviewed_at) > @waiver_review_days ->
        [renewal_error(venue, path, "waiver review expired after #{@waiver_review_days} days")]

      true ->
        []
    end
  end

  defp review_errors(_venue, _path, _entries, _today), do: []

  defp renewal_error(venue, path, reason) do
    "#{venue}:#{path} #{reason}; recheck the blocker and append " <>
      "`[#{@waiver_review_marker} YYYY-MM-DD]` to #{@waiver_renewal_path}"
  end

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
