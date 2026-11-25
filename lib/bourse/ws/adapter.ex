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
  is announced with `{:bourse_ws, {:order_book_invalidated, channel, market,
  reason}}` on the same topics, where `market` is the instrument read from the
  venue's authored `market_path` (the routed market id where none is authored).
  Until the adapter has resynced it — from the venue's REST depth snapshot or by
  resubscribing for a fresh stream snapshot — routed frames for that book carry
  `book: nil`. A failed or unusable REST snapshot is retried after a delay that
  doubles per failure, one attempt at a time.

  ## Transport lifecycle

  The adapter owns reconnection. Its sockets are opened with
  `reconnect_on_error: false` and monitored, so a lost transport — on the
  primary socket or a routed host — ends the connection instead of being redialed
  underneath it. The adapter then:

    * announces every book it held as invalidated with reason
      `{:connection_lost, reason}` and discards the books and any REST snapshot
      in flight;
    * closes every socket of the lost connection and retires its
      authentication — `auth_state/1` is `:unauthenticated` and no renewal stays
      armed — until a new connection establishes its own;
    * dials a new connection, immediately after a connection that stayed up,
      otherwise after a delay that doubles per consecutive short-lived
      connection or failed dial (up to 30 s);
    * restores each accepted `subscribe/3` call as it was made, with its own
      options. A call the new connection refuses is logged and retried with
      the same backoff until it is accepted.

  Every book starts again from a fresh snapshot; frames still queued from the
  old connection are ignored.
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

  # A connection that stayed up this long resets the reconnect backoff.
  @stable_connection_ms 10_000
  @reconnect_base_ms 500
  @reconnect_max_ms 30_000
  @failed_dial_min_ms 5_000

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
          connected_at: integer() | nil,
          reconnect_attempts: non_neg_integer(),
          restore_attempts: non_neg_integer(),
          monitors: %{reference() => pid()},
          book_routes: %{Orderbook.key() => {String.t() | map(), String.t() | nil}},
          connect_fun: (Exchange.t(), section(), keyword() -> {:ok, WS.t()} | {:error, term()}),
          subscriptions: [{[String.t() | map()], keyword() | map()}],
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
    connected_at: nil,
    reconnect_attempts: 0,
    restore_attempts: 0,
    monitors: %{},
    book_routes: %{},
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
         monitor_transports(%{
           state
           | subscriptions: merge_subscriptions(state.subscriptions, {channels, sub_opts}),
             orderbook: Orderbook.track_subscriptions(state.orderbook, channels)
         })}

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
    #
    # A socket redialed underneath the adapter would keep books and sequence
    # ids from the old stream and carry none of its subscriptions, so the
    # transport is not allowed to reconnect itself (see "Transport lifecycle").
    case state.connect_fun.(state.exchange, state.section, handler: handler, reconnect_on_error: false) do
      {:ok, ws} ->
        connected = %{state | connection_ref: connection_ref, connected_at: System.monotonic_time(:millisecond)}
        {:noreply, replace_connection(connected, ws)}

      {:error, reason} ->
        Logger.warning("WS connect for #{state.exchange.id} (#{state.section}) failed: #{inspect(reason)}")
        {:noreply, schedule_connect(state, @failed_dial_min_ms)}
    end
  end

  def handle_info(:restore_subscriptions, state), do: handle_info({:restore_subscriptions, nil}, state)

  # Each accepted subscribe call is replayed on its own: some venues accept one
  # channel map per call, so a merged call would be refused.
  def handle_info({:restore_subscriptions, ref}, %{ws: %WS{} = ws, connection_ref: current} = state)
      when is_nil(ref) or ref == current do
    failed =
      for {channels, opts} = group <- state.subscriptions,
          {:error, reason} <- [WS.subscribe(ws, channels, opts)] do
        {group, reason}
      end

    state = monitor_transports(state)

    case failed do
      [] ->
        {:noreply, %{state | restore_attempts: 0}}

      _ ->
        delay = backoff_ms(state.restore_attempts + 1)

        Logger.warning(
          "WS #{state.exchange.id} (#{state.section}) could not restore #{inspect(failed)}; retrying in #{delay}ms"
        )

        Process.send_after(self(), {:restore_failed, current, Enum.map(failed, &elem(&1, 0))}, delay)
        {:noreply, %{state | restore_attempts: state.restore_attempts + 1}}
    end
  end

  def handle_info({:restore_subscriptions, _ref}, state), do: {:noreply, state}

  def handle_info({:restore_failed, ref, groups}, %{ws: %WS{}, connection_ref: ref} = state) do
    pending = %{state | subscriptions: Enum.filter(state.subscriptions, &(&1 in groups))}
    {:noreply, merged} = handle_info({:restore_subscriptions, ref}, pending)
    {:noreply, %{merged | subscriptions: state.subscriptions}}
  end

  def handle_info({:restore_failed, _ref, _groups}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitors: monitors} = state)
      when is_map_key(monitors, monitor) do
    {:noreply, transport_lost(state, reason)}
  end

  # A renewal timer that fired before a lost connection cancelled it has
  # nothing left to renew.
  def handle_info(:auth_expired, %{auth_context: nil} = state), do: {:noreply, state}

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

  def handle_info({:order_book_fetch_retry, key, token}, state) do
    if Orderbook.fetch_in_flight?(state.orderbook, key, token) do
      {:noreply, %{state | orderbook: start_snapshot_fetch(state, key, key)}}
    else
      {:noreply, state}
    end
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

        {state, book} =
          if family == :watch_order_book do
            apply_order_book(state, decoded, payload, channel, market_id)
          else
            {state, nil}
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

        {:noreply, %{state | trades: trades_state, ohlcv: ohlcv_state}}

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
          orderbook: Orderbook.reset(state.orderbook),
          book_routes: %{},
          restore_attempts: 0
      }
      |> demonitor_transports()
      |> adopt_connection()
      |> attach_owner()
      |> monitor_transports()

    close_previous(previous)
    send(self(), {:restore_subscriptions, new_state.connection_ref})
    new_state
  end

  # Every socket the connection owns — the primary one and each routed host —
  # is monitored once; losing any of them loses the frames it carried. The
  # primary socket is monitored even when it already died: the owner drops a
  # dead socket from its inventory, and the monitor still reports it.
  defp monitor_transports(%{ws: %WS{} = ws, monitors: monitors} = state) do
    watched = MapSet.new(Map.values(monitors))

    new =
      for pid <- Enum.uniq(primary_pid(ws) ++ WS.transport_pids(ws)),
          not MapSet.member?(watched, pid),
          into: %{} do
        {Process.monitor(pid), pid}
      end

    %{state | monitors: Map.merge(monitors, new)}
  end

  defp monitor_transports(state), do: state

  defp primary_pid(%WS{zen_client: %{server_pid: pid}}) when is_pid(pid), do: [pid]
  defp primary_pid(_ws), do: []

  defp demonitor_transports(%{monitors: monitors} = state) do
    Enum.each(Map.keys(monitors), &Process.demonitor(&1, [:flush]))
    %{state | monitors: %{}}
  end

  defp transport_lost(state, reason) do
    Logger.warning("WS transport for #{state.exchange.id} (#{state.section}) lost: #{inspect(reason)} — reconnecting")

    Enum.each(state.book_routes, fn {_key, {channel, market}} ->
      broadcast_invalidated(state, channel, market, {:connection_lost, reason})
    end)

    # The rest of the connection goes with the lost socket, and so does its
    # authentication: a replacement establishes its own.
    state = demonitor_transports(state)
    if state.ws, do: close_previous(state.ws)
    if state.auth_timer_ref, do: Process.cancel_timer(state.auth_timer_ref)

    schedule_connect(
      %{
        state
        | ws: nil,
          auth_state: :unauthenticated,
          auth_context: nil,
          auth_timer_ref: nil,
          orderbook: Orderbook.reset(state.orderbook),
          book_routes: %{},
          connection_ref: nil,
          reconnect_attempts: if(stable?(state), do: 0, else: state.reconnect_attempts)
      },
      0
    )
  end

  defp stable?(%{connected_at: at}) when is_integer(at),
    do: System.monotonic_time(:millisecond) - at >= @stable_connection_ms

  defp stable?(_state), do: false

  defp schedule_connect(state, min_delay_ms) do
    attempts = state.reconnect_attempts
    delay = max(min_delay_ms, backoff_ms(attempts))
    Process.send_after(self(), :connect, delay)
    %{state | reconnect_attempts: attempts + 1, connected_at: nil}
  end

  defp backoff_ms(0), do: 0
  defp backoff_ms(attempts), do: min(@reconnect_base_ms * Integer.pow(2, attempts - 1), @reconnect_max_ms)

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
    market = Orderbook.market(state.orderbook, decoded) || market_id
    {orderbook, outcome} = Orderbook.apply(state.orderbook, key, payload, decoded)
    state = %{state | orderbook: orderbook, book_routes: Map.put_new(state.book_routes, key, {channel, market})}

    case outcome do
      {:book, book} ->
        {state, book}

      {:fetch_snapshot, _market} ->
        {%{state | orderbook: start_snapshot_fetch(state, key, key)}, nil}

      {:invalidated, reason} ->
        broadcast_invalidated(state, channel, market, reason)
        send(self(), {:order_book_resync, key})
        {state, nil}

      {:unavailable, reason} ->
        broadcast_invalidated(state, channel, market, reason)
        {state, nil}

      _pending_or_none ->
        {state, nil}
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
        # One attempt per book: a fetch or a paced retry already scheduled wins.
        if Orderbook.needs_fetch?(state.orderbook, key),
          do: %{state | orderbook: start_snapshot_fetch(state, key, market)},
          else: state

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
      {:fetch_snapshot, _market} -> schedule_fetch_retry(state, key, :unusable_snapshot)
      _book_or_pending -> state
    end
  end

  defp apply_order_book_snapshot(state, key, ref, result) do
    if Orderbook.fetch_in_flight?(state.orderbook, key, ref) do
      schedule_fetch_retry(state, key, result)
    else
      state
    end
  end

  # The retry carries a token reserved on the book, so it fires only while that
  # book is still waiting for this attempt.
  defp schedule_fetch_retry(state, key, reason) do
    token = make_ref()

    case Orderbook.fetch_retry(state.orderbook, key, token) do
      {orderbook, delay_ms} ->
        Logger.warning(
          "WS order book snapshot #{state.exchange.id} #{inspect(key)} not usable (#{inspect(reason)}); " <>
            "retrying in #{delay_ms}ms"
        )

        Process.send_after(self(), {:order_book_fetch_retry, key, token}, delay_ms)
        %{state | orderbook: orderbook}

      :none ->
        state
    end
  end

  defp merge_subscriptions(existing, group) do
    if group in existing, do: existing, else: existing ++ [group]
  end
end
