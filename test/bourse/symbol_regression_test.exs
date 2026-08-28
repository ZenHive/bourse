defmodule Bourse.SymbolRegressionTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Symbol
  alias Bourse.Symbol.ParsedSymbol

  @alias_venues ~w(binance binancecoinm binanceusdm bybit deribit derive hyperliquid okx)
  @format %{separator: "", case: :upper}

  describe "currency aliases" do
    test "non-injective inversion names every colliding exchange code" do
      aliases = authored_aliases("hyperliquid")
      assert map_size(aliases) == 14

      assert_raise ArgumentError, ~r/"BTC" is mapped from \["UBTC", "XBT"\]/, fn ->
        Symbol.reverse_aliases(aliases)
      end
    end

    test "every injective authored venue alias map round-trips every key" do
      for venue <- @alias_venues -- ["hyperliquid"] do
        aliases = authored_aliases(venue)
        reversed = Symbol.reverse_aliases(aliases)

        for exchange_code <- Map.keys(aliases) do
          assert exchange_code ==
                   exchange_code
                   |> Symbol.apply_alias(aliases)
                   |> Symbol.apply_alias(reversed),
                 "#{venue} failed to round-trip #{exchange_code}"
        end
      end
    end

    test "normalize applies aliases only to split currency fields" do
      binance_aliases = authored_aliases("binance")
      okx_aliases = authored_aliases("okx")

      assert Symbol.normalize("AIXBTUSDT", @format, aliases: binance_aliases) == "AIXBT/USDT"
      assert Symbol.normalize("AVAXBTC", @format, aliases: binance_aliases) == "AVAX/BTC"

      assert Symbol.normalize("AEVO-USDT", %{separator: "-", case: :upper}, aliases: okx_aliases) ==
               "AEVO/USDT"

      assert Symbol.normalize("AERGO-USDT", %{separator: "-", case: :upper}, aliases: okx_aliases) ==
               "AERGO/USDT"

      assert Symbol.normalize("AERO-USDT", %{separator: "-", case: :upper}, aliases: okx_aliases) ==
               "AERO/USDT"
    end

    test "every authored alias key is inert inside a currency code and across a pair boundary" do
      for venue <- @alias_venues,
          aliases = authored_aliases(venue),
          alias_key <- Map.keys(aliases) do
        embedded_base = "A#{alias_key}Z"

        assert Symbol.normalize("#{embedded_base}USDT", @format, aliases: aliases) ==
                 "#{embedded_base}/USDT"

        assert Symbol.normalize("AX#{alias_key}BTC", @format, aliases: aliases) ==
                 "AX#{alias_key}/BTC"
      end
    end

    test "authored example ids never take a substring alias rewrite" do
      crossed =
        for venue <- @alias_venues,
            aliases = authored_aliases(venue),
            {id, format} <- authored_example_ids(venue),
            naive = naive_alias_rewrite(id, aliases),
            naive != id,
            do: {venue, id, format, aliases, naive}

      for {venue, id, format, aliases, naive} <- crossed do
        got = Symbol.normalize(id, format, aliases: aliases)
        naive_got = Symbol.normalize(naive, format, aliases: %{})
        per_currency = per_currency_alias(id, format, aliases)

        assert got == per_currency, "#{venue} #{id} left the per-currency path"

        if naive_got != per_currency do
          refute got == naive_got, "#{venue} #{id} kept a boundary-crossing rewrite"
        end
      end
    end
  end

  describe "dated futures" do
    test "parse_extended resolves a venue-native Bybit linear future id" do
      assert {:ok,
              %ParsedSymbol{
                base: "DOGE",
                quote: "USDT",
                settle: "USDT",
                expiry: "260828"
              }} = Symbol.parse_extended("DOGEUSDT-28AUG26")
    end

    test "parse_extended accepts a digit-prefixed Bybit linear future base" do
      assert {:ok, %ParsedSymbol{base: "1000PEPE", quote: "USDT", expiry: "260828"}} =
               Symbol.parse_extended("1000PEPEUSDT-28AUG26")
    end

    test "parse_extended does not treat a Deribit-native dated id as a Bybit linear future" do
      assert {:error, :invalid_format} = Symbol.parse_extended("BTC-7AUG26")
    end

    test "single-digit days preserve each venue's native width" do
      bybit = exchange("bybit", "", :future_ddmmmyy)
      deribit = exchange("deribit", "-", :future_ddmmmyy)

      assert Symbol.to_exchange_id("DOGE/USDT:USDT-260807", bybit) == "DOGEUSDT-07AUG26"
      assert Symbol.to_exchange_id("BTC/USD:BTC-260807", deribit) == "BTC-7AUG26"

      assert Symbol.from_exchange_id("DOGEUSDT-07AUG26", bybit, :future) == "DOGE/USDT:USDT-260807"
      assert Symbol.from_exchange_id("1000PEPEUSDT-28AUG26", bybit, :future) == "1000PEPE/USDT:USDT-260828"
      assert Symbol.from_exchange_id("BTC-7AUG26", deribit, :future) == "BTC/USD:BTC-260807"
    end
  end

  describe "date validation" do
    test "malformed input raises instead of returning plausible garbage" do
      for {input, source, target} <- [
            {"BANANA", :yyyymmdd, :yymmdd},
            {"nonsense", :yymmdd, :yyyymmdd},
            {"2026-03-27", :yyyymmdd, :yymmdd}
          ] do
        assert_raise ArgumentError, ~r/does not match declared source format/, fn ->
          Symbol.convert_date(input, source, target)
        end
      end
    end
  end

  test "from_exchange_id uses venue-authored currencies as quote candidates" do
    patterns = %{
      spot: %{pattern: :no_separator_upper, separator: "", case: :upper, date_format: nil, suffix: nil, prefix: nil}
    }

    with_try = %Exchange{
      id: "custom",
      name: "Custom",
      common_currencies: %{"TRY" => "TRY"},
      symbol_patterns: patterns
    }

    without_try = %Exchange{
      id: "custom",
      name: "Custom",
      common_currencies: %{},
      symbol_patterns: patterns
    }

    assert Symbol.from_exchange_id("BTCTRY", with_try, :spot) == "BTC/TRY"
    assert Symbol.from_exchange_id("BTCTRY", without_try, :spot) == "BTCTRY"
  end

  defp authored_aliases(venue) do
    venue
    |> authored_markets()
    |> get_in(["patterns", "currency_aliases"])
  end

  defp authored_example_ids(venue) do
    patterns = authored_markets(venue)["patterns"] || %{}

    Enum.flat_map(patterns, fn
      {"currency_aliases", _aliases} ->
        []

      {_kind, spec} when is_map(spec) ->
        format = %{
          separator: spec["separator"] || "",
          case: pattern_case(spec["case"])
        }

        for %{"id" => id} <- spec["examples"] || [], is_binary(id), do: {id, format}

      _other ->
        []
    end)
  end

  defp authored_markets(venue) do
    path = Path.expand("../../priv/venues/#{venue}/authored/markets.json", __DIR__)
    path |> File.read!() |> :json.decode()
  end

  defp pattern_case("lower"), do: :lower
  defp pattern_case(_other), do: :upper

  defp naive_alias_rewrite(id, aliases) do
    Enum.reduce(aliases, id, fn {from, to}, acc -> String.replace(acc, from, to) end)
  end

  defp per_currency_alias(id, format, aliases) do
    case id |> Symbol.normalize(format, aliases: %{}) |> String.split("/", parts: 2) do
      [base, quote] -> "#{Symbol.apply_alias(base, aliases)}/#{Symbol.apply_alias(quote, aliases)}"
      [unsplit] -> unsplit
    end
  end

  defp exchange(id, separator, pattern) do
    %Exchange{
      id: id,
      name: id,
      symbol_patterns: %{
        future: %{
          pattern: pattern,
          separator: separator,
          case: :upper,
          date_format: :ddmmmyy,
          suffix: nil,
          prefix: nil
        }
      }
    }
  end
end
