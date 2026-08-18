defmodule Bourse.UnifiedTest do
  @moduledoc "Tests for Bourse.Unified — dispatch helpers and method definitions."

  # async: false — the dispatch gate test uses global Req.Test.stub(Bourse.HTTP, ...)
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Test.RequestCollector
  alias Bourse.TestExchange.Bybit
  alias Bourse.Unified

  @bybit_instruments_page_limit 1000
  @bybit_non_option_category_count 3

  defmodule PrivateMarketExchange do
    @moduledoc false

    @spec __unified_endpoint__(atom()) :: [map()]
    def __unified_endpoint__(:fetch_markets) do
      for {name, section} <- [{:private_get_markets, "private"}, {:private_v2_get_markets, "privateV2"}] do
        %{name: name, authenticated: true, sections: [section], path: "markets", method: :get}
      end
    end

    def __unified_endpoint__(_method), do: []
  end

  # ---------------------------------------------------------------------------
  # Method Definitions
  # ---------------------------------------------------------------------------

  describe "method_defs/0" do
    test "returns a non-empty list of method definitions" do
      defs = Unified.method_defs()
      assert length(defs) > 200, "Expected 200+ method definitions, got #{length(defs)}"
    end

    test "each entry is a {atom, string, list, string} tuple" do
      for {name, js_name, params, desc} <- Unified.method_defs() do
        assert is_atom(name), "Expected atom name, got: #{inspect(name)}"
        assert is_binary(js_name), "Expected string js_name for #{name}"
        assert is_list(params), "Expected list params for #{name}"
        assert is_binary(desc), "Expected string description for #{name}"
        assert desc != "", "Expected non-empty description for #{name}"

        Enum.each(params, fn p ->
          assert is_atom(p), "Expected atom param for #{name}, got: #{inspect(p)}"
        end)
      end
    end

    test "no duplicate elixir names" do
      names = Enum.map(Unified.method_defs(), &elem(&1, 0))
      assert length(names) == length(Enum.uniq(names))
    end

    test "no duplicate js capability names" do
      js_names = Enum.map(Unified.method_defs(), &elem(&1, 1))
      assert length(js_names) == length(Enum.uniq(js_names))
    end

    test "elixir atoms match Macro.underscore or are in known divergences" do
      # These JS names produce different atoms via Macro.underscore than what
      # method_defs declares. They're handled by the js_to_atom canonical mapping
      # in Exchange.build_unified_method_mapping/2. Add new entries here when
      # Macro.underscore mangles a JS name (e.g., consecutive acronyms like UTAOHLCV).
      known_divergences = MapSet.new(["fetchUTAOHLCV"])

      for {declared_atom, js_name, _params, _desc} <- Unified.method_defs(),
          js_name not in known_divergences do
        derived = js_name |> Macro.underscore() |> String.to_atom()

        assert declared_atom == derived,
               "method_defs declares :#{declared_atom} but Macro.underscore produces :#{derived} " <>
                 "for #{js_name}. Either fix the atom in method_defs or add #{js_name} to " <>
                 "known_divergences (handled by js_to_atom canonical mapping)."
      end
    end
  end

  test "endpoint_id returns nil for an incomplete endpoint config" do
    assert Unified.endpoint_id(%{}) == nil
  end

  # ---------------------------------------------------------------------------
  # split_opts/1
  # ---------------------------------------------------------------------------

  describe "split_opts/1" do
    test "separates dispatch opts from exchange params" do
      assert {:ok, {dispatch, extra}} =
               Unified.split_opts(endpoint_index: 1, symbol: "BTC", timeout: 5000)

      assert dispatch == [endpoint_index: 1, timeout: 5000]
      assert extra == [symbol: "BTC"]
    end

    test "returns empty dispatch opts when none present" do
      assert {:ok, {dispatch, extra}} = Unified.split_opts(symbol: "BTC", limit: 10)
      assert dispatch == []
      assert extra == [symbol: "BTC", limit: 10]
    end

    test "handles empty opts" do
      assert {:ok, {[], []}} = Unified.split_opts([])
    end

    test "HTTP-level opts are dispatch opts, not exchange params" do
      assert {:ok, {dispatch, extra}} =
               Unified.split_opts(headers: [{"x-test", "1"}], limit: 10, base_url: "https://example.com")

      assert Keyword.has_key?(dispatch, :headers)
      assert Keyword.has_key?(dispatch, :base_url)
      assert extra == [limit: 10]
    end

    test "market_type is a dispatch opt, not an exchange param" do
      assert {:ok, {dispatch, extra}} = Unified.split_opts(market_type: :spot, symbol: "BTC/USDT")
      assert dispatch == [market_type: :spot]
      assert extra == [symbol: "BTC/USDT"]
    end

    test "merges :params map into exchange params instead of passing params key through" do
      assert {:ok, {_dispatch, extra}} =
               Unified.split_opts(normalize: false, params: %{"currency" => "BTC", "interval" => "1d"})

      refute Keyword.has_key?(extra, :params)

      assert Unified.build_params([], [], extra) == %{
               "normalize" => false,
               "currency" => "BTC",
               "interval" => "1d"
             }
    end

    test "top-level opts override :params entries on conflict" do
      assert {:ok, {_dispatch, extra}} =
               Unified.split_opts(params: %{"currency" => "BTC"}, currency: "ETH")

      assert extra == [currency: "ETH"]
    end

    test "coerces map opts to exchange params" do
      assert {:ok, {[], extra}} = Unified.split_opts(%{"category" => "linear"})
      assert extra == [{"category", "linear"}]
    end

    test "coerces map opts with string params channel" do
      assert {:ok, {_dispatch, extra}} =
               Unified.split_opts(%{"params" => %{"currency" => "BTC"}, "interval" => "1d"})

      assert Unified.build_params([], [], extra) == %{"currency" => "BTC", "interval" => "1d"}
    end

    test "returns bad_request for invalid opts shape" do
      assert {:error, %Error{type: :bad_request} = error} = Unified.split_opts("not-opts")
      assert error.message =~ "keyword list or map"

      assert {:error, %Error{type: :bad_request}} = Unified.split_opts(%{{:invalid, :key} => true})
    end

    test "returns bad_request for malformed list opts before keyword splitting" do
      assert {:error, %Error{type: :bad_request} = error} = Unified.split_opts(["not-a-pair"])
      assert error.message =~ "keyword list or map"
    end

    test "returns bad_request when :params is not a map" do
      assert {:error, %Error{type: :bad_request} = error} = Unified.split_opts(params: "bad")
      assert error.message =~ ":params must be a map"
    end
  end

  test "raw_call reports an exchange without a generated module" do
    assert {:error, %Error{type: :not_supported}} =
             Unified.raw_call(%Exchange{id: "missing", name: "Missing"}, :fetch_ticker, %{})
  end

  describe "public unified API opts hardening" do
    test "Bourse-positional shapes rejected by our signatures return method-specific errors" do
      exchange = Exchange.new!("bybit")

      assert {:error, %Error{type: :bad_request, message: order_book_message}} =
               Bourse.fetch_order_book(exchange, "BTC/USDT", 5)

      assert order_book_message =~ "fetch_order_book"
      assert order_book_message =~ "limit: depth"
      refute order_book_message =~ "opts must be"

      assert {:error, %Error{type: :bad_request, message: adl_rank_message}} =
               Bourse.fetch_positions_adl_rank(exchange, ["BTC/USDT:USDT"])

      assert adl_rank_message =~ "fetch_positions_adl_rank"
      assert adl_rank_message =~ "symbols: [...]"
      refute adl_rank_message =~ "opts must be"

      assert {:error, %Error{type: :bad_request, message: orders_message}} =
               Bourse.fetch_orders_classic(exchange, "BTC/USDT")

      assert orders_message =~ "fetch_orders_classic"
      assert orders_message =~ "symbol: \"BTC/USDT\""
      refute orders_message =~ "opts must be"
    end

    test "positional guidance names the offending value" do
      exchange = Exchange.new!("bybit")

      assert {:error, %Error{message: message}} = Bourse.fetch_order_book(exchange, "BTC/USDT", 5)
      assert message =~ "got: 5"
    end

    test "a well-shaped opts failing on its :params channel keeps its own message" do
      exchange = Exchange.new!("bybit")

      assert {:error, %Error{type: :bad_request, message: message}} =
               Bourse.fetch_order_book(exchange, "BTC/USDT", params: "not-a-map")

      assert message =~ "opts :params must be a map"
      refute message =~ "limit: depth"
    end

    test "fetch_funding_rates with map opts does not raise" do
      stub = unique_stub("bybit_funding_map_opts")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"list" => []}})
      end)

      {:ok, exchange} = Exchange.new("bybit")

      result =
        Bourse.fetch_funding_rates(exchange, %{"category" => "linear", plug: {Req.Test, stub}})

      case result do
        {:ok, _} -> :ok
        {:error, %Error{}} -> :ok
        other -> flunk("unexpected result: #{inspect(other)}")
      end
    end

    test "fetch_funding_rates with invalid opts returns bad_request instead of raising" do
      {:ok, exchange} = Exchange.new("bybit")

      assert {:error, %Error{type: :bad_request}} = Bourse.fetch_funding_rates(exchange, 123)
      assert {:error, %Error{type: :bad_request}} = Bourse.fetch_funding_rates(exchange, ["not-a-pair"])
    end

    test "fetch_volatility_history merges :params into the venue query" do
      stub = unique_stub("deribit_volatility")
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => []})
      end)

      {:ok, exchange} = Exchange.new("deribit")

      assert {:ok, []} =
               Bourse.fetch_volatility_history(exchange, "BTC/USD:BTC",
                 params: %{"currency" => "BTC"},
                 plug: {Req.Test, stub}
               )

      conn = RequestCollector.one!(requests)
      assert conn.query_string =~ "currency=BTC"
      refute conn.query_string =~ "params="
    end

    test "fetch_volatility_history returns typed DVOL rows, not the raw envelope" do
      stub = unique_stub("deribit_volatility_typed")
      ts = 1_640_142_000_000
      vol = 63.828320460740585

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "result" => [[ts, vol], [ts + 3_600_000, 64.0]],
          "usIn" => 1,
          "usOut" => 2,
          "usDiff" => 1,
          "testnet" => false
        })
      end)

      {:ok, exchange} = Exchange.new("deribit")

      assert {:ok, [%Bourse.VolatilityHistory{} = first | rest]} =
               Bourse.fetch_volatility_history(exchange, "BTC",
                 params: %{"currency" => "BTC"},
                 plug: {Req.Test, stub}
               )

      assert first.timestamp == ts
      assert first.datetime == "2021-12-22T03:00:00.000Z"
      assert first.volatility == vol
      assert first.info == [ts, vol]
      assert length(rest) == 1
      # Never the raw HTTP/JSON-RPC envelope shape
      refute Map.has_key?(first, :status)
      refute Map.has_key?(first, :body)
    end

    test "fetch_volatility_history returns exchange errors as {:error, _}" do
      stub = unique_stub("deribit_volatility_err")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32_602, "message" => "Invalid params"},
          "testnet" => false
        })
      end)

      {:ok, exchange} = Exchange.new("deribit")

      # JSON-RPC -32602 "Invalid params" now resolves to Deribit's mapped
      # BadRequest exception (Bourse `exceptions["-32602"]`) via the real error
      # code, rather than the generic exchange-error fallback.
      assert {:error, %Error{type: :bad_request, code: -32_602}} =
               Bourse.fetch_volatility_history(exchange, "BTC",
                 params: %{"currency" => "NOT_A_COIN"},
                 plug: {Req.Test, stub}
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Param-value shape (task 587) — task 185's never-raise invariant at the
  # value layer. A keyword list / tuple / struct must not reach the signer.
  # ---------------------------------------------------------------------------

  describe "public unified API param-value hardening" do
    test "set_margin_mode with symbol: keyword returns invalid_parameters without raising" do
      {:ok, exchange} = Exchange.new("binanceusdm")

      assert {:error, %Error{type: :invalid_parameters} = error} =
               Bourse.set_margin_mode(exchange, "isolated", symbol: "ETH/USDT:USDT")

      assert error.message =~ ~s(invalid parameter "symbol")
      assert error.message =~ "positional argument of set_margin_mode/3"
      refute error.message =~ "Jason"
    end

    test "a keyword list in a binary positional slot names the positional convention" do
      {:ok, exchange} = Exchange.new("bybit")

      assert {:error, %Error{type: :invalid_parameters, message: message}} =
               Bourse.fetch_ticker(exchange, symbol: "BTC/USDT")

      assert message =~ ~s(invalid parameter "symbol")
      assert message =~ "positional argument of fetch_ticker/2"
      assert message =~ "not a keyword option"
      refute message =~ "Jason"
    end

    test "a keyword list in an extra param is a typed encode refusal, not a positional hint" do
      {:ok, exchange} = Exchange.new("bybit")

      assert {:error, %Error{type: :invalid_parameters, message: message}} =
               Bourse.fetch_ticker(exchange, "BTC/USDT", extra: [foo: 1])

      assert message =~ ~s(invalid parameter "extra")
      assert message =~ "keyword list"
      refute message =~ "positional argument"
    end

    test "public unified functions refuse non-encodable param values without raising" do
      {:ok, exchange} = Exchange.new("bybit")

      bad_values = [
        keyword_list: [symbol: "ETH/USDT:USDT"],
        tuple: {:symbol, "ETH/USDT:USDT"},
        struct: DateTime.utc_now()
      ]

      for {name, _js, required, _desc} <- Unified.method_defs(),
          {kind, bad} <- bad_values do
        args = [exchange | Enum.map(required, &dummy_required_value/1)] ++ [[probe: bad]]

        result =
          try do
            apply(Bourse, name, args)
          rescue
            exception ->
              flunk(
                "#{name} raised #{inspect(exception.__struct__)} for #{kind}: " <>
                  Exception.message(exception)
              )
          end

        assert {:error, %Error{type: :invalid_parameters} = error} = result,
               "#{name} (#{kind}) expected invalid_parameters, got: #{inspect(result)}"

        assert error.message =~ ~s(invalid parameter "probe")
        refute error.message =~ "Jason"
      end
    end
  end

  describe "validate_param_values/2" do
    test "accepts wire-encodable scalars, lists, and maps" do
      params = %{
        "symbol" => "BTC/USDT",
        "limit" => 10,
        "hedge_mode" => true,
        "category" => :linear,
        "ids" => ["a", "b"],
        "orders" => [%{"symbol" => "BTC/USDT", "amount" => 1}],
        "filter" => %{"min" => 1, "active" => false},
        "empty" => [],
        "none" => nil
      }

      assert {:ok, ^params} = Unified.validate_param_values(params, :create_order)
    end

    test "refuses a tuple, struct, or keyword list and names the param" do
      assert {:error, %Error{type: :invalid_parameters, message: tuple_message}} =
               Unified.validate_param_values(%{"probe" => {1, 2}}, :fetch_ticker)

      assert tuple_message =~ ~s(invalid parameter "probe")
      assert tuple_message =~ "tuple"

      assert {:error, %Error{type: :invalid_parameters, message: struct_message}} =
               Unified.validate_param_values(%{"probe" => DateTime.utc_now()}, :fetch_ticker)

      assert struct_message =~ "DateTime struct"

      assert {:error, %Error{type: :invalid_parameters, message: keyword_message}} =
               Unified.validate_param_values(%{"probe" => [foo: 1]}, :fetch_ticker)

      assert keyword_message =~ "keyword list"
      refute keyword_message =~ "positional argument"
    end

    test "a keyword list in a required binary slot names the positional convention" do
      assert {:error, %Error{type: :invalid_parameters, message: message}} =
               Unified.validate_param_values(
                 %{"margin_mode" => "isolated", "symbol" => [symbol: "ETH/USDT:USDT"]},
                 :set_margin_mode
               )

      assert message =~ ~s(invalid parameter "symbol")
      assert message =~ "positional argument of set_margin_mode/3"
      refute message =~ "Jason"
    end

    test "a keyword list in a required list slot is a generic encode refusal" do
      assert {:error, %Error{type: :invalid_parameters, message: message}} =
               Unified.validate_param_values(%{"orders" => [symbol: "BTC/USDT"]}, :create_orders)

      assert message =~ ~s(invalid parameter "orders")
      assert message =~ "keyword list"
      refute message =~ "positional argument"
    end
  end

  # ---------------------------------------------------------------------------
  # build_params/3
  # ---------------------------------------------------------------------------

  describe "build_params/3" do
    test "builds string-keyed map from required params" do
      params = Unified.build_params([:symbol, :type], ["BTC/USDT", "limit"], [])
      assert params == %{"symbol" => "BTC/USDT", "type" => "limit"}
    end

    test "merges extra opts into params" do
      params = Unified.build_params([:symbol], ["BTC/USDT"], limit: 100, since: 123)
      assert params == %{"symbol" => "BTC/USDT", "limit" => 100, "since" => 123}
    end

    test "required params take precedence over extra opts with same key" do
      params = Unified.build_params([:symbol], ["BTC/USDT"], symbol: "ETH/USDT")
      assert params == %{"symbol" => "BTC/USDT"}
    end

    test "handles empty required params" do
      params = Unified.build_params([], [], type: "spot")
      assert params == %{"type" => "spot"}
    end

    test "handles empty extra opts" do
      params = Unified.build_params([:id], ["order-123"], [])
      assert params == %{"id" => "order-123"}
    end
  end

  # ---------------------------------------------------------------------------
  # call/5 — error paths
  # ---------------------------------------------------------------------------

  describe "raw_call/4" do
    test "returns raw HTTP response without unified parsing" do
      stub = stub_json(%{"timeSecond" => 1_700_000_000}, "raw_call")

      exchange = %Exchange{
        id: "bybit",
        name: "Bybit",
        module: nil,
        base_urls: %{"public" => "https://api.bybit.com"}
      }

      assert {:ok, response} =
               Unified.raw_call(exchange, :fetch_time, %{}, plug: {Req.Test, stub})

      assert is_map(response)
    end

    test "bybit fetch_ticker injects V5 category before dispatch" do
      stub = unique_stub("bybit_ticker_category")
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"list" => []}})
      end)

      {:ok, exchange} = Exchange.new("bybit")

      assert {:ok, _response} =
               Unified.raw_call(exchange, :fetch_ticker, %{"symbol" => "BTC/USDT:USDT"}, plug: {Req.Test, stub})

      params = RequestCollector.query(requests)

      assert params["symbol"] == "BTCUSDT"
      assert params["category"] == "linear"
    end

    test "bybit fetch_open_orders retains a captured spot row after requested-symbol filtering" do
      stub = unique_stub("bybit_open_orders_spot")
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)

        Req.Test.json(conn, %{
          "retCode" => 0,
          "result" => %{
            "category" => "spot",
            "list" => [
              %{
                "avgPrice" => "",
                "createdTime" => "1784189372501",
                "cumExecQty" => "0",
                "cumExecValue" => "0",
                "orderId" => "demo-order-1",
                "orderStatus" => "New",
                "orderType" => "Limit",
                "price" => "10000",
                "qty" => "0.001",
                "side" => "Buy",
                "symbol" => "BTCUSDT",
                "updatedTime" => "1784189372501"
              }
            ]
          }
        })
      end)

      exchange =
        Exchange.new!("bybit", credentials: Bourse.Credentials.new!(api_key: "test-key", secret: "test-secret"))

      assert {:ok, [%Bourse.Order{id: "demo-order-1", status: "open", symbol: "BTC/USDT"}]} =
               Bourse.fetch_open_orders(exchange, symbol: "BTC/USDT", category: "spot", plug: {Req.Test, stub})

      conn = RequestCollector.one!(requests)
      assert conn.request_path == "/v5/order/realtime"
      assert URI.decode_query(conn.query_string) == %{"category" => "spot", "symbol" => "BTCUSDT"}
    end

    test "bybit fetch_markets raw_call selects one endpoint instead of crashing on param fan-out" do
      stub = unique_stub("bybit_raw_markets_param_fan_out")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"list" => [], "query" => conn.query_string}})
      end)

      {:ok, exchange} = Exchange.new("bybit")

      assert {:ok, %{body: %{"result" => %{"list" => []}}}} =
               Unified.raw_call(exchange, :fetch_markets, %{}, plug: {Req.Test, stub})
    end

    test "bybit fetch_ohlcv maps timeframe to V5 interval before dispatch" do
      stub = unique_stub("bybit_ohlcv_interval")
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"list" => []}})
      end)

      {:ok, exchange} = Exchange.new("bybit")

      assert {:ok, _response} =
               Unified.raw_call(exchange, :fetch_ohlcv, %{"symbol" => "BTC/USDT:USDT", "timeframe" => "1h"},
                 plug: {Req.Test, stub}
               )

      params = RequestCollector.query(requests)

      assert params["symbol"] == "BTCUSDT"
      assert params["category"] == "linear"
      assert params["interval"] == "60"
      refute Map.has_key?(params, "timeframe")
    end

    test "raw calls collapse authored broadcast and first-success plans to one endpoint" do
      credentials = Bourse.Credentials.new!(api_key: "test-key", secret: "test-secret")
      exchange = Exchange.new!("binance", credentials: credentials)

      for {method, params, expected_path} <- [
            {:cancel_all_orders, %{"symbol" => "BTC/USDT:USDT"}, "/fapi/v1/allOpenOrders"},
            {:cancel_order, %{"id" => "1", "symbol" => "BTC/USDT:USDT"}, "/fapi/v1/order"}
          ] do
        {stub, requests} = raw_request_stub(%{"code" => 200})

        assert {:ok, _response} =
                 Unified.raw_call(exchange, method, params, plug: {Req.Test, stub})

        assert RequestCollector.one!(requests).request_path == expected_path
      end
    end

    test "an explicit market id bypasses dynamic market lookup" do
      {stub, requests} = raw_request_stub(%{"code" => 200, "order_book_details" => []})
      exchange = Exchange.new!("lighter", sandbox: true)

      assert {:ok, _response} =
               Unified.raw_call(exchange, :fetch_ticker, %{"market_id" => 0}, plug: {Req.Test, stub})

      assert RequestCollector.query(requests)["market_id"] == "0"
    end

    test "COIN-M market discovery stays on the inverse provider surface" do
      {stub, requests} = raw_request_stub(%{"symbols" => []})

      assert {:ok, _response} =
               Unified.raw_call(Exchange.new!("binancecoinm"), :fetch_markets, %{}, plug: {Req.Test, stub})

      assert RequestCollector.one!(requests).request_path == "/dapi/v1/exchangeInfo"
    end
  end

  describe "request_param_shapes/4" do
    test "rebuilds every authored first-success request candidate" do
      credentials = Bourse.Credentials.new!(api_key: "test-key", secret: "test-secret")
      exchange = Exchange.new!("binance", credentials: credentials)

      assert {:ok,
              [
                %{"orderId" => "order-1", "symbol" => "BTCUSDT"},
                %{"algoId" => "order-1", "symbol" => "BTCUSDT"}
              ]} =
               Unified.request_param_shapes(exchange, :cancel_order, %{
                 "id" => "order-1",
                 "symbol" => "BTC/USDT:USDT"
               })
    end

    test "rebuilds every parameter fan-out variant" do
      assert {:ok, shapes} = Unified.request_param_shapes(Exchange.new!("bybit"), :fetch_markets, %{})

      assert Enum.map(shapes, & &1["category"]) ==
               ~w(spot linear inverse option option option option option option)

      option_shapes = Enum.drop(shapes, @bybit_non_option_category_count)
      assert Enum.map(option_shapes, & &1["baseCoin"]) == ~w(BTC ETH SOL XRP MNT DOGE)
      assert Enum.all?(option_shapes, &(&1["limit"] == @bybit_instruments_page_limit))
    end

    test "stops parameter fan-out when a variant cannot satisfy its request shape" do
      exchange = Exchange.new!("bybit")

      request_param_shape =
        put_in(
          exchange.request_param_shape,
          ["fetchMarkets", "market_id"],
          %{"kind" => "unresolved", "reason" => "dynamic_construction"}
        )

      exchange = %{exchange | request_param_shape: request_param_shape}

      assert {:error, %Error{type: :bad_symbol, message: message}} =
               Unified.request_param_shapes(exchange, :fetch_markets, %{})

      assert message == "bybit requires a known market symbol to resolve market_id"
    end
  end

  describe "capture_responses/4" do
    test "single-endpoint methods return the bare body response" do
      stub = stub_json(%{"timeSecond" => 1_700_000_000}, "capture_single")

      exchange = %Exchange{
        id: "bybit",
        name: "Bybit",
        module: nil,
        base_urls: %{"public" => "https://api.bybit.com"}
      }

      assert {:ok, response} =
               Unified.capture_responses(exchange, :fetch_time, %{}, plug: {Req.Test, stub})

      assert is_map(response)
      assert Map.has_key?(response, :body)
    end

    test "param fan-out tags each response with its API section and parameter variant" do
      stub = unique_stub("bybit_capture_markets_param_fan_out")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"list" => [], "query" => conn.query_string}})
      end)

      {:ok, exchange} = Exchange.new("bybit")
      expected_types = get_in(exchange.spec, ["options", "fetchMarkets", "types"]) || []
      expected_bases = get_in(exchange.spec, ["options", "fetchMarkets", "options"]) || []

      assert {:ok, responses} = Unified.capture_responses(exchange, :fetch_markets, %{}, plug: {Req.Test, stub})
      assert is_list(responses)
      assert length(responses) > 1

      Enum.each(responses, fn entry ->
        assert is_binary(entry["api"])
        assert %{"category" => category} = entry["params"]
        assert category in expected_types
        assert is_map(entry["body"])
      end)

      categories = Enum.map(responses, &get_in(&1, ["params", "category"]))
      assert Enum.sort(Enum.uniq(categories)) == Enum.sort(expected_types)
      assert "option" in categories

      option_bases =
        responses
        |> Enum.filter(&(get_in(&1, ["params", "category"]) == "option"))
        |> Enum.map(&get_in(&1, ["params", "baseCoin"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      assert option_bases == Enum.sort(expected_bases)
    end

    test "endpoint fan-out tags every Binance market response with its section" do
      stub = stub_json(%{"symbols" => []}, "capture_binance_market_sections")
      exchange = Exchange.new!("binance")

      assert {:ok, responses} = Unified.capture_responses(exchange, :fetch_markets, %{}, plug: {Req.Test, stub})

      assert is_list(responses)
      assert Enum.all?(responses, &match?(%{"api" => api, "body" => %{"symbols" => []}} when is_binary(api), &1))

      sections = MapSet.new(responses, & &1["api"])
      assert MapSet.subset?(MapSet.new(~w(public fapiPublic dapiPublic eapiPublic)), sections)
    end
  end

  describe "status response errors" do
    test "Bybit and OKX surface provider error envelopes and foreign response shapes" do
      for {exchange_id, body, expected_message} <- [
            {"bybit", %{"unexpected" => "bad"}, "Bybit status request failed"},
            {"okx", %{"unexpected" => "bad"}, "OKX status request failed"}
          ] do
        exchange = Exchange.new!(exchange_id)

        assert {:error, %Error{type: :exchange_error, message: ^expected_message}} =
                 Bourse.fetch_status(exchange, plug: {Req.Test, stub_json(body, "status_error")})

        assert {:error, {:unexpected_response_shape, "invalid"}} =
                 Bourse.fetch_status(exchange, plug: {Req.Test, stub_json("invalid", "status_shape")})
      end
    end

    test "OKX ignores unknown and non-map maintenance rows without inventing state" do
      body = %{
        "code" => "0",
        "data" => [%{"state" => "foreign", "end" => "123"}, "foreign"]
      }

      assert {:ok, %{status: "maintenance", eta: 123}} =
               Bourse.fetch_status(Exchange.new!("okx"),
                 plug: {Req.Test, stub_json(body, "status_unknown_rows")}
               )
    end
  end

  describe "Deribit ticker argument validation" do
    test "ignores malformed symbols and still requires one valid base or code" do
      exchange = Exchange.new!("deribit")

      for symbols <- [["not-a-unified-symbol"], [123]] do
        assert {:error, %Error{type: :bad_request, message: message}} =
                 Unified.call(exchange, :fetch_tickers, "fetchTickers", %{"symbols" => symbols}, [])

        assert message =~ "requires a non-empty symbols list or code"
      end
    end
  end

  describe "multi-endpoint selection branches" do
    test "Binance market-type strings select their matching public families" do
      for {type, expected_path} <- [
            {"linear", "/fapi/v1/ticker/24hr"},
            {"inverse", "/dapi/v1/ticker/24hr"},
            {"option", "/eapi/v1/ticker"}
          ] do
        {stub, requests} = raw_request_stub([])

        assert {:ok, %{body: []}} =
                 Unified.raw_call(Exchange.new!("binance"), :fetch_ticker, %{"type" => type}, plug: {Req.Test, stub})

        assert RequestCollector.one!(requests).request_path == expected_path
      end
    end

    test "Binance private families require credentials and honor swap/future signals" do
      assert {:error, %Error{type: :authentication_error, message: message}} =
               Unified.raw_call(Exchange.new!("binance"), :fetch_order_trades, %{"type" => "swap"})

      assert message =~ "fetchOrderTrades on binance resolves to authenticated endpoint"
      assert message =~ "credentials required"

      exchange = Exchange.new!("binance", api_key: "key", secret: "secret")

      for {type, expected_path} <- [
            {"swap", "/fapi/v1/userTrades"},
            {"delivery", "/dapi/v1/userTrades"}
          ] do
        {stub, requests} = raw_request_stub([])

        assert {:ok, %{body: []}} =
                 Unified.raw_call(exchange, :fetch_order_trades, %{"type" => type},
                   plug: {Req.Test, stub},
                   timestamp_ms_override: 1_700_000_000_000
                 )

        assert RequestCollector.one!(requests).request_path == expected_path
      end
    end

    test "market-family priority outranks endpoint config order" do
      {stub, requests} = raw_request_stub([])

      assert {:ok, %{body: []}} =
               Unified.raw_call(
                 Exchange.new!("binanceusdm"),
                 :fetch_open_interest_history,
                 %{"type" => "linear"},
                 plug: {Req.Test, stub}
               )

      request = RequestCollector.one!(requests)
      assert request.host == "fapi.binance.com"
      assert request.request_path == "/futures/data/openInterestHist"
    end

    test "a sole credential-reachable twin resolves without a family section" do
      {stub, requests} = raw_request_stub(%{"result" => %{"list" => []}, "retCode" => 0})

      assert {:ok, %{body: %{"retCode" => 0}}} =
               Unified.raw_call(Exchange.new!("bybit"), :fetch_option_markets, %{"category" => "option"},
                 plug: {Req.Test, stub}
               )

      assert RequestCollector.one!(requests).request_path == "/v5/market/instruments-info"
    end

    test "authored cases and market-type maps select their documented endpoints" do
      {deribit_stub, deribit_requests} = raw_request_stub(%{"jsonrpc" => "2.0", "result" => []})

      assert {:ok, _} =
               Unified.raw_call(
                 Exchange.new!("deribit"),
                 :fetch_trades,
                 %{"symbol" => "BTC/USD:BTC", "since" => 1_700_000_000_000},
                 plug: {Req.Test, deribit_stub}
               )

      assert RequestCollector.one!(deribit_requests).request_path =~ "get_last_trades_by_instrument_and_time"

      {okx_stub, okx_requests} = raw_request_stub(%{"code" => "0", "data" => []})

      assert {:ok, _} =
               Unified.raw_call(
                 Exchange.new!("okx"),
                 :fetch_open_interest_history,
                 %{"type" => "option"},
                 plug: {Req.Test, okx_stub}
               )

      assert RequestCollector.one!(okx_requests).request_path == "/api/v5/rubik/stat/option/open-interest-volume"
    end

    test "endpoint_index remains an explicit positional override" do
      exchange = Exchange.new!("binance")

      for {index, expected_path} <- [
            {1, "/eapi/v1/ticker"},
            {999, "/dapi/v1/ticker/24hr"}
          ] do
        {stub, requests} = raw_request_stub([])

        assert {:ok, _} =
                 Unified.raw_call(exchange, :fetch_ticker, %{}, endpoint_index: index, plug: {Req.Test, stub})

        assert RequestCollector.one!(requests).request_path == expected_path
      end
    end

    test "default-arity helpers preserve typed module-resolution errors" do
      exchange = build_fake_exchange(module: nil)

      assert {:error, %Error{type: :not_supported}} = Unified.load_markets(exchange)
      assert {:error, %Error{type: :not_supported}} = Unified.capture_responses(exchange, :fetch_markets, %{})
    end

    test "a public fetchMarkets fan-out fails clearly when every config is private" do
      exchange = build_fake_exchange(module: PrivateMarketExchange)

      assert {:error, %Error{type: :not_supported, message: message}} =
               Unified.capture_responses(exchange, :fetch_markets, %{})

      assert message == "fake_exchange has no public fetchMarkets endpoints"
    end

    test "raw_call collapses a market endpoint fan-out to one request" do
      {stub, requests} = raw_request_stub(%{"symbols" => []})

      assert {:ok, _} =
               Unified.raw_call(Exchange.new!("binance"), :fetch_markets, %{}, plug: {Req.Test, stub})

      assert length(RequestCollector.requests(requests)) == 1
    end

    test "Hyperliquid's configured create-order endpoint remains authentication-gated" do
      assert {:error, %Error{type: :authentication_error}} =
               Unified.raw_call(Exchange.new!("hyperliquid"), :create_order, %{})
    end

    test "malformed authored rules fall through to their valid default" do
      exchange = Exchange.new!("binance")

      exchange =
        put_in(exchange.endpoint_selection["fetchTicker"], %{
          "default" => "public_get_ticker_24hr",
          "rules" => [%{}]
        })

      {stub, requests} = raw_request_stub([])

      assert {:ok, _} = Unified.raw_call(exchange, :fetch_ticker, %{}, plug: {Req.Test, stub})
      assert RequestCollector.one!(requests).request_path == "/api/v3/ticker/24hr"
    end

    test "authored rules can select an endpoint when a parameter is absent" do
      exchange = Exchange.new!("binance")

      exchange =
        put_in(exchange.endpoint_selection["fetchTicker"], %{
          "default" => "public_get_ticker_24hr",
          "rules" => [
            %{
              "endpoint" => "fapiPublic_get_ticker_24hr",
              "when" => %{"type" => "absent"}
            }
          ]
        })

      {stub, requests} = raw_request_stub([])

      assert {:ok, _} = Unified.raw_call(exchange, :fetch_ticker, %{}, plug: {Req.Test, stub})
      assert RequestCollector.one!(requests).request_path == "/fapi/v1/ticker/24hr"
    end

    test "ambiguity errors name only parameter sets that resolve" do
      exchange = Exchange.new!("bybit", api_key: "key", secret: "secret")

      exchange = %{
        exchange
        | default_family: nil,
          endpoint_selection: Map.delete(exchange.endpoint_selection, "fetchOptionMarkets")
      }

      assert {:error, %Error{type: :bad_request, message: message}} =
               Unified.raw_call(exchange, :fetch_option_markets, %{})

      assert message =~ "ambiguous multi-endpoint selection"
      assert message =~ ~s(pass type: "spot")

      {stub, requests} = raw_request_stub(%{"retCode" => 0, "result" => %{"list" => []}})

      assert {:ok, _response} =
               Unified.raw_call(exchange, :fetch_option_markets, %{"type" => "spot"}, plug: {Req.Test, stub})

      assert RequestCollector.one!(requests).request_path == "/v5/market/instruments-info"
    end
  end

  describe "fan-out boundary failures" do
    test "endpoint fan-out stops on the first malformed parsed market response" do
      assert {:error, _reason} =
               Unified.call(
                 Exchange.new!("binance"),
                 :fetch_markets,
                 "fetchMarkets",
                 %{},
                 plug: {Req.Test, stub_json("invalid", "bad_market_fan_out")}
               )
    end

    test "parameter fan-out stops on the first malformed parsed market response" do
      stub = unique_stub("bad_market_param_fan_out")

      Req.Test.stub(stub, fn conn ->
        case URI.decode_query(conn.query_string)["category"] do
          "option" -> Req.Test.json(conn, %{"retCode" => 0, "result" => %{"list" => []}})
          _category -> Req.Test.json(conn, "invalid")
        end
      end)

      assert {:error, _reason} =
               Unified.call(
                 Exchange.new!("bybit"),
                 :fetch_markets,
                 "fetchMarkets",
                 %{},
                 plug: {Req.Test, stub}
               )
    end

    test "empty authored market variant sets fall back to a single request" do
      fixtures = [
        {"bybit", fn exchange -> put_in(exchange.spec["options"]["fetchMarkets"]["types"], []) end},
        {"okx", fn exchange -> put_in(exchange.spec["options"]["fetchMarkets"]["types"], []) end},
        {"derive", fn exchange -> %{exchange | request_defaults: %{}} end}
      ]

      for {exchange_id, update} <- fixtures do
        exchange = exchange_id |> Exchange.new!() |> update.()
        {stub, requests} = raw_request_stub(%{"result" => [], "data" => [], "instruments" => []})

        assert {:ok, _} = Unified.raw_call(exchange, :fetch_markets, %{}, plug: {Req.Test, stub})
        assert length(RequestCollector.requests(requests)) == 1
      end
    end

    test "invalid Bybit market variant values are ignored" do
      exchange = Exchange.new!("bybit")
      exchange = put_in(exchange.spec["options"]["fetchMarkets"]["types"], [nil])
      {stub, requests} = raw_request_stub(%{"result" => %{"list" => []}, "retCode" => 0})

      assert {:ok, _} = Unified.raw_call(exchange, :fetch_markets, %{}, plug: {Req.Test, stub})
      assert length(RequestCollector.requests(requests)) == 1
    end

    test "OKX option discovery fails on a foreign envelope or missing raw endpoint" do
      assert {:error, %Error{type: :exchange_error, message: message}} =
               Unified.capture_responses(Exchange.new!("okx"), :fetch_markets, %{},
                 plug: {Req.Test, stub_json(%{"unexpected" => true}, "bad_okx_underlyings")}
               )

      assert message =~ "Unexpected option underlying response"

      exchange = %{Exchange.new!("okx") | module: Bybit}

      assert {:error, %Error{type: :not_supported, message: missing_message}} =
               Unified.capture_responses(exchange, :fetch_markets, %{})

      assert missing_message =~ "does not expose public/underlying"
    end
  end

  describe "Bybit instruments pagination boundaries" do
    test "retains the next cursor when the page budget is exhausted" do
      stub = unique_stub("bybit_page_budget")

      Req.Test.stub(stub, fn conn ->
        cursor = conn.query_string |> URI.decode_query() |> Map.get("cursor")
        current = if cursor, do: String.to_integer(cursor), else: 0
        next = Integer.to_string(current + 1)

        Req.Test.json(conn, %{
          "retCode" => 0,
          "result" => %{"list" => [%{"symbol" => "BTCUSDT"}], "nextPageCursor" => next}
        })
      end)

      assert {:ok, %{body: %{"result" => %{"list" => rows, "nextPageCursor" => "21"}}}} =
               Unified.raw_call(
                 Exchange.new!("bybit"),
                 :fetch_future_markets,
                 %{"category" => "linear"},
                 plug: {Req.Test, stub}
               )

      assert length(rows) == 21
    end

    test "halts on a cursor page without a list" do
      stub = unique_stub("bybit_page_without_list")

      Req.Test.stub(stub, fn conn ->
        case URI.decode_query(conn.query_string)["cursor"] do
          nil ->
            Req.Test.json(conn, %{
              "retCode" => 0,
              "result" => %{"list" => [%{"symbol" => "BTCUSDT"}], "nextPageCursor" => "next"}
            })

          "next" ->
            Req.Test.json(conn, %{"retCode" => 0, "result" => %{"unexpected" => true}})
        end
      end)

      assert {:ok, %{body: %{"result" => %{"nextPageCursor" => "next"}}}} =
               Unified.raw_call(
                 Exchange.new!("bybit"),
                 :fetch_future_markets,
                 %{"category" => "linear"},
                 plug: {Req.Test, stub}
               )
    end

    test "surfaces a cursor-page transport failure" do
      stub = unique_stub("bybit_page_error")

      Req.Test.stub(stub, fn conn ->
        case URI.decode_query(conn.query_string)["cursor"] do
          nil ->
            Req.Test.json(conn, %{
              "retCode" => 0,
              "result" => %{"list" => [], "nextPageCursor" => "next"}
            })

          "next" ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "0")
            |> Plug.Conn.put_status(503)
            |> Req.Test.json(%{"error" => "unavailable"})
        end
      end)

      assert {:error, %Error{type: :exchange_not_available}} =
               Unified.raw_call(
                 Exchange.new!("bybit"),
                 :fetch_future_markets,
                 %{"category" => "linear"},
                 plug: {Req.Test, stub}
               )
    end
  end

  describe "call/5 error paths" do
    test "returns not_supported when module is nil and not in registry" do
      exchange = build_fake_exchange(id: "nonexistent_exchange")

      assert {:error, %Error{type: :not_supported}} =
               Unified.call(exchange, :fetch_ticker, "fetchTicker", %{}, [])
    end

    test "returns not_supported when method has no endpoint configs" do
      # Real module but a method that doesn't have endpoints mapped
      exchange = build_fake_exchange(module: Bybit)

      assert {:error, %Error{type: :not_supported} = error} =
               Unified.call(exchange, :fetch_nonexistent, "fetchNonexistent", %{}, [])

      assert error.message =~ "does not support"
    end

    test "error includes exchange id and capability name" do
      exchange = build_fake_exchange(module: Bybit, id: "bybit_test")

      assert {:error, %Error{type: :not_supported} = error} =
               Unified.call(exchange, :fetch_nonexistent, "fetchNonexistent", %{}, [])

      assert error.message =~ "bybit_test"
      assert error.message =~ "fetchNonexistent"
    end

    test "emulated reads preserve errors from their underlying unified method" do
      exchange = Exchange.new!("binancecoinm")

      assert {:error, %Error{type: :authentication_error, message: "Credentials required for fetch_orders"}} =
               Bourse.fetch_closed_orders(exchange, symbol: "BTC/USD:BTC")
    end
  end

  # ---------------------------------------------------------------------------
  # call/5 — dispatch does not gate on Exchange.has?
  # ---------------------------------------------------------------------------

  describe "margin argument contracts" do
    test "write return inventory covers every action method" do
      expected_methods =
        Unified.method_defs()
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(fn method ->
          method
          |> Atom.to_string()
          |> then(&Regex.match?(~r/^(add|borrow|cancel|close|create|edit|reduce|repay|set|transfer|withdraw)(_|$)/, &1))
        end)
        |> MapSet.new()

      assert MapSet.new(Map.keys(Unified.write_return_contracts())) == expected_methods

      assert %{
               add_margin: :unified_struct,
               reduce_margin: :unified_struct,
               close_position: :already_parsed_order_like,
               set_leverage: :venue_body,
               cancel_all_orders: :already_parsed_order_like
             } = Unified.write_return_contracts()
    end

    test "unparsed write methods return the venue body instead of the HTTP envelope" do
      stub = unique_stub("okx_set_leverage_body")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"code" => "0", "data" => [%{"instId" => "BTC-USDT-SWAP", "lever" => "5"}]})
      end)

      credentials = Bourse.Credentials.new!(api_key: "test-key", secret: "test-secret", password: "test-pass")
      exchange = Exchange.new!("okx", credentials: credentials)

      assert {:ok, %{"code" => "0", "data" => [%{"lever" => "5"}]}} =
               Bourse.set_leverage(exchange, 5, "BTC/USDT:USDT", plug: {Req.Test, stub})
    end

    test "unparsed write methods preserve venue business errors" do
      stub = unique_stub("okx_set_leverage_error")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"code" => "59102", "msg" => "Leverage exceeds the maximum"})
      end)

      credentials = Bourse.Credentials.new!(api_key: "test-key", secret: "test-secret", password: "test-pass")
      exchange = Exchange.new!("okx", credentials: credentials)

      assert {:error, %Error{code: "59102", raw: %{"code" => "59102"}}} =
               Bourse.set_leverage(exchange, 999, "BTC/USDT:USDT", plug: {Req.Test, stub})
    end

    test "aligns set_margin, add_margin, reduce_margin, and create_convert_trade with Bourse positional params" do
      assert Unified.required_params_for(:set_margin) == [:symbol, :amount]
      assert Unified.required_params_for(:add_margin) == [:symbol, :amount]
      assert Unified.required_params_for(:reduce_margin) == [:symbol, :amount]
      assert Unified.required_params_for(:create_convert_trade) == [:id, :from_code, :to_code, :amount]

      assert Unified.build_params([:symbol, :amount], ["BTC/USDT:USDT", 1], []) ==
               %{"symbol" => "BTC/USDT:USDT", "amount" => 1}

      assert Unified.build_params([:id, :from_code, :to_code, :amount], ["quote-id", "USDT", "BTC", 1], []) ==
               %{"id" => "quote-id", "from_code" => "USDT", "to_code" => "BTC", "amount" => 1}
    end

    for method <- [:set_margin, :add_margin, :reduce_margin] do
      test "#{method} raises a symbol error without issuing an HTTP request" do
        stub = unique_stub("okx_#{unquote(method)}_bad_symbol")
        test_pid = self()

        Req.Test.stub(stub, fn conn ->
          # Do not flunk here: Bourse.HTTP rescues plug exceptions as network errors.
          send(test_pid, {:request_issued, conn.method, conn.request_path})
          Req.Test.json(conn, %{"code" => "0", "data" => []})
        end)

        exchange = Exchange.new!("okx")

        assert_raise Bourse.Symbol.Error, ~r/Invalid symbol format/, fn ->
          apply(Bourse, unquote(method), [exchange, "not-a-symbol", 1, [plug: {Req.Test, stub}]])
        end

        refute_received {:request_issued, _method, _path}
      end
    end

    test "add_margin and reduce_margin return MarginModification structs" do
      stub = unique_stub("okx_add_margin_ok")
      {:ok, requests} = RequestCollector.start_link()

      # Task 342 authors symbol→instId and amount→amt for OKX addMargin. A resolvable
      # unified symbol must denormalize and dispatch under the native keys rather than
      # raise client-side (the bad-symbol cases above cover the reject path).
      Req.Test.stub(stub, fn conn ->
        {conn, body} = RequestCollector.capture_with_body(requests, conn)
        decoded = Jason.decode!(body)

        Req.Test.json(conn, %{
          "code" => "0",
          "data" => [
            %{
              "instId" => "BTC-USDT-SWAP",
              "type" => decoded["type"],
              "amt" => "1",
              "mgnMode" => "cross"
            }
          ]
        })
      end)

      creds = Bourse.Credentials.new!(api_key: "test-key", secret: "test-secret", password: "test-pass")
      exchange = Exchange.new!("okx", credentials: creds)

      assert {:ok, %Bourse.MarginModification{type: "add"}} =
               Bourse.add_margin(exchange, "BTC/USDT:USDT", 1, plug: {Req.Test, stub})

      assert {:ok, %Bourse.MarginModification{type: "reduce"}} =
               Bourse.reduce_margin(exchange, "BTC/USDT:USDT", 1, plug: {Req.Test, stub})

      for %{body: body} <- RequestCollector.requests(requests) do
        decoded = Jason.decode!(body)
        assert decoded["instId"] == "BTC-USDT-SWAP"
        assert decoded["amt"] == 1
        assert decoded["type"] in ["add", "reduce"]
        refute Map.has_key?(decoded, "symbol")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_denormalize_symbol/2 — Task 86
  # ---------------------------------------------------------------------------

  describe "maybe_denormalize_symbol/2" do
    test "spot symbol is denormalized to exchange-native form (Binance-style)" do
      exchange = binance_like_exchange()
      params = %{"symbol" => "BTC/USDT", "limit" => 10}
      assert %{"symbol" => "BTCUSDT", "limit" => 10} = Unified.maybe_denormalize_symbol(params, exchange)
    end

    test "swap symbol is denormalized (Binance linear perp)" do
      exchange = binance_like_exchange()

      assert %{"symbol" => "BTCUSDT"} =
               Unified.maybe_denormalize_symbol(%{"symbol" => "BTC/USDT:USDT"}, exchange)
    end

    test "swap symbol is denormalized to PERPETUAL suffix (Deribit)" do
      exchange = deribit_like_exchange()

      assert %{"symbol" => "BTC-PERPETUAL"} =
               Unified.maybe_denormalize_symbol(%{"symbol" => "BTC/USD:BTC"}, exchange)
    end

    test "no-op when params has no symbol key" do
      exchange = binance_like_exchange()
      assert %{"limit" => 10} == Unified.maybe_denormalize_symbol(%{"limit" => 10}, exchange)
    end

    test "no-op when symbol value is not a binary" do
      exchange = binance_like_exchange()

      assert %{"symbol" => :not_a_string} ==
               Unified.maybe_denormalize_symbol(%{"symbol" => :not_a_string}, exchange)
    end

    test "no-op when exchange has no symbol_patterns (graceful degradation)" do
      exchange = build_fake_exchange(id: "no_patterns_exchange")
      params = %{"symbol" => "BTC/USDT"}
      assert %{"symbol" => "BTC/USDT"} == Unified.maybe_denormalize_symbol(params, exchange)
    end

    test "other params pass through unchanged" do
      exchange = binance_like_exchange()

      result =
        Unified.maybe_denormalize_symbol(
          %{"symbol" => "BTC/USDT", "since" => 123, "limit" => 10, "type" => "spot"},
          exchange
        )

      assert result == %{"symbol" => "BTCUSDT", "since" => 123, "limit" => 10, "type" => "spot"}
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_merge_request_defaults/3 — Task 90
  # ---------------------------------------------------------------------------

  describe "maybe_merge_request_defaults/3" do
    test "merges literal defaults when method matches and params is empty" do
      exchange = hyperliquid_like_exchange()

      assert %{"type" => "exchangeStatus"} ==
               Unified.maybe_merge_request_defaults(%{}, exchange, "fetchTime")
    end

    test "caller-supplied params override defaults (Map.put_new semantics)" do
      exchange = hyperliquid_like_exchange()
      params = %{"type" => "spotMeta"}

      assert %{"type" => "spotMeta"} ==
               Unified.maybe_merge_request_defaults(params, exchange, "fetchTime")
    end

    test "merges defaults into params alongside unrelated caller keys" do
      exchange = hyperliquid_like_exchange()
      params = %{"coin" => "BTC"}

      assert %{"type" => "exchangeStatus", "coin" => "BTC"} ==
               Unified.maybe_merge_request_defaults(params, exchange, "fetchTime")
    end

    test "no-op when method has no entry on the exchange" do
      exchange = hyperliquid_like_exchange()
      assert %{} == Unified.maybe_merge_request_defaults(%{}, exchange, "unknownMethod")
    end

    test "no-op when exchange has empty request_defaults map (graceful degradation)" do
      exchange = build_fake_exchange(id: "no_defaults")
      params = %{"coin" => "BTC"}
      assert params == Unified.maybe_merge_request_defaults(params, exchange, "fetchTime")
    end

    test "real hyperliquid spec materializes fetchTime default from structure.request_defaults" do
      {:ok, ex} = Exchange.new("hyperliquid")
      assert %{"type" => "exchangeStatus"} == ex.request_defaults["fetchTime"]
    end

    test "real hyperliquid spec materializes /info request_defaults for fetchMarkets/fetchTicker (T191)" do
      {:ok, ex} = Exchange.new("hyperliquid")
      # Task 370 (carve C-T370-1): fetchMarkets asks for metaAndAssetCtxs so the
      # price tick can be derived from the ctx mark/mid.
      assert %{"type" => "metaAndAssetCtxs"} == ex.request_defaults["fetchMarkets"]
      assert %{"type" => "metaAndAssetCtxs"} == ex.request_defaults["fetchTicker"]
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_translate_timeframe/2 — Task 136
  # ---------------------------------------------------------------------------

  describe "maybe_translate_timeframe/2" do
    test "translates unified OHLCV label via capabilities.timeframes (Bybit 1h -> 60)" do
      {:ok, exchange} = Exchange.new("bybit")

      assert %{"timeframe" => "60", "symbol" => "BTC/USDT"} =
               Unified.maybe_translate_timeframe(%{"timeframe" => "1h", "symbol" => "BTC/USDT"}, exchange)
    end

    test "identity mapping passes through unchanged (Binance 1h -> 1h)" do
      {:ok, exchange} = Exchange.new("binance")

      assert %{"timeframe" => "1h"} =
               Unified.maybe_translate_timeframe(%{"timeframe" => "1h"}, exchange)
    end

    test "carries a numeric native timeframe verbatim" do
      exchange = %{build_fake_exchange(id: "numeric_timeframe") | timeframes: %{"1m" => 1}}

      assert %{"timeframe" => 1, "symbol" => "BTC/USD"} =
               Unified.maybe_translate_timeframe(%{"timeframe" => "1m", "symbol" => "BTC/USD"}, exchange)
    end

    test "raises ArgumentError for unknown unified timeframe when map is present" do
      {:ok, exchange} = Exchange.new("bybit")

      assert_raise ArgumentError, ~r/unsupported timeframe "99y"/, fn ->
        Unified.maybe_translate_timeframe(%{"timeframe" => "99y"}, exchange)
      end
    end

    test "no-op when exchange has empty timeframes map (graceful degradation)" do
      exchange = build_fake_exchange(id: "no_timeframes")
      params = %{"timeframe" => "1h"}
      assert params == Unified.maybe_translate_timeframe(params, exchange)
    end

    test "no-op when params has no timeframe key" do
      {:ok, exchange} = Exchange.new("bybit")
      assert %{"symbol" => "BTC/USDT"} == Unified.maybe_translate_timeframe(%{"symbol" => "BTC/USDT"}, exchange)
    end
  end

  describe "call/5 response normalization" do
    test "gate: vendored first-class field maps include a resolved ticker slot" do
      assert %{"_unresolved_reason" => nil, "field_map" => field_map} =
               Bourse.Bybit.__field_maps__()["ticker"]

      assert is_map(field_map)
      assert is_map(field_map["last"])
    end

    test "parses a resolved single-object read response into the unified struct" do
      stub =
        stub_json(%{
          "symbol" => "BTCUSDT",
          "lastPrice" => "65000.00",
          "bid1Price" => "64999.00",
          "ask1Price" => "65001.00"
        })

      {:ok, exchange} = Exchange.new("bybit")

      assert {:ok, %Bourse.Ticker{symbol: "BTC/USDT", last: 65_000.0, bid: 64_999.0, ask: 65_001.0}} =
               Unified.call(exchange, :fetch_ticker, "fetchTicker", %{"symbol" => "BTC/USDT"}, plug: {Req.Test, stub})
    end

    test "parses a resolved list read response into unified structs" do
      stub =
        stub_json([
          %{"tradeId" => "1", "fillPx" => "12.5", "fillSz" => "0.4", "ordId" => "order-1", "side" => "buy"},
          %{"tradeId" => "2", "fillPx" => "13.5", "fillSz" => "0.5", "ordId" => "order-2", "side" => "sell"}
        ])

      {:ok, exchange} = Exchange.new("okx")

      # OKX `parseTrade` reads fillPx/fillSz via safeNumber (CCXT compatibility fixture
      # records numeric price/amount, e.g. 73239.3 / 0.0009478) — the authored
      # okx trade field map coerces to numbers to stay tier-2 compatible.
      assert {:ok,
              [
                %Bourse.Trade{id: "1", price: 12.5, amount: 0.4, order_id: "order-1", side: "buy"},
                %Bourse.Trade{id: "2", price: 13.5, amount: 0.5, order_id: "order-2", side: "sell"}
              ]} =
               Unified.call(exchange, :fetch_trades, "fetchTrades", %{"symbol" => "BTC/USDT"}, plug: {Req.Test, stub})
    end

    test "parses Bybit public trade price, amount, timestamp, and id from result.list" do
      stub =
        stub_json(%{
          "retCode" => 0,
          "result" => %{
            "list" => [
              %{
                "execId" => "trade-1",
                "price" => "62531.40",
                "size" => "0.088",
                "side" => "Sell",
                "symbol" => "BTCUSDT",
                "time" => "1784021853044"
              }
            ]
          }
        })

      {:ok, exchange} = Exchange.new("bybit")

      assert %{"branches" => [_private_branch, public_branch]} = Bourse.Bybit.__field_maps__()["trade"]

      assert %{
               "field_map" => %{
                 "id" => %{"key" => "execId"},
                 "amount" => %{"key" => "size", "fallback_keys" => ["execQty", "orderQty"]},
                 "price" => %{"key" => "price", "fallback_keys" => ["execPrice", "orderPrice"]},
                 "timestamp" => %{"key" => "time", "fallback_keys" => ["execTime", "tradeTime"]}
               }
             } = public_branch

      assert {:ok,
              [
                %Bourse.Trade{
                  id: "trade-1",
                  symbol: "BTC/USDT:USDT",
                  price: 62_531.4,
                  amount: 0.088,
                  timestamp: 1_784_021_853_044
                }
              ]} =
               Unified.call(
                 exchange,
                 :fetch_trades,
                 "fetchTrades",
                 %{"symbol" => "BTC/USDT:USDT", "category" => "linear"},
                 plug: {Req.Test, stub}
               )
    end

    test "parses the Balances descriptor alias through the balance slot" do
      stub =
        stub_json(%{
          "result" => %{
            "list" => [
              %{
                "coin" => [
                  %{"coin" => "USDT", "walletBalance" => "2.0", "availableToWithdraw" => "1.5", "locked" => "0.5"}
                ]
              }
            ]
          }
        })

      {:ok, exchange} = Exchange.new("bybit", api_key: "key", secret: "secret")

      assert {:ok, %Bourse.Balance{total: %{"USDT" => 2.0}, free: %{"USDT" => 1.5}, used: %{"USDT" => 0.5}}} =
               Unified.call(exchange, :fetch_balance, "fetchBalance", %{}, plug: {Req.Test, stub})
    end

    test "parses fetch_markets into market structs with symbol backfill when field map is resolved" do
      assert %{"_unresolved_reason" => nil, "field_map" => field_map} = Bourse.Binance.__field_maps__()["market"]
      assert is_map(field_map)

      raw_markets = [%{"symbol" => "BTCUSDT", "baseAsset" => "BTC", "quoteAsset" => "USDT"}]
      stub = stub_json(%{"symbols" => raw_markets})
      {:ok, exchange} = Exchange.new("binance")

      assert {:ok, markets} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      refute markets == []
      assert Enum.all?(markets, &match?(%Bourse.Market{symbol: "BTC/USDT"}, &1))
    end

    test "binance inverse-perp raw market normalizes to settle form without trailing slash (task 167)" do
      raw_markets = [
        %{
          "symbol" => "BTCUSD_PERP",
          "baseAsset" => "BTC",
          "quoteAsset" => "USD",
          "marginAsset" => "BTC",
          "contractType" => "PERPETUAL",
          "contractSize" => "100"
        }
      ]

      # endpoint_index pins a single markets endpoint so fan-out does not multiply the stub.
      stub = stub_json(%{"symbols" => raw_markets})
      {:ok, exchange} = Exchange.new("binance")

      assert {:ok, [%Bourse.Market{} = market]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{},
                 endpoint_index: 0,
                 plug: {Req.Test, stub}
               )

      assert market.symbol == "BTC/USD:BTC"
      assert market.base == "BTC"
      assert market.quote == "USD"
      assert market.settle == "BTC"
      assert market.id == "BTCUSD_PERP"
      refute String.ends_with?(market.symbol, "/")
      refute market.symbol == "BTCUSD_PERP"
      refute market.symbol == "BTCUSD_PERP/"
    end

    test "binance spot and linear symbols still normalize without trailing slash" do
      spot_stub =
        stub_json(%{"symbols" => [%{"symbol" => "ETHUSDT", "baseAsset" => "ETH", "quoteAsset" => "USDT"}]})

      linear_stub =
        stub_json(%{
          "symbols" => [
            %{
              "symbol" => "BTCUSDT",
              "baseAsset" => "BTC",
              "quoteAsset" => "USDT",
              "marginAsset" => "USDT",
              "contractType" => "PERPETUAL"
            }
          ]
        })

      {:ok, exchange} = Exchange.new("binance")

      assert {:ok, [%Bourse.Market{symbol: "ETH/USDT"}]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{},
                 endpoint_index: 3,
                 plug: {Req.Test, spot_stub}
               )

      assert {:ok, [%Bourse.Market{symbol: "BTC/USDT:USDT"}]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{},
                 endpoint_index: 0,
                 plug: {Req.Test, linear_stub}
               )
    end

    test "hyperliquid fetch_markets fans out swap + spot /info bodies and unwraps universe markets" do
      stub = unique_stub("hyperliquid_markets_meta")
      {:ok, requests} = RequestCollector.start_link()

      # Task 370 (carve C-T370-2): bare fetch_markets fans out metaAndAssetCtxs +
      # spotMetaAndAssetCtxs. The spot leg answers with an empty universe so this
      # test still pins exactly one swap row.
      Req.Test.stub(stub, fn conn ->
        {conn, body} = RequestCollector.capture_with_body(requests, conn)

        case Jason.decode!(body) do
          %{"type" => "metaAndAssetCtxs"} ->
            Req.Test.json(conn, [
              %{
                "universe" => [
                  %{"name" => "BTC", "maxLeverage" => 50, "szDecimals" => 5, "onlyIsolated" => false}
                ]
              },
              [%{"markPx" => "50000.5", "midPx" => "50001.0", "funding" => "0.0001"}]
            ])

          %{"type" => "spotMetaAndAssetCtxs"} ->
            Req.Test.json(conn, [%{"tokens" => [], "universe" => []}, []])
        end
      end)

      {:ok, exchange} = Exchange.new("hyperliquid")

      assert {:ok,
              [
                %Bourse.Market{
                  symbol: "BTC/USDC:USDC",
                  base: "BTC",
                  asset_index: 0,
                  info: %{"name" => "BTC"}
                }
              ]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      for %{conn: conn} <- RequestCollector.requests(requests) do
        assert conn.request_path == "/info"
        assert conn.method == "POST"
      end
    end

    test "hyperliquid fetch_balance sends credential-derived account /info body" do
      {stub, requests} =
        stub_hyperliquid_info_body(
          "hyperliquid_balance_info",
          %{
            "marginSummary" => %{"accountValue" => "999.0", "totalMarginUsed" => "0.0"},
            "time" => 1_700_000_000_000,
            "withdrawable" => "999.0"
          }
        )

      {:ok, exchange} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert {:ok, %Bourse.Balance{} = balance} =
               Unified.call(exchange, :fetch_balance, "fetchBalance", %{}, plug: {Req.Test, stub})

      assert_hyperliquid_info_request(requests, %{
        "type" => "clearinghouseState",
        "user" => "0xwallet"
      })

      assert balance.free["USDC"] == 999.0
      assert balance.total["USDC"] == 999.0
      assert balance.used["USDC"] == 0.0
      refute Map.has_key?(balance.total, "usdc")
      assert Bourse.Balance.get(balance, "USDC") == %{free: 999.0, used: 0.0, total: 999.0}
    end

    test "hyperliquid fetch_positions sends credential-derived account /info body" do
      {stub, requests} =
        stub_hyperliquid_info_body(
          "hyperliquid_positions_info",
          %{
            "assetPositions" => []
          }
        )

      {:ok, exchange} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert {:ok, _} = Unified.call(exchange, :fetch_positions, "fetchPositions", %{}, plug: {Req.Test, stub})

      assert_hyperliquid_info_request(requests, %{
        "type" => "clearinghouseState",
        "user" => "0xwallet"
      })
    end

    test "hyperliquid fetch_open_orders sends credential-derived account /info body" do
      {stub, requests} = stub_hyperliquid_info_body("hyperliquid_open_orders_info", [])

      {:ok, exchange} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert {:ok, _} = Unified.call(exchange, :fetch_open_orders, "fetchOpenOrders", %{}, plug: {Req.Test, stub})

      assert_hyperliquid_info_request(requests, %{
        "type" => "frontendOpenOrders",
        "user" => "0xwallet"
      })
    end

    test "hyperliquid fetch_trades is not_supported and points to fetch_my_trades (T219)" do
      {:ok, exchange} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert Exchange.has?(exchange, "fetchTrades") == false
      assert Bourse.Hyperliquid.__unified_endpoint__(:fetch_trades) == []

      assert {:error, %Error{type: :not_supported} = error} =
               Unified.call(exchange, :fetch_trades, "fetchTrades", %{"symbol" => "ETH/USDC:USDC"}, [])

      assert error.message =~ "fetch_my_trades"
      assert error.message =~ "hyperliquid"
    end

    test "hyperliquid fetch_my_trades sends userFills body without since (T219)" do
      {stub, requests} = stub_hyperliquid_info_body("hyperliquid_my_trades_user_fills", [])

      {:ok, exchange} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert {:ok, _} =
               Unified.call(exchange, :fetch_my_trades, "fetchMyTrades", %{}, plug: {Req.Test, stub})

      assert_hyperliquid_info_request(requests, %{
        "type" => "userFills",
        "user" => "0xwallet"
      })
    end

    test "hyperliquid fetch_my_trades sends userFillsByTime + startTime when since present (T219)" do
      since = 1_704_262_888_911

      {stub, requests} = stub_hyperliquid_info_body("hyperliquid_my_trades_by_time", [])

      {:ok, exchange} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert {:ok, _} =
               Unified.call(
                 exchange,
                 :fetch_my_trades,
                 "fetchMyTrades",
                 %{"since" => since},
                 plug: {Req.Test, stub}
               )

      assert_hyperliquid_info_request(requests, %{
        "type" => "userFillsByTime",
        "user" => "0xwallet",
        "startTime" => since
      })
    end

    test "returns error for exchange error envelopes instead of all-nil structs" do
      stub =
        stub_json(%{
          "retCode" => 10_006,
          "retMsg" => "error",
          "result" => %{"list" => []}
        })

      {:ok, exchange} = Exchange.new("bybit")

      assert {:error, %Error{}} =
               Unified.call(exchange, :fetch_trades, "fetchTrades", %{"symbol" => "BTC/USDT"}, plug: {Req.Test, stub})
    end

    test "returns error when list parse yields only empty structs" do
      stub = stub_json([%{}])
      {:ok, exchange} = Exchange.new("okx")

      # ReadParse.normalize_error/2 wraps the internal {:empty_parse, _} tuple in a
      # %Bourse.Error{} at the public boundary (raw carries the all-nil structs).
      assert {:error, %Error{message: message}} =
               Unified.call(exchange, :fetch_trades, "fetchTrades", %{"symbol" => "BTC/USDT"}, plug: {Req.Test, stub})

      assert message =~ "Unexpected response shape"
      assert message =~ "all-nil"
    end
  end

  describe "call/5 — binance fetch_markets multi-endpoint fan-out" do
    test "fans out to all market-type endpoints and unions parsed markets" do
      request_count = :counters.new(1, [:atomics])
      stub = binance_fetch_markets_fan_out_stub(request_count)
      {:ok, exchange} = Exchange.new("binance")

      assert {:ok, markets} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      symbols = markets |> Enum.map(& &1.symbol) |> Enum.uniq()
      assert "BTC/USDT" in symbols
      assert "BTC/USD:BTC" in symbols
      assert Enum.any?(symbols, &String.contains?(&1, "251226"))
      refute Enum.any?(symbols, &String.ends_with?(&1, "/"))
      assert length(markets) == 4
      assert :counters.get(request_count, 1) == 4
    end

    test "endpoint_index selects a single endpoint without fan-out" do
      request_count = :counters.new(1, [:atomics])
      stub = binance_fetch_markets_counting_stub(request_count)
      {:ok, exchange} = Exchange.new("binance")

      assert {:ok, [%Bourse.Market{symbol: "BTC/USDT"}]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, endpoint_index: 3, plug: {Req.Test, stub})

      assert :counters.get(request_count, 1) == 1
    end

    # OKX's fetchMarkets has a single endpoint config, so it never does the
    # multi-ENDPOINT fan-out above — but it does one PARAM wave per authored
    # market type (instType), since OKX lists instruments per instrument type.
    # OPTION is additionally expanded to one wave per live underlying (task 269),
    # so the static SPOT/FUTURES/SWAP waves are joined by one wave per `uly`.
    test "single-config exchange fans out over params, not endpoints" do
      request_count = :counters.new(1, [:atomics])
      stub = okx_fetch_markets_counting_stub(request_count, ["BTC-USD", "ETH-USD"])
      {:ok, exchange} = Exchange.new("okx")

      assert {:ok, [%Bourse.Market{} | _]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      assert :counters.get(request_count, 1) == 5
    end

    test "single-config exchange dispatches once when the caller pins an instrument type" do
      request_count = :counters.new(1, [:atomics])
      stub = counting_stub(request_count, [%{"instId" => "BTC-USDT", "baseCcy" => "BTC", "quoteCcy" => "USDT"}])
      {:ok, exchange} = Exchange.new("okx")

      assert {:ok, [%Bourse.Market{} | _]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{"instType" => "SPOT"}, plug: {Req.Test, stub})

      assert :counters.get(request_count, 1) == 1
    end

    test "a single failing endpoint fails the whole fan-out (Promise.all semantics)" do
      stub = unique_stub("binance_markets_partial_fail")

      Req.Test.stub(stub, fn conn ->
        if conn.request_path =~ "/fapi/" do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"message" => "unavailable"})
        else
          Req.Test.json(conn, %{"symbols" => [%{"symbol" => "BTCUSDT", "baseAsset" => "BTC", "quoteAsset" => "USDT"}]})
        end
      end)

      {:ok, exchange} = Exchange.new("binance")

      assert {:error, _} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})
    end
  end

  describe "call/5 — shortlist fetch_markets carve (task 195)" do
    test "bybit unwraps result.list, fans out categories, and backfills symbols" do
      request_count = :counters.new(1, [:atomics])
      stub = unique_stub("bybit_fetch_markets_carve")

      Req.Test.stub(stub, fn conn ->
        :counters.add(request_count, 1, 1)
        query = URI.decode_query(conn.query_string)
        category = query["category"]

        body =
          case category do
            "linear" ->
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "BTCUSDT",
                      "baseCoin" => "BTC",
                      "quoteCoin" => "USDT",
                      "settleCoin" => "USDT",
                      "contractType" => "LinearPerpetual",
                      "status" => "Trading"
                    }
                  ]
                }
              }

            "option" ->
              base = query["baseCoin"] || "BTC"

              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "#{base}-25JUN27-45000-P-USDT",
                      "baseCoin" => base,
                      "quoteCoin" => "USDT",
                      "settleCoin" => "USDT",
                      "optionsType" => "Put",
                      "status" => "Trading"
                    }
                  ]
                }
              }

            _ ->
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "ETHUSDT",
                      "baseCoin" => "ETH",
                      "quoteCoin" => "USDT",
                      "status" => "Trading"
                    }
                  ]
                }
              }
          end

        Req.Test.json(conn, body)
      end)

      {:ok, exchange} = Exchange.new("bybit")
      types = get_in(exchange.spec, ["options", "fetchMarkets", "types"]) || []
      bases = get_in(exchange.spec, ["options", "fetchMarkets", "options"]) || []
      expected_requests = length(types) - 1 + max(length(bases), 1)

      assert {:ok, markets} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      symbols = Enum.map(markets, & &1.symbol)
      assert "BTC/USDT:USDT" in symbols
      assert "ETH/USDT" in symbols
      assert Enum.any?(markets, &(&1.type == "option"))
      assert "BTC/USDT:USDT-270625-45000-P" in symbols

      assert Enum.all?(markets, fn %Bourse.Market{symbol: sym, info: info} ->
               is_binary(sym) and is_map(info) and map_size(info) > 0
             end)

      assert :counters.get(request_count, 1) == expected_requests
    end

    test "bybit category fan-out survives credentials (param fan-out precedes config fan-out)" do
      # With credentials the private+public endpoint configs both survive
      # filtering; config-level fan-out would dispatch each WITHOUT a category
      # (both defaulting to spot -> duplicated spot rows, no derivatives).
      test_pid = self()
      stub = unique_stub("bybit_fetch_markets_with_creds")

      Req.Test.stub(stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        category = query["category"]
        send(test_pid, {:fan_out_request, query})

        body =
          case category do
            "linear" ->
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "BTCUSDT",
                      "baseCoin" => "BTC",
                      "quoteCoin" => "USDT",
                      "settleCoin" => "USDT",
                      "contractType" => "LinearPerpetual",
                      "status" => "Trading"
                    }
                  ]
                }
              }

            "option" ->
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "BTC-25JUN27-45000-P-USDT",
                      "baseCoin" => query["baseCoin"] || "BTC",
                      "quoteCoin" => "USDT",
                      "settleCoin" => "USDT",
                      "optionsType" => "Put",
                      "status" => "Trading"
                    }
                  ]
                }
              }

            _ ->
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "ETHUSDT",
                      "baseCoin" => "ETH",
                      "quoteCoin" => "USDT",
                      "status" => "Trading"
                    }
                  ]
                }
              }
          end

        Req.Test.json(conn, body)
      end)

      creds = Bourse.Credentials.new!(api_key: "test-key", secret: "test-secret")
      {:ok, exchange} = Exchange.new("bybit", credentials: creds)
      types = get_in(exchange.spec, ["options", "fetchMarkets", "types"]) || []
      bases = get_in(exchange.spec, ["options", "fetchMarkets", "options"]) || []
      expected_requests = length(types) - 1 + max(length(bases), 1)

      assert {:ok, markets} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      requests =
        for _ <- 1..expected_requests do
          assert_receive {:fan_out_request, query}
          query
        end

      categories = Enum.map(requests, & &1["category"])
      assert Enum.sort(Enum.uniq(categories)) == Enum.sort(types)
      assert "option" in categories

      option_bases =
        requests
        |> Enum.filter(&(&1["category"] == "option"))
        |> Enum.map(& &1["baseCoin"])
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      assert option_bases == Enum.sort(bases)
      refute_receive {:fan_out_request, _}

      symbols = Enum.map(markets, & &1.symbol)
      assert "BTC/USDT:USDT" in symbols
      assert Enum.count(symbols, &(&1 == "ETH/USDT")) == 2
      assert Enum.any?(markets, &(&1.type == "option"))
    end

    test "bybit fetch_markets option fan-out is derived from describe types + baseCoin list" do
      # Pins the request plan so option cannot silently drop from the fan-out set
      # again (task 251). Categories come from options.fetchMarkets.types; option
      # expands with options.fetchMarkets.options baseCoin values (live 2026-07-16:
      # bare category=option only returns BTC — baseCoin loop is required).
      test_pid = self()
      stub = unique_stub("bybit_fetch_markets_option_fan_out")

      Req.Test.stub(stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:option_fan_out, query})

        body =
          case query["category"] do
            "option" ->
              base = query["baseCoin"] || "BTC"

              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "#{base}-25JUN27-45000-P-USDT",
                      "baseCoin" => base,
                      "quoteCoin" => "USDT",
                      "settleCoin" => "USDT",
                      "optionsType" => "Put",
                      "status" => "Trading"
                    },
                    %{
                      "symbol" => "#{base}-25JUN27-45000-C-USDT",
                      "baseCoin" => base,
                      "quoteCoin" => "USDT",
                      "settleCoin" => "USDT",
                      "optionsType" => "Call",
                      "status" => "Delivering"
                    }
                  ]
                }
              }

            "linear" ->
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "BTCUSDT",
                      "baseCoin" => "BTC",
                      "quoteCoin" => "USDT",
                      "settleCoin" => "USDT",
                      "contractType" => "LinearPerpetual",
                      "status" => "Trading"
                    }
                  ]
                }
              }

            _ ->
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [
                    %{
                      "symbol" => "ETHUSDT",
                      "baseCoin" => "ETH",
                      "quoteCoin" => "USDT",
                      "status" => "Trading"
                    }
                  ]
                }
              }
          end

        Req.Test.json(conn, body)
      end)

      {:ok, exchange} = Exchange.new("bybit")
      types = get_in(exchange.spec, ["options", "fetchMarkets", "types"])
      bases = get_in(exchange.spec, ["options", "fetchMarkets", "options"])

      assert is_list(types) and "option" in types
      assert is_list(bases) and bases != []

      expected_requests = length(types) - 1 + length(bases)

      assert {:ok, markets} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      queries =
        for _ <- 1..expected_requests do
          assert_receive {:option_fan_out, query}
          query
        end

      refute_receive {:option_fan_out, _}

      assert Enum.sort(Enum.uniq(Enum.map(queries, & &1["category"]))) == Enum.sort(types)

      option_queries = Enum.filter(queries, &(&1["category"] == "option"))
      assert length(option_queries) == length(bases)
      assert Enum.all?(option_queries, &is_binary(&1["baseCoin"]))
      assert Enum.sort(Enum.map(option_queries, & &1["baseCoin"])) == Enum.sort(bases)
      assert Enum.all?(option_queries, &(&1["limit"] == "1000"))

      option_markets = Enum.filter(markets, &(&1.type == "option"))
      assert option_markets != []

      # Carve C13: non-Trading rows stay in the index (CCXT-JS drops them unless
      # loadAllOptions) and carry their tradeability in `active` — never nil,
      # which would claim the venue's own status enum is unknown to us.
      by_status = Map.new(option_markets, &{&1.info["status"], &1.active})
      assert by_status == %{"Trading" => true, "Delivering" => false}

      market = Enum.find(option_markets, &(&1.info["status"] == "Trading"))
      assert is_binary(market.symbol)
      assert market.option == true

      # Symbol round-trip: unified row -> to_exchange_id matches venue-native id
      native = Bourse.Symbol.to_exchange_id(market.symbol, exchange)
      assert native == market.info["symbol"]
      assert String.contains?(native, "-")
    end

    # Bybit instruments-info omits PreLaunch rows from a default-status read, so
    # Bourse issues paired default+PreLaunch requests per category and concatenates.
    # Live testnet 2026-07-17: linear 724 default + 22 PreLaunch = 746. A
    # default-only fan-out silently under-reports.
    test "bybit fetch_future_markets fans out linear+inverse across default and PreLaunch status" do
      stub = unique_stub("bybit_future_markets_waves")
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:wave, {query["category"], query["status"], query["limit"]}})

        row = bybit_linear_instrument("#{query["category"]}#{query["status"]}USDT")
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{"list" => [row], "nextPageCursor" => ""}})
      end)

      {:ok, exchange} = Exchange.new("bybit")

      assert {:ok, markets} =
               Unified.call(exchange, :fetch_future_markets, "fetchFutureMarkets", %{}, plug: {Req.Test, stub})

      # Four waves: {linear, inverse} x {default, PreLaunch}, each carrying limit=1000.
      assert length(markets) == 4

      for category <- ["linear", "inverse"], status <- [nil, "PreLaunch"] do
        assert_received {:wave, {^category, ^status, "1000"}}
      end
    end

    defp bybit_linear_instrument(symbol) do
      %{
        "symbol" => symbol,
        "baseCoin" => String.replace_suffix(symbol, "USDT", ""),
        "quoteCoin" => "USDT",
        "settleCoin" => "USDT",
        "contractType" => "LinearPerpetual",
        "status" => "Trading"
      }
    end

    # The instruments walk merges every page's rows into the first response. The
    # merged envelope must answer for the LAST page walked: a stale page-1 cursor
    # would report a fully-walked surface as truncated (and vice versa), which is
    # exactly the signal the option completeness guard keys off.
    test "bybit fetch_markets pagination merges pages and reports the last page's cursor" do
      stub = unique_stub("bybit_markets_cursor_walk")
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:page_query, query})

        body =
          case {query["category"], query["cursor"]} do
            {"linear", nil} ->
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [bybit_linear_instrument("BTCUSDT")],
                  "nextPageCursor" => "page2"
                }
              }

            {"linear", "page2"} ->
              # Final page — venue reports an empty cursor: the surface is complete.
              %{
                "retCode" => 0,
                "result" => %{
                  "list" => [bybit_linear_instrument("ETHUSDT")],
                  "nextPageCursor" => ""
                }
              }

            _ ->
              %{"retCode" => 0, "result" => %{"list" => [], "nextPageCursor" => ""}}
          end

        Req.Test.json(conn, body)
      end)

      {:ok, exchange} = Exchange.new("bybit")

      assert {:ok, markets} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      # Both pages' rows survive the merge — the walk did not stop at page 1.
      ids = markets |> Enum.map(& &1.info["symbol"]) |> Enum.sort()
      assert "BTCUSDT" in ids
      assert "ETHUSDT" in ids

      assert_received {:page_query, %{"category" => "linear", "cursor" => "page2"}}
    end

    test "bybit fetch_markets fails loudly when an option page remains" do
      stub = unique_stub("bybit_option_markets_incomplete")

      Req.Test.stub(stub, fn conn ->
        query = URI.decode_query(conn.query_string)

        body =
          if query["category"] == "option" do
            %{"retCode" => 0, "result" => %{"list" => [], "nextPageCursor" => "0%2C1000"}}
          else
            %{"retCode" => 0, "result" => %{"list" => []}}
          end

        Req.Test.json(conn, body)
      end)

      {:ok, exchange} = Exchange.new("bybit")

      assert {:error, %Error{type: :exchange_error, message: message}} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      assert message =~ "Bybit option markets are incomplete"
      assert message =~ "nextPageCursor=0%2C1000"
    end

    # The bare-option fallback (describe carries no baseCoin list) must obey the
    # same completeness contract as the per-base waves — it is the one option
    # request that carries no `baseCoin` to key the guard off, so an
    # `%{"category" => "option", "baseCoin" => _}`-shaped guard would let it
    # truncate at the venue's 500-row default in silence.
    test "bybit fetch_markets bare-option fallback still carries the limit and honours the cursor" do
      stub = unique_stub("bybit_option_markets_bare")
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:bare_option_query, query})

        body =
          if query["category"] == "option" do
            %{"retCode" => 0, "result" => %{"list" => [], "nextPageCursor" => "0%2C500"}}
          else
            %{"retCode" => 0, "result" => %{"list" => []}}
          end

        Req.Test.json(conn, body)
      end)

      {:ok, exchange} = Exchange.new("bybit")
      exchange = put_in(exchange.spec["options"]["fetchMarkets"]["options"], [])

      assert {:error, %Error{type: :exchange_error, message: message}} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})

      assert message =~ "Bybit option markets are incomplete for all base coins"

      assert_received {:bare_option_query, %{"category" => "option", "limit" => "1000"} = query}
      refute Map.has_key?(query, "baseCoin")
    end

    test "empty list-return envelope is a valid empty success, not an all-nil struct error" do
      # Live-observed 2026-07-15: deribit fetch_positions with zero open
      # positions handed the raw envelope to the parser (result [] triggered
      # the try-fallbacks miss), erroring with {:empty_parse, _}. bybit shows
      # the same symptom for a different reason (fetchPositions envelope slice
      # unauthored — task 223), so only the envelope mechanism is pinned here.
      deribit_stub = unique_stub("deribit_empty_positions")

      Req.Test.stub(deribit_stub, fn conn ->
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => []})
      end)

      creds = Bourse.Credentials.new!(api_key: "test-key", secret: "test-secret")
      {:ok, deribit} = Exchange.new("deribit", credentials: creds)

      assert {:ok, []} =
               Unified.call(deribit, :fetch_positions, "fetchPositions", %{}, plug: {Req.Test, deribit_stub})
    end

    test "deribit unwraps jsonrpc result and backfills instrument_name symbols" do
      stub = unique_stub("deribit_fetch_markets_carve")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "result" => [
            %{
              "instrument_name" => "BTC-PERPETUAL",
              "base_currency" => "BTC",
              "counter_currency" => "USD",
              "settlement_currency" => "BTC",
              "kind" => "future",
              "settlement_period" => "perpetual",
              "is_active" => true,
              "taker_commission" => 0.0005,
              "maker_commission" => 0.0,
              "contract_size" => 10.0,
              "tick_size" => 0.5,
              "min_trade_amount" => 10.0
            }
          ]
        })
      end)

      {:ok, exchange} = Exchange.new("deribit")

      assert {:ok, [%Bourse.Market{symbol: "BTC/USD:BTC", info: %{"instrument_name" => "BTC-PERPETUAL"}}]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})
    end

    test "lighter unwraps order_book_details and backfills perp symbols" do
      stub = unique_stub("lighter_fetch_markets_carve")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "code" => 200,
          "order_book_details" => [
            %{
              "symbol" => "ETH",
              "market_id" => 0,
              "market_type" => "perp",
              "taker_fee" => "0.0001",
              "maker_fee" => "0.0000",
              "min_base_amount" => "0.01",
              "min_quote_amount" => "0.1",
              "size_decimals" => "4",
              "price_decimals" => "4"
            }
          ]
        })
      end)

      {:ok, exchange} = Exchange.new("lighter")

      assert {:ok, [%Bourse.Market{symbol: "ETH/USDC:USDC", info: %{"symbol" => "ETH"}}]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})
    end

    test "hyperliquid backfills swap symbols from the name field" do
      stub = unique_stub("hyperliquid_fetch_markets_symbol")

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case Jason.decode!(body) do
          %{"type" => "metaAndAssetCtxs"} ->
            Req.Test.json(conn, [
              %{
                "universe" => [
                  %{"name" => "BTC", "maxLeverage" => 50, "szDecimals" => 5, "onlyIsolated" => false}
                ]
              },
              [%{"markPx" => "50000.5", "midPx" => "50001.0"}]
            ])

          %{"type" => "spotMetaAndAssetCtxs"} ->
            Req.Test.json(conn, [%{"tokens" => [], "universe" => []}, []])
        end
      end)

      {:ok, exchange} = Exchange.new("hyperliquid")

      assert {:ok, [%Bourse.Market{symbol: "BTC/USDC:USDC", info: %{"name" => "BTC"}}]} =
               Unified.call(exchange, :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, stub})
    end
  end

  describe "call/5 — binance fetch_ticker endpoint selection" do
    test "spot symbol routes to the spot public section, not dapi/fapi" do
      # Assert on the distinguishing path segment — both spot (/api/v3/ticker)
      # and fapi (/fapi/v1/ticker/24hr) paths contain "ticker", so a 200 alone
      # would not prove the spot section was selected.
      {stub, requests} = unique_binance_ticker_stub()
      {:ok, exchange} = Exchange.new("binance")

      assert {:ok, response} =
               Unified.call(exchange, :fetch_ticker, "fetchTicker", %{"symbol" => "BTC/USDT"}, plug: {Req.Test, stub})

      assert %Bourse.Ticker{symbol: "BTC/USDT", last: 65_000.0} = response

      path = RequestCollector.one!(requests).request_path
      assert path =~ "ticker"
      refute path =~ "fapi"
    end

    test "swap symbol routes to the fapiPublic section" do
      {stub, requests} = unique_binance_ticker_stub()
      {:ok, exchange} = Exchange.new("binance")

      assert {:ok, response} =
               Unified.call(exchange, :fetch_ticker, "fetchTicker", %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, stub}
               )

      assert %Bourse.Ticker{symbol: "BTC/USDT:USDT", last: 65_000.0} = response

      path = RequestCollector.one!(requests).request_path
      assert path =~ "ticker"
      assert path =~ "fapi"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Constructs a minimal fake exchange for error path tests.
  # For tests needing real exchange behavior, use Exchange.new/2 instead.
  defp build_fake_exchange(opts) do
    %Exchange{
      id: Keyword.get(opts, :id, "fake_exchange"),
      name: "Fake",
      module: Keyword.get(opts, :module)
    }
  end

  # Minimal exchange with Binance-style patterns (no separator, upper case,
  # spot/swap/future omit suffix).
  defp binance_like_exchange do
    %Exchange{
      id: "binance_like",
      name: "BinanceLike",
      symbol_patterns: %{
        spot: %{pattern: :no_separator_upper, separator: "", case: :upper, date_format: nil, suffix: nil, prefix: nil},
        swap: %{pattern: :implicit, separator: "", case: :upper, date_format: nil, suffix: nil, prefix: nil}
      }
    }
  end

  # Hyperliquid-style: only request_defaults are relevant for the merge helper.
  defp hyperliquid_like_exchange do
    %Exchange{
      id: "hyperliquid_like",
      name: "HyperliquidLike",
      request_defaults: %{
        "fetchTime" => %{"type" => "exchangeStatus"},
        "fetchMarkets" => %{"type" => "meta"}
      }
    }
  end

  # Deribit: dash-separated, PERPETUAL suffix, USD-quote base-only shorthand.
  defp deribit_like_exchange do
    %Exchange{
      id: "deribit_like",
      name: "DeribitLike",
      symbol_patterns: %{
        swap: %{
          pattern: :suffix_perpetual,
          separator: "-",
          case: :upper,
          date_format: nil,
          suffix: "-PERPETUAL",
          prefix: nil
        }
      }
    }
  end

  defp binance_fetch_markets_fan_out_stub(request_count) do
    stub = unique_stub("binance_markets_fan_out")

    Req.Test.stub(stub, fn conn ->
      :counters.add(request_count, 1, 1)

      body =
        cond do
          conn.request_path =~ "/dapi/" ->
            %{
              "symbols" => [
                %{
                  "symbol" => "BTCUSD_PERP",
                  "baseAsset" => "BTC",
                  "quoteAsset" => "USD",
                  "marginAsset" => "BTC",
                  "contractType" => "PERPETUAL"
                }
              ]
            }

          conn.request_path =~ "/fapi/" ->
            %{
              "symbols" => [
                %{
                  "symbol" => "BTCUSDT",
                  "baseAsset" => "BTC",
                  "quoteAsset" => "USDT",
                  "marginAsset" => "USDT",
                  "contractType" => "PERPETUAL"
                }
              ]
            }

          conn.request_path =~ "/eapi/" ->
            %{"symbols" => [%{"symbol" => "BTC-251226-90000-C", "baseAsset" => "BTC", "quoteAsset" => "USDT"}]}

          conn.request_path =~ "margin" ->
            %{"symbols" => []}

          true ->
            %{"symbols" => [%{"symbol" => "BTCUSDT", "baseAsset" => "BTC", "quoteAsset" => "USDT"}]}
        end

      Req.Test.json(conn, body)
    end)

    stub
  end

  defp binance_fetch_markets_counting_stub(request_count) do
    stub = unique_stub("binance_markets_count")

    Req.Test.stub(stub, fn conn ->
      :counters.add(request_count, 1, 1)
      Req.Test.json(conn, %{"symbols" => [%{"symbol" => "BTCUSDT", "baseAsset" => "BTC", "quoteAsset" => "USDT"}]})
    end)

    stub
  end

  # Counts only the `public/instruments` waves; the dependent `public/underlying`
  # discovery read is answered with the venue's own nested-list `data` shape.
  defp okx_fetch_markets_counting_stub(request_count, underlyings) do
    stub = unique_stub("okx_markets_counting")

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/api/v5/public/underlying" ->
          Req.Test.json(conn, %{"code" => "0", "data" => [underlyings]})

        "/api/v5/public/instruments" ->
          :counters.add(request_count, 1, 1)
          Req.Test.json(conn, [%{"instId" => "BTC-USDT", "baseCcy" => "BTC", "quoteCcy" => "USDT"}])
      end
    end)

    stub
  end

  defp counting_stub(request_count, response_body) do
    stub = unique_stub("counting")

    Req.Test.stub(stub, fn conn ->
      :counters.add(request_count, 1, 1)
      Req.Test.json(conn, response_body)
    end)

    stub
  end

  defp unique_binance_ticker_stub do
    stub = unique_stub("binance_ticker")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      Req.Test.json(conn, %{
        "symbol" => "BTCUSDT",
        "lastPrice" => "65000.00",
        "closeTime" => 1_700_000_000_000
      })
    end)

    {stub, requests}
  end

  defp raw_request_stub(response_body) do
    stub = unique_stub("raw_request")
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, response_body)
    end)

    {stub, requests}
  end

  defp stub_json(response_body, prefix \\ "unified") do
    stub = unique_stub(prefix)

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, response_body)
    end)

    stub
  end

  defp stub_hyperliquid_info_body(prefix, response_body) do
    stub = unique_stub(prefix)
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      Req.Test.json(conn, response_body)
    end)

    {stub, requests}
  end

  # Runs in the test process after the call returns, so the diagnostic naming the
  # wrong path, method or body survives Bourse.HTTP's transport rescue.
  defp assert_hyperliquid_info_request(requests, expected_body) do
    conn = RequestCollector.one!(requests)
    assert conn.request_path == "/info"
    assert conn.method == "POST"
    assert RequestCollector.json_body!(requests) == expected_body
  end

  defp unique_stub(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp dummy_required_value(:orders), do: [%{"symbol" => "BTC/USDT"}]
  defp dummy_required_value(:ids), do: ["id"]
  defp dummy_required_value(:hedge_mode), do: true

  defp dummy_required_value(name) when name in [:amount, :leverage, :timeout, :duration, :cost], do: 1

  defp dummy_required_value(_name), do: "dummy"
end
