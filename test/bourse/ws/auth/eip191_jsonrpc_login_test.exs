defmodule Bourse.WS.Auth.Eip191JsonrpcLoginTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing.Derive
  alias Bourse.WS.Auth.Eip191JsonrpcLogin

  @ts_ms 1_700_000_000_000
  @private_key "0x0123456789012345678901234567890123456789012345678901234567890123"
  @wallet "0x108b9aF9279a525b8A8AeAbE7AC2bA925Bc50075"
  @creds %Credentials{api_key: @wallet, secret: @private_key}

  describe "pre_auth/3" do
    test "is a no-op" do
      assert {:ok, %{}} = Eip191JsonrpcLogin.pre_auth(@creds, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "builds a derive public/login frame with EIP-191 of the ms timestamp" do
      config = %{timestamp_ms_override: @ts_ms}
      timestamp = Integer.to_string(@ts_ms)

      {:ok, message} = Eip191JsonrpcLogin.build_auth_message(@creds, config, request_id: 42)

      assert message == %{
               "id" => 42,
               "method" => "public/login",
               "params" => %{
                 "wallet" => @wallet,
                 "timestamp" => timestamp,
                 "signature" => Derive.sign_message(timestamp, private_key: @private_key)
               }
             }
    end

    test "passes a binary config timestamp through unchanged" do
      timestamp = "1700000000000"
      config = %{timestamp: timestamp}

      {:ok, %{"params" => params}} = Eip191JsonrpcLogin.build_auth_message(@creds, config, [])

      assert params["timestamp"] == timestamp
      assert params["signature"] == Derive.sign_message(timestamp, private_key: @private_key)
    end

    test "honors config[:method_value] override" do
      config = %{timestamp_ms_override: @ts_ms, method_value: "private/login"}

      {:ok, %{"method" => method}} = Eip191JsonrpcLogin.build_auth_message(@creds, config, [])

      assert method == "private/login"
    end
  end

  describe "handle_auth_response/2" do
    test "returns {:ok, %{subaccounts: ids}} on a list result" do
      assert {:ok, %{subaccounts: [144_422]}} =
               Eip191JsonrpcLogin.handle_auth_response(%{"result" => [144_422]}, %{})
    end

    test "accepts an empty subaccount list as a successful login" do
      assert {:ok, %{subaccounts: []}} = Eip191JsonrpcLogin.handle_auth_response(%{"result" => []}, %{})
    end

    test "error on {error, ...}" do
      response = %{"error" => %{"code" => 14_022, "message" => "invalid signature"}}

      assert {:error, {:auth_failed, %{"code" => 14_022}}} =
               Eip191JsonrpcLogin.handle_auth_response(response, %{})
    end

    test "rejects an unrecognised frame" do
      assert {:error, {:auth_failed, %{"foo" => 1}}} =
               Eip191JsonrpcLogin.handle_auth_response(%{"foo" => 1}, %{})
    end
  end
end
