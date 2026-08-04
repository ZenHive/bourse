defmodule Bourse.WS.Dispatch do
  @moduledoc """
  Spec-driven channel → handler resolution from `websocket.dispatch.entries`.
  """

  alias Bourse.Exchange
  alias Bourse.WS.Envelope
  alias Bourse.WS.HandlerMappings

  @type resolve_result :: {:family, atom()} | :system | :not_found

  @doc "Resolves a channel name to a watch family using spec dispatch entries."
  @spec resolve_channel(Exchange.t(), String.t()) :: resolve_result()
  def resolve_channel(%Exchange{} = exchange, channel_name) when is_binary(channel_name) do
    dispatch = get_in(exchange.spec, ["websocket", "dispatch"]) || %{}
    entries = Map.get(dispatch, "entries", [])
    envelope = Envelope.for_exchange(exchange)
    match_type = Envelope.match_type(envelope)
    prefix_channels = Envelope.prefix_channels(envelope)

    case find_handler(entries, channel_name, match_type, prefix_channels) do
      nil -> :not_found
      handler -> HandlerMappings.resolve_handler(handler)
    end
  end

  @doc "Returns dispatch entries from the exchange spec."
  @spec entries(Exchange.t()) :: [map()]
  def entries(%Exchange{spec: spec}) do
    case get_in(spec, ["websocket", "dispatch", "entries"]) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  defp find_handler(entries, channel_name, match_type, prefix_channels) do
    exact = Enum.find(entries, fn entry -> Map.get(entry, "channel") == channel_name end)

    if exact do
      Map.get(exact, "handler")
    else
      match_type
      |> fallback_match(entries, channel_name)
      |> Kernel.||(prefix_match(entries, channel_name, prefix_channels))
    end
  end

  defp fallback_match("exact_then_substring", entries, channel_name) do
    substring_match(entries, channel_name) || split_match(entries, channel_name)
  end

  defp fallback_match("split", entries, channel_name), do: split_match(entries, channel_name)
  defp fallback_match(_exact, _entries, _channel_name), do: nil

  defp substring_match(entries, channel_name) do
    match =
      Enum.find(entries, fn entry ->
        channel = Map.get(entry, "channel", "")
        channel != "" and String.contains?(channel_name, channel)
      end)

    if match, do: Map.get(match, "handler")
  end

  defp split_match(entries, channel_name) do
    parts = String.split(channel_name, ".")

    match =
      Enum.find_value(parts, fn part ->
        Enum.find(entries, fn entry -> Map.get(entry, "channel") == part end)
      end)

    if match, do: Map.get(match, "handler")
  end

  defp prefix_match(entries, channel_name, prefix_channels) do
    prefixes =
      prefix_channels
      |> Enum.map(fn prefix ->
        Enum.find(entries, fn entry -> Map.get(entry, "channel") == prefix end)
      end)
      |> Enum.reject(&is_nil/1)

    match =
      Enum.find(prefixes, fn entry ->
        prefix = Map.get(entry, "channel", "")
        prefix != "" and String.starts_with?(channel_name, prefix)
      end)

    if match, do: Map.get(match, "handler")
  end
end
