defmodule Bourse.Greeks do
  @moduledoc """
  Unified options greeks data.

  Represents the greeks (risk sensitivities) for an options contract.

  ## Fields

    * `symbol` - Unified symbol
    * `timestamp` - Venue source timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string for the source timestamp
    * `observed_at` - Local observation time in milliseconds (client wall clock)
    * `delta` - Price sensitivity to underlying
    * `gamma` - Delta sensitivity to underlying
    * `theta` - Time decay per day
    * `vega` - Sensitivity to volatility
    * `rho` - Sensitivity to interest rate
    * `bid_size` - Bid size
    * `ask_size` - Ask size
    * `bid_implied_volatility` - Implied volatility from bid
    * `ask_implied_volatility` - Implied volatility from ask
    * `mark_implied_volatility` - Implied volatility from mark price
    * `bid_price` - Bid price
    * `ask_price` - Ask price
    * `mark_price` - Mark price
    * `last_price` - Last traded price
    * `underlying_price` - Underlying asset price
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          observed_at: integer() | nil,
          delta: number() | nil,
          gamma: number() | nil,
          theta: number() | nil,
          vega: number() | nil,
          rho: number() | nil,
          bid_size: number() | nil,
          ask_size: number() | nil,
          bid_implied_volatility: number() | nil,
          ask_implied_volatility: number() | nil,
          mark_implied_volatility: number() | nil,
          bid_price: number() | nil,
          ask_price: number() | nil,
          mark_price: number() | nil,
          last_price: number() | nil,
          underlying_price: number() | nil,
          info: map() | nil
        }

  defstruct [
    :symbol,
    :timestamp,
    :datetime,
    :observed_at,
    :delta,
    :gamma,
    :theta,
    :vega,
    :rho,
    :bid_size,
    :ask_size,
    :bid_implied_volatility,
    :ask_implied_volatility,
    :mark_implied_volatility,
    :bid_price,
    :ask_price,
    :mark_price,
    :last_price,
    :underlying_price,
    :info
  ]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   observed_at: integer() | nil,
                   delta: number() | nil,
                   gamma: number() | nil,
                   theta: number() | nil,
                   vega: number() | nil,
                   rho: number() | nil,
                   bid_size: number() | nil,
                   ask_size: number() | nil,
                   bid_implied_volatility: number() | nil,
                   ask_implied_volatility: number() | nil,
                   mark_implied_volatility: number() | nil,
                   bid_price: number() | nil,
                   ask_price: number() | nil,
                   mark_price: number() | nil,
                   last_price: number() | nil,
                   underlying_price: number() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol",
                   timestamp: "Venue source timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string for the source timestamp",
                   observed_at: "Local observation time in milliseconds",
                   delta: "Price sensitivity to underlying",
                   gamma: "Delta sensitivity to underlying",
                   theta: "Time decay per day",
                   vega: "Sensitivity to volatility",
                   rho: "Sensitivity to interest rate",
                   bid_size: "Bid size",
                   ask_size: "Ask size",
                   bid_implied_volatility: "Implied volatility from bid",
                   ask_implied_volatility: "Implied volatility from ask",
                   mark_implied_volatility: "Implied volatility from mark price",
                   bid_price: "Bid price",
                   ask_price: "Ask price",
                   mark_price: "Mark price",
                   last_price: "Last traded price",
                   underlying_price: "Underlying asset price",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Greeks unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
