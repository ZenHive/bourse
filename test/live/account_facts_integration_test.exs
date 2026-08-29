defmodule Bourse.AccountFactsIntegrationTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Exchange

  @moduletag :integration
  @moduletag :network

  @alpaca_credentials_url "https://app.alpaca.markets/paper/dashboard/overview"
  @binance_spot_credentials_url "https://testnet.binance.vision"
  @binance_futures_credentials_url "https://demo-fapi.binance.com"
  @bybit_credentials_url "https://testnet.bybit.com"
  @bybit_demo_url "https://api-demo.bybit.com"
  @deribit_credentials_url "https://test.deribit.com"
  @hyperliquid_credentials_url "https://app.hyperliquid-testnet.xyz"
  @lighter_credentials_url "https://testnet.zklighter.elliot.ai"

  test "alpaca paper account exposes multiplier and shorting_enabled" do
    env = require_env!("Alpaca paper account", ["ALPACA_API_KEY", "ALPACA_API_SECRET"], @alpaca_credentials_url)

    exchange =
      Exchange.new!("alpaca",
        credentials: Credentials.new!(api_key: env["ALPACA_API_KEY"], secret: env["ALPACA_API_SECRET"]),
        sandbox: true
      )

    assert {:ok, facts} = Bourse.fetch_account_facts(exchange)
    assert facts.info["multiplier"] == facts.account_margin_model.value["multiplier"]
    assert facts.info["shorting_enabled"] == facts.product_access.value["shorting_enabled"]
    assert facts.account_margin_model.provider_fields == ["multiplier"]
    assert facts.product_access.provider_fields == ["shorting_enabled"]
    assert facts.account_margin.status == :unavailable
    assert facts.account_margin.value == nil
  end

  test "bybit demo account exposes unifiedMarginStatus and marginMode" do
    env =
      require_env!(
        "Bybit demo account",
        ["BYBIT_DEMO_API_KEY", "BYBIT_DEMO_API_SECRET"],
        @bybit_credentials_url
      )

    exchange =
      Exchange.new!("bybit",
        credentials: Credentials.new!(api_key: env["BYBIT_DEMO_API_KEY"], secret: env["BYBIT_DEMO_API_SECRET"])
      )

    assert {:ok, facts} = Bourse.fetch_account_facts(exchange, base_url: @bybit_demo_url)
    result = Map.fetch!(facts.info, "result")
    assert result["unifiedMarginStatus"] == facts.product_access.value["unifiedMarginStatus"]
    assert result["marginMode"] == facts.account_margin_model.value["marginMode"]
    assert facts.product_access.provider_fields == ["unifiedMarginStatus"]
    assert facts.account_margin_model.provider_fields == ["marginMode"]
    assert facts.account_margin.status == :unavailable
    assert facts.account_margin.value == nil
  end

  test "binance spot and USD-M accounts expose their independent provider fields" do
    spot_env =
      require_env!(
        "Binance spot testnet account",
        ["BINANCE_TESTNET_API_KEY", "BINANCE_TESTNET_API_SECRET"],
        @binance_spot_credentials_url
      )

    spot_exchange =
      Exchange.new!("binance",
        credentials:
          Credentials.new!(
            api_key: spot_env["BINANCE_TESTNET_API_KEY"],
            secret: spot_env["BINANCE_TESTNET_API_SECRET"]
          ),
        sandbox: true
      )

    assert {:ok, spot_facts} = Bourse.fetch_account_facts(spot_exchange)
    assert is_binary(spot_facts.info["accountType"])
    assert is_list(spot_facts.info["permissions"])
    assert spot_facts.product_access.value == Map.take(spot_facts.info, ["accountType", "permissions"])
    assert spot_facts.account_margin.status == :unavailable

    futures_env =
      require_env!(
        "Binance USD-M demo account",
        ["BINANCE_FUTURES_TEST_API_KEY", "BINANCE_FUTURES_TEST_API_SECRET"],
        @binance_futures_credentials_url
      )

    futures_exchange =
      Exchange.new!("binance",
        credentials:
          Credentials.new!(
            api_key: futures_env["BINANCE_FUTURES_TEST_API_KEY"],
            secret: futures_env["BINANCE_FUTURES_TEST_API_SECRET"]
          ),
        sandbox: true
      )

    assert {:ok, futures_facts} = Bourse.fetch_account_facts(futures_exchange, type: "swap")
    assert is_list(futures_facts.info["positions"])
    assert futures_facts.info["positions"] != []
    assert Enum.all?(futures_facts.info["positions"], &Map.has_key?(&1, "isolated"))
    assert futures_facts.position_margin_modes.status == :observed
    assert futures_facts.position_margin_modes.provider_fields == ["isolated"]
    assert futures_facts.account_margin.status == :unavailable
  end

  test "deribit account summaries expose portfolio_margining_enabled and margin_model" do
    env =
      require_env!(
        "Deribit testnet account",
        ["DERIBIT_TESTNET_API_KEY", "DERIBIT_TESTNET_API_SECRET"],
        @deribit_credentials_url
      )

    exchange =
      Exchange.new!("deribit",
        credentials:
          Credentials.new!(
            api_key: env["DERIBIT_TESTNET_API_KEY"],
            secret: env["DERIBIT_TESTNET_API_SECRET"]
          ),
        sandbox: true
      )

    assert {:ok, facts} = Bourse.fetch_account_facts(exchange)
    summaries = get_in(facts.info, ["result", "summaries"])
    assert is_list(summaries) and summaries != []
    assert Enum.all?(summaries, &Map.has_key?(&1, "portfolio_margining_enabled"))
    assert Enum.all?(summaries, &Map.has_key?(&1, "margin_model"))
    assert facts.product_access.provider_fields == ["portfolio_margining_enabled"]
    assert facts.account_margin_model.provider_fields == ["margin_model"]
    assert facts.account_margin.status == :observed

    assert facts.account_margin.provider_fields == [
             "initial_margin",
             "maintenance_margin",
             "projected_initial_margin",
             "projected_maintenance_margin",
             "margin_balance",
             "projected_close_out_margin",
             "close_out_margin",
             "total_initial_margin_usd",
             "total_maintenance_margin_usd",
             "total_margin_balance_usd"
           ]

    assert facts.account_margin.value != []

    for row <- facts.account_margin.value do
      summary = Enum.find(summaries, &(&1["currency"] == row["currency"]))
      assert summary, "account_margin row #{inspect(row)} has no matching summary"
      assert is_binary(row["currency"])
      assert row["initial_margin"]
      assert row["initial_margin"] == summary["initial_margin"]
      assert row["maintenance_margin"] == summary["maintenance_margin"]
      assert row["margin_balance"] == summary["margin_balance"]
    end
  end

  test "hyperliquid clearinghouse state exposes crossMarginSummary and observed leverage types" do
    env =
      require_env!(
        "Hyperliquid testnet account",
        ["HYPERLIQUID_TESTNET_API_KEY", "HYPERLIQUID_TESTNET_API_SECRET"],
        @hyperliquid_credentials_url
      )

    exchange =
      Exchange.new!("hyperliquid",
        credentials:
          Credentials.new!(
            api_key: env["HYPERLIQUID_TESTNET_API_KEY"],
            secret: env["HYPERLIQUID_TESTNET_API_SECRET"]
          ),
        sandbox: true
      )

    assert {:ok, facts} = Bourse.fetch_account_facts(exchange)
    assert is_map(facts.info["crossMarginSummary"])
    assert facts.account_margin_model.value == %{"crossMarginSummary" => facts.info["crossMarginSummary"]}
    assert facts.account_margin.status == :unavailable
    assert facts.account_margin.value == nil

    case facts.info["assetPositions"] do
      [] ->
        assert facts.position_margin_modes == unavailable(["leverage.type"])

      [_position | _rest] = positions ->
        assert Enum.all?(positions, &is_binary(get_in(&1, ["position", "leverage", "type"])))
        assert facts.position_margin_modes.status == :observed
        assert facts.position_margin_modes.provider_fields == ["leverage.type"]

      other ->
        flunk("Unexpected Hyperliquid assetPositions shape: #{inspect(other)}")
    end
  end

  test "lighter account exposes account_type, account_trading_mode, and margin_mode" do
    env =
      require_env!(
        "Lighter testnet account",
        [
          "LIGHTER_TESTNET_API_KEY_INDEX",
          "LIGHTER_TESTNET_ACCOUNT_INDEX",
          "LIGHTER_TESTNET_API_PRIVATE_KEY"
        ],
        @lighter_credentials_url
      )

    account_index = String.to_integer(env["LIGHTER_TESTNET_ACCOUNT_INDEX"])

    exchange =
      Exchange.new!("lighter",
        credentials:
          Credentials.new!(
            api_key: env["LIGHTER_TESTNET_API_KEY_INDEX"],
            uid: env["LIGHTER_TESTNET_ACCOUNT_INDEX"],
            secret: env["LIGHTER_TESTNET_API_PRIVATE_KEY"]
          ),
        sandbox: true,
        options: %{account_index: account_index}
      )

    assert {:ok, facts} = Bourse.fetch_account_facts(exchange, account_index: account_index)
    accounts = Map.fetch!(facts.info, "accounts")
    assert accounts != []
    assert Enum.all?(accounts, &Map.has_key?(&1, "account_type"))
    assert Enum.all?(accounts, &Map.has_key?(&1, "account_trading_mode"))
    assert Enum.all?(accounts, &is_list(&1["positions"]))
    positions = Enum.flat_map(accounts, & &1["positions"])
    assert positions != []
    assert Enum.all?(positions, &Map.has_key?(&1, "margin_mode"))
    assert facts.product_access.provider_fields == ["account_type"]
    assert facts.account_margin_model.provider_fields == ["account_trading_mode"]
    assert facts.position_margin_modes.provider_fields == ["margin_mode"]
    assert facts.account_margin.status == :unavailable
    assert facts.account_margin.value == nil
  end

  defp require_env!(label, names, credentials_url) do
    missing = Enum.reject(names, &present_env?/1)

    if missing != [] do
      exports = Enum.map_join(names, "\n", &~s(  export #{&1}="your_value"))

      flunk("""
      Missing credentials for #{label}: #{Enum.join(missing, ", ")}

      Set these environment variables:
      #{exports}

      Get credentials at: #{credentials_url}
      """)
    end

    Map.new(names, &{&1, System.fetch_env!(&1)})
  end

  defp present_env?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
    end
  end

  defp unavailable(provider_fields) do
    %{status: :unavailable, provider_fields: provider_fields, value: nil}
  end
end
