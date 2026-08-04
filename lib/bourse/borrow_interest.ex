defmodule Bourse.BorrowInterest do
  @moduledoc """
  Unified borrow interest data.

  Represents accrued interest on a margin borrow position.

  ## Fields

    * `symbol` - Unified symbol (if isolated margin)
    * `currency` - Borrowed currency code
    * `interest` - Accrued interest amount
    * `interest_rate` - Interest rate as decimal
    * `amount_borrowed` - Total amount borrowed
    * `margin_mode` - "cross" or "isolated"
    * `timestamp` - Data timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          currency: String.t() | nil,
          interest: number() | nil,
          interest_rate: number() | nil,
          amount_borrowed: number() | nil,
          margin_mode: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          info: map() | nil
        }

  defstruct [
    :symbol,
    :currency,
    :interest,
    :interest_rate,
    :amount_borrowed,
    :margin_mode,
    :timestamp,
    :datetime,
    :info
  ]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   currency: String.t() | nil,
                   interest: number() | nil,
                   interest_rate: number() | nil,
                   amount_borrowed: number() | nil,
                   margin_mode: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (if isolated margin)",
                   currency: "Borrowed currency code",
                   interest: "Accrued interest amount",
                   interest_rate: "Interest rate as decimal",
                   amount_borrowed: "Total amount borrowed",
                   margin_mode: ~s("cross" or "isolated"),
                   timestamp: "Data timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the BorrowInterest unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
