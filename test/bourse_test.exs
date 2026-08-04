defmodule BourseTest do
  @moduledoc "Tests for Bourse unified API — generated functions, dispatch, and error handling."

  # async: false — Req.Test.stub uses global state
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Test.RequestCollector
  alias Bourse.TestExchange.Bybit
  alias Bourse.Unified

  @moduletag capture_log: true

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_stub do
    :"bourse_stub_#{System.unique_integer([:positive])}"
  end

  defp stub_json(stub, response_body) do
    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, response_body)
    end)
  end

  # Builds a minimal exchange with the Bybit test module
  defp build_test_exchange(opts \\ []) do
    has = Keyword.get(opts, :has, Bybit.__features__())
    # Lean hand-built exchange for dispatch/signing unit tests (empty
    # symbol_patterns keeps unified symbols on the wire). Still carry authored
    # endpoint_selection + default_family so multi-endpoint selection is not
    # bare-hd (task 378).
    authored = Exchange.new!("bybit")

    %Exchange{
      id: "bybit",
      name: "Bybit",
      credentials: Keyword.get(opts, :credentials),
      sandbox: false,
      rate_limit_ms: 0,
      hostname: nil,
      base_urls: %{"public" => "https://api.bybit.com", "private" => "https://api.bybit.com"},
      has: has,
      required_credentials: %{},
      signing_pattern: :hmac_sha256_headers,
      signing_config: Bybit.__signing__().config,
      options: %{},
      error_codes: %{},
      broad_error_patterns: %{},
      http_exceptions: %{},
      module: Bybit,
      markets: [
        %Bourse.Market{
          symbol: "BTC/USDT",
          precision: %{"amount" => 0.001, "price" => 0.1}
        }
      ],
      endpoint_selection: authored.endpoint_selection,
      default_family: authored.default_family,
      spec: %{}
    }
  end

  # ---------------------------------------------------------------------------
  # Function Generation
  # ---------------------------------------------------------------------------

  describe "generated functions" do
    test "all unified methods have regular + bang variants" do
      exports = :functions |> Bourse.__info__() |> MapSet.new()

      for {name, _js, params, _desc} <- Unified.method_defs() do
        min_arity = length(params) + 1
        bang = String.to_atom("#{name}!")

        assert MapSet.member?(exports, {name, min_arity}),
               "Missing: Bourse.#{name}/#{min_arity}"

        assert MapSet.member?(exports, {name, min_arity + 1}),
               "Missing: Bourse.#{name}/#{min_arity + 1} (with opts)"

        assert MapSet.member?(exports, {bang, min_arity}),
               "Missing: Bourse.#{bang}/#{min_arity}"

        assert MapSet.member?(exports, {bang, min_arity + 1}),
               "Missing: Bourse.#{bang}/#{min_arity + 1} (with opts)"
      end
    end

    test "total export count matches method_defs" do
      exports = Bourse.__info__(:functions)
      method_count = length(Unified.method_defs())
      # Each method generates 4 exports (regular + bang × 2 arities)
      # + 4 for exchange/exchange!
      # + 4 for timeframes/1, fees/1, config/1, doc_urls/1
      # + 4 for load_markets/load_markets! (2 arities each)
      # + 2 for Descripex __api__/0 and __api__/1
      # + 4 for Discoverable describe/0, describe/1, describe/2, __descripex_modules__/0
      expected = method_count * 4 + 4 + 4 + 4 + 2 + 4
      assert length(exports) == expected
    end
  end

  # ---------------------------------------------------------------------------
  # Happy Path — Public Endpoint
  # ---------------------------------------------------------------------------

  describe "fetch_ticker/2,3 (public endpoint)" do
    test "dispatches to exchange module and returns parsed ticker" do
      stub = unique_stub()
      exchange = build_test_exchange()

      stub_json(stub, %{"symbol" => "BTCUSDT", "lastPrice" => "67000"})

      assert {:ok, %Bourse.Ticker{last: 67_000.0}} =
               Bourse.fetch_ticker(exchange, "BTC/USDT", plug: {Req.Test, stub})
    end

    test "passes extra opts as exchange params" do
      stub = unique_stub()
      exchange = build_test_exchange()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"retCode" => 0, "lastPrice" => "67000"})
      end)

      assert {:ok, _} =
               Bourse.fetch_ticker(exchange, "BTC/USDT", category: "spot", plug: {Req.Test, stub})

      params = RequestCollector.query(requests)
      assert params["category"] == "spot"
    end
  end

  # ---------------------------------------------------------------------------
  # Happy Path — No Required Params
  # ---------------------------------------------------------------------------

  describe "fetch_balance/1,2 (no required params)" do
    test "dispatches with empty params" do
      stub = unique_stub()

      exchange =
        build_test_exchange(credentials: %Bourse.Credentials{api_key: "test", secret: "test"})

      stub_json(stub, %{
        "result" => %{"list" => [%{"coin" => [%{"coin" => "USDT", "walletBalance" => "1000"}]}]}
      })

      assert {:ok, %Bourse.Balance{total: %{"USDT" => 1000.0}}} =
               Bourse.fetch_balance(exchange, plug: {Req.Test, stub})
    end

    test "passes opts as exchange params" do
      stub = unique_stub()

      exchange =
        build_test_exchange(credentials: %Bourse.Credentials{api_key: "test", secret: "test"})

      stub_json(stub, %{"retCode" => 0})

      assert {:ok, _} = Bourse.fetch_balance(exchange, type: "spot", plug: {Req.Test, stub})
    end
  end

  # ---------------------------------------------------------------------------
  # Happy Path — Multiple Required Params
  # ---------------------------------------------------------------------------

  describe "fetch_ohlcv/3,4 (symbol + timeframe)" do
    test "passes both required params" do
      stub = unique_stub()
      exchange = build_test_exchange()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, [1_700_000_000_000, "1", "2", "0.5", "1.5", "10"])
      end)

      assert {:ok, _} = Bourse.fetch_ohlcv(exchange, "BTC/USDT", "1h", plug: {Req.Test, stub})

      params = RequestCollector.query(requests)
      assert params["symbol"] == "BTC/USDT"
      assert params["timeframe"] == "1h"
    end

    test "translates unified timeframe via capabilities.timeframes on real exchange" do
      stub = unique_stub()
      {:ok, exchange} = Exchange.new("bybit")

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, [1_700_000_000_000, "1", "2", "0.5", "1.5", "10"])
      end)

      assert {:ok, _} = Bourse.fetch_ohlcv(exchange, "BTC/USDT", "1h", plug: {Req.Test, stub})

      params = RequestCollector.query(requests)
      # bybit V5 kline maps the unified timeframe into `interval` (and injects
      # the per-market `category`); the unified `timeframe` key is dropped.
      assert params["interval"] == "60"
      assert params["category"] == "spot"
      refute Map.has_key?(params, "timeframe")
    end

    test "merges opts with required params" do
      stub = unique_stub()
      exchange = build_test_exchange()

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, [1_700_000_000_000, "1", "2", "0.5", "1.5", "10"])
      end)

      assert {:ok, _} =
               Bourse.fetch_ohlcv(exchange, "BTC/USDT", "1m",
                 limit: 200,
                 plug: {Req.Test, stub}
               )

      params = RequestCollector.query(requests)
      assert params["symbol"] == "BTC/USDT"
      assert params["limit"] == "200"
    end
  end

  # ---------------------------------------------------------------------------
  # Happy Path — Order Creation (4 required params)
  # ---------------------------------------------------------------------------

  describe "create_order/5,6 (symbol, type, side, amount)" do
    test "dispatches through signing to exchange and returns response" do
      stub = unique_stub()

      exchange =
        build_test_exchange(credentials: %Bourse.Credentials{api_key: "test", secret: "test"})

      # Body params are verified by Dispatch + Signing tests (dispatch_test.exs).
      # Here we verify the unified layer correctly routes a private endpoint
      # through signing and returns the parsed order response.
      stub_json(stub, %{"retCode" => 0, "result" => %{"orderId" => "12345"}})

      assert {:ok, response} =
               Bourse.create_order(exchange, "BTC/USDT", "limit", "buy", 0.001,
                 price: 50_000,
                 plug: {Req.Test, stub}
               )

      assert %Bourse.Order{id: "12345"} = response
      assert response.info["orderId"] == "12345"
    end
  end

  # ---------------------------------------------------------------------------
  # Error Handling
  # ---------------------------------------------------------------------------

  describe "not_supported errors" do
    test "returns not_supported when method has no endpoint mapping" do
      # createGiftCode has no endpoint mapping on Bybit
      exchange = build_test_exchange()

      assert {:error, %Error{type: :not_supported}} =
               Bourse.create_gift_code(exchange, "BTC", 1.0)
    end

    test "not_supported error includes exchange id and method name" do
      exchange = build_test_exchange()

      assert {:error, %Error{type: :not_supported, message: message}} =
               Bourse.create_gift_code(exchange, "BTC", 1.0)

      assert message =~ "bybit"
      assert message =~ "createGiftCode"
    end

    test "dispatch proceeds past has=false when endpoint mapping exists" do
      # Bybit has fetchTicker endpoint mapping — dispatch should proceed
      # regardless of has value, reaching the HTTP layer (not the old gate)
      stub = unique_stub()
      exchange = build_test_exchange(has: %{"fetchTicker" => false})

      stub_json(stub, %{"retCode" => 0, "lastPrice" => "67000"})

      result = Bourse.fetch_ticker(exchange, "BTC/USDT", plug: {Req.Test, stub})
      assert {:ok, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Bang Variants
  # ---------------------------------------------------------------------------

  describe "bang variants" do
    test "returns unwrapped result on success" do
      stub = unique_stub()
      exchange = build_test_exchange()

      stub_json(stub, %{"symbol" => "BTCUSDT", "lastPrice" => "67000"})

      response = Bourse.fetch_ticker!(exchange, "BTC/USDT", plug: {Req.Test, stub})
      assert %Bourse.Ticker{last: 67_000.0} = response
    end

    test "raises Bourse.Error on not_supported" do
      exchange = build_test_exchange()

      assert_raise Error, ~r/does not support/, fn ->
        Bourse.create_gift_code!(exchange, "BTC", 1.0)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Endpoint Index Override
  # ---------------------------------------------------------------------------

  describe "endpoint_index option" do
    test "selects specific endpoint when multiple exist" do
      stub = unique_stub()
      exchange = build_test_exchange()

      stub_json(stub, %{"retCode" => 0, "lastPrice" => "67000"})

      # endpoint_index is a dispatch opt, not passed to exchange
      assert {:ok, _} =
               Bourse.fetch_ticker(exchange, "BTC/USDT",
                 endpoint_index: 0,
                 plug: {Req.Test, stub}
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Exchange Constructor Integration
  # ---------------------------------------------------------------------------

  describe "exchange/2 integration" do
    test "still delegates to Exchange.new/2" do
      assert {:ok, %Exchange{id: "bybit"}} = Bourse.exchange("bybit")
    end

    test "bang variant raises on invalid exchange" do
      assert_raise ArgumentError, fn ->
        Bourse.exchange!("nonexistent_exchange_xyz")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Descripex Introspection (__api__)
  # ---------------------------------------------------------------------------

  describe "__api__/0 introspection" do
    test "returns declarations for all unified methods plus exchange constructors" do
      api = Bourse.__api__()
      assert is_list(api)
      # unified methods + exchange/2 + timeframes/1 + fees/1 + config/1 + doc_urls/1 + load_markets/2
      # (bang variants excluded from api())
      method_count = length(Unified.method_defs())
      assert length(api) == method_count + 6
    end

    test "each entry has name, arity, hints, and spec fields" do
      for entry <- Bourse.__api__() do
        assert is_atom(entry.name), "Expected atom name, got: #{inspect(entry.name)}"
        assert is_integer(entry.arity), "Expected integer arity for #{entry.name}"
        assert is_map(entry.hints), "Expected hints map for #{entry.name}"
        assert Map.has_key?(entry.hints, :description), "Missing :description in hints for #{entry.name}"
      end
    end
  end

  describe "__api__/1 lookup" do
    test "returns full detail for fetch_ticker" do
      ticker = Bourse.__api__(:fetch_ticker)
      assert ticker.name == :fetch_ticker
      assert ticker.hints.description =~ "ticker"
      assert Map.has_key?(ticker.hints, :params)
      assert Map.has_key?(ticker.hints.params, :exchange)
      assert Map.has_key?(ticker.hints.params, :symbol)
      assert ticker.hints.params.exchange.kind == :value
    end

    test "returns full detail for create_order" do
      order = Bourse.__api__(:create_order)
      assert order.name == :create_order
      assert Map.has_key?(order.hints.params, :symbol)
      assert Map.has_key?(order.hints.params, :type)
      assert Map.has_key?(order.hints.params, :side)
      assert Map.has_key?(order.hints.params, :amount)
    end

    test "returns full detail for exchange constructor" do
      exch = Bourse.__api__(:exchange)
      assert exch.name == :exchange
      assert exch.hints.description =~ "exchange configuration"
      assert Map.has_key?(exch.hints, :params)
      assert Map.has_key?(exch.hints.params, :exchange_id)
    end

    test "returns nil for nonexistent method" do
      assert Bourse.__api__(:nonexistent_method) == nil
    end

    test "all unified methods have errors in hints" do
      for {name, _, _, _} <- Unified.method_defs() do
        entry = Bourse.__api__(name)
        assert is_list(entry.hints.errors), "Missing errors for #{name}"
        assert :not_supported in entry.hints.errors
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Descripex Discoverable (describe/0-2)
  # ---------------------------------------------------------------------------

  describe "describe/0 (Level 1 — module overview)" do
    test "returns list of module summaries" do
      modules = Bourse.describe()
      assert is_list(modules)
      assert modules != []

      # descripex 0.12.0 emits `short_name` as a string — it is a label over a
      # caller-supplied module list, never interned. Atoms still work as *input*
      # to describe/1-2.
      names = Enum.map(modules, & &1.short_name)
      assert "bourse" in names
    end

    test "each module summary has required fields" do
      for mod <- Bourse.describe() do
        assert Map.has_key?(mod, :module)
        assert Map.has_key?(mod, :short_name)
        assert Map.has_key?(mod, :function_count)
      end
    end
  end

  describe "describe/1 (Level 2 — function list)" do
    test "returns function list for :bourse" do
      functions = Bourse.describe(:bourse)
      assert is_list(functions)
      assert length(functions) > 200

      names = Enum.map(functions, & &1.name)
      assert :fetch_ticker in names
      assert :create_order in names
    end
  end

  describe "describe/2 (Level 3 — function detail)" do
    test "returns full detail for fetch_ticker" do
      detail = Bourse.describe(:bourse, :fetch_ticker)
      assert detail.name == :fetch_ticker
      assert is_binary(detail.description)
      assert detail.params.exchange.kind == :value
      assert detail.params.symbol.kind == :value
    end

    test "returns nil for nonexistent function" do
      assert Bourse.describe(:bourse, :nonexistent) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # MCP Tool Generation
  # ---------------------------------------------------------------------------

  describe "Bourse.MCP.tools/0" do
    test "generates tool definitions for all unified methods" do
      tools = Bourse.MCP.tools()
      assert is_list(tools)
      assert length(tools) > 200
    end

    test "each tool has name, description, and inputSchema" do
      tools = Bourse.MCP.tools()

      for tool <- tools do
        assert is_binary(tool.name), "Expected string tool name"
        assert is_binary(tool.description), "Expected string description for #{tool.name}"
        assert is_map(tool.inputSchema), "Expected inputSchema map for #{tool.name}"
      end
    end

    test "fetch_ticker tool has exchange and symbol inputs" do
      tools = Bourse.MCP.tools()
      ticker_tool = Enum.find(tools, &(&1.name == "bourse__fetch_ticker"))
      assert ticker_tool, "Expected to find bourse__fetch_ticker tool"
      assert Map.has_key?(ticker_tool.inputSchema, :properties)
      props = ticker_tool.inputSchema.properties
      assert Map.has_key?(props, :exchange)
      assert Map.has_key?(props, :symbol)
    end
  end
end
