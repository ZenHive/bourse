defmodule Bourse.WS.Auth.ListenKeyTest do
  @moduledoc """
  Endpoint resolution for the `:listen_key` pattern.

  What `pre_auth/3` returns is dispatch coordinates: generated raw endpoint
  names the exchange module actually carries. It used to return a CCXT method
  name plus an `api_section`/`method`/`path` triple that nothing read and that
  matched no function in this client — resolution that looked complete and
  could not be called.

  The round-trip that consumes this lives in `Bourse.WS.ListenKeyTest`.
  """

  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.WS.Auth.ListenKey

  @creds %Credentials{api_key: "k", secret: "s"}

  @config %{
    pre_auth: %{
      default_market_type: :linear,
      endpoints: %{
        spot: :public_post_userdatastream,
        linear: :fapiPrivate_post_listenkey,
        inverse: :dapiPrivate_post_listenkey
      },
      keepalive_endpoints: %{linear: :fapiPrivate_put_listenkey},
      keepalive_ms: 900_000
    }
  }

  describe "pre_auth/3" do
    test "resolves the venue's own default market type, not spot" do
      # binanceusdm serves linear only. A hardcoded `:spot` default resolved an
      # endpoint the venue does not serve, or nothing at all.
      assert {:ok, result} = ListenKey.pre_auth(@creds, @config, [])

      assert result.endpoint == :fapiPrivate_post_listenkey
      assert result.keepalive_endpoint == :fapiPrivate_put_listenkey
      assert result.market_type == :linear
      assert result.keepalive_ms == 900_000
      assert result.credentials == @creds
    end

    test "an explicit market type wins over the venue default" do
      assert {:ok, %{endpoint: :public_post_userdatastream, market_type: :spot}} =
               ListenKey.pre_auth(@creds, @config, market_type: :spot)
    end

    test "normalizes :future to :linear" do
      assert {:ok, %{endpoint: :fapiPrivate_post_listenkey, market_type: :linear}} =
               ListenKey.pre_auth(@creds, @config, market_type: :future)
    end

    test "normalizes :delivery to :inverse" do
      assert {:ok, %{endpoint: :dapiPrivate_post_listenkey, market_type: :inverse}} =
               ListenKey.pre_auth(@creds, @config, market_type: :delivery)
    end

    test "normalizes :contract to :linear" do
      assert {:ok, %{market_type: :linear}} = ListenKey.pre_auth(@creds, @config, market_type: :contract)
    end

    test "reports a market type with no refresh endpoint as nil rather than guessing" do
      assert {:ok, %{market_type: :inverse, keepalive_endpoint: nil}} =
               ListenKey.pre_auth(@creds, @config, market_type: :inverse)
    end

    test "applies the venue's documented 30-minute refresh when none is authored" do
      config = %{pre_auth: %{endpoints: %{spot: :e}}}

      assert {:ok, %{keepalive_ms: 1_800_000}} = ListenKey.pre_auth(@creds, config, market_type: :spot)
    end

    test "accepts the documented list shape as well as the authored map" do
      config = %{pre_auth: %{endpoints: [%{type: :spot, endpoint: :listed}]}}

      assert {:ok, %{endpoint: :listed}} = ListenKey.pre_auth(@creds, config, market_type: :spot)
    end

    test "returns no_endpoint_for_market_type when unsupported" do
      assert {:error, {:no_endpoint_for_market_type, details}} =
               ListenKey.pre_auth(@creds, @config, market_type: :margin)

      assert details.requested == :margin
      assert details.normalized == :margin
      assert Enum.sort(details.available) == [:inverse, :linear, :spot]
    end

    test "reports an absent pre_auth slice instead of raising" do
      assert {:error, {:no_endpoint_for_market_type, %{available: []}}} =
               ListenKey.pre_auth(@creds, %{}, [])
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
