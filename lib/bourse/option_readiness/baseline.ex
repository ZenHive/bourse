defmodule Bourse.OptionReadiness.Baseline do
  @moduledoc """
  Acceptance rules for option-readiness baseline reports.

  A broken or untested cell can never become an accepted baseline. Venue rows
  still pending judgment (status nil) are also rejected until classified.
  """

  alias Bourse.OptionReadiness.Cell
  alias Bourse.OptionReadiness.Report
  alias Bourse.OptionReadiness.VenueRow

  @venues MapSet.new(Bourse.OptionReadiness.Vocabulary.venues())

  @doc "True when the report may be promoted to an accepted baseline."
  @spec accept?(Report.t()) :: boolean()
  def accept?(%Report{} = report), do: rejection_reasons(report) == []

  @doc "Human-readable rejection reasons; empty means acceptable."
  @spec rejection_reasons(Report.t()) :: [String.t()]
  def rejection_reasons(%Report{venues: venues}) do
    venues
    |> coverage_reasons()
    |> Kernel.++(Enum.flat_map(venues, &row_reasons/1))
    |> Enum.sort()
  end

  defp row_reasons(%VenueRow{} = row) do
    row_metadata_reasons(row) ++
      Enum.flat_map(row.cells, &cell_reasons(row.venue, &1)) ++
      status_reasons(row) ++ fill_reasons(row) ++ book_reasons(row) ++ lifecycle_fill_reasons(row)
  end

  defp row_metadata_reasons(row) do
    []
    |> maybe_add(not is_integer(row.observed_at), "#{row.venue}: row timestamp is missing")
    |> maybe_add(not present?(row.environment), "#{row.venue}: row environment is missing")
  end

  defp cell_reasons(venue, {name, cell}) do
    cond do
      Cell.untested?(cell) -> ["#{venue}.#{name}: untested cell cannot become an accepted baseline"]
      Cell.broken?(cell) -> ["#{venue}.#{name}: broken cell cannot become an accepted baseline"]
      not is_integer(cell.observed_at) -> ["#{venue}.#{name}: cell timestamp is missing"]
      not present?(cell.environment) -> ["#{venue}.#{name}: cell environment is missing"]
      true -> []
    end
  end

  defp status_reasons(%VenueRow{status: nil, venue: venue}),
    do: ["#{venue}: status unset (pending judgment or incomplete evidence)"]

  defp status_reasons(_row), do: []

  defp fill_reasons(%VenueRow{status: :fill_ready} = row) do
    if VenueRow.fill_ready_evidence?(row),
      do: [],
      else: ["#{row.venue}: fill_ready without complete fill/hedge/risk/unwind/residual evidence"]
  end

  defp fill_reasons(_row), do: []

  defp book_reasons(%VenueRow{status: :fill_ready} = row) do
    if VenueRow.empty_book?(row), do: ["#{row.venue}: empty option book cannot claim fill_ready"], else: []
  end

  defp book_reasons(_row), do: []

  defp lifecycle_fill_reasons(%VenueRow{status: :order_lifecycle_ready} = row) do
    fill_evidence = row.fill_evidence || %{}
    claimed? = Map.get(fill_evidence, :claimed_as_fill) == true or Map.get(fill_evidence, "claimed_as_fill") == true
    if claimed?, do: ["#{row.venue}: order_lifecycle_ready must not claim fill evidence"], else: []
  end

  defp lifecycle_fill_reasons(_row), do: []

  defp coverage_reasons(rows) do
    venues = Enum.map(rows, & &1.venue)
    actual = MapSet.new(venues)

    []
    |> maybe_add(actual != @venues, "baseline must contain exactly deribit, okx, bybit and derive")
    |> maybe_add(length(venues) != MapSet.size(actual), "baseline contains duplicate venue rows")
  end

  defp maybe_add(reasons, true, reason), do: [reason | reasons]
  defp maybe_add(reasons, false, _reason), do: reasons

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
