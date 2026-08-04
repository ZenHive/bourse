defmodule Bourse.WS.Semantics.Trades do
  @moduledoc """
  Trades cache driven by `websocket.trades_semantics`.
  """

  alias Bourse.Exchange

  @type t :: %__MODULE__{
          update_model: String.t(),
          cache_type: String.t() | nil,
          dedup_key: String.t() | nil,
          caches: %{String.t() => [map()]}
        }

  defstruct update_model: "append",
            cache_type: nil,
            dedup_key: nil,
            caches: %{}

  @doc "Builds state from exchange spec semantics."
  @spec new(Exchange.t()) :: t()
  def new(%Exchange{spec: spec}) do
    semantics = get_in(spec, ["websocket", "trades_semantics"]) || %{}

    %__MODULE__{
      update_model: Map.get(semantics, "update_model", "append"),
      cache_type: Map.get(semantics, "cache_type"),
      dedup_key: Map.get(semantics, "dedup_key")
    }
  end

  @doc "Applies a routed trades payload and returns updated state + emitted trades."
  @spec apply(t(), String.t(), term()) :: {t(), [map()]}
  def apply(%__MODULE__{} = state, key, payload) when is_binary(key) do
    trades = normalize_trades(payload)
    existing = Map.get(state.caches, key, [])

    updated =
      case state.update_model do
        "replace" -> trades
        _ -> append_trades(existing, trades, state.dedup_key)
      end

    {%{state | caches: Map.put(state.caches, key, updated)}, trades}
  end

  defp normalize_trades(payload) when is_list(payload), do: Enum.filter(payload, &is_map/1)
  defp normalize_trades(payload) when is_map(payload), do: [payload]
  defp normalize_trades(_), do: []

  defp append_trades(existing, trades, dedup_key) do
    Enum.reduce(trades, existing, fn trade, acc -> append_trade(acc, trade, dedup_key) end)
  end

  defp append_trade(acc, trade, dedup_key) when is_map(trade) and is_binary(dedup_key) do
    key = Map.get(trade, dedup_key)

    if key && Enum.any?(acc, &(Map.get(&1, dedup_key) == key)) do
      acc
    else
      acc ++ [trade]
    end
  end

  defp append_trade(acc, trade, _dedup_key), do: acc ++ [trade]
end
