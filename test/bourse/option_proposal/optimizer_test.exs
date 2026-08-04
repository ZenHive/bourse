defmodule Bourse.OptionProposal.OptimizerTest do
  use ExUnit.Case, async: true

  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.OptionProposal
  alias Bourse.OptionProposal.Hedge
  alias Bourse.OptionProposal.Projection
  alias Bourse.Unified.OptionQuantity
  alias Bourse.Unified.OptionSurface

  @greeks [:delta, :gamma, :vega]
  @epsilon 1.0e-10
  @market_load_timeout_ms 120_000

  describe "optimize/1 golden problems" do
    test "solves caller-approved quantities across delta, gamma, and vega into the v1 plan shape" do
      first = option_instrument("call", "buy", greeks(delta: 0.5, gamma: 0.1, vega: 0.2))
      second = option_instrument("put", "sell", greeks(delta: -0.5, gamma: 0.1, vega: 0.2))

      problem =
        problem(
          instruments: [first, second],
          objectives: objectives(first.greeks, delta: 1.0, gamma: 0.0, vega: 0.0),
          hard_limits: greek_limits(1.0)
        )

      assert {:ok, result} = OptionProposal.optimize(problem)
      assert result.status == :feasible
      assert result.diagnosis == nil
      assert result.exposures == %{delta: 1.0, gamma: 0.0, vega: 0.0}
      assert result.objective_residuals == %{delta: 0.0, gamma: 0.0, vega: 0.0}

      assert result.plan |> Map.keys() |> Enum.sort() ==
               [:hard_limits, :hedge, :legs, :risk_targets, :venue_policy]

      assert result.plan.hedge == nil
      assert result.plan.risk_targets == %{delta: 1.0, gamma: 0.0, vega: 0.0}
      assert Enum.map(result.plan.legs, &{&1.id, &1.side, &1.amount}) == [{"call", "buy", 1.0}, {"put", "sell", 1.0}]
      assert Enum.map(result.allocations, &{&1.id, &1.signed_quantity}) == [{"call", 1.0}, {"put", -1.0}]
      assert Enum.all?(result.unit_contracts, fn {_greek, contract} -> contract.underlying == "BTC" end)
    end

    test "weights, hard limits, and caller tie-break order each change deterministic selection" do
      delta_heavy = option_instrument("delta", "buy", greeks(delta: 0.8, gamma: 0.2, vega: 0.0), max: 1)
      gamma_heavy = option_instrument("gamma", "buy", greeks(delta: 0.2, gamma: 0.8, vega: 0.0), max: 1)
      broad = objectives(delta_heavy.greeks, [delta: 0.6, gamma: 0.6, vega: 0.0], tolerance: 1.0)

      assert {:ok, delta_result} =
               OptionProposal.optimize(
                 problem(
                   instruments: [delta_heavy, gamma_heavy],
                   objectives: put_in(broad, [:delta, :weight], 10.0)
                 )
               )

      assert selected_ids(delta_result) == ["delta"]

      gamma_weighted =
        broad
        |> put_in([:delta, :weight], 1.0)
        |> put_in([:gamma, :weight], 10.0)

      assert {:ok, gamma_result} =
               OptionProposal.optimize(problem(instruments: [delta_heavy, gamma_heavy], objectives: gamma_weighted))

      assert selected_ids(gamma_result) == ["gamma"]

      constrained = problem(instruments: [delta_heavy, gamma_heavy], objectives: broad, hard_limits: %{delta: 0.5})

      assert {:ok, constrained_result} = OptionProposal.optimize(constrained)
      assert selected_ids(constrained_result) == ["gamma"]
      assert constrained_result.plan.hard_limits == %{delta: 0.5}

      identical = [
        option_instrument("preferred", "buy", greeks(delta: 1.0, gamma: 0.0, vega: 0.0), max: 1),
        option_instrument("fallback", "buy", greeks(delta: 1.0, gamma: 0.0, vega: 0.0), max: 1)
      ]

      tie_problem =
        problem(
          instruments: identical,
          objectives: %{delta: objective(hd(identical).greeks, :delta, 1.0, 0.0, 1.0)},
          hard_limits: %{delta: %{max_abs: 2.0}},
          tie_break_policy: [:min_active_instruments, :prefer_instrument_order]
        )

      assert {:ok, tie_result} = OptionProposal.optimize(tie_problem)
      assert selected_ids(tie_result) == ["preferred"]
    end

    test "returns a diagnosis, never a nearest green plan, when objectives are infeasible" do
      instrument = option_instrument("small", "buy", greeks(delta: 0.3), max: 1)

      assert {:ok, result} =
               OptionProposal.optimize(
                 problem(
                   instruments: [instrument],
                   objectives: %{delta: objective(instrument.greeks, :delta, 1.0, 0.01, 1.0)},
                   hard_limits: %{residual_delta_abs: 0.01}
                 )
               )

      assert result.status == :infeasible
      assert result.plan == nil
      assert result.allocations == []
      assert result.diagnosis.code == :objectives_infeasible
      assert result.diagnosis.closest.exposures.delta == 0.3
      assert [%{greek: :delta}] = result.diagnosis.closest.objective_violations
      assert [%{greek: :delta, kind: :residual_max_abs}] = result.diagnosis.closest.hard_limit_breaches
    end

    test "one-instrument delta-only optimization is equivalent to v1 hedge sizing" do
      market = linear_perp()

      hedge = %{
        id: "perp",
        venue: "deribit",
        account: "main",
        symbol: market.symbol,
        side: "sell",
        market: market,
        quantity_limits: %{min: 0.0, max: 1.0}
      }

      baseline = [
        %{
          underlying: "BTC",
          greeks: %{delta: %{value: 0.23, unit_convention: Projection.delta_convention()}}
        }
      ]

      objective = %{
        delta: %{
          target: 0.0,
          tolerance: 0.05,
          weight: 1.0,
          underlying: "BTC",
          unit_convention: Projection.delta_convention()
        }
      }

      assert {:ok, optimized} =
               OptionProposal.optimize(
                 problem(
                   instruments: [hedge],
                   objectives: objective,
                   hard_limits: %{residual_delta_abs: 0.05},
                   baseline_contributions: baseline
                 )
               )

      v1_candidate = Map.delete(hedge, :quantity_limits)
      assert {:ok, v1} = Hedge.calculate(0.23, 0.0, [v1_candidate], :same_only, ["deribit"])

      assert optimized.plan.legs == []
      assert optimized.plan.hedge.quantity == v1.quantity
      assert optimized.plan.hedge.signed_quantity == v1.signed_quantity
      assert_in_delta optimized.plan.hedge.residual_delta, v1.residual_delta, @epsilon
      assert optimized.plan.hedge.side == v1.side

      assert optimized.plan.hedge |> Map.keys() |> Enum.sort() ==
               [
                 :account,
                 :candidate_id,
                 :cross_venue?,
                 :feasible?,
                 :quantity,
                 :reason,
                 :residual_delta,
                 :side,
                 :signed_quantity,
                 :symbol,
                 :target_delta,
                 :venue
               ]
    end

    test "OKX-style contract multipliers stay canonical through optimization and native conversion" do
      market = contracts_option_market()
      instrument = option_instrument("okx", "buy", greeks(), market: market, min: 0.3, max: 0.3)

      targets = %{delta: 0.15, gamma: 0.03, vega: 0.06}

      assert {:ok, result} =
               OptionProposal.optimize(
                 problem(
                   instruments: [instrument],
                   objectives: objectives(instrument.greeks, Keyword.new(targets), tolerance: @epsilon),
                   hard_limits: %{
                     delta: %{min: 0.15, max: 0.15},
                     gamma: %{min: 0.03, max: 0.03},
                     vega: %{min: 0.06, max: 0.06}
                   }
                 )
               )

      assert result.status == :feasible
      assert [%{amount: 0.3}] = result.plan.legs
      assert [%{quantity: 0.3, quantity_unit: "base", grid_count: 3}] = result.allocations
      assert {:ok, 3} = OptionQuantity.to_native(market, result.plan.legs |> hd() |> Map.fetch!(:amount))
    end

    @tag :network
    test "live OKX units preserve venue-valid quantities and provider Greek conventions" do
      assert {:ok, exchange} = Bourse.exchange("okx", sandbox: true, hostname: "www.okx.com")
      assert {:ok, markets} = Bourse.fetch_markets(exchange, timeout: @market_load_timeout_ms)
      exchange = %{exchange | markets: markets}

      [first_market, second_market | _rest] =
        Enum.filter(markets, fn market ->
          market.option == true and market.active != false and market.base == "BTC" and
            is_number(get_in(market.precision, ["amount"]))
        end)

      assert {:ok, %InstrumentGreeks{} = first_greeks} =
               OptionSurface.instrument_greeks(exchange, first_market.symbol)

      assert {:ok, %InstrumentGreeks{} = second_greeks} =
               OptionSurface.instrument_greeks(exchange, second_market.symbol)

      first_greeks = %{first_greeks | underlying_price: Bourse.Safe.number(first_greeks.info["fwdPx"])}
      second_greeks = %{second_greeks | underlying_price: Bourse.Safe.number(second_greeks.info["fwdPx"])}

      assert is_number(first_greeks.underlying_price) and first_greeks.underlying_price > 0
      assert is_number(second_greeks.underlying_price) and second_greeks.underlying_price > 0

      first_step = first_market.precision["amount"]
      second_step = second_market.precision["amount"]

      first =
        option_instrument(first_market.id, "buy", first_greeks,
          venue: "okx",
          market: first_market,
          min: first_step,
          max: first_step
        )

      second =
        option_instrument(second_market.id, "sell", second_greeks,
          venue: "okx",
          market: second_market,
          min: second_step,
          max: second_step
        )

      targets =
        Map.new(@greeks, fn greek ->
          target = first_step * Map.fetch!(first_greeks, greek) - second_step * Map.fetch!(second_greeks, greek)
          {greek, target}
        end)

      live_objectives =
        Map.new(targets, fn {greek, target} ->
          {greek, objective(first_greeks, greek, target, @epsilon, 1.0)}
        end)

      live_limits =
        Map.new(targets, fn {greek, target} ->
          {greek, %{min: target - @epsilon, max: target + @epsilon}}
        end)

      assert {:ok, result} =
               OptionProposal.optimize(
                 problem(
                   instruments: [first, second],
                   objectives: live_objectives,
                   hard_limits: live_limits
                 )
               )

      assert result.status == :feasible
      assert Enum.map(result.plan.legs, & &1.amount) == [first_step, second_step]

      assert {:ok, first_native} = OptionQuantity.to_native(first_market, first_step)
      assert {:ok, second_native} = OptionQuantity.to_native(second_market, second_step)
      assert first_native == first_market.native_amount_step
      assert second_native == second_market.native_amount_step

      for greek <- @greeks do
        convention = first_greeks.conventions[Atom.to_string(greek)]

        assert result.unit_contracts[greek].unit_convention ==
                 Map.take(convention, ~w(denomination unit bump_size time_basis))
      end
    end
  end

  describe "canonical unit and input failures" do
    test "rejects incompatible candidate, objective, and baseline Greek units before search" do
      first = option_instrument("first", "buy", greeks())

      incompatible_greeks =
        greeks(conventions: put_in(conventions(), ["vega", "bump_size"], 1.0))

      second = option_instrument("second", "buy", incompatible_greeks)

      assert {:error, {:incompatible_greek_convention, :vega}} =
               OptionProposal.optimize(problem(instruments: [first, second]))

      mismatched_objectives =
        first.greeks
        |> objectives()
        |> put_in([:gamma, :unit_convention, "bump_size"], 2.0)

      assert {:error, {:incompatible_objective_unit, :gamma, "first"}} =
               OptionProposal.optimize(problem(instruments: [first], objectives: mismatched_objectives))

      baseline = [
        %{
          underlying: "BTC",
          greeks: %{
            delta: %{
              value: 1.0,
              unit_convention: Map.put(objective_convention(first.greeks, :delta), "unit", "contracts")
            }
          }
        }
      ]

      assert {:error, {:incompatible_baseline_unit, :delta}} =
               OptionProposal.optimize(problem(instruments: [first], baseline_contributions: baseline))
    end

    test "rejects mixed underlyings and non-representable canonical bounds" do
      btc = option_instrument("btc", "buy", greeks())
      eth_market = %{option_market() | symbol: "ETH/USD:ETH-270101-3000-C", base: "ETH"}
      eth = option_instrument("eth", "buy", greeks(), market: eth_market)

      assert {:error, {:mixed_underlyings, ["BTC", "ETH"]}} =
               OptionProposal.optimize(problem(instruments: [btc, eth]))

      invalid = option_instrument("invalid", "buy", greeks(), market: contracts_option_market(), max: 0.15)

      assert {:error, :quantity_bound_not_representable} =
               OptionProposal.optimize(problem(instruments: [invalid]))
    end

    test "rejects unsupported shapes, policies, limits, and oversized search spaces" do
      instrument = option_instrument("one", "buy", greeks(), max: 2)
      valid = problem(instruments: [instrument])

      for {change, expected} <- [
            {&Map.delete(&1, :objectives), {:missing_optimization_fields, [:objectives]}},
            {&Map.put(&1, :instruments, []), :optimization_requires_instruments},
            {&Map.put(&1, :objectives, nil), :optimization_requires_objectives},
            {&Map.put(&1, :objectives, %{unknown: %{}}), {:unsupported_optimization_objective, :unknown}},
            {&Map.update!(&1, :objectives, fn objectives -> Map.put(objectives, :charm, %{}) end),
             {:unsupported_optimization_objective, :charm}},
            {&Map.put(&1, :objectives, %{delta: :invalid}), {:invalid_objective, :delta}},
            {&put_in(&1, [:instruments, Access.at(0), :side], "hold"), {:invalid_instrument_side, "hold"}},
            {&Map.put(&1, :tie_break_policy, []), :tie_break_policy_required},
            {&Map.put(&1, :tie_break_policy, [:unknown]), {:invalid_tie_breaker, :unknown}},
            {&Map.put(&1, :venue_policy, :unknown), {:invalid_venue_policy, :unknown}},
            {&Map.put(&1, :hard_limits, nil), :optimization_requires_hard_limits},
            {&Map.put(&1, :hard_limits, %{delta: :invalid}), {:invalid_hard_limit, :delta}},
            {&Map.put(&1, :hard_limits, %{residual_delta_abs: -1}), {:invalid_residual_hard_limit, :delta}},
            {&Map.put(&1, :hard_limits, %{theta: %{max_abs: 1}}), {:unsupported_optimization_hard_limit, :theta}},
            {&Map.put(&1, :hard_limits, %{notional: 1}), {:unsupported_optimization_hard_limit, :notional}},
            {&Map.put(&1, :baseline_contributions, :invalid), :invalid_baseline_contributions},
            {&Map.put(&1, :max_combinations, 0), :invalid_max_combinations},
            {&Map.put(&1, :max_combinations, 1), {:search_space_too_large, %{combinations: 3, limit: 1}}}
          ] do
        assert {:error, ^expected} = OptionProposal.optimize(change.(valid))
      end

      assert {:error, :invalid_optimization_problem} = OptionProposal.optimize(:invalid)
    end

    test "rejects malformed instruments before they can enter the search" do
      option = option_instrument("option", "buy", greeks())

      inactive_market = %{option.market | active: false}
      missing_precision = %{option.market | precision: %{}}
      missing_semantics = %{option.market | quantity_unit: nil}

      for {instrument, expected} <- [
            {Map.delete(option, :market), :invalid_optimization_instrument},
            {%{option | market: inactive_market}, :inactive_market},
            {Map.delete(option, :greeks), :option_instrument_requires_greeks},
            {%{option | market: missing_precision}, :missing_amount_precision},
            {%{option | market: missing_semantics}, :missing_option_quantity_semantics},
            {%{option | quantity_limits: :invalid}, :invalid_quantity_limits},
            {%{option | quantity_limits: %{min: -1, max: 1}}, :invalid_quantity_limits}
          ] do
        assert {:error, ^expected} = OptionProposal.optimize(problem(instruments: [instrument]))
      end

      broken_hedge_market = %{linear_perp() | precision: nil}
      broken_hedge = hedge_instrument("broken", broken_hedge_market)

      assert {:error, :missing_amount_precision} =
               OptionProposal.optimize(problem(instruments: [broken_hedge]))
    end

    test "enforces instrument-role, objective-underlying, and venue-bound invariants" do
      first_hedge = hedge_instrument("first", linear_perp())
      second_market = %{linear_perp() | symbol: "BTC/USD:BTC-SECOND"}
      second_hedge = hedge_instrument("second", second_market)

      assert {:error, :multiple_hedges_break_v1_plan_shape} =
               OptionProposal.optimize(problem(instruments: [first_hedge, second_hedge]))

      option = option_instrument("option", "buy", greeks())
      wrong_underlying = put_in(objectives(option.greeks), [:delta, :underlying], "ETH")

      assert {:error, {:incompatible_objective_underlying, :delta, "option"}} =
               OptionProposal.optimize(problem(instruments: [option], objectives: wrong_underlying))

      no_limits_market = %{option.market | limits: nil}
      no_limits = %{option | market: no_limits_market, quantity_limits: %{min: 0, max: 1}}
      assert {:ok, %{status: :feasible}} = OptionProposal.optimize(problem(instruments: [no_limits]))

      malformed_limits_market = %{option.market | limits: %{"amount" => :invalid}}
      malformed_limits = %{option | market: malformed_limits_market, quantity_limits: %{min: 0, max: 1}}
      assert {:ok, %{status: :feasible}} = OptionProposal.optimize(problem(instruments: [malformed_limits]))

      zero_only_market = %{option.market | limits: %{"amount" => %{"min" => 2.0, "max" => 2.0}}}
      zero_only = %{option | market: zero_only_market, quantity_limits: %{min: 0, max: 1}}

      assert {:ok, %{status: :feasible, allocations: [%{quantity: quantity}]}} =
               OptionProposal.optimize(problem(instruments: [zero_only]))

      assert quantity == 0

      cross_venue_hedge =
        "cross"
        |> hedge_instrument(linear_perp())
        |> Map.put(:venue, "okx")

      assert {:error, :no_same_venue_hedge_candidate} =
               OptionProposal.optimize(problem(instruments: [option, cross_venue_hedge]))

      assert {:ok, %{status: :feasible, plan: %{hedge: %{cross_venue?: true}}}} =
               OptionProposal.optimize(
                 problem(
                   instruments: [option, cross_venue_hedge],
                   venue_policy: :cross_allowed,
                   tie_break_policy: [:min_active_instruments, :prefer_instrument_order]
                 )
               )
    end

    test "rejects quantity-unit-dependent tie breaks across base options and perp contracts" do
      option = option_instrument("option", "buy", greeks(), max: 1)
      perp_market = linear_perp()

      perp = %{
        id: "perp",
        venue: "deribit",
        account: "main",
        symbol: perp_market.symbol,
        side: "sell",
        market: perp_market,
        quantity_limits: %{min: 0.0, max: 1.0}
      }

      assert {:error, {:incompatible_tie_break_quantity_units, ["base", "contracts"]}} =
               OptionProposal.optimize(
                 problem(
                   instruments: [option, perp],
                   tie_break_policy: [:min_total_quantity]
                 )
               )
    end
  end

  defp problem(overrides) do
    instrument = option_instrument("default", "buy", greeks())

    Map.merge(
      %{
        instruments: [instrument],
        objectives: objectives(instrument.greeks),
        hard_limits: greek_limits(10.0),
        tie_break_policy: [:min_total_quantity, :min_active_instruments, :prefer_instrument_order],
        venue_policy: :same_only,
        baseline_contributions: []
      },
      Map.new(overrides)
    )
  end

  defp option_instrument(id, side, instrument_greeks, overrides \\ []) do
    market = Keyword.get(overrides, :market, %{option_market() | symbol: "BTC/USD:BTC-270101-#{id}-C"})

    %{
      id: id,
      venue: Keyword.get(overrides, :venue, "deribit"),
      account: "main",
      symbol: market.symbol,
      side: side,
      market: market,
      greeks: instrument_greeks,
      price: 0.01,
      type: "limit",
      quantity_limits: %{
        min: Keyword.get(overrides, :min, 0.0),
        max: Keyword.get(overrides, :max, 2.0)
      }
    }
  end

  defp hedge_instrument(id, market) do
    %{
      id: id,
      venue: "deribit",
      account: "main",
      symbol: market.symbol,
      side: "sell",
      market: market,
      quantity_limits: %{min: 0.0, max: 1.0}
    }
  end

  defp objectives(instrument_greeks, targets \\ [delta: 0.0, gamma: 0.0, vega: 0.0], opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @epsilon)

    Map.new(@greeks, fn greek ->
      target = Keyword.get(targets, greek, 0.0)
      {greek, objective(instrument_greeks, greek, target, tolerance, 1.0)}
    end)
  end

  defp objective(instrument_greeks, greek, target, tolerance, weight) do
    %{
      target: target,
      tolerance: tolerance,
      weight: weight,
      underlying: "BTC",
      unit_convention: objective_convention(instrument_greeks, greek)
    }
  end

  defp objective_convention(instrument_greeks, greek) do
    instrument_greeks.conventions
    |> Map.fetch!(Atom.to_string(greek))
    |> Map.take(~w(denomination unit bump_size time_basis))
  end

  defp greek_limits(maximum) do
    Map.new(@greeks, &{&1, %{max_abs: maximum}})
  end

  defp selected_ids(result) do
    result.allocations
    |> Enum.reject(&(&1.quantity == 0))
    |> Enum.map(& &1.id)
  end

  defp greeks(overrides \\ []) do
    struct!(
      InstrumentGreeks,
      Keyword.merge(
        [
          delta: 0.5,
          gamma: 0.1,
          vega: 0.2,
          theta: -0.05,
          underlying_price: 100_000.0,
          conventions: conventions()
        ],
        overrides
      )
    )
  end

  defp conventions do
    %{
      "delta" => convention("underlying", "ratio", 1.0),
      "gamma" => convention("delta", "delta_per_underlying_unit", 1.0),
      "vega" => convention("option_premium", "premium_per_vol_point", 0.01),
      "theta" => convention("option_premium", "premium_per_day", 1.0, "calendar_day")
    }
  end

  defp convention(denomination, unit, bump_size, time_basis \\ nil) do
    %{
      "supported" => true,
      "native_field" => "greeks",
      "denomination" => denomination,
      "unit" => unit,
      "bump_size" => bump_size,
      "time_basis" => time_basis
    }
  end

  defp option_market do
    %Market{
      id: "BTC-OPTION",
      symbol: "BTC/USD:BTC-270101-100000-C",
      base: "BTC",
      quote: "USD",
      settle: "BTC",
      type: "option",
      option: true,
      contract: true,
      active: true,
      quantity_unit: "base",
      native_quantity_unit: "base",
      native_quantity_field: "amount",
      native_amount_step: 1.0,
      contract_size: 1.0,
      precision: %{"amount" => 1.0},
      limits: %{"amount" => %{"min" => 1.0, "max" => 2.0}}
    }
  end

  defp contracts_option_market do
    %{
      option_market()
      | id: "BTC-USD-OPTION",
        symbol: "BTC/USD:BTC-270101-90000-C",
        native_quantity_unit: "contracts",
        native_quantity_field: "sz",
        native_amount_step: 1.0,
        contract_size: 0.1,
        precision: %{"amount" => 0.1},
        limits: %{"amount" => %{"min" => 0.1, "max" => 1.0}}
    }
  end

  defp linear_perp do
    %Market{
      id: "BTC-PERPETUAL",
      symbol: "BTC/USD:BTC",
      base: "BTC",
      quote: "USD",
      settle: "BTC",
      type: "swap",
      swap: true,
      contract: true,
      linear: true,
      inverse: false,
      active: true,
      contract_size: 1.0,
      precision: %{"amount" => 0.1},
      limits: %{"amount" => %{"min" => 0.1, "max" => 10.0}}
    }
  end
end
