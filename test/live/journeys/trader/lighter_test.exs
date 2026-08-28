defmodule Bourse.Journeys.Trader.LighterTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Error
  alias Bourse.Market
  alias Bourse.Order
  alias Bourse.Signing.Lighter, as: LighterSigning

  @moduletag :exchange_lighter

  @venue :lighter
  @amount 0.011
  @resting_ratio "0.99"
  @maximum_client_order_index 2_000_000_000

  # This journey has no private-stream leg because the authored slice carries no
  # WebSocket URL for lighter at all: `base_urls` holds only "private"/"public"/
  # "root" REST hosts, and `WS.connect(exchange, :private)` answers
  # `{:error, :no_url_configured}` (re-measured live 2026-08-28). That is a gap in
  # our spec, not a venue or credential limit — an earlier note here blamed the
  # testnet key, citing a 20013 "couldnt find account" that came from an
  # unprovisioned account (index 354). The account is provisioned now (index 153),
  # so that reason no longer describes anything; the missing URL still does.

  describe "a trader's day" do
    test "survey the market, place a resting limit buy, track it, cancel it" do
      exchange = sandbox_exchange!(@venue)
      on_exit(fn -> terminate_lighter_helper(exchange) end)

      assert %Market{} = market = Enum.find(exchange.markets, &(&1.base == "BTC" and &1.type == "swap"))
      assert market.active
      assert market.contract and market.linear and market.settle == "USDC"
      assert market.limits["amount"]["min"] <= @amount

      {:ok, ticker} = Bourse.fetch_ticker(exchange, market.symbol)
      assert ticker.symbol == market.symbol
      # Observed live 2026-08-28: ticker carries last/mark/index; bid, ask,
      # and timestamp are nil. The book is the spread authority.
      assert is_number(ticker.last) and ticker.last > 0
      assert is_number(ticker.mark_price) and ticker.mark_price > 0

      {:ok, book} = Bourse.fetch_order_book(exchange, market.symbol)
      assert [[best_bid, bid_size] | _] = book.bids
      assert [[best_ask, ask_size] | _] = book.asks
      assert best_bid <= best_ask
      assert bid_size > 0 and ask_size > 0

      balance = fetch_balance!(exchange)

      for {currency, total} <- balance.total, is_number(total) do
        free = balance.free[currency] || 0.0
        used = balance.used[currency] || 0.0
        assert free >= 0 and used >= 0, "#{currency}: negative balance component"
        assert_in_delta free + used, total, 0.01
      end

      price = resting_price(best_bid, market)
      client_order_index = unique_client_order_index()
      nonce = next_nonce!(exchange)

      assert {:ok, %{"code" => 200, "tx_hash" => tx_hash}} =
               Bourse.create_order(exchange, market.symbol, "limit", "buy", @amount,
                 price: price,
                 client_order_index: client_order_index,
                 nonce: nonce,
                 timeInForce: "PO"
               )

      assert is_binary(tx_hash) and tx_hash != ""

      try do
        order = poll_open_order!(exchange, market.symbol, client_order_index)

        assert order.side == "buy"
        assert order.type == "limit"
        assert order.client_order_id == Integer.to_string(client_order_index)
        assert_in_delta order.price, price, precision!(market, "price") / 2
        assert_in_delta order.amount, @amount, 1.0e-9

        {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: market.symbol)
        assert Enum.any?(open_orders, &(&1.id == order.id)), "resting order missing from open orders"

        assert {:ok, %{"code" => 200, "tx_hash" => cancel_hash}} =
                 Bourse.cancel_order(exchange, order.id,
                   symbol: market.symbol,
                   nonce: next_nonce!(exchange)
                 )

        assert is_binary(cancel_hash) and cancel_hash != ""
        poll_order_gone!(exchange, market.symbol, client_order_index)
      after
        release_lighter_order!(exchange, market.symbol, client_order_index)
      end
    end
  end

  describe "orders the venue rejects" do
    # Both codes were first observed live on testnet.zklighter.elliot.ai on
    # 2026-08-28 against a provisioned account (index 153). They supersede an
    # earlier pin of 21100 "account not found", which described an unprovisioned
    # account rather than the order — every create failed that check first, so no
    # in-flow rejection could be isolated behind it.
    test "sendTx refuses an amount below the market minimum" do
      exchange = sandbox_exchange!(@venue)
      on_exit(fn -> terminate_lighter_helper(exchange) end)

      market = Enum.find(exchange.markets, &(&1.base == "BTC" and &1.type == "swap"))
      {:ok, book} = Bourse.fetch_order_book(exchange, market.symbol)
      [[best_bid, _] | _] = book.bids

      # One precision step below the venue minimum: on the price/amount grid, so
      # our own precision guard passes it through and the venue is what rejects.
      below_minimum = market.limits["amount"]["min"] - precision!(market, "amount")
      assert below_minimum > 0

      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, market.symbol, "limit", "buy", below_minimum,
                 price: resting_price(best_bid, market),
                 client_order_index: unique_client_order_index(),
                 nonce: next_nonce!(exchange),
                 timeInForce: "PO"
               )

      assert error.type == :exchange_error
      assert error.http_status == 400
      assert error.code == 21_706
      assert error.message == "invalid order base or quote amount"
    end

    test "sendTx refuses a replayed nonce" do
      exchange = sandbox_exchange!(@venue)
      on_exit(fn -> terminate_lighter_helper(exchange) end)

      market = Enum.find(exchange.markets, &(&1.base == "BTC" and &1.type == "swap"))
      {:ok, book} = Bourse.fetch_order_book(exchange, market.symbol)
      [[best_bid, _] | _] = book.bids

      # Nonce 1 was consumed by the account's own ChangePubKey registration, so it
      # can never be current again — a replay the venue must refuse.
      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, market.symbol, "limit", "buy", @amount,
                 price: resting_price(best_bid, market),
                 client_order_index: unique_client_order_index(),
                 nonce: 1,
                 timeInForce: "PO"
               )

      assert error.type == :exchange_error
      assert error.http_status == 400
      assert error.code == 21_104
      assert error.message == "invalid nonce"
    end
  end

  defp fetch_balance!(exchange) do
    case Bourse.fetch_balance(exchange) do
      {:ok, balance} ->
        assert map_size(balance.total) > 0
        balance

      {:error, %Error{code: 29_404, message: message}} ->
        flunk("""
        Lighter testnet account is not found (code 29404: #{message}).
        Refresh LIGHTER_TESTNET_API_KEY_INDEX, LIGHTER_TESTNET_ACCOUNT_INDEX, \
        and LIGHTER_TESTNET_API_PRIVATE_KEY, then re-run this journey.
        """)

      {:error, error} ->
        flunk("fetch_balance failed: #{inspect(error)}")
    end
  end

  defp next_nonce!(exchange) do
    assert {:ok, %{status: 200, body: %{"code" => 200, "nonce" => nonce}}} =
             Bourse.Lighter.public_get_nextnonce(exchange, %{
               "account_index" => credential_integer!(exchange.credentials.uid),
               "api_key_index" => credential_integer!(exchange.credentials.api_key)
             })

    nonce
  end

  defp unique_client_order_index do
    [:positive, :monotonic]
    |> System.unique_integer()
    |> rem(@maximum_client_order_index)
  end

  defp resting_price(best_bid, market) do
    tick = Decimal.from_float(precision!(market, "price"))

    best_bid
    |> Decimal.from_float()
    |> Decimal.mult(Decimal.new(@resting_ratio))
    |> Decimal.div(tick)
    |> Decimal.round(0, :floor)
    |> Decimal.mult(tick)
    |> Decimal.to_float()
  end

  defp poll_open_order!(exchange, symbol, client_order_index) do
    poll_until!("Lighter order #{client_order_index} visible as open", fn ->
      case find_open_order(exchange, symbol, client_order_index) do
        %Order{status: "open"} = order -> {:ok, order}
        %Order{} -> :retry
        nil -> :retry
      end
    end)
  end

  defp poll_order_gone!(exchange, symbol, client_order_index) do
    poll_until!("Lighter order #{client_order_index} gone from open orders", fn ->
      if find_open_order(exchange, symbol, client_order_index), do: :retry, else: {:ok, :gone}
    end)
  end

  defp find_open_order(exchange, symbol, client_order_index) do
    case Bourse.fetch_open_orders(exchange, symbol: symbol) do
      {:ok, orders} -> Enum.find(orders, &(&1.client_order_id == Integer.to_string(client_order_index)))
      {:error, error} -> flunk("fetch_open_orders failed: #{inspect(error)}")
    end
  end

  defp release_lighter_order!(exchange, symbol, client_order_index) do
    case find_open_order(exchange, symbol, client_order_index) do
      nil ->
        :ok

      %Order{id: id} ->
        case Bourse.cancel_order(exchange, id, symbol: symbol, nonce: next_nonce!(exchange)) do
          {:ok, %{"code" => 200}} -> :ok
          {:error, %Error{type: type}} when type in [:order_not_found, :invalid_order] -> :ok
          {:error, error} -> flunk("cleanup for order #{id} failed: #{inspect(error)}")
        end
    end
  end

  defp terminate_lighter_helper(exchange) do
    config =
      (exchange.signing_config || %{})
      |> Map.put(:base_url, exchange.base_urls["private"])
      |> Map.put(:testnet, exchange.sandbox)
      |> Map.put(:exchange_options, exchange.options || %{})

    _ = LighterSigning.terminate_helper(exchange.credentials, config)
    :ok
  end

  defp credential_integer!(value) when is_integer(value), do: value
  defp credential_integer!(value) when is_binary(value), do: String.to_integer(value)

  defp precision!(market, field), do: Map.fetch!(market.precision, field)
end
