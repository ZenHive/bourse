defmodule Bourse.WS.Subscription.MethodSubscribe do
  @moduledoc """
  Binance/XT/Aster-style subscribe frame.

      %{"method" => "SUBSCRIBE", "params" => ["btcusdt@ticker", "btcusdt@depth"]}

  Config keys: `:op_field` (default `"method"`), `:args_field`
  (default `"params"`). Action strings are upper-case per Binance convention.
  """

  @behaviour Bourse.WS.Subscription.Behaviour

  @impl true
  def subscribe(channels, config) when is_list(channels) do
    build(channels, config, "SUBSCRIBE")
  end

  @impl true
  def unsubscribe(channels, config) when is_list(channels) do
    build(channels, config, "UNSUBSCRIBE")
  end

  defp build(channels, config, action) do
    method = Map.get(config, :op_field, "method")
    params = Map.get(config, :args_field, "params")
    %{method => action, params => channels}
  end
end
