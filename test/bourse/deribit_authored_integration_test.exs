defmodule Bourse.DeribitAuthoredIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Balance
  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.OptionProposal
  alias Bourse.Order
  alias Bourse.PortfolioRisk
  alias Bourse.Position
  alias Bourse.Test.FixtureGateIsolation

  @moduletag :integration
  @moduletag :network

  @deribit_testnet_url "https://test.deribit.com"
  @funding_history_window_ms 12 * 60 * 60 * 1000
  @milliseconds_per_hour 60 * 60 * 1000
  @ohlcv_window_ms 300_000
  @option_probe_price 0.0001
  @order_poll_attempts 20
  @order_poll_interval_ms 250

  setup do
    FixtureGateIsolation.isolate!("deribit")
    :ok
  end

  test "public ticker parses from live testnet" do
    exchange = build_exchange(:deribit, sandbox: true)

    assert {:ok, %Bourse.Ticker{symbol: "BTC/USD:BTC", last: last}} =
             Bourse.fetch_ticker(exchange, "BTC/USD:BTC")

    assert is_number(last)
  end

  test "liquid BTC option returns nested greeks from live testnet" do
    exchange = build_exchange(:deribit, sandbox: true)

    assert {:ok, markets} = Bourse.fetch_markets(exchange)
    market = Enum.find(markets, &(&1.type == "option" and &1.base == "BTC" and &1.active))
    assert %Bourse.Market{} = market

    assert {:ok, %Bourse.Greeks{} = greeks} = Bourse.fetch_greeks(exchange, market.symbol)

    assert Enum.all?([greeks.delta, greeks.gamma, greeks.rho, greeks.theta, greeks.vega], &is_number/1)
  end

  test "option proposal self-fetches fresh data and sizes a caller-priced inverse hedge" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)

    assert {:ok, markets} = Bourse.fetch_markets(exchange)
    assert {:ok, chain} = Bourse.fetch_option_chain(exchange, "BTC")

    option_data =
      Enum.find_value(chain, fn {symbol, data} ->
        if is_number(data.bid_price) or is_number(data.ask_price), do: {symbol, data}
      end)

    assert {option_symbol, _data} = option_data
    assert %Bourse.Market{} = option_market = Enum.find(markets, &(&1.symbol == option_symbol))
    option_amount = option_market.native_amount_step || option_market.precision["amount"]
    assert is_number(option_amount) and option_amount > 0

    assert {:ok, %Bourse.Ticker{} = inverse_ticker} = Bourse.fetch_ticker(exchange, "BTC/USD:BTC")
    inverse_price = inverse_ticker.last || inverse_ticker.bid || inverse_ticker.ask
    assert is_number(inverse_price) and inverse_price > 0

    proposal = %{
      legs: [
        %{
          id: "option",
          venue: "deribit",
          account: "main",
          symbol: option_symbol,
          side: "buy",
          amount: option_amount,
          type: "market",
          exchange: exchange
        }
      ],
      hedge_candidates: [
        %{
          id: "inverse-perp",
          venue: "deribit",
          account: "main",
          symbol: "BTC/USD:BTC",
          exchange: exchange,
          price: inverse_price
        }
      ],
      risk_targets: %{delta: 0.0},
      hard_limits: %{residual_delta_abs: 0.01},
      venue_policy: :same_only,
      freshness_assumptions: %{max_age_ms: 60_000},
      scopes: [PortfolioRisk.scope(exchange, "main")]
    }

    assert {:ok, %Bourse.OptionProposal.Result{status: :approved} = result} =
             OptionProposal.preflight(proposal)

    assert Enum.find(result.checks, &(&1.name == :quote)).status == :ok
    assert Enum.find(result.checks, &(&1.name == :greeks)).status == :ok
    assert %{feasible?: true, candidate_id: "inverse-perp", symbol: "BTC/USD:BTC"} = result.hedge
    assert is_number(result.hedge.quantity) and result.hedge.quantity > 0
  end

  @tag :dangerous
  test "option amount and contracts preserve base exposure while invalid granularity reaches Deribit" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    base = build_exchange(:deribit, credentials: credentials, sandbox: true)
    assert {:ok, exchange} = Bourse.load_markets(base)

    market =
      Enum.find(
        exchange.markets,
        &(&1.option and &1.base == "BTC" and &1.active and is_number(&1.native_amount_step))
      )

    assert %Bourse.Market{
             quantity_unit: "base",
             native_quantity_unit: "base",
             native_quantity_field: "amount",
             contract_size: contract_size,
             native_amount_step: amount_step,
             settle: settle,
             expiry: expiry,
             strike: strike,
             option_type: option_type
           } = market

    assert contract_size == Bourse.Safe.number(market.info["contract_size"])
    assert amount_step == Bourse.Safe.number(market.info["qty_tick_size"] || market.info["min_trade_amount"])
    assert is_binary(settle)
    assert is_integer(expiry)
    assert is_number(strike)
    assert option_type in ["call", "put"]

    assert {:ok, %Order{id: amount_order_id, amount: ^amount_step, filled: 0}} =
             Bourse.create_order(exchange, market.symbol, "limit", "buy", amount_step,
               price: @option_probe_price,
               postOnly: true,
               clientOrderId: "task397-amount-#{System.unique_integer([:positive])}"
             )

    try do
      assert {:ok, %Order{id: ^amount_order_id, amount: ^amount_step}} =
               Bourse.fetch_order(exchange, amount_order_id, symbol: market.symbol)
    after
      assert {:ok, %Order{id: ^amount_order_id}} =
               Bourse.cancel_order(exchange, amount_order_id, symbol: market.symbol)
    end

    contracts_label = "task397-contracts-#{System.unique_integer([:positive])}"

    assert {:ok, %{body: %{"result" => %{"order" => native_order}}}} =
             Bourse.Deribit.private_get_buy(exchange, %{
               "instrument_name" => market.id,
               "contracts" => amount_step / contract_size,
               "type" => "limit",
               "price" => @option_probe_price,
               "post_only" => true,
               "label" => contracts_label
             })

    native_order_id = native_order["order_id"]

    try do
      assert native_order["amount"] == amount_step
      assert native_order["contracts"] == amount_step / contract_size
    after
      assert {:ok, %Order{id: ^native_order_id}} =
               Bourse.cancel_order(exchange, native_order_id, symbol: market.symbol)
    end

    assert {:error, %Error{type: :bad_request, code: -32_602, message: message}} =
             Bourse.Deribit.private_get_buy(exchange, %{
               "instrument_name" => market.id,
               "amount" => amount_step / 2,
               "type" => "limit",
               "price" => @option_probe_price,
               "post_only" => true
             })

    assert message =~ ~s("param" => "amount")
    assert message =~ "multiple of the minimum order size"
  end

  @tag :dangerous
  test "marketable option speed bump reconciles through history and restores its zero baseline" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    base = build_exchange(:deribit, credentials: credentials, sandbox: true)
    assert {:ok, exchange} = Bourse.load_markets(base)
    assert {:ok, positions} = Bourse.fetch_positions(exchange, code: "ETH")
    assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, code: "ETH")
    assert {:ok, chain} = Bourse.fetch_option_chain(exchange, "ETH")

    {market, quote} = speed_bump_candidate!(exchange.markets, chain, positions, open_orders)
    amount = market.native_amount_step || market.precision["amount"]
    assert is_number(amount) and amount > 0
    assert position_size(positions, market.symbol) == 0
    refute Enum.any?(open_orders, &(&1.symbol == market.symbol))

    Process.put({__MODULE__, :task_511_order_ids}, [])

    try do
      sell_label = "task511-open-#{System.unique_integer([:positive])}"

      # Re-fetch the top of book immediately before placing — the option-chain
      # snapshot can go stale (live 2026-07-29: sell at chain bid returned
      # 10005 price_too_low). Prefer a fresh ticker bid; fall back to chain.
      sell_price = fresh_option_bid!(exchange, market.symbol, quote.bid_price)

      assert {:ok, %{body: %{"result" => %{"order" => sell_order, "trades" => sell_trades}}}} =
               Bourse.Deribit.private_get_sell(exchange, %{
                 "instrument_name" => market.id,
                 "amount" => amount,
                 "type" => "limit",
                 "price" => sell_price,
                 "label" => sell_label
               })

      remember_task_511_order!(sell_order)
      # Live 2026-07-29: marketable option limits often fill immediately
      # (`order_state: "filled"`) instead of resting as `speed_bumped`. Both
      # paths reconcile through history; accept either venue behaviour.
      assert sell_order["order_state"] in ["speed_bumped", "filled", "open"]
      assert is_list(sell_trades)

      if sell_order["order_state"] == "speed_bumped" do
        assert sell_order["filled_amount"] == 0
        assert sell_trades == []
      end

      assert %Order{status: "closed", filled: filled} =
               poll_filled_order!(exchange, sell_order["order_id"], market.symbol, amount)

      assert filled >= amount

      assert {:error, %Error{code: sell_cancel_code, message: sell_cancel_message}} =
               Bourse.cancel_order(exchange, sell_order["order_id"], symbol: market.symbol)

      assert to_string(sell_cancel_code) == "11044"
      assert sell_cancel_message =~ "not_open_order"

      assert {:ok, %Bourse.Ticker{ask: ask}} = Bourse.fetch_ticker(exchange, market.symbol)
      assert is_number(ask) and ask > 0
      buy_label = "task511-close-#{System.unique_integer([:positive])}"

      assert {:ok, %{body: %{"result" => %{"order" => buy_order, "trades" => buy_trades}}}} =
               Bourse.Deribit.private_get_buy(exchange, %{
                 "instrument_name" => market.id,
                 "amount" => amount,
                 "type" => "limit",
                 "price" => ask,
                 "reduce_only" => true,
                 "label" => buy_label
               })

      remember_task_511_order!(buy_order)
      assert buy_order["order_state"] in ["speed_bumped", "filled", "open"]
      assert is_list(buy_trades)

      if buy_order["order_state"] == "speed_bumped" do
        assert buy_order["filled_amount"] == 0
        assert buy_trades == []
      end

      assert %Order{status: "closed", filled: close_filled} =
               poll_filled_order!(exchange, buy_order["order_id"], market.symbol, amount)

      assert close_filled >= amount
      assert_position_size!(exchange, market.symbol, 0)
    after
      cleanup_task_511_option!(exchange, market)
      Process.delete({__MODULE__, :task_511_order_ids})
    end
  end

  test "USDC dated future and option symbols reach their live instruments" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)

    assert {:ok, markets} = Bourse.fetch_markets(exchange)

    future = Enum.find(markets, &(&1.type == "future" and &1.quote == "USDC" and &1.active))
    assert %Bourse.Market{symbol: future_symbol, id: future_id} = future
    assert future_symbol =~ "/"

    option = Enum.find(markets, &(&1.type == "option" and &1.quote == "USDC" and &1.active))
    assert %Bourse.Market{symbol: option_symbol, id: option_id} = option
    assert option_symbol =~ "/"

    assert {:ok, %Bourse.Ticker{symbol: ^future_symbol, info: future_info}} =
             Bourse.fetch_ticker(exchange, future_symbol)

    assert instrument_name(future_info) == future_id

    assert {:ok, %Bourse.Ticker{symbol: ^option_symbol, info: option_info}} =
             Bourse.fetch_ticker(exchange, option_symbol)

    assert instrument_name(option_info) == option_id
  end

  test "combo instruments intentionally retain native symbols" do
    exchange = build_exchange(:deribit, sandbox: true)

    assert {:ok, markets} = Bourse.fetch_markets(exchange)

    # Every no-slash symbol is a combo (carve C27) — not an unparsed dated instrument.
    raw_symbol_markets = Enum.reject(markets, &String.contains?(&1.symbol, "/"))
    assert raw_symbol_markets != []

    for market <- raw_symbol_markets do
      assert market.symbol == market.id
      assert get_in(market.info, ["kind"]) in ["future_combo", "option_combo"]
      assert Bourse.Symbol.to_exchange_id(market.symbol, exchange) == market.id
    end

    # No live symbol — combo or single-leg — may raise on the outbound conversion.
    for market <- markets do
      assert is_binary(Bourse.Symbol.to_exchange_id(market.symbol, exchange))
    end
  end

  test "deposit history populates transaction identity fields from both live records" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)

    assert {:ok, deposits} = Bourse.fetch_deposits(exchange, code: "BTC")
    assert length(deposits) >= 2

    for deposit <- Enum.take(deposits, 2) do
      assert %Bourse.Transaction{currency: "BTC", type: "deposit", status: "ok"} = deposit
      assert is_integer(deposit.timestamp)
      assert is_binary(deposit.datetime)
    end
  end

  test "funding rate cadence matches Deribit's live hourly history" do
    exchange = build_exchange(:deribit, sandbox: true)
    end_timestamp = System.system_time(:millisecond)
    start_timestamp = end_timestamp - @funding_history_window_ms

    assert {:ok, %Bourse.FundingRate{funding_rate: rate, interval: interval}} =
             Bourse.fetch_funding_rate(exchange, "BTC/USD:BTC")

    assert {:ok, [_first, _second | _] = history} =
             Bourse.fetch_funding_rate_history(exchange, "BTC/USD:BTC",
               since: start_timestamp,
               end_timestamp: end_timestamp
             )

    assert is_number(rate)
    assert interval == observed_funding_interval!(history)
    assert interval == "1h"
  end

  test "ticker collection requires scope and returns parsed symbol-keyed values" do
    exchange = build_exchange(:deribit, sandbox: true)

    assert {:error, %Error{type: :bad_request}} = Bourse.fetch_tickers(exchange)
    assert {:ok, tickers} = Bourse.fetch_tickers(exchange, code: "BTC")
    assert map_size(tickers) > 0
    assert Enum.all?(tickers, fn {symbol, ticker} -> is_binary(symbol) and match?(%Bourse.Ticker{}, ticker) end)
  end

  test "fetch_ohlcv returns live candles with authored timestamp params" do
    exchange = build_exchange(:deribit, sandbox: true)
    since = System.system_time(:millisecond) - @ohlcv_window_ms

    assert {:ok, [_ | _] = rows} =
             Bourse.fetch_ohlcv(exchange, "BTC/USD:BTC", "1m", since: since, limit: 2)

    # fetchOHLCV returns Bourse `number[][]` raw rows (see read_parse `do_parse("ohlcv", …)`
    # and the bybit authored sibling), not %Bourse.OHLCV{} structs. Reaching the parser at
    # all — three coerced rows instead of JSON-RPC -32602 — is the request-build proof.
    assert Enum.all?(rows, fn [timestamp, open, high, low, close, volume] ->
             is_integer(timestamp) and Enum.all?([open, high, low, close, volume], &is_number/1)
           end)
  end

  test "signed account summaries produce per-currency balances" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)

    assert {:ok, %Balance{} = balance} = Bourse.fetch_balance(exchange)
    assert map_size(balance.total) > 0
    assert Map.keys(balance.total) == Map.keys(balance.free)
    assert Enum.all?(balance.total, fn {currency, total} -> is_binary(currency) and is_number(total) end)

    # Task 241: used is maintenance_margin (already parsed) — never total-free.
    # Clobber produced huge negatives on cross-collateral rows (equity=0).
    assert is_map(balance.used)
    assert Map.keys(balance.used) == Map.keys(balance.total)

    summaries =
      case balance.info do
        %{"result" => %{"summaries" => rows}} when is_list(rows) -> rows
        %{"summaries" => rows} when is_list(rows) -> rows
        _ -> []
      end

    assert summaries != []

    for summary <- summaries do
      currency = summary["currency"]
      maintenance = summary["maintenance_margin"]
      assert is_binary(currency)
      assert is_number(balance.used[currency])
      assert balance.used[currency] >= 0

      if is_number(maintenance) do
        assert_in_delta balance.used[currency], maintenance, 1.0e-9
      end
    end
  end

  test "currency-shaped private reads normalize on live testnet" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)
    assert {:ok, exchange} = Bourse.load_markets(exchange)

    assert {:ok, %Bourse.DepositAddress{currency: "BTC", address: address, info: address_info}} =
             Bourse.fetch_deposit_address(exchange, "BTC")

    assert is_binary(address) and address != ""
    refute Map.has_key?(address_info, "jsonrpc")

    assert {:ok, transfers} = Bourse.fetch_transfers(exchange, code: "BTC")
    assert is_list(transfers)
  end

  test "undiscounted testnet account omits the optional extended fee schedule" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)
    assert {:ok, exchange} = Bourse.load_markets(exchange)

    assert {:ok, %{status: 200, body: %{"result" => summary}}} =
             Bourse.Deribit.private_get_get_account_summary(exchange, %{
               "currency" => "BTC",
               "extended" => true
             })

    assert summary["currency"] == "BTC"
    refute Map.has_key?(summary, "fee_group")
    refute Map.has_key?(summary, "fees")

    # `%{}` matches ANY map in a pattern, so compare by size. Once the account gains a discount,
    # `fees` arrives as Deribit's nested index/instrument/default object, which the C-T380a
    # carrier guard now surfaces as a loud error instead of an `{}` indistinguishable from the
    # undiscounted answer — that error is the signal the DIVERGE can be closed against a real body.
    case Bourse.fetch_trading_fees(exchange) do
      {:ok, fees} ->
        assert map_size(fees) == 0, "expected no schedule without a fee discount, got: #{inspect(fees)}"

      {:error, %Error{} = error} ->
        flunk("Deribit returned a fee schedule — carve C-T380a is closable: #{Exception.message(error)}")
    end
  end

  test "withdraw invalid address reaches Deribit's address validation" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)

    assert {:error, %Error{code: code, message: message}} =
             Bourse.withdraw(exchange, "BTC", 0.001, "invalid-address-for-task-237", %{})

    # 11090 invalid_addr proves the request cleared Deribit's param-presence check
    # (currency/amount/address all sent) and reached address validation.
    assert to_string(code) == "11090"
    assert message =~ "invalid_addr"
  end

  # Task 344 — residual request renames: instrument_name (by-instrument reads) and order_id.
  test "instrument_name-shaped open interest succeeds on live testnet" do
    exchange = build_exchange(:deribit, sandbox: true)

    # public/get_book_summary_by_instrument requires instrument_name. A green parse with
    # info.instrument_name == BTC-PERPETUAL proves the authored symbol→instrument_name
    # rename reached the wire (without it Deribit answers -32602 instrument_name required).
    assert {:ok, %Bourse.OpenInterest{symbol: "BTC/USD:BTC", info: info}} =
             Bourse.fetch_open_interest(exchange, "BTC/USD:BTC")

    assert instrument_name(info) == "BTC-PERPETUAL"
    assert is_number(info["open_interest"]) or is_number(info["open_interest_value"])
  end

  test "fetch_order_trades invalid id reaches Deribit's order_id validation" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)

    assert {:error, %Error{type: :bad_request, code: code, message: message}} =
             Bourse.fetch_order_trades(exchange, "not-a-real-order-id-task-344")

    # The `reason` discriminates rename-sent from rename-dropped; the code and the bare
    # "order_id" substring do not. Both rejections are -32602 on param order_id (observed
    # live 2026-07-17): a sent-but-invalid order_id reasons "invalid_order_id", while a
    # dropped rename reasons "value required". Asserting the reason is therefore what makes
    # this test fail if the authored id→order_id binding regresses.
    assert code == -32_602
    assert message =~ ~s("param" => "order_id")
    assert message =~ ~s("reason" => "invalid_order_id")
  end

  test "private read families return Deribit's authentication error for invalid credentials" do
    credentials = Credentials.new!(api_key: "invalid-task-170", secret: "invalid-task-170")
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)

    for request <- [
          &Bourse.fetch_balance/1,
          &Bourse.fetch_trading_fees/1,
          fn private_exchange -> Bourse.fetch_deposit_address(private_exchange, "BTC") end
        ] do
      assert {:error, %Error{type: :authentication_error, code: code}} = request.(exchange)
      assert to_string(code) == "13004"
    end
  end

  defp instrument_name(%{"instrument_name" => value}), do: value
  defp instrument_name(%{"result" => %{"instrument_name" => value}}), do: value

  defp observed_funding_interval!(rows) do
    gaps =
      rows
      |> Enum.map(& &1.timestamp)
      |> Enum.sort()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [left, right] -> right - left end)
      |> Enum.uniq()

    assert [gap_ms] = gaps
    assert rem(gap_ms, @milliseconds_per_hour) == 0
    "#{div(gap_ms, @milliseconds_per_hour)}h"
  end

  defp speed_bump_candidate!(markets, chain, positions, open_orders) do
    Enum.find_value(chain, fn {symbol, quote} ->
      market = Enum.find(markets, &(&1.symbol == symbol))

      if match?(%Bourse.Market{active: true, option: true}, market) and
           is_number(quote.bid_price) and quote.bid_price > 0 and
           is_number(quote.ask_price) and quote.ask_price > 0 and
           position_size(positions, symbol) == 0 and
           not Enum.any?(open_orders, &(&1.symbol == symbol)) do
        {market, quote}
      end
    end) ||
      flunk("Deribit testnet has no two-sided ETH option with a zero position/open-order baseline")
  end

  defp fresh_option_bid!(exchange, symbol, fallback_bid) do
    case Bourse.fetch_ticker(exchange, symbol) do
      {:ok, %Bourse.Ticker{bid: bid}} when is_number(bid) and bid > 0 -> bid
      _ -> fallback_bid
    end
  end

  # Deribit may report size as signed (negative = short) or as positive with side.
  defp position_size(positions, symbol) do
    case Enum.find(positions, &(&1.symbol == symbol and is_number(&1.contracts) and &1.contracts != 0)) do
      %Position{side: "long", contracts: contracts} -> abs(contracts)
      %Position{side: "short", contracts: contracts} when contracts < 0 -> contracts
      %Position{side: "short", contracts: contracts} -> -abs(contracts)
      %Position{contracts: contracts} -> contracts
      nil -> 0
    end
  end

  defp remember_task_511_order!(%{"order_id" => order_id}) when is_binary(order_id) do
    key = {__MODULE__, :task_511_order_ids}
    Process.put(key, [order_id | Process.get(key, [])])
  end

  defp remember_task_511_order!(order), do: flunk("Deribit order acknowledgement omitted order_id: #{inspect(order)}")

  defp poll_filled_order!(exchange, order_id, symbol, amount, attempts \\ @order_poll_attempts)

  defp poll_filled_order!(_exchange, order_id, _symbol, _amount, 0) do
    flunk("Deribit order #{order_id} did not reconcile to filled after #{@order_poll_attempts} attempts")
  end

  defp poll_filled_order!(exchange, order_id, symbol, amount, attempts) do
    case Bourse.fetch_order(exchange, order_id, symbol: symbol) do
      {:ok, %Order{status: "closed", filled: filled} = order} when is_number(filled) and filled >= amount ->
        order

      {:ok, %Order{status: status}} when status in ["open", nil] ->
        wait_then(fn -> poll_filled_order!(exchange, order_id, symbol, amount, attempts - 1) end)

      {:error, %Error{type: :order_not_found}} ->
        wait_then(fn -> poll_filled_order!(exchange, order_id, symbol, amount, attempts - 1) end)

      other ->
        flunk("Deribit order #{order_id} reconciliation failed: #{inspect(other)}")
    end
  end

  defp assert_position_size!(exchange, symbol, expected, attempts \\ @order_poll_attempts)

  defp assert_position_size!(_exchange, symbol, expected, 0) do
    flunk("Deribit position #{symbol} did not return to #{expected}")
  end

  defp assert_position_size!(exchange, symbol, expected, attempts) do
    case Bourse.fetch_positions(exchange, symbols: [symbol]) do
      {:ok, positions} ->
        observed = position_size(positions, symbol)
        reconcile_position_size(observed, exchange, symbol, expected, attempts)

      other ->
        flunk("Deribit position reconciliation failed for #{symbol}: #{inspect(other)}")
    end
  end

  defp reconcile_position_size(expected, _exchange, _symbol, expected, _attempts), do: :ok

  defp reconcile_position_size(_observed, exchange, symbol, expected, attempts) do
    wait_then(fn -> assert_position_size!(exchange, symbol, expected, attempts - 1) end)
  end

  defp cleanup_task_511_option!(exchange, market) do
    for order_id <- Process.get({__MODULE__, :task_511_order_ids}, []) do
      case Bourse.cancel_order(exchange, order_id, symbol: market.symbol) do
        {:ok, %Order{}} -> :ok
        {:error, %Error{code: code}} when code in [11_044, "11044"] -> :ok
        other -> flunk("Deribit task 511 cleanup cancel failed for #{order_id}: #{inspect(other)}")
      end
    end

    assert {:ok, positions} = Bourse.fetch_positions(exchange, symbols: [market.symbol])

    case position_size(positions, market.symbol) do
      0 ->
        :ok

      size when size < 0 ->
        assert_cleanup_order!(
          Bourse.Deribit.private_get_buy(exchange, %{
            "instrument_name" => market.id,
            "amount" => abs(size),
            "type" => "market",
            "reduce_only" => true,
            "label" => "task511-cleanup-#{System.unique_integer([:positive])}"
          })
        )

        assert_position_size!(exchange, market.symbol, 0)

      size when size > 0 ->
        assert_cleanup_order!(
          Bourse.Deribit.private_get_sell(exchange, %{
            "instrument_name" => market.id,
            "amount" => size,
            "type" => "market",
            "reduce_only" => true,
            "label" => "task511-cleanup-#{System.unique_integer([:positive])}"
          })
        )

        assert_position_size!(exchange, market.symbol, 0)
    end
  end

  defp assert_cleanup_order!({:ok, %{body: %{"result" => %{"order" => %{"order_id" => order_id}}}}})
       when is_binary(order_id), do: :ok

  defp assert_cleanup_order!(other), do: flunk("Deribit task 511 position cleanup failed: #{inspect(other)}")

  defp wait_then(fun) do
    receive do
    after
      @order_poll_interval_ms -> fun.()
    end
  end
end
