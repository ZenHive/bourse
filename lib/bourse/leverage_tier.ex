defmodule Bourse.LeverageTier do
  @moduledoc """
  Unified leverage tier data.

  Represents a single tier in an exchange's tiered leverage/margin schedule.

  ## Fields

    * `tier` - Tier number (1-based)
    * `symbol` - Unified symbol
    * `currency` - Settlement currency
    * `min_notional` - Minimum notional value for this tier
    * `max_notional` - Maximum notional value for this tier
    * `maintenance_margin_rate` - Required maintenance margin rate as decimal
    * `max_leverage` - Maximum leverage allowed in this tier
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          tier: integer() | nil,
          symbol: String.t() | nil,
          currency: String.t() | nil,
          min_notional: number() | nil,
          max_notional: number() | nil,
          maintenance_margin_rate: number() | nil,
          max_leverage: number() | nil,
          info: map() | nil
        }

  defstruct [
    :tier,
    :symbol,
    :currency,
    :min_notional,
    :max_notional,
    :maintenance_margin_rate,
    :max_leverage,
    :info
  ]

  @json_schema schema(
                 %{
                   tier: integer() | nil,
                   symbol: String.t() | nil,
                   currency: String.t() | nil,
                   min_notional: number() | nil,
                   max_notional: number() | nil,
                   maintenance_margin_rate: number() | nil,
                   max_leverage: number() | nil,
                   info: map() | nil
                 },
                 doc: [
                   tier: "Tier number (1-based)",
                   symbol: "Unified symbol",
                   currency: "Settlement currency",
                   min_notional: "Minimum notional value for this tier",
                   max_notional: "Maximum notional value for this tier",
                   maintenance_margin_rate: "Required maintenance margin rate as decimal",
                   max_leverage: "Maximum leverage allowed in this tier",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the LeverageTier unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
