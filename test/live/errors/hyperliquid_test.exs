defmodule Bourse.LiveErrors.HyperliquidTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_hyperliquid

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises. fetchOpenOrder is
  # not offered on hyperliquid, so the unknown-id probe is fetch_order
  # (info orderStatus).

  @symbol "BTC/USDC:USDC"
  @unknown_order_id "1"

  test "an order id the venue has never seen answers unknownOid" do
    credentials = Bourse.Testnet.creds!(:hyperliquid)
    {:ok, exchange} = Bourse.Exchange.new("hyperliquid", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.fetch_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-28 against api.hyperliquid-testnet.xyz:
    # {"status": "unknownOid"}. Authority: "Missing Order" tab of
    # https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#query-order-status-by-oid-or-cloid
    assert error.type == :order_not_found
    assert error.code == "unknownOid"
    assert error.message == "unknownOid"
  end
end
