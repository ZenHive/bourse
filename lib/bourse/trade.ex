defmodule Bourse.Trade do
  @moduledoc """
  Unified trade execution data.

  Represents a single fill/execution on an exchange.

  ## Fields

    * `id` - Exchange trade ID
    * `order_id` - Associated order ID
    * `client_order_id` - Client-assigned order ID echoed on the fill, when the venue returns one
    * `symbol` - Unified symbol (e.g., "BTC/USDT")
    * `timestamp` - Execution time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `side` - "buy" or "sell"
    * `type` - Order type that produced this trade (e.g., "limit", "market")
    * `price` - Execution price
    * `amount` - Quantity executed
    * `cost` - Total cost (price * amount)
    * `taker_or_maker` - "taker" or "maker"
    * `fee` - Fee charged for this trade
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          order_id: String.t() | nil,
          client_order_id: String.t() | nil,
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          side: String.t() | nil,
          type: String.t() | nil,
          price: number() | nil,
          amount: number() | nil,
          cost: number() | nil,
          taker_or_maker: String.t() | nil,
          fee: Bourse.Fee.t() | map() | nil,
          fees: [map()] | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :order_id,
    :client_order_id,
    :symbol,
    :timestamp,
    :datetime,
    :side,
    :type,
    :price,
    :amount,
    :cost,
    :taker_or_maker,
    :fee,
    :fees,
    :info
  ]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   order_id: String.t() | nil,
                   client_order_id: String.t() | nil,
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   side: String.t() | nil,
                   type: String.t() | nil,
                   price: number() | nil,
                   amount: number() | nil,
                   cost: number() | nil,
                   taker_or_maker: String.t() | nil,
                   fee: map() | nil,
                   fees: [map()],
                   info: map() | nil
                 },
                 doc: [
                   id: "Exchange trade ID",
                   order_id: "Associated order ID",
                   client_order_id: "Client-assigned order ID echoed on the fill, when the venue returns one",
                   symbol: "Unified symbol (e.g., BTC/USDT)",
                   timestamp: "Execution time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   side: "buy or sell",
                   type: "Order type (e.g., limit, market)",
                   price: "Execution price",
                   amount: "Quantity executed",
                   cost: "Total cost (price * amount)",
                   taker_or_maker: "taker or maker",
                   fee: "Fee charged for this trade",
                   fees: "All fees charged for this trade (Bourse safeTrade plural form)",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Trade unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
