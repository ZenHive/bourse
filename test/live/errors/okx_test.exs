defmodule Bourse.LiveErrors.OkxTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_okx

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises. OKX authors no
  # fetchOpenOrder, so the unknown-id probe is fetch_order.

  @symbol "BTC/USDT:USDT"
  @unknown_order_id "635561007938625536"

  test "an order id the venue has never seen answers order_not_found" do
    credentials = Bourse.Testnet.creds!(:okx)
    {:ok, exchange} = Bourse.Exchange.new("okx", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.fetch_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-28 on www.okx.com with x-simulated-trading:
    # GET /api/v5/trade/order with a never-seen ordId answers code "51603",
    # "Order does not exist". Authority: OKX API v5 51603
    # (https://www.okx.com/docs-v5/en/#error-code).
    assert error.type == :order_not_found
    assert error.code == "51603"
    assert error.message == "Order does not exist"
  end
end
