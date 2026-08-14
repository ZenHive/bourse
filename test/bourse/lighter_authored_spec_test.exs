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
  @balance_fixture "test/fixtures/responses/lighter/fetch_balance.json"
  @deposit_fixture "test/fixtures/responses/lighter/fetch_deposits.json"
  @positions_fixture "test/fixtures/responses/lighter/fetch_positions.json"
  @external_resource @balance_fixture
  @external_resource @deposit_fixture
  @external_resource @positions_fixture
  @mainnet_url "https://mainnet.zklighter.elliot.ai"
  @public_account_index 0
  @private_key "07000000000000000300000000000000000000000000000000000000000000000000000000000000"
  @provider_required_fields %{
    "AccountPosition" =>
      ~w(market_id symbol initial_margin_fraction open_order_count pending_order_count position_tied_order_count sign position avg_entry_price position_value unrealized_pnl realized_pnl liquidation_price margin_mode allocated_margin total_discount),
    "DepositHistoryItem" => ~w(id amount timestamp status l1_tx_hash asset_id),
    "LiqTrade" => ~w(price size taker_fee maker_fee transaction_time),
    "Liquidation" => ~w(id market_id type trade info executed_at),
    "LiquidationInfo" => ~w(positions risk_info_before risk_info_after mark_prices assets asset_index_prices),
    "Trade" =>
      ~w(trade_id trade_id_str tx_hash type market_id size price usd_amount ask_id bid_id ask_client_id ask_client_id_str bid_client_id bid_client_id_str ask_account_id bid_account_id is_maker_ask block_height timestamp taker_position_size_before taker_entry_quote_before taker_initial_margin_fraction_before taker_position_sign_changed maker_position_size_before maker_entry_quote_before maker_initial_margin_fraction_before maker_position_sign_changed transaction_time ask_account_pnl bid_account_pnl integrator_taker_fee integrator_taker_fee_collector_index integrator_maker_fee integrator_maker_fee_collector_index taker_allocated_margin_usdc_before taker_allocated_margin_usdc_after maker_allocated_margin_usdc_before maker_allocated_margin_usdc_after),
    "TransferHistoryItem" =>
      ~w(id amount timestamp type from_l1_address to_l1_address from_account_index to_account_index tx_hash asset_id fee from_route to_route),
    "WithdrawHistoryItem" => ~w(id amount timestamp status type l1_tx_hash asset_id)
  }

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
             ~w(cancelOrder createOrder fetchBalance fetchClosedOrders fetchDeposits fetchFundingRateHistory fetchMarkets fetchMyLiquidations fetchMyTrades fetchOHLCV fetchOpenOrders fetchOrderBook fetchPositions fetchTicker fetchTransfers fetchWithdrawals)

    assert get_in(spec, ["endpoints", "unified", "fetchFundingRateHistory"]) == ["publicGetFundings"]

    assert get_in(spec, ["endpoints", "descriptors", "fetchFundingRateHistory", "description"]) =~
             "/api/v1/funding-rates is the separate cross-exchange reference feed"

    for method <- ~w(fetchClosedOrders fetchOpenOrders) do
      assert get_in(spec, ["endpoints", "request", "defaults", method, "market_id", "optional"]) == true
    end

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

  test "account read builders source account identity and private auth defaults" do
    exchange = signed_exchange()

    assert LighterRequestShape.build(%{}, "fetchBalance", exchange, []) == %{
             "by" => "index",
             "value" => 1
           }

    before_deadline = System.system_time(:second)
    private = LighterRequestShape.build(%{}, "fetchMyTrades", exchange, [])

    assert private["account_index"] == 1
    assert private["auth_deadline"] >= before_deadline
    assert private["auth_deadline"] <= before_deadline + 300

    assert LighterRequestShape.build(
             %{"account_index" => 2, "auth_deadline" => 1_800_000_000},
             "fetchTransfers",
             exchange,
             []
           ) == %{"account_index" => 2, "auth_deadline" => 1_800_000_000}

    assert LighterRequestShape.build(
             %{"by" => "index", "value" => @public_account_index},
             "fetchPositions",
             exchange_with_market(),
             []
           ) == %{"by" => "index", "value" => @public_account_index}

    # deposit/history additionally REQUIRES l1_address per the provider contract;
    # without it the venue answers an unspecific 20001, so the builder fails loud.
    deposits = LighterRequestShape.build(%{"l1_address" => "0xabc"}, "fetchDeposits", exchange, [])
    assert deposits["l1_address"] == "0xabc"
    assert deposits["account_index"] == 1

    assert_raise ArgumentError, ~r/l1_address/, fn ->
      LighterRequestShape.build(%{}, "fetchDeposits", exchange, [])
    end
  end

  test "new account and history routes parse provider response slices" do
    stub = unique_stub(:account_and_history_reads)
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      body =
        case conn.request_path do
          "/api/v1/account" -> account_body()
          "/api/v1/trades" -> %{"code" => 200, "trades" => [trade_body()]}
          "/api/v1/deposit/history" -> %{"code" => 200, "deposits" => [deposit_body()]}
          "/api/v1/withdraw/history" -> %{"code" => 200, "withdraws" => [withdrawal_body()]}
          "/api/v1/transfer/history" -> %{"code" => 200, "transfers" => [transfer_body()]}
          "/api/v1/liquidations" -> %{"code" => 200, "liquidations" => [liquidation_body()]}
          "/api/v1/fundings" -> %{"code" => 200, "fundings" => [funding_body()], "resolution" => "1h"}
        end

      Req.Test.json(conn, body)
    end)

    exchange = signed_exchange()
    call_opts = [plug: {Req.Test, stub}]

    assert {:ok, %Bourse.Balance{} = balance} = Bourse.fetch_balance(exchange, call_opts)
    assert Bourse.Balance.get(balance, "ETH") == %{free: 3.0, used: 0.0, total: 3.0}
    assert Bourse.Balance.get(balance, "USDC") == %{free: 9964.5, used: 0.0, total: 10_000.0}

    assert {:ok, [%Bourse.Position{} = position]} = Bourse.fetch_positions(exchange, call_opts)
    assert position.symbol == market().symbol
    assert position.side == "long"
    assert position.contracts == 0.25
    assert position.initial_margin_percentage == 0.2
    assert position.liquidation_price == 75.0

    assert {:ok, [%Bourse.Trade{} = trade]} = Bourse.fetch_my_trades(exchange, call_opts)

    assert %{
             id: "145",
             symbol: "BTC/USDC:USDC",
             amount: 0.1,
             price: 100.0,
             cost: 10.0,
             timestamp: 1_800_000_000_000,
             side: "buy",
             taker_or_maker: "taker",
             order_id: "245",
             # Plumbing pin only: the provider OpenAPI types taker_fee/maker_fee as
             # int32 and no live row has ever carried the field, so the VALUE scale
             # is unverified (carve C-T546 amendment + prod-verification-ledger).
             # This asserts the raw pass-through, not USDC semantics.
             fee: %{"cost" => 3, "currency" => "USDC"},
             type: nil
           } = trade

    assert {:ok,
            [
              %Bourse.Transaction{
                id: "deposit-1",
                type: "deposit",
                currency: "USDC",
                status: "ok",
                amount: 5.0,
                timestamp: 1_800_000_000_000
              }
            ]} =
             Bourse.fetch_deposits(exchange, [{:l1_address, "0xabc"} | call_opts])

    assert {:ok,
            [
              %Bourse.Transaction{
                id: "withdrawal-1",
                type: "withdrawal",
                currency: "ETH",
                status: "pending",
                amount: 1.0,
                timestamp: 1_800_000_000_000
              }
            ]} =
             Bourse.fetch_withdrawals(exchange, call_opts)

    assert {:ok,
            [
              %Bourse.TransferEntry{
                id: "transfer-1",
                currency: "LIT",
                # The signed transfer payload names the fee field `usdc_fee`
                # (Signing.Lighter.Protocol / lighter_signer helper.c), so the fee
                # is USDC-denominated regardless of the asset moved.
                fee: %{"cost" => 0.01, "currency" => "USDC"},
                from_account: "1",
                to_account: "2",
                info: %{"from_route" => "perps", "to_route" => "spot"}
              }
            ]} =
             Bourse.fetch_transfers(exchange, call_opts)

    assert {:ok, [%Bourse.Liquidation{symbol: "BTC/USDC:USDC", price: 80.0, contracts: 0.25}]} =
             Bourse.fetch_my_liquidations(exchange, call_opts)

    assert {:ok, [%Bourse.FundingRateHistory{} = funding]} =
             Bourse.fetch_funding_rate_history(exchange, market().symbol,
               since: 1_800_000_000_000,
               limit: 1,
               plug: {Req.Test, stub}
             )

    assert funding.symbol == market().symbol
    # The venue publishes `rate` in percent: for every live market
    # `value == mark_price * rate / 100` (funding value per 1 base unit), so the
    # unified fraction is rate / 100 — a raw "0.0012" row means 0.0012%/h.
    assert funding.funding_rate == 1.2e-5
    assert funding.timestamp == 1_800_000_000_000

    assert Enum.map(RequestCollector.requests(requests), & &1.conn.request_path) == [
             "/api/v1/account",
             "/api/v1/account",
             "/api/v1/trades",
             "/api/v1/deposit/history",
             "/api/v1/withdraw/history",
             "/api/v1/transfer/history",
             "/api/v1/liquidations",
             "/api/v1/fundings"
           ]
  end

  test "provider-shaped history stubs carry every required provider field" do
    account_position = get_in(account_body(), ["accounts", Access.at(0), "positions", Access.at(0)])
    liquidation = liquidation_body()

    assert_provider_stub!("AccountPosition", account_position)
    assert_provider_stub!("Trade", trade_body())
    assert_provider_stub!("DepositHistoryItem", deposit_body())
    assert_provider_stub!("WithdrawHistoryItem", withdrawal_body())
    assert_provider_stub!("TransferHistoryItem", transfer_body())
    assert_provider_stub!("Liquidation", liquidation)
    assert_provider_stub!("LiqTrade", liquidation["trade"])
    assert_provider_stub!("LiquidationInfo", liquidation["info"])
  end

  test "a required provider symbol cannot suppress market-id resolution or make a flat row long" do
    body = put_in(account_body(), ["accounts", Access.at(0), "positions", Access.at(0), "position"], "0.00000")

    assert {:ok, [%Bourse.Position{symbol: "BTC/USDC:USDC", side: nil} = position]} =
             ReadParse.parse(
               exchange_with_market(),
               Bourse.Lighter,
               :fetch_positions,
               "fetchPositions",
               body,
               %{},
               :parse_position,
               true
             )

    assert position.contracts == 0.0
  end

  test "the recorded populated deposit resolves its required asset id and endpoint type" do
    fixture = Bourse.JsonDocument.decode_file!(@deposit_fixture)

    assert {:ok, [%Bourse.Transaction{} = deposit | _]} =
             ReadParse.parse(
               Exchange.new!("lighter"),
               Bourse.Lighter,
               :fetch_deposits,
               "fetchDeposits",
               fixture["body"],
               %{},
               :parse_transaction,
               true
             )

    assert %{amount: 10_000.0, currency: "USDC", type: "deposit"} = deposit
  end

  test "the recorded open account uses provider available balance as free collateral" do
    fixture = Bourse.JsonDocument.decode_file!(@balance_fixture)

    assert {:ok, %Bourse.Balance{} = balance} =
             ReadParse.parse(
               Exchange.new!("lighter"),
               Bourse.Lighter,
               :fetch_balance,
               "fetchBalance",
               fixture["body"],
               %{},
               :parse_balance,
               true
             )

    assert %{free: free, used: used, total: 10_000.0} = Bourse.Balance.get(balance, "USDC")
    assert used == 0.0
    assert_in_delta free, 9_964.54469, 1.0e-8
    assert free < balance.total["USDC"]
  end

  test "the recorded position margin fraction is normalized from percent points" do
    fixture = Bourse.JsonDocument.decode_file!(@positions_fixture)

    exchange = "lighter" |> Exchange.new!() |> Exchange.put_markets([market()])

    assert {:ok,
            [
              %Bourse.Position{
                initial_margin_percentage: 0.05,
                side: "long",
                symbol: "BTC/USDC:USDC"
              }
            ]} =
             ReadParse.parse(
               exchange,
               Bourse.Lighter,
               :fetch_positions,
               "fetchPositions",
               fixture["body"],
               %{},
               :parse_position,
               true
             )
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

    assert {:ok, %Bourse.Ticker{last: 100.25, mark_price: 100.3, base_volume: 12.5, percentage: 1.3548}} =
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
        "orders" => [private_order_body()]
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

  test "private order reads omit optional market scope and retain symbol scoping" do
    stub = unique_stub(:optional_private_read_scope)
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      orders =
        if Map.has_key?(RequestCollector.query(conn), "market_id") do
          [private_order_body()]
        else
          [private_order_body(), Map.put(private_order_body(), "order_id", "100")]
        end

      Req.Test.json(conn, %{"code" => 200, "orders" => orders})
    end)

    exchange = signed_exchange()
    common_opts = [account_index: 1, auth_deadline: 1_800_000_000, plug: {Req.Test, stub}]

    assert {:ok, [_, _]} = Bourse.fetch_open_orders(exchange, common_opts)
    assert {:ok, [_, _]} = Bourse.fetch_closed_orders(exchange, common_opts)
    assert {:ok, [_]} = Bourse.fetch_open_orders(exchange, [{:symbol, market().symbol} | common_opts])
    assert {:ok, [_]} = Bourse.fetch_closed_orders(exchange, [{:symbol, market().symbol} | common_opts])

    assert [open_all, closed_all, open_market, closed_market] = RequestCollector.requests(requests)

    assert {open_all.conn.request_path, RequestCollector.query(open_all.conn)} ==
             {"/api/v1/accountActiveOrders", %{"account_index" => "1"}}

    assert {closed_all.conn.request_path, RequestCollector.query(closed_all.conn)} ==
             {"/api/v1/accountInactiveOrders", %{"account_index" => "1", "limit" => "100"}}

    assert {open_market.conn.request_path, RequestCollector.query(open_market.conn)} ==
             {"/api/v1/accountActiveOrders", %{"account_index" => "1", "market_id" => "1"}}

    assert {closed_market.conn.request_path, RequestCollector.query(closed_market.conn)} ==
             {"/api/v1/accountInactiveOrders", %{"account_index" => "1", "limit" => "100", "market_id" => "1"}}
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
      "daily_price_change" => 1.3548,
      "daily_base_token_volume" => "12.5"
    }
  end

  defp private_order_body do
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
  end

  defp account_body do
    %{
      "code" => 200,
      "accounts" => [
        %{
          "available_balance" => "9964.500000",
          "assets" => [
            %{"symbol" => "ETH", "balance" => "3.0", "locked_balance" => "0", "margin_balance" => "0"},
            %{"symbol" => "USDC", "balance" => "0", "locked_balance" => "0", "margin_balance" => "10000"}
          ],
          "positions" => [
            %{
              "allocated_margin" => "20",
              "avg_entry_price" => "90",
              "initial_margin_fraction" => "20",
              "liquidation_price" => "75",
              "margin_mode" => 0,
              "market_id" => 1,
              "open_order_count" => 0,
              "pending_order_count" => 0,
              "position" => "0.25",
              "position_tied_order_count" => 0,
              "position_value" => "25",
              "realized_pnl" => "1",
              "sign" => 1,
              "symbol" => "BTC",
              "total_discount" => "0",
              "unrealized_pnl" => "2"
            }
          ]
        }
      ]
    }
  end

  defp trade_body do
    %{
      "ask_account_id" => 2,
      "ask_account_pnl" => "0",
      "ask_client_id" => 12,
      "ask_client_id_str" => "12",
      "ask_id" => 244,
      "bid_account_id" => 1,
      "bid_account_pnl" => "0",
      "bid_client_id" => 13,
      "bid_client_id_str" => "13",
      "bid_id" => 245,
      "block_height" => 10,
      "integrator_maker_fee" => "0",
      "integrator_maker_fee_collector_index" => 0,
      "integrator_taker_fee" => "0",
      "integrator_taker_fee_collector_index" => 0,
      "is_maker_ask" => true,
      "maker_allocated_margin_usdc_after" => "0",
      "maker_allocated_margin_usdc_before" => "0",
      "maker_entry_quote_before" => "0",
      # Provider-typed: the pinned OpenAPI declares maker_fee/taker_fee int32
      # (every other Trade money field is string) — a scaled unit of unknown scale.
      "maker_fee" => 2,
      "maker_initial_margin_fraction_before" => 0,
      "maker_position_sign_changed" => false,
      "maker_position_size_before" => "0",
      "market_id" => 1,
      "price" => "100",
      "size" => "0.1",
      "taker_allocated_margin_usdc_after" => "0",
      "taker_allocated_margin_usdc_before" => "0",
      "taker_entry_quote_before" => "0",
      "taker_fee" => 3,
      "taker_initial_margin_fraction_before" => 0,
      "taker_position_sign_changed" => false,
      "taker_position_size_before" => "0",
      "timestamp" => 1_800_000_000_000,
      "trade_id" => 145,
      "trade_id_str" => "145",
      "transaction_time" => 1_800_000_000_000,
      "tx_hash" => "0xtrade",
      "type" => "trade",
      "usd_amount" => "10"
    }
  end

  defp deposit_body do
    %{
      "amount" => "5",
      "asset_id" => 3,
      "id" => "deposit-1",
      "l1_tx_hash" => "0xdeposit",
      "status" => "completed",
      "timestamp" => 1_800_000_000_000
    }
  end

  defp withdrawal_body do
    %{
      "amount" => "1",
      "asset_id" => 1,
      "id" => "withdrawal-1",
      "l1_tx_hash" => "0xwithdrawal",
      "status" => "pending",
      "timestamp" => 1_800_000_000_000,
      "type" => "secure"
    }
  end

  defp transfer_body do
    %{
      "amount" => "2",
      "asset_id" => 2,
      "fee" => "0.01",
      "from_account_index" => 1,
      "from_l1_address" => "0xfrom",
      "from_route" => "perps",
      "id" => "transfer-1",
      "timestamp" => 1_800_000_000_000,
      "to_account_index" => 2,
      "to_l1_address" => "0xto",
      "to_route" => "spot",
      "tx_hash" => "0xtransfer",
      "type" => "internal"
    }
  end

  defp liquidation_body do
    %{
      "executed_at" => 1_800_000_000,
      "id" => 1,
      "info" => %{
        "asset_index_prices" => [],
        "assets" => [],
        "mark_prices" => [],
        "positions" => [],
        "risk_info_after" => %{},
        "risk_info_before" => %{}
      },
      "market_id" => 1,
      "trade" => %{
        "maker_fee" => "0",
        "price" => "80",
        "size" => "0.25",
        "taker_fee" => "0",
        "transaction_time" => 1_800_000_000
      },
      "type" => "partial"
    }
  end

  defp funding_body do
    %{"direction" => "long", "rate" => "0.0012", "timestamp" => 1_800_000_000, "value" => "0.03"}
  end

  defp assert_provider_stub!(schema, row) do
    missing_fields =
      @provider_required_fields
      |> Map.fetch!(schema)
      |> Enum.reject(&Map.has_key?(row, &1))

    assert missing_fields == [],
           "#{schema} stub is missing required provider fields: #{Enum.join(missing_fields, ", ")}"
  end

  defp unique_stub(name), do: {__MODULE__, name, System.unique_integer([:positive])}
end
