defmodule Bourse.WS.Adapter do
  @moduledoc """
  Layer-3 WebSocket adapter GenServer.

  Manages connection lifecycle, auth state machine, subscription restoration,
  spec-driven message routing, semantics state, and Registry broadcast.

  ## Broadcasts

  Every routed frame is published as
  `{:bourse_ws, {:routed, family, payload, channel, market_id, book}}` on the
  family's channel topic and on its `nil` topic. `book` is the maintained order
  book for `:watch_order_book` and `nil` for other families.

  An order book whose continuity breaks (see `Bourse.WS.Semantics.Orderbook`)
  is announced with `{:bourse_ws, {:order_book_invalidated, channel, market_id,
  reason}}` on the same topics. Until the adapter has resynced it — from the
  venue's REST depth snapshot or by resubscribing for a fresh stream snapshot —
  routed frames for that book carry `book: nil`. After a reconnect every book
  starts again from a fresh snapshot.
  """

  use GenServer

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Auth.Expiry
  alias Bourse.WS.Broadcast
  alias Bourse.WS.Config
  alias Bourse.WS.Envelope
  alias Bourse.WS.ListenKey
  alias Bourse.WS.MessageRouter
  alias Bourse.WS.Semantics.Ohlcv
  alias Bourse.WS.Semantics.Orderbook
  alias Bourse.WS.Semantics.Trades

  require Logger

  # Must exceed Bourse.WS's own auth window so the caller does not time out on a
  # handshake the facade is still waiting on.
  @auth_call_timeout_ms 15_000

  @type section :: WS.section()
  @type auth_state :: :unauthenticated | :authenticating | :authenticated | :expired

  @type t :: %__MODULE__{
          exchange: Exchange.t(),
          section: section(),
          ws: WS.t() | nil,
          auth_state: auth_state(),
          auth_context: map() | nil,
          auth_timer_ref: reference() | nil,
          connection_ref: reference() | nil,
          connect_fun: (Exchange.t(), section(), keyword() -> {:ok, WS.t()} | {:error, term()}),
          subscriptions: [String.t() | map()],
          orderbook: Orderbook.t(),
          trades: Trades.t(),
          ohlcv: Ohlcv.t()
        }

  defstruct [
    :exchange,
    :section,
    ws: nil,
    auth_state: :unauthenticated,
    auth_context: nil,
    auth_timer_ref: nil,
    connection_ref: nil,
    connect_fun: &WS.connect/3,
    subscriptions: [],
    orderbook: %Orderbook{},
    trades: %Trades{},
    ohlcv: %Ohlcv{}
  ]

  @doc "Starts a managed WS adapter for the given exchange section."
  @spec start_link(Exchange.t(), section(), keyword()) :: GenServer.on_start()
  def start_link(%Exchange{} = exchange, section, opts \\ []) when section in [:public, :private] do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, {exchange, section, opts}, name: name)
    else
      GenServer.start_link(__MODULE__, {exchange, section, opts})
    end
  end

  @doc "Subscribes to channels and tracks them for restoration."
  @spec subscribe(GenServer.server(), [String.t() | map()], keyword() | map()) ::
          :ok | {:error, term()}
  def subscribe(server, channels, opts \\ []) when is_list(channels) do
    GenServer.call(server, {:subscribe, channels, opts})
  end

  @doc """
  Runs the auth state machine when credentials are configured.

  The call window is longer than the GenServer default because the handshake
  waits on the venue: `Bourse.WS.authenticate/2` allows 10s for a verdict, and a
  5s call timeout would abandon a handshake that is still legitimately in
  flight.
  """
  @spec authenticate(GenServer.server()) :: :ok | {:error, term()}
  def authenticate(server), do: GenServer.call(server, :authenticate, @auth_call_timeout_ms)

  @doc "Returns current auth state."
  @spec auth_state(GenServer.server()) :: auth_state()
  def auth_state(server), do: GenServer.call(server, :auth_state)

  @doc "Returns connection state from the underlying WS client."
  @spec connection_state(GenServer.server()) :: :connecting | :connected | :disconnected
  def connection_state(server), do: GenServer.call(server, :connection_state)

  @impl true
  def init({exchange, section, opts}) do
    state =
      attach_owner(%__MODULE__{
        exchange: exchange,
        section: section,
        ws: Keyword.get(opts, :ws),
        connect_fun: Keyword.get(opts, :connect_fun, &WS.connect/3),
        orderbook: Orderbook.new(exchange),
        trades: Trades.new(exchange),
        ohlcv: Ohlcv.new(exchange)
      })

    if Keyword.get(opts, :connect, true) do
      send(self(), :connect)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, _channels, _sub_opts}, _from, %{ws: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:subscribe, channels, sub_opts}, _from, %{ws: ws} = state) do
    case WS.subscribe(ws, channels, sub_opts) do
      :ok ->
        {:reply, :ok,
         %{
           state
           | subscriptions: merge_subscriptions(state.subscriptions, channels),
             orderbook: Orderbook.track_subscriptions(state.orderbook, channels)
         }}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:authenticate, _from, %{auth_state: :authenticated} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:authenticate, _from, %{ws: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:authenticate, _from, %{exchange: %{credentials: nil}} = state) do
    {:reply, {:error, :no_credentials}, state}
  end

  def handle_call(:authenticate, _from, state) do
    case do_authenticate(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:auth_state, _from, state), do: {:reply, state.auth_state, state}

  def handle_call(:connection_state, _from, %{ws: nil} = state) do
    {:reply, :disconnected, state}
  end

  def handle_call(:connection_state, _from, %{ws: ws} = state) do
    {:reply, WS.get_state(ws), state}
  end

  @impl true
  def handle_info(:connect, state) do
    adapter_pid = self()
    # Frames carry the connection they arrived on, so frames still queued from
    # a replaced connection are not applied to books rebuilt on the new one.
    connection_ref = make_ref()

    handler = fn
      {:message, data} -> send(adapter_pid, {:ws_frame, connection_ref, data})
      {:binary, data} -> send(adapter_pid, {:ws_frame, connection_ref, data})
      {:unmatched_response, data} -> send(adapter_pid, {:ws_frame, connection_ref, data})
      _ -> :ok
    end

    # The facade authenticates a private section itself and records the outcome
    # on the connection, so the adapter reads `ws.auth` rather than running a
    # second handshake. Opting out is not available on every venue: a listen
    # key is part of the URL, so there is no connection to authenticate later.
    case state.connect_fun.(state.exchange, state.section, handler: handler) do
      {:ok, ws} ->
        {:noreply, replace_connection(%{state | connection_ref: connection_ref}, ws)}

      {:error, _} ->
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(:restore_subscriptions, %{subscriptions: []} = state) do
    {:noreply, state}
  end

  def handle_info(:restore_subscriptions, %{ws: ws, subscriptions: subs} = state) do
    WS.subscribe(ws, subs)
    {:noreply, state}
  end

  def handle_info(:auth_expired, state) do
    case renew_auth(%{state | auth_state: :expired}) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        # The socket stays open and stops delivering. Nothing downstream can
        # tell that apart from a quiet market, so say it here.
        Logger.warning(
          "WS auth renewal failed for #{state.exchange.id} (#{state.section}): #{inspect(reason)} — " <>
            "the connection is open but no longer authenticated"
        )

        {:noreply, %{state | auth_state: :expired}}
    end
  end

  def handle_info({:ws_frame, decoded}, state) when is_map(decoded) do
    route_and_broadcast(decoded, state)
  end

  def handle_info({:ws_frame, ref, decoded}, %{connection_ref: ref} = state) when is_map(decoded) do
    route_and_broadcast(decoded, state)
  end

  def handle_info({:order_book_resync, key}, state) do
    {:noreply, resync_order_book(state, key)}
  end

  def handle_info({:order_book_snapshot, key, ref, result}, state) do
    {:noreply, apply_order_book_snapshot(state, key, ref, result)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{ws: nil}), do: :ok

  def terminate(_reason, %{ws: ws}) do
    unlink_owner(ws)
    WS.close(ws)
  end

  defp route_and_broadcast(decoded, state) do
    envelope = Envelope.for_exchange(state.exchange)

    case MessageRouter.route(decoded, envelope, state.exchange) do
      {:routed, family, payload, channel} ->
        # Emit after routing to get accurate kind; one call to route.
        :telemetry.execute(
          Bourse.Telemetry.ws_message(),
          %{system_time: System.system_time()},
          # reach:disable-next-line fixed_shape_map — :telemetry metadata; the shape is the boundary contract
          %{exchange: state.exchange.id, section: state.section, kind: :routed}
        )

        market_id = MessageRouter.extract_market_id(channel)
        key = market_id || channel

        {orderbook, book} =
          if family == :watch_order_book do
            apply_order_book(state, decoded, payload, channel, market_id)
          else
            {state.orderbook, nil}
          end

        {trades_state, _} =
          if family == :watch_trades do
            Trades.apply(state.trades, key, payload)
          else
            {state.trades, nil}
          end

        {ohlcv_state, _} =
          if family == :watch_ohlcv do
            Ohlcv.apply(state.ohlcv, key, payload)
          else
            {state.ohlcv, nil}
          end

        message = {:bourse_ws, {:routed, family, payload, channel, market_id, book}}

        Broadcast.broadcast(Broadcast.topic(state.exchange.id, family, channel), message)
        Broadcast.broadcast(Broadcast.topic(state.exchange.id, family, nil), message)

        {:noreply, %{state | orderbook: orderbook, trades: trades_state, ohlcv: ohlcv_state}}

      {:system, _} ->
        :telemetry.execute(
          Bourse.Telemetry.ws_message(),
          %{system_time: System.system_time()},
          %{exchange: state.exchange.id, section: state.section, kind: :system}
        )

        Broadcast.broadcast(
          Broadcast.topic(state.exchange.id, :system, nil),
          {:bourse_ws, {:system, decoded}}
        )

        {:noreply, state}

      {:unknown, _} ->
        :telemetry.execute(
          Bourse.Telemetry.ws_message(),
          %{system_time: System.system_time()},
          %{exchange: state.exchange.id, section: state.section, kind: :raw}
        )

        Broadcast.broadcast(
          Broadcast.topic(state.exchange.id, :raw, nil),
          {:bourse_ws, {:raw, decoded}}
        )

        {:noreply, state}
    end
  end

  # `connect/3` refuses to hand back a private connection the venue rejected, so
  # reaching here with `ws.auth` set means the handshake already succeeded — all
  # that is left is to arm renewal from what the venue disclosed.
  defp replace_connection(state, ws) do
    previous = state.ws

    if state.auth_timer_ref, do: Process.cancel_timer(state.auth_timer_ref)

    # Books built on the previous connection cannot be continued: every book
    # restarts from a fresh snapshot.
    new_state =
      %{
        state
        | ws: ws,
          auth_state: :unauthenticated,
          auth_context: nil,
          auth_timer_ref: nil,
          orderbook: Orderbook.reset(state.orderbook)
      }
      |> adopt_connection()
      |> attach_owner()

    close_previous(previous)
    send(self(), :restore_subscriptions)
    new_state
  end

  defp close_previous(nil), do: :ok

  defp close_previous(%WS{} = ws) do
    unlink_owner(ws)
    WS.close(ws)
  end

  defp attach_owner(%{ws: %WS{connection_owner: pid}} = state) when is_pid(pid) do
    Process.link(pid)
    state
  end

  defp attach_owner(state), do: state

  defp unlink_owner(%WS{connection_owner: pid}) when is_pid(pid), do: Process.unlink(pid)
  defp unlink_owner(_ws), do: :ok

  defp adopt_connection(%{ws: %WS{auth: %{pattern: pattern, meta: meta}}} = state) do
    mark_auth_success(state, %{pattern: pattern}, auth_config_or_empty(state), meta)
  end

  defp adopt_connection(state), do: state

  # The handshake itself lives in `Bourse.WS.authenticate/2` so the facade and
  # the adapter cannot drift; the adapter adds only what a long-lived process
  # needs on top — the state transition and the re-auth timer.
  defp do_authenticate(state) do
    with {:ok, config} <- fetch_ws_config(state.exchange),
         %{auth_pattern: pattern} when not is_nil(pattern) <- config,
         {:ok, auth_meta} <- WS.authenticate(state.ws, market_type: :spot) do
      {:ok, mark_auth_success(state, %{pattern: pattern}, config.auth_config, auth_meta)}
    else
      # `fetch_ws_config/1` already turns a missing config into an
      # `{:error, _}`, so an unauthenticated venue reaches here only as a
      # config whose `auth_pattern` the venue never authored.
      %{auth_pattern: nil} -> {:error, :no_auth_config}
      {:error, _} = error -> error
    end
  end

  # Renewal is not always re-authentication. A listen key stays valid only while
  # it is refreshed, and the refresh extends the key the open socket was built
  # from — re-running the handshake would mint a second key this connection
  # could not adopt.
  defp renew_auth(%{auth_context: %{pattern: :listen_key}, ws: %WS{auth: %{meta: session}}} = state) do
    case ListenKey.keepalive(state.exchange, session) do
      :ok -> {:ok, mark_auth_success(state, state.auth_context, auth_config_or_empty(state), session)}
      {:error, _} = error -> error
    end
  end

  defp renew_auth(state), do: do_authenticate(state)

  defp auth_config_or_empty(state) do
    case fetch_ws_config(state.exchange) do
      {:ok, config} -> config.auth_config
      {:error, _} -> %{}
    end
  end

  defp mark_auth_success(state, context, auth_config, auth_meta) do
    if state.auth_timer_ref, do: Process.cancel_timer(state.auth_timer_ref)

    %{
      state
      | auth_state: :authenticated,
        auth_context: context,
        auth_timer_ref: schedule_renewal(auth_meta, auth_config)
    }
  end

  defp schedule_renewal(auth_meta, auth_config) do
    case renewal_delay_ms(auth_meta, auth_config) do
      nil -> nil
      delay_ms -> Process.send_after(self(), :auth_expired, delay_ms)
    end
  end

  # A venue that discloses a session TTL gets the safety margin applied to it.
  # An authored keepalive interval is already the safe interval below the
  # venue's expiry, so it is used as authored rather than discounted twice.
  defp renewal_delay_ms(%{keepalive_ms: ms}, _auth_config) when is_integer(ms) and ms > 0, do: ms

  defp renewal_delay_ms(auth_meta, auth_config) do
    Expiry.schedule_delay_ms(Expiry.compute_ttl_ms(auth_meta, auth_config))
  end

  defp fetch_ws_config(%Exchange{} = exchange) do
    case Config.for_exchange(exchange) do
      nil -> Config.missing_config_error(exchange.id)
      config -> {:ok, config}
    end
  end

  # Order book maintenance. Continuity is checked in `Orderbook`; this side
  # performs what a broken or missing book needs — a REST snapshot or a
  # resubscribe — and tells subscribers when a book they hold is no longer valid.
  defp apply_order_book(state, decoded, payload, channel, market_id) do
    key = Orderbook.key(state.orderbook, decoded, channel, market_id)
    {orderbook, outcome} = Orderbook.apply(state.orderbook, key, payload, decoded)

    case outcome do
      {:book, book} ->
        {orderbook, book}

      {:fetch_snapshot, market} ->
        {start_snapshot_fetch(%{state | orderbook: orderbook}, key, market), nil}

      {:invalidated, reason} ->
        broadcast_invalidated(state, channel, market_id, reason)
        send(self(), {:order_book_resync, key})
        {orderbook, nil}

      {:unavailable, reason} ->
        broadcast_invalidated(state, channel, market_id, reason)
        {orderbook, nil}

      _pending_or_none ->
        {orderbook, nil}
    end
  end

  defp broadcast_invalidated(state, channel, market_id, reason) do
    Logger.warning("WS order book #{state.exchange.id} #{inspect(channel)} invalidated: #{inspect(reason)}")
    message = {:bourse_ws, {:order_book_invalidated, channel, market_id, reason}}
    Broadcast.broadcast(Broadcast.topic(state.exchange.id, :watch_order_book, channel), message)
    Broadcast.broadcast(Broadcast.topic(state.exchange.id, :watch_order_book, nil), message)
  end

  defp resync_order_book(state, key) do
    case Orderbook.resync_action(state.orderbook, key) do
      {:rest_snapshot, market} ->
        %{state | orderbook: start_snapshot_fetch(state, key, market)}

      {:resubscribe, subscription} ->
        resubscribe(state, subscription)

      :none ->
        state
    end
  end

  defp resubscribe(%{ws: nil} = state, _subscription), do: state

  defp resubscribe(%{ws: ws} = state, subscription) do
    _ = WS.unsubscribe(WS.Handle.new(ws, :watch_order_book, [subscription]))

    case WS.subscribe(ws, [subscription]) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning(
          "WS order book resubscribe #{state.exchange.id} #{inspect(subscription)} failed: #{inspect(reason)}"
        )

        Process.send_after(self(), {:order_book_resync, subscription}, 1_000)
        state
    end
  end

  defp start_snapshot_fetch(state, key, market) do
    # The authored function name resolves to an existing atom only once the
    # generated venue module is loaded.
    Code.ensure_loaded!(state.exchange.module)
    {function, params} = Orderbook.rest_snapshot_request(state.orderbook, market)
    ref = make_ref()
    adapter = self()
    exchange = state.exchange

    {:ok, _pid} =
      Task.start(fn ->
        result =
          try do
            apply(exchange.module, function, [exchange, params])
          rescue
            error -> {:error, error}
          end

        send(adapter, {:order_book_snapshot, key, ref, result})
      end)

    Orderbook.fetch_started(state.orderbook, key, ref)
  end

  defp apply_order_book_snapshot(state, key, ref, {:ok, %{status: 200, body: body}}) when is_map(body) do
    {orderbook, outcome} = Orderbook.apply_rest_snapshot(state.orderbook, key, ref, body)
    state = %{state | orderbook: orderbook}

    case outcome do
      {:fetch_snapshot, market} -> %{state | orderbook: start_snapshot_fetch(state, key, market)}
      _book_or_pending -> state
    end
  end

  defp apply_order_book_snapshot(state, key, ref, result) do
    if Orderbook.fetch_in_flight?(state.orderbook, key, ref) do
      Logger.warning("WS order book snapshot fetch #{state.exchange.id} #{inspect(key)} failed: #{inspect(result)}")
      Process.send_after(self(), {:order_book_resync, key}, 1_000)
    end

    state
  end

  defp merge_subscriptions(existing, channels) do
    Enum.uniq(existing ++ channels)
  end
end
