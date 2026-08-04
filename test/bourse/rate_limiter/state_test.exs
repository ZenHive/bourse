defmodule Bourse.RateLimiter.StateTest do
  use Bourse.Test.Case, async: false

  alias Bourse.RateLimiter.Info
  alias Bourse.RateLimiter.State

  @moduletag trace_messages: true

  # State uses a named ETS table, so tests must be sequential.
  # The Application starts State automatically.

  describe "update/2 and status/1-2" do
    test "stores independent bucket axes for the same credential" do
      ip_info = %Info{exchange: "binance", remaining: 400, source: :binance_weight}
      order_info = %Info{exchange: "binance", remaining: 10, source: :binance_order_count}

      :ok = State.update({"binance", :public, "ip"}, ip_info)
      :ok = State.update({"binance", :public, "order_weight"}, order_info)

      assert %Info{remaining: 400} = State.status("binance", :public, "ip")
      assert %Info{remaining: 10} = State.status("binance", :public, "order_weight")
    end

    test "stores and retrieves info for public key" do
      info = %Info{exchange: "binance", limit: 1200, used: 800, remaining: 400, source: :binance_weight}
      key = {"binance", :public}

      :ok = State.update(key, info)

      assert %Info{exchange: "binance", remaining: 400} = State.status("binance")
      assert %Info{exchange: "binance", remaining: 400} = State.status("binance", :public)
    end

    test "stores and retrieves info for authenticated key" do
      info = %Info{exchange: "bybit", limit: 120, remaining: 80, source: :bybit_bapi}
      key = {"bybit", "my_api_key"}

      :ok = State.update(key, info)

      assert %Info{remaining: 80} = State.status("bybit", "my_api_key")
      # Authenticated key update must not bleed into public key
      assert State.status("bybit", :public) == nil
    end

    test "overwrites previous value" do
      key = {"binance", :public}

      :ok = State.update(key, %Info{exchange: "binance", remaining: 400, source: :binance_weight})
      :ok = State.update(key, %Info{exchange: "binance", remaining: 200, source: :binance_weight})

      assert %Info{remaining: 200} = State.status("binance")
    end
  end

  describe "all/1" do
    test "returns all entries for an exchange" do
      :ok = State.update({"gate", :public}, %Info{exchange: "gate", remaining: 50, source: :standard})
      :ok = State.update({"gate", "key_1"}, %Info{exchange: "gate", remaining: 30, source: :standard})

      entries = State.all("gate")
      assert length(entries) >= 2
      assert Enum.all?(entries, &match?(%Info{exchange: "gate"}, &1))
    end

    test "returns empty list for unknown exchange" do
      assert State.all("nonexistent_exchange_#{:erlang.unique_integer([:positive])}") == []
    end
  end

  describe "status/1 returns nil for missing keys" do
    test "returns nil for untracked exchange" do
      assert State.status("never_tracked_#{:erlang.unique_integer([:positive])}") == nil
    end
  end
end
