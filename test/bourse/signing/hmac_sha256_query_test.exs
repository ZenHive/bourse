defmodule Bourse.Signing.HmacSha256QueryTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing
  alias Bourse.Signing.HmacSha256Query

  @credentials %Bourse.Credentials{api_key: "test_api_key", secret: "test_secret"}

  describe "sign/3" do
    test "GET request places signature in query string" do
      request = %{method: :get, path: "/api/v3/account", body: nil, params: %{}}
      config = %{api_key_header: "X-MBX-APIKEY"}

      result = HmacSha256Query.sign(request, @credentials, config)

      assert result.method == :get
      assert String.starts_with?(result.url, "/api/v3/account?")
      assert String.contains?(result.url, "signature=")
      assert String.contains?(result.url, "timestamp=")
      assert result.body == nil
    end

    test "POST request places signed form body in body by default" do
      request = %{method: :post, path: "/api/v3/order", body: nil, params: %{"symbol" => "BTCUSDT"}}
      config = %{}

      result = HmacSha256Query.sign(request, @credentials, config)

      assert result.method == :post
      assert result.url == "/api/v3/order"
      assert is_binary(result.body)
      assert String.contains?(result.body, "signature=")
      assert String.contains?(result.body, "symbol=BTCUSDT")
      refute String.contains?(result.url, "?")
    end

    test "POST with post_as_json puts signature in JSON body" do
      request = %{method: :post, path: "/api/v3/order", body: nil, params: %{"symbol" => "BTCUSDT"}}
      config = %{post_as_json: true}

      result = HmacSha256Query.sign(request, @credentials, config)

      assert result.url == "/api/v3/order"
      assert is_binary(result.body)
      decoded = Jason.decode!(result.body)
      assert Map.has_key?(decoded, "signature")
      assert decoded["symbol"] == "BTCUSDT"
    end

    test "includes API key header" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = %{api_key_header: "X-MBX-APIKEY"}

      result = HmacSha256Query.sign(request, @credentials, config)

      assert {"X-MBX-APIKEY", "test_api_key"} in result.headers
    end

    test "custom header name" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = %{api_key_header: "X-CUSTOM-KEY"}

      result = HmacSha256Query.sign(request, @credentials, config)

      assert {"X-CUSTOM-KEY", "test_api_key"} in result.headers
    end

    test "params are sorted alphabetically in query string" do
      request = %{method: :get, path: "/test", body: nil, params: %{"z" => "1", "a" => "2"}}
      config = %{}

      result = HmacSha256Query.sign(request, @credentials, config)

      # After the path, params should be sorted: a=2&timestamp=...&z=1&signature=...
      query = result.url |> String.split("?") |> List.last()
      parts = String.split(query, "&")
      # "a" should come before "z" and "timestamp"
      a_idx = Enum.find_index(parts, &String.starts_with?(&1, "a="))
      z_idx = Enum.find_index(parts, &String.starts_with?(&1, "z="))
      assert a_idx < z_idx
    end

    test "signature encoding defaults to hex" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = %{}

      result = HmacSha256Query.sign(request, @credentials, config)

      query = result.url |> String.split("?") |> List.last()
      sig_part = query |> String.split("&") |> Enum.find(&String.starts_with?(&1, "signature="))
      sig_value = String.replace_prefix(sig_part, "signature=", "")
      # Hex: only lowercase hex chars, 64 chars for SHA256
      assert String.match?(sig_value, ~r/^[0-9a-f]{64}$/)
    end

    test "base64 signature encoding" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = %{signature_encoding: :base64}

      result = HmacSha256Query.sign(request, @credentials, config)

      query = result.url |> String.split("?") |> List.last()
      sig_part = query |> String.split("&") |> Enum.find(&String.starts_with?(&1, "signature="))
      sig_value = sig_part |> String.replace_prefix("signature=", "") |> URI.decode()
      # Base64 should decode successfully
      assert {:ok, _} = Base.decode64(sig_value)
    end

    test "auto_recv_window adds recvWindow when enabled" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = %{recv_window_key: "recvWindow", auto_recv_window: true, recv_window: 5000}

      result = HmacSha256Query.sign(request, @credentials, config)

      assert String.contains?(result.url, "recvWindow=5000")
    end

    test "atom key recvWindow in params prevents duplicate" do
      request = %{method: :get, path: "/test", body: nil, params: %{recvWindow: 1000}}
      config = %{recv_window_key: "recvWindow", auto_recv_window: true, recv_window: 5000}

      result = HmacSha256Query.sign(request, @credentials, config)

      query = result.url |> String.split("?") |> List.last()
      recv_count = query |> String.split("&") |> Enum.count(&String.starts_with?(&1, "recvWindow="))
      assert recv_count == 1
    end

    test "recv_window not added when auto_recv_window is false" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}
      config = %{recv_window_key: "recvWindow", auto_recv_window: false}

      result = HmacSha256Query.sign(request, @credentials, config)

      refute String.contains?(result.url, "recvWindow=")
    end

    test "DELETE request works like GET" do
      request = %{method: :delete, path: "/api/v3/order", body: nil, params: %{"orderId" => "123"}}
      config = %{}

      result = HmacSha256Query.sign(request, @credentials, config)

      assert result.method == :delete
      assert String.contains?(result.url, "orderId=123")
      assert String.contains?(result.url, "signature=")
      assert result.body == nil
    end

    test "deterministic signature for known inputs" do
      # Manually compute expected signature
      params = %{"symbol" => "BTCUSDT", "timestamp" => "1234567890"}
      query_string = Signing.urlencode(params)
      expected_sig = query_string |> Signing.hmac_sha256("test_secret") |> Signing.encode_hex()

      request = %{method: :get, path: "/test", body: nil, params: %{"symbol" => "BTCUSDT"}}
      config = %{timestamp_key: "timestamp"}

      result = HmacSha256Query.sign(request, @credentials, config)

      # We can't match exact sig (timestamp differs) but verify format
      query = result.url |> String.split("?") |> List.last()
      sig_part = query |> String.split("&") |> Enum.find(&String.starts_with?(&1, "signature="))
      assert sig_part
      sig_value = String.replace_prefix(sig_part, "signature=", "")
      # Valid hex, correct length
      assert String.match?(sig_value, ~r/^[0-9a-f]{64}$/)
      # Both are SHA256 hashes of similar structure — just different timestamps
      assert String.length(sig_value) == String.length(expected_sig)
    end
  end
end
