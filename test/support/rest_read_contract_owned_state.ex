defmodule Bourse.Test.RestReadContractOwnedState do
  @moduledoc """
  Creates and tears down the sandbox state a REST-read resource argument needs.

  `fetchOpenOrders` / `fetchOrders` get a far-from-market resting limit.
  `fetchCanceledOrders` gets the same order cancelled before the read.
  History windows that the venue itself expires are not manufactured here.
  """

  alias Bourse.Error
  alias Bourse.Order
  alias Bourse.Test.Journeys.Case, as: Journey

  require Logger

  @resting_ratio 0.9
  @resting_sources ["fetchOpenOrders", "fetchOrders"]
  @canceled_sources ["fetchCanceledOrders"]
  @transfer_amount 1

  @doc "Whether the scenario can manufacture a sandbox row for this resource source."
  @spec ownable_source?(String.t()) :: boolean()
  def ownable_source?(source) when is_binary(source) do
    source in @resting_sources or source in @canceled_sources or source == "transfer"
  end

  @doc "Creates the live row a resource argument needs, or `:unownable`."
  @spec ensure(map(), map(), map()) :: {:ok, term()} | :unownable | {:error, term()}
  def ensure(argument, contract_case, context) do
    source = argument["source_method"]

    cond do
      source in @resting_sources -> own_resting_order(argument, contract_case, context)
      source in @canceled_sources -> own_canceled_order(argument, contract_case, context)
      source == "transfer" or argument["source_kind"] == "transfer" -> own_transfer(context)
      true -> :unownable
    end
  end

  # `source_kind: "algo"` names a venue's algo book, whose ids only the
  # `algoOrder` read branches accept. A plain GTC limit would yield an
  # `orderId` that endpoint answers `order_not_found` for, so the algo case
  # needs a conditional order of its own. The kind is declared rather than
  # inferred from `source_endpoint_index`, which other venues use to select an
  # ordinary book.
  defp own_resting_order(%{"source_kind" => "algo"} = argument, contract_case, context) do
    with {:ok, placed} <- place_algo_order(contract_case, context),
         :ok <- register_algo_cleanup!(context.exchange, placed, argument),
         :ok <- await_algo_readable(context.exchange, placed, argument, contract_case) do
      owned_field(placed, argument)
    end
  end

  defp own_resting_order(argument, contract_case, context) do
    with {:ok, placed} <- place_resting_order(contract_case, context) do
      register_cleanup!(context.exchange, placed)
      await_readable(context.exchange, placed)
      owned_field(placed, argument)
    end
  end

  defp owned_field(placed, argument) do
    field = field_from(placed, argument["field"])

    if is_nil(field), do: {:error, {:missing_field, argument["field"], placed}}, else: {:ok, field}
  end

  # A venue indexes a create into its order-read surface a beat after the create
  # answers, so reading the new id immediately can answer `order_not_found` for
  # an order that exists. Observed on bybit's `/v5/order/realtime`, where the
  # order-identity cases lose that race often enough to red the lane — and lose
  # it again on the automatic retry, which places a fresh order and reads it
  # just as fast, so it reports as a confirmed failure rather than a flake.
  #
  # Waiting out the lag is this function's job; deciding what an exhausted wait
  # means is not. On timeout the id is handed over anyway and the case's own
  # assertion fails with the venue's answer, which is the message worth reading.
  defp await_readable(exchange, %Order{id: id, symbol: symbol}) when is_binary(id) and is_binary(symbol) do
    poll =
      Journey.poll_until(fn ->
        case Bourse.fetch_order(exchange, id, symbol: symbol) do
          {:ok, %Order{}} -> {:ok, :readable}
          _unreadable -> :retry
        end
      end)

    if poll == :timeout do
      Logger.warning("rest_read_contract: order #{id} on #{symbol} never became readable; reading it anyway")
    end

    :ok
  end

  defp await_readable(_exchange, _placed), do: :ok

  # Binance futures serve a new algo order from the open-algo list at once, while
  # the single-order `algoOrder` detail read answers -2013 "Order does not exist."
  # for up to ~1.3 s after the create (measured 2026-11-25 on demo-fapi and
  # demo-dapi; once it answers, it keeps answering). -2013 is also what an id the
  # venue never issued gets, so the miss alone proves nothing. It counts as
  # propagation only while the id is listed on the open-algo book: anything else
  # — an unlisted id, another error, another id, a miss outliving the bound —
  # fails the case here rather than being waited out. The contract's own read
  # stays the assertion; this wait only decides when to make it.
  @propagation_miss_code -2013

  defp await_algo_readable(exchange, %Order{id: id, symbol: symbol}, argument, contract_case)
       when is_binary(id) and is_binary(symbol) do
    with :ok <- listed_on_algo_book(exchange, id, symbol, argument),
         {:ok, read} <- algo_detail_read(contract_case) do
      opts = [symbol: symbol, endpoint_index: contract_case["endpoint_index"]]
      poll = Journey.poll_until(fn -> classify_algo_detail(read.(exchange, id, opts), id) end)
      algo_wait_outcome(poll, id, contract_case)
    end
  end

  defp await_algo_readable(_exchange, placed, _argument, _contract_case), do: {:error, {:algo_order_without_id, placed}}

  defp classify_algo_detail({:ok, %Order{id: id}}, id), do: {:ok, :readable}
  defp classify_algo_detail({:error, %Error{type: :order_not_found, code: @propagation_miss_code}}, _id), do: :retry
  defp classify_algo_detail(other, id), do: {:ok, {:unexpected_algo_detail, id, other}}

  defp algo_wait_outcome({:ok, :readable}, _id, _contract_case), do: :ok
  defp algo_wait_outcome({:ok, unexpected}, _id, _contract_case), do: {:error, unexpected}

  defp algo_wait_outcome(:timeout, id, contract_case),
    do: {:error, {:algo_order_never_readable, id, contract_case["method"]}}

  defp listed_on_algo_book(exchange, id, symbol, argument) do
    case Bourse.fetch_open_orders(exchange, symbol: symbol, endpoint_index: argument["source_endpoint_index"]) do
      {:ok, rows} when is_list(rows) ->
        if Enum.any?(rows, &match?(%Order{id: ^id}, &1)),
          do: :ok,
          else: {:error, {:algo_order_not_listed, id, Enum.map(rows, & &1.id)}}

      other ->
        {:error, {:algo_book_unreadable, other}}
    end
  end

  defp algo_detail_read(%{"method" => "fetchOrder"}), do: {:ok, &Bourse.fetch_order/3}
  defp algo_detail_read(%{"method" => "fetchOpenOrder"}), do: {:ok, &Bourse.fetch_open_order/3}
  defp algo_detail_read(%{"method" => method}), do: {:error, {:no_algo_detail_read, method}}

  defp own_canceled_order(argument, contract_case, context) do
    # Register cleanup before cancelling: a cancel that raises would otherwise
    # leave the order resting on the sandbox forever. A second cancel of an
    # already-cancelled order answers `order_not_found`, which `release_order!`
    # treats as success.
    with {:ok, placed} <- place_resting_order(contract_case, context),
         :ok <- register_cleanup!(context.exchange, placed),
         :ok <- cancel_now(context.exchange, placed) do
      field = field_from(placed, argument["field"])

      if is_nil(field), do: {:error, {:missing_field, argument["field"], placed}}, else: {:ok, field}
    end
  end

  defp own_transfer(context) do
    case place_reversible_transfer(context.exchange) do
      {:ok, %Bourse.TransferEntry{id: id} = placed, reverse_from, reverse_to}
      when is_binary(id) and id != "" ->
        register_transfer_cleanup!(
          context.exchange,
          placed.currency || "USDT",
          @transfer_amount,
          reverse_from,
          reverse_to
        )

        {:ok, id}

      {:ok, placed, _reverse_from, _reverse_to} ->
        {:error, {:missing_field, "id", placed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Read which account actually holds the funds instead of trying a direction and
  # falling back. OKX demo keeps its USDT in `trading` and `funding` empty, so a
  # try-then-fallback always burned a doomed POST first and the follow-up hit the
  # venue's funds-transfer budget as `50011 Too many requests` — the state the
  # case needs never got created. One read, then one POST.
  defp place_reversible_transfer(exchange) do
    wait = [rate_limit_max_wait_ms: 60_000]

    with {:ok, from, to} <- funded_transfer_direction(exchange),
         {:ok, placed} <- Bourse.transfer(exchange, "USDT", @transfer_amount, from, to, wait) do
      {:ok, placed, to, from}
    end
  end

  defp funded_transfer_direction(exchange) do
    with {:ok, funding} <- Bourse.fetch_balance(exchange, type: "funding"),
         {:ok, trading} <- Bourse.fetch_balance(exchange, type: "trading") do
      cond do
        free_usdt(funding) >= @transfer_amount -> {:ok, "funding", "trading"}
        free_usdt(trading) >= @transfer_amount -> {:ok, "trading", "funding"}
        true -> {:error, {:insufficient_usdt_for_transfer, @transfer_amount}}
      end
    end
  end

  defp free_usdt(%Bourse.Balance{free: free}) when is_map(free) do
    case Map.get(free, "USDT") do
      amount when is_number(amount) -> amount
      _absent -> 0
    end
  end

  defp free_usdt(_balance), do: 0

  # Cleanup must not redden the case it cleans up after, but a reversal that keeps
  # failing drains the demo wallet one unit per run, so name it rather than drop it.
  defp register_transfer_cleanup!(exchange, currency, amount, from_account, to_account) do
    ExUnit.Callbacks.on_exit(fn ->
      case Bourse.transfer(exchange, currency, amount, from_account, to_account) do
        {:ok, _reversed} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "rest_read_contract: could not reverse the #{amount} #{currency} " <>
              "#{from_account}->#{to_account} transfer: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp place_resting_order(contract_case, context) do
    symbol = contract_case["resolved_symbol"] || market_symbol(context, contract_case)
    market = Enum.find(context.markets || [], &(&1.symbol == symbol))
    amount = min_amount(market)

    case resting_price(context.exchange, symbol, market) do
      price when is_number(price) and price > 0 ->
        sized = sized_amount(amount, price, market)
        Bourse.create_order(context.exchange, symbol, "limit", "buy", sized, price: price, time_in_force: "GTC")

      _missing ->
        {:error, :no_resting_price}
    end
  end

  # A far-below-market conditional sell rests on the venue's algo book
  # (`POST /fapi/v1/algoOrder`, live-proven shape: market + trigger_price +
  # GTC answers `%Order{status: "open", type: "stop_market"}`). Its id is an
  # `algoId`, which is what the `algoOrder` read branches require.
  defp place_algo_order(contract_case, context) do
    symbol = contract_case["resolved_symbol"] || market_symbol(context, contract_case)
    market = Enum.find(context.markets || [], &(&1.symbol == symbol))

    case resting_price(context.exchange, symbol, market) do
      trigger when is_number(trigger) and trigger > 0 ->
        Bourse.create_order(
          context.exchange,
          symbol,
          "market",
          "sell",
          sized_amount(min_amount(market), trigger, market),
          time_in_force: "GTC",
          trigger_price: trigger
        )

      _missing ->
        {:error, :no_resting_price}
    end
  end

  defp resting_price(exchange, symbol, market) do
    case Bourse.fetch_ticker(exchange, symbol) do
      {:ok, ticker} ->
        bid = ticker.bid || ticker.last
        if is_number(bid) and bid > 0, do: round_to(bid * @resting_ratio, market, "price")

      _other ->
        nil
    end
  end

  defp cancel_now(exchange, placed) do
    Journey.release_order!(exchange, placed.id, placed.symbol)
  end

  defp register_cleanup!(exchange, placed) do
    id = placed.id
    symbol = placed.symbol

    ExUnit.Callbacks.on_exit(fn ->
      Journey.release_order!(exchange, id, symbol)
    end)

    :ok
  end

  # `release_order!` reads `order_not_found` as already gone. For an algo id that
  # is also what a cancel routed to the wrong book answers, so the cleanup checks
  # the open-algo book instead of trusting the miss.
  defp register_algo_cleanup!(exchange, %Order{id: id, symbol: symbol}, argument) do
    ExUnit.Callbacks.on_exit(fn ->
      release_algo_order!(Bourse.cancel_order(exchange, id, symbol: symbol), exchange, id, symbol, argument)
    end)

    :ok
  end

  defp release_algo_order!({:ok, %Order{id: id}}, _exchange, id, _symbol, _argument), do: :ok

  defp release_algo_order!({:error, %Error{type: :order_not_found}} = miss, exchange, id, symbol, argument) do
    if listed_on_algo_book(exchange, id, symbol, argument) == :ok do
      ExUnit.Assertions.flunk(
        "cleanup for algo order #{id} answered #{inspect(miss)} while it still rests on the algo book"
      )
    end

    :ok
  end

  defp release_algo_order!(other, _exchange, id, _symbol, _argument),
    do: ExUnit.Assertions.flunk("cleanup for algo order #{id} failed: #{inspect(other)}")

  defp min_amount(%{limits: %{"amount" => %{"min" => min}}}) when is_number(min) and min > 0, do: min
  defp min_amount(_market), do: 0.001

  # USD-M demo rejects notionals below 50; size the resting buy above that floor.
  @min_notional 100.0

  defp sized_amount(min_amount, price, market) when price > 0 do
    needed = @min_notional / price
    raw = if needed > min_amount, do: needed, else: min_amount
    round_to(raw, market, "amount")
  end

  defp round_to(value, %{precision: precision}, "amount") when is_map(precision) do
    ceil_precision(value, precision["amount"])
  end

  defp round_to(value, %{precision: precision}, "price") when is_map(precision) do
    floor_precision(value, precision["price"])
  end

  defp round_to(value, _market, _key), do: Float.round(value, 8)

  defp ceil_precision(value, precision) when is_integer(precision) and precision >= 0 do
    factor = :math.pow(10, precision)
    Float.ceil(value * factor - 1.0e-9) / factor
  end

  defp ceil_precision(value, precision) when is_float(precision) and precision > 0 and precision < 1 do
    Float.round(Float.ceil(value / precision - 1.0e-9) * precision, 8)
  end

  defp ceil_precision(value, _precision), do: Float.round(value, 8)

  defp floor_precision(value, precision) when is_integer(precision) and precision >= 0 do
    factor = :math.pow(10, precision)
    Float.floor(value * factor + 1.0e-9) / factor
  end

  defp floor_precision(value, precision) when is_float(precision) and precision > 0 and precision < 1 do
    Float.round(Float.floor(value / precision + 1.0e-9) * precision, 8)
  end

  defp floor_precision(value, _precision), do: Float.round(value, 8)

  defp field_from(%Order{} = order, "id"), do: order.id
  defp field_from(order, field), do: Map.get(order, String.to_existing_atom(field))

  defp market_symbol(context, contract_case) do
    kind = contract_case["market_kind"]
    context.venue_contract["symbols"][kind] || context.venue_contract["symbols"]["spot"]
  end
end
