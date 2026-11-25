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
      send(self(), {:websocket_unmatched_response, elem(order_frame("o1"), 1)})

      send(
        self(),
        "o1" |> trade_frame() |> put_in([Access.elem(1), "params", "data"], [%{"order_id" => "o1", "trade_id" => "late"}])
      )

      assert %{order: %{"order_id" => "o1"}, trade: %{"trade_id" => "t-o1"}} = MM.await_all!(wanted("o1"), 200)
    end

    test "flunks naming the event still missing" do
      send(self(), trade_frame("o1"))
      error = assert_raise ExUnit.AssertionError, fn -> MM.await_all!(wanted("o1"), 50) end
      assert error.message =~ ~s(order: "42.orders")
      refute error.message =~ "42.trades"
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
    end

    test "a body failure survives a successful cleanup unchanged" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          MM.run_with_cleanup(fn -> flunk("body broke") end, fn -> send(self(), :cleaned) end)
        end

      assert error.message == "body broke"

      assert_received :cleaned
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
end
