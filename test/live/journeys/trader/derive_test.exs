defmodule Bourse.Journeys.Trader.DeriveTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.Signing.Derive, as: DeriveSigning
  alias Bourse.Unified.RequestShape.Derive, as: DeriveRequestShape

  @moduletag :exchange_derive

  @venue :derive
  @symbol "BTC/USD:USDC"
  @subaccount_id 144_422
  @amount 0.1
  @resting_price 100.0
  @max_fee "200"

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
