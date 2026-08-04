defmodule Bourse.AuthoredOrderStatusCoverageTest do
  @moduledoc false
  # Whole-surface invariant: when a venue's order-status vocabulary is closed and
  # provider-documented, the authored enum_map must cover every documented raw value.
  # A missing arm fails here rather than on a consumer account that happens to hold
  # that history row (task 538 / hyperliquid minTradeNtlRejected).
  #
  # Lighter deliberately preserves its provider-native status vocabulary through
  # `enum_passthrough: true`; every other runtime venue has a closed authored map.

  use ExUnit.Case, async: true

  # Documented raw values only — defensive aliases (e.g. hyperliquid "cancelled")
  # may exist in the authored map beyond this set.
  @documented_order_statuses %{
    "alpaca" => %{
      source: "https://docs.alpaca.markets/us/docs/orders-at-alpaca#order-lifecycle",
      values: MapSet.new(~w(
          new partially_filled filled done_for_day canceled expired replaced pending_cancel
          pending_replace accepted pending_new accepted_for_bidding stopped rejected suspended
          calculated held
        ))
    },
    "binance" => %{
      source: "https://github.com/binance/binance-spot-api-docs/blob/master/enums.md#order-status-status",
      values: MapSet.new(~w(
          NEW PENDING_NEW PARTIALLY_FILLED FILLED CANCELED PENDING_CANCEL REJECTED EXPIRED
          EXPIRED_IN_MATCH
        ))
    },
    "binancecoinm" => %{
      source:
        "https://developers.binance.com/en/docs/products/derivatives-trading-coin-futures/common-definition#order-status-status",
      values: MapSet.new(~w(NEW PARTIALLY_FILLED FILLED CANCELED EXPIRED))
    },
    "binanceusdm" => %{
      source:
        "https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures/common-definition#order-status-status",
      values: MapSet.new(~w(NEW PARTIALLY_FILLED FILLED CANCELED REJECTED EXPIRED EXPIRED_IN_MATCH))
    },
    "bybit" => %{
      source: "https://bybit-exchange.github.io/docs/v5/enum#orderstatus",
      values: MapSet.new(~w(
          New PartiallyFilled Untriggered Rejected PartiallyFilledCanceled Filled Cancelled
          Triggered Deactivated
        ))
    },
    "deribit" => %{
      source: "https://docs.deribit.com/api-reference/trading/private-get_order_state",
      values: MapSet.new(~w(open filled rejected cancelled untriggered triggered speed_bumped))
    },
    "derive" => %{
      source: "https://docs.derive.xyz/reference/private-get_open_orders",
      values: MapSet.new(~w(open filled cancelled expired untriggered))
    },
    "hyperliquid" => %{
      source:
        "https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#query-order-status-by-oid-or-cloid",
      values: MapSet.new(~w(
          open filled canceled triggered rejected marginCanceled vaultWithdrawalCanceled
          openInterestCapCanceled selfTradeCanceled reduceOnlyCanceled siblingFilledCanceled
          delistedCanceled liquidatedCanceled scheduledCancel tickRejected minTradeNtlRejected
          perpMarginRejected reduceOnlyRejected badAloPxRejected iocCancelRejected
          badTriggerPxRejected marketOrderNoLiquidityRejected
          positionIncreaseAtOpenInterestCapRejected positionFlipAtOpenInterestCapRejected
          tooAggressiveAtOpenInterestCapRejected openInterestIncreaseRejected
          insufficientSpotBalanceRejected oracleRejected perpMaxPositionRejected
        ))
    },
    "lighter" => %{
      mode: :passthrough,
      source: "https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json",
      values: MapSet.new(~w(
          in-progress pending open filled canceled canceled-post-only canceled-reduce-only
          canceled-position-not-allowed canceled-margin-not-allowed canceled-too-much-slippage
          canceled-not-enough-liquidity canceled-self-trade canceled-expired canceled-oco
          canceled-child canceled-liquidation canceled-invalid-balance
        ))
    },
    "okx" => %{
      source: "https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-details",
      values: MapSet.new(~w(live partially_filled filled canceled mmp_canceled))
    }
  }

  @surfaced_status_mappings %{
    "binance" => %{
      "EXPIRED_IN_MATCH" => "canceled",
      "PENDING_CANCEL" => "open",
      "PENDING_NEW" => "open"
    },
    "binanceusdm" => %{"EXPIRED_IN_MATCH" => "canceled"},
    "derive" => %{"expired" => "canceled"},
    "okx" => %{"mmp_canceled" => "canceled"}
  }

  test "each registered venue's authored order-status enum covers its documented set" do
    for {venue, %{source: source, values: documented}} <- @documented_order_statuses do
      rule =
        venue
        |> Bourse.Spec.load!()
        |> get_in(["normalization", "field_maps", "order", "field_map", "status"])

      assert is_map(rule), "#{venue}: expected an authored order status rule"

      if Map.get(@documented_order_statuses[venue], :mode) == :passthrough do
        assert rule["enum_passthrough"] == true,
               "#{venue}: expected explicit passthrough for provider statuses from #{source}"
      else
        enum_map = rule["enum_map"]

        assert is_map(enum_map) and map_size(enum_map) > 0,
               "#{venue}: expected a non-empty enum_map (not passthrough) for documented statuses from #{source}"

        authored = enum_map |> Map.keys() |> MapSet.new()
        missing = MapSet.difference(documented, authored)

        assert missing == MapSet.new(),
               "#{venue}: authored order.status.enum_map is missing provider-documented values " <>
                 "#{inspect(MapSet.to_list(missing))} (source: #{source})"
      end
    end
  end

  test "coverage registry contains every runtime-supported venue" do
    supported = MapSet.new(Bourse.Registry.exchanges())
    registered = @documented_order_statuses |> Map.keys() |> MapSet.new()

    assert registered == supported
  end

  test "documented gaps surfaced by the whole-runtime invariant have deliberate mappings" do
    for {venue, expected} <- @surfaced_status_mappings do
      enum_map =
        venue
        |> Bourse.Spec.load!()
        |> get_in(["normalization", "field_maps", "order", "field_map", "status", "enum_map"])

      assert Map.take(enum_map, Map.keys(expected)) == expected
    end
  end
end
