defmodule Bourse.RegistryTest do
  use ExUnit.Case, async: true

  alias Bourse.Registry

  describe "lookup/1" do
    test "returns module for known string ID" do
      assert {:ok, Bourse.Bybit} = Registry.lookup("bybit")
    end

    test "returns module for known atom ID" do
      assert {:ok, Bourse.Binance} = Registry.lookup(:binance)
    end

    test "returns named error for a reference-only string ID" do
      assert {:error, {:unsupported_exchange, "kraken"}} = Registry.lookup("kraken")
    end

    test "returns named error for unsupported atom ID" do
      # atom is converted to string in error tuple
      assert {:error, {:unsupported_exchange, "kraken"}} = Registry.lookup(:kraken)
    end
  end

  describe "lookup!/1" do
    test "returns module for known exchange" do
      assert Bourse.Bybit = Registry.lookup!(:bybit)
    end

    test "raises on unsupported exchange" do
      assert_raise ArgumentError, ~r/unsupported exchange/, fn ->
        Registry.lookup!(:kraken)
      end
    end
  end

  describe "module_for/1" do
    test "returns module for known exchange" do
      assert Bourse.Bybit = Registry.module_for("bybit")
    end

    test "returns nil for unknown exchange" do
      assert is_nil(Registry.module_for("nonexistent"))
    end

    test "accepts atoms" do
      assert Bourse.Binance = Registry.module_for(:binance)
    end
  end

  describe "exchanges/0" do
    test "returns exactly the manifest-defined runtime inventory" do
      assert Registry.exchanges() == Bourse.Spec.exchanges()

      assert Registry.exchanges() ==
               ~w(alpaca binance binancecoinm binanceusdm bybit deribit derive hyperliquid lighter okx)
    end

    test "returns string IDs sorted alphabetically" do
      exchanges = Registry.exchanges()

      assert exchanges == Enum.sort(exchanges)
    end
  end

  describe "registered?/1" do
    test "returns true for known string ID" do
      assert Registry.registered?("bybit")
    end

    test "returns true for known atom ID" do
      assert Registry.registered?(:binance)
    end

    test "returns false for unknown exchange" do
      refute Registry.registered?("nonexistent")
      refute Registry.registered?(:nonexistent)
    end
  end

  describe "loaded?/1" do
    test "returns true for a generated runtime exchange" do
      assert Registry.loaded?("bybit")
    end

    test "returns false for unknown exchange" do
      refute Registry.loaded?(:nonexistent)
    end

    test "every registered module is compiled" do
      assert Enum.all?(Registry.exchanges(), &Registry.loaded?/1)
    end
  end
end
