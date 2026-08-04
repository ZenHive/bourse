defmodule Bourse.OptionProposal.Checks do
  @moduledoc false

  alias Bourse.Market
  alias Bourse.Order.Sanity
  alias Bourse.PortfolioRisk.Snapshot

  @check_order [
    :market,
    :quote,
    :greeks,
    :portfolio,
    :account_capacity,
    :order_sanity,
    :hard_limits,
    :hedge,
    :cross_venue
  ]
  @future_timestamp_tolerance_ms 1_000

  @doc "Runs the stable preflight check suite and returns checks, violations, failures."
  @spec run(map()) :: {[map()], [map()], [map()]}
  def run(ctx) when is_map(ctx) do
    check_results = Enum.map(@check_order, &run_one(&1, ctx))

    checks =
      Enum.map(check_results, fn {name, status, detail} ->
        %{name: name, status: status, detail: detail}
      end)

    violations =
      Enum.flat_map(check_results, fn
        {name, status, detail} when status in [:violation, :unknown, :unsupported] ->
          [violation_from_detail(name, detail)]

        {_name, _status, _detail} ->
          []
      end)

    failures = portfolio_failures(ctx.portfolio) ++ capacity_failures(check_results)
    {checks, violations, failures}
  end

  defp run_one(:market, ctx), do: check_market(ctx.legs, ctx.candidates, ctx.observed_at, ctx.opts)
  defp run_one(:quote, ctx), do: check_quote(ctx.legs, ctx.observed_at, ctx.opts)
  defp run_one(:greeks, ctx), do: check_greeks(ctx.legs, ctx.observed_at, ctx.opts)
  defp run_one(:portfolio, ctx), do: check_portfolio(ctx.proposal, ctx.portfolio, ctx.observed_at, ctx.opts)
  defp run_one(:account_capacity, ctx), do: check_account_capacity(ctx.proposal, ctx.legs, ctx.hedge, ctx.portfolio)
  defp run_one(:order_sanity, ctx), do: check_order_sanity(ctx.legs, ctx.hedge)
  defp run_one(:hard_limits, ctx), do: check_hard_limits(ctx.proposal, ctx.projected, ctx.hedge, ctx.post_after)
  defp run_one(:hedge, ctx), do: check_hedge(ctx.proposal, ctx.candidates, ctx.hedge)
  defp run_one(:cross_venue, ctx), do: check_cross_venue(ctx.proposal, ctx.legs, ctx.hedge)

  defp check_market(legs, candidates, observed_at, opts) do
    rows = legs ++ candidates
    max_age = Keyword.get(opts, :max_age_ms)

    inactive =
      for row <- rows,
          match?(%Market{active: false}, Map.get(row, :market)),
          do: row.symbol

    stale =
      Enum.filter(rows, fn row ->
        stale_timestamp?(Map.get(row, :market_observed_at), observed_at, max_age)
      end)

    cond do
      is_nil(max_age) ->
        {:market, :unsupported, %{code: :freshness_constraint_missing, input: :market}}

      inactive != [] ->
        {:market, :violation, %{code: :inactive_market, symbols: inactive}}

      stale != [] ->
        {:market, :violation, %{code: :stale_market, ids: Enum.map(stale, & &1.id)}}

      true ->
        {:market, :ok, :active_and_fresh}
    end
  end

  defp check_quote(legs, observed_at, opts) do
    max_age = Keyword.get(opts, :max_age_ms)
    stale = Enum.filter(legs, &stale_quote?(&1, observed_at, max_age))

    cond do
      is_nil(max_age) ->
        {:quote, :unsupported, %{code: :freshness_constraint_missing, input: :quote}}

      stale == [] ->
        {:quote, :ok, :fresh}

      true ->
        {:quote, :violation, %{code: :stale_or_missing_quote, leg_ids: Enum.map(stale, & &1.id)}}
    end
  end

  defp stale_quote?(leg, observed_at, max_age) do
    quote = Map.get(leg, :quote)
    freshness_observed_at = Map.get(leg, :quote_observed_at, observed_at)

    cond do
      is_nil(max_age) and is_nil(quote) -> false
      is_nil(quote) -> true
      is_map(quote) -> stale_timestamp?(quote_timestamp(quote), freshness_observed_at, max_age)
      true -> true
    end
  end

  defp quote_timestamp(quote), do: Map.get(quote, :timestamp) || Map.get(quote, "timestamp")

  defp check_greeks(legs, observed_at, opts) do
    max_age = Keyword.get(opts, :max_age_ms)
    bad = Enum.filter(legs, &bad_greeks?(&1, observed_at, max_age))

    cond do
      is_nil(max_age) ->
        {:greeks, :unsupported, %{code: :freshness_constraint_missing, input: :greeks}}

      bad == [] ->
        {:greeks, :ok, :fresh}

      true ->
        {:greeks, :violation, %{code: :stale_or_missing_greeks, leg_ids: Enum.map(bad, & &1.id)}}
    end
  end

  defp bad_greeks?(leg, observed_at, max_age) do
    greeks = leg.greeks
    freshness_observed_at = Map.get(leg, :greeks_observed_at, observed_at)
    missing? = is_nil(greeks.delta) or is_nil(greeks.gamma) or is_nil(greeks.vega) or is_nil(greeks.theta)
    missing? or stale_timestamp?(greeks.source_timestamp, freshness_observed_at, max_age)
  end

  defp check_portfolio(proposal, portfolio, observed_at, opts) do
    max_age = Keyword.get(opts, :max_age_ms)

    cond do
      portfolio.status == :error ->
        {:portfolio, :violation, %{code: :portfolio_read_failed, failures: portfolio.failures}}

      portfolio.status == :partial ->
        {:portfolio, :violation, %{code: :portfolio_partial, failures: portfolio.failures}}

      is_nil(portfolio.snapshot) ->
        {:portfolio, :unsupported, %{code: :portfolio_check_unsupported}}

      stale_timestamp?(portfolio.snapshot.observed_at, observed_at, max_age) ->
        {:portfolio, :violation, %{code: :stale_portfolio, observed_at: portfolio.snapshot.observed_at}}

      Map.get(proposal, :expected_positions) ->
        portfolio_expected(proposal.expected_positions, portfolio.snapshot)

      true ->
        {:portfolio, :ok, portfolio.status}
    end
  end

  defp portfolio_expected(expected, snapshot) do
    case positions_changed?(expected, snapshot) do
      false -> {:portfolio, :ok, :unchanged}
      true -> {:portfolio, :violation, %{code: :positions_changed}}
      :unknown -> {:portfolio, :unknown, %{code: :positions_unreadable}}
    end
  end

  defp check_account_capacity(proposal, legs, hedge, portfolio) do
    domains = capacity_domains(portfolio)
    required = Map.get(proposal.hard_limits, :required_capacity) || Map.get(proposal.hard_limits, "required_capacity")
    touched = touched_domain_keys(legs, hedge)
    known_keys = MapSet.new(domains, &{&1.venue, &1.account})
    missing = Enum.reject(touched, &MapSet.member?(known_keys, &1))
    unknown = Enum.filter(domains, &(&1.capacity_status == :unknown and {&1.venue, &1.account} in touched))
    unknown_keys = missing ++ Enum.map(unknown, &{&1.venue, &1.account})

    cond do
      unknown_keys != [] ->
        {:account_capacity, :violation, %{code: :unknown_account_capacity, domains: Enum.uniq(unknown_keys)}}

      is_map(required) or is_list(required) ->
        capacity_required_result(domains, required, touched)

      domains == [] ->
        {:account_capacity, :unknown, %{code: :unknown_account_capacity, domains: touched}}

      true ->
        {:account_capacity, :ok, :known}
    end
  end

  defp capacity_required_result(domains, required, touched) do
    case capacity_sufficient?(domains, required, touched) do
      :ok -> {:account_capacity, :ok, :sufficient}
      {:error, detail} -> {:account_capacity, :violation, detail}
    end
  end

  defp check_order_sanity(legs, hedge) do
    issues = leg_sanity_issues(legs) ++ hedge_sanity_issues(hedge)

    if issues == [] do
      {:order_sanity, :ok, :passed}
    else
      {:order_sanity, :violation, %{code: :order_sanity_failed, issues: issues}}
    end
  end

  defp leg_sanity_issues(legs) do
    Enum.flat_map(legs, fn leg ->
      params = %{
        "symbol" => leg.symbol,
        "type" => leg.type || "limit",
        "side" => leg.side,
        "amount" => leg.amount,
        "price" => leg.price
      }

      sanity_issues(params, leg.market, leg.id)
    end)
  end

  defp hedge_sanity_issues(hedge) do
    if hedge && hedge.market && hedge.quantity > 0 do
      params = %{
        "symbol" => hedge.symbol,
        "type" => "market",
        "side" => hedge.side,
        "amount" => hedge.quantity
      }

      sanity_issues(params, hedge.market, :hedge)
    else
      []
    end
  end

  defp sanity_issues(params, market, id) do
    case Sanity.validate(params, market, precision_mode: market.precision_mode) do
      {:ok, _} -> []
      {:ok, _, _} -> []
      {:error, {:sanity_check, errors}} -> Enum.map(errors, &{id, &1})
    end
  end

  defp check_hard_limits(proposal, projected, hedge, post_after) do
    limits = proposal.hard_limits
    residual = residual_delta(hedge, post_after, proposal.risk_targets)

    breaches =
      limits
      |> greek_breaches(post_after, projected.notional)
      |> maybe_residual_breach(limits, residual)

    if breaches == [] do
      {:hard_limits, :ok, :within_limits}
    else
      {:hard_limits, :violation, %{code: :post_trade_limit_violation, breaches: breaches}}
    end
  end

  defp residual_delta(hedge, post_after, risk_targets) do
    case {hedge, target_delta(risk_targets)} do
      {%{residual_delta: residual}, _target} -> residual
      {nil, target} when is_number(target) -> post_after.delta - target
      {nil, nil} -> nil
    end
  end

  defp greek_breaches(limits, post_after, notional) do
    []
    |> maybe_limit_breach(limits, :delta, post_after.delta)
    |> maybe_limit_breach(limits, :gamma, post_after.gamma)
    |> maybe_limit_breach(limits, :vega, post_after.vega)
    |> maybe_limit_breach(limits, :theta, post_after.theta)
    |> maybe_limit_breach(limits, :notional, notional)
  end

  defp check_hedge(proposal, candidates, hedge) do
    target = target_delta(proposal.risk_targets)

    cond do
      is_nil(target) -> {:hedge, :ok, :not_requested}
      match?(%{feasible?: false}, hedge) -> {:hedge, :violation, %{code: :hedge_infeasible, reason: hedge.reason}}
      zero_hedge?(hedge) -> {:hedge, :ok, :zero_hedge}
      hedge -> hedge_result(proposal, hedge)
      candidates == [] -> {:hedge, :violation, %{code: :hedge_infeasible, reason: :no_candidates}}
      true -> {:hedge, :violation, %{code: :hedge_infeasible}}
    end
  end

  defp zero_hedge?(hedge), do: hedge && hedge.feasible? && hedge.quantity == 0 && almost_zero?(hedge.residual_delta)

  defp hedge_result(proposal, hedge) do
    residual_limit =
      Map.get(proposal.hard_limits, :residual_delta_abs) ||
        Map.get(proposal.hard_limits, "residual_delta_abs")

    if is_number(residual_limit) and abs(hedge.residual_delta) > residual_limit do
      {:hedge, :violation,
       %{code: :residual_delta_exceeds_limit, residual_delta: hedge.residual_delta, limit: residual_limit}}
    else
      {:hedge, :ok, %{candidate_id: hedge.candidate_id, residual_delta: hedge.residual_delta}}
    end
  end

  defp target_delta(risk_targets) when is_map(risk_targets) do
    Map.get(risk_targets, :delta) || Map.get(risk_targets, "delta")
  end

  defp target_delta(_), do: nil

  defp check_cross_venue(proposal, legs, hedge) do
    venues = legs |> Enum.map(& &1.venue) |> Enum.uniq()
    cross? = length(venues) > 1 or match?(%{cross_venue?: true}, hedge)

    if cross? do
      cross_venue_result(proposal)
    else
      {:cross_venue, :ok, :not_applicable}
    end
  end

  defp cross_venue_result(proposal) do
    missing =
      Enum.reject(
        [:valuation_assumptions, :freshness_assumptions, :basis_risk, :counterparty_risk],
        &explicit_assumption?(proposal, &1)
      )

    if missing == [] do
      {:cross_venue, :ok, :assumptions_explicit}
    else
      {:cross_venue, :violation, %{code: :missing_cross_venue_assumptions, missing: missing}}
    end
  end

  defp explicit_assumption?(proposal, key) do
    case Map.get(proposal, key) do
      value when is_map(value) -> map_size(value) > 0
      _ -> false
    end
  end

  defp maybe_limit_breach(breaches, limits, key, value) when is_number(value) do
    case Map.get(limits, key) || Map.get(limits, Atom.to_string(key)) do
      nil -> breaches
      limit -> append_limit_breach(breaches, key, value, limit)
    end
  end

  defp maybe_limit_breach(breaches, _limits, _key, _value), do: breaches

  defp append_limit_breach(breaches, key, value, %{min: min, max: max})
       when is_number(min) and is_number(max) and (value < min or value > max) do
    [%{greek: key, value: value, min: min, max: max} | breaches]
  end

  defp append_limit_breach(breaches, key, value, %{"min" => min, "max" => max})
       when is_number(min) and is_number(max) and (value < min or value > max) do
    [%{greek: key, value: value, min: min, max: max} | breaches]
  end

  defp append_limit_breach(breaches, key, value, %{max_abs: max_abs}),
    do: append_max_abs_breach(breaches, key, value, max_abs)

  defp append_limit_breach(breaches, key, value, %{"max_abs" => max_abs}),
    do: append_max_abs_breach(breaches, key, value, max_abs)

  defp append_limit_breach(breaches, key, value, max_abs), do: append_max_abs_breach(breaches, key, value, max_abs)

  defp append_max_abs_breach(breaches, key, value, max_abs) when is_number(max_abs) and abs(value) > max_abs do
    [%{greek: key, value: value, max_abs: max_abs} | breaches]
  end

  defp append_max_abs_breach(breaches, _key, _value, _max_abs), do: breaches

  defp maybe_residual_breach(breaches, limits, residual) when is_number(residual) do
    limit = Map.get(limits, :residual_delta_abs) || Map.get(limits, "residual_delta_abs")
    append_max_abs_breach(breaches, :residual_delta, residual, limit)
  end

  defp maybe_residual_breach(breaches, _limits, _residual), do: breaches

  defp violation_from_detail(check, %{code: code} = detail) do
    %{code: code, check: check, message: violation_message(code, detail), detail: detail}
  end

  defp violation_from_detail(check, detail) do
    %{code: :check_failed, check: check, message: "check #{check} failed", detail: detail}
  end

  defp violation_message(:inactive_market, %{symbols: symbols}) do
    "inactive markets: #{Enum.join(symbols, ", ")}"
  end

  defp violation_message(:stale_market, _), do: "market metadata is stale or lacks an observation timestamp"

  defp violation_message(:freshness_constraint_missing, %{input: input}) do
    "cannot approve #{input} freshness without max_age_ms"
  end

  defp violation_message(:stale_or_missing_quote, _) do
    "quote is stale or missing under the caller freshness constraint"
  end

  defp violation_message(:stale_or_missing_greeks, _) do
    "greeks are stale or missing under the caller freshness constraint"
  end

  defp violation_message(:positions_changed, _), do: "portfolio positions changed relative to expected_positions"

  defp violation_message(:portfolio_partial, _) do
    "portfolio snapshot is partial; incomplete exposure cannot be approved"
  end

  defp violation_message(:portfolio_read_failed, _), do: "portfolio read failed"
  defp violation_message(:portfolio_check_unsupported, _), do: "portfolio snapshot or scopes are required for approval"
  defp violation_message(:stale_portfolio, _), do: "portfolio snapshot is stale"
  defp violation_message(:positions_unreadable, _), do: "existing positions could not be verified"

  defp violation_message(:unknown_account_capacity, _) do
    "account capacity is unknown and cannot be converted into approval"
  end

  defp violation_message(:insufficient_capacity, %{currency: currency}) do
    "insufficient capacity for #{currency}"
  end

  defp violation_message(:order_sanity_failed, _), do: "order sanity check failed"
  defp violation_message(:post_trade_limit_violation, _), do: "post-trade hard limits violated"

  defp violation_message(:residual_delta_exceeds_limit, %{residual_delta: residual, limit: limit}) do
    "residual delta #{residual} exceeds limit #{limit}"
  end

  defp violation_message(:hedge_infeasible, _) do
    "hedge is infeasible under the supplied candidates and venue policy"
  end

  defp violation_message(:missing_cross_venue_assumptions, _) do
    "cross-venue plans require valuation, freshness, basis-risk, and counterparty-risk assumptions"
  end

  defp violation_message(:ambiguous_cross_venue_capacity_limit, _) do
    "cross-venue capacity requirements must name each venue and account"
  end

  defp violation_message(code, _), do: to_string(code)

  defp portfolio_failures(%{failures: failures}) when is_list(failures), do: failures
  defp portfolio_failures(_), do: []

  defp capacity_failures(check_results) do
    Enum.flat_map(check_results, fn
      {:account_capacity, :violation, %{code: :unknown_account_capacity} = detail} ->
        [%{component: :account_capacity, reason: :unknown_account_capacity, detail: detail}]

      _ ->
        []
    end)
  end

  defp positions_changed?(expected, %Snapshot{domains: domains}) when is_list(expected) do
    actual = Enum.flat_map(domains, &domain_positions/1)

    if :unreadable in actual do
      :unknown
    else
      normalize_positions(expected) != Enum.sort(actual)
    end
  end

  defp positions_changed?(_expected, _snapshot), do: :unknown

  defp domain_positions(domain) do
    case get_in(domain, [:components, :positions]) do
      %{status: :ok, data: data} when is_list(data) ->
        Enum.map(data, fn pos ->
          {domain.venue, domain.account, Map.get(pos, :symbol), Map.get(pos, :contracts) || Map.get(pos, :side)}
        end)

      %{status: :error} ->
        [:unreadable]

      _ ->
        []
    end
  end

  defp normalize_positions(expected) do
    expected
    |> Enum.map(fn row ->
      {
        to_string(Map.get(row, :venue) || Map.get(row, "venue")),
        Map.get(row, :account) || Map.get(row, "account"),
        Map.get(row, :symbol) || Map.get(row, "symbol"),
        Map.get(row, :contracts) || Map.get(row, "contracts") || Map.get(row, :side) || Map.get(row, "side")
      }
    end)
    |> Enum.sort()
  end

  defp touched_domain_keys(legs, hedge) do
    hedge_domains =
      case hedge do
        %{feasible?: true, venue: venue, account: account} when not is_nil(venue) -> [{venue, account}]
        _ -> []
      end

    legs
    |> Enum.map(&{&1.venue, &1.account})
    |> Kernel.++(hedge_domains)
    |> Enum.uniq()
  end

  defp capacity_domains(%{snapshot: %Snapshot{domains: domains}}) do
    Enum.map(domains, &capacity_domain_row/1)
  end

  defp capacity_domains(_portfolio), do: []

  defp capacity_domain_row(domain) do
    case domain.available_capacity do
      {:ok, capacity} ->
        %{
          venue: domain.venue,
          account: domain.account,
          settlement_currencies: Map.keys(capacity),
          available_capacity: capacity,
          capacity_status: :known,
          portfolio_margin_netting: false
        }

      {:error, reason} ->
        %{
          venue: domain.venue,
          account: domain.account,
          settlement_currencies: [],
          available_capacity: nil,
          capacity_status: :unknown,
          capacity_error: reason,
          portfolio_margin_netting: false
        }
    end
  end

  defp capacity_sufficient?(domains, required, [{venue, account}]) when is_map(required) do
    Enum.reduce_while(required, :ok, fn {currency, amount}, :ok ->
      check_domain_capacity(domains, venue, account, to_string(currency), amount)
    end)
  end

  defp capacity_sufficient?(_domains, required, [_first, _second | _rest] = touched) when is_map(required) do
    {:error, %{code: :ambiguous_cross_venue_capacity_limit, domains: touched}}
  end

  defp capacity_sufficient?(domains, required, _touched) when is_list(required) do
    Enum.reduce_while(required, :ok, fn row, :ok ->
      case row do
        %{venue: venue, account: account, currency: currency, amount: amount} ->
          check_domain_capacity(domains, to_string(venue), account, to_string(currency), amount)

        _ ->
          {:halt, {:error, %{code: :invalid_capacity_requirement, requirement: row}}}
      end
    end)
  end

  defp capacity_sufficient?(_domains, _required, _touched) do
    {:error, %{code: :invalid_capacity_requirement}}
  end

  defp check_domain_capacity(domains, venue, account, currency, amount) when is_number(amount) and amount >= 0 do
    domain = Enum.find(domains, &(&1.venue == venue and &1.account == account))
    available = capacity_for_currency(domain, currency)

    cond do
      is_nil(available) ->
        {:halt, {:error, %{code: :unknown_account_capacity, venue: venue, account: account, currency: currency}}}

      available < amount ->
        {:halt,
         {:error,
          %{
            code: :insufficient_capacity,
            venue: venue,
            account: account,
            currency: currency,
            required: amount,
            available: available
          }}}

      true ->
        {:cont, :ok}
    end
  end

  defp check_domain_capacity(_domains, venue, account, currency, amount) do
    {:halt,
     {:error,
      %{
        code: :invalid_capacity_requirement,
        venue: venue,
        account: account,
        currency: currency,
        amount: amount
      }}}
  end

  defp capacity_for_currency(%{available_capacity: %{} = cap}, currency) do
    Map.get(cap, currency) || Map.get(cap, string_to_existing_atom(currency))
  end

  defp capacity_for_currency(_domain, _currency), do: nil

  defp string_to_existing_atom(currency) do
    String.to_existing_atom(currency)
  rescue
    ArgumentError -> nil
  end

  defp stale_timestamp?(_timestamp, _observed_at, nil), do: false
  defp stale_timestamp?(nil, _observed_at, max_age_ms) when is_integer(max_age_ms), do: true

  defp stale_timestamp?(timestamp, observed_at, max_age_ms)
       when is_integer(timestamp) and is_integer(observed_at) and is_integer(max_age_ms) do
    age = observed_at - timestamp

    # Provider and local clocks may straddle fetch completion by sub-second
    # granularity. Larger future timestamps remain fail-closed as clock skew.
    age < -@future_timestamp_tolerance_ms or age > max_age_ms
  end

  defp stale_timestamp?(_timestamp, _observed_at, _max_age_ms), do: true

  defp almost_zero?(value) when is_number(value), do: abs(value) < 1.0e-12
  defp almost_zero?(_), do: false

  @doc "Extracts per-domain capacity rows from a portfolio snapshot wrapper."
  @spec capacity_domains_for(map()) :: [map()]
  def capacity_domains_for(portfolio), do: capacity_domains(portfolio)
end
