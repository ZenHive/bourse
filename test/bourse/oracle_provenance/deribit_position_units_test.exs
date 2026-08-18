defmodule Bourse.OracleProvenance.DeribitPositionUnitsTest do
  use ExUnit.Case, async: true

  alias Bourse.OracleProvenance.DeribitPositionUnits

  test "registered inverse and linear rows satisfy the provider unit contract" do
    assert :ok = DeribitPositionUnits.validate!()
  end

  test "inverse notional sourcing regression fails the oracle" do
    assert_raise ArgumentError, ~r/BTC-PERPETUAL notional expected/, fn ->
      DeribitPositionUnits.validate!(
        position_transform: fn positions ->
          replace_notional(positions, "BTC-PERPETUAL", & &1.base_quantity)
        end
      )
    end
  end

  test "linear notional sourcing regression fails the oracle" do
    assert_raise ArgumentError, ~r/ETH_USDC-PERPETUAL notional expected/, fn ->
      DeribitPositionUnits.validate!(
        position_transform: fn positions ->
          replace_notional(positions, "ETH_USDC-PERPETUAL", & &1.base_quantity)
        end
      )
    end
  end

  defp replace_notional(positions, instrument_name, replacement) do
    Enum.map(positions, fn position ->
      if position.info["instrument_name"] == instrument_name do
        %{position | notional: replacement.(position)}
      else
        position
      end
    end)
  end
end
