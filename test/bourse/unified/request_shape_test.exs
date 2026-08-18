defmodule Bourse.Unified.RequestShapeTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.ReferenceSlice
  alias Bourse.Signing.Hyperliquid
  alias Bourse.Unified.RequestShape
  alias Bourse.Unified.RequestShape.Bybit

  @receive_timeout_ms 1_000

  describe "apply/3" do
    test "returns params unchanged for non-exchange inputs" do
      params = %{"symbol" => "BTC/USDT"}

      assert RequestShape.apply(params, :not_an_exchange, "fetchTicker") == params
      assert RequestShape.apply_premarket(params, :not_an_exchange, "fetchTicker") == params
    end

    test "returns params unchanged when premarket category is not authored" do
      {:ok, exchange} = Exchange.new("okx")
      params = %{"symbol" => "BTC/USDT"}

      assert RequestShape.apply_premarket(params, exchange, "fetchTicker") == params
    end

    test "ignores unknown request-shape entries" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{"fetchTicker" => %{"unknown" => %{"reason" => "not_supported"}}}
      }

      assert RequestShape.apply(%{}, exchange, "fetchTicker") == %{}
    end

    test "rejects an invalid builder before request shaping" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{"fetchTicker" => %{"_builder" => "missing_builder"}}
      }

      error =
        assert_raise ArgumentError, fn ->
          RequestShape.apply(%{}, exchange, "fetchTicker")
        end

      assert error.message =~ "exchange shape_test"
      assert error.message =~ "method fetchTicker"
      assert error.message =~ ~s(builder "missing_builder")
    end

    test "rejects a known builder on the wrong venue or method" do
      for {exchange_id, method} <- [{"bybit", "createOrders"}, {"binance", "fetchTicker"}] do
        exchange = %Exchange{
          id: exchange_id,
          name: "Shape Test",
          request_param_shape: %{method => %{"_builder" => "binance_batch_orders"}}
        }

        assert_raise ArgumentError,
                     ~r/exchange #{exchange_id} method #{method} builder "binance_batch_orders"/,
                     fn -> RequestShape.apply_premarket(%{}, exchange, method) end
      end
    end

    test "raises when a unified source is not emitted by the method" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{
          "fetchTicker" => %{"symbol" => %{"source" => "ticker", "source_class" => "unified_param"}}
        }
      }

      assert_raise ArgumentError, ~r/exchange shape_test method fetchTicker source ticker/, fn ->
        RequestShape.apply(%{"symbol" => "BTC/USDT"}, exchange, "fetchTicker")
      end
    end

    test "renames denormalized symbol to instId for okx fetchTicker defaults" do
      {:ok, exchange} = Exchange.new("okx")

      params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => "BTC/USDT"}, exchange)

      assert %{"instId" => "BTC-USDT"} = RequestShape.apply(params, exchange, "fetchTicker")
      refute Map.has_key?(RequestShape.apply(params, exchange, "fetchTicker"), "symbol")
    end

    # These drive the PUBLIC unified path (Bourse.fetch_*) and assert the request OKX
    # actually receives. Asserting RequestShape.apply/3 on hand-built native params
    # would test params the unified layer never produces — every shape below was
    # first confirmed against the OKX EEA demo (my.okx.com) on 2026-07-16.
    defp okx_request(fun, markets \\ nil) do
      creds = Credentials.new!(api_key: "test-key", secret: "test-secret", password: "passphrase")
      exchange = Exchange.new!("okx", credentials: creds)
      exchange = if is_list(markets), do: Exchange.put_markets(exchange, markets), else: exchange
      test_pid = self()
      stub = {__MODULE__, :okx_request, System.unique_integer([:positive])}

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        query = URI.decode_query(conn.query_string || "")
        send(test_pid, {:okx_request, conn.request_path, query, body})
        Req.Test.json(conn, %{"code" => "0", "data" => []})
      end)

      fun.(exchange, %{plug: {Req.Test, stub}})

      receive do
        {:okx_request, path, query, body} -> %{path: path, query: query, body: body}
      after
        @receive_timeout_ms -> flunk("no OKX request captured")
      end
    end

    test "defaults OKX instrument types from the venue's own tables" do
      assert %{query: %{"instType" => "SPOT"}} = okx_request(&Bourse.fetch_tickers(&1, &2))
      assert %{query: %{"instType" => "SWAP"}} = okx_request(&Bourse.fetch_mark_prices(&1, &2))
      assert %{query: %{"instType" => "SWAP"}} = okx_request(&Bourse.fetch_open_interests(&1, &2))
    end

    test "derives OKX trading-fee instrument type and family from the symbol's market type" do
      # SPOT keys on instId...
      assert %{query: %{"instType" => "SPOT", "instId" => "BTC-USDT"}} =
               okx_request(&Bourse.fetch_trading_fee(&1, "BTC/USDT", &2))

      # ...a derivative keys on instFamily; instId there is rejected with 50016.
      swap = okx_request(&Bourse.fetch_trading_fee(&1, "BTC/USDT:USDT", &2))
      assert swap.query["instType"] == "SWAP"
      assert swap.query["instFamily"] == "BTC-USDT"
      refute Map.has_key?(swap.query, "instId")
    end

    test "defaults OKX leverage margin mode to cross rather than leaking the instrument id" do
      assert %{query: %{"instId" => "BTC-USDT-SWAP", "mgnMode" => "cross"}} =
               okx_request(&Bourse.fetch_leverage(&1, "BTC/USDT:USDT", &2))
    end

    test "defaults OKX borrow-interest margin mode to cross so the read reaches the wire" do
      assert %{query: %{"mgnMode" => "cross"}} = okx_request(&Bourse.fetch_borrow_interest(&1, &2))
    end

    test "maps OKX borrow-interest currency code to ccy" do
      assert %{query: %{"ccy" => "USDT", "mgnMode" => "cross"}} =
               okx_request(&Bourse.fetch_borrow_interest(&1, Map.put(&2, "code", "USDT")))
    end

    test "threads the OKX transfer id and margin-adjustment sub type" do
      assert %{query: %{"transId" => "12345"}} = okx_request(&Bourse.fetch_transfer(&1, "12345", &2))

      # Optional code is not a transfer-state wire field (GET /asset/transfer-state).
      assert %{query: query} =
               okx_request(&Bourse.fetch_transfer(&1, "0", Map.put(&2, "code", "USDC")))

      assert query["transId"] == "0"
      refute Map.has_key?(query, "code")
      refute Map.has_key?(query, "params")

      assert %{query: %{"subType" => "160", "mgnMode" => "isolated"}} =
               okx_request(&Bourse.fetch_margin_adjustment_history(&1, Map.put(&2, "type", "add")))

      assert %{query: %{"subType" => "161"}} =
               okx_request(&Bourse.fetch_margin_adjustment_history(&1, Map.put(&2, "type", "reduce")))
    end

    test "maps OKX convert-trade history id to clTReqId" do
      assert %{query: %{"clTReqId" => "12AB34"}} =
               okx_request(&Bourse.fetch_convert_trade(&1, "12AB34", &2))
    end

    test "asks OKX for a full order book by default and honours an explicit limit" do
      default = okx_request(&Bourse.fetch_order_book(&1, "BTC/USDT", &2))
      assert default.query["sz"] == "100"
      refute Map.has_key?(default.query, "limit")

      limited = okx_request(&Bourse.fetch_order_book(&1, "BTC/USDT", Map.put(&2, "limit", 5)))
      assert limited.query["sz"] == "5"
      refute Map.has_key?(limited.query, "limit")
    end

    test "maps OKX transfer accounts to the venue's numeric account ids" do
      %{body: body} = okx_request(&Bourse.transfer(&1, "USDT", 1, "funding", "trading", &2))
      decoded = JSON.decode!(body)

      assert decoded["ccy"] == "USDT"
      # OKX documents amt as String on POST /api/v5/asset/transfer.
      assert decoded["amt"] == "1"
      assert decoded["from"] == "6"
      assert decoded["to"] == "18"
      assert decoded["type"] == "0"
      # The unified vocabulary must not ride along to the venue.
      refute Map.has_key?(decoded, "from_account")
      refute Map.has_key?(decoded, "code")
    end

    # Task 342 — non-convert identifier_reference renames (ccy/toAddr/depId/wdId/ordId/…).
    # Task 484 — amt is a documented String on OKX withdrawal (C-T484b).
    test "maps OKX withdraw code/amount/address to ccy/amt/toAddr" do
      {:ok, exchange} = Exchange.new("okx")

      # withdraw fans out through asset/currencies first (network/fee lookup), so the
      # full dispatch may not hit the withdrawal POST in a one-shot plug capture.
      # Pin the authored request-shape itself — dest=4 is the vendored on-chain literal.
      shaped =
        RequestShape.apply(
          %{"code" => "USDT", "amount" => 1, "address" => "invalid-addr-task-342"},
          exchange,
          "withdraw"
        )

      assert shaped["ccy"] == "USDT"
      assert shaped["amt"] == "1"
      assert shaped["toAddr"] == "invalid-addr-task-342"
      assert shaped["dest"] == "4"
      refute Map.has_key?(shaped, "code")
      refute Map.has_key?(shaped, "address")
      refute Map.has_key?(shaped, "amount")
    end

    test "maps OKX borrow/repay currency and amount under ccy/amt" do
      %{body: borrow} = okx_request(&Bourse.borrow_cross_margin(&1, "USDT", 1, &2))
      assert JSON.decode!(borrow) == %{"ccy" => "USDT", "amt" => 1, "side" => "borrow"}

      %{body: repay} = okx_request(&Bourse.repay_cross_margin(&1, "USDT", 1, &2))
      assert JSON.decode!(repay) == %{"ccy" => "USDT", "amt" => 1, "side" => "repay"}

      %{body: repay_ord} =
        okx_request(&Bourse.repay_cross_margin(&1, "USDT", 1, Map.put(&2, "id", "ord-1")))

      assert JSON.decode!(repay_ord) == %{
               "ccy" => "USDT",
               "amt" => 1,
               "side" => "repay",
               "ordId" => "ord-1"
             }
    end

    test "keeps unsupported OKX single-record histories disabled and maps deposit-address currency" do
      {:ok, exchange} = Exchange.new("okx")

      refute exchange.has["fetchDeposit"]
      refute exchange.has["fetchWithdrawal"]

      assert %{query: %{"ccy" => "USDT"}} =
               okx_request(&Bourse.fetch_deposit_addresses_by_network(&1, "USDT", &2))
    end

    test "maps OKX order id and symbol to ordId and instId" do
      # fetch_order is a GET; cancel_order is a POST. Both require the same renames.
      assert %{query: %{"ordId" => "123", "instId" => "BTC-USDT"}} =
               okx_request(&Bourse.fetch_order(&1, "123", Map.put(&2, "symbol", "BTC/USDT")))

      %{body: body} =
        okx_request(&Bourse.cancel_order(&1, "123", Map.put(&2, "symbol", "BTC/USDT")))

      assert JSON.decode!(body) == %{"ordId" => "123", "instId" => "BTC-USDT"}
    end

    test "maps OKX leverage, margin-mode, close-position and position-mode natives" do
      %{body: lev} = okx_request(&Bourse.set_leverage(&1, 5, "BTC/USDT:USDT", &2))

      assert JSON.decode!(lev) == %{
               "lever" => 5,
               "mgnMode" => "cross",
               "instId" => "BTC-USDT-SWAP"
             }

      %{body: mgn} =
        okx_request(&Bourse.set_margin_mode(&1, "isolated", "BTC/USDT:USDT", Map.put(&2, "leverage", 10)))

      assert JSON.decode!(mgn) == %{
               "mgnMode" => "isolated",
               "lever" => 10,
               "instId" => "BTC-USDT-SWAP"
             }

      %{body: close} = okx_request(&Bourse.close_position(&1, "BTC/USDT:USDT", &2))
      assert JSON.decode!(close) == %{"instId" => "BTC-USDT-SWAP", "mgnMode" => "cross"}

      # Dual-mode close: unified buy/sell → OKX posSide long/short.
      %{body: close_short} =
        okx_request(&Bourse.close_position(&1, "ADA/USDT:USDT", Map.put(&2, "side", "sell")))

      assert JSON.decode!(close_short) == %{
               "instId" => "ADA-USDT-SWAP",
               "mgnMode" => "cross",
               "posSide" => "short"
             }

      %{body: close_long} =
        okx_request(&Bourse.close_position(&1, "ADA/USDT:USDT", Map.put(&2, "side", "buy")))

      assert JSON.decode!(close_long) == %{
               "instId" => "ADA-USDT-SWAP",
               "mgnMode" => "cross",
               "posSide" => "long"
             }

      # A side OKX does not recognise rides through verbatim (Bourse's else-branch)
      # so the venue answers 51000 "Parameter posSide error". Dropping it here
      # would silently close a net-mode position the caller never asked to close.
      %{body: close_bogus} =
        okx_request(&Bourse.close_position(&1, "ADA/USDT:USDT", Map.put(&2, "side", "shrot")))

      assert JSON.decode!(close_bogus) == %{
               "instId" => "ADA-USDT-SWAP",
               "mgnMode" => "cross",
               "posSide" => "shrot"
             }

      %{body: hedge} = okx_request(&Bourse.set_position_mode(&1, true, &2))
      assert JSON.decode!(hedge) == %{"posMode" => "long_short_mode"}

      %{body: net} = okx_request(&Bourse.set_position_mode(&1, false, &2))
      assert JSON.decode!(net) == %{"posMode" => "net_mode"}
    end

    test "maps OKX add/reduce margin under instId/amt/type/posSide" do
      %{body: add} =
        okx_request(&Bourse.add_margin(&1, "BTC/USD:BTC", 0.0001, Map.put(&2, "posSide", "long")))

      assert JSON.decode!(add) == %{
               "instId" => "BTC-USD-SWAP",
               "amt" => 0.0001,
               "type" => "add",
               "posSide" => "long"
             }

      %{body: reduce} =
        okx_request(&Bourse.reduce_margin(&1, "BTC/USD:BTC", 0.0001, Map.put(&2, "posSide", "long")))

      assert JSON.decode!(reduce) == %{
               "instId" => "BTC-USD-SWAP",
               "amt" => 0.0001,
               "type" => "reduce",
               "posSide" => "long"
             }
    end

    test "sends an OKX conversion quote and amount under the documented native keys" do
      %{body: body, path: path} =
        okx_request(&Bourse.create_convert_trade(&1, "stale-quote-id-308", "USDT", "BTC", 100, &2))

      assert path == "/api/v5/asset/convert/trade"

      # OKX documents sz as String on POST /api/v5/asset/convert/trade.
      assert %{
               "quoteId" => "stale-quote-id-308",
               "baseCcy" => "USDT",
               "quoteCcy" => "BTC",
               "szCcy" => "USDT",
               "sz" => "100",
               "side" => "sell"
             } = JSON.decode!(body)
    end

    test "resolves the OKX instrument id for a swap read" do
      request = okx_request(&Bourse.fetch_funding_interval(&1, "BTC/USDT:USDT", &2))

      assert request.query["instId"] == "BTC-USDT-SWAP"
      refute Map.has_key?(request.query, "symbol")
    end

    test "defaults OKX closed-order reads to the plain history endpoint with an instType" do
      request = okx_request(&Bourse.fetch_closed_orders(&1, &2))

      assert request.path == "/api/v5/trade/orders-history"
      assert request.query["instType"] == "SPOT"
    end

    test "narrows the OKX option family instead of sending a full instrument id" do
      exchange = Exchange.new!("okx")

      # opt-summary keys on the family (BTC-USD); `uly` is the redundant alias.
      shaped = RequestShape.apply(%{"instFamily" => "BTC-USD-260717-48000-C"}, exchange, "fetchGreeks")
      assert shaped["instFamily"] == "BTC-USD"
      refute Map.has_key?(shaped, "uly")

      # An id whose shape we do not recognise is left for OKX to reject in its
      # own words rather than guessed at.
      unknown = RequestShape.apply(%{"instFamily" => "BTC-USD"}, exchange, "fetchGreeks")
      assert unknown["instFamily"] == "BTC-USD"
    end

    test "selects OKX's configured method without crashing on a bare-string option" do
      # `options.createOrder` is a method-name string, not a `%{"method" => _}` map;
      # reading a "method" key out of it raises Access.get/3. Endpoint choice and
      # body shape for createOrder are unauthored — this pins only that the
      # configured-method lookup tolerates the non-map option and still dispatches.
      assert %{path: "/api/v5/trade/" <> _} =
               okx_request(
                 &Bourse.create_order(&1, "BTC/USDT", "limit", "buy", 1, Map.put(&2, "price", 100)),
                 [%Bourse.Market{id: "BTC-USDT", symbol: "BTC/USDT", precision: %{"amount" => 0.001, "price" => 0.1}}]
               )
    end

    test "fans OKX option markets out from venue underlyings" do
      exchange = Exchange.new!("okx")
      test_pid = self()
      stub = {__MODULE__, :okx_market_fan_out, System.unique_integer([:positive])}

      Req.Test.stub(stub, fn conn ->
        query = URI.decode_query(conn.query_string)

        case conn.request_path do
          "/api/v5/public/underlying" ->
            send(test_pid, {:okx_underlying_request, query})
            Req.Test.json(conn, %{"code" => "0", "data" => [["BTC-USD", "ETH-USD"]]})

          "/api/v5/public/instruments" ->
            send(test_pid, {:okx_market_request, query})
            Req.Test.json(conn, %{"code" => "0", "data" => []})
        end
      end)

      assert {:ok, responses} =
               Bourse.Unified.capture_responses(exchange, :fetch_markets, %{}, plug: {Req.Test, stub})

      requests =
        for _ <- responses do
          receive do
            {:okx_market_request, query} -> query
          after
            @receive_timeout_ms -> flunk("missing OKX market fan-out request")
          end
        end

      assert_receive {:okx_underlying_request, %{"instType" => "OPTION"}}, @receive_timeout_ms

      assert Enum.sort(Enum.map(requests, & &1["instType"])) == ["FUTURES", "OPTION", "OPTION", "SPOT", "SWAP"]

      assert requests
             |> Enum.filter(&(&1["instType"] == "OPTION"))
             |> Enum.map(& &1["uly"])
             |> Enum.sort() == ["BTC-USD", "ETH-USD"]
    end

    test "surfaces an OKX underlying-read error before issuing option instruments requests" do
      exchange = Exchange.new!("okx")
      stub = {__MODULE__, :okx_underlying_error, System.unique_integer([:positive])}
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        case conn.request_path do
          "/api/v5/public/underlying" ->
            Req.Test.json(conn, %{"code" => "50015", "msg" => "underlying failed"})

          "/api/v5/public/instruments" ->
            # Do not flunk here: Bourse.HTTP rescues plug exceptions as network errors.
            send(test_pid, {:option_instruments_request, conn.method, conn.request_path})
            Req.Test.json(conn, %{"code" => "0", "data" => []})
        end
      end)

      assert {:error, %Error{exchange: "okx"}} =
               Bourse.Unified.capture_responses(exchange, :fetch_markets, %{}, plug: {Req.Test, stub})

      refute_received {:option_instruments_request, _method, _path}
    end

    test "fails loudly when OKX underlyings are not the authored string families" do
      exchange = Exchange.new!("okx")
      stub = {__MODULE__, :okx_underlying_shape, System.unique_integer([:positive])}
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        case conn.request_path do
          "/api/v5/public/underlying" ->
            Req.Test.json(conn, %{"code" => "0", "data" => [[%{"uly" => "BTC-USD"}]]})

          "/api/v5/public/instruments" ->
            # Do not flunk here: Bourse.HTTP rescues plug exceptions as network errors.
            send(test_pid, {:option_instruments_request, conn.method, conn.request_path})
            Req.Test.json(conn, %{"code" => "0", "data" => []})
        end
      end)

      assert {:error, %Error{exchange: "okx", type: :exchange_error} = error} =
               Bourse.Unified.capture_responses(exchange, :fetch_markets, %{}, plug: {Req.Test, stub})

      assert error.message =~ "Unexpected option underlying response"
      refute_received {:option_instruments_request, _method, _path}
    end

    test "maps instrument_name for deribit fetchTrades defaults" do
      {:ok, exchange} = Exchange.new("deribit")

      params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => "BTC-PERPETUAL"}, exchange)

      shaped = RequestShape.apply(params, exchange, "fetchTrades")
      assert shaped["instrument_name"] == "BTC-PERPETUAL"
      assert shaped["include_old"] == true
    end

    test "maps Derive perp reads to the authored instrument_name" do
      exchange = Exchange.new!("derive")

      for js_name <- ["fetchTicker", "fetchTrades", "fetchFundingRate", "fetchFundingRateHistory"] do
        shaped =
          %{"symbol" => "BTC/USD:USDC"}
          |> Bourse.Unified.maybe_denormalize_symbol(exchange)
          |> RequestShape.apply(exchange, js_name)

        assert shaped["instrument_name"] == "BTC-PERP"
        refute Map.has_key?(shaped, "symbol")
      end
    end

    # Task 416 — Derive private reads/cancels default subaccount_id from
    # exchange options, with per-call override.
    test "derive injects options.subaccount_id for private shaped methods without per-call param" do
      exchange = Exchange.new!("derive", options: %{"subaccount_id" => 144_422})

      for js_name <- [
            "fetchPositions",
            "fetchOrders",
            "fetchOpenOrders",
            "fetchClosedOrders",
            "fetchCanceledOrders",
            "fetchMyTrades",
            "cancelAllOrders"
          ] do
        shaped = RequestShape.apply(%{}, exchange, js_name)
        assert shaped["subaccount_id"] == 144_422, "#{js_name} should inject options default"
      end
    end

    test "derive per-call subaccount_id overrides the exchange options default for open orders" do
      exchange = Exchange.new!("derive", options: %{"subaccount_id" => 144_422})

      shaped = RequestShape.apply(%{"subaccount_id" => 99_001}, exchange, "fetchOpenOrders")
      assert shaped["subaccount_id"] == 99_001
    end

    # Sweep, not a fixed list: every unified-reachable PRIVATE method is derived from
    # the compiled endpoint mapping, so a newly authored private method that forgets
    # its request shape fails here instead of 14025-ing on the wire (task 423).
    test "every derive private unified method authors a wallet or subaccount_id request shape" do
      exchange = Exchange.new!("derive")

      private_methods =
        Bourse.Derive.__unified_endpoints__()
        |> Enum.filter(fn {_method, configs} -> Enum.any?(configs, & &1.authenticated) end)
        |> Enum.map(fn {method, _configs} -> Bourse.Unified.js_name_for!(method) end)
        |> Enum.sort()

      assert "fetchOpenOrders" in private_methods

      missing =
        Enum.reject(private_methods, fn js_name ->
          entries = Map.get(exchange.request_param_shape, js_name, %{})
          Map.has_key?(entries, "subaccount_id") or Map.has_key?(entries, "wallet")
        end)

      assert missing == [],
             "derive private unified methods with no wallet/subaccount_id request shape: #{inspect(missing)}"
    end

    test "derive accepts atom options.subaccount_id at construction" do
      exchange = Exchange.new!("derive", options: %{subaccount_id: 144_422})

      shaped = RequestShape.apply(%{}, exchange, "fetchPositions")
      assert shaped["subaccount_id"] == 144_422
    end

    test "derive request shaping raises a normalized error when subaccount_id is missing" do
      exchange = Exchange.new!("derive")

      error = assert_raise Error, fn -> RequestShape.apply(%{}, exchange, "fetchPositions") end

      assert error.type == :invalid_parameters
      assert error.exchange == "derive"
      assert error.message =~ "subaccount_id"
      assert error.message =~ "subaccount_id: value"

      cancel_error = assert_raise Error, fn -> RequestShape.apply(%{}, exchange, "cancelAllOrders") end
      assert cancel_error.message =~ "cancelAllOrders"
      assert cancel_error.message =~ "subaccount_id"
    end

    test "derive does not inject subaccount_id on public methods without that shape entry" do
      exchange = Exchange.new!("derive", options: %{"subaccount_id" => 144_422})

      shaped =
        %{"symbol" => "BTC/USD:USDC"}
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> RequestShape.apply(exchange, "fetchTicker")

      refute Map.has_key?(shaped, "subaccount_id")
      assert shaped["instrument_name"] == "BTC-PERP"
    end

    test "derive request-shape edge branches for subaccount defaults" do
      alias Bourse.Unified.RequestShape.Derive

      # Binary option values are accepted (venue accepts int; string is a valid construction form).
      binary_opts =
        %Exchange{
          id: "derive",
          name: "Derive",
          options: %{"subaccount_id" => "144422"},
          request_param_shape: %{
            "fetchPositions" => %{"subaccount_id" => %{"reason" => "identifier_reference"}}
          }
        }

      assert Derive.build(%{}, "fetchPositions", binary_opts)["subaccount_id"] == "144422"

      # Non-positive / empty options are ignored (leave unresolved for the generic raise).
      assert Derive.build(%{}, "fetchPositions", %{binary_opts | options: %{"subaccount_id" => 0}}) ==
               %{}

      assert Derive.build(%{}, "fetchPositions", %{binary_opts | options: %{"subaccount_id" => ""}}) ==
               %{}

      # Non-map shape is a no-op (defensive); non-map options yield no default.
      assert Derive.build(%{}, "fetchPositions", %{binary_opts | request_param_shape: nil}) == %{}
      assert Derive.build(%{}, "fetchPositions", %{binary_opts | options: nil}) == %{}

      # An unusable explicit per-call value falls back to the construction default.
      assert Derive.build(%{"subaccount_id" => "not-a-number"}, "fetchPositions", binary_opts)["subaccount_id"] ==
               "144422"

      assert Derive.build(%{"subaccount_id" => 0}, "fetchPositions", binary_opts)["subaccount_id"] == "144422"

      # A usable explicit per-call value wins over the construction default.
      assert Derive.build(%{"subaccount_id" => 999}, "fetchPositions", binary_opts)["subaccount_id"] == 999
      assert Derive.build(%{"subaccount_id" => "999"}, "fetchPositions", binary_opts)["subaccount_id"] == "999"
    end

    test "derive createOrder names the missing market precondition instead of signing garbage" do
      alias Bourse.Unified.RequestShape.Derive

      exchange =
        Exchange.new!("derive",
          credentials:
            Credentials.new!(
              api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
              secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
            ),
          options: %{"subaccount_id" => 144_422}
        )

      params = %{
        "instrument_name" => "ETH/USD:USDC",
        "type" => "limit",
        "side" => "buy",
        "amount" => 0.1,
        "price" => 100,
        "max_fee" => "200"
      }

      # No market cache at all.
      assert_raise ArgumentError, ~r/requires loaded markets/, fn ->
        Derive.build(params, "createOrder", exchange)
      end

      # Markets loaded, but the requested instrument is absent.
      loaded = Exchange.put_markets(exchange, [%Bourse.Market{id: "BTC-PERP", symbol: "BTC/USD:USDC"}])

      assert_raise ArgumentError, ~r/requires a loaded market for ETH\/USD:USDC/, fn ->
        Derive.build(params, "createOrder", loaded)
      end

      # Market found, but it carries no venue `info` to build the trade-module hash from.
      info_less = Exchange.put_markets(exchange, [%Bourse.Market{id: "ETH-PERP", symbol: "ETH/USD:USDC"}])

      assert_raise ArgumentError, ~r/needs the venue `info`/, fn ->
        Derive.build(params, "createOrder", info_less)
      end
    end

    test "derive createOrder resolves raw string-keyed markets and canonical option ids" do
      alias Bourse.Unified.RequestShape.Derive

      # The static-fixture replay cache holds Bourse's RAW market maps (string keys),
      # not %Bourse.Market{} structs — both shapes must resolve.
      raw_market = %{
        "id" => "ZEC-20260925-800-P",
        "symbol" => "ZEC/USDC:USDC-260925-800-P",
        "info" => %{
          "base_asset_address" => "0x0000000000000000000000000000000000000001",
          "base_asset_sub_id" => "0"
        }
      }

      exchange =
        "derive"
        |> Exchange.new!(
          sandbox: true,
          credentials:
            Credentials.new!(
              api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
              secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
            ),
          options: %{"subaccount_id" => 144_422}
        )
        |> Map.put(:markets, [raw_market])

      base = %{"type" => "limit", "side" => "BUY", "amount" => 2, "price" => "0.1", "max_fee" => 200}
      native_option = Bourse.Symbol.to_exchange_id(raw_market["symbol"], exchange)

      assert native_option == raw_market["id"]

      built = Derive.build(Map.put(base, "instrument_name", native_option), "createOrder", exchange, [])

      # The venue id — not the unified symbol — reaches the wire, and `order_type`
      # carries limit/market (the task-379 defect had the instrument name here).
      assert built["instrument_name"] == "ZEC-20260925-800-P"
      assert built["order_type"] == "limit"
      assert built["direction"] == "buy"
      # Amounts/prices/fees are stringified regardless of the caller's numeric type.
      assert built["amount"] == "2"
      assert built["limit_price"] == "0.1"
      assert built["max_fee"] == "200"
      assert built["subaccount_id"] == 144_422
      assert "0x" <> _ = built["signature"]

      # An explicit signature_expiry_sec is honored in both integer and string form;
      # an unparseable one falls back to the nonce-derived validity window.
      pinned = Map.merge(base, %{"instrument_name" => "ZEC-20260925-800-P", "signature_expiry_sec" => 1_700_000_000})
      assert Derive.build(pinned, "createOrder", exchange, [])["signature_expiry_sec"] == 1_700_000_000

      stringy = %{pinned | "signature_expiry_sec" => "1700000000"}
      assert Derive.build(stringy, "createOrder", exchange, [])["signature_expiry_sec"] == 1_700_000_000

      junk = %{pinned | "signature_expiry_sec" => "later"}

      assert Derive.build(junk, "createOrder", exchange, timestamp_ms_override: 1_000_000_000)["signature_expiry_sec"] ==
               1_000_000 + 7_776_000

      # Optional passthrough fields ride along only when the caller supplied them.
      refute Map.has_key?(Derive.build(pinned, "createOrder", exchange, []), "label")

      with_label = Map.put(pinned, "label", "tag-1")
      assert Derive.build(with_label, "createOrder", exchange, [])["label"] == "tag-1"

      with_client_id = Map.put(pinned, "clientOrderId", "tag-2")
      create = Derive.build(with_client_id, "createOrder", exchange, [])
      edit = Derive.build(Map.put(with_client_id, "id", "derive-order-1"), "editOrder", exchange, [])

      assert create["label"] == "tag-2"
      assert Map.take(create, ["label"]) == Map.take(edit, ["label"])
      refute Map.has_key?(create, "clientOrderId")
      refute Map.has_key?(edit, "clientOrderId")
    end

    test "keeps mandatory symbol for binance fetchOHLCV (limit is not a symbol rename)" do
      {:ok, exchange} = Exchange.new("binance")

      params =
        %{"symbol" => "BTC/USDT", "timeframe" => "1m"}
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> Bourse.Unified.maybe_translate_timeframe(exchange)

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV")

      # symbol is the native param here — must survive (binance's `limit`
      # identifier_reference must NOT trigger the symbol-rename drop).
      assert shaped["symbol"] == "BTCUSDT"
      # timeframe is renamed into `interval`; the leftover unified key is dropped
      # (binance rejects unread duplicate params).
      assert shaped["interval"] == "1m"
      refute Map.has_key?(shaped, "timeframe")
    end

    test "injects bybit V5 spot category from a spot symbol" do
      {:ok, exchange} = Exchange.new("bybit")

      params =
        %{"symbol" => "BTC/USDT"}
        |> RequestShape.apply_premarket(exchange, "fetchTicker")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)

      shaped = RequestShape.apply(params, exchange, "fetchTicker")

      assert shaped["symbol"] == "BTCUSDT"
      assert shaped["category"] == "spot"
    end

    test "injects bybit V5 linear category from a USDT-settled swap symbol" do
      {:ok, exchange} = Exchange.new("bybit")

      params =
        %{"symbol" => "BTC/USDT:USDT"}
        |> RequestShape.apply_premarket(exchange, "fetchTicker")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)

      shaped = RequestShape.apply(params, exchange, "fetchTicker")

      assert shaped["symbol"] == "BTCUSDT"
      assert shaped["category"] == "linear"
    end

    test "injects bybit V5 inverse category from a coin-settled swap symbol" do
      {:ok, exchange} = Exchange.new("bybit")

      params =
        %{"symbol" => "BTC/USD:BTC"}
        |> RequestShape.apply_premarket(exchange, "fetchTicker")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)

      shaped = RequestShape.apply(params, exchange, "fetchTicker")

      assert shaped["symbol"] == "BTCUSD"
      assert shaped["category"] == "inverse"
    end

    test "injects bybit V5 option category from an option symbol" do
      {:ok, exchange} = Exchange.new("bybit")

      shaped =
        %{"symbol" => "BTC/USDT:USDT-270326-67000-P"}
        |> RequestShape.apply_premarket(exchange, "fetchTicker")
        |> RequestShape.apply(exchange, "fetchTicker")

      assert shaped["category"] == "option"
    end

    test "bybit option requests use bare USDC option ids through the real shaping order" do
      {:ok, exchange} = Exchange.new("bybit")
      symbol = "BTC/USDC:USDC-241227-55000-P"

      for js_name <- ["fetchGreeks", "fetchTicker", "fetchOrderBook", "fetchTrades", "fetchOpenInterest"] do
        shaped =
          %{"symbol" => symbol}
          |> RequestShape.apply_premarket(exchange, js_name)
          |> Bourse.Unified.maybe_denormalize_symbol(exchange)
          |> Bourse.Unified.maybe_merge_request_defaults(exchange, js_name)
          |> RequestShape.apply(exchange, js_name)

        assert shaped["symbol"] == "BTC-27DEC24-55000-P"
        refute shaped["symbol"] =~ "-USDC"
      end
    end

    test "bybit option chain derives baseCoin from option symbol through the real shaping order" do
      {:ok, exchange} = Exchange.new("bybit")

      shaped =
        %{"symbol" => "BTC/USDC:USDC-241227-55000-P"}
        |> RequestShape.apply_premarket(exchange, "fetchOptionChain")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> Bourse.Unified.maybe_merge_request_defaults(exchange, "fetchOptionChain")
        |> RequestShape.apply(exchange, "fetchOptionChain")

      assert shaped == %{"category" => "option", "baseCoin" => "BTC"}
    end

    # Bourse's static request fixture calls fetchOptionChain with a bare code ("BTC"),
    # which the unified layer receives under the "symbol" key.
    test "bybit option chain accepts a bare base code as the symbol param" do
      {:ok, exchange} = Exchange.new("bybit")

      shaped =
        %{"symbol" => "BTC"}
        |> RequestShape.apply_premarket(exchange, "fetchOptionChain")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> Bourse.Unified.maybe_merge_request_defaults(exchange, "fetchOptionChain")
        |> RequestShape.apply(exchange, "fetchOptionChain")

      assert shaped == %{"category" => "option", "baseCoin" => "BTC"}
    end

    test "injects bybit V5 default categories for symbol-less methods" do
      {:ok, exchange} = Exchange.new("bybit")

      assert %{"category" => "spot"} = RequestShape.apply_premarket(%{}, exchange, "fetchMarkets")
      assert %{"category" => "linear"} = RequestShape.apply_premarket(%{}, exchange, "fetchFundingRates")
    end

    test "builds bybit option fetchTickers category and base coin from symbols" do
      {:ok, exchange} = Exchange.new("bybit")

      shaped =
        %{"symbols" => ["BTC/USDT:USDT-250530-70000-C"]}
        |> RequestShape.apply_premarket(exchange, "fetchTickers")
        |> RequestShape.apply(exchange, "fetchTickers")

      assert shaped == %{"category" => "option", "baseCoin" => "BTC"}
    end

    test "builds bybit fetchTickers category and base coin from explicit params" do
      {:ok, exchange} = Exchange.new("bybit")

      shaped =
        %{"type" => "option", "code" => "ETH"}
        |> RequestShape.apply_premarket(exchange, "fetchTickers")
        |> RequestShape.apply(exchange, "fetchTickers")

      assert shaped == %{"category" => "option", "baseCoin" => "ETH", "code" => "ETH"}
    end

    test "injects bybit V5 category from explicit market type params" do
      {:ok, exchange} = Exchange.new("bybit")

      assert %{"category" => "inverse"} =
               RequestShape.apply_premarket(%{"subType" => "inverse"}, exchange, "fetchTicker")

      assert %{"category" => "linear"} =
               RequestShape.apply_premarket(%{"sub_type" => "linear"}, exchange, "fetchTicker")

      assert %{"category" => "spot"} =
               RequestShape.apply_premarket(%{"type" => "spot"}, exchange, "fetchTicker")

      assert %{"category" => "option"} =
               RequestShape.apply_premarket(%{"type" => "option"}, exchange, "fetchTicker")

      assert %{"category" => "linear"} =
               RequestShape.apply_premarket(%{"type" => "swap"}, exchange, "fetchTicker")

      assert %{"category" => "linear"} =
               RequestShape.apply_premarket(%{"type" => "future"}, exchange, "fetchTicker")
    end

    test "does not inject bybit V5 category for unknown category inputs" do
      {:ok, exchange} = Exchange.new("bybit")

      shaped = RequestShape.apply_premarket(%{"type" => "margin"}, exchange, "fetchTicker")

      refute Map.has_key?(shaped, "category")
    end

    test "does not inject bybit V5 category for an unparseable symbol" do
      {:ok, exchange} = Exchange.new("bybit")

      shaped = RequestShape.apply_premarket(%{"symbol" => "garbage"}, exchange, "fetchTicker")

      refute Map.has_key?(shaped, "category")
    end

    test "maps bybit fetchOHLCV timeframe to interval and injects category" do
      {:ok, exchange} = Exchange.new("bybit")

      params =
        %{"symbol" => "BTC/USDT:USDT", "timeframe" => "1h"}
        |> RequestShape.apply_premarket(exchange, "fetchOHLCV")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> Bourse.Unified.maybe_translate_timeframe(exchange)

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV")

      assert shaped["symbol"] == "BTCUSDT"
      assert shaped["category"] == "linear"
      assert shaped["interval"] == "60"
      refute Map.has_key?(shaped, "timeframe")
    end

    test "builds authored bybit create and cancel order requests" do
      {:ok, exchange} = Exchange.new("bybit")

      create =
        %{
          "symbol" => "LTC/USDT:USDT",
          "type" => "limit",
          "side" => "sell",
          "amount" => 0.1,
          "price" => 100,
          "postOnly" => true,
          "reduceOnly" => true
        }
        |> RequestShape.apply_premarket(exchange, "createOrder")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> RequestShape.apply(exchange, "createOrder")

      assert create == %{
               "category" => "linear",
               "symbol" => "LTCUSDT",
               "side" => "Sell",
               "orderType" => "Limit",
               "qty" => "0.1",
               "price" => "100",
               "timeInForce" => "PostOnly",
               "reduceOnly" => true
             }

      cancel =
        %{"id" => "order-1", "symbol" => "BTC/USDT", "stop" => true}
        |> RequestShape.apply_premarket(exchange, "cancelOrder")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> RequestShape.apply(exchange, "cancelOrder")

      assert cancel == %{
               "category" => "spot",
               "symbol" => "BTCUSDT",
               "orderId" => "order-1",
               "orderFilter" => "StopOrder"
             }
    end

    test "rounds Bybit order values from loaded instrument precision" do
      exchange =
        "bybit"
        |> Exchange.new!()
        |> Exchange.put_markets([
          %Bourse.Market{
            id: "LTCUSDT",
            symbol: "LTC/USDT",
            spot: true,
            precision: %{"amount" => 0.00001, "price" => 0.01},
            info: %{
              "lotSizeFilter" => %{"basePrecision" => "0.00001"},
              "priceFilter" => %{"tickSize" => "0.01"}
            }
          },
          %Bourse.Market{
            id: "ADAUSDT",
            symbol: "ADA/USDT",
            spot: true,
            precision: %{"amount" => 0.01, "price" => 0.0001},
            info: %{
              "lotSizeFilter" => %{"basePrecision" => "0.01"},
              "priceFilter" => %{"tickSize" => "0.0001"}
            }
          },
          %Bourse.Market{
            id: "LTCUSDT",
            symbol: "LTC/USDT:USDT",
            linear: true,
            precision: %{"amount" => 0.1, "price" => 0.001}
          }
        ])

      shape_order = fn exchange, symbol, amount, price ->
        %{
          "symbol" => symbol,
          "type" => "limit",
          "side" => "buy",
          "amount" => amount,
          "price" => price
        }
        |> RequestShape.apply_premarket(exchange, "createOrder")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> RequestShape.apply(exchange, "createOrder")
      end

      assert %{"qty" => "0.14444", "price" => "60.42"} =
               shape_order.(exchange, "LTC/USDT", 0.1444444234234234, 60.423)

      assert %{"qty" => "12.34", "price" => "0.4321"} =
               shape_order.(exchange, "ADA/USDT", "12.349", "0.43219")

      assert %{"category" => "linear", "qty" => "1.2", "price" => "60.423"} =
               shape_order.(exchange, "LTC/USDT:USDT", 1.29, 60.4239)
    end

    test "Bybit authored request builders contain no per-symbol precision table" do
      exchange = Exchange.new!("bybit")

      for method <- ~w(createOrder createOrders editOrder editOrders) do
        refute Map.has_key?(exchange.request_param_shape[method], "_precision")
      end
    end

    test "Bybit batch builders raise a typed error for missing or empty orders" do
      exchange = Exchange.new!("bybit")

      for {method, params} <- [
            {"createOrders", %{}},
            {"createOrders", %{"orders" => []}},
            {"editOrders", %{}},
            {"editOrders", %{"orders" => []}}
          ] do
        error = assert_raise Error, fn -> Bybit.build(params, method, exchange, %{}) end

        assert error.type == :bad_request
        assert error.exchange == "bybit"
        assert error.message == "Bybit batch orders require a non-empty orders list"
      end
    end

    test "builds authored bybit batch cancellation and margin borrow requests" do
      {:ok, exchange} = Exchange.new("bybit")

      assert RequestShape.apply(
               %{"ids" => ["order-1"], "symbol" => "LTC/USDT:USDT"},
               exchange,
               "cancelOrders"
             ) == %{
               "category" => "linear",
               "request" => [%{"symbol" => "LTCUSDT", "orderId" => "order-1"}]
             }

      assert RequestShape.apply(
               %{"code" => "BTC", "amount" => 0.001},
               exchange,
               "borrowCrossMargin"
             ) == %{"coin" => "BTC", "amount" => "0.001"}
    end

    test "bybit cancelOrders keeps the premarket category once the symbol is denormalized" do
      {:ok, exchange} = Exchange.new("bybit")

      # `build_final_params` denormalizes the symbol before RequestShape runs and
      # `apply_premarket` resolves the category from the still-unified symbol.
      # `LTCUSDT` alone is ambiguous (spot and linear swap share the id), so the
      # premarket category must win over re-deriving it from the exchange id.
      assert RequestShape.apply(
               %{"ids" => ["order-1"], "symbol" => "LTCUSDT", "category" => "linear"},
               exchange,
               "cancelOrders"
             ) == %{
               "category" => "linear",
               "request" => [%{"symbol" => "LTCUSDT", "orderId" => "order-1"}]
             }
    end

    test "keeps extra params maps out of bybit batch cancellation symbols" do
      {:ok, exchange} = Exchange.new("bybit")

      assert RequestShape.apply(
               %{"ids" => ["order-1"], "symbol" => "LTC/USDT:USDT", "params" => %{"foo" => "bar"}},
               exchange,
               "cancelOrders"
             ) == %{
               "category" => "linear",
               "request" => [%{"symbol" => "LTCUSDT", "orderId" => "order-1"}]
             }

      assert RequestShape.apply(
               %{"ids" => ["order-1"], "params" => %{"foo" => "bar"}},
               exchange,
               "cancelOrders"
             ) == %{"request" => [%{"orderId" => "order-1"}]}
    end

    test "keeps extra params maps out of bybit position-mode symbols" do
      {:ok, exchange} = Exchange.new("bybit")

      assert RequestShape.apply(
               %{"hedge_mode" => true, "symbol" => "LTC/USDT:USDT", "params" => %{"foo" => "bar"}},
               exchange,
               "setPositionMode"
             ) == %{"category" => "linear", "symbol" => "LTCUSDT", "mode" => 3}

      assert RequestShape.apply(
               %{"hedge_mode" => true, "params" => %{"foo" => "bar"}},
               exchange,
               "setPositionMode"
             ) == %{"mode" => 3}
    end

    test "keeps extra params maps out of bybit single-order lookup symbols" do
      {:ok, exchange} = Exchange.new("bybit")
      params = %{"id" => "order-1", "symbol" => "LTC/USDT:USDT", "params" => %{"foo" => "bar"}}

      for js_name <- ["fetchOrder", "fetchOpenOrder", "fetchClosedOrder"] do
        shaped = RequestShape.apply(params, exchange, js_name)

        assert shaped["category"] == "linear"
        assert shaped["symbol"] == "LTCUSDT"
        assert shaped["orderId"] == "order-1"
      end

      # The originally reported repro: an extra-params map and no symbol at all.
      for js_name <- ["fetchOrder", "fetchOpenOrder", "fetchClosedOrder"] do
        shaped = RequestShape.apply(%{"id" => "order-1", "params" => %{"foo" => "bar"}}, exchange, js_name)

        assert shaped["category"] == "spot"
        assert shaped["orderId"] == "order-1"
        refute Map.has_key?(shaped, "symbol")
      end
    end

    test "keeps extra params maps out of bybit transfer and convert identifiers" do
      {:ok, exchange} = Exchange.new("bybit")

      transfers = RequestShape.apply(%{"params" => %{"limit" => 5}}, exchange, "fetchTransfers")
      convert_trade = RequestShape.apply(%{"params" => %{"limit" => 5}}, exchange, "fetchConvertTrade")

      refute Map.has_key?(transfers, "coin")
      refute Map.has_key?(convert_trade, "quoteTxId")
      assert convert_trade["accountType"] == "eb_convert_uta"
      refute Enum.any?(transfers, fn {_key, value} -> is_map(value) end)
      refute Enum.any?(convert_trade, fn {_key, value} -> is_map(value) end)
    end

    test "bybit transfer and convert identifiers use their documented parameter channels" do
      {:ok, exchange} = Exchange.new("bybit")

      assert RequestShape.apply(%{"code" => "USDT"}, exchange, "fetchTransfers") == %{"coin" => "USDT"}

      assert RequestShape.apply(%{"id" => "1010020692439483803499737088"}, exchange, "fetchConvertTrade") ==
               %{"quoteTxId" => "1010020692439483803499737088", "accountType" => "eb_convert_uta"}

      assert RequestShape.apply(%{"code" => "USDT", "params" => %{"limit" => 5}}, exchange, "fetchTransfers") ==
               %{"coin" => "USDT"}

      assert RequestShape.apply(%{"id" => "quote-1", "params" => %{"limit" => 5}}, exchange, "fetchConvertTrade") ==
               %{"quoteTxId" => "quote-1", "accountType" => "eb_convert_uta"}
    end

    test "bybit request shape has no bare params fallback reads" do
      source = "../../../lib/bourse/unified/request_shape/bybit.ex" |> Path.expand(__DIR__) |> File.read!()

      refute source =~ ~s(params["params"])
    end

    test "bybit maps native currency and option baseCoin from unified identifiers" do
      exchange = Exchange.new!("bybit")

      assert RequestShape.apply(%{"code" => "USDT"}, exchange, "fetchCrossBorrowRate") == %{"currency" => "USDT"}

      assert RequestShape.apply(%{"symbol" => "BTC/USD:BTC"}, exchange, "fetchVolatilityHistory") == %{
               "category" => "option",
               "baseCoin" => "BTC"
             }

      assert RequestShape.apply(%{"symbol" => "BTCUSD"}, exchange, "fetchVolatilityHistory") == %{
               "category" => "option",
               "baseCoin" => "BTC"
             }
    end

    test "bybit setPositionMode keeps the premarket category after symbol denormalization" do
      {:ok, exchange} = Exchange.new("bybit")

      # `apply_premarket` resolves category from the still-unified symbol; by the
      # time RequestShape.apply/3 runs, `symbol` is the native id (`BTCUSDT`),
      # which is shared by spot and linear-swap and cannot re-derive a category.
      params =
        %{"hedge_mode" => true, "symbol" => "BTC/USDT:USDT"}
        |> RequestShape.apply_premarket(exchange, "setPositionMode")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)

      assert RequestShape.apply(params, exchange, "setPositionMode") == %{
               "category" => "linear",
               "symbol" => "BTCUSDT",
               "mode" => 3
             }
    end

    test "covers Bybit request variants that accept scalar identifiers and order controls" do
      exchange = Exchange.new!("bybit")

      order =
        Bybit.build(
          %{
            "symbol" => "BTC/USDT:USDT",
            "amount" => 1,
            "price" => 100,
            "type" => "limit",
            "side" => "buy",
            "timeInForce" => "ioc",
            "clientOrderId" => "client-1",
            "triggerPrice" => 101,
            "triggerDirection" => "ascending",
            "stopLoss" => %{"triggerPrice" => 99, "price" => 98},
            "takeProfit" => 102,
            "hedged" => true
          },
          "createOrder",
          exchange,
          %{}
        )

      assert order["timeInForce"] == "IOC"
      assert order["orderLinkId"] == "client-1"
      assert order["triggerDirection"] == 1
      assert order["slLimitPrice"] == "98"
      assert order["tpslMode"] == "Partial"
      assert order["positionIdx"] == 1

      assert Bybit.build(%{"leverage" => 2, "category" => "linear", "symbol" => "BTCUSDT"}, "setLeverage", exchange, %{}) ==
               %{"category" => "linear", "symbol" => "BTCUSDT", "buyLeverage" => "2", "sellLeverage" => "2"}

      assert Bybit.build(
               %{"from_account" => "funding", "to_account" => "unified", "code" => "USDT", "amount" => 1},
               "transfer",
               exchange,
               %{}
             ) ==
               %{"fromAccountType" => "FUND", "toAccountType" => "UNIFIED", "coin" => "USDT", "amount" => "1"}

      assert Bybit.build(%{"code" => "BTC"}, "fetchTransfers", exchange, %{}) == %{"coin" => "BTC"}

      assert Bybit.build(%{"id" => "quote-1"}, "fetchConvertTrade", exchange, %{}) ==
               %{"quoteTxId" => "quote-1", "accountType" => "eb_convert_uta"}

      assert Bybit.build(
               %{"id" => "quote-1", "from_code" => "USDT", "to_code" => "BTC", "amount" => 1},
               "createConvertTrade",
               exchange,
               %{}
             ) == %{"quoteTxId" => "quote-1"}
    end

    @tag :exchange_bybit
    test "bybit fetchBorrowRateHistory defaults a 30-day window when since is absent" do
      # Task 246 — default/no-arg shape must not ArithmeticError on nil since.
      # since = now - 30d, endTime = since + 30d. Nested "params" is not since.
      exchange = Exchange.new!("bybit")
      month_ms = 30 * 24 * 60 * 60 * 1000
      before = System.system_time(:millisecond)

      shaped = RequestShape.apply(%{"code" => "USDT"}, exchange, "fetchBorrowRateHistory")

      after_ms = System.system_time(:millisecond)
      assert shaped["currency"] == "USDT"
      assert is_integer(shaped["startTime"])
      assert is_integer(shaped["endTime"])
      assert shaped["endTime"] - shaped["startTime"] == month_ms
      # start ≈ now - 30d (clock ticks during the call are fine within the sample window)
      assert shaped["startTime"] >= before - month_ms - 1_000
      assert shaped["startTime"] <= after_ms - month_ms + 1_000
      assert shaped["endTime"] >= before - 1_000
      assert shaped["endTime"] <= after_ms + 1_000

      # Explicit since still windows forward by 30d; nested params map is ignored as since.
      since = 1_726_652_765_781

      assert RequestShape.apply(
               %{"code" => "USDT", "since" => since, "params" => %{"vipLevel" => "No VIP"}},
               exchange,
               "fetchBorrowRateHistory"
             ) == %{
               "currency" => "USDT",
               "startTime" => since,
               "endTime" => since + month_ms
             }
    end

    @tag :exchange_bybit
    test "bybit fetchAllGreeks defaults baseCoin to BTC with no args" do
      # Option endpoints require baseCoin; keep it consistent with tickers_request.
      exchange = Exchange.new!("bybit")

      assert RequestShape.apply(%{}, exchange, "fetchAllGreeks") == %{
               "category" => "option",
               "baseCoin" => "BTC"
             }

      assert %{"category" => "option", "baseCoin" => "ETH"} =
               RequestShape.apply(%{"baseCoin" => "ETH"}, exchange, "fetchAllGreeks")
    end

    @tag :exchange_bybit
    test "bybit fetchAllGreeks derives baseCoin from non-BTC option symbol" do
      exchange = Exchange.new!("bybit")

      params =
        %{"symbol" => "ETH/USDT:USDT-270625-5500-P"}
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> RequestShape.apply(exchange, "fetchAllGreeks")

      assert params == %{
               "category" => "option",
               "baseCoin" => "ETH",
               "symbol" => "ETH-25JUN27-5500-P-USDT"
             }
    end

    # /v5/position/list requires `category` to select the product line (Bybit V5
    # docs; confirmed live 2026-07-16). It is derived from the unified symbol's
    # settle coin, so an inverse contract must NOT be requested as linear.
    @tag :exchange_bybit
    test "bybit fetchPositionADLRank derives linear category from a USDT-settled swap symbol" do
      exchange = Exchange.new!("bybit")

      params =
        %{"symbol" => "BTC/USDT:USDT"}
        |> RequestShape.apply_premarket(exchange, "fetchPositionADLRank")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> RequestShape.apply(exchange, "fetchPositionADLRank")

      assert params == %{"category" => "linear", "symbol" => "BTCUSDT"}
    end

    @tag :exchange_bybit
    test "bybit fetchPositionADLRank derives inverse category from a coin-settled swap symbol" do
      exchange = Exchange.new!("bybit")

      params =
        %{"symbol" => "BTC/USD:BTC"}
        |> RequestShape.apply_premarket(exchange, "fetchPositionADLRank")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> RequestShape.apply(exchange, "fetchPositionADLRank")

      assert params == %{"category" => "inverse", "symbol" => "BTCUSD"}
    end

    @tag :exchange_bybit
    test "bybit fetchPositionADLRank keeps an explicit caller category" do
      exchange = Exchange.new!("bybit")

      params =
        %{"symbol" => "BTC/USD:BTC", "category" => "inverse"}
        |> RequestShape.apply_premarket(exchange, "fetchPositionADLRank")
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> RequestShape.apply(exchange, "fetchPositionADLRank")

      assert params == %{"category" => "inverse", "symbol" => "BTCUSD"}
    end

    @tag :exchange_bybit
    test "covers bybit request option branches not present in the static corpus" do
      exchange = Exchange.new!("bybit")

      assert %{
               "category" => "spot",
               "marketUnit" => "quoteCoin",
               "qty" => "2",
               "orderLinkId" => "client-1",
               "timeInForce" => "PostOnly"
             } =
               Bybit.build(
                 %{
                   "category" => "spot",
                   "symbol" => "BTCUSDT",
                   "type" => "market",
                   "side" => "buy",
                   "amount" => 2,
                   "marketUnit" => "quoteCoin",
                   "clientOrderId" => "client-1",
                   "timeInForce" => "postonly"
                 },
                 "createOrder",
                 exchange,
                 %{}
               )

      assert %{"triggerDirection" => 2, "triggerPrice" => "110"} =
               Bybit.build(
                 %{
                   "category" => "linear",
                   "symbol" => "BTCUSDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 1,
                   "price" => 100,
                   "takeProfitPrice" => 110
                 },
                 "createOrder",
                 exchange,
                 %{}
               )

      assert %{"setMarginMode" => "portfolio"} =
               Bybit.build(%{"margin_mode" => "portfolio"}, "setMarginMode", exchange, %{})

      transfer =
        Bybit.build(
          %{"from_account" => "fund", "to_account" => nil, "code" => "USDT", "amount" => 1},
          "transfer",
          exchange,
          %{}
        )

      assert transfer["fromAccountType"] == "FUND"
      refute Map.has_key?(transfer, "toAccountType")

      assert %{"chain" => "ERC20"} =
               Bybit.build(
                 %{"code" => "USDT", "amount" => 1, "address" => "0x1", "network" => "ERC20"},
                 "withdraw",
                 exchange,
                 %{}
               )

      assert Bybit.build(%{"untouched" => true}, "unknownMethod", exchange, %{}) == %{"untouched" => true}
      assert Bybit.build(%{}, "fetchOption", exchange, %{}) == %{"category" => "option", "symbol" => nil}

      assert Bybit.build(%{"symbol" => "BTC/USDC:USDC-241227-55000-P"}, "fetchOption", exchange, %{}) == %{
               "category" => "option",
               "symbol" => "BTC-27DEC24-55000-P"
             }
    end

    test "builds each Bybit spot market-order quantity form" do
      exchange = Exchange.new!("bybit")
      base = %{"category" => "spot", "symbol" => "LTCUSDT", "type" => "market"}

      assert %{"marketUnit" => "quoteCoin", "qty" => "7"} =
               Bybit.build(Map.merge(base, %{"side" => "sell", "amount" => 2, "cost" => 7}), "createOrder", exchange, %{})

      assert %{"marketUnit" => "quoteCoin", "qty" => "6"} =
               Bybit.build(
                 Map.merge(base, %{"side" => "sell", "amount" => 2, "price" => 3}),
                 "createOrder",
                 exchange,
                 %{}
               )

      assert %{"qty" => "7"} =
               Bybit.build(Map.merge(base, %{"side" => "buy", "amount" => 2, "cost" => 7}), "createOrder", exchange, %{})

      assert %{"qty" => "6"} =
               Bybit.build(Map.merge(base, %{"side" => "buy", "amount" => 2, "price" => 3}), "createOrder", exchange, %{})

      assert %{"marketUnit" => "baseCoin", "qty" => "2"} =
               Bybit.build(Map.merge(base, %{"side" => "buy", "amount" => 2}), "createOrder", exchange, %{})
    end

    test "builds Bybit trailing and trading-stop request variants" do
      exchange = Exchange.new!("bybit")

      assert %{
               "activePrice" => "95",
               "positionIdx" => 2,
               "trailingStop" => "5"
             } =
               Bybit.build(
                 %{
                   "category" => "linear",
                   "symbol" => "BTCUSDT",
                   "type" => "limit",
                   "side" => "sell",
                   "amount" => 2,
                   "price" => 100,
                   "trailingStop" => 5,
                   "activePrice" => 95,
                   "hedged" => true
                 },
                 "createOrder",
                 exchange,
                 %{}
               )

      assert %{
               "slLimitPrice" => "89",
               "slOrderType" => "Limit",
               "slSize" => "2",
               "stopLoss" => "90",
               "takeProfit" => "110",
               "tpLimitPrice" => "111",
               "tpOrderType" => "Limit",
               "tpSize" => "2",
               "tpslMode" => "Partial"
             } =
               Bybit.build(
                 %{
                   "category" => "linear",
                   "symbol" => "BTCUSDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 2,
                   "stopLossPrice" => 90,
                   "stopLossLimitPrice" => 89,
                   "takeProfitPrice" => 110,
                   "takeProfitLimitPrice" => 111
                 },
                 "createOrder",
                 exchange,
                 %{}
               )

      assert %{"positionIdx" => 1, "tpslMode" => "Full"} =
               Bybit.build(
                 %{
                   "category" => "linear",
                   "symbol" => "BTCUSDT",
                   "type" => "limit",
                   "side" => "sell",
                   "amount" => 0,
                   "stopLossPrice" => 90,
                   "takeProfitPrice" => 110,
                   "hedged" => true,
                   "reduceOnly" => true
                 },
                 "createOrder",
                 exchange,
                 %{}
               )
    end

    test "builds Bybit trigger direction variants" do
      exchange = Exchange.new!("bybit")
      base = %{"category" => "linear", "symbol" => "BTCUSDT", "type" => "limit", "amount" => 1, "price" => 100}

      assert %{"triggerDirection" => 1} =
               Bybit.build(Map.merge(base, %{"side" => "buy", "stopLossPrice" => 90}), "createOrder", exchange, %{})

      assert %{"triggerDirection" => 1} =
               Bybit.build(Map.merge(base, %{"side" => "sell", "takeProfitPrice" => 110}), "createOrder", exchange, %{})

      assert %{"triggerDirection" => 2} =
               Bybit.build(Map.merge(base, %{"side" => "sell", "stopLossPrice" => 90}), "createOrder", exchange, %{})

      assert %{"orderFilter" => "StopOrder", "triggerPrice" => "90"} =
               spot =
               Bybit.build(
                 %{
                   "category" => "spot",
                   "symbol" => "BTCUSDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 1,
                   "price" => 100,
                   "triggerPrice" => 90
                 },
                 "createOrder",
                 exchange,
                 %{}
               )

      refute Map.has_key?(spot, "triggerDirection")
    end

    test "builds Bybit batch, history, and account-control boundary variants" do
      exchange = Exchange.new!("bybit")

      assert %{"category" => "linear", "request" => [%{"symbol" => "LTCUSDT", "qty" => "1", "price" => "60"}]} =
               Bybit.build(
                 %{
                   "orders" => [
                     %{
                       "symbol" => "LTC/USDT:USDT",
                       "type" => "limit",
                       "side" => "buy",
                       "amount" => 1,
                       "price" => 60
                     }
                   ]
                 },
                 "createOrders",
                 exchange,
                 %{}
               )

      assert %{"category" => "linear", "request" => [%{"symbol" => "LTCUSDT", "orderId" => "order-1"}]} =
               Bybit.build(
                 %{"orders" => [%{"symbol" => "LTC/USDT:USDT", "id" => "order-1"}]},
                 "cancelOrdersForSymbols",
                 exchange,
                 %{}
               )

      assert Bybit.build(%{"margin_mode" => "cross"}, "setMarginMode", exchange, %{}) ==
               %{"setMarginMode" => "REGULAR_MARGIN"}

      assert Bybit.build(%{"margin_mode" => "isolated"}, "setMarginMode", exchange, %{}) ==
               %{"setMarginMode" => "ISOLATED_MARGIN"}

      assert %{"category" => "inverse", "settleCoin" => "BTC"} =
               Bybit.build(
                 %{"category" => "inverse", "settleCoin" => "BTC"},
                 "fetchOpenOrders",
                 exchange,
                 %{}
               )

      assert %{"category" => "spot"} =
               Bybit.build(%{"category" => "spot"}, "fetchOpenOrders", exchange, %{})

      assert %{"endTime" => 10_800_001, "startTime" => 1} =
               Bybit.build(%{"since" => 1}, "fetchFundingRateHistory", exchange, %{})

      assert %{"limit" => "200"} =
               Bybit.build(%{"category" => "linear", "limit" => nil}, "fetchPositions", exchange, %{})

      assert %{"chain" => "TRX"} =
               Bybit.build(
                 %{"code" => "USDT", "amount" => 1, "address" => "T1", "network" => "TRC20"},
                 "withdraw",
                 exchange,
                 %{}
               )
    end

    test "handles Bybit native-symbol and scalar boundary inputs" do
      exchange = Exchange.new!("bybit")
      spot_default = %{exchange | options: Map.put(exchange.options, "defaultType", "spot")}

      assert %{"category" => "inverse"} =
               Bybit.build(
                 %{"orders" => [%{"symbol" => "BTCUSD", "id" => "order-1"}]},
                 "cancelOrdersForSymbols",
                 exchange,
                 %{}
               )

      assert %{"category" => "spot"} = Bybit.build(%{}, "fetchTickers", spot_default, %{})
      assert %{"category" => "linear"} = Bybit.build(%{"symbols" => ["not-a-symbol"]}, "fetchTickers", exchange, %{})

      assert %{"side" => ""} =
               Bybit.build(
                 %{
                   "category" => "spot",
                   "symbol" => "BTCUSDT",
                   "type" => "limit",
                   "side" => "",
                   "amount" => 1,
                   "price" => 100
                 },
                 "createOrder",
                 exchange,
                 %{}
               )

      refute Map.has_key?(
               Bybit.build(
                 %{
                   "category" => "option",
                   "symbol" => "BTC-27MAR26-100000-C-USDT",
                   "type" => "limit",
                   "side" => "buy",
                   "amount" => 1,
                   "price" => 1
                 },
                 "createOrder",
                 exchange,
                 %{}
               ),
               "orderLinkId"
             )

      assert %{"amount" => "1.25"} =
               Bybit.build(
                 %{"from_account" => "unified", "to_account" => "fund", "code" => "USDT", "amount" => "1.25"},
                 "transfer",
                 exchange,
                 %{}
               )
    end

    test "maps deribit fetchOHLCV timeframe to resolution" do
      {:ok, exchange} = Exchange.new("deribit")

      params = Bourse.Unified.maybe_translate_timeframe(%{"symbol" => "BTC-PERPETUAL", "timeframe" => "1h"}, exchange)

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV")

      assert shaped["resolution"] == "60"
      refute Map.has_key?(shaped, "timeframe")
    end

    test "builds deribit fetchOHLCV timestamps from since, limit, and timeframe" do
      {:ok, exchange} = Exchange.new("deribit")
      since = 1_689_335_160_000
      until_ms = since + 5 * 60 * 60 * 1000

      params =
        %{
          "symbol" => "BTC/USDT:USDT",
          "timeframe" => "1h",
          "since" => since,
          "until" => until_ms,
          "limit" => 10
        }
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> Bourse.Unified.maybe_translate_timeframe(exchange)

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV", timestamp_ms_override: 1_700_000_000_000)

      assert shaped == %{
               "instrument_name" => "BTC_USDT-PERPETUAL",
               "resolution" => "60",
               "start_timestamp" => since,
               "end_timestamp" => until_ms
             }
    end

    test "builds deribit fetchOHLCV default window from the frozen clock" do
      {:ok, exchange} = Exchange.new("deribit")
      now = 1_705_557_450_518

      params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => "BTC/USDT"}, exchange)
      shaped = RequestShape.apply(params, exchange, "fetchOHLCV", timestamp_ms_override: now)

      assert shaped["resolution"] == "1"
      assert shaped["end_timestamp"] == now
      assert shaped["start_timestamp"] == now - 999 * 60 * 1000
      refute Map.has_key?(shaped, "since")
      refute Map.has_key?(shaped, "limit")
    end

    test "applies authored references, conditions, transformations, and omissions" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{
          "fetchTicker" => %{
            "_omit" => ["side"],
            "currency" => %{"kind" => "reference", "source" => "code"},
            "instrument_name" => %{
              "kind" => "reference",
              "source" => "symbol",
              "transform" => "date_yymmdd_to_ddmmmyy"
            },
            "type" => %{
              "kind" => "conditional",
              "source" => "type",
              "cases" => [%{"when" => %{"trailingAmount" => "present"}, "value" => "trailing_stop"}]
            }
          }
        }
      }

      shaped =
        RequestShape.apply(
          %{
            "code" => "BTC",
            "symbol" => "BTC-240126-39000-C",
            "side" => "sell",
            "type" => "market",
            "trailingAmount" => 1000
          },
          exchange,
          "fetchTicker"
        )

      assert shaped["currency"] == "BTC"
      assert shaped["instrument_name"] == "BTC-26JAN24-39000-C"
      assert shaped["type"] == "trailing_stop"
      refute Map.has_key?(shaped, "code")
      refute Map.has_key?(shaped, "symbol")
      refute Map.has_key?(shaped, "side")
    end

    test "covers authored omission, retention, decrement, and exact conditional branches" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{
          "fetchTicker" => %{
            "discard" => %{"kind" => "omit"},
            "kept" => %{"kind" => "reference", "source" => "source", "retain_source" => true},
            "previous" => %{"kind" => "reference", "source" => "count", "transform" => "decrement"},
            "mode" => %{
              "kind" => "conditional",
              "cases" => [
                %{
                  "when" => %{"flag" => true, "missing" => "absent", "source" => "present"},
                  "value" => "matched"
                }
              ]
            },
            "suppressed" => %{
              "kind" => "reference",
              "source" => "other",
              "unless_present" => "flag"
            }
          }
        }
      }

      shaped =
        RequestShape.apply(
          %{"discard" => true, "source" => "value", "other" => "ignored", "count" => 3, "flag" => true},
          exchange,
          "fetchTicker"
        )

      assert shaped["kept"] == "value"
      assert shaped["source"] == "value"
      assert shaped["previous"] == 2
      assert shaped["mode"] == "matched"
      refute Map.has_key?(shaped, "discard")
      refute Map.has_key?(shaped, "suppressed")
    end

    # Task 615 — caller-supplied native keys survive authored conditionals.
    # Distinctive values are ones no matching case would emit, so a clobber
    # cannot hide behind a coincidentally-equal default.
    test "caller-supplied native values survive every authored conditional entry" do
      for {venue, js_name, native_key, caller_value, extra} <- [
            {"binance", "setMarginMode", "marginType", "CROSSED", %{"symbol" => "BTCUSDT"}},
            {"binancecoinm", "setMarginMode", "marginType", "CROSSED", %{"symbol" => "BTCUSD_PERP"}},
            {"binanceusdm", "setMarginMode", "marginType", "CROSSED", %{"symbol" => "BTCUSDT"}},
            {"deribit", "createOrder", "trigger", "index_price",
             %{
               "amount" => 10,
               "side" => "sell",
               "symbol" => "BTC-PERPETUAL",
               "trigger_price" => 1,
               "type" => "stop_market"
             }},
            {"deribit", "createOrder", "type", "stop_market",
             %{
               "amount" => 10,
               "side" => "sell",
               "symbol" => "BTC-PERPETUAL",
               "trigger" => "index_price",
               "trigger_price" => 1
             }},
            {"okx", "fetchMarginAdjustmentHistory", "subType", "999", %{}},
            {"okx", "setPositionMode", "posMode", "net_mode", %{}}
          ] do
        {:ok, exchange} = Exchange.new(venue)
        params = Map.put(extra, native_key, caller_value)
        shaped = RequestShape.apply(params, exchange, js_name)

        assert shaped[native_key] == caller_value,
               "#{venue} #{js_name}.#{native_key} dropped caller #{inspect(caller_value)} → #{inspect(shaped)}"
      end
    end

    test "deribit trailingAmount still emits trigger=last_price and type=trailing_stop" do
      {:ok, exchange} = Exchange.new("deribit")

      shaped =
        RequestShape.apply(
          %{"amount" => 10, "side" => "sell", "symbol" => "BTC-PERPETUAL", "trailingAmount" => 1000},
          exchange,
          "createOrder"
        )

      assert shaped["trigger"] == "last_price"
      assert shaped["type"] == "trailing_stop"
      assert shaped["trigger_offset"] == 1000
    end

    test "covers authored time windows with until and non-string timeframe fallbacks" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{
          "fetchTicker" => %{
            "start" => %{
              "kind" => "computed",
              "operation" => "time_window_start",
              "default_limit" => 2,
              "default_timeframe_ms" => 30_000
            },
            "end" => %{
              "kind" => "computed",
              "operation" => "time_window_end",
              "default_limit" => 2,
              "default_timeframe_ms" => 30_000
            }
          }
        }
      }

      assert %{"start" => 90_000, "end" => 180_000} =
               RequestShape.apply(
                 %{"timeframe" => 1, "until" => 180_000},
                 exchange,
                 "fetchTicker",
                 timestamp_ms_override: 150_000
               )

      assert %{"start" => 120_000, "end" => 150_000} =
               RequestShape.apply(
                 %{"timeframe" => :invalid},
                 exchange,
                 "fetchTicker",
                 timestamp_ms_override: 150_000
               )

      assert %{"start" => -3_450_000, "end" => 150_000} =
               RequestShape.apply(
                 %{"timeframe" => "1h"},
                 exchange,
                 "fetchTicker",
                 timestamp_ms_override: 150_000
               )

      assert %{"start" => -86_250_000, "end" => 150_000} =
               RequestShape.apply(
                 %{"timeframe" => "1d"},
                 exchange,
                 "fetchTicker",
                 timestamp_ms_override: 150_000
               )

      assert %{"start" => 120_000, "end" => 150_000} =
               RequestShape.apply(
                 %{"timeframe" => "not-a-timeframe"},
                 exchange,
                 "fetchTicker",
                 timestamp_ms_override: 150_000
               )
    end

    test "covers empty category and symbol-list fallbacks" do
      {:ok, exchange} = Exchange.new("bybit")

      assert RequestShape.apply_premarket(%{}, exchange, "fetchTicker") == %{}
      assert RequestShape.apply_premarket(%{"symbols" => []}, exchange, "fetchTickers") == %{"symbols" => []}
    end

    test "covers legacy dynamic resolution construction" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{
          "fetchOHLCV" => %{
            "resolution" => %{"reason" => "dynamic_construction"}
          }
        }
      }

      assert RequestShape.apply(%{"timeframe" => "5"}, exchange, "fetchOHLCV") == %{"resolution" => "5"}
    end

    test "date transform does not interpret a six-digit option strike as an expiry" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{
          "fetchOption" => %{
            "instrument_name" => %{
              "kind" => "reference",
              "source" => "symbol",
              "transform" => "date_yymmdd_to_ddmmmyy"
            }
          }
        }
      }

      shaped = RequestShape.apply(%{"symbol" => "BTC-241227-240000-C"}, exchange, "fetchOption")

      assert shaped["instrument_name"] == "BTC-27DEC24-240000-C"
    end

    test "injects the Deribit fetchFundingRate 8h timestamp window" do
      {:ok, exchange} = Exchange.new("deribit")
      now = System.os_time(:millisecond)

      params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => "BTC-PERPETUAL"}, exchange)

      shaped = RequestShape.apply(params, exchange, "fetchFundingRate")

      assert shaped["instrument_name"] == "BTC-PERPETUAL"
      assert is_integer(shaped["start_timestamp"])
      assert is_integer(shaped["end_timestamp"])
      assert shaped["end_timestamp"] - shaped["start_timestamp"] == 8 * 60 * 60 * 1000
      assert shaped["end_timestamp"] <= now + 1_000
      assert shaped["start_timestamp"] >= now - 8 * 60 * 60 * 1000 - 1_000
      refute shaped["end_timestamp"] == shaped["instrument_name"]
    end

    test "deribit currency request shapes use the authored code reference" do
      {:ok, exchange} = Exchange.new("deribit")

      trading_fees =
        %{}
        |> Bourse.Unified.maybe_merge_request_defaults(exchange, "fetchTradingFees")
        |> RequestShape.apply(exchange, "fetchTradingFees")

      transfers = RequestShape.apply(%{"code" => "BTC"}, exchange, "fetchTransfers")

      withdraw =
        RequestShape.apply(
          %{"code" => "BTC", "amount" => 0.001, "address" => "invalid-address-for-task-237"},
          exchange,
          "withdraw"
        )

      assert trading_fees["currency"] == "BTC"
      assert trading_fees["extended"] == true
      refute Map.has_key?(trading_fees, "code")

      assert transfers == %{"currency" => "BTC"}
      assert withdraw["currency"] == "BTC"
      assert withdraw["amount"] == 0.001
      assert withdraw["address"] == "invalid-address-for-task-237"
      refute Map.has_key?(withdraw, "code")
    end

    # Task 344 — residual Deribit identifier_reference renames that raised before authoring.
    test "deribit fetchOrderTrades renames unified id to order_id" do
      {:ok, exchange} = Exchange.new("deribit")

      shaped =
        RequestShape.apply(%{"id" => "20906817839", "symbol" => "BTC/USD:BTC"}, exchange, "fetchOrderTrades")

      assert shaped == %{"order_id" => "20906817839"}
      refute Map.has_key?(shaped, "id")
      refute Map.has_key?(shaped, "symbol")
    end

    test "deribit by-instrument settlement shapes map symbol to instrument_name" do
      {:ok, exchange} = Exchange.new("deribit")

      my_liqs =
        RequestShape.apply(%{"symbol" => "BTC-PERPETUAL"}, exchange, "fetchMyLiquidations")

      assert my_liqs["instrument_name"] == "BTC-PERPETUAL"
      # Full-file literal survives deep-merge with the authored instrument_name entry.
      assert my_liqs["type"] == "bankruptcy"
      refute Map.has_key?(my_liqs, "symbol")

      # Optional symbol: omission is correct (no raise, no fabricated instrument_name).
      assert RequestShape.apply(%{}, exchange, "fetchMyLiquidations") == %{"type" => "bankruptcy"}

      liquidations =
        RequestShape.apply(%{"symbol" => "BTC-PERPETUAL"}, exchange, "fetchLiquidations")

      assert liquidations["instrument_name"] == "BTC-PERPETUAL"
      assert liquidations["type"] == "bankruptcy"

      open_interest =
        RequestShape.apply(%{"symbol" => "BTC-PERPETUAL"}, exchange, "fetchOpenInterest")

      assert open_interest == %{"instrument_name" => "BTC-PERPETUAL"}
    end

    test "unresolved identifier_reference returns a public error naming venue, method, param, and remedy" do
      exchange =
        Exchange.new!("deribit",
          credentials: Credentials.new!(api_key: "test-key", secret: "test-secret")
        )

      exchange = %{
        exchange
        | request_param_shape: %{
            "fetchBalance" => %{"mystery_param" => %{"reason" => "identifier_reference"}}
          }
      }

      assert {:error,
              %Error{
                type: :invalid_parameters,
                exchange: "deribit",
                raw: %{
                  "method" => "fetchBalance",
                  "parameter" => "mystery_param",
                  "reason" => "unresolved_identifier_reference"
                },
                message: message
              }} = Bourse.fetch_balance(exchange)

      assert message =~ "mystery_param"
      assert message =~ "mystery_param: value"
    end

    test "an unsupported synthetic venue gets no silent identifier fallback" do
      exchange = %Exchange{
        id: "kraken",
        name: "Unsupported",
        request_param_shape: %{
          "fetchBalance" => %{"mystery_param" => %{"reason" => "identifier_reference"}}
        }
      }

      error =
        assert_raise Error, fn ->
          RequestShape.apply(%{"code" => "BTC"}, exchange, "fetchBalance")
        end

      assert error.exchange == "kraken"
      assert error.message =~ "fetchBalance"
      assert error.message =~ "mystery_param"
    end

    test "deribit fetchFundingRate honors fixture-clock override for static replay" do
      {:ok, exchange} = Exchange.new("deribit")
      # Frozen end_timestamp from the CCXT compatibility fixture for Deribit fetchFundingRate.
      frozen_now = 1_705_562_067_483

      params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => "BTC-PERPETUAL"}, exchange)

      shaped =
        RequestShape.apply(params, exchange, "fetchFundingRate", timestamp_ms_override: frozen_now)

      assert shaped["instrument_name"] == "BTC-PERPETUAL"
      assert shaped["end_timestamp"] == frozen_now
      assert shaped["start_timestamp"] == frozen_now - 8 * 60 * 60 * 1000
    end

    test "deribit fetchFundingRate honors since/until and explicit timestamp overrides" do
      {:ok, exchange} = Exchange.new("deribit")

      params =
        Bourse.Unified.maybe_denormalize_symbol(
          %{"symbol" => "BTC-PERPETUAL", "since" => 1_700_000_000_000, "until" => 1_700_028_800_000},
          exchange
        )

      shaped = RequestShape.apply(params, exchange, "fetchFundingRate")

      assert shaped["start_timestamp"] == 1_700_000_000_000
      assert shaped["end_timestamp"] == 1_700_028_800_000

      override =
        RequestShape.apply(
          Map.merge(params, %{"start_timestamp" => 42, "end_timestamp" => 99}),
          exchange,
          "fetchFundingRate"
        )

      assert override["start_timestamp"] == 42
      assert override["end_timestamp"] == 99
    end

    test "builds hyperliquid fetchOHLCV POST body from spec defaults" do
      {:ok, exchange} = Exchange.new("hyperliquid")

      params = %{
        "symbol" => "BTC",
        "timeframe" => "1m",
        "since" => 1_700_000_000_000
      }

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV")
      assert shaped["type"] == "candleSnapshot"
      assert %{"coin" => "BTC", "interval" => "1m"} = shaped["req"]
      refute Map.has_key?(shaped, "symbol")
      refute Map.has_key?(shaped, "timeframe")
      refute Map.has_key?(shaped, "since")
    end

    # Task 333 — denormalized swap id ("BTCUSDC") must yield universe coin "BTC",
    # not the pair string; nested sources must not leak top-level.
    # Docs: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#candle-snapshot
    test "hyperliquid fetchOHLCV resolves universe coin after denormalize and drops unified leaks" do
      {:ok, exchange} = Exchange.new("hyperliquid")
      now = 1_784_210_000_000

      params =
        %{"symbol" => "BTC/USDC:USDC", "timeframe" => "1h", "limit" => 3}
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> Bourse.Unified.maybe_translate_timeframe(exchange)

      assert params["symbol"] == "BTCUSDC"

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV", timestamp_ms_override: now)

      assert shaped == %{
               "type" => "candleSnapshot",
               "req" => %{
                 "coin" => "BTC",
                 "interval" => "1h",
                 "startTime" => now - 3 * 60 * 60 * 1000,
                 "endTime" => now
               }
             }
    end

    test "hyperliquid fetchOHLCV with explicit since keeps that startTime and still drops leaks" do
      {:ok, exchange} = Exchange.new("hyperliquid")
      since = 1_700_000_000_000
      now = 1_784_210_000_000

      params =
        Bourse.Unified.maybe_denormalize_symbol(
          %{"symbol" => "BTC/USDC:USDC", "timeframe" => "1h", "since" => since, "limit" => 3},
          exchange
        )

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV", timestamp_ms_override: now)

      assert shaped["req"]["coin"] == "BTC"
      assert shaped["req"]["startTime"] == since
      assert shaped["req"]["endTime"] == now
      refute Map.has_key?(shaped, "symbol")
      refute Map.has_key?(shaped, "timeframe")
      refute Map.has_key?(shaped, "since")
      refute Map.has_key?(shaped, "limit")
    end

    test "hyperliquid fetchOHLCV without since/limit uses named default startTime 0" do
      {:ok, exchange} = Exchange.new("hyperliquid")
      now = 1_784_210_000_000

      params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => "BTC/USDC:USDC", "timeframe" => "1h"}, exchange)

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV", timestamp_ms_override: now)

      assert shaped["req"]["startTime"] == 0
      assert shaped["req"]["endTime"] == now
      assert shaped["req"]["coin"] == "BTC"
      assert shaped |> Map.keys() |> Enum.sort() == ["req", "type"]
    end

    test "hyperliquid fetchFundingRateHistory authors native coin and time fields" do
      {:ok, exchange} = Exchange.new("hyperliquid")
      now = 1_784_210_000_000
      since = now - 3 * 60 * 60 * 1000

      params =
        Bourse.Unified.maybe_denormalize_symbol(
          %{"symbol" => "BTC/USDC:USDC", "since" => since, "limit" => 3, "until" => now},
          exchange
        )

      assert RequestShape.apply(params, exchange, "fetchFundingRateHistory", timestamp_ms_override: now) == %{
               "type" => "fundingHistory",
               "coin" => "BTC",
               "startTime" => since,
               "endTime" => now
             }
    end

    test "hyperliquid fetchFundingRateHistory derives its required default startTime" do
      {:ok, exchange} = Exchange.new("hyperliquid")
      now = 1_784_210_000_000

      params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => "BTC/USDC:USDC", "limit" => 3}, exchange)

      assert RequestShape.apply(params, exchange, "fetchFundingRateHistory", timestamp_ms_override: now) == %{
               "type" => "fundingHistory",
               "coin" => "BTC",
               "startTime" => now - 3 * 60 * 60 * 1000
             }
    end

    test "resolves conditional_value coin from the symbol base (hyperliquid fetchOrderBook)" do
      {:ok, exchange} = Exchange.new("hyperliquid")

      shaped = RequestShape.apply(%{"symbol" => "BTC/USDC:USDC"}, exchange, "fetchOrderBook")

      assert shaped["coin"] == "BTC"
      assert shaped["type"] == "l2Book"
      refute Map.has_key?(shaped, "symbol")
    end

    test "hyperliquid fetchOrderBook coin survives denormalize (task 333)" do
      {:ok, exchange} = Exchange.new("hyperliquid")

      params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => "BTC/USDC:USDC"}, exchange)
      assert params["symbol"] == "BTCUSDC"

      shaped = RequestShape.apply(params, exchange, "fetchOrderBook")

      assert shaped == %{"type" => "l2Book", "coin" => "BTC"}
    end

    test "conditional_value coin is a no-op when symbol is absent" do
      {:ok, exchange} = Exchange.new("hyperliquid")

      shaped = RequestShape.apply(%{}, exchange, "fetchOrderBook")

      refute Map.has_key?(shaped, "coin")
      assert shaped["type"] == "l2Book"
    end

    test "carries an optional identifier_reference param through when present (okx fetchOHLCV limit)" do
      {:ok, exchange} = Exchange.new("okx")

      shaped = RequestShape.apply(%{"timeframe" => "1m", "limit" => 100}, exchange, "fetchOHLCV")

      assert shaped["limit"] == 100
    end

    test "maps okx fetchOHLCV symbol→instId and timeframe→bar without colliding" do
      {:ok, exchange} = Exchange.new("okx")

      params =
        %{"symbol" => "BTC/USDT", "timeframe" => "1h", "limit" => 100}
        |> Bourse.Unified.maybe_denormalize_symbol(exchange)
        |> Bourse.Unified.maybe_translate_timeframe(exchange)

      shaped = RequestShape.apply(params, exchange, "fetchOHLCV")

      assert shaped["instId"] == "BTC-USDT"
      assert shaped["bar"] == "1H"
      assert shaped["limit"] == 100
      refute Map.has_key?(shaped, "symbol")
      refute Map.has_key?(shaped, "timeframe")
    end

    test "okx fetchOHLCV authors venue defaults when optional timeframe and limit are absent" do
      {:ok, exchange} = Exchange.new("okx")

      shaped = RequestShape.apply(%{"timeframe" => "1m"}, exchange, "fetchOHLCV")

      assert shaped == %{"bar" => "1m", "limit" => 100}
    end

    test "okx fetchOHLCV maps explicit and until-only windows to exclusive cursors" do
      {:ok, exchange} = Exchange.new("okx")
      since = 1_700_000_000_000
      until_ms = since + 5 * 60_000

      assert %{
               "after" => ^until_ms,
               "before" => 1_699_999_999_999,
               "bar" => "1m",
               "limit" => 5
             } =
               RequestShape.apply(
                 %{"timeframe" => "1m", "since" => since, "until" => until_ms, "limit" => 5},
                 exchange,
                 "fetchOHLCV"
               )

      assert %{
               "after" => ^until_ms,
               "before" => 1_699_999_999_999,
               "bar" => "1m",
               "limit" => 5
             } =
               RequestShape.apply(
                 %{"timeframe" => "1m", "until" => until_ms, "limit" => 5},
                 exchange,
                 "fetchOHLCV"
               )
    end

    test "dynamic_construction is a no-op when its source param is absent (deepcoin fetchBalance instType)" do
      reference_shape =
        "deepcoin"
        |> ReferenceSlice.spec_path()
        |> Bourse.JsonDocument.decode_file!()
        |> get_in(["normalization", "request_param_shape", "fetchBalance"])

      exchange = %Exchange{
        id: "deepcoin_reference",
        name: "Deepcoin Reference Shape",
        request_param_shape: %{"fetchBalance" => reference_shape}
      }

      shaped = RequestShape.apply(%{}, exchange, "fetchBalance")

      refute Map.has_key?(shaped, "instType")
    end

    test "unknown dynamic_construction entry is a no-op" do
      exchange = %Exchange{
        id: "shape_test",
        name: "Shape Test",
        request_param_shape: %{"fetchTicker" => %{"custom" => %{"reason" => "dynamic_construction"}}}
      }

      assert RequestShape.apply(%{}, exchange, "fetchTicker") == %{}
    end

    test "hyperliquid /info POST request_param_shape literals for fetchMarkets + fetchTicker (T191)" do
      {:ok, ex} = Exchange.new("hyperliquid")

      # request_defaults (literal projection used by unified). fetchMarkets asks for
      # metaAndAssetCtxs, not bare meta — the ctxs carry the mark/mid the price tick
      # is derived from (task 370, carve C-T370-1).
      assert %{"type" => "metaAndAssetCtxs"} == ex.request_defaults["fetchMarkets"]
      assert %{"type" => "metaAndAssetCtxs"} == ex.request_defaults["fetchTicker"]
      assert %{"type" => "metaAndAssetCtxs"} == ex.request_defaults["fetchTickers"]

      # full shape (authored source)
      assert %{"kind" => "literal", "reason" => nil, "value" => "metaAndAssetCtxs"} ==
               get_in(ex.request_param_shape, ["fetchMarkets", "type"])

      assert %{"kind" => "literal", "reason" => nil, "value" => "metaAndAssetCtxs"} ==
               get_in(ex.request_param_shape, ["fetchTicker", "type"])

      # injection produces the body fields
      assert %{"type" => "metaAndAssetCtxs"} == RequestShape.apply(%{}, ex, "fetchMarkets")
      assert %{"type" => "metaAndAssetCtxs"} == RequestShape.apply(%{}, ex, "fetchTicker")
    end

    test "hyperliquid account /info request shapes derive user from credentials (T216)" do
      {:ok, ex} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert %{"type" => "clearinghouseState", "user" => "0xwallet"} =
               RequestShape.apply(%{}, ex, "fetchBalance")

      assert %{"type" => "clearinghouseState", "user" => "0xwallet"} =
               RequestShape.apply(%{}, ex, "fetchPositions")

      assert %{"type" => "frontendOpenOrders", "user" => "0xwallet"} =
               RequestShape.apply(%{}, ex, "fetchOpenOrders")

      assert %{"type" => "userFills", "user" => "0xwallet"} =
               RequestShape.apply(%{}, ex, "fetchMyTrades")

      assert %{"type" => "userFees", "user" => "0xwallet"} =
               RequestShape.apply(%{}, ex, "fetchTradingFee")
    end

    test "hyperliquid fetchBalance turns the unified spot selector into spotClearinghouseState" do
      {:ok, ex} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert %{"type" => "spotClearinghouseState", "user" => "0xwallet"} =
               RequestShape.apply(%{"type" => "spot"}, ex, "fetchBalance")
    end

    # Static request fixtures establish userFills + user; Bourse hyperliquid.ts
    # establishes the by-time branch — userFillsByTime + startTime when since is present.
    test "hyperliquid fetchMyTrades uses userFills without since (T219)" do
      {:ok, ex} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert %{"type" => "userFills", "user" => "0xwallet"} =
               RequestShape.apply(%{}, ex, "fetchMyTrades")

      refute Map.has_key?(RequestShape.apply(%{}, ex, "fetchMyTrades"), "startTime")
    end

    test "hyperliquid fetchMyTrades uses userFillsByTime + startTime when since present (T219)" do
      {:ok, ex} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)
      since = 1_704_262_888_911

      shaped = RequestShape.apply(%{"since" => since}, ex, "fetchMyTrades")

      assert shaped == %{
               "type" => "userFillsByTime",
               "user" => "0xwallet",
               "startTime" => since
             }

      refute Map.has_key?(shaped, "since")
    end

    test "hyperliquid fetchMyTrades keeps explicit user over credentials on both type branches (T219)" do
      {:ok, ex} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert %{"type" => "userFills", "user" => "0xexplicit"} =
               RequestShape.apply(%{"user" => "0xexplicit"}, ex, "fetchMyTrades")

      assert %{"type" => "userFillsByTime", "user" => "0xexplicit", "startTime" => 100} =
               RequestShape.apply(%{"user" => "0xexplicit", "since" => 100}, ex, "fetchMyTrades")
    end

    test "hyperliquid account /info request shape keeps explicit user over credentials" do
      {:ok, ex} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      assert %{"type" => "clearinghouseState", "user" => "0xexplicit"} =
               RequestShape.apply(%{"user" => "0xexplicit"}, ex, "fetchPositions")
    end

    test "hyperliquid residual account /info reads derive user from credentials (T218)" do
      {:ok, ex} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      # Each residual account-read keeps its frozen `type` literal and injects the
      # credential-derived wallet as `user` (source: api_key) so the /info body is
      # not sent without the wallet (the 400 that T216 fixed for balance/positions).
      residuals = [
        {"fetchDeposits", "userNonFundingLedgerUpdates"},
        {"fetchWithdrawals", "userNonFundingLedgerUpdates"},
        {"fetchLedger", "userNonFundingLedgerUpdates"},
        {"fetchFundingHistory", "userFunding"},
        {"fetchOrder", "orderStatus"},
        {"fetchOrders", "historicalOrders"}
      ]

      for {js_name, type} <- residuals do
        assert %{"type" => ^type, "user" => "0xwallet"} = RequestShape.apply(%{}, ex, js_name),
               "#{js_name} should inject credential-derived user with type #{type}"
      end
    end

    test "hyperliquid residual account /info reads keep explicit user over credentials (T218)" do
      {:ok, ex} = Exchange.new("hyperliquid", api_key: "0xwallet", secret: "privkey", sandbox: true)

      for js_name <- ~w(fetchDeposits fetchWithdrawals fetchLedger fetchFundingHistory fetchOrder fetchOrders) do
        assert %{"user" => "0xexplicit"} =
                 RequestShape.apply(%{"user" => "0xexplicit"}, ex, js_name),
               "#{js_name} must not overwrite an explicit caller-supplied user"
      end
    end

    test "hyperliquid residual account /info reads omit user without credentials (T218)" do
      {:ok, ex} = Exchange.new("hyperliquid")

      # No api_key → no wallet to inject; the frozen `type` literal still applies but
      # `user` is left unset (Bourse raises ArgumentsRequired at that boundary, not us).
      shaped = RequestShape.apply(%{}, ex, "fetchLedger")
      assert shaped == %{"type" => "userNonFundingLedgerUpdates"}
      refute Map.has_key?(shaped, "user")
    end

    test "lighter fetchTicker market_id is dynamic_construction (numeric market id, T197)" do
      {:ok, exchange} = Exchange.new("lighter")

      assert %{"reason" => "dynamic_construction"} =
               get_in(exchange.request_param_shape, ["fetchTicker", "market_id"])

      # Without a resolved market_id, do not invent one from the symbol string
      # (the old identifier_reference path produced market_id="BTCUSDC" → API 20001).
      shaped_missing =
        RequestShape.apply(%{"symbol" => "BTC/USDC:USDC"}, exchange, "fetchTicker")

      refute Map.has_key?(shaped_missing, "market_id")

      # Once Unified injects market_id from loadMarkets/market.id, apply carries it
      # and drops the leftover unified symbol so the API is not sent an invalid param.
      shaped =
        RequestShape.apply(
          %{"symbol" => "BTC/USDC:USDC", "market_id" => 1},
          exchange,
          "fetchTicker"
        )

      assert shaped["market_id"] == 1
      refute Map.has_key?(shaped, "symbol")
    end

    test "hyperliquid cancelOrder builds L1 cancel action from id+symbol (task 331)" do
      exchange =
        Bourse.ReplayExchange.build!("hyperliquid", %{})

      shaped =
        RequestShape.apply(
          %{"id" => 6_466_108_935, "symbol" => "SOL/USDC:USDC"},
          exchange,
          "cancelOrder",
          timestamp_ms_override: 1_709_205_271_182
        )

      assert shaped["nonce"] == 1_709_205_271_182

      assert shaped["action"] == %{
               "type" => "cancel",
               "cancels" => [%{"a" => 5, "o" => 6_466_108_935}]
             }

      refute Map.has_key?(shaped, "id")
      refute Map.has_key?(shaped, "symbol")
    end

    test "hyperliquid transfer builds usdClassTransfer action for spot->swap (task 331)" do
      exchange =
        Bourse.ReplayExchange.build!("hyperliquid", %{})

      shaped =
        RequestShape.apply(
          %{
            "code" => "USDC",
            "amount" => 100,
            "from_account" => "spot",
            "to_account" => "swap"
          },
          exchange,
          "transfer",
          timestamp_ms_override: 1_733_369_421_517
        )

      assert shaped["action"] == %{
               "hyperliquidChain" => "Mainnet",
               "signatureChainId" => "0x66eee",
               "type" => "usdClassTransfer",
               "amount" => "100",
               "toPerp" => true,
               "nonce" => 1_733_369_421_517
             }

      assert shaped["nonce"] == 1_733_369_421_517
      refute Map.has_key?(shaped, "code")
    end

    test "hyperliquid withdraw with vaultAddress builds vaultTransfer L1 action (task 384)" do
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})
      vault = "0xc751489d24a33172541ea451bc253d7a9e98c781"

      vault_shaped =
        RequestShape.apply(
          %{
            "code" => "USDC",
            "amount" => 100,
            "address" => vault,
            "vaultAddress" => vault
          },
          exchange,
          "withdraw",
          timestamp_ms_override: 1_718_449_507_245
        )

      # `usd` is 1e6 micro-USD per the official Python SDK (`vault_usd_transfer`
      # examples pass 5_000_000 for "5 usd"), matching the identically-shaped
      # subAccountTransfer. Bourse sends the bare amount here — a Bourse bug we
      # deliberately DIVERGE from; carve C-T384, fixture #1144 stays red.
      assert vault_shaped["action"] == %{
               "type" => "vaultTransfer",
               "vaultAddress" => vault,
               "isDeposit" => false,
               "usd" => 100_000_000
             }

      assert vault_shaped["nonce"] == 1_718_449_507_245
      refute Map.has_key?(vault_shaped, "vaultAddress")

      # Sub-dollar precision survives: micro-units represent cents exactly, so a
      # fractional withdraw is not silently rounded to whole dollars.
      cents_shaped =
        RequestShape.apply(
          %{"code" => "USDC", "amount" => 10.5, "address" => vault, "vaultAddress" => vault},
          exchange,
          "withdraw",
          timestamp_ms_override: 1_718_449_507_245
        )

      assert cents_shaped["action"]["usd"] == 10_500_000

      bridge_shaped =
        RequestShape.apply(
          %{"code" => "USDC", "amount" => 100, "address" => vault},
          exchange,
          "withdraw",
          timestamp_ms_override: 1_718_449_507_245
        )

      assert bridge_shaped["action"]["type"] == "withdraw3"
      assert bridge_shaped["action"]["destination"] == vault
    end

    test "hyperliquid signer-owned action fields are not request-shape requirements (task 417)" do
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})

      shaped =
        RequestShape.apply(
          %{"symbol" => "BTC/USDC:USDC", "id" => "123"},
          exchange,
          "cancelTwapOrder"
        )

      refute Map.has_key?(shaped, "action")
      refute Map.has_key?(shaped, "nonce")
      refute Map.has_key?(shaped, "signature")
    end

    test "hyperliquid schedule-cancel reaches the signer with its wire envelope (task 417)" do
      nonce = 1_700_000_000_000
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})

      shaped =
        RequestShape.apply(%{"timeout" => 0}, exchange, "cancelAllOrdersAfter", timestamp_ms_override: nonce)

      credentials =
        Credentials.new!(
          api_key: "0x0000000000000000000000000000000000000000",
          secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
        )

      body =
        %{method: :post, path: "https://api.hyperliquid.xyz/exchange", body: nil, params: shaped}
        |> Hyperliquid.sign(credentials, %{testnet: true})
        |> Map.fetch!(:body)
        |> Jason.decode!()

      assert body["action"] == %{"type" => "scheduleCancel", "time" => nonce}
      assert body["nonce"] == nonce
      assert %{"r" => _, "s" => _, "v" => _} = body["signature"]
    end

    test "hyperliquid schedule-cancel offsets the timer from the nonce (task 417)" do
      nonce = 1_700_000_000_000
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})

      shaped =
        RequestShape.apply(%{"timeout" => 60_000}, exchange, "cancelAllOrdersAfter", timestamp_ms_override: nonce)

      # Hyperliquid cancelAllOrdersAfter uses `time: nonce + timeout`.
      assert shaped["action"] == %{"type" => "scheduleCancel", "time" => nonce + 60_000}
    end

    test "hyperliquid schedule-cancel rejects an unusable timeout instead of dropping the action (task 417)" do
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})

      # Dropping the signer-owned action/nonce slots removed the identifier
      # guard that used to catch this, so the builder must fail loudly rather
      # than shape an action-less body onto the wire.
      for bad <- [nil, 60_000.0, "soon"] do
        assert_raise ArgumentError, ~r/hyperliquid action build/, fn ->
          RequestShape.apply(%{"timeout" => bad}, exchange, "cancelAllOrdersAfter")
        end
      end

      assert_raise ArgumentError, ~r/non-negative timeout/, fn ->
        RequestShape.apply(%{"timeout" => -1}, exchange, "cancelAllOrdersAfter")
      end
    end

    test "hyperliquid accepts an explicit action override without rebuilding (task 331)" do
      exchange =
        Bourse.ReplayExchange.build!("hyperliquid", %{})

      action = %{"type" => "cancel", "cancels" => [%{"a" => 0, "o" => 1}]}

      shaped =
        RequestShape.apply(
          %{"action" => action, "id" => 99, "symbol" => "BTC/USDC:USDC"},
          exchange,
          "cancelOrder",
          timestamp_ms_override: 42
        )

      assert shaped["action"] == action
      assert shaped["nonce"] == 42
    end

    # Task 353 — number_string must canonicalize binary size/price to Hyperliquid
    # wire form (trailing zeros stripped). Passthrough of "0.00020" produces a
    # different L1 msgpack hash than the venue reconstructs → garbage signer.
    test "hyperliquid createOrders canonicalizes non-canonical size/price strings (task 353)" do
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})

      shaped =
        RequestShape.apply(
          %{
            "orders" => [
              %{
                "symbol" => "SOL/USDC:USDC",
                "side" => "buy",
                "type" => "limit",
                "amount" => "0.00020",
                "price" => "60.0"
              }
            ]
          },
          exchange,
          "createOrders",
          timestamp_ms_override: 1_709_643_776_143
        )

      [row] = shaped["action"]["orders"]
      assert row["s"] == "0.0002"
      assert row["p"] == "60"
    end

    test "hyperliquid createOrder builds the same one-row L1 action as createOrders (task 354)" do
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})
      nonce = 1_709_643_776_143

      order = %{
        "symbol" => "SOL/USDC:USDC",
        "side" => "buy",
        "type" => "limit",
        "amount" => "0.00020",
        "price" => "60.0"
      }

      singular = RequestShape.apply(order, exchange, "createOrder", timestamp_ms_override: nonce)

      batch =
        RequestShape.apply(%{"orders" => [order]}, exchange, "createOrders", timestamp_ms_override: nonce)

      assert singular["nonce"] == nonce
      assert singular["action"] == batch["action"]

      assert singular["action"] == %{
               "type" => "order",
               "orders" => [
                 %{
                   "a" => 5,
                   "b" => true,
                   "p" => "60",
                   "s" => "0.0002",
                   "r" => false,
                   "t" => %{"limit" => %{"tif" => "Gtc"}}
                 }
               ],
               "grouping" => "na"
             }

      dispatch_exchange =
        Exchange.put_markets(exchange, [
          %Bourse.Market{
            id: "SOLUSDC",
            symbol: "SOL/USDC:USDC",
            asset_index: 5,
            precision: %{"amount" => 0.0001, "price" => 0.1}
          }
        ])

      stub = {__MODULE__, :hyperliquid_create_order, System.unique_integer([:positive])}
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:hyperliquid_create_order, body})
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{body: %{}}} =
               Bourse.Unified.capture_responses(dispatch_exchange, :create_order, order,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: nonce
               )

      assert_receive {:hyperliquid_create_order, body}, @receive_timeout_ms

      assert %{
               "action" => %{"type" => "order", "orders" => [row], "grouping" => "na"},
               "nonce" => ^nonce,
               "signature" => %{"r" => "0x" <> _, "s" => "0x" <> _, "v" => _}
             } = Jason.decode!(body)

      assert Map.take(row, ["a", "b", "p", "s", "r", "t"]) == %{
               "a" => 5,
               "b" => true,
               "p" => "60",
               "s" => "0.0002",
               "r" => false,
               "t" => %{"limit" => %{"tif" => "Gtc"}}
             }
    end

    test "hyperliquid createOrders number_string wire form for trailing-zero and integer-valued strings (task 353)" do
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})

      cases = [
        {"0.00020", "12345.0", "0.0002", "12345"},
        {"1.00", "0.10", "1", "0.1"},
        {"0.123450", "10", "0.12345", "10"},
        {"100", "1.2300", "100", "1.23"}
      ]

      for {amount, price, want_s, want_p} <- cases do
        shaped =
          RequestShape.apply(
            %{
              "orders" => [
                %{
                  "symbol" => "SOL/USDC:USDC",
                  "side" => "buy",
                  "type" => "limit",
                  "amount" => amount,
                  "price" => price
                }
              ]
            },
            exchange,
            "createOrders",
            timestamp_ms_override: 1
          )

        [row] = shaped["action"]["orders"]
        assert row["s"] == want_s, "amount #{inspect(amount)} → #{inspect(row["s"])}, want #{inspect(want_s)}"
        assert row["p"] == want_p, "price #{inspect(price)} → #{inspect(row["p"])}, want #{inspect(want_p)}"
      end
    end

    test "hyperliquid createOrders rejects non-numeric size strings before signing (task 353)" do
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})

      assert_raise ArgumentError, ~r/expected numeric string/, fn ->
        RequestShape.apply(
          %{
            "orders" => [
              %{
                "symbol" => "SOL/USDC:USDC",
                "side" => "buy",
                "type" => "limit",
                "amount" => "not-a-number",
                "price" => "60"
              }
            ]
          },
          exchange,
          "createOrders",
          timestamp_ms_override: 1
        )
      end
    end

    test "hyperliquid createOrders non-canonical size string yields same L1 signature as float (task 353)" do
      exchange = Bourse.ReplayExchange.build!("hyperliquid", %{})
      private_key = "0x0123456789012345678901234567890123456789012345678901234567890123"
      nonce = 1_709_643_776_143

      order = fn amount, price ->
        %{
          "orders" => [
            %{
              "symbol" => "SOL/USDC:USDC",
              "side" => "buy",
              "type" => "limit",
              "amount" => amount,
              "price" => price
            }
          ]
        }
      end

      string_shaped =
        RequestShape.apply(order.("0.00020", "60.0"), exchange, "createOrders", timestamp_ms_override: nonce)

      float_shaped =
        RequestShape.apply(order.(0.0002, 60.0), exchange, "createOrders", timestamp_ms_override: nonce)

      assert string_shaped["action"] == float_shaped["action"]
      assert string_shaped["action"]["orders"] |> hd() |> Map.take(["p", "s"]) == %{"p" => "60", "s" => "0.0002"}

      string_sig =
        Hyperliquid.sign_l1_action(string_shaped["action"], nonce,
          private_key: private_key,
          testnet: true
        )

      float_sig =
        Hyperliquid.sign_l1_action(float_shaped["action"], nonce,
          private_key: private_key,
          testnet: true
        )

      assert string_sig == float_sig
    end
  end
end
