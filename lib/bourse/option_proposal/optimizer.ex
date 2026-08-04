defmodule Bourse.OptionProposal.Optimizer do
  @moduledoc """
  Exact bounded optimization for caller-approved option-risk instruments.

  The caller supplies every instrument, side, quantity bound, objective,
  weight, tolerance, hard limit, and tie-break rule. The optimizer searches
  only those finite venue-valid quantity grids. It returns a v1-shaped plan
  when feasible and a labelled diagnosis when no grid point satisfies every
  objective and hard limit.
  """

  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.OptionProposal.Hedge
  alias Bourse.OptionProposal.Projection
  alias Bourse.Unified.OptionQuantity

  @greeks [:delta, :gamma, :vega]
  @residual_limits [:residual_delta_abs, :residual_gamma_abs, :residual_vega_abs]
  @venue_policies [:same_only, :prefer_same_venue, :cross_allowed]
  @tie_breakers [:min_total_quantity, :min_active_instruments, :prefer_instrument_order]
  @convention_keys ~w(denomination unit bump_size time_basis)
  @default_max_combinations 250_000
  @score_decimal_places 12
  @comparison_epsilon 1.0e-12

  @type objective :: %{
          required(:target) => number(),
          required(:tolerance) => number(),
          required(:weight) => number(),
          required(:underlying) => String.t(),
          required(:unit_convention) => map()
        }

  @type instrument :: %{
          required(:id) => term(),
          required(:venue) => String.t(),
          required(:account) => term(),
          required(:symbol) => String.t(),
          required(:side) => String.t(),
          required(:market) => Market.t(),
          required(:quantity_limits) => %{required(:min) => number(), required(:max) => number()},
          optional(:greeks) => InstrumentGreeks.t(),
          optional(:kind) => atom() | String.t(),
          optional(:price) => number(),
          optional(:type) => String.t()
        }

  @type problem :: %{
          required(:instruments) => [instrument()],
          required(:objectives) => %{required(atom()) => objective()},
          required(:hard_limits) => map(),
          required(:tie_break_policy) => [atom()],
          required(:venue_policy) => atom(),
          optional(:baseline_contributions) => [map()],
          optional(:max_combinations) => pos_integer()
        }

  @doc """
  Solves one finite caller-authored option-risk problem.

  Option quantities are canonical base amounts and are checked with
  `Bourse.Unified.OptionQuantity`. At most one non-option delta hedge is accepted
  because the emitted `plan.hedge` deliberately retains the v1 singular shape.
  """
  @spec optimize(problem()) :: {:ok, map()} | {:error, term()}
  def optimize(problem) when is_map(problem) do
    with {:ok, objectives} <- validate_problem(problem),
         {:ok, instruments} <- prepare_instruments(problem.instruments, max_combinations(problem)),
         :ok <- validate_instrument_roles(instruments, objectives),
         :ok <- validate_venue_relationships(instruments, problem.venue_policy),
         {:ok, instruments} <- attach_option_terms(instruments),
         :ok <- validate_problem_units(instruments, objectives, baseline(problem)),
         {:ok, baseline} <- baseline_exposure(baseline(problem), objectives),
         :ok <- validate_tie_break_units(instruments, problem.tie_break_policy),
         :ok <- validate_search_size(instruments, max_combinations(problem)) do
      result = search(instruments, objectives, baseline, problem.hard_limits, problem.tie_break_policy)
      {:ok, build_result(result, instruments, objectives, problem)}
    end
  end

  def optimize(_problem), do: {:error, :invalid_optimization_problem}

  defp validate_problem(problem) do
    with :ok <- required_problem_fields(problem),
         :ok <- validate_instruments(problem.instruments),
         {:ok, objectives} <- validate_objectives(problem.objectives),
         :ok <- validate_hard_limits(problem.hard_limits, objectives),
         :ok <- validate_tie_break_policy(problem.tie_break_policy),
         :ok <- validate_venue_policy(problem.venue_policy),
         :ok <- validate_baseline(baseline(problem)),
         :ok <- validate_max_combinations(max_combinations(problem)) do
      {:ok, objectives}
    end
  end

  defp required_problem_fields(problem) do
    required = [:instruments, :objectives, :hard_limits, :tie_break_policy, :venue_policy]

    case Enum.reject(required, &Map.has_key?(problem, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_optimization_fields, missing}}
    end
  end

  defp validate_instruments(instruments) when is_list(instruments) and instruments != [] do
    ids = Enum.map(instruments, &Map.get(&1, :id))

    cond do
      Enum.any?(instruments, &(not is_map(&1))) -> {:error, :invalid_optimization_instrument}
      Enum.any?(ids, &is_nil/1) -> {:error, :missing_instrument_id}
      length(Enum.uniq(ids)) != length(ids) -> {:error, :duplicate_instrument_id}
      true -> :ok
    end
  end

  defp validate_instruments(_instruments), do: {:error, :optimization_requires_instruments}

  defp validate_objectives(objectives) when is_map(objectives) and map_size(objectives) > 0 do
    with :ok <- reject_unsupported_objectives(objectives) do
      @greeks
      |> Enum.reduce_while({:ok, %{}}, &reduce_objective(&1, &2, objectives))
      |> require_normalized_objectives()
    end
  end

  defp validate_objectives(_objectives), do: {:error, :optimization_requires_objectives}

  defp reduce_objective(greek, {:ok, acc}, objectives) do
    case fetch_key(objectives, greek) do
      nil -> {:cont, {:ok, acc}}
      objective -> validate_and_put_objective(greek, objective, acc)
    end
  end

  defp validate_and_put_objective(greek, objective, acc) do
    case validate_objective(greek, objective) do
      {:ok, normalized} -> {:cont, {:ok, Map.put(acc, greek, normalized)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp require_normalized_objectives({:ok, objectives}) when map_size(objectives) == 0,
    do: {:error, :unsupported_optimization_objectives}

  defp require_normalized_objectives(result), do: result

  defp validate_objective(greek, objective) when is_map(objective) do
    target = fetch_key(objective, :target)
    tolerance = fetch_key(objective, :tolerance)
    weight = fetch_key(objective, :weight)
    underlying = fetch_key(objective, :underlying)
    convention = fetch_key(objective, :unit_convention)

    if is_number(target) and is_number(tolerance) and tolerance >= 0 and is_number(weight) and
         weight > 0 and is_binary(underlying) and underlying != "" and valid_convention?(convention) do
      {:ok,
       %{
         greek: greek,
         target: target * 1.0,
         tolerance: tolerance * 1.0,
         weight: weight * 1.0,
         underlying: underlying,
         unit_convention: normalize_convention(convention)
       }}
    else
      {:error, {:invalid_objective, greek}}
    end
  end

  defp validate_objective(greek, _objective), do: {:error, {:invalid_objective, greek}}

  defp reject_unsupported_objectives(objectives) do
    unsupported = unsupported_key(objectives, @greeks)
    if unsupported, do: {:error, {:unsupported_optimization_objective, unsupported}}, else: :ok
  end

  defp validate_hard_limits(limits, objectives) when is_map(limits) do
    with :ok <- reject_unsupported_greek_limits(limits),
         :ok <- require_objectives_for_limits(limits, objectives),
         :ok <- validate_residual_limits(limits) do
      Enum.reduce_while(objectives, :ok, &reduce_greek_limit(&1, &2, limits))
    end
  end

  defp validate_hard_limits(_limits, _objectives), do: {:error, :optimization_requires_hard_limits}

  defp reduce_greek_limit({greek, _objective}, :ok, limits) do
    case validate_greek_limit(greek, fetch_key(limits, greek)) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp reject_unsupported_greek_limits(limits) do
    unsupported = unsupported_key(limits, @greeks ++ @residual_limits)

    if unsupported, do: {:error, {:unsupported_optimization_hard_limit, unsupported}}, else: :ok
  end

  defp require_objectives_for_limits(limits, objectives) do
    missing =
      Enum.find(@greeks, fn greek ->
        not Map.has_key?(objectives, greek) and
          (not is_nil(fetch_key(limits, greek)) or not is_nil(residual_limit(limits, greek)))
      end)

    if missing, do: {:error, {:hard_limit_without_objective, missing}}, else: :ok
  end

  defp validate_residual_limits(limits) do
    invalid =
      Enum.find(@greeks, fn greek ->
        case residual_limit(limits, greek) do
          nil -> false
          value -> not is_number(value) or value < 0
        end
      end)

    if invalid, do: {:error, {:invalid_residual_hard_limit, invalid}}, else: :ok
  end

  defp validate_greek_limit(_greek, nil), do: :ok

  defp validate_greek_limit(_greek, limit) when is_number(limit) and limit >= 0, do: :ok

  defp validate_greek_limit(greek, limit) when is_map(limit) do
    values = Enum.map([:min, :max, :max_abs], &fetch_key(limit, &1))
    populated = Enum.reject(values, &is_nil/1)
    minimum = fetch_key(limit, :min)
    maximum = fetch_key(limit, :max)
    maximum_absolute = fetch_key(limit, :max_abs)

    cond do
      Enum.any?(populated, &(not is_number(&1))) -> {:error, {:invalid_hard_limit, greek}}
      is_number(maximum_absolute) and maximum_absolute < 0 -> {:error, {:invalid_hard_limit, greek}}
      is_number(minimum) and is_number(maximum) and minimum > maximum -> {:error, {:invalid_hard_limit, greek}}
      true -> :ok
    end
  end

  defp validate_greek_limit(greek, _limit), do: {:error, {:invalid_hard_limit, greek}}

  defp validate_tie_break_policy(policy) when is_list(policy) and policy != [] do
    case Enum.find(policy, &(&1 not in @tie_breakers)) do
      nil -> if(length(Enum.uniq(policy)) == length(policy), do: :ok, else: {:error, :duplicate_tie_breaker})
      invalid -> {:error, {:invalid_tie_breaker, invalid}}
    end
  end

  defp validate_tie_break_policy(_policy), do: {:error, :tie_break_policy_required}

  defp validate_venue_policy(policy) when policy in @venue_policies, do: :ok
  defp validate_venue_policy(policy), do: {:error, {:invalid_venue_policy, policy}}

  defp validate_baseline(contributions) when is_list(contributions), do: :ok
  defp validate_baseline(_contributions), do: {:error, :invalid_baseline_contributions}

  defp validate_max_combinations(value) when is_integer(value) and value > 0, do: :ok
  defp validate_max_combinations(_value), do: {:error, :invalid_max_combinations}

  defp prepare_instruments(instruments, maximum_combinations) do
    instruments
    |> Enum.reduce_while({:ok, []}, fn instrument, {:ok, acc} ->
      case prepare_instrument(instrument, maximum_combinations) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, prepared} -> validate_prepared_instruments(Enum.reverse(prepared))
      error -> error
    end)
  end

  defp prepare_instrument(
         %{
           id: id,
           venue: venue,
           account: account,
           symbol: symbol,
           side: side,
           market: %Market{} = market,
           quantity_limits: limits
         } = instrument,
         maximum_combinations
       )
       when is_binary(venue) and not is_nil(account) and is_binary(symbol) and side in ["buy", "sell"] do
    role = if market.option == true or market.type == "option", do: :option, else: :hedge

    with :ok <- active_market(market),
         {:ok, terms} <- instrument_terms(role, instrument),
         {:ok, counts} <- quantity_counts(limits, terms.amount_step, market, role, maximum_combinations) do
      {:ok,
       Map.merge(terms, %{
         id: id,
         venue: venue,
         account: account,
         symbol: symbol,
         side: side,
         sign: side_sign(side),
         role: role,
         source: instrument,
         counts: counts
       })}
    end
  end

  defp prepare_instrument(%{side: side}, _maximum_combinations) when side not in ["buy", "sell"],
    do: {:error, {:invalid_instrument_side, side}}

  defp prepare_instrument(_instrument, _maximum_combinations), do: {:error, :invalid_optimization_instrument}

  defp active_market(%Market{active: false}), do: {:error, :inactive_market}
  defp active_market(%Market{}), do: :ok

  defp instrument_terms(:option, %{greeks: %InstrumentGreeks{}, market: %Market{} = market}) do
    with {:ok, step} <- option_amount_step(market),
         :ok <- validate_option_quantity(market, step) do
      {:ok,
       %{
         market: market,
         amount_step: step,
         quantity_unit: "base",
         coefficients: %{},
         unit_conventions: %{}
       }}
    end
  end

  defp instrument_terms(:option, _instrument), do: {:error, :option_instrument_requires_greeks}

  defp instrument_terms(:hedge, instrument) do
    case Hedge.candidate_terms(instrument) do
      {:ok, terms} ->
        {:ok,
         Map.merge(terms, %{
           quantity_unit: if(terms.market.spot == true, do: "base", else: "contracts"),
           coefficients: %{delta: side_sign(instrument.side) * terms.delta_per_unit},
           unit_conventions: %{delta: normalize_convention(Projection.delta_convention())}
         })}

      {:error, _reason} = error ->
        error
    end
  end

  defp option_amount_step(%Market{quantity_unit: "base", precision: precision}) when is_map(precision) do
    case fetch_key(precision, :amount) do
      step when is_number(step) and step > 0 -> {:ok, step * 1.0}
      _step -> {:error, :missing_amount_precision}
    end
  end

  defp option_amount_step(%Market{}), do: {:error, :missing_option_quantity_semantics}

  defp validate_option_quantity(market, amount) do
    case OptionQuantity.to_native(market, amount) do
      {:ok, _native} -> :ok
      {:error, error} -> {:error, {:quantity_not_representable, error}}
    end
  end

  defp quantity_counts(limits, step, market, role, maximum_combinations) when is_map(limits) do
    minimum = fetch_key(limits, :min)
    maximum = fetch_key(limits, :max)

    with :ok <- validate_quantity_bounds(minimum, maximum),
         {:ok, step_decimal} <- decimal(step),
         {:ok, min_decimal} <- decimal(minimum),
         {:ok, max_decimal} <- decimal(maximum),
         :ok <- validate_bound_grid(min_decimal, max_decimal, step_decimal),
         :ok <- validate_market_bounds(minimum, maximum, market),
         :ok <- validate_option_bounds(role, market, minimum, maximum) do
      build_counts(min_decimal, max_decimal, step_decimal, market, maximum_combinations)
    end
  end

  defp quantity_counts(_limits, _step, _market, _role, _maximum_combinations), do: {:error, :invalid_quantity_limits}

  defp validate_quantity_bounds(minimum, maximum)
       when is_number(minimum) and is_number(maximum) and minimum >= 0 and maximum >= minimum, do: :ok

  defp validate_quantity_bounds(_minimum, _maximum), do: {:error, :invalid_quantity_limits}

  defp validate_bound_grid(minimum, maximum, step) do
    if grid_value?(minimum, step) and grid_value?(maximum, step),
      do: :ok,
      else: {:error, :quantity_bound_not_representable}
  end

  defp validate_market_bounds(minimum, maximum, market) do
    venue_minimum = amount_limit(market, :min)
    venue_maximum = amount_limit(market, :max)

    cond do
      minimum > 0 and is_number(venue_minimum) and minimum < venue_minimum ->
        {:error, {:quantity_below_venue_minimum, venue_minimum}}

      is_number(venue_maximum) and maximum > venue_maximum ->
        {:error, {:quantity_above_venue_maximum, venue_maximum}}

      true ->
        :ok
    end
  end

  defp validate_option_bounds(:option, market, minimum, maximum) do
    Enum.reduce_while([minimum, maximum], :ok, &reduce_option_bound(&1, &2, market))
  end

  defp validate_option_bounds(:hedge, _market, _minimum, _maximum), do: :ok

  defp reduce_option_bound(0, :ok, _market), do: {:cont, :ok}
  defp reduce_option_bound(+0.0, :ok, _market), do: {:cont, :ok}

  defp reduce_option_bound(amount, :ok, market) do
    case validate_option_quantity(market, amount) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp build_counts(minimum, maximum, step, market, maximum_combinations) do
    max_count = decimal_integer!(Decimal.div(maximum, step))

    {zero?, first_count} =
      if Decimal.equal?(minimum, 0) do
        {true, max(1, venue_minimum_count(market, step))}
      else
        {false, decimal_integer!(Decimal.div(minimum, step))}
      end

    combinations = max(max_count - first_count + 1, 0) + if(zero?, do: 1, else: 0)

    if combinations <= maximum_combinations do
      nonzero_counts = integer_range(first_count, max_count)
      {:ok, if(zero?, do: [0 | nonzero_counts], else: nonzero_counts)}
    else
      {:error, {:search_space_too_large, %{combinations: combinations, limit: maximum_combinations}}}
    end
  end

  defp venue_minimum_count(market, step) do
    case amount_limit(market, :min) do
      minimum when is_number(minimum) and minimum > 0 ->
        {:ok, minimum_decimal} = decimal(minimum)
        minimum_decimal |> Decimal.div(step) |> Decimal.round(0, :ceiling) |> decimal_integer!()

      _minimum ->
        1
    end
  end

  defp integer_range(first, last) when first <= last, do: Enum.to_list(first..last)
  defp integer_range(_first, _last), do: []

  defp amount_limit(%Market{limits: limits}, key) when is_map(limits) do
    limits
    |> fetch_key(:amount)
    |> case do
      amount when is_map(amount) -> fetch_key(amount, key)
      _amount -> nil
    end
  end

  defp amount_limit(%Market{}, _key), do: nil

  defp validate_prepared_instruments(instruments) do
    hedge_count = Enum.count(instruments, &(&1.role == :hedge))
    underlyings = instruments |> Enum.map(& &1.market.base) |> Enum.uniq()

    cond do
      hedge_count > 1 -> {:error, :multiple_hedges_break_v1_plan_shape}
      Enum.any?(underlyings, &(not is_binary(&1) or &1 == "")) -> {:error, :missing_underlying}
      length(underlyings) > 1 -> {:error, {:mixed_underlyings, Enum.sort(underlyings)}}
      true -> {:ok, instruments}
    end
  end

  defp validate_instrument_roles(instruments, objectives) do
    if Enum.any?(instruments, &(&1.role == :hedge)) and not Map.has_key?(objectives, :delta),
      do: {:error, :delta_hedge_requires_delta_objective},
      else: :ok
  end

  defp validate_venue_relationships(instruments, :same_only) do
    option_venues =
      instruments
      |> Enum.filter(&(&1.role == :option))
      |> MapSet.new(& &1.venue)

    hedge = Enum.find(instruments, &(&1.role == :hedge))

    if hedge && MapSet.size(option_venues) > 0 && not MapSet.member?(option_venues, hedge.venue),
      do: {:error, :no_same_venue_hedge_candidate},
      else: :ok
  end

  defp validate_venue_relationships(_instruments, _policy), do: :ok

  defp attach_option_terms(instruments) do
    options = Enum.filter(instruments, &(&1.role == :option))

    case options do
      [] ->
        {:ok, instruments}

      _options ->
        legs = Enum.map(options, &step_leg/1)

        case Projection.project_legs(legs) do
          {:ok, %{legs: effects}} ->
            by_id = Map.new(effects, &{&1.id, &1})
            {:ok, Enum.map(instruments, &attach_option_effect(&1, by_id))}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp step_leg(instrument) do
    instrument.source
    |> Map.put(:amount, instrument.amount_step)
    |> Map.put(:type, Map.get(instrument.source, :type, "limit"))
  end

  defp attach_option_effect(%{role: :option} = instrument, by_id) do
    effect = Map.fetch!(by_id, instrument.id)

    coefficients =
      Map.new(@greeks, fn greek ->
        {greek, Map.fetch!(effect.greeks, greek) / instrument.amount_step}
      end)

    %{instrument | coefficients: coefficients, unit_conventions: effect.unit_conventions}
  end

  defp attach_option_effect(instrument, _by_id), do: instrument

  defp validate_problem_units(instruments, objectives, contributions) do
    Enum.reduce_while(objectives, :ok, fn {greek, objective}, :ok ->
      with :ok <- validate_instrument_units(instruments, greek, objective),
           :ok <- validate_baseline_units(contributions, greek, objective) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_instrument_units(instruments, greek, objective) do
    Enum.reduce_while(instruments, :ok, fn instrument, :ok ->
      convention = Map.get(instrument.unit_conventions, greek)

      cond do
        instrument.market.base != objective.underlying ->
          {:halt, {:error, {:incompatible_objective_underlying, greek, instrument.id}}}

        is_map(convention) and normalize_convention(convention) != objective.unit_convention ->
          {:halt, {:error, {:incompatible_objective_unit, greek, instrument.id}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_baseline_units(contributions, greek, objective) do
    contributions
    |> Enum.filter(&(Map.get(&1, :underlying) == objective.underlying))
    |> Enum.reduce_while(:ok, &reduce_baseline_unit(&1, &2, greek, objective))
  end

  defp reduce_baseline_unit(contribution, :ok, greek, objective) do
    case get_in(contribution, [:greeks, greek]) do
      nil ->
        {:cont, :ok}

      %{value: value, unit_convention: convention} when is_number(value) and is_map(convention) ->
        compare_baseline_unit(convention, greek, objective)

      _risk ->
        {:halt, {:error, {:invalid_baseline_contribution, greek}}}
    end
  end

  defp compare_baseline_unit(convention, greek, objective) do
    if normalize_convention(convention) == objective.unit_convention,
      do: {:cont, :ok},
      else: {:halt, {:error, {:incompatible_baseline_unit, greek}}}
  end

  defp baseline_exposure(contributions, objectives) do
    Enum.reduce_while(objectives, {:ok, %{}}, fn {greek, objective}, {:ok, acc} ->
      case sum_baseline(contributions, greek, objective.underlying) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, greek, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sum_baseline(contributions, greek, underlying) do
    contributions
    |> Enum.filter(&(Map.get(&1, :underlying) == underlying))
    |> Enum.reduce_while({:ok, 0.0}, fn contribution, {:ok, total} ->
      case get_in(contribution, [:greeks, greek]) do
        nil -> {:cont, {:ok, total}}
        %{value: value} when is_number(value) -> {:cont, {:ok, total + value}}
        _risk -> {:halt, {:error, {:invalid_baseline_contribution, greek}}}
      end
    end)
  end

  defp validate_tie_break_units(instruments, policy) do
    units = instruments |> Enum.map(& &1.quantity_unit) |> Enum.uniq()

    if :min_total_quantity in policy and length(units) > 1,
      do: {:error, {:incompatible_tie_break_quantity_units, units}},
      else: :ok
  end

  defp validate_search_size(instruments, maximum) do
    combinations = Enum.reduce(instruments, 1, &(&2 * length(&1.counts)))

    if combinations <= maximum,
      do: :ok,
      else: {:error, {:search_space_too_large, %{combinations: combinations, limit: maximum}}}
  end

  defp search(instruments, objectives, baseline, hard_limits, tie_break_policy) do
    initial = %{best: nil, closest: nil, evaluated: 0}

    enumerate(instruments, [], initial, fn counts, state ->
      evaluation = evaluate(instruments, Enum.reverse(counts), objectives, baseline, hard_limits)
      update_search(state, evaluation, instruments, tie_break_policy)
    end)
  end

  defp enumerate([], counts, state, function), do: function.(counts, state)

  defp enumerate([instrument | rest], counts, state, function) do
    Enum.reduce(instrument.counts, state, fn count, next_state ->
      enumerate(rest, [count | counts], next_state, function)
    end)
  end

  defp evaluate(instruments, counts, objectives, baseline, hard_limits) do
    amounts = Enum.zip_with(instruments, counts, &grid_amount(&2, &1.amount_step))
    exposures = apply_allocations(instruments, amounts, baseline)
    residuals = Map.new(objectives, fn {greek, objective} -> {greek, exposures[greek] - objective.target} end)
    objective_violations = objective_violations(residuals, objectives)
    hard_limit_breaches = hard_limit_breaches(exposures, residuals, hard_limits, objectives)

    %{
      counts: counts,
      amounts: amounts,
      exposures: exposures,
      residuals: residuals,
      score: objective_score(residuals, objectives),
      objective_violations: objective_violations,
      hard_limit_breaches: hard_limit_breaches,
      feasible?: objective_violations == [] and hard_limit_breaches == []
    }
  end

  defp apply_allocations(instruments, amounts, baseline) do
    instruments
    |> Enum.zip(amounts)
    |> Enum.reduce(baseline, fn {instrument, amount}, exposures ->
      Map.new(exposures, fn {greek, value} ->
        coefficient = Map.get(instrument.coefficients, greek, 0.0)
        {greek, value + amount * coefficient}
      end)
    end)
  end

  defp objective_violations(residuals, objectives) do
    Enum.flat_map(objectives, fn {greek, objective} ->
      residual = residuals[greek]

      if abs(residual) <= objective.tolerance + @comparison_epsilon do
        []
      else
        [%{greek: greek, residual: residual, tolerance: objective.tolerance}]
      end
    end)
  end

  defp hard_limit_breaches(exposures, residuals, hard_limits, objectives) do
    Enum.flat_map(objectives, fn {greek, _objective} ->
      value_breaches(greek, exposures[greek], fetch_key(hard_limits, greek)) ++
        residual_breaches(greek, residuals[greek], residual_limit(hard_limits, greek))
    end)
  end

  defp value_breaches(_greek, _value, nil), do: []

  defp value_breaches(greek, value, limit) when is_number(limit) do
    maybe_abs_breach([], greek, value, limit)
  end

  defp value_breaches(greek, value, limit) do
    []
    |> maybe_breach(greek, value, :min, fetch_key(limit, :min), &(&1 < &2 - @comparison_epsilon))
    |> maybe_breach(greek, value, :max, fetch_key(limit, :max), &(&1 > &2 + @comparison_epsilon))
    |> maybe_abs_breach(greek, value, fetch_key(limit, :max_abs))
  end

  defp residual_breaches(_greek, _residual, nil), do: []

  defp residual_breaches(greek, residual, limit) do
    if abs(residual) > limit + @comparison_epsilon,
      do: [breach(greek, :residual_max_abs, residual, limit)],
      else: []
  end

  defp maybe_breach(breaches, _greek, _value, _kind, nil, _predicate), do: breaches

  defp maybe_breach(breaches, greek, value, kind, limit, predicate) do
    if predicate.(value, limit),
      do: [breach(greek, kind, value, limit) | breaches],
      else: breaches
  end

  defp maybe_abs_breach(breaches, _greek, _value, nil), do: breaches

  defp maybe_abs_breach(breaches, greek, value, limit) do
    if abs(value) > limit + @comparison_epsilon,
      do: [breach(greek, :max_abs, value, limit) | breaches],
      else: breaches
  end

  defp breach(greek, kind, value, limit) do
    %{greek: greek, kind: kind, value: value, limit: limit}
  end

  defp objective_score(residuals, objectives) do
    Enum.reduce(objectives, 0.0, fn {greek, objective}, score ->
      score + objective.weight * abs(residuals[greek])
    end)
  end

  defp update_search(state, evaluation, instruments, tie_break_policy) do
    closest = pick_better(state.closest, evaluation, instruments, tie_break_policy, :diagnostic)

    best =
      if evaluation.feasible?,
        do: pick_better(state.best, evaluation, instruments, tie_break_policy, :feasible),
        else: state.best

    %{state | best: best, closest: closest, evaluated: state.evaluated + 1}
  end

  defp pick_better(nil, candidate, _instruments, _policy, _mode), do: candidate

  defp pick_better(existing, candidate, instruments, policy, mode) do
    if evaluation_key(candidate, instruments, policy, mode) <
         evaluation_key(existing, instruments, policy, mode),
       do: candidate,
       else: existing
  end

  defp evaluation_key(evaluation, instruments, policy, mode) do
    diagnostic_prefix =
      if mode == :diagnostic,
        do: [length(evaluation.objective_violations) + length(evaluation.hard_limit_breaches)],
        else: []

    diagnostic_prefix ++
      [Float.round(evaluation.score, @score_decimal_places)] ++
      tie_break_key(evaluation, instruments, policy) ++ [evaluation.counts]
  end

  defp tie_break_key(evaluation, instruments, policy) do
    policy
    |> Enum.map(fn
      :min_total_quantity -> Enum.sum(evaluation.amounts)
      :min_active_instruments -> Enum.count(evaluation.counts, &(&1 != 0))
      :prefer_instrument_order -> Enum.map(evaluation.amounts, &(-&1))
    end)
    |> Kernel.++([Enum.map(instruments, & &1.id)])
  end

  defp build_result(%{best: nil} = search, instruments, objectives, _problem) do
    %{
      status: :infeasible,
      plan: nil,
      allocations: [],
      exposures: nil,
      objective_residuals: nil,
      objective_score: nil,
      unit_contracts: unit_contracts(objectives),
      combinations_evaluated: search.evaluated,
      diagnosis: infeasible_diagnosis(search.closest, instruments)
    }
  end

  defp build_result(%{best: best} = search, instruments, objectives, problem) do
    allocations = build_allocations(instruments, best)

    %{
      status: :feasible,
      plan: build_plan(allocations, instruments, best, objectives, problem),
      allocations: allocations,
      exposures: best.exposures,
      objective_residuals: best.residuals,
      objective_score: best.score,
      unit_contracts: unit_contracts(objectives),
      combinations_evaluated: search.evaluated,
      diagnosis: nil
    }
  end

  defp build_allocations(instruments, evaluation) do
    [instruments, evaluation.counts, evaluation.amounts]
    |> Enum.zip()
    |> Enum.map(fn {instrument, count, amount} ->
      %{
        id: instrument.id,
        role: instrument.role,
        venue: instrument.venue,
        account: instrument.account,
        symbol: instrument.symbol,
        side: instrument.side,
        quantity: amount,
        signed_quantity: instrument.sign * amount,
        quantity_unit: instrument.quantity_unit,
        grid_count: count,
        amount_step: instrument.amount_step
      }
    end)
  end

  defp build_plan(allocations, instruments, evaluation, objectives, problem) do
    %{
      legs: option_plan_legs(allocations, instruments),
      hedge: hedge_plan(allocations, instruments, evaluation, objectives, problem),
      venue_policy: problem.venue_policy,
      risk_targets: Map.new(objectives, fn {greek, objective} -> {greek, objective.target} end),
      hard_limits: problem.hard_limits
    }
  end

  defp option_plan_legs(allocations, instruments) do
    instruments
    |> Enum.zip(allocations)
    |> Enum.flat_map(fn
      {%{role: :option}, %{quantity: +0.0}} ->
        []

      {%{role: :option} = instrument, allocation} ->
        [
          instrument.source
          |> Map.take([:id, :venue, :account, :symbol, :side, :price, :type])
          |> Map.put(:amount, allocation.quantity)
          |> Map.put_new(:type, "limit")
        ]

      {_instrument, _allocation} ->
        []
    end)
  end

  defp hedge_plan(allocations, instruments, evaluation, objectives, _problem) do
    case instruments
         |> Enum.zip(allocations)
         |> Enum.find(fn {instrument, _allocation} -> instrument.role == :hedge end) do
      nil ->
        nil

      {instrument, allocation} ->
        target = get_in(objectives, [:delta, :target])
        option_venues = instruments |> Enum.filter(&(&1.role == :option)) |> Enum.map(& &1.venue) |> Enum.uniq()

        %{
          candidate_id: instrument.id,
          venue: instrument.venue,
          account: instrument.account,
          symbol: instrument.symbol,
          side: instrument.side,
          quantity: allocation.quantity,
          signed_quantity: allocation.signed_quantity,
          residual_delta: evaluation.residuals[:delta],
          target_delta: target,
          cross_venue?: option_venues != [] and instrument.venue not in option_venues,
          feasible?: true,
          reason: nil
        }
    end
  end

  defp infeasible_diagnosis(closest, instruments) do
    %{
      code: :objectives_infeasible,
      closest: %{
        allocations: build_allocations(instruments, closest),
        exposures: closest.exposures,
        objective_residuals: closest.residuals,
        objective_score: closest.score,
        objective_violations: closest.objective_violations,
        hard_limit_breaches: closest.hard_limit_breaches
      }
    }
  end

  defp unit_contracts(objectives) do
    Map.new(objectives, fn {greek, objective} ->
      {greek, Map.take(objective, [:underlying, :unit_convention])}
    end)
  end

  defp valid_convention?(convention) when is_map(convention) do
    denomination = fetch_key(convention, :denomination)
    unit = fetch_key(convention, :unit)
    bump_size = fetch_key(convention, :bump_size)
    time_basis = fetch_key(convention, :time_basis)

    is_binary(denomination) and denomination != "" and is_binary(unit) and unit != "" and
      is_number(bump_size) and (is_binary(time_basis) or is_nil(time_basis))
  end

  defp valid_convention?(_convention), do: false

  defp normalize_convention(convention) do
    Map.new(@convention_keys, fn key ->
      atom = String.to_existing_atom(key)
      {key, Map.get(convention, atom, Map.get(convention, key))}
    end)
  end

  defp residual_limit(limits, :delta), do: fetch_key(limits, :residual_delta_abs)
  defp residual_limit(limits, :gamma), do: fetch_key(limits, :residual_gamma_abs)
  defp residual_limit(limits, :vega), do: fetch_key(limits, :residual_vega_abs)

  defp baseline(problem), do: Map.get(problem, :baseline_contributions, [])
  defp max_combinations(problem), do: Map.get(problem, :max_combinations, @default_max_combinations)
  defp side_sign("buy"), do: 1
  defp side_sign("sell"), do: -1

  defp fetch_key(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp fetch_key(_map, _key), do: nil

  defp unsupported_key(map, allowed) do
    strings = Enum.map(allowed, &Atom.to_string/1)
    Enum.find(Enum.sort(Map.keys(map)), &(&1 not in allowed and &1 not in strings))
  end

  defp grid_value?(value, step) do
    value |> Decimal.div(step) |> then(&Decimal.equal?(&1, Decimal.round(&1, 0)))
  end

  defp grid_amount(count, step) do
    {:ok, step} = decimal(step)
    step |> Decimal.mult(Decimal.new(count)) |> Decimal.to_float()
  end

  defp decimal(%Decimal{} = value), do: {:ok, value}
  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}
  defp decimal(_value), do: {:error, :invalid_quantity_limits}

  defp decimal_integer!(decimal), do: Decimal.to_integer(decimal)
end
