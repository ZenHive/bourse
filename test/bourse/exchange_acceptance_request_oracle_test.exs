defmodule Bourse.ExchangeAcceptanceRequestOracleTest do
  use ExUnit.Case, async: true

  alias Bourse.ExchangeAcceptanceFixtures
  alias Bourse.JsonDocument

  @manifest_path "test/fixtures/exchange_accepted_requests/_manifest.json"
  @external_resource @manifest_path
  @manifest JsonDocument.decode_file!(@manifest_path)
  @fixture_paths Enum.map(@manifest["goldens"], &Path.join("test/fixtures/exchange_accepted_requests", &1["path"]))
  @goldens Enum.map(@fixture_paths, &JsonDocument.decode_file!/1)

  for fixture_path <- @fixture_paths do
    @external_resource fixture_path
  end

  @credential_env_names ~w(
    ALPACA_API_KEY
    ALPACA_API_SECRET
    BINANCE_TESTNET_API_KEY
    BINANCE_TESTNET_API_SECRET
    BINANCE_FUTURES_TEST_API_KEY
    BINANCE_FUTURES_TEST_API_SECRET
    BYBIT_DEMO_API_KEY
    BYBIT_DEMO_API_SECRET
    DERIBIT_TESTNET_API_KEY
    DERIBIT_TESTNET_API_SECRET
    OKX_INTL_API_KEY
    OKX_INTL_API_SECRET
    OKX_INTL_PASSPHRASE
    HYPERLIQUID_TESTNET_API_KEY
    HYPERLIQUID_TESTNET_API_SECRET
    LIGHTER_TESTNET_API_PRIVATE_KEY
    DERIVE_TESTNET_API_KEY
    DERIVE_TESTNET_API_SECRET
  )

  test "manifest covers every credentialed venue with accepted live evidence" do
    assert ExchangeAcceptanceFixtures.fixture_root() == Path.expand("test/fixtures/exchange_accepted_requests")
    assert ExchangeAcceptanceFixtures.manifest_path() == Path.expand(@manifest_path)
    assert Enum.sort(ExchangeAcceptanceFixtures.load_all!()) == Enum.sort(@goldens)

    assert @manifest["oracle"] == "exchange_acceptance"
    assert @manifest["count"] == length(ExchangeAcceptanceFixtures.profiles())

    # A profile that omits its id and duplicates a sibling's method would share
    # a golden file while the count check above still passes — pin uniqueness.
    profile_ids = Enum.map(ExchangeAcceptanceFixtures.profiles(), fn {venue, profile, _method} -> {venue, profile} end)
    assert profile_ids == Enum.uniq(profile_ids)

    assert @manifest["goldens"] |> Enum.map(& &1["venue"]) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(ExchangeAcceptanceFixtures.authenticated_venues())

    Enum.each(@manifest["goldens"], fn row ->
      assert row["http_status"] in 200..299
      assert is_binary(row["business_success"]) and row["business_success"] != ""
      assert is_binary(row["capture_date"]) and row["capture_date"] != ""
      assert is_binary(row["endpoint"]) and row["endpoint"] != ""
      assert is_binary(row["host"]) and row["host"] != ""
      assert row["label"] =~ "exchange-acceptance tier 1"

      {_, profile, _method} =
        Enum.find(ExchangeAcceptanceFixtures.profiles(), fn {venue, profile, method} ->
          venue == row["venue"] and Atom.to_string(profile) == (row["profile"] || row["method"]) and
            Atom.to_string(method) == row["method"]
        end)

      assert File.exists?(ExchangeAcceptanceFixtures.fixture_path(row["venue"], profile))
    end)
  end

  test "offline replay rebuilds every exchange-accepted signed request exactly" do
    Enum.each(@goldens, fn golden ->
      assert :ok = ExchangeAcceptanceFixtures.replay(golden), golden["label"]
    end)
  end

  test "Binance futures goldens pin the repaired host, endpoint, and signed params" do
    balance = binance_golden!("fetch_balance")
    assert_request(balance, "demo-fapi.binance.com", "/fapi/v3/account", "GET", %{})

    create = binance_golden!("create_order")

    assert_request(create, "demo-fapi.binance.com", "/fapi/v1/algoOrder", "POST", %{
      "algoType" => "CONDITIONAL",
      "reduceOnly" => "false",
      "side" => "SELL",
      "symbol" => "ETHUSDT",
      "timeInForce" => "GTC",
      "type" => "TAKE_PROFIT_MARKET"
    })

    create_query = request_query(create)
    assert is_binary(create_query["triggerPrice"])
    refute Map.has_key?(create_query, "price")

    margin = binance_golden!("set_margin_mode")

    assert_request(margin, "demo-fapi.binance.com", "/fapi/v1/marginType", "POST", %{
      "marginType" => "CROSSED",
      "symbol" => "ETHUSDT"
    })

    cancel = binance_golden!("cancel_all_orders")

    assert_request(cancel, "demo-fapi.binance.com", "/fapi/v1/allOpenOrders", "DELETE", %{
      "symbol" => "ETHUSDT"
    })

    assert [algo_cancel] = cancel["additional_requests"]

    assert_request(%{"request" => algo_cancel}, "demo-fapi.binance.com", "/fapi/v1/algoOpenOrders", "DELETE", %{
      "symbol" => "ETHUSDT"
    })
  end

  test "Binance spot and futures balances retain separate accepted-request profiles" do
    futures = binance_golden!("fetch_balance")
    assert_request(futures, "demo-fapi.binance.com", "/fapi/v3/account", "GET", %{})

    spot = binance_golden!("fetch_balance_spot")
    assert_request(spot, "testnet.binance.vision", "/api/v3/account", "GET", %{})
  end

  test "dedicated Binance futures goldens pin Algo, margin, and cancel-all wire shapes" do
    for {venue, host, prefix, symbol, margin_type} <- [
          {"binanceusdm", "demo-fapi.binance.com", "fapi", "ETHUSDT", "CROSSED"},
          {"binancecoinm", "demo-dapi.binance.com", "dapi", "BTCUSD_PERP", "ISOLATED"}
        ] do
      create = venue_golden!(venue, "create_order")

      assert_request(create, host, "/#{prefix}/v1/algoOrder", "POST", %{
        "algoType" => "CONDITIONAL",
        "reduceOnly" => "false",
        "side" => "SELL",
        "symbol" => symbol,
        "timeInForce" => "GTC",
        "type" => "TAKE_PROFIT_MARKET"
      })

      assert is_binary(request_query(create)["triggerPrice"])

      margin = venue_golden!(venue, "set_margin_mode")

      assert_request(margin, host, "/#{prefix}/v1/marginType", "POST", %{
        "marginType" => margin_type,
        "symbol" => symbol
      })

      cancel = venue_golden!(venue, "cancel_all_orders")
      assert_request(cancel, host, "/#{prefix}/v1/allOpenOrders", "DELETE", %{"symbol" => symbol})
      assert [algo_cancel] = cancel["additional_requests"]

      assert_request(%{"request" => algo_cancel}, host, "/#{prefix}/v1/algoOpenOrders", "DELETE", %{
        "symbol" => symbol
      })
    end

    position_mode = venue_golden!("binanceusdm", "set_position_mode")

    assert_request(position_mode, "demo-fapi.binance.com", "/fapi/v1/positionSide/dual", "POST", %{
      "dualSidePosition" => "true"
    })

    leverage = venue_golden!("binancecoinm", "set_leverage")

    assert_request(leverage, "demo-dapi.binance.com", "/dapi/v1/leverage", "POST", %{
      "leverage" => "3",
      "symbol" => "BTCUSD_PERP"
    })

    leverage_tiers = venue_golden!("binancecoinm", "fetch_leverage_tiers")

    assert_request(leverage_tiers, "demo-dapi.binance.com", "/dapi/v2/leverageBracket", "GET", %{
      "symbol" => "BTCUSD_PERP"
    })
  end

  test "Binance-family Algo read goldens pin identifier overrides and history fan-out" do
    for {venue, host, prefix, symbol} <- [
          {"binance", "demo-fapi.binance.com", "fapi", "ETHUSDT"},
          {"binanceusdm", "demo-fapi.binance.com", "fapi", "ETHUSDT"},
          {"binancecoinm", "demo-dapi.binance.com", "dapi", "BTCUSD_PERP"}
        ] do
      for profile <- ~w(fetch_order_algo fetch_open_order_algo) do
        golden = venue_golden!(venue, profile)
        assert_request(golden, host, "/#{prefix}/v1/algoOrder", "GET", %{"symbol" => symbol})
        assert is_binary(request_query(golden)["algoId"])
        refute Map.has_key?(request_query(golden), "orderId")
        assert [regular] = golden["additional_requests"]
        assert URI.parse(regular["url"]).path in ["/#{prefix}/v1/order", "/#{prefix}/v1/openOrder"]
      end

      if venue != "binancecoinm" do
        for profile <- ~w(fetch_orders_algo fetch_closed_orders_algo fetch_canceled_orders_algo) do
          golden = venue_golden!(venue, profile)
          assert_request(golden, host, "/fapi/v1/allAlgoOrders", "GET", %{"symbol" => symbol})
          assert [regular] = golden["additional_requests"]
          assert URI.parse(regular["url"]).path == "/fapi/v1/allOrders"
        end
      end
    end
  end

  test "Binance spot order golden pins pass-through controls" do
    spot = binance_golden!("create_order_spot")

    assert_request(spot, "testnet.binance.vision", "/api/v3/order", "POST", %{
      "newOrderRespType" => "ACK",
      "side" => "BUY",
      "symbol" => "BTCUSDT",
      "timeInForce" => "GTC",
      "type" => "LIMIT"
    })

    assert is_binary(request_query(spot)["newClientOrderId"])
  end

  test "every golden freezes distinct timestamp and nonce overrides" do
    Enum.each(@goldens, fn golden ->
      timestamp_ms = get_in(golden, ["replay", "timestamp_ms_override"])
      nonce = get_in(golden, ["replay", "nonce_override"])

      assert is_integer(timestamp_ms), golden["label"]
      assert is_integer(nonce), golden["label"]
      refute timestamp_ms == nonce, golden["label"]
    end)
  end

  test "a deterministic signature mutation turns the offline gate red" do
    golden = Enum.find(@goldens, &(get_in(&1, ["acceptance", "venue"]) == "deribit"))

    mutated =
      update_in(golden, ["request", "headers"], fn headers ->
        Enum.map(headers, fn
          ["authorization", value] -> ["authorization", value <> "0"]
          header -> header
        end)
      end)

    assert {:error, :accepted_request_regressed} = ExchangeAcceptanceFixtures.replay(mutated)
  end

  test "replay rejects malformed identity before rebuilding a request" do
    golden = hd(@goldens)

    for key <- ~w(method timestamp_ms_override nonce_override) do
      mutated = put_in(golden, ["replay", key], nil)
      assert {:error, :invalid_replay_identity} = ExchangeAcceptanceFixtures.replay(mutated)
    end
  end

  test "goldens contain no configured live credentials" do
    live_material =
      @credential_env_names
      |> Enum.map(&System.get_env/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    assert :ok = ExchangeAcceptanceFixtures.validate_no_material(@goldens, live_material)
  end

  test "material guard inspects maps, tuples, URLs, and encoded request bodies" do
    secret = "live-secret-that-must-never-be-written"

    unsafe = %{
      body: Jason.encode!(%{"nested" => %{"signature" => secret}}),
      headers: [{"authorization", "Bearer #{secret}"}],
      url: "https://example.test/private?signature=#{secret}"
    }

    assert {:error, :sensitive_material_present} =
             ExchangeAcceptanceFixtures.validate_no_material(unsafe, [secret])

    assert :ok = ExchangeAcceptanceFixtures.validate_no_material(unsafe, ["different-secret"])

    assert {:error, :sensitive_material_present} =
             ExchangeAcceptanceFixtures.validate_no_material({["safe", secret]}, [secret])
  end

  defp binance_golden!(profile) do
    Enum.find(@goldens, fn golden ->
      get_in(golden, ["acceptance", "venue"]) == "binance" and
        (get_in(golden, ["acceptance", "profile"]) || get_in(golden, ["acceptance", "method"])) == profile
    end) || flunk("missing Binance #{profile} accepted-request golden")
  end

  defp venue_golden!(venue, profile) do
    Enum.find(@goldens, fn golden ->
      get_in(golden, ["acceptance", "venue"]) == venue and
        (get_in(golden, ["acceptance", "profile"]) || get_in(golden, ["acceptance", "method"])) == profile
    end) || flunk("missing #{venue} #{profile} accepted-request golden")
  end

  defp assert_request(golden, host, path, method, expected_query) do
    request = Map.fetch!(golden, "request")
    uri = URI.parse(Map.fetch!(request, "url"))

    assert request["method"] == method
    assert uri.host == host
    assert uri.path == path

    query = request_query(golden)

    Enum.each(expected_query, fn {key, expected} ->
      assert query[key] == expected
    end)
  end

  defp request_query(golden) do
    golden
    |> get_in(["request", "url"])
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.drop(["signature", "timestamp"])
  end
end
