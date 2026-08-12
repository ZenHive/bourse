defmodule Bourse.AuthoredLedgerContractCoverageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @ledger_type_path ~w(normalization field_maps ledger_entry field_map type)

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

  @okx_types MapSet.new(~w(
      1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 20 22 24 26 27 28 29 30 32 33
      34 35 37 38 250 251
    ))

  # Values are transcribed from the named provider-owned revisions or, for OKX,
  # from the provider's authenticated enumeration response. They are deliberately
  # not derived from authored specs: this registry is the independent side of the gate.
  @documented_ledger_types %{
    "binance" => %{
      sources: [
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-usds-futures/docs/IncomeType.md",
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-options/docs/AccountFundingFlowResponseInner.md"
      ],
      derivation: "22 USD-M IncomeType literals plus options Account Funding Flow type FEE",
      values: MapSet.put(@binance_usdm_types, "FEE")
    },
    "binancecoinm" => %{
      sources: [
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-coin-futures/docs/IncomeType.md"
      ],
      derivation: "seven COIN-M IncomeType literals",
      values: @binance_coinm_types
    },
    "binanceusdm" => %{
      sources: [
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-usds-futures/docs/IncomeType.md",
        "https://github.com/binance/binance-connector-java/blob/a13868d0e49ee7f3bcc3f3aaed5ca9de8d8e0b35/clients/derivatives-trading-options/docs/AccountFundingFlowResponseInner.md"
      ],
      derivation: "22 USD-M IncomeType literals plus its routed options Funding Flow type FEE",
      values: MapSet.put(@binance_usdm_types, "FEE")
    },
    "bybit" => %{
      sources: [
        "https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/enum.mdx#typeuta-translog",
        "https://github.com/bybit-exchange/docs/blob/5ccd30109fe2eb5a39cf4d864365213658530f6c/docs/v5/enum.mdx#typecontract-translog"
      ],
      derivation: "union of 100 uta-translog and 15 contract-translog rows: 101 unique literals",
      values: @bybit_types
    },
    "hyperliquid" => %{
      sources: [
        "https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions#wsusernonfundingledgerupdates"
      ],
      derivation: "WsLedgerUpdate union, expanding WsVaultDelta's three type literals: 14 values",
      values: @hyperliquid_types
    },
    "okx" => %{
      sources: [
        "GET https://www.okx.com/api/v5/account/subtypes (Get bills types), authenticated demo observation 2026-08-12"
      ],
      derivation: "all 32 top-level type values returned by code=0 data[]",
      values: @okx_types
    }
  }

  @ledger_passthrough_venues MapSet.new(~w(bybit hyperliquid okx))

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
      "AUTO_EXCHANGE" => "trade",
      "BFUSD_REWARD" => "cashback",
      "FEE_RETURN" => "rebate",
      "INSURANCE_CLEAR" => "settlement",
      "STRATEGY_UMFUTURES_TRANSFER" => "transfer"
    },
    "binancecoinm" => %{"INSURANCE_CLEAR" => "settlement"},
    "binanceusdm" => %{
      "AUTO_EXCHANGE" => "trade",
      "BFUSD_REWARD" => "cashback",
      "FEE_RETURN" => "rebate",
      "INSURANCE_CLEAR" => "settlement",
      "STRATEGY_UMFUTURES_TRANSFER" => "transfer"
    }
  }

  test "each authored ledger type enum exactly matches its independently derived provider set" do
    for {venue, %{sources: sources, derivation: derivation, values: documented}} <- @documented_ledger_types do
      enum_map = venue |> Bourse.Spec.load!() |> get_in(@ledger_type_path) |> Map.fetch!("enum_map")
      authored = enum_map |> Map.keys() |> MapSet.new()
      missing = MapSet.difference(documented, authored)
      extra = MapSet.difference(authored, documented)

      assert missing == MapSet.new(),
             "#{venue}: ledger_entry.type is missing #{inspect(MapSet.to_list(missing))} " <>
               "from provider contracts #{inspect(sources)}"

      assert extra == MapSet.new(),
             "#{venue}: ledger_entry.type carries unsupported values #{inspect(MapSet.to_list(extra))}; " <>
               "provider derivation: #{derivation} (#{inspect(sources)})"

      assert derivation != ""
      assert Enum.all?(sources, &String.contains?(&1, "https://"))
    end
  end

  test "the ledger registry covers every runtime venue with an authored type enum map" do
    authored =
      Bourse.Registry.exchanges()
      |> Enum.filter(fn venue ->
        venue
        |> Bourse.Spec.load!()
        |> get_in(@ledger_type_path)
        |> then(&(is_map(&1) and is_map(&1["enum_map"])))
      end)
      |> MapSet.new()

    assert authored == @documented_ledger_types |> Map.keys() |> MapSet.new()
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

  test "generic Binance ledger rules consume every routed income and options bill row shape" do
    spec = Bourse.Spec.load!("binance")
    field_map = get_in(spec, ~w(normalization field_maps ledger_entry field_map))

    assert spec["endpoints"]["unified"]["fetchLedger"] == [
             "dapiPrivateGetIncome",
             "eapiPrivateGetBill",
             "fapiPrivateGetIncome",
             "papiGetCmIncome",
             "papiGetUmIncome"
           ]

    assert authored_source_keys(field_map["type"]) == MapSet.new(~w(incomeType type))
    assert authored_source_keys(field_map["amount"]) == MapSet.new(~w(amount income))
    assert authored_source_keys(field_map["currency"]) == MapSet.new(~w(asset))
    assert authored_source_keys(field_map["direction"]) == MapSet.new(~w(amount income))

    fixture = "test/fixtures/responses/binance/fetch_funding_history.json" |> File.read!() |> Jason.decode!()

    assert fixture["endpoint"] == "fapi/v1/income"
    assert fixture["environment"] == "testnet-demo"

    assert {:ok, [%Bourse.LedgerEntry{} = income | _]} =
             Bourse.Binance.parse_ledger_entry(fixture["body"])

    assert income.type == "fee"
    assert income.amount == -0.01286054
    assert income.currency == "USDT"
    assert income.direction == "out"

    bill = %{
      "amount" => "-0.16518203",
      "asset" => "USDT",
      "createDate" => 1_676_621_042_489,
      "id" => 1_125_899_906_845_701_870,
      "type" => "FEE"
    }

    assert {:ok,
            %Bourse.LedgerEntry{
              amount: -0.16518203,
              currency: "USDT",
              direction: "out",
              type: "fee"
            }} = Bourse.Binance.parse_ledger_entry(bill)

    assert {:ok, %Bourse.LedgerEntry{direction: nil}} =
             Bourse.Binance.parse_ledger_entry(%{bill | "amount" => "0"})
  end

  test "every mapped ledger type is loud unless its venue explicitly preserves new raw values" do
    for {venue, _entry} <- @documented_ledger_types do
      rule =
        venue
        |> Bourse.Spec.load!()
        |> get_in(@ledger_type_path)
        |> Map.put("key", "type")
        |> Map.delete("fallback_keys")

      result =
        Bourse.ResponseParser.apply_mappings(
          %{"type" => "provider-added-type"},
          %{"type" => rule},
          target: Bourse.LedgerEntry,
          venue: venue
        )

      if MapSet.member?(@ledger_passthrough_venues, venue) do
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
