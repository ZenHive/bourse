defmodule Bourse.LiveErrors.AlpacaTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_alpaca

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises. Alpaca authors no
  # fetchOpenOrder, so the unknown-id probe is fetch_order.

  @unknown_order_id "00000000-dead-beef-0000-000000000000"

  test "an order id the venue has never seen is rejected" do
    credentials = Bourse.Testnet.creds!(:alpaca)
    {:ok, exchange} = Bourse.Exchange.new("alpaca", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} = Bourse.fetch_order(exchange, @unknown_order_id)

    # Observed live 2026-08-28 on paper-api.alpaca.markets: HTTP 404,
    # code 40410000, "order not found for 00000000-dead-beef-0000-000000000000".
    # Alpaca documents 40410000 as a missing resource
    # (https://docs.alpaca.markets/us/reference/getorderbyorderid-1).
    # Authored mapping of 40410000 is InvalidOrder, not OrderNotFound.
    assert error.type == :invalid_order
    assert error.code == 40_410_000
    assert error.http_status == 404
    assert error.message =~ "order not found"
  end
end
