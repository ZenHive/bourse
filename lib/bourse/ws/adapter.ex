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

    # `authenticate: false` because the adapter runs the handshake itself: it
    # needs the session metadata `WS.authenticate/2` returns to schedule
    # re-auth before expiry, which the facade's connect-time handshake
    # discards.
    case state.connect_fun.(state.exchange, state.section, handler: handler, authenticate: false) do
      {:ok, ws} ->
        new_state = authenticate_on_connect(%{state | ws: ws, auth_state: :unauthenticated})
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
    case do_authenticate(%{state | auth_state: :expired}) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _} -> {:noreply, %{state | auth_state: :expired}}
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

  # A private connection that comes up unauthenticated is the failure mode this
  # layer exists to prevent, and it is invisible from here: subscriptions are
  # accepted and simply never deliver. Log the venue's reason rather than let a
  # silent socket look healthy.
  defp authenticate_on_connect(%{section: :private} = state) do
    case do_authenticate(state) do
      {:ok, authenticated} ->
        authenticated

      {:error, :no_auth_config} ->
        state

      {:error, reason} ->
        Logger.warning(
          "WS auth failed for #{state.exchange.id} (private): #{inspect(reason)} — " <>
            "the connection is open but unauthenticated"
        )

        state
    end
  end

  defp authenticate_on_connect(state), do: state

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

  defp mark_auth_success(state, context, auth_config, auth_meta) do
    if state.auth_timer_ref, do: Process.cancel_timer(state.auth_timer_ref)

    {timer_ref, _} = schedule_auth_expiry(auth_meta, auth_config)

    %{state | auth_state: :authenticated, auth_context: context, auth_timer_ref: timer_ref}
  end

  defp schedule_auth_expiry(auth_meta, auth_config) do
    case Expiry.schedule_delay_ms(Expiry.compute_ttl_ms(auth_meta, auth_config)) do
      nil ->
        {nil, nil}

      delay_ms ->
        ref = Process.send_after(self(), :auth_expired, delay_ms)
        {ref, nil}
    end
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
