defmodule Bourse.OptionReadiness do
  @moduledoc """
  Executable four-venue option readiness matrix (task 402).

  Collects timestamped evidence for Deribit, OKX, Bybit and Derive across
  option discovery, Greeks, portfolio reads, order lifecycle, preflight and
  hedge. Emits a durable report that links the captured evidence behind every
  cell and venue status.

  Classification of `client_broken` versus `venue_degraded` is an explicit AI
  judgment over the captured evidence — never an automatic disposition table.
  Pure mechanical rules still own empty books (`market_unavailable`), complete
  fill cycles (`fill_ready`), and proven create/fetch/cancel with a documented
  limitation (`order_lifecycle_ready`).

  Short-side sell → margin → buyback readiness is **orthogonal** to the scalar
  venue status: inject `short_evidence` through `run(evidence: …)` and read
  `capabilities.short_fill_ready` / `side_status.short`. It never becomes another
  winner in the single-status precedence table, so a venue may be both
  buy-fill-ready and short-fill-ready.
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.OptionReadiness.Baseline
  alias Bourse.OptionReadiness.Collector
  alias Bourse.OptionReadiness.Credentials
  alias Bourse.OptionReadiness.Report
  alias Bourse.OptionReadiness.VenueRow
  alias Bourse.OptionReadiness.Vocabulary

  @venues Vocabulary.venues()
  @cells Vocabulary.cells()
  @statuses [
    :fill_ready,
    :order_lifecycle_ready,
    :market_unavailable,
    :venue_degraded,
    :client_broken,
    :venue_unsupported,
    :account_mode_missing,
    :external_account_blocked
  ]
  @judgment_statuses [:client_broken, :venue_degraded]
  @default_report_dir "tmp/option_readiness"

  @type venue :: String.t()
  @type cell_name :: atom()
  @type status :: atom()
  @type judgment :: %{
          required(:status) => :client_broken | :venue_degraded,
          required(:rationale) => String.t(),
          required(:judged_at) => integer(),
          optional(:judge) => String.t()
        }

  @doc "Returns the four option venues covered by the matrix."
  @spec venues() :: [venue()]
  def venues, do: @venues

  @doc "Returns the ordered evidence cells collected per venue row."
  @spec cells() :: [cell_name()]
  def cells, do: @cells

  @doc "Returns the closed venue-status vocabulary."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Statuses that may only be assigned by explicit AI judgment."
  @spec judgment_statuses() :: [status()]
  def judgment_statuses, do: @judgment_statuses

  @doc """
  Runs the matrix for every venue and returns a durable report.

  Options:

    * `:venues` — subset of `venues/0` (default: all four)
    * `:observed_at` — wall-clock override (milliseconds)
    * `:report_dir` — report directory (default: `tmp/option_readiness`)
    * `:mutate` — when true, attempt create/fetch/cancel lifecycle probes
    * `:collect` — when false, only assemble injected `:evidence` maps
    * `:evidence` — `%{venue => %{cell => cell_map | Cell.t()}}` injection map.
      Optional top-level keys per venue: `fill_evidence`, `short_evidence`,
      `limitation`, `book`, `judgment`, `environment`, `host`.
    * `:judgments` — `%{venue => judgment()}` explicit AI judgments
    * `:exchanges` — `%{venue => Exchange.t()}` prebuilt exchanges (tests)
    * `:request_opts` — `%{venue => keyword()}` per-venue HTTP opts
  """
  @spec run(keyword()) :: {:ok, Report.t()} | {:error, Error.t()}
  def run(opts \\ []) when is_list(opts) do
    venues = Keyword.get(opts, :venues, @venues)
    observed_at = Keyword.get(opts, :observed_at, System.system_time(:millisecond))

    with :ok <- validate_venues(venues),
         {:ok, rows} <- collect_rows(venues, observed_at, opts) do
      report = Report.new(rows, observed_at, opts)
      maybe_write_report(report, opts)
    end
  end

  @doc """
  Collects one venue row. Missing credentials fail with exact setup instructions.
  """
  @spec collect_venue(venue(), keyword()) :: {:ok, VenueRow.t()} | {:error, Error.t()}
  def collect_venue(venue, opts \\ []) when is_binary(venue) and is_list(opts) do
    observed_at = Keyword.get(opts, :observed_at, System.system_time(:millisecond))

    with :ok <- validate_venues([venue]),
         {:ok, exchange, environment, request_opts} <- resolve_exchange(venue, opts) do
      Collector.collect(venue, exchange, environment, request_opts, observed_at, opts)
    end
  end

  @doc """
  Applies an explicit AI judgment of `client_broken` or `venue_degraded`.

  Mechanical collectors never assign those statuses. The judgment must cite a
  non-empty rationale and timestamp; empty rationale is rejected.
  """
  @spec apply_judgment(VenueRow.t(), judgment()) :: {:ok, VenueRow.t()} | {:error, Error.t()}
  def apply_judgment(%VenueRow{} = row, judgment) when is_map(judgment) do
    status = Map.get(judgment, :status)
    rationale = Map.get(judgment, :rationale)
    judged_at = Map.get(judgment, :judged_at)

    cond do
      status not in @judgment_statuses ->
        {:error,
         Error.exception(
           type: :invalid_parameters,
           message: "judgment status must be client_broken or venue_degraded, got #{inspect(status)}"
         )}

      not is_binary(rationale) or String.trim(rationale) == "" ->
        {:error, Error.exception(type: :invalid_parameters, message: "judgment requires a non-empty rationale")}

      not is_integer(judged_at) ->
        {:error, Error.exception(type: :invalid_parameters, message: "judgment requires judged_at milliseconds")}

      true ->
        {:ok,
         %{
           row
           | status: status,
             judgment: %{
               status: status,
               rationale: rationale,
               judged_at: judged_at,
               judge: Map.get(judgment, :judge)
             },
             status_reason: rationale
         }}
    end
  end

  @doc "Serializes a report to a JSON file and returns the absolute path."
  @spec write_report(Report.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_report(%Report{} = report, path) when is_binary(path) do
    Report.write(report, path)
  end

  @doc """
  Returns whether a report may become an accepted baseline.

  Any broken or untested cell rejects acceptance. Judgment-pending rows that
  still lack an assigned status also reject.
  """
  @spec accept_baseline?(Report.t()) :: boolean()
  def accept_baseline?(%Report{} = report), do: Baseline.accept?(report)

  @doc "Explains baseline rejection reasons (empty list when acceptable)."
  @spec baseline_rejection_reasons(Report.t()) :: [String.t()]
  def baseline_rejection_reasons(%Report{} = report), do: Baseline.rejection_reasons(report)

  @doc """
  Derives the mechanical venue status from cell evidence.

  Never returns `:client_broken` or `:venue_degraded` — those require
  `apply_judgment/2`. Returns `{:pending_judgment, reason}` when captured
  evidence needs human/AI classification.
  """
  @spec classify_status(VenueRow.t() | map()) :: {:ok, status()} | {:pending_judgment, String.t()}
  def classify_status(row), do: VenueRow.classify_status(row)

  defp collect_rows(venues, observed_at, opts) do
    venues
    |> Enum.reduce_while({:ok, []}, &collect_row(&1, &2, observed_at, opts))
    |> reverse_rows()
  end

  defp collect_row(venue, {:ok, acc}, observed_at, opts) do
    venue_opts =
      opts
      |> Keyword.put(:observed_at, observed_at)
      |> Keyword.put(:venue_evidence, get_in(opts, [:evidence, venue]) || %{})
      |> Keyword.put(:venue_judgment, get_in(opts, [:judgments, venue]))

    case collect_or_inject(venue, venue_opts) do
      {:ok, row} -> {:cont, {:ok, [row | acc]}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp reverse_rows({:ok, rows}), do: {:ok, Enum.reverse(rows)}
  defp reverse_rows({:error, _} = error), do: error

  defp collect_or_inject(venue, opts) do
    case Keyword.get(opts, :venue_judgment) do
      nil ->
        do_collect_or_inject(venue, opts)

      judgment ->
        with {:ok, row} <- do_collect_or_inject(venue, opts) do
          apply_judgment(row, judgment)
        end
    end
  end

  defp do_collect_or_inject(venue, opts) do
    evidence = Keyword.get(opts, :venue_evidence, %{})

    cond do
      Keyword.get(opts, :collect, true) == false ->
        VenueRow.from_injected(venue, evidence, injected_row_opts(venue, opts, evidence))

      map_size(evidence) > 0 and Keyword.get(opts, :prefer_injected, false) ->
        VenueRow.from_injected(venue, evidence, injected_row_opts(venue, opts, evidence))

      true ->
        collect_venue(venue, opts)
    end
  end

  defp injected_row_opts(venue, opts, evidence) do
    environment =
      Keyword.get(opts, :environment) ||
        Map.get(evidence, :environment) ||
        Map.get(evidence, "environment") ||
        Credentials.default_environment(venue)

    host = Keyword.get(opts, :host) || Map.get(evidence, :host) || Map.get(evidence, "host")

    opts
    |> Keyword.put(:environment, environment)
    |> Keyword.put(:host, host)
    |> Keyword.put_new(:observed_at, Keyword.get(opts, :observed_at, System.system_time(:millisecond)))
  end

  defp resolve_exchange(venue, opts) do
    case Keyword.get(opts, :exchanges) do
      %{^venue => %Exchange{} = exchange} ->
        environment = Keyword.get(opts, :environment, Credentials.default_environment(venue))
        request_opts = get_in(opts, [:request_opts, venue]) || Credentials.default_request_opts(venue)
        {:ok, exchange, environment, request_opts}

      _other ->
        Credentials.build_exchange(venue)
    end
  end

  defp maybe_write_report(report, opts) do
    dir = Keyword.get(opts, :report_dir, @default_report_dir)
    path = Path.join(dir, Report.default_filename(report))

    case Report.write(report, path) do
      {:ok, written} ->
        {:ok, %{report | path: written}}

      {:error, reason} ->
        {:error, Error.exception(type: :operation_failed, message: "write report failed: #{inspect(reason)}")}
    end
  end

  defp validate_venues(venues) when is_list(venues) do
    unknown = Enum.reject(venues, &(&1 in @venues))

    if unknown == [] do
      :ok
    else
      {:error,
       Error.exception(
         type: :invalid_parameters,
         message: "unknown option readiness venues: #{Enum.join(unknown, ", ")}"
       )}
    end
  end
end
