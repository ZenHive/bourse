defmodule Bourse.Account do
  @moduledoc """
  Unified exchange account data.

  Represents an account or sub-account on an exchange.

  ## Fields

    * `id` - Account ID
    * `type` - Account type (e.g., "spot", "futures", "margin")
    * `code` - Currency code (if account is currency-specific)
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: String.t() | nil,
          code: String.t() | nil,
          info: map() | nil
        }

  defstruct [:id, :type, :code, :info]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   type: String.t() | nil,
                   code: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Account ID",
                   type: ~s{Account type (e.g., "spot", "futures", "margin")},
                   code: "Currency code (if account is currency-specific)",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Account unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
