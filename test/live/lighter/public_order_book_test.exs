defmodule Bourse.Lighter.PublicOrderBookTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_lighter

  test "an unknown numeric market id returns an empty order book" do
    exchange = Bourse.Exchange.new!("lighter", sandbox: true)

    assert {:ok, %{status: 200, body: body}} =
             Bourse.Lighter.public_get_orderbookorders(exchange, %{
               "market_id" => 2_147_483_647,
               "limit" => 1
             })

    assert body == %{"asks" => [], "bids" => [], "code" => 200, "total_asks" => 0, "total_bids" => 0}
  end
end
