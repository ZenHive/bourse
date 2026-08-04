defmodule Bourse.Telemetry do
  @moduledoc """
  Centralized telemetry contract for Bourse.

  Single source of truth for all telemetry events emitted by the library.
  Both `Bourse.HTTP` and `Bourse.CircuitBreaker` delegate event names here.

  ## Contract Version

  Bumped on breaking changes to event names, measurements, or metadata shapes.
  Consumers can assert compatibility at startup.

  ## Request Events

  Emitted by `Bourse.HTTP` during HTTP request lifecycle.

  ### `[:bourse, :request, :start]`

  - **Measurements:** `%{system_time: integer()}`
  - **Metadata:** `%{exchange: String.t(), method: atom(), path: String.t()}`

  ### `[:bourse, :request, :stop]`

  - **Measurements:** `%{duration: integer()}` (native time units)
  - **Metadata:** `%{exchange: String.t(), method: atom(), path: String.t(), status: integer()}`

  ### `[:bourse, :request, :exception]`

  - **Measurements:** `%{duration: integer()}` (native time units)
  - **Metadata:** `%{exchange: String.t(), method: atom(), path: String.t(), kind: atom(), reason: term()}`

  ## Circuit Breaker Events

  Emitted by `Bourse.CircuitBreaker` on state transitions.

  ### `[:bourse, :circuit_breaker, :open]`

  - **Measurements:** `%{system_time: integer()}`
  - **Metadata:** `%{exchange: String.t()}`

  ### `[:bourse, :circuit_breaker, :closed]`

  - **Measurements:** `%{system_time: integer()}`
  - **Metadata:** `%{exchange: String.t()}`

  ### `[:bourse, :circuit_breaker, :rejected]`

  - **Measurements:** `%{system_time: integer()}`
  - **Metadata:** `%{exchange: String.t()}`

  ## Rate Limiter Events

  Emitted by `Bourse.HTTP` when rate limiting is triggered.

  ### `[:bourse, :rate_limiter, :throttled]`

  - **Measurements:** `%{delay_ms: integer(), cost: number()}`
  - **Metadata:** `%{exchange: String.t()}`

  ## Signing Events

  Emitted by `Bourse.Signing.sign/4` (single event carrying duration; signing is a fast synchronous operation).

  ### `[:bourse, :signing, :sign]`

  - **Measurements:** `%{duration: integer()}` (native time units)
  - **Metadata:** `%{exchange: String.t() | nil, pattern: atom()}`

  ## WS Message Events

  Emitted by `Bourse.WS` (outbound) and `Bourse.WS.Adapter` (inbound frames).

  ### `[:bourse, :ws, :send]`

  - **Measurements:** `%{system_time: integer()}`
  - **Metadata:** `%{exchange: String.t(), section: :public | :private}`

  ### `[:bourse, :ws, :message]`

  - **Measurements:** `%{system_time: integer()}`
  - **Metadata:** `%{exchange: String.t(), section: :public | :private, kind: :routed | :system | :raw}`
  """

  @contract_version 2

  @request_start_event [:bourse, :request, :start]
  @request_stop_event [:bourse, :request, :stop]
  @request_exception_event [:bourse, :request, :exception]
  @circuit_breaker_open_event [:bourse, :circuit_breaker, :open]
  @circuit_breaker_closed_event [:bourse, :circuit_breaker, :closed]
  @circuit_breaker_rejected_event [:bourse, :circuit_breaker, :rejected]
  @rate_limiter_throttled_event [:bourse, :rate_limiter, :throttled]

  @signing_sign_event [:bourse, :signing, :sign]

  @ws_send_event [:bourse, :ws, :send]
  @ws_message_event [:bourse, :ws, :message]

  @request_events [@request_start_event, @request_stop_event, @request_exception_event]
  @circuit_breaker_events [
    @circuit_breaker_open_event,
    @circuit_breaker_closed_event,
    @circuit_breaker_rejected_event
  ]
  @rate_limiter_events [@rate_limiter_throttled_event]
  @signing_events [@signing_sign_event]
  @ws_events [@ws_send_event, @ws_message_event]
  @all_events @request_events ++ @circuit_breaker_events ++ @rate_limiter_events ++ @signing_events ++ @ws_events

  # ============================================================================
  # Contract Version
  # ============================================================================

  @doc """
  Returns the telemetry contract version.

  Bumped on breaking changes to event names, measurements, or metadata shapes.

      if Bourse.Telemetry.contract_version() != 2 do
        raise "Incompatible Bourse telemetry contract"
      end

  """
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  # ============================================================================
  # Event Name Functions
  # ============================================================================

  @doc "Event name for request start: `[:bourse, :request, :start]`."
  @spec request_start() :: [atom()]
  def request_start, do: @request_start_event

  @doc "Event name for request stop: `[:bourse, :request, :stop]`."
  @spec request_stop() :: [atom()]
  def request_stop, do: @request_stop_event

  @doc "Event name for request exception: `[:bourse, :request, :exception]`."
  @spec request_exception() :: [atom()]
  def request_exception, do: @request_exception_event

  @doc "Event name for circuit breaker open: `[:bourse, :circuit_breaker, :open]`."
  @spec circuit_breaker_open() :: [atom()]
  def circuit_breaker_open, do: @circuit_breaker_open_event

  @doc "Event name for circuit breaker closed: `[:bourse, :circuit_breaker, :closed]`."
  @spec circuit_breaker_closed() :: [atom()]
  def circuit_breaker_closed, do: @circuit_breaker_closed_event

  @doc "Event name for circuit breaker rejected: `[:bourse, :circuit_breaker, :rejected]`."
  @spec circuit_breaker_rejected() :: [atom()]
  def circuit_breaker_rejected, do: @circuit_breaker_rejected_event

  @doc "Event name for rate limiter throttled: `[:bourse, :rate_limiter, :throttled]`."
  @spec rate_limiter_throttled() :: [atom()]
  def rate_limiter_throttled, do: @rate_limiter_throttled_event

  @doc "Event name for signing (with duration): `[:bourse, :signing, :sign]`."
  @spec signing_sign() :: [atom()]
  def signing_sign, do: @signing_sign_event

  @doc "Event name for WS send: `[:bourse, :ws, :send]`."
  @spec ws_send() :: [atom()]
  def ws_send, do: @ws_send_event

  @doc "Event name for WS message (inbound): `[:bourse, :ws, :message]`."
  @spec ws_message() :: [atom()]
  def ws_message, do: @ws_message_event

  # ============================================================================
  # Event Lists
  # ============================================================================

  @doc "Returns all telemetry event names."
  @spec events() :: [[atom()]]
  def events, do: @all_events

  @doc "Returns the 3 HTTP request event names."
  @spec request_events() :: [[atom()]]
  def request_events, do: @request_events

  @doc "Returns the 3 circuit breaker event names."
  @spec circuit_breaker_events() :: [[atom()]]
  def circuit_breaker_events, do: @circuit_breaker_events

  @doc "Returns the rate limiter event names."
  @spec rate_limiter_events() :: [[atom()]]
  def rate_limiter_events, do: @rate_limiter_events

  @doc "Returns the signing event names (1 event)."
  @spec signing_events() :: [[atom()]]
  def signing_events, do: @signing_events

  @doc "Returns the 2 WS message event names."
  @spec ws_events() :: [[atom()]]
  def ws_events, do: @ws_events

  # ============================================================================
  # Convenience API
  # ============================================================================

  @doc """
  Attaches a handler to all Bourse telemetry events.

  Wraps `:telemetry.attach_many/4` with `events/0` as the event list.

  ## Parameters

  - `handler_id` - Unique string identifying this handler
  - `handler_fn` - Function of arity 4: `(event, measurements, metadata, config)`
  - `config` - Optional handler config (default: `nil`)

  """
  @spec attach(String.t(), (list(), map(), map(), term() -> any()), term()) ::
          :ok | {:error, :already_exists}
  def attach(handler_id, handler_fn, config \\ nil) when is_binary(handler_id) and is_function(handler_fn, 4) do
    :telemetry.attach_many(handler_id, events(), handler_fn, config)
  end

  @doc """
  Detaches a previously attached handler by ID.
  """
  @spec detach(String.t()) :: :ok | {:error, :not_found}
  def detach(handler_id) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
  end
end
