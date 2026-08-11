defmodule Bourse.BybitOrderLifecycleIntegrationTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Market
  alias Bourse.Order

  @moduletag :network
  @moduletag :dangerous
  @moduletag :exchange_bybit

  # Bybit demo trading (venue-granted fake funds). The provisioned TESTNET key is
  # read-only (business error 10024 on create); trade evidence runs on the demo host,
  # reached per call via the :base_url dispatch opt. The demo key is invalid on the
  # default host, so a dropped :base_url fails loudly at the balance guard below
  # instead of ever trading against mainnet.
  @demo_url "https://api-demo.bybit.com"

  @symbol "BTC/USDT:USDT"
  @amount 0.001
  @create_price 10_000
  @edit_price 9_000
  @precision_symbols ["LTC/USDT", "ADA/USDT"]
  @precision_order_cost 10.0
  @resting_price_ratio 0.95
  @off_grid_divisor 3
  @poll_attempts 10
  @poll_interval_ms 250

  test "creates, fetches, edits, cancels, and confirms a Bybit order lifecycle" do
    exchange = loaded_demo_exchange!()
    # unique_integer/1 restarts per VM, so bare counters collide across runs on the
    # persistent demo account (Bybit 170141 Duplicate clientOrderId) — anchor to wall time.
    client_order_id = "bourse-task234-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    order =
      create_order!(exchange,
        price: @create_price,
        postOnly: true,
        clientOrderId: client_order_id,
        base_url: @demo_url
      )

    try do
      assert %Order{id: id, client_order_id: ^client_order_id} = fetch_open_order!(exchange, order.id)
      assert id == order.id

      assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, symbol: @symbol, base_url: @demo_url)

      assert Enum.any?(open_orders, &(&1.id == id and &1.symbol == @symbol)),
             "fetch_open_orders must return the resting order #{id}; got #{inspect(Enum.map(open_orders, &{&1.id, &1.symbol, &1.status}))}"

      assert {:ok, %Order{id: ^id, amount: nil, status: nil}} =
               Bourse.edit_order(exchange, id, @symbol, "limit", "buy",
                 amount: @amount,
                 price: @edit_price,
                 base_url: @demo_url
               )

      assert %Order{price: @edit_price, status: "open"} = fetch_open_order!(exchange, id)

      assert {:ok, %Order{id: ^id}} = Bourse.cancel_order(exchange, id, symbol: @symbol, base_url: @demo_url)
      assert %Order{status: status} = fetch_terminal_order!(exchange, id)
      assert status in ["closed", "canceled"]
    after
      cleanup_order!(exchange, order.id)
      cleanup_order!(exchange, order.id)
    end
  end

  test "maps a successful empty Bybit order lookup to order_not_found" do
    exchange = demo_exchange!()
    missing_id = "bourse-task234-missing-#{System.unique_integer([:positive])}"

    assert {:error, %Error{type: :order_not_found}} =
             Bourse.fetch_open_order(exchange, missing_id, symbol: @symbol, base_url: @demo_url)
  end

  test "option qty uses the base-quantity step and the demo venue rejects a half step" do
    exchange = loaded_demo_exchange!()
    market = Enum.find(exchange.markets, &(&1.option and &1.active and &1.base == "BTC"))

    assert %Market{
             quantity_unit: "base",
             native_quantity_unit: "base",
             native_quantity_field: "qty",
             contract_size: nil,
             native_amount_step: amount_step,
             settle: settle,
             expiry: expiry,
             strike: strike,
             option_type: option_type
           } = market

    assert amount_step == Bourse.Safe.number(get_in(market.info, ["lotSizeFilter", "qtyStep"]))
    assert market.precision["amount"] == amount_step
    assert is_binary(settle)
    assert is_integer(expiry)
    assert is_number(strike)
    assert option_type in ["call", "put"]

    client_order_id = "task397-#{System.system_time(:millisecond)}"

    assert {:ok, %Order{id: order_id}} =
             Bourse.create_order(exchange, market.symbol, "limit", "buy", amount_step,
               price: market.precision["price"],
               postOnly: true,
               clientOrderId: client_order_id,
               base_url: @demo_url
             )

    try do
      assert {:ok, %Order{amount: ^amount_step, filled: 0, remaining: ^amount_step}} =
               Bourse.fetch_order(exchange, order_id, symbol: market.symbol, base_url: @demo_url)
    after
      cleanup_order!(exchange, order_id, market.symbol)
    end

    assert {:error, %Error{type: :bad_request, code: 10_001, message: message}} =
             Bourse.Bybit.private_post_v5_order_create(
               exchange,
               %{
                 "category" => "option",
                 "symbol" => market.id,
                 "side" => "Buy",
                 "orderType" => "Limit",
                 "qty" => to_string(amount_step / 2),
                 "price" => to_string(market.precision["price"]),
                 "orderLinkId" => "task397-bad-#{System.system_time(:millisecond)}",
                 "timeInForce" => "PostOnly"
               },
               base_url: @demo_url
             )

    assert message =~ "below the lower limit"
  end

  test "missing demo credentials fail loudly with exact setup instructions" do
    variables = ["BYBIT_DEMO_API_KEY", "BYBIT_DEMO_API_SECRET"]
    previous = Map.new(variables, &{&1, System.get_env(&1)})
    Enum.each(variables, &System.delete_env/1)

    try do
      error = assert_raise ExUnit.AssertionError, &demo_exchange!/0

      assert error.message =~ ~s(export BYBIT_DEMO_API_KEY="your_demo_api_key")
      assert error.message =~ ~s(export BYBIT_DEMO_API_SECRET="your_demo_api_secret")
      assert error.message =~ "https://www.bybit.com/app/user/api-management"
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  test "accepts off-grid spot orders rounded from two instruments with different tick sizes" do
    exchange = demo_exchange!()

    error =
      assert_raise Error, fn ->
        Bourse.create_order(exchange, "LTC/USDT", "limit", "buy", 0.144_444_423_423_423_4,
          price: 60.423,
          base_url: @demo_url
        )
      end

    assert error.type == :invalid_order
    assert error.exchange == "bybit"
    assert error.message =~ "LTCUSDT"
    assert error.message =~ "missing instrument precision"

    assert {:ok, %Bourse.Exchange{} = exchange} = Bourse.load_markets(exchange, base_url: @demo_url)

    markets = Enum.map(@precision_symbols, &market_for_symbol!(exchange, &1))
    assert markets |> Enum.map(&market_step!(&1, "price")) |> Enum.uniq() |> length() == length(markets)

    Enum.each(markets, &assert_precision_order_accepted!(exchange, &1))
  end

  defp demo_exchange! do
    api_key = System.get_env("BYBIT_DEMO_API_KEY")
    secret = System.get_env("BYBIT_DEMO_API_SECRET")

    if api_key in [nil, ""] or secret in [nil, ""] do
      flunk("""
      Missing Bybit DEMO-trading credentials (the testnet key is read-only, error 10024).

        export BYBIT_DEMO_API_KEY="your_demo_api_key"
        export BYBIT_DEMO_API_SECRET="your_demo_api_secret"

      Create a demo-trading key from a bybit.com account (Demo Trading):
        https://www.bybit.com/app/user/api-management
      """)
    end

    credentials = Bourse.Credentials.new!(api_key: api_key, secret: secret)
    {:ok, exchange} = Bourse.Exchange.new("bybit", credentials: credentials)

    case Bourse.fetch_balance(exchange, base_url: @demo_url) do
      {:ok, _balance} ->
        exchange

      other ->
        flunk("""
        Bybit demo host guard failed: fetch_balance via base_url #{@demo_url} returned
        #{inspect(other)}. The demo key is only valid on the demo host — if the :base_url
        dispatch opt regressed (task 252), this fails here instead of trading elsewhere.
        """)
    end
  end

  defp create_order!(exchange, opts) do
    case Bourse.create_order(exchange, @symbol, "limit", "buy", @amount, opts) do
      {:ok, %Order{id: id} = order} when is_binary(id) and id != "" ->
        order

      {:error, %Error{code: code} = error} when code in [10_005, 10_024] ->
        flunk("Bybit key cannot trade (#{code}); use a demo-trading key: #{Exception.message(error)}")

      other ->
        flunk("Bybit create_order failed: #{inspect(other)}")
    end
  end

  defp loaded_demo_exchange! do
    exchange = demo_exchange!()

    case Bourse.load_markets(exchange, base_url: @demo_url) do
      {:ok, %Bourse.Exchange{} = loaded} -> loaded
      other -> flunk("Bybit demo load_markets failed: #{inspect(other)}")
    end
  end

  defp assert_precision_order_accepted!(exchange, %Market{} = market) do
    price_step = market_step!(market, "price")
    amount_step = market_step!(market, "amount")

    assert price_step == Bourse.Safe.number(get_in(market.info, ["priceFilter", "tickSize"]))
    assert amount_step == Bourse.Safe.number(get_in(market.info, ["lotSizeFilter", "basePrecision"]))

    assert {:ok, %Bourse.OrderBook{bids: [[bid | _] | _]}} =
             Bourse.fetch_order_book(exchange, market.symbol, base_url: @demo_url)

    resting_price = bid * @resting_price_ratio
    off_grid_price = resting_price + price_step / @off_grid_divisor
    off_grid_amount = @precision_order_cost / resting_price + amount_step / @off_grid_divisor

    client_order_id =
      "ccxt-489-#{market.id}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    order =
      case Bourse.create_order(exchange, market.symbol, "limit", "buy", off_grid_amount,
             price: off_grid_price,
             clientOrderId: client_order_id,
             base_url: @demo_url
           ) do
        {:ok, %Order{id: id} = order} when is_binary(id) and id != "" -> order
        other -> flunk("Bybit precision order failed for #{market.symbol}: #{inspect(other)}")
      end

    try do
      assert order.client_order_id == client_order_id
    after
      cleanup_order!(exchange, order.id, market.symbol)
    end
  end

  defp market_for_symbol!(%Bourse.Exchange{markets: markets}, symbol) do
    case Enum.find(markets, &(&1.symbol == symbol)) do
      %Market{} = market -> market
      nil -> flunk("Bybit demo fetch_markets returned no #{symbol} instrument")
    end
  end

  defp market_step!(%Market{precision: precision, symbol: symbol}, field) do
    case precision[field] do
      step when is_number(step) and step > 0 -> step
      other -> flunk("Bybit #{symbol} has invalid #{field} precision: #{inspect(other)}")
    end
  end

  defp fetch_open_order!(exchange, id) do
    poll_order!(fn -> Bourse.fetch_open_order(exchange, id, symbol: @symbol, base_url: @demo_url) end)
  end

  defp fetch_terminal_order!(exchange, id, symbol \\ @symbol) do
    poll_order!(fn -> Bourse.fetch_closed_order(exchange, id, symbol: symbol, base_url: @demo_url) end)
  end

  defp poll_order!(request, attempts \\ @poll_attempts)
  defp poll_order!(_request, 0), do: flunk("Bybit order state did not become visible after #{@poll_attempts} attempts")

  defp poll_order!(request, attempts) do
    case request.() do
      {:ok, %Order{} = order} ->
        order

      {:error, %Error{type: :order_not_found}} ->
        receive do
        after
          @poll_interval_ms -> poll_order!(request, attempts - 1)
        end

      other ->
        flunk("Bybit order lookup failed: #{inspect(other)}")
    end
  end

  defp cleanup_order!(exchange, id, symbol \\ @symbol) do
    case Bourse.cancel_order(exchange, id, symbol: symbol, base_url: @demo_url) do
      {:ok, %Order{}} -> :ok
      {:error, %Error{type: :order_not_found}} -> :ok
      {:error, %Error{type: :invalid_order}} -> :ok
      other -> flunk("Bybit cleanup failed for #{id}: #{inspect(other)}")
    end
  end
end
