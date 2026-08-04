defmodule Bourse.WS do
  @moduledoc """
  WebSocket entry point. Thin wrapper around `ZenWebsocket.Client` that binds
  a `%Bourse.Exchange{}` to a connection so `subscribe/3` can pick the correct
  exchange-native frame builder.

  ## Layer 1+2 (Task 92)

  Pure URL resolution (`Bourse.WS.URLRouting`) + connection lifecycle (this module).
  Layer 3 (auth state machine, custom reconnection) is deliberately deferred —
  `zen_websocket` covers reconnection, backoff, heartbeat, and subscription
  restoration natively.

  ## Usage

      {:ok, ws} = Bourse.WS.connect(exchange, :public)
      {:ok, sub} = Bourse.WS.watch_ticker(ws, "BTC/USDT")
      :ok = Bourse.WS.unsubscribe(sub)
      Bourse.WS.close(ws)

  Lower-level subscribe with pre-formatted channels still works:

      :ok = Bourse.WS.subscribe(ws, ["tickers.BTCUSDT"])
      # Data messages arrive at the calling process as {:websocket_message, decoded_map}
      Bourse.WS.close(ws)

  ## Subscribe return shape (unified)

  `subscribe/3` always returns `:ok | {:error, term()}` across venues:

  - `:ok` — the venue accepted the subscription, or acknowledgement waiting was
    explicitly disabled with `ack_timeout_ms: 0`
  - `{:error, {:subscription_rejected, frame}}` — the venue rejected it; `frame`
    is the raw exchange envelope
  - `{:error, :subscription_ack_timeout}` — no accept/reject outcome arrived
    within the acknowledgement window
  - `{:error, reason}` — build/send failures (`:unsupported_exchange`, channel
    shape errors, transport errors, …)

  Correlated JSON-RPC replies (deribit) and asynchronous acks (bybit, okx,
  hyperliquid, derive, binance) are classified by `Bourse.WS.SubscribeAck`.
  Rejection frames that arrive asynchronously are still consumed and returned
  as errors; non-ack data frames that arrive during the wait are re-queued to
  the caller mailbox.

  ## Scope

  Seven runtime venues have WS config: `binance`, `binanceusdm`, `bybit`,
  `deribit`, `derive`, `hyperliquid`, `okx`.
  """

  alias Bourse.Exchange
  alias Bourse.WS.Channels
  alias Bourse.WS.Config
  alias Bourse.WS.Handle
  alias Bourse.WS.SubscribeAck
  alias Bourse.WS.Subscription
  alias Bourse.WS.URLRouting
  alias ZenWebsocket.Client, as: ZenClient

  # Default window to wait for an async subscribe ack/rejection after send.
  @default_ack_timeout_ms 3_000

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
  defstruct [:exchange, :zen_client, :url, :section]

  @type t :: %__MODULE__{
          exchange: Exchange.t(),
          zen_client: ZenClient.t(),
          url: String.t(),
          section: section()
        }

  @doc """
  Connects to the exchange's WebSocket endpoint for the given section
  (`:public` or `:private`).

  Extra opts are forwarded to `ZenWebsocket.Client.connect/2`. The connection's
  heartbeat config is resolved from `Bourse.WS.Config` unless the caller overrides
  `heartbeat_config` in opts.

  Returns `{:error, :unsupported_exchange}` if the exchange has no WS config,
  or `{:error, :no_url_configured}` if the requested section is absent.
  """
  @spec connect(Exchange.t(), section(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(%Exchange{} = exchange, section, opts \\ []) when section in [:public, :private] do
    with {:ok, config} <- fetch_config(exchange),
         {:ok, url} <- fetch_url(exchange, section),
         connect_opts = build_connect_opts(config, opts),
         {:ok, zen_client} <- ZenClient.connect(url, connect_opts) do
      {:ok, %__MODULE__{exchange: exchange, zen_client: zen_client, url: url, section: section}}
    end
  end

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

  TODO(T94): `:rest_token` (kraken) and `:inline_subscribe` (coinbase) auth
  patterns require per-frame auth injection via `Bourse.WS.Auth.build_subscribe_auth/5`,
  which this function does not call. Private subscribes on those exchanges ship
  unauthenticated until the adapter layer lands (see CHANGELOG T94).
  """
  @spec subscribe(t(), [String.t() | map()], keyword() | map()) :: :ok | {:error, term()}
  def subscribe(%__MODULE__{exchange: exchange, zen_client: zen_client, section: section}, channels, opts \\ [])
      when is_list(channels) do
    emit_ws_send(exchange, section)
    ack_timeout_ms = ack_timeout_ms(opts)

    with {:ok, config} <- fetch_config(exchange),
         merged_config = merge_subscription_config(config, strip_ack_opts(opts)),
         {:ok, payload} <-
           Subscription.build_subscribe(config.subscription_pattern, channels, merged_config) do
      confirm_subscribe(zen_client, payload, exchange.id, ack_timeout_ms)
    end
  end

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

  @doc "Closes the WebSocket connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{zen_client: zen_client}), do: ZenClient.close(zen_client)

  @doc "Returns the current connection state (`:connecting`, `:connected`, or `:disconnected`)."
  @spec get_state(t()) :: :connecting | :connected | :disconnected
  def get_state(%__MODULE__{zen_client: zen_client}), do: ZenClient.get_state(zen_client)

  @doc "Returns the resolved WS URL this connection is using."
  @spec get_url(t()) :: String.t()
  def get_url(%__MODULE__{url: url}), do: url

  @doc """
  Subscribes to ticker updates for `symbol`.

  Builds the channel from `websocket.subscribe.channels` and returns a handle
  for `unsubscribe/1`. Pass `channel:` to supply a pre-formatted channel when
  templates are missing or unresolved.
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
  Optional `symbol:` in opts scopes the stream when templates require it.
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
  """
  @spec unsubscribe(Handle.t()) :: :ok | {:ok, map()} | {:error, term()}
  def unsubscribe(%Handle{ws: ws, channels: channels, opts: sub_opts}) do
    with {:ok, config} <- fetch_config(ws.exchange),
         merged_config = merge_subscription_config(config, sub_opts),
         {:ok, payload} <-
           Subscription.build_unsubscribe(config.subscription_pattern, channels, merged_config) do
      send_payload(ws.zen_client, payload)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp watch(%__MODULE__{exchange: exchange, section: section} = ws, method, params, opts) do
    with :ok <- require_section(method, section),
         {:ok, channel} <- Channels.build(exchange, method, params, opts),
         :ok <- subscribe(ws, List.wrap(channel), opts) do
      {:ok, Handle.new(ws, method, channel, opts)}
    end
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
      nil -> {:error, :unsupported_exchange}
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
    Keyword.put(opts, :heartbeat_config, heartbeat)
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

  defp confirm_subscribe(zen_client, payload, exchange_id, ack_timeout_ms) do
    case send_payload(zen_client, payload) do
      :ok ->
        await_subscribe_ack(exchange_id, ack_timeout_ms)

      {:ok, response} when is_map(response) ->
        response
        |> then(&SubscribeAck.classify(exchange_id, &1))
        |> SubscribeAck.to_result()

      {:error, _} = err ->
        err
    end
  end

  # Wait for an async subscribe ack/reject. Non-ack frames are re-queued so
  # the caller's existing {:websocket_message, _} receive loop still sees them.
  defp await_subscribe_ack(_exchange_id, 0), do: :ok

  defp await_subscribe_ack(exchange_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_subscribe_ack(exchange_id, deadline, [])
  end

  defp do_await_subscribe_ack(exchange_id, deadline, requeue) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      requeue_messages(requeue)
      {:error, :subscription_ack_timeout}
    else
      receive do
        {:websocket_message, frame} = msg when is_map(frame) ->
          handle_ack_frame(exchange_id, deadline, requeue, msg, frame)

        {:websocket_unmatched_response, frame} = msg when is_map(frame) ->
          handle_ack_frame(exchange_id, deadline, requeue, msg, frame)

        # Adapter injects a custom handler that tags frames as {:ws_frame, _}.
        {:ws_frame, frame} = msg when is_map(frame) ->
          handle_ack_frame(exchange_id, deadline, requeue, msg, frame)

        other ->
          do_await_subscribe_ack(exchange_id, deadline, [other | requeue])
      after
        max(left, 0) ->
          requeue_messages(requeue)
          {:error, :subscription_ack_timeout}
      end
    end
  end

  defp handle_ack_frame(exchange_id, deadline, requeue, msg, frame) do
    case SubscribeAck.classify(exchange_id, frame) do
      :success ->
        requeue_messages(requeue)
        :ok

      {:rejected, rejected} ->
        requeue_messages(requeue)
        {:error, {:subscription_rejected, rejected}}

      :not_ack ->
        do_await_subscribe_ack(exchange_id, deadline, [msg | requeue])
    end
  end

  defp requeue_messages(messages) do
    # Preserve original arrival order (requeue is newest-first).
    messages
    |> Enum.reverse()
    |> Enum.each(&send(self(), &1))
  end

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
