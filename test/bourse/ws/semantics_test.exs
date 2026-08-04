defmodule Bourse.WS.SemanticsTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.Semantics.Ohlcv
  alias Bourse.WS.Semantics.Orderbook
  alias Bourse.WS.Semantics.Trades

  test "orderbook applies snapshot then delta" do
    exchange = Exchange.new!("bybit")
    state = Orderbook.new(exchange)

    snapshot = %{"b" => [["42000", "1"]], "a" => [["42001", "1"]], "type" => "snapshot"}
    {state, book} = Orderbook.apply(state, "BTCUSDT", snapshot)
    assert book["bids"] == [["42000", "1"]]

    delta = %{"b" => [["42000", "0"]], "a" => [["42002", "2"]], "type" => "delta"}
    {_state, book} = Orderbook.apply(state, "BTCUSDT", delta)
    assert book["bids"] == []
    assert book["asks"] == [["42001", "1"], ["42002", "2"]]
  end

  test "orderbook preserves the existing book for an unknown update" do
    state = %Orderbook{apply_mode: "unknown", books: %{"BTCUSDT" => %{"bids" => [["1", "2"]]}}}

    assert {^state, %{"bids" => [["1", "2"]]}} = Orderbook.apply(state, "BTCUSDT", %{})
  end

  test "orderbook replaces, accepts raw snapshots, and ignores malformed delta levels" do
    state = %Orderbook{apply_mode: "replace"}
    {_state, book} = Orderbook.apply(state, "BTCUSDT", %{bids: []})
    assert book == %{"bids" => [], "asks" => []}

    delta_state = %Orderbook{apply_mode: "delta", books: %{"BTCUSDT" => %{"bids" => [["1", "1"]], "asks" => []}}}
    {_state, delta_book} = Orderbook.apply(delta_state, "BTCUSDT", %{"bids" => [["1", "3"], ["bad"]]})
    assert delta_book["bids"] == [["1", "3"]]

    {_state, raw_book} = Orderbook.apply(%Orderbook{apply_mode: "snapshot"}, "BTCUSDT", :raw)
    assert raw_book == %{"payload" => :raw}
  end

  test "orderbook both mode recognizes snapshots and defaults to delta when configured" do
    state = %Orderbook{apply_mode: "both", discriminator_field: "type", snapshot_values: ["snapshot"]}
    {state, snapshot} = Orderbook.apply(state, "BTCUSDT", %{"type" => "snapshot", "b" => [["1", "1"]]})
    assert snapshot["bids"] == [["1", "1"]]

    {_state, delta} = Orderbook.apply(state, "BTCUSDT", %{"type" => "update", "b" => [["1", "0"]]})
    assert delta["bids"] == []
  end

  test "trades append without dedup when dedup_key is unset" do
    exchange = Exchange.new!("bybit")
    state = Trades.new(exchange)

    trade = %{"id" => "1", "price" => "100"}
    {state, emitted} = Trades.apply(state, "BTCUSDT", trade)
    assert emitted == [trade]

    {state, _} = Trades.apply(state, "BTCUSDT", trade)
    assert Map.get(state.caches, "BTCUSDT") == [trade, trade]
  end

  test "trades deduplicate and replace according to semantics" do
    deduplicated = %Trades{dedup_key: "id"}
    {deduplicated, [%{"id" => "1"}]} = Trades.apply(deduplicated, "BTCUSDT", %{"id" => "1"})

    {deduplicated, [%{"id" => "1"}, %{"id" => "2"}]} =
      Trades.apply(deduplicated, "BTCUSDT", [%{"id" => "1"}, %{"id" => "2"}, :invalid])

    assert deduplicated.caches["BTCUSDT"] == [%{"id" => "1"}, %{"id" => "2"}]

    replaced = %Trades{update_model: "replace"}
    {replaced, []} = Trades.apply(replaced, "BTCUSDT", :invalid)
    assert replaced.caches["BTCUSDT"] == []
  end

  test "ohlcv replace model stores latest candle" do
    exchange = Exchange.new!("okx")
    state = Ohlcv.new(exchange)

    candle = %{"o" => "42000", "h" => "42500"}
    {state, out} = Ohlcv.apply(state, "BTC-USDT", candle)
    assert out == candle
    assert Map.get(state.caches, "BTC-USDT") == candle
  end

  test "ohlcv append model merges an existing candle and retains it for invalid updates" do
    state = %Ohlcv{update_model: "append"}
    {state, first} = Ohlcv.apply(state, "BTCUSDT", [%{"open" => "1"}])
    assert first == %{"open" => "1"}

    {state, second} = Ohlcv.apply(state, "BTCUSDT", %{"close" => "2"})
    assert second == %{"close" => "2"}
    assert state.caches["BTCUSDT"] == %{"close" => "2"}

    {state, nil} = Ohlcv.apply(state, "BTCUSDT", :invalid)
    assert state.caches["BTCUSDT"] == %{"close" => "2"}
  end
end
