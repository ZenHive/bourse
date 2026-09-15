defmodule Bourse.ConditionalOrderOptionsIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Order
  alias Bourse.Unified
  alias Bourse.Unified.OrderOptions

  @moduletag :integration
  @moduletag :network
  @moduletag :dangerous

  for {venue, symbol, amount, type, native_trigger} <- [
        {:okx, "BTC/USDT:USDT", 0.01, "market", "triggerPx"},
        {:bybit, "BTC/USDT:USDT", 0.001, "market", "triggerPrice"},
        {:binance, "ETH/USDT:USDT", 0.25, "market", "triggerPrice"},
        {:binanceusdm, "ETH/USDT:USDT", 0.25, "market", "triggerPrice"},
        {:binancecoinm, "BTC/USD:BTC", 1, "market", "triggerPrice"},
        {:deribit, "BTC/USD:BTC", 10, "stop_market", "trigger_price"},
        {:alpaca, "AAPL", 1, "stop", "stop_price"}
      ] do
    @venue venue
    @symbol symbol
    @amount amount
    @order_type type
    @native_trigger native_trigger

    test "#{venue} keeps canonical and legacy trigger orders unfilled in its conditional book" do
      {exchange, opts} = sandbox!(@venue)
      assert {:ok, exchange} = Bourse.load_markets(exchange, opts)
      assert {:ok, ticker} = Bourse.fetch_ticker(exchange, @symbol, opts)
      market = Enum.find(exchange.markets, &(&1.symbol == @symbol))
      # Alpaca equities use the documented cent increment above $1, not an asset precision field.
      tick = if @venue == :alpaca, do: 0.01, else: market.precision["price"]
      assert is_number(tick) and tick > 0
      assert is_number(ticker.mark_price || ticker.last)

      trigger =
        (ticker.mark_price || ticker.last)
        |> to_string()
        |> Decimal.new()
        |> Decimal.mult(Decimal.new("0.85"))
        |> Decimal.div(Decimal.new(to_string(tick)))
        |> Decimal.round(0, :floor)
        |> Decimal.mult(Decimal.new(to_string(tick)))
        |> Decimal.to_float()

      for spelling <- spellings(@venue) do
        client_id = "t700#{System.system_time(:microsecond)}#{System.unique_integer([:positive])}"
        extras = [{spelling, trigger} | selectors(@venue)] ++ reduce_only_opt(@venue)
        order_opts = [{:clientOrderId, client_id} | extras ++ opts]

        params =
          Unified.build_params([:symbol, :type, :side, :amount], [@symbol, @order_type, "sell", @amount], extras)

        # Refuse to reproduce the original bug by sending an unprotected market order.
        assert {:ok, prepared} = OrderOptions.prepare(exchange, :create_order, params)
        assert {:ok, [shape]} = Unified.request_param_shapes(exchange, :create_order, prepared)
        assert numeric(shape[@native_trigger]) == trigger
        assert_conditional_shape!(shape, @venue)

        assert {:ok, %Order{id: id}} = Bourse.create_order(exchange, @symbol, @order_type, "sell", @amount, order_opts)
        assert is_binary(id) and id != ""

        read_opts = Keyword.put(opts, :symbol, @symbol) ++ book_selector(@venue)
        on_exit(fn -> cancel_owned(exchange, id, read_opts) end)

        order = resting_trigger!(@venue, exchange, id, read_opts)
        assert order.status == "open"
        assert order.side == "sell"
        assert order.filled in [nil, 0, 0.0]
        assert numeric(order.trigger_price) == trigger
        assert_reduce_only!(@venue, order)
        assert_untriggered!(@venue, order.info)

        assert {:ok, %Order{} = fetched} = Bourse.fetch_order(exchange, id, read_opts)
        assert numeric(fetched.trigger_price) == trigger
        assert_reduce_only!(@venue, fetched)

        assert {:ok, _} = Bourse.cancel_order(exchange, id, read_opts)
      end

      rejected_opts = [{hd(spellings(@venue)), trigger} | opts] ++ selectors(@venue)

      assert {:error, %Error{type: error_type, code: code} = error} =
               Bourse.create_order(exchange, @symbol, @order_type, "sell", 0, rejected_opts)

      assert error_type in [:invalid_order, :bad_request, :invalid_parameters]
      assert not is_nil(code), "rejection must come from the provider"
      assert inspect(error.raw) =~ ~r/qty|quantity|amount|\bsz\b|size|number of contracts/i
    end
  end

  defp spellings(venue) when venue in [:binance, :binanceusdm, :binancecoinm, :deribit],
    do: [:trigger_price, :triggerPrice]

  defp spellings(_venue), do: [:triggerPrice, :trigger_price]

  defp sandbox!(:bybit) do
    credentials =
      for {key, variable} <- [api_key: "BYBIT_DEMO_API_KEY", secret: "BYBIT_DEMO_API_SECRET"] do
        value = System.get_env(variable)

        assert value not in [nil, ""],
               "export #{variable}=your_demo_value; create a demo key at https://www.bybit.com/app/user/api-management"

        {key, value}
      end

    exchange = Exchange.new!("bybit", credentials: Bourse.Credentials.new!(credentials))
    opts = [base_url: "https://api-demo.bybit.com"]
    assert {:ok, _} = Bourse.fetch_balance(exchange, opts)
    {exchange, opts}
  end

  defp sandbox!(venue) do
    {registry, credential_opts} =
      if venue in [:binance, :binanceusdm, :binancecoinm],
        do: {:binance, [sandbox_key: :futures, url: "https://demo.binance.com/en/my/settings/api-management"]},
        else: {venue, [url: sandbox_url(venue)]}

    credentials = require_credentials!(registry, credential_opts)
    {build_exchange(venue, credentials: credentials, sandbox: true), []}
  end

  defp selectors(:bybit), do: [triggerDirection: 2]
  defp selectors(:deribit), do: [trigger: "index_price"]
  defp selectors(:alpaca), do: [time_in_force: "gtc"]
  defp selectors(_venue), do: []

  defp reduce_only_opt(:alpaca), do: []
  defp reduce_only_opt(_venue), do: [reduce_only: false]

  defp assert_reduce_only!(:alpaca, %Order{reduce_only: reduce_only}), do: assert(is_nil(reduce_only))
  defp assert_reduce_only!(_venue, %Order{reduce_only: reduce_only}), do: assert(reduce_only == false)

  defp book_selector(:okx), do: [stop: true]
  defp book_selector(_venue), do: []

  defp assert_conditional_shape!(shape, venue) when venue in [:binance, :binanceusdm, :binancecoinm] do
    assert shape["algoType"] == "CONDITIONAL"
    assert shape["type"] == "STOP_MARKET"
  end

  defp assert_conditional_shape!(shape, :okx), do: assert(shape["ordType"] == "trigger")
  defp assert_conditional_shape!(shape, :bybit), do: assert(shape["triggerDirection"] == 2)
  defp assert_conditional_shape!(shape, :deribit), do: assert(shape["type"] == "stop_market")
  defp assert_conditional_shape!(shape, :alpaca), do: assert(shape["type"] == "stop")

  defp sandbox_url(:okx), do: "https://www.okx.com"
  defp sandbox_url(:alpaca), do: "https://app.alpaca.markets/paper/dashboard/overview"
  defp sandbox_url(:deribit), do: "https://test.deribit.com"

  defp assert_untriggered!(:okx, info), do: assert(info["state"] == "live")
  defp assert_untriggered!(:bybit, info), do: assert(info["orderStatus"] == "Untriggered")
  defp assert_untriggered!(:deribit, info), do: assert(info["order_state"] == "untriggered")
  defp assert_untriggered!(:alpaca, info), do: assert(info["status"] in ["new", "accepted"])
  defp assert_untriggered!(_binance, info), do: assert(info["algoStatus"] == "NEW")

  defp resting_trigger!(venue, exchange, id, read_opts) do
    assert {:ok, orders} = Bourse.fetch_open_orders(exchange, read_opts)
    order = Enum.find(orders, &(&1.id == id))

    if is_nil(order) do
      seen =
        case Bourse.fetch_order(exchange, id, read_opts) do
          {:ok, %Order{} = found} ->
            " fetch_order status=#{inspect(found.status)} filled=#{inspect(found.filled)} type=#{inspect(found.type)}"

          other ->
            " fetch_order=#{inspect(other)}"
        end

      flunk(
        "owned trigger #{id} missing from #{venue} conditional book; a market fill is a failure, not cleanup success.#{seen}"
      )
    end

    order
  end

  defp cancel_owned(exchange, id, read_opts) do
    case Bourse.cancel_order(exchange, id, read_opts) do
      {:ok, _} -> :ok
      {:error, %Error{type: type}} when type in [:order_not_found, :invalid_order] -> :ok
      {:error, error} -> flunk("cleanup for owned trigger #{id} failed: #{inspect(error)}")
    end
  end

  defp numeric(value) when is_number(value), do: value
  defp numeric(value) when is_binary(value), do: value |> Float.parse() |> elem(0)
  defp numeric(value), do: flunk("missing numeric trigger: #{inspect(value)}")
end
