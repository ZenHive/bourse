defmodule Bourse.FundingRateHistory do
  @moduledoc """
  Unified funding rate history entry.

  Represents a single historical funding rate record. Distinct from
  `Bourse.FundingRate` which carries the full current funding rate snapshot
  with mark/index prices and next/previous rates (17 fields). This
  struct is the stripped-down version returned by `fetch_funding_rate_history`.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT:USDT")
    * `funding_rate` - Historical funding rate as decimal
    * `timestamp` - Funding event timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          funding_rate: number() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          info: map() | nil
        }

  defstruct [:symbol, :funding_rate, :timestamp, :datetime, :info]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   funding_rate: number() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (e.g., \"BTC/USDT:USDT\")",
                   funding_rate: "Historical funding rate as decimal",
                   timestamp: "Funding event timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the FundingRateHistory unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
