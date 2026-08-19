defmodule Bourse.Unified.ReadParseFinancialTest do
  @moduledoc false
  # Focused coverage for Bybit position notional / maintenance-margin financial
  # annotation in ReadParse, plus adjacent parse branches needed to lift the
  # module to the critical (≥95%) coverage tier (task 244).

  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified.ReadParse

  defmodule NoFieldMapParser do
    @moduledoc false
    def __response_envelopes__, do: %{}
    def parse_ticker(_body, _opts), do: {:error, :no_field_map}
    def parse_trade(_body, _opts), do: {:error, :no_field_map}
  end

  defmodule FailingTradeParser do
    @moduledoc false
    def __response_envelopes__, do: %{}
    def parse_trade(_body, _opts), do: {:error, :forced_parser_failure}
  end

  defmodule DictTickerParser do
    @moduledoc false
    def __response_envelopes__ do
      %{"ticker" => %{"fetchTickers" => %{"key" => "result.list", "default" => []}}}
    end

    def parse_ticker(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(rows, fn row ->
         %Bourse.Ticker{symbol: nil, last: Bourse.Safe.number(row["lastPrice"]), info: row}
       end)}
    end

    def parse_ticker(other, _opts), do: {:ok, other}
  end

  defmodule BadShapeOhlcvParser do
    @moduledoc false
    def __response_envelopes__ do
      %{"ohlcv" => %{"fetchOHLCV" => %{"key" => "result"}}}
    end
  end

  defmodule VolHistoryParser do
    @moduledoc false
    def __response_envelopes__ do
      %{"volatility_history" => %{"fetchVolatilityHistory" => %{"key" => "result"}}}
    end
  end

  defmodule BalanceCoinParser do
    @moduledoc false
    def __response_envelopes__ do
      %{"balance" => %{"fetchBalance" => %{"key" => "result.list", "default" => []}}}
    end

    def parse_balance(%{"coin" => coins}, _opts) when is_list(coins) do
      free =
        Map.new(coins, fn c ->
          {c["coin"], Bourse.Safe.number(c["availableToWithdraw"] || c["walletBalance"])}
        end)

      total =
        Map.new(coins, fn c ->
          {c["coin"], Bourse.Safe.number(c["walletBalance"])}
        end)

      {:ok, %Bourse.Balance{free: free, used: %{}, total: total}}
    end

    def parse_balance(body, _opts) when is_map(body) do
      {:ok,
       %Bourse.Balance{
         free: %{"USDT" => 1.0},
         used: %{"USDT" => 0.0},
         total: %{"USDT" => 1.0}
       }}
    end
  end

  defmodule ListBodyBalanceParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    # `balance_parse_payload/4` reshapes a bare list body into `%{"details" => rows}`.
    def parse_balance(%{"details" => rows}, _opts) when is_list(rows) do
      total = Map.new(rows, fn r -> {r["asset"], Bourse.Safe.number(r["totalWalletBalance"])} end)

      {:ok, %Bourse.Balance{free: %{}, used: %{}, total: total}}
    end
  end

  defmodule CollateralsBalanceParser do
    @moduledoc false
    def __response_envelopes__ do
      %{"balance" => %{"fetchBalance" => %{"key" => "result", "default" => []}}}
    end

    def parse_balance(%{"collaterals" => rows}, _opts) when is_list(rows) do
      total =
        Map.new(rows, fn r ->
          {r["asset_name"] || r["currency"], Bourse.Safe.number(r["amount"])}
        end)

      {:ok, %Bourse.Balance{free: %{}, used: %{}, total: total}}
    end
  end

  defmodule FundingRateListParser do
    @moduledoc false
    def __response_envelopes__ do
      %{"funding_rate" => %{"fetchFundingRates" => %{"key" => "result.list", "default" => []}}}
    end

    def parse_funding_rate(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(rows, fn row ->
         %Bourse.FundingRate{
           symbol: nil,
           funding_rate: Bourse.Safe.number(row["fundingRate"]),
           info: row
         }
       end)}
    end
  end

  defmodule FundingRateRowParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_funding_rate(rows, _opts) when is_list(rows), do: {:ok, []}

    def parse_funding_rate(%{"symbol" => symbol} = row, _opts) do
      {:ok,
       %Bourse.FundingRate{
         symbol: symbol,
         funding_rate: Bourse.Safe.number(row["lastFundingRate"] || row["fundingRate"]),
         timestamp: Bourse.Safe.integer(row["time"]),
         mark_price: Bourse.Safe.number(row["markPrice"]),
         info: row
       }}
    end
  end

  defmodule BadCurrencyParser do
    @moduledoc false
    def __response_envelopes__ do
      %{"currency" => %{"fetchCurrencies" => %{"key" => "result"}}}
    end

    def parse_currency(_entries, _opts), do: {:ok, []}
  end

  defmodule SingleDictTickerParser do
    @moduledoc false
    def __response_envelopes__, do: %{}
    def parse_ticker(body, _opts), do: {:ok, body}
  end

  defmodule PartialBalanceParser do
    @moduledoc false
    def __response_envelopes__, do: %{}
    def parse_balance(_body, _opts), do: {:ok, %Bourse.Balance{free: nil, used: nil, total: nil}}
  end

  defmodule IntBalanceParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_balance(_body, _opts) do
      {:ok, %Bourse.Balance{free: %{"BTC" => 1}, used: %{}, total: %{"BTC" => 3}}}
    end
  end

  defmodule ThreeWayBalanceParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_balance(_body, _opts) do
      {:ok,
       %Bourse.Balance{
         free: %{"FREE" => nil, "TOTAL" => 2.0, "PRESERVED" => 3.0},
         used: %{"FREE" => 3.0, "TOTAL" => 3.0, "PRESERVED" => 4.0},
         total: %{"FREE" => 5.0, "TOTAL" => nil, "PRESERVED" => 99.0}
       }}
    end
  end

  # Deribit-style: used already mapped from maintenance_margin; free/total numeric
  # but free + used != total (cross-collateral equity=0 for non-primary currency).
  defmodule ParsedUsedBalanceParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_balance(_body, _opts) do
      {:ok,
       %Bourse.Balance{
         free: %{"BUIDL" => 1_094_714.0, "BTC" => 0.5, "ETH" => 1.0},
         # ETH used=0 is a real parsed value (not "missing") — must survive.
         used: %{"BUIDL" => 142_537.0, "BTC" => 0.12, "ETH" => 0.0},
         total: %{"BUIDL" => 0.0, "BTC" => 1.0, "ETH" => 2.0}
       }}
    end
  end

  defmodule TimedTradesParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_trade(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(rows, fn r ->
         %Bourse.Trade{symbol: "BTC/USDT", price: 1.0, timestamp: r["t"], info: r}
       end)}
    end
  end

  defmodule TimedOrdersParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_order(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(rows, fn r ->
         %Bourse.Order{id: r["id"], symbol: "BTC/USDT", timestamp: r["t"], info: r}
       end)}
    end
  end

  defmodule NoTsTradesParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_trade(rows, _opts) when is_list(rows) do
      {:ok, Enum.map(rows, fn _ -> %Bourse.Trade{symbol: "BTC/USDT", price: 1.0, timestamp: nil} end)}
    end
  end

  defmodule OpenInterestListEnvelopeParser do
    @moduledoc false

    def __response_envelopes__ do
      %{"open_interest" => %{"fetchOpenInterest" => %{"key" => "result.list", "default" => []}}}
    end

    def parse_open_interest(%{"openInterest" => value}, _opts) do
      {:ok, %Bourse.OpenInterest{open_interest_amount: Bourse.Safe.number(value)}}
    end

    def parse_open_interest(rows, _opts) when is_list(rows) do
      case rows do
        [first | _] -> parse_open_interest(first, [])
        _ -> {:ok, %Bourse.OpenInterest{}}
      end
    end
  end

  defmodule SparseFundingHistoryParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_funding_history(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(rows, fn r ->
         %Bourse.FundingHistory{
           symbol: "BTC/USDT:USDT",
           code: "USDT",
           amount: 1.0,
           timestamp: r["t"],
           info: r
         }
       end)}
    end
  end

  defmodule DailyBorrowParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_borrow_rate(body, _opts) do
      {:ok,
       %Bourse.BorrowRate{
         currency: "USDT",
         rate: 0.01,
         period: 86_400_000,
         info: body
       }}
    end
  end

  defmodule HourlyBorrowParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_borrow_rate(body, _opts) do
      {:ok, %Bourse.BorrowRate{currency: "USDT", rate: 0.0001, info: body}}
    end
  end

  defmodule ListInfoTradeParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_trade(body, _opts) when is_list(body) do
      {:ok, Enum.map(body, fn _ -> %Bourse.Trade{symbol: "BTC/USDT", price: 1.0} end)}
    end
  end

  defmodule MapTradeParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_trade(_body, _opts) do
      {:ok,
       %{
         "BTCUSDT" => %Bourse.Trade{
           symbol: "BTCUSDT",
           price: 1.0,
           info: %{"symbol" => "BTCUSDT", "category" => "linear"}
         }
       }}
    end
  end

  defmodule OptionDataParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_option(body, _opts) do
      {:ok, %Bourse.OptionData{symbol: nil, info: body}}
    end
  end

  defmodule GreeksNativeParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_greeks(body, _opts) when is_map(body) do
      {:ok, %Bourse.Greeks{symbol: nil, delta: 0.1, info: body}}
    end

    def parse_greeks(rows, _opts) when is_list(rows) do
      {:ok, Enum.map(rows, fn r -> %Bourse.Greeks{symbol: nil, delta: 0.1, info: r} end)}
    end
  end

  defmodule ComponentMarketParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_market(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(rows, fn _ ->
         %Bourse.Market{
           symbol: nil,
           base: "BTC",
           quote: "USDT",
           settle: "USDT",
           type: "swap",
           swap: true
         }
       end)}
    end
  end

  defmodule BareVolHistoryParser do
    @moduledoc false
    def __response_envelopes__, do: %{}
  end

  defmodule NonBalanceParser do
    @moduledoc false
    def __response_envelopes__, do: %{}
    def parse_balance(_body, _opts), do: {:ok, %{not: :balance}}
  end

  defmodule NilComponentMarketParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_market(rows, _opts) when is_list(rows) do
      {:ok,
       Enum.map(rows, fn _ ->
         %Bourse.Market{symbol: nil, base: nil, quote: nil, settle: nil, type: "spot"}
       end)}
    end
  end

  defmodule LighterMarketParser do
    @moduledoc false
    def __response_envelopes__, do: %{}

    def parse_market(rows, _opts) when is_list(rows) do
      {:ok, Enum.map(rows, fn r -> %Bourse.Market{symbol: nil, info: r} end)}
    end
  end

  # ---------------------------------------------------------------------------
  # Bybit position financial annotation (notional + maintenance margin)
  # ---------------------------------------------------------------------------

  describe "Bybit position financial annotation" do
    test "linear notional uses positionValue; MM recomputes as |liq-bust|*size" do
      exchange = Exchange.new!("bybit")
      body = bybit_position_body("linear", linear_open_row())

      assert {:ok, [%Bourse.Position{} = pos]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 true
               )

      # positionValue "5000"
      assert pos.notional == 5000.0
      # |45000 - 44000| * 0.1 = 100
      assert pos.maintenance_margin == 100.0
      assert pos.initial_margin == 500.0
      assert pos.liquidation_price == 45_000.0
      # synthetic keys never leak into info
      refute Map.has_key?(pos.info, "_bourse_notional")
      refute Map.has_key?(pos.info, "_bourse_mm")
      refute Map.has_key?(pos.info, "_bourse_im")
    end

    test "inverse notional is size/markPrice; MM is size*|bust-liq|/(bust*liq)" do
      exchange = Exchange.new!("bybit")
      body = bybit_position_body("inverse", inverse_open_row())

      assert {:ok, [%Bourse.Position{} = pos]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_position,
                 true
               )

      # 100 / 50000
      assert pos.notional == 0.002
      # 100 * |39000-40000| / (39000*40000)
      assert_in_delta pos.maintenance_margin, 6.4102564102564e-5, 1.0e-15
      assert pos.initial_margin == 0.0001
      assert pos.contracts == 100.0
    end

    test "without liqPrice, maintenance margin falls back to positionMM" do
      exchange = Exchange.new!("bybit")

      row =
        linear_open_row()
        |> Map.put("liqPrice", "")
        |> Map.put("bustPrice", "")
        |> Map.put("positionMM", "12.5")
        |> Map.put("positionValue", "50000")
        |> Map.put("size", "1")

      body = bybit_position_body("linear", row)

      assert {:ok, [%Bourse.Position{notional: 50_000.0, maintenance_margin: 12.5}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{},
                 :parse_position,
                 true
               )
    end

    test "liqPrice present with empty bust yields nil maintenance margin" do
      exchange = Exchange.new!("bybit")

      row =
        linear_open_row()
        |> Map.put("bustPrice", "")
        |> Map.put("positionMM", "12.5")

      body = bybit_position_body("linear", row)

      assert {:ok, [%Bourse.Position{maintenance_margin: nil, liquidation_price: 45_000.0}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 true
               )
    end

    test "liqPrice present with missing size yields nil recomputed MM" do
      exchange = Exchange.new!("bybit")

      row =
        linear_open_row()
        |> Map.delete("size")
        |> Map.put("qty", "")
        |> Map.put("positionValue", "5000")

      body = bybit_position_body("linear", row)

      assert {:ok, [%Bourse.Position{maintenance_margin: nil, notional: 5000.0}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 true
               )
    end

    test "malformed liq/bust numerics take the Decimal.Error path and leave MM nil" do
      exchange = Exchange.new!("bybit")

      row =
        linear_open_row()
        |> Map.put("liqPrice", "not-a-number")
        |> Map.put("bustPrice", "44000")

      body = bybit_position_body("linear", row)

      assert {:ok, [%Bourse.Position{} = pos]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 true
               )

      # notional still copies positionValue; only the decimal recompute fails soft
      assert pos.notional == 5000.0
      assert pos.maintenance_margin == nil
      assert pos.liquidation_price == nil
    end

    test "inverse notional is nil when markPrice is blank" do
      exchange = Exchange.new!("bybit")

      row =
        inverse_open_row()
        |> Map.put("markPrice", "")
        |> Map.put("liqPrice", "")
        |> Map.put("bustPrice", "")

      body = bybit_position_body("inverse", row)

      assert {:ok, [%Bourse.Position{notional: nil, maintenance_margin: 0.00005}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_position,
                 true
               )
    end

    test "linear falls back to cumExitValue when positionValue is empty" do
      exchange = Exchange.new!("bybit")

      row =
        linear_open_row()
        |> Map.put("positionValue", "")
        |> Map.put("cumExitValue", "123.45")
        |> Map.put("liqPrice", "")
        |> Map.put("bustPrice", "")

      body = bybit_position_body("linear", row)

      assert {:ok, [%Bourse.Position{notional: 123.45}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 true
               )
    end

    test "closedSize history rows skip notional/MM recomputation" do
      exchange = Exchange.new!("bybit")

      row = %{
        "symbol" => "BTCUSDT",
        "qty" => "0.001",
        "cumExitValue" => "55.563",
        "closedSize" => "0.001",
        "avgEntryPrice" => "55937.5",
        "avgExitPrice" => "55563",
        "createdTime" => "1700000000000",
        "updatedTime" => "1700000000000",
        "orderId" => "hist-1",
        "side" => "Sell",
        "execType" => "Trade",
        "closedPnl" => "0",
        "liqPrice" => "40000",
        "bustPrice" => "39000",
        "positionMM" => "1",
        "positionIM" => "2"
      }

      body = bybit_position_body("linear", row)

      assert {:ok, [%Bourse.Position{} = pos]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions_history,
                 "fetchPositionsHistory",
                 body,
                 %{},
                 :parse_position,
                 true
               )

      # history maps notional from cumExitValue via field map, not inverse recompute
      assert pos.notional == 55.563
      assert pos.contracts == 0.001
      # closedSize short-circuits annotate — no liq/bust recompute despite liqPrice/bustPrice
      assert pos.maintenance_margin == nil
    end

    test "fetchPosition stamps outer response time onto the single position" do
      exchange = Exchange.new!("bybit")
      body = bybit_position_body("linear", linear_open_row(), time: 1_700_000_000_123)

      assert {:ok, %Bourse.Position{} = pos} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_position,
                 "fetchPosition",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 false
               )

      assert pos.timestamp == 1_700_000_000_123
      assert pos.datetime == "2023-11-14T22:13:20.123Z"
      assert pos.notional == 5000.0
      assert pos.maintenance_margin == 100.0
    end

    test "fetchPosition without time leaves row timestamps alone" do
      exchange = Exchange.new!("bybit")
      body = "linear" |> bybit_position_body(linear_open_row()) |> Map.delete("time")

      assert {:ok, %Bourse.Position{} = pos} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_position,
                 "fetchPosition",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 false
               )

      assert pos.timestamp == 1_700_000_000_000
    end

    test "numeric size/markPrice coerce through non_empty_string" do
      exchange = Exchange.new!("bybit")

      row =
        inverse_open_row()
        |> Map.put("size", 50)
        |> Map.put("markPrice", 25_000)
        |> Map.put("liqPrice", 20_000)
        |> Map.put("bustPrice", 19_000)

      body = bybit_position_body("inverse", row)

      assert {:ok, [%Bourse.Position{} = pos]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_position,
                 true
               )

      # 50 / 25000
      assert pos.notional == 0.002
      # 50 * 1000 / (19000*20000)
      assert_in_delta pos.maintenance_margin, 50 * 1000 / (19_000 * 20_000), 1.0e-15
    end

    test "qty substitutes for size on inverse notional and linear MM" do
      exchange = Exchange.new!("bybit")

      inv =
        inverse_open_row()
        |> Map.delete("size")
        |> Map.put("qty", "100")

      assert {:ok, [%Bourse.Position{notional: 0.002}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 bybit_position_body("inverse", inv),
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_position,
                 true
               )

      lin =
        linear_open_row()
        |> Map.delete("size")
        |> Map.put("qty", "0.1")

      assert {:ok, [%Bourse.Position{maintenance_margin: 100.0}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 bybit_position_body("linear", lin),
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 true
               )
    end

    test "inverse with equal liq and bust recomputes MM as zero" do
      exchange = Exchange.new!("bybit")

      row =
        inverse_open_row()
        |> Map.put("liqPrice", "100")
        |> Map.put("bustPrice", "100")

      assert {:ok, [%Bourse.Position{} = pos]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 bybit_position_body("inverse", row),
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_position,
                 true
               )

      assert pos.notional == 0.002
      assert pos.maintenance_margin == +0.0
    end

    test "malformed inverse bust takes Decimal.Error path leaving MM nil" do
      exchange = Exchange.new!("bybit")

      row =
        inverse_open_row()
        |> Map.put("liqPrice", "40000")
        |> Map.put("bustPrice", "bad")

      assert {:ok, [%Bourse.Position{maintenance_margin: nil, notional: 0.002}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 bybit_position_body("inverse", row),
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_position,
                 true
               )
    end

    test "whitespace-only markPrice is treated as missing for inverse notional" do
      exchange = Exchange.new!("bybit")

      row =
        inverse_open_row()
        |> Map.put("markPrice", "   ")
        |> Map.put("liqPrice", "")

      assert {:ok, [%Bourse.Position{notional: nil}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 bybit_position_body("inverse", row),
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_position,
                 true
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Adjacent ReadParse branches (coverage lift toward ≥95%)
  # ---------------------------------------------------------------------------

  describe "ReadParse coverage edges" do
    test "OHLCV rejects a non-list envelope payload" do
      exchange = Exchange.new!("deribit")

      assert {:error, %Error{type: :exchange_error} = err} =
               ReadParse.parse(
                 exchange,
                 BadShapeOhlcvParser,
                 :fetch_ohlcv,
                 "fetchOHLCV",
                 %{"result" => %{"not" => "rows"}},
                 %{},
                 :parse_ohlcv,
                 true
               )

      # unexpected shape is normalized through normalize_error → exchange_error
      assert err.message =~ "Unexpected response shape"
    end

    test "currency parse rejects a non-list unexpected shape after envelope" do
      exchange = Exchange.new!("deribit")

      # When result is a map (not list), extract returns the map → unexpected shape
      assert {:error, %Error{}} =
               ReadParse.parse(
                 exchange,
                 BadCurrencyParser,
                 :fetch_currencies,
                 "fetchCurrencies",
                 %{"result" => %{"currency" => "BTC"}},
                 %{},
                 :parse_currency,
                 false
               )
    end

    test "no_field_map returns a typed error with method context" do
      exchange = Exchange.new!("binance")
      body = %{"lastPrice" => "1", "symbol" => "BTCUSDT"}

      assert {:error, %Error{exchange: "binance", message: message, raw: ^body}} =
               ReadParse.parse(
                 exchange,
                 NoFieldMapParser,
                 :fetch_ticker,
                 "fetchTicker",
                 body,
                 %{},
                 :parse_ticker,
                 false
               )

      assert message =~ "No field map available"
      assert message =~ "fetch_ticker"
    end

    test "parser error propagates" do
      exchange = Exchange.new!("binance")

      assert {:error, %Error{}} =
               ReadParse.parse(
                 exchange,
                 FailingTradeParser,
                 :fetch_trades,
                 "fetchTrades",
                 [%{"price" => "1"}],
                 %{},
                 :parse_trade,
                 true
               )
    end

    test "bybit fetchTickers backfills requested symbols from native ids" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "linear",
          "list" => [
            %{"symbol" => "BTCUSDT", "lastPrice" => "50000", "turnover24h" => "1"}
          ]
        }
      }

      assert {:ok, tickers} =
               ReadParse.parse(
                 exchange,
                 DictTickerParser,
                 :fetch_tickers,
                 "fetchTickers",
                 body,
                 %{"symbols" => ["BTC/USDT:USDT", "ETH/USDT:USDT"]},
                 :parse_ticker,
                 false
               )

      assert is_map(tickers)
      assert %Bourse.Ticker{symbol: "BTC/USDT:USDT", last: 50_000.0} = Map.fetch!(tickers, "BTC/USDT:USDT")
    end

    test "fetchTickers rejects a non-list parse instead of returning it as success" do
      exchange = Exchange.new!("bybit")
      body = %{"symbol" => "BTCUSDT", "lastPrice" => "1"}

      assert {:error, %Error{type: :exchange_error, message: message, raw: ^body}} =
               ReadParse.parse(
                 exchange,
                 SingleDictTickerParser,
                 :fetch_tickers,
                 "fetchTickers",
                 body,
                 %{},
                 :parse_ticker,
                 false
               )

      assert message =~ "fetchTickers"
      assert message =~ "fetch_tickers"
      assert message =~ "expected a list of rows to index by symbol"
      assert message =~ "got map"
    end

    test "bybit balance flattens coin rows and reconciles used = total - free" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "time" => 1_700_000_000_000,
        "result" => %{
          "list" => [
            %{
              "coin" => [
                %{
                  "coin" => "USDT",
                  "walletBalance" => "100",
                  "availableToWithdraw" => "40"
                }
              ]
            }
          ]
        }
      }

      assert {:ok, %Bourse.Balance{} = bal} =
               ReadParse.parse(
                 exchange,
                 BalanceCoinParser,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )

      assert bal.free["USDT"] == 40.0
      assert bal.total["USDT"] == 100.0
      assert bal.used["USDT"] == 60.0
      assert bal.timestamp == 1_700_000_000_000
      assert bal.info == body
    end

    test "reconcile_balance_used keeps already-parsed used (does not clobber with total-free)" do
      exchange = Exchange.new!("deribit")

      # Portfolio-margin shape: equity (total) can be 0 while free and used are both
      # large positives. Deriving used = total - free would yield ~-1e6; the parser's
      # maintenance_margin mapping must survive (task 241).
      assert {:ok, %Bourse.Balance{} = bal} =
               ReadParse.parse(
                 exchange,
                 ParsedUsedBalanceParser,
                 :fetch_balance,
                 "fetchBalance",
                 %{"summaries" => []},
                 %{},
                 :parse_balance,
                 false
               )

      assert bal.used["BUIDL"] == 142_537.0
      assert bal.used["BTC"] == 0.12
      # Zero used is defined (not nil) — do not derive total-free (= 1.0).
      assert bal.used["ETH"] == 0.0
      assert bal.free["BUIDL"] == 1_094_714.0
      assert bal.total["BUIDL"] == 0.0
      # Proves we did not fall through to total - free for BUIDL/BTC.
      refute bal.used["BUIDL"] == bal.total["BUIDL"] - bal.free["BUIDL"]
      refute bal.used["BTC"] == bal.total["BTC"] - bal.free["BTC"]
    end

    test "derive-style collaterals balance flattens multi-account rows" do
      exchange = Exchange.new!("derive")

      body = %{
        "result" => [
          %{"collaterals" => [%{"asset_name" => "USDC", "amount" => "10"}]},
          %{"collaterals" => [%{"asset_name" => "ETH", "amount" => "2"}]}
        ]
      }

      assert {:ok, %Bourse.Balance{total: total}} =
               ReadParse.parse(
                 exchange,
                 CollateralsBalanceParser,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )

      assert total["USDC"] == 10.0
      assert total["ETH"] == 2.0
    end

    # Binance portfolio-margin (`GET /papi/v1/balance`) answers with a bare JSON
    # array. Envelope `time` is a map-only concept; reading it off a list body
    # raised a BadMapError before task 297.
    test "list-bodied balance payload parses with a nil timestamp" do
      exchange = Exchange.new!("binance")

      body = [
        %{"asset" => "USDT", "totalWalletBalance" => "100.5"},
        %{"asset" => "ETH", "totalWalletBalance" => "2"}
      ]

      assert {:ok, %Bourse.Balance{total: total, timestamp: nil, datetime: nil, info: ^body}} =
               ReadParse.parse(
                 exchange,
                 ListBodyBalanceParser,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )

      assert total["USDT"] == 100.5
      assert total["ETH"] == 2.0
    end

    test "map-bodied balance payload still stamps envelope time" do
      body = %{
        "result" => [%{"collaterals" => [%{"asset_name" => "USDC", "amount" => "10"}]}],
        "time" => 1_707_465_600_000
      }

      assert {:ok, %Bourse.Balance{timestamp: 1_707_465_600_000, datetime: "2024-02-09T08:00:00.000Z"}} =
               ReadParse.parse(
                 Exchange.new!("derive"),
                 CollateralsBalanceParser,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )
    end

    test "balance without free/total maps skips used reconciliation" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Balance{free: nil, used: nil, total: nil}} =
               ReadParse.parse(
                 exchange,
                 PartialBalanceParser,
                 :fetch_balance,
                 "fetchBalance",
                 %{"x" => 1},
                 %{},
                 :parse_balance,
                 false
               )
    end

    test "integer free/total balance amounts coerce via balance_decimal" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Balance{used: %{"BTC" => 2.0}}} =
               ReadParse.parse(
                 exchange,
                 IntBalanceParser,
                 :fetch_balance,
                 "fetchBalance",
                 %{},
                 %{},
                 :parse_balance,
                 false
               )
    end

    test "reconciles each missing balance member without overwriting parsed values" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.Balance{} = balance} =
               ReadParse.parse(
                 exchange,
                 ThreeWayBalanceParser,
                 :fetch_balance,
                 "fetchBalance",
                 %{},
                 %{},
                 :parse_balance,
                 false
               )

      assert balance.free["FREE"] == 2.0
      assert balance.total["TOTAL"] == 5.0
      assert balance.free["PRESERVED"] == 3.0
      assert balance.used["PRESERVED"] == 4.0
      assert balance.total["PRESERVED"] == 99.0
    end

    test "volatility history coerces sparse and non-list rows" do
      exchange = Exchange.new!("deribit")

      body = %{
        "result" => [
          [1_700_000_000_000, 0.55],
          ["only-one"],
          "not-a-row"
        ]
      }

      assert {:ok, rows} =
               ReadParse.parse(
                 exchange,
                 VolHistoryParser,
                 :fetch_volatility_history,
                 "fetchVolatilityHistory",
                 body,
                 %{},
                 :parse_volatility_history,
                 true
               )

      assert length(rows) == 3
      assert Enum.all?(rows, &match?(%Bourse.VolatilityHistory{}, &1))
    end

    test "since/limit filter keeps newest without since and oldest with since" do
      exchange = Exchange.new!("binance")

      body = [
        %{"t" => 100},
        %{"t" => 200},
        %{"t" => 300}
      ]

      assert {:ok, without_since} =
               ReadParse.parse(
                 exchange,
                 TimedTradesParser,
                 :fetch_trades,
                 "fetchTrades",
                 body,
                 %{"limit" => 2},
                 :parse_trade,
                 true
               )

      assert Enum.map(without_since, & &1.timestamp) == [200, 300]

      assert {:ok, with_since} =
               ReadParse.parse(
                 exchange,
                 TimedTradesParser,
                 :fetch_trades,
                 "fetchTrades",
                 body,
                 %{"since" => 150, "limit" => 2},
                 :parse_trade,
                 true
               )

      assert Enum.map(with_since, & &1.timestamp) == [200, 300]
    end

    test "order limit sorts chronologically before taking newest rows" do
      exchange = Exchange.new!("deribit")

      body = [
        %{"id" => "newest", "t" => 300},
        %{"id" => "middle", "t" => 200},
        %{"id" => "oldest", "t" => 100}
      ]

      assert {:ok, orders} =
               ReadParse.parse(
                 exchange,
                 TimedOrdersParser,
                 :fetch_closed_orders,
                 "fetchClosedOrders",
                 body,
                 %{"limit" => 1},
                 :parse_order,
                 true
               )

      assert Enum.map(orders, & &1.id) == ["newest"]
    end

    test "trade rows without timestamp pass the since filter" do
      exchange = Exchange.new!("binance")

      assert {:ok, [_, _]} =
               ReadParse.parse(
                 exchange,
                 NoTsTradesParser,
                 :fetch_trades,
                 "fetchTrades",
                 [%{}, %{}],
                 %{"since" => 1},
                 :parse_trade,
                 true
               )
    end

    test "bybit funding history derives code from inverse vs linear symbols" do
      exchange = Exchange.new!("bybit")

      inv_body = %{
        "retCode" => 0,
        "result" => %{
          "list" => [
            %{
              "symbol" => "BTCUSD",
              "funding" => "0.01",
              "fundingRate" => "0.0001",
              "execTime" => "1700000000000",
              "transactionId" => "t1"
            }
          ]
        }
      }

      assert {:ok, [%Bourse.FundingHistory{code: "USD", symbol: "BTC/USD:BTC"}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 inv_body,
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_funding_history,
                 true
               )

      lin_body = %{
        "retCode" => 0,
        "result" => %{
          "list" => [
            %{
              "symbol" => "BTCUSDT",
              "funding" => "0.01",
              "fundingRate" => "0.0001",
              "execTime" => "1700000000000",
              "transactionId" => "t2"
            }
          ]
        }
      }

      assert {:ok, [%Bourse.FundingHistory{code: "USDT", symbol: "BTC/USDT:USDT"}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 lin_body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_funding_history,
                 true
               )
    end

    test "fetchFundingRates list keeps native symbols unless singular request" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "linear",
          "list" => [
            %{"symbol" => "BTCUSDT", "fundingRate" => "0.0001"},
            %{"symbol" => "ETHUSDT", "fundingRate" => "0.0002"}
          ]
        }
      }

      assert {:ok, rates} =
               ReadParse.parse(
                 exchange,
                 FundingRateListParser,
                 :fetch_funding_rates,
                 "fetchFundingRates",
                 body,
                 %{},
                 :parse_funding_rate,
                 false
               )

      assert is_map(rates)
      assert map_size(rates) >= 1
    end

    test "binanceusdm funding rates key inverse and dated contracts by unified symbols" do
      exchange = Exchange.new!("binanceusdm")

      inverse_body = %{
        "result" => %{
          "list" => [
            %{"symbol" => "FILUSD_PERP", "fundingRate" => "0.0001"},
            %{"symbol" => "SOLUSD_261225", "fundingRate" => "0.0002"},
            %{"symbol" => "BTCUSD1", "fundingRate" => "0.0003"}
          ]
        }
      }

      linear_body = %{
        "result" => %{
          "list" => [%{"symbol" => "ETHUSDT_260925", "fundingRate" => "0.0004"}]
        }
      }

      assert {:ok, inverse_rates} =
               ReadParse.parse(
                 exchange,
                 FundingRateListParser,
                 :fetch_funding_rates,
                 "fetchFundingRates",
                 inverse_body,
                 %{},
                 :parse_funding_rate,
                 false
               )

      assert inverse_rates |> Map.keys() |> Enum.sort() == ["BTC/USD1:USD1", "FIL/USD:FIL", "SOL/USD:SOL-261225"]

      assert {:ok, linear_rates} =
               ReadParse.parse(
                 exchange,
                 FundingRateListParser,
                 :fetch_funding_rates,
                 "fetchFundingRates",
                 linear_body,
                 %{},
                 :parse_funding_rate,
                 false
               )

      assert Map.keys(linear_rates) == ["ETH/USDT:USDT-260925"]
    end

    test "binancecoinm funding rates share the COIN-M grammar without the fapi-only carves" do
      exchange = Exchange.new!("binancecoinm")

      body = %{
        "result" => %{
          "list" => [
            %{"symbol" => "BTCUSD_PERP", "fundingRate" => "0.0001"},
            %{"symbol" => "BNBUSD_261225", "fundingRate" => "0.0002"}
          ]
        }
      }

      assert {:ok, rates} =
               ReadParse.parse(
                 exchange,
                 FundingRateListParser,
                 :fetch_funding_rates,
                 "fetchFundingRates",
                 body,
                 %{},
                 :parse_funding_rate,
                 false
               )

      assert rates |> Map.keys() |> Enum.sort() == ["BNB/USD:BNB-261225", "BTC/USD:BTC"]
    end

    test "bybit fetchOpenOrders merges pagination cursor onto the first raw row" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "linear",
          "nextPageCursor" => "cursor-abc",
          "list" => [
            %{
              "orderId" => "o1",
              "symbol" => "BTCUSDT",
              "orderStatus" => "New",
              "orderType" => "Limit",
              "side" => "Buy",
              "price" => "10000",
              "qty" => "0.001",
              "avgPrice" => "",
              "cumExecQty" => "0",
              "cumExecValue" => "0",
              "createdTime" => "1784189372501",
              "updatedTime" => "1784189372501"
            }
          ]
        }
      }

      assert {:ok, [%Bourse.Order{} = order]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_open_orders,
                 "fetchOpenOrders",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_order,
                 true
               )

      assert order.info["nextPageCursor"] == "cursor-abc"
    end

    test "bybit positions pagination cursor stamps every row" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "linear",
          "nextPageCursor" => "pos-cursor",
          "list" => [linear_open_row()]
        }
      }

      assert {:ok, [%Bourse.Position{} = pos]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 true
               )

      assert pos.info["nextPageCursor"] == "pos-cursor"
      assert pos.notional == 5000.0
    end

    test "bybit fetchClosedOrders sorts by timestamp ascending" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "linear",
          "list" => [
            order_row("late", "1784189372502"),
            order_row("early", "1784189372500")
          ]
        }
      }

      assert {:ok, orders} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_closed_orders,
                 "fetchClosedOrders",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_order,
                 true
               )

      assert Enum.map(orders, & &1.id) == ["early", "late"]
    end

    test "bybit editOrder preserves full raw ack as info and clears symbol" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "orderId" => "edit-1",
          "orderLinkId" => "link-1"
        }
      }

      assert {:ok, %Bourse.Order{symbol: nil, info: ^body, id: "edit-1"}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :edit_order,
                 "editOrder",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_order,
                 false
               )
    end

    test "single-position request symbol overrides native id" do
      exchange = Exchange.new!("bybit")
      body = bybit_position_body("linear", linear_open_row())

      assert {:ok, %Bourse.Position{symbol: "BTC/USDT:USDT"}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_position,
                 "fetchPosition",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_position,
                 false
               )
    end

    test "reject exchange error with non-success retCode" do
      exchange = Exchange.new!("bybit")

      assert {:error, %Error{type: :exchange_error}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 %{"retCode" => 10_001, "retMsg" => "fail"},
                 %{},
                 :parse_position,
                 true
               )
    end

    test "option market category annotation still resolves option positions" do
      exchange = Exchange.new!("bybit")

      body = %{
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
              "updatedTime" => "1784189372501",
              "positionIM" => "10",
              "positionMM" => "1",
              "liqPrice" => "",
              "bustPrice" => ""
            }
          ]
        }
      }

      assert {:ok, [%Bourse.Position{symbol: "BTC/USDC:USDC-250131-100000-C", notional: 50.0}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 body,
                 %{"symbol" => "BTC/USDC:USDC-250131-100000-C"},
                 :parse_position,
                 true
               )
    end

    test "margin loan backfills currency from request and leaves amount nil without request amount" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{"resultStatus" => "SU"}
      }

      assert {:ok, %Bourse.MarginLoan{currency: "USDT", amount: nil}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :repay_cross_margin,
                 "repayCrossMargin",
                 body,
                 %{"code" => "USDT"},
                 :parse_margin_loan,
                 false
               )
    end

    test "margin loan backfills amount from the request when present" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{"resultStatus" => "SU"}
      }

      assert {:ok, %Bourse.MarginLoan{currency: "USDT", amount: 5}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :repay_cross_margin,
                 "repayCrossMargin",
                 body,
                 %{"code" => "USDT", "amount" => 5},
                 :parse_margin_loan,
                 false
               )
    end

    test "fetchPositionADLRank backfills the requested symbol on a single rank" do
      exchange = Exchange.new!("bybit")
      body = bybit_adl_body()

      assert {:ok, %Bourse.ADLRank{symbol: "BTC/USDT:USDT", rank: 2}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_position_adl_rank,
                 "fetchPositionADLRank",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_adl_rank,
                 false
               )
    end

    test "COIN-M fetchADLRank treats the documented empty account object as no rank" do
      exchange = Exchange.new!("binancecoinm")

      assert {:ok, nil} =
               ReadParse.parse(
                 exchange,
                 Bourse.Binancecoinm,
                 :fetch_adl_rank,
                 "fetchADLRank",
                 %{},
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_adl_rank,
                 false
               )
    end

    test "fetchPositionsADLRank backfills the requested symbol on each rank row" do
      exchange = Exchange.new!("bybit")
      body = bybit_adl_body()

      assert {:ok, [%Bourse.ADLRank{symbol: "BTC/USDT:USDT", rank: 2}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions_adl_rank,
                 "fetchPositionsADLRank",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_adl_rank,
                 true
               )
    end

    test "fetchGreeks backfills the requested option symbol" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "option",
          "list" => [
            %{
              "symbol" => "BTC-31JAN25-100000-C",
              "delta" => "0.5",
              "gamma" => "0.01",
              "vega" => "0.02",
              "theta" => "-0.03",
              "markPrice" => "500",
              "underlyingPrice" => "100000",
              "markIv" => "0.5",
              "bid1Price" => "1",
              "ask1Price" => "2",
              "bid1Size" => "1",
              "ask1Size" => "1",
              "lastPrice" => "500",
              "indexPrice" => "100000",
              "ask1Iv" => "0.5",
              "bid1Iv" => "0.5"
            }
          ]
        }
      }

      assert {:ok, %Bourse.Greeks{symbol: "BTC/USDC:USDC-250131-100000-C", delta: 0.5}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_greeks,
                 "fetchGreeks",
                 body,
                 %{"symbol" => "BTC/USDC:USDC-250131-100000-C"},
                 :parse_greeks,
                 false
               )
    end

    test "fetchFundingRateHistory list and single backfill the request symbol" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "list" => [
            %{
              "symbol" => "BTCUSDT",
              "fundingRate" => "0.0001",
              "fundingRateTimestamp" => "1700000000000"
            }
          ]
        }
      }

      assert {:ok, [%Bourse.FundingRateHistory{symbol: "BTC/USDT:USDT", funding_rate: 0.0001}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_funding_rate_history,
                 "fetchFundingRateHistory",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_funding_rate_history,
                 true
               )

      assert {:ok, %Bourse.FundingRateHistory{symbol: "BTC/USDT:USDT"}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_funding_rate_history,
                 "fetchFundingRateHistory",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_funding_rate_history,
                 false
               )
    end

    test "fetchFundingRateHistory normalizes a Hyperliquid funding row" do
      exchange = Exchange.new!("hyperliquid")

      row = %{
        "coin" => "BTC",
        "fundingRate" => "0.0000125",
        "premium" => "0.0",
        "time" => 1_784_318_400_005
      }

      assert {:ok,
              [
                %Bourse.FundingRateHistory{
                  symbol: "BTC/USDC:USDC",
                  funding_rate: 0.0000125,
                  timestamp: 1_784_318_400_005,
                  info: ^row
                }
              ]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Hyperliquid,
                 :fetch_funding_rate_history,
                 "fetchFundingRateHistory",
                 [row],
                 %{"symbol" => "BTC/USDC:USDC"},
                 :parse_funding_rate_history,
                 true
               )
    end

    test "fetchTickers option symbols convert to Bybit native option ids" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "option",
          "list" => [
            %{"symbol" => "BTC-31JAN25-100000-C-USDC", "lastPrice" => "500"}
          ]
        }
      }

      assert {:ok, tickers} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_tickers,
                 "fetchTickers",
                 body,
                 %{"symbols" => ["BTC/USDC:USDC-250131-100000-C", "not-a-parseable-symbol"]},
                 :parse_ticker,
                 false
               )

      assert %Bourse.Ticker{symbol: "BTC/USDC:USDC-250131-100000-C", last: 500.0} =
               Map.fetch!(tickers, "BTC/USDC:USDC-250131-100000-C")
    end

    test "okx trading balance unwraps data[0].details account rows" do
      exchange = Exchange.new!("okx")

      body = %{
        "code" => "0",
        "data" => [
          %{
            "details" => [
              %{"ccy" => "BTC", "availBal" => "1", "eq" => "1", "frozenBal" => "0"}
            ],
            "totalEq" => "1"
          }
        ]
      }

      assert {:ok, %Bourse.Balance{free: free, total: total}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )

      assert free["BTC"] == 1.0
      assert total["BTC"] == 1.0
    end

    test "okx funding balance normalizes bare data currency rows" do
      exchange = Exchange.new!("okx")

      # Funding accounts return currency rows directly under data[].
      body = %{
        "code" => "0",
        "data" => [
          %{"ccy" => "USDT", "availBal" => "10", "bal" => "10", "frozenBal" => "0"}
        ]
      }

      assert {:ok, %Bourse.Balance{}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_balance,
                 "fetchBalance",
                 body,
                 %{},
                 :parse_balance,
                 false
               )
    end

    test "map error object body is rejected as an exchange error" do
      exchange = Exchange.new!("bybit")

      assert {:error, %Error{type: :exchange_error, raw: %{"error" => %{"msg" => "x"}}}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 %{"error" => %{"msg" => "x"}},
                 %{},
                 :parse_position,
                 true
               )
    end

    test "empty open-order list is order_not_found for single-order reads" do
      exchange = Exchange.new!("bybit")

      body = %{"retCode" => 0, "result" => %{"list" => []}}

      assert {:error, %Error{type: :order_not_found}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_open_order,
                 "fetchOpenOrder",
                 body,
                 %{"id" => "missing"},
                 :parse_order,
                 false
               )
    end

    test "funding history with an unresolved market family fails loudly" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "list" => [
            %{
              "symbol" => "???",
              "funding" => "1",
              "fundingRate" => "0.1",
              "execTime" => "1700000000000",
              "transactionId" => "t"
            }
          ]
        }
      }

      assert {:error, %Error{message: message}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 body,
                 %{"symbol" => "NOTASYMBOL"},
                 :parse_funding_history,
                 true
               )

      assert message =~ "Cannot resolve unified symbol"
    end

    test "bybit linear futures market builds expiry-suffixed symbol" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "linear",
          "list" => [
            %{
              "symbol" => "BTC-26JUN26",
              "baseCoin" => "BTC",
              "quoteCoin" => "USDT",
              "settleCoin" => "USDT",
              "status" => "Trading",
              "contractType" => "LinearFutures",
              "deliveryTime" => "1782432000000",
              "launchTime" => "1"
            }
          ]
        }
      }

      assert {:ok, [%Bourse.Market{symbol: symbol}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_markets,
                 "fetchMarkets",
                 body,
                 %{"category" => "linear"},
                 :parse_market,
                 true
               )

      assert symbol == "BTC/USDT:USDT-260626"
    end

    test "funding-history rows without timestamp sort as epoch 0" do
      exchange = Exchange.new!("binance")
      body = [%{"t" => nil}, %{"t" => 200}, %{"t" => 100}]

      assert {:ok, rows} =
               ReadParse.parse(
                 exchange,
                 SparseFundingHistoryParser,
                 :fetch_funding_history,
                 "fetchFundingHistory",
                 body,
                 %{},
                 :parse_funding_history,
                 true
               )

      assert Enum.map(rows, & &1.timestamp) == [nil, 100, 200]
    end

    test "borrow-rate enrich defaults period when hourly rate is absent" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.BorrowRate{period: 86_400_000}} =
               ReadParse.parse(
                 exchange,
                 DailyBorrowParser,
                 :fetch_borrow_rate,
                 "fetchBorrowRate",
                 %{"currency" => "USDT", "dailyBorrowRate" => "0.01"},
                 %{},
                 :parse_borrow_rate,
                 false
               )
    end

    test "borrow-rate enrich uses 1h period when hourlyBorrowRate is present" do
      exchange = Exchange.new!("binance")

      assert {:ok, %Bourse.BorrowRate{period: 3_600_000}} =
               ReadParse.parse(
                 exchange,
                 HourlyBorrowParser,
                 :fetch_borrow_rate,
                 "fetchBorrowRate",
                 %{"currency" => "USDT", "hourlyBorrowRate" => "0.0001"},
                 %{},
                 :parse_borrow_rate,
                 false
               )
    end

    test "list trade enrich zips each struct with its raw row" do
      exchange = Exchange.new!("binance")

      assert {:ok, [%Bourse.Trade{price: 1.0, info: %{"price" => "1"}}]} =
               ReadParse.parse(
                 exchange,
                 ListInfoTradeParser,
                 :fetch_trades,
                 "fetchTrades",
                 [%{"price" => "1"}],
                 %{"symbol" => "BTC/USDT"},
                 :parse_trade,
                 true
               )
    end

    test "funding rate list rows accept a singular request symbol override" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "list" => [
            %{"symbol" => "BTCUSDT", "fundingRate" => "0.1"}
          ]
        }
      }

      assert {:ok, rates} =
               ReadParse.parse(
                 exchange,
                 FundingRateListParser,
                 :fetch_funding_rates,
                 "fetchFundingRates",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_funding_rate,
                 true
               )

      assert [%Bourse.FundingRate{symbol: "BTC/USDT:USDT", funding_rate: 0.1}] = rates
    end

    test "singular fetch_funding_rate refuses a fundingless spot symbol" do
      exchange = Exchange.new!("binance")

      body = %{
        "lastFundingRate" => "0.00008235",
        "markPrice" => "64346.85",
        "symbol" => "BTC/USDT:USDT",
        "time" => 1_787_097_890_001
      }

      assert {:error, %Error{type: :exchange_error, message: message, raw: raw}} =
               ReadParse.parse(
                 exchange,
                 FundingRateRowParser,
                 :fetch_funding_rate,
                 "fetchFundingRate",
                 body,
                 %{"symbol" => "BTC/USDT"},
                 :parse_funding_rate,
                 false
               )

      assert message =~ "BTC/USDT is fundingless"
      assert raw == %{reason: :fundingless_symbol, symbol: "BTC/USDT"}
    end

    test "singular fetch_funding_rate refuses an empty payload as unservable" do
      exchange = Exchange.new!("binance")

      assert {:error, %Error{type: :exchange_error, message: message, raw: raw}} =
               ReadParse.parse(
                 exchange,
                 FundingRateRowParser,
                 :fetch_funding_rate,
                 "fetchFundingRate",
                 [],
                 %{"symbol" => "BTC/USD:BTC"},
                 :parse_funding_rate,
                 false
               )

      assert message =~ "BTC/USD:BTC is not servable on this funding-rate surface"
      assert raw == %{reason: :unservable_funding_symbol, symbol: "BTC/USD:BTC"}
    end

    test "singular fetch_funding_rate keeps the venue-answered market identity" do
      exchange = Exchange.new!("binance")

      body = %{
        "lastFundingRate" => "0.00008235",
        "markPrice" => "64346.85",
        "symbol" => "BTC/USDT:USDT",
        "time" => 1_787_097_890_001
      }

      assert {:ok, %Bourse.FundingRate{symbol: "BTC/USDT:USDT", funding_rate: 8.235e-5}} =
               ReadParse.parse(
                 exchange,
                 FundingRateRowParser,
                 :fetch_funding_rate,
                 "fetchFundingRate",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_funding_rate,
                 false
               )
    end

    test "singular fetch_funding_rate refuses to re-label another market's row" do
      exchange = Exchange.new!("binance")

      body = %{
        "lastFundingRate" => "0.00008235",
        "markPrice" => "64346.85",
        "symbol" => "BTC/USDT:USDT",
        "time" => 1_787_097_890_001
      }

      assert {:error, %Error{type: :exchange_error, message: message, raw: raw}} =
               ReadParse.parse(
                 exchange,
                 FundingRateRowParser,
                 :fetch_funding_rate,
                 "fetchFundingRate",
                 body,
                 %{"symbol" => "ETH/USDT:USDT"},
                 :parse_funding_rate,
                 false
               )

      assert message =~ "requested ETH/USDT:USDT"
      assert message =~ "answered for BTC/USDT:USDT"
      assert raw == %{reason: :funding_symbol_mismatch, requested: "ETH/USDT:USDT", answered: "BTC/USDT:USDT"}
    end

    test "order pagination cursor merges onto a single map payload" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "linear",
          "nextPageCursor" => "solo-cursor",
          "list" => [
            order_row("solo", "1784189372501")
          ]
        }
      }

      assert {:ok, %Bourse.Order{} = order} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_closed_order,
                 "fetchClosedOrder",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_order,
                 false
               )

      assert order.info["nextPageCursor"] == "solo-cursor"
    end

    test "open-interest pagination cursor stamps a single result map" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "list" => [
            %{"openInterest" => "1.5", "symbol" => "BTCUSDT"}
          ],
          "nextPageCursor" => "oi-cursor"
        }
      }

      assert {:ok, %Bourse.OpenInterest{} = oi} =
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

      assert oi.symbol == "BTC/USDT:USDT"
    end

    test "closed-orders multi-row cursor stamps only the first raw row" do
      exchange = Exchange.new!("bybit")

      body = %{
        "retCode" => 0,
        "result" => %{
          "category" => "linear",
          "nextPageCursor" => "c1",
          "list" => [
            order_row("a", "1"),
            order_row("b", "2")
          ]
        }
      }

      assert {:ok, [first, second]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_closed_orders,
                 "fetchClosedOrders",
                 body,
                 %{},
                 :parse_order,
                 true
               )

      assert first.info["nextPageCursor"] == "c1"
      refute Map.has_key?(second.info, "nextPageCursor")
    end

    test "map-shaped trade parse normalizes each entry and its symbol key" do
      exchange = Exchange.new!("bybit")

      assert {:ok, %{"BTC/USDT:USDT" => %Bourse.Trade{symbol: "BTC/USDT:USDT", price: 1.0}}} =
               ReadParse.parse(
                 exchange,
                 MapTradeParser,
                 :fetch_trades,
                 "fetchTrades",
                 %{},
                 %{},
                 :parse_trade,
                 false
               )
    end

    test "option data native ids resolve as option markets" do
      exchange = Exchange.new!("bybit")

      # Omit category so native_market_type/2 hits the OptionData struct clause
      # rather than the info-category short-circuit.
      assert {:ok, %Bourse.OptionData{symbol: symbol}} =
               ReadParse.parse(
                 exchange,
                 OptionDataParser,
                 :fetch_option,
                 "fetchOption",
                 %{"symbol" => "BTC-31JAN25-100000-C"},
                 %{},
                 :parse_option,
                 false
               )

      assert is_binary(symbol)
      assert String.contains?(symbol, "BTC")
    end

    test "greeks native option id with settle suffix resolves as option" do
      exchange = Exchange.new!("bybit")

      assert {:ok, %Bourse.Greeks{symbol: "BTC/USDC:USDC-250131-100000-C", delta: 0.1}} =
               ReadParse.parse(
                 exchange,
                 GreeksNativeParser,
                 :fetch_greeks,
                 "fetchGreeks",
                 %{"symbol" => "BTC-31JAN25-100000-C-USDC", "delta" => "0.1"},
                 %{},
                 :parse_greeks,
                 false
               )
    end

    test "fetchAllGreeks fills nil symbols from the symbols request list" do
      exchange = Exchange.new!("bybit")

      # No native symbol in info — requested_symbol_or_first fills from symbols[].
      assert {:ok, greeks} =
               ReadParse.parse(
                 exchange,
                 GreeksNativeParser,
                 :fetch_all_greeks,
                 "fetchAllGreeks",
                 [%{"delta" => "0.1"}],
                 %{"symbols" => ["BTC/USDC:USDC-250131-100000-C"]},
                 :parse_greeks,
                 true
               )

      assert %{"BTC/USDC:USDC-250131-100000-C" => %Bourse.Greeks{}} = greeks
    end

    test "market symbol falls back to base/quote/settle components" do
      exchange = Exchange.new!("bybit")

      assert {:ok, [%Bourse.Market{symbol: "BTC/USDT:USDT", base: "BTC", settle: "USDT"}]} =
               ReadParse.parse(
                 exchange,
                 ComponentMarketParser,
                 :fetch_markets,
                 "fetchMarkets",
                 [%{"foo" => 1}],
                 %{},
                 :parse_market,
                 true
               )
    end

    test "volatility history falls back to body result list or empty" do
      exchange = Exchange.new!("deribit")

      assert {:ok, [%Bourse.VolatilityHistory{volatility: 0.5}]} =
               ReadParse.parse(
                 exchange,
                 BareVolHistoryParser,
                 :fetch_volatility_history,
                 "fetchVolatilityHistory",
                 %{"result" => [[1, 0.5]]},
                 %{},
                 :parse_volatility_history,
                 true
               )

      assert {:ok, [%Bourse.VolatilityHistory{volatility: 0.6}]} =
               ReadParse.parse(
                 exchange,
                 BareVolHistoryParser,
                 :fetch_volatility_history,
                 "fetchVolatilityHistory",
                 [[2, 0.6]],
                 %{},
                 :parse_volatility_history,
                 true
               )

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 BareVolHistoryParser,
                 :fetch_volatility_history,
                 "fetchVolatilityHistory",
                 %{"no" => "rows"},
                 %{},
                 :parse_volatility_history,
                 true
               )
    end

    test "non-balance parse result skips balance info stamping" do
      exchange = Exchange.new!("bybit")

      assert {:ok, %{not: :balance}} =
               ReadParse.parse(
                 exchange,
                 NonBalanceParser,
                 :fetch_balance,
                 "fetchBalance",
                 %{},
                 %{},
                 :parse_balance,
                 false
               )
    end

    test "nil error field does not short-circuit a successful retCode" do
      exchange = Exchange.new!("bybit")

      assert {:ok, []} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_positions,
                 "fetchPositions",
                 %{"error" => nil, "retCode" => 0, "result" => %{"list" => []}},
                 %{},
                 :parse_position,
                 true
               )
    end

    test "market components catch-all leaves symbol nil when base/quote/settle absent" do
      exchange = Exchange.new!("bybit")

      assert {:ok, [%Bourse.Market{symbol: nil}]} =
               ReadParse.parse(
                 exchange,
                 NilComponentMarketParser,
                 :fetch_markets,
                 "fetchMarkets",
                 [%{"x" => 1}],
                 %{},
                 :parse_market,
                 true
               )
    end

    test "bybit futures deliveryTime unparseable or zero-padded yields no expiry suffix" do
      exchange = Exchange.new!("bybit")

      for delivery <- ["abc", "00"] do
        body = %{
          "retCode" => 0,
          "result" => %{
            "category" => "linear",
            "list" => [
              %{
                "symbol" => "XRPUSDT",
                "baseCoin" => "XRP",
                "quoteCoin" => "USDT",
                "settleCoin" => "USDT",
                "status" => "Trading",
                "contractType" => "LinearFutures",
                "deliveryTime" => delivery,
                "launchTime" => "1"
              }
            ]
          }
        }

        assert {:ok, [%Bourse.Market{symbol: "XRP/USDT:USDT"}]} =
                 ReadParse.parse(
                   exchange,
                   Bourse.Bybit,
                   :fetch_markets,
                   "fetchMarkets",
                   body,
                   %{"category" => "linear"},
                   :parse_market,
                   true
                 )
      end
    end

    test "lighter market symbol keeps slash form and uppercases bare ids" do
      exchange = Exchange.new!("lighter")

      assert {:ok, [%Bourse.Market{symbol: "BTC/USDC"}]} =
               ReadParse.parse(
                 exchange,
                 LighterMarketParser,
                 :fetch_markets,
                 "fetchMarkets",
                 [%{"symbol" => "BTC/USDC", "market_type" => "spot"}],
                 %{},
                 :parse_market,
                 true
               )

      assert {:ok, [%Bourse.Market{symbol: "BTC"}]} =
               ReadParse.parse(
                 exchange,
                 LighterMarketParser,
                 :fetch_markets,
                 "fetchMarkets",
                 [%{"symbol" => "BTC", "market_type" => "spot"}],
                 %{},
                 :parse_market,
                 true
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp bybit_position_body(category, row, opts \\ []) do
    time = Keyword.get(opts, :time, 1_700_000_000_000)

    %{
      "retCode" => 0,
      "time" => time,
      "result" => %{
        "category" => category,
        "list" => [row]
      }
    }
  end

  defp linear_open_row do
    %{
      "symbol" => "BTCUSDT",
      "size" => "0.1",
      "markPrice" => "50000",
      "positionValue" => "5000",
      "liqPrice" => "45000",
      "bustPrice" => "44000",
      "positionMM" => "50",
      "positionIM" => "500",
      "side" => "Buy",
      "avgPrice" => "50000",
      "unrealisedPnl" => "0",
      "createdTime" => "1700000000000",
      "updatedTime" => "1700000000000"
    }
  end

  defp inverse_open_row do
    %{
      "symbol" => "BTCUSD",
      "size" => "100",
      "markPrice" => "50000",
      "positionValue" => "0.002",
      "liqPrice" => "40000",
      "bustPrice" => "39000",
      "positionMM" => "0.00005",
      "positionIM" => "0.0001",
      "side" => "Buy",
      "avgPrice" => "50000",
      "unrealisedPnl" => "0",
      "createdTime" => "1700000000000",
      "updatedTime" => "1700000000000"
    }
  end

  defp order_row(id, created) do
    %{
      "orderId" => id,
      "symbol" => "BTCUSDT",
      "orderStatus" => "Filled",
      "orderType" => "Limit",
      "side" => "Buy",
      "price" => "10000",
      "qty" => "0.001",
      "avgPrice" => "10000",
      "cumExecQty" => "0.001",
      "cumExecValue" => "10",
      "createdTime" => created,
      "updatedTime" => created
    }
  end

  defp bybit_adl_body do
    %{
      "retCode" => 0,
      "result" => %{
        "category" => "linear",
        "list" => [
          %{"symbol" => "BTCUSDT", "adlRankIndicator" => 2}
        ]
      }
    }
  end
end
