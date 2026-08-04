defmodule Bourse.PortfolioRisk.ExposureTest do
  use ExUnit.Case, async: true

  alias Bourse.Balance
  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.Order
  alias Bourse.PortfolioRisk.Exposure
  alias Bourse.Position

  @observed_at 1_800_000_000_000
  @provenance %{venue: "deribit", account: "main", observed_at: @observed_at}

  describe "signed quantities" do
    test "balances preserve assets and express debt as negative delta" do
      balance = %Balance{
        total: %{"BTC" => 2.0, "USDT" => 0},
        debt: %{"BTC" => 0.25, "ETH" => 1.0},
        timestamp: @observed_at - 1
      }

      lots = Exposure.balance_lots(@provenance, balance)
      contributions = Enum.map(lots, &Exposure.delta_contribution/1)

      assert Enum.map(contributions, &{&1.source, &1.underlying, &1.greeks.delta.value}) == [
               {:balance, "BTC", 2.0},
               {:debt, "BTC", -0.25},
               {:debt, "ETH", -1.0}
             ]

      assert Enum.all?(contributions, &(&1.source_timestamp == @observed_at - 1))
    end

    test "option positions apply contract multipliers and long/short signs" do
      market = option_market(native_quantity_unit: "contracts", contract_size: 0.01)

      assert {:ok, long} =
               Exposure.position_lot(@provenance, %Position{symbol: market.symbol, side: "long", contracts: 3}, market)

      assert long.quantity == 0.03
      assert long.contract_multiplier == 0.01

      assert {:ok, short} =
               Exposure.position_lot(@provenance, %Position{symbol: market.symbol, side: "short", contracts: 3}, market)

      assert short.quantity == -0.03

      base_market = %{market | native_quantity_unit: "base", contract_size: 0.01}

      assert {:ok, base_lot} =
               Exposure.position_lot(
                 @provenance,
                 %Position{symbol: market.symbol, side: "long", contracts: 0.03},
                 base_market
               )

      assert base_lot.quantity == 0.03
      assert base_lot.contract_multiplier == 1
    end

    test "position errors and linear/inverse quantities fail loudly" do
      option = option_market()

      assert {:error, :missing_position_side} =
               Exposure.position_lot(@provenance, %Position{symbol: option.symbol, contracts: 1}, option)

      assert {:error, :missing_contract_multiplier} =
               Exposure.position_lot(
                 @provenance,
                 %Position{symbol: option.symbol, side: "long", contracts: 1},
                 %{option | contract_size: nil}
               )

      assert {:error, :missing_option_quantity_semantics} =
               Exposure.position_lot(
                 @provenance,
                 %Position{symbol: option.symbol, side: "long", contracts: 1},
                 %{option | native_quantity_unit: nil}
               )

      linear = derivative_market(contract_size: 0.001)

      assert {:ok, linear_lot} =
               Exposure.position_lot(
                 @provenance,
                 %Position{symbol: linear.symbol, side: "long", contracts: 20},
                 linear
               )

      assert linear_lot.quantity == 0.02

      inverse = %{linear | inverse: true, linear: false, contract_size: 10}

      assert {:ok, inverse_lot} =
               Exposure.position_lot(
                 @provenance,
                 %Position{symbol: inverse.symbol, side: "short", notional: 1_000, mark_price: 50_000},
                 inverse
               )

      assert inverse_lot.quantity == -0.02

      assert {:error, :missing_mark_price_for_inverse_contract} =
               Exposure.position_lot(
                 @provenance,
                 %Position{symbol: inverse.symbol, side: "long", contracts: 10},
                 inverse
               )

      assert {:error, :missing_position_quantity} =
               Exposure.position_lot(
                 @provenance,
                 %Position{symbol: linear.symbol, side: "long"},
                 %{linear | contract_size: nil}
               )
    end

    test "pending option quantity is already canonical base exposure and is not multiplied twice" do
      market = option_market(contract_size: 0.01)
      buy = %Order{symbol: market.symbol, side: "buy", amount: 0.03, filled: 0.01, remaining: 0.02}
      sell = %{buy | side: "sell"}

      assert {:ok, [buy_lot]} = Exposure.order_lots(@provenance, buy, market)
      assert {:ok, [sell_lot]} = Exposure.order_lots(@provenance, sell, market)

      assert buy_lot.quantity == 0.02
      assert sell_lot.quantity == -0.02
      assert buy_lot.pending
      assert buy_lot.contract_multiplier == 0.01
    end

    test "spot orders include both pending asset and cash legs" do
      market = %Market{
        symbol: "BTC/USDT",
        base: "BTC",
        quote: "USDT",
        spot: true,
        contract: false
      }

      order = %Order{symbol: market.symbol, side: "buy", amount: 2, filled: 0.5, price: 50_000}
      assert {:ok, [base, quote]} = Exposure.order_lots(@provenance, order, market)
      assert {base.underlying, base.quantity} == {"BTC", 1.5}
      assert {quote.underlying, quote.quantity} == {"USDT", -75_000.0}

      assert {:error, :missing_order_price} =
               Exposure.order_lots(@provenance, %{order | price: nil}, market)
    end

    test "derivative order quantities cover linear, inverse, zero, and invalid inputs" do
      linear = derivative_market(contract_size: 0.001)
      order = %Order{symbol: linear.symbol, side: "sell", remaining: 20}

      assert {:ok, [linear_lot]} = Exposure.order_lots(@provenance, order, linear)
      assert linear_lot.quantity == -0.02

      inverse = %{linear | inverse: true, linear: false, contract_size: 10}
      assert {:ok, [inverse_lot]} = Exposure.order_lots(@provenance, %{order | price: 50_000}, inverse)
      assert inverse_lot.quantity == -0.004

      assert {:ok, []} = Exposure.order_lots(@provenance, %{order | remaining: 0}, linear)

      assert {:error, :missing_inverse_order_price_or_multiplier} =
               Exposure.order_lots(@provenance, %{order | price: nil}, inverse)

      assert {:error, :missing_contract_multiplier} =
               Exposure.order_lots(@provenance, order, %{linear | contract_size: nil})

      assert {:error, :missing_order_side} =
               Exposure.order_lots(@provenance, %{order | side: nil}, linear)

      assert {:error, :missing_remaining_quantity} =
               Exposure.order_lots(@provenance, %{order | remaining: nil, amount: nil, filled: nil}, linear)

      assert {:error, :missing_option_quantity_semantics} =
               Exposure.order_lots(
                 @provenance,
                 %Order{symbol: option_market().symbol, side: "buy", remaining: 1},
                 %{option_market() | quantity_unit: nil}
               )
    end
  end

  describe "Greek contributions and compatible aggregation" do
    test "long and short options sign all five Greeks" do
      market = option_market()
      greeks = instrument_greeks(market)

      {:ok, long} =
        Exposure.position_lot(@provenance, %Position{symbol: market.symbol, side: "long", contracts: 3}, market)

      {:ok, short} =
        Exposure.position_lot(@provenance, %Position{symbol: market.symbol, side: "short", contracts: 3}, market)

      assert {long_contribution, []} = Exposure.option_contribution(long, greeks)
      assert {short_contribution, []} = Exposure.option_contribution(short, greeks)

      assert long_contribution.greeks.delta.value == 0.015
      assert long_contribution.greeks.gamma.value == 0.0003
      assert long_contribution.greeks.vega.value == 0.006
      assert long_contribution.greeks.theta.value == -0.009
      assert long_contribution.greeks.rho.value == 0.003

      for greek <- [:delta, :gamma, :vega, :theta, :rho] do
        assert_in_delta(
          Map.fetch!(short_contribution.greeks, greek).value,
          -Map.fetch!(long_contribution.greeks, greek).value,
          1.0e-12
        )
      end

      assert long_contribution.greeks.delta.native_field == "greeks.delta"
      assert long_contribution.source_timestamp == @observed_at - 2
    end

    test "BTC and ETH, settlement currencies, and mismatched units remain separate" do
      btc = Exposure.delta_contribution(currency_lot("BTC", "BTC", 1))
      eth = Exposure.delta_contribution(currency_lot("ETH", "ETH", 2))
      btc_usdt = Exposure.delta_contribution(currency_lot("BTC", "USDT", 3))

      mismatched =
        update_in(btc, [:greeks, :delta, :unit_convention, :unit], fn _unit ->
          "contracts"
        end)

      aggregates = Exposure.aggregate([btc, eth, btc_usdt, mismatched], [])

      assert length(aggregates) == 4
      assert Enum.all?(aggregates, &(&1.status == :complete))

      assert aggregates
             |> Enum.map(&{&1.bucket.underlying, &1.bucket.settlement_currency, &1.bucket.unit_convention.unit})
             |> Enum.sort() ==
               [
                 {"BTC", "BTC", "contracts"},
                 {"BTC", "BTC", "ratio"},
                 {"BTC", "USDT", "ratio"},
                 {"ETH", "ETH", "ratio"}
               ]
    end

    test "one missing Greek blocks only its exact bucket" do
      market = option_market()

      {:ok, first_lot} =
        Exposure.position_lot(@provenance, %Position{symbol: market.symbol, side: "long", contracts: 3}, market)

      {:ok, second_lot} =
        Exposure.position_lot(@provenance, %Position{symbol: market.symbol, side: "long", contracts: 2}, market)

      {complete, []} = Exposure.option_contribution(first_lot, instrument_greeks(market))
      {partial, [rho_blocker]} = Exposure.option_contribution(second_lot, %{instrument_greeks(market) | rho: nil})

      aggregates = Exposure.aggregate([complete, partial], [rho_blocker])
      rho = Enum.find(aggregates, &(&1.bucket.greek == :rho))
      delta = Enum.find(aggregates, &(&1.bucket.greek == :delta))

      assert rho.status == :blocked
      assert rho.value == nil
      assert_in_delta rho.partial_value, 0.003, 1.0e-12
      assert rho.blocked_count == 1

      assert delta.status == :complete
      assert_in_delta delta.value, 0.025, 1.0e-12
    end

    test "a failed or stale Greek read blocks supported buckets and preserves unsupported declarations" do
      market = option_market()

      {:ok, lot} =
        Exposure.position_lot(@provenance, %Position{symbol: market.symbol, side: "long", contracts: 3}, market)

      conventions = put_in(conventions(), ["rho"], %{"supported" => false})
      blockers = Exposure.block_option(lot, conventions, :stale)

      assert Enum.map(blockers, & &1.bucket.greek) == [:delta, :gamma, :vega, :theta]
      assert Enum.all?(blockers, &(&1.reason == :stale))

      aggregates = Exposure.aggregate([], blockers)
      assert Enum.all?(aggregates, &(&1.status == :blocked and is_nil(&1.partial_value)))
      assert Enum.all?(aggregates, &(&1.contribution_count == 0))
    end

    test "all unsupported Greeks produce no contribution or blockers" do
      market = option_market()

      {:ok, lot} =
        Exposure.position_lot(@provenance, %Position{symbol: market.symbol, side: "long", contracts: 1}, market)

      unsupported = Map.new(conventions(), fn {name, _entry} -> {name, %{"supported" => false}} end)
      greeks = %{instrument_greeks(market) | conventions: unsupported}

      assert {nil, []} = Exposure.option_contribution(lot, greeks)
      assert [] = Exposure.block_option(lot, unsupported, :unavailable)
      assert [] = Exposure.aggregate([], [])
    end
  end

  defp option_market(overrides \\ []) do
    struct!(
      Market,
      Keyword.merge(
        [
          id: "BTC-31JAN26-100000-C",
          symbol: "BTC/USD:BTC-260131-100000-C",
          base: "BTC",
          quote: "USD",
          settle: "BTC",
          type: "option",
          option: true,
          contract: true,
          quantity_unit: "base",
          native_quantity_unit: "contracts",
          contract_size: 0.01
        ],
        overrides
      )
    )
  end

  defp derivative_market(overrides) do
    struct!(
      Market,
      Keyword.merge(
        [
          id: "BTCUSDT",
          symbol: "BTC/USDT:USDT",
          base: "BTC",
          quote: "USDT",
          settle: "USDT",
          type: "swap",
          swap: true,
          contract: true,
          linear: true
        ],
        overrides
      )
    )
  end

  defp instrument_greeks(market) do
    %InstrumentGreeks{
      venue: "deribit",
      symbol: market.symbol,
      id: market.id,
      settle: market.settle,
      delta: 0.5,
      gamma: 0.01,
      vega: 0.2,
      theta: -0.3,
      rho: 0.1,
      conventions: conventions(),
      source_timestamp: @observed_at - 2,
      observed_at: @observed_at
    }
  end

  defp conventions do
    %{
      "delta" => convention("greeks.delta", "underlying", "ratio", 1.0, nil),
      "gamma" => convention("greeks.gamma", "delta", "delta_per_underlying_unit", 1.0, nil),
      "vega" => convention("greeks.vega", "option_premium", "premium_per_vol_point", 0.01, nil),
      "theta" => convention("greeks.theta", "option_premium", "premium_per_day", 1.0, "calendar_day"),
      "rho" => convention("greeks.rho", "option_premium", "premium_per_interest_point", 0.01, nil)
    }
  end

  defp convention(native_field, denomination, unit, bump_size, time_basis) do
    %{
      "supported" => true,
      "native_field" => native_field,
      "denomination" => denomination,
      "unit" => unit,
      "bump_size" => bump_size,
      "time_basis" => time_basis
    }
  end

  defp currency_lot(underlying, settlement_currency, quantity) do
    %{
      venue: "venue",
      account: "account",
      symbol: underlying,
      underlying: underlying,
      settlement_currency: settlement_currency,
      quantity: quantity,
      quantity_unit: "underlying",
      source: :balance,
      pending: false,
      source_timestamp: @observed_at,
      observed_at: @observed_at,
      contract_multiplier: nil,
      market: nil
    }
  end
end
