defmodule Bourse.Tier1SemanticOracleTest do
  # Task 180 — tier-1 (reality-anchored) semantic oracle for CCXT-divergence-prone
  # fields. Doctrine: docs/authored-specs.md § "The epistemology — provider-owned
  # contract, binary verification"; adjudications: docs/tier1-divergence-report.md.
  #
  # INDEPENDENCE INVARIANT: every expected value below is anchored on (a) a real
  # captured exchange response (test/fixtures/responses/, `mix ccxt.record_fixtures`)
  # and (b) the exchange's own API documentation — never CCXT JS, CCXT static
  # fixtures, or our field_maps. CCXT appears only as a cross-check in the report.
  #
  # Two assertion kinds:
  #   * tier-1 GREEN — our parse matches reality; guards against regression.
  #   * adjudicated divergence PIN — our parse is known-wrong/lossy vs reality
  #     (adjudicated in the report); the pin freezes the defective state so BOTH a
  #     new regression AND the authoring fix (tasks 170/171/181) fail loudly and
  #     force re-adjudication. A pin is never an endorsement of the pinned value.
  use ExUnit.Case, async: false

  alias Bourse.Exchange
  alias Bourse.OracleLabel
  alias Bourse.RecordedResponseFixtures
  alias Bourse.Test.FixtureGateIsolation
  alias Bourse.Unified

  @manifest_path "test/fixtures/responses/_manifest.json"
  @external_resource @manifest_path
  @recording_manifest @manifest_path |> File.read!() |> Jason.decode!()
  @okx_open_interest_timestamp_ms 1_784_649_600_000
  @okx_open_interest_value_usd 2_830_404_860.7702
  @okx_trading_volume_usd 6_024_096_502.2173
  @okx_option_open_interest_amount 35_667.9
  @okx_option_base_volume 7_312.96
  @milliseconds_per_hour 60 * 60 * 1000
  @usd_value_tolerance 1.0e-4
  @coin_value_tolerance 1.0e-4
  @tier1_fixture_paths [
    "deribit/fetch_markets.json",
    "deribit/fetch_trades.json",
    "deribit/fetch_funding_rate.json",
    "deribit/fetch_funding_rate_history.json",
    "hyperliquid/fetch_markets.json",
    "bybit/fetch_markets.json",
    "bybit/fetch_ticker.json",
    "okx/fetch_open_interest_history.json",
    "okx/fetch_open_interest_history_option.json"
  ]

  setup_all do
    IO.puts([
      "\n",
      OracleLabel.tier1_suite_banner(@tier1_fixture_paths, @recording_manifest, @manifest_path),
      "\n"
    ])

    :ok
  end

  # --- deribit fetchMarkets: precision semantics + type flags ------------------
  #
  # Reality (test/fixtures/responses/deribit/fetch_markets.json, BTC-PERPETUAL):
  # tick_size 0.5, contract_size 10.0, min_trade_amount 10.0,
  # instrument_type "reversed", settlement_period "perpetual".
  # Semantic source (non-Bourse): docs.deribit.com api-reference public-get_instruments —
  # tick_size "specifies minimal price change" (a TICK SIZE, not decimal places);
  # instrument_type is "linear" or "reversed" (reversed = inverse).
  test "deribit fetchMarkets: BTC-PERPETUAL precision (tick-size semantics) and type flags" do
    markets = replay!("deribit", :fetch_markets, :fetch_markets, "fetchMarkets", %{})
    perp = Enum.find(markets, &(&1.id == "BTC-PERPETUAL"))
    assert perp, "BTC-PERPETUAL missing from parsed deribit markets"

    # tier-1 GREEN: price precision carries the raw tick size verbatim
    assert perp.precision["price"] == 0.5
    assert is_float(perp.precision["price"]), "deribit precision is tick-size (float) semantics"
    assert perp.contract_size == 10.0
    assert perp.taker == 0.0005

    assert perp.precision_mode == "tick_size"
    assert perp.precision["amount"] == 10.0
    assert perp.limits["amount"]["min"] == 10.0
    assert perp.inverse == true
    assert perp.linear == false
    assert perp.swap == true
    assert perp.contract == true
    assert perp.type == "swap"
    assert perp.expiry == nil
  end

  # --- hyperliquid fetchMarkets: precision semantics ---------------------------
  #
  # Reality (test/fixtures/responses/hyperliquid/fetch_markets.json, universe BTC):
  # szDecimals 5. Semantic source (non-Bourse): hyperliquid.gitbook.io tick-and-lot-size —
  # sizes round to szDecimals (DECIMAL PLACES); prices allow ≤5 significant figures
  # and ≤ MAX_DECIMALS − szDecimals decimals, MAX_DECIMALS = 6 for perps.
  test "hyperliquid fetchMarkets: BTC amount precision (decimal-places semantics)" do
    markets = replay!("hyperliquid", :fetch_markets, :fetch_markets, "fetchMarkets", %{})
    btc = Enum.find(markets, &(&1.base == "BTC"))
    assert btc, "BTC missing from parsed hyperliquid markets"

    # tier-1 GREEN: amount precision is the szDecimals tick size (10^-szDecimals),
    # resolved to a float increment under the authored `tick_size` precision mode
    # (task 181 carve C1). szDecimals 5 → 1.0e-5. This replaces the earlier
    # decimal-places INTEGER copy, which was the internal contradiction C1 fixed:
    # `precision_mode: "tick_size"` with a raw integer `5` in `precision.amount`.
    assert btc.precision["amount"] == 1.0e-5
    assert btc.precision_mode == "tick_size", "hyperliquid amount precision is tick-size (float) semantics"

    # adjudicated divergence pin — report § 1.2
    assert_pin(
      btc.precision["price"],
      nil,
      "hyperliquid price rule (≤5 sig figs, ≤ 6−szDecimals decimals) not represented"
    )
  end

  # --- deribit fetchTrades: inverse-perp cost branch ----------------------------
  #
  # Reality (test/fixtures/responses/deribit/fetch_trades.json, trade 434762295):
  # amount 10.0, price 64044.5, contracts 1.0. Semantic source (non-Bourse):
  # docs.deribit.com public-get_last_trades_by_instrument — "For perpetual and
  # inverse futures the amount is in USD units." So the reality-anchored cost in
  # the settlement currency is amount / price ≈ 1.5614e-4 BTC (a $10 trade), NOT
  # amount * price = 640_445.0. Adjudication (report § 2): our-reading-wrong —
  # the ResponseParser `inverse_op` branch exists but never fires because our
  # deribit market parse leaves `inverse` nil (§ 1.3 pin above); Bourse and reality
  # agree here (cross-check in the report).
  test "deribit fetchTrades: inverse-perp cost uses the inverse branch" do
    trades = replay!("deribit", :fetch_trades, :fetch_trades, "fetchTrades", %{"symbol" => "BTC/USD:BTC"})
    trade = Enum.find(trades, &(&1.id == "434762295"))
    assert trade, "trade 434762295 missing from parsed deribit trades"

    # tier-1 GREEN: raw copies land verbatim
    assert trade.amount == 10.0
    assert trade.price == 64_044.5

    reality_cost = 10.0 / 64_044.5
    assert_in_delta reality_cost, 1.5614e-4, 1.0e-8

    assert_in_delta trade.cost, reality_cost, 1.0e-12
  end

  # --- bybit fetchMarkets: precision across categories ---------------------------
  #
  # Reality (test/fixtures/responses/bybit/fetch_markets.json): linear BTCUSDT has
  # priceFilter.tickSize "0.10" + lotSizeFilter.qtyStep "0.001"; spot BTCUSDT has
  # NO qtyStep — only lotSizeFilter.basePrecision "0.000001". Semantic source
  # (non-Bourse): bybit-exchange.github.io/docs/v5/market/instrument — tickSize/qtyStep
  # are step sizes ("the step to increase/reduce order price/quantity");
  # basePrecision ("the precision of base coin") exists for spot only.
  test "bybit fetchMarkets: linear tick-size precision and spot basePrecision" do
    assert {:ok, markets} =
             Unified.call(Exchange.new!("bybit"), :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, bybit_stub!()})

    linear = Enum.find(markets, &(&1.id == "BTCUSDT" and &1.info["contractType"] == "LinearPerpetual"))
    assert linear, "linear BTCUSDT missing from parsed bybit markets"

    # tier-1 GREEN: both members present, tick-size (float) semantics
    assert linear.precision["price"] == 0.1
    assert linear.precision["amount"] == 0.001

    spot = Enum.find(markets, &(&1.id == "BTCUSDT" and is_nil(&1.info["contractType"])))
    assert spot, "spot BTCUSDT missing from parsed bybit markets"
    assert spot.precision["price"] == 0.1

    assert spot.precision["amount"] == 0.000001
  end

  test "bybit fetchMarkets: venue-native identity and contract flags preserve every recorded instrument" do
    fixture = load_fixture!("bybit", :fetch_markets)
    raw_count = Enum.sum(for response <- fixture["responses"], do: length(response["body"]["result"]["list"]))

    assert {:ok, markets} =
             Unified.call(Exchange.new!("bybit"), :fetch_markets, "fetchMarkets", %{}, plug: {Req.Test, bybit_stub!()})

    assert length(markets) == raw_count
    assert markets |> Enum.map(& &1.symbol) |> Enum.uniq() |> length() == raw_count

    spot = Enum.find(markets, &(&1.id == "BTCUSDT" and &1.spot == true))
    assert %{symbol: "BTC/USDT", swap: false, future: false, contract: false, active: true} = spot
    assert %{linear: false, inverse: false, settle: nil, expiry: nil} = spot

    linear_perpetual = Enum.find(markets, &(&1.id == "BTCUSDT" and &1.info["contractType"] == "LinearPerpetual"))
    assert %{symbol: "BTC/USDT:USDT", swap: true, future: false, contract: true, active: true} = linear_perpetual
    assert %{linear: true, inverse: false, settle: "USDT", expiry: nil} = linear_perpetual

    inverse_perpetual = Enum.find(markets, &(&1.id == "BTCUSD" and &1.info["contractType"] == "InversePerpetual"))
    assert %{symbol: "BTC/USD:BTC", swap: true, future: false, contract: true, active: true} = inverse_perpetual
    assert %{linear: false, inverse: true, settle: "BTC", expiry: nil} = inverse_perpetual

    dated_future = Enum.find(markets, &(&1.id == "BTCUSDT-17JUL26"))
    assert %{symbol: "BTC/USDT:USDT-260717", swap: false, future: true, contract: true, active: true} = dated_future
    assert %{linear: true, inverse: false, settle: "USDT", expiry: 1_784_275_200_000} = dated_future
    assert dated_future.expiry_datetime == Bourse.Timestamp.iso8601_from_ms(dated_future.expiry)

    assert {:ok, option} =
             Bourse.Bybit.parse_market(%{
               "symbol" => "BTC-25DEC26-100000-C-USDT",
               "baseCoin" => "BTC",
               "quoteCoin" => "USDT",
               "settleCoin" => "USDC",
               "category" => "option",
               "status" => "Trading"
             })

    assert %{type: "option", spot: false, swap: false, future: false, option: true, contract: true} = option
    assert %{linear: false, inverse: false, active: true, settle: "USDC"} = option
  end

  test "bybit fetchTicker: response-envelope clock stamps the extracted ticker row" do
    fixture = load_fixture!("bybit", :fetch_ticker)
    timestamp = fixture["body"]["time"]

    assert {:ok, ticker} =
             Bourse.fetch_ticker(
               Exchange.new!("bybit"),
               fixture["symbol"],
               plug: {Req.Test, bybit_stub!()}
             )

    assert ticker.timestamp == timestamp
    assert ticker.datetime == Bourse.Timestamp.iso8601_from_ms(timestamp)
  end

  # --- bybit fetchFundingRate: interval ----------------------------------------
  #
  # Reality (test/fixtures/responses/bybit/fetch_ticker.json — funding rides the
  # same v5 tickers endpoint the recorded cassette captured): fundingRate
  # "-0.00000276", fundingIntervalHour "8", nextFundingTime "1782000000000".
  # Semantic source (non-Bourse): bybit-exchange.github.io/docs/v5/market/tickers —
  # fundingIntervalHour is the per-symbol "funding interval hour" (whole hours;
  # symbols vary per Bybit's own announcements).
  test "bybit fetchFundingRate: rate, timestamp, and per-symbol interval" do
    # fetchFundingRate on bybit is emulated over fetchFundingRates and resolves
    # the market via an inline fetchMarkets round, so the stub routes both
    # recorded cassettes: instruments-info (category fan-out) and tickers.
    assert {:ok, funding} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_funding_rate,
               "fetchFundingRate",
               %{"symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, bybit_stub!()}
             )

    # tier-1 GREEN
    assert funding.funding_rate == -0.00000276
    assert funding.funding_timestamp == 1_782_000_000_000

    assert funding.interval == "8h"
  end

  # B3 negative direction (docs/authored-spec-carves/bybit.md): a tickers payload
  # without fundingIntervalHour keeps `interval` nil — the parser never invents
  # the interval from a markets cache the raw response does not carry (CCXT's
  # offline golden does).
  test "bybit fetchFundingRate: absent fundingIntervalHour stays nil, never invented" do
    drop_interval = fn body ->
      update_in(body, ["result", "list"], fn rows ->
        Enum.map(rows, &Map.delete(&1, "fundingIntervalHour"))
      end)
    end

    assert {:ok, funding} =
             Unified.call(
               Exchange.new!("bybit"),
               :fetch_funding_rate,
               "fetchFundingRate",
               %{"symbol" => "BTC/USDT:USDT"},
               plug: {Req.Test, bybit_stub!(ticker_transform: drop_interval)}
             )

    assert funding.funding_rate == -0.00000276
    assert funding.interval == nil
  end

  # --- deribit fetchFundingRate: hourly venue cadence ---------------------------
  #
  # Reality (test/fixtures/responses/deribit/fetch_funding_rate.json): the RPC
  # result is the bare scalar 0.00009056435480116205 — the funding rate over the
  # requested [start_timestamp, end_timestamp] window. The separately registered
  # provider history recording carries 12 hourly rows over 12 hours, and Deribit's
  # own endpoint documentation describes those rows as hourly history.
  test "deribit fetchFundingRate: scalar rate and observed hourly cadence" do
    funding =
      replay!("deribit", :fetch_funding_rate, :fetch_funding_rate, "fetchFundingRate", %{"symbol" => "BTC/USD:BTC"})

    history = load_fixture!("deribit", :fetch_funding_rate_history)

    gaps =
      history["body"]["result"]
      |> Enum.map(& &1["timestamp"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [left, right] -> right - left end)
      |> Enum.uniq()

    # tier-1 GREEN
    assert funding.funding_rate == 0.00009056435480116205
    assert gaps == [@milliseconds_per_hour]
    assert funding.interval == "1h"
  end

  # --- okx fetchOpenInterestHistory: contracts column semantics -----------------
  #
  # Reality (test/fixtures/responses/okx/fetch_open_interest_history.json):
  # contracts Rubik rows are [ts, oi, vol]. OKX documents oi and vol in USD, so
  # they are value/quote-volume fields; the row does not expose contract amount.
  test "okx fetchOpenInterestHistory: contracts columns preserve USD open interest and volume" do
    history =
      replay!(
        "okx",
        :fetch_open_interest_history,
        :fetch_open_interest_history,
        "fetchOpenInterestHistory",
        %{"symbol" => "BTC/USDT:USDT", "timeframe" => "1d"}
      )

    assert [%Bourse.OpenInterest{} = interest | _] = history
    assert interest.symbol == "BTC/USDT:USDT"
    assert interest.timestamp == @okx_open_interest_timestamp_ms
    assert interest.datetime == "2026-07-21T16:00:00.000Z"
    assert interest.open_interest_amount == nil
    assert interest.base_volume == nil
    assert_in_delta interest.open_interest_value, @okx_open_interest_value_usd, @usd_value_tolerance
    assert_in_delta interest.quote_volume, @okx_trading_volume_usd, @usd_value_tolerance
  end

  # --- okx fetchOpenInterestHistory: option column semantics --------------------
  #
  # Reality (test/fixtures/responses/okx/fetch_open_interest_history_option.json):
  # option Rubik rows are [ts, oi, vol] with oi and vol coin-denominated (BTC).
  # That is the mirror of the contracts USD map: amount/base_volume populated,
  # value/quote_volume nil. Guard against silently swapping the discriminator.
  test "okx fetchOpenInterestHistory: option columns preserve coin open interest and volume" do
    option_symbol = "BTC/USD:BTC-260622-60000-C"

    history =
      replay!(
        "okx",
        :fetch_open_interest_history_option,
        :fetch_open_interest_history,
        "fetchOpenInterestHistory",
        %{"symbol" => option_symbol, "timeframe" => "1d"}
      )

    assert [%Bourse.OpenInterest{} = interest | _] = history
    assert interest.symbol == option_symbol
    assert interest.timestamp == @okx_open_interest_timestamp_ms
    assert interest.datetime == "2026-07-21T16:00:00.000Z"
    assert interest.open_interest_value == nil
    assert interest.quote_volume == nil
    assert_in_delta interest.open_interest_amount, @okx_option_open_interest_amount, @coin_value_tolerance
    assert_in_delta interest.base_volume, @okx_option_base_volume, @coin_value_tolerance
  end

  # --- helpers ------------------------------------------------------------------

  # Routes bybit requests to the matching recorded cassette: instruments-info
  # (param fan-out per category) and tickers (the fetch_ticker recording, which
  # carries the funding fields — same v5 tickers endpoint).
  defp bybit_stub!(opts \\ []) do
    FixtureGateIsolation.isolate!("bybit")
    ticker_transform = Keyword.get(opts, :ticker_transform, &Function.identity/1)

    markets = load_fixture!("bybit", :fetch_markets)
    ticker = load_fixture!("bybit", :fetch_ticker)
    stub = {__MODULE__, :bybit, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      cond do
        String.contains?(conn.request_path, "instruments-info") ->
          category = Plug.Conn.fetch_query_params(conn).query_params["category"]
          Req.Test.json(conn, instruments_info_body!(markets, category))

        String.contains?(conn.request_path, "tickers") ->
          Req.Test.json(conn, ticker_transform.(ticker["body"]))

        true ->
          raise "unexpected bybit request path: #{conn.request_path}"
      end
    end)

    stub
  end

  # Task 251 added option (+ per-baseCoin) to the fan-out plan. The recorded
  # cassette still has spot/linear/inverse only; empty option success keeps
  # offline precision/identity pins green without re-recording.
  defp instruments_info_body!(markets, "option") do
    case Enum.find(markets["responses"], &(&1["params"]["category"] == "option")) do
      %{"body" => body} -> body
      nil -> %{"retCode" => 0, "result" => %{"category" => "option", "list" => []}}
    end
  end

  defp instruments_info_body!(markets, category) do
    case Enum.find(markets["responses"], &(&1["params"]["category"] == category)) do
      %{"body" => body} -> body
      nil -> raise "no recorded bybit instruments-info cassette for category #{inspect(category)}"
    end
  end

  defp load_fixture!(exchange_id, fixture_method) do
    exchange_id
    |> RecordedResponseFixtures.fixture_path(fixture_method)
    |> RecordedResponseFixtures.load_fixture!()
  end

  # Replays a recorded live cassette (fixture_method) through a unified dispatch
  # (method_atom/js_method) against a Req.Test stub — fully offline.
  defp replay!(exchange_id, fixture_method, method_atom, js_method, params) do
    FixtureGateIsolation.isolate!(exchange_id)

    fixture = load_fixture!(exchange_id, fixture_method)
    identity = OracleLabel.tier1_label_from_fixture(fixture, @recording_manifest, @manifest_path)

    stub = {__MODULE__, exchange_id, method_atom, System.unique_integer([:positive])}
    Req.Test.stub(stub, fn conn -> Req.Test.json(conn, fixture["body"]) end)

    exchange = Exchange.new!(exchange_id)

    assert {:ok, result} =
             Unified.call(exchange, method_atom, js_method, params, plug: {Req.Test, stub}),
           identity

    result
  end

  defp assert_pin(actual, pinned, note) do
    if actual == pinned do
      :ok
    else
      flunk("""
      Adjudicated tier-1 divergence pin changed: #{note}
      pinned (adjudicated defective state): #{inspect(pinned)}
      observed:                             #{inspect(actual)}
      Either a new regression or the authoring fix landed (tasks 170/171/181).
      Re-adjudicate docs/tier1-divergence-report.md and update this pin.
      """)
    end
  end
end
