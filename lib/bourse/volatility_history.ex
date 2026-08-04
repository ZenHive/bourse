defmodule Bourse.VolatilityHistory do
  @moduledoc """
  Unified historical volatility (DVOL) entry.

  Represents a single historical volatility sample as returned by
  `fetch_volatility_history` (Deribit `public/get_historical_volatility`).

  Wire shape is array-of-pairs `[[unix_ms, value], ...]` inside the venue
  envelope — not a field-mapped object. Parsed fields mirror Bourse's
  volatility structure (`timestamp`, `datetime`, `volatility`, `info`).

  ## Fields

    * `timestamp` - Sample time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `volatility` - Historical volatility value (numeric)
    * `info` - Raw exchange row (`[unix_ms, value]`)

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          volatility: number() | nil,
          info: [number()] | nil
        }

  defstruct [:timestamp, :datetime, :volatility, :info]

  @json_schema schema(
                 %{
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   volatility: number() | nil,
                   info: [number()] | nil
                 },
                 doc: [
                   timestamp: "Sample time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   volatility: "Historical volatility value (numeric)",
                   info: "Raw exchange row ([unix_ms, value])"
                 ]
               )

  @doc "JSON Schema for the VolatilityHistory unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
