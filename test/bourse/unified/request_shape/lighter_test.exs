defmodule Bourse.Unified.RequestShape.LighterTest do
  @moduledoc """
  Pure request-shaping mechanics for Lighter: which params the venue's private
  reads must carry, and how malformed order input is rejected.

  Nothing here asks the venue anything — every assertion is about bytes this
  repo builds before a request exists. Lighter's own semantics are proven live
  in `test/live/lighter/` and `test/live/journeys/trader/lighter_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified.RequestShape.Lighter

  @account_index 153
  @market %{
    id: "1",
    symbol: "BTC/USDC:USDC",
    precision: %{amount: 0.00001, price: 0.1}
  }

  defp exchange(opts \\ []) do
    credentials =
      Credentials.new!(
        api_key: "3",
        uid: to_string(@account_index),
        secret: String.duplicate("ab", 40)
      )

    credentials =
      if Keyword.get(opts, :uid, :keep) == nil, do: %{credentials | uid: nil}, else: credentials

    {:ok, exchange} = Exchange.new("lighter", credentials: credentials, sandbox: true)
    %{exchange | markets: Keyword.get(opts, :markets, [@market])}
  end

  defp order_params(overrides) do
    Map.merge(
      %{
        "symbol" => "BTC/USDC:USDC",
        "type" => "limit",
        "side" => "buy",
        "amount" => 0.011,
        "price" => 78_901.4,
        "client_order_index" => 7,
        "nonce" => 1
      },
      overrides
    )
  end

  describe "private account reads carry the account they are scoped to" do
    # Lighter's private reads are account-scoped in the query string, not only in
    # the auth token. Omitting account_index answers a bare 20001 "invalid param "
    # with no hint (observed live 2026-08-28 against testnet.zklighter.elliot.ai:
    # `accountActiveOrders?market_id=1` -> "invalid param ", while
    # `accountActiveOrders?account_index=153` reaches the auth check).
    for method <- ~w(fetchOpenOrders fetchClosedOrders fetchMyTrades fetchWithdrawals
                     fetchTransfers fetchMyLiquidations) do
      test "#{method} fills account_index and auth_deadline from credentials" do
        built = Lighter.build(%{}, unquote(method), exchange(), [])

        assert built["account_index"] == @account_index
        assert is_integer(built["auth_deadline"])
        assert built["auth_deadline"] > System.system_time(:second)
      end

      test "#{method} lets an explicit account_index win" do
        built = Lighter.build(%{"account_index" => 999}, unquote(method), exchange(), [])

        assert built["account_index"] == 999
      end
    end

    test "fetchBalance and fetchPositions address the public account endpoint by index" do
      for method <- ~w(fetchBalance fetchPositions) do
        built = Lighter.build(%{}, method, exchange(), [])

        assert built["by"] == "index"
        assert built["value"] == @account_index
      end
    end

    test "fetchDeposits demands the L1 address the provider contract requires" do
      assert_raise Error, ~r/requires l1_address/, fn ->
        Lighter.build(%{}, "fetchDeposits", exchange(), [])
      end

      built = Lighter.build(%{"l1_address" => "0xabc"}, "fetchDeposits", exchange(), [])
      assert built["account_index"] == @account_index
    end

    test "an unrelated method is passed through untouched" do
      assert Lighter.build(%{"a" => 1}, "fetchTicker", exchange(), []) == %{"a" => 1}
    end
  end

  describe "account_index resolution" do
    test "falls back to exchange options when credentials carry no uid" do
      exchange = %{exchange(uid: nil) | options: %{"account_index" => "153"}}

      assert Lighter.build(%{}, "fetchMyTrades", exchange, [])["account_index"] == @account_index
    end

    test "a non-numeric account index is rejected loudly" do
      exchange = %{exchange(uid: nil) | options: %{"account_index" => "not-a-number"}}

      assert_raise ArgumentError, ~r/account index must be an integer/, fn ->
        Lighter.build(%{}, "fetchMyTrades", exchange, [])
      end
    end

    test "a missing account index is rejected loudly" do
      exchange = %{exchange(uid: nil) | options: %{}}

      assert_raise ArgumentError, ~r/account index must be an integer/, fn ->
        Lighter.build(%{}, "fetchMyTrades", exchange, [])
      end
    end
  end

  describe "createOrder rejects input the venue cannot represent" do
    test "an unknown symbol names the symbol it could not resolve" do
      assert_raise ArgumentError, ~r|requires a loaded market for NOPE/USDC:USDC|, fn ->
        Lighter.build(order_params(%{"symbol" => "NOPE/USDC:USDC"}), "createOrder", exchange(), [])
      end
    end

    test "unloaded markets are a distinct failure from an unknown symbol" do
      assert_raise ArgumentError, ~r/requires loaded markets/, fn ->
        Lighter.build(order_params(%{}), "createOrder", exchange(markets: nil), [])
      end
    end

    test "a market without the needed precision cannot scale an order" do
      market = Map.put(@market, :precision, %{price: 0.1})

      assert_raise ArgumentError, ~r/requires amount precision/, fn ->
        Lighter.build(order_params(%{}), "createOrder", exchange(markets: [market]), [])
      end
    end

    test "an amount off the precision grid is refused rather than silently rounded" do
      assert_raise Error, ~r/amount does not align with market precision/, fn ->
        Lighter.build(order_params(%{"amount" => 0.0110001}), "createOrder", exchange(), [])
      end
    end

    test "a non-numeric price is refused" do
      assert_raise Error, ~r/price must be numeric/, fn ->
        Lighter.build(order_params(%{"price" => "cheap"}), "createOrder", exchange(), [])
      end
    end

    test "only limit orders are authored" do
      assert_raise Error, ~r/supports limit orders only/, fn ->
        Lighter.build(order_params(%{"type" => "market"}), "createOrder", exchange(), [])
      end
    end

    test "the side must be buy or sell" do
      assert_raise Error, ~r/side must be buy or sell/, fn ->
        Lighter.build(order_params(%{"side" => "long"}), "createOrder", exchange(), [])
      end
    end

    test "an unsupported time in force is refused" do
      assert_raise Error, ~r/unsupported Lighter time in force/, fn ->
        Lighter.build(order_params(%{"timeInForce" => "FOK"}), "createOrder", exchange(), [])
      end
    end

    test "a non-boolean reduceOnly is refused" do
      assert_raise Error, ~r/expected boolean Lighter parameter/, fn ->
        Lighter.build(order_params(%{"reduceOnly" => "yes"}), "createOrder", exchange(), [])
      end
    end

    test "a non-integer nonce is refused" do
      assert_raise Error, ~r/nonce must be an integer/, fn ->
        Lighter.build(order_params(%{"nonce" => 1.5}), "createOrder", exchange(), [])
      end
    end

    test "a numeric string nonce is accepted, a malformed one is not" do
      built = Lighter.build(order_params(%{"nonce" => "42"}), "createOrder", exchange(), [])
      assert transaction(built).nonce == 42

      assert_raise Error, ~r/nonce must be an integer/, fn ->
        Lighter.build(order_params(%{"nonce" => "42x"}), "createOrder", exchange(), [])
      end
    end
  end

  describe "createOrder scales to the market grid" do
    test "amount and price become integer units of their precision" do
      transaction = transaction(Lighter.build(order_params(%{}), "createOrder", exchange(), []))

      assert transaction.market_index == 1
      assert transaction.base_amount == 1_100
      assert transaction.price == 789_014
      assert transaction.is_ask == false
      assert transaction.order_type == 0
      assert transaction.time_in_force == 1
      assert transaction.reduce_only == false
      assert transaction.skip_nonce == false
    end

    test "post-only and sell map to their venue codes" do
      transaction =
        transaction(
          Lighter.build(
            order_params(%{"side" => "sell", "timeInForce" => "PO"}),
            "createOrder",
            exchange(),
            []
          )
        )

      assert transaction.is_ask == true
      assert transaction.time_in_force == 2
    end
  end

  describe "cancelOrder" do
    test "carries the market index and the order it cancels" do
      built =
        Lighter.build(
          %{"symbol" => "BTC/USDC:USDC", "id" => 844_424_928_359_300, "nonce" => 3},
          "cancelOrder",
          exchange(),
          []
        )

      transaction = transaction(built)
      assert transaction.market_index == 1
      assert transaction.order_index == 844_424_928_359_300
      assert transaction.nonce == 3
    end
  end

  defp transaction(built), do: Map.fetch!(built, "__bourse_lighter_transaction_params")
end
