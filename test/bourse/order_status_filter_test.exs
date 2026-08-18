defmodule Bourse.OrderStatusFilterTest do
  @moduledoc """
  Task 536 — order-status reads that share an all-orders endpoint must post-filter.

  Venues that route `fetchClosedOrders` / `fetchCanceledOrders` through the same
  all-orders family as `fetchOrders` (Binance spot + USD-M) declare those methods
  as emulated. Emulation reuses `fetchOrders` and filters by unified status so a
  caller asking for canceled orders never receives filled ones.
  """
  use ExUnit.Case, async: false

  alias Bourse.Emulation
  alias Bourse.Exchange
  alias Bourse.Order
  alias Bourse.Spec
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified

  # Realistic Binance allOrders body: mixed CANCELED + FILLED (venue wire values).
  # Shape matches GET /api/v3/allOrders and GET /fapi/v1/allOrders rows.
  @mixed_all_orders [
    %{
      "symbol" => "BTCUSDT",
      "orderId" => 1001,
      "clientOrderId" => "canceled-1",
      "price" => "50000.00",
      "origQty" => "0.010",
      "executedQty" => "0.000",
      "cummulativeQuoteQty" => "0.000",
      "cumQuote" => "0.000",
      "status" => "CANCELED",
      "timeInForce" => "GTC",
      "type" => "LIMIT",
      "side" => "BUY",
      "stopPrice" => "0.0",
      "time" => 1_700_000_000_000,
      "updateTime" => 1_700_000_000_100,
      "isWorking" => false,
      "origQuoteOrderQty" => "0.0",
      "positionSide" => "BOTH"
    },
    %{
      "symbol" => "BTCUSDT",
      "orderId" => 1002,
      "clientOrderId" => "filled-1",
      "price" => "51000.00",
      "origQty" => "0.010",
      "executedQty" => "0.010",
      "cummulativeQuoteQty" => "510.00",
      "cumQuote" => "510.00",
      "status" => "FILLED",
      "timeInForce" => "GTC",
      "type" => "LIMIT",
      "side" => "BUY",
      "stopPrice" => "0.0",
      "time" => 1_700_000_000_200,
      "updateTime" => 1_700_000_000_300,
      "isWorking" => false,
      "origQuoteOrderQty" => "0.0",
      "positionSide" => "BOTH"
    },
    %{
      "symbol" => "BTCUSDT",
      "orderId" => 1003,
      "clientOrderId" => "canceled-2",
      "price" => "49000.00",
      "origQty" => "0.020",
      "executedQty" => "0.000",
      "cummulativeQuoteQty" => "0.000",
      "cumQuote" => "0.000",
      "status" => "CANCELED",
      "timeInForce" => "GTC",
      "type" => "LIMIT",
      "side" => "SELL",
      "stopPrice" => "0.0",
      "time" => 1_700_000_000_400,
      "updateTime" => 1_700_000_000_500,
      "isWorking" => false,
      "origQuoteOrderQty" => "0.0",
      "positionSide" => "BOTH"
    }
  ]

  @shared_all_orders_venues [
    {"binance", "BTC/USDT", "/api/v3/allOrders"},
    {"binanceusdm", "BTC/USDT:USDT", "/fapi/v1/allOrders"}
  ]

  @order_status_emulated_methods [
    "fetchCanceledOrders",
    "fetchClosedOrders",
    "fetchCanceledAndClosedOrders"
  ]

  test "every has=emulated order-status method is registered in emulated_methods" do
    for exchange_id <- Spec.exchanges() do
      spec = Spec.load!(exchange_id)
      has = get_in(spec, ["capabilities", "has"]) || %{}
      declared = MapSet.new(spec["emulated_methods"] || [], & &1["name"])

      for method <- @order_status_emulated_methods do
        if has[method] == "emulated" do
          assert MapSet.member?(declared, method),
                 "#{exchange_id} capabilities.has[#{method}]=emulated but " <>
                   "emulated_methods does not declare it — shared all-orders " <>
                   "routes would return unfiltered rows"
        end
      end
    end
  end

  test "shared all-orders venues emulate closed/canceled filters at runtime" do
    for {exchange_id, _symbol, _path} <- @shared_all_orders_venues do
      exchange = Exchange.new!(exchange_id)

      assert Emulation.emulated?(exchange, :fetch_closed_orders, :rest),
             "#{exchange_id} fetch_closed_orders must be emulated"

      assert Emulation.emulated?(exchange, :fetch_canceled_orders, :rest),
             "#{exchange_id} fetch_canceled_orders must be emulated"

      refute Emulation.emulated?(exchange, :fetch_orders, :rest),
             "#{exchange_id} fetch_orders must remain a native all-orders read"
    end
  end

  for {exchange_id, symbol, expected_path} <- @shared_all_orders_venues do
    @exchange_id exchange_id
    @symbol symbol
    @expected_path expected_path

    test "#{exchange_id}: fetch_canceled/closed/orders partition a mixed allOrders body" do
      exchange = Exchange.new!(@exchange_id, api_key: "key", secret: "secret", sandbox: true)

      assert {:ok, all_orders} = call_orders(exchange, :fetch_orders, "fetchOrders", @symbol)
      assert {:ok, closed_orders} = call_orders(exchange, :fetch_closed_orders, "fetchClosedOrders", @symbol)
      assert {:ok, canceled_orders} = call_orders(exchange, :fetch_canceled_orders, "fetchCanceledOrders", @symbol)

      assert length(all_orders) == 3
      assert all_orders |> Enum.map(& &1.status) |> Enum.sort() == ["canceled", "canceled", "closed"]

      assert length(closed_orders) == 1
      assert Enum.all?(closed_orders, &Order.closed?/1)
      assert Enum.map(closed_orders, & &1.id) == ["1002"]

      assert length(canceled_orders) == 2
      assert Enum.all?(canceled_orders, &Order.canceled?/1)
      assert canceled_orders |> Enum.map(& &1.id) |> Enum.sort() == ["1001", "1003"]

      # The three methods must not collapse to identical result sets on mixed state.
      refute order_ids(closed_orders) == order_ids(all_orders)
      refute order_ids(canceled_orders) == order_ids(all_orders)
      refute order_ids(closed_orders) == order_ids(canceled_orders)

      # Emulation still hits the shared all-orders family (no separate venue path).
      {requests, stub} = mixed_all_orders_stub()

      assert {:ok, _} =
               Unified.call(
                 exchange,
                 :fetch_closed_orders,
                 "fetchClosedOrders",
                 %{"symbol" => @symbol},
                 plug: {Req.Test, stub}
               )

      paths = requests |> RequestCollector.requests() |> Enum.map(& &1.conn.request_path) |> Enum.sort()

      expected_paths =
        if @exchange_id == "binanceusdm" do
          ["/fapi/v1/allAlgoOrders", @expected_path]
        else
          [@expected_path]
        end

      assert paths == expected_paths
    end
  end

  @tag :network
  @tag :integration
  test "live binanceusdm demo: canceled and closed partitions are disjoint subsets of fetch_orders" do
    case live_exchange("binanceusdm") do
      {:ok, exchange, symbol} ->
        assert {:ok, all_orders} = Bourse.fetch_orders(exchange, symbol: symbol)
        assert {:ok, closed_orders} = Bourse.fetch_closed_orders(exchange, symbol: symbol)
        assert {:ok, canceled_orders} = Bourse.fetch_canceled_orders(exchange, symbol: symbol)

        assert is_list(all_orders) and is_list(closed_orders) and is_list(canceled_orders)

        all_ids = MapSet.new(all_orders, & &1.id)
        closed_ids = MapSet.new(closed_orders, & &1.id)
        canceled_ids = MapSet.new(canceled_orders, & &1.id)

        assert Enum.all?(closed_orders, &Order.closed?/1)
        assert Enum.all?(canceled_orders, &Order.canceled?/1)
        assert closed_orders != [], "live account must contain at least one closed order"
        assert canceled_orders != [], "live account must contain at least one canceled order"
        assert MapSet.disjoint?(closed_ids, canceled_ids)
        assert MapSet.subset?(closed_ids, all_ids)
        assert MapSet.subset?(canceled_ids, all_ids)
        refute order_ids(closed_orders) == order_ids(all_orders)
        refute order_ids(canceled_orders) == order_ids(all_orders)
        refute order_ids(closed_orders) == order_ids(canceled_orders)

      {:skip, reason} ->
        flunk("""
        Binance USD-M demo credentials unavailable: #{reason}

        Set these environment variables:
          export BINANCE_FUTURES_TEST_API_KEY="your_key"
          export BINANCE_FUTURES_TEST_API_SECRET="your_secret"

        Create demo credentials at: https://testnet.binancefuture.com/
        """)
    end
  end

  defp call_orders(exchange, method, js_name, symbol) do
    {_requests, stub} = mixed_all_orders_stub()

    Unified.call(exchange, method, js_name, %{"symbol" => symbol}, plug: {Req.Test, stub})
  end

  defp mixed_all_orders_stub do
    {:ok, requests} = RequestCollector.start_link()
    stub = make_ref()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      body = if String.ends_with?(conn.request_path, "/allAlgoOrders"), do: [], else: @mixed_all_orders
      Req.Test.json(conn, body)
    end)

    {requests, stub}
  end

  defp order_ids(orders), do: orders |> Enum.map(& &1.id) |> Enum.sort()

  defp live_exchange(exchange_id) do
    exchange_atom = String.to_existing_atom(exchange_id)

    case Bourse.Testnet.creds(exchange_atom) do
      %Bourse.Credentials{} = creds ->
        {:ok, Exchange.new!(exchange_id, credentials: creds, sandbox: true), live_symbol(exchange_id)}

      nil ->
        {key_env, secret_env} = live_env_pair(exchange_id)
        key = key_env && System.get_env(key_env)
        secret = secret_env && System.get_env(secret_env)

        if is_binary(key) and key != "" and is_binary(secret) and secret != "" do
          creds = Bourse.Credentials.new!(api_key: key, secret: secret)

          {:ok, Exchange.new!(exchange_id, credentials: creds, sandbox: true), live_symbol(exchange_id)}
        else
          {:skip, "missing #{key_env}/#{secret_env}"}
        end
    end
  end

  defp live_symbol("binanceusdm"), do: "BTC/USDT:USDT"
  defp live_symbol(_), do: "BTC/USDT"

  defp live_env_pair("binanceusdm"), do: {"BINANCE_FUTURES_TEST_API_KEY", "BINANCE_FUTURES_TEST_API_SECRET"}

  defp live_env_pair("binance"), do: {"BINANCE_TESTNET_API_KEY", "BINANCE_TESTNET_API_SECRET"}
  defp live_env_pair(_), do: {nil, nil}
end
