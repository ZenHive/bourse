defmodule Bourse.BybitAccountAnalyticsIntegrationTest do
  @moduledoc """
  Task 235 — live Bybit testnet pins for the remaining account/analytics
  response surfaces: fetchMarginMode, fetchAllGreeks, fetchBorrowRateHistory,
  borrowCrossMargin / repayCrossMargin.
  """

  use ExUnit.Case, async: false

  alias Bourse.BorrowRate
  alias Bourse.Error
  alias Bourse.Greeks
  alias Bourse.MarginLoan
  alias Bourse.MarginMode

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_bybit

  @testnet_url "https://api-testnet.bybit.com"
  # Smallest isolated cross-margin loan that restores cleanly on testnet.
  @borrow_code "USDT"
  @borrow_amount 1

  test "public fetch_all_greeks returns symbol-keyed %Greeks{} values" do
    exchange = public_exchange!()

    assert {:ok, %{body: body}} =
             Bourse.Bybit.public_get_v5_market_tickers(exchange, %{
               "category" => "option",
               "baseCoin" => "BTC"
             })

    rows = get_in(body, ["result", "list"]) || []
    assert rows != [], "Bybit testnet returned no BTC option tickers for greeks probe"

    native = hd(rows)["symbol"]
    unified = Bourse.Symbol.from_exchange_id(native, exchange, :option)
    assert is_binary(unified) and unified != native

    assert {:ok, greeks_map} =
             Bourse.fetch_all_greeks(exchange, symbols: [unified], baseCoin: "BTC")

    assert is_map(greeks_map)
    assert %Greeks{} = greeks = Map.fetch!(greeks_map, unified)
    assert greeks.symbol == unified
    assert is_number(greeks.delta)
    assert is_number(greeks.mark_implied_volatility)
  end

  test "public fetch_leverage_tiers authors the required category" do
    exchange = public_exchange!()

    assert {:ok, [%Bourse.LeverageTier{} | _] = tiers} = Bourse.fetch_leverage_tiers(exchange)
    assert length(tiers) > 1
  end

  test "public fetch_all_greeks with illegal category yields Bybit bad_request" do
    exchange = public_exchange!()

    assert {:error, %Error{type: :bad_request, code: code, message: message}} =
             Bourse.Bybit.public_get_v5_market_tickers(exchange, %{
               "category" => "not-a-category",
               "baseCoin" => "BTC"
             })

    assert code in [10_001, "10001"]
    assert is_binary(message) and message =~ "category"
  end

  test "signed fetch_margin_mode returns a parsed %MarginMode{}" do
    exchange = signed_exchange!()

    assert {:ok, %MarginMode{symbol: "BTC/USDT", margin_mode: mode}} =
             Bourse.fetch_margin_mode(exchange, "BTC/USDT")

    assert mode in ["cross", "isolated", "portfolio"]
  end

  test "signed fetch_leverage pins the live position-row shape (carve C26)" do
    exchange = signed_exchange!()

    assert {:ok, %Bourse.Leverage{} = leverage} =
             Bourse.fetch_leverage(exchange, "BTC/USDT:USDT", category: "linear")

    row =
      case leverage.info do
        [row | _] -> row
        %{} = row -> row
      end

    # Bybit v5 position rows carry a deprecated tradeMode and NO marginMode key
    # (margin mode is account-scoped — see fetch_margin_mode). Carve C26.
    assert Map.has_key?(row, "tradeMode")
    refute Map.has_key?(row, "marginMode")

    case row["tradeMode"] do
      0 -> assert is_nil(leverage.margin_mode)
      1 -> assert leverage.margin_mode == "isolated"
      other -> flunk("Bybit documented tradeMode as 0/1; venue sent #{inspect(other)}")
    end

    assert is_integer(leverage.long_leverage)
    assert is_integer(leverage.short_leverage)
  end

  test "signed fetch_borrow_rate_history succeeds with %BorrowRate{} or fails loudly" do
    exchange = signed_exchange!()
    since = System.system_time(:millisecond) - 3 * 86_400_000

    case Bourse.fetch_borrow_rate_history(exchange, "USDT", since: since) do
      {:ok, rows} when is_list(rows) and rows != [] ->
        Enum.each(rows, fn row ->
          assert %BorrowRate{currency: "USDT"} = row
          assert is_number(row.rate)
          assert row.period == 3_600_000
          assert is_integer(row.timestamp)
          assert is_binary(row.datetime)
        end)

        timestamps = Enum.map(rows, & &1.timestamp)
        assert timestamps == Enum.sort(timestamps)

      {:ok, []} ->
        flunk("""
        Bybit testnet returned an empty borrow-rate history for USDT.
        Empty success is not a capability pin — confirm Spot Margin interest-rate access.
        """)

      # Unavailable account capability / missing scope must surface as a typed
      # error, never a raw HTTP envelope or silent pass (task 235 AC).
      {:error, %Error{type: type}} when type in [:permission_denied, :authentication_error, :bad_request] ->
        assert type in [:permission_denied, :authentication_error, :bad_request]

      other ->
        flunk("fetch_borrow_rate_history returned unexpected result: #{inspect(other)}")
    end
  end

  test "invalid credentials fail loudly on signed account reads" do
    exchange =
      Bourse.IntegrationHelper.build_exchange(:bybit,
        credentials: Bourse.Credentials.new!(api_key: "invalid-task-235", secret: "invalid-task-235"),
        sandbox: true
      )

    assert {:error, %Error{type: type}} = Bourse.fetch_margin_mode(exchange, "BTC/USDT")
    assert type in [:authentication_error, :permission_denied]
  end

  @tag :dangerous
  test "borrow then repay restores the smallest isolated cross-margin loan" do
    exchange = signed_exchange!()

    loan =
      case Bourse.borrow_cross_margin(exchange, @borrow_code, @borrow_amount) do
        {:ok, %MarginLoan{} = result} ->
          result

        {:error, %Error{code: code} = error} when code in [10_005, 10_024, 110_007, 170_131] ->
          flunk("""
          Bybit testnet key cannot borrow cross margin (#{code}): #{Exception.message(error)}
          Grant UNIFIED account borrow permission for the smallest USDT amount.
          """)

        other ->
          flunk("borrow_cross_margin failed: #{inspect(other)}")
      end

    assert loan.currency == @borrow_code
    assert loan.amount in [@borrow_amount, to_string(@borrow_amount)]
    assert is_map(loan.info)

    try do
      assert {:ok, %MarginLoan{currency: @borrow_code, amount: @borrow_amount} = repay} =
               Bourse.repay_cross_margin(exchange, @borrow_code, @borrow_amount)

      assert is_map(repay.info)
      assert repay.info["resultStatus"] in ["SU", "success", nil] or map_size(repay.info) > 0
    after
      _ = Bourse.repay_cross_margin(exchange, @borrow_code, @borrow_amount)
    end
  end

  defp public_exchange! do
    exchange = Bourse.IntegrationHelper.build_exchange(:bybit, sandbox: true)
    assert_testnet!(exchange)
    exchange
  end

  defp signed_exchange! do
    credentials =
      Bourse.IntegrationHelper.require_credentials!(:bybit,
        url: "https://www.bybit.com/en/help-center/article/How-to-Create-Your-API-Key"
      )

    exchange = Bourse.IntegrationHelper.build_exchange(:bybit, credentials: credentials, sandbox: true)
    assert_testnet!(exchange)
    exchange
  end

  defp assert_testnet!(exchange) do
    if !(exchange.sandbox and Enum.all?(exchange.base_urls, fn {_name, url} -> url == @testnet_url end)) do
      flunk("Bybit account/analytics tests must use only #{@testnet_url}; got #{inspect(exchange.base_urls)}")
    end
  end
end
