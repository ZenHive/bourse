defmodule Bourse.WS.Subscription.Custom do
  @moduledoc """
  Escape hatch for exchanges whose subscribe frames don't fit any named
  pattern. The module dispatches on `config[:custom_type]`:

  | custom_type        | Exchange            | Shape                                     |
  |--------------------|---------------------|-------------------------------------------|
  | `"array_format"`   | Upbit               | `[[%{type, codes}, ...]]` — array of maps |
  | `"sendTopicAction"`| Deepcoin            | Nested `sendTopicAction` envelope         |
  | _(default)_        | — fallback          | `%{"subscribe" => true, "channels" => […]}` |

  `subscribe/2` for Upbit returns a `[map()]` (one envelope per channel);
  all others return a single `map()`. Callers must pass `config[:custom_type]`
  explicitly — no WS-configured exchange wires this pattern in T94 (custom
  DEX exchanges like Hyperliquid/Derive/Lighter are deferred).
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
    case Map.get(config, :custom_type) do
      "array_format" -> build_array_format(channels, action)
      "sendTopicAction" -> build_send_topic_action(channels, action)
      _ -> build_default(channels, action)
    end
  end

  # Upbit-style: one envelope per channel.
  defp build_array_format(channels, "subscribe") do
    Enum.map(channels, fn channel -> %{"type" => "ticker", "codes" => [channel]} end)
  end

  defp build_array_format(channels, "unsubscribe") do
    Enum.map(channels, fn channel ->
      %{"type" => "ticker", "codes" => [channel], "isOnlyRealtime" => true}
    end)
  end

  defp build_send_topic_action(channels, action) do
    %{"sendTopicAction" => %{"action" => action, "topics" => channels}}
  end

  defp build_default(channels, "subscribe"), do: %{"subscribe" => true, "channels" => channels}
  defp build_default(channels, "unsubscribe"), do: %{"unsubscribe" => true, "channels" => channels}
end
