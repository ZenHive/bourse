defmodule Bourse.Journeys.Trader.AlpacaTest do
  use Bourse.Test.Journeys.Case, async: false

  alias Bourse.Dispatch
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Order

  @moduletag :exchange_alpaca

  @venue :alpaca
  @symbol "BTC/USD"
  @paper_host "paper-api.alpaca.markets"
  # 0.001 BTC at a 10% under-market limit sits well above Alpaca's $10
  # USD-pair notional floor (docs: 10 / USD asset price).
  @amount 0.001
  @price_decimals 2
  @resting_ratio 0.9

  # Alpaca's private trade_updates stream is not wired
  # (docs/prod-verification-ledger.md, task 674). Observed live 2026-08-28:
  # `WS.connect(:private)` → `:no_url_configured` because authored
  # `websocket.urls.private` / `sandbox_private` are null. The provider hosts
  # account events at wss://paper-api.alpaca.markets/stream.

  describe "a trader's day" do
    test "survey the market, place a resting limit buy, track it, cancel it" do
      exchange = paper_crypto_exchange!()

      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      assert market, "#{@symbol} missing from loaded alpaca crypto markets"
      assert market.active
      assert market.info["class"] == "crypto"
      assert market.info["tradable"] == true
      assert market.quote == "USD"
      assert market.limits["amount"]["min"] <= @amount

      {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol)
      assert ticker.symbol == @symbol
      assert ticker.bid > 0 and ticker.ask > 0 and ticker.bid <= ticker.ask
      assert is_number(ticker.last) and ticker.last > 0
      assert_recent_timestamp!(ticker.timestamp)

      {best_bid, bid_size, best_ask, ask_size} = crypto_book_top!(exchange)
      assert best_bid <= best_ask
      assert bid_size > 0 and ask_size > 0

      {:ok, balance} = Bourse.fetch_balance(exchange)
      assert map_size(balance.total) > 0
      # Observed live 2026-08-28: paper GET /v2/account has no timestamp field,
      # so the unified Balance.timestamp stays nil.

      for {currency, total} <- balance.total, is_number(total) do
        free = balance.free[currency] || 0.0
        used = balance.used[currency] || 0.0
        assert free >= 0 and used >= 0, "#{currency}: negative balance component"
        assert_in_delta free + used, total, 0.01
      end

      price = Float.round(best_bid * @resting_ratio, @price_decimals)
      client_order_id = unique_client_order_id("trader-alpaca")

      {:ok, placed} =
        Bourse.create_order(exchange, @symbol, "limit", "buy", @amount,
          price: price,
          client_order_id: client_order_id,
          time_in_force: "gtc"
        )

      assert is_binary(placed.id) and placed.id != ""

      try do
        order =
          poll_until!("order #{placed.id} visible as open", fn ->
            case Bourse.fetch_order(exchange, placed.id) do
              {:ok, %Order{status: "open"} = order} -> {:ok, order}
              {:ok, %Order{}} -> :retry
              {:error, %Error{type: :invalid_order}} -> :retry
              {:error, error} -> flunk("fetch_order failed: #{inspect(error)}")
            end
          end)

        assert order.side == "buy"
        assert order.type == "limit"
        assert order.client_order_id == client_order_id
        assert_in_delta order.price, price, 0.05
        assert_in_delta order.amount, @amount, 1.0e-9

        {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
        assert Enum.any?(open_orders, &(&1.id == placed.id)), "resting order missing from open orders"

        {:ok, canceled} = Bourse.cancel_order(exchange, placed.id, symbol: @symbol)
        assert canceled.id == placed.id

        poll_until!("order #{placed.id} gone from open orders", fn ->
          {:ok, open} = Bourse.fetch_open_orders(exchange, symbol: @symbol)
          if Enum.any?(open, &(&1.id == placed.id)), do: :retry, else: {:ok, :gone}
        end)
      after
        release_order!(exchange, placed.id, @symbol)
      end
    end
  end

  describe "orders the venue rejects" do
    test "a notional below Alpaca's USD-pair floor is refused with Alpaca's own error" do
      exchange = paper_crypto_exchange!()
      {best_bid, _bid_size, _best_ask, _ask_size} = crypto_book_top!(exchange)
      price = Float.round(best_bid * @resting_ratio, @price_decimals)
      # $1 of notional at the resting price is under the $10 USD-pair floor
      # (https://docs.alpaca.markets/us/docs/crypto-trading-1 — "10/USD asset price").
      below_floor = 1.0 / price

      assert {:error, %Error{} = error} =
               Bourse.create_order(exchange, @symbol, "limit", "buy", below_floor,
                 price: price,
                 time_in_force: "gtc"
               )

      # Observed live 2026-08-28 on paper-api.alpaca.markets: HTTP 403,
      # code 40310000, "cost basis must be >= minimal amount of order 10".
      # Alpaca's own docs name 40310000 as an authorization/business refusal
      # (https://docs.alpaca.markets/us/reference/postorder). The unified type
      # comes from `Bourse.HTTP.Errors`, which short-circuits every 401/403 to
      # authentication_error before any authored mapping is consulted — the
      # venue's own code and message are what pin the refusal here.
      assert error.type == :authentication_error
      assert error.code == 40_310_000
      assert error.http_status == 403
      assert error.message =~ "cost basis must be >= minimal amount of order 10"
    end
  end

  defp paper_crypto_exchange! do
    exchange = sandbox_exchange!(@venue)
    paper_url = Dispatch.resolve_base_url(["trader", "private"], exchange.base_urls)

    assert URI.parse(paper_url).host == @paper_host,
           "Alpaca trader journey must stay on the paper host, resolved #{inspect(paper_url)}"

    # fetchMarkets defaults to asset_class us_equity. Crypto pairs are a
    # separate class on GET /v2/assets (https://docs.alpaca.markets/us/docs/crypto-trading).
    case Bourse.fetch_markets(exchange, asset_class: "crypto") do
      {:ok, markets} -> Exchange.put_markets(exchange, markets)
      {:error, error} -> flunk("alpaca: crypto fetch_markets failed: #{inspect(error)}")
    end
  end

  # Unified fetchOrderBook is not offered. The live book is the public crypto
  # latest-orderbooks read (https://docs.alpaca.markets/us/docs/crypto-trading).
  defp crypto_book_top!(exchange) do
    config =
      Enum.find(exchange.module.__endpoints__(), fn endpoint ->
        endpoint.path == "v1beta3/crypto/{loc}/latest/orderbooks" and endpoint.method == :get
      end)

    assert config, "alpaca crypto latest/orderbooks endpoint missing from the authored spec"

    case Dispatch.call(exchange, config, %{"loc" => "us", "symbols" => @symbol}) do
      {:ok, %{body: %{"orderbooks" => %{@symbol => %{"b" => [bid | _], "a" => [ask | _]}}}}} ->
        {bid["p"], bid["s"], ask["p"], ask["s"]}

      other ->
        flunk("alpaca crypto order book for #{@symbol} failed: #{inspect(other)}")
    end
  end
end
