defmodule Bourse.Order.BuilderTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.Order.Builder

  test "fluent setters replace duplicate prices and preserve their order" do
    builder =
      "BTC/USDT"
      |> Builder.new("buy", 0.1)
      |> Builder.limit(10)
      |> Builder.limit(11)
      |> Builder.stop_loss(8)
      |> Builder.stop_loss(9)
      |> Builder.take_profit(12)
      |> Builder.take_profit(13)

    assert builder.type == "limit"
    assert builder.params == [price: 11, stop_loss_price: 9, take_profit_price: 13]
  end

  test "submit returns sanity failures before transport" do
    builder = Builder.new("BTC/USDT", "hold", 0)
    exchange = %Exchange{id: "fixture", name: "fixture", spec: %{"capabilities" => %{"has" => %{}}}}
    credentials = Credentials.new!(api_key: "key", secret: "secret")

    assert {:error, {:sanity_check, reasons}} =
             Builder.submit(builder, exchange, credentials, sanity: [market: nil])

    assert List.keymember?(reasons, :check_side, 0)
    assert List.keymember?(reasons, :check_amount, 0)
  end
end
