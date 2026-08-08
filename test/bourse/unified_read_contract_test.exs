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

  @runtime_manifest "priv/specs/json/runtime_support.json"
  @exclusions_path "test/fixtures/unified_read_parse_coverage_exclusions.json"
  @resolution_disposition_path "test/fixtures/unified_read_return_type_resolution.json"
  @unified_source_path "lib/bourse/unified.ex"
  @read_parse_source_path "lib/bourse/unified/read_parse.ex"
  @external_resource @runtime_manifest
  @external_resource @exclusions_path
  @external_resource @resolution_disposition_path
  @external_resource @unified_source_path
  @external_resource @read_parse_source_path
  @venues @runtime_manifest |> File.read!() |> Jason.decode!() |> Map.fetch!("venues")
  @exclusions @exclusions_path |> File.read!() |> Jason.decode!()
  @resolution_disposition @resolution_disposition_path |> File.read!() |> Jason.decode!()
  @recording_manifest_path "test/fixtures/responses/_manifest.json"
  @external_resource @recording_manifest_path
  @recording_manifest @recording_manifest_path |> File.read!() |> Jason.decode!()

  # TODO(Task 538): remove each entry as the sibling task repairs the recorded
  # collection-shape violations. Exact enumeration keeps new regressions red.
  # fetch_last_prices is now typed as LastPrice[] (task 565); remaining gaps are
  # collection-shape only (list vs symbol-keyed map).
  @known_runtime_gaps [
    {"binance", :fetch_bids_asks, {:row_count_collapsed, 3_673, 1}, 538},
    {"binance", :fetch_bids_asks, :not_symbol_keyed, 538},
    {"binance", :fetch_last_prices, :not_symbol_keyed, 538},
    {"binanceusdm", :fetch_funding_intervals, {:row_count_collapsed, 616, 1}, 538},
    {"binanceusdm", :fetch_funding_intervals, :not_symbol_keyed, 538}
  ]

  describe "static parse coverage" do
    test "every supported read with a runtime parse gap is explicitly tracked by task 550" do
      actual =
        Map.new(@venues, fn venue ->
          spec = authored_spec!(venue)
          {venue, parse_coverage_gaps(venue, spec)}
        end)

      assert Map.new(actual, fn {venue, entries} -> {venue, length(entries)} end) == %{
               "alpaca" => 0,
               "binance" => 8,
               "binancecoinm" => 1,
               "binanceusdm" => 11,
               "bybit" => 7,
               "deribit" => 2,
               "derive" => 0,
               "hyperliquid" => 2,
               "lighter" => 0,
               "okx" => 7
             }

      expected =
        Map.new(@exclusions, fn {venue, entries} ->
          assert Enum.all?(entries, &(&1["tracking_task"] == 550)),
                 "#{venue} has a parse-coverage exclusion not owned by task 550"

          assert Enum.all?(entries, &(&1["failure"] in ["no_parse_type", "no_field_map"])),
                 "#{venue} has a parse-coverage exclusion without a failure kind"

          {venue, entries}
        end)

      assert actual == expected
    end

    test "the guard covers every read in each generated unified endpoint surface" do
      js_names = Map.new(Unified.method_defs(), fn {method, js_name, _params, _description} -> {method, js_name} end)

      for venue <- @venues do
        exchange = Exchange.new!(venue)
        features = exchange.module.__features__()
        spec = authored_spec!(venue)
        declared_reads = declared_reads(spec)

        mapped_reads =
          exchange.module.__unified_endpoints__()
          |> Map.keys()
          |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "fetch_"))

        assert mapped_reads != [], "#{venue} generated no unified read endpoints"

        for method <- mapped_reads,
            js_name = Map.fetch!(js_names, method),
            features[js_name] == true do
          assert js_name in declared_reads,
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
      pending = MapSet.new(resolution_disposition()["pending_net_new_type"] || [])
      contract = runtime_parse_contract()
      method_by_js = Map.new(Unified.method_defs(), fn {method, js, _, _} -> {js, method} end)

      for venue <- @venues do
        for js_name <- supported_reads(venue, authored_spec!(venue)) do
          method = Map.fetch!(method_by_js, js_name)

          case runtime_parse_type(method, js_name, contract) do
            {:ok, _parse_type} ->
              :ok

            :none ->
              assert MapSet.member?(pending, js_name),
                     "#{venue}.#{js_name} is has=true but unresolvable and not enumerated as net-new residue"
          end
        end
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
      assert is_binary(tier.symbol)

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
                 %{},
                 :parse_ledger_entry,
                 true
               )

      assert_mapped_value!(raw["income"], entry.amount, "income", :amount)
      assert_mapped_value!(raw["asset"], entry.currency, "asset", :currency)
      assert_mapped_value!(raw["incomeType"], entry.type, "incomeType", :type)
      assert entry.amount == -0.03079999
      assert entry.currency == "USDT"
      assert entry.type == "trade"
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

  defp authored_spec!(venue) do
    JsonDocument.decode_file!("priv/specs/json/output/authored/#{venue}.json")
  end

  defp declared_reads(spec) do
    spec
    |> get_in(["capabilities", "has"])
    |> Enum.filter(fn {method, value} -> value == true and String.starts_with?(method, "fetch") end)
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

  defp parse_coverage_gaps(venue, spec) do
    method_by_js_name =
      Map.new(Unified.method_defs(), fn {method, js_name, _params, _description} ->
        {js_name, method}
      end)

    field_maps = get_in(spec, ["normalization", "field_maps"]) || %{}
    runtime_contract = runtime_parse_contract()

    venue
    |> supported_reads(spec)
    |> Enum.flat_map(fn js_name ->
      method = Map.fetch!(method_by_js_name, js_name)

      parse_gap(js_name, venue, method, field_maps, runtime_contract)
    end)
  end

  defp parse_gap(js_name, venue, method, field_maps, runtime_contract) do
    case runtime_parse_type(method, js_name, runtime_contract) do
      {:ok, parse_type} ->
        if Map.has_key?(field_maps, parse_type) or
             read_parse_bypass?(runtime_contract.read_parse_bypasses, parse_type, venue, js_name) do
          []
        else
          [
            %{
              "failure" => "no_field_map",
              "method" => js_name,
              "parse_type" => parse_type,
              "tracking_task" => 550
            }
          ]
        end

      :none ->
        [%{"failure" => "no_parse_type", "method" => js_name, "tracking_task" => 550}]
    end
  end

  defp runtime_parse_contract do
    %{
      aliases: module_attribute_value!(@unified_source_path, :return_type_aliases),
      parsers: module_attribute_value!(@unified_source_path, :parsers_by_parse_type),
      parse_types_by_return: module_attribute_value!(@unified_source_path, :parse_types_by_return_type),
      parser_slots: module_attribute_value!(@read_parse_source_path, :parser_slots),
      read_parse_bypasses: read_parse_bypasses(),
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

  defp read_parse_bypasses do
    @read_parse_source_path
    |> function_clauses(:do_parse, 8)
    |> Enum.filter(fn %{args: args, body: body} ->
      parser_arg = Enum.at(args, 6)
      not ast_uses_variable?(body, variable_name(parser_arg))
    end)
  end

  defp read_parse_bypass?(bypasses, parse_type, venue, js_name) do
    Enum.any?(bypasses, fn %{args: [parse_type_arg, exchange, _module, js_name_arg | _], guard: guard} ->
      domain_match?(argument_domain(parse_type_arg, guard), parse_type) and
        domain_match?(exchange_domain(exchange, guard), venue) and
        domain_match?(argument_domain(js_name_arg, guard), js_name)
    end)
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

  defp ast_uses_variable?(_ast, nil), do: false

  defp ast_uses_variable?(ast, variable) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {^variable, _meta, context} = node, _found? when is_atom(context) or is_nil(context) ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp exchange_domain({:%, _meta, [_module, {:%{}, _map_meta, fields}]}, guard) do
    fields |> Keyword.fetch!(:id) |> argument_domain(guard)
  end

  defp exchange_domain(_exchange, _guard), do: :all

  defp argument_domain(value, _guard) when is_atom(value) or is_binary(value), do: [value]

  defp argument_domain({name, _meta, context}, guard) when is_atom(name) and (is_atom(context) or is_nil(context)) do
    guard_domain(guard, name) || :all
  end

  defp argument_domain(_argument, _guard), do: :all

  defp guard_domain(guard, variable) do
    {_guard, domain} =
      Macro.prewalk(guard, nil, fn
        {:in, _meta, [{^variable, _variable_meta, _context}, values]} = node, nil when is_list(values) ->
          {node, Enum.map(values, &literal!/1)}

        {:==, _meta, [{^variable, _variable_meta, _context}, value]} = node, nil ->
          {node, [literal!(value)]}

        node, acc ->
          {node, acc}
      end)

    domain
  end

  defp domain_match?(:all, _value), do: true
  defp domain_match?(domain, value), do: value in domain

  defp variable_name({name, _meta, context}) when is_atom(name) and (is_atom(context) or is_nil(context)), do: name
  defp variable_name(_argument), do: nil

  defp literal!(value) when is_atom(value) or is_binary(value) or is_boolean(value), do: value

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

  defp symbol_keyed_method?(method), do: method in [:fetch_bids_asks, :fetch_funding_intervals, :fetch_last_prices]

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
