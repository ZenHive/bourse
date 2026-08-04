defmodule Bourse.WS.Auth.IsoPassphraseTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.WS.Auth.IsoPassphrase

  @ts_ms 1_700_000_000_000
  @creds_with_pass %Credentials{
    api_key: "test_key",
    secret: "test_secret",
    password: "test_pass"
  }

  describe "pre_auth/3" do
    test "is a no-op" do
      assert {:ok, %{}} = IsoPassphrase.pre_auth(@creds_with_pass, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "builds an okx-style login frame with seconds timestamp by default" do
      config = %{timestamp_ms_override: @ts_ms}

      {:ok, message} = IsoPassphrase.build_auth_message(@creds_with_pass, config, [])

      expected_ts = to_string(div(@ts_ms, 1000))

      expected_sig =
        "#{expected_ts}GET/users/self/verify"
        |> Signing.hmac_sha256("test_secret")
        |> Signing.encode_base64()

      assert message == %{
               "op" => "login",
               "args" => [
                 %{
                   "apiKey" => "test_key",
                   "passphrase" => "test_pass",
                   "timestamp" => expected_ts,
                   "sign" => expected_sig
                 }
               ]
             }
    end

    test "honors :timestamp_unit => :milliseconds" do
      config = %{timestamp_ms_override: @ts_ms, timestamp_unit: :milliseconds}

      {:ok, %{"args" => [%{"timestamp" => ts}]}} =
        IsoPassphrase.build_auth_message(@creds_with_pass, config, [])

      assert ts == to_string(@ts_ms)
    end

    test "honors :op_field / :op_value overrides" do
      config = %{timestamp_ms_override: @ts_ms, op_field: "event", op_value: "auth"}

      {:ok, message} = IsoPassphrase.build_auth_message(@creds_with_pass, config, [])

      assert Map.has_key?(message, "event")
      refute Map.has_key?(message, "op")
      assert message["event"] == "auth"
    end

    test "errors when credentials.password is missing" do
      creds = %Credentials{api_key: "k", secret: "s"}
      assert {:error, :passphrase_required} = IsoPassphrase.build_auth_message(creds, %{}, [])
    end
  end

  describe "handle_auth_response/2" do
    test "success on event=login + code=0" do
      assert :ok =
               IsoPassphrase.handle_auth_response(
                 %{"event" => "login", "code" => "0"},
                 %{}
               )
    end

    test "error on event=error" do
      response = %{"event" => "error", "msg" => "bad key"}

      assert {:error, {:auth_failed, "bad key"}} =
               IsoPassphrase.handle_auth_response(response, %{})
    end

    test "generic error otherwise" do
      assert {:error, {:auth_failed, %{}}} =
               IsoPassphrase.handle_auth_response(%{}, %{})
    end
  end
end
