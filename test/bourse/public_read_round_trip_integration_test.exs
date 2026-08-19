defmodule Bourse.Test.PublicReadSmokeMatrix do
  @moduledoc """
  Live public-read smoke venues and explicit exclusions for runtime support.

  Completeness is `venue_symbols ∪ exclusions == Registry.exchanges()`. A
  venue may leave the live smoke only with a registered reason, matching the
  time-window matrix exclusion shape (`venue`, `reason`, `tracking`).
  """

  @type exclusion :: %{
          venue: atom(),
          reason: String.t(),
          tracking: String.t()
        }

  @venue_symbols [
    alpaca: "GLD",
    binance: "BTC/USDT",
    binancecoinm: "BTC/USD:BTC",
    binanceusdm: "BTC/USDT:USDT",
    bybit: "BTC/USDT",
    coinbaseexchange: "ETH/USD",
    deribit: "BTC/USD:BTC",
    derive: "BTC/USD:USDC",
    hyperliquid: "BTC/USDC:USDC",
    lighter: "BTC/USDC:USDC",
    okx: "BTC/USDT"
  ]

  # Empty on purpose: every runtime venue is live-smoked. A deliberate omission
  # must land here with reason + tracking, or the offline inventory test fails.
  @exclusions []

  @doc "Preferred public symbols for each live-smoked venue."
  @spec venue_symbols() :: keyword(String.t())
  def venue_symbols, do: @venue_symbols

  @doc "Venues intentionally left out of the live smoke, with tracking."
  @spec exclusions() :: [exclusion()]
  def exclusions, do: @exclusions
end

defmodule Bourse.PublicReadSmokeInventoryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Bourse.Registry
  alias Bourse.Test.PublicReadSmokeMatrix

  test "smoke inventory covers every supported venue" do
    smoke = PublicReadSmokeMatrix.venue_symbols() |> Keyword.keys() |> Enum.map(&Atom.to_string/1)
    excluded = Enum.map(PublicReadSmokeMatrix.exclusions(), &Atom.to_string(&1.venue))

    assert length(smoke) == MapSet.size(MapSet.new(smoke)), "duplicate live public-read smoke venue"
    assert length(excluded) == MapSet.size(MapSet.new(excluded)), "duplicate public-read smoke exclusion"
    assert MapSet.disjoint?(MapSet.new(smoke), MapSet.new(excluded))

    covered = MapSet.new(smoke ++ excluded)
    expected = MapSet.new(Registry.exchanges())

    assert covered == expected,
           "public-read smoke inventory drift: #{inspect(MapSet.symmetric_difference(expected, covered))}"
  end

  test "every exclusion names why it cannot be probed and where it is tracked" do
    exclusions = PublicReadSmokeMatrix.exclusions()
    assert is_list(exclusions)

    Enum.each(exclusions, fn exclusion ->
      assert exclusion |> Map.keys() |> Enum.sort() == [:reason, :tracking, :venue]

      %{venue: venue, reason: reason, tracking: tracking} = exclusion
      assert String.trim(reason) != "", "#{venue} exclusion has no reason"
      assert tracking =~ ~r/task(?:s)? \d+/i, "#{venue} exclusion has no task tracking reference"
    end)
  end
end

defmodule Bourse.PublicReadRoundTripIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2]

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Test.FixtureGateIsolation
  alias Bourse.Test.PublicReadSmokeMatrix
  alias Bourse.Ticker

  @moduletag :integration
  @moduletag :network

  for {venue, preferred_symbol} <- PublicReadSmokeMatrix.venue_symbols() do
    @tag :"exchange_#{venue}"
    test "#{venue} fetch_ticker accepts a live public symbol" do
      venue = unquote(venue)
      preferred_symbol = unquote(preferred_symbol)
      FixtureGateIsolation.isolate!(Atom.to_string(venue))
      exchange = live_exchange(venue)
      symbol = live_symbol(exchange, preferred_symbol)

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

  # Public-only production host; sandbox: true is :no_testnet_data.
  defp live_exchange(:coinbaseexchange), do: build_exchange(:coinbaseexchange, [])

  defp live_exchange(venue), do: build_exchange(venue, sandbox: true)

  defp live_symbol(exchange, preferred_symbol) do
    if Exchange.has?(exchange, "fetchMarkets") do
      assert {:ok, markets} = Bourse.fetch_markets(exchange)
      assert markets != []

      assert %Market{symbol: symbol, active: active} =
               Enum.find(markets, &(&1.symbol == preferred_symbol))

      assert active != false
      symbol
    else
      preferred_symbol
    end
  end

  defp positive_number?(value), do: is_number(value) and value > 0
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
