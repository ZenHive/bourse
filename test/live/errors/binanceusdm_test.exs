defmodule Bourse.LiveErrors.BinanceusdmTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_binanceusdm

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises.

  @symbol "BTC/USDT:USDT"
  @unknown_order_id "999999999999999"

  test "an order id the venue has never seen answers order_not_found" do
    credentials = Bourse.Testnet.creds!(:binanceusdm)
    {:ok, exchange} = Bourse.Exchange.new("binanceusdm", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.fetch_open_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-28: GET /fapi/v1/openOrder with a never-seen
    # orderId answers code -2013, "Order does not exist."
    # Authority: Binance USD-M error codes —2013 NO_SUCH_ORDER
    # (https://developers.binance.com/docs/derivatives/usds-futures/error-code).
    assert error.type == :order_not_found
    assert error.code == -2013
    assert error.message == "Order does not exist."
  end
end
