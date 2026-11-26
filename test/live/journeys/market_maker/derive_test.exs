defmodule Bourse.Journeys.MarketMaker.DeriveTest do
  @moduledoc """
  A market maker's day on the Derive v3 testnet, against an order or fill each
  test creates and cleans up itself: the four unified order reads, both private
  feeds through a real fill, a market-maker-protection freeze and its reset,
  and cancel-on-disconnect. The customer-signed `PreparedOrder` case lives in
  `test/live/derive/prepared_order_live_test.exs`.

  Every mutation is undone and checked: a fill is traded back to the position
  recorded before it, and the MMP config and the cancel-on-disconnect account
  setting are restored to the values read before the test, a freeze the test
  induced is reset and the account proven unfrozen again. Every cleanup step
  runs even when an earlier one failed, and a failed restore is reported
  alongside, never instead of, the failure that preceded it. The freeze test
  refuses to run while the subaccount carries open BTC MMP orders or quotes,
  which a tripped threshold would cancel.

  The freeze is tripped by one taker IOC fill carrying `mmp: true`. The provider
  page counts fills from "orders and quotes submitted with the per-order `mmp`
  flag"; whether a taker fill trips the window has not been observed live. If it
  does not, the MMP evidence is set/read and the reset acknowledgement only.

  Every case needs the v3 testnet account (owner wallet funded, subaccount
  created by a deposit, session key registered); without it each one fails in
  setup with the operator step from `Bourse.Test.DeriveAccount`.

  Provider sources (retrieved 2026-11-25):
  https://docs.derive.xyz/openapi.json,
  https://docs.derive.xyz/subscriptions.asyncapi.json,
  https://docs.derive.xyz/trading/market-maker-protection.md,
  https://docs.derive.xyz/trading/cancel-on-disconnect.md,
  https://docs.derive.xyz/reference/error-codes.md.
  """
  use Bourse.Test.Journeys.Case, async: false

  import Bourse.IntegrationHelper, only: [derive_subaccount_id!: 0]

  alias Bourse.Order
  alias Bourse.Test.DeriveMarketMaker, as: MM
  alias Bourse.Unified.RequestShape.Derive, as: DeriveRequestShape
  alias Bourse.WS

  @moduletag :exchange_derive

  @symbol "BTC/USDC:USDC"
  @instrument "BTC-PERP"
  @currency "BTC"
  @resting_amount 0.1
  @resting_price 100.0
  @max_fee "200"
  @frame_timeout_ms 20_000
  # get_order_history is written behind the matching engine: a canceled order
  # took longer than five seconds to appear there (observed 2026-11-26).
  @history_lag_ms 30_000

  describe "the four unified order reads" do
    @tag timeout: 180_000
    test "an order created here appears open, then canceled; a filled one appears closed" do
      exchange = derive_exchange!()
      placed_id = place!(exchange, resting_order(exchange, "mm-derive-reads"))

      try do
        open =
          poll_until!("order #{placed_id} open", fn ->
            {:ok, orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
            find_order(orders, placed_id)
          end)

        assert %Order{status: "open", side: "buy", type: "limit"} = open

        {:ok, %Order{id: ^placed_id}} = Bourse.cancel_order(exchange, placed_id, symbol: @symbol)

        canceled =
          poll_until!(
            "order #{placed_id} in canceled history",
            fn ->
              {:ok, orders} = Bourse.fetch_canceled_orders(exchange, symbol: @symbol)
              find_order(orders, placed_id)
            end,
            @history_lag_ms
          )

        assert canceled.status == "canceled"
        assert_in_delta canceled.price, @resting_price, 1.0e-9

        # The canceled-history read and the all-orders read lag independently.
        assert %Order{status: "canceled"} =
                 poll_until!(
                   "order #{placed_id} in all orders",
                   fn ->
                     {:ok, all} = Bourse.fetch_orders(exchange, symbol: @symbol)
                     find_order(all, placed_id)
                   end,
                   @history_lag_ms
                 )

        {:ok, closed_before} = Bourse.fetch_closed_orders(exchange, symbol: @symbol)
        refute Enum.any?(closed_before, &(&1.id == placed_id)), "a canceled order is not a closed one"
      after
        release_order!(exchange, placed_id, @symbol)
      end

      with_position_restored(exchange, fn ->
        filled_id = fill!(exchange, "buy", "mm-derive-closed")

        closed =
          poll_until!(
            "order #{filled_id} in closed history",
            fn ->
              {:ok, orders} = Bourse.fetch_closed_orders(exchange, symbol: @symbol)
              find_order(orders, filled_id)
            end,
            @history_lag_ms
          )

        assert closed.status == "closed"
        assert is_number(closed.filled) and closed.filled > 0
      end)
    end
  end

  describe "both private feeds through a fill" do
    test "the fill arrives on {subaccount_id}.orders and {subaccount_id}.trades" do
      exchange = derive_exchange!()
      {:ok, ws} = WS.connect(exchange, :private)

      try do
        assert {:ok, %WS.Handle{method: :watch_orders}} = WS.watch_orders(ws, ack_timeout_ms: 8_000)
        assert {:ok, %WS.Handle{method: :watch_my_trades}} = WS.watch_my_trades(ws, ack_timeout_ms: 8_000)

        with_position_restored(exchange, fn ->
          filled_id = fill!(exchange, "buy", "mm-derive-feeds")

          # The two channels carry no cross-channel ordering guarantee: collect
          # both events from whichever frame arrives first, under one deadline.
          %{order: order_event, trade: trade_event} =
            MM.await_all!(
              [
                {:order, orders_channel(), &(&1["order_id"] == filled_id and &1["order_status"] == "filled")},
                {:trade, trades_channel(), &(&1["order_id"] == filled_id)}
              ],
              @frame_timeout_ms
            )

          assert order_event["instrument_name"] == @instrument
          assert order_event["direction"] == "buy"

          assert trade_event["instrument_name"] == @instrument
          assert trade_event["subaccount_id"] == derive_subaccount_id!()
          assert {qty, ""} = Float.parse(trade_event["trade_amount"])
          assert qty > 0

          poll_until!(
            "fill #{filled_id} in fetch_my_trades",
            fn ->
              {:ok, trades} = Bourse.fetch_my_trades(exchange, symbol: @symbol)
              if Enum.any?(trades, &(&1.order_id == filled_id)), do: {:ok, filled_id}, else: :retry
            end,
            @history_lag_ms
          )
        end)
      after
        WS.close(ws)
      end
    end
  end

  describe "market-maker protection" do
    @tag timeout: 180_000
    test "an mmp maker fill over the amount limit freezes BTC; reset_mmp clears the freeze" do
      exchange = derive_exchange!()
      subaccount = derive_subaccount_id!()
      original = mmp_config!(exchange)
      refute original["is_frozen"] == true, "BTC MMP is already frozen before the test: #{inspect(original)}"
      refuse_mmp_exposure!(exchange)

      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      min_amount = market.limits["amount"]["min"]

      # Fixed freeze (mmp_frozen_time 0 = frozen until reset), tripped by one
      # mmp fill of the minimum size against a limit half that size.
      config = %{
        "subaccount_id" => subaccount,
        "currency" => @currency,
        "mmp_interval" => 60_000,
        "mmp_frozen_time" => 0,
        "mmp_amount_limit" => to_string(min_amount / 2),
        "mmp_delta_limit" => "0"
      }

      MM.run_with_cleanup(
        fn ->
          assert {:ok, %{body: %{"result" => stored}}} = Bourse.Derive.private_post_set_mmp_config(exchange, config)
          assert stored["mmp_interval"] == 60_000
          assert stored["mmp_frozen_time"] == 0
          assert decimal_equal?(stored["mmp_amount_limit"], config["mmp_amount_limit"])

          # Only a MAKER fill of an mmp order counts: an mmp IOC taker fill over the
          # limit left the subaccount unfrozen, while the same size resting and hit
          # by a second subaccount froze it at once (observed 2026-11-26, v3 testnet).
          # The cross runs on a wide-spread BTC option, not the perp: the perp's
          # quoting bot re-prices inside a four-tick spread faster than the ticker
          # reports it, so a resting bid there was outbid or crossed. A BTC option
          # fill counts toward the BTC MMP (observed the same day).
          counter = counterparty_exchange!()
          {option, price} = wide_spread_option!(exchange)
          amount = option.limits["amount"]["min"]
          crossed = make_ref()

          MM.run_with_cleanup(
            fn ->
              cross!(exchange, counter, option, price, amount, true)
              Process.put(crossed, true)

              frozen =
                poll_until!(
                  "BTC MMP frozen after the mmp maker fill",
                  fn ->
                    case mmp_config!(exchange) do
                      %{"is_frozen" => true} = frozen -> {:ok, frozen}
                      _ -> :retry
                    end
                  end,
                  @history_lag_ms
                )

              assert frozen["mmp_interval"] == 60_000

              assert {:ok, %{body: %{"result" => "ok"}}} =
                       Bourse.Derive.private_post_reset_mmp(exchange, %{
                         "subaccount_id" => subaccount,
                         "currency" => @currency
                       })

              assert %{"is_frozen" => false} =
                       poll_until!("BTC MMP cleared by reset_mmp", fn ->
                         case mmp_config!(exchange) do
                           %{"is_frozen" => false} = cleared -> {:ok, cleared}
                           _ -> :retry
                         end
                       end)
            end,
            # Undo the option position on both sides with the opposite cross.
            fn -> if Process.get(crossed), do: cross!(counter, exchange, option, price, amount, false) end
          )
        end,
        fn -> restore_mmp_config!(exchange, original) end
      )
    end
  end

  describe "cancel-on-disconnect" do
    test "an open mmp order placed on the socket is canceled for cancel_on_disconnect when that socket drops" do
      exchange = derive_exchange!()
      original = cod_setting!(exchange)
      placed = make_ref()

      MM.run_with_cleanup(
        fn ->
          {:ok, ws} = WS.connect(exchange, :private)

          placed_id =
            MM.run_with_cleanup(
              fn ->
                set_cod!(ws, exchange, true)
                assert cod_setting!(exchange) == true

                request = resting_order(exchange, "mm-derive-cod", %{"mmp" => true})

                assert {:ok, %{"result" => %{"order" => %{"order_id" => id, "mmp" => true}}}} =
                         WS.send_message(ws, rpc("private/order", request))

                Process.put(placed, id)

                assert %Order{status: "open"} =
                         poll_until!("order #{id} open before the disconnect", fn ->
                           {:ok, orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
                           find_order(orders, id)
                         end)

                id
              end,
              fn -> WS.close(ws) end
            )

          # Observed live 2026-11-26 (v3 testnet, three runs): the disconnect removes
          # the order from the book, and the order is then gone. get_order answers
          # 11006 "Does not exist" and get_order_history carries no row, although
          # the provider's history page says every cancelled order is recorded with a
          # `cancel_on_disconnect` reason. Recorded in BUGS.md as a provider divergence.
          poll_until!("order #{placed_id} off the book after the disconnect", fn ->
            {:ok, orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
            if find_order(orders, placed_id) == :retry, do: {:ok, :gone}, else: :retry
          end)

          assert {:error, %Bourse.Error{code: 11_006}} =
                   Bourse.Derive.private_post_get_order(exchange, %{
                     "subaccount_id" => derive_subaccount_id!(),
                     "order_id" => placed_id
                   })

          Process.delete(placed)
        end,
        fn ->
          MM.cleanup_all([
            fn -> if id = Process.get(placed), do: release_order!(exchange, id, @symbol) end,
            fn -> restore_cod!(exchange, original) end
          ])
        end
      )
    end
  end

  defp place!(exchange, request) do
    assert {:ok, %{body: %{"result" => %{"order" => %{"order_id" => id}}}}} =
             Bourse.Derive.private_post_order(exchange, request)

    id
  end

  defp set_cod!(ws, exchange, enabled) do
    assert {:ok, %{"result" => "ok"}} =
             WS.send_message(
               ws,
               rpc("private/set_cancel_on_disconnect", %{"wallet" => exchange.credentials.api_key, "enabled" => enabled})
             )
  end

  defp rpc(method, params), do: %{"id" => System.unique_integer([:positive]), "method" => method, "params" => params}

  defp resting_order(exchange, prefix, extra \\ %{}) do
    %{
      "instrument_name" => @symbol,
      "type" => "limit",
      "side" => "buy",
      "amount" => @resting_amount,
      "price" => @resting_price,
      "max_fee" => @max_fee,
      "subaccount_id" => exchange.options["subaccount_id"],
      "clientOrderId" => unique_client_order_id(prefix)
    }
    |> Map.merge(extra)
    |> DeriveRequestShape.build("createOrder", exchange)
  end

  # Crosses the book with an IOC limit halfway from the touch to the band edge; fails
  # loudly when the testnet book has nothing to fill against.
  defp fill!(exchange, side, prefix, extra \\ %{}) do
    market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
    {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol)
    touch = if side == "buy", do: ticker.ask, else: ticker.bid
    assert is_number(touch) and touch > 0, "no #{side} touch on #{@instrument}: #{inspect(ticker)}"

    # The venue rejects a limit outside its published band (11013), ticker `maxp` / `minp`,
    # and the band follows the mark between the ticker read and the order: aim halfway.
    tick = market.precision["price"]

    price =
      if side == "buy" do
        on_tick(Float.floor((touch + elem(Float.parse(ticker.info["maxp"]), 0)) / 2 / tick), tick)
      else
        on_tick(Float.ceil((touch + elem(Float.parse(ticker.info["minp"]), 0)) / 2 / tick), tick)
      end

    request =
      %{
        "instrument_name" => @symbol,
        "type" => "limit",
        "side" => side,
        "amount" => market.limits["amount"]["min"],
        "price" => price,
        "max_fee" => @max_fee,
        "time_in_force" => "ioc",
        "subaccount_id" => exchange.options["subaccount_id"],
        "clientOrderId" => unique_client_order_id(prefix)
      }
      |> Map.merge(extra)
      |> DeriveRequestShape.build("createOrder", exchange)

    assert {:ok, %{body: %{"result" => %{"order" => %{"order_id" => id, "order_status" => "filled"}}}}} =
             Bourse.Derive.private_post_order(exchange, request)

    id
  end

  # Records the instrument's signed position, runs `fun`, then trades the
  # exact difference back and proves the account holds the recorded size again.
  defp with_position_restored(exchange, fun) do
    start = position_size!(exchange)

    MM.run_with_cleanup(fun, fn -> restore_position!(exchange, start) end)
  end

  defp restore_position!(exchange, start) do
    case MM.restore_order(start, position_size!(exchange)) do
      :none ->
        :ok

      {side, amount, reduce_only} ->
        fill!(exchange, side, "mm-derive-restore", %{"amount" => Decimal.to_float(amount), "reduce_only" => reduce_only})
        poll_until!("#{@instrument} position back at #{start}", fn -> position_at(exchange, start) end)
    end
  end

  defp position_at(exchange, start) do
    if Decimal.equal?(position_size!(exchange), start), do: {:ok, start}, else: :retry
  end

  defp position_size!(exchange) do
    assert {:ok, positions} = Bourse.fetch_positions(exchange)
    MM.signed_size(positions, @instrument)
  end

  defp mmp_config!(exchange), do: MM.mmp_config_row!(mmp_configs!(exchange), @currency)

  defp mmp_configs!(exchange) do
    assert {:ok, %{body: %{"result" => configs}}} =
             Bourse.Derive.private_post_get_mmp_config(exchange, %{
               "subaccount_id" => derive_subaccount_id!(),
               "currency" => @currency
             })

    assert is_list(configs)
    configs
  end

  # Undoes a freeze the test induced (mmp_frozen_time 0 stays frozen until a
  # manual reset), rewrites the original config, then proves both the config
  # and the freeze state match what was read before the test. Each step runs
  # even when an earlier one failed.
  defp restore_mmp_config!(exchange, original) do
    target = MM.mmp_restore_target(original)
    account = %{"subaccount_id" => derive_subaccount_id!(), "currency" => @currency}

    MM.restore_mmp!(target, @currency, %{
      read: fn -> mmp_configs!(exchange) end,
      reset: fn ->
        assert {:ok, %{body: %{"result" => "ok"}}} = Bourse.Derive.private_post_reset_mmp(exchange, account)
      end,
      write: fn ->
        assert {:ok, %{body: %{"result" => _}}} =
                 Bourse.Derive.private_post_set_mmp_config(exchange, Map.merge(Map.delete(target, "is_frozen"), account))
      end,
      poll: &poll_until!("BTC MMP back at #{inspect(target)}", &1)
    })
  end

  # A deliberate freeze cancels every open MMP order and quote on the currency,
  # so the test refuses to run on an account that carries any.
  defp refuse_mmp_exposure!(exchange) do
    account = %{"subaccount_id" => derive_subaccount_id!()}

    assert {:ok, %{body: %{"result" => %{"orders" => orders}}}} =
             Bourse.Derive.private_post_get_open_orders(exchange, account)

    assert is_list(orders)

    # get_quotes is paginated (Pagination.num_pages, default page size 20);
    # get_open_orders returns every open order in one result.
    quotes =
      MM.read_all_pages!("quotes", "quote_id", fn page ->
        case Bourse.Derive.private_post_get_quotes(exchange, Map.merge(account, %{"status" => "open", "page" => page})) do
          {:ok, %{body: %{"result" => result}}} -> {:ok, result}
          other -> other
        end
      end)

    case MM.mmp_exposure(orders, quotes, @currency) do
      [] ->
        :ok

      ids ->
        flunk("""
        subaccount #{derive_subaccount_id!()} carries open #{@currency} MMP orders or quotes #{inspect(ids)}.
        Tripping the freeze would cancel them; cancel them or run on a subaccount without MMP exposure.
        """)
    end
  end

  # The persisted account setting, from private/get_account
  # (PrivateGetAccountResponse.cancel_on_disconnect).
  defp cod_setting!(exchange) do
    assert {:ok, %{body: %{"result" => %{"cancel_on_disconnect" => enabled}}}} =
             Bourse.Derive.private_post_get_account(exchange, %{"wallet" => exchange.credentials.api_key})

    assert is_boolean(enabled)
    enabled
  end

  defp restore_cod!(exchange, original) do
    if cod_setting!(exchange) != original do
      {:ok, ws} = WS.connect(exchange, :private)
      MM.run_with_cleanup(fn -> set_cod!(ws, exchange, original) end, fn -> WS.close(ws) end)
      assert cod_setting!(exchange) == original
    end
  end

  # Ticks times a float tick drift off the grid (619106 * 0.1); multiply in decimal.
  defp on_tick(ticks, tick), do: ticks |> trunc() |> Decimal.mult(Decimal.from_float(tick)) |> Decimal.to_float()

  # A second subaccount of the owner wallet in the perp's risk universe, to take
  # the other side of a resting order. Created by private/transfer_spot with
  # `new_subaccount_manager` 1 (standard margin).
  defp counterparty_exchange! do
    primary = derive_subaccount_id!()
    {:ok, public} = Bourse.Exchange.new("derive", sandbox: true)
    wallet = Bourse.Testnet.creds!(:derive).api_key

    assert {:ok, %{body: %{"result" => %{"subaccount_ids" => ids}}}} =
             Bourse.Derive.public_post_get_subaccounts(public, %{"wallet" => wallet})

    universe = Enum.find(derive_exchange!().markets, &(&1.symbol == @symbol)).info["risk_universe_id"]

    candidate =
      Enum.find(ids -- [primary], fn id ->
        {:ok, %{body: %{"result" => %{"risk_universe_id" => u}}}} =
          Bourse.Derive.private_post_get_subaccount(subaccount_exchange!(id), %{"subaccount_id" => id})

        u == universe
      end)

    candidate ||
      flunk("""
      The MMP journey needs a second subaccount of #{wallet} in risk universe #{universe}
      to hit a resting mmp order; #{inspect(ids)} has none besides #{primary}. Create one with
      private/transfer_spot from #{primary}: new_subaccount_manager 1, asset USDC, amount 1000.
      """)

    subaccount_exchange!(candidate)
  end

  # An active BTC option in the perp's risk universe, expiring in more than three
  # days, whose book is two-sided and at least ten ticks wide: a bid at the mid
  # then rests alone between the quotes and is the only bid an IOC sell at that
  # price can reach.
  defp wide_spread_option!(exchange) do
    perp = Enum.find(exchange.markets, &(&1.symbol == @symbol))
    horizon = System.system_time(:millisecond) + to_timeout(day: 3)

    universe = perp.info["risk_universe_id"]

    candidates =
      exchange.markets
      |> Enum.filter(&listed_option?(&1, horizon, universe))
      |> Enum.sort_by(&{&1.expiry, &1.strike})
      |> Enum.take(40)

    Enum.find_value(candidates, &wide_mid(exchange, &1)) ||
      flunk("no two-sided BTC option at least ten ticks wide among #{Enum.map_join(candidates, ", ", & &1.id)}")
  end

  defp listed_option?(market, horizon, universe) do
    market.option and market.active and market.base == @currency and market.expiry > horizon and
      market.info["risk_universe_id"] == universe
  end

  defp wide_mid(exchange, option) do
    tick = option.precision["price"]

    with {:ok, %{body: %{"result" => %{"a" => ask, "b" => bid}}}} when is_binary(ask) and is_binary(bid) <-
           Bourse.Derive.public_post_get_ticker(exchange, %{"instrument_name" => option.id}),
         {ask, ""} <- Float.parse(ask),
         {bid, ""} <- Float.parse(bid),
         true <- ask - bid >= 10 * tick do
      {option, on_tick(Float.floor((ask + bid) / 2 / tick), tick)}
    else
      _ -> nil
    end
  end

  # `bidder` rests a post_only bid at `price`; `seller` sells into it with an IOC
  # at the same price, so the bidder is the maker. The bid reaches the book a
  # moment after its placement is acknowledged; until then the IOC answers
  # 11009 "Zero liquidity". Each IOC is a fresh signed order (a nonce is single-use).
  defp cross!(bidder, seller, option, price, amount, mmp) do
    bid_id =
      place!(
        bidder,
        resting_order(bidder, "mm-derive-mmp", %{
          "instrument_name" => option.symbol,
          "price" => price,
          "amount" => amount,
          "mmp" => mmp,
          "time_in_force" => "post_only"
        })
      )

    try do
      poll_until!("IOC sell at #{price} on #{option.id} filled", fn ->
        ioc_sell(seller, option, amount, price, bid_id)
      end)
    after
      release_order!(bidder, bid_id, option.symbol)
    end
  end

  defp ioc_sell(seller, option, amount, price, bid_id) do
    request =
      DeriveRequestShape.build(
        %{
          "instrument_name" => option.symbol,
          "type" => "limit",
          "side" => "sell",
          "amount" => amount,
          "price" => price,
          "max_fee" => @max_fee,
          "time_in_force" => "ioc",
          "subaccount_id" => seller.options["subaccount_id"],
          "clientOrderId" => unique_client_order_id("mm-derive-mmp-hit")
        },
        "createOrder",
        seller
      )

    case Bourse.Derive.private_post_order(seller, request) do
      {:ok, %{body: %{"result" => %{"order" => %{"order_status" => "filled"}}}}} -> {:ok, :filled}
      {:error, %Bourse.Error{code: 11_009}} -> :retry
      other -> flunk("IOC sell into the resting bid #{bid_id} failed: #{inspect(other)}")
    end
  end

  defp find_order(orders, id) do
    case Enum.find(orders, &(&1.id == id)) do
      nil -> :retry
      order -> {:ok, order}
    end
  end

  defp decimal_equal?(left, right), do: Decimal.equal?(Decimal.new(to_string(left)), Decimal.new(to_string(right)))

  defp orders_channel, do: "#{derive_subaccount_id!()}.orders"
  defp trades_channel, do: "#{derive_subaccount_id!()}.trades"

  defp derive_exchange!, do: subaccount_exchange!(derive_subaccount_id!())

  defp subaccount_exchange!(subaccount) do
    {:ok, exchange} =
      Bourse.Exchange.new("derive",
        credentials: %{Bourse.Testnet.creds!(:derive) | uid: Integer.to_string(subaccount)},
        sandbox: true,
        options: %{"subaccount_id" => subaccount}
      )

    {:ok, exchange} = Bourse.load_markets(exchange)
    exchange
  end
end
