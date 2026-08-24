defmodule Bourse.LiveErrors.BybitTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_bybit

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises.

  @symbol "BTC/USDT:USDT"
  @unknown_order_id "00000000-dead-beef-0000-000000000000"

  test "an order id the venue has never seen answers order_not_found" do
    credentials = Bourse.Testnet.creds!(:bybit)
    {:ok, exchange} = Bourse.Exchange.new("bybit", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.fetch_open_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-24: the venue answers "Order not found".
    assert error.type == :order_not_found
    assert error.message =~ "Order not found"
  end
end
