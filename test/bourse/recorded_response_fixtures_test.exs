defmodule Bourse.RecordedResponseFixturesTest do
  use ExUnit.Case, async: false

  alias Bourse.Market
  alias Bourse.RecordedResponseFixtures
  alias Bourse.RecordedResponseFixtures.Capture
  alias Bourse.ReplayExchange
  alias Bourse.ResponseParser
  alias Bourse.Spec
  alias Bourse.Ticker
  alias Bourse.Unified

  # Deliberately malformed — kept out of `fixture_root/0` so the recorded-response
  # corpus never holds a document engineered to raise on read.
  @duplicate_fixture Path.expand("../fixtures/json_document/duplicate_key.json", __DIR__)

  test "load_fixture!/1 rejects a duplicate key with its file and object path" do
    error = assert_raise ArgumentError, fn -> RecordedResponseFixtures.load_fixture!(@duplicate_fixture) end

    assert error.message =~ @duplicate_fixture
    assert error.message =~ ~s(duplicate key "body")
    assert error.message =~ "object path $.methods.fetchTicker[0]"
  end

  test "load_fixture!/1 leaves malformed JSON to Jason with a byte position" do
    path = Path.join(System.tmp_dir!(), "recorded-fixture-malformed-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"methods": }))
    on_exit(fn -> File.rm(path) end)

    error = assert_raise Jason.DecodeError, fn -> RecordedResponseFixtures.load_fixture!(path) end

    assert is_integer(error.position)
  end

  test "replay exchange declares its raw Bourse market cache shape" do
    exchange = ReplayExchange.build!("binance", %{})

    refute Enum.any?(exchange.markets, &match?(%Market{}, &1))
    assert Enum.any?(exchange.markets, &(&1["symbol"] == "BTC/USDT"))
    assert Enum.any?(exchange.markets, &(&1["symbol"] == "BTC/USDT:USDT" and &1["contractSize"] == 1))

    assert get_in(exchange.currencies, ["USDT", "networks", "ERC20", "info", "contractAddressUrl"]) ==
             "https://etherscan.io/address/"
  end

  test "DEX replay exchanges use signer-safe credentials and Hyperliquid asset indexes" do
    hyperliquid = ReplayExchange.build!("hyperliquid", %{})
    derive = ReplayExchange.build!("derive", %{})

    btc = Enum.find(hyperliquid.markets, &(&1["symbol"] == "BTC/USDC:USDC"))

    assert btc["baseId"] == "0"
    assert btc["asset_index"] == 0
    assert hyperliquid.credentials.api_key == "0x0000000000000000000000000000000000000000"
    assert derive.credentials.secret =~ ~r/^0x[0-9]{64}$/
  end

  test "ticker average uses the cached market price precision" do
    exchange = ReplayExchange.build!("binance", %{})
    market = Enum.find(exchange.markets, &(&1["symbol"] == "BTC/USDT"))
    mapping = Bourse.Binance.__field_maps__()["ticker"]
    data = %{"openPrice" => "72181.09", "lastPrice" => "73369.84"}

    assert {:ok, %Ticker{average: 72_775.46}} =
             ResponseParser.apply_mappings(data, mapping, target: Ticker, market: market)

    coarse_market = put_in(market, ["precision", "price"], 1)

    assert {:ok, %Ticker{average: 72_775.0}} =
             ResponseParser.apply_mappings(data, mapping, target: Ticker, market: coarse_market)
  end

  # Bourse `getNetworkCodeByNetworkUrl` matches the deposit url against the BASE
  # DOMAIN of each network's `contractAddressUrl`, not the full url. ERC20 passes
  # under either reading (both urls share the `/address/` path), so it cannot tell
  # the two apart — TRC20 can: the catalog says `#/token20/` while the deposit url
  # says `#/address/`. This is the case that fails a full-url matcher.
  test "deposit-address network resolves by contractAddressUrl base domain, not full url" do
    exchange = ReplayExchange.build!("binance", %{})

    assert get_in(exchange.currencies, ["USDT", "networks", "TRC20", "info", "contractAddressUrl"]) ==
             "https://tronscan.org/#/token20/"

    assert {:ok, %Bourse.DepositAddress{currency: "USDT", network: "TRC20"}} =
             replay_deposit_address(exchange, %{
               "coin" => "USDT",
               "address" => "TGC4Fq6Mum7kE2eEHkt8RudZY1o8oqkvBu",
               "tag" => "",
               "url" => "https://tronscan.org/#/address/TGC4Fq6Mum7kE2eEHkt8RudZY1o8oqkvBu"
             })

    assert {:ok, %Bourse.DepositAddress{currency: "USDT", network: "ERC20"}} =
             replay_deposit_address(exchange, %{
               "coin" => "USDT",
               "address" => "0x437ef7f47dc0d5f0e1e0e0b7f5e6a4b1c2d3e4f5",
               "tag" => "",
               "url" => "https://etherscan.io/address/0x437ef7f47dc0d5f0e1e0e0b7f5e6a4b1c2d3e4f5"
             })

    # An explorer domain absent from the catalog resolves to no network rather
    # than silently mislabelling the address.
    assert {:ok, %Bourse.DepositAddress{currency: "USDT", network: nil}} =
             replay_deposit_address(exchange, %{
               "coin" => "USDT",
               "address" => "unknown",
               "tag" => "",
               "url" => "https://example.invalid/address/unknown"
             })
  end

  defp replay_deposit_address(exchange, payload) do
    stub = {__MODULE__, :deposit_address, System.unique_integer([:positive])}
    Req.Test.stub(stub, fn conn -> Req.Test.json(conn, payload) end)

    Unified.call(exchange, :fetch_deposit_address, "fetchDepositAddress", %{"code" => "USDT"}, plug: {Req.Test, stub})
  end

  test "legacy recording paths and options are deterministic" do
    assert {"binance", :fetch_markets} in RecordedResponseFixtures.capture_targets()
    assert {"deribit", :fetch_balance} in RecordedResponseFixtures.capture_targets()
    assert {"binanceusdm", :fetch_account_positions} in RecordedResponseFixtures.capture_targets()
    assert {"binanceusdm", :fetch_positions_risk} in RecordedResponseFixtures.capture_targets()
    assert {"binanceusdm", :fetch_leverages} in RecordedResponseFixtures.capture_targets()
    assert RecordedResponseFixtures.capture_category("deribit", :fetch_balance) == :private
    assert RecordedResponseFixtures.capture_category("binance", :fetch_ticker) == :public

    assert RecordedResponseFixtures.oracle_identity("binanceusdm", :fetch_account_positions)["endpoint"] ==
             "fapi/v3/account"

    assert RecordedResponseFixtures.oracle_identity("binanceusdm", :fetch_positions_risk)["endpoint"] ==
             "fapi/v3/positionRisk"

    assert RecordedResponseFixtures.oracle_identity("binanceusdm", :fetch_leverages)["endpoint"] ==
             "fapi/v1/symbolConfig"

    assert RecordedResponseFixtures.fixture_path("binance", :fetch_markets) ==
             Path.join(RecordedResponseFixtures.fixture_root(), "binance/fetch_markets.json")

    assert RecordedResponseFixtures.decode_call_opts(%{"call_opts" => %{"endpoint_index" => 2}}) ==
             [endpoint_index: 2]
  end

  test "capture_fixture/2 rejects methods without a capture profile" do
    assert {:error, {:no_capture_profile, "binance", :fetch_account}} =
             RecordedResponseFixtures.capture_fixture("binance", :fetch_account)
  end

  test "public trade capture carries the configured symbol into the provider request" do
    stub = unique_stub("trade_symbol")

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{"id" => "offline", "result" => %{"trades" => []}})
    end)

    assert {:ok, fixture} =
             Capture.capture_fixture("derive", :fetch_trades, plug: {Req.Test, stub})

    assert fixture["params"]["symbol"] == "BTC/USDC"
  end

  test "OHLCV capture carries its positional timeframe as a request parameter" do
    stub = unique_stub("ohlcv_timeframe")
    test_process = self()

    Req.Test.stub(stub, fn conn ->
      send(test_process, {:ohlcv_request, conn.request_path, URI.decode_query(conn.query_string)})
      Req.Test.json(conn, [[1_700_000_000_000, "1", "2", "0.5", "1.5", "3"]])
    end)

    with_http_stub(stub, fn ->
      assert {:ok, fixture} = Capture.capture_fixture("binance", :fetch_ohlcv)
      assert fixture["params"]["timeframe"] == "1m"

      assert_receive {:ohlcv_request, "/api/v3/klines", %{"interval" => "1m", "symbol" => "BTCUSDT"}}
    end)
  end

  test "private capture profiles cover account reads for every declared real-recordings venue" do
    targets = MapSet.new(RecordedResponseFixtures.capture_targets())
    private_capture_venues = Spec.oracle_venues(:private_real_recordings)

    for venue <- private_capture_venues do
      assert MapSet.member?(targets, {venue, :fetch_balance})
      assert MapSet.member?(targets, {venue, :fetch_open_orders})
      assert MapSet.member?(targets, {venue, :fetch_my_trades})
    end

    for venue <- private_capture_venues -- ["binance"] do
      assert MapSet.member?(targets, {venue, :fetch_positions})
    end
  end

  test "every runtime venue can record fetch_markets reality" do
    targets = MapSet.new(RecordedResponseFixtures.capture_targets())

    for venue <- Spec.exchanges() do
      assert MapSet.member?(targets, {venue, :fetch_markets})
    end
  end

  test "under-recorded venues expose their supported critical response profiles" do
    targets = MapSet.new(RecordedResponseFixtures.capture_targets())

    for target <- [
          {"alpaca", :fetch_ticker},
          {"alpaca", :fetch_balance},
          {"alpaca", :fetch_positions},
          {"alpaca", :fetch_open_orders},
          {"binancecoinm", :fetch_ticker},
          {"binancecoinm", :fetch_balance},
          {"binancecoinm", :fetch_positions},
          {"binancecoinm", :fetch_open_orders},
          {"lighter", :fetch_ticker},
          {"lighter", :fetch_closed_orders},
          {"lighter", :fetch_open_orders}
        ] do
      assert MapSet.member?(targets, target)
    end

    assert RecordedResponseFixtures.oracle_identity("alpaca", :fetch_balance)["host"] ==
             "paper-api.alpaca.markets"

    assert RecordedResponseFixtures.oracle_identity("binancecoinm", :fetch_balance)["host"] ==
             "demo-dapi.binance.com"

    assert RecordedResponseFixtures.oracle_identity("lighter", :fetch_closed_orders)["host"] ==
             "testnet.zklighter.elliot.ai"
  end

  test "write capture profiles are demo-only far-from-market order lifecycles with cancel cleanup" do
    for venue <- ~w(alpaca bybit binance binancecoinm binanceusdm) do
      assert {venue, :order_lifecycle} in RecordedResponseFixtures.capture_targets()
      assert RecordedResponseFixtures.capture_category(venue, :order_lifecycle) == :write

      identity = RecordedResponseFixtures.oracle_identity(venue, :order_lifecycle)

      assert identity["environment"] == "testnet-demo"
      # Alpaca's non-live sandbox is its paper-trading host (paper-api.alpaca.markets);
      # it never points at the live-money host, so "paper" is a demo-tier host here.
      assert identity["host"] =~ ~r/(demo|testnet|test|paper)/

      safety = identity["mutation_safety"]

      assert Map.take(safety, ["cleanup", "far_from_market", "paramless_persistent_mutation"]) == %{
               "cleanup" => "cancel_order",
               "far_from_market" => true,
               "paramless_persistent_mutation" => false
             }

      assert safety["price_source"] == "live_ticker_ratio"
      assert safety["price_ratio"] > 0 and safety["price_ratio"] < 1
    end

    assert RecordedResponseFixtures.oracle_identity("alpaca", :order_lifecycle)["host"] ==
             "paper-api.alpaca.markets"
  end

  test "error capture profiles deliberately reject and never mutate valid state" do
    error_targets =
      Enum.filter(RecordedResponseFixtures.capture_targets(), fn {venue, method} ->
        RecordedResponseFixtures.capture_category(venue, method) == :error
      end)

    assert error_targets != []

    venues = error_targets |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    assert venues == Spec.exchanges()

    for {venue, method} <- error_targets do
      identity = RecordedResponseFixtures.oracle_identity(venue, method)
      safety = identity["mutation_safety"]

      assert is_map(safety)
      assert safety["deliberately_invalid_params"] == true
      assert safety["valid_order"] == false
      assert safety["withdrawal"] == false
      assert safety["transfer"] == false
      assert safety["key_mutation"] == false
      assert safety["paramless_persistent_mutation"] == false

      error_kind = safety["error_kind"] || identity["error_kind"]
      assert is_binary(error_kind) and error_kind != ""

      assert RecordedResponseFixtures.fixture_path(venue, method) ==
               Path.join(RecordedResponseFixtures.error_fixture_root(), "#{venue}/#{method}.json")
    end

    assert {"binance", :error_bad_symbol} in error_targets
    assert {"binance", :error_invalid_signature} in error_targets
    assert {"binance", :error_insufficient_funds} in error_targets
    assert {"hyperliquid", :error_order_not_found} in error_targets

    for venue <- ~w(binancecoinm binanceusdm) do
      identity = RecordedResponseFixtures.oracle_identity(venue, :error_bad_symbol)
      assert identity["environment"] == "testnet-demo"
      assert identity["host"] =~ ~r/^demo-[df]api\.binance\.com$/
    end
  end

  test "unknown capture profiles fail explicitly" do
    assert Capture.category("unknown", :fetch_ticker) == nil
    assert Capture.oracle_identity("unknown", :fetch_ticker) == nil

    assert {:error, {:no_capture_profile, "unknown", :fetch_ticker}} =
             Capture.capture_fixture("unknown", :fetch_ticker)
  end

  test "scrubber masks account numbers as provider account identity" do
    scrubbed = Capture.scrub(%{"account_number" => "paper-account-number", "currency" => "USD"})

    assert scrubbed == %{"account_number" => "***REDACTED***", "currency" => "USD"}
    assert Capture.safety_violations(scrubbed) == []
  end

  test "error capture preserves HTTP status for body-level and status-level errors" do
    stub = unique_stub("recorded_error_http_status")

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/v5/market/tickers" ->
          Req.Test.json(conn, %{
            "retCode" => 10_001,
            "retMsg" => "params error: symbol invalid",
            "result" => %{}
          })

        "/v5/account/wallet-balance" ->
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"retCode" => 10_003, "retMsg" => "API key is invalid"})
      end
    end)

    with_http_stub(stub, fn ->
      assert {:ok, body_error} = Capture.capture_fixture("bybit", :error_bad_symbol)
      assert body_error["http_status"] == 200
      assert body_error["body"]["retCode"] == 10_001

      assert {:ok, status_error} = Capture.capture_fixture("bybit", :error_invalid_signature)
      assert status_error["http_status"] == 401
      assert status_error["body"]["retCode"] == 10_003
    end)
  end

  test "missing capture credentials fail with exact export commands" do
    variables = ~w(ALPACA_API_KEY ALPACA_API_SECRET)

    with_env(variables, nil, fn ->
      assert {:error, {:missing_credentials, ^variables, instructions}} =
               Capture.capture_fixture("alpaca", :error_bad_symbol)

      for variable <- variables do
        assert instructions =~ ~s(export #{variable}="replace-me")
      end

      assert instructions =~ "CLAUDE.md Testnet Credentials"
    end)
  end

  test "insufficient-funds capture refuses to send an order unless the live balance proves it unfillable" do
    test_process = self()
    stub = unique_stub("unfillable_preflight")

    Req.Test.stub(stub, fn conn ->
      send(test_process, {:request_path, conn.request_path})

      case conn.request_path do
        "/api/v3/account" ->
          Req.Test.json(conn, %{
            "balances" => [%{"asset" => "USDT", "free" => "1000000000", "locked" => "0"}]
          })

        "/api/v3/ticker/24hr" ->
          Req.Test.json(conn, %{"symbol" => "BTCUSDT", "lastPrice" => "100000"})

        "/api/v3/order" ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"code" => -2010, "msg" => "insufficient balance"})
      end
    end)

    variables = ~w(BINANCE_TESTNET_API_KEY BINANCE_TESTNET_API_SECRET)

    with_env(variables, "offline-test-credential", fn ->
      with_http_stub(stub, fn ->
        assert {:error, {:order_not_proven_unfillable, "BTC/USDT"}} =
                 Capture.capture_fixture("binance", :error_insufficient_funds)
      end)
    end)

    assert_received {:request_path, "/api/v3/account"}
    assert_received {:request_path, "/api/v3/ticker/24hr"}
    refute_received {:request_path, "/api/v3/order"}
  end

  test "write capture freezes the create-read-cancel lifecycle and cleans up" do
    test_process = self()
    stub = unique_stub("write_lifecycle")
    order_id = 123_456

    Req.Test.stub(stub, fn conn ->
      send(test_process, {:lifecycle_request, conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/ticker/24hr"} ->
          Req.Test.json(conn, %{"lastPrice" => "100000", "symbol" => "BTCUSDT"})

        {"POST", "/api/v3/order"} ->
          Req.Test.json(conn, %{"clientOrderId" => "review-order", "orderId" => order_id, "symbol" => "BTCUSDT"})

        {method, "/api/v3/order"} when method in ["GET", "DELETE"] ->
          Req.Test.json(conn, %{
            "clientOrderId" => "review-order",
            "executedQty" => "0",
            "orderId" => order_id,
            "origQty" => "0.001",
            "price" => "80000",
            "side" => "BUY",
            "status" => "CANCELED",
            "symbol" => "BTCUSDT",
            "time" => 1,
            "timeInForce" => "GTC",
            "type" => "LIMIT",
            "updateTime" => 1
          })
      end
    end)

    variables = ~w(BINANCE_TESTNET_API_KEY BINANCE_TESTNET_API_SECRET)

    with_env(variables, "offline-test-credential", fn ->
      with_http_stub(stub, fn ->
        assert {:ok, fixture} = Capture.capture_fixture("binance", :order_lifecycle)

        assert Enum.map(fixture["responses"], &{&1["step"], &1["method"]}) == [
                 {"create", "create_order"},
                 {"read", "fetch_order"},
                 {"cancel", "cancel_order"}
               ]

        assert fixture["mutation_safety"]["cleanup"] == "cancel_order"
      end)
    end)

    assert_received {:lifecycle_request, "GET", "/api/v3/ticker/24hr"}
    assert_received {:lifecycle_request, "POST", "/api/v3/order"}
    assert_received {:lifecycle_request, "GET", "/api/v3/order"}
    assert_received {:lifecycle_request, "DELETE", "/api/v3/order"}
    assert_received {:lifecycle_request, "DELETE", "/api/v3/order"}
  end

  test "fixture scrub masks credentials and account identity recursively" do
    credentials = Bourse.Credentials.new!(api_key: "key-value", secret: "secret-value")

    fixture = %{
      "apiKey" => "key-value",
      "nested" => [
        %{
          "signature" => "signed-value",
          "subaccount_id" => 144_422,
          "address" => "0x1234",
          "ordinary" => "secret-value"
        },
        %{"id" => 5519, "email" => "account@example.test", "username" => "account-name"}
      ]
    }

    scrubbed = RecordedResponseFixtures.scrub_fixture(fixture, credentials)

    assert scrubbed["apiKey"] == "***REDACTED***"
    assert get_in(scrubbed, ["nested", Access.at(0), "signature"]) == "***REDACTED***"
    assert get_in(scrubbed, ["nested", Access.at(0), "subaccount_id"]) == "***REDACTED***"
    assert get_in(scrubbed, ["nested", Access.at(0), "address"]) == "***REDACTED***"
    assert get_in(scrubbed, ["nested", Access.at(0), "ordinary"]) == "***REDACTED***"
    assert get_in(scrubbed, ["nested", Access.at(1), "id"]) == "***REDACTED***"
    assert get_in(scrubbed, ["nested", Access.at(1), "email"]) == "***REDACTED***"
    assert RecordedResponseFixtures.safety_violations(scrubbed) == []

    assert RecordedResponseFixtures.safety_violations(fixture) == [
             "$.apiKey",
             "$.nested[0].address",
             "$.nested[0].signature",
             "$.nested[0].subaccount_id",
             "$.nested[1].email",
             "$.nested[1].id",
             "$.nested[1].username"
           ]
  end

  test "the complete real-recordings corpus contains no unmasked sensitive fields" do
    roots = [
      RecordedResponseFixtures.fixture_root(),
      RecordedResponseFixtures.error_fixture_root()
    ]

    violations =
      roots
      |> Enum.flat_map(fn root ->
        root
        |> Path.join("**/*.json")
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "_manifest.json"))
      end)
      |> Enum.flat_map(fn path ->
        path
        |> RecordedResponseFixtures.load_fixture!()
        |> RecordedResponseFixtures.safety_violations()
        |> Enum.map(&"#{Path.relative_to_cwd(path)}:#{&1}")
      end)

    assert violations == []
  end

  test "recorded error corpus freezes code, host, and capture date per venue" do
    root = RecordedResponseFixtures.error_fixture_root()

    manifest =
      root
      |> Path.join("_manifest.json")
      |> RecordedResponseFixtures.load_fixture!()

    assert manifest["count"] == length(manifest["recordings"])
    assert manifest["count"] >= length(Spec.exchanges())

    venues = manifest["recordings"] |> Enum.map(& &1["venue"]) |> Enum.uniq() |> Enum.sort()
    assert venues == Spec.exchanges()

    for recording <- manifest["recordings"] do
      assert is_binary(recording["venue"]) and recording["venue"] != ""
      assert is_binary(recording["endpoint"]) and recording["endpoint"] != ""
      assert recording["capture_date"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert is_binary(recording["host"]) and recording["host"] != ""
      assert is_binary(recording["code"]) and recording["code"] != ""
      assert recording["http_status"] in 100..599

      fixture =
        root
        |> Path.join(recording["path"])
        |> RecordedResponseFixtures.load_fixture!()

      assert fixture["code"] == recording["code"]
      assert fixture["http_status"] == recording["http_status"]
      refute fixture["body"] in [nil, "", %{}, []]
      assert fixture["mutation_safety"]["valid_order"] == false
      assert fixture["mutation_safety"]["deliberately_invalid_params"] == true
    end
  end

  test "recording manifest names every oracle's venue, endpoint, capture date, and host" do
    manifest =
      RecordedResponseFixtures.fixture_root()
      |> Path.join("_manifest.json")
      |> RecordedResponseFixtures.load_fixture!()

    assert manifest["count"] == length(manifest["recordings"])
    assert Enum.map(manifest["recordings"], & &1["path"]) == manifest["fixtures"]

    for recording <- manifest["recordings"] do
      assert is_binary(recording["venue"]) and recording["venue"] != ""
      assert is_binary(recording["endpoint"]) and recording["endpoint"] != ""
      assert recording["capture_date"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert is_binary(recording["host"]) and recording["host"] != ""
    end
  end

  defp unique_stub(prefix) do
    {__MODULE__, prefix, System.unique_integer([:positive])}
  end

  defp with_http_stub(stub, fun) do
    key = {Bourse.HTTP, :base_client}
    previous = :persistent_term.get(key, :missing)

    client =
      Req.new(
        compressed: true,
        decode_body: true,
        plug: {Req.Test, stub},
        retry: false
      )

    :persistent_term.put(key, client)

    try do
      fun.()
    after
      case previous do
        :missing -> :persistent_term.erase(key)
        client -> :persistent_term.put(key, client)
      end
    end
  end

  defp with_env(variables, value, fun) do
    previous = Map.new(variables, &{&1, System.get_env(&1)})
    Enum.each(variables, &put_env(&1, value))

    try do
      fun.()
    after
      Enum.each(previous, fn {variable, original} -> put_env(variable, original) end)
    end
  end

  defp put_env(variable, nil), do: System.delete_env(variable)
  defp put_env(variable, value), do: System.put_env(variable, value)
end
