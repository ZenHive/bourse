defmodule Bourse.DispatchTest do
  @moduledoc "Tests for Bourse.Dispatch — path interpolation, URL resolution, HTTP delegation."

  # async: false — Req.Test.stub uses global state
  use ExUnit.Case, async: false

  alias Bourse.Dispatch
  alias Bourse.Exchange
  alias Bourse.Signing
  alias Bourse.Signing.Hyperliquid
  alias Bourse.Test.RequestCollector

  @moduletag capture_log: true

  @request_timeout_status 408
  @first_retry_timestamp_ms 1_700_000_000_000
  @second_retry_timestamp_ms 1_700_000_000_001

  # ---------------------------------------------------------------------------
  # Test Helpers
  # ---------------------------------------------------------------------------

  # Builds a minimal exchange with configurable base_urls
  defp build_exchange(base_urls, opts \\ []) do
    exchange_id = Keyword.get(opts, :id, "dispatch_test_#{System.unique_integer([:positive])}")
    sandbox = Keyword.get(opts, :sandbox, false)

    %Exchange{
      id: exchange_id,
      name: "Test Exchange",
      credentials: nil,
      sandbox: sandbox,
      rate_limit_ms: 100,
      hostname: nil,
      base_urls: base_urls,
      has: %{},
      required_credentials: %{},
      options: %{},
      error_codes: %{},
      broad_error_patterns: %{},
      http_exceptions: %{},
      spec: %{}
    }
  end

  defp unique_stub do
    :"dispatch_stub_#{System.unique_integer([:positive])}"
  end

  defp zero_retry_delay(_retry_count), do: 0

  defp value_sequence(values) do
    {:ok, sequence} = Agent.start_link(fn -> values end)

    fn ->
      Agent.get_and_update(sequence, fn [value | rest] -> {value, rest} end)
    end
  end

  defp deribit_auth(conn) do
    [authorization] = Plug.Conn.get_req_header(conn, "authorization")

    captures =
      Regex.named_captures(
        ~r/ts=(?<timestamp>\d+),sig=(?<signature>[0-9a-f]+),nonce=(?<nonce>\d+)/,
        authorization
      )

    %{
      timestamp: Map.fetch!(captures, "timestamp"),
      signature: Map.fetch!(captures, "signature"),
      nonce: Map.fetch!(captures, "nonce")
    }
  end

  defp expected_deribit_signature(conn, auth, secret) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    request_data = "GET\n#{conn.request_path}#{query}\n\n"

    "#{auth.timestamp}\n#{auth.nonce}\n#{request_data}"
    |> Signing.hmac_sha256(secret)
    |> Signing.encode_hex()
  end

  defp stub_json(stub, response_body) do
    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, response_body)
    end)
  end

  # ---------------------------------------------------------------------------
  # Path Interpolation (Unit Tests)
  # ---------------------------------------------------------------------------

  describe "interpolate_path/2" do
    test "returns path unchanged when no templates" do
      assert {"v5/market/tickers", %{"symbol" => "BTC"}} =
               Dispatch.interpolate_path("v5/market/tickers", %{"symbol" => "BTC"})
    end

    test "returns path unchanged when params empty" do
      assert {"orders/{id}", %{}} =
               Dispatch.interpolate_path("orders/{id}", %{})
    end

    test "replaces single template and removes consumed param" do
      {path, remaining} = Dispatch.interpolate_path("orders/{id}", %{"id" => "123", "symbol" => "BTC"})
      assert path == "orders/123"
      assert remaining == %{"symbol" => "BTC"}
    end

    test "replaces multiple templates" do
      {path, remaining} =
        Dispatch.interpolate_path(
          "{settle}/orders/{id}",
          %{"settle" => "usdt", "id" => "456", "limit" => 10}
        )

      assert path == "usdt/orders/456"
      assert remaining == %{"limit" => 10}
    end

    test "handles atom keys in params" do
      {path, remaining} =
        Dispatch.interpolate_path("orders/{id}", %{id: "789", symbol: "BTC"})

      assert path == "orders/789"
      assert remaining == %{symbol: "BTC"}
    end

    test "leaves placeholder when param not found" do
      {path, remaining} =
        Dispatch.interpolate_path("orders/{id}", %{"symbol" => "BTC"})

      assert path == "orders/{id}"
      assert remaining == %{"symbol" => "BTC"}
    end

    test "logs warning when path param is missing" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          {_path, _remaining} =
            Dispatch.interpolate_path("orders/{id}", %{"symbol" => "BTC"})
        end)

      assert log =~ "path param 'id' missing"
      assert log =~ "orders/{id}"
    end

    test "replaces hyphenated placeholders (htx pattern)" do
      {path, remaining} =
        Dispatch.interpolate_path(
          "v1/order/orders/{order-id}/matchresult",
          %{"order-id" => "abc123", "limit" => 10}
        )

      assert path == "v1/order/orders/abc123/matchresult"
      assert remaining == %{"limit" => 10}
    end

    test "raises on explicit nil param value" do
      assert_raise ArgumentError, ~r/path param 'id' is nil/, fn ->
        Dispatch.interpolate_path("orders/{id}", %{"id" => nil, "symbol" => "BTC"})
      end
    end

    test "raises on nil with atom key" do
      assert_raise ArgumentError, ~r/path param 'id' is nil/, fn ->
        Dispatch.interpolate_path("orders/{id}", %{id: nil})
      end
    end

    test "converts non-string param values to string" do
      {path, _remaining} =
        Dispatch.interpolate_path("limit/{count}", %{"count" => 100})

      assert path == "limit/100"
    end
  end

  describe "interpolate_path/3 with authored-spec descriptor path_params" do
    # Regression: request_contracts store path params as descriptor maps
    # %{"name" => n, "source" => _}; the reduce used to pass the whole map as the
    # placeholder name → `"{#{map}}"` raised Protocol.UndefinedError (String.Chars
    # not implemented for Map), crashing ~44 exchanges on any templated path.
    test "normalizes descriptor-map path params instead of crashing" do
      {path, remaining} =
        Dispatch.interpolate_path(
          "public/ticker/{symbol}",
          %{"symbol" => "BTCUSDT", "limit" => 10},
          [%{"name" => "symbol", "source" => "params"}]
        )

      assert path == "public/ticker/BTCUSDT"
      assert remaining == %{"limit" => 10}
    end

    test "still accepts legacy plain-string path_params" do
      {path, remaining} =
        Dispatch.interpolate_path("orders/{id}", %{"id" => "123", "x" => 1}, ["id"])

      assert path == "orders/123"
      assert remaining == %{"x" => 1}
    end

    test "raises loudly on a non-params descriptor source (invariant guard)" do
      # Every authored path_param sources from "params" (1668/1668, 2026-06-22).
      # A different source must fail loud, not silently resolve from params.
      assert_raise ArgumentError, ~r/unsupported path_param source "literal"/, fn ->
        Dispatch.interpolate_path(
          "public/ticker/{symbol}",
          %{"symbol" => "BTCUSDT"},
          [%{"name" => "symbol", "source" => "literal"}]
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Base URL Resolution (Unit Tests)
  # ---------------------------------------------------------------------------

  describe "resolve_base_url/2" do
    test "flat URL map — direct key lookup" do
      urls = %{"public" => "https://api.bybit.com", "private" => "https://api.bybit.com"}
      assert Dispatch.resolve_base_url(["public"], urls) == "https://api.bybit.com"
      assert Dispatch.resolve_base_url(["private"], urls) == "https://api.bybit.com"
    end

    test "flat distinct keys — Binance sapi pattern" do
      urls = %{
        "sapi" => "https://api.binance.com/sapi/v1",
        "fapiPrivate" => "https://fapi.binance.com/fapi/v1"
      }

      assert Dispatch.resolve_base_url(["sapi"], urls) == "https://api.binance.com/sapi/v1"
      assert Dispatch.resolve_base_url(["fapiPrivate"], urls) == "https://fapi.binance.com/fapi/v1"
    end

    test "nested URL map — Gate pattern" do
      urls = %{
        "public" => %{
          "delivery" => "https://api.gateio.ws/api/v4",
          "spot" => "https://api.gateio.ws/api/v4"
        },
        "private" => %{
          "futures" => "https://api.gateio.ws/api/v4"
        }
      }

      assert Dispatch.resolve_base_url(["public", "delivery"], urls) == "https://api.gateio.ws/api/v4"
      assert Dispatch.resolve_base_url(["private", "futures"], urls) == "https://api.gateio.ws/api/v4"
    end

    test "nested Gate section without sub-path picks a URL under that section only" do
      urls = %{
        "public" => %{
          "delivery" => "https://api.gateio.ws/api/v4",
          "spot" => "https://api.gateio.ws/api/v4"
        },
        "private" => %{
          "futures" => "https://fx-api.gateio.ws/api/v4"
        }
      }

      # Matched top-level "public" is a map with no further section path —
      # find_any_url stays *inside* public and never rides private's host.
      assert Dispatch.resolve_base_url(["public"], urls) == "https://api.gateio.ws/api/v4"
    end

    test "early-stop when string found before sections exhausted" do
      urls = %{"spot" => "https://api.bingx.com"}

      # BingX sections like ["spot", "v1", "private"] — "spot" resolves to string immediately
      assert Dispatch.resolve_base_url(["spot", "v1", "private"], urls) == "https://api.bingx.com"
    end

    test "nested MEXC pattern — two-level navigation" do
      urls = %{
        "spot" => %{
          "private" => "https://api.mexc.com",
          "public" => "https://api.mexc.com"
        },
        "contract" => %{
          "private" => "https://api.mexc.com/api/v1/private"
        }
      }

      assert Dispatch.resolve_base_url(["spot", "private"], urls) == "https://api.mexc.com"
      assert Dispatch.resolve_base_url(["contract", "private"], urls) == "https://api.mexc.com/api/v1/private"
    end

    test "missing section with multiple distinct hosts does not ride a sibling" do
      urls = %{
        "public" => "https://api.example.com",
        "dapiPublic" => "https://dapi.example.com"
      }

      assert Dispatch.resolve_base_url(["sapi"], urls) == nil
      assert Dispatch.resolve_base_url(["unknown_section"], urls) == nil
    end

    test "missing section under nested map with a single unique host may share it" do
      # Nested leaves are the same host string → unique count 1 → safe shared fallback.
      urls = %{"public" => %{"spot" => "https://api.example.com"}}
      assert Dispatch.resolve_base_url(["unknown"], urls) == "https://api.example.com"
    end

    test "missing nested sub-section with multiple distinct hosts fails" do
      urls = %{
        "public" => %{"spot" => "https://api.example.com"},
        "private" => %{"futures" => "https://fx.example.com"}
      }

      assert Dispatch.resolve_base_url(["public", "futures"], urls) == nil
      assert Dispatch.resolve_base_url(["unknown"], urls) == nil
    end

    test "single unique URL (OKX rest key) is a safe shared-host fallback" do
      urls = %{"rest" => "https://www.okx.com"}
      assert Dispatch.resolve_base_url(["private"], urls) == "https://www.okx.com"
      assert Dispatch.resolve_base_url(["public"], urls) == "https://www.okx.com"
      assert Dispatch.resolve_base_url([], urls) == "https://www.okx.com"
    end

    test "flat same-host map allows fallback when section key is absent" do
      urls = %{
        "public" => "https://api.bybit.com",
        "private" => "https://api.bybit.com"
      }

      assert Dispatch.resolve_base_url(["spot"], urls) == "https://api.bybit.com"
    end

    test "empty base_urls — returns nil" do
      assert Dispatch.resolve_base_url(["public"], %{}) == nil
    end

    test "binance sandbox shape — sapi and eapiPublic are unresolvable" do
      # Real binance sandbox base_urls (no margin/options testnet hosts).
      urls = %{
        "dapiPrivate" => "https://testnet.binancefuture.com/dapi/v1",
        "dapiPublic" => "https://testnet.binancefuture.com/dapi/v1",
        "fapiPrivate" => "https://testnet.binancefuture.com/fapi/v1",
        "fapiPublic" => "https://testnet.binancefuture.com/fapi/v1",
        "private" => "https://testnet.binance.vision/api/v3",
        "public" => "https://testnet.binance.vision/api/v3"
      }

      assert Dispatch.resolve_base_url(["sapi"], urls) == nil
      assert Dispatch.resolve_base_url(["eapiPublic"], urls) == nil
      assert Dispatch.resolve_base_url(["public"], urls) == "https://testnet.binance.vision/api/v3"
      assert Dispatch.resolve_base_url(["fapiPublic"], urls) == "https://testnet.binancefuture.com/fapi/v1"
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-End: call/4
  # ---------------------------------------------------------------------------

  describe "call/4 params argument guard" do
    test "raises ArgumentError naming the expected shape on a keyword list" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})

      config = %{
        name: :public_get_v5_market_tickers,
        method: :get,
        path: "v5/market/tickers",
        sections: ["public"],
        weight: 5
      }

      assert_raise ArgumentError,
                   "expected raw endpoint arguments: (exchange, params_map, opts); " <>
                     "received a keyword list in the params position",
                   fn -> Dispatch.call(exchange, config, params: %{"category" => "spot"}) end
    end

    test "an empty list body is a valid [map()] params value, not misuse" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :public_post_batch,
        method: :post,
        path: "v5/batch",
        sections: ["public"],
        weight: 1
      }

      assert {:ok, %{status: 200}} = Dispatch.call(exchange, config, [], plug: {Req.Test, stub})
    end

    test "a list of maps is a valid params value, not misuse" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :public_post_batch,
        method: :post,
        path: "v5/batch",
        sections: ["public"],
        weight: 1
      }

      assert {:ok, %{status: 200}} =
               Dispatch.call(exchange, config, [%{"symbol" => "BTCUSDT"}], plug: {Req.Test, stub})
    end
  end

  describe "call/4 GET requests" do
    test "resolves URL and passes params as query string" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :public_get_v5_market_tickers,
        method: :get,
        path: "v5/market/tickers",
        sections: ["public"],
        weight: 5
      }

      assert {:ok, response} =
               Dispatch.call(exchange, config, %{"category" => "spot"}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.host == "api.test.com"
      assert conn.request_path == "/v5/market/tickers"
      assert conn.method == "GET"
      assert conn.query_string =~ "category=spot"

      assert response.status == 200
    end

    test "caller base_url overrides resolved public URL" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :public_get_v5_market_tickers,
        method: :get,
        path: "v5/market/tickers",
        sections: ["public"],
        weight: 5
      }

      assert {:ok, response} =
               Dispatch.call(exchange, config, %{"category" => "spot"},
                 base_url: "https://override.test.com",
                 plug: {Req.Test, stub}
               )

      conn = RequestCollector.one!(requests)
      assert conn.host == "override.test.com"
      assert conn.request_path == "/v5/market/tickers"

      assert response.status == 200
    end

    test "missing section base URL fails with exchange + section + environment" do
      # Binance sandbox: no sapi host; must not ride dapi/fapi.
      exchange =
        build_exchange(
          %{
            "dapiPublic" => "https://testnet.binancefuture.com/dapi/v1",
            "fapiPublic" => "https://testnet.binancefuture.com/fapi/v1",
            "public" => "https://testnet.binance.vision/api/v3"
          },
          id: "binance",
          sandbox: true
        )

      config = %{
        name: :sapi_get_margin_allpairs,
        method: :get,
        path: "margin/allPairs",
        sections: ["sapi"],
        weight: 1,
        authenticated: false
      }

      assert {:error, %Bourse.Error{} = error} = Dispatch.call(exchange, config, %{})
      assert error.type == :not_supported
      assert error.exchange == "binance"
      assert error.message =~ "sapi"
      assert error.message =~ "binance"
      assert error.message =~ "sandbox"
      refute error.message =~ "dapi"
    end

    test "missing section base URL names mainnet when not sandboxed" do
      # Multiple distinct hosts — section is load-bearing; missing sapi must not
      # share the public host.
      exchange =
        build_exchange(
          %{
            "public" => "https://api.binance.com",
            "fapiPublic" => "https://fapi.binance.com"
          },
          id: "binance",
          sandbox: false
        )

      config = %{
        name: :sapi_get_margin_allpairs,
        method: :get,
        path: "margin/allPairs",
        sections: ["sapi"],
        weight: 1
      }

      assert {:error, %Bourse.Error{} = error} = Dispatch.call(exchange, config, %{})
      assert error.type == :not_supported
      assert error.exchange == "binance"
      assert error.message =~ "mainnet"
    end

    test "nested Gate base URLs still resolve through call/4" do
      exchange =
        build_exchange(%{
          "public" => %{
            "spot" => "https://api.gateio.ws/api/v4"
          }
        })

      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{})
      end)

      config = %{
        name: :public_spot_get_tickers,
        method: :get,
        path: "tickers",
        sections: ["public", "spot"],
        weight: 1,
        url_prefix: "/spot/"
      }

      assert {:ok, %{status: 200}} =
               Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.host == "api.gateio.ws"
      assert String.ends_with?(conn.request_path, "/tickers")
    end

    test "BingX early-stop base URL still resolves through call/4" do
      exchange = build_exchange(%{"spot" => "https://api.bingx.com"})
      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{})
      end)

      config = %{
        name: :spot_v1_public_get_ticker,
        method: :get,
        path: "ticker",
        sections: ["spot", "v1", "public"],
        weight: 1
      }

      assert {:ok, %{status: 200}} =
               Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.host == "api.bingx.com"
    end

    test "authenticated missing section fails before signing (no wrong-host request)" do
      exchange =
        build_exchange(
          %{
            "dapiPublic" => "https://testnet.binancefuture.com/dapi/v1",
            "public" => "https://testnet.binance.vision/api/v3"
          },
          id: "binance",
          sandbox: true
        )

      config = %{
        name: :sapi_get_margin_allpairs,
        method: :get,
        path: "margin/allPairs",
        sections: ["sapi"],
        weight: 1,
        authenticated: true
      }

      # Base URL resolution fails before credentials/signing — no silent dapi ride.
      assert {:error, %Bourse.Error{type: :not_supported} = error} =
               Dispatch.call(exchange, config, %{})

      assert error.message =~ "No base URL for section sapi on binance (sandbox)"
    end

    test "interpolates path templates and removes consumed params from query" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :public_get_orders_id,
        method: :get,
        path: "orders/{id}",
        sections: ["public"],
        weight: 1
      }

      assert {:ok, _} =
               Dispatch.call(
                 exchange,
                 config,
                 %{"id" => "abc123", "symbol" => "BTC"},
                 plug: {Req.Test, stub}
               )

      conn = RequestCollector.one!(requests)
      assert conn.request_path == "/orders/abc123"
      # "id" should NOT appear in query string — it was consumed by interpolation
      refute conn.query_string =~ "id="
      assert conn.query_string =~ "symbol=BTC"
    end
  end

  describe "call/4 POST requests" do
    test "sends params as JSON body" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{"orderId" => "x"}})
      end)

      config = %{
        name: :public_post_v5_order_create,
        method: :post,
        path: "v5/order/create",
        sections: ["public"],
        weight: 1
      }

      assert {:ok, response} =
               Dispatch.call(
                 exchange,
                 config,
                 %{"symbol" => "BTCUSDT", "side" => "Buy"},
                 plug: {Req.Test, stub}
               )

      conn = RequestCollector.one!(requests)
      assert conn.request_path == "/v5/order/create"
      assert conn.method == "POST"
      decoded = RequestCollector.json_body!(requests)
      assert decoded["symbol"] == "BTCUSDT"
      assert decoded["side"] == "Buy"

      assert response.body["result"]["orderId"] == "x"
    end
  end

  describe "call/4 URL resolution integration" do
    test "uses nested URL for Gate-style sections" do
      exchange =
        build_exchange(%{
          "public" => %{
            "delivery" => "https://api.gateio.ws/api/v4",
            "spot" => "https://api.gateio.ws/api/v4"
          }
        })

      stub = unique_stub()
      stub_json(stub, %{"result" => "ok"})

      config = %{
        name: :public_delivery_get_settle_candlesticks,
        method: :get,
        path: "delivery/usdt/candlesticks",
        sections: ["public", "delivery"],
        weight: 1
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})
    end

    test "call with no params defaults to empty map" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0})
      end)

      config = %{
        name: :public_get_v5_market_time,
        method: :get,
        path: "v5/market/time",
        sections: ["public"],
        weight: 1
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.query_string == ""
    end
  end

  describe "call/4 url_prefix integration" do
    test "prepends url_prefix to path for public requests" do
      exchange = build_exchange(%{"public" => "https://www.okx.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"code" => "0"})
      end)

      config = %{
        name: :public_get_market_ticker,
        method: :get,
        path: "market/ticker",
        sections: ["public"],
        weight: 1,
        url_prefix: "/api/v5/"
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{"instId" => "BTC-USDT"}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.request_path == "/api/v5/market/ticker"
    end

    test "defaults to / when url_prefix not in endpoint config" do
      exchange = build_exchange(%{"public" => "https://api.bybit.com"})
      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"retCode" => 0})
      end)

      config = %{
        name: :public_get_v5_market_tickers,
        method: :get,
        path: "v5/market/tickers",
        sections: ["public"],
        weight: 1
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.request_path == "/v5/market/tickers"
    end

    test "prepends section prefix for nested sections (Gate pattern)" do
      exchange =
        build_exchange(%{
          "public" => %{
            "spot" => "https://api.gateio.ws/api/v4"
          }
        })

      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, [%{"currency_pair" => "BTC_USDT"}])
      end)

      config = %{
        name: :public_spot_get_tickers,
        method: :get,
        path: "tickers",
        sections: ["public", "spot"],
        weight: 1,
        url_prefix: "/spot/"
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      # base_url is https://api.gateio.ws/api/v4, prefix is /spot/, path is tickers
      # Full request path: /api/v4/spot/tickers
      conn = RequestCollector.one!(requests)
      assert conn.request_path == "/api/v4/spot/tickers"
    end
  end

  describe "call/4 error propagation" do
    test "propagates HTTP errors from exchange" do
      exchange =
        build_exchange(
          %{"public" => "https://api.test.com"},
          id: "err_test_#{System.unique_integer([:positive])}"
        )

      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "Rate limited"}))
      end)

      config = %{
        name: :public_get_test,
        method: :get,
        path: "test",
        sections: ["public"],
        weight: 1
      }

      assert {:error, error} =
               Dispatch.call(exchange, config, %{},
                 plug: {Req.Test, stub},
                 retry_delay: &zero_retry_delay/1
               )

      assert error.type == :rate_limit_exceeded
    end
  end

  # ---------------------------------------------------------------------------
  # Signed Requests (Private Endpoints)
  # ---------------------------------------------------------------------------

  describe "call/4 signed requests" do
    # Flat HMAC recipe for synthetic exchanges. Nested venue recipes (Bybit
    # section keys) would pick the wrong branch on these fake paths.
    @header_sign_recipe %{
      "auth_headers" => [
        %{"name" => "X-BAPI-API-KEY", "source" => "api_key"},
        %{"name" => "X-BAPI-TIMESTAMP", "source" => "timestamp"},
        %{"name" => "X-BAPI-RECV-WINDOW", "source" => "recv_window"}
      ],
      "canonical_string" => %{
        "*" => %{
          "components" => [
            %{"source" => "timestamp"},
            %{"source" => "api_key"},
            %{"source" => "recv_window"},
            %{"source" => "body"}
          ]
        }
      },
      "crypto_op" => %{"algo" => "hmac_sha256"},
      "pre_sign_transforms" => [
        %{"op" => "json_encode", "target" => "body"},
        %{"op" => "hex_encode", "target" => "signature"}
      ],
      "signature_placement" => %{"key" => "X-BAPI-SIGN", "location" => "header"},
      "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
    }

    @query_sign_recipe %{
      "auth_headers" => [%{"name" => "X-MBX-APIKEY", "source" => "api_key"}],
      "canonical_string" => %{"*" => %{"components" => [%{"source" => "query"}]}},
      "crypto_op" => %{"algo" => "hmac_sha256"},
      "pre_sign_transforms" => [%{"op" => "hex_encode", "target" => "signature"}],
      "signature_placement" => %{"key" => "signature", "location" => "query"},
      "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
    }

    @iso_sign_recipe %{
      "auth_headers" => [
        %{"name" => "OK-ACCESS-KEY", "source" => "api_key"},
        %{"name" => "OK-ACCESS-PASSPHRASE", "source" => "passphrase"},
        %{"name" => "OK-ACCESS-TIMESTAMP", "source" => "timestamp"}
      ],
      "canonical_string" => %{
        "*" => %{
          "components" => [
            %{"source" => "timestamp"},
            %{"source" => "method"},
            %{"source" => "path"}
          ]
        }
      },
      "crypto_op" => %{"algo" => "hmac_sha256"},
      "pre_sign_transforms" => [
        %{"op" => "base64_encode", "target" => "signature"}
      ],
      "signature_placement" => %{"key" => "OK-ACCESS-SIGN", "location" => "header"},
      "timestamp" => %{"format" => "iso8601", "source" => "timestamp_ms"}
    }

    @bybit_signing_config %{
      api_key_header: "X-BAPI-API-KEY",
      timestamp_header: "X-BAPI-TIMESTAMP",
      signature_header: "X-BAPI-SIGN",
      recv_window_header: "X-BAPI-RECV-WINDOW",
      sign_recipe: @header_sign_recipe
    }

    defp build_signed_exchange(base_urls, opts \\ []) do
      exchange_id = Keyword.get(opts, :id, "signed_test_#{System.unique_integer([:positive])}")
      pattern = Keyword.get(opts, :signing_pattern, :hmac_sha256_headers)

      credentials =
        Keyword.get(opts, :credentials, %Bourse.Credentials{
          api_key: "test_api_key",
          secret: "test_secret_key"
        })

      %Exchange{
        id: exchange_id,
        name: "Test Signed Exchange",
        credentials: credentials,
        sandbox: false,
        rate_limit_ms: 100,
        hostname: Keyword.get(opts, :hostname),
        base_urls: base_urls,
        has: %{},
        required_credentials: %{},
        signing_pattern: pattern,
        signing_config: opts |> Keyword.get(:signing_config, @bybit_signing_config) |> ensure_hmac_recipe(pattern),
        options: %{},
        error_codes: %{},
        broad_error_patterns: %{},
        http_exceptions: %{},
        spec: %{}
      }
    end

    defp ensure_hmac_recipe(%{sign_recipe: recipe} = config, _pattern) when is_map(recipe), do: config
    defp ensure_hmac_recipe(config, :hmac_sha256_headers), do: Map.put(config, :sign_recipe, header_recipe(config))
    defp ensure_hmac_recipe(config, :hmac_sha256_query), do: Map.put(config, :sign_recipe, @query_sign_recipe)
    defp ensure_hmac_recipe(config, :hmac_sha256_iso_passphrase), do: Map.put(config, :sign_recipe, @iso_sign_recipe)
    defp ensure_hmac_recipe(config, _pattern), do: config

    defp header_recipe(config) do
      api_key_header = Map.get(config, :api_key_header, "X-BAPI-API-KEY")
      timestamp_header = Map.get(config, :timestamp_header, "X-BAPI-TIMESTAMP")
      signature_header = Map.get(config, :signature_header, "X-BAPI-SIGN")

      %{
        "auth_headers" => [
          %{"name" => api_key_header, "source" => "api_key"},
          %{"name" => timestamp_header, "source" => "timestamp"}
        ],
        "canonical_string" => %{
          "*" => %{"components" => [%{"source" => "timestamp"}, %{"source" => "method"}, %{"source" => "path"}]}
        },
        "crypto_op" => %{"algo" => "hmac_sha256"},
        "pre_sign_transforms" => [
          %{"op" => "json_encode", "target" => "body"},
          %{"op" => "hex_encode", "target" => "signature"}
        ],
        "signature_placement" => %{"key" => signature_header, "location" => "header"},
        "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
      }
    end

    test "threads the exact authored section into Binance dust signing" do
      credentials = %Bourse.Credentials{api_key: "test_api_key", secret: "test_secret_key"}
      exchange = Exchange.new!("binance", credentials: credentials)
      endpoint = Enum.find(Bourse.Binance.__endpoints__(), &(&1.name == :sapi_post_asset_dust))
      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{})
      end)

      assert {:ok, _response} =
               Dispatch.call(exchange, endpoint, %{"asset" => ["BTC", "USDT"]},
                 plug: {Req.Test, stub},
                 timestamp_ms_override: 1_700_000_000_000
               )

      conn = RequestCollector.one!(requests)
      [unsigned_query, signature] = String.split(conn.query_string, "&signature=", parts: 2)

      assert String.contains?(unsigned_query, "asset=BTC%2CUSDT")
      assert URI.decode_query(unsigned_query)["asset"] == "BTC,USDT"
      assert signature == unsigned_query |> Signing.hmac_sha256(credentials.secret) |> Signing.encode_hex()
    end

    test "re-signs a Binance query request after an injected 408" do
      credentials = %Bourse.Credentials{api_key: "test_api_key", secret: "test_secret_key"}
      exchange = Exchange.new!("binance", credentials: credentials)
      endpoint = Enum.find(Bourse.Binance.__endpoints__(), &(&1.name == :private_get_account))
      timestamp = value_sequence([@first_retry_timestamp_ms, @second_retry_timestamp_ms])
      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)

        if length(RequestCollector.requests(requests)) == 1 do
          conn
          |> Plug.Conn.put_status(@request_timeout_status)
          |> Req.Test.json(%{"msg" => "upstream request timed out"})
        else
          Req.Test.json(conn, %{})
        end
      end)

      assert {:ok, _response} =
               Dispatch.call(exchange, endpoint, %{},
                 plug: {Req.Test, stub},
                 max_retries: 1,
                 retry_delay: &zero_retry_delay/1,
                 timestamp_ms_override: timestamp
               )

      [first, second] = RequestCollector.requests(requests)
      [first_payload, first_signature] = String.split(first.conn.query_string, "&signature=", parts: 2)
      [second_payload, second_signature] = String.split(second.conn.query_string, "&signature=", parts: 2)

      assert URI.decode_query(first_payload)["timestamp"] == Integer.to_string(@first_retry_timestamp_ms)
      assert URI.decode_query(second_payload)["timestamp"] == Integer.to_string(@second_retry_timestamp_ms)
      refute first_signature == second_signature

      assert first_signature ==
               first_payload |> Signing.hmac_sha256(credentials.secret) |> Signing.encode_hex()

      assert second_signature ==
               second_payload |> Signing.hmac_sha256(credentials.secret) |> Signing.encode_hex()
    end

    test "re-signs a Deribit nonce request after an injected 408" do
      credentials = %Bourse.Credentials{api_key: "test_api_key", secret: "test_secret_key"}
      exchange = Exchange.new!("deribit", credentials: credentials)

      endpoint =
        Enum.find(Bourse.Deribit.__endpoints__(), &(&1.name == :private_get_get_account_summaries))

      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)

        if length(RequestCollector.requests(requests)) == 1 do
          conn
          |> Plug.Conn.put_status(@request_timeout_status)
          |> Req.Test.json(%{"error" => %{"code" => 10_000, "message" => "upstream request timed out"}})
        else
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => %{}})
        end
      end)

      assert {:ok, _response} =
               Dispatch.call(exchange, endpoint, %{},
                 plug: {Req.Test, stub},
                 max_retries: 1,
                 retry_delay: &zero_retry_delay/1,
                 timestamp_ms_override: @first_retry_timestamp_ms
               )

      [first, second] = RequestCollector.requests(requests)
      first_auth = deribit_auth(first.conn)
      second_auth = deribit_auth(second.conn)

      refute first_auth.nonce == second_auth.nonce
      refute first_auth.signature == second_auth.signature
      assert first_auth.signature == expected_deribit_signature(first.conn, first_auth, credentials.secret)
      assert second_auth.signature == expected_deribit_signature(second.conn, second_auth, credentials.secret)
    end

    test "returns the injected 408 after signed retries are exhausted" do
      credentials = %Bourse.Credentials{api_key: "test_api_key", secret: "test_secret_key"}
      exchange = Exchange.new!("binance", credentials: credentials)
      endpoint = Enum.find(Bourse.Binance.__endpoints__(), &(&1.name == :private_get_account))
      timestamp = value_sequence([@first_retry_timestamp_ms, @second_retry_timestamp_ms])
      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)

        conn
        |> Plug.Conn.put_status(@request_timeout_status)
        |> Req.Test.json(%{"msg" => "upstream request timed out"})
      end)

      assert {:error,
              %Bourse.Error{
                type: :network_error,
                http_status: @request_timeout_status,
                message: "upstream request timed out"
              }} =
               Dispatch.call(exchange, endpoint, %{},
                 plug: {Req.Test, stub},
                 max_retries: 1,
                 retry_delay: &zero_retry_delay/1,
                 timestamp_ms_override: timestamp
               )

      assert length(RequestCollector.requests(requests)) == 2
    end

    defp host_signing_config(hostname) do
      %{
        hostname: hostname,
        sign_recipe: %{
          "auth_headers" => [],
          "canonical_string" => %{
            "*" => %{
              "components" => [
                %{"source" => "method"},
                %{"source" => "literal", "value" => "\n"},
                %{"source" => "hostname"},
                %{"source" => "literal", "value" => "\n"},
                %{"source" => "path"},
                %{"source" => "literal", "value" => "\n"},
                %{"encoder" => "urlencode", "key_order" => "sorted", "source" => "query"}
              ]
            }
          },
          "crypto_op" => %{"algo" => "hmac_sha256", "key_encoding" => "utf8"},
          "pre_sign_transforms" => [%{"op" => "base64_encode", "target" => "signature"}],
          "signature_placement" => %{"key" => "Signature", "location" => "query"}
        }
      }
    end

    defp auth_params(timestamp) do
      %{
        "AccessKeyId" => "test_api_key",
        "SignatureMethod" => "HmacSHA256",
        "SignatureVersion" => "2",
        "Timestamp" => timestamp
      }
    end

    defp host_signature(hostname, path, timestamp) do
      payload =
        Enum.join(
          [
            "GET",
            String.downcase(hostname),
            path,
            URI.encode_query(Enum.sort_by(auth_params(timestamp), fn {key, _value} -> key end))
          ],
          "\n"
        )

      payload
      |> Signing.hmac_sha256("test_secret_key")
      |> Signing.encode_base64()
    end

    test "returns authentication_error when credentials are nil" do
      exchange = build_signed_exchange(%{"private" => "https://api.test.com"}, credentials: nil)

      config = %{
        name: :private_get_account,
        method: :get,
        path: "v5/account/wallet-balance",
        sections: ["private"],
        weight: 1,
        authenticated: true
      }

      assert {:error, error} = Dispatch.call(exchange, config, %{})
      assert error.type == :authentication_error
      assert error.message =~ "Credentials required"
    end

    test "returns authentication_error when signing_pattern is nil" do
      exchange =
        build_signed_exchange(%{"private" => "https://api.test.com"}, signing_pattern: nil)

      config = %{
        name: :private_get_account,
        method: :get,
        path: "v5/account/wallet-balance",
        sections: ["private"],
        weight: 1,
        authenticated: true
      }

      assert {:error, error} = Dispatch.call(exchange, config, %{})
      assert error.type == :authentication_error
      assert error.message =~ "signing pattern"
    end

    test "signed GET includes auth headers" do
      exchange = build_signed_exchange(%{"private" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{"balance" => "100"}})
      end)

      config = %{
        name: :private_get_account,
        method: :get,
        path: "v5/account/wallet-balance",
        sections: ["private"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, response} =
               Dispatch.call(exchange, config, %{"accountType" => "UNIFIED"}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.host == "api.test.com"

      # Verify signing headers are present
      api_key = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      timestamp = Plug.Conn.get_req_header(conn, "x-bapi-timestamp")
      signature = Plug.Conn.get_req_header(conn, "x-bapi-sign")

      assert api_key == ["test_api_key"]
      assert [ts] = timestamp
      assert String.length(ts) == 13
      assert [sig] = signature
      assert String.length(sig) == 64
      assert Regex.match?(~r/^[0-9a-f]+$/, sig)

      assert response.body["result"]["balance"] == "100"
    end

    test "caller base_url overrides resolved signed URL" do
      exchange = build_signed_exchange(%{"private" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{"balance" => "100"}})
      end)

      config = %{
        name: :private_get_account,
        method: :get,
        path: "v5/account/wallet-balance",
        sections: ["private"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, response} =
               Dispatch.call(exchange, config, %{"accountType" => "UNIFIED"},
                 base_url: "https://demo.test.com",
                 plug: {Req.Test, stub}
               )

      conn = RequestCollector.one!(requests)
      assert conn.host == "demo.test.com"
      assert conn.request_path == "/v5/account/wallet-balance"
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-sign")

      assert response.body["result"]["balance"] == "100"
    end

    test "host-signing recipe uses caller base_url host in signature" do
      exchange =
        build_signed_exchange(%{"private" => "https://api.test.com"},
          hostname: "api.test.com",
          signing_pattern: :hmac_sha256_query,
          signing_config: host_signing_config("api.test.com")
        )

      stub = unique_stub()
      timestamp_ms = 1_700_000_000_000
      timestamp = "2023-11-14T22:13:20"

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"status" => "ok", "data" => []})
      end)

      config = %{
        name: :private_get_account_accounts,
        method: :get,
        path: "account/accounts",
        sections: ["private"],
        url_prefix: "/v1/",
        weight: 1,
        authenticated: true
      }

      assert {:ok, response} =
               Dispatch.call(exchange, config, auth_params(timestamp),
                 base_url: "https://override.test.com",
                 plug: {Req.Test, stub},
                 timestamp_ms_override: timestamp_ms
               )

      conn = RequestCollector.one!(requests)
      query = URI.decode_query(conn.query_string)
      expected = host_signature("override.test.com", "/v1/account/accounts", timestamp)
      struct_host = host_signature("api.test.com", "/v1/account/accounts", timestamp)

      assert conn.host == "override.test.com"
      assert query["Signature"] == expected
      refute query["Signature"] == struct_host

      assert response.body["status"] == "ok"
    end

    test "host-signing recipe uses resolved base_url host without caller override" do
      exchange =
        build_signed_exchange(%{"private" => "https://api.test.com"},
          hostname: "api.test.com",
          signing_pattern: :hmac_sha256_query,
          signing_config: host_signing_config("api.test.com")
        )

      stub = unique_stub()
      timestamp_ms = 1_700_000_000_000
      timestamp = "2023-11-14T22:13:20"

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"status" => "ok", "data" => []})
      end)

      config = %{
        name: :private_get_account_accounts,
        method: :get,
        path: "account/accounts",
        sections: ["private"],
        url_prefix: "/v1/",
        weight: 1,
        authenticated: true
      }

      assert {:ok, response} =
               Dispatch.call(exchange, config, auth_params(timestamp),
                 plug: {Req.Test, stub},
                 timestamp_ms_override: timestamp_ms
               )

      conn = RequestCollector.one!(requests)
      query = URI.decode_query(conn.query_string)

      assert conn.host == "api.test.com"
      assert query["Signature"] == host_signature("api.test.com", "/v1/account/accounts", timestamp)

      assert response.body["status"] == "ok"
    end

    test "host-signing recipe uses per-section resolved base_url host" do
      exchange =
        build_signed_exchange(%{"contract" => %{"private" => "https://api.hbdm.vn"}},
          hostname: "api.huobi.pro",
          signing_pattern: :hmac_sha256_query,
          signing_config: host_signing_config("api.huobi.pro")
        )

      stub = unique_stub()
      timestamp_ms = 1_700_000_000_000
      timestamp = "2023-11-14T22:13:20"

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"status" => "ok", "data" => []})
      end)

      config = %{
        name: :contract_private_get_api_v1_contract_sub_auth_list,
        method: :get,
        path: "api/v1/contract_sub_auth_list",
        sections: ["contract", "private"],
        url_prefix: "/",
        weight: 1,
        authenticated: true
      }

      assert {:ok, response} =
               Dispatch.call(exchange, config, auth_params(timestamp),
                 plug: {Req.Test, stub},
                 timestamp_ms_override: timestamp_ms
               )

      conn = RequestCollector.one!(requests)
      query = URI.decode_query(conn.query_string)

      assert conn.host == "api.hbdm.vn"
      assert query["Signature"] == host_signature("api.hbdm.vn", "/api/v1/contract_sub_auth_list", timestamp)
      refute query["Signature"] == host_signature("api.huobi.pro", "/api/v1/contract_sub_auth_list", timestamp)

      assert response.body["status"] == "ok"
    end

    test "signed POST sends JSON body with auth headers" do
      exchange = build_signed_exchange(%{"private" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{"orderId" => "123"}})
      end)

      config = %{
        name: :private_post_order,
        method: :post,
        path: "v5/order/create",
        sections: ["private"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, response} =
               Dispatch.call(
                 exchange,
                 config,
                 %{"symbol" => "BTCUSDT", "side" => "Buy"},
                 plug: {Req.Test, stub}
               )

      conn = RequestCollector.one!(requests)

      # Verify auth headers
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-sign")

      # Verify body is JSON-encoded
      decoded = RequestCollector.json_body!(requests)
      assert decoded["symbol"] == "BTCUSDT"
      assert decoded["side"] == "Buy"

      assert response.body["result"]["orderId"] == "123"
    end

    test "signed JSON-body POST signs and sends an empty JSON object" do
      exchange = build_signed_exchange(%{"private" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :private_post_get_time,
        method: :post,
        path: "private/get_time",
        sections: ["private"],
        weight: 1,
        authenticated: true,
        body_encoding: "json"
      }

      assert {:ok, _} =
               Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      %{conn: conn, body: body} = RequestCollector.one_request!(requests)
      assert body == "{}"

      [signature] = Plug.Conn.get_req_header(conn, "x-bapi-sign")
      [timestamp] = Plug.Conn.get_req_header(conn, "x-bapi-timestamp")
      [recv_window] = Plug.Conn.get_req_header(conn, "x-bapi-recv-window")

      expected_signature =
        "#{timestamp}test_api_key#{recv_window}{}"
        |> Signing.hmac_sha256("test_secret_key")
        |> Signing.encode_hex()

      assert signature == expected_signature
    end

    test "exchange sandbox selects Hyperliquid's testnet phantom source" do
      private_key = "0x0123456789012345678901234567890123456789012345678901234567890123"
      credentials = %Bourse.Credentials{api_key: "0xwallet", secret: private_key, sandbox: false}
      exchange = Exchange.new!("hyperliquid", credentials: credentials, sandbox: true)
      nonce = 1_700_000_000_000
      action = %{"type" => "cancel", "cancels" => [%{"a" => 0, "o" => 1}]}

      request = %{method: :post, path: "exchange", body: nil, params: %{action: action, nonce: nonce}}
      expected_testnet = request |> Hyperliquid.sign(credentials, %{testnet: true}) |> decode_signature()
      expected_mainnet = request |> Hyperliquid.sign(credentials, %{testnet: false}) |> decode_signature()
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      config = %{
        name: :private_post_exchange,
        method: :post,
        path: "exchange",
        sections: ["private"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, _response} =
               Dispatch.call(exchange, config, %{action: action, nonce: nonce}, plug: {Req.Test, stub})

      assert RequestCollector.json_body!(requests)["signature"] == expected_testnet

      refute expected_testnet == expected_mainnet
    end

    test "public endpoint stays unsigned even with credentialed exchange" do
      exchange = build_signed_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :public_get_tickers,
        method: :get,
        path: "v5/market/tickers",
        sections: ["public"],
        weight: 5
      }

      assert {:ok, _} =
               Dispatch.call(exchange, config, %{"category" => "spot"}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      # Public endpoint should NOT have signing headers
      assert [] == Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert [] == Plug.Conn.get_req_header(conn, "x-bapi-sign")
    end

    test "suffix-private sections are signed (Binance fapiPrivate)" do
      exchange =
        build_signed_exchange(%{
          "fapiPrivate" => "https://fapi.binance.com/fapi/v1"
        })

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :fapi_private_get_account,
        method: :get,
        path: "fapi/v1/account",
        sections: ["fapiPrivate"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-sign")
    end

    test "prefix-private sections are signed (GRVT privateTrading)" do
      exchange =
        build_signed_exchange(%{
          "privateTrading" => "https://api.grvt.io/full/v1"
        })

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :private_trading_get_positions,
        method: :get,
        path: "full/v1/positions",
        sections: ["privateTrading"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-sign")
    end

    test "v2Private sections are signed (HTX pattern)" do
      exchange =
        build_signed_exchange(%{
          "v2Private" => "https://api.huobi.pro/v2"
        })

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :v2_private_get_account,
        method: :get,
        path: "v2/account/overview",
        sections: ["v2Private"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-sign")
    end

    test "signed request prepends url_prefix to path (OKX private pattern)" do
      exchange =
        build_signed_exchange(%{
          "private" => "https://www.okx.com"
        })

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"code" => "0", "data" => [%{"totalEq" => "1000"}]})
      end)

      config = %{
        name: :private_get_account_balance,
        method: :get,
        path: "account/balance",
        sections: ["private"],
        weight: 1,
        url_prefix: "/api/v5/",
        authenticated: true
      }

      assert {:ok, response} =
               Dispatch.call(exchange, config, %{"ccy" => "BTC"}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      # The url_prefix /api/v5/ must be prepended to the endpoint path
      assert conn.request_path == "/api/v5/account/balance"

      # Verify signing headers are still present
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-sign")

      assert response.body["data"] |> hd() |> Map.get("totalEq") == "1000"
    end

    test "formats private timestamps in dispatch from the v4 sign recipe" do
      timestamp_ms = 1_700_000_000_123

      exchange =
        Exchange.new!("okx",
          api_key: "test_api_key",
          secret: "test_secret_key",
          password: "test_passphrase"
        )

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"code" => "0", "data" => [%{}]})
      end)

      config = Enum.find(Bourse.Okx.__endpoints__(), &(&1.name == :private_get_account_balance))

      assert {:ok, _response} =
               Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub}, timestamp_ms_override: timestamp_ms)

      conn = RequestCollector.one!(requests)
      assert Plug.Conn.get_req_header(conn, "ok-access-timestamp") == ["2023-11-14T22:13:20.123Z"]
    end

    test "threads deterministic timestamp and nonce overrides to direct signers" do
      timestamp_ms = 1_700_000_000_123
      nonce = 987_654

      exchange =
        Exchange.new!("deribit",
          api_key: "test_api_key",
          secret: "test_secret_key"
        )

      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => %{}})
      end)

      config = Enum.find(Bourse.Deribit.__endpoints__(), &(&1.name == :private_get_get_account_summaries))

      assert {:ok, _response} =
               Dispatch.call(exchange, config, %{},
                 plug: {Req.Test, stub},
                 timestamp_ms_override: timestamp_ms,
                 nonce_override: nonce
               )

      conn = RequestCollector.one!(requests)
      assert [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      assert authorization =~ "ts=#{timestamp_ms}"
      assert authorization =~ "nonce=#{nonce}"
    end

    test "formats seconds timestamps in dispatch from the requested v4 sign recipe shape" do
      timestamp_ms = 1_700_000_000_123

      exchange =
        build_signed_exchange(%{"private" => "https://api.test.com"},
          signing_pattern: :hmac_sha256_headers,
          signing_config: %{
            api_key_header: "KEY",
            signature_header: "SIGN",
            timestamp_header: "Timestamp"
          }
        )

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"result" => %{}})
      end)

      config = %{
        name: :private_get_spot_accounts,
        method: :get,
        path: "spot/accounts",
        sections: ["private"],
        weight: 1,
        authenticated: true,
        timestamp_recipe: %{"source" => "timestamp_ms", "format" => "seconds"}
      }

      assert {:ok, _response} =
               Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub}, timestamp_ms_override: timestamp_ms)

      conn = RequestCollector.one!(requests)
      assert Plug.Conn.get_req_header(conn, "timestamp") == ["1700000000"]
    end

    test "uses request contract resolved during exchange construction without reloading spec per call" do
      timestamp_ms = 1_700_000_000_123

      exchange =
        %{
          build_signed_exchange(%{"private" => "https://api.test.com"},
            id: "synthetic_contract",
            signing_pattern: :hmac_sha256_iso_passphrase,
            signing_config: %{
              api_key_header: "OK-ACCESS-KEY",
              timestamp_header: "OK-ACCESS-TIMESTAMP",
              signature_header: "OK-ACCESS-SIGN",
              passphrase_header: "OK-ACCESS-PASSPHRASE"
            }
          )
          | request_contracts: %{
              {["private"], :get, "account/balance"} => %{
                timestamp_recipe: %{"source" => "timestamp_ms", "format" => "iso8601"}
              }
            }
        }

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"code" => "0", "data" => [%{}]})
      end)

      config = %{
        name: :private_get_account_balance,
        method: :get,
        path: "account/balance",
        sections: ["private"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, _response} =
               Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub}, timestamp_ms_override: timestamp_ms)

      conn = RequestCollector.one!(requests)
      assert Plug.Conn.get_req_header(conn, "ok-access-timestamp") == ["2023-11-14T22:13:20.123Z"]
    end

    test "removes inferred content-type when v4 request contract has none" do
      exchange =
        build_signed_exchange(%{
          "private" => "https://api.test.com"
        })

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :private_get_account,
        method: :get,
        path: "v5/account/wallet-balance",
        sections: ["private"],
        weight: 1,
        authenticated: true,
        body_encoding: "none",
        content_type: nil
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert Plug.Conn.get_req_header(conn, "content-type") == []
    end

    test "nested sections with 'private' are signed (Gate-style)" do
      exchange =
        build_signed_exchange(%{
          "private" => %{"futures" => "https://api.gateio.ws/api/v4"}
        })

      stub = unique_stub()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0, "result" => %{}})
      end)

      config = %{
        name: :private_futures_get_orders,
        method: :get,
        path: "futures/orders",
        sections: ["private", "futures"],
        weight: 1,
        authenticated: true
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      # Verify signing headers are present
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-api-key")
      assert [_] = Plug.Conn.get_req_header(conn, "x-bapi-sign")
    end
  end

  defp decode_signature(signed_request) do
    signed_request.body |> Jason.decode!() |> Map.fetch!("signature")
  end

  describe "call/4 response_transformer wiring" do
    test "passes endpoint rate limit metadata through to HTTP bucket accounting" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      config = %{
        name: :public_get_weighted,
        method: :get,
        path: "weighted",
        sections: ["public"],
        weight: 1,
        rate_limit: %{axes: ["uid"], cost: 4}
      }

      assert {:ok, _} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})
      assert Bourse.RateLimiter.get_cost({exchange.id, :public, "uid"}, 60_000) == 4
    end

    test "applies the configured transformer to the response body before returning" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      # BitMEX-style flat order list returned by the exchange
      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, [
          %{"side" => "Sell", "price" => 100.5, "size" => 10},
          %{"side" => "Buy", "price" => 99.5, "size" => 20}
        ])
      end)

      config = %{
        name: :public_get_order_book,
        method: :get,
        path: "orderBook/L2",
        sections: ["public"],
        weight: 1,
        response_transformer: :order_book_from_flat_list
      }

      assert {:ok, response} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})

      assert response.body == %{
               "bids" => [[99.5, 20]],
               "asks" => [[100.5, 10]]
             }
    end

    test "leaves the body untouched when no transformer is configured" do
      exchange = build_exchange(%{"public" => "https://api.test.com"})
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, [%{"side" => "Buy", "price" => 1, "size" => 1}])
      end)

      config = %{
        name: :public_get_order_book,
        method: :get,
        path: "orderBook/L2",
        sections: ["public"],
        weight: 1
      }

      assert {:ok, response} = Dispatch.call(exchange, config, %{}, plug: {Req.Test, stub})
      assert response.body == [%{"side" => "Buy", "price" => 1, "size" => 1}]
    end

    test "raw callers receive the response envelope without unified field parsing" do
      raw_ticker = %{"lastPrice" => "65000.00", "bid1Price" => "64999.00"}
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, raw_ticker)
      end)

      {:ok, exchange} = Exchange.new("bybit")
      config = hd(Bourse.Bybit.__unified_endpoint__(:fetch_ticker))

      assert {:ok, response} =
               Dispatch.call(exchange, config, %{"symbol" => "BTCUSDT"}, plug: {Req.Test, stub})

      assert response.body == raw_ticker
      refute match?(%Bourse.Ticker{}, response.body)
    end
  end
end
