defmodule Bourse.LiveErrors.BinancecoinmTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_binancecoinm

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises.

  @symbol "BTC/USD:BTC"
  @unknown_order_id "999999999999999"

  test "an order id the venue has never seen answers order_not_found" do
    credentials = Bourse.Testnet.creds!(:binancecoinm)
    {:ok, exchange} = Bourse.Exchange.new("binancecoinm", credentials: credentials, sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.fetch_open_order(exchange, @unknown_order_id, symbol: @symbol)

    # Observed live 2026-08-28: GET /dapi/v1/openOrder with a never-seen
    # orderId answers -2013, "Order does not exist."
    # Authority: Binance COIN-M error codes —2013 NO_SUCH_ORDER
    # (https://developers.binance.com/docs/derivatives/coin-margined-futures/error-code).
    assert error.type == :order_not_found
    assert error.code == -2013
    assert error.message == "Order does not exist."
  end

  # Index 0 of both reads is `dapiPrivate_get_algoorder` (GET /dapi/v1/algoOrder).
  # The REST-read contract's owned-algo wait treats -2013 on these reads as a
  # propagation miss only while the id is listed on the open-algo book; this pins
  # the answer a genuinely unknown algoId gets on the same branches.
  for {read, index} <- [fetch_order: 0, fetch_open_order: 0] do
    test "an algoId the venue has never seen answers order_not_found on #{read} index #{index}" do
      credentials = Bourse.Testnet.creds!(:binancecoinm)
      {:ok, exchange} = Bourse.Exchange.new("binancecoinm", credentials: credentials, sandbox: true)

      # Every book of this read answers -2013 for an unknown id, so pin the slot first.
      assert %{method: :get, path: "algoOrder", sections: ["dapiPrivate"]} =
               Enum.at(Bourse.Binancecoinm.__unified_endpoints__()[unquote(read)], unquote(index))

      assert {:error, %Error{} = error} =
               Bourse.unquote(read)(exchange, @unknown_order_id, symbol: @symbol, endpoint_index: unquote(index))

      # Observed live 2026-11-25: GET /dapi/v1/algoOrder with a never-issued
      # algoId answers -2013, "Order does not exist." — the same answer a
      # just-created algo order gets for up to ~1.3 s.
      assert error.type == :order_not_found
      assert error.code == -2013
      assert error.message == "Order does not exist."
    end
  end
end
