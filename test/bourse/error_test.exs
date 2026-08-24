defmodule Bourse.ErrorTest do
  use ExUnit.Case, async: true

  alias Bourse.Error

  # ===========================================================================
  # Factory Functions
  # ===========================================================================

  describe "rate_limit_exceeded/1" do
    test "creates error with defaults" do
      error = Error.rate_limit_exceeded()
      assert error.type == :rate_limit_exceeded
      assert error.message == "Rate limit exceeded"
      assert is_nil(error.retry_after)
    end

    test "creates error with retry_after and exchange" do
      error = Error.rate_limit_exceeded(retry_after: 1000, exchange: "binance")
      assert error.retry_after == 1000
      assert error.exchange == "binance"
    end
  end

  describe "network_error/1" do
    test "creates error with custom message" do
      error = Error.network_error(message: "Connection timeout")
      assert error.type == :network_error
      assert error.message == "Connection timeout"
    end
  end

  describe "exchange_not_available/1" do
    test "creates error with defaults" do
      error = Error.exchange_not_available()
      assert error.type == :exchange_not_available
      assert error.message == "Exchange not available"
    end
  end

  describe "authentication_error/1" do
    test "creates error with custom message" do
      error = Error.authentication_error(message: "API key expired")
      assert error.type == :authentication_error
      assert error.message == "API key expired"
    end
  end

  describe "invalid_nonce/1" do
    test "creates error with defaults" do
      error = Error.invalid_nonce()
      assert error.type == :invalid_nonce
      assert error.message =~ "nonce"
      assert error.recoverable == true
      assert error.retry_class == :network
    end

    test "creates error with custom message and code" do
      error = Error.invalid_nonce(message: "Timestamp outside recvWindow", code: -1021, exchange: "binance")
      assert error.type == :invalid_nonce
      assert error.code == -1021
      assert error.exchange == "binance"
      assert error.message == "Timestamp outside recvWindow"
    end
  end

  describe "insufficient_funds/1" do
    test "creates error with exchange and code" do
      error = Error.insufficient_funds(exchange: "bybit", code: "10001")
      assert error.type == :insufficient_funds
      assert error.exchange == "bybit"
      assert error.code == "10001"
    end
  end

  describe "invalid_order/1" do
    test "creates error with message" do
      error = Error.invalid_order(message: "Price too low")
      assert error.type == :invalid_order
      assert error.message == "Price too low"
    end
  end

  describe "order_not_found/1" do
    test "creates error with raw" do
      error = Error.order_not_found(raw: %{"error" => "no order"})
      assert error.type == :order_not_found
      assert error.raw == %{"error" => "no order"}
    end
  end

  describe "bad_request/1" do
    test "creates error with defaults" do
      error = Error.bad_request()
      assert error.type == :bad_request
      assert error.message == "Bad request"
    end
  end

  describe "bad_symbol/1" do
    test "creates error with defaults" do
      error = Error.bad_symbol()
      assert error.type == :bad_symbol
      assert error.message == "Invalid symbol"
    end
  end

  describe "permission_denied/1" do
    test "creates error with defaults" do
      error = Error.permission_denied()
      assert error.type == :permission_denied
      assert error.message == "Permission denied"
    end
  end

  describe "access_restricted/1" do
    test "creates error with defaults" do
      error = Error.access_restricted()
      assert error.type == :access_restricted
      assert error.message =~ "Access restricted"
    end

    test "creates error with custom message and hints" do
      error =
        Error.access_restricted(
          message: "Received HTML page 'Access Denied'",
          code: 403,
          exchange: "okx",
          hints: ["Check VPN", "Verify API URL"]
        )

      assert error.code == 403
      assert error.exchange == "okx"
      assert error.hints == ["Check VPN", "Verify API URL"]
    end
  end

  describe "cloudflare_challenge/1" do
    test "creates error with defaults" do
      error = Error.cloudflare_challenge()
      assert error.type == :cloudflare_challenge
    end

    test "preserves custom message, code, exchange, and hints" do
      error =
        Error.cloudflare_challenge(
          message: "Cloudflare challenge page 'Just a moment...' received",
          code: 403,
          exchange: "btcbox",
          hints: ["Cloudflare challenge detected"]
        )

      assert error.code == 403
      assert error.exchange == "btcbox"
      assert error.message =~ "Just a moment"
      assert error.hints == ["Cloudflare challenge detected"]
    end
  end

  describe "not_supported/1" do
    test "creates error with defaults" do
      error = Error.not_supported()
      assert error.type == :not_supported
    end
  end

  describe "operation_failed/1" do
    test "creates error with defaults" do
      error = Error.operation_failed()
      assert error.type == :operation_failed
      assert error.message == "Operation failed"
    end
  end

  describe "invalid_parameters/1" do
    test "creates error with custom message" do
      error = Error.invalid_parameters(message: "Missing required field: symbol", exchange: "binance")
      assert error.type == :invalid_parameters
      assert error.message == "Missing required field: symbol"
      assert error.exchange == "binance"
    end
  end

  describe "market_closed/1" do
    test "creates error with defaults" do
      error = Error.market_closed()
      assert error.type == :market_closed
      assert error.message == "Market is closed"
    end
  end

  describe "circuit_open/1" do
    test "creates error with exchange" do
      error = Error.circuit_open(exchange: "binance")
      assert error.type == :circuit_open
      assert error.exchange == "binance"
    end
  end

  describe "exchange_error/2" do
    test "creates generic exchange error" do
      error = Error.exchange_error("Unknown error occurred", code: 500, exchange: "kraken")
      assert error.type == :exchange_error
      assert error.message == "Unknown error occurred"
      assert error.code == 500
      assert error.exchange == "kraken"
    end
  end

  describe "message/1" do
    test "prefixes the exchange id when one is set" do
      error = Error.insufficient_funds(exchange: "bybit", message: "not enough USDT")

      assert Exception.message(error) == "[bybit] insufficient_funds: not enough USDT"
    end

    test "omits the prefix when exchange is nil" do
      error = Error.insufficient_funds(message: "not enough USDT")

      assert error.exchange == nil
      assert Exception.message(error) == "insufficient_funds: not enough USDT"
    end
  end

  # ===========================================================================
  # Recoverability
  # ===========================================================================

  describe "recoverable? auto-populated on errors" do
    test "recoverable types" do
      assert Error.rate_limit_exceeded().recoverable == true
      assert Error.network_error().recoverable == true
      assert Error.exchange_not_available().recoverable == true
      assert Error.invalid_nonce().recoverable == true
    end

    test "non-recoverable types" do
      assert Error.authentication_error().recoverable == false
      assert Error.insufficient_funds().recoverable == false
      assert Error.invalid_order().recoverable == false
      assert Error.order_not_found().recoverable == false
      assert Error.bad_request().recoverable == false
      assert Error.bad_symbol().recoverable == false
      assert Error.permission_denied().recoverable == false
      assert Error.access_restricted().recoverable == false
      assert Error.cloudflare_challenge().recoverable == false
      assert Error.not_supported().recoverable == false
      assert Error.operation_failed().recoverable == false
      assert Error.invalid_parameters().recoverable == false
      assert Error.market_closed().recoverable == false
      assert Error.circuit_open().recoverable == false
    end

    test "exchange_error has nil recoverability" do
      assert Error.exchange_error("Unknown").recoverable == nil
    end
  end

  describe "recoverable?/1" do
    test "returns true for recoverable types" do
      assert Error.recoverable?(:rate_limit_exceeded) == true
      assert Error.recoverable?(:network_error) == true
      assert Error.recoverable?(:exchange_not_available) == true
      assert Error.recoverable?(:invalid_nonce) == true
    end

    test "returns false for non-recoverable types" do
      assert Error.recoverable?(:authentication_error) == false
      assert Error.recoverable?(:permission_denied) == false
      assert Error.recoverable?(:insufficient_funds) == false
    end

    test "returns nil for exchange_error" do
      assert Error.recoverable?(:exchange_error) == nil
    end

    test "returns nil for a type outside the declared error_type set" do
      assert Error.recoverable?(:not_a_real_error_type) == nil
    end
  end

  describe "recoverable_types/0 and non_recoverable_types/0" do
    test "returns lists" do
      assert is_list(Error.recoverable_types())
      assert :rate_limit_exceeded in Error.recoverable_types()
      assert is_list(Error.non_recoverable_types())
      assert :authentication_error in Error.non_recoverable_types()
    end
  end

  # ===========================================================================
  # Spec Class Mapping
  # ===========================================================================

  describe "from_spec_class/1" do
    test "maps common Bourse error classes" do
      assert Error.from_spec_class("AuthenticationError") == :authentication_error
      assert Error.from_spec_class("InsufficientFunds") == :insufficient_funds
      assert Error.from_spec_class("InvalidOrder") == :invalid_order
      assert Error.from_spec_class("OrderNotFound") == :order_not_found
      assert Error.from_spec_class("RateLimitExceeded") == :rate_limit_exceeded
      assert Error.from_spec_class("ExchangeError") == :exchange_error
    end

    test "strips __function: prefix" do
      assert Error.from_spec_class("__function:AuthenticationError") == :authentication_error
      assert Error.from_spec_class("__function:InsufficientFunds") == :insufficient_funds
      assert Error.from_spec_class("__function:BadSymbol") == :bad_symbol
    end

    test "maps related classes to same type" do
      # InvalidNonce is its own retryable type (Task 604) — not credential rejection
      assert Error.from_spec_class("InvalidNonce") == :invalid_nonce
      assert Error.from_spec_class("AuthenticationError") == :authentication_error

      # Multiple classes map to :invalid_order
      assert Error.from_spec_class("OrderImmediatelyFillable") == :invalid_order
      assert Error.from_spec_class("OrderNotFillable") == :invalid_order
      assert Error.from_spec_class("DuplicateOrderId") == :invalid_order

      # Multiple classes map to :exchange_not_available
      assert Error.from_spec_class("OnMaintenance") == :exchange_not_available
      assert Error.from_spec_class("ExchangeNotAvailable") == :exchange_not_available
      assert Error.from_spec_class("MarketClosed") == :exchange_not_available
    end

    test "returns :exchange_error for unknown classes" do
      assert Error.from_spec_class("SomeNewErrorClass") == :exchange_error
      assert Error.from_spec_class("__function:UnknownType") == :exchange_error
    end
  end

  describe "spec_class_mapping/0" do
    test "returns a map with all 34 Bourse error classes" do
      mapping = Error.spec_class_mapping()
      assert is_map(mapping)
      assert map_size(mapping) >= 30
      assert mapping["AuthenticationError"] == :authentication_error
    end
  end

  # ===========================================================================
  # Retry Classification (Phase 13 — errors.retry_classification)
  # ===========================================================================

  describe "retry_class/1" do
    test "maps recoverable types to their retry buckets" do
      assert Error.retry_class(:rate_limit_exceeded) == :rate_limit
      assert Error.retry_class(:network_error) == :network
      assert Error.retry_class(:exchange_not_available) == :server_busy
      assert Error.retry_class(:invalid_nonce) == :network
    end

    test "maps auth-class types to :auth" do
      assert Error.retry_class(:authentication_error) == :auth
      assert Error.retry_class(:permission_denied) == :auth
    end

    # Task 604: nonce/timestamp drift must stay retryable; credential rejection stays terminal.
    test "splits InvalidNonce (retryable) from AuthenticationError / PermissionDenied (terminal)" do
      assert Error.from_spec_class("InvalidNonce") == :invalid_nonce
      assert Error.retry_class(:invalid_nonce) == :network
      assert Error.should_retry?(Error.retry_class(:invalid_nonce))
      assert Error.should_retry?(Error.invalid_nonce())

      assert Error.from_spec_class("AuthenticationError") == :authentication_error
      assert Error.retry_class(:authentication_error) == :auth
      refute Error.should_retry?(Error.retry_class(:authentication_error))
      refute Error.should_retry?(Error.authentication_error())

      assert Error.from_spec_class("PermissionDenied") == :permission_denied
      assert Error.retry_class(:permission_denied) == :auth
      refute Error.should_retry?(Error.retry_class(:permission_denied))
      refute Error.should_retry?(Error.permission_denied())
    end

    test "maps deterministic rejections to :non_retryable" do
      assert Error.retry_class(:insufficient_funds) == :non_retryable
      assert Error.retry_class(:invalid_order) == :non_retryable
      assert Error.retry_class(:bad_request) == :non_retryable
      assert Error.retry_class(:order_not_found) == :non_retryable
    end

    test "returns nil for the generic / unknown type" do
      assert Error.retry_class(:exchange_error) == nil
      assert Error.retry_class(:totally_unknown) == nil
    end

    test "is consistent with recoverable?/1" do
      # Every recoverable type has a retryable bucket; every non-recoverable
      # type has a non-retryable bucket. exchange_error has neither.
      for type <- Error.recoverable_types() do
        assert Error.should_retry?(Error.retry_class(type)), "#{type} should be retryable"
      end

      for type <- Error.non_recoverable_types() do
        refute Error.should_retry?(Error.retry_class(type)), "#{type} should not be retryable"
      end
    end
  end

  describe "retry_class auto-populated on errors" do
    test "factory errors carry the retry bucket" do
      assert Error.rate_limit_exceeded().retry_class == :rate_limit
      assert Error.network_error().retry_class == :network
      assert Error.exchange_not_available().retry_class == :server_busy
      assert Error.invalid_nonce().retry_class == :network
      assert Error.authentication_error().retry_class == :auth
      assert Error.insufficient_funds().retry_class == :non_retryable
      assert Error.exchange_error("x").retry_class == nil
    end
  end

  describe "should_retry?/1" do
    test "true for retryable buckets" do
      assert Error.should_retry?(:rate_limit)
      assert Error.should_retry?(:network)
      assert Error.should_retry?(:server_busy)
    end

    test "false for non-retryable buckets and nil" do
      refute Error.should_retry?(:auth)
      refute Error.should_retry?(:non_retryable)
      refute Error.should_retry?(nil)
    end

    test "accepts an error struct" do
      assert Error.should_retry?(Error.network_error())
      assert Error.should_retry?(Error.invalid_nonce())
      refute Error.should_retry?(Error.authentication_error())
      refute Error.should_retry?(Error.permission_denied())
      refute Error.should_retry?(Error.exchange_error("x"))
    end
  end

  describe "retry_class_mapping/0" do
    test "covers every non-generic error type exactly once" do
      mapping = Error.retry_class_mapping()
      assert is_map(mapping)
      # exchange_error is intentionally absent (unclassified).
      refute Map.has_key?(mapping, :exchange_error)
      assert mapping[:rate_limit_exceeded] == :rate_limit
    end
  end

  describe "from_spec_class/2 (hierarchy-aware)" do
    test "direct mapping wins over ancestors" do
      assert Error.from_spec_class("InsufficientFunds", %{}) == :insufficient_funds
    end

    test "resolves an unmapped class through its nearest mapped ancestor" do
      ancestors = %{
        "AddressPending" => ["InvalidAddress", "ExchangeError", "BaseError"],
        "ChecksumError" => ["InvalidNonce", "NetworkError", "OperationFailed", "BaseError"],
        "OrderNotCached" => ["InvalidOrder", "ExchangeError", "BaseError"]
      }

      assert Error.from_spec_class("AddressPending", ancestors) == :bad_request
      # ChecksumError → InvalidNonce → :invalid_nonce (retryable, not auth)
      assert Error.from_spec_class("ChecksumError", ancestors) == :invalid_nonce
      assert Error.from_spec_class("OrderNotCached", ancestors) == :invalid_order
    end

    test "strips __function: prefix on the class and its ancestors" do
      ancestors = %{"AddressPending" => ["__function:InvalidAddress"]}
      assert Error.from_spec_class("__function:AddressPending", ancestors) == :bad_request
    end

    test "falls back to :exchange_error when neither class nor ancestors are known" do
      assert Error.from_spec_class("TotallyUnknown", %{}) == :exchange_error
      assert Error.from_spec_class("UnsubscribeError", %{"UnsubscribeError" => ["BaseError"]}) == :exchange_error
    end

    test "strips the __function: prefix on the direct mapping path, without ancestors" do
      assert Error.from_spec_class("__function:InsufficientFunds", %{}) == :insufficient_funds
      assert Error.from_spec_class("__function:AuthenticationError", %{}) == :authentication_error
    end

    test "rejects a non-binary class name" do
      assert_raise FunctionClauseError, fn -> Error.from_spec_class(untyped(:insufficient_funds), %{}) end
    end

    test "rejects a non-map ancestors argument" do
      assert_raise FunctionClauseError, fn -> Error.from_spec_class("InsufficientFunds", untyped(nil)) end
    end
  end

  # Hides the value from compile-time type inference so the runtime guard, not the
  # type checker, is what rejects it.
  defp untyped(value), do: Enum.random([value])
end
