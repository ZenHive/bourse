defmodule Bourse.OptionData do
  @moduledoc """
  Unified options contract data.

  Represents market data for an options contract. Named `OptionData`
  to avoid confusion with Elixir's concept of options.

  ## Fields

    * `currency` - Settlement currency
    * `symbol` - Unified symbol
    * `timestamp` - Venue source timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string for the source timestamp
    * `observed_at` - Local observation time in milliseconds (client wall clock)
    * `implied_volatility` - Implied volatility
    * `open_interest` - Open interest
    * `bid_price` - Bid price
    * `ask_price` - Ask price
    * `mid_price` - Mid price
    * `mark_price` - Mark price
    * `last_price` - Last traded price
    * `underlying_price` - Underlying asset price
    * `change` - Price change
    * `percentage` - Percentage change
    * `base_volume` - Volume in base currency
    * `quote_volume` - Volume in quote currency
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          currency: String.t() | nil,
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          observed_at: integer() | nil,
          implied_volatility: number() | nil,
          open_interest: number() | nil,
          bid_price: number() | nil,
          ask_price: number() | nil,
          mid_price: number() | nil,
          mark_price: number() | nil,
          last_price: number() | nil,
          underlying_price: number() | nil,
          change: number() | nil,
          percentage: number() | nil,
          base_volume: number() | nil,
          quote_volume: number() | nil,
          info: map() | nil
        }

  defstruct [
    :currency,
    :symbol,
    :timestamp,
    :datetime,
    :observed_at,
    :implied_volatility,
    :open_interest,
    :bid_price,
    :ask_price,
    :mid_price,
    :mark_price,
    :last_price,
    :underlying_price,
    :change,
    :percentage,
    :base_volume,
    :quote_volume,
    :info
  ]

  @json_schema schema(
                 %{
                   currency: String.t() | nil,
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   observed_at: integer() | nil,
                   implied_volatility: number() | nil,
                   open_interest: number() | nil,
                   bid_price: number() | nil,
                   ask_price: number() | nil,
                   mid_price: number() | nil,
                   mark_price: number() | nil,
                   last_price: number() | nil,
                   underlying_price: number() | nil,
                   change: number() | nil,
                   percentage: number() | nil,
                   base_volume: number() | nil,
                   quote_volume: number() | nil,
                   info: map() | nil
                 },
                 doc: [
                   currency: "Settlement currency",
                   symbol: "Unified symbol",
                   timestamp: "Venue source timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string for the source timestamp",
                   observed_at: "Local observation time in milliseconds",
                   implied_volatility: "Implied volatility",
                   open_interest: "Open interest",
                   bid_price: "Bid price",
                   ask_price: "Ask price",
                   mid_price: "Mid price",
                   mark_price: "Mark price",
                   last_price: "Last traded price",
                   underlying_price: "Underlying asset price",
                   change: "Price change",
                   percentage: "Percentage change",
                   base_volume: "Volume in base currency",
                   quote_volume: "Volume in quote currency",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the OptionData unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
