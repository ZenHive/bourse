defmodule Bourse.WS.Auth.RestTokenTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.WS.Auth.RestToken

  @creds %Credentials{api_key: "k", secret: "s"}

  describe "pre_auth/3" do
    test "returns endpoint + credentials when config carries a pre_auth endpoint" do
      config = %{pre_auth: %{endpoint: "privatePostGetWebSocketsToken"}}

      assert {:ok, %{endpoint: "privatePostGetWebSocketsToken", credentials: @creds}} =
               RestToken.pre_auth(@creds, config, [])
    end

    test "error when pre_auth endpoint is missing" do
      assert {:error, :no_token_endpoint} = RestToken.pre_auth(@creds, %{}, [])
    end
  end

  describe "build_auth_message/3" do
    test "returns :no_message" do
      assert :no_message = RestToken.build_auth_message(@creds, %{}, [])
    end
  end

  describe "handle_auth_response/2" do
    test "always :ok" do
      assert :ok = RestToken.handle_auth_response(%{}, %{})
    end
  end
end
