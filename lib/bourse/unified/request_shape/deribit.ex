defmodule Bourse.Unified.RequestShape.Deribit do
  @moduledoc false

  # Deribit indexes altcoin option books under the USDC settlement currency.
  # `get_book_summary_by_currency?currency=SOL` answers an empty list; the same
  # legs are under `currency=USDC` with `base_currency=SOL`. Remap the wire
  # currency so `fetch_option_chain("SOL")` reaches that book. Parse still sees
  # the original unified params and filters to the requested underlying.

  alias Bourse.Exchange

  @settlement_currencies MapSet.new(~w(BTC ETH USDC USDT EURR))

  @doc false
  @spec build(map(), String.t(), Exchange.t(), keyword()) :: map()
  def build(params, "fetchOptionChain", %Exchange{}, _opts) when is_map(params) do
    remap_option_chain_currency(params)
  end

  def build(params, _js_name, _exchange, _opts), do: params

  @doc """
  The option-chain underlying a caller asked for, as an upper-case currency code.

  `currency`/`code` are the explicit selectors and win over `symbol`; a symbol is
  reduced to its base so an instrument symbol (the REST-read contract's
  `market_symbol` argument) names the same underlying a bare code does.
  """
  @spec option_chain_underlying(map()) :: String.t() | nil
  def option_chain_underlying(params) when is_map(params) do
    case params["currency"] || params["code"] || params["symbol"] do
      value when is_binary(value) and value != "" -> base_currency(value)
      _missing -> nil
    end
  end

  @doc "Whether `code` is a currency Deribit settles an option book under."
  @spec settlement_currency?(String.t()) :: boolean()
  def settlement_currency?(code) when is_binary(code) do
    MapSet.member?(@settlement_currencies, String.upcase(code))
  end

  defp remap_option_chain_currency(params) do
    case option_chain_underlying(params) do
      currency when is_binary(currency) ->
        if settlement_currency?(currency), do: params, else: Map.put(params, "currency", "USDC")

      _missing ->
        params
    end
  end

  # "BTC/USD:BTC-260829-70000-C" and "SOL" both name their base currency.
  defp base_currency(value) do
    value
    |> String.upcase()
    |> String.split(["/", ":", "-"], parts: 2)
    |> hd()
  end
end
