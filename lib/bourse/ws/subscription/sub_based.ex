defmodule Bourse.WS.Subscription.SubBased do
  @moduledoc """
  HTX/Huobi-style subscribe frame.

      %{"sub" => "market.btcusdt.ticker"}

  HTX requires **one subscribe frame per channel** — `subscribe/2` returns
  a `[map()]` with one entry per channel (or an empty list for an empty
  input). `Bourse.WS.subscribe/3` handles both single-map and list returns.

  Frames intentionally omit an `"id"` field. zen_websocket's
  `RequestCorrelator.extract_id/1` (deps/zen_websocket) treats any outbound
  frame with a non-nil `"id"` as a JSON-RPC request and parks the caller in
  a `GenServer.call` pending a correlated reply; HTX's subscribe ack is
  fire-and-forget and does not round-trip through the correlator, so a
  present `id` field hangs the caller until the default request timeout.
  Omitting it restores immediate `:ok` return from `Bourse.WS.subscribe/3`.

  Config keys:
  - `:op_field` — default `"sub"`; the unsubscribe frame swaps to `"unsub"`
    automatically (overridable via `:unsub_field`)
  """

  @behaviour Bourse.WS.Subscription.Behaviour

  @impl true
  def subscribe(channels, config) when is_list(channels) do
    build_frames(channels, Map.get(config, :op_field, "sub"))
  end

  @impl true
  def unsubscribe(channels, config) when is_list(channels) do
    build_frames(channels, Map.get(config, :unsub_field, "unsub"))
  end

  defp build_frames(channels, field) do
    Enum.map(channels, fn channel -> %{field => channel} end)
  end
end
