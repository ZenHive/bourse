defmodule Bourse.AuthoredLedgerContractCoverageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @ledger_type_path ~w(normalization field_maps ledger_entry field_map type)

  @binance_family_types MapSet.new(~w(
      API_REBATE AUTO_EXCHANGE COIN_SWAP_DEPOSIT COIN_SWAP_WITHDRAW COMMISSION
      COMMISSION_REBATE CONTEST_REWARD CONTRACT CROSS_COLLATERAL_TRANSFER
      DELIVERED_SETTELMENT FEE FUNDING_FEE INSURANCE_CLEAR INTERNAL_TRANSFER
      OPTIONS_PREMIUM_FEE OPTIONS_SETTLE_PROFIT POSITION_LIMIT_INCREASE_FEE
      REALIZED_PNL REFERRAL_KICKBACK TRANSFER WELCOME_BONUS
    ))

  # Each registry entry cites the operation contract that emits the row. A venue
  # enum page may supplement that contract, but never replaces it; change logs are
  # included where they add values absent from the endpoint page.
  @documented_ledger_types %{
    "binance" => %{
      sources: [
        "https://developers.binance.com/docs/derivatives/coin-margined-futures/account/rest-api/Get-Income-History",
        "https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/Get-Income-History",
        "https://developers.binance.com/docs/derivatives/usds-margined-futures/change-log"
      ],
      values: @binance_family_types
    },
    "binancecoinm" => %{
      sources: [
        "https://developers.binance.com/docs/derivatives/coin-margined-futures/account/rest-api/Get-Income-History"
      ],
      values: MapSet.new(~w(
          TRANSFER WELCOME_BONUS FUNDING_FEE REALIZED_PNL COMMISSION
          INSURANCE_CLEAR DELIVERED_SETTELMENT
        ))
    },
    "binanceusdm" => %{
      sources: [
        "https://developers.binance.com/docs/derivatives/usds-margined-futures/account/rest-api/Get-Income-History",
        "https://developers.binance.com/docs/derivatives/usds-margined-futures/change-log"
      ],
      values: @binance_family_types
    },
    "bybit" => %{
      sources: [
        "https://bybit-exchange.github.io/docs/v5/account/transaction-log",
        "https://bybit-exchange.github.io/docs/v5/enum#transactionlogtype",
        "https://bybit-exchange.github.io/docs/changelog/v5"
      ],
      values: MapSet.new(~w(
          BONUS CURRENCY_BUY CURRENCY_SELL Commission DELIVERY Deposit
          ExchangeOrderDeposit ExchangeOrderWithdraw FEE_REFUND INTEREST LIQUIDATION
          Prize RealisedPNL Refund SETTLEMENT TRADE TRANSFER_IN TRANSFER_OUT Withdraw
        ))
    },
    "hyperliquid" => %{
      sources: [
        "https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#retrieve-a-users-ledger-updates"
      ],
      values: MapSet.new(~w(accountClassTransfer internalTransfer))
    },
    "okx" => %{
      sources: [
        "https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-bills-details-last-7-days",
        "https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-bills-details-last-3-months",
        "https://www.okx.com/docs-v5/en/#change-log"
      ],
      values: MapSet.new(~w(1 2 3 4 5 6 7 8 9 10 11))
    }
  }

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
    "binance" => %{"AUTO_EXCHANGE" => "trade", "INSURANCE_CLEAR" => "settlement"},
    "binancecoinm" => %{"INSURANCE_CLEAR" => "settlement"},
    "binanceusdm" => %{"AUTO_EXCHANGE" => "trade", "INSURANCE_CLEAR" => "settlement"}
  }

  test "each authored ledger type enum covers its provider-documented contract set" do
    for {venue, %{sources: sources, values: documented}} <- @documented_ledger_types do
      enum_map = venue |> Bourse.Spec.load!() |> get_in(@ledger_type_path) |> Map.fetch!("enum_map")
      missing = MapSet.difference(documented, enum_map |> Map.keys() |> MapSet.new())

      assert missing == MapSet.new(),
             "#{venue}: ledger_entry.type is missing #{inspect(MapSet.to_list(missing))} " <>
               "from provider contracts #{inspect(sources)}"

      assert Enum.all?(sources, &String.starts_with?(&1, "https://"))
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

      assert direction_rule == %{
               "key" => "income",
               "kind" => "sign_direction",
               "negative" => "out",
               "positive" => "in",
               "zero" => "in"
             }
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
