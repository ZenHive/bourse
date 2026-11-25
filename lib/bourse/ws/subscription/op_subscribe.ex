defmodule Bourse.WS.Subscription.OpSubscribe do
  @moduledoc """
  Bybit/Bitmex-style subscribe frame.

      %{"op" => "subscribe", "args" => ["tickers.BTCUSDT", "orderbook.50.BTCUSDT"]}

  Config keys: `:op_field` (default `"op"`), `:args_field` (default `"args"`),
  and `:request_id_field` with `:request_id` — when both are set the frame
  carries the id, as a string, that the venue echoes in its reply.
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
    Bourse.WS.Subscription.Behaviour.put_request_id(%{op => action, args => channels}, config, &to_string/1)
  end
end
