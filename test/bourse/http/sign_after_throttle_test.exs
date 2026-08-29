defmodule Bourse.HTTP.SignAfterThrottleTest do
  use ExUnit.Case, async: false

  alias Bourse.Exchange
  alias Bourse.HTTP
  alias Bourse.RateLimiter.Shaping
  alias Bourse.Signing.SignedRequest

  @moduletag trace_messages: true

  test "the resigner runs after the limiter releases, not before the wait" do
    exchange = %Exchange{
      id: "sign_after_#{System.unique_integer([:positive])}",
      name: "Sign After",
      credentials: nil,
      sandbox: false,
      rate_limit_ms: 500,
      hostname: nil,
      base_urls: %{"public" => "http://127.0.0.1:1"},
      has: %{},
      required_credentials: %{},
      options: %{},
      error_codes: %{},
      broad_error_patterns: %{},
      error_body_checks: [],
      error_code_fields: [],
      http_exceptions: %{},
      spec: %{}
    }

    rate_key = Shaping.rate_key(exchange)
    assert :ok = Shaping.maybe_rate_limit(rate_key, exchange, 1)

    parent = self()
    started = System.monotonic_time(:millisecond)

    resigner = fn ->
      send(parent, {:signed_at, System.monotonic_time(:millisecond)})

      %SignedRequest{
        url: "/probe",
        method: :get,
        headers: [],
        body: nil
      }
    end

    result =
      HTTP.signed_request(exchange, nil, "http://127.0.0.1:1", resigner, retry: false)

    assert {:error, _} = result
    assert_received {:signed_at, signed_at}
    assert signed_at - started >= 200
  end
end
