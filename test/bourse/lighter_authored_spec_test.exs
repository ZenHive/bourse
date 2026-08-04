defmodule Bourse.LighterAuthoredSpecTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Signing.Lighter, as: LighterSigning
  alias Bourse.Spec
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified.ReadParse
  alias Bourse.Unified.RequestShape.Lighter, as: LighterRequestShape

  @owned_path "priv/specs/json/output/authored/lighter.json"
  @mainnet_url "https://mainnet.zklighter.elliot.ai"
  @private_key "07000000000000000300000000000000000000000000000000000000000000000000000000000000"

  defmodule NoopParser do
    @moduledoc false
    def __response_envelopes__, do: %{}
  end

  test "owned spec exposes only the live-adjudicated REST contract" do
    spec = Spec.decode_file!(@owned_path)

    assert spec["authored"] == true
    assert spec["hand_owned"] == true
    assert spec["frozen"] == true
    assert String.ends_with?(Spec.authored_spec_path("lighter"), @owned_path)

    assert supported_methods(spec) ==
             ~w(cancelOrder createOrder fetchClosedOrders fetchMarkets fetchOHLCV fetchOpenOrders fetchOrderBook fetchTicker)

    Enum.each(spec["capabilities"]["has"], fn {method, declaration} ->
      endpoints = spec["endpoints"]["unified"][method]

      if declaration == false do
        assert endpoints == [], "unsupported #{method} retained a runtime route"
      else
        assert declaration == true
        assert is_list(endpoints) and endpoints != [], "supported #{method} has no runtime route"
      end
    end)

    assert Enum.all?(Map.values(spec["websocket"]), fn
             %{"supported" => false} -> true
             %{"public" => nil, "private" => nil, "sandbox_public" => nil, "sandbox_private" => nil} -> true
             _ -> false
           end)
  end

  test "create and cancel builders scale typed params and overwrite injected transaction internals" do
    exchange = exchange_with_market()

    create =
      LighterRequestShape.build(
        %{
          "symbol" => market().symbol,
          "type" => "limit",
          "side" => "buy",
          "amount" => "0.0100",
          "price" => "100.25",
          "client_order_index" => "42",
          "nonce" => "7",
          "timeInForce" => "PO",
          "__bourse_lighter_transaction_operation" => "withdraw",
          "__bourse_lighter_transaction_params" => %{signature: "caller"}
        },
        "createOrder",
        exchange,
        []
      )

    assert create["__bourse_lighter_transaction_operation"] == "create_order"

    assert create["__bourse_lighter_transaction_params"] == %{
             market_index: 1,
             client_order_index: 42,
             base_amount: 100,
             price: 10_025,
             is_ask: false,
             order_type: 0,
             time_in_force: 2,
             reduce_only: false,
             trigger_price: 0,
             order_expiry: -1,
             integrator_account_index: 0,
             integrator_taker_fee: 0,
             integrator_maker_fee: 0,
             self_trade_behavior: 0,
             self_trade_equality: 0,
             skip_nonce: false,
             nonce: 7
           }

    cancel =
      LighterRequestShape.build(
        %{"symbol" => market().symbol, "id" => "99", "nonce" => 8},
        "cancelOrder",
        exchange,
        []
      )

    assert cancel["__bourse_lighter_transaction_operation"] == "cancel_order"

    assert cancel["__bourse_lighter_transaction_params"] == %{
             market_index: 1,
             order_index: 99,
             skip_nonce: false,
             nonce: 8
           }
  end

  test "create builder rejects unsupported order types and precision loss" do
    exchange = exchange_with_market()

    base = %{
      "symbol" => market().symbol,
      "side" => "buy",
      "amount" => "0.0100",
      "price" => "100.25",
      "client_order_index" => 42,
      "nonce" => 7
    }

    assert_raise ArgumentError, "Lighter authored trading supports limit orders only", fn ->
      LighterRequestShape.build(Map.put(base, "type", "market"), "createOrder", exchange, [])
    end

    assert_raise ArgumentError, "Lighter amount does not align with market precision", fn ->
      base
      |> Map.merge(%{"type" => "limit", "amount" => "0.01001"})
      |> LighterRequestShape.build("createOrder", exchange, [])
    end
  end

  test "provider-shaped markets and object order-book levels parse completely" do
    stub = unique_stub(:public_reads)

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/api/v1/orderBookDetails" ->
          Req.Test.json(conn, %{"code" => 200, "order_book_details" => [market_body()]})

        "/api/v1/orderBookOrders" ->
          Req.Test.json(conn, %{
            "code" => 200,
            "bids" => [%{"price" => "100.25", "remaining_base_amount" => "0.4"}],
            "asks" => [%{"price" => "100.50", "remaining_base_amount" => "0.3"}]
          })
      end
    end)

    assert {:ok, [%Market{} = market]} = Bourse.fetch_markets(Exchange.new!("lighter"), plug: {Req.Test, stub})
    assert market.symbol == "BTC/USDC:USDC"
    assert market.type == "swap"
    assert market.swap == true
    assert market.contract == true
    assert market.linear == true
    assert market.active == true
    assert market.quote == "USDC"
    assert market.settle == "USDC"

    exchange = "lighter" |> Exchange.new!() |> Exchange.put_markets([market])

    assert {:ok, %Bourse.Ticker{last: 100.25, mark_price: 100.3, base_volume: 12.5}} =
             Bourse.fetch_ticker(exchange, market.symbol, plug: {Req.Test, stub})

    assert {:ok, %Bourse.OrderBook{} = book} =
             Bourse.fetch_order_book(exchange, market.symbol, plug: {Req.Test, stub})

    assert book.bids == [[100.25, 0.4]]
    assert book.asks == [[100.5, 0.3]]
  end

  test "private order reads use the helper token and retain provider order semantics" do
    stub = unique_stub(:private_read)
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      Req.Test.json(conn, %{
        "code" => 200,
        "orders" => [
          %{
            "order_id" => "99",
            "client_order_id" => "42",
            "initial_base_amount" => "0.0100",
            "filled_base_amount" => "0.0000",
            "filled_quote_amount" => "0.000000",
            "remaining_base_amount" => "0.0100",
            "is_ask" => false,
            "price" => "100.25",
            "reduce_only" => false,
            "status" => "open",
            "time_in_force" => "good-till-time",
            "timestamp" => 1_800_000_000,
            "type" => "limit"
          }
        ]
      })
    end)

    exchange = signed_exchange()

    assert {:ok, [%Bourse.Order{} = order]} =
             Bourse.fetch_open_orders(exchange,
               symbol: market().symbol,
               account_index: 1,
               auth_deadline: 1_800_000_000,
               plug: {Req.Test, stub}
             )

    assert order.id == "99"
    assert order.client_order_id == "42"
    assert order.side == "buy"
    assert order.status == "open"
    assert order.type == "limit"
    assert order.price == 100.25
    assert order.amount == 0.01
    assert order.filled == 0.0
    assert order.remaining == 0.01
    assert order.time_in_force == "good-till-time"

    conn = RequestCollector.one!(requests)
    assert Plug.Conn.get_req_header(conn, "authorization") == ["1800000000:1:0:fake-signature"]
    assert RequestCollector.query(conn) == %{"account_index" => "1", "market_id" => "1"}
  end

  test "unified create dispatch transports only first-party signer output" do
    stub = unique_stub(:create_order)
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      {conn, _body} = RequestCollector.capture_with_body(requests, conn)

      Req.Test.json(conn, %{
        "code" => 200,
        "predicted_execution_time_ms" => 1,
        "tx_hash" => "fixture-hash",
        "volume_quota_remaining" => 1
      })
    end)

    exchange = signed_exchange()

    assert {:ok, %{"code" => 200, "tx_hash" => "fixture-hash"}} =
             Bourse.create_order(exchange, market().symbol, "limit", "buy", "0.0100",
               price: "100.25",
               client_order_index: 42,
               nonce: 7,
               tx_type: 255,
               tx_info: ~s({"signature":"caller"}),
               signature: "caller",
               plug: {Req.Test, stub}
             )

    %{conn: conn, body: body} = RequestCollector.one_request!(requests)
    assert conn.request_path == "/api/v1/sendTx"
    assert Plug.Conn.get_req_header(conn, "authorization") == []
    assert Plug.Conn.get_req_header(conn, "content-type") == ["application/x-www-form-urlencoded"]
    assert URI.decode_query(body) == %{"tx_info" => ~s({"signature":"fake-signature"}), "tx_type" => "14"}
    refute body =~ "caller"
  end

  test "Lighter order-book parser rejects no provider fields while preserving sort order" do
    body = %{
      "bids" => [
        %{"price" => "100.00", "remaining_base_amount" => "1.0"},
        %{"price" => "101.00", "remaining_base_amount" => "2.0"}
      ],
      "asks" => [
        %{"price" => "103.00", "remaining_base_amount" => "4.0"},
        %{"price" => "102.00", "remaining_base_amount" => "3.0"}
      ]
    }

    assert {:ok, %Bourse.OrderBook{bids: bids, asks: asks}} =
             ReadParse.parse(
               Exchange.new!("lighter"),
               NoopParser,
               :fetch_order_book,
               "fetchOrderBook",
               body,
               %{"symbol" => market().symbol},
               :parse_order_book,
               false
             )

    assert bids == [[101.0, 2.0], [100.0, 1.0]]
    assert asks == [[102.0, 3.0], [103.0, 4.0]]
  end

  defp supported_methods(spec) do
    spec["capabilities"]["has"]
    |> Enum.flat_map(fn
      {method, true} -> [method]
      {_method, false} -> []
    end)
    |> Enum.sort()
  end

  defp exchange_with_market do
    "lighter" |> Exchange.new!() |> Exchange.put_markets([market()])
  end

  defp signed_exchange do
    credentials = Credentials.new!(api_key: "0", secret: @private_key, uid: "1")
    exchange = "lighter" |> Exchange.new!(credentials: credentials) |> Exchange.put_markets([market()])
    config = helper_config()
    exchange = %{exchange | signing_config: Map.merge(exchange.signing_config, config)}

    on_exit(fn -> LighterSigning.terminate_helper(credentials, Map.put(config, :base_url, @mainnet_url)) end)
    exchange
  end

  defp helper_config do
    %{
      helper_path: System.find_executable("elixir"),
      helper_args: [Path.expand("../support/fixtures/lighter_helper.exs", __DIR__), "normal"]
    }
  end

  defp market do
    %Market{
      id: "1",
      symbol: "BTC/USDC:USDC",
      base: "BTC",
      quote: "USDC",
      settle: "USDC",
      type: "swap",
      swap: true,
      contract: true,
      linear: true,
      precision: %{amount: 0.0001, price: 0.01}
    }
  end

  defp market_body do
    %{
      "symbol" => "BTC",
      "market_id" => 1,
      "market_type" => "perp",
      "status" => "active",
      "taker_fee" => "0.0001",
      "maker_fee" => "0.0000",
      "min_base_amount" => "0.0001",
      "min_quote_amount" => "10.000000",
      "size_decimals" => "4",
      "price_decimals" => "2",
      "quote_multiplier" => 1,
      "last_trade_price" => "100.25",
      "mark_price" => "100.30",
      "daily_base_token_volume" => "12.5"
    }
  end

  defp unique_stub(name), do: {__MODULE__, name, System.unique_integer([:positive])}
end
