defmodule Bourse.LiveErrors.BinancecoinmTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_binancecoinm

  @symbol "BTC/USD:BTC"
  @unknown_order_id "999999999999999"

  test "an order id the venue has never seen answers order_not_found" do
    credentials = Bourse.Testnet.creds!(:binancecoinm)
    {:ok, exchange} = Bourse.Exchange.new("binancecoinm", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.fetch_open_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-28: GET /dapi/v1/openOrder with a never-seen
    # orderId answers -2013, "Order does not exist."
    # Authority: Binance COIN-M error code -2013 NO_SUCH_ORDER.
    assert error.type == :order_not_found
    assert error.code == -2013
    assert error.message == "Order does not exist."
  end
end
