defmodule Bourse.LiveErrors.DeriveTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_derive

  @symbol "BTC/USD:USDC"
  @subaccount_id 144_422
  @unknown_order_id "00000000-dead-beef-0000-000000000000"

  test "an order id the venue has never seen is rejected" do
    credentials = Bourse.Testnet.creds!(:derive)

    {:ok, exchange} =
      Bourse.Exchange.new("derive",
        credentials: credentials,
        sandbox: true,
        options: %{"subaccount_id" => @subaccount_id}
      )

    {:ok, exchange} = Bourse.load_markets(exchange)

    assert {:error, %Error{} = error} =
             Bourse.cancel_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-28: code 11006, "Order does not exist."
    assert error.type == :order_not_found
    assert error.code == 11_006
    assert error.message =~ "Order does not exist"
  end
end
