defmodule Bourse.Conversion do
  @moduledoc """
  Unified currency conversion data.

  Represents a convert trade (currency swap) on an exchange.

  ## Fields

    * `id` - Conversion ID
    * `timestamp` - Conversion time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `from_currency` - Source currency code
    * `from_amount` - Source amount
    * `to_currency` - Destination currency code
    * `to_amount` - Destination amount
    * `price` - Conversion rate
    * `fee` - Conversion fee amount
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          from_currency: String.t() | nil,
          from_amount: number() | nil,
          to_currency: String.t() | nil,
          to_amount: number() | nil,
          price: number() | nil,
          fee: number() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :timestamp,
    :datetime,
    :from_currency,
    :from_amount,
    :to_currency,
    :to_amount,
    :price,
    :fee,
    :info
  ]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   from_currency: String.t() | nil,
                   from_amount: number() | nil,
                   to_currency: String.t() | nil,
                   to_amount: number() | nil,
                   price: number() | nil,
                   fee: number() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Conversion ID",
                   timestamp: "Conversion time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   from_currency: "Source currency code",
                   from_amount: "Source amount",
                   to_currency: "Destination currency code",
                   to_amount: "Destination amount",
                   price: "Conversion rate",
                   fee: "Conversion fee amount",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Conversion unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
