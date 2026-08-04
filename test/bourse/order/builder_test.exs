defmodule Bourse.Order.BuilderTest do
  @moduledoc "Tests for fluent order construction."

  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.Order.Builder
  alias Bourse.Test.RequestCollector
  alias Bourse.TestExchange.Bybit

  @moduletag capture_log: true

  defp unique_stub do
    :"order_builder_stub_#{System.unique_integer([:positive])}"
  end

  defp build_test_exchange do
    %Exchange{
      id: "bybit",
      name: "Bybit",
      sandbox: false,
      rate_limit_ms: 0,
      hostname: nil,
      base_urls: %{"public" => "https://api.bybit.com", "private" => "https://api.bybit.com"},
      has: Bybit.__features__(),
      required_credentials: %{},
      signing_pattern: :hmac_sha256_headers,
      signing_config: Bybit.__signing__().config,
      options: %{},
      error_codes: %{},
      broad_error_patterns: %{},
      http_exceptions: %{},
      module: Bybit,
      markets: [
        %Bourse.Market{
          symbol: "BTC/USDT",
          precision: %{"amount" => 0.001, "price" => 0.1}
        }
      ],
      spec: %{}
    }
  end

  describe "fluent construction" do
    test "new/3 creates a market order builder" do
      assert %Builder{
               symbol: "BTC/USDT",
               side: "buy",
               amount: 0.1,
               type: "market",
               params: []
             } = Builder.new("BTC/USDT", "buy", 0.1)
    end

    test "limit/2 switches to limit order and stores price" do
      builder =
        "BTC/USDT"
        |> Builder.new("sell", 0.2)
        |> Builder.limit(50_000)

      assert %Builder{type: "limit", params: [price: 50_000]} = builder
    end

    test "stop_loss/2 and take_profit/2 accumulate optional params" do
      builder =
        "BTC/USDT"
        |> Builder.new("buy", 0.1)
        |> Builder.limit(50_000)
        |> Builder.stop_loss(48_000)
        |> Builder.take_profit(55_000)

      assert builder.params == [
               price: 50_000,
               stop_loss_price: 48_000,
               take_profit_price: 55_000
             ]
    end
  end

  describe "submit/3" do
    test "submits through unified create_order with supplied credentials" do
      stub = unique_stub()
      exchange = build_test_exchange()
      credentials = %Credentials{api_key: "test", secret: "test"}

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"orderId" => "abc123"}})
      end)

      result =
        "BTC/USDT"
        |> Builder.new("buy", 0.1)
        |> Builder.limit(50_000)
        |> Builder.stop_loss(48_000)
        |> Builder.take_profit(55_000)
        |> Builder.submit(exchange, credentials,
          endpoint_index: 2,
          plug: {Req.Test, stub},
          sanity: [market: %{"symbol" => "BTC/USDT"}]
        )

      assert RequestCollector.one!(requests).method == "POST"

      assert {:ok, response} = result
      assert response.id == "abc123"
      assert response.info["orderId"] == "abc123"
    end

    test "submits without sanity validation by default" do
      stub = unique_stub()
      exchange = build_test_exchange()
      credentials = %Credentials{api_key: "test", secret: "test"}

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"orderId" => "plain123"}})
      end)

      result =
        "BTC/USDT"
        |> Builder.new("sell", 0.1)
        |> Builder.submit(exchange, credentials, endpoint_index: 2, plug: {Req.Test, stub})

      assert RequestCollector.one!(requests).method == "POST"

      assert {:ok, response} = result
      assert response.id == "plain123"
      assert response.info["orderId"] == "plain123"
    end

    test "returns sanity errors before submitting when opt-in validation fails" do
      stub = unique_stub()
      exchange = build_test_exchange()
      credentials = %Credentials{api_key: "test", secret: "test"}
      market = %{"symbol" => "BTC/USDT", "limits" => %{"amount" => %{"min" => 0.01}}}
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        # Do not flunk here: Bourse.HTTP rescues plug exceptions as network errors.
        send(test_pid, {:request_issued, conn.method, conn.request_path})
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{}})
      end)

      result =
        "BTC/USDT"
        |> Builder.new("buy", 0.001)
        |> Builder.limit(50_000)
        |> Builder.submit(exchange, credentials,
          endpoint_index: 2,
          plug: {Req.Test, stub},
          sanity: [market: market]
        )

      assert {:error, {:sanity_check, [{:check_amount, message}]}} = result
      assert message =~ "below minimum"
      refute_received {:request_issued, _method, _path}
    end

    test "returns sanity warnings with successful submission" do
      stub = unique_stub()
      exchange = build_test_exchange()
      credentials = %Credentials{api_key: "test", secret: "test"}
      market = %{"symbol" => "BTC/USDT"}

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"orderId" => "warn123"}})
      end)

      result =
        "BTC/USDT"
        |> Builder.new("buy", 0.1)
        |> Builder.limit(125)
        |> Builder.submit(exchange, credentials,
          endpoint_index: 2,
          plug: {Req.Test, stub},
          sanity: [market: market, reference_price: 100, deviation_threshold: 0.10]
        )

      assert RequestCollector.one!(requests).method == "POST"

      assert {:ok, response, [{:check_price_deviation, _message}]} = result
      assert response.id == "warn123"
      assert response.info["orderId"] == "warn123"
    end
  end
end
