defmodule Bourse.UnifiedMethodTest do
  use ExUnit.Case, async: true

  alias Bourse.TestExchange.Binance
  alias Bourse.TestExchange.Bybit
  alias Bourse.UnifiedMethod

  describe "camelCase → snake_case conversion via build_unified_mapping/2" do
    @dummy_config %{name: :public_get_ticker, method: :get, path: "ticker", sections: ["public"], weight: 1}

    test "converts camelCase unified method names to snake_case atoms" do
      mapping =
        UnifiedMethod.build_unified_mapping(
          %{
            "fetchTicker" => ["publicGetTicker"],
            "createOrder" => ["publicGetTicker"],
            "cancelAllOrders" => ["publicGetTicker"],
            "fetchMyTrades" => ["publicGetTicker"]
          },
          [@dummy_config]
        )

      assert Map.has_key?(mapping, :fetch_ticker)
      assert Map.has_key?(mapping, :create_order)
      assert Map.has_key?(mapping, :cancel_all_orders)
      assert Map.has_key?(mapping, :fetch_my_trades)
    end

    test "handles all-caps acronyms" do
      mapping =
        UnifiedMethod.build_unified_mapping(
          %{"fetchOHLCV" => ["publicGetTicker"]},
          [@dummy_config]
        )

      assert Map.has_key?(mapping, :fetch_ohlcv)
    end

    test "handles single-word methods" do
      mapping =
        UnifiedMethod.build_unified_mapping(
          %{"withdraw" => ["publicGetTicker"], "transfer" => ["publicGetTicker"]},
          [@dummy_config]
        )

      assert Map.has_key?(mapping, :withdraw)
      assert Map.has_key?(mapping, :transfer)
    end
  end

  describe "endpoint_config_to_js_name/3" do
    test "simple single-section endpoints" do
      assert UnifiedMethod.endpoint_config_to_js_name(["public"], :get, "v5/market/tickers") ==
               "publicGetV5MarketTickers"

      assert UnifiedMethod.endpoint_config_to_js_name(["private"], :post, "v5/order/create") ==
               "privatePostV5OrderCreate"
    end

    test "multi-section endpoints with camelCase joining" do
      assert UnifiedMethod.endpoint_config_to_js_name(["private", "options"], :delete, "orders") ==
               "privateOptionsDeleteOrders"

      assert UnifiedMethod.endpoint_config_to_js_name(["public", "futures"], :get, "tickers") ==
               "publicFuturesGetTickers"
    end

    test "Binance-style prefixed sections" do
      assert UnifiedMethod.endpoint_config_to_js_name(["dapiPublic"], :get, "ticker/24hr") ==
               "dapiPublicGetTicker24hr"

      assert UnifiedMethod.endpoint_config_to_js_name(["sapi"], :get, "margin/account") ==
               "sapiGetMarginAccount"

      assert UnifiedMethod.endpoint_config_to_js_name(["fapiPrivateV2"], :get, "account") ==
               "fapiPrivateV2GetAccount"
    end

    test "paths with template params (curly braces stripped)" do
      assert UnifiedMethod.endpoint_config_to_js_name(["private", "delivery"], :get, "{settle}/positions") ==
               "privateDeliveryGetSettlePositions"
    end

    test "paths with @ separator (BigOne depth@{symbol}/snapshot)" do
      assert UnifiedMethod.endpoint_config_to_js_name(
               ["contractPublic"],
               :get,
               "depth@{symbol}/snapshot"
             ) == "contractPublicGetDepthSymbolSnapshot"
    end

    test "paths with hyphens as word separators" do
      assert UnifiedMethod.endpoint_config_to_js_name(["private"], :get, "v5/account/wallet-balance") ==
               "privateGetV5AccountWalletBalance"
    end

    test "preserves camelCase within path segments" do
      assert UnifiedMethod.endpoint_config_to_js_name(["private"], :get, "openAlgoOrders") ==
               "privateGetOpenAlgoOrders"
    end

    test "paths with colons (Bitfinex)" do
      assert UnifiedMethod.endpoint_config_to_js_name(["public"], :get, "conf/pub:list:object:detail") ==
               "publicGetConfPubListObjectDetail"
    end

    test "all HTTP methods" do
      assert UnifiedMethod.endpoint_config_to_js_name(["private"], :put, "order") == "privatePutOrder"
      assert UnifiedMethod.endpoint_config_to_js_name(["private"], :delete, "order") == "privateDeleteOrder"
      assert UnifiedMethod.endpoint_config_to_js_name(["private"], :patch, "order") == "privatePatchOrder"
    end
  end

  describe "build_unified_mapping/2" do
    @endpoint_configs [
      %{name: :public_get_v5_market_tickers, method: :get, path: "v5/market/tickers", sections: ["public"], weight: 5},
      %{name: :private_post_v5_order_create, method: :post, path: "v5/order/create", sections: ["private"], weight: 2.5},
      %{
        name: :private_get_v5_account_wallet_balance,
        method: :get,
        path: "v5/account/wallet-balance",
        sections: ["private"],
        weight: 1
      },
      %{
        name: :private_post_v5_position_trading_stop,
        method: :post,
        path: "v5/position/trading-stop",
        sections: ["private"],
        weight: 2.5
      }
    ]

    test "maps unified methods to matching endpoint configs" do
      unified_endpoints = %{
        "fetchTicker" => ["publicGetV5MarketTickers"],
        "createOrder" => ["privatePostV5OrderCreate", "privatePostV5PositionTradingStop"]
      }

      mapping = UnifiedMethod.build_unified_mapping(unified_endpoints, @endpoint_configs)

      assert [:public_get_v5_market_tickers] == Enum.map(mapping[:fetch_ticker], & &1.name)

      assert [:private_post_v5_order_create, :private_post_v5_position_trading_stop] ==
               Enum.map(mapping[:create_order], & &1.name)
    end

    test "excludes methods with no matching endpoint configs" do
      unified_endpoints = %{
        "fetchTicker" => ["publicGetV5MarketTickers"],
        "fetchLedger" => ["privateGetNonexistentEndpoint"]
      }

      mapping = UnifiedMethod.build_unified_mapping(unified_endpoints, @endpoint_configs)

      assert Map.has_key?(mapping, :fetch_ticker)
      refute Map.has_key?(mapping, :fetch_ledger)
    end

    test "returns empty map for nil unified_endpoints" do
      assert UnifiedMethod.build_unified_mapping(nil, @endpoint_configs) == %{}
    end

    test "returns empty map for empty unified_endpoints" do
      assert UnifiedMethod.build_unified_mapping(%{}, @endpoint_configs) == %{}
    end

    test "preserves full endpoint config data" do
      unified_endpoints = %{"fetchBalance" => ["privateGetV5AccountWalletBalance"]}

      mapping = UnifiedMethod.build_unified_mapping(unified_endpoints, @endpoint_configs)
      [config] = mapping[:fetch_balance]

      assert config.name == :private_get_v5_account_wallet_balance
      assert config.method == :get
      assert config.path == "v5/account/wallet-balance"
      assert config.sections == ["private"]
      assert config.weight == 1
    end
  end

  describe "integration with real specs" do
    test "Bybit produces non-empty unified mapping" do
      spec = Bourse.Spec.load!("bybit")
      endpoint_configs = Bourse.Exchange.build_endpoint_configs(spec["raw"]["describe"]["api"] || %{})
      mapping = Bourse.Exchange.build_unified_method_mapping(spec, endpoint_configs)

      assert map_size(mapping) > 50
      assert Map.has_key?(mapping, :fetch_ticker)
      assert Map.has_key?(mapping, :create_order)
      assert Map.has_key?(mapping, :fetch_balance)

      # fetch_ticker resolves to the correct endpoint
      [config] = mapping[:fetch_ticker]
      assert config.name == :public_get_v5_market_tickers
      assert config.method == :get
    end

    test "Binance multi-section endpoints resolve correctly" do
      spec = Bourse.Spec.load!("binance")
      endpoint_configs = Bourse.Exchange.build_endpoint_configs(spec["raw"]["describe"]["api"] || %{})
      mapping = Bourse.Exchange.build_unified_method_mapping(spec, endpoint_configs)

      # Binance fetchTicker maps to multiple section endpoints
      ticker_configs = mapping[:fetch_ticker]
      assert length(ticker_configs) >= 3

      # Should include dapiPublic, fapiPublic, and public variants
      names = Enum.map(ticker_configs, & &1.name)
      assert :public_get_ticker in names or :public_get_ticker_24hr in names
    end

    test "exchange with no unified_endpoints returns empty mapping" do
      endpoint_configs = [%{name: :public_get_ticker, method: :get, path: "ticker", sections: ["public"], weight: 1}]
      mapping = Bourse.Exchange.build_unified_method_mapping(%{}, endpoint_configs)

      assert mapping == %{}
    end
  end

  describe "generated introspection functions" do
    test "__unified_endpoints__/0 returns the full mapping" do
      mapping = Bybit.__unified_endpoints__()

      assert is_map(mapping)
      assert map_size(mapping) > 50
      assert Map.has_key?(mapping, :fetch_ticker)
    end

    test "__unified_endpoint__/1 returns configs for known method" do
      configs = Bybit.__unified_endpoint__(:fetch_ticker)

      assert [%{name: :public_get_v5_market_tickers} | _] = configs
    end

    test "__unified_endpoint__/1 returns empty list for unknown method" do
      assert Bybit.__unified_endpoint__(:nonexistent_method) == []
    end

    test "Binance unified endpoints resolve multi-section names" do
      configs = Binance.__unified_endpoint__(:fetch_ticker)

      assert length(configs) >= 3
      names = Enum.map(configs, & &1.name)
      # dapiPublic section endpoints should be resolved
      assert Enum.any?(names, &String.contains?(to_string(&1), "dapi"))
    end
  end
end
