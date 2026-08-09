defmodule Bourse.LoadMarketsTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Ticker

  describe "Exchange markets cache (pure data)" do
    test "new exchange has markets: nil" do
      exchange = Exchange.new!("lighter")
      assert is_nil(exchange.markets)
      assert is_nil(Exchange.markets(exchange))
    end

    test "put_markets/2 threads markets on the struct without network" do
      exchange = Exchange.new!("lighter")
      markets = [%Market{id: "1", symbol: "BTC/USDC:USDC"}]

      loaded = Exchange.put_markets(exchange, markets)

      assert loaded.markets == markets
      assert Exchange.markets(loaded) == markets
      # original unchanged (pure data)
      assert is_nil(exchange.markets)
    end
  end

  describe "load_markets/2" do
    test "fetches markets once and attaches them to the returned exchange" do
      markets_count = :counters.new(1, [:atomics])
      stub = lighter_stub(markets_count)

      exchange = Exchange.new!("lighter")

      assert {:ok, loaded} = Bourse.load_markets(exchange, plug: {Req.Test, stub})
      assert match?([_ | _], loaded.markets)
      assert Enum.any?(loaded.markets, &(&1.symbol == "BTC/USDC:USDC"))
      assert :counters.get(markets_count, 1) == 1
    end

    test "load_markets!/2 raises on transport error" do
      stub = unique_stub("load_markets_error")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "boom"})
      end)

      exchange = Exchange.new!("lighter")

      assert_raise Bourse.Error, fn ->
        Bourse.load_markets!(exchange, plug: {Req.Test, stub})
      end
    end
  end

  describe "market_id resolution reuses loaded markets (Task 215)" do
    test "two fetch_ticker calls after load_markets do not re-fetch markets" do
      markets_count = :counters.new(1, [:atomics])
      ticker_count = :counters.new(1, [:atomics])
      stub = lighter_stub(markets_count, ticker_count)

      exchange = Exchange.new!("lighter")
      assert {:ok, exchange} = Bourse.load_markets(exchange, plug: {Req.Test, stub})
      assert :counters.get(markets_count, 1) == 1

      assert {:ok, %Ticker{symbol: "BTC/USDC:USDC"}} =
               Bourse.fetch_ticker(exchange, "BTC/USDC:USDC", plug: {Req.Test, stub})

      assert {:ok, %Ticker{symbol: "BTC/USDC:USDC"}} =
               Bourse.fetch_ticker(exchange, "BTC/USDC:USDC", plug: {Req.Test, stub})

      # One markets fetch from load_markets; tickers reuse the cache
      assert :counters.get(markets_count, 1) == 1
      assert :counters.get(ticker_count, 1) == 2
    end

    test "without load_markets, each market_id resolution re-fetches markets" do
      markets_count = :counters.new(1, [:atomics])
      ticker_count = :counters.new(1, [:atomics])
      stub = lighter_stub(markets_count, ticker_count)

      exchange = Exchange.new!("lighter")
      assert is_nil(exchange.markets)

      assert {:ok, %Ticker{}} =
               Bourse.fetch_ticker(exchange, "BTC/USDC:USDC", plug: {Req.Test, stub})

      assert {:ok, %Ticker{}} =
               Bourse.fetch_ticker(exchange, "BTC/USDC:USDC", plug: {Req.Test, stub})

      assert :counters.get(markets_count, 1) == 2
      assert :counters.get(ticker_count, 1) == 2
    end

    test "put_markets/2 alone is enough for resolution without a markets network call" do
      markets_count = :counters.new(1, [:atomics])
      ticker_count = :counters.new(1, [:atomics])
      stub = lighter_stub(markets_count, ticker_count)

      exchange =
        "lighter"
        |> Exchange.new!()
        |> Exchange.put_markets([%Market{id: "1", symbol: "BTC/USDC:USDC"}])

      assert {:ok, %Ticker{}} =
               Bourse.fetch_ticker(exchange, "BTC/USDC:USDC", plug: {Req.Test, stub})

      assert :counters.get(markets_count, 1) == 0
      assert :counters.get(ticker_count, 1) == 1
    end

    test "accepts integer and opaque string market ids from the loaded market" do
      markets_count = :counters.new(1, [:atomics])
      ticker_count = :counters.new(1, [:atomics])
      stub = lighter_stub(markets_count, ticker_count)

      for id <- [1, "perp-btc"] do
        exchange =
          "lighter"
          |> Exchange.new!()
          |> Exchange.put_markets([%Market{id: id, symbol: "BTC/USDC:USDC"}])

        assert {:ok, %Ticker{}} =
                 Bourse.fetch_ticker(exchange, "BTC/USDC:USDC", plug: {Req.Test, stub})
      end

      assert :counters.get(markets_count, 1) == 0
      assert :counters.get(ticker_count, 1) == 2
    end

    test "rejects missing and unknown symbols before dispatch" do
      exchange =
        "lighter"
        |> Exchange.new!()
        |> Exchange.put_markets([%Market{id: "1", symbol: "BTC/USDC:USDC"}])

      assert {:error, %Bourse.Error{type: :bad_symbol, message: missing_message}} =
               Bourse.Unified.call(exchange, :fetch_ticker, "fetchTicker", %{}, [])

      assert missing_message =~ "requires a known market symbol"

      assert {:error, %Bourse.Error{type: :bad_symbol, message: unknown_message}} =
               Bourse.fetch_ticker(exchange, "ETH/USDC:USDC")

      assert unknown_message == "Unknown market symbol ETH/USDC:USDC"
    end

    test "rejects string-keyed market rows instead of guessing their id shape" do
      exchange =
        "lighter"
        |> Exchange.new!()
        |> Exchange.put_markets([%{"id" => 1, "symbol" => "BTC/USDC:USDC"}])

      assert {:error, %Bourse.Error{type: :bad_symbol, message: message}} =
               Bourse.fetch_ticker(exchange, "BTC/USDC:USDC")

      assert message == "Unknown market symbol BTC/USDC:USDC"
    end

    test "rejects loaded rows without a symbol" do
      exchange =
        "lighter"
        |> Exchange.new!()
        |> Exchange.put_markets([%{id: 1}])

      assert {:error, %Bourse.Error{type: :bad_symbol}} =
               Bourse.fetch_ticker(exchange, "BTC/USDC:USDC")
    end
  end

  # Lighter fetchMarkets and fetchTicker share publicGetOrderBookDetails.
  # Markets requests omit market_id; ticker requests include it after resolution.
  defp lighter_stub(markets_count, ticker_count \\ nil) do
    stub = unique_stub("lighter_markets_cache")

    Req.Test.stub(stub, fn conn ->
      respond_lighter(conn, markets_count, ticker_count)
    end)

    stub
  end

  defp respond_lighter(conn, markets_count, ticker_count) do
    if Map.has_key?(query_params(conn), "market_id") do
      count_request(ticker_count)
      Req.Test.json(conn, lighter_ticker_body())
    else
      count_request(markets_count)
      Req.Test.json(conn, lighter_markets_body())
    end
  end

  defp count_request(nil), do: :ok
  defp count_request(counter), do: :counters.add(counter, 1, 1)

  defp lighter_ticker_body do
    %{
      "code" => 200,
      "order_book_details" => [
        %{
          "market_id" => 1,
          "symbol" => "BTC",
          "market_type" => "perp",
          "last_trade_price" => "50000.5",
          "daily_price_high" => "51000",
          "daily_price_low" => "49000",
          "daily_base_token_volume" => "100",
          "daily_quote_token_volume" => "5_000_000"
        }
      ]
    }
  end

  defp lighter_markets_body do
    %{
      "code" => 200,
      "order_book_details" => [
        %{
          "symbol" => "BTC",
          "market_id" => 1,
          "market_type" => "perp",
          "taker_fee" => "0.0001",
          "maker_fee" => "0.0000",
          "min_base_amount" => "0.01",
          "min_quote_amount" => "0.1",
          "size_decimals" => "4",
          "price_decimals" => "4"
        }
      ]
    }
  end

  defp query_params(%Plug.Conn{query_string: qs}) when is_binary(qs) and qs != "" do
    URI.decode_query(qs)
  end

  defp query_params(_conn), do: %{}

  defp unique_stub(label) do
    :"load_markets_#{label}_#{System.unique_integer([:positive])}"
  end
end
