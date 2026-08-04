defmodule Bourse.Liquidation do
  @moduledoc """
  Unified liquidation event data.

  Represents a liquidation event on a derivatives exchange.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT:USDT")
    * `timestamp` - Liquidation time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `price` - Liquidation price
    * `base_value` - Value in base currency
    * `quote_value` - Value in quote currency
    * `contracts` - Number of contracts liquidated
    * `contract_size` - Size of one contract
    * `side` - "long" or "short"
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          price: number() | nil,
          base_value: number() | nil,
          quote_value: number() | nil,
          contracts: number() | nil,
          contract_size: number() | nil,
          side: String.t() | nil,
          info: map() | nil
        }

  defstruct [
    :symbol,
    :timestamp,
    :datetime,
    :price,
    :base_value,
    :quote_value,
    :contracts,
    :contract_size,
    :side,
    :info
  ]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   price: number() | nil,
                   base_value: number() | nil,
                   quote_value: number() | nil,
                   contracts: number() | nil,
                   contract_size: number() | nil,
                   side: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (e.g., \"BTC/USDT:USDT\")",
                   timestamp: "Liquidation time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   price: "Liquidation price",
                   base_value: "Value in base currency",
                   quote_value: "Value in quote currency",
                   contracts: "Number of contracts liquidated",
                   contract_size: "Size of one contract",
                   side: ~s("long" or "short"),
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Liquidation unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
