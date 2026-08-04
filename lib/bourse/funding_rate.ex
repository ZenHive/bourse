defmodule Bourse.FundingRate do
  @moduledoc """
  Unified funding rate data.

  Represents the current or historical funding rate for a perpetual swap contract.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT:USDT")
    * `timestamp` - Data timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `funding_rate` - Current funding rate as decimal
    * `mark_price` - Current mark price
    * `index_price` - Current index price
    * `interest_rate` - Interest rate component
    * `estimated_settle_price` - Estimated settlement price
    * `funding_timestamp` - Funding event timestamp
    * `funding_datetime` - Funding event datetime
    * `next_funding_timestamp` - Next funding event timestamp
    * `next_funding_datetime` - Next funding event datetime
    * `next_funding_rate` - Next estimated funding rate
    * `previous_funding_timestamp` - Previous funding event timestamp
    * `previous_funding_datetime` - Previous funding event datetime
    * `previous_funding_rate` - Previous funding rate
    * `interval` - Funding interval (e.g., "8h")
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          funding_rate: number() | nil,
          mark_price: number() | nil,
          index_price: number() | nil,
          interest_rate: number() | nil,
          estimated_settle_price: number() | nil,
          funding_timestamp: integer() | nil,
          funding_datetime: String.t() | nil,
          next_funding_timestamp: integer() | nil,
          next_funding_datetime: String.t() | nil,
          next_funding_rate: number() | nil,
          previous_funding_timestamp: integer() | nil,
          previous_funding_datetime: String.t() | nil,
          previous_funding_rate: number() | nil,
          interval: String.t() | nil,
          info: map() | nil
        }

  defstruct [
    :symbol,
    :timestamp,
    :datetime,
    :funding_rate,
    :mark_price,
    :index_price,
    :interest_rate,
    :estimated_settle_price,
    :funding_timestamp,
    :funding_datetime,
    :next_funding_timestamp,
    :next_funding_datetime,
    :next_funding_rate,
    :previous_funding_timestamp,
    :previous_funding_datetime,
    :previous_funding_rate,
    :interval,
    :info
  ]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   funding_rate: number() | nil,
                   mark_price: number() | nil,
                   index_price: number() | nil,
                   interest_rate: number() | nil,
                   estimated_settle_price: number() | nil,
                   funding_timestamp: integer() | nil,
                   funding_datetime: String.t() | nil,
                   next_funding_timestamp: integer() | nil,
                   next_funding_datetime: String.t() | nil,
                   next_funding_rate: number() | nil,
                   previous_funding_timestamp: integer() | nil,
                   previous_funding_datetime: String.t() | nil,
                   previous_funding_rate: number() | nil,
                   interval: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (e.g., BTC/USDT:USDT)",
                   timestamp: "Data timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   funding_rate: "Current funding rate as decimal",
                   mark_price: "Current mark price",
                   index_price: "Current index price",
                   interest_rate: "Interest rate component",
                   estimated_settle_price: "Estimated settlement price",
                   funding_timestamp: "Funding event timestamp",
                   funding_datetime: "Funding event datetime",
                   next_funding_timestamp: "Next funding event timestamp",
                   next_funding_datetime: "Next funding event datetime",
                   next_funding_rate: "Next estimated funding rate",
                   previous_funding_timestamp: "Previous funding event timestamp",
                   previous_funding_datetime: "Previous funding event datetime",
                   previous_funding_rate: "Previous funding rate",
                   interval: "Funding interval (e.g., 8h)",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the FundingRate unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
