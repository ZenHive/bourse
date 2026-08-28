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

  # Lighter's account_all_orders stream is unreachable with the configured
  # testnet key (docs/prod-verification-ledger.md, task 681). Observed live
  # 2026-08-28 against wss://testnet.zklighter.elliot.ai/stream:
  # `WS.connect(:private)` → `:no_url_configured`; public subscribe without
  # `auth` → code 20001 "auth field is required"; subscribe with a signed
  # auth token → code 20013 "invalid auth: couldnt find account".

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
    test "sendTx refuses an order when the testnet account is not found" do
      exchange = sandbox_exchange!(@venue)
      on_exit(fn -> terminate_lighter_helper(exchange) end)

      market = Enum.find(exchange.markets, &(&1.base == "BTC" and &1.type == "swap"))
      {:ok, book} = Bourse.fetch_order_book(exchange, market.symbol)
      [[best_bid, _] | _] = book.bids

      # Observed live 2026-08-28 on testnet.zklighter.elliot.ai: sendTx
      # rejects every create for this configured account with code 21100
      # "account not found" (publicGetAccount is 29404 "not found" first).
      # A below-minimum amount could not be isolated — the account check
      # wins. Re-pin against a recognized account once credentials refresh.
      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, market.symbol, "limit", "buy", @amount,
                 price: resting_price(best_bid, market),
                 client_order_index: unique_client_order_index(),
                 nonce: next_nonce!(exchange),
                 timeInForce: "PO"
               )

      assert error.type == :exchange_error
      assert error.http_status == 400
      assert error.code == 21_100
      assert error.message == "account not found"
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
