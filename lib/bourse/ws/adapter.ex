defmodule Bourse.WS.Adapter do
  @moduledoc """
  Layer-3 WebSocket adapter GenServer.

  Manages connection lifecycle, auth state machine, subscription restoration,
  spec-driven message routing, semantics state, and Registry broadcast.
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
    state = %__MODULE__{
      exchange: exchange,
      section: section,
      ws: Keyword.get(opts, :ws),
      connect_fun: Keyword.get(opts, :connect_fun, &WS.connect/3),
      orderbook: Orderbook.new(exchange),
      trades: Trades.new(exchange),
      ohlcv: Ohlcv.new(exchange)
    }

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
        {:reply, :ok, %{state | subscriptions: merge_subscriptions(state.subscriptions, channels)}}

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

    handler = fn
      {:message, data} -> send(adapter_pid, {:ws_frame, data})
      {:binary, data} -> send(adapter_pid, {:ws_frame, data})
      {:unmatched_response, data} -> send(adapter_pid, {:ws_frame, data})
      _ -> :ok
    end

    # The facade authenticates a private section itself and records the outcome
    # on the connection, so the adapter reads `ws.auth` rather than running a
    # second handshake. Opting out is not available on every venue: a listen
    # key is part of the URL, so there is no connection to authenticate later.
    case state.connect_fun.(state.exchange, state.section, handler: handler) do
      {:ok, ws} ->
        new_state = adopt_connection(%{state | ws: ws, auth_state: :unauthenticated})
        send(self(), :restore_subscriptions)
        {:noreply, new_state}

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

  def handle_info(_msg, state), do: {:noreply, state}

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
            Orderbook.apply(state.orderbook, key, payload)
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
      nil -> {:error, :no_auth_config}
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
      nil -> {:error, :unsupported_exchange}
      config -> {:ok, config}
    end
  end

  defp merge_subscriptions(existing, channels) do
    Enum.uniq(existing ++ channels)
  end
end
