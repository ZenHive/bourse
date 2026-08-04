defmodule Bourse.OptionProposal do
  @moduledoc """
  Mechanical option-proposal preflight and spot/perp hedge sizing.

  An AI supplies explicit option legs, risk targets, hard limits, hedge
  candidates and a venue policy. This module projects post-trade exposure,
  sizes a correctly rounded hedge toward the caller's target delta, and returns
  either one non-mutating approval or a stable list of actionable violations.

  Strategy decisions stay with the caller: the library never chooses which
  option to trade or submits orders. Its optimizer only allocates quantities
  among caller-approved instruments and objectives. Cross-venue plans keep
  collateral pools separate and never claim portfolio-margin netting.
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.OptionProposal.Checks
  alias Bourse.OptionProposal.Hedge
  alias Bourse.OptionProposal.MarginImpact
  alias Bourse.OptionProposal.Optimizer
  alias Bourse.OptionProposal.Projection
  alias Bourse.OptionProposal.Result
  alias Bourse.PortfolioRisk
  alias Bourse.PortfolioRisk.Snapshot
  alias Bourse.Unified.OptionSurface

  @venue_policies [:same_only, :prefer_same_venue, :cross_allowed]

  @type venue_policy :: Hedge.venue_policy()

  @type proposal :: %{
          required(:legs) => [map()],
          required(:hedge_candidates) => [map()],
          required(:risk_targets) => map(),
          required(:hard_limits) => map(),
          required(:venue_policy) => venue_policy(),
          optional(:valuation_assumptions) => map(),
          optional(:freshness_assumptions) => map(),
          optional(:basis_risk) => map(),
          optional(:counterparty_risk) => map(),
          optional(:strategy) => map(),
          optional(:snapshot) => Snapshot.t(),
          optional(:scopes) => [PortfolioRisk.scope()],
          optional(:expected_positions) => [map()]
        }

  @doc """
  Validates a caller-built option proposal without mutation.

  Options:

    * `:observed_at` — local observation timestamp for caller-supplied data;
      self-fetched Greeks and derived quotes use fetch-completion time
    * `:timeout` — forwarded to portfolio snapshot when scopes are supplied
    * `:max_age_ms` — freshness gate for Greeks / portfolio when reading live
    * `:request_opts` — default HTTP opts used when enriching legs and hedge candidates

  Returns `{:ok, %Result{}}` for both approved and rejected outcomes. Structural
  input errors return `{:error, %Error{}}`.
  """
  @spec preflight(proposal(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def preflight(proposal, opts \\ []) when is_map(proposal) and is_list(opts) do
    observed_at = Keyword.get(opts, :observed_at, System.system_time(:millisecond))
    opts = apply_freshness_assumptions(opts, proposal)

    with :ok <- validate_proposal(proposal),
         {:ok, portfolio} <- resolve_portfolio(proposal, opts, observed_at),
         {:ok, legs} <- enrich_legs(proposal.legs, opts, observed_at),
         {:ok, candidates} <- enrich_candidates(proposal.hedge_candidates, opts, observed_at),
         {:ok, projected} <- project_or_error(legs, baseline_contributions(portfolio)),
         {:ok, hedge} <- size_hedge(projected, proposal, candidates, legs) do
      finalize_preflight(proposal, legs, candidates, projected, hedge, portfolio, observed_at, opts)
    end
  end

  @doc "Projects option-leg exposure without portfolio checks or hedge sizing."
  @spec project([map()], [map()]) :: {:ok, map()} | {:error, atom() | {atom(), term()}}
  def project(legs, baseline_contributions \\ []) do
    Projection.project_legs(legs, baseline_contributions)
  end

  @doc "Sizes a spot/perp hedge toward `target_delta` under `venue_policy`."
  @spec calculate_hedge(number(), number(), [map()], venue_policy(), [String.t()]) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def calculate_hedge(current_delta, target_delta, candidates, venue_policy, option_venues) do
    Hedge.calculate(current_delta, target_delta, candidates, venue_policy, option_venues)
  end

  @doc "Optimizes a finite set of caller-approved instruments into a v1-shaped plan."
  @spec optimize(Optimizer.problem()) :: {:ok, map()} | {:error, term()}
  def optimize(problem), do: Optimizer.optimize(problem)

  @doc "Compares provider-reported margin impact within venue-local collateral domains."
  @spec compare_margin_impact(MarginImpact.problem()) ::
          {:ok, MarginImpact.result()} | {:error, Error.t()}
  def compare_margin_impact(problem), do: MarginImpact.compare(problem)

  defp finalize_preflight(proposal, legs, candidates, projected, hedge, portfolio, observed_at, opts) do
    post_after = apply_optional_hedge(projected.post_trade_before_hedge, hedge)
    projected = Map.put(projected, :post_trade_after_hedge, post_after)
    margin_domains = assemble_margin_domains(projected, hedge, portfolio)
    cross_venue = cross_venue_section(proposal, hedge, margin_domains)

    {checks, violations, failures} =
      Checks.run(%{
        proposal: proposal,
        legs: legs,
        candidates: candidates,
        projected: projected,
        hedge: hedge,
        portfolio: portfolio,
        post_after: post_after,
        observed_at: observed_at,
        opts: opts
      })

    status = if violations == [] and failures == [], do: :approved, else: :rejected

    {:ok,
     %Result{
       status: status,
       observed_at: observed_at,
       projected: projected,
       hedge: hedge,
       margin_domains: margin_domains,
       cross_venue: cross_venue,
       checks: checks,
       violations: violations,
       failures: failures,
       plan: build_plan(legs, hedge, proposal),
       strategy: Map.get(proposal, :strategy, %{})
     }}
  end

  defp apply_optional_hedge(post_trade, nil), do: post_trade
  defp apply_optional_hedge(post_trade, %{feasible?: false}), do: post_trade

  defp apply_optional_hedge(post_trade, hedge) do
    Projection.apply_hedge_delta(post_trade, hedge.hedge_delta)
  end

  defp size_hedge(projected, proposal, candidates, legs) do
    maybe_hedge(
      projected.post_trade_before_hedge.delta,
      proposal.risk_targets,
      candidates,
      proposal.venue_policy,
      option_venues(legs)
    )
  end

  defp validate_proposal(proposal) do
    cond do
      not is_list(Map.get(proposal, :legs)) or proposal.legs == [] ->
        {:error, Error.invalid_parameters(message: "option proposal requires at least one leg")}

      not is_list(Map.get(proposal, :hedge_candidates)) ->
        {:error, Error.invalid_parameters(message: "option proposal requires a hedge_candidates list")}

      not is_map(Map.get(proposal, :risk_targets)) ->
        {:error, Error.invalid_parameters(message: "option proposal requires risk_targets")}

      not is_map(Map.get(proposal, :hard_limits)) ->
        {:error, Error.invalid_parameters(message: "option proposal requires hard_limits")}

      Map.get(proposal, :venue_policy) not in @venue_policies ->
        {:error,
         Error.invalid_parameters(message: "venue_policy must be one of same_only, prefer_same_venue, cross_allowed")}

      true ->
        :ok
    end
  end

  defp resolve_portfolio(proposal, opts, observed_at) do
    cond do
      match?(%Snapshot{}, Map.get(proposal, :snapshot)) ->
        portfolio_result(proposal.snapshot, proposal.snapshot.failures, proposal.snapshot.status)

      is_list(Map.get(proposal, :scopes)) and proposal.scopes != [] ->
        snapshot_from_scopes(proposal.scopes, opts, observed_at)

      true ->
        portfolio_result(nil, [], :not_requested)
    end
  end

  defp snapshot_from_scopes(scopes, opts, observed_at) do
    snapshot_opts =
      opts
      |> Keyword.take([:timeout, :max_age_ms])
      |> Keyword.put(:observed_at, observed_at)

    case PortfolioRisk.snapshot(scopes, snapshot_opts) do
      {:ok, %Snapshot{} = snapshot} ->
        portfolio_result(snapshot, snapshot.failures, snapshot.status)

      {:error, %Error{} = error} ->
        portfolio_result(nil, [%{component: :portfolio, reason: error}], :error)
    end
  end

  defp portfolio_result(snapshot, failures, status) do
    {:ok, %{snapshot: snapshot, failures: failures, status: status}}
  end

  defp baseline_contributions(%{snapshot: %Snapshot{contributions: contributions}}), do: contributions
  defp baseline_contributions(_portfolio), do: []

  defp enrich_legs(legs, opts, observed_at) do
    map_ok(legs, &enrich_leg(&1, opts, observed_at))
  end

  defp enrich_leg(leg, opts, observed_at) when is_map(leg) do
    with :ok <- require_fields(leg, [:id, :venue, :account, :symbol, :side, :amount], "option leg"),
         {:ok, market} <- resolve_market(leg, opts),
         {:ok, greeks, greeks_observed_at} <- resolve_greeks(leg, market, opts, observed_at) do
      {:ok,
       %{
         id: Map.fetch!(leg, :id),
         venue: to_string(Map.fetch!(leg, :venue)),
         account: Map.fetch!(leg, :account),
         symbol: Map.fetch!(leg, :symbol),
         side: to_string(Map.fetch!(leg, :side)),
         amount: Map.fetch!(leg, :amount),
         price: Map.get(leg, :price),
         type: leg |> Map.get(:type, "limit") |> to_string(),
         market: market,
         market_observed_at: market_observed_at(leg, observed_at),
         greeks: greeks,
         greeks_observed_at: greeks_observed_at,
         quote: resolve_quote(leg, greeks),
         quote_observed_at: quote_observed_at(leg, greeks_observed_at, observed_at),
         exchange: Map.get(leg, :exchange)
       }}
    end
  end

  defp enrich_leg(_leg, _opts, _observed_at), do: {:error, Error.invalid_parameters(message: "each leg must be a map")}

  defp enrich_candidates(candidates, opts, observed_at) do
    map_ok(candidates, &enrich_candidate(&1, opts, observed_at))
  end

  defp enrich_candidate(candidate, opts, observed_at) when is_map(candidate) do
    with :ok <- require_fields(candidate, [:id, :venue, :account, :symbol], "hedge candidate"),
         {:ok, market} <- resolve_candidate_market(candidate, opts) do
      {:ok,
       %{
         id: Map.fetch!(candidate, :id),
         venue: to_string(Map.fetch!(candidate, :venue)),
         account: Map.fetch!(candidate, :account),
         symbol: Map.fetch!(candidate, :symbol),
         market: market,
         market_observed_at: market_observed_at(candidate, observed_at),
         kind: Map.get(candidate, :kind),
         price: Map.get(candidate, :price),
         quote: Map.get(candidate, :quote)
       }}
    end
  end

  defp enrich_candidate(_candidate, _opts, _observed_at) do
    {:error, Error.invalid_parameters(message: "each hedge candidate must be a map")}
  end

  defp require_fields(row, required, label) do
    missing = Enum.reject(required, &Map.has_key?(row, &1))

    if missing == [] do
      :ok
    else
      {:error,
       Error.invalid_parameters(message: "#{label} missing fields: #{Enum.map_join(missing, ", ", &to_string/1)}")}
    end
  end

  defp resolve_market(%{market: %Market{} = market}, _opts), do: {:ok, market}

  defp resolve_market(%{exchange: %Exchange{} = exchange, symbol: symbol} = leg, opts) do
    with {:ok, exchange} <- ensure_markets(exchange, request_opts(leg, opts)) do
      find_market(exchange, symbol)
    end
  end

  defp resolve_market(_leg, _opts) do
    {:error, Error.invalid_parameters(message: "each leg requires a market or exchange")}
  end

  defp resolve_greeks(%{greeks: %InstrumentGreeks{} = greeks}, _market, _opts, observed_at) do
    {:ok, greeks, observed_at}
  end

  defp resolve_greeks(%{exchange: %Exchange{} = exchange, symbol: symbol} = leg, _market, opts, _observed_at) do
    request_opts = request_opts(leg, opts)
    max_age_ms = Keyword.get(opts, :max_age_ms) || get_in(leg, [:freshness, :max_age_ms])

    greeks_opts =
      [request_opts: request_opts]
      |> maybe_put(:observed_at, Keyword.get(opts, :observed_at))
      |> maybe_put(:max_age_ms, max_age_ms)

    case OptionSurface.instrument_greeks(exchange, symbol, greeks_opts) do
      {:ok, greeks} ->
        checked_at = Keyword.get(opts, :observed_at, System.system_time(:millisecond))
        {:ok, greeks, checked_at}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp resolve_greeks(_leg, _market, _opts, _observed_at) do
    {:error, Error.invalid_parameters(message: "each leg requires greeks or an exchange to fetch them")}
  end

  defp resolve_candidate_market(%{market: %Market{} = market}, _opts), do: {:ok, market}

  defp resolve_candidate_market(%{exchange: %Exchange{} = exchange, symbol: symbol} = candidate, opts) do
    with {:ok, exchange} <- ensure_markets(exchange, request_opts(candidate, opts)) do
      find_market(exchange, symbol)
    end
  end

  defp resolve_candidate_market(_candidate, _opts) do
    {:error, Error.invalid_parameters(message: "each hedge candidate requires a market or exchange")}
  end

  defp ensure_markets(%Exchange{markets: markets} = exchange, _request_opts) when is_list(markets) and markets != [] do
    {:ok, exchange}
  end

  defp ensure_markets(%Exchange{} = exchange, request_opts) do
    case Bourse.load_markets(exchange, request_opts) do
      {:ok, %Exchange{} = loaded} -> {:ok, loaded}
      {:error, %Error{}} = err -> err
      {:error, reason} -> {:error, Error.exchange_error("load_markets failed: #{inspect(reason)}")}
    end
  end

  defp find_market(%Exchange{markets: markets}, symbol) when is_list(markets) do
    case Enum.find(markets, &(&1.symbol == symbol or &1.id == symbol)) do
      %Market{} = market -> {:ok, market}
      nil -> {:error, Error.bad_symbol(message: "market not found: #{symbol}")}
    end
  end

  defp find_market(_exchange, symbol), do: {:error, Error.bad_symbol(message: "markets not loaded for #{symbol}")}

  defp project_or_error(legs, baseline) do
    case Projection.project_legs(legs, baseline) do
      {:ok, projected} -> {:ok, projected}
      {:error, reason} -> {:error, Error.invalid_parameters(message: "option projection failed: #{inspect(reason)}")}
    end
  end

  defp maybe_hedge(current_delta, risk_targets, candidates, venue_policy, option_venues) do
    target = Map.get(risk_targets, :delta) || Map.get(risk_targets, "delta")
    hedge_for_target(current_delta, target, candidates, venue_policy, option_venues)
  end

  defp hedge_for_target(_current_delta, nil, _candidates, _venue_policy, _option_venues), do: {:ok, nil}

  defp hedge_for_target(_current_delta, target, _candidates, _venue_policy, _option_venues) when not is_number(target) do
    {:error, Error.invalid_parameters(message: "risk_targets.delta must be a number when supplied")}
  end

  defp hedge_for_target(current_delta, target, [], venue_policy, _option_venues) do
    if target == current_delta do
      {:ok, zero_hedge(current_delta, target, venue_policy)}
    else
      {:ok, infeasible_hedge(current_delta, target, venue_policy, :no_hedge_candidate)}
    end
  end

  defp hedge_for_target(current_delta, target, candidates, venue_policy, option_venues) do
    case Hedge.calculate(current_delta, target, candidates, venue_policy, option_venues) do
      {:ok, hedge} ->
        {:ok, hedge}

      {:error, reason} ->
        {:ok, infeasible_hedge(current_delta, target, venue_policy, reason)}
    end
  end

  defp zero_hedge(current_delta, target_delta, venue_policy) do
    %{
      candidate_id: nil,
      venue: nil,
      account: nil,
      symbol: nil,
      market: nil,
      kind: nil,
      side: "buy",
      quantity: 0.0,
      signed_quantity: 0.0,
      raw_quantity: 0.0,
      amount_step: nil,
      delta_per_unit: 1.0,
      hedge_delta: 0.0,
      current_delta: current_delta,
      target_delta: target_delta,
      residual_delta: current_delta - target_delta,
      venue_policy: venue_policy,
      cross_venue?: false,
      feasible?: true,
      reason: nil
    }
  end

  defp infeasible_hedge(current_delta, target_delta, venue_policy, reason) do
    current_delta
    |> zero_hedge(target_delta, venue_policy)
    |> Map.merge(%{
      residual_delta: current_delta - target_delta,
      feasible?: false,
      reason: reason
    })
  end

  defp option_venues(legs), do: legs |> Enum.map(& &1.venue) |> Enum.uniq()

  defp assemble_margin_domains(projected, hedge, portfolio) do
    rows = projected.margin_domains ++ hedge_domain_rows(hedge) ++ Checks.capacity_domains_for(portfolio)

    rows
    |> Enum.group_by(&{&1.venue, &1.account})
    |> Enum.map(fn {{venue, account}, grouped} ->
      %{
        venue: venue,
        account: account,
        settlement_currencies: grouped |> Enum.flat_map(&Map.get(&1, :settlement_currencies, [])) |> Enum.uniq(),
        effects: grouped,
        available_capacity: Enum.find_value(grouped, &Map.get(&1, :available_capacity)),
        capacity_status: Enum.find_value(grouped, &Map.get(&1, :capacity_status)) || :projected,
        portfolio_margin_netting: false
      }
    end)
    |> Enum.sort_by(&{&1.venue, to_string(&1.account)})
  end

  defp hedge_domain_rows(%{venue: venue} = hedge) when not is_nil(venue) do
    settle = hedge.market && (hedge.market.settle || hedge.market.quote)

    [
      %{
        venue: hedge.venue,
        account: hedge.account,
        settlement_currencies: Enum.reject([settle], &is_nil/1),
        leg_ids: [hedge.candidate_id],
        delta: hedge.hedge_delta,
        gamma: 0.0,
        vega: 0.0,
        theta: 0.0,
        notional: hedge_notional(hedge),
        portfolio_margin_netting: false,
        role: :hedge
      }
    ]
  end

  defp hedge_domain_rows(_hedge), do: []

  defp hedge_notional(%{signed_quantity: qty, market: %Market{spot: true}}), do: abs(qty)
  defp hedge_notional(%{hedge_delta: delta}) when is_number(delta), do: abs(delta)

  defp cross_venue_section(proposal, hedge, margin_domains) do
    cross? =
      (hedge && Map.get(hedge, :cross_venue?)) ||
        length(Enum.uniq(Enum.map(margin_domains, & &1.venue))) > 1

    if cross? do
      %{
        collateral_pools:
          Enum.map(margin_domains, &Map.take(&1, [:venue, :account, :available_capacity, :capacity_status])),
        valuation_assumptions: Map.get(proposal, :valuation_assumptions, %{}),
        freshness_assumptions: Map.get(proposal, :freshness_assumptions, %{}),
        basis_risk: Map.get(proposal, :basis_risk, %{}),
        counterparty_risk: Map.get(proposal, :counterparty_risk, %{}),
        portfolio_margin_netting: false
      }
    end
  end

  defp build_plan(legs, hedge, proposal) do
    %{
      legs:
        Enum.map(legs, fn leg ->
          Map.take(leg, [:id, :venue, :account, :symbol, :side, :amount, :price, :type])
        end),
      hedge: hedge && Map.take(hedge, hedge_plan_keys()),
      venue_policy: proposal.venue_policy,
      risk_targets: proposal.risk_targets,
      hard_limits: proposal.hard_limits
    }
  end

  defp hedge_plan_keys do
    [
      :candidate_id,
      :venue,
      :account,
      :symbol,
      :side,
      :quantity,
      :signed_quantity,
      :residual_delta,
      :target_delta,
      :cross_venue?,
      :feasible?,
      :reason
    ]
  end

  defp map_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp request_opts(row, opts) do
    (Map.get(row, :request_opts) || []) ++ Keyword.get(opts, :request_opts, [])
  end

  defp apply_freshness_assumptions(opts, proposal) do
    assumptions =
      case Map.get(proposal, :freshness_assumptions) do
        value when is_map(value) -> value
        _ -> %{}
      end

    max_age_ms = Map.get(assumptions, :max_age_ms) || Map.get(assumptions, "max_age_ms")
    maybe_put(opts, :max_age_ms, Keyword.get(opts, :max_age_ms, max_age_ms))
  end

  defp market_observed_at(row, observed_at) do
    Map.get(row, :market_observed_at) ||
      if(match?(%Exchange{}, Map.get(row, :exchange)), do: observed_at)
  end

  defp resolve_quote(%{quote: quote}, _greeks) when is_map(quote), do: quote

  defp resolve_quote(_leg, %InstrumentGreeks{} = greeks) do
    if is_number(greeks.bid_price) or is_number(greeks.ask_price) do
      %{bid: greeks.bid_price, ask: greeks.ask_price, timestamp: greeks.source_timestamp}
    end
  end

  defp quote_observed_at(%{quote: quote}, _greeks_observed_at, observed_at) when is_map(quote), do: observed_at
  defp quote_observed_at(_leg, greeks_observed_at, _observed_at), do: greeks_observed_at

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
