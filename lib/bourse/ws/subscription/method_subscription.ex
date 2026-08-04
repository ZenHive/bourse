defmodule Bourse.WS.Subscription.MethodSubscription do
  @moduledoc """
  Hyperliquid-style subscribe frame.

      %{"method" => "subscribe", "subscription" => %{"type" => "allMids"}}

  Accepts two caller conventions per channel list (same dual-shape contract as
  `MethodParams` / `EventSubscribe`):

  1. **Plain strings** — each string becomes the nested subscription's `"type"`.
     Hyperliquid accepts one subscription object per frame; when multiple
     strings are supplied the first is used (matches prior single-type behavior).

         MethodSubscription.subscribe(["allMids"], %{})
         # => %{"method" => "subscribe", "subscription" => %{"type" => "allMids"}}

  2. **Single pre-shaped map** — used as the `subscription` object directly
     (e.g. `%{"type" => "l2Book", "coin" => "BTC"}`). Passing a map into the
     string branch previously double-wrapped to
     `%{"type" => %{"type" => "allMids"}}` and the venue rejected the frame.

         MethodSubscription.subscribe([%{"type" => "allMids"}], %{})
         # => %{"method" => "subscribe", "subscription" => %{"type" => "allMids"}}

  Multiple maps per call return `{:error, :multiple_maps_not_supported}`;
  lists that mix maps and strings return `{:error, :mixed_channel_types}`.

  Config keys: `:op_field` (default `"method"`), `:args_field`
  (default `"subscription"`).
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

  defp build([%{} = subscription_map], config, action) do
    method = Map.get(config, :op_field, "method")
    subscription = Map.get(config, :args_field, "subscription")
    %{method => action, subscription => subscription_map}
  end

  defp build(channels, config, action) when is_list(channels) do
    case Bourse.WS.Subscription.Behaviour.classify_channel_list(channels) do
      :strings -> build_string_frame(channels, config, action)
      :all_maps -> {:error, :multiple_maps_not_supported}
      :mixed -> {:error, :mixed_channel_types}
    end
  end

  defp build_string_frame(channels, config, action) do
    method = Map.get(config, :op_field, "method")
    subscription = Map.get(config, :args_field, "subscription")
    type = List.first(channels) || ""

    %{method => action, subscription => %{"type" => type}}
  end
end
