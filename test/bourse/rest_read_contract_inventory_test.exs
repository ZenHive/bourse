defmodule Bourse.RestReadContractInventoryTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.RestReadContracts
  alias Bourse.Test.RestReadContractScenario

  @expected_case_counts %{
    "alpaca" => 16,
    "binance" => 26,
    "binancecoinm" => 32,
    "binanceusdm" => 61,
    "bybit" => 78,
    "coinbaseexchange" => 3,
    "deribit" => 41,
    "derive" => 24,
    "hyperliquid" => 29,
    "lighter" => 16,
    "okx" => 84
  }

  test "the execution inventory mirrors every supported REST-read branch" do
    assert :ok = RestReadContracts.validate!()

    actual_counts =
      Map.new(RestReadContracts.venues(), fn venue ->
        {venue, length(RestReadContracts.cases_for(venue))}
      end)

    assert actual_counts == @expected_case_counts
    assert RestReadContracts.denominator() == 410
  end

  describe "option instrument selection" do
    defp option_contract(overrides) do
      Map.merge(
        %{
          "symbols" => %{"spot" => "BTC/USDT"},
          "operations" => [
            %{
              "method" => "fetchTrades",
              "arguments" => [%{"name" => "symbol", "strategy" => "market_symbol"}],
              "branches" => [
                %{
                  "provider_operation" => "publicGetPublicOptionTrades",
                  "market_kind" => "option",
                  "option_instrument" => "traded",
                  "options" => []
                }
              ]
            }
          ],
          "option_selection" => %{
            "source_method" => "fetchOptionChain",
            "options" => [%{"name" => "instType", "strategy" => "literal", "value" => "OPTION"}]
          }
        },
        overrides
      )
    end

    defp with_requirement(requirement) do
      [operation] = option_contract(%{})["operations"]
      [branch] = operation["branches"]

      branch =
        if requirement,
          do: Map.put(branch, "option_instrument", requirement),
          else: Map.delete(branch, "option_instrument")

      %{"operations" => [%{operation | "branches" => [branch]}]}
    end

    test "every venue contract leaves the option slot out and declares a requirement per option branch" do
      for venue <- RestReadContracts.venues() do
        contract = RestReadContracts.inventory()["venues"][venue]
        refute Map.has_key?(contract["symbols"], "option"), "#{venue} still names an option slot"
        assert :ok = RestReadContracts.validate_option_selection!(venue, contract)
      end
    end

    test "a non-option symbol in the option slot is rejected" do
      contract = option_contract(%{"symbols" => %{"spot" => "BTC/USDT", "option" => "BTC/USDT:USDT"}})

      assert_raise ArgumentError, ~r/symbols.option names "BTC\/USDT:USDT", which is not an option symbol/, fn ->
        RestReadContracts.validate_option_selection!("okx", contract)
      end
    end

    test "a literal option symbol in the option slot is rejected because it expires" do
      contract = option_contract(%{"symbols" => %{"option" => "BTC/USD:BTC-260925-100000-C"}})

      assert_raise ArgumentError, ~r/names the literal option .* option instruments expire/, fn ->
        RestReadContracts.validate_option_selection!("okx", contract)
      end
    end

    test "an option branch without a known requirement is rejected" do
      for requirement <- [nil, "liquid"] do
        contract = option_contract(with_requirement(requirement))

        assert_raise ArgumentError, ~r/must declare option_instrument as one of/, fn ->
          RestReadContracts.validate_option_selection!("okx", contract)
        end
      end
    end

    test "a traded or quoted requirement needs a live selection source" do
      contract = Map.delete(option_contract(%{}), "option_selection")

      assert_raise ArgumentError, ~r/must declare option_selection/, fn ->
        RestReadContracts.validate_option_selection!("okx", contract)
      end

      assert :ok =
               RestReadContracts.validate_option_selection!("derive", Map.merge(contract, with_requirement("listed")))
    end

    test "a venue with no listed option fails as market state before the branch is called" do
      contract_case = %{
        "id" => "okx:fetchTrades:2:publicGetPublicOptionTrades",
        "kind" => "success",
        "method" => "fetchTrades",
        "venue" => "okx",
        "market_kind" => "option",
        "option_instrument" => "traded",
        "arguments" => [%{"name" => "symbol", "strategy" => "market_symbol"}],
        "options" => []
      }

      context = %{exchange: nil, markets: [], venue: "okx", venue_contract: option_contract(%{})}

      assert_raise ExUnit.AssertionError, ~r/no listed option instrument on okx now .* the branch was not called/, fn ->
        RestReadContractScenario.assert_case!(contract_case, context)
      end
    end

    test "an empty read for an instrument the venue reports as traded fails as a broken read" do
      contract_case = %{
        "id" => "okx:fetchTrades:2:publicGetPublicOptionTrades",
        "method" => "fetchTrades",
        "venue" => "okx",
        "selected_option" => %{
          symbol: "BTC/USD:BTC-270625-200000-P",
          requirement: "traded",
          source: "fetchOptionChain",
          evidence: "24h base volume 22906.84"
        },
        "success" => %{
          "representation" => "parsed",
          "collection" => "list",
          "module" => "Bourse.Trade",
          "required_fields" => ["symbol"],
          "any_fields" => []
        }
      }

      assert_raise ExUnit.AssertionError,
                   ~r/fetchOptionChain reported as traded \(24h base volume 22906.84\).*broken read, not market state/,
                   fn -> RestReadContractScenario.assert_live_value!(contract_case, []) end
    end

    @quoted_btc "BTC/USDT:USDT-270326-10000-P"
    @dead_btc "BTC/USDT:USDT-270924-10000-P"
    @expiring_btc "BTC/USDT:USDT-261126-60000-C"

    defp btc_listings do
      listed = MapSet.new([@quoted_btc, @dead_btc, @expiring_btc])
      {listed, MapSet.delete(listed, @expiring_btc)}
    end

    test "clearing only the qualifying rows' identities leaves absence unestablished" do
      {listed, eligible} = btc_listings()

      rows = [
        %Bourse.OptionData{symbol: nil, bid_price: 1890.0, ask_price: 1900.0},
        %Bourse.OptionData{symbol: @dead_btc, bid_price: 0.0, ask_price: 0.0},
        %Bourse.OptionData{symbol: @quoted_btc, bid_price: 0.0, ask_price: 5.0}
      ]

      assert {:unresolved, 1} = RestReadContractScenario.option_group_verdict(rows, listed, eligible, "quoted")
    end

    test "an identified qualifying row is selected beside many unreconciled rows" do
      {listed, eligible} = btc_listings()
      noise = for _ <- 1..50, do: %Bourse.OptionData{symbol: "DOGE-25DEC26-0.045-P-USDT", base_volume: 9.0e6}
      qualifying = %Bourse.OptionData{symbol: @quoted_btc, base_volume: 1.0}

      assert {:selected, ^qualifying} =
               RestReadContractScenario.option_group_verdict([qualifying | noise], listed, eligible, "traded")
    end

    test "the highest-volume candidate wins and a listing excluded by the cutoff is irrelevant" do
      {listed, eligible} = btc_listings()

      rows = [
        %Bourse.OptionData{symbol: @dead_btc, base_volume: 2.0},
        %Bourse.OptionData{symbol: @quoted_btc, base_volume: 22_906.84},
        %Bourse.OptionData{symbol: @expiring_btc, base_volume: 99_999.0}
      ]

      assert {:selected, %Bourse.OptionData{symbol: @quoted_btc}} =
               RestReadContractScenario.option_group_verdict(rows, listed, eligible, "traded")

      assert {:absent, 1} =
               RestReadContractScenario.option_group_verdict(Enum.take(rows, -1), listed, eligible, "traded")
    end

    test "rows that are all identified and none qualifying establish absence" do
      {listed, eligible} = btc_listings()

      rows = [
        %Bourse.OptionData{symbol: @dead_btc, bid_price: 0.0, ask_price: 0.0},
        %Bourse.OptionData{symbol: nil, bid_price: nil, ask_price: 2.0}
      ]

      assert {:absent, 2} = RestReadContractScenario.option_group_verdict(rows, listed, eligible, "quoted")
    end

    test "an empty successful response leaves absence unestablished" do
      {listed, eligible} = btc_listings()
      assert :no_rows = RestReadContractScenario.option_group_verdict([], listed, eligible, "quoted")
    end

    test "absence is market state only when every underlying answered identified rows without a candidate" do
      cutoff = 1_795_660_000_000
      id = "bybit:fetchOption:0:publicGetV5MarketTickers"

      state =
        RestReadContractScenario.option_absence_message(
          id,
          "bybit",
          "quoted",
          "fetchOptionChain",
          [
            {"BTC", {:absent, 824}},
            {"ETH", {:absent, 618}}
          ],
          cutoff
        )

      assert state =~ "no quoted option instrument on bybit now"
      assert state =~ "BTC: 824 rows, none quoted; ETH: 618 rows, none quoted"
      assert state =~ "options expiring before 2026-11-26T"
      assert state =~ "current market state"

      unverified =
        RestReadContractScenario.option_absence_message(
          id,
          "okx",
          "quoted",
          "fetchOptionChain",
          [
            {"BTC", {:unresolved, 8}},
            {"ETH", :no_rows},
            {"HYPE", {:source_error, "[okx] invalid_parameters: unsupported OKX option underlying"}},
            {"LTC", {:absent, 62}}
          ],
          cutoff
        )

      assert unverified =~ "absence of a quoted option instrument on okx not established"
      assert unverified =~ "BTC: 8 quoted rows of unknown identity"
      assert unverified =~ "ETH: source returned no rows; market state unverified"
      assert unverified =~ "HYPE: source error [okx] invalid_parameters"
      assert unverified =~ "Market state unverified: the branch was not called"
      refute unverified =~ "current market state"
      refute unverified =~ "broken"
    end

    test "option symbols are recognised by their expiry, strike and right" do
      assert RestReadContracts.option_symbol?("BTC/USD:BTC-260925-100000-C")
      assert RestReadContracts.option_symbol?("ETH/USDC:USDC-250131-2500.5-P")
      refute RestReadContracts.option_symbol?("BTC/USDT:USDT")
      refute RestReadContracts.option_symbol?("GLD")
      refute RestReadContracts.option_symbol?(nil)
    end
  end

  test "scalar time contracts assert current milliseconds without a module" do
    now = System.system_time(:millisecond)

    contract_case = %{
      "id" => "binance:fetchTime:2:publicGetTime",
      "method" => "fetchTime",
      "venue" => "binance",
      "success" => %{
        "representation" => "parsed",
        "collection" => "scalar",
        "scalar" => "integer",
        "invariants" => [%{"operator" => "recent_ms", "tolerance_ms" => 300_000}]
      }
    }

    assert :ok = RestReadContractScenario.assert_live_value!(contract_case, now)
  end

  test "nested map contracts assert provider meaning keys without a module" do
    contract_case = %{
      "id" => "binance:fetchTradingLimits:3:publicGetExchangeInfo",
      "method" => "fetchTradingLimits",
      "venue" => "binance",
      "success" => %{
        "representation" => "nested_map",
        "provider_meaning_keys" => ["min", "max"]
      }
    }

    assert :ok =
             RestReadContractScenario.assert_live_value!(
               contract_case,
               %{"BTC/USDT" => %{"min" => 0.00001, "max" => 9000.0}}
             )
  end

  describe "field_values" do
    defp open_order_case(success_overrides) do
      %{
        "id" => "binanceusdm:fetchOpenOrder:1:fapiPrivateGetAlgoOrder",
        "method" => "fetchOpenOrder",
        "venue" => "binanceusdm",
        "success" =>
          Map.merge(
            %{
              "representation" => "parsed",
              "collection" => "single",
              "module" => "Bourse.Order",
              "required_fields" => ["id"],
              "any_fields" => ["symbol", "status", "type", "side"]
            },
            success_overrides
          )
      }
    end

    test "an absent declaration constrains nothing" do
      assert :ok = RestReadContracts.validate_field_values!(open_order_case(%{}))
    end

    test "a map from field names to allowed values is accepted" do
      assert :ok = RestReadContracts.validate_field_values!(open_order_case(%{"field_values" => %{"status" => ["open"]}}))
    end

    for {label, malformed} <- [
          false: false,
          null: nil,
          empty_list: [],
          non_map: "status",
          empty_map: %{},
          empty_allowed_list: %{"status" => []},
          non_list_allowed: %{"status" => "open"}
        ] do
      test "a #{label} declaration is rejected" do
        contract_case = open_order_case(%{"field_values" => unquote(Macro.escape(malformed))})

        assert_raise ArgumentError, ~r/field_values must map field names to non-empty lists/, fn ->
          RestReadContracts.validate_field_values!(contract_case)
        end
      end
    end

    test "a declared status rejects an order outside the allowed values" do
      contract_case = open_order_case(%{"field_values" => %{"status" => ["open"]}})
      canceled = %Bourse.Order{id: "1", symbol: "BTC/USDT:USDT", status: "canceled"}

      assert_raise ExUnit.AssertionError, ~r/status is "canceled", expected one of \["open"\]/, fn ->
        RestReadContractScenario.assert_live_value!(contract_case, canceled)
      end

      assert :ok = RestReadContractScenario.assert_live_value!(contract_case, %{canceled | status: "open"})
    end
  end

  test "nested map contracts keep a false provider boolean as meaning" do
    contract_case = %{
      "id" => "binancecoinm:fetchPositionMode:0:dapiPrivateGetPositionSideDual",
      "method" => "fetchPositionMode",
      "venue" => "binancecoinm",
      "success" => %{
        "representation" => "nested_map",
        "provider_meaning_keys" => ["dualSidePosition"]
      }
    }

    assert :ok =
             RestReadContractScenario.assert_live_value!(
               contract_case,
               %{"dualSidePosition" => false}
             )
  end
end
