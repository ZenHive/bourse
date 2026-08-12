defmodule Bourse.InstrumentGreeks do
  @moduledoc """
  Per-instrument Greeks joined to option identity with explicit conventions.

  Built by `Bourse.Unified.OptionSurface.instrument_greeks/3`. Each populated
  Greek names its native source field plus denomination, unit, bump size and
  time basis; unsupported Greeks stay explicit with `supported: false`.
  """

  import JSONSpec, only: [schema: 2]

  @type convention :: %{
          required(String.t()) => term()
        }

  @type t :: %__MODULE__{
          venue: String.t() | nil,
          symbol: String.t() | nil,
          id: String.t() | nil,
          settle: String.t() | nil,
          strike: number() | nil,
          expiry: integer() | nil,
          option_type: String.t() | nil,
          delta: number() | nil,
          gamma: number() | nil,
          vega: number() | nil,
          theta: number() | nil,
          rho: number() | nil,
          conventions: %{optional(String.t()) => convention()} | nil,
          bid_price: number() | nil,
          ask_price: number() | nil,
          mark_implied_volatility: number() | nil,
          underlying_price: number() | nil,
          source_timestamp: integer() | nil,
          observed_at: integer() | nil,
          info: map() | nil
        }

  defstruct [
    :venue,
    :symbol,
    :id,
    :settle,
    :strike,
    :expiry,
    :option_type,
    :delta,
    :gamma,
    :vega,
    :theta,
    :rho,
    :conventions,
    :bid_price,
    :ask_price,
    :mark_implied_volatility,
    :underlying_price,
    :source_timestamp,
    :observed_at,
    :info
  ]

  @json_schema schema(
                 %{
                   venue: String.t() | nil,
                   symbol: String.t() | nil,
                   id: String.t() | nil,
                   settle: String.t() | nil,
                   strike: number() | nil,
                   expiry: integer() | nil,
                   option_type: String.t() | nil,
                   delta: number() | nil,
                   gamma: number() | nil,
                   vega: number() | nil,
                   theta: number() | nil,
                   rho: number() | nil,
                   conventions: map() | nil,
                   bid_price: number() | nil,
                   ask_price: number() | nil,
                   mark_implied_volatility: number() | nil,
                   underlying_price: number() | nil,
                   source_timestamp: integer() | nil,
                   observed_at: integer() | nil,
                   info: map() | nil
                 },
                 doc: [
                   venue: "Exchange id",
                   symbol: "Canonical unified option symbol",
                   id: "Venue-native instrument id",
                   settle: "Settlement currency",
                   strike: "Strike price",
                   expiry: "Expiry timestamp in milliseconds",
                   option_type: "call or put",
                   delta: "Delta when the venue publishes it",
                   gamma: "Gamma when the venue publishes it",
                   vega: "Vega when the venue publishes it",
                   theta: "Theta when the venue publishes it",
                   rho: "Rho when the venue publishes it",
                   conventions: "Per-Greek native field and unit conventions",
                   bid_price: "Best bid when supplied with the Greeks payload",
                   ask_price: "Best ask when supplied with the Greeks payload",
                   mark_implied_volatility: "Mark IV as a fraction when supplied (0.75 = 75%)",
                   underlying_price: "Underlying price when supplied",
                   source_timestamp: "Venue-reported timestamp in milliseconds",
                   observed_at: "Local observation time in milliseconds",
                   info: "Raw venue Greeks payload"
                 ]
               )

  @doc "JSON Schema for the InstrumentGreeks surface type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
