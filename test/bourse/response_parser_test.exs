defmodule Bourse.ResponseParserTest do
  use ExUnit.Case, async: true

  alias Bourse.Balance
  alias Bourse.Market
  alias Bourse.Order
  alias Bourse.Position
  alias Bourse.ResponseParser
  alias Bourse.Ticker
  alias Bourse.Trade
  alias Mix.Tasks.Ccxt.ReferenceCorpus

  setup_all do
    field_maps = runtime_field_maps()
    coercion_rules = runtime_coercion_rules(field_maps)

    {:ok,
     catalog_resolutions: catalog_resolutions(coercion_rules), coercion_rules: coercion_rules, field_maps: field_maps}
  end

  @ticker_mapping %{
    "symbol" => %{"key" => "symbol", "coercion" => "safeString"},
    "last" => %{"key" => "last", "coercion" => "safeNumber"},
    "timestamp" => %{"key" => "ts", "coercion" => "safeInteger"}
  }

  # Catalog-wide coercion contract (Task 393).
  #
  # `Bourse.ResponseParser.coerce/2` branches on `{coercion, format}` — the
  # *resolution* a field rule declares — so that pair is what these ledgers key
  # on. The sweep below walks every field rule in the merged runtime rule set
  # across all manifest ids and requires each resolution it finds to appear in
  # exactly one of the three ledgers. A resolution in none of them fails the
  # suite: that is the defect class task 376's five `"format": null`
  # safeTimestamp rules belonged to — a coercion tag whose runtime branch does
  # not exist, or whose guard does not match the shape the catalog emits.
  #
  # `{sample, expected, target, field}` — the source value a venue plausibly
  # sends for this resolution, and the exact value coerce/2 must produce.
  @coercion_samples %{
    {"decimalPlacesToTickSize", nil} => {"2", 0.01, Ticker, "last"},
    {"epochMsOrDatetime", "ms"} => {"1714923704000", 1_714_923_704_000, Ticker, "timestamp"},
    {"iso8601", nil} => {"1714923704000", "2024-05-05T15:41:44.000Z", Ticker, "datetime"},
    {"iso8601", "ms"} => {"1714923704000", "2024-05-05T15:41:44.000Z", Ticker, "datetime"},
    # Seconds epoch → ISO-8601 (deepcoin CreateTime / whitebit fundingTime).
    {"iso8601", "s"} => {"1714923704", "2024-05-05T15:41:44.000Z", Ticker, "datetime"},
    {"safeBool", :absent} => {"true", true, Market, "active"},
    {"safeBool", nil} => {"true", true, Market, "active"},
    {"safeCurrencyCode", :absent} => {"usdt", "USDT", Ticker, "symbol"},
    {"safeCurrencyCode", nil} => {"usdt", "USDT", Ticker, "symbol"},
    {"safeInteger", :absent} => {"1714923704000", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeInteger", nil} => {"1714923704000", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeInteger", "ms"} => {"1714923704000", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeInteger2", nil} => {"1714923704000", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeInteger2", "ms"} => {"1714923704000", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeNumber", :absent} => {"50000.5", 50_000.5, Ticker, "last"},
    {"safeNumber", nil} => {"50000.5", 50_000.5, Ticker, "last"},
    {"safeNumber2", :absent} => {"50000.5", 50_000.5, Ticker, "last"},
    {"safeNumber2", nil} => {"50000.5", 50_000.5, Ticker, "last"},
    {"safeNumberCanonical", :absent} => {"1.50", 1.5, Ticker, "last"},
    {"safeNumberCanonical", nil} => {"1.50", 1.5, Ticker, "last"},
    {"parseNumber(parsePrecision(safeString))", nil} => {"8", 1.0e-8, Ticker, "last"},
    {"parseNumber(safeString)", nil} => {"12.5", 12.5, Ticker, "last"},
    {"parseNumber(omitZero(safeString))", nil} => {"12.5", 12.5, Ticker, "last"},
    {"parse8601", :absent} => {"2024-05-05T15:41:44Z", 1_714_923_704_000, Ticker, "timestamp"},
    {"parse8601", nil} => {"2024-05-05T15:41:44Z", 1_714_923_704_000, Ticker, "timestamp"},
    {"parse8601", "iso8601"} => {"2024-05-05T15:41:44Z", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeString", :absent} => {"BTCUSDT", "BTCUSDT", Ticker, "symbol"},
    {"safeString", nil} => {"BTCUSDT", "BTCUSDT", Ticker, "symbol"},
    # `funding_interval` is consumed by a post-coercion format step, not by
    # coerce/2: bybit's bare hour count is rendered as an interval string.
    {"safeString", "funding_interval"} => {"8", "8h", Ticker, "symbol"},
    # A timestamp-ish format annotation on a string slot; nothing acts on it.
    {"safeString", "ms"} => {"1714923704000", "1714923704000", Ticker, "symbol"},
    {"safeString2", :absent} => {"BTCUSDT", "BTCUSDT", Ticker, "symbol"},
    {"safeString2", nil} => {"BTCUSDT", "BTCUSDT", Ticker, "symbol"},
    {"safeStringLower", :absent} => {"BUY", "buy", Ticker, "symbol"},
    {"safeStringLower", nil} => {"BUY", "buy", Ticker, "symbol"},
    {"safeStringLower2", nil} => {"BUY", "buy", Ticker, "symbol"},
    {"safeSymbol", nil} => {"BTCUSDT", "BTCUSDT", Ticker, "symbol"},
    {"safeIntegerOmitZero", "ms"} => {"1714923704000", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeIntegerProduct", "ms"} => {"1714923704", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeTimestamp", :absent} => {"1714923704", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeTimestamp", nil} => {"1714923704", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeTimestamp", "ms"} => {"1714923704000", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeTimestamp", "s"} => {"1714923704", 1_714_923_704_000, Ticker, "timestamp"},
    {"safeTimestamp2", "ms"} => {"1714923704", 1_714_923_704_000, Ticker, "timestamp"}
  }

  # Resolutions that reach a real branch and produce a value of the right shape,
  # but whose value is wrong. Shape is asserted; the exact value is not, so the
  # suite does not freeze the defect as expected behaviour. Empty after Task 413
  # moved the only entry (`{"iso8601", "s"}`) into @coercion_samples.
  @coercion_divergences %{}

  # These roots represent exchange-instance reads, not HTTP response fields:
  # `this.fees` and `this.options`. Add a root only after confirming the pinned
  # compatibility parser reads `this.<root>` rather than the response.
  @instance_state_roots %{"fees" => "this.fees", "options" => "this.options"}

  test "applies a field map and builds the target struct" do
    data = %{"symbol" => "BTCUSDT", "last" => "50000.5", "ts" => "123"}

    assert {:ok, %Ticker{} = ticker} = ResponseParser.apply_mappings(data, @ticker_mapping, target: Ticker)
    assert ticker.symbol == "BTCUSDT"
    assert ticker.last == 50_000.5
    assert ticker.timestamp == 123
  end

  test "market parsing does not attribute static fees to a response" do
    field_map =
      "binancecoinm"
      |> Bourse.Spec.load!()
      |> get_in(["normalization", "field_maps", "market", "field_map"])

    data = %{
      "baseAsset" => "BTC",
      "fees" => %{"trading" => %{"maker" => "0.0001", "taker" => "0.0005"}},
      "quoteAsset" => "USD",
      "symbol" => "BTCUSD_PERP"
    }

    assert {:ok, %Market{maker: nil, taker: nil}} =
             ResponseParser.apply_mappings(data, field_map, target: Market)
  end

  # Bourse coinmetro's `parseMarket` reads `basePrecisionAndLimits` from a local
  # built out of `this.options["currenciesByIdForParseMarket"]` — exchange
  # instance state, not the market row. A field map that resolved those keys off
  # the response would read whatever a venue happened to name the same way.
  test "market parsing does not attribute instance-state precision/limits to a response" do
    field_map =
      "coinmetro"
      |> reference_spec()
      |> get_in(["normalization", "field_maps", "market", "field_map"])

    data = %{
      "basePrecisionAndLimits" => %{"minLimit" => 0.0001, "precision" => 8},
      "pair" => "BTCEUR",
      "precision" => "2",
      "quotePrecisionAndLimits" => %{"minLimit" => 0.01}
    }

    assert {:ok, %Market{precision: precision, limits: limits}} =
             ResponseParser.apply_mappings(data, field_map, target: Market)

    refute Map.has_key?(precision, "amount")
    assert limits["amount"] == %{}
    assert limits["cost"] == %{}
  end

  describe "network-code resolution" do
    @rule %{
      "kind" => "network_code",
      "network_aliases" => %{"USDT-FROZEN" => "FROZEN", "USDT-NEW" => "OLD"}
    }

    # Pins the C-T421 order. The catalog carries Bourse's raw network id (step one of
    # `indexBy(networks, 'id')` -> `networkIdToCode`); the alias table carries the
    # resolved unified code. On disagreement the resolved value wins.
    test "the authored alias table outranks a disagreeing currency catalog" do
      currencies = %{
        "USDT" => %Bourse.Currency{networks: %{"NEW" => %{"id" => "USDT-NEW"}}}
      }

      data = %{"ccy" => "USDT", "chain" => "USDT-NEW"}

      assert "OLD" == ResponseParser.network_code_for_row(data, @rule, currencies)

      assert {:ok, %Bourse.DepositAddress{network: "OLD"}} =
               ResponseParser.apply_mappings(data, %{"network" => @rule},
                 target: Bourse.DepositAddress,
                 currencies: currencies
               )
    end

    test "a catalog-only chain reaches field extraction through the parse context" do
      currencies = %{
        "USDT" => %Bourse.Currency{networks: %{"CATALOGONLY" => %{"id" => "USDT-CATALOGONLY"}}}
      }

      data = %{"ccy" => "USDT", "chain" => "USDT-CATALOGONLY"}

      assert {:ok, %Bourse.DepositAddress{network: "CATALOGONLY"}} =
               ResponseParser.apply_mappings(data, %{"network" => @rule},
                 target: Bourse.DepositAddress,
                 currencies: currencies
               )
    end

    test "falls back to the authored alias table without a currency catalog" do
      data = %{"ccy" => "USDT", "chain" => "USDT-FROZEN"}

      assert "FROZEN" == ResponseParser.network_code_for_row(data, @rule)
    end

    # The catalog `Bourse.Exchange` actually carries — raw string-keyed maps straight
    # from `markets.currencies` / the static currencies fixture, not `%Bourse.Currency{}`.
    # `options` is the venue's REAL authored spec, never a hand-built `networksById`:
    # a synthetic table would pin the test against itself rather than against okx.
    test "resolves a catalog-only chain to its unified code from the raw string-keyed catalog shape" do
      {:ok, okx} = Bourse.Exchange.new("okx")
      options = Map.merge(okx.network_options, okx.options)

      currencies = %{
        "USDT" => %{
          "id" => "USDT",
          "networks" => %{"OPTIMISM" => %{"id" => "USDT-Optimism", "network" => "Optimism"}}
        }
      }

      data = %{"ccy" => "USDT", "chain" => "USDT-Optimism"}
      context = %{currencies: currencies, options: options}

      # `Optimism` is a network *id*; okx's authored `options.networks` carries
      # `OPTIMISM => Optimism`, so the inverted `networksById` unifies it.
      refute ResponseParser.network_code_for_row(data, @rule)
      assert "OPTIMISM" == ResponseParser.network_code_for_row(data, @rule, context)
    end

    # `defaultNetworkCodeReplacements` is the second half of networkIdToCode: the
    # same id resolves differently for the native chain currency vs a token on it.
    test "applies the base default network code replacements per currency" do
      {:ok, okx} = Bourse.Exchange.new("okx")
      options = Map.merge(okx.network_options, okx.options)

      catalog = fn code ->
        %{code => %{"networks" => %{"ERC20" => %{"id" => "#{code}-ERC20", "network" => "ERC20"}}}}
      end

      resolve = fn code ->
        ResponseParser.network_code_for_row(
          %{"ccy" => code, "chain" => "#{code}-ERC20"},
          @rule,
          %{currencies: catalog.(code), options: options}
        )
      end

      assert "ETH" == resolve.("ETH")
      assert "ERC20" == resolve.("USDT")
    end

    # Pins the known limitation recorded in carve C-T421 so it cannot be quietly
    # restated as resolved: the vendored currencies cache already carries `OP` (a
    # unified code from a newer Bourse vintage), and neither okx's `networks` nor the
    # base replacements map `OP`, so networkIdToCode is correctly an identity here.
    # The alias table — not the catalog — is what yields `OPTIMISM` for this chain.
    test "leaves a catalog value the venue tables do not map untouched" do
      {:ok, okx} = Bourse.Exchange.new("okx")
      options = Map.merge(okx.network_options, okx.options)

      currencies = %{
        "USDT" => %{"networks" => %{"OP" => %{"id" => "USDT-Optimism", "network" => "OP"}}}
      }

      assert "OP" ==
               ResponseParser.network_code_for_row(
                 %{"ccy" => "USDT", "chain" => "USDT-Optimism"},
                 @rule,
                 %{currencies: currencies, options: options}
               )
    end

    test "looks up the catalog after applying the venue currency alias" do
      context = %{
        currencies: %{
          "BTC" => %{"networks" => %{"BTC" => %{"id" => "XBT-Bitcoin", "network" => "BTC"}}}
        },
        common_currencies: %{"XBT" => "BTC"}
      }

      assert "BTC" == ResponseParser.network_code_for_row(%{"ccy" => "XBT", "chain" => "XBT-Bitcoin"}, @rule, context)
    end

    test "returns nil when neither the catalog nor the aliases know the chain" do
      data = %{"ccy" => "USDT", "chain" => "USDT-Unlisted"}

      refute ResponseParser.network_code_for_row(data, @rule, %{
               "USDT" => %{"networks" => %{"ARBONE" => %{"id" => "USDT-Arbitrum One"}}}
             })
    end

    test "a non-map rule resolves to nil rather than raising" do
      refute ResponseParser.network_code_for_row(%{"ccy" => "USDT", "chain" => "USDT-NEW"}, nil)
    end
  end

  test "coerces values from documented venue response shapes" do
    # Each row uses the source key and wire representation from the corresponding
    # venue parser call, rather than a generic {"v" => sample} sweep input.
    # Binance's market shape is also captured in
    # test/fixtures/responses/binance/fetch_markets.json.
    cases = [
      {"binance market precision", %{"baseAssetPrecision" => 8},
       %{"key" => "baseAssetPrecision", "coercion" => "parseNumber(parsePrecision(safeString))"}, "last", 1.0e-8},
      {"dydx market step size", %{"stepSize" => "0.01"}, %{"key" => "stepSize", "coercion" => "parseNumber(safeString)"},
       "last", 0.01},
      {"hashkey market notional", %{"min_notional" => "10"},
       %{"key" => "min_notional", "coercion" => "parseNumber(omitZero(safeString))"}, "last", 10.0},
      {"backpack candle start", %{"start" => "2024-05-05T15:41:44Z"},
       %{"key" => "start", "coercion" => "parse8601", "format" => "iso8601"}, "timestamp", 1_714_923_704_000},
      {"arkham funding time", %{"time" => "1714923704"},
       %{"key" => "time", "coercion" => "safeIntegerProduct", "format" => "ms"}, "timestamp", 1_714_923_704_000},
      {"binance funding timestamp", %{"timestamp" => "1714923704000"},
       %{"key" => "timestamp", "coercion" => "safeIntegerOmitZero", "format" => "ms"}, "timestamp", 1_714_923_704_000},
      {"kraken futures side", %{"side" => "BUY"}, %{"key" => "side", "coercion" => "safeStringLower2"}, "symbol", "buy"},
      {"binance funding symbol", %{"symbol" => "BTCUSDT"}, %{"key" => "symbol", "coercion" => "safeSymbol"}, "symbol",
       "BTCUSDT"},
      {"woo order created time", %{"createdTime" => "1714923704"},
       %{"key" => "createdTime", "coercion" => "safeTimestamp2", "format" => "ms"}, "timestamp", 1_714_923_704_000}
    ]

    for {venue, data, rule, field, expected} <- cases do
      assert {:ok, parsed} = ResponseParser.apply_mappings(data, %{field => rule}, target: Ticker), venue
      assert Map.fetch!(parsed, String.to_existing_atom(field)) == expected, venue
    end
  end

  test "omits zero sentinels for omit-zero coercions" do
    mapping = %{
      "last" => %{"key" => "min_notional", "coercion" => "parseNumber(omitZero(safeString))"},
      "timestamp" => %{"key" => "timestamp", "coercion" => "safeIntegerOmitZero", "format" => "ms"}
    }

    assert {:ok, %Ticker{last: nil, timestamp: nil}} =
             ResponseParser.apply_mappings(%{"min_notional" => "0", "timestamp" => "0"}, mapping, target: Ticker)
  end

  test "parses a list of records into target structs" do
    data = [
      %{"symbol" => "BTC/USDT", "last" => "1", "ts" => "10"},
      %{"symbol" => "ETH/USDT", "last" => "2", "ts" => "20"}
    ]

    assert {:ok, [%Ticker{symbol: "BTC/USDT"}, %Ticker{symbol: "ETH/USDT"}]} =
             ResponseParser.apply_mappings(data, @ticker_mapping, %{target: Ticker})
  end

  test "selects a branch by input shape" do
    mapping = %{
      "branches" => [
        %{
          "guard" => %{"input_shape" => "array"},
          "field_map" => %{"id" => %{"index" => 0, "coercion" => "safeString"}}
        },
        %{
          "guard" => %{"input_shape" => "object"},
          "field_map" => %{"id" => %{"key" => "id", "coercion" => "safeString"}}
        }
      ]
    }

    assert {:ok, %Trade{id: "trade-1"}} = ResponseParser.apply_mappings(["trade-1"], mapping, target: Trade)
    assert {:ok, %Trade{id: "trade-2"}} = ResponseParser.apply_mappings(%{"id" => "trade-2"}, mapping, target: Trade)
  end

  test "maps an empty list to an empty list of records" do
    assert {:ok, []} = ResponseParser.apply_mappings([], @ticker_mapping, target: Ticker)
  end

  test "supports discriminated rules from market context" do
    mapping = %{
      "last" => %{
        "kind" => "discriminated",
        "discriminator" => "market.inverse",
        "true" => %{"key" => "inverse_price", "coercion" => "safeNumber"},
        "false" => %{"key" => "spot_price", "coercion" => "safeNumber"}
      }
    }

    assert {:ok, %Ticker{last: 10.0}} =
             ResponseParser.apply_mappings(%{"inverse_price" => "10"}, mapping, target: Ticker, market: %{inverse: true})

    assert {:ok, %Ticker{last: 20.0}} =
             ResponseParser.apply_mappings(%{"spot_price" => "20"}, mapping,
               target: Ticker,
               market: %{"inverse" => false}
             )
  end

  test "supports when rules gated on a payload field (C36 vwap shape)" do
    mapping = %{
      "vwap" => %{
        "kind" => "when",
        "guard" => %{"field" => "instType", "in" => ["SPOT", "MARGIN"]},
        "then" => %{
          "kind" => "computed",
          "op" => "div",
          "operands" => ["volCcy24h", "vol24h"],
          "coercion" => "safeNumber"
        },
        "else" => nil
      }
    }

    assert {:ok, %Ticker{vwap: vwap}} =
             ResponseParser.apply_mappings(
               %{"instType" => "SPOT", "volCcy24h" => "200", "vol24h" => "2"},
               mapping,
               target: Ticker
             )

    assert_in_delta vwap, 100.0, 1.0e-9

    assert {:ok, %Ticker{vwap: nil}} =
             ResponseParser.apply_mappings(
               %{"instType" => "SWAP", "volCcy24h" => "83052.9378", "vol24h" => "8305293.78"},
               mapping,
               target: Ticker
             )
  end

  test "maps authored numeric zero sentinels to nil" do
    mapping = %{"high" => %{"key" => "highPrice24h", "coercion" => "safeNumber", "zero_as_nil" => true}}

    assert {:ok, %Ticker{high: nil}} =
             ResponseParser.apply_mappings(%{"highPrice24h" => "0"}, mapping, target: Ticker)
  end

  test "drops discriminated fields when no branch is available" do
    mapping = %{
      "last" => %{
        "kind" => "discriminated",
        "discriminator" => "market.inverse"
      }
    }

    assert {:ok, %Ticker{last: nil}} =
             ResponseParser.apply_mappings(%{"inverse_price" => "10"}, mapping, target: Ticker, market: %{inverse: true})
  end

  test "extracts nested sub-field maps" do
    mapping = %{
      "info" => %{
        "sub_field_map" => %{
          "venue" => %{"key" => "exchange", "coercion" => "safeStringLower"}
        }
      }
    }

    assert {:ok, %Ticker{info: %{"venue" => "okx"}}} =
             ResponseParser.apply_mappings(%{"exchange" => "OKX"}, mapping, target: Ticker)
  end

  test "preserves canonical balance currency keys in nested currency maps" do
    mapping = %{
      "free" => %{"sub_field_map" => %{"USDC" => %{"key" => "withdrawable", "coercion" => "safeNumber"}}},
      "used" => %{"sub_field_map" => %{"USDC" => %{"key" => "marginSummary.totalMarginUsed", "coercion" => "safeNumber"}}},
      "total" => %{"sub_field_map" => %{"USDC" => %{"key" => "marginSummary.accountValue", "coercion" => "safeNumber"}}}
    }

    data = %{
      "marginSummary" => %{"accountValue" => "999.0", "totalMarginUsed" => "0.0"},
      "withdrawable" => "999.0"
    }

    assert {:ok, %Balance{} = balance} = ResponseParser.apply_mappings(data, mapping, target: Balance)
    assert balance.free["USDC"] == 999.0
    assert balance.total["USDC"] == 999.0
    assert balance.used["USDC"] == 0.0
    refute Map.has_key?(balance.total, "usdc")
    assert Balance.get(balance, "USDC") == %{free: 999.0, used: 0.0, total: 999.0}
  end

  test "adds two keyed balance fields with decimal precision" do
    mapping = %{
      "total" => %{
        "kind" => "keyed_collection",
        "collection_key" => "balances",
        "index_key" => "asset",
        "index_coercion" => "safeCurrencyCode",
        "value_key" => "free",
        "value_key2" => "locked",
        "value_op" => "add",
        "coercion" => "safeNumber"
      }
    }

    data = %{"balances" => [%{"asset" => "BTC", "free" => "0.91974100", "locked" => "0.00025900"}]}

    assert {:ok, %Balance{total: %{"BTC" => 0.92}}} =
             ResponseParser.apply_mappings(data, mapping, target: Balance)
  end

  test "subtracts keyed balance operands with decimal precision" do
    mapping = %{
      "free" => %{
        "kind" => "keyed_collection",
        "collection_key" => "balances",
        "index_key" => "asset",
        "index_coercion" => "safeCurrencyCode",
        "operand_keys" => ["walletBalance", "totalPositionIM", "totalOrderIM", "locked", "bonus"],
        "value_op" => "subtract",
        "coercion" => "safeNumber"
      }
    }

    data = %{
      "balances" => [
        %{
          "asset" => "USDT",
          "walletBalance" => "3322.25896609",
          "totalPositionIM" => "50.61831144",
          "totalOrderIM" => "0",
          "locked" => "42",
          "bonus" => "0"
        }
      ]
    }

    assert {:ok, %Balance{free: %{"USDT" => 3229.64065465}}} =
             ResponseParser.apply_mappings(data, mapping, target: Balance)
  end

  test "indexes Deribit account summaries by currency" do
    rule = fn value_key ->
      %{
        "kind" => "keyed_collection",
        "collection_key" => "summaries",
        "index_key" => "currency",
        "index_coercion" => "safeCurrencyCode",
        "value_key" => value_key,
        "coercion" => "safeNumber"
      }
    end

    mapping = %{
      "free" => rule.("available_funds"),
      "used" => rule.("maintenance_margin"),
      "total" => rule.("equity")
    }

    data = %{
      "summaries" => [
        %{"currency" => "btc", "available_funds" => "0.2", "maintenance_margin" => "0.01", "equity" => "0.21"},
        %{"currency" => "eth", "available_funds" => 1, "maintenance_margin" => 0, "equity" => 1}
      ]
    }

    assert {:ok, %Balance{} = balance} = ResponseParser.apply_mappings(data, mapping, target: Balance)
    assert balance.free == %{"BTC" => 0.2, "ETH" => 1.0}
    assert balance.used == %{"BTC" => 0.01, "ETH" => 0.0}
    assert balance.total == %{"BTC" => 0.21, "ETH" => 1.0}
  end

  test "indexes OKX account details by ccy with availEq/availBal and eq/cashBal fallbacks" do
    rule = fn value_key, value_key2, fallbacks ->
      %{
        "kind" => "keyed_collection",
        "collection_key" => "details",
        "index_key" => "ccy",
        "index_coercion" => "safeCurrencyCode",
        "value_key" => value_key,
        "value_key2" => value_key2,
        "fallback_keys" => fallbacks,
        "coercion" => "safeNumber"
      }
    end

    mapping = %{
      "free" => rule.("availEq", "availBal", []),
      "used" => rule.("frozenBal", nil, []),
      "total" => rule.("eq", "cashBal", ["bal"])
    }

    data = %{
      "details" => [
        %{
          "ccy" => "btc",
          "availEq" => "",
          "availBal" => "1",
          "frozenBal" => "0",
          "eq" => "",
          "cashBal" => "1"
        },
        %{
          "ccy" => "USDT",
          "availEq" => "10",
          "availBal" => "9",
          "frozenBal" => "1",
          "eq" => "11",
          "cashBal" => "11"
        }
      ]
    }

    assert {:ok, %Balance{} = balance} = ResponseParser.apply_mappings(data, mapping, target: Balance)
    assert balance.free == %{"BTC" => 1.0, "USDT" => 10.0}
    assert balance.used == %{"BTC" => 0.0, "USDT" => 1.0}
    assert balance.total == %{"BTC" => 1.0, "USDT" => 11.0}
  end

  test "indexes OKX funding rows normalized under details (funding bal fallback)" do
    mapping = %{
      "free" => %{
        "kind" => "keyed_collection",
        "collection_key" => "details",
        "index_key" => "ccy",
        "index_coercion" => "safeCurrencyCode",
        "value_key" => "availEq",
        "value_key2" => "availBal",
        "coercion" => "safeNumber"
      },
      "used" => %{
        "kind" => "keyed_collection",
        "collection_key" => "details",
        "index_key" => "ccy",
        "index_coercion" => "safeCurrencyCode",
        "value_key" => "frozenBal",
        "coercion" => "safeNumber"
      },
      "total" => %{
        "kind" => "keyed_collection",
        "collection_key" => "details",
        "index_key" => "ccy",
        "index_coercion" => "safeCurrencyCode",
        "value_key" => "eq",
        "value_key2" => "cashBal",
        "fallback_keys" => ["bal"],
        "coercion" => "safeNumber"
      }
    }

    # ReadParse.balance_parse_payload normalizes funding `data[]` into this shape.
    data = %{"details" => [%{"availBal" => "100", "bal" => "100", "ccy" => "TUSD", "frozenBal" => "0"}]}

    assert {:ok, %Balance{} = balance} = ResponseParser.apply_mappings(data, mapping, target: Balance)
    assert balance.free == %{"TUSD" => 100.0}
    assert balance.used == %{"TUSD" => 0.0}
    assert balance.total == %{"TUSD" => 100.0}
  end

  test "epochMsOrDatetime accepts epoch ms and naive UTC datetime sources" do
    mapping = %{"timestamp" => %{"key" => "at", "coercion" => "epochMsOrDatetime"}}

    parse = fn value ->
      {:ok, %Ticker{timestamp: timestamp}} =
        ResponseParser.apply_mappings(%{"at" => value}, mapping, target: Ticker)

      timestamp
    end

    # Binance capital history sends both forms: `insertTime` as epoch ms,
    # `applyTime` as a naive UTC datetime.
    assert parse.("1714923704000") == 1_714_923_704_000
    assert parse.(1_714_923_704_000) == 1_714_923_704_000
    assert parse.("2024-05-05 15:38:56") == 1_714_923_536_000
    assert parse.("2024-05-05T15:38:56") == 1_714_923_536_000
    assert parse.(1_714_923_704_000.9) == 1_714_923_704_000

    # Unparseable sources yield nil rather than a bogus epoch.
    assert parse.("not-a-timestamp") == nil
    assert parse.(%{"nested" => "map"}) == nil
  end

  test "epochMsOrDatetime does not scale seconds, unlike Bourse's safeTimestamp" do
    # Guards the carve recorded in docs/authored-spec-carves/binance.md: this
    # coercion is deliberately NOT Bourse's `safeTimestamp` (seconds -> ms). If a
    # future change makes it scale, the 48 catalog rules still tagged
    # `safeTimestamp` must keep its documented seconds-to-ms behavior.
    mapping = %{"timestamp" => %{"key" => "at", "coercion" => "epochMsOrDatetime"}}

    assert {:ok, %Ticker{timestamp: 1_714_923_704}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704"}, mapping, target: Ticker)
  end

  test "safeTimestamp respects the field rule's documented resolution" do
    seconds = %{"timestamp" => %{"key" => "at", "coercion" => "safeTimestamp", "format" => "s"}}
    milliseconds = %{"timestamp" => %{"key" => "at", "coercion" => "safeTimestamp", "format" => "ms"}}

    assert {:ok, %Ticker{timestamp: 1_714_923_704_000}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704"}, seconds, target: Ticker)

    assert {:ok, %Ticker{timestamp: 1_714_923_704_000}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704000"}, milliseconds, target: Ticker)
  end

  test "iso8601 respects the field rule's documented resolution" do
    seconds = %{"datetime" => %{"key" => "at", "coercion" => "iso8601", "format" => "s"}}
    milliseconds = %{"datetime" => %{"key" => "at", "coercion" => "iso8601", "format" => "ms"}}
    absent = %{"datetime" => %{"key" => "at", "coercion" => "iso8601"}}

    assert {:ok, %Ticker{datetime: "2024-05-05T15:41:44.000Z"}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704"}, seconds, target: Ticker)

    assert {:ok, %Ticker{datetime: "2024-05-05T15:41:44.000Z"}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704000"}, milliseconds, target: Ticker)

    # Absent format defaults to milliseconds (catalog majority), not seconds.
    assert {:ok, %Ticker{datetime: "2024-05-05T15:41:44.000Z"}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704000"}, absent, target: Ticker)
  end

  test "iso8601 format s honours seconds for deepcoin CreateTime and whitebit fundingTime" do
    # Deepcoin CreateTime is Unix seconds: the English response example shows
    # `"CreateTime":1744606800` (10-digit epoch) on
    # https://www.deepcoin.com/docs/DeepCoinTrade/fundingRateHistory, and live
    # GET /deepcoin/trade/fund-rate/history returns the same form.
    deepcoin_rule =
      "deepcoin"
      |> reference_spec()
      |> get_in(["normalization", "field_maps", "funding_rate_history", "field_map", "datetime"])

    assert %{"coercion" => "iso8601", "format" => "s", "key" => "CreateTime"} = deepcoin_rule

    assert {:ok, %Ticker{datetime: "2025-04-14T05:00:00.000Z"}} =
             ResponseParser.apply_mappings(
               %{"CreateTime" => 1_744_606_800},
               %{"datetime" => deepcoin_rule},
               target: Ticker
             )

    # WhiteBIT fundingTime is Unix seconds: OpenAPI documents
    # "Unix timestamp in seconds when the funding settlement executed" with
    # example `"1752537600"` on
    # https://docs.whitebit.com/api-reference/market-data/funding-history.
    whitebit_rule =
      "whitebit"
      |> reference_spec()
      |> get_in(["normalization", "field_maps", "funding_rate_history", "field_map", "datetime"])

    assert %{"coercion" => "iso8601", "format" => "s", "key" => "fundingTime"} = whitebit_rule

    assert {:ok, %Ticker{datetime: "2025-07-15T00:00:00.000Z"}} =
             ResponseParser.apply_mappings(
               %{"fundingTime" => "1752537600"},
               %{"datetime" => whitebit_rule},
               target: Ticker
             )
  end

  test "safeTimestamp format s scales deepcoin CreateTime and whitebit fundingTime to ms epoch" do
    # Same venue sources as the iso8601 companion test above: both are Unix
    # seconds on the wire (task 419). safeTimestamp with format "s" must emit
    # seconds * 1000 so the timestamp sibling matches the iso8601 datetime.
    deepcoin_ts =
      "deepcoin"
      |> reference_spec()
      |> get_in(["normalization", "field_maps", "funding_rate_history", "field_map", "timestamp"])

    assert %{"coercion" => "safeTimestamp", "format" => "s", "key" => "CreateTime"} = deepcoin_ts

    # Live-shaped sample: English docs example CreateTime 1744606800
    # (https://www.deepcoin.com/docs/DeepCoinTrade/fundingRateHistory).
    assert {:ok, %Ticker{timestamp: 1_744_606_800_000, datetime: "2025-04-14T05:00:00.000Z"}} =
             ResponseParser.apply_mappings(
               %{"CreateTime" => 1_744_606_800},
               %{
                 "timestamp" => deepcoin_ts,
                 "datetime" => %{
                   "coercion" => "iso8601",
                   "format" => "s",
                   "key" => "CreateTime"
                 }
               },
               target: Ticker
             )

    whitebit_ts =
      "whitebit"
      |> reference_spec()
      |> get_in(["normalization", "field_maps", "funding_rate_history", "field_map", "timestamp"])

    assert %{"coercion" => "safeTimestamp", "format" => "s", "key" => "fundingTime"} = whitebit_ts

    # Live-shaped sample: OpenAPI example fundingTime "1752537600"
    # (https://docs.whitebit.com/api-reference/market-data/funding-history).
    assert {:ok, %Ticker{timestamp: 1_752_537_600_000, datetime: "2025-07-15T00:00:00.000Z"}} =
             ResponseParser.apply_mappings(
               %{"fundingTime" => "1752537600"},
               %{
                 "timestamp" => whitebit_ts,
                 "datetime" => %{
                   "coercion" => "iso8601",
                   "format" => "s",
                   "key" => "fundingTime"
                 }
               },
               target: Ticker
             )
  end

  test "safeTimestamp drops rules with an unresolved format instead of passing through the raw value" do
    mapping = %{"timestamp" => %{"key" => "at", "coercion" => "safeTimestamp", "format" => "unknown"}}

    assert {:ok, %Ticker{timestamp: nil}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704"}, mapping, target: Ticker)
  end

  test "safeTimestamp scales an explicitly-null format as unannotated seconds, not as unsupported" do
    # `"format": null` is the catalog's "not annotated" idiom, carried by five
    # runtime rules (digifinex/lighter/mercado/whitebit order timestamps). A
    # key-absence-only guard silently dropped all five to nil.
    explicit_null = %{"timestamp" => %{"key" => "at", "coercion" => "safeTimestamp", "format" => nil}}
    absent = %{"timestamp" => %{"key" => "at", "coercion" => "safeTimestamp"}}

    assert {:ok, %Ticker{timestamp: 1_714_923_704_000}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704"}, explicit_null, target: Ticker)

    assert {:ok, %Ticker{timestamp: 1_714_923_704_000}} =
             ResponseParser.apply_mappings(%{"at" => "1714923704"}, absent, target: Ticker)
  end

  test "derive market.expiry declares ms — its source is pre-scaled, so it must not be scaled again" do
    # `_bourse_expiry` is already seconds * 1000 at Bourse.Unified.ReadParse
    # (scale_option_expiry/1). The authored rule declares "format": "ms" so the
    # parser preserves it; a seconds default here would be 1000x too large.
    rule =
      "derive"
      |> Bourse.Spec.load!()
      |> get_in(["normalization", "field_maps", "market", "field_map", "expiry"])

    assert %{"coercion" => "safeTimestamp", "format" => "ms", "key" => "_bourse_expiry"} = rule

    assert {:ok, %Ticker{timestamp: 1_714_923_704_000}} =
             ResponseParser.apply_mappings(
               %{"_bourse_expiry" => 1_714_923_704_000},
               %{"timestamp" => rule},
               target: Ticker
             )
  end

  test "enum_fallback raw keeps the venue identifier when the map has no entry" do
    mapping = %{
      "symbol" => %{
        "key" => "net",
        "enum_map" => %{"TRX" => "TRC20"},
        "enum_default" => nil,
        "enum_fallback" => "raw"
      }
    }

    assert {:ok, %Ticker{symbol: "TRC20"}} =
             ResponseParser.apply_mappings(%{"net" => "TRX"}, mapping, target: Ticker)

    # An id outside the authored map survives unnormalized rather than nil-ing.
    assert {:ok, %Ticker{symbol: "SOL"}} =
             ResponseParser.apply_mappings(%{"net" => "SOL"}, mapping, target: Ticker)
  end

  test "enum_default still applies when enum_fallback is absent" do
    mapping = %{"symbol" => %{"key" => "net", "enum_map" => %{"TRX" => "TRC20"}, "enum_default" => nil}}

    assert {:ok, %Ticker{symbol: nil}} =
             ResponseParser.apply_mappings(%{"net" => "SOL"}, mapping, target: Ticker)
  end

  test "unmapped authored order status fails with venue, source field, and raw value" do
    mapping = %{"status" => %{"key" => "order_state", "enum_map" => %{"open" => "open"}}}

    assert {:error, {:unmapped_order_status, %{venue: "deribit", field: "order_state", raw_value: "provider_added"}}} =
             ResponseParser.apply_mappings(
               %{"order_state" => "provider_added"},
               mapping,
               target: Order,
               venue: "deribit"
             )
  end

  test "order status preserves missing values and only passes unknown values through explicitly" do
    strict = %{"status" => %{"key" => "state", "enum_map" => %{"open" => "open"}}}
    passthrough = put_in(strict, ["status", "enum_passthrough"], true)

    assert {:ok, %Order{status: nil}} =
             ResponseParser.apply_mappings(%{}, strict, target: Order, venue: "example")

    assert {:ok, %Order{status: "provider_added"}} =
             ResponseParser.apply_mappings(
               %{"state" => "provider_added"},
               passthrough,
               target: Order,
               venue: "example"
             )
  end

  test "maps authored enum values and defaults" do
    mapping = %{
      "spot" => %{"key" => "kind", "enum_map" => %{"spot" => true}, "enum_default" => false},
      "contract" => %{"key" => "kind", "enum_map" => %{"spot" => false}, "enum_default" => true}
    }

    assert {:ok, %Market{spot: false, contract: true}} =
             ResponseParser.apply_mappings(%{"kind" => "future"}, mapping, target: Market)
  end

  test "supports defaults, boolean coercion, raw values, and trade order id normalization" do
    mapping = %{
      "order" => %{"key" => "order", "coercion" => "safeString"},
      "fee" => %{"key" => "missing", "default" => %{"cost" => 0}},
      "info" => %{"key" => "maker", "coercion" => "safeBool"},
      :cost => %{"key" => "raw_cost"}
    }

    assert {:ok, %Trade{order_id: "order-1", fee: %{"cost" => 0}, info: true, cost: "12.5"}} =
             ResponseParser.apply_mappings(%{"order" => "order-1", "maker" => "true", "raw_cost" => "12.5"}, mapping,
               target: Trade
             )
  end

  test "returns no_matching_parser_branch when branch guards miss" do
    mapping = %{
      "branches" => [
        %{"guard" => %{"input_shape" => "array"}, "field_map" => %{"id" => %{"index" => 0}}}
      ]
    }

    assert {:error, :no_matching_parser_branch} =
             ResponseParser.apply_mappings(%{"id" => "trade-1"}, mapping, target: Trade)
  end

  test "propagates list record parse errors" do
    mapping = %{
      "branches" => [
        %{"guard" => %{"input_shape" => "array"}, "field_map" => %{"id" => %{"index" => 0}}}
      ]
    }

    assert {:error, :no_matching_parser_branch} =
             ResponseParser.apply_mappings([["trade-1"], %{"id" => "trade-2"}], mapping, target: Trade)
  end

  test "returns explicit errors for invalid mapping and target context" do
    assert {:error, :invalid_mapping} = ResponseParser.apply_mappings(%{}, nil, target: Ticker)
    assert {:error, {:invalid_target, nil}} = ResponseParser.apply_mappings(%{}, @ticker_mapping, %{})
    assert {:error, {:invalid_target, String}} = ResponseParser.apply_mappings(%{}, @ticker_mapping, target: String)
  end

  test "treats a non-map, non-list context as having no target" do
    assert {:error, {:invalid_target, nil}} = ResponseParser.apply_mappings(%{}, @ticker_mapping, :weird_context)
  end

  describe "computed scalar rules" do
    @cost_mul %{
      "cost" => %{
        "kind" => "computed",
        "op" => "mul",
        "operands" => ["amount", "price"],
        "coercion" => "safeNumber"
      }
    }

    test "multiplies operands money-exact (linear cost)" do
      assert {:ok, %Trade{cost: 10.4727}} =
               ResponseParser.apply_mappings(%{"amount" => "0.0001", "price" => "104727.0"}, @cost_mul, target: Trade)
    end

    test "uses inverse_op when the market is inverse" do
      mapping = put_in(@cost_mul, ["cost", "inverse_op"], "div")

      assert {:ok, %Trade{cost: 12.5}} =
               ResponseParser.apply_mappings(%{"amount" => "100", "price" => "8"}, mapping,
                 target: Trade,
                 market: %{inverse: true}
               )
    end

    test "keeps the linear op when inverse_op is authored but the market is linear" do
      mapping = put_in(@cost_mul, ["cost", "inverse_op"], "div")

      assert {:ok, %Trade{cost: 800.0}} =
               ResponseParser.apply_mappings(%{"amount" => "100", "price" => "8"}, mapping,
                 target: Trade,
                 market: %{"inverse" => false}
               )
    end

    test "falls back to the linear op for an inverse market with no inverse_op authored" do
      assert {:ok, %Trade{cost: 800.0}} =
               ResponseParser.apply_mappings(%{"amount" => "100", "price" => "8"}, @cost_mul,
                 target: Trade,
                 market: %{inverse: true}
               )
    end

    test "drops the field when an operand is missing" do
      assert {:ok, %Trade{cost: nil}} =
               ResponseParser.apply_mappings(%{"amount" => "0.0001"}, @cost_mul, target: Trade)
    end

    test "reads computed operands from authored fallback keys" do
      mapping = %{
        "cost" => %{
          "kind" => "computed",
          "op" => "mul",
          "operands" => [
            %{"key" => "sz", "fallback_keys" => ["fillSz"]},
            %{"key" => "px", "fallback_keys" => ["fillPx"]}
          ],
          "coercion" => "safeNumber"
        }
      }

      assert {:ok, %Trade{cost: 6.784}} =
               ResponseParser.apply_mappings(%{"fillSz" => "0.1", "fillPx" => "67.84"}, mapping, target: Trade)

      assert {:ok, %Trade{cost: 10.0}} =
               ResponseParser.apply_mappings(
                 %{"sz" => "2", "px" => "5", "fillSz" => "100", "fillPx" => "100"},
                 mapping,
                 target: Trade
               )

      assert {:ok, %Trade{cost: nil}} =
               ResponseParser.apply_mappings(%{"fillSz" => "0.1"}, mapping, target: Trade)
    end

    test "drops subtraction when an operand is missing" do
      mapping = %{
        "change" => %{
          "kind" => "computed",
          "op" => "sub",
          "operands" => ["lastPrice", "prevPrice24h"],
          "coercion" => "safeNumber"
        }
      }

      assert {:ok, %Ticker{change: nil}} =
               ResponseParser.apply_mappings(%{"lastPrice" => "10"}, mapping, target: Ticker)
    end

    test "drops the field for an unknown op" do
      mapping = put_in(@cost_mul, ["cost", "op"], "pow")

      assert {:ok, %Trade{cost: nil}} =
               ResponseParser.apply_mappings(%{"amount" => "2", "price" => "3"}, mapping, target: Trade)
    end

    test "averages operands money-exact and unrounded (Bourse safeTicker parity)" do
      mapping = %{
        "average" => %{
          "kind" => "computed",
          "op" => "average",
          "operands" => ["openPrice", "lastPrice"],
          "coercion" => "safeNumber"
        }
      }

      # round: 2 would collapse this low-priced average to 0.01; exact math keeps 0.012.
      assert {:ok, %Ticker{average: 0.012}} =
               ResponseParser.apply_mappings(
                 %{"openPrice" => "0.010", "lastPrice" => "0.014"},
                 mapping,
                 target: Ticker
               )
    end

    test "rounds a computed field half-even when round is authored" do
      mapping = %{
        "average" => %{
          "kind" => "computed",
          "op" => "average",
          "operands" => ["openPrice", "lastPrice"],
          "round" => 2,
          "coercion" => "safeNumber"
        }
      }

      assert {:ok, %Ticker{average: 100.12}} =
               ResponseParser.apply_mappings(
                 %{"openPrice" => "100.10", "lastPrice" => "100.15"},
                 mapping,
                 target: Ticker
               )
    end

    test "truncates a computed field when truncate is authored" do
      mapping = %{
        "average" => %{
          "kind" => "computed",
          "op" => "average",
          "operands" => ["openPrice", "lastPrice"],
          "truncate" => 1,
          "coercion" => "safeNumber"
        }
      }

      assert {:ok, %Ticker{average: 50_795.9}} =
               ResponseParser.apply_mappings(
                 %{"openPrice" => "50147.50", "lastPrice" => "51444.40"},
                 mapping,
                 target: Ticker
               )
    end

    # Bourse `safePosition` truncates the divide to 4 dp BEFORE the ×100. The real
    # deribit inverse-perp figures below give -1.4591883... , so a full-precision
    # divide would round to -1.46 — only the truncate-then-scale order yields the
    # -1.45 recorded by the pinned compatibility vector.
    test "pnl_percentage truncates the divide to 4dp before scaling by 100" do
      mapping = %{
        "percentage" => %{
          "kind" => "computed",
          "op" => "pnl_percentage",
          "operands" => ["floating_profit_loss", "initial_margin"],
          "coercion" => "safeNumber"
        }
      }

      assert {:ok, %Position{percentage: -1.45}} =
               ResponseParser.apply_mappings(
                 %{"floating_profit_loss" => "-1.6e-7", "initial_margin" => "1.0965e-5"},
                 mapping,
                 target: Position
               )
    end

    test "pnl_percentage is nil rather than a division error when initial margin is zero" do
      mapping = %{
        "percentage" => %{
          "kind" => "computed",
          "op" => "pnl_percentage",
          "operands" => ["floating_profit_loss", "initial_margin"],
          "coercion" => "safeNumber"
        }
      }

      assert {:ok, %Position{percentage: nil}} =
               ResponseParser.apply_mappings(
                 %{"floating_profit_loss" => "-1.6e-7", "initial_margin" => "0"},
                 mapping,
                 target: Position
               )
    end

    test "subtracts operands and scales ratios" do
      mapping = %{
        "remaining" => %{
          "kind" => "computed",
          "op" => "sub",
          "operands" => ["amount", "filled"],
          "coercion" => "safeNumber"
        },
        "cost" => %{
          "kind" => "computed",
          "op" => "div",
          "operands" => ["margin", "notional"],
          "scale" => 100,
          "coercion" => "safeNumber"
        }
      }

      assert {:ok, %Order{} = order} =
               ResponseParser.apply_mappings(
                 %{"amount" => "0.1", "filled" => "0.1", "margin" => "0.02", "notional" => "1"},
                 mapping,
                 target: Order
               )

      assert order.remaining == 0.0
      assert order.cost == 2.0
    end
  end

  describe "field-map selection and rule edge cases" do
    test "supports signed ledger arithmetic" do
      mapping = %{
        "amount" => %{"kind" => "absolute", "key" => "change", "coercion" => "safeNumber"},
        "direction" => %{
          "kind" => "sign_direction",
          "key" => "change",
          "negative" => "out",
          "zero" => "in",
          "positive" => "in"
        },
        "before" => %{
          "kind" => "computed",
          "op" => "add",
          "operands" => ["cashBalance", "change"],
          "coercion" => "safeNumber"
        }
      }

      assert {:ok, %Bourse.LedgerEntry{amount: 0.25, direction: "out", before: 9.5}} =
               ResponseParser.apply_mappings(%{"change" => "-0.25", "cashBalance" => "9.75"}, mapping,
                 target: Bourse.LedgerEntry
               )
    end

    test "builds trade fees only when the venue supplies a fee" do
      rule = %{
        "kind" => "trade_fee",
        "cost_keys" => ["execFee"],
        "rate_keys" => ["feeRate"],
        "currency_keys" => ["feeCoin"],
        "symbol_key" => "symbol",
        "side_key" => "side",
        "contract_keys" => ["createType"],
        "contract_type_key" => "execType",
        "contract_type_values" => ["Funding"],
        "quote_currencies" => ["USDT", "USD"]
      }

      assert {:ok, %Trade{fee: nil}} =
               ResponseParser.apply_mappings(%{"symbol" => "BTCUSDT"}, %{"fee" => rule}, target: Trade)

      assert {:ok, %Trade{fee: %{"cost" => 0.001, "currency" => "BTC", "rate" => 0.001}}} =
               ResponseParser.apply_mappings(
                 %{"symbol" => "BTCUSDT", "side" => "Buy", "execFee" => "0.001", "feeRate" => "0.001"},
                 %{"fee" => rule},
                 target: Trade
               )
    end

    test "builds currency networks and aggregate currency fields" do
      rules = %{
        "networks" => %{
          "kind" => "currency_networks",
          "collection_key" => "chains",
          "active_requires_both" => false,
          "network_aliases" => %{"USDT" => %{"ETH" => "ERC20"}}
        },
        "active" => %{
          "active_requires_both" => false,
          "kind" => "currency_network_summary",
          "collection_key" => "chains",
          "field" => "active"
        },
        "fee" => %{"kind" => "currency_network_summary", "collection_key" => "chains", "field" => "fee"},
        "precision" => %{
          "kind" => "currency_network_summary",
          "collection_key" => "chains",
          "field" => "precision"
        },
        "limits" => %{"kind" => "currency_network_summary", "collection_key" => "chains", "field" => "limits"}
      }

      data = %{
        "coin" => "USDT",
        "chains" => [
          %{
            "chain" => "ETH",
            "chainDeposit" => "1",
            "chainWithdraw" => "1",
            "withdrawFee" => "0.8",
            "minAccuracy" => "4",
            "withdrawMin" => "6",
            "depositMin" => "0.005"
          }
        ]
      }

      assert {:ok, %Bourse.Currency{} = currency} = ResponseParser.apply_mappings(data, rules, target: Bourse.Currency)
      assert currency.active
      assert currency.fee == 0.8
      assert currency.precision == 0.0001
      assert currency.limits["withdraw"]["min"] == 6.0
      assert currency.networks["ERC20"]["network"] == "ERC20"
    end

    test "filters fee rollups by the authored withdraw-enabled key" do
      rules = %{
        "fee" => %{
          "kind" => "currency_network_summary",
          "collection_key" => "chains",
          "field" => "fee",
          "fee_key" => "fee",
          "fee_enabled_key" => "canWd"
        }
      }

      data = %{
        "chains" => [
          %{"canWd" => true, "fee" => "0.000015"},
          %{"canWd" => false, "fee" => "0"}
        ]
      }

      assert {:ok, %Bourse.Currency{fee: 1.5e-5}} =
               ResponseParser.apply_mappings(data, rules, target: Bourse.Currency)
    end

    test "binance networkList rollup: tick-size precision, max aggregate, implied networks" do
      # Mirrors priv/specs/json/output/authored/binance.json currency slice (task 319).
      rules = %{
        "id" => %{"key" => "coin", "coercion" => "safeString"},
        "active" => %{"key" => "trading", "coercion" => "safeBool"},
        "deposit" => %{
          "kind" => "currency_network_summary",
          "collection_key" => "networkList",
          "field" => "deposit",
          "deposit_key" => "depositEnable"
        },
        "fee" => %{
          "kind" => "currency_network_summary",
          "collection_key" => "networkList",
          "field" => "fee",
          "fee_key" => "withdrawFee"
        },
        "precision" => %{
          "kind" => "currency_network_summary",
          "collection_key" => "networkList",
          "field" => "precision",
          "precision_key" => "withdrawIntegerMultiple",
          "precision_mode" => "tick_size",
          "precision_aggregate" => "max"
        },
        "limits" => %{
          "kind" => "currency_network_summary",
          "collection_key" => "networkList",
          "field" => "limits",
          "withdraw_min_key" => "withdrawMin",
          "withdraw_max_key" => "withdrawMax",
          "deposit_min_key" => "depositDust",
          "include_amount_limits" => false
        },
        "networks" => %{
          "kind" => "currency_networks",
          "collection_key" => "networkList",
          "currency_key" => "coin",
          "network_key" => "network",
          "deposit_key" => "depositEnable",
          "withdraw_key" => "withdrawEnable",
          "active_requires_both" => true,
          "fee_key" => "withdrawFee",
          "precision_key" => "withdrawIntegerMultiple",
          "precision_mode" => "tick_size",
          "withdraw_min_key" => "withdrawMin",
          "withdraw_max_key" => "withdrawMax",
          "deposit_min_key" => "depositDust",
          "network_aliases" => %{
            "BSC" => "BEP20",
            "ETH" => "ERC20",
            "TRX" => "TRC20",
            "OPTIMISM" => "OP",
            "ARBITRUM" => "ARBONE"
          },
          "implied_networks" => %{
            "ETH" => %{"ERC20" => "ETH"},
            "TRX" => %{"TRC20" => "TRX"}
          }
        }
      }

      usdt = %{
        "coin" => "USDT",
        "trading" => true,
        "networkList" => [
          %{
            "network" => "BSC",
            "depositEnable" => true,
            "withdrawEnable" => true,
            "withdrawFee" => "0.01",
            "withdrawIntegerMultiple" => "0.00000001",
            "withdrawMin" => "10",
            "withdrawMax" => "310000000",
            "depositDust" => "0.01"
          },
          %{
            "network" => "ETH",
            "depositEnable" => true,
            "withdrawEnable" => true,
            "withdrawFee" => "0.5",
            "withdrawIntegerMultiple" => "0.000001",
            "withdrawMin" => "10",
            "withdrawMax" => "310000000",
            "depositDust" => "0.001"
          },
          %{
            "network" => "APT",
            "depositEnable" => true,
            "withdrawEnable" => true,
            "withdrawFee" => "0.1",
            "withdrawIntegerMultiple" => "0.00001",
            "withdrawMin" => "10",
            "withdrawMax" => "400000000",
            "depositDust" => "0.000001"
          }
        ]
      }

      assert {:ok, %Bourse.Currency{} = currency} = ResponseParser.apply_mappings(usdt, rules, target: Bourse.Currency)
      assert currency.id == "USDT"
      assert currency.active
      assert currency.deposit
      assert currency.fee == 0.01
      # Coarsest tick across networks (Bourse safeCurrencyStructure max), not finest.
      assert currency.precision == 0.00001
      assert currency.limits["withdraw"]["min"] == 10.0
      assert currency.limits["withdraw"]["max"] == 400_000_000.0
      assert currency.limits["deposit"]["min"] == 0.000001
      refute Map.has_key?(currency.limits, "amount")
      assert currency.networks["BEP20"]["id"] == "BSC"
      assert currency.networks["ERC20"]["id"] == "ETH"
      assert currency.networks["ERC20"]["precision"] == 0.000001

      eth = %{
        "coin" => "ETH",
        "trading" => true,
        "networkList" => [
          %{
            "network" => "ETH",
            "depositEnable" => true,
            "withdrawEnable" => true,
            "withdrawFee" => "0.0001",
            "withdrawIntegerMultiple" => "0.00000001",
            "withdrawMin" => "0.001",
            "withdrawMax" => "10000",
            "depositDust" => "0.0000003"
          },
          %{
            "network" => "BSC",
            "depositEnable" => true,
            "withdrawEnable" => true,
            "withdrawFee" => "0.0000089",
            "withdrawIntegerMultiple" => "0.000001",
            "withdrawMin" => "0.000018",
            "withdrawMax" => "35000",
            "depositDust" => "0.00000001"
          }
        ]
      }

      assert {:ok, %Bourse.Currency{} = eth_currency} =
               ResponseParser.apply_mappings(eth, rules, target: Bourse.Currency)

      # impliedNetworks: native ETH chain stays ETH, not ERC20.
      assert Map.has_key?(eth_currency.networks, "ETH")
      refute Map.has_key?(eth_currency.networks, "ERC20")
      assert eth_currency.networks["BEP20"]["id"] == "BSC"
    end

    test "authors a native spot symbol only when its discriminator matches" do
      rule = %{
        "kind" => "native_symbol",
        "key" => "symbol",
        "when_key" => "marketUnit",
        "when_value" => "baseCoin",
        "market_type" => "spot",
        "quote_currencies" => ["USDT", "USD"]
      }

      assert {:ok, %Trade{symbol: "ETH/USDT"}} =
               ResponseParser.apply_mappings(%{"symbol" => "ETHUSDT", "marketUnit" => "baseCoin"}, %{"symbol" => rule},
                 target: Trade
               )

      assert {:ok, %Trade{symbol: nil}} =
               ResponseParser.apply_mappings(%{"symbol" => "ETHUSDT", "marketUnit" => ""}, %{"symbol" => rule},
                 target: Trade
               )

      assert {:ok, %Trade{symbol: "ETH/USDT"}} =
               ResponseParser.apply_mappings(%{"symbol" => "ETHUSDT", "marketUnit" => ""}, %{"symbol" => rule},
                 target: Trade,
                 symbol: "ETH/USDT"
               )
    end

    test "extracts a value from a matching collection member" do
      mapping = %{
        "precision" => %{
          "sub_field_map" => %{
            "price" => %{
              "kind" => "collection_member",
              "collection_key" => "filters",
              "match_key" => "filterType",
              "match_value" => "PRICE_FILTER",
              "key" => "tickSize",
              "coercion" => "safeNumber"
            }
          }
        }
      }

      data = %{"filters" => [%{"filterType" => "PRICE_FILTER", "tickSize" => "0.01000000"}]}

      assert {:ok, %Market{precision: %{"price" => 0.01}}} =
               ResponseParser.apply_mappings(data, mapping, target: Market)
    end

    test "collection_member prefers ordered match_values and fallback_keys" do
      mapping = %{
        "limits" => %{
          "sub_field_map" => %{
            "cost" => %{
              "sub_field_map" => %{
                "min" => %{
                  "kind" => "collection_member",
                  "collection_key" => "filters",
                  "match_key" => "filterType",
                  "match_values" => ["NOTIONAL", "MIN_NOTIONAL"],
                  "key" => "minNotional",
                  "fallback_keys" => ["notional"],
                  "coercion" => "safeNumber2"
                }
              }
            }
          }
        }
      }

      # Spot-style NOTIONAL carries minNotional.
      notional_data = %{
        "filters" => [
          %{"filterType" => "LOT_SIZE", "minQty" => "0.001"},
          %{"filterType" => "NOTIONAL", "minNotional" => "5.00000000", "maxNotional" => "9000000"}
        ]
      }

      assert {:ok, %Market{limits: %{"cost" => %{"min" => 5.0}}}} =
               ResponseParser.apply_mappings(notional_data, mapping, target: Market)

      # Futures-style MIN_NOTIONAL carries `notional` only.
      min_notional_data = %{
        "filters" => [%{"filterType" => "MIN_NOTIONAL", "notional" => "50"}]
      }

      assert {:ok, %Market{limits: %{"cost" => %{"min" => 50.0}}}} =
               ResponseParser.apply_mappings(min_notional_data, mapping, target: Market)

      # Authored preference order wins even when the payload lists MIN_NOTIONAL first.
      both_data = %{
        "filters" => [
          %{"filterType" => "MIN_NOTIONAL", "notional" => "50"},
          %{"filterType" => "NOTIONAL", "minNotional" => "5.00000000"}
        ]
      }

      assert {:ok, %Market{limits: %{"cost" => %{"min" => 5.0}}}} =
               ResponseParser.apply_mappings(both_data, mapping, target: Market)
    end

    test "selects an explicit field_map wrapper" do
      mapping = %{"field_map" => %{"symbol" => %{"key" => "symbol", "coercion" => "safeString"}}}

      assert {:ok, %Ticker{symbol: "BTC/USDT"}} =
               ResponseParser.apply_mappings(%{"symbol" => "BTC/USDT"}, mapping, target: Ticker)
    end

    test "matches an always-guard branch" do
      mapping = %{
        "branches" => [
          %{"guard" => %{"kind" => "always"}, "field_map" => %{"id" => %{"key" => "id", "coercion" => "safeString"}}}
        ]
      }

      assert {:ok, %Trade{id: "t-1"}} = ResponseParser.apply_mappings(%{"id" => "t-1"}, mapping, target: Trade)
    end

    test "rejects an unrecognized branch guard" do
      mapping = %{
        "branches" => [
          %{"guard" => %{"input_shape" => "scalar"}, "field_map" => %{"id" => %{"key" => "id"}}}
        ]
      }

      assert {:error, :no_matching_parser_branch} =
               ResponseParser.apply_mappings(%{"id" => "t-1"}, mapping, target: Trade)
    end

    test "drops nil and non-map rules" do
      mapping = %{"cost" => nil, "amount" => "literal-not-a-rule"}

      assert {:ok, %Trade{cost: nil, amount: nil}} =
               ResponseParser.apply_mappings(%{"amount" => "1"}, mapping, target: Trade)
    end

    test "handles every signed-ledger direction and malformed amounts" do
      mapping = %{
        "amount" => %{"kind" => "absolute", "key" => "change", "coercion" => "safeNumber"},
        "direction" => %{
          "kind" => "sign_direction",
          "key" => "change",
          "negative" => "out",
          "zero" => "flat",
          "positive" => "in"
        }
      }

      assert {:ok, %Bourse.LedgerEntry{amount: amount, direction: "flat"}} =
               ResponseParser.apply_mappings(%{"change" => "0"}, mapping, target: Bourse.LedgerEntry)

      assert amount == 0.0

      assert {:ok, %Bourse.LedgerEntry{amount: 1.0, direction: "in"}} =
               ResponseParser.apply_mappings(%{"change" => "1"}, mapping, target: Bourse.LedgerEntry)

      assert {:ok, %Bourse.LedgerEntry{amount: nil, direction: nil}} =
               ResponseParser.apply_mappings(%{}, mapping, target: Bourse.LedgerEntry)

      assert {:ok, %Bourse.LedgerEntry{amount: nil, direction: nil}} =
               ResponseParser.apply_mappings(%{"change" => "invalid"}, mapping, target: Bourse.LedgerEntry)
    end

    test "derives explicit, contract, and spot trade-fee currencies" do
      rule = %{
        "kind" => "trade_fee",
        "cost_keys" => ["fee"],
        "currency_keys" => ["feeCoin"],
        "symbol_key" => "symbol",
        "side_key" => "side",
        "contract_keys" => ["contractMarker"],
        "quote_currencies" => ["USDT", "USD"]
      }

      assert {:ok, %Trade{fee: %{"cost" => 1.0, "currency" => "USDC"}}} =
               ResponseParser.apply_mappings(
                 %{"fee" => "1", "feeCoin" => "usdc"},
                 %{"fee" => rule},
                 target: Trade
               )

      assert {:ok, %Trade{fee: %{"cost" => 1.0, "currency" => "USDT"}}} =
               ResponseParser.apply_mappings(
                 %{"fee" => "1", "symbol" => "BTCUSDT", "side" => "Buy", "contractMarker" => "linear"},
                 %{"fee" => rule},
                 target: Trade
               )

      for {side, fee, currency} <- [{"Sell", "1", "USDT"}, {"Buy", "-1", "USDT"}, {"Sell", "-1", "BTC"}] do
        assert {:ok, %Trade{fee: %{"currency" => ^currency}}} =
                 ResponseParser.apply_mappings(
                   %{"fee" => fee, "symbol" => "BTCUSDT", "side" => side},
                   %{"fee" => rule},
                   target: Trade
                 )
      end
    end

    test "extracts the first authored fee entry without inventing an empty fee" do
      mapping = %{
        "fee" => %{"kind" => "first_fee_entry", "key" => "cumFeeDetail"},
        "fees" => %{"kind" => "first_fee_entry", "key" => "cumFeeDetail", "wrap_list" => true}
      }

      assert {:ok,
              %Order{
                fee: %{"cost" => 0.25, "currency" => "USDT"},
                fees: [%{"cost" => 0.25, "currency" => "USDT"}]
              }} =
               ResponseParser.apply_mappings(
                 %{"cumFeeDetail" => %{"usdt" => "0.25"}},
                 mapping,
                 target: Order
               )

      assert {:ok, %Order{fee: nil}} =
               ResponseParser.apply_mappings(%{"cumFeeDetail" => %{}}, mapping, target: Order)
    end

    test "mirrors a populated sub-field map into a list without inventing empty values" do
      fee_map = %{
        "cost" => %{"key" => "fee", "scale" => -1, "coercion" => "safeNumber"},
        "currency" => %{"key" => "feeCcy", "coercion" => "safeString"}
      }

      mapping = %{
        "fee" => %{"sub_field_map" => fee_map, "omit_if_empty" => true},
        "fees" => %{"sub_field_map" => fee_map, "omit_if_empty" => true, "wrap_list" => true}
      }

      fee = %{"cost" => 0.0001, "currency" => "LTC"}

      assert {:ok, %Order{fee: ^fee, fees: [^fee]}} =
               ResponseParser.apply_mappings(%{"fee" => "-0.0001", "feeCcy" => "LTC"}, mapping, target: Order)

      assert {:ok, %Order{fee: nil, fees: []}} =
               ResponseParser.apply_mappings(%{}, mapping, target: Order)
    end

    test "preserves decimal numbers while canonicalizing whole-number strings" do
      mapping = %{
        "amount" => %{"key" => "amount", "coercion" => "safeNumberCanonical"},
        "price" => %{"key" => "price", "coercion" => "safeNumberCanonical"}
      }

      assert {:ok, %Order{amount: 1, price: 1.5}} =
               ResponseParser.apply_mappings(%{"amount" => "1", "price" => "1.5"}, mapping, target: Order)
    end

    test "builds a native contract symbol" do
      rule = %{
        "kind" => "native_symbol",
        "key" => "symbol",
        "when_key" => "marketUnit",
        "when_value" => "baseCoin",
        "market_type" => "contract",
        "quote_currencies" => ["USDT", "USD"]
      }

      assert {:ok, %Trade{symbol: "ETH/USDT:USDT"}} =
               ResponseParser.apply_mappings(
                 %{"symbol" => "ETHUSDT", "marketUnit" => "baseCoin"},
                 %{"symbol" => rule},
                 target: Trade
               )
    end

    test "handles currency summary booleans and malformed chain collections" do
      rules = %{
        "deposit" => %{"kind" => "currency_network_summary", "field" => "deposit"},
        "withdraw" => %{"kind" => "currency_network_summary", "field" => "withdraw"},
        "fee" => %{"kind" => "currency_network_summary", "field" => "unknown"}
      }

      assert {:ok, %Bourse.Currency{deposit: true, withdraw: false, fee: nil}} =
               ResponseParser.apply_mappings(
                 %{"chains" => [%{"chainDeposit" => "1", "chainWithdraw" => "0"}]},
                 rules,
                 target: Bourse.Currency
               )

      assert {:ok, %Bourse.Currency{deposit: false, withdraw: false}} =
               ResponseParser.apply_mappings(%{"chains" => %{}}, rules, target: Bourse.Currency)
    end

    test "handles keyed collections without their authored wrapper" do
      mapping = %{
        "branches" => [
          %{
            "guard" => %{"input_shape" => "array"},
            "field_map" => %{
              "free" => %{
                "kind" => "keyed_collection",
                "collection_key" => "details",
                "index_key" => "ccy",
                "index_coercion" => "safeCurrencyCode",
                "value_key" => "bal",
                "coercion" => "safeNumber"
              }
            }
          }
        ]
      }

      assert {:ok, %Balance{free: %{"USDT" => 2.0}}} =
               ResponseParser.apply_mappings([%{"ccy" => "USDT", "bal" => "2"}], mapping, target: Balance)
    end

    test "drops unmatched collection members and unsupported scale factors" do
      mapping = %{
        "precision" => %{
          "sub_field_map" => %{
            "price" => %{
              "kind" => "collection_member",
              "collection_key" => "filters",
              "match_key" => "filterType",
              "match_value" => "PRICE_FILTER",
              "key" => "tickSize",
              "coercion" => "safeNumber"
            }
          }
        },
        "maker" => %{"key" => "maker", "scale" => "unsupported", "coercion" => "safeNumber"}
      }

      assert {:ok, %Market{precision: %{}, maker: 0.1}} =
               ResponseParser.apply_mappings(%{"filters" => %{}, "maker" => "0.1"}, mapping, target: Market)
    end

    test "formats authored hour and funding-interval values" do
      for {format, value, expected} <- [
            {"hours", "8", "8h"},
            {"hours", 8, "8h"},
            {"funding_interval", "8h", "8h"},
            {"funding_interval", "8", "8h"},
            {"funding_interval", 480, "8h"},
            {"funding_interval", "invalid", nil},
            {"funding_interval", nil, nil}
          ] do
        mapping = %{"interval" => %{"key" => "interval", "format" => format}}

        assert {:ok, %Bourse.FundingRate{interval: ^expected}} =
                 ResponseParser.apply_mappings(%{"interval" => value}, mapping, target: Bourse.FundingRate)
      end
    end

    test "covers keyed guards, numeric scaling, and malformed coercions" do
      guarded = %{
        "branches" => [
          %{
            "guard" => %{"has_key" => "price"},
            "field_map" => %{
              "last" => %{"key" => "price", "scale" => 100, "coercion" => "safeNumber"},
              "timestamp" => %{"key" => "timestamp", "coercion" => "iso8601"}
            }
          }
        ]
      }

      assert {:ok, %Ticker{last: 150.0, timestamp: nil}} =
               ResponseParser.apply_mappings(%{"price" => "1.5", "timestamp" => "invalid"}, guarded, target: Ticker)

      assert {:error, {:invalid_target, String}} =
               ResponseParser.apply_mappings(%{"price" => "1"}, guarded, target: String)

      assert {:error, {:invalid_target, nil}} =
               ResponseParser.apply_mappings(%{"price" => "1"}, guarded, %{})
    end

    test "handles scalar and object keyed-collection fallbacks" do
      rule = %{
        "kind" => "keyed_collection",
        "collection_key" => "details",
        "index_key" => "ccy",
        "index_coercion" => "safeCurrencyCode",
        "operand_keys" => ["total", "used", "reserved"],
        "value_op" => "subtract",
        "coercion" => "safeNumber"
      }

      assert {:ok, %Balance{free: %{"USDT" => 8.0}}} =
               ResponseParser.apply_mappings(
                 %{"ccy" => "usdt", "total" => "10", "used" => "2"},
                 %{"free" => rule},
                 target: Balance
               )

      assert {:ok, %Balance{free: %{}}} =
               ResponseParser.apply_mappings("not-a-collection", %{"free" => rule}, target: Balance)
    end
  end

  defp reference_spec(exchange_id) do
    exchange_id
    |> ReferenceCorpus.spec_path()
    |> Bourse.JsonDocument.decode_file!()
  end

  describe "discriminator path resolution" do
    test "a nil discriminator yields no branch" do
      mapping = %{"last" => %{"kind" => "discriminated", "discriminator" => nil, "true" => %{"key" => "p"}}}
      assert {:ok, %Ticker{last: nil}} = ResponseParser.apply_mappings(%{"p" => "1"}, mapping, target: Ticker)
    end

    test "a path through a non-map intermediate yields no branch" do
      mapping = %{
        "last" => %{"kind" => "discriminated", "discriminator" => "market.inverse.deep", "true" => %{"key" => "p"}}
      }

      assert {:ok, %Ticker{last: nil}} =
               ResponseParser.apply_mappings(%{"p" => "1"}, mapping, target: Ticker, market: %{inverse: true})
    end

    test "a segment that is not an existing atom yields no branch" do
      mapping = %{
        "last" => %{"kind" => "discriminated", "discriminator" => "market.notanatom_qwerty", "true" => %{"key" => "p"}}
      }

      assert {:ok, %Ticker{last: nil}} =
               ResponseParser.apply_mappings(%{"p" => "1"}, mapping, target: Ticker, market: %{"inverse" => true})
    end
  end

  describe "catalog coercion rules" do
    test "every {coercion, format} resolution in the catalog is exercised or ledgered", %{
      catalog_resolutions: catalog
    } do
      refute catalog == %{}

      unaccounted =
        for {{coercion, format} = resolution, witness} <- catalog,
            not Map.has_key?(@coercion_samples, resolution),
            not Map.has_key?(@coercion_divergences, resolution) do
          "#{inspect(coercion)} format=#{inspect(format)} (e.g. #{witness})"
        end

      assert unaccounted == [],
             """
             Coercion resolutions present in the merged runtime rule set but accounted
             for by none of @coercion_samples / @coercion_divergences:

             #{Enum.join(unaccounted, "\n")}

             Add a sample with the value the runtime branch must produce.
             """
    end

    test "every exercised coercion resolution yields a non-nil value of the declared shape", %{
      catalog_resolutions: catalog
    } do
      for {{coercion, format} = resolution, {sample, expected, target, field}} <- @coercion_samples,
          Map.has_key?(catalog, resolution) do
        rule = build_rule(coercion, format)

        assert {:ok, parsed} = ResponseParser.apply_mappings(%{"v" => sample}, %{field => rule}, target: target),
               "#{inspect(resolution)} did not parse"

        actual = Map.fetch!(parsed, String.to_existing_atom(field))

        refute is_nil(actual),
               "#{inspect(resolution)} coerced #{inspect(sample)} to nil — it fell through to a nil-returning branch"

        assert actual == expected,
               "#{inspect(resolution)} coerced #{inspect(sample)} to #{inspect(actual)}, expected #{inspect(expected)}"
      end
    end

    test "every ledgered divergent resolution still reaches a branch and still exists in the catalog", %{
      catalog_resolutions: catalog
    } do
      for {{coercion, format} = resolution, {reason, sample, target, field, shape?}} <- @coercion_divergences do
        assert Map.has_key?(catalog, resolution),
               "@coercion_divergences lists #{inspect(resolution)} (#{reason}) but no catalog rule declares it — drop the stale entry"

        rule = build_rule(coercion, format)

        assert {:ok, parsed} = ResponseParser.apply_mappings(%{"v" => sample}, %{field => rule}, target: target)

        actual = Map.fetch!(parsed, String.to_existing_atom(field))

        refute is_nil(actual), "#{inspect(resolution)} coerced #{inspect(sample)} to nil (#{reason})"
        assert shape?.(actual), "#{inspect(resolution)} coerced #{inspect(sample)} to #{inspect(actual)} (#{reason})"
      end
    end

    test "every safeTimestamp rule resolves its declared source resolution", %{coercion_rules: coercion_rules} do
      rules = runtime_safe_timestamp_rules(coercion_rules)
      refute rules == []

      for {exchange_id, rule} <- rules do
        {source_value, expected} = safe_timestamp_sample(rule)

        assert {:ok, %Ticker{timestamp: timestamp}} =
                 ResponseParser.apply_mappings(
                   source_data(rule, source_value),
                   %{"timestamp" => rule},
                   target: Ticker
                 ),
               "#{exchange_id} #{inspect(rule)} did not parse"

        assert is_integer(timestamp), "#{exchange_id} #{inspect(rule)} returned #{inspect(timestamp)}"
        assert timestamp == expected, "#{exchange_id} #{inspect(rule)} returned #{inspect(timestamp)}"
      end
    end
  end

  describe "catalog instance-state field-map keys" do
    test "funding interval literals carry a provider-evidence carve", %{field_maps: field_maps} do
      violations =
        for {exchange_id, maps} <- field_maps,
            slot <- ["funding_rate", "funding_rate_history"],
            %{"field_map" => %{"interval" => %{"default" => _value} = rule}} <- [maps[slot]],
            not funding_interval_evidence?(rule) do
          "#{exchange_id}.#{slot}.interval"
        end

      assert violations == [],
             "literal funding cadences require carve_id, derivation, and provider evidence: #{inspect(violations)}"
    end

    test "no runtime field map traverses an authored exchange-instance root", %{field_maps: field_maps} do
      assert_no_instance_state_keys!(field_maps)
    end

    # Vacuity guard: the sweep above is green either when the catalog is clean
    # OR when `runtime_field_maps/0` stops finding keys (spec slot renamed, loader
    # change, `field_map` nested under a new shape). Pin the observed extraction
    # so the second case reddens here instead of silently disarming the sweep.
    test "the sweep extracts keys from every runtime venue, not an empty projection", %{field_maps: field_maps} do
      keys = Enum.flat_map(field_maps, fn {_id, maps} -> field_map_keys(maps) end)
      venues_with_keys = Enum.count(field_maps, fn {_id, maps} -> field_map_keys(maps) != [] end)

      assert length(field_maps) == length(Bourse.Spec.exchanges())

      assert venues_with_keys == length(Bourse.Spec.exchanges()),
             "expected field-map keys on every runtime venue, got #{venues_with_keys}"

      assert length(keys) > 100,
             "expected the owned field-map corpus, got #{length(keys)} keys — " <>
               "the instance-state sweep is likely reading the wrong spec slot"
    end

    test "reports the venue, field, and root for an instance-state key" do
      field_maps = %{
        "market" => %{
          "field_map" => %{
            "maker" => %{"coercion" => "safeString", "key" => "fees.trading.maker"}
          }
        }
      }

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_no_instance_state_keys!([{"fixture_venue", field_maps}])
        end

      assert error.message =~
               "fixture_venue field maker key fees.trading.maker traverses instance-state root fees (reference parser this.fees)"
    end
  end

  defp runtime_safe_timestamp_rules(coercion_rules) do
    for {exchange_id, rule} <- coercion_rules, rule["coercion"] == "safeTimestamp" do
      {exchange_id, rule}
    end
  end

  defp runtime_coercion_rules(field_maps) do
    for {exchange_id, maps} <- field_maps,
        rule <- coercion_rules(maps) do
      {exchange_id, rule}
    end
  end

  defp runtime_field_maps do
    for exchange_id <- Bourse.Spec.exchanges() do
      {exchange_id, get_in(Bourse.Spec.load!(exchange_id), ["normalization", "field_maps"]) || %{}}
    end
  end

  defp funding_interval_evidence?(%{
         "evidence" => %{"carve_id" => carve_id, "derivation" => derivation, "source" => source}
       }) do
    Enum.all?([carve_id, derivation, source], &(is_binary(&1) and &1 != ""))
  end

  defp funding_interval_evidence?(_rule), do: false

  defp assert_no_instance_state_keys!(field_maps_by_exchange) do
    violations =
      for {exchange_id, field_maps} <- field_maps_by_exchange,
          {field, key} <- field_map_keys(field_maps),
          root = key_root(key),
          expression when is_binary(expression) <- [@instance_state_roots[root]] do
        "#{exchange_id} field #{field} key #{key} traverses instance-state root #{root} (reference parser #{expression})"
      end

    assert violations == [],
           """
           Runtime field-map keys must traverse HTTP response data, not exchange instance state:

           #{Enum.join(violations, "\n")}

           Add a denylisted root only after confirming the compatibility parser reads `this.<root>`.
           """
  end

  defp field_map_keys(value) when is_map(value) do
    current =
      case value do
        %{"field_map" => field_map} when is_map(field_map) ->
          for {field, rule} <- field_map,
              key <- rule_keys(rule) do
            {field, key}
          end

        _ ->
          []
      end

    current ++ Enum.flat_map(Map.values(value), &field_map_keys/1)
  end

  defp field_map_keys(value) when is_list(value), do: Enum.flat_map(value, &field_map_keys/1)
  defp field_map_keys(_value), do: []

  defp rule_keys(%{"key" => key} = rule) when is_binary(key), do: [key | nested_rule_keys(rule)]
  defp rule_keys(rule) when is_map(rule), do: nested_rule_keys(rule)
  defp rule_keys(rule) when is_list(rule), do: Enum.flat_map(rule, &rule_keys/1)
  defp rule_keys(_rule), do: []

  defp nested_rule_keys(rule) do
    rule
    |> Map.delete("key")
    |> Map.values()
    |> Enum.flat_map(&rule_keys/1)
  end

  defp key_root(key), do: key |> String.split(".", parts: 2) |> hd()

  # `{coercion, format}` is the resolution `Bourse.ResponseParser.coerce/2` branches
  # on, so it is the unit this sweep asserts. The value is a witness string naming
  # one venue + source key carrying that resolution, for failure messages.
  defp catalog_resolutions(coercion_rules) do
    Map.new(coercion_rules, fn {exchange_id, rule} ->
      {{rule["coercion"], Map.get(rule, "format", :absent)}, "#{exchange_id} #{inspect(rule["key"])}"}
    end)
  end

  defp build_rule(coercion, :absent), do: %{"coercion" => coercion, "key" => "v"}
  defp build_rule(coercion, format), do: %{"coercion" => coercion, "format" => format, "key" => "v"}

  defp coercion_rules(value) when is_map(value) do
    current = if is_binary(value["coercion"]), do: [value], else: []
    current ++ Enum.flat_map(Map.values(value), &coercion_rules/1)
  end

  defp coercion_rules(value) when is_list(value), do: Enum.flat_map(value, &coercion_rules/1)
  defp coercion_rules(_value), do: []

  defp safe_timestamp_sample(%{"format" => "ms"}), do: {"1714923704000", 1_714_923_704_000}
  defp safe_timestamp_sample(_rule), do: {"1714923704", 1_714_923_704_000}

  defp source_data(%{"key" => key}, value) when is_binary(key) do
    key
    |> String.split(".")
    |> Enum.reverse()
    |> Enum.reduce(value, fn segment, nested -> %{segment => nested} end)
  end
end
