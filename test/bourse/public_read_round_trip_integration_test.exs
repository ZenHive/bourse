defmodule Bourse.PublicReadRoundTripIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2]

  alias Bourse.Credentials
  alias Bourse.Market
  alias Bourse.Test.FixtureGateIsolation
  alias Bourse.Ticker

  @moduletag :integration
  @moduletag :network

  @venue_symbols [
    alpaca: "GLD",
    binance: "BTC/USDT",
    binancecoinm: "BTC/USD:BTC",
    binanceusdm: "BTC/USDT:USDT",
    bybit: "BTC/USDT",
    deribit: "BTC/USD:BTC",
    derive: "BTC/USD:USDC",
    hyperliquid: "BTC/USDC:USDC",
    lighter: "BTC/USDC:USDC",
    okx: "BTC/USDT"
  ]

  test "smoke inventory covers every supported venue" do
    venues = @venue_symbols |> Keyword.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    assert venues == Bourse.Registry.exchanges()
  end

  for {venue, preferred_symbol} <- @venue_symbols do
    @tag :"exchange_#{venue}"
    test "#{venue} fetch_ticker accepts a symbol returned by live fetch_markets" do
      venue = unquote(venue)
      preferred_symbol = unquote(preferred_symbol)
      FixtureGateIsolation.isolate!(Atom.to_string(venue))
      exchange = live_exchange(venue)

      assert {:ok, markets} = Bourse.fetch_markets(exchange)
      assert markets != []

      assert %Market{symbol: symbol, active: active} =
               Enum.find(markets, &(&1.symbol == preferred_symbol))

      assert active != false
      assert {:ok, %Ticker{symbol: ^symbol} = ticker} = Bourse.fetch_ticker(exchange, symbol)
      assert Enum.any?([ticker.last, ticker.bid, ticker.ask, ticker.mark_price, ticker.index_price], &positive_number?/1)
    end
  end

  defp live_exchange(:alpaca) do
    api_key = System.get_env("ALPACA_API_KEY")
    secret = System.get_env("ALPACA_API_SECRET")

    if !(present?(api_key) and present?(secret)) do
      flunk("""
      Missing Alpaca paper-account credentials!

      Set these environment variables and re-run:
        export ALPACA_API_KEY="your_key"
        export ALPACA_API_SECRET="your_secret"

      Get paper-account credentials at: https://app.alpaca.markets/signup
      """)
    end

    credentials = Credentials.new!(api_key: api_key, secret: secret)
    build_exchange(:alpaca, credentials: credentials, sandbox: true)
  end

  defp live_exchange(venue), do: build_exchange(venue, sandbox: true)

  defp positive_number?(value), do: is_number(value) and value > 0
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
