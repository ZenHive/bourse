defmodule Bourse.Signing.HmacSha256HeadersTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing.HmacSha256Headers

  @credentials %Bourse.Credentials{api_key: "bybit_key", secret: "bybit_secret"}

  @config %{
    api_key_header: "X-BAPI-API-KEY",
    timestamp_header: "X-BAPI-TIMESTAMP",
    signature_header: "X-BAPI-SIGN",
    recv_window_header: "X-BAPI-RECV-WINDOW"
  }

  describe "sign/3" do
    test "GET request puts params in query string" do
      request = %{method: :get, path: "/v5/market/tickers", body: nil, params: %{"category" => "spot"}}

      result = HmacSha256Headers.sign(request, @credentials, @config)

      assert result.url == "/v5/market/tickers?category=spot"
      assert result.body == nil
    end

    test "POST request puts params in JSON body" do
      request = %{
        method: :post,
        path: "/v5/order/create",
        body: nil,
        params: %{"symbol" => "BTCUSDT", "side" => "Buy"}
      }

      result = HmacSha256Headers.sign(request, @credentials, @config)

      assert result.url == "/v5/order/create"
      decoded = Jason.decode!(result.body)
      assert decoded["symbol"] == "BTCUSDT"
      assert decoded["side"] == "Buy"
    end

    test "POST with pre-built body uses it directly" do
      body = Jason.encode!(%{"symbol" => "BTCUSDT"})

      request = %{method: :post, path: "/v5/order/create", body: body, params: %{}}

      result = HmacSha256Headers.sign(request, @credentials, @config)

      assert result.body == body
    end

    test "includes all required auth headers" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = HmacSha256Headers.sign(request, @credentials, @config)

      header_names = Enum.map(result.headers, &elem(&1, 0))
      assert "X-BAPI-API-KEY" in header_names
      assert "X-BAPI-TIMESTAMP" in header_names
      assert "X-BAPI-SIGN" in header_names
      assert "X-BAPI-RECV-WINDOW" in header_names
    end

    test "API key header has correct value" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = HmacSha256Headers.sign(request, @credentials, @config)

      assert {"X-BAPI-API-KEY", "bybit_key"} in result.headers
    end

    test "signature is hex-encoded by default" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = HmacSha256Headers.sign(request, @credentials, @config)

      {_, sig} = Enum.find(result.headers, fn {k, _} -> k == "X-BAPI-SIGN" end)
      assert String.match?(sig, ~r/^[0-9a-f]{64}$/)
    end

    test "base64 signature encoding" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = Map.put(@config, :signature_encoding, :base64)

      result = HmacSha256Headers.sign(request, @credentials, config)

      {_, sig} = Enum.find(result.headers, fn {k, _} -> k == "X-BAPI-SIGN" end)
      assert {:ok, _} = Base.decode64(sig)
    end

    test "recv_window header omitted when not configured" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = Map.delete(@config, :recv_window_header)

      result = HmacSha256Headers.sign(request, @credentials, config)

      header_names = Enum.map(result.headers, &elem(&1, 0))
      refute "X-BAPI-RECV-WINDOW" in header_names
    end

    test "GET with empty params produces clean URL" do
      request = %{method: :get, path: "/v5/account/info", body: nil, params: %{}}

      result = HmacSha256Headers.sign(request, @credentials, @config)

      assert result.url == "/v5/account/info"
    end

    test "DELETE works like GET" do
      request = %{method: :delete, path: "/v5/order", body: nil, params: %{"orderId" => "123"}}

      result = HmacSha256Headers.sign(request, @credentials, @config)

      assert String.contains?(result.url, "orderId=123")
      assert result.body == nil
    end
  end
end
