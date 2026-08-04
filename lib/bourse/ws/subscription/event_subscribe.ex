defmodule Bourse.WS.Subscription.EventSubscribe do
  @moduledoc """
  Gate/Bitfinex/Bitget-style subscribe frame keyed on an `"event"` field.

  Accepts two caller conventions per channel list:

  1. **Plain strings** — the pattern owns envelope construction.

         # Gate-style (list payload)
         EventSubscribe.subscribe(["BTC_USDT"], %{channel_field: "channel", channel_value: "spot.tickers"})
         # => %{"event" => "subscribe", "channel" => "spot.tickers", "payload" => ["BTC_USDT"]}

         # Bitfinex-style (single string under args_field)
         EventSubscribe.subscribe(["tBTCUSD"],
           %{args_field: "symbol", args_format: :string,
             channel_field: "channel", channel_value: "ticker"})
         # => %{"event" => "subscribe", "channel" => "ticker", "symbol" => "tBTCUSD"}

  2. **Single pre-shaped map** — the caller supplies the per-subscribe fields
     directly; they are spread alongside `"event" => "subscribe"`. Used by
     callers that already know the exchange-native shape (bitfinex with
     `%{"channel" => "ticker", "symbol" => "tBTCUSD"}`, gate with
     `%{"channel" => "spot.tickers", "payload" => ["BTC_USDT"]}`).

         EventSubscribe.subscribe([%{"channel" => "ticker", "symbol" => "tBTCUSD"}], %{})
         # => %{"event" => "subscribe", "channel" => "ticker", "symbol" => "tBTCUSD"}

  Multiple maps per call are not supported for this single-envelope pattern —
  `subscribe/2` returns `{:error, :multiple_maps_not_supported}` in that case.
  Lists that mix maps and strings return `{:error, :mixed_channel_types}`
  (also rejected, since silently shipping a heterogeneous payload was the
  exact failure mode T98/T99 set out to fix).

  Config keys (string-channel branch only):
  - `:op_field` — default `"event"`
  - `:args_field` — default `"payload"`; set to `"symbol"` for Bitfinex-style
  - `:args_format` — `:string` for single-channel, `:object_list` for
    object payloads, otherwise (default) an array of strings
  - `:channel_field` — extra field carrying the channel name; its value
    comes from `config[:channel_value]`.
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

  defp build([%{} = channel_map], config, action) do
    event = Map.get(config, :op_field, "event")
    Map.put(channel_map, event, action)
  end

  defp build(channels, config, action) when is_list(channels) do
    Bourse.WS.Subscription.Behaviour.build_single_envelope(channels, config, action, &build_string_frame/3)
  end

  defp build_string_frame(channels, config, action) do
    event = Map.get(config, :op_field, "event")
    args = Map.get(config, :args_field, "payload")

    %{event => action}
    |> maybe_put_channel_field(config)
    |> Map.put(args, args_value(channels, config))
  end

  defp args_value(channels, config) do
    case Map.get(config, :args_format) do
      :string -> List.first(channels) || ""
      :object_list -> channels
      _ -> channels
    end
  end

  defp maybe_put_channel_field(map, config) do
    case {Map.get(config, :channel_field), Map.get(config, :channel_value)} do
      {nil, _} -> map
      {field, nil} -> Map.put(map, field, "")
      {field, value} -> Map.put(map, field, value)
    end
  end
end
