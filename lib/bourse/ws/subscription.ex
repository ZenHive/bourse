defmodule Bourse.WS.Subscription do
  @moduledoc """
  WebSocket subscription pattern dispatcher.

  Parallel of `Bourse.WS.Auth`: a function-head dispatcher that routes a
  pattern atom to the matching per-pattern module. Each pattern module
  implements the `Bourse.WS.Subscription.Behaviour` callbacks.

  ## Supported Patterns

  | Pattern atom                  | Exchanges                                 | Frame shape                                      |
  |-------------------------------|-------------------------------------------|--------------------------------------------------|
  | `:op_subscribe`               | bybit, bitmex                             | `%{"op"=>"subscribe","args"=>[strings]}`         |
  | `:op_subscribe_objects`       | okx                                       | `%{"op"=>"subscribe","args"=>[objects]}`         |
  | `:method_subscribe`           | binance, xt, aster                        | `%{"method"=>"SUBSCRIBE","params"=>[strings]}`   |
  | `:method_params_subscribe`    | kraken, cryptocom, derive                 | `%{"method"=>"subscribe","params"=>%{"channel"=>[strings]}}` |
  | `:method_subscription`        | hyperliquid                               | `%{"method"=>"subscribe","subscription"=>%{"type"=>…}}` |
  | `:jsonrpc_subscribe`          | deribit                                   | JSON-RPC 2.0 envelope with correlation id        |
  | `:event_subscribe`            | gate, bitfinex, woo, bitrue               | `%{"event"=>"subscribe","channel"=>…}` variants  |
  | `:type_subscribe`             | kucoin, coinbaseexchange                  | `%{"type"=>"subscribe","topic"=>…}` variants     |
  | `:sub_subscribe`              | htx, huobi                                | `%{"sub"=>…}` — **one frame per channel**, no `id` (see `SubBased` moduledoc) |
  | `:custom`                     | bithumb, upbit, deepcoin, … (escape hatch)| dispatches on `config[:custom_type]`             |

  Patterns for venues without a `WS.SpecConfig` hand base (e.g. method_topics /
  method_as_topic / reqtype_sub / action_subscribe) are not registered here —
  re-adding a venue re-vendors the shape deliberately from git history or
  `ccxt_client_bak`.

  ## Return shape

  `build_subscribe/3` returns `{:ok, frame_or_frames}` where
  `frame_or_frames` is `map() | [map()]`. Single-frame exchanges return a
  map; multi-frame exchanges (HTX, Upbit-custom) return a list.

  Pattern modules may also surface input-shape rejections as
  `{:error, term()}` (e.g. `:multiple_maps_not_supported` /
  `:mixed_channel_types` from `:event_subscribe` and
  `:method_params_subscribe` when callers mix shapes). The dispatcher
  passes those tuples through verbatim — it never wraps them in `{:ok, _}`.

  Unknown patterns return `{:error, {:unknown_pattern, atom}}` — matches
  `Bourse.WS.Auth`'s dispatcher-head behavior.
  """

  alias Bourse.WS.Subscription.Custom
  alias Bourse.WS.Subscription.EventSubscribe
  alias Bourse.WS.Subscription.JsonRpc
  alias Bourse.WS.Subscription.MethodParams
  alias Bourse.WS.Subscription.MethodSubscribe
  alias Bourse.WS.Subscription.MethodSubscription
  alias Bourse.WS.Subscription.OpSubscribe
  alias Bourse.WS.Subscription.OpSubscribeObjects
  alias Bourse.WS.Subscription.SubBased
  alias Bourse.WS.Subscription.TypeSubscribe

  @type pattern ::
          :op_subscribe
          | :op_subscribe_objects
          | :method_subscribe
          | :method_params_subscribe
          | :method_subscription
          | :jsonrpc_subscribe
          | :event_subscribe
          | :type_subscribe
          | :sub_subscribe
          | :custom

  @type channel :: String.t() | map()
  @type config :: map()
  @type frame :: map()
  @type build_result :: {:ok, frame() | [frame()]} | {:error, term()}

  @patterns [
    :op_subscribe,
    :op_subscribe_objects,
    :method_subscribe,
    :method_params_subscribe,
    :method_subscription,
    :jsonrpc_subscribe,
    :event_subscribe,
    :type_subscribe,
    :sub_subscribe,
    :custom
  ]

  @doc "Lists every supported subscription pattern atom."
  @spec patterns() :: [pattern()]
  def patterns, do: @patterns

  @doc "Returns the implementing module for a pattern, or `nil` if unknown."
  @spec module_for_pattern(pattern()) :: module() | nil
  def module_for_pattern(:op_subscribe), do: OpSubscribe
  def module_for_pattern(:op_subscribe_objects), do: OpSubscribeObjects
  def module_for_pattern(:method_subscribe), do: MethodSubscribe
  def module_for_pattern(:method_params_subscribe), do: MethodParams
  def module_for_pattern(:method_subscription), do: MethodSubscription
  def module_for_pattern(:jsonrpc_subscribe), do: JsonRpc
  def module_for_pattern(:event_subscribe), do: EventSubscribe
  def module_for_pattern(:type_subscribe), do: TypeSubscribe
  def module_for_pattern(:sub_subscribe), do: SubBased
  def module_for_pattern(:custom), do: Custom
  def module_for_pattern(_), do: nil

  @doc """
  Builds the subscribe frame(s) for the pattern and channel list.

  Returns `{:ok, map()}` for the common single-frame case, or
  `{:ok, [map()]}` for multi-frame exchanges (HTX, Upbit-custom).
  Callers should handle both shapes.
  """
  @spec build_subscribe(pattern(), [channel()], config()) :: build_result()
  def build_subscribe(pattern, channels, config) when is_list(channels) do
    case module_for_pattern(pattern) do
      nil -> {:error, {:unknown_pattern, pattern}}
      module -> wrap_pattern_result(module.subscribe(channels, config))
    end
  end

  @doc "Builds the unsubscribe frame(s) — same return shape as `build_subscribe/3`."
  @spec build_unsubscribe(pattern(), [channel()], config()) :: build_result()
  def build_unsubscribe(pattern, channels, config) when is_list(channels) do
    case module_for_pattern(pattern) do
      nil -> {:error, {:unknown_pattern, pattern}}
      module -> wrap_pattern_result(module.unsubscribe(channels, config))
    end
  end

  # Pattern modules may return `{:error, term()}` for input-shape rejections
  # (`:multiple_maps_not_supported`, `:mixed_channel_types`). Pass those
  # through unchanged; wrap everything else in `{:ok, _}`.
  defp wrap_pattern_result({:error, _} = err), do: err
  defp wrap_pattern_result(frame_or_frames), do: {:ok, frame_or_frames}
end
