defmodule Bourse.HTTPTest do
  # Registered exchange IDs back circuit-breaker integration cases, so this
  # module runs synchronously while Req.Test stubs remain ownership-scoped.
  use ExUnit.Case, async: false

  alias Bourse.CircuitBreaker
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.HTTP
  alias Bourse.RateLimiter.Info
  alias Bourse.RateLimiter.State
  alias Bourse.Test.CircuitBreakerControl
  alias Bourse.Test.RequestCollector

  @moduletag capture_log: true

  # Build a minimal exchange with unique ID per test to avoid circuit breaker pollution
  setup do
    exchange_id = "http_test_#{System.unique_integer([:positive])}"

    exchange = %Exchange{
      id: exchange_id,
      name: "Test Exchange",
      credentials: nil,
      sandbox: false,
      rate_limit_ms: 100,
      hostname: nil,
      base_urls: %{"public" => "https://api.testexchange.com"},
      has: %{},
      required_credentials: %{},
      options: %{},
      error_codes: %{"10001" => :insufficient_funds, "10002" => :order_not_found},
      broad_error_patterns: %{"Insufficient balance!" => :insufficient_funds},
      error_body_checks: [],
      error_code_fields: ~w(code ret_code retCode error_code),
      http_exceptions: %{"401" => :authentication_error},
      spec: %{}
    }

    {:ok, exchange: exchange, exchange_id: exchange_id}
  end

  # ===========================================================================
  # Successful Requests
  # ===========================================================================

  describe "request/4 successful responses" do
    test "records endpoint rate limit cost against the configured bucket axis", %{exchange: exchange} do
      stub = unique_stub()
      axis = "ip"

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"result" => "ok"})
      end)

      assert {:ok, _} =
               HTTP.request(exchange, :get, "/v5/test",
                 endpoint_rate_limit: %{axes: [axis], cost: 7},
                 plug: {Req.Test, stub}
               )

      assert Bourse.RateLimiter.get_cost({exchange.id, :public, axis}, 60_000) == 7
      assert Bourse.RateLimiter.get_cost({exchange.id, :public, "request"}, 60_000) == 0
    end

    test "stores parsed header info under the header bucket axis", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-mbx-used-weight-1m", "11")
        |> Req.Test.json(%{"result" => "ok"})
      end)

      assert {:ok, _} = HTTP.request(exchange, :get, "/v5/test", plug: {Req.Test, stub})

      assert %Info{used: 11, axis: "ip"} = State.status(exchange.id, :public, "ip")
    end

    test "returns decoded JSON body on 200", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"result" => "ok", "data" => [1, 2, 3]})
      end)

      assert {:ok, response} = HTTP.request(exchange, :get, "/v5/test", plug: {Req.Test, stub})
      assert response.status == 200
      assert response.body == %{"result" => "ok", "data" => [1, 2, 3]}
      assert is_map(response.headers)
    end

    test "passes query params for GET requests", %{exchange: exchange} do
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0})
      end)

      assert {:ok, _} =
               HTTP.request(exchange, :get, "/v5/market/tickers",
                 params: %{"symbol" => "BTCUSDT", "category" => "spot"},
                 plug: {Req.Test, stub}
               )

      conn = RequestCollector.one!(requests)
      assert conn.query_string =~ "symbol=BTCUSDT"
      assert conn.query_string =~ "category=spot"
    end

    test "encodes list-valued GET params with empty-bracket keys (no encode_query crash)", %{
      exchange: exchange
    } do
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"result" => "ok"})
      end)

      assert {:ok, _} =
               HTTP.request(exchange, :get, "/api/v2/public/subscribe",
                 params: %{"channels" => ["trades.BTC-PERPETUAL.raw", "ticker.BTC-PERPETUAL.raw"]},
                 plug: {Req.Test, stub}
               )

      conn = RequestCollector.one!(requests)

      assert conn.query_string ==
               "channels%5B%5D=trades.BTC-PERPETUAL.raw&channels%5B%5D=ticker.BTC-PERPETUAL.raw"
    end

    test "raises naming the param for nested list-of-maps GET values", %{exchange: exchange} do
      assert_raise ArgumentError, ~r/unsupported nested query param "trades"/, fn ->
        HTTP.request(exchange, :get, "/api/v2/private/execute_block_trade",
          params: %{"trades" => [%{"instrument_name" => "BTC-PERPETUAL"}]}
        )
      end
    end

    test "sends JSON-encoded body for POST requests", %{exchange: exchange} do
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{"orderId" => "123"}})
      end)

      assert {:ok, response} =
               HTTP.request(exchange, :post, "/v5/order/create",
                 params: %{"symbol" => "BTCUSDT", "side" => "buy"},
                 plug: {Req.Test, stub}
               )

      decoded = RequestCollector.json_body!(requests)
      assert decoded["symbol"] == "BTCUSDT"
      assert decoded["side"] == "buy"

      assert response.body["result"]["orderId"] == "123"
    end

    test "sends an empty JSON object for JSON-body POST requests", %{exchange: exchange} do
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"result" => "ok"})
      end)

      assert {:ok, _} =
               HTTP.request(exchange, :post, "/public/get_time",
                 body_encoding: "json",
                 plug: {Req.Test, stub}
               )

      assert RequestCollector.one_request!(requests).body == "{}"
    end

    test "keeps GET requests body-less despite a JSON-body convention", %{exchange: exchange} do
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"result" => "ok"})
      end)

      assert {:ok, _} =
               HTTP.request(exchange, :get, "/public/get_time",
                 body_encoding: "json",
                 plug: {Req.Test, stub}
               )

      assert RequestCollector.one_request!(requests).body == ""
    end
  end

  # ===========================================================================
  # HTTP Error Responses
  # ===========================================================================

  describe "request/4 HTTP error responses" do
    test "returns rate_limit_exceeded on 429", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "Too many requests"}))
      end)

      assert {:error, %Error{type: :rate_limit_exceeded}} =
               HTTP.request(exchange, :get, "/test",
                 plug: {Req.Test, stub},
                 retry_delay: &zero_retry_delay/1
               )
    end

    test "returns authentication_error on 401", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "Invalid API key"}))
      end)

      assert {:error, %Error{type: :authentication_error}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "returns authentication_error on 403", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "Forbidden"}))
      end)

      assert {:error, %Error{type: :authentication_error}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "maps HTTP status via errors.status_map and tags retry_class", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"message" => "Service unavailable"}))
      end)

      exchange = %{exchange | status_map: %{"503" => :exchange_not_available}}

      assert {:error, %Error{type: :exchange_not_available, http_status: 503, retry_class: :server_busy}} =
               HTTP.request(exchange, :get, "/test",
                 plug: {Req.Test, stub},
                 retry_delay: &zero_retry_delay/1
               )
    end

    test "status_map takes precedence over legacy http_exceptions", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "boom"}))
      end)

      exchange = %{
        exchange
        | status_map: %{"500" => :exchange_not_available},
          http_exceptions: %{"500" => :bad_request}
      }

      assert {:error, %Error{type: :exchange_not_available}} =
               HTTP.request(exchange, :get, "/test",
                 plug: {Req.Test, stub},
                 retry_delay: &zero_retry_delay/1
               )
    end

    test "zero-delay retry controller preserves retry count and eventual result", %{exchange: exchange} do
      stub = unique_stub()
      attempts = :counters.new(1, [:atomics])
      parent = self()

      Req.Test.stub(stub, fn conn ->
        :counters.add(attempts, 1, 1)
        attempt = :counters.get(attempts, 1)

        if attempt < 4 do
          conn
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"message" => "retry"})
        else
          Req.Test.json(conn, %{"result" => "ok"})
        end
      end)

      retry_delay = fn retry_count ->
        send(parent, {:retry_delay, retry_count})
        0
      end

      assert {:ok, %{status: 200, body: %{"result" => "ok"}}} =
               HTTP.request(exchange, :get, "/test",
                 plug: {Req.Test, stub},
                 retry_delay: retry_delay
               )

      assert :counters.get(attempts, 1) == 4
      assert_received {:retry_delay, 0}
      assert_received {:retry_delay, 1}
      assert_received {:retry_delay, 2}
      refute_received {:retry_delay, 3}
    end
  end

  # ===========================================================================
  # Body-Level Error Detection
  # ===========================================================================

  describe "request/4 body-level errors" do
    test "detects non-zero ret_code as error", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"ret_code" => 10_001, "retMsg" => "Insufficient balance"})
      end)

      exchange = %{exchange | error_codes: %{"10001" => :insufficient_funds}}

      assert {:error, %Error{type: :insufficient_funds}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "detects non-zero code field as error", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"code" => "10002", "msg" => "Order not found"})
      end)

      exchange = %{exchange | error_codes: %{"10002" => :order_not_found}}

      assert {:error, %Error{type: :order_not_found, message: "Order not found"}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "passes through when ret_code is 0", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"ret_code" => 0, "result" => "good"})
      end)

      assert {:ok, response} = HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
      assert response.body["result"] == "good"
    end

    test "returns exchange_error for unmapped error code", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"code" => "99999", "message" => "Something weird"})
      end)

      exchange = %{exchange | error_codes: %{}, broad_error_patterns: %{}}

      assert {:error, %Error{type: :exchange_error, message: "Something weird"}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "matches broad error patterns by message substring", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"code" => "99999", "msg" => "Insufficient balance! Please deposit."})
      end)

      # No exact match for "99999", but broad pattern matches the message
      exchange = %{exchange | error_codes: %{}}

      assert {:error, %Error{type: :insufficient_funds}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "signed requests classify against the authored market scope for their API base URL" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"code" => -2019, "msg" => "Margin is insufficient."})
      end)

      exchange = isolated_exchange!("binancecoinm")
      signed = %{url: "/order", method: :post, headers: [], body: "{}"}

      assert Exchange.error_scope(exchange, "https://demo-dapi.binance.com/dapi/v1") == "inverse"

      assert {:error,
              %Error{
                type: :insufficient_funds,
                retry_class: :non_retryable,
                code: -2019
              }} =
               HTTP.signed_request(
                 exchange,
                 signed,
                 "https://demo-dapi.binance.com/dapi/v1",
                 plug: {Req.Test, stub}
               )
    end

    test "detects error using spec-configured custom field name", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        # Exchange uses "label" as its error code field (Gate-style), not the default list
        Req.Test.json(conn, %{"label" => "BAD_REQUEST", "message" => "bad input"})
      end)

      exchange = %{
        exchange
        | error_code_fields: ["label"],
          error_codes: %{"BAD_REQUEST" => :bad_request}
      }

      assert {:error, %Error{type: :bad_request}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "does not treat Binance success msg as an error" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"msg" => "success"})
      end)

      {:ok, exchange} = Exchange.new("binance")
      exchange = %{exchange | id: "binance_http_test_#{System.unique_integer([:positive])}"}

      assert {:ok, response} = HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
      assert response.status == 200
      assert response.body == %{"msg" => "success"}
    end

    test "routes Binance LOT_SIZE through guarded handler predicate limbs" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"code" => "-1013", "msg" => "Filter failure: LOT_SIZE"})
      end)

      {:ok, exchange} = Exchange.new("binance")
      exchange = %{exchange | id: "binance_http_test_#{System.unique_integer([:positive])}"}

      assert {:error, %Error{type: :invalid_order, code: "-1013", http_status: 400}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "does not apply Binance body predicate when status guard does not match" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"code" => "-1013", "msg" => "Filter failure: LOT_SIZE"})
      end)

      {:ok, exchange} = Exchange.new("binance")
      exchange = %{exchange | id: "binance_http_test_#{System.unique_integer([:positive])}"}

      assert {:error, %Error{type: :bad_request, code: "-1013", http_status: nil}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "keeps Binance compound -2015 handler on exact-code routing without body discriminator" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"code" => "-2015", "msg" => "Invalid API-key, IP, or permissions."})
      end)

      {:ok, exchange} = Exchange.new("binance", options: %{"hasAlreadyAuthenticatedSuccessfully" => true})
      exchange = %{exchange | id: "binance_http_test_#{System.unique_integer([:positive])}"}

      assert {:error, %Error{type: :authentication_error, code: "-2015", http_status: 400}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "respects error_code_fields priority order", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        # Both fields present — first in list wins
        Req.Test.json(conn, %{"ret_code" => "10001", "code" => "10002", "msg" => "err"})
      end)

      exchange = %{
        exchange
        | error_code_fields: ["ret_code", "code"],
          error_codes: %{"10001" => :insufficient_funds, "10002" => :order_not_found}
      }

      assert {:error, %Error{type: :insufficient_funds}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end
  end

  # ===========================================================================
  # Sentinel-only error_body_checks (Hyperliquid-shape regression — Task 64)
  # ===========================================================================
  #
  # Reproduces the T49 regression on Hyperliquid: spec emits
  #   field: "status", roles: ["status_sentinel"],
  #   sentinel_values: [{"===", "err"}, {"===", "unknownOid"}]
  # Before the fix, classify_by_eq_success/classify_by_error required
  # `has_code_role: true` for === matches, so sentinel-only entries silently
  # fell through to :unknown and the response classified as success.
  describe "request/4 sentinel-only error_body_checks" do
    setup do
      hyperliquid_check = %{
        field: "status",
        field2: "",
        roles: [:status_sentinel],
        sentinel_values: [
          %{operator: "===", value: "err"},
          %{operator: "===", value: "unknownOid"}
        ]
      }

      {:ok, sentinel_check: hyperliquid_check}
    end

    test "classifies === sentinel match as error on sentinel-only entry",
         %{exchange: exchange, sentinel_check: check} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"status" => "err", "response" => "Insufficient margin"})
      end)

      exchange = %{exchange | error_body_checks: [check]}

      assert {:error, %Error{}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "classifies second === sentinel match as error",
         %{exchange: exchange, sentinel_check: check} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"status" => "unknownOid"})
      end)

      exchange = %{exchange | error_body_checks: [check]}

      assert {:error, %Error{}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "non-matching status value is not classified as error",
         %{exchange: exchange, sentinel_check: check} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"status" => "ok", "response" => %{"data" => 1}})
      end)

      # Strip default code fields so the sentinel-only entry is the sole signal.
      exchange = %{exchange | error_body_checks: [check], error_code_fields: []}

      assert {:ok, response} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert response.body["status"] == "ok"
    end

    test "missing status field returns success on sentinel-only entry",
         %{exchange: exchange, sentinel_check: check} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"data" => "no status field"})
      end)

      exchange = %{exchange | error_body_checks: [check], error_code_fields: []}

      assert {:ok, _response} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end
  end

  # ===========================================================================
  # Response classifier: lighter code:200 and deribit result-without-error
  # (Task 186)
  # ===========================================================================

  describe "response classifier (lighter/deribit success envelopes)" do
    test "lighter code:200 is success (not exchange_error)" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"code" => 200, "order_book_details" => [%{"market_id" => 1}]})
      end)

      ex = isolated_exchange!("lighter")

      assert {:ok, resp} =
               HTTP.request(ex, :get, "/test", plug: {Req.Test, stub})

      assert resp.body["code"] == 200
    end

    test "Bourse.fetch_markets on lighter with code:200 returns {:ok, _} carrying parsed markets" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "code" => 200,
          "order_book_details" => [
            %{
              "symbol" => "BTC",
              "market_id" => 1,
              "market_type" => "perp",
              "taker_fee" => "0.0001",
              "maker_fee" => "0.0000",
              "min_base_amount" => "0.01",
              "min_quote_amount" => "0.1",
              "size_decimals" => "4",
              "price_decimals" => "4"
            }
          ]
        })
      end)

      ex = isolated_exchange!("lighter")

      assert {:ok, [%Bourse.Market{symbol: "BTC/USDC:USDC", info: %{"symbol" => "BTC"}}]} =
               Bourse.fetch_markets(ex, plug: {Req.Test, stub})
    end

    test "deribit JSON-RPC result without error is success" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => [%{"instrument_name" => "BTC-PERPETUAL"}]})
      end)

      ex = isolated_exchange!("deribit")

      assert {:ok, resp} =
               HTTP.request(ex, :get, "/test", plug: {Req.Test, stub})

      assert Map.has_key?(resp.body, "result")
    end

    test "Bourse.fetch_markets on deribit with result (no error) returns {:ok, _} carrying parsed markets" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "result" => [
            %{
              "instrument_name" => "ETH-PERPETUAL",
              "base_currency" => "ETH",
              "counter_currency" => "USD",
              "settlement_currency" => "ETH",
              "kind" => "future",
              "settlement_period" => "perpetual",
              "is_active" => true,
              "taker_commission" => 0.0005,
              "maker_commission" => 0.0,
              "contract_size" => 10.0,
              "tick_size" => 0.5,
              "min_trade_amount" => 10.0
            }
          ]
        })
      end)

      ex = isolated_exchange!("deribit")

      assert {:ok, [%Bourse.Market{symbol: "ETH/USD:ETH", info: %{"instrument_name" => "ETH-PERPETUAL"}}]} =
               Bourse.fetch_markets(ex, plug: {Req.Test, stub})
    end

    test "genuine error (non-success code) still classifies as exchange_error" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"code" => 10_001, "msg" => "bad"})
      end)

      ex = isolated_exchange!("lighter")

      assert {:error, %Error{type: :exchange_error}} =
               HTTP.request(ex, :get, "/test", plug: {Req.Test, stub})
    end

    test "non-JSON-RPC result envelope with error code still classifies as exchange_error", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"retCode" => 77_777, "retMsg" => "bad", "result" => %{}})
      end)

      assert {:error, %Error{type: :exchange_error}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "genuine JSON-RPC error still classifies as exchange_error" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "error" => %{"message" => "bad"}, "id" => 1})
      end)

      ex = isolated_exchange!("deribit")

      assert {:error, %Error{}} =
               HTTP.request(ex, :get, "/test", plug: {Req.Test, stub})
    end
  end

  # ===========================================================================
  # HTML Response Detection
  # ===========================================================================

  describe "request/4 HTML detection" do
    test "returns access_restricted for HTML response", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          200,
          "<html><head><title>Access Denied</title></head><body>Blocked</body></html>"
        )
      end)

      assert {:error, %Error{type: :access_restricted} = error} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert error.message =~ "Access Denied"
    end

    test "detects HTML by body content with text/plain content-type", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(403, "<!DOCTYPE html><html><body>Cloudflare block</body></html>")
      end)

      assert {:error, %Error{type: :access_restricted}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "classifies Cloudflare 'Just a moment' challenge as :cloudflare_challenge",
         %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          403,
          "<html><head><title>Just a moment...</title></head><body>checking your browser</body></html>"
        )
      end)

      assert {:error, %Error{type: :cloudflare_challenge} = error} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert error.message =~ "Just a moment"
      assert Enum.any?(error.hints, &String.contains?(&1, "Cloudflare"))
    end

    test "classifies CF body marker as :cloudflare_challenge even without title match",
         %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          503,
          ~s(<html><body><div class="cf-chl-bypass">x</div></body></html>)
        )
      end)

      assert {:error, %Error{type: :cloudflare_challenge}} =
               HTTP.request(exchange, :get, "/test",
                 plug: {Req.Test, stub},
                 retry_delay: &zero_retry_delay/1
               )
    end

    test "HTML without CF markers stays :access_restricted (T80 canary)",
         %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(404, "<html><head><title>Not Found</title></head></html>")
      end)

      assert {:error, %Error{type: :access_restricted}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end
  end

  describe "request/4 empty body" do
    # Task 255: an empty 2xx response is successful, not a network error.
    test "classifies HTTP 200 with empty body as success", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert {:ok, %{status: 200}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    test "whitespace-only body on 200 is success", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Plug.Conn.send_resp(conn, 200, "   \n  ")
      end)

      assert {:ok, %{status: 200}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end

    # Regression: empty-body guard must not flunk HEAD responses, which are
    # body-less by definition. :head is declared as a supported method in
    # build_request/5 — keep the contract consistent.
    test "HEAD with 200 and empty body returns {:ok, _}", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert {:ok, %{status: 200}} =
               HTTP.request(exchange, :head, "/test", plug: {Req.Test, stub})
    end
  end

  describe "request/4 classifier exceptions surface (task 255)" do
    # Deliberately-broken exchange config makes classify_response raise.
    # Before the fix, http.ex's blanket rescue swallowed it as network_error.
    test "classify crash is not mislabeled network_error", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"result" => "ok"})
      end)

      # roles: nil → `:status_sentinel in nil` raises inside classifier (Enumerable)
      broken = %{
        exchange
        | error_body_checks: [
            %{field: "code", field2: "", roles: nil, sentinel_values: []}
          ]
      }

      assert_raise Protocol.UndefinedError, fn ->
        HTTP.request(broken, :get, "/test", plug: {Req.Test, stub})
      end
    end

    test "scalar gateway error through HTTP is typed, not network_error", %{exchange: exchange} do
      stub = unique_stub()

      body = %{
        "timestamp" => "2026-07-16T12:00:00.000Z",
        "status" => 404,
        "error" => "Not Found",
        "requestId" => "req-http-scalar"
      }

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(body))
      end)

      assert {:error, %Error{} = err} =
               HTTP.request(exchange, :get, "/missing", plug: {Req.Test, stub})

      refute err.type == :network_error
      assert err.http_status == 404
      assert err.message == "Not Found"
      assert is_map(err.raw)
      assert err.raw["error"] == "Not Found"
    end
  end

  # ===========================================================================
  # Transport Errors
  # ===========================================================================

  describe "request/4 transport errors" do
    test "returns network_error on transport failure", %{exchange: exchange, exchange_id: exchange_id} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Error{type: :network_error} = error} =
               HTTP.request(exchange, :get, "/test",
                 plug: {Req.Test, stub},
                 retry_delay: &zero_retry_delay/1
               )

      assert error.message =~ "timeout"
      assert error.exchange == exchange_id
    end

    test "returns network_error when the plug raises", %{exchange: exchange, exchange_id: exchange_id} do
      stub = unique_stub()

      Req.Test.stub(stub, fn _conn ->
        raise "plug boom"
      end)

      assert {:error, %Error{type: :network_error} = error} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert error.message =~ "plug boom" or error.message =~ "Exception" or error.message =~ "Request failed"
      assert error.exchange == exchange_id
    end
  end

  # ===========================================================================
  # Circuit Breaker Integration
  # ===========================================================================

  describe "request/4 circuit breaker" do
    test "returns circuit_open when circuit is blown" do
      exchange_id = "bybit"
      isolate_fuse(exchange_id)

      exchange = %Exchange{
        id: exchange_id,
        name: "CB Test",
        credentials: nil,
        sandbox: false,
        rate_limit_ms: 100,
        hostname: nil,
        base_urls: %{"public" => "https://api.test.com"},
        has: %{},
        required_credentials: %{},
        options: %{},
        error_codes: %{},
        broad_error_patterns: %{},
        error_body_checks: [],
        error_code_fields: ~w(code ret_code retCode error_code),
        http_exceptions: %{},
        spec: %{}
      }

      # Blow the circuit
      CircuitBreaker.check(exchange_id)
      for _ <- 1..5, do: CircuitBreaker.record_failure(exchange_id)

      assert {:error, %Error{type: :circuit_open}} = HTTP.request(exchange, :get, "/test")
    end

    # The case above blows the fuse by calling the breaker directly, so it pins
    # `check_circuit_breaker/1` but not the melt half: nothing proves a failing
    # request reaches `record_result/2` at all, nor that `request/4` hands it the
    # *normalized* outcome. That distinction is load-bearing and only observable
    # end-to-end — bybit reports maintenance as `retCode 180023` under HTTP 200,
    # which classifies as `:exchange_not_available` (`retry_class: :server_busy`)
    # and melts. Passing the raw Req result instead would classify on the status
    # threshold, see 200, and never melt — silently disarming the breaker for
    # every venue that signals failure in the body rather than the status line.
    test "a 200 response the venue reads as maintenance melts the breaker through request/4" do
      exchange_id = "bybit"
      CircuitBreakerControl.isolate!(exchange_id, %{max_failures: 3, window_ms: 60_000, reset_ms: 60_000})

      exchange = Exchange.new!(exchange_id)
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"retCode" => 180_023, "retMsg" => "Service maintenance", "result" => %{}})
      end)

      request = fn ->
        HTTP.request(exchange, :get, "/v5/market/time",
          plug: {Req.Test, stub},
          retry_delay: &zero_retry_delay/1
        )
      end

      assert {:error, %Error{type: :exchange_not_available, retry_class: :server_busy}} = request.()
      assert CircuitBreaker.status(exchange_id) == :ok

      for _ <- 1..3, do: request.()

      assert CircuitBreaker.status(exchange_id) == :blown
      assert {:error, %Error{type: :circuit_open}} = request.()
    end
  end

  # ===========================================================================
  # Telemetry
  # ===========================================================================

  describe "request/4 telemetry" do
    setup do
      parent = self()
      ref = make_ref()
      handler_id = "test-http-telemetry-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:bourse, :request, :start],
          [:bourse, :request, :stop],
          [:bourse, :request, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits start and stop events on success", %{exchange: exchange, exchange_id: exchange_id} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert_received {:telemetry, [:bourse, :request, :start], %{system_time: _}, %{exchange: ^exchange_id}}
      assert_received {:telemetry, [:bourse, :request, :stop], %{duration: _}, %{exchange: ^exchange_id, status: 200}}
    end

    test "emits exception event on transport error", %{exchange: exchange} do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _} =
               HTTP.request(exchange, :get, "/test",
                 plug: {Req.Test, stub},
                 retry_delay: &zero_retry_delay/1
               )

      assert_received {:telemetry, [:bourse, :request, :start], _, _}
      assert_received {:telemetry, [:bourse, :request, :exception], %{duration: _}, %{kind: :transport}}
    end
  end

  # ===========================================================================
  # Signed Request Execution
  # ===========================================================================

  describe "signed_request/4" do
    test "adds authored sandbox headers to signed requests", %{exchange: exchange} do
      stub = unique_stub()
      exchange = %{exchange | sandbox: true, sandbox_headers: %{"x-simulated-trading" => "1"}}

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"code" => "0"})
      end)

      signed = %{url: "/api/v5/account/balance", method: :get, headers: [], body: nil}

      assert {:ok, _} =
               HTTP.signed_request(exchange, signed, "https://api.test.com", plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert Plug.Conn.get_req_header(conn, "x-simulated-trading") == ["1"]
    end

    test "prepends base_url to signed url and passes headers", %{exchange: exchange} do
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      signed = %{
        url: "/v5/account/wallet-balance?accountType=UNIFIED",
        method: :get,
        headers: [{"X-BAPI-API-KEY", "my_key"}, {"X-BAPI-SIGN", "abc123"}],
        body: nil
      }

      assert {:ok, response} =
               HTTP.signed_request(exchange, signed, "https://api.test.com", plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.request_path == "/v5/account/wallet-balance"
      assert conn.query_string == "accountType=UNIFIED"

      api_key = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert api_key == ["my_key"]

      assert response.status == 200
    end

    test "passes pre-encoded body without re-encoding", %{exchange: exchange} do
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      signed = %{
        url: "/v5/order/create",
        method: :post,
        headers: [
          {"content-type", "application/json"},
          {"X-BAPI-API-KEY", "my_key"},
          {"X-BAPI-SIGN", "abc123"}
        ],
        body: ~s({"symbol":"BTCUSDT","side":"Buy"})
      }

      assert {:ok, _} =
               HTTP.signed_request(exchange, signed, "https://api.test.com", plug: {Req.Test, stub})

      # Body should be exactly the pre-encoded string, not double-encoded
      assert RequestCollector.one_request!(requests).body == ~s({"symbol":"BTCUSDT","side":"Buy"})
    end

    test "respects circuit breaker" do
      exchange_id = "okx"
      isolate_fuse(exchange_id)

      exchange = %Exchange{
        id: exchange_id,
        name: "CB Signed Test",
        credentials: nil,
        sandbox: false,
        rate_limit_ms: 100,
        hostname: nil,
        base_urls: %{"private" => "https://api.test.com"},
        has: %{},
        required_credentials: %{},
        options: %{},
        error_codes: %{},
        broad_error_patterns: %{},
        error_body_checks: [],
        error_code_fields: ~w(code ret_code retCode error_code),
        http_exceptions: %{},
        spec: %{}
      }

      # Blow the circuit breaker
      CircuitBreaker.check(exchange_id)
      for _ <- 1..5, do: CircuitBreaker.record_failure(exchange_id)

      signed = %{
        url: "/v5/account/wallet-balance",
        method: :get,
        headers: [{"X-BAPI-API-KEY", "my_key"}],
        body: nil
      }

      assert {:error, error} =
               HTTP.signed_request(exchange, signed, "https://api.test.com")

      assert error.type == :circuit_open
    end
  end

  # ===========================================================================
  # Base URL resolution (nested / rest / spot shapes)
  # ===========================================================================

  describe "request/4 base URL resolution" do
    test "uses rest URL when public is absent", %{exchange: exchange} do
      stub = unique_stub()
      exchange = %{exchange | base_urls: %{"rest" => "https://rest.test.com"}}
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert RequestCollector.one!(requests).host == "rest.test.com"
    end

    test "uses first nested public URL", %{exchange: exchange} do
      stub = unique_stub()

      exchange = %{
        exchange
        | base_urls: %{"public" => %{"spot" => "https://nested.test.com/api"}}
      }

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert RequestCollector.one!(requests).host == "nested.test.com"
    end

    test "uses first nested spot URL when public is absent", %{exchange: exchange} do
      stub = unique_stub()

      exchange = %{
        exchange
        | base_urls: %{"spot" => %{"public" => "https://spot.test.com"}}
      }

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert RequestCollector.one!(requests).host == "spot.test.com"
    end

    test "scans top-level map for any binary URL", %{exchange: exchange} do
      stub = unique_stub()
      exchange = %{exchange | base_urls: %{"other" => "https://other.test.com"}}
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})

      assert RequestCollector.one!(requests).host == "other.test.com"
    end

    test "nested map with no binary URL falls through to empty base", %{exchange: exchange} do
      stub = unique_stub()
      exchange = %{exchange | base_urls: %{"public" => %{"spot" => %{"deep" => true}}}}

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{body: %{"ok" => true}}} =
               HTTP.request(exchange, :get, "/test", plug: {Req.Test, stub})
    end
  end

  # Generates a unique stub name to avoid cross-test conflicts
  defp unique_stub do
    :"http_stub_#{System.unique_integer([:positive])}"
  end

  defp isolated_exchange!(exchange_id) do
    {:ok, exchange} = Bourse.exchange(exchange_id)
    %{exchange | id: "#{exchange_id}_http_test_#{System.unique_integer([:positive])}"}
  end

  # The `:test` environment disables the breaker so it cannot couple unrelated
  # modules; the two cases below assert its integration, so they opt back in.
  defp isolate_fuse(exchange_id) do
    CircuitBreakerControl.isolate!(exchange_id)
  end

  defp zero_retry_delay(_retry_count), do: 0
end
