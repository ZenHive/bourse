defmodule Bourse.Order do
  @moduledoc """
  Unified order data.

  Represents the full state of an exchange order including fills,
  fees, and advanced order parameters.

  ## Fields

    * `id` - Exchange order ID
    * `client_order_id` - Client-assigned order ID
    * `symbol` - Unified symbol (e.g., "BTC/USDT")
    * `timestamp` - Order creation time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `status` - "open", "closed", or "canceled"
    * `type` - "limit", "market", etc.
    * `side` - "buy" or "sell"
    * `price` - Order price (limit orders)
    * `amount` - Requested quantity; options use base-currency exposure
    * `filled` - Quantity filled so far; options use base-currency exposure
    * `remaining` - Quantity remaining; options use base-currency exposure
    * `cost` - Total filled cost
    * `average` - Average fill price
    * `fee` - Cumulative fee
    * `fees` - Per-fill fee breakdown
    * `trades` - Individual fill executions
    * `time_in_force` - "GTC", "IOC", "FOK", "PO"
    * `stop_price`, `trigger_price` - Stop/trigger prices
    * `take_profit_price`, `stop_loss_price` - TP/SL prices
    * `reduce_only` - Derivatives: reduce position only
    * `post_only` - Maker-only order
    * `last_trade_timestamp`, `last_update_timestamp` - Last activity times
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          client_order_id: String.t() | nil,
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          status: String.t() | nil,
          type: String.t() | nil,
          side: String.t() | nil,
          price: number() | nil,
          amount: number() | nil,
          filled: number() | nil,
          remaining: number() | nil,
          cost: number() | nil,
          average: number() | nil,
          fee: Bourse.Fee.t() | nil,
          fees: [Bourse.Fee.t()],
          trades: [Bourse.Trade.t()],
          time_in_force: String.t() | nil,
          stop_price: number() | nil,
          trigger_price: number() | nil,
          take_profit_price: number() | nil,
          stop_loss_price: number() | nil,
          reduce_only: boolean() | nil,
          post_only: boolean() | nil,
          last_trade_timestamp: integer() | nil,
          last_update_timestamp: integer() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :client_order_id,
    :symbol,
    :timestamp,
    :datetime,
    :status,
    :type,
    :side,
    :price,
    :amount,
    :filled,
    :remaining,
    :cost,
    :average,
    :fee,
    :time_in_force,
    :stop_price,
    :trigger_price,
    :take_profit_price,
    :stop_loss_price,
    :reduce_only,
    :post_only,
    :last_trade_timestamp,
    :last_update_timestamp,
    :info,
    fees: [],
    trades: []
  ]

  @doc "Returns true if the order status is \"open\"."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: "open"}), do: true
  def open?(%__MODULE__{}), do: false

  @doc "Returns true if the order status is \"closed\"."
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{status: "closed"}), do: true
  def closed?(%__MODULE__{}), do: false

  @doc "Returns true if the order status is \"canceled\"."
  @spec canceled?(t()) :: boolean()
  def canceled?(%__MODULE__{status: "canceled"}), do: true
  def canceled?(%__MODULE__{}), do: false

  @doc "Returns true if filled equals amount (fully filled)."
  @spec filled?(t()) :: boolean()
  def filled?(%__MODULE__{filled: filled, amount: amount}) when is_number(filled) and is_number(amount) and amount > 0 do
    filled >= amount
  end

  def filled?(%__MODULE__{}), do: false

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   client_order_id: String.t() | nil,
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   status: String.t() | nil,
                   type: String.t() | nil,
                   side: String.t() | nil,
                   price: number() | nil,
                   amount: number() | nil,
                   filled: number() | nil,
                   remaining: number() | nil,
                   cost: number() | nil,
                   average: number() | nil,
                   fee: map() | nil,
                   fees: [map()],
                   trades: [map()],
                   time_in_force: String.t() | nil,
                   stop_price: number() | nil,
                   trigger_price: number() | nil,
                   take_profit_price: number() | nil,
                   stop_loss_price: number() | nil,
                   reduce_only: boolean() | nil,
                   post_only: boolean() | nil,
                   last_trade_timestamp: integer() | nil,
                   last_update_timestamp: integer() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Exchange order ID",
                   client_order_id: "Client-assigned order ID",
                   symbol: "Unified symbol (e.g., BTC/USDT)",
                   timestamp: "Order creation time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   status: "open, closed, or canceled",
                   type: "limit, market, etc.",
                   side: "buy or sell",
                   price: "Order price (limit orders)",
                   amount: "Requested quantity; options use base-currency exposure",
                   filled: "Quantity filled so far; options use base-currency exposure",
                   remaining: "Quantity remaining; options use base-currency exposure",
                   cost: "Total filled cost",
                   average: "Average fill price",
                   fee: "Cumulative fee",
                   fees: "Per-fill fee breakdown",
                   trades: "Individual fill executions",
                   time_in_force: "GTC, IOC, FOK, or PO",
                   stop_price: "Stop price",
                   trigger_price: "Trigger price",
                   take_profit_price: "Take profit price",
                   stop_loss_price: "Stop loss price",
                   reduce_only: "Derivatives: reduce position only",
                   post_only: "Maker-only order",
                   last_trade_timestamp: "Last trade timestamp in milliseconds",
                   last_update_timestamp: "Last update timestamp in milliseconds",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Order unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
