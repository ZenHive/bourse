defmodule Bourse.OptionReadiness.VenueRow do
  @moduledoc """
  One venue's readiness row: environment, cells, derived status and judgment.

  Buy-side fill readiness remains a single scalar `status` (`:fill_ready`,
  `:order_lifecycle_ready`, …). Short-side sell → margin → buyback readiness is
  an **orthogonal** capability (`capabilities.short_fill_ready` /
  `side_status.short`) so a venue may be both buy-fill-ready and
  short-fill-ready without collapsing the two into one precedence winner.
  """

  alias Bourse.OptionReadiness.Cell

  @cells Bourse.OptionReadiness.Vocabulary.cells()
  @fill_ready_evidence_keys [
    :fill,
    :hedge,
    :risk_check,
    :unwind,
    :zero_residual
  ]
  @lifecycle_evidence_keys [:create, :fetch, :cancel]
  @short_step_keys [:sell_fill, :short_margin, :buyback, :cleanup]
  @short_provenance_keys [:venue, :environment, :host, :instrument, :lifecycle_id]
  @margin_delta_tolerance 1.0e-9

  @type t :: %__MODULE__{
          venue: String.t(),
          environment: String.t() | nil,
          host: String.t() | nil,
          observed_at: integer(),
          status: atom() | nil,
          status_reason: String.t() | nil,
          cells: %{atom() => Cell.t()},
          fill_evidence: map() | nil,
          short_evidence: map() | nil,
          capabilities: %{optional(atom()) => boolean()},
          side_status: %{optional(atom()) => atom()},
          limitation: map() | nil,
          judgment: map() | nil,
          book: map() | nil
        }

  @enforce_keys [:venue, :observed_at, :cells]
  defstruct [
    :venue,
    :environment,
    :host,
    :observed_at,
    :status,
    :status_reason,
    :cells,
    :fill_evidence,
    :short_evidence,
    :limitation,
    :judgment,
    :book,
    capabilities: %{short_fill_ready: false},
    side_status: %{short: :not_ready}
  ]

  @doc "Builds a row from injected cell evidence (offline / report replay)."
  @spec from_injected(String.t(), map(), keyword()) :: {:ok, t()}
  def from_injected(venue, evidence, opts \\ []) when is_binary(venue) and is_map(evidence) do
    observed_at = Keyword.get(opts, :observed_at, System.system_time(:millisecond))
    environment = Keyword.get(opts, :environment) || evidence_value(evidence, :environment)
    host = Keyword.get(opts, :host) || evidence_value(evidence, :host)
    cell_evidence = evidence_value(evidence, :cells) || evidence
    cells = injected_cells(cell_evidence, observed_at, environment)

    short_evidence =
      normalize_short_evidence!(venue, environment, host, evidence_value(evidence, :short_evidence))

    row = %__MODULE__{
      venue: venue,
      environment: environment,
      host: host,
      observed_at: observed_at,
      cells: cells,
      fill_evidence: evidence_value(evidence, :fill_evidence),
      short_evidence: short_evidence,
      limitation: evidence_value(evidence, :limitation),
      book: evidence_value(evidence, :book),
      judgment: evidence_value(evidence, :judgment)
    }

    finalize(row)
  end

  @doc "Builds a row from already-collected cells and optional metadata."
  @spec new(String.t(), %{atom() => Cell.t()}, keyword()) :: {:ok, t()}
  def new(venue, cells, opts \\ []) when is_binary(venue) and is_map(cells) do
    observed_at = Keyword.get(opts, :observed_at, System.system_time(:millisecond))
    environment = Keyword.get(opts, :environment)
    host = Keyword.get(opts, :host)

    complete_cells =
      Map.new(@cells, fn name ->
        {name, Map.get(cells, name) || Cell.new(name, outcome: :untested, observed_at: observed_at)}
      end)

    short_evidence =
      normalize_short_evidence!(venue, environment, host, Keyword.get(opts, :short_evidence))

    row = %__MODULE__{
      venue: venue,
      environment: environment,
      host: host,
      observed_at: observed_at,
      cells: complete_cells,
      fill_evidence: Keyword.get(opts, :fill_evidence),
      short_evidence: short_evidence,
      limitation: Keyword.get(opts, :limitation),
      book: Keyword.get(opts, :book),
      judgment: Keyword.get(opts, :judgment)
    }

    finalize(row)
  end

  @doc "Derives status from evidence without inventing client_broken/venue_degraded."
  @spec classify_status(t() | map()) :: {:ok, atom()} | {:pending_judgment, String.t()}
  def classify_status(%__MODULE__{} = row), do: do_classify(row)

  def classify_status(%{} = map) do
    venue = Map.get(map, :venue) || Map.get(map, "venue")
    {:ok, row} = from_injected(venue, map)
    do_classify(row)
  end

  @doc "JSON-safe map representation with linked evidence per cell."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = row) do
    %{
      "venue" => row.venue,
      "environment" => row.environment,
      "host" => row.host,
      "observed_at" => row.observed_at,
      "status" => status_to_string(row.status),
      "status_reason" => row.status_reason,
      "cells" => Map.new(row.cells, fn {name, cell} -> {Atom.to_string(name), Cell.to_map(cell)} end),
      "fill_evidence" => Cell.stringify_keys(row.fill_evidence),
      "short_evidence" => Cell.stringify_keys(row.short_evidence),
      "capabilities" => Cell.stringify_keys(row.capabilities),
      "side_status" => Cell.stringify_keys(row.side_status),
      "limitation" => Cell.stringify_keys(row.limitation),
      "book" => Cell.stringify_keys(row.book),
      "judgment" => Cell.stringify_keys(row.judgment)
    }
  end

  @doc "True when every required fill-cycle artifact is timestamped and present."
  @spec fill_ready_evidence?(t()) :: boolean()
  def fill_ready_evidence?(%__MODULE__{fill_evidence: evidence}) when is_map(evidence) do
    timestamped? =
      Enum.all?(@fill_ready_evidence_keys, fn key ->
        entry = Map.get(evidence, key) || Map.get(evidence, Atom.to_string(key))
        timestamped_success?(entry)
      end)

    zero_residual = Map.get(evidence, :zero_residual) || Map.get(evidence, "zero_residual")
    timestamped? and zero_residual?(zero_residual)
  end

  def fill_ready_evidence?(%__MODULE__{}), do: false

  @doc """
  True when short-side sell → margin → buyback → baseline-relative cleanup is complete.

  Orthogonal to scalar `status` / buy-side `fill_ready`. Incomplete or non-ok
  short evidence never returns true.
  """
  @spec short_fill_ready_evidence?(t()) :: boolean()
  def short_fill_ready_evidence?(%__MODULE__{short_evidence: evidence} = row) when is_map(evidence) do
    short_provenance_ok?(evidence, row) and
      Enum.all?(@short_step_keys, fn key ->
        short_step_ready?(
          key,
          Map.get(evidence, key) || Map.get(evidence, Atom.to_string(key)),
          evidence
        )
      end) and
      short_steps_ordered?(evidence)
  end

  def short_fill_ready_evidence?(%__MODULE__{}), do: false

  @doc "True when create/fetch/cancel succeeded and a market/account limitation is recorded."
  @spec order_lifecycle_ready?(t()) :: boolean()
  def order_lifecycle_ready?(%__MODULE__{} = row) do
    lifecycle = Map.get(row.cells, :create_fetch_cancel)

    match?(%Cell{outcome: :ok, observed_at: ts} when is_integer(ts), lifecycle) and
      lifecycle_evidence?(lifecycle.evidence) and observed_limitation?(row.limitation)
  end

  @doc "True when the observed option book is empty / one-sided and recorded."
  @spec empty_book?(t()) :: boolean()
  def empty_book?(%__MODULE__{book: book}) when is_map(book) do
    two_sided = Map.get(book, :two_sided) || Map.get(book, "two_sided")
    empty? = Map.get(book, :empty) || Map.get(book, "empty")
    observed_at = Map.get(book, :observed_at) || Map.get(book, "observed_at")
    observed? = Map.get(book, :observed, Map.get(book, "observed", true))

    observed? == true and is_integer(observed_at) and (empty? == true or two_sided == false)
  end

  def empty_book?(%__MODULE__{}), do: false

  defp finalize(row) do
    short_ready? = short_fill_ready_evidence?(row)

    capabilities = %{short_fill_ready: short_ready?}
    side_status = %{short: if(short_ready?, do: :short_fill_ready, else: :not_ready)}
    row = %{row | capabilities: capabilities, side_status: side_status}

    case normalize_judgment(row.judgment) do
      %{status: status} = judgment when status in [:client_broken, :venue_degraded] ->
        if valid_judgment?(judgment) do
          {:ok, %{row | status: status, status_reason: judgment.rationale, judgment: judgment}}
        else
          {:ok,
           %{
             row
             | status: nil,
               status_reason: "invalid explicit judgment: non-empty rationale and judged_at milliseconds required",
               judgment: judgment
           }}
        end

      _other ->
        case do_classify(row) do
          {:ok, status} ->
            {:ok, %{row | status: status, status_reason: reason_for(status, row)}}

          {:pending_judgment, reason} ->
            {:ok, %{row | status: nil, status_reason: reason}}
        end
    end
  end

  defp normalize_judgment(nil), do: nil

  defp normalize_judgment(judgment) when is_map(judgment) do
    %{
      status: judgment |> evidence_value(:status) |> normalize_judgment_status(),
      rationale: evidence_value(judgment, :rationale),
      judged_at: evidence_value(judgment, :judged_at),
      judge: evidence_value(judgment, :judge)
    }
  end

  defp normalize_judgment_status("client_broken"), do: :client_broken
  defp normalize_judgment_status("venue_degraded"), do: :venue_degraded
  defp normalize_judgment_status(status), do: status

  # Scalar status precedence is buy-side only. Short readiness is orthogonal and
  # must never insert a winner here.
  defp do_classify(row) do
    cond do
      empty_book?(row) ->
        {:ok, :market_unavailable}

      fill_ready_evidence?(row) ->
        {:ok, :fill_ready}

      account_mode_missing?(row) ->
        {:ok, :account_mode_missing}

      external_account_blocked?(row) ->
        {:ok, :external_account_blocked}

      venue_unsupported?(row) ->
        {:ok, :venue_unsupported}

      # Proven create/fetch/cancel plus a documented limitation is
      # order_lifecycle_ready — never fill evidence.
      order_lifecycle_ready?(row) ->
        {:ok, :order_lifecycle_ready}

      needs_judgment?(row) ->
        {:pending_judgment, "captured evidence requires explicit AI judgment of client_broken vs venue_degraded"}

      true ->
        {:pending_judgment, "insufficient evidence to assign a terminal readiness status"}
    end
  end

  defp account_mode_missing?(%__MODULE__{limitation: %{"kind" => "account_mode_missing"}}), do: true
  defp account_mode_missing?(%__MODULE__{limitation: %{kind: :account_mode_missing}}), do: true
  defp account_mode_missing?(%__MODULE__{limitation: %{kind: "account_mode_missing"}}), do: true
  defp account_mode_missing?(_row), do: false

  defp external_account_blocked?(%__MODULE__{limitation: %{"kind" => "external_account_blocked"}}), do: true
  defp external_account_blocked?(%__MODULE__{limitation: %{kind: :external_account_blocked}}), do: true
  defp external_account_blocked?(%__MODULE__{limitation: %{kind: "external_account_blocked"}}), do: true
  defp external_account_blocked?(_row), do: false

  defp venue_unsupported?(%__MODULE__{cells: cells}) do
    Enum.any?(cells, fn
      {_name, %Cell{outcome: :unsupported}} -> true
      _ -> false
    end)
  end

  # Infrastructure cells with errors stay pending judgment — never auto-routed
  # by a disposition table into client_broken vs venue_degraded. Preflight/hedge
  # probe failures alone are incomplete evidence, not venue/client disposition.
  @judgment_cells [
    :discovery,
    :greeks,
    :balances,
    :positions,
    :open_orders,
    :create_fetch_cancel
  ]

  defp needs_judgment?(%__MODULE__{cells: cells}) do
    Enum.any?(@judgment_cells, fn name ->
      match?(%Cell{outcome: :error}, Map.get(cells, name))
    end)
  end

  defp reason_for(:fill_ready, _row),
    do: "timestamped fill, hedge, risk check, full unwind and zero residual evidence present"

  defp reason_for(:order_lifecycle_ready, row),
    do: "timestamped create/fetch/cancel plus limitation #{inspect(row.limitation)}"

  defp reason_for(:market_unavailable, row),
    do:
      "empty or one-sided option book at #{inspect(Map.get(row.book || %{}, :observed_at) || Map.get(row.book || %{}, "observed_at"))}"

  defp reason_for(:account_mode_missing, _row), do: "option account mode missing"
  defp reason_for(:external_account_blocked, _row), do: "external account restriction blocked option trading"
  defp reason_for(:venue_unsupported, _row), do: "venue does not support required option capability"

  defp timestamped_success?(entry) when is_map(entry) do
    ok? = Map.get(entry, :ok) || Map.get(entry, "ok")

    ts =
      Map.get(entry, :observed_at) || Map.get(entry, "observed_at") || Map.get(entry, :timestamp) ||
        Map.get(entry, "timestamp")

    ok? == true and is_integer(ts)
  end

  defp timestamped_success?(_), do: false

  defp zero_residual?(entry) when is_map(entry) do
    zero?(Map.get(entry, :open_orders, Map.get(entry, "open_orders"))) and
      zero?(Map.get(entry, :positions, Map.get(entry, "positions")))
  end

  defp zero_residual?(_entry), do: false

  defp zero?(0), do: true
  defp zero?([]), do: true
  defp zero?(_value), do: false

  defp lifecycle_evidence?(evidence) when is_map(evidence) do
    Enum.all?(@lifecycle_evidence_keys, fn key ->
      evidence
      |> then(&(Map.get(&1, key) || Map.get(&1, Atom.to_string(key))))
      |> timestamped_success?()
    end)
  end

  defp lifecycle_evidence?(_evidence), do: false

  defp observed_limitation?(limitation) when is_map(limitation) do
    kind = Map.get(limitation, :kind) || Map.get(limitation, "kind")
    observed_at = Map.get(limitation, :observed_at) || Map.get(limitation, "observed_at")

    kind in [
      :market_unavailable,
      "market_unavailable",
      :account_mode_missing,
      "account_mode_missing",
      :external_account_blocked,
      "external_account_blocked"
    ] and is_integer(observed_at)
  end

  defp observed_limitation?(_limitation), do: false

  defp valid_judgment?(judgment) do
    is_binary(judgment.rationale) and String.trim(judgment.rationale) != "" and is_integer(judgment.judged_at)
  end

  # ---------------------------------------------------------------------------
  # Short-side evidence (orthogonal capability)
  # ---------------------------------------------------------------------------

  defp normalize_short_evidence!(_venue, _environment, _host, nil), do: nil

  defp normalize_short_evidence!(venue, environment, host, evidence) when is_map(evidence) do
    validate_short_evidence_shape!(venue, environment, host, evidence)
    evidence
  end

  defp normalize_short_evidence!(_venue, _environment, _host, other) do
    raise ArgumentError, "short_evidence must be a map or nil, got: #{inspect(other)}"
  end

  defp validate_short_evidence_shape!(venue, environment, host, evidence) do
    validate_short_context!(:venue, venue, evidence_value(evidence, :venue))
    validate_short_context!(:environment, environment, evidence_value(evidence, :environment))
    validate_short_context!(:host, host, evidence_value(evidence, :host))
    Enum.each(@short_provenance_keys, &validate_short_provenance_field!(evidence, &1))
    Enum.each(@short_step_keys, &validate_optional_short_step!(evidence, &1))
    :ok
  end

  defp validate_short_context!(_key, _expected, nil), do: :ok
  defp validate_short_context!(_key, nil, _actual), do: :ok

  defp validate_short_context!(key, expected, actual) do
    if actual != expected do
      raise ArgumentError,
            "short_evidence #{key} #{inspect(actual)} does not match row #{key} #{inspect(expected)}"
    end

    :ok
  end

  defp validate_short_provenance_field!(evidence, key) do
    case evidence_value(evidence, key) do
      nil -> :ok
      value -> require_present_string!(key, value)
    end
  end

  defp require_present_string!(key, value) do
    if present_string?(value) do
      :ok
    else
      raise ArgumentError, "short_evidence.#{key} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp validate_optional_short_step!(evidence, key) do
    case Map.get(evidence, key) || Map.get(evidence, Atom.to_string(key)) do
      nil ->
        :ok

      step when is_map(step) ->
        validate_short_step_shape!(key, step)
        validate_short_step_context!(key, step, evidence)

      other ->
        raise ArgumentError, "short_evidence.#{key} must be a map, got: #{inspect(other)}"
    end
  end

  defp validate_short_step_shape!(key, step) do
    validate_short_step_ok!(key, Map.get(step, :ok, Map.get(step, "ok", :missing)))
    validate_short_step_timestamp!(key, step_timestamp(step))
    validate_optional_string_fields!(key, step, short_string_fields(key))
    validate_optional_number_fields!(key, step, short_number_fields(key))
    validate_optional_list_field!(key, step, :lifecycle_order_ids)
    validate_cleanup_state_shape!(key, step)
    :ok
  end

  defp validate_short_step_ok!(_key, :missing), do: :ok
  defp validate_short_step_ok!(_key, ok?) when is_boolean(ok?), do: :ok

  defp validate_short_step_ok!(key, ok?) do
    raise ArgumentError, "short_evidence.#{key}.ok must be a boolean, got: #{inspect(ok?)}"
  end

  defp validate_short_step_timestamp!(_key, nil), do: :ok
  defp validate_short_step_timestamp!(_key, ts) when is_integer(ts), do: :ok

  defp validate_short_step_timestamp!(key, ts) do
    raise ArgumentError, "short_evidence.#{key} timestamp must be an integer, got: #{inspect(ts)}"
  end

  defp step_timestamp(step) when is_map(step) do
    Map.get(step, :observed_at) || Map.get(step, "observed_at") || Map.get(step, :timestamp) ||
      Map.get(step, "timestamp")
  end

  defp step_timestamp(_step), do: nil

  defp short_string_fields(:sell_fill), do: [:instrument, :lifecycle_id, :order_id, :fill_id, :id, :side]

  defp short_string_fields(:buyback), do: [:instrument, :lifecycle_id, :order_id, :fill_id, :id, :side]

  defp short_string_fields(:short_margin), do: [:instrument, :lifecycle_id]
  defp short_string_fields(:cleanup), do: [:target_instrument, :lifecycle_id]

  defp short_number_fields(key) when key in [:sell_fill, :buyback], do: [:price]
  defp short_number_fields(:short_margin), do: [:before, :after, :delta, :margin_before, :margin_after, :margin_delta]
  defp short_number_fields(:cleanup), do: []

  defp validate_optional_string_fields!(step_key, step, fields) do
    Enum.each(fields, fn field ->
      case evidence_value(step, field) do
        nil -> :ok
        value -> require_present_string!("#{step_key}.#{field}", value)
      end
    end)
  end

  defp validate_optional_number_fields!(step_key, step, fields) do
    Enum.each(fields, fn field ->
      case evidence_value(step, field) do
        nil -> :ok
        value when is_number(value) -> :ok
        value -> raise ArgumentError, "short_evidence.#{step_key}.#{field} must be a number, got: #{inspect(value)}"
      end
    end)
  end

  defp validate_optional_list_field!(step_key, step, field) do
    case evidence_value(step, field) do
      nil ->
        :ok

      values when is_list(values) ->
        Enum.each(values, &require_present_string!("#{step_key}.#{field}", &1))

      value ->
        raise ArgumentError, "short_evidence.#{step_key}.#{field} must be a list, got: #{inspect(value)}"
    end
  end

  defp validate_cleanup_state_shape!(:cleanup, step) do
    Enum.each([:baseline, :after], fn state_key ->
      case evidence_value(step, state_key) do
        nil ->
          :ok

        state when is_map(state) ->
          validate_optional_number_fields!("cleanup.#{state_key}", state, [:target_position_size])
          validate_optional_list_field!("cleanup.#{state_key}", state, :target_open_order_ids)

        value ->
          raise ArgumentError,
                "short_evidence.cleanup.#{state_key} must be a map, got: #{inspect(value)}"
      end
    end)
  end

  defp validate_cleanup_state_shape!(_key, _step), do: :ok

  defp validate_short_step_context!(key, step, evidence) do
    instrument_key = if key == :cleanup, do: :target_instrument, else: :instrument

    validate_step_context_field!(
      key,
      instrument_key,
      evidence_value(evidence, :instrument),
      evidence_value(step, instrument_key)
    )

    validate_step_context_field!(
      key,
      :lifecycle_id,
      evidence_value(evidence, :lifecycle_id),
      evidence_value(step, :lifecycle_id)
    )
  end

  defp validate_step_context_field!(_step, _field, nil, _actual), do: :ok
  defp validate_step_context_field!(_step, _field, _expected, nil), do: :ok

  defp validate_step_context_field!(step, field, expected, actual) do
    if actual != expected do
      raise ArgumentError,
            "short_evidence.#{step}.#{field} #{inspect(actual)} does not match #{inspect(expected)}"
    end

    :ok
  end

  defp short_provenance_ok?(evidence, row) do
    evidence_value(evidence, :venue) == row.venue and
      evidence_value(evidence, :environment) == row.environment and
      evidence_value(evidence, :host) == row.host and
      Enum.all?(@short_provenance_keys, &present_string?(evidence_value(evidence, &1)))
  end

  defp short_step_ready?(:sell_fill, entry, evidence) do
    timestamped_success?(entry) and
      short_step_context_ok?(entry, evidence) and
      evidence_value(entry, :side) in [:sell, "sell"] and
      present_string?(order_identity(entry)) and
      price_present?(entry)
  end

  defp short_step_ready?(:buyback, entry, evidence) do
    timestamped_success?(entry) and
      short_step_context_ok?(entry, evidence) and
      evidence_value(entry, :side) in [:buy, "buy"] and
      present_string?(order_identity(entry)) and
      price_present?(entry)
  end

  defp short_step_ready?(:short_margin, entry, evidence) do
    timestamped_success?(entry) and
      short_step_context_ok?(entry, evidence) and
      margin_observation?(entry)
  end

  defp short_step_ready?(:cleanup, entry, evidence) do
    timestamped_success?(entry) and
      cleanup_context_ok?(entry, evidence) and
      baseline_relative_cleanup?(entry, evidence)
  end

  defp short_step_ready?(_key, _entry, _evidence), do: false

  defp short_step_context_ok?(entry, evidence) when is_map(entry) do
    evidence_value(entry, :instrument) == evidence_value(evidence, :instrument) and
      evidence_value(entry, :lifecycle_id) == evidence_value(evidence, :lifecycle_id)
  end

  defp cleanup_context_ok?(entry, evidence) when is_map(entry) do
    evidence_value(entry, :target_instrument) == evidence_value(evidence, :instrument) and
      evidence_value(entry, :lifecycle_id) == evidence_value(evidence, :lifecycle_id)
  end

  defp order_identity(entry) when is_map(entry) do
    Map.get(entry, :order_id) || Map.get(entry, "order_id") ||
      Map.get(entry, :fill_id) || Map.get(entry, "fill_id") ||
      Map.get(entry, :id) || Map.get(entry, "id")
  end

  defp price_present?(entry) when is_map(entry) do
    price = Map.get(entry, :price) || Map.get(entry, "price")
    is_number(price) and price > 0
  end

  defp margin_observation?(entry) when is_map(entry) do
    before = first_number(entry, [:before, :margin_before])
    after_value = first_number(entry, [:after, :margin_after])
    delta = first_number(entry, [:delta, :margin_delta])

    is_number(before) and is_number(after_value) and is_number(delta) and
      abs(after_value - before - delta) <= @margin_delta_tolerance
  end

  defp first_number(entry, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
    end)
  end

  defp short_steps_ordered?(evidence) do
    timestamps =
      Enum.map(@short_step_keys, fn key ->
        evidence
        |> evidence_value(key)
        |> step_timestamp()
      end)

    timestamps == Enum.sort(timestamps)
  end

  # Compare only the target instrument and lifecycle-created orders. Unrelated
  # positions and orders may remain when they were present before the cycle.
  defp baseline_relative_cleanup?(entry, evidence) when is_map(entry) do
    baseline = evidence_value(entry, :baseline)
    after_state = evidence_value(entry, :after)
    lifecycle_ids = evidence_value(entry, :lifecycle_order_ids)

    with true <- is_map(baseline) and is_map(after_state),
         true <- lifecycle_ids_match?(lifecycle_ids, evidence),
         baseline_position when is_number(baseline_position) <-
           evidence_value(baseline, :target_position_size),
         after_position when is_number(after_position) <- evidence_value(after_state, :target_position_size),
         baseline_orders when is_list(baseline_orders) <- evidence_value(baseline, :target_open_order_ids),
         after_orders when is_list(after_orders) <- evidence_value(after_state, :target_open_order_ids) do
      baseline_position == after_position and
        Enum.sort(baseline_orders) == Enum.sort(after_orders) and
        Enum.all?(baseline_orders ++ after_orders, &present_string?/1) and
        Enum.all?(lifecycle_ids, &(&1 not in after_orders))
    else
      _ -> false
    end
  end

  defp lifecycle_ids_match?(lifecycle_ids, evidence) when is_list(lifecycle_ids) do
    sell_id = evidence |> evidence_value(:sell_fill) |> order_identity()
    buyback_id = evidence |> evidence_value(:buyback) |> order_identity()

    present_string?(sell_id) and present_string?(buyback_id) and sell_id != buyback_id and
      Enum.sort(lifecycle_ids) == Enum.sort([sell_id, buyback_id])
  end

  defp lifecycle_ids_match?(_lifecycle_ids, _evidence), do: false

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp injected_cells(cell_evidence, observed_at, environment) do
    Map.new(@cells, fn name ->
      cell = cell_evidence |> evidence_value(name) |> injected_cell(name, observed_at, environment)
      {name, cell}
    end)
  end

  defp injected_cell(%Cell{} = cell, _name, _observed_at, _environment), do: cell

  defp injected_cell(raw, name, _observed_at, _environment) when is_map(raw) do
    Cell.from_map(Map.put(raw, "name", Atom.to_string(name)))
  end

  defp injected_cell(_raw, name, observed_at, environment) do
    Cell.new(name, outcome: :untested, observed_at: observed_at, environment: environment)
  end

  defp evidence_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp status_to_string(nil), do: nil
  defp status_to_string(status) when is_atom(status), do: Atom.to_string(status)
end
