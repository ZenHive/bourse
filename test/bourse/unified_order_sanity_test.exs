defmodule Bourse.UnifiedOrderSanityTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified

  test "create_order rejects an amount below the loaded market minimum before dispatch" do
    stub = refusing_stub()

    assert {:error, %Error{type: :invalid_order} = error} =
             Bourse.create_order(loaded_exchange(), "BTC/USDT", "limit", "buy", 0.001,
               price: 100,
               sanity: true,
               plug: {Req.Test, stub}
             )

    assert error.exchange == "okx"
    assert error.message =~ "below minimum"
    assert [hint] = error.hints
    assert hint =~ "below minimum"
    assert %{"sanity_check" => %{"check_amount" => _}} = error.raw
    refute_request_issued()
  end

  test "create_order rejects missing precision before dispatch when markets are not loaded" do
    exchange = Exchange.new!("okx", api_key: "test-key", secret: "test-secret", password: "test-pass")
    refute is_list(exchange.markets)

    stub = refusing_stub()

    error =
      assert_raise Error, fn ->
        Bourse.create_order(exchange, "BTC/USDT", "limit", "buy", 0.001,
          price: 100,
          sanity: true,
          plug: {Req.Test, stub}
        )
      end

    assert error.type == :invalid_order
    assert error.exchange == "okx"
    assert error.message =~ "BTC-USDT"
    assert error.message =~ "missing instrument precision"
    refute_request_issued()
  end

  test "create_order leaves validation to the exchange by default" do
    {stub, requests} = order_stub("2")

    assert {:ok, %Bourse.Order{id: "2"}} =
             Bourse.create_order(loaded_exchange(), "BTC/USDT", "limit", "buy", 0.001,
               price: 100,
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).method == "POST"
  end

  test "every positional-side write rejects an atom before dispatch without markets or sanity" do
    exchange = Exchange.new!("okx", api_key: "test-key", secret: "test-secret", password: "test-pass")
    refute is_list(exchange.markets)
    stub = refusing_stub()

    side_methods =
      Enum.filter(Unified.method_defs(), fn {_name, _js_name, required, _description} -> :side in required end)

    assert side_methods != []

    for {name, _js_name, required, _description} <- side_methods do
      required_values = Enum.map(required, &side_method_value/1)

      assert {:error, %Error{type: :invalid_parameters} = error} =
               apply(Bourse, name, [exchange | required_values] ++ [[plug: {Req.Test, stub}]]),
             "#{name} accepted an atom side"

      assert error.message =~ "Invalid side: :sell"
      assert error.message =~ ~s(Accepted forms: "buy" or "sell")
      assert error.raw == %{"accepted" => ["buy", "sell"], "reason" => "invalid_side", "side" => ":sell"}
    end

    refute_request_issued()
  end

  test "create_order rejects an uninterpretable string side before dispatch without markets" do
    exchange = Exchange.new!("okx", api_key: "test-key", secret: "test-secret", password: "test-pass")
    refute is_list(exchange.markets)
    stub = refusing_stub()

    for side <- ["hold", "BUY", ""] do
      assert {:error, %Error{type: :invalid_parameters} = error} =
               Bourse.create_order(exchange, "BTC/USDT", "limit", side, 1, plug: {Req.Test, stub})

      assert error.message =~ "Invalid side: #{inspect(side)}"
      assert error.message =~ ~s(Accepted forms: "buy" or "sell")
      assert error.raw["reason"] == "invalid_side"
      assert error.raw["accepted"] == ["buy", "sell"]
    end

    refute_request_issued()
  end

  test "create_order dispatches when the amount satisfies the market minimum" do
    {stub, requests} = order_stub("3")

    assert {:ok, %Bourse.Order{id: "3"}} =
             Bourse.create_order(loaded_exchange(), "BTC/USDT", "limit", "buy", 0.5,
               price: 100,
               sanity: true,
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).method == "POST"
  end

  test "edit_order rejects an amount below the loaded market minimum before dispatch" do
    stub = refusing_stub()

    assert {:error, %Error{type: :invalid_order} = error} =
             Bourse.edit_order(loaded_exchange(), "1", "BTC/USDT", "limit", "buy",
               amount: 0.001,
               price: 100,
               sanity: true,
               plug: {Req.Test, stub}
             )

    assert error.message =~ "below minimum"
    refute_request_issued()
  end

  # edit_order is a partial update: omitting amount means "leave the amount
  # alone", not "amount is missing". Validating it as a create would reject a
  # legitimate price-only edit.
  test "edit_order allows a price-only edit with sanity enabled" do
    {stub, requests} = order_stub("4")

    assert {:ok, %Bourse.Order{id: "4"}} =
             Bourse.edit_order(loaded_exchange(), "1", "BTC/USDT", "limit", "buy",
               price: 100,
               sanity: true,
               plug: {Req.Test, stub}
             )

    assert RequestCollector.one!(requests).method == "POST"
  end

  test "edit_order still rejects an explicitly invalid amount on a partial edit" do
    stub = refusing_stub()

    assert {:error, %Error{type: :invalid_order} = error} =
             Bourse.edit_order(loaded_exchange(), "1", "BTC/USDT", "limit", "buy",
               amount: -1,
               sanity: true,
               plug: {Req.Test, stub}
             )

    assert error.message =~ "positive number"
    refute_request_issued()
  end

  defp loaded_exchange do
    "okx"
    |> Exchange.new!(api_key: "test-key", secret: "test-secret", password: "test-pass")
    |> Exchange.put_markets([
      %Market{
        id: "BTC-USDT",
        symbol: "BTC/USDT",
        precision: %{"amount" => 0.01, "price" => 0.1},
        limits: %{"amount" => %{"min" => 0.01}}
      }
    ])
  end

  # Records any request that escapes to the transport. A `flunk` here would be
  # useless: Bourse.HTTP rescues exceptions raised inside the plug and returns
  # {:error, %Bourse.Error{type: :network_error}}, so the assertion would be
  # swallowed. Messaging the test process survives that rescue, which is what
  # `refute_request_issued/0` then checks.
  defp refusing_stub do
    stub = unique_stub()
    test_pid = self()

    Req.Test.stub(stub, fn conn ->
      send(test_pid, {:request_issued, conn.method, conn.request_path})
      Req.Test.json(conn, %{"code" => "0", "data" => [], "msg" => ""})
    end)

    stub
  end

  defp refute_request_issued do
    refute_received {:request_issued, _method, _path}
  end

  defp order_stub(order_id) do
    stub = unique_stub()
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      Req.Test.json(conn, %{
        "code" => "0",
        "data" => [%{"clOrdId" => "", "ordId" => order_id, "sCode" => "0", "sMsg" => ""}],
        "msg" => ""
      })
    end)

    {stub, requests}
  end

  defp unique_stub, do: {__MODULE__, System.unique_integer([:positive])}

  defp side_method_value(:amount), do: 1
  defp side_method_value(:cost), do: 1
  defp side_method_value(:duration), do: 60
  defp side_method_value(:id), do: "order-id"
  defp side_method_value(:side), do: :sell
  defp side_method_value(:symbol), do: "BTC/USDT"
  defp side_method_value(:type), do: "limit"
end
