defmodule Bourse.Test.Generator.SymbolResolver do
  @moduledoc """
  Compile-time test-symbol resolver for integration probes (Tasks 79, 39).

  Walks each exchange's frozen reference `markets.symbols_index` map and returns a unified
  symbol suitable for symbol-required public/private probes (`fetch_ticker`,
  `fetch_ohlcv`, `fetch_order_book`, `fetch_trades`, `fetch_funding_rate`).

  Selection order for `pick_symbol/1`:

    1. The preference list — common spot pairs, then linear perps, then
       inverse perps. Ordered by ubiquity across exchanges. USDC linear
       perps (`BTC/USDC:USDC`, `ETH/USDC:USDC`) are preferred ahead of bare
       `BTC/USDC` / `ETH/USDC` spot aliases because several DEX venues
       (lighter, hyperliquid) list the spot form in the reference index
       but only serve the perpetual form live.
    2. First spot market in the spec.
    3. First swap market in the spec.
    4. First market of any kind.

  `pick_funding_symbol/1` only selects perpetual/swap markets — funding-rate
  endpoints reject spot instruments (verified live 2026-07-29 on binance,
  okx, deribit).

  Returns `nil` when the spec has no markets — callers should skip emission
  for that exchange/method combination.

  Spec-driven by design: hand-maintained per-exchange symbol overrides
  duplicate information already in the spec and break exactly when upstream
  adds a new exchange.
  """

  alias Bourse.Spec
  alias Mix.Tasks.Ccxt.ReferenceCorpus

  # Spot aliases first for CEX ubiquity. Linear-perp forms next (covers
  # futures-only and DEX venues). Inverse-perp after. Bare USDC spot forms
  # trail their `:USDC` perpetual siblings so lighter/hyperliquid probes do
  # not pick a symbols_index spot alias that the live venue rejects.
  @preferred_symbols [
    "BTC/USDT",
    "ETH/USDT",
    "BTC/USD",
    "BTC/USDT:USDT",
    "ETH/USDT:USDT",
    "BTC/USDC:USDC",
    "ETH/USDC:USDC",
    "BTC/USD:BTC",
    "ETH/USD:ETH",
    "BTC/USDC",
    "ETH/USDC"
  ]

  @preferred_funding_symbols [
    "BTC/USDT:USDT",
    "ETH/USDT:USDT",
    "BTC/USDC:USDC",
    "ETH/USDC:USDC",
    "BTC/USD:BTC",
    "ETH/USD:ETH"
  ]

  @doc """
  Returns a unified test symbol for `exchange_id`, or `nil` if the spec
  has no markets.
  """
  @spec pick_symbol(binary()) :: binary() | nil
  def pick_symbol(exchange_id) when is_binary(exchange_id) do
    markets = markets(exchange_id)
    if map_size(markets) == 0, do: nil, else: find_symbol(markets)
  end

  @doc """
  Returns a perpetual/swap symbol suitable for funding-rate probes, or `nil`.

  Spot symbols are excluded: venues reject them for funding-rate endpoints
  (binance multi-endpoint ambiguity / OKX Parameter error / Deribit
  "instrument is not perpetual").
  """
  @spec pick_funding_symbol(binary()) :: binary() | nil
  def pick_funding_symbol(exchange_id) when is_binary(exchange_id) do
    markets = markets(exchange_id)
    if map_size(markets) == 0, do: nil, else: find_funding_symbol(markets)
  end

  @doc "Returns the test-only frozen market index for an exchange."
  @spec markets(binary()) :: map()
  def markets(exchange_id) when is_binary(exchange_id) do
    exchange_id
    |> ReferenceCorpus.spec_path()
    |> Spec.decode_file!()
    |> get_in(["markets", "symbols_index"])
    |> case do
      m when is_map(m) -> m
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  @doc """
  The preference list driving spot/perp selection. Exposed for tests.
  """
  @spec preferred_symbols() :: [binary()]
  def preferred_symbols, do: @preferred_symbols

  @doc """
  The preference list for funding-rate perpetual selection. Exposed for tests.
  """
  @spec preferred_funding_symbols() :: [binary()]
  def preferred_funding_symbols, do: @preferred_funding_symbols

  defp find_symbol(markets) do
    Enum.find_value(@preferred_symbols, fn sym ->
      if Map.has_key?(markets, sym), do: sym
    end) || first_market(markets, "spot") || first_market(markets, "swap") ||
      markets |> Map.keys() |> Enum.sort() |> List.first()
  end

  defp find_funding_symbol(markets) do
    Enum.find_value(@preferred_funding_symbols, fn sym ->
      if Map.has_key?(markets, sym) and swap_market?(Map.get(markets, sym)), do: sym
    end) || first_market(markets, "swap")
  end

  defp swap_market?(%{} = data), do: data["swap"] == true or data["type"] == "swap"
  defp swap_market?(_), do: false

  defp first_market(markets, type) do
    markets
    |> Enum.sort_by(fn {sym, _data} -> sym end)
    |> Enum.find(fn {_sym, data} -> is_map(data) and Map.get(data, type) == true end)
    |> case do
      {sym, _data} -> sym
      nil -> nil
    end
  end
end
