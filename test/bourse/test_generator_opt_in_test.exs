defmodule Bourse.Test.Generator.OptInTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.Generator.OptIn

  @catalog ~w(binance bybit kraken)
  @suite_tags [:network, :raw]

  test "ordinary offline filters instantiate no opt-in exchanges" do
    assert OptIn.exchanges_for(@catalog, @suite_tags, []) == []
    refute OptIn.requested_from?([], @suite_tags)
  end

  test "suite filters retain the complete catalog" do
    assert OptIn.exchanges_for(@catalog, @suite_tags, network: true) == @catalog
  end

  test "an exchange filter retains only the selected complete exchange suite" do
    assert OptIn.exchanges_for(@catalog, @suite_tags, exchange_bybit: true) == ["bybit"]
  end

  test "false filters do not opt into generation" do
    assert OptIn.exchanges_for(@catalog, @suite_tags, network: false, raw: false) == []
  end
end
