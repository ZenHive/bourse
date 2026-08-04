defmodule Bourse.OptionProposal.MarginImpactTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.OptionProposal
  alias Bourse.OptionProposal.MarginImpact
  alias Bourse.Test.RequestCollector

  @private_key "0x0123456789012345678901234567890123456789012345678901234567890123"

  describe "provider capability classification" do
    test "labels all four venue capabilities from their official endpoints" do
      capabilities = MarginImpact.capabilities()

      assert capabilities["deribit"].label == :joint_plan_simulation
      assert capabilities["okx"].label == :joint_plan_simulation
      assert capabilities["bybit"].label == :single_order_margin_quote
      assert capabilities["derive"].label == :position_scenario_margin

      assert capabilities["deribit"].endpoint == :private_get_simulate_portfolio
      assert capabilities["okx"].endpoint == :private_post_account_position_builder
      assert capabilities["bybit"].endpoint == :private_post_v5_order_pre_check
      assert capabilities["derive"].endpoint == :private_post_get_margin
    end

    test "unsupported venues and account modes fail explicitly" do
      assert {:error, %Error{type: :not_supported, exchange: "binance"}} =
               MarginImpact.capability("binance")

      problem =
        problem([
          deribit_plan(:unsupported, margin_stub(100, 120), account_mode: :standard_margin)
        ])

      assert {:error, %Error{type: :not_supported, exchange: "deribit"} = error} =
               OptionProposal.compare_margin_impact(problem)

      assert error.message =~ "account mode"
    end
  end

  describe "joint-plan comparison" do
    test "ranks provider-reported impact only inside one collateral domain" do
      expensive = deribit_plan(:expensive, margin_stub(100, 140, 80, 110))
      efficient = deribit_plan(:efficient, margin_stub(100, 125, 80, 95))

      problem =
        problem(
          [expensive, efficient],
          weights: %{initial_margin_impact: 1.0, maintenance_margin_impact: 0.5}
        )

      assert {:ok, result} = OptionProposal.compare_margin_impact(problem)
      assert result.portfolio_margin_netting == false
      assert result.cross_venue.global_ranking == nil

      assert [
               %{
                 status: :ranked,
                 winner_plan_id: :efficient,
                 ranking: [
                   %{plan_id: :efficient, score: 32.5},
                   %{plan_id: :expensive, score: 55.0}
                 ]
               }
             ] = result.comparisons

      assert Enum.all?(result.observations, &(&1.capability_label == :joint_plan_simulation))
      assert Enum.all?(result.observations, &(&1.comparable? == true))
      assert Enum.all?(result.collateral_domains, &(&1.portfolio_margin_netting == false))

      assert RequestCollector.paths(expensive.request_collector) == [
               "/api/v2/private/simulate_portfolio"
             ]

      assert RequestCollector.paths(efficient.request_collector) == [
               "/api/v2/private/simulate_portfolio"
             ]
    end

    test "does not produce a cross-venue ranking or collateral benefit" do
      deribit = deribit_plan(:deribit, margin_stub(100, 120))
      okx = okx_plan(:okx, okx_stub())

      assert {:ok, result} =
               OptionProposal.compare_margin_impact(problem([deribit, okx], weights: %{initial_margin_impact: 1}))

      assert Enum.sort(result.cross_venue.venues) == ["deribit", "okx"]
      assert result.cross_venue.portfolio_margin_netting == false
      assert result.cross_venue.global_ranking == nil
      assert length(result.collateral_domains) == 2
      assert Enum.all?(result.comparisons, &(&1.status == :insufficient_candidates))
      assert Enum.all?(result.comparisons, &is_nil(&1.winner_plan_id))
      assert RequestCollector.paths(okx.request_collector) == List.duplicate("/api/v5/account/position-builder", 2)
    end

    test "fails when the provider did not expose a weighted metric" do
      plans = [
        deribit_plan(:one, margin_stub(100, 120)),
        deribit_plan(:two, margin_stub(100, 130))
      ]

      assert {:error, %Error{type: :not_supported} = error} =
               OptionProposal.compare_margin_impact(problem(plans, weights: %{liquidation_distance: 1}))

      assert error.message =~ "provider did not expose"
      assert error.message =~ "liquidation_distance"
    end
  end

  describe "narrow provider evidence" do
    test "single-order and position-scenario observations remain uncomposed" do
      bybit = bybit_plan(:bybit_order, bybit_stub())
      derive = derive_plan(:derive_scenario, derive_stub())

      assert {:ok, result} =
               OptionProposal.compare_margin_impact(problem([bybit, derive], weights: %{initial_margin_impact: 1}))

      assert result.comparisons == []
      assert result.cross_venue.global_ranking == nil
      assert result.portfolio_margin_netting == false

      bybit_observation = Enum.find(result.observations, &(&1.plan_id == :bybit_order))
      derive_observation = Enum.find(result.observations, &(&1.plan_id == :derive_scenario))

      assert bybit_observation.capability_label == :single_order_margin_quote
      assert bybit_observation.comparable? == false
      assert bybit_observation.metrics.initial_margin_rate_impact_e4 == 327.0
      assert bybit_observation.effects.liquidation == %{}
      assert RequestCollector.paths(bybit.request_collector) == ["/v5/order/pre-check"]

      assert derive_observation.capability_label == :position_scenario_margin
      assert derive_observation.comparable? == false
      assert derive_observation.metrics.initial_margin_impact == 5.0
      assert derive_observation.effects.capacity == %{is_valid_trade: true}
      assert RequestCollector.paths(derive.request_collector) == ["/private/get_margin"]
    end
  end

  describe "provider response errors" do
    test "malformed provider success envelopes fail loudly" do
      malformed = %{"unexpected" => true}

      plans = [
        deribit_plan(:deribit, response_stub(malformed)),
        okx_plan(:okx, response_stub(malformed)),
        bybit_plan(:bybit, response_stub(malformed)),
        derive_plan(:derive, response_stub(malformed))
      ]

      for plan <- plans do
        assert {:error, %Error{type: :exchange_error, raw: ^malformed}} =
                 OptionProposal.compare_margin_impact(problem([plan]))
      end
    end

    test "non-numeric provider values cannot enter a weighted comparison" do
      response = %{
        "result" => %{
          "initial_margin" => "unknown",
          "projected_initial_margin" => nil,
          "maintenance_margin" => 10,
          "projected_maintenance_margin" => "12"
        }
      }

      plans = [
        deribit_plan(:one, response_stub(response)),
        deribit_plan(:two, response_stub(response))
      ]

      assert {:error, %Error{type: :not_supported, message: message}} =
               OptionProposal.compare_margin_impact(problem(plans, weights: %{initial_margin_impact: 1}))

      assert message =~ "initial_margin_impact"
    end
  end

  test "rejects nil ids or accounts, non-positive weights, and non-keyword request options" do
    nil_id = deribit_plan(nil, margin_stub(100, 120))

    assert {:error, %Error{type: :invalid_parameters, message: message}} =
             OptionProposal.compare_margin_impact(problem([nil_id]))

    assert message =~ "ids cannot be nil"

    valid = deribit_plan(:valid, margin_stub(100, 120))

    assert {:error, %Error{type: :invalid_parameters, message: message}} =
             valid
             |> Map.put(:account, nil)
             |> then(&OptionProposal.compare_margin_impact(problem([&1])))

    assert message =~ "account cannot be nil"

    assert {:error, %Error{type: :invalid_parameters, message: message}} =
             OptionProposal.compare_margin_impact(problem([valid], weights: %{initial_margin_impact: 0}))

    assert message =~ "positive"

    invalid_opts = Map.put(valid, :request_opts, [:not_a_keyword])

    assert {:error, %Error{type: :invalid_parameters, message: message}} =
             OptionProposal.compare_margin_impact(problem([invalid_opts]))

    assert message =~ "keyword list"
  end

  test "rejects malformed comparison and plan inputs before provider calls" do
    assert {:error, %Error{type: :invalid_parameters}} =
             OptionProposal.compare_margin_impact(nil)

    assert {:error, %Error{type: :invalid_parameters, message: empty_message}} =
             OptionProposal.compare_margin_impact(problem([]))

    assert empty_message =~ "non-empty"

    valid = deribit_plan(:valid, margin_stub(100, 120))

    assert {:error, %Error{type: :invalid_parameters, message: objective_message}} =
             OptionProposal.compare_margin_impact(problem([valid], objective: :guess))

    assert objective_message =~ "objective"

    assert {:error, %Error{type: :invalid_parameters, message: tie_message}} =
             OptionProposal.compare_margin_impact(problem([valid], tie_break_policy: [:unknown]))

    assert tie_message =~ "tie_break_policy"

    assert {:error, %Error{type: :invalid_parameters, message: missing_message}} =
             valid
             |> Map.delete(:provider_params)
             |> then(&OptionProposal.compare_margin_impact(problem([&1])))

    assert missing_message =~ "provider_params"

    assert {:error, %Error{type: :invalid_parameters, message: duplicate_message}} =
             OptionProposal.compare_margin_impact(problem([valid, deribit_plan(:valid, margin_stub(100, 130))]))

    assert duplicate_message =~ "unique"
  end

  test "requires provider-specific domain and baseline inputs" do
    deribit =
      :deribit
      |> deribit_plan(margin_stub(100, 120))
      |> put_in([:provider_params], %{})

    assert {:error, %Error{type: :invalid_parameters, message: currency_message}} =
             OptionProposal.compare_margin_impact(problem([deribit]))

    assert currency_message =~ "currency"

    okx =
      :okx
      |> okx_plan(okx_stub())
      |> Map.delete(:baseline_provider_params)

    assert {:error, %Error{type: :invalid_parameters, message: baseline_message}} =
             OptionProposal.compare_margin_impact(problem([okx]))

    assert baseline_message =~ "baseline_provider_params"
  end

  test "caller controls objective, weights, and tie-break policy" do
    first = deribit_plan(:zeta, margin_stub(100, 120))
    second = deribit_plan(:alpha, margin_stub(100, 120))

    assert {:ok, result} =
             OptionProposal.compare_margin_impact(
               problem([first, second],
                 objective: :maximize,
                 weights: %{initial_margin_impact: 3},
                 tie_break_policy: [:plan_id]
               )
             )

    assert result.objective == :maximize
    assert result.weights == %{initial_margin_impact: 3}
    assert result.tie_break_policy == [:plan_id]
    assert hd(hd(result.comparisons).ranking).plan_id == :alpha
  end

  defp problem(plans, overrides \\ []) do
    %{
      candidate_plans: plans,
      objective: Keyword.get(overrides, :objective, :minimize),
      weights: Keyword.get(overrides, :weights, %{initial_margin_impact: 1}),
      tie_break_policy: Keyword.get(overrides, :tie_break_policy, [:plan_order])
    }
  end

  defp deribit_plan(id, {stub, requests}, overrides \\ []) do
    %{
      id: id,
      exchange: exchange("deribit"),
      account: "main",
      account_mode: Keyword.get(overrides, :account_mode, :portfolio_margin),
      provider_params: %{
        "currency" => "BTC",
        "add_positions" => true,
        "simulated_positions" => ~s({"BTC-PERPETUAL":1})
      },
      request_opts: [plug: {Req.Test, stub}],
      request_collector: requests
    }
  end

  defp okx_plan(id, {stub, requests}) do
    %{
      id: id,
      exchange: exchange("okx"),
      account: "demo",
      account_mode: :multi_currency_margin,
      baseline_provider_params: %{"acctLv" => "3", "inclRealPosAndEq" => true},
      provider_params: %{
        "acctLv" => "3",
        "inclRealPosAndEq" => true,
        "simPos" => [%{"instId" => "BTC-USDT-SWAP", "pos" => "1", "avgPx" => "100000"}]
      },
      request_opts: [plug: {Req.Test, stub}],
      request_collector: requests
    }
  end

  defp bybit_plan(id, {stub, requests}) do
    %{
      id: id,
      exchange: exchange("bybit"),
      account: "uta",
      account_mode: :cross_margin,
      provider_params: %{
        "category" => "option",
        "symbol" => "BTC-31JUL26-100000-C",
        "side" => "Buy",
        "orderType" => "Limit",
        "qty" => "0.1",
        "price" => "0.1"
      },
      request_opts: [plug: {Req.Test, stub}],
      request_collector: requests
    }
  end

  defp derive_plan(id, {stub, requests}) do
    %{
      id: id,
      exchange: exchange("derive"),
      account: 144_422,
      account_mode: :standard_margin,
      provider_params: %{
        "subaccount_id" => 144_422,
        "simulated_position_changes" => []
      },
      request_opts: [plug: {Req.Test, stub}],
      request_collector: requests
    }
  end

  defp margin_stub(initial, projected, maintenance \\ 80, projected_maintenance \\ 100) do
    response = %{
      "jsonrpc" => "2.0",
      "result" => %{
        "currency" => "BTC",
        "initial_margin" => initial,
        "projected_initial_margin" => projected,
        "maintenance_margin" => maintenance,
        "projected_maintenance_margin" => projected_maintenance,
        "available_funds" => 900
      }
    }

    response_stub(response)
  end

  defp okx_stub do
    response_stub(%{
      "code" => "0",
      "data" => [
        %{
          "totalImr" => "10",
          "totalMmr" => "5",
          "eq" => "1000",
          "marginRatio" => "100"
        }
      ],
      "msg" => ""
    })
  end

  defp bybit_stub do
    response_stub(%{
      "retCode" => 0,
      "retMsg" => "OK",
      "result" => %{
        "preImrE4" => 30,
        "preMmrE4" => 21,
        "postImrE4" => 357,
        "postMmrE4" => 294
      }
    })
  end

  defp derive_stub do
    response_stub(%{
      "result" => %{
        "subaccount_id" => 144_422,
        "is_valid_trade" => true,
        "pre_initial_margin" => "20",
        "post_initial_margin" => "25",
        "pre_maintenance_margin" => "15",
        "post_maintenance_margin" => "18"
      }
    })
  end

  defp response_stub(response) do
    stub = {__MODULE__, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, response)
    end)

    {stub, requests}
  end

  defp exchange("okx") do
    credentials = Credentials.new!(api_key: "key", secret: "secret", password: "passphrase")
    Exchange.new!("okx", credentials: credentials, sandbox: true)
  end

  defp exchange("derive") do
    credentials =
      Credentials.new!(
        api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
        secret: @private_key
      )

    Exchange.new!("derive", credentials: credentials, sandbox: true)
  end

  defp exchange(venue) do
    credentials = Credentials.new!(api_key: "key", secret: "secret")
    Exchange.new!(venue, credentials: credentials, sandbox: true)
  end
end
