defmodule Bourse.Order.Builder do
  @moduledoc """
  Fluent builder for unified order creation.

  Accumulates order options and submits through `Bourse.create_order/6`.
  """

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.Order.Sanity

  @type t :: %__MODULE__{
          symbol: String.t(),
          side: String.t(),
          amount: number(),
          type: String.t(),
          params: keyword()
        }

  @enforce_keys [:symbol, :side, :amount]
  defstruct [:symbol, :side, :amount, type: "market", params: []]

  @doc "Starts a market order builder for `symbol`, `side`, and `amount`."
  @spec new(String.t(), String.t(), number()) :: t()
  def new(symbol, side, amount) do
    %__MODULE__{symbol: symbol, side: side, amount: amount}
  end

  @doc "Turns the order into a limit order with `price`."
  @spec limit(t(), number()) :: t()
  def limit(%__MODULE__{} = builder, price) do
    %{builder | type: "limit", params: put_param(builder.params, :price, price)}
  end

  @doc "Adds a stop-loss price."
  @spec stop_loss(t(), number()) :: t()
  def stop_loss(%__MODULE__{} = builder, price) do
    %{builder | params: put_param(builder.params, :stop_loss_price, price)}
  end

  @doc "Adds a take-profit price."
  @spec take_profit(t(), number()) :: t()
  def take_profit(%__MODULE__{} = builder, price) do
    %{builder | params: put_param(builder.params, :take_profit_price, price)}
  end

  @doc "Submits the order through `Bourse.create_order/6` using `credentials`."
  @spec submit(t(), Exchange.t(), Credentials.t(), keyword()) ::
          {:ok, map()} | {:ok, map(), [Sanity.reason()]} | {:error, term()}
  def submit(%__MODULE__{} = builder, %Exchange{} = exchange, %Credentials{} = credentials, opts \\ []) do
    exchange_with_credentials = %{exchange | credentials: credentials}
    order_opts = builder.params ++ opts
    {sanity_opts, order_opts} = Keyword.pop(order_opts, :sanity)

    with {:ok, warnings} <- validate_sanity(builder, exchange, sanity_opts),
         {:ok, response} <-
           Bourse.create_order(
             exchange_with_credentials,
             builder.symbol,
             builder.type,
             builder.side,
             builder.amount,
             order_opts
           ) do
      if warnings == [], do: {:ok, response}, else: {:ok, response, warnings}
    end
  end

  defp validate_sanity(_builder, _exchange, nil), do: {:ok, []}

  defp validate_sanity(builder, exchange, sanity_opts) when is_list(sanity_opts) do
    market = Keyword.get(sanity_opts, :market)
    opts = sanity_opts |> Keyword.delete(:market) |> Keyword.put(:has, exchange.has)

    case Sanity.validate(builder, market, opts) do
      {:ok, _params} -> {:ok, []}
      {:ok, _params, warnings} -> {:ok, warnings}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_param(params, key, value) do
    params
    |> Keyword.delete(key)
    |> Kernel.++([{key, value}])
  end
end
