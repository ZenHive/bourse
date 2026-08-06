defmodule Bourse.WS.Auth.WsApiSignatureTest do
  @moduledoc """
  The signed WS-API request that opens binance spot's user data stream.

  Signing is the whole content of this pattern, so the assertions compute the
  expected HMAC independently rather than compare the frame against itself.

  Live confirmation is in `Bourse.WS.AuthLiveSmokeTest`: the venue accepts the
  request and delivers `executionReport`, and rejects a wrong secret.
  """

  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.WS.Auth.WsApiSignature

  @creds Credentials.new!(api_key: "key", secret: "secret")

  describe "pre_auth/3" do
    test "needs no round-trip — the request travels on the socket" do
      assert {:ok, %{}} = WsApiSignature.pre_auth(@creds, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "signs the parameters sorted by name" do
      assert {:ok, frame} = WsApiSignature.build_auth_message(@creds, %{}, timestamp_ms: 1_700_000_000_000)

      assert frame["method"] == "userDataStream.subscribe.signature"

      assert frame["params"] == %{
               "apiKey" => "key",
               "timestamp" => 1_700_000_000_000,
               "signature" =>
                 :hmac
                 |> :crypto.mac(:sha256, "secret", "apiKey=key&timestamp=1700000000000")
                 |> Base.encode16(case: :lower)
             }
    end

    test "carries the request id the venue correlates its reply by" do
      assert {:ok, %{"id" => "abc"}} = WsApiSignature.build_auth_message(@creds, %{}, request_id: "abc")
    end

    test "stamps its own timestamp when the caller names none" do
      before = System.system_time(:millisecond)
      assert {:ok, %{"params" => %{"timestamp" => stamped}}} = WsApiSignature.build_auth_message(@creds, %{}, [])

      assert stamped >= before
      assert stamped <= System.system_time(:millisecond)
    end

    test "an authored method overrides the default" do
      assert {:ok, %{"method" => "userDataStream.unsubscribe"}} =
               WsApiSignature.build_auth_message(@creds, %{method: "userDataStream.unsubscribe"}, [])
    end

    test "refuses to build an unsigned frame when a credential half is missing" do
      assert {:error, :missing_credentials} =
               WsApiSignature.build_auth_message(%Credentials{api_key: "key", secret: nil}, %{}, [])

      assert {:error, :missing_credentials} =
               WsApiSignature.build_auth_message(%Credentials{api_key: nil, secret: "secret"}, %{}, [])

      assert {:error, :missing_credentials} = WsApiSignature.build_auth_message(nil, %{}, [])
    end
  end

  describe "handle_auth_response/2" do
    test "accepts the venue's 200" do
      assert :ok = WsApiSignature.handle_auth_response(%{"status" => 200, "result" => %{}}, %{})
    end

    test "prefers the venue's own message over the status code" do
      response = %{"status" => 401, "error" => %{"code" => -1_022, "msg" => "Signature invalid."}}

      assert {:error, {:auth_failed, "Signature invalid."}} =
               WsApiSignature.handle_auth_response(response, %{})
    end

    test "falls back to the status when the venue sends no message" do
      assert {:error, {:auth_failed, 403}} = WsApiSignature.handle_auth_response(%{"status" => 403}, %{})
    end

    test "reports an unrecognised frame whole rather than reading it as success" do
      assert {:error, {:auth_failed, %{"unexpected" => true}}} =
               WsApiSignature.handle_auth_response(%{"unexpected" => true}, %{})
    end
  end
end
