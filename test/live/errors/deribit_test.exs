defmodule Bourse.LiveErrors.DeribitTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_deribit

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises. Deribit authors no
  # fetchOpenOrder, so the unknown-id probe is fetch_order
  # (private/get_order_state).

  @symbol "BTC/USD:BTC"
  @unknown_order_id "999999999999"

  test "an order id the venue has never seen answers order_not_found" do
    credentials = Bourse.Testnet.creds!(:deribit)
    {:ok, exchange} = Bourse.Exchange.new("deribit", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.fetch_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-28 on test.deribit.com: private/get_order_state
    # with a never-seen numeric order_id answers code 10004, "order_not_found".
    # A malformed id (e.g. "BTC-0") is refused first as JSON-RPC -32602
    # invalid_order_id, so the probe uses a well-formed numeric id.
    # Authority: Deribit API v2 errors —10004 order_not_found
    # (https://docs.deribit.com/articles/errors).
    assert error.type == :order_not_found
    assert error.code == 10_004
    assert error.message =~ "order_not_found"
  end
end
