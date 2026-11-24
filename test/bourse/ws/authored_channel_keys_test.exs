defmodule Bourse.WS.AuthoredChannelKeysTest do
  @moduledoc """
  Every authored `websocket.subscribe.channels` key must be one
  `Bourse.WS.Channels` actually reads and that the venue can send.

  A key outside that set is a claim about a venue channel that no client call
  can subscribe to, so no live lane can ever prove it. The documents are read
  from disk, so adding such a key fails here before anything else.
  """

  use ExUnit.Case, async: true

  alias Bourse.Spec
  alias Bourse.WS.Channels
  alias Bourse.WS.Config

  # Derive's channel map is being re-authored for its v3 host in separate work.
  # Its one undispatchable key is pinned exactly, so this goes red both when
  # another key appears and when the re-authoring removes this one.
  @pinned_undispatchable %{"derive" => ["watchMyTrades"]}

  test "every runtime venue authors only channel keys the client dispatches" do
    offenders =
      for venue <- Spec.exchanges(),
          undispatchable = undispatchable_keys(venue),
          undispatchable != Map.get(@pinned_undispatchable, venue, []),
          into: %{},
          do: {venue, undispatchable}

    assert offenders == %{},
           "authored websocket.subscribe.channels keys no watch method reads " <>
             "(venue => keys): #{inspect(offenders)}. " <>
             "Delete them, or add the dispatching watch_* method first."
  end

  test "no authored channel template is a message-hash shape instead of a provider channel" do
    hashes =
      for venue <- Spec.exchanges(),
          {key, templates} <- channels(Spec.load!(venue)),
          is_list(templates),
          template <- templates,
          is_binary(template),
          message_hash?(template),
          do: {venue, key, template}

    assert hashes == []
  end

  test "the pinned exception names only runtime venues" do
    assert Enum.all?(Map.keys(@pinned_undispatchable), &(&1 in Spec.exchanges()))
  end

  defp undispatchable_keys(venue) do
    spec = Spec.load!(venue)
    authored = spec |> channels() |> Map.keys() |> MapSet.new()
    readable = readable_keys(venue, authored)

    authored |> MapSet.difference(readable) |> Enum.sort()
  end

  defp readable_keys(venue, authored) do
    private_section? = private_section?(venue)

    for {method, primary, fallbacks} <- Channels.dispatch_keys(),
        private_section? or not Channels.private?(method),
        key <- if(primary in authored, do: [primary], else: fallbacks),
        into: MapSet.new(),
        do: key
  end

  # A private watch method is sent only on a `:private` connection; a venue
  # without a private WS URL in either environment can never open one.
  defp private_section?(venue) do
    config = Config.for_exchange(venue) || %{}
    is_binary(config[:private_url]) or is_binary(config[:private_url_sandbox])
  end

  defp channels(spec), do: get_in(spec, ["websocket", "subscribe", "channels"]) || %{}

  # Leading-separator and doubled-separator shapes (`:{symbol}`, `.{symbol}`,
  # `trade::{symbol}`) are client-side routing keys, never a provider channel.
  defp message_hash?(template) do
    String.starts_with?(template, [":", "."]) or String.contains?(template, ["::", ".."])
  end
end
