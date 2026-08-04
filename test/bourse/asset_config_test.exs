defmodule Bourse.AssetConfigTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.AssetConfig

  @exchange :bybit
  @method :create_order
  @symbol "BTC/USDT"
  @size "0.001"
  @price "10000"

  @valid_order_attrs [
    exchange_id: @exchange,
    method: @method,
    symbol: @symbol,
    size: @size,
    price: @price,
    order_type: "limit",
    side: "buy",
    safety_flags: [post_only: true, sandbox_only: true],
    cleanup: [cancel_after_create: true]
  ]

  describe "fetch/2" do
    test "missing config is explicit and keyed by exchange and method" do
      assert {:error, {:missing_asset_config, @exchange, @method}} =
               AssetConfig.fetch(@exchange, @method)
    end
  end

  describe "new!/1" do
    test "builds a config with required dangerous-test fields" do
      assert %AssetConfig{
               exchange_id: @exchange,
               method: @method,
               symbol: @symbol,
               size: @size,
               safety_flags: %{post_only: true, sandbox_only: true},
               cleanup: %{cancel_after_create: true}
             } = AssetConfig.new!(@valid_order_attrs)
    end

    test "requires explicit safety flags" do
      attrs = Keyword.delete(@valid_order_attrs, :safety_flags)

      assert_raise ArgumentError, ~r/safety_flags/, fn ->
        AssetConfig.new!(attrs)
      end
    end

    test "requires cancel-after-create cleanup for order-write methods" do
      attrs = Keyword.put(@valid_order_attrs, :cleanup, cancel_after_create: false)

      assert_raise ArgumentError, ~r/cancel_after_create/, fn ->
        AssetConfig.new!(attrs)
      end
    end
  end
end
