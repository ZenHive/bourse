defmodule Bourse.WS.Subscription.TypeSubscribe do
  @moduledoc """
  KuCoin/Coinbase-style subscribe frame keyed on a `"type"` field.

  KuCoin single-topic form:

      %{"type" => "subscribe", "topic" => "/market/ticker:BTC-USDT"}

  Coinbase dual-field form:

      %{
        "type"         => "subscribe",
        "product_ids"  => ["BTC-USD", "ETH-USD"],
        "channels"     => ["matches"]
      }

  The dual-field form is selected by setting `config[:channels_field]` to
  `"channels"` (or similar); in that case `args_field` receives the market
  id list and `channels_field` receives the channel name (wrapped in a
  single-element list when the field is literally `"channels"`, otherwise
  bare).

  Config keys:
  - `:op_field` — default `"type"`
  - `:args_field` — default `"topic"`; Coinbase sets `"product_ids"`
  - `:args_format` — `:string` (KuCoin default) or `:string_list` for arrays
  - `:channels_field` — when set, activates the dual-field shape
  - `:channel_name` — the channel name placed under `channels_field`
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
    type = Map.get(config, :op_field, "type")
    args = Map.get(config, :args_field, "topic")
    base = %{type => action}

    case Map.get(config, :channels_field) do
      nil -> Map.put(base, args, single_or_list(channels, config))
      channels_field -> put_dual_field(base, args, channels, channels_field, config)
    end
  end

  defp single_or_list(channels, config) do
    case Map.get(config, :args_format, :string) do
      :string -> List.first(channels) || ""
      _ -> channels
    end
  end

  defp put_dual_field(base, args_field, channels, channels_field, config) do
    channel_name = Map.get(config, :channel_name)

    base
    |> Map.put(args_field, channels)
    |> Map.put(channels_field, wrap_channel_name(channels_field, channel_name))
  end

  defp wrap_channel_name("channels", nil), do: []
  defp wrap_channel_name("channels", name) when is_binary(name), do: [name]
  defp wrap_channel_name(_field, nil), do: ""
  defp wrap_channel_name(_field, name), do: name
end
