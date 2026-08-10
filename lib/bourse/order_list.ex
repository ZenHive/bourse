defmodule Bourse.OrderList do
  @moduledoc """
  Unified order-group data.

  An order list has its own identifier and lifecycle while referencing multiple
  constituent orders. The `orders` entries are the exchange's order references,
  not full `%Bourse.Order{}` rows.
  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          client_order_id: String.t() | nil,
          symbol: String.t() | nil,
          type: String.t() | nil,
          status: String.t() | nil,
          status_type: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          orders: [map()],
          info: map() | nil
        }

  defstruct [
    :id,
    :client_order_id,
    :symbol,
    :type,
    :status,
    :status_type,
    :timestamp,
    :datetime,
    :info,
    orders: []
  ]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   client_order_id: String.t() | nil,
                   symbol: String.t() | nil,
                   type: String.t() | nil,
                   status: String.t() | nil,
                   status_type: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   orders: [map()],
                   info: map() | nil
                 },
                 doc: [
                   id: "Exchange order-list ID",
                   client_order_id: "Client-assigned order-list ID",
                   symbol: "Unified symbol (e.g., BTC/USDT)",
                   type: "Order-group type (e.g., oco or oto)",
                   status: "Unified group status",
                   status_type: "Exchange lifecycle event type",
                   timestamp: "Order-list transaction time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   orders: "Exchange order references belonging to the group",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the OrderList unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
