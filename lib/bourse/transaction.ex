defmodule Bourse.Transaction do
  @moduledoc """
  Unified deposit/withdrawal transaction data.

  Represents a deposit or withdrawal on an exchange.

  ## Fields

    * `id` - Exchange transaction ID
    * `txid` - Blockchain transaction hash
    * `timestamp` - Transaction time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `address` - Destination address
    * `address_from` - Source address
    * `address_to` - Destination address
    * `tag` - Destination tag/memo
    * `tag_from` - Source tag/memo
    * `tag_to` - Destination tag/memo
    * `type` - "deposit" or "withdrawal"
    * `amount` - Transaction amount
    * `currency` - Currency code (e.g., "BTC")
    * `status` - "pending", "ok", "failed", "canceled"
    * `updated` - Last update timestamp in milliseconds
    * `fee` - Transaction fee
    * `network` - Blockchain network
    * `comment` - Transaction comment/note
    * `internal` - Whether this is an internal transfer
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          txid: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          address: String.t() | nil,
          address_from: String.t() | nil,
          address_to: String.t() | nil,
          tag: String.t() | nil,
          tag_from: String.t() | nil,
          tag_to: String.t() | nil,
          type: String.t() | nil,
          amount: number() | nil,
          currency: String.t() | nil,
          status: String.t() | nil,
          updated: integer() | nil,
          fee: Bourse.Fee.t() | nil,
          network: String.t() | nil,
          comment: String.t() | nil,
          internal: boolean() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :txid,
    :timestamp,
    :datetime,
    :address,
    :address_from,
    :address_to,
    :tag,
    :tag_from,
    :tag_to,
    :type,
    :amount,
    :currency,
    :status,
    :updated,
    :fee,
    :network,
    :comment,
    :internal,
    :info
  ]

  @doc "Returns true if this is a deposit."
  @spec deposit?(t()) :: boolean()
  def deposit?(%__MODULE__{type: "deposit"}), do: true
  def deposit?(%__MODULE__{}), do: false

  @doc "Returns true if this is a withdrawal."
  @spec withdrawal?(t()) :: boolean()
  def withdrawal?(%__MODULE__{type: "withdrawal"}), do: true
  def withdrawal?(%__MODULE__{}), do: false

  @doc "Returns true if the transaction is pending."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: "pending"}), do: true
  def pending?(%__MODULE__{}), do: false

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   txid: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   address: String.t() | nil,
                   address_from: String.t() | nil,
                   address_to: String.t() | nil,
                   tag: String.t() | nil,
                   tag_from: String.t() | nil,
                   tag_to: String.t() | nil,
                   type: String.t() | nil,
                   amount: number() | nil,
                   currency: String.t() | nil,
                   status: String.t() | nil,
                   updated: integer() | nil,
                   fee: map() | nil,
                   network: String.t() | nil,
                   comment: String.t() | nil,
                   internal: boolean() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Exchange transaction ID",
                   txid: "Blockchain transaction hash",
                   timestamp: "Transaction time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   address: "Destination address",
                   address_from: "Source address",
                   address_to: "Destination address",
                   tag: "Destination tag/memo",
                   tag_from: "Source tag/memo",
                   tag_to: "Destination tag/memo",
                   type: "deposit or withdrawal",
                   amount: "Transaction amount",
                   currency: "Currency code (e.g., BTC)",
                   status: "pending, ok, failed, or canceled",
                   updated: "Last update timestamp in milliseconds",
                   fee: "Transaction fee",
                   network: "Blockchain network",
                   comment: "Transaction comment/note",
                   internal: "Whether this is an internal transfer",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Transaction unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
