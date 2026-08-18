defmodule Bourse.PositionUnitInvariantTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Position
  alias Bourse.Unified.DeribitPositionUnits

  @unit_tolerance 1.0e-12
  @carve_register "docs/authored-spec-carves/global.md"

  test "every authored position slice preserves its frozen notional unit and reconciles or names its carve" do
    carve_register = File.read!(@carve_register)

    for position_case <- position_cases() do
      position = parse_position!(position_case)

      assert_in_delta position.notional,
                      position_case.expected_notional,
                      @unit_tolerance,
                      "#{position_case.venue} changed its frozen position notional unit"

      assert_in_delta position.contracts,
                      position_case.expected_contracts,
                      @unit_tolerance,
                      "#{position_case.venue} changed its frozen position contract unit"

      assert_contract_size(position, position_case)
      assert_base_quantity(position, position_case)

      assert position_case.quote_notional? or is_binary(position_case.exception)

      case position_case.exception do
        nil ->
          assert_in_delta position.contracts * position.contract_size,
                          position.notional,
                          @unit_tolerance,
                          "#{position_case.venue} contracts no longer reconcile with quote notional"

        exception ->
          assert carve_register =~ "`#{exception}`",
                 "#{position_case.venue} unit exception #{exception} is not documented"
      end
    end
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

  defp assert_base_quantity(position, %{expected_base_quantity: expected}) do
    assert_in_delta position.base_quantity,
                    expected,
                    @unit_tolerance,
                    "position base quantity changed its frozen unit"
  end

  defp assert_base_quantity(_position, _position_case), do: :ok

  defp parse_position!(position_case) do
    module = position_case.module

    assert {:ok, %Position{} = position} =
             module.parse_position(position_case.row, [])

    position = %{position | info: position_case.row}

    exchange =
      position_case.venue
      |> Exchange.new!()
      |> Exchange.put_markets(position_case.markets)

    assert {:ok, %Position{} = reconciled} =
             DeribitPositionUnits.reconcile({:ok, position}, exchange)

    reconciled
  end

  defp position_cases do
    [
      %{
        venue: "alpaca",
        module: Bourse.Alpaca,
        row: %{"qty" => "-1.5", "market_value" => "-450"},
        markets: [],
        expected_contracts: 1.5,
        expected_contract_size: nil,
        expected_notional: 450.0,
        quote_notional?: true,
        exception: "C-T610/alpaca-equity-share-quantity"
      },
      binance_position_case("binance", Bourse.Binance, "C-T610/binance-linear-base-contract"),
      %{
        venue: "binancecoinm",
        module: Bourse.Binancecoinm,
        row: %{
          "_bourse_contract_size" => 10,
          "_bourse_contracts" => 2,
          "_bourse_notional" => "0.01",
          "notionalValue" => "0.01",
          "positionAmt" => "2",
          "symbol" => "ETHUSD_PERP"
        },
        markets: [],
        expected_contracts: 2.0,
        expected_contract_size: 10.0,
        expected_notional: 0.01,
        quote_notional?: false,
        exception: "C-T610/binancecoinm-inverse-settlement-notional"
      },
      binance_position_case(
        "binanceusdm",
        Bourse.Binanceusdm,
        "C-T610/binanceusdm-linear-base-contract"
      ),
      %{
        venue: "bybit",
        module: Bourse.Bybit,
        row: %{
          "_bourse_contract_size" => 1,
          "_bourse_notional" => "5000",
          "positionValue" => "5000",
          "size" => "0.1",
          "symbol" => "BTCUSDT"
        },
        markets: [],
        expected_contracts: 0.1,
        expected_contract_size: 1.0,
        expected_notional: 5000.0,
        quote_notional?: true,
        exception: "C-T610/bybit-linear-base-contract"
      },
      %{
        venue: "deribit",
        module: Bourse.Deribit,
        row: %{
          "_bourse_inverse" => true,
          "instrument_name" => "BTC-PERPETUAL",
          "kind" => "future",
          "mark_price" => 7476.65,
          "size" => 50,
          "size_currency" => 0.006687487
        },
        markets: [%Market{id: "BTC-PERPETUAL", contract_size: 10.0, inverse: true}],
        expected_base_quantity: 0.006687487,
        expected_contracts: 5.0,
        expected_contract_size: 10.0,
        expected_notional: 50.0,
        quote_notional?: true,
        exception: nil
      },
      %{
        venue: "deribit",
        module: Bourse.Deribit,
        row: %{
          "_bourse_inverse" => false,
          "direction" => "buy",
          "instrument_name" => "ETH_USDC-PERPETUAL",
          "kind" => "future",
          "mark_price" => 3000.25,
          "size" => 1500.125,
          "size_currency" => 0.5
        },
        markets: [
          %Market{id: "ETH_USDC-PERPETUAL", contract_size: 0.001, inverse: false, linear: true}
        ],
        expected_base_quantity: 0.5,
        expected_contracts: 500.0,
        expected_contract_size: 0.001,
        expected_notional: 1500.125,
        quote_notional?: true,
        exception: "C-T611/deribit-linear-base-contract"
      },
      %{
        venue: "derive",
        module: Bourse.Derive,
        row: %{"_bourse_notional" => "50", "amount" => "0.5", "mark_price" => "100"},
        markets: [],
        expected_contracts: 0.5,
        expected_contract_size: 1.0,
        expected_notional: 50.0,
        quote_notional?: true,
        exception: "C-T610/derive-base-amount"
      },
      %{
        venue: "hyperliquid",
        module: Bourse.Hyperliquid,
        row: %{
          "_bourse_contract_size" => 1,
          "_bourse_contracts" => "0.5",
          "positionValue" => "50",
          "szi" => "0.5"
        },
        markets: [],
        expected_contracts: 0.5,
        expected_contract_size: 1.0,
        expected_notional: 50.0,
        quote_notional?: true,
        exception: "C-T610/hyperliquid-base-size"
      },
      %{
        venue: "lighter",
        module: Bourse.Lighter,
        row: %{"position" => "0.25", "position_value" => "25"},
        markets: [],
        expected_contracts: 0.25,
        expected_contract_size: 1.0,
        expected_notional: 25.0,
        quote_notional?: true,
        exception: "C-T610/lighter-base-position"
      },
      %{
        venue: "okx",
        module: Bourse.Okx,
        row: %{
          "_bourse_contract_size" => 1,
          "_bourse_notional" => "50",
          "instId" => "BTC-USDT-SWAP",
          "instType" => "SWAP",
          "pos" => "0.5"
        },
        markets: [],
        expected_contracts: 0.5,
        expected_contract_size: 1.0,
        expected_notional: 50.0,
        quote_notional?: true,
        exception: "C-T610/okx-linear-base-contract"
      }
    ]
  end

  defp binance_position_case(venue, module, exception) do
    %{
      venue: venue,
      module: module,
      row: %{
        "_bourse_contract_size" => 1,
        "_bourse_contracts" => "0.009",
        "_bourse_notional" => "607.52416678",
        "notional" => "607.52416678",
        "positionAmt" => "0.009",
        "symbol" => "BTCUSDT"
      },
      markets: [],
      expected_contracts: 0.009,
      expected_contract_size: 1.0,
      expected_notional: 607.52416678,
      quote_notional?: true,
      exception: exception
    }
  end
end
