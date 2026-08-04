defmodule Bourse.LongShortRatio do
  @moduledoc """
  Unified long/short ratio data.

  Represents the ratio of long to short positions for a symbol.

  ## Fields

    * `symbol` - Unified symbol
    * `timestamp` - Data timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `timeframe` - Aggregation timeframe (e.g., "5m", "1h")
    * `long_short_ratio` - Ratio of longs to shorts
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          timeframe: String.t() | nil,
          long_short_ratio: number() | nil,
          info: map() | nil
        }

  defstruct [:symbol, :timestamp, :datetime, :timeframe, :long_short_ratio, :info]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   timeframe: String.t() | nil,
                   long_short_ratio: number() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol",
                   timestamp: "Data timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   timeframe: ~s{Aggregation timeframe (e.g., "5m", "1h")},
                   long_short_ratio: "Ratio of longs to shorts",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the LongShortRatio unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
