defmodule Bourse.WS.URLRouting do
  @moduledoc """
  Pure URL resolution for WebSocket endpoints.

  Given a `%Bourse.Exchange{}`, returns the public or private WS URL appropriate
  for the current sandbox flag, with `{hostname}` interpolated from
  `exchange.hostname`.

  URLs come from `Bourse.WS.Config`, which prefers resolved `websocket.urls`
  from the spec and falls back to hand-maintained bases when absent.

  Binance USD-M additionally authors a `/market` host; `stream_url/2` picks it
  for regular market streams so a `/public` socket cannot silently drop them.
  """

  alias Bourse.Exchange
  alias Bourse.WS.Config
  alias Bourse.WS.Helpers

  # Binance USD-M WebSocket Market Streams: /market carries regular data
  # (miniTicker, ticker, aggTrade, kline, markPrice, forceOrder). /public
  # carries high-frequency bookTicker/depth; live /ws also delivers @trade.
  # `@ticker` is not a substring of `@bookTicker`, so the needle is safe.
  @market_needles [
    "!assetIndex",
    "!contractInfo",
    "!forceOrder",
    "!markPrice",
    "!miniTicker",
    "!ticker@",
    "@aggTrade",
    "@assetIndex",
    "@compositeIndex",
    "@forceOrder",
    "@kline_",
    "@markPrice",
    "@miniTicker",
    "@ticker",
    "continuousKline_"
  ]

  @doc """
  Public WS URL for the given exchange, or nil if the exchange has no WS config.

  Honors `exchange.sandbox` — returns the sandbox URL when the flag is true
  and a sandbox URL is configured.
  """
  @spec public_url(Exchange.t()) :: String.t() | nil
  def public_url(%Exchange{} = exchange) do
    resolve(exchange, :public)
  end

  @doc """
  Private WS URL for the given exchange, or nil if the exchange has no WS config
  or no private endpoint.
  """
  @spec private_url(Exchange.t()) :: String.t() | nil
  def private_url(%Exchange{} = exchange) do
    resolve(exchange, :private)
  end

  @doc """
  USD-M regular-market stream host (`/market/ws`), or nil when the venue has none.

  Binance split USD-M market streams off the high-frequency `/public` host.
  `watch_ticker` and other `/market` streams resolve here; other venues stay nil.
  """
  @spec market_url(Exchange.t()) :: String.t() | nil
  def market_url(%Exchange{} = exchange) do
    resolve(exchange, :market)
  end

  @doc """
  Public-section URL that actually delivers `channel`.

  USD-M `@miniTicker` / `@ticker` / `@aggTrade` live on `/market/ws`; depth,
  `@trade`, and `@bookTicker` stay on `/public/ws`. Other venues return
  `public_url/1`.
  """
  @spec stream_url(Exchange.t(), String.t()) :: String.t() | nil
  def stream_url(%Exchange{} = exchange, channel) when is_binary(channel) do
    case {exchange.id, usdm_family(channel)} do
      {"binanceusdm", :market} -> market_url(exchange) || public_url(exchange)
      _ -> public_url(exchange)
    end
  end

  @doc """
  True when `url` is an authored USD-M public or market host, including the
  legacy unrouted `/ws` alias that still behaves like `/public`.
  """
  @spec authored_usdm_host?(Exchange.t(), String.t()) :: boolean()
  def authored_usdm_host?(%Exchange{} = exchange, url) when is_binary(url) do
    url in authored_usdm_hosts(exchange)
  end

  defp authored_usdm_hosts(%Exchange{} = exchange) do
    Enum.reject(
      [public_url(exchange), market_url(exchange), "wss://fstream.binance.com/ws", "wss://demo-fstream.binance.com/ws"],
      &is_nil/1
    )
  end

  defp usdm_family(channel) do
    if Enum.any?(@market_needles, &String.contains?(channel, &1)), do: :market, else: :public
  end

  defp resolve(%Exchange{} = exchange, section) do
    %{sandbox: sandbox, hostname: hostname} = exchange

    case Config.for_exchange(exchange) do
      nil ->
        nil

      config ->
        config
        |> pick_url(section, sandbox)
        |> Helpers.interpolate_hostname(hostname)
    end
  end

  defp pick_url(config, :public, true), do: config[:public_url_sandbox] || config[:public_url]
  defp pick_url(config, :public, false), do: config[:public_url]
  defp pick_url(config, :market, true), do: config[:market_url_sandbox] || config[:market_url]
  defp pick_url(config, :market, false), do: config[:market_url]
  defp pick_url(config, :private, true), do: config[:private_url_sandbox] || config[:private_url]
  defp pick_url(config, :private, false), do: config[:private_url]
end
