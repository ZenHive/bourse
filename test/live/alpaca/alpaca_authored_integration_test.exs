defmodule Bourse.AlpacaAuthoredIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2]

  alias Bourse.Credentials
  alias Bourse.Dispatch
  alias Bourse.Error
  alias Bourse.Order

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_alpaca

  @alpaca_credentials_url "https://app.alpaca.markets/signup"
  @paper_host "paper-api.alpaca.markets"
  @equity_symbol "GLD"
  @forex_pair "USDJPY"
  @one_day_timeframe "1d"
  @bar_limit 3
  @lookback_days 60
  @milliseconds_per_day 86_400_000
  @far_limit_price 1.0
  @order_amount 1
  @calendar_trade_date "2026-07-22"
  @calendar_settlement_date "2026-07-23"

  test "live stock bars and snapshot return parsed primary-market data" do
    exchange = market_data_exchange!()
    now_ms = System.system_time(:millisecond)
    since_ms = now_ms - @lookback_days * @milliseconds_per_day

    assert {:ok, candles} =
             Bourse.fetch_ohlcv(exchange, @equity_symbol, @one_day_timeframe,
               since: since_ms,
               limit: @bar_limit
             )

    assert length(candles) == @bar_limit
    assert Enum.all?(candles, fn [timestamp | _values] -> timestamp >= since_ms and timestamp <= now_ms end)

    [first | _rest] = candles
    assert [timestamp, open, high, low, close, volume] = first
    assert is_integer(timestamp)
    assert Enum.all?([open, high, low, close, volume], &is_number/1)
    assert low <= high

    assert {:ok, [_first | _rest]} =
             Bourse.fetch_ohlcv(exchange, @equity_symbol, @one_day_timeframe)

    assert {:ok, %Bourse.Ticker{symbol: @equity_symbol, last: last, bid: bid, ask: ask}} =
             Bourse.fetch_ticker(exchange, @equity_symbol)

    assert is_number(last)
    assert is_number(bid)
    assert is_number(ask)
    # Outside regular hours Alpaca IEX snapshots routinely print a one-sided
    # book (live 2026-07-29: GLD bid=369.11 ask=0). Only enforce bid<=ask when
    # both sides of the quote are present and positive.
    if bid > 0 and ask > 0 do
      assert bid <= ask
    end
  end

  test "live stock bars reject an inverted unified window with Alpaca's provider error" do
    exchange = market_data_exchange!()
    start_ms = System.system_time(:millisecond)
    end_ms = start_ms - @milliseconds_per_day

    assert {:error,
            %Error{
              type: :exchange_error,
              code: 400,
              http_status: 400,
              message: "end should not be before start"
            }} =
             Bourse.fetch_ohlcv(exchange, @equity_symbol, @one_day_timeframe,
               since: start_ms,
               until: end_ms
             )
  end

  test "live news and forex rate payloads expose their documented domain fields" do
    exchange = market_data_exchange!()

    assert {:ok, %{body: %{"news" => [%{"headline" => headline, "symbols" => symbols} | _]}}} =
             call_endpoint(exchange, "v1beta1/news", %{"symbols" => @equity_symbol, "limit" => 1})

    assert is_binary(headline) and headline != ""
    assert @equity_symbol in symbols

    # Live-observed: paper accounts carry no FX data entitlement — HTTP 403.
    # Message has drifted (`not authorized for FX data` → `forbidden: insufficient
    # grants` on 2026-07-29); pin the entitlement boundary, not a frozen string.
    assert {:error, %Error{type: :authentication_error, http_status: 403} = fx_error} =
             call_endpoint(exchange, "v1beta1/forex/latest/rates", %{"currency_pairs" => @forex_pair})

    assert is_binary(fx_error.message) and fx_error.message != ""
    assert fx_error.message =~ ~r/not authorized|insufficient grants|forbidden/i
  end

  # Live-observed 2026-07-19: Alpaca's data edge rejects bad keys with HTTP 401
  # and a `text/html` nginx body (no JSON error envelope). The HTML branch
  # classifies 401 as a credential rejection (task 439).
  test "invalid credentials produce Alpaca's recorded HTML 401 rejection" do
    credentials = Credentials.new!(api_key: "invalid-key", secret: "invalid-secret")
    exchange = build_exchange(:alpaca, credentials: credentials, sandbox: true)

    assert {:error, %Error{type: :authentication_error, code: 401}} =
             Bourse.fetch_ohlcv(exchange, @equity_symbol, @one_day_timeframe, limit: 1)
  end

  test "live stock trades return parsed public prints from the data host" do
    exchange = market_data_exchange!()

    assert {:ok, [%Bourse.Trade{} = trade | _rest]} = Bourse.fetch_trades(exchange, @equity_symbol, limit: 3)

    assert trade.symbol == @equity_symbol
    assert is_number(trade.price) and trade.price > 0
    assert is_number(trade.amount) and trade.amount > 0
    assert is_integer(trade.timestamp)
    assert is_binary(trade.datetime) and trade.datetime != ""
    assert is_binary(trade.id) and trade.id != ""
    assert is_nil(trade.side)
    assert is_map(trade.info)
    assert is_binary(trade.info["x"])
  end

  test "paper fill history returns a unified list from the paper host" do
    exchange = paper_exchange!()

    assert {:ok, trades} = Bourse.fetch_my_trades(exchange, limit: 5)
    assert is_list(trades)
    assert Enum.all?(trades, &match?(%Bourse.Trade{}, &1))
    assert Enum.all?(trades, &(is_binary(&1.id) and &1.id != ""))
    assert Enum.all?(trades, &(is_number(&1.price) and is_number(&1.amount)))
  end

  test "paper account, balance, positions, market clock, settlement, and equity asset semantics are live" do
    exchange = paper_exchange!()

    assert {:ok, %Bourse.Balance{} = balance} = Bourse.fetch_balance(exchange)
    assert is_number(balance.free["USD"])
    assert is_number(balance.used["USD"])
    assert is_number(balance.total["USD"])
    assert balance.info["currency"] == "USD"
    assert is_boolean(balance.info["shorting_enabled"])

    assert {:ok, positions} = Bourse.fetch_positions(exchange)
    assert is_list(positions)
    assert Enum.all?(positions, &match?(%Bourse.Position{}, &1))

    assert {:ok, orders} = Bourse.fetch_open_orders(exchange)
    assert is_list(orders)
    assert Enum.all?(orders, &match?(%Order{}, &1))

    assert {:ok, %{body: clock}} = call_endpoint(exchange, "v2/clock", %{})
    assert is_boolean(clock["is_open"])
    assert is_binary(clock["timestamp"])
    assert is_binary(clock["next_open"])
    assert is_binary(clock["next_close"])

    assert {:ok, %{body: [calendar_row]}} =
             call_endpoint(exchange, "v2/calendar", %{
               "start" => @calendar_trade_date,
               "end" => @calendar_trade_date
             })

    assert calendar_row["date"] == @calendar_trade_date
    assert calendar_row["settlement_date"] == @calendar_settlement_date
    assert calendar_row["open"] == "09:30"
    assert calendar_row["close"] == "16:00"

    assert {:ok, %{body: asset}} =
             call_endpoint(exchange, "v2/assets/{symbol_or_asset_id}", %{
               "symbol_or_asset_id" => @equity_symbol
             })

    assert asset["class"] == "us_equity"
    assert asset["tradable"] == true
    assert is_boolean(asset["fractionable"])
    assert is_boolean(asset["shortable"])
    assert asset["borrow_status"] in ["easy_to_borrow", "hard_to_borrow", "locate_required", "not_shortable"]
  end

  @tag :dangerous
  test "paper limit-order create, fetch, and cancel lifecycle preserves Alpaca semantics" do
    exchange = paper_exchange!()
    client_order_id = "bourse-task429-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    assert {:ok, %Order{id: id} = created} =
             Bourse.create_order(exchange, @equity_symbol, "limit", "buy", @order_amount,
               price: @far_limit_price,
               client_order_id: client_order_id,
               time_in_force: "day",
               extended_hours: false
             )

    assert is_binary(id) and id != ""

    try do
      assert created.client_order_id == client_order_id
      assert created.symbol == @equity_symbol
      assert created.type == "limit"
      assert created.side == "buy"
      assert created.amount == @order_amount
      assert created.price == @far_limit_price
      assert created.status == "open"
      assert created.time_in_force == "DAY"

      assert {:ok, %Order{id: ^id, symbol: @equity_symbol, status: "open"}} =
               Bourse.fetch_order(exchange, id)

      assert {:ok, %Order{id: ^id, status: "canceled"}} = Bourse.cancel_order(exchange, id)
    after
      cleanup_order!(exchange, id)
    end
  end

  @tag :dangerous
  test "paper API rejects an order missing qty and notional with its provider code" do
    exchange = paper_exchange!()

    assert {:error,
            %Error{
              type: :bad_request,
              code: 40_010_001,
              http_status: 422,
              message: "qty or notional is required"
            }} =
             call_endpoint(
               exchange,
               "v2/orders",
               %{
                 "symbol" => @equity_symbol,
                 "side" => "buy",
                 "type" => "limit",
                 "limit_price" => @far_limit_price,
                 "time_in_force" => "day"
               },
               :post
             )
  end

  defp market_data_exchange! do
    build_exchange(:alpaca, credentials: require_credentials!())
  end

  defp paper_exchange! do
    exchange = build_exchange(:alpaca, credentials: require_credentials!(), sandbox: true)
    paper_url = Dispatch.resolve_base_url(["trader", "private"], exchange.base_urls)

    if exchange.sandbox == true and URI.parse(paper_url).host == @paper_host do
      exchange
    else
      flunk("Alpaca paper-host guard failed: resolved #{inspect(paper_url)}")
    end
  end

  defp require_credentials! do
    api_key = System.get_env("ALPACA_API_KEY")
    secret = System.get_env("ALPACA_API_SECRET")

    if is_binary(api_key) and api_key != "" and is_binary(secret) and secret != "" do
      Credentials.new!(api_key: api_key, secret: secret)
    else
      flunk("""
      Missing Alpaca paper-account credentials!

      Set these environment variables and re-run:
        export ALPACA_API_KEY="your_key"
        export ALPACA_API_SECRET="your_secret"

      Get paper-account credentials at: #{@alpaca_credentials_url}
      """)
    end
  end

  defp call_endpoint(exchange, path, params, method \\ :get) do
    config = Enum.find(exchange.module.__endpoints__(), &(&1.path == path and &1.method == method))

    if is_nil(config) do
      flunk("Alpaca #{method} endpoint #{path} is absent from the authored spec")
    else
      Dispatch.call(exchange, config, params)
    end
  end

  defp cleanup_order!(exchange, id) do
    case Bourse.fetch_order(exchange, id) do
      {:ok, %Order{status: status}} when status in ["canceled", "closed"] ->
        :ok

      {:ok, %Order{}} ->
        assert {:ok, %Order{id: ^id, status: "canceled"}} = Bourse.cancel_order(exchange, id)

      {:error, %Error{type: :order_not_found}} ->
        :ok

      other ->
        flunk("Alpaca paper-order cleanup lookup failed for #{id}: #{inspect(other)}")
    end
  end
end
