defmodule Bourse.TransferEntry do
  @moduledoc """
  Unified internal transfer data.

  Represents a transfer between accounts within an exchange
  (e.g., spot to futures, main to sub-account).

  ## Fields

    * `id` - Transfer ID
    * `timestamp` - Transfer time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `currency` - Currency code
    * `amount` - Transfer amount
    * `fee` - Transfer fee
    * `from_account` - Source account type (e.g., "spot", "futures")
    * `to_account` - Destination account type
    * `status` - Transfer status
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          currency: String.t() | nil,
          amount: number() | nil,
          fee: Bourse.Fee.t() | nil,
          from_account: String.t() | nil,
          to_account: String.t() | nil,
          status: String.t() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :timestamp,
    :datetime,
    :currency,
    :amount,
    :fee,
    :from_account,
    :to_account,
    :status,
    :info
  ]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   currency: String.t() | nil,
                   amount: number() | nil,
                   fee: map() | nil,
                   from_account: String.t() | nil,
                   to_account: String.t() | nil,
                   status: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Transfer ID",
                   timestamp: "Transfer time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   currency: "Currency code",
                   amount: "Transfer amount",
                   fee: "Transfer fee",
                   from_account: "Source account type (e.g., spot, futures)",
                   to_account: "Destination account type",
                   status: "Transfer status",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the TransferEntry unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
