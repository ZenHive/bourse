defmodule Bourse.Unified.ReadParseHelpersTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Unified.ReadParse

  defmodule TickerParser do
    @moduledoc false
    def parse_ticker(raw, _opts) do
      {:ok, %Bourse.Ticker{last: Bourse.Safe.number(raw["markPx"]), info: raw}}
    end
  end

  test "indexes only tickers that can be assigned a market symbol" do
    tickers = [%Bourse.Ticker{last: 1.0}, %Bourse.Ticker{symbol: "ETH/USDC", last: 2.0}]

    assert %{"ETH/USDC" => %Bourse.Ticker{last: 2.0}} =
             ReadParse.index_tickers_by_markets(tickers, [])
  end

  test "uses a raw market symbol when a ticker lacks one" do
    assert %{"BTC/USDT" => %Bourse.Ticker{symbol: "BTC/USDT"}} =
             ReadParse.index_tickers_by_markets([%Bourse.Ticker{}], [%{"symbol" => "BTC/USDT"}])
  end

  test "builds Hyperliquid ticker symbols from market context" do
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, %{"BTC/USDC:USDC" => %Bourse.Ticker{last: 65_000.0} = ticker}} =
             ReadParse.build_tickers_from_meta_asset_ctxs(
               exchange,
               TickerParser,
               [
                 %{"universe" => [%{"name" => "BTC", "maxLeverage" => 50}]},
                 [%{"markPx" => "65000"}]
               ]
             )

    assert ticker.info["name"] == "BTC"
  end

  test "drops ticker contexts without a resolvable market symbol" do
    exchange = Exchange.new!("hyperliquid")

    assert {:ok, %{}} =
             ReadParse.build_tickers_from_meta_asset_ctxs(
               exchange,
               TickerParser,
               [%{"universe" => [%{"unknown" => "BTC"}]}, [%{"markPx" => "65000"}]]
             )
  end
end
