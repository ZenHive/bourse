defmodule Bourse.Error do
  @moduledoc """
  Unified error types for exchange operations.

  All exchange errors are normalized to this struct, providing consistent
  error handling across every configured exchange. Each error carries its
  type, the original exchange error code and message, recoverability, and the
  upstream retry classification bucket.

  ## Error Types

  ### Recoverable (can retry automatically)
  - `:rate_limit_exceeded` - Too many requests, retry after `retry_after` ms
  - `:network_error` - Connection or timeout issue
  - `:exchange_not_available` - Exchange down, on maintenance, or market closed
  - `:invalid_nonce` - Nonce/timestamp window drift (client clock skew, concurrent
    signers, recv-window jitter); safe to retry after re-sync

  ### Non-recoverable (require intervention)
  - `:authentication_error` - API key/secret rejected (credential failure)
  - `:insufficient_funds` - Not enough funds for the operation
  - `:invalid_order` - Order parameters rejected by exchange
  - `:order_not_found` - Order ID does not exist
  - `:bad_request` - Invalid request parameters
  - `:bad_symbol` - Symbol not recognized by exchange
  - `:permission_denied` - API key lacks permissions or account suspended
  - `:access_restricted` - Geographic/IP block or wrong-URL HTML response (non-Cloudflare)
  - `:cloudflare_challenge` - Cloudflare anti-bot challenge page (exchange reachable but requires browser/approved client)
  - `:not_supported` - Method not supported by this exchange
  - `:operation_failed` - Operation rejected or failed
  - `:invalid_parameters` - Invalid request parameters (code bug)
  - `:market_closed` - Market is not currently trading
  - `:circuit_open` - Circuit breaker tripped due to consecutive failures

  ### Generic
  - `:exchange_error` - Unmapped error (see `code` and `message`)

  ## Example

      case Bourse.HTTP.request(exchange, :post, "/v5/order/create", params: params) do
        {:ok, response} -> handle_response(response)
        {:error, %Bourse.Error{type: :insufficient_funds}} -> notify_low_balance()
        {:error, %Bourse.Error{type: :rate_limit_exceeded, retry_after: ms}} -> Process.sleep(ms)
        {:error, %Bourse.Error{} = err} -> Logger.error("Exchange error: \#{err.message}")
      end

  """

  @type error_type ::
          :rate_limit_exceeded
          | :network_error
          | :exchange_not_available
          | :invalid_nonce
          | :authentication_error
          | :insufficient_funds
          | :invalid_order
          | :order_not_found
          | :bad_request
          | :bad_symbol
          | :permission_denied
          | :access_restricted
          | :cloudflare_challenge
          | :not_supported
          | :operation_failed
          | :invalid_parameters
          | :market_closed
          | :circuit_open
          | :exchange_error

  @typedoc """
  Upstream (Bourse Phase 13) retry classification bucket for an error.

  Adopted from the v4 spec's `errors.retry_classification`. Refines the
  coarse `recoverable?` boolean into the canonical retry semantics:

  - `:rate_limit` — back off and retry (handled by the rate limiter)
  - `:network` — transient connectivity/timeout; safe to retry
  - `:server_busy` — exchange unavailable/maintenance; safe to retry
  - `:auth` — credential/permission failure; do not retry without intervention
  - `:non_retryable` — deterministic rejection (bad params, no funds, …)
  - `nil` — unclassified (generic `exchange_error`)
  """
  @type retry_class ::
          :rate_limit | :network | :server_busy | :auth | :non_retryable | nil

  @type t :: %__MODULE__{
          type: error_type(),
          code: String.t() | integer() | nil,
          http_status: non_neg_integer() | nil,
          message: String.t(),
          exchange: String.t() | nil,
          retry_after: non_neg_integer() | nil,
          raw: map() | binary() | nil,
          hints: [String.t()],
          recoverable: boolean() | nil,
          retry_class: retry_class()
        }

  defexception [
    :type,
    :code,
    :http_status,
    :message,
    :exchange,
    :retry_after,
    :raw,
    :recoverable,
    :retry_class,
    hints: []
  ]

  @impl Exception
  def message(%__MODULE__{type: type, message: msg, exchange: exchange}) do
    prefix = if exchange, do: "[#{exchange}] ", else: ""
    "#{prefix}#{type}: #{msg}"
  end

  # ===========================================================================
  # Recoverability Classification
  # ===========================================================================

  @recoverable_types [:rate_limit_exceeded, :network_error, :exchange_not_available, :invalid_nonce]

  @non_recoverable_types [
    :authentication_error,
    :insufficient_funds,
    :invalid_order,
    :order_not_found,
    :bad_request,
    :bad_symbol,
    :permission_denied,
    :access_restricted,
    :cloudflare_challenge,
    :not_supported,
    :operation_failed,
    :invalid_parameters,
    :market_closed,
    :circuit_open
  ]

  @doc """
  Returns the recoverability classification for an error type.

  - `true` — recoverable (can retry automatically)
  - `false` — not recoverable (requires intervention)
  - `nil` — unknown (generic exchange_error)
  """
  @spec recoverable?(error_type()) :: boolean() | nil
  def recoverable?(type) when type in @recoverable_types, do: true
  def recoverable?(type) when type in @non_recoverable_types, do: false
  def recoverable?(:exchange_error), do: nil
  def recoverable?(_), do: nil

  @doc "Returns all recoverable error types."
  @spec recoverable_types() :: [error_type()]
  def recoverable_types, do: @recoverable_types

  @doc "Returns all non-recoverable error types."
  @spec non_recoverable_types() :: [error_type()]
  def non_recoverable_types, do: @non_recoverable_types

  # ===========================================================================
  # Retry classification from the authored errors.retry_classification slice.
  #
  # Canonical error_type → retry bucket. Derived from and verified against the
  # v4 `errors.retry_classification` contract across all in-scope exchanges
  # (mix run / test asserts spec agreement). Two upstream classes still collapse
  # to an Elixir atom that maps to two buckets across the spec — resolved here to
  # the dominant/safer bucket, consistent with the existing lossy
  # `from_spec_class/1` collapse:
  #
  #   * bad_request — BadRequest(:non_retryable) wins over BadResponse(:server_busy).
  #   * exchange_not_available — ExchangeNotAvailable/OnMaintenance(:server_busy)
  #     win over the MarketClosed(:non_retryable) edge; the type is recoverable.
  #
  # InvalidNonce is intentionally NOT collapsed into authentication_error: nonce
  # and timestamp-window failures are transient (`retry_class: :network`) while
  # credential rejection stays `:auth`. See Task 604 / BUGS 2026-08-12.
  #
  # The per-exchange `errors.retry_classification` table is preserved verbatim
  # on `Bourse.Exchange` (class-name keyed) for faithful lookups; this atom-level
  # map is what the runtime tags errors with, since only the type atom survives
  # to the HTTP layer.
  # ===========================================================================

  @retry_class_by_type %{
    rate_limit_exceeded: :rate_limit,
    network_error: :network,
    exchange_not_available: :server_busy,
    invalid_nonce: :network,
    authentication_error: :auth,
    permission_denied: :auth,
    insufficient_funds: :non_retryable,
    invalid_order: :non_retryable,
    order_not_found: :non_retryable,
    bad_request: :non_retryable,
    bad_symbol: :non_retryable,
    access_restricted: :non_retryable,
    cloudflare_challenge: :non_retryable,
    not_supported: :non_retryable,
    operation_failed: :non_retryable,
    invalid_parameters: :non_retryable,
    market_closed: :non_retryable,
    circuit_open: :non_retryable
  }

  @retryable_classes [:rate_limit, :network, :server_busy]

  @doc """
  Returns the canonical retry classification bucket for an error type.

  Returns `nil` for the generic `:exchange_error` (and any unknown type) —
  the retry semantics are genuinely unknown for an unmapped error.

  ## Examples

      iex> Bourse.Error.retry_class(:rate_limit_exceeded)
      :rate_limit

      iex> Bourse.Error.retry_class(:authentication_error)
      :auth

      iex> Bourse.Error.retry_class(:exchange_error)
      nil

  """
  @spec retry_class(error_type()) :: retry_class()
  def retry_class(type), do: Map.get(@retry_class_by_type, type)

  @doc """
  Returns whether an error (or retry bucket) is worth retrying.

  Retryable buckets are `:rate_limit`, `:network`, and `:server_busy`. An
  `:auth`, `:non_retryable`, or unclassified (`nil`) error returns `false`.

  ## Examples

      iex> Bourse.Error.should_retry?(:server_busy)
      true

      iex> Bourse.Error.should_retry?(:auth)
      false

      iex> Bourse.Error.should_retry?(%Bourse.Error{type: :rate_limit_exceeded, message: "", retry_class: :rate_limit})
      true

  """
  @spec should_retry?(t() | retry_class()) :: boolean()
  def should_retry?(%__MODULE__{retry_class: class}), do: class in @retryable_classes
  def should_retry?(class), do: class in @retryable_classes

  @doc "Returns the canonical error_type → retry bucket map."
  @spec retry_class_mapping() :: %{error_type() => retry_class()}
  def retry_class_mapping, do: @retry_class_by_type

  # ===========================================================================
  # Spec Class Mapping
  #
  # Maps CCXT compatibility exception class names (e.g., "__function:AuthenticationError")
  # to Elixir error atoms. Used by Exchange.new/2 to pre-process exception maps.
  # ===========================================================================

  @spec_class_mapping %{
    "AuthenticationError" => :authentication_error,
    "InvalidNonce" => :invalid_nonce,
    "InsufficientFunds" => :insufficient_funds,
    "InvalidOrder" => :invalid_order,
    "OrderImmediatelyFillable" => :invalid_order,
    "OrderNotFillable" => :invalid_order,
    "DuplicateOrderId" => :invalid_order,
    "OrderNotFound" => :order_not_found,
    "CancelPending" => :order_not_found,
    "BadRequest" => :bad_request,
    "ArgumentsRequired" => :bad_request,
    "BadResponse" => :bad_request,
    "BadSymbol" => :bad_symbol,
    "ContractUnavailable" => :bad_symbol,
    "PermissionDenied" => :permission_denied,
    "AccountSuspended" => :permission_denied,
    "AccountNotEnabled" => :permission_denied,
    "RateLimitExceeded" => :rate_limit_exceeded,
    "DDoSProtection" => :rate_limit_exceeded,
    "RequestTimeout" => :network_error,
    "NetworkError" => :network_error,
    "ExchangeNotAvailable" => :exchange_not_available,
    "OnMaintenance" => :exchange_not_available,
    "MarketClosed" => :exchange_not_available,
    "ExchangeClosedByUser" => :exchange_not_available,
    "RestrictedLocation" => :access_restricted,
    "NotSupported" => :not_supported,
    "OperationFailed" => :operation_failed,
    "OperationRejected" => :operation_failed,
    "ExchangeError" => :exchange_error,
    "ManualInteractionNeeded" => :exchange_error,
    "MarginModeAlreadySet" => :exchange_error,
    "NoChange" => :exchange_error,
    "InvalidAddress" => :bad_request
  }

  @doc """
  Maps a Bourse spec exception class to an error type atom.

  Accepts both raw class names and `__function:` prefixed strings from specs.

  ## Examples

      from_spec_class("AuthenticationError")
      #=> :authentication_error

      from_spec_class("__function:InsufficientFunds")
      #=> :insufficient_funds

      from_spec_class("UnknownClass")
      #=> :exchange_error

  """
  @spec from_spec_class(String.t()) :: error_type()
  def from_spec_class("__function:" <> class_name), do: from_spec_class(class_name)

  def from_spec_class(class_name) when is_binary(class_name) do
    Map.get(@spec_class_mapping, class_name, :exchange_error)
  end

  @doc """
  Maps a Bourse spec exception class to an error type, walking the upstream
  class hierarchy when the class is not directly mapped.

  `ancestors` is the per-exchange `errors.class_hierarchy.ancestors` map
  (`%{class => [ancestor, ...]}`, nearest first). When `class_name` has no
  direct mapping, the nearest mapped ancestor wins; only when neither the
  class nor any ancestor is known does it fall back to `:exchange_error`.

  This keeps the client robust to *new* upstream classes (e.g. `AddressPending`
  resolves through `InvalidAddress`, `ChecksumError` through `InvalidNonce`)
  without enumerating every leaf.

  ## Examples

      iex> Bourse.Error.from_spec_class("InsufficientFunds", %{})
      :insufficient_funds

      iex> ancestors = %{"AddressPending" => ["InvalidAddress", "ExchangeError", "BaseError"]}
      iex> Bourse.Error.from_spec_class("AddressPending", ancestors)
      :bad_request

      iex> Bourse.Error.from_spec_class("TotallyUnknown", %{})
      :exchange_error

  """
  @spec from_spec_class(String.t(), %{optional(String.t()) => [String.t()]}) :: error_type()
  def from_spec_class("__function:" <> class_name, ancestors), do: from_spec_class(class_name, ancestors)

  def from_spec_class(class_name, ancestors) when is_binary(class_name) and is_map(ancestors) do
    case Map.get(@spec_class_mapping, class_name) do
      nil -> resolve_via_ancestors(class_name, ancestors)
      type -> type
    end
  end

  defp resolve_via_ancestors(class_name, ancestors) do
    ancestors
    |> Map.get(strip_function_prefix(class_name), [])
    |> Enum.find_value(:exchange_error, fn ancestor ->
      Map.get(@spec_class_mapping, strip_function_prefix(ancestor))
    end)
  end

  defp strip_function_prefix("__function:" <> name), do: name
  defp strip_function_prefix(name), do: name

  @doc "Returns the full spec class to error type mapping."
  @spec spec_class_mapping() :: %{String.t() => error_type()}
  def spec_class_mapping, do: @spec_class_mapping

  # ===========================================================================
  # Factory Functions
  # ===========================================================================

  @doc """
  Creates a rate limit exceeded error.

  ## Options

  - `:retry_after` - Milliseconds until retry is allowed
  - `:exchange` - Exchange ID string
  - `:raw` - Original error response from exchange
  - `:hints` - List of debugging hint strings
  """
  @spec rate_limit_exceeded(keyword()) :: t()
  def rate_limit_exceeded(opts \\ []) do
    build(:rate_limit_exceeded, "Rate limit exceeded", opts)
  end

  @doc "Creates a network error."
  @spec network_error(keyword()) :: t()
  def network_error(opts \\ []) do
    build(:network_error, "Network error", opts)
  end

  @doc "Creates an exchange not available error."
  @spec exchange_not_available(keyword()) :: t()
  def exchange_not_available(opts \\ []) do
    build(:exchange_not_available, "Exchange not available", opts)
  end

  @doc "Creates an authentication error."
  @spec authentication_error(keyword()) :: t()
  def authentication_error(opts \\ []) do
    build(:authentication_error, "Invalid API credentials", opts)
  end

  @doc """
  Creates an invalid-nonce / timestamp-window error.

  Transient client clock skew, concurrent nonce races, and recv-window
  jitter — not credential rejection. `retry_class` is `:network`.
  """
  @spec invalid_nonce(keyword()) :: t()
  def invalid_nonce(opts \\ []) do
    build(:invalid_nonce, "Invalid nonce or timestamp outside recv window", opts)
  end

  @doc "Creates an insufficient funds error."
  @spec insufficient_funds(keyword()) :: t()
  def insufficient_funds(opts \\ []) do
    build(:insufficient_funds, "Insufficient funds", opts)
  end

  @doc "Creates an invalid order error."
  @spec invalid_order(keyword()) :: t()
  def invalid_order(opts \\ []) do
    build(:invalid_order, "Invalid order parameters", opts)
  end

  @doc "Creates an order not found error."
  @spec order_not_found(keyword()) :: t()
  def order_not_found(opts \\ []) do
    build(:order_not_found, "Order not found", opts)
  end

  @doc "Creates a bad request error."
  @spec bad_request(keyword()) :: t()
  def bad_request(opts \\ []) do
    build(:bad_request, "Bad request", opts)
  end

  @doc "Creates a bad symbol error."
  @spec bad_symbol(keyword()) :: t()
  def bad_symbol(opts \\ []) do
    build(:bad_symbol, "Invalid symbol", opts)
  end

  @doc "Creates a permission denied error."
  @spec permission_denied(keyword()) :: t()
  def permission_denied(opts \\ []) do
    build(:permission_denied, "Permission denied", opts)
  end

  @doc """
  Creates an access restricted error.

  Used when exchange returns HTML instead of JSON without Cloudflare
  markers — typically a wrong URL/prefix, geo/IP block, or landing page.
  Cloudflare challenges use `cloudflare_challenge/1` instead.
  """
  @spec access_restricted(keyword()) :: t()
  def access_restricted(opts \\ []) do
    build(:access_restricted, "Access restricted - exchange returned HTML instead of JSON", opts)
  end

  @doc """
  Creates a Cloudflare challenge error.

  Used when the exchange is reachable but served a Cloudflare anti-bot
  challenge page (e.g. "Just a moment..."). Inconclusive for integration
  tests — the client is reaching the right host but needs a browser or
  approved path to pass the challenge.
  """
  @spec cloudflare_challenge(keyword()) :: t()
  def cloudflare_challenge(opts \\ []) do
    build(:cloudflare_challenge, "Cloudflare challenge - exchange requires browser/approved client", opts)
  end

  @doc "Creates a not supported error."
  @spec not_supported(keyword()) :: t()
  def not_supported(opts \\ []) do
    build(:not_supported, "Method not supported by this exchange", opts)
  end

  @doc "Creates an operation failed error."
  @spec operation_failed(keyword()) :: t()
  def operation_failed(opts \\ []) do
    build(:operation_failed, "Operation failed", opts)
  end

  @doc "Creates an invalid parameters error."
  @spec invalid_parameters(keyword()) :: t()
  def invalid_parameters(opts \\ []) do
    build(:invalid_parameters, "Invalid request parameters", opts)
  end

  @doc "Creates a market closed error."
  @spec market_closed(keyword()) :: t()
  def market_closed(opts \\ []) do
    build(:market_closed, "Market is closed", opts)
  end

  @doc "Creates a circuit breaker open error."
  @spec circuit_open(keyword()) :: t()
  def circuit_open(opts \\ []) do
    build(:circuit_open, "Circuit breaker is open", opts)
  end

  @doc """
  Creates a generic exchange error.

  Use this for errors that don't fit other categories.
  """
  @spec exchange_error(String.t(), keyword()) :: t()
  def exchange_error(message, opts \\ []) do
    build(:exchange_error, message, opts)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Builds an error struct with consistent field population and auto-classified recoverability.
  @spec build(error_type(), String.t(), keyword()) :: t()
  defp build(type, default_message, opts) do
    %__MODULE__{
      type: type,
      message: Keyword.get(opts, :message, default_message),
      code: Keyword.get(opts, :code),
      retry_after: Keyword.get(opts, :retry_after),
      exchange: Keyword.get(opts, :exchange),
      raw: Keyword.get(opts, :raw),
      hints: Keyword.get(opts, :hints, []),
      recoverable: recoverable?(type),
      retry_class: retry_class(type)
    }
  end
end
