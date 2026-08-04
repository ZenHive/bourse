defmodule Bourse.OpenInterest do
  @moduledoc """
  Unified open interest data.

  Represents the total open interest for a derivatives contract.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT:USDT")
    * `open_interest_amount` - Open interest in contracts
    * `open_interest_value` - Open interest in quote currency
    * `base_volume` - Base currency volume
    * `quote_volume` - Quote currency volume
    * `timestamp` - Data timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          open_interest_amount: number() | nil,
          open_interest_value: number() | nil,
          base_volume: number() | nil,
          quote_volume: number() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          info: map() | nil
        }

  defstruct [
    :symbol,
    :open_interest_amount,
    :open_interest_value,
    :base_volume,
    :quote_volume,
    :timestamp,
    :datetime,
    :info
  ]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   open_interest_amount: number() | nil,
                   open_interest_value: number() | nil,
                   base_volume: number() | nil,
                   quote_volume: number() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (e.g., \"BTC/USDT:USDT\")",
                   open_interest_amount: "Open interest in contracts",
                   open_interest_value: "Open interest in quote currency",
                   base_volume: "Base currency volume",
                   quote_volume: "Quote currency volume",
                   timestamp: "Data timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the OpenInterest unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
