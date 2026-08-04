defmodule Bourse.OptionInstrument do
  @moduledoc """
  Discovered option market identity plus available quote fields.

  Built by `Bourse.Unified.OptionSurface.discover/2`. Identity fields are required;
  bid/ask, IV and open interest are populated only when the venue supplies them.
  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          venue: String.t() | nil,
          symbol: String.t() | nil,
          id: String.t() | nil,
          base: String.t() | nil,
          quote: String.t() | nil,
          settle: String.t() | nil,
          strike: number() | nil,
          expiry: integer() | nil,
          option_type: String.t() | nil,
          active: boolean() | nil,
          bid_price: number() | nil,
          ask_price: number() | nil,
          implied_volatility: number() | nil,
          open_interest: number() | nil,
          source_timestamp: integer() | nil,
          observed_at: integer() | nil,
          info: map() | nil
        }

  defstruct [
    :venue,
    :symbol,
    :id,
    :base,
    :quote,
    :settle,
    :strike,
    :expiry,
    :option_type,
    :active,
    :bid_price,
    :ask_price,
    :implied_volatility,
    :open_interest,
    :source_timestamp,
    :observed_at,
    :info
  ]

  @json_schema schema(
                 %{
                   venue: String.t() | nil,
                   symbol: String.t() | nil,
                   id: String.t() | nil,
                   base: String.t() | nil,
                   quote: String.t() | nil,
                   settle: String.t() | nil,
                   strike: number() | nil,
                   expiry: integer() | nil,
                   option_type: String.t() | nil,
                   active: boolean() | nil,
                   bid_price: number() | nil,
                   ask_price: number() | nil,
                   implied_volatility: number() | nil,
                   open_interest: number() | nil,
                   source_timestamp: integer() | nil,
                   observed_at: integer() | nil,
                   info: map() | nil
                 },
                 doc: [
                   venue: "Exchange id",
                   symbol: "Canonical unified option symbol",
                   id: "Venue-native instrument id",
                   base: "Underlying base currency",
                   quote: "Quote currency",
                   settle: "Settlement currency",
                   strike: "Strike price",
                   expiry: "Expiry timestamp in milliseconds",
                   option_type: "call or put",
                   active: "Whether the instrument is currently tradeable",
                   bid_price: "Best bid when the venue supplies it",
                   ask_price: "Best ask when the venue supplies it",
                   implied_volatility: "Implied volatility when supplied",
                   open_interest: "Open interest when supplied",
                   source_timestamp: "Venue-reported timestamp in milliseconds",
                   observed_at: "Local observation time in milliseconds",
                   info: "Raw venue payload fragments"
                 ]
               )

  @doc "JSON Schema for the OptionInstrument surface type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
