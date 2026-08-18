defmodule Bourse.ExchangeAcceptanceFixturesTest do
  use ExUnit.Case, async: false

  alias Bourse.ExchangeAcceptanceFixtures

  @credential_env %{
    "alpaca" => ~w(ALPACA_API_KEY ALPACA_API_SECRET),
    "binance" => ~w(
        BINANCE_TESTNET_API_KEY
        BINANCE_TESTNET_API_SECRET
        BINANCE_FUTURES_TEST_API_KEY
        BINANCE_FUTURES_TEST_API_SECRET
      ),
    "binancecoinm" => ~w(BINANCE_FUTURES_TEST_API_KEY BINANCE_FUTURES_TEST_API_SECRET),
    "binanceusdm" => ~w(BINANCE_FUTURES_TEST_API_KEY BINANCE_FUTURES_TEST_API_SECRET),
    "bybit" => ~w(BYBIT_DEMO_API_KEY BYBIT_DEMO_API_SECRET),
    "deribit" => ~w(DERIBIT_TESTNET_API_KEY DERIBIT_TESTNET_API_SECRET),
    "derive" => ~w(DERIVE_TESTNET_API_KEY DERIVE_TESTNET_API_SECRET),
    "okx" => ~w(OKX_INTL_API_KEY OKX_INTL_API_SECRET OKX_INTL_PASSPHRASE)
  }

  test "catalog exposes every first-class profile and fixture root" do
    venues = ExchangeAcceptanceFixtures.authenticated_venues()
    profiles = ExchangeAcceptanceFixtures.profiles()

    assert venues == ~w(alpaca binance binancecoinm binanceusdm bybit deribit derive hyperliquid lighter okx)
    assert {"binance", :fetch_balance, :fetch_balance} in profiles
    assert {"binance", :fetch_balance_spot, :fetch_balance} in profiles
    assert {"binance", :create_order, :create_order} in profiles
    assert {"binancecoinm", :fetch_balance, :fetch_balance} in profiles
    assert {"binancecoinm", :set_leverage, :set_leverage} in profiles
    assert {"binanceusdm", :set_position_mode, :set_position_mode} in profiles
    assert ExchangeAcceptanceFixtures.fixture_root() =~ "test/fixtures/exchange_accepted_requests"

    assert ExchangeAcceptanceFixtures.manifest_path() ==
             Path.join(ExchangeAcceptanceFixtures.fixture_root(), "_manifest.json")
  end

  test "credential material detection rejects nested values without false positives" do
    secret = "live-secret-material"

    assert {:error, :sensitive_material_present} =
             ExchangeAcceptanceFixtures.validate_no_material(
               %{"request" => [%{"headers" => {"authorization", secret}}]},
               [nil, "", secret]
             )

    assert :ok =
             ExchangeAcceptanceFixtures.validate_no_material(
               %{"request" => [%{"headers" => {"authorization", "fixture-slot"}}]},
               [nil, "", secret]
             )
  end

  test "fixture paths distinguish venues with multiple profiles and reject unknown methods" do
    assert_raise ArgumentError, ~r/alpaca has multiple accepted-request profiles/, fn ->
      ExchangeAcceptanceFixtures.fixture_path("alpaca")
    end

    assert_raise ArgumentError, ~r/binance has multiple accepted-request profiles/, fn ->
      ExchangeAcceptanceFixtures.fixture_path("binance")
    end

    assert ExchangeAcceptanceFixtures.fixture_path("deribit") =~ "deribit/fetch_balance.json"

    assert ExchangeAcceptanceFixtures.fixture_path("binance", :fetch_balance_spot) =~
             "binance/fetch_balance_spot.json"

    assert_raise ArgumentError, ~r/unknown accepted-request profile/, fn ->
      ExchangeAcceptanceFixtures.fixture_path("deribit", :fetch_ticker)
    end
  end

  test "record rejects venues with multiple profiles and names missing credentials" do
    assert {:error, {:multiple_acceptance_profiles, "alpaca"}} =
             ExchangeAcceptanceFixtures.record("alpaca", transport: &success_transport/1)

    assert {:error, {:multiple_acceptance_profiles, "binance"}} =
             ExchangeAcceptanceFixtures.record("binance", transport: &success_transport/1)

    with_env(@credential_env["deribit"], nil, fn ->
      assert {:error, {:missing_credentials, missing}} =
               ExchangeAcceptanceFixtures.record("deribit", transport: &success_transport/1)

      assert missing == @credential_env["deribit"]
    end)
  end

  test "default transports still fail before network when credentials are absent" do
    with_env(@credential_env["deribit"], nil, fn ->
      assert {:error, {:missing_credentials, missing}} =
               ExchangeAcceptanceFixtures.record("deribit")

      assert {:error, {:fetch_balance, {:missing_credentials, ^missing}}} =
               ExchangeAcceptanceFixtures.record_all("deribit")
    end)
  end

  test "default transport honors the configured Req plug" do
    stub = {__MODULE__, :deribit_default_transport, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => %{}})
    end)

    with_env(@credential_env["deribit"], "offline-deribit-credential", fn ->
      with_http_stub(stub, fn ->
        assert {:ok, golden} = ExchangeAcceptanceFixtures.record("deribit")
        assert :ok = ExchangeAcceptanceFixtures.replay(golden)
      end)
    end)
  end

  test "replay rejects an unknown method name" do
    golden =
      ExchangeAcceptanceFixtures.load_all!()
      |> Enum.find(&(get_in(&1, ["acceptance", "venue"]) == "deribit"))
      |> put_in(["replay", "method"], "not_a_unified_method")

    assert {:error, :invalid_replay_identity} = ExchangeAcceptanceFixtures.replay(golden)
  end

  test "injected transport records signed reads without reaching the network" do
    for venue <- ~w(deribit okx) do
      with_env(@credential_env[venue], &credential_value(venue, &1), fn ->
        result = ExchangeAcceptanceFixtures.record(venue, transport: &success_transport/1)

        golden =
          case result do
            {:ok, golden} -> golden
            other -> flunk("#{venue}: #{inspect(other)}")
          end

        assert get_in(golden, ["acceptance", "venue"]) == venue
        assert get_in(golden, ["acceptance", "http_status"]) == 200
        assert :ok = ExchangeAcceptanceFixtures.replay(golden)
      end)
    end
  end

  test "injected transport records dedicated Binance futures write profiles" do
    stub = {__MODULE__, :dedicated_binance_acceptance_setup, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", path} when path in ["/fapi/v1/ticker/24hr", "/dapi/v1/ticker/24hr"] ->
          Req.Test.json(conn, %{"lastPrice" => "2000"})

        {"DELETE", path} when path in ["/fapi/v1/order", "/dapi/v1/order"] ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"code" => -2011, "msg" => "Unknown order sent."})

        {"DELETE", path} when path in ["/fapi/v1/algoOrder", "/dapi/v1/algoOrder"] ->
          Req.Test.json(conn, %{"algoId" => 1, "algoStatus" => "CANCELED"})

        {"POST", path}
        when path in ["/fapi/v1/marginType", "/dapi/v1/marginType", "/fapi/v1/positionSide/dual"] ->
          Req.Test.json(conn, %{"code" => 200, "msg" => "success"})
      end
    end)

    for venue <- ~w(binanceusdm binancecoinm) do
      with_env(@credential_env[venue], "offline-binance-futures-credential", fn ->
        with_http_stub(stub, fn ->
          assert {:ok, goldens} =
                   ExchangeAcceptanceFixtures.record_all(venue, transport: &success_transport/1)

          expected_profiles = ["fetch_balance", "create_order", "set_margin_mode", "cancel_all_orders"]

          expected_profiles =
            case venue do
              "binanceusdm" ->
                expected_profiles ++
                  [
                    "set_position_mode",
                    "fetch_order_algo",
                    "fetch_open_order_algo",
                    "fetch_orders_algo",
                    "fetch_closed_orders_algo",
                    "fetch_canceled_orders_algo"
                  ]

              "binancecoinm" ->
                expected_profiles ++
                  ["set_leverage", "fetch_leverage_tiers", "fetch_order_algo", "fetch_open_order_algo"]
            end

          assert Enum.map(goldens, &get_in(&1, ["acceptance", "profile"])) == expected_profiles

          assert Enum.all?(goldens, &(ExchangeAcceptanceFixtures.replay(&1) == :ok))
        end)
      end)
    end
  end

  test "injected transport records every Binance signed request profile" do
    stub = {__MODULE__, :binance_acceptance_setup, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/fapi/v1/ticker/24hr"} ->
          Req.Test.json(conn, %{"lastPrice" => "2000"})

        {"DELETE", "/fapi/v1/order"} ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"code" => -2011, "msg" => "Unknown order sent."})

        {"DELETE", "/fapi/v1/algoOrder"} ->
          Req.Test.json(conn, %{"algoId" => 1, "algoStatus" => "CANCELED", "symbol" => "ETHUSDT"})

        {"DELETE", "/api/v3/order"} ->
          Req.Test.json(conn, %{"clientOrderId" => "task-578-spot", "orderId" => 1, "status" => "CANCELED"})

        _other ->
          Req.Test.json(conn, %{"code" => 200, "msg" => "success"})
      end
    end)

    with_env(@credential_env["binance"], "offline-binance-credential", fn ->
      with_http_stub(stub, fn ->
        assert {:ok, goldens} =
                 ExchangeAcceptanceFixtures.record_all("binance", transport: &success_transport/1)

        assert Enum.map(goldens, &get_in(&1, ["acceptance", "profile"])) == [
                 "fetch_balance",
                 "fetch_balance_spot",
                 "fetch_orders",
                 "create_order",
                 "create_order_spot",
                 "set_margin_mode",
                 "cancel_all_orders",
                 "fetch_order_algo",
                 "fetch_open_order_algo",
                 "fetch_orders_algo",
                 "fetch_closed_orders_algo",
                 "fetch_canceled_orders_algo"
               ]

        assert Enum.all?(goldens, &(ExchangeAcceptanceFixtures.replay(&1) == :ok))
      end)
    end)
  end

  test "injected transport records both Alpaca public-data and paper-account reads" do
    with_env(@credential_env["alpaca"], "offline-alpaca-credential", fn ->
      assert {:ok, goldens} =
               ExchangeAcceptanceFixtures.record_all("alpaca", transport: &success_transport/1)

      assert Enum.map(goldens, &get_in(&1, ["acceptance", "method"])) == [
               "fetch_ticker",
               "fetch_trades",
               "fetch_balance",
               "fetch_my_trades"
             ]

      assert Enum.all?(goldens, &(ExchangeAcceptanceFixtures.replay(&1) == :ok))
    end)
  end

  test "non-success and venue-level error responses fail loudly" do
    with_env(@credential_env["deribit"], "offline-deribit-credential", fn ->
      transport = fn request ->
        {request, Req.Response.new(status: 503, body: %{"error" => %{"code" => 10_000}})}
      end

      assert {:error, {:live_call_failed, :authentication_error, 10_000}} =
               ExchangeAcceptanceFixtures.record("deribit", transport: transport)
    end)

    with_env(@credential_env["binance"], "offline-binance-credential", fn ->
      transport = fn request ->
        {request, Req.Response.new(status: 200, body: %{"code" => -1022, "msg" => "bad signature"})}
      end

      assert {:error, {:fetch_balance, {:live_call_failed, :authentication_error, -1022}}} =
               ExchangeAcceptanceFixtures.record_all("binance", transport: transport)
    end)
  end

  test "injected transport reaches Bybit's prepared order profile without a live request" do
    stub = {__MODULE__, :bybit_order_book, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{
        "retCode" => 0,
        "retMsg" => "OK",
        "result" => %{
          "a" => [["101", "1"]],
          "b" => [["100", "1"]],
          "s" => "LTCUSDT",
          "ts" => 1,
          "u" => 1
        }
      })
    end)

    test_process = self()

    transport = fn request ->
      send(test_process, :transport_called)
      {request, Req.Response.new(status: 200, body: %{"retCode" => 0, "result" => %{}})}
    end

    with_env(@credential_env["bybit"], &credential_value("bybit", &1), fn ->
      with_http_stub(stub, fn ->
        assert {:error, :venue_business_failure} =
                 ExchangeAcceptanceFixtures.record("bybit", transport: transport)
      end)

      assert_received :transport_called
    end)
  end

  defp success_transport(request) do
    case {request.method, request.url.host, request.url.path} do
      {:get, host, path}
      when host in ["demo-fapi.binance.com", "demo-dapi.binance.com"] and
             path in ["/fapi/v1/order", "/fapi/v1/openOrder", "/dapi/v1/order", "/dapi/v1/openOrder"] ->
        {request, Req.Response.new(status: 400, body: %{"code" => -2013, "msg" => "Order does not exist."})}

      {:delete, "demo-fapi.binance.com", "/fapi/v1/order"} ->
        {request, Req.Response.new(status: 400, body: %{"code" => -2011, "msg" => "Unknown order sent."})}

      {:delete, "demo-fapi.binance.com", "/fapi/v1/algoOrder"} ->
        {request,
         Req.Response.new(
           status: 200,
           body: %{"algoId" => 1, "algoStatus" => "CANCELED", "symbol" => "ETHUSDT"}
         )}

      _other ->
        success_response(request)
    end
  end

  defp success_response(request) do
    body = success_body(request.url.host, request.url.path)
    {request, Req.Response.new(status: 200, body: body)}
  end

  defp success_body("testnet.binance.vision", "/api/v3/allOrders"), do: []

  defp success_body("testnet.binance.vision", "/api/v3/order") do
    %{"clientOrderId" => "task-578-spot", "orderId" => 1, "transactTime" => 1}
  end

  defp success_body("demo-fapi.binance.com", "/fapi/v1/algoOrder") do
    %{"algoId" => 1, "algoStatus" => "NEW", "symbol" => "ETHUSDT"}
  end

  defp success_body("demo-dapi.binance.com", "/dapi/v1/algoOrder") do
    %{"algoId" => 1, "algoStatus" => "NEW", "symbol" => "BTCUSD_PERP"}
  end

  defp success_body("demo-fapi.binance.com", path) when path in ["/fapi/v1/allOrders", "/fapi/v1/allAlgoOrders"], do: []

  defp success_body("demo-dapi.binance.com", "/dapi/v1/leverage") do
    %{"leverage" => 3, "maxQty" => "1000", "symbol" => "BTCUSD_PERP"}
  end

  defp success_body("demo-fapi.binance.com", path)
       when path in [
              "/fapi/v1/marginType",
              "/fapi/v1/positionSide/dual",
              "/fapi/v1/allOpenOrders",
              "/fapi/v1/algoOpenOrders"
            ] do
    %{"code" => 200, "msg" => "success"}
  end

  defp success_body("demo-dapi.binance.com", path)
       when path in ["/dapi/v1/marginType", "/dapi/v1/allOpenOrders", "/dapi/v1/algoOpenOrders"] do
    %{"code" => 200, "msg" => "success"}
  end

  defp success_body(host, _path)
       when host in ["testnet.binance.vision", "demo-fapi.binance.com", "demo-dapi.binance.com"] do
    %{"assets" => [], "balances" => [], "positions" => []}
  end

  defp success_body("test.deribit.com", _path), do: %{"jsonrpc" => "2.0", "result" => %{}}
  defp success_body("api-demo.lyra.finance", _path), do: %{"id" => "offline", "result" => []}
  defp success_body("www.okx.com", _path), do: %{"code" => "0", "data" => [], "msg" => ""}

  defp success_body("paper-api.alpaca.markets", "/v2/account/activities/FILL"), do: []

  defp success_body("data.alpaca.markets", "/v2/stocks/GLD/trades") do
    %{"next_page_token" => nil, "symbol" => "GLD", "trades" => []}
  end

  defp success_body(host, _path) when host in ["data.alpaca.markets", "paper-api.alpaca.markets"] do
    %{"currency" => "USD", "equity" => "1"}
  end

  defp credential_value("derive", "DERIVE_TESTNET_API_KEY") do
    "0x0000000000000000000000000000000000000001"
  end

  defp credential_value("derive", "DERIVE_TESTNET_API_SECRET") do
    "0x0123456789012345678901234567890123456789012345678901234567890123"
  end

  defp credential_value(_venue, variable), do: "offline-#{String.downcase(variable)}"

  defp with_env(variables, value, fun) do
    previous = Map.new(variables, &{&1, System.get_env(&1)})
    Enum.each(variables, &put_env(&1, value))

    try do
      fun.()
    after
      Enum.each(previous, fn {variable, original} -> put_env(variable, original) end)
    end
  end

  defp with_http_stub(stub, fun) do
    key = {Bourse.HTTP, :base_client}
    previous = :persistent_term.get(key, :missing)
    client = Req.new(decode_body: true, plug: {Req.Test, stub}, retry: false)
    :persistent_term.put(key, client)

    try do
      fun.()
    after
      case previous do
        :missing -> :persistent_term.erase(key)
        previous_client -> :persistent_term.put(key, previous_client)
      end
    end
  end

  defp put_env(variable, nil), do: System.delete_env(variable)
  defp put_env(variable, value) when is_function(value, 1), do: System.put_env(variable, value.(variable))
  defp put_env(variable, value), do: System.put_env(variable, value)
end
