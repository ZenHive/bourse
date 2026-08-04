defmodule Bourse.OptionSaga do
  @moduledoc """
  Observable, caller-held execution saga for approved option plans.

  `new/2` converts a fresh `%Bourse.OptionProposal.Result{status: :approved}`
  into a journal with stable plan, leg, and client-order identifiers.
  `step/3` is pure: it returns at most one command and the journal state that
  must be retained *before* that command is executed. `execute/3` performs that
  single effect. `resume/4` is pure and records the exact observed outcome.

  A submission with an ambiguous outcome becomes `:unknown`. The next command
  is reconciliation, never another submission. Definite failures stop later
  legs and switch to cancellation of reversible acknowledged remainders.
  Filled exposure is reported as residual risk requiring caller action; it is
  never described as rolled back.
  """

  alias Bourse.Error
  alias Bourse.OptionProposal.Result
  alias Bourse.OptionSaga.Executor
  alias Bourse.OptionSaga.Journal
  alias Bourse.Order

  @default_max_approval_age_ms 60_000
  @client_id_plan_chars 12
  @client_id_leg_chars 12
  @plan_id_chars 16
  @ambiguous_error_types [:network_error, :exchange_not_available, :rate_limit_exceeded]
  @reconciling_states [:submitted, :unknown]
  @live_states [:accepted, :open, :partial]

  @type command_action :: :submit | :reconcile | :cancel
  @type command :: %{
          required(:id) => String.t(),
          required(:action) => command_action(),
          required(:plan_id) => String.t(),
          required(:approval_id) => String.t(),
          required(:leg_id) => term(),
          required(:execution_id) => String.t(),
          required(:client_order_id) => String.t(),
          required(:venue) => String.t(),
          required(:account) => term(),
          required(:symbol) => String.t(),
          required(:type) => String.t(),
          required(:side) => String.t(),
          required(:amount) => number(),
          optional(:price) => number() | nil,
          optional(:order_id) => String.t() | nil
        }

  @type outcome :: Executor.outcome()

  @doc """
  Creates a journal from a fresh approved preflight result.

  Options:

    * `:now_ms` — current time override
    * `:max_approval_age_ms` — maximum age before a new submission is refused
  """
  @spec new(Result.t(), keyword()) :: {:ok, Journal.t()} | {:error, Error.t()}
  def new(%Result{} = approval, opts \\ []) when is_list(opts) do
    now = now_ms(opts)
    max_age = Keyword.get(opts, :max_approval_age_ms, @default_max_approval_age_ms)

    with :ok <- validate_approval(approval, now, max_age),
         {:ok, legs} <- build_legs(approval.plan, now) do
      {:ok,
       %Journal{
         plan_id: plan_id(approval.plan),
         approval_id: approval_id(approval),
         approval_observed_at: approval.observed_at,
         max_approval_age_ms: max_age,
         status: :ready,
         legs: legs
       }}
    end
  end

  @doc """
  Emits the next command and the journal state that precedes its execution.

  New submissions re-check both approval identity and freshness before a
  command is returned. Reconciliation and compensation remain available after
  approval expiry because they reduce uncertainty or risk rather than add a
  new planned exposure.
  """
  @spec step(Journal.t(), Result.t(), keyword()) ::
          {:ok, command(), Journal.t()}
          | {:done, Journal.t()}
          | {:halted, Journal.t()}
          | {:error, Error.t()}
  def step(%Journal{} = journal, %Result{} = approval, opts \\ []) when is_list(opts) do
    next_step(journal, approval, now_ms(opts))
  end

  defp next_step(%Journal{status: :completed} = journal, _approval, _now), do: {:done, journal}
  defp next_step(%Journal{status: :halted} = journal, _approval, _now), do: {:halted, journal}

  defp next_step(journal, approval, now) do
    case reconciliation_leg(journal) do
      nil -> next_without_reconciliation(journal, approval, now)
      reconciliation -> emit_command(journal, reconciliation, :reconcile, now)
    end
  end

  defp next_without_reconciliation(journal, approval, now) do
    cancellation = cancellation_leg(journal)
    planned = Enum.find(journal.legs, &(&1.state == :planned))
    live = Enum.find(journal.legs, &(&1.state in @live_states))

    cond do
      journal.status == :compensating ->
        next_compensation(journal, cancellation, now)

      planned ->
        next_planned(journal, planned, approval, now)

      Enum.all?(journal.legs, &(&1.state in [:filled, :cancelled])) ->
        {:done, %{journal | status: :completed}}

      live ->
        emit_command(%{journal | status: :monitoring}, live, :reconcile, now)

      true ->
        {:halted, finalize_halt(journal)}
    end
  end

  defp next_compensation(journal, nil, _now), do: {:halted, finalize_halt(journal)}

  defp next_compensation(journal, cancellation, now) do
    journal = update_leg(journal, cancellation.execution_id, &Map.put(&1, :cancel_attempted?, true))
    emit_command(journal, cancellation, :cancel, now)
  end

  defp next_planned(journal, planned, approval, now) do
    case validate_same_fresh_approval(journal, approval, now) do
      :ok ->
        journal =
          journal
          |> transition(planned.execution_id, :submitted, now, %{client_order_id: planned.client_order_id})
          |> Map.put(:status, :running)

        emit_command(journal, planned, :submit, now)

      {:error, %Error{} = error} ->
        reject_new_submission(journal, planned, error, now)
    end
  end

  @doc "Executes exactly one command against caller-supplied exchange configurations."
  @spec execute(command(), Executor.exchanges(), keyword()) :: outcome()
  defdelegate execute(command, exchanges, opts \\ []), to: Executor

  @doc """
  Records one command outcome in the caller-held journal.

  Replaying the same command outcome is idempotent. An outcome for another
  plan, approval, or leg is rejected.
  """
  @spec resume(Journal.t(), command(), outcome(), keyword()) ::
          {:ok, Journal.t()} | {:error, Error.t()}
  def resume(%Journal{} = journal, command, outcome, opts \\ []) when is_map(command) and is_list(opts) do
    now = now_ms(opts)

    cond do
      command.id in journal.recorded_commands ->
        {:ok, journal}

      not command_matches?(journal, command) ->
        {:error, Error.invalid_parameters(message: "saga command does not match the caller-held journal")}

      true ->
        journal = %{journal | recorded_commands: [command.id | journal.recorded_commands]}
        {:ok, record_outcome(journal, command, outcome, now)}
    end
  end

  defp build_legs(plan, now) when is_map(plan) do
    rows =
      Enum.map(Map.get(plan, :legs, []), &Map.put(&1, :role, :option)) ++
        hedge_rows(Map.get(plan, :hedge))

    legs = Enum.map(rows, &build_leg(&1, plan, now))
    ids = Enum.map(legs, & &1.execution_id)

    if rows != [] and length(ids) == length(Enum.uniq(ids)) do
      {:ok, legs}
    else
      {:error, Error.invalid_parameters(message: "approved option plan requires unique executable legs")}
    end
  end

  defp build_legs(_plan, _now) do
    {:error, Error.invalid_parameters(message: "approved option result has no executable plan")}
  end

  defp hedge_rows(%{feasible?: true, quantity: quantity} = hedge) when is_number(quantity) and quantity > 0 do
    [
      %{
        id: {:hedge, hedge.candidate_id},
        role: :hedge,
        venue: hedge.venue,
        account: hedge.account,
        symbol: hedge.symbol,
        side: hedge.side,
        amount: quantity,
        price: nil,
        type: "market"
      }
    ]
  end

  defp hedge_rows(_hedge), do: []

  defp build_leg(row, plan, now) do
    plan_hash = digest(plan)
    leg_hash = digest({row.role, row.id, row.venue, row.account, row.symbol})

    %{
      id: row.id,
      execution_id: "leg-" <> String.slice(leg_hash, 0, @plan_id_chars),
      client_order_id:
        "cx-" <>
          String.slice(plan_hash, 0, @client_id_plan_chars) <>
          "-" <> String.slice(leg_hash, 0, @client_id_leg_chars),
      role: row.role,
      venue: to_string(row.venue),
      account: row.account,
      symbol: row.symbol,
      type: to_string(Map.get(row, :type, "limit")),
      side: to_string(row.side),
      amount: row.amount,
      price: Map.get(row, :price),
      order_id: nil,
      filled: nil,
      remaining: row.amount,
      state: :planned,
      acknowledged?: false,
      cancel_attempted?: false,
      cancel_retry_allowed?: false,
      transitions: [%{state: :planned, at: now}]
    }
  end

  defp validate_approval(%Result{status: :approved, observed_at: observed_at}, now, max_age)
       when is_integer(observed_at) and is_integer(now) and is_integer(max_age) and max_age >= 0 do
    age = now - observed_at

    if age >= 0 and age <= max_age do
      :ok
    else
      {:error, Error.invalid_parameters(message: "option preflight approval is stale or future-dated")}
    end
  end

  defp validate_approval(%Result{status: status}, _now, _max_age) do
    {:error, Error.invalid_parameters(message: "option saga requires an approved preflight result, got #{status}")}
  end

  defp validate_same_fresh_approval(journal, approval, now) do
    if approval_id(approval) == journal.approval_id do
      validate_approval(approval, now, journal.max_approval_age_ms)
    else
      {:error, Error.invalid_parameters(message: "option preflight approval changed after journal creation")}
    end
  end

  defp reject_new_submission(journal, planned, error, now) do
    if Enum.any?(journal.legs, & &1.acknowledged?) do
      command = %{leg_id: planned.id, execution_id: planned.execution_id}

      journal =
        journal
        |> transition(planned.execution_id, :failed, now, error)
        |> fail_journal(command, error, now)

      case cancellation_leg(journal) do
        nil ->
          {:halted, finalize_halt(journal)}

        cancellation ->
          journal = update_leg(journal, cancellation.execution_id, &Map.put(&1, :cancel_attempted?, true))
          emit_command(journal, cancellation, :cancel, now)
      end
    else
      {:error, error}
    end
  end

  defp reconciliation_leg(%Journal{status: :compensating} = journal) do
    Enum.find(journal.legs, fn leg ->
      leg.state in @reconciling_states or
        (leg.state in @live_states and is_nil(leg.order_id))
    end)
  end

  defp reconciliation_leg(journal), do: Enum.find(journal.legs, &(&1.state in @reconciling_states))

  defp cancellation_leg(journal) do
    Enum.find(journal.legs, fn leg ->
      leg.state in @live_states and is_binary(leg.order_id) and
        (not leg.cancel_attempted? or leg.cancel_retry_allowed?)
    end)
  end

  defp emit_command(journal, leg, action, now) do
    current_leg = Enum.find(journal.legs, &(&1.execution_id == leg.execution_id))

    command =
      current_leg
      |> Map.take([
        :client_order_id,
        :venue,
        :account,
        :symbol,
        :type,
        :side,
        :amount,
        :price,
        :order_id
      ])
      |> Map.merge(%{
        id: command_id(journal, current_leg, action, now),
        action: action,
        plan_id: journal.plan_id,
        approval_id: journal.approval_id,
        leg_id: current_leg.id,
        execution_id: current_leg.execution_id
      })

    {:ok, command, journal}
  end

  defp command_id(journal, leg, action, now) do
    "cmd-" <>
      String.slice(
        digest({journal.plan_id, leg.execution_id, action, now, length(journal.recorded_commands)}),
        0,
        @plan_id_chars
      )
  end

  defp command_matches?(journal, command) do
    command.plan_id == journal.plan_id and
      command.approval_id == journal.approval_id and
      Enum.any?(journal.legs, &(&1.execution_id == command.execution_id))
  end

  defp record_outcome(journal, %{action: :submit} = command, outcome, now) do
    case outcome do
      {:ok, %Order{} = order} ->
        journal
        |> acknowledge(command, order, now)
        |> apply_order(command, order, :submit, now)

      {:error, %Error{} = error} ->
        if ambiguous_error?(error) do
          mark_unknown(journal, command, error, now)
        else
          fail_leg(journal, command, error, now)
        end

      {:unknown, reason} ->
        mark_unknown(journal, command, reason, now)

      other ->
        fail_leg(journal, command, {:unexpected_submit_outcome, other}, now)
    end
  end

  defp record_outcome(journal, %{action: :reconcile} = command, outcome, now) do
    case outcome do
      {:ok, %Order{} = order} ->
        journal
        |> acknowledge(command, order, now)
        |> apply_order(command, order, :reconcile, now)

      {:not_found, detail} ->
        reconcile_absence(journal, command, detail, now)

      {:error, %Error{} = error} ->
        mark_unknown(journal, command, error, now)

      {:unknown, reason} ->
        mark_unknown(journal, command, reason, now)
    end
  end

  defp record_outcome(journal, %{action: :cancel} = command, outcome, now) do
    journal = record_compensation(journal, command, outcome, now)

    case outcome do
      {:ok, %Order{} = order} ->
        journal =
          journal
          |> acknowledge(command, order, now)
          |> apply_order(command, order, :cancel, now)

        if leg(journal, command).state == :cancelled do
          journal
        else
          mark_unknown(journal, command, :cancellation_requires_reconciliation, now)
        end

      {:error, %Error{} = error} ->
        if ambiguous_error?(error) do
          mark_unknown(journal, command, error, now)
        else
          update_residual_risk(journal)
        end

      {:not_found, detail} ->
        mark_unknown(journal, command, detail, now)

      {:unknown, reason} ->
        mark_unknown(journal, command, reason, now)
    end
  end

  defp acknowledge(journal, command, order, now) do
    already_acknowledged? = leg(journal, command).acknowledged?

    journal =
      update_leg(journal, command.execution_id, fn leg ->
        %{
          leg
          | acknowledged?: true,
            order_id: order.id || leg.order_id,
            filled: order.filled || leg.filled,
            remaining: order.remaining || leg.remaining
        }
      end)

    if already_acknowledged? do
      journal
    else
      transition(journal, command.execution_id, :accepted, now, order)
    end
  end

  defp apply_order(journal, command, order, context, now) do
    state = order_state(order, context)

    journal =
      journal
      |> update_leg(command.execution_id, fn leg ->
        %{
          leg
          | order_id: order.id || leg.order_id,
            filled: order.filled || leg.filled,
            remaining: order.remaining || leg.remaining,
            cancel_retry_allowed?: context == :reconcile and state in [:open, :partial]
        }
      end)
      |> transition(command.execution_id, state, now, order)

    cond do
      context == :submit and state in [:cancelled, :failed] ->
        fail_journal(journal, command, {:order_terminated_on_submission, state}, now)

      journal.failure ->
        update_residual_risk(journal)

      true ->
        journal
    end
  end

  defp order_state(%Order{status: status}, _context) when status in ["cancelled", "canceled"], do: :cancelled
  defp order_state(%Order{status: status}, _context) when status in ["closed", "filled"], do: :filled
  defp order_state(%Order{status: status}, _context) when status in ["rejected", "failed"], do: :failed

  defp order_state(%Order{} = order, context) do
    cond do
      Order.filled?(order) -> :filled
      is_number(order.filled) and order.filled > 0 -> :partial
      Order.open?(order) -> :open
      context == :submit -> :accepted
      true -> :unknown
    end
  end

  defp ambiguous_error?(%Error{type: type}), do: type in @ambiguous_error_types

  defp reconcile_absence(journal, command, detail, now) do
    current = leg(journal, command)

    if current.acknowledged? do
      mark_unknown(journal, command, {:acknowledged_order_not_found, detail}, now)
    else
      journal
      |> transition(command.execution_id, :planned, now, detail)
      |> update_leg(command.execution_id, &Map.put(&1, :cancel_retry_allowed?, false))
      |> Map.put(:status, :ready)
    end
  end

  defp mark_unknown(journal, command, detail, now) do
    journal
    |> transition(command.execution_id, :unknown, now, detail)
    |> Map.put(:status, if(journal.failure, do: :compensating, else: :monitoring))
    |> update_residual_risk()
  end

  defp fail_leg(journal, command, reason, now) do
    journal
    |> transition(command.execution_id, :failed, now, reason)
    |> fail_journal(command, reason, now)
  end

  defp fail_journal(journal, command, reason, now) do
    journal
    |> Map.put(:failure, %{
      leg_id: command.leg_id,
      execution_id: command.execution_id,
      reason: reason,
      at: now
    })
    |> Map.put(:status, :compensating)
    |> update_residual_risk()
  end

  defp record_compensation(journal, command, outcome, now) do
    result = %{
      command_id: command.id,
      leg_id: command.leg_id,
      execution_id: command.execution_id,
      order_id: command.order_id,
      outcome: outcome,
      at: now
    }

    %{journal | compensations: journal.compensations ++ [result]}
  end

  defp finalize_halt(journal) do
    journal
    |> Map.put(:status, :halted)
    |> update_residual_risk()
  end

  defp update_residual_risk(%Journal{failure: nil} = journal), do: journal

  defp update_residual_risk(journal) do
    risks =
      journal.legs
      |> Enum.filter(fn leg ->
        (is_number(leg.filled) and leg.filled > 0) or
          (leg.acknowledged? and leg.state in [:accepted, :open, :partial, :unknown])
      end)
      |> Enum.map(fn leg ->
        %{
          leg_id: leg.id,
          execution_id: leg.execution_id,
          venue: leg.venue,
          account: leg.account,
          symbol: leg.symbol,
          side: leg.side,
          filled: leg.filled || 0,
          remaining: leg.remaining,
          state: leg.state,
          action_required: :explicit_follow_up_required
        }
      end)

    %{journal | residual_risk: risks}
  end

  defp transition(journal, execution_id, state, now, detail) do
    update_leg(journal, execution_id, fn leg ->
      if leg.state == state do
        leg
      else
        transition = %{state: state, at: now, detail: detail}
        %{leg | state: state, transitions: leg.transitions ++ [transition]}
      end
    end)
  end

  defp update_leg(journal, execution_id, fun) do
    %{journal | legs: Enum.map(journal.legs, fn leg -> if leg.execution_id == execution_id, do: fun.(leg), else: leg end)}
  end

  defp leg(journal, command), do: Enum.find(journal.legs, &(&1.execution_id == command.execution_id))

  defp plan_id(plan), do: "opt-" <> String.slice(digest(plan), 0, @plan_id_chars)
  defp approval_id(approval), do: "approval-" <> digest(approval)

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp now_ms(opts), do: Keyword.get(opts, :now_ms, System.system_time(:millisecond))
end
