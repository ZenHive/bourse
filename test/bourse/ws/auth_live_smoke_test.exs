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

  The second half covers the handshake `Bourse.WS.connect/3` runs for a
  `:private` section, on all three frame-based venues. Those tests are
  deliberately *differential*: each subscribes to a private channel twice, once
  on an authenticated connection and once on `authenticate: false`. Asserting
  only that the authenticated call succeeds would pass just as well against a
  venue that never checked — the rejection on the unauthenticated connection is
  what proves the handshake is load-bearing.

  The binance family is covered too, and no part of it is a subscribe-ack
  venue. The two futures halves (`:listen_key`) authenticate before the socket
  exists — the key is a path segment — so the evidence is the issued key
  appearing in the URL, its refresh succeeding, and a key that is not the
  account's failing before any socket opens. binancecoinm additionally drives a
  real account event past both a socket keyed by its own listen key and one
  keyed by a decoy, because a wrong key connects and reports `:connected` while
  delivering nothing. binance spot (`:ws_api_signature`) opens its user data
  stream with a signed WS-API request, and is checked against a bad secret,
  which the venue rejects outright.

  Credentials: bybit + deribit testnet and okx demo keys must be registered via
  `Bourse.Testnet.register_all_from_env/1` in `test_helper.exs`. Tests flunk
  with setup instructions when credentials are missing — never silent skip.
  """

  use Bourse.Test.Case, async: false

  import Bourse.IntegrationHelper, only: [require_credentials!: 2]

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Auth
  alias Bourse.WS.ListenKey
  alias ZenWebsocket.Client, as: ZenClient

  @moduletag :network
  @moduletag :ws_auth_smoke
  @moduletag trace_messages: 200

  # 10 USD per contract and a wallet the UI faucet does not credit, so the
  # cheapest COIN-M instrument the demo account can margin is the one to write
  # the account-event probe against.
  @coinm_symbol "BCHUSD_PERP"

  # =============================================================================
  # bybit — :direct_hmac_expiry
  # =============================================================================

  describe "bybit :direct_hmac_expiry against testnet WS" do
    test "authenticates against wss://stream-testnet.bybit.com/v5/private" do
      creds = require_credentials!(:bybit, url: "https://testnet.bybit.com")
      exchange = Exchange.new!(:bybit, credentials: creds, sandbox: true)

      # `authenticate: false` — this test drives the handshake by hand to
      # exercise the pattern module; letting connect/3 do it first makes the
      # manual frame a second one (bybit answers "Repeat auth").
      {:ok, ws} = WS.connect(exchange, :private, authenticate: false)

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

      # `authenticate: false` — this test drives the handshake by hand to
      # exercise the pattern module in isolation, so connect/3 must not have
      # already run one.
      {:ok, ws} = WS.connect(exchange, :private, authenticate: false)

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

  # =============================================================================
  # connect/3 — the handshake a caller actually gets
  # =============================================================================

  describe "connect/3 authenticates a :private section" do
    test "bybit private subscribe is accepted only on the authenticated connection" do
      creds = require_credentials!(:bybit, url: "https://testnet.bybit.com")
      exchange = Exchange.new!(:bybit, credentials: creds, sandbox: true)

      assert :ok = private_subscribe(exchange, ["order"], authenticate: true)

      assert {:error, {:subscription_rejected, %{"ret_msg" => ret_msg}}} =
               private_subscribe(exchange, ["order"], authenticate: false)

      assert ret_msg =~ "not authorized"
    end

    test "deribit echoes the subscribed channel back only when authenticated" do
      creds = require_credentials!(:deribit, url: "https://test.deribit.com")
      exchange = Exchange.new!(:deribit, credentials: creds, sandbox: true)

      assert :ok = private_subscribe(exchange, ["user.portfolio.btc"], authenticate: true)

      # Deribit reports the refusal as an empty `result` list in an envelope
      # otherwise identical to success — see Bourse.WS.SubscribeAck.
      assert {:error, {:subscription_rejected, %{"result" => []}}} =
               private_subscribe(exchange, ["user.portfolio.btc"], authenticate: false)
    end

    test "okx private subscribe is accepted only on the authenticated connection" do
      creds = require_credentials!(:okx, url: "https://www.okx.com", passphrase: true)
      exchange = Exchange.new!(:okx, credentials: creds, sandbox: true)
      channels = [%{"channel" => "orders", "instType" => "ANY"}]

      assert :ok = private_subscribe(exchange, channels, authenticate: true)

      assert {:error, {:subscription_rejected, %{"code" => "60011"}}} =
               private_subscribe(exchange, channels, authenticate: false)
    end

    test "a bad secret fails the connection with the venue's reason" do
      creds = require_credentials!(:bybit, url: "https://testnet.bybit.com")
      wrong = %{creds | secret: "not-the-real-secret"}
      exchange = Exchange.new!(:bybit, credentials: wrong, sandbox: true)

      # The socket opens — bybit only judges the signature — so this is exactly
      # the case that used to hand back a live, useless connection.
      assert {:error, {:auth_failed, %{"op" => "auth", "success" => false} = frame}} =
               WS.connect(exchange, :private)

      assert frame["ret_msg"] =~ "sign"
    end

    test "binance spot opens the user data stream with a signed WS-API request" do
      creds = require_credentials!(:binance, url: "https://testnet.binance.vision")
      exchange = Exchange.new!(:binance, credentials: creds, sandbox: true)

      {:ok, ws} = WS.connect(exchange, :private)

      try do
        assert ws.url =~ "ws-api"
        assert %{pattern: :ws_api_signature} = ws.auth
      after
        WS.close(ws)
      end

      # The same connection without the request: the venue accepts the socket
      # and sends nothing, which is the whole failure class this guards.
      {:ok, unauthenticated} = WS.connect(exchange, :private, authenticate: false)
      assert unauthenticated.auth == nil
      WS.close(unauthenticated)
    end

    test "binance spot rejects a bad secret rather than returning a silent socket" do
      creds = require_credentials!(:binance, url: "https://testnet.binance.vision")
      exchange = Exchange.new!(:binance, credentials: %{creds | secret: "not-the-real-secret"}, sandbox: true)

      assert {:error, {:auth_failed, message}} = WS.connect(exchange, :private)
      assert message =~ "Signature"
    end

    test "binanceusdm carries an issued listen key in the connect URL" do
      creds = require_credentials!(:binanceusdm, url: "https://demo-fapi.binance.com")
      exchange = Exchange.new!(:binanceusdm, credentials: creds, sandbox: true)

      {:ok, ws} = WS.connect(exchange, :private)

      try do
        assert %{pattern: :listen_key, meta: session} = ws.auth
        assert ws.url =~ session.listen_key
        assert session.market_type == :linear

        # The refresh has to work on the key the socket was built from — a
        # connection whose key silently expires stops delivering without error.
        assert :ok = ListenKey.keepalive(exchange, session)
      after
        WS.close(ws)
      end
    end

    test "binanceusdm fails before the socket when the key is not the account's" do
      creds = require_credentials!(:binanceusdm, url: "https://demo-fapi.binance.com")
      exchange = Exchange.new!(:binanceusdm, credentials: %{creds | api_key: "not-a-real-api-key"}, sandbox: true)

      # The listen key endpoint is API-key authenticated and does not check the
      # secret, so the api key is the credential that has to be wrong here for
      # the rejection to mean anything.
      assert {:error, %Bourse.Error{type: :authentication_error}} = WS.connect(exchange, :private)
    end

    test "binancecoinm carries a delivery listen key issued from its own wallet" do
      creds = require_credentials!(:binancecoinm, url: "https://demo-dapi.binance.com")
      exchange = Exchange.new!(:binancecoinm, credentials: creds, sandbox: true)

      {:ok, ws} = WS.connect(exchange, :private)

      try do
        assert %{pattern: :listen_key, meta: session} = ws.auth
        assert ws.url =~ session.listen_key
        # USD-M and COIN-M are two wallets inside one demo account, each with
        # its own stream — a linear key here connects and delivers nothing.
        assert session.market_type == :inverse
        assert ws.url =~ "dstream"

        assert :ok = ListenKey.keepalive(exchange, session)
      after
        WS.close(ws)
      end
    end

    @tag :dangerous
    test "binancecoinm account events reach the keyed socket and no other" do
      creds = require_credentials!(:binancecoinm, url: "https://demo-dapi.binance.com")
      exchange = Exchange.new!(:binancecoinm, credentials: creds, sandbox: true)

      # The control leg is a syntactically valid key that is not the account's,
      # collected in its own process so the two streams stay distinguishable.
      # The venue accepts the socket and reports :connected either way, so a
      # single-leg "events arrived" assertion would pass against a connection
      # that never carried a credential at all.
      decoy = Task.async(fn -> collect_decoy_frames(String.duplicate("a", 64), 20_000) end)
      {:ok, ws} = WS.connect(exchange, :private)

      try do
        order_id = place_resting_coinm_order(exchange)
        assert {:ok, _} = cancel_coinm_order(exchange, order_id)

        assert_receive {:websocket_message, %{"e" => "ORDER_TRADE_UPDATE", "o" => %{"X" => "NEW"}}}, 15_000

        assert_receive {:websocket_message, %{"e" => "ORDER_TRADE_UPDATE", "o" => %{"X" => "CANCELED"}}},
                       15_000

        assert %{state: :connected, frames: []} = Task.await(decoy, 30_000)
      after
        WS.close(ws)
      end
    end

    test "binanceusdm refuses to hand back a private connection with auth opted out" do
      creds = require_credentials!(:binanceusdm, url: "https://demo-fapi.binance.com")
      exchange = Exchange.new!(:binanceusdm, credentials: creds, sandbox: true)

      assert {:error, {:auth_not_optional, :listen_key}} =
               WS.connect(exchange, :private, authenticate: false)
    end
  end

  # A limit buy well under the mark, so it rests instead of filling — the point
  # is the ORDER_TRADE_UPDATE the venue emits, not a position.
  defp place_resting_coinm_order(exchange) do
    {:ok, %{body: [%{"price" => mark} | _]}} =
      Bourse.Binancecoinm.dapiPublic_get_ticker_price(exchange, %{"symbol" => @coinm_symbol})

    {mark, ""} = Float.parse(mark)
    price = :erlang.float_to_binary(Float.round(mark * 0.7, 2), decimals: 2)

    {:ok, %{body: %{"orderId" => order_id}}} =
      Bourse.Binancecoinm.dapiPrivate_post_order(exchange, %{
        "symbol" => @coinm_symbol,
        "side" => "BUY",
        # The demo futures account runs Hedge Mode; omitting positionSide is -4061.
        "positionSide" => "LONG",
        "type" => "LIMIT",
        "timeInForce" => "GTC",
        "quantity" => "1",
        "price" => price
      })

    order_id
  end

  defp cancel_coinm_order(exchange, order_id) do
    Bourse.Binancecoinm.dapiPrivate_delete_order(exchange, %{"symbol" => @coinm_symbol, "orderId" => order_id})
  end

  defp collect_decoy_frames(listen_key, timeout_ms) do
    {:ok, client} = ZenClient.connect("wss://demo-dstream.binance.com/ws/" <> listen_key)

    try do
      Process.sleep(timeout_ms)
      %{state: ZenClient.get_state(client), frames: drain_frames([])}
    after
      ZenClient.close(client)
    end
  end

  defp drain_frames(acc) do
    receive do
      {:websocket_message, frame} -> drain_frames([frame | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp private_subscribe(exchange, channels, opts) do
    {:ok, ws} = WS.connect(exchange, :private, authenticate: Keyword.fetch!(opts, :authenticate))

    try do
      WS.subscribe(ws, channels)
    after
      WS.close(ws)
    end
  end
end
