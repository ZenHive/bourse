defmodule Bourse.WS.Subscription.Behaviour do
  @moduledoc """
  Behaviour for WebSocket subscription pattern implementations.

  Each pattern module converts a list of pre-formatted channel strings (or
  per-pattern objects) into the exchange-native subscribe frame. Frame
  encoding (Jason) happens at the WS boundary in `Bourse.WS.subscribe/3`, not
  inside pattern modules — modules return plain maps.

  ## Return shape

  `subscribe/2` and `unsubscribe/2` return `map() | [map()] | {:error, term()}`.

  - Most exchanges accept an array of channels in a single frame → return a
    `map()`.
  - HTX (`:sub_subscribe`) requires one frame per channel → return a
    `[map()]` with one frame per channel.
  - Upbit-style custom (`config[:custom_type] == "array_format"`) also
    returns a `[map()]`.
  - Implementations that enforce an input-shape contract may return
    `{:error, term()}` (e.g. `:multiple_maps_not_supported` or
    `:mixed_channel_types` from `EventSubscribe` / `MethodParams`).
    `Bourse.WS.Subscription.build_subscribe/3` passes these through to the
    caller verbatim rather than wrapping them in `{:ok, _}`.

  `Bourse.WS.subscribe/3` handles both frame shapes by iterating the list
  when present and sending one `ZenWebsocket.Client.send_message/2` per
  frame.

  ## Channel formatting is the caller's responsibility

  Pattern modules do **not** format channel strings from unified symbols.
  Callers pass pre-formatted channels like `"tickers.BTCUSDT"` or
  `"market.btcusdt.ticker"`. A future task may introduce spec-driven
  channel templates; this behaviour is deliberately narrow.

  ## Implementing a Pattern

      defmodule Bourse.WS.Subscription.OpSubscribe do
        @behaviour Bourse.WS.Subscription.Behaviour

        @impl true
        def subscribe(channels, config) do
          %{
            (config[:op_field] || "op") => "subscribe",
            (config[:args_field] || "args") => channels
          }
        end

        @impl true
        def unsubscribe(channels, config) do
          %{
            (config[:op_field] || "op") => "unsubscribe",
            (config[:args_field] || "args") => channels
          }
        end
      end
  """

  @type channel :: String.t() | map()
  @type config :: map()
  @type frame :: map()
  @type channel_shape_error :: :multiple_maps_not_supported | :mixed_channel_types

  @callback subscribe(channels :: [channel()], config :: config()) ::
              frame() | [frame()] | {:error, term()}
  @callback unsubscribe(channels :: [channel()], config :: config()) ::
              frame() | [frame()] | {:error, term()}

  @optional_callbacks [unsubscribe: 2]

  @doc """
  Builds a single-envelope frame after validating channel-list shape.

  Pattern modules pass their string-channel frame builder. Map-only and mixed
  channel lists return the shared error atoms used by the dispatcher tests.
  """
  @spec build_single_envelope(
          [channel()],
          config(),
          String.t(),
          ([channel()], config(), String.t() -> frame())
        ) :: frame() | {:error, channel_shape_error()}
  def build_single_envelope(channels, config, action, string_builder)
      when is_list(channels) and is_function(string_builder, 3) do
    case classify_channel_list(channels) do
      :strings -> string_builder.(channels, config, action)
      :all_maps -> {:error, :multiple_maps_not_supported}
      :mixed -> {:error, :mixed_channel_types}
    end
  end

  @doc """
  Classifies a channel list by element shape.

  Empty lists classify as `:strings`, preserving the default-frame behavior in
  single-envelope pattern modules.
  """
  @spec classify_channel_list([channel()]) :: :strings | :all_maps | :mixed
  def classify_channel_list(channels) when is_list(channels) do
    cond do
      Enum.all?(channels, &is_binary/1) -> :strings
      Enum.all?(channels, &is_map/1) -> :all_maps
      true -> :mixed
    end
  end
end
