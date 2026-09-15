defmodule Bourse.OrderAPIBoundaryIntegrationTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Exchange

  @moduletag :integration
  @moduletag :network

  test "public bang wrappers preserve success values and raise typed boundary errors" do
    exchange = Bourse.exchange!("deribit", sandbox: true)
    assert {:ok, %Exchange{}} = Bourse.exchange("deribit", sandbox: true)
    assert is_map(Bourse.timeframes(exchange))
    assert is_map(Bourse.fees(exchange))
    assert is_map(Bourse.config(exchange))
    assert is_map(Bourse.doc_urls(exchange))
    assert Enum.find(Bourse.__api__(), &(&1.name == :create_order)) == Bourse.__api__(:create_order)
    assert Bourse.__api__(:create_order).hints.opts[:trigger_price]
    assert Exchange in Bourse.__descripex_modules__()

    assert is_integer(Bourse.fetch_time!(exchange))
    assert {:ok, time} = Bourse.fetch_time(exchange)
    assert is_integer(time)
    assert %Exchange{markets: [_ | _]} = Bourse.load_markets!(exchange)

    assert {:error, %Error{type: :bad_request}} = Bourse.create_order(exchange, "BTC/USD:BTC", "market", "buy", 10, 42)

    assert_raise Error, fn -> Bourse.create_order!(exchange, "BTC/USD:BTC", "market", "buy", 10, 42) end

    unknown = %Exchange{id: "no-such-venue", name: "Unknown", module: nil}
    assert_raise Error, fn -> Bourse.load_markets!(unknown) end
  end
end
