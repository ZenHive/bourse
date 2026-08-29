defmodule Bourse.DefaultsTest do
  use ExUnit.Case, async: true

  alias Bourse.Defaults

  describe "recv_window_ms/0" do
    test "returns default value" do
      assert Defaults.recv_window_ms() == 5_000
    end
  end

  describe "rate_limit_max_wait_ms/0" do
    test "returns default value" do
      assert Defaults.rate_limit_max_wait_ms() == 10_000
    end
  end

  describe "request_timeout_ms/0" do
    test "returns default value" do
      assert Defaults.request_timeout_ms() == 30_000
    end
  end

  describe "retry_policy/0" do
    test "returns :safe_transient by default" do
      assert Defaults.retry_policy() == :safe_transient
    end
  end

  describe "raw_defaults/0" do
    test "returns map of all defaults" do
      defaults = Defaults.raw_defaults()
      assert defaults.recv_window_ms == 5_000
      assert defaults.request_timeout_ms == 30_000
      assert defaults.retry_policy == :safe_transient
      assert defaults.rate_limit_max_wait_ms == 10_000
    end
  end

  describe "Application config overrides" do
    test "request_timeout_ms respects config override" do
      Application.put_env(:bourse, :request_timeout_ms, 60_000)
      on_exit(fn -> Application.delete_env(:bourse, :request_timeout_ms) end)
      assert Defaults.request_timeout_ms() == 60_000
    end

    test "recv_window_ms respects config override" do
      Application.put_env(:bourse, :recv_window_ms, 10_000)
      on_exit(fn -> Application.delete_env(:bourse, :recv_window_ms) end)
      assert Defaults.recv_window_ms() == 10_000
    end

    test "retry_policy respects config override" do
      Application.put_env(:bourse, :retry_policy, false)
      on_exit(fn -> Application.delete_env(:bourse, :retry_policy) end)
      assert Defaults.retry_policy() == false
    end
  end
end
