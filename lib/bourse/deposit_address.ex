defmodule Bourse.DepositAddress do
  @moduledoc """
  Unified deposit address data.

  Represents a deposit address for a specific currency and network.

  ## Fields

    * `currency` - Currency code (e.g., "BTC")
    * `network` - Blockchain network (e.g., "ERC20", "TRC20")
    * `address` - Deposit address
    * `tag` - Deposit tag/memo (required for some currencies like XRP, EOS)
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          currency: String.t() | nil,
          network: String.t() | nil,
          address: String.t() | nil,
          tag: String.t() | nil,
          info: map() | nil
        }

  defstruct [:currency, :network, :address, :tag, :info]

  @json_schema schema(
                 %{
                   currency: String.t() | nil,
                   network: String.t() | nil,
                   address: String.t() | nil,
                   tag: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   currency: "Currency code (e.g., BTC)",
                   network: "Blockchain network (e.g., ERC20, TRC20)",
                   address: "Deposit address",
                   tag: "Deposit tag/memo (required for some currencies like XRP, EOS)",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the DepositAddress unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
