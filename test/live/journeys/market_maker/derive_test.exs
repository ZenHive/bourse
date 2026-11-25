defmodule Bourse.Journeys.MarketMaker.DeriveTest do
  @moduledoc """
  A market maker's day on the Derive v3 testnet, against an order or fill each
  test creates and cleans up itself: the four unified order reads, both private
  feeds through a real fill, market-maker protection, cancel-on-disconnect, and
  a customer-signed `PreparedOrder` — accepted as signed, refused once a signed
  term is altered.

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

      filled_id = fill!(exchange, "buy", "mm-derive-closed")

      try do
        closed =
          poll_until!("order #{filled_id} in closed history", fn ->
            {:ok, orders} = Bourse.fetch_closed_orders(exchange, symbol: @symbol)
            find_order(orders, filled_id)
          end)

        assert closed.status == "closed"
        assert closed.filled > 0
      after
        flatten!(exchange)
      end
    end
  end

  describe "both private feeds through a fill" do
    test "the fill arrives on {subaccount_id}.orders and {subaccount_id}.trades" do
      exchange = derive_exchange!()
      {:ok, ws} = WS.connect(exchange, :private)

      try do
        assert {:ok, %WS.Handle{method: :watch_orders}} = WS.watch_orders(ws, ack_timeout_ms: 8_000)
        assert {:ok, %WS.Handle{method: :watch_my_trades}} = WS.watch_my_trades(ws, ack_timeout_ms: 8_000)

        filled_id = fill!(exchange, "buy", "mm-derive-feeds")

        try do
          order_event = await_event!(orders_channel(), &(&1["order_id"] == filled_id and &1["order_status"] == "filled"))
          assert order_event["instrument_name"] == @instrument
          assert order_event["direction"] == "buy"

          trade_event = await_event!(trades_channel(), &(&1["order_id"] == filled_id))
          assert trade_event["instrument_name"] == @instrument
          assert trade_event["subaccount_id"] == derive_subaccount_id!()
          assert {qty, ""} = Float.parse(trade_event["trade_amount"])
          assert qty > 0

          {:ok, trades} = Bourse.fetch_my_trades(exchange, @symbol)
          assert Enum.any?(trades, &(&1.order == filled_id)), "fill #{filled_id} missing from fetch_my_trades"
        after
          flatten!(exchange)
        end
      after
        WS.close(ws)
      end
    end
  end

  describe "market-maker protection" do
    test "set, read back and reset the BTC config, then disable it" do
      exchange = derive_exchange!()
      subaccount = derive_subaccount_id!()

      config = %{
        "subaccount_id" => subaccount,
        "currency" => @currency,
        "mmp_interval" => 5_000,
        "mmp_frozen_time" => 60_000,
        "mmp_amount_limit" => "1",
        "mmp_delta_limit" => "0"
      }

      try do
        assert {:ok, %{body: %{"result" => stored}}} = Bourse.Derive.private_post_set_mmp_config(exchange, config)
        assert stored["currency"] == @currency
        assert stored["mmp_interval"] == 5_000
        assert stored["mmp_frozen_time"] == 60_000
        assert decimal_equal?(stored["mmp_amount_limit"], "1")

        assert {:ok, %{body: %{"result" => configs}}} =
                 Bourse.Derive.private_post_get_mmp_config(exchange, %{
                   "subaccount_id" => subaccount,
                   "currency" => @currency
                 })

        assert %{"is_frozen" => false, "mmp_interval" => 5_000} = Enum.find(configs, &(&1["currency"] == @currency))

        assert {:ok, %{body: %{"result" => "ok"}}} =
                 Bourse.Derive.private_post_reset_mmp(exchange, %{"subaccount_id" => subaccount, "currency" => @currency})
      after
        # mmp_interval 0 disables MMP for the (subaccount, currency).
        {:ok, %{body: %{"result" => %{"mmp_interval" => 0}}}} =
          Bourse.Derive.private_post_set_mmp_config(exchange, %{config | "mmp_interval" => 0})
      end
    end
  end

  describe "cancel-on-disconnect" do
    test "an mmp order placed on the socket is canceled when that socket drops" do
      exchange = derive_exchange!()
      {:ok, ws} = WS.connect(exchange, :private)

      set_cod!(ws, exchange, true)
      request = resting_order(exchange, "mm-derive-cod", %{"mmp" => true})

      placed_id =
        try do
          assert {:ok, %{"result" => %{"order" => %{"order_id" => id, "mmp" => true}}}} =
                   WS.send_message(ws, rpc("private/order", request))

          id
        after
          WS.close(ws)
        end

      try do
        canceled =
          poll_until!("order #{placed_id} canceled by the disconnect", fn ->
            {:ok, orders} = Bourse.fetch_canceled_orders(exchange, symbol: @symbol)
            find_order(orders, placed_id)
          end)

        assert canceled.status == "canceled"
        refute canceled.info["cancel_reason"] in [nil, "", "user_request"]
      after
        release_order!(exchange, placed_id, @symbol)
        {:ok, cleanup_ws} = WS.connect(exchange, :private)

        try do
          set_cod!(cleanup_ws, exchange, false)
        after
          WS.close(cleanup_ws)
        end
      end
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

  defp flatten!(exchange) do
    {:ok, positions} = Bourse.fetch_positions(exchange, [@symbol])

    case Enum.find(positions, &(&1.symbol == @symbol and is_number(&1.contracts) and &1.contracts != 0)) do
      nil -> :ok
      %{side: "long"} -> fill!(exchange, "sell", "mm-derive-flatten", %{"reduce_only" => true})
      %{side: "short"} -> fill!(exchange, "buy", "mm-derive-flatten", %{"reduce_only" => true})
    end
  end

  defp find_order(orders, id) do
    case Enum.find(orders, &(&1.id == id)) do
      nil -> :retry
      order -> {:ok, order}
    end
  end

  defp await_event!(channel, match?) do
    await_event!(channel, match?, System.monotonic_time(:millisecond) + @frame_timeout_ms)
  end

  defp await_event!(channel, match?, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    receive do
      {tag, %{"params" => %{"channel" => ^channel, "data" => data}}}
      when tag in [:websocket_message, :websocket_unmatched_response] and is_list(data) ->
        Enum.find(data, match?) || await_event!(channel, match?, deadline)

      _other ->
        await_event!(channel, match?, deadline)
    after
      max(left, 0) -> flunk("no matching frame on #{channel} within #{@frame_timeout_ms}ms")
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
