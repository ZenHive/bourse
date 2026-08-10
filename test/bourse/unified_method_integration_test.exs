# Task 39 — Unified-method integration probe.
#
# Generates per-exchange per-auth-class network tests covering the gap the
# three existing probes don't:
#
#   * Public symbol-required methods beyond T79's `fetch_ticker` /
#     `fetch_ohlcv` — `fetch_order_book`, `fetch_trades`,
#     `fetch_funding_rate`.
#   * Public zero-arg method `fetch_status` (not in T40's set).
#   * Private methods with **real** testnet credentials —
#     `fetch_balance`, `fetch_open_orders`, `fetch_my_trades`,
#     `fetch_positions`, `fetch_account`, `fetch_trading_fees`.
#     Venue-required symbols and account identifiers are supplied by the
#     generator; methods without requirements stay no-arg.
#     T67 covers the signing pipeline with bogus creds (expects an
#     auth-shaped error); T39 covers the same pipeline end-to-end and
#     expects a real success or a non-auth inconclusive error.
#
# Opt-in: module-level `:network` + `:unified_integration` + `:exchange_<id>`
# tags emitted from the generator.
#
#     mix test.json --quiet --only unified_integration
#     mix test.json --quiet --only unified_integration --only exchange_bybit
#
# Per-exchange private modules split at load time: exchanges with registered
# credentials emit the full per-method tests plus a runtime `setup_all`
# backstop; exchanges without registered credentials emit one flunk test with
# the required env-var exports and no `setup_all`. Public modules always emit
# their normal tests.
#
# `Module.create/3` with `quote ... unquote` is needed so the per-iteration
# `exchange_atom` is spliced in as a literal before `use/2` expansion.

defmodule Bourse.UnifiedMethodIntegrationProbeConfigTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Test.Generator.SymbolResolver
  alias Bourse.Test.Generator.UnifiedMethodIntegrationProbe

  @derive_demo_subaccount_id 144_422
  @fixture_account_index 42
  @lighter_auth_lifetime_seconds 300

  setup_all do
    {:ok, cases: UnifiedMethodIntegrationProbe.__collect_for_inspection__()}
  end

  test "collects public symbol fetch_order_book cases scoped to supported venues", %{cases: cases} do
    supported = MapSet.new(Bourse.Registry.exchanges())

    order_book_venues = for {:public_symbol, venue, :fetch_order_book, _extra} <- cases, do: venue

    assert order_book_venues != [], "expected at least one supported-venue fetch_order_book probe case"
    assert Enum.all?(order_book_venues, &MapSet.member?(supported, &1))
  end

  test "funding-rate cases use perpetual symbols from each venue index", %{cases: cases} do
    funding_cases =
      for {:public_symbol, venue, :fetch_funding_rate, [symbol]} <- cases,
          do: {venue, symbol}

    assert funding_cases != []

    Enum.each(funding_cases, fn {venue, symbol} ->
      market = SymbolResolver.markets(venue)[symbol]

      assert market["swap"] == true or market["type"] == "swap",
             "#{venue} funding-rate probe selected non-swap symbol #{symbol}"
    end)
  end

  test "DEX public probes prefer live perpetual symbols over stale bare-USDC aliases" do
    resolver = SymbolResolver

    assert resolver.pick_symbol("lighter") == "BTC/USDC:USDC"
    assert resolver.pick_symbol("hyperliquid") == "BTC/USDC:USDC"
  end

  test "private symbol-required probes receive a resolved venue symbol", %{cases: cases} do
    binance_symbol = SymbolResolver.pick_symbol("binance")
    lighter_symbol = SymbolResolver.pick_symbol("lighter")

    assert {:private, "binance", :fetch_my_trades, [[symbol: binance_symbol]]} in cases

    assert {:private, "lighter", :fetch_open_orders,
            [
              [
                symbol: lighter_symbol,
                account_index: {:credential, :uid},
                auth_deadline: {:unix_now_plus, @lighter_auth_lifetime_seconds}
              ]
            ]} in cases
  end

  test "private runtime identifiers resolve from credentials and current time", %{cases: cases} do
    {:private, "lighter", :fetch_open_orders, args} =
      Enum.find(cases, &match?({:private, "lighter", :fetch_open_orders, _args}, &1))

    credentials = Credentials.new!(api_key: "0", secret: "unused", uid: Integer.to_string(@fixture_account_index))
    exchange = Bourse.Exchange.new!(:lighter, credentials: credentials, sandbox: true)
    before_resolution = System.system_time(:second)

    assert [[symbol: "BTC/USDC:USDC", account_index: @fixture_account_index, auth_deadline: auth_deadline]] =
             UnifiedMethodIntegrationProbe.__resolve_private_args__(exchange, args)

    after_resolution = System.system_time(:second)

    assert auth_deadline in (before_resolution + @lighter_auth_lifetime_seconds)..(after_resolution +
                                                                                     @lighter_auth_lifetime_seconds)
  end

  test "Derive private probes receive the demo subaccount identifier", %{cases: cases} do
    for method <- [:fetch_my_trades, :fetch_open_orders, :fetch_positions] do
      assert {:private, "derive", method, [[subaccount_id: @derive_demo_subaccount_id]]} in cases
    end
  end

  test "private methods without identifier requirements remain no-arg", %{cases: cases} do
    assert {:private, "binance", :fetch_balance, []} in cases
    assert {:private, "derive", :fetch_balance, []} in cases
  end
end

for exchange_id <-
      Bourse.Test.Generator.OptIn.exchanges_for(
        Bourse.Registry.exchanges(),
        [:network, :unified_integration]
      ) do
  exchange_atom = String.to_atom(exchange_id)
  exchange_camel = Macro.camelize(exchange_id)

  for {auth, suffix} <- [{:public, PublicTest}, {:private, PrivateTest}] do
    module_name = Module.concat([Bourse.Probes.Unified, exchange_camel, suffix])

    Module.create(
      module_name,
      quote do
        use ExUnit.Case, async: false

        use Bourse.Test.Generator.UnifiedMethodIntegrationProbe,
          exchange: unquote(exchange_atom),
          auth: unquote(auth)
      end,
      Macro.Env.location(__ENV__)
    )
  end
end
