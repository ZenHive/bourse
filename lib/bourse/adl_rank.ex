defmodule Bourse.ADLRank do
  @moduledoc """
  Unified auto-deleveraging (ADL) rank data.

  Represents an account's ADL ranking on a derivatives exchange.
  Higher rank means higher priority for auto-deleveraging in case
  of liquidation cascades.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT:USDT")
    * `rank` - ADL rank (integer, lower = safer)
    * `rating` - ADL rating (e.g., "1", "2", "3", "4", "5")
    * `percentage` - ADL percentile
    * `timestamp` - Data timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          rank: integer() | nil,
          rating: String.t() | nil,
          percentage: number() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          info: map() | nil
        }

  defstruct [:symbol, :rank, :rating, :percentage, :timestamp, :datetime, :info]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   rank: integer() | nil,
                   rating: String.t() | nil,
                   percentage: number() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (e.g., \"BTC/USDT:USDT\")",
                   rank: "ADL rank (integer, lower = safer)",
                   rating: ~s{ADL rating (e.g., "1", "2", "3", "4", "5")},
                   percentage: "ADL percentile",
                   timestamp: "Data timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the ADLRank unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
