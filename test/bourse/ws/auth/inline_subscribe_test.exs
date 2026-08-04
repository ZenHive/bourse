defmodule Bourse.WS.Auth.InlineSubscribeTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.WS.Auth.InlineSubscribe

  @ts_ms 1_700_000_000_000
  @ts_s div(@ts_ms, 1000)

  # Coinbase ships secrets as base64 — pre-encode a fixed 32-byte secret
  @secret_binary :binary.copy(<<0x42>>, 32)
  @secret_b64 Base.encode64(@secret_binary)

  @creds %Credentials{
    api_key: "test_key",
    secret: @secret_b64,
    password: "test_pass"
  }

  describe "pre_auth/3" do
    test "is a no-op" do
      assert {:ok, %{}} = InlineSubscribe.pre_auth(@creds, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "returns :no_message — auth is per-subscribe, not standalone" do
      assert :no_message = InlineSubscribe.build_auth_message(@creds, %{}, [])
    end
  end

  describe "handle_auth_response/2" do
    test "always :ok — no standalone auth response" do
      assert :ok = InlineSubscribe.handle_auth_response(%{}, %{})
    end
  end

  describe "build_subscribe_auth/4" do
    test "builds a coinbase-style per-subscribe auth map with passphrase" do
      config = %{timestamp_ms_override: @ts_ms}

      result = InlineSubscribe.build_subscribe_auth(@creds, config, "level2", ["BTC-USD"])

      expected_ts = to_string(@ts_s)
      payload = expected_ts <> "GET" <> "/users/self/verify"

      expected_sig =
        payload
        |> Signing.hmac_sha256(@secret_binary)
        |> Signing.encode_base64()

      assert result == %{
               "key" => "test_key",
               "timestamp" => expected_ts,
               "signature" => expected_sig,
               "passphrase" => "test_pass"
             }
    end

    test "omits passphrase when credentials.password is nil" do
      creds = %Credentials{api_key: "k", secret: @secret_b64}
      config = %{timestamp_ms_override: @ts_ms}

      result = InlineSubscribe.build_subscribe_auth(creds, config, "level2", ["BTC-USD"])

      refute Map.has_key?(result, "passphrase")
      assert Map.has_key?(result, "key")
      assert Map.has_key?(result, "timestamp")
      assert Map.has_key?(result, "signature")
    end
  end
end
