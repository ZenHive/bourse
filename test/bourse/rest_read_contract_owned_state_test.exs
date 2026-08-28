defmodule Bourse.Test.RestReadContractOwnedStateTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.RestReadContractOwnedState

  test "fill history and deposit sources are unownable" do
    context = %{exchange: nil, markets: [], venue: "example", venue_contract: %{}}
    contract_case = %{"id" => "example:fetchOrder:0:x", "market_kind" => "spot"}

    for source <- ["fetchClosedOrders", "fetchDeposits", "fetchWithdrawals", "fetchTransfers"] do
      assert :unownable =
               RestReadContractOwnedState.ensure(
                 %{"source_method" => source, "field" => "id"},
                 contract_case,
                 context
               )
    end
  end
end
