defmodule Bourse.OptionProposal.HedgeTest do
  use ExUnit.Case, async: true

  alias Bourse.Market
  alias Bourse.OptionProposal.Hedge

  describe "calculate/5" do
    test "sizes a linear perp hedge to the target delta and reports residual after rounding" do
      candidate = candidate(market: linear_perp(step: 0.1, contract_size: 1.0))

      # current 0.23, target 0.0 => need -0.23; step 0.1 => nearest -0.2 residual -0.03
      assert {:ok, hedge} = Hedge.calculate(0.23, 0.0, [candidate], :same_only, ["deribit"])

      assert hedge.side == "sell"
      assert_in_delta hedge.quantity, 0.2, 1.0e-12
      assert_in_delta hedge.signed_quantity, -0.2, 1.0e-12
      assert_in_delta hedge.residual_delta, 0.03, 1.0e-12
      assert hedge.cross_venue? == false
    end

    test "returns a zero hedge when already at target" do
      candidate = candidate(market: linear_perp(step: 0.001, contract_size: 1.0))

      assert {:ok, hedge} = Hedge.calculate(0.0, 0.0, [candidate], :same_only, ["deribit"])
      assert hedge.quantity == 0.0
      assert hedge.residual_delta == 0.0
    end

    test "same_only rejects cross-venue candidates while prefer_same_venue chooses same first" do
      same = candidate(id: "same", venue: "deribit", market: linear_perp(step: 0.01, contract_size: 1.0))
      cross = candidate(id: "cross", venue: "okx", market: linear_perp(step: 0.01, contract_size: 1.0))

      assert {:error, :no_same_venue_hedge_candidate} =
               Hedge.calculate(0.5, 0.0, [cross], :same_only, ["deribit"])

      assert {:ok, preferred} =
               Hedge.calculate(0.5, 0.0, [cross, same], :prefer_same_venue, ["deribit"])

      assert preferred.candidate_id == "same"
      assert preferred.cross_venue? == false

      assert {:ok, allowed} =
               Hedge.calculate(0.5, 0.0, [cross, same], :cross_allowed, ["deribit"])

      # cross_allowed preserves caller order — first candidate wins
      assert allowed.candidate_id == "cross"
      assert allowed.cross_venue? == true
    end

    test "spot hedge uses unit delta and contract multipliers scale linear perps" do
      spot = candidate(id: "spot", market: spot_market(step: 0.001))
      assert {:ok, hedge} = Hedge.calculate(0.015, 0.0, [spot], :same_only, ["deribit"])
      assert_in_delta hedge.quantity, 0.015, 1.0e-12
      assert hedge.side == "sell"

      micro = candidate(id: "micro", market: linear_perp(step: 1, contract_size: 0.01))
      # need -0.025 delta / 0.01 = -2.5 contracts => nearest -2 or -3
      assert {:ok, sized} = Hedge.calculate(0.025, 0.0, [micro], :same_only, ["deribit"])
      assert sized.quantity in [2.0, 3.0]
      assert abs(sized.residual_delta) <= 0.01
    end

    test "inactive hedge markets fail explicitly" do
      candidate = candidate(market: %{linear_perp(step: 0.1, contract_size: 1.0) | active: false})
      assert {:error, :inactive_market} = Hedge.calculate(1.0, 0.0, [candidate], :same_only, ["deribit"])
    end

    test "sizes inverse perps from contract value and the caller-supplied market price" do
      inverse = candidate(market: inverse_perp(step: 1, contract_size: 100.0, price: 20_000.0))

      assert {:ok, hedge} = Hedge.calculate(0.012, 0.0, [inverse], :same_only, ["deribit"])
      assert hedge.quantity == 2.0
      assert hedge.delta_per_unit == 0.005
      assert_in_delta hedge.residual_delta, 0.002, 1.0e-12
    end

    test "prefers candidate price and quote over inverse market info" do
      no_market_price = %{inverse_perp(step: 1, contract_size: 100.0, price: 10_000.0) | info: %{"kind" => "future"}}

      priced =
        candidate(
          market: no_market_price,
          price: 20_000.0,
          quote: %{last: 25_000.0}
        )

      assert {:ok, priced_hedge} = Hedge.calculate(0.012, 0.0, [priced], :same_only, ["deribit"])
      assert priced_hedge.delta_per_unit == 0.005
      assert priced_hedge.quantity == 2.0

      quoted = candidate(market: no_market_price, quote: %{"last" => 25_000.0})

      assert {:ok, quoted_hedge} = Hedge.calculate(0.009, 0.0, [quoted], :same_only, ["deribit"])
      assert quoted_hedge.delta_per_unit == 0.004
      assert quoted_hedge.quantity == 2.0
    end

    test "interprets decimal-place precision and fails when precision is unavailable" do
      decimal_market = %{spot_market(step: 3) | precision_mode: "decimal_places"}
      decimal = candidate(market: decimal_market)

      assert {:ok, hedge} = Hedge.calculate(0.0014, 0.0, [decimal], :same_only, ["deribit"])
      assert hedge.amount_step == 0.001
      assert hedge.quantity == 0.001

      missing = candidate(market: %{spot_market(step: 0.001) | precision: nil})
      assert {:error, :missing_amount_precision} = Hedge.calculate(0.1, 0.0, [missing], :same_only, ["deribit"])
    end

    test "rejects invalid candidates, option hedges, and missing contract multipliers" do
      assert {:error, {:invalid_hedge_candidate, %{}}} =
               Hedge.calculate(0.1, 0.0, [%{}], :cross_allowed, ["deribit"])

      option = candidate(market: %{linear_perp(step: 1, contract_size: 1.0) | option: true})
      assert {:error, :hedge_candidate_is_option} = Hedge.calculate(0.1, 0.0, [option], :same_only, ["deribit"])

      missing_multiplier = candidate(market: %{linear_perp(step: 1, contract_size: 1.0) | contract_size: nil})

      assert {:error, :missing_contract_multiplier} =
               Hedge.calculate(0.1, 0.0, [missing_multiplier], :same_only, ["deribit"])
    end

    test "returns stable errors for empty candidates and invalid policies" do
      assert {:error, :no_hedge_candidate} = Hedge.calculate(0.1, 0.0, [], :cross_allowed, ["deribit"])

      assert {:error, {:invalid_venue_policy, :unknown}} =
               Hedge.calculate(0.1, 0.0, [candidate()], :unknown, ["deribit"])
    end

    test "requires a candidate market and an inverse valuation price" do
      assert {:error, :missing_hedge_market} =
               Hedge.calculate(0.1, 0.0, [Map.delete(candidate(), :market)], :same_only, ["deribit"])

      no_price = candidate(market: %{inverse_perp(step: 1, contract_size: 100.0, price: 20_000.0) | info: nil})

      assert {:error, :inverse_hedge_requires_price} =
               Hedge.calculate(0.1, 0.0, [no_price], :same_only, ["deribit"])
    end

    test "derives candidate kinds from market flags and types" do
      type_swap = candidate(kind: nil, market: %{linear_perp(step: 0.1, contract_size: 1.0) | swap: nil})
      assert {:ok, %{kind: :perp}} = Hedge.calculate(0.1, 0.0, [type_swap], :same_only, ["deribit"])

      type_spot = candidate(kind: nil, market: %{spot_market(step: 0.1) | spot: nil})
      assert {:ok, %{kind: :spot}} = Hedge.calculate(0.1, 0.0, [type_spot], :same_only, ["deribit"])

      generic_market = %Market{
        symbol: "BTC/USD",
        type: "index",
        active: true,
        contract_size: 1.0,
        precision: %{"amount" => 0.1}
      }

      generic = candidate(kind: nil, market: generic_market)
      assert {:ok, %{kind: :perp}} = Hedge.calculate(0.1, 0.0, [generic], :same_only, ["deribit"])
    end

    test "rejects malformed amount precision" do
      malformed = candidate(market: %{spot_market(step: 0.1) | precision: %{"amount" => nil}})

      assert {:error, :missing_amount_precision} =
               Hedge.calculate(0.1, 0.0, [malformed], :same_only, ["deribit"])
    end
  end

  defp candidate(overrides \\ []) do
    market = Keyword.get(overrides, :market, linear_perp(step: 0.01, contract_size: 1.0))

    %{
      id: Keyword.get(overrides, :id, "hedge-1"),
      venue: Keyword.get(overrides, :venue, "deribit"),
      account: Keyword.get(overrides, :account, "main"),
      symbol: market.symbol,
      market: market,
      kind: Keyword.get(overrides, :kind),
      price: Keyword.get(overrides, :price),
      quote: Keyword.get(overrides, :quote)
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

  defp spot_market(step: step) do
    %Market{
      id: "BTCUSDT",
      symbol: "BTC/USDT",
      base: "BTC",
      quote: "USDT",
      type: "spot",
      spot: true,
      active: true,
      precision: %{"amount" => step, "price" => 0.1},
      limits: %{"amount" => %{"min" => step}}
    }
  end

  defp inverse_perp(step: step, contract_size: size, price: price) do
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
      info: %{"mark_price" => price}
    }
  end
end
