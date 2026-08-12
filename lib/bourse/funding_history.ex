defmodule Bourse.FundingHistory do
  @moduledoc """
  Unified funding payment history data.

  Represents a single funding payment received or paid on a perpetual swap position.

  ## Fields

    * `id` - Payment ID
    * `symbol` - Unified symbol
    * `code` - Currency code
    * `timestamp` - Payment time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `amount` - Funding amount (positive = received, negative = paid)
    * `rate` - Funding rate applied for the payment as a fraction, when the venue supplies it
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          symbol: String.t() | nil,
          code: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          amount: number() | nil,
          rate: number() | nil,
          info: map() | nil
        }

  defstruct [:id, :symbol, :code, :timestamp, :datetime, :amount, :rate, :info]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   symbol: String.t() | nil,
                   code: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   amount: number() | nil,
                   rate: number() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Payment ID",
                   symbol: "Unified symbol",
                   code: "Currency code",
                   timestamp: "Payment time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   amount: "Funding amount (positive = received, negative = paid)",
                   rate: "Funding rate applied for the payment as a fraction, when the venue supplies it",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the FundingHistory unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
