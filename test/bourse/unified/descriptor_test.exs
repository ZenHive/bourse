defmodule Bourse.Unified.DescriptorTest do
  use ExUnit.Case, async: true

  alias Bourse.Unified.Descriptor

  @first_class ~w(bybit binance deribit okx binanceusdm hyperliquid derive)

  describe "gate: upstream descriptors populated" do
    test "endpoints.descriptors is non-null for first-class venues" do
      for exchange_id <- @first_class do
        descriptors = Descriptor.descriptors_from_spec(exchange_id)

        assert is_map(descriptors)

        assert map_size(descriptors) > 0,
               "expected non-empty descriptors for #{exchange_id}"
      end
    end
  end

  describe "descriptors/0" do
    test "merges first-class venue descriptors" do
      assert map_size(Descriptor.descriptors()) >= 50
      assert Map.has_key?(Descriptor.descriptors(), "fetchTicker")
    end
  end

  describe "build_api_opts/2" do
    test "enriches fetch_ticker from upstream signature and JSDoc overlay" do
      opts = Descriptor.build_api_opts("fetchTicker", [:symbol])

      assert Keyword.fetch!(opts, :params)[:symbol][:description] =~ "unified symbol"
      assert Keyword.fetch!(opts, :params)[:symbol][:description] =~ "TS: string"

      returns = Keyword.fetch!(opts, :returns)
      assert returns.description =~ "ticker structure"
      assert returns.description =~ "TS: Promise<Ticker>"
    end

    test "enriches create_order optional params into opts" do
      opts = Descriptor.build_api_opts("createOrder", [:symbol, :type, :side, :amount])
      opt_hints = Keyword.fetch!(opts, :opts)

      assert opt_hints[:price][:description] =~ "price"
      assert opt_hints[:hedged][:description] =~ "hedged"
    end

    test "emits structural metadata when JSDoc overlay is sparse" do
      opts = Descriptor.build_api_opts("fetchMarkets", [])

      assert Keyword.fetch!(opts, :params)[:exchange]
      assert Keyword.fetch!(opts, :returns).description =~ "TS: Promise<Market[]>"
    end

    test "falls back when descriptor is absent" do
      opts = Descriptor.build_api_opts("fetchOrderBooks", [])

      assert Keyword.fetch!(opts, :params)[:exchange]
      assert Keyword.fetch!(opts, :returns).description =~ "{:ok, map()}"

      assert Keyword.fetch!(opts, :errors) == [
               :not_supported,
               :authentication_error,
               :rate_limit_exceeded,
               :network_error
             ]
    end
  end

  describe "Bourse.__api__/1 consumption" do
    test "fetch_ticker hints carry upstream metadata without changing curated description" do
      entry = Bourse.__api__(:fetch_ticker)

      assert entry.hints.description =~ "ticker"
      assert entry.hints.params.symbol.description =~ "unified symbol"
      assert entry.hints.returns.description =~ "ticker structure"
    end

    test "method without descriptor keeps hand-authored hints" do
      entry = Bourse.__api__(:fetch_order_books)

      assert entry.hints.params.exchange.kind == :value
      assert entry.hints.returns.description =~ "{:ok, map()}"
    end

    test "aligned margin and convert signatures are exposed through API metadata" do
      assert Map.has_key?(Bourse.__api__(:set_margin).hints.params, :symbol)
      assert Map.has_key?(Bourse.__api__(:set_margin).hints.params, :amount)
      assert Map.has_key?(Bourse.__api__(:add_margin).hints.params, :symbol)
      assert Map.has_key?(Bourse.__api__(:add_margin).hints.params, :amount)
      assert Map.has_key?(Bourse.__api__(:create_convert_trade).hints.params, :id)

      assert Map.has_key?(Bourse.describe(:bourse, :set_margin).params, :symbol)
      assert Map.has_key?(Bourse.describe(:bourse, :set_margin).params, :amount)
    end

    test "our-rule positional shapes are exposed through API metadata" do
      order_book_params = Bourse.__api__(:fetch_order_book).hints.params
      adl_rank_params = Bourse.__api__(:fetch_positions_adl_rank).hints.params
      classic_orders_params = Bourse.__api__(:fetch_orders_classic).hints.params

      assert Map.has_key?(order_book_params, :symbol)
      refute Map.has_key?(order_book_params, :limit)
      assert Map.keys(adl_rank_params) == [:exchange]
      assert Map.keys(classic_orders_params) == [:exchange]

      assert Map.has_key?(Bourse.describe(:bourse, :fetch_order_book).params, :symbol)
      assert Map.keys(Bourse.describe(:bourse, :fetch_positions_adl_rank).params) == [:exchange]
      assert Map.keys(Bourse.describe(:bourse, :fetch_orders_classic).params) == [:exchange]
    end

    test "describe/2 and MCP.tools/0 remain available for enriched methods" do
      detail = Bourse.describe(:bourse, :fetch_ticker)
      assert detail.params.symbol.description =~ "unified symbol"

      tool = Enum.find(Bourse.MCP.tools(), &(&1.name == "bourse__fetch_ticker"))

      assert tool.description =~ "ticker"
      assert Map.has_key?(tool.inputSchema.properties, :symbol)
    end
  end
end
