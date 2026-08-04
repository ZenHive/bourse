defmodule Bourse.UnifiedWriteMethodIntegrationProbeTest do
  use ExUnit.Case, async: false

  alias Bourse.Exchange
  alias Bourse.Test.AssetConfig
  alias Bourse.Test.Generator.UnifiedWriteMethodIntegrationProbe

  @exchange_id :bybit
  @symbol "BTC/USDT"
  @size "0.001"
  @price "10000"
  @created_order_id "probe-order-1"

  defmodule FakeAPI do
    @moduledoc false
    def create_order(exchange, symbol, type, side, size, opts) do
      send(self(), {:create_order, exchange.sandbox, symbol, type, side, size, opts})
      {:ok, %{"id" => "probe-order-1"}}
    end

    def cancel_order(exchange, id, opts) do
      send(self(), {:cancel_order, exchange.sandbox, id, opts})
      {:ok, %{"id" => id, "status" => "canceled"}}
    end
  end

  @order_config AssetConfig.new!(
                  exchange_id: @exchange_id,
                  method: :create_order,
                  symbol: @symbol,
                  size: @size,
                  price: @price,
                  order_type: "limit",
                  side: "buy",
                  safety_flags: [post_only: true, sandbox_only: true],
                  cleanup: [cancel_after_create: true]
                )

  describe "__collect_for_inspection__/0" do
    test "emits private dangerous cases for supported write methods" do
      cases = UnifiedWriteMethodIntegrationProbe.__collect_for_inspection__()

      assert Enum.any?(cases, fn
               {:private_dangerous, "bybit", :create_order} -> true
               _ -> false
             end)
    end
  end

  describe "__ensure_testnet!/2" do
    test "flunks loudly when sandbox resolution did not apply" do
      exchange = %Exchange{id: "bybit", name: "Bybit", sandbox: false}

      assert_raise ExUnit.AssertionError, ~r/dangerous probe requires sandbox/, fn ->
        UnifiedWriteMethodIntegrationProbe.__ensure_testnet!(exchange, :create_order)
      end
    end
  end

  describe "__fetch_config!/2" do
    test "flunks loudly instead of using dangerous defaults" do
      assert_raise ExUnit.AssertionError, ~r/Missing dangerous asset config/, fn ->
        UnifiedWriteMethodIntegrationProbe.__fetch_config!(@exchange_id, :create_order)
      end
    end
  end

  describe "__explicit_include_tags?/1" do
    test "requires both network and dangerous includes" do
      refute UnifiedWriteMethodIntegrationProbe.__explicit_include_tags?(dangerous: true)
      refute UnifiedWriteMethodIntegrationProbe.__explicit_include_tags?(network: true)
      assert UnifiedWriteMethodIntegrationProbe.__explicit_include_tags?(network: true, dangerous: true)
    end
  end

  describe "__run_write_case__/4" do
    test "create_order cancels the created order in the same lifecycle" do
      exchange = %Exchange{id: "bybit", name: "Bybit", sandbox: true}

      assert :ok =
               UnifiedWriteMethodIntegrationProbe.__run_write_case__(
                 :create_order,
                 exchange,
                 @order_config,
                 api_module: FakeAPI
               )

      assert_received {:create_order, true, @symbol, "limit", "buy", @size, create_opts}
      assert Keyword.fetch!(create_opts, :price) == @price
      assert Keyword.fetch!(create_opts, :postOnly) == true

      assert_received {:cancel_order, true, @created_order_id, cancel_opts}
      assert Keyword.fetch!(cancel_opts, :symbol) == @symbol
    end
  end
end
