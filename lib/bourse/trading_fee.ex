defmodule Bourse.TradingFee do
  @moduledoc """
  Unified trading fee schedule data.

  Describes the maker/taker fee rates for a symbol. Distinct from
  `Bourse.Fee` which represents the fee on a single trade or order.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT")
    * `maker` - Maker fee rate as decimal (e.g., 0.001 = 0.1%)
    * `taker` - Taker fee rate as decimal
    * `percentage` - Whether fees are percentage-based (vs flat)
    * `tier_based` - Whether fees vary by trading volume tier
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          maker: number() | nil,
          taker: number() | nil,
          percentage: boolean() | nil,
          tier_based: boolean() | nil,
          info: map() | nil
        }

  defstruct [:symbol, :maker, :taker, :percentage, :tier_based, :info]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   maker: number() | nil,
                   taker: number() | nil,
                   percentage: boolean() | nil,
                   tier_based: boolean() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (e.g., BTC/USDT)",
                   maker: "Maker fee rate as decimal (e.g., 0.001 = 0.1%)",
                   taker: "Taker fee rate as decimal",
                   percentage: "Whether fees are percentage-based (vs flat)",
                   tier_based: "Whether fees vary by trading volume tier",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the TradingFee unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
