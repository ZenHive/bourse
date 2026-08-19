defmodule Bourse.SymbolTest do
  use ExUnit.Case, async: true

  alias Bourse.Symbol
  alias Bourse.Symbol.Error
  alias Bourse.Symbol.ParsedSymbol
  alias Bourse.Unified.ReadParse

  # ===========================================================================
  # parse/1
  # ===========================================================================

  describe "parse/1" do
    test "parses simple spot symbol" do
      assert {:ok, %{base: "BTC", quote: "USDT", settle: nil}} = Symbol.parse("BTC/USDT")
    end

    test "parses symbol with settle currency" do
      assert {:ok, %{base: "BTC", quote: "USDT", settle: "USDT"}} = Symbol.parse("BTC/USDT:USDT")
    end

    test "parses inverse perpetual" do
      assert {:ok, %{base: "BTC", quote: "USD", settle: "BTC"}} = Symbol.parse("BTC/USD:BTC")
    end

    test "returns error for missing slash" do
      assert {:error, :invalid_format} = Symbol.parse("BTCUSDT")
    end

    test "returns error for empty base" do
      assert {:error, :invalid_format} = Symbol.parse("/USDT")
    end

    test "returns error for empty quote" do
      assert {:error, :invalid_format} = Symbol.parse("BTC/")
    end

    test "returns error for multiple colons" do
      assert {:error, :invalid_format} = Symbol.parse("BTC/USDT:USDT:extra")
    end
  end

  # ===========================================================================
  # parse!/1
  # ===========================================================================

  describe "parse!/1" do
    test "returns parsed symbol on success" do
      assert %{base: "ETH", quote: "BTC"} = Symbol.parse!("ETH/BTC")
    end

    test "raises on invalid format" do
      assert_raise Error, ~r/Invalid symbol format/, fn ->
        Symbol.parse!("INVALID")
      end
    end
  end

  # ===========================================================================
  # parse_extended/1
  # ===========================================================================

  describe "parse_extended/1" do
    test "parses simple spot into ParsedSymbol" do
      assert {:ok, %ParsedSymbol{} = parsed} = Symbol.parse_extended("BTC/USDT")
      assert parsed.base == "BTC"
      assert parsed.quote == "USDT"
      assert parsed.settle == nil
      assert parsed.expiry == nil
      assert parsed.strike == nil
      assert parsed.option_type == nil
    end

    test "parses perpetual swap" do
      assert {:ok, %ParsedSymbol{} = parsed} = Symbol.parse_extended("BTC/USDT:USDT")
      assert parsed.settle == "USDT"
      assert parsed.expiry == nil
    end

    test "parses future with expiry" do
      assert {:ok, %ParsedSymbol{} = parsed} = Symbol.parse_extended("BTC/USDT:USDT-260327")
      assert parsed.settle == "USDT"
      assert parsed.expiry == "260327"
      assert parsed.strike == nil
    end

    test "parses option with all fields" do
      assert {:ok,
              %ParsedSymbol{
                base: "BTC",
                quote: "USD",
                settle: "BTC",
                expiry: "260112",
                strike: "84000",
                option_type: "C"
              }} = Symbol.parse_extended("BTC/USD:BTC-260112-84000-C")
    end

    test "parses put option" do
      assert {:ok, %ParsedSymbol{} = parsed} = Symbol.parse_extended("ETH/USD:ETH-260612-5000-P")
      assert parsed.option_type == "P"
      assert parsed.strike == "5000"
    end

    test "supports map-pattern matching on the struct" do
      assert {:ok, %{base: "BTC", quote: "USDT", settle: "USDT"}} =
               Symbol.parse_extended("BTC/USDT:USDT")
    end

    test "returns error for invalid format" do
      assert {:error, :invalid_format} = Symbol.parse_extended("INVALID")
    end

    test "returns error for wrong number of derivative parts" do
      # 3 parts after settle (missing option_type)
      assert {:error, :invalid_format} = Symbol.parse_extended("BTC/USD:BTC-260112-84000")
    end
  end

  # ===========================================================================
  # build/2-3
  # ===========================================================================

  describe "build/2-3" do
    test "builds spot symbol" do
      assert "BTC/USDT" = Symbol.build("BTC", "USDT")
    end

    test "builds with settle currency" do
      assert "BTC/USD:BTC" = Symbol.build("BTC", "USD", "BTC")
    end

    test "nil settle omits colon" do
      assert "ETH/BTC" = Symbol.build("ETH", "BTC", nil)
    end

    test "roundtrips with parse" do
      symbol = "BTC/USDT:USDT"
      {:ok, parsed} = Symbol.parse(symbol)
      assert symbol == Symbol.build(parsed.base, parsed.quote, parsed.settle)
    end
  end

  # ===========================================================================
  # normalize/3
  # ===========================================================================

  describe "normalize/3" do
    test "normalizes no-separator uppercase (Binance)" do
      format = %{separator: "", case: :upper}
      assert "BTC/USDT" = Symbol.normalize("BTCUSDT", format)
    end

    test "normalizes dash separator (Coinbase)" do
      format = %{separator: "-", case: :upper}
      assert "BTC/USD" = Symbol.normalize("BTC-USD", format)
    end

    test "normalizes underscore separator (Gate.io)" do
      format = %{separator: "_", case: :upper}
      assert "BTC/USDT" = Symbol.normalize("BTC_USDT", format)
    end

    test "normalizes lowercase no-separator (Bitstamp)" do
      format = %{separator: "", case: :lower}
      assert "BTC/USD" = Symbol.normalize("btcusd", format)
    end

    test "passes through already-normalized symbol" do
      format = %{separator: "/", case: :upper}
      assert "BTC/USDT" = Symbol.normalize("BTC/USDT", format)
    end

    test "returns original when no quote currency found" do
      format = %{separator: "", case: :upper}
      assert "XYZABC" = Symbol.normalize("XYZABC", format)
    end

    test "applies currency aliases" do
      format = %{separator: "", case: :upper}
      aliases = %{"XBT" => "BTC"}
      assert "BTC/USD" = Symbol.normalize("XBTUSD", format, aliases: aliases)
    end

    test "handles USDT vs USD longest-match" do
      format = %{separator: "", case: :upper}
      assert "BTC/USDT" = Symbol.normalize("BTCUSDT", format)
      assert "BTC/USD" = Symbol.normalize("BTCUSD", format)
    end

    test "handles FDUSD (longest quote currency)" do
      format = %{separator: "", case: :upper}
      assert "BTC/FDUSD" = Symbol.normalize("BTCFDUSD", format)
    end

    test "returns original when base would be empty" do
      format = %{separator: "", case: :upper}
      # "USDT" alone — base would be empty
      assert "USDT" = Symbol.normalize("USDT", format)
    end

    test "custom quote_currencies option works" do
      format = %{separator: "", case: :upper}
      # TRY is not in defaults, so without option it returns unchanged
      assert "BTCTRY" = Symbol.normalize("BTCTRY", format)
      # With custom quote currencies, it splits correctly
      assert "BTC/TRY" = Symbol.normalize("BTCTRY", format, quote_currencies: ["TRY"])
    end

    test "custom quote_currencies merges with defaults" do
      format = %{separator: "", case: :upper}
      # USDT is in defaults, TRY is custom — both should work
      assert "BTC/USDT" = Symbol.normalize("BTCUSDT", format, quote_currencies: ["TRY"])
      assert "BTC/TRY" = Symbol.normalize("BTCTRY", format, quote_currencies: ["TRY"])
    end
  end

  # ===========================================================================
  # denormalize/2
  # ===========================================================================

  describe "denormalize/2" do
    test "denormalizes to no-separator uppercase (Binance)" do
      format = %{separator: "", case: :upper}
      assert "BTCUSDT" = Symbol.denormalize("BTC/USDT", format)
    end

    test "denormalizes to dash separator (Coinbase)" do
      format = %{separator: "-", case: :upper}
      assert "BTC-USD" = Symbol.denormalize("BTC/USD", format)
    end

    test "denormalizes to underscore separator (Gate.io)" do
      format = %{separator: "_", case: :upper}
      assert "BTC_USDT" = Symbol.denormalize("BTC/USDT", format)
    end

    test "denormalizes to lowercase (Bitstamp)" do
      format = %{separator: "", case: :lower}
      assert "btcusdt" = Symbol.denormalize("BTC/USDT", format)
    end

    test "strips settle currency before conversion" do
      format = %{separator: "", case: :upper}
      assert "BTCUSDT" = Symbol.denormalize("BTC/USDT:USDT", format)
    end

    test "preserves mixed case" do
      format = %{separator: "-", case: :mixed}
      assert "BTC-USDT" = Symbol.denormalize("BTC/USDT", format)
    end

    test "roundtrips with normalize" do
      format = %{separator: "-", case: :upper}
      original = "BTC-USD"
      normalized = Symbol.normalize(original, format)
      assert original == Symbol.denormalize(normalized, format)
    end
  end

  # ===========================================================================
  # denormalize_ws/2
  # ===========================================================================

  describe "denormalize_ws/2" do
    test "dash_separated" do
      assert "BTC-USDT" = Symbol.denormalize_ws("BTC/USDT", :dash_separated)
    end

    test "lowercase_no_slash" do
      assert "btcusdt" = Symbol.denormalize_ws("BTC/USDT", :lowercase_no_slash)
    end

    test "uppercase_no_slash" do
      assert "BTCUSDT" = Symbol.denormalize_ws("BTC/USDT", :uppercase_no_slash)
    end

    test "slash passthrough" do
      assert "BTC/USDT" = Symbol.denormalize_ws("BTC/USDT", :slash)
    end

    test "unknown format falls back to removing slash" do
      assert "BTCUSDT" = Symbol.denormalize_ws("BTC/USDT", :unknown)
    end
  end

  # ===========================================================================
  # apply_alias/2 and reverse_aliases/1
  # ===========================================================================

  describe "apply_alias/2" do
    test "returns mapped currency" do
      assert "BTC" = Symbol.apply_alias("XBT", %{"XBT" => "BTC"})
    end

    test "returns original when no mapping" do
      assert "ETH" = Symbol.apply_alias("ETH", %{"XBT" => "BTC"})
    end

    test "works with empty alias map" do
      assert "BTC" = Symbol.apply_alias("BTC", %{})
    end
  end

  describe "reverse_aliases/1" do
    test "inverts the alias map" do
      aliases = %{"XBT" => "BTC", "ZEUR" => "EUR"}
      reversed = Symbol.reverse_aliases(aliases)
      assert reversed == %{"BTC" => "XBT", "EUR" => "ZEUR"}
    end

    test "handles empty map" do
      assert %{} = Symbol.reverse_aliases(%{})
    end
  end

  # ===========================================================================
  # strip_prefix/1
  # ===========================================================================

  describe "strip_prefix/1" do
    test "strips KrakenFutures PI_ prefix" do
      assert {"PI_", "XBTUSD"} = Symbol.strip_prefix("PI_XBTUSD")
    end

    test "strips PF_ prefix" do
      assert {"PF_", "ETHUSD"} = Symbol.strip_prefix("PF_ETHUSD")
    end

    test "strips FI_ prefix" do
      assert {"FI_", "XRPUSD"} = Symbol.strip_prefix("FI_XRPUSD")
    end

    test "strips Kraken XX prefix (crypto)" do
      assert {"X", "XBT"} = Symbol.strip_prefix("XXBT")
    end

    test "strips Kraken Z prefix (fiat, 4 chars)" do
      assert {"Z", "USD"} = Symbol.strip_prefix("ZUSD")
      assert {"Z", "EUR"} = Symbol.strip_prefix("ZEUR")
    end

    test "does not strip Z from longer codes" do
      # ZCASH is 5 chars, not a Z-prefix fiat
      assert {nil, "ZCASH"} = Symbol.strip_prefix("ZCASH")
    end

    test "returns nil prefix for regular symbols" do
      assert {nil, "BTCUSDT"} = Symbol.strip_prefix("BTCUSDT")
    end
  end

  # ===========================================================================
  # get_quote_currencies/1
  # ===========================================================================

  describe "get_quote_currencies/1" do
    test "returns sorted defaults" do
      currencies = Symbol.get_quote_currencies()
      # Longest first
      assert hd(currencies) in ["FDUSD", "USDD"]
      assert "USD" in currencies
      assert "BTC" in currencies
    end

    test "includes extra currencies" do
      currencies = Symbol.get_quote_currencies(["TRY", "BRL"])
      assert "TRY" in currencies
      assert "BRL" in currencies
    end

    test "deduplicates" do
      currencies = Symbol.get_quote_currencies(["USD", "BTC"])
      assert length(Enum.filter(currencies, &(&1 == "USD"))) == 1
    end
  end

  # ===========================================================================
  # convert_date/3
  # ===========================================================================

  describe "convert_date/3" do
    test "same format returns unchanged" do
      assert "260327" = Symbol.convert_date("260327", :yymmdd, :yymmdd)
    end

    test "yymmdd to ddmmmyy" do
      assert "27MAR26" = Symbol.convert_date("260327", :yymmdd, :ddmmmyy)
    end

    test "yymmdd to ddmmmyy with single-digit day" do
      assert "9JAN26" = Symbol.convert_date("260109", :yymmdd, :ddmmmyy)
    end

    test "ddmmmyy to yymmdd" do
      assert "260327" = Symbol.convert_date("27MAR26", :ddmmmyy, :yymmdd)
    end

    test "ddmmmyy to yymmdd with single-digit day" do
      assert "260109" = Symbol.convert_date("9JAN26", :ddmmmyy, :yymmdd)
    end

    test "yymmdd to yyyymmdd" do
      assert "20260327" = Symbol.convert_date("260327", :yymmdd, :yyyymmdd)
    end

    test "yyyymmdd to yymmdd" do
      assert "260327" = Symbol.convert_date("20260327", :yyyymmdd, :yymmdd)
    end

    test "yyyymmdd to ddmmmyy" do
      assert "27MAR26" = Symbol.convert_date("20260327", :yyyymmdd, :ddmmmyy)
    end

    test "ddmmmyy to yyyymmdd" do
      assert "20260327" = Symbol.convert_date("27MAR26", :ddmmmyy, :yyyymmdd)
    end

    test "roundtrips yymmdd through ddmmmyy" do
      original = "261231"
      converted = Symbol.convert_date(original, :yymmdd, :ddmmmyy)
      assert original == Symbol.convert_date(converted, :ddmmmyy, :yymmdd)
    end

    test "raises when the input does not match the declared source format" do
      assert_raise ArgumentError, ~r/cannot convert "04SEP26" from :yymmdd to :ddmmmyy/, fn ->
        Symbol.convert_date("04SEP26", :yymmdd, :ddmmmyy)
      end
    end

    test "raises on an unsupported format pair" do
      assert_raise ArgumentError, ~r/cannot convert "260904" from :unknown to :ddmmmyy/, fn ->
        Symbol.convert_date("260904", :unknown, :ddmmmyy)
      end
    end
  end

  # ===========================================================================
  # detect_market_type/1
  # ===========================================================================

  describe "detect_market_type/1" do
    test "detects spot from ParsedSymbol" do
      assert {:ok, parsed} = Symbol.parse_extended("BTC/USDT")
      assert :spot = Symbol.detect_market_type(parsed)
    end

    test "detects swap from ParsedSymbol" do
      assert {:ok, parsed} = Symbol.parse_extended("BTC/USDT:USDT")
      assert :swap = Symbol.detect_market_type(parsed)
    end

    test "detects future from ParsedSymbol" do
      assert {:ok, parsed} = Symbol.parse_extended("BTC/USDT:USDT-260327")
      assert :future = Symbol.detect_market_type(parsed)
    end

    test "detects option (highest priority) from ParsedSymbol" do
      assert {:ok, parsed} = Symbol.parse_extended("BTC/USD:BTC-260112-84000-C")
      assert :option = Symbol.detect_market_type(parsed)
    end

    test "accepts maps with the same keys (call-site convenience)" do
      assert :spot = Symbol.detect_market_type(%{settle: nil, expiry: nil, option_type: nil})
      assert :swap = Symbol.detect_market_type(%{settle: "USDT", expiry: nil, option_type: nil})
      assert :future = Symbol.detect_market_type(%{settle: "USDT", expiry: "260327", option_type: nil})
      assert :option = Symbol.detect_market_type(%{settle: "BTC", expiry: "260112", option_type: "C"})
    end

    test "raises ArgumentError on bare string (contract is ParsedSymbol)" do
      assert_raise ArgumentError, ~r/detect_market_type.*expects a %Bourse.Symbol.ParsedSymbol/, fn ->
        Symbol.detect_market_type("BTC/USDT")
      end
    end
  end

  # ===========================================================================
  # Exchange.common_currencies integration
  # ===========================================================================

  describe "Exchange common_currencies" do
    test "populated from markets.patterns.currency_aliases (Task 60)" do
      {:ok, exchange} = Bourse.Exchange.new("bybit")
      assert is_map(exchange.common_currencies)
      assert exchange.common_currencies["XBT"] == "BTC"
    end

    test "includes exchange-specific aliases from spec (okx AE → AET)" do
      {:ok, exchange} = Bourse.Exchange.new("okx")
      assert exchange.common_currencies["AE"] == "AET"
    end

    test "defaults to empty map when not in spec" do
      # All exchanges should have common_currencies as a map (even if empty)
      {:ok, exchange} = Bourse.Exchange.new("binance")
      assert is_map(exchange.common_currencies)
    end
  end

  # ===========================================================================
  # to_exchange_id/2 and from_exchange_id/3
  # ===========================================================================

  # Helper to build a minimal exchange struct with hardcoded symbol_patterns.
  # `common_currencies` powers inbound (`from_exchange_id`) aliasing only.
  # Outbound (`to_exchange_id`) aliasing is now driven by the separate
  # `outbound_aliases` field — see Task 91.
  defp make_exchange(id, patterns, common_currencies \\ %{}, outbound_aliases \\ %{}) do
    %Bourse.Exchange{
      id: id,
      name: id,
      common_currencies: common_currencies,
      outbound_aliases: outbound_aliases,
      symbol_patterns: patterns
    }
  end

  # Common pattern configs used across multiple tests
  @no_sep_upper %{
    pattern: :no_separator_upper,
    separator: "",
    case: :upper,
    date_format: nil,
    suffix: nil,
    prefix: nil
  }
  @implicit_swap %{
    pattern: :implicit,
    separator: "",
    case: :upper,
    date_format: nil,
    suffix: nil,
    prefix: nil
  }

  describe "to_exchange_id/2 - Binance patterns" do
    setup do
      exchange =
        make_exchange("binance", %{
          spot: @no_sep_upper,
          swap: @implicit_swap,
          future: %{
            pattern: :future_yymmdd,
            separator: "_",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          },
          option: %{
            pattern: :option_base_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      {:ok, exchange: exchange}
    end

    test "spot: BTC/USDT → BTCUSDT", %{exchange: ex} do
      assert "BTCUSDT" = Symbol.to_exchange_id("BTC/USDT", ex)
    end

    test "swap: BTC/USDT:USDT → BTCUSDT", %{exchange: ex} do
      assert "BTCUSDT" = Symbol.to_exchange_id("BTC/USDT:USDT", ex)
    end

    test "future: BTC/USDT:USDT-260327 → BTCUSDT_260327", %{exchange: ex} do
      assert "BTCUSDT_260327" = Symbol.to_exchange_id("BTC/USDT:USDT-260327", ex)
    end

    test "option: BTC/USDT:USDT-260925-145000-C → BTC-260925-145000-C", %{exchange: ex} do
      assert "BTC-260925-145000-C" = Symbol.to_exchange_id("BTC/USDT:USDT-260925-145000-C", ex)
    end

    test "option preserves decimal strikes", %{exchange: ex} do
      assert "XRP-260731-0.85-C" = Symbol.to_exchange_id("XRP/USDT:USDT-260731-0.85-C", ex)
    end
  end

  describe "to_exchange_id/2 - Deribit patterns" do
    setup do
      exchange =
        make_exchange(
          "deribit",
          %{
            spot: %{pattern: :dash_upper, separator: "-", case: :upper, date_format: nil, suffix: nil, prefix: nil},
            # separator "_" mirrors deribit's real spec: linear ids are base_quote
            # (ADA_USDC-PERPETUAL), inverse ids are base-only (BTC-PERPETUAL) keyed
            # on quote == "USD" — NOT on the separator char.
            swap: %{
              pattern: :suffix_perpetual,
              separator: "_",
              case: :upper,
              date_format: nil,
              suffix: "-PERPETUAL",
              prefix: nil
            },
            future: %{
              pattern: :future_ddmmmyy,
              separator: "_",
              case: :upper,
              date_format: :ddmmmyy,
              suffix: nil,
              prefix: nil
            },
            option: %{
              pattern: :option_ddmmmyy,
              separator: "_",
              case: :upper,
              date_format: :ddmmmyy,
              suffix: nil,
              prefix: nil
            }
          }
        )

      {:ok, exchange: exchange}
    end

    test "swap inverse: BTC/USD:BTC → BTC-PERPETUAL (base-only)", %{exchange: ex} do
      assert "BTC-PERPETUAL" = Symbol.to_exchange_id("BTC/USD:BTC", ex)
    end

    test "swap linear: ADA/USDC:USDC → ADA_USDC-PERPETUAL (base_quote)", %{exchange: ex} do
      assert "ADA_USDC-PERPETUAL" = Symbol.to_exchange_id("ADA/USDC:USDC", ex)
    end

    test "future: BTC/USD:BTC-260116 → BTC-16JAN26", %{exchange: ex} do
      assert "BTC-16JAN26" = Symbol.to_exchange_id("BTC/USD:BTC-260116", ex)
    end

    test "future linear: BTC/USDC:USDC-260622 → BTC_USDC-22JUN26", %{exchange: ex} do
      assert "BTC_USDC-22JUN26" = Symbol.to_exchange_id("BTC/USDC:USDC-260622", ex)
    end

    test "option: BTC/USD:BTC-260112-84000-C → BTC-12JAN26-84000-C", %{exchange: ex} do
      assert "BTC-12JAN26-84000-C" = Symbol.to_exchange_id("BTC/USD:BTC-260112-84000-C", ex)
    end

    test "option put: ETH/USD:ETH-260612-5000-P → ETH-12JUN26-5000-P", %{exchange: ex} do
      assert "ETH-12JUN26-5000-P" = Symbol.to_exchange_id("ETH/USD:ETH-260612-5000-P", ex)
    end

    test "option linear: AVAX/USDC:USDC-260622-5.5-C → AVAX_USDC-22JUN26-5d5-C", %{exchange: ex} do
      assert "AVAX_USDC-22JUN26-5d5-C" = Symbol.to_exchange_id("AVAX/USDC:USDC-260622-5.5-C", ex)
    end
  end

  # Reality-anchored: builds the exchange from the REAL frozen spec (not a
  # fabricated config), so the assertion reflects what the live API accepts.
  # Bug 3 (BTC/USD:BTC → "BTC_USD-PERPETUAL", rejected live as "instrument not
  # open") slipped past the fabricated-config tests above precisely because they
  # used separator "-"; the real spec carries "_". Verified live via tidewave.
  describe "to_exchange_id/2 - Deribit (real spec)" do
    setup do
      {:ok, exchange: Bourse.Exchange.new!("deribit")}
    end

    test "swap inverse: BTC/USD:BTC → BTC-PERPETUAL", %{exchange: ex} do
      assert "BTC-PERPETUAL" = Symbol.to_exchange_id("BTC/USD:BTC", ex)
    end

    test "swap linear: ADA/USDC:USDC → ADA_USDC-PERPETUAL", %{exchange: ex} do
      assert "ADA_USDC-PERPETUAL" = Symbol.to_exchange_id("ADA/USDC:USDC", ex)
    end

    test "linear USDC perpetual round-trips through the live Deribit spec", %{exchange: ex} do
      symbol = "1000BONK/USDC:USDC"
      exchange_id = Symbol.to_exchange_id(symbol, ex)

      assert exchange_id == "1000BONK_USDC-PERPETUAL"
      assert Symbol.from_exchange_id(exchange_id, ex, :swap) == symbol
    end

    test "dated USDC future round-trips through the live Deribit spec", %{exchange: ex} do
      symbol = "BTC/USDC:USDC-260622"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert exchange_id == "BTC_USDC-22JUN26"
      assert Symbol.from_exchange_id(exchange_id, ex, :future) == symbol
    end

    test "USDC option with d-decimal strike round-trips through the live Deribit spec", %{exchange: ex} do
      symbol = "AVAX/USDC:USDC-260622-5.5-C"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert exchange_id == "AVAX_USDC-22JUN26-5d5-C"
      assert Symbol.from_exchange_id(exchange_id, ex, :option) == symbol
    end

    # Task 305 / carve C27: a live option_combo id whose C24 d-encoded strikes the
    # option grammar used to partially transform (upcase `0d1184` → `0D1184`) and
    # return as a plausible-but-wrong symbol. Contract: identity or faithful
    # round-trip or raise — never a rewritten intermediate.
    test "d-strike option_combo id is not silently rewritten by from_exchange_id/3", %{
      exchange: ex
    } do
      id = "DOGE_USDC-CS-28AUG26-0d1184_0d12"
      rewritten = "DOGE_USDC-CS-28AUG26-0D1184_0D12"

      assert Symbol.from_exchange_id(id, ex, :option) == id
      assert Symbol.from_exchange_id!(id, ex, :option) == id
      refute Symbol.from_exchange_id(id, ex, :option) == rewritten
      # Outbound stays identity for no-slash native ids.
      assert Symbol.to_exchange_id(id, ex) == id
    end

    test "future_combo and option_combo native ids identity-passthrough from_exchange_id/3", %{
      exchange: ex
    } do
      for {id, type} <- [
            {"BTC-FS-17JUL26_PERP", :future},
            {"BTC-FS-31JUL26_17JUL26", :future},
            {"BTC-REV-18JUL26-65000", :option},
            {"DOGE_USDC-CS-28AUG26-0d1184_0d12", :option}
          ] do
        assert Symbol.from_exchange_id(id, ex, type) == id
        assert Symbol.to_exchange_id(id, ex) == id
      end
    end
  end

  describe "to_exchange_id/2 - Derive (real spec)" do
    setup do
      {:ok, exchange: Bourse.Exchange.new!("derive")}
    end

    test "full-date option ids round-trip through the unified short expiry", %{exchange: exchange} do
      native = "ZEC-20260925-800-P"
      unified = "ZEC/USDC:USDC-260925-800-P"

      assert Symbol.from_exchange_id(native, exchange, :option) == unified
      assert Symbol.from_exchange_id!(native, exchange, :option) == unified
      assert Symbol.to_exchange_id(unified, exchange) == native
    end

    test "full-date option ids recover from the coarse read-path swap classification", %{exchange: exchange} do
      assert Symbol.from_exchange_id("ZEC-20260925-800-P", exchange, :swap) ==
               "ZEC/USDC:USDC-260925-800-P"
    end
  end

  describe "to_exchange_id/2 - OKX patterns" do
    setup do
      exchange =
        make_exchange("okx", %{
          spot: %{pattern: :dash_upper, separator: "-", case: :upper, date_format: nil, suffix: nil, prefix: nil},
          swap: %{
            pattern: :suffix_swap,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: "-SWAP",
            prefix: nil
          },
          option: %{
            pattern: :option_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      {:ok, exchange: exchange}
    end

    test "spot: BTC/USDT → BTC-USDT", %{exchange: ex} do
      assert "BTC-USDT" = Symbol.to_exchange_id("BTC/USDT", ex)
    end

    test "swap: BTC/USDT:USDT → BTC-USDT-SWAP", %{exchange: ex} do
      assert "BTC-USDT-SWAP" = Symbol.to_exchange_id("BTC/USDT:USDT", ex)
    end

    test "option: BTC/USD:BTC-260112-80000-C → BTC-USD-260112-80000-C", %{exchange: ex} do
      assert "BTC-USD-260112-80000-C" = Symbol.to_exchange_id("BTC/USD:BTC-260112-80000-C", ex)
    end
  end

  describe "to_exchange_id/2 - Bybit patterns" do
    setup do
      exchange =
        make_exchange("bybit", %{
          spot: @no_sep_upper,
          future: %{
            pattern: :future_ddmmmyy,
            separator: "",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          },
          option: %{
            pattern: :option_with_settle,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      {:ok, exchange: exchange}
    end

    test "future: BTC/USDT:USDT-260327 → BTCUSDT-27MAR26", %{exchange: ex} do
      assert "BTCUSDT-27MAR26" = Symbol.to_exchange_id("BTC/USDT:USDT-260327", ex)
    end

    test "future: BTC/USDT:USDT-260904 → BTCUSDT-04SEP26 (venue-padded day)", %{exchange: ex} do
      assert "BTCUSDT-04SEP26" = Symbol.to_exchange_id("BTC/USDT:USDT-260904", ex)
    end

    test "option: BTC/USDT:USDT-261225-105000-P → BTC-25DEC26-105000-P-USDT", %{exchange: ex} do
      assert "BTC-25DEC26-105000-P-USDT" = Symbol.to_exchange_id("BTC/USDT:USDT-261225-105000-P", ex)
    end

    test "option: BTC/USDC:USDC-241227-55000-P → BTC-27DEC24-55000-P", %{exchange: ex} do
      assert "BTC-27DEC24-55000-P" = Symbol.to_exchange_id("BTC/USDC:USDC-241227-55000-P", ex)
    end
  end

  describe "to_exchange_id/2 - Bybit provider date format" do
    setup do
      {:ok, exchange: Bourse.Exchange.new!("bybit")}
    end

    test "the authored future_ddmmmyy pattern keeps native DDMMMYY and stamps yymmdd", %{
      exchange: exchange
    } do
      assert %{pattern: :future_ddmmmyy, date_format: :ddmmmyy} = exchange.symbol_patterns.future

      # Bybit V5 linear instrument ids are `{base}{quote}-DDMMMYY` (docs enum
      # example `BTCUSDT-21FEB25`; live 2026-08-19 pads the day as `04SEP26`).
      # fetch_markets must stamp canonical yymmdd — a venue-native unified
      # expiry is the 658 miss this test exists to redden.
      futures = Enum.filter(recorded_markets!(exchange), &(&1.type == "future"))
      refute Enum.empty?(futures), "bybit recorded markets must include a dated future"

      for market <- futures do
        assert {:ok, parsed} = Symbol.parse_extended(market.symbol)

        if is_binary(parsed.expiry) do
          assert parsed.expiry =~ ~r/^\d{6}$/,
                 "expected yymmdd unified expiry, got: #{parsed.expiry} in #{market.symbol}"
        end
      end

      for {unified_symbol, native_symbol} <- [
            {"BTC/USDT:USDT-260904", "BTCUSDT-04SEP26"},
            {"BTC/USDT:USDT-260821", "BTCUSDT-21AUG26"}
          ] do
        assert Symbol.to_exchange_id(unified_symbol, exchange) == native_symbol
        assert Symbol.from_exchange_id(native_symbol, exchange, :future) == unified_symbol
      end
    end

    test "dated-future non-bang reads reach HTTP and return a typed provider error", %{exchange: exchange} do
      symbol = "BTC/USDT:USDT-260904"
      native_symbol = "BTCUSDT-04SEP26"
      test_pid = self()
      stub = {__MODULE__, System.unique_integer([:positive])}

      error_body =
        "bybit"
        |> Bourse.RecordedResponseFixtures.fixture_path(:error_bad_symbol)
        |> Bourse.RecordedResponseFixtures.load_fixture!()
        |> Map.fetch!("body")

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:dated_future_request, conn.request_path, URI.decode_query(conn.query_string)})
        Req.Test.json(conn, error_body)
      end)

      assert {:error, %Bourse.Error{type: :bad_request}} =
               Bourse.fetch_ticker(exchange, symbol, plug: {Req.Test, stub})

      assert {:error, %Bourse.Error{type: :bad_request}} =
               Bourse.fetch_ohlcv(exchange, symbol, "1m", plug: {Req.Test, stub})

      assert {:error, %Bourse.Error{type: :bad_request}} =
               Bourse.fetch_order_book(exchange, symbol, plug: {Req.Test, stub})

      assert {:error, %Bourse.Error{type: :bad_request}} =
               Bourse.fetch_trades(exchange, symbol, plug: {Req.Test, stub})

      for path <- ["/v5/market/tickers", "/v5/market/kline", "/v5/market/orderbook"] do
        assert_receive {:dated_future_request, ^path, %{"category" => "linear", "symbol" => ^native_symbol}}
      end

      assert_receive {:dated_future_request, "/v5/market/recent-trade", %{"symbol" => ^native_symbol}}
    end
  end

  describe "from_exchange_id/3 - Binance patterns" do
    setup do
      exchange =
        make_exchange("binance", %{
          spot: @no_sep_upper,
          swap: @implicit_swap,
          future: %{
            pattern: :future_yymmdd,
            separator: "_",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          },
          option: %{
            pattern: :option_base_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      {:ok, exchange: exchange}
    end

    test "spot: BTCUSDT → BTC/USDT", %{exchange: ex} do
      assert "BTC/USDT" = Symbol.from_exchange_id("BTCUSDT", ex, :spot)
    end

    test "unsplittable inverse-perp id does not produce a trailing slash (task 167)", %{exchange: ex} do
      # Spot / implicit-swap patterns cannot reverse BTCUSD_PERP; must not emit "BTCUSD_PERP/".
      assert "BTCUSD_PERP" = Symbol.from_exchange_id("BTCUSD_PERP", ex, :spot)
      assert "BTCUSD_PERP" = Symbol.from_exchange_id("BTCUSD_PERP", ex, :swap)
      refute String.ends_with?(Symbol.from_exchange_id("BTCUSD_PERP", ex, :spot), "/")
    end

    test "future: BTCUSDT_260327 → BTC/USDT:USDT-260327", %{exchange: ex} do
      assert "BTC/USDT:USDT-260327" = Symbol.from_exchange_id("BTCUSDT_260327", ex, :future)
    end

    test "option: BTC-260925-145000-C → BTC/USDT:USDT-260925-145000-C", %{exchange: ex} do
      assert "BTC/USDT:USDT-260925-145000-C" =
               Symbol.from_exchange_id("BTC-260925-145000-C", ex, :option)
    end
  end

  describe "from_exchange_id/3 - Deribit patterns" do
    setup do
      exchange =
        make_exchange(
          "deribit",
          %{
            swap: %{
              pattern: :suffix_perpetual,
              separator: "-",
              case: :upper,
              date_format: nil,
              suffix: "-PERPETUAL",
              prefix: nil
            },
            future: %{
              pattern: :future_ddmmmyy,
              separator: "-",
              case: :upper,
              date_format: :ddmmmyy,
              suffix: nil,
              prefix: nil
            },
            option: %{
              pattern: :option_ddmmmyy,
              separator: "-",
              case: :upper,
              date_format: :ddmmmyy,
              suffix: nil,
              prefix: nil
            }
          },
          %{"XBT" => "BTC"}
        )

      {:ok, exchange: exchange}
    end

    test "swap: BTC-PERPETUAL → BTC/USD:BTC", %{exchange: ex} do
      assert "BTC/USD:BTC" = Symbol.from_exchange_id("BTC-PERPETUAL", ex, :swap)
    end

    test "future: BTC-16JAN26 → BTC/USD:BTC-260116", %{exchange: ex} do
      assert "BTC/USD:BTC-260116" = Symbol.from_exchange_id("BTC-16JAN26", ex, :future)
    end

    test "inverse future round-trips to Deribit's base-date native id", %{exchange: ex} do
      assert "BTC-16JAN26" = Symbol.to_exchange_id("BTC/USD:BTC-260116", ex)
    end

    test "option: BTC-12JAN26-84000-C → BTC/USD:BTC-260112-84000-C", %{exchange: ex} do
      assert "BTC/USD:BTC-260112-84000-C" = Symbol.from_exchange_id("BTC-12JAN26-84000-C", ex, :option)
    end
  end

  describe "from_exchange_id/3 - OKX patterns" do
    setup do
      exchange =
        make_exchange("okx", %{
          spot: %{pattern: :dash_upper, separator: "-", case: :upper, date_format: nil, suffix: nil, prefix: nil},
          swap: %{
            pattern: :suffix_swap,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: "-SWAP",
            prefix: nil
          },
          option: %{
            pattern: :option_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      {:ok, exchange: exchange}
    end

    test "spot: BTC-USDT → BTC/USDT", %{exchange: ex} do
      assert "BTC/USDT" = Symbol.from_exchange_id("BTC-USDT", ex, :spot)
    end

    test "swap: BTC-USDT-SWAP → BTC/USDT:USDT", %{exchange: ex} do
      assert "BTC/USDT:USDT" = Symbol.from_exchange_id("BTC-USDT-SWAP", ex, :swap)
    end

    test "option: BTC-USD-260112-80000-C → BTC/USD:BTC-260112-80000-C", %{exchange: ex} do
      assert "BTC/USD:BTC-260112-80000-C" = Symbol.from_exchange_id("BTC-USD-260112-80000-C", ex, :option)
    end
  end

  describe "from_exchange_id/3 - Bybit patterns" do
    setup do
      exchange =
        make_exchange("bybit", %{
          future: %{
            pattern: :future_ddmmmyy,
            separator: "",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          },
          option: %{
            pattern: :option_with_settle,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      {:ok, exchange: exchange}
    end

    test "future: BTCUSDT-27MAR26 → BTC/USDT:USDT-260327", %{exchange: ex} do
      assert "BTC/USDT:USDT-260327" = Symbol.from_exchange_id("BTCUSDT-27MAR26", ex, :future)
    end

    test "option: BTC-25DEC26-105000-P-USDT → BTC/USDT:USDT-261225-105000-P", %{exchange: ex} do
      assert "BTC/USDT:USDT-261225-105000-P" = Symbol.from_exchange_id("BTC-25DEC26-105000-P-USDT", ex, :option)
    end

    test "option: BTC-27DEC24-55000-P → BTC/USDC:USDC-241227-55000-P", %{exchange: ex} do
      assert "BTC/USDC:USDC-241227-55000-P" = Symbol.from_exchange_id("BTC-27DEC24-55000-P", ex, :option)
    end
  end

  # ===========================================================================
  # Roundtrip tests
  # ===========================================================================

  describe "roundtrip: to_exchange_id → from_exchange_id" do
    test "each market type in every supported venue's recorded market list round-trips" do
      for exchange_id <- Bourse.Spec.exchanges() do
        exchange = Bourse.Exchange.new!(exchange_id)

        if exchange.has["fetchMarkets"] == true do
          markets = recorded_markets!(exchange)

          refute Enum.empty?(markets), "#{exchange_id}: recorded market list is empty"

          # Pattern conversion only — loading markets would short-circuit
          # `to_exchange_id/2` via id lookup and miss a `convert_date/3` miss.
          markets
          |> Enum.filter(&is_binary(&1.type))
          |> Enum.group_by(& &1.type)
          |> Enum.each(fn {market_type, [market | _same_type]} ->
            market_type_atom = String.to_existing_atom(market_type)
            date_format = get_in(exchange.symbol_patterns, [market_type_atom, :date_format])

            case Symbol.parse_extended(market.symbol) do
              {:ok, parsed} when is_binary(parsed.expiry) and not is_nil(date_format) ->
                assert parsed.expiry =~ ~r/^\d{6}$/,
                       "#{exchange_id} #{market_type}: unified expiry must be yymmdd, got #{inspect(parsed.expiry)} in #{market.symbol}"

              _other ->
                :ok
            end

            native_symbol = Symbol.to_exchange_id(market.symbol, exchange)
            unified_symbol = Symbol.from_exchange_id(native_symbol, exchange, market_type_atom)
            stable_native_symbol = Symbol.to_exchange_id(unified_symbol, exchange)
            stable_unified_symbol = Symbol.from_exchange_id(stable_native_symbol, exchange, market_type_atom)

            assert stable_native_symbol == native_symbol,
                   "#{exchange_id} #{market_type}: native symbol changed after round-trip"

            assert stable_unified_symbol == unified_symbol,
                   "#{exchange_id} #{market_type}: unified symbol changed after round-trip"
          end)
        end
      end
    end

    test "Binance spot roundtrip" do
      ex =
        make_exchange("binance", %{
          spot: @no_sep_upper
        })

      symbol = "BTC/USDT"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :spot)
    end

    test "Binance future roundtrip" do
      ex =
        make_exchange("binance", %{
          future: %{
            pattern: :future_yymmdd,
            separator: "_",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "BTC/USDT:USDT-260327"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :future)
    end

    test "Deribit option roundtrip" do
      ex =
        make_exchange("deribit", %{
          option: %{
            pattern: :option_ddmmmyy,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "BTC/USD:BTC-260112-84000-C"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :option)
    end

    test "Bybit option roundtrip" do
      ex =
        make_exchange("bybit", %{
          option: %{
            pattern: :option_with_settle,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "BTC/USDT:USDT-261225-105000-P"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :option)
    end

    test "Bybit USDC option exchange-id roundtrip uses bare venue id" do
      ex =
        make_exchange("bybit", %{
          option: %{
            pattern: :option_with_settle,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      exchange_id = "BTC-27DEC24-55000-P"
      unified = Symbol.from_exchange_id(exchange_id, ex, :option)

      assert unified == "BTC/USDC:USDC-241227-55000-P"
      assert Symbol.to_exchange_id(unified, ex) == exchange_id
    end

    test "Bybit USDT option exchange-id roundtrip preserves settlement suffix" do
      ex =
        make_exchange("bybit", %{
          option: %{
            pattern: :option_with_settle,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      exchange_id = "BTC-25JUN27-150000-P-USDT"
      unified = Symbol.from_exchange_id(exchange_id, ex, :option)

      assert unified == "BTC/USDT:USDT-270625-150000-P"
      assert Symbol.to_exchange_id(unified, ex) == exchange_id
    end

    test "OKX option roundtrip" do
      ex =
        make_exchange("okx", %{
          option: %{
            pattern: :option_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "BTC/USD:BTC-260112-80000-C"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :option)
    end

    test "Binance option roundtrip" do
      ex =
        make_exchange("binance", %{
          option: %{
            pattern: :option_base_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "BTC/USDT:USDT-260925-145000-C"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert exchange_id == "BTC-260925-145000-C"
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :option)
    end

    test "Binance decimal-strike option roundtrip" do
      ex =
        make_exchange("binance", %{
          option: %{
            pattern: :option_base_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "XRP/USDT:USDT-260731-0.85-C"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert exchange_id == "XRP-260731-0.85-C"
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :option)
    end

    test "Deribit future roundtrip" do
      ex =
        make_exchange("deribit", %{
          future: %{
            pattern: :future_ddmmmyy,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "BTC/USD:BTC-260116"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert exchange_id == "BTC-16JAN26"
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :future)
    end

    test "Deribit inverse future keeps the unpadded live day width" do
      ex =
        make_exchange("deribit", %{
          future: %{
            pattern: :future_ddmmmyy,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTC-4SEP26" = Symbol.to_exchange_id("BTC/USD:BTC-260904", ex)
    end

    test "Deribit linear USDC future roundtrip" do
      ex =
        make_exchange("deribit", %{
          future: %{
            pattern: :future_ddmmmyy,
            separator: "_",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "AVAX/USDC:USDC-260622"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert exchange_id == "AVAX_USDC-22JUN26"
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :future)
    end

    test "Deribit linear USDC option roundtrip with d-decimal strike" do
      ex =
        make_exchange("deribit", %{
          option: %{
            pattern: :option_ddmmmyy,
            separator: "_",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "AVAX/USDC:USDC-260622-5.5-C"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert exchange_id == "AVAX_USDC-22JUN26-5d5-C"
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :option)
    end

    test "YYYYMMDD future roundtrip" do
      ex =
        make_exchange("test", %{
          future: %{
            pattern: :future_yyyymmdd,
            separator: "_",
            case: :upper,
            date_format: :yyyymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "BTC/USDT:USDT-260327"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert "BTCUSDT_20260327" = exchange_id
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :future)
    end

    test "YYYYMMDD future roundtrip with dash separator (3-part)" do
      ex =
        make_exchange("test", %{
          future: %{
            pattern: :future_yyyymmdd,
            separator: "-",
            case: :upper,
            date_format: :yyyymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      symbol = "BTC/USD:BTC-260327"
      exchange_id = Symbol.to_exchange_id(symbol, ex)
      assert "BTC-USD-20260327" = exchange_id
      assert symbol == Symbol.from_exchange_id(exchange_id, ex, :future)
    end
  end

  # ===========================================================================
  # Edge cases and error handling
  # ===========================================================================

  describe "to_exchange_id/2 edge cases" do
    test "invalid symbol returns as-is" do
      ex = make_exchange("test", %{})
      assert "INVALID" = Symbol.to_exchange_id("INVALID", ex)
    end

    test "missing pattern config returns input unchanged" do
      ex =
        make_exchange("test", %{
          spot: %{pattern: :dash_upper, separator: "-", case: :upper, date_format: nil, suffix: nil, prefix: nil}
        })

      # swap pattern missing — return unchanged rather than lossy spot conversion
      assert "BTC/USDT:USDT" = Symbol.to_exchange_id("BTC/USDT:USDT", ex)
    end

    test "outbound aliases applied (Kraken BTC → XBT)" do
      # Outbound aliases are now per-exchange opt-in (Task 91): only Kraken
      # actually accepts XBT on input, so the forward map is no longer
      # derived by reversing common_currencies.
      ex =
        make_exchange(
          "kraken",
          %{spot: @no_sep_upper},
          %{"XBT" => "BTC"},
          %{"BTC" => "XBT"}
        )

      assert "XBTUSD" = Symbol.to_exchange_id("BTC/USD", ex)
    end

    test "common_currencies alone does NOT trigger outbound rewrite (Task 91 regression)" do
      # Pre-Task-91 behavior: any exchange carrying `XBT → BTC` in
      # common_currencies (every spec does, as a defensive
      # base default) had outbound BTC silently rewritten to XBT.
      # Post-Task-91: outbound_aliases is the sole input.
      ex = make_exchange("binance", %{spot: @no_sep_upper}, %{"XBT" => "BTC"})

      assert "BTCUSDT" = Symbol.to_exchange_id("BTC/USDT", ex)
    end
  end

  describe "swap settle currency with real specs (carve C25)" do
    # swap_settle/3 is on the shared reverse path, so the USD-quote-means-base-settle
    # rule binds every venue whose swap pattern is :implicit / :suffix_perpetual /
    # :suffix_swap — not just Deribit. Pinning the cross-venue expectation here keeps a
    # future "quote in [USD, USDC]" widening from silently re-breaking the linear book.

    test "USDC-quoted perps settle in USDC across venues sharing the swap reverse path" do
      for {exchange_id, native_id, expected} <- [
            {"deribit", "1000BONK_USDC-PERPETUAL", "1000BONK/USDC:USDC"},
            {"hyperliquid", "BTCUSDC", "BTC/USDC:USDC"},
            {"okx", "BTC-USDC-SWAP", "BTC/USDC:USDC"},
            {"bybit", "BTCUSDC", "BTC/USDC:USDC"},
            {"binanceusdm", "BTCUSDC", "BTC/USDC:USDC"}
          ] do
        exchange = Bourse.Exchange.new!(exchange_id)

        assert Symbol.from_exchange_id(native_id, exchange, :swap) == expected,
               "#{exchange_id}: #{native_id} should unify to #{expected}"

        assert Symbol.to_exchange_id(expected, exchange) == native_id,
               "#{exchange_id}: #{expected} should denormalize to #{native_id}"
      end
    end

    test "USD-quoted inverse perps still settle in base" do
      for {exchange_id, native_id, expected} <- [
            {"deribit", "BTC-PERPETUAL", "BTC/USD:BTC"},
            {"bybit", "BTCUSD", "BTC/USD:BTC"}
          ] do
        exchange = Bourse.Exchange.new!(exchange_id)

        assert Symbol.from_exchange_id(native_id, exchange, :swap) == expected,
               "#{exchange_id}: #{native_id} should unify to #{expected}"
      end
    end

    test "derive's -PERP family stays USDC-settled under a USD quote" do
      exchange = Bourse.Exchange.new!("derive")

      assert Symbol.from_exchange_id("BTC-PERP", exchange, :swap) == "BTC/USD:USDC"
    end
  end

  describe "to_exchange_id/2 + from_exchange_id/3 with real specs (Task 91 regression)" do
    # End-to-end checks that go through Exchange.new!/1 to confirm outbound
    # BTC is NOT rewritten to XBT on in-scope exchanges, despite their specs
    # all carrying `XBT → BTC` in commonCurrencies as a defensive base default.
    # (The Kraken outbound/inbound regression coverage was dropped when Kraken
    # was moved out of the Registry scope.)

    test "binance outbound BTC/USDT does not leak to XBTUSDT" do
      exchange = Bourse.Exchange.new!("binance")
      assert "BTCUSDT" = Symbol.to_exchange_id("BTC/USDT", exchange)
    end

    test "bybit outbound BTC/USDT does not leak to XBTUSDT" do
      exchange = Bourse.Exchange.new!("bybit")
      assert "BTCUSDT" = Symbol.to_exchange_id("BTC/USDT", exchange)
    end

    test "okx outbound BTC/USDT does not leak to XBT-USDT" do
      exchange = Bourse.Exchange.new!("okx")
      assert "BTC-USDT" = Symbol.to_exchange_id("BTC/USDT", exchange)
    end

    test "okx real spec keeps instId roundtrips stable across market types" do
      exchange = Bourse.Exchange.new!("okx")

      # The expected unified symbol is asserted alongside the round-trip: an
      # unclassified pattern passes both conversions through untouched, so
      # `instId -> instId` alone would hold vacuously without ever unifying.
      for {inst_id, market_type, expected_unified} <- [
            {"BTC-USDT", :spot, "BTC/USDT"},
            {"BTC-USD-SWAP", :swap, "BTC/USD:BTC"},
            {"BTC-USD-260626", :future, "BTC/USD:BTC-260626"},
            {"BTC-USD-260717-48000-C", :option, "BTC/USD:BTC-260717-48000-C"}
          ] do
        unified = Symbol.from_exchange_id(inst_id, exchange, market_type)

        assert unified == expected_unified,
               "#{market_type}: #{inst_id} unified to #{inspect(unified)}"

        assert Symbol.to_exchange_id(unified, exchange) == inst_id
      end
    end

    test "okx real spec keeps the quote in option instIds" do
      exchange = Bourse.Exchange.new!("okx")

      assert "BTC-USD-260717-48000-C" =
               Symbol.to_exchange_id("BTC/USD:BTC-260717-48000-C", exchange)
    end

    test "okx real spec carves unified-margin futures and options into canonical symbols" do
      exchange = Bourse.Exchange.new!("okx")

      for {inst_id, market_type, canonical_symbol} <- [
            {"SOL-USD_UM-260724", :future, "SOL/USD:USD-260724"},
            {"SOL-USD_UM-260731-48-C", :option, "SOL/USD:USD-260731-48-C"}
          ] do
        assert Symbol.from_exchange_id(inst_id, exchange, market_type) == canonical_symbol
        assert Symbol.to_exchange_id(canonical_symbol, exchange) == inst_id
        refute String.contains?(canonical_symbol, "USD_UM")
      end
    end

    test "okx real spec scopes the unified-margin suffix to USD-settled contracts" do
      exchange = Bourse.Exchange.new!("okx")

      for {canonical_symbol, inst_id} <- [
            {"BTC/USDT:USDT-260327", "BTC-USDT-260327"},
            {"SOL/USD:USD-260724", "SOL-USD_UM-260724"},
            {"BTC/USD:BTC-260626", "BTC-USD-260626"},
            {"EWJ/USD:USD", "EWJ-USD_UM-SWAP"},
            {"HOME/USDT:USDT", "HOME-USDT-SWAP"},
            {"HOME/USDC:USDC", "HOME-USDC-SWAP"},
            {"DOGE/USD:DOGE", "DOGE-USD-SWAP"}
          ] do
        assert Symbol.to_exchange_id(canonical_symbol, exchange) == inst_id
      end

      assert Symbol.from_exchange_id("EWJ-USD_UM-SWAP", exchange, :swap) == "EWJ/USD:USD"
      assert Symbol.from_exchange_id("HOME-USDT-SWAP", exchange, :swap) == "HOME/USDT:USDT"
      assert Symbol.from_exchange_id("HOME-USDC-SWAP", exchange, :swap) == "HOME/USDC:USDC"
    end

    test "okx loaded X-Perp future resolves its canonical symbol to the exact instId" do
      canonical_symbol = "DOGE/USD:USD-310516"

      exchange =
        "okx"
        |> Bourse.Exchange.new!()
        |> Map.put(:markets, [
          %Bourse.Market{
            id: "DOGE-USD_UM_XPERP-310516",
            symbol: canonical_symbol,
            type: "future"
          }
        ])

      assert Symbol.from_exchange_id("DOGE-USD_UM_XPERP-310516", exchange, :future) ==
               canonical_symbol

      assert Symbol.to_exchange_id(canonical_symbol, exchange) == "DOGE-USD_UM_XPERP-310516"
      assert Symbol.to_exchange_id!(canonical_symbol, exchange) == "DOGE-USD_UM_XPERP-310516"
    end

    test "other first-class option denormalization stays unchanged" do
      deribit = Bourse.Exchange.new!("deribit")
      bybit = Bourse.Exchange.new!("bybit")
      binance = Bourse.Exchange.new!("binance")

      assert "BTC-12JAN26-84000-C" =
               Symbol.to_exchange_id("BTC/USD:BTC-260112-84000-C", deribit)

      assert "BTC-25DEC26-105000-P-USDT" =
               Symbol.to_exchange_id("BTC/USDT:USDT-261225-105000-P", bybit)

      assert "BTC-260925-145000-C" =
               Symbol.to_exchange_id("BTC/USDT:USDT-260925-145000-C", binance)
    end
  end

  describe "to_exchange_id!/2" do
    test "raises on invalid symbol" do
      ex =
        make_exchange("test", %{
          spot: %{pattern: :dash_upper, separator: "-", case: :upper, date_format: nil, suffix: nil, prefix: nil}
        })

      assert_raise Error, ~r/Invalid symbol format/, fn ->
        Symbol.to_exchange_id!("INVALID", ex)
      end
    end

    test "raises when pattern not found" do
      ex = make_exchange("test", %{})

      assert_raise Error, ~r/No symbol pattern found/, fn ->
        Symbol.to_exchange_id!("BTC/USDT", ex)
      end
    end
  end

  describe "from_exchange_id!/3" do
    test "raises when pattern not found" do
      ex = make_exchange("test", %{})

      assert_raise Error, ~r/No symbol pattern found/, fn ->
        Symbol.from_exchange_id!("BTCUSDT", ex, :spot)
      end
    end

    test "converts when pattern is present" do
      ex = make_exchange("test", %{spot: @no_sep_upper})
      assert "BTC/USDT" = Symbol.from_exchange_id!("BTCUSDT", ex, :spot)
    end
  end

  # ===========================================================================
  # Coverage edge cases (critical-logic 95% gate for Task 149)
  # ===========================================================================

  describe "parse_extended/1 edge cases" do
    test "rejects multiple colons" do
      assert {:error, :invalid_format} = Symbol.parse_extended("BTC/USDT:USDT:extra")
    end

    test "rejects invalid pair with derivative suffix" do
      assert {:error, :invalid_format} = Symbol.parse_extended("BTCUSDT:USDT")
      assert {:error, :invalid_format} = Symbol.parse_extended("/USDT:USDT")
    end
  end

  describe "convert_date/3 edge cases" do
    test "returns invalid ddmmmyy strings unchanged" do
      assert "not-a-date" = Symbol.convert_date("not-a-date", :ddmmmyy, :yymmdd)
    end
  end

  describe "to_exchange_id!/2 success path" do
    test "applies pattern when config present" do
      ex = make_exchange("test", %{spot: @no_sep_upper})
      assert "BTCUSDT" = Symbol.to_exchange_id!("BTC/USDT", ex)
    end
  end

  describe "from_exchange_id/3 soft missing pattern" do
    test "returns exchange id unchanged when market type has no pattern" do
      ex = make_exchange("test", %{spot: @no_sep_upper})
      assert "BTCUSDT" = Symbol.from_exchange_id("BTCUSDT", ex, :swap)
    end
  end

  describe "apply_pattern edge cases via to_exchange_id/2" do
    test "unknown pattern atom falls back to separator join" do
      ex =
        make_exchange("test", %{
          spot: %{
            pattern: :totally_unknown,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTC-USDT" = Symbol.to_exchange_id("BTC/USDT", ex)
    end

    test "mixed-case spot preserves case and applies prefix" do
      ex =
        make_exchange("test", %{
          spot: %{
            pattern: :dash_mixed,
            separator: "-",
            case: :mixed,
            date_format: nil,
            suffix: nil,
            prefix: "x_"
          }
        })

      assert "x_BTC-USDT" = Symbol.to_exchange_id("BTC/USDT", ex)
    end

    test "lowercase spot applies downcase" do
      ex =
        make_exchange("test", %{
          spot: %{
            pattern: :dash_lower,
            separator: "-",
            case: :lower,
            date_format: nil,
            suffix: nil,
            prefix: nil
          }
        })

      assert "btc-usdt" = Symbol.to_exchange_id("BTC/USDT", ex)
    end

    test "future_unknown uses separator between all parts" do
      ex =
        make_exchange("test", %{
          future: %{
            pattern: :future_unknown,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTC-USDT-260327" = Symbol.to_exchange_id("BTC/USDT:USDT-260327", ex)
    end

    test "option_unknown formats base-expiry-strike-type" do
      ex =
        make_exchange("test", %{
          option: %{
            pattern: :option_unknown,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTC-260112-84000-C" = Symbol.to_exchange_id("BTC/USD:BTC-260112-84000-C", ex)
    end

    test "strip_pattern_prefix matches case-insensitively and ignores non-matching prefix" do
      with_prefix =
        make_exchange("test", %{
          spot: %{
            pattern: :no_separator_upper,
            separator: "",
            case: :upper,
            date_format: nil,
            suffix: nil,
            prefix: "pi_"
          }
        })

      # Inbound: prefix stripped when present
      assert "BTC/USD" = Symbol.from_exchange_id("PI_BTCUSD", with_prefix, :spot)
      # Inbound: non-matching prefix left intact, then no-separator split still applies
      assert "XXBTC/USD" = Symbol.from_exchange_id("XXBTCUSD", with_prefix, :spot)

      # Outbound applies prefix
      assert "pi_BTCUSD" = Symbol.to_exchange_id("BTC/USD", with_prefix)
    end
  end

  describe "reverse_pattern edge cases via from_exchange_id/3" do
    test "unknown market type returns id unchanged" do
      ex = make_exchange("test", %{spot: @no_sep_upper, custom: @no_sep_upper})
      # market_type atom present in map but not :spot/:swap/:future/:option
      assert "BTCUSDT" = Symbol.from_exchange_id("BTCUSDT", ex, :custom)
    end

    test "spot with separator that does not split returns id unchanged" do
      ex =
        make_exchange("test", %{
          spot: %{
            pattern: :dash_upper,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTCUSDT" = Symbol.from_exchange_id("BTCUSDT", ex, :spot)
    end

    test "swap with multi-part remainder after separator returns id unchanged" do
      ex =
        make_exchange("test", %{
          swap: %{
            pattern: :implicit,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTC-USDT-EXTRA" = Symbol.from_exchange_id("BTC-USDT-EXTRA", ex, :swap)
    end

    test "future with unknown date_format returns id unchanged" do
      ex =
        make_exchange("test", %{
          future: %{
            pattern: :future_unknown,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTC-16JAN26" = Symbol.from_exchange_id("BTC-16JAN26", ex, :future)
    end

    test "ddmmmyy future that matches neither Bybit nor Deribit returns id" do
      ex =
        make_exchange("test", %{
          future: %{
            pattern: :future_ddmmmyy,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      assert "NOT-A-FUTURE" = Symbol.from_exchange_id("NOT-A-FUTURE", ex, :future)
    end

    test "yymmdd future three-part path and fallback" do
      ex =
        make_exchange("test", %{
          future: %{
            pattern: :future_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTC/USD:BTC-260327" = Symbol.from_exchange_id("BTC-USD-260327", ex, :future)
      assert "BTC-USD-USDT-260327" = Symbol.from_exchange_id("BTC-USD-USDT-260327", ex, :future)
    end

    test "yyyymmdd future unparsable shape returns id" do
      ex =
        make_exchange("test", %{
          future: %{
            pattern: :future_yyyymmdd,
            separator: "-",
            case: :upper,
            date_format: :yyyymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      assert "BTC-USD" = Symbol.from_exchange_id("BTC-USD", ex, :future)
    end

    test "option reverse fails soft and unknown pattern returns id" do
      deribit =
        make_exchange("test", %{
          option: %{
            pattern: :option_ddmmmyy,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      okx =
        make_exchange("test", %{
          option: %{
            pattern: :option_yymmdd,
            separator: "-",
            case: :upper,
            date_format: :yymmdd,
            suffix: nil,
            prefix: nil
          }
        })

      bybit =
        make_exchange("test", %{
          option: %{
            pattern: :option_with_settle,
            separator: "-",
            case: :upper,
            date_format: :ddmmmyy,
            suffix: nil,
            prefix: nil
          }
        })

      unknown =
        make_exchange("test", %{
          option: %{
            pattern: :option_unknown,
            separator: "-",
            case: :upper,
            date_format: nil,
            suffix: nil,
            prefix: nil
          }
        })

      assert "NOT-AN-OPTION" = Symbol.from_exchange_id("NOT-AN-OPTION", deribit, :option)
      assert "NOT-AN-OPTION" = Symbol.from_exchange_id("NOT-AN-OPTION", okx, :option)
      assert "NOT-AN-OPTION" = Symbol.from_exchange_id("NOT-AN-OPTION", bybit, :option)
      assert "BTC-12JAN26-84000-C" = Symbol.from_exchange_id("BTC-12JAN26-84000-C", unknown, :option)
    end

    test "no-separator split prefers alias-known base among multiple quote matches" do
      # BTCBUSD ends with both BUSD and USD → multiple matches; aliases pick BUSD base "BTC"
      with_aliases =
        make_exchange("test", %{spot: @no_sep_upper}, %{"BTC" => "BTC", "BT" => "BT"})

      assert "BTC/BUSD" = Symbol.from_exchange_id("BTCBUSD", with_aliases, :spot)

      # Without aliases, first (longest-first quote list) match wins
      no_aliases = make_exchange("test", %{spot: @no_sep_upper}, %{})
      assert "BTC/BUSD" = Symbol.from_exchange_id("BTCBUSD", no_aliases, :spot)
    end
  end

  defp recorded_markets!(exchange) do
    path = Bourse.RecordedResponseFixtures.fixture_path(exchange.id, :fetch_markets)
    assert File.regular?(path), "#{exchange.id}: missing recorded fetch_markets fixture"

    fixture = Bourse.RecordedResponseFixtures.load_fixture!(path)

    fixture
    |> recorded_market_responses()
    |> Enum.flat_map(&parse_recorded_markets!(exchange, fixture, &1))
  end

  defp recorded_market_responses(%{"responses" => responses}) when is_list(responses), do: responses
  defp recorded_market_responses(%{"body" => _body} = fixture), do: [fixture]

  defp parse_recorded_markets!(exchange, fixture, response) do
    params = response["params"] || fixture["params"] || %{}

    case ReadParse.parse(
           exchange,
           exchange.module,
           :fetch_markets,
           "fetchMarkets",
           response["body"],
           params,
           :parse_market,
           true
         ) do
      {:ok, markets} when is_list(markets) -> markets
      {:ok, %Bourse.Market{} = market} -> [market]
      {:ok, other} -> flunk("#{exchange.id}: expected a market list, got: #{inspect(other)}")
      {:error, reason} -> flunk("#{exchange.id}: fetch_markets fixture failed to parse: #{inspect(reason)}")
    end
  end
end
