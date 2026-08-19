defmodule Bourse.UnifiedReadContractTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.JsonDocument
  alias Bourse.RecordedResponseFixtures
  alias Bourse.ReplayExchange
  alias Bourse.Unified
  alias Bourse.Unified.Descriptor
  alias Bourse.Unified.ReadParse
  alias Bourse.Unified.RequestShape

  @runtime_manifest "priv/specs/json/runtime_support.json"
  @exclusions_path "test/fixtures/unified_read_parse_coverage_exclusions.json"
  @resolution_disposition_path "test/fixtures/unified_read_return_type_resolution.json"
  @unsupported_raw_audit_path "test/fixtures/unsupported_raw_endpoint_audit.json"
  @unified_source_path "lib/bourse/unified.ex"
  @read_parse_source_path "lib/bourse/unified/read_parse.ex"
  @external_resource @runtime_manifest
  @external_resource @exclusions_path
  @external_resource @resolution_disposition_path
  @external_resource @unsupported_raw_audit_path
  @external_resource @unified_source_path
  @external_resource @read_parse_source_path
  @venues @runtime_manifest |> File.read!() |> Jason.decode!() |> Map.fetch!("venues")
  @exclusions @exclusions_path |> File.read!() |> Jason.decode!()
  @resolution_disposition @resolution_disposition_path |> File.read!() |> Jason.decode!()
  @unsupported_raw_audit @unsupported_raw_audit_path |> File.read!() |> Jason.decode!()
  @recording_manifest_path "test/fixtures/responses/_manifest.json"
  @external_resource @recording_manifest_path
  @recording_manifest @recording_manifest_path |> File.read!() |> Jason.decode!()
  @bybit_category_required_reads ~w(
    fetchAllGreeks
    fetchCanceledAndClosedOrders
    fetchCanceledOrders
    fetchClosedOrder
    fetchClosedOrders
    fetchDerivativesMarketLeverageTiers
    fetchDerivativesOpenInterestHistory
    fetchFundingHistory
    fetchFundingRateHistory
    fetchFundingRates
    fetchFutureMarkets
    fetchGreeks
    fetchLeverage
    fetchLeverageTiers
    fetchLongShortRatioHistory
    fetchMarketLeverageTiers
    fetchMarkets
    fetchMyLiquidations
    fetchMyTrades
    fetchOHLCV
    fetchOpenInterest
    fetchOpenOrder
    fetchOpenOrders
    fetchOption
    fetchOptionChain
    fetchOptionMarkets
    fetchOrder
    fetchOrderBook
    fetchOrderClassic
    fetchOrderTrades
    fetchPosition
    fetchPositionADLRank
    fetchPositions
    fetchPositionsHistory
    fetchSpotMarkets
    fetchTicker
    fetchTickers
    fetchTradingFee
    fetchVolatilityHistory
  )

  # TODO(Task 538): remove each entry as the sibling task repairs the recorded
  # collection-shape violations. Exact enumeration keeps new regressions red.
  # fetch_last_prices is now typed as LastPrice[] (task 565); remaining gaps are
  # collection-shape only (list vs symbol-keyed map).
  @known_runtime_gaps [
    {"binance", :fetch_bids_asks, {:row_count_collapsed, 3_673, 1}, 538},
    {"binance", :fetch_bids_asks, :not_symbol_keyed, 538},
    {"binance", :fetch_last_prices, :not_symbol_keyed, 538},
    {"binanceusdm", :fetch_funding_intervals, {:row_count_collapsed, 616, 1}, 538},
    {"binanceusdm", :fetch_funding_intervals, :not_symbol_keyed, 538},
    {"binanceusdm", :fetch_last_prices, :not_symbol_keyed, 538}
  ]

  @market_context_rule_dispositions %{
    "binance/ohlcv/branches/0/field_map/volume#market.inverse" => :symbol_required,
    "binance/ticker/field_map/percentage/else#market.option" => :non_money_exemption,
    "binancecoinm/ohlcv/branches/0/field_map/volume#market.inverse" => :symbol_required,
    "binanceusdm/ohlcv/branches/0/field_map/volume#market.inverse" => :symbol_required,
    "bybit/ohlcv/branches/0/field_map/volume#market.inverse" => :symbol_required,
    "bybit/open_interest/field_map/openInterestAmount#market.inverse" => :symbol_required,
    "bybit/open_interest/field_map/openInterestValue#market.inverse" => :symbol_required,
    "bybit/ticker/field_map/vwap/else#market.inverse" =>
      {:payload_guard, %{"field" => "category", "in" => ["inverse", "option"]}},
    "deribit/open_interest/field_map/openInterestAmount#market.linear" => :symbol_required,
    "deribit/open_interest/field_map/openInterestValue#market.linear" => :symbol_required,
    "deribit/position/field_map/initialMarginPercentage/else#market.inverse" =>
      {:payload_guard, %{"equals" => true, "field" => "_bourse_inverse"}},
    "deribit/position/field_map/maintenanceMarginPercentage/else#market.inverse" =>
      {:payload_guard, %{"equals" => true, "field" => "_bourse_inverse"}},
    "deribit/trade/field_map/cost/else#market.inverse" =>
      {:payload_guard, %{"equals" => true, "field" => "_bourse_inverse"}},
    "okx/ohlcv/branches/0/field_map/volume#market.spot" => :symbol_required,
    "okx/open_interest/branches/1/field_map/baseVolume#market.option" => :symbol_required_branch,
    "okx/open_interest/branches/1/field_map/openInterestAmount#market.option" => :symbol_required_branch,
    "okx/open_interest/branches/1/field_map/openInterestValue#market.option" => :symbol_required_branch,
    "okx/open_interest/branches/1/field_map/quoteVolume#market.option" => :symbol_required_branch
  }

  describe "static parse coverage" do
    test "money-field market discriminators are payload-derived on symbol-less reads" do
      rules = Enum.flat_map(@venues, &market_context_rules/1)
      actual_names = rules |> Enum.map(& &1.name) |> Enum.sort()
      expected_names = @market_context_rule_dispositions |> Map.keys() |> Enum.sort()

      assert actual_names == expected_names,
             "authored market-context rule inventory changed; classify every added or removed rule explicitly"

      for %{name: name, path: path, venue: venue} <- rules,
          {:payload_guard, expected_guard} <- [Map.fetch!(@market_context_rule_dispositions, name)] do
        parent_rule =
          venue
          |> authored_spec!()
          |> get_in(["normalization", "field_maps" | Enum.drop(path, -1)])

        assert parent_rule["kind"] == "when", "#{name} lost its payload-gated outer branch"
        assert parent_rule["guard"] == expected_guard, "#{name} changed its payload discriminator"
      end

      symbol_less_parse_types = symbol_less_parse_types()

      violations =
        for %{name: name, parse_type: parse_type, venue: venue} <- rules,
            MapSet.member?(symbol_less_parse_types, {venue, parse_type}),
            disposition = Map.fetch!(@market_context_rule_dispositions, name),
            not symbol_less_safe_disposition?(disposition),
            do: {name, disposition}

      assert violations == [],
             "money-field rules reachable without required symbol still depend on request market context: " <>
               inspect(violations)
    end

    test "every provider-offered read with an incomplete mapping is explicitly tracked by task 550" do
      actual =
        Map.new(@venues, fn venue ->
          spec = authored_spec!(venue)
          {venue, parse_coverage_gaps(venue, spec)}
        end)

      assert Map.new(actual, fn {venue, entries} -> {venue, length(entries)} end) == %{
               "alpaca" => 0,
               "binance" => 13,
               "binancecoinm" => 3,
               "binanceusdm" => 16,
               "bybit" => 8,
               "coinbaseexchange" => 0,
               "deribit" => 3,
               "derive" => 0,
               "hyperliquid" => 2,
               "lighter" => 0,
               "okx" => 9
             }

      assert actual |> Map.values() |> List.flatten() |> length() == 54

      expected =
        Map.new(@exclusions, fn {venue, entries} ->
          assert Enum.all?(entries, &(&1["tracking_task"] == 550)),
                 "#{venue} has a parse-coverage exclusion not owned by task 550"

          assert Enum.all?(entries, &(is_binary(&1["failure"]) and &1["failure"] != "")),
                 "#{venue} has a parse-coverage exclusion without a failure kind"

          {venue, entries |> Enum.map(& &1["method"]) |> Enum.sort()}
        end)

      assert Map.new(actual, fn {venue, entries} -> {venue, entries |> Enum.map(& &1["method"]) |> Enum.sort()} end) ==
               expected

      for method <- ~w(fetchConvertTrade fetchConvertTradeHistory) do
        assert %{"failure" => "ambiguous_endpoint_selection"} =
                 Enum.find(@exclusions["binanceusdm"], &(&1["method"] == method))
      end
    end

    test "provider support, mapping completeness, and verification have independent owners" do
      for venue <- @venues do
        spec = authored_spec!(venue)
        support = get_in(spec, ["capabilities", "has"])
        mapping_complete = get_in(spec, ["capabilities", "mapping_complete"])
        verification = get_in(spec, ["capabilities", "verification"])
        unified = get_in(spec, ["endpoints", "unified"])
        js_to_atom = Map.new(Unified.method_defs(), fn {method, js_name, _, _} -> {js_name, method} end)

        assert Enum.sort(Map.keys(mapping_complete)) == Enum.sort(Map.keys(unified))
        assert Enum.sort(Map.keys(verification)) == Enum.sort(Map.keys(unified))
        refute Map.has_key?(spec["capabilities"], "support_reasons")
        refute Map.has_key?(spec["capabilities"], "reasons")

        for {method, false} <- support do
          assert is_boolean(support[method])

          assert Map.get(unified, method, []) == [],
                 "#{venue}.#{method} is provider-unsupported but retains a unified route"
        end

        for {method, false} <- mapping_complete,
            support[method] in [true, "emulated"],
            unified[method] != [] do
          method_atom = Map.fetch!(js_to_atom, method)

          assert Map.has_key?(Exchange.new!(venue).module.__unified_endpoints__(), method_atom),
                 "#{venue}.#{method} is offered with an incomplete mapping but is not callable"
        end

        mutated =
          put_in(
            spec,
            ["capabilities", "verification"],
            Map.new(verification, fn {method, _} -> {method, "unverified"} end)
          )

        assert Exchange.build_unified_method_mapping(
                 spec,
                 Exchange.build_endpoint_configs(spec["raw"]["describe"]["api"])
               ) ==
                 Exchange.build_unified_method_mapping(
                   mutated,
                   Exchange.build_endpoint_configs(mutated["raw"]["describe"]["api"])
                 )

        assert parse_coverage_gaps(venue, spec) == parse_coverage_gaps(venue, mutated)
      end
    end

    test "task-570 restored cells stay offered, incomplete, unverified, and callable" do
      restored = [
        {"binance", "fetchMyDustTrades", true},
        {"binance", "fetchIsolatedBorrowRates", true},
        {"binance", "fetchOptionPositions", true},
        {"binance", "fetchAccountPositions", true},
        {"binance", "fetchPositionsRisk", true},
        {"binance", "fetchMarginModes", true},
        {"binanceusdm", "fetchMyDustTrades", true},
        {"binanceusdm", "fetchIsolatedBorrowRates", true},
        {"binanceusdm", "fetchOptionPositions", true},
        {"binanceusdm", "fetchAccountPositions", true},
        {"binanceusdm", "fetchPositionsRisk", true},
        {"binancecoinm", "fetchFundingHistory", true},
        {"binancecoinm", "fetchMarginAdjustmentHistory", true},
        {"bybit", "fetchDerivativesOpenInterestHistory", true},
        {"deribit", "fetchLiquidations", "emulated"},
        {"okx", "fetchDeposit", true},
        {"okx", "fetchWithdrawal", true}
      ]

      assert length(restored) == 17

      for {venue, method, support} <- restored do
        spec = authored_spec!(venue)
        exchange = Exchange.new!(venue)

        assert get_in(spec, ["capabilities", "has", method]) == support
        assert get_in(spec, ["capabilities", "mapping_complete", method]) == false
        assert get_in(spec, ["capabilities", "verification", method]) == "unverified"
        assert Exchange.has?(exchange, method)
        refute Exchange.mapping_complete?(exchange, method)
        assert Exchange.verification_state(exchange, method) == :unverified
      end
    end

    test "bybit declared reads resolve every provider-required category before dispatch" do
      spec = authored_spec!("bybit")
      defaults = get_in(spec, ["endpoints", "request", "defaults"])
      support = get_in(spec, ["capabilities", "has"])
      exchange = Exchange.new!("bybit")

      category_contracts =
        for {method, %{"category" => contract}} <- defaults, into: %{}, do: {method, contract}

      assert map_size(category_contracts) == 67

      refute Enum.any?(category_contracts, fn {_method, contract} ->
               contract["kind"] == "unresolved" or contract["reason"] == "conditional_value"
             end)

      assert Enum.frequencies_by(category_contracts, fn {_method, contract} -> contract["kind"] end) == %{
               "computed" => 45,
               "literal" => 7,
               "omit" => 15
             }

      resolved_reads =
        category_contracts
        |> Enum.filter(fn {method, contract} -> String.starts_with?(method, "fetch") and contract["kind"] != "omit" end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert resolved_reads == Enum.sort(@bybit_category_required_reads)

      for method <- @bybit_category_required_reads do
        contract = Map.fetch!(category_contracts, method)

        assert support[method] == true
        assert get_in(spec, ["endpoints", "unified", method]) != []
        assert Exchange.has?(exchange, method)

        assert match?(%{"kind" => "literal", "value" => value} when is_binary(value), contract) or
                 match?(
                   %{"kind" => "computed", "operation" => "market_category", "required" => true},
                   contract
                 ),
               "#{method} has no authored category resolution"

        assert_bybit_category_resolves!(exchange, method, contract)
      end

      for {method, %{"kind" => "omit"}} <- category_contracts do
        pre = RequestShape.apply_premarket(%{"category" => "linear"}, exchange, method)

        refute Map.has_key?(pre, "category"),
               "#{method} leaked a category the provider contract does not consume"
      end

      assert get_in(spec, ["capabilities", "has", "fetchDerivativesOpenInterestHistory"]) == true
      assert get_in(spec, ["capabilities", "mapping_complete", "fetchDerivativesOpenInterestHistory"]) == false
      assert get_in(spec, ["capabilities", "verification", "fetchDerivativesOpenInterestHistory"]) == "unverified"
      assert Exchange.has?(exchange, "fetchDerivativesOpenInterestHistory")
    end

    test "unsupported raw endpoint confrontations are registered repo-wide" do
      assert @unsupported_raw_audit["reviewed_at"] == "2026-08-19"
      assert Enum.sort(Map.keys(@unsupported_raw_audit["venues"])) == Enum.sort(@venues)

      for venue <- @venues do
        spec = authored_spec!(venue)
        support = get_in(spec, ["capabilities", "has"])
        carve_register = File.read!("docs/authored-spec-carves/#{venue}.md")

        raw_interfaces =
          spec["raw"]["describe"]["api"]
          |> Exchange.build_endpoint_configs()
          |> MapSet.new(&Bourse.UnifiedMethod.endpoint_config_to_js_name(&1.sections, &1.method, &1.path))

        unsupported = support |> Enum.filter(&(elem(&1, 1) == false)) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
        sorted_raw_interfaces = raw_interfaces |> MapSet.to_list() |> Enum.sort()
        expected_audit = Map.fetch!(@unsupported_raw_audit["venues"], venue)

        assert expected_audit == %{
                 "raw_endpoint_count" => length(sorted_raw_interfaces),
                 "sha256" => unsupported_raw_audit_sha256(unsupported, sorted_raw_interfaces),
                 "unsupported_count" => length(unsupported)
               },
               "#{venue}'s unsupported-capability or raw-endpoint inventory changed; " <>
                 "re-adjudicate provider-false capabilities against the provider contract and " <>
                 "register every matching raw primitive before updating the audit"

        for {method, %{"carve" => carve, "endpoints" => endpoints}} <-
              get_in(spec, ["capabilities", "unsupported_raw_endpoints"]) do
          assert support[method] == false
          assert endpoints != []
          assert Enum.all?(endpoints, &MapSet.member?(raw_interfaces, &1))
          assert carve_register =~ carve
          assert carve_register =~ "`#{method}`"
        end
      end
    end

    test "the guard covers every read in each generated unified endpoint surface" do
      js_names = Map.new(Unified.method_defs(), fn {method, js_name, _params, _description} -> {method, js_name} end)

      for venue <- @venues do
        exchange = Exchange.new!(venue)
        features = exchange.module.__features__()
        spec = authored_spec!(venue)
        offered_reads = offered_reads(spec)

        mapped_reads =
          exchange.module.__unified_endpoints__()
          |> Map.keys()
          |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "fetch_"))

        assert mapped_reads != [], "#{venue} generated no unified read endpoints"

        for method <- mapped_reads,
            js_name = Map.fetch!(js_names, method),
            features[js_name] in [true, "emulated"] do
          assert js_name in offered_reads,
                 "#{venue}.#{js_name} is generated but absent from capabilities.has"
        end
      end
    end

    test "fetchTime is covered on Bybit and Deribit and OKX fetchOpenInterests resolves via alias" do
      cases = [
        {"bybit", Bourse.Bybit, %{"retCode" => 0, "result" => %{"timeSecond" => "1785772800"}}},
        {"deribit", Bourse.Deribit, %{"jsonrpc" => "2.0", "result" => 1_785_772_800_000}}
      ]

      for {venue, module, body} <- cases do
        gaps = parse_coverage_gaps(venue, authored_spec!(venue))
        refute Enum.any?(gaps, &(&1["method"] == "fetchTime"))

        assert {:ok, timestamp} =
                 ReadParse.parse(
                   Exchange.new!(venue),
                   module,
                   :fetch_time,
                   "fetchTime",
                   body,
                   %{},
                   :parse_time,
                   false
                 )

        assert is_integer(timestamp)
      end

      refute Enum.any?(
               parse_coverage_gaps("okx", authored_spec!("okx")),
               &(&1["method"] == "fetchOpenInterests")
             )
    end

    test "return-type resolution is total over declared reads except enumerated net-new residue" do
      pending_by_method = resolution_disposition()["pending_net_new_type_venues"] || %{}
      pending_methods = resolution_disposition()["pending_net_new_type"] || []
      refute Map.has_key?(resolution_disposition(), "has_false")
      contract = runtime_parse_contract()
      method_by_js = Map.new(Unified.method_defs(), fn {method, js, _, _} -> {js, method} end)

      unresolved =
        for venue <- @venues,
            js_name <- supported_reads(venue, authored_spec!(venue)),
            method = Map.fetch!(method_by_js, js_name),
            runtime_parse_type(method, js_name, contract) == :none,
            do: {js_name, venue}

      expected =
        for {js_name, venues} <- pending_by_method,
            venue <- venues,
            do: {js_name, venue}

      assert Enum.sort(unresolved) == Enum.sort(expected)
      assert Enum.sort(pending_methods) == Enum.sort(Map.keys(pending_by_method))

      for {js_name, venue} <- unresolved do
        method = Map.fetch!(method_by_js, js_name)

        case runtime_parse_type(method, js_name, contract) do
          :none ->
            assert venue in Map.fetch!(pending_by_method, js_name)

          {:ok, _parse_type} ->
            flunk("#{venue}.#{js_name} unexpectedly resolved while listed as net-new residue")
        end
      end
    end

    test "each task-565 has=true resolution has a venue-own registered response" do
      recorded = resolution_disposition()["verified_recordings"] || %{}

      expected =
        resolution_disposition()
        |> resolved_has_true_cells()
        |> Enum.sort()

      actual =
        for {js_name, venues} <- recorded,
            venue <- venues,
            do: {venue, js_name}

      assert Enum.sort(actual) == expected

      manifest_cells =
        MapSet.new(@recording_manifest["recordings"], fn row -> {row["venue"], row["method"]} end)

      for {venue, js_name} <- actual do
        method = Macro.underscore(js_name)

        assert MapSet.member?(manifest_cells, {venue, method}),
               "#{venue}.#{js_name} has no manifest-registered venue response"
      end
    end

    test "aliased plural tokens parse venue-own recordings into unified structs" do
      bybit_body =
        "test/fixtures/responses/bybit/fetch_leverage_tiers.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("body")

      assert {:ok, [%Bourse.LeverageTier{} = tier | _] = tiers} =
               ReadParse.parse(
                 Exchange.new!("bybit"),
                 Bourse.Bybit,
                 :fetch_leverage_tiers,
                 "fetchLeverageTiers",
                 bybit_body,
                 %{},
                 :parse_leverage_tiers,
                 true
               )

      assert length(tiers) > 1
      assert is_number(tier.max_leverage)
      assert tier.symbol == "0G/USDT:USDT"

      binanceusdm_body =
        "test/fixtures/responses/binanceusdm/fetch_leverage_tiers.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("body")
        |> Enum.filter(&(&1["symbol"] == "KAVAUSDT"))

      assert {:ok, binanceusdm_tiers} =
               ReadParse.parse(
                 Exchange.new!("binanceusdm"),
                 Bourse.Binanceusdm,
                 :fetch_leverage_tiers,
                 "fetchLeverageTiers",
                 binanceusdm_body,
                 %{},
                 :parse_leverage_tiers,
                 true
               )

      assert %Bourse.LeverageTier{symbol: "KAVA/USDT:USDT"} =
               Enum.find(binanceusdm_tiers, &(&1.info["symbol"] == "KAVAUSDT"))

      okx_body =
        "test/fixtures/responses/okx/fetch_open_interests.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("body")

      assert {:ok, %{} = interests} =
               ReadParse.parse(
                 Exchange.new!("okx"),
                 Bourse.Okx,
                 :fetch_open_interests,
                 "fetchOpenInterests",
                 okx_body,
                 %{},
                 :parse_open_interest,
                 false
               )

      assert map_size(interests) > 0
      assert %Bourse.OpenInterest{} = interests |> Map.values() |> hd()

      last_prices_body =
        "test/fixtures/responses/binance/fetch_last_prices.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("body")

      assert {:ok, [%Bourse.LastPrice{} = price | _]} =
               ReadParse.parse(
                 Exchange.new!("binance"),
                 Bourse.Binance,
                 :fetch_last_prices,
                 "fetchLastPrices",
                 Enum.take(last_prices_body, 5),
                 %{},
                 :parse_last_price,
                 true
               )

      assert is_number(price.price)
    end

    test "Binance leverage-tier carriers flatten without losing their symbols" do
      body = [
        %{
          "symbol" => "BTCUSDT",
          "brackets" => [
            %{
              "bracket" => 1,
              "initialLeverage" => 125,
              "maintMarginRatio" => "0.004",
              "notionalCap" => 50_000,
              "notionalFloor" => 0
            }
          ]
        }
      ]

      assert {:ok, [%Bourse.LeverageTier{} = tier]} =
               ReadParse.parse(
                 Exchange.new!("binanceusdm"),
                 Bourse.Binanceusdm,
                 :fetch_leverage_tiers,
                 "fetchLeverageTiers",
                 body,
                 %{},
                 :parse_leverage_tiers,
                 true
               )

      assert tier.symbol == "BTC/USDT:USDT"
      assert tier.tier == 1
      assert tier.max_leverage == 125
    end
  end

  describe "public parser failures are data" do
    test "OKX funding history with no authored field map returns a typed method error" do
      exchange = Exchange.new!("okx")

      body = %{
        "code" => "0",
        "data" => [
          %{
            "fundingRate" => "0.0000477603410209",
            "fundingTime" => "1785772800000",
            "instId" => "BTC-USDT-SWAP"
          }
        ],
        "msg" => ""
      }

      assert {:error, %Error{exchange: "okx", message: message}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_funding_rate_history,
                 "fetchFundingRateHistory",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_funding_rate_history,
                 true
               )

      assert message =~ "fetch_funding_rate_history"
      refute message =~ "key :symbol not found"
    end

    test "Deribit funding history uses its authored hourly row map" do
      exchange = Exchange.new!("deribit")

      body = %{
        "jsonrpc" => "2.0",
        "result" => [
          %{
            "index_price" => 113_942.33,
            "interest_1h" => 0.0000125,
            "interest_8h" => 0.0001,
            "timestamp" => 1_785_772_800_000
          }
        ]
      }

      assert {:ok,
              [
                %Bourse.FundingRateHistory{
                  symbol: "BTC/USD:BTC",
                  funding_rate: 0.0000125,
                  timestamp: 1_785_772_800_000
                }
              ]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_funding_rate_history,
                 "fetchFundingRateHistory",
                 body,
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_funding_rate_history,
                 true
               )
    end

    test "Binance USD-M empty ADL response is legitimate no-data without weakening all-nil detection" do
      exchange = Exchange.new!("binanceusdm")

      assert {:ok, nil} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binanceusdm,
                 :fetch_position_adl_rank,
                 "fetchPositionADLRank",
                 %{},
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_adl_rank,
                 false
               )

      assert {:error, %Error{message: message}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binanceusdm,
                 :fetch_position_adl_rank,
                 "fetchPositionADLRank",
                 %{"unexpected" => "populated"},
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_adl_rank,
                 false
               )

      assert message =~ "all-nil"
    end
  end

  describe "manifest-recorded unified read contract" do
    test "recorded runtime shapes have no untracked envelopes, row collapses, or native symbol keys" do
      violations =
        Enum.flat_map(recorded_read_cases(), fn {venue, method, path} ->
          fixture =
            RecordedResponseFixtures.fixture_root()
            |> Path.join(path)
            |> RecordedResponseFixtures.load_fixture!()
            |> normalize_recorded_fixture(venue, method)

          assert_manifest_path_registered!(path)

          case replay(fixture, method) do
            {:ok, parsed} ->
              fixture
              |> runtime_contract_violations(method, parsed)
              |> Enum.map(&{venue, method, &1, tracking_task(venue, method, &1)})

            {:error, %Error{}} ->
              []

            other ->
              flunk("#{venue}.#{method} escaped the unified result contract: #{inspect(other)}")
          end
        end)

      assert violations == @known_runtime_gaps
    end

    test "the same guard rejects provider envelope keys from real OKX and Deribit recordings" do
      for {venue, method} <- [
            {"okx", :fetch_funding_rate_history},
            {"deribit", :fetch_funding_rate_history}
          ] do
        fixture = recorded_fixture!(venue, method)
        assert_manifest_registered!(venue, method)

        assert :raw_envelope in runtime_contract_violations(fixture, method, fixture["body"])
      end
    end

    test "the remaining unmapped OKX funding history replays as a typed method error" do
      fixture = recorded_fixture!("okx", :fetch_funding_rate_history)
      assert {:error, %Error{exchange: "okx", message: message}} = replay(fixture, :fetch_funding_rate_history)
      assert message =~ "fetch_funding_rate_history"
      refute message =~ "key :symbol not found"
    end

    test "recorded Deribit funding history replays as typed hourly rows" do
      fixture = recorded_fixture!("deribit", :fetch_funding_rate_history)
      raw_rows = fixture["body"]["result"]

      assert {:ok, rows} = replay(fixture, :fetch_funding_rate_history)
      assert length(rows) == length(raw_rows)

      assert Enum.all?(rows, fn row ->
               match?(%Bourse.FundingRateHistory{}, row) and
                 is_number(row.funding_rate) and is_integer(row.timestamp) and is_binary(row.datetime)
             end)
    end

    test "empty live USD-M ADL response replays as no data" do
      fixture = recorded_fixture!("binanceusdm", :fetch_position_adl_rank)
      assert fixture["body"] == %{}
      assert {:ok, nil} = replay(fixture, :fetch_position_adl_rank)
    end

    test "live populated recordings bind the four repaired values" do
      ledger_fixture = recorded_fixture!("binanceusdm", :fetch_ledger)
      raw_ledger = hd(ledger_fixture["body"])
      assert {:ok, [%Bourse.LedgerEntry{} = ledger | _]} = replay(ledger_fixture, :fetch_ledger)
      assert_mapped_value!(raw_ledger["income"], ledger.amount, "income", :amount)
      assert_mapped_value!(raw_ledger["asset"], ledger.currency, "asset", :currency)
      assert_mapped_value!(raw_ledger["incomeType"], ledger.type, "incomeType", :type)
      assert ledger.direction == "out"

      interval_fixture = recorded_fixture!("binanceusdm", :fetch_funding_intervals)
      raw_interval = hd(interval_fixture["body"])
      assert {:ok, %Bourse.FundingRate{} = funding} = replay(interval_fixture, :fetch_funding_intervals)
      assert_mapped_value!(raw_interval["fundingIntervalHours"], funding.interval, "fundingIntervalHours", :interval)

      time_fixture = recorded_fixture!("alpaca", :fetch_time)
      assert {:ok, timestamp} = replay(time_fixture, :fetch_time)
      assert_mapped_value!(time_fixture["body"]["timestamp"], timestamp, "timestamp", :epoch_milliseconds)
      assert timestamp > 1_000_000_000_000

      orders_fixture = recorded_fixture!("derive", :fetch_canceled_orders)
      raw_orders = get_in(orders_fixture, ["body", "result", "orders"])
      assert {:ok, orders} = replay(orders_fixture, :fetch_canceled_orders)
      assert length(orders) == length(raw_orders)
      assert [%Bourse.Order{} = first | _] = orders
      assert_mapped_value!(hd(raw_orders)["order_id"], first.id, "order_id", :id)
    end
  end

  describe "recorded populated values reach their unified fields" do
    test "Binance USD-M income rows populate ledger amount, currency, and type" do
      raw = %{
        "asset" => "USDT",
        "income" => "-0.03079999",
        "incomeType" => "REALIZED_PNL",
        "time" => 1_785_715_578_000,
        "tranId" => 90_030_523_893_572
      }

      assert {:ok, [%Bourse.LedgerEntry{} = entry]} =
               ReadParse.parse(
                 Exchange.new!("binanceusdm"),
                 Bourse.Binanceusdm,
                 :fetch_ledger,
                 "fetchLedger",
                 [raw],
                 %{"_bourse_endpoint_route" => "income"},
                 :parse_ledger_entry,
                 true
               )

      assert_mapped_value!(raw["income"], entry.amount, "income", :amount)
      assert_mapped_value!(raw["asset"], entry.currency, "asset", :currency)
      assert_mapped_value!(raw["incomeType"], entry.type, "incomeType", :type)
      assert entry.amount == -0.03079999
      assert entry.currency == "USDT"
      assert entry.direction == "out"
      assert entry.type == "realized_pnl"
      assert entry.info["incomeType"] == "REALIZED_PNL"

      funding_raw = %{raw | "incomeType" => "FUNDING_FEE"}

      assert {:ok, [%Bourse.LedgerEntry{} = funding_entry]} =
               ReadParse.parse(
                 Exchange.new!("binanceusdm"),
                 Bourse.Binanceusdm,
                 :fetch_ledger,
                 "fetchLedger",
                 [funding_raw],
                 %{"_bourse_endpoint_route" => "income"},
                 :parse_ledger_entry,
                 true
               )

      assert funding_entry.type == "funding_fee"
      assert funding_entry.info["incomeType"] == "FUNDING_FEE"
    end

    test "Binance USD-M funding interval preserves fundingIntervalHours" do
      raw = %{
        "adjustedFundingRateCap" => "0.0075",
        "adjustedFundingRateFloor" => "-0.0075",
        "fundingIntervalHours" => 8,
        "symbol" => "SUSHIUSDT"
      }

      assert {:ok, %Bourse.FundingRate{} = rate} =
               ReadParse.parse(
                 Exchange.new!("binanceusdm"),
                 Bourse.Binanceusdm,
                 :fetch_funding_intervals,
                 "fetchFundingIntervals",
                 [raw],
                 %{},
                 :parse_funding_rate,
                 false
               )

      assert_mapped_value!(raw["fundingIntervalHours"], rate.interval, "fundingIntervalHours", :interval)
      assert rate.interval == "8h"
    end

    test "Alpaca clock ISO-8601 timestamp becomes epoch milliseconds" do
      raw = %{
        "is_open" => false,
        "timestamp" => "2026-08-03T19:48:10.111642616-04:00"
      }

      assert {:ok, timestamp} =
               ReadParse.parse(
                 Exchange.new!("alpaca"),
                 Bourse.Alpaca,
                 :fetch_time,
                 "fetchTime",
                 raw,
                 %{},
                 :parse_time,
                 false
               )

      assert_mapped_value!(raw["timestamp"], timestamp, "timestamp", :epoch_milliseconds)
      assert timestamp == 1_785_800_890_111
    end

    test "Derive canceled-order envelope maps every result.orders row" do
      rows = [
        derive_order("order-1", "open"),
        derive_order("order-2", "canceled")
      ]

      body = %{"id" => "1", "jsonrpc" => "2.0", "result" => %{"orders" => rows}}

      assert {:ok, [%Bourse.Order{} = first, %Bourse.Order{} = second]} =
               ReadParse.parse(
                 Exchange.new!("derive"),
                 Bourse.Derive,
                 :fetch_canceled_orders,
                 "fetchCanceledOrders",
                 body,
                 %{},
                 :parse_order,
                 true
               )

      assert_mapped_value!(hd(rows)["order_id"], first.id, "order_id", :id)
      assert first.id == "order-1"
      assert second.id == "order-2"
    end
  end

  defp resolution_disposition, do: @resolution_disposition

  defp resolved_has_true_cells(disposition) do
    alias_cells =
      for {_token, entry} <- disposition["aliased"] || %{},
          js_name <- entry["methods"] || [],
          venue <- entry["venues"] || [],
          do: {venue, js_name}

    descriptor_cells =
      for {js_name, entry} <- disposition["descriptor_return_types_added"] || %{},
          venue <- entry["venues"] || [],
          do: {venue, js_name}

    Enum.uniq(alias_cells ++ descriptor_cells)
  end

  defp authored_spec!(venue) do
    JsonDocument.decode_file!("priv/specs/json/output/authored/#{venue}.json")
  end

  defp unsupported_raw_audit_sha256(unsupported, raw_interfaces) do
    material = Enum.join(unsupported, "\0") <> "\1" <> Enum.join(raw_interfaces, "\0")

    :sha256
    |> :crypto.hash(material)
    |> Base.encode16(case: :lower)
  end

  defp market_context_rules(venue) do
    venue
    |> authored_spec!()
    |> get_in(["normalization", "field_maps"])
    |> Enum.flat_map(fn {parse_type, slot} -> market_context_rules(slot, venue, [parse_type]) end)
  end

  defp market_context_rules(value, venue, path) when is_map(value) do
    dependencies =
      []
      |> maybe_add_dependency(is_binary(value["inverse_op"]), "inverse_op")
      |> maybe_add_dependency(
        is_binary(value["discriminator"]) and String.starts_with?(value["discriminator"], "market."),
        value["discriminator"]
      )

    current =
      Enum.map(dependencies, fn dependency ->
        %{
          name: "#{venue}/#{Enum.map_join(path, "/", &to_string/1)}##{dependency}",
          parse_type: hd(path),
          path: path,
          venue: venue
        }
      end)

    children =
      Enum.flat_map(value, fn {key, child} ->
        market_context_rules(child, venue, path ++ [key])
      end)

    current ++ children
  end

  defp market_context_rules(value, venue, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} -> market_context_rules(child, venue, path ++ [index]) end)
  end

  defp market_context_rules(_value, _venue, _path), do: []

  defp maybe_add_dependency(dependencies, true, dependency), do: [dependency | dependencies]
  defp maybe_add_dependency(dependencies, false, _dependency), do: dependencies

  defp symbol_less_parse_types do
    method_defs =
      Map.new(Unified.method_defs(), fn {method, js_name, params, _description} -> {js_name, {method, params}} end)

    contract = runtime_parse_contract()

    MapSet.new(
      for venue <- @venues,
          js_name <- supported_reads(venue, authored_spec!(venue)),
          {method, required_params} = Map.fetch!(method_defs, js_name),
          :symbol not in required_params,
          {:ok, parse_type} <- [runtime_parse_type(method, js_name, contract)],
          do: {venue, parse_type}
    )
  end

  defp symbol_less_safe_disposition?({:payload_guard, _guard}), do: true
  defp symbol_less_safe_disposition?(:non_money_exemption), do: true

  # OKX's array-shaped open-interest branch is used by the symbol-required
  # history read; symbol-less fetchOpenInterests selects the object branch.
  defp symbol_less_safe_disposition?(:symbol_required_branch), do: true
  defp symbol_less_safe_disposition?(_disposition), do: false

  defp declared_reads(spec) do
    spec
    |> get_in(["capabilities", "has"])
    |> Enum.filter(fn {method, value} -> value == true and String.starts_with?(method, "fetch") end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp offered_reads(spec) do
    spec
    |> get_in(["capabilities", "has"])
    |> Enum.filter(fn {method, value} -> value in [true, "emulated"] and String.starts_with?(method, "fetch") end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp supported_reads(venue, spec) do
    js_name_by_method =
      Map.new(Unified.method_defs(), fn {method, js_name, _params, _description} ->
        {method, js_name}
      end)

    declared_reads = MapSet.new(declared_reads(spec))
    exchange = Exchange.new!(venue)

    exchange.module.__unified_endpoints__()
    |> Map.keys()
    |> Enum.map(&Map.fetch!(js_name_by_method, &1))
    |> Enum.filter(&MapSet.member?(declared_reads, &1))
    |> Enum.sort()
  end

  defp parse_coverage_gaps(_venue, spec) do
    support = get_in(spec, ["capabilities", "has"])

    spec
    |> get_in(["capabilities", "mapping_complete"])
    |> Enum.flat_map(fn
      {method, false} when is_map_key(support, method) ->
        if support[method] in [true, "emulated"] and String.starts_with?(method, "fetch") do
          [%{"method" => method}]
        else
          []
        end

      _entry ->
        []
    end)
    |> Enum.sort_by(& &1["method"])
  end

  defp runtime_parse_contract do
    %{
      aliases: module_attribute_value!(@unified_source_path, :return_type_aliases),
      parsers: module_attribute_value!(@unified_source_path, :parsers_by_parse_type),
      parse_types_by_return: module_attribute_value!(@unified_source_path, :parse_types_by_return_type),
      parser_slots: module_attribute_value!(@read_parse_source_path, :parser_slots),
      special_plans: special_parser_plans()
    }
  end

  defp runtime_parse_type(method, js_name, runtime_contract) do
    with {:ok, parser} <- runtime_parser(method, js_name, runtime_contract) do
      Map.fetch(runtime_contract.parser_slots, parser)
    end
  end

  defp runtime_parser(method, js_name, runtime_contract) do
    case Map.fetch(runtime_contract.special_plans, {method, js_name}) do
      {:ok, parser} -> {:ok, parser}
      :error -> descriptor_parser(js_name, runtime_contract)
    end
  end

  defp descriptor_parser(js_name, runtime_contract) do
    with %{"signature" => %{"return_type" => "Promise<" <> rest}} <-
           Map.get(Descriptor.descriptors(), js_name),
         type_token = rest |> String.trim_trailing(">") |> String.trim_trailing("[]"),
         aliased_token = Map.get(runtime_contract.aliases, type_token, type_token),
         {:ok, parse_type} <- Map.fetch(runtime_contract.parse_types_by_return, aliased_token),
         {:ok, parser} <- Map.fetch(runtime_contract.parsers, parse_type) do
      {:ok, parser}
    else
      _ -> :none
    end
  end

  defp special_parser_plans do
    @unified_source_path
    |> function_clauses(:parser_plan, 2)
    |> Enum.flat_map(fn
      %{
        args: [method, js_name],
        body: {:{}, _meta, [:ok, parser, _list_return?]}
      }
      when is_atom(method) and is_binary(js_name) and is_atom(parser) ->
        [{{method, js_name}, parser}]

      _clause ->
        []
    end)
    |> Map.new()
  end

  defp function_clauses(path, function_name, arity) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:defp, _meta, [head, body]} = node, acc ->
          {call, guard} = unwrap_guard(head)

          case call do
            {^function_name, _call_meta, args} when length(args) == arity ->
              clause = %{args: args, body: Keyword.fetch!(body, :do), guard: guard}
              {node, [clause | acc]}

            _other ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(clauses)
  end

  defp unwrap_guard({:when, _meta, [call, guard]}), do: {call, guard}
  defp unwrap_guard(call), do: {call, true}

  defp module_attribute_value!(path, attribute) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, value_ast} =
      Macro.prewalk(ast, nil, fn
        {:@, _meta, [{^attribute, _attribute_meta, [value]}]} = node, nil -> {node, value}
        node, acc -> {node, acc}
      end)

    eval_env = %{__ENV__ | aliases: [{FieldMaps, Bourse.Unified.FieldMaps} | __ENV__.aliases]}
    {value, []} = Code.eval_quoted(value_ast, [], eval_env)
    value
  end

  defp assert_mapped_value!(raw_value, parsed_value, raw_field, unified_field) do
    refute is_nil(raw_value), "test fixture must carry #{raw_field}"

    refute is_nil(parsed_value),
           "venue supplied #{raw_field}, but unified field #{unified_field} stayed nil"
  end

  defp recorded_fixture!(venue, method) do
    venue
    |> RecordedResponseFixtures.fixture_path(method)
    |> RecordedResponseFixtures.load_fixture!()
  end

  defp normalize_recorded_fixture(%{"exchange" => _fixture_venue} = fixture, _venue, _method), do: fixture

  defp normalize_recorded_fixture(body, venue, method) do
    %{
      "body" => body,
      "call_opts" => %{},
      "exchange" => venue,
      "method" => Atom.to_string(method),
      "params" => %{}
    }
  end

  defp recorded_read_cases do
    Enum.flat_map(@recording_manifest["recordings"], fn recording ->
      venue = recording["venue"]

      with method when is_atom(method) <- method_atom(recording["method"]),
           true <- Map.has_key?(Exchange.new!(venue).module.__unified_endpoints__(), method) do
        [{venue, method, recording["path"]}]
      else
        _missing_or_auxiliary_method -> []
      end
    end)
  end

  defp assert_manifest_registered!(venue, method) do
    path = "#{venue}/#{method}.json"
    assert_manifest_path_registered!(path)
  end

  defp assert_manifest_path_registered!(path) do
    assert path in @recording_manifest["fixtures"], "#{path} is not registered in the response manifest"
  end

  defp replay(fixture, method) do
    exchange = replay_exchange(fixture["exchange"])
    stub = {__MODULE__, fixture["exchange"], method, System.unique_integer([:positive])}
    Req.Test.stub(stub, fn conn -> Req.Test.json(conn, replay_body!(fixture, conn)) end)

    opts =
      fixture
      |> RecordedResponseFixtures.decode_call_opts()
      |> Keyword.put(:plug, {Req.Test, stub})

    Unified.call(exchange, method, js_name(method), replay_params(fixture), opts)
  end

  defp replay_body!(%{"responses" => responses}, conn) when is_list(responses) do
    query = URI.decode_query(conn.query_string)

    case Enum.find(responses, &response_matches_query?(&1, query)) do
      %{"body" => body} -> body
      nil -> raise "recorded fan-out response does not match query #{inspect(query)}"
    end
  end

  defp replay_body!(fixture, _conn), do: fixture["body"]

  defp response_matches_query?(%{"params" => params}, query) do
    Enum.all?(params, fn {key, value} -> query[key] == to_string(value) end)
  end

  defp replay_params(%{"params" => %{"variants" => _variants}}), do: %{}
  defp replay_params(fixture), do: fixture["params"] || %{}

  defp replay_exchange("derive" = venue) do
    exchange = ReplayExchange.build!(venue, %{})
    %{exchange | options: Map.put(exchange.options, "subaccount_id", 1)}
  end

  defp replay_exchange("alpaca") do
    credentials = Bourse.Credentials.new!(api_key: "key", secret: "secret")
    Exchange.new!("alpaca", credentials: credentials)
  end

  defp replay_exchange("binancecoinm") do
    credentials = Bourse.Credentials.new!(api_key: "key", secret: "secretsecret")
    Exchange.new!("binancecoinm", credentials: credentials)
  end

  defp replay_exchange("lighter") do
    credentials =
      Bourse.Credentials.new!(
        api_key: "30",
        secret: "e6b975b33b81e53fb5333bd84553f12b3b5327ce5b1595139f49e8bebf734d9b1b81d3351b487d1b",
        uid: "715085"
      )

    Exchange.new!("lighter", credentials: credentials)
  end

  defp replay_exchange(venue), do: ReplayExchange.build!(venue, %{})

  defp js_name(method) do
    Enum.find_value(Unified.method_defs(), fn {candidate, js_name, _params, _description} ->
      if candidate == method, do: js_name
    end)
  end

  defp method_atom(method_name) do
    Enum.find_value(Unified.method_defs(), fn {method, _js_name, _params, _description} ->
      if Atom.to_string(method) == method_name, do: method
    end)
  end

  defp runtime_contract_violations(fixture, method, parsed) do
    []
    |> maybe_add(raw_envelope?(parsed), :raw_envelope)
    |> maybe_add(row_count_collapsed?(fixture["body"], parsed), row_count_violation(fixture["body"], parsed))
    |> maybe_add(symbol_keyed_method?(method) and not unified_symbol_map?(parsed), :not_symbol_keyed)
    |> maybe_add(not valid_unified_shape?(method, parsed), :untyped_result)
    |> Enum.reverse()
  end

  defp raw_envelope?(map) when is_map(map) and not is_struct(map) do
    keys = map |> Map.keys() |> MapSet.new()

    Enum.any?(
      [
        MapSet.new(~w(code data msg)),
        MapSet.new(~w(jsonrpc result)),
        MapSet.new(~w(retCode result))
      ],
      &MapSet.subset?(&1, keys)
    )
  end

  defp raw_envelope?(_value), do: false

  defp row_count_collapsed?(raw, parsed) when is_list(raw) and length(raw) > 1 do
    parsed_count(parsed) == 1
  end

  defp row_count_collapsed?(%{"result" => %{"orders" => rows}}, parsed) when is_list(rows) and length(rows) > 1 do
    parsed_count(parsed) == 1
  end

  defp row_count_collapsed?(_raw, _parsed), do: false

  defp row_count_violation(raw, parsed) when is_list(raw) do
    {:row_count_collapsed, length(raw), parsed_count(parsed)}
  end

  defp row_count_violation(%{"result" => %{"orders" => rows}}, parsed) do
    {:row_count_collapsed, length(rows), parsed_count(parsed)}
  end

  defp row_count_violation(_raw, _parsed), do: nil

  defp parsed_count(value) when is_list(value), do: length(value)
  defp parsed_count(value) when is_map(value) and not is_struct(value), do: map_size(value)
  defp parsed_count(nil), do: 0
  defp parsed_count(_value), do: 1

  defp assert_bybit_category_resolves!(exchange, method, %{"kind" => "literal", "value" => value})
       when is_binary(value) do
    pre = RequestShape.apply_premarket(%{}, exchange, method)
    assert pre["category"] == value, "#{method} literal category was not applied before dispatch"
  end

  defp assert_bybit_category_resolves!(exchange, method, %{"kind" => "computed", "default" => default})
       when is_binary(default) do
    pre = RequestShape.apply_premarket(%{}, exchange, method)
    assert pre["category"] == default, "#{method} authored default was not applied before dispatch"

    derived = RequestShape.apply_premarket(%{"symbol" => "BTC/USDT:USDT"}, exchange, method)
    assert derived["category"] == "linear", "#{method} did not derive linear from a unified swap symbol"
  end

  defp assert_bybit_category_resolves!(exchange, method, %{"kind" => "computed", "required" => true}) do
    derived = RequestShape.apply_premarket(%{"symbol" => "BTC/USDT:USDT"}, exchange, method)

    assert derived["category"] == "linear",
           "#{method} did not derive category from a unified linear symbol"

    error = assert_raise Error, fn -> RequestShape.apply(%{}, exchange, method) end
    assert error.raw["reason"] == "missing_required_param", "#{method} did not fail closed without a category signal"
    assert error.raw["parameter"] == "category"
  end

  defp symbol_keyed_method?(method),
    do: method in [:fetch_bids_asks, :fetch_funding_intervals, :fetch_last_prices, :fetch_leverages]

  defp unified_symbol_map?(map) when is_map(map) and not is_struct(map) do
    map_size(map) > 0 and
      Enum.all?(map, fn
        {symbol, %{__struct__: _module}} when is_binary(symbol) -> String.contains?(symbol, "/")
        _entry -> false
      end)
  end

  defp unified_symbol_map?(_value), do: false

  defp valid_unified_shape?(:fetch_time, value), do: is_integer(value)

  defp valid_unified_shape?(:fetch_ohlcv, values) when is_list(values) do
    Enum.all?(values, &(is_list(&1) and length(&1) >= 6))
  end

  defp valid_unified_shape?(:fetch_position_adl_rank, nil), do: true
  defp valid_unified_shape?(:fetch_adl_rank, nil), do: true
  defp valid_unified_shape?(_method, %{__struct__: _module}), do: true

  defp valid_unified_shape?(_method, values) when is_list(values) do
    Enum.all?(values, &match?(%{__struct__: _module}, &1))
  end

  defp valid_unified_shape?(_method, values) when is_map(values) do
    not raw_envelope?(values) and Enum.all?(values, fn {_key, value} -> is_struct(value) end)
  end

  defp valid_unified_shape?(_method, _value), do: false

  defp maybe_add(violations, true, violation), do: [violation | violations]
  defp maybe_add(violations, false, _violation), do: violations

  defp tracking_task(venue, method, violation) do
    case Enum.find(@known_runtime_gaps, fn {known_venue, known_method, known_violation, _task} ->
           {known_venue, known_method, known_violation} == {venue, method, violation}
         end) do
      {_venue, _method, _violation, task} -> task
      nil -> nil
    end
  end

  defp derive_order(id, status) do
    %{
      "amount" => "0.1",
      "creation_timestamp" => 1_785_800_000_000,
      "direction" => "buy",
      "instrument_name" => "ETH-PERP",
      "limit_price" => "1000",
      "order_id" => id,
      "order_status" => status,
      "order_type" => "limit",
      "time_in_force" => "gtc"
    }
  end
end
