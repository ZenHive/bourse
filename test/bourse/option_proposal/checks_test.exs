defmodule Bourse.OptionProposal.ChecksTest do
  use ExUnit.Case, async: true

  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.OptionProposal.Checks
  alias Bourse.PortfolioRisk.Snapshot

  @observed_at 1_800_000_000_000
  @max_age_ms 1_000

  test "reports malformed freshness inputs and portfolio read failures" do
    ctx =
      base_ctx()
      |> put_in([:legs, Access.at(0), :quote], :invalid)
      |> update_in([:legs, Access.at(0), :greeks], &%{&1 | source_timestamp: nil})
      |> Map.put(:portfolio, %{status: :error, snapshot: nil, failures: [:down]})
      |> put_in([:proposal, :risk_targets], :invalid)

    {checks, violations, failures} = Checks.run(ctx)

    assert check(checks, :quote) == %{
             name: :quote,
             status: :violation,
             detail: %{code: :stale_or_missing_quote, leg_ids: ["leg"]}
           }

    assert check(checks, :greeks).detail.code == :stale_or_missing_greeks
    assert check(checks, :portfolio).detail.code == :portfolio_read_failed
    assert check(checks, :account_capacity).status == :violation
    assert check(checks, :hedge).detail == :not_requested
    assert Enum.any?(violations, &(&1.message == "portfolio read failed"))

    assert [
             :down,
             %{component: :account_capacity, reason: :unknown_account_capacity}
           ] = failures
  end

  test "accepts unchanged positions and sufficient atom-key capacity" do
    position = %{symbol: "BTC/USD", side: "long"}
    snapshot = snapshot(%{BTC: 1.0}, [position])

    ctx =
      base_ctx()
      |> Map.put(:portfolio, %{status: :complete, snapshot: snapshot, failures: []})
      |> put_in([:proposal, :expected_positions], [
        %{"venue" => "deribit", "account" => "main", "symbol" => "BTC/USD", "side" => "long"}
      ])
      |> put_in([:proposal, :hard_limits], %{required_capacity: %{"BTC" => 0.5}})
      |> put_in([:proposal, :risk_targets], %{delta: 0.0})

    {checks, _violations, _failures} = Checks.run(ctx)

    assert check(checks, :portfolio).detail == :unchanged
    assert check(checks, :account_capacity).detail == :sufficient
    assert check(checks, :hedge).detail == %{code: :hedge_infeasible, reason: :no_candidates}
  end

  test "supports every hard-limit shape and string residual limits" do
    ctx =
      base_ctx()
      |> put_in([:proposal, :risk_targets], %{delta: 0.0})
      |> put_in([:proposal, :hard_limits], %{
        "gamma" => %{"min" => -0.1, "max" => 0.1},
        "vega" => %{"max_abs" => 0.1},
        "residual_delta_abs" => 0.1,
        delta: %{min: -0.1, max: 0.1},
        theta: 0.1
      })
      |> Map.put(:post_after, %{delta: 1.0, gamma: 1.0, vega: 1.0, theta: 1.0})
      |> Map.put(:projected, %{notional: nil})
      |> Map.put(:hedge, %{
        feasible?: true,
        quantity: 1.0,
        residual_delta: 0.2,
        candidate_id: "hedge",
        market: nil,
        venue: nil
      })

    {checks, _violations, _failures} = Checks.run(ctx)

    assert %{detail: %{code: :post_trade_limit_violation, breaches: breaches}} = check(checks, :hard_limits)
    assert MapSet.new(breaches, & &1.greek) == MapSet.new([:delta, :gamma, :vega, :theta, :residual_delta])
    assert check(checks, :hedge).detail.code == :residual_delta_exceeds_limit
  end

  test "fails capacity requirements by domain and input shape" do
    second_leg = %{leg() | id: "second", venue: "okx", account: "demo"}
    two_domain_snapshot = snapshot(%{"BTC" => 1.0}, [], [domain("okx", "demo", %{"USDT" => 1_000.0})])

    ambiguous =
      base_ctx()
      |> Map.put(:legs, [leg(), second_leg])
      |> Map.put(:portfolio, %{status: :complete, snapshot: two_domain_snapshot, failures: []})
      |> put_in([:proposal, :hard_limits], %{required_capacity: %{"BTC" => 0.5}})

    {checks, violations, _failures} = Checks.run(ambiguous)
    assert check(checks, :account_capacity).detail.code == :ambiguous_cross_venue_capacity_limit
    assert Enum.any?(violations, &(&1.message == "cross-venue capacity requirements must name each venue and account"))

    invalid_row = put_in(base_ctx(), [:proposal, :hard_limits], %{required_capacity: [:invalid]})
    {checks, violations, _failures} = Checks.run(invalid_row)
    assert check(checks, :account_capacity).detail.code == :invalid_capacity_requirement
    assert Enum.any?(violations, &(&1.message == "invalid_capacity_requirement"))

    invalid_amount =
      put_in(base_ctx(), [:proposal, :hard_limits], %{
        required_capacity: [%{venue: "deribit", account: "main", currency: "BTC", amount: :invalid}]
      })

    {checks, _violations, _failures} = Checks.run(invalid_amount)
    assert check(checks, :account_capacity).detail.code == :invalid_capacity_requirement

    unknown_currency =
      put_in(base_ctx(), [:proposal, :hard_limits], %{required_capacity: %{"TASK_505_UNKNOWN" => 0.5}})

    {checks, _violations, failures} = Checks.run(unknown_currency)
    assert check(checks, :account_capacity).detail.code == :unknown_account_capacity
    assert [%{component: :account_capacity, reason: :unknown_account_capacity}] = failures
  end

  test "fails closed for invalid timestamps and unreadable expected positions" do
    ctx =
      base_ctx()
      |> put_in([:legs, Access.at(0), :quote, :timestamp], "invalid")
      |> update_in([:legs, Access.at(0), :greeks], &%{&1 | source_timestamp: "invalid"})
      |> put_in([:proposal, :expected_positions], :invalid)
      |> update_in([:portfolio], &Map.delete(&1, :failures))

    {checks, violations, failures} = Checks.run(ctx)

    assert check(checks, :quote).detail.code == :stale_or_missing_quote
    assert check(checks, :greeks).detail.code == :stale_or_missing_greeks
    assert check(checks, :portfolio).detail.code == :positions_unreadable
    assert Enum.any?(violations, &(&1.code == :positions_unreadable))
    assert failures == []

    odd_hedge =
      base_ctx()
      |> put_in([:proposal, :risk_targets], %{delta: 0.0})
      |> Map.put(:hedge, %{
        feasible?: true,
        quantity: 0,
        residual_delta: :unknown,
        candidate_id: "hedge",
        market: nil,
        venue: nil
      })

    {checks, _violations, _failures} = Checks.run(odd_hedge)
    assert check(checks, :hedge).detail == %{candidate_id: "hedge", residual_delta: :unknown}
  end

  test "handles empty account scope, candidate-only hedges, and absent position components" do
    no_scope =
      base_ctx()
      |> Map.put(:legs, [])
      |> Map.put(:portfolio, %{status: :complete, snapshot: nil, failures: []})

    {checks, _violations, _failures} = Checks.run(no_scope)
    assert check(checks, :account_capacity).status == :unknown

    candidate_only =
      base_ctx()
      |> Map.put(:candidates, [
        %{
          id: "hedge",
          venue: "deribit",
          account: "main",
          symbol: "BTC/USD",
          market: market(),
          market_observed_at: @observed_at
        }
      ])
      |> put_in([:proposal, :risk_targets], %{delta: 0.0})

    {checks, _violations, _failures} = Checks.run(candidate_only)
    assert check(checks, :hedge).detail == %{code: :hedge_infeasible}

    no_positions =
      %{"BTC" => 1.0}
      |> snapshot()
      |> update_in([Access.key!(:domains), Access.at(0), :components], fn _components -> %{} end)

    unreadable =
      base_ctx()
      |> Map.put(:portfolio, %{status: :complete, snapshot: no_positions, failures: []})
      |> put_in([:proposal, :expected_positions], [])

    {checks, _violations, _failures} = Checks.run(unreadable)
    assert check(checks, :portfolio).detail == :unchanged
  end

  defp base_ctx do
    %{
      proposal: %{hard_limits: %{}, risk_targets: %{}},
      legs: [leg()],
      candidates: [],
      projected: %{notional: 0.0},
      hedge: nil,
      portfolio: %{status: :complete, snapshot: snapshot(%{"BTC" => 1.0}), failures: []},
      post_after: %{delta: 0.0, gamma: 0.0, vega: 0.0, theta: 0.0},
      observed_at: @observed_at,
      opts: [max_age_ms: @max_age_ms]
    }
  end

  defp leg do
    %{
      id: "leg",
      venue: "deribit",
      account: "main",
      symbol: "BTC/USD",
      side: "buy",
      amount: 1.0,
      price: 1.0,
      type: "limit",
      market: market(),
      market_observed_at: @observed_at,
      quote: %{bid: 1.0, ask: 1.1, timestamp: @observed_at},
      greeks: %InstrumentGreeks{
        delta: 0.5,
        gamma: 0.1,
        vega: 0.1,
        theta: -0.1,
        source_timestamp: @observed_at
      }
    }
  end

  defp market do
    %Market{
      id: "BTC/USD",
      symbol: "BTC/USD",
      active: true,
      spot: true,
      type: "spot",
      precision: %{"amount" => 1.0, "price" => 0.1},
      limits: %{}
    }
  end

  defp snapshot(capacity, positions \\ [], extra_domains \\ []) do
    %Snapshot{
      status: :complete,
      observed_at: @observed_at,
      domains: [domain("deribit", "main", capacity, positions) | extra_domains],
      contributions: [],
      aggregates: [],
      blocked_buckets: [],
      failures: []
    }
  end

  defp domain(venue, account, capacity, positions \\ []) do
    %{
      venue: venue,
      account: account,
      components: %{positions: %{status: :ok, data: positions}},
      available_capacity: {:ok, capacity}
    }
  end

  defp check(checks, name), do: Enum.find(checks, &(&1.name == name))
end
