# Task 188 — Standing live capability matrix for the consumer shortlist.
#
# Codifies COVERAGE.md as a gate, not a one-off Tidewave sweep: one live
# PUBLIC call per {venue, method}. Symbols come from each venue's live
# carved market list. Errors and wrong shapes flunk with venue + method + raw.
# No inconclusive-pass for malformation or wrong structs (task 183 folded in).
#
# Opt-in (excluded by default — offline suite untouched):
#
#     mix test.json --quiet --include capability_live \
#       test/bourse/public_api_live_test.exs
#
# Or with the bare tag filter:
#
#     mix test.json --quiet --only capability_live \
#       test/bourse/public_api_live_test.exs

defmodule Bourse.PublicApiLiveTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.FundingRate
  alias Bourse.Market
  alias Bourse.Ticker

  @moduletag :capability_live
  @moduletag :network

  # trading_dashboard consumer shortlist (COVERAGE.md).
  @venues [:binance, :bybit, :lighter, :deribit, :hyperliquid]

  # Public market-data spine cells. Credentialed account_read is out of scope
  # (task 184). Unsupported venue×method combos are not emitted (see COVERAGE "—").
  @methods [
    :fetch_markets,
    :fetch_ticker
  ]

  # Venues where has.fetchFundingRate is true and the live carve returns
  # %FundingRate{} (lighter/hyperliquid claim false / "—" in COVERAGE.md).
  @funding_rate_venues [:binance, :bybit, :deribit]

  # Prefer liquid BTC pairs first; fall back to any non-empty carved symbol.
  @preferred_symbols [
    "BTC/USDT",
    "ETH/USDT",
    "BTC/USDC",
    "BTC/USDT:USDT",
    "ETH/USDT:USDT",
    "BTC/USDC:USDC",
    "BTC/USD:BTC",
    "BTC-PERPETUAL"
  ]

  # ---------------------------------------------------------------------------
  # Live matrix — one test per {venue, method}
  # ---------------------------------------------------------------------------

  for venue <- @venues, method <- @methods do
    # Capture via @tag values (not module attributes): ExUnit freezes tags per
    # test at definition time; bare @venue/@method would collapse to the last
    # for-loop assignment for every cell.
    @tag venue: venue
    @tag method: method
    @tag String.to_atom("exchange_#{venue}")
    @tag String.to_atom("method_#{method}")
    test "#{venue} #{method} returns unified type with load-bearing fields", %{
      venue: venue,
      method: method
    } do
      run_matrix_cell(venue, method)
    end
  end

  for venue <- @funding_rate_venues do
    @tag venue: venue
    @tag method: :fetch_funding_rate
    @tag String.to_atom("exchange_#{venue}")
    @tag :method_fetch_funding_rate
    test "#{venue} fetch_funding_rate returns unified type with load-bearing fields", %{
      venue: venue
    } do
      run_matrix_cell(venue, :fetch_funding_rate)
    end
  end

  @tag :exchange_bybit
  @tag :method_fetch_markets
  test "bybit live market catalog preserves venue-native identities and type flags" do
    assert {:ok, markets} = Bourse.fetch_markets(Bourse.Exchange.new!(:bybit, sandbox: true))

    symbols = Enum.map(markets, & &1.symbol)
    assert length(symbols) == MapSet.size(MapSet.new(symbols))

    spot = Enum.find(markets, &(&1.id == "BTCUSDT" and &1.spot == true))
    assert %{symbol: "BTC/USDT", swap: false, future: false, contract: false, active: true} = spot
    assert %{linear: false, inverse: false, settle: nil, expiry: nil} = spot

    linear_perpetual = Enum.find(markets, &(&1.id == "BTCUSDT" and &1.info["contractType"] == "LinearPerpetual"))
    assert %{symbol: "BTC/USDT:USDT", swap: true, future: false, contract: true, active: true} = linear_perpetual
    assert %{linear: true, inverse: false, settle: "USDT", expiry: nil} = linear_perpetual

    inverse_perpetual = Enum.find(markets, &(&1.id == "BTCUSD" and &1.info["contractType"] == "InversePerpetual"))
    assert %{symbol: "BTC/USD:BTC", swap: true, future: false, contract: true, active: true} = inverse_perpetual
    assert %{linear: false, inverse: true, settle: "BTC", expiry: nil} = inverse_perpetual

    dated_future = Enum.find(markets, &(&1.future == true and is_integer(&1.expiry) and &1.expiry > 0))
    assert %{swap: false, contract: true, active: true, settle: settle} = dated_future
    assert dated_future.linear == true or dated_future.inverse == true
    assert is_binary(settle) and settle != ""

    assert String.ends_with?(
             dated_future.symbol,
             dated_future.expiry |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("-%y%m%d")
           )

    assert dated_future.expiry_datetime == Bourse.Timestamp.iso8601_from_ms(dated_future.expiry)
  end

  # ---------------------------------------------------------------------------
  # Negative control — prove the suite can fail (pinned, not hand-tried)
  # ---------------------------------------------------------------------------

  describe "negative control (Task 188)" do
    @tag :capability_live_negative
    test "wrong-shape success flunks with venue, method, and raw" do
      # Deliberate perturbation: {:ok, bare map} instead of %Ticker{}.
      raw = %{"last" => 1.0, "symbol" => "BTC/USDT"}

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_capability_cell!(:binance, :fetch_ticker, {:ok, raw}, expected_symbol: "BTC/USDT")
        end

      msg = Exception.message(error)
      assert msg =~ "binance"
      assert msg =~ "fetch_ticker"
      assert msg =~ "raw:"
      assert msg =~ inspect(raw)
    end

    @tag :capability_live_negative
    test "error result flunks with venue, method, and raw (no inconclusive pass)" do
      raw = %{"retCode" => 10_001, "retMsg" => "Illegal category"}

      err = %Error{
        type: :bad_request,
        code: 10_001,
        message: "Illegal category",
        exchange: "bybit",
        raw: raw
      }

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_capability_cell!(:bybit, :fetch_markets, {:error, err})
        end

      msg = Exception.message(error)
      assert msg =~ "bybit"
      assert msg =~ "fetch_markets"
      assert msg =~ "raw:"
      assert msg =~ "Illegal category"
    end

    @tag :capability_live_negative
    test "invalid-symbol live call flunks with venue, method, and raw" do
      exchange = Bourse.Exchange.new!(:bybit, sandbox: false)
      result = Bourse.fetch_ticker(exchange, "NOT_A_REAL_SYMBOL_ZZZ/USDT")

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_capability_cell!(:bybit, :fetch_ticker, result, expected_symbol: "NOT_A_REAL_SYMBOL_ZZZ/USDT")
        end

      msg = Exception.message(error)
      assert msg =~ "bybit"
      assert msg =~ "fetch_ticker"
      assert msg =~ "raw:"
    end
  end

  # ---------------------------------------------------------------------------
  # Matrix runner
  # ---------------------------------------------------------------------------

  defp run_matrix_cell(venue, :fetch_markets) do
    exchange = Bourse.Exchange.new!(venue, sandbox: false)
    result = Bourse.fetch_markets(exchange)
    assert_capability_cell!(venue, :fetch_markets, result)
  end

  defp run_matrix_cell(venue, :fetch_ticker) do
    exchange = Bourse.Exchange.new!(venue, sandbox: false)

    with {:ok, markets} when is_list(markets) and markets != [] <- Bourse.fetch_markets(exchange),
         symbol when is_binary(symbol) <- pick_symbol(markets) do
      # Prefer markets already threaded on the exchange (lighter market_id path).
      exchange =
        case Bourse.load_markets(exchange) do
          {:ok, loaded} -> loaded
          _ -> exchange
        end

      result = Bourse.fetch_ticker(exchange, symbol)
      assert_capability_cell!(venue, :fetch_ticker, result, expected_symbol: symbol)
    else
      {:error, _} = err ->
        assert_capability_cell!(venue, :fetch_markets, err)

      other ->
        flunk(cell_flunk_message(venue, :fetch_markets, other, "could not resolve a live carved symbol"))
    end
  end

  defp run_matrix_cell(venue, :fetch_funding_rate) do
    exchange = Bourse.Exchange.new!(venue, sandbox: false)

    if !Bourse.Exchange.has?(exchange, "fetchFundingRate") do
      flunk(
        cell_flunk_message(venue, :fetch_funding_rate, nil, "has fetchFundingRate is false — cell should not be emitted")
      )
    end

    with {:ok, markets} when is_list(markets) and markets != [] <- Bourse.fetch_markets(exchange),
         symbol when is_binary(symbol) <- pick_contract_symbol(markets) do
      exchange =
        case Bourse.load_markets(exchange) do
          {:ok, loaded} -> loaded
          _ -> exchange
        end

      result = Bourse.fetch_funding_rate(exchange, symbol)
      assert_capability_cell!(venue, :fetch_funding_rate, result, expected_symbol: symbol)
    else
      {:error, _} = err ->
        assert_capability_cell!(venue, :fetch_markets, err)

      other ->
        flunk(
          cell_flunk_message(
            venue,
            :fetch_funding_rate,
            other,
            "could not resolve a live carved contract symbol"
          )
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Flunk-on-non-struct assertions (no inconclusive pass)
  # ---------------------------------------------------------------------------

  defp assert_capability_cell!(venue, method, result, opts \\ [])

  defp assert_capability_cell!(venue, method, {:ok, body}, opts) do
    expected_symbol = Keyword.get(opts, :expected_symbol)
    assert_unified_body!(venue, method, body, expected_symbol)
  end

  defp assert_capability_cell!(venue, method, {:error, reason}, _opts) do
    flunk(cell_flunk_message(venue, method, reason, "expected {:ok, unified struct}, got error"))
  end

  defp assert_capability_cell!(venue, method, other, _opts) do
    flunk(cell_flunk_message(venue, method, other, "unexpected return shape"))
  end

  defp assert_unified_body!(venue, :fetch_markets, markets, _expected_symbol) when is_list(markets) do
    if markets == [] do
      flunk(cell_flunk_message(venue, :fetch_markets, markets, "empty markets list"))
    end

    Enum.each(markets, fn
      %Market{} = market ->
        assert_market_fields!(venue, market)

      other ->
        flunk(cell_flunk_message(venue, :fetch_markets, other, "list element is not %Market{}"))
    end)

    # Zero nil/empty symbols — COVERAGE keystone after task 195.
    bad =
      Enum.count(markets, fn
        %Market{symbol: s} when is_binary(s) and s != "" -> false
        _ -> true
      end)

    if bad > 0 do
      sample =
        markets
        |> Enum.filter(fn
          %Market{symbol: s} when is_binary(s) and s != "" -> false
          _ -> true
        end)
        |> Enum.take(3)

      flunk(
        cell_flunk_message(
          venue,
          :fetch_markets,
          sample,
          "#{bad}/#{length(markets)} markets missing non-empty symbol"
        )
      )
    end

    :ok
  end

  defp assert_unified_body!(venue, :fetch_markets, body, _expected_symbol) do
    flunk(cell_flunk_message(venue, :fetch_markets, body, "expected [%Market{}], got non-list"))
  end

  defp assert_unified_body!(venue, :fetch_ticker, %Ticker{} = ticker, expected_symbol) do
    assert_ticker_fields!(venue, ticker, expected_symbol)
    :ok
  end

  defp assert_unified_body!(venue, :fetch_ticker, body, _expected_symbol) do
    flunk(cell_flunk_message(venue, :fetch_ticker, body, "expected %Ticker{}, got wrong shape"))
  end

  defp assert_unified_body!(venue, :fetch_funding_rate, %FundingRate{} = fr, expected_symbol) do
    assert_funding_rate_fields!(venue, fr, expected_symbol)
    :ok
  end

  defp assert_unified_body!(venue, :fetch_funding_rate, body, _expected_symbol) do
    flunk(cell_flunk_message(venue, :fetch_funding_rate, body, "expected %FundingRate{}, got wrong shape"))
  end

  defp assert_market_fields!(venue, %Market{} = market) do
    if !(is_binary(market.symbol) and market.symbol != "") do
      flunk(cell_flunk_message(venue, :fetch_markets, market, "market.symbol missing/empty"))
    end

    # info is load-bearing provenance for consumer debugging.
    if !is_map(market.info) do
      flunk(cell_flunk_message(venue, :fetch_markets, market, "market.info must be a map"))
    end

    :ok
  end

  defp assert_ticker_fields!(venue, %Ticker{} = ticker, expected_symbol) do
    if !(is_binary(ticker.symbol) and ticker.symbol != "") do
      flunk(cell_flunk_message(venue, :fetch_ticker, ticker, "ticker.symbol missing/empty"))
    end

    if expected_symbol && ticker.symbol != expected_symbol do
      flunk(
        cell_flunk_message(
          venue,
          :fetch_ticker,
          ticker,
          "ticker.symbol #{inspect(ticker.symbol)} != expected #{inspect(expected_symbol)}"
        )
      )
    end

    if !numeric_price?(ticker.last) do
      flunk(cell_flunk_message(venue, :fetch_ticker, ticker, "ticker.last must be a numeric price"))
    end

    if !is_map(ticker.info) do
      flunk(cell_flunk_message(venue, :fetch_ticker, ticker, "ticker.info must be a map"))
    end

    :ok
  end

  defp assert_funding_rate_fields!(venue, %FundingRate{} = fr, expected_symbol) do
    if !(is_binary(fr.symbol) and fr.symbol != "") do
      flunk(cell_flunk_message(venue, :fetch_funding_rate, fr, "funding_rate.symbol missing/empty"))
    end

    if expected_symbol && fr.symbol != expected_symbol do
      flunk(
        cell_flunk_message(
          venue,
          :fetch_funding_rate,
          fr,
          "funding_rate.symbol #{inspect(fr.symbol)} != expected #{inspect(expected_symbol)}"
        )
      )
    end

    if !numeric_price?(fr.funding_rate) do
      flunk(
        cell_flunk_message(
          venue,
          :fetch_funding_rate,
          fr,
          "funding_rate.funding_rate must be numeric"
        )
      )
    end

    :ok
  end

  defp numeric_price?(value) when is_number(value), do: true

  defp numeric_price?(value) when is_binary(value) do
    case Float.parse(value) do
      {_num, ""} -> true
      _ -> false
    end
  end

  defp numeric_price?(_), do: false

  # ---------------------------------------------------------------------------
  # Symbol selection from live carved markets
  # ---------------------------------------------------------------------------

  defp pick_symbol(markets) when is_list(markets) do
    by_symbol =
      markets
      |> Enum.filter(fn
        %Market{symbol: s} when is_binary(s) and s != "" -> true
        _ -> false
      end)
      |> Map.new(&{&1.symbol, &1})

    Enum.find_value(@preferred_symbols, fn sym ->
      if Map.has_key?(by_symbol, sym), do: sym
    end) ||
      Enum.find_value(markets, fn
        %Market{symbol: s} when is_binary(s) and s != "" -> s
        _ -> nil
      end)
  end

  defp pick_contract_symbol(markets) when is_list(markets) do
    preferred_contracts =
      Enum.filter(@preferred_symbols, fn s ->
        String.contains?(s, ":") or String.contains?(s, "PERPETUAL")
      end)

    by_symbol =
      markets
      |> Enum.filter(fn
        %Market{symbol: s} when is_binary(s) and s != "" -> true
        _ -> false
      end)
      |> Map.new(&{&1.symbol, &1})

    Enum.find_value(preferred_contracts, fn sym ->
      if Map.has_key?(by_symbol, sym), do: sym
    end) ||
      Enum.find_value(markets, fn
        %Market{symbol: s, swap: true} when is_binary(s) and s != "" -> s
        %Market{symbol: s, contract: true} when is_binary(s) and s != "" -> s
        _ -> nil
      end)
  end

  # ---------------------------------------------------------------------------
  # Diagnostics
  # ---------------------------------------------------------------------------

  defp cell_flunk_message(venue, method, raw, reason) do
    """
    capability_live cell FAILED
      venue:  #{venue}
      method: #{method}
      reason: #{reason}
      raw: #{inspect(raw, pretty: true, limit: 50)}
    """
  end
end
