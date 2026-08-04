defmodule Bourse.LighterPromotionIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Order
  alias Bourse.OrderBook
  alias Bourse.Signing.Lighter, as: LighterSigning
  alias Bourse.Ticker

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_lighter

  @testnet_url "https://testnet.zklighter.elliot.ai"
  @auth_lifetime_seconds 300
  @poll_attempts 12
  @poll_interval_ms 500
  @resting_price_ratio "0.99"
  @resting_amount 0.011
  @minimum_available_balance 11
  @maximum_client_order_index 2_000_000_000

  test "live public contract pins every advertised market-data method and a provider error" do
    assert {:ok, %Exchange{markets: markets} = exchange} =
             "lighter"
             |> Exchange.new!(sandbox: true)
             |> Bourse.load_markets()

    assert markets != []

    assert %Market{
             id: market_id,
             symbol: symbol,
             base: "BTC",
             quote: "USDC",
             settle: "USDC",
             type: "swap",
             active: true
           } = market = Enum.find(markets, &(&1.base == "BTC" and &1.type == "swap"))

    assert market.swap == true
    assert market.contract == true
    assert market.linear == true
    assert is_binary(market_id) and market_id != ""

    assert {:ok, %Ticker{symbol: ^symbol, last: last}} = Bourse.fetch_ticker(exchange, symbol)
    assert is_number(last)

    assert {:ok, %OrderBook{symbol: ^symbol, bids: bids, asks: asks}} =
             Bourse.fetch_order_book(exchange, symbol, limit: 10)

    assert match?([[_price, _amount | _] | _], bids)
    assert match?([[_price, _amount | _] | _], asks)

    assert {:ok, candles} = Bourse.fetch_ohlcv(exchange, symbol, "1m", limit: 2)
    assert match?([[_timestamp, _open, _high, _low, _close, _volume] | _], candles)

    assert {:error,
            %Error{
              type: :bad_request,
              code: 20_001,
              raw: %{"code" => 20_001, "message" => message}
            }} = Bourse.Lighter.public_get_orderbookorders(exchange, %{})

    assert message =~ "invalid param"
  end

  @tag :dangerous
  test "safe testnet limit order create, fetch, and cancel lifecycle cleans up deterministically" do
    credentials = require_credentials!()
    exchange = signed_exchange(credentials)
    assert {:ok, %Exchange{} = exchange} = Bourse.load_markets(exchange)

    market = Enum.find(exchange.markets, &(&1.base == "BTC" and &1.type == "swap"))
    assert %Market{} = market
    resting_price = resting_price!(exchange, market)
    assert account_available_balance!(exchange, credentials) >= @minimum_available_balance

    client_order_index =
      [:positive, :monotonic]
      |> System.unique_integer()
      |> rem(@maximum_client_order_index)

    try do
      assert {:ok, %{"code" => 200, "tx_hash" => tx_hash}} =
               Bourse.create_order(
                 exchange,
                 market.symbol,
                 "limit",
                 "buy",
                 @resting_amount,
                 price: resting_price,
                 client_order_index: client_order_index,
                 nonce: next_nonce!(exchange, credentials),
                 timeInForce: "PO"
               )

      assert is_binary(tx_hash) and tx_hash != ""

      assert %Order{id: order_id, client_order_id: client_order_id, status: "open"} =
               order = poll_open_order!(exchange, market.symbol, credentials, client_order_index)

      assert client_order_id == Integer.to_string(client_order_index)
      assert order.side == "buy"
      assert order.type == "limit"
      assert order.price == resting_price
      assert order.amount == @resting_amount

      assert {:ok, %{"code" => 200, "tx_hash" => cancel_hash}} =
               Bourse.cancel_order(exchange, order_id,
                 symbol: market.symbol,
                 nonce: next_nonce!(exchange, credentials)
               )

      assert is_binary(cancel_hash) and cancel_hash != ""
      assert_order_absent!(exchange, market.symbol, credentials, client_order_index)

      assert %Order{status: status} =
               poll_closed_order!(exchange, market.symbol, credentials, client_order_index)

      assert status in ["canceled", "cancelled"]
    after
      cleanup_order!(exchange, market.symbol, credentials, client_order_index)
    end
  end

  defp require_credentials! do
    required = [
      "LIGHTER_TESTNET_API_KEY_INDEX",
      "LIGHTER_TESTNET_ACCOUNT_INDEX",
      "LIGHTER_TESTNET_API_PRIVATE_KEY"
    ]

    missing = Enum.reject(required, &present_env?/1)

    if missing != [] do
      flunk("""
      Missing Lighter testnet credentials: #{Enum.join(missing, ", ")}

      Set these environment variables and re-run:
        export LIGHTER_TESTNET_API_KEY_INDEX="your-authorized-index"
        export LIGHTER_TESTNET_ACCOUNT_INDEX="your-account-index"
        export LIGHTER_TESTNET_API_PRIVATE_KEY="your-40-byte-hex-api-signing-key"

      Create an account-authorized API key at: https://testnet.zklighter.elliot.ai
      """)
    end

    Credentials.new!(
      api_key: System.fetch_env!("LIGHTER_TESTNET_API_KEY_INDEX"),
      uid: System.fetch_env!("LIGHTER_TESTNET_ACCOUNT_INDEX"),
      secret: System.fetch_env!("LIGHTER_TESTNET_API_PRIVATE_KEY")
    )
  end

  defp signed_exchange(credentials) do
    exchange =
      Exchange.new!("lighter",
        credentials: credentials,
        sandbox: true,
        options: %{
          account_index: credential_integer!(credentials.uid),
          api_key_index: credential_integer!(credentials.api_key)
        }
      )

    on_exit(fn ->
      assert :ok = LighterSigning.terminate_helper(credentials, helper_config(exchange))
    end)

    exchange
  end

  defp account_available_balance!(exchange, credentials) do
    assert {:ok, %{status: 200, body: %{"code" => 200, "accounts" => [account | _]}}} =
             Bourse.Lighter.public_get_account(exchange, %{
               "by" => "index",
               "value" => credential_integer!(credentials.uid)
             })

    account
    |> Map.fetch!("available_balance")
    |> Bourse.Safe.number()
  end

  defp resting_price!(exchange, market) do
    assert {:ok, %OrderBook{bids: [[best_bid, _amount | _] | _]}} =
             Bourse.fetch_order_book(exchange, market.symbol, limit: 1)

    tick_size = Map.get(market.precision, :price, Map.get(market.precision, "price"))

    price =
      best_bid
      |> decimal!()
      |> Decimal.mult(Decimal.new(@resting_price_ratio))
      |> Decimal.div(decimal!(tick_size))
      |> Decimal.round(0, :floor)
      |> Decimal.mult(decimal!(tick_size))

    assert Decimal.positive?(price)
    Decimal.to_float(price)
  end

  defp decimal!(value) do
    assert {:ok, decimal} = Decimal.cast(value)
    decimal
  end

  defp next_nonce!(exchange, credentials) do
    assert {:ok, %{status: 200, body: %{"code" => 200, "nonce" => nonce}}} =
             Bourse.Lighter.public_get_nextnonce(exchange, %{
               "account_index" => credential_integer!(credentials.uid),
               "api_key_index" => credential_integer!(credentials.api_key)
             })

    nonce
  end

  defp poll_open_order!(exchange, symbol, credentials, client_order_index, attempts \\ @poll_attempts)

  defp poll_open_order!(_exchange, _symbol, _credentials, client_order_index, 0) do
    flunk("Lighter order #{client_order_index} did not become visible after #{@poll_attempts} attempts")
  end

  defp poll_open_order!(exchange, symbol, credentials, client_order_index, attempts) do
    case find_open_order(exchange, symbol, credentials, client_order_index) do
      %Order{} = order ->
        order

      nil ->
        wait_then(fn -> poll_open_order!(exchange, symbol, credentials, client_order_index, attempts - 1) end)
    end
  end

  defp assert_order_absent!(exchange, symbol, credentials, client_order_index, attempts \\ @poll_attempts)

  defp assert_order_absent!(_exchange, _symbol, _credentials, client_order_index, 0) do
    flunk("Lighter order #{client_order_index} remained open after #{@poll_attempts} attempts")
  end

  defp assert_order_absent!(exchange, symbol, credentials, client_order_index, attempts) do
    case find_open_order(exchange, symbol, credentials, client_order_index) do
      nil ->
        :ok

      %Order{} ->
        wait_then(fn -> assert_order_absent!(exchange, symbol, credentials, client_order_index, attempts - 1) end)
    end
  end

  defp poll_closed_order!(exchange, symbol, credentials, client_order_index, attempts \\ @poll_attempts)

  defp poll_closed_order!(_exchange, _symbol, _credentials, client_order_index, 0) do
    flunk("Lighter order #{client_order_index} did not enter closed history after #{@poll_attempts} attempts")
  end

  defp poll_closed_order!(exchange, symbol, credentials, client_order_index, attempts) do
    case exchange |> fetch_orders!(:closed, symbol, credentials) |> find_client_order(client_order_index) do
      %Order{} = order ->
        order

      nil ->
        wait_then(fn -> poll_closed_order!(exchange, symbol, credentials, client_order_index, attempts - 1) end)
    end
  end

  defp cleanup_order!(exchange, symbol, credentials, client_order_index) do
    case find_open_order(exchange, symbol, credentials, client_order_index) do
      nil ->
        :ok

      %Order{id: order_id} ->
        assert {:ok, %{"code" => 200, "tx_hash" => tx_hash}} =
                 Bourse.cancel_order(exchange, order_id,
                   symbol: symbol,
                   nonce: next_nonce!(exchange, credentials)
                 )

        assert is_binary(tx_hash) and tx_hash != ""
        assert_order_absent!(exchange, symbol, credentials, client_order_index)
    end
  end

  defp find_open_order(exchange, symbol, credentials, client_order_index) do
    exchange
    |> fetch_orders!(:open, symbol, credentials)
    |> find_client_order(client_order_index)
  end

  defp fetch_orders!(exchange, status, symbol, credentials) do
    opts = [
      account_index: credential_integer!(credentials.uid),
      auth_deadline: System.system_time(:second) + @auth_lifetime_seconds
    ]

    result =
      case status do
        :open -> Bourse.fetch_open_orders(exchange, [{:symbol, symbol} | opts])
        :closed -> Bourse.fetch_closed_orders(exchange, [{:symbol, symbol} | opts])
      end

    case result do
      {:ok, orders} when is_list(orders) -> orders
      other -> flunk("Lighter #{status} order read failed: #{inspect(other)}")
    end
  end

  defp find_client_order(orders, client_order_index) do
    client_order_id = Integer.to_string(client_order_index)
    Enum.find(orders, &(&1.client_order_id == client_order_id))
  end

  defp wait_then(fun) do
    receive do
    after
      @poll_interval_ms -> fun.()
    end
  end

  defp helper_config(exchange) do
    exchange.signing_config
    |> Map.put(:base_url, @testnet_url)
    |> Map.put(:testnet, exchange.sandbox)
    |> Map.put(:exchange_options, exchange.options)
  end

  defp credential_integer!(value) when is_integer(value), do: value
  defp credential_integer!(value) when is_binary(value), do: String.to_integer(value)

  defp present_env?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
    end
  end
end
