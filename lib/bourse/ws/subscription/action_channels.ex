defmodule Bourse.WS.Subscription.ActionChannels do
  @moduledoc """
  Alpaca-style action frame whose channel names are top-level keys.

  Pre-formatted channels use `channel:symbol`, for example
  `trades:FAKEPACA`. Channels with the same name are grouped into one list.
  """

  @behaviour Bourse.WS.Subscription.Behaviour

  @impl true
  @spec subscribe([String.t() | map()], map()) :: map() | {:error, term()}
  def subscribe(channels, _config) when is_list(channels), do: build(channels, "subscribe")

  @impl true
  @spec unsubscribe([String.t() | map()], map()) :: map() | {:error, term()}
  def unsubscribe(channels, _config) when is_list(channels), do: build(channels, "unsubscribe")

  defp build(channels, action) do
    Enum.reduce_while(channels, %{"action" => action}, fn channel, frame ->
      case split_channel(channel) do
        {:ok, name, symbol} -> {:cont, Map.update(frame, name, [symbol], &(&1 ++ [symbol]))}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp split_channel(channel) when is_binary(channel) do
    case String.split(channel, ":", parts: 2) do
      [name, symbol] when name != "" and symbol != "" -> {:ok, name, symbol}
      _ -> {:error, {:invalid_channel, channel}}
    end
  end

  defp split_channel(channel), do: {:error, {:invalid_channel, channel}}
end
