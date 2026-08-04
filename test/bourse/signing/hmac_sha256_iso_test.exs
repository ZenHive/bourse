defmodule Bourse.Signing.HmacSha256IsoTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing.HmacSha256Iso

  @credentials %Bourse.Credentials{
    api_key: "okx_key",
    secret: "okx_secret",
    password: "okx_passphrase"
  }

  @config %{
    api_key_header: "OK-ACCESS-KEY",
    timestamp_header: "OK-ACCESS-TIMESTAMP",
    signature_header: "OK-ACCESS-SIGN",
    passphrase_header: "OK-ACCESS-PASSPHRASE"
  }

  describe "sign/3" do
    test "includes passphrase header" do
      request = %{method: :get, path: "/api/v5/account/balance", body: nil, params: %{}}

      result = HmacSha256Iso.sign(request, @credentials, @config)

      assert {"OK-ACCESS-PASSPHRASE", "okx_passphrase"} in result.headers
    end

    test "passphrase defaults to empty string when nil" do
      creds = %{@credentials | password: nil}
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = HmacSha256Iso.sign(request, creds, @config)

      assert {"OK-ACCESS-PASSPHRASE", ""} in result.headers
    end

    test "timestamp is ISO8601 format" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = HmacSha256Iso.sign(request, @credentials, @config)

      {_, ts} = Enum.find(result.headers, fn {k, _} -> k == "OK-ACCESS-TIMESTAMP" end)
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(ts)
    end

    test "uses preformatted timestamp from signing config" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = Map.put(@config, :timestamp, "2023-11-14T22:13:20.123Z")

      result = HmacSha256Iso.sign(request, @credentials, config)

      assert {"OK-ACCESS-TIMESTAMP", "2023-11-14T22:13:20.123Z"} in result.headers
    end

    test "signature defaults to base64 encoding" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = HmacSha256Iso.sign(request, @credentials, @config)

      {_, sig} = Enum.find(result.headers, fn {k, _} -> k == "OK-ACCESS-SIGN" end)
      assert {:ok, decoded} = Base.decode64(sig)
      # SHA256 produces 32 bytes
      assert byte_size(decoded) == 32
    end

    test "supports hex signature encoding" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = Map.put(@config, :signature_encoding, :hex)

      result = HmacSha256Iso.sign(request, @credentials, config)

      {_, signature} = Enum.find(result.headers, fn {key, _value} -> key == "OK-ACCESS-SIGN" end)
      assert {:ok, _decoded} = Base.decode16(signature, case: :lower)
    end

    test "GET with params includes query in URL and payload" do
      request = %{method: :get, path: "/api/v5/market/tickers", body: nil, params: %{"instId" => "BTC-USDT"}}

      result = HmacSha256Iso.sign(request, @credentials, @config)

      assert result.url == "/api/v5/market/tickers?instId=BTC-USDT"
      assert result.body == nil
    end

    test "POST with params creates JSON body" do
      request = %{
        method: :post,
        path: "/api/v5/trade/order",
        body: nil,
        params: %{"instId" => "BTC-USDT", "side" => "buy"}
      }

      result = HmacSha256Iso.sign(request, @credentials, @config)

      assert result.url == "/api/v5/trade/order"
      decoded = Jason.decode!(result.body)
      assert decoded["instId"] == "BTC-USDT"
    end

    test "POST without params keeps an empty body" do
      request = %{method: :post, path: "/api/v5/trade/order", body: nil, params: %{}}

      result = HmacSha256Iso.sign(request, @credentials, @config)

      assert result.body == nil
    end

    test "GET omits Content-Type header" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = HmacSha256Iso.sign(request, @credentials, @config)

      refute Enum.any?(result.headers, fn {k, _} -> k == "Content-Type" end)
    end

    test "POST includes Content-Type application/json" do
      request = %{method: :post, path: "/api/v5/trade/order", body: nil, params: %{"instId" => "BTC-USDT"}}

      result = HmacSha256Iso.sign(request, @credentials, @config)

      assert {"Content-Type", "application/json"} in result.headers
    end

    test "includes all four OKX headers" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = HmacSha256Iso.sign(request, @credentials, @config)

      header_names = Enum.map(result.headers, &elem(&1, 0))
      assert "OK-ACCESS-KEY" in header_names
      assert "OK-ACCESS-TIMESTAMP" in header_names
      assert "OK-ACCESS-SIGN" in header_names
      assert "OK-ACCESS-PASSPHRASE" in header_names
    end
  end
end
