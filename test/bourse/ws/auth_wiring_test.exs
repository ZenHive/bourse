defmodule Bourse.WS.AuthWiringTest do
  @moduledoc """
  Offline contract for `Bourse.WS.authenticate/2` and the `:private` handshake
  `connect/3` runs.

  The gap this covers: `Bourse.WS.Adapter` held the auth state machine and the
  facade never called it, so `Bourse.WS.connect(exchange, :private)` returned an
  open, unauthenticated socket. Subscriptions on it are accepted and then
  deliver nothing, which is why every assertion here is about the handshake
  producing an *outcome* rather than about it merely being attempted.

  Live confirmation against bybit / deribit / okx lives in
  `Bourse.WS.AuthLiveSmokeTest`.
  """

  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.WS
  alias ZenWebsocket.Client

  defmodule Transport do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok, %{owner: Keyword.fetch!(opts, :owner), reply: Keyword.get(opts, :reply, :ok)}}
    end

    @impl true
    def handle_call({:send_message, message}, _from, state) do
      send(state.owner, {:transport_sent, message})
      {:reply, state.reply, state}
    end

    def handle_call(:get_state, _from, state), do: {:reply, :connected, state}
    def handle_call(:close, _from, state), do: {:reply, :ok, state}
  end

  describe "authenticate/2 on an asynchronous venue (bybit :direct_hmac_expiry)" do
    test "accepts the venue's success frame and reports session metadata" do
      ws = connected_ws("bybit", reply: :ok)

      send(self(), {:websocket_message, %{"op" => "auth", "success" => true}})

      assert {:ok, %{}} = WS.authenticate(ws)
      assert_received {:transport_sent, sent}
      assert %{"op" => "auth", "args" => [_key, _expires, _signature]} = Jason.decode!(sent)
    end

    test "surfaces a credential rejection instead of reporting success" do
      ws = connected_ws("bybit", reply: :ok)

      rejection = %{"op" => "auth", "success" => false, "ret_msg" => "error:api_key invalid"}
      send(self(), {:websocket_message, rejection})

      assert {:error, {:auth_failed, _}} = WS.authenticate(ws)
    end

    test "data frames arriving before the verdict are re-queued, not misjudged" do
      ws = connected_ws("bybit", reply: :ok)

      # Every pattern module's handle_auth_response/2 ends in a catch-all that
      # reads an unknown frame as {:auth_failed, frame}. Without the AuthAck
      # discriminator, this tick would fail the handshake.
      tick = %{"topic" => "tickers.BTCUSDT", "data" => %{"lastPrice" => "1"}}
      send(self(), {:websocket_message, tick})
      send(self(), {:websocket_message, %{"op" => "auth", "success" => true}})

      assert {:ok, %{}} = WS.authenticate(ws)

      # The caller's own receive loop must still see the tick it never asked us
      # to consume.
      assert_received {:websocket_message, ^tick}
    end

    test "returns a timeout rather than blocking when no verdict arrives" do
      ws = connected_ws("bybit", reply: :ok)

      assert {:error, :auth_ack_timeout} = WS.authenticate(ws, auth_timeout_ms: 20)
    end

    test "a zero window reports the timeout without waiting on the mailbox" do
      ws = connected_ws("bybit", reply: :ok)

      assert {:error, :auth_ack_timeout} = WS.authenticate(ws, auth_timeout_ms: 0)
    end

    test "reads the verdict from an unmatched-response frame too" do
      ws = connected_ws("bybit", reply: :ok)

      # zen_websocket delivers a reply it could not correlate under a different
      # tag; the handshake must still recognise it as the verdict.
      send(self(), {:websocket_unmatched_response, %{"op" => "auth", "success" => true}})

      assert {:ok, %{}} = WS.authenticate(ws)
    end

    test "surfaces a transport failure instead of waiting out the window" do
      ws = connected_ws("bybit", reply: {:error, :closed})

      assert {:error, :closed} = WS.authenticate(ws)
    end
  end

  describe "connect/3 on Alpaca's authenticated public stream" do
    test "authenticates before returning the public connection" do
      transport = start_supervised!({Transport, owner: self(), reply: :ok})
      client = %Client{server_pid: transport, state: :connected}
      connect_fun = fn _url, _opts -> {:ok, client} end

      connected = [%{"T" => "success", "msg" => "connected"}]
      authenticated = [%{"T" => "success", "msg" => "authenticated"}]
      send(self(), {:websocket_message, connected})
      send(self(), {:websocket_message, authenticated})

      exchange =
        Exchange.new!("alpaca",
          credentials: Credentials.new!(api_key: "test-key", secret: "test-secret"),
          sandbox: true
        )

      assert {:ok, ws} = WS.connect(exchange, :public, connect_fun: connect_fun)
      assert %{pattern: :action_key_secret, meta: %{}} = ws.auth
      assert_received {:transport_sent, payload}

      assert Jason.decode!(payload) == %{
               "action" => "auth",
               "key" => "test-key",
               "secret" => "test-secret"
             }

      assert_received {:websocket_message, ^connected}
      assert :ok = WS.close(ws)
    end
  end

  describe "authenticate/2 on a correlated venue (deribit :jsonrpc_linebreak)" do
    test "reads the session TTL out of the correlated reply" do
      reply = {:ok, %{"result" => %{"access_token" => "tok", "expires_in" => 900}}}
      ws = connected_ws("deribit", reply: reply)

      assert {:ok, %{ttl_ms: 900_000}} = WS.authenticate(ws)
      assert_received {:transport_sent, sent}
      assert %{"method" => "public/auth", "id" => id} = Jason.decode!(sent)
      assert is_integer(id)
    end

    test "surfaces the venue's error object" do
      reply = {:ok, %{"error" => %{"code" => 13_009, "message" => "unauthorized"}}}
      ws = connected_ws("deribit", reply: reply)

      assert {:error, {:auth_failed, %{"code" => 13_009}}} = WS.authenticate(ws)
    end
  end

  describe "authenticate/2 on okx (:iso_passphrase)" do
    test "accepts the login event" do
      ws = connected_ws("okx", reply: :ok, password: "passphrase")

      send(self(), {:websocket_message, %{"event" => "login", "code" => "0"}})

      assert {:ok, %{}} = WS.authenticate(ws)
    end

    test "treats an error event as the verdict, not as noise" do
      ws = connected_ws("okx", reply: :ok, password: "passphrase")

      send(self(), {:websocket_message, %{"event" => "error", "code" => "60009", "msg" => "Login failed."}})

      assert {:error, {:auth_failed, "Login failed."}} = WS.authenticate(ws)
    end
  end

  describe "authenticate/2 refusals" do
    test "names the missing credentials rather than sending an unsigned frame" do
      ws = connected_ws("bybit", reply: :ok, credentials: false)

      assert {:error, :no_credentials} = WS.authenticate(ws)
      refute_received {:transport_sent, _}
    end

    test "reports no_auth_pattern for a venue whose spec authors no handshake" do
      ws = connected_ws("hyperliquid", reply: :ok)

      assert {:error, :no_auth_pattern} = WS.authenticate(ws)
    end
  end

  describe "binance spot (:ws_api_signature)" do
    test "signs the WS-API request that opens the user data stream" do
      ws = connected_ws("binance", reply: {:ok, %{"id" => "1", "status" => 200, "result" => %{}}})

      assert {:ok, %{}} = WS.authenticate(ws)
      assert_received {:transport_sent, sent}

      assert %{"method" => "userDataStream.subscribe.signature", "params" => params} =
               Jason.decode!(sent)

      assert %{"apiKey" => "test-key", "timestamp" => timestamp, "signature" => signature} = params
      assert is_integer(timestamp)

      # The venue checks the signature over the parameters sorted by name, so a
      # signature computed over any other ordering is the failure to catch here
      # rather than at the venue.
      expected =
        :hmac
        |> :crypto.mac(:sha256, "test-secret", "apiKey=test-key&timestamp=#{timestamp}")
        |> Base.encode16(case: :lower)

      assert signature == expected
    end

    test "surfaces a non-200 status as the venue's rejection" do
      reply = {:ok, %{"id" => "1", "status" => 401, "error" => %{"msg" => "Signature invalid."}}}
      ws = connected_ws("binance", reply: reply)

      assert {:error, {:auth_failed, "Signature invalid."}} = WS.authenticate(ws)
    end
  end

  describe "binance futures (:listen_key)" do
    test "refuses to open a private connection with the handshake opted out" do
      # The key is a path segment of the URL, so there is no later handshake to
      # run — honouring `authenticate: false` would hand back a socket that is
      # accepted by the venue and then never delivers.
      exchange = Exchange.new!("binanceusdm", credentials: Credentials.new!(api_key: "k", secret: "s"))

      assert {:error, {:auth_not_optional, :listen_key}} =
               WS.connect(exchange, :private, authenticate: false)
    end

    test "reports the venue's refusal to issue a key instead of opening a socket" do
      stub = {__MODULE__, :listen_key_denied, System.unique_integer([:positive])}

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"code" => -2_015, "msg" => "Invalid API-key, IP, or permissions."})
      end)

      exchange = Exchange.new!("binanceusdm", credentials: Credentials.new!(api_key: "k", secret: "s"))

      assert {:error, %Bourse.Error{code: -2_015}} =
               WS.connect(exchange, :private, pre_auth_opts: [plug: {Req.Test, stub}])
    end

    test "reports the round-trip when asked to authenticate a socket built without one" do
      # A hand-built connection has no key embedded, so the pattern reports what
      # it needs rather than pretending the socket is authenticated.
      ws = connected_ws("binanceusdm", reply: :ok)

      assert {:error, {:pre_auth_required, %{endpoint: :fapiPrivate_post_listenkey}}} =
               WS.authenticate(ws)
    end

    test "binancecoinm resolves its own endpoints rather than the linear ones" do
      # One demo account, two wallets: a COIN-M socket keyed by a fapi listen
      # key connects and then delivers nothing, because the key belongs to the
      # other wallet's stream.
      ws = connected_ws("binancecoinm", reply: :ok)

      assert {:error, {:pre_auth_required, %{endpoint: :dapiPrivate_post_listenkey}}} =
               WS.authenticate(ws)
    end

    test "reports the session already held rather than issuing a second key" do
      session = %{
        listen_key: "abc",
        market_type: :linear,
        keepalive_endpoint: :fapiPrivate_put_listenkey,
        keepalive_ms: 1
      }

      ws = %{connected_ws("binanceusdm", reply: :ok) | auth: %{pattern: :listen_key, meta: session}}

      assert {:ok, ^session} = WS.authenticate(ws)
      refute_received {:transport_sent, _}
    end
  end

  defp connected_ws(exchange_id, opts) do
    transport = start_supervised!({Transport, owner: self(), reply: Keyword.get(opts, :reply, :ok)})

    exchange =
      if Keyword.get(opts, :credentials, true) do
        Exchange.new!(exchange_id,
          credentials:
            Credentials.new!(
              api_key: "test-key",
              secret: "test-secret",
              password: Keyword.get(opts, :password)
            )
        )
      else
        Exchange.new!(exchange_id)
      end

    %WS{
      exchange: exchange,
      zen_client: %Client{server_pid: transport, state: :connected},
      url: "wss://offline.test",
      section: :private
    }
  end
end
