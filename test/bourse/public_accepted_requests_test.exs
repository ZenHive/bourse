defmodule Bourse.PublicAcceptedRequestsTest do
  use ExUnit.Case, async: false

  alias Bourse.PublicAcceptedRequests

  @captured_at ~U[2026-07-26 00:00:00Z]

  test "inventory covers authored public read branches across all runtime venues" do
    branches = PublicAcceptedRequests.inventory()

    assert length(branches) >= 150
    assert branches |> Enum.map(& &1.venue) |> Enum.uniq() |> Enum.sort() == Bourse.Spec.exchanges()
    assert branches |> Enum.map(& &1.key) |> Enum.uniq() |> length() == length(branches)

    Enum.each(branches, fn branch ->
      assert branch.config.authenticated == false
      assert branch.config.method in [:get, :post]
      assert String.starts_with?(branch.js_method, "fetch")

      classification =
        branch.venue
        |> Bourse.Spec.owned_spec_path()
        |> Bourse.Spec.decode_file!()
        |> get_in(["endpoints", "transaction_classification", branch.js_method])

      assert classification["transactional"] == false
    end)
  end

  test "authored route selection preserves every distinct request-shape branch" do
    branches = PublicAcceptedRequests.inventory()

    assert branch_names(branches, "binance", "fetchOHLCV") ==
             MapSet.new(~w(
               dapiPublic_get_indexpriceklines
               dapiPublic_get_klines
               dapiPublic_get_markpriceklines
               dapiPublic_get_premiumindexklines
               eapiPublic_get_klines
               fapiPublic_get_indexpriceklines
               fapiPublic_get_klines
               fapiPublic_get_markpriceklines
               fapiPublic_get_premiumindexklines
               public_get_klines
             ))

    assert branch_names(branches, "deribit", "fetchTrades") ==
             MapSet.new(~w(
               public_get_get_last_trades_by_instrument
               public_get_get_last_trades_by_instrument_and_time
             ))

    assert branches |> branch_names("okx", "fetchOHLCV") |> MapSet.size() == 6
  end

  test "fixture paths, public slots, and generated manifest are stable" do
    branch = find_branch!("binance", "fetchTime", "public_get_time")
    golden = fake_golden!("binance", "fetchTime", "public_get_time")
    path = "binance/fetch_time--public_get_time.json"

    assert Path.relative_to_cwd(PublicAcceptedRequests.fixture_root()) ==
             "test/fixtures/public_accepted_requests"

    assert Path.relative_to_cwd(PublicAcceptedRequests.manifest_path()) ==
             "test/fixtures/public_accepted_requests/_manifest.json"

    assert PublicAcceptedRequests.fixture_relative_path(golden) == path
    assert PublicAcceptedRequests.sign_path(branch) == "sign_path.public.public"
    assert PublicAcceptedRequests.sign_path(golden["acceptance"]) == "sign_path.public.public"

    assert %{
             "count" => 1,
             "exclusion_count" => 0,
             "generated_at" => "2026-07-26T00:00:00Z",
             "goldens" => [%{"path" => ^path}]
           } = PublicAcceptedRequests.manifest([{:golden, golden}], @captured_at)
  end

  test "manifest completeness is exact and exclusions require a date and reason" do
    [first, second | _rest] = PublicAcceptedRequests.inventory()

    valid = %{
      "schema_version" => 1,
      "count" => 1,
      "exclusion_count" => 1,
      "goldens" => [row(first, %{"host" => "api.example", "http_status" => 200, "path" => "one.json"})],
      "exclusions" => [row(second, %{"reason" => "provider endpoint is unavailable"})]
    }

    assert PublicAcceptedRequests.manifest_errors(valid, [first, second]) == []

    invalid =
      valid
      |> put_in(["exclusions", Access.at(0), "reason"], "")
      |> update_in(["goldens"], &(&1 ++ [row(first, %{"host" => "api.example", "http_status" => 200})]))

    errors = PublicAcceptedRequests.manifest_errors(invalid, [first, second])
    assert Enum.any?(errors, &String.contains?(&1, "duplicate branch"))
    assert Enum.any?(errors, &String.contains?(&1, "exclusion reason is missing"))
  end

  test "capture is sequentially paced per HTTP call and replays pagination requests" do
    branch = find_branch!("bybit", "fetchMarkets", "public_get_v5_market_instruments_info")
    counter = :atomics.new(1, [])
    parent = self()

    transport = fn request ->
      page = :atomics.add_get(counter, 1, 1)
      cursor = if page == 1, do: "next-page", else: ""

      body = %{
        "retCode" => 0,
        "retMsg" => "OK",
        "result" => %{"list" => [], "nextPageCursor" => cursor}
      }

      {request, Req.Response.new(status: 200, body: body)}
    end

    sleep = fn milliseconds -> send(parent, {:paced, milliseconds}) end

    assert {:golden, golden} =
             PublicAcceptedRequests.record_branch(branch,
               captured_at: @captured_at,
               pacing_ms: 7,
               sleep: sleep,
               transport: transport
             )

    assert length(golden["requests"]) == 2
    assert get_in(golden, ["replay", "pagination_cursors"]) == ["next-page", ""]
    assert get_in(golden, ["replay", "timestamp_ms_override"]) == DateTime.to_unix(@captured_at, :millisecond)
    assert_receive {:paced, 7}
    assert_receive {:paced, 7}
    refute_receive {:paced, 7}
    assert :ok = PublicAcceptedRequests.replay(golden)
  end

  test "capture decodes raw transport bodies before cursor extraction" do
    branch = find_branch!("bybit", "fetchMarkets", "public_get_v5_market_instruments_info")
    counter = :atomics.new(1, [])

    transport = fn request ->
      page = :atomics.add_get(counter, 1, 1)
      cursor = if page == 1, do: "next-page", else: ""

      body =
        Jason.encode!(%{
          "retCode" => 0,
          "retMsg" => "OK",
          "result" => %{"list" => [], "nextPageCursor" => cursor}
        })

      response =
        [status: 200, body: :zlib.gzip(body)]
        |> Req.Response.new()
        |> Req.Response.put_header("content-encoding", "gzip")

      {request, response}
    end

    assert {:golden, golden} =
             PublicAcceptedRequests.record_branch(branch,
               captured_at: @captured_at,
               pacing_ms: 0,
               transport: transport
             )

    assert length(golden["requests"]) == 2
    assert get_in(golden, ["replay", "pagination_cursors"]) == ["next-page", ""]
    assert :ok = PublicAcceptedRequests.replay(golden)
  end

  test "capture accepts only HTTP 200" do
    branch = find_branch!("binance", "fetchTime", "public_get_time")

    transport = fn request ->
      {request, Req.Response.new(status: 204, body: %{})}
    end

    assert {:exclusion, %{"reason" => reason}} =
             PublicAcceptedRequests.record_branch(branch,
               captured_at: @captured_at,
               pacing_ms: 0,
               transport: transport
             )

    assert reason == ":non_200_response"
  end

  test "Alpaca crypto reads derive the provider's location and plural symbols parameter" do
    transport = fn request ->
      {request, Req.Response.new(status: 200, body: %{"bars" => %{"BTC/USD" => []}})}
    end

    for {method, branch_name} <- [
          {"fetchOHLCV", "market_public_get_v1beta3_crypto__loc__bars"},
          {"fetchTicker", "market_public_get_v1beta3_crypto__loc__snapshots"}
        ] do
      branch = find_branch!("alpaca", method, branch_name)

      assert {:golden, golden} =
               PublicAcceptedRequests.record_branch(branch,
                 captured_at: @captured_at,
                 pacing_ms: 0,
                 transport: transport
               )

      assert get_in(golden, ["replay", "params", "symbol"]) == "BTC/USD"
      refute get_in(golden, ["replay", "params"])["loc"]
      refute get_in(golden, ["replay", "params"])["symbols"]

      url = golden["requests"] |> hd() |> Map.fetch!("url")
      assert url =~ "/v1beta3/crypto/us/"
      assert url =~ "symbols=BTC%2FUSD"

      if method == "fetchOHLCV" do
        assert get_in(golden, ["replay", "params", "timeframe"]) == "1m"
        # Live-confirmed 2026-07-26: the venue accepts the authored "1min"
        # mapping (capabilities.timeframes) — no capture-side override.
        assert url =~ "timeframe=1min"
      end
    end
  end

  test "structural scrub rejects credential and account identity names without environment secrets" do
    golden = fake_golden!("binance", "fetchTime", "public_get_time")

    leaked =
      golden
      |> put_in(["requests", Access.at(0), "headers"], [["authorization", "Bearer static-value"]])
      |> put_in(["requests", Access.at(0), "url"], "https://api.binance.com/api/v3/time?api_key=static-value")
      |> put_in(["requests", Access.at(0), "body"], Jason.encode!(%{"user" => "public-account"}))

    violations = PublicAcceptedRequests.scrub_violations(leaked)
    assert Enum.any?(violations, &String.contains?(&1, "headers"))
    assert Enum.any?(violations, &String.contains?(&1, "query"))
    assert Enum.any?(violations, &String.contains?(&1, "body.user"))
  end

  test "replay rejects a self-consistent non-provider host" do
    golden = fake_golden!("binance", "fetchTime", "public_get_time")

    changed =
      golden
      |> put_in(["acceptance", "host"], "example.invalid")
      |> put_in(["requests", Access.at(0), "url"], "https://example.invalid/api/v3/time")

    assert {:error, :route_identity_mismatch} = PublicAcceptedRequests.replay(changed)
  end

  test "committed bulk manifest is exact, scrubbed, and replayable" do
    {manifest, goldens} = PublicAcceptedRequests.load_all!()

    assert manifest["count"] + manifest["exclusion_count"] == length(PublicAcceptedRequests.inventory())
    assert manifest["count"] > 0
    assert Enum.all?(manifest["goldens"], &(&1["http_status"] == 200))

    Enum.each(goldens, fn {_row, golden} ->
      assert PublicAcceptedRequests.scrub_violations(golden) == []
      assert PublicAcceptedRequests.replay(golden) == :ok
    end)
  end

  defp fake_golden!(venue, method, branch_name) do
    branch = find_branch!(venue, method, branch_name)

    transport = fn request ->
      {request, Req.Response.new(status: 200, body: %{"serverTime" => 1})}
    end

    assert {:golden, golden} =
             PublicAcceptedRequests.record_branch(branch,
               captured_at: @captured_at,
               pacing_ms: 0,
               transport: transport
             )

    golden
  end

  defp find_branch!(venue, method, branch_name) do
    Enum.find(PublicAcceptedRequests.inventory(venue), fn branch ->
      branch.js_method == method and branch.branch == branch_name
    end) || flunk("missing branch #{venue}:#{method}:#{branch_name}")
  end

  defp branch_names(branches, venue, method) do
    branches
    |> Enum.filter(&(&1.venue == venue and &1.js_method == method))
    |> MapSet.new(& &1.branch)
  end

  defp row(branch, extra) do
    Map.merge(
      %{
        "branch" => branch.branch,
        "capture_date" => "2026-07-26",
        "endpoint" => branch.config.path,
        "method" => branch.js_method,
        "sections" => branch.config.sections,
        "venue" => branch.venue
      },
      extra
    )
  end
end
