defmodule Bourse.WS.AuthLiveSmokeTest do
  @moduledoc """
  Opt-in live auth smoke tests — exercise the auth frames built by T93 pattern
  modules against real exchange sandboxes. Excluded by default; run with:

      mix test --include network --include ws_auth_smoke

  Covers:

    * bybit (`:direct_hmac_expiry`) — connect private WS, send auth frame,
      expect `{"op" => "auth", "success" => true}`.
    * deribit (`:jsonrpc_linebreak`) — connect testnet WS, send JSON-RPC
      `public/auth`, expect correlated `access_token` in the reply.

  binance `:listen_key` is covered by its unit test (`pre_auth/3` is pure
  endpoint resolution — no WS frame) and will be exercised end-to-end through
  the adapter in T94.

  Credentials: bybit + deribit testnet keys must be registered via
  `Bourse.Testnet.register_all_from_env/1` in `test_helper.exs`. Tests flunk
  with setup instructions when credentials are missing — never silent skip.
  """

  use Bourse.Test.Case, async: false

  import Bourse.IntegrationHelper, only: [require_credentials!: 2]

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Auth
  alias ZenWebsocket.Client, as: ZenClient

  @moduletag :network
  @moduletag :ws_auth_smoke
  @moduletag trace_messages: 200

  # =============================================================================
  # bybit — :direct_hmac_expiry
  # =============================================================================

  describe "bybit :direct_hmac_expiry against testnet WS" do
    test "authenticates against wss://stream-testnet.bybit.com/v5/private" do
      creds = require_credentials!(:bybit, url: "https://testnet.bybit.com")
      exchange = Exchange.new!(:bybit, credentials: creds, sandbox: true)

      {:ok, ws} = WS.connect(exchange, :private)

      {:ok, frame} = Auth.build_auth_message(:direct_hmac_expiry, creds, %{}, [])
      payload = Jason.encode!(frame)

      # bybit's auth frame has no "id" → send_message returns :ok, the reply
      # arrives in the caller's mailbox as {:websocket_message, %{…}}.
      assert :ok = ZenClient.send_message(ws.zen_client, payload)

      assert_receive {:websocket_message, %{"op" => "auth"} = response}, 10_000

      # A well-formed auth frame that reaches bybit must produce success: true.
      # Credential rejection (success: false) is an actionable state — refresh
      # testnet keys — not a passing outcome.
      case Auth.handle_auth_response(:direct_hmac_expiry, response, %{}) do
        :ok ->
          :ok

        {:error, {:auth_failed, %{"op" => "auth", "success" => false} = err}} ->
          flunk("""
          bybit testnet auth rejected the signed frame: #{inspect(err["ret_msg"])}

          The frame was well-formed (bybit parsed it and returned a structured
          response), but the configured credentials were rejected. Refresh the
          testnet keys at https://testnet.bybit.com and re-run:

            export BYBIT_TESTNET_API_KEY=...
            export BYBIT_TESTNET_API_SECRET=...
          """)

        other ->
          flunk("Unexpected bybit auth response: #{inspect(other)}")
      end

      WS.close(ws)
    end
  end

  # =============================================================================
  # deribit — :jsonrpc_linebreak
  # =============================================================================

  describe "deribit :jsonrpc_linebreak against testnet WS" do
    test "authenticates against wss://test.deribit.com/ws/api/v2" do
      creds = require_credentials!(:deribit, url: "https://test.deribit.com")
      exchange = Exchange.new!(:deribit, credentials: creds, sandbox: true)

      {:ok, ws} = WS.connect(exchange, :private)

      {:ok, frame} =
        Auth.build_auth_message(:jsonrpc_linebreak, creds, %{}, request_id: :erlang.unique_integer([:positive]))

      payload = Jason.encode!(frame)

      # Deribit auth frame carries an "id" → send_message blocks and returns the
      # correlated reply via ZenWebsocket's request correlation.
      assert {:ok, response} = ZenClient.send_message(ws.zen_client, payload)

      assert %{"result" => %{"access_token" => token, "expires_in" => expires_in}} = response
      assert is_binary(token) and byte_size(token) > 0
      assert is_integer(expires_in) and expires_in > 0

      # handle_auth_response/2 must extract ttl_ms for re-auth scheduling.
      assert {:ok, %{ttl_ms: ttl_ms}} =
               Auth.handle_auth_response(:jsonrpc_linebreak, response, %{})

      assert ttl_ms == expires_in * 1_000

      WS.close(ws)
    end
  end
end
