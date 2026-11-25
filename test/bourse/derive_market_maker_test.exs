defmodule Bourse.DeriveMarketMakerTest do
  @moduledoc """
  Offline checks for the pure pieces of the Derive market-maker journey
  (`test/live/journeys/market_maker/derive_test.exs`): the read arguments it
  passes, frame collection in either arrival order, position restore, and
  cleanup that never masks the body's failure.
  """
  use ExUnit.Case, async: true

  alias Bourse.Test.DeriveMarketMaker, as: MM

  @orders "42.orders"
  @trades "42.trades"

  defp order_frame(id),
    do:
      {:websocket_message,
       %{"params" => %{"channel" => @orders, "data" => [%{"order_id" => id, "order_status" => "filled"}]}}}

  defp trade_frame(id),
    do:
      {:websocket_message,
       %{"params" => %{"channel" => @trades, "data" => [%{"order_id" => id, "trade_id" => "t-" <> id}]}}}

  defp wanted(id) do
    [
      {:order, @orders, &(&1["order_id"] == id and &1["order_status"] == "filled")},
      {:trade, @trades, &(&1["order_id"] == id)}
    ]
  end

  describe "the journey's read arguments" do
    setup do
      {:ok, exchange} = Bourse.Exchange.new("derive", sandbox: true, options: %{"subaccount_id" => 42})
      %{exchange: exchange}
    end

    test "the forms the journey uses pass argument validation and stop only at the missing credential", %{exchange: ex} do
      assert {:error, %Bourse.Error{type: :authentication_error}} = Bourse.fetch_positions(ex)
      assert {:error, %Bourse.Error{type: :authentication_error}} = Bourse.fetch_my_trades(ex, symbol: "BTC/USDC:USDC")
    end

    test "the forms the reviewer reproduced are refused before dispatch", %{exchange: ex} do
      assert {:error, %Bourse.Error{type: :bad_request}} = Bourse.fetch_positions(ex, ["BTC/USDC:USDC"])
      assert {:error, %Bourse.Error{type: :bad_request}} = Bourse.fetch_my_trades(ex, "BTC/USDC:USDC")
    end
  end

  describe "await_all!/2" do
    test "collects both events when the order frame arrives first" do
      send(self(), order_frame("o1"))
      send(self(), trade_frame("o1"))
      assert %{order: %{"order_id" => "o1"}, trade: %{"trade_id" => "t-o1"}} = MM.await_all!(wanted("o1"), 200)
    end

    test "collects both events when the trade frame arrives first" do
      send(self(), trade_frame("o1"))
      send(self(), order_frame("o1"))
      assert %{order: %{"order_id" => "o1"}, trade: %{"trade_id" => "t-o1"}} = MM.await_all!(wanted("o1"), 200)
    end

    test "ignores other orders and unrelated messages, and keeps the first match" do
      send(self(), trade_frame("other"))
      send(self(), :unrelated)
      send(self(), {:websocket_message, %{"result" => "ok"}})
      send(self(), trade_frame("o1"))

      # The duplicate is queued while the order event is still pending, so the
      # collector reads it before the pair completes.
      send(
        self(),
        "o1" |> trade_frame() |> put_in([Access.elem(1), "params", "data"], [%{"order_id" => "o1", "trade_id" => "late"}])
      )

      send(self(), {:websocket_unmatched_response, elem(order_frame("o1"), 1)})

      assert %{order: %{"order_id" => "o1"}, trade: %{"trade_id" => "t-o1"}} = MM.await_all!(wanted("o1"), 200)
    end

    test "flunks naming the event still missing" do
      send(self(), trade_frame("o1"))
      error = assert_raise ExUnit.AssertionError, fn -> MM.await_all!(wanted("o1"), 50) end
      assert error.message =~ ~s(order: "42.orders")
      refute error.message =~ "42.trades"
    end

    test "a frame that arrives after the deadline is not accepted, even when it completes the pair" do
      test = self()

      spawn(fn ->
        Process.sleep(80)
        send(test, order_frame("o1"))
      end)

      send(self(), trade_frame("o1"))

      error = assert_raise ExUnit.AssertionError, fn -> MM.await_all!(wanted("o1"), 30) end
      assert error.message =~ ~s(order: "42.orders")
    end

    test "a frame already queued when a slow predicate runs past the deadline is not accepted" do
      send(self(), trade_frame("o1"))
      send(self(), order_frame("o1"))

      slow = [
        {:trade, @trades, fn row -> Process.sleep(40) && row["order_id"] == "o1" end},
        {:order, @orders, &(&1["order_id"] == "o1")}
      ]

      error = assert_raise ExUnit.AssertionError, fn -> MM.await_all!(slow, 15) end
      assert error.message =~ ~s(order: "42.orders")
    end

    test "noise arriving while an event is pending does not extend the deadline" do
      # The trade completes at once; then twenty foreign order frames, each
      # costing ~10ms in the predicate, precede the owned order. It is reached
      # only if every frame restarted the clock.
      send(self(), trade_frame("o1"))
      for n <- 1..20, do: send(self(), order_frame("other-#{n}"))
      send(self(), order_frame("o1"))

      slow_order = fn row -> Process.sleep(10) && row["order_id"] == "o1" end
      wanted = [{:order, @orders, slow_order}, {:trade, @trades, &(&1["order_id"] == "o1")}]

      error = assert_raise ExUnit.AssertionError, fn -> MM.await_all!(wanted, 50) end
      assert error.message =~ ~s(order: "42.orders")
    end
  end

  describe "position restore" do
    test "signed_size sums the instrument's signed provider amounts, from structs or raw rows" do
      positions = [
        %{info: %{"instrument_name" => "BTC-PERP", "amount" => "-0.3"}},
        %{"instrument_name" => "BTC-PERP", "amount" => 0.1},
        %{info: %{"instrument_name" => "ETH-PERP", "amount" => "5"}}
      ]

      assert Decimal.equal?(MM.signed_size(positions, "BTC-PERP"), Decimal.new("-0.2"))
      assert Decimal.equal?(MM.signed_size([], "BTC-PERP"), 0)
    end

    test "restore_order returns the exact difference, reduce-only only when it shrinks without crossing" do
      d = &Decimal.new/1
      assert MM.restore_order(d.("0"), d.("0")) == :none
      assert MM.restore_order(d.("0.5"), d.("0.5")) == :none

      assert {"sell", amount, true} = MM.restore_order(d.("0"), d.("0.1"))
      assert Decimal.equal?(amount, d.("0.1"))

      assert {"buy", amount, true} = MM.restore_order(d.("-0.2"), d.("-0.3"))
      assert Decimal.equal?(amount, d.("0.1"))

      # Restoring a pre-existing short after a buy that flipped the account long crosses zero.
      assert {"sell", amount, false} = MM.restore_order(d.("-0.1"), d.("0.1"))
      assert Decimal.equal?(amount, d.("0.2"))

      # Growing back to a larger start is not a reduction.
      assert {"buy", amount, false} = MM.restore_order(d.("0.3"), d.("0.1"))
      assert Decimal.equal?(amount, d.("0.2"))

      assert {"buy", _, false} = MM.restore_order(d.("0.1"), d.("0"))
    end
  end

  describe "run_with_cleanup/2" do
    test "returns the body's value and runs cleanup once" do
      assert MM.run_with_cleanup(fn -> :value end, fn -> send(self(), :cleaned) end) == :value
      assert_received :cleaned
      refute_received :cleaned
    end

    test "a body failure survives a successful cleanup unchanged" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          MM.run_with_cleanup(fn -> flunk("body broke") end, fn -> send(self(), :cleaned) end)
        end

      assert error.message == "body broke"

      assert_received :cleaned
      refute_received :cleaned
    end

    test "a cleanup failure after a passing body is raised" do
      assert_raise RuntimeError, "cleanup broke", fn ->
        MM.run_with_cleanup(fn -> :value end, fn -> raise "cleanup broke" end)
      end
    end

    test "when both fail, the body's failure is reported first, with the cleanup's" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          MM.run_with_cleanup(fn -> flunk("body broke") end, fn -> raise "cleanup broke" end)
        end

      assert [before, _] = String.split(error.message, "cleanup also failed:")
      assert before =~ "body broke"
      assert error.message =~ "cleanup broke"
    end

    test "exits and throws in the body are kept as well" do
      assert catch_exit(MM.run_with_cleanup(fn -> exit(:gone) end, fn -> :ok end)) == :gone
      assert catch_throw(MM.run_with_cleanup(fn -> throw(:thrown) end, fn -> :ok end)) == :thrown
    end
  end

  describe "cleanup_all/1" do
    test "a failed order release does not stop the original COD value being restored" do
      {:ok, cod} = Agent.start_link(fn -> true end)
      original = false

      error =
        assert_raise RuntimeError, "cancel timed out", fn ->
          MM.cleanup_all([
            fn -> raise "cancel timed out" end,
            fn -> Agent.update(cod, fn _ -> original end) end
          ])
        end

      assert error.message == "cancel timed out"
      assert Agent.get(cod, & &1) == original
    end

    test "every step runs once and every failure is reported in step order" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          MM.cleanup_all([
            fn -> flunk("first broke") end,
            fn -> send(self(), :second) end,
            fn -> raise "third broke" end
          ])
        end

      assert_received :second
      refute_received :second
      assert [first, third] = String.split(error.message, "another cleanup step also failed:")
      assert first =~ "first broke"
      assert third =~ "third broke"
    end

    test "returns :ok when every step succeeds" do
      assert MM.cleanup_all([fn -> :a end, fn -> nil end]) == :ok
    end
  end

  describe "MMP cleanup" do
    @original %{
      "currency" => "BTC",
      "is_frozen" => false,
      "mmp_interval" => 5_000,
      "mmp_frozen_time" => 60_000,
      "mmp_amount_limit" => "2",
      "mmp_delta_limit" => "0.5"
    }

    test "a freeze the test induced needs a reset; an unfrozen account does not" do
      target = MM.mmp_restore_target(@original)
      assert MM.mmp_needs_reset?(target, %{@original | "is_frozen" => true})
      refute MM.mmp_needs_reset?(target, @original)
      refute MM.mmp_needs_reset?(target, nil)
      assert MM.mmp_needs_reset?(MM.mmp_restore_target(nil), %{"is_frozen" => true})
    end

    test "a restored config that is still frozen is not restored" do
      target = MM.mmp_restore_target(@original)
      assert MM.mmp_mismatches(target, %{@original | "is_frozen" => true}) == ["is_frozen"]
      assert MM.mmp_mismatches(target, %{@original | "mmp_amount_limit" => "2.000"}) == []
      assert MM.mmp_mismatches(target, %{@original | "mmp_delta_limit" => "0"}) == ["mmp_delta_limit"]
      assert MM.mmp_mismatches(target, Map.delete(@original, "mmp_amount_limit")) == ["mmp_amount_limit"]
      assert MM.mmp_mismatches(target, nil) == ["config missing"]
    end

    test "no prior config restores as MMP off and unfrozen" do
      target = MM.mmp_restore_target(nil)
      assert %{"mmp_interval" => 0, "is_frozen" => false} = target
      off = %{"mmp_interval" => 0, "mmp_frozen_time" => 0, "mmp_amount_limit" => "0", "mmp_delta_limit" => "0"}
      assert MM.mmp_mismatches(target, Map.put(off, "is_frozen", false)) == []
      assert MM.mmp_mismatches(target, Map.put(off, "is_frozen", true)) == ["is_frozen"]
    end

    test "open MMP orders and quotes on the currency are exposure; others are not" do
      orders = [
        %{"order_id" => "o1", "mmp" => true, "order_status" => "open", "instrument_name" => "BTC-PERP"},
        %{"order_id" => "o2", "mmp" => false, "order_status" => "open", "instrument_name" => "BTC-PERP"},
        %{"order_id" => "o3", "mmp" => true, "order_status" => "open", "instrument_name" => "ETH-PERP"},
        %{"order_id" => "o4", "mmp" => true, "order_status" => "filled", "instrument_name" => "BTC-PERP"}
      ]

      quotes = [
        %{
          "quote_id" => "q1",
          "mmp" => true,
          "status" => "open",
          "legs" => [%{"instrument_name" => "BTC-20261231-100000-C"}]
        },
        %{"quote_id" => "q2", "mmp" => true, "status" => "open", "legs" => [%{"instrument_name" => "ETH-PERP"}]},
        %{"quote_id" => "q3", "mmp" => false, "status" => "open", "legs" => [%{"instrument_name" => "BTC-PERP"}]}
      ]

      assert MM.mmp_exposure(orders, quotes, "BTC") == ["o1", "q1"]
      assert MM.mmp_exposure([], [], "BTC") == []
    end
  end
end
