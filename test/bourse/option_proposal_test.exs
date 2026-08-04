defmodule Bourse.OptionProposalTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.OptionProposal
  alias Bourse.OptionProposal.Result
  alias Bourse.PortfolioRisk.Snapshot

  @observed_at 1_800_000_000_000
  @option_expiry 1_769_817_600_000
  @option_strike 100_000.0

  describe "preflight/2" do
    test "approves a multi-venue plan, projects Greeks/notional, and sizes the hedge" do
      proposal = multi_venue_proposal()

      assert {:ok, %Result{status: :approved} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert result.violations == []
      assert result.failures == []
      assert result.strategy == %{label: "manual-call-spread"}
      assert result.plan.venue_policy == :prefer_same_venue
      assert length(result.plan.legs) == 2

      assert_in_delta result.projected.legs_total.delta, 0.1 * 0.5 + 0.05 * 0.4, 1.0e-12
      assert is_number(result.projected.notional)
      assert result.projected.post_trade_after_hedge.delta |> abs() |> Kernel.<=(0.01)

      assert result.hedge.side in ["buy", "sell"]
      assert is_number(result.hedge.residual_delta)
      assert result.hedge.candidate_id == "same-hedge"

      assert Enum.all?(result.margin_domains, &(&1.portfolio_margin_netting == false))
      assert is_map(result.cross_venue)
      assert result.cross_venue.portfolio_margin_netting == false
      assert result.cross_venue.valuation_assumptions == %{btc_usd: 100_000}
      assert result.cross_venue.basis_risk == %{note: "deribit-vs-okx"}
      assert result.cross_venue.counterparty_risk == %{venues: ["deribit", "okx"]}
      assert length(result.cross_venue.collateral_pools) >= 2

      check_names = Enum.map(result.checks, & &1.name)

      assert check_names == [
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

      assert Enum.all?(result.checks, &(&1.status == :ok))
    end

    test "covers long/short signs, zero hedge, and residual reporting" do
      long = option_leg(id: "long", side: "buy", amount: 0.1, delta: 0.5)
      short = option_leg(id: "short", side: "sell", amount: 0.1, delta: 0.5)
      # net delta ~0 already
      proposal =
        base_proposal(
          legs: [long, short],
          hedge_candidates: [hedge_candidate()],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 1.0e-9, delta: %{max_abs: 1.0}},
          venue_policy: :same_only
        )

      assert {:ok, %Result{status: :approved} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert result.hedge.quantity == 0.0
      assert_in_delta result.hedge.residual_delta, 0.0, 1.0e-12
      assert_in_delta result.projected.post_trade_before_hedge.delta, 0.0, 1.0e-12
    end

    test "same_only fails when only a cross-venue hedge exists; cross_allowed accepts it" do
      leg = option_leg(venue: "deribit")
      cross = hedge_candidate(id: "x", venue: "okx", account: "demo")

      same_only =
        base_proposal(
          legs: [leg],
          hedge_candidates: [cross],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 0.05, delta: %{max_abs: 1.0}},
          venue_policy: :same_only
        )

      assert {:ok, %Result{status: :rejected} = same_only_result} =
               OptionProposal.preflight(same_only, observed_at: @observed_at)

      assert Enum.any?(same_only_result.violations, &(&1.code == :hedge_infeasible))

      cross_allowed =
        same_only
        |> Map.put(:venue_policy, :cross_allowed)
        |> Map.put(:valuation_assumptions, %{btc_usd: 100_000})
        |> Map.put(:basis_risk, %{note: "caller-accepted"})
        |> Map.put(:counterparty_risk, %{venues: ["deribit", "okx"]})

      assert {:ok, %Result{status: :approved} = result} =
               OptionProposal.preflight(cross_allowed, observed_at: @observed_at)

      assert result.hedge.cross_venue? == true
      assert result.cross_venue.portfolio_margin_netting == false
    end

    test "infeasible residual limit and hard gamma limit produce stable actionable violations" do
      # amount 0.13 * delta 0.5 = 0.065; step 0.1 => residual 0.065 after zero-ish hedge
      leg = option_leg(amount: 0.13, delta: 0.5)
      candidate = hedge_candidate(market: linear_perp(step: 0.1, contract_size: 1.0))

      residual_fail =
        base_proposal(
          legs: [leg],
          hedge_candidates: [candidate],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 0.001, gamma: %{max_abs: 100.0}},
          venue_policy: :same_only
        )

      assert {:ok, %Result{status: :rejected} = residual_result} =
               OptionProposal.preflight(residual_fail, observed_at: @observed_at)

      assert Enum.any?(
               residual_result.violations,
               &(&1.code in [:residual_delta_exceeds_limit, :post_trade_limit_violation])
             )

      assert is_number(residual_result.hedge.residual_delta)

      gamma_fail =
        base_proposal(
          legs: [option_leg(amount: 1.0, gamma: 0.5)],
          hedge_candidates: [hedge_candidate()],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 1.0, gamma: %{max_abs: 0.1}},
          venue_policy: :same_only
        )

      assert {:ok, %Result{status: :rejected} = gamma_result} =
               OptionProposal.preflight(gamma_fail, observed_at: @observed_at)

      assert Enum.any?(gamma_result.violations, &(&1.code == :post_trade_limit_violation))
      # Stable check order
      assert Enum.map(gamma_result.checks, & &1.name) == Enum.map(residual_result.checks, & &1.name)
    end

    test "unknown account capacity cannot convert into approval" do
      snapshot = %Snapshot{
        status: :partial,
        observed_at: @observed_at,
        domains: [
          %{
            venue: "deribit",
            account: "main",
            components: %{
              balance: %{
                status: :error,
                error: %Error{type: :network_error, message: "timeout"},
                observed_at: @observed_at
              },
              positions: %{status: :ok, data: [], observed_at: @observed_at},
              open_orders: %{status: :ok, data: [], observed_at: @observed_at}
            },
            margin: {:ok, []},
            collateral: {:ok, []},
            available_capacity: {:error, %Error{type: :network_error, message: "timeout"}},
            account_modes: {:ok, []},
            liquidation_state: {:ok, []}
          }
        ],
        contributions: [],
        aggregates: [],
        blocked_buckets: [],
        failures: [%{venue: "deribit", account: "main", component: :balance, reason: :timeout}]
      }

      proposal =
        base_proposal(
          legs: [option_leg()],
          hedge_candidates: [hedge_candidate()],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 0.05, required_capacity: %{"BTC" => 0.01}},
          venue_policy: :same_only,
          snapshot: snapshot
        )

      assert {:ok, %Result{status: :rejected} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert Enum.any?(result.violations, &(&1.code == :unknown_account_capacity))
      assert Enum.any?(result.failures, &(&1.component in [:account_capacity, :balance]))
      # Failed venue is not treated as zero exposure — failures remain queryable
      assert result.failures != []
      assert result.projected.legs_total.delta != 0
    end

    test "stale greeks, inactive markets and changed positions fail explicitly" do
      stale =
        base_proposal(
          legs: [option_leg(greeks: %{greeks() | source_timestamp: @observed_at - 60_000})],
          hedge_candidates: [hedge_candidate()],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 1.0},
          venue_policy: :same_only
        )

      assert {:ok, %Result{status: :rejected} = stale_result} =
               OptionProposal.preflight(stale, observed_at: @observed_at, max_age_ms: 1_000)

      assert Enum.any?(stale_result.violations, &(&1.code == :stale_or_missing_greeks))

      inactive =
        base_proposal(
          legs: [option_leg(market: %{option_market() | active: false})],
          hedge_candidates: [hedge_candidate()],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 1.0},
          venue_policy: :same_only
        )

      assert {:ok, %Result{status: :rejected} = inactive_result} =
               OptionProposal.preflight(inactive, observed_at: @observed_at)

      assert Enum.any?(inactive_result.violations, &(&1.code == :inactive_market))

      snapshot = complete_snapshot()

      changed =
        base_proposal(
          legs: [option_leg()],
          hedge_candidates: [hedge_candidate()],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 1.0},
          venue_policy: :same_only,
          snapshot: snapshot,
          expected_positions: [
            %{venue: "deribit", account: "main", symbol: "BTC/USD:BTC-260131-100000-C", contracts: 9}
          ]
        )

      assert {:ok, %Result{status: :rejected} = changed_result} =
               OptionProposal.preflight(changed, observed_at: @observed_at)

      assert Enum.any?(changed_result.violations, &(&1.code == :positions_changed))
    end

    test "future caller timestamps beyond the bounded skew tolerance fail closed" do
      future_timestamp = @observed_at + 60_000

      leg =
        option_leg(
          greeks: %{greeks() | source_timestamp: future_timestamp},
          quote: %{bid: 0.04, ask: 0.06, timestamp: future_timestamp}
        )

      assert {:ok, %Result{status: :rejected} = result} =
               OptionProposal.preflight(
                 base_proposal(legs: [leg]),
                 observed_at: @observed_at,
                 max_age_ms: 1_000
               )

      codes = MapSet.new(result.violations, & &1.code)
      assert MapSet.member?(codes, :stale_or_missing_quote)
      assert MapSet.member?(codes, :stale_or_missing_greeks)
    end

    test "default observed_at accepts self-fetched quotes and Greeks and sizes a caller-priced inverse hedge" do
      option = %{option_market() | expiry: @option_expiry, option_type: "call", strike: @option_strike}
      inverse = inverse_perp(step: 1, contract_size: 100.0)

      exchange =
        "deribit"
        |> Exchange.new!()
        |> Map.put(:markets, [option, inverse])

      stub = live_greeks_stub()

      proposal = %{
        legs: [
          %{
            id: "option",
            venue: "deribit",
            account: "main",
            symbol: option.symbol,
            side: "buy",
            amount: 0.1,
            price: 0.05,
            exchange: exchange
          }
        ],
        hedge_candidates: [
          %{
            id: "inverse",
            venue: "deribit",
            account: "main",
            symbol: inverse.symbol,
            exchange: exchange,
            price: 20_000.0
          }
        ],
        risk_targets: %{delta: 0.0},
        hard_limits: %{residual_delta_abs: 0.01},
        venue_policy: :same_only,
        freshness_assumptions: %{max_age_ms: 5_000}
      }

      assert {:ok, %Result{} = result} =
               OptionProposal.preflight(proposal, request_opts: [plug: {Req.Test, stub}])

      assert check(result, :quote).status == :ok
      assert check(result, :greeks).status == :ok
      assert result.hedge.feasible?
      assert result.hedge.candidate_id == "inverse"
      assert result.hedge.delta_per_unit == 0.005
      assert result.hedge.quantity == 10.0
    end

    test "pins a provider/read failure without zeroing successful domains" do
      snapshot = %Snapshot{
        status: :partial,
        observed_at: @observed_at,
        domains: [
          %{
            venue: "deribit",
            account: "main",
            components: %{
              balance: %{status: :ok, data: %{free: %{"BTC" => 1.0}}, observed_at: @observed_at},
              positions: %{status: :ok, data: [], observed_at: @observed_at},
              open_orders: %{status: :ok, data: [], observed_at: @observed_at}
            },
            margin: {:ok, []},
            collateral: {:ok, []},
            available_capacity: {:ok, %{"BTC" => 1.0}},
            account_modes: {:ok, []},
            liquidation_state: {:ok, []}
          },
          %{
            venue: "okx",
            account: "demo",
            components: %{
              balance: %{status: :error, error: %Error{type: :network_error, message: "down"}, observed_at: @observed_at},
              positions: %{
                status: :error,
                error: %Error{type: :network_error, message: "down"},
                observed_at: @observed_at
              },
              open_orders: %{
                status: :error,
                error: %Error{type: :network_error, message: "down"},
                observed_at: @observed_at
              }
            },
            margin: {:error, :network_error},
            collateral: {:error, :network_error},
            available_capacity: {:error, :network_error},
            account_modes: {:error, :network_error},
            liquidation_state: {:error, :network_error}
          }
        ],
        contributions: [
          %{
            venue: "deribit",
            account: "main",
            source: :balance,
            underlying: "BTC",
            greeks: %{delta: %{value: 0.25, unit_convention: semantic_convention("delta")}}
          }
        ],
        aggregates: [],
        blocked_buckets: [],
        failures: [
          %{venue: "okx", account: "demo", component: :balance, reason: %Error{type: :network_error, message: "down"}}
        ]
      }

      proposal =
        base_proposal(
          legs: [option_leg(), option_leg(id: "okx-leg", venue: "okx", account: "demo", market: option_market("okx"))],
          hedge_candidates: [hedge_candidate()],
          risk_targets: %{delta: 0.0},
          hard_limits: %{residual_delta_abs: 1.0},
          venue_policy: :prefer_same_venue,
          snapshot: snapshot,
          valuation_assumptions: %{note: "caller-fx"},
          freshness_assumptions: %{max_age_ms: 5_000},
          basis_risk: %{spread: 0.01},
          counterparty_risk: %{okx: :demo}
        )

      assert {:ok, %Result{status: :rejected} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert Enum.any?(result.failures, &(&1.venue == "okx"))
      assert result.projected.baseline |> Map.to_list() |> Enum.any?(fn _ -> true end)
      # baseline delta from successful deribit contribution is preserved
      assert_in_delta result.projected.baseline.delta, 0.25, 1.0e-12
      assert result.cross_venue.portfolio_margin_netting == false
      assert result.cross_venue.valuation_assumptions == %{note: "caller-fx"}
    end

    test "enforces caller freshness assumptions for market, quote, Greeks, and portfolio" do
      stale_quote =
        option_leg(
          quote: %{bid: 0.04, ask: 0.06, timestamp: @observed_at - 10_000},
          market_observed_at: @observed_at
        )

      proposal = base_proposal(legs: [stale_quote])

      assert {:ok, %Result{status: :rejected} = quote_result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert Enum.any?(quote_result.violations, &(&1.code == :stale_or_missing_quote))

      stale_market = option_leg(market_observed_at: @observed_at - 10_000)

      assert {:ok, %Result{status: :rejected} = market_result} =
               OptionProposal.preflight(base_proposal(legs: [stale_market]), observed_at: @observed_at)

      assert Enum.any?(market_result.violations, &(&1.code == :stale_market))

      stale_snapshot = %{complete_snapshot() | observed_at: @observed_at - 10_000}

      assert {:ok, %Result{status: :rejected} = portfolio_result} =
               OptionProposal.preflight(base_proposal(snapshot: stale_snapshot), observed_at: @observed_at)

      assert Enum.any?(portfolio_result.violations, &(&1.code == :stale_portfolio))
    end

    test "missing portfolio, freshness constraints, and capacity cannot approve" do
      proposal =
        base_proposal()
        |> Map.delete(:snapshot)
        |> Map.delete(:freshness_assumptions)

      assert {:ok, %Result{status: :rejected} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      codes = MapSet.new(result.violations, & &1.code)
      assert MapSet.member?(codes, :freshness_constraint_missing)
      assert MapSet.member?(codes, :portfolio_check_unsupported)
      assert MapSet.member?(codes, :unknown_account_capacity)
    end

    test "never sums cross-venue capacity to satisfy a domain requirement" do
      proposal =
        put_in(multi_venue_proposal(), [:hard_limits, :required_capacity], [
          %{venue: "deribit", account: "main", currency: "BTC", amount: 2.0},
          %{venue: "okx", account: "demo", currency: "USDT", amount: 500.0}
        ])

      assert {:ok, %Result{status: :rejected} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert Enum.any?(result.violations, fn violation ->
               violation.code == :insufficient_capacity and
                 violation.detail.venue == "deribit" and
                 violation.detail.account == "main"
             end)
    end

    test "cross-venue plans require explicit valuation, freshness, basis, and counterparty assumptions" do
      proposal =
        [
          legs: [option_leg(), option_leg(id: "okx", venue: "okx", account: "demo", market: option_market("okx"))],
          venue_policy: :prefer_same_venue
        ]
        |> base_proposal()
        |> Map.drop([:valuation_assumptions, :basis_risk, :counterparty_risk])

      assert {:ok, %Result{status: :rejected} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert Enum.any?(result.violations, &(&1.code == :missing_cross_venue_assumptions))
    end

    test "a proposal without a delta target still checks other hard limits" do
      proposal =
        base_proposal(
          risk_targets: %{gamma: 0.0},
          hard_limits: %{gamma: %{max_abs: 0.001}}
        )

      assert {:ok, %Result{status: :rejected, hedge: nil} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert Enum.any?(result.violations, &(&1.code == :post_trade_limit_violation))
    end

    test "an unreadable expected-position check is a blocking violation" do
      snapshot =
        update_in(complete_snapshot().domains, fn [domain | rest] ->
          [
            put_in(domain, [:components, :positions], %{status: :error, error: :timeout, observed_at: @observed_at})
            | rest
          ]
        end)

      proposal =
        base_proposal(
          snapshot: snapshot,
          expected_positions: [
            %{venue: "deribit", account: "main", symbol: "BTC/USD:BTC-260131-100000-C", contracts: 1}
          ]
        )

      assert {:ok, %Result{status: :rejected} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert Enum.any?(result.violations, &(&1.code == :positions_unreadable))
    end

    test "rejects structurally invalid proposals before work" do
      assert {:error, %Error{type: :invalid_parameters}} =
               OptionProposal.preflight(%{
                 legs: [],
                 hedge_candidates: [],
                 risk_targets: %{},
                 hard_limits: %{},
                 venue_policy: :same_only
               })

      assert {:error, %Error{type: :invalid_parameters}} =
               OptionProposal.preflight(%{
                 legs: [option_leg()],
                 hedge_candidates: [],
                 risk_targets: %{},
                 hard_limits: %{},
                 venue_policy: :unknown_policy
               })

      for {field, value} <- [
            hedge_candidates: :not_a_list,
            risk_targets: :not_a_map,
            hard_limits: :not_a_map
          ] do
        assert {:error, %Error{type: :invalid_parameters}} =
                 OptionProposal.preflight(Map.put(base_proposal(), field, value))
      end
    end

    test "rejects malformed leg and candidate rows with actionable structural errors" do
      assert {:error, %Error{message: leg_message}} =
               OptionProposal.preflight(base_proposal(legs: [:bad]))

      assert leg_message =~ "each leg must be a map"

      assert {:error, %Error{message: candidate_message}} =
               OptionProposal.preflight(base_proposal(hedge_candidates: [:bad]))

      assert candidate_message =~ "each hedge candidate must be a map"

      assert {:error, %Error{message: missing_message}} =
               OptionProposal.preflight(base_proposal(legs: [Map.delete(option_leg(), :amount)]))

      assert missing_message =~ "missing fields"
    end

    test "rejects missing enrichment inputs and invalid delta targets" do
      no_market = Map.delete(option_leg(), :market)
      assert {:error, %Error{message: market_message}} = OptionProposal.preflight(base_proposal(legs: [no_market]))
      assert market_message =~ "requires a market or exchange"

      exchange = "deribit" |> Exchange.new!() |> Map.put(:markets, [option_market()])

      unknown_market =
        option_leg()
        |> Map.drop([:greeks, :market])
        |> Map.merge(%{exchange: exchange, symbol: "UNKNOWN"})

      assert {:error, %Error{message: unknown_market_message}} =
               OptionProposal.preflight(base_proposal(legs: [unknown_market]))

      assert unknown_market_message =~ "market not found"

      no_greeks = Map.delete(option_leg(), :greeks)
      assert {:error, %Error{message: greek_message}} = OptionProposal.preflight(base_proposal(legs: [no_greeks]))
      assert greek_message =~ "requires greeks or an exchange"

      invalid_greeks = option_leg(greeks: %{greeks() | gamma: :invalid})

      assert {:error, %Error{message: projection_message}} =
               OptionProposal.preflight(base_proposal(legs: [invalid_greeks]))

      assert projection_message =~ "option projection failed"

      no_candidate_market = Map.delete(hedge_candidate(), :market)

      assert {:error, %Error{message: candidate_message}} =
               OptionProposal.preflight(base_proposal(hedge_candidates: [no_candidate_market]))

      assert candidate_message =~ "requires a market or exchange"

      assert {:error, %Error{message: delta_message}} =
               OptionProposal.preflight(base_proposal(risk_targets: %{delta: "flat"}))

      assert delta_message =~ "risk_targets.delta"
    end

    test "builds a zero hedge without candidates and derives a quote from Greeks" do
      greeks = %{greeks() | delta: 0.0, bid_price: 0.04, ask_price: 0.06}
      leg = [greeks: greeks, delta: 0.0] |> option_leg() |> Map.delete(:quote)

      proposal =
        base_proposal(
          legs: [leg],
          hedge_candidates: [],
          risk_targets: %{delta: 0.0}
        )

      assert {:ok, %Result{status: :approved} = result} =
               OptionProposal.preflight(proposal, observed_at: @observed_at)

      assert result.hedge.quantity == 0.0
      assert result.hedge.candidate_id == nil
    end
  end

  describe "calculate_hedge/5 and project/2" do
    test "public pure helpers are available" do
      assert {:ok, projected} = OptionProposal.project([option_leg(amount: 0.1)])
      assert projected.legs_total.delta == 0.05

      assert {:ok, hedge} =
               OptionProposal.calculate_hedge(0.05, 0.0, [hedge_candidate()], :same_only, ["deribit"])

      assert hedge.side == "sell"
    end
  end

  defp multi_venue_proposal do
    base_proposal(
      legs: [
        option_leg(id: "d-leg", venue: "deribit", account: "main", amount: 0.1, delta: 0.5),
        option_leg(
          id: "o-leg",
          venue: "okx",
          account: "demo",
          amount: 0.05,
          delta: 0.4,
          market: option_market("okx")
        )
      ],
      hedge_candidates: [
        hedge_candidate(id: "same-hedge", venue: "deribit"),
        hedge_candidate(
          id: "cross-hedge",
          venue: "bybit",
          account: "sub",
          market: linear_perp(step: 0.001, contract_size: 1.0)
        )
      ],
      risk_targets: %{delta: 0.0},
      hard_limits: %{
        residual_delta_abs: 0.01,
        delta: %{max_abs: 1.0},
        gamma: %{max_abs: 10.0},
        vega: %{max_abs: 10.0},
        theta: %{max_abs: 10.0}
      },
      venue_policy: :prefer_same_venue,
      strategy: %{label: "manual-call-spread"},
      valuation_assumptions: %{btc_usd: 100_000},
      freshness_assumptions: %{max_age_ms: 5_000},
      basis_risk: %{note: "deribit-vs-okx"},
      counterparty_risk: %{venues: ["deribit", "okx"]},
      snapshot: complete_snapshot()
    )
  end

  defp base_proposal(overrides \\ []) do
    Map.merge(
      %{
        legs: [option_leg()],
        hedge_candidates: [hedge_candidate()],
        risk_targets: %{delta: 0.0},
        hard_limits: %{residual_delta_abs: 0.05},
        venue_policy: :same_only,
        freshness_assumptions: %{max_age_ms: 1_000},
        snapshot: complete_snapshot()
      },
      Map.new(overrides)
    )
  end

  defp option_leg(overrides \\ []) do
    market = Keyword.get(overrides, :market, option_market())
    delta = Keyword.get(overrides, :delta, 0.5)
    gamma = Keyword.get(overrides, :gamma, 0.02)

    greeks =
      Keyword.get(overrides, :greeks, %{greeks() | delta: delta, gamma: gamma})

    %{
      id: Keyword.get(overrides, :id, "leg-1"),
      venue: Keyword.get(overrides, :venue, "deribit"),
      account: Keyword.get(overrides, :account, "main"),
      symbol: market.symbol,
      side: Keyword.get(overrides, :side, "buy"),
      amount: Keyword.get(overrides, :amount, 0.1),
      price: Keyword.get(overrides, :price, 0.05),
      type: "limit",
      market: market,
      market_observed_at: Keyword.get(overrides, :market_observed_at, @observed_at),
      greeks: greeks,
      quote: Keyword.get(overrides, :quote, %{bid: 0.04, ask: 0.06, timestamp: @observed_at - 10})
    }
  end

  defp hedge_candidate(overrides \\ []) do
    market = Keyword.get(overrides, :market, linear_perp(step: 0.001, contract_size: 1.0))

    %{
      id: Keyword.get(overrides, :id, "hedge-1"),
      venue: Keyword.get(overrides, :venue, "deribit"),
      account: Keyword.get(overrides, :account, "main"),
      symbol: market.symbol,
      market: market,
      market_observed_at: Keyword.get(overrides, :market_observed_at, @observed_at),
      kind: :perp
    }
  end

  defp option_market(venue \\ "deribit") do
    %Market{
      id: "BTC-31JAN26-100000-C",
      symbol: "BTC/USD:BTC-260131-100000-C",
      base: "BTC",
      quote: "USD",
      settle: if(venue == "okx", do: "USDT", else: "BTC"),
      type: "option",
      option: true,
      contract: true,
      active: true,
      quantity_unit: "base",
      native_quantity_unit: "base",
      native_amount_step: 0.01,
      contract_size: 1,
      precision: %{"amount" => 0.01, "price" => 0.0001},
      limits: %{"amount" => %{"min" => 0.01}, "price" => %{"min" => 0.0001}}
    }
  end

  defp linear_perp(step: step, contract_size: size) do
    %Market{
      id: "BTCUSDT",
      symbol: "BTC/USDT:USDT",
      base: "BTC",
      quote: "USDT",
      settle: "USDT",
      type: "swap",
      swap: true,
      contract: true,
      linear: true,
      inverse: false,
      active: true,
      contract_size: size,
      precision: %{"amount" => step, "price" => 0.1},
      limits: %{"amount" => %{"min" => step}}
    }
  end

  defp inverse_perp(step: step, contract_size: size) do
    %Market{
      id: "BTC-PERPETUAL",
      symbol: "BTC/USD:BTC",
      base: "BTC",
      quote: "USD",
      settle: "BTC",
      type: "swap",
      swap: true,
      contract: true,
      linear: false,
      inverse: true,
      active: true,
      contract_size: size,
      precision: %{"amount" => step, "price" => 0.5},
      limits: %{"amount" => %{"min" => step}},
      info: %{"kind" => "future"}
    }
  end

  defp greeks do
    %InstrumentGreeks{
      delta: 0.5,
      gamma: 0.02,
      vega: 0.1,
      theta: -0.05,
      underlying_price: 100_000.0,
      source_timestamp: @observed_at - 10,
      conventions: Map.new(~w(delta gamma vega theta), &{&1, greek_convention(&1)})
    }
  end

  defp complete_snapshot do
    %Snapshot{
      status: :complete,
      observed_at: @observed_at,
      domains: [
        %{
          venue: "deribit",
          account: "main",
          components: %{
            balance: %{status: :ok, data: %{free: %{"BTC" => 1.0}}, observed_at: @observed_at},
            positions: %{status: :ok, data: [], observed_at: @observed_at},
            open_orders: %{status: :ok, data: [], observed_at: @observed_at}
          },
          margin: {:ok, []},
          collateral: {:ok, []},
          available_capacity: {:ok, %{"BTC" => 1.0}},
          account_modes: {:ok, []},
          liquidation_state: {:ok, []}
        },
        %{
          venue: "okx",
          account: "demo",
          components: %{
            balance: %{status: :ok, data: %{free: %{"USDT" => 1_000.0}}, observed_at: @observed_at},
            positions: %{status: :ok, data: [], observed_at: @observed_at},
            open_orders: %{status: :ok, data: [], observed_at: @observed_at}
          },
          margin: {:ok, []},
          collateral: {:ok, []},
          available_capacity: {:ok, %{"USDT" => 1_000.0}},
          account_modes: {:ok, []},
          liquidation_state: {:ok, []}
        }
      ],
      contributions: [],
      aggregates: [],
      blocked_buckets: [],
      failures: []
    }
  end

  defp live_greeks_stub do
    stub = String.to_atom("option_proposal_#{System.unique_integer([:positive])}")

    Req.Test.stub(stub, fn conn ->
      source_timestamp = System.system_time(:millisecond) + 500

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "testnet" => true,
        "result" => %{
          "instrument_name" => "BTC-31JAN26-100000-C",
          "timestamp" => source_timestamp,
          "best_bid_price" => 0.04,
          "best_ask_price" => 0.06,
          "underlying_price" => 20_000.0,
          "greeks" => %{
            "delta" => 0.5,
            "gamma" => 0.02,
            "vega" => 0.1,
            "theta" => -0.05,
            "rho" => 0.01
          }
        }
      })
    end)

    stub
  end

  defp check(result, name), do: Enum.find(result.checks, &(&1.name == name))

  defp greek_convention("delta") do
    %{
      "supported" => true,
      "native_field" => "delta",
      "denomination" => "underlying",
      "unit" => "ratio",
      "bump_size" => 1.0,
      "time_basis" => nil
    }
  end

  defp greek_convention("gamma") do
    %{
      "supported" => true,
      "native_field" => "gamma",
      "denomination" => "delta",
      "unit" => "delta_per_underlying_unit",
      "bump_size" => 1.0,
      "time_basis" => nil
    }
  end

  defp greek_convention("vega") do
    %{
      "supported" => true,
      "native_field" => "vega",
      "denomination" => "option_premium",
      "unit" => "premium_per_vol_point",
      "bump_size" => 0.01,
      "time_basis" => nil
    }
  end

  defp greek_convention("theta") do
    %{
      "supported" => true,
      "native_field" => "theta",
      "denomination" => "option_premium",
      "unit" => "premium_per_day",
      "bump_size" => 1.0,
      "time_basis" => "calendar_day"
    }
  end

  defp semantic_convention(greek), do: Map.take(greek_convention(greek), ~w(denomination unit bump_size time_basis))
end
