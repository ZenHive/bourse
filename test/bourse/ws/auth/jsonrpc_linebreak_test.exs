defmodule Bourse.WS.Auth.JsonrpcLinebreakTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.WS.Auth.JsonrpcLinebreak

  @ts_ms 1_700_000_000_000
  @creds %Credentials{api_key: "test_key", secret: "test_secret"}

  describe "pre_auth/3" do
    test "is a no-op" do
      assert {:ok, %{}} = JsonrpcLinebreak.pre_auth(@creds, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "builds a deribit-style public/auth frame with linebreak payload" do
      config = %{timestamp_ms_override: @ts_ms, nonce_override: @ts_ms}

      {:ok, message} = JsonrpcLinebreak.build_auth_message(@creds, config, request_id: 42)

      expected_payload = "#{@ts_ms}\n#{@ts_ms}\n"

      expected_sig =
        expected_payload
        |> Signing.hmac_sha256("test_secret")
        |> Signing.encode_hex()

      assert message == %{
               "jsonrpc" => "2.0",
               "id" => 42,
               "method" => "public/auth",
               "params" => %{
                 "grant_type" => "client_signature",
                 "client_id" => "test_key",
                 "timestamp" => @ts_ms,
                 "signature" => expected_sig,
                 "nonce" => to_string(@ts_ms),
                 "data" => ""
               }
             }
    end

    test "honors opts[:nonce] override" do
      config = %{timestamp_ms_override: @ts_ms}

      {:ok, %{"params" => %{"nonce" => nonce}}} =
        JsonrpcLinebreak.build_auth_message(@creds, config, nonce: "custom-nonce")

      assert nonce == "custom-nonce"
    end

    test "honors config[:method_value] override" do
      config = %{timestamp_ms_override: @ts_ms, method_value: "private/auth"}

      {:ok, %{"method" => method}} = JsonrpcLinebreak.build_auth_message(@creds, config, [])

      assert method == "private/auth"
    end
  end

  describe "handle_auth_response/2" do
    test "returns {:ok, %{ttl_ms: N}} when expires_in is an integer" do
      response = %{"result" => %{"access_token" => "tok", "expires_in" => 900}}
      assert {:ok, %{ttl_ms: 900_000}} = JsonrpcLinebreak.handle_auth_response(response, %{})
    end

    test "parses string expires_in" do
      response = %{"result" => %{"access_token" => "tok", "expires_in" => "900"}}
      assert {:ok, %{ttl_ms: 900_000}} = JsonrpcLinebreak.handle_auth_response(response, %{})
    end

    test "returns :ok with no TTL when expires_in is missing or unparseable" do
      assert :ok =
               JsonrpcLinebreak.handle_auth_response(
                 %{"result" => %{"access_token" => "tok"}},
                 %{}
               )

      assert :ok =
               JsonrpcLinebreak.handle_auth_response(
                 %{"result" => %{"access_token" => "tok", "expires_in" => "garbage"}},
                 %{}
               )
    end

    test "error on {error, ...}" do
      response = %{"error" => %{"code" => -32_000, "message" => "invalid_credentials"}}

      assert {:error, {:auth_failed, %{"code" => -32_000}}} =
               JsonrpcLinebreak.handle_auth_response(response, %{})
    end
  end
end
