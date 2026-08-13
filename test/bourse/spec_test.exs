defmodule Bourse.SpecTest do
  use ExUnit.Case, async: true

  alias Bourse.ReferenceSlice
  alias Bourse.Spec.Schema

  describe "load!/1" do
    test "loads and decodes bybit spec" do
      spec = Bourse.Spec.load!("bybit")
      assert spec["exchange"]["id"] == "bybit"
      assert spec["exchange"]["name"] == "Bybit"
    end

    test "returns map with expected top-level keys" do
      spec = Bourse.Spec.load!("bybit")

      expected_keys = [
        "authored",
        "auth",
        "capabilities",
        "config",
        "emulated_methods",
        "endpoints",
        "errors",
        "exchange",
        "fees",
        "frozen",
        "hand_owned",
        "markets",
        "normalization",
        "oracles",
        "rate_limits",
        "raw",
        "schema_version",
        "testnet",
        "urls",
        "websocket"
      ]

      assert Enum.sort(Map.keys(spec)) == Enum.sort(expected_keys)
    end

    test "strips method_inventory from raw (v4 heavy AST)" do
      spec = Bourse.Spec.load!("bybit")
      refute Map.has_key?(spec["raw"], "method_inventory")
    end

    test "strips interfaces from endpoints (v4)" do
      spec = Bourse.Spec.load!("bybit")
      refute Map.has_key?(spec["endpoints"], "interfaces")
    end

    test "drops extraction-only fields with no consumers" do
      spec = Bourse.Spec.load!("bybit")

      refute Map.has_key?(spec, "_provenance")
      refute Map.has_key?(spec, "_divergence_notes")
      refute Map.has_key?(spec, "ccxt_version")
      refute Map.has_key?(spec, "extracted_at")
      refute Map.has_key?(spec, "oracle_provenance")
      refute Map.has_key?(spec["auth"], "headers")
      refute Map.has_key?(spec["auth"], "sign_method")
      refute Map.has_key?(spec["raw"], "class_info")
      refute Map.has_key?(spec["raw"], "overrides_meta")
      refute Map.has_key?(spec["normalization"], "parse_methods_digest")
      refute Map.has_key?(spec["markets"], "precision_mode")
      refute Map.has_key?(spec["markets"], "symbols_index")

      refute Map.has_key?(spec["errors"]["handle_errors"], "method")
      refute Map.has_key?(spec["errors"]["handle_errors"], "throw_dispatches")
    end

    test "preserves raw.describe with API endpoints (v4)" do
      spec = Bourse.Spec.load!("bybit")
      describe = spec["raw"]["describe"]
      assert is_map(describe["api"])
      assert is_map(describe["has"])
      assert is_map(describe["exceptions"])
    end

    test "loads a small exchange (deribit)" do
      spec = Bourse.Spec.load!("deribit")
      assert spec["exchange"]["id"] == "deribit"
    end

    test "rejects a reference-only exchange" do
      assert_raise ArgumentError, ~r/unsupported exchange: "kraken"/, fn ->
        Bourse.Spec.load!("kraken")
      end

      assert_raise ArgumentError, ~r/unsupported exchange/, fn ->
        Bourse.Spec.load!("nonexistent_exchange_xyz")
      end
    end

    test "rejects path traversal attempts" do
      assert_raise ArgumentError, ~r/invalid exchange ID/, fn ->
        Bourse.Spec.load!("../mix")
      end
    end

    test "rejects exchange IDs with slashes" do
      assert_raise ArgumentError, ~r/invalid exchange ID/, fn ->
        Bourse.Spec.load!("foo/bar")
      end
    end

    test "rejects exchange IDs with uppercase" do
      assert_raise ArgumentError, ~r/invalid exchange ID/, fn ->
        Bourse.Spec.load!("Bybit")
      end
    end

    test "loads the complete owned document" do
      spec = Bourse.Spec.load!("bybit")
      assert spec["authored"] == true
      assert is_map(spec["auth"]["sign_recipe"])
      assert is_map(spec["normalization"]["field_maps"])
      assert is_map(spec["normalization"]["response_envelopes"])
      assert is_map(spec["markets"]["patterns"])
      assert is_list(spec["errors"]["handle_errors"]["error_code_fields"])
    end

    test "all first-class venues load exactly one independently valid owned document" do
      for exchange_id <- Bourse.Spec.exchanges() do
        owned_path = Bourse.Spec.owned_spec_path(exchange_id)
        reference_path = ReferenceSlice.spec_path(exchange_id)
        owned = Bourse.Spec.decode_file!(owned_path)

        assert Bourse.Spec.spec_path(exchange_id) == owned_path
        refute owned_path == reference_path
        assert Bourse.Spec.validate_schema!(owned, exchange_id) == owned
        assert Bourse.Spec.load!(exchange_id) == owned
      end
    end

    test "vendored reference slice records its storage decision and is locally complete" do
      manifest = ReferenceSlice.load_manifest!()

      assert %{
               "mode" => "vendored",
               "reference_documents" => reference_reason,
               "manifest" => manifest_reason,
               "cross_repository_revision_pin" => "pins.source.sha256"
             } = manifest["vendoring_decision"]

      assert reference_reason != ""
      assert manifest_reason != ""

      for exchange_id <- manifest["exchanges"] do
        assert File.regular?(ReferenceSlice.spec_path(exchange_id))
      end
    end

    test "every owned document declares the static public fee trigger explicitly (task 499)" do
      for exchange_id <- Bourse.Spec.exchanges() do
        owned = exchange_id |> Bourse.Spec.owned_spec_path() |> Bourse.Spec.decode_file!()

        assert is_boolean(owned["fees"]["static_market_fees"]),
               "#{exchange_id} must author fees.static_market_fees; it is never defaulted"
      end

      # Omitting the slot is an authoring gap, not an implicit "no" — a new
      # first-class venue cannot silently inherit either behaviour.
      gapped =
        "bybit"
        |> Bourse.Spec.owned_spec_path()
        |> Bourse.Spec.decode_file!()
        |> update_in(["fees"], &Map.delete(&1, "static_market_fees"))

      assert_raise ArgumentError, ~r/fees\.static_market_fees.*missing required slot/, fn ->
        Schema.validate!(gapped, "bybit")
      end

      assert_raise ArgumentError, ~r/fees\.static_market_fees.*expected boolean/, fn ->
        Schema.validate!(put_in(gapped, ["fees", "static_market_fees"], "true"), "bybit")
      end
    end

    test "Alpaca runtime loading never consults the frozen CCXT reference" do
      owned_path = Bourse.Spec.owned_spec_path("alpaca")
      owned = Bourse.Spec.decode_file!(owned_path)

      assert Bourse.Spec.spec_path("alpaca") == owned_path
      assert Bourse.Spec.load!("alpaca") == owned
      refute ReferenceSlice.spec_path("alpaca") == owned_path
      refute Map.has_key?(owned["raw"]["describe"]["api"], "broker")
      refute Map.has_key?(owned["raw"]["describe"]["urls"]["api"], "broker")
    end

    test "first-class GET array dialects are explicit or not applicable" do
      deribit = "deribit" |> Bourse.Spec.owned_spec_path() |> Bourse.Spec.decode_file!()

      assert get_in(deribit, ["auth", "sign_recipe", "private", "query_encoder"]) == "urlencode"

      binance_recipes =
        "binance"
        |> Bourse.Spec.owned_spec_path()
        |> Bourse.Spec.decode_file!()
        |> get_in(["auth", "sign_recipe"])

      encoders =
        binance_recipes
        |> Map.values()
        |> MapSet.new(&get_in(&1, ["canonical_string", "*", "components", Access.at(0), "encoder"]))

      assert encoders == MapSet.new(["urlencodeCommaSeparatedArray", "urlencodeJsonArray"])

      [dust_component, default_component] = get_in(binance_recipes, ["sapi", "canonical_string", "*", "components"])
      assert dust_component["path_equals"] == "/asset/dust"
      assert default_component["unless_path_equals"] == "/asset/dust"

      binanceusdm_encoders =
        "binanceusdm"
        |> Bourse.Spec.owned_spec_path()
        |> Bourse.Spec.decode_file!()
        |> get_in(["auth", "sign_recipe"])
        |> Map.values()
        |> MapSet.new(&get_in(&1, ["canonical_string", "*", "components", Access.at(0), "encoder"]))

      assert binanceusdm_encoders == MapSet.new(["urlencodeJsonArray"])
    end

    test "derive is hand-owned and its authored contract is active" do
      slice = "derive" |> Bourse.Spec.authored_spec_path() |> File.read!() |> Jason.decode!()

      assert slice["authored"] == true
      assert slice["hand_owned"] == true
      assert slice["frozen"] == true
      assert :ok = Bourse.Spec.validate_authored_contract!(slice, "derive")

      invalid = put_in(slice, ["auth", "sign_recipe"], %{})

      assert_raise RuntimeError, ~r/spec "derive".*auth\.sign_recipe.*non-empty map/, fn ->
        Bourse.Spec.validate_authored_contract!(invalid, "derive")
      end
    end

    test "deribit is hand-owned and its authored contract is active" do
      slice = "deribit" |> Bourse.Spec.authored_spec_path() |> File.read!() |> Jason.decode!()

      assert slice["authored"] == true
      assert slice["hand_owned"] == true
      assert slice["frozen"] == true
      # Descriptors carry documentation only (`signature`, `returns`, `params_doc`);
      # `source` is a request-binding key and never belongs here. A leaked CCXT JS
      # signature string used to sit in this slot — assert the slot stays absent.
      refute Map.has_key?(get_in(slice, ["endpoints", "descriptors", "fetchVolatilityHistory"]), "source")
      assert :ok = Bourse.Spec.validate_authored_contract!(slice, "deribit")

      invalid = put_in(slice, ["normalization", "field_maps"], %{})

      assert_raise RuntimeError, ~r/spec "deribit".*normalization\.field_maps.*non-empty map/, fn ->
        Bourse.Spec.validate_authored_contract!(invalid, "deribit")
      end
    end

    test "bybit is hand-owned and its authored contract is active" do
      slice = "bybit" |> Bourse.Spec.authored_spec_path() |> File.read!() |> Jason.decode!()

      assert slice["authored"] == true
      assert slice["hand_owned"] == true
      assert slice["frozen"] == true
      assert :ok = Bourse.Spec.validate_authored_contract!(slice, "bybit")

      invalid = put_in(slice, ["normalization", "response_envelopes"], %{})

      assert_raise RuntimeError, ~r/spec "bybit".*normalization\.response_envelopes.*non-empty map/, fn ->
        Bourse.Spec.validate_authored_contract!(invalid, "bybit")
      end
    end

    test "okx is hand-owned and its authored contract is active" do
      slice = "okx" |> Bourse.Spec.authored_spec_path() |> File.read!() |> Jason.decode!()

      assert slice["authored"] == true
      assert slice["hand_owned"] == true
      assert slice["frozen"] == true
      assert :ok = Bourse.Spec.validate_authored_contract!(slice, "okx")

      invalid = put_in(slice, ["normalization", "field_maps"], %{})

      assert_raise RuntimeError, ~r/spec "okx".*normalization\.field_maps.*non-empty map/, fn ->
        Bourse.Spec.validate_authored_contract!(invalid, "okx")
      end
    end

    test "okx interpretive request defaults live only in the owned runtime document" do
      reference =
        "okx"
        |> ReferenceSlice.spec_path()
        |> Bourse.Spec.decode_file!()

      reference_defaults = get_in(reference, ["endpoints", "request", "defaults"])

      # The vendored full spec carries only distill's unresolved stubs, so a
      # re-vendor of the catalog alone cannot wipe the authored renames.
      for {method, param} <- [
            {"fetchLeverage", "mgnMode"},
            {"fetchBorrowInterest", "mgnMode"},
            {"fetchMarketLeverageTiers", "tdMode"},
            {"transfer", "amt"},
            {"transfer", "ccy"},
            {"transfer", "from"},
            {"transfer", "to"}
          ] do
        assert get_in(reference_defaults, [method, param, "kind"]) == "unresolved",
               "#{method}.#{param} carries interpretive judgment in the vendored full spec; " <>
                 "it belongs in authored/okx.json"
      end

      owned = "okx" |> Bourse.Spec.owned_spec_path() |> Bourse.Spec.decode_file!()
      assert get_in(owned, ["endpoints", "request", "defaults", "transfer", "ccy", "source"]) == "code"
    end

    test "okx request defaults load from the owned document" do
      defaults = get_in(Bourse.Spec.load!("okx"), ["endpoints", "request", "defaults"])

      assert get_in(defaults, ["fetchLeverage", "mgnMode", "kind"]) == "literal"
      assert get_in(defaults, ["fetchLeverage", "mgnMode", "value"]) == "cross"

      # OKX treats mgnMode/tdMode as optional filters on these reads (live: omitting
      # mgnMode on interest-accrued answers code 0); CCXT-JS defaults both to "cross".
      assert get_in(defaults, ["fetchBorrowInterest", "mgnMode", "value"]) == "cross"
      assert get_in(defaults, ["fetchMarketLeverageTiers", "tdMode", "value"]) == "cross"

      for {param, source} <- [
            {"amt", "amount"},
            {"ccy", "code"},
            {"from", "from_account"},
            {"to", "to_account"}
          ] do
        assert defaults |> get_in(["transfer", param]) |> Map.take(["kind", "source"]) == %{
                 "kind" => "reference",
                 "source" => source
               }
      end

      assert get_in(defaults, ["transfer", "type", "value"]) == "0"

      # Params the authored slice deliberately leaves to RequestShape.OKX stay unresolved.
      assert get_in(defaults, ["fetchLeverage", "instId", "kind"]) == "unresolved"
    end

    test "hyperliquid is hand-owned and its authored contract is active" do
      slice = "hyperliquid" |> Bourse.Spec.authored_spec_path() |> File.read!() |> Jason.decode!()

      assert slice["authored"] == true
      assert slice["hand_owned"] == true
      assert slice["frozen"] == true
      assert :ok = Bourse.Spec.validate_authored_contract!(slice, "hyperliquid")

      invalid = put_in(slice, ["normalization", "field_maps"], %{})

      assert_raise RuntimeError, ~r/spec "hyperliquid".*normalization\.field_maps.*non-empty map/, fn ->
        Bourse.Spec.validate_authored_contract!(invalid, "hyperliquid")
      end
    end

    test "Binance family is hand-owned and each authored contract is active" do
      for exchange_id <- ["binance", "binanceusdm"] do
        slice = exchange_id |> Bourse.Spec.authored_spec_path() |> File.read!() |> Jason.decode!()

        assert slice["authored"] == true
        assert slice["hand_owned"] == true
        assert slice["frozen"] == true
        assert :ok = Bourse.Spec.validate_authored_contract!(slice, exchange_id)

        invalid = put_in(slice, ["normalization", "field_maps"], %{})

        assert_raise RuntimeError, ~r/normalization\.field_maps.*non-empty map/, fn ->
          Bourse.Spec.validate_authored_contract!(invalid, exchange_id)
        end
      end
    end

    test "reference-only venues have no runtime path" do
      assert_raise ArgumentError, ~r/unsupported exchange: "kraken"/, fn ->
        Bourse.Spec.spec_path("kraken")
      end

      assert File.exists?(ReferenceSlice.spec_path("kraken"))
      assert Bourse.Spec.owned_spec_path("kraken") == nil
      assert Bourse.Spec.authored_spec_path("kraken") == nil
    end
  end

  describe "JSON document validation" do
    @duplicate_fixture_dir Path.expand("../fixtures/spec", __DIR__)

    test "rejects a duplicate top-level key with its file and object path" do
      path = Path.join(@duplicate_fixture_dir, "duplicate_top_level.json")

      error = assert_raise ArgumentError, fn -> Bourse.Spec.decode_file!(path) end

      assert error.message =~ path
      assert error.message =~ ~s(duplicate key "endpoints")
      assert error.message =~ "object path $"
    end

    test "rejects a nested duplicate key with its file and object path" do
      path = Path.join(@duplicate_fixture_dir, "duplicate_nested.json")

      error = assert_raise ArgumentError, fn -> Bourse.Spec.decode_file!(path) end

      assert error.message =~ path
      assert error.message =~ ~s(duplicate key "source")
      assert error.message =~ "object path $.endpoints.request"
    end

    test "detects a duplicate key nested inside an array element" do
      path = Path.join(System.tmp_dir!(), "dup-in-array-#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"endpoints":[{"ok":1},{"source":"params","source":"code"}]}))
      on_exit(fn -> File.rm(path) end)

      error = assert_raise ArgumentError, fn -> Bourse.Spec.decode_file!(path) end

      assert error.message =~ ~s(duplicate key "source")
      assert error.message =~ "object path $.endpoints[1]"
    end

    test "leaves malformed JSON to Jason so the decode error keeps its position" do
      path = Path.join(System.tmp_dir!(), "malformed-#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"endpoints": }))
      on_exit(fn -> File.rm(path) end)

      # The duplicate-key pass re-parses with `:json`, which reports malformed
      # input as an opaque `{:invalid_byte, _}` — it must not mask this.
      assert_raise Jason.DecodeError, fn -> Bourse.Spec.decode_file!(path) end
    end

    test "validates every runtime document and the separate reference corpus" do
      assert :ok = Bourse.Spec.validate_all_documents!()
      assert :ok = ReferenceSlice.validate_all_documents!()
    end

    test "runtime validation excludes non-venue authored reference assets" do
      runtime_files = Enum.map(Bourse.Spec.exchanges(), &Path.basename(Bourse.Spec.owned_spec_path(&1)))

      assert Enum.sort(runtime_files) ==
               ~w(alpaca.json binance.json binancecoinm.json binanceusdm.json bybit.json coinbaseexchange.json deribit.json derive.json hyperliquid.json lighter.json okx.json)
    end
  end

  describe "validate_schema!/2 (exercised via in-memory maps — no filesystem)" do
    test "real spec carries the owned local schema version" do
      assert Bourse.Spec.load!("bybit")["schema_version"] == Bourse.Spec.schema_version()
    end

    test "accepts a complete owned spec" do
      spec = owned_spec("bybit")
      assert Bourse.Spec.validate_schema!(spec, "bybit") == spec
    end

    test "rejects a different schema version" do
      spec = %{"schema_version" => 4}

      assert_raise RuntimeError, ~r/spec "fake".*unsupported schema_version.*4.*expected 3/, fn ->
        Bourse.Spec.validate_schema!(spec, "fake")
      end
    end

    test "rejects empty map" do
      assert_raise RuntimeError, ~r/spec "fake" missing schema_version/, fn ->
        Bourse.Spec.validate_schema!(%{}, "fake")
      end
    end
  end

  describe "owned runtime schema" do
    test "every first-class venue loads its complete owned document" do
      for venue <- Bourse.Spec.exchanges() do
        spec = Bourse.Spec.load!(venue)

        assert spec["schema_version"] == Bourse.Spec.schema_version()
        assert spec["authored"] == true
        assert spec["exchange"]["id"] == venue
        assert Bourse.Spec.spec_path(venue) == Bourse.Spec.owned_spec_path(venue)
      end
    end

    test "an owned document that drops the ownership marker fails as a named gap" do
      # The gate must key on the owned path, not on the flag the document declares
      # about itself — otherwise a truncated document silently loads unvalidated.
      spec = "bybit" |> owned_spec() |> Map.delete("authored")

      assert_raise ArgumentError, ~r/owned spec "bybit" gap ownership/, fn ->
        Schema.validate!(spec, "bybit")
      end

      refute match?(%{"authored" => true}, spec)
    end

    test "names missing, null and empty required semantic gaps" do
      spec = owned_spec("bybit")

      missing = update_in(spec, ["websocket"], &Map.delete(&1, "urls"))

      assert_raise ArgumentError, ~r/owned spec "bybit" gap websocket\.urls: missing required slot/, fn ->
        Bourse.Spec.validate_schema!(missing, "bybit")
      end

      null = put_in(spec, ["websocket", "urls"], nil)

      assert_raise ArgumentError, ~r/owned spec "bybit" gap websocket\.urls: required slot is null/, fn ->
        Bourse.Spec.validate_schema!(null, "bybit")
      end

      empty = put_in(spec, ["auth", "sign_recipe"], %{})

      assert_raise ArgumentError, ~r/owned spec "bybit" gap auth\.sign_recipe: expected non_empty_map/, fn ->
        Bourse.Spec.validate_schema!(empty, "bybit")
      end

      assert Bourse.Spec.validate_schema!(put_in(spec, ["config"], %{}), "bybit")["config"] == %{}
    end

    test "exception_scopes must biject with scoped exception sub-maps" do
      undeclared_submap =
        "bybit"
        |> owned_spec()
        |> put_in(["errors", "handle_errors", "exception_scopes"], %{"public" => "spot"})

      assert_raise ArgumentError,
                   ~r/owned spec "bybit" gap errors\.handle_errors\.exception_scopes: declares scope "spot" with no exception sub-map/,
                   fn -> Schema.validate!(undeclared_submap, "bybit") end

      unrouted_submap =
        update_in(owned_spec("binancecoinm"), ["errors", "handle_errors", "exception_scopes"], fn scopes ->
          Map.reject(scopes, fn {_section, scope} -> scope == "inverse" end)
        end)

      assert_raise ArgumentError,
                   ~r/owned spec "binancecoinm" gap errors\.handle_errors\.exception_scopes: scoped exception sub-map "inverse" has no declaration routing to it/,
                   fn -> Schema.validate!(unrouted_submap, "binancecoinm") end

      missing =
        "bybit"
        |> owned_spec()
        |> update_in(["errors", "handle_errors"], &Map.delete(&1, "exception_scopes"))

      assert_raise ArgumentError,
                   ~r/owned spec "bybit" gap errors\.handle_errors\.exception_scopes: missing required slot/,
                   fn -> Schema.validate!(missing, "bybit") end
    end

    test "exception_scopes name every real API section and reject unknown sections" do
      missing_route =
        update_in(owned_spec("binancecoinm"), ["errors", "handle_errors", "exception_scopes"], fn scopes ->
          Map.delete(scopes, "dapiPrivate")
        end)

      assert_raise ArgumentError,
                   ~r/owned spec "binancecoinm" gap errors\.handle_errors\.exception_scopes\.dapiPrivate: API section has no exception-scope declaration/,
                   fn -> Schema.validate!(missing_route, "binancecoinm") end

      unknown_route =
        put_in(
          owned_spec("binancecoinm"),
          ["errors", "handle_errors", "exception_scopes", "unknownPrivate"],
          "inverse"
        )

      assert_raise ArgumentError,
                   ~r/owned spec "binancecoinm" gap errors\.handle_errors\.exception_scopes\.unknownPrivate: declares an API section with no base URL/,
                   fn -> Schema.validate!(unknown_route, "binancecoinm") end

      conflicting_route =
        put_in(
          owned_spec("binancecoinm"),
          ["errors", "handle_errors", "exception_scopes", "dapiPrivate"],
          "linear"
        )

      assert_raise ArgumentError,
                   ~r/owned spec "binancecoinm" gap errors\.handle_errors\.exception_scopes: base URL "https:\/\/dapi\.binance\.com\/dapi\/v1" routes to conflicting scopes \["inverse", "linear"\]/,
                   fn -> Schema.validate!(conflicting_route, "binancecoinm") end
    end

    test "requires a complete authored oracle profile with reasons for every declined oracle" do
      spec = owned_spec("alpaca")

      assert_raise ArgumentError, ~r/owned spec "alpaca" gap oracles: missing required slot/, fn ->
        Schema.validate!(Map.delete(spec, "oracles"), "alpaca")
      end

      missing_reason = put_in(spec, ["oracles", "private_real_recordings"], %{"grades" => false})

      assert_raise ArgumentError,
                   ~r/oracles\.private_real_recordings.*grades=false with a non-empty reason/,
                   fn -> Schema.validate!(missing_reason, "alpaca") end

      invalid_grade = put_in(spec, ["oracles", "live_tier1"], %{"grades" => "yes"})

      assert_raise ArgumentError, ~r/oracles\.live_tier1.*expected grades=true/, fn ->
        Schema.validate!(invalid_grade, "alpaca")
      end
    end

    test "every supported venue declares at least one grading oracle" do
      for venue <- Bourse.Spec.exchanges() do
        profile = Bourse.Spec.load!(venue)["oracles"]

        assert Enum.sort(Map.keys(profile)) == Schema.oracle_names()

        assert Enum.any?(profile, fn {_oracle, declaration} -> declaration["grades"] end),
               "#{venue} declares zero grading oracles"

        for {oracle, %{"grades" => false} = declaration} <- profile do
          assert is_binary(declaration["reason"]) and declaration["reason"] != "",
                 "#{venue} declines #{oracle} without a reason"
        end
      end
    end

    test "oracle venue sets come only from authored profiles" do
      assert Bourse.Spec.oracle_venues(:private_real_recordings) ==
               ~w(binance binanceusdm bybit deribit derive hyperliquid okx)

      assert Bourse.Spec.oracle_venues(:live_tier1) == Bourse.Spec.exchanges()

      assert_raise ArgumentError, ~r/unknown oracle: "training"/, fn ->
        Bourse.Spec.oracle_venues("training")
      end
    end

    test "forbids extraction payloads and test-only market indexes" do
      spec = owned_spec("deribit")

      for {path, label} <- [
            {~w(oracle_provenance), "oracle_provenance"},
            {~w(raw method_inventory), "raw.method_inventory"},
            {~w(markets symbols_index), "markets.symbols_index"}
          ] do
        invalid = put_in(spec, path, %{})

        assert_raise ArgumentError, ~r/#{Regex.escape(label)}.*forbidden/, fn ->
          Bourse.Spec.validate_schema!(invalid, "deribit")
        end
      end
    end

    test "requires explicit support declarations for every unified mapping" do
      spec = owned_spec("okx")
      method = spec["endpoints"]["unified"] |> Map.keys() |> Enum.sort() |> hd()
      missing = update_in(spec, ["capabilities", "has"], &Map.delete(&1, method))

      assert_raise ArgumentError, ~r/capabilities\.has\..*missing support declaration/, fn ->
        Bourse.Spec.validate_schema!(missing, "okx")
      end

      unresolved = put_in(spec, ["capabilities", "has", method], "unresolved")

      assert_raise ArgumentError, ~r/expected true, false or "emulated"/, fn ->
        Bourse.Spec.validate_schema!(unresolved, "okx")
      end
    end

    test "order status requires a closed enum map or an explicit passthrough" do
      deribit = owned_spec("deribit")
      status_path = ["normalization", "field_maps", "order", "field_map", "status"]

      missing_policy =
        put_in(deribit, status_path, %{"key" => "order_state", "coercion" => "safeString"})

      assert_raise ArgumentError, ~r/order\.status.*enum_map or explicit enum_passthrough=true/, fn ->
        Schema.validate!(missing_policy, "deribit")
      end

      silent_default =
        update_in(deribit, status_path, &Map.put(&1, "enum_default", nil))

      assert_raise ArgumentError, ~r/order\.status\.enum_default.*fail loudly/, fn ->
        Schema.validate!(silent_default, "deribit")
      end

      assert Schema.validate!(
               put_in(missing_policy, status_path, %{
                 "key" => "order_state",
                 "coercion" => "safeString",
                 "enum_passthrough" => true
               }),
               "deribit"
             )
    end

    test "ledger type rejects a silent enum default" do
      binance = owned_spec("binance")
      type_path = ["normalization", "field_maps", "ledger_entry", "field_map", "type"]
      silent_default = update_in(binance, type_path, &Map.put(&1, "enum_default", nil))

      assert_raise ArgumentError, ~r/ledger_entry\.type\.enum_default.*fail loudly/, fn ->
        Schema.validate!(silent_default, "binance")
      end

      route_type_path = ["normalization", "field_maps", "ledger_entry", "route_field_maps", "bill", "type"]
      silent_route_default = update_in(binance, route_type_path, &Map.put(&1, "enum_default", nil))

      # The gap must name the ROUTE slot, not the (clean) base type slot.
      assert_raise ArgumentError, ~r/ledger_entry\.route_field_maps\.bill\.type\.enum_default.*silently default/, fn ->
        Schema.validate!(silent_route_default, "binance")
      end
    end

    test "every authored order-status rule declares its unknown-value policy" do
      for venue <-
            ~w(alpaca binance binancecoinm binanceusdm bybit coinbaseexchange deribit derive hyperliquid lighter okx) do
        assert Schema.validate!(owned_spec(venue), venue)
      end
    end

    test "an explicit unsupported declaration cannot generate a unified route" do
      spec = owned_spec("hyperliquid")
      endpoints = Bourse.Exchange.build_endpoint_configs(spec["raw"]["describe"]["api"])
      mapping = Bourse.Exchange.build_unified_method_mapping(spec, endpoints)

      assert spec["capabilities"]["has"]["fetchTrades"] == false
      refute Map.has_key?(mapping, :fetch_trades)
    end

    test "preserves typed literals, references and meaningful null values" do
      okx = owned_spec("okx")
      hyperliquid = owned_spec("hyperliquid")

      assert get_in(okx, ["endpoints", "request", "defaults", "addMargin", "type"]) == %{
               "kind" => "literal",
               "value" => "add"
             }

      assert get_in(okx, ["endpoints", "request", "defaults", "addMargin", "amt"]) == %{
               "kind" => "reference",
               "source" => "amount",
               "source_class" => "unified_param"
             }

      assert get_in(hyperliquid, [
               "endpoints",
               "request",
               "defaults",
               "approveBuilderFee",
               "vaultAddress"
             ]) == %{"kind" => "literal", "reason" => nil, "value" => nil}
    end
  end

  describe "validate_authored_contract!/2" do
    test "does not enforce authored slots before a venue is marked authored" do
      assert :ok = Bourse.Spec.validate_authored_contract!(%{"authored" => false}, "bybit")
      assert :ok = Bourse.Spec.validate_authored_contract!(%{}, "bybit")
    end

    test "accepts a complete authored slice" do
      assert :ok = Bourse.Spec.validate_authored_contract!(complete_authored_spec(), "bybit")
    end

    test "accepts an explicit public-only auth contract" do
      spec =
        complete_authored_spec()
        |> put_in(["auth", "authenticated_sections"], [])
        |> put_in(["auth", "signing_config"], %{})
        |> put_in(["auth", "signing_pattern"], nil)
        |> put_in(["auth", "sign_recipe"], %{})

      assert :ok = Bourse.Spec.validate_authored_contract!(spec, "bybit")
    end

    test "rejects a partial public-only auth contract" do
      spec =
        complete_authored_spec()
        |> put_in(["auth", "authenticated_sections"], [])
        |> put_in(["auth", "signing_config"], %{})
        |> put_in(["auth", "signing_pattern"], nil)

      assert_raise RuntimeError, ~r/public-only auth contract/, fn ->
        Bourse.Spec.validate_authored_contract!(spec, "bybit")
      end
    end

    test "names the venue and every missing authored slot" do
      slots = [
        {~w(auth sign_recipe), "auth.sign_recipe"},
        {~w(normalization field_maps), "normalization.field_maps"},
        {~w(normalization response_envelopes), "normalization.response_envelopes"},
        {~w(markets patterns), "markets.patterns"},
        {~w(errors handle_errors error_code_fields), "errors.handle_errors.error_code_fields"}
      ]

      for {path, label} <- slots do
        spec = put_in(complete_authored_spec(), path, nil)

        error =
          assert_raise RuntimeError, fn ->
            Bourse.Spec.validate_authored_contract!(spec, "bybit")
          end

        assert error.message =~ ~s(spec "bybit")
        assert error.message =~ label
      end
    end

    test "rejects a malformed error field list" do
      spec = put_in(complete_authored_spec(), ["errors", "handle_errors", "error_code_fields"], %{})

      assert_raise RuntimeError, ~r/spec "okx".*errors\.handle_errors\.error_code_fields.*non-empty list/, fn ->
        Bourse.Spec.validate_authored_contract!(spec, "okx")
      end
    end

    test "requires authored request sources to declare a source class" do
      spec =
        Map.put(complete_authored_spec(), "endpoints", %{
          "request" => %{"defaults" => %{"fetchTicker" => %{"symbol" => %{"source" => "symbol"}}}}
        })

      assert_raise ArgumentError, ~r/exchange bybit method fetchTicker source symbol/, fn ->
        Bourse.Spec.validate_authored_contract!(spec, "bybit")
      end
    end

    test "rejects unknown and mismatched authored request builders" do
      for {exchange_id, method, builder} <- [
            {"bybit", "fetchTicker", "unknown_builder"},
            {"bybit", "fetchTicker", "binance_batch_orders"},
            {"binance", "fetchTicker", "binance_batch_orders"}
          ] do
        spec =
          Map.put(complete_authored_spec(), "endpoints", %{
            "request" => %{"defaults" => %{method => %{"_builder" => builder}}}
          })

        error =
          assert_raise ArgumentError, fn ->
            Bourse.Spec.validate_authored_contract!(spec, exchange_id)
          end

        assert error.message =~ "exchange #{exchange_id}"
        assert error.message =~ "method #{method}"
        assert error.message =~ ~s(builder "#{builder}")
      end
    end

    test "validates request builders nested in endpoint overrides" do
      spec =
        Map.put(complete_authored_spec(), "endpoints", %{
          "request" => %{
            "defaults" => %{
              "endpoint_overrides" => %{
                "fetchTicker" => %{"ticker/price" => %{"_builder" => "missing_builder"}}
              }
            }
          }
        })

      assert_raise ArgumentError,
                   ~r/exchange binance method fetchTicker builder "missing_builder"/,
                   fn -> Bourse.Spec.validate_authored_contract!(spec, "binance") end
    end
  end

  describe "validate_manifest_schema!/1" do
    test "accepts valid manifest" do
      manifest = %{
        "kind" => "runtime_support",
        "schema_version" => Bourse.Spec.schema_version(),
        "venue_count" => 0,
        "venues" => []
      }

      assert Bourse.Spec.validate_manifest_schema!(manifest) == manifest
    end

    test "rejects manifest with another schema version" do
      manifest = %{"schema_version" => 4}

      assert_raise RuntimeError, ~r/manifest.*unsupported schema_version.*4.*expected 3/, fn ->
        Bourse.Spec.validate_manifest_schema!(manifest)
      end
    end

    test "rejects manifest missing schema_version" do
      assert_raise RuntimeError, ~r/invalid runtime-support manifest contract/, fn ->
        Bourse.Spec.validate_manifest_schema!(%{"venues" => []})
      end
    end
  end

  describe "load_manifest!/0" do
    test "returns manifest with exchange list" do
      manifest = Bourse.Spec.load_manifest!()
      assert is_list(manifest["venues"])
      assert manifest["schema_version"] == Bourse.Spec.schema_version()
    end

    test "manifest has expected keys" do
      manifest = Bourse.Spec.load_manifest!()
      assert Map.has_key?(manifest, "venues")
      assert Map.has_key?(manifest, "venue_count")
      assert manifest["kind"] == "runtime_support"
      assert Map.has_key?(manifest, "schema_version")
      refute Map.has_key?(manifest, "ccxt_version")
      refute Map.has_key?(manifest, "extracted_at")
      refute Map.has_key?(manifest, "source")
      refute Map.has_key?(manifest, "source_git_sha")
    end

    test "venue_count matches the exact supported inventory" do
      manifest = Bourse.Spec.load_manifest!()

      assert manifest["venue_count"] == length(manifest["venues"])

      assert manifest["venues"] ==
               ~w(alpaca binance binancecoinm binanceusdm bybit coinbaseexchange deribit derive hyperliquid lighter okx)
    end
  end

  describe "exchanges/0" do
    test "returns list of exchange ID strings" do
      exchanges = Bourse.Spec.exchanges()
      assert is_list(exchanges)
      assert Enum.all?(exchanges, &is_binary/1)
    end

    test "contains exactly the supported venues" do
      assert Bourse.Spec.exchanges() ==
               ~w(alpaca binance binancecoinm binanceusdm bybit coinbaseexchange deribit derive hyperliquid lighter okx)
    end

    test "list is sorted alphabetically" do
      exchanges = Bourse.Spec.exchanges()
      assert exchanges == Enum.sort(exchanges)
    end
  end

  describe "spec_path/1" do
    test "returns valid path for known exchange" do
      path = Bourse.Spec.spec_path("bybit")
      assert String.ends_with?(path, "authored/bybit.json")
    end

    test "path points to existing file" do
      path = Bourse.Spec.spec_path("bybit")
      assert File.exists?(path)
    end

    test "rejects path traversal" do
      assert_raise ArgumentError, ~r/invalid exchange ID/, fn ->
        Bourse.Spec.spec_path("../mix")
      end
    end
  end

  describe "authored_spec_path/1" do
    test "returns the complete owned path for first-class venues" do
      path = Bourse.Spec.authored_spec_path("bybit")
      assert String.ends_with?(path, "authored/bybit.json")
      assert File.exists?(path)
    end

    test "returns nil for a reference-only venue" do
      assert Bourse.Spec.authored_spec_path("kraken") == nil
    end
  end

  describe "manifest_path/0" do
    test "returns the runtime-support manifest path" do
      path = Bourse.Spec.manifest_path()
      assert String.ends_with?(path, "runtime_support.json")
    end

    test "path points to existing file" do
      path = Bourse.Spec.manifest_path()
      assert File.exists?(path)
    end
  end

  defp complete_authored_spec do
    %{
      "authored" => true,
      "auth" => %{"sign_recipe" => %{"private" => %{}}},
      "normalization" => %{
        "field_maps" => %{"ticker" => %{}},
        "response_envelopes" => %{"ticker" => %{}}
      },
      "markets" => %{"patterns" => %{"spot" => %{}}},
      "errors" => %{"handle_errors" => %{"error_code_fields" => [%{"field" => "code"}]}}
    }
  end

  defp owned_spec(exchange_id) do
    exchange_id
    |> Bourse.Spec.owned_spec_path()
    |> Bourse.Spec.decode_file!()
  end
end
