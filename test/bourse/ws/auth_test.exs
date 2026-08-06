defmodule Bourse.WS.AuthTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.WS.Auth
  alias Bourse.WS.Auth.DirectHmacExpiry
  alias Bourse.WS.Auth.InlineSubscribe
  alias Bourse.WS.Auth.IsoPassphrase
  alias Bourse.WS.Auth.JsonrpcLinebreak
  alias Bourse.WS.Auth.ListenKey
  alias Bourse.WS.Auth.RestToken
  alias Bourse.WS.Auth.Sha384Nonce
  alias Bourse.WS.Auth.Sha512Newline
  alias Bourse.WS.Auth.WsApiSignature

  @creds %Credentials{api_key: "test_key", secret: "test_secret"}

  describe "patterns/0" do
    test "lists exactly the nine behaviour-implementing atoms (excludes :expiry)" do
      assert Enum.sort(Auth.patterns()) ==
               Enum.sort([
                 :direct_hmac_expiry,
                 :inline_subscribe,
                 :iso_passphrase,
                 :jsonrpc_linebreak,
                 :listen_key,
                 :rest_token,
                 :sha384_nonce,
                 :sha512_newline,
                 :ws_api_signature
               ])
    end
  end

  describe "module_for_pattern/1" do
    test "maps each pattern atom to its module" do
      assert Auth.module_for_pattern(:direct_hmac_expiry) == DirectHmacExpiry
      assert Auth.module_for_pattern(:inline_subscribe) == InlineSubscribe
      assert Auth.module_for_pattern(:iso_passphrase) == IsoPassphrase
      assert Auth.module_for_pattern(:jsonrpc_linebreak) == JsonrpcLinebreak
      assert Auth.module_for_pattern(:listen_key) == ListenKey
      assert Auth.module_for_pattern(:rest_token) == RestToken
      assert Auth.module_for_pattern(:sha384_nonce) == Sha384Nonce
      assert Auth.module_for_pattern(:sha512_newline) == Sha512Newline
      assert Auth.module_for_pattern(:ws_api_signature) == WsApiSignature
    end

    test "returns nil for unknown patterns" do
      assert Auth.module_for_pattern(:nonexistent) == nil
    end
  end

  describe "requires_pre_auth?/1" do
    test "is true only for :listen_key and :rest_token" do
      for pattern <- Auth.patterns() do
        expected = pattern in [:listen_key, :rest_token]
        assert Auth.requires_pre_auth?(pattern) == expected
      end
    end
  end

  describe "inline_auth?/1" do
    test "is true only for :inline_subscribe and :rest_token" do
      for pattern <- Auth.patterns() do
        expected = pattern in [:inline_subscribe, :rest_token]
        assert Auth.inline_auth?(pattern) == expected
      end
    end
  end

  describe "build_auth_message/4 dispatch" do
    test "routes :direct_hmac_expiry to DirectHmacExpiry" do
      config = %{timestamp_ms_override: 1_700_000_000_000}

      assert {:ok, %{"op" => "auth", "args" => [_, _, _]}} =
               Auth.build_auth_message(:direct_hmac_expiry, @creds, config, [])
    end

    test "returns :no_message for listen_key / rest_token / inline_subscribe" do
      for pattern <- [:listen_key, :rest_token, :inline_subscribe] do
        assert :no_message = Auth.build_auth_message(pattern, @creds, %{}, [])
      end
    end

    test "returns unknown_pattern error on garbage pattern" do
      assert {:error, {:unknown_pattern, :oops}} =
               Auth.build_auth_message(:oops, @creds, %{}, [])
    end
  end

  describe "pre_auth/4 dispatch" do
    test "returns {:ok, %{}} for patterns without REST round-trip" do
      for pattern <- [
            :direct_hmac_expiry,
            :iso_passphrase,
            :jsonrpc_linebreak,
            :sha384_nonce,
            :sha512_newline,
            :inline_subscribe,
            :ws_api_signature
          ] do
        assert {:ok, %{}} = Auth.pre_auth(pattern, @creds, %{}, [])
      end
    end

    test "unknown pattern returns unknown_pattern error" do
      assert {:error, {:unknown_pattern, :oops}} =
               Auth.pre_auth(:oops, @creds, %{}, [])
    end
  end

  describe "build_subscribe_auth/5 dispatch" do
    test "returns nil for most patterns" do
      for pattern <- [
            :direct_hmac_expiry,
            :iso_passphrase,
            :jsonrpc_linebreak,
            :sha384_nonce,
            :sha512_newline,
            :listen_key,
            :ws_api_signature
          ] do
        assert nil == Auth.build_subscribe_auth(pattern, @creds, %{}, "chan", ["BTC/USDT"])
      end
    end

    test "rest_token returns token map when config[:token] is set" do
      config = %{token: "abc123"}

      assert %{"token" => "abc123"} =
               Auth.build_subscribe_auth(:rest_token, @creds, config, "chan", nil)
    end

    test "rest_token returns nil when config[:token] is missing" do
      assert nil == Auth.build_subscribe_auth(:rest_token, @creds, %{}, "chan", nil)
    end

    test "inline_subscribe delegates to the module" do
      # InlineSubscribe needs a base64-encoded secret; verified in detail in its own test file
      secret_binary = :crypto.strong_rand_bytes(32)
      creds = %Credentials{api_key: "k", secret: Base.encode64(secret_binary)}
      config = %{timestamp_ms_override: 1_700_000_000_000}

      result =
        Auth.build_subscribe_auth(:inline_subscribe, creds, config, "level2", ["BTC-USD"])

      assert %{"key" => "k", "timestamp" => _, "signature" => _} = result
    end
  end

  describe "handle_auth_response/3 dispatch" do
    test "success responses by pattern" do
      assert :ok = Auth.handle_auth_response(:direct_hmac_expiry, %{"success" => true}, %{})

      assert :ok =
               Auth.handle_auth_response(
                 :iso_passphrase,
                 %{"event" => "login", "code" => "0"},
                 %{}
               )

      assert :ok =
               Auth.handle_auth_response(
                 :sha384_nonce,
                 %{"event" => "auth", "status" => "OK"},
                 %{}
               )

      assert :ok = Auth.handle_auth_response(:listen_key, %{}, %{})
      assert :ok = Auth.handle_auth_response(:rest_token, %{}, %{})
      assert :ok = Auth.handle_auth_response(:inline_subscribe, %{}, %{})
    end

    test "jsonrpc_linebreak extracts ttl_ms from expires_in" do
      response = %{
        "result" => %{"access_token" => "tok", "expires_in" => 900}
      }

      assert {:ok, %{ttl_ms: 900_000}} =
               Auth.handle_auth_response(:jsonrpc_linebreak, response, %{})
    end

    test "unknown pattern returns unknown_pattern error" do
      assert {:error, {:unknown_pattern, :oops}} =
               Auth.handle_auth_response(:oops, %{}, %{})
    end
  end

  describe "every pattern module implements the behaviour" do
    test "declares Bourse.WS.Auth.Behaviour in its attributes" do
      for pattern <- Auth.patterns() do
        module = Auth.module_for_pattern(pattern)
        behaviours = module.module_info(:attributes)[:behaviour] || []

        assert Bourse.WS.Auth.Behaviour in behaviours,
               "#{inspect(module)} is missing @behaviour Bourse.WS.Auth.Behaviour"
      end
    end
  end
end
