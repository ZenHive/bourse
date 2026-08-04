defmodule Bourse.WS.Auth.Sha512NewlineTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.WS.Auth.Sha512Newline

  @ts_ms 1_700_000_000_000
  @expected_ts_s div(@ts_ms, 1000)
  @creds %Credentials{api_key: "test_key", secret: "test_secret"}

  describe "pre_auth/3" do
    test "is a no-op" do
      assert {:ok, %{}} = Sha512Newline.pre_auth(@creds, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "builds a gate-style spot.login frame with SHA512 hex signature" do
      config = %{timestamp_ms_override: @ts_ms}
      opts = [request_id: "req-42"]

      {:ok, message} = Sha512Newline.build_auth_message(@creds, config, opts)

      req_params_json = Jason.encode!(%{})
      payload = "api\nspot.login\n#{req_params_json}\n#{@expected_ts_s}"

      expected_sig =
        payload
        |> Signing.hmac_sha512("test_secret")
        |> Signing.encode_hex()

      assert message == %{
               "id" => "req-42",
               "time" => @expected_ts_s,
               "channel" => "spot.login",
               "event" => "api",
               "payload" => %{
                 "req_id" => "req-42",
                 "timestamp" => to_string(@expected_ts_s),
                 "api_key" => "test_key",
                 "signature" => expected_sig,
                 "req_param" => %{}
               }
             }
    end

    test "honors :channel config override" do
      config = %{timestamp_ms_override: @ts_ms, channel: "futures.login"}
      {:ok, %{"channel" => channel}} = Sha512Newline.build_auth_message(@creds, config, [])
      assert channel == "futures.login"
    end
  end

  describe "handle_auth_response/2" do
    test "success on event=api + result.status=success" do
      response = %{"event" => "api", "result" => %{"status" => "success"}}
      assert :ok = Sha512Newline.handle_auth_response(response, %{})
    end

    test "error on {error, ...}" do
      response = %{"error" => %{"code" => 1, "message" => "bad sig"}}

      assert {:error, {:auth_failed, %{"code" => 1}}} =
               Sha512Newline.handle_auth_response(response, %{})
    end

    test "success when result is a bare map with no status field" do
      assert :ok = Sha512Newline.handle_auth_response(%{"result" => %{}}, %{})
    end

    test "error when result carries a non-success status" do
      response = %{"event" => "api", "result" => %{"status" => "failed"}}

      assert {:error, {:auth_failed, ^response}} =
               Sha512Newline.handle_auth_response(response, %{})
    end

    test "generic error when result is missing" do
      assert {:error, {:auth_failed, %{}}} = Sha512Newline.handle_auth_response(%{}, %{})
    end
  end
end
