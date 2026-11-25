defmodule Bourse.Journeys.MarketMaker.DeriveTest do
  @moduledoc """
  A market maker's day on the Derive v3 testnet, against an order or fill each
  test creates and cleans up itself: the four unified order reads, both private
  feeds through a real fill, a market-maker-protection freeze and its reset,
  cancel-on-disconnect, and a customer-signed `PreparedOrder` — accepted as
  signed, refused once a signed term is altered.

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
  https://docs.derive.xyz/authentication/action-signing.md,
  https://docs.derive.xyz/reference/error-codes.md.
  """
  use Bourse.Test.Journeys.Case, async: false

  import Bourse.IntegrationHelper, only: [derive_subaccount_id!: 0]

  alias Bourse.Order
  alias Bourse.Signing.Crypto
  alias Bourse.Signing.Derive, as: DeriveSigning
  alias Bourse.Signing.Derive.PreparedOrder
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

  describe "the four unified order reads" do
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
          poll_until!("order #{placed_id} in canceled history", fn ->
            {:ok, orders} = Bourse.fetch_canceled_orders(exchange, symbol: @symbol)
            find_order(orders, placed_id)
          end)

        assert canceled.status == "canceled"
        assert_in_delta canceled.price, @resting_price, 1.0e-9

        {:ok, all} = Bourse.fetch_orders(exchange, symbol: @symbol)
        assert %Order{status: "canceled"} = Enum.find(all, &(&1.id == placed_id))
        {:ok, closed_before} = Bourse.fetch_closed_orders(exchange, symbol: @symbol)
        refute Enum.any?(closed_before, &(&1.id == placed_id)), "a canceled order is not a closed one"
      after
        release_order!(exchange, placed_id, @symbol)
      end

      with_position_restored(exchange, fn ->
        filled_id = fill!(exchange, "buy", "mm-derive-closed")

        closed =
          poll_until!("order #{filled_id} in closed history", fn ->
            {:ok, orders} = Bourse.fetch_closed_orders(exchange, symbol: @symbol)
            find_order(orders, filled_id)
          end)

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

          {:ok, trades} = Bourse.fetch_my_trades(exchange, symbol: @symbol)
          assert Enum.any?(trades, &(&1.order == filled_id)), "fill #{filled_id} missing from fetch_my_trades"
        end)
      after
        WS.close(ws)
      end
    end
  end

  describe "market-maker protection" do
    test "an mmp fill over the amount limit freezes BTC; reset_mmp clears the freeze" do
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

          with_position_restored(exchange, fn ->
            fill!(exchange, "buy", "mm-derive-mmp", %{"mmp" => true})

            frozen =
              poll_until!("BTC MMP frozen after the mmp fill", fn ->
                case mmp_config!(exchange) do
                  %{"is_frozen" => true} = frozen -> {:ok, frozen}
                  _ -> :retry
                end
              end)

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
          end)
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

          canceled =
            poll_until!("order #{placed_id} canceled by the disconnect", fn ->
              {:ok, orders} = Bourse.fetch_canceled_orders(exchange, symbol: @symbol)
              find_order(orders, placed_id)
            end)

          assert canceled.status == "canceled"
          assert canceled.info["cancel_reason"] == "cancel_on_disconnect"
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

  describe "a customer-signed PreparedOrder" do
    test "the signed terms are accepted; the same signature over an altered price is refused" do
      exchange = derive_exchange!()
      prepared = prepare!(exchange)
      signature = sign_digest(prepared.digest, exchange.credentials.secret)

      # Provider error table: 14014 invalid_signature, "Recovered signer does not
      # match the expected signer". Not yet observed live on v3.
      altered = Map.put(%{prepared.body | "limit_price" => "101"}, "signature", signature)
      assert {:error, error} = Bourse.Derive.private_post_order(exchange, altered)
      assert error.code == 14_014

      body = Map.put(prepared.body, "signature", signature)

      assert {:ok, %{body: %{"result" => %{"order" => %{"order_id" => placed_id} = order}}}} =
               Bourse.Derive.private_post_order(exchange, body)

      try do
        assert decimal_equal?(order["limit_price"], prepared.body["limit_price"])
        assert to_string(order["nonce"]) == prepared.body["nonce"]
      after
        release_order!(exchange, placed_id, @symbol)
      end
    end
  end

  defp place!(exchange, request) do
    assert {:ok, %{body: %{"result" => %{"order" => %{"order_id" => id}}}}} =
             Bourse.Derive.private_post_order(exchange, request)

    id
  end

  defp prepare!(exchange) do
    {:ok, %{body: %{"result" => instrument}}} =
      Bourse.Derive.public_post_get_instrument(exchange, %{"instrument_name" => @instrument})

    now_ms = System.system_time(:millisecond)

    {:ok, prepared} =
      PreparedOrder.prepare(
        %{
          "subaccount_id" => derive_subaccount_id!(),
          "nonce" => now_ms * 1_000_000 + :rand.uniform(899_999) + 100_000,
          "signature_expiry_sec" => div(now_ms, 1_000) + 3_600,
          "owner" => exchange.credentials.api_key,
          "signer" => DeriveSigning.signer_address(exchange.credentials.secret),
          "base_asset_address" => instrument["base_asset_address"],
          "base_asset_sub_id" => instrument["base_asset_sub_id"],
          "instrument_name" => @instrument,
          "direction" => "buy",
          "amount" => "0.1",
          "limit_price" => "100",
          "max_fee" => @max_fee
        },
        :testnet
      )

    prepared
  end

  defp sign_digest("0x" <> hex, secret) do
    hex
    |> Base.decode16!(case: :mixed)
    |> Crypto.sign_hash(Crypto.decode_private_key(secret))
    |> Crypto.packed_signature()
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
      "subaccount_id" => derive_subaccount_id!(),
      "clientOrderId" => unique_client_order_id(prefix)
    }
    |> Map.merge(extra)
    |> DeriveRequestShape.build("createOrder", exchange)
  end

  # Crosses the book with an IOC limit two percent through the touch; fails
  # loudly when the testnet book has nothing to fill against.
  defp fill!(exchange, side, prefix, extra \\ %{}) do
    market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
    {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol)
    touch = if side == "buy", do: ticker.ask, else: ticker.bid
    assert is_number(touch) and touch > 0, "no #{side} touch on #{@instrument}: #{inspect(ticker)}"

    tick = market.precision["price"]
    price = Float.round(touch * if(side == "buy", do: 1.02, else: 0.98) / tick) * tick

    request =
      %{
        "instrument_name" => @symbol,
        "type" => "limit",
        "side" => side,
        "amount" => market.limits["amount"]["min"],
        "price" => price,
        "max_fee" => @max_fee,
        "time_in_force" => "ioc",
        "subaccount_id" => derive_subaccount_id!(),
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

    MM.run_with_cleanup(fun, fn ->
      case MM.restore_order(start, position_size!(exchange)) do
        :none ->
          :ok

        {side, amount, reduce_only} ->
          fill!(exchange, side, "mm-derive-restore", %{"amount" => Decimal.to_float(amount), "reduce_only" => reduce_only})

          poll_until!("#{@instrument} position back at #{start}", fn ->
            if Decimal.equal?(position_size!(exchange), start), do: {:ok, start}, else: :retry
          end)
      end
    end)
  end

  defp position_size!(exchange) do
    assert {:ok, positions} = Bourse.fetch_positions(exchange)
    MM.signed_size(positions, @instrument)
  end

  defp mmp_config!(exchange) do
    assert {:ok, %{body: %{"result" => configs}}} =
             Bourse.Derive.private_post_get_mmp_config(exchange, %{
               "subaccount_id" => derive_subaccount_id!(),
               "currency" => @currency
             })

    assert is_list(configs)
    Enum.find(configs, &(&1["currency"] == @currency))
  end

  # Undoes a freeze the test induced (mmp_frozen_time 0 stays frozen until a
  # manual reset), rewrites the original config, then proves both the config
  # and the freeze state match what was read before the test. Each step runs
  # even when an earlier one failed.
  defp restore_mmp_config!(exchange, original) do
    target = MM.mmp_restore_target(original)
    account = %{"subaccount_id" => derive_subaccount_id!(), "currency" => @currency}

    MM.cleanup_all([
      fn ->
        if MM.mmp_needs_reset?(target, mmp_config!(exchange)) do
          assert {:ok, %{body: %{"result" => "ok"}}} = Bourse.Derive.private_post_reset_mmp(exchange, account)
        end
      end,
      fn ->
        assert {:ok, %{body: %{"result" => _}}} =
                 Bourse.Derive.private_post_set_mmp_config(exchange, Map.merge(Map.delete(target, "is_frozen"), account))
      end,
      fn ->
        poll_until!("BTC MMP back at #{inspect(target)}", fn ->
          current = mmp_config!(exchange)
          if MM.mmp_mismatches(target, current) == [], do: {:ok, current}, else: :retry
        end)
      end
    ])
  end

  # A deliberate freeze cancels every open MMP order and quote on the currency,
  # so the test refuses to run on an account that carries any.
  defp refuse_mmp_exposure!(exchange) do
    account = %{"subaccount_id" => derive_subaccount_id!()}

    assert {:ok, %{body: %{"result" => %{"orders" => orders}}}} =
             Bourse.Derive.private_post_get_open_orders(exchange, account)

    assert {:ok, %{body: %{"result" => %{"quotes" => quotes}}}} =
             Bourse.Derive.private_post_get_quotes(exchange, Map.put(account, "status", "open"))

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

  defp find_order(orders, id) do
    case Enum.find(orders, &(&1.id == id)) do
      nil -> :retry
      order -> {:ok, order}
    end
  end

  defp decimal_equal?(left, right), do: Decimal.equal?(Decimal.new(to_string(left)), Decimal.new(to_string(right)))

  defp orders_channel, do: "#{derive_subaccount_id!()}.orders"
  defp trades_channel, do: "#{derive_subaccount_id!()}.trades"

  defp derive_exchange! do
    subaccount = derive_subaccount_id!()

    {:ok, exchange} =
      Bourse.Exchange.new("derive",
        credentials: Bourse.Testnet.creds!(:derive),
        sandbox: true,
        options: %{"subaccount_id" => subaccount}
      )

    {:ok, exchange} = Bourse.load_markets(exchange)
    exchange
  end
end
