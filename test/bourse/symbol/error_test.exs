defmodule Bourse.Symbol.ErrorTest do
  use ExUnit.Case, async: true

  alias Bourse.Symbol.Error, as: SymbolError

  describe "invalid_format/1" do
    test "creates error with symbol and reason" do
      error = SymbolError.invalid_format("INVALID")
      assert error.symbol == "INVALID"
      assert error.reason == :invalid_format
      assert error.message =~ "Invalid symbol format"
      assert error.message =~ "INVALID"
    end
  end

  describe "pattern_not_found/3" do
    test "creates error with market type" do
      error = SymbolError.pattern_not_found("BTC/USDT", :swap)
      assert error.reason == :pattern_not_found
      assert error.market_type == :swap
      assert error.message =~ ":swap"
    end

    test "includes exchange_id when provided" do
      error = SymbolError.pattern_not_found("BTC/USDT", :spot, "binance")
      assert error.exchange_id == "binance"
      assert error.message =~ "binance"
    end
  end

  describe "unknown_quote_currency/2" do
    test "creates error with symbol" do
      error = SymbolError.unknown_quote_currency("BTCXYZ")
      assert error.reason == :unknown_quote_currency
      assert error.symbol == "BTCXYZ"
    end

    test "includes split attempt when provided" do
      error = SymbolError.unknown_quote_currency("BTCXYZ", "XYZ")
      assert error.message =~ "XYZ"
    end
  end

  describe "parse_failed/2" do
    test "creates error with reason detail" do
      error = SymbolError.parse_failed("BAD", :timeout)
      assert error.reason == :parse_failed
      assert error.message =~ ":timeout"
    end
  end

  describe "unsupported_prefix/2" do
    test "creates error with prefix tuple reason" do
      error = SymbolError.unsupported_prefix("XX_BTCUSD", "XX_")
      assert error.reason == {:unsupported_prefix, "XX_"}
      assert error.message =~ "XX_"
    end
  end

  describe "unrepresentable_id/4" do
    test "creates error naming the id and the rewrite it rejected" do
      error =
        SymbolError.unrepresentable_id(
          "DOGE_USDC-CS-28AUG26-0d1184_0d12",
          "DOGE_USDC-CS-28AUG26-0D1184_0D12"
        )

      assert error.reason == :unrepresentable_id
      assert error.symbol == "DOGE_USDC-CS-28AUG26-0d1184_0d12"
      assert error.exchange_id == nil
      assert error.market_type == nil
      assert error.message =~ "0d1184_0d12"
      assert error.message =~ "0D1184_0D12"
    end

    test "includes exchange and market type when provided" do
      error =
        SymbolError.unrepresentable_id("BTC-REV-18JUL26-65000", "BTC-REV", "deribit", :option)

      assert error.exchange_id == "deribit"
      assert error.market_type == :option
      assert error.message =~ "deribit"
      assert error.message =~ ":option"
    end
  end

  describe "exception protocol" do
    test "can be raised and rescued" do
      assert_raise SymbolError, ~r/Invalid symbol format/, fn ->
        raise SymbolError.invalid_format("BAD")
      end
    end

    test "unrepresentable_id can be raised and rescued" do
      assert_raise SymbolError, ~r/cannot faithfully represent this id/, fn ->
        raise SymbolError.unrepresentable_id("X-COMBO", "X-COMBO-REWRITTEN", "deribit", :option)
      end
    end
  end
end
