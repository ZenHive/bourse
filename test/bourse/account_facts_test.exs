defmodule Bourse.AccountFactsTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified.ReadParse

  @bybit_invalid_request_code 10_001
  @fixed_timestamp_ms 1_700_000_000_000

  describe "provider mappings" do
    test "alpaca keeps product access and account margin model independent" do
      body = fixture_body("alpaca")

      assert {:ok, facts} = ReadParse.account_facts(Exchange.new!("alpaca"), body)
      assert facts.info == body

      assert facts.product_access == %{
               status: :observed,
               provider_fields: ["shorting_enabled"],
               value: %{"shorting_enabled" => true}
             }

      assert facts.account_margin_model == %{
               status: :observed,
               provider_fields: ["multiplier"],
               value: %{"multiplier" => "4"}
             }

      assert facts.position_margin_modes == unavailable([])
    end

    test "bybit maps account info classifications without a position inference" do
      body = %{
        "retCode" => 0,
        "result" => %{"unifiedMarginStatus" => 3, "marginMode" => "REGULAR_MARGIN"}
      }

      assert {:ok, facts} = ReadParse.account_facts(Exchange.new!("bybit"), body)

      assert facts.product_access == %{
               status: :observed,
               provider_fields: ["unifiedMarginStatus"],
               value: %{"unifiedMarginStatus" => 3}
             }

      assert facts.account_margin_model == %{
               status: :observed,
               provider_fields: ["marginMode"],
               value: %{"marginMode" => "REGULAR_MARGIN"}
             }

      assert facts.position_margin_modes == unavailable([])
      assert facts.info == body
    end

    test "deribit preserves per-currency product and margin classifications" do
      body = fixture_body("deribit")

      assert {:ok, facts} = ReadParse.account_facts(Exchange.new!("deribit"), body)
      assert facts.product_access.status == :observed
      assert facts.product_access.provider_fields == ["portfolio_margining_enabled"]
      assert Enum.all?(facts.product_access.value, &Map.has_key?(&1, "portfolio_margining_enabled"))
      assert facts.account_margin_model.status == :observed
      assert facts.account_margin_model.provider_fields == ["margin_model"]
      assert Enum.all?(facts.account_margin_model.value, &Map.has_key?(&1, "margin_model"))
      assert facts.position_margin_modes == unavailable([])
      assert facts.info == body
    end

    test "binance spot and derivative fields remain separate facts" do
      spot_body = fixture_body("binance")

      assert {:ok, spot_facts} = ReadParse.account_facts(Exchange.new!("binance"), spot_body)

      assert spot_facts.product_access == %{
               status: :observed,
               provider_fields: ["accountType", "permissions"],
               value: %{"accountType" => "SPOT", "permissions" => ["SPOT"]}
             }

      assert spot_facts.account_margin_model == unavailable([])
      assert spot_facts.position_margin_modes == unavailable(["isolated"])

      derivative_body = %{
        "canTrade" => true,
        "positions" => [
          %{"symbol" => "BTCUSDT", "isolated" => false},
          %{"symbol" => "ETHUSDT", "isolated" => true}
        ]
      }

      assert {:ok, derivative_facts} =
               ReadParse.account_facts(Exchange.new!("binance"), derivative_body)

      assert derivative_facts.product_access ==
               unavailable(["accountType", "permissions"])

      assert derivative_facts.account_margin_model == unavailable([])

      assert derivative_facts.position_margin_modes == %{
               status: :observed,
               provider_fields: ["isolated"],
               value: [
                 %{"symbol" => "BTCUSDT", "isolated" => false},
                 %{"symbol" => "ETHUSDT", "isolated" => true}
               ]
             }

      assert derivative_facts.info == derivative_body
    end

    test "hyperliquid reports an empty position observation as unavailable" do
      body = fixture_body("hyperliquid")

      assert {:ok, facts} = ReadParse.account_facts(Exchange.new!("hyperliquid"), body)
      assert facts.product_access == unavailable([])

      assert facts.account_margin_model == %{
               status: :observed,
               provider_fields: ["crossMarginSummary"],
               value: %{"crossMarginSummary" => body["crossMarginSummary"]}
             }

      assert facts.position_margin_modes == unavailable(["leverage.type"])
      assert facts.info == body
    end

    test "hyperliquid maps provider position leverage types when positions exist" do
      body = %{
        "crossMarginSummary" => %{"accountValue" => "10.0"},
        "assetPositions" => [
          %{"position" => %{"coin" => "BTC", "leverage" => %{"type" => "cross", "value" => 3}}}
        ]
      }

      assert {:ok, facts} = ReadParse.account_facts(Exchange.new!("hyperliquid"), body)

      assert facts.position_margin_modes == %{
               status: :observed,
               provider_fields: ["leverage.type"],
               value: [%{"coin" => "BTC", "leverage" => %{"type" => "cross", "value" => 3}}]
             }
    end

    test "lighter preserves account and position classification fields" do
      body = fixture_body("lighter")

      assert {:ok, facts} = ReadParse.account_facts(Exchange.new!("lighter"), body)
      assert facts.product_access.status == :observed
      assert facts.product_access.provider_fields == ["account_type"]
      assert Enum.all?(facts.product_access.value, &Map.has_key?(&1, "account_type"))
      assert facts.account_margin_model.status == :observed
      assert facts.account_margin_model.provider_fields == ["account_trading_mode"]
      assert Enum.all?(facts.account_margin_model.value, &Map.has_key?(&1, "account_trading_mode"))
      assert facts.position_margin_modes.status == :observed
      assert facts.position_margin_modes.provider_fields == ["margin_mode"]
      assert Enum.all?(facts.position_margin_modes.value, &Map.has_key?(&1, "margin_mode"))
      assert facts.info == body
    end

    test "provider error envelopes and unmapped venues fail explicitly" do
      assert {:error, %Error{type: :exchange_error}} =
               ReadParse.account_facts(
                 Exchange.new!("bybit"),
                 %{"retCode" => @bybit_invalid_request_code, "retMsg" => "invalid request"}
               )

      assert {:error, %Error{type: :not_supported}} =
               ReadParse.account_facts(Exchange.new!("okx"), %{})

      assert {:error, %Error{type: :exchange_error, raw: %{"result" => []}}} =
               ReadParse.account_facts(Exchange.new!("bybit"), %{"result" => []})
    end
  end

  describe "unified dispatch" do
    test "bybit reads the account-info endpoint and preserves its envelope" do
      test_pid = self()
      stub = unique_stub("bybit_account_facts")
      body = %{"retCode" => 0, "result" => %{"unifiedMarginStatus" => 3, "marginMode" => "REGULAR_MARGIN"}}

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:account_facts_path, conn.request_path})
        Req.Test.json(conn, body)
      end)

      exchange = exchange_with_credentials("bybit")

      assert {:ok, %{info: ^body}} =
               Bourse.fetch_account_facts(exchange,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: @fixed_timestamp_ms
               )

      assert_receive {:account_facts_path, "/v5/account/info"}
    end

    test "binance uses the requested provider surface but never returns that selector as a fact" do
      test_pid = self()
      stub = unique_stub("binance_account_facts")
      body = %{"canTrade" => true, "positions" => [%{"symbol" => "BTCUSDT", "isolated" => false}]}

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:account_facts_path, conn.request_path, conn.query_string})
        Req.Test.json(conn, body)
      end)

      exchange = exchange_with_credentials("binance")

      assert {:ok, facts} =
               Bourse.fetch_account_facts(exchange,
                 type: "swap",
                 plug: {Req.Test, stub},
                 timestamp_ms_override: @fixed_timestamp_ms
               )

      assert facts.product_access == unavailable(["accountType", "permissions"])
      assert facts.account_margin_model == unavailable([])
      assert facts.position_margin_modes.status == :observed
      assert facts.info == body

      assert_receive {:account_facts_path, "/fapi/v2/account", query}
      refute URI.decode_query(query)["type"]
    end

    test "binance resolves spot, inverse, and default-family account surfaces" do
      test_pid = self()
      stub = unique_stub("binance_account_fact_families")

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:account_facts_path, conn.request_path})
        Req.Test.json(conn, %{"accountType" => "SPOT", "permissions" => ["SPOT"], "positions" => []})
      end)

      exchange = exchange_with_credentials("binance")
      exchange_without_default = %{exchange | default_family: nil}

      for {selected_exchange, opts, path} <- [
            {exchange, [subType: "inverse"], "/dapi/v1/account"},
            {exchange, [type: "spot"], "/api/v3/account"},
            {exchange_without_default, [], "/api/v3/account"}
          ] do
        assert {:ok, _facts} =
                 Bourse.fetch_account_facts(
                   selected_exchange,
                   opts ++ [plug: {Req.Test, stub}, timestamp_ms_override: @fixed_timestamp_ms]
                 )

        assert_receive {:account_facts_path, ^path}
      end
    end

    test "deribit account facts use the authenticated balance route" do
      test_pid = self()
      stub = unique_stub("deribit_account_facts")
      body = fixture_body("deribit")

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:account_facts_path, conn.request_path})
        Req.Test.json(conn, body)
      end)

      assert {:ok, %{info: ^body}} =
               Bourse.fetch_account_facts(exchange_with_credentials("deribit"),
                 plug: {Req.Test, stub},
                 timestamp_ms_override: @fixed_timestamp_ms
               )

      assert_receive {:account_facts_path, "/api/v2/private/get_account_summaries"}
    end

    test "bybit reports a missing authored account-info endpoint" do
      exchange = %{exchange_with_credentials("bybit") | module: Bourse.Alpaca}

      assert {:error, %Error{type: :not_supported, message: message}} =
               Bourse.fetch_account_facts(exchange)

      assert message =~ "does not expose the account classification endpoint"
    end

    test "unmapped venue and binance family return not-supported errors" do
      assert {:error, %Error{type: :not_supported}} =
               Bourse.fetch_account_facts(Exchange.new!("okx"))

      assert {:error, %Error{type: :not_supported}} =
               Bourse.fetch_account_facts(exchange_with_credentials("binance"), type: "option")
    end
  end

  defp fixture_body(venue) do
    "test/fixtures/responses/#{venue}/fetch_balance.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("body")
  end

  defp exchange_with_credentials(venue) do
    credentials = Credentials.new!(api_key: "test-key", secret: "test-secret")
    Exchange.new!(venue, credentials: credentials)
  end

  defp unavailable(provider_fields) do
    %{status: :unavailable, provider_fields: provider_fields, value: nil}
  end

  defp unique_stub(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
