defmodule Bourse.HyperliquidAuthoredSpecTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified
  alias Bourse.Unified.RequestShape

  @create_order_fixture "priv/reference_cache/response/hyperliquid.json"
  @external_resource @create_order_fixture

  test "spot balances parse their per-coin totals from balances rows" do
    body = %{
      "balances" => [
        %{"coin" => "USDC", "hold" => "1.5", "total" => "999"},
        %{"coin" => "PURR", "hold" => "0", "total" => "2.25"}
      ]
    }

    {stub, requests} = stub(body)

    assert {:ok, balance} =
             Unified.call(
               Exchange.new!("hyperliquid", api_key: "0xwallet", secret: "private-key"),
               :fetch_balance,
               "fetchBalance",
               %{"type" => "spot"},
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).request_path == "/info"

    assert balance.total == %{"PURR" => 2.25, "USDC" => 999.0}
    assert balance.free == %{"PURR" => 2.25, "USDC" => 997.5}
    assert balance.used == %{"PURR" => 0.0, "USDC" => 1.5}
  end

  test "market size precision is the szDecimals tick size without a snapshot price scalar" do
    body = %{"universe" => [%{"name" => "BTC", "szDecimals" => 5, "maxLeverage" => 40}]}

    {stub, requests} = stub(body)

    # Pass type so bare fetch_markets does not fan out spot+swap against one stub.
    assert {:ok, [%Bourse.Market{} = market]} =
             Unified.call(
               Exchange.new!("hyperliquid"),
               :fetch_markets,
               "fetchMarkets",
               %{"type" => "meta"},
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).request_path == "/info"

    assert market.precision_mode == "tick_size"
    assert market.precision["amount"] == 1.0e-5
    # Task 370: price tick is only filled when mark/mid is on the row (metaAndAssetCtxs).
    refute Map.has_key?(market.precision, "price")
    assert market.type == "swap"
    assert market.quote == "USDC"
  end

  test "funding-rate map authors Hyperliquid's hourly interval" do
    assert {:ok, %Bourse.FundingRate{interval: "1h"}} =
             Bourse.Hyperliquid.parse_funding_rate(%{"funding" => "0.0001"})
  end

  # Fill-parse coverage (task 219 fold-in). This pins the userFills ->
  # [%Bourse.Trade{}] RESPONSE parse against Bourse's static `fetchMyTrades`
  # httpResponse rows (tier-2 / compatibility oracle). Task 225 upgraded this to
  # tier-1 live evidence: `HyperliquidAuthoredIntegrationTest` places a real
  # testnet order that fills and asserts fetch_my_trades reads the resulting
  # non-empty live userFills (the provisioned testnet wallet is now registered).
  test "user fills parse into trades with price, amount, and timestamp populated" do
    body = [
      %{
        "coin" => "SOL",
        "px" => "132.31",
        "sz" => "0.5",
        "side" => "B",
        "time" => "1709643346297",
        "oid" => "6928122855",
        "tid" => "566849930446139",
        "fee" => "0.023154",
        "feeToken" => "USDC"
      },
      %{
        "coin" => "HYPE",
        "px" => "33.209",
        "sz" => "0.73",
        "side" => "B",
        "time" => "1770458548926",
        "oid" => "314848230306",
        "tid" => "882779857052503",
        "fee" => "0.012896",
        "feeToken" => "USDC"
      }
    ]

    {stub, requests} = stub(body)

    assert {:ok, trades} =
             Unified.call(
               Exchange.new!("hyperliquid", api_key: "0xwallet", secret: "private-key"),
               :fetch_my_trades,
               "fetchMyTrades",
               %{},
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).request_path == "/info"

    assert length(trades) == 2
    assert Enum.all?(trades, &match?(%Bourse.Trade{}, &1))

    sol = Enum.find(trades, &(&1.id == "566849930446139"))
    # Numeric, not the raw wire strings: Bourse `parseTrade` reads px/sz through
    # `safeNumber`, and the static golden for this very fill pins price 132.31 /
    # amount 0.5 / cost 66.155 as floats (task 302 authored the trade slice to match).
    assert %Bourse.Trade{price: 132.31, amount: 0.5, timestamp: 1_709_643_346_297, order_id: "6928122855"} = sol
    assert sol.cost == 66.155
    assert sol.symbol == "SOL/USDC:USDC"
    assert sol.side == "buy"
    assert sol.fee == %{"cost" => 0.023154, "currency" => "USDC"}
  end

  test "createOrders parses the CCXT compatibility acknowledgement into an order" do
    fixture =
      @create_order_fixture
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["methods", "createOrder"])
      |> hd()
      |> Map.fetch!("httpResponse")

    {stub, requests} = exchange_stub(fixture)

    assert {:ok, %Bourse.Order{} = order} =
             Unified.call(
               private_exchange(),
               :create_orders,
               "createOrders",
               %{
                 "action" => %{"type" => "order", "orders" => [], "grouping" => "na"},
                 "nonce" => 1_700_000_000_000
               },
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert RequestCollector.one!(requests).request_path == "/exchange"

    assert order.id == "296683658818"
    assert order.average == 25.585
    assert order.amount == 1.0
    assert order.filled == 1.0
    assert order.status == "closed"
  end

  test "createOrders surfaces a venue rejection from statuses" do
    body = %{
      "status" => "ok",
      "response" => %{
        "type" => "order",
        "data" => %{"statuses" => [%{"error" => "Insufficient margin"}]}
      }
    }

    {stub, requests} = exchange_stub(body)

    assert {:error, %Bourse.Error{exchange: "hyperliquid", message: "Insufficient margin", raw: ^body}} =
             Unified.call(
               private_exchange(),
               :create_orders,
               "createOrders",
               %{
                 "action" => %{"type" => "order", "orders" => [], "grouping" => "na"},
                 "nonce" => 1_700_000_000_000
               },
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert RequestCollector.one!(requests).request_path == "/exchange"
  end

  test "cancel acknowledgements parse into canceled orders" do
    body = %{
      "status" => "ok",
      "response" => %{
        "type" => "cancel",
        "data" => %{"statuses" => ["success"]}
      }
    }

    {single_stub, single_requests} = exchange_stub(body)

    assert {:ok, %Bourse.Order{status: "canceled"}} =
             Unified.call(
               private_exchange(),
               :cancel_order,
               "cancelOrder",
               cancel_params(),
               plug: {Req.Test, single_stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert RequestCollector.one!(single_requests).request_path == "/exchange"

    {batch_stub, batch_requests} = exchange_stub(body)

    assert {:ok, [%Bourse.Order{status: "canceled"}]} =
             Unified.call(
               private_exchange(),
               :cancel_orders,
               "cancelOrders",
               Map.put(cancel_params(), "ids", ["1"]),
               plug: {Req.Test, batch_stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert RequestCollector.one!(batch_requests).request_path == "/exchange"
  end

  test "cancelOrders surfaces a venue rejection from statuses" do
    message = "Order was never placed, already canceled, or filled. asset=3"

    body = %{
      "status" => "ok",
      "response" => %{
        "type" => "cancel",
        "data" => %{"statuses" => [%{"error" => message}]}
      }
    }

    {stub, requests} = exchange_stub(body)

    assert {:error, %Bourse.Error{exchange: "hyperliquid", message: ^message, raw: ^body}} =
             Unified.call(
               private_exchange(),
               :cancel_orders,
               "cancelOrders",
               Map.put(cancel_params(), "ids", ["1"]),
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert RequestCollector.one!(requests).request_path == "/exchange"
  end

  # Body recorded live from api.hyperliquid-testnet.xyz on 2026-07-18 for
  # create_twap_order(BTC/USDC:USDC, "buy", 0, 0). Note the venue answers HTTP
  # 200 with a top-level "status" => "ok" and nests the rejection in a SINGULAR
  # `status` map — unlike the `statuses` list the order actions return.
  test "createTwapOrder surfaces a venue rejection from its singular status" do
    message = "Invalid TWAP duration: 0 min(s)"

    body = %{
      "status" => "ok",
      "response" => %{
        "type" => "twapOrder",
        "data" => %{"status" => %{"error" => message}}
      }
    }

    {stub, requests} = exchange_stub(body)

    assert {:error, %Bourse.Error{exchange: "hyperliquid", message: ^message, raw: ^body}} =
             Unified.call(
               market_exchange(),
               :create_twap_order,
               "createTwapOrder",
               %{"symbol" => "BTC/USDC:USDC", "side" => "buy", "amount" => 0, "duration" => 0},
               plug: {Req.Test, stub},
               timestamp_ms_override: 1_700_000_000_000
             )

    assert RequestCollector.one!(requests).request_path == "/exchange"
  end

  test "request shape builds signed isolated-margin and TWAP actions" do
    exchange = market_exchange()

    add_margin =
      RequestShape.apply(
        %{"symbol" => "BTC/USDC:USDC", "amount" => "1.25"},
        exchange,
        "addMargin",
        timestamp_ms_override: 1_700_000_000_000
      )

    assert add_margin["action"] == %{
             "type" => "updateIsolatedMargin",
             "asset" => 7,
             "isBuy" => true,
             "ntli" => 1_250_000
           }

    assert add_margin["nonce"] == 1_700_000_000_000

    reduce_margin =
      RequestShape.apply(
        %{"symbol" => "BTC/USDC:USDC", "amount" => 1.25},
        exchange,
        "reduceMargin",
        timestamp_ms_override: 1_700_000_000_000
      )

    assert reduce_margin["action"]["ntli"] == -1_250_000

    twap =
      RequestShape.apply(
        %{
          "symbol" => "BTC/USDC:USDC",
          "side" => "buy",
          "amount" => "0.01",
          "duration" => 120_000,
          "reduceOnly" => true,
          "randomize" => true
        },
        exchange,
        "createTwapOrder",
        timestamp_ms_override: 1_700_000_000_000
      )

    assert twap["action"] == %{
             "type" => "twapOrder",
             "twap" => %{"a" => 7, "b" => true, "s" => "0.01", "r" => true, "m" => 2, "t" => true}
           }
  end

  test "withdraw request builds its user-signed action without unresolved identifiers" do
    shaped =
      RequestShape.apply(
        %{"code" => "USDC", "amount" => 0, "address" => "0x0000000000000000000000000000000000000001"},
        private_exchange(),
        "withdraw",
        timestamp_ms_override: 1_700_000_000_000
      )

    assert shaped["action"] == %{
             "type" => "withdraw3",
             "hyperliquidChain" => "Testnet",
             "signatureChainId" => "0x66eee",
             "destination" => "0x0000000000000000000000000000000000000001",
             "amount" => "0",
             "time" => 1_700_000_000_000
           }

    refute Map.has_key?(shaped, "code")
    # signature is omit in the authored request defaults — the signer injects it.
    refute Map.has_key?(shaped, "signature")
  end

  test "withdraw with vaultAddress builds L1 vaultTransfer (task 384)" do
    vault = "0xc751489d24a33172541ea451bc253d7a9e98c781"

    shaped =
      RequestShape.apply(
        %{
          "code" => "USDC",
          "amount" => 100,
          "address" => vault,
          "vaultAddress" => vault
        },
        private_exchange(),
        "withdraw",
        timestamp_ms_override: 1_718_449_507_245
      )

    # `usd` is 1e6 micro-USD (official Python SDK `vault_usd_transfer`) — a
    # deliberate DIVERGE from Bourse, which sends the bare amount. Carve C-T384.
    assert shaped["action"] == %{
             "type" => "vaultTransfer",
             "vaultAddress" => vault,
             "isDeposit" => false,
             "usd" => 100_000_000
           }

    assert shaped["nonce"] == 1_718_449_507_245
    refute Map.has_key?(shaped, "vaultAddress")
    refute Map.has_key?(shaped, "destination")
    refute Map.has_key?(shaped, "signatureChainId")
  end

  test "historical-order wrappers delegate through the emulation filter" do
    exchange = private_exchange()
    Bourse.Emulation.reload!()

    assert Bourse.Emulation.emulated?(exchange, :fetch_closed_orders, :rest)
    assert Bourse.Emulation.emulated?(exchange, :fetch_canceled_orders, :rest)
    assert Bourse.Emulation.emulated?(exchange, :fetch_canceled_and_closed_orders, :rest)
    assert exchange.request_param_shape["fetchClosedOrders"]["_delegate"] == "fetchOrders"
    assert exchange.request_param_shape["fetchCanceledOrders"]["_delegate"] == "fetchOrders"
    assert exchange.request_param_shape["fetchCanceledAndClosedOrders"]["_delegate"] == "fetchOrders"
  end

  # Task 538 — provider orderStatus table + live historicalOrders minTradeNtlRejected.
  # Source: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#query-order-status-by-oid-or-cloid
  @hyperliquid_documented_order_statuses %{
    "open" => "open",
    "triggered" => "open",
    "filled" => "closed",
    "canceled" => "canceled",
    "marginCanceled" => "canceled",
    "vaultWithdrawalCanceled" => "canceled",
    "openInterestCapCanceled" => "canceled",
    "selfTradeCanceled" => "canceled",
    "reduceOnlyCanceled" => "canceled",
    "siblingFilledCanceled" => "canceled",
    "delistedCanceled" => "canceled",
    "liquidatedCanceled" => "canceled",
    "scheduledCancel" => "canceled",
    "rejected" => "rejected",
    "tickRejected" => "rejected",
    "minTradeNtlRejected" => "rejected",
    "perpMarginRejected" => "rejected",
    "reduceOnlyRejected" => "rejected",
    "badAloPxRejected" => "rejected",
    "iocCancelRejected" => "rejected",
    "badTriggerPxRejected" => "rejected",
    "marketOrderNoLiquidityRejected" => "rejected",
    "positionIncreaseAtOpenInterestCapRejected" => "rejected",
    "positionFlipAtOpenInterestCapRejected" => "rejected",
    "tooAggressiveAtOpenInterestCapRejected" => "rejected",
    "openInterestIncreaseRejected" => "rejected",
    "insufficientSpotBalanceRejected" => "rejected",
    "oracleRejected" => "rejected",
    "perpMaxPositionRejected" => "rejected"
  }

  test "order status covers every provider-documented state with deliberate terminal semantics" do
    rule =
      "hyperliquid"
      |> Bourse.Spec.load!()
      |> get_in(["normalization", "field_maps", "order", "field_map", "status"])

    for {provider_state, unified_state} <- @hyperliquid_documented_order_statuses do
      assert rule["enum_map"][provider_state] == unified_state,
             "expected #{provider_state} → #{unified_state}, got #{inspect(rule["enum_map"][provider_state])}"

      assert {:ok, %Bourse.Order{status: ^unified_state}} =
               Bourse.Hyperliquid.parse_order(hyperliquid_history_row(provider_state))
    end

    # Defensive British spelling alias — not on the provider table, still mapped.
    assert rule["enum_map"]["cancelled"] == "canceled"
  end

  test "min-notional-rejected history succeeds on all four order-read methods" do
    # Live evidence 2026-08-04 testnet oid 56637337026 (status minTradeNtlRejected).
    body = [
      hyperliquid_history_row("minTradeNtlRejected", oid: 56_637_337_026, price: "32012.0"),
      hyperliquid_history_row("filled", oid: 57_397_439_760, price: "62995.0", remaining: "0.0"),
      hyperliquid_history_row("canceled", oid: 57_397_440_943, price: "31816.0")
    ]

    methods = [
      {:fetch_orders, "fetchOrders"},
      {:fetch_closed_orders, "fetchClosedOrders"},
      {:fetch_canceled_orders, "fetchCanceledOrders"},
      {:fetch_canceled_and_closed_orders, "fetchCanceledAndClosedOrders"}
    ]

    for {method, js_name} <- methods do
      {stub, _requests} = stub(body)

      assert {:ok, orders} =
               Unified.call(private_exchange(), method, js_name, %{}, plug: {Req.Test, stub})

      assert is_list(orders)
      assert Enum.all?(orders, &match?(%Bourse.Order{}, &1))
    end

    # Unified path annotates nested historical wrappers before field mapping.
    {stub, _requests} = stub(body)

    assert {:ok, orders} =
             Unified.call(private_exchange(), :fetch_orders, "fetchOrders", %{}, plug: {Req.Test, stub})

    rejected = Enum.find(orders, &(&1.id == "56637337026"))
    assert %Bourse.Order{status: "rejected"} = rejected
    assert rejected.info["status"] == "minTradeNtlRejected"
  end

  test "genuinely unknown order status still fails loud" do
    assert {:error, {:unmapped_order_status, %{venue: "hyperliquid", raw_value: "providerAdded"}}} =
             Bourse.Hyperliquid.parse_order(hyperliquid_history_row("providerAdded"))
  end

  defp stub(body) do
    name = {__MODULE__, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(name, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, body)
    end)

    {name, requests}
  end

  defp hyperliquid_history_row(status, opts \\ []) do
    oid = Keyword.get(opts, :oid, 1)
    price = Keyword.get(opts, :price, "32012.0")
    remaining = Keyword.get(opts, :remaining, "0.0003")
    ts = Keyword.get(opts, :timestamp, 1_784_339_687_183)

    %{
      "order" => %{
        "children" => [],
        "cloid" => nil,
        "coin" => "BTC",
        "isPositionTpsl" => false,
        "isTrigger" => false,
        "limitPx" => price,
        "oid" => oid,
        "orderType" => "Limit",
        "origSz" => "0.0003",
        "reduceOnly" => false,
        "side" => "B",
        "sz" => remaining,
        "tif" => "Gtc",
        "timestamp" => ts,
        "triggerCondition" => "N/A",
        "triggerPx" => "0.0"
      },
      "status" => status,
      "statusTimestamp" => ts
    }
  end

  defp private_exchange do
    Exchange.new!("hyperliquid",
      api_key: "0xwallet",
      secret: "0x0123456789012345678901234567890123456789012345678901234567890123",
      sandbox: true
    )
  end

  defp market_exchange do
    Exchange.put_markets(private_exchange(), [
      %Bourse.Market{
        id: "BTCUSDC",
        symbol: "BTC/USDC:USDC",
        asset_index: 7,
        precision: %{"amount" => 0.001}
      }
    ])
  end

  defp cancel_params do
    %{
      "id" => "1",
      "symbol" => "BTC/USDC:USDC",
      "action" => %{"type" => "cancel", "cancels" => []},
      "nonce" => 1_700_000_000_000
    }
  end

  defp exchange_stub(body) do
    name = {__MODULE__, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(name, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, body)
    end)

    {name, requests}
  end
end
