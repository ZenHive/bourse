defmodule Bourse.Fee do
  @moduledoc """
  Fee information attached to trades and orders.

  Represents exchange fees with currency denomination, absolute cost,
  and rate (as a decimal fraction).

  ## Fields

    * `currency` - Fee currency (e.g., "USDT", "BTC")
    * `cost` - Absolute fee amount
    * `rate` - Fee rate as decimal (e.g., 0.001 for 0.1%)

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          currency: String.t() | nil,
          cost: number() | nil,
          rate: number() | nil
        }

  defstruct [:currency, :cost, :rate]

  @json_schema schema(
                 %{
                   currency: String.t() | nil,
                   cost: number() | nil,
                   rate: number() | nil
                 },
                 doc: [
                   currency: "Fee currency (e.g., USDT, BTC)",
                   cost: "Absolute fee amount",
                   rate: "Fee rate as decimal (e.g., 0.001 for 0.1%)"
                 ]
               )

  @doc "JSON Schema for the Fee unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
