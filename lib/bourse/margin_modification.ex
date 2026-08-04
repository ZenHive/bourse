defmodule Bourse.MarginModification do
  @moduledoc """
  Unified margin modification data.

  Represents a margin adjustment (add/reduce margin) on a position.

  ## Fields

    * `symbol` - Unified symbol
    * `type` - "add" or "reduce"
    * `margin_mode` - "cross" or "isolated"
    * `amount` - Margin amount modified
    * `total` - Total margin after modification
    * `code` - Currency code
    * `status` - Modification status
    * `timestamp` - Modification time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          type: String.t() | nil,
          margin_mode: String.t() | nil,
          amount: number() | nil,
          total: number() | nil,
          code: String.t() | nil,
          status: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          info: map() | nil
        }

  defstruct [
    :symbol,
    :type,
    :margin_mode,
    :amount,
    :total,
    :code,
    :status,
    :timestamp,
    :datetime,
    :info
  ]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   type: String.t() | nil,
                   margin_mode: String.t() | nil,
                   amount: number() | nil,
                   total: number() | nil,
                   code: String.t() | nil,
                   status: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol",
                   type: ~s("add" or "reduce"),
                   margin_mode: ~s("cross" or "isolated"),
                   amount: "Margin amount modified",
                   total: "Total margin after modification",
                   code: "Currency code",
                   status: "Modification status",
                   timestamp: "Modification time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the MarginModification unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
