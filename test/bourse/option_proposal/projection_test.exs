defmodule Bourse.OptionProposal.ProjectionTest do
  use ExUnit.Case, async: true

  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.OptionProposal.Projection

  describe "project_legs/2" do
    test "projects canonical base quantities without applying native contract multipliers twice" do
      long = leg(id: "long", side: "buy", amount: 0.03, market: contract_option(0.01))
      short = leg(id: "short", side: "sell", amount: 0.01, market: contract_option(0.01))

      assert {:ok, projected} = Projection.project_legs([long, short])

      assert projected.legs_total.delta == 0.03 * 0.5 + -0.01 * 0.5
      assert projected.legs_total.gamma == 0.03 * 0.02 + -0.01 * 0.02
      assert projected.legs_total.vega == 0.03 * 0.1 + -0.01 * 0.1
      assert projected.legs_total.theta == 0.03 * -0.05 + -0.01 * -0.05

      long_effect = Enum.find(projected.legs, &(&1.id == "long"))
      assert long_effect.signed_quantity == 0.03
      assert long_effect.contract_multiplier == 0.01
      assert long_effect.quantity_unit == "underlying"
      assert long_effect.greeks.delta == 0.015

      assert length(projected.margin_domains) == 1
      refute Enum.any?(projected.margin_domains, & &1.portfolio_margin_netting)
    end

    test "uses underlying value for notional and reports premium separately" do
      assert {:ok, projected} = Projection.project_legs([leg(amount: 0.1, price: 0.05)])

      assert projected.notional == 10_000.0
      assert_in_delta projected.premium, 0.005, 1.0e-12
      assert hd(projected.legs).notional == 10_000.0
      assert_in_delta hd(projected.legs).premium, 0.005, 1.0e-12
    end

    test "keeps margin domains separate across venues and never nets them" do
      a = leg(id: "a", venue: "deribit", account: "main", side: "buy", amount: 0.1)
      b = leg(id: "b", venue: "okx", account: "demo", side: "buy", amount: 0.2)

      assert {:ok, projected} = Projection.project_legs([a, b])

      assert Enum.map(projected.margin_domains, &{&1.venue, &1.account}) == [
               {"deribit", "main"},
               {"okx", "demo"}
             ]

      assert Enum.all?(projected.margin_domains, &(&1.portfolio_margin_netting == false))
    end

    test "rejects inactive markets and missing multipliers" do
      inactive = leg(market: %{option_market() | active: false})
      assert {:ok, _projection} = Projection.project_legs([inactive])

      missing = leg(market: %{contract_option(nil) | contract_size: nil, native_quantity_unit: "contracts"})
      assert {:error, :missing_contract_multiplier} = Projection.project_legs([missing])
    end

    test "rejects non-representable canonical quantities and incomplete Greek conventions" do
      non_representable = leg(amount: 0.015, market: contract_option(0.01))
      assert {:error, {:quantity_not_representable, %Bourse.Error{}}} = Projection.project_legs([non_representable])

      incomplete = leg(greeks: %{greeks() | conventions: %{"delta" => greek_convention("delta")}})
      assert {:error, {:invalid_greek_convention, :gamma}} = Projection.project_legs([incomplete])
    end

    test "rejects mixed underlyings and incompatible Greek units" do
      eth_market = %{option_market() | base: "ETH", symbol: "ETH/USD:ETH-260131-5000-C"}
      assert {:error, {:mixed_underlyings, ["BTC", "ETH"]}} = Projection.project_legs([leg(), leg(market: eth_market)])

      incompatible =
        update_in(greeks().conventions["vega"], &Map.put(&1, "bump_size", 1.0))

      assert {:error, {:incompatible_greek_convention, :vega}} =
               Projection.project_legs([leg(), leg(id: "other", greeks: incompatible)])
    end

    test "folds baseline portfolio contributions into post-trade exposure" do
      baseline = [
        %{
          underlying: "BTC",
          greeks: %{
            delta: %{value: 0.2, unit_convention: semantic_convention("delta")},
            gamma: %{value: 0.0, unit_convention: semantic_convention("gamma")},
            vega: %{value: 0.0, unit_convention: semantic_convention("vega")},
            theta: %{value: 0.0, unit_convention: semantic_convention("theta")}
          }
        }
      ]

      assert {:ok, projected} = Projection.project_legs([leg(side: "buy", amount: 0.1)], baseline)
      # 0.1 base * 0.5 delta + 0.2 baseline
      assert_in_delta projected.post_trade_before_hedge.delta, 0.25, 1.0e-12
    end

    test "rejects malformed legs, sides, amounts, and quantity semantics" do
      assert {:error, :invalid_leg} = Projection.project_legs([%{market: option_market()}])
      assert {:error, :invalid_side} = Projection.project_legs([leg(side: "hold")])
      assert {:error, :invalid_amount} = Projection.project_legs([leg(amount: 0)])

      missing_semantics = %{option_market() | quantity_unit: nil}
      assert {:error, :missing_option_quantity_semantics} = Projection.project_legs([leg(market: missing_semantics)])
      assert {:error, :missing_underlying} = Projection.project_legs([])
    end

    test "rejects missing and invalid Greek values and convention tables" do
      assert {:error, {:missing_greek, :gamma}} =
               Projection.project_legs([leg(greeks: %{greeks() | gamma: nil})])

      assert {:error, {:invalid_greek, :gamma}} =
               Projection.project_legs([leg(greeks: %{greeks() | gamma: "bad"})])

      assert {:error, {:invalid_greek_convention, :delta}} =
               Projection.project_legs([leg(greeks: %{greeks() | conventions: nil})])
    end

    test "requires an underlying valuation and can use confronted market info" do
      no_price = %{greeks() | underlying_price: nil}
      assert {:error, :missing_underlying_price} = Projection.project_legs([leg(greeks: no_price)])

      market = %{option_market() | info: %{"index_price" => 90_000.0}}
      assert {:ok, projected} = Projection.project_legs([leg(greeks: no_price, market: market, price: nil)])
      assert projected.notional == 9_000.0
      assert projected.premium == 0.0
      assert Projection.delta_convention().denomination == "underlying"
    end

    test "rejects incompatible and malformed baseline contribution units" do
      incompatible = [
        %{
          underlying: "BTC",
          greeks: %{
            delta: %{
              value: 0.2,
              unit_convention: %{semantic_convention("delta") | "bump_size" => 0.01}
            }
          }
        }
      ]

      assert {:error, {:incompatible_baseline_convention, :delta}} =
               Projection.project_legs([leg()], incompatible)

      malformed = [%{underlying: "BTC", greeks: %{delta: %{value: "bad"}}}]

      assert {:error, {:invalid_baseline_contribution, :delta}} =
               Projection.project_legs([leg()], malformed)
    end
  end

  defp leg(overrides \\ []) do
    market = Keyword.get(overrides, :market, option_market())

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
      greeks: Keyword.get(overrides, :greeks, greeks())
    }
  end

  defp option_market do
    %Market{
      id: "BTC-31JAN26-100000-C",
      symbol: "BTC/USD:BTC-260131-100000-C",
      base: "BTC",
      quote: "USD",
      settle: "BTC",
      type: "option",
      option: true,
      contract: true,
      active: true,
      quantity_unit: "base",
      native_quantity_unit: "base",
      native_amount_step: 0.01,
      contract_size: 1,
      precision: %{"amount" => 0.01, "price" => 0.0001},
      limits: %{"amount" => %{"min" => 0.01}}
    }
  end

  defp contract_option(size) do
    %{option_market() | native_quantity_unit: "contracts", native_amount_step: 1, contract_size: size}
  end

  defp greeks do
    %InstrumentGreeks{
      delta: 0.5,
      gamma: 0.02,
      vega: 0.1,
      theta: -0.05,
      underlying_price: 100_000.0,
      source_timestamp: 1_800_000_000_000,
      conventions: Map.new(~w(delta gamma vega theta), &{&1, greek_convention(&1)})
    }
  end

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
