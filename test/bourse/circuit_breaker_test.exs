defmodule Bourse.CircuitBreakerTest do
  use Bourse.Test.Case, async: false

  import ExUnit.CaptureLog

  alias Bourse.CircuitBreaker
  alias Bourse.Error
  alias Bourse.Test.CircuitBreakerControl

  @moduletag trace_messages: true

  setup do
    exchange = "binance"
    unknown_exchange = "unknown_exchange_#{System.unique_integer([:positive])}"

    # The `:test` environment disables the breaker so it cannot couple unrelated
    # modules; this one asserts its behaviour, so it opts back in.
    CircuitBreakerControl.isolate!(exchange)

    {:ok, exchange: exchange, unknown_exchange: unknown_exchange}
  end

  # Blows the circuit by recording enough failures
  defp blow_circuit(exchange, failure_count \\ 5) do
    CircuitBreaker.check(exchange)
    for _ <- 1..failure_count, do: CircuitBreaker.record_failure(exchange)
  end

  describe "status/1" do
    test "returns :not_installed for unknown exchange", %{unknown_exchange: exchange} do
      assert CircuitBreaker.status(exchange) == :not_installed
    end

    test "returns :ok after fuse is installed via check", %{exchange: exchange} do
      assert CircuitBreaker.check(exchange) == :ok
      assert CircuitBreaker.status(exchange) == :ok
    end
  end

  describe "check/1" do
    test "installs fuse and returns :ok on first call", %{exchange: exchange} do
      assert CircuitBreaker.check(exchange) == :ok
      assert CircuitBreaker.status(exchange) == :ok
    end

    test "returns :ok when circuit is closed", %{exchange: exchange} do
      CircuitBreaker.check(exchange)
      assert CircuitBreaker.check(exchange) == :ok
    end

    test "returns :blown after circuit opens from failures", %{exchange: exchange} do
      log =
        capture_log(fn ->
          blow_circuit(exchange)
          assert CircuitBreaker.check(exchange) == :blown
          assert CircuitBreaker.status(exchange) == :blown
        end)

      assert log =~ "Circuit OPEN"
    end

    test "returns :ok when circuit breaker is disabled", %{exchange: exchange} do
      Application.put_env(:bourse, :circuit_breaker, %{enabled: false})
      on_exit(fn -> Application.delete_env(:bourse, :circuit_breaker) end)

      blow_circuit(exchange)
      assert CircuitBreaker.check(exchange) == :ok
    end
  end

  describe "reset/1" do
    test "returns {:error, :not_found} for unknown exchange", %{unknown_exchange: exchange} do
      assert CircuitBreaker.reset(exchange) == {:error, :not_found}
    end

    test "resets a blown circuit", %{exchange: exchange} do
      log =
        capture_log(fn ->
          blow_circuit(exchange)
          assert CircuitBreaker.status(exchange) == :blown
          assert CircuitBreaker.reset(exchange) == :ok
          assert CircuitBreaker.status(exchange) == :ok
        end)

      assert log =~ "Circuit OPEN"
    end
  end

  describe "reset!/1" do
    test "resets an installed circuit", %{exchange: exchange} do
      CircuitBreaker.check(exchange)

      assert CircuitBreaker.reset!(exchange) == :ok
    end

    test "raises for unknown exchange", %{unknown_exchange: exchange} do
      assert_raise ArgumentError, ~r/No circuit breaker found/, fn ->
        CircuitBreaker.reset!(exchange)
      end
    end
  end

  describe "exchange identity" do
    test "unknown identifiers never create atoms", %{unknown_exchange: exchange} do
      assert_raise ArgumentError, fn -> String.to_existing_atom(exchange) end

      assert CircuitBreaker.fuse_name(exchange) == nil
      assert CircuitBreaker.check(exchange) == :ok
      assert CircuitBreaker.record_failure(exchange) == :ok

      assert_raise ArgumentError, fn -> String.to_existing_atom(exchange) end
    end
  end

  describe "record_failure/1" do
    test "records failure without opening circuit under threshold", %{exchange: exchange} do
      CircuitBreaker.check(exchange)
      CircuitBreaker.record_failure(exchange)
      CircuitBreaker.record_failure(exchange)
      assert CircuitBreaker.status(exchange) == :ok
    end

    test "opens circuit after reaching threshold", %{exchange: exchange} do
      capture_log(fn ->
        blow_circuit(exchange)
        assert CircuitBreaker.status(exchange) == :blown
      end)
    end
  end

  describe "record_result/2" do
    test "does not melt on successful response", %{exchange: exchange} do
      CircuitBreaker.check(exchange)
      result = {:ok, %Req.Response{status: 200, headers: %{}, body: ""}}
      CircuitBreaker.record_result(exchange, result)
      assert CircuitBreaker.status(exchange) == :ok
    end

    test "does not melt on 429 rate limit", %{exchange: exchange} do
      CircuitBreaker.check(exchange)
      result = {:ok, %Req.Response{status: 429, headers: %{}, body: ""}}

      for _ <- 1..10 do
        CircuitBreaker.record_result(exchange, result)
      end

      assert CircuitBreaker.status(exchange) == :ok
    end

    test "does not melt on 400 client error", %{exchange: exchange} do
      CircuitBreaker.check(exchange)
      result = {:ok, %Req.Response{status: 400, headers: %{}, body: ""}}

      for _ <- 1..10 do
        CircuitBreaker.record_result(exchange, result)
      end

      assert CircuitBreaker.status(exchange) == :ok
    end

    test "melts on 500 server error", %{exchange: exchange} do
      capture_log(fn ->
        CircuitBreaker.check(exchange)
        result = {:ok, %Req.Response{status: 500, headers: %{}, body: ""}}

        for _ <- 1..5 do
          CircuitBreaker.record_result(exchange, result)
        end

        assert CircuitBreaker.status(exchange) == :blown
      end)
    end

    test "melts on transport error", %{exchange: exchange} do
      capture_log(fn ->
        CircuitBreaker.check(exchange)
        result = {:error, %Req.TransportError{reason: :timeout}}

        for _ <- 1..5 do
          CircuitBreaker.record_result(exchange, result)
        end

        assert CircuitBreaker.status(exchange) == :blown
      end)
    end
  end

  describe "should_melt?/1" do
    test "melts on 500+" do
      assert CircuitBreaker.should_melt?({:ok, %Req.Response{status: 500, headers: %{}, body: ""}})
      assert CircuitBreaker.should_melt?({:ok, %Req.Response{status: 502, headers: %{}, body: ""}})
    end

    test "does not melt on 2xx/4xx" do
      refute CircuitBreaker.should_melt?({:ok, %Req.Response{status: 200, headers: %{}, body: ""}})
      refute CircuitBreaker.should_melt?({:ok, %Req.Response{status: 400, headers: %{}, body: ""}})
      refute CircuitBreaker.should_melt?({:ok, %Req.Response{status: 429, headers: %{}, body: ""}})
    end

    test "melts on transport errors" do
      assert CircuitBreaker.should_melt?({:error, %Req.TransportError{reason: :timeout}})
      assert CircuitBreaker.should_melt?({:error, %Req.TransportError{reason: :econnrefused}})
      assert CircuitBreaker.should_melt?({:error, :closed})
    end

    test "does not melt on nil or other values" do
      refute CircuitBreaker.should_melt?(nil)
      refute CircuitBreaker.should_melt?(:ok)
    end

    test "melts on normalized errors classified :network or :server_busy" do
      assert CircuitBreaker.should_melt?({:error, Error.network_error()})
      assert CircuitBreaker.should_melt?({:error, Error.exchange_not_available()})
    end

    test "does not melt on :invalid_nonce despite its retryable :network class" do
      # Nonce/timestamp drift is client-side (clock skew, recvWindow); melting
      # would block the whole exchange, public reads included.
      err = Error.invalid_nonce()
      assert err.retry_class == :network
      refute CircuitBreaker.should_melt?({:error, err})
    end

    test "does not melt on rate_limit / auth / non_retryable normalized errors" do
      refute CircuitBreaker.should_melt?({:error, Error.rate_limit_exceeded()})
      refute CircuitBreaker.should_melt?({:error, Error.authentication_error()})
      refute CircuitBreaker.should_melt?({:error, Error.insufficient_funds()})
      refute CircuitBreaker.should_melt?({:error, Error.exchange_error("x")})
    end

    test "melts on a 5xx-tagged error regardless of retry classification" do
      # An HTML 5xx resolves to access_restricted (:non_retryable) but the
      # http_status fallback still trips the breaker.
      err = %{Error.access_restricted() | http_status: 503}
      assert CircuitBreaker.should_melt?({:error, err})
    end

    test "does not melt on a 4xx-tagged non-retryable error" do
      err = %{Error.bad_request() | http_status: 400}
      refute CircuitBreaker.should_melt?({:error, err})
    end
  end

  describe "record_result/2 with normalized Bourse.Error outcomes" do
    test "melts after enough :server_busy errors", %{exchange: exchange} do
      capture_log(fn ->
        CircuitBreaker.check(exchange)

        for _ <- 1..5 do
          CircuitBreaker.record_result(exchange, {:error, Error.exchange_not_available()})
        end

        assert CircuitBreaker.status(exchange) == :blown
      end)
    end

    test "does not melt on repeated rate_limit errors", %{exchange: exchange} do
      CircuitBreaker.check(exchange)

      for _ <- 1..10 do
        CircuitBreaker.record_result(exchange, {:error, Error.rate_limit_exceeded()})
      end

      assert CircuitBreaker.status(exchange) == :ok
    end

    test "does not melt on a successful normalized outcome", %{exchange: exchange} do
      CircuitBreaker.check(exchange)
      CircuitBreaker.record_result(exchange, {:ok, %{"result" => "ok"}})
      assert CircuitBreaker.status(exchange) == :ok
    end
  end

  describe "all_statuses/0" do
    test "returns map of installed exchanges", %{exchange: exchange} do
      CircuitBreaker.check(exchange)
      statuses = CircuitBreaker.all_statuses()
      assert is_map(statuses)
      assert Map.get(statuses, exchange) == :ok
    end

    test "omits a tracked fuse that no longer exists", %{exchange: exchange} do
      CircuitBreaker.check(exchange)
      :ok = :fuse.remove(CircuitBreaker.fuse_name(exchange))

      refute Map.has_key?(CircuitBreaker.all_statuses(), exchange)
    end
  end

  describe "config/0" do
    test "returns default config" do
      config = CircuitBreaker.config()
      assert config.enabled == true
      assert config.max_failures == 5
      assert config.window_ms == 10_000
      assert config.reset_ms == 15_000
    end

    test "reads keyword configuration" do
      Application.put_env(:bourse, :circuit_breaker, enabled: false, max_failures: 2)
      on_exit(fn -> Application.delete_env(:bourse, :circuit_breaker) end)

      assert %{enabled: false, max_failures: 2} = CircuitBreaker.config()
    end

    test "falls back to defaults for an unsupported configuration value" do
      Application.put_env(:bourse, :circuit_breaker, :invalid)
      on_exit(fn -> Application.delete_env(:bourse, :circuit_breaker) end)

      assert %{enabled: true, max_failures: 5, window_ms: 10_000, reset_ms: 15_000} =
               CircuitBreaker.config()
    end
  end

  describe "telemetry emission" do
    setup do
      parent = self()
      ref = make_ref()
      handler_id = "cb-telemetry-test-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:bourse, :circuit_breaker, :open],
          [:bourse, :circuit_breaker, :closed],
          [:bourse, :circuit_breaker, :rejected]
        ],
        fn event, _measurements, metadata, _config ->
          send(parent, {:telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :open event when circuit opens", %{exchange: exchange} do
      capture_log(fn -> blow_circuit(exchange) end)
      assert_received {:telemetry, [:bourse, :circuit_breaker, :open], %{exchange: ^exchange}}
    end

    test "emits :closed event when circuit is reset", %{exchange: exchange} do
      capture_log(fn ->
        blow_circuit(exchange)
        CircuitBreaker.reset(exchange)
      end)

      assert_received {:telemetry, [:bourse, :circuit_breaker, :closed], %{exchange: ^exchange}}
    end

    test "emits :rejected event when request hits blown circuit", %{exchange: exchange} do
      capture_log(fn ->
        blow_circuit(exchange)
        CircuitBreaker.check(exchange)
      end)

      assert_received {:telemetry, [:bourse, :circuit_breaker, :rejected], %{exchange: ^exchange}}
    end
  end
end
