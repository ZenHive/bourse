defmodule Bourse.WS.Auth.Sha384NonceTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.WS.Auth.Sha384Nonce

  @ts_ms 1_700_000_000_000
  @creds %Credentials{api_key: "test_key", secret: "test_secret"}

  describe "pre_auth/3" do
    test "is a no-op" do
      assert {:ok, %{}} = Sha384Nonce.pre_auth(@creds, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "builds a bitfinex-style auth frame with SHA384 hex signature" do
      config = %{timestamp_ms_override: @ts_ms}

      {:ok, message} = Sha384Nonce.build_auth_message(@creds, config, [])

      expected_sig =
        "AUTH#{@ts_ms}"
        |> Signing.hmac_sha384("test_secret")
        |> Signing.encode_hex()

      assert message == %{
               "event" => "auth",
               "apiKey" => "test_key",
               "authSig" => expected_sig,
               "authNonce" => @ts_ms,
               "authPayload" => "AUTH#{@ts_ms}"
             }
    end

    test "honors :event_value override" do
      config = %{timestamp_ms_override: @ts_ms, event_value: "login"}

      {:ok, %{"event" => event}} = Sha384Nonce.build_auth_message(@creds, config, [])

      assert event == "login"
    end
  end

  describe "handle_auth_response/2" do
    test "success on event=auth + status=OK" do
      assert :ok =
               Sha384Nonce.handle_auth_response(
                 %{"event" => "auth", "status" => "OK"},
                 %{}
               )
    end

    test "error on event=auth + status=FAILED" do
      response = %{"event" => "auth", "status" => "FAILED", "msg" => "nonce too small"}

      assert {:error, {:auth_failed, "nonce too small"}} =
               Sha384Nonce.handle_auth_response(response, %{})
    end

    test "generic error otherwise" do
      assert {:error, {:auth_failed, %{}}} = Sha384Nonce.handle_auth_response(%{}, %{})
    end
  end
end
