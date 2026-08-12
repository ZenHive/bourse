defmodule Bourse.OkxAuthoredIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 1, build_exchange: 2]

  alias Bourse.Balance
  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.MarginModification
  alias Bourse.Test.FixtureGateIsolation
  alias Bourse.Unified.ReadParse

  @moduletag :integration
  @moduletag :network

  @okx_demo_host "www.okx.com"
  @margin_adjustment_amount 1
  @order_probe_price_ratio 0.5
  @order_probe_price_decimal_places 1
  @order_probe_size "0.001"
  @algo_probe_size "1"
  @algo_probe_trigger_price "2"
  @missing_algo_id "999999999999999999"
  @position_money_tolerance 1.0e-8
  @position_ratio_tolerance 1.0e-4
  @percentage_scale 100
  @market_load_timeout_ms 120_000
  @canonical_future_symbol ~r"^[^/]+/[^:]+:[^-]+-\d{6}$"
  @canonical_option_symbol ~r"^[^/]+/[^:]+:[^-]+-\d{6}-\d+(?:\.\d+)?-[CP]$"
  @canonical_swap_symbol ~r"^[^/]+/[^:]+:[^-]+$"

  setup do
    FixtureGateIsolation.isolate!("okx")
    :ok
  end

  test "public ticker parses from live production" do
    exchange = build_exchange(:okx)

    assert {:ok, %Bourse.Ticker{symbol: "BTC/USDT", last: last}} =
             Bourse.fetch_ticker(exchange, "BTC/USDT")

    assert is_binary(last) or is_number(last)
    refute last in [nil, "", 0, "0"]
  end

  test "international demo ohlcv retains live candle order and rejects an unknown instrument" do
    exchange = demo_exchange()

    assert {:ok, candles} = Bourse.fetch_ohlcv(exchange, "BTC/USDT", "1h", limit: 3)
    assert is_list(candles)
    assert candles != []
    assert match?([_ts, _o, _h, _l, _c, _v | _], hd(candles))
    assert Enum.sort_by(candles, &hd/1) == candles

    assert Enum.all?(candles, fn [timestamp, open, high, low, close, volume] ->
             is_integer(timestamp) and is_number(open) and is_number(high) and is_number(low) and
               is_number(close) and is_number(volume)
           end)

    assert {:error, %Error{type: :bad_symbol, code: "51001"}} =
             Bourse.fetch_ohlcv(exchange, "NOPE/USDT", "1h", limit: 1)
  end

  test "international demo order-book, ticker, and trade request builds reach their documented public schemas" do
    exchange = build_exchange(:okx, sandbox: true, hostname: @okx_demo_host)

    assert {:ok, %Bourse.OrderBook{bids: bids, asks: asks}} =
             Bourse.fetch_order_book(exchange, "BTC/USDT", limit: 5)

    assert bids != [] and asks != []

    assert {:error, %Error{type: :bad_symbol, code: "51001"}} =
             Bourse.fetch_order_book(exchange, "NOPE/USDT", limit: 1)

    assert {:ok, %{"BTC/USDT:USDT" => %Bourse.Ticker{}}} =
             Bourse.fetch_tickers(exchange, symbols: ["BTC/USDT:USDT"])

    assert {:error, %Error{type: :bad_request, code: "51000"}} =
             Bourse.fetch_tickers(exchange, instType: "NOPE")

    assert {:ok, [%Bourse.Trade{} | _]} = Bourse.fetch_trades(exchange, "BTC/USDT", limit: 2)

    assert {:error, %Error{type: :bad_symbol, code: "51001"}} =
             Bourse.fetch_trades(exchange, "NOPE/USDT", limit: 1)
  end

  test "international demo option and open-interest reads pin live success and venue errors" do
    exchange = build_exchange(:okx, sandbox: true, hostname: @okx_demo_host)

    assert {:ok, option_chain} = Bourse.fetch_option_chain(exchange, "BTC")
    assert is_map(option_chain) and map_size(option_chain) > 0

    assert {:error, %Error{type: :bad_request, code: "51000"}} =
             Bourse.fetch_option_chain(exchange, "BTC", instType: "NOPE")

    assert {:ok, greeks} = Bourse.fetch_all_greeks(exchange, instFamily: "BTC-USD")
    assert is_map(greeks) and map_size(greeks) > 0

    assert {:error, %Error{type: :bad_request, code: "51000"}} =
             Bourse.fetch_all_greeks(exchange, instFamily: "NOPE")

    assert {:ok, [%Bourse.OpenInterest{} = interest | _]} =
             Bourse.fetch_open_interest_history(exchange, "BTC/USDT:USDT", timeframe: "1d")

    assert interest.symbol == "BTC/USDT:USDT"
    assert is_integer(interest.timestamp)
    assert is_number(interest.open_interest_value)
    assert is_number(interest.quote_volume)
    assert interest.open_interest_amount == nil
    assert interest.base_volume == nil

    assert {:error, %Error{type: :bad_symbol, code: "51012"}} =
             Bourse.fetch_open_interest_history(exchange, "NOPE/USDT:USDT")
  end

  @tag :dangerous
  test "international demo option sz round-trips through ctVal and ctMult and rejects a fractional lot" do
    assert {:ok, exchange} = Bourse.load_markets(demo_exchange())

    market =
      Enum.find(
        exchange.markets,
        &(&1.option and &1.active and String.starts_with?(&1.id, "BTC-USD-"))
      )

    assert %Bourse.Market{
             quantity_unit: "base",
             native_quantity_unit: "contracts",
             native_quantity_field: "sz",
             contract_size: contract_size,
             native_amount_step: native_step,
             settle: settle,
             expiry: expiry,
             strike: strike,
             option_type: option_type
           } = market

    ct_val = Bourse.Safe.number(market.info["ctVal"])
    ct_mult = Bourse.Safe.number(market.info["ctMult"])
    lot_size = Bourse.Safe.number(market.info["lotSz"])
    canonical_step = market.precision["amount"]

    assert contract_size == ct_val * ct_mult
    assert native_step == lot_size
    assert canonical_step == lot_size * contract_size
    assert market.limits["amount"]["min"] == Bourse.Safe.number(market.info["minSz"]) * contract_size
    assert is_binary(settle)
    assert is_integer(expiry)
    assert is_number(strike)
    assert option_type in ["call", "put"]

    assert {:ok, %Bourse.Order{id: order_id}} =
             Bourse.create_order(exchange, market.symbol, "limit", "buy", canonical_step,
               price: market.precision["price"],
               tdMode: "isolated",
               clientOrderId: "t397#{System.unique_integer([:positive])}"
             )

    try do
      assert {:ok, %Bourse.Order{amount: ^canonical_step, filled: 0, remaining: ^canonical_step}} =
               Bourse.fetch_order(exchange, order_id, symbol: market.symbol)
    after
      assert {:ok, %Bourse.Order{id: ^order_id}} =
               Bourse.cancel_order(exchange, order_id, symbol: market.symbol)
    end

    invalid_native_size = native_step / 2

    assert {:error, %Error{code: "1", raw: %{"data" => [error_row | _]}}} =
             Bourse.Okx.private_post_trade_order(exchange, %{
               "instId" => market.id,
               "tdMode" => "isolated",
               "side" => "buy",
               "ordType" => "limit",
               "sz" => to_string(invalid_native_size),
               "px" => to_string(market.precision["price"]),
               "clOrdId" => "t397bad#{System.unique_integer([:positive])}"
             })

    assert error_row["sCode"] == "51121"
    assert error_row["sMsg"] =~ "multiple of the lot size"
  end

  test "public open interest parses a populated documented row and reports an invalid instId" do
    exchange = build_exchange(:okx)
    params = %{"instType" => "SWAP", "instId" => "BTC-USDT-SWAP"}

    assert {:ok, %{body: %{"data" => [raw | _] = data}}} =
             Bourse.Okx.public_get_public_open_interest(exchange, params)

    assert is_binary(raw["oi"]) and is_binary(raw["oiCcy"]) and is_binary(raw["oiUsd"])

    assert {:ok, %Bourse.OpenInterest{} = interest} =
             ReadParse.parse(
               exchange,
               Bourse.Okx,
               :fetch_open_interest,
               "fetchOpenInterest",
               %{"code" => "0", "msg" => "", "data" => data},
               %{"symbol" => "BTC/USDT:USDT"},
               :parse_open_interest,
               false
             )

    assert interest.symbol == "BTC/USDT:USDT"
    assert interest.open_interest_amount == Bourse.Safe.number(raw["oi"])
    assert interest.base_volume == Bourse.Safe.number(raw["oiCcy"])
    assert interest.open_interest_value == Bourse.Safe.number(raw["oiUsd"])
    assert interest.timestamp == Bourse.Safe.integer(raw["ts"])

    assert {:error, %Error{type: :bad_symbol}} =
             Bourse.Okx.public_get_public_open_interest(exchange, %{"instType" => "SWAP", "instId" => "NOPE-USDT-SWAP"})
  end

  test "public status returns the unified operational envelope" do
    exchange = build_exchange(:okx)

    assert {:ok, %{status: "ok", updated: nil, eta: nil, url: nil, info: %{"code" => "0"}}} =
             Bourse.fetch_status(exchange)
  end

  test "live option instId round-trips through the unified symbol and keeps the quote" do
    exchange = build_exchange(:okx, sandbox: true, hostname: @okx_demo_host)

    # Options expire continuously, so the instrument under test is discovered from
    # the venue rather than pinned to an expiry that delists days later.
    inst_id = live_option_inst_id!(exchange)

    symbol = Bourse.Symbol.from_exchange_id(inst_id, exchange, :option)

    assert symbol =~ ~r"^[A-Z]+/USD:[A-Z]+-\d{6}-\d+-[CP]$",
           "expected a unified OKX option symbol, got #{inspect(symbol)}"

    assert Bourse.Symbol.to_exchange_id(symbol, exchange) == inst_id
  end

  @tag task_503: true
  @tag task_504: true
  test "international demo unified-margin derivatives use canonical symbols that resolve to instId" do
    assert {:ok, exchange} = Bourse.load_markets(demo_exchange(), timeout: @market_load_timeout_ms)

    options = Enum.filter(exchange.markets, &(&1.type == "option"))
    futures = Enum.filter(exchange.markets, &dated_future?/1)
    swaps = Enum.filter(exchange.markets, &(&1.type == "swap"))
    derivatives = options ++ futures ++ swaps
    unified_margin = Enum.filter(derivatives, &String.contains?(&1.id, "_UM"))
    unified_margin_swaps = Enum.filter(swaps, &String.contains?(&1.id, "_UM"))

    collisions =
      derivatives
      |> Enum.frequencies_by(& &1.symbol)
      |> Enum.filter(fn {_symbol, count} -> count > 1 end)

    assert options != []
    assert futures != []
    assert unified_margin_swaps != []

    assert unified_margin_swaps
           |> Map.new(&{&1.id, &1.symbol})
           |> Map.take(["EWJ-USD_UM-SWAP", "SLX-USD_UM-SWAP"]) ==
             %{"EWJ-USD_UM-SWAP" => "EWJ/USD:USD", "SLX-USD_UM-SWAP" => "SLX/USD:USD"}

    assert collisions == []
    assert Enum.all?(unified_margin, &(&1.symbol != &1.id))
    refute Enum.any?(unified_margin, &invalid_unified_margin_currency?/1)
    refute Enum.any?(unified_margin, &String.contains?(&1.symbol, "USD_UM"))
    assert Enum.all?(options, &Regex.match?(@canonical_option_symbol, &1.symbol))
    assert Enum.all?(futures, &Regex.match?(@canonical_future_symbol, &1.symbol))
    assert Enum.all?(unified_margin_swaps, &Regex.match?(@canonical_swap_symbol, &1.symbol))
    assert Enum.all?(unified_margin, &(Bourse.Symbol.to_exchange_id(&1.symbol, exchange) == &1.id))

    market = Enum.find(unified_margin, &String.contains?(&1.id, "-USD_UM-"))
    assert %Bourse.Market{} = market

    assert {:ok, %Bourse.Ticker{symbol: symbol, info: %{"instId" => inst_id}}} =
             Bourse.fetch_ticker(exchange, market.symbol)

    assert symbol == market.symbol
    assert inst_id == market.id
  end

  test "live put fetch_greeks returns a Black-Scholes delta" do
    exchange = build_exchange(:okx, sandbox: true, hostname: @okx_demo_host)
    inst_id = live_option_inst_id!(exchange)
    symbol = Bourse.Symbol.from_exchange_id(inst_id, exchange, :option)

    case Bourse.fetch_greeks(exchange, symbol) do
      {:ok, %Bourse.Greeks{} = greeks} ->
        assert Enum.all?([greeks.delta, greeks.gamma, greeks.vega, greeks.theta], &is_number/1),
               "fetch_greeks returned empty greeks for #{inst_id}: #{inspect(greeks)}"

        assert greeks.delta >= -1 and greeks.delta <= 0,
               "fetch_greeks returned a non-Black-Scholes put delta for #{inst_id}: #{inspect(greeks.delta)}"

        # The bound above is necessary but not sufficient: the venue's nearest
        # strike is usually far OTM, where the PA and BS families both round
        # towards zero and so both satisfy [-1, 0]. Pin the field family
        # structurally instead — that holds for whichever strike is live (C35).
        for {field, bs_key} <- [delta: "deltaBS", gamma: "gammaBS", vega: "vegaBS", theta: "thetaBS"] do
          {expected, ""} = Float.parse(Map.fetch!(greeks.info, bs_key))

          assert Map.fetch!(greeks, field) == expected,
                 "unified #{field} did not come from OKX's #{bs_key} for #{inst_id}: " <>
                   "#{inspect(Map.fetch!(greeks, field))} vs info #{inspect(Map.get(greeks.info, bs_key))} " <>
                   "(PA key #{inspect(Map.get(greeks.info, to_string(field)))})"
        end

      # The family is derived from the instId, so a mangled id surfaces as OKX's
      # own 51000 "Parameter instFamily error" — the defect task 270 closed.
      # Any other error is checked too: the message is the signal, not the shape.
      {:error, %Error{message: message}} ->
        refute message =~ "instFamily",
               "fetch_greeks failed on an instFamily error for #{inst_id}: #{message}"

      other ->
        flunk("Unexpected OKX fetch_greeks result: #{inspect(other)}")
    end
  end

  # Nearest-expiry BTC-USD option straight from the venue's own instrument list.
  defp live_option_inst_id!(exchange) do
    assert {:ok, %{body: %{"data" => instruments}}} =
             Bourse.Okx.public_get_public_instruments(exchange, %{
               "instType" => "OPTION",
               "instFamily" => "BTC-USD"
             })

    inst_id =
      instruments
      |> Enum.map(& &1["instId"])
      |> Enum.filter(&String.ends_with?(&1, "-P"))
      |> Enum.sort()
      |> List.first()

    assert is_binary(inst_id),
           "OKX returned no live BTC-USD puts to test against: #{inspect(instruments)}"

    inst_id
  end

  test "signed demo account balance parses per-currency free/used/total maps" do
    credentials = demo_credentials!()

    exchange =
      build_exchange(:okx,
        credentials: credentials,
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:ok, %Balance{} = balance} = Bourse.fetch_balance(exchange)
    funded_demo_balance_details!(balance)

    assert is_map(balance.total)
    assert map_size(balance.total) > 0
    assert Map.keys(balance.total) == Map.keys(balance.free)
    assert Enum.all?(balance.total, fn {currency, total} -> is_binary(currency) and is_number(total) end)
    assert is_map(balance.info)
  end

  test "signed international demo ledger and deposit requests pin accepted and rejected parameter shapes" do
    exchange = demo_exchange()

    assert {:ok, ledger} = Bourse.fetch_ledger(exchange, code: "USDT")
    assert is_list(ledger)

    assert {:error, %Error{type: :bad_request, code: "51000"}} =
             Bourse.fetch_ledger(exchange, instType: "NOPE")

    assert {:ok, deposits} = Bourse.fetch_deposits(exchange, code: "USDT", limit: 1)
    assert is_list(deposits)

    assert {:error, %Error{type: :bad_request, code: "51000"}} =
             Bourse.fetch_deposits(exchange, since: "BAD", limit: 1)
  end

  test "signed international demo position requests pin list, history, and singular schemas" do
    exchange = demo_exchange()
    until_ms = System.system_time(:millisecond)

    assert {:ok, positions} = Bourse.fetch_positions(exchange, symbols: ["BTC/USDT:USDT"])
    assert is_list(positions)

    assert {:error, %Error{type: :bad_request, code: "51000"}} =
             Bourse.fetch_positions(exchange, instType: "NOPE")

    assert {:ok, history} =
             Bourse.fetch_positions_history(exchange,
               symbols: ["BTC/USDT:USDT"],
               until: until_ms,
               limit: 1
             )

    assert is_list(history)
    assert Enum.all?(history, &(&1.timestamp < until_ms))

    assert {:error, %Error{type: :bad_request, code: "51000"}} =
             Bourse.fetch_positions_history(exchange, instType: "NOPE", until: until_ms, limit: 1)

    assert {:ok, position_rows} = Bourse.fetch_position(exchange, "BTC/USDT:USDT")
    assert is_list(position_rows)

    assert {:error, %Error{type: :bad_symbol, code: "51001"}} =
             Bourse.fetch_position(exchange, "NOPE/USDT:USDT")
  end

  # C-T427a/b — the live spot row carries `maker`/`taker` (negative = commission on OKX); we
  # surface the sign-normalized rate and keep the raw row in `info`.
  test "signed demo trading fee normalizes the venue's negative spot maker and taker rates" do
    exchange = demo_exchange()

    assert {:ok, %Bourse.TradingFee{symbol: "BTC/USDT", maker: maker, taker: taker, info: info}} =
             Bourse.fetch_trading_fee(exchange, "BTC/USDT")

    assert is_number(maker) and is_number(taker)
    assert maker > 0 and taker > 0
    assert maker == -Bourse.Safe.number(info["maker"])
    assert taker == -Bourse.Safe.number(info["taker"])
  end

  # C-T427b — the USDT-margined row blanks `maker`/`taker` and carries the rate on
  # `makerU`/`takerU`. This branch returned an all-nil-struct error before task 427.
  test "signed demo trading fee reads the USDT-margined carriers for a swap symbol" do
    exchange = demo_exchange()

    assert {:ok, %Bourse.TradingFee{symbol: "BTC/USDT:USDT", maker: maker, taker: taker, info: info}} =
             Bourse.fetch_trading_fee(exchange, "BTC/USDT:USDT")

    assert is_number(maker) and is_number(taker)
    assert maker > 0 and taker > 0
    assert info["maker"] in [nil, ""]
    assert maker == -Bourse.Safe.number(info["makerU"])
    assert taker == -Bourse.Safe.number(info["takerU"])
  end

  # Task 307 / C28 — pin the live balance availability branch against OKX's own row shape.
  # Spot mode (acctLv=1) returns details[].availEq as "" (not applicable per OKX Get
  # balance field matrix). Empty ≡ absent via Bourse.Safe, so free/used take availBal/frozenBal.
  # MUTATES SHARED STATE: drops the shared international demo account to spot mode
  # (acctLv 1). The on_exit callback restores the original level even if the test
  # process dies mid-cycle; it re-reads the live level first so a restore is only
  # issued when the account actually left its original mode.
  test "international demo spot-mode rows take the availEq-absent free/used branch" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:ok, %{body: %{"code" => "0", "data" => [%{"acctLv" => original_level} | _]}}} =
             Bourse.Okx.private_get_account_config(exchange, %{})

    on_exit(fn -> restore_account_level!(exchange, original_level) end)

    assert {:ok, %{body: %{"code" => "0"}}} =
             Bourse.Okx.private_post_account_set_account_level(exchange, %{"acctLv" => "1"})

    assert {:ok, %Balance{} = balance} = Bourse.fetch_balance(exchange)

    details = funded_demo_balance_details!(balance)

    observed_absent = Enum.filter(details, &availability_absent?(&1, "availEq"))

    assert observed_absent != [],
           "expected at least one international spot-mode row on the availEq-absent branch; got #{inspect(details)}"

    for detail <- observed_absent do
      ccy = detail["ccy"]
      free = Map.fetch!(balance.free, ccy)
      used = Map.fetch!(balance.used, ccy)
      total = Map.fetch!(balance.total, ccy)
      avail_bal = Bourse.Safe.number(detail["availBal"])
      frozen_bal = Bourse.Safe.number(detail["frozenBal"])
      eq = Bourse.Safe.number(detail["eq"] || detail["cashBal"])

      assert_in_delta free,
                      avail_bal,
                      1.0e-10,
                      "#{ccy}: free must come from availBal when availEq is empty (got #{free} vs availBal #{avail_bal})"

      assert_in_delta used,
                      frozen_bal,
                      1.0e-10,
                      "#{ccy}: used must map frozenBal when availEq is empty (got #{used} vs frozenBal #{frozen_bal})"

      assert_in_delta total, eq, 1.0e-10, "#{ccy}: total must map eq/cashBal (got #{total} vs #{eq})"
    end
  end

  # C28 — the availEq-PRESENT branch, pinned live at the account's standing
  # multi-currency margin mode (acctLv 3): free maps availEq, used is total − free.
  # Read-only; no account-level mutation.
  test "international demo multi-currency-margin rows take the availEq-present free/used branch" do
    exchange = demo_exchange()

    assert {:ok, %Balance{} = balance} = Bourse.fetch_balance(exchange)

    details = funded_demo_balance_details!(balance)

    observed_present = Enum.reject(details, &availability_absent?(&1, "availEq"))

    assert observed_present != [],
           "expected at least one row with availEq populated at the account's standing " <>
             "multi-currency margin mode (acctLv 3 attested 2026-07-23); a concurrent " <>
             "session may have stranded the shared demo account in spot mode. Got: #{inspect(details)}"

    for detail <- observed_present do
      ccy = detail["ccy"]
      free = Map.fetch!(balance.free, ccy)
      used = Map.fetch!(balance.used, ccy)
      total = Map.fetch!(balance.total, ccy)
      avail_eq = Bourse.Safe.number(detail["availEq"])
      eq = Bourse.Safe.number(detail["eq"] || detail["cashBal"])

      assert_in_delta free,
                      avail_eq,
                      1.0e-10,
                      "#{ccy}: free must come from availEq when present (got #{free} vs availEq #{avail_eq})"

      assert_in_delta used,
                      total - free,
                      1.0e-8,
                      "#{ccy}: used must be total − free when availEq is present (got #{used})"

      assert_in_delta total, eq, 1.0e-10, "#{ccy}: total must map eq/cashBal (got #{total} vs #{eq})"
    end
  end

  # Success-path pins for the account-level write builds, restored from the pins the
  # intl-demo migration deleted and retargeted at www.okx.com (live-verified 2026-07-23).
  # MUTATES SHARED STATE: changes the shared international demo account's leverage and
  # position mode; on_exit restores the originals even if the test process dies.
  test "international demo set_leverage and set_position_mode succeed with native lever/mgnMode/posMode" do
    exchange = demo_exchange()

    assert {:ok, %{body: %{"code" => "0", "data" => [%{"lever" => original_lever} | _]}}} =
             Bourse.Okx.private_get_account_leverage_info(exchange, %{
               "instId" => "BTC-USDT-SWAP",
               "mgnMode" => "cross"
             })

    assert {:ok, %{body: %{"code" => "0", "data" => [%{"posMode" => original_pos_mode} | _]}}} =
             Bourse.Okx.private_get_account_config(exchange, %{})

    on_exit(fn ->
      restore_leverage!(exchange, original_lever)
      restore_position_mode!(exchange, original_pos_mode)
    end)

    # Success family: lever ← leverage, mgnMode default cross, instId ← symbol.
    assert {:ok, %{"code" => "0", "data" => [lev_row | _]} = leverage_response} =
             Bourse.set_leverage(exchange, 5, "BTC/USDT:USDT")

    assert lev_row["lever"] == "5"
    assert lev_row["mgnMode"] == "cross"
    assert lev_row["instId"] == "BTC-USDT-SWAP"
    refute Map.has_key?(leverage_response, :status)
    refute Map.has_key?(leverage_response, :headers)

    # Success family: hedge_mode boolean → posMode long_short_mode | net_mode.
    assert {:ok, %{"code" => "0", "data" => [pos_row | _]} = position_mode_response} =
             Bourse.set_position_mode(exchange, false)

    assert pos_row["posMode"] == "net_mode"
    refute Map.has_key?(position_mode_response, :status)
    refute Map.has_key?(position_mode_response, :headers)
  end

  test "signed demo account reads retain account configuration and do not treat empty ledgers as semantic proof" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:ok, [%Bourse.Account{id: id, type: type} | _]} = Bourse.fetch_accounts(exchange)
    assert is_binary(id) and id != ""
    assert is_binary(type) and type != ""

    assert {:ok, ledger} = Bourse.fetch_ledger(exchange)
    assert is_list(ledger)

    # The international demo may have no trading-account bill rows. A green empty response
    # proves signed transport only; populated-row semantics stay pinned offline
    # and are tracked in the production-verification ledger. When the account DOES
    # supply a row, assert the C-T365a carve against it — that is the tier-1
    # evidence the ledger entry is waiting on, so never let it pass unchecked.
    for %Bourse.LedgerEntry{} = entry <- ledger do
      assert entry.id == entry.info["billId"]
      assert entry.currency == entry.info["ccy"]
      assert entry.amount == Bourse.Safe.number(entry.info["balChg"])
      assert entry.after == Bourse.Safe.number(entry.info["bal"])
      assert_in_delta entry.before, entry.after - entry.amount, 1.0e-6

      expected_direction =
        cond do
          entry.amount < 0 -> "out"
          entry.amount > 0 -> "in"
          true -> nil
        end

      assert entry.direction == expected_direction
      assert entry.status == "ok"

      case entry.fee do
        nil -> :ok
        %{"currency" => currency} -> assert currency == entry.info["ccy"]
      end
    end

    assert {:ok, [%Bourse.TransferEntry{} = transfer | _]} = Bourse.fetch_transfers(exchange)
    assert is_binary(transfer.currency)
    assert is_number(transfer.amount)
    assert transfer.amount == Bourse.Safe.number(transfer.info["balChg"])
    assert transfer.currency == transfer.info["ccy"]

    # fetch_transfers reads account bills. Internal-transfer rows carry OKX account
    # codes 6 (funding) / 18 (trading) and map via the authored enum (C-T365b).
    # Other bill types may carry from/to "0" (not an account id) — product leaves
    # from_account/to_account nil for unmapped codes (live 2026-07-29: from="0").
    # Assert the enum when present; never require from_account on every bill row.
    assert transfer.from_account == account_name(transfer.info["from"])
    assert transfer.to_account == account_name(transfer.info["to"])
  end

  test "invalid credentials return OKX authentication error" do
    credentials =
      Credentials.new!(
        api_key: "invalid-task-208",
        secret: "invalid-task-208",
        password: "invalid-task-208"
      )

    exchange =
      build_exchange(:okx,
        credentials: credentials,
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:error, %Error{type: :authentication_error}} = Bourse.fetch_balance(exchange)
    assert {:error, %Error{type: :authentication_error}} = Bourse.fetch_accounts(exchange)
    assert {:error, %Error{type: :authentication_error}} = Bourse.fetch_ledger(exchange)
  end

  test "a stale convert quote reaches OKX and returns a business error" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:error, %Error{raw: %{"code" => code}, message: message}} =
             Bourse.create_convert_trade(exchange, "stale-quote-id-308", "USDT", "BTC", 100)

    refute code in [nil, "", "0"]
    assert is_binary(message) and message != ""
  end

  # Task 342 — non-convert identifier_reference renames against the demo API.
  # Write-shaped calls use deliberate invalid params only; never a valid withdrawal.

  test "demo set_leverage surfaces the venue maximum-leverage error" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:error, %Error{code: code, raw: %{"code" => raw_code}}} =
             Bourse.set_leverage(exchange, 999, "BTC/USDT:USDT")

    assert to_string(code) == "59102"
    assert raw_code == "59102"
  end

  test "demo isolated position add_margin is reversed by reduce_margin" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:ok, positions} = Bourse.fetch_positions(exchange)

    position =
      Enum.find(positions, fn
        %Bourse.Position{symbol: symbol, margin_mode: "isolated"} when is_binary(symbol) -> true
        _ -> false
      end)

    case position do
      %Bourse.Position{symbol: symbol} ->
        assert {:ok, %MarginModification{type: "add"} = addition} =
                 Bourse.add_margin(exchange, symbol, @margin_adjustment_amount)

        try do
          assert addition.info
        after
          assert {:ok, %MarginModification{type: "reduce"} = reduction} =
                   Bourse.reduce_margin(exchange, symbol, @margin_adjustment_amount)

          assert reduction.info
        end

      nil ->
        assert Enum.all?(positions, fn
                 %Bourse.Position{margin_mode: "isolated"} -> false
                 _ -> true
               end),
               "an isolated position must run the add/reduce lifecycle: #{inspect(positions)}"
    end
  end

  test "demo funding id renames reach OKX validation (depId/wdId), not client raises" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:error, %Error{code: dep_code, message: dep_message}} =
             Bourse.fetch_deposit(exchange, "not-a-real-dep-id-task-342")

    assert to_string(dep_code) == "51000"
    assert dep_message =~ "depId"

    assert {:error, %Error{code: wd_code, message: wd_message}} =
             Bourse.fetch_withdrawal(exchange, "not-a-real-wd-id-task-342")

    assert to_string(wd_code) == "51000"
    assert wd_message =~ "wdId"
  end

  test "demo funding request builds reach their native read and withdrawal boundaries" do
    exchange = demo_exchange()

    assert {:ok, withdrawals} = Bourse.fetch_withdrawals(exchange, code: "USDT")
    assert is_list(withdrawals)

    assert {:ok, funding_history} = Bourse.fetch_funding_history(exchange, "BTC/USDT:USDT")
    assert is_list(funding_history)

    assert {:error, %Error{code: "50038", message: deposit_message}} =
             Bourse.fetch_deposit_address(exchange, "USDT")

    assert deposit_message =~ "unavailable in demo trading"

    assert {:error, %Error{code: "50120", message: withdraw_message}} =
             Bourse.withdraw(
               exchange,
               "USDT",
               5,
               "invalid-address-task-484-never-completes",
               network: "TRC20",
               fee: 1
             )

    assert withdraw_message =~ "doesn't have permission"
  end

  test "demo order id rename reaches OKX ordId validation" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    # fetch_order requires instId + ordId. A non-existent numeric-looking id that
    # cleared param shape returns 51603 (order does not exist) — not a missing-param
    # 51000 and not a client-side unresolved identifier_reference.
    assert {:error, %Error{code: code, message: message}} =
             Bourse.fetch_order(exchange, "635561007938625536", symbol: "BTC/USDT")

    assert to_string(code) == "51603"
    assert message =~ "Order does not exist" or message =~ "ordId" or message =~ "order"
  end

  test "signed international demo order reads accept instId, state, and algo ordType while invalid instType is rejected" do
    exchange = demo_exchange()

    assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: "BTC/USDT")
    assert is_list(open_orders)

    assert {:ok, closed_orders} = Bourse.fetch_closed_orders(exchange, symbol: "BTC/USDT")
    assert is_list(closed_orders)

    assert {:ok, canceled_orders} = Bourse.fetch_canceled_orders(exchange, symbol: "BTC/USDT")
    assert is_list(canceled_orders)

    assert {:ok, trailing_orders} =
             Bourse.fetch_open_orders(exchange, symbol: "BTC/USDT:USDT", trailing: true)

    assert is_list(trailing_orders)

    assert {:error, %Error{type: :bad_request, code: "51000"}} =
             Bourse.fetch_closed_orders(exchange, instType: "NOPE")
  end

  # Spot is the only instrument class where OKX can express a quote-denominated
  # cost (`tgtCcy`). The cost here is deliberately far below the venue minimum so
  # the request reaches business validation and can never fill.
  # Task 494: precision-gated create paths require a loaded market cache.
  test "international demo market order with cost reaches business validation without a filled order" do
    assert {:ok, exchange} = Bourse.load_markets(demo_exchange())

    case Bourse.create_market_buy_order_with_cost(exchange, "BTC/USDT", 0.0001) do
      {:error, %Error{raw: raw}} ->
        code = s_code(raw)

        assert code not in [nil, "0"], "expected a business validation code, got: #{inspect(raw)}"
        assert String.starts_with?(code, "51"), "unexpected market-with-cost result: #{inspect(raw)}"

      {:ok, %Bourse.Order{id: id}} when is_binary(id) and id != "" ->
        cleanup = Bourse.cancel_order(exchange, id, symbol: "BTC/USDT")
        flunk("market-with-cost unexpectedly rested; cleanup result: #{inspect(cleanup)}")

      other ->
        flunk("unexpected market-with-cost result: #{inspect(other)}")
    end
  end

  # Task 494 precision guard runs before the SPOT-only cost guard when markets are
  # unloaded; load markets so the deliberate derivatives refusal is the SPOT-only
  # ArgumentError (not "missing instrument precision").
  test "market order with cost refuses derivatives before any request reaches the venue" do
    assert {:ok, exchange} = Bourse.load_markets(demo_exchange())

    assert_raise ArgumentError, ~r/SPOT-only/, fn ->
      Bourse.create_market_buy_order_with_cost(exchange, "BTC/USDT:USDT", 1)
    end
  end

  test "demo order acknowledgement exposes the venue's populated per-operation error row" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    client_order_id = "t363#{System.unique_integer([:positive])}"

    assert {:error, %Error{code: "1", raw: %{"data" => [row | _]}}} =
             Bourse.Okx.private_post_trade_order(exchange, %{
               "instId" => "BTC-USDT",
               "tdMode" => "cash",
               "side" => "buy",
               "ordType" => "not-a-real-order-type",
               "sz" => @order_probe_size,
               "clOrdId" => client_order_id
             })

    assert row["clOrdId"] == client_order_id
    assert row["ordId"] == ""
    assert row["sCode"] == "51000"
    assert is_binary(row["sMsg"]) and row["sMsg"] != ""
  end

  # Task 385 — unified create_order / fetch_my_trades request builds on international demo.
  # Pre-fix: create_order → 50002 Incorrect json data format (batch-orders + unified keys);
  # fetch_my_trades → 50014 instType empty (fills-history). Post-fix: never those codes.

  test "demo unified create_order is never malformed-body 50002; cancel when resting" do
    assert {:ok, exchange} = Bourse.load_markets(demo_exchange())

    assert {:ok, %Bourse.Ticker{last: last}} = Bourse.fetch_ticker(exchange, "BTC/USDT")

    price =
      last
      |> Bourse.Safe.number()
      |> Kernel.*(@order_probe_price_ratio)
      |> Float.round(@order_probe_price_decimal_places)

    case Bourse.create_order(exchange, "BTC/USDT", "limit", "buy", 0.0001, price: price) do
      {:ok, %Bourse.Order{id: ord_id}} when is_binary(ord_id) and ord_id != "" ->
        # Venue accepted the place (code 0 + ordId). Always cancel in the same eval.
        _ = Bourse.cancel_order(exchange, ord_id, symbol: "BTC/USDT")

      {:error, %Error{code: code, message: message, raw: raw}} ->
        refute to_string(code) == "50002"
        refute is_binary(message) and String.contains?(message, "Incorrect json")
        refute s_code(raw) == "50002"
        refute to_string(code) == ""

        assert is_binary(message)

      other ->
        flunk("Unexpected create_order result: #{inspect(other)}")
    end

    # Swap path: same malformed-body ban; business errors (incl. 51155) allowed.
    case Bourse.create_order(exchange, "BTC/USDT:USDT", "limit", "buy", 1, price: price) do
      {:ok, %Bourse.Order{id: ord_id}} when is_binary(ord_id) and ord_id != "" ->
        _ = Bourse.cancel_order(exchange, ord_id, symbol: "BTC/USDT:USDT")

      {:error, %Error{code: code, message: message, raw: raw}} ->
        refute to_string(code) == "50002"
        refute is_binary(message) and String.contains?(message, "Incorrect json")
        refute s_code(raw) == "50002"

      other ->
        flunk("Unexpected swap create_order result: #{inspect(other)}")
    end
  end

  # Task 361 — the normal batch endpoints all require root JSON arrays. Every
  # call below is either non-mutating (unknown ids) or cleaned up immediately
  # when the international demo accepts a batch order.
  # Task 494: precision-gated create/edit paths require a loaded market cache.
  test "demo normal batch order families reach OKX business validation, not JSON-shape rejection" do
    assert {:ok, exchange} = Bourse.load_markets(demo_exchange())

    assert {:ok, %Bourse.Ticker{last: last}} = Bourse.fetch_ticker(exchange, "BTC/USDT")

    price =
      last
      |> Bourse.Safe.number()
      |> Kernel.*(@order_probe_price_ratio)
      |> Float.round(@order_probe_price_decimal_places)

    case Bourse.create_orders(exchange, [
           %{symbol: "BTC/USDT", type: "limit", side: "buy", amount: 0.0001, price: price},
           %{symbol: "BTC/USDT", type: "limit", side: "buy", amount: 0.0001, price: price}
         ]) do
      {:ok, orders} when is_list(orders) ->
        for %Bourse.Order{id: id} <- orders, is_binary(id) and id != "" do
          _ = Bourse.cancel_order(exchange, id, symbol: "BTC/USDT")
        end

      {:error, %Error{} = error} ->
        assert_normal_batch_business_error(error)

      other ->
        flunk("Unexpected create_orders result: #{inspect(other)}")
    end

    assert {:error, %Error{} = edit_error} =
             Bourse.edit_orders(exchange, [
               %{id: "999999999999999001", symbol: "BTC/USDT", amount: 0.0001, price: price}
             ])

    assert_normal_batch_business_error(edit_error)

    assert {:error, %Error{} = cancel_error} =
             Bourse.cancel_orders(exchange, ["999999999999999001"], symbol: "BTC/USDT")

    assert_normal_batch_business_error(cancel_error)
  end

  test "demo fetch_my_trades with symbol returns ok list and never 50014 instType-empty" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    # Empty is allowed (3-day fills window). A pre-fix fills-history path returned
    # 50014 "Parameter instType can not be empty".
    assert {:ok, trades} = Bourse.fetch_my_trades(exchange, symbol: "BTC/USDT")
    assert is_list(trades)
  end

  test "demo withdraw invalid address never completes a withdrawal" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    # Deliberate invalid destination. The request must leave this client and must not return
    # success — proving ccy/amt/toAddr were sent rather than raising pre-wire.
    assert {:error, %Error{code: code, message: message}} =
             Bourse.withdraw(exchange, "USDT", 1, "invalid-addr-task-342-not-a-wallet", %{})

    refute to_string(code) in [nil, "", "0"]
    assert is_binary(message) and message != ""
  end

  test "demo borrow_cross_margin sends ccy/amt and reaches amt validation" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    # Tiny amount is rejected as Parameter amt error once ccy is accepted. Without
    # the ccy rename OKX would name ccy first; without amt it would name amt as
    # required/missing rather than value-invalid.
    assert {:error, %Error{code: code, message: message}} =
             Bourse.borrow_cross_margin(exchange, "USDT", 0.00000001)

    assert to_string(code) == "51000"
    assert message =~ "amt"
  end

  test "demo fetch_cross_borrow_rate succeeds with ccy from unified code" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:ok, %Bourse.BorrowRate{currency: "USDT", rate: rate}} =
             Bourse.fetch_cross_borrow_rate(exchange, "USDT")

    assert is_number(rate) and rate > 0
  end

  # Task 362 — residual non-order account / convert request semantics on international demo.
  # Reads are success-path; mutating families use deliberate invalid params only
  # (never a valid irreversible transfer / withdrawal / key change).

  test "demo fetch_borrow_interest and fetch_margin_adjustment_history succeed as safe reads" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:ok, interest} = Bourse.fetch_borrow_interest(exchange, code: "USDT")
    assert is_list(interest)

    assert {:ok, adjustments} = Bourse.fetch_margin_adjustment_history(exchange, type: "add")
    assert is_list(adjustments)
  end

  test "demo fetch_convert_trade with unknown id reaches venue business error" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:error, %Error{code: code, message: message}} =
             Bourse.fetch_convert_trade(exchange, "not-a-real-clTReqId-task-362")

    refute to_string(code) in [nil, "", "0"]
    assert is_binary(message) and message != ""
  end

  test "demo fetch_transfer with unknown id reaches venue business error" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:error, %Error{code: code, message: message}} =
             Bourse.fetch_transfer(exchange, "0")

    refute to_string(code) in [nil, "", "0"]
    assert is_binary(message) and message != ""
  end

  test "demo algo amend and cancel return their specific missing-order business errors" do
    # Task 494: edit_order is precision-gated; load markets so the probe reaches
    # the venue missing-order codes rather than "missing instrument precision".
    assert {:ok, exchange} = Bourse.load_markets(demo_exchange())

    assert {:error, %Error{raw: %{"data" => [%{"sCode" => "51400"} | _]}}} =
             Bourse.cancel_order(exchange, @missing_algo_id, symbol: "BTC/USDT:USDT", stop: true)

    FixtureGateIsolation.isolate!("okx")

    assert {:error, %Error{raw: %{"data" => [%{"sCode" => "51527"} | _]}}} =
             Bourse.edit_order(exchange, @missing_algo_id, "BTC/USDT:USDT", "conditional", "buy",
               amount: @algo_probe_size,
               stopLossPrice: @algo_probe_trigger_price
             )
  end

  test "demo cancel-all-after rejects a malformed tag" do
    exchange = demo_exchange()

    assert {:error, %Error{code: "51000", message: message}} =
             Bourse.cancel_all_orders_after(exchange, 0, tag: "bad-tag")

    assert message =~ "tag"
  end

  test "demo transfer with zero amount is rejected without moving funds" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    # Zero/invalid amt proves ccy/from/to/amt reached the wire; never a positive
    # valid transfer that would move demo funds as a standing side effect.
    assert {:error, %Error{code: code, message: message}} =
             Bourse.transfer(exchange, "USDT", 0, "spot", "funding")

    refute to_string(code) in [nil, "", "0"]
    assert is_binary(message) and message != ""
  end

  # An unrecognised side must ride to the venue verbatim. Dropping it would send no
  # posSide at all, which a net-mode account accepts — silently closing a position the
  # caller never asked to close. Observed live 2026-07-18: 51000 "Parameter posSide error".
  test "demo close_position forwards an unrecognised side and OKX rejects it by name" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: @okx_demo_host
      )

    assert {:error, %Error{code: code, message: message}} =
             Bourse.close_position(exchange, "BTC/USDT:USDT", side: "shrot")

    assert to_string(code) == "51000"
    assert message =~ "posSide"
  end

  # Task 364 — populated position semantics need a real open row.
  test "international demo reversible swap position lifecycle pins populated position semantics" do
    exchange =
      build_exchange(:okx,
        credentials: demo_credentials!(),
        sandbox: true,
        hostname: "www.okx.com"
      )

    assert {:ok, exchange} = Bourse.load_markets(exchange)

    # Idempotent pre-cleanup if a prior run left a resting position.
    _ = Bourse.close_position(exchange, "BTC/USDT:USDT")

    assert {:ok, %Bourse.Order{id: order_id}} =
             Bourse.create_order(exchange, "BTC/USDT:USDT", "market", "buy", 1)

    assert is_binary(order_id) and order_id != ""

    try do
      assert {:ok, positions} = Bourse.fetch_positions(exchange, symbols: ["BTC/USDT:USDT"])
      assert is_list(positions)

      position =
        Enum.find(positions, fn
          %Bourse.Position{contracts: c} when is_number(c) and c != 0 -> true
          _ -> false
        end)

      assert %Bourse.Position{} = position
      assert position.symbol == "BTC/USDT:USDT"
      assert position.side in ["long", "short"]
      assert is_boolean(position.hedged)
      # net-mode live rows carry posSide=net → hedged false + side from signed pos
      if is_map(position.info) and position.info["posSide"] == "net" do
        assert position.hedged == false
      end

      assert is_number(position.contracts) and position.contracts != 0
      assert position.contract_size == 0.01
      assert is_number(position.notional) and position.notional > 0
      assert is_number(position.entry_price) and position.entry_price > 0
      assert is_number(position.mark_price) and position.mark_price > 0
      assert is_number(position.leverage) and position.leverage > 0
      assert position.margin_mode in ["cross", "isolated"]
      assert is_number(position.initial_margin)
      assert is_number(position.maintenance_margin)
      assert is_number(position.collateral)
      assert is_number(position.unrealized_pnl)
      assert is_number(position.percentage)
      assert is_number(position.initial_margin_percentage)
      assert is_number(position.maintenance_margin_percentage)
      assert is_number(position.margin_ratio)
      assert is_binary(position.id) or is_nil(position.id)
      assert_live_position_semantics(position)

      assert {:ok, %Bourse.Position{} = singular} = Bourse.fetch_position(exchange, "BTC/USDT:USDT")
      assert singular.symbol == "BTC/USDT:USDT"
      assert singular.side == position.side
      assert singular.contracts == position.contracts

      # Relevant error: unknown instrument is a typed bad_symbol, not a silent []
      assert {:error, %Error{type: :bad_symbol, code: code}} =
               Bourse.fetch_position(exchange, "NOTAREAL/USDT:USDT")

      assert to_string(code) == "51001"
    after
      _ = Bourse.close_position(exchange, "BTC/USDT:USDT")

      assert {:ok, cleaned} = Bourse.fetch_positions(exchange, symbols: ["BTC/USDT:USDT"])

      assert Enum.all?(cleaned, fn
               %Bourse.Position{contracts: c} when is_number(c) -> c == 0
               _ -> true
             end)
    end
  end

  # OKX transfer account codes (C-T365b). Unmapped codes (e.g. bill from="0") → nil.
  defp account_name("6"), do: "funding"
  defp account_name("18"), do: "trading"
  defp account_name(_other), do: nil

  defp assert_live_position_semantics(%Bourse.Position{info: info} = position) when is_map(info) do
    notional = Bourse.Safe.number(info["notionalUsd"])
    initial_margin = Bourse.Safe.number(info["imr"])
    maintenance_margin = Bourse.Safe.number(info["mmr"])
    unrealized_pnl = Bourse.Safe.number(info["upl"])
    pnl_ratio = Bourse.Safe.number(info["uplRatio"])

    assert is_number(notional) and notional > 0
    assert is_number(initial_margin)
    assert is_number(maintenance_margin)
    assert is_number(unrealized_pnl)
    assert is_number(pnl_ratio)

    assert_in_delta position.notional, notional, @position_money_tolerance
    assert_in_delta position.initial_margin, initial_margin, @position_money_tolerance
    assert_in_delta position.maintenance_margin, maintenance_margin, @position_money_tolerance
    assert_in_delta position.collateral, initial_margin + unrealized_pnl, @position_money_tolerance
    assert_in_delta position.unrealized_pnl, unrealized_pnl, @position_money_tolerance
    assert_in_delta position.percentage, pnl_ratio * @percentage_scale, @position_money_tolerance
    assert_in_delta position.initial_margin_percentage, initial_margin / notional, @position_ratio_tolerance
    assert_in_delta position.maintenance_margin_percentage, maintenance_margin / notional, @position_ratio_tolerance
    assert_in_delta position.margin_ratio, maintenance_margin / position.collateral, @position_ratio_tolerance

    assert position.entry_price == Bourse.Safe.number(info["avgPx"])
    assert position.mark_price == Bourse.Safe.number(info["markPx"])
    assert position.liquidation_price == Bourse.Safe.number(info["liqPx"])
    assert position.leverage == Bourse.Safe.number(info["lever"])
    assert position.margin_mode == info["mgnMode"]
    assert position.realized_pnl == Bourse.Safe.number(info["realizedPnl"])
  end

  defp demo_exchange do
    build_exchange(:okx, credentials: demo_credentials!(), sandbox: true, hostname: @okx_demo_host)
  end

  defp invalid_unified_margin_currency?(market) do
    Enum.any?([market.quote, market.settle], fn currency ->
      is_binary(currency) and String.contains?(currency, "USD_UM")
    end)
  end

  defp dated_future?(market) do
    market.type == "future" and is_binary(market.id) and market.id != "" and is_integer(market.expiry)
  end

  defp funded_demo_balance_details!(%Balance{info: info}) do
    details = get_in(info, ["data", Access.at(0), "details"])

    assert is_list(details),
           "OKX demo balance response did not contain data[0].details: #{inspect(info)}"

    if details == [] do
      flunk("""
      OKX international demo balance has no per-currency rows because the account used by
      OKX_INTL_API_KEY is unfunded (data[0].details is empty).

      Add virtual assets through the international demo endpoint:
        POST https://www.okx.com/api/v5/account/demo-adjust-balance
      Then re-run this test after /api/v5/account/balance returns at least one details row.

      Observed response: #{inspect(info)}
      """)
    end

    details
  end

  defp demo_credentials! do
    with api_key when is_binary(api_key) <- System.get_env("OKX_INTL_API_KEY"),
         secret when is_binary(secret) <- System.get_env("OKX_INTL_API_SECRET"),
         password when is_binary(password) <- System.get_env("OKX_INTL_PASSPHRASE"),
         {:ok, credentials} <- Credentials.new(api_key: api_key, secret: secret, password: password) do
      credentials
    else
      _ ->
        flunk("""
        Missing OKX demo credentials!

        Set these environment variables:
          export OKX_INTL_API_KEY="your_key"
          export OKX_INTL_API_SECRET="your_secret"
          export OKX_INTL_PASSPHRASE="your_passphrase"

        Create an international demo-trading key at www.okx.com.
        """)
    end
  end

  # Shared-state restore helpers: raise loudly when the shared international demo
  # account cannot be returned to its pre-test configuration.
  defp restore_account_level!(exchange, original_level) do
    case Bourse.Okx.private_get_account_config(exchange, %{}) do
      {:ok, %{body: %{"code" => "0", "data" => [%{"acctLv" => ^original_level} | _]}}} ->
        :ok

      {:ok, %{body: %{"code" => "0"}}} ->
        case Bourse.Okx.private_post_account_set_account_level(exchange, %{"acctLv" => original_level}) do
          {:ok, %{body: %{"code" => "0"}}} ->
            :ok

          other ->
            raise "failed to restore shared demo acctLv to #{original_level}: #{inspect(other)}"
        end

      other ->
        raise "failed to read shared demo acctLv for restore: #{inspect(other)}"
    end
  end

  defp restore_leverage!(exchange, original_lever) do
    case Bourse.set_leverage(exchange, String.to_integer(original_lever), "BTC/USDT:USDT") do
      {:ok, %{"code" => "0"}} ->
        :ok

      other ->
        raise "failed to restore shared demo BTC-USDT-SWAP leverage to #{original_lever}: #{inspect(other)}"
    end
  end

  defp restore_position_mode!(exchange, original_pos_mode) do
    case Bourse.set_position_mode(exchange, original_pos_mode == "long_short_mode") do
      {:ok, %{"code" => "0"}} ->
        :ok

      other ->
        raise "failed to restore shared demo posMode to #{original_pos_mode}: #{inspect(other)}"
    end
  end

  # Matches Bourse.Safe / when_keys_absent: missing or empty string is absent.
  defp availability_absent?(row, key) when is_map(row) and is_binary(key) do
    case Map.get(row, key) do
      nil -> true
      "" -> true
      _ -> false
    end
  end

  defp s_code(%{"data" => [%{"sCode" => code} | _]}) when is_binary(code), do: code
  defp s_code(%{"data" => [%{"sCode" => code} | _]}), do: to_string(code)
  defp s_code(_), do: nil

  defp assert_normal_batch_business_error(%Error{code: code, message: message, raw: raw}) do
    refute to_string(code) in ["", "0", "50002"]
    refute is_binary(message) and String.contains?(message, "Incorrect json")
    refute s_code(raw) == "50002"
  end
end
