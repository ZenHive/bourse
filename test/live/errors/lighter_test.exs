defmodule Bourse.LiveErrors.LighterTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_lighter

  # Deliberate bad-input probes, one venue per file. Invalid-symbol reads are
  # already pinned by the REST-read contract lane (rest_read_contract.json
  # error_cases) and invalid-credential probes have their own suite — this
  # file carries only errors neither of those exercises. Lighter authors no
  # fetchOrder, so an unknown market id on the public order-book-orders
  # read is the equivalent bad-input probe.

  @unknown_market_id 2_147_483_647

  test "an unknown market id is rejected as bad input" do
    {:ok, exchange} = Bourse.Exchange.new("lighter", sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.Lighter.public_get_orderbookorders(exchange, %{
               "market_id" => @unknown_market_id,
               "limit" => 1
             })

    # Observed live 2026-08-28 on testnet.zklighter.elliot.ai: HTTP 400,
    # code 20001, "invalid param ".
    assert error.type == :bad_request
    assert error.http_status == 400
    assert error.code == 20_001
    assert error.message == "invalid param "
  end
end
