defmodule Bourse.Journeys.Trader.DeriveTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.Signing.Derive, as: DeriveSigning
  alias Bourse.Unified.RequestShape.Derive, as: DeriveRequestShape
  alias Bourse.WS

  @moduletag :exchange_derive

  @venue :derive
  @symbol "BTC/USD:USDC"
  @subaccount_id 144_422
  @amount 0.1
  @resting_price 100.0
  @max_fee "200"
  # Provider channel is `{subaccount_id}.orders` (docs.derive.xyz).
  @order_channel "#{@subaccount_id}.orders"
  @frame_timeout_ms 20_000

  describe "a trader's day" do
    test "survey the market, place a signed resting limit buy, track it, cancel it" do
      exchange = derive_exchange!()

      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      assert market, "#{@symbol} missing from loaded derive markets"
      assert market.active
      assert market.contract and market.linear and market.settle == "USDC"
      assert market.limits["amount"]["min"] <= @amount

      {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol)
      assert ticker.symbol == @symbol
      assert is_number(ticker.mark_price) and ticker.mark_price > 0

      {:ok, balance} = Bourse.fetch_balance(exchange)
      assert map_size(balance.total) > 0

      client_order_id = unique_client_order_id("trader-derive")

      request =
        DeriveRequestShape.build(
          %{
            "instrument_name" => @symbol,
            "type" => "limit",
            "side" => "buy",
            "amount" => @amount,
            "price" => @resting_price,
            "max_fee" => @max_fee,
            "subaccount_id" => @subaccount_id,
            "clientOrderId" => client_order_id
          },
          "createOrder",
          exchange
        )

      # RequestShape.build signs Derive's eight-field order tuple via sign_order
      # (max_fee, signer, nonce, signature_expiry_sec are part of that envelope).
      assert request["max_fee"] == @max_fee
      assert request["subaccount_id"] == @subaccount_id
      assert is_integer(request["nonce"])
      assert request["signature_expiry_sec"] > div(request["nonce"], 1_000)
      assert request["signer"] == DeriveSigning.signer_address(exchange.credentials.secret)
      assert is_binary(request["signature"]) and request["signature"] != ""

      assert {:ok, %{body: %{"result" => %{"order" => %{"order_id" => placed_id}}}}} =
               Bourse.Derive.private_post_order(exchange, request)

      assert is_binary(placed_id) and placed_id != ""

      try do
        order =
          poll_until!("order #{placed_id} visible as open", fn ->
            case Bourse.fetch_open_orders(exchange, symbol: @symbol) do
              {:ok, orders} ->
                case Enum.find(orders, &(&1.id == placed_id and &1.status == "open")) do
                  nil -> :retry
                  order -> {:ok, order}
                end

              {:error, error} ->
                flunk("fetch_open_orders failed: #{inspect(error)}")
            end
          end)

        assert %Order{side: "buy", type: "limit", info: %{"label" => ^client_order_id}} = order
        assert_in_delta order.price, @resting_price, 1.0e-9
        assert_in_delta order.amount, @amount, 1.0e-9

        {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
        assert Enum.any?(open_orders, &(&1.id == placed_id)), "resting order missing from open orders"

        {:ok, canceled} = Bourse.cancel_order(exchange, placed_id, symbol: @symbol)
        assert canceled.id == placed_id

        poll_until!("order #{placed_id} gone from open orders", fn ->
          {:ok, open} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
          if Enum.any?(open, &(&1.id == placed_id)), do: :retry, else: {:ok, :gone}
        end)
      after
        release_order!(exchange, placed_id, @symbol)
      end
    end
  end

  describe "a trader watching the private order stream" do
    test "the order's own lifecycle arrives on the stream, place and cancel" do
      exchange = derive_exchange!()
      {:ok, ws} = WS.connect(exchange, :private)

      try do
        # connect/3 does not handshake: auth_pattern is nil, so :no_auth_pattern
        # is swallowed and an unauthenticated socket is returned. :connected is
        # not evidence the stream will deliver order events.
        assert is_nil(ws.auth)

        # Observed live 2026-08-28 against wss://api-demo.lyra.finance/ws:
        # `{subaccount_id}.orders` before public/login is rejected with envelope
        # code 13000 wrapping 14022 "Subscription to a private channel failed".
        # Authority: https://docs.derive.xyz/reference/authentication
        assert {:error, {:subscription_rejected, unauthorized}} =
                 WS.subscribe(ws, [@order_channel], ack_timeout_ms: 8_000)

        assert get_in(unauthorized, ["error", "code"]) == 13_000
        assert get_in(unauthorized, ["error", "data"]) =~ "14022"

        # Venue-owned login (https://docs.derive.xyz/reference/public-login), not
        # a wired auth_pattern: EIP-191 of the millisecond timestamp with the
        # registered Admin session key, wallet = X-LyraWallet.
        timestamp = Integer.to_string(System.system_time(:millisecond))

        signature =
          DeriveSigning.sign_message(timestamp, private_key: exchange.credentials.secret)

        assert {:ok, %{"result" => subaccounts}} =
                 WS.send_message(ws, %{
                   "id" => 1,
                   "method" => "public/login",
                   "params" => %{
                     "wallet" => exchange.credentials.api_key,
                     "timestamp" => timestamp,
                     "signature" => signature
                   }
                 })

        assert @subaccount_id in subaccounts
        assert :ok = WS.subscribe(ws, [@order_channel], ack_timeout_ms: 8_000)

        client_order_id = unique_client_order_id("trader-derive-ws")

        request =
          DeriveRequestShape.build(
            %{
              "instrument_name" => @symbol,
              "type" => "limit",
              "side" => "buy",
              "amount" => @amount,
              "price" => @resting_price,
              "max_fee" => @max_fee,
              "subaccount_id" => @subaccount_id,
              "clientOrderId" => client_order_id
            },
            "createOrder",
            exchange
          )

        assert {:ok, %{body: %{"result" => %{"order" => %{"order_id" => placed_id}}}}} =
                 Bourse.Derive.private_post_order(exchange, request)

        assert is_binary(placed_id) and placed_id != ""

        try do
          # Observed live 2026-08-28: method "subscription", channel
          # "144422.orders", data[0] order_status "open", cancel_reason "".
          placed_event = await_order_event!(placed_id, "open")

          assert placed_event["instrument_name"] == "BTC-PERP"
          assert placed_event["direction"] == "buy"
          assert placed_event["order_type"] == "limit"
          assert placed_event["time_in_force"] == "gtc"
          assert placed_event["label"] == client_order_id
          assert placed_event["cancel_reason"] == ""
          assert placed_event["subaccount_id"] == @subaccount_id

          assert {event_price, ""} = Float.parse(placed_event["limit_price"])
          assert_in_delta event_price, @resting_price, 1.0e-9
          assert {event_qty, ""} = Float.parse(placed_event["amount"])
          assert_in_delta event_qty, @amount, 1.0e-9

          {:ok, canceled} = Bourse.cancel_order(exchange, placed_id, symbol: @symbol)
          assert canceled.id == placed_id

          # Observed live 2026-08-28: the same order_id returns order_status
          # "cancelled" and cancel_reason "user_request".
          cancel_event = await_order_event!(placed_id, "cancelled")

          assert cancel_event["label"] == client_order_id
          assert cancel_event["cancel_reason"] == "user_request"
          assert cancel_event["filled_amount"] == "0"
        after
          release_order!(exchange, placed_id, @symbol)
        end
      after
        WS.close(ws)
      end
    end
  end

  describe "orders the venue rejects" do
    test "a fee below the dynamic floor is refused with derive's own error" do
      exchange = derive_exchange!()

      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
                 price: @resting_price,
                 max_fee: "1"
               )

      # Observed live 2026-08-28: error 11023 returned
      # "signed max_fee must be >= 161.46771070217062". The floor is dynamic,
      # so pin the venue-owned code and its exact minimum-bearing message shape.
      assert error.type == :invalid_order
      assert error.code == 11_023
      assert [_, minimum] = Regex.run(~r/signed max_fee must be >= ([0-9.]+)/, error.message)
      assert {minimum_fee, ""} = Float.parse(minimum)
      assert minimum_fee > 1
    end
  end

  defp await_order_event!(order_id, status) do
    await_order_event!(order_id, status, System.monotonic_time(:millisecond) + @frame_timeout_ms)
  end

  defp await_order_event!(order_id, status, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
    else
      receive do
        {:websocket_message, frame} ->
          match_order_event(frame, order_id, status, deadline)

        {:websocket_unmatched_response, frame} ->
          match_order_event(frame, order_id, status, deadline)

        _other ->
          await_order_event!(order_id, status, deadline)
      after
        left -> flunk("no #{status} order frame for #{order_id} within #{@frame_timeout_ms}ms")
      end
    end
  end

  defp match_order_event(
         %{"method" => "subscription", "params" => %{"channel" => @order_channel, "data" => data}},
         order_id,
         status,
         deadline
       )
       when is_list(data) do
    case Enum.find(data, &(&1["order_id"] == order_id and &1["order_status"] == status)) do
      nil -> await_order_event!(order_id, status, deadline)
      event -> event
    end
  end

  defp match_order_event(_frame, order_id, status, deadline) do
    await_order_event!(order_id, status, deadline)
  end

  defp derive_exchange! do
    credentials = Bourse.Testnet.creds!(@venue)

    {:ok, exchange} =
      Bourse.Exchange.new(to_string(@venue),
        credentials: credentials,
        sandbox: true,
        options: %{"subaccount_id" => @subaccount_id}
      )

    {:ok, exchange} = Bourse.load_markets(exchange)
    exchange
  end
end
