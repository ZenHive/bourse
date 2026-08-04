defmodule Bourse.WS.Subscription.OpSubscribeObjects do
  @moduledoc """
  OKX-style subscribe frame with object-valued args.

      %{
        "op" => "subscribe",
        "args" => [
          %{"channel" => "tickers", "instId" => "BTC-USDT"},
          %{"channel" => "books",   "instId" => "BTC-USDT"}
        ]
      }

  Callers pass pre-built channel objects (maps). Same frame shape as
  `OpSubscribe`; the difference is that `args` contains maps instead of
  strings. Config keys: `:op_field` (default `"op"`), `:args_field`
  (default `"args"`).
  """

  @behaviour Bourse.WS.Subscription.Behaviour

  @impl true
  def subscribe(channels, config) when is_list(channels) do
    build(channels, config, "subscribe")
  end

  @impl true
  def unsubscribe(channels, config) when is_list(channels) do
    build(channels, config, "unsubscribe")
  end

  defp build(channels, config, action) do
    op = Map.get(config, :op_field, "op")
    args = Map.get(config, :args_field, "args")
    %{op => action, args => Enum.map(channels, &coerce_object/1)}
  end

  # Strings are tolerated for callers that prefer the plain form —
  # coerced to `%{"channel" => str}` so OKX accepts the frame.
  defp coerce_object(%{} = object), do: object
  defp coerce_object(channel) when is_binary(channel), do: %{"channel" => channel}
end
