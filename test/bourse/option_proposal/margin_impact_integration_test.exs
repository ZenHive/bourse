defmodule Bourse.OptionProposal.MarginImpactIntegrationTest do
  @moduledoc """
  Live provider pins for `compare_margin_impact/1` capability classes.

  Offline `Req.Test` stubs in `margin_impact_test.exs` stay as regression
  coverage. These tagged network tests hit testnet/demo endpoints with
  standing credentials and pin real success + error envelopes.
  """
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.OptionProposal

  @moduletag :integration
  @moduletag :network

  @bybit_demo_url "https://api-demo.bybit.com"
  @derive_subaccount_id 144_422

  # ---------------------------------------------------------------------------
  # OKX international demo — joint-plan position builder
  # ---------------------------------------------------------------------------

  @tag :exchange_okx
  test "OKX position builder returns provider-owned joint-plan margin evidence" do
    exchange = okx_demo_exchange!()

    assert {:ok, result} =
             OptionProposal.compare_margin_impact(%{
               candidate_plans: [okx_plan(exchange, %{"acctLv" => "3", "inclRealPosAndEq" => true})],
               objective: :minimize,
               weights: %{initial_margin_impact: 1},
               tie_break_policy: [:plan_order]
             })

    assert [observation] = result.observations
    assert observation.capability_label == :joint_plan_simulation
    assert observation.provider_response.baseline["code"] == "0"
    assert observation.provider_response.scenario["code"] == "0"
    assert is_number(observation.metrics.initial_margin)
    assert is_number(observation.metrics.maintenance_margin)
    assert is_number(observation.metrics.initial_margin_impact)
    assert observation.collateral_domain.portfolio_margin_netting == false
  end

  @tag :exchange_okx
  test "OKX position builder preserves a provider parameter error" do
    exchange = okx_demo_exchange!()

    invalid_scenario = %{
      "acctLv" => "3",
      "inclRealPosAndEq" => true,
      "simPos" => [%{"pos" => "1"}]
    }

    assert {:error, %Error{type: :bad_request, code: "50014"} = error} =
             OptionProposal.compare_margin_impact(%{
               candidate_plans: [okx_plan(exchange, invalid_scenario)],
               objective: :minimize,
               weights: %{initial_margin_impact: 1},
               tie_break_policy: [:plan_order]
             })

    assert error.message =~ "simPos.avgPx"
  end

  # ---------------------------------------------------------------------------
  # Deribit testnet — joint-plan simulate_portfolio
  # ---------------------------------------------------------------------------

  @tag :exchange_deribit
  test "Deribit simulate_portfolio returns provider-owned joint-plan margin evidence" do
    exchange = deribit_testnet_exchange!()

    assert {:ok, result} =
             OptionProposal.compare_margin_impact(%{
               candidate_plans: [deribit_plan(exchange, ~s({"BTC-PERPETUAL":100}))],
               objective: :minimize,
               weights: %{initial_margin_impact: 1},
               tie_break_policy: [:plan_order]
             })

    assert [observation] = result.observations
    assert observation.capability_label == :joint_plan_simulation
    assert observation.comparable? == true
    assert is_map(observation.provider_response["result"])
    assert observation.provider_response["result"]["currency"] == "BTC"
    assert is_number(observation.metrics.initial_margin)
    assert is_number(observation.metrics.maintenance_margin)
    assert observation.metrics.initial_margin > 0
    assert observation.metrics.maintenance_margin > 0
    # Provider reports both current and projected; impact is their difference
    # (live portfolio_margin often returns equal current/projected → impact 0.0).
    assert is_number(observation.metrics.projected_initial_margin)
    assert is_number(observation.metrics.projected_maintenance_margin)
    assert is_number(observation.metrics.initial_margin_impact)
    assert is_number(observation.metrics.maintenance_margin_impact)

    assert observation.collateral_domain == %{
             venue: "deribit",
             account: "main",
             account_mode: :portfolio_margin,
             collateral_scope: {:currency, "BTC"},
             portfolio_margin_netting: false
           }
  end

  @tag :exchange_deribit
  test "Deribit simulate_portfolio preserves a malformed simulated_positions error" do
    exchange = deribit_testnet_exchange!()

    assert {:error, %Error{type: :bad_request, code: -32_602} = error} =
             OptionProposal.compare_margin_impact(%{
               candidate_plans: [deribit_plan(exchange, "not-json")],
               objective: :minimize,
               weights: %{initial_margin_impact: 1},
               tie_break_policy: [:plan_order]
             })

    assert error.message =~ "simulated_positions"
    assert error.message =~ "invalid format"
  end

  # ---------------------------------------------------------------------------
  # Bybit demo — single-order pre-check quote
  # ---------------------------------------------------------------------------

  @tag :exchange_bybit
  test "Bybit order pre-check returns provider-owned single-order margin quote" do
    exchange = bybit_demo_exchange!()

    # Demo attests linear far-from-market pre-check as retCode 0 with zero IMR/MMR
    # rates (empty metrics case). Option pre-check also returns zeros on this
    # demo account when orderLinkId is supplied — pin the linear empty-metrics
    # shape honestly rather than inventing non-zero rates.
    assert {:ok, result} =
             OptionProposal.compare_margin_impact(%{
               candidate_plans: [bybit_linear_plan(exchange)],
               objective: :minimize,
               weights: %{initial_margin_rate_impact_e4: 1},
               tie_break_policy: [:plan_order]
             })

    assert [observation] = result.observations
    assert observation.capability_label == :single_order_margin_quote
    assert observation.comparable? == false
    assert observation.provider_response["retCode"] == 0
    assert is_map(observation.provider_response["result"])
    assert is_binary(observation.provider_response["result"]["orderId"])

    # Provider-reported rate domain (e4). Pin metrics to the live pre-check
    # envelope rather than a frozen zero — demo returned all zeros earlier and
    # preImrE4/postImrE4 = 1 on 2026-07-29 for the same far-from-market plan.
    result_row = observation.provider_response["result"]

    assert observation.metrics.pre_initial_margin_rate_e4 ==
             Bourse.Safe.number(result_row["preImrE4"])

    assert observation.metrics.pre_maintenance_margin_rate_e4 ==
             Bourse.Safe.number(result_row["preMmrE4"])

    assert observation.metrics.post_initial_margin_rate_e4 ==
             Bourse.Safe.number(result_row["postImrE4"])

    assert observation.metrics.post_maintenance_margin_rate_e4 ==
             Bourse.Safe.number(result_row["postMmrE4"])

    assert observation.metrics.initial_margin_rate_impact_e4 ==
             observation.metrics.post_initial_margin_rate_e4 -
               observation.metrics.pre_initial_margin_rate_e4

    assert observation.metrics.maintenance_margin_rate_impact_e4 ==
             observation.metrics.post_maintenance_margin_rate_e4 -
               observation.metrics.pre_maintenance_margin_rate_e4

    assert observation.effects.liquidation == %{}
    assert result.comparisons == []
    assert observation.collateral_domain.portfolio_margin_netting == false
  end

  @tag :exchange_bybit
  test "Bybit order pre-check preserves a provider parameter error" do
    exchange = bybit_demo_exchange!()

    invalid_params = %{
      "category" => "linear",
      "side" => "Buy",
      "orderType" => "Limit",
      "qty" => "0.001",
      "price" => "10000"
    }

    assert {:error, %Error{type: :bad_request, code: 10_001} = error} =
             OptionProposal.compare_margin_impact(%{
               candidate_plans: [
                 %{
                   id: :bybit_missing_symbol,
                   exchange: exchange,
                   account: "uta",
                   account_mode: :cross_margin,
                   provider_params: invalid_params,
                   request_opts: [base_url: @bybit_demo_url]
                 }
               ],
               objective: :minimize,
               weights: %{initial_margin_rate_impact_e4: 1},
               tie_break_policy: [:plan_order]
             })

    assert error.message =~ "symbol"
  end

  # ---------------------------------------------------------------------------
  # Derive demo — position-scenario get_margin
  # ---------------------------------------------------------------------------

  @tag :exchange_derive
  test "Derive get_margin returns provider-owned position-scenario margin evidence" do
    exchange = derive_demo_exchange!()

    assert {:ok, result} =
             OptionProposal.compare_margin_impact(%{
               candidate_plans: [derive_plan(exchange)],
               objective: :minimize,
               weights: %{initial_margin_impact: 1},
               tie_break_policy: [:plan_order]
             })

    assert [observation] = result.observations
    assert observation.capability_label == :position_scenario_margin
    assert observation.comparable? == false
    assert observation.provider_response["result"]["subaccount_id"] == @derive_subaccount_id
    assert is_number(observation.metrics.initial_margin)
    assert is_number(observation.metrics.maintenance_margin)
    assert observation.metrics.initial_margin > 0
    assert observation.metrics.maintenance_margin > 0
    assert is_number(observation.metrics.pre_initial_margin)
    assert is_number(observation.metrics.pre_maintenance_margin)
    assert is_number(observation.metrics.initial_margin_impact)
    assert is_number(observation.metrics.maintenance_margin_impact)
    assert observation.effects.capacity.is_valid_trade in [true, false]
    assert result.comparisons == []

    assert observation.collateral_domain == %{
             venue: "derive",
             account: @derive_subaccount_id,
             account_mode: :standard_margin,
             collateral_scope: {:subaccount, @derive_subaccount_id},
             portfolio_margin_netting: false
           }
  end

  @tag :exchange_derive
  test "Derive get_margin preserves a not-found subaccount provider error" do
    exchange = derive_demo_exchange!()

    # Missing subaccount_id is rejected client-side (collateral_scope validation).
    # A real provider error requires a well-formed plan with an unknown id.
    assert {:error, %Error{type: :invalid_order, code: 14_001} = error} =
             OptionProposal.compare_margin_impact(%{
               candidate_plans: [
                 %{
                   id: :derive_unknown_subaccount,
                   exchange: exchange,
                   account: 999_999_999,
                   account_mode: :standard_margin,
                   provider_params: %{
                     "subaccount_id" => 999_999_999,
                     "simulated_position_changes" => []
                   }
                 }
               ],
               objective: :minimize,
               weights: %{initial_margin_impact: 1},
               tie_break_policy: [:plan_order]
             })

    assert error.message =~ "Subaccount not found"
  end

  # ---------------------------------------------------------------------------
  # Plans
  # ---------------------------------------------------------------------------

  defp okx_plan(exchange, provider_params) do
    %{
      id: :intl_demo,
      exchange: exchange,
      account: "intl-demo",
      account_mode: :multi_currency_margin,
      baseline_provider_params: %{"acctLv" => "3", "inclRealPosAndEq" => true},
      provider_params: provider_params
    }
  end

  defp deribit_plan(exchange, simulated_positions) do
    %{
      id: :deribit_sim,
      exchange: exchange,
      account: "main",
      account_mode: :portfolio_margin,
      provider_params: %{
        "currency" => "BTC",
        "add_positions" => true,
        "simulated_positions" => simulated_positions
      }
    }
  end

  defp bybit_linear_plan(exchange) do
    %{
      id: :bybit_linear_precheck,
      exchange: exchange,
      account: "uta",
      account_mode: :cross_margin,
      provider_params: %{
        "category" => "linear",
        "symbol" => "BTCUSDT",
        "side" => "Buy",
        "orderType" => "Limit",
        "qty" => "0.001",
        "price" => "10000",
        "timeInForce" => "GTC",
        "positionIdx" => 0
      },
      request_opts: [base_url: @bybit_demo_url]
    }
  end

  defp derive_plan(exchange) do
    %{
      id: :derive_scenario,
      exchange: exchange,
      account: @derive_subaccount_id,
      account_mode: :standard_margin,
      provider_params: %{
        "subaccount_id" => @derive_subaccount_id,
        "simulated_position_changes" => []
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Credentials — flunk loudly with exact export instructions
  # ---------------------------------------------------------------------------

  defp okx_demo_exchange! do
    with api_key when is_binary(api_key) <- System.get_env("OKX_INTL_API_KEY"),
         secret when is_binary(secret) <- System.get_env("OKX_INTL_API_SECRET"),
         password when is_binary(password) <- System.get_env("OKX_INTL_PASSPHRASE"),
         {:ok, credentials} <-
           Credentials.new(api_key: api_key, secret: secret, password: password) do
      Exchange.new!("okx", credentials: credentials, sandbox: true)
    else
      _missing ->
        flunk("""
        Missing OKX international demo credentials!

        Set these environment variables:
          export OKX_INTL_API_KEY="your_key"
          export OKX_INTL_API_SECRET="your_secret"
          export OKX_INTL_PASSPHRASE="your_passphrase"

        Create an international demo-trading key at https://www.okx.com/.
        """)
    end
  end

  defp deribit_testnet_exchange! do
    with api_key when is_binary(api_key) and api_key != "" <- System.get_env("DERIBIT_TESTNET_API_KEY"),
         secret when is_binary(secret) and secret != "" <- System.get_env("DERIBIT_TESTNET_API_SECRET"),
         {:ok, credentials} <- Credentials.new(api_key: api_key, secret: secret) do
      Exchange.new!("deribit", credentials: credentials, sandbox: true)
    else
      _missing ->
        flunk("""
        Missing Deribit testnet credentials!

        Set these environment variables:
          export DERIBIT_TESTNET_API_KEY="your_key"
          export DERIBIT_TESTNET_API_SECRET="your_secret"

        Create a testnet key at https://test.deribit.com/.
        """)
    end
  end

  defp bybit_demo_exchange! do
    api_key = System.get_env("BYBIT_DEMO_API_KEY")
    secret = System.get_env("BYBIT_DEMO_API_SECRET")

    if api_key in [nil, ""] or secret in [nil, ""] do
      flunk("""
      Missing Bybit DEMO-trading credentials (the testnet key is read-only, error 10024).

        export BYBIT_DEMO_API_KEY="your_demo_api_key"
        export BYBIT_DEMO_API_SECRET="your_demo_api_secret"

      Create a demo-trading key from a bybit.com account (Demo Trading):
        https://www.bybit.com/app/user/api-management
      """)
    end

    credentials = Credentials.new!(api_key: api_key, secret: secret)
    Exchange.new!("bybit", credentials: credentials)
  end

  defp derive_demo_exchange! do
    with api_key when is_binary(api_key) and api_key != "" <- System.get_env("DERIVE_TESTNET_API_KEY"),
         secret when is_binary(secret) and secret != "" <- System.get_env("DERIVE_TESTNET_API_SECRET"),
         {:ok, credentials} <- Credentials.new(api_key: api_key, secret: secret) do
      Exchange.new!("derive", credentials: credentials, sandbox: true)
    else
      _missing ->
        flunk("""
        Missing Derive testnet credentials!

        Set these environment variables:
          export DERIVE_TESTNET_API_KEY="your_derive_wallet_address"
          export DERIVE_TESTNET_API_SECRET="your_session_key_private_key"

        Derive wallet must be registered for api-demo.lyra.finance (subaccount #{@derive_subaccount_id}).
        Docs: https://docs.derive.xyz/
        """)
    end
  end
end
