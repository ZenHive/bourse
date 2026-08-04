defmodule Bourse.BorrowRate do
  @moduledoc """
  Unified borrow rate data.

  Represents a margin borrow rate, covering both cross-margin and
  isolated-margin rates in a single struct. For cross rates, `symbol`
  is nil and only `currency`/`rate` are populated. For isolated rates,
  `symbol`, `base`, `quote`, and per-side rates are populated.

  ## Fields

    * `symbol` - Unified symbol (nil for cross-margin rates)
    * `currency` - Currency code
    * `rate` - Borrow rate as decimal
    * `base` - Base currency (isolated margin only)
    * `base_rate` - Base currency borrow rate (isolated margin only)
    * `quote` - Quote currency (isolated margin only)
    * `quote_rate` - Quote currency borrow rate (isolated margin only)
    * `period` - Rate period in milliseconds
    * `timestamp` - Data timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          currency: String.t() | nil,
          rate: number() | nil,
          base: String.t() | nil,
          base_rate: number() | nil,
          quote: String.t() | nil,
          quote_rate: number() | nil,
          period: integer() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          info: map() | nil
        }

  defstruct [
    :symbol,
    :currency,
    :rate,
    :base,
    :base_rate,
    :quote,
    :quote_rate,
    :period,
    :timestamp,
    :datetime,
    :info
  ]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   currency: String.t() | nil,
                   rate: number() | nil,
                   base: String.t() | nil,
                   base_rate: number() | nil,
                   quote: String.t() | nil,
                   quote_rate: number() | nil,
                   period: integer() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (nil for cross-margin rates)",
                   currency: "Currency code",
                   rate: "Borrow rate as decimal",
                   base: "Base currency (isolated margin only)",
                   base_rate: "Base currency borrow rate (isolated margin only)",
                   quote: "Quote currency (isolated margin only)",
                   quote_rate: "Quote currency borrow rate (isolated margin only)",
                   period: "Rate period in milliseconds",
                   timestamp: "Data timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the BorrowRate unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
