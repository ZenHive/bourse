defmodule Bourse.RawEndpointProbeConfigTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.Generator.RawEndpointProbe
  alias Bourse.Test.Generator.RawEndpointProbe.Config, as: ProbeConfig

  setup_all do
    snapshot = RawEndpointProbe.__inspection_snapshot__()

    {:ok, raw_cases: snapshot.cases, raw_skips: snapshot.skips, raw_spec_loads: snapshot.spec_loads}
  end

  describe "Task 117 gate — transaction_classification populated" do
    test "first-class venues carry non-empty endpoints.transaction_classification" do
      for exchange_id <- ProbeConfig.first_class_venues() do
        assert ProbeConfig.transaction_classification_populated?(exchange_id),
               "expected endpoints.transaction_classification for #{exchange_id}; " <>
                 "STOP — re-file upstream distill before consuming"
      end
    end
  end

  describe "classification_for/2" do
    test "derive fetchBalance POST is read-style (transactional: false)" do
      ctx = ProbeConfig.transaction_context("derive")

      endpoint = %{
        sections: ["private"],
        method: :post,
        path: "get_all_portfolios",
        authenticated: true
      }

      assert ProbeConfig.classification_for(ctx, endpoint) == %{
               "on_chain" => false,
               "transactional" => false
             }

      assert ProbeConfig.treat_post_as_safe?("derive", endpoint)
    end

    test "derive createOrder POST is transactional" do
      ctx = ProbeConfig.transaction_context("derive")

      endpoint = %{
        sections: ["private"],
        method: :post,
        path: "order",
        authenticated: true
      }

      assert ProbeConfig.classification_for(ctx, endpoint) == %{
               "on_chain" => false,
               "transactional" => true
             }

      refute ProbeConfig.treat_post_as_safe?("derive", endpoint)
    end

    test "lighter publicPostSendTx is on-chain transactional without unified mapping" do
      ctx = ProbeConfig.transaction_context("lighter")

      endpoint = %{
        sections: ["public"],
        method: :post,
        path: "sendTx",
        authenticated: false
      }

      assert ProbeConfig.classification_for(ctx, endpoint) == %{
               "on_chain" => true,
               "transactional" => true
             }

      refute ProbeConfig.treat_post_as_safe?("lighter", endpoint)
    end

    test "hyperliquid public info POST is read-style" do
      ctx = ProbeConfig.transaction_context("hyperliquid")

      endpoint = %{
        sections: ["public"],
        method: :post,
        path: "info",
        authenticated: false
      }

      assert ProbeConfig.classification_for(ctx, endpoint) == %{
               "on_chain" => false,
               "transactional" => false
             }

      assert ProbeConfig.treat_post_as_safe?("hyperliquid", endpoint)
    end
  end

  describe "Task 111 — Bybit query params + needs_params gating" do
    test "bybit v5 kline probe params include category, symbol, and interval" do
      endpoint = %{path: "v5/market/kline"}

      assert %{"category" => "spot", "symbol" => symbol, "interval" => "1"} =
               ProbeConfig.query_params_for("bybit", endpoint)

      assert is_binary(symbol) and symbol != ""
    end

    test "bybit linear index-price-kline uses linear category" do
      endpoint = %{path: "v5/market/index-price-kline"}

      assert %{"category" => "linear", "symbol" => _, "interval" => "1"} =
               ProbeConfig.query_params_for("bybit", endpoint)
    end

    test "bybit crypto-loan-fixed prefix is needs_params" do
      endpoint = %{path: "v5/crypto-loan-fixed/borrow-order-quote"}

      assert ProbeConfig.needs_params_prefix("bybit", endpoint) == "v5/crypto-loan-fixed/"
      assert ProbeConfig.skip_group_key("bybit", endpoint, :public) == {:needs_params, "v5/crypto-loan-fixed/"}
    end

    test "needs_params gating applies only to public auth class" do
      endpoint = %{path: "v5/crypto-loan-fixed/borrow-order-quote"}

      refute ProbeConfig.skip_group_key("bybit", endpoint, :private)
    end

    test "needs_params skip labels and reasons are actionable" do
      assert ProbeConfig.skip_label({:needs_params, "v5/crypto-loan-fixed/"}) =~ "hand-authored"
      assert ProbeConfig.skip_reason({:needs_params, "v5/crypto-loan-fixed/"}, 2) =~ "2 endpoints"
    end
  end

  describe "Task 112 — testnet-unavailable + WS-only gating" do
    test "binance sapi private endpoint matches unavailable testnet prefix" do
      endpoint = %{sections: ["sapi"], name: :sapi_get_capital_config_getall}

      assert ProbeConfig.unavailable_testnet_prefix("binance", endpoint) == "sapi"
      assert ProbeConfig.skip_group_key("binance", endpoint, :private) == {:testnet_unavailable, "sapi"}
    end

    test "binance api prefix is not testnet-unavailable" do
      endpoint = %{sections: ["api"], name: :private_get_account}

      refute ProbeConfig.unavailable_testnet_prefix("binance", endpoint)
      refute ProbeConfig.skip_group_key("binance", endpoint, :private)
    end

    test "testnet-unavailable gating applies only to sandbox auth classes" do
      endpoint = %{sections: ["sapi"], name: :sapi_get_capital_config_getall}

      refute ProbeConfig.skip_group_key("binance", endpoint, :public)
      refute ProbeConfig.skip_group_key("binance", endpoint, :public_dangerous)
    end

    test "deribit private_get endpoint is WS-only" do
      endpoint = %{sections: ["private"], name: :private_get_logout}

      assert ProbeConfig.ws_only_method?("deribit", endpoint)
      assert ProbeConfig.skip_group_key("deribit", endpoint, :private) == {:ws_only, "private_get_"}
    end

    test "skip labels and reasons are actionable" do
      assert ProbeConfig.skip_label({:testnet_unavailable, "papi"}) =~ "papi"
      assert ProbeConfig.skip_reason({:testnet_unavailable, "papi"}, 67) =~ "67 endpoints"

      assert ProbeConfig.skip_label({:ws_only, "private_get_"}) =~ "WS-only"
      assert ProbeConfig.skip_reason({:ws_only, "private_get_"}, 83) =~ "83 endpoints"
    end
  end

  describe "Task 242 — live-sweep retired and misclassified endpoint rows" do
    test "deribit retired endpoints are registered without removing generated functions" do
      endpoint_names = generated_endpoint_names("deribit")

      for name <- ~w(private_get_get_portfolio_margins public_get_get_index public_get_get_index_price_names) do
        assert name in endpoint_names
      end

      endpoint = generated_endpoint!("deribit", "public_get_get_index")

      assert ProbeConfig.retired_endpoint_key("deribit", endpoint) == "public_get_get_index"
      assert ProbeConfig.skip_group_key("deribit", endpoint, :public) == {:retired_endpoint, "public_get_get_index"}
    end

    test "bybit retired path families and misclassified destructive GET are registered" do
      # AC2: the rows stay generated — the register is the deliverable, not a removal.
      endpoint_names = generated_endpoint_names("bybit")
      assert "private_get_v5_user_del_submember" in endpoint_names

      retired_endpoint = generated_endpoint!("bybit", "public_get_spot_v3_public_symbols")

      assert ProbeConfig.retired_endpoint_key("bybit", retired_endpoint) == "spot/v3/public/"
      assert ProbeConfig.skip_group_key("bybit", retired_endpoint, :public) == {:retired_endpoint, "spot/v3/public/"}

      misclassified_endpoint = generated_endpoint!("bybit", "private_get_v5_user_del_submember")

      assert ProbeConfig.misclassified_endpoint_key("bybit", misclassified_endpoint) ==
               "private_get_v5_user_del_submember"

      # The destructive rm-subuid row must never reach a live testnet probe.
      assert ProbeConfig.skip_group_key("bybit", misclassified_endpoint, :private) ==
               {:misclassified_endpoint, "private_get_v5_user_del_submember"}
    end

    test "okx typo and POST-only variants are registered" do
      endpoint_names = generated_endpoint_names("okx")

      for name <- ~w(public_get_support_announcements_types private_get_account_set_auto_repay) do
        assert name in endpoint_names
      end

      retired_endpoint = generated_endpoint!("okx", "public_get_support_announcements_types")

      assert ProbeConfig.retired_endpoint_key("okx", retired_endpoint) == "public_get_support_announcements_types"

      assert ProbeConfig.skip_group_key("okx", retired_endpoint, :public) ==
               {:retired_endpoint, "public_get_support_announcements_types"}

      # The correctly-spelled sibling stays live — the retirement is path-specific,
      # not a blanket announcement-types skip.
      live_sibling = generated_endpoint!("okx", "public_get_support_announcement_types")

      assert ProbeConfig.retired_endpoint_key("okx", live_sibling) == nil
      assert ProbeConfig.skip_group_key("okx", live_sibling, :public) == nil

      misclassified_endpoint = generated_endpoint!("okx", "private_get_account_set_auto_repay")

      assert ProbeConfig.misclassified_endpoint_key("okx", misclassified_endpoint) ==
               "private_get_account_set_auto_repay"

      assert ProbeConfig.skip_group_key("okx", misclassified_endpoint, :private) ==
               {:misclassified_endpoint, "private_get_account_set_auto_repay"}
    end

    test "skip labels and reasons preserve the generated-function contract" do
      assert ProbeConfig.skip_label({:retired_endpoint, "spot/v3/public/"}) =~ "retired"
      assert ProbeConfig.skip_reason({:retired_endpoint, "spot/v3/public/"}, 12) =~ "generated function retained"

      assert ProbeConfig.skip_label({:misclassified_endpoint, "private_get_account_set_auto_repay"}) =~
               "misclassified"

      assert ProbeConfig.skip_reason({:misclassified_endpoint, "private_get_account_set_auto_repay"}, 1) =~
               "generated function retained"
    end
  end

  describe "RawEndpointProbe compile-time skip grouping" do
    test "inspection derives each exchange context once", %{raw_spec_loads: spec_loads} do
      assert spec_loads == length(Bourse.Registry.exchanges())
    end

    test "binance private emits one skip group per unavailable prefix, not per endpoint", %{
      raw_cases: raw_cases,
      raw_skips: raw_skips
    } do
      skips =
        Enum.filter(raw_skips, fn {exchange_id, auth, _, _, _, _} ->
          exchange_id == "binance" and auth == :private
        end)

      assert {"binance", :private, {:testnet_unavailable, "sapi"}, _, _, count} =
               Enum.find(skips, fn {_, _, key, _, _, _} -> key == {:testnet_unavailable, "sapi"} end)

      assert count > 1

      assert {"binance", :private, {:testnet_unavailable, "papi"}, _, _, papi_count} =
               Enum.find(skips, fn {_, _, key, _, _, _} -> key == {:testnet_unavailable, "papi"} end)

      assert papi_count > 1

      refute Enum.any?(skips, fn {_, _, key, _, _, _} -> key == {:testnet_unavailable, "eapi"} end)

      runnable =
        Enum.filter(raw_cases, fn
          {"binance", _, endpoint, :private, _} -> "sapi" in endpoint.sections
          _ -> false
        end)

      assert runnable == []
    end

    test "deribit private emits one WS-only skip group for private_get_* methods", %{
      raw_cases: raw_cases,
      raw_skips: raw_skips
    } do
      skips =
        Enum.filter(raw_skips, fn {exchange_id, auth, _, _, _, _} ->
          exchange_id == "deribit" and auth == :private
        end)

      assert [
               {"deribit", :private, {:ws_only, "private_get_"}, _, reason, count}
             ] = skips

      assert count == 84
      assert reason =~ "WS-only"

      runnable =
        Enum.filter(raw_cases, fn
          {"deribit", _, _, :private, _} -> true
          _ -> false
        end)

      assert runnable == []
    end

    test "deribit public retired endpoints emit retired skip groups", %{raw_skips: raw_skips} do
      skips =
        Enum.filter(raw_skips, fn {exchange_id, auth, _, _, _, _} ->
          exchange_id == "deribit" and auth == :public
        end)

      assert {"deribit", :public, {:retired_endpoint, "public_get_get_index"}, _, reason, 1} =
               Enum.find(skips, fn {_, _, key, _, _, _} -> key == {:retired_endpoint, "public_get_get_index"} end)

      assert reason =~ "retired"
    end

    test "bybit public emits one needs_params skip group for crypto-loan-fixed", %{
      raw_cases: raw_cases,
      raw_skips: raw_skips
    } do
      skips =
        Enum.filter(raw_skips, fn {exchange_id, auth, _, _, _, _} ->
          exchange_id == "bybit" and auth == :public
        end)

      assert {"bybit", :public, {:needs_params, "v5/crypto-loan-fixed/"}, _, reason, count} =
               Enum.find(skips, fn {_, _, key, _, _, _} -> key == {:needs_params, "v5/crypto-loan-fixed/"} end)

      assert count == 2
      assert reason =~ "cannot infer"

      runnable =
        Enum.filter(raw_cases, fn
          {"bybit", _, endpoint, :public, _} -> String.starts_with?(endpoint.path, "v5/crypto-loan-fixed/")
          _ -> false
        end)

      assert runnable == []
    end

    test "bybit and okx live-sweep rows emit retired or misclassified skip groups", %{raw_skips: skips} do
      assert {"bybit", :public, {:retired_endpoint, "spot/v3/public/"}, _, _, spot_v3_count} =
               Enum.find(skips, fn {exchange_id, auth, key, _, _, _} ->
                 exchange_id == "bybit" and auth == :public and key == {:retired_endpoint, "spot/v3/public/"}
               end)

      assert spot_v3_count > 1

      assert {"bybit", :private, {:misclassified_endpoint, "private_get_v5_user_del_submember"}, _, _, 1} =
               Enum.find(skips, fn {exchange_id, auth, key, _, _, _} ->
                 exchange_id == "bybit" and auth == :private and
                   key == {:misclassified_endpoint, "private_get_v5_user_del_submember"}
               end)

      assert {"okx", :private, {:misclassified_endpoint, "private_get_account_set_auto_repay"}, _, _, 1} =
               Enum.find(skips, fn {exchange_id, auth, key, _, _, _} ->
                 exchange_id == "okx" and auth == :private and
                   key == {:misclassified_endpoint, "private_get_account_set_auto_repay"}
               end)

      assert {"okx", :public, {:retired_endpoint, "public_get_support_announcements_types"}, _, _, 1} =
               Enum.find(skips, fn {exchange_id, auth, key, _, _, _} ->
                 exchange_id == "okx" and auth == :public and
                   key == {:retired_endpoint, "public_get_support_announcements_types"}
               end)
    end
  end

  describe "RawEndpointProbe compile-time classification" do
    test "derive transactional POSTs emit under private_dangerous", %{raw_cases: raw_cases} do
      cases =
        Enum.filter(raw_cases, fn
          {"derive", _module, endpoint, :private_dangerous, _defaults} ->
            endpoint.method == :post

          _ ->
            false
        end)

      assert cases != []
    end

    test "lighter sendTx emits as public_dangerous", %{raw_cases: raw_cases} do
      cases =
        Enum.filter(raw_cases, fn
          {"lighter", _module, endpoint, :public_dangerous, _defaults} ->
            to_string(endpoint.name) =~ "sendtx"

          _ ->
            false
        end)

      assert cases != []
    end
  end

  defp generated_endpoint_names(exchange_id) do
    exchange_id
    |> generated_endpoints()
    |> Enum.map(&to_string(&1.name))
  end

  defp generated_endpoints(exchange_id) do
    {:ok, exchange} = Bourse.Exchange.new(exchange_id, sandbox: true)

    exchange.module.__endpoints__()
  end

  # Fetches the real generated endpoint rather than hand-building one, so the
  # registry assertions fail if the authored spec's name/path ever drifts.
  defp generated_endpoint!(exchange_id, name) do
    endpoints = generated_endpoints(exchange_id)

    case Enum.find(endpoints, &(to_string(&1.name) == name)) do
      nil -> flunk("#{exchange_id} has no generated endpoint named #{name}")
      endpoint -> endpoint
    end
  end
end
