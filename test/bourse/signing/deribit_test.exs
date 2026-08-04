defmodule Bourse.Signing.DeribitTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing.Deribit

  @credentials %Bourse.Credentials{api_key: "deri_key", secret: "deri_secret"}

  describe "sign/3" do
    test "produces deri-hmac-sha256 Authorization header" do
      request = %{method: :get, path: "/api/v2/public/get_instruments", body: nil, params: %{}}

      result = Deribit.sign(request, @credentials, %{})

      {_, auth} = Enum.find(result.headers, fn {k, _} -> k == "Authorization" end)
      assert String.starts_with?(auth, "deri-hmac-sha256 ")
    end

    test "Authorization header contains id, ts, sig, nonce" do
      request = %{method: :get, path: "/api/v2/public/test", body: nil, params: %{}}

      result = Deribit.sign(request, @credentials, %{})

      {_, auth} = Enum.find(result.headers, fn {k, _} -> k == "Authorization" end)
      assert String.contains?(auth, "id=deri_key")
      assert String.contains?(auth, "ts=")
      assert String.contains?(auth, "sig=")
      assert String.contains?(auth, "nonce=")
    end

    test "signature is hex-encoded SHA256" do
      request = %{method: :get, path: "/api/v2/public/test", body: nil, params: %{}}

      result = Deribit.sign(request, @credentials, %{})

      {_, auth} = Enum.find(result.headers, fn {k, _} -> k == "Authorization" end)
      # Extract sig value
      [sig_part] = Regex.run(~r/sig=([0-9a-f]+)/, auth, capture: :all_but_first)
      assert String.length(sig_part) == 64
    end

    test "only Authorization header (no extra X- headers)" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = Deribit.sign(request, @credentials, %{})

      assert length(result.headers) == 1
      assert {"Authorization", _} = hd(result.headers)
    end

    test "GET with params includes query in URL" do
      request = %{
        method: :get,
        path: "/api/v2/private/get_position",
        body: nil,
        params: %{"instrument_name" => "BTC-PERPETUAL"}
      }

      result = Deribit.sign(request, @credentials, %{})

      assert String.contains?(result.url, "instrument_name=BTC-PERPETUAL")
    end

    test "GET with list params encodes empty-bracket keys (not URI.encode_query crash)" do
      request = %{
        method: :get,
        path: "/api/v2/private/get_order_margin_by_ids",
        body: nil,
        params: %{"ids" => ["ETH-1", "ETH-2"]}
      }

      result = Deribit.sign(request, @credentials, %{})

      assert result.url ==
               "/api/v2/private/get_order_margin_by_ids?ids%5B%5D=ETH-1&ids%5B%5D=ETH-2"
    end

    test "uses the explicit urlencode query encoder" do
      request = %{
        method: :get,
        path: "/api/v2/private/get_order_margin_by_ids",
        body: nil,
        params: %{"ids" => ["ETH-1", "ETH-2"]}
      }

      result = Deribit.sign(request, @credentials, %{query_encoder: "urlencode"})

      assert result.url ==
               "/api/v2/private/get_order_margin_by_ids?ids%5B%5D=ETH-1&ids%5B%5D=ETH-2"
    end

    test "an unauthored query encoder raises rather than signing a wrong dialect" do
      request = %{
        method: :get,
        path: "/api/v2/private/get_order_margin_by_ids",
        body: nil,
        params: %{"ids" => ["ETH-1", "ETH-2"]}
      }

      assert_raise ArgumentError, ~r/unsupported Deribit query encoder "urlencodeJsonArray"/, fn ->
        Deribit.sign(request, @credentials, %{query_encoder: "urlencodeJsonArray"})
      end
    end

    test "GET with space-bearing param percent-encodes as %20 in signed URL" do
      request = %{
        method: :get,
        path: "/api/v2/private/cancel_by_label",
        body: nil,
        params: %{"label" => "task 286 pin"}
      }

      result = Deribit.sign(request, @credentials, %{})

      assert result.url == "/api/v2/private/cancel_by_label?label=task%20286%20pin"
      refute String.contains?(result.url, "label=task+")
    end

    test "preserves original body" do
      body = Jason.encode!(%{"instrument_name" => "BTC-PERPETUAL"})

      request = %{method: :post, path: "/api/v2/private/buy", body: body, params: %{}}

      result = Deribit.sign(request, @credentials, %{})

      assert result.body == body
    end

    test "nil body produces nil in result" do
      request = %{method: :get, path: "/test", body: nil, params: %{}}

      result = Deribit.sign(request, @credentials, %{})

      assert result.body == nil
    end
  end
end
