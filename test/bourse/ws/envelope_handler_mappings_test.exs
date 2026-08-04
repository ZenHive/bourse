defmodule Bourse.WS.EnvelopeHandlerMappingsTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.Envelope
  alias Bourse.WS.HandlerMappings

  test "builds authored envelopes and respects disabled dispatch" do
    bybit = Exchange.new!("bybit")
    assert %{"discriminator_field" => "topic", "discriminators" => discriminators} = Envelope.for_exchange(bybit)
    assert is_list(discriminators)
    assert Envelope.match_type(Envelope.for_exchange(bybit)) == "exact_then_substring"

    disabled = %{bybit | spec: put_in(bybit.spec, ["websocket", "dispatch", "kind"], "none")}
    assert Envelope.for_exchange(disabled) == nil
    assert Envelope.for_exchange(%Exchange{id: "kraken", name: "Unsupported", spec: %{}}) == nil
  end

  test "uses supplied discriminator and envelope defaults" do
    exchange = Exchange.new!("bybit")

    spec = %{
      "websocket" => %{
        "dispatch" => %{"discriminators" => ["first", "second"]}
      }
    }

    envelope = Envelope.for_exchange(%{exchange | spec: spec})
    assert envelope["discriminator_field"] == "topic"
    assert Envelope.match_type(nil) == "exact"
    assert Envelope.prefix_channels(nil) == []
  end

  test "keeps derive's explicit discriminator when its dispatch slice is empty" do
    assert %{"discriminator_field" => "channel"} =
             Envelope.for_exchange(Exchange.new!("derive"))
  end

  test "resolves handlers, composite families, and non-family messages" do
    assert HandlerMappings.resolve_handler(nil) == :not_found
    assert HandlerMappings.resolve_handler("handleTicker") == {:family, :watch_ticker}
    assert HandlerMappings.resolve_handler("handlePong") == :system
    assert HandlerMappings.handler_to_family("handleOrderBook") == :watch_order_book
    assert HandlerMappings.handler_to_family("unknown") == nil

    assert HandlerMappings.handler_to_families("handleAcountUpdate") == [:watch_balance, :watch_positions]
    assert HandlerMappings.handler_to_families("handleTicker") == [:watch_ticker]
    assert HandlerMappings.handler_to_families("unknown") == []
    assert :watch_positions in HandlerMappings.known_families()
  end
end
