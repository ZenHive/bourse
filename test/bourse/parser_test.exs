defmodule Bourse.ParserTest do
  use ExUnit.Case, async: true

  alias Bourse.Parser

  describe "apply_mappings/3" do
    test "extracts fields, coerces values, and builds the target struct through JSONSpec atomization" do
      mapping = %{
        "field_map" => %{
          "bid" => %{"coercion" => "safeNumber", "key" => "bidPrice"},
          "bidVolume" => %{"coercion" => "safeNumber", "key" => "bidQty"},
          "last" => %{"coercion" => "safeNumber", "key" => "lastPrice"},
          "timestamp" => %{"coercion" => "safeInteger", "key" => "time"},
          "notInTicker" => %{"coercion" => "safeString", "key" => "unsafe"}
        }
      }

      raw = %{
        "bidPrice" => "101.25",
        "bidQty" => "2.5",
        "lastPrice" => "102.75",
        "time" => "1710000000000",
        "unsafe" => "must not become an atom"
      }

      assert {:ok, %Bourse.Ticker{} = ticker} =
               Parser.apply_mappings(raw, mapping, target: Bourse.Ticker)

      assert ticker.bid == 101.25
      assert ticker.bid_volume == 2.5
      assert ticker.last == 102.75
      assert ticker.timestamp == 1_710_000_000_000
      refute Map.has_key?(Map.from_struct(ticker), :not_in_ticker)
    end

    test "uses fallback keys when the primary key is absent" do
      mapping = %{
        "field_map" => %{
          "last" => %{
            "coercion" => "safeNumber",
            "key" => "lastPrice",
            "fallback_keys" => ["closePrice"]
          }
        }
      }

      assert {:ok, %Bourse.Ticker{last: 42.5}} =
               Parser.apply_mappings(%{"closePrice" => "42.5"}, mapping, target: Bourse.Ticker)
    end

    test "treats empty strings as missing and keeps trying fallback keys" do
      mapping = %{
        "field_map" => %{
          "last" => %{
            "coercion" => "safeNumber",
            "key" => "lastPrice",
            "fallback_keys" => ["closePrice"]
          }
        }
      }

      assert {:ok, %Bourse.Ticker{last: 42.5}} =
               Parser.apply_mappings(
                 %{"lastPrice" => "", "closePrice" => "42.5"},
                 mapping,
                 target: Bourse.Ticker
               )
    end

    test "adapts Bourse parser field names to current struct field names" do
      mapping = %{
        "field_map" => %{
          "clientOrderId" => %{"coercion" => "safeString", "key" => "client_id"},
          "timeInForce" => %{"coercion" => "safeString", "key" => "tif"},
          "lastTradeTimestamp" => %{"coercion" => "safeInteger", "key" => "last_trade_at"}
        }
      }

      assert {:ok,
              %Bourse.Order{
                client_order_id: "abc-123",
                time_in_force: "GTC",
                last_trade_timestamp: 1_710_000_000_001
              }} =
               Parser.apply_mappings(
                 %{"client_id" => "abc-123", "tif" => "GTC", "last_trade_at" => "1710000000001"},
                 mapping,
                 target: Bourse.Order
               )
    end

    test "uses market context for discriminated field mappings" do
      mapping = %{
        "branches" => [
          %{
            "guard" => %{"input_shape" => "array", "kind" => "always"},
            "field_map" => %{
              "timestamp" => %{"coercion" => "safeInteger", "index" => 0},
              "open" => %{"coercion" => "safeNumber", "index" => 1},
              "high" => %{"coercion" => "safeNumber", "index" => 2},
              "low" => %{"coercion" => "safeNumber", "index" => 3},
              "close" => %{"coercion" => "safeNumber", "index" => 4},
              "volume" => %{
                "kind" => "discriminated",
                "discriminator" => "market.inverse",
                "true" => %{"coercion" => "safeNumber", "index" => 6},
                "false" => %{"coercion" => "safeNumber", "index" => 5}
              }
            }
          }
        ]
      }

      raw = [1_710_000_000_000, "100", "110", "90", "105", "12.5", "0.75"]

      assert {:ok, %Bourse.OHLCV{volume: 0.75}} =
               Parser.apply_mappings(raw, mapping, target: Bourse.OHLCV, market: %{"inverse" => true})
    end
  end

  describe "parse/4 (Honesty Rule dispatch)" do
    # `opts` is a KEYWORD LIST — generated parsers hand the dispatcher's
    # `build_parse_opts/4` output straight here. Handing it a map raised
    # FunctionClauseError inside `Keyword.get/3` and reddened 168 replay
    # fixtures, so both the shape and the network-context forwarding are pinned.
    test "threads endpoint route context into branch selection" do
      mapping = %{
        "field_map" => %{"type" => %{"key" => "type", "enum_map" => %{"1" => "transfer"}}},
        "route_field_maps" => %{
          "asset/bills" => %{"type" => %{"key" => "type", "enum_map" => %{"1" => "deposit"}}}
        }
      }

      assert {:ok, %Bourse.LedgerEntry{type: "deposit"}} =
               Parser.parse(%{"type" => "1"}, mapping, Bourse.LedgerEntry,
                 route: "asset/bills",
                 venue: "okx"
               )
    end

    test "forwards the venue network context so catalog chains resolve to unified codes" do
      mapping = %{
        "_unresolved_reason" => nil,
        "field_map" => %{
          "network" => %{"kind" => "network_code", "network_key" => "chain", "currency_key" => "ccy"}
        }
      }

      opts = [
        currencies: %{"USDT" => %{"networks" => %{"x" => %{"id" => "USDT-Optimism", "network" => "Optimism"}}}},
        common_currencies: %{},
        options: %{"networks" => %{"OPTIMISM" => "Optimism"}}
      ]

      assert {:ok, %Bourse.DepositAddress{network: "OPTIMISM"}} =
               Parser.parse(%{"ccy" => "USDT", "chain" => "USDT-Optimism"}, mapping, Bourse.DepositAddress, opts)
    end

    test "returns {:error, :no_field_map} for a nil slot mapping" do
      assert Parser.parse(%{"x" => 1}, nil, Bourse.Ticker) == {:error, :no_field_map}
    end

    test "returns {:error, {:unresolved, reason}} when the slot has a non-nil _unresolved_reason" do
      mapping = %{
        "_unresolved_reason" => "identifier_return",
        "field_map" => %{"last" => %{"coercion" => "safeNumber", "key" => "lastPrice"}}
      }

      assert Parser.parse(%{"lastPrice" => "1.0"}, mapping, Bourse.Ticker) ==
               {:error, {:unresolved, "identifier_return"}}
    end

    test "returns {:error, :no_field_map} when a resolved slot carries an empty field_map" do
      mapping = %{"_unresolved_reason" => nil, "field_map" => %{}}
      assert Parser.parse(%{"x" => 1}, mapping, Bourse.Ticker) == {:error, :no_field_map}
    end

    test "returns {:error, :no_field_map} when branches is present but empty" do
      mapping = %{"_unresolved_reason" => nil, "branches" => []}
      assert Parser.parse([1, 2, 3], mapping, Bourse.OHLCV) == {:error, :no_field_map}
    end

    test "parses a resolved field_map slot into the target struct" do
      mapping = %{
        "_unresolved_reason" => nil,
        "field_map" => %{"last" => %{"coercion" => "safeNumber", "key" => "lastPrice"}}
      }

      assert {:ok, %Bourse.Ticker{last: 102.5}} =
               Parser.parse(%{"lastPrice" => "102.5"}, mapping, Bourse.Ticker)
    end

    test "threads :market opts into discriminated branch mappings" do
      mapping = %{
        "_unresolved_reason" => nil,
        "branches" => [
          %{
            "guard" => %{"input_shape" => "array", "kind" => "always"},
            "field_map" => %{
              "volume" => %{
                "kind" => "discriminated",
                "discriminator" => "market.inverse",
                "true" => %{"coercion" => "safeNumber", "index" => 2},
                "false" => %{"coercion" => "safeNumber", "index" => 1}
              }
            }
          }
        ]
      }

      raw = ["100", "5.0", "6.0"]

      assert {:ok, %Bourse.OHLCV{volume: 6.0}} =
               Parser.parse(raw, mapping, Bourse.OHLCV, market: %{"inverse" => true})

      assert {:ok, %Bourse.OHLCV{volume: 5.0}} =
               Parser.parse(raw, mapping, Bourse.OHLCV, market: %{"inverse" => false})
    end

    test "threads :symbol opts into authored response rules" do
      mapping = %{
        "field_map" => %{
          "symbol" => %{
            "kind" => "native_symbol",
            "key" => "symbol",
            "when_key" => "marketUnit",
            "when_value" => "baseCoin"
          }
        }
      }

      assert {:ok, %Bourse.Trade{symbol: "BTC/USDT"}} =
               Parser.parse(%{"symbol" => "BTCUSDT"}, mapping, Bourse.Trade, symbol: "BTC/USDT")
    end
  end
end
