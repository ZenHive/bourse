defmodule Bourse.OptionSaga.Executor do
  @moduledoc """
  Executes one saga command against caller-supplied exchange configurations.

  It performs exactly one submission or cancellation. Reconciliation may read
  the order endpoint and provider order-state collections, but never submits an
  order. Retry policy belongs to `Bourse.OptionSaga`, where ambiguous writes are
  journaled before another command can be emitted.
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Order

  @collection_reads [:fetch_open_orders, :fetch_closed_orders, :fetch_canceled_orders]

  @type exchanges :: %{{String.t(), term()} => Exchange.t()} | %{String.t() => Exchange.t()}
  @type outcome ::
          {:ok, Order.t()}
          | {:not_found, map()}
          | {:unknown, term()}
          | {:error, Error.t()}

  @doc "Executes one command using the exchange matching its venue/account domain."
  @spec execute(map(), exchanges(), keyword()) :: outcome()
  def execute(command, exchanges, opts \\ []) when is_map(command) and is_map(exchanges) and is_list(opts) do
    with {:ok, exchange} <- exchange_for(command, exchanges) do
      execute_action(command, exchange, opts)
    end
  end

  defp execute_action(%{action: :submit} = command, exchange, opts) do
    order_opts =
      opts
      |> request_opts()
      |> Keyword.put(:clientOrderId, command.client_order_id)
      |> maybe_put(:price, command.price)

    invoke(opts, :create_order, exchange, [command.symbol, command.type, command.side, command.amount], order_opts)
  end

  defp execute_action(%{action: :cancel} = command, exchange, opts) do
    order_opts = opts |> request_opts() |> Keyword.put(:symbol, command.symbol)
    invoke(opts, :cancel_order, exchange, [command.order_id], order_opts)
  end

  defp execute_action(%{action: :reconcile} = command, exchange, opts) do
    case fetch_by_order_id(command, exchange, opts) do
      {:ok, %Order{}} = found -> found
      {:error, %Error{type: :order_not_found}} -> fetch_by_client_id(command, exchange, opts)
      {:not_found, _} -> fetch_by_client_id(command, exchange, opts)
      {:error, %Error{}} = error -> error
    end
  end

  defp fetch_by_order_id(%{order_id: order_id} = command, exchange, opts) when is_binary(order_id) and order_id != "" do
    order_opts = opts |> request_opts() |> Keyword.put(:symbol, command.symbol)
    invoke(opts, :fetch_order, exchange, [order_id], order_opts)
  end

  defp fetch_by_order_id(_command, _exchange, _opts), do: {:not_found, %{source: :order_id_missing}}

  defp fetch_by_client_id(command, exchange, opts) do
    Enum.reduce_while(@collection_reads, {:not_found, %{sources: []}}, fn method, {:not_found, detail} ->
      order_opts =
        opts
        |> request_opts()
        |> Keyword.put(:symbol, command.symbol)
        |> Keyword.put(:clientOrderId, command.client_order_id)

      case invoke(opts, method, exchange, [], order_opts) do
        {:ok, orders} when is_list(orders) ->
          collection_result(orders, command, method, detail)

        {:error, %Error{}} = error ->
          {:halt, error}

        other ->
          {:halt,
           {:error,
            Error.exchange_error(
              "unexpected #{method} reconciliation result: #{inspect(other)}",
              exchange: exchange.id
            )}}
      end
    end)
  end

  defp collection_result(orders, command, method, detail) do
    case find_order(orders, command) do
      %Order{} = order -> {:halt, {:ok, order}}
      nil -> {:cont, {:not_found, %{sources: detail.sources ++ [method]}}}
    end
  end

  defp find_order(orders, command) do
    Enum.find(orders, fn
      %Order{client_order_id: client_order_id, id: order_id} ->
        client_order_id == command.client_order_id or
          (is_binary(command.order_id) and order_id == command.order_id)

      _ ->
        false
    end)
  end

  defp exchange_for(command, exchanges) do
    case Map.get(exchanges, {command.venue, command.account}) || Map.get(exchanges, command.venue) do
      %Exchange{} = exchange ->
        {:ok, exchange}

      _ ->
        {:error,
         Error.invalid_parameters(
           message: "missing exchange for saga domain #{inspect({command.venue, command.account})}"
         )}
    end
  end

  defp invoke(opts, method, exchange, args, order_opts) do
    case Keyword.get(opts, :call) do
      call when is_function(call, 4) -> call.(method, exchange, args, order_opts)
      nil -> apply(Bourse, method, [exchange | args] ++ [order_opts])
    end
  end

  defp request_opts(opts), do: Keyword.get(opts, :request_opts, [])

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
