defmodule Bourse.AuthoredOrderStatusCoverageTest do
  @moduledoc false
  # Whole-surface invariant: when a venue's order-status vocabulary is closed and
  # provider-documented, the authored enum_map must cover every documented raw value.
  # A missing arm fails here rather than on a consumer account that happens to hold
  # that history row (task 538 / hyperliquid minTradeNtlRejected).
  #
  use ExUnit.Case, async: true

  @order_status_path ~w(normalization field_maps order field_map status)

  # Governed, exact, and intended only to shrink. Each entry identifies one field
  # whose provider-native vocabulary is deliberately open beyond its mapped aliases.
  @enum_passthrough_exemptions %{
    {"bybit", ~w(normalization field_maps ledger_entry field_map type)} => %{
      reason:
        "The complete provider transaction-log vocabulary is mapped; additional provider-native ledger types retain their identifier.",
      tracking: "Task 598; docs/authored-spec-carves/bybit.md C-T598b"
    },
    {"hyperliquid", ~w(normalization field_maps ledger_entry field_map type)} => %{
      reason:
        "All 14 documented delta types are mapped; additional provider-native ledger types retain their identifier.",
      tracking: "Task 598; docs/authored-spec-carves/hyperliquid.md C-T598d"
    },
    {"okx", ~w(normalization field_maps ledger_entry field_map type)} => %{
      reason:
        "The live provider bill-type enumeration is mapped; additional provider-native ledger types retain their identifier.",
      tracking: "Task 598; docs/authored-spec-carves/okx.md C-T598c"
    },
    {"okx", ~w(normalization field_maps order field_map type)} => %{
      reason:
        "Known OKX ordType values normalize to unified types while additional provider-native order styles retain their identifier.",
      tracking: "Task 552; docs/authored-spec-carves/okx.md C-T382a"
    }
  }

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
      # The common-definition page omits EXPIRED_IN_MATCH, but COIN-M ships STP
      # (selfTradePreventionMode, default EXPIRE_MAKER) and the STP FAQ + change log
      # document EXPIRED_IN_MATCH as its resulting order status:
      # https://developers.binance.com/docs/derivatives/usds-margined-futures/faq/stp-faq
      source:
        "https://developers.binance.com/en/docs/products/derivatives-trading-coin-futures/common-definition#order-status-status",
      values: MapSet.new(~w(NEW PARTIALLY_FILLED FILLED CANCELED EXPIRED EXPIRED_IN_MATCH))
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
    "binancecoinm" => %{"EXPIRED_IN_MATCH" => "canceled"},
    "binanceusdm" => %{"EXPIRED_IN_MATCH" => "canceled"},
    "derive" => %{"expired" => "canceled"},
    "lighter" => %{
      "canceled" => "canceled",
      "canceled-child" => "canceled",
      "canceled-expired" => "canceled",
      "canceled-invalid-balance" => "canceled",
      "canceled-liquidation" => "canceled",
      "canceled-margin-not-allowed" => "canceled",
      "canceled-not-enough-liquidity" => "canceled",
      "canceled-oco" => "canceled",
      "canceled-position-not-allowed" => "canceled",
      "canceled-post-only" => "canceled",
      "canceled-reduce-only" => "canceled",
      "canceled-self-trade" => "canceled",
      "canceled-too-much-slippage" => "canceled",
      "filled" => "closed",
      "in-progress" => "open",
      "open" => "open",
      "pending" => "open"
    },
    "okx" => %{"mmp_canceled" => "canceled"}
  }

  test "each registered venue's authored order-status enum covers its documented set" do
    for {venue, %{source: source, values: documented}} <- @documented_order_statuses do
      rule =
        venue
        |> Bourse.Spec.load!()
        |> get_in(["normalization", "field_maps", "order", "field_map", "status"])

      assert is_map(rule), "#{venue}: expected an authored order status rule"

      case rule["enum_map"] do
        enum_map when is_map(enum_map) and map_size(enum_map) > 0 ->
          authored = enum_map |> Map.keys() |> MapSet.new()
          missing = MapSet.difference(documented, authored)

          assert missing == MapSet.new(),
                 "#{venue}: authored order.status.enum_map is missing provider-documented values " <>
                   "#{inspect(MapSet.to_list(missing))} (source: #{source})"

        _missing_enum_map ->
          assert rule["enum_passthrough"] == true,
                 "#{venue}: expected a non-empty enum_map or explicit passthrough for statuses from #{source}"

          assert Map.has_key?(@enum_passthrough_exemptions, {venue, @order_status_path}),
                 "#{venue}: order status passthrough is absent from the governed exemption registry"
      end
    end
  end

  test "enum passthrough exemptions exactly match every authored passthrough field" do
    actual =
      Bourse.Registry.exchanges()
      |> Enum.flat_map(fn venue ->
        venue
        |> Bourse.Spec.load!()
        |> enum_passthrough_paths()
        |> Enum.map(&{venue, &1})
      end)
      |> MapSet.new()

    expected = @enum_passthrough_exemptions |> Map.keys() |> MapSet.new()

    assert actual == expected,
           "enum_passthrough exemptions must only shrink and must match the authored specs exactly"

    for {_field, %{reason: reason, tracking: tracking}} <- @enum_passthrough_exemptions do
      assert is_binary(reason) and String.length(reason) > 40
      assert Regex.match?(~r/Task \d+/, tracking)
    end
  end

  test "coverage registry contains every runtime venue with an authored order field map" do
    supported =
      Bourse.Registry.exchanges()
      |> Enum.filter(fn venue ->
        venue
        |> Bourse.Spec.load!()
        |> get_in(["normalization", "field_maps", "order"])
        |> is_map()
      end)
      |> MapSet.new()

    registered = @documented_order_statuses |> Map.keys() |> MapSet.new()

    assert registered == supported
  end

  test "unknown order statuses fail loudly for every venue without an exemption" do
    for venue <- Map.keys(@documented_order_statuses),
        not Map.has_key?(@enum_passthrough_exemptions, {venue, @order_status_path}) do
      rule =
        venue
        |> Bourse.Spec.load!()
        |> get_in(@order_status_path)
        |> Map.put("key", "status")

      assert {:error, {:unmapped_order_status, %{venue: ^venue, field: "status", raw_value: "provider-added-status"}}} =
               Bourse.ResponseParser.apply_mappings(
                 %{"status" => "provider-added-status"},
                 %{"status" => rule},
                 target: Bourse.Order,
                 venue: venue
               )
    end
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

  defp enum_passthrough_paths(value), do: enum_passthrough_paths(value, [])

  defp enum_passthrough_paths(value, path) when is_map(value) do
    current = if value["enum_passthrough"] == true, do: [path], else: []

    nested =
      Enum.flat_map(value, fn
        {"enum_passthrough", _value} -> []
        {key, child} -> enum_passthrough_paths(child, path ++ [key])
      end)

    current ++ nested
  end

  defp enum_passthrough_paths(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} -> enum_passthrough_paths(child, path ++ [index]) end)
  end

  defp enum_passthrough_paths(_value, _path), do: []
end
