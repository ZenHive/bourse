defmodule Bourse.WS do
  @moduledoc """
  WebSocket entry point. Thin wrapper around `ZenWebsocket.Client` that binds
  a `%Bourse.Exchange{}` to a connection so `subscribe/3` can pick the correct
  exchange-native frame builder.

  ## Structure

  Pure URL resolution (`Bourse.WS.URLRouting`) + connection lifecycle (this
  module). `connect/3` authenticates a `:private` section before returning it,
  so the socket a caller holds is one the venue accepted; `authenticate/2`
  exposes the same handshake for callers driving it themselves. Reconnection,
  backoff, heartbeat, and subscription restoration come from `zen_websocket`.

  `Bourse.WS.Adapter` adds what a long-lived process needs on top: auth state,
  re-auth before session expiry, and routing frames onto `Bourse.WS.Broadcast`.

  ## Usage

      {:ok, ws} = Bourse.WS.connect(exchange, :public)
      {:ok, sub} = Bourse.WS.watch_ticker(ws, "BTC/USDT")
      :ok = Bourse.WS.unsubscribe(sub)
      :ok = Bourse.WS.close(ws)

  Lower-level subscribe with pre-formatted channels still works:

      :ok = Bourse.WS.subscribe(ws, ["tickers.BTCUSDT"])
      # Market data arrives as {:websocket_message, decoded_map}. Heartbeat
      # replies and other transport control arrive as {:websocket_unmatched_response, _}.
      {:ok, observations} = Bourse.WS.health(ws)
      Bourse.WS.close(ws)

  ## Subscribe return shape (unified)

  `subscribe/3` always returns `:ok | {:error, term()}` across venues:

  - `:ok` — the venue accepted the subscription, or acknowledgement waiting was
    explicitly disabled with `ack_timeout_ms: 0`
  - `{:error, {:subscription_rejected, frame}}` — the venue rejected it; `frame`
    is the raw exchange envelope
  - `{:error, :subscription_ack_timeout}` — no accept/reject outcome arrived
    within the acknowledgement window
  - `{:error, reason}` — build/send failures (`:websocket_not_configured`,
    `:unsupported_exchange`, channel shape errors, transport errors, …)

  Channels that span more than one authored host are one call: every host is
  accepted, or hosts that already succeeded are unsubscribed and the failing
  host's error is returned. A retry of the same list does not stack a leftover
  subscription on the host that worked.

  Correlated JSON-RPC replies (deribit) and asynchronous acks (alpaca, bybit,
  okx, hyperliquid, derive, binance, lighter, coinbaseexchange) are classified by
  `Bourse.WS.SubscribeAck`.
  Rejection frames that arrive asynchronously are still consumed and returned
  as errors; non-ack data frames that arrive during the wait are re-queued to
  the caller mailbox. Lighter's `subscribed/*` reply is both the acknowledgement
  and the first snapshot, so it is re-queued after `subscribe/3` returns `:ok`.

  ## Scope

  All eleven runtime venues have WS transport config. Coinbase Exchange is
  public-only (matches and heartbeat on the Exchange feed, no credentials).
  """

  alias Bourse.Exchange
  alias Bourse.WS.Auth
  alias Bourse.WS.AuthAck
  alias Bourse.WS.Channels
  alias Bourse.WS.Config
  alias Bourse.WS.ConnectionOwner
  alias Bourse.WS.ControlFrame
  alias Bourse.WS.Handle
  alias Bourse.WS.Heartbeat
  alias Bourse.WS.ListenKey
  alias Bourse.WS.SubscribeAck
  alias Bourse.WS.Subscription
  alias Bourse.WS.URLRouting
  alias ZenWebsocket.Client, as: ZenClient

  # Default window to wait for an async subscribe ack/rejection after send.
  @default_ack_timeout_ms 3_000

  # Auth replies cross the same socket as subscribe acks but sit behind a
  # signature check on the venue side, so they get their own, longer window.
  @default_auth_timeout_ms 10_000

  @default_connection_timeout_ms 5_000
  @connection_owner_timeout_buffer_ms 5_000

  # Telemetry helpers (outbound WS messages)
  defp emit_ws_send(%Exchange{id: id}, section) do
    :telemetry.execute(
      Bourse.Telemetry.ws_send(),
      %{system_time: System.system_time()},
      %{exchange: id, section: section}
    )
  end

  @type section :: :public | :private

  @enforce_keys [:exchange, :zen_client, :url, :section]
  defstruct [
    :exchange,
    :zen_client,
    :url,
    :section,
    :connection_owner,
    auth: nil,
    connect_opts: [],
    connect_fun: &ZenClient.connect/2
  ]

  @typedoc """
  What the venue disclosed about the accepted handshake.

  `nil` on a public connection, and on a private one opened with
  `authenticate: false`. Present, it names the pattern that succeeded and
  carries the pattern's own metadata — a `ttl_ms` where the venue discloses
  one, the listen key session where the credential lives in the URL, the
  derive subaccount list after `public/login`. `Bourse.WS.Adapter` reads it
  to schedule renewal without re-running the handshake to find out.
  """
  @type auth_info :: %{pattern: Auth.pattern(), meta: map()}

  @type t :: %__MODULE__{
          exchange: Exchange.t(),
          zen_client: ZenClient.t(),
          url: String.t(),
          section: section(),
          auth: auth_info() | nil,
          connection_owner: pid() | nil,
          connect_opts: keyword(),
          connect_fun: (String.t(), keyword() -> {:ok, ZenClient.t()} | {:error, term()})
        }

  @typedoc """
  One socket's liveness observation from `health/1`.

  `heartbeat` is the locked dependency's `get_heartbeat_health/1` map, or
  `nil` when the client process cannot be queried.
  """
  @type socket_health :: %{
          url: String.t(),
          role: :primary | :routed,
          connection_state: :connecting | :connected | :disconnected,
          heartbeat: map() | nil
        }

  @doc """
  Connects to the exchange's WebSocket endpoint for the given section
  (`:public` or `:private`).

  Extra opts are forwarded to `ZenWebsocket.Client.connect/2`. The connection's
  heartbeat config is resolved from `Bourse.WS.Config` unless the caller overrides
  `heartbeat_config` in opts. Only `:deribit` and `:ping_pong` are accepted;
  unsupported types return `{:error, {:unsupported_heartbeat, type}}`.
  `connect_fun:` replaces `ZenWebsocket.Client.connect/2`
  for instrumented transports and is reused for authored secondary hosts.

  Returns `{:error, :websocket_not_configured}` if a runtime-supported exchange
  has no WS config, `{:error, :unsupported_exchange}` if the exchange itself is
  unsupported, or `{:error, :no_url_configured}` if the requested section is
  absent.

  ## Private connections authenticate

  A `:private` connection runs the venue's auth handshake before it is handed
  back, so a socket a caller holds is one the venue has accepted. A handshake
  that fails closes the socket and surfaces the venue's reason — an open but
  unauthenticated private connection is never returned, because the failure it
  produces later is a silently empty stream rather than an error.

  A `:private` section whose authored spec declares no `auth_pattern` is an
  error (`:no_auth_pattern`): the socket is closed rather than returned. The
  one runtime venue with a `nil` pattern *and* a working private stream is
  hyperliquid, and it has no private URL — its private subscriptions are
  scoped by address on the public socket, which is a different condition.

  Pass `authenticate: false` to skip the handshake and drive it yourself with
  `authenticate/2`; the connection is then unauthenticated until you do.

  Alpaca's public market-data socket also requires its key/secret handshake;
  its config declares `:public` in `auth_sections`, so the same guarantee
  applies there without enabling the private trading stream.

  ## Credentials that live in the URL

  The `:listen_key` venues (binance USD-M and COIN-M) authenticate before the
  socket exists: the venue issues a key over REST and it travels in the URL.
  USD-M uses the provider's `listenKey` and `events` query parameters; COIN-M
  keeps its path segment. `connect/3` performs that round-trip and connects to
  the resulting URL, so there is nothing left to authenticate afterwards and
  `authenticate: false` is refused with `{:error, {:auth_not_optional,
  :listen_key}}` rather than silently returning a stream that delivers nothing.
  """
  @spec connect(Exchange.t(), section(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(%Exchange{} = exchange, section, opts \\ []) when section in [:public, :private] do
    {auth?, connect_opts} = Keyword.pop(opts, :authenticate, true)
    {connect_fun, connect_opts} = Keyword.pop(connect_opts, :connect_fun, &ZenClient.connect/2)

    with {:ok, config} <- fetch_config(exchange),
         {:ok, url} <- fetch_url(exchange, section),
         {:ok, url, auth} <- maybe_embed_credential(exchange, config, section, auth?, url, connect_opts),
         {:ok, zen_opts} <- build_connect_opts(config, connect_opts),
         {:ok, zen_client} <- connect_fun.(url, zen_opts),
         {:ok, connection_owner} <- own_connection(url, zen_client) do
      ws = %__MODULE__{
        exchange: exchange,
        zen_client: zen_client,
        url: url,
        section: section,
        auth: auth,
        connection_owner: connection_owner,
        connect_opts: zen_opts,
        connect_fun: connect_fun
      }

      maybe_authenticate(ws, config, section, auth?, connect_opts)
    end
  end

  # A listen key lives in the URL, so it has to be resolved before the socket
  # opens; every other pattern leaves the URL alone and authenticates over the
  # open connection.
  defp maybe_embed_credential(exchange, %{auth_pattern: :listen_key} = config, :private, true, url, opts) do
    case ListenKey.open(exchange, Map.get(config, :auth_config, %{}), listen_key_opts(opts)) do
      {:ok, session} ->
        {:ok, embed_listen_key(url, session.listen_key, config.auth_config.listen_key_url),
         %{pattern: :listen_key, meta: session}}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_embed_credential(_exchange, %{auth_pattern: :listen_key}, :private, false, _url, _opts) do
    {:error, {:auth_not_optional, :listen_key}}
  end

  defp maybe_embed_credential(_exchange, _config, _section, _auth?, url, _opts), do: {:ok, url, nil}

  defp embed_listen_key(url, listen_key, %{placement: :query, events: [_ | _] = events}) do
    query =
      "listenKey=#{URI.encode_www_form(listen_key)}&events=#{Enum.map_join(events, "/", &URI.encode_www_form/1)}"

    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> query
  end

  defp embed_listen_key(url, listen_key, %{placement: :path}), do: join_path(url, listen_key)

  defp join_path(url, segment), do: String.trim_trailing(url, "/") <> "/" <> segment

  # The listen key round-trip is an HTTP request of its own, so `:pre_auth_opts`
  # carries what belongs to it — a timeout, a base URL override — rather than
  # letting request options leak into the WebSocket connect options.
  defp listen_key_opts(opts) do
    Keyword.take(opts, [:market_type]) ++ Keyword.get(opts, :pre_auth_opts, [])
  end

  defp maybe_authenticate(%__MODULE__{auth: %{}} = ws, _config, :private, true, _opts), do: {:ok, ws}

  defp maybe_authenticate(ws, config, section, true, opts) do
    if section == :private or section in Map.get(config, :auth_sections, []) do
      case authenticate(ws, opts) do
        {:ok, meta} ->
          {:ok, %{ws | auth: %{pattern: pattern_of(ws), meta: meta}}}

        {:error, reason} ->
          close(ws)
          {:error, reason}
      end
    else
      {:ok, ws}
    end
  end

  defp maybe_authenticate(ws, _config, _section, _auth?, _opts), do: {:ok, ws}

  defp pattern_of(%__MODULE__{exchange: exchange}) do
    case fetch_config(exchange) do
      {:ok, %{auth_pattern: pattern}} -> pattern
      _ -> nil
    end
  end

  @doc """
  Runs the venue's auth handshake on an open connection.

  Called for you by `connect/3` on a `:private` section; call it directly only
  after `connect(exchange, :private, authenticate: false)`, or to re-authenticate
  a connection whose credentials have expired.

  Returns `{:ok, meta}` where `meta` carries whatever the venue disclosed about
  the session — `%{ttl_ms: milliseconds}` on deribit, `%{}` where the venue says
  nothing. A caller that wants to re-authenticate before expiry reads `ttl_ms`;
  `Bourse.WS.Adapter` does exactly that.

  Errors:

  - `{:error, :no_auth_pattern}` — the authored spec declares no handshake
  - `{:error, :no_credentials}` — the exchange carries none
  - `{:error, {:pre_auth_required, data}}` — the pattern needs a REST
    round-trip first (`:rest_token`), which this function does not perform.
    `:listen_key` is not in that set: `connect/3` resolves it, and calling this
    on such a connection returns the session it already holds.
  - `{:error, {:auth_failed, reason}}` — the venue rejected the credentials
  - `{:error, :auth_ack_timeout}` — no verdict arrived within the window

  Pass `auth_timeout_ms:` to change the wait (default 10_000).
  """
  @spec authenticate(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def authenticate(ws, opts \\ [])

  # The credential is the URL this socket was opened with; re-running the
  # handshake would issue a second key the open connection could not adopt.
  def authenticate(%__MODULE__{auth: %{pattern: :listen_key, meta: meta}}, _opts), do: {:ok, meta}

  def authenticate(%__MODULE__{exchange: exchange} = ws, opts) do
    with {:ok, config} <- fetch_config(exchange),
         {:ok, pattern} <- fetch_auth_pattern(config),
         {:ok, credentials} <- fetch_credentials(exchange),
         auth_opts = auth_opts(opts),
         {:ok, empty} when empty == %{} <-
           Auth.pre_auth(pattern, credentials, config.auth_config, auth_opts),
         {:ok, frame} <-
           Auth.build_auth_message(pattern, credentials, config.auth_config, auth_opts) do
      send_auth(ws, pattern, frame, auth_timeout_ms(opts))
    else
      # `:no_message` patterns authenticate by connecting (the credential is in
      # the URL or in each subscribe frame), so there is nothing to await.
      :no_message -> {:ok, %{}}
      {:ok, pre_auth} when is_map(pre_auth) -> {:error, {:pre_auth_required, pre_auth}}
      {:error, _} = error -> error
    end
  end

  defp send_auth(%__MODULE__{} = ws, pattern, frame, timeout_ms) do
    case send_message(ws, frame) do
      # Correlated venues (deribit) answer inline through the request id.
      {:ok, response} when is_map(response) -> adjudicate_auth(pattern, response)
      :ok -> await_auth_ack(pattern, timeout_ms)
      {:error, _} = error -> error
    end
  end

  defp await_auth_ack(pattern, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    classify = fn frame ->
      case AuthAck.classify(pattern, frame) do
        :auth_response -> {:take, :auth_response}
        :not_auth -> :skip
      end
    end

    case await_in_mailbox(classify, deadline) do
      {:auth_response, frame} -> adjudicate_auth(pattern, frame)
      :timeout -> {:error, :auth_ack_timeout}
    end
  end

  defp adjudicate_auth(pattern, response) do
    case Auth.handle_auth_response(pattern, response, %{}) do
      :ok -> {:ok, %{}}
      {:ok, meta} when is_map(meta) -> {:ok, meta}
      {:error, _} = error -> error
    end
  end

  defp fetch_auth_pattern(%{auth_pattern: nil}), do: {:error, :no_auth_pattern}
  defp fetch_auth_pattern(%{auth_pattern: pattern}), do: {:ok, pattern}

  defp fetch_credentials(%Exchange{credentials: nil}), do: {:error, :no_credentials}
  defp fetch_credentials(%Exchange{credentials: credentials}), do: {:ok, credentials}

  # Deribit correlates its reply by request id, so every handshake needs one
  # that has not been used on this socket before. `:market_type` is passed
  # through only when the caller names it — the venue's own default is the
  # better answer, and forcing `:spot` here resolved a spot listen key endpoint
  # on venues that trade no spot at all.
  defp auth_opts(opts) do
    opts
    |> Keyword.take([:market_type, :request_id])
    |> Keyword.put_new_lazy(:request_id, fn -> :erlang.unique_integer([:positive]) end)
  end

  defp auth_timeout_ms(opts), do: Keyword.get(opts, :auth_timeout_ms, @default_auth_timeout_ms)

  @doc """
  Sends an exchange-native subscribe frame for the given channels and waits for
  the venue's accept/reject outcome.

  The frame is built by the exchange's registered `subscription_pattern` module
  (via `Bourse.WS.Subscription.build_subscribe/3`), encoded as JSON, and sent via
  `ZenWebsocket.Client.send_message/2`.

  Pattern modules return either a single map (most exchanges) or a list of maps
  (`:sub_subscribe` and `:custom` with `array_format` — HTX/Upbit emit one
  frame per channel). List returns are sent sequentially.

  ## Return shape

  Always `:ok | {:error, term()}` — never `{:ok, envelope}`. Venue rejections
  (correlated or async) surface as `{:error, {:subscription_rejected, frame}}`.

  Pass `ack_timeout_ms:` (keyword or map) to override the async-ack wait
  (default 3000); `0` explicitly disables acknowledgement waiting. Other `opts`
  merge into the exchange's `subscription_config` from `Bourse.WS.Config` —
  used for runtime overrides like a fresh JSON-RPC id. Keys must be atoms to
  override the atom-keyed base config; string-keyed maps coexist rather than
  override.

  On a venue that echoes a request id in its reply (bybit `req_id`, the binance
  family and okx `id`), every request carries a fresh id unless `request_id:`
  supplies one, and only the reply echoing that id is the request's outcome —
  any other reply stays in the mailbox as an ordinary frame. The wait for a
  correlated reply is bounded by `ack_timeout_ms` too.

  With `ack_timeout_ms: 0` nothing waits for the reply, so no id is generated:
  the frame is sent as given and the call returns the send's own result. A
  `request_id:` passed anyway is put on the frame, and the reply is then
  delivered however zen_websocket delivers that frame: a `req_id` (bybit)
  reply reaches the handler as an ordinary frame, while an `id` (the binance
  family, okx) is correlated by zen_websocket itself, which holds the send
  until the reply with that id arrives and returns it as the call's outcome —
  exiting the caller after its 5-second call timeout when no reply comes.

  Per-frame auth injection (`Bourse.WS.Auth.build_subscribe_auth/5`, used by the
  `:rest_token` and `:inline_subscribe` patterns) is not called here. No runtime
  venue uses either pattern — both belong to exchanges outside the supported eleven
  — so this is a gap only for a venue promoted with one of them.
  """
  @spec subscribe(t(), [String.t() | map()], keyword() | map()) :: :ok | {:error, term()}
  def subscribe(%__MODULE__{} = ws, channels, opts \\ []) when is_list(channels) do
    with {:ok, groups} <- route_subscription_groups(ws, channels) do
      subscribe_groups(ws, groups, opts)
    end
  end

  defp subscribe_on(ws, channels, opts) do
    emit_ws_send(ws.exchange, ws.section)

    timeout = ack_timeout_ms(opts)

    with {:ok, payload, request_id} <-
           subscription_payload(ws.exchange, channels, opts, timeout, &Subscription.build_subscribe/3) do
      confirm_subscribe(ws, payload, {channels, request_id}, timeout)
    end
  end

  defp unsubscribe_on(ws, channels, opts) do
    emit_ws_send(ws.exchange, ws.section)

    timeout = ack_timeout_ms(opts)

    with {:ok, payload, _request_id} <-
           subscription_payload(ws.exchange, channels, opts, timeout, &Subscription.build_unsubscribe/3) do
      send_request(ws, payload, timeout)
    end
  end

  # A venue that echoes a request id in its reply (`request_id_field` in its
  # subscription config) gets a fresh one on every request, so the reply to this
  # request can be told from a late reply to an earlier one; a caller-supplied
  # `request_id:` is sent as given. Returns the field and the id as the frame
  # carries it, or nil.
  defp subscription_payload(exchange, channels, opts, timeout, builder) do
    with {:ok, config} <- fetch_config(exchange) do
      sub_config = config |> merge_subscription_config(strip_ack_opts(opts)) |> with_request_id(timeout)

      with {:ok, payload} <- builder.(config.subscription_pattern, channels, sub_config) do
        {:ok, payload, sent_request_id(payload, sub_config)}
      end
    end
  end

  defp with_request_id(%{request_id_field: field} = sub_config, timeout) when is_binary(field) and timeout != 0 do
    Map.put_new_lazy(sub_config, :request_id, fn -> System.unique_integer([:positive, :monotonic]) end)
  end

  defp with_request_id(sub_config, _timeout), do: sub_config

  defp sent_request_id(%{} = payload, %{request_id_field: field}) when is_binary(field),
    do: {field, Map.get(payload, field)}

  defp sent_request_id(_payload, _sub_config), do: nil

  @doc "Sends a raw (already-encoded or map) payload. Delegates to zen_websocket."
  @spec send_message(t(), String.t() | map()) :: :ok | {:ok, map()} | {:error, term()}
  def send_message(%__MODULE__{exchange: exchange, zen_client: zen_client, section: section}, payload)
      when is_binary(payload) do
    emit_ws_send(exchange, section)
    ZenClient.send_message(zen_client, payload)
  end

  def send_message(%__MODULE__{exchange: exchange, zen_client: zen_client, section: section}, %{} = payload) do
    emit_ws_send(exchange, section)
    ZenClient.send_message(zen_client, Jason.encode!(payload))
  end

  @doc "Closes the WebSocket connection and every routed public-host connection it owns."
  @spec close(t()) :: :ok
  def close(%__MODULE__{connection_owner: owner} = ws) when is_pid(owner) do
    case take_owned_connections(ws) do
      {:ok, clients} ->
        Enum.each(clients, &ZenClient.close/1)
        stop_connection_owner(owner, connection_owner_timeout(ws))

      {:error, _reason} ->
        ZenClient.close(ws.zen_client)
    end

    :ok
  end

  def close(%__MODULE__{zen_client: zen_client}), do: ZenClient.close(zen_client)

  @doc "Returns the current connection state (`:connecting`, `:connected`, or `:disconnected`)."
  @spec get_state(t()) :: :connecting | :connected | :disconnected
  def get_state(%__MODULE__{zen_client: zen_client}), do: ZenClient.get_state(zen_client)

  @doc """
  Connection-scoped liveness observations for the primary socket and every
  routed host this connection still owns.

  Heartbeat fields are the locked dependency's `get_heartbeat_health/1` map
  (`active_heartbeats`, `last_heartbeat_at`, `failure_count`, `config`,
  `timer_active`). Market-data silence is not treated as a miss. A missing or
  closed owner is an error rather than an empty healthy list.
  """
  @spec health(t()) ::
          {:ok, [socket_health()]} | {:error, :connection_closed | {:connection_owner_down, term()}}
  def health(%__MODULE__{connection_owner: nil} = ws) do
    {:ok, [socket_health(ws.url, ws.zen_client, :primary)]}
  end

  def health(%__MODULE__{} = ws) do
    with {:ok, connections} <- snapshot_owned_connections(ws) do
      # The owner drops a client from `connections` when its transport process
      # exits, so a dead socket leaves an empty map behind. Answering `{:ok, []}`
      # there is a false green: `Enum.all?(observations, & &1.connection_state
      # == :connected)` is `true` on an empty list, so a caller polling for
      # liveness reads a dead connection as healthy.
      case health_observations(ws.url, connections) do
        [] -> {:error, :connection_closed}
        observations -> {:ok, observations}
      end
    end
  end

  @doc """
  Returns the process of every socket this connection still owns — the primary
  one and each routed host — so a supervising process can monitor them.

  A closed connection owns nothing and answers `[]`; so does one whose sockets
  have all exited.
  """
  @spec transport_pids(t()) :: [pid()]
  def transport_pids(%__MODULE__{connection_owner: nil} = ws) do
    [ws.zen_client] |> Enum.map(&client_server_pid/1) |> Enum.filter(&live_pid?/1)
  end

  def transport_pids(%__MODULE__{} = ws) do
    case snapshot_owned_connections(ws) do
      {:ok, connections} ->
        connections
        |> Map.values()
        |> Enum.map(&client_server_pid/1)
        |> Enum.filter(&live_pid?/1)
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end

  defp live_pid?(pid), do: is_pid(pid) and Process.alive?(pid)

  defp client_server_pid(%ZenClient{server_pid: pid}), do: pid
  defp client_server_pid(_client), do: nil

  @doc "Returns the resolved WS URL this connection is using."
  @spec get_url(t()) :: String.t()
  def get_url(%__MODULE__{url: url}), do: url

  @doc """
  Subscribes to ticker updates for `symbol`.

  Builds the channel from `websocket.subscribe.channels` and returns a handle
  for `unsubscribe/1`. The handle carries the effective socket, which can differ
  from the supplied socket when a stream uses another authored host. Pass
  `channel:` to supply a pre-formatted channel when templates are missing or
  unresolved.
  """
  @spec watch_ticker(t(), String.t(), keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def watch_ticker(%__MODULE__{} = ws, symbol, opts \\ []) when is_binary(symbol) do
    watch(ws, :watch_ticker, %{symbol: symbol}, opts)
  end

  @doc """
  Subscribes to order book updates for `symbol`.

  Pass `limit:` in opts when the exchange template includes `{limit}`.
  """
  @spec watch_order_book(t(), String.t(), keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def watch_order_book(%__MODULE__{} = ws, symbol, opts \\ []) when is_binary(symbol) do
    params =
      opts
      |> Keyword.take([:limit])
      |> Map.new()
      |> Map.put(:symbol, symbol)

    watch(ws, :watch_order_book, params, opts)
  end

  @doc "Subscribes to public trade updates for `symbol`."
  @spec watch_trades(t(), String.t(), keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def watch_trades(%__MODULE__{} = ws, symbol, opts \\ []) when is_binary(symbol) do
    watch(ws, :watch_trades, %{symbol: symbol}, opts)
  end

  @doc """
  Subscribes to private order updates.

  Requires a `:private` connection (`Bourse.WS.connect(exchange, :private)`).
  Optional `symbol:` in opts scopes the stream when the venue's template
  interpolates a symbol. Bybit's order stream is the account-wide `order`
  topic and does not need one.

  Bybit private order pushes carry an `"id"` field, so zen_websocket's
  correlator delivers them as `{:websocket_unmatched_response, frame}`
  rather than `{:websocket_message, frame}` — no in-flight request matches
  that id. Callers of `watch_orders/2` must handle both tags; the bybit
  trader journey pins this.
  """
  @spec watch_orders(t(), keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def watch_orders(%__MODULE__{} = ws, opts \\ []) do
    params =
      case Keyword.get(opts, :symbol) do
        symbol when is_binary(symbol) -> %{symbol: symbol}
        _ -> %{}
      end

    watch(ws, :watch_orders, params, opts)
  end

  @doc """
  Unsubscribes using a handle from `watch_*/3`.

  Sends the exchange-native unsubscribe frame built from the stored channels.
  Routed hosts stay with the originating `Bourse.WS` until `close/1`.
  """
  @spec unsubscribe(Handle.t()) :: :ok | {:ok, map()} | {:error, term()}
  def unsubscribe(%Handle{ws: ws, channels: channels, opts: sub_opts}) do
    unsubscribe_on(ws, channels, sub_opts)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp watch(%__MODULE__{exchange: exchange, section: section} = ws, method, params, opts) do
    with :ok <- require_section(method, section),
         {:ok, channel} <- Channels.build(exchange, method, params, opts),
         {:ok, ws} <- ensure_stream_host(ws, channel),
         :ok <- subscribe(ws, List.wrap(channel), opts) do
      {:ok, Handle.new(ws, method, channel, opts)}
    end
  end

  # USD-M `/public` silently acks `/market` stream names. Route only when the
  # caller is already on an authored venue host — test doubles and
  # caller-supplied URLs stay put.
  defp ensure_stream_host(%__MODULE__{section: :public, url: url} = ws, channel) when is_binary(channel) do
    target = URLRouting.stream_url(ws.exchange, channel)

    cond do
      is_nil(target) or target == url -> {:ok, ws}
      URLRouting.authored_usdm_host?(ws.exchange, url) -> routed_connection(ws, target)
      true -> {:ok, ws}
    end
  end

  defp ensure_stream_host(ws, _channel), do: {:ok, ws}

  defp route_subscription_groups(%__MODULE__{section: :public, url: url} = ws, channels) do
    if URLRouting.authored_usdm_host?(ws.exchange, url) do
      groups =
        ws.exchange
        |> URLRouting.group_channels_by_url(channels)
        |> Enum.map(fn {target, grouped} -> {target || url, grouped} end)

      {:ok, groups}
    else
      {:ok, [{url, channels}]}
    end
  end

  defp route_subscription_groups(%__MODULE__{url: url}, channels), do: {:ok, [{url, channels}]}

  defp subscribe_groups(ws, groups, opts) do
    groups
    |> Enum.reduce_while([], fn {url, channels}, succeeded ->
      case subscribe_host(ws, url, channels, opts) do
        {:ok, host_ws} ->
          {:cont, [{host_ws, channels} | succeeded]}

        {:error, _} = error ->
          rollback_subscriptions(succeeded, opts)
          {:halt, error}
      end
    end)
    |> finish_subscribe_groups()
  end

  defp subscribe_host(ws, url, channels, opts) do
    with {:ok, host_ws} <- routed_connection(ws, url),
         :ok <- subscribe_on(host_ws, channels, opts) do
      {:ok, host_ws}
    end
  end

  defp finish_subscribe_groups(succeeded) when is_list(succeeded), do: :ok
  defp finish_subscribe_groups({:error, _} = error), do: error

  defp rollback_subscriptions(succeeded, opts) do
    Enum.each(succeeded, fn {ws, channels} -> _ = unsubscribe_on(ws, channels, opts) end)
  end

  defp routed_connection(%__MODULE__{url: url} = ws, url), do: {:ok, ws}

  defp routed_connection(%__MODULE__{connection_owner: nil}, url) do
    {:error, {:stream_host_unavailable, url, :connection_not_owned}}
  end

  defp routed_connection(%__MODULE__{} = ws, url) do
    owner_result =
      try do
        ConnectionOwner.checkout(
          ws.connection_owner,
          ws.connect_fun,
          url,
          ws.connect_opts,
          connection_owner_timeout(ws)
        )
      catch
        :exit, reason -> {:error, {:connection_owner_down, reason}}
      end

    case owner_result do
      {:ok, zen_client} -> {:ok, %{ws | zen_client: zen_client, url: url}}
      {:error, reason} -> {:error, {:stream_host_unavailable, url, reason}}
    end
  end

  defp own_connection(url, zen_client) do
    case ConnectionOwner.start(url, zen_client) do
      {:ok, owner} ->
        Process.link(owner)
        {:ok, owner}

      {:error, reason} ->
        ZenClient.close(zen_client)
        {:error, reason}
    end
  end

  defp take_owned_connections(ws) do
    ConnectionOwner.take(ws.connection_owner, connection_owner_timeout(ws))
  catch
    :exit, reason -> {:error, reason}
  end

  defp snapshot_owned_connections(ws) do
    ConnectionOwner.snapshot(ws.connection_owner, connection_owner_timeout(ws))
  catch
    :exit, reason -> {:error, {:connection_owner_down, reason}}
  end

  defp health_observations(primary_url, connections) do
    connections
    |> Enum.map(fn {url, client} ->
      role = if url == primary_url, do: :primary, else: :routed
      socket_health(url, client, role)
    end)
    |> Enum.sort_by(fn obs -> {obs.role != :primary, obs.url} end)
  end

  defp socket_health(url, client, role) do
    %{
      url: url,
      role: role,
      connection_state: connection_state(client),
      heartbeat: heartbeat_health(client)
    }
  end

  defp connection_state(client) do
    ZenClient.get_state(client)
  catch
    :exit, _reason -> :disconnected
  end

  defp heartbeat_health(client) do
    ZenClient.get_heartbeat_health(client)
  catch
    :exit, _reason -> nil
  end

  defp stop_connection_owner(owner, timeout), do: ConnectionOwner.stop(owner, timeout)

  defp connection_owner_timeout(%__MODULE__{connect_opts: opts}) do
    Keyword.get(opts, :timeout, @default_connection_timeout_ms) + @connection_owner_timeout_buffer_ms
  end

  defp require_section(method, section) do
    if Channels.private?(method) and section != :private do
      {:error, :private_section_required}
    else
      :ok
    end
  end

  defp fetch_config(%Exchange{} = exchange) do
    case Config.for_exchange(exchange) do
      nil -> Config.missing_config_error(exchange.id)
      config -> {:ok, config}
    end
  end

  defp fetch_url(%Exchange{} = exchange, :public) do
    case URLRouting.public_url(exchange) do
      nil -> {:error, :no_url_configured}
      url -> {:ok, url}
    end
  end

  defp fetch_url(%Exchange{} = exchange, :private) do
    case URLRouting.private_url(exchange) do
      nil -> {:error, :no_url_configured}
      url -> {:ok, url}
    end
  end

  defp build_connect_opts(config, opts) do
    heartbeat = Keyword.get(opts, :heartbeat_config, config.heartbeat)

    case Heartbeat.validate(heartbeat) do
      :ok ->
        opts =
          opts
          |> Keyword.delete(:pre_auth_opts)
          |> Keyword.put(:heartbeat_config, heartbeat)
          |> put_default_handler()

        {:ok, opts}

      {:error, _} = error ->
        error
    end
  end

  defp put_default_handler(opts) do
    parent = self()

    Keyword.put_new_lazy(opts, :handler, fn ->
      fn
        {:message, data} -> send(parent, market_or_control(data))
        {:binary, data} -> send(parent, market_or_control(data))
        {:unmatched_response, response} -> send(parent, {:websocket_unmatched_response, response})
        {:protocol_error, reason} -> send(parent, {:websocket_protocol_error, reason})
        _other -> :ok
      end
    end)
  end

  defp market_or_control(data) do
    case ControlFrame.classify(data) do
      :control -> {:websocket_unmatched_response, data}
      :market -> {:websocket_message, data}
    end
  end

  defp merge_subscription_config(%{subscription_config: base}, opts) when is_list(opts) do
    Map.merge(base, Map.new(opts))
  end

  defp merge_subscription_config(%{subscription_config: base}, opts) when is_map(opts) do
    Map.merge(base, opts)
  end

  defp ack_timeout_ms(opts) when is_list(opts) do
    Keyword.get(opts, :ack_timeout_ms, @default_ack_timeout_ms)
  end

  defp ack_timeout_ms(opts) when is_map(opts) do
    Map.get(opts, :ack_timeout_ms, Map.get(opts, "ack_timeout_ms", @default_ack_timeout_ms))
  end

  defp strip_ack_opts(opts) when is_list(opts), do: Keyword.delete(opts, :ack_timeout_ms)

  defp strip_ack_opts(opts) when is_map(opts) do
    opts
    |> Map.delete(:ack_timeout_ms)
    |> Map.delete("ack_timeout_ms")
  end

  defp confirm_subscribe(%__MODULE__{exchange: %{id: exchange_id}} = ws, payload, {channels, request_id}, ack_timeout_ms) do
    case send_request(ws, payload, ack_timeout_ms) do
      :ok ->
        await_subscribe_ack(exchange_id, {channels, request_id}, ack_timeout_ms)

      {:ok, response} when is_map(response) ->
        response
        |> then(&SubscribeAck.classify(exchange_id, &1, channels, request_id))
        |> SubscribeAck.to_result()

      {:error, _} = err ->
        err
    end
  end

  # Wait for an async subscribe ack/reject without disturbing the caller's
  # mailbox: the ack is taken out where it sits and every other message stays in
  # arrival order.
  defp await_subscribe_ack(_exchange_id, _request, 0), do: :ok

  defp await_subscribe_ack(exchange_id, {channels, request_id}, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    classify = fn frame ->
      case SubscribeAck.classify(exchange_id, frame, channels, request_id) do
        :success -> {:take, :success}
        # The ack is also data: it stays in the mailbox for the caller.
        {:success, :data} -> {:leave, :success}
        {:rejected, rejected} -> {:take, {:rejected, rejected}}
        :not_ack -> :skip
      end
    end

    case await_in_mailbox(classify, deadline) do
      {:success, _frame} -> :ok
      {{:rejected, rejected}, _frame} -> {:error, {:subscription_rejected, rejected}}
      :timeout -> {:error, :subscription_ack_timeout}
    end
  end

  # Finds the first frame message `classify` recognises and removes only that
  # message (or none, for `{:leave, _}`). Receiving everything and re-sending
  # what was not the ack cannot keep arrival order: a frame sent while the
  # re-send runs lands between re-sent ones, and messages that are not frames
  # move behind them. An order book checks each delta against the one before it.
  @ack_poll_ms 5

  defp await_in_mailbox(classify, deadline), do: await_in_mailbox(classify, deadline, 0)

  defp await_in_mailbox(classify, deadline, scanned) do
    case scan_mailbox(classify, scanned) do
      {:found, verdict, message, frame} ->
        take_message(verdict, message)
        {elem(verdict, 1), frame}

      {:not_found, scanned} ->
        left = deadline - System.monotonic_time(:millisecond)

        if left <= 0 do
          :timeout
        else
          receive do
          after
            min(left, @ack_poll_ms) -> await_in_mailbox(classify, deadline, scanned)
          end
        end
    end
  end

  # Nothing ahead of `scanned` is ever removed while waiting, so already
  # classified messages are not classified again.
  defp scan_mailbox(classify, scanned) do
    {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

    if queued <= scanned do
      {:not_found, scanned}
    else
      {:messages, messages} = Process.info(self(), :messages)

      messages
      |> Enum.drop(scanned)
      |> Enum.find_value({:not_found, length(messages)}, &classify_message(classify, &1))
    end
  end

  defp classify_message(classify, message) do
    with frame when is_map(frame) or is_list(frame) <- frame_of(message),
         verdict when verdict != :skip <- classify.(frame) do
      {:found, verdict, message, frame}
    else
      _ -> nil
    end
  end

  defp frame_of({tag, frame}) when tag in [:websocket_message, :websocket_unmatched_response, :ws_frame], do: frame
  # The adapter's handler delivers frames as {:ws_frame, connection, _}.
  defp frame_of({:ws_frame, _connection, frame}), do: frame
  defp frame_of(_message), do: nil

  # A pinned receive removes the first equal message, which is the one found:
  # an equal message earlier in the mailbox would have been found first.
  defp take_message({:take, _}, message) do
    receive do
      ^message -> :ok
    end
  end

  defp take_message({:leave, _}, _message), do: :ok

  # zen_websocket correlates a frame carrying an `"id"`: the send blocks until
  # the reply with that id arrives, and only that reply answers it. The block is
  # a GenServer.call under its default 5-second timeout, so an awaited request
  # runs it in a monitored process: the wait ends at `timeout_ms`, and a venue
  # that never answers cannot exit the caller. A reply arriving after that is
  # dropped by zen_websocket with the abandoned call. A request nothing waits
  # for (`timeout_ms` 0) is sent the plain way.
  defp send_request(%__MODULE__{zen_client: zen_client}, %{"id" => id} = payload, timeout_ms)
       when not is_nil(id) and timeout_ms != 0 do
    {pid, ref} = spawn_monitor(fn -> exit({:sent, send_payload(zen_client, payload)}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:sent, result}} -> result
      {:DOWN, ^ref, :process, ^pid, {:timeout, _call}} -> {:error, :subscription_ack_timeout}
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, {:send_failed, reason}}
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        {:error, :subscription_ack_timeout}
    end
  end

  defp send_request(%__MODULE__{zen_client: zen_client}, payload, _timeout_ms), do: send_payload(zen_client, payload)

  defp send_payload(zen_client, frames) when is_list(frames) do
    Enum.reduce_while(frames, :ok, fn frame, _acc ->
      case ZenClient.send_message(zen_client, Jason.encode!(frame)) do
        :ok -> {:cont, :ok}
        {:ok, _response} = ok -> {:cont, ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp send_payload(zen_client, %{} = payload) do
    ZenClient.send_message(zen_client, Jason.encode!(payload))
  end
end
