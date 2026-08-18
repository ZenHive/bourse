defmodule Bourse.WS.Auth.ActionKeySecretTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.WS.Auth.ActionKeySecret

  @credentials Credentials.new!(api_key: "key", secret: "secret")

  test "builds Alpaca's plain action auth frame" do
    assert {:ok, %{}} = ActionKeySecret.pre_auth(@credentials, %{}, [])

    assert {:ok, %{"action" => "auth", "key" => "key", "secret" => "secret"}} =
             ActionKeySecret.build_auth_message(@credentials, %{}, [])
  end

  test "accepts authentication and preserves provider rejection detail" do
    assert :ok =
             ActionKeySecret.handle_auth_response(
               [%{"T" => "success", "msg" => "authenticated"}],
               %{}
             )

    rejection = %{"T" => "error", "code" => 402, "msg" => "auth failed"}

    assert {:error, {:auth_failed, ^rejection}} =
             ActionKeySecret.handle_auth_response([rejection], %{})

    assert :ok =
             ActionKeySecret.handle_auth_response(
               [%{"T" => "success", "msg" => "authenticated"}, rejection],
               %{}
             )
  end

  test "rejects missing credential fields and unknown replies" do
    assert {:error, :missing_credentials} =
             ActionKeySecret.build_auth_message(%Credentials{api_key: nil, secret: "secret"}, %{}, [])

    assert {:error, {:auth_failed, [%{"T" => "success", "msg" => "connected"}]}} =
             ActionKeySecret.handle_auth_response(
               [%{"T" => "success", "msg" => "connected"}],
               %{}
             )

    assert {:error, {:auth_failed, %{"T" => "error"}}} =
             ActionKeySecret.handle_auth_response(%{"T" => "error"}, %{})
  end
end
