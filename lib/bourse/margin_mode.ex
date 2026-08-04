defmodule Bourse.MarginMode do
  @moduledoc """
  Unified margin mode data.

  Represents the margin mode setting for a symbol.

  ## Fields

    * `symbol` - Unified symbol
    * `margin_mode` - "cross" or "isolated"
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          margin_mode: String.t() | nil,
          info: map() | nil
        }

  defstruct [:symbol, :margin_mode, :info]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   margin_mode: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol",
                   margin_mode: ~s("cross" or "isolated"),
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the MarginMode unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
