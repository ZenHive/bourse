defmodule Bourse.WS.Semantics.Ohlcv do
  @moduledoc """
  OHLCV cache driven by `websocket.ohlcv_semantics`.
  """

  alias Bourse.Exchange

  @type t :: %__MODULE__{
          update_model: String.t(),
          cache_type: String.t() | nil,
          closed_signal: String.t() | nil,
          timeframe_key: String.t() | nil,
          caches: %{String.t() => map() | nil}
        }

  defstruct update_model: "replace",
            cache_type: nil,
            closed_signal: nil,
            timeframe_key: nil,
            caches: %{}

  @doc "Builds state from exchange spec semantics."
  @spec new(Exchange.t()) :: t()
  def new(%Exchange{spec: spec}) do
    semantics = get_in(spec, ["websocket", "ohlcv_semantics"]) || %{}

    %__MODULE__{
      update_model: Map.get(semantics, "update_model", "replace"),
      cache_type: Map.get(semantics, "cache_type"),
      closed_signal: Map.get(semantics, "closed_signal"),
      timeframe_key: Map.get(semantics, "timeframe_key")
    }
  end

  @doc "Applies a routed OHLCV payload and returns updated state + candle."
  @spec apply(t(), String.t(), term()) :: {t(), map() | nil}
  def apply(%__MODULE__{} = state, key, payload) when is_binary(key) do
    candle = normalize_candle(payload)

    updated =
      case state.update_model do
        "append" ->
          case Map.get(state.caches, key) do
            nil -> candle
            existing when is_map(existing) -> merge_candle(existing, candle)
            _ -> candle
          end

        _ ->
          candle
      end

    {%{state | caches: Map.put(state.caches, key, updated)}, candle}
  end

  defp normalize_candle(payload) when is_map(payload), do: payload
  defp normalize_candle([head | _]) when is_map(head), do: head
  defp normalize_candle(_), do: nil

  defp merge_candle(existing, nil), do: existing
  defp merge_candle(_existing, candle), do: candle
end
