defmodule Bourse.BybitAuthoredIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Balance
  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Trade

  @milliseconds_per_hour 60 * 60 * 1000
  @trade_limit 50
  # Demo host for C28 balance branch pin (granted fake funds). Not sandbox/testnet.
  @bybit_demo_url "https://api-demo.bybit.com"

  @moduletag :integration
  @moduletag :network

  test "public spot and linear reads need no caller category workaround" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:ok, %Bourse.Ticker{last: last}} = Bourse.fetch_ticker(exchange, "BTC/USDT")
    assert is_number(last) and last > 0

    assert {:ok, %Bourse.OrderBook{bids: bids, asks: asks}} =
             Bourse.fetch_order_book(exchange, "BTC/USDT:USDT")

    assert bids != []
    assert asks != []

    assert {:ok, spot_rows} = Bourse.fetch_ohlcv(exchange, "BTC/USDT", "1m", limit: 2)
    assert {:ok, linear_rows} = Bourse.fetch_ohlcv(exchange, "BTC/USDT:USDT", "1m", limit: 2)
    assert_ohlcv_rows(spot_rows)
    assert_ohlcv_rows(linear_rows)
  end

  test "public system status uses the venue status event schema" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:ok, %{status: status, info: %{"retCode" => 0, "result" => %{"list" => events}}}} =
             Bourse.fetch_status(exchange)

    assert status in ["ok", "maintenance"]
    assert Enum.all?(events, &(is_map(&1) and &1["state"] in ["scheduled", "ongoing", "completed", "canceled"]))
  end

  test "signed unified wallet balance parses coin rows" do
    credentials = require_credentials!(:bybit, url: "https://api-testnet.bybit.com")
    exchange = build_exchange(:bybit, credentials: credentials, sandbox: true)

    assert {:ok, %Balance{} = balance} = Bourse.fetch_balance(exchange)
    assert map_size(balance.total) > 0
    assert Enum.all?(balance.total, fn {currency, total} -> is_binary(currency) and is_number(total) end)
  end

  # Task 307 / C28 — pin the live UTA availability branch on the demo host (granted funds).
  # Bybit docs: availableToWithdraw is Deprecated for accountType=UNIFIED from 9 Jan 2025 and
  # returns "". Live demo rows take the when_keys_absent used sum; free reconciles as total−used.
  # The availableToWithdraw-present branch is a known live gap on UTA UNIFIED.
  test "live demo wallet-balance rows take the availableToWithdraw-absent used branch" do
    exchange = bybit_demo_exchange!()

    assert {:ok, %Balance{} = balance} =
             Bourse.fetch_balance(exchange, base_url: @bybit_demo_url)

    coins =
      balance.info
      |> get_in(["result", "list"])
      |> List.wrap()
      |> Enum.flat_map(&Map.get(&1, "coin", []))

    assert coins != [],
           "Bybit demo wallet-balance returned no coin rows: #{inspect(balance.info)}"

    observed_absent =
      Enum.filter(coins, fn coin ->
        availability_absent?(coin, "availableToWithdraw") and availability_absent?(coin, "free")
      end)

    observed_present =
      Enum.reject(coins, fn coin ->
        availability_absent?(coin, "availableToWithdraw") and availability_absent?(coin, "free")
      end)

    assert observed_absent != [],
           "expected at least one live UTA row on the availableToWithdraw-absent branch; got #{inspect(coins)}"

    # known gap (C28): availableToWithdraw-present is not observable on UTA UNIFIED — offline pins it.
    # When non-empty availability keys appear, the loop below pins the present branch.

    for coin <- observed_absent do
      ccy = coin["coin"]
      free = Map.fetch!(balance.free, ccy)
      used = Map.fetch!(balance.used, ccy)
      total = Map.fetch!(balance.total, ccy)
      wallet = Bourse.Safe.number(coin["walletBalance"])
      locked = Bourse.Safe.number(coin["locked"]) || 0.0
      position_im = Bourse.Safe.number(coin["totalPositionIM"]) || 0.0
      order_im = Bourse.Safe.number(coin["totalOrderIM"]) || 0.0
      expected_used = locked + position_im + order_im

      assert_in_delta total, wallet, 1.0e-10, "#{ccy}: total must map walletBalance (got #{total} vs #{wallet})"

      assert_in_delta used,
                      expected_used,
                      1.0e-10,
                      "#{ccy}: used must sum locked+totalPositionIM+totalOrderIM when " <>
                        "availableToWithdraw is empty (got #{used} vs #{expected_used})"

      assert_in_delta free,
                      total - used,
                      1.0e-8,
                      "#{ccy}: free must reconcile as total−used when availability keys are empty " <>
                        "(got #{free} vs #{total - used})"
    end

    for coin <- observed_present do
      ccy = coin["coin"]
      free = Map.fetch!(balance.free, ccy)
      used = Map.fetch!(balance.used, ccy)
      total = Map.fetch!(balance.total, ccy)
      avail = Bourse.Safe.number(coin["availableToWithdraw"] || coin["free"])

      assert_in_delta free, avail, 1.0e-10, "#{ccy}: free must come from availableToWithdraw/free when present"

      assert_in_delta used, total - free, 1.0e-8, "#{ccy}: used must be total−free when availableToWithdraw is present"
    end
  end

  test "invalid credentials produce Bybit's authentication error" do
    exchange =
      build_exchange(:bybit,
        credentials: Credentials.new!(api_key: "invalid-task-171", secret: "invalid-task-171"),
        sandbox: true
      )

    assert {:error, %Error{type: type}} = Bourse.fetch_balance(exchange)
    assert type in [:authentication_error, :permission_denied]
  end

  test "a deliberately invalid convert quote reaches Bybit without executing a conversion" do
    credentials = require_credentials!(:bybit, url: "https://api-testnet.bybit.com")
    exchange = build_exchange(:bybit, credentials: credentials, sandbox: true)

    assert {:error, %Error{type: :permission_denied, code: code, message: message}} =
             Bourse.create_convert_trade(exchange, "invalid-quote-tx-id-347", "USDT", "BTC", 1)

    # The provisioned testnet key lacks the Exchange permission, so Bybit rejects
    # this POST with its business-level permission response before any conversion
    # can execute.
    assert code in [10_005, "10005"]
    assert is_binary(message) and message != ""
  end

  test "public option volatility maps the symbol base coin and surfaces Bybit validation" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:ok, rows} = Bourse.fetch_volatility_history(exchange, "BTC/USD:BTC", period: 7)
    assert is_list(rows)

    assert {:error, %Error{type: :bad_request, code: code, message: message}} =
             Bourse.fetch_volatility_history(exchange, "BTC/USD:BTC", baseCoin: "NOPE", period: 7)

    assert code in [10_001, "10001"]
    assert is_binary(message) and message != ""
  end

  test "signed cross-borrow-rate returns Bybit's hourly collateral rate" do
    credentials = require_credentials!(:bybit, url: "https://api-testnet.bybit.com")
    exchange = build_exchange(:bybit, credentials: credentials, sandbox: true)

    assert {:ok, %Bourse.BorrowRate{currency: "USDT", rate: rate, period: 3_600_000}} =
             Bourse.fetch_cross_borrow_rate(exchange, "USDT")

    assert is_number(rate) and rate > 0

    assert {:error, %Error{code: code}} = Bourse.fetch_cross_borrow_rate(exchange, "NOT_A_CURRENCY")
    assert code in [181_015, "181015"]
  end

  test "public trades preserve Bybit's public trade semantics" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:ok, %{body: %{"result" => %{"list" => rows}}}} =
             Bourse.Bybit.public_get_v5_market_recent_trade(exchange, %{
               "category" => "spot",
               "symbol" => "BTCUSDT",
               "limit" => @trade_limit
             })

    assert rows != []
    assert {:ok, trades} = Bourse.Bybit.parse_trade(rows, symbol: "BTC/USDT")

    Enum.each(trades, fn trade ->
      assert %Trade{} = trade
      assert is_number(trade.price)
      assert is_number(trade.amount)
      assert is_number(trade.cost)
      assert trade.taker_or_maker == nil
      assert is_nil(trade.fee) or trade.fee == %{"cost" => nil, "currency" => nil}
    end)
  end

  test "an invalid public trade symbol yields Bybit bad_request" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:error, %Error{type: :bad_request, code: code, message: message}} =
             Bourse.Bybit.public_get_v5_market_recent_trade(exchange, %{
               "category" => "spot",
               "symbol" => "NOT-A-SYMBOL",
               "limit" => 1
             })

    assert code in [10_001, "10001"]
    assert is_binary(message) and message =~ "symbol"
  end

  test "private trade history carries Bybit execution fee semantics" do
    credentials = require_credentials!(:bybit, url: "https://api-testnet.bybit.com")
    exchange = build_exchange(:bybit, credentials: credentials, sandbox: true)

    assert {:ok, %{body: %{"result" => %{"list" => rows}}}} =
             Bourse.Bybit.private_get_v5_execution_list(exchange, %{
               "category" => "linear",
               "limit" => @trade_limit
             })

    assert {:ok, trades} = Bourse.Bybit.parse_trade(rows)

    if trades == [] do
      flunk("""
      Bybit testnet has no private trade history to verify fee semantics.
      Create and neutralize the smallest isolated linear testnet trade, then rerun this test.
      The current provisioned key may return Bybit error 10024 when trading is region-restricted.
      """)
    end

    Enum.each(trades, fn trade ->
      assert %Trade{taker_or_maker: taker_or_maker, fee: fee} = trade
      assert taker_or_maker in ["maker", "taker"]
      assert is_number(fee["cost"])
      assert is_number(fee["rate"])
      assert is_binary(fee["currency"]) and fee["currency"] != ""
    end)
  end

  # Task 230 — open interest: linear amount vs inverse value (Bybit V5 semantics).
  test "fetch_open_interest pins linear amount and inverse value units" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:ok, %Bourse.OpenInterest{} = linear} =
             Bourse.fetch_open_interest(exchange, "BTC/USDT:USDT", limit: 1)

    assert linear.symbol == "BTC/USDT:USDT"
    assert is_number(linear.open_interest_amount) and linear.open_interest_amount > 0
    assert is_nil(linear.open_interest_value)
    assert is_integer(linear.timestamp)

    assert {:ok, %Bourse.OpenInterest{} = inverse} =
             Bourse.fetch_open_interest(exchange, "BTC/USD:BTC", limit: 1)

    assert inverse.symbol == "BTC/USD:BTC"
    assert is_nil(inverse.open_interest_amount)
    assert is_number(inverse.open_interest_value) and inverse.open_interest_value > 0
  end

  # Task 230 — invalid category is a domain-error pin (raw open-interest path).
  test "open interest with illegal category yields Bybit bad_request" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:error, %Error{type: :bad_request, code: code, message: message}} =
             Bourse.Bybit.public_get_v5_market_open_interest(exchange, %{
               "symbol" => "BTCUSDT",
               "category" => "not-a-category"
             })

    assert code in [10_001, "10001"]
    assert is_binary(message) and message =~ "category"
  end

  # Task 232 — funding rate: live ticker/instrument cadence (not a hardcoded periods-per-day).
  # Anchor observed 2026-07-16: fundingRate 0.005, fundingIntervalHour "8" → interval "8h".
  test "fetch_funding_rate pins live numeric rate and venue-derived interval" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:ok, %{body: body}} =
             Bourse.Bybit.public_get_v5_market_tickers(exchange, %{
               "category" => "linear",
               "symbol" => "BTCUSDT"
             })

    raw = body |> get_in(["result", "list"]) |> List.first()
    assert is_map(raw)

    raw_rate = String.to_float(raw["fundingRate"])
    raw_interval_hour = raw["fundingIntervalHour"]

    assert {:ok, %Bourse.FundingRate{} = rate} = Bourse.fetch_funding_rate(exchange, "BTC/USDT:USDT")
    assert rate.symbol == "BTC/USDT:USDT"
    assert is_number(rate.funding_rate)
    assert_in_delta rate.funding_rate, raw_rate, 1.0e-12
    assert is_integer(rate.funding_timestamp)
    assert is_binary(rate.funding_datetime)

    # Cadence from venue data only — fundingIntervalHour on the ticker (live), never a constant.
    assert is_binary(raw_interval_hour) and raw_interval_hour != ""
    assert rate.interval == raw_interval_hour <> "h"
  end

  # Task 232 — funding rate history public read (chronological rows, numeric rates).
  test "fetch_funding_rate_history returns chronological numeric rows" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:ok, rows} =
             Bourse.fetch_funding_rate_history(exchange, "BTC/USDT:USDT", limit: 3)

    assert is_list(rows) and length(rows) == 3

    Enum.each(rows, fn row ->
      assert %Bourse.FundingRateHistory{} = row
      assert row.symbol == "BTC/USDT:USDT"
      assert is_number(row.funding_rate)
      assert is_integer(row.timestamp)
      assert is_binary(row.datetime)
    end)

    timestamps = Enum.map(rows, & &1.timestamp)
    assert timestamps == Enum.sort(timestamps)

    assert {:ok, %Bourse.FundingRate{interval: interval}} =
             Bourse.fetch_funding_rate(exchange, "BTC/USDT:USDT")

    assert interval == observed_funding_interval!(rows)
    refute interval == "1h"
  end

  # Task 232 — invalid category is a domain-error pin (raw tickers path used by funding rates).
  test "funding rate with illegal category yields Bybit bad_request" do
    exchange = build_exchange(:bybit, sandbox: true)

    assert {:error, %Error{type: :bad_request, code: code, message: message}} =
             Bourse.Bybit.public_get_v5_market_tickers(exchange, %{
               "category" => "not-a-category",
               "symbol" => "BTCUSDT"
             })

    assert code in [10_001, "10001"]
    assert is_binary(message) and message =~ "category"
  end

  # Task 230 — signed positions read succeeds (zero-size row still fully parsed).
  # Non-empty open positions require trade permission; testnet keys in this
  # environment return regulatory 10024 on create_order (documented in gate evidence).
  test "signed fetch_positions returns parsed Position structs" do
    credentials = require_credentials!(:bybit, url: "https://api-testnet.bybit.com")
    exchange = build_exchange(:bybit, credentials: credentials, sandbox: true)

    assert {:ok, positions} = Bourse.fetch_positions(exchange, symbols: ["BTC/USDT:USDT"])
    assert is_list(positions)

    Enum.each(positions, fn position ->
      assert %Bourse.Position{} = position
      assert position.symbol == "BTC/USDT:USDT"
      assert is_boolean(position.hedged) or is_nil(position.hedged)
      # Task 306: linear V5 positions stamp contract_size 1 (venue contract size).
      assert position.contract_size == 1.0 or position.contract_size == 1

      if is_number(position.contracts) and position.contracts != 0 do
        assert position.side in ["long", "short"]
        assert is_number(position.initial_margin)
        assert is_number(position.leverage)
        assert is_number(position.notional)
      end
    end)
  end

  defp assert_ohlcv_rows(rows) when is_list(rows) and rows != [] do
    assert Enum.all?(rows, fn [timestamp, open, high, low, close, volume] ->
             is_integer(timestamp) and Enum.all?([open, high, low, close, volume], &is_number/1)
           end)
  end

  defp observed_funding_interval!(rows) do
    gaps =
      rows
      |> Enum.map(& &1.timestamp)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [left, right] -> right - left end)
      |> Enum.uniq()

    assert [gap_ms] = gaps
    assert rem(gap_ms, @milliseconds_per_hour) == 0
    "#{div(gap_ms, @milliseconds_per_hour)}h"
  end

  # Demo trading key (BYBIT_DEMO_*) — not the read-only testnet key. Flunks loudly
  # when missing so the C28 live branch pin never silently skips.
  defp bybit_demo_exchange! do
    api_key = System.get_env("BYBIT_DEMO_API_KEY")
    secret = System.get_env("BYBIT_DEMO_API_SECRET")

    if api_key in [nil, ""] or secret in [nil, ""] do
      flunk("""
      Missing Bybit DEMO-trading credentials for the C28 balance branch pin!

        export BYBIT_DEMO_API_KEY=...
        export BYBIT_DEMO_API_SECRET=...

      Create a demo-trading key from a bybit.com account (Demo Trading), or source ~/.secrets.
      The provisioned BYBIT_TESTNET_* key is read-only (business error 10024) and is not the demo host.
      """)
    end

    credentials = Credentials.new!(api_key: api_key, secret: secret)
    build_exchange(:bybit, credentials: credentials)
  end

  # Matches Bourse.Safe / when_keys_absent: missing or empty string is absent.
  defp availability_absent?(row, key) when is_map(row) and is_binary(key) do
    case Map.get(row, key) do
      nil -> true
      "" -> true
      _ -> false
    end
  end
end
