defmodule Bourse.LiveErrors.LighterTest do
  use ExUnit.Case, async: false

  alias Bourse.Error

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_lighter

  @unknown_market_id 2_147_483_647

  test "an unknown market id is rejected as bad input" do
    {:ok, exchange} = Bourse.Exchange.new("lighter", sandbox: true)

    assert {:error, %Error{} = error} =
             Bourse.Lighter.public_get_orderbookorders(exchange, %{
               "market_id" => @unknown_market_id,
               "limit" => 1
             })

    # Observed live 2026-08-28: HTTP 400, code 20001, "invalid param ".
    assert error.type == :bad_request
    assert error.http_status == 400
    assert error.code == 20_001
    assert error.message == "invalid param "
  end
end
