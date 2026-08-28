defmodule Bourse.Test.RestReadContractOwnedStateTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.RestReadContractOwnedState

  test "open and canceled order sources are ownable; history windows are not" do
    context = %{exchange: nil, markets: [], venue: "example", venue_contract: %{}}
    contract_case = %{"id" => "example:fetchOrder:0:x", "market_kind" => "spot"}

    for source <- ["fetchOpenOrders", "fetchOrders", "fetchCanceledOrders"] do
      assert RestReadContractOwnedState.ownable_source?(source)
    end

    for source <- [
          "fetchClosedOrders",
          "fetchDeposits",
          "fetchWithdrawals",
          "fetchTransfers",
          "fetchOrderLists",
          "fetchConvertTradeHistory",
          "fetchBalance"
        ] do
      refute RestReadContractOwnedState.ownable_source?(source)

      assert :unownable =
               RestReadContractOwnedState.ensure(
                 %{"source_method" => source, "field" => "id"},
                 contract_case,
                 context
               )
    end
  end
end
