defmodule Bourse.AlpacaAuthoredPrivateTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Dispatch
  alias Bourse.Exchange
  alias Bourse.Test.RequestCollector
  alias Bourse.ReferenceSlice

  @order_id "task429-paper-order"
  @client_order_id "task429-client-order"
  @submitted_at "2026-07-23T01:02:03.456789Z"
  @equity_symbol "GLD"

  test "owned Alpaca support inventory is exhaustive and names options unsupported" do
    spec = Bourse.Spec.load!("alpaca")
    support = spec["capabilities"]["has"]

    assert spec["authored"] == true
    assert spec["hand_owned"] == true
    assert spec["frozen"] == true
    refute Map.has_key?(spec["raw"]["describe"]["api"], "broker")

    supported =
      support
      |> Enum.filter(fn {_method, enabled?} -> enabled? == true end)
      |> MapSet.new(&elem(&1, 0))

    assert supported ==
             MapSet.new(~w(
               cancelOrder createOrder fetchBalance fetchClosedOrders fetchMarkets
               fetchOHLCV fetchOpenOrders fetchOrder fetchOrders fetchPositions fetchTicker fetchTime
             ))

    reference =
      "alpaca"
      |> ReferenceSlice.spec_path()
      |> Bourse.Spec.decode_file!()

    reference_methods =
      Map.keys(reference["capabilities"]["has"]) ++ Map.keys(reference["endpoints"]["unified"])

    assert support |> Map.keys() |> Enum.sort() == reference_methods |> Enum.uniq() |> Enum.sort()
    assert support["option"] == false
    assert support["fetchOption"] == false
    assert support["fetchOptionChain"] == false

    refute Map.has_key?(spec["raw"]["describe"]["urls"]["api"], "broker")
    refute Map.has_key?(spec["raw"]["describe"]["urls"]["test"], "broker")
    assert spec["raw"]["describe"]["options"]["defaultTimeInForce"] == "day"
    refute Map.has_key?(spec["raw"]["describe"]["options"], "defaultExchange")
    refute Map.has_key?(spec["raw"]["describe"]["options"], "exchanges")

    assert spec["fees"]["trading"] == %{
             "maker" => 0,
             "percentage" => true,
             "taker" => 0,
             "tierBased" => false,
             "tiers" => %{"maker" => [], "taker" => []}
           }

    assert spec["urls"]["fees"] == "https://docs.alpaca.markets/us/docs/regulatory-fees"
  end

  test "account response becomes a USD equity balance without crypto defaults" do
    {stub, requests} = stub_with_response(:account, account_payload())

    assert {:ok, %Bourse.Balance{} = balance} = Bourse.fetch_balance(exchange(), plug: {Req.Test, stub})

    assert balance.free == %{"USD" => 100_000.0}
    assert balance.used == %{"USD" => 0.0}
    assert balance.total == %{"USD" => 100_000.0}
    assert balance.info["buying_power"] == "400000"
    assert balance.info["shorting_enabled"] == true

    request = RequestCollector.one!(requests)
    assert request.request_path == "/v2/account"
    assert Plug.Conn.get_req_header(request, "apca-api-key-id") == ["key"]
    assert Plug.Conn.get_req_header(request, "apca-api-secret-key") == ["secret"]
  end

  test "equity asset and position rows preserve fractional, borrow, and signed-share semantics" do
    stub = {__MODULE__, :equity_reads, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      response = if conn.request_path == "/v2/assets", do: [asset_payload()], else: [position_payload()]
      Req.Test.json(conn, response)
    end)

    assert {:ok, [%Bourse.Market{} = market]} = Bourse.fetch_markets(exchange(), plug: {Req.Test, stub})
    assert market.symbol == @equity_symbol
    assert market.base == @equity_symbol
    assert market.quote == "USD"
    assert market.type == "spot"
    assert market.margin == true
    assert market.option == false
    assert market.info["fractionable"] == true
    assert market.info["shortable"] == true
    assert market.info["borrow_status"] == "easy_to_borrow"

    assert {:ok, [%Bourse.Position{} = position]} = Bourse.fetch_positions(exchange(), plug: {Req.Test, stub})
    assert position.symbol == @equity_symbol
    assert position.side == "short"
    assert position.contracts == 1.5
    assert position.notional == 450.0
    assert position.entry_price == 310.0
    assert position.mark_price == 300.0
    assert position.unrealized_pnl == 15.0
    assert position.percentage == 3.2258
  end

  test "paper order request, response, fetch, and empty cancel acknowledgement stay unified" do
    stub = {__MODULE__, :order_lifecycle, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      {conn, _body} = RequestCollector.capture_with_body(requests, conn)

      case conn.method do
        "DELETE" -> Plug.Conn.send_resp(conn, 204, "")
        _method -> Req.Test.json(conn, order_payload())
      end
    end)

    opts = [price: 1.0, client_order_id: @client_order_id, plug: {Req.Test, stub}]

    assert {:ok, %Bourse.Order{} = created} =
             Bourse.create_order(exchange(), @equity_symbol, "limit", "buy", 1, opts)

    assert created.id == @order_id
    assert created.client_order_id == @client_order_id
    assert created.status == "open"
    assert created.amount == 1.0
    assert created.remaining == 1.0
    assert created.price == 1.0
    assert created.time_in_force == "DAY"

    assert {:ok, %Bourse.Order{id: @order_id, symbol: @equity_symbol, status: "open"}} =
             Bourse.fetch_order(exchange(), @order_id, plug: {Req.Test, stub})

    assert {:ok, %Bourse.Order{id: @order_id, status: "canceled", info: %{"http_status" => 204}}} =
             Bourse.cancel_order(exchange(), @order_id, plug: {Req.Test, stub})

    [create_request, fetch_request, cancel_request] = RequestCollector.requests(requests)
    assert create_request.conn.method == "POST"
    assert create_request.conn.request_path == "/v2/orders"

    assert Jason.decode!(create_request.body) == %{
             "client_order_id" => @client_order_id,
             "extended_hours" => false,
             "limit_price" => 1.0,
             "qty" => 1,
             "side" => "buy",
             "symbol" => @equity_symbol,
             "time_in_force" => "day",
             "type" => "limit"
           }

    assert fetch_request.conn.method == "GET"
    assert fetch_request.conn.request_path == "/v2/orders/#{@order_id}"
    assert cancel_request.conn.method == "DELETE"
    assert cancel_request.conn.request_path == "/v2/orders/#{@order_id}"
  end

  test "Alpaca rejected-order code retains the provider error semantics" do
    stub = {__MODULE__, :rejected_order, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"code" => 40_010_001, "message" => "qty or notional is required"})
    end)

    assert {:error,
            %Bourse.Error{
              type: :bad_request,
              code: 40_010_001,
              http_status: 422,
              message: "qty or notional is required"
            }} =
             raw_call(
               exchange(),
               "v2/orders",
               :post,
               %{
                 "symbol" => @equity_symbol,
                 "side" => "buy",
                 "type" => "limit",
                 "limit_price" => 1,
                 "time_in_force" => "day"
               },
               plug: {Req.Test, stub}
             )
  end

  defp exchange do
    Exchange.new!(:alpaca,
      sandbox: true,
      credentials: Credentials.new!(api_key: "key", secret: "secret")
    )
  end

  defp stub_with_response(name, response) do
    stub = {__MODULE__, name, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, response)
    end)

    {stub, requests}
  end

  defp raw_call(exchange, path, method, params, opts) do
    config = Enum.find(exchange.module.__endpoints__(), &(&1.path == path and &1.method == method))
    Dispatch.call(exchange, config, params, opts)
  end

  defp account_payload do
    %{
      "id" => "paper-account",
      "currency" => "USD",
      "cash" => "100000",
      "equity" => "100000",
      "initial_margin" => "0",
      "buying_power" => "400000",
      "shorting_enabled" => true,
      "status" => "ACTIVE"
    }
  end

  defp asset_payload do
    %{
      "id" => "asset-gld",
      "class" => "us_equity",
      "symbol" => @equity_symbol,
      "status" => "active",
      "tradable" => true,
      "marginable" => true,
      "shortable" => true,
      "easy_to_borrow" => true,
      "borrow_status" => "easy_to_borrow",
      "fractionable" => true,
      "min_order_size" => "0.000001",
      "min_trade_increment" => "0.000001",
      "price_increment" => "0.01"
    }
  end

  defp position_payload do
    %{
      "asset_id" => "asset-gld",
      "symbol" => @equity_symbol,
      "side" => "short",
      "qty" => "-1.5",
      "market_value" => "-450",
      "avg_entry_price" => "310",
      "current_price" => "300",
      "unrealized_pl" => "15",
      "unrealized_plpc" => "0.032258"
    }
  end

  defp order_payload do
    %{
      "id" => @order_id,
      "client_order_id" => @client_order_id,
      "symbol" => @equity_symbol,
      "submitted_at" => @submitted_at,
      "status" => "accepted",
      "type" => "limit",
      "side" => "buy",
      "limit_price" => "1",
      "qty" => "1",
      "filled_qty" => "0",
      "filled_avg_price" => nil,
      "time_in_force" => "day",
      "extended_hours" => false,
      "asset_class" => "us_equity"
    }
  end
end
