defmodule Bourse.PositionUnitInvariantTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Position
  alias Bourse.RecordedResponseFixtures
  alias Bourse.Unified.DeribitPositionUnits
  alias Bourse.Unified.ReadParse

  @unit_tolerance 1.0e-6

  # Recordings whose position list is empty cannot certify payload keys.
  # Drop a venue from this list when its fetch_positions recording gains rows.
  @unpopulated_position_recordings ~w(alpaca derive hyperliquid)

  test "every authored position slice emits a frozen notional with a machine-readable currency" do
    for position_case <- position_cases() do
      position = parse_position!(position_case)

      assert is_number(position.notional),
             "#{position_case.venue} did not emit a numeric notional: #{inspect(position)}"

      assert_in_delta position.notional,
                      position_case.expected_notional,
                      @unit_tolerance,
                      "#{position_case.venue} changed its frozen position notional unit"

      assert position.notional_currency == position_case.expected_notional_currency,
             "#{position_case.venue} changed its frozen position notional currency"

      assert_in_delta position.contracts,
                      position_case.expected_contracts,
                      @unit_tolerance,
                      "#{position_case.venue} changed its frozen position contract unit"

      assert_contract_size(position, position_case)
      assert_base_quantity(position, position_case)
      assert_quantity_arithmetic(position, position_case)
    end
  end

  test "frozen rows are venue payloads without parser annotations" do
    for %{venue: venue, row: row} <- position_cases() do
      refute synthetic_key?(row), "#{venue} invariant row pre-seeds a _bourse_* annotation"
    end
  end

  test "base_quantity is scoped to Deribit futures rather than all position rows" do
    exchange = Exchange.new!("deribit")

    assert {:ok, %Position{base_quantity: nil, contracts: 0.25, notional: nil}} =
             ReadParse.parse(
               exchange,
               Bourse.Deribit,
               :fetch_position,
               "fetchPosition",
               %{
                 "direction" => "buy",
                 "instrument_name" => "ETH-25SEP26-2700-P",
                 "kind" => "option",
                 "mark_price" => 0.4,
                 "size" => 0.25
               },
               %{"symbol" => "ETH/USD:ETH-260925-2700-P"},
               :parse_position,
               false
             )
  end

  test "every authored position slice carries a frozen invariant row" do
    authored =
      Bourse.Spec.exchanges()
      |> Enum.filter(&position_slice?/1)
      |> MapSet.new()

    frozen = MapSet.new(position_cases(), & &1.venue)

    assert MapSet.to_list(MapSet.difference(authored, frozen)) == [],
           "a venue authors a position slice with no frozen unit row"

    assert MapSet.to_list(MapSet.difference(frozen, authored)) == [],
           "a frozen unit row names a venue that authors no position slice"
  end

  test "unit-matrix payloads carry only keys present on the recorded venue row" do
    for position_case <- position_cases() do
      assert_recorded_payload_keys!(position_case)
    end
  end

  test "an injected recording-absent key is rejected" do
    inverse_bybit = Enum.find(position_cases(), &(&1.venue == "bybit" and &1.symbol == "BTC/USD:BTC"))
    injected = %{inverse_bybit | row: Map.put(inverse_bybit.row, "contractSize", "1")}

    assert_raise ExUnit.AssertionError, ~r/contractSize/, fn ->
      assert_recorded_payload_keys!(injected)
    end
  end

  test "unpopulated position recordings stay empty so the payload-key guard remains honest" do
    for venue <- @unpopulated_position_recordings do
      assert recorded_position_rows(venue) == [],
             "#{venue} fetch_positions now has rows; drop it from @unpopulated_position_recordings"
    end
  end

  defp position_slice?(venue) do
    case Bourse.Spec.load!(venue) do
      %{"normalization" => %{"field_maps" => %{"position" => slice}}} -> is_map(slice)
      _spec -> false
    end
  end

  defp assert_contract_size(%Position{contract_size: nil}, %{expected_contract_size: nil}), do: :ok

  defp assert_contract_size(position, position_case) do
    assert_in_delta position.contract_size,
                    position_case.expected_contract_size,
                    @unit_tolerance,
                    "#{position_case.venue} changed its frozen contract-size unit"
  end

  defp assert_base_quantity(position, %{expected_emitted_base_quantity: expected}) do
    assert_in_delta position.base_quantity,
                    expected,
                    @unit_tolerance,
                    "position base quantity changed its frozen unit"
  end

  defp assert_base_quantity(%Position{base_quantity: base_quantity}, position_case) do
    assert is_nil(base_quantity),
           "#{position_case.venue} emitted base_quantity outside the Deribit-future scope"
  end

  defp assert_quantity_arithmetic(position, %{quantity_basis: :shares} = position_case) do
    assert_in_delta position.contracts * unit_price!(position, position_case),
                    position.notional,
                    @unit_tolerance,
                    "#{position_case.venue} shares and price no longer reconcile with notional"
  end

  defp assert_quantity_arithmetic(position, %{quantity_basis: :quote_contract} = position_case) do
    quote_quantity = position.contracts * position.contract_size

    if position_case.expected_notional_currency == quote_currency(position.symbol) do
      assert_in_delta quote_quantity,
                      position.notional,
                      @unit_tolerance,
                      "#{position_case.venue} quote contracts no longer reconcile with notional"
    else
      assert_in_delta quote_quantity,
                      position.notional * unit_price!(position, position_case),
                      @unit_tolerance,
                      "#{position_case.venue} quote contracts no longer reconcile with settlement notional"
    end
  end

  defp assert_quantity_arithmetic(position, %{quantity_basis: :base_contract} = position_case) do
    base_quantity = position.contracts * position.contract_size

    assert_in_delta base_quantity,
                    position_case.expected_base_quantity,
                    @unit_tolerance,
                    "#{position_case.venue} contracts no longer reconcile with base quantity"

    assert_in_delta base_quantity * unit_price!(position, position_case),
                    position.notional,
                    @unit_tolerance,
                    "#{position_case.venue} base quantity and price no longer reconcile with quote notional"
  end

  defp unit_price!(position, position_case) do
    price = position.mark_price || position.entry_price || position.last_price

    assert is_number(price),
           "#{position_case.venue} frozen row has no mark, entry, or last price for unit arithmetic"

    price
  end

  defp quote_currency(symbol) do
    assert {:ok, %{quote: quote}} = Bourse.Symbol.parse_extended(symbol)
    quote
  end

  defp synthetic_key?(%{} = map) do
    Enum.any?(map, fn
      {"_bourse_" <> _rest, _value} -> true
      {_key, value} -> synthetic_key?(value)
    end)
  end

  defp synthetic_key?(list) when is_list(list), do: Enum.any?(list, &synthetic_key?/1)
  defp synthetic_key?(_value), do: false

  defp parse_position!(position_case) do
    exchange =
      position_case.venue
      |> Exchange.new!()
      |> Exchange.put_markets(position_case.markets)

    exchange = %{
      exchange
      | spec: put_in(exchange.spec, ["capabilities", "mapping_complete", "fetchPosition"], true)
    }

    assert {:ok, %Position{} = position} =
             ReadParse.parse(
               exchange,
               position_case.module,
               :fetch_position,
               "fetchPosition",
               position_case.row,
               %{"symbol" => position_case.symbol},
               :parse_position,
               false
             )

    assert {:ok, %Position{} = reconciled} =
             DeribitPositionUnits.reconcile({:ok, position}, exchange)

    reconciled
  end

  defp position_cases do
    [
      %{
        venue: "alpaca",
        module: Bourse.Alpaca,
        symbol: "AAPL",
        row: %{"current_price" => "300", "market_value" => "-450", "qty" => "-1.5", "symbol" => "AAPL"},
        markets: [],
        expected_base_quantity: 1.5,
        expected_contracts: 1.5,
        expected_contract_size: nil,
        expected_notional: 450.0,
        expected_notional_currency: "USD",
        quantity_basis: :shares
      },
      binance_position_case("binance", Bourse.Binance),
      %{
        venue: "binancecoinm",
        module: Bourse.Binancecoinm,
        symbol: "ETH/USD:ETH",
        row: %{
          "markPrice" => "2000",
          "notionalValue" => "0.01",
          "positionAmt" => "2",
          "symbol" => "ETHUSD_PERP"
        },
        markets: [
          %Market{
            id: "ETHUSD_PERP",
            symbol: "ETH/USD:ETH",
            contract: true,
            swap: true,
            inverse: true,
            contract_size: 10.0
          }
        ],
        expected_contracts: 2.0,
        expected_contract_size: 10.0,
        expected_notional: 0.01,
        expected_notional_currency: "ETH",
        quantity_basis: :quote_contract
      },
      binance_position_case("binanceusdm", Bourse.Binanceusdm),
      %{
        venue: "bybit",
        module: Bourse.Bybit,
        symbol: "BTC/USDT:USDT",
        row: %{
          "markPrice" => "50000",
          "positionValue" => "5000",
          "side" => "Buy",
          "size" => "0.1",
          "symbol" => "BTCUSDT"
        },
        markets: [],
        expected_base_quantity: 0.1,
        expected_contracts: 0.1,
        expected_contract_size: 1.0,
        expected_notional: 5000.0,
        expected_notional_currency: "USDT",
        quantity_basis: :base_contract
      },
      %{
        venue: "bybit",
        module: Bourse.Bybit,
        symbol: "BTC/USD:BTC",
        row: %{
          "markPrice" => "50000",
          "side" => "Buy",
          "size" => "100",
          "symbol" => "BTCUSD"
        },
        markets: [],
        expected_contracts: 100.0,
        expected_contract_size: 1.0,
        expected_notional: 0.002,
        expected_notional_currency: "BTC",
        quantity_basis: :quote_contract
      },
      %{
        venue: "deribit",
        module: Bourse.Deribit,
        symbol: "BTC/USD:BTC",
        row: %{
          "direction" => "buy",
          "instrument_name" => "BTC-PERPETUAL",
          "kind" => "future",
          "mark_price" => 7476.65,
          "size" => 50,
          "size_currency" => 0.006687487
        },
        markets: [%Market{id: "BTC-PERPETUAL", symbol: "BTC/USD:BTC", contract_size: 10.0, inverse: true}],
        expected_base_quantity: 0.006687487,
        expected_emitted_base_quantity: 0.006687487,
        expected_contracts: 5.0,
        expected_contract_size: 10.0,
        expected_notional: 50.0,
        expected_notional_currency: "USD",
        quantity_basis: :quote_contract
      },
      %{
        venue: "deribit",
        module: Bourse.Deribit,
        symbol: "ETH/USDC:USDC",
        row: %{
          "direction" => "buy",
          "instrument_name" => "ETH_USDC-PERPETUAL",
          "kind" => "future",
          "mark_price" => 3000.25,
          "size" => 1500.125,
          "size_currency" => 0.5
        },
        markets: [
          %Market{
            id: "ETH_USDC-PERPETUAL",
            symbol: "ETH/USDC:USDC",
            contract_size: 0.001,
            inverse: false,
            linear: true
          }
        ],
        expected_base_quantity: 0.5,
        expected_emitted_base_quantity: 0.5,
        expected_contracts: 500.0,
        expected_contract_size: 0.001,
        expected_notional: 1500.125,
        expected_notional_currency: "USDC",
        quantity_basis: :base_contract
      },
      %{
        venue: "deribit",
        module: Bourse.Deribit,
        symbol: "ETH/USD:ETH-260925-2700-P",
        row: %{
          "direction" => "buy",
          "instrument_name" => "ETH-25SEP26-2700-P",
          "kind" => "option",
          "mark_price" => 0.415961,
          "size" => 0.1
        },
        markets: [
          %Market{
            id: "ETH-25SEP26-2700-P",
            symbol: "ETH/USD:ETH-260925-2700-P",
            contract_size: 1.0,
            option: true
          }
        ],
        expected_base_quantity: 0.1,
        expected_contracts: 0.1,
        expected_contract_size: 1.0,
        expected_notional: 0.0415961,
        expected_notional_currency: "ETH",
        quantity_basis: :base_contract
      },
      %{
        venue: "derive",
        module: Bourse.Derive,
        symbol: "ETH/USDC:USDC",
        row: %{"amount" => "-0.5", "instrument_name" => "ETH-PERP", "mark_price" => "100"},
        markets: [],
        expected_base_quantity: 0.5,
        expected_contracts: 0.5,
        expected_contract_size: 1.0,
        expected_notional: 50.0,
        expected_notional_currency: "USDC",
        quantity_basis: :base_contract
      },
      %{
        venue: "hyperliquid",
        module: Bourse.Hyperliquid,
        symbol: "ETH/USDC:USDC",
        row: %{
          "position" => %{
            "coin" => "ETH",
            "entryPx" => "100",
            "leverage" => %{"type" => "cross", "value" => "5"},
            "positionValue" => "50",
            "szi" => "0.5"
          },
          "type" => "oneWay"
        },
        markets: [],
        expected_base_quantity: 0.5,
        expected_contracts: 0.5,
        expected_contract_size: 1.0,
        expected_notional: 50.0,
        expected_notional_currency: "USDC",
        quantity_basis: :base_contract
      },
      %{
        venue: "lighter",
        module: Bourse.Lighter,
        symbol: "BTC/USDC:USDC",
        row: %{"avg_entry_price" => "100", "market_id" => 1, "position" => "0.25", "position_value" => "25"},
        markets: [%Market{id: "1", symbol: "BTC/USDC:USDC", contract_size: 1.0, linear: true, swap: true}],
        expected_base_quantity: 0.25,
        expected_contracts: 0.25,
        expected_contract_size: 1.0,
        expected_notional: 25.0,
        expected_notional_currency: "USDC",
        quantity_basis: :base_contract
      },
      %{
        venue: "okx",
        module: Bourse.Okx,
        symbol: "BTC/USDT:USDT",
        row: %{
          "instId" => "BTC-USDT-SWAP",
          "instType" => "SWAP",
          "markPx" => "100",
          "mgnMode" => "cross",
          "notionalUsd" => "50",
          "pos" => "0.5",
          "posSide" => "net"
        },
        markets: [
          %Market{
            id: "BTC-USDT-SWAP",
            symbol: "BTC/USDT:USDT",
            contract_size: 1.0,
            contract: true,
            linear: true,
            swap: true
          }
        ],
        expected_base_quantity: 0.5,
        expected_contracts: 0.5,
        expected_contract_size: 1.0,
        expected_notional: 50.0,
        expected_notional_currency: "USD",
        quantity_basis: :base_contract
      },
      %{
        venue: "okx",
        module: Bourse.Okx,
        symbol: "BTC/USD:BTC",
        row: %{
          "instId" => "BTC-USD-SWAP",
          "instType" => "SWAP",
          "markPx" => "2000",
          "mgnMode" => "cross",
          "pos" => "2",
          "posSide" => "net"
        },
        markets: [
          %Market{
            id: "BTC-USD-SWAP",
            symbol: "BTC/USD:BTC",
            contract_size: 10.0,
            contract: true,
            inverse: true,
            swap: true
          }
        ],
        expected_contracts: 2.0,
        expected_contract_size: 10.0,
        expected_notional: 0.01,
        expected_notional_currency: "BTC",
        quantity_basis: :quote_contract
      }
    ]
  end

  defp assert_recorded_payload_keys!(%{venue: venue, row: row} = position_case) do
    if venue in @unpopulated_position_recordings do
      :ok
    else
      recorded_keys = recorded_position_keys(venue)
      payload_keys = map_keys(row)
      extra = MapSet.difference(payload_keys, recorded_keys)

      assert MapSet.size(extra) == 0,
             "#{fixture_label(position_case)} payload keys absent from the recorded row: #{inspect(MapSet.to_list(extra))}"
    end
  end

  defp recorded_position_keys(venue) do
    venue
    |> recorded_position_rows()
    |> map_keys()
  end

  defp recorded_position_rows(venue) do
    fixture_venue = recorded_fixture_venue(venue)

    fixture_venue
    |> RecordedResponseFixtures.fixture_path(:fetch_positions)
    |> RecordedResponseFixtures.load_fixture!()
    |> position_rows(fixture_venue)
  end

  defp recorded_fixture_venue("binance"), do: "binanceusdm"
  defp recorded_fixture_venue(venue), do: venue

  defp position_rows(%{"body" => %{"result" => %{"list" => list}}}, "bybit") when is_list(list), do: list
  defp position_rows(%{"body" => %{"data" => list}}, "okx") when is_list(list), do: list
  defp position_rows(%{"body" => %{"result" => list}}, "deribit") when is_list(list), do: list
  defp position_rows(%{"body" => %{"result" => %{"positions" => list}}}, "derive") when is_list(list), do: list
  defp position_rows(%{"body" => %{"assetPositions" => list}}, "hyperliquid") when is_list(list), do: list

  defp position_rows(%{"body" => %{"accounts" => accounts}}, "lighter") when is_list(accounts) do
    Enum.flat_map(accounts, fn
      %{"positions" => list} when is_list(list) -> list
      _account -> []
    end)
  end

  defp position_rows(%{"body" => list}, venue) when is_list(list) and venue in ["alpaca", "binanceusdm", "binancecoinm"],
    do: list

  defp position_rows(_fixture, venue) do
    flunk("#{venue} fetch_positions recording has no recognized position-row envelope")
  end

  defp map_keys(%{} = map) do
    Enum.reduce(map, MapSet.new(), fn {key, value}, acc ->
      acc
      |> MapSet.put(key)
      |> MapSet.union(map_keys(value))
    end)
  end

  defp map_keys(list) when is_list(list) do
    Enum.reduce(list, MapSet.new(), fn item, acc -> MapSet.union(acc, map_keys(item)) end)
  end

  defp map_keys(_value), do: MapSet.new()

  defp fixture_label(%{venue: venue, symbol: symbol}), do: "#{venue} #{symbol}"

  defp binance_position_case(venue, module) do
    %{
      venue: venue,
      module: module,
      symbol: "BTC/USDT:USDT",
      row: %{
        "markPrice" => "60000",
        "notional" => "540",
        "positionAmt" => "0.009",
        "symbol" => "BTCUSDT"
      },
      markets: [
        %Market{
          id: "BTCUSDT",
          symbol: "BTC/USDT:USDT",
          contract: true,
          swap: true,
          linear: true,
          contract_size: 1.0
        }
      ],
      expected_base_quantity: 0.009,
      expected_contracts: 0.009,
      expected_contract_size: 1.0,
      expected_notional: 540.0,
      expected_notional_currency: "USDT",
      quantity_basis: :base_contract
    }
  end
end
