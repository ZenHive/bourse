defmodule Bourse.WS.AuthoredChannelKeysTest do
  @moduledoc """
  Every authored `websocket.subscribe.channels` key must be one
  `Bourse.WS.Channels` actually reads and that the venue can send.

  A key outside that set is a claim about a venue channel that no client call
  can subscribe to, so no live lane can ever prove it. The documents are read
  from disk, so adding such a key fails here before anything else.
  """

  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Spec
  alias Bourse.WS.Channels
  alias Bourse.WS.Config

  test "every runtime venue authors only channel keys the client dispatches" do
    offenders =
      for venue <- Spec.exchanges(),
          undispatchable = undispatchable_keys(venue, venue |> Spec.load!() |> channels()),
          undispatchable != [],
          into: %{},
          do: {venue, undispatchable}

    assert offenders == %{},
           "authored websocket.subscribe.channels keys no watch method reads " <>
             "(venue => keys): #{inspect(offenders)}. " <>
             "Delete them, or add the dispatching watch_* method first."
  end

  test "no authored channel template is a message-hash shape instead of a provider channel" do
    hashes =
      for venue <- Spec.exchanges(), hash <- venue |> Spec.load!() |> channels() |> message_hashes(), do: {venue, hash}

    assert hashes == []
  end

  test "derive's account-scoped trade key is read by the private watch_my_trades" do
    assert {:watch_my_trades, "watchMyTrades", []} in Channels.dispatch_keys()
    assert Channels.private?(:watch_my_trades)
    assert private_section?("derive")
    assert "watchMyTrades" in readable_keys("derive", "derive" |> Spec.load!() |> channels())
  end

  describe "the guard mirrors what the builder reads" do
    test "an empty primary leaves its fallback readable, exactly as the builder resolves it" do
      exchange = Exchange.new!("bybit")
      authored = exchange.spec |> channels() |> Map.put("watchTrades", [])
      exchange = %{exchange | spec: put_in(exchange.spec, ~w(websocket subscribe channels), authored)}

      assert {:ok, "publicTrade.BTCUSDT"} = Channels.build(exchange, :watch_trades, %{symbol: "BTC/USDT"}, [])
      assert undispatchable_keys("bybit", authored) == ["watchTrades"]
    end

    test "a fallback behind a usable primary is unreadable" do
      authored = "bybit" |> Spec.load!() |> channels() |> Map.put("watchTrades", ["publicTrade.{symbol}"])

      assert undispatchable_keys("bybit", authored) == ["watchTradesForSymbols"]
    end

    test "a message-hash channel name inside an object template is caught" do
      authored =
        "okx"
        |> Spec.load!()
        |> channels()
        |> Map.put("watchOrders", [%{"channel" => "orders::{symbol}", "instType" => "ANY"}])

      assert message_hashes(authored) == [{"watchOrders", "orders::{symbol}"}]
    end
  end

  defp undispatchable_keys(venue, authored) do
    readable = readable_keys(venue, authored)

    authored |> Map.keys() |> MapSet.new() |> MapSet.difference(readable) |> Enum.sort()
  end

  # Same resolution as `Bourse.WS.Channels`: the primary key when it carries
  # templates or an unresolved reason, otherwise the first fallback that does.
  defp readable_keys(venue, authored) do
    private_section? = private_section?(venue)

    for {method, primary, fallbacks} <- Channels.dispatch_keys(),
        private_section? or not Channels.private?(method),
        key <- List.wrap(Enum.find([primary | fallbacks], &usable?(authored[&1]))),
        into: MapSet.new(),
        do: key
  end

  defp usable?(%{"_unresolved_reason" => reason}) when is_binary(reason), do: true
  defp usable?([_ | _]), do: true
  defp usable?(_entry), do: false

  # A private watch method is sent only on a `:private` connection; a venue
  # without a private WS URL in either environment can never open one.
  defp private_section?(venue) do
    config = Config.for_exchange(venue) || %{}
    is_binary(config[:private_url]) or is_binary(config[:private_url_sandbox])
  end

  defp channels(spec), do: get_in(spec, ["websocket", "subscribe", "channels"]) || %{}

  # Every string an authored template sends: the template itself, or each
  # string value of an object template.
  defp message_hashes(authored) do
    for {key, templates} <- authored,
        is_list(templates),
        template <- templates,
        value <- sent_strings(template),
        message_hash?(value),
        do: {key, value}
  end

  defp sent_strings(template) when is_binary(template), do: [template]
  defp sent_strings(%{} = object), do: object |> Map.values() |> Enum.filter(&is_binary/1)

  # Leading-separator and doubled-separator shapes (`:{symbol}`, `.{symbol}`,
  # `trade::{symbol}`) are client-side routing keys, never a provider channel.
  defp message_hash?(template) do
    String.starts_with?(template, [":", "."]) or String.contains?(template, ["::", ".."])
  end
end
