defmodule Bourse.LastPrice do
  @moduledoc """
  Unified last price data.

  Represents the most recent trade price for a symbol.

  ## Fields

    * `symbol` - Unified symbol
    * `timestamp` - Price timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `price` - Last traded price
    * `side` - Last trade side ("buy" or "sell")
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          price: number() | nil,
          side: String.t() | nil,
          info: map() | nil
        }

  defstruct [:symbol, :timestamp, :datetime, :price, :side, :info]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   price: number() | nil,
                   side: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol",
                   timestamp: "Price timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   price: "Last traded price",
                   side: ~s{Last trade side ("buy" or "sell")},
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the LastPrice unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
