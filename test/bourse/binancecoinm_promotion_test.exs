defmodule Bourse.BinancecoinmPromotionTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.ReferenceSlice
  alias Bourse.Spec
  alias Bourse.Test.RequestCollector

  @supported_methods ~w(
    cancelAllOrders
    cancelOrder
    createOrder
    fetchADLRank
    fetchBalance
    fetchFundingHistory
    fetchFundingIntervals
    fetchFundingRate
    fetchFundingRateHistory
    fetchFundingRates
    fetchLedger
    fetchLeverageTiers
    fetchLeverages
    fetchMarginAdjustmentHistory
    fetchMarkets
    fetchMyTrades
    fetchOpenInterest
    fetchOpenOrder
    fetchOpenOrders
    fetchOrder
    fetchOrderBook
    fetchOrders
    fetchPositionMode
    fetchPositions
    fetchTicker
    fetchTime
    fetchTrades
    fetchTradingFee
    setLeverage
    setMarginMode
    setPositionMode
  )
  @emulated_methods ~w(fetchCanceledOrders fetchClosedOrders fetchLeverage)
  @demo_host "demo-dapi.binance.com"
  @ticker_fixture "test/fixtures/responses/binancecoinm/fetch_ticker.json"
  @external_resource @ticker_fixture

  test "runtime loads the complete owned document without reference fallback" do
    owned_path = Spec.owned_spec_path("binancecoinm")
    reference_path = ReferenceSlice.spec_path("binancecoinm")
    owned = Spec.decode_file!(owned_path)

    assert Spec.spec_path("binancecoinm") == owned_path
    refute owned_path == reference_path
    assert Spec.load!("binancecoinm") == owned
    assert owned["authored"] == true
    assert owned["hand_owned"] == true
    assert owned["frozen"] == true
    assert Spec.validate_schema!(owned, "binancecoinm") == owned
  end

  test "all reference methods have an explicit supported or unsupported contract" do
    spec = Spec.load!("binancecoinm")
    support = spec["capabilities"]["has"]
    routes = spec["endpoints"]["unified"]

    assert support |> Map.keys() |> Enum.sort() == routes |> Map.keys() |> Enum.sort()

    assert support |> Enum.filter(fn {_method, value} -> value == true end) |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             Enum.sort(@supported_methods)

    assert support
           |> Enum.filter(fn {_method, value} -> value == "emulated" end)
           |> Enum.map(&elem(&1, 0))
           |> Enum.sort() == Enum.sort(@emulated_methods)

    for {method, declaration} <- support do
      assert declaration in [true, false, "emulated"]

      if declaration in [true, "emulated"] do
        assert routes[method] != []
        assert Enum.all?(routes[method], &String.starts_with?(&1, "dapi"))
      else
        assert routes[method] == []
      end
    end
  end

  test "unsupported methods neither advertise availability nor generate dispatch routes" do
    spec = Spec.load!("binancecoinm")
    exchange = Exchange.new!("binancecoinm")
    generated = Bourse.Binancecoinm.__unified_endpoints__()

    for {method, false} <- spec["capabilities"]["has"] do
      refute Exchange.has?(exchange, method)

      if method_atom = unified_method_atom(method) do
        refute Map.has_key?(generated, method_atom)
      end
    end
  end

  test "sandbox DAPI sections use Binance's documented demo host" do
    exchange = Exchange.new!("binancecoinm", sandbox: true)

    for section <- ~w(dapiPublic dapiPrivate dapiPrivateV2) do
      assert URI.parse(exchange.base_urls[section]).host == @demo_host
    end
  end

  test "runtime error maps retain top-level and scoped classifications separately" do
    exchange = Exchange.new!("binancecoinm")

    assert exchange.error_codes["-2014"] == :authentication_error
    assert exchange.error_codes["-4061"] == :operation_failed
    assert Exchange.error_codes_for(exchange, "inverse")["-2019"] == :insufficient_funds
    assert Exchange.error_codes_for(exchange, "portfolioMargin")["-2019"] == :operation_failed
  end

  test "ticker denormalizes an own-market inverse perpetual without a loaded market cache" do
    {:ok, requests} = RequestCollector.start_link()
    stub = {__MODULE__, :ticker_round_trip, System.unique_integer([:positive])}
    body = @ticker_fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("body")

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, body)
    end)

    exchange = Exchange.new!("binancecoinm", sandbox: true)

    assert {:ok, %Bourse.Ticker{symbol: "BTC/USD:BTC", last: last}} =
             Bourse.fetch_ticker(exchange, "BTC/USD:BTC", plug: {Req.Test, stub})

    assert is_number(last)

    request = RequestCollector.one!(requests)
    assert request.request_path == "/dapi/v1/ticker/24hr"
    assert RequestCollector.query(request) == %{"symbol" => "BTCUSD_PERP"}
  end

  defp unified_method_atom(js_name) do
    Enum.find_value(Bourse.Unified.method_defs(), fn {method, candidate, _required, _description} ->
      if candidate == js_name, do: method
    end)
  end
end
