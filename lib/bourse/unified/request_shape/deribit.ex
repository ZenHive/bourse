defmodule Bourse.Unified.RequestShape.Deribit do
  @moduledoc false

  # Deribit indexes altcoin option books under the USDC settlement currency.
  # `get_book_summary_by_currency?currency=SOL` answers an empty list; the same
  # legs are under `currency=USDC` with `base_currency=SOL`. Remap the wire
  # currency so `fetch_option_chain("SOL")` reaches that book. Parse still sees
  # the original unified symbol and filters to the requested underlying.

  alias Bourse.Exchange

  @settlement_currencies MapSet.new(~w(BTC ETH USDC USDT EURR))

  @doc false
  @spec build(map(), String.t(), Exchange.t(), keyword()) :: map()
  def build(params, "fetchOptionChain", %Exchange{}, _opts) when is_map(params) do
    remap_option_chain_currency(params)
  end

  def build(params, _js_name, _exchange, _opts), do: params

  defp remap_option_chain_currency(params) do
    case option_chain_currency(params) do
      currency when is_binary(currency) ->
        if settlement_currency?(currency) do
          params
        else
          Map.put(params, "currency", "USDC")
        end

      _missing ->
        params
    end
  end

  defp option_chain_currency(params) do
    case params["currency"] || params["code"] || params["symbol"] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp settlement_currency?(code) when is_binary(code) do
    MapSet.member?(@settlement_currencies, String.upcase(code))
  end
end
