defmodule Bourse.Unified.RequestShape.HyperliquidCoverageTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified.RequestShape.Hyperliquid

  @nonce 1_700_000_000_000

  test "explicit actions retain caller data and receive only a missing nonce" do
    exchange = exchange()

    assert Hyperliquid.build(%{"action" => %{"type" => "cancel"}}, "raw", exchange, timestamp_ms_override: @nonce)[
             "nonce"
           ] == @nonce

    params = %{"action" => %{}, "nonce" => 7}
    assert Hyperliquid.build(params, "raw", exchange) == params
    assert Hyperliquid.build(:invalid, "raw", exchange) == :invalid
  end

  test "cancel methods shape integer ids and vault ownership" do
    exchange = exchange()

    assert %{
             "action" => %{"type" => "cancel", "cancels" => [%{"a" => 0, "o" => 12}]},
             "nonce" => @nonce,
             "vaultAddress" => "abcdef"
           } =
             Hyperliquid.build(
               %{"id" => "12", "symbol" => "BTC", "vaultAddress" => "0xABCDEF"},
               "cancelOrder",
               exchange,
               timestamp_ms_override: @nonce
             )

    assert get_in(
             Hyperliquid.build(%{"ids" => [1, "2"], "symbol" => "BTC"}, "cancelOrders", exchange,
               timestamp_ms_override: @nonce
             ),
             ["action", "cancels"]
           ) == [%{"a" => 0, "o" => 1}, %{"a" => 0, "o" => 2}]

    assert Hyperliquid.build(%{"id" => nil}, "cancelOrder", exchange) == %{"id" => nil}
    assert Hyperliquid.build(%{"ids" => :bad}, "cancelOrders", exchange) == %{"ids" => :bad}
  end

  test "single and batch orders normalize sides, numbers, TIF, client ids, and builder fees" do
    exchange = exchange(%{"approvedBuilderFee" => true, "builder" => "0xABC", "feeInt" => 7})

    orders = [
      %{"symbol" => "BTC", "side" => "buy", "type" => "market", "amount" => "1.00", "price" => nil},
      %{
        "symbol" => "BTC",
        "side" => "S",
        "amount" => Decimal.new("2.50"),
        "price" => 10.25,
        "reduce_only" => "true",
        "time_in_force" => "PO",
        "client_order_id" => "client"
      }
    ]

    shaped = Hyperliquid.build(%{"orders" => orders, "grouping" => "normalTpsl"}, "createOrders", exchange, nonce: @nonce)
    assert get_in(shaped, ["action", "builder"]) == %{"b" => "0xabc", "f" => 7}
    assert [market, limit] = get_in(shaped, ["action", "orders"])
    assert market["b"] and market["p"] == "0" and market["s"] == "1" and get_in(market, ["t", "limit", "tif"]) == "Ioc"
    refute limit["b"]
    assert limit["r"] and limit["c"] == "client" and get_in(limit, ["t", "limit", "tif"]) == "Alo"

    single =
      Hyperliquid.build(hd(orders), "createOrderWithTakeProfitAndStopLoss", exchange, timestamp_ms_override: @nonce)

    assert single |> get_in(["action", "orders"]) |> length() == 1
    refute Map.has_key?(single, "symbol")
    assert Hyperliquid.build(%{"orders" => []}, "createOrders", exchange) == %{"orders" => []}
  end

  test "margin, TWAP, and dead-man actions validate and normalize units" do
    exchange = exchange()

    assert get_in(
             Hyperliquid.build(%{"symbol" => "BTC", "amount" => "1.25"}, "reduceMargin", exchange,
               timestamp_ms_override: @nonce
             ),
             ["action", "ntli"]
           ) == -1_250_000

    assert get_in(
             Hyperliquid.build(
               %{"symbol" => "BTC", "side" => "b", "amount" => 2, "duration" => 120_001.0, "randomize" => 1},
               "createTwapOrder",
               exchange,
               timestamp_ms_override: @nonce
             ),
             ["action", "twap"]
           ) == %{"a" => 0, "b" => true, "m" => 2, "r" => false, "s" => "2", "t" => true}

    assert get_in(
             Hyperliquid.build(%{"timeout" => "500"}, "cancelAllOrdersAfter", exchange, timestamp_ms_override: @nonce),
             ["action", "time"]
           ) == @nonce + 500

    assert_raise Error, fn -> Hyperliquid.build(%{"timeout" => -1}, "cancelAllOrdersAfter", exchange) end

    assert_raise Error, fn ->
      Hyperliquid.build(
        %{"symbol" => "BTC", "side" => "buy", "amount" => 1, "duration" => "bad"},
        "createTwapOrder",
        exchange
      )
    end
  end

  test "withdrawals choose bridge and vault actions" do
    bridge =
      Hyperliquid.build(%{"amount" => "1.20", "address" => "0x1", "code" => "USDC"}, "withdraw", exchange(),
        timestamp_ms_override: @nonce
      )

    assert get_in(bridge, ["action", "type"]) == "withdraw3"
    assert get_in(bridge, ["action", "amount"]) == "1.2"
    assert get_in(bridge, ["action", "hyperliquidChain"]) == "Testnet"

    vault =
      Hyperliquid.build(
        %{"amount" => 1.5, "address" => "ignored", "vault_address" => "0XABC"},
        "withdraw",
        exchange(),
        timestamp_ms_override: @nonce
      )

    assert get_in(vault, ["action"]) ==
             %{"type" => "vaultTransfer", "vaultAddress" => "0xabc", "isDeposit" => false, "usd" => 1_500_000}
  end

  test "transfers choose class, subaccount, and unsupported branches" do
    class = transfer(%{"from_account" => "spot", "to_account" => "perp", "amount" => 1}, exchange())
    assert get_in(class, ["action", "type"]) == "usdClassTransfer"
    assert get_in(class, ["action", "toPerp"])

    deposit = transfer(%{"from_account" => "main", "to_account" => "0xsub", "amount" => "1.25"}, exchange())

    assert get_in(deposit, ["action"]) ==
             %{"type" => "subAccountTransfer", "subAccountUser" => "0xsub", "isDeposit" => true, "usd" => 1_250_000}

    withdrawal = transfer(%{"from_account" => "0xsub", "to_account" => "main", "amount" => 2.0}, exchange())
    refute get_in(withdrawal, ["action", "isDeposit"])

    unsupported = %{"code" => "BTC", "amount" => 1, "from_account" => "main", "to_account" => "0xsub"}
    assert Hyperliquid.build(unsupported, "transfer", exchange()) == unsupported
  end

  test "market lookup and numeric validation distinguish caller and market defects" do
    assert_raise ArgumentError, ~r/markets are not loaded/, fn ->
      Hyperliquid.build(%{"id" => 1, "symbol" => "BTC"}, "cancelOrder", %{exchange() | markets: nil})
    end

    assert_raise Error, fn ->
      Hyperliquid.build(%{"id" => 1, "symbol" => "ETH"}, "cancelOrder", exchange())
    end

    assert_raise ArgumentError, ~r/no asset_index/, fn ->
      Hyperliquid.build(%{"id" => 1, "symbol" => "BTC"}, "cancelOrder", %{exchange() | markets: [%{"symbol" => "BTC"}]})
    end

    assert_raise Error, fn ->
      Hyperliquid.build(%{"symbol" => "BTC", "side" => "hold", "amount" => 1, "price" => 1}, "createOrder", exchange())
    end

    assert_raise Error, fn ->
      Hyperliquid.build(%{"amount" => :many, "address" => "0x1"}, "withdraw", exchange())
    end
  end

  test "optional and rejection branches remain explicit" do
    exchange = exchange()
    assert Hyperliquid.build(%{"amount" => 1}, "transfer", exchange) == %{"amount" => 1}
    assert Hyperliquid.build(%{"address" => "0x1"}, "withdraw", exchange) == %{"address" => "0x1"}
    assert Hyperliquid.build(%{"symbol" => "BTC"}, "addMargin", exchange) == %{"symbol" => "BTC"}
    assert Hyperliquid.build(%{"symbol" => "BTC"}, "createTwapOrder", exchange) == %{"symbol" => "BTC"}

    for duration <- ["120000", :invalid] do
      params = %{"symbol" => "BTC", "side" => "buy", "amount" => 1, "duration" => duration}

      if is_binary(duration) do
        assert get_in(Hyperliquid.build(params, "createTwapOrder", exchange), ["action", "twap", "m"]) == 2
      else
        assert_raise Error, fn -> Hyperliquid.build(params, "createTwapOrder", exchange) end
      end
    end

    for tif <- ["IOC", "ALO", "unknown", 7] do
      params = %{"symbol" => "BTC", "side" => "buy", "amount" => 1, "price" => 1, "timeInForce" => tif}

      assert get_in(Hyperliquid.build(params, "createOrder", exchange), [
               "action",
               "orders",
               Access.at(0),
               "t",
               "limit",
               "tif"
             ])
    end

    no_fee = exchange(%{"approvedBuilderFee" => true, "builderFee" => false})

    assert get_in(Hyperliquid.build(%{"symbol" => "BTC", "side" => "buy", "amount" => 1}, "createOrder", no_fee), [
             "action",
             "builder",
             "f"
           ]) == 0

    assert get_in(
             Hyperliquid.build(%{"symbol" => "BTC", "side" => "buy", "amount" => 1}, "createOrder", %{
               exchange
               | options: nil
             }),
             ["action", "builder"]
           ) == nil

    unrelated = %{"code" => "USDC", "amount" => 1, "from_account" => "alice", "to_account" => "bob"}
    assert Hyperliquid.build(unrelated, "transfer", exchange) == unrelated

    vaulted = transfer(%{"vault_address" => "ABC", "amount" => 1}, exchange)
    assert get_in(vaulted, ["action", "amount"]) == "1 subaccount:abc"

    integer_sub = transfer(%{"code" => nil, "from_account" => "main", "to_account" => "sub", "amount" => 2}, exchange)
    assert get_in(integer_sub, ["action", "usd"]) == 2_000_000

    rejected_code = %{"code" => 7, "amount" => 1, "from_account" => "main", "to_account" => "sub"}
    assert Hyperliquid.build(rejected_code, "transfer", exchange) == rejected_code

    assert get_in(Hyperliquid.build(%{"timeout" => 0, "nonce" => 9}, "cancelAllOrdersAfter", exchange), ["action", "time"]) ==
             9

    bare_vault = Hyperliquid.build(%{"id" => 1, "symbol" => "BTC", "vaultAddress" => "ABC"}, "cancelOrder", exchange)
    assert bare_vault["vaultAddress"] == "abc"
  end

  defp transfer(params, exchange) do
    defaults = %{"code" => "USDC", "amount" => 1, "from_account" => "spot", "to_account" => "perp"}
    Hyperliquid.build(Map.merge(defaults, params), "transfer", exchange, timestamp_ms_override: @nonce)
  end

  defp exchange(options \\ %{}) do
    %Exchange{
      id: "hyperliquid",
      name: "Hyperliquid",
      sandbox: true,
      options: options,
      markets: [%{"id" => "BTC", "symbol" => "BTC/USDC:USDC", "asset_index" => 0}]
    }
  end
end
