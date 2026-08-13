defmodule Bourse.AuthoredLedgerContractCoverageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @ledger_type_path ~w(normalization field_maps ledger_entry field_map type)

  @registered_ledger_types MapSet.new(~w(
      trade fee deposit withdrawal transfer funding_fee realized_pnl liquidation settlement
      interest rebate commission cashback referral conversion
    ))

  @binance_usdm_types MapSet.new(~w(
      API_REBATE AUTO_EXCHANGE BFUSD_REWARD COIN_SWAP_DEPOSIT COIN_SWAP_WITHDRAW
      COMMISSION COMMISSION_REBATE CONTEST_REWARD CROSS_COLLATERAL_TRANSFER
      DELIVERED_SETTELMENT FEE_RETURN FUNDING_FEE INSURANCE_CLEAR INTERNAL_TRANSFER
      OPTIONS_PREMIUM_FEE OPTIONS_SETTLE_PROFIT POSITION_LIMIT_INCREASE_FEE
      REALIZED_PNL REFERRAL_KICKBACK STRATEGY_UMFUTURES_TRANSFER TRANSFER WELCOME_BONUS
    ))

  @binance_coinm_types MapSet.new(~w(
      COMMISSION DELIVERED_SETTELMENT FUNDING_FEE INSURANCE_CLEAR REALIZED_PNL
      TRANSFER WELCOME_BONUS
    ))

  @bybit_types MapSet.new(~w(
      ADL AIRDROP ALPHA_SMALL_TOKEN_REFUND AUTO_BUY_LIABILITY_INS_LOAN AUTO_DEDUCTION
      AUTO_INTEREST_REPAYMENT_INS_LOAN AUTO_PRINCIPLE_REPAYMENT_INS_LOAN
      AUTO_SOLD_COLLATERAL_INS_LOAN BONUS BONUS_RECOLLECT BONUS_TRANSFER_IN
      BONUS_TRANSFER_OUT BORROW BORROWED_AMOUNT_INS_LOAN BROKER_ABACCOUNT_FEE
      CLASSIC_WEALTH_MANAGEMENT_SUBSCRIPTION CONVERT CURRENCY_BUY CURRENCY_SELL
      CUSTODY_CASH_RECOVER_TR CUSTODY_LOCK CUSTODY_NETWORK_FEE CUSTODY_SETTLE_FEE
      CUSTODY_UNLOCK CUSTODY_UNLOCK_REFUND DBS_CASH_IN DBS_CASH_IN_TR DBS_CASH_OUT
      DBS_CASH_OUT_TR DEFI_INVESTMENT_REDEMPTION DEFI_INVESTMENT_REFUND
      DEFI_INVESTMENT_SUBSCRIPTION DELIVERY EARNING_REDEMPTION_BUY
      EARNING_REDEMPTION_SELL FEE_REFUND FIXED_STAKING_REFUND FIXED_STAKING_SUBSCRIPTION
      FLEXIBLE_STAKING_REDEMPTION FLEXIBLE_STAKING_REFUND FLEXIBLE_STAKING_SUBSCRIPTION
      FLOATING_TO_FIXED_BORROW FLOATING_TO_FIXED_REPAY IDN_CONVERT_IN IDN_CONVERT_OUT
      INSTITUTION_EXCHANGE_BUY INSTITUTION_EXCHANGE_SELL INSTITUTION_LIQ_INTEREST_OUT
      INSTITUTION_LIQ_PRINCIPAL_OUT INSTITUTION_LOAN_IN INSTITUTION_LOAN_RESERVE_IN
      INSTITUTION_LOAN_RESERVE_OUT INSTITUTION_LOAN_TRANSFER_IN
      INSTITUTION_LOAN_TRANSFER_OUT INSTITUTION_LOAN_WITHOUT_WITHDRAW
      INSTITUTION_PAYBACK_INTEREST_OUT INSTITUTION_PAYBACK_PRINCIPAL_OUT INTEREST
      INTEREST_REPAYMENT_INS_LOAN LIQUIDATION LIQUIDITY_MINING_REFUND
      LIQUIDITY_MINING_SUBSCRIPTION LOANS_BORROW_FUNDS LOANS_PLEDGE_ASSET
      ONCHAINEARN_REDEMPTION ONCHAINEARN_REFUND ONCHAINEARN_SUBSCRIPTION Others
      PEF_PROFIT_SHARE PEF_TRANSFER_IN PEF_TRANSFER_OUT PLATFORM_TOKEN_MNT_LIQRECALLEDMMNT
      PLATFORM_TOKEN_MNT_LIQRETURNEDMNT PREMARKET_DELIVERY_BUY_NEW_COIN
      PREMARKET_DELIVERY_PLEDGE_BACK PREMARKET_DELIVERY_PLEDGE_PAY_SELLER
      PREMARKET_DELIVERY_SELL_NEW_COIN PREMARKET_ROLLBACK_PLEDGE_BACK
      PREMARKET_ROLLBACK_PLEDGE_PENALTY_TO_BUYER PREMARKET_TRANSFER_OUT
      PREMIMUM_WEALTH_MANAGEMENT_REFUND PREMIMUM_WEALTH_MANAGEMENT_SUBSCRIPTION
      PRINCIPLE_REPAYMENT_INS_LOAN PWM_REFUND PWM_SUBSCRIPTION REPAY SETTLEMENT
      SPOT_REPAYMENT_BUY SPOT_REPAYMENT_SELL SPREAD_FEE_OUT STRUCTURE_PRODUCT_REFUND
      STRUCTURE_PRODUCT_SUBSCRIPTION TOKENS_REDEMPTION TOKENS_SUBSCRIPTION TRADE
      TRANSFER_IN TRANSFER_IN_INS_LOAN TRANSFER_OUT TRANSFER_OUT_INS_LOAN
      TWAP_BUDGET_AIRDROP TWAP_BUDGET_RECALL
    ))

  @hyperliquid_types MapSet.new(~w(
      accountClassTransfer deposit internalTransfer liquidation rewardsClaim spotGenesis
      spotTransfer subAccountTransfer vaultCreate vaultDeposit vaultDistribution
      vaultLeaderCommission vaultWithdraw withdraw
    ))

  @okx_account_types MapSet.new(~w(
      1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 20 22 24 26 27 28 29 30 32 33
      34 35 37 38 250 251
    ))

  @okx_asset_types MapSet.new(~w(
      1 2 13 20 21 22 23 28 47 48 49 68 72 73 74 75 76 77 78 80 82 83 84 89
      116 117 118 124 130 131 132 133 134 135 137 138 139 146 150 151 152 160
      161 162 163 172 173 174 175 176 177 178 179 180 181 185 187 189 195 196
      197 198 199 200 202 203 204 205 207 208 209 210 212 215 217 218 220 221
      222 223 225 226 227 228 229 232 233 240 241 242 243 249 250 251 252 263
      265 266 270 271 272 273 284 285 286 287 288 289 299 300 303 311 313 314
      315 328 329 330 331 332 333 339 340 341 342 343 344 345 346 347 348 349
      350 351 354 361 372 373 400 408 476 477 509 511 516 518 523
    ))

  # Values are transcribed from the named provider-owned revisions. They are
  # deliberately not derived from authored specs: this registry is the
  # independent side of the gate, scoped to the route where each vocabulary applies.
  @documented_ledger_types [
    %{
      venue: "binance",
      scope: "income",
      path: @ledger_type_path,
      routes: ~w(income cm/income um/income),
      mode: :exact,
      sources: [
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-usds-futures/docs/IncomeType.md"
      ],
      derivation: "22 enumerated USD-M IncomeType literals",
      values: @binance_usdm_types,
      venue_specific: MapSet.new()
    },
    %{
      venue: "binance",
      scope: "options bill",
      path: ~w(normalization field_maps ledger_entry route_field_maps bill type),
      routes: ["bill"],
      mode: :passthrough,
      sources: [
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-options/docs/AccountFundingFlowResponseInner.md"
      ],
      derivation: "0 enumerated literals; the provider contract defines type as a free String",
      values: MapSet.new(),
      venue_specific: MapSet.new()
    },
    %{
      venue: "binancecoinm",
      scope: "income",
      path: @ledger_type_path,
      routes: [],
      mode: :exact,
      sources: [
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-coin-futures/docs/IncomeType.md"
      ],
      derivation: "7 enumerated COIN-M IncomeType literals",
      values: @binance_coinm_types,
      venue_specific: MapSet.new()
    },
    %{
      venue: "binanceusdm",
      scope: "income",
      path: @ledger_type_path,
      routes: ~w(income cm/income um/income),
      mode: :exact,
      sources: [
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-usds-futures/docs/IncomeType.md"
      ],
      derivation: "22 enumerated USD-M IncomeType literals",
      values: @binance_usdm_types,
      venue_specific: MapSet.new()
    },
    %{
      venue: "binanceusdm",
      scope: "options bill",
      path: ~w(normalization field_maps ledger_entry route_field_maps bill type),
      routes: ["bill"],
      mode: :passthrough,
      sources: [
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-options/docs/AccountFundingFlowResponseInner.md"
      ],
      derivation: "0 enumerated literals; the provider contract defines type as a free String",
      values: MapSet.new(),
      venue_specific: MapSet.new()
    },
    %{
      venue: "bybit",
      scope: "transaction log",
      path: @ledger_type_path,
      routes: [],
      mode: :passthrough,
      sources: [
        "https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/enum.mdx#typeuta-translog",
        "https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/enum.mdx#typecontract-translog"
      ],
      derivation: "101 unique literals from the UTA and contract transaction-log union",
      values: @bybit_types,
      venue_specific: MapSet.new(~w(Prize transaction))
    },
    %{
      venue: "hyperliquid",
      scope: "non-funding ledger updates",
      path: @ledger_type_path,
      routes: [],
      mode: :passthrough,
      sources: [
        "https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions#wsusernonfundingledgerupdates"
      ],
      derivation: "14 literals in the WsLedgerUpdate union after expanding WsVaultDelta",
      values: @hyperliquid_types,
      venue_specific: MapSet.new(~w(withdraw))
    },
    %{
      venue: "okx",
      scope: "trading-account bills",
      path: @ledger_type_path,
      routes: ["account/bills", "account/bills-archive"],
      mode: :passthrough,
      sources: [
        "https://www.okx.com/api/v5/account/subtypes"
      ],
      derivation: "32 top-level type values returned by the Get bills types operation",
      values: @okx_account_types,
      venue_specific: MapSet.new(~w(
          adl overloss_recovery ddh quick_margin borrowing one_click_repay move_position
          loans corporate_action usdg_rewards profit_share_payment profit_share_refund
        )),
      venue_specific_format: :snake_case
    },
    %{
      venue: "okx",
      scope: "funding-account asset bills",
      path: ~w(normalization field_maps ledger_entry route_field_maps asset/bills type),
      routes: ["asset/bills"],
      mode: :passthrough,
      sources: [
        "https://www.okx.com/docs-v5/en/#funding-account-rest-api-asset-bills-details"
      ],
      derivation: "147 unique type values in the funding-account Asset bills details table",
      values: @okx_asset_types,
      venue_specific: MapSet.new()
    }
  ]

  @required_source_slots [
    %{
      venue: "lighter",
      path: ~w(normalization field_maps transaction field_map currency),
      authored_sources: ["asset_id"],
      provider_sources: ["DepositHistoryItem.asset_id", "WithdrawHistoryItem.asset_id"],
      citations: [
        "https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json"
      ]
    },
    %{
      venue: "lighter",
      path: ~w(normalization field_maps transaction field_map type),
      authored_sources: ["_bourse_type"],
      provider_sources: ["fetchDeposits operation", "fetchWithdrawals operation"],
      citations: [
        "https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json"
      ]
    },
    %{
      venue: "lighter",
      path: ~w(normalization field_maps transfer field_map currency),
      authored_sources: ["asset_id"],
      provider_sources: ["TransferHistoryItem.asset_id"],
      citations: [
        "https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json"
      ]
    },
    %{
      venue: "lighter",
      path: ~w(normalization field_maps transfer field_map fee),
      authored_sources: ["asset_id", "fee"],
      provider_sources: ["TransferHistoryItem.asset_id", "TransferHistoryItem.fee"],
      citations: [
        "https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json"
      ]
    }
  ]

  @surfaced_binance_mappings %{
    "binance" => %{
      "AUTO_EXCHANGE" => "conversion",
      "BFUSD_REWARD" => "cashback",
      "FEE_RETURN" => "rebate",
      "FUNDING_FEE" => "funding_fee",
      "INSURANCE_CLEAR" => "settlement",
      "OPTIONS_PREMIUM_FEE" => "fee",
      "REALIZED_PNL" => "realized_pnl",
      "STRATEGY_UMFUTURES_TRANSFER" => "transfer"
    },
    "binancecoinm" => %{
      "FUNDING_FEE" => "funding_fee",
      "INSURANCE_CLEAR" => "settlement",
      "REALIZED_PNL" => "realized_pnl"
    },
    "binanceusdm" => %{
      "AUTO_EXCHANGE" => "conversion",
      "BFUSD_REWARD" => "cashback",
      "FEE_RETURN" => "rebate",
      "FUNDING_FEE" => "funding_fee",
      "INSURANCE_CLEAR" => "settlement",
      "OPTIONS_PREMIUM_FEE" => "fee",
      "REALIZED_PNL" => "realized_pnl",
      "STRATEGY_UMFUTURES_TRANSFER" => "transfer"
    }
  }

  @okx_account_mappings %{
    "1" => "transfer",
    "2" => "trade",
    "3" => "settlement",
    "4" => "conversion",
    "5" => "liquidation",
    "6" => "transfer",
    "7" => "interest",
    "8" => "funding_fee",
    "9" => "adl",
    "10" => "overloss_recovery",
    "11" => "conversion",
    "12" => "transfer",
    "13" => "ddh",
    "14" => "trade",
    "15" => "quick_margin",
    "16" => "borrowing",
    "20" => "conversion",
    "27" => "conversion",
    "28" => "conversion",
    "29" => "one_click_repay",
    "30" => "trade",
    "32" => "move_position",
    "33" => "loans",
    "34" => "settlement",
    "35" => "transfer",
    "37" => "corporate_action",
    "38" => "usdg_rewards",
    "250" => "profit_share_payment",
    "251" => "profit_share_refund"
  }

  @okx_asset_mappings %{
    "1" => "deposit",
    "2" => "withdrawal",
    "20" => "transfer",
    "21" => "transfer",
    "22" => "transfer",
    "23" => "transfer",
    "130" => "transfer",
    "131" => "transfer"
  }

  test "each route-scoped ledger registry has the provider coverage its openness permits" do
    for entry <- @documented_ledger_types do
      rule = entry.venue |> Bourse.Spec.load!() |> get_in(entry.path)
      enum_map = Map.get(rule, "enum_map", %{})
      authored = enum_map |> Map.keys() |> MapSet.new()
      missing = MapSet.difference(entry.values, authored)
      extra = MapSet.difference(authored, entry.values)

      if entry.mode == :exact do
        assert missing == MapSet.new(),
               "#{entry.venue}/#{entry.scope}: missing provider values #{inspect(MapSet.to_list(missing))}"

        assert rule["enum_passthrough"] != true
      else
        assert rule["enum_passthrough"] == true
      end

      assert extra == MapSet.new(),
             "#{entry.venue}/#{entry.scope}: unsupported authored values #{inspect(MapSet.to_list(extra))}"

      refute Enum.any?(enum_map, fn {raw, normalized} -> raw == normalized end),
             "#{entry.venue}/#{entry.scope}: passthrough makes identity enum padding redundant"

      assert Enum.all?(entry.sources, &String.starts_with?(&1, "https://"))

      [_, stated_count] = Regex.run(~r/^(\d+)\b/, entry.derivation)
      assert String.to_integer(stated_count) == MapSet.size(entry.values)
    end
  end

  test "every mapped ledger label is registered or explicitly venue-specific" do
    for entry <- @documented_ledger_types do
      mapped_values =
        entry.venue
        |> Bourse.Spec.load!()
        |> get_in(entry.path)
        |> Map.get("enum_map", %{})
        |> Map.values()
        |> MapSet.new()

      permitted_values = MapSet.union(@registered_ledger_types, entry.venue_specific)
      unregistered = MapSet.difference(mapped_values, permitted_values)
      unused_declarations = MapSet.difference(entry.venue_specific, mapped_values)

      assert unregistered == MapSet.new(),
             "#{entry.venue}/#{entry.scope}: unregistered mapped labels #{inspect(MapSet.to_list(unregistered))}"

      assert unused_declarations == MapSet.new(),
             "#{entry.venue}/#{entry.scope}: unused venue-specific labels " <>
               inspect(MapSet.to_list(unused_declarations))

      assert MapSet.disjoint?(@registered_ledger_types, entry.venue_specific)

      if entry[:venue_specific_format] == :snake_case do
        assert Enum.all?(entry.venue_specific, &Regex.match?(~r/^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/, &1))
      end
    end
  end

  test "LedgerEntry and Descripex enumerate the two-class ledger type contract" do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Bourse.LedgerEntry)
    descripex_doc = Bourse.__api__(:fetch_ledger).hints.description

    for type <- @registered_ledger_types do
      assert moduledoc =~ "`#{type}`"
      assert descripex_doc =~ type
    end

    assert moduledoc =~ "one of two classes"
    assert moduledoc =~ "venue-faithful snake_case"
    assert moduledoc =~ "always retained in `info`"
    assert descripex_doc =~ "venue-faithful snake_case"
    assert descripex_doc =~ "always retained in info"
  end

  test "the registry scopes every authored ledger type rule and every routed endpoint" do
    registered_rules = MapSet.new(@documented_ledger_types, &{&1.venue, &1.path})

    authored_rules =
      Bourse.Registry.exchanges()
      |> Enum.flat_map(fn venue -> venue |> Bourse.Spec.load!() |> ledger_type_rule_paths() |> Enum.map(&{venue, &1}) end)
      |> MapSet.new()

    assert registered_rules == authored_rules

    for venue <- ~w(binance binanceusdm okx) do
      registered_routes =
        @documented_ledger_types
        |> Enum.filter(&(&1.venue == venue))
        |> Enum.flat_map(& &1.routes)
        |> MapSet.new()

      authored_routes =
        venue
        |> Bourse.Spec.load!()
        |> get_in(~w(normalization field_maps ledger_entry route_field_maps))
        |> Map.keys()
        |> MapSet.new()

      assert registered_routes == authored_routes
    end
  end

  test "the registered OKX subtype response re-derives its account-bills vocabulary (key membership; translations are authored)" do
    fixture = "test/fixtures/responses/okx/account_subtypes.json" |> File.read!() |> Jason.decode!()
    rows = fixture["body"]["data"]
    recorded_types = MapSet.new(rows, & &1["type"])
    named_types = rows |> Enum.reject(&(&1["typeDesc"] == "")) |> MapSet.new(& &1["type"])

    registry = Enum.find(@documented_ledger_types, &(&1.venue == "okx" and &1.scope == "trading-account bills"))
    enum_map = "okx" |> Bourse.Spec.load!() |> get_in(@ledger_type_path) |> Map.fetch!("enum_map")

    assert fixture["endpoint"] == "api/v5/account/subtypes"
    assert recorded_types == registry.values
    assert MapSet.new(Map.keys(enum_map)) == named_types
    assert enum_map == @okx_account_mappings
    refute Enum.any?(enum_map, fn {raw, normalized} -> raw == normalized end)

    # Every label outside the registered set must be the venue's own typeDesc, rendered
    # snake_case — the carve register claims faithfulness, so derive it rather than trust it.
    recorded_descriptions = Map.new(rows, &{&1["type"], &1["typeDesc"]})

    for {type, label} <- enum_map, MapSet.member?(registry.venue_specific, label) do
      assert label == snake_case(Map.fetch!(recorded_descriptions, type)),
             "okx bill type #{type}: venue-specific label #{inspect(label)} is not the snake_case " <>
               "rendering of the recorded typeDesc #{inspect(Map.fetch!(recorded_descriptions, type))}"
    end
  end

  defp snake_case(description) do
    description
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  test "the surfaced Binance gaps and signed direction have deliberate authored mappings" do
    for {venue, expected} <- @surfaced_binance_mappings do
      spec = Bourse.Spec.load!(venue)
      type_rule = get_in(spec, @ledger_type_path)
      direction_rule = get_in(spec, ~w(normalization field_maps ledger_entry field_map direction))

      for {raw, unified} <- expected do
        assert type_rule["enum_map"][raw] == unified
      end

      assert direction_rule["negative"] == "out"
      assert direction_rule["positive"] == "in"
      assert direction_rule["zero"] == nil
    end
  end

  test "shared economic events emit the registered value" do
    assert {:ok, %Bourse.LedgerEntry{type: "funding_fee"}} =
             Bourse.Binanceusdm.parse_ledger_entry(%{"incomeType" => "FUNDING_FEE"}, route: "income")

    assert {:ok, %Bourse.LedgerEntry{type: "funding_fee"}} =
             Bourse.Okx.parse_ledger_entry(%{"type" => "8"}, route: "account/bills")

    assert {:ok, %Bourse.LedgerEntry{type: "realized_pnl"}} =
             Bourse.Binancecoinm.parse_ledger_entry(%{"incomeType" => "REALIZED_PNL"})

    assert {:ok, %Bourse.LedgerEntry{type: "fee"}} =
             Bourse.Binanceusdm.parse_ledger_entry(%{"incomeType" => "OPTIONS_PREMIUM_FEE"}, route: "income")
  end

  test "OKX asset bills normalize their documented deposit, withdrawal, and transfer arms" do
    enum_map =
      "okx"
      |> Bourse.Spec.load!()
      |> get_in(~w(normalization field_maps ledger_entry route_field_maps asset/bills type enum_map))

    assert enum_map == @okx_asset_mappings
  end

  test "generic Binance ledger rules consume every routed income and options bill row shape" do
    spec = Bourse.Spec.load!("binance")
    mapping = get_in(spec, ~w(normalization field_maps ledger_entry))
    income_field_map = routed_field_map(mapping, "income")
    options_field_map = routed_field_map(mapping, "bill")

    assert spec["endpoints"]["unified"]["fetchLedger"] == [
             "dapiPrivateGetIncome",
             "eapiPrivateGetBill",
             "fapiPrivateGetIncome",
             "papiGetCmIncome",
             "papiGetUmIncome"
           ]

    assert authored_source_keys(income_field_map["type"]) == MapSet.new(~w(incomeType type))
    assert authored_source_keys(income_field_map["amount"]) == MapSet.new(~w(amount income))
    assert authored_source_keys(income_field_map["currency"]) == MapSet.new(~w(asset))
    assert authored_source_keys(income_field_map["direction"]) == MapSet.new(~w(amount income))
    assert authored_source_keys(options_field_map["type"]) == MapSet.new(~w(type))
    assert options_field_map["type"]["enum_passthrough"] == true

    fixture = "test/fixtures/responses/binance/fetch_funding_history.json" |> File.read!() |> Jason.decode!()

    assert fixture["endpoint"] == "fapi/v1/income"
    assert fixture["environment"] == "testnet-demo"

    assert {:ok, [%Bourse.LedgerEntry{} = income | _]} =
             Bourse.Binance.parse_ledger_entry(fixture["body"], route: "income")

    assert income.type == "funding_fee"
    assert income.amount == -0.01286054
    assert income.currency == "USDT"
    assert income.direction == "out"

    bill = %{
      "amount" => "-0.16518203",
      "asset" => "USDT",
      "createDate" => 1_676_621_042_489,
      "id" => 1_125_899_906_845_701_870,
      "type" => "provider-added-option-type"
    }

    assert {:ok,
            %Bourse.LedgerEntry{
              amount: -0.16518203,
              currency: "USDT",
              direction: "out",
              type: "provider-added-option-type"
            }} = Bourse.Binance.parse_ledger_entry(bill, route: "bill")

    assert {:ok, %Bourse.LedgerEntry{direction: nil}} =
             Bourse.Binance.parse_ledger_entry(%{bill | "amount" => "0"}, route: "bill")
  end

  test "each scoped ledger type rule is loud or preserving exactly as registered" do
    for entry <- @documented_ledger_types do
      venue = entry.venue

      rule =
        venue
        |> Bourse.Spec.load!()
        |> get_in(entry.path)
        |> Map.put("key", "type")
        |> Map.delete("fallback_keys")

      result =
        Bourse.ResponseParser.apply_mappings(
          %{"type" => "provider-added-type"},
          %{"type" => rule},
          target: Bourse.LedgerEntry,
          venue: venue
        )

      if entry.mode == :passthrough do
        assert {:ok, %Bourse.LedgerEntry{type: "provider-added-type"}} = result
      else
        assert {:error, {:unmapped_ledger_type, %{venue: ^venue, field: "type", raw_value: "provider-added-type"}}} =
                 result
      end
    end
  end

  test "provider-required sources cannot remain authored as nil unified slots" do
    for entry <- @required_source_slots do
      rule = entry.venue |> Bourse.Spec.load!() |> get_in(entry.path)

      assert is_map(rule),
             "#{entry.venue}: #{Enum.join(entry.path, ".")} is nil despite required provider sources " <>
               "#{inspect(entry.provider_sources)} (#{inspect(entry.citations)})"

      authored = authored_source_keys(rule)

      for source <- entry.authored_sources do
        assert MapSet.member?(authored, source),
               "#{entry.venue}: #{Enum.join(entry.path, ".")} does not consume required source #{source}"
      end
    end
  end

  defp ledger_type_rule_paths(spec) do
    mapping = get_in(spec, ~w(normalization field_maps ledger_entry)) || %{}

    base_paths =
      if ledger_type_rule?(get_in(mapping, ~w(field_map type))), do: [@ledger_type_path], else: []

    route_paths =
      mapping
      |> Map.get("route_field_maps", %{})
      |> Enum.flat_map(fn {route, field_map} ->
        if ledger_type_rule?(field_map["type"]) do
          [~w(normalization field_maps ledger_entry route_field_maps) ++ [route, "type"]]
        else
          []
        end
      end)

    base_paths ++ route_paths
  end

  defp ledger_type_rule?(rule) when is_map(rule) do
    is_map(rule["enum_map"]) or rule["enum_passthrough"] == true
  end

  defp ledger_type_rule?(_rule), do: false

  defp routed_field_map(mapping, route) do
    Map.merge(mapping["field_map"], get_in(mapping, ["route_field_maps", route]))
  end

  defp authored_source_keys(rule) do
    rule
    |> nested_maps()
    |> Enum.flat_map(fn map ->
      map
      |> Map.take(["key", "key2", "fallback_keys"])
      |> Map.values()
      |> List.flatten()
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp nested_maps(map) when is_map(map), do: [map | Enum.flat_map(Map.values(map), &nested_maps/1)]
  defp nested_maps(list) when is_list(list), do: Enum.flat_map(list, &nested_maps/1)
  defp nested_maps(_value), do: []
end
