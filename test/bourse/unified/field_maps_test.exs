defmodule Bourse.Unified.FieldMapsTest do
  use ExUnit.Case, async: true

  alias Bourse.Unified.FieldMaps

  doctest FieldMaps

  @canonical_fields_under_test ["ticker", "trade", "ohlcv", "volatility_history"]

  setup_all do
    exchange_ids = Bourse.Spec.exchanges()
    specs = Enum.map(exchange_ids, &Bourse.Spec.load!/1)

    direct_fields =
      @canonical_fields_under_test
      |> Task.async_stream(
        &{&1, FieldMaps.canonical_fields(&1)},
        max_concurrency: length(@canonical_fields_under_test),
        timeout: :infinity
      )
      |> Map.new(fn {:ok, pair} -> pair end)

    {:ok,
     canonical_field_sets: canonical_field_sets(specs),
     direct_fields: direct_fields,
     catalog_spec_loads: length(specs),
     exchange_count: length(exchange_ids)}
  end

  defp struct_fields(module) do
    module.__struct__()
    |> Map.from_struct()
    |> Map.keys()
    |> MapSet.new(&Atom.to_string/1)
  end

  defp schema_keys(module) do
    module.schema()
    |> Map.fetch!("properties")
    |> Map.keys()
    |> MapSet.new()
  end

  describe "derivation surface" do
    test "suite snapshot loads each catalog spec once when deriving every canonical field set", %{
      canonical_field_sets: field_sets,
      catalog_spec_loads: spec_loads,
      exchange_count: exchange_count
    } do
      assert spec_loads == exchange_count
      assert map_size(field_sets) == length(FieldMaps.parse_types())
    end

    # The struct-coverage sweep below grades every struct against
    # `canonical_field_sets/1`, a suite-local derivation that reads each spec once
    # instead of once per parse type. That makes the sweep's oracle a second
    # implementation, so pin it to production `FieldMaps.canonical_fields/1` on
    # every sampled type — a resolved slot, a renamed slot (`trade`), and the two
    # array-shaped slots. Without this the sweep could go green against a drifted
    # local copy while the shipped derivation is broken.
    test "the suite-local derivation agrees with FieldMaps.canonical_fields/1", %{
      canonical_field_sets: field_sets,
      direct_fields: direct_fields
    } do
      for parse_type <- @canonical_fields_under_test do
        assert field_sets[parse_type] == direct_fields[parse_type],
               "suite-local derivation drifted from FieldMaps.canonical_fields/1 for #{parse_type}"
      end
    end

    test "parse_types/0 lists the governed parse types, each with a struct" do
      types = FieldMaps.parse_types()

      assert types == [
               "account",
               "adl_rank",
               "balance",
               "borrow_interest",
               "borrow_rate",
               "conversion",
               "currency",
               "deposit_address",
               "funding_history",
               "funding_rate",
               "funding_rate_history",
               "greeks",
               "ledger_entry",
               "leverage",
               "leverage_tiers",
               "liquidation",
               "long_short_ratio",
               "margin_loan",
               "margin_mode",
               "margin_modification",
               "market",
               "ohlcv",
               "open_interest",
               "option",
               "order",
               "position",
               "ticker",
               "trade",
               "trading_fee",
               "transaction",
               "transfer",
               "volatility_history"
             ]

      for type <- types do
        assert is_atom(FieldMaps.struct_for(type)), "no struct mapped for #{type}"
      end
    end

    test "struct_for/1 returns nil for an unknown parse type" do
      assert FieldMaps.struct_for("nope") == nil
    end

    test "coercion_type/1 maps the v4 coercion vocabulary to JSONSpec scalars" do
      assert FieldMaps.coercion_type("safeString") == :string
      assert FieldMaps.coercion_type("safeStringLower") == :string
      assert FieldMaps.coercion_type("safeInteger2") == :integer
      assert FieldMaps.coercion_type("safeNumber") == :number
      assert FieldMaps.coercion_type("safeBool") == :boolean
    end

    test "coercion_type/1 returns :unknown for nil or unrecognised coercion" do
      assert FieldMaps.coercion_type(nil) == :unknown
      assert FieldMaps.coercion_type("safeWeird") == :unknown
    end

    test "canonical_fields/1 derives snake_case keys including unresolved canonical keys", %{direct_fields: fields} do
      ticker = fields["ticker"]

      # Resolved keys
      assert "ask" in ticker
      assert "mark_price" in ticker
      # Honesty Rule: 'average'/'previous_close' are canonical keys present even
      # though no in-scope exchange statically resolves a coercion for them.
      assert "average" in ticker
      assert "previous_close" in ticker
    end

    test "canonical_fields/1 applies by-design naming divergences", %{direct_fields: fields} do
      trade = fields["trade"]
      assert "order_id" in trade
      refute "order" in trade
      assert FieldMaps.divergences("trade") == %{"order" => "order_id"}
    end

    test "canonical_fields/1 yields [] for the array-shaped ohlcv slot", %{direct_fields: fields} do
      assert fields["ohlcv"] == []
    end

    test "canonical_fields/1 yields [] for the array-shaped volatility_history slot", %{direct_fields: fields} do
      assert fields["volatility_history"] == []
      assert FieldMaps.struct_for("volatility_history") == Bourse.VolatilityHistory
    end

    test "divergences_for_struct/1 maps a struct module to its renames" do
      assert FieldMaps.divergences_for_struct(Bourse.Trade) == %{"order" => "order_id"}
      assert FieldMaps.divergences_for_struct(Bourse.Ticker) == %{}
      assert FieldMaps.divergences_for_struct(String) == %{}
    end

    test "struct_for/1 governs the open_interest Tier-2 slot" do
      assert FieldMaps.struct_for("open_interest") == Bourse.OpenInterest
      assert FieldMaps.divergences_for_struct(Bourse.OpenInterest) == %{}
    end

    test "struct_for/1 governs the funding_rate, greeks, and option Tier-2/3 slots" do
      assert FieldMaps.struct_for("funding_rate") == Bourse.FundingRate
      assert FieldMaps.struct_for("greeks") == Bourse.Greeks
      assert FieldMaps.struct_for("option") == Bourse.OptionData
    end
  end

  describe "drift guard: hand-authored structs vs derived canonical field set" do
    # Task 55 contract: the spec governs the field set. A struct must be a
    # superset of its derived canonical keys; a new upstream key with no struct
    # field fails here instead of being silently dropped by ResponseParser.
    for parse_type <- FieldMaps.parse_types() do
      @parse_type parse_type

      test "#{parse_type} struct covers every derived canonical key", %{canonical_field_sets: field_sets} do
        module = FieldMaps.struct_for(@parse_type)
        canonical = MapSet.new(field_sets[@parse_type])
        fields = struct_fields(module)

        missing = MapSet.difference(canonical, fields)

        assert MapSet.size(missing) == 0,
               "#{inspect(module)} is missing canonical field(s): #{inspect(MapSet.to_list(missing))}"
      end

      test "#{parse_type} JSONSpec schema keys match the struct fields" do
        module = FieldMaps.struct_for(@parse_type)
        assert schema_keys(module) == struct_fields(module)
      end
    end
  end

  describe "spec-governed additive reconciliation (Task 55)" do
    test "Market carries the canonical created/percentage/tier_based keys" do
      fields = struct_fields(Bourse.Market)
      assert "created" in fields
      assert "percentage" in fields
      assert "tier_based" in fields
    end

    test "Order carries the canonical fees breakdown alongside fee" do
      fields = struct_fields(Bourse.Order)
      assert "fee" in fields
      assert "fees" in fields
    end

    test "Balance carries the canonical debt per-currency map" do
      assert "debt" in struct_fields(Bourse.Balance)
      assert %Bourse.Balance{}.debt == %{}
    end
  end

  defp canonical_field_sets(specs) do
    raw_keys_by_type = Enum.reduce(specs, %{}, &merge_field_map_keys/2)

    Map.new(FieldMaps.parse_types(), fn parse_type ->
      renames = FieldMaps.divergences(parse_type)

      fields =
        raw_keys_by_type
        |> Map.get(parse_type, [])
        |> Enum.map(&Macro.underscore/1)
        |> Enum.map(&Map.get(renames, &1, &1))
        |> Enum.uniq()
        |> Enum.sort()

      {parse_type, fields}
    end)
  end

  defp merge_field_map_keys(spec, acc) do
    case get_in(spec, ["normalization", "field_maps"]) do
      field_maps when is_map(field_maps) -> Enum.reduce(field_maps, acc, &merge_slot_keys/2)
      _other -> acc
    end
  end

  defp merge_slot_keys({parse_type, %{"field_map" => field_map}}, acc) when is_map(field_map) do
    Map.update(acc, parse_type, Map.keys(field_map), &(Map.keys(field_map) ++ &1))
  end

  defp merge_slot_keys({_parse_type, _slot}, acc), do: acc
end
