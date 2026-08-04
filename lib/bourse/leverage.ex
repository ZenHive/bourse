defmodule Bourse.Leverage do
  @moduledoc """
  Unified leverage settings data.

  Represents the current leverage configuration for a symbol.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT:USDT")
    * `margin_mode` - "cross" or "isolated"
    * `long_leverage` - Leverage for long positions
    * `short_leverage` - Leverage for short positions
    * `info` - Raw exchange row, or the list of rows when a venue answers
      hedge mode with one row per side (OKX `posSide` long/short)

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          margin_mode: String.t() | nil,
          long_leverage: number() | nil,
          short_leverage: number() | nil,
          info: term() | nil
        }

  defstruct [:symbol, :margin_mode, :long_leverage, :short_leverage, :info]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   margin_mode: String.t() | nil,
                   long_leverage: number() | nil,
                   short_leverage: number() | nil,
                   info: term() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (e.g., \"BTC/USDT:USDT\")",
                   margin_mode: ~s("cross" or "isolated"),
                   long_leverage: "Leverage for long positions",
                   short_leverage: "Leverage for short positions",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Leverage unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
