defmodule Bourse.OracleProvenance.DerivationTest do
  use ExUnit.Case, async: false

  alias Bourse.OracleProvenance
  alias Bourse.OracleProvenance.Derivation

  @accepted_root "test/fixtures/exchange_accepted_requests"
  @ledger_path "docs/prod-verification-ledger.md"

  setup_all do
    reports = OracleProvenance.binary_reports!()
    {:ok, reports: Map.new(reports, &{&1.venue, &1})}
  end

  test "derives binary slots, host classes, and semantic membership from reality", %{reports: reports} do
    assert verified?(reports["binancecoinm"], "normalization.field_maps.market")

    assert %{host_classes: [:production], semantic: true} =
             slot(reports["bybit"], "normalization.field_maps.ticker")

    assert %{host_classes: [:production], semantic: true} =
             slot(reports["okx"], "normalization.field_maps.open_interest")

    assert %{host_classes: [:testnet_demo], semantic: false} =
             slot(reports["binance"], "auth.sign_recipe.private")

    refute verified?(reports["binance"], "auth.sign_recipe.fapiPrivateV3")
    assert verified?(reports["binanceusdm"], "auth.sign_recipe.fapiPrivateV3")
    refute verified?(reports["binanceusdm"], "auth.sign_recipe.private")

    assert verified?(reports["alpaca"], "markets.patterns.crypto")
    assert verified?(reports["alpaca"], "markets.patterns.equity")
    assert verified?(reports["lighter"], "markets.patterns.spot")
    assert verified?(reports["lighter"], "markets.patterns.swap")
  end

  test "every runtime venue has populated fetchMarkets reality", %{reports: reports} do
    for venue <- Bourse.Spec.exchanges() do
      assert %{verified: true, contributing_methods: methods} =
               slot(reports[venue], "normalization.field_maps.market")

      assert "fetchMarkets" in methods
    end
  end

  test "accepted requests verify request shape and only their exact signed route", %{reports: reports} do
    assert verified?(reports["binance"], "request_shape.fetchBalance")
    assert verified?(reports["bybit"], "request_shape.createOrder")
    assert verified?(reports["hyperliquid"], "request_shape.createOrder")

    assert route_sections("binance", "fetch_balance") == ["private"]
    assert route_sections("binanceusdm", "fetch_balance") == ["fapiPrivateV3"]
    assert route_sections("hyperliquid", "create_order") == ["private"]
    assert route_sections("alpaca", "fetch_ticker") == ["market", "private"]
  end

  test "public accepted requests verify complete method branch sets and public routes", %{reports: reports} do
    assert verified?(reports["binancecoinm"], "request_shape.fetchMarkets")

    assert %{verified: true, host_classes: [:production]} =
             slot(reports["binancecoinm"], "sign_path.public.dapiPublic")

    assert verified?(reports["alpaca"], "request_shape.fetchOHLCV")
    assert verified?(reports["alpaca"], "sign_path.public.market.public")
  end

  test "accepted route matching fails closed when the wire host changes" do
    golden = load_accepted!("binance", "fetch_balance")
    changed = put_in(golden, ["request", "url"], "https://example.invalid/api/v3/account")

    assert_raise ArgumentError, ~r/matches no exact endpoint route/, fn ->
      Derivation.accepted_route!("binance", changed)
    end
  end

  test "populated bodies reject empty and shape-only maps and reuse list-body rules" do
    refute Derivation.body_populated?(%{})
    refute Derivation.body_populated?(%{"code" => 0, "msg" => "ok", "result" => %{}})
    refute Derivation.body_populated?([])
    refute Derivation.body_populated?([1, 2, 3])

    assert Derivation.body_populated?(%{"code" => 0, "result" => %{"equity" => "1.0"}})
    assert Derivation.body_populated?(%{"data" => [%{"symbol" => "BTCUSDT"}]})
    assert Derivation.body_populated?(%{"data" => [[1_784_649_600_000, "2830404860.7702"]]})
    assert Derivation.body_populated?([%{"symbol" => "BTCUSDT"}])
  end

  test "critical slots report contributing and still-unverified methods separately", %{reports: reports} do
    ticker = slot(reports["binance"], "normalization.field_maps.ticker")

    assert ticker.critical
    assert ticker.verified
    assert ticker.contributing_methods == ["fetchTicker", "fetchTickers"]
    assert "fetchMarkPrice" in ticker.unverified_methods
    refute "fetchTickers" in ticker.unverified_methods
  end

  test "extension map reaches field-map keys outside the return-type vocabulary", %{reports: reports} do
    assert Derivation.method_slot_extensions() == %{
             "fetchFundingHistory" => "income",
             "fetchMySettlementHistory" => "settlement",
             "fetchOptionPositions" => "option_position",
             "fetchSettlementHistory" => "settlement",
             "fetchTradingFees" => "trading_fees"
           }

    assert %{verified: true, contributing_methods: ["fetchTradingFees"]} =
             slot(reports["deribit"], "normalization.field_maps.trading_fees")
  end

  test "one recorded exact code represents each satisfied safe error class", %{reports: reports} do
    report = reports["binancecoinm"]
    authentication_slots = error_slots(report, "AuthenticationError")

    assert Enum.count(authentication_slots, & &1.critical) == 1
    assert Enum.find(authentication_slots, & &1.critical).verified
    assert Enum.any?(authentication_slots, &(not &1.critical and not &1.verified))
  end

  test "a safe error class without a recording keeps one open representative", %{reports: reports} do
    bad_request_slots = error_slots(reports["binancecoinm"], "BadRequest")

    assert Enum.count(bad_request_slots, & &1.critical) == 1
    refute Enum.find(bad_request_slots, & &1.critical).verified
  end

  test "recorded errors and provider-doc paths verify handle_errors distinctly", %{reports: reports} do
    bad_symbol = slot(reports["binancecoinm"], "errors.handle_errors.exceptions.exact.-1121")
    assert bad_symbol.verified
    assert bad_symbol.critical
    assert :recorded_error in bad_symbol.verification_paths
    assert "error_bad_symbol" in bad_symbol.contributing_methods

    assert bad_symbol.verification_citations == [
             "test/fixtures/recorded_errors/binancecoinm/error_bad_symbol.json"
           ]

    auth = slot(reports["binancecoinm"], "errors.handle_errors.exceptions.exact.-2014")
    assert auth.verified
    assert :recorded_error in auth.verification_paths

    maintenance = slot(reports["binance"], "errors.handle_errors.exceptions.exact.-1016")
    assert maintenance.verified
    assert maintenance.critical == false
    assert maintenance.host_classes == [:provider_doc]
    assert maintenance.verification_paths == [:provider_doc]
    assert maintenance.verification_citations == ["priv/authority/binance/errors.json"]
    refute :recorded_error in maintenance.verification_paths

    unknown_oid = slot(reports["hyperliquid"], "errors.handle_errors.exceptions.exact.unknownOid")
    assert unknown_oid.verified
    assert unknown_oid.critical
    assert :recorded_error in unknown_oid.verification_paths
  end

  test "binary derivation does not read legacy provenance declarations" do
    Enum.each(Bourse.Spec.exchanges(), fn venue ->
      refute Map.has_key?(Bourse.Spec.load!(venue), "oracle_provenance")
    end)
  end

  test "production ledger conflicts require semantic production evidence", %{reports: reports} do
    entries = @ledger_path |> File.read!() |> OracleProvenance.open_ledger_entries()
    assert [] == OracleProvenance.tier_one_ledger_conflicts(Map.values(reports), entries)

    entry = [%{heading: "open", slots: [{"bybit", "normalization.field_maps.ticker"}]}]
    assert [_conflict] = OracleProvenance.tier_one_ledger_conflicts([reports["bybit"]], entry)

    testnet_entry = [%{heading: "open", slots: [{"binance", "auth.sign_recipe.private"}]}]
    assert [] == OracleProvenance.tier_one_ledger_conflicts([reports["binance"]], testnet_entry)
  end

  test "exact-set baseline names lost and newly verified slots", %{reports: reports} do
    report = reports["bybit"]
    baseline = OracleProvenance.binary_baseline([report])
    removed = %{report | verified: report.verified -- ["normalization.field_maps.ticker"]}

    assert ["bybit:normalization.field_maps.ticker lost verified reality evidence"] ==
             OracleProvenance.binary_baseline_differences([removed], baseline)

    empty_baseline = %{"version" => 1, "venues" => %{"bybit" => %{"verified_slots" => []}}}
    differences = OracleProvenance.binary_baseline_differences([report], empty_baseline)
    assert "bybit:normalization.field_maps.ticker newly verified; update the oracle baseline" in differences
  end

  test "manifest consistency checks missing and orphaned fixtures in both directions" do
    root = Path.join(System.tmp_dir!(), "ccxt-oracle-#{System.unique_integer([:positive])}")
    response_root = Path.join(root, "responses")
    accepted_root = Path.join(root, "accepted")
    error_root = Path.join(root, "errors")
    fixture_path = Path.join(response_root, "bybit/fetch_ticker.json")

    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.dirname(fixture_path))
    write_json!(fixture_path, %{"body" => %{"result" => %{"lastPrice" => "1"}}})
    write_manifest!(response_root, "recordings", [recording()])
    write_manifest!(accepted_root, "goldens", [])
    write_manifest!(error_root, "recordings", [])

    opts = [
      venues: ["bybit"],
      response_root: response_root,
      accepted_request_root: accepted_root,
      recorded_error_root: error_root,
      replay_accepted_requests: false
    ]

    assert [%{verified: verified}] = Derivation.reports!(opts)
    assert "normalization.field_maps.ticker" in verified

    File.rm!(fixture_path)

    assert_raise ArgumentError, ~r/bybit:normalization\.field_maps\.ticker/, fn ->
      Derivation.reports!(opts)
    end

    write_json!(fixture_path, %{"body" => %{"result" => %{"lastPrice" => "1"}}})
    write_manifest!(response_root, "recordings", [])

    assert_raise ArgumentError, ~r/bybit:normalization\.field_maps\.ticker/, fn ->
      Derivation.reports!(opts)
    end
  end

  test "host classification is read from manifest host names" do
    assert Derivation.host_class("test.deribit.com") == :testnet_demo
    assert Derivation.host_class("api-demo.bybit.com") == :testnet_demo
    assert Derivation.host_class("www.okx.com") == :production
  end

  defp verified?(report, path), do: slot(report, path).verified
  defp slot(report, path), do: Enum.find(report.slots, &(&1.path == path))

  defp error_slots(report, class) do
    classes =
      "priv/specs/json/output/authored/#{report.venue}.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["errors", "handle_errors", "exceptions"])
      |> flatten_error_classes(["exceptions", "handle_errors", "errors"])
      |> Map.new()

    Enum.filter(report.slots, &(Map.get(classes, &1.path) == class))
  end

  defp flatten_error_classes(map, reversed_prefix) when is_map(map) do
    Enum.flat_map(map, fn
      {key, value} when is_map(value) ->
        flatten_error_classes(value, [key | reversed_prefix])

      {key, value} when is_binary(value) ->
        [{[key | reversed_prefix] |> Enum.reverse() |> Enum.join("."), value}]
    end)
  end

  defp route_sections(venue, method) do
    venue
    |> load_accepted!(method)
    |> then(&Derivation.accepted_route!(venue, &1))
    |> Map.fetch!(:sections)
  end

  defp load_accepted!(venue, method) do
    @accepted_root
    |> Path.join("#{venue}/#{method}.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp recording do
    %{
      "capture_date" => "2026-07-26",
      "captured_at" => "2026-07-26T00:00:00Z",
      "endpoint" => "v5/market/tickers",
      "host" => "api.bybit.com",
      "method" => "fetch_ticker",
      "path" => "bybit/fetch_ticker.json",
      "venue" => "bybit"
    }
  end

  defp write_manifest!(root, key, rows) do
    File.mkdir_p!(root)
    write_json!(Path.join(root, "_manifest.json"), %{"count" => length(rows), key => rows})
  end

  defp write_json!(path, document), do: File.write!(path, Jason.encode!(document))
end
