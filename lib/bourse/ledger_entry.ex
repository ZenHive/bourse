defmodule Bourse.LedgerEntry do
  @moduledoc """
  Unified ledger entry data.

  Represents a single entry in an account's ledger/transaction history.

  ## Fields

    * `id` - Ledger entry ID
    * `timestamp` - Entry time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `direction` - "in" or "out"; nil when the venue assigns no flow direction (zero amount)
    * `account` - Account identifier
    * `reference_id` - Related transaction/order ID
    * `reference_account` - Related account
    * `type` - Entry type: a normalized value where the routed vocabulary is mapped; open vocabularies (Bybit, Hyperliquid, OKX, and Binance options bills) preserve provider literals without a mapped alias
    * `currency` - Currency code
    * `amount` - Entry amount
    * `before` - Balance before this entry
    * `after` - Balance after this entry
    * `status` - Entry status
    * `fee` - Associated fee
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          direction: String.t() | nil,
          account: String.t() | nil,
          reference_id: String.t() | nil,
          reference_account: String.t() | nil,
          type: String.t() | nil,
          currency: String.t() | nil,
          amount: number() | nil,
          before: number() | nil,
          after: number() | nil,
          status: String.t() | nil,
          fee: Bourse.Fee.t() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :timestamp,
    :datetime,
    :direction,
    :account,
    :reference_id,
    :reference_account,
    :type,
    :currency,
    :amount,
    :before,
    :after,
    :status,
    :fee,
    :info
  ]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   direction: String.t() | nil,
                   account: String.t() | nil,
                   reference_id: String.t() | nil,
                   reference_account: String.t() | nil,
                   type: String.t() | nil,
                   currency: String.t() | nil,
                   amount: number() | nil,
                   before: number() | nil,
                   after: number() | nil,
                   status: String.t() | nil,
                   fee: map() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Ledger entry ID",
                   timestamp: "Entry time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   direction: "in or out; nil when the venue assigns no flow direction (zero amount)",
                   account: "Account identifier",
                   reference_id: "Related transaction/order ID",
                   reference_account: "Related account",
                   type:
                     "Entry type: normalized where mapped; open routed vocabularies preserve provider literals without an alias",
                   currency: "Currency code",
                   amount: "Entry amount",
                   before: "Balance before this entry",
                   after: "Balance after this entry",
                   status: "Entry status",
                   fee: "Associated fee",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the LedgerEntry unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
