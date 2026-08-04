defmodule Bourse.WS.Auth.DirectHmacExpiryTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.WS.Auth.DirectHmacExpiry

  @ts_ms 1_700_000_000_000
  @creds %Credentials{api_key: "test_key", secret: "test_secret"}

  describe "pre_auth/3" do
    test "is a no-op" do
      assert {:ok, %{}} = DirectHmacExpiry.pre_auth(@creds, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "produces a byte-equal bybit-style frame with default hex encoding" do
      config = %{timestamp_ms_override: @ts_ms}

      {:ok, message} = DirectHmacExpiry.build_auth_message(@creds, config, [])

      expected_expires = @ts_ms + 10_000

      expected_sig =
        "GET/realtime#{expected_expires}"
        |> Signing.hmac_sha256("test_secret")
        |> Signing.encode_hex()

      assert message == %{
               "op" => "auth",
               "args" => ["test_key", expected_expires, expected_sig]
             }
    end

    test "honors :expires_offset_ms override" do
      config = %{timestamp_ms_override: @ts_ms, expires_offset_ms: 5_000}

      {:ok, %{"args" => [_, expires, _]}} =
        DirectHmacExpiry.build_auth_message(@creds, config, [])

      assert expires == @ts_ms + 5_000
    end

    test "honors :encoding => :base64" do
      config = %{timestamp_ms_override: @ts_ms, encoding: :base64}

      {:ok, %{"args" => [_, expires, sig]}} =
        DirectHmacExpiry.build_auth_message(@creds, config, [])

      expected_sig =
        "GET/realtime#{expires}"
        |> Signing.hmac_sha256("test_secret")
        |> Signing.encode_base64()

      assert sig == expected_sig
    end

    test "honors :op_field / :op_value overrides" do
      config = %{timestamp_ms_override: @ts_ms, op_field: "type", op_value: "login"}

      {:ok, message} = DirectHmacExpiry.build_auth_message(@creds, config, [])

      assert Map.has_key?(message, "type")
      refute Map.has_key?(message, "op")
      assert message["type"] == "login"
    end
  end

  describe "handle_auth_response/2" do
    test "success with success: true" do
      assert :ok = DirectHmacExpiry.handle_auth_response(%{"success" => true}, %{})
    end

    test "error when ret_msg contains 'error'" do
      response = %{"ret_msg" => "authentication error"}

      assert {:error, {:auth_failed, "authentication error"}} =
               DirectHmacExpiry.handle_auth_response(response, %{})
    end

    test "generic error otherwise" do
      assert {:error, {:auth_failed, %{"weird" => "frame"}}} =
               DirectHmacExpiry.handle_auth_response(%{"weird" => "frame"}, %{})
    end
  end
end
