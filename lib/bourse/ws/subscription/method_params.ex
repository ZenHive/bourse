defmodule Bourse.WS.Subscription.MethodParams do
  @moduledoc """
  Kraken v2 / Crypto.com / Derive-style subscribe frame.

  Accepts two caller conventions per channel list:

  1. **Plain strings** — channels are grouped under
     `params.<channel_key>` (default key `"channel"`).

         MethodParams.subscribe(["ticker", "book"], %{})
         # => %{"method" => "subscribe", "params" => %{"channel" => ["ticker", "book"]}}

  2. **Single pre-shaped map** — the caller supplies the `params` object
     directly (Kraken v2 expects `{"channel": "ticker", "symbol": [...]}`).

         MethodParams.subscribe([%{"channel" => "ticker", "symbol" => ["BTC/USD"]}], %{})
         # => %{"method" => "subscribe",
         #      "params" => %{"channel" => "ticker", "symbol" => ["BTC/USD"]}}

  Multiple maps per call return `{:error, :multiple_maps_not_supported}`;
  lists that mix maps and strings return `{:error, :mixed_channel_types}`.
  Both errors propagate verbatim through `Bourse.WS.Subscription.build_subscribe/3`.

  Config keys:
  - `:op_field` — default `"method"`
  - `:args_field` — default `"params"`
  - `:channel_key` — default `"channel"` (string-channel branch only)
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

  defp build([%{} = params_map], config, action) do
    method = Map.get(config, :op_field, "method")
    params = Map.get(config, :args_field, "params")

    %{method => action, params => params_map}
  end

  defp build(channels, config, action) when is_list(channels) do
    Bourse.WS.Subscription.Behaviour.build_single_envelope(channels, config, action, &build_string_frame/3)
  end

  defp build_string_frame(channels, config, action) do
    method = Map.get(config, :op_field, "method")
    params = Map.get(config, :args_field, "params")
    channel_key = Map.get(config, :channel_key, "channel")

    %{method => action, params => %{channel_key => channels}}
  end
end
