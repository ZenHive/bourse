defmodule Bourse.WS.Auth.ListenKeyTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.WS.Auth.ListenKey

  @creds %Credentials{api_key: "k", secret: "s"}

  @config %{
    pre_auth: %{
      endpoints: [
        %{
          type: :spot,
          endpoint: "publicPostUserDataStream",
          api_section: "public",
          method: "POST",
          path: "/api/v3/userDataStream"
        },
        %{
          type: :linear,
          endpoint: "fapiPrivatePostListenKey",
          api_section: "fapiPrivate",
          method: "POST",
          path: "/fapi/v1/listenKey"
        },
        %{
          type: :inverse,
          endpoint: "dapiPrivatePostListenKey",
          api_section: "dapiPrivate",
          path: "/dapi/v1/listenKey"
        }
      ]
    }
  }

  describe "pre_auth/3" do
    test "resolves :spot endpoint by default" do
      assert {:ok, result} = ListenKey.pre_auth(@creds, @config, [])

      assert result.endpoint == "publicPostUserDataStream"
      assert result.market_type == :spot
      assert result.api_section == "public"
      assert result.method == "POST"
      assert result.path == "/api/v3/userDataStream"
      assert result.credentials == @creds
    end

    test "resolves :linear endpoint when opts[:market_type] == :linear" do
      assert {:ok, %{endpoint: "fapiPrivatePostListenKey", market_type: :linear}} =
               ListenKey.pre_auth(@creds, @config, market_type: :linear)
    end

    test "normalizes :future to :linear" do
      assert {:ok, %{endpoint: "fapiPrivatePostListenKey", market_type: :linear}} =
               ListenKey.pre_auth(@creds, @config, market_type: :future)
    end

    test "normalizes :delivery to :inverse" do
      assert {:ok, %{endpoint: "dapiPrivatePostListenKey", market_type: :inverse}} =
               ListenKey.pre_auth(@creds, @config, market_type: :delivery)
    end

    test "defaults method to POST when the endpoint entry omits it" do
      # The :inverse entry above leaves :method unset
      assert {:ok, %{method: "POST"}} =
               ListenKey.pre_auth(@creds, @config, market_type: :inverse)
    end

    test "returns no_endpoint_for_market_type when unsupported" do
      assert {:error, {:no_endpoint_for_market_type, details}} =
               ListenKey.pre_auth(@creds, @config, market_type: :margin)

      assert details.requested == :margin
      assert details.normalized == :margin
      assert Enum.sort(details.available) == [:inverse, :linear, :spot]
    end
  end

  describe "build_auth_message/3" do
    test "returns :no_message — listen_key has no WS auth frame" do
      assert :no_message = ListenKey.build_auth_message(@creds, %{}, [])
    end
  end

  describe "handle_auth_response/2" do
    test "always :ok — no WS auth response to classify" do
      assert :ok = ListenKey.handle_auth_response(%{}, %{})
    end
  end
end
