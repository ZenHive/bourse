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
  @fill_amount 0.0002
  @buy_crossing_ratio "1.01"
  @sell_crossing_ratio "0.99"
  @minimum_available_balance 11
  @maximum_client_order_index 2_000_000_000
  @lighter_usdc_asset_index 3
  @perps_route 0
  @spot_route 1
  @one_usdc 1_000_000
  @empty_transfer_memo String.duplicate("00", 32)

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

  test "live unified account and history reads succeed against Lighter testnet" do
    credentials = require_credentials!()

    assert {:ok, %Exchange{} = exchange} =
             credentials
             |> signed_exchange()
             |> Bourse.load_markets()

    market = Enum.find(exchange.markets, &(&1.base == "BTC" and &1.type == "swap"))
    assert %Market{} = market

    assert {:ok, %Bourse.Balance{free: free, total: total}} = Bourse.fetch_balance(exchange)
    assert total != %{}
    assert Enum.all?(total, fn {_currency, value} -> is_number(value) end)
    assert is_number(free["USDC"])

    assert {:ok, [%Bourse.Position{} | _] = positions} = Bourse.fetch_positions(exchange)
    assert Enum.all?(positions, &match?(%Bourse.Position{}, &1))
    assert Enum.all?(positions, &(is_binary(&1.symbol) and String.contains?(&1.symbol, "/")))
    assert Enum.all?(positions, &(not (&1.contracts == 0 and &1.side == "long")))

    assert {:ok, [%Bourse.Trade{} | _] = trades} = Bourse.fetch_my_trades(exchange)
    assert Enum.all?(trades, &match?(%Bourse.Trade{}, &1))
    assert Enum.all?(trades, &(is_binary(&1.symbol) and String.contains?(&1.symbol, "/")))
    assert Enum.all?(trades, &(&1.side in ["buy", "sell"]))
    assert Enum.all?(trades, &(&1.taker_or_maker in ["maker", "taker"]))
    assert Enum.all?(trades, &(is_binary(&1.order_id) and &1.order_id != ""))
    assert Enum.all?(trades, &is_nil(&1.type))

    assert {:ok, %{status: 200, body: %{"code" => 200, "accounts" => [account | _]}}} =
             Bourse.Lighter.public_get_account(exchange, %{
               "by" => "index",
               "value" => credential_integer!(credentials.uid)
             })

    assert {:ok, deposits} = Bourse.fetch_deposits(exchange, l1_address: Map.fetch!(account, "l1_address"))
    assert Enum.all?(deposits, &match?(%Bourse.Transaction{}, &1))

    assert {:ok, withdrawals} = Bourse.fetch_withdrawals(exchange)
    assert Enum.all?(withdrawals, &match?(%Bourse.Transaction{}, &1))

    assert {:ok, transfers} = Bourse.fetch_transfers(exchange)
    assert Enum.all?(transfers, &match?(%Bourse.TransferEntry{}, &1))

    assert {:ok, liquidations} = Bourse.fetch_my_liquidations(exchange)
    assert Enum.all?(liquidations, &match?(%Bourse.Liquidation{}, &1))

    assert {:ok, [%Bourse.FundingRateHistory{symbol: symbol} | _] = funding_history} =
             Bourse.fetch_funding_rate_history(exchange, market.symbol, limit: 10)

    assert symbol == market.symbol
    assert Enum.all?(funding_history, &match?(%Bourse.FundingRateHistory{}, &1))
  end

  @tag :dangerous
  test "live signed transfer round trip preserves account identity and route metadata" do
    credentials = require_credentials!()
    exchange = signed_exchange(credentials)
    account_index = credential_integer!(credentials.uid)
    initial_count = exchange |> Bourse.fetch_transfers() |> transfer_count!()

    assert {:ok, first_hash} =
             send_transfer(exchange, credentials, account_index, @perps_route, @spot_route)

    try do
      transfer = poll_transfer!(exchange, initial_count, first_hash)
      assert transfer.from_account == Integer.to_string(account_index)
      assert transfer.to_account == Integer.to_string(account_index)
      assert transfer.info["from_route"] == "perps"
      assert transfer.info["to_route"] == "spot"
    after
      assert {:ok, cleanup_hash} =
               send_transfer(exchange, credentials, account_index, @spot_route, @perps_route)

      cleanup = poll_transfer!(exchange, initial_count, cleanup_hash)
      assert cleanup.from_account == Integer.to_string(account_index)
      assert cleanup.to_account == Integer.to_string(account_index)
      assert cleanup.info["from_route"] == "spot"
      assert cleanup.info["to_route"] == "perps"
    end
  end

  @tag :dangerous
  test "live crossing fill proves populated position, balance, and trade semantics, then flattens" do
    credentials = require_credentials!()
    exchange = signed_exchange(credentials)
    assert {:ok, exchange} = Bourse.load_markets(exchange)
    market = Enum.find(exchange.markets, &(&1.base == "BTC" and &1.type == "swap"))
    assert %Market{} = market
    prior_trade_ids = exchange |> Bourse.fetch_my_trades() |> trade_ids!()

    try do
      assert {:ok, %{"code" => 200}} =
               Bourse.create_order(exchange, market.symbol, "limit", "buy", @fill_amount,
                 price: crossing_price!(exchange, market, :buy),
                 client_order_index: next_client_order_index(),
                 nonce: next_nonce!(exchange, credentials),
                 order_expiry: 0,
                 timeInForce: "IOC"
               )

      position = poll_active_position!(exchange, market.symbol)
      assert position.symbol == market.symbol
      assert position.side == "long"
      assert position.contracts > 0

      assert {:ok, %Bourse.Balance{free: free, total: total}} = Bourse.fetch_balance(exchange)
      assert free["USDC"] < total["USDC"]

      trade = poll_new_trade!(exchange, prior_trade_ids)
      assert trade.symbol == market.symbol
      assert trade.side == "buy"
      assert trade.taker_or_maker == "taker"
      assert is_binary(trade.order_id) and trade.order_id != ""
      assert is_nil(trade.type)
    after
      cleanup_position!(exchange, market, credentials)
    end

    assert %Bourse.Position{side: nil, contracts: contracts} = poll_flat_position!(exchange, market.symbol)
    assert contracts == 0.0
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

  defp send_transfer(exchange, credentials, account_index, from_route, to_route) do
    params = %{
      to_account_index: account_index,
      asset_index: @lighter_usdc_asset_index,
      from_route: from_route,
      to_route: to_route,
      amount: @one_usdc,
      usdc_fee: 0,
      memo: @empty_transfer_memo,
      skip_nonce: false,
      nonce: next_nonce!(exchange, credentials)
    }

    request_params = %{
      "__bourse_lighter_transaction_operation" => "transfer",
      "__bourse_lighter_transaction_params" => params
    }

    with {:ok, %{status: 200, body: %{"code" => 200, "tx_hash" => tx_hash}}} <-
           Bourse.Lighter.private_post_sendtx(exchange, request_params) do
      {:ok, tx_hash}
    end
  end

  defp poll_transfer!(exchange, prior_count, tx_hash, attempts \\ @poll_attempts)

  defp poll_transfer!(_exchange, _prior_count, tx_hash, 0) do
    flunk("Lighter transfer #{tx_hash} did not enter history after #{@poll_attempts} attempts")
  end

  defp poll_transfer!(exchange, prior_count, tx_hash, attempts) do
    case Bourse.fetch_transfers(exchange) do
      {:ok, transfers} when length(transfers) > prior_count ->
        Enum.find(transfers, &(&1.info["tx_hash"] == tx_hash)) ||
          wait_then(fn -> poll_transfer!(exchange, prior_count, tx_hash, attempts - 1) end)

      {:ok, _transfers} ->
        wait_then(fn -> poll_transfer!(exchange, prior_count, tx_hash, attempts - 1) end)

      other ->
        flunk("Lighter transfer history failed: #{inspect(other)}")
    end
  end

  defp transfer_count!({:ok, transfers}) when is_list(transfers), do: length(transfers)
  defp transfer_count!(other), do: flunk("Lighter transfer history failed: #{inspect(other)}")

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

  defp crossing_price!(exchange, market, side) do
    assert {:ok, %OrderBook{bids: [[best_bid, _ | _] | _], asks: [[best_ask, _ | _] | _]}} =
             Bourse.fetch_order_book(exchange, market.symbol, limit: 1)

    {top, ratio, rounding} =
      if side == :buy,
        do: {best_ask, @buy_crossing_ratio, :ceiling},
        else: {best_bid, @sell_crossing_ratio, :floor}

    tick_size = Map.get(market.precision, :price, Map.get(market.precision, "price"))

    top
    |> decimal!()
    |> Decimal.mult(Decimal.new(ratio))
    |> Decimal.div(decimal!(tick_size))
    |> Decimal.round(0, rounding)
    |> Decimal.mult(decimal!(tick_size))
    |> Decimal.to_float()
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

  defp next_client_order_index do
    [:positive, :monotonic]
    |> System.unique_integer()
    |> rem(@maximum_client_order_index)
  end

  defp trade_ids!({:ok, trades}), do: MapSet.new(trades, & &1.id)
  defp trade_ids!(other), do: flunk("Lighter trade read failed: #{inspect(other)}")

  defp poll_new_trade!(exchange, prior_ids, attempts \\ @poll_attempts)

  defp poll_new_trade!(_exchange, _prior_ids, 0) do
    flunk("Lighter fill did not enter trade history after #{@poll_attempts} attempts")
  end

  defp poll_new_trade!(exchange, prior_ids, attempts) do
    case Bourse.fetch_my_trades(exchange) do
      {:ok, trades} ->
        Enum.find(trades, &(not MapSet.member?(prior_ids, &1.id))) ||
          wait_then(fn -> poll_new_trade!(exchange, prior_ids, attempts - 1) end)

      other ->
        flunk("Lighter trade read failed: #{inspect(other)}")
    end
  end

  defp poll_active_position!(exchange, symbol, attempts \\ @poll_attempts)

  defp poll_active_position!(_exchange, symbol, 0) do
    flunk("Lighter position #{symbol} did not become active after #{@poll_attempts} attempts")
  end

  defp poll_active_position!(exchange, symbol, attempts) do
    case find_position(exchange, symbol) do
      %Bourse.Position{contracts: contracts} = position when is_number(contracts) and contracts > 0 ->
        position

      _other ->
        wait_then(fn -> poll_active_position!(exchange, symbol, attempts - 1) end)
    end
  end

  defp poll_flat_position!(exchange, symbol, attempts \\ @poll_attempts)

  defp poll_flat_position!(_exchange, symbol, 0) do
    flunk("Lighter position #{symbol} did not flatten after #{@poll_attempts} attempts")
  end

  defp poll_flat_position!(exchange, symbol, attempts) do
    case find_position(exchange, symbol) do
      %Bourse.Position{contracts: contracts} = position when contracts == 0 ->
        position

      _other ->
        wait_then(fn -> poll_flat_position!(exchange, symbol, attempts - 1) end)
    end
  end

  defp find_position(exchange, symbol) do
    case Bourse.fetch_positions(exchange) do
      {:ok, positions} -> Enum.find(positions, &(&1.symbol == symbol))
      other -> flunk("Lighter position read failed: #{inspect(other)}")
    end
  end

  defp cleanup_position!(exchange, market, credentials) do
    case find_position(exchange, market.symbol) do
      %Bourse.Position{contracts: contracts, side: side} when is_number(contracts) and contracts > 0 ->
        close_side = if side == "long", do: "sell", else: "buy"
        crossing_side = if close_side == "sell", do: :sell, else: :buy

        assert {:ok, %{"code" => 200}} =
                 Bourse.create_order(exchange, market.symbol, "limit", close_side, contracts,
                   price: crossing_price!(exchange, market, crossing_side),
                   client_order_index: next_client_order_index(),
                   nonce: next_nonce!(exchange, credentials),
                   order_expiry: 0,
                   reduceOnly: true,
                   timeInForce: "IOC"
                 )

        _position = poll_flat_position!(exchange, market.symbol)
        :ok

      _flat_or_absent ->
        :ok
    end
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
