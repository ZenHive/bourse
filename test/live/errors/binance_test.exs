defmodule Bourse.LiveErrors.BinanceTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_binance

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises.

  @symbol "BTC/USDT"
  @unknown_order_id "999999999999999"

  test "an order id the venue has never seen answers order_not_found" do
    credentials = Bourse.Testnet.creds!(:binance)
    {:ok, exchange} = Bourse.Exchange.new("binance", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.fetch_open_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-28: GET /api/v3/order with a never-seen orderId
    # answers code -2013, "Order does not exist."
    # Authority: Binance Spot errors.md —2013 NO_SUCH_ORDER
    # (https://developers.binance.com/docs/binance-spot-api-docs/errors).
    assert error.type == :order_not_found
    assert error.code == -2013
    assert error.message == "Order does not exist."
  end
end
