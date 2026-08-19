defmodule Bourse.Unified.ReadParseTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.RawResponse
  alias Bourse.Unified.FieldMaps
  alias Bourse.Unified.ReadParse

  defmodule NativeSymbolParser do
    @moduledoc false

    @symbol_parse_types Enum.filter(FieldMaps.parse_types(), fn parse_type ->
                          parse_type
                          |> FieldMaps.struct_for()
                          |> struct()
                          |> Map.has_key?(:symbol)
                        end)

    def __response_envelopes__, do: %{}
    def symbol_parse_types, do: @symbol_parse_types

    for parse_type <- @symbol_parse_types do
      parser = String.to_atom("parse_#{parse_type}")
      target = FieldMaps.struct_for(parse_type)

      def unquote(parser)(body, _opts) when is_map(body) do
        symbol = if unquote(target) == Bourse.Market, do: nil, else: body["symbol"]
        {:ok, struct(unquote(target), symbol: symbol, info: body)}
      end
    end
  end

  defmodule NoFieldMapParser do
    @moduledoc false

    def __response_envelopes__, do: %{}
    def parse_ticker(_body, _opts), do: {:error, :no_field_map}
  end

  defmodule RawMapFundingHistoryParser do
    @moduledoc false

    def __response_envelopes__, do: %{}
    def parse_funding_history(_body, _opts), do: {:error, :no_field_map}
  end

  defmodule UnresolvedTickerParser do
    @moduledoc false

    def __response_envelopes__, do: %{}
    def parse_ticker(_body, _opts), do: {:error, {:unresolved, "identifier_return"}}

    def __field_maps__ do
      %{
        "ticker" => %{
          "_unresolved_reason" => "identifier_return",
          "field_map" => %{"last" => %{"coercion" => "safeNumber", "key" => "lastPrice"}}
        }
      }
    end
  end

  defmodule ParsedStructs do
    @moduledoc false

    def __response_envelopes__, do: %{}
    def parse_market(_body, _opts), do: {:ok, %Bourse.Market{}}
    def parse_trade(body, _opts) when is_list(body), do: {:ok, Enum.map(body, &trade_from_raw/1)}
    def parse_trade(_body, _opts), do: {:ok, %Bourse.Trade{price: 42.0}}

    defp trade_from_raw(%{"price" => price, "timestamp" => timestamp}) do
      %Bourse.Trade{price: price, timestamp: timestamp}
    end
  end

  # Currency-scoped list parsers: rows are symbol-less structs. Used to pin that
  # a misplaced symbol:/symbols: param does not KeyError in filter_requested_symbols
  # (task 262) — the filter is ignored for rows without a `:symbol` key.
  defmodule CurrencyScopedParsers do
    @moduledoc false

    def __response_envelopes__, do: %{}

    def parse_transaction(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(
         rows,
         &%Bourse.Transaction{id: &1["id"], currency: &1["currency"], amount: 1.0, type: "deposit", info: &1}
       )}
    end

    def parse_ledger_entry(rows, _opts) when is_list(rows) do
      {:ok, Enum.map(rows, &%Bourse.LedgerEntry{id: &1["id"], currency: &1["currency"], amount: 1.0, info: &1})}
    end

    def parse_transfer(rows, _opts) when is_list(rows) do
      {:ok, Enum.map(rows, &%Bourse.TransferEntry{id: &1["id"], currency: &1["currency"], amount: 1.0, info: &1})}
    end

    def parse_deposit_address(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(
         rows,
         &%Bourse.DepositAddress{
           currency: &1["currency"],
           address: &1["address"],
           network: &1["network"],
           info: &1
         }
       )}
    end
  end

  defmodule CatalogDepositAddressParser do
    @moduledoc false

    @rule %{
      "kind" => "network_code",
      "network_aliases" => %{"USDT-FROZEN" => "FROZEN"}
    }

    def __response_envelopes__, do: %{}

    def __field_maps__ do
      %{
        "deposit_address" => %{
          "field_map" => %{
            "address" => %{"key" => "addr"},
            "currency" => %{"key" => "ccy"},
            "network" => @rule
          }
        }
      }
    end

    def parse_deposit_address(body, opts) do
      Bourse.Parser.parse(body, __field_maps__()["deposit_address"], Bourse.DepositAddress, opts)
    end
  end

  defmodule MarketFeeParser do
    @moduledoc false

    @field_map %{
      "field_map" => %{
        "maker" => %{"coercion" => "safeNumber", "key" => "maker"},
        "percentage" => %{"default" => true},
        "symbol" => %{"coercion" => "safeString", "key" => "symbol"},
        "taker" => %{"coercion" => "safeNumber", "key" => "taker"},
        "tierBased" => %{"default" => true}
      }
    }

    def __field_maps__, do: %{"trading_fee" => @field_map}

    def __response_envelopes__ do
      %{
        "trading_fee" => %{
          "fetchTradingFees" => %{
            "key" => "result",
            "transform" => %{
              "kind" => "market_fee_rows",
              "market_type_map" => %{"future" => "future", "swap" => "perpetual"}
            }
          }
        }
      }
    end

    def parse_trading_fee(body, opts) do
      Bourse.Parser.parse(body, @field_map, Bourse.TradingFee, opts)
    end
  end

  # Trades with pre-set symbols so multi-symbol filtering can be exercised without
  # request-symbol backfill stamping the same symbol onto every row.
  defmodule SymbolFilterTradeParser do
    @moduledoc false

    def __response_envelopes__, do: %{}

    def parse_trade(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(rows, fn row ->
         %Bourse.Trade{symbol: row["symbol"], price: Bourse.Safe.number(row["price"]), info: row}
       end)}
    end
  end

  defmodule OpenInterestParser do
    @moduledoc false

    def __response_envelopes__, do: %{}
    def parse_open_interest(_body, _opts), do: {:ok, %Bourse.OpenInterest{open_interest_value: 9_978_637_780}}
  end

  defmodule OpenInterestListEnvelopeParser do
    @moduledoc false

    def __response_envelopes__ do
      %{"open_interest" => %{"fetchOpenInterest" => %{"key" => "result.list", "default" => []}}}
    end

    def parse_open_interest(%{"openInterest" => value}, _opts) do
      {:ok, %Bourse.OpenInterest{open_interest_amount: Bourse.Safe.number(value)}}
    end
  end

  defmodule FeeTradeParser do
    @moduledoc false

    def __response_envelopes__, do: %{}
    def parse_trade(%{"with_fee" => "no_rate"}, _opts), do: {:ok, fee_trade(%{"cost" => "0.5", "currency" => "USDT"})}

    def parse_trade(%{"with_fee" => true}, _opts),
      do: {:ok, fee_trade(%{"cost" => "0.5", "currency" => "USDT", "rate" => "0.001"})}

    def parse_trade(_body, _opts), do: {:ok, %Bourse.Trade{price: 1.0}}

    defp fee_trade(fee), do: %Bourse.Trade{price: 1.0, fee: fee}
  end

  defmodule ColumnarOhlcvParser do
    @moduledoc false

    def __response_envelopes__ do
      %{
        "ohlcv" => %{
          "fetchOHLCV" => %{
            "key" => "result",
            "transform" => "transpose_columns",
            "columns" => ["ticks", "open", "high", "low", "close", "volume"]
          }
        }
      }
    end
  end

  defmodule RowOhlcvParser do
    @moduledoc false

    def __response_envelopes__, do: %{}
  end

  defmodule CoinbaseOhlcvParser do
    @moduledoc false

    def __response_envelopes__ do
      %{
        "ohlcv" => %{
          "fetchOHLCV" => %{
            "order" => "newest_first",
            "row_columns" => ~w(timestamp low high open close volume),
            "timestamp_unit" => "seconds"
          }
        }
      }
    end
  end

  defmodule MillisecondRowColumnsOhlcvParser do
    @moduledoc false

    def __response_envelopes__ do
      %{
        "ohlcv" => %{
          "fetchOHLCV" => %{
            "row_columns" => ~w(timestamp low high open close volume),
            "timestamp_unit" => "milliseconds"
          }
        }
      }
    end
  end

  # Currency fakes: each builds a partial Currency per raw entry; `code`/`info`
  # are filled by ReadParse (Bourse `safeCurrencyCode` + raw `info`), not the parser.
  defmodule ResultEnvelopeCurrencyParser do
    @moduledoc false

    def __response_envelopes__ do
      %{"currency" => %{"fetchCurrencies" => %{"key" => "result"}}}
    end

    def parse_currency(entries, _opts) when is_list(entries) do
      {:ok, Enum.map(entries, fn raw -> %Bourse.Currency{id: raw["currency"], name: raw["name"]} end)}
    end
  end

  # A different venue: no envelope key (the body is already the currency list) —
  # proves the envelope unwrap is config-driven, not a hardcoded "result".
  defmodule BareListCurrencyParser do
    @moduledoc false

    def __response_envelopes__, do: %{}

    def parse_currency(entries, _opts) when is_list(entries) do
      {:ok, Enum.map(entries, fn raw -> %Bourse.Currency{id: raw["asset"]} end)}
    end
  end

  describe "parse/8 currency (code-keyed dict)" do
    test "unwraps the result envelope and re-keys structs by uppercased code, setting info" do
      exchange = Exchange.new!("deribit")

      body = %{
        "result" => [
          %{"currency" => "XRP", "name" => "XRP"},
          %{"currency" => "USDT", "name" => "Tether"}
        ]
      }

      assert {:ok, parsed} =
               ReadParse.parse(
                 exchange,
                 ResultEnvelopeCurrencyParser,
                 :fetch_currencies,
                 "fetchCurrencies",
                 body,
                 %{},
                 :parse_currency,
                 false
               )

      assert %{"XRP" => xrp, "USDT" => usdt} = parsed
      assert xrp.code == "XRP"
      assert xrp.id == "XRP"
      assert xrp.info == %{"currency" => "XRP", "name" => "XRP"}
      assert usdt.code == "USDT" and usdt.name == "Tether"
    end

    test "applies common-currency aliases when deriving code (xbt -> BTC)" do
      exchange = Exchange.new!("deribit")
      body = %{"result" => [%{"currency" => "xbt"}]}

      assert {:ok, %{"BTC" => btc}} =
               ReadParse.parse(
                 exchange,
                 ResultEnvelopeCurrencyParser,
                 :fetch_currencies,
                 "fetchCurrencies",
                 body,
                 %{},
                 :parse_currency,
                 false
               )

      assert btc.code == "BTC" and btc.id == "xbt"
    end

    test "handles an un-enveloped list body (cross-venue, no deribit overfit)" do
      exchange = Exchange.new!("derive")
      body = [%{"asset" => "ETH"}, %{"asset" => "SOL"}]

      assert {:ok, parsed} =
               ReadParse.parse(
                 exchange,
                 BareListCurrencyParser,
                 :fetch_currencies,
                 "fetchCurrencies",
                 body,
                 %{},
                 :parse_currency,
                 false
               )

      assert parsed |> Map.keys() |> Enum.sort() == ["ETH", "SOL"]
      assert parsed["ETH"].info == %{"asset" => "ETH"}
    end

    test "an empty currency payload yields an empty map" do
      exchange = Exchange.new!("deribit")

      assert {:ok, %{}} ==
               ReadParse.parse(
                 exchange,
                 ResultEnvelopeCurrencyParser,
                 :fetch_currencies,
                 "fetchCurrencies",
                 %{"result" => []},
                 %{},
                 :parse_currency,
                 false
               )
    end

    test "rejects a jsonrpc error envelope before parsing currencies" do
      exchange = Exchange.new!("deribit")
      body = %{"error" => %{"code" => -32_602, "message" => "Invalid params"}}

      assert {:error, %Error{type: :exchange_error}} =
               ReadParse.parse(
                 exchange,
                 ResultEnvelopeCurrencyParser,
                 :fetch_currencies,
                 "fetchCurrencies",
                 body,
                 %{},
                 :parse_currency,
                 false
               )
    end
  end

  describe "Bybit category-aware native symbols" do
    test "resolves identical native ids by response category before filtering" do
      exchange = Exchange.new!("bybit")

      assert {:ok, [%Bourse.Order{symbol: "BTC/USDT", status: "open"}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_open_orders,
                 "fetchOpenOrders",
                 bybit_order_response("spot"),
                 %{"symbol" => "BTC/USDT"},
                 :parse_order,
                 true
               )

      assert {:ok, [%Bourse.Order{symbol: "BTC/USDT:USDT", status: "open"}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_open_orders,
                 "fetchOpenOrders",
                 bybit_order_response("linear"),
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_order,
                 true
               )
    end

    # The position parse type pre-computes notional/margin keys; that annotation
    # must not shadow the response-category injection, or an option position's
    # native id resolves as a swap and the requested-symbol filter empties the read.
    test "resolves an option position native id via the response category" do
      exchange = Exchange.new!("bybit")

      assert {:ok, [%Bourse.Position{symbol: "BTC/USDC:USDC-250131-100000-C"}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 bybit_option_position_response(),
                 %{"symbol" => "BTC/USDC:USDC-250131-100000-C"},
                 :parse_position,
                 true
               )
    end

    test "normalizes every symbol-bearing parse type without a parse-type allowlist" do
      exchange = Exchange.new!("bybit")

      body = %{
        "baseCoin" => "0G",
        "category" => "linear",
        "contractType" => "LinearPerpetual",
        "quoteCoin" => "USDT",
        "settleCoin" => "USDT",
        "symbol" => "0GUSDT"
      }

      for parse_type <- NativeSymbolParser.symbol_parse_types() do
        parser = String.to_existing_atom("parse_#{parse_type}")

        assert {:ok, %{symbol: "0G/USDT:USDT"}} =
                 ReadParse.parse(
                   exchange,
                   NativeSymbolParser,
                   :fetch_ticker,
                   "symbolInvariantProbe",
                   body,
                   %{},
                   parser,
                   false
                 ),
               parse_type
      end
    end

    test "fails loudly when an ambiguous native id has no row market family" do
      assert {:error, %Error{message: message}} =
               ReadParse.parse(
                 Exchange.new!("bybit"),
                 NativeSymbolParser,
                 :fetch_leverage_tiers,
                 "symbolInvariantProbe",
                 %{"symbol" => "0GUSDT"},
                 %{},
                 :parse_leverage_tiers,
                 false
               )

      assert message =~ "Cannot resolve unified symbol"
      assert message =~ "0GUSDT"
    end
  end

  defp bybit_option_position_response do
    %{
      "retCode" => 0,
      "result" => %{
        "category" => "option",
        "list" => [
          %{
            "avgPrice" => "500",
            "createdTime" => "1784189372501",
            "markPrice" => "510",
            "positionValue" => "50",
            "side" => "Buy",
            "size" => "0.1",
            "symbol" => "BTC-31JAN25-100000-C",
            "unrealisedPnl" => "1",
            "updatedTime" => "1784189372501"
          }
        ]
      }
    }
  end

  defp bybit_order_response(category) do
    %{
      "retCode" => 0,
      "result" => %{
        "category" => category,
        "list" => [
          %{
            "avgPrice" => "",
            "createdTime" => "1784189372501",
            "cumExecQty" => "0",
            "cumExecValue" => "0",
            "orderId" => "demo-order-1",
            "orderStatus" => "New",
            "orderType" => "Limit",
            "price" => "10000",
            "qty" => "0.001",
            "side" => "Buy",
            "symbol" => "BTCUSDT",
            "updatedTime" => "1784189372501"
          }
        ]
      }
    }
  end

  describe "parse/8 OHLCV (array-shaped)" do
    test "transposes a columnar envelope payload to coerced [ts,o,h,l,c,v] rows" do
      exchange = Exchange.new!("deribit")

      body = %{
        "jsonrpc" => "2.0",
        "result" => %{
          "ticks" => [1, 2],
          "open" => [10, 11],
          "high" => [12, 13],
          "low" => [9, 8],
          "close" => [11, 12],
          "volume" => [0.5, 0.6],
          "cost" => [5, 6]
        }
      }

      assert {:ok, [[1, 10, 12, 9, 11, 0.5], [2, 11, 13, 8, 12, 0.6]]} =
               ReadParse.parse(
                 exchange,
                 ColumnarOhlcvParser,
                 :fetch_ohlcv,
                 "fetchOHLCV",
                 body,
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_ohlcv,
                 true
               )
    end

    test "passes a row-shaped body through, coercing string numbers (cross-venue, no deribit overfit)" do
      exchange = Exchange.new!("binance")
      body = [["1710327600000", "10", "12", "9", "11", "0.5"]]

      assert {:ok, [[1_710_327_600_000, 10.0, 12.0, 9.0, 11.0, 0.5]]} =
               ReadParse.parse(
                 exchange,
                 RowOhlcvParser,
                 :fetch_ohlcv,
                 "fetchOHLCV",
                 body,
                 %{},
                 :parse_ohlcv,
                 true
               )
    end

    test "reorders Coinbase columns, scales seconds, and normalizes newest-first rows" do
      exchange = Exchange.new!("binance")
      body = [[1_710_327_660, "9", "12", "10", "11", "0.6"], [1_710_327_600, "8", "11", "9", "10", "0.5"]]

      assert {:ok,
              [
                [1_710_327_600_000, 9.0, 11.0, 8.0, 10.0, 0.5],
                [1_710_327_660_000, 10.0, 12.0, 9.0, 11.0, 0.6]
              ]} =
               ReadParse.parse(
                 exchange,
                 CoinbaseOhlcvParser,
                 :fetch_ohlcv,
                 "fetchOHLCV",
                 body,
                 %{},
                 :parse_ohlcv,
                 true
               )
    end

    test "row_columns without a seconds timestamp_unit raises instead of parsing positionally" do
      exchange = Exchange.new!("binance")
      body = [[1_710_327_600_000, "8", "11", "9", "10", "0.5"]]

      assert_raise ArgumentError, ~r/row_columns requires list rows and timestamp_unit "seconds"/, fn ->
        ReadParse.parse(
          exchange,
          MillisecondRowColumnsOhlcvParser,
          :fetch_ohlcv,
          "fetchOHLCV",
          body,
          %{},
          :parse_ohlcv,
          true
        )
      end
    end

    test "rejects a jsonrpc error envelope before transposing" do
      exchange = Exchange.new!("deribit")
      body = %{"error" => %{"code" => -32_602, "message" => "Invalid params"}}

      assert {:error, %Error{type: :exchange_error}} =
               ReadParse.parse(
                 exchange,
                 ColumnarOhlcvParser,
                 :fetch_ohlcv,
                 "fetchOHLCV",
                 body,
                 %{},
                 :parse_ohlcv,
                 true
               )
    end
  end

  describe "parse/8 volatility_history (array-of-pairs)" do
    defmodule VolatilityHistoryEnvelopeParser do
      @moduledoc false

      def __response_envelopes__ do
        %{
          "volatility_history" => %{
            "fetchVolatilityHistory" => %{"key" => "result", "default" => [], "fallback_keys" => []}
          }
        }
      end
    end

    test "unwraps result pairs into %VolatilityHistory{} structs" do
      exchange = Exchange.new!("deribit")
      ts = 1_640_142_000_000
      vol = 63.828320460740585

      body = %{
        "jsonrpc" => "2.0",
        "result" => [[ts, vol], [ts + 3_600_000, 64.03821964123213]],
        "testnet" => false
      }

      assert {:ok, [first, second]} =
               ReadParse.parse(
                 exchange,
                 VolatilityHistoryEnvelopeParser,
                 :fetch_volatility_history,
                 "fetchVolatilityHistory",
                 body,
                 %{"currency" => "BTC"},
                 :parse_volatility_history,
                 true
               )

      assert %Bourse.VolatilityHistory{} = first
      assert first.timestamp == ts
      assert first.datetime == Bourse.Timestamp.iso8601_from_ms(ts)
      assert first.volatility == vol
      assert first.info == [ts, vol]
      assert second.timestamp == ts + 3_600_000
      assert is_number(second.volatility)
    end

    test "empty successful result returns []" do
      exchange = Exchange.new!("deribit")
      body = %{"jsonrpc" => "2.0", "result" => []}

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 VolatilityHistoryEnvelopeParser,
                 :fetch_volatility_history,
                 "fetchVolatilityHistory",
                 body,
                 %{},
                 :parse_volatility_history,
                 true
               )
    end

    test "rejects a jsonrpc error envelope" do
      exchange = Exchange.new!("deribit")
      body = %{"error" => %{"code" => -32_602, "message" => "Invalid params"}}

      assert {:error, %Error{type: :exchange_error}} =
               ReadParse.parse(
                 exchange,
                 VolatilityHistoryEnvelopeParser,
                 :fetch_volatility_history,
                 "fetchVolatilityHistory",
                 body,
                 %{},
                 :parse_volatility_history,
                 true
               )
    end
  end

  describe "parse/8" do
    # Task 367 filters symbol-keyed results (fetchTickers) client-side. Structs
    # are maps too, so an unguarded map clause routes a SINGULAR parse into the
    # enumerable filter and raises `Enumerable not implemented`. Pin that a
    # single-struct return with a symbol filter passes through untouched.
    for {label, params} <- [
          {"singular symbol", %{"symbol" => "BTC/USDT"}},
          {"symbols list", %{"symbols" => ["BTC/USDT"]}}
        ] do
      test "passes a single-struct return through the request filters (#{label})" do
        assert {:ok, %Bourse.Trade{price: 42.0}} =
                 ReadParse.parse(
                   Exchange.new!("binance"),
                   ParsedStructs,
                   :fetch_trades,
                   "fetchTrades",
                   %{"price" => "42.0"},
                   unquote(Macro.escape(params)),
                   :parse_trade,
                   false
                 )
      end
    end

    test "selects the requested Binance inverse position and derives margin mode from isolated" do
      exchange =
        "binance"
        |> Exchange.new!()
        |> Exchange.put_markets([%{"id" => "BTCUSD_PERP", "symbol" => "BTC/USD:BTC"}])

      body = %{
        "positions" => [
          %{"symbol" => "ETHUSD_PERP", "isolated" => true},
          %{"symbol" => "BTCUSD_PERP", "isolated" => false}
        ]
      }

      assert {:ok, %Bourse.MarginMode{symbol: "BTC/USD:BTC", margin_mode: "cross"}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_margin_mode,
                 "fetchMarginMode",
                 body,
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_margin_mode,
                 false
               )
    end

    test "keeps the flat Binance marginType response for linear margin mode" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.MarginMode{symbol: "BTC/USDT:USDT", margin_mode: "isolated"}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_margin_mode,
                 "fetchMarginMode",
                 %{"marginType" => "ISOLATED"},
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_margin_mode,
                 false
               )
    end

    # `GET /fapi/v1/positionRisk` answers with a bare row list, which is the
    # shape Bourse's own `linear swap fetch margin mode` fixture records. The
    # inverse `positions[]` envelope must not make that list body unparseable.
    test "parses the Binance linear positionRisk list body for margin mode" do
      exchange = Exchange.new!("binance")

      body = [
        %{
          "symbol" => "BTCUSDT",
          "marginType" => "CROSSED",
          "isAutoAddMargin" => false,
          "leverage" => "20",
          "maxNotionalValue" => "100000000"
        }
      ]

      assert {:ok, %Bourse.MarginMode{symbol: "BTC/USDT:USDT", margin_mode: "cross"}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_margin_mode,
                 "fetchMarginMode",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_margin_mode,
                 false
               )
    end

    test "rejects jsonrpc error envelopes" do
      exchange = Exchange.new!("derive")
      body = %{"error" => %{"code" => -32_602, "message" => "Invalid params"}}

      assert {:error, %Error{type: :exchange_error}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Derive,
                 :fetch_ticker,
                 "fetchTicker",
                 body,
                 %{"symbol" => "BTC/USDC"},
                 :parse_ticker,
                 false
               )
    end

    test "rejects all-nil single-object parses before symbol backfill" do
      exchange = Exchange.new!("okx")
      body = [%{}]

      assert {:error, %Error{type: :exchange_error, message: message}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_trades,
                 "fetchTrades",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 true
               )

      assert message =~ "Unexpected response shape"
      assert message =~ "all-nil"
    end

    test "incomplete currency mapping returns a labelled raw provider payload" do
      exchange = Exchange.new!("binanceusdm")
      body = [%{"coin" => "USDC", "name" => "USD Coin", "networkList" => []}]

      assert {:ok,
              %RawResponse{
                payload: ^body,
                venue: "binanceusdm",
                method: "fetchCurrencies",
                verification: :unverified
              }} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binanceusdm,
                 :fetch_currencies,
                 "fetchCurrencies",
                 body,
                 %{},
                 :parse_currency,
                 false
               )
    end

    test "missing funding_history field map fails as data instead of raising during symbol backfill" do
      exchange = Exchange.new!("binanceusdm")
      body = [%{"symbol" => "BTCUSDT", "income" => "-0.01", "asset" => "USDT", "time" => "1"}]

      assert {:error, %Error{type: :exchange_error, message: message}} =
               ReadParse.parse(
                 exchange,
                 __MODULE__.RawMapFundingHistoryParser,
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_funding_history,
                 true
               )

      assert message =~ "No field map available"
      assert message =~ "fetch_funding_history"
      refute message =~ "key :symbol not found"
    end

    test "fetchMarginAdjustmentHistory returns a parsed list, not the Req HTTP envelope (task 321)" do
      exchange = Exchange.new!("binanceusdm")

      # Unified dispatch used to return the whole Req envelope when
      # MarginModification had no parse slot. Pin the parse path never does that.
      body = [
        %{
          "symbol" => "XRPUSDT",
          "type" => "1",
          "deltaType" => "TRADE",
          "amount" => "2.57148240",
          "asset" => "USDT",
          "time" => "1711046271555",
          "positionSide" => "BOTH",
          "clientTranId" => ""
        }
      ]

      assert {:ok, [%Bourse.MarginModification{} = row]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binanceusdm,
                 :fetch_margin_adjustment_history,
                 "fetchMarginAdjustmentHistory",
                 body,
                 %{"symbol" => "XRP/USDT:USDT"},
                 :parse_margin_modification,
                 true
               )

      assert row.type == "add"
      assert row.margin_mode == "isolated"
      assert row.status == "ok"
      assert row.code == "USDT"
      assert row.amount == 2.5714824
      assert row.symbol == "XRP/USDT:USDT"
      # Must be a MarginModification struct, not the Req HTTP envelope map.
      assert is_struct(row, Bourse.MarginModification)
      # Envelope keys never leak onto the unified struct fields.
      refute Map.has_key?(Map.from_struct(row), :body)
      refute Map.has_key?(Map.from_struct(row), :headers)
    end

    test "rejects a foreign body with none of the mapped fields (never {:ok, all-nil})" do
      # Live-observed class: bybit /v5/account/info body fed to parse_order produced
      # an all-nil Order whose only non-nil fields were structural defaults
      # (fees: [], trades: []). That must be a hard error naming the shape.
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "marginMode" => "REGULAR_MARGIN",
          "unifiedMarginStatus" => 4,
          "dcpStatus" => "OFF"
        }
      }

      assert {:error, %Error{type: :exchange_error, message: message, raw: raw}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_order,
                 "fetchOrder",
                 body,
                 %{},
                 :parse_order,
                 false
               )

      assert message =~ "Unexpected response shape"
      assert %Bourse.Order{id: nil, symbol: nil, status: nil, trades: [], fees: []} = raw
    end

    test "list payload with N rows parses to N structs, never one folded struct" do
      # OKX-style envelope without an authored transfer envelope: data holds N
      # real rows. Folding the outer map into one TransferEntry must not happen.
      exchange = Exchange.new!("okx")

      body = %{
        "code" => "0",
        "data" => [
          %{"transId" => "1", "ccy" => "USDT", "amt" => "10", "from" => "6", "to" => "18", "state" => "success"},
          %{"transId" => "2", "ccy" => "BTC", "amt" => "0.1", "from" => "18", "to" => "6", "state" => "success"},
          %{"transId" => "3", "ccy" => "ETH", "amt" => "1", "from" => "6", "to" => "18", "state" => "success"}
        ]
      }

      assert {:ok, transfers} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_transfers,
                 "fetchTransfers",
                 body,
                 %{},
                 :parse_transfer,
                 true
               )

      assert is_list(transfers)
      assert length(transfers) == 3
      assert Enum.all?(transfers, &is_struct(&1, Bourse.TransferEntry))
      assert Enum.map(transfers, & &1.id) == ["1", "2", "3"]
      assert Enum.map(transfers, & &1.amount) == [10.0, 0.1, 1.0]
    end

    test "empty bybit deposit/withdrawal collection under result.rows is {:ok, []}" do
      # Live history-less testnet: retCode 0 + result.rows: [] must not raise
      # all-nil Transaction (authored envelope key is result.list; rows is the
      # sibling collection key the deposit endpoints actually use).
      exchange = Exchange.new!("bybit")
      body = %{"retCode" => 0, "retMsg" => "OK", "result" => %{"rows" => []}}

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_deposits,
                 "fetchDeposits",
                 body,
                 %{},
                 :parse_transaction,
                 true
               )

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_withdrawals,
                 "fetchWithdrawals",
                 body,
                 %{},
                 :parse_transaction,
                 true
               )
    end

    test "backfills ticker symbol after successful parse" do
      exchange = Exchange.new!("binance")
      body = %{"lastPrice" => "65000.00", "symbol" => "BTCUSDT"}

      assert {:ok, %Bourse.Ticker{symbol: "BTC/USDT", last: 65_000.0}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_ticker,
                 "fetchTicker",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_ticker,
                 false
               )
    end

    test "no-field-map returns a typed error naming the venue and method" do
      exchange = Exchange.new!("binance")

      data = %{"lastPrice" => "65000.00"}

      assert {:error, %Error{exchange: "binance", message: message, raw: ^data}} =
               ReadParse.parse(
                 exchange,
                 NoFieldMapParser,
                 :fetch_ticker,
                 "fetchTicker",
                 data,
                 %{"symbol" => "BTC/USDT"},
                 :parse_ticker,
                 false
               )

      assert message =~ "No field map available"
      assert message =~ "fetch_ticker"
    end

    test "retries unresolved parser output with the partial mapping stripped" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Ticker{last: 65_000.0}} =
               ReadParse.parse(
                 exchange,
                 UnresolvedTickerParser,
                 :fetch_ticker,
                 "fetchTicker",
                 %{"lastPrice" => "65000.00"},
                 %{},
                 :parse_ticker,
                 false
               )
    end

    test "backfills trade symbol after successful single-object parse" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Trade{symbol: "BTC/USDT", price: 42.0}} =
               ReadParse.parse(
                 exchange,
                 ParsedStructs,
                 :fetch_trade,
                 "fetchTrade",
                 %{"price" => "42"},
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 false
               )
    end

    test "backfills market symbol from the raw market entry" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Market{symbol: "BTC/USDT"}} =
               ReadParse.parse(
                 exchange,
                 ParsedStructs,
                 :fetch_markets,
                 "fetchMarkets",
                 %{"baseAsset" => "BTC", "quoteAsset" => "USDT"},
                 %{},
                 :parse_market,
                 false
               )
    end

    test "allows an empty list payload for list-return parses" do
      exchange = Exchange.new!("bybit")

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_markets,
                 "fetchMarkets",
                 %{"retCode" => 0, "result" => %{"list" => []}},
                 %{},
                 :parse_market,
                 true
               )
    end

    # Task 499: the static-fee trigger is the authored `fees.static_market_fees`
    # opt-in, not a venue-id list in lib/. Both directions are exercised on the
    # SAME venue so the only variable is the authored signal.
    test "an authored static-fee signal populates market maker/taker for any venue (task 499)" do
      base = Exchange.new!("bybit")
      opted_in = %{base | fees: %{base.fees | static_market_fees: true}}

      assert {:ok, [%Bourse.Market{} = market]} =
               ReadParse.parse(
                 opted_in,
                 Bourse.Bybit,
                 :fetch_markets,
                 "fetchMarkets",
                 %{
                   "retCode" => 0,
                   "result" => %{"list" => [%{"symbol" => "BTCUSDT", "baseCoin" => "BTC", "quoteCoin" => "USDT"}]}
                 },
                 %{},
                 :parse_market,
                 true
               )

      # Bybit's own authored `fees.trading` block — read generically, no venue id
      # appears in `apply_static_trading_fees/2`.
      assert market.maker == base.fees.trading.maker
      assert market.taker == base.fees.trading.taker
    end

    test "a venue without the authored static-fee signal keeps nil maker/taker (task 499)" do
      exchange = Exchange.new!("bybit")

      assert exchange.fees.static_market_fees == false
      assert is_number(exchange.fees.trading.maker), "a fees.trading block alone must not be the trigger"

      assert {:ok, [%Bourse.Market{} = market]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_markets,
                 "fetchMarkets",
                 %{
                   "retCode" => 0,
                   "result" => %{"list" => [%{"symbol" => "BTCUSDT", "baseCoin" => "BTC", "quoteCoin" => "USDT"}]}
                 },
                 %{},
                 :parse_market,
                 true
               )

      assert is_nil(market.maker)
      assert is_nil(market.taker)
    end

    test "deribit empty transfer history unwraps result.data as an empty list" do
      exchange = Exchange.new!("deribit")

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_transfers,
                 "fetchTransfers",
                 %{"jsonrpc" => "2.0", "result" => %{"count" => 0, "data" => []}},
                 %{"code" => "BTC"},
                 :parse_transfer,
                 true
               )
    end

    test "backfills hyperliquid market symbol from the name field" do
      exchange = Exchange.new!("hyperliquid")

      assert {:ok, [%Bourse.Market{symbol: "BTC/USDC:USDC"}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Hyperliquid,
                 :fetch_markets,
                 "fetchMarkets",
                 %{
                   "universe" => [
                     %{"name" => "BTC", "maxLeverage" => 50, "szDecimals" => 5}
                   ]
                 },
                 %{},
                 :parse_market,
                 true
               )
    end

    test "build_tickers_from_meta_asset_ctxs keys tickers by carved market symbols" do
      exchange = Exchange.new!("hyperliquid")

      meta = %{
        "universe" => [
          %{"name" => "BTC", "maxLeverage" => 40, "szDecimals" => 5},
          %{"name" => "ETH", "maxLeverage" => 25, "szDecimals" => 4}
        ]
      }

      ctxs = [
        %{"markPx" => "62750.0", "midPx" => "62744.5", "dayNtlVlm" => "100"},
        %{"markPx" => "3400.0", "midPx" => "3399.5", "dayNtlVlm" => "50"}
      ]

      assert {:ok, tickers} =
               ReadParse.build_tickers_from_meta_asset_ctxs(exchange, Bourse.Hyperliquid, [meta, ctxs])

      assert %Bourse.Ticker{symbol: "BTC/USDC:USDC", last: 62_750.0} =
               Map.fetch!(tickers, "BTC/USDC:USDC")

      assert %Bourse.Ticker{symbol: "ETH/USDC:USDC", last: 3400.0} =
               Map.fetch!(tickers, "ETH/USDC:USDC")
    end

    test "index_tickers_by_markets zips nil-symbol tickers with carved markets" do
      tickers = [
        %Bourse.Ticker{symbol: nil, last: 100.0},
        %Bourse.Ticker{symbol: nil, last: 200.0}
      ]

      markets = [
        %Bourse.Market{symbol: "BTC/USDC:USDC"},
        %Bourse.Market{symbol: "ETH/USDC:USDC"}
      ]

      indexed = ReadParse.index_tickers_by_markets(tickers, markets)

      assert %Bourse.Ticker{symbol: "BTC/USDC:USDC", last: 100.0} =
               Map.fetch!(indexed, "BTC/USDC:USDC")

      assert %Bourse.Ticker{symbol: "ETH/USDC:USDC", last: 200.0} =
               Map.fetch!(indexed, "ETH/USDC:USDC")
    end

    test "index_tickers_by_markets handles map tickers without symbol keys" do
      tickers = [%{last: 100.0}]
      markets = [%Bourse.Market{symbol: "BTC/USDC:USDC"}]

      assert %{"BTC/USDC:USDC" => %{last: 100.0, symbol: "BTC/USDC:USDC"}} =
               ReadParse.index_tickers_by_markets(tickers, markets)
    end

    test "enriches binance ticker datetime and info after parsing" do
      exchange = Exchange.new!("binance")

      body = %{
        "closeTime" => 1_781_996_258_038,
        "lastPrice" => "64301.92000000",
        "quoteVolume" => "633633271.69607420",
        "symbol" => "BTCUSDT"
      }

      assert {:ok, %Bourse.Ticker{} = ticker} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binance,
                 :fetch_ticker,
                 "fetchTicker",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_ticker,
                 false
               )

      assert ticker.timestamp == 1_781_996_258_038
      assert ticker.datetime == DateTime.to_iso8601(DateTime.from_unix!(1_781_996_258_038, :millisecond))
      assert ticker.info == body
    end

    test "enriches deribit ticker info with the post-envelope raw entry" do
      exchange = Exchange.new!("deribit")

      raw_entry = %{
        "instrument_name" => "BTC-PERPETUAL",
        "last_price" => 64_044.5,
        "timestamp" => 1_781_993_751_291
      }

      body = %{"jsonrpc" => "2.0", "result" => raw_entry}

      assert {:ok, %Bourse.Ticker{} = ticker} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_ticker,
                 "fetchTicker",
                 body,
                 %{"symbol" => "BTC-PERPETUAL"},
                 :parse_ticker,
                 false
               )

      assert ticker.timestamp == 1_781_993_751_291
      assert ticker.datetime == DateTime.to_iso8601(DateTime.from_unix!(1_781_993_751_291, :millisecond))
      assert ticker.info == raw_entry
    end

    test "defaults trade fee and fees when no fee is parsed (Bourse safeTrade)" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Trade{fee: %{"cost" => nil, "currency" => nil}, fees: []}} =
               ReadParse.parse(
                 exchange,
                 FeeTradeParser,
                 :fetch_trade,
                 "fetchTrade",
                 %{"price" => "1"},
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 false
               )
    end

    test "coerces a parsed trade fee numeric and mirrors it into fees" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Trade{fee: fee, fees: fees}} =
               ReadParse.parse(
                 exchange,
                 FeeTradeParser,
                 :fetch_trade,
                 "fetchTrade",
                 %{"with_fee" => true},
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 false
               )

      assert fee == %{"cost" => 0.5, "currency" => "USDT", "rate" => 0.001}
      assert fees == [fee]
    end

    test "coerces a rate-less trade fee without inventing a rate key" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Trade{fee: %{"cost" => 0.5, "currency" => "USDT"} = fee, fees: [fee]}} =
               ReadParse.parse(
                 exchange,
                 FeeTradeParser,
                 :fetch_trade,
                 "fetchTrade",
                 %{"with_fee" => "no_rate"},
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 false
               )

      refute Map.has_key?(fee, "rate")
    end

    test "backfills open interest symbol from the request param" do
      exchange = Exchange.new!("deribit")

      assert {:ok, %Bourse.OpenInterest{symbol: "BTC/USD:BTC", open_interest_value: 9_978_637_780}} =
               ReadParse.parse(
                 exchange,
                 OpenInterestParser,
                 :fetch_open_interest,
                 "fetchOpenInterest",
                 %{"open_interest" => "9978637780"},
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_open_interest,
                 false
               )
    end

    test "single-record reads parse the first row from multi-row list envelopes" do
      exchange = Exchange.new!("bybit")

      body = %{
        "result" => %{
          "list" => [
            %{"openInterest" => "245925.636", "symbol" => "BTCUSDT"},
            %{"openInterest" => "244000.123", "symbol" => "BTCUSDT"}
          ]
        }
      }

      assert {:ok, %Bourse.OpenInterest{symbol: "BTC/USDT:USDT", open_interest_amount: 245_925.636}} =
               ReadParse.parse(
                 exchange,
                 OpenInterestListEnvelopeParser,
                 :fetch_open_interest,
                 "fetchOpenInterest",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_open_interest,
                 false
               )
    end

    test "requested symbol wins over ambiguous native id for single-symbol trade lists" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "list" => [
            %{
              "execId" => "spot-trade-1",
              "price" => "65000.5",
              "side" => "Buy",
              "size" => "0.01",
              "symbol" => "BTCUSDT",
              "time" => "1784189372501"
            }
          ]
        }
      }

      assert {:ok, [%Bourse.Trade{symbol: "BTC/USDT", price: 65_000.5}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_trades,
                 "fetchTrades",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 true
               )
    end

    # Task 262: filter_requested_symbols used unguarded `.symbol` on every list
    # row. Currency-scoped structs have no `:symbol` key — a symbol/symbols param
    # would KeyError. Chosen behavior: ignore the filter for symbol-less rows
    # (keep them); symbol-bearing rows still filter as before.
    test "currency-scoped transaction list ignores symbol filter instead of KeyError" do
      exchange = Exchange.new!("binance")
      body = [%{"id" => "1", "currency" => "BTC"}, %{"id" => "2", "currency" => "ETH"}]

      assert {:ok, [%Bourse.Transaction{id: "1"}, %Bourse.Transaction{id: "2"}]} =
               ReadParse.parse(
                 exchange,
                 CurrencyScopedParsers,
                 :fetch_deposits,
                 "fetchDeposits",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_transaction,
                 true
               )

      assert {:ok, [%Bourse.Transaction{id: "1"}, %Bourse.Transaction{id: "2"}]} =
               ReadParse.parse(
                 exchange,
                 CurrencyScopedParsers,
                 :fetch_deposits,
                 "fetchDeposits",
                 body,
                 %{"symbols" => ["BTC/USDT", "ETH/USDT"]},
                 :parse_transaction,
                 true
               )
    end

    test "currency-scoped ledger list ignores symbol filter instead of KeyError" do
      exchange = Exchange.new!("binance")
      body = [%{"id" => "led-1", "currency" => "USDT"}]

      assert {:ok, [%Bourse.LedgerEntry{id: "led-1", currency: "USDT"}]} =
               ReadParse.parse(
                 exchange,
                 CurrencyScopedParsers,
                 :fetch_ledger,
                 "fetchLedger",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_ledger_entry,
                 true
               )
    end

    test "currency-scoped transfer list ignores symbol filter instead of KeyError" do
      exchange = Exchange.new!("binance")
      body = [%{"id" => "tr-1", "currency" => "BTC"}]

      assert {:ok, [%Bourse.TransferEntry{id: "tr-1", currency: "BTC"}]} =
               ReadParse.parse(
                 exchange,
                 CurrencyScopedParsers,
                 :fetch_transfers,
                 "fetchTransfers",
                 body,
                 %{"symbols" => ["BTC/USDT"]},
                 :parse_transfer,
                 true
               )
    end

    # fetchDepositAddressesByNetwork returns a network-keyed dict (bybit.ts:
    # `indexBy(parsed, 'network')`), so the symbol filter must not KeyError on a
    # currency-scoped struct on the way to that shape.
    test "currency-scoped deposit-address dict ignores symbol filter instead of KeyError" do
      exchange = Exchange.new!("binance")
      body = [%{"currency" => "BTC", "address" => "bc1qexample", "network" => "BTC"}]

      assert {:ok, %{"BTC" => %Bourse.DepositAddress{currency: "BTC", address: "bc1qexample"}}} =
               ReadParse.parse(
                 exchange,
                 CurrencyScopedParsers,
                 :fetch_deposit_addresses_by_network,
                 "fetchDepositAddressesByNetwork",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_deposit_address,
                 true
               )
    end

    # Row SELECTION and field EXTRACTION must agree on the network, including for a
    # chain only the catalog knows — otherwise the requested row is unreachable.
    test "deposit-address selection resolves a catalog-only chain the aliases never saw" do
      exchange =
        "okx"
        |> Exchange.new!()
        |> Map.merge(%{
          module: CatalogDepositAddressParser,
          currencies: %{"USDT" => %Bourse.Currency{networks: %{"NEW" => %{"id" => "USDT-NEW"}}}}
        })

      body = [%{"ccy" => "USDT", "chain" => "USDT-NEW", "addr" => "TNewAddress"}]

      assert {:ok, %Bourse.DepositAddress{network: "NEW", address: "TNewAddress"}} =
               ReadParse.parse(
                 exchange,
                 CatalogDepositAddressParser,
                 :fetch_deposit_address,
                 "fetchDepositAddress",
                 body,
                 %{"code" => "USDT", "network" => "NEW"},
                 :parse_deposit_address,
                 false
               )
    end

    # A row with no network has no key to index under and is dropped, matching
    # Bourse's `indexBy` (which skips undefined keys). Pinned so the drop is a
    # known contract rather than silent data loss discovered downstream.
    test "deposit-address dict drops rows carrying no network, matching Bourse indexBy" do
      exchange = Exchange.new!("binance")

      body = [
        %{"currency" => "BTC", "address" => "bc1qexample", "network" => "BTC"},
        %{"currency" => "BTC", "address" => "bc1qnonetwork"}
      ]

      assert {:ok, indexed} =
               ReadParse.parse(
                 exchange,
                 CurrencyScopedParsers,
                 :fetch_deposit_addresses_by_network,
                 "fetchDepositAddressesByNetwork",
                 body,
                 %{},
                 :parse_deposit_address,
                 true
               )

      assert Map.keys(indexed) == ["BTC"]
      assert indexed["BTC"].address == "bc1qexample"
    end

    test "symbol-bearing trade lists still filter by requested symbol" do
      exchange = Exchange.new!("binance")

      body = [
        %{"price" => "42.0", "timestamp" => 1_700_000_000_000},
        %{"price" => "43.0", "timestamp" => 1_700_000_000_001}
      ]

      # ParsedStructs trades have no symbol; request backfill stamps the singular
      # symbol onto every row, then filter keeps them all for that symbol.
      assert {:ok, [_, _]} =
               ReadParse.parse(
                 exchange,
                 ParsedStructs,
                 :fetch_trades,
                 "fetchTrades",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 true
               )

      # Multi-symbol filter without request backfill (symbols, not symbol): only
      # rows whose parsed symbol is in the list survive.
      assert {:ok, [%Bourse.Trade{symbol: "ETH/USDT", price: 1.0}]} =
               ReadParse.parse(
                 exchange,
                 SymbolFilterTradeParser,
                 :fetch_trades,
                 "fetchTrades",
                 [
                   %{"symbol" => "BTC/USDT", "price" => 2.0},
                   %{"symbol" => "ETH/USDT", "price" => 1.0}
                 ],
                 %{"symbols" => ["ETH/USDT"]},
                 :parse_trade,
                 true
               )
    end

    test "enriches list-return structs with matching raw entries" do
      exchange = Exchange.new!("binance")

      body = [
        %{"price" => "42.0", "timestamp" => 1_700_000_000_000},
        %{"price" => "43.0", "timestamp" => 1_700_000_000_001}
      ]

      assert {:ok, [first, second]} =
               ReadParse.parse(
                 exchange,
                 ParsedStructs,
                 :fetch_trades,
                 "fetchTrades",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 true
               )

      assert first.datetime == "2023-11-14T22:13:20.000Z"
      assert first.info == Enum.at(body, 0)
      assert second.datetime == "2023-11-14T22:13:20.001Z"
      assert second.info == Enum.at(body, 1)
    end

    test "plural trading fees reject one all-nil struct instead of inventing a symbol-keyed map" do
      exchange = Exchange.new!("binance")
      body = %{"maker" => "0.0002", "taker" => "0.0004"}

      assert {:error, %Error{type: :exchange_error, message: message}} =
               ReadParse.parse(
                 exchange,
                 NativeSymbolParser,
                 :fetch_trading_fees,
                 "fetchTradingFees",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_trading_fee,
                 false
               )

      assert message =~ "fetchTradingFees"
      assert message =~ "fetch_trading_fees"
      assert message =~ "%Bourse.TradingFee{}"
    end

    test "plural trading fees reject a populated single struct instead of returning it as success" do
      exchange = Exchange.new!("binance")
      body = %{"symbol" => "BTC/USDT", "makerCommission" => "0.0002", "takerCommission" => "0.0004"}

      assert {:error, %Error{type: :exchange_error, message: message, raw: %Bourse.TradingFee{symbol: "BTC/USDT"}}} =
               ReadParse.parse(
                 exchange,
                 NativeSymbolParser,
                 :fetch_trading_fees,
                 "fetchTradingFees",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_trading_fee,
                 false
               )

      assert message =~ "fetchTradingFees"
      assert message =~ "fetch_trading_fees"
      assert message =~ "expected a list of rows to index by symbol"
      assert message =~ "%Bourse.TradingFee{}"
    end

    test "market-fee transform is driven by generic authored vocabulary" do
      exchange =
        "binance"
        |> Exchange.new!()
        |> Exchange.put_markets([
          %Bourse.Market{base: "BTC", symbol: "BTC/USD:BTC", type: "swap"},
          %Bourse.Market{base: "BTC", symbol: "BTC/USD:BTC-260626", type: "future"},
          %Bourse.Market{base: "ETH", symbol: "ETH/USD:ETH", type: "swap"}
        ])

      body = %{
        "result" => %{
          "currency" => "BTC",
          "fees" => [
            %{"instrument_type" => "perpetual", "maker_fee" => "0.0001", "taker_fee" => "0.0005"},
            %{"instrument_type" => "future", "maker_fee" => "0.0002", "taker_fee" => "0.0006"}
          ]
        }
      }

      assert {:ok, fees} =
               ReadParse.parse(
                 exchange,
                 MarketFeeParser,
                 :fetch_trading_fees,
                 "fetchTradingFees",
                 body,
                 %{},
                 :parse_trading_fee,
                 false
               )

      assert %Bourse.TradingFee{maker: 0.0001, taker: 0.0005, percentage: true, tier_based: true} =
               fees["BTC/USD:BTC"]

      assert fees["BTC/USD:BTC"].info == %{
               "instrument_type" => "perpetual",
               "maker_fee" => "0.0001",
               "taker_fee" => "0.0005"
             }

      refute Map.has_key?(fees["BTC/USD:BTC"].info, "info")
      assert %Bourse.TradingFee{maker: 0.0002, taker: 0.0006} = fees["BTC/USD:BTC-260626"]
      refute Map.has_key?(fees, "ETH/USD:ETH")
    end

    test "market-fee transforms without a mismatch carve retain legitimate empty results" do
      exchange =
        "binance"
        |> Exchange.new!()
        |> Exchange.put_markets([%Bourse.Market{base: "BTC", symbol: "BTC/USD:BTC", type: "swap"}])

      body = %{"result" => %{"currency" => "BTC", "fees" => []}}

      assert {:ok, %{}} =
               ReadParse.parse(
                 exchange,
                 MarketFeeParser,
                 :fetch_trading_fees,
                 "fetchTradingFees",
                 body,
                 %{},
                 :parse_trading_fee,
                 false
               )
    end

    # Without the market cache the compact schedule would field-map-parse into a
    # single struct with symbol/maker/taker nil and the raw envelope in `info`,
    # handed back as `{:ok, _}` — the raw leak the transform exists to close.
    test "market-fee transform names the missing market cache instead of leaking raw" do
      exchange = Exchange.new!("binance")
      assert exchange.markets == nil

      body = %{
        "result" => %{
          "currency" => "BTC",
          "fees" => [%{"instrument_type" => "perpetual", "maker_fee" => "0.0001", "taker_fee" => "0.0005"}]
        }
      }

      assert_raise ArgumentError, ~r/markets` is not loaded.*Bourse\.load_markets\/1/s, fn ->
        ReadParse.parse(
          exchange,
          MarketFeeParser,
          :fetch_trading_fees,
          "fetchTradingFees",
          body,
          %{},
          :parse_trading_fee,
          false
        )
      end
    end
  end
end
