defmodule Bourse.WS.Subscription.JsonRpc do
  @moduledoc """
  Deribit-style JSON-RPC 2.0 subscribe frame.

      %{
        "jsonrpc" => "2.0",
        "method"  => "public/subscribe",
        "params"  => %{"channels" => ["ticker.BTC-PERPETUAL"]},
        "id"      => 1
      }

  The `id` field carries a correlation integer that `ZenWebsocket.Client`
  uses to route the response back to the caller. Callers may inject an id
  via `config[:id]`; otherwise a fresh monotonic integer is generated.

  Config keys:
  - `:method` (default `"public/subscribe"` for subscribe, `"public/unsubscribe"`
    for unsubscribe) — set to `"private/subscribe"` for authenticated streams
  - `:id` — explicit correlation id (optional)
  """

  @behaviour Bourse.WS.Subscription.Behaviour

  @impl true
  def subscribe(channels, config) when is_list(channels) do
    method = Map.get(config, :method, "public/subscribe")
    build(channels, config, method)
  end

  @impl true
  def unsubscribe(channels, config) when is_list(channels) do
    method =
      case Map.get(config, :method, "public/subscribe") do
        "public/subscribe" -> "public/unsubscribe"
        "private/subscribe" -> "private/unsubscribe"
        other -> String.replace(other, "subscribe", "unsubscribe")
      end

    build(channels, config, method)
  end

  defp build(channels, config, method) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => %{"channels" => channels},
      "id" => Map.get(config, :id) || System.unique_integer([:positive, :monotonic])
    }
  end
end
