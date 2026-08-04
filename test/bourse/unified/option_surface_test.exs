defmodule Bourse.Unified.OptionSurfaceTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Greeks
  alias Bourse.Market
  alias Bourse.OptionInstrument
  alias Bourse.Unified.GreeksConventions
  alias Bourse.Unified.OptionSurface

  @call_symbol "BTC/USD:BTC-260131-100000-C"
  @put_symbol "BTC/USD:BTC-260131-100000-P"
  @observed_at 1_700_000_000_000

  setup do
    markets = [
      market(@call_symbol, "BTC-31JAN26-100000-C", "call", 100_000.0),
      market(@put_symbol, "BTC-31JAN26-100000-P", "put", 100_000.0)
    ]

    exchange =
      "deribit"
      |> Exchange.new!()
      |> Map.put(:markets, markets)

    {:ok, exchange: exchange, markets: markets}
  end

  test "discover returns active calls and puts with required identity", %{exchange: exchange} do
    assert {:ok, instruments} = OptionSurface.discover(exchange, quotes: false, observed_at: @observed_at)
    assert length(instruments) == 2

    assert Enum.all?(instruments, fn %OptionInstrument{} = instrument ->
             instrument.venue == "deribit" and
               is_binary(instrument.symbol) and
               is_binary(instrument.id) and
               is_number(instrument.strike) and
               is_integer(instrument.expiry) and
               is_binary(instrument.settle) and
               instrument.option_type in ["call", "put"] and
               instrument.observed_at == @observed_at
           end)
  end

  test "discover fails explicitly when a call or put has incomplete identity", %{exchange: exchange} do
    broken = "BTC/USDC:USDC-260131-1-C" |> market("BTC-1-C", "call", 1.0) |> Map.put(:strike, nil)
    exchange = %{exchange | markets: [broken | exchange.markets]}

    assert {:error, %Error{type: :bad_symbol, message: message}} =
             OptionSurface.discover(exchange, quotes: false, observed_at: @observed_at)

    assert message =~ "incomplete option identity"
    assert message =~ "strike"
  end

  test "discover excludes native combo rows because they are not calls or puts", %{exchange: exchange} do
    combo =
      @call_symbol
      |> market("BTC-PS-31JAN26-100000_110000", nil, nil)
      |> Map.put(:info, %{"kind" => "option_combo"})

    exchange = %{exchange | markets: [combo | exchange.markets]}
    assert {:ok, instruments} = OptionSurface.discover(exchange, quotes: false)
    assert Enum.map(instruments, & &1.id) == ["BTC-31JAN26-100000-C", "BTC-31JAN26-100000-P"]
  end

  test "discover rejects duplicate canonical symbols", %{exchange: exchange, markets: [call | _]} do
    duplicate = %{call | id: "BTC-31JAN26-100000-C-duplicate"}
    exchange = %{exchange | markets: [duplicate | exchange.markets]}

    assert {:error, %Error{type: :bad_symbol, message: message}} =
             OptionSurface.discover(exchange, quotes: false)

    assert message =~ "ambiguous option market symbols"
    assert message =~ @call_symbol
  end

  test "discover accepts a type-identified option and fails when no active options remain", %{exchange: exchange} do
    [call | _] = exchange.markets
    type_identified = %{call | option: false}

    assert {:ok, [%OptionInstrument{symbol: @call_symbol}]} =
             OptionSurface.discover(%{exchange | markets: [type_identified]}, quotes: false)

    inactive = %{type_identified | active: false}

    assert {:error, %Error{type: :bad_symbol, message: message}} =
             OptionSurface.discover(%{exchange | markets: [inactive]}, quotes: false)

    assert message =~ "no active option markets discovered"
  end

  test "first-class venues load authored greeks conventions" do
    for venue <- ["deribit", "okx", "bybit", "derive"] do
      exchange = Exchange.new!(venue)
      assert {:ok, table} = GreeksConventions.for_exchange(exchange)
      assert Map.has_key?(table, "delta")
      assert Map.has_key?(table, "rho")

      for name <- GreeksConventions.names() do
        entry = table[name]
        assert is_map(entry)
        assert is_boolean(entry["supported"])

        if entry["supported"] do
          assert is_binary(entry["native_field"]) and entry["native_field"] != ""
          assert is_binary(entry["denomination"])
          assert is_binary(entry["unit"])
          assert is_number(entry["bump_size"])
        else
          assert entry["native_field"] in [nil, ""]
        end
      end
    end
  end

  test "greeks conventions fail explicitly when missing or malformed" do
    assert {:error, %Error{type: :not_supported}} =
             GreeksConventions.for_exchange(%Exchange{id: "unknown", name: "Unknown", config: %{}})

    deribit = Exchange.new!("deribit")
    table = deribit.config["greeks_conventions"]

    assert {:error, %Error{type: :invalid_parameters, message: missing_message}} =
             GreeksConventions.for_exchange(%{deribit | config: %{"greeks_conventions" => Map.delete(table, "rho")}})

    assert missing_message =~ "missing entries"

    invalid_rho = put_in(table, ["rho"], %{"supported" => false, "native_field" => "greeks.rho"})

    assert {:error, %Error{type: :invalid_parameters, message: unsupported_message}} =
             GreeksConventions.for_exchange(%{deribit | config: %{"greeks_conventions" => invalid_rho}})

    assert unsupported_message =~ "must not name a native_field"
  end

  test "instrument_greeks rejects ambiguous market matches" do
    twin = market(@call_symbol, "BTC-31JAN26-100000-C-alt", "call", 100_000.0)

    exchange =
      "deribit"
      |> Exchange.new!()
      |> Map.put(:markets, [market(@call_symbol, "BTC-31JAN26-100000-C", "call", 100_000.0), twin])

    assert {:error, %Error{type: :bad_symbol, message: message}} =
             OptionSurface.instrument_greeks(exchange, @call_symbol, observed_at: @observed_at)

    assert message =~ "ambiguous option market match"
  end

  test "instrument_greeks fails loud on missing market", %{exchange: exchange} do
    assert {:error, %Error{type: :bad_symbol}} =
             OptionSurface.instrument_greeks(exchange, "NOPE", observed_at: @observed_at)
  end

  test "instrument_greeks fails on incomplete discovered identity", %{exchange: exchange} do
    [call | rest] = exchange.markets
    exchange = %{exchange | markets: [%{call | settle: nil} | rest]}

    assert {:error, %Error{type: :bad_symbol, message: message}} =
             OptionSurface.instrument_greeks(exchange, @call_symbol)

    assert message =~ "incomplete option identity"
    assert message =~ "settle"
  end

  test "instrument_greeks rejects missing or mismatched native response identity", %{exchange: exchange} do
    missing_stub = greeks_stub(@observed_at, instrument_name: nil)

    assert {:error, %Error{type: :operation_failed, message: missing_message}} =
             OptionSurface.instrument_greeks(
               exchange,
               @call_symbol,
               request_opts: [plug: {Req.Test, missing_stub}]
             )

    assert missing_message =~ "missing native instrument identity"

    mismatch_stub = greeks_stub(@observed_at, instrument_name: "ETH-31JAN26-100000-C")

    assert {:error, %Error{type: :operation_failed, message: mismatch_message}} =
             OptionSurface.instrument_greeks(
               exchange,
               @call_symbol,
               request_opts: [plug: {Req.Test, mismatch_stub}]
             )

    assert mismatch_message =~ "greeks native instrument mismatch"
  end

  test "instrument_greeks joins native values and keeps the response observation clock", %{exchange: exchange} do
    source_timestamp = System.system_time(:millisecond) - 1_000
    stub = greeks_stub(source_timestamp)

    assert {:ok, result} =
             OptionSurface.instrument_greeks(
               exchange,
               @call_symbol,
               request_opts: [plug: {Req.Test, stub}]
             )

    assert result.symbol == @call_symbol
    assert result.id == "BTC-31JAN26-100000-C"
    assert result.delta == 0.5
    assert result.rho == 0.1
    assert result.source_timestamp == source_timestamp
    assert result.observed_at >= source_timestamp
    assert result.conventions["delta"]["native_field"] == "greeks.delta"
    assert result.conventions["delta"]["value_present"]
  end

  test "stale source timestamps fail through the production path", %{exchange: exchange} do
    stub = greeks_stub(@observed_at - 60_000)

    assert {:error, %Error{type: :operation_failed, message: message}} =
             OptionSurface.instrument_greeks(
               exchange,
               @call_symbol,
               observed_at: @observed_at,
               max_age_ms: 1_000,
               request_opts: [plug: {Req.Test, stub}]
             )

    assert message =~ "stale option greeks"
  end

  test "missing timestamps fail and forward clock skew remains fresh", %{exchange: exchange} do
    missing_stub = greeks_stub(nil)

    assert {:error, %Error{type: :operation_failed, message: missing_message}} =
             OptionSurface.instrument_greeks(
               exchange,
               @call_symbol,
               observed_at: @observed_at,
               max_age_ms: 1_000,
               request_opts: [plug: {Req.Test, missing_stub}]
             )

    assert missing_message =~ "missing source timestamp"

    future_stub = greeks_stub(@observed_at + 1)

    assert {:ok, future_result} =
             OptionSurface.instrument_greeks(
               exchange,
               @call_symbol,
               observed_at: @observed_at,
               max_age_ms: 0,
               request_opts: [plug: {Req.Test, future_stub}]
             )

    assert future_result.source_timestamp == @observed_at + 1
    assert future_result.observed_at == @observed_at
  end

  test "unsupported Greeks cannot carry fabricated values", %{exchange: exchange} do
    conventions = put_in(exchange.config, ["greeks_conventions", "rho"], %{"supported" => false})
    exchange = %{exchange | config: conventions}
    stub = greeks_stub(@observed_at - 1)

    assert {:error, %Error{type: :operation_failed, message: message}} =
             OptionSurface.instrument_greeks(
               exchange,
               @call_symbol,
               observed_at: @observed_at,
               request_opts: [plug: {Req.Test, stub}]
             )

    assert message =~ "unsupported greek rho returned"
  end

  test "surface joins quote fields, native open interest and provenance", %{exchange: exchange} do
    stub = greeks_stub(@observed_at - 1)

    assert {:ok, [%{instrument: instrument, greeks: greeks}]} =
             OptionSurface.surface(
               exchange,
               quotes: false,
               limit: 1,
               observed_at: @observed_at,
               request_opts: [plug: {Req.Test, stub}]
             )

    assert instrument.symbol == greeks.symbol
    assert instrument.bid_price == 0.1
    assert instrument.ask_price == 0.2
    assert instrument.implied_volatility == 0.6
    assert instrument.open_interest == 12.5
    assert instrument.source_timestamp == @observed_at - 1
    assert instrument.observed_at == @observed_at
    assert get_in(instrument.info, ["greeks", "instrument_name"]) == "BTC-31JAN26-100000-C"
  end

  test "surface propagates an instrument Greeks failure", %{exchange: exchange} do
    stub = unique_stub("surface_error")
    Req.Test.stub(stub, &Req.Test.transport_error(&1, :timeout))

    assert {:error, %Error{type: :network_error}} =
             OptionSurface.surface(
               exchange,
               quotes: false,
               limit: 1,
               request_opts: [plug: {Req.Test, stub}]
             )
  end

  test "discover attaches option-chain fields and propagates transport errors", %{exchange: exchange} do
    quote_stub = option_chain_stub()

    assert {:ok, instruments} =
             OptionSurface.discover(
               exchange,
               observed_at: @observed_at,
               request_opts: [plug: {Req.Test, quote_stub}]
             )

    call = Enum.find(instruments, &(&1.symbol == @call_symbol))
    assert call.bid_price == 0.1
    assert call.ask_price == 0.2
    assert call.open_interest == 12.5
    assert call.observed_at == @observed_at

    error_stub = unique_stub("option_chain_error")
    Req.Test.stub(error_stub, &Req.Test.transport_error(&1, :timeout))

    assert {:error, %Error{type: :network_error}} =
             OptionSurface.discover(
               exchange,
               request_opts: [plug: {Req.Test, error_stub}]
             )
  end

  test "invalid request and freshness options fail explicitly", %{exchange: exchange} do
    assert {:error, %Error{type: :invalid_parameters, message: request_message}} =
             OptionSurface.discover(exchange, request_opts: :invalid)

    assert request_message =~ "request_opts must be"

    stub = greeks_stub(@observed_at - 1)

    assert {:error, %Error{type: :invalid_parameters, message: age_message}} =
             OptionSurface.instrument_greeks(
               exchange,
               @call_symbol,
               observed_at: @observed_at,
               max_age_ms: -1,
               request_opts: [plug: {Req.Test, stub}]
             )

    assert age_message =~ "max_age_ms must be a non-negative integer"
  end

  test "Greeks and OptionData carry observed_at as an additive local clock" do
    assert :observed_at in Map.keys(%Greeks{})
    assert :observed_at in Map.keys(%Bourse.OptionData{})
  end

  defp market(symbol, id, option_type, strike) do
    %Market{
      symbol: symbol,
      id: id,
      base: "BTC",
      quote: "USD",
      settle: "BTC",
      type: "option",
      option: true,
      active: true,
      strike: strike,
      expiry: 1_769_817_600_000,
      option_type: option_type,
      info: %{"id" => id}
    }
  end

  defp greeks_stub(timestamp, opts \\ []) do
    stub = unique_stub("greeks")
    instrument_name = Keyword.get(opts, :instrument_name, "BTC-31JAN26-100000-C")

    Req.Test.stub(stub, fn conn ->
      raw =
        %{
          "best_bid_price" => 0.1,
          "best_ask_price" => 0.2,
          "mark_iv" => 0.6,
          "open_interest" => 12.5,
          "underlying_price" => 100_000.0,
          "greeks" => %{"delta" => 0.5, "gamma" => 0.01, "vega" => 0.2, "theta" => -0.3, "rho" => 0.1}
        }
        |> maybe_put(
          "timestamp",
          timestamp
        )
        |> maybe_put("instrument_name", instrument_name)

      Req.Test.json(conn, rpc_result(raw))
    end)

    stub
  end

  defp option_chain_stub do
    stub = unique_stub("option_chain")

    Req.Test.stub(stub, fn conn ->
      rows = [
        %{
          "instrument_name" => "BTC-31JAN26-100000-C",
          "base_currency" => "BTC",
          "bid_price" => 0.1,
          "ask_price" => 0.2,
          "open_interest" => 12.5
        },
        %{
          "instrument_name" => "BTC-31JAN26-100000-P",
          "base_currency" => "BTC",
          "bid_price" => 0.2,
          "ask_price" => 0.3,
          "open_interest" => 8.0
        }
      ]

      Req.Test.json(conn, rpc_result(rows))
    end)

    stub
  end

  defp rpc_result(result), do: %{"jsonrpc" => "2.0", "result" => result, "testnet" => true}
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp unique_stub(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
