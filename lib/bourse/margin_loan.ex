defmodule Bourse.MarginLoan do
  @moduledoc """
  Unified margin loan data.

  Represents the result of a cross/isolated margin borrow or repay.

  ## Fields

    * `id` - Loan / transaction id when the venue returns one
    * `currency` - Unified currency code
    * `amount` - Borrowed or repaid amount (string or number per venue)
    * `symbol` - Unified market symbol (isolated margin only)
    * `timestamp` - Loan time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: term() | nil,
          currency: String.t() | nil,
          amount: term() | nil,
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :currency,
    :amount,
    :symbol,
    :timestamp,
    :datetime,
    :info
  ]

  @json_schema schema(
                 %{
                   id: term() | nil,
                   currency: String.t() | nil,
                   amount: term() | nil,
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Loan / transaction id when the venue returns one",
                   currency: "Unified currency code",
                   amount: "Borrowed or repaid amount (string or number per venue)",
                   symbol: "Unified market symbol (isolated margin only)",
                   timestamp: "Loan time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the MarginLoan unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
