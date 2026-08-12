defmodule Bourse.InvalidNonceClassificationTest do
  @moduledoc """
  Pins InvalidNonce → :invalid_nonce (retryable) and keeps credential rejection terminal.

  Task 604 / BUGS 2026-08-12: money-path consumers must not treat nonce/timestamp
  drift as a definite auth rejection.

  Authority (Binance Spot errors.md, -1021 INVALID_TIMESTAMP):
  https://github.com/binance/binance-spot-api-docs/blob/master/errors.md
  Documents "Timestamp for this request is outside of the recvWindow" and
  "Timestamp for this request was 1000ms ahead of the server's time" — client
  clock drift, not key rejection. Authored binance maps `-1021` → InvalidNonce;
  `-1022` INVALID_SIGNATURE stays AuthenticationError.
  """

  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.HTTP.Errors

  # Provider-owned statement for the retryable classification (Task 604 AC).
  @binance_timestamp_error_docs "https://github.com/binance/binance-spot-api-docs/blob/master/errors.md"

  test "InvalidNonce class is :invalid_nonce with retryable :network bucket" do
    assert Error.from_spec_class("InvalidNonce") == :invalid_nonce
    assert Error.retry_class(:invalid_nonce) == :network
    assert Error.should_retry?(Error.retry_class(:invalid_nonce))
    assert Error.should_retry?(Error.invalid_nonce())
  end

  test "AuthenticationError and PermissionDenied remain terminal :auth" do
    assert Error.from_spec_class("AuthenticationError") == :authentication_error
    assert Error.from_spec_class("PermissionDenied") == :permission_denied
    assert Error.retry_class(:authentication_error) == :auth
    assert Error.retry_class(:permission_denied) == :auth
    refute Error.should_retry?(Error.retry_class(:authentication_error))
    refute Error.should_retry?(Error.authentication_error())
    refute Error.should_retry?(Error.retry_class(:permission_denied))
    refute Error.should_retry?(Error.permission_denied())
  end

  test "binance -1021 (INVALID_TIMESTAMP) classifies as retryable :invalid_nonce" do
    # Provider authority for retryable classification (recvWindow / clock skew):
    assert @binance_timestamp_error_docs ==
             "https://github.com/binance/binance-spot-api-docs/blob/master/errors.md"

    exchange = Exchange.new!("binance")
    assert exchange.error_codes["-1021"] == :invalid_nonce
    assert exchange.retry_classification["InvalidNonce"] == :network

    body = %{"code" => -1021, "msg" => "Timestamp for this request is outside of the recvWindow."}

    assert {:error, %Error{type: :invalid_nonce, code: code, retry_class: :network, recoverable: true} = err} =
             Errors.classify_response(:get, 400, %{}, body, exchange)

    assert to_string(code) == "-1021"
    assert Error.should_retry?(err)
  end

  test "binance -1022 (INVALID_SIGNATURE) stays terminal :authentication_error" do
    exchange = Exchange.new!("binance")
    assert exchange.error_codes["-1022"] == :authentication_error

    body = %{"code" => -1022, "msg" => "Signature for this request is not valid."}

    assert {:error, %Error{type: :authentication_error, retry_class: :auth, recoverable: false} = err} =
             Errors.classify_response(:get, 400, %{}, body, exchange)

    refute Error.should_retry?(err)
  end

  test "bybit and okx InvalidNonce-mapped codes stay on the dedicated type" do
    bybit = Exchange.new!("bybit")
    assert bybit.error_codes["10002"] == :invalid_nonce

    okx = Exchange.new!("okx")
    assert okx.error_codes["50102"] == :invalid_nonce
    assert okx.error_codes["60006"] == :invalid_nonce
  end
end
