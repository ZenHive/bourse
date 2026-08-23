defmodule Bourse.OptionSurfaceIntegrationTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.InstrumentGreeks
  alias Bourse.OptionInstrument
  alias Bourse.Test.LiveGateIsolation
  alias Bourse.Unified.OptionSurface

  @moduletag :integration
  @moduletag :network

  @venues [
    {"deribit", [sandbox: true], "BTC"},
    {"okx", [sandbox: true], "BTC"},
    {"bybit", [sandbox: true], "BTC"},
    {"derive", [sandbox: true], "ZEC"}
  ]

  setup do
    for {venue, _, _} <- @venues, do: LiveGateIsolation.isolate!(venue)
    :ok
  end

  for {venue, exchange_opts, base} <- @venues do
    @venue venue
    @exchange_opts exchange_opts
    @base base

    # Per-venue tags exist so a runner that a venue geo-blocks can select the
    # venues it can actually reach. `--exclude` cannot do this: these tests also
    # carry the module's `:integration` tag, and an include wins over an exclude
    # on the same test.
    @tag String.to_atom("exchange_#{venue}")
    test "#{venue}: discover active options and join instrument greeks with delta sign" do
      {:ok, exchange} = Bourse.exchange(@venue, @exchange_opts)
      assert {:ok, markets} = Bourse.fetch_markets(exchange)
      exchange = %{exchange | markets: markets}

      assert {:ok, instruments} =
               OptionSurface.discover(exchange, base: @base, quotes: true)

      call = Enum.find(instruments, &(&1.option_type == "call"))
      put = Enum.find(instruments, &(&1.option_type == "put"))
      assert %OptionInstrument{} = call
      assert %OptionInstrument{} = put

      for sample <- [call, put] do
        assert is_binary(sample.symbol)
        assert is_binary(sample.id)
        assert is_number(sample.strike)
        assert is_integer(sample.expiry)
        assert is_binary(sample.settle)
        assert sample.option_type in ["call", "put"]
        assert is_integer(sample.observed_at)

        assert {:ok, %InstrumentGreeks{} = greeks} =
                 OptionSurface.instrument_greeks(exchange, sample.symbol)

        assert greeks.symbol == sample.symbol
        assert greeks.id == sample.id
        assert greeks.strike == sample.strike
        assert greeks.expiry == sample.expiry
        assert greeks.settle == sample.settle
        assert greeks.option_type == sample.option_type
        assert is_integer(greeks.observed_at)
        assert Map.has_key?(Map.from_struct(greeks), :source_timestamp)

        assert is_map(greeks.conventions)
        assert Map.has_key?(greeks.conventions, "delta")
        assert Map.has_key?(greeks.conventions, "rho")

        for {name, entry} <- greeks.conventions do
          assert is_boolean(entry["supported"])

          if entry["supported"] do
            assert is_binary(entry["native_field"]) and entry["native_field"] != ""
            assert is_binary(entry["denomination"])
            assert is_binary(entry["unit"])
            assert is_number(entry["bump_size"])

            if is_number(Map.get(greeks, String.to_existing_atom(name))) do
              assert get_in(greeks.info, String.split(entry["native_field"], "."))
            end
          else
            assert entry["native_field"] in [nil, ""]
            assert Map.get(greeks, String.to_existing_atom(name)) in [nil]
          end
        end

        assert is_number(greeks.delta)

        case greeks.option_type do
          "call" ->
            assert greeks.delta >= 0.0 and greeks.delta <= 1.0,
                   "#{@venue} call delta out of range: #{inspect(greeks.delta)} for #{greeks.symbol}"

          "put" ->
            assert greeks.delta >= -1.0 and greeks.delta <= 0.0,
                   "#{@venue} put delta out of range: #{inspect(greeks.delta)} for #{greeks.symbol}"
        end

        assert Enum.any?(
                 [greeks.bid_price, greeks.ask_price, greeks.mark_implied_volatility],
                 &is_number/1
               )
      end
    end

    @tag String.to_atom("exchange_#{venue}")
    test "#{venue}: missing symbol fails explicitly" do
      {:ok, exchange} = Bourse.exchange(@venue, @exchange_opts)
      assert {:ok, markets} = Bourse.fetch_markets(exchange)
      exchange = %{exchange | markets: markets}

      assert {:error, %Error{type: :bad_symbol}} =
               OptionSurface.instrument_greeks(exchange, "NOT-A-REAL-OPTION-SYMBOL")
    end
  end

  @tag :exchange_deribit
  test "stale max_age_ms fails when a venue publishes a source timestamp" do
    {:ok, exchange} = Bourse.exchange("deribit", sandbox: true)
    assert {:ok, markets} = Bourse.fetch_markets(exchange)
    exchange = %{exchange | markets: markets}
    assert {:ok, instruments} = OptionSurface.discover(exchange, base: "BTC", quotes: false)
    sample = hd(instruments)

    assert {:error, %Error{type: :operation_failed, message: message}} =
             OptionSurface.instrument_greeks(
               exchange,
               sample.symbol,
               observed_at: System.system_time(:millisecond) + 60_000,
               max_age_ms: 0
             )

    assert message =~ "stale option greeks" or message =~ "missing source timestamp"
  end
end
