defmodule Bourse.TelemetryTest do
  use ExUnit.Case, async: true

  alias Bourse.Telemetry

  describe "contract_version/0" do
    test "returns version 2" do
      assert Telemetry.contract_version() == 2
    end
  end

  describe "event name functions" do
    test "request events" do
      assert Telemetry.request_start() == [:bourse, :request, :start]
      assert Telemetry.request_stop() == [:bourse, :request, :stop]
      assert Telemetry.request_exception() == [:bourse, :request, :exception]
    end

    test "circuit breaker events" do
      assert Telemetry.circuit_breaker_open() == [:bourse, :circuit_breaker, :open]
      assert Telemetry.circuit_breaker_closed() == [:bourse, :circuit_breaker, :closed]
      assert Telemetry.circuit_breaker_rejected() == [:bourse, :circuit_breaker, :rejected]
    end

    test "rate limiter event" do
      assert Telemetry.rate_limiter_throttled() == [:bourse, :rate_limiter, :throttled]
    end

    test "signing events" do
      assert Telemetry.signing_sign() == [:bourse, :signing, :sign]
    end

    test "ws message events" do
      assert Telemetry.ws_send() == [:bourse, :ws, :send]
      assert Telemetry.ws_message() == [:bourse, :ws, :message]
    end
  end

  describe "event lists" do
    test "events/0 returns all events" do
      assert length(Telemetry.events()) ==
               length(Telemetry.request_events()) +
                 length(Telemetry.circuit_breaker_events()) +
                 length(Telemetry.rate_limiter_events()) +
                 length(Telemetry.signing_events()) +
                 length(Telemetry.ws_events())
    end

    test "request_events/0 returns 3 events" do
      assert length(Telemetry.request_events()) == 3
    end

    test "circuit_breaker_events/0 returns 3 events" do
      assert length(Telemetry.circuit_breaker_events()) == 3
    end

    test "signing_events/0 returns 1 event" do
      assert length(Telemetry.signing_events()) == 1
    end

    test "ws_events/0 returns 2 events" do
      assert length(Telemetry.ws_events()) == 2
    end

    test "events/0 is union of all event groups" do
      assert Telemetry.events() ==
               Telemetry.request_events() ++
                 Telemetry.circuit_breaker_events() ++
                 Telemetry.rate_limiter_events() ++
                 Telemetry.signing_events() ++
                 Telemetry.ws_events()
    end
  end

  describe "attach/3 and detach/1" do
    test "attaches and detaches handler" do
      handler_fn = fn _event, _measurements, _metadata, _config -> :ok end
      assert :ok = Telemetry.attach("test-handler-telemetry", handler_fn)
      assert :ok = Telemetry.detach("test-handler-telemetry")
    end

    test "detach returns error for unknown handler" do
      assert {:error, :not_found} = Telemetry.detach("nonexistent-handler")
    end
  end
end
