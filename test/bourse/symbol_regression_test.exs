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

      assert Symbol.normalize("AEVO-USDT", %{separator: "-", case: :upper}, aliases: okx_aliases) ==
               "AEVO/USDT"
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

    test "single-digit days preserve each venue's native width" do
      bybit = exchange("bybit", "", :future_ddmmmyy)
      deribit = exchange("deribit", "-", :future_ddmmmyy)

      assert Symbol.to_exchange_id("DOGE/USDT:USDT-260807", bybit) == "DOGEUSDT-07AUG26"
      assert Symbol.to_exchange_id("BTC/USD:BTC-260807", deribit) == "BTC-7AUG26"
    end
  end

  describe "date validation" do
    test "malformed input raises instead of returning plausible garbage" do
      for {input, source, target} <- [
            {"BANANA", :yyyymmdd, :yymmdd},
            {"nonsense", :yymmdd, :yyyymmdd},
            {"2026-03-27", :yyyymmdd, :yymmdd}
          ] do
        assert_raise ArgumentError, fn -> Symbol.convert_date(input, source, target) end
      end
    end
  end

  test "from_exchange_id uses venue-authored currencies as quote candidates" do
    exchange = %Exchange{
      id: "custom",
      name: "Custom",
      common_currencies: %{"TRY" => "TRY"},
      symbol_patterns: %{
        spot: %{pattern: :no_separator_upper, separator: "", case: :upper, date_format: nil, suffix: nil, prefix: nil}
      }
    }

    assert Symbol.from_exchange_id("BTCTRY", exchange, :spot) == "BTC/TRY"
  end

  defp authored_aliases(venue) do
    path = Path.expand("../../priv/venues/#{venue}/authored/markets.json", __DIR__)
    path |> File.read!() |> :json.decode() |> get_in(["patterns", "currency_aliases"])
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
